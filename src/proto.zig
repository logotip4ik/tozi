const std = @import("std");

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
    request: struct { index: u32, begin: u32, len: u32 },
    piece: struct { index: u32, begin: u32, len: u32 },
    cancel: struct { index: u32, begin: u32, len: u32 },
    port: u16,

    /// Length of the message defined by torrent protocol
    fn len(self: Message) u32 {
        const id_size = 1;
        const u32_size = @sizeOf(u32);

        return switch (self) {
            .choke, .unchoke, .interested, .not_interested, .port => id_size,

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
    pub fn wireLen(self: Message) u32 {
        return 4 + self.len();
    }

    pub fn writeMessage(m: Message, w: *std.Io.Writer) !void {
        try w.writeInt(u32, m.len(), .big);

        switch (m) {
            .request => |r| {
                try w.writeByte(@intFromEnum(m));
                try w.writeInt(u32, r.index, .big);
                try w.writeInt(u32, r.begin, .big);
                try w.writeInt(u32, r.len, .big);
            },
            .interested,
            .unchoke,
            .choke,
            .not_interested,
            => {
                try w.writeByte(@intFromEnum(m));
            },
            .have => |idx| {
                try w.writeByte(@intFromEnum(m));
                try w.writeInt(u32, idx, .big);
            },
            else => unreachable,
        }
    }
};
