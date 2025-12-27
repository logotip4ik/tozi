const std = @import("std");

const Torrent = struct {
    value: Value,

    announce: []const u8,
    announceList: ?[]const []const u8,
    creation_date: ?usize,
    created_by: ?[]const u8,
    info: std.StringHashMapUnmanaged(Value) = .empty,

    pub fn deinit(self: *Torrent, alloc: std.mem.Allocator) void {
        self.value.deinit(alloc);
        if (self.announceList) |list| alloc.free(list);
    }
};

const Value = union(enum) {
    int: usize,
    string: []const u8,
    list: std.array_list.Aligned(Value, null),
    dict: std.StringHashMapUnmanaged(Value),

    fn dumpWithOptions(self: Value, writer: *std.Io.Writer, indent: u8) void {
        switch (self) {
            .int => |int| {
                for (0..indent) |_| writer.writeByte(' ') catch unreachable;
                writer.print("{d}\n", .{int}) catch unreachable;
            },
            .string => |string| {
                for (0..indent) |_| writer.writeByte(' ') catch unreachable;
                writer.print("{s}\n", .{string}) catch unreachable;
            },
            .list => |list| {
                for (list.items) |item| {
                    item.dumpWithOptions(writer, indent + 2);
                }
            },
            .dict => |dict| {
                var iter = dict.iterator();
                while (iter.next()) |entry| {
                    for (0..indent) |_| writer.writeByte(' ') catch unreachable;
                    writer.print("{s}\n", .{entry.key_ptr.*}) catch unreachable;
                    entry.value_ptr.dumpWithOptions(writer, indent + 2);
                }
            },
        }
    }

    fn dump(self: Value) void {
        var buf: [512]u8 = undefined;
        const out = std.Progress.lockStderrWriter(&buf);
        defer out.flush() catch {};

        out.print("======= VALUE DUMP =======\n", .{}) catch unreachable;

        self.dumpWithOptions(out, 0);
    }

    fn deinit(self: *Value, alloc: std.mem.Allocator) void {
        switch (self.*) {
            Value.int => {},
            Value.string => |string| alloc.free(string),
            Value.list => |*list| {
                for (list.items) |*item| item.deinit(alloc);
                list.deinit(alloc);
            },
            Value.dict => |*dict| {
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

fn parseString(alloc: std.mem.Allocator, reader: *std.Io.Reader) ![]const u8 {
    const keyLengthString = try reader.takeDelimiter(':') orelse {
        std.log.err("expected key length to be present", .{});
        return error.MissingColon;
    };

    const keyLength = try std.fmt.parseUnsigned(usize, keyLengthString, 10);
    return try reader.readAlloc(alloc, keyLength);
}

pub fn parseValue(alloc: std.mem.Allocator, reader: *std.Io.Reader) !Value {
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

            while (reader.peekByte() catch null) |next| {
                if (next == 'e') {
                    _ = try reader.discardShort(1);
                    break;
                }

                const key = try parseString(alloc, reader);
                errdefer alloc.free(key);

                // std.debug.print("key: {s}\n", .{key});

                var value = try parseValue(alloc, reader);
                errdefer value.deinit(alloc);

                // switch (value) {
                //     .string => |string| std.debug.print("value string: {s}\n", .{string}),
                //     .int => |int| std.debug.print("value int: {d}\n", .{int}),
                //     .list => |list| std.debug.print("value list: {d}\n", .{list.items.len}),
                //     .dict => |dict| std.debug.print("value dict: {d}\n", .{dict.size}),
                // }

                try ret.put(alloc, key, value);
            }

            return .{ .dict = ret };
        },

        'l' => {
            _ = try reader.discardShort(1);

            var ret: std.array_list.Aligned(Value, null) = .empty;
            errdefer {
                for (ret.items) |*item| item.deinit(alloc);
                ret.deinit(alloc);
            }

            while (reader.peekByte() catch null) |next| {
                if (next == 'e') {
                    _ = try reader.discardShort(1);
                    break;
                }

                var value = try parseValue(alloc, reader);
                errdefer value.deinit(alloc);

                // switch (value) {
                //     .string => |string| std.debug.print("parsed list string: {s}\n", .{string}),
                //     .int => |int| std.debug.print("parsed list int: {d}\n", .{int}),
                //     .list => |list| std.debug.print("parsed list list: {d}\n", .{list.items.len}),
                //     .dict => |dict| std.debug.print("parsed list dict: {d}\n", .{dict.size}),
                // }

                try ret.append(alloc, value);
            }

            return .{ .list = ret };
        },

        '0'...'9' => {
            return .{ .string = try parseString(alloc, reader) };
        },

        'i' => {
            _ = try reader.discardShort(1);

            const numString = try reader.takeDelimiter('e') orelse return error.MissingNumEndMark;

            const int = try std.fmt.parseInt(usize, numString, 10);

            return .{ .int = int };
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

    var value = try parseValue(std.testing.allocator, &reader);
    defer value.deinit(std.testing.allocator);

    switch (value) {
        .string => try std.testing.expectEqualStrings("announce", value.string),
        else => try std.testing.expect(false),
    }
}

test "parseValue digit" {
    var reader: std.Io.Reader = .fixed(
        \\i32e
    );

    var value = try parseValue(std.testing.allocator, &reader);
    defer value.deinit(std.testing.allocator);

    switch (value) {
        .int => try std.testing.expectEqual(32, value.int),
        else => try std.testing.expect(false),
    }
}

test "parseValue list" {
    var reader: std.Io.Reader = .fixed(
        \\l4:http4:http4:httpe
    );

    var value = try parseValue(std.testing.allocator, &reader);
    defer value.deinit(std.testing.allocator);

    switch (value) {
        .list => |list| {
            try std.testing.expectEqual(3, list.items.len);
            try std.testing.expectEqualStrings("http", list.items[0].string);
            try std.testing.expectEqualStrings("http", list.items[1].string);
            try std.testing.expectEqualStrings("http", list.items[2].string);
        },
        else => try std.testing.expect(false),
    }
}

test "parseValue dict" {
    var reader: std.Io.Reader = .fixed(
        \\d4:httpl4:httpee
    );

    var value = try parseValue(std.testing.allocator, &reader);
    defer value.deinit(std.testing.allocator);

    switch (value) {
        .dict => |dict| {
            try std.testing.expectEqual(1, dict.size);

            const v = dict.get("http") orelse unreachable;
            switch (v) {
                .list => |l| {
                    try std.testing.expectEqual(1, l.items.len);
                    try std.testing.expectEqualStrings("http", l.items[0].string);
                },
                else => try std.testing.expect(false),
            }
        },
        else => try std.testing.expect(false),
    }
}

pub fn parseTorrent(alloc: std.mem.Allocator, reader: *std.Io.Reader) !Torrent {
    var value = try parseValue(alloc, reader);
    errdefer value.deinit(alloc);

    const dict = value.dict;

    return Torrent{
        .value = value,
        .announce = if (dict.get("announce")) |v| v.string else return error.MissingAnnounce,
        .announceList = if (dict.get("announce-list")) |v| blk: {
            const list = v.list.items[0].list;

            const ret = try alloc.alloc([]const u8, list.items.len);
            errdefer alloc.free(ret);

            for (list.items, 0..) |item, i| ret[i] = item.string;

            break :blk ret;
        } else null,
        .created_by = null,
        .creation_date = null,
        .info = if (dict.get("info")) |v| v.dict else return error.MissingInfo,
    };
}

test "parseTorrent - simple" {
    const file = @embedFile("./testing.torrent");
    var reader: std.Io.Reader = .fixed(file);

    var torrent = try parseTorrent(std.testing.allocator, &reader);
    defer torrent.deinit(std.testing.allocator);
}
