const std = @import("std");

pub inline fn assert(ok: bool) void {
    if (!ok) unreachable;
}

pub const RqPool = struct {
    buf: []Piece,
    count: usize = 0,
    size: usize,

    const MAX_REQUEST_POOL_SIZE = 250;

    pub const Piece = packed struct { index: u32, begin: u32 };

    /// usually initial size is 32 "in-flight" requests
    pub fn init(alloc: std.mem.Allocator, initialSize: usize) !RqPool {
        const buf = try alloc.alloc(Piece, initialSize);
        return .{ .buf = buf, .size = initialSize };
    }

    pub fn deinit(self: *RqPool, alloc: std.mem.Allocator) void {
        alloc.free(self.buf);
    }

    /// currently only supports size increasing
    pub fn resize(self: *RqPool, alloc: std.mem.Allocator, newSize: usize) !void {
        if (newSize <= self.size) {
            return;
        }

        const cappedSize = @min(newSize, MAX_REQUEST_POOL_SIZE);

        self.buf = try alloc.realloc(self.buf, cappedSize);
        self.size = cappedSize;
    }

    pub fn push(self: *RqPool, r: Piece) !void {
        if (self.count == self.size) {
            return error.Full;
        }

        self.buf[self.count] = r;
        self.count += 1;
    }

    pub fn receive(self: *RqPool, r: Piece) !void {
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

    pub fn format(self: *const RqPool, w: *std.Io.Writer) !void {
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

        pub fn get(self: *const Self, index: usize) T {
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

pub fn writeQueryToStream(
    w: *std.Io.Writer,
    url: std.Uri,
    queries: []const QueryParam,
) !void {
    try w.writeByte('?');

    if (url.query) |query| {
        try query.formatRaw(w);

        if (w.buffer[w.end - 1] != '&') {
            try w.writeByte('&');
        }
    }

    for (queries) |query| {
        const key, const val = query;

        switch (val) {
            .int => |int| try w.print("{s}={d}", .{ key, int }),

            // default zig's query escaping is not enough...
            .string => |string| {
                try w.print("{s}=", .{key});
                const valComp: std.Uri.Component = .{ .raw = string };
                try valComp.formatEscaped(w);
            },

            .skip => continue,
        }

        try w.writeByte('&');
    }

    w.undo(1);
}

pub fn TaggedPointer(comptime Union: type) type {
    const unionFields = switch (@typeInfo(Union)) {
        .@"union" => |x| x.fields,
        else => @compileError("TaggedPointer requires a union type"),
    };

    // Calculate how many bits we need to store the "tag" (the enum index)
    // 2 fields = 1 bit, 4 fields = 2 bits, 8 fields = 3 bits, etc.
    const tagBits = std.math.log2_int_ceil(usize, unionFields.len);
    const requiredAlignment = @as(usize, 1) << tagBits;

    const tagMask = requiredAlignment - 1;
    const ptrMask = ~tagMask;

    for (unionFields) |field| {
        if (@typeInfo(field.type) == .pointer) {
            if (@typeInfo(field.type).pointer.alignment < requiredAlignment) {
                @compileError("Field '" ++ field.name ++ "' does not have enough alignment for this TaggedPointer.");
            }
        }
    }

    const EnumFromU = std.meta.Tag(Union);

    return struct {
        pub fn pack(value: Union) usize {
            switch (value) {
                inline else => |ptr, tag| {
                    const addr = @intFromPtr(ptr);

                    assert(addr % requiredAlignment == 0);

                    return addr | @intFromEnum(tag);
                },
            }
        }

        pub fn unpack(val: usize) Union {
            const tagValue = val & tagMask;
            const ptrValue = val & ptrMask;

            assert(tagValue < unionFields.len);

            const valueType: EnumFromU = @enumFromInt(tagValue);

            switch (valueType) {
                inline else => |tag| {
                    const field = @tagName(tag);
                    const ptr: @FieldType(Union, field) = @ptrFromInt(ptrValue);
                    return @unionInit(Union, field, ptr);
                },
            }
        }
    };
}

test "TaggedPointer" {
    const A = struct { int: usize };
    const B = struct { smaller: u32 };

    const Ptrs = union(enum) { a: *A, b: *B };

    const Tagged = TaggedPointer(Ptrs);

    var a = A{ .int = 64 };
    const aTagged = Tagged.pack(.{ .a = &a });

    var b = B{ .smaller = 32 };
    const bTagged = Tagged.pack(.{ .b = &b });

    switch (Tagged.unpack(aTagged)) {
        .a => |ptr| try std.testing.expectEqualDeep(&a, ptr),
        else => try std.testing.expect(false),
    }

    switch (Tagged.unpack(bTagged)) {
        .b => |ptr| try std.testing.expectEqualDeep(&b, ptr),
        else => try std.testing.expect(false),
    }
}

pub fn isHttp(haystack: []const u8) bool {
    const prefix = "http://";
    return std.mem.startsWith(u8, haystack, prefix) and haystack.len > prefix.len;
}

pub fn isHttps(haystack: []const u8) bool {
    const prefix = "https://";
    return std.mem.startsWith(u8, haystack, prefix) and haystack.len > prefix.len;
}

pub fn isUdp(haystack: []const u8) bool {
    const prefix = "udp://";
    return std.mem.startsWith(u8, haystack, prefix) and haystack.len > prefix.len;
}

pub fn isMagnet(haystack: []const u8) bool {
    const prefix = "magnet:";
    return std.mem.startsWith(u8, haystack, prefix) and haystack.len > prefix.len;
}

pub fn parseCompactAddress(in: [6]u8) std.net.Address {
    const port = std.mem.readInt(u16, in[4..6], .big);
    return std.net.Address.initIp4(in[0..4].*, port);
}

pub fn compactAddress(addr: std.net.Address, bytes: []u8) void {
    assert(bytes.len >= 6);
    // only ipv4
    assert(addr.any.family == std.posix.AF.INET);

    const ip_bytes: *const [4]u8 = @ptrCast(&addr.in.sa.addr);
    @memcpy(bytes[0..4], ip_bytes);

    std.mem.writeInt(u16, bytes[4..6][0..2], addr.getPort(), .big);
}

pub fn addressToYourIp(addr: std.net.Address) ?[4]u8 {
    if (addr.any.family != std.posix.AF.INET) return null;

    const bytes = std.mem.asBytes(&addr.in.sa.addr);

    return bytes[0..4].*;
}

pub fn base32ToBytes(out: []u8, in: []const u8) !void {
    var buffer: u64 = 0;
    var bits: u6 = 0;
    var out_index: usize = 0;

    for (in) |c| {
        const value = switch (c) {
            'A'...'Z' => c - 'A',
            'a'...'z' => c - 'a',
            '2'...'7' => c - '2' + 26,
            else => return error.InvalidFormat,
        };

        buffer = (buffer << 5) | value;
        bits += 5;

        if (bits >= 8) {
            bits -= 8;

            if (out_index >= out.len) return error.NoSpaceLeft;

            out[out_index] = @truncate(buffer >> bits);
            out_index += 1;
        }
    }
}

test "base32ToBytes" {
    const input = "6MVEC6UU6BXKSAENDIQLTI3NN7QH3AEC";
    var out: [20]u8 = undefined;

    try base32ToBytes(&out, input);

    try std.testing.expectEqualStrings(&[_]u8{ 0xF3, 0x2A, 0x41, 0x7A, 0x94, 0xF0, 0x6E, 0xA9, 0x00, 0x8D, 0x1A, 0x20, 0xB9, 0xA3, 0x6D, 0x6F, 0xE0, 0x7D, 0x80, 0x82 }, &out);
}
