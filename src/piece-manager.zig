const std = @import("std");
const hasher = @import("hasher");

const Torrent = @import("torrent.zig");
const proto = @import("proto.zig");
const utils = @import("utils.zig");

pieces: []State,

/// used to track if isEndgame
missingCount: usize,

completedCount: usize,

buffers: std.hash_map.AutoHashMapUnmanaged(u32, PieceBuf) = .empty,

buffersPool: std.array_list.Aligned(PieceBuf, null),

const Self = @This();

const State = enum(u2) {
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
    errdefer alloc.free(arr);

    for (arr) |*piece| piece.* = .missing;

    return .{
        .pieces = arr,
        .missingCount = numberOfPieces,
        .completedCount = 0,
        .buffersPool = try .initCapacity(alloc, 64), // 64 stale piece buffers, should be plenty right ?
    };
}

pub fn fromBitset(alloc: std.mem.Allocator, bitset: std.bit_set.DynamicBitSetUnmanaged) !Self {
    const numberOfPieces = bitset.bit_length;

    const arr = try alloc.alloc(State, numberOfPieces);
    errdefer alloc.free(arr);

    var missingCount: usize = 0;
    var completedCount: usize = 0;

    for (arr, 0..) |*piece, i| {
        if (bitset.isSet(i)) {
            piece.* = .have;
            completedCount += 1;
        } else {
            piece.* = .missing;
            missingCount += 1;
        }
    }

    return .{
        .pieces = arr,
        .missingCount = missingCount,
        .completedCount = completedCount,
        .buffersPool = try .initCapacity(alloc, 64), // 64 stale piece buffers, should be plenty right ?
    };
}

pub fn deinit(self: *Self, alloc: std.mem.Allocator) void {
    alloc.free(self.pieces);

    var iter = self.buffers.valueIterator();
    while (iter.next()) |buf| {
        buf.deinit(alloc);
    }

    self.buffers.deinit(alloc);

    for (self.buffersPool.items) |buf| buf.deinit(alloc);
    self.buffersPool.deinit(alloc);
}

pub fn validatePiece(
    _: *Self,
    noalias bytes: []const u8,
    noalias expectedHash: []const u8,
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
        res.value_ptr.* = self.buffersPool.pop() orelse .{
            .bytes = try alloc.alloc(u8, len),
            .received = .initEmpty(),
            .fetched = 0,
        };
    }

    return res.value_ptr;
}

pub fn consumePieceBuf(self: *Self, alloc: std.mem.Allocator, piece: *PieceBuf) void {
    piece.fetched = 0;
    piece.received = .initEmpty();

    self.buffersPool.appendBounded(piece.*) catch piece.deinit(alloc);
}

pub fn isEndgame(self: *const Self) bool {
    return self.missingCount == 0;
}

pub fn canFetch(self: *Self, index: usize) bool {
    switch (self.pieces[index]) {
        .missing => {
            self.missingCount -= 1;
            self.pieces[index] = .downloading;

            return true;
        },

        .have => {
            return false;
        },

        .downloading => {
            return self.isEndgame();
        },
    }
}

pub fn isDownloadComplete(self: Self) bool {
    return std.mem.allEqual(State, self.pieces, .have);
}

pub fn reset(self: *Self, index: u32) void {
    self.pieces[index] = .missing;
    self.missingCount += 1;

    const buf = self.buffers.getPtr(index) orelse return;
    buf.fetched = 0;
    buf.received = .initEmpty();
}

pub fn complete(self: *Self, index: u32) !PieceBuf {
    const kv = self.buffers.fetchRemove(index) orelse return error.NoMatchingPiece;

    self.pieces[index] = .have;
    self.completedCount += 1;

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

    for (self.pieces, 0..) |p, i| switch (p) {
        else => continue,
        .have => {
            const byteIdx = i / 8;
            const bitPos: u3 = @intCast(7 - (i % 8));
            bytes[byteIdx] |= (@as(u8, 1) << bitPos);
        },
    };

    return bytes;
}

pub fn bytesToBitfield(self: *Self, alloc: std.mem.Allocator, bytes: []const u8) !std.bit_set.DynamicBitSetUnmanaged {
    // Round up pieces.len to the nearest byte
    const expectedBytes = (self.pieces.len + 7) / 8;

    if (bytes.len != expectedBytes) return error.CorruptBitfield;

    var bitfield: std.bit_set.DynamicBitSetUnmanaged = try .initEmpty(alloc, self.pieces.len);

    for (0..self.pieces.len) |i| {
        const byte_idx = i / 8;
        const bit_within_byte: u3 = @intCast(i % 8);

        // BitTorrent Spec: Index 0 is the high bit (0x80) of the first byte.
        // So we shift by (7 - bit_index).
        const shift_amount = 7 - bit_within_byte;
        const is_set = (bytes[byte_idx] >> shift_amount) & 1 != 0;

        bitfield.setValue(i, is_set);
    }

    return bitfield;
}

pub fn countDownloaded(self: *const Self, torrent: *const Torrent) usize {
    var downloaded: usize = 0;

    for (self.pieces, 0..) |piece, i| switch (piece) {
        .have => {
            downloaded += torrent.getPieceSize(i);
        },
        else => continue,
    };

    return downloaded;
}
