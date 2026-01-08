const std = @import("std");

const proto = @import("proto.zig");
const utils = @import("utils.zig");

const Self = @This();

const State = enum {
    missing,
    downloading,
    have,
};

const PieceBuf = struct {
    fetched: u32,
    bytes: []u8,

    pub fn deinit(self: PieceBuf, alloc: std.mem.Allocator) void {
        alloc.free(self.bytes);
    }
};

pieces: []State,

buffers: std.hash_map.AutoHashMapUnmanaged(u32, PieceBuf) = .empty,

pub fn init(alloc: std.mem.Allocator, numberOfPieces: usize) !Self {
    const pieces = try alloc.alloc(State, numberOfPieces);
    for (pieces) |*piece| piece.* = .missing;

    return .{ .pieces = pieces };
}

pub fn deinit(self: *Self, alloc: std.mem.Allocator) void {
    alloc.free(self.pieces);

    var iter = self.buffers.valueIterator();
    while (iter.next()) |buf| {
        buf.deinit(alloc);
    }

    self.buffers.deinit(alloc);
}

pub fn validatePiece(
    self: *Self,
    index: u32,
    noalias bytes: []const u8,
    noalias expectedHash: []const u8,
) !void {
    var computedHash: [20]u8 = undefined;

    std.crypto.hash.Sha1.hash(bytes, computedHash[0..20], .{});

    if (!std.mem.eql(u8, computedHash[0..20], expectedHash[0..20])) {
        self.reset(index);
        return error.CorruptPiece;
    }
}

pub fn writePiece(
    self: *Self,
    alloc: std.mem.Allocator,
    piece: proto.Piece,
    pieceLen: u32,
    noalias bytes: []const u8,
) !?PieceBuf {
    if (self.pieces[piece.index] == .have) {
        return error.PieceAlreadyDownloaded;
    }

    const buf = try self.getPieceBuf(alloc, piece.index, pieceLen);

    @memcpy(buf.bytes[piece.begin .. piece.begin + piece.len], bytes[0..piece.len]);
    buf.fetched += @intCast(bytes.len);

    // TODO: maybe we should reset this piece and abort any operations ?
    utils.assert(buf.fetched <= pieceLen);

    if (buf.fetched != pieceLen) {
        return null;
    }

    return self.complete(piece.index) catch unreachable;
}

pub fn getPieceBuf(
    self: *Self,
    alloc: std.mem.Allocator,
    index: u32,
    len: u32,
) !*PieceBuf {
    const res = try self.buffers.getOrPut(alloc, index);

    if (!res.found_existing) {
        res.value_ptr.* = .{
            .bytes = try alloc.alloc(u8, len),
            .fetched = 0,
        };
    }

    return res.value_ptr;
}

pub fn getWorkingPiece(self: *Self, peerBitfield: std.DynamicBitSetUnmanaged) ?u32 {
    for (self.pieces, 0..) |*piece, index| {
        if (piece.* != .missing) {
            continue;
        }

        if (peerBitfield.isSet(index)) {
            piece.* = .downloading;
            return @intCast(index);
        }
    }
    return null;
}

pub fn isDownloadComplete(self: Self) bool {
    return std.mem.allEqual(State, self.pieces, .have);
}

pub fn reset(self: *Self, index: u32) void {
    self.pieces[index] = .missing;
    const buf = self.buffers.getPtr(index) orelse return;
    buf.fetched = 0;
}

pub fn complete(self: *Self, index: u32) !PieceBuf {
    self.pieces[index] = .have;

    const kv = self.buffers.fetchRemove(index) orelse return error.NoMatchingPiece;
    return kv.value;
}
