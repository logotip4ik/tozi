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
            kq.killPeer(peer.socket);
            pieces.killPeer(peer.workingOn);
            peer.deinit(alloc);
            alloc.destroy(peer);
        }
        peers.deinit(alloc);
    }

    const Timer = enum { tracker, tick };
    try kq.addTimer(@intFromEnum(Timer.tracker), 0, .{ .periodic = false });
    try kq.addTimer(@intFromEnum(Timer.tick), 3 * std.time.ms_per_s, .{ .periodic = true });

    var deadCount: usize = 0;

    const downloadStart = std.time.milliTimestamp();
    const totalPieces = torrent.pieces.len / 20;
    var completedCount: usize = 0;
    var bytesPerTick: usize = 0;

    const handshake: proto.TcpHandshake = .{ .infoHash = torrent.infoHash, .peerId = peerId };
    const handshakeBytes = std.mem.asBytes(&handshake);

    main: while (try kq.next()) |event| {
        if (event.kind == .timer) {
            const timer = std.enums.fromInt(Timer, event.kevent.ident) orelse continue;

            switch (timer) {
                .tracker => {
                    updateTracker(&tracker, pieces, torrent);

                    if (tracker.oldAddrs.items.len - deadCount < 10 and tracker.newAddrs.items.len < 10) {
                        tracker.numWant += 50;
                    }

                    const nextKeepAlive = try tracker.keepAlive(alloc);

                    std.log.info("setting timer to next: {d}", .{nextKeepAlive});
                    try kq.addTimer(0, nextKeepAlive, .{ .periodic = false });

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

                    if (deadCount == tracker.oldAddrs.items.len) {
                        return error.AllStreamsDead;
                    }
                },
                .tick => {
                    defer bytesPerTick = 0;

                    const percent = (completedCount * 100) / totalPieces;
                    const bytesPerSecond = bytesPerTick / 3;

                    std.log.info("progress: {d:3}% {d}/{d} (alive peers: {d}, speed: {Bi:.2})", .{
                        percent,
                        completedCount,
                        totalPieces,
                        tracker.oldAddrs.items.len - deadCount,
                        bytesPerSecond,
                    });
                },
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
                if (peer.writeBuf.items.len == 0) {
                    try peer.writeBuf.appendSlice(alloc, handshakeBytes);
                }

                const ready = peer.send() catch {
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
                    var writer: std.Io.Writer.Allocating = .fromArrayList(alloc, &peer.writeBuf);
                    defer peer.writeBuf = writer.toArrayList();

                    while (peer.mq.remove()) |m| {
                        try m.writeMessage(&writer.writer);
                    }
                }

                const ready = peer.send() catch {
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
                defer peer.readBuf.clearRetainingCapacity();

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
                    if (!peer.choked) {
                        peer.fillRqPool(torrent, &pieces);

                        try kq.subscribe(peer.socket, .write, event.kevent.udata);
                    }

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

                    std.log.info("peer: {d} unchoked", .{peer.socket});

                    peer.fillRqPool(torrent, &pieces);
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
                    defer peer.readBuf.clearRetainingCapacity();

                    try peer.setBitfield(alloc, bytes);

                    // TODO: actually check if peer has interesting pieces

                    try peer.mq.add(.interested);

                    peer.state = .messageStart;
                    try kq.subscribe(peer.socket, .write, event.kevent.udata);
                },
                .piece => |piece| {
                    const chunkBytes = try peer.readTotalBuf(alloc, piece.len) orelse continue;
                    defer peer.readBuf.clearRetainingCapacity();

                    peer.state = .messageStart;
                    bytesPerTick += chunkBytes.len;

                    if (piece.index > totalPieces) {
                        @branchHint(.unlikely);
                        std.log.err("peer {d} sen't unknown piece massage: {d}", .{
                            peer.socket,
                            piece.index,
                        });
                        continue :sw .dead;
                    }

                    peer.inFlight.receive(.{ .pieceIndex = piece.index, .begin = piece.begin }) catch {};
                    if (!peer.choked) {
                        @branchHint(.likely);

                        peer.fillRqPool(torrent, &pieces);

                        try kq.subscribe(peer.socket, .write, event.kevent.udata);
                    }

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

                    completedCount += 1;

                    if (pieces.isDownloadComplete()) {
                        @branchHint(.cold);
                        std.log.info("download finished", .{});
                        break :main;
                    }

                    for (peers.items) |otherPeer| {
                        if (peer.socket != otherPeer.socket) {
                            otherPeer.mq.add(.{ .have = piece.index }) catch {};
                            kq.subscribe(otherPeer.socket, .write, @intFromPtr(otherPeer)) catch {};
                        }
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
            kq.killPeer(peer.socket);
            pieces.killPeer(peer.workingOn);
            peer.deinit(alloc);

            for (peers.items, 0..) |item, i| {
                if (item == peer) {
                    _ = peers.swapRemove(i);
                    std.log.debug("dead count: {d}", .{deadCount});
                    deadCount += 1;
                    break;
                }
            }

            alloc.destroy(peer);

            if (tracker.oldAddrs.items.len - deadCount < 10) {
                kq.addTimer(@intFromEnum(Timer.tracker), 0, .{ .periodic = false }) catch {};
            }
        }
    }

    updateTracker(&tracker, pieces, torrent);
    for (tracker.trackers.items) |t| {
        tracker.sendAnnounce(alloc, t.url, null, .completed) catch {};
    }

    const delta: usize = @intCast(std.time.milliTimestamp() - downloadStart);
    const minutes = @as(f64, @floatFromInt(delta)) / std.time.ms_per_min;

    std.log.info("downloaded in: {d:.2} minutes", .{minutes});
}

fn updateTracker(tracker: *HttpTracker, pieces: PieceManager, torrent: Torrent) void {
    var downloaded: u64 = 0;

    for (pieces.pieces, 0..) |state, i| {
        if (state == .have) {
            downloaded += torrent.getPieceSize(i);
        }
    }

    tracker.downloaded = downloaded;
    tracker.left = torrent.totalLen - downloaded;
}

test {
    _ = @import("torrent.zig");
    _ = @import("piece-manager.zig");
    _ = @import("files.zig");
    _ = @import("http-tracker.zig");
    _ = @import("peer.zig");
    _ = @import("utils.zig");
}
