const std = @import("std");

const Value = @This();

const Inner = union(enum) {
    int: isize,
    string: []const u8,
    list: std.array_list.Aligned(Value, null),
    dict: std.StringHashMapUnmanaged(Value),
};

inner: Inner,

/// only used during `decode` to later reference/get `info` section which is used for hashing
start: usize = 0,
len: usize = 0,

pub fn deinit(self: *Value, alloc: std.mem.Allocator) void {
    switch (self.inner) {
        .int => {},
        .string => |string| alloc.free(string),
        .list => |*list| {
            for (list.items) |*item| item.deinit(alloc);
            list.deinit(alloc);
        },
        .dict => |*dict| {
            var iter = dict.iterator();
            while (iter.next()) |*entry| {
                alloc.free(entry.key_ptr.*);
                entry.value_ptr.deinit(alloc);
            }
            dict.deinit(alloc);
        },
    }
}

pub fn decode(alloc: std.mem.Allocator, reader: *std.Io.Reader, start: usize) !Value {
    const byte = try reader.peekByte();

    switch (byte) {
        'd' => {
            _ = try reader.discardShort(1);

            var ret: std.StringHashMapUnmanaged(Value) = .empty;
            errdefer {
                var iter = ret.iterator();
                while (iter.next()) |entry| {
                    alloc.free(entry.key_ptr.*);
                    entry.value_ptr.deinit(alloc);
                }
                ret.deinit(alloc);
            }

            // one for leading `d`
            var len: usize = 1;

            while (reader.peekByte() catch null) |next| {
                if (next == 'e') {
                    _ = try reader.discardShort(1);
                    break;
                }

                const key, const keyLen = try parseString(alloc, reader);
                errdefer alloc.free(key);

                len += keyLen;

                var value = try Value.decode(alloc, reader, len);
                errdefer value.deinit(alloc);

                len += value.len;

                try ret.put(alloc, key, value);
            }

            // and one for ending `e`
            len += 1;

            return Value{
                .inner = .{ .dict = ret },
                .start = start,
                .len = len,
            };
        },

        'l' => {
            _ = try reader.discardShort(1);

            var ret: std.array_list.Aligned(Value, null) = .empty;
            errdefer {
                for (ret.items) |*item| item.deinit(alloc);
                ret.deinit(alloc);
            }

            // one for leading `l`
            var len: usize = 1;

            while (reader.peekByte() catch null) |next| {
                if (next == 'e') {
                    _ = try reader.discardShort(1);
                    break;
                }

                var value = try Value.decode(alloc, reader, len);
                errdefer value.deinit(alloc);

                try ret.append(alloc, value);
                len += value.len;
            }

            // and one for ending `e`
            len += 1;

            return Value{
                .inner = .{ .list = ret },
                .start = start,
                .len = len,
            };
        },

        '0'...'9' => {
            const string, const len = try parseString(alloc, reader);
            return Value{
                .inner = .{ .string = string },
                .start = start,
                .len = len,
            };
        },

        'i' => {
            _ = try reader.discardShort(1);

            const numString = try reader.takeDelimiter('e') orelse return error.MissingNumEndMark;

            const int = try std.fmt.parseInt(isize, numString, 10);
            const len = 1 + numString.len + 1;

            return Value{
                .inner = .{ .int = int },
                .start = start,
                .len = len,
            };
        },

        else => {
            @branchHint(.unlikely);
            std.debug.print("unrecognized bencode: {s}", .{
                reader.peek(20) catch reader.buffered(),
            });
            return error.UnrecognisedBencode;
        },
    }
}

fn parseString(alloc: std.mem.Allocator, reader: *std.Io.Reader) !struct { []const u8, usize } {
    const keyLengthString = try reader.takeDelimiter(':') orelse {
        std.log.err("expected key length to be present", .{});
        return error.MissingColon;
    };

    const keyLength = try std.fmt.parseUnsigned(usize, keyLengthString, 10);

    const key = try reader.readAlloc(alloc, keyLength);
    const len = keyLengthString.len + 1 + keyLength;

    return .{ key, len };
}

pub fn encode(self: *const Value, writer: *std.Io.Writer) std.Io.Writer.Error!void {
    switch (self.inner) {
        .int => |int| try writer.print("i{d}e", .{int}),
        .string => |string| try writer.print("{d}:{s}", .{ string.len, string }),
        .list => |list| {
            try writer.writeByte('l');

            for (list.items) |v| {
                try v.encode(writer);
            }

            try writer.writeByte('e');
        },
        .dict => |dict| {
            try writer.writeByte('d');

            var iter = dict.iterator();
            while (iter.next()) |entry| {
                try writer.print("{d}:{s}", .{ entry.key_ptr.len, entry.key_ptr.* });
                try entry.value_ptr.encode(writer);
            }

            try writer.writeByte('e');
        },
    }
}

pub fn format(self: *const Value, writer: *std.Io.Writer) std.Io.Writer.Error!void {
    switch (self.inner) {
        .int => |int| {
            try writer.print("{d}", .{int});
        },
        .string => |string| {
            if (string.len == 0) {
                try writer.print("<empty string>", .{});
            } else if (std.unicode.utf8ValidateSlice(string)) {
                try writer.print("{s}", .{string});
            } else {
                try writer.print("<{d} bytes>", .{string.len});
            }
        },
        .list => |list| {
            try writer.writeAll("[\n");

            for (list.items) |item| {
                try writer.print("\t{f}\n", .{item});
            }

            try writer.writeAll("]");
        },
        .dict => |dict| {
            try writer.writeAll("{\n");

            var iter = dict.iterator();
            while (iter.next()) |entry| {
                try writer.print("\t{s}: {f}\n", .{entry.key_ptr.*, entry.value_ptr});
            }

            writer.writeAll("}") catch unreachable;
        },
    }
}

pub fn dumpWithOptions(self: Value, writer: *std.Io.Writer, indent: u8) void {
    switch (self.inner) {
        .int => |int| {
            for (0..indent) |_| writer.writeByte(' ') catch unreachable;
            writer.print("{d}\n", .{int}) catch unreachable;
        },
        .string => |string| {
            for (0..indent) |_| writer.writeByte(' ') catch unreachable;

            if (string.len == 0) {
                writer.print("<empty string>\n", .{}) catch unreachable;
            } else if (std.unicode.utf8ValidateSlice(string)) {
                writer.print("{s}\n", .{string}) catch unreachable;
            } else {
                writer.print("<{d} bytes>\n", .{string.len}) catch unreachable;
            }
        },
        .list => |list| {
            for (0..indent) |_| writer.writeByte(' ') catch unreachable;
            _ = writer.write("[\n") catch unreachable;

            for (list.items) |item| {
                item.dumpWithOptions(writer, indent + 2);
            }

            for (0..indent) |_| writer.writeByte(' ') catch unreachable;
            _ = writer.write("]\n") catch unreachable;
        },
        .dict => |dict| {
            for (0..indent) |_| writer.writeByte(' ') catch unreachable;
            _ = writer.write("{\n") catch unreachable;

            var iter = dict.iterator();
            while (iter.next()) |entry| {
                for (0..indent + 2) |_| writer.writeByte(' ') catch unreachable;
                writer.print("{s}\n", .{entry.key_ptr.*}) catch unreachable;
                entry.value_ptr.dumpWithOptions(writer, indent + 4);
            }

            for (0..indent) |_| writer.writeByte(' ') catch unreachable;
            _ = writer.write("}\n") catch unreachable;
        },
    }
}

pub fn dump(self: Value) void {
    var buf: [512]u8 = undefined;
    const out = std.Progress.lockStderrWriter(&buf);
    defer out.flush() catch {};

    out.print("======= VALUE DUMP =======\n", .{}) catch unreachable;

    self.dumpWithOptions(out, 0);
}

test "parseValue string" {
    var reader: std.Io.Reader = .fixed(
        \\8:announce
    );

    var v: Value = try .decode(std.testing.allocator, &reader, 0);
    defer v.deinit(std.testing.allocator);

    switch (v.inner) {
        .string => |string| try std.testing.expectEqualStrings("announce", string),
        else => try std.testing.expect(false),
    }
}

test "parseValue digit" {
    var reader: std.Io.Reader = .fixed(
        \\i32e
    );

    var v: Value = try .decode(std.testing.allocator, &reader, 0);
    defer v.deinit(std.testing.allocator);

    switch (v.inner) {
        .int => |int| try std.testing.expectEqual(32, int),
        else => try std.testing.expect(false),
    }
}

test "parseValue list" {
    var reader: std.Io.Reader = .fixed(
        \\l4:http4:http4:httpe
    );

    var v: Value = try .decode(std.testing.allocator, &reader, 0);
    defer v.deinit(std.testing.allocator);

    switch (v.inner) {
        .list => |list| {
            try std.testing.expectEqual(3, list.items.len);
            try std.testing.expectEqualStrings("http", list.items[0].inner.string);
            try std.testing.expectEqualStrings("http", list.items[1].inner.string);
            try std.testing.expectEqualStrings("http", list.items[2].inner.string);
        },
        else => try std.testing.expect(false),
    }
}

test "parseValue dict" {
    var reader: std.Io.Reader = .fixed(
        \\d4:httpl4:httpee
    );

    var v: Value = try .decode(std.testing.allocator, &reader, 0);
    defer v.deinit(std.testing.allocator);

    switch (v.inner) {
        .dict => |dict| {
            try std.testing.expectEqual(1, dict.size);

            const dv = dict.get("http") orelse unreachable;
            switch (dv.inner) {
                .list => |l| {
                    try std.testing.expectEqual(1, l.items.len);
                    try std.testing.expectEqualStrings("http", l.items[0].inner.string);
                },
                else => try std.testing.expect(false),
            }
        },
        else => try std.testing.expect(false),
    }
}

test "value int encode" {
    var writer: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer writer.deinit();

    {
        defer writer.clearRetainingCapacity();
        const v = Value{ .inner = .{ .int = 42 } };
        try v.encode(&writer.writer);
        try std.testing.expectEqualStrings("i42e", writer.written());
    }

    {
        defer writer.clearRetainingCapacity();
        const v = Value{ .inner = .{ .int = -42 } };
        try v.encode(&writer.writer);
        try std.testing.expectEqualStrings("i-42e", writer.written());
    }

    {
        defer writer.clearRetainingCapacity();
        const v = Value{ .inner = .{ .int = 0 } };
        try v.encode(&writer.writer);
        try std.testing.expectEqualStrings("i0e", writer.written());
    }
}

test "value string encode" {
    var writer: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer writer.deinit();

    const v = Value{ .inner = .{ .string = "spam" } };
    try v.encode(&writer.writer);
    try std.testing.expectEqualStrings("4:spam", writer.written());
}

test "value list encode" {
    var writer: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer writer.deinit();

    var list = [_]Value{
        Value{ .inner = .{ .string = "spam" } },
        Value{ .inner = .{ .int = 42 } },
    };

    const v = Value{ .inner = .{ .list = .fromOwnedSlice(&list) } };
    try v.encode(&writer.writer);
    try std.testing.expectEqualStrings("l4:spami42ee", writer.written());
}

test "value dict encode" {
    var writer: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer writer.deinit();

    var map: std.StringHashMapUnmanaged(Value) = .empty;
    defer map.deinit(std.testing.allocator);

    try map.ensureTotalCapacity(std.testing.allocator, 2);

    {
        defer writer.clearRetainingCapacity();
        defer map.clearRetainingCapacity();

        map.putAssumeCapacityNoClobber("cow", .{ .inner = .{ .string = "moo" } });
        map.putAssumeCapacityNoClobber("spam", .{ .inner = .{ .string = "eggs" } });

        const v = Value{ .inner = .{ .dict = map } };
        try v.encode(&writer.writer);
        try std.testing.expectEqualStrings("d3:cow3:moo4:spam4:eggse", writer.written());
    }

    {
        defer writer.clearRetainingCapacity();
        defer map.clearRetainingCapacity();

        var list = [_]Value{
            Value{ .inner = .{ .string = "a" } },
            Value{ .inner = .{ .string = "b" } },
        };

        map.putAssumeCapacityNoClobber("spam", .{ .inner = .{ .list = .fromOwnedSlice(&list) } });

        const v = Value{ .inner = .{ .dict = map } };
        try v.encode(&writer.writer);
        try std.testing.expectEqualStrings("d4:spaml1:a1:bee", writer.written());
    }
}
