const std = @import("std");

pub const Value = struct {
    inner: union(enum) {
        int: usize,
        string: []const u8,
        list: std.array_list.Aligned(Value, null),
        dict: std.StringHashMapUnmanaged(Value),
    },
    start: usize,
    len: usize,

    pub fn dumpWithOptions(self: Value, writer: *std.Io.Writer, indent: u8) void {
        switch (self.inner) {
            .int => |int| {
                for (0..indent) |_| writer.writeByte(' ') catch unreachable;
                writer.print("{d}\n", .{int}) catch unreachable;
            },
            .string => |string| {
                for (0..indent) |_| writer.writeByte(' ') catch unreachable;

                if (std.ascii.isAlphanumeric(string[0]) or std.unicode.utf8ValidateSlice(string)) {
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
};

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

pub fn parseValue(alloc: std.mem.Allocator, reader: *std.Io.Reader, start: usize) !Value {
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

                var value = try parseValue(alloc, reader, len);
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

                var value = try parseValue(alloc, reader, len);
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

            const int = try std.fmt.parseInt(usize, numString, 10);
            const len = 1 + numString.len + 1;

            return Value{
                .inner = .{ .int = int },
                .start = start,
                .len = len,
            };
        },

        else => {
            std.debug.print("unrecognized bencode: {s}", .{
                reader.peek(20) catch reader.buffered(),
            });
            return error.UnrecognisedBencode;
        },
    }
}

test "parseValue string" {
    var reader: std.Io.Reader = .fixed(
        \\8:announce
    );

    var value = try parseValue(std.testing.allocator, &reader, 0);
    defer value.deinit(std.testing.allocator);

    switch (value.inner) {
        .string => |string| try std.testing.expectEqualStrings("announce", string),
        else => try std.testing.expect(false),
    }
}

test "parseValue digit" {
    var reader: std.Io.Reader = .fixed(
        \\i32e
    );

    var value = try parseValue(std.testing.allocator, &reader, 0);
    defer value.deinit(std.testing.allocator);

    switch (value.inner) {
        .int => |int| try std.testing.expectEqual(32, int),
        else => try std.testing.expect(false),
    }
}

test "parseValue list" {
    var reader: std.Io.Reader = .fixed(
        \\l4:http4:http4:httpe
    );

    var value = try parseValue(std.testing.allocator, &reader, 0);
    defer value.deinit(std.testing.allocator);

    switch (value.inner) {
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

    var value = try parseValue(std.testing.allocator, &reader, 0);
    defer value.deinit(std.testing.allocator);

    switch (value.inner) {
        .dict => |dict| {
            try std.testing.expectEqual(1, dict.size);

            const v = dict.get("http") orelse unreachable;
            switch (v.inner) {
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

