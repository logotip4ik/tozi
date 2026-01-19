const std = @import("std");

const proto = @import("proto.zig");
const utils = @import("utils.zig");
const Torrent = @import("torrent.zig");
const PieceManager = @import("piece-manager.zig");

const Peer = @This();

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
        .inFlight = try .init(alloc, 32),
    };
}

pub fn deinit(p: *Peer, alloc: std.mem.Allocator) void {
    p.state = .dead;

    p.readBuf.deinit();
    p.writeBuf.deinit();
    p.inFlight.deinit(alloc);

    if (p.bitfield) |*x| x.deinit(alloc);
    if (p.workingOn) |*x| x.deinit(alloc);
}

pub fn setBitfield(p: *Peer, alloc: std.mem.Allocator, bytes: []const u8) !void {
    var bitfield: std.DynamicBitSetUnmanaged = try .initEmpty(alloc, bytes.len * 8);
    defer p.bitfield = bitfield;

    for (bytes, 0..) |byte, i| {
        for (0..8) |bit_idx| {
            // Check if bit is set (MSB first), thank you gemini, but i don't get what this does
            const is_set = (byte >> @intCast(7 - bit_idx)) & 1 != 0;

            // Calculate absolute piece index
            const piece_index = (i * 8) + bit_idx;

            if (piece_index < bitfield.capacity() and is_set) {
                bitfield.set(piece_index);
            }
        }
    }
}

pub fn fillReadBuffer(p: *Peer, alloc: std.mem.Allocator, size: usize) !?void {
    // utils.assert(size <= Torrent.BLOCK_SIZE * 2);

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

/// this is highly coupled with `addRequest`. This function expects to clear `workingPiece` when
/// needed
pub fn getNextWorkingPiece(p: *Peer, pieces: *PieceManager) ?u32 {
    const piece = p.workingPiece orelse blk: {
        p.workingPieceOffset = 0;
        p.workingPiece = pieces.getWorkingPiece(p.bitfield orelse return null) orelse return null;
        break :blk p.workingPiece.?;
    };
    if (p.workingOn) |*x| x.set(piece);
    return piece;
}

// returns true if pipeline is full
pub fn addRequest(p: *Peer, _: std.mem.Allocator, piece: u32, pieceLen: u32) !bool {
    const chunkLen = @min(Torrent.BLOCK_SIZE, pieceLen - p.workingPieceOffset);

    p.inFlight.push(.{
        .index = piece,
        .begin = p.workingPieceOffset,
    }) catch return true;

    const m: proto.Message = .{ .request = .{
        .index = piece,
        .begin = p.workingPieceOffset,
        .len = chunkLen,
    } };

    try m.writeMessage(&p.writeBuf.writer, &.{});

    p.workingPieceOffset += chunkLen;

    if (p.workingPieceOffset >= pieceLen) {
        p.workingPiece = null;
        p.workingPieceOffset = 0;
    }

    return false;
}

/// returns `true` when all data was written to socket
pub fn fillRqPool(p: *Peer, alloc: std.mem.Allocator, torrent: Torrent, pieces: *PieceManager) !bool {
    while (p.inFlight.count < p.inFlight.size) {
        const piece = p.getNextWorkingPiece(pieces) orelse break;
        const len = torrent.getPieceSize(piece);

        if (try p.addRequest(alloc, piece, len)) {
            break;
        }
    }

    return try p.send();
}

pub fn compareBytesReceived(_: void, a: *Peer, b: *Peer) bool {
    return std.math.order(a.bytesReceived, b.bytesReceived) == .gt;
}
