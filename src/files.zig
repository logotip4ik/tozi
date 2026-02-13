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

const Files = @This();

files: []FileRef,
totalSize: usize,

pub fn init(alloc: std.mem.Allocator, files: []Torrent.File) !Files {
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

pub fn deinit(self: *Files, alloc: std.mem.Allocator) void {
    for (self.files) |f| f.handle.close();
    alloc.free(self.files);
}

pub fn collectPieces(
    self: *Files,
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

    var sreader: SReader = try .init(alloc, torrentPieceLen);
    defer sreader.deinit(alloc);

    var i: usize = 0;
    while (i < numberOfPieces) : (i += 1) {
        const remainingTotal = self.totalSize - (i * torrentPieceLen);
        const toread = @min(remainingTotal, torrentPieceLen);

        const piece = try sreader.next(toread, self.files);

        std.crypto.hash.Sha1.hash(piece, &hash, .{});

        const hashVec: @Vector(20, u8) = hash;
        const expectedVec: @Vector(20, u8) = pieces[i * 20 ..][0..20].*;

        if (@reduce(.And, hashVec == expectedVec)) {
            bitset.set(i);
        }
    }

    return bitset;
}

pub fn readPieceBuf(
    self: *Files,
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
    self: *Files,
    alloc: std.mem.Allocator,
    piece: proto.Piece,
    torrentPieceLen: u32,
) ![]const u8 {
    const buf = try alloc.alloc(u8, piece.len);
    errdefer alloc.free(buf);

    try self.readPieceBuf(buf, piece.index, piece.begin, torrentPieceLen);

    return buf;
}

pub fn writePieceData(self: Files, index: u32, torrentPieceLen: u32, data: []const u8) !void {
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

const SReader = struct {
    currentFileIdx: usize = 0,
    currentFileOffset: usize = 0,
    mptr: ?[]align(std.heap.page_size_min) u8 = null,

    scratchBuf: []u8,

    pub fn init(alloc: std.mem.Allocator, torrentPieceLen: usize) !SReader {
        return SReader{
            .scratchBuf = try alloc.alloc(u8, torrentPieceLen),
        };
    }

    pub fn deinit(self: *SReader, alloc: std.mem.Allocator) void {
        self.unmapCurrent();
        alloc.free(self.scratchBuf);
    }

    pub fn next(self: *SReader, len: usize, files: []const FileRef) ![]const u8 {
        const mptr = try self.ensureMapped(files);

        const currentFileSize = files[self.currentFileIdx].size;
        const available = currentFileSize - self.currentFileOffset;

        if (len <= available) {
            const slice = mptr[self.currentFileOffset .. self.currentFileOffset + len];

            self.currentFileOffset += len;

            return slice;
        }

        var destOffset: usize = 0;
        var remaining = len;

        while (remaining > 0) {
            const nextMptr = try self.ensureMapped(files);

            const fileSize = files[self.currentFileIdx].size;
            const fileAvail = fileSize - self.currentFileOffset;

            const toCopy = @min(remaining, fileAvail);

            if (toCopy > 0) {
                @branchHint(.unlikely);
                const src = nextMptr[self.currentFileOffset .. self.currentFileOffset + toCopy];
                @memcpy(self.scratchBuf[destOffset .. destOffset + toCopy], src);

                destOffset += toCopy;
                remaining -= toCopy;
                self.currentFileOffset += toCopy;
            }

            if (self.currentFileOffset == fileSize) {
                self.advanceFile();
            }
        }

        return self.scratchBuf[0..len];
    }

    fn advanceFile(self: *SReader) void {
        self.unmapCurrent();
        self.currentFileIdx += 1;
        self.currentFileOffset = 0;
    }

    fn unmapCurrent(self: *SReader) void {
        if (self.mptr) |ptr| {
            @branchHint(.likely);
            std.posix.munmap(ptr);
            self.mptr = null;
        }
    }

    fn ensureMapped(self: *SReader, files: []const FileRef) ![]align(std.heap.page_size_min) u8 {
        if (self.mptr) |mptr| {
            @branchHint(.likely);
            return mptr;
        }

        if (self.currentFileIdx >= files.len) {
            @branchHint(.cold);
            return error.EndOfStream;
        }

        const file = files[self.currentFileIdx];

        if (file.size == 0) {
            @branchHint(.cold);
            self.currentFileIdx += 1;
            self.currentFileOffset = 0;
            return self.ensureMapped(files);
        }

        const ptr = try std.posix.mmap(
            null,
            file.size,
            std.posix.PROT.READ,
            .{ .TYPE = .PRIVATE },
            file.handle.handle,
            0,
        );

        // Essential optimization
        _ = std.posix.madvise(ptr.ptr, file.size, std.posix.MADV.SEQUENTIAL) catch {};

        self.mptr = ptr;

        return ptr;
    }
};
