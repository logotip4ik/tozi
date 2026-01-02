const std = @import("std");
const bencode = @import("bencode.zig");

pub const Torrent = struct {
    value: bencode.Value,

    announce: []const u8,
    info: std.StringHashMapUnmanaged(bencode.Value) = .empty,
    infoHash: [std.crypto.hash.Sha1.digest_length]u8,
    totalLen: usize,

    announceList: ?[]const []const u8,
    creation_date: ?usize,
    created_by: ?[]const u8,

    /// reader must be recreated to seek from start of the file
    pub fn deinit(self: *Torrent, alloc: std.mem.Allocator) void {
        self.value.deinit(alloc);
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
    const files = info.inner.dict.get("files") orelse {
        std.log.err("expected 'files' property to exists in torrent", .{});
        return error.NoFiles;
    };

    const totalLen = blk: {
        var sum: usize = 0;

        for (files.inner.list.items) |file| {
            const lenVal = file.inner.dict.get("length") orelse unreachable;
            sum += lenVal.inner.int;
        }

        break :blk sum;
    };

    reader.seek = 0;
    const infoHash = try computeInfoHash(info, &reader);

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
        .info = info.inner.dict,
        .infoHash = infoHash,
        .totalLen = totalLen,
    };
}

test "parseTorrent - simple" {
    const file = @embedFile("./test_files/testing.torrent");

    var torrent = try parseTorrentFromSlice(std.testing.allocator, file);
    defer torrent.deinit(std.testing.allocator);
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
