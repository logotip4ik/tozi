const std = @import("std");
const builtin = @import("builtin");

const Tls = @import("tls");
const utils = @import("utils.zig");
const Socket = @import("socket.zig");
const Bencode = @import("bencode.zig");
const tracker_utils = @import("./tracker-utils.zig");

const TrackerHttp = @This();

const State = enum {
    handshake,
    prepare,
    send,
    read,
};

state: State,

socket: *Socket,
socketPosix: ?Socket.Posix,

rng: std.Random.IoSource,

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
    encoding: std.http.ContentEncoding,
    transfer: union(enum) {
        chunked: struct { start: usize, headerLen: ?usize, len: ?usize },
        length: ?usize,
    },
} = null,

pub fn init(
    self: *TrackerHttp,
    alloc: std.mem.Allocator,
    io: std.Io,
    url: []const u8,
) !void {
    const isHttp = utils.isHttp(url);
    const isHttps = utils.isHttps(url);
    utils.assert(isHttp or isHttps);

    const urlDupe = try alloc.dupe(u8, url);
    errdefer alloc.free(urlDupe);

    const uri: std.Uri = try .parse(urlDupe);
    const port: u16 = if (uri.port) |x| x else if (isHttps) 443 else 80;

    var host_buffer: [std.Io.net.HostName.max_len]u8 = undefined;
    const host = try uri.getHost(&host_buffer);

    var elem_buf: [16]std.Io.net.HostName.LookupResult = undefined;
    var queue: std.Io.Queue(std.Io.net.HostName.LookupResult) = .init(&elem_buf);

    var lookup = io.async(std.Io.net.HostName.lookup, .{
        host,
        io,
        &queue,
        .{ .port = port },
    });
    defer lookup.cancel(io) catch {};

    const socket: std.posix.fd_t = while (queue.getOne(io)) |result| {
        switch (result) {
            .address => |addr| {
                break try tracker_utils.connectToAddress(&addr, .tcp);
            },
            .canonical_name => {},
        }
    } else |err| switch (err) {
        error.Canceled => unreachable,
        else => return err,
    };
    errdefer std.Io.Threaded.closeFd(socket);

    self.* = TrackerHttp{
        .state = if (isHttps) .handshake else .prepare,
        .buffer = .init(alloc),
        .socket = undefined,
        .socketPosix = .init(socket),
        .url = urlDupe,
        .uri = uri,
        .tls = .none,
        .rng = .{ .io = io },
    };

    self.socket = &self.socketPosix.?.interface;
    if (isHttps) {
        self.tls = .{ .handshake = try .init(
            alloc,
            io,
            host.bytes,
            self.socket,
            self.rng.interface(),
        ) };
    }
}

pub fn deinit(self: *TrackerHttp, alloc: std.mem.Allocator) void {
    alloc.free(self.url);
    self.buffer.deinit();
    self.chunks.deinit(alloc);
    self.encryptedBuf.deinit(alloc);

    switch (self.tls) {
        .handshake => |*h| h.deinit(alloc),
        else => {},
    }

    if (self.socketPosix) |x| std.Io.Threaded.closeFd(x.fd);
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

    pub fn init(
        alloc: std.mem.Allocator,
        io: std.Io,
        host: []const u8,
        socket: *Socket,
        rng: std.Random,
    ) !TlsHandshake {
        var ca_bundle = try Tls.config.cert.fromSystem(alloc, io);
        errdefer ca_bundle.deinit(alloc);

        const client = Tls.nonblock.Client.init(.{
            .host = host,
            .root_ca = ca_bundle,
            .insecure_skip_verify = builtin.is_test or builtin.mode == .Debug,
            .now = std.Io.Clock.real.now(io),
            .rng = rng,
        });

        return .{
            .caBundle = ca_bundle,
            .client = client,
            .socket = socket,
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
        if (std.testing.environ.containsUnemptyConstant("GITHUB_ACTIONS")) {
            return error.SkipZigTest;
        }

        const io = std.testing.io;
        const alloc = std.testing.allocator;

        var torrent = try getTestTorrent(alloc, io, "./src/test_files/copper-https.torrent");
        defer torrent.deinit(alloc);

        var t: TrackerHttp = undefined;
        try t.init(alloc, io, torrent.tiers.items[0].items[0]);
        defer t.deinit(alloc);

        const socket = t.socketPosix.?.fd;

        try std.testing.expectEqual(State.handshake, t.state);

        const handshake = &t.tls.handshake;

        const KQ = @import("kq.zig");
        var kq: KQ = try .init();
        defer kq.deinit();

        try kq.subscribe(socket, .write, 1);
        try kq.subscribe(socket, .read, 1);
        switch (handshake.state) {
            .write => try kq.disable(socket, .read),
            .read => try kq.disable(socket, .write),
            .done => unreachable,
        }

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

pub fn prepareRequest(self: *TrackerHttp, alloc: std.mem.Allocator, stats: *const tracker_utils.Stats) !void {
    utils.assert(self.state == .prepare);

    const w = &self.buffer.writer;
    _ = w.consumeAll();

    try w.writeAll("GET ");

    try self.uri.writeToStream(w, .{ .path = true });
    try utils.writeQueryToStream(w, self.uri, &[_]utils.QueryParam{
        .{ "info_hash", .{ .string = &stats.info_hash } },
        .{ "peer_id", .{ .string = &stats.peer_id } },
        .{ "port", .{ .int = stats.port } },
        .{ "uploaded", .{ .int = stats.uploaded } },
        .{ "downloaded", .{ .int = stats.downloaded } },
        .{ "left", .{ .int = stats.left } },
        .{ "compact", .{ .int = 1 } },
        .{ "key", .{ .string = stats.peer_id[16..20] } },
        .{ "numwant", .{ .int = stats.num_want } },
        .{
            "event",
            if (stats.event == .none) .skip else .{ .string = @tagName(stats.event) },
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

    self.state = .send;
}

/// true - wrote all, false - still data to be written
pub fn sendRequest(self: *TrackerHttp) !bool {
    utils.assert(self.state == .send);

    const wrote = try self.socket.write(self.buffer.written()) orelse return false;
    _ = self.buffer.writer.consume(wrote);

    if (self.buffer.writer.end != 0) {
        return false;
    }

    self.state = .read;
    return true;
}

pub fn readRequest(self: *TrackerHttp, alloc: std.mem.Allocator) !?[]u8 {
    utils.assert(self.state == .read);

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

pub fn parseIntoAnnounce(alloc: std.mem.Allocator, bytes: []const u8, announce: *tracker_utils.AnnounceResponse) !void {
    var reader: std.Io.Reader = .fixed(bytes);

    var value: Bencode = try .decode(alloc, &reader, 0);
    defer value.deinit(alloc);

    if (value.inner.dict.get("failure reason")) |x| switch (x.inner) {
        .string => |failure_reason| {
            std.log.err("received err from tracker: {s}", .{failure_reason});
            return error.FailedAnnouncement;
        },
        else => return error.FailedAnnouncement,
    };

    if (value.inner.dict.get("interval")) |x| switch (x.inner) {
        .int => |interval| {
            if (interval < 0) return error.InvalidInterval;

            announce.interval = @intCast(interval);
        },
        else => return error.MissingInternal,
    };

    if (value.inner.dict.get("peers")) |x| switch (x.inner) {
        .string => |peers| blk: {
            if (peers.len == 0) break :blk;
            if (@rem(peers.len, 6) != 0) return error.InvalidPeers;

            var iter = std.mem.window(u8, peers, 6, 6);
            while (iter.next()) |peer| {
                try announce.peers.append(
                    alloc,
                    utils.parseCompactAddress(peer[0..6].*),
                );
            }
        },
        else => return error.MissingPeers,
    };

    if (value.inner.dict.get("min interval")) |x| switch (x.inner) {
        .int => |interval_min| if (interval_min >= 0) {
            announce.interval_min = @intCast(interval_min);
        },
        else => {},
    };

    if (value.inner.dict.get("complete")) |x| switch (x.inner) {
        .int => |complete| if (complete >= 0) {
            announce.complete = @intCast(complete);
        },
        else => {},
    };

    if (value.inner.dict.get("incomplete")) |x| switch (x.inner) {
        .int => |incomplete| if (incomplete >= 0) {
            announce.incomplete = @intCast(incomplete);
        },
        else => {},
    };

    if (value.inner.dict.get("external ip")) |x| switch (x.inner) {
        .string => |external_ip| if (external_ip.len == 4) {
            announce.external_ip = external_ip[0..4].*;
        },
        else => {},
    };
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
    var t = TrackerHttp{
        .buffer = .init(alloc),
        .uri = try .parse(requrl),
        .socket = undefined,
        .socketPosix = null,
        .url = "",
        .tls = .none,
        .state = .prepare,
        .rng = .{ .io = std.testing.io },
    };
    defer t.buffer.deinit();

    try t.prepareRequest(alloc, &.{
        .info_hash = .{1} ** 20,
        .peer_id = .{1} ** 20,
        .num_want = 0,
        .downloaded = 0,
        .uploaded = 0,
        .left = 0,
        .event = .started,
    });

    const expectedReqString = "GET /announce?info_hash=%01%01%01%01%01%01%01%01%01%01%01%01%01%01%01%01%01%01%01%01&peer_id=%01%01%01%01%01%01%01%01%01%01%01%01%01%01%01%01%01%01%01%01&port=6889&uploaded=0&downloaded=0&left=0&compact=1&key=%01%01%01%01&numwant=0&event=started HTTP/1.1\r\n" ++
        "host: localhost:9000\r\n" ++
        "user-agent: tozi/0.0.1\r\n" ++
        "connection: close\r\n" ++
        "accept-encoding: gzip, deflate\r\n\r\n";

    try std.testing.expectEqualStrings(expectedReqString, t.buffer.written());
}

fn getTestTorrent(alloc: std.mem.Allocator, io: std.Io, path: []const u8) !Torrent {
    const torrentFile = std.Io.Dir.cwd().openFile(io, path, .{}) catch unreachable;
    defer torrentFile.close(io);

    var reader_buf: [10 * 1024]u8 = undefined;
    var reader = torrentFile.reader(io, &reader_buf);

    const torrentSlice = try reader.interface.allocRemaining(alloc, .limited(10 * 1024));
    defer alloc.free(torrentSlice);

    return try .fromSlice(alloc, torrentSlice);
}

test "make request" {
    if (std.testing.environ.containsUnemptyConstant("GITHUB_ACTIONS")) {
        return error.SkipZigTest;
    }

    const alloc = std.testing.allocator;
    const io = std.testing.io;

    var torrent = try getTestTorrent(alloc, io, "./src/test_files/copper.torrent");
    defer torrent.deinit(alloc);

    var t: TrackerHttp = undefined;
    try t.init(alloc, io, torrent.tiers.items[0].items[0]);
    defer t.deinit(alloc);
    const socket = t.socketPosix.?.fd;

    const stats: tracker_utils.Stats = .{
        .info_hash = torrent.info_hash,
        .peer_id = .{1} ** 20,
        .num_want = 50,
        .downloaded = 0,
        .uploaded = 0,
        .left = torrent.total_len,
        .event = .started,
    };

    try t.prepareRequest(alloc, &stats);

    const KQ = @import("./kq.zig");

    var kq: KQ = try .init();
    defer kq.deinit();

    try kq.subscribe(socket, .write, 1);
    const readyWrite = try kq.next() orelse unreachable;
    try std.testing.expectEqual(null, readyWrite.err);
    try std.testing.expectEqual(.write, readyWrite.kind);

    _ = try t.sendRequest();
    try kq.delete(socket, .write);

    try std.testing.expectEqual(0, t.buffer.writer.end);
    try std.testing.expectEqual(State.read, t.state);

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
    if (std.testing.environ.containsUnemptyConstant("GITHUB_ACTIONS")) {
        return error.SkipZigTest;
    }

    const alloc = std.testing.allocator;
    const io = std.testing.io;

    var torrent = try getTestTorrent(alloc, io, "./src/test_files/copper-https.torrent");
    defer torrent.deinit(alloc);

    const KQ = @import("./kq.zig");

    var t: TrackerHttp = undefined;
    try t.init(alloc, io, torrent.tiers.items[0].items[0]);
    defer t.deinit(alloc);

    const socket = t.socketPosix.?.fd;

    const stats: tracker_utils.Stats = .{
        .info_hash = torrent.info_hash,
        .peer_id = .{1} ** 20,
        .num_want = 50,
        .downloaded = 0,
        .uploaded = 0,
        .left = torrent.total_len,
        .event = .started,
    };

    var kq: KQ = try .init();
    defer kq.deinit();

    try kq.subscribe(socket, .write, 1);
    try kq.addTimer(0, 100, .{ .periodic = false });

    while (try kq.next()) |e| {
        try std.testing.expect(e.kind != .timer);

        sw: switch (t.state) {
            .handshake => {
                const handshake = &t.tls.handshake;

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
                                t.state = .prepare;

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
            .prepare => {
                try t.prepareRequest(alloc, &stats);
                try kq.subscribe(socket, .write, 1);
            },
            .send => {
                const ready = try t.sendRequest();

                if (!ready) continue;

                kq.delete(socket, .write) catch {};
                try kq.subscribe(socket, .read, 1);
            },
            .read => {
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
    const io = std.testing.io;

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

        var t: TrackerHttp = .{
            .socket = &a.interface,
            .socketPosix = null,
            .buffer = .init(alloc),
            .state = .read,
            .tls = .none,
            .url = undefined,
            .uri = undefined,
            .rng = .{ .io = io },
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
    std.testing.refAllDecls(TrackerHttp);
}
