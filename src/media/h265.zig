//! H.265 NAL unit parsing and RTP packetization handling

const std = @import("std");
const rtsp = @import("../rtsp.zig");
const media = @import("../media.zig");
const common = @import("../common.zig");
const Frame = media.Frame;
const Parser = media.Parser;
const Error = common.Error;

/// H.265 parser state
pub const H265Parser = struct {
    parser: Parser,
    allocator: std.mem.Allocator,
    timestamp: i64,

    // Fragmentation state
    frag_buffer: ?struct {
        data: std.ArrayList(u8),
        nal_header: NalHeader,
    },

    // Parser vtable
    const vtable = Parser.VTable{
        .parse = parseRtp,
        .deinit = deinit,
    };

    /// Create new H.265 parser
    pub fn init(allocator: std.mem.Allocator) H265Parser {
        return .{
            .parser = .{ .vtable = &vtable },
            .allocator = allocator,
            .timestamp = 0,
            .frag_buffer = null,
        };
    }

    /// Get reference to parser interface
    pub fn getParser(self: *H265Parser) *Parser {
        return &self.parser;
    }

    /// Parse RTP packet
    fn parseRtp(parser: *Parser, data: []const u8) !?Frame {
        const self = @as(*H265Parser, @ptrCast(@alignCast(parser)));

        if (data.len < 13) return null; // Minimum RTP header + 1 byte payload

        // Extract timestamp from RTP header (bytes 4-7)
        self.timestamp = @as(i64, std.mem.readInt(u32, data[4..8], .big));

        // Skip RTP header (12 bytes)
        const payload = data[12..];
        if (payload.len < 2) return null;

        // H.265 payloads have 2-byte header
        const nal_header = NalHeader.parse(payload[0..2]);
        if (nal_header.forbidden_bit != 0) return Error.MediaParseError;

        return switch (nal_header.nal_unit_type) {
            .trail_n, .trail_r, .tsa_n, .tsa_r, .stsas_n, .stsas_r, .radl_n, .radl_r, 
            .rasl_n, .rasl_r, .bla_w_lp, .bla_w_radl, .bla_n_lp, .idr_w_radl, 
            .idr_n_lp, .cra_nut => try self.handleSingleNalUnit(payload),

            .vps_nut, .sps_nut, .pps_nut, .aud_nut, .eos_nut, .eob_nut, .fd_nut, 
            .prefix_sei_nut, .suffix_sei_nut => try self.handleSingleNalUnit(payload),

            .aggr_nut => try self.handleAggregationPacket(payload[2..]),

            .frag_nut => try self.handleFragmentationUnit(payload),

            else => Error.MediaParseError,
        };
    }

    fn handleSingleNalUnit(self: *H265Parser, payload: []const u8) !?Frame {
        return try Frame.init(
            self.allocator,
            .video,
            .h265,
            self.timestamp,
            payload,
        );
    }

    fn handleFragmentationUnit(self: *H265Parser, payload: []const u8) !?Frame {
        if (payload.len < 3) return Error.MediaParseError;

        // FU header is the third byte (after 2-byte NAL header)
        const fu_header = FuHeader.parse(payload[2]);
        const fu_payload = payload[3..];

        if (fu_header.start_bit) {
            // Start of fragmented NAL unit
            if (self.frag_buffer != null) return Error.MediaParseError;

            var frag_data = std.ArrayList(u8).init(self.allocator);
            errdefer frag_data.deinit();

            // Reconstruct NAL header
            const orig_header = NalHeader{
                .forbidden_bit = 0,
                .nuh_layer_id = 0,
                .nuh_temporal_id_plus1 = 1,
                .nal_unit_type = fu_header.nal_unit_type,
            };

            try frag_data.appendSlice(&orig_header.toBytes());
            try frag_data.appendSlice(fu_payload);

            self.frag_buffer = .{
                .data = frag_data,
                .nal_header = orig_header,
            };
            return null;
        } else if (fu_header.end_bit) {
            // End of fragmented NAL unit
            if (self.frag_buffer == null) return Error.MediaParseError;

            try self.frag_buffer.?.data.appendSlice(fu_payload);
            const frame = try Frame.init(
                self.allocator,
                .video,
                .h265,
                self.timestamp,
                self.frag_buffer.?.data.items,
            );

            self.frag_buffer.?.data.deinit();
            self.frag_buffer = null;
            return frame;
        } else {
            // Middle of fragmented NAL unit
            if (self.frag_buffer == null) return Error.MediaParseError;
            try self.frag_buffer.?.data.appendSlice(fu_payload);
            return null;
        }
    }

    fn handleAggregationPacket(self: *H265Parser, payload: []const u8) !?Frame {
        var pos: usize = 0;
        var combined = std.ArrayList(u8).init(self.allocator);
        defer combined.deinit();

        while (pos + 2 <= payload.len) {
            const nalu_size = std.mem.readInt(u16, payload[pos..][0..2], .big);
            pos += 2;

            if (pos + nalu_size > payload.len) return Error.MediaParseError;
            try combined.appendSlice(payload[pos .. pos + nalu_size]);
            pos += nalu_size;
        }

        return try Frame.init(
            self.allocator,
            .video,
            .h265,
            self.timestamp,
            combined.items,
        );
    }

    fn deinit(parser: *Parser) void {
        const self = @as(*H265Parser, @ptrCast(@alignCast(parser)));
        if (self.frag_buffer) |*frag| {
            frag.data.deinit();
        }
    }
};

/// H.265 NAL unit types (Table 7-1 of H.265 spec)
pub const NalUnitType = enum(u6) {
    trail_n = 0,
    trail_r = 1,
    tsa_n = 2,
    tsa_r = 3,
    stsas_n = 4,
    stsas_r = 5,
    radl_n = 6,
    radl_r = 7,
    rasl_n = 8,
    rasl_r = 9,
    rsv_vcl_n10 = 10,
    rsv_vcl_r11 = 11,
    rsv_vcl_n12 = 12,
    rsv_vcl_r13 = 13,
    rsv_vcl_n14 = 14,
    rsv_vcl_r15 = 15,
    bla_w_lp = 16,
    bla_w_radl = 17,
    bla_n_lp = 18,
    idr_w_radl = 19,
    idr_n_lp = 20,
    cra_nut = 21,
    rsv_irap_vcl22 = 22,
    rsv_irap_vcl23 = 23,
    rsv_vcl24 = 24,
    rsv_vcl25 = 25,
    rsv_vcl26 = 26,
    rsv_vcl27 = 27,
    rsv_vcl28 = 28,
    rsv_vcl29 = 29,
    rsv_vcl30 = 30,
    rsv_vcl31 = 31,
    vps_nut = 32,
    sps_nut = 33,
    pps_nut = 34,
    aud_nut = 35,
    eos_nut = 36,
    eob_nut = 37,
    fd_nut = 38,
    prefix_sei_nut = 39,
    suffix_sei_nut = 40,
    rsv_nvcl41 = 41,
    rsv_nvcl42 = 42,
    rsv_nvcl43 = 43,
    rsv_nvcl44 = 44,
    rsv_nvcl45 = 45,
    rsv_nvcl46 = 46,
    rsv_nvcl47 = 47,
    aggr_nut = 48, // Aggregation packet AP
    frag_nut = 49, // Fragmentation unit FU
    paci_nut = 50, // PACI packet
    rsv_51 = 51,
    rsv_52 = 52,
    rsv_53 = 53,
    rsv_54 = 54,
    rsv_55 = 55,
    rsv_56 = 56,
    rsv_57 = 57,
    rsv_58 = 58,
    rsv_59 = 59,
    rsv_60 = 60,
    rsv_61 = 61,
    rsv_62 = 62,
    rsv_63 = 63,

    pub fn isKeyframe(self: NalUnitType) bool {
        return switch (self) {
            .idr_w_radl, .idr_n_lp, .cra_nut, .bla_w_lp, .bla_w_radl, .bla_n_lp, .vps_nut, .sps_nut, .pps_nut => true,
            else => false,
        };
    }

    pub fn isConfig(self: NalUnitType) bool {
        return self == .vps_nut or self == .sps_nut or self == .pps_nut;
    }
};

/// H.265 NAL unit header (2 bytes)
const NalHeader = packed struct {
    nal_unit_type: NalUnitType,
    nuh_layer_id: u6,
    nuh_temporal_id_plus1: u3,
    forbidden_bit: u1,

    pub fn parse(bytes: []const u8) NalHeader {
        const byte1 = bytes[0];
        const byte2 = bytes[1];
        return .{
            .forbidden_bit = @truncate((byte1 >> 7) & 0x01),
            .nal_unit_type = @enumFromInt((byte1 >> 1) & 0x3F),
            .nuh_layer_id = @truncate(((byte1 & 0x01) << 5) | ((byte2 >> 3) & 0x1F)),
            .nuh_temporal_id_plus1 = @truncate(byte2 & 0x07),
        };
    }

    pub fn toBytes(self: NalHeader) [2]u8 {
        var bytes: [2]u8 = undefined;
        bytes[0] = (@as(u8, self.forbidden_bit) << 7) |
            (@as(u8, @intFromEnum(self.nal_unit_type)) << 1) |
            (@as(u8, self.nuh_layer_id) >> 5);
        bytes[1] = (@as(u8, self.nuh_layer_id & 0x1F) << 3) |
            self.nuh_temporal_id_plus1;
        return bytes;
    }
};

/// H.265 FU header for fragmented NAL units (1 byte)
const FuHeader = packed struct {
    nal_unit_type: NalUnitType,
    end_bit: bool,
    start_bit: bool,

    pub fn parse(byte: u8) FuHeader {
        return .{
            .start_bit = (byte & 0x80) != 0,
            .end_bit = (byte & 0x40) != 0,
            .nal_unit_type = @enumFromInt(byte & 0x3F),
        };
    }

    pub fn toByte(self: FuHeader) u8 {
        return (@as(u8, @intFromBool(self.start_bit)) << 7) |
            (@as(u8, @intFromBool(self.end_bit)) << 6) |
            @as(u8, @intFromEnum(self.nal_unit_type));
    }
};

test "h265 parser - single nal unit" {
    // Create test RTP packet with timestamp and H.265 payload
    const rtp_header = [_]u8{
        0x80, 0x60, 0x12, 0x34, // Version, padding, ext, CSRC count, marker, PT, seq
        0x00, 0x00, 0x30, 0x39, // Timestamp (12345)
        0x11, 0x22, 0x33, 0x44, // SSRC
    };

    const test_nalu = [_]u8{
        0x40, 0x01, // NAL header (type=32 VPS, layer=0, tid=1)
        0x88, 0x84, 0x00, // Some H.265 coded data
    };

    var packet = std.ArrayList(u8).init(std.testing.allocator);
    defer packet.deinit();
    try packet.appendSlice(&rtp_header);
    try packet.appendSlice(&test_nalu);

    var parser = H265Parser.init(std.testing.allocator);
    const h265_parser = parser.getParser();
    defer h265_parser.deinit();

    const result = try h265_parser.parse(packet.items);
    defer if (result) |frame| {
        var mutable_frame = frame;
        mutable_frame.deinit();
    };

    try std.testing.expect(result != null);
    try std.testing.expectEqual(@as(i64, 12345), result.?.pts);
    try std.testing.expectEqualSlices(u8, &test_nalu, result.?.data);
}

test "h265 parser - fragmented nal unit" {
    const rtp_header = [_]u8{
        0x80, 0x60, 0x12, 0x34, // Version, padding, ext, CSRC count, marker, PT, seq
        0x00, 0x00, 0x30, 0x39, // Timestamp (12345)
        0x11, 0x22, 0x33, 0x44, // SSRC
    };

    // FU packets with NAL type 49 (fragmentation unit)
    const test_fragments = [_][]const u8{
        &[_]u8{
            0x62, 0x01, // NAL header (type=49 FU, layer=0, tid=1)
            0x94, // FU header (start=1, end=0, type=20 IDR)
            0x88, 0x84, // Payload part 1
        },
        &[_]u8{
            0x62, 0x01, // NAL header (type=49 FU, layer=0, tid=1)
            0x14, // FU header (start=0, end=0, type=20 IDR)
            0x00, 0x01, // Payload part 2
        },
        &[_]u8{
            0x62, 0x01, // NAL header (type=49 FU, layer=0, tid=1)
            0x54, // FU header (start=0, end=1, type=20 IDR)
            0x02, 0x03, // Payload part 3
        },
    };

    var parser = H265Parser.init(std.testing.allocator);
    const h265_parser = parser.getParser();
    defer h265_parser.deinit();

    // Process fragments
    for (test_fragments, 0..) |frag, i| {
        var packet = std.ArrayList(u8).init(std.testing.allocator);
        defer packet.deinit();
        try packet.appendSlice(&rtp_header);
        try packet.appendSlice(frag);

        const result = try h265_parser.parse(packet.items);
        if (i < 2) {
            try std.testing.expect(result == null);
        } else {
            defer if (result) |frame| {
                var mutable_frame = frame;
                mutable_frame.deinit();
            };
            try std.testing.expect(result != null);

            const expected_header = [_]u8{ 0x28, 0x01 }; // Reconstructed NAL header for IDR
            try std.testing.expectEqual(@as(i64, 12345), result.?.pts);
            try std.testing.expectEqualSlices(u8, &expected_header, result.?.data[0..2]);
        }
    }
}
