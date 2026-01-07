const std = @import("std");
const builtin = @import("builtin");

const Torrent = @import("torrent.zig");
const PieceManager = @import("piece-manager.zig");
const Files = @import("files.zig");
const httpTracker = @import("http-tracker.zig");
const peer = @import("peer.zig");
const utils = @import("utils.zig");

pub fn downloadTorrent(alloc: std.mem.Allocator, torrentPath: []const u8) !void {
    const torrentFile = try std.fs.cwd().openFile(torrentPath, .{});
    defer torrentFile.close();

    const torrentSlice = try torrentFile.readToEndAlloc(alloc, 64 * 1024 * 1024);
    defer alloc.free(torrentSlice);

    var torrent: Torrent = try .fromSlice(alloc, torrentSlice);
    defer torrent.deinit(alloc);

    for (torrent.announceList) |announce| {
        utils.assert(std.mem.startsWith(u8, announce, "http"));
    }

    var files: Files = try .init(alloc, torrent);
    defer files.deinit();

    const peerId = httpTracker.generatePeerId();

    var peers = try httpTracker.getPeers(alloc, peerId, torrent);
    defer peers.deinit(alloc);

    comptime utils.assert(builtin.os.tag == .macos);

    const numberOfPieces = torrent.pieces.len / 20;

    var pieces: PieceManager = try .init(alloc, numberOfPieces);
    defer pieces.deinit(alloc);

    try peer.loop(alloc, peerId, &torrent, &files, &pieces, peers.items);
}

test {
    _ = @import("./http-tracker.zig");
    _ = @import("./torrent.zig");
    _ = @import("./bencode.zig");
    _ = @import("./peer.zig");
}
