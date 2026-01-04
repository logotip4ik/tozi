const std = @import("std");

const Self = @This();

const State = enum {
    missing,
    downloading,
    have,
};

const Pieces = std.array_list.Aligned(State, null);

pieces: Pieces,

pub fn init(alloc: std.mem.Allocator, numberOfPieces: usize) !Self {
    var pieces: Pieces = try .initCapacity(alloc, numberOfPieces);

    pieces.appendNTimesAssumeCapacity(.missing, numberOfPieces);

    return .{ .pieces = pieces };
}

pub fn deinit(self: *Self, alloc: std.mem.Allocator) !Self {
    self.pieces.deinit(alloc);
}

pub fn getWorkingPiece(self: *Self, peerBitfield: std.DynamicBitSetUnmanaged) ?usize {
    for (self.pieces.items, 0..) |state, index| {
        if (state != .Missing) {
            continue;
        }

        if (peerBitfield.isSet(index)) {
            self.pieces.items[index] = .Downloading;
            return index;
        }
    }
    return null;
}

pub fn reset(self: *Self, index: usize) void {
    if (self.pieces.items[index] != .have) {
        self.pieces.items[index] = .missing;
    }
}

pub fn complete(self: *Self, index: usize) void {
    self.pieces.items[index] = .have;
}
