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
    pub fn init() @This() {
        return .{};
    }

    pub fn alloc(_: *@This()) std.mem.Allocator {
        return std.heap.smp_allocator;
    }

    pub fn deinit(_: *@This()) void {}
};

pub fn main() !void {
    var heap: Heap = .init();
    defer heap.deinit();

    const alloc = heap.alloc();

    const args = try std.process.argsAlloc(alloc);
    defer std.process.argsFree(alloc, args);

    if (args.len < 3) {
        std.log.err("provide command to run `download`, `continue` or `info` + path to torrent file", .{});
        return;
    }

    const command = args[1];
    const torrentPath = args[2];
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

    if (std.mem.eql(u8, command, "info")) {
        torrent.value.dump();
        return;
    }

    const peerId = tozi.HttpTracker.generatePeerId();

    var files: tozi.Files = try .init(alloc, torrent.files.items);
    defer files.deinit(alloc);

    const isverify = std.mem.eql(u8, command, "verify");

    var pieces: tozi.PieceManager = if (std.mem.eql(u8, command, "continue") or isverify) blk: {
        var bitset = try files.collectPieces(alloc, torrent.pieces, torrent.pieceLen);
        defer bitset.deinit(alloc);

        break :blk try .fromBitset(alloc, bitset);
    } else try .init(alloc, torrent.pieces);
    defer pieces.deinit(alloc);


    if (isverify) return;

    try tozi.downloadTorrent(alloc, peerId, torrent, &files, &pieces);
}
