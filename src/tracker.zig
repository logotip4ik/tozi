const std = @import("std");

const utils = @import("utils");
const Peer = @import("peer.zig");
const Torrent = @import("torrent.zig");
const Bencode = @import("bencode.zig");

const TrackerHttp = @import("tracker-http.zig");
const TrackerUdp = @import("tracker-udp.zig");
const Stats = @import("tracker-utils.zig").Stats;
const Operation = @import("tracker-utils.zig").Operation;
const AnnounceResponse = @import("tracker-utils.zig").AnnounceResponse;

const Tracker = @This();

peerId: [20]u8,

infoHash: [20]u8,

uploaded: usize,

downloaded: usize,

left: usize,

numWant: u16 = 100,

port: u16 = 6889,

client: Client = .none,

oldAddrs: std.array_list.Aligned([6]u8, null) = .empty,
newAddrs: std.array_list.Aligned([6]u8, null) = .empty,

tiers: Torrent.Tiers,

used: Source = .{ .tier = 0, .i = 0 },

queued: Stats = undefined,

const Source = packed struct {
    tier: u32,
    i: u32,
};

const Client = union(enum) {
    none,
    http: TrackerHttp,
    udp: TrackerUdp,

    pub fn socket(self: *const Client) std.posix.socket_t {
        return switch (self.*) {
            .none => unreachable,
            inline else => |t| t.socketPosix.?.fd,
        };
    }

    pub fn deinit(self: *Client, alloc: std.mem.Allocator) void {
        switch (self.*) {
            .none => {},
            inline else => |*t| t.deinit(alloc),
        }
    }
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

    self.client.deinit(alloc);
}

pub fn addNewAddrs(self: *Tracker, alloc: std.mem.Allocator, announce: *const AnnounceResponse) !void {
    outer: for (announce.peers.items) |peerString| {
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
}

fn nextHttpOperation(self: *Tracker, alloc: std.mem.Allocator, client: *TrackerHttp) !Operation {
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
                            client.state = .prepare;

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
                .done => unreachable,
            }
        },
        .prepare => {
            try client.prepareRequest(alloc, &self.queued);

            return .write;
        },
        .send => {
            const ready = try client.sendRequest();

            if (!ready) return .write;
            return .read;
        },
        .read => {
            const content = try client.readRequest(alloc) orelse return .read;
            defer alloc.free(content);

            var announce: AnnounceResponse = .{};
            defer announce.deinit(alloc);

            try TrackerHttp.parseIntoAnnounce(alloc, content, &announce);
            try self.addNewAddrs(alloc, &announce);

            std.log.debug("received interval of {d}s", .{announce.interval});

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

            return .{ .timer = announce.interval * std.time.ms_per_s };
        },
    }
}

fn nextUdpOperation(self: *Tracker, alloc: std.mem.Allocator, client: *TrackerUdp) !Operation {
    sw: switch (client.state) {
        .prepare_connect => {
            try client.prepareConnect();
            return .write;
        },
        .send_connect => {
            try client.sendConnect() orelse return .write;

            return .read;
        },
        .read_connect => {
            try client.readConnect() orelse return .read;

            continue :sw .prepare_announce;
        },
        .prepare_announce => {
            try client.prepareAnnounce(&self.queued);

            return .write;
        },
        .send_announce => {
            try client.sendAnnounce() orelse return .write;

            return .read;
        },
        .read_announce => {
            var announce: AnnounceResponse = .{};
            defer announce.deinit(alloc);

            try client.readAnnounce(alloc, &announce) orelse return .write;

            try self.addNewAddrs(alloc, &announce);

            std.log.debug("received interval of {d}s", .{announce.interval});

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

            return .{ .timer = announce.interval * std.time.ms_per_s };
        },
    }
}

pub fn nextOperation(self: *Tracker, alloc: std.mem.Allocator) !Operation {
    return switch (self.client) {
        .http => |*t| try self.nextHttpOperation(alloc, t),
        .udp => |*t| try self.nextUdpOperation(alloc, t),
        .none => unreachable,
    };
}

pub fn enqueueEvent(self: *Tracker, alloc: std.mem.Allocator, event: @FieldType(Stats, "event")) !Operation {
    while (true) {
        const url = self.tiers.items[self.used.tier].items[self.used.i];

        if (utils.isHttp(url) or utils.isHttps(url)) {
            const client = TrackerHttp.init(alloc, url) catch |err| {
                std.log.debug("failed creating http client with {t} for {s}", .{ err, url });
                self.used = self.nextUsed() orelse return error.NoAnnounceUrlAvailable;
                continue;
            };

            self.client = .{ .http = client };

            break;
        }

        if (utils.isUdp(url)) {
            const client = TrackerUdp.init(alloc, .{ .url = url }) catch |err| {
                std.log.debug("failed creating udp client with {t} for {s}", .{ err, url });
                self.used = self.nextUsed() orelse return error.NoAnnounceUrlAvailable;
                continue;
            };

            self.client = .{ .udp = client };

            break;
        }

        self.client.deinit(alloc);
        self.used = self.nextUsed() orelse return error.NoAnnounceUrlAvailable;
    }
    errdefer {
        self.client.deinit(alloc);
        self.client = .none;
    }

    self.queued = .{
        .infoHash = self.infoHash,
        .peerId = self.peerId,
        .left = self.left,
        .downloaded = self.downloaded,
        .uploaded = self.uploaded,
        .numWant = self.numWant,
        .event = event,
    };

    return try self.nextOperation(alloc);
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

/// in milliseconds
pub fn timeout(self: *const Tracker) u32 {
    return switch (self.client) {
        .udp => |u| switch (u.state) {
            // TODO
            // .read_connect => 3000,
            // .read_announce => 15000,
            // else => 3000,
            else => 5000,
        },
        .http => |h| switch (h.state) {
            // TODO
            // .handshake => 5000,
            // .read => 10000,
            // else => 3000,
            else => 3000,
        },
        .none => unreachable,
    };
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
    _ = @import("tracker-http.zig");
    _ = @import("tracker-udp.zig");
}
