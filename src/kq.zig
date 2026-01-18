const std = @import("std");
const builtin = @import("builtin");

const utils = @import("utils.zig");

alloc: std.mem.Allocator,

fd: std.posix.fd_t,

evs: utils.Queue(KEvent, MAX_EVENTS) = .{},

changeList: std.array_list.Aligned(KEvent, null) = .empty,

const Self = @This();

const KEvent = std.posix.Kevent;

pub const Kind = enum(u2) { timer, read, write };

const MAX_EVENTS = 512;

pub fn init(alloc: std.mem.Allocator) !Self {
    comptime utils.assert(builtin.os.tag == .macos);

    const kqueue = try std.posix.kqueue();
    errdefer std.posix.close(kqueue);

    return .{ .alloc = alloc, .fd = kqueue };
}

pub fn deinit(self: *Self) void {
    std.posix.close(self.fd);
    self.changeList.deinit(self.alloc);
}

/// adds one time timer, that will fire event after `wait` in **milliseconds**
pub fn addTimer(self: *Self, id: usize, ms: usize, opts: struct { periodic: bool = false }) !void {
    const flags: usize = if (opts.periodic)
        std.c.EV.ADD | std.c.EV.ENABLE
    else
        std.c.EV.ADD | std.c.EV.ENABLE | std.c.EV.ONESHOT;

    try self.changeList.append(self.alloc, KEvent{
        .ident = @intCast(id),
        .filter = std.c.EVFILT.TIMER,
        .flags = @intCast(flags),
        .fflags = 0, // default is milliseconds
        .data = @intCast(ms),
        .udata = 1, // prevents `udata != 0` assert
    });
}

/// subscribe to read or write of socket (`ident`)
pub fn subscribe(self: *Self, ident: std.posix.fd_t, kind: Kind, udata: usize) !void {
    utils.assert(udata != 0);

    const filter: isize = switch (kind) {
        .read => std.c.EVFILT.READ,
        .write => std.c.EVFILT.WRITE,
        .timer => return error.UseAddTimer,
    };

    try self.changeList.append(self.alloc, KEvent{
        .ident = @intCast(ident),
        .filter = @intCast(filter),
        .flags = std.c.EV.ADD | std.c.EV.ENABLE,
        .fflags = 0,
        .data = 0,
        .udata = udata,
    });
}

pub fn delete(self: *Self, ident: std.posix.fd_t, kind: Kind) !void {
    const filter: isize = switch (kind) {
        .read => std.c.EVFILT.READ,
        .write => std.c.EVFILT.WRITE,
        .timer => std.c.EVFILT.TIMER,
    };

    var i = self.evs.count;
    while (i > 0) {
        i -= 1;
        const ev = self.evs.get(i);
        if (ev.ident == ident and ev.filter == filter) {
            self.evs.removeIndex(i);
        }
    }

    self.changeList.append(self.alloc, KEvent{
        .ident = @intCast(ident),
        .filter = @intCast(filter),
        .flags = std.c.EV.DELETE,
        .fflags = 0,
        .data = 0,
        .udata = 0,
    });
}

pub fn enable(self: *Self, ident: std.posix.fd_t, kind: Kind, udata: usize) !void {
    utils.assert(udata != 0);

    const filter: isize = switch (kind) {
        .read => std.c.EVFILT.READ,
        .write => std.c.EVFILT.WRITE,
        .timer => return error.UseAddTimer,
    };

    try self.changeList.append(self.alloc, KEvent{
        .ident = @intCast(ident),
        .filter = @intCast(filter),
        .flags = std.c.EV.ENABLE,
        .fflags = 0,
        .data = 0,
        .udata = udata,
    });
}

pub fn disable(self: *Self, ident: std.posix.fd_t, kind: Kind) !void {
    const filter: isize = switch (kind) {
        .read => std.c.EVFILT.READ,
        .write => std.c.EVFILT.WRITE,
        .timer => return error.UseAddTimer,
    };

    var i = self.evs.count;
    while (i > 0) {
        i -= 1;
        const ev = self.evs.get(i);
        if (ev.ident == ident and ev.filter == filter) {
            self.evs.removeIndex(i);
        }
    }

    try self.changeList.append(self.alloc, KEvent{
        .ident = @intCast(ident),
        .filter = @intCast(filter),
        .flags = std.c.EV.DISABLE,
        .fflags = 0,
        .data = 0,
        .udata = 0,
    });
}

const NextError = error{
    FFlags,
    ConnectionRefused,
} || std.posix.KEventError;

const CustomEvent = struct {
    ident : usize,
    udata: usize,
    kind: Kind,
    err: ?std.c.E,
};

const FALLBACK_ERROR = std.c.E.CONNREFUSED;
var intermidiateKqBuf: [MAX_EVENTS]KEvent = undefined;

pub fn next(self: *Self) NextError!?CustomEvent {
    if (self.evs.count == 0) {
        defer self.changeList.clearRetainingCapacity();

        const readyCount = try std.posix.kevent(self.fd, self.changeList.items, &intermidiateKqBuf, null);

        for (intermidiateKqBuf[0..readyCount]) |e| {
            self.evs.add(e) catch unreachable;
        }
    }

    const ev = self.evs.remove() orelse unreachable;

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

    const kind: Kind = switch (ev.filter) {
        std.c.EVFILT.READ => .read,
        std.c.EVFILT.WRITE => .write,
        std.c.EVFILT.TIMER => .timer,
        else => unreachable,
    };

    return .{ .ident = ev.ident, .udata = ev.udata, .kind = kind, .err = err };
}

pub fn killPeer(self: *Self, socket: std.posix.fd_t) void {
    std.posix.close(socket);

    var i = self.evs.count;
    while (i > 0) {
        i -= 1;
        const ev = self.evs.get(i);
        if (ev.ident == socket) {
            self.evs.removeIndex(i);
        }
    }
}
