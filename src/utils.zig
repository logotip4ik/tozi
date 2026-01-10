const std = @import("std");

pub inline fn assert(ok: bool) void {
    if (!ok) unreachable;
}

pub fn RqPool(comptime Size: usize) type {
    return struct {
        buf: [Size]Chunk = undefined,
        count: usize = 0,
        size: usize = Size,

        const Self = @This();
        pub const Chunk = packed struct { pieceIndex: u32, begin: u32 };

        pub fn push(self: *Self, r: Chunk) !void {
            if (self.count == Size) {
                return error.Full;
            }

            self.buf[self.count] = r;
            self.count += 1;
        }

        pub fn receive(self: *Self, r: Chunk) !void {
            for (0..self.count) |i| {
                const req = self.buf[i];

                if (req.pieceIndex != r.pieceIndex or req.begin != r.begin) {
                    continue;
                }

                self.buf[i] = self.buf[self.count - 1];
                self.count -= 1;

                return;
            }

            return error.UnknownChunk;
        }

        pub fn format(self: Self, w: *std.Io.Writer) !void {
            for (self.buf[0..self.count], 0..) |r, i| {
                try w.print("(piece: {d} + {d})", .{ r.pieceIndex, r.begin });

                if (i != self.count - 1) {
                    try w.writeAll(", ");
                }
            }
        }
    };
}

pub fn Queue(comptime T: type, comptime Size: usize) type {
    assert(Size > 0);

    return struct {
        buf: [Size]T = undefined,
        begin: usize = 0,
        end: usize = 0,
        count: usize = 0,

        const Self = @This();

        pub fn add(self: *Self, item: T) !void {
            if (self.count == Size) {
                return error.OutOfMemory;
            }

            self.buf[self.end] = item;
            self.end = @rem(self.end + 1, Size);
            self.count += 1;
        }

        pub fn remove(self: *Self) ?T {
            if (self.count == 0) {
                return null;
            }

            const item = self.buf[self.begin];

            self.begin = @rem(self.begin + 1, Size);
            self.count -= 1;

            return item;
        }

        pub fn removeIndex(self: *Self, index: usize) void {
            assert(index < self.count);

            var i = index;
            while (i < self.count - 1) : (i += 1) {
                const current = @rem(self.begin + i, Size);
                const next = @rem(self.begin + i + 1, Size);

                self.buf[current] = self.buf[next];
            }

            self.count -= 1;
            self.end = @rem(self.end + Size - 1, Size);
        }

        pub fn get(self: Self, index: usize) T {
            assert(index < self.count);
            const targetIndex = @rem(self.begin + index, Size);
            return self.buf[targetIndex];
        }
    };
}

test "Queue simple use case" {
    var q: Queue(u8, 5) = .{};

    try q.add(1);
    try q.add(2);

    try std.testing.expectEqual(1, q.remove().?);
    try std.testing.expectEqual(2, q.remove().?);
    try std.testing.expectEqual(null, q.remove());
}

test "Queue complex use case" {
    var q: Queue(u8, 5) = .{};

    try q.add(1);
    try q.add(2);
    try q.add(3);
    try q.add(4);
    try q.add(5);

    try std.testing.expectEqual(1, q.remove().?);
    try std.testing.expectEqual(2, q.remove().?);

    try q.add(6);

    try std.testing.expectEqual(3, q.remove().?);
    try std.testing.expectEqual(4, q.remove().?);

    try q.add(7);
    try q.add(8);
    try q.add(9);

    try std.testing.expectEqual(5, q.remove().?);
    try std.testing.expectEqual(6, q.remove().?);
    try std.testing.expectEqual(7, q.remove().?);
    try std.testing.expectEqual(8, q.remove().?);
    try std.testing.expectEqual(9, q.remove().?);
}
