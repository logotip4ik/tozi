const std = @import("std");

const Torrent = @import("torrent.zig");
const PieceManager = @import("piece-manager.zig");
const KQ = @import("kq.zig");
const proto = @import("proto.zig");
const utils = @import("utils.zig");

const TCP_HANDSHAKE_LEN = 68;
const TcpHandshake = extern struct {
    pstrlen: u8 = 19,
    pstr: [19]u8 = "BitTorrent protocol".*,
    reserved: [8]u8 = [_]u8{0} ** 8,
    infoHash: [20]u8,
    peerId: [20]u8,

    const ValidateError = error{ InvalidPstrLen, InvalidPstr, InvalidInfoHash };

    pub fn validate(self: TcpHandshake, other: TcpHandshake) ValidateError!void {
        if (self.pstrlen != other.pstrlen) {
            return error.InvalidPstrLen;
        }

        if (!std.mem.eql(u8, &self.pstr, &other.pstr)) {
            return error.InvalidPstr;
        }

        if (!std.mem.eql(u8, &self.infoHash, &other.infoHash)) {
            return error.InvalidInfoHash;
        }
    }
};

comptime {
    if (@sizeOf(TcpHandshake) != TCP_HANDSHAKE_LEN) @compileError("TcpHandshake has invalid size");
}

const Socket = struct {
    pub fn close(self: *Socket) void {
        if (self.state != .dead) {
            std.posix.close(self.fd);
        }

        self.state = .dead;
    }
};

const Peer = struct {
    socket: std.posix.fd_t,

    state: State = .handshake,
    direction: KQ.Op = .write,

    choked: bool = true,
    interested: bool = false,
    workingPiece: ?u32 = null,

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

    const handshake = TcpHandshake{ .infoHash = torrent.infoHash, .peerId = peerId };
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
                    const bytes = try peer.readTotalBuf(alloc, TCP_HANDSHAKE_LEN) orelse continue;

                    defer peer.buf.clearRetainingCapacity();
                    const received: *TcpHandshake = @ptrCast(bytes);

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
                            defer peer.state = .messageStart;
                            peer.choked = true;
                        },
                        .unchoke => {
                            peer.choked = false;

                            peer.buf.clearRetainingCapacity();

                            const workingPiece = peer.workingPiece orelse {
                                std.log.err("unexpected emtpy working piece when unchoking", .{});
                                continue;
                            };

                            const pieceLen = torrent.getPieceSize(workingPiece);
                            const numberOfRequests = try std.math.divCeil(u32, pieceLen, Torrent.BLOCK_SIZE);
                            var request: proto.Message = .{ .request = .{ .index = workingPiece, .begin = 0, .len = 0 } };

                            try peer.buf.resize(alloc, request.wireLen() * numberOfRequests);

                            for (0..numberOfRequests) |i| {
                                const begin: u32 = @intCast(i * Torrent.BLOCK_SIZE);

                                request.request.begin = begin;
                                if (begin + Torrent.BLOCK_SIZE <= pieceLen) {
                                    @branchHint(.likely);
                                    request.request.len = Torrent.BLOCK_SIZE;
                                } else {
                                    request.request.len = pieceLen - begin;
                                }

                                const bufStart = i * request.wireLen();
                                const buf = peer.buf.items[bufStart .. bufStart + request.wireLen()];
                                var writer: std.Io.Writer = .fixed(buf);

                                try request.writeMessage(&writer);
                            }

                            std.log.debug("trying to send {s}", .{@tagName(request)});

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
                        },
                        .bitfield => |len| {
                            const bytes = try peer.readTotalBuf(alloc, len) orelse continue;

                            std.log.debug("received bitfield {b}", .{bytes[0]});
                            try peer.setBitfield(alloc, bytes);

                            peer.workingPiece = pieceManager.getWorkingPiece(peer.bitfield.?) orelse {
                                std.log.debug("peer {d} doesn't have interesting pieces\n", .{
                                    peer.socket,
                                });

                                continue :sw .dead;
                            };

                            std.log.debug("peer {d} has interesting pieces", .{peer.socket});

                            peer.buf.clearRetainingCapacity();

                            const m: proto.Message = .interested;
                            try peer.buf.resize(alloc, m.wireLen());

                            const slice = peer.buf.items[0..m.wireLen()];
                            var writer: std.Io.Writer = .fixed(slice);

                            try m.writeMessage(&writer);

                            peer.state = .bufFlush;
                            peer.direction = .write;

                            std.log.debug("trying to send {s}", .{@tagName(m)});

                            try kq.subscribe(peer.socket, .write, event.kevent.udata);
                        },
                        .piece => |piece| {
                            const bytes = try peer.readTotalBuf(alloc, piece.len) orelse continue;
                            defer peer.state = .messageStart;

                            if (peer.workingPiece) |index| {
                                if (index != piece.index) {
                                    std.log.warn("received piece {d}, while expected {d}", .{
                                        piece.index,
                                        index,
                                    });
                                    continue;
                                }
                            } else {
                                std.log.warn("received piece {d}, while not expecting anything", .{
                                    piece.index,
                                });
                                continue;
                            }

                            std.log.debug("received piece {any}", .{piece});

                            const pieceLen = torrent.getPieceSize(piece.index);
                            const buf = try pieceManager.getPieceBuf(alloc, piece.index, pieceLen);

                            @memcpy(buf.bytes[piece.begin .. piece.begin + piece.len], bytes[0..piece.len]);
                            buf.fetched += @intCast(bytes.len);

                            if (buf.fetched == pieceLen) {
                                const completed = pieceManager.complete(piece.index) catch unreachable;
                                defer completed.deinit(alloc);

                                std.debug.print("{s}", .{completed.bytes});

                                return error.DownloadComplete;
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
