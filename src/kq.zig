const std = @import("std");
const builtin = @import("builtin");

const utils = @import("utils.zig");

fd: std.posix.fd_t,

evs: [MAX_EVENTS]KEvent = undefined,
evs_index: u16 = 0,
evs_count: u16 = 0,

changes: [MAX_CHANGE_EVENTS]KEvent = undefined,
changes_count: usize = 0,

const KQ = @This();

const KEvent = std.posix.Kevent;

pub const Kind = enum(u2) { timer, read, write };

const MAX_EVENTS = 256;
const MAX_CHANGE_EVENTS = 64;

pub fn init() !KQ {
    comptime switch (builtin.target.os.tag) {
        .macos, .freebsd, .netbsd => {},
        else => @compileError("unsupported target"),
    };

    const kqueue = try std.posix.kqueue();
    errdefer std.posix.close(kqueue);

    return .{ .fd = kqueue };
}

pub fn deinit(self: *KQ) void {
    std.posix.close(self.fd);
}

/// adds one time timer, that will fire event after `wait` in **milliseconds**
pub inline fn addTimer(
    self: *KQ,
    id: usize,
    ms: usize,
    comptime opts: struct { periodic: bool = false },
) !void {
    const flags = if (opts.periodic)
        std.c.EV.ADD | std.c.EV.ENABLE
    else
        std.c.EV.ADD | std.c.EV.ENABLE | std.c.EV.ONESHOT;

    if (self.changes_count == self.changes.len) {
        @branchHint(.unlikely);

        try self.emptyChangeList();
    }

    self.changes[self.changes_count] = KEvent{
        .ident = id,
        .filter = std.c.EVFILT.TIMER,
        .flags = flags,
        .fflags = 0, // default is milliseconds
        .data = @intCast(ms),
        .udata = 1, // prevents `udata != 0` assert
    };
    self.changes_count += 1;
}

pub fn deleteTimer(self: *KQ, id: usize) !void {
    self.removeEv(id, .timer);

    if (self.changes_count == self.changes.len) {
        @branchHint(.unlikely);

        try self.emptyChangeList();
    }

    self.changes[self.changes_count] = KEvent{
        .ident = id,
        .filter = std.c.EVFILT.TIMER,
        .flags = std.c.EV.DELETE,
        .fflags = 0,
        .data = 0,
        .udata = 0,
    };
    self.changes_count += 1;
}

/// subscribe to read or write of socket
pub inline fn subscribe(self: *KQ, socket: std.posix.fd_t, comptime kind: Kind, udata: usize) !void {
    utils.assert(udata != 0);

    const filter = switch (kind) {
        .read => std.c.EVFILT.READ,
        .write => std.c.EVFILT.WRITE,
        .timer => @compileError("use addTimer"),
    };

    if (self.changes_count == self.changes.len) {
        @branchHint(.unlikely);

        try self.emptyChangeList();
    }

    self.changes[self.changes_count] = KEvent{
        .ident = @intCast(socket),
        .filter = filter,
        .flags = std.c.EV.ADD | std.c.EV.ENABLE,
        .fflags = 0,
        .data = 0,
        .udata = udata,
    };
    self.changes_count += 1;
}

pub inline fn enable(self: *KQ, socket: std.posix.fd_t, comptime kind: Kind, udata: usize) !void {
    utils.assert(udata != 0);

    const filter = switch (kind) {
        .read => std.c.EVFILT.READ,
        .write => std.c.EVFILT.WRITE,
        .timer => @compileError("use addTimer"),
    };

    if (self.changes_count == self.changes.len) {
        @branchHint(.unlikely);

        try self.emptyChangeList();
    }

    self.changes[self.changes_count] = KEvent{
        .ident = @intCast(socket),
        .filter = filter,
        .flags = std.c.EV.ENABLE,
        .fflags = 0,
        .data = 0,
        .udata = udata,
    };
    self.changes_count += 1;
}

pub inline fn delete(self: *KQ, socket: std.posix.fd_t, comptime kind: Kind) !void {
    const filter = switch (kind) {
        .read => std.c.EVFILT.READ,
        .write => std.c.EVFILT.WRITE,
        .timer => @compileError("use deleteTimer"),
    };

    const ident: usize = @intCast(socket);
    self.removeEv(ident, kind);

    if (self.changes_count == self.changes.len) {
        @branchHint(.unlikely);

        try self.emptyChangeList();
    }

    self.changes[self.changes_count] = KEvent{
        .ident = ident,
        .filter = filter,
        .flags = std.c.EV.DELETE,
        .fflags = 0,
        .data = 0,
        .udata = 0,
    };
    self.changes_count += 1;
}

pub inline fn disable(self: *KQ, socket: std.posix.fd_t, comptime kind: Kind) !void {
    const filter = switch (kind) {
        .read => std.c.EVFILT.READ,
        .write => std.c.EVFILT.WRITE,
        .timer => @compileError("use deleteTimer"),
    };

    const ident: usize = @intCast(socket);
    self.removeEv(ident, kind);

    if (self.changes_count == self.changes.len) {
        @branchHint(.unlikely);

        try self.emptyChangeList();
    }

    self.changes[self.changes_count] = KEvent{
        .ident = ident,
        .filter = filter,
        .flags = std.c.EV.DISABLE,
        .fflags = 0,
        .data = 0,
        .udata = 0,
    };
    self.changes_count += 1;
}

const NextError = error{
    FFlags,
    ConnectionRefused,
} || std.posix.KEventError;

const CustomEvent = struct {
    ident: usize,
    udata: usize,
    kind: Kind,
    err: ?std.c.E,
};

const FALLBACK_ERROR = std.c.E.CONNRESET;
const EV_ERROR = switch (builtin.target.os.tag) {
    .netbsd => 0x4000,
    else => std.c.EV.ERROR,
};
const EV_EOF = switch (builtin.target.os.tag) {
    .netbsd, .freebsd => 0x8000,
    else => std.c.EV.EOF,
};

pub fn next(self: *KQ) NextError!?CustomEvent {
    while (self.evs_index >= self.evs_count) {
        const count = try std.posix.kevent(self.fd, self.changes[0..self.changes_count], &self.evs, null);

        self.evs_index = 0;
        self.evs_count = @intCast(count);
        self.changes_count = 0;
    }

    const ev = self.evs[self.evs_index];
    self.evs_index += 1;

    utils.assert(ev.udata != 0);

    var err: ?std.posix.E = null;

    if (ev.flags & EV_ERROR != 0) {
        const code: i32 = @intCast(ev.data);
        err = std.enums.fromInt(std.posix.E, code) orelse blk: {
            std.log.err("unknown registration error: {d}", .{code});
            break :blk FALLBACK_ERROR;
        };
    } else if (ev.flags & EV_EOF != 0) { // Check for socket errors/disconnects
        if (ev.fflags == 0) {
            err = .CONNRESET;
        } else {
            err = std.enums.fromInt(std.posix.E, ev.fflags) orelse blk: {
                std.log.err("unknown socket error: {d}", .{ev.fflags});
                break :blk FALLBACK_ERROR;
            };
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

fn emptyChangeList(self: *KQ) !void {
    utils.assert(self.changes_count == self.changes.len);

    _ = try std.posix.kevent(self.fd, &self.changes, &.{}, null);
    self.changes_count = 0;
}

inline fn removeEv(self: *KQ, ident: usize, comptime kind: Kind) void {
    const filter = switch (kind) {
        .read => std.c.EVFILT.READ,
        .write => std.c.EVFILT.WRITE,
        .timer => std.c.EVFILT.TIMER,
    };

    var i = self.evs_count;
    while (i > self.evs_index) {
        i -= 1;

        const ev = self.evs[i];
        if (ev.ident == ident and ev.filter == filter) {
            self.evs[i] = self.evs[self.evs_count - 1];
            self.evs_count -= 1;
            break;
        }
    }
}

pub fn killSocket(self: *KQ, socket: std.posix.fd_t) void {
    var i = self.evs_count;
    while (i > self.evs_index) {
        i -= 1;

        const ev = self.evs[i];
        if (ev.ident == socket) {
            self.evs[i] = self.evs[self.evs_count - 1];
            self.evs_count -= 1;
        }
    }
}
