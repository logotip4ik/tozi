const std = @import("std");

const Torrent = @import("torrent.zig");
const PieceManager = @import("piece-manager.zig");
const Files = @import("files.zig");
const KQ = @import("kq.zig");
const proto = @import("proto.zig");
const utils = @import("utils.zig");

const Peer = struct {
    socket: std.posix.fd_t,

    state: State = .handshake,
    direction: KQ.Op = .write,

    choked: bool = true,
    interested: bool = false,

    buf: std.array_list.Aligned(u8, null) = .empty,

    bitfield: ?std.DynamicBitSetUnmanaged = null,

    pub const State = union(enum) {
        handshake,
        messageStart,
        message: proto.Message,
        bufFlush,
        dead,
    };

    pub fn init(addr: std.net.Address) !Peer {
        const fd = try std.posix.socket(
            std.posix.AF.INET,
            std.posix.SOCK.STREAM | std.posix.SOCK.NONBLOCK,
            std.posix.IPPROTO.TCP,
        );
        errdefer std.posix.close(fd);

        std.debug.print("connecting to {f}\n", .{addr});

        std.posix.connect(@intCast(fd), &addr.any, addr.getOsSockLen()) catch |err| switch (err) {
            error.WouldBlock => {},
            else => return err,
        };

        return .{ .socket = fd };
    }

    pub fn deinit(self: *Peer, alloc: std.mem.Allocator, k: *KQ) void {
        if (self.state == .dead) {
            return;
        }

        self.state = .dead;

        k.unsubscribe(self.socket, .read) catch |err| {
            std.log.debug("received err while unsubscribing from read for socket {d} with {s}\n", .{
                self.socket,
                @errorName(err),
            });
        };
        k.unsubscribe(self.socket, .write) catch |err| switch (err) {
            error.EventNotFound => {}, // already unsubscribed
            else => {
                std.log.debug("received err while unsubscribing from write for socket {d} with {s}\n", .{
                    self.socket,
                    @errorName(err),
                });
            },
        };

        std.posix.close(self.socket);
        self.buf.deinit(alloc);
        if (self.bitfield) |*x| x.deinit(alloc);
    }

    pub fn setBitfield(self: *Peer, alloc: std.mem.Allocator, bytes: []const u8) !void {
        var bitfield: std.DynamicBitSetUnmanaged = try .initEmpty(alloc, bytes.len * 8);
        defer self.bitfield = bitfield;

        for (bytes, 0..) |byte, i| {
            for (0..8) |bit_idx| {
                // Check if bit is set (MSB first), thank you gemini, but i don't get what this does
                const is_set = (byte >> @intCast(7 - bit_idx)) & 1 != 0;

                // Calculate absolute piece index
                const piece_index = (i * 8) + bit_idx;

                if (piece_index < bitfield.capacity() and is_set) {
                    bitfield.set(piece_index);
                }
            }
        }
    }

    pub fn readInt(self: *Peer, comptime T: type, endian: std.builtin.Endian) !T {
        const n = @divExact(@typeInfo(T).int.bits, 8);
        var buf: [n]u8 = undefined;

        var total: usize = 0;
        while (total != n) {
            const count = std.posix.read(self.socket, buf[total..n]) catch |err| switch (err) {
                error.WouldBlock => 0,
                else => return err,
            };

            total += count;
        }

        return std.mem.readInt(T, &buf, endian);
    }

    pub fn readTotalBuf(self: *Peer, alloc: std.mem.Allocator, size: usize) !?[]u8 {
        if (self.buf.items.len >= size) {
            return self.buf.items[0..size];
        }

        try self.buf.ensureTotalCapacity(alloc, size);

        const slice = self.buf.allocatedSlice();
        const len = self.buf.items.len;
        const count = try std.posix.read(self.socket, slice[len..size]);

        self.buf.items.len += count;

        if (self.buf.items.len >= size) {
            return self.buf.items[0..size];
        }

        return null;
    }

    pub fn writeTotalBuf(self: *Peer, alloc: std.mem.Allocator, slice: []const u8) !?usize {
        if (self.buf.items.len == slice.len) {
            return slice.len;
        }

        try self.buf.ensureTotalCapacity(alloc, slice.len);

        const len = self.buf.items.len;
        const wrote = try std.posix.write(self.socket, slice[len..]);
        try self.buf.appendSlice(alloc, slice[len .. len + wrote]);

        if (wrote == slice.len) {
            return wrote;
        }

        return null;
    }

    /// returns null when there is still data pending to be written
    pub fn writeBuf(self: *Peer) !?void {
        if (self.buf.items.len == 0) {
            return;
        }

        const wrote = try std.posix.write(self.socket, self.buf.items);

        const left = self.buf.items.len - wrote;
        if (left == 0) {
            return;
        }

        @memmove(self.buf.items[0..left], self.buf.items[wrote .. wrote + left]);
        self.buf.items.len = left;

        return null;
    }
};

pub fn loop(
    alloc: std.mem.Allocator,
    peerId: [20]u8,
    torrent: *Torrent,
    files: *Files,
    pieceManager: *PieceManager,
    addrs: []const std.net.Address,
) !void {
    var kq: KQ = try .init(alloc);
    defer kq.deinit();

    var peers = try alloc.alloc(Peer, addrs.len);
    defer {
        for (peers) |*peer| peer.deinit(alloc, &kq);
        alloc.free(peers);
    }

    for (addrs, 0..) |addr, i| {
        const peer = &peers[i];

        peer.* = try .init(addr);

        std.debug.print("{*}\n", .{peer});

        try kq.subscribe(peer.socket, .read, @intFromPtr(peer));
        try kq.subscribe(peer.socket, .write, @intFromPtr(peer));
    }

    var deadCount: usize = 0;

    const handshake: proto.TcpHandshake = .{ .infoHash = torrent.infoHash, .peerId = peerId };
    const handshakeBytes = std.mem.asBytes(&handshake);

    while (try kq.next()) |event| {
        const peer: *Peer = @ptrFromInt(event.kevent.udata);

        if (event.err) |err| {
            std.log.err("enountered {s} for dead {any}", .{ @tagName(err), peer });
            peer.deinit(alloc, &kq);
            deadCount += 1;

            if (deadCount == peers.len) {
                return error.AllStreamsDead;
            }
        }

        switch (event.op) {
            .write => if (peer.direction == .write) switch (peer.state) {
                .dead => {},
                .handshake => {
                    std.log.debug("sent handshake to socket {d}", .{peer.socket});
                    _ = try peer.writeTotalBuf(alloc, handshakeBytes) orelse continue;

                    peer.state = .handshake;
                    peer.direction = .read;
                    peer.buf.clearRetainingCapacity();

                    try kq.unsubscribe(peer.socket, .write);
                },
                .bufFlush => {
                    if (peer.buf.items.len == 0) continue;
                    try peer.writeBuf() orelse continue;
                    std.log.debug("wrote whole buffer", .{});

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
                    peer.deinit(alloc, &kq);
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
                        std.log.err("received invalid handshake err {s}", .{@errorName(err)});
                        continue :sw .dead;
                    };

                    peer.state = .messageStart;
                    std.log.debug("received valid TcpHandshake for socket {d}", .{peer.socket});
                },
                .messageStart => {
                    const len = try peer.readInt(u32, .big);
                    if (len == 0) {
                        // keep alive, send requests ?
                        continue;
                    }

                    if (len > 16 * 1024 * 1024) {
                        std.log.err("received too large message {d}, dropping peer {d}", .{
                            len,
                            peer.socket,
                        });
                        continue :sw .dead;
                    }

                    const idInt = try peer.readInt(u8, .big);
                    const id = std.enums.fromInt(proto.MessageId, idInt) orelse {
                        std.log.debug("enountered unknown message id: {d}\n", .{idInt});
                        continue;
                    };

                    std.log.debug("read message start ({s}, len: {d})", .{
                        @tagName(id),
                        len,
                    });

                    const message: proto.Message = switch (id) {
                        .choke => .choke,
                        .unchoke => .unchoke,
                        .interested => .interested,
                        .not_interested => .not_interested,
                        .have => .{ .have = try peer.readInt(u32, .big) },
                        .bitfield => .{ .bitfield = len - 1 },
                        .request => .{ .request = .{
                            .index = try peer.readInt(u32, .big),
                            .begin = try peer.readInt(u32, .big),
                            .len = len - 9,
                        } },
                        .piece => .{ .piece = .{
                            .index = try peer.readInt(u32, .big),
                            .begin = try peer.readInt(u32, .big),
                            .len = len - 9,
                        } },
                        .cancel => .{ .cancel = .{
                            .index = try peer.readInt(u32, .big),
                            .begin = try peer.readInt(u32, .big),
                            .len = len - 9,
                        } },
                        .port => .{ .port = try peer.readInt(u16, .big) },
                    };

                    peer.state = .{ .message = message };
                    peer.buf.clearRetainingCapacity();
                },
                .message => |message| {
                    std.log.debug("received message: {s}", .{@tagName(message)});

                    switch (message) {
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
                            const numberOfPieces = torrent.pieces.len / 20;
                            const requestsPerPeer = try std.math.divCeil(usize, numberOfPieces, peers.len);
                            const numberOfPiecesToRequest = @min(requestsPerPeer, 12);

                            peer.buf.clearRetainingCapacity();
                            var writer: std.Io.Writer.Allocating = .fromArrayList(alloc, &peer.buf);
                            defer peer.buf = writer.toArrayList();

                            for (0..numberOfPiecesToRequest) |_| {
                                const index = pieceManager.getWorkingPiece(bitfield) orelse break;
                                const pieceLen = torrent.getPieceSize(index);
                                try proto.writeRequestsBatch(&writer.writer, index, pieceLen);
                            }

                            std.log.debug("trying to send requests", .{});

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

                            for (bytes) |byte| {
                                std.log.debug("received bitfield {b}", .{byte});
                            }
                            try peer.setBitfield(alloc, bytes);

                            // TODO: actually check if peer has interesting pieces
                            std.log.debug("peer {d} has interesting pieces", .{peer.socket});

                            peer.buf.clearRetainingCapacity();

                            var writer: std.Io.Writer.Allocating = .fromArrayList(alloc, &peer.buf);
                            defer peer.buf = writer.toArrayList();

                            const interested: proto.Message = .interested;
                            try interested.writeMessage(&writer.writer);

                            peer.state = .bufFlush;
                            peer.direction = .write;

                            std.log.debug("trying to send interested message", .{});

                            try kq.subscribe(peer.socket, .write, event.kevent.udata);
                        },
                        .piece => |piece| {
                            const bytes = try peer.readTotalBuf(alloc, piece.len) orelse continue;

                            const numberOfPieces = torrent.pieces.len / 20;
                            if (piece.index > numberOfPieces) {
                                std.log.err("peer {d} sen't unknown piece massage: {d}", .{
                                    peer.socket,
                                    piece.index,
                                });
                                continue :sw .dead;
                            }

                            std.log.debug("received piece {any}", .{piece});

                            const pieceLen = torrent.getPieceSize(piece.index);
                            const completed = try pieceManager.writePiece(alloc, piece, pieceLen, bytes) orelse {
                                peer.state = .messageStart;
                                continue;
                            };
                            defer completed.deinit(alloc);

                            const expectedHash = torrent.pieces[piece.index * 20 ..];
                            pieceManager.verifyPiece(piece.index, bytes, expectedHash[0..20]) catch {
                                std.log.warn("received corrupt piece from peer: {d}", .{peer.socket});
                                peer.state = .messageStart;
                                continue;
                            };

                            try files.writePiece(piece.index, bytes);

                            std.log.info("fetched {d} piece", .{pieceLen});

                            const bitfield = peer.bitfield orelse {
                                std.log.err("unexpected empty bitfield with piece message", .{});
                                peer.state = .messageStart;
                                pieceManager.reset(piece.index);
                                continue;
                            };

                            if (pieceManager.getWorkingPiece(bitfield)) |nextWorkingPiece| {
                                if (peer.choked) {
                                    peer.state = .messageStart;
                                    continue;
                                }

                                peer.buf.clearRetainingCapacity();

                                const nextPieceLen = torrent.getPieceSize(nextWorkingPiece);

                                var writer: std.Io.Writer.Allocating = .fromArrayList(alloc, &peer.buf);
                                defer peer.buf = writer.toArrayList();

                                try proto.writeRequestsBatch(&writer.writer, nextWorkingPiece, nextPieceLen);

                                peer.state = .bufFlush;
                                peer.direction = .write;

                                std.log.info("writing requests batch for {d}, len {d}", .{
                                    nextWorkingPiece,
                                    nextPieceLen,
                                });

                                try kq.subscribe(peer.socket, .write, event.kevent.udata);
                            } else if (pieceManager.isDownloadComplete()) {
                                std.log.info("download complete.", .{});
                                return;
                            } else {
                                std.log.info("no work for peer {d}", .{peer.socket});
                                peer.state = .messageStart;
                                continue;
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
                    }
                },
                else => unreachable,
            },
        }
    }
}
