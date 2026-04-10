const std = @import("std");

const Bencode = @import("bencode.zig");
const Torrent = @import("torrent.zig");

const utils = @import("utils.zig");
const proto = @import("proto.zig");

info_hash: [20]u8 = undefined,

display_name: []const u8 = "",

trackers: std.array_list.Aligned([]const u8, null) = .empty,

peers: std.array_list.Aligned(std.net.Address, null) = .empty,

buffer: ?[]u8 = null,

received: ?std.bit_set.DynamicBitSetUnmanaged = null,

const Magnet = @This();

pub const MessageType = enum(u8) {
    Request = 0,
    Data = 1,
    Reject = 2,
};

pub fn deinit(self: *Magnet, alloc: std.mem.Allocator) void {
    for (self.trackers.items) |x| alloc.free(x);
    self.trackers.deinit(alloc);

    self.peers.deinit(alloc);

    if (self.buffer) |x| alloc.free(x);
    if (self.received) |*x| x.deinit(alloc);
}

pub fn parse(alloc: std.mem.Allocator, link: []const u8) !Magnet {
    utils.assert(utils.isMagnet(link));
    utils.assert(link.len > "magnet:?".len);

    var magnet = Magnet{};
    errdefer magnet.deinit(alloc);

    var buffer: [512]u8 = undefined;

    var iter = std.mem.splitScalar(u8, link["magnet:?".len..], '&');
    while (iter.next()) |chunk| {
        if (chunk.len < 4) return error.CorruptMagnetLink;

        const equal_index = std.mem.indexOfScalar(u8, chunk, '=') orelse return error.CorruptMagnetLink;

        const prefix = chunk[0..equal_index];
        const value = chunk[equal_index + 1 ..];

        if (std.mem.eql(u8, prefix, "xt")) {
            const prefix_v1 = "urn:btih:";
            const prefix_v2 = "urn:btmh:";

            if (std.mem.startsWith(u8, value, prefix_v1)) {
                const topic = value[prefix_v1.len..];
                if (topic.len == 40) {
                    const bytes = try std.fmt.hexToBytes(&buffer, topic);
                    @memcpy(&magnet.info_hash, bytes);
                } else if (topic.len == 32) {
                    try utils.base32ToBytes(&magnet.info_hash, topic);
                } else {
                    return error.CorruptTopic;
                }
            } else if (std.mem.startsWith(u8, value, prefix_v2)) {
                return error.UnsupportedMagnetLink;
            } else {
                return error.CorruptMagnetLink;
            }
        } else if (std.mem.eql(u8, prefix, "dn")) {
            magnet.display_name = value;
        } else if (std.mem.eql(u8, prefix, "tr")) {
            const tracker_component = std.Uri.Component{ .percent_encoded = value };
            const decoded_value = try tracker_component.toRawMaybeAlloc(alloc);
            errdefer alloc.free(decoded_value);

            try magnet.trackers.append(alloc, decoded_value);
        } else if (std.mem.eql(u8, prefix, "x.pe")) {
            const peer_component = std.Uri.Component{ .percent_encoded = value };
            const decoded_peer = try peer_component.toRaw(&buffer);

            const last_colon = std.mem.lastIndexOfScalar(u8, decoded_peer, ':') orelse return error.CorruptMagnetLink;

            const host = decoded_peer[0..last_colon];
            const port_str = decoded_peer[last_colon + 1 ..];

            if (host.len > 2 and host[0] == '[' and host[host.len - 1] == ']') {
                // TODO: add support for ip v6
                continue;
            }

            const port = std.fmt.parseInt(u16, port_str, 10) catch return error.CorruptMagnetLink;
            const address = std.net.Address.parseIp(host, port) catch return error.CorruptMagnetLink;

            try magnet.peers.append(alloc, address);
        }
    }

    return magnet;
}

test "parse magent link" {
    const alloc = std.testing.allocator;

    const link = "magnet:?xt=urn:btih:F32A417A94F06EA9008D1A20B9A36D6FE07D8082" // prevent zls
        ++ "&dn=Mercy.2026.1080p.WEBRip.AAC5.1.10bits.x265-Rapta" // from
        ++ "&tr=udp%3A%2F%2Fopen.tracker.cl%3A1337%2Fannounce" // formatting
        ++ "&tr=http%3A%2F%2Fnyaa.tracker.wf%3A7777%2Fannounce" // this
        ++ "&x.pe=127.0.0.1:8080";

    var magnet: Magnet = try .parse(alloc, link);
    defer magnet.deinit(alloc);

    try std.testing.expectEqualStrings(&[_]u8{ 0xF3, 0x2A, 0x41, 0x7A, 0x94, 0xF0, 0x6E, 0xA9, 0x00, 0x8D, 0x1A, 0x20, 0xB9, 0xA3, 0x6D, 0x6F, 0xE0, 0x7D, 0x80, 0x82 }, &magnet.info_hash);
    try std.testing.expectEqualStrings("Mercy.2026.1080p.WEBRip.AAC5.1.10bits.x265-Rapta", magnet.display_name);
    try std.testing.expectEqualDeep(&[_][]const u8{
        "udp://open.tracker.cl:1337/announce",
        "http://nyaa.tracker.wf:7777/announce",
    }, magnet.trackers.items);

    try std.testing.expectEqual(1, magnet.peers.items.len);
    try std.testing.expectEqualDeep(std.net.Ip4Address.init([_]u8{ 127, 0, 0, 1 }, 8080), magnet.peers.items[0].in);
}

pub fn writeInfoTableRequests(
    self: *Magnet,
    alloc: std.mem.Allocator,
    request_key: u8,
    metadata_size: u32,
    peer_writer: *std.Io.Writer,
) !void {
    if (metadata_size > std.math.maxInt(u32)) {
        return error.MetadataTooBig;
    }

    const total_pieces = (metadata_size + (Torrent.BLOCK_SIZE - 1)) / Torrent.BLOCK_SIZE;
    if (self.buffer == null) {
        self.buffer = try alloc.alloc(u8, metadata_size);
        self.received = try .initEmpty(alloc, total_pieces);
    }

    var extended_data: Bencode = .{ .inner = .{ .dict = .empty } };
    defer extended_data.inner.dict.deinit(alloc);

    try extended_data.inner.dict.put(alloc, "msg_type", Bencode{
        .inner = .{ .int = @intFromEnum(MessageType.Request) },
    });

    try extended_data.inner.dict.put(alloc, "piece", Bencode{
        .inner = .{ .int = 0 },
    });

    var buffer: [1024]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buffer);

    for (0..total_pieces) |i| {
        defer w.end = 0;

        extended_data.inner.dict.putAssumeCapacity("piece", Bencode{
            .inner = .{ .int = @intCast(i) },
        });

        try extended_data.encode(&w);
        const extended_data_encoded = w.buffered();

        const extended_message: proto.Message = .{ .extended = .{
            .id = request_key,
            .len = @intCast(extended_data_encoded.len),
        } };

        try extended_message.writeMessage(peer_writer, extended_data_encoded);
    }
}

pub fn receivePiece(self: *Magnet, alloc: std.mem.Allocator, bytes: []const u8) !void {
    var r: std.Io.Reader = .fixed(bytes);
    var msg: Bencode = try .decode(alloc, &r, 0);
    defer msg.deinit(alloc);

    const msg_dict = switch (msg.inner) {
        .dict => |d| d,
        else => return error.CorruptMessage,
    };

    const msg_type: MessageType = if (msg_dict.get("msg_type")) |x| switch (x.inner) {
        .int => |int| if (std.enums.fromInt(MessageType, int)) |msg_type|
            msg_type
        else
            return error.InvalidMessageType,
        else => return error.InvalidMessageTypeType,
    } else return error.MissingMsgType;

    const piece: u32 = if (msg_dict.get("piece")) |x| switch (x.inner) {
        .int => |int| if (int >= 0 and int < std.math.maxInt(u32))
            @intCast(int)
        else
            return error.InvalidPiece,
        else => return error.InvalidPieceType,
    } else return error.MissingPiece;

    const data = if (bytes.len > msg.len)
        bytes[msg.len..]
    else
        return error.CorruptMessage;

    const received = if (self.received) |*x| x else return error.ReceivedNotInitialized;
    const buffer = if (self.buffer) |x| x else return error.BufferNotInitialized;

    switch (msg_type) {
        .Request => return error.UnexpectedMessage,
        .Reject => return error.RejectPiece,
        .Data => {
            const offset = piece * Torrent.BLOCK_SIZE;

            if (offset + data.len > buffer.len) return error.InvalidPiece;
            if (received.isSet(piece)) return;

            @memcpy(buffer[offset .. offset + data.len], data);
            received.set(piece);
        },
    }
}

pub fn isComplete(self: *const Magnet) bool {
    return if (self.received) |x| x.count() == x.bit_length else false;
}

pub fn isValid(self: *const Magnet) bool {
    const buffer = self.buffer orelse return false;

    var hash: [20]u8 = undefined;

    std.crypto.hash.Sha1.hash(buffer, &hash, .{});

    return std.mem.eql(u8, hash[0..20], self.info_hash[0..20]);
}
