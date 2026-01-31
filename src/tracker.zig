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

sources: std.array_list.Aligned([]const u8, null) = .empty,

initialized: ?Source = null,

const Source = struct {
    url: []const u8,
    interval: usize,
    checkinAt: usize,
};

pub const defaultNumWant = 20;

pub fn init(
    peerId: [20]u8,
    infoHash: [20]u8,
    downloaded: u64,
    totalLen: u64,
) Self {
    return .{
        .peerId = peerId,
        .infoHash = infoHash,
        .downloaded = downloaded,
        .uploaded = 0,
        .left = totalLen - downloaded,
    };
}

pub fn deinit(self: *Self, alloc: std.mem.Allocator) void {
    self.oldAddrs.deinit(alloc);
    self.newAddrs.deinit(alloc);

    for (self.sources.items) |url| alloc.free(url);
    self.sources.deinit(alloc);

    if (self.initialized) |x| alloc.free(x.url);
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

pub fn addTrackers(self: *Self, alloc: std.mem.Allocator, urls: *const []const []const u8) !void {
    for (urls.*) |url| {
        try self.sources.append(alloc, try alloc.dupe(u8, url));
    }

    self.initialized = try self.initializeSource(alloc);
}

pub fn initializeSource(self: *Self, alloc: std.mem.Allocator) !?Source {
    while (self.sources.items.len > 0) {
        const source = self.sources.pop() orelse unreachable;

        const interval = self.announce(alloc, source) catch |err| {
            @branchHint(.unlikely);

            std.log.warn("failed announcing to {s} with {t}", .{ source, err });
            alloc.free(source);

            continue;
        };

        const intervalInMs = interval * std.time.ms_per_s;
        const now: usize = @intCast(std.time.milliTimestamp());

        return .{
            .url = source,
            .interval = intervalInMs,
            .checkinAt = now + intervalInMs,
        };
    }

    return null;
}

pub fn finalizeSource(self: *Self, alloc: std.mem.Allocator) void {
    const source = self.initialized orelse return;

    self.sendAnnounce(alloc, source.url, null, .stopped) catch {};
}

pub fn keepAlive(self: *Self, alloc: std.mem.Allocator) !usize {
    if (self.initialized) |*source| {
        const now: usize = @intCast(std.time.milliTimestamp());

        if (now < source.checkinAt) {
            return source.checkinAt - now;
        }

        // TODO: add retries
        const interval = self.announce(alloc, source.url) catch |err| {
            std.log.warn("failed announcing to {s} with {t}", .{ source.url, err });
            alloc.free(source.url);

            const new = try self.initializeSource(alloc) orelse return error.NoSourceAvailable;
            self.initialized = new;

            return new.interval;
        };

        const intervalInMs = interval * std.time.ms_per_s;

        source.interval = intervalInMs;
        source.checkinAt = now + intervalInMs;

        return intervalInMs;
    }

    const source = try self.initializeSource(alloc) orelse return error.NoSourceAvailable;
    self.initialized = source;

    return source.interval;
}

pub fn nextNewPeer(self: *Self) ?std.net.Address {
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
