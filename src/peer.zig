const std = @import("std");

const Torrent = @import("torrent.zig");
const PieceManager = @import("piece-manager.zig");
const KQ = @import("kq.zig");

const TCP_HANDSHAKE_LEN = 68;
const TcpHandshake = extern struct {
    pstrlen: u8 = 19,
    pstr: [19]u8 = "BitTorrent protocol".*,
    reserved: [8]u8 = [_]u8{0} ** 8,
    infoHash: [20]u8,
    peerId: [20]u8,

    const ValidateError = error{ InvalidPstrLen, InvalidPstr, InvalidInfoHash };

    pub fn validate(self: TcpHandshake, other: TcpHandshake) ValidateError!bool {
        if (self.pstrlen != other.pstrlen) {
            return error.InvalidPstrLen;
        }

        if (!std.mem.eql(u8, &self.pstr, &other.pstr)) {
            return error.InvalidPstr;
        }

        if (!std.mem.eql(u8, &self.infoHash, &other.infoHash)) {
            return error.InvalidInfoHash;
        }

        return true;
    }
};

comptime {
    if (@sizeOf(TcpHandshake) != TCP_HANDSHAKE_LEN) @compileError("TcpHandshake has invalid size");
}

const Socket = struct {
    fd: std.posix.fd_t,

    state: State = .write,

    pub const State = enum {
        write,
        read,
        dead,
    };

    pub fn connect(addr: std.net.Address, opts: struct { block: bool = false }) !Socket {
        const sockOpts: u32 = if (opts.block) 0 else std.posix.SOCK.NONBLOCK;

        const fd = try std.posix.socket(
            std.posix.AF.INET,
            std.posix.SOCK.STREAM | sockOpts,
            std.posix.IPPROTO.TCP,
        );
        errdefer std.posix.close(fd);

        std.debug.print("connecting to {f}\n", .{addr});

        std.posix.connect(@intCast(fd), &addr.any, addr.getOsSockLen()) catch |err| switch (err) {
            error.WouldBlock => {},
            else => return err,
        };

        return .{ .fd = fd };
    }

    pub fn getNewState(self: *Socket, e: std.posix.Kevent) error{ ConnectionRefused, FFlags, Unknown }!State {
        if (e.filter == std.c.EVFILT.WRITE and self.state == .init) {
            return .write;
        } else if (e.filter == std.c.EVFILT.READ) {
            return .read;
        }

        return error.Unknown;
    }

    pub fn close(self: *Socket) void {
        if (self.state != .dead) {
            std.posix.close(self.fd);
        }

        self.state = .dead;
    }
};

const Peer = struct {
    socket: Socket,

    state: State = .handshake,

    choked: bool = true,
    interested: bool = false,
    workingPiece: ?usize,

    buf: std.array_list.Aligned(u8, null) = .empty,

    bitfield: std.DynamicBitSetUnmanaged,

    pub const State = union(enum) {
        handshake,
        messageStart,
        message: struct { id: MessageId, len: u32 },
        ready,
        dead,
    };

    const MessageId = enum(u8) {
        choke = 0,
        unchoke = 1,
        interested = 2,
        not_interested = 3,
        have = 4,
        bitfield = 5,
        request = 6,
        piece = 7,
        cancel = 8,
        port = 9,
    };

    pub fn deinit(self: *Peer, alloc: std.mem.Allocator, k: KQ) void {
        if (self.state == .dead) {
            return;
        }

        self.state = .dead;

        k.unsubscribe(self.socket.fd, .read) catch |err| {
            std.log.debug("received err while unsubscribing from read for socket {d} with {s}\n", .{
                self.socket.fd,
                @errorName(err),
            });
        };
        k.unsubscribe(self.socket.fd, .write) catch |err| switch (err) {
            error.EventNotFound => {}, // already unsubscribed
            else => {
                std.log.debug("received err while unsubscribing from write for socket {d} with {s}\n", .{
                    self.socket.fd,
                    @errorName(err),
                });
            },
        };

        self.socket.close();
        self.buf.deinit(alloc);
        self.bitfield.deinit(alloc);
    }

    pub fn setBitfield(self: *Peer, alloc: std.mem.Allocator, bytes: []const u8) !void {
        self.bitfield = try .initEmpty(alloc, bytes.len * 8);

        for (bytes, 0..) |byte, i| {
            for (0..8) |bit_idx| {
                // Check if bit is set (MSB first), thank you gemini, but i don't get what this does
                const is_set = (byte >> @intCast(7 - bit_idx)) & 1 != 0;

                // Calculate absolute piece index
                const piece_index = (i * 8) + bit_idx;

                if (piece_index < self.bitfield.capacity() and is_set) {
                    self.bitfield.set(piece_index);
                }
            }
        }
    }

    pub fn read(self: *Peer, slice: []u8) !usize {
        const count = try std.posix.read(self.socket.fd, slice);
        return count;
    }

    pub fn readInt(self: *Peer, comptime T: type, endian: std.builtin.Endian) !T {
        const n = @divExact(@typeInfo(T).int.bits, 8);
        var buf: [n]u8 = undefined;

        var total: usize = 0;
        while (total != n) {
            const count = std.posix.read(self.socket.fd, buf[total..n]) catch |err| switch (err) {
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
        const count = try std.posix.read(self.socket.fd, slice[len..size]);

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
        const wrote = try std.posix.write(self.socket.fd, slice[len..]);
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

        const wrote = try std.posix.write(self.socket.fd, self.buf.items);

        const left = self.buf.items.len - wrote;
        if (left == 0) {
            return;
        }

        @memmove(self.buf.items[0..left], self.buf.items[wrote .. wrote + left]);
        self.buf.items.len = left;

        return null;
    }

    pub fn findMissing(self: Peer, other: std.DynamicBitSetUnmanaged) ?usize {
        var i: usize = 0;

        while (i < self.bitfield.capacity()) : (i += 1) {
            if (self.bitfield.isSet(i) and !other.isSet(i)) {
                return i;
            }
        }

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
        for (peers) |*peer| peer.deinit(alloc, kq);
        alloc.free(peers);
    }

    for (addrs, 0..) |addr, i| {
        const socket: Socket = try .connect(addr, .{});

        peers[i] = Peer{
            .socket = socket,
            .bitfield = .{},
        };

        try kq.subscribe(socket.fd, .read, @intFromPtr(&peers[i]));
        try kq.subscribe(socket.fd, .write, @intFromPtr(&peers[i]));
    }

    var deadCount: usize = 0;

    const handshake = TcpHandshake{ .infoHash = torrent.infoHash, .peerId = peerId };
    const handshakeBytes = std.mem.asBytes(&handshake);

    while (try kq.next()) |event| {
        const peer: *Peer = @ptrFromInt(event.kevent.udata);

        if (event.err) |err| if (peer.state != .dead) {
            std.log.err("enountered {s} for {any}", .{ @tagName(err), peer });
            peer.deinit(alloc, kq);
            deadCount += 1;
        };

        if (deadCount == peers.len) {
            return error.AllStreamsDead;
        }

        switch (event.op) {
            .write => if (peer.socket.state == .write) switch (peer.state) {
                .dead => {},
                .handshake => {
                    std.log.debug("sent handshake to socket {d}", .{peer.socket.fd});
                    _ = try peer.writeTotalBuf(alloc, handshakeBytes) orelse continue;

                    peer.state = .handshake;
                    peer.socket.state = .read;
                    peer.buf.clearRetainingCapacity();

                    try kq.unsubscribe(peer.socket.fd, .write);
                },
                .message => |message| {
                    if (peer.buf.items.len == 0) continue;
                    try peer.writeBuf() orelse continue;

                    std.log.debug("sent message {s} to socket {d}", .{ @tagName(message.id), peer.socket.fd });

                    peer.state = .messageStart;
                    peer.socket.state = .read;

                    try kq.unsubscribe(peer.socket.fd, .write);
                },
                else => unreachable,
            },
            .read => if (peer.socket.state == .read) switch (peer.state) {
                .dead => {},
                .handshake => {
                    const bytes = try peer.readTotalBuf(alloc, TCP_HANDSHAKE_LEN) orelse continue;

                    defer peer.buf.clearRetainingCapacity();
                    const received: *TcpHandshake = @ptrCast(bytes);

                    const valid = handshake.validate(received.*) catch |err| switch (err) {
                        error.InvalidInfoHash => blk: {
                            std.debug.print("received handshake with invalid info hash\n", .{});
                            break :blk false;
                        },
                        error.InvalidPstr => blk: {
                            std.debug.print("received handshake with invalid pstr\n", .{});
                            break :blk false;
                        },
                        error.InvalidPstrLen => blk: {
                            std.debug.print("received handshake with invalid pstr len\n", .{});
                            break :blk false;
                        },
                    };

                    if (valid) {
                        peer.state = .messageStart;
                        std.log.debug("received valid TcpHandshake for socket {d}", .{peer.socket.fd});
                    } else {
                        deadCount += 1;
                        peer.deinit(alloc, kq);
                    }
                },
                .messageStart => {
                    const len = try peer.readInt(u32, .big);
                    if (len == 0) {
                        // keep alive, send requests ?
                        continue;
                    }

                    const id = try peer.readInt(u8, .big);
                    const idEnum = std.enums.fromInt(Peer.MessageId, id) orelse {
                        std.debug.print("enountered unknown message id: {d}\n", .{id});
                        continue;
                    };

                    std.log.debug("read message start ({s}, len: {d})", .{
                        @tagName(idEnum),
                        len,
                    });

                    peer.state = .{ .message = .{ .id = idEnum, .len = len - 1 } };
                },
                .message => |message| {
                    const bytes = try peer.readTotalBuf(alloc, message.len) orelse continue;

                    std.log.debug("received {s} message", .{@tagName(message.id)});

                    switch (message.id) {
                        .choke => {
                            defer peer.state = .messageStart;
                            peer.choked = true;
                        },
                        .unchoke => {
                            defer peer.state = .messageStart;
                            peer.choked = false;

                            // TODO: Logic: If peer_has_what_I_need, sendRequests()
                            // This sendRequest should send multiple requests for chunks from single
                            // piece at once. I think we can send all chunk requests from single
                            // piece. And then wait for receive them all.

                            // peer.buf.clearRetainingCapacity();
                            // try peer.buf.ensureUnusedCapacity(alloc, 17);
                            // peer.buf.items.len = 17;
                            //
                            // const buf = peer.buf.items;
                            // std.mem.writeInt(u32, buf[0..4], 13, .big);
                            // buf[4] = 6; // ID for Request
                            //
                            // std.mem.writeInt(u32, buf[5..9], index, .big);
                            // std.mem.writeInt(u32, buf[9..13], begin, .big);
                            // std.mem.writeInt(u32, buf[13..17], len, .big);
                        },
                        .have => {
                            defer peer.state = .messageStart;

                            const index = std.mem.readInt(u32, bytes[0..4], .big);
                            peer.bitfield.set(index);
                        },
                        .bitfield => {
                            std.log.debug("received bitfield {b}", .{bytes[0]});
                            try peer.setBitfield(alloc, bytes);

                            if (pieceManager.getWorkingPiece(peer.bitfield)) |index| {
                                std.log.debug("peer {d} has interesting pieces", .{peer.socket.fd});

                                peer.workingPiece = index;

                                peer.buf.clearRetainingCapacity();
                                try peer.buf.resize(alloc, 5);

                                peer.state = .{ .message = .{ .id = .interested, .len = 1 } };
                                peer.socket.state = .write;

                                std.mem.writeInt(u32, peer.buf.items[0..4], peer.state.message.len, .big);
                                peer.buf.items[4] = @intFromEnum(peer.state.message.id);

                                try kq.subscribe(peer.socket.fd, .write, event.kevent.udata);
                            } else {
                                std.log.debug("peer {d} doesn't have interesting pieces\n", .{
                                    peer.socket.fd,
                                });

                                deadCount += 1;
                                peer.deinit(alloc, kq);
                            }
                        },
                        .piece => { // PIECE (The Data)
                            // const index = std.mem.readInt(u32, bytes[0..4], .big);
                            // const begin = std.mem.readInt(u32, bytes[4..8], .big);
                            // const block = bytes[8..];
                            // try storeBlock(index, begin, block);
                            defer peer.state = .messageStart;
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
