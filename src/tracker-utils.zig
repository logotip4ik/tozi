const std = @import("std");
const builtin = @import("builtin");

pub const Operation = union(enum) {
    read,
    write,
    /// in milliseconds
    timer: u32,
};

pub const Stats = struct {
    info_hash: [20]u8,
    peer_id: [20]u8,
    port: u16 = 6889,
    num_want: u16,
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
    interval: u32,
    peers: std.array_list.Aligned(std.Io.net.IpAddress, null) = .empty,

    /// Minimum allowed interval
    interval_min: ?u32 = null,
    /// Number of seeders
    complete: ?u32 = null,
    /// Number of leechers
    incomplete: ?u32 = null,
    /// My ip, what tracker sees me as
    external_ip: ?[4]u8 = null,

    pub fn deinit(self: *AnnounceResponse, alloc: std.mem.Allocator) void {
        self.peers.deinit(alloc);
    }
};

pub fn setNonBlock(fd: std.posix.fd_t) !void {
    var fl_flags: usize = fl: {
        while (true) {
            const rc = std.posix.system.fcntl(fd, std.posix.F.GETFL, @as(usize, 0));
            switch (std.posix.errno(rc)) {
                .SUCCESS => break :fl @intCast(rc),
                .INTR => continue,
                else => |err| return std.posix.unexpectedErrno(err),
            }
        }
    };

    fl_flags |= @as(usize, 1 << @bitOffsetOf(std.posix.O, "NONBLOCK"));

    while (true) {
        switch (std.posix.errno(std.posix.system.fcntl(fd, std.posix.F.SETFL, fl_flags))) {
            .SUCCESS => break,
            .INTR => continue,
            else => |err| return std.posix.unexpectedErrno(err),
        }
    }
}

pub fn connectToAddress(addr: *const std.Io.net.IpAddress, comptime proto: enum { tcp, udp }) !std.posix.fd_t {
    const fd = blk: {
        const mode = switch (proto) {
            .tcp => std.posix.SOCK.STREAM,
            .udp => std.posix.SOCK.DGRAM,
        };
        const protocol = switch (proto) {
            .tcp => std.posix.IPPROTO.TCP,
            .udp => std.posix.IPPROTO.UDP,
        };

        const rc = std.posix.system.socket(
            std.Io.Threaded.posixAddressFamily(addr),
            mode,
            protocol,
        );
        break :blk switch (std.posix.errno(rc)) {
            .SUCCESS => {
                const fd: std.posix.fd_t = @intCast(rc);
                try setNonBlock(fd);
                break :blk fd;
            },
            else => |e| return std.posix.unexpectedErrno(e),
        };
    };
    errdefer std.Io.Threaded.closeFd(fd);

    var posix_addr: std.Io.Threaded.PosixAddress = undefined;
    const addr_len = std.Io.Threaded.addressToPosix(addr, &posix_addr);

    const rc = std.posix.system.connect(fd, &posix_addr.any, addr_len);
    switch (std.posix.errno(rc)) {
        .SUCCESS, .AGAIN, .INPROGRESS => {},
        .CONNREFUSED => return error.ConnectionRefused,
        else => |e| return std.posix.unexpectedErrno(e),
    }

    return fd;
}
