const std = @import("std");
const builtin = @import("builtin");

const utils = @import("utils");
const Tls = @import("tls");
const Socket = @import("socket.zig");
const Operation = @import("tozi").Tracker.Operation;

const HttpTracker = @This();

const State = enum {
    handshake,
    prepareRequest,
    sendingRequest,
    readingRequest,
};

state: State,

socket: *Socket,
socketPosix: ?Socket.Posix,

buffer: std.Io.Writer.Allocating,

encryptedBuf: std.array_list.Aligned(u8, null) = .empty,
chunks: std.array_list.Aligned(packed struct { start: u32, len: u32 }, null) = .empty,

url: []const u8,
uri: std.Uri,

tls: union(enum) {
    handshake: TlsHandshake,
    connection: Tls.nonblock.Connection,
    none,
},

/// used in `readingRequest` to prevent re-parsing head each time, new chunk or read appears
parsedHead: ?struct {
    contentStart: usize,
    transfer: union(enum) { chunked: struct { start: usize, headerLen: ?usize, len: ?usize }, length: ?usize },
    encoding: std.http.ContentEncoding,
} = null,

pub fn init(alloc: std.mem.Allocator, url: []const u8) !HttpTracker {
    const isHttp = utils.isHttp(url);
    const isHttps = utils.isHttps(url);
    utils.assert(isHttp or isHttps);

    const urlDupe = try alloc.dupe(u8, url);
    errdefer alloc.free(urlDupe);

    const uri: std.Uri = try .parse(urlDupe);

    var hostBuffer: [std.Uri.host_name_max]u8 = undefined;
    const host = try uri.getHost(&hostBuffer);
    const port: u16 = if (uri.port) |x| x else if (isHttps) 443 else 80;

    const list = try std.net.getAddressList(alloc, host, port);
    defer list.deinit();

    if (list.addrs.len == 0) return error.UnknownHostName;

    const socket = blk: {
        for (list.addrs) |addr| {
            break :blk connectToAddress(addr) catch |err| switch (err) {
                error.ConnectionRefused => continue,
                else => return err,
            };
        }
        return std.posix.ConnectError.ConnectionRefused;
    };

    var self = HttpTracker{
        .state = if (isHttps) .handshake else .prepareRequest,
        .buffer = .init(alloc),
        .socket = undefined,
        .socketPosix = .init(socket),
        .url = urlDupe,
        .uri = uri,
        .tls = .none,
    };

    self.socket = &self.socketPosix.?.interface;

    return self;
}

pub fn deinit(self: *HttpTracker, alloc: std.mem.Allocator) void {
    alloc.free(self.url);
    self.buffer.deinit();
    self.chunks.deinit(alloc);
    self.encryptedBuf.deinit(alloc);

    switch (self.tls) {
        .handshake => |*h| h.deinit(alloc),
        else => {},
    }

    if (self.socketPosix) |x| std.posix.close(x.fd);
}

pub fn tlsHandshake(self: *HttpTracker, alloc: std.mem.Allocator) !*TlsHandshake {
    return switch (self.tls) {
        .handshake => |*h| h,
        .connection => error.HandshakeAlreadyEstablished,
        .none => {
            utils.assert(self.state == .handshake);
            self.tls = .{ .handshake = try .init(alloc, self) };
            return &self.tls.handshake;
        },
    };
}

pub const TlsHandshake = struct {
    caBundle: Tls.config.cert.Bundle,
    client: Tls.nonblock.Client,

    socket: *Socket,

    res: ?struct {
        unusedRecv: []const u8,
        send: []const u8,
        sendPos: u32 = 0,
    },

    recvPos: u32 = 0,

    recvBuf: [Tls.max_ciphertext_record_len]u8 = undefined,
    sendBuf: [Tls.max_ciphertext_record_len]u8 = undefined,

    state: union(enum) {
        write,
        read,
        done: Tls.Cipher,
    },

    pub fn init(alloc: std.mem.Allocator, tracker: *const HttpTracker) !TlsHandshake {
        var caBundle = try Tls.config.cert.fromSystem(alloc);
        errdefer caBundle.deinit(alloc);

        var hostBuf: [std.Uri.host_name_max]u8 = undefined;
        const host = try tracker.uri.getHost(&hostBuf);

        const client = Tls.nonblock.Client.init(.{
            .host = host,
            .root_ca = caBundle,
            .insecure_skip_verify = builtin.is_test or builtin.mode == .Debug,
        });

        return .{
            .caBundle = caBundle,
            .client = client,
            .socket = tracker.socket,
            .state = .write,
            .res = null,
        };
    }

    pub fn deinit(self: *TlsHandshake, alloc: std.mem.Allocator) void {
        self.caBundle.deinit(alloc);
    }

    pub fn write(self: *TlsHandshake) !void {
        if (self.state == .done or self.state == .read) return;

        const res = if (self.res) |*r| r else blk: {
            const res = try self.client.run(self.recvBuf[0..self.recvPos], &self.sendBuf);
            self.res = .{
                .unusedRecv = res.unused_recv,
                .send = res.send,
            };

            break :blk &self.res.?;
        };

        const wrote = try self.socket.write(res.send[res.sendPos..]) orelse return;
        res.sendPos += @intCast(wrote);

        utils.assert(res.sendPos <= Tls.max_ciphertext_record_len);

        if (res.sendPos == res.send.len) {
            self.recvPos = @intCast(shiftUnused(&self.recvBuf, res.unusedRecv));
            self.res = null;
            self.state = .read;

            if (self.client.cipher()) |cipher| {
                self.state = .{ .done = cipher };
            }
        }
    }

    pub fn read(self: *TlsHandshake) !void {
        if (self.state == .done or self.state == .write) return;

        const readCount = try self.socket.read(self.recvBuf[self.recvPos..]) orelse return;
        self.recvPos += @intCast(readCount);

        self.state = .write;
    }

    test "initiate handshake" {
        const alloc = std.testing.allocator;

        var torrent = try getTestTorrent(alloc, "./src/test_files/copper-https.torrent");
        defer torrent.deinit(alloc);

        var t: HttpTracker = try .init(alloc, torrent.tiers.items[0].items[0]);
        defer t.deinit(alloc);
        const socket = t.socketPosix.?.fd;

        try std.testing.expectEqual(State.handshake, t.state);

        const handshake = try t.tlsHandshake(alloc);

        const KQ = @import("kq.zig");
        var kq: KQ = try .init(alloc);
        defer kq.deinit();

        try kq.subscribe(socket, .write, 1);
        try kq.subscribe(socket, .read, 1);
        try kq.disable(socket, switch (handshake.state) {
            .write => .read,
            .read => .write,
            .done => unreachable,
        });
        try kq.addTimer(0, 250, .{ .periodic = false });

        while (try kq.next()) |ev| {
            try std.testing.expectEqual(null, ev.err);
            try std.testing.expect(ev.kind != .timer);

            switch (ev.kind) {
                .timer => unreachable,
                .write => if (handshake.state == .write) {
                    try handshake.write();

                    switch (handshake.state) {
                        .write => {},
                        .read => {
                            try kq.disable(socket, .write);
                            try kq.enable(socket, .read, 1);
                        },
                        .done => |cipher| {
                            _ = cipher;
                            break;
                        },
                    }
                },
                .read => if (handshake.state == .read) {
                    try handshake.read();

                    if (handshake.state == .write) {
                        try kq.disable(socket, .read);
                        try kq.enable(socket, .write, 1);
                    }
                },
            }
        }
    }
};

pub const Stats = struct {
    infoHash: [20]u8,
    peerId: [20]u8,
    port: u16 = 6889,
    numWant: u16,
    downloaded: usize,
    uploaded: usize,
    left: usize,

    event: ?enum { started, stopped, completed } = null,
};

pub fn prepareRequest(self: *HttpTracker, alloc: std.mem.Allocator, stats: *const Stats) !void {
    utils.assert(self.state == .prepareRequest);

    const w = &self.buffer.writer;
    _ = w.consumeAll();

    try w.writeAll("GET ");

    try self.uri.writeToStream(w, .{ .path = true });
    try utils.writeQueryToStream(w, self.uri, &[_]utils.QueryParam{
        .{ "info_hash", .{ .string = &stats.infoHash } },
        .{ "peer_id", .{ .string = &stats.peerId } },
        .{ "port", .{ .int = stats.port } },
        .{ "uploaded", .{ .int = stats.uploaded } },
        .{ "downloaded", .{ .int = stats.downloaded } },
        .{ "left", .{ .int = stats.left } },
        .{ "compact", .{ .int = 1 } },
        .{ "key", .{ .string = stats.peerId[16..20] } },
        .{ "numwant", .{ .int = stats.numWant } },
        .{
            "event",
            if (stats.event) |x| .{ .string = @tagName(x) } else .skip,
        },
    });

    try w.print(" {s}\r\n", .{@tagName(std.http.Version.@"HTTP/1.1")});

    try w.writeAll("host: ");
    try self.uri.writeToStream(w, .{ .authority = true });
    try w.writeAll("\r\n");

    try w.writeAll("user-agent: tozi/0.0.1\r\n");
    try w.writeAll("connection: close\r\n");

    try w.writeAll("accept-encoding: ");
    for (std.http.Client.Request.default_accept_encoding, 0..) |enabled, i| {
        const tag: std.http.ContentEncoding = @enumFromInt(i);
        if (!enabled or tag == .identity) continue;
        try w.print("{s}, ", .{@tagName(tag)});
    }
    w.undo(2);
    try w.writeAll("\r\n");

    try w.writeAll("\r\n");

    switch (self.tls) {
        .connection => |*conn| {
            const text = w.buffered();
            const encryptedSize = conn.encryptedLength(text.len);
            utils.assert(encryptedSize <= std.math.maxInt(u16));

            const encrypted = try alloc.alloc(u8, encryptedSize);
            defer alloc.free(encrypted);

            const res = try conn.encrypt(text, encrypted);
            utils.assert(res.ciphertext.len == encrypted.len);

            _ = w.consumeAll();
            try w.writeAll(encrypted);
        },
        else => {},
    }

    self.state = .sendingRequest;
}

/// true - wrote all, false - still data to be written
pub fn sendRequest(self: *HttpTracker) !bool {
    utils.assert(self.state == .sendingRequest);

    const wrote = try self.socket.write(self.buffer.written()) orelse return false;
    _ = self.buffer.writer.consume(wrote);

    if (self.buffer.writer.end != 0) {
        return false;
    }

    self.state = .readingRequest;
    return true;
}

pub fn readRequest(self: *HttpTracker, alloc: std.mem.Allocator) !?[]u8 {
    utils.assert(self.state == .readingRequest);

    const readBuf = switch (self.tls) {
        .connection => blk: {
            try self.encryptedBuf.ensureTotalCapacityPrecise(alloc, Tls.max_ciphertext_record_len);

            break :blk self.encryptedBuf.unusedCapacitySlice();
        },
        .handshake, .none => blk: {
            const readCount = 4 * 1024;
            try self.buffer.ensureUnusedCapacity(readCount);

            break :blk self.buffer.writer.unusedCapacitySlice()[0..readCount];
        },
    };

    const count = try self.socket.read(readBuf) orelse return null;

    switch (self.tls) {
        .connection => |*conn| {
            self.encryptedBuf.items.len += count;

            try self.buffer.writer.ensureUnusedCapacity(Tls.max_ciphertext_record_len);
            const res = try conn.decrypt(self.encryptedBuf.items, self.buffer.writer.unusedCapacitySlice());

            self.buffer.writer.end += res.cleartext.len;

            self.encryptedBuf.items.len = shiftUnused(self.encryptedBuf.allocatedSlice(), res.unused_ciphertext);
        },
        .handshake, .none => {
            self.buffer.writer.end += count;
        },
    }

    if (self.buffer.writer.end > std.math.maxInt(u16)) {
        return error.ResponseTooLong;
    }

    const written = self.buffer.written();
    const head = if (self.parsedHead) |*x| x else blk: {
        var hp: std.http.HeadParser = .{};

        const contentStart = hp.feed(written);
        if (hp.state != .finished) {
            return if (count == 0) error.ResponseTruncated else null;
        }

        const head = try std.http.Client.Response.Head.parse(written[0..contentStart]);

        if (head.status != .ok) return error.NonOkStatus;
        if (head.content_length) |contentLength| if (contentLength > std.math.maxInt(u16)) {
            return error.ResponseTooLong;
        };

        if (head.content_encoding == .compress) return error.UnsupportedCompressionMethod;

        self.parsedHead = .{
            .encoding = head.content_encoding,
            .contentStart = contentStart,
            .transfer = if (head.transfer_encoding == .chunked)
                .{ .chunked = .{ .start = contentStart, .headerLen = null, .len = null } }
            else
                .{ .length = head.content_length },
        };

        break :blk &self.parsedHead.?;
    };

    switch (head.transfer) {
        .length => |len| {
            if (len) |contentLength| {
                if (head.contentStart + contentLength > written.len) return null;
            } else if (count != 0) return null;
        },
        .chunked => |*state| while (true) {
            if (state.len) |chunkLen| {
                const end = state.start + state.headerLen.? + chunkLen + 2;

                if (written.len < end) {
                    return null;
                } else {
                    try self.chunks.append(alloc, .{
                        .start = @intCast(state.start + state.headerLen.?),
                        .len = @intCast(chunkLen),
                    });

                    state.start = end;
                    state.len = null;
                }
            } else {
                var chp: std.http.ChunkParser = .init;
                const headerLen = chp.feed(written[state.start..]);

                switch (chp.state) {
                    .invalid => return error.InvalidChunkEncoding,
                    .data => {
                        if (chp.chunk_len == 0) break;

                        state.len = chp.chunk_len;
                        state.headerLen = headerLen;
                    },
                    else => return null,
                }
            }
        },
    }

    const bytes = switch (head.transfer) {
        .length => written[head.contentStart..],
        .chunked => blk: {
            var prevChunkEnd: usize = head.contentStart;
            var copied: usize = 0;

            for (self.chunks.items) |chunk| {
                std.mem.copyForwards(
                    u8,
                    written[prevChunkEnd .. prevChunkEnd + chunk.len],
                    written[chunk.start .. chunk.start + chunk.len],
                );

                prevChunkEnd += chunk.len;
                copied += chunk.len;
            }

            break :blk written[head.contentStart .. head.contentStart + copied];
        },
    };

    switch (head.encoding) {
        .compress => unreachable,
        .identity => return try alloc.dupe(u8, bytes),
        .zstd => {
            var reader: std.Io.Reader = .fixed(bytes);

            const buffer = try alloc.alloc(u8, std.compress.zstd.default_window_len);
            defer alloc.free(buffer);

            var decompress = std.compress.zstd.Decompress.init(&reader, buffer, .{ .verify_checksum = false });

            return try decompress.reader.allocRemaining(alloc, .unlimited);
        },
        inline else => |tag| {
            var reader: std.Io.Reader = .fixed(bytes);

            const buffer = try alloc.alloc(u8, std.compress.flate.max_window_len);
            defer alloc.free(buffer);

            var decompress = std.compress.flate.Decompress.init(&reader, switch (tag) {
                .deflate => .zlib,
                .gzip => .gzip,
                else => @compileError("handle else in switch above"),
            }, buffer);

            return try decompress.reader.allocRemaining(alloc, .unlimited);
        },
    }
}

fn connectToAddress(addr: std.net.Address) !std.posix.socket_t {
    const CLOEXEC = if (builtin.os.tag == .windows) 0 else std.posix.SOCK.CLOEXEC;

    const sock_flags = std.posix.SOCK.STREAM | std.posix.SOCK.NONBLOCK | CLOEXEC;

    const sock = try std.posix.socket(addr.any.family, sock_flags, std.posix.IPPROTO.TCP);
    errdefer std.posix.close(sock);

    std.posix.connect(sock, &addr.any, addr.getOsSockLen()) catch |err| switch (err) {
        error.WouldBlock => {},
        else => |e| return e,
    };

    return sock;
}

/// Shift unused part of the buffer to the beginning.
/// Returns write position for the next write into buffer.
/// Unused part is at the end of the buffer.
fn shiftUnused(buf: []u8, unused: []const u8) usize {
    if (unused.len == 0) return 0;
    if (unused.ptr == buf.ptr) return unused.len;
    std.mem.copyForwards(u8, buf, unused);
    return unused.len;
}

const Torrent = @import("torrent.zig");

test "writes correct http request" {
    const requrl = "http://localhost:9000/announce";

    const alloc = std.testing.allocator;
    var t = HttpTracker{
        .buffer = .init(alloc),
        .uri = try .parse(requrl),
        .socket = undefined,
        .socketPosix = null,
        .url = "",
        .tls = .none,
        .state = .prepareRequest,
    };
    defer t.buffer.deinit();

    try t.prepareRequest(alloc, &.{
        .infoHash = .{1} ** 20,
        .peerId = .{1} ** 20,
        .numWant = 0,
        .downloaded = 0,
        .uploaded = 0,
        .left = 0,
    });

    const expectedReqString = "GET /announce?info_hash=%01%01%01%01%01%01%01%01%01%01%01%01%01%01%01%01%01%01%01%01&peer_id=%01%01%01%01%01%01%01%01%01%01%01%01%01%01%01%01%01%01%01%01&port=6889&uploaded=0&downloaded=0&left=0&compact=1&key=%01%01%01%01&numwant=0 HTTP/1.1\r\n" ++
        "host: localhost:9000\r\n" ++
        "user-agent: tozi/0.0.1\r\n" ++
        "connection: close\r\n" ++
        "accept-encoding: gzip, deflate\r\n\r\n";

    try std.testing.expectEqualStrings(expectedReqString, t.buffer.written());
}

fn getTestTorrent(alloc: std.mem.Allocator, path: []const u8) !Torrent {
    const torrentFile = std.fs.cwd().openFile(path, .{}) catch unreachable;
    defer torrentFile.close();

    const torrentSlice = try torrentFile.readToEndAlloc(alloc, 10 * 1024);
    defer alloc.free(torrentSlice);

    return try .fromSlice(alloc, torrentSlice);
}

test "make request" {
    const alloc = std.testing.allocator;

    var torrent = try getTestTorrent(alloc, "./src/test_files/copper.torrent");
    defer torrent.deinit(alloc);

    var t: HttpTracker = try .init(alloc, torrent.tiers.items[0].items[0]);
    defer t.deinit(alloc);
    const socket = t.socketPosix.?.fd;

    const stats: Stats = .{
        .infoHash = torrent.infoHash,
        .peerId = .{1} ** 20,
        .numWant = 50,
        .downloaded = 0,
        .uploaded = 0,
        .left = torrent.totalLen,
    };

    try t.prepareRequest(alloc, &stats);

    const KQ = @import("./kq.zig");
    const Bencode = @import("bencode.zig");

    var kq: KQ = try .init(alloc);
    defer kq.deinit();

    try kq.subscribe(socket, .write, 1);
    const readyWrite = try kq.next() orelse unreachable;
    try std.testing.expectEqual(null, readyWrite.err);
    try std.testing.expectEqual(.write, readyWrite.kind);

    _ = try t.sendRequest();
    try kq.delete(socket, .write);

    try std.testing.expectEqual(0, t.buffer.writer.end);
    try std.testing.expectEqual(State.readingRequest, t.state);

    try kq.subscribe(socket, .read, 1);
    try kq.addTimer(0, 100, .{ .periodic = false });

    while (try kq.next()) |ev| {
        try std.testing.expectEqual(.read, ev.kind);

        const bytes = try t.readRequest(alloc) orelse continue;
        defer alloc.free(bytes);

        var reader: std.Io.Reader = .fixed(bytes);

        var value: Bencode = try .decode(alloc, &reader, 0);
        defer value.deinit(alloc);

        return;
    }

    try std.testing.expect(false);
}

test "make https request" {
    const alloc = std.testing.allocator;

    var torrent = try getTestTorrent(alloc, "./src/test_files/copper-https.torrent");
    defer torrent.deinit(alloc);

    const KQ = @import("./kq.zig");
    const Bencode = @import("bencode.zig");

    var t: HttpTracker = try .init(alloc, torrent.tiers.items[0].items[0]);
    defer t.deinit(alloc);
    const socket = t.socketPosix.?.fd;

    const stats: Stats = .{
        .infoHash = torrent.infoHash,
        .peerId = .{1} ** 20,
        .numWant = 50,
        .downloaded = 0,
        .uploaded = 0,
        .left = torrent.totalLen,
    };

    var kq: KQ = try .init(alloc);
    defer kq.deinit();

    try kq.subscribe(socket, .write, 1);
    try kq.addTimer(0, 100, .{ .periodic = false });

    while (try kq.next()) |e| {
        try std.testing.expect(e.kind != .timer);

        sw: switch (t.state) {
            .handshake => {
                const handshake = try t.tlsHandshake(alloc);

                switch (e.kind) {
                    .timer => unreachable,
                    .write => if (handshake.state == .write) {
                        try handshake.write();

                        switch (handshake.state) {
                            .write => {},
                            .read => {
                                try kq.delete(socket, .write);
                                try kq.subscribe(socket, .read, 1);
                            },
                            .done => |cipher| {
                                kq.delete(socket, .write) catch {};

                                handshake.deinit(alloc);

                                t.tls = .{ .connection = .init(cipher) };
                                t.state = .prepareRequest;

                                continue :sw t.state;
                            },
                        }
                    },
                    .read => if (handshake.state == .read) {
                        try handshake.read();

                        switch (handshake.state) {
                            .write => {
                                try kq.delete(socket, .read);
                                try kq.subscribe(socket, .write, 1);
                            },
                            .read => {},
                            .done => unreachable,
                        }
                    },
                }
            },
            .prepareRequest => {
                try t.prepareRequest(alloc, &stats);
                try kq.subscribe(socket, .write, 1);
            },
            .sendingRequest => {
                const ready = try t.sendRequest();

                if (!ready) continue;

                kq.delete(socket, .write) catch {};
                try kq.subscribe(socket, .read, 1);
            },
            .readingRequest => {
                const content = try t.readRequest(alloc) orelse continue;
                defer alloc.free(content);

                kq.delete(socket, .read) catch {};

                var reader: std.Io.Reader = .fixed(content);

                var value: Bencode = try .decode(alloc, &reader, 0);
                defer value.deinit(alloc);

                return;
            },
        }
    }

    try std.testing.expect(false);
}

test "chuncked transfer encoding" {
    const alloc = std.testing.allocator;

    outer: for (12..32) |max| {
        var a: Socket.Allocating = .init(alloc, @intCast(max));
        defer a.deinit();

        try a.addInBytes("HTTP/1.1 200 OK\r\n" ++
            "Content-Type: text/plain\r\n" ++
            "Transfer-Encoding: chunked\r\n" ++
            "\r\n" ++
            "5\r\n" ++
            "Hello\r\n" ++
            "7\r\n" ++
            " World!\r\n" ++
            "0\r\n" ++
            "\r\n");

        var t: HttpTracker = .{
            .socket = &a.interface,
            .socketPosix = null,
            .buffer = .init(alloc),
            .state = .readingRequest,
            .tls = .none,
            .url = undefined,
            .uri = undefined,
        };
        defer t.buffer.deinit();
        defer t.chunks.deinit(alloc);

        var i: u8 = 0;
        while (i < std.math.maxInt(u8)) : (i += 1) {
            const bytes = try t.readRequest(alloc) orelse continue;
            defer alloc.free(bytes);

            try std.testing.expectEqualStrings("Hello World!", bytes);

            break :outer;
        }

        try std.testing.expect(false);
    }
}

test {
    std.testing.refAllDecls(HttpTracker);
}
