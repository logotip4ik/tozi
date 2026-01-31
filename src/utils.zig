const std = @import("std");

pub inline fn assert(ok: bool) void {
    if (!ok) unreachable;
}

pub const RqPool = struct {
    buf: []Piece,
    count: usize = 0,
    size: usize,

    const Self = @This();
    pub const Piece = packed struct { index: u32, begin: u32 };

    /// usually initial size is 32 "in-flight" requests
    pub fn init(alloc: std.mem.Allocator, initialSize: usize) !RqPool {
        const buf = try alloc.alloc(Piece, initialSize);
        return .{ .buf = buf, .size = initialSize };
    }

    pub fn deinit(self: *RqPool, alloc: std.mem.Allocator) void {
        alloc.free(self.buf);
    }

    pub fn push(self: *Self, r: Piece) !void {
        if (self.count == self.size) {
            return error.Full;
        }

        self.buf[self.count] = r;
        self.count += 1;
    }

    pub fn receive(self: *Self, r: Piece) !void {
        for (0..self.count) |i| {
            const req = self.buf[i];

            if (req.index != r.index or req.begin != r.begin) {
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
            try w.print("(piece: {d} + {d})", .{ r.index, r.begin });

            if (i != self.count - 1) {
                try w.writeAll(", ");
            }
        }
    }
};

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

pub const QueryValue = union(enum) {
    string: []const u8,
    int: usize,
    skip,
};

pub const QueryParam = struct { []const u8, QueryValue };

pub fn appendQuery(
    alloc: std.mem.Allocator,
    url: std.Uri,
    queries: []const QueryParam,
) !std.array_list.Aligned(u8, null) {
    var w: std.Io.Writer.Allocating = .init(alloc);
    errdefer w.deinit();

    var writer = &w.writer;

    if (url.query) |query| {
        try query.formatRaw(writer);

        if (writer.buffer[writer.end - 1] != '&') {
            try writer.writeByte('&');
        }
    }

    for (queries, 0..) |query, i| {
        const key, const val = query;

        switch (val) {
            .int => |int| {
                try writer.print("{s}=", .{key});
                try writer.print("{d}", .{int});
            },

            // default zig's query escaping is not enough...
            .string => |string| {
                try writer.print("{s}=", .{key});
                const valComp: std.Uri.Component = .{ .raw = string };
                try valComp.formatEscaped(writer);
            },

            .skip => continue,
        }

        if (i != queries.len - 1) {
            try writer.writeByte('&');
        }
    }

    return w.toArrayList();
}

test "appendQuery" {
    const url1 = try std.Uri.parse("https://toloka.ua/something?else=true");

    var query1 = try appendQuery(std.testing.allocator, url1, &.{
        .{ "port", .{ .int = 456 } },
        .{ "compact", .{ .string = "1" } },
    });
    defer query1.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("else=true&port=456&compact=1", query1.items);

    const url2 = try std.Uri.parse("https://toloka.ua/something");

    var query2 = try appendQuery(std.testing.allocator, url2, &.{
        .{ "port", .{ .int = 456 } },
        .{ "compact", .{ .string = "1" } },
    });
    defer query2.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("port=456&compact=1", query2.items);

    const url3 = try std.Uri.parse("https://toloka.ua/something?testing&");

    var query3 = try appendQuery(std.testing.allocator, url3, &.{
        .{ "port", .{ .int = 456 } },
        .{ "compact", .{ .string = "1" } },
    });
    defer query3.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("testing&port=456&compact=1", query3.items);
}
