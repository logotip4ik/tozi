const std = @import("std");
const bencode = @import("bencode.zig");

pub const File = struct {
    /// should include `dirname` from torrent if there was one
    path: []const []const u8,
    len: usize,
};
const Files = std.array_list.Aligned(File, null);

const Torrent = @This();

value: bencode.Value,

files: Files,
pieces: []const u8,
pieceLen: u32,
infoHash: [std.crypto.hash.Sha1.digest_length]u8,
totalLen: usize,

announceList: []const []const u8,
creation_date: ?usize,
created_by: ?[]const u8,

pub const BLOCK_SIZE = 1024 * 16;

pub fn deinit(self: *Torrent, alloc: std.mem.Allocator) void {
    for (self.files.items) |file| {
        alloc.free(file.path);
    }
    self.files.deinit(alloc);
    alloc.free(self.announceList);
    self.value.deinit(alloc);
}

pub fn getPieceSize(self: Torrent, index: usize) u32 {
    const numberOfPieces = (self.totalLen + self.pieceLen - 1) / self.pieceLen;

    if (index < numberOfPieces - 1) {
        @branchHint(.likely);
        return @intCast(self.pieceLen);
    }

    return @intCast(self.totalLen - (index * self.pieceLen));
}

pub fn computeInfoHash(info: bencode.Value, reader: *std.Io.Reader) ![std.crypto.hash.Sha1.digest_length]u8 {
    _ = try reader.discardShort(info.start);

    var hash: std.crypto.hash.Sha1 = .init(.{});

    var read: usize = 0;
    while (true) {
        const readSize = @min(std.crypto.hash.Sha1.block_length, info.len - read);
        const chunk = try reader.take(readSize);

        hash.update(chunk);
        read += readSize;

        if (read == info.len) {
            break;
        }
    }

    return hash.finalResult();
}

pub fn fromSlice(alloc: std.mem.Allocator, noalias slice: []const u8) !Torrent {
    var reader: std.Io.Reader = .fixed(slice);

    var value = try bencode.parseValue(alloc, &reader, 0);
    errdefer value.deinit(alloc);

    const dict = value.inner.dict;

    const announce = if (dict.get("announce")) |v|
        v.inner.string
    else
        null;

    var announces: std.array_list.Aligned([]const u8, null) = .empty;

    if (dict.get("announce-list")) |v| {
        if (announce) |a| {
            try announces.append(alloc, a);
        }

        for (v.inner.list.items) |list| {
            outer: for (list.inner.list.items) |item| {
                for (announces.items) |existing| {
                    if (std.mem.eql(u8, existing, item.inner.string)) {
                        continue :outer;
                    }
                }

                try announces.append(alloc, item.inner.string);
            }
        }
    } else if (announce) |x| {
        try announces.append(alloc, x);
    } else return error.NoAnnounceUrls;
    defer announces.deinit(alloc);

    const info = if (dict.get("info")) |v| v else {
        std.log.err("expected 'info' property to exists in torrent", .{});
        return error.MissingInfo;
    };

    var files: Files = .empty;
    errdefer files.deinit(alloc);

    var totalLen: usize = 0;

    if (info.inner.dict.get("files")) |infoFiles| {
        const dirnameValue = info.inner.dict.get("name") orelse return error.NoDirName;
        const dirname = dirnameValue.inner.string;

        for (infoFiles.inner.list.items) |file| {
            const chunks = file.inner.dict.get("path") orelse return error.NoFilePath;
            const len = file.inner.dict.get("length") orelse return error.NoFileLength;

            totalLen += len.inner.int;

            const path = try alloc.alloc([]const u8, chunks.inner.list.items.len + 1);

            path[0] = dirname;
            for (chunks.inner.list.items, 1..) |filename, i| {
                path[i] = filename.inner.string;
            }

            try files.append(alloc, .{
                .path = path,
                .len = len.inner.int,
            });
        }
    } else {
        const filename = info.inner.dict.get("name") orelse return error.NoFileName;
        const len = info.inner.dict.get("length") orelse return error.NoFileLength;

        totalLen += len.inner.int;

        const path = try alloc.alloc([]const u8, 1);
        path[0] = filename.inner.string;

        try files.append(alloc, .{
            .path = path,
            .len = len.inner.int,
        });
    }

    reader.seek = 0;
    const infoHash = try computeInfoHash(info, &reader);

    const pieces = info.inner.dict.get("pieces") orelse return error.NoPiencesField;
    const pieceLen = info.inner.dict.get("piece length") orelse return error.NoPieceLenField;

    return Torrent{
        .value = value,
        .announceList = try announces.toOwnedSlice(alloc),
        .created_by = null,
        .creation_date = null,
        .files = files,
        .pieces = pieces.inner.string,
        .pieceLen = @intCast(pieceLen.inner.int),
        .infoHash = infoHash,
        .totalLen = totalLen,
    };
}

test "parseTorrent - simple" {
    const file = @embedFile("./test_files/custom-folder.torrent");

    var torrent = try fromSlice(std.testing.allocator, file);
    defer torrent.deinit(std.testing.allocator);

    try std.testing.expectEqual(7, torrent.files.items.len);
}

test "parseTorrent - single file" {
    const file = @embedFile("./test_files/custom.torrent");

    var torrent = try fromSlice(std.testing.allocator, file);
    defer torrent.deinit(std.testing.allocator);

    try std.testing.expectEqual(1, torrent.files.items.len);
    try std.testing.expectEqualStrings("http://localhost:9000/announce", torrent.announceList[0]);
}

test "parseTorrent - info hash for simple torrent" {
    const file = @embedFile("./test_files/custom.torrent");

    var torrent = try fromSlice(std.testing.allocator, file);
    defer torrent.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings(
        "9e947546139508901953291490941744bf9395bc",
        &std.fmt.bytesToHex(&torrent.infoHash, .lower),
    );
}

test "parseTorrent - info hash" {
    const file = @embedFile("./test_files/custom-folder.torrent");

    var torrent = try fromSlice(std.testing.allocator, file);
    defer torrent.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings(
        "f0c4cb2d359b74a5f418344749c7441ae2639d33",
        &std.fmt.bytesToHex(&torrent.infoHash, .lower),
    );
}
