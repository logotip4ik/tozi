const std = @import("std");
const bencode = @import("bencode.zig");

pub const File = struct {
    name: []const u8,
    len: usize,
};
const Files = std.array_list.Aligned(File, null);

pub const Dir = struct {
    name: []const u8,
};
const Dirs = std.array_list.Aligned(Dir, null);

pub const Torrent = struct {
    value: bencode.Value,

    announce: []const u8,
    files: Files,
    dirs: Dirs,
    pieces: []const u8,
    pienceLen: usize,
    infoHash: [std.crypto.hash.Sha1.digest_length]u8,
    totalLen: usize,

    announceList: ?[]const []const u8,
    creation_date: ?usize,
    created_by: ?[]const u8,

    /// reader must be recreated to seek from start of the file
    pub fn deinit(self: *Torrent, alloc: std.mem.Allocator) void {
        self.value.deinit(alloc);
        self.dirs.deinit(alloc);
        self.files.deinit(alloc);
        if (self.announceList) |list| alloc.free(list);
    }
};

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

pub fn parseTorrentFromSlice(alloc: std.mem.Allocator, noalias slice: []const u8) !Torrent {
    var reader: std.Io.Reader = .fixed(slice);

    var value = try bencode.parseValue(alloc, &reader, 0);
    errdefer value.deinit(alloc);

    const dict = value.inner.dict;
    const announceList = if (dict.get("announce-list")) |v| blk: {
        const list = v.inner.list.items[0].inner.list;

        const ret = try alloc.alloc([]const u8, list.items.len);
        errdefer alloc.free(ret);

        for (list.items, 0..) |item, i| ret[i] = item.inner.string;

        break :blk ret;
    } else null;
    errdefer if (announceList) |list| alloc.free(list);

    const info = if (dict.get("info")) |v| v else {
        std.log.err("expected 'info' property to exists in torrent", .{});
        return error.MissingInfo;
    };

    var files: Files = .empty;
    errdefer files.deinit(alloc);

    var dirs: Dirs = .empty;
    errdefer files.deinit(alloc);

    var totalLen: usize = 0;

    if (info.inner.dict.get("files")) |infoFiles| {
        const dirname = info.inner.dict.get("name") orelse return error.NoDirName;

        try dirs.append(alloc, .{ .name = dirname.inner.string });

        for (infoFiles.inner.list.items) |file| {
            const filenames = file.inner.dict.get("path") orelse return error.NoFilePath;
            const len = file.inner.dict.get("length") orelse return error.NoFileLength;

            totalLen += len.inner.int;

            for (filenames.inner.list.items) |filename| {
                try files.append(alloc, .{
                    .name = filename.inner.string,
                    .len = len.inner.int,
                });
            }
        }
    } else {
        const filename = info.inner.dict.get("name") orelse return error.NoFileName;
        const len = info.inner.dict.get("length") orelse return error.NoFileLength;

        totalLen += len.inner.int;

        try files.append(alloc, .{
            .name = filename.inner.string,
            .len = len.inner.int,
        });
    }

    reader.seek = 0;
    const infoHash = try computeInfoHash(info, &reader);

    const pieces = info.inner.dict.get("pieces") orelse return error.NoPiencesField;
    const pienceLen = info.inner.dict.get("piece length") orelse return error.NoPieceLenField;

    return Torrent{
        .value = value,
        .announce = if (dict.get("announce")) |v|
            v.inner.string
        else if (announceList) |list|
            list[0]
        else
            return error.MissingAnnounceUrl,
        .announceList = announceList,
        .created_by = null,
        .creation_date = null,
        .files = files,
        .dirs = dirs,
        .pieces = pieces.inner.string,
        .pienceLen = pienceLen.inner.int,
        .infoHash = infoHash,
        .totalLen = totalLen,
    };
}

test "parseTorrent - simple" {
    const file = @embedFile("./test_files/testing.torrent");

    var torrent = try parseTorrentFromSlice(std.testing.allocator, file);
    defer torrent.deinit(std.testing.allocator);

    try std.testing.expectEqual(1, torrent.dirs.items.len);
    try std.testing.expectEqual(2, torrent.files.items.len);
}

test "parseTorrent - single file" {
    const file = @embedFile("./test_files/custom.torrent");

    var torrent = try parseTorrentFromSlice(std.testing.allocator, file);
    defer torrent.deinit(std.testing.allocator);

    try std.testing.expectEqual(0, torrent.dirs.items.len);
    try std.testing.expectEqual(1, torrent.files.items.len);
    try std.testing.expectEqualStrings("http://localhost:6881/announce", torrent.announce);
}

test "parseTorrent - info hash for simple torrent" {
    const file = @embedFile("./test_files/custom.torrent");

    var torrent = try parseTorrentFromSlice(std.testing.allocator, file);
    defer torrent.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings(
        "0d236f8a8da1f617140e926bdc7ed69184669816",
        &std.fmt.bytesToHex(&torrent.infoHash, .lower),
    );
}

test "parseTorrent - info hash" {
    const file = @embedFile("./test_files/testing.torrent");

    var torrent = try parseTorrentFromSlice(std.testing.allocator, file);
    defer torrent.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings(
        "dd08c5e0f873f31687ea4b8a6ecfd0153d6d524c",
        &std.fmt.bytesToHex(&torrent.infoHash, .lower),
    );
}
