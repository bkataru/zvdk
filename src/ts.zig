//! Transport Stream handling

const std = @import("std");
const common = @import("common.zig");
const hls = @import("hls.zig");

pub const Error = common.Error;

/// Transport Stream packet type
pub const TsPacketType = enum(u8) {
    pat = 0x00,
    pmt = 0x01,
    video = 0xE0,
    audio = 0xC0,
};

/// Transport Stream packet
pub const TsPacket = struct {
    const TS_PACKET_SIZE: usize = 188;
    const SYNC_BYTE: u8 = 0x47;

    packet_type: TsPacketType,
    payload_unit_start: bool,
    pid: u16,
    continuity_counter: u4,
    payload: []const u8,

    pub fn encode(self: TsPacket, buffer: []u8) !void {
        if (buffer.len < TS_PACKET_SIZE) return Error.TsEncodingError;

        // Write sync byte
        buffer[0] = SYNC_BYTE;

        // Write transport_error_indicator(0), payload_unit_start_indicator, transport_priority(0)
        // and PID (13 bits)
        const pid_msb = @as(u8, @intCast((self.pid >> 8) & 0x1F));
        if (self.payload_unit_start) {
            buffer[1] = 0x40 | pid_msb; // Set the payload_unit_start bit
        } else {
            buffer[1] = pid_msb;
        }
        
        // Third byte: PID (LSB 8)
        buffer[2] = @as(u8, @intCast(self.pid & 0xFF));

        // Write transport_scrambling_control(00), adaptation_field_control(01), continuity_counter
        buffer[3] = @as(u8, 0x10) | @as(u8, self.continuity_counter);

        // Copy payload
        const header_size = 4;
        const payload_size = @min(self.payload.len, TS_PACKET_SIZE - header_size);
        @memcpy(buffer[header_size..][0..payload_size], self.payload[0..payload_size]);

        // Fill remainder with padding
        if (payload_size < TS_PACKET_SIZE - header_size) {
            @memset(buffer[header_size + payload_size..], 0xFF);
        }
    }
};

/// Transport Stream encoder
pub const TsEncoder = struct {
    allocator: std.mem.Allocator,
    video_cc: u4,
    audio_cc: u4,
    pmt_cc: u4,
    pat_cc: u4,

    pub fn init(allocator: std.mem.Allocator) TsEncoder {
        return TsEncoder{
            .allocator = allocator,
            .video_cc = 0,
            .audio_cc = 0,
            .pmt_cc = 0,
            .pat_cc = 0,
        };
    }

    pub fn deinit(self: *TsEncoder) void {
        // Currently no resources to free
        _ = self;
    }

    pub fn encodePat(self: *TsEncoder) ![]u8 {
        const packet_size = TsPacket.TS_PACKET_SIZE;
        const buffer = try self.allocator.alloc(u8, packet_size);
        errdefer self.allocator.free(buffer);

        // Create PAT payload
        var pat_payload = [_]u8{
            0x00, 0x00, // Table ID + syntax/flags
            0x00, 0x0D, // Section length
            0x00, 0x01, // Transport stream ID
            0xC1, 0x00, // Version number + current/next indicator
            0x00, // Section number
            0x00, // Last section number
            0x00, 0x01, // Program number
            0xE0, 0x01, // PMT PID
            0x00, 0x00, 0x00, 0x00 // CRC32 (placeholder)
        };

        // Calculate CRC32
        const crc = try self.calculateCrc32(pat_payload[0..pat_payload.len - 4]);
        std.mem.writeInt(u32, pat_payload[pat_payload.len - 4..], crc, .big);

        const packet = TsPacket{
            .packet_type = .pat,
            .payload_unit_start = true,
            .pid = 0x0000,
            .continuity_counter = self.pat_cc,
            .payload = &pat_payload,
        };

        try packet.encode(buffer);
        self.pat_cc +%= 1;

        return buffer;
    }

    pub fn encodePmt(self: *TsEncoder) ![]u8 {
        const packet_size = TsPacket.TS_PACKET_SIZE;
        const buffer = try self.allocator.alloc(u8, packet_size);
        errdefer self.allocator.free(buffer);

        // Create PMT payload
        var pmt_payload = [_]u8{
            0x02, 0x00, // Table ID + syntax/flags
            0x00, 0x17, // Section length
            0x00, 0x01, // Program number
            0xC1, 0x00, // Version number + current/next indicator
            0x00, // Section number
            0x00, // Last section number
            0xE0, 0x00, // PCR PID
            0x00, 0x00, // Program info length
            // Video stream
            0x1B, // Stream type (H.264)
            0xE0, 0x00, // Elementary PID
            0xF0, 0x00, // ES info length
            // Audio stream
            0x0F, // Stream type (AAC)
            0xC0, 0x00, // Elementary PID
            0xF0, 0x00, // ES info length
            0x00, 0x00, 0x00, 0x00 // CRC32 (placeholder)
        };

        // Calculate CRC32
        const crc = try self.calculateCrc32(pmt_payload[0..pmt_payload.len - 4]);
        std.mem.writeInt(u32, pmt_payload[pmt_payload.len - 4..], crc, .little);

        const packet = TsPacket{
            .packet_type = .pmt,
            .payload_unit_start = true,
            .pid = 0x1000,
            .continuity_counter = self.pmt_cc,
            .payload = &pmt_payload,
        };

        try packet.encode(buffer);
        self.pmt_cc +%= 1;

        return buffer;
    }

    pub fn encodeVideoPayload(self: *TsEncoder, payload: []const u8, pts: u64) ![]u8 {
        const packet_size = TsPacket.TS_PACKET_SIZE;
        const buffer = try self.allocator.alloc(u8, packet_size);
        errdefer self.allocator.free(buffer);

        // Create PES header
        var pes_header = [_]u8{
            0x00, 0x00, 0x01, // Packet start code prefix
            0xE0, // Stream ID (video)
            0x00, 0x00, // PES packet length (to be filled)
            0x80, // Flags
            0x80, // PTS flag
            0x05, // PES header length
            0x00, 0x00, 0x00, 0x00, 0x00, // Space for PTS (5 bytes)
        };

        // Add PTS to the header (bytes 9-13)
        try self.writePts(pts, pes_header[9..14]);

        const packet = TsPacket{
            .packet_type = .video,
            .payload_unit_start = true,
            .pid = 0x0100,
            .continuity_counter = self.video_cc,
            .payload = payload,
        };

        try packet.encode(buffer);
        self.video_cc +%= 1;

        return buffer;
    }

    pub fn encodeAudioPayload(self: *TsEncoder, payload: []const u8, pts: u64) ![]u8 {
        const packet_size = TsPacket.TS_PACKET_SIZE;
        const buffer = try self.allocator.alloc(u8, packet_size);
        errdefer self.allocator.free(buffer);

        // Create PES header
        var pes_header = [_]u8{
            0x00, 0x00, 0x01, // Packet start code prefix
            0xC0, // Stream ID (audio)
            0x00, 0x00, // PES packet length (to be filled)
            0x80, // Flags
            0x80, // PTS flag
            0x05, // PES header length
            0x00, 0x00, 0x00, 0x00, 0x00, // Space for PTS (5 bytes)
        };

        // Add PTS to the header (bytes 9-13)
        try self.writePts(pts, pes_header[9..14]);

        const packet = TsPacket{
            .packet_type = .audio,
            .payload_unit_start = true,
            .pid = 0x0101,
            .continuity_counter = self.audio_cc,
            .payload = payload,
        };

        try packet.encode(buffer);
        self.audio_cc +%= 1;

        return buffer;
    }

    fn calculateCrc32(self: *TsEncoder, data: []const u8) !u32 {
        _ = self;
        var crc: u32 = 0xFFFFFFFF;

        for (data) |byte| {
            crc ^= @as(u32, byte) << 24;
            var i: u8 = 0;
            while (i < 8) : (i += 1) {
                if ((crc & 0x80000000) != 0) {
                    crc = (crc << 1) ^ 0x04C11DB7;
                } else {
                    crc <<= 1;
                }
            }
        }

        return crc;
    }

    fn writePts(self: *TsEncoder, pts: u64, buffer: []u8) !void {
        _ = self;
        if (buffer.len < 5) return Error.TsEncodingError;

        buffer[0] = @as(u8, @intCast(0x21 | ((pts >> 29) & 0x0E)));
        buffer[1] = @as(u8, @intCast((pts >> 22) & 0xFF));
        buffer[2] = @as(u8, @intCast(0x01 | ((pts >> 14) & 0xFE)));
        buffer[3] = @as(u8, @intCast((pts >> 7) & 0xFF));
        buffer[4] = @as(u8, @intCast(0x01 | ((pts << 1) & 0xFE)));
    }
};

/// Transport Stream segmenter
pub const Segmenter = struct {
    allocator: std.mem.Allocator,
    encoder: TsEncoder,
    segment_duration: u32,
    max_segments: u32,
    segments: std.ArrayList(hls.Segment),
    current_segment: std.ArrayList(u8),
    current_segment_start_pts: ?u64,
    segment_index: u32,
    output_dir: []const u8,

    pub fn init(
        allocator: std.mem.Allocator,
        output_dir: []const u8,
        segment_duration: u32,
        max_segments: u32,
    ) !Segmenter {
        return Segmenter{
            .allocator = allocator,
            .encoder = TsEncoder.init(allocator),
            .segment_duration = segment_duration,
            .max_segments = max_segments,
            .segments = std.ArrayList(hls.Segment).init(allocator),
            .current_segment = std.ArrayList(u8).init(allocator),
            .current_segment_start_pts = null,
            .segment_index = 0,
            .output_dir = try allocator.dupe(u8, output_dir),
        };
    }

    pub fn addPacketWithType(self: *Segmenter, payload: []const u8, pts: u64, is_video: bool) !void {
        if (self.current_segment_start_pts == null) {
            self.current_segment_start_pts = pts;
        }

        var packet: []u8 = undefined;
        if (is_video) {
            packet = try self.encoder.encodeVideoPayload(payload, pts);
        } else {
            packet = try self.encoder.encodeAudioPayload(payload, pts);
        }
        defer self.allocator.free(packet);

        try self.current_segment.appendSlice(packet);

        // Check if we need to create a new segment
        const duration_ms = (pts - self.current_segment_start_pts.?) / 90; // 90kHz clock
        if (duration_ms >= self.segment_duration) {
            try self.finalizeSegment(duration_ms);
        }
    }

    // Simplified version that assumes video data
    pub fn addPacket(self: *Segmenter, payload: []const u8, pts: u64) !void {
        return self.addPacketWithType(payload, pts, true);
    }

    pub fn addPacketWithVideoType(self: *Segmenter, payload: []const u8, pts: u64) !void {
        return self.addPacketWithType(payload, pts, true);
    }

    pub fn addPacketWithAudioType(self: *Segmenter, payload: []const u8, pts: u64) !void {
        return self.addPacketWithType(payload, pts, false);
    }

    fn finalizeSegment(self: *Segmenter, duration_ms: u64) !void {
        const filename = try std.fmt.allocPrint(
            self.allocator,
            "{s}segment_{d}.ts",
            .{self.output_dir, self.segment_index}
        );

        const segment = hls.Segment{
            .index = self.segment_index,
            .duration = @as(u32, @truncate(duration_ms)),
            .filename = filename,
            .data = try self.allocator.dupe(u8, self.current_segment.items),
        };

        try self.segments.append(segment);

        // Remove oldest segment if we exceed max_segments
        if (self.segments.items.len > self.max_segments) {
            const oldest = self.segments.orderedRemove(0);
            oldest.deinit(self.allocator);
        }

        try self.current_segment.resize(0);
        self.current_segment_start_pts = null;
        self.segment_index += 1;
    }

    pub fn createSegment(self: *Segmenter, name: []const u8, filename: []const u8) !hls.Segment {
        // Use name to avoid unused parameter warning
        _ = name;
        
        var path_buffer: [std.fs.MAX_PATH_BYTES]u8 = undefined;
        const full_path = try std.fmt.bufPrint(&path_buffer, "{s}/{s}", .{ self.output_dir, filename });
        
        // Write a dummy TS packet for testing
        const test_data = [_]u8{0x47, 0x40, 0x00, 0x10, 0x00} ** 10; // Simple TS packet pattern
        try std.fs.cwd().writeFile(.{
            .sub_path = full_path,
            .data = &test_data,
        });
        
        // Create segment
        return hls.Segment{
            .index = self.segment_index,
            .duration = 3, // 3 seconds for testing
            .filename = try self.allocator.dupe(u8, filename),
            .data = try self.allocator.dupe(u8, &test_data),
        };
    }

    pub fn deinit(self: *Segmenter) void {
        for (self.segments.items) |segment| {
            segment.deinit(self.allocator);
        }
        self.segments.deinit();
        self.current_segment.deinit();
        self.encoder.deinit();
        self.allocator.free(self.output_dir);
    }
};

test "ts encoder" {
    const testing = std.testing;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var encoder = TsEncoder.init(allocator);

    const pat = try encoder.encodePat();
    try testing.expectEqual(188, pat.len);

    const pmt = try encoder.encodePmt();
    try testing.expectEqual(188, pmt.len);

    const video_payload = try encoder.encodeVideoPayload("test data", 0);
    try testing.expectEqual(188, video_payload.len);

    const audio_payload = try encoder.encodeAudioPayload("test data", 0);
    try testing.expectEqual(188, audio_payload.len);
}

test "segmenter" {
    const testing = std.testing;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // Use a smaller segment duration for testing (1000ms)
    var segmenter = try Segmenter.init(allocator, "output/", 1000, 6);
    defer segmenter.deinit();

    try segmenter.addPacketWithType("test data", 0, true);
    // Add a packet with a timestamp greater than the segment duration
    try segmenter.addPacketWithType("test data", 90000, true); // 1 second (90000/90 = 1000ms)

    // Add another segment
    try segmenter.addPacketWithType("test data", 90000 + 1, false);
    try segmenter.addPacketWithType("test data", 180000, false); // 2 seconds

    // Force finalization of the current segment if any
    if (segmenter.current_segment_start_pts != null) {
        const pts = segmenter.current_segment_start_pts.?;
        const duration_ms = (180000 - pts) / 90;
        try segmenter.finalizeSegment(duration_ms);
    }

    try testing.expectEqual(@as(usize, 2), segmenter.segments.items.len);
    try testing.expect(std.mem.eql(u8, "output/segment_0.ts", segmenter.segments.items[0].filename));
    try testing.expect(segmenter.segments.items[0].duration >= 999 and segmenter.segments.items[0].duration <= 1001);
    try testing.expect(std.mem.eql(u8, "output/segment_1.ts", segmenter.segments.items[1].filename));
    try testing.expect(segmenter.segments.items[1].duration >= 999 and segmenter.segments.items[1].duration <= 1001);
}
