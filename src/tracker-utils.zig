const std = @import("std");
const builtin = @import("builtin");

pub const Operation = union(enum) {
    read,
    write,
    /// in milliseconds
    timer: u32,
};

pub const Stats = struct {
    infoHash: [20]u8,
    peerId: [20]u8,
    port: u16 = 6889,
    numWant: u16,
    downloaded: usize,
    uploaded: usize,
    left: usize,

    event: enum(u32) {
        /// Periodic Update (Keep-alive) (Missing / Omitted)
        none = 0,
        /// Download Reaches 100%
        completed = 1,
        /// First Request
        started = 2,
        /// User Pauses / Quits
        stopped = 3,
    },
};

pub const AnnounceResponse = struct {
    /// Seconds client should wait before next announce
    interval: u32 = undefined,
    /// Binary blob: 6 bytes per peer (4 byte IP + 2 byte Port)
    peers: std.array_list.Aligned([6]u8, null) = .empty,

    /// Minimum allowed interval
    minInterval: ?u32 = null,
    /// Number of seeders
    complete: ?u32 = null,
    /// Number of leechers
    incomplete: ?u32 = null,

    pub fn deinit(self: *AnnounceResponse, alloc: std.mem.Allocator) void {
        self.peers.deinit(alloc);
    }
};

pub fn connectToAddress(addr: std.net.Address, proto: enum { tcp, udp }) !std.posix.socket_t {
    const CLOEXEC = if (builtin.os.tag == .windows) 0 else std.posix.SOCK.CLOEXEC;

    const sock_type: u32 = switch (proto) {
        .tcp => std.posix.SOCK.STREAM,
        .udp => std.posix.SOCK.DGRAM,
    };

    const protocol: u32 = switch (proto) {
        .tcp => std.posix.IPPROTO.TCP,
        .udp => std.posix.IPPROTO.UDP,
    };

    const sock_flags = sock_type | std.posix.SOCK.NONBLOCK | CLOEXEC;

    const sock = try std.posix.socket(addr.any.family, sock_flags, protocol);
    errdefer std.posix.close(sock);

    std.posix.connect(sock, &addr.any, addr.getOsSockLen()) catch |err| switch (err) {
        error.WouldBlock => {},
        else => |e| return e,
    };

    return sock;
}
