const std = @import("std");

pub const Piece = struct {
    index: u32,
    begin: u32,
    len: u32,
};

pub const Extended = struct {
    /// The extended message ID (0 for handshake, or as specified in the handshake)
    id: u8,
    /// Length of the extended payload
    len: u32,
};

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

    // Fast Extension (BEP 6)
    suggest_piece = 13,
    have_all = 14,
    have_none = 15,
    reject_request = 16,
    allowed_fast = 17,

    // Extension Protocol (BEP 10)
    extended = 20,

    pub inline fn messageStartLen(self: MessageId) usize {
        const initialOffset = @sizeOf(u32) + @sizeOf(u8);

        const rest: usize = switch (self) {
            .choke, .unchoke, .interested, .not_interested, .bitfield, .have_all, .have_none => 0,
            .have, .suggest_piece, .allowed_fast => @sizeOf(u32),
            .piece => @sizeOf(u32) * 2,
            .request, .cancel, .reject_request => @sizeOf(u32) * 3,
            .port => @sizeOf(u16),
            .extended => 1,
        };

        return initialOffset + rest;
    }
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

    // Fast Extension
    suggest_piece: u32,
    have_all: void,
    have_none: void,
    reject_request: Piece,
    allowed_fast: u32,

    // Extension Protocol
    extended: Extended,

    /// Length of the message defined by torrent protocol
    fn len(self: Message) u32 {
        const idSize = 1;
        const u32Size = @sizeOf(u32);

        return switch (self) {
            .choke,
            .unchoke,
            .interested,
            .not_interested,
            .have_all,
            .have_none,
            => idSize,

            .port => idSize + @sizeOf(u16),

            // ID (1) + Index (4)
            .have, .suggest_piece, .allowed_fast => idSize + u32Size,

            // ID (1) + Raw bytes
            .bitfield => |l| idSize + l,

            // ID (1) + Index (4) + Begin (4) + Length (4)
            .request, .cancel, .reject_request => idSize + (u32Size * 3),

            // ID (1) + Index (4) + Begin (4) + Raw block data
            .piece => |p| idSize + (u32Size * 2) + p.len,

            // BEP 10: ID (1) + Extended ID (1) + Payload Len
            .extended => |e| idSize + 1 + e.len,
        };
    }

    pub fn writeMessage(m: Message, w: *std.Io.Writer, data: []const u8) !void {
        try w.writeInt(u32, m.len(), .big);
        try w.writeByte(@intFromEnum(m));

        switch (m) {
            .choke,
            .unchoke,
            .interested,
            .not_interested,
            .have_all,
            .have_none,
            => {},

            .have, .suggest_piece, .allowed_fast => |idx| try w.writeInt(u32, idx, .big),

            .port => |p| try w.writeInt(u16, p, .big),

            .bitfield => try w.writeAll(data),

            .request, .cancel, .reject_request => |r| {
                try w.writeInt(u32, r.index, .big);
                try w.writeInt(u32, r.begin, .big);
                try w.writeInt(u32, r.len, .big);
            },

            .piece => |p| {
                try w.writeInt(u32, p.index, .big);
                try w.writeInt(u32, p.begin, .big);
                try w.writeAll(data);
            },

            .extended => |e| {
                try w.writeByte(e.id);
                try w.writeAll(data);
            },
        }
    }
};
