const std = @import("std");
const builtin = @import("builtin");

const tozi = @import("tozi");

const Heap = if (builtin.mode == .Debug) struct {
    gpa: std.heap.DebugAllocator(.{}),

    pub fn init() @This() {
        return .{ .gpa = .init };
    }

    pub fn alloc(self: *@This()) std.mem.Allocator {
        return self.gpa.allocator();
    }

    pub fn deinit(self: *@This()) void {
        _ = self.gpa.deinit();
    }
} else struct {
    arena: std.heap.ArenaAllocator,

    pub fn init() @This() {
        return .{ .arena = .init(std.heap.smp_allocator) };
    }

    pub fn alloc(self: *@This()) std.mem.Allocator {
        return self.arena.allocator();
    }

    pub fn deinit(self: *@This()) void {
        self.arena.deinit();
    }
};

pub fn main() !void {
    var heap: Heap = .init();
    defer heap.deinit();

    const alloc = heap.alloc();

    const args = try std.process.argsAlloc(alloc);
    defer std.process.argsFree(alloc, args);

    if (args.len < 2) {
        std.log.err("provide path to torrent as first arg", .{});
        return;
    }

    const torrentPath = args[1];
    const file = std.fs.cwd().openFile(torrentPath, .{}) catch {
        std.log.err("failed openning {s} file", .{torrentPath});
        return;
    };
    defer file.close();

    var readerBuf: [64 * 1024]u8 = undefined;
    var reader = file.reader(&readerBuf);
    const fileContents = try reader.interface.allocRemaining(alloc, .unlimited);
    defer alloc.free(fileContents);

    var torrent: tozi.Torrent = try .fromSlice(alloc, fileContents);
    defer torrent.deinit(alloc);

    const peerId = tozi.HttpTracker.generatePeerId();

    try tozi.downloadTorrent(alloc, peerId, torrent);
}
