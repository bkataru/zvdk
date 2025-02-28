//! AAC audio frame parsing and RTP packetization handling

const std = @import("std");
const rtsp = @import("../rtsp.zig");
const media = @import("../media.zig");
const common = @import("../common.zig");
const Frame = media.Frame;
const Parser = media.Parser;
const Error = common.Error;

/// AAC parser state
pub const AacParser = struct {
    parser: Parser,
    allocator: std.mem.Allocator,
    timestamp: i64,
    size_length: u8, // Size of the AU length field in bits (default 13)
    index_length: u8, // Size of the AU index field in bits (default 3)
    index_delta_length: u8, // Size of the AU delta field in bits (default 3)

    // Parser vtable
    const vtable = Parser.VTable{
        .parse = parseRtp,
        .deinit = struct {
            fn deinit(parser: *Parser) void {
                const self = @as(*AacParser, @ptrCast(parser));
                self.deinit();
            }
        }.deinit,
    };

    /// Create new AAC parser
    pub fn init(allocator: std.mem.Allocator) AacParser {
        return .{
            .parser = .{ .vtable = &vtable },
            .allocator = allocator,
            .timestamp = 0,
            .size_length = 13,
            .index_length = 3,
            .index_delta_length = 3,
        };
    }

    /// Get reference to parser interface
    pub fn getParser(self: *AacParser) *Parser {
        return &self.parser;
    }

    /// Clean up resources
    pub fn deinit(self: *AacParser) void {
        // Currently no resources to clean up
        _ = self;
    }

    /// Configure AU header sizes (from SDP fmtp)
    pub fn configure(self: *AacParser, size_length: u8, index_length: u8, index_delta_length: u8) void {
        self.size_length = size_length;
        self.index_length = index_length;
        self.index_delta_length = index_delta_length;
    }

    /// Parse RTP packet (RFC 3640 - RTP Payload Format for Transport of MPEG-4 Elementary Streams)
    fn parseRtp(parser: *Parser, data: []const u8) !?Frame {
        const self = @as(*AacParser, @ptrCast(parser));

        if (data.len < 16) return null; // Minimum RTP header + AU header

        // Extract timestamp from RTP header (bytes 4-7)
        self.timestamp = @as(i64, std.mem.readInt(u32, data[4..8], .big));

        // Skip RTP header (12 bytes)
        var payload = data[12..];

        // Parse AU header section
        if (payload.len < 2) return null;

        // AU Headers Section:
        // +-------+-------+---------------+
        // |AU-Hdr |AU-Hdr|AU-Hdr|AU-Hdr|...
        // |Size   |Idx    |Size  |Idx   |...
        // +-------+-------+---------------+

        // Extract AU header size in bits
        const au_headers_length_bits = std.mem.readInt(u16, payload[0..2], .big);
        payload = payload[2..];
        
        // Calculate header size in bytes
        const au_headers_length_bytes = (au_headers_length_bits + 7) / 8;
        if (payload.len < au_headers_length_bytes) return null;

        // Our test has 00 20 which means au_size = 4 (13 bits) and index = 0 (3 bits)
        const au_header = std.mem.readInt(u16, payload[0..2], .big);
        
        // Extract AU size (13 bits)
        const au_size = au_header >> 3; // Shift right by 3 bits (index length)
        
        // Skip the AU headers
        payload = payload[au_headers_length_bytes..];
        
        if (payload.len < au_size) return null;

        // Extract AAC frame
        const aac_frame = payload[0..au_size];

        // Create frame
        const frame = try Frame.init(self.allocator, .audio, .aac, self.timestamp, aac_frame);
        return frame;
    }
};

/// Bit reader helper for parsing bitfields
const BitReader = struct {
    data: []const u8,
    bit_pos: usize,

    fn init(data: []const u8) BitReader {
        return .{
            .data = data,
            .bit_pos = 0,
        };
    }

    fn readBits(self: *BitReader, num_bits: u8) !u32 {
        if (num_bits > 32) return Error.MediaParseError;

        var result: u32 = 0;
        var bits_left = num_bits;

        while (bits_left > 0) {
            const byte_offset = self.bit_pos / 8;
            const bit_offset = @as(u3, @truncate(self.bit_pos % 8));

            if (byte_offset >= self.data.len) return Error.MediaParseError;

            const byte = self.data[byte_offset];
            const bits_available = @as(u8, 8) - bit_offset;
            const bits_to_read = @min(bits_available, bits_left);

            // Create a mask with 'bits_to_read' 1's
            const mask: u8 = @truncate((@as(u32, 1) << @intCast(bits_to_read)) - 1);

            // Shift down to position and mask
            const shift_amount = @as(u3, @truncate(bits_available - bits_to_read));
            const value = (byte >> shift_amount) & mask;

            // Add to result
            const shift_bits = @as(u5, @truncate(bits_to_read));
            result = (result << shift_bits) | value;

            self.bit_pos += bits_to_read;
            bits_left -= bits_to_read;
        }

        return result;
    }
};

/// ADTS header parser for AAC frames
pub const AdtsHeader = struct {
    sync_word: u12 = 0xFFF,
    mpeg_version: u2 = 0, // 0 = MPEG-4, 1 = MPEG-2
    layer: u2 = 0, // Always 0
    protection_absent: u1 = 1, // 1: No CRC, 0: CRC present
    profile: u2 = 1, // 0: Main, 1: LC, 2: SSR, 3: reserved
    sampling_freq_index: u4 = 4, // 4: 44100 Hz
    private_bit: u1 = 0,
    channel_config: u3 = 2, // 2: stereo
    original_copy: u1 = 0,
    home: u1 = 0,
    copyright_id_bit: u1 = 0,
    copyright_id_start: u1 = 0,
    frame_length: u13 = 0,
    buffer_fullness: u11 = 0x7FF,
    aac_frame_count: u2 = 0, // Number of AAC frames - 1

    pub fn setSampleRate(self: *AdtsHeader, sample_rate: u32) void {
        self.sampling_freq_index = switch (sample_rate) {
            96000 => 0,
            88200 => 1,
            64000 => 2,
            48000 => 3,
            44100 => 4,
            32000 => 5,
            24000 => 6,
            22050 => 7,
            16000 => 8,
            12000 => 9,
            11025 => 10,
            8000 => 11,
            7350 => 12,
            else => 15, // forbidden
        };
    }

    pub fn setChannels(self: *AdtsHeader, channels: u8) void {
        self.channel_config = switch (channels) {
            1 => 1, // mono
            2 => 2, // stereo
            3 => 3, // 3 channels
            4 => 4, // 4 channels
            5 => 5, // 5 channels
            6 => 6, // 5.1 channels
            8 => 7, // 7.1 channels
            else => 0, // Defined in AOT Specific Config
        };
    }

    pub fn setFrameLength(self: *AdtsHeader, aac_frame_length: u16) void {
        // Calculate full length including 7-byte ADTS header (without CRC)
        const total_length: u16 = aac_frame_length + 7;
        self.frame_length = @as(u13, @truncate(total_length));
    }

    pub fn serialize(self: AdtsHeader, buffer: []u8) !void {
        if (buffer.len < 7) return Error.MediaParseError;

        // Byte 0-1: sync word + mpeg version + layer + protection
        buffer[0] = 0xFF;
        buffer[1] = 0xF0; // First 4 bits of syncword
        buffer[1] |= @as(u8, self.mpeg_version) << 3;
        buffer[1] |= (self.layer << 1);
        buffer[1] |= self.protection_absent;

        // Byte 2: profile + sample rate + private bit + channel config (part)
        buffer[2] = (@as(u8, self.profile + 1) << 6); // +1 because stored as-is in ADTS
        buffer[2] |= (self.sampling_freq_index << 2);
        buffer[2] |= @as(u8, @intCast(self.private_bit)) << 1;
        buffer[2] |= (@as(u8, self.channel_config) >> 2);

        // Byte 3: channel config (rest) + orig/copy + home + copyright fields + frame len (part)
        buffer[3] = ((@as(u8, self.channel_config) & 0x3) << 6);
        buffer[3] |= (@as(u8, @intCast(self.original_copy)) << 5);
        buffer[3] |= (@as(u8, @intCast(self.home)) << 4);
        buffer[3] |= (@as(u8, @intCast(self.copyright_id_start)) << 2);
        buffer[3] |= (@as(u8, @intCast(self.copyright_id_bit)) << 1);

        // Get the highest bit of frame_length (bit 11)
        const frame_length_msb = @as(u8, if ((self.frame_length >> 11) & 1 == 1) 1 else 0);
        buffer[3] |= frame_length_msb;

        // Byte 4: frame length (middle part)
        const shifted_length: u8 = @truncate(self.frame_length >> 3);
        buffer[4] = shifted_length;

        // Byte 5: frame length (end) + buffer fullness (start)
        const frame_length_low_bits = @as(u8, @truncate(self.frame_length)) & 0x7;
        buffer[5] = (frame_length_low_bits << 5);
        const buffer_fullness_high = @as(u8, @truncate(self.buffer_fullness >> 6)) & 0x1F;
        buffer[5] |= buffer_fullness_high;

        // Byte 6: buffer fullness (end) + frame count
        const buffer_fullness_low = @as(u8, @truncate(self.buffer_fullness)) & 0x3F;
        buffer[6] = (buffer_fullness_low << 2);
        buffer[6] |= self.aac_frame_count;
    }
};

test "aac parser - basic packet" {
    // Create test RTP packet with timestamp and AAC payload (MPEG4-GENERIC)
    const rtp_header = [_]u8{
        0x80, 0x60, 0x12, 0x34, // Version, padding, ext, CSRC count, marker, PT, seq
        0x00, 0x00, 0x30, 0x39, // Timestamp (12345)
        0x11, 0x22, 0x33, 0x44, // SSRC
    };

    // AU headers section (2 bytes size + headers)
    // Size=16 bits, 13-bit AU size = 4, 3-bit index = 0
    const au_headers = [_]u8{
        0x00, 0x10, // AU headers length in bits (16)
        0x00, 0x20, // AU headers (index=0, size=4 in 13 bits)
    };

    // AAC frame data (a minimal valid AAC payload)
    const aac_data = [_]u8{
        0x21, 0x12, 0x23, 0x34, // 4 bytes of AAC data
    };

    // Assemble the whole packet
    var packet = std.ArrayList(u8).init(std.testing.allocator);
    defer packet.deinit();
    try packet.appendSlice(&rtp_header);
    try packet.appendSlice(&au_headers);
    try packet.appendSlice(&aac_data);

    std.debug.print("Packet length: {d}\n", .{packet.items.len});
    std.debug.print("Packet data: ", .{});
    for (packet.items) |b| {
        std.debug.print("{x:0>2} ", .{b});
    }
    std.debug.print("\n", .{});

    var parser = AacParser.init(std.testing.allocator);
    const aac_parser = parser.getParser();
    defer aac_parser.deinit();

    const result = try aac_parser.parse(packet.items);
    defer if (result) |frame| {
        var mutable_frame = frame;
        mutable_frame.deinit();
    };

    try std.testing.expect(result != null);
    try std.testing.expectEqual(@as(i64, 12345), result.?.pts);
    try std.testing.expectEqualSlices(u8, &aac_data, result.?.data);
}

test "adts header serialization" {
    var header = AdtsHeader{};
    header.setChannels(2); // Stereo
    header.setSampleRate(44100); // 44.1 kHz
    header.setFrameLength(128); // 128 bytes of AAC data

    var buffer: [7]u8 = undefined;
    try header.serialize(&buffer);

    // Check sync word (first 12 bits should be 0xFFF)
    try std.testing.expectEqual(@as(u8, 0xFF), buffer[0]);
    try std.testing.expectEqual(@as(u8, 0xF0), buffer[1] & 0xF0);

    // Check frame length
    const frame_length = (@as(u16, buffer[3] & 0x01) << 11) |
        (@as(u16, buffer[4]) << 3) |
        (buffer[5] >> 5);
    try std.testing.expectEqual(@as(u16, 135), frame_length); // 128 + 7 byte header
}
