const std = @import("std");
const tozi = @import("tozi");

pub fn main() !void {
    // var arena: std.heap.ArenaAllocator = .init(std.heap.smp_allocator);
    // defer arena.deinit();
    // const alloc = arena.allocator();

    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

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
