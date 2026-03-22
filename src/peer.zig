const std = @import("std");

const utils = @import("utils.zig");
const proto = @import("proto.zig");
const Torrent = @import("torrent.zig");
const PieceManager = @import("piece-manager.zig");
const Handshake = @import("handshake.zig");
const Socket = @import("socket.zig");
const Pex = @import("pex.zig");

const Peer = @This();

var next_id: u32 = 0;

const DEFAULT_IN_FLIGHT_REQUESTS = 50;
const DEFAULT_ALLOWED_FAST = 10;

id: u32,

address: std.net.Address,

socket: Socket.Posix,

state: State = .writeHandshake,

choked: bool = true,

is_interested: bool = false,
is_unchoked: bool = false,

bytes_received: usize = 0,
bytes_sent: usize = 0,

buf_read: std.Io.Writer.Allocating,
buf_write: std.Io.Writer.Allocating,

bitfield: ?std.DynamicBitSetUnmanaged = null,
working_on: ?std.DynamicBitSetUnmanaged = null,

working_piece: ?u32 = null,
working_piece_offset: u32 = 0,
in_flight: utils.RqPool,

protocols: Handshake.Protocols = .{},
extended_map: Handshake.Extended.Map = .{},

allowed_fast: std.array_list.Aligned(u32, null),

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

pub fn init(alloc: std.mem.Allocator, addr: std.net.Address) !*Peer {
    const self = try alloc.create(Peer);
    errdefer alloc.destroy(self);

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

    self.* = .{
        .id = next_id,
        .address = addr,
        .socket = .init(fd),
        .buf_read = .init(alloc),
        .buf_write = .init(alloc),
        .in_flight = try .init(alloc, DEFAULT_IN_FLIGHT_REQUESTS),
        .allowed_fast = try .initCapacity(alloc, DEFAULT_ALLOWED_FAST),
    };

    next_id += 1;

    return self;
}

pub fn deinit(self: *Peer, alloc: std.mem.Allocator) void {
    self.buf_read.deinit();
    self.buf_write.deinit();
    self.in_flight.deinit(alloc);
    self.allowed_fast.deinit(alloc);
    self.pex_sent_addresses.deinit(alloc);

    if (self.bitfield) |*x| x.deinit(alloc);
    if (self.working_on) |*x| x.deinit(alloc);

    std.posix.close(self.socket.fd);
    alloc.destroy(self);
}

pub fn fillReadBuffer(self: *Peer, alloc: std.mem.Allocator, size: usize) !?void {
    utils.assert(size <= Torrent.BLOCK_SIZE * 10);

    if (self.buf_read.writer.end >= size) {
        return;
    }

    var list = self.buf_read.toArrayList();
    defer self.buf_read = .fromArrayList(alloc, &list);

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

    const buffered = self.buf_read.written();

    return std.mem.readInt(T, buffered[offset .. offset + n][0..n], .big);
}

pub fn read(self: *Peer, alloc: std.mem.Allocator, size: usize) !?[]u8 {
    try self.fillReadBuffer(alloc, size) orelse return null;

    const buffered = self.buf_read.written();

    return buffered[0..size];
}

pub fn consumeReadBuf(self: *Peer, buf: []const u8) void {
    _ = self.buf_read.writer.consume(buf.len);
}

/// returns `true` when all data was written to socket
pub fn send(self: *Peer) !bool {
    const toWrite = self.buf_write.written();

    if (toWrite.len == 0) {
        return true;
    }

    const wrote = try self.socket.interface.write(toWrite) orelse return false;

    _ = self.buf_write.writer.consume(wrote);

    const still_buffered = self.buf_write.written();
    return still_buffered.len == 0;
}

/// returns `true` when all data was written to socket
pub fn addMessage(self: *Peer, message: proto.Message, data: []const u8) !bool {
    utils.assert(self.state.isConnected());

    try message.writeMessage(&self.buf_write.writer, data);

    return try self.send();
}

pub fn writeHandshake(self: *Peer, handshake: *const Handshake) !bool {
    utils.assert(self.state == .writeHandshake);

    if (self.buf_write.written().len == 0) {
        try self.buf_write.writer.writeAll(&handshake.asBytes());
    }

    return try self.send();
}

pub fn nextWorkingPiece(self: *Peer, pieces: *PieceManager) ?u32 {
    const working_on = self.working_on orelse {
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
        for (self.allowed_fast.items) |index| {
            if (pieces.canFetch(index) and !working_on.isSet(index)) {
                return @intCast(index);
            }
        }

        return null;
    }

    if (pieces.suggestPiece()) |index| {
        if (bitfield.isSet(index) and !working_on.isSet(index)) {
            return @intCast(index);
        }
    }

    var iter = bitfield.iterator(.{
        .direction = .forward,
        .kind = .set,
    });

    while (iter.next()) |index| {
        if (pieces.canFetch(index) and !working_on.isSet(index)) {
            return @intCast(index);
        }
    }

    return null;
}

/// returns `true` when all data was written to socket
pub fn fillRqPool(self: *Peer, torrent: *const Torrent, pieces: *PieceManager) !bool {
    while (self.in_flight.count < self.in_flight.size) {
        if (pieces.isDownloadComplete()) break;

        const piece = self.working_piece orelse blk: {
            self.working_piece_offset = 0;
            self.working_piece = self.nextWorkingPiece(pieces) orelse break;

            self.working_on.?.set(self.working_piece.?);
            pieces.downloading(self.working_piece.?);

            break :blk self.working_piece.?;
        };

        const pieceLen = torrent.getPieceSize(piece);

        self.in_flight.push(.{
            .index = piece,
            .begin = self.working_piece_offset,
        }) catch break;

        const chunkLen = @min(Torrent.BLOCK_SIZE, pieceLen - self.working_piece_offset);

        const m: proto.Message = .{ .request = .{
            .index = piece,
            .begin = self.working_piece_offset,
            .len = chunkLen,
        } };

        try m.writeMessage(&self.buf_write.writer, &.{});

        self.working_piece_offset += chunkLen;

        if (self.working_piece_offset >= pieceLen) {
            self.working_piece = null;
            self.working_piece_offset = 0;
        }
    }

    return try self.send();
}

pub fn compareBytesReceived(_: void, a: *Peer, b: *Peer) bool {
    return std.math.order(a.bytes_received, b.bytes_received) == .gt;
}

pub fn readMessageStart(self: *Peer, alloc: std.mem.Allocator) !?union(enum) { keep_alive, message: proto.Message } {
    utils.assert(self.state == .messageStart);

    const len = try self.peekInt(alloc, u32, 0) orelse return null;

    if (len == 0) {
        _ = self.buf_read.writer.consume(@sizeOf(u32));

        return .keep_alive;
    }

    if (len > Torrent.BLOCK_SIZE * 2) {
        return error.MessageTooBig;
    }

    const id_int = try self.peekInt(alloc, u8, @sizeOf(u32)) orelse return null;

    const id = std.enums.fromInt(proto.MessageId, id_int) orelse {
        std.log.warn("peer: {d} unknown msg id {d}", .{ self.socket.fd, id_int });
        return error.Dead;
    };

    const message_start_size = id.messageStartLen();
    const messaage_start = try self.read(alloc, message_start_size) orelse return null;
    defer self.consumeReadBuf(messaage_start);

    var reader: std.Io.Reader = .fixed(messaage_start);
    reader.toss(@sizeOf(@TypeOf(id_int)) + @sizeOf(@TypeOf(len)));

    const message: proto.Message = switch (id) {
        .choke => .choke,
        .unchoke => .unchoke,
        .interested => .interested,
        .not_interested => .not_interested,

        .have => .{ .have = reader.takeInt(u32, .big) catch unreachable },
        .bitfield => .{ .bitfield = len - 1 },

        .piece => .{ .piece = .{
            .index = reader.takeInt(u32, .big) catch unreachable,
            .begin = reader.takeInt(u32, .big) catch unreachable,
            .len = len - 9,
        } },

        .have_all => if (self.protocols.fast) .have_all else return error.Dead,
        .have_none => if (self.protocols.fast) .have_none else return error.Dead,
        .suggest_piece => if (self.protocols.fast)
            .{ .suggest_piece = reader.takeInt(u32, .big) catch unreachable }
        else
            return error.Dead,
        .allowed_fast => if (self.protocols.fast)
            .{ .allowed_fast = reader.takeInt(u32, .big) catch unreachable }
        else
            return error.Dead,

        .request, .cancel, .reject_request => blk: {
            const index = reader.takeInt(u32, .big) catch unreachable;
            const begin = reader.takeInt(u32, .big) catch unreachable;
            const message_len = reader.takeInt(u32, .big) catch unreachable;

            if (message_len > Torrent.BLOCK_SIZE) {
                std.log.err("peer: {d} dropped (msg too big: {d})", .{ self.socket.fd, len });
                return error.Dead;
            }

            if (id == .request) {
                break :blk .{ .request = .{
                    .index = index,
                    .begin = begin,
                    .len = message_len,
                } };
            } else if (id == .cancel) {
                break :blk .{ .cancel = .{
                    .index = index,
                    .begin = begin,
                    .len = message_len,
                } };
            } else if (self.protocols.fast and id == .reject_request) {
                break :blk .{ .reject_request = .{
                    .index = index,
                    .begin = begin,
                    .len = message_len,
                } };
            } else return error.Dead;
        },

        .extended => if (self.protocols.extended)
            .{ .extended = .{
                .id = reader.takeByte() catch unreachable,
                .len = len - 2,
            } }
        else
            return error.Dead,

        .port => .{ .port = reader.takeInt(u16, .big) catch unreachable },
    };

    return .{ .message = message };
}

pub fn computePex(self: *Peer, alloc: std.mem.Allocator, other_peers: []*Peer) !Pex {
    var pex: Pex = .{};
    errdefer pex.deinit(alloc);

    outer: for (other_peers) |other_peer| {
        if (!other_peer.state.isConnected() or other_peer == self) continue;

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
    }

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
