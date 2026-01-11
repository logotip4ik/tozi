const std = @import("std");

const Torrent = @import("torrent.zig");

pub const FileRef = struct {
    handle: std.fs.File,
    size: usize,
    start: usize,
};

const Self = @This();

alloc: std.mem.Allocator,
files: []FileRef,
pieceLen: u32,

pub fn init(alloc: std.mem.Allocator, torrent: Torrent) !Self {
    var refs = try alloc.alloc(FileRef, torrent.files.items.len);
    var currentPos: usize = 0;

    var cwd = if (torrent.dirname) |name|
        try std.fs.cwd().makeOpenPath(name, .{})
    else
        std.fs.cwd();
    defer if (torrent.dirname) |_| cwd.close();

    for (torrent.files.items, 0..) |file, i| {
        const path = try std.fs.path.join(alloc, file.path);
        defer alloc.free(path);

        if (std.fs.path.dirname(path)) |dir| {
            try cwd.makePath(dir);
        }

        const handle = try cwd.createFile(path, .{ .read = true });
        errdefer handle.close();

        try handle.setEndPos(file.len);

        refs[i] = .{
            .handle = handle,
            .size = file.len,
            .start = currentPos,
        };

        currentPos += file.len;
    }

    return .{
        .alloc = alloc,
        .files = refs,
        .pieceLen = torrent.pieceLen,
    };
}

pub fn deinit(self: *Self) void {
    for (self.files) |f| f.handle.close();
    self.alloc.free(self.files);
}

pub fn readPiece(self: *Self, alloc: std.mem.Allocator, index: u32, begin: u32, len: u32) ![]u8 {
    const buf = try alloc.alloc(u8, len);
    errdefer alloc.free(buf);

    var globalOffset = @as(usize, index) * self.pieceLen + begin;
    var bufOffset: usize = 0;

    for (self.files) |file| {
        const fileEnd = file.start + file.size;
        if (globalOffset >= fileEnd) continue;

        const readStart = if (globalOffset > file.start)
            globalOffset - file.start
        else
            0;

        const avail = file.size - readStart;
        const rem = len - bufOffset;
        const toRead = @min(avail, rem);

         _ = try file.handle.preadAll(buf[bufOffset..][0..toRead], readStart);

        bufOffset += toRead;
        globalOffset += toRead;

        if (bufOffset >= len) break;
    }

    if (bufOffset < len) return error.UnexpectedEof;
    return buf;
}

pub fn writePiece(self: Self, index: u32, data: []const u8) !void {
    var globalOffset = @as(usize, index) * self.pieceLen;
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
