const std = @import("std");
const Bencode = @import("bencode.zig");

const Handshake = @This();

pub const HANDSHAKE_LEN = 68;

reserved: Reserved,
infoHash: [20]u8,
peerId: [20]u8,

const Reserved = packed struct(u64) {
    _: u40 = 0,

    // byte 5
    _pad_b5: u4 = 0,
    extended: bool = false, // 0x10 (Bit 4): BEP 10
    _pad_b5_high: u3 = 0,

    // byte 6
    _pad_b6: u8 = 0,

    // byte 7
    dht: bool = false, // 0x01 (Bit 0): BEP 5
    _azureus: bool = false, // 0x02 (Bit 1): BEP 9
    fast: bool = false, // 0x04 (Bit 2): BEP 6
    _pad_b7: u5 = 0,
};

pub const Protocols = packed struct {
    fast: bool = false,
    extended: bool = false,
};

pub fn init(peerId: [20]u8, infoHash: [20]u8, protocols: Protocols) Handshake {
    var reserved: Reserved = .{};

    inline for (std.meta.fields(Protocols)) |field| {
        @field(reserved, field.name) = @field(protocols, field.name);
    }

    return Handshake{
        .peerId = peerId,
        .infoHash = infoHash,
        .reserved = reserved,
    };
}

pub fn asBytes(self: Handshake) [HANDSHAKE_LEN]u8 {
    var buffer: [HANDSHAKE_LEN]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);

    writer.writeByte(19) catch unreachable;
    writer.writeAll("BitTorrent protocol") catch unreachable;

    const reserved: u64 = @bitCast(self.reserved);
    writer.writeInt(u64, reserved, .little) catch unreachable;

    writer.writeAll(&self.infoHash) catch unreachable;
    writer.writeAll(&self.peerId) catch unreachable;

    return buffer;
}

const ValidateError = error{
    InvalidBuffer,
    InvalidPstrLen,
    InvalidPstr,
    InvalidInfoHash,
};

pub fn matchExtensions(self: Handshake, buffer: []const u8) ValidateError!Protocols {
    var reader: std.Io.Reader = .fixed(buffer);

    const len = reader.takeByte() catch return ValidateError.InvalidBuffer;
    if (len != 19) return ValidateError.InvalidPstrLen;

    const pstr = reader.take(19) catch return ValidateError.InvalidBuffer;
    if (!std.mem.eql(u8, "BitTorrent protocol", pstr[0..19])) {
        return ValidateError.InvalidPstr;
    }

    const reservedBytes = reader.take(8) catch return ValidateError.InvalidBuffer;
    const reserved = std.mem.bytesToValue(Reserved, reservedBytes[0..8]);

    const infoHash = reader.take(20) catch return ValidateError.InvalidBuffer;
    if (!std.mem.eql(u8, self.infoHash[0..20], infoHash[0..20])) {
        return ValidateError.InvalidInfoHash;
    }

    var proto: Protocols = .{};

    inline for (comptime std.meta.fieldNames(Protocols)) |field| {
        @field(proto, field) = @field(self.reserved, field) and @field(reserved, field);
    }

    return proto;
}

test "reserved byte positions" {
    const res = Reserved{
        .extended = true,
        .dht = true,
        .fast = true,
    };

    const bytes = @as([8]u8, @bitCast(res));

    // BEP 10: reserved[5] & 0x10
    try std.testing.expectEqual(@as(u8, 0x10), bytes[5]);
    // BEP 5 & 6: reserved[7] & 0x01 and 0x04
    try std.testing.expectEqual(@as(u8, 0x05), bytes[7]);
}

test "reserved byte positions with 'asBytes'" {
    const h: Handshake = .{
        .reserved = .{ .extended = true, .dht = true, .fast = true },
        .infoHash = undefined,
        .peerId = undefined,
    };

    const bytes = h.asBytes();
    const reservedBytes = bytes[20..28];

    // BEP 10: reserved[5] & 0x10
    try std.testing.expectEqual(@as(u8, 0x10), reservedBytes[5]);
    // BEP 5 & 6: reserved[7] & 0x01 and 0x04
    try std.testing.expectEqual(@as(u8, 0x05), reservedBytes[7]);
}

pub const Extended = struct {
    m: ?Map = .{},

    v: ?[]const u8,
    reqq: ?usize = null,

    const MAX_V_LEN = 1024;

    pub const MKey = enum(u8) {
        Handshake = 0,
        Pex = 1,
    };

    pub const Map = struct {
        pex: ?u8 = null,
        holepunch: ?u8 = null,
        metadata: ?u8 = null,
        donthave: ?u8 = null,

        pub const nameMap = std.StaticStringMap([]const u8).initComptime(&[_]struct { []const u8, []const u8 }{
            .{ "ut_pex", "pex" },
            .{ "ut_holepunch", "holepunch" },
            .{ "ut_metadata", "metadata" },
            .{ "lt_donthave", "donthave" },
        });

        pub fn parse(map: *const std.StringHashMapUnmanaged(Bencode)) Map {
            var self = Map{};

            inline for (comptime nameMap.keys()) |key| {
                const mappedKey = comptime nameMap.get(key) orelse unreachable;

                if (map.get(key)) |id| switch (id.inner) {
                    .int => |id_int| if (id_int > 0 and id_int < std.math.maxInt(u8)) {
                        @field(self, mappedKey) = @intCast(id_int);
                    },
                    else => {},
                };
            }

            return self;
        }

        pub fn fill(self: *const Map, alloc: std.mem.Allocator, map: *std.StringHashMapUnmanaged(Bencode)) !void {
            inline for (comptime nameMap.keys()) |key| {
                const mappedKey = comptime nameMap.get(key) orelse unreachable;

                if (@field(self, mappedKey)) |id| {
                    try map.putNoClobber(alloc, key, .{ .inner = .{ .int = id } });
                }
            }
        }
    };

    /// deinit is used when parsing `extended` message from other peers
    pub fn deinit(self: *const Extended, alloc: std.mem.Allocator) void {
        if (self.v) |v| alloc.free(v);
    }

    pub fn encode(
        self: *const Extended,
        alloc: std.mem.Allocator,
        writer: *std.Io.Writer,
    ) !void {
        var root: std.StringHashMapUnmanaged(Bencode) = .empty;
        defer root.deinit(alloc);

        if (self.v) |v| {
            try root.putNoClobber(alloc, "v", .{ .inner = .{ .string = v } });
        }

        var m: std.StringHashMapUnmanaged(Bencode) = .empty;
        defer m.deinit(alloc);

        if (self.m) |x| try x.fill(alloc, &m);

        try root.putNoClobber(alloc, "m", .{ .inner = .{ .dict = m } });

        var rootValue: Bencode = .{ .inner = .{ .dict = root } };
        try rootValue.encode(writer);
    }

    pub fn decode(alloc: std.mem.Allocator, reader: *std.Io.Reader) !Extended {
        var v: Bencode = try .decode(alloc, reader, 0);
        defer v.deinit(alloc);

        var extended = Extended{ .m = null, .v = null };

        const dict = switch (v.inner) {
            .dict => |d| d,
            else => return error.InvalidExtendBencode,
        };

        if (dict.get("reqq")) |reqq| switch (reqq.inner) {
            .int => |int| if (int > 0) {
                extended.reqq = @intCast(int);
            },
            else => {},
        };

        if (dict.get("v")) |version| blk: switch (version.inner) {
            .string => |string| if (string.len < MAX_V_LEN) {
                extended.v = alloc.dupe(u8, string) catch break :blk;
            },
            else => {},
        };

        if (dict.get("m")) |m| switch (m.inner) {
            .dict => |mPeer| {
                extended.m = .parse(&mPeer);
            },
            else => {},
        };

        return extended;
    }

    test "m filling" {
        const alloc = std.testing.allocator;

        const m: Map = .{ .pex = 1 };
        var map: std.hash_map.StringHashMapUnmanaged(Bencode) = .empty;
        defer map.deinit(alloc);

        try m.fill(alloc, &map);

        const value = map.get("ut_pex") orelse unreachable;
        try std.testing.expectEqualDeep(Bencode{ .inner = .{ .int = 1 } }, value);

        const value_null = map.get("ut_holepunch");
        try std.testing.expectEqual(null, value_null);
    }
};

test {
    std.testing.refAllDecls(Handshake);
}
