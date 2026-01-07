const std = @import("std");
const tozi = @import("tozi");

pub fn main() !void {
    // var arena: std.heap.ArenaAllocator = .init(std.heap.smp_allocator);
    // defer arena.deinit();

    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();

    const alloc = gpa.allocator();

    try tozi.downloadTorrent(alloc, "./src/test_files/copper.torrent");
}
