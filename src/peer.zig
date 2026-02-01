const std = @import("std");

const proto = @import("proto.zig");
const utils = @import("utils.zig");
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
        .allowedFast = try .initCapacity(alloc, DEFAULT_ALLOWED_FAST)
    };
}

pub fn deinit(p: *Peer, alloc: std.mem.Allocator) void {
    p.state = .dead;

    p.readBuf.deinit();
    p.writeBuf.deinit();
    p.inFlight.deinit(alloc);
    p.allowedFast.deinit(alloc);

    if (p.bitfield) |*x| x.deinit(alloc);
    if (p.workingOn) |*x| x.deinit(alloc);
    if (p.extended) |*x| x.deinit(alloc);
}

pub fn fillReadBuffer(p: *Peer, alloc: std.mem.Allocator, size: usize) !?void {
    utils.assert(size <= Torrent.BLOCK_SIZE * 10);

    if (p.readBuf.writer.end >= size) {
        return;
    }

    var list = p.readBuf.toArrayList();
    defer p.readBuf = .fromArrayList(alloc, &list);

    try list.ensureTotalCapacity(alloc, size);

    const left = size - list.items.len;
    const count = std.posix.read(p.socket, list.unusedCapacitySlice()[0..left]) catch |err| switch (err) {
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

pub fn peekInt(p: *Peer, alloc: std.mem.Allocator, comptime T: type, offset: usize) !?T {
    const n = @divExact(@typeInfo(T).int.bits, 8);

    try p.fillReadBuffer(alloc, n + offset) orelse return null;

    const buffered = p.readBuf.written();

    return std.mem.readInt(T, buffered[offset .. offset + n][0..n], .big);
}

pub fn read(p: *Peer, alloc: std.mem.Allocator, size: usize) !?[]u8 {
    try p.fillReadBuffer(alloc, size) orelse return null;

    const buffered = p.readBuf.written();
    const dupe = try alloc.dupe(u8, buffered[0..size]);
    _ = p.readBuf.writer.consume(size);

    return dupe;
}

/// returns `true` when all data was written to socket
pub fn send(p: *Peer) !bool {
    const toWrite = p.writeBuf.written();

    if (toWrite.len == 0) {
        return true;
    }

    const wrote = std.posix.write(p.socket, toWrite) catch |err| switch (err) {
        error.WouldBlock => return false,
        else => |e| return e,
    };

    _ = p.writeBuf.writer.consume(wrote);

    const stillBuffered = p.writeBuf.written();
    return stillBuffered.len == 0;
}

/// returns `true` when all data was written to socket
pub fn addMessage(p: *Peer, message: proto.Message, data: []const u8) !bool {
    utils.assert(p.state == .messageStart or p.state == .message);

    try message.writeMessage(&p.writeBuf.writer, data);

    return try p.send();
}

pub fn nextWorkingPiece(p: *Peer, pieces: *PieceManager) ?u32 {
    if (p.choked) {
        for (p.allowedFast.items) |index| {
            if (pieces.canFetch(index)) {
                std.log.debug("peer: {d} using {d} piece as allowed fast in choked", .{p.socket, index});
                return @intCast(index);
            }
        }
    } else if (p.bitfield) |bitfield| if (p.workingOn) |workingOn| {
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
pub fn addRequest(p: *Peer, piece: u32, pieceLen: u32) !enum { full, finishedPiece, next } {
    p.inFlight.push(.{
        .index = piece,
        .begin = p.workingPieceOffset,
    }) catch return .full;

    const chunkLen = @min(Torrent.BLOCK_SIZE, pieceLen - p.workingPieceOffset);

    const m: proto.Message = .{ .request = .{
        .index = piece,
        .begin = p.workingPieceOffset,
        .len = chunkLen,
    } };

    try m.writeMessage(&p.writeBuf.writer, &.{});

    p.workingPieceOffset += chunkLen;

    if (p.workingPieceOffset >= pieceLen) {
        return .finishedPiece;
    }

    return .next;
}

/// returns `true` when all data was written to socket
pub fn fillRqPool(p: *Peer, _: std.mem.Allocator, torrent: *const Torrent, pieces: *PieceManager) !bool {
    while (p.inFlight.count < p.inFlight.size) {
        const piece = p.workingPiece orelse blk: {
            p.workingPieceOffset = 0;
            p.workingPiece = p.nextWorkingPiece(pieces) orelse break;

            if (p.workingOn) |*workingOn| {
                workingOn.set(p.workingPiece.?);
            }

            break :blk p.workingPiece.?;
        };

        const len = torrent.getPieceSize(piece);
        switch (try p.addRequest(piece, len)) {
            .full => break,
            .next => {},
            .finishedPiece => {
                p.workingPiece = null;
                p.workingPieceOffset = 0;
            },
        }
    }

    return try p.send();
}

pub fn compareBytesReceived(_: void, a: *Peer, b: *Peer) bool {
    return std.math.order(a.bytesReceived, b.bytesReceived) == .gt;
}
