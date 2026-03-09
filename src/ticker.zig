const std = @import("std");

const Peer = @import("peer.zig");
const PieceManager = @import("piece-manager.zig");

/// in seconds
tick: u8,

total_pieces: usize,

const Ticker = @This();

pub fn onTick(
    self: *const Ticker,
    peers: []*Peer,
    pieces: *const PieceManager,
) void {
    var bytes_per_tick: usize = 0;
    var peers_alive_count: usize = 0;

    // TODO: This currently is not used, but leaving here for future references. This should be
    // removed from Ticker?
    //
    // const maxPeersToUnchoke = 5;
    // var unchokedCount: usize = 0;

    for (peers) |peer| {
        defer {
            peer.bytes_received = 0;
            peer.bytes_sent = 0;
        }

        // const shouldUnchoke = peer.isInterested and unchokedCount < maxPeersToUnchoke;
        // if (shouldUnchoke) {
        //     if (!peer.isUnchoked) {
        //         peer.isUnchoked = true;
        //         const ready = try peer.addMessage(.unchoke, &.{});
        //         if (!ready) try kq.enable(peer.socket.fd, .write, TaggedPointer.pack(.{ .peer = peer }));
        //     }
        //     unchokedCount += 1;
        // } else if (peer.isUnchoked) {
        //     peer.isUnchoked = false;
        //     const ready = try peer.addMessage(.choke, &.{});
        //     if (!ready) try kq.enable(peer.socket.fd, .write, TaggedPointer.pack(.{ .peer = peer }));
        // }

        bytes_per_tick += peer.bytes_received;
        peers_alive_count += @intFromBool(peer.bytes_received > 0);
    }

    const percent = (pieces.completed_count * 100) / self.total_pieces;
    const bytes_per_second = bytes_per_tick / 3;

    std.log.info("progress: {d:2}% {d}/{d} (peers: {d}, speed: {Bi:6.2})", .{
        percent,
        pieces.completed_count,
        self.total_pieces,
        peers_alive_count,
        bytes_per_second,
    });
}
