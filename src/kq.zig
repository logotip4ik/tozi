const std = @import("std");
const builtin = @import("builtin");

const utils = @import("utils.zig");

fd: std.posix.fd_t,

evs: std.PriorityQueue(KEvent, CompareContext, compareKEvents),

const Self = @This();

const KEvent = std.posix.Kevent;

pub const Op = enum { write, read };

const logger = std.log.scoped(.kqueue);
const MAX_EVENTS = 8;

pub fn init(alloc: std.mem.Allocator) !Self {
    comptime utils.assert(builtin.os.tag == .macos);

    const kqueue = try std.posix.kqueue();
    errdefer std.posix.close(kqueue);

    var evs: std.PriorityQueue(KEvent, CompareContext, compareKEvents) = .init(alloc, .{});
    errdefer evs.deinit();

    try evs.ensureUnusedCapacity(MAX_EVENTS);

    return .{ .fd = kqueue, .evs = evs };
}

pub fn deinit(self: *Self) void {
    std.posix.close(self.fd);
    self.evs.deinit();
}

const CompareContext = struct {};
fn compareKEvents(_: CompareContext, _: KEvent, _: KEvent) std.math.Order {
    return .lt;
}

pub fn subscribe(self: Self, socketId: std.posix.fd_t, op: Op, udata: usize) !void {
    utils.assert(udata != 0);

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

pub fn unsubscribe(self: *Self, socketId: std.posix.fd_t, op: Op) !void {
    const filter: isize = switch (op) {
        .read => std.c.EVFILT.READ,
        .write => std.c.EVFILT.WRITE,
    };

    var iter = self.evs.iterator();
    while (iter.next()) |item| {
        if (item.filter == filter) {
            if (iter.count == self.evs.items.len) {
                _ = self.evs.remove();
            } else {
                _ = self.evs.removeIndex(iter.count);
            }
        }
    }

    _ = try std.posix.kevent(self.fd, &[_]KEvent{
        KEvent{
            .ident = @intCast(socketId),
            .filter = @intCast(filter),
            .flags = std.c.EV.DELETE,
            .fflags = 0,
            .data = 0,
            .udata = 0,
        },
    }, &.{}, null);
}

const NextError = error{
    FFlags,
    ConnectionRefused,
} || std.posix.KEventError;

const CustomEvent = struct {
    kevent: KEvent,
    op: Op,
    err: ?std.c.E,
};

const FALLBACK_ERROR = std.c.E.CONNREFUSED;

pub fn next(self: *Self) NextError!?CustomEvent {
    const ev = self.evs.removeOrNull() orelse blk: {
        var buf: [MAX_EVENTS]KEvent = undefined;

        var readyCount: usize = 0;
        while (readyCount == 0) {
            readyCount = try std.posix.kevent(self.fd, &.{}, &buf, null);
            if (readyCount == 0) {
                std.Thread.sleep(std.time.ns_per_us * 4);
            }
        }

        if (readyCount > 1) {
            self.evs.addSlice(buf[1..readyCount]) catch unreachable;
        }

        break :blk buf[0];
    };

    utils.assert(ev.udata != 0);

    var err: ?std.posix.E = null;

    if (ev.flags & std.c.EV.ERROR != 0) {
        const code: i32 = @intCast(ev.data);
        err = std.enums.fromInt(std.posix.E, code);
        if (err == null) std.log.err("unknown registration error: {d}", .{code});
    } else if (ev.flags & std.c.EV.EOF != 0) { // Check for socket errors/disconnects
        if (ev.fflags != 0) {
            const code: i32 = @intCast(ev.fflags);
            err = std.enums.fromInt(std.posix.E, code);
            if (err == null) std.log.err("unknown socket error: {d}", .{code});
        } else {
            err = .CONNRESET;
        }
    }

    const op: Op = switch (ev.filter) {
        std.c.EVFILT.READ => .read,
        std.c.EVFILT.WRITE => .write,
        else => unreachable,
    };

    return .{ .kevent = ev, .op = op, .err = err };
}
