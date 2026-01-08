const std = @import("std");
const builtin = @import("builtin");

pub const Torrent = @import("torrent.zig");
pub const PieceManager = @import("piece-manager.zig");
pub const Files = @import("files.zig");
pub const KQ = @import("kq.zig");
pub const Peer = @import("peer.zig");
const httpTracker = @import("http-tracker.zig");
const proto = @import("proto.zig");
const utils = @import("utils.zig");

comptime {
    utils.assert(builtin.os.tag == .macos);
}

pub const generatePeerId = httpTracker.generatePeerId;

pub fn downloadTorrent(alloc: std.mem.Allocator, peerId: [20]u8, torrent: Torrent) !void {
    for (torrent.announceList) |announce| {
        utils.assert(std.mem.startsWith(u8, announce, "http"));
    }

    var files: Files = try .init(alloc, torrent);
    defer files.deinit();

    var peers = httpTracker.getPeers(alloc, peerId, torrent) catch |err| {
        std.log.err("failed sending announcement with {s}", .{@errorName(err)});
        return;
    };
    defer peers.deinit(alloc);

    const numberOfPieces = torrent.pieces.len / 20;

    var pieces: PieceManager = try .init(alloc, numberOfPieces);
    defer pieces.deinit(alloc);

    try loop(alloc, peerId, torrent, &files, &pieces, peers.items);
}

pub fn loop(
    alloc: std.mem.Allocator,
    peerId: [20]u8,
    torrent: Torrent,
    files: *Files,
    pieceManager: *PieceManager,
    addrs: []const std.net.Address,
) !void {
    var kq: KQ = try .init(alloc);
    defer kq.deinit();

    var peers = try alloc.alloc(Peer, addrs.len);
    defer {
        for (peers) |*peer| {
            kq.unsubscribe(peer.socket, .read) catch |err| {
                std.log.err("received err while unsubscribing from read for socket {d} with {s}\n", .{
                    peer.socket,
                    @errorName(err),
                });
            };
            kq.unsubscribe(peer.socket, .write) catch |err| switch (err) {
                error.EventNotFound => {}, // already unsubscribed
                else => {
                    std.log.err("received err while unsubscribing from write for socket {d} with {s}\n", .{
                        peer.socket,
                        @errorName(err),
                    });
                },
            };

            peer.deinit(alloc);
        }
        alloc.free(peers);
    }

    for (addrs, 0..) |addr, i| {
        const peer = &peers[i];

        peer.* = try .init(addr);

        try kq.subscribe(peer.socket, .read, @intFromPtr(peer));
        try kq.subscribe(peer.socket, .write, @intFromPtr(peer));
    }

    var deadCount: usize = 0;

    const totalPieces = torrent.pieces.len / 20;
    var completedCount: usize = 0;

    const handshake: proto.TcpHandshake = .{ .infoHash = torrent.infoHash, .peerId = peerId };
    const handshakeBytes = std.mem.asBytes(&handshake);

    while (try kq.next()) |event| {
        const peer: *Peer = @ptrFromInt(event.kevent.udata);

        if (event.err) |_| {
            peer.state = .dead;
            peer.direction = .read;
        }

        switch (event.op) {
            .write => if (peer.direction == .write) switch (peer.state) {
                .handshake => {
                    _ = try peer.writeTotalBuf(alloc, handshakeBytes) orelse continue;

                    peer.state = .handshake;
                    peer.direction = .read;
                    peer.buf.clearRetainingCapacity();

                    try kq.unsubscribe(peer.socket, .write);
                },
                .bufFlush => {
                    if (peer.buf.items.len == 0) continue;
                    try peer.writeBuf() orelse continue;

                    peer.state = .messageStart;
                    peer.direction = .read;

                    try kq.unsubscribe(peer.socket, .write);
                },
                else => {
                    std.log.err("receivd {any} for write", .{peer.state});
                    return error.Unknown;
                },
            },
            .read => if (peer.direction == .read) sw: switch (peer.state) {
                .dead => if (peer.state != .dead) {
                    if (event.err) |err| {
                        std.log.err("peer: {d} dead with error {s}", .{ peer.socket, @tagName(err) });
                    } else {
                        std.log.err("peer: {d} dead", .{peer.socket});
                    }

                    if (peer.workingOn) |workingOn| {
                        var iter = workingOn.iterator(.{ .direction = .forward, .kind = .set });
                        while (iter.next()) |index| {
                            pieceManager.reset(@intCast(index));
                        }
                    }

                    kq.unsubscribe(peer.socket, .read) catch |e| {
                        std.log.err("received err while unsubscribing from read for socket {d} with {s}\n", .{
                            peer.socket,
                            @errorName(e),
                        });
                    };
                    kq.unsubscribe(peer.socket, .write) catch |e| switch (e) {
                        error.EventNotFound => {}, // already unsubscribed
                        else => {
                            std.log.err("received err while unsubscribing from write for socket {d} with {s}\n", .{
                                peer.socket,
                                @errorName(e),
                            });
                        },
                    };

                    peer.deinit(alloc);
                    deadCount += 1;

                    if (deadCount == peers.len) {
                        return error.AllStreamsDead;
                    }
                },
                .handshake => {
                    const bytes = try peer.readTotalBuf(alloc, proto.TCP_HANDSHAKE_LEN) orelse continue;

                    defer peer.buf.clearRetainingCapacity();
                    const received: *proto.TcpHandshake = @ptrCast(bytes);

                    handshake.validate(received.*) catch |err| {
                        std.log.err("peer: {d} bad handshake {s}", .{ peer.socket, @errorName(err) });
                        continue :sw .dead;
                    };

                    peer.state = .messageStart;
                    std.log.info("peer: {d} handshake ok", .{peer.socket});
                },
                .messageStart => {
                    const len = try peer.readInt(u32);
                    if (len == 0) {
                        // keep alive, send requests ?
                        continue;
                    }

                    if (len > 16 * 1024 * 1024) {
                        std.log.err("peer: {d} dropped (msg too big: {d})", .{ peer.socket, len });
                        continue :sw .dead;
                    }

                    const idInt = try peer.readInt(u8);
                    const id = std.enums.fromInt(proto.MessageId, idInt) orelse {
                        std.log.warn("peer: {d} unknown msg id {d}", .{ peer.socket, idInt });
                        continue;
                    };

                    const message: proto.Message = switch (id) {
                        .choke => .choke,
                        .unchoke => .unchoke,
                        .interested => .interested,
                        .not_interested => .not_interested,
                        .have => .{ .have = try peer.readInt(u32) },
                        .bitfield => .{ .bitfield = len - 1 },
                        .request => .{ .request = .{
                            .index = try peer.readInt(u32),
                            .begin = try peer.readInt(u32),
                            .len = len - 9,
                        } },
                        .piece => .{ .piece = .{
                            .index = try peer.readInt(u32),
                            .begin = try peer.readInt(u32),
                            .len = len - 9,
                        } },
                        .cancel => .{ .cancel = .{
                            .index = try peer.readInt(u32),
                            .begin = try peer.readInt(u32),
                            .len = len - 9,
                        } },
                        .port => .{ .port = try peer.readInt(u16) },
                    };

                    peer.state = .{ .message = message };
                    peer.buf.clearRetainingCapacity();
                },
                .message => |message| switch (message) {
                    .choke => {
                        peer.choked = true;
                        peer.state = .messageStart;
                    },
                    .unchoke => {
                        peer.choked = false;

                        const bitfield = peer.bitfield orelse {
                            std.log.warn("received unchoke message but no bitfield was set", .{});
                            peer.state = .messageStart;
                            continue;
                        };

                        if (peer.workingOn == null) {
                            peer.workingOn = try .initEmpty(alloc, bitfield.bit_length);
                        }

                        const requestsPerPeer = try std.math.divCeil(usize, totalPieces, peers.len);
                        const numberOfPiecesToRequest = @min(requestsPerPeer, 5);

                        std.log.info("peer: {d} unchoked, requesting", .{peer.socket});

                        peer.buf.clearRetainingCapacity();
                        var writer: std.Io.Writer.Allocating = .fromArrayList(alloc, &peer.buf);
                        defer peer.buf = writer.toArrayList();

                        for (0..numberOfPiecesToRequest) |_| {
                            const index = pieceManager.getWorkingPiece(bitfield) orelse break;
                            const pieceLen = torrent.getPieceSize(index);
                            try proto.writeRequestsBatch(&writer.writer, index, pieceLen);
                            peer.workingOn.?.set(index);
                        }

                        peer.state = .bufFlush;
                        peer.direction = .write;

                        try kq.subscribe(peer.socket, .write, event.kevent.udata);
                    },
                    .have => |piece| {
                        defer peer.state = .messageStart;

                        var bitfield = peer.bitfield orelse {
                            std.log.err("unexpected empty bitfield with have message", .{});
                            continue;
                        };

                        bitfield.set(piece);
                        // TODO: check if we don't have this piece and we aren't downloading it,
                        // then request it
                    },
                    .bitfield => |len| {
                        const bytes = try peer.readTotalBuf(alloc, len) orelse continue;

                        try peer.setBitfield(alloc, bytes);

                        // TODO: actually check if peer has interesting pieces

                        peer.buf.clearRetainingCapacity();

                        var writer: std.Io.Writer.Allocating = .fromArrayList(alloc, &peer.buf);
                        defer peer.buf = writer.toArrayList();

                        const interested: proto.Message = .interested;
                        try interested.writeMessage(&writer.writer);

                        peer.state = .bufFlush;
                        peer.direction = .write;

                        try kq.subscribe(peer.socket, .write, event.kevent.udata);
                    },
                    .piece => |piece| {
                        const chunkBytes = try peer.readTotalBuf(alloc, piece.len) orelse continue;

                        if (piece.index > totalPieces) {
                            @branchHint(.unlikely);
                            std.log.err("peer {d} sen't unknown piece massage: {d}", .{
                                peer.socket,
                                piece.index,
                            });
                            continue :sw .dead;
                        }

                        const pieceLen = torrent.getPieceSize(piece.index);
                        const completed = try pieceManager.writePiece(alloc, piece, pieceLen, chunkBytes) orelse {
                            peer.state = .messageStart;
                            continue;
                        };
                        defer completed.deinit(alloc);

                        const expectedHash = torrent.pieces[piece.index * 20 ..];
                        pieceManager.validatePiece(piece.index, completed.bytes, expectedHash[0..20]) catch {
                            @branchHint(.unlikely);
                            std.log.warn("piece: {d} corrupt from peer {d}", .{ piece.index, peer.socket });
                            peer.state = .messageStart;
                            continue;
                        };

                        try files.writePiece(piece.index, completed.bytes);
                        completedCount += 1;

                        const percent = (completedCount * 100) / totalPieces;
                        std.log.info("progress: {d}/{d} ({d}%) - piece {d} ok", .{ completedCount, totalPieces, percent, piece.index });

                        const bitfield = peer.bitfield orelse {
                            @branchHint(.cold);
                            std.log.err("unexpected empty bitfield with piece message", .{});
                            peer.state = .messageStart;
                            pieceManager.reset(piece.index);
                            continue;
                        };

                        if (peer.workingOn) |*workingOn| {
                            @branchHint(.likely);
                            workingOn.unset(piece.index);
                        } else {
                            @branchHint(.cold);
                            std.log.err("unexpected empty workingOn with piece message", .{});
                            peer.state = .messageStart;
                            pieceManager.reset(piece.index);
                            continue;
                        }

                        if (peer.choked) {
                            peer.state = .messageStart;
                            continue;
                        }

                        if (pieceManager.getWorkingPiece(bitfield)) |nextWorkingPiece| {
                            @branchHint(.likely);

                            peer.buf.clearRetainingCapacity();

                            const nextPieceLen = torrent.getPieceSize(nextWorkingPiece);

                            var writer: std.Io.Writer.Allocating = .fromArrayList(alloc, &peer.buf);
                            defer peer.buf = writer.toArrayList();

                            try proto.writeRequestsBatch(&writer.writer, nextWorkingPiece, nextPieceLen);

                            peer.state = .bufFlush;
                            peer.direction = .write;
                            peer.workingOn.?.set(nextWorkingPiece);

                            try kq.subscribe(peer.socket, .write, event.kevent.udata);
                        } else if (pieceManager.isDownloadComplete()) {
                            std.log.info("download finished", .{});
                            return;
                        } else {
                            peer.state = .messageStart;
                        }
                    },
                    .request, // Peer requested block from you (Ignore if leaching)
                    .interested, // Peer is interested in you (Ignore if leaching)
                    .not_interested, // Peer not interested (Ignore)
                    .cancel,
                    .port,
                    => {
                        defer peer.state = .messageStart;
                    },
                },
                else => unreachable,
            },
        }
    }
}

test {
    _ = @import("torrent.zig");
    _ = @import("piece-manager.zig");
    _ = @import("files.zig");
    _ = @import("http-tracker.zig");
    _ = @import("peer.zig");
    _ = @import("utils.zig");
}
