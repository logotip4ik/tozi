const std = @import("std");

const Torrent = @import("torrent.zig");

pub const TCP_HANDSHAKE_LEN = 68;
pub const TcpHandshake = extern struct {
    pstrlen: u8 = 19,
    pstr: [19]u8 = "BitTorrent protocol".*,
    reserved: [8]u8 = [_]u8{0} ** 8,
    infoHash: [20]u8,
    peerId: [20]u8,

    const ValidateError = error{ InvalidPstrLen, InvalidPstr, InvalidInfoHash };

    pub fn validate(self: TcpHandshake, other: TcpHandshake) ValidateError!void {
        if (self.pstrlen != other.pstrlen) {
            return error.InvalidPstrLen;
        }

        if (!std.mem.eql(u8, &self.pstr, &other.pstr)) {
            return error.InvalidPstr;
        }

        if (!std.mem.eql(u8, &self.infoHash, &other.infoHash)) {
            return error.InvalidInfoHash;
        }
    }
};

comptime {
    if (@sizeOf(TcpHandshake) != TCP_HANDSHAKE_LEN) @compileError("TcpHandshake has invalid size");
}

pub const Piece = struct { index: u32, begin: u32, len: u32 };

pub const MessageId = enum(u8) {
    choke = 0,
    unchoke = 1,
    interested = 2,
    not_interested = 3,
    have = 4,
    bitfield = 5,
    request = 6,
    piece = 7,
    cancel = 8,
    port = 9,
};

pub const Message = union(MessageId) {
    choke: void,
    unchoke: void,
    interested: void,
    not_interested: void,
    have: u32,
    bitfield: u32,
    request: Piece,
    piece: Piece,
    cancel: Piece,
    port: u16,

    /// Length of the message defined by torrent protocol
    inline fn len(self: Message) u32 {
        const id_size = 1;
        const u32_size = @sizeOf(u32);

        return switch (self) {
            .choke, .unchoke, .interested, .not_interested => id_size,

            .port => id_size + @sizeOf(u16),

            // ID (1) + Index (4)
            .have => id_size + u32_size,

            // ID (1) + Raw bytes
            .bitfield => |l| id_size + l,

            // ID (1) + Index (4) + Begin (4) + Length (4)
            .request, .cancel => id_size + (u32_size * 3),

            // ID (1) + Index (4) + Begin (4) + Raw block data
            .piece => |p| id_size + (u32_size * 2) + p.len,
        };
    }

    /// length required to write message to buf. It requires 4 bytes more for actual `len` prefix of
    /// the message
    pub inline fn wireLen(self: Message) u32 {
        return 4 + self.len();
    }

    pub inline fn writeMessage(m: Message, w: *std.Io.Writer, data: []const u8) !void {
        try w.writeInt(u32, m.len(), .big);
        try w.writeByte(@intFromEnum(m));

        switch (m) {
            .choke, .unchoke, .interested, .not_interested => {},
            .have => |idx| try w.writeInt(u32, idx, .big),
            .port => |p| try w.writeInt(u16, p, .big),
            .bitfield => try w.writeAll(data),
            .request, .cancel => |r| {
                try w.writeInt(u32, r.index, .big);
                try w.writeInt(u32, r.begin, .big);
                try w.writeInt(u32, r.len, .big);
            },
            .piece => |p| {
                try w.writeInt(u32, p.index, .big);
                try w.writeInt(u32, p.begin, .big);
                try w.writeAll(data);
            },
        }
    }
};

pub fn writeRequestsBatch(writer: *std.Io.Writer, index: u32, pieceLen: u32) !void {
    const numberOfRequests = try std.math.divCeil(u32, pieceLen, Torrent.BLOCK_SIZE);

    for (0..numberOfRequests) |i| {
        const begin: u32 = @intCast(i * Torrent.BLOCK_SIZE);

        const message: Message = .{ .request = .{
            .index = index,
            .begin = begin,
            .len = if (begin + Torrent.BLOCK_SIZE <= pieceLen)
                Torrent.BLOCK_SIZE
            else
                pieceLen - begin,
        } };

        try message.writeMessage(writer);
    }
}
