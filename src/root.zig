const std = @import("std");

const Torrent = struct {
    value: Value,

    announce: []const u8,
    announceList: ?[]const []const u8,
    creation_date: ?usize,
    created_by: ?[]const u8,
    info: std.StringHashMapUnmanaged(Value) = .empty,

    /// reader must be recreated to seek from start of the file
    pub fn computeInfoHash(self: Torrent, reader: *std.Io.Reader) ![std.crypto.hash.Sha1.digest_length]u8 {
        const info = self.value.inner.dict.get("info") orelse unreachable;

        _ = try reader.discardShort(info.start);

        var hash: std.crypto.hash.Sha1 = .init(.{});

        var read: usize = 0;
        while (true) {
            const readSize = @min(std.crypto.hash.Sha1.block_length, info.len - read);
            const chunk = try reader.take(readSize);

            hash.update(chunk);
            read += readSize;

            if (read == info.len) {
                break;
            }
        }

        return hash.finalResult();
    }

    pub fn deinit(self: *Torrent, alloc: std.mem.Allocator) void {
        self.value.deinit(alloc);
        if (self.announceList) |list| alloc.free(list);
    }
};

const Value = struct {
    inner: union(enum) {
        int: usize,
        string: []const u8,
        list: std.array_list.Aligned(Value, null),
        dict: std.StringHashMapUnmanaged(Value),
    },
    start: usize,
    len: usize,

    fn dumpWithOptions(self: Value, writer: *std.Io.Writer, indent: u8) void {
        switch (self.inner) {
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

pub fn parseTorrent(alloc: std.mem.Allocator, reader: *std.Io.Reader) !Torrent {
    var value = try parseValue(alloc, reader, 0);
    errdefer value.deinit(alloc);

    const dict = value.inner.dict;

    return Torrent{
        .value = value,
        .announce = if (dict.get("announce")) |v| v.inner.string else return error.MissingAnnounce,
        .announceList = if (dict.get("announce-list")) |v| blk: {
            const list = v.inner.list.items[0].inner.list;

            const ret = try alloc.alloc([]const u8, list.items.len);
            errdefer alloc.free(ret);

            for (list.items, 0..) |item, i| ret[i] = item.inner.string;

            break :blk ret;
        } else null,
        .created_by = null,
        .creation_date = null,
        .info = if (dict.get("info")) |v| v.inner.dict else return error.MissingInfo,
    };
}

test "parseTorrent - simple" {
    const file = @embedFile("./testing.torrent");
    var reader: std.Io.Reader = .fixed(file);

    var torrent = try parseTorrent(std.testing.allocator, &reader);
    defer torrent.deinit(std.testing.allocator);
}

test "parseTorrent - info hash" {
    const file = @embedFile("./testing.torrent");
    var reader: std.Io.Reader = .fixed(file);

    var torrent = try parseTorrent(std.testing.allocator, &reader);
    defer torrent.deinit(std.testing.allocator);

    reader = .fixed(file);

    const hash = try torrent.computeInfoHash(&reader);
    std.debug.print("{s}", .{std.fmt.bytesToHex(hash, .lower)});
}
