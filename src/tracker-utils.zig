const std = @import("std");

pub const Operation = union(enum) {
    read,
    write,
    /// in milliseconds
    timer: u32,
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
