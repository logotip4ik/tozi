const std = @import("std");

const Handshake = @This();

pub const HANDSHAKE_LEN = 68;

reserved: Reserved,
infoHash: [20]u8,
peerId: [20]u8,

const Reserved = packed struct(u64) {
    _: u40 = 0,

    // byte 5
    _pad_b5: u4 = 0,
    extension: bool = false, // 0x10 (Bit 4): BEP 10
    _pad_b5_high: u3 = 0,

    // byte 6
    _pad_b6: u8 = 0,

    // byte 7
    dht: bool = false, // 0x01 (Bit 0): BEP 5
    _azureus: bool = false, // 0x02 (Bit 1): BEP 9
    fast: bool = false, // 0x04 (Bit 2): BEP 6
    _pad_b7: u5 = 0,
};

pub const Extensions = packed struct {
    fast: bool = false,
};

pub fn init(peerId: [20]u8, infoHash: [20]u8, extenstions: Extensions) Handshake {
    return Handshake{
        .peerId = peerId,
        .infoHash = infoHash,
        .reserved = .{ .fast = extenstions.fast },
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

pub fn matchExtensions(self: Handshake, buffer: []const u8) ValidateError!Extensions {
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

    return Extensions{
        .fast = self.reserved.fast and reserved.fast,
    };
}

test "reserved byte positions" {
    const res = Reserved{
        .extension = true,
        .dht = true,
        .fast = true,
    };

    const bytes = @as([8]u8, @bitCast(res));

    // BEP 10: reserved[5] & 0x10
    try std.testing.expectEqual(@as(u8, 0x10), bytes[5]);
    // BEP 5 & 6: reserved[7] & 0x01 and 0x04
    try std.testing.expectEqual(@as(u8, 0x05), bytes[7]);
}
