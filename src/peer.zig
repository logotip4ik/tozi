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

readBuf: std.array_list.Aligned(u8, null) = .empty,

writeBuf: std.Io.Writer.Allocating,

bitfield: ?std.DynamicBitSetUnmanaged = null,
workingOn: ?std.DynamicBitSetUnmanaged = null,

workingPiece: ?u32 = null,
workingPieceOffset: u32 = 0,
inFlight: utils.RqPool(32) = .{},

pub const State = union(enum) {
    readHandshake,
    writeHandshake,
    messageStart,
    message: proto.Message,
    dead,
};

pub fn init(alloc: std.mem.Allocator, fd: std.posix.fd_t) !Peer {
    return .{ .socket = fd, .writeBuf = .init(alloc) };
}

pub fn deinit(p: *Peer, alloc: std.mem.Allocator) void {
    p.state = .dead;

    p.readBuf.deinit(alloc);
    p.writeBuf.deinit();

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

pub fn addMessage(p: *Peer, message: proto.Message, data: []const u8) !void {
    try message.writeMessage(&p.writeBuf.writer, data);
}

pub fn readInt(p: *Peer, comptime T: type) !T {
    const n = @divExact(@typeInfo(T).int.bits, 8);
    var buf: [n]u8 = undefined;

    var total: usize = 0;
    while (total != n) {
        const count = std.posix.read(p.socket, buf[total..n]) catch |err| switch (err) {
            error.WouldBlock => 0,
            else => return err,
        };

        total += count;
    }

    return std.mem.readInt(T, &buf, .big);
}

pub fn read(p: *Peer, alloc: std.mem.Allocator, size: usize) !?[]u8 {
    if (p.readBuf.items.len >= size) {
        return p.readBuf.items[0..size];
    }

    try p.readBuf.ensureTotalCapacity(alloc, size);

    const slice = p.readBuf.allocatedSlice();
    const len = p.readBuf.items.len;
    const count = std.posix.read(p.socket, slice[len..size]) catch |err| switch (err) {
        error.WouldBlock => return null,
        else => |e| return e,
    };

    p.readBuf.items.len += count;

    if (p.readBuf.items.len >= size) {
        return p.readBuf.items[0..size];
    }

    return null;
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
    if (p.writeBuf.writer.end == 0) {
        return true;
    }

    return false;
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
pub fn addRequest(p: *Peer, _: std.mem.Allocator, piece: u32, pieceLen: u32) bool {
    const chunkLen = @min(Torrent.BLOCK_SIZE, pieceLen - p.workingPieceOffset);

    p.inFlight.push(.{
        .pieceIndex = piece,
        .begin = p.workingPieceOffset,
    }) catch return true;

    p.addMessage(.{ .request = .{
        .index = piece,
        .begin = p.workingPieceOffset,
        .len = chunkLen,
    } }, &.{}) catch {
        p.inFlight.receive(.{
            .pieceIndex = piece,
            .begin = p.workingPieceOffset,
        }) catch unreachable;
        return true;
    };

    p.workingPieceOffset += chunkLen;

    if (p.workingPieceOffset >= pieceLen) {
        p.workingPiece = null;
        p.workingPieceOffset = 0;
    }

    return false;
}

pub fn fillRqPool(p: *Peer, alloc: std.mem.Allocator, torrent: Torrent, pieces: *PieceManager) void {
    while (p.inFlight.count < p.inFlight.size) {
        const piece = p.getNextWorkingPiece(pieces) orelse break;
        const len = torrent.getPieceSize(piece);

        if (p.addRequest(alloc, piece, len)) {
            break;
        }
    }
}

pub fn compareBytesReceived(_: void, a: *Peer, b: *Peer) bool {
    return std.math.order(a.bytesReceived, b.bytesReceived) == .gt;
}
