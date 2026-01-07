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

pub fn init(alloc: std.mem.Allocator, files: []const Torrent.File, pieceLen: u32) !Self {
    var refs = try alloc.alloc(FileRef, files.len);
    var currentPos: usize = 0;

    const cwd = std.fs.cwd();

    for (files, 0..) |file, i| {
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
        .pieceLen = pieceLen,
    };
}

pub fn deinit(self: *Self) void {
    for (self.files) |f| f.handle.close();
    self.alloc.free(self.files);
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

        var writer = file.handle.writer(&.{});
        try writer.seekTo(writeStart);
        try writer.interface.writeAll(data[dataOffset..][0..toWrite]);

        dataOffset += toWrite;
        globalOffset += toWrite;

        if (dataOffset >= data.len) break;
    }
}
