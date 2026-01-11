const std = @import("std");

pub fn hash(slice: []const u8) ![20]u8 {
    var computedHash: [20]u8 = undefined;

    std.crypto.hash.Sha1.hash(slice, computedHash[0..20], .{});

    return computedHash;
}
