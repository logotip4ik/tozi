const std = @import("std");
const builtin = @import("builtin");

pub const Torrent = @import("torrent.zig");
pub const PieceManager = @import("piece-manager.zig");
pub const Files = @import("files.zig");
pub const KQ = @import("kq.zig");
pub const Peer = @import("peer.zig");
pub const HttpTracker = @import("http-tracker.zig");

const proto = @import("proto.zig");
const utils = @import("utils.zig");

comptime {
    utils.assert(builtin.os.tag == .macos);
}

pub fn downloadTorrent(alloc: std.mem.Allocator, peerId: [20]u8, torrent: Torrent) !void {
    var files: Files = try .init(alloc, torrent);
    defer files.deinit();

    var tracker: HttpTracker = .{
        .peerId = peerId,
        .infoHash = torrent.infoHash,
        .downloaded = 0,
        .uploaded = 0,
        .left = torrent.totalLen,
    };
    defer tracker.deinit(alloc);

    for (torrent.announceList) |announce| {
        if (std.mem.startsWith(u8, announce, "http")) {
            std.log.debug("adding tracker url {s}", .{announce});
            try tracker.addTracker(alloc, announce);
        }
    }

    const numberOfPieces = torrent.pieces.len / 20;

    var pieces: PieceManager = try .init(alloc, numberOfPieces);
    defer pieces.deinit(alloc);

    var kq: KQ = try .init();
    defer kq.deinit();

    var peers: std.array_list.Aligned(*Peer, null) = .empty;
    defer {
        for (peers.items) |peer| {
            if (peer.workingOn) |x| pieces.killPeer(x);
            kq.killPeer(peer.socket);
            peer.deinit(alloc);
            alloc.destroy(peer);
        }
        peers.deinit(alloc);
    }

    // initiate loop
    try kq.addTimer(0, 0);

    var deadCount: usize = 0;

    const totalPieces = torrent.pieces.len / 20;
    var completedCount: usize = 0;

    const handshake: proto.TcpHandshake = .{ .infoHash = torrent.infoHash, .peerId = peerId };
    const handshakeBytes = std.mem.asBytes(&handshake);

    while (try kq.next()) |event| {
        if (event.kind == .timer) {
            var downloaded: u64 = 0;

            for (pieces.pieces, 0..) |state, i| {
                if (state == .have) {
                    downloaded += torrent.getPieceSize(i);
                }
            }

            tracker.downloaded = downloaded;
            tracker.left = torrent.totalLen - downloaded;
            if (peers.items.len - deadCount < 10) {
                tracker.numWant += 50;
            }

            const nextKeepAlive = try tracker.keepAlive(alloc);

            std.log.info("setting timer to next: {d}", .{nextKeepAlive});
            try kq.addTimer(0, nextKeepAlive);

            while (tracker.nextNewPeer()) |addr| {
                const peer = try alloc.create(Peer);
                errdefer alloc.destroy(peer);

                peer.* = Peer.init(addr) catch |err| {
                    std.log.err("failed connecting to {f} with {t}", .{ addr, err });
                    alloc.destroy(peer);
                    continue;
                };

                try kq.subscribe(peer.socket, .write, @intFromPtr(peer));

                try peers.append(alloc, peer);
            }

            continue;
        }

        const peer: *Peer = @ptrFromInt(event.kevent.udata);

        if (event.err) |err| {
            peer.state = .dead;
            std.log.err("peer: {d} received {t}", .{ peer.socket, err });
        }

        if (event.kind == .write and peer.state != .dead) sw: switch (peer.state) {
            .readHandshake, .dead => {},
            .writeHandshake => {
                if (peer.buf.items.len == 0) {
                    try peer.buf.appendSlice(alloc, handshakeBytes);
                }

                const ready = peer.writeBuf() catch {
                    peer.state = .dead;
                    break :sw;
                };

                if (!ready) continue;

                peer.state = .readHandshake;

                try kq.unsubscribe(peer.socket, .write);
                try kq.subscribe(peer.socket, .read, @intFromPtr(peer));
            },
            .messageStart, .message => {
                {
                    var writer: std.Io.Writer.Allocating = .fromArrayList(alloc, &peer.buf);
                    defer peer.buf = writer.toArrayList();

                    while (peer.mq.remove()) |m| {
                        try m.writeMessage(&writer.writer);
                    }
                }

                const ready = peer.writeBuf() catch {
                    peer.state = .dead;
                    break :sw;
                };

                if (!ready) continue;

                try kq.unsubscribe(peer.socket, .write);
            },
        };

        if (event.kind == .read and peer.state != .dead) sw: switch (peer.state) {
            .writeHandshake => {},
            .dead => {
                peer.state = .dead;
            },
            .readHandshake => {
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
                        .len = try peer.readInt(u32),
                    } },
                    .piece => .{ .piece = .{
                        .index = try peer.readInt(u32),
                        .begin = try peer.readInt(u32),
                        .len = len - 9,
                    } },
                    .cancel => .{ .cancel = .{
                        .index = try peer.readInt(u32),
                        .begin = try peer.readInt(u32),
                        .len = try peer.readInt(u32),
                    } },
                    .port => .{ .port = try peer.readInt(u16) },
                };

                peer.state = .{ .message = message };
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

                    std.log.info("peer: {d} unchoked, requesting", .{peer.socket});

                    while (peer.inFlight.count < peer.inFlight.size) {
                        const piece = peer.getNextWorkingPiece(&pieces) orelse break;
                        const len = torrent.getPieceSize(piece);

                        if (peer.addRequest(piece, len)) {
                            break;
                        }
                    }

                    peer.state = .messageStart;
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
                    defer peer.buf.clearRetainingCapacity();

                    try peer.setBitfield(alloc, bytes);

                    // TODO: actually check if peer has interesting pieces

                    try peer.mq.add(.interested);

                    peer.state = .messageStart;
                    try kq.subscribe(peer.socket, .write, event.kevent.udata);
                },
                .piece => |piece| {
                    const chunkBytes = try peer.readTotalBuf(alloc, piece.len) orelse continue;
                    defer peer.buf.clearRetainingCapacity();

                    peer.state = .messageStart;

                    if (piece.index > totalPieces) {
                        @branchHint(.unlikely);
                        std.log.err("peer {d} sen't unknown piece massage: {d}", .{
                            peer.socket,
                            piece.index,
                        });
                        continue :sw .dead;
                    }

                    peer.inFlight.receive(.{ .pieceIndex = piece.index, .begin = piece.begin }) catch {};
                    if (!peer.choked) if (peer.getNextWorkingPiece(&pieces)) |workingPiece| {
                        @branchHint(.likely);

                        _ = peer.addRequest(workingPiece, torrent.getPieceSize(workingPiece));

                        try kq.subscribe(peer.socket, .write, event.kevent.udata);
                    };

                    const pieceLen = torrent.getPieceSize(piece.index);
                    const completed = try pieces.writePiece(alloc, piece, pieceLen, chunkBytes) orelse continue;
                    defer completed.deinit(alloc);

                    const expectedHash = torrent.pieces[piece.index * 20 ..];
                    pieces.validatePiece(piece.index, completed.bytes, expectedHash[0..20]) catch {
                        @branchHint(.unlikely);
                        std.log.warn("piece: {d} corrupt from peer {d}", .{ piece.index, peer.socket });
                        continue;
                    };

                    try files.writePiece(piece.index, completed.bytes);
                    peer.workingOn.?.unset(piece.index);

                    for (peers.items) |otherPeer| {
                        if (peer.state != .dead and peer.socket != otherPeer.socket) {
                            otherPeer.mq.add(.{ .have = piece.index }) catch {};
                        }
                    }

                    completedCount += 1;
                    const percent = (completedCount * 100) / totalPieces;
                    std.log.info("progress: ({d}%) {d}/{d} - piece {d} ok (peer: {d}, alive peers: {d})", .{
                        percent,
                        completedCount,
                        totalPieces,
                        piece.index,
                        peer.socket,
                        peers.items.len - deadCount,
                    });

                    if (pieces.isDownloadComplete()) {
                        @branchHint(.cold);
                        std.log.info("download finished", .{});
                        return;
                    }
                },
                .request, // Peer requested block from you (Ignore if leaching)
                .interested, // Peer is interested in you (Ignore if leaching)
                .not_interested, // Peer not interested (Ignore)
                .cancel,
                .port,
                => {
                    peer.state = .messageStart;
                },
            },
        };

        if (peer.state == .dead) {
            deadCount += 1;

            kq.killPeer(peer.socket);
            if (peer.workingOn) |x| pieces.killPeer(x);

            if (deadCount == peers.items.len) {
                return error.AllStreamsDead;
            }
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
