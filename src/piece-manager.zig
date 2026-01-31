const std = @import("std");
const hasher = @import("hasher");

const Torrent = @import("torrent.zig");
const proto = @import("proto.zig");
const utils = @import("utils.zig");

pieces: []State,

buffers: std.hash_map.AutoHashMapUnmanaged(u32, PieceBuf) = .empty,

const Self = @This();

const State = enum {
    missing,
    downloading,
    have,
};

const PieceBuf = struct {
    bytes: []u8,
    received: std.bit_set.ArrayBitSet(usize, 2048),
    fetched: u32,

    pub fn hasBlock(self: PieceBuf, begin: u32) bool {
        const chunkIdx = begin / Torrent.BLOCK_SIZE;
        return self.received.isSet(chunkIdx);
    }

    pub fn markBlock(self: *PieceBuf, begin: u32) void {
        const chunkIdx = begin / Torrent.BLOCK_SIZE;
        self.received.set(chunkIdx);
    }

    pub fn deinit(self: PieceBuf, alloc: std.mem.Allocator) void {
        alloc.free(self.bytes);
    }
};

pub fn init(alloc: std.mem.Allocator, pieces: []const u8) !Self {
    const numberOfPieces = pieces.len / 20;

    const arr = try alloc.alloc(State, numberOfPieces);
    for (arr) |*piece| piece.* = .missing;

    return .{ .pieces = arr };
}

pub fn fromBitset(alloc: std.mem.Allocator, bitset: std.bit_set.DynamicBitSetUnmanaged) !Self {
    const numberOfPieces = bitset.bit_length;

    const arr = try alloc.alloc(State, numberOfPieces);
    for (arr, 0..) |*piece, i| {
        piece.* = if (bitset.isSet(i)) .have else .missing;
    }

    return .{ .pieces = arr };
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
    _: *Self,
    noalias bytes: *const []const u8,
    noalias expectedHash: *const []const u8,
) !void {
    const computedHash = hasher.hash(bytes) catch return error.HashingFailed;

    if (!std.mem.eql(u8, computedHash[0..20], expectedHash[0..20])) {
        @branchHint(.unlikely);
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
        return null;
    }

    const buf = try self.getPieceBuf(alloc, piece.index, pieceLen);

    if (!buf.hasBlock(piece.begin)) {
        @memcpy(buf.bytes[piece.begin .. piece.begin + piece.len], bytes[0..piece.len]);
        buf.markBlock(piece.begin);
        buf.fetched += piece.len;
    }

    // TODO: maybe we should reset this piece and abort any operations ?
    utils.assert(buf.fetched <= pieceLen);

    if (buf.fetched != pieceLen) {
        return null;
    }

    return self.complete(piece.index) catch null;
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
            .received = .initEmpty(),
            .fetched = 0,
        };
    }

    return res.value_ptr;
}

pub fn getWorkingPiece(self: *Self, peerBitfield: std.DynamicBitSetUnmanaged) ?u32 {
    for (self.pieces, 0..) |*piece, index| {
        if (piece.* == .missing and peerBitfield.isSet(index)) {
            piece.* = .downloading;
            return @intCast(index);
        }
    }

    const isEndgame = blk: for (self.pieces) |piece| {
        if (piece == .missing) break :blk false;
    } else true;

    if (!isEndgame or self.isDownloadComplete()) {
        return null;
    }

    for (self.pieces, 0..) |*piece, index| {
        if (piece.* == .downloading and peerBitfield.isSet(index)) {
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
    buf.received = .initEmpty();
}

pub fn complete(self: *Self, index: u32) !PieceBuf {
    const kv = self.buffers.fetchRemove(index) orelse return error.NoMatchingPiece;

    self.pieces[index] = .have;

    return kv.value;
}

pub fn killPeer(self: *Self, workingOn: ?std.DynamicBitSetUnmanaged) void {
    const bitfield = workingOn orelse return;

    var iter = bitfield.iterator(.{
        .direction = .forward,
        .kind = .set,
    });

    while (iter.next()) |index| {
        self.reset(@intCast(index));
    }
}

pub fn hasInterestingPiece(self: *Self, bitfield: std.DynamicBitSetUnmanaged) bool {
    var iterator = bitfield.iterator(.{
        .direction = .forward,
        .kind = .set,
    });

    while (iterator.next()) |index| {
        if (index >= self.pieces.len) continue;

        if (self.pieces[index] == .missing) {
            return true;
        }
    }

    return false;
}

pub fn torrentBitfieldBytes(self: *Self, alloc: std.mem.Allocator) ![]u8 {
    const byteLen = (self.pieces.len + 7) / 8;

    const bytes = try alloc.alloc(u8, byteLen);
    errdefer alloc.free(bytes);

    @memset(bytes, 0);

    for (self.pieces, 0..) |p, i| {
        if (p == .have) {
            const byteIdx = i / 8;
            const bitPos: u3 = @intCast(7 - (i % 8));
            bytes[byteIdx] |= (@as(u8, 1) << bitPos);
        }
    }

    return bytes;
}
