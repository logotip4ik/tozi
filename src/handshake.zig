const std = @import("std");

const utils = @import("utils");
const Bencode = @import("bencode.zig");

const Handshake = @This();

pub const HANDSHAKE_LEN = 68;

reserved: Reserved,
info_hash: [20]u8,
peer_id: [20]u8,

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

pub fn init(peer_id: [20]u8, info_hash: [20]u8, protocols: Protocols) Handshake {
    var reserved: Reserved = .{};

    inline for (std.meta.fields(Protocols)) |field| {
        @field(reserved, field.name) = @field(protocols, field.name);
    }

    return Handshake{
        .peer_id = peer_id,
        .info_hash = info_hash,
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

    writer.writeAll(&self.info_hash) catch unreachable;
    writer.writeAll(&self.peer_id) catch unreachable;

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

    const reserved_bytes = reader.take(8) catch return ValidateError.InvalidBuffer;
    const reserved = std.mem.bytesToValue(Reserved, reserved_bytes[0..8]);

    const info_hash = reader.take(20) catch return ValidateError.InvalidBuffer;
    if (!std.mem.eql(u8, self.info_hash[0..20], info_hash[0..20])) {
        return ValidateError.InvalidInfoHash;
    }

    var proto: Protocols = .{};

    inline for (std.meta.fields(Protocols)) |field| {
        @field(proto, field.name) = @field(self.reserved, field.name) and @field(reserved, field.name);
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
        .info_hash = undefined,
        .peer_id = undefined,
    };

    const bytes = h.asBytes();
    const reservedBytes = bytes[20..28];

    // BEP 10: reserved[5] & 0x10
    try std.testing.expectEqual(@as(u8, 0x10), reservedBytes[5]);
    // BEP 5 & 6: reserved[7] & 0x01 and 0x04
    try std.testing.expectEqual(@as(u8, 0x05), reservedBytes[7]);
}

pub const Extended = struct {
    map: ?Map = .{},
    client_name: ?[]const u8 = null,
    req_queue: ?usize = null,
    your_ip: ?[4]u8 = null,
    metadata_size: ?u32 = null,

    const CLIENT_NAME_LEN_MAX = 1024;

    pub const Key = enum(u8) {
        Handshake = 0,
        Pex,
        Donthave,
        Metadata,
    };

    pub const Map = struct {
        pex: ?u8 = null,
        holepunch: ?u8 = null,
        metadata: ?u8 = null,
        donthave: ?u8 = null,

        pub const name_map = std.StaticStringMap([]const u8).initComptime(&[_]struct { []const u8, []const u8 }{
            .{ "ut_pex", "pex" },
            .{ "ut_holepunch", "holepunch" },
            .{ "ut_metadata", "metadata" },
            .{ "lt_donthave", "donthave" },
        });

        pub fn parse(map: *const std.StringHashMapUnmanaged(Bencode)) Map {
            var self = Map{};

            inline for (comptime name_map.keys()) |key| {
                const self_key = comptime name_map.get(key) orelse unreachable;

                if (map.get(key)) |id| switch (id.inner) {
                    .int => |id_int| if (id_int > 0 and id_int < std.math.maxInt(u8)) {
                        @field(self, self_key) = @intCast(id_int);
                    },
                    else => {},
                };
            }

            return self;
        }

        pub fn fill(self: *const Map, alloc: std.mem.Allocator, map: *std.StringHashMapUnmanaged(Bencode)) !void {
            inline for (comptime name_map.keys()) |key| {
                const self_key = comptime name_map.get(key) orelse unreachable;

                if (@field(self, self_key)) |id| {
                    try map.putNoClobber(alloc, key, .{ .inner = .{ .int = id } });
                }
            }
        }
    };

    /// deinit is used when parsing `extended` message from other peers
    pub fn deinit(self: *const Extended, alloc: std.mem.Allocator) void {
        if (self.client_name) |x| alloc.free(x);
    }

    pub fn encode(
        self: *const Extended,
        alloc: std.mem.Allocator,
        writer: *std.Io.Writer,
    ) !void {
        var root: std.StringHashMapUnmanaged(Bencode) = .empty;
        defer root.deinit(alloc);

        if (self.client_name) |client_name| {
            try root.putNoClobber(alloc, "v", .{ .inner = .{ .string = client_name } });
        }

        var m: std.StringHashMapUnmanaged(Bencode) = .empty;
        defer m.deinit(alloc);

        if (self.map) |map| try map.fill(alloc, &m);

        try root.putNoClobber(alloc, "m", .{ .inner = .{ .dict = m } });

        if (self.req_queue) |req_queue| {
            utils.assert(req_queue > 0);
            try root.putNoClobber(alloc, "reqq", .{ .inner = .{ .int = @intCast(req_queue) } });
        }

        if (self.your_ip) |your_ip| {
            try root.putNoClobber(alloc, "yourip", .{ .inner = .{ .string = &your_ip } });
        }

        var value: Bencode = .{ .inner = .{ .dict = root } };
        try value.encode(writer);
    }

    pub fn decode(alloc: std.mem.Allocator, bytes: []const u8) !Extended {
        var reader: std.Io.Reader = .fixed(bytes);

        var v: Bencode = try .decode(alloc, &reader, 0);
        defer v.deinit(alloc);

        var extended = Extended{};

        const dict = switch (v.inner) {
            .dict => |d| d,
            else => return error.InvalidExtendBencode,
        };

        if (dict.get("reqq")) |x| switch (x.inner) {
            .int => |req_queue| if (req_queue > 0) {
                extended.req_queue = @intCast(req_queue);
            },
            else => {},
        };

        if (dict.get("metadata_size")) |x| switch (x.inner) {
            .int => |metadata_size| if (metadata_size > 0 and metadata_size < std.math.maxInt(u32)) {
                extended.metadata_size = @intCast(metadata_size);
            },
            else => {},
        };

        if (dict.get("v")) |x| blk: switch (x.inner) {
            .string => |client_name| if (client_name.len < CLIENT_NAME_LEN_MAX) {
                extended.client_name = alloc.dupe(u8, client_name) catch break :blk;
            },
            else => {},
        };

        if (dict.get("m")) |x| switch (x.inner) {
            .dict => |map| {
                extended.map = .parse(&map);
            },
            else => {},
        };

        if (dict.get("yourip")) |x| switch (x.inner) {
            .string => |your_ip| if (your_ip.len == 4) {
                extended.your_ip = your_ip[0..4].*;
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
