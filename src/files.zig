const std = @import("std");

const Torrent = @import("torrent.zig");
const proto = @import("proto.zig");

pub const FileRef = struct {
    /// was created right now, or existed in fs before, useful for `collectPieces` function
    new: bool,
    handle: std.fs.File,
    size: usize,
    start: usize,
};

const Self = @This();

files: []FileRef,
totalSize: usize,

pub fn init(alloc: std.mem.Allocator, files: []Torrent.File) !Self {
    var refs = try alloc.alloc(FileRef, files.len);
    var currentPos: usize = 0;

    const cwd = std.fs.cwd();

    for (files, 0..) |file, i| {
        const path = try std.fs.path.join(alloc, file.path);
        defer alloc.free(path);

        if (std.fs.path.dirname(path)) |dir| {
            try cwd.makePath(dir);
        }

        const handle, const new = if (cwd.openFile(path, .{ .mode = .read_write })) |h|
            .{ h, false }
        else |_|
            .{ try cwd.createFile(path, .{ .read = true }), true };
        errdefer handle.close();

        try handle.setEndPos(file.len);

        refs[i] = .{
            .new = new,
            .handle = handle,
            .size = file.len,
            .start = currentPos,
        };

        currentPos += file.len;
    }

    return .{
        .files = refs,
        .totalSize = currentPos,
    };
}

pub fn deinit(self: *Self, alloc: std.mem.Allocator) void {
    for (self.files) |f| f.handle.close();
    alloc.free(self.files);
}

pub fn collectPieces(
    self: *Self,
    alloc: std.mem.Allocator,
    pieces: []const u8,
    torrentPieceLen: u32,
) !std.bit_set.DynamicBitSetUnmanaged {
    const numberOfPieces = pieces.len / 20;
    var bitset: std.bit_set.DynamicBitSetUnmanaged = try .initEmpty(alloc, numberOfPieces);
    errdefer bitset.deinit(alloc);

    const pieceBuf = try alloc.alloc(u8, torrentPieceLen);
    defer alloc.free(pieceBuf);

    var hash: [20]u8 = undefined;

    var fileIdx: u32 = 0;
    var index: u32 = 0;

    var iter = std.mem.window(u8, pieces, 20, 20);
    outer: while (iter.next()) |expected| : (index += 1) {
        const pieceStart = @as(usize, index) * torrentPieceLen;
        const pieceSize = if (pieceStart + torrentPieceLen > self.totalSize)
            self.totalSize - pieceStart
        else
            torrentPieceLen;
        const pieceEnd = pieceStart + pieceSize;

        for (self.files[fileIdx..]) |file| {
            // If the file ends before the piece starts, it's permanently behind us.
            // We increment the persistent fileIdx so the next piece skips it instantly.
            if (file.start + file.size <= pieceStart) {
                fileIdx += 1;
                continue;
            }

            // If the file starts after the piece ends, we've gone past the overlap zone.
            // We stop checking files for THIS piece.
            if (file.start >= pieceEnd) break;

            // If we are here, the file and piece overlap.
            // If any part of the piece is in a 'new' file, skip hashing.
            if (file.new) continue :outer;
        }

        const activeBuf = pieceBuf[0..pieceSize];
        self.readPieceBuf(activeBuf, index, 0, torrentPieceLen) catch continue;

        std.crypto.hash.Sha1.hash(activeBuf, hash[0..20], .{});

        if (std.mem.eql(u8, hash[0..20], expected[0..20])) {
            bitset.set(index);
        }
    }

    return bitset;
}

pub fn readPieceBuf(
    self: *Self,
    buf: []u8,
    index: u32,
    begin: u32,
    torrentPieceLen: u32,
) !void {
    var globalOffset = @as(usize, index) * torrentPieceLen + begin;
    var bufOffset: usize = 0;

    for (self.files) |file| {
        const fileEnd = file.start + file.size;
        if (globalOffset >= fileEnd) continue;

        const readStart = if (globalOffset > file.start)
            globalOffset - file.start
        else
            0;

        const avail = file.size - readStart;
        const rem = buf.len - bufOffset;
        const toRead = @min(avail, rem);

        _ = try file.handle.preadAll(buf[bufOffset .. bufOffset + toRead], readStart);

        bufOffset += toRead;
        globalOffset += toRead;

        if (bufOffset >= buf.len) break;
    }

    if (bufOffset < buf.len) return error.UnexpectedEof;
}

pub fn readPieceData(
    self: *Self,
    alloc: std.mem.Allocator,
    piece: proto.Piece,
    torrentPieceLen: u32,
) ![]const u8 {
    const buf = try alloc.alloc(u8, piece.len);
    errdefer alloc.free(buf);

    try self.readPieceBuf(buf, piece.index, piece.begin, torrentPieceLen);

    return buf;
}

pub fn writePieceData(
    self: Self,
    index: u32,
    torrentPieceLen: u32,
    data: []const u8
) !void {
    var globalOffset = @as(usize, index) * torrentPieceLen;
    var dataOffset: usize = 0;

    for (self.files) |file| {
        const fileEnd = file.start + file.size;

        if (globalOffset >= fileEnd) continue;

        const writeStart = if (globalOffset > file.start)
            globalOffset - file.start
        else
            0;

        // find how much this file can take
        const spaceInFile = file.size - writeStart;
        const rem = data.len - dataOffset;
        const toWrite = @min(spaceInFile, rem);

        try file.handle.pwriteAll(data[dataOffset..][0..toWrite], writeStart);

        dataOffset += toWrite;
        globalOffset += toWrite;

        if (dataOffset >= data.len) break;
    }
}
