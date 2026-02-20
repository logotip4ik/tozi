const std = @import("std");
const builtin = @import("builtin");

pub const Torrent = @import("torrent.zig");
pub const PieceManager = @import("piece-manager.zig");
pub const Files = @import("files.zig");
pub const KQ = @import("kq.zig");
pub const Peer = @import("peer.zig");
pub const Tracker = @import("tracker.zig");
pub const Handshake = @import("handshake.zig");
pub const Socket = @import("socket.zig");

const hasher = @import("hasher");
const utils = @import("utils");
const proto = @import("proto.zig");
const trackerUtils = @import("tracker-utils.zig");

const ENABLE_FAST = true;
const ENABLE_EXTENSION = true;

const TaggedPointer = utils.TaggedPointer(union(enum) {
    tracker: *Tracker,
    peer: *Peer,
    pieces: *PieceManager,
});

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

    var pool: std.Thread.Pool = undefined;
    try pool.init(.{ .allocator = alloc });
    defer pool.deinit();

    const threadPipes = try std.posix.pipe();
    defer for (threadPipes) |fd| std.posix.close(fd);

    const readPipe, const writePipe = threadPipes;
    try kq.subscribe(readPipe, .read, TaggedPointer.pack(.{ .pieces = pieces }));

    var peers: std.array_list.Aligned(*Peer, null) = .empty;
    defer {
        for (peers.items) |peer| {
            kq.killSocket(peer.socket.fd);
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
        pieces.downloaded,
        &torrent,
    );
    defer tracker.deinit(alloc);
    const trackerTaggedPointer = TaggedPointer.pack(.{ .tracker = &tracker });
    var prevTrackerOperation: trackerUtils.Operation = .{ .timer = 0 };

    const Timer = enum { tracker, tick };
    try kq.addTimer(@intFromEnum(Timer.tracker), 0, .{ .periodic = false });
    try kq.addTimer(@intFromEnum(Timer.tick), 3 * std.time.ms_per_s, .{ .periodic = true });

    const handshake = Handshake.init(peerId, torrent.infoHash, .{
        .fast = ENABLE_FAST,
        .extended = ENABLE_EXTENSION,
    });

    const totalPieces = torrent.pieces.len / 20;

    while (try kq.next()) |event| {
        if (event.kind == .timer) if (std.enums.fromInt(Timer, event.ident)) |timer| switch (timer) {
            .tracker => {
                tracker.downloaded = pieces.downloaded;
                tracker.left = torrent.totalLen - tracker.downloaded;

                switch (try tracker.enqueueEvent(alloc, if (tracker.oldAddrs.items.len == 0) .started else .none)) {
                    .read => try kq.subscribe(tracker.client.socket(), .read, trackerTaggedPointer),
                    .write => try kq.subscribe(tracker.client.socket(), .write, trackerTaggedPointer),
                    .timer => unreachable, // shouldn't be available on first call
                }

                continue;
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
                            if (!ready) try kq.enable(peer.socket.fd, .write, TaggedPointer.pack(.{ .peer = peer }));
                        }
                        unchokedCount += 1;
                    } else if (peer.isUnchoked) {
                        peer.isUnchoked = false;
                        const ready = try peer.addMessage(.choke, &.{});
                        if (!ready) try kq.enable(peer.socket.fd, .write, TaggedPointer.pack(.{ .peer = peer }));
                    }

                    bytesPerTick += peer.bytesReceived;
                    activePeers += if (peer.bytesReceived > 0) 1 else 0;
                }

                const percent = (pieces.completedCount * 100) / totalPieces;
                const bytesPerSecond = bytesPerTick / 3;

                std.log.info("progress: {d:2}% {d}/{d} (peers: {d}, speed: {Bi:6.2})", .{
                    percent,
                    pieces.completedCount,
                    totalPieces,
                    activePeers,
                    bytesPerSecond,
                });

                continue;
            },
        } else continue;

        const taggedPointer = TaggedPointer.unpack(event.udata);
        switch (taggedPointer) {
            .peer => {},
            .pieces => {
                var peerAndPointersBytes: [16]u8 = undefined;
                const count = try std.posix.read(readPipe, &peerAndPointersBytes);
                utils.assert(count == peerAndPointersBytes.len);

                const peer: *Peer = @ptrFromInt(std.mem.readInt(usize, peerAndPointersBytes[0..8], .big));
                const piece: *PieceManager.PieceBuf = @ptrFromInt(std.mem.readInt(usize, peerAndPointersBytes[8..16], .big));

                defer pieces.consumePieceBuf(alloc, piece);
                defer if (peer.workingOn) |*x| x.unset(piece.index);

                if (piece.fetched == 0) {
                    pieces.reset(piece);

                    continue;
                }

                pieces.complete(piece);

                for (peers.items) |otherPeer| {
                    switch (otherPeer.state) {
                        .readHandshake, .writeHandshake, .dead => continue,
                        .messageStart, .message => {},
                    }

                    const ready = try otherPeer.addMessage(.{ .have = piece.index }, &.{});
                    if (!ready) try kq.enable(otherPeer.socket.fd, .write, event.udata);
                }

                if (pieces.isDownloadComplete()) {
                    tracker.downloaded = pieces.downloaded;
                    tracker.left = torrent.totalLen - tracker.downloaded;
                    const op = tracker.enqueueEvent(alloc, .completed) catch return;
                    switch (op) {
                        .read => try kq.subscribe(tracker.client.socket(), .read, trackerTaggedPointer),
                        .write => try kq.subscribe(tracker.client.socket(), .write, trackerTaggedPointer),
                        .timer => unreachable, // shouldn't be available on first call
                    }

                    for (peers.items) |otherPeer| {
                        kq.killSocket(otherPeer.socket.fd);
                    }
                }

                continue;
            },
            .tracker => {
                // get socket **before** updating state
                const socket = tracker.client.socket();

                const nextOperation = tracker.nextOperation(alloc) catch |err| {
                    std.log.warn("failed announcing with {t}", .{err});

                    tracker.client.deinit(alloc);
                    tracker.used = tracker.nextUsed() orelse {
                        std.log.info("all tracker urls are dead", .{});
                        return;
                    };

                    try kq.addTimer(@intFromEnum(Timer.tracker), 0, .{ .periodic = false });
                    prevTrackerOperation = .{ .timer = 0 };

                    continue;
                };
                defer prevTrackerOperation = nextOperation;

                switch (nextOperation) {
                    .read => if (@intFromEnum(nextOperation) != @intFromEnum(prevTrackerOperation)) {
                        kq.delete(socket, .write) catch {};
                        try kq.subscribe(socket, .read, trackerTaggedPointer);
                    },
                    .write => if (@intFromEnum(nextOperation) != @intFromEnum(prevTrackerOperation)) {
                        kq.delete(socket, .read) catch {};
                        try kq.subscribe(socket, .write, trackerTaggedPointer);
                    },
                    .timer => |timer| {
                        kq.killSocket(socket);

                        if (pieces.isDownloadComplete()) {
                            return;
                        }

                        try kq.addTimer(@intFromEnum(Timer.tracker), timer, .{ .periodic = false });

                        while (tracker.nextNewPeer()) |addr| {
                            const peer = try alloc.create(Peer);
                            errdefer alloc.destroy(peer);

                            const fd = try std.posix.socket(
                                std.posix.AF.INET,
                                std.posix.SOCK.STREAM | std.posix.SOCK.NONBLOCK,
                                std.posix.IPPROTO.TCP,
                            );
                            errdefer std.posix.close(fd);

                            std.log.debug("peer: {d} connecting to {f}", .{ fd, addr });
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

                            try kq.subscribe(peer.socket.fd, .write, TaggedPointer.pack(.{ .peer = peer }));
                            errdefer kq.killSocket(peer.socket.fd);

                            try peers.append(alloc, peer);
                        }

                        if (peers.items.len == 0 and tracker.newAddrs.items.len == 0) {
                            std.log.info("no pending or alive peers left", .{});
                            return;
                        }
                    },
                }

                continue;
            },
        }

        const peer = taggedPointer.peer;
        if (event.err) |err| {
            peer.state = .dead;
            std.log.err("peer: {d} received {t}", .{ peer.socket.fd, err });
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

                try kq.disable(peer.socket.fd, .write);
                try kq.subscribe(peer.socket.fd, .read, event.udata);
            },
            .messageStart, .message => {
                const ready = peer.send() catch {
                    peer.state = .dead;
                    break :sw;
                };

                if (!ready) continue;

                try kq.disable(peer.socket.fd, .write);
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
                        std.log.err("peer: {d} bad handshake {s}", .{ peer.socket.fd, @errorName(err) });
                        peer.state = .dead;
                        break :readblk;
                    };

                    peer.state = .messageStart;
                    peer.protocols.fast = matched.fast;
                    peer.protocols.extended = matched.extended;

                    if (matched.fast and pieces.downloaded == 0) {
                        const ready = try peer.addMessage(.haveNone, &.{});
                        if (!ready) try kq.enable(peer.socket.fd, .write, event.udata);

                        std.log.debug("peer: {d} sent 'haveNone' message", .{peer.socket.fd});
                    } else {
                        const bitfield = try pieces.torrentBitfieldBytes(alloc);
                        defer alloc.free(bitfield);

                        const ready = try peer.addMessage(.{ .bitfield = @intCast(bitfield.len) }, bitfield);
                        if (!ready) try kq.enable(peer.socket.fd, .write, event.udata);
                    }

                    if (matched.extended) {
                        std.log.debug("peer: {d} sending extended handshake message", .{peer.socket.fd});

                        var extended: Handshake.Extended = .{};

                        var w: std.Io.Writer.Allocating = try .initCapacity(alloc, 128);
                        defer w.deinit();

                        try extended.encode(alloc, &w.writer);

                        const ready = try peer.addMessage(.{
                            .extended = .{ .id = 0, .len = @intCast(w.written().len) },
                        }, w.written());
                        if (!ready) try kq.subscribe(peer.socket.fd, .write, event.udata);
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

                        const ready = try peer.fillRqPool(alloc, &torrent, pieces);
                        if (!ready) try kq.enable(peer.socket.fd, .write, event.udata);

                        continue;
                    }

                    if (len > Torrent.BLOCK_SIZE + 9) {
                        std.log.err("peer: {d} dropped (msg too big: {d})", .{ peer.socket.fd, len });
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

                    const message = peer.readMessageStart(alloc, idInt, len) catch |err| switch (err) {
                        error.EndOfStream => {
                            peer.state = .dead;
                            break :readblk;
                        },
                        else => |e| return e,
                    } orelse break :readblk;

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

                                std.log.info("peer: {d}, v: {?s}, reqq: {?d}", .{ peer.socket.fd, e.v, e.reqq });

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
                        std.log.info("peer: {d}, received unchoke message", .{peer.socket.fd});

                        peer.choked = false;
                        peer.state = .messageStart;

                        const ready = try peer.fillRqPool(alloc, &torrent, pieces);
                        if (!ready) try kq.enable(peer.socket.fd, .write, event.udata);
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
                            if (!ready) try kq.enable(peer.socket.fd, .write, event.udata);
                        }
                    },
                    .haveAll => {
                        peer.state = .messageStart;

                        if (peer.bitfield != null) {
                            continue;
                        }

                        std.log.debug("peer: {d} receied 'haveAll' message", .{peer.socket.fd});

                        peer.bitfield = try .initFull(alloc, pieces.pieces.len);
                        peer.workingOn = try .initEmpty(alloc, pieces.pieces.len);

                        if (pieces.hasInterestingPiece(peer.bitfield.?)) {
                            const ready = try peer.addMessage(.interested, &.{});
                            if (!ready) try kq.enable(peer.socket.fd, .write, event.udata);

                            std.log.debug("peer: {d} sent 'interested' message", .{peer.socket.fd});
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
                                peer.socket.fd,
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
                            if (!ready) try kq.enable(peer.socket.fd, .write, event.udata);
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

                        std.log.debug("peer: {d} received allowed fast for {d}", .{ peer.socket.fd, allowedFast });

                        const ready = try peer.fillRqPool(alloc, &torrent, pieces);
                        if (!ready) try kq.enable(peer.socket.fd, .write, event.udata);
                    },
                    .suggestPiece => |index| {
                        peer.state = .messageStart;
                        std.log.debug("peer: {d} received 'suggestPiece' for {d}", .{ peer.socket.fd, index });
                    },
                    .rejectRequest => |piece| {
                        peer.state = .messageStart;

                        peer.inFlight.receive(.{
                            .index = piece.index,
                            .begin = piece.begin,
                        }) catch {};

                        if (pieces.buffers.get(piece.index)) |buf| pieces.reset(buf);
                        if (peer.workingOn) |*workingOn| workingOn.unset(piece.index);

                        if (peer.workingPiece != null and peer.workingPiece.? == piece.index) {
                            peer.workingPiece = null;
                            peer.workingPieceOffset = 0;
                        }

                        const ready = try peer.fillRqPool(alloc, &torrent, pieces);
                        if (!ready) try kq.enable(peer.socket.fd, .write, event.udata);
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
                                peer.socket.fd,
                                piece.index,
                            });
                            peer.state = .dead;
                            break :readblk;
                        }

                        peer.inFlight.receive(.{ .index = piece.index, .begin = piece.begin }) catch {};

                        const ready = try peer.fillRqPool(alloc, &torrent, pieces);
                        if (!ready) try kq.enable(peer.socket.fd, .write, event.udata);

                        const pieceLen = torrent.getPieceSize(piece.index);
                        const fullPiece = try pieces.writePiece(alloc, piece, pieceLen, chunkBytes) orelse continue;

                        try pool.spawn(hashAndWrite, .{
                            writePipe,
                            peer,
                            fullPiece,
                            &torrent,
                            files,
                        });
                    },
                    .interested => {
                        peer.isInterested = true;
                        peer.state = .messageStart;
                        std.log.info("peer: {d} is interested", .{peer.socket.fd});
                    },
                    .notInterested => {
                        peer.isInterested = false;
                        peer.state = .messageStart;
                        std.log.info("peer: {d} is not interested", .{peer.socket.fd});
                    },
                    .request => |request| {
                        peer.state = .messageStart;

                        if (peer.requestsPerTick > 5 or !peer.isInterested or !peer.isUnchoked) {
                            continue;
                        }

                        if (request.index > totalPieces) {
                            @branchHint(.unlikely);
                            std.log.err("peer {d} sent unknown request message: {d}", .{
                                peer.socket.fd,
                                request.index,
                            });
                            peer.state = .dead;
                            break :readblk;
                        }

                        peer.requestsPerTick += 1;

                        std.log.info("peer: {d} sending {any}", .{ peer.socket.fd, request });
                        const data = try files.readPieceData(alloc, request, torrent.pieceLen);
                        defer alloc.free(data);

                        const m: proto.Message = .{ .piece = request };
                        try m.writeMessage(&peer.writeBuf.writer, data);
                        try kq.enable(peer.socket.fd, .write, event.udata);
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
            kq.killSocket(peer.socket.fd);
            pieces.killPeer(peer.workingOn);
            peer.deinit(alloc);

            for (peers.items, 0..) |item, i| if (item == peer) {
                alloc.destroy(peers.swapRemove(i));
                break;
            };
        }
    }
}

fn hashAndWrite(
    writeFd: std.posix.socket_t,
    peer: *const Peer,
    piece: *PieceManager.PieceBuf,
    torrent: *const Torrent,
    files: *const Files,
) void {
    var peerAndPointersBytes: [16]u8 = undefined;
    std.mem.writeInt(usize, peerAndPointersBytes[0..8], @intFromPtr(peer), .big);
    std.mem.writeInt(usize, peerAndPointersBytes[8..16], @intFromPtr(piece), .big);

    const expectedHash = torrent.pieces[piece.index * 20 ..];
    const computedHash = hasher.hash(piece.written());

    if (!std.mem.eql(u8, computedHash[0..20], expectedHash[0..20])) {
        @branchHint(.unlikely);

        std.log.warn("piece: {d} corrupt from peer {d}", .{ piece.index, peer.socket.fd });

        // mark as errored
        piece.fetched = 0;

        const wrote = std.posix.write(writeFd, &peerAndPointersBytes) catch @panic("failed writing to thread pipe");
        utils.assert(wrote == peerAndPointersBytes.len);

        return;
    }

    files.writePieceData(piece.index, torrent.pieceLen, piece.written()) catch |err| {
        @branchHint(.unlikely);

        std.log.warn("piece: {d} failed writing with {t}", .{ piece.index, err });

        // mark as errored
        piece.fetched = 0;

        const wrote = std.posix.write(writeFd, &peerAndPointersBytes) catch @panic("failed writing to thread pipe");
        utils.assert(wrote == peerAndPointersBytes.len);

        return;
    };

    const wrote = std.posix.write(writeFd, &peerAndPointersBytes) catch @panic("failed writing to thread pipe");
    utils.assert(wrote == peerAndPointersBytes.len);
}

test {
    std.testing.refAllDecls(@This());
}
