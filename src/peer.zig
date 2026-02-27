const std = @import("std");

const utils = @import("utils");
const proto = @import("proto.zig");
const Torrent = @import("torrent.zig");
const PieceManager = @import("piece-manager.zig");
const Handshake = @import("handshake.zig");
const Socket = @import("socket.zig");
const Pex = @import("pex.zig");

const Peer = @This();

const DEFAULT_IN_FLIGHT_REQUESTS = 50;
const DEFAULT_ALLOWED_FAST = 10;

address: std.net.Address,

socket: Socket.Posix,

state: State = .writeHandshake,

choked: bool = true,

isInterested: bool = false,
isUnchoked: bool = false,

bytesReceived: usize = 0,
requestsPerTick: usize = 0,

readBuf: std.Io.Writer.Allocating,
writeBuf: std.Io.Writer.Allocating,

bitfield: ?std.DynamicBitSetUnmanaged = null,
workingOn: ?std.DynamicBitSetUnmanaged = null,

workingPiece: ?u32 = null,
workingPieceOffset: u32 = 0,
inFlight: utils.RqPool,

protocols: Handshake.Protocols = .{},
extendedMap: Handshake.Extended.Map = .{},

allowedFast: std.array_list.Aligned(u32, null),

pex_sent_addresses: std.array_list.Aligned(std.net.Address, null) = .empty,

pub const State = union(enum) {
    readHandshake,
    writeHandshake,
    messageStart,
    message: proto.Message,
    dead,

    pub fn isDead(self: *const State) bool {
        return switch (self.*) {
            .dead => true,
            else => false,
        };
    }

    pub fn isConnected(self: *const State) bool {
        return switch (self.*) {
            .message, .messageStart => true,
            else => false,
        };
    }
};

pub fn init(alloc: std.mem.Allocator, addr: std.net.Address) !Peer {
    const fd = try std.posix.socket(
        std.posix.AF.INET,
        std.posix.SOCK.STREAM | std.posix.SOCK.NONBLOCK,
        std.posix.IPPROTO.TCP,
    );
    errdefer std.posix.close(fd);

    std.log.debug("peer: {d} connecting to {f}", .{ fd, addr });
    std.posix.connect(@intCast(fd), &addr.any, addr.getOsSockLen()) catch |err| switch (err) {
        error.WouldBlock => {},
        else => return err,
    };

    return .{
        .address = addr,
        .socket = .init(fd),
        .readBuf = .init(alloc),
        .writeBuf = .init(alloc),
        .inFlight = try .init(alloc, DEFAULT_IN_FLIGHT_REQUESTS),
        .allowedFast = try .initCapacity(alloc, DEFAULT_ALLOWED_FAST),
    };
}

pub fn deinit(self: *Peer, alloc: std.mem.Allocator) void {
    self.state = .dead;

    self.readBuf.deinit();
    self.writeBuf.deinit();
    self.inFlight.deinit(alloc);
    self.allowedFast.deinit(alloc);
    self.pex_sent_addresses.deinit(alloc);

    if (self.bitfield) |*x| x.deinit(alloc);
    if (self.workingOn) |*x| x.deinit(alloc);

    std.posix.close(self.socket.fd);
}

pub fn fillReadBuffer(self: *Peer, alloc: std.mem.Allocator, size: usize) !?void {
    utils.assert(size <= Torrent.BLOCK_SIZE * 10);

    if (self.readBuf.writer.end >= size) {
        return;
    }

    var list = self.readBuf.toArrayList();
    defer self.readBuf = .fromArrayList(alloc, &list);

    try list.ensureTotalCapacity(alloc, size);

    const left = size - list.items.len;

    const count = try self.socket.interface.read(list.unusedCapacitySlice()[0..left]) orelse return null;

    list.items.len += count;

    if (list.items.len < size) {
        return null;
    }
}

pub inline fn peekInt(self: *Peer, alloc: std.mem.Allocator, comptime T: type, offset: usize) !?T {
    const n = @divExact(@typeInfo(T).int.bits, 8);

    try self.fillReadBuffer(alloc, n + offset) orelse return null;

    const buffered = self.readBuf.written();

    return std.mem.readInt(T, buffered[offset .. offset + n][0..n], .big);
}

pub fn read(self: *Peer, alloc: std.mem.Allocator, size: usize) !?[]u8 {
    try self.fillReadBuffer(alloc, size) orelse return null;

    const buffered = self.readBuf.written();

    return buffered[0..size];
}

pub fn consumeReadBuf(self: *Peer, buf: []const u8) void {
    _ = self.readBuf.writer.consume(buf.len);
}

/// returns `true` when all data was written to socket
pub fn send(self: *Peer) !bool {
    const toWrite = self.writeBuf.written();

    if (toWrite.len == 0) {
        return true;
    }

    const wrote = try self.socket.interface.write(toWrite) orelse return false;

    _ = self.writeBuf.writer.consume(wrote);

    const stillBuffered = self.writeBuf.written();
    return stillBuffered.len == 0;
}

/// returns `true` when all data was written to socket
pub fn addMessage(self: *Peer, message: proto.Message, data: []const u8) !bool {
    utils.assert(self.state == .messageStart or self.state == .message);

    try message.writeMessage(&self.writeBuf.writer, data);

    return try self.send();
}

pub fn nextWorkingPiece(self: *Peer, pieces: *PieceManager) ?u32 {
    const workingOn = self.workingOn orelse {
        @branchHint(.cold);
        std.log.err("peer: {d} doesn't have workingOn bitset", .{self.socket.fd});
        return null;
    };

    const bitfield = self.bitfield orelse {
        @branchHint(.cold);
        std.log.err("peer: {d} doesn't have bitfield bitset", .{self.socket.fd});
        return null;
    };

    if (self.choked) {
        for (self.allowedFast.items) |index| {
            if (pieces.canFetch(index) and !workingOn.isSet(index)) {
                return @intCast(index);
            }
        }

        return null;
    }

    if (pieces.suggstPiece()) |index| {
        if (bitfield.isSet(index) and !workingOn.isSet(index)) {
            return @intCast(index);
        }
    }

    var iter = bitfield.iterator(.{
        .direction = .forward,
        .kind = .set,
    });

    while (iter.next()) |index| {
        if (pieces.canFetch(index) and !workingOn.isSet(index)) {
            return @intCast(index);
        }
    }

    return null;
}

/// returns `true` when all data was written to socket
pub fn fillRqPool(self: *Peer, torrent: *const Torrent, pieces: *PieceManager) !bool {
    while (self.inFlight.count < self.inFlight.size) {
        if (pieces.isDownloadComplete()) break;

        const piece = self.workingPiece orelse blk: {
            self.workingPieceOffset = 0;
            self.workingPiece = self.nextWorkingPiece(pieces) orelse break;

            self.workingOn.?.set(self.workingPiece.?);
            pieces.downloading(self.workingPiece.?);

            break :blk self.workingPiece.?;
        };

        const pieceLen = torrent.getPieceSize(piece);

        self.inFlight.push(.{
            .index = piece,
            .begin = self.workingPieceOffset,
        }) catch break;

        const chunkLen = @min(Torrent.BLOCK_SIZE, pieceLen - self.workingPieceOffset);

        const m: proto.Message = .{ .request = .{
            .index = piece,
            .begin = self.workingPieceOffset,
            .len = chunkLen,
        } };

        try m.writeMessage(&self.writeBuf.writer, &.{});

        self.workingPieceOffset += chunkLen;

        if (self.workingPieceOffset >= pieceLen) {
            self.workingPiece = null;
            self.workingPieceOffset = 0;
        }
    }

    return try self.send();
}

pub fn compareBytesReceived(_: void, a: *Peer, b: *Peer) bool {
    return std.math.order(a.bytesReceived, b.bytesReceived) == .gt;
}

pub fn readMessageStart(self: *Peer, alloc: std.mem.Allocator, idInt: u8, len: u32) !?proto.Message {
    const id = std.enums.fromInt(proto.MessageId, idInt) orelse {
        std.log.warn("peer: {d} unknown msg id {d}", .{ self.socket.fd, idInt });
        return error.Dead;
    };

    const sizeOfMessageStart = id.messageStartLen();
    const messageStartBytes = try self.read(alloc, sizeOfMessageStart) orelse return null;
    defer self.consumeReadBuf(messageStartBytes);

    var reader: std.Io.Reader = .fixed(messageStartBytes);
    reader.toss(@sizeOf(@TypeOf(idInt)) + @sizeOf(@TypeOf(len)));

    return switch (id) {
        .choke => .choke,
        .unchoke => .unchoke,
        .interested => .interested,
        .notInterested => .notInterested,

        .have => .{ .have = reader.takeInt(u32, .big) catch unreachable },
        .bitfield => .{ .bitfield = len - 1 },

        .piece => .{ .piece = .{
            .index = reader.takeInt(u32, .big) catch unreachable,
            .begin = reader.takeInt(u32, .big) catch unreachable,
            .len = len - 9,
        } },

        .haveAll => if (self.protocols.fast) .haveAll else error.Dead,
        .haveNone => if (self.protocols.fast) .haveNone else error.Dead,
        .suggestPiece => if (self.protocols.fast)
            .{ .suggestPiece = reader.takeInt(u32, .big) catch unreachable }
        else
            error.Dead,
        .allowedFast => if (self.protocols.fast)
            .{ .allowedFast = reader.takeInt(u32, .big) catch unreachable }
        else
            error.Dead,

        .request, .cancel, .rejectRequest => blk: {
            const index = reader.takeInt(u32, .big) catch unreachable;
            const begin = reader.takeInt(u32, .big) catch unreachable;
            const mLen = reader.takeInt(u32, .big) catch unreachable;

            if (mLen > Torrent.BLOCK_SIZE) {
                std.log.err("peer: {d} dropped (msg too big: {d})", .{ self.socket.fd, len });
                return error.Dead;
            }

            if (id == .request) {
                break :blk .{ .request = .{
                    .index = index,
                    .begin = begin,
                    .len = mLen,
                } };
            } else if (id == .cancel) {
                break :blk .{ .cancel = .{
                    .index = index,
                    .begin = begin,
                    .len = mLen,
                } };
            } else if (self.protocols.fast) {
                break :blk .{ .rejectRequest = .{
                    .index = index,
                    .begin = begin,
                    .len = mLen,
                } };
            } else break :blk error.Dead;
        },

        .extended => if (self.protocols.extended)
            .{ .extended = .{
                .id = reader.takeByte() catch unreachable,
                .len = len - 2,
            } }
        else
            error.Dead,

        .port => .{ .port = reader.takeInt(u16, .big) catch unreachable },
    };
}

pub fn computePex(self: *Peer, alloc: std.mem.Allocator, other_peers: []*Peer) !Pex {
    var pex: Pex = .{};
    errdefer pex.deinit(alloc);

    outer: for (other_peers) |other_peer| if (other_peer.state.isConnected() and other_peer != self) {
        for (self.pex_sent_addresses.items) |sent| {
            if (sent.eql(other_peer.address)) continue :outer;
        }

        const seed = if (other_peer.bitfield) |bitfield|
            bitfield.count() == bitfield.bit_length
        else
            false;

        try pex.added.append(alloc, .{
            .addr = other_peer.address,
            .flags = .{
                .reachable = true,
                .seed = seed,
            },
        });
        try self.pex_sent_addresses.append(alloc, other_peer.address);
    };

    var i = self.pex_sent_addresses.items.len;
    outer: while (i > 0) {
        i -= 1;

        const sent = self.pex_sent_addresses.items[i];
        for (other_peers) |other_peer| {
            if (other_peer.state.isConnected() and other_peer.address.eql(sent)) continue :outer;
        }

        try pex.dropped.append(alloc, sent);
        _ = self.pex_sent_addresses.swapRemove(i);
    }

    return pex;
}
