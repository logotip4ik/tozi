const std = @import("std");
const builtin = @import("builtin");

const bencode = @import("bencode.zig");
const Torrent = @import("torrent.zig");

const DEFAULT_LISTENING_PORT = 6882;

const QueryParam = struct { []const u8, []const u8 };
const GetAnnounceOpts = struct {
    peerId: []const u8,
    announce: []const u8,
    infoHash: []const u8,
    port: ?u16 = DEFAULT_LISTENING_PORT,
    uploaded: usize = 0,
    downloaded: usize = 0,
    left: usize,
};

/// caller owns memory
fn getAnnounce(alloc: std.mem.Allocator, opts: GetAnnounceOpts) ![]const u8 {
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

    if (builtin.is_test) {
        std.debug.print("skipping sending announce request to {f}\n", .{uri});
        return try alloc.dupe(u8, @embedFile("./test_files/announce.bencode"));
    }

    std.debug.print("sending request to {f}\n", .{uri});

    var stream: std.Io.Writer.Allocating = .init(alloc);
    errdefer stream.deinit();

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

test "getAnnounce" {
    const torrentString = @embedFile("./test_files/custom.torrent");

    var torrent: Torrent = try .fromSlice(std.testing.allocator, torrentString);
    defer torrent.deinit(std.testing.allocator);

    const announcement = try getAnnounce(std.testing.allocator, .{
        .announce = torrent.announce,
        .infoHash = &torrent.infoHash,
        .left = torrent.totalLen,
        .downloaded = 0,
        .uploaded = 0,
        .peerId = &generatePeerId(),
    });
    defer std.testing.allocator.free(announcement);
}

const Peer = struct {
    value: [6]u8,
    address: std.net.Ip4Address,

    pub fn init(buff: *const [6]u8) Peer {
        var peer: Peer = undefined;

        @memcpy(&peer.value, buff);

        const ip = peer.value[0..4];
        const port = std.mem.readInt(u16, peer.value[4..6], .big);

        peer.address = .init(ip, port);

        return peer;
    }

    pub fn format(self: Peer, w: *std.Io.Writer) !void {
        try self.address.format(w);
    }
};
const Peers = std.array_list.Aligned(std.net.Address, null);

pub fn getPeers(alloc: std.mem.Allocator, peerId: [20]u8, torrent: Torrent) !Peers {
    const announcement = try getAnnounce(alloc, .{
        .peerId = &peerId,
        .uploaded = 0,
        .downloaded = 0,
        .left = torrent.totalLen,
        .infoHash = &torrent.infoHash,
        .announce = torrent.announce,
    });
    defer alloc.free(announcement);

    var announceReader: std.Io.Reader = .fixed(announcement);
    var value = try bencode.parseValue(alloc, &announceReader, 0);
    defer value.deinit(alloc);

    const peers = value.inner.dict.get("peers") orelse {
        std.log.err("expected 'peers' property to exists", .{});
        return error.NoPeersField;
    };

    const peersNum = @divExact(peers.inner.string.len, 6);
    var peersArray: Peers = try .initCapacity(alloc, peersNum);
    errdefer peersArray.deinit(alloc);

    var window = std.mem.window(u8, peers.inner.string, 6, 6);
    var i: u32 = 0;
    while (window.next()) |peerString| : (i += 1) {
        std.debug.assert(peerString.len == 6);

        const port = std.mem.readInt(u16, peerString[4..6], .big);

        peersArray.appendAssumeCapacity(.initIp4(peerString[0..4].*, port));
    }

    return peersArray;
}

test "getPeers" {
    const file = @embedFile("./test_files/custom.torrent");

    var torrent: Torrent = try .fromSlice(std.testing.allocator, file);
    defer torrent.deinit(std.testing.allocator);

    const peerId = generatePeerId();

    var peers = try getPeers(std.testing.allocator, peerId, torrent);
    defer peers.deinit(std.testing.allocator);

    var writer: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer writer.deinit();

    for (peers.items) |peer| {
        try writer.writer.print("{f}\n", .{peer});
    }

    try std.testing.expectEqualStrings(
        \\192.168.97.1:6881
        \\127.0.0.1:9000
        \\
    , writer.writer.buffered());
}

pub fn generatePeerId() [20]u8 {
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
