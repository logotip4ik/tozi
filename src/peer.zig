const std = @import("std");

const proto = @import("proto.zig");
const utils = @import("utils.zig");
const Torrent = @import("torrent.zig");
const PieceManager = @import("piece-manager.zig");

const Peer = @This();

socket: std.posix.fd_t,

state: State = .writeHandshake,

choked: bool = true,
interested: bool = false,

buf: std.array_list.Aligned(u8, null) = .empty,

bitfield: ?std.DynamicBitSetUnmanaged = null,
workingOn: ?std.DynamicBitSetUnmanaged = null,

mq: utils.Queue(proto.Message, 16) = .{},

workingPiece: ?u32 = null,
workingPieceOffset: u32 = 0,
inFlight: utils.RqPool(5) = .{},

pub const State = union(enum) {
    readHandshake,
    writeHandshake,
    messageStart,
    message: proto.Message,
    bufFlush,
    dead,
};

pub fn init(addr: std.net.Address) !Peer {
    const fd = try std.posix.socket(
        std.posix.AF.INET,
        std.posix.SOCK.STREAM | std.posix.SOCK.NONBLOCK,
        std.posix.IPPROTO.TCP,
    );
    errdefer std.posix.close(fd);

    std.log.info("peer: {d} connecting to {f}", .{ fd, addr });

    std.posix.connect(@intCast(fd), &addr.any, addr.getOsSockLen()) catch |err| switch (err) {
        error.WouldBlock => {},
        else => return err,
    };

    return .{ .socket = fd };
}

pub fn deinit(p: *Peer, alloc: std.mem.Allocator) void {
    p.state = .dead;

    std.posix.close(p.socket);
    p.buf.deinit(alloc);
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

pub fn readTotalBuf(p: *Peer, alloc: std.mem.Allocator, size: usize) !?[]u8 {
    if (p.buf.items.len >= size) {
        return p.buf.items[0..size];
    }

    try p.buf.ensureTotalCapacity(alloc, size);

    const slice = p.buf.allocatedSlice();
    const len = p.buf.items.len;
    const count = try std.posix.read(p.socket, slice[len..size]);

    p.buf.items.len += count;

    if (p.buf.items.len >= size) {
        return p.buf.items[0..size];
    }

    return null;
}

pub fn writeBuf(p: *Peer) !?void {
    if (p.buf.items.len == 0) {
        return;
    }

    const wrote = try std.posix.write(p.socket, p.buf.items);

    const left = p.buf.items.len - wrote;
    p.buf.items.len = left;

    if (left == 0) {
        return;
    }

    @memmove(p.buf.items[0..left], p.buf.items[wrote .. wrote + left]);

    return null;
}

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
pub fn addRequest(p: *Peer, piece: u32, pieceLen: u32) bool {
    const chunkLen = @min(Torrent.BLOCK_SIZE, pieceLen - p.workingPieceOffset);

    p.inFlight.push(.{
        .pieceIndex = piece,
        .begin = p.workingPieceOffset,
    }) catch return true;

    p.mq.add(.{ .request = .{
        .index = piece,
        .begin = p.workingPieceOffset,
        .len = chunkLen,
    } }) catch {
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
