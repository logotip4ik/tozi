const std = @import("std");

const Peer = @import("peer.zig");
const bencode = @import("bencode.zig");
const utils = @import("utils.zig");

const Self = @This();

peerId: [20]u8,

infoHash: [20]u8,

uploaded: usize,

downloaded: usize,

left: usize,

numWant: usize = 50,

port: u16 = 6889,

http: ?std.http.Client = null,

oldAddrs: std.array_list.Aligned([6]u8, null) = .empty,
newAddrs: std.array_list.Aligned([6]u8, null) = .empty,

trackers: std.array_list.Aligned(Tracker, null) = .empty,

const Tracker = struct {
    url: []const u8,
    interval: usize,
    checkinAt: usize,
};

pub const defaultNumWant = 20;

pub fn deinit(self: *Self, alloc: std.mem.Allocator) void {
    self.oldAddrs.deinit(alloc);
    self.newAddrs.deinit(alloc);

    for (self.trackers.items) |tracker| {
        alloc.free(tracker.url);
    }
    self.trackers.deinit(alloc);

    if (self.http) |*x| x.deinit();
}

fn getHttp(self: *Self, alloc: std.mem.Allocator) !std.http.Client {
    return self.http orelse blk: {
        var client: std.http.Client = .{ .allocator = alloc };
        errdefer client.deinit();

        try client.initDefaultProxies(alloc);

        self.http = client;

        break :blk client;
    };
}

pub fn sendAnnounce(
    self: *Self,
    alloc: std.mem.Allocator,
    url: []const u8,
    responseWriter: ?*std.Io.Writer,
    event: ?enum { started, stopped, completed },
) !void {
    var http = try self.getHttp(alloc);

    var uri: std.Uri = try .parse(url);

    var newQuery = try appendQuery(alloc, uri, &[_]QueryParam{
        .{ "info_hash", .{ .string = self.infoHash[0..20] } },
        .{ "peer_id", .{ .string = self.peerId[0..20] } },
        .{ "port", .{ .int = self.port } },
        .{ "uploaded", .{ .int = self.uploaded } },
        .{ "downloaded", .{ .int = self.downloaded } },
        .{ "left", .{ .int = self.left } },
        .{ "compact", .{ .int = 1 } },
        .{ "key", .{ .string = self.peerId[16..20] } },
        .{ "numwant", .{ .int = self.numWant } },
        .{
            "event",
            if (event) |x| .{ .string = @tagName(x) } else .skip,
        },
    });
    defer newQuery.deinit(alloc);

    uri.query = .{ .percent_encoded = newQuery.items };

    const res = try http.fetch(.{
        .method = .GET,
        .location = .{ .uri = uri },
        .keep_alive = false,
        .response_writer = responseWriter,
    });

    if (res.status != .ok) {
        return error.NonOkStatus;
    }
}

/// returns tracker interval, peers are appended to `newPeers`
pub fn announce(self: *Self, alloc: std.mem.Allocator, url: []const u8) !usize {
    var stream: std.Io.Writer.Allocating = .init(alloc);
    defer stream.deinit();

    try self.sendAnnounce(alloc, url, &stream.writer, .started);

    var reader: std.Io.Reader = .fixed(stream.written());

    var value = try bencode.parseValue(alloc, &reader, 0);
    defer value.deinit(alloc);

    if (value.inner.dict.get("failure reason")) |failureReason| {
        std.log.err("received err from tracker: {s}", .{failureReason.inner.string});
        return error.FailedAnnouncement;
    }

    const interval = value.inner.dict.get("interval") orelse return error.MissingInternal;
    const peers = value.inner.dict.get("peers") orelse return error.MissinPeers;

    if (peers.inner.string.len < 6) {
        return interval.inner.int;
    }

    var window = std.mem.window(u8, peers.inner.string, 6, 6);
    outer: while (window.next()) |peerString| {
        if (@rem(peerString.len, 6) != 0) {
            std.log.err("received invalid peer string {s}", .{peerString});
            continue;
        }

        if (self.newAddrs.items.len + self.oldAddrs.items.len >= self.numWant) {
            break;
        }

        if (peerString[0] == 0 or peerString[0] == 255) {
            continue;
        }

        for (self.newAddrs.items) |addr| {
            if (std.mem.eql(u8, addr[0..6], peerString[0..6])) {
                continue :outer;
            }
        }

        for (self.oldAddrs.items) |addr| {
            if (std.mem.eql(u8, addr[0..6], peerString[0..6])) {
                continue :outer;
            }
        }

        try self.newAddrs.append(alloc, peerString[0..6].*);
    }

    try self.oldAddrs.ensureUnusedCapacity(alloc, self.newAddrs.items.len);

    return interval.inner.int;
}

pub fn addTracker(self: *Self, alloc: std.mem.Allocator, url: []const u8) !void {
    const interval = try self.announce(alloc, url);
    const intervalInMs = interval * std.time.ms_per_s;

    const now: usize = @intCast(std.time.milliTimestamp());

    try self.trackers.append(alloc, .{
        .url = try alloc.dupe(u8, url),
        .interval = intervalInMs,
        .checkinAt = now + intervalInMs,
    });
}

pub fn keepAlive(self: *Self, alloc: std.mem.Allocator) usize {
    var now: usize = @intCast(std.time.milliTimestamp());

    for (self.trackers.items) |*tracker| {
        if (tracker.checkinAt > now and self.newAddrs.items.len + self.oldAddrs.items.len >= self.numWant) {
            continue;
        }

        const interval = self.announce(alloc, tracker.url) catch |err| {
            std.log.warn("failed sending announce request to {s} with {t}", .{tracker.url, err});
            continue;
        };

        const intervalInMs = interval * std.time.ms_per_s;

        tracker.interval = intervalInMs;
        tracker.checkinAt = now + intervalInMs;
    }

    if (self.trackers.items.len == 0) return 1800 * 1000;

    now = @intCast(std.time.milliTimestamp());

    var soonest = self.trackers.items[0].checkinAt;
    for (self.trackers.items[1..]) |tracker| {
        if (soonest > tracker.checkinAt) {
            soonest = tracker.checkinAt;
        }
    }

    if (soonest <= now) return 0;

    return soonest - now;
}

pub fn nextNewPeer(self: *Self) ?std.net.Address {
    const newPeer = self.newAddrs.pop() orelse return null;

    self.oldAddrs.appendAssumeCapacity(newPeer);

    const port = std.mem.readInt(u16, newPeer[4..6], .big);

    return std.net.Address.initIp4(newPeer[0..4].*, port);
}

const QueryValue = union(enum) {
    string: []const u8,
    int: usize,
    skip,
};

const QueryParam = struct { []const u8, QueryValue };

fn appendQuery(
    alloc: std.mem.Allocator,
    url: std.Uri,
    queries: []const QueryParam,
) !std.array_list.Aligned(u8, null) {
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

        switch (val) {
            .int => |int| {
                try writer.print("{s}=", .{key});
                try writer.print("{d}", .{int});
            },

            // default zig's query escaping is not enough...
            .string => |string| {
                try writer.print("{s}=", .{key});
                const valComp: std.Uri.Component = .{ .raw = string };
                try valComp.formatEscaped(writer);
            },

            .skip => continue,
        }

        if (i != queries.len - 1) {
            try writer.writeByte('&');
        }
    }

    return w.toArrayList();
}

test "appendQuery" {
    const url1 = try std.Uri.parse("https://toloka.ua/something?else=true");

    var query1 = try appendQuery(std.testing.allocator, url1, &.{
        .{ "port", .{ .int = 456 } },
        .{ "compact", .{ .string = "1" } },
    });
    defer query1.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("else=true&port=456&compact=1", query1.items);

    const url2 = try std.Uri.parse("https://toloka.ua/something");

    var query2 = try appendQuery(std.testing.allocator, url2, &.{
        .{ "port", .{ .int = 456 } },
        .{ "compact", .{ .string = "1" } },
    });
    defer query2.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("port=456&compact=1", query2.items);

    const url3 = try std.Uri.parse("https://toloka.ua/something?testing&");

    var query3 = try appendQuery(std.testing.allocator, url3, &.{
        .{ "port", .{ .int = 456 } },
        .{ "compact", .{ .string = "1" } },
    });
    defer query3.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("testing&port=456&compact=1", query3.items);
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
