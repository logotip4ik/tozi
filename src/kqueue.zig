const std = @import("std");
const builtin = @import("builtin");

fd: std.posix.fd_t,

evBuf: [16]KEvent = undefined,

const Self = @This();

const KEvent = std.posix.Kevent;

const Op = enum { write, read };

const logger = std.log.scoped(.kqueue);

pub fn init() !Self {
    comptime std.debug.assert(builtin.os.tag == .macos);

    const kqueue = try std.posix.kqueue();

    return .{ .fd = kqueue };
}

pub fn deinit(self: Self) void {
    std.posix.close(self.fd);
}

pub fn subscribe(self: Self, socketId: std.posix.fd_t, op: Op, udata: usize) !void {
    const filter: isize = switch (op) {
        .read => std.c.EVFILT.READ,
        .write => std.c.EVFILT.WRITE,
    };

    _ = try std.posix.kevent(self.fd, &[_]KEvent{
        KEvent{
            .ident = @intCast(socketId),
            .filter = @intCast(filter),
            .flags = std.c.EV.ADD | std.c.EV.ENABLE,
            .fflags = 0,
            .data = 0,
            .udata = udata,
        },
    }, &.{}, null);
}

pub fn unsubscribe(self: Self, socketId: std.posix.fd_t, op: Op, udata: usize) !void {
    const filter: isize = switch (op) {
        .read => std.c.EVFILT.READ,
        .write => std.c.EVFILT.WRITE,
    };

    _ = try std.posix.kevent(self.fd, &[_]KEvent{
        KEvent{
            .ident = @intCast(socketId),
            .filter = @intCast(filter),
            .flags = std.c.EV.DELETE,
            .fflags = 0,
            .data = 0,
            .udata = udata,
        },
    }, &.{}, null);
}

const NextError = error {
    FFlags,
    ConnectionRefused,
} || std.posix.KEventError;

pub fn next(self: *Self) NextError!?KEvent {
    const readyCount = try std.posix.kevent(self.fd, &.{}, &self.evBuf, null);

    for (self.evBuf[0..readyCount]) |ev| {
        logger.debug("received ev: {any}", .{ev});

        return ev;
    }

    return null;
}
