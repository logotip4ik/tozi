const std = @import("std");

const Torrent = @import("torrent.zig");

pub const Piece = struct {
    index: u32,
    begin: u32,
    len: u32,
};

pub const MessageId = enum(u8) {
    choke = 0,
    unchoke = 1,
    interested = 2,
    notInterested = 3,
    have = 4,
    bitfield = 5,
    request = 6,
    piece = 7,
    cancel = 8,
    port = 9,

    // Fast Extension (BEP 6)
    suggestPiece = 13,
    haveAll = 14,
    haveNone = 15,
    rejectRequest = 16,
    allowedFast = 17,

    pub fn messageStartLen(self: MessageId) usize {
        const initialOffset = @sizeOf(u32) + @sizeOf(u8);

        const rest: usize = switch (self) {
            .choke, .unchoke, .interested, .notInterested, .bitfield, .haveAll, .haveNone => 0,
            .have, .suggestPiece, .allowedFast => @sizeOf(u32),
            .piece => @sizeOf(u32) * 2,
            .request, .cancel, .rejectRequest => @sizeOf(u32) * 3,
            .port => @sizeOf(u16),
        };

        return initialOffset + rest;
    }
};

pub const Message = union(MessageId) {
    choke: void,
    unchoke: void,
    interested: void,
    notInterested: void,
    have: u32,
    bitfield: u32,
    request: Piece,
    piece: Piece,
    cancel: Piece,
    port: u16,

    // Fast Extension
    suggestPiece: u32,
    haveAll: void,
    haveNone: void,
    rejectRequest: Piece,
    allowedFast: u32,

    /// Length of the message defined by torrent protocol
    inline fn len(self: Message) u32 {
        const id_size = 1;
        const u32_size = @sizeOf(u32);

        return switch (self) {
            .choke,
            .unchoke,
            .interested,
            .notInterested,
            .haveAll,
            .haveNone,
            => id_size,

            .port => id_size + @sizeOf(u16),

            // ID (1) + Index (4)
            .have, .suggestPiece, .allowedFast => id_size + u32_size,

            // ID (1) + Raw bytes
            .bitfield => |l| id_size + l,

            // ID (1) + Index (4) + Begin (4) + Length (4)
            .request, .cancel, .rejectRequest => id_size + (u32_size * 3),

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
            .choke,
            .unchoke,
            .interested,
            .notInterested,
            .haveAll,
            .haveNone,
            => {},

            .have, .suggestPiece, .allowedFast => |idx| try w.writeInt(u32, idx, .big),

            .port => |p| try w.writeInt(u16, p, .big),

            .bitfield => try w.writeAll(data),

            .request, .cancel, .rejectRequest => |r| {
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
