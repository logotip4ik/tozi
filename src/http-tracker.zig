const std = @import("std");
const builtin = @import("builtin");

const DEFAULT_LISTENING_PORT = 6881;

const QueryParam = struct { []const u8, []const u8 };
const DiscoverPeersOpts = struct {
    peerId: []const u8,
    announce: []const u8,
    infoHash: []const u8,
    port: ?u16 = DEFAULT_LISTENING_PORT,
    uploaded: usize = 0,
    downloaded: usize = 0,
    left: usize,
};

/// caller owns memory
pub fn announce(alloc: std.mem.Allocator, opts: DiscoverPeersOpts) ![]const u8 {
    var http: std.http.Client = .{ .allocator = alloc };
    defer http.deinit();

    try http.initDefaultProxies(alloc);

    var portStringBuf: [10]u8 = undefined;
    const portString = std.fmt.bufPrint(&portStringBuf, "{d}", .{
        opts.port orelse DEFAULT_LISTENING_PORT,
    }) catch unreachable;

    const uploadedString = try std.fmt.allocPrint(alloc, "{d}", .{opts.uploaded});
    defer alloc.free(uploadedString);

    const downloadedString = try std.fmt.allocPrint(alloc, "{d}", .{opts.downloaded});
    defer alloc.free(downloadedString);

    const leftString = try std.fmt.allocPrint(alloc, "{d}", .{opts.left});
    defer alloc.free(leftString);

    const parameters = [_]QueryParam{
        .{ "info_hash", opts.infoHash },
        .{ "peer_id", opts.peerId },
        .{ "port", portString },
        .{ "uploaded", uploadedString },
        .{ "downloaded", downloadedString },
        .{ "left", leftString },
        .{ "compact", "1" },
        .{ "key", opts.peerId[16..20] },
    };

    var uri = try std.Uri.parse(opts.announce);

    const newQuery = try appendQuery(alloc, uri, &parameters);
    defer alloc.free(newQuery);

    uri.query = .{ .raw = newQuery };

    std.debug.print("sending request to {f}\n", .{uri});

    var stream: std.Io.Writer.Allocating = .init(alloc);
    errdefer stream.deinit();

    if (builtin.is_test) {
        std.debug.print("skipping actually announcing http tracker for tests\n", .{});
        return @embedFile("./test_files/http-announcement.bencode");
    }

    const res = try http.fetch(.{
        .keep_alive = false,
        .method = .GET,
        .location = .{ .uri = uri },
        .response_writer = &stream.writer,
    });

    if (res.status != .ok) {
        std.log.err("received non ok response ({s}), while fetching {f}", .{
            @tagName(res.status),
            uri,
        });
        return error.NonOkResponse;
    }

    return try alloc.realloc(stream.writer.buffer, stream.writer.end);
}

test "announce" {
    const root = @import("root.zig");
    const torrentString = @embedFile("./test_files/testing.torrent");

    var reader: std.Io.Reader = .fixed(torrentString);

    var torrent = try root.parseTorrent(std.testing.allocator, &reader);
    defer torrent.deinit(std.testing.allocator);

    const files = torrent.info.get("files") orelse unreachable;
    const totalLen = blk: {
        var sum: usize = 0;

        for (files.inner.list.items) |file| {
            const lenVal = file.inner.dict.get("length") orelse unreachable;
            sum += lenVal.inner.int;
        }

        break :blk sum;
    };

    reader.seek = 0;

    const infoHash = try torrent.computeInfoHash(&reader);

    _ = try announce(std.testing.allocator, .{
        .announce = torrent.announce,
        .infoHash = &infoHash,
        .left = totalLen,
        .downloaded = 0,
        .uploaded = 0,
        .peerId = &getPeerId(),
    });
}

fn getPeerId() [20]u8 {
    var id: [20]u8 = undefined;

    @memcpy(id[0..8], "-TZ0001-");

    var random: std.Random.DefaultPrng = .init(@intCast(std.time.milliTimestamp()));
    for (8..20) |i| {
        const char = random.random().intRangeAtMost(u8, '0', 'Z');
        id[i] = char;
    }

    return id;
}

fn appendQuery(
    alloc: std.mem.Allocator,
    url: std.Uri,
    queries: []const QueryParam,
) ![]const u8 {
    var w: std.Io.Writer.Allocating = .init(alloc);
    errdefer w.deinit();

    var writer = &w.writer;

    if (url.query) |query| {
        try query.formatRaw(writer);

        if (writer.buffer[writer.end - 1] != '&') {
            try writer.writeByte('&');
        }
    }

    for (queries, 0..) |query, i| {
        const key, const val = query;

        if (i == queries.len - 1) {
            try writer.print("{s}={s}", .{ key, val });
        } else {
            try writer.print("{s}={s}&", .{ key, val });
        }
    }

    return try alloc.realloc(writer.buffer, writer.end);
}

test "mergeQuery" {
    const url1 = try std.Uri.parse("https://toloka.ua/something?else=true");

    const query1 = try appendQuery(std.testing.allocator, url1, &.{
        .{ "port", "456" },
        .{ "compact", "1" },
    });
    defer std.testing.allocator.free(query1);

    try std.testing.expectEqualStrings("else=true&port=456&compact=1", query1);

    const url2 = try std.Uri.parse("https://toloka.ua/something");

    const query2 = try appendQuery(std.testing.allocator, url2, &.{
        .{ "port", "456" },
        .{ "compact", "1" },
    });
    defer std.testing.allocator.free(query2);

    try std.testing.expectEqualStrings("port=456&compact=1", query2);

    const url3 = try std.Uri.parse("https://toloka.ua/something?testing&");

    const query3 = try appendQuery(std.testing.allocator, url3, &.{
        .{ "port", "456" },
        .{ "compact", "1" },
    });
    defer std.testing.allocator.free(query3);

    try std.testing.expectEqualStrings("testing&port=456&compact=1", query3);
}
