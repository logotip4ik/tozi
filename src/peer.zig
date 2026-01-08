const std = @import("std");

const proto = @import("proto.zig");

const Self = @This();

socket: std.posix.fd_t,

state: State = .handshake,
direction: enum { write, read } = .write,

choked: bool = true,
interested: bool = false,

buf: std.array_list.Aligned(u8, null) = .empty,

bitfield: ?std.DynamicBitSetUnmanaged = null,
workingOn: ?std.DynamicBitSetUnmanaged = null,

pub const State = union(enum) {
    handshake,
    messageStart,
    message: proto.Message,
    bufFlush,
    dead,
};

pub fn init(addr: std.net.Address) !Self {
    const fd = try std.posix.socket(
        std.posix.AF.INET,
        std.posix.SOCK.STREAM | std.posix.SOCK.NONBLOCK,
        std.posix.IPPROTO.TCP,
    );
    errdefer std.posix.close(fd);

    std.log.info("peer: {d} connecting to {f}", .{ fd, addr });

    std.posix.connect(@intCast(fd), &addr.any, addr.getOsSockLen()) catch |err| switch (err) {
        error.WouldBlock => {},
        else => return err,
    };

    return .{ .socket = fd };
}

pub fn deinit(self: *Self, alloc: std.mem.Allocator) void {
    if (self.state == .dead) {
        return;
    }

    self.state = .dead;

    std.posix.close(self.socket);
    self.buf.deinit(alloc);
    if (self.bitfield) |*x| x.deinit(alloc);
    if (self.workingOn) |*x| x.deinit(alloc);
}

pub fn setBitfield(self: *Self, alloc: std.mem.Allocator, bytes: []const u8) !void {
    var bitfield: std.DynamicBitSetUnmanaged = try .initEmpty(alloc, bytes.len * 8);
    defer self.bitfield = bitfield;

    for (bytes, 0..) |byte, i| {
        for (0..8) |bit_idx| {
            // Check if bit is set (MSB first), thank you gemini, but i don't get what this does
            const is_set = (byte >> @intCast(7 - bit_idx)) & 1 != 0;

            // Calculate absolute piece index
            const piece_index = (i * 8) + bit_idx;

            if (piece_index < bitfield.capacity() and is_set) {
                bitfield.set(piece_index);
            }
        }
    }
}

pub fn readInt(self: *Self, comptime T: type) !T {
    const n = @divExact(@typeInfo(T).int.bits, 8);
    var buf: [n]u8 = undefined;

    var total: usize = 0;
    while (total != n) {
        const count = std.posix.read(self.socket, buf[total..n]) catch |err| switch (err) {
            error.WouldBlock => 0,
            else => return err,
        };

        total += count;
    }

    return std.mem.readInt(T, &buf, .big);
}

pub fn readTotalBuf(self: *Self, alloc: std.mem.Allocator, size: usize) !?[]u8 {
    if (self.buf.items.len >= size) {
        return self.buf.items[0..size];
    }

    try self.buf.ensureTotalCapacity(alloc, size);

    const slice = self.buf.allocatedSlice();
    const len = self.buf.items.len;
    const count = try std.posix.read(self.socket, slice[len..size]);

    self.buf.items.len += count;

    if (self.buf.items.len >= size) {
        return self.buf.items[0..size];
    }

    return null;
}

pub fn writeTotalBuf(self: *Self, alloc: std.mem.Allocator, slice: []const u8) !?usize {
    if (self.buf.items.len == slice.len) {
        return slice.len;
    }

    try self.buf.ensureTotalCapacity(alloc, slice.len);

    const len = self.buf.items.len;
    const wrote = try std.posix.write(self.socket, slice[len..]);
    try self.buf.appendSlice(alloc, slice[len .. len + wrote]);

    if (wrote == slice.len) {
        return wrote;
    }

    return null;
}

/// returns null when there is still data pending to be written
pub fn writeBuf(self: *Self) !?void {
    if (self.buf.items.len == 0) {
        return;
    }

    const wrote = try std.posix.write(self.socket, self.buf.items);

    const left = self.buf.items.len - wrote;
    if (left == 0) {
        return;
    }

    @memmove(self.buf.items[0..left], self.buf.items[wrote .. wrote + left]);
    self.buf.items.len = left;

    return null;
}
