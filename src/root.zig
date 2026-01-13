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
        if (!std.mem.startsWith(u8, announce, "http")) {
            continue;
        }

        std.log.debug("adding tracker url {s}", .{announce});
        try tracker.addTracker(alloc, announce);
        if (tracker.newAddrs.items.len > 0) {
            break;
        }
    }

    const numberOfPieces = torrent.pieces.len / 20;

    var pieces: PieceManager = try .init(alloc, numberOfPieces);
    defer pieces.deinit(alloc);

    var kq: KQ = try .init(alloc);
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

    const downloadStart = std.time.milliTimestamp();
    const totalPieces = torrent.pieces.len / 20;
    var completedCount: usize = 0;

    const handshake: proto.TcpHandshake = .{ .infoHash = torrent.infoHash, .peerId = peerId };
    const handshakeBytes = std.mem.asBytes(&handshake);

    loop: while (try kq.next()) |event| {
        if (event.kind == .timer) {
            const timer = std.enums.fromInt(Timer, event.ident) orelse continue;

            switch (timer) {
                .tracker => {
                    updateTracker(&tracker, pieces, torrent);

                    if (peers.items.len < 10 and tracker.newAddrs.items.len < 10) {
                        tracker.numWant += HttpTracker.defaultNumWant;
                    }

                    const nextKeepAlive = try tracker.keepAlive(alloc);

                    std.log.info("setting timer to next: {d}", .{nextKeepAlive});
                    try kq.addTimer(@intFromEnum(Timer.tracker), nextKeepAlive, .{ .periodic = false });

                    while (tracker.nextNewPeer()) |addr| {
                        const peer = try alloc.create(Peer);
                        errdefer alloc.destroy(peer);

                        const fd = try std.posix.socket(
                            std.posix.AF.INET,
                            std.posix.SOCK.STREAM | std.posix.SOCK.NONBLOCK,
                            std.posix.IPPROTO.TCP,
                        );
                        errdefer std.posix.close(fd);

                        std.posix.connect(@intCast(fd), &addr.any, addr.getOsSockLen()) catch |err| switch (err) {
                            error.WouldBlock => {},
                            else => return err,
                        };

                        peer.* = Peer.init(alloc, fd) catch |err| {
                            std.log.err("failed connecting to {f} with {t}", .{ addr, err });
                            alloc.destroy(peer);
                            continue;
                        };

                        try kq.subscribe(peer.socket, .write, @intFromPtr(peer));

                        try peers.append(alloc, peer);
                    }

                    if (peers.items.len == 0) {
                        return error.AllStreamsDead;
                    }
                },
                .tick => {
                    var bytesPerTick: usize = 0;
                    var activePeers: usize = 0;

                    const maxPeersToUnchoke = 5;
                    var unchokedCount: usize = 0;

                    std.mem.sort(*Peer, peers.items, {}, Peer.compareBytesReceived);

                    for (peers.items) |peer| {
                        defer {
                            peer.bytesReceived = 0;
                            peer.requestsPerTick = 0;
                        }

                        const shouldUnchoke = peer.isInterested and unchokedCount < maxPeersToUnchoke;
                        if (shouldUnchoke) {
                            if (!peer.isUnchoked) {
                                peer.isUnchoked = true;
                                try peer.addMessage(.unchoke, &.{});
                                try kq.enable(peer.socket, .write, @intFromPtr(peer));
                            }
                            unchokedCount += 1;
                        } else if (peer.isUnchoked) {
                            peer.isUnchoked = false;
                            try peer.addMessage(.choke, &.{});
                            try kq.enable(peer.socket, .write, @intFromPtr(peer));
                        }

                        bytesPerTick += peer.bytesReceived;
                        activePeers += if (peer.bytesReceived > 0) 1 else 0;
                    }

                    const percent = (completedCount * 100) / totalPieces;
                    const bytesPerSecond = bytesPerTick / 3;

                    std.log.info("progress: {d:3}% {d}/{d} (peers: {d}, speed: {Bi:.2})", .{
                        percent,
                        completedCount,
                        totalPieces,
                        activePeers,
                        bytesPerSecond,
                    });
                },
            }

            continue;
        }

        const peer: *Peer = @ptrFromInt(event.udata);

        if (event.err) |err| {
            peer.state = .dead;
            std.log.err("peer: {d} received {t}", .{ peer.socket, err });
        }

        if (event.kind == .write and peer.state != .dead) sw: switch (peer.state) {
            .readHandshake, .dead => {},
            .writeHandshake => {
                if (peer.writeBuf.written().len == 0) {
                    try peer.writeBuf.writer.writeAll(handshakeBytes);
                }

                const ready = peer.send() catch {
                    peer.state = .dead;
                    break :sw;
                };

                if (!ready) continue;

                peer.state = .readHandshake;

                try kq.disable(peer.socket, .write);
                try kq.subscribe(peer.socket, .read, @intFromPtr(peer));
            },
            .messageStart, .message => {
                const ready = peer.send() catch {
                    peer.state = .dead;
                    break :sw;
                };

                if (!ready) continue;

                try kq.disable(peer.socket, .write);
            },
        };

        if (event.kind == .read and peer.state != .dead) sw: switch (peer.state) {
            .writeHandshake, .dead => {},
            .readHandshake => {
                const bytes = try peer.read(alloc, proto.TCP_HANDSHAKE_LEN) orelse continue;
                defer peer.readBuf.clearRetainingCapacity();

                const received: *proto.TcpHandshake = @ptrCast(bytes);

                handshake.validate(received.*) catch |err| {
                    std.log.err("peer: {d} bad handshake {s}", .{ peer.socket, @errorName(err) });
                    peer.state = .dead;
                    break :sw;
                };

                peer.state = .messageStart;

                const bitfield = try pieces.torrentBitfieldBytes(alloc);
                defer alloc.free(bitfield);

                try peer.addMessage(.{ .bitfield = @intCast(bitfield.len) }, bitfield);
                try kq.enable(peer.socket, .write, event.udata);
            },
            .messageStart => {
                const len = try peer.readInt(u32);
                if (len == 0) {
                    if (!peer.choked) {
                        const needsWrite = try peer.fillRqPool(alloc, torrent, &pieces);
                        if (needsWrite) try kq.enable(peer.socket, .write, event.udata);
                    }

                    continue;
                }

                if (len > Torrent.BLOCK_SIZE + 9) {
                    std.log.err("peer: {d} dropped (msg too big: {d})", .{ peer.socket, len });
                    peer.state = .dead;
                    break :sw;
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
                    .piece => .{ .piece = .{
                        .index = try peer.readInt(u32),
                        .begin = try peer.readInt(u32),
                        .len = len - 9,
                    } },
                    .request => blk: {
                        const index = try peer.readInt(u32);
                        const begin = try peer.readInt(u32);
                        const rLen = try peer.readInt(u32);

                        if (rLen > Torrent.BLOCK_SIZE) {
                            std.log.err("peer: {d} dropped (msg too big: {d})", .{ peer.socket, len });
                            peer.state = .dead;
                            break :sw;
                        }

                        break :blk .{ .request = .{
                            .index = index,
                            .begin = begin,
                            .len = rLen,
                        } };
                    },
                    .cancel => blk: {
                        const index = try peer.readInt(u32);
                        const begin = try peer.readInt(u32);
                        const cLen = try peer.readInt(u32);

                        if (cLen > Torrent.BLOCK_SIZE) {
                            std.log.err("peer: {d} dropped (msg too big: {d})", .{ peer.socket, len });
                            peer.state = .dead;
                            break :sw;
                        }

                        break :blk .{ .cancel = .{
                            .index = index,
                            .begin = begin,
                            .len = cLen,
                        } };
                    },
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

                    peer.state = .messageStart;
                    const needsWrite = try peer.fillRqPool(alloc, torrent, &pieces);
                    if (needsWrite) try kq.enable(peer.socket, .write, event.udata);
                },
                .have => |piece| {
                    defer peer.state = .messageStart;

                    var bitfield = peer.bitfield orelse {
                        std.log.err("unexpected empty bitfield with have message", .{});
                        continue;
                    };

                    bitfield.set(piece);
                },
                .bitfield => |len| {
                    const bytes = try peer.read(alloc, len) orelse continue;
                    defer peer.readBuf.clearRetainingCapacity();

                    try peer.setBitfield(alloc, bytes);

                    if (pieces.hasInterestingPiece(peer.bitfield.?)) {
                        peer.state = .messageStart;
                        try peer.addMessage(.interested, &.{});
                        try kq.enable(peer.socket, .write, event.udata);
                    }
                },
                .piece => |piece| {
                    const chunkBytes = try peer.read(alloc, piece.len) orelse continue;
                    defer peer.readBuf.clearRetainingCapacity();

                    peer.state = .messageStart;
                    peer.bytesReceived += chunkBytes.len;

                    if (piece.index > totalPieces) {
                        @branchHint(.unlikely);
                        std.log.err("peer {d} sen't unknown piece massage: {d}", .{
                            peer.socket,
                            piece.index,
                        });
                        peer.state = .dead;
                        break :sw;
                    }

                    peer.inFlight.receive(.{ .pieceIndex = piece.index, .begin = piece.begin }) catch {};
                    if (!peer.choked) {
                        @branchHint(.likely);

                        const needsWrite = try peer.fillRqPool(alloc, torrent, &pieces);
                        if (needsWrite) try kq.enable(peer.socket, .write, event.udata);
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
                        break :loop;
                    }

                    for (peers.items) |p| {
                        try p.addMessage(.{ .have = piece.index }, &.{});
                        try kq.enable(p.socket, .write, @intFromPtr(p));
                    }
                },
                .interested => {
                    peer.isInterested = true;
                    peer.state = .messageStart;
                    std.log.info("peer: {d} is interested", .{peer.socket});
                },
                .not_interested => {
                    peer.isInterested = false;
                    peer.state = .messageStart;
                    std.log.info("peer: {d} is not interested", .{peer.socket});
                },
                .request => |request| {
                    peer.state = .messageStart;

                    if (peer.requestsPerTick > 5 or !peer.isInterested or !peer.isUnchoked) {
                        continue;
                    }

                    peer.requestsPerTick += 1;

                    std.log.info("peer: {d} sending {any}", .{ peer.socket, request });
                    const data = try files.readPiece(alloc, request.index, request.begin, request.len);
                    defer alloc.free(data);

                    const m: proto.Message = .{ .piece = request };
                    try m.writeMessage(&peer.writeBuf.writer, data);
                    try kq.enable(peer.socket, .write, event.udata);
                },
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
                    break;
                }
            }

            alloc.destroy(peer);

            if (peers.items.len < 10) {
                kq.addTimer(@intFromEnum(Timer.tracker), 0, .{ .periodic = false }) catch {};
            }
        }
    }

    updateTracker(&tracker, pieces, torrent);
    for (tracker.trackers.items) |t| {
        tracker.sendAnnounce(alloc, t.url, null, .stopped) catch {};
    }

    const delta: usize = @intCast(std.time.milliTimestamp() - downloadStart);
    const minutes = @as(f64, @floatFromInt(delta)) / std.time.ms_per_min;

    if (minutes < 60) {
        std.log.info("downloaded in: {d:.2} minutes", .{minutes});
    } else {
        const hours = minutes / 60;
        std.log.info("downloaded in: {d:.2} hours", .{hours});
    }
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
