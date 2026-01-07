const std = @import("std");

const Self = @This();

const State = enum {
    missing,
    downloading,
    have,
};

const Pieces = std.array_list.Aligned(State, null);

const PieceBuf = struct {
    fetched: u32,
    bytes: []u8,

    pub fn deinit(self: PieceBuf, alloc: std.mem.Allocator) void {
        alloc.free(self.bytes);
    }
};

pieces: Pieces,

buffers: std.hash_map.AutoHashMapUnmanaged(u32, PieceBuf) = .empty,

pub fn init(alloc: std.mem.Allocator, numberOfPieces: usize) !Self {
    var pieces: Pieces = try .initCapacity(alloc, numberOfPieces);

    pieces.appendNTimesAssumeCapacity(.missing, numberOfPieces);

    return .{ .pieces = pieces };
}

pub fn deinit(self: *Self, alloc: std.mem.Allocator) void {
    self.pieces.deinit(alloc);

    var iter = self.buffers.valueIterator();
    while (iter.next()) |buf| {
        buf.deinit(alloc);
    }

    self.buffers.deinit(alloc);
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
    for (self.pieces.items, 0..) |state, index| {
        if (state != .missing) {
            continue;
        }

        if (peerBitfield.isSet(index)) {
            self.pieces.items[index] = .downloading;
            return @intCast(index);
        }
    }
    return null;
}

pub fn isDownloadComplete(self: Self) bool {

}

pub fn reset(self: *Self, index: usize) void {
    if (self.pieces.items[index] != .have) {
        self.pieces.items[index] = .missing;
    }

    const buf = self.buffers.get(index) orelse return;
    buf.fetched = 0;
}

pub fn complete(self: *Self, index: u32) !PieceBuf {
    self.pieces.items[index] = .have;

    const kv = self.buffers.fetchRemove(index) orelse return error.NoMatchingPiece;
    return kv.value;
}
