const std = @import("std");

const Peer = @import("peer.zig");
const Torrent = @import("torrent.zig");
const Bencode = @import("bencode.zig");
const utils = @import("utils.zig");

const Tracker = @This();

peerId: [20]u8,

infoHash: [20]u8,

uploaded: usize,

downloaded: usize,

left: usize,

numWant: usize = 100,

port: u16 = 6889,

http: ?std.http.Client = null,

oldAddrs: std.array_list.Aligned([6]u8, null) = .empty,
newAddrs: std.array_list.Aligned([6]u8, null) = .empty,

tiers: Torrent.Tiers,

initialized: ?Source = null,

const Source = struct {
    interval: usize,
    checkinAt: usize,
};

pub const defaultNumWant = 20;

pub fn init(
    alloc: std.mem.Allocator,
    peerId: [20]u8,
    infoHash: [20]u8,
    downloaded: u64,
    torrent: *const Torrent,
) !Tracker {
    var cloned: Torrent.Tiers = try .initCapacity(alloc, torrent.tiers.items.len);
    errdefer {
        for (cloned.items) |*x| x.deinit(alloc);
        cloned.deinit(alloc);
    }

    var rand: std.Random.DefaultPrng = .init(@intCast(std.time.microTimestamp()));
    var random = rand.random();

    for (torrent.tiers.items) |urls| {
        const urlsCloned = try urls.clone(alloc);

        random.shuffle([]const u8, urlsCloned.items);

        cloned.appendAssumeCapacity(urlsCloned);
    }

    return .{
        .peerId = peerId,
        .infoHash = infoHash,
        .downloaded = downloaded,
        .uploaded = 0,
        .left = torrent.totalLen - downloaded,
        .tiers = cloned,
    };
}

pub fn deinit(self: *Tracker, alloc: std.mem.Allocator) void {
    self.oldAddrs.deinit(alloc);
    self.newAddrs.deinit(alloc);

    for (self.tiers.items) |*x| x.deinit(alloc);
    self.tiers.deinit(alloc);

    if (self.http) |*x| x.deinit();
}

fn getHttp(self: *Tracker, alloc: std.mem.Allocator) !std.http.Client {
    return self.http orelse blk: {
        var client: std.http.Client = .{ .allocator = alloc };
        errdefer client.deinit();

        try client.initDefaultProxies(alloc);

        self.http = client;

        break :blk client;
    };
}

pub fn sendEvent(
    self: *Tracker,
    alloc: std.mem.Allocator,
    event: ?enum { started, stopped, completed },
    url: []const u8,
    responseWriter: ?*std.Io.Writer,
) !void {
    var http = try self.getHttp(alloc);

    var uri: std.Uri = try .parse(url);

    var newQuery = try utils.appendQuery(alloc, uri, &[_]utils.QueryParam{
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
pub fn announce(self: *Tracker, alloc: std.mem.Allocator, url: []const u8) !usize {
    var stream: std.Io.Writer.Allocating = .init(alloc);
    defer stream.deinit();

    try self.sendEvent(alloc, .started, url, &stream.writer);

    var reader: std.Io.Reader = .fixed(stream.written());

    var value: Bencode = try .decode(alloc, &reader, 0);
    defer value.deinit(alloc);

    if (value.inner.dict.get("failure reason")) |failureReason| {
        std.log.err("received err from tracker: {s}", .{failureReason.inner.string});
        return error.FailedAnnouncement;
    }

    const interval = value.inner.dict.get("interval") orelse return error.MissingInternal;
    const peers = value.inner.dict.get("peers") orelse return error.MissinPeers;

    if (peers.inner.string.len < 6) {
        return @max(0, interval.inner.int);
    }

    var window = std.mem.window(u8, peers.inner.string, 6, 6);
    outer: while (window.next()) |peerString| {
        if (@rem(peerString.len, 6) != 0) {
            std.log.err("received invalid peer string {s}", .{peerString});
            continue;
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

    std.log.debug("tracker: added {d} new addrs", .{self.newAddrs.items.len});
    try self.oldAddrs.ensureUnusedCapacity(alloc, self.newAddrs.items.len);

    return @max(0, interval.inner.int);
}

pub fn finalizeSource(self: *Tracker, alloc: std.mem.Allocator) void {
    for (self.tiers.items) |urls| {
        for (urls.items, 0..) |url, i| {
            if (!std.mem.startsWith(u8, url, "http://")) continue;

            self.sendEvent(alloc, .stopped, url, null) catch |err| {
                std.log.warn("failed announcing to {s} with {t}", .{ url, err });
                continue;
            };

            if (i != 0) {
                std.mem.swap([]const u8, &urls.items[0], &urls.items[i]);
            }

            return;
        }
    }
}

pub fn keepAlive(self: *Tracker, alloc: std.mem.Allocator) !usize {
    if (self.initialized) |source| {
        const now: usize = @intCast(std.time.milliTimestamp());

        if (now < source.checkinAt) {
            return source.checkinAt - now;
        }
    }

    for (self.tiers.items) |urls| {
        for (urls.items, 0..) |url, i| {
            if (!std.mem.startsWith(u8, url, "http://")) continue;

            const interval = self.announce(alloc, url) catch |err| {
                std.log.warn("failed announcing to {s} with {t}", .{ url, err });
                continue;
            };

            const now: usize = @intCast(std.time.milliTimestamp());
            const intervalInMs = interval * std.time.ms_per_s;

            self.initialized = .{
                .interval = intervalInMs,
                .checkinAt = now + intervalInMs,
            };

            if (i != 0) {
                std.mem.swap([]const u8, &urls.items[0], &urls.items[i]);
            }

            return intervalInMs;
        }
    }

    return error.NoSourceAvailable;
}

pub fn nextNewPeer(self: *Tracker) ?std.net.Address {
    const newPeer = self.newAddrs.pop() orelse return null;

    self.oldAddrs.appendAssumeCapacity(newPeer);

    const port = std.mem.readInt(u16, newPeer[4..6], .big);

    return std.net.Address.initIp4(newPeer[0..4].*, port);
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
