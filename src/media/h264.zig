//! H.264 NAL unit parsing and RTP packetization handling

const std = @import("std");
const rtsp = @import("../rtsp.zig");
const media = @import("../media.zig");
const common = @import("../common.zig");
const Frame = media.Frame;
const Parser = media.Parser;
const Error = common.Error;

/// H.264 parser state
pub const H264Parser = struct {
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
        .deinit = struct {
            fn deinit(parser: *Parser) void {
                const self = @as(*H264Parser, @ptrCast(@alignCast(parser)));
                self.deinit();
            }
        }.deinit,
    };

    /// Create new H.264 parser
    pub fn init(allocator: std.mem.Allocator) H264Parser {
        return .{
            .parser = .{ .vtable = &vtable },
            .allocator = allocator,
            .timestamp = 0,
            .frag_buffer = null,
        };
    }

    /// Get reference to parser interface
    pub fn getParser(self: *H264Parser) *Parser {
        return &self.parser;
    }

    /// Clean up resources
    pub fn deinit(self: *H264Parser) void {
        if (self.frag_buffer) |*frag| {
            frag.data.deinit();
            self.frag_buffer = null;
        }
    }

    /// Parse RTP packet
    fn parseRtp(parser: *Parser, data: []const u8) !?Frame {
        const self = @as(*H264Parser, @ptrCast(@alignCast(parser)));

        if (data.len < 13) return null; // Minimum RTP header + 1 byte payload

        // Extract timestamp from RTP header (bytes 4-7)
        self.timestamp = @as(i64, std.mem.readInt(u32, data[4..8], .big));

        // Skip RTP header (12 bytes)
        const payload = data[12..];
        if (payload.len < 1) return null;

        const nal_header = NalHeader.parse(payload[0]);
        if (nal_header.forbidden_zero_bit != 0) return Error.MediaParseError;

        return switch (nal_header.nal_unit_type) {
            // Single NAL unit packet
            .Unspecified, .Slice, .DPA, .DPB, .DPC, .IDR, .SEI, .SPS, .PPS, .AUD, .EndOfSequence, .EndOfStream, .Filler, .SPSExtension, .Prefix, .SubsetSPS, .Reserved16, .Reserved17, .Reserved18, .SliceAux, .SliceExtension, .SliceDepth, .Reserved22, .Reserved23 => try self.handleSingleNalUnit(payload),

            // Aggregation packet
            .stap_a => try self.handleStapA(payload[1..]),
            .stap_b, .mtap16, .mtap24 => return Error.MediaParseError, // Unsupported

            // Fragmentation unit
            .fu_a => try self.handleFuA(payload[1..]),
            .fu_b => return Error.MediaParseError, // Unsupported

            else => Error.MediaParseError,
        };
    }

    fn handleSingleNalUnit(self: *H264Parser, payload: []const u8) !?Frame {
        return try Frame.init(
            self.allocator,
            .video,
            .h264,
            self.timestamp,
            payload,
        );
    }

    fn handleStapA(self: *H264Parser, payload: []const u8) !?Frame {
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
            .h264,
            self.timestamp,
            combined.items,
        );
    }

    fn handleFuA(self: *H264Parser, payload: []const u8) !?Frame {
        if (payload.len < 1) return Error.MediaParseError;

        const fu_header = FuHeader.parse(payload[0]);
        const fu_payload = payload[1..];

        if (fu_header.start) {
            // Start of fragmented NAL unit
            if (self.frag_buffer != null) return Error.MediaParseError;

            var frag_data = std.ArrayList(u8).init(self.allocator);
            errdefer frag_data.deinit();

            // Reconstruct NAL header
            const orig_header = NalHeader{
                .forbidden_zero_bit = 0,
                .nal_ref_idc = 3, // TODO: Proper reference management
                .nal_unit_type = fu_header.type,
            };

            try frag_data.append(orig_header.toByte());
            try frag_data.appendSlice(fu_payload);

            self.frag_buffer = .{
                .data = frag_data,
                .nal_header = orig_header,
            };
            return null;
        } else if (fu_header.end) {
            // End of fragmented NAL unit
            if (self.frag_buffer == null) return Error.MediaParseError;

            try self.frag_buffer.?.data.appendSlice(fu_payload);
            const frame = try Frame.init(
                self.allocator,
                .video,
                .h264,
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
};

/// H.264 NAL unit types (Table 7-1)
pub const NalUnitType = enum(u5) {
    Unspecified = 0,
    Slice = 1,
    DPA = 2,
    DPB = 3,
    DPC = 4,
    IDR = 5,
    SEI = 6,
    SPS = 7,
    PPS = 8,
    AUD = 9,
    EndOfSequence = 10,
    EndOfStream = 11,
    Filler = 12,
    SPSExtension = 13,
    Prefix = 14,
    SubsetSPS = 15,
    Reserved16 = 16,
    Reserved17 = 17,
    Reserved18 = 18,
    SliceAux = 19,
    SliceExtension = 20,
    SliceDepth = 21,
    Reserved22 = 22,
    Reserved23 = 23,
    stap_a = 24,
    stap_b = 25,
    mtap16 = 26,
    mtap24 = 27,
    fu_a = 28,
    fu_b = 29,
    unspecified_30 = 30,
    unspecified_31 = 31,

    pub fn isKeyframe(self: NalUnitType) bool {
        return self == .IDR or self == .SPS or self == .PPS;
    }

    pub fn isConfig(self: NalUnitType) bool {
        return self == .SPS or self == .PPS;
    }
};

/// H.264 NAL unit header
const NalHeader = packed struct {
    nal_unit_type: NalUnitType,
    nal_ref_idc: u2,
    forbidden_zero_bit: u1,

    pub fn parse(byte: u8) NalHeader {
        return .{
            .forbidden_zero_bit = @truncate((byte >> 7) & 0x01),
            .nal_ref_idc = @truncate((byte >> 5) & 0x03),
            .nal_unit_type = @enumFromInt(byte & 0x1F),
        };
    }

    pub fn toByte(self: NalHeader) u8 {
        return (@as(u8, self.forbidden_zero_bit) << 7) |
            (@as(u8, self.nal_ref_idc) << 5) |
            @intFromEnum(self.nal_unit_type);
    }
};

/// H.264 FU header for fragmented NAL units
const FuHeader = packed struct {
    type: NalUnitType,
    reserved: u1,
    end: bool,
    start: bool,

    pub fn parse(byte: u8) FuHeader {
        return .{
            .start = (byte & 0x80) != 0,
            .end = (byte & 0x40) != 0,
            .reserved = @truncate((byte >> 5) & 0x01),
            .type = @enumFromInt(byte & 0x1F),
        };
    }

    pub fn toByte(self: FuHeader) u8 {
        return (@as(u8, @intFromBool(self.start)) << 7) |
            (@as(u8, @intFromBool(self.end)) << 6) |
            (@as(u8, self.reserved) << 5) |
            @intFromEnum(self.type);
    }
};

test "h264 parser - single nal unit" {
    // Create test RTP packet with timestamp and H.264 payload
    const rtp_header = [_]u8{
        0x80, 0x60, 0x12, 0x34, // Version, padding, ext, CSRC count, marker, PT, seq
        0x00, 0x00, 0x30, 0x39, // Timestamp (12345)
        0x11, 0x22, 0x33, 0x44, // SSRC
    };
    const test_nalu = [_]u8{
        0x65, // NAL header (type=5, ref=3, forbidden=0)
        0x88, 0x84, 0x00, // Some H.264 coded data
    };

    var packet = std.ArrayList(u8).init(std.testing.allocator);
    defer packet.deinit();
    try packet.appendSlice(&rtp_header);
    try packet.appendSlice(&test_nalu);

    var parser = H264Parser.init(std.testing.allocator);
    const h264_parser = parser.getParser();
    defer h264_parser.deinit();

    const result = try h264_parser.parse(packet.items);
    defer if (result) |frame| {
        var mutable_frame = frame;
        mutable_frame.deinit();
    };

    try std.testing.expect(result != null);
    try std.testing.expectEqual(@as(i64, 12345), result.?.pts);
    try std.testing.expectEqualSlices(u8, &test_nalu, result.?.data);
}

test "h264 parser - fragmented nal unit" {
    const rtp_header = [_]u8{
        0x80, 0x60, 0x12, 0x34, // Version, padding, ext, CSRC count, marker, PT, seq
        0x00, 0x00, 0x30, 0x39, // Timestamp (12345)
        0x11, 0x22, 0x33, 0x44, // SSRC
    };

    const test_fragments = [_][]const u8{
        &[_]u8{
            0x7c, // FU indicator (type=28, ref=3, forbidden=0)
            0x85, // FU header (start=1, end=0, type=5)
            0x88, 0x84, // Payload part 1
        },
        &[_]u8{
            0x7c, // FU indicator
            0x05, // FU header (start=0, end=0, type=5)
            0x00, 0x01, // Payload part 2
        },
        &[_]u8{
            0x7c, // FU indicator
            0x45, // FU header (start=0, end=1, type=5)
            0x02, 0x03, // Payload part 3
        },
    };

    var parser = H264Parser.init(std.testing.allocator);
    const h264_parser = parser.getParser();
    defer h264_parser.deinit();

    // Process fragments
    for (test_fragments, 0..) |frag, i| {
        var packet = std.ArrayList(u8).init(std.testing.allocator);
        defer packet.deinit();
        try packet.appendSlice(&rtp_header);
        try packet.appendSlice(frag);

        const result = try h264_parser.parse(packet.items);
        if (i < 2) {
            try std.testing.expect(result == null);
        } else {
            defer if (result) |frame| {
                var mutable_frame = frame;
                mutable_frame.deinit();
            };
            try std.testing.expect(result != null);

            const expected = [_]u8{
                0x65, // Reconstructed NAL header
                0x88, 0x84, // Part 1
                0x00, 0x01, // Part 2
                0x02, 0x03, // Part 3
            };
            try std.testing.expectEqualSlices(u8, &expected, result.?.data);
            try std.testing.expectEqual(@as(i64, 12345), result.?.pts);
        }
    }
}
