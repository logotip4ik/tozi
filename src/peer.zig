const std = @import("std");

const utils = @import("utils");
const proto = @import("proto.zig");
const Torrent = @import("torrent.zig");
const PieceManager = @import("piece-manager.zig");
const Handshake = @import("handshake.zig");

const Peer = @This();

const DEFAULT_IN_FLIGHT_REQUESTS = 50;
const DEFAULT_ALLOWED_FAST = 10;

socket: std.posix.fd_t,

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
extended: ?Handshake.Extended = null,

allowedFast: std.array_list.Aligned(u32, null),

pub const State = union(enum) {
    readHandshake,
    writeHandshake,
    messageStart,
    message: proto.Message,
    dead,
};

pub fn init(alloc: std.mem.Allocator, fd: std.posix.fd_t) !Peer {
    return .{
        .socket = fd,
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

    if (self.bitfield) |*x| x.deinit(alloc);
    if (self.workingOn) |*x| x.deinit(alloc);
    if (self.extended) |*x| x.deinit(alloc);

    std.posix.close(self.socket);
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
    const count = std.posix.read(self.socket, list.unusedCapacitySlice()[0..left]) catch |err| switch (err) {
        error.WouldBlock => return null,
        else => |e| return e,
    };

    if (count == 0) {
        return error.EndOfStream;
    }

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
    const dupe = try alloc.dupe(u8, buffered[0..size]);
    _ = self.readBuf.writer.consume(size);

    return dupe;
}

/// returns `true` when all data was written to socket
pub fn send(self: *Peer) !bool {
    const toWrite = self.writeBuf.written();

    if (toWrite.len == 0) {
        return true;
    }

    const wrote = std.posix.write(self.socket, toWrite) catch |err| switch (err) {
        error.WouldBlock => return false,
        else => |e| return e,
    };

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
    if (self.choked) {
        for (self.allowedFast.items) |index| {
            if (pieces.canFetch(index)) {
                std.log.debug("peer: {d} using {d} piece as allowed fast in choked", .{ self.socket, index });
                return @intCast(index);
            }
        }
    } else if (self.bitfield) |bitfield| if (self.workingOn) |workingOn| {
        var iter = bitfield.iterator(.{ .direction = .forward, .kind = .set });
        while (iter.next()) |index| {
            if (pieces.canFetch(index)) {
                if (pieces.isEndgame() and workingOn.isSet(index)) {
                    continue;
                }

                return @intCast(index);
            }
        }
    };

    return null;
}

// returns true if pipeline is full
pub fn addRequest(self: *Peer, piece: u32, pieceLen: u32) !enum { full, finishedPiece, next } {
    self.inFlight.push(.{
        .index = piece,
        .begin = self.workingPieceOffset,
    }) catch return .full;

    const chunkLen = @min(Torrent.BLOCK_SIZE, pieceLen - self.workingPieceOffset);

    const m: proto.Message = .{ .request = .{
        .index = piece,
        .begin = self.workingPieceOffset,
        .len = chunkLen,
    } };

    try m.writeMessage(&self.writeBuf.writer, &.{});

    self.workingPieceOffset += chunkLen;

    if (self.workingPieceOffset >= pieceLen) {
        return .finishedPiece;
    }

    return .next;
}

/// returns `true` when all data was written to socket
pub fn fillRqPool(self: *Peer, _: std.mem.Allocator, torrent: *const Torrent, pieces: *PieceManager) !bool {
    while (self.inFlight.count < self.inFlight.size) {
        const piece = self.workingPiece orelse blk: {
            self.workingPieceOffset = 0;
            self.workingPiece = self.nextWorkingPiece(pieces) orelse break;

            if (self.workingOn) |*workingOn| {
                workingOn.set(self.workingPiece.?);
            }

            break :blk self.workingPiece.?;
        };

        const len = torrent.getPieceSize(piece);
        switch (try self.addRequest(piece, len)) {
            .full => break,
            .next => {},
            .finishedPiece => {
                self.workingPiece = null;
                self.workingPieceOffset = 0;
            },
        }
    }

    return try self.send();
}

pub fn compareBytesReceived(_: void, a: *Peer, b: *Peer) bool {
    return std.math.order(a.bytesReceived, b.bytesReceived) == .gt;
}

pub fn readMessageStart(self: *Peer, alloc: std.mem.Allocator, idInt: u8, len: u32) !?proto.Message {
    const id = std.enums.fromInt(proto.MessageId, idInt) orelse {
        std.log.warn("peer: {d} unknown msg id {d}", .{ self.socket, idInt });
        return error.Dead;
    };

    const sizeOfMessageStart = id.messageStartLen();
    const messageStartBytes = self.read(alloc, sizeOfMessageStart) catch |err| switch (err) {
        error.EndOfStream => return error.Dead,
        else => |e| return e,
    } orelse return null;
    defer alloc.free(messageStartBytes);

    var reader: std.Io.Reader = .fixed(messageStartBytes);
    reader.toss(@sizeOf(u32) + @sizeOf(u8));

    return switch (id) {
        .choke => .choke,
        .unchoke => .unchoke,
        .interested => .interested,
        .notInterested => .notInterested,
        .haveAll => .haveAll,
        .haveNone => .haveNone,

        .have => .{ .have = reader.takeInt(u32, .big) catch unreachable },
        .bitfield => .{ .bitfield = len - 1 },

        .suggestPiece => .{ .suggestPiece = reader.takeInt(u32, .big) catch unreachable },
        .allowedFast => .{ .allowedFast = reader.takeInt(u32, .big) catch unreachable },

        .piece => .{ .piece = .{
            .index = reader.takeInt(u32, .big) catch unreachable,
            .begin = reader.takeInt(u32, .big) catch unreachable,
            .len = len - 9,
        } },

        .extended => .{ .extended = .{
            .id = reader.takeByte() catch unreachable,
            .len = len - 2,
        } },

        .request, .cancel, .rejectRequest => blk: {
            const index = reader.takeInt(u32, .big) catch unreachable;
            const begin = reader.takeInt(u32, .big) catch unreachable;
            const mLen = reader.takeInt(u32, .big) catch unreachable;

            if (mLen > Torrent.BLOCK_SIZE) {
                std.log.err("peer: {d} dropped (msg too big: {d})", .{ self.socket, len });
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
            } else {
                break :blk .{ .rejectRequest = .{
                    .index = index,
                    .begin = begin,
                    .len = mLen,
                } };
            }
        },

        .port => .{ .port = reader.takeInt(u16, .big) catch unreachable },
    };
}
