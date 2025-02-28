//! Common types, utilities and error handling

const std = @import("std");

/// Library error types
pub const Error = error{
    // RTSP errors
    RtspConnectionFailed,
    RtspAuthFailed,
    RtspStreamNotFound,
    SdpParseError,

    // RTP/Media errors
    RtpPacketError,
    MediaParseError,
    H264ParseError,
    H265ParseError,
    AacParseError,

    // TS/HLS errors
    TsEncodingError,
    SegmentationError,
    HlsServerError,
    PlaylistUpdateError,

    // General errors
    OutOfMemory,
    InvalidArgument,
    IoError,
};

/// Stream information
pub const StreamInfo = struct {
    id: []const u8,
    name: []const u8,
    rtsp_url: []const u8,

    pub fn deinit(self: *const StreamInfo, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.name);
        allocator.free(self.rtsp_url);
    }
};

/// Global configuration options
pub const Config = struct {
    /// Duration of each HLS segment in milliseconds
    segment_duration_ms: u32 = 10000,

    /// Maximum number of segments to keep in playlist
    max_segments: u32 = 6,

    /// Port for HLS server
    port: u16 = 8080,

    /// Number of worker threads
    thread_pool_size: u8 = 4,

    /// Testing configuration
    testing: struct {
        /// Whether to use live URLs for testing
        use_live_urls: bool = false,

        /// Dummy RTSP URL to use when not using live URLs
        dummy_rtsp_url: []const u8 = "rtsp://localhost:8554/test",
    } = .{},

    /// Stream configuration
    streams: []StreamInfo = &[_]StreamInfo{},

    const Self = @This();

    /// Load configuration from JSON file
    pub fn loadFromFile(allocator: std.mem.Allocator, path: []const u8) !Self {
        const file = try std.fs.cwd().openFile(path, .{});
        defer file.close();

        const content = try file.readToEndAlloc(allocator, std.math.maxInt(usize));
        defer allocator.free(content);

        var parsed = try std.json.parseFromSlice(std.json.Value, allocator, content, .{});
        defer parsed.deinit();

        return try Self.fromJson(allocator, parsed.value);
    }

    /// Create configuration from JSON value
    pub fn fromJson(allocator: std.mem.Allocator, json: std.json.Value) !Self {
        var config = Self{};

        if (json.object.get("segment_duration_ms")) |val| {
            config.segment_duration_ms = @intCast(val.integer);
        }

        if (json.object.get("max_segments")) |val| {
            config.max_segments = @intCast(val.integer);
        }

        if (json.object.get("port")) |val| {
            config.port = @intCast(val.integer);
        }

        if (json.object.get("thread_pool_size")) |val| {
            config.thread_pool_size = @intCast(val.integer);
        }

        // Parse testing config
        if (json.object.get("testing")) |test_json| {
            if (test_json.object.get("use_live_urls")) |val| {
                config.testing.use_live_urls = val.bool;
            }

            if (test_json.object.get("dummy_rtsp_url")) |val| {
                config.testing.dummy_rtsp_url = try allocator.dupe(u8, val.string);
            }
        }

        // Parse streams
        if (json.object.get("streams")) |streams_json| {
            const streams = try allocator.alloc(StreamInfo, streams_json.array.items.len);
            errdefer allocator.free(streams);

            for (streams_json.array.items, 0..) |stream_json, i| {
                streams[i] = StreamInfo{
                    .id = try allocator.dupe(u8, stream_json.object.get("id").?.string),
                    .name = try allocator.dupe(u8, stream_json.object.get("name").?.string),
                    .rtsp_url = try allocator.dupe(u8, stream_json.object.get("rtsp_url").?.string),
                };
            }
            config.streams = streams;
        }

        return config;
    }

    /// Clean up resources
    pub fn deinit(self: *const Self, allocator: std.mem.Allocator) void {
        for (self.streams) |stream| {
            stream.deinit(allocator);
        }
        allocator.free(self.streams);
    }
};

// Tests
const testing = std.testing;

test "config loads from json" {
    const json_str =
        \\{
        \\  "segment_duration_ms": 5000,
        \\  "max_segments": 10,
        \\  "port": 8081,
        \\  "thread_pool_size": 8,
        \\  "testing": {
        \\    "use_live_urls": true,
        \\    "dummy_rtsp_url": "rtsp://test:8554/stream"
        \\  },
        \\  "streams": [
        \\    {
        \\      "id": "test1",
        \\      "name": "Test Stream 1",
        \\      "rtsp_url": "rtsp://example.com/stream1"
        \\    }
        \\  ]
        \\}
    ;

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_str, .{});
    defer parsed.deinit();

    const config = try Config.fromJson(allocator, parsed.value);
    defer config.deinit(allocator);

    try testing.expectEqual(@as(u32, 5000), config.segment_duration_ms);
    try testing.expectEqual(@as(u32, 10), config.max_segments);
    try testing.expectEqual(@as(u16, 8081), config.port);
    try testing.expectEqual(@as(u8, 8), config.thread_pool_size);
    try testing.expect(config.testing.use_live_urls);
    try testing.expectEqualStrings("rtsp://test:8554/stream", config.testing.dummy_rtsp_url);
    try testing.expectEqualStrings("test1", config.streams[0].id);
    try testing.expectEqualStrings("Test Stream 1", config.streams[0].name);
    try testing.expectEqualStrings("rtsp://example.com/stream1", config.streams[0].rtsp_url);
}
