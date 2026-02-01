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
        if (@field(protocols, field.name)) {
            @field(reserved, field.name) = true;
        }
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

    return Protocols{
        .fast = self.reserved.fast and reserved.fast,
    };
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
    m: ?struct {} = .{},
    v: ?[]const u8 = "Tozi 0.1",
    reqq: ?usize = null,

    const MAX_V_LEN = 1024;

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

        const m: std.StringHashMapUnmanaged(Bencode) = .empty;
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

        return extended;
    }
};
