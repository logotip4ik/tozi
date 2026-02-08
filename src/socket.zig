const std = @import("std");

const Socket = @This();

const ReadError = std.Io.Reader.Error;
const WriteError = std.Io.Writer.Error;

vtable: *const VTable,

const VTable = struct {
    /// null means, "WouldBlock", which requires another call of `read` after `read` event from kq
    read: *const fn (*Socket, buf: []u8) ReadError!?usize,
    /// null means, "WouldBlock", which requires another call of `write` after `write` event from kq
    write: *const fn (*Socket, buf: []const u8) WriteError!?usize,
};

/// null means, "WouldBlock", which requires another call of `read` after `read` event from kq
pub fn read(s: *Socket, buf: []u8) ReadError!?usize {
    return s.vtable.read(s, buf);
}

/// null means, "WouldBlock", which requires another call of `write` after `write` event from kq
pub fn write(s: *Socket, buf: []const u8) WriteError!?usize {
    return s.vtable.write(s, buf);
}

pub const Posix = struct {
    fd: std.posix.socket_t,

    interface: Socket,

    pub fn init(socket: std.posix.socket_t) Posix {
        return .{
            .fd = socket,
            .interface = .{ .vtable = &Posix.vtable },
        };
    }

    const vtable = VTable{ .read = Posix.read, .write = Posix.write };

    fn read(s: *Socket, buf: []u8) ReadError!?usize {
        const p: *const Posix = @fieldParentPtr("interface", s);

        const n = std.posix.read(p.fd, buf) catch |err| switch (err) {
            error.WouldBlock => return null,
            else => return ReadError.ReadFailed,
        };

        if (n == 0) {
            return ReadError.EndOfStream;
        }

        return n;
    }

    fn write(s: *Socket, buf: []const u8) WriteError!?usize {
        const p: *const Posix = @fieldParentPtr("interface", s);

        const n = std.posix.write(p.fd, buf) catch |err| switch (err) {
            error.WouldBlock => return null,
            else => return WriteError.WriteFailed,
        };

        if (n == 0) {
            return WriteError.WriteFailed;
        }

        return n;
    }
};

pub const Allocating = struct {
    alloc: std.mem.Allocator,

    singleOperationCountMax: u16,

    bufferIn: std.array_list.Aligned(u8, null),
    bufferOut: std.array_list.Aligned(u8, null),

    interface: Socket,

    pub fn init(alloc: std.mem.Allocator, singleOperationCountMax: u16) Allocating {
        return .{
            .alloc = alloc,
            .singleOperationCountMax = singleOperationCountMax,
            .bufferIn = .empty,
            .bufferOut = .empty,
            .interface = .{ .vtable = &Allocating.vtable },
        };
    }

    pub fn deinit(self: *Allocating) void {
        self.bufferIn.deinit(self.alloc);
        self.bufferOut.deinit(self.alloc);
    }

    const vtable = VTable{ .read = Allocating.read, .write = Allocating.write };

    fn read(s: *Socket, buf: []u8) ReadError!?usize {
        const p: *Allocating = @fieldParentPtr("interface", s);

        const count = @min(p.bufferIn.items.len, buf.len, p.singleOperationCountMax);

        if (count == 0) {
            return ReadError.EndOfStream;
        }

        @memcpy(buf[0..count], p.bufferIn.items[0..count]);

        const left = p.bufferIn.items.len - count;
        std.mem.copyBackwards(u8, p.bufferIn.items[0..left], p.bufferIn.items[count..]);
        p.bufferIn.items.len = left;

        return count;
    }

    fn write(s: *Socket, buf: []const u8) WriteError!?usize {
        var p: *Allocating = @fieldParentPtr("interface", s);

        const count = @min(p.singleOperationCountMax, buf.len);
        p.bufferOut.ensureUnusedCapacity(p.alloc, count) catch return WriteError.WriteFailed;

        @memcpy(p.bufferOut.unusedCapacitySlice()[0..count], buf[0..count]);
        p.bufferOut.items.len += count;

        return count;
    }

    fn addInBytes(self: *Allocating, bytes: []const u8) !void {
        try self.bufferIn.appendSlice(self.alloc, bytes);
    }
};

test "Allocating" {
    const alloc = std.testing.allocator;

    const max = 6;
    var a: Allocating = .init(alloc, max);
    defer a.deinit();

    const readBytes = "hello world";
    try a.addInBytes(readBytes);

    var socket = &a.interface;

    var buf: [10]u8 = undefined;
    {
        const countRead = socket.read(&buf) catch unreachable orelse unreachable;

        try std.testing.expectEqual(max, countRead);
        try std.testing.expectEqualStrings("hello ", buf[0..countRead]);
        try std.testing.expectEqual(5, a.bufferIn.items.len);
        try std.testing.expectEqualStrings("world", a.bufferIn.items);
    }

    {
        const countRead = socket.read(&buf) catch unreachable orelse unreachable;

        try std.testing.expectEqual(5, countRead);
        try std.testing.expectEqualStrings("world", buf[0..countRead]);
        try std.testing.expectEqual(0, a.bufferIn.items.len);
    }

    {
        const countRead = socket.read(&buf);

        try std.testing.expectError(ReadError.EndOfStream, countRead);
    }

    const writeBuf = "testing";

    {
        const countWrite = socket.write(writeBuf) catch unreachable orelse unreachable;

        try std.testing.expectEqual(6, countWrite);
        try std.testing.expectEqualStrings("testin", a.bufferOut.items);
    }

    {
        const countWrite = socket.write(writeBuf[max..]) catch unreachable orelse unreachable;

        try std.testing.expectEqual(1, countWrite);
        try std.testing.expectEqualStrings(writeBuf, a.bufferOut.items);
    }
}
