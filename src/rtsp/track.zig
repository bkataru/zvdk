//! Track management and RTP reception

const std = @import("std");
const common = @import("../common.zig");
const rtsp = @import("../rtsp.zig");
const MediaType = rtsp.MediaType;
const ProtoType = rtsp.ProtoType;
const Error = common.Error;

/// RTP packet header structure
pub const RtpHeader = struct {
    version: u2,
    padding: bool,
    extension: bool,
    csrc_count: u4,
    marker: bool,
    payload_type: u7,
    sequence_number: u16,
    timestamp: u32,
    ssrc: u32,
    csrc: [15]u32,

    /// Parse RTP header from buffer
    pub fn parse(data: []const u8) !RtpHeader {
        if (data.len < 12) return Error.RtpPacketError;

        return RtpHeader{
            .version = @as(u2, @truncate((data[0] >> 6) & 0x03)),
            .padding = (data[0] & 0x20) != 0,
            .extension = (data[0] & 0x10) != 0,
            .csrc_count = @as(u4, @truncate(data[0] & 0x0F)),
            .marker = (data[1] & 0x80) != 0,
            .payload_type = @as(u7, @truncate(data[1] & 0x7F)),
            .sequence_number = (@as(u16, data[2]) << 8) | data[3],
            .timestamp = (@as(u32, data[4]) << 24) | (@as(u32, data[5]) << 16) | (@as(u32, data[6]) << 8) | data[7],
            .ssrc = (@as(u32, data[8]) << 24) | (@as(u32, data[9]) << 16) | (@as(u32, data[10]) << 8) | data[11],
            .csrc = [_]u32{0} ** 15,
        };
    }

    /// Get size of header in bytes
    pub fn getSize(self: *const RtpHeader) usize {
        const base_size = 12;
        const csrc_size = @as(usize, self.csrc_count) * 4;
        return base_size + csrc_size;
    }
};

/// RTP packet structure
pub const RtpPacket = struct {
    header: RtpHeader,
    payload: []const u8,
    allocator: std.mem.Allocator,

    /// Create RTP packet from raw data
    pub fn parse(allocator: std.mem.Allocator, data: []const u8) !RtpPacket {
        const header = try RtpHeader.parse(data);
        const header_size = header.getSize();

        if (data.len < header_size) return Error.RtpPacketError;

        const payload = try allocator.dupe(u8, data[header_size..]);
        errdefer allocator.free(payload);

        return RtpPacket{
            .header = header,
            .payload = payload,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *RtpPacket) void {
        self.allocator.free(self.payload);
    }
};

/// RTSP media track
pub const Track = struct {
    media_type: MediaType,
    codec: []const u8,
    control_url: []const u8,
    port: u16,
    protocol: ProtoType,
    payload_type: u8,
    clock_rate: u32,
    allocator: std.mem.Allocator,

    // UDP socket for RTP reception
    rtp_socket: ?i32,
    rtcp_socket: ?i32,

    // Packet buffer
    packet_buffer: std.ArrayList(RtpPacket),
    last_seq: u16,

    const Self = @This();

    /// Create a new track from media info
    pub fn init(allocator: std.mem.Allocator, info: rtsp.MediaInfo) !Self {
        return Self{
            .media_type = info.media_type,
            .codec = try allocator.dupe(u8, info.codec),
            .control_url = try allocator.dupe(u8, info.control_url),
            .port = info.port,
            .protocol = info.protocol,
            .payload_type = info.payload_type,
            .clock_rate = info.clock_rate,
            .allocator = allocator,
            .rtp_socket = null,
            .rtcp_socket = null,
            .packet_buffer = std.ArrayList(RtpPacket).init(allocator),
            .last_seq = 0,
        };
    }

    /// Setup RTP reception
    pub fn setup(self: *Self, port: u16) !void {
        // Create UDP sockets for RTP and RTCP
        self.rtp_socket = try std.posix.socket(std.posix.AF.INET, std.posix.SOCK.DGRAM, std.posix.IPPROTO.UDP);
        self.rtcp_socket = try std.posix.socket(std.posix.AF.INET, std.posix.SOCK.DGRAM, std.posix.IPPROTO.UDP);
        
        // Bind to the specified port (even though we're not using it yet)
        _ = port;
    }

    /// Receive RTP packet
    pub fn receivePacket(self: *Self) !?RtpPacket {
        var buf: [2048]u8 = undefined;
        const addr = try std.os.recvfrom(self.rtp_socket.?, &buf, 0, null);

        // Parse RTP packet
        const packet = try RtpPacket.parse(self.allocator, buf[0..addr.bytes]);
        errdefer packet.deinit();

        // Check sequence number
        if (self.packet_buffer.items.len > 0) {
            const expected_seq = self.last_seq +% 1;
            if (packet.header.sequence_number != expected_seq) {
                // Out of order packet, buffer it
                try self.packet_buffer.append(packet);
                return null;
            }
        }

        self.last_seq = packet.header.sequence_number;

        // Check buffered packets
        while (self.packet_buffer.items.len > 0) {
            const next_seq = self.last_seq +% 1;
            const next_packet = for (self.packet_buffer.items, 0..) |p, i| {
                if (p.header.sequence_number == next_seq) break i;
            } else null;

            if (next_packet) |i| {
                const ordered_packet = self.packet_buffer.orderedRemove(i);
                self.last_seq = ordered_packet.header.sequence_number;
                try self.packet_buffer.append(ordered_packet);
            } else break;
        }

        // Limit buffer size
        if (self.packet_buffer.items.len > 64) {
            const packet_to_free = self.packet_buffer.orderedRemove(0);
            packet_to_free.deinit();
        }

        return packet;
    }

    pub fn deinit(self: *Self) void {
        self.allocator.free(self.codec);
        self.allocator.free(self.control_url);
        for (self.packet_buffer.items) |*packet| {
            packet.deinit();
        }
        self.packet_buffer.deinit();
        if (self.rtp_socket) |socket| _ = std.posix.close(socket);
        if (self.rtcp_socket) |socket| _ = std.posix.close(socket);
    }
};

test "rtp header parsing" {
    const test_data = [_]u8{
        0x80, 0x60, 0x12, 0x34, // Version, padding, ext, csrc, marker, PT, seq
        0x00, 0x00, 0x00, 0x0A, // Timestamp
        0x11, 0x22, 0x33, 0x44, // SSRC
    };

    const header = try RtpHeader.parse(&test_data);

    try std.testing.expectEqual(@as(u2, 2), header.version);
    try std.testing.expect(!header.padding);
    try std.testing.expect(!header.extension);
    try std.testing.expectEqual(@as(u4, 0), header.csrc_count);
    try std.testing.expect(!header.marker);
    try std.testing.expectEqual(@as(u7, 0x60), header.payload_type);
    try std.testing.expectEqual(@as(u16, 0x1234), header.sequence_number);
    try std.testing.expectEqual(@as(u32, 10), header.timestamp);
    try std.testing.expectEqual(@as(u32, 0x11223344), header.ssrc);
}
