const std = @import("std");

const utils = @import("utils");
const proto = @import("proto.zig");
const Torrent = @import("torrent.zig");

pieces: []State,

/// used to track if isEndgame
missingCount: usize,

completedCount: usize,

/// downloaded bytes, instead of iterating each time over "pieces", use this to check how many is
/// already downloaded
downloaded: usize,

buffers: std.hash_map.AutoHashMapUnmanaged(u32, *PieceBuf) = .empty,

buffersPool: std.array_list.Aligned(*PieceBuf, null),

const PieceManager = @This();

const State = enum(u2) {
    missing,
    downloading,
    have,
};

/// enable logging of "fetching/reseted/completed" piece
const VERY_VERBOSE = false;

const MAX_STALE_BUFFERS_COUNT = 32; // 32 stale piece buffers, should be plenty right ?

pub const PieceBuf = struct {
    index: u32,
    fetched: u32,
    received: std.bit_set.ArrayBitSet(usize, 1024),
    bytes: []u8,

    /// last piece is almost always smaller than rest, this means if we use `bytes` directly to
    /// write or verify piece, nothing will work. This function will return only what was downloaded
    pub fn written(self: *const PieceBuf) []u8 {
        return self.bytes[0..self.fetched];
    }

    pub fn hasBlock(self: *const PieceBuf, begin: u32) bool {
        const chunkIdx = begin / Torrent.BLOCK_SIZE;
        return self.received.isSet(chunkIdx);
    }

    pub fn markBlock(self: *PieceBuf, begin: u32) void {
        const chunkIdx = begin / Torrent.BLOCK_SIZE;
        self.received.set(chunkIdx);
    }

    pub fn deinit(self: *const PieceBuf, alloc: std.mem.Allocator) void {
        alloc.free(self.bytes);
    }
};

pub fn init(alloc: std.mem.Allocator, pieces: []const u8) !PieceManager {
    const numberOfPieces = pieces.len / 20;

    const arr = try alloc.alloc(State, numberOfPieces);
    errdefer alloc.free(arr);

    for (arr) |*piece| piece.* = .missing;

    return .{
        .pieces = arr,
        .missingCount = numberOfPieces,
        .completedCount = 0,
        .downloaded = 0,
        .buffersPool = try .initCapacity(alloc, MAX_STALE_BUFFERS_COUNT),
    };
}

pub fn fromBitset(alloc: std.mem.Allocator, torrent: *const Torrent, bitset: std.bit_set.DynamicBitSetUnmanaged) !PieceManager {
    const numberOfPieces = bitset.bit_length;

    const arr = try alloc.alloc(State, numberOfPieces);
    errdefer alloc.free(arr);

    var missingCount: usize = 0;
    var completedCount: usize = 0;
    var downloaded: usize = 0;

    for (arr, 0..) |*piece, i| {
        if (bitset.isSet(i)) {
            piece.* = .have;
            completedCount += 1;
            downloaded += torrent.getPieceSize(i);
        } else {
            piece.* = .missing;
            missingCount += 1;
        }
    }

    return .{
        .pieces = arr,
        .missingCount = missingCount,
        .completedCount = completedCount,
        .downloaded = downloaded,
        .buffersPool = try .initCapacity(alloc, MAX_STALE_BUFFERS_COUNT),
    };
}

pub fn deinit(self: *PieceManager, alloc: std.mem.Allocator) void {
    alloc.free(self.pieces);

    var iter = self.buffers.valueIterator();
    while (iter.next()) |buf| {
        buf.*.deinit(alloc);
        alloc.destroy(buf.*);
    }
    self.buffers.deinit(alloc);

    for (self.buffersPool.items) |buf| {
        buf.deinit(alloc);
        alloc.destroy(buf);
    }
    self.buffersPool.deinit(alloc);
}

pub fn writePiece(
    self: *PieceManager,
    alloc: std.mem.Allocator,
    piece: proto.Piece,
    pieceLen: u32,
    noalias bytes: []const u8,
) !?*PieceBuf {
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

    const kv = self.buffers.fetchRemove(piece.index) orelse unreachable;
    return kv.value;
}

pub fn getPieceBuf(
    self: *PieceManager,
    alloc: std.mem.Allocator,
    index: u32,
    len: u32,
) !*PieceBuf {
    const res = try self.buffers.getOrPut(alloc, index);

    if (!res.found_existing) {
        if (self.buffersPool.pop()) |buf| {
            buf.index = index;
            res.value_ptr.* = buf;
        } else {
            const buf = try alloc.create(PieceBuf);
            errdefer alloc.destroy(buf);

            buf.* = .{
                .index = index,
                .bytes = try alloc.alloc(u8, len),
                .received = .initEmpty(),
                .fetched = 0,
            };

            res.value_ptr.* = buf;
        }
    }

    return res.value_ptr.*;
}

pub fn consumePieceBuf(self: *PieceManager, alloc: std.mem.Allocator, piece: *PieceBuf) void {
    piece.fetched = 0;
    piece.received = .initEmpty();

    self.buffersPool.appendBounded(piece) catch {
        piece.deinit(alloc);
        alloc.destroy(piece);
    };
}

pub fn suggstPiece(self: *PieceManager) ?usize {
    if (self.missingCount == 0) {
        return null;
    }

    const maybeMissingPiece = self.pieces.len - self.missingCount;

    return switch (self.pieces[maybeMissingPiece]) {
        .missing => maybeMissingPiece,
        .have => null,
        .downloading => if (self.isEndgame()) maybeMissingPiece else null,
    };
}

pub fn canFetch(self: *PieceManager, index: usize) bool {
    return switch (self.pieces[index]) {
        .missing => true,
        .have => false,
        .downloading => self.isEndgame(),
    };
}

pub fn isEndgame(self: *const PieceManager) bool {
    return self.missingCount == 0;
}

pub fn isDownloadComplete(self: PieceManager) bool {
    return self.completedCount == self.pieces.len;
}

pub fn downloading(self: *PieceManager, index: u32) void {
    self.missingCount -= 1;
    self.pieces[index] = .downloading;

    if (VERY_VERBOSE) std.log.debug("pieces: downloading {d}", .{index});
}

pub fn reset(self: *PieceManager, piece: *PieceBuf) void {
    self.pieces[piece.index] = .missing;
    self.missingCount += 1;

    if (VERY_VERBOSE) std.log.debug("pieces: reseting {d}", .{piece.index});
}

pub fn complete(self: *PieceManager, piece: *PieceBuf) void {
    self.pieces[piece.index] = .have;
    self.completedCount += 1;
    self.downloaded += piece.fetched;

    if (VERY_VERBOSE) std.log.debug("pieces: finished {d}", .{piece.index});
}

pub fn killPeer(self: *PieceManager, workingOn: ?std.DynamicBitSetUnmanaged) void {
    const bitfield = workingOn orelse return;

    var iter = bitfield.iterator(.{
        .direction = .forward,
        .kind = .set,
    });

    while (iter.next()) |index| {
        const buf = self.buffers.get(@intCast(index)) orelse continue;
        self.reset(buf);
    }
}

pub fn hasInterestingPiece(self: *PieceManager, bitfield: std.DynamicBitSetUnmanaged) bool {
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

pub fn torrentBitfieldBytes(self: *PieceManager, alloc: std.mem.Allocator) ![]u8 {
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

pub fn bytesToBitfield(self: *PieceManager, alloc: std.mem.Allocator, bytes: []const u8) !std.bit_set.DynamicBitSetUnmanaged {
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
