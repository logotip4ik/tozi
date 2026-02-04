const std = @import("std");
const builtin = @import("builtin");

pub const Torrent = @import("torrent.zig");
pub const PieceManager = @import("piece-manager.zig");
pub const Files = @import("files.zig");
pub const KQ = @import("kq.zig");
pub const Peer = @import("peer.zig");
pub const Tracker = @import("tracker.zig");
pub const Handshake = @import("handshake.zig");

const proto = @import("proto.zig");
const utils = @import("utils.zig");

const ENABLE_FAST = true;
const ENABLE_EXTENSION = true;

/// TODO: we also need to handle case when requested chunk of piece never arrives. `inFlight`
/// requests doesn't track when the request was done, so we don't have a way to check if this chunk
/// is "stale" and all our download could be broken by one chunk that is "lost"...

pub fn downloadTorrent(
    alloc: std.mem.Allocator,
    peerId: [20]u8,
    torrent: Torrent,
    files: *Files,
    pieces: *PieceManager,
) !void {
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

    var tracker: Tracker = try .init(
        alloc,
        peerId,
        torrent.infoHash,
        pieces.countDownloaded(&torrent),
        &torrent,
    );
    defer tracker.deinit(alloc);

    const trackerTick = tracker.keepAlive(alloc) catch |err| {
        std.log.err("failed keeping alive with {t}", .{err});
        return;
    };

    const Timer = enum { start, tracker, tick };
    try kq.addTimer(@intFromEnum(Timer.tracker), trackerTick, .{ .periodic = false });
    try kq.addTimer(@intFromEnum(Timer.tick), 3 * std.time.ms_per_s, .{ .periodic = true });
    try kq.addTimer(@intFromEnum(Timer.start), 0, .{ .periodic = false }); // kick off the loop

    const handshake = Handshake.init(peerId, torrent.infoHash, .{
        .fast = ENABLE_FAST,
        .extended = ENABLE_EXTENSION,
    });

    const totalPieces = torrent.pieces.len / 20;

    loop: while (try kq.next()) |event| {
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
            errdefer peer.deinit(alloc);

            try kq.subscribe(peer.socket, .write, @intFromPtr(peer));
            errdefer kq.killPeer(peer.socket);

            try peers.append(alloc, peer);
        }

        if (event.kind == .timer) {
            const timer = std.enums.fromInt(Timer, event.ident) orelse continue;

            switch (timer) {
                .start => {},
                .tracker => {
                    tracker.downloaded = pieces.countDownloaded(&torrent);
                    tracker.left = torrent.totalLen - tracker.downloaded;

                    const nextKeepAlive = tracker.keepAlive(alloc) catch |err| {
                        std.log.err("failed keeping alive with {t}", .{err});
                        return;
                    };

                    try kq.addTimer(@intFromEnum(Timer.tracker), nextKeepAlive, .{ .periodic = false });

                    if (peers.items.len == 0 and tracker.newAddrs.items.len == 0) {
                        std.log.info("no pending or alive peers left", .{});
                        return;
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
                                const ready = try peer.addMessage(.unchoke, &.{});
                                if (!ready) try kq.enable(peer.socket, .write, @intFromPtr(peer));
                            }
                            unchokedCount += 1;
                        } else if (peer.isUnchoked) {
                            peer.isUnchoked = false;
                            const ready = try peer.addMessage(.choke, &.{});
                            if (!ready) try kq.enable(peer.socket, .write, @intFromPtr(peer));
                        }

                        bytesPerTick += peer.bytesReceived;
                        activePeers += if (peer.bytesReceived > 0) 1 else 0;
                    }

                    const percent = (pieces.completedCount * 100) / totalPieces;
                    const bytesPerSecond = bytesPerTick / 3;

                    std.log.info("progress: {d:2}% {d}/{d} (peers: {d}, speed: {Bi:.2})", .{
                        percent,
                        pieces.completedCount,
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

        const isDead = peer.state == .dead;

        if (event.kind == .write and !isDead) sw: switch (peer.state) {
            .readHandshake, .dead => {},
            .writeHandshake => {
                if (peer.writeBuf.written().len == 0) {
                    try peer.writeBuf.writer.writeAll(&handshake.asBytes());
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

        if (event.kind == .read and !isDead) readblk: {
            peer.fillReadBuffer(alloc, Torrent.BLOCK_SIZE * 8) catch |err| switch (err) {
                error.EndOfStream => {
                    peer.state = .dead;
                    break :readblk;
                },
                else => |e| return e,
            } orelse {};

            while (peer.readBuf.writer.end > 0) switch (peer.state) {
                .writeHandshake, .dead => {},
                .readHandshake => {
                    const bytes = peer.read(alloc, Handshake.HANDSHAKE_LEN) catch |err| switch (err) {
                        error.EndOfStream => {
                            peer.state = .dead;
                            break :readblk;
                        },
                        else => |e| return e,
                    } orelse break :readblk;
                    defer alloc.free(bytes);

                    const matched = handshake.matchExtensions(bytes) catch |err| {
                        std.log.err("peer: {d} bad handshake {s}", .{ peer.socket, @errorName(err) });
                        peer.state = .dead;
                        break :readblk;
                    };

                    peer.state = .messageStart;
                    peer.protocols.fast = matched.fast;
                    peer.protocols.extended = matched.extended;

                    if (matched.fast and pieces.countDownloaded(&torrent) == 0) {
                        const ready = try peer.addMessage(.haveNone, &.{});
                        if (!ready) try kq.enable(peer.socket, .write, event.udata);

                        std.log.debug("peer: {d} sent 'haveNone' message", .{peer.socket});
                    } else {
                        const bitfield = try pieces.torrentBitfieldBytes(alloc);
                        defer alloc.free(bitfield);

                        const ready = try peer.addMessage(.{ .bitfield = @intCast(bitfield.len) }, bitfield);
                        if (!ready) try kq.enable(peer.socket, .write, event.udata);
                    }

                    if (matched.extended) {
                        std.log.debug("peer: {d} sending extended handshake message", .{peer.socket});

                        var extended: Handshake.Extended = .{};

                        var w: std.Io.Writer.Allocating = try .initCapacity(alloc, 128);
                        defer w.deinit();

                        try extended.encode(alloc, &w.writer);

                        const ready = try peer.addMessage(.{
                            .extended = .{ .id = 0, .len = @intCast(w.written().len) },
                        }, w.written());
                        if (!ready) try kq.subscribe(peer.socket, .write, event.udata);
                    }
                },
                .messageStart => {
                    const len = peer.peekInt(alloc, u32, 0) catch |err| switch (err) {
                        error.EndOfStream => {
                            peer.state = .dead;
                            break :readblk;
                        },
                        else => |e| return e,
                    } orelse break :readblk;

                    if (len == 0) {
                        _ = peer.readBuf.writer.consume(@sizeOf(u32));

                        if (!peer.choked) {
                            const ready = try peer.fillRqPool(alloc, &torrent, pieces);
                            if (!ready) try kq.enable(peer.socket, .write, event.udata);
                        }

                        continue;
                    }

                    if (len > Torrent.BLOCK_SIZE + 9) {
                        std.log.err("peer: {d} dropped (msg too big: {d})", .{ peer.socket, len });
                        peer.state = .dead;
                        break :readblk;
                    }

                    const idInt = peer.peekInt(alloc, u8, @sizeOf(u32)) catch |err| switch (err) {
                        error.EndOfStream => {
                            peer.state = .dead;
                            break :readblk;
                        },
                        else => |e| return e,
                    } orelse break :readblk;

                    const id = std.enums.fromInt(proto.MessageId, idInt) orelse {
                        std.log.warn("peer: {d} unknown msg id {d}", .{ peer.socket, idInt });
                        peer.state = .dead;
                        break :readblk;
                    };

                    const sizeOfMessageStart = id.messageStartLen();
                    const messageStartBytes = peer.read(alloc, sizeOfMessageStart) catch |err| switch (err) {
                        error.EndOfStream => {
                            peer.state = .dead;
                            break :readblk;
                        },
                        else => |e| return e,
                    } orelse break :readblk;
                    defer alloc.free(messageStartBytes);

                    var reader: std.Io.Reader = .fixed(messageStartBytes);
                    reader.toss(@sizeOf(u32) + @sizeOf(u8));

                    const message: proto.Message = switch (id) {
                        .choke => .choke,
                        .unchoke => .unchoke,
                        .interested => .interested,
                        .notInterested => .notInterested,
                        .haveAll => .haveAll,
                        .haveNone => .haveNone,

                        .have => .{ .have = reader.takeInt(u32, .big) catch unreachable },
                        .bitfield => .{ .bitfield = len - 1 },

                        .suggestPiece => .{ .suggestPiece = reader.takeInt(u32, .big) catch unreachable },
                        .allowedFast => .{ .allowedFast = reader.takeInt(u32, .big) catch unreachable },

                        .piece => .{ .piece = .{
                            .index = reader.takeInt(u32, .big) catch unreachable,
                            .begin = reader.takeInt(u32, .big) catch unreachable,
                            .len = len - 9,
                        } },

                        .extended => .{ .extended = .{
                            .id = reader.takeByte() catch unreachable,
                            .len = len - 2,
                        } },

                        .request, .cancel, .rejectRequest => blk: {
                            const index = reader.takeInt(u32, .big) catch unreachable;
                            const begin = reader.takeInt(u32, .big) catch unreachable;
                            const mLen = reader.takeInt(u32, .big) catch unreachable;

                            if (mLen > Torrent.BLOCK_SIZE) {
                                std.log.err("peer: {d} dropped (msg too big: {d})", .{ peer.socket, len });
                                peer.state = .dead;
                                break :readblk;
                            }

                            if (id == .request) {
                                break :blk .{ .request = .{
                                    .index = index,
                                    .begin = begin,
                                    .len = mLen,
                                } };
                            } else if (id == .cancel) {
                                break :blk .{ .cancel = .{
                                    .index = index,
                                    .begin = begin,
                                    .len = mLen,
                                } };
                            } else {
                                break :blk .{ .rejectRequest = .{
                                    .index = index,
                                    .begin = begin,
                                    .len = mLen,
                                } };
                            }
                        },

                        .port => .{ .port = reader.takeInt(u16, .big) catch unreachable },
                    };

                    peer.state = .{ .message = message };
                },
                .message => |message| switch (message) {
                    .extended => |extended| {
                        const bytes = peer.read(alloc, extended.len) catch |err| switch (err) {
                            error.EndOfStream => {
                                peer.state = .dead;
                                break :readblk;
                            },
                            else => |e| return e,
                        } orelse break :readblk;
                        defer alloc.free(bytes);

                        peer.state = .messageStart;

                        switch (extended.id) {
                            // 0 - reserved as `handshake`
                            0 => {
                                var reader: std.Io.Reader = .fixed(bytes);
                                const e = Handshake.Extended.decode(alloc, &reader) catch {
                                    continue; // `while` read loop
                                };
                                peer.extended = e;

                                std.log.info("peer: {d}, v: {?s}, reqq: {?d}", .{ peer.socket, e.v, e.reqq });

                                if (e.reqq) |reqq| peer.inFlight.resize(alloc, reqq) catch {};
                            },
                            else => {},
                        }
                    },
                    .choke => {
                        peer.choked = true;
                        peer.state = .messageStart;
                    },
                    .unchoke => {
                        peer.choked = false;
                        peer.state = .messageStart;

                        const ready = try peer.fillRqPool(alloc, &torrent, pieces);
                        if (!ready) try kq.enable(peer.socket, .write, event.udata);

                        std.log.debug("peer: {d}, received unchoke message", .{peer.socket});
                    },
                    .have => |piece| {
                        peer.state = .messageStart;

                        var bitfield = peer.bitfield orelse {
                            std.log.err("unexpected empty bitfield with have message", .{});
                            continue;
                        };

                        bitfield.set(piece);

                        if (pieces.hasInterestingPiece(bitfield)) {
                            const ready = try peer.addMessage(.interested, &.{});
                            if (!ready) try kq.enable(peer.socket, .write, event.udata);
                        }
                    },
                    .haveAll => {
                        peer.state = .messageStart;

                        if (peer.bitfield != null) {
                            continue;
                        }

                        std.log.debug("peer: {d} receied 'haveAll' message", .{peer.socket});

                        peer.bitfield = try .initFull(alloc, pieces.pieces.len);
                        peer.workingOn = try .initEmpty(alloc, pieces.pieces.len);

                        if (pieces.hasInterestingPiece(peer.bitfield.?)) {
                            const ready = try peer.addMessage(.interested, &.{});
                            if (!ready) try kq.enable(peer.socket, .write, event.udata);

                            std.log.debug("peer: {d} sent 'interested' message", .{peer.socket});
                        }
                    },
                    .haveNone => {
                        peer.state = .messageStart;

                        if (peer.bitfield != null) {
                            continue;
                        }

                        peer.bitfield = try .initEmpty(alloc, pieces.pieces.len);
                        peer.workingOn = try .initEmpty(alloc, pieces.pieces.len);
                    },
                    .bitfield => |len| {
                        if (peer.protocols.fast and peer.bitfield != null) {
                            peer.state = .dead;
                            std.log.warn("peer: {d} received bitfield message while already received `have` messages", .{
                                peer.socket,
                            });
                            break :readblk;
                        }

                        const bytes = peer.read(alloc, len) catch |err| switch (err) {
                            error.EndOfStream => {
                                peer.state = .dead;
                                break :readblk;
                            },
                            else => |e| return e,
                        } orelse break :readblk;
                        defer alloc.free(bytes);

                        peer.state = .messageStart;

                        peer.bitfield = pieces.bytesToBitfield(alloc, bytes) catch |err| {
                            std.log.err("corruupt bitifield ?{t}", .{err});
                            peer.state = .dead;
                            break :readblk;
                        };
                        peer.workingOn = try .initEmpty(alloc, pieces.pieces.len);

                        if (pieces.hasInterestingPiece(peer.bitfield.?)) {
                            const ready = try peer.addMessage(.interested, &.{});
                            if (!ready) try kq.enable(peer.socket, .write, event.udata);
                        }
                    },
                    .allowedFast => |allowedFast| blk: {
                        peer.state = .messageStart;

                        if (allowedFast >= pieces.pieces.len) {
                            peer.state = .dead;
                            break :readblk;
                        }

                        for (peer.allowedFast.items) |existing| {
                            if (existing == allowedFast) break :blk;
                        }

                        peer.allowedFast.appendBounded(allowedFast) catch continue;

                        std.log.debug("peer: {d} received allowed fast for {d}", .{ peer.socket, allowedFast });

                        const ready = try peer.fillRqPool(alloc, &torrent, pieces);
                        if (!ready) try kq.enable(peer.socket, .write, event.udata);
                    },
                    .suggestPiece => |index| {
                        peer.state = .messageStart;
                        std.log.debug("peer: {d} received 'suggestPiece' for {d}", .{ peer.socket, index });
                    },
                    .rejectRequest => |piece| {
                        _ = piece;
                        peer.state = .messageStart;

                        // TODO: we need to add this request back to queue, or reset the whole piece
                        // and give it to another peer
                        // peer.inFlight.receive(.{
                        //     .index = piece.index,
                        //     .begin = piece.begin,
                        // }) catch {};
                    },
                    .piece => |piece| {
                        const chunkBytes = peer.read(alloc, piece.len) catch |err| switch (err) {
                            error.EndOfStream => {
                                peer.state = .dead;
                                break :readblk;
                            },
                            else => |e| return e,
                        } orelse break :readblk;
                        defer alloc.free(chunkBytes);

                        peer.state = .messageStart;
                        peer.bytesReceived += chunkBytes.len;

                        if (piece.index > totalPieces) {
                            @branchHint(.unlikely);
                            std.log.err("peer {d} sent unknown piece message: {d}", .{
                                peer.socket,
                                piece.index,
                            });
                            peer.state = .dead;
                            break :readblk;
                        }

                        peer.inFlight.receive(.{ .index = piece.index, .begin = piece.begin }) catch {};
                        if (!peer.choked) {
                            @branchHint(.likely);

                            const ready = try peer.fillRqPool(alloc, &torrent, pieces);
                            if (!ready) try kq.enable(peer.socket, .write, event.udata);
                        }

                        const pieceLen = torrent.getPieceSize(piece.index);
                        var completed = try pieces.writePiece(alloc, piece, pieceLen, chunkBytes) orelse continue;

                        defer pieces.consumePieceBuf(alloc, &completed);
                        defer if (peer.workingOn) |*x| x.unset(piece.index);

                        const expectedHash = torrent.pieces[piece.index * 20 ..][0..20];
                        pieces.validatePiece(completed.written(), expectedHash) catch {
                            @branchHint(.unlikely);
                            std.log.warn("piece: {d} corrupt from peer {d}", .{ piece.index, peer.socket });
                            pieces.reset(piece.index);
                            continue;
                        };

                        try files.writePieceData(piece.index, torrent.pieceLen, completed.written());

                        if (pieces.isDownloadComplete()) {
                            @branchHint(.cold);
                            std.log.info("download finished", .{});
                            break :loop;
                        }

                        for (peers.items) |p| {
                            switch (p.state) {
                                .readHandshake, .writeHandshake, .dead => continue,
                                .messageStart, .message => {},
                            }

                            const ready = try p.addMessage(.{ .have = piece.index }, &.{});
                            if (!ready) try kq.enable(p.socket, .write, @intFromPtr(p));
                        }
                    },
                    .interested => {
                        peer.isInterested = true;
                        peer.state = .messageStart;
                        std.log.info("peer: {d} is interested", .{peer.socket});
                    },
                    .notInterested => {
                        peer.isInterested = false;
                        peer.state = .messageStart;
                        std.log.info("peer: {d} is not interested", .{peer.socket});
                    },
                    .request => |request| {
                        peer.state = .messageStart;

                        if (peer.requestsPerTick > 5 or !peer.isInterested or !peer.isUnchoked) {
                            continue;
                        }

                        if (request.index > totalPieces) {
                            @branchHint(.unlikely);
                            std.log.err("peer {d} sent unknown request message: {d}", .{
                                peer.socket,
                                request.index,
                            });
                            peer.state = .dead;
                            break :readblk;
                        }

                        peer.requestsPerTick += 1;

                        std.log.info("peer: {d} sending {any}", .{ peer.socket, request });
                        const data = try files.readPieceData(alloc, request, torrent.pieceLen);
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
        }

        if (peer.state == .dead) {
            kq.killPeer(peer.socket);
            pieces.killPeer(peer.workingOn);
            peer.deinit(alloc);

            for (peers.items, 0..) |item, i| {
                if (item == peer) {
                    alloc.destroy(peers.swapRemove(i));
                    break;
                }
            }
        }
    }

    tracker.downloaded = pieces.countDownloaded(&torrent);
    tracker.left = torrent.totalLen - tracker.downloaded;
    tracker.finalizeSource(alloc);
}

test {
    std.testing.refAllDecls(@This());
}
