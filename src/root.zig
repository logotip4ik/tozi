const std = @import("std");

const bencode = @import("./bencode.zig");

test {
    _ = @import("./http-tracker.zig");
    _ = @import("./torrent.zig");
}
