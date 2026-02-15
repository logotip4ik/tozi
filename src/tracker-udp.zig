const std = @import("std");
const builtin = @import("builtin");

const utils = @import("utils");
const Socket = @import("socket.zig");
const Stats = @import("tracker-utils.zig").Stats;
const connectToAddress = @import("tracker-utils.zig").connectToAddress;
const AnnounceResponse = @import("tracker-utils.zig").AnnounceResponse;

state: State,

socket: *Socket,
socketPosix: ?Socket.Posix = null,

buffer: std.Io.Writer.Allocating,

connectionId: u64,
transactionId: u32,

lastUseTime: u64,

const TrackerUdp = @This();

const State = enum {
    prepare_connect,
    send_connect,
    read_connect,
    prepare_announce,
    send_announce,
    read_announce,
};

const Action = enum(u32) {
    connect = 0,
    announce = 1,
};

const Event = enum(u32) {
    none = 0,
    started = 1,
    stopped = 2,
    completed = 3,
};

const MAGIC = 0x41727101980;

pub fn init(
    alloc: std.mem.Allocator,
    opts: struct {
        seed: ?u64 = null,
        fd: ?std.posix.socket_t = null,
        socket: ?*Socket = null,
        url: ?[]const u8 = null,
    },
) !TrackerUdp {
    var self = TrackerUdp{
        .state = .prepare_connect,
        .lastUseTime = @intCast(std.time.microTimestamp()),
        .connectionId = undefined,
        .transactionId = undefined,
        .socket = undefined,
        .buffer = try .initCapacity(alloc, 32),
    };
    errdefer self.buffer.deinit();

    self.transactionId = generateTransactionId(opts.seed orelse self.lastUseTime);

    if (opts.fd) |fd| {
        self.socketPosix = .init(fd);
        self.socket = &self.socketPosix.?.interface;
    } else if (opts.socket) |socket| {
        self.socket = socket;
    } else if (opts.url) |url| {
        utils.assert(utils.isUdp(url));

        const uri: std.Uri = try .parse(url);

        var hostBuffer: [std.Uri.host_name_max]u8 = undefined;
        const host = try uri.getHost(&hostBuffer);
        const port: u16 = uri.port orelse return error.MissingPort;

        const list = try std.net.getAddressList(alloc, host, port);
        defer list.deinit();

        if (list.addrs.len == 0) return error.UnknownHostName;

        const socket = blk: {
            for (list.addrs) |addr| {
                break :blk connectToAddress(addr, .udp) catch |err| switch (err) {
                    error.ConnectionRefused => continue,
                    else => return err,
                };
            }
            return std.posix.ConnectError.ConnectionRefused;
        };

        self.socketPosix = .init(socket);
        self.socket = &self.socketPosix.?.interface;
    } else {
        unreachable;
    }

    return self;
}

pub fn deinit(self: *TrackerUdp, _: std.mem.Allocator) void {
    self.buffer.deinit();

    if (self.socketPosix) |x| std.posix.close(x.fd);
}

pub fn prepareConnect(self: *TrackerUdp) !void {
    utils.assert(self.state == .prepare_connect);

    const w = &self.buffer.writer;
    _ = w.consumeAll();

    try w.writeInt(u64, MAGIC, .big);
    try w.writeInt(u32, @intFromEnum(Action.connect), .big);
    try w.writeInt(u32, self.transactionId, .big);

    self.state = .send_connect;
}

pub fn sendConnect(self: *TrackerUdp) !?void {
    utils.assert(self.state == .send_connect);

    const wrote = try self.socket.write(self.buffer.written()) orelse return null;
    _ = self.buffer.writer.consume(wrote);

    if (self.buffer.writer.end != 0) return error.PacketCorrupt;

    self.state = .read_connect;
}

pub fn readConnect(self: *TrackerUdp) !?void {
    utils.assert(self.state == .read_connect);

    const message_len = 16;
    try self.buffer.ensureTotalCapacity(message_len);

    const count = try self.socket.read(self.buffer.writer.unusedCapacitySlice()[0..message_len]) orelse return null;
    self.buffer.writer.end += count;

    if (count != message_len) return error.PacketCorrupt;
    defer _ = self.buffer.writer.consumeAll();

    var r: std.Io.Reader = .fixed(self.buffer.written());

    const action = try r.takeInt(u32, .big);
    const transactionId = try r.takeInt(u32, .big);

    if (transactionId != self.transactionId) {
        return error.InvalidTransactionId;
    }

    switch (action) {
        0 => {
            const connectionId = try r.takeInt(u64, .big);
            self.connectionId = connectionId;
            self.state = .prepare_announce;
        },
        else => return error.UnexpectedAction,
    }
}

pub fn prepareAnnounce(self: *TrackerUdp, stats: *const Stats) !void {
    utils.assert(self.state == .prepare_announce);

    const w = &self.buffer.writer;
    _ = w.consumeAll();

    const key = std.mem.readInt(u32, stats.peerId[16..20], .big);

    // TODO: maybe we need to update `lastUseTime`
    self.transactionId = generateTransactionId(self.lastUseTime);

    try w.writeInt(u64, self.connectionId, .big);
    try w.writeInt(u32, @intFromEnum(Action.announce), .big);
    try w.writeInt(u32, self.transactionId, .big);

    try w.writeAll(&stats.infoHash);
    try w.writeAll(&stats.peerId);
    try w.writeInt(u64, stats.downloaded, .big);
    try w.writeInt(u64, stats.left, .big);
    try w.writeInt(u64, stats.uploaded, .big);
    try w.writeInt(u32, @intFromEnum(stats.event), .big);

    try w.writeInt(u32, 0, .big); // 84: IP address (0 = use source)
    try w.writeInt(u32, key, .big); // 88: Key (unique per client)
    try w.writeInt(i32, @intCast(stats.numWant), .big); // 92: num_want
    try w.writeInt(u16, stats.port, .big); // 96: port

    self.state = .send_announce;
}

pub fn sendAnnounce(self: *TrackerUdp) !?void {
    utils.assert(self.state == .send_announce);

    const wrote = try self.socket.write(self.buffer.written()) orelse return null;
    _ = self.buffer.writer.consume(wrote);

    if (self.buffer.writer.end != 0) return error.PacketCorrupt;

    self.state = .read_announce;
}

pub fn readAnnounce(self: *TrackerUdp, alloc: std.mem.Allocator, announce: *AnnounceResponse) !?void {
    utils.assert(self.state == .read_announce);

    const max_message_len = 4 * 1024;
    try self.buffer.ensureTotalCapacity(max_message_len);

    const count = try self.socket.read(self.buffer.writer.unusedCapacitySlice()[0..max_message_len]) orelse return null;
    self.buffer.writer.end += count;

    if (count < 20) return error.PacketCorrupt;

    var r: std.Io.Reader = .fixed(self.buffer.written());

    const action = try r.takeInt(u32, .big);
    const transactionId = try r.takeInt(u32, .big);

    if (transactionId != self.transactionId) {
        return error.InvalidTransactionId;
    }

    switch (action) {
        1 => {
            announce.interval = try r.takeInt(u32, .big);
            announce.incomplete = try r.takeInt(u32, .big);
            announce.complete = try r.takeInt(u32, .big);

            const peersLen = count - 20;
            if (@rem(peersLen, 6) != 0) {
                return error.InvalidPeers;
            }

            while (r.take(6) catch null) |peerString| {
                const buf = try announce.peers.addOne(alloc);
                @memcpy(buf[0..6], peerString[0..6]);
            }
        },
        2 => return error.WarningMessage,
        3 => return error.Error,
        else => return error.UnexpectedAction,
    }
}

fn generateTransactionId(seed: u64) u32 {
    var prng: std.Random.DefaultPrng = .init(seed);
    const rand = prng.random();
    return rand.int(u32);
}

test "prepareConnect" {
    const alloc = std.testing.allocator;

    var socket: Socket.Allocating = .init(alloc, 16);
    defer socket.deinit();

    var t: TrackerUdp = try .init(alloc, .{
        .seed = 1,
        .socket = &socket.interface,
    });
    defer t.deinit(alloc);

    try t.prepareConnect();

    try std.testing.expectEqual(.send_connect, t.state);

    const written = t.buffer.written();
    try std.testing.expectEqual(16, written.len);

    var r: std.Io.Reader = .fixed(written);

    const protocolId = try r.takeInt(u64, .big);
    try std.testing.expectEqual(0x41727101980, protocolId);

    const action = try r.takeInt(u32, .big);
    try std.testing.expectEqual(0, action);

    const transactionId = try r.takeInt(u32, .big);
    try std.testing.expect(t.transactionId == transactionId);
}

test "prepareAnnounce" {
    const alloc = std.testing.allocator;

    var socket: Socket.Allocating = .init(alloc, 1024);
    defer socket.deinit();

    var t: TrackerUdp = try .init(alloc, .{
        .seed = 1,
        .socket = &socket.interface,
    });
    defer t.deinit(alloc);

    t.connectionId = 0x123456789ABCDEF0;
    t.state = .prepare_announce;

    var infoHash: [20]u8 = undefined;
    @memcpy(&infoHash, &([_]u8{1} ** 20));
    var peerId: [20]u8 = undefined;
    @memcpy(&peerId, &([_]u8{2} ** 20));

    const stats: Stats = .{
        .infoHash = infoHash,
        .peerId = peerId,
        .port = 6881,
        .downloaded = 100,
        .uploaded = 50,
        .left = 200,
        .numWant = 50,
        .event = .started,
    };

    try t.prepareAnnounce(&stats);

    try std.testing.expectEqual(.send_announce, t.state);

    const written = t.buffer.written();
    try std.testing.expectEqual(98, written.len);

    var reader: std.Io.Reader = .fixed(written);
    reader.toss(16);

    const infoHashOut = reader.take(20) catch unreachable;
    try std.testing.expectEqualSlices(u8, &([_]u8{1} ** 20), infoHashOut);

    const peerIdOut = reader.take(20) catch unreachable;
    try std.testing.expectEqualSlices(u8, &([_]u8{2} ** 20), peerIdOut);

    const downloaded = reader.takeInt(u64, .big);
    try std.testing.expectEqual(@as(u64, 100), downloaded);

    const left = reader.takeInt(u64, .big);
    try std.testing.expectEqual(@as(u64, 200), left);

    const uploaded = reader.takeInt(u64, .big);
    try std.testing.expectEqual(@as(u64, 50), uploaded);

    const event = reader.takeInt(u32, .big);
    try std.testing.expectEqual(@as(u32, 2), event);
}

test "readConnect response" {
    const alloc = std.testing.allocator;

    var socket: Socket.Allocating = .init(alloc, 16);
    defer socket.deinit();

    var t: TrackerUdp = try .init(alloc, .{
        .seed = 1,
        .socket = &socket.interface,
    });
    defer t.deinit(alloc);

    t.state = .read_connect;

    const expectedTransactionId = t.transactionId;
    const connection_id = 0x123456789ABCDEF0;

    var response: [16]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&response);

    writer.writeInt(u32, 0, .big) catch unreachable;
    writer.writeInt(u32, expectedTransactionId, .big) catch unreachable;
    writer.writeInt(u64, connection_id, .big) catch unreachable;

    try socket.addInBytes(&response);

    try t.readConnect() orelse unreachable;

    try std.testing.expectEqual(connection_id, t.connectionId);
    try std.testing.expectEqual(.prepare_announce, t.state);
}

test "readAnnounce response" {
    const alloc = std.testing.allocator;

    var socket: Socket.Allocating = .init(alloc, 1024);
    defer socket.deinit();

    var t: TrackerUdp = try .init(alloc, .{
        .seed = 1,
        .socket = &socket.interface,
    });
    defer t.deinit(alloc);

    t.state = .read_announce;
    t.transactionId = 1;

    var response: [32]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&response);

    writer.writeInt(u32, 1, .big) catch unreachable;
    writer.writeInt(u32, 1, .big) catch unreachable;
    writer.writeInt(u32, 300, .big) catch unreachable;
    writer.writeInt(u32, 10, .big) catch unreachable;
    writer.writeInt(u32, 5, .big) catch unreachable;
    writer.writeAll(&[_]u8{ 192, 168, 1, 1, 0x1A, 0xE1 }) catch unreachable;
    writer.writeAll(&[_]u8{ 192, 168, 1, 2, 0x1A, 0xE2 }) catch unreachable;

    try socket.addInBytes(&response);

    var announce: AnnounceResponse = .{};
    defer announce.deinit(alloc);

    _ = try t.readAnnounce(alloc, &announce);

    try std.testing.expectEqual(2, announce.peers.items.len);
    try std.testing.expectEqual(300, announce.interval);
    try std.testing.expectEqual(10, announce.incomplete.?);
    try std.testing.expectEqual(5, announce.complete.?);

    try std.testing.expectEqualSlices(u8, &[_]u8{ 192, 168, 1, 1, 0x1A, 0xE1 }, &announce.peers.items[0]);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 192, 168, 1, 2, 0x1A, 0xE2 }, &announce.peers.items[1]);
}
