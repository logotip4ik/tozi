const std = @import("std");

const utils = @import("utils");
const Peer = @import("peer.zig");
const Torrent = @import("torrent.zig");
const Bencode = @import("bencode.zig");

const HttpTracker = @import("./http-tracker.zig");

const Tracker = @This();

peerId: [20]u8,

infoHash: [20]u8,

uploaded: usize,

downloaded: usize,

left: usize,

numWant: u16 = 100,

port: u16 = 6889,

client: union(enum) { none, http: HttpTracker } = .none,

oldAddrs: std.array_list.Aligned([6]u8, null) = .empty,
newAddrs: std.array_list.Aligned([6]u8, null) = .empty,

tiers: Torrent.Tiers,

used: Source = .{ .tier = 0, .i = 0 },

queued: HttpTracker.Stats = undefined,

const Source = packed struct {
    tier: u32,
    i: u32,
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

    switch (self.client) {
        .none => {},
        .http => |*t| t.deinit(alloc),
    }
}

pub fn addNewAddrs(self: *Tracker, alloc: std.mem.Allocator, bytes: []const u8) !usize {
    var reader: std.Io.Reader = .fixed(bytes);

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

/// TODO: make finalize source
pub fn finalizeSource(self: *Tracker, alloc: std.mem.Allocator) void {
    _ = self;
    _ = alloc;
    // for (self.tiers.items) |urls| {
    //     for (urls.items, 0..) |url, i| {
    //         if (!std.mem.startsWith(u8, url, "http://")) continue;
    //
    //         self.sendEvent(alloc, .stopped, url, null) catch |err| {
    //             std.log.warn("failed announcing to {s} with {t}", .{ url, err });
    //             continue;
    //         };
    //
    //         if (i != 0) {
    //             std.mem.swap([]const u8, &urls.items[0], &urls.items[i]);
    //         }
    //
    //         return;
    //     }
    // }
}

pub const Operation = union(enum) {
    read,
    write,
    timer: u32,
};

fn nextHttpOperation(self: *Tracker, alloc: std.mem.Allocator, client: *HttpTracker) !Operation {
    sw: switch (client.state) {
        .handshake => {
            const handshake = try client.tlsHandshake(alloc);

            switch (handshake.state) {
                .write => {
                    try handshake.write();

                    return switch (handshake.state) {
                        .read => .read,
                        .write => .write,
                        .done => |cipher| {
                            handshake.deinit(alloc);

                            std.log.debug("received tls cipher for {s}", .{client.url});
                            client.tls = .{ .connection = .init(cipher) };
                            client.state = .prepareRequest;

                            continue :sw client.state;
                        },
                    };
                },
                .read => {
                    try handshake.read();

                    return switch (handshake.state) {
                        .read => .read,
                        .write => .write,
                        .done => unreachable,
                    };
                },
                .done => unreachable
            }
        },
        .prepareRequest => {
            try client.prepareRequest(alloc, &self.queued);

            return .write;
        },
        .sendingRequest => {
            const ready = try client.sendRequest();

            if (!ready) return .write;
            return .read;
        },
        .readingRequest => {
            const content = try client.readRequest(alloc) orelse return .read;
            defer alloc.free(content);

            const interval = try self.addNewAddrs(alloc, content);
            std.log.debug("received interval of {d}", .{interval});

            if (self.used.i != 0) {
                const tier = self.tiers.items[self.used.tier];
                const workingUrl = tier.items[self.used.i];

                std.mem.copyForwards(
                    []const u8,
                    tier.items[1..self.used.i],
                    tier.items[0 .. self.used.i - 1],
                );

                tier.items[0] = workingUrl;

                std.log.debug("updated tier: {any}", .{tier});
            }

            client.deinit(alloc);
            self.client = .none;
            self.used.tier = 0;
            self.used.i = 0;

            return .{ .timer = @intCast(interval) };
        },
    }
}

pub fn enqueueKeepAlive(self: *Tracker, alloc: std.mem.Allocator) !Operation {
    while (true) {
        const url = self.tiers.items[self.used.tier].items[self.used.i];
        const client = HttpTracker.init(alloc, url) catch {
            self.used = self.nextUsed() orelse return error.NoAnnounceUrlAvailable;
            continue;
        };

        self.client = .{ .http = client };
        break;
    }

    errdefer switch (self.client) {
        .http => |*t| {
            t.deinit(alloc);
            self.client = .none;
        },
        .none => {},
    };

    self.queued = .{
        .infoHash = self.infoHash,
        .peerId = self.peerId,
        .left = self.left,
        .downloaded = self.downloaded,
        .uploaded = self.uploaded,
        .numWant = self.numWant,
    };

    return try self.nextOperation(alloc);
}

pub fn nextOperation(self: *Tracker, alloc: std.mem.Allocator) !Operation {
    return switch (self.client) {
        .http => |*t| try self.nextHttpOperation(alloc, t),
        .none => unreachable,
    };
}

pub fn socket(self: *const Tracker) std.posix.socket_t {
    return switch (self.client) {
        .http => |t| t.socket,
        .none => unreachable,
    };
}

pub fn nextUsed(self: *Tracker) ?Source {
    for (self.tiers.items[self.used.tier..], 0..) |urls, tier| {
        if (self.used.tier == tier) {
            const maxIInTier = urls.items.len;

            if (self.used.i + 1 < maxIInTier) {
                self.used.i += 1;

                return self.used;
            }
        } else if (urls.items.len > 0) {
            self.used.tier = @intCast(tier);
            self.used.i = 0;

            return self.used;
        }
    }

    return null;
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

test {
    _ = @import("http-tracker.zig");
}
