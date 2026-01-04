const std = @import("std");

const Torrent = @import("torrent.zig");
const KQueue = @import("kqueue.zig");

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

    state: State = .init,

    pub const State = enum {
        init,
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
        if (e.flags & std.c.EV.EOF != 0) {
            const fallback = std.c.E.CONNREFUSED;
            const err = std.meta.intToEnum(std.c.E, e.fflags) catch blk: {
                std.debug.print("unknown error flag: {d}, fallbacking to {s}", .{
                    e.fflags,
                    @tagName(fallback),
                });
                break :blk fallback;
            };

            return switch (err) {
                .CONNREFUSED => return error.ConnectionRefused,
                else => return error.FFlags,
            };
        }

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

    state: State = .init,

    choked: bool = true,
    interested: bool = false,

    buf: std.array_list.Aligned(u8, null) = .empty,

    bitfield: std.DynamicBitSetUnmanaged,

    pub const State = union(enum) {
        init,
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

    pub fn deinit(self: *Peer, alloc: std.mem.Allocator) void {
        if (self.state == .dead) {
            return;
        }

        self.state = .dead;
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
    addrs: []const std.net.Address,
) !void {
    var kqueue: KQueue = try .init();
    defer kqueue.deinit();

    var peers = try alloc.alloc(Peer, addrs.len);
    defer {
        for (peers) |*peer| peer.deinit(alloc);
        alloc.free(peers);
    }

    for (addrs, 0..) |addr, i| {
        const socket: Socket = try .connect(addr, .{});

        peers[i] = Peer{
            .socket = socket,
            .bitfield = .{},
        };

        try kqueue.subscribe(socket.fd, .read, @intFromPtr(&peers[i]));
        try kqueue.subscribe(socket.fd, .write, @intFromPtr(&peers[i]));
    }

    var deadCount: usize = 0;

    const handshake = TcpHandshake{ .infoHash = torrent.infoHash, .peerId = peerId };
    const handshakeBytes = std.mem.asBytes(&handshake);

    while (try kqueue.next()) |e| {
        std.debug.assert(e.udata != 0);

        const peer: *Peer = @ptrFromInt(e.udata);

        peer.socket.state = peer.socket.getNewState(e) catch |err| switch (err) {
            error.ConnectionRefused => blk: {
                std.debug.print("Connection refused for {any}\n", .{e});
                break :blk .dead;
            },
            else => return err,
        };

        if (peer.socket.state != .dead) {
            std.debug.print("received peer: {any}\n", .{peer});
        }

        sw: switch (peer.socket.state) {
            .init => unreachable,
            .dead => {
                deadCount += 1;

                try kqueue.unsubscribe(peer.socket.fd, .read, 0);
                kqueue.unsubscribe(peer.socket.fd, .write, 0) catch |err| switch (err) {
                    error.EventNotFound => {}, // already unsubscribed
                    else => return err,
                };

                peer.deinit(alloc);

                if (deadCount == peers.len) {
                    return error.AllStreamsDead;
                }
            },
            .write => if (peer.state == .init) {
                if (peer.buf.items.len == 0) {
                    try peer.buf.appendSlice(alloc, handshakeBytes);
                }

                const sent = try std.posix.write(peer.socket.fd, peer.buf.items);
                const left = peer.buf.items.len - sent;
                std.log.debug("sent handshake to socket {d}", .{peer.socket.fd});

                if (left == 0) {
                    peer.state = .handshake;
                    peer.buf.clearRetainingCapacity();
                    try peer.buf.ensureTotalCapacity(alloc, TCP_HANDSHAKE_LEN);

                    try kqueue.unsubscribe(peer.socket.fd, .write, e.udata);
                } else {
                    try peer.buf.replaceRangeBounded(0, left, peer.buf.items[sent .. sent + left]);
                }
            },
            .read => switch (peer.state) {
                .init => unreachable,
                .dead => continue,
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
                        continue :sw .dead;
                    }
                },
                .messageStart => {
                    const len = try peer.readInt(u32, .big);
                    if (len == 0) continue;

                    const id = try peer.readInt(u8, .big);
                    const idEnum = std.enums.fromInt(Peer.MessageId, id) orelse {
                        std.debug.print("enountered unknown message id: {d}\n", .{id});
                        continue;
                    };

                    std.log.debug("read message start ({s}, len: {d})", .{
                        @tagName(idEnum),
                        len - 1,
                    });
                    peer.state = .{ .message = .{ .id = idEnum, .len = len - 1 } };
                },
                .message => |message| {
                    const bytes = try peer.readTotalBuf(alloc, message.len) orelse continue;

                    // this is safe because we wouldn't get here if we didn't read all `message.len`
                    // bytes from kernel
                    defer peer.buf.clearRetainingCapacity();
                    defer peer.state = .messageStart;

                    std.log.debug("received {s} message", .{@tagName(message.id)});

                    switch (message.id) {
                        .choke => peer.choked = true,
                        .unchoke => {
                            peer.choked = false;
                            break;
                            // TODO: Logic: If peer_has_what_I_need, sendRequests()
                        },
                        .have => {
                            const index = std.mem.readInt(u32, bytes[0..4], .big);
                            peer.bitfield.set(index);
                        },
                        .bitfield => {
                            std.debug.print("received bitfield {b}\n", .{bytes[0]});
                            try peer.setBitfield(alloc, bytes);

                            if (peer.findMissing(torrent.bitfield)) |_| {
                                // peer has pieces that i don't have
                                std.log.debug("has interesting piece", .{});
                                break;
                            }
                        },
                        .piece => { // PIECE (The Data)
                            // const index = std.mem.readInt(u32, bytes[0..4], .big);
                            // const begin = std.mem.readInt(u32, bytes[4..8], .big);
                            // const block = bytes[8..];
                            // try storeBlock(index, begin, block);
                        },
                        .request, // Peer requested block from you (Ignore if leaching)
                        .interested, // Peer is interested in you (Ignore if leaching)
                        .not_interested, // Peer not interested (Ignore)
                        .cancel,
                        .port,
                        => {},
                    }
                },
                .ready => {
                    // const len =
                },
            },
        }
    }
}
