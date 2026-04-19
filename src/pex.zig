const std = @import("std");

const Bencode = @import("bencode.zig");
const utils = @import("utils.zig");

added: std.array_list.Aligned(AddedEntry, null) = .empty,

dropped: std.array_list.Aligned(std.Io.net.IpAddress, null) = .empty,

const Pex = @This();

const AddedEntry = struct { addr: std.Io.net.IpAddress, flags: PexFlagByte };

pub const TIMEOUT_DEFAULT = 60 * std.time.ms_per_s;

pub const ADDED_MAX_DEFAULT = 50;

pub const PexFlagByte = packed struct(u8) {
    /// Prefers encryption
    encryption: bool = false,
    /// Is a seeder
    seed: bool = false,
    /// Supports uTP
    utp: bool = false,
    /// Supports BEP 55
    holepunch: bool = false,
    /// You connected TO them / they aren't firewalled
    reachable: bool = false,
    _: u3 = 0,
};

pub fn deinit(self: *Pex, alloc: std.mem.Allocator) void {
    self.added.deinit(alloc);
    self.dropped.deinit(alloc);
}

pub fn exportMessage(self: *const Pex, alloc: std.mem.Allocator) ![]u8 {
    var writer: std.Io.Writer.Allocating = .init(alloc);
    defer writer.deinit();

    var root = Bencode{ .inner = .{ .dict = .empty } };
    defer {
        var iter = root.inner.dict.iterator();
        while (iter.next()) |*entry| {
            entry.value_ptr.deinit(alloc);
        }
        root.inner.dict.deinit(alloc);
    }

    if (self.added.items.len > 0) {
        // yes, `added` could get leaked if `put` fails, and i ignore it.
        const added = try alloc.alloc(u8, self.added.items.len * 6);
        try root.inner.dict.putNoClobber(alloc, "added", .{ .inner = .{ .string = added } });

        const flags = try alloc.alloc(u8, self.added.items.len);
        try root.inner.dict.putNoClobber(alloc, "added.f", .{ .inner = .{ .string = flags } });

        for (self.added.items, 0..) |entry, i| {
            const start = i * 6;
            utils.compactAddress(entry.addr, added[start..][0..6]);
            flags[i] = @bitCast(entry.flags);
        }
    }

    if (self.dropped.items.len > 0) {
        // yes, `dropped` could get leaked if `put` fails, and i ignore it.
        const dropped = try alloc.alloc(u8, self.dropped.items.len * 6);
        try root.inner.dict.putNoClobber(alloc, "dropped", .{ .inner = .{ .string = dropped } });

        for (self.dropped.items, 0..) |addr, i| {
            const start = i * 6;
            utils.compactAddress(addr, dropped[start..][0..6]);
        }
    }

    try root.encode(&writer.writer);
    const bytes = try writer.toOwnedSlice();

    return bytes;
}

pub fn parse(alloc: std.mem.Allocator, bytes: []const u8) !Pex {
    var r: std.Io.Reader = .fixed(bytes);
    var value: Bencode = try .decode(alloc, &r, 0);
    defer value.deinit(alloc);

    const dict = switch (value.inner) {
        .dict => |d| d,
        else => return error.InvalidPexBytes,
    };

    var pex: Pex = .{};
    errdefer pex.deinit(alloc);

    // TODO: add added6 handling
    if (dict.get("added")) |x| switch (x.inner) {
        .string => |added| if (@rem(added.len, 6) == 0 and added.len > 0) {
            var iter = std.mem.window(u8, added, 6, 6);

            while (iter.next()) |str| {
                const in = str[0..6];

                try pex.added.append(alloc, .{
                    .addr = utils.parseCompactAddress(in.*),
                    .flags = .{},
                });
            }
        },
        else => {},
    };

    if (dict.get("added.f")) |x| switch (x.inner) {
        .string => |flags| if (flags.len == pex.added.items.len) {
            for (0..flags.len) |i| {
                pex.added.items[i].flags = @bitCast(flags[i]);
            }
        },
        else => {},
    };

    if (dict.get("dropped")) |x| switch (x.inner) {
        .string => |dropped| if (@rem(dropped.len, 6) == 0 and dropped.len > 0) {
            var iter = std.mem.window(u8, dropped, 6, 6);

            while (iter.next()) |str| {
                const in = str[0..6];

                try pex.dropped.append(alloc, utils.parseCompactAddress(in.*));
            }
        },
        else => {},
    };

    return pex;
}

test "parse" {
    const bytes = "d5:added12:\x01\x01\x01\x01\x00\x50\x02\x02\x02\x02\x01\xbb7:dropped6:\x03\x03\x03\x03\x00\x16e";

    const alloc = std.testing.allocator;
    var pex: Pex = try .parse(alloc, bytes);
    defer pex.deinit(alloc);

    try std.testing.expectEqual(2, pex.added.items.len);
    try std.testing.expectEqual(1, pex.dropped.items.len);

    {
        const expected = std.Io.net.Ip4Address.parse("1.1.1.1", 80) catch unreachable;

        try std.testing.expectEqualDeep(expected, pex.added.items[0].addr.ip4);
    }

    {
        const expected = std.Io.net.Ip4Address.parse("2.2.2.2", 443) catch unreachable;

        try std.testing.expectEqualDeep(expected, pex.added.items[1].addr.ip4);
    }

    {
        const expected = std.Io.net.Ip4Address.parse("3.3.3.3", 22) catch unreachable;

        try std.testing.expectEqualDeep(expected, pex.dropped.items[0].ip4);
    }
}

test "parse with flags" {
    const bytes = "d5:added12:\xc0\xa8\x01\x05\x1a\xe1\x0a\x00\x00\x01\x1f\x907:added.f2:\x01\x027:dropped6:\x04\x04\x04\x04\x00\x35e";

    const alloc = std.testing.allocator;
    var pex: Pex = try .parse(alloc, bytes);
    defer pex.deinit(alloc);

    try std.testing.expectEqual(2, pex.added.items.len);
    try std.testing.expectEqual(1, pex.dropped.items.len);

    {
        const expected = std.Io.net.Ip4Address.parse("192.168.1.5", 6881) catch unreachable;
        const entry = pex.added.items[0];

        try std.testing.expectEqualDeep(expected, entry.addr.ip4);
        try std.testing.expectEqualDeep(PexFlagByte{ .encryption = true }, entry.flags);
    }

    {
        const expected = std.Io.net.Ip4Address.parse("10.0.0.1", 8080) catch unreachable;
        const entry = pex.added.items[1];

        try std.testing.expectEqualDeep(expected, entry.addr.ip4);
        try std.testing.expectEqualDeep(PexFlagByte{ .seed = true }, entry.flags);
    }

    {
        const expected = std.Io.net.Ip4Address.parse("4.4.4.4", 53);

        try std.testing.expectEqualDeep(expected, pex.dropped.items[0].ip4);
    }
}

test "exportMessage" {
    const alloc = std.testing.allocator;

    var pex = Pex{};
    defer pex.deinit(alloc);

    try pex.added.append(alloc, .{
        .addr = try .parseIp4("127.0.0.1", 6881),
        .flags = .{ .seed = true, .reachable = true },
    });

    const addr_dropped = std.Io.net.IpAddress.parse("8.8.8.8", 53) catch unreachable;
    try pex.dropped.append(alloc, addr_dropped);

    // 3. Run export
    const result = try pex.exportMessage(alloc);
    defer alloc.free(result);

    const expected = "d5:added6:\x7f\x00\x00\x01\x1a\xe17:added.f1:\x127:dropped6:\x08\x08\x08\x08\x00\x35e";

    try std.testing.expectEqualStrings(expected, result);
}
