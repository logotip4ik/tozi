const std = @import("std");

const bencode = @import("./bencode.zig");

const Torrent = struct {
    value: bencode.Value,

    announce: []const u8,
    announceList: ?[]const []const u8,
    creation_date: ?usize,
    created_by: ?[]const u8,
    info: std.StringHashMapUnmanaged(bencode.Value) = .empty,

    /// reader must be recreated to seek from start of the file
    pub fn computeInfoHash(self: Torrent, reader: *std.Io.Reader) ![std.crypto.hash.Sha1.digest_length]u8 {
        const info = self.value.inner.dict.get("info") orelse unreachable;

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

    pub fn deinit(self: *Torrent, alloc: std.mem.Allocator) void {
        self.value.deinit(alloc);
        if (self.announceList) |list| alloc.free(list);
    }
};

pub fn parseTorrent(alloc: std.mem.Allocator, reader: *std.Io.Reader) !Torrent {
    var value = try bencode.parseValue(alloc, reader, 0);
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

    return Torrent{
        .value = value,
        .announce = if (dict.get("announce")) |v|
            v.inner.string
        else if (announceList) |list| list[0] else return error.MissingAnnounceUrl,
        .announceList = announceList,
        .created_by = null,
        .creation_date = null,
        .info = if (dict.get("info")) |v| v.inner.dict else return error.MissingInfo,
    };
}

test "parseTorrent - simple" {
    const file = @embedFile("./testing.torrent");
    var reader: std.Io.Reader = .fixed(file);

    var torrent = try parseTorrent(std.testing.allocator, &reader);
    defer torrent.deinit(std.testing.allocator);
}

test "parseTorrent - info hash" {
    const file = @embedFile("./testing.torrent");
    var reader: std.Io.Reader = .fixed(file);

    var torrent = try parseTorrent(std.testing.allocator, &reader);
    defer torrent.deinit(std.testing.allocator);

    reader = .fixed(file);

    const hash = try torrent.computeInfoHash(&reader);

    try std.testing.expectEqualStrings(
        "dd08c5e0f873f31687ea4b8a6ecfd0153d6d524c",
        &std.fmt.bytesToHex(&hash, .lower),
    );
}

test {
    _ = @import("./peers.zig");
}
