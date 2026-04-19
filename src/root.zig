const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");

pub const Torrent = @import("torrent.zig");
pub const PieceManager = @import("piece-manager.zig");
pub const Files = @import("files.zig");
pub const KQ = @import("kq.zig");
pub const Peer = @import("peer.zig");
pub const Tracker = @import("tracker.zig");
pub const Handshake = @import("handshake.zig");
pub const Socket = @import("socket.zig");
pub const Ticker = @import("ticker.zig");
pub const Pex = @import("pex.zig");
pub const Magnet = @import("magnet.zig");

const proto = @import("proto.zig");
pub const utils = @import("utils.zig");

const ENABLE_FAST = true;
const ENABLE_EXTENSION = true;
const ENABLE_PEX = true;
const PEERS_MAX = 30;
const CLIENT_NAME = std.fmt.comptimePrint("Tozi {f}", .{build_options.version});
const WORKER_MESSAGE_SIZE = 20;

const tg = utils.TaggedPointer(union(enum) {
    tracker: *Tracker,
    tracker_client_timeout: *Tracker.Client,
    peer: *Peer,
    pieces: *PieceManager,
    ticker: *Ticker,
});

pub const DownloadTorrentContext = struct {
    alloc: std.mem.Allocator,
    io: std.Io,
    loop: *KQ,
    files: *Files,
    pieces: *PieceManager,
    ticker: ?*Ticker = null,
};

const PeerAllocator = std.heap.memory_pool.Extra(Peer, .{ .alignment = null, .growable = false });
const PeerPtrs = std.array_list.Aligned(*Peer, null);

/// TODO: we also need to handle case when requested chunk of piece never arrives. `in_flight`
/// requests doesn't track when the request was done, so we don't have a way to check if this chunk
/// is "stale" and all our download could be broken by one chunk that is "lost"...
pub fn downloadTorrent(
    ctx: DownloadTorrentContext,
    peer_id: [20]u8,
    torrent: *const Torrent,
) !void {
    const alloc = ctx.alloc;
    const io = ctx.io;
    const files = ctx.files;
    const pieces = ctx.pieces;
    const kq = ctx.loop;

    var write_group: std.Io.Group = .init;
    defer write_group.await(io) catch unreachable;

    const thread_pipes = blk: {
        var pipefd: [2]std.posix.fd_t = undefined;
        const rc = std.posix.system.pipe(&pipefd);

        break :blk switch (std.posix.errno(rc)) {
            .SUCCESS => pipefd,
            else => |err| return std.posix.unexpectedErrno(err),
        };
    };
    defer for (thread_pipes) |fd| std.Io.Threaded.closeFd(fd);

    const read_pipe, const write_pipe = thread_pipes;
    try kq.subscribe(read_pipe, .read, tg.pack(.{ .pieces = pieces }));

    var peer_allocator: PeerAllocator = try .initCapacity(alloc, PEERS_MAX);
    defer peer_allocator.deinit(alloc);

    var peers: PeerPtrs = try .initCapacity(alloc, PEERS_MAX);
    defer {
        for (peers.items) |peer| killPeer(alloc, peer, kq, pieces, &peer_allocator);
        peers.deinit(alloc);
    }

    var tracker: Tracker = try .init(alloc, io, torrent);
    defer tracker.deinit(alloc);
    const tracker_tagged_pointer = tg.pack(.{ .tracker = &tracker });

    try kq.addTimer(tracker_tagged_pointer, 0, .{ .periodic = false });
    if (ctx.ticker) |ticker| {
        try kq.addTimer(
            tg.pack(.{ .ticker = ticker }),
            @as(usize, ticker.tick) * std.time.ms_per_s,
            .{ .periodic = true },
        );
    }

    const handshake = Handshake.init(peer_id, torrent.info_hash, .{
        .fast = ENABLE_FAST,
        .extended = ENABLE_EXTENSION,
    });

    const total_pieces = torrent.pieces.len / 20;

    while (try kq.next()) |event| {
        if (event.kind == .timer) switch (tg.unpack(event.ident)) {
            .tracker => {
                tracker.queueEventIfEmpty(.{
                    .info_hash = torrent.info_hash,
                    .peer_id = peer_id,
                    .left = torrent.total_len - pieces.downloaded,
                    .downloaded = pieces.downloaded,
                    .uploaded = 0,
                    .num_want = Tracker.NUM_WANT_DEFAULT,
                    .event = if (tracker.addrs.items.len == 0) .started else .none,
                });

                try tracker.startClient(alloc, io);
                try kq.subscribe(tracker.client.socket(), .write, tracker_tagged_pointer);
                try kq.subscribe(tracker.client.socket(), .read, tracker_tagged_pointer);
                try kq.disable(tracker.client.socket(), .read);

                try kq.addTimer(
                    tg.pack(.{ .tracker_client_timeout = &tracker.client }),
                    tracker.timeout(),
                    .{ .periodic = false },
                );

                continue;
            },
            .tracker_client_timeout => |client| {
                kq.killSocket(client.socket());

                tracker.useNextUrl(alloc) catch |err| switch (err) {
                    error.NoAnnounceUrlAvailable => {
                        std.log.info("all tracker urls are dead", .{});
                        return;
                    },
                };

                try kq.addTimer(tracker_tagged_pointer, 0, .{ .periodic = false });

                continue;
            },
            .ticker => |t| {
                std.mem.sortUnstable(*Peer, peers.items, {}, Peer.compareBytesReceived);

                t.onTick(peers.items, pieces);
                continue;
            },
            .peer => |peer| {
                if (peer.extended_map.pex) |pex_key| if (peer.state.isConnected()) blk: {
                    var pex = try peer.computePex(alloc, peers.items);
                    defer pex.deinit(alloc);

                    if (pex.added.items.len == 0 and pex.dropped.items.len == 0) {
                        break :blk;
                    }

                    const pex_message = try pex.exportMessage(alloc);
                    defer alloc.free(pex_message);

                    std.log.debug("peer: {d} ({f}) sending pex message, added {d}, dropped {d}", .{
                        peer.socket.fd,
                        peer.address,
                        pex.added.items.len,
                        pex.dropped.items.len,
                    });

                    const ready = peer.addMessage(.{
                        .extended = .{ .id = pex_key, .len = @intCast(pex_message.len) },
                    }, pex_message) catch {
                        peer.state = .dead;
                        continue;
                    };
                    if (!ready) try kq.enable(peer.socket.fd, .write, tg.pack(.{ .peer = peer }));
                };

                continue;
            },
            .pieces => unreachable,
        };

        const taggedPointer = tg.unpack(event.udata);
        switch (taggedPointer) {
            .ticker, .tracker_client_timeout => unreachable,
            .peer => {},
            .pieces => {
                var buf: [WORKER_MESSAGE_SIZE * 12]u8 = undefined;
                const count = try std.posix.read(read_pipe, &buf);

                utils.assert(@rem(count, WORKER_MESSAGE_SIZE) == 0);

                var r: std.Io.Reader = .fixed(buf[0..count]);
                while (r.peek(WORKER_MESSAGE_SIZE) catch null) |_| {
                    const peer_ident = r.takeInt(u32, .big) catch unreachable;
                    const peer_ptr = r.takeInt(usize, .big) catch unreachable;
                    const piece: *PieceManager.PieceBuf = @ptrFromInt(r.takeInt(usize, .big) catch unreachable);
                    defer pieces.consumePieceBuf(alloc, piece);

                    const piece_is_valid = piece.fetched != 0;
                    if (piece_is_valid) {
                        pieces.complete(piece);
                    } else {
                        pieces.reset(piece.index);
                    }

                    for (peers.items) |p| {
                        if (@intFromPtr(p) == peer_ptr and p.id == peer_ident) {
                            if (p.working_on) |*x| x.unset(piece.index);
                            if (!piece_is_valid) break;
                        }

                        if (piece_is_valid and p.state.isConnected()) {
                            const ready = p.addMessage(.{ .have = piece.index }, &.{}) catch {
                                p.state = .dead;
                                continue;
                            };
                            if (!ready) try kq.subscribe(p.socket.fd, .write, tg.pack(.{ .peer = p }));
                        }
                    }

                    if (!piece_is_valid) {
                        continue;
                    }

                    if (pieces.isDownloadComplete()) {
                        tracker.queueEventIfEmpty(.{
                            .info_hash = torrent.info_hash,
                            .peer_id = peer_id,
                            .left = torrent.total_len - pieces.downloaded,
                            .downloaded = pieces.downloaded,
                            .uploaded = 0,
                            .num_want = 0,
                            .event = .completed,
                        });

                        try tracker.startClient(alloc, io);
                        try kq.subscribe(tracker.client.socket(), .write, tracker_tagged_pointer);
                        try kq.subscribe(tracker.client.socket(), .read, tracker_tagged_pointer);
                        try kq.disable(tracker.client.socket(), .read);

                        var i = peers.items.len;
                        while (i > 0) {
                            i -= 1;
                            killPeer(alloc, peers.swapRemove(i), kq, pieces, &peer_allocator);
                        }

                        break;
                    }
                }

                continue;
            },
            .tracker => {
                // get socket **before** updating state, because `nextOperation` will deinit and
                // unset current client if next operation is last/finishing one
                const socket = tracker.client.socket();

                const nextOperation = tracker.nextOperation(alloc) catch |err| {
                    std.log.warn("failed announcing with {t}", .{err});

                    tracker.useNextUrl(alloc) catch |e| switch (e) {
                        error.NoAnnounceUrlAvailable => {
                            std.log.info("all tracker urls are dead", .{});
                            return;
                        },
                    };

                    try kq.addTimer(tracker_tagged_pointer, 0, .{ .periodic = false });

                    continue;
                };

                if (nextOperation) |x| switch (x) {
                    .read => {
                        try kq.disable(socket, .write);
                        try kq.enable(socket, .read, tracker_tagged_pointer);
                    },
                    .write => {
                        try kq.disable(socket, .read);
                        try kq.enable(socket, .write, tracker_tagged_pointer);
                    },
                    .timer => |timer| {
                        kq.killSocket(socket);

                        // closing socket will close "read/write"
                        // pipes, but we have our custom timer with "socket" id
                        try kq.deleteTimer(tg.pack(.{ .tracker_client_timeout = &tracker.client }));

                        if (pieces.isDownloadComplete()) {
                            std.log.info("successfully downloaded torrent.", .{});
                            return;
                        }

                        try kq.addTimer(tracker_tagged_pointer, timer, .{ .periodic = false });

                        try initializeNewPeers(alloc, &peer_allocator, &peers, &tracker, kq);
                    },
                };

                continue;
            },
        }

        const peer = taggedPointer.peer;
        if (event.err) |err| {
            peer.state = .dead;
            std.log.warn("peer: {d} received {t}", .{ peer.socket.fd, err });
        }

        if (event.kind == .write and !peer.state.isDead()) sw: switch (peer.state) {
            .readHandshake, .dead => unreachable,
            .writeHandshake => {
                const ready = peer.writeHandshake(&handshake) catch {
                    peer.state = .dead;
                    break :sw;
                };

                if (ready) {
                    peer.state = .readHandshake;
                    try kq.disable(peer.socket.fd, .write);
                    try kq.subscribe(peer.socket.fd, .read, event.udata);
                }
            },
            .messageStart, .message => {
                const ready = peer.send() catch {
                    peer.state = .dead;
                    break :sw;
                };

                if (ready) try kq.disable(peer.socket.fd, .write);
            },
        };

        if (event.kind == .read and !peer.state.isDead()) readblk: {
            peer.fillReadBuffer(alloc, Torrent.BLOCK_SIZE * 16) catch |err| switch (err) {
                error.EndOfStream => {
                    peer.state = .dead;
                    break :readblk;
                },
                else => |e| return e,
            } orelse {};

            while (peer.buf_read.writer.end > 0) switch (peer.state) {
                .writeHandshake, .dead => unreachable,
                .readHandshake => {
                    const bytes = peer.read(alloc, Handshake.HANDSHAKE_LEN) catch |err| switch (err) {
                        error.EndOfStream => {
                            peer.state = .dead;
                            break :readblk;
                        },
                        else => |e| return e,
                    } orelse break :readblk;
                    defer peer.consumeReadBuf(bytes);

                    const matched = handshake.matchExtensions(bytes) catch |err| {
                        std.log.err("peer: {d} bad handshake {s}", .{ peer.socket.fd, @errorName(err) });
                        peer.state = .dead;
                        break :readblk;
                    };

                    peer.state = .messageStart;
                    peer.protocols = matched;

                    if (matched.fast and pieces.downloaded == 0) {
                        const ready = peer.addMessage(.have_none, &.{}) catch {
                            peer.state = .dead;
                            break :readblk;
                        };
                        if (!ready) try kq.enable(peer.socket.fd, .write, event.udata);

                        std.log.debug("peer: {d} sent 'haveNone' message", .{peer.socket.fd});
                    } else {
                        const bitfield = try pieces.torrentBitfieldBytes(alloc);
                        defer alloc.free(bitfield);

                        const ready = peer.addMessage(.{ .bitfield = @intCast(bitfield.len) }, bitfield) catch {
                            peer.state = .dead;
                            break :readblk;
                        };
                        if (!ready) try kq.enable(peer.socket.fd, .write, event.udata);
                    }

                    if (matched.extended) {
                        std.log.debug("peer: {d} sending extended handshake message", .{peer.socket.fd});

                        var extended: Handshake.Extended = .{
                            .client_name = CLIENT_NAME,
                            .your_ip = utils.addressToYourIp(peer.address),
                            .map = .{
                                .pex = if (ENABLE_PEX) @intFromEnum(Handshake.Extended.Key.Pex) else null,
                                .donthave = @intFromEnum(Handshake.Extended.Key.Donthave),
                                .metadata = @intFromEnum(Handshake.Extended.Key.Metadata),
                            },
                        };

                        var buffer: [256]u8 = undefined;
                        var w: std.Io.Writer = .fixed(&buffer);

                        try extended.encode(alloc, &w);

                        const ready = peer.addMessage(.{
                            .extended = .{ .id = 0, .len = @intCast(w.buffered().len) },
                        }, w.buffered()) catch {
                            peer.state = .dead;
                            break :readblk;
                        };
                        if (!ready) try kq.subscribe(peer.socket.fd, .write, event.udata);
                    }
                },
                .messageStart => {
                    const res = peer.readMessageStart(alloc) catch |err| switch (err) {
                        error.EndOfStream, error.Dead, error.MessageTooBig => {
                            peer.state = .dead;
                            break :readblk;
                        },
                        else => |e| return e,
                    } orelse break :readblk;

                    switch (res) {
                        .keep_alive => {
                            const ready = try peer.fillRqPool(torrent, pieces);
                            if (!ready) try kq.enable(peer.socket.fd, .write, event.udata);
                        },
                        .message => |message| {
                            peer.state = .{ .message = message };
                        },
                    }
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
                        defer peer.consumeReadBuf(bytes);

                        peer.state = .messageStart;

                        const m_key = std.enums.fromInt(Handshake.Extended.Key, extended.id) orelse {
                            std.log.warn("peer: {d} received unrecognized extended message id {d}", .{ peer.socket.fd, extended.id });
                            continue;
                        };

                        switch (m_key) {
                            .Handshake => {
                                const e = Handshake.Extended.decode(alloc, bytes) catch continue; // `while` read loop
                                defer e.deinit(alloc);

                                if (e.req_queue) |req_queue| {
                                    peer.in_flight.resize(alloc, req_queue) catch {};
                                }

                                if (e.your_ip) |your_ip| {
                                    try tracker.voteForIp(alloc, your_ip, .peer);
                                }

                                peer.extended_map = e.map orelse continue;

                                std.log.debug("peer: {d}, extendedMap: {any}, metadata size: {?d}", .{ peer.socket.fd, peer.extended_map, e.metadata_size });

                                if (peer.extended_map.pex) |_| {
                                    try kq.addTimer(
                                        tg.pack(.{ .peer = peer }),
                                        Pex.TIMEOUT_DEFAULT,
                                        .{ .periodic = true },
                                    );

                                    std.log.debug("peer: {d}, enabled PEX", .{peer.socket.fd});
                                }
                            },
                            .Pex => {
                                if (peer.extended_map.pex) |_| {} else {
                                    peer.state = .dead;
                                    break :readblk;
                                }

                                var pex = Pex.parse(alloc, bytes) catch |err| {
                                    std.log.warn("peer: {d} received invalid pex message, error: {t}", .{ peer.socket.fd, err });
                                    continue;
                                };
                                defer pex.deinit(alloc);

                                var i: u8 = 0;
                                while (i < pex.added.items.len) : (i += 1) {
                                    if (i > Pex.ADDED_MAX_DEFAULT) break;
                                    try tracker.addNewAddr(alloc, pex.added.items[i].addr);
                                }

                                if (tracker.myIp()) |my_ip| tracker.sortNewAddrs(my_ip);

                                std.log.debug("peer: {d}, received PEX message, added {d}, dropped {d}", .{
                                    peer.socket.fd,
                                    pex.added.items.len,
                                    pex.dropped.items.len,
                                });

                                if (!pieces.isDownloadComplete()) {
                                    try initializeNewPeers(alloc, &peer_allocator, &peers, &tracker, kq);
                                }
                            },
                            .Donthave => {
                                if (bytes.len != 4) {
                                    std.log.warn("peer: {d} expected donthave message payload to be 4 bytes len, received: {d}", .{
                                        peer.socket.fd,
                                        bytes.len,
                                    });
                                    continue;
                                }

                                const piece = std.mem.readInt(u32, bytes[0..4], .big);
                                if (piece >= total_pieces) {
                                    std.log.warn("Peer sent invalid piece index: {d}", .{piece});
                                    peer.state = .dead;
                                    break :readblk;
                                }

                                if (peer.bitfield) |*x| x.unset(piece);
                                if (peer.working_on) |*x| x.unset(piece);

                                if (pieces.pieces[piece] == .downloading) {
                                    pieces.reset(piece);

                                    var i: u16 = @intCast(peer.in_flight.count);
                                    while (i > 0) {
                                        i -= 1;
                                        const req = peer.in_flight.buf[i];
                                        if (req.index == piece) peer.in_flight.receive(req) catch unreachable;
                                    }

                                    const ready = try peer.fillRqPool(torrent, pieces);
                                    if (!ready) try kq.subscribe(peer.socket.fd, .write, tg.pack(.{ .peer = peer }));
                                }
                            },
                            .Metadata => {
                                // TODO, we probably should be able to retrieve torrent info section
                                // and send it on `request`
                            },
                        }
                    },
                    .choke => {
                        peer.choked = true;
                        peer.state = .messageStart;
                    },
                    .unchoke => {
                        peer.choked = false;
                        peer.state = .messageStart;

                        const ready = try peer.fillRqPool(torrent, pieces);
                        if (!ready) try kq.enable(peer.socket.fd, .write, event.udata);

                        std.log.info("peer: {d}, received unchoke message, {d} in flight requests", .{ peer.socket.fd, peer.in_flight.count });
                    },
                    .have => |piece| {
                        peer.state = .messageStart;

                        var bitfield = peer.bitfield orelse {
                            std.log.err("unexpected empty bitfield with have message", .{});
                            continue;
                        };

                        bitfield.set(piece);

                        if (pieces.hasInterestingPiece(bitfield)) {
                            const ready = peer.addMessage(.interested, &.{}) catch {
                                peer.state = .dead;
                                break :readblk;
                            };
                            if (!ready) try kq.enable(peer.socket.fd, .write, event.udata);
                        }
                    },
                    .have_all => {
                        peer.state = .messageStart;

                        if (peer.bitfield != null) {
                            continue;
                        }

                        std.log.debug("peer: {d} receied 'haveAll' message", .{peer.socket.fd});

                        peer.bitfield = try .initFull(alloc, pieces.pieces.len);
                        peer.working_on = try .initEmpty(alloc, pieces.pieces.len);

                        if (pieces.hasInterestingPiece(peer.bitfield.?)) {
                            const ready = peer.addMessage(.interested, &.{}) catch {
                                peer.state = .dead;
                                break :readblk;
                            };
                            if (!ready) try kq.enable(peer.socket.fd, .write, event.udata);

                            std.log.debug("peer: {d} sent 'interested' message", .{peer.socket.fd});
                        }
                    },
                    .have_none => {
                        peer.state = .messageStart;

                        if (peer.bitfield != null) {
                            continue;
                        }

                        peer.bitfield = try .initEmpty(alloc, pieces.pieces.len);
                        peer.working_on = try .initEmpty(alloc, pieces.pieces.len);
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
                        defer peer.consumeReadBuf(bytes);

                        peer.state = .messageStart;

                        peer.bitfield = pieces.bytesToBitfield(alloc, bytes) catch |err| {
                            std.log.err("corruupt bitifield ?{t}", .{err});
                            peer.state = .dead;
                            break :readblk;
                        };
                        peer.working_on = try .initEmpty(alloc, pieces.pieces.len);

                        if (pieces.hasInterestingPiece(peer.bitfield.?)) {
                            const ready = peer.addMessage(.interested, &.{}) catch {
                                peer.state = .dead;
                                break :readblk;
                            };
                            if (!ready) try kq.enable(peer.socket.fd, .write, event.udata);
                        }
                    },
                    .allowed_fast => |allowed_fast| blk: {
                        peer.state = .messageStart;

                        if (allowed_fast >= pieces.pieces.len) {
                            peer.state = .dead;
                            break :readblk;
                        }

                        for (peer.allowed_fast.items) |existing| {
                            if (existing == allowed_fast) break :blk;
                        }

                        peer.allowed_fast.appendBounded(allowed_fast) catch continue;

                        const ready = try peer.fillRqPool(torrent, pieces);
                        if (!ready) try kq.enable(peer.socket.fd, .write, event.udata);
                    },
                    .suggest_piece => |index| {
                        peer.state = .messageStart;
                        std.log.debug("peer: {d} received 'suggestPiece' for {d}", .{ peer.socket.fd, index });
                    },
                    .reject_request => |piece| {
                        peer.state = .messageStart;
                        if (pieces.pieces[piece.index] == .missing) {
                            continue;
                        }

                        peer.in_flight.receive(.{
                            .index = piece.index,
                            .begin = piece.begin,
                        }) catch {};

                        pieces.reset(piece.index);
                        if (peer.working_on) |*working_on| working_on.unset(piece.index);

                        if (peer.working_piece) |x| if (x == piece.index) {
                            peer.working_piece = null;
                            peer.working_piece_offset = 0;
                        };

                        const ready = try peer.fillRqPool(torrent, pieces);
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
                        defer peer.consumeReadBuf(chunkBytes);

                        peer.state = .messageStart;
                        peer.bytes_received +|= chunkBytes.len;

                        if (piece.index > total_pieces) {
                            @branchHint(.unlikely);
                            std.log.err("peer {d} sent unknown piece message: {d}", .{
                                peer.socket.fd,
                                piece.index,
                            });
                            peer.state = .dead;
                            break :readblk;
                        }

                        peer.in_flight.receive(.{ .index = piece.index, .begin = piece.begin }) catch {};

                        const ready = try peer.fillRqPool(torrent, pieces);
                        if (!ready) try kq.enable(peer.socket.fd, .write, event.udata);

                        const pieceLen = torrent.getPieceSize(piece.index);
                        const fullPiece = try pieces.writePiece(alloc, piece, pieceLen, chunkBytes) orelse continue;

                        write_group.async(io, hashAndWrite, .{
                            io,
                            write_pipe,
                            peer,
                            peer.id,
                            fullPiece,
                            torrent,
                            files,
                        });
                    },
                    .interested => {
                        peer.is_interested = true;
                        peer.state = .messageStart;
                        std.log.info("peer: {d} is interested", .{peer.socket.fd});
                    },
                    .not_interested => {
                        peer.is_interested = false;
                        peer.state = .messageStart;
                        std.log.info("peer: {d} is not interested", .{peer.socket.fd});
                    },
                    .request => |request| {
                        peer.state = .messageStart;

                        if (peer.bytes_sent > peer.bytes_received or !peer.is_interested or !peer.is_unchoked) {
                            continue;
                        }

                        if (request.index > total_pieces or request.len > Torrent.BLOCK_SIZE) {
                            @branchHint(.unlikely);
                            std.log.err("peer: {d} sent invalid request message: {any}", .{
                                peer.socket.fd,
                                request,
                            });
                            peer.state = .dead;
                            break :readblk;
                        }

                        std.log.info("peer: {d} sending {any}", .{ peer.socket.fd, request });
                        const data = try files.readPieceData(alloc, io, request, torrent.piece_len);
                        defer alloc.free(data);

                        peer.bytes_sent +|= data.len;

                        const ready = peer.addMessage(.{ .piece = request }, data) catch {
                            peer.state = .dead;
                            break :readblk;
                        };
                        if (!ready) try kq.enable(peer.socket.fd, .write, event.udata);
                    },
                    .cancel,
                    .port,
                    => {
                        peer.state = .messageStart;
                    },
                },
            };
        }

        if (peer.state.isDead()) {
            if (peer.extended_map.pex) |_| {
                try kq.deleteTimer(tg.pack(.{ .peer = peer }));
            }

            for (peers.items, 0..) |other_peer, i| {
                if (other_peer == peer) {
                    killPeer(alloc, peers.swapRemove(i), kq, pieces, &peer_allocator);
                    break;
                }
            } else unreachable;

            if (!pieces.isDownloadComplete()) {
                try initializeNewPeers(alloc, &peer_allocator, &peers, &tracker, kq);
            }
        }
    }
}

fn killPeer(
    alloc: std.mem.Allocator,
    peer: *Peer,
    kq: *KQ,
    pieces: *PieceManager,
    peer_allocator: *PeerAllocator,
) void {
    kq.killSocket(peer.socket.fd);
    pieces.killPeer(peer.working_on);
    peer.deinit(alloc);
    peer_allocator.destroy(peer);
}

fn initializeNewPeers(
    alloc: std.mem.Allocator,
    peer_allocator: *PeerAllocator,
    peers: *PeerPtrs,
    tracker: *Tracker,
    kq: *KQ,
) !void {
    if (peers.items.len == peers.capacity) return;

    // don't waste returned addr, because it's already moved to `oldAddrs`
    while (tracker.nextNewPeer()) |addr| {
        const peer = peer_allocator.create(alloc) catch unreachable;
        errdefer peer_allocator.destroy(peer);

        peer.initPtr(alloc, addr) catch |err| {
            std.log.err("failed connecting with {t}", .{err});
            peer_allocator.destroy(peer);
            continue;
        };
        errdefer peer.deinit(alloc);

        try kq.subscribe(peer.socket.fd, .write, tg.pack(.{ .peer = peer }));
        errdefer kq.killSocket(peer.socket.fd);

        peers.appendAssumeCapacity(peer);

        if (peers.items.len == peers.capacity) return;
    }

    const addrs_new_count = tracker.addrs.items.len - tracker.addr_current;
    if (peers.items.len == 0 and addrs_new_count == 0) {
        std.log.info("no pending or alive peers left", .{});
        return error.DeadTorrent;
    }
}

fn hashAndWrite(
    io: std.Io,
    writeFd: std.posix.socket_t,
    peer_ptr: *const Peer,
    peer_id: u32,
    piece: *PieceManager.PieceBuf,
    torrent: *const Torrent,
    files: *const Files,
) void {
    var pipeBytes: [WORKER_MESSAGE_SIZE]u8 = undefined;
    var w: std.Io.Writer = .fixed(&pipeBytes);

    w.writeInt(u32, peer_id, .big) catch unreachable;
    w.writeInt(usize, @intFromPtr(peer_ptr), .big) catch unreachable;
    w.writeInt(usize, @intFromPtr(piece), .big) catch unreachable;

    const expectedHash = torrent.pieces[piece.index * 20 ..];
    var computedHash: [20]u8 = undefined;

    std.crypto.hash.Sha1.hash(piece.written(), &computedHash, .{});

    if (std.mem.eql(u8, computedHash[0..20], expectedHash[0..20])) {
        files.writePieceData(io, piece.index, torrent.piece_len, piece.written()) catch |err| {
            @branchHint(.unlikely);

            std.log.warn("piece: {d} failed writing with {t}", .{ piece.index, err });

            // mark as errored
            piece.fetched = 0;
        };
    } else {
        @branchHint(.unlikely);

        std.log.warn("piece: {d} corrupt from peer {d}", .{ piece.index, peer_ptr.socket.fd });

        // mark as errored
        piece.fetched = 0;
    }

    const wrote: u8 = blk: {
        const rc = std.posix.system.write(writeFd, &pipeBytes, pipeBytes.len);
        break :blk switch (std.posix.errno(rc)) {
            .SUCCESS => @intCast(rc),
            else => |e| {
                const err = std.posix.unexpectedErrno(e);
                std.log.err("failed writing to thread pipe with {t}", .{err});
                @panic("failed writing to thread pipe");
            },
        };
    };

    utils.assert(wrote == pipeBytes.len);
}

const DownloadMagnetContext = struct {
    alloc: std.mem.Allocator,
    io: std.Io,
    loop: *KQ,
};

pub fn downloadMagnet(
    ctx: DownloadMagnetContext,
    peer_id: [20]u8,
    magnet: *Magnet,
) !void {
    const alloc = ctx.alloc;
    const io = ctx.io;
    const kq = ctx.loop;

    var tracker: Tracker = try .fromMagnet(alloc, io, magnet);
    defer tracker.deinit(alloc);
    const tracker_tagged_pointer = tg.pack(.{ .tracker = &tracker });

    var peer_allocator: PeerAllocator = try .initCapacity(alloc, PEERS_MAX);
    defer peer_allocator.deinit(alloc);

    var peers: PeerPtrs = try .initCapacity(alloc, PEERS_MAX);
    defer {
        for (peers.items) |peer| {
            kq.killSocket(peer.socket.fd);
            peer.deinit(alloc);
        }
        peers.deinit(alloc);
    }

    if (magnet.peers.items.len == 0) {
        try kq.addTimer(tracker_tagged_pointer, 0, .{ .periodic = false });
    } else {
        for (magnet.peers.items, 0..) |addr, i| {
            if (i == PEERS_MAX) break;

            const peer = peer_allocator.create(alloc) catch unreachable;
            errdefer peer_allocator.destroy(peer);

            peer.initPtr(alloc, addr) catch |err| {
                std.log.err("failed connecting with {t}", .{err});
                peer_allocator.destroy(peer);
                continue;
            };

            try kq.subscribe(peer.socket.fd, .write, tg.pack(.{ .peer = peer }));
            errdefer kq.killSocket(kq);

            peers.appendAssumeCapacity(peer);

            if (i == peers.capacity) break;
        }
    }

    const handshake = Handshake.init(peer_id, magnet.info_hash, .{ .extended = true });

    while (try kq.next()) |ev| {
        if (ev.kind == .timer) switch (tg.unpack(ev.ident)) {
            .tracker => {
                tracker.queueEventIfEmpty(.{
                    .info_hash = magnet.info_hash,
                    .peer_id = peer_id,
                    .left = 1,
                    .downloaded = 1,
                    .uploaded = 0,
                    .num_want = Tracker.NUM_WANT_DEFAULT,
                    .event = .started,
                });

                try tracker.startClient(alloc, io);
                try kq.subscribe(tracker.client.socket(), .write, tracker_tagged_pointer);
                try kq.subscribe(tracker.client.socket(), .read, tracker_tagged_pointer);
                try kq.disable(tracker.client.socket(), .read);

                try kq.addTimer(
                    tg.pack(.{ .tracker_client_timeout = &tracker.client }),
                    tracker.timeout(),
                    .{ .periodic = false },
                );

                continue;
            },
            .tracker_client_timeout => |client| {
                std.log.info("reached timeout for tracker, trying next one...", .{});

                kq.killSocket(client.socket());
                client.deinit(alloc);

                tracker.useNextUrl(alloc) catch |err| switch (err) {
                    error.NoAnnounceUrlAvailable => {
                        std.log.info("all tracker urls are dead", .{});
                        return error.Dead;
                    },
                };

                try kq.addTimer(tracker_tagged_pointer, 0, .{ .periodic = false });

                continue;
            },
            else => unreachable,
        };

        const tagged_pointer = tg.unpack(ev.udata);
        switch (tagged_pointer) {
            .tracker => {
                // get socket **before** updating state, because `nextOperation` will deinit and
                // unset current client if next operation is last/finishing one
                const socket = tracker.client.socket();

                const nextOperation = tracker.nextOperation(alloc) catch |err| {
                    std.log.warn("failed announcing with {t}", .{err});

                    tracker.useNextUrl(alloc) catch |e| switch (e) {
                        error.NoAnnounceUrlAvailable => {
                            std.log.info("all tracker urls are dead", .{});
                            return error.Dead;
                        },
                    };

                    try kq.addTimer(tracker_tagged_pointer, 0, .{ .periodic = false });

                    continue;
                };

                if (nextOperation) |x| switch (x) {
                    .read => {
                        try kq.disable(socket, .write);
                        try kq.enable(socket, .read, tracker_tagged_pointer);
                    },
                    .write => {
                        try kq.disable(socket, .read);
                        try kq.enable(socket, .write, tracker_tagged_pointer);
                    },
                    .timer => {
                        kq.killSocket(socket);

                        // closing socket will close "read/write"
                        // pipes, but we have our custom timer with "socket" id
                        try kq.deleteTimer(tg.pack(.{ .tracker_client_timeout = &tracker.client }));

                        try initializeNewPeers(alloc, &peer_allocator, &peers, &tracker, kq);
                    },
                };

                continue;
            },
            .peer => {},
            else => unreachable,
        }

        const peer = tagged_pointer.peer;
        if (ev.err) |err| {
            peer.state = .dead;
            std.log.err("peer: {d} received {t}", .{ peer.socket.fd, err });
        }

        if (ev.kind == .write and !peer.state.isDead()) sw: switch (peer.state) {
            .dead, .readHandshake => unreachable,
            .message, .messageStart => {
                const ready = peer.send() catch {
                    peer.state = .dead;
                    break :sw;
                };

                if (ready) try kq.disable(peer.socket.fd, .write);
            },
            .writeHandshake => {
                const ready = peer.writeHandshake(&handshake) catch {
                    peer.state = .dead;
                    break :sw;
                };

                if (ready) {
                    peer.state = .readHandshake;
                    try kq.disable(peer.socket.fd, .write);
                    try kq.subscribe(peer.socket.fd, .read, ev.udata);
                }
            },
        };

        if (ev.kind == .read and !peer.state.isDead()) readblk: {
            peer.fillReadBuffer(alloc, Torrent.BLOCK_SIZE * 8) catch |err| switch (err) {
                error.EndOfStream => {
                    peer.state = .dead;
                    break :readblk;
                },
                else => |e| return e,
            } orelse {};

            while (peer.buf_read.writer.end > 0) switch (peer.state) {
                .dead, .writeHandshake => unreachable,
                .readHandshake => {
                    const bytes = peer.read(alloc, Handshake.HANDSHAKE_LEN) catch |err| switch (err) {
                        error.EndOfStream => {
                            peer.state = .dead;
                            break :readblk;
                        },
                        else => |e| return e,
                    } orelse break :readblk;
                    defer peer.consumeReadBuf(bytes);

                    const matched = handshake.matchExtensions(bytes) catch |err| {
                        std.log.err("peer: {d} bad handshake {s}", .{ peer.socket.fd, @errorName(err) });
                        peer.state = .dead;
                        break :readblk;
                    };

                    peer.state = .messageStart;
                    peer.protocols = matched;

                    if (!matched.extended) {
                        peer.state = .dead;
                        break :readblk;
                    }

                    std.log.debug("peer: {d} sending extended handshake message", .{peer.socket.fd});

                    var extended: Handshake.Extended = .{
                        .client_name = CLIENT_NAME,
                        .your_ip = utils.addressToYourIp(peer.address),
                        .map = .{ .metadata = @intFromEnum(Handshake.Extended.Key.Metadata) },
                    };

                    var buffer: [256]u8 = undefined;
                    var w: std.Io.Writer = .fixed(&buffer);

                    try extended.encode(alloc, &w);

                    const ready = peer.addMessage(.{
                        .extended = .{ .id = 0, .len = @intCast(w.buffered().len) },
                    }, w.buffered()) catch {
                        peer.state = .dead;
                        break :readblk;
                    };
                    if (!ready) try kq.subscribe(peer.socket.fd, .write, ev.udata);
                },
                .messageStart => {
                    const res = peer.readMessageStart(alloc) catch |err| switch (err) {
                        error.EndOfStream, error.Dead, error.MessageTooBig => {
                            peer.state = .dead;
                            break :readblk;
                        },
                        else => |e| return e,
                    } orelse break :readblk;

                    switch (res) {
                        .keep_alive => {},
                        .message => |message| {
                            peer.state = .{ .message = message };
                        },
                    }
                },
                .message => |message| switch (message) {
                    else => |msg| {
                        peer.state = .messageStart;
                        std.log.debug("peer: {d} received {t}", .{ peer.socket.fd, msg });
                    },
                    .bitfield => |len| {
                        const bytes = peer.read(alloc, len) catch |err| switch (err) {
                            error.EndOfStream => {
                                peer.state = .dead;
                                break :readblk;
                            },
                            else => |e| return e,
                        } orelse break :readblk;
                        defer peer.consumeReadBuf(bytes);

                        std.log.debug("peer: {d} received bitfield", .{peer.socket.fd});
                        peer.state = .messageStart;
                    },
                    .piece => |piece| {
                        const bytes = peer.read(alloc, piece.len) catch |err| switch (err) {
                            error.EndOfStream => {
                                peer.state = .dead;
                                break :readblk;
                            },
                            else => |e| return e,
                        } orelse break :readblk;
                        defer peer.consumeReadBuf(bytes);
                        std.log.debug("peer: {d} received piece", .{peer.socket.fd});
                    },
                    .extended => |extended| {
                        const bytes = peer.read(alloc, extended.len) catch |err| switch (err) {
                            error.EndOfStream => {
                                peer.state = .dead;
                                break :readblk;
                            },
                            else => |e| return e,
                        } orelse break :readblk;
                        defer peer.consumeReadBuf(bytes);

                        peer.state = .messageStart;

                        const id = std.enums.fromInt(Handshake.Extended.Key, extended.id) orelse {
                            std.log.warn("peer: {d} received unrecognized extended message id {d}", .{ peer.socket.fd, extended.id });
                            continue;
                        };

                        switch (id) {
                            .Handshake => {
                                const e = Handshake.Extended.decode(alloc, bytes) catch continue; // `while` read loop
                                defer e.deinit(alloc);

                                std.log.debug("peer: {d}, client name: {?s}, e: {?any}", .{ peer.socket.fd, e.client_name, e.map });

                                peer.extended_map = e.map orelse {
                                    peer.state = .dead;
                                    break :readblk;
                                };

                                if (e.metadata_size == null) {
                                    peer.state = .dead;
                                    break :readblk;
                                }

                                if (peer.extended_map.metadata) |metadata_id| {
                                    try magnet.writeInfoTableRequests(alloc, metadata_id, e.metadata_size.?, &peer.buf_write.writer);

                                    const ready = try peer.send();
                                    if (!ready) try kq.subscribe(peer.socket.fd, .write, ev.udata);

                                    std.log.debug("peer: {d} wrote metadata requests for metadata (id: {d}, size: {d})", .{
                                        peer.socket.fd,
                                        metadata_id,
                                        e.metadata_size.?,
                                    });
                                } else {
                                    peer.state = .dead;
                                    break :readblk;
                                }
                            },
                            .Metadata => {
                                std.log.debug("peer: {d} received metadata message {d}", .{ peer.socket.fd, bytes.len });

                                try magnet.receivePiece(alloc, bytes);

                                if (magnet.isComplete()) {
                                    if (magnet.isValid()) {
                                        return;
                                    } else return error.MagnetNotValid;
                                }
                            },
                            else => {},
                        }
                    },
                },
            };
        }

        if (peer.state.isDead()) {
            kq.killSocket(peer.socket.fd);
            peer.deinit(alloc);
            peer_allocator.destroy(peer);

            for (peers.items, 0..) |other_peer, i| {
                if (other_peer == peer) {
                    _ = peers.swapRemove(i);
                    break;
                }
            }

            const addrs_new_count = tracker.addrs.items.len - tracker.addr_current;
            if (peers.items.len == 0 and addrs_new_count == 0) {
                try kq.addTimer(tracker_tagged_pointer, 0, .{ .periodic = false });
            } else {
                try initializeNewPeers(alloc, &peer_allocator, &peers, &tracker, kq);
            }
        }
    }
}

test {
    std.testing.refAllDecls(@This());
}
