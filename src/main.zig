const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");

const tozi = @import("tozi");

const Heap = if (builtin.mode == .Debug) struct {
    gpa: std.heap.DebugAllocator(.{}),

    pub fn init() @This() {
        return .{ .gpa = .init };
    }

    pub fn alloc(self: *@This()) std.mem.Allocator {
        return self.gpa.allocator();
    }

    pub fn deinit(self: *@This()) void {
        _ = self.gpa.deinit();
    }
} else struct {
    pub fn init() @This() {
        return .{};
    }

    pub fn alloc(_: *@This()) std.mem.Allocator {
        return std.heap.smp_allocator;
    }

    pub fn deinit(_: *@This()) void {}
};

const Command = enum {
    download,
    @"continue",
    verify,
    info,
    version,
    help,
};

const command_descriptions: std.static_string_map.StaticStringMap([]const u8) = .initComptime([_]struct { []const u8, []const u8 }{
    .{ "download", "Download torrent from a file or magnet link" },
    .{ "continue", "Check how much of the torrent is already downloaded. Accepts torrent files as well as magnet links" },
    .{ "verify", "Check the integrity of the torrent files. Logs success message if the whole torrent is downloaded" },
    .{ "info", "Display metadata for a torrent file or magnet link (will firstly fetch torrent file for magnet links)" },
    .{ "version", "Show build information" },
    .{ "help", "Show this message" },
});

comptime {
    for (std.meta.fieldNames(Command)) |field| {
        if (command_descriptions.get(field)) |_| {} else {
            @compileError(field ++ " is missing from command_descriptions");
        }
    }
}

pub fn main() !void {
    var heap: Heap = .init();
    defer heap.deinit();

    const alloc = heap.alloc();

    const args = try std.process.argsAlloc(alloc);
    defer std.process.argsFree(alloc, args);

    const stdout = std.fs.File.stdout();
    var stdout_buf: [256]u8 = undefined;
    var out = stdout.writer(&stdout_buf);
    defer out.interface.flush() catch {};

    if (args.len < 2) {
        try printHelp(&out.interface);
        return;
    }

    const command = std.meta.stringToEnum(Command, args[1]) orelse {
        std.log.err("{s} is not recognized as command\n", .{args[1]});
        try printHelp(&out.interface);
        return;
    };

    switch (command) {
        .help => {
            try printHelp(&out.interface);
            return;
        },
        .version => {
            try printVersion(&out.interface);
            return;
        },
        else => if (args.len < 3) {
            std.log.err("missing required file or url parameter\n", .{});
            try printHelp(&out.interface);
            return;
        },
    }

    const torrent_path = args[2];

    const peer_id = tozi.Tracker.generatePeerId();

    var torrent: tozi.Torrent = if (tozi.utils.isMagnet(torrent_path)) blk: {
        var magnet: tozi.Magnet = try .parse(alloc, torrent_path);
        defer magnet.deinit(alloc);

        try tozi.downloadMagnet(alloc, peer_id, &magnet);

        break :blk try .fromMagnet(alloc, &magnet);
    } else blk: {
        const file = std.fs.cwd().openFile(torrent_path, .{}) catch {
            std.log.err("failed openning {s} file", .{torrent_path});
            return;
        };
        defer file.close();

        var buf: [32 * 1024]u8 = undefined;
        var reader = file.reader(&buf);
        const contents = try reader.interface.allocRemaining(alloc, .limited(std.math.maxInt(u32)));
        defer alloc.free(contents);

        break :blk try .fromSlice(alloc, contents);
    };
    defer torrent.deinit(alloc);

    if (command == .info) {
        torrent.value.dump();
        try out.interface.print("info hash: {x}\n", .{torrent.info_hash});
        return;
    }

    var files: tozi.Files = try .init(alloc, torrent.files.items);
    defer files.deinit(alloc);

    var pieces: tozi.PieceManager = if (command == .verify or command == .@"continue") blk: {
        var start = std.time.Timer.start() catch unreachable;

        var bitset = try files.collectPieces(alloc, torrent.pieces, torrent.piece_len);
        defer bitset.deinit(alloc);

        const duration = start.read();
        const durationInS = @as(f64, @floatFromInt(start.read())) / std.time.ns_per_s;
        const mb = @as(f64, @floatFromInt(files.totalSize)) / (1024.0 * 1024.0);

        std.log.info("verified {d:.2} MB in {D} ({d:.2} MB/s)", .{
            mb,
            duration,
            mb / durationInS,
        });

        if (bitset.count() == bitset.bit_length) {
            std.log.info("whole torrent is downloaded.", .{});
        }

        break :blk try .fromBitset(alloc, &torrent, bitset);
    } else try .init(alloc, torrent.pieces);
    defer pieces.deinit(alloc);

    if (command == .verify) {
        return;
    }

    var start = std.time.Timer.start() catch unreachable;

    var ticker = tozi.Ticker{ .tick = 3, .total_pieces = torrent.pieces.len / 20 };

    try tozi.downloadTorrent(.{
        .alloc = alloc,
        .files = &files,
        .pieces = &pieces,
        .ticker = &ticker,
    }, peer_id, &torrent);

    std.log.info("finished in: {D}", .{start.read()});
}

fn printHelp(out: *std.Io.Writer) !void {
    try out.writeAll(
        \\tozi - torrent leecher (downloader) built in zig, fast, efficient and small
        \\
        \\USAGE:
        \\  tozi <COMMAND> [FILE_OR_URL]
        \\
        \\COMMANDS:
        \\
    );

    const command_name_len_max = comptime blk: {
        var len = 0;

        for (std.meta.fieldNames(Command)) |field| {
            if (field.len > len) len = field.len;
        }

        break :blk len;
    };

    for (std.meta.fieldNames(Command)) |field| {
        const desc = command_descriptions.get(field) orelse unreachable;

        try out.print("  {s}", .{field});
        for (field.len..command_name_len_max + 2) |_| try out.writeByte(' ');
        try out.print("{s}\n", .{ desc });
    }

    try out.writeByte('\n');

    try out.writeAll(
        \\EXAMPLES:
        \\  tozi download "magnet:?xt=urn:btih:..."
        \\  tozi download ./film.torrent
        \\  tozi version
        \\
    );
}

fn printVersion(out: *std.Io.Writer) !void {
    try out.print("{f} {t}\n", .{ build_options.version, builtin.mode });
}
