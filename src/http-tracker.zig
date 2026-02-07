const std = @import("std");
const builtin = @import("builtin");

const utils = @import("utils");
const tls = @import("tls");

const HttpTracker = @This();

const State = enum {
    handshake,
    prepareRequest,
    sendingRequest,
    readingRequest,
};

state: State,

socket: std.posix.socket_t,

buffer: std.Io.Writer.Allocating,

url: []const u8,
uri: std.Uri,

handshake: ?TlsHandshake,

/// used in `readingRequest` to prevent re-parsing head each time, new chunk or read appears
parsedHead: ?struct {
    contentStart: usize,
    contentLength: ?usize,
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

    return HttpTracker{
        .state = if (isHttps) .handshake else .prepareRequest,
        .buffer = .init(alloc),
        .socket = socket,
        .url = urlDupe,
        .uri = uri,
        .handshake = null,
    };
}

pub fn deinit(self: *HttpTracker, alloc: std.mem.Allocator) void {
    alloc.free(self.url);
    self.buffer.deinit();
    std.posix.close(self.socket);
}

pub fn tlsHandshake(self: *HttpTracker, alloc: std.mem.Allocator) !*TlsHandshake {
    return if (self.handshake) |*x| x else {
        utils.assert(self.state == .handshake);
        self.handshake = try .init(alloc, self);
        return &self.handshake.?;
    };
}

// TODO: actually use captured tls cert in connection...
pub const TlsHandshake = struct {
    caBundle: tls.config.cert.Bundle,
    client: tls.nonblock.Client,

    socket: std.posix.socket_t,

    res: ?struct {
        unusedRecv: []const u8,
        send: []const u8,
        sendPos: u32 = 0,
    },

    recvPos: u32 = 0,

    recvBuf: [tls.max_ciphertext_record_len]u8 = undefined,
    sendBuf: [tls.max_ciphertext_record_len]u8 = undefined,

    state: union(enum) {
        needWrite,
        needRead,
        done: tls.Cipher,
    },

    pub fn init(alloc: std.mem.Allocator, tracker: *const HttpTracker) !TlsHandshake {
        var caBundle = try tls.config.cert.fromSystem(alloc);
        defer caBundle.deinit(alloc);

        var hostBuf: [std.Uri.host_name_max]u8 = undefined;
        const host = try tracker.uri.getHost(&hostBuf);

        const client = tls.nonblock.Client.init(.{
            .host = host,
            .root_ca = caBundle,
            .insecure_skip_verify = builtin.is_test,
        });

        return .{
            .caBundle = caBundle,
            .client = client,
            .socket = tracker.socket,
            .state = .needWrite,
            .res = null,
        };
    }

    pub fn deinit(self: *TlsHandshake, alloc: std.mem.Allocator) void {
        self.caBundle.deinit(alloc);
    }

    pub fn write(self: *TlsHandshake) !void {
        if (self.state == .done or self.state == .needRead) return;

        const res = if (self.res) |*r| r else blk: {
            const res = try self.client.run(self.recvBuf[0..self.recvPos], &self.sendBuf);
            self.res = .{
                .unusedRecv = res.unused_recv,
                .send = res.send,
            };

            break :blk &self.res.?;
        };

        const wrote = std.posix.write(self.socket, res.send[res.sendPos..]) catch |err| switch (err) {
            error.WouldBlock => return,
            else => |e| return e,
        };

        res.sendPos += @intCast(wrote);

        utils.assert(res.sendPos <= tls.max_ciphertext_record_len);

        if (res.sendPos == res.send.len) {
            self.recvPos = @intCast(shiftUnused(&self.recvBuf, res.unusedRecv));
            self.res = null;
            self.state = .needRead;

            if (self.client.cipher()) |cipher| {
                self.state = .{ .done = cipher };
            }
        }
    }

    pub fn read(self: *TlsHandshake) !void {
        if (self.state == .done or self.state == .needWrite) return;

        const readCount = std.posix.read(self.socket, self.recvBuf[self.recvPos..]) catch |err| switch (err) {
            error.WouldBlock => return,
            else => |e| return e,
        };

        self.recvPos += @intCast(readCount);

        self.state = .needWrite;
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

    test "initiate handshake" {
        const alloc = std.testing.allocator;

        var torrent = try getTestTorrent(alloc, "./src/test_files/copper-https.torrent");
        defer torrent.deinit(alloc);

        var t: HttpTracker = try .init(alloc, torrent.tiers.items[0].items[0]);
        defer t.deinit(alloc);

        try std.testing.expectEqual(State.handshake, t.state);

        const handshake = try t.tlsHandshake(alloc);

        const KQ = @import("kq.zig");
        var kq: KQ = try .init(alloc);
        defer kq.deinit();

        try kq.subscribe(handshake.socket, .write, 1);
        try kq.subscribe(handshake.socket, .read, 1);
        try kq.disable(handshake.socket, switch (handshake.state) {
            .needWrite => .read,
            .needRead => .write,
            .done => unreachable,
        });
        try kq.addTimer(0, 250, .{ .periodic = false });

        while (try kq.next()) |ev| {
            try std.testing.expectEqual(null, ev.err);
            try std.testing.expect(ev.kind != .timer);

            switch (ev.kind) {
                .timer => unreachable,
                .write => if (handshake.state == .needWrite) {
                    try handshake.write();

                    switch (handshake.state) {
                        .needWrite => {},
                        .needRead => {
                            try kq.disable(handshake.socket, .write);
                            try kq.enable(handshake.socket, .read, 1);
                        },
                        .done => |cipher| {
                            _ = cipher;
                            break;
                        },
                    }
                },
                .read => if (handshake.state == .needRead) {
                    try handshake.read();

                    if (handshake.state == .needWrite) {
                        try kq.disable(handshake.socket, .read);
                        try kq.enable(handshake.socket, .write, 1);
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

pub fn prepareRequest(self: *HttpTracker, stats: *const Stats) !void {
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

    self.state = .sendingRequest;
}

/// true - wrote all, false - still data to be written
pub fn sendRequest(self: *HttpTracker) !bool {
    utils.assert(self.state == .sendingRequest);

    const wrote = std.posix.write(self.socket, self.buffer.written()) catch |err| switch (err) {
        error.WouldBlock => return false,
        else => |e| return e,
    };

    _ = self.buffer.writer.consume(wrote);

    if (self.buffer.writer.end != 0) {
        return false;
    }

    self.state = .readingRequest;
    return true;
}

pub fn readRequest(self: *HttpTracker, alloc: std.mem.Allocator) !?[]u8 {
    utils.assert(self.state == .readingRequest);

    const readCount = 8 * 1024;
    try self.buffer.ensureUnusedCapacity(readCount);

    const wrote = std.posix.read(self.socket, self.buffer.writer.unusedCapacitySlice()[0..readCount]) catch |err| switch (err) {
        error.WouldBlock => return null,
        else => |e| return e,
    };

    self.buffer.writer.end += wrote;

    if (self.buffer.writer.end > std.math.maxInt(u16)) {
        return error.ResponseTooLong;
    }

    const written = self.buffer.written();

    const head = self.parsedHead orelse blk: {
        var hp: std.http.HeadParser = .{};

        const contentStart = hp.feed(written);
        if (hp.state != .finished) {
            return null;
        }

        const head = try std.http.Client.Response.Head.parse(written[0..contentStart]);

        if (head.content_length) |contentLength| if (contentLength > std.math.maxInt(u16)) {
            return error.ResponseTooLong;
        };

        if (head.content_encoding == .compress) return error.UnsupportedCompressionMethod;
        if (head.transfer_encoding == .chunked) return error.UnsupportedTransferEncoding;

        self.parsedHead = .{
            .contentStart = contentStart,
            .contentLength = head.content_length,
            .encoding = head.content_encoding,
        };

        break :blk self.parsedHead.?;
    };

    if (head.contentLength) |contentLength| {
        if (head.contentStart + contentLength > written.len) return null;
    } else if (wrote != 0) return null;

    defer _ = self.buffer.writer.consumeAll();
    const bytes = written[head.contentStart..];

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

const Torrent = @import("torrent.zig");

test "writes correct http request" {
    const requrl = "http://localhost:9000/announce";

    const alloc = std.testing.allocator;
    var t = HttpTracker{
        .buffer = .init(alloc),
        .uri = try .parse(requrl),
        .socket = 0,
        .url = "",
        .handshake = null,
        .state = .prepareRequest,
    };
    defer t.buffer.deinit();

    try t.prepareRequest(&.{
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

    try t.prepareRequest(&.{
        .infoHash = torrent.infoHash,
        .peerId = .{1} ** 20,
        .numWant = 50,
        .downloaded = 0,
        .uploaded = 0,
        .left = torrent.totalLen,
    });

    const KQ = @import("./kq.zig");
    const Bencode = @import("bencode.zig");

    var kq: KQ = try .init(alloc);
    defer kq.deinit();

    try kq.subscribe(t.socket, .write, 1);
    const readyWrite = try kq.next() orelse unreachable;
    try std.testing.expectEqual(null, readyWrite.err);
    try std.testing.expectEqual(.write, readyWrite.kind);

    _ = try t.sendRequest();
    try kq.delete(t.socket, .write);

    try std.testing.expectEqual(0, t.buffer.writer.end);
    try std.testing.expectEqual(State.readingRequest, t.state);

    try kq.subscribe(t.socket, .read, 1);
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

test {
    std.testing.refAllDecls(HttpTracker);
}
