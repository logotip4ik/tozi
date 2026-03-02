const std = @import("std");

const Bencode = @import("bencode.zig");
const Magnet = @import("magnet.zig");

pub const File = struct {
    /// should include `dirname` from torrent if there was one
    path: []const []const u8,
    len: usize,
};
const Files = std.array_list.Aligned(File, null);

const Torrent = @This();

pub const BLOCK_SIZE = 1024 * 16;

pub const Announces = std.array_list.Aligned([]const u8, null);
pub const Tiers = std.array_list.Aligned(Announces, null);

value: ?Bencode,

files: Files,
pieces: []const u8,
piece_len: u32,
info_hash: [std.crypto.hash.Sha1.digest_length]u8,
total_len: usize,
private: bool,

tiers: std.array_list.Aligned(Announces, null),

creation_date: ?usize,
created_by: ?[]const u8,

pub fn deinit(self: *Torrent, alloc: std.mem.Allocator) void {
    for (self.files.items) |file| alloc.free(file.path);
    self.files.deinit(alloc);

    for (self.tiers.items) |*x| {
        for (x.items) |url| alloc.free(url);
        x.deinit(alloc);
    }
    self.tiers.deinit(alloc);

    if (self.value) |*x| x.deinit(alloc);
}

pub fn getPieceSize(self: Torrent, index: usize) u32 {
    const offset = @as(u64, index) * self.piece_len;
    const remaining = self.total_len - offset;

    return @intCast(@min(@as(u64, self.piece_len), remaining));
}

pub fn inheritInfo(
    self: *Torrent,
    alloc: std.mem.Allocator,
    info: std.hash_map.StringHashMapUnmanaged(Bencode),
) !void {
    var files: Files = .empty;
    errdefer files.deinit(alloc);

    var total_len: usize = 0;

    if (info.get("files")) |infoFiles| {
        const dirname_value = info.get("name") orelse return error.NoDirName;
        const dirname = dirname_value.inner.string;

        for (infoFiles.inner.list.items) |file| {
            const chunks = file.inner.dict.get("path") orelse return error.NoFilePath;
            const len = file.inner.dict.get("length") orelse return error.NoFileLength;

            total_len += @max(0, len.inner.int);

            const path = try alloc.alloc([]const u8, chunks.inner.list.items.len + 1);

            path[0] = dirname;
            for (chunks.inner.list.items, 1..) |filename, i| {
                path[i] = filename.inner.string;
            }

            try files.append(alloc, .{
                .path = path,
                .len = @max(0, len.inner.int),
            });
        }
    } else {
        const filename = info.get("name") orelse return error.NoFileName;
        const len = info.get("length") orelse return error.NoFileLength;

        total_len += @max(0, len.inner.int);

        const path = try alloc.alloc([]const u8, 1);
        path[0] = filename.inner.string;

        try files.append(alloc, .{
            .path = path,
            .len = @max(0, len.inner.int),
        });
    }

    const pieces = info.get("pieces") orelse return error.NoPiencesField;
    const piece_len = info.get("piece length") orelse return error.NoPieceLenField;
    const private = if (info.get("private")) |p| p.inner.int == 1 else false;

    self.total_len = total_len;
    self.pieces = pieces.inner.string;
    self.piece_len = @intCast(piece_len.inner.int);
    self.private = private;
    self.files = files;
}

pub fn fromSlice(alloc: std.mem.Allocator, noalias slice: []const u8) !Torrent {
    var reader: std.Io.Reader = .fixed(slice);

    var value: Bencode = try .decode(alloc, &reader, 0);
    errdefer value.deinit(alloc);

    const dict = value.inner.dict;

    var tiers: Tiers = .empty;
    errdefer {
        for (tiers.items) |*urls| urls.deinit(alloc);
        tiers.deinit(alloc);
    }

    if (dict.get("announce-list")) |tiersV| {
        for (tiersV.inner.list.items) |tierV| {
            var announces = try tiers.addOne(alloc);
            announces.* = .empty;

            for (tierV.inner.list.items) |urlV| {
                try announces.append(alloc, try alloc.dupe(u8, urlV.inner.string));
            }
        }
    } else if (dict.get("announce")) |v| {
        var announces = try tiers.addOne(alloc);
        announces.* = .empty;

        try announces.append(alloc, try alloc.dupe(u8, v.inner.string));
    } else {
        return error.NoAnnounceUrls;
    }

    const info = if (dict.get("info")) |v| v else {
        std.log.err("expected 'info' property to exists in torrent", .{});
        return error.MissingInfo;
    };

    var torrent = Torrent{
        .value = value,
        .tiers = tiers,
        .created_by = null,
        .creation_date = null,
        .info_hash = undefined,

        .files = undefined,
        .pieces = undefined,
        .piece_len = undefined,
        .total_len = undefined,
        .private = undefined,
    };

    std.crypto.hash.Sha1.hash(slice[info.start .. info.start + info.len], &torrent.info_hash, .{});

    try torrent.inheritInfo(alloc, info.inner.dict);

    return torrent;
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
    try std.testing.expectEqualStrings("http://localhost:9000/announce", torrent.tiers.items[0].items[0]);
}

test "parseTorrent - info hash for simple torrent" {
    const file = @embedFile("./test_files/custom.torrent");

    var torrent = try fromSlice(std.testing.allocator, file);
    defer torrent.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings(
        "9e947546139508901953291490941744bf9395bc",
        &std.fmt.bytesToHex(&torrent.info_hash, .lower),
    );
}

test "parseTorrent - info hash" {
    const file = @embedFile("./test_files/custom-folder.torrent");

    var torrent = try fromSlice(std.testing.allocator, file);
    defer torrent.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings(
        "f0c4cb2d359b74a5f418344749c7441ae2639d33",
        &std.fmt.bytesToHex(&torrent.info_hash, .lower),
    );
}

pub fn fromMagnet(alloc: std.mem.Allocator, magnet: *const Magnet) !Torrent {
    var r: std.Io.Reader = .fixed(magnet.buffer.?);

    var v = try Bencode.decode(alloc, &r, 0);
    errdefer v.deinit(alloc);

    var tiers: Torrent.Tiers = try .initCapacity(alloc, 1);
    errdefer tiers.deinit(alloc);

    var urls_cloned = tiers.addOneAssumeCapacity();
    urls_cloned.* = .empty;

    try urls_cloned.ensureTotalCapacityPrecise(alloc, magnet.trackers.items.len);
    errdefer {
        for (urls_cloned.items) |x| alloc.free(x);
        urls_cloned.deinit(alloc);
    }

    for (magnet.trackers.items) |item| {
        urls_cloned.appendAssumeCapacity(try alloc.dupe(u8, item));
    }

    var rand: std.Random.DefaultPrng = .init(@intCast(std.time.microTimestamp()));
    var random = rand.random();
    random.shuffle([]const u8, urls_cloned.items);

    var torrent = Torrent{
        .value = v,
        .info_hash = magnet.info_hash,
        .created_by = null,
        .creation_date = null,
        .tiers = tiers,

        .total_len = undefined,
        .pieces = undefined,
        .piece_len = undefined,
        .private = undefined,
        .files = undefined,
    };

    try torrent.inheritInfo(alloc, v.inner.dict);

    return torrent;
}
