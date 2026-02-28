const std = @import("std");
const builtin = @import("builtin");

const utils = @import("utils");
const Peer = @import("peer.zig");
const Torrent = @import("torrent.zig");
const Bencode = @import("bencode.zig");
const Socket = @import("socket.zig");
const Magnet = @import("magnet.zig");

const TrackerHttp = @import("tracker-http.zig");
const TrackerUdp = @import("tracker-udp.zig");
const Stats = @import("tracker-utils.zig").Stats;
const Operation = @import("tracker-utils.zig").Operation;
const AnnounceResponse = @import("tracker-utils.zig").AnnounceResponse;

const Tracker = @This();

peer_id: [20]u8,

info_hash: [20]u8,

uploaded: usize,

downloaded: usize,

left: usize,

num_want: u16 = 100,

port: u16 = MY_PORT_DEFAULT,

client: Client = .none,

addrs_new: std.array_list.Aligned(NewAddr, null) = .empty,
addrs_old: std.array_list.Aligned(std.net.Address, null) = .empty,

tiers: Torrent.Tiers,

used: Source = .{ .tier = 0, .i = 0 },

queued: Stats = undefined,

ip_vote: IpVote = .empty,

const IpVote = std.hash_map.AutoHashMapUnmanaged([4]u8, u16);

const NewAddr = struct {
    addr: std.net.Address,
    priority: u32,

    pub fn lessThen(_: void, a: NewAddr, b: NewAddr) bool {
        return a.priority < b.priority;
    }
};

const Source = packed struct { tier: u32, i: u32 };

pub const Client = union(enum) {
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
const MY_PORT_DEFAULT = 6889;

pub fn init(
    alloc: std.mem.Allocator,
    peer_id: [20]u8,
    info_hash: [20]u8,
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
        .peer_id = peer_id,
        .info_hash = info_hash,
        .downloaded = downloaded,
        .uploaded = 0,
        .left = torrent.totalLen - downloaded,
        .tiers = cloned,
    };
}

pub fn fromMagnet(
    alloc: std.mem.Allocator,
    peerId: [20]u8,
    magnet: *const Magnet,
) !Tracker {
    var tiers: Torrent.Tiers = try .initCapacity(alloc, 1);
    errdefer tiers.deinit(alloc);

    var rand: std.Random.DefaultPrng = .init(@intCast(std.time.microTimestamp()));
    var random = rand.random();

    var urls_cloned = try magnet.trackers.clone(alloc);
    errdefer urls_cloned.deinit(alloc);

    random.shuffle([]const u8, urls_cloned.items);

    tiers.appendAssumeCapacity(urls_cloned);

    return .{
        .peer_id = peerId,
        .info_hash = magnet.info_hash,
        .downloaded = 0,
        .left = 1,
        .uploaded = 0,
        .tiers = tiers,
    };
}

pub fn deinit(self: *Tracker, alloc: std.mem.Allocator) void {
    self.addrs_old.deinit(alloc);
    self.addrs_new.deinit(alloc);
    self.ip_vote.deinit(alloc);

    for (self.tiers.items) |*x| x.deinit(alloc);
    self.tiers.deinit(alloc);

    self.client.deinit(alloc);
}

/// NOTE: after adding new address ensure `oldAddrs` have the same length as the `newAddrs`
/// NOTE: ensure to call `sortNewAddrs` after batch call
pub fn addNewAddr(self: *Tracker, alloc: std.mem.Allocator, peer: std.net.Address) !void {
    if (peer.any.family != std.posix.AF.INET) {
        return;
    }

    const ip = peer.in.sa.addr;

    // 0.0.0.0 is 0
    // 255.255.255.255 is 0xFFFFFFFF (4294967295)
    if (ip == 0 or ip == 0xFFFFFFFF) {
        return;
    }

    // Block loopback (127.0.0.1)
    if (builtin.mode != .Debug and ip == 0x0100007f) return;

    for (self.addrs_new.items) |item| if (item.addr.eql(peer)) return;
    for (self.addrs_old.items) |addr| if (addr.eql(peer)) return;

    try self.addrs_new.append(alloc, .{ .addr = peer, .priority = 0 });
}

pub fn addNewAddrs(self: *Tracker, alloc: std.mem.Allocator, peers: []const std.net.Address) !void {
    for (peers) |peer| try self.addNewAddr(alloc, peer);

    std.log.debug("tracker: added {d} new addrs", .{self.addrs_new.items.len});
    try self.addrs_old.ensureUnusedCapacity(alloc, self.addrs_new.items.len);

    if (self.myIp()) |my_ip| self.sortNewAddrs(my_ip);
}

pub fn myIp(self: *const Tracker) ?[4]u8 {
    var iter = self.ip_vote.iterator();

    var ip: ?[4]u8 = null;
    var votes: u16 = 0;

    while (iter.next()) |entry| {
        if (entry.value_ptr.* > votes) {
            ip = entry.key_ptr.*;
            votes = entry.value_ptr.*;
        }
    }

    return ip;
}

pub fn voteForIp(self: *Tracker, alloc: std.mem.Allocator, ip: [4]u8, source: enum { tracker, peer }) !void {
    const res = try self.ip_vote.getOrPut(alloc, ip);
    const points: u8 = switch (source) {
        .tracker => 5,
        .peer => 1,
    };

    if (res.found_existing) {
        res.value_ptr.* = std.math.add(u16, res.value_ptr.*, points) catch res.value_ptr.*;
    } else {
        res.value_ptr.* = points;
    }
}

pub fn sortNewAddrs(self: *Tracker, my_ip: [4]u8) void {
    for (self.addrs_new.items) |*item| {
        if (item.priority != 0) continue;
        item.priority = computeBep40Priority(
            my_ip,
            MY_PORT_DEFAULT,
            utils.addressToYourIp(item.addr) orelse continue,
            item.addr.getPort(),
        );
    }

    std.mem.sortUnstable(NewAddr, self.addrs_new.items, {}, NewAddr.lessThen);
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
            std.log.debug("received interval of {d}s", .{announce.interval});

            if (announce.external_ip) |your_ip| {
                try self.voteForIp(alloc, your_ip, .tracker);
            }

            try self.addNewAddrs(alloc, announce.peers.items);

            if (self.used.i != 0) {
                const tier = self.tiers.items[self.used.tier];
                const workingUrl = tier.items[self.used.i];

                std.mem.copyForwards(
                    []const u8,
                    tier.items[1..self.used.i],
                    tier.items[0 .. self.used.i - 1],
                );

                tier.items[0] = workingUrl;
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

            try self.addNewAddrs(alloc, announce.peers.items);

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
        .info_hash = self.info_hash,
        .peer_id = self.peer_id,
        .left = self.left,
        .downloaded = self.downloaded,
        .uploaded = self.uploaded,
        .num_want = self.num_want,
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
    const newPeer = self.addrs_new.pop() orelse return null;

    self.addrs_old.appendAssumeCapacity(newPeer.addr);

    return newPeer.addr;
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

/// Computes the BEP 40 Canonical Peer Priority between your IP/Port and a Peer's IP/Port.
/// IPs are represented as 4-byte arrays (IPv4).
pub fn computeBep40Priority(
    my_ip: [4]u8,
    my_port: u16,
    peer_ip: [4]u8,
    peer_port: u16,
) u32 {
    // 1. Fallback to ports if the IP addresses are identical
    if (std.mem.eql(u8, &my_ip, &peer_ip)) {
        var buffer: [4]u8 = undefined;

        const is_smaller = my_port < peer_port;
        std.mem.writeInt(u16, buffer[0..2], if (is_smaller) my_port else peer_port, .big);
        std.mem.writeInt(u16, buffer[2..4], if (is_smaller) peer_port else my_port, .big);

        return std.hash.crc.Crc32Iscsi.hash(&buffer);
    }

    // 2. Determine the mask based on subnet match
    var mask = [4]u8{ 0xff, 0xff, 0x55, 0x55 }; // Default mask

    if (my_ip[0] == peer_ip[0] and my_ip[1] == peer_ip[1]) {
        if (my_ip[2] == peer_ip[2]) {
            mask = [4]u8{ 0xff, 0xff, 0xff, 0xff }; // Same /24
        } else {
            mask = [4]u8{ 0xff, 0xff, 0xff, 0x55 }; // Same /16
        }
    }

    // 3. Apply the mask
    var masked_client: [4]u8 = undefined;
    var masked_peer: [4]u8 = undefined;
    for (0..4) |i| {
        masked_client[i] = my_ip[i] & mask[i];
        masked_peer[i] = peer_ip[i] & mask[i];
    }

    // 4. Sort and concatenate into an 8-byte buffer
    const client_val = std.mem.readInt(u32, &masked_client, .big);
    const peer_val = std.mem.readInt(u32, &masked_peer, .big);

    var buffer: [8]u8 = undefined;
    if (client_val < peer_val) {
        @memcpy(buffer[0..4], &masked_client);
        @memcpy(buffer[4..8], &masked_peer);
    } else {
        @memcpy(buffer[0..4], &masked_peer);
        @memcpy(buffer[4..8], &masked_client);
    }

    // 5. Calculate and return CRC32-C
    return std.hash.crc.Crc32Iscsi.hash(&buffer);
}

test "BEP 40 Official Example 1 - Different /16" {
    // Client: 123.213.32.10
    // Peer:   98.76.54.32
    // Mask applied: FF.FF.55.55
    // Expected Hash: ec2d7224
    const client_ip = [_]u8{ 123, 213, 32, 10 };
    const peer_ip = [_]u8{ 98, 76, 54, 32 };

    const priority = computeBep40Priority(client_ip, 0, peer_ip, 0);
    try std.testing.expectEqual(@as(u32, 0xec2d7224), priority);
}

test "BEP 40 Official Example 2 - Same /24" {
    // Client: 123.213.32.10
    // Peer:   123.213.32.234
    // Mask applied: FF.FF.FF.FF
    // Expected Hash: 99568189
    const client_ip = [_]u8{ 123, 213, 32, 10 };
    const peer_ip = [_]u8{ 123, 213, 32, 234 };

    const priority = computeBep40Priority(client_ip, 0, peer_ip, 0);
    try std.testing.expectEqual(@as(u32, 0x99568189), priority);
}

test {
    _ = @import("tracker-http.zig");
    _ = @import("tracker-udp.zig");
}
