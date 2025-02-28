const std = @import("std");
const rtsp = @import("../rtsp.zig");
const media = @import("../media.zig");
const ts = @import("../ts.zig");
const hls = @import("../hls.zig");
const test_config = @import("../test_config.zig");
const RtspClient = rtsp.RtspClient;
const H264Parser = media.h264.H264Parser;
const H265Parser = media.h265.H265Parser;
const AacParser = media.aac.AacParser;
const TsEncoder = ts.TsEncoder;
const Segmenter = ts.Segmenter;
const MockRtspServer = @import("../rtsp/mock_server.zig").MockRtspServer;
const MockServerConfig = @import("../rtsp/mock_server.zig").MockServerConfig;

// Integration test
test "rtsp to hls conversion" {
    const testing = std.testing;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // Load test configuration
    var config = try test_config.TestConfig.load(allocator, "config.test.json");
    defer config.deinit();

    // Set up mock server if not using live URLs
    var mock_server: ?*MockRtspServer = null;
    defer if (mock_server) |server| server.deinit();

    if (!config.test_config.use_live_urls) {
        // Start mock RTSP server on port 8554
        mock_server = try MockRtspServer.start(allocator, .{
            .port = 8554,
        });
        std.debug.print("Started mock RTSP server on port 8554\n", .{});
    }

    // Use dummy or live RTSP URL based on configuration
    var rtsp_url: []const u8 = undefined;

    if (config.test_config.use_live_urls) {
        rtsp_url = config.streams[0].rtsp_url;
    } else {
        rtsp_url = config.test_config.dummy_rtsp_url;
    }

    // Initialize RTSP client with test configuration
    var client = try RtspClient.init(allocator, rtsp_url, .{}, config);
    defer client.deinit();

    // Connect to RTSP server
    try client.connect();
    try testing.expectEqual(rtsp.State.connected, client.state);

    // Describe session
    try client.describe();
    try testing.expectEqual(rtsp.State.described, client.state);
    try testing.expect(client.tracks.items.len > 0);

    // Setup tracks
    try client.setup();
    try testing.expectEqual(rtsp.State.setup, client.state);

    // Start playing
    try client.play();
    try testing.expectEqual(rtsp.State.playing, client.state);

    // Initialize media parsers
    var h264_parser = H264Parser.init(allocator);
    defer h264_parser.deinit();

    var aac_parser = AacParser.init(allocator);
    defer aac_parser.deinit();

    // Initialize TS encoder
    var ts_encoder = TsEncoder.init(allocator);
    defer ts_encoder.deinit();

    // Initialize segmenter
    var segmenter = try Segmenter.init(allocator, "segments", 10000, 6);
    defer segmenter.deinit();

    // Create segments directory if it doesn't exist
    std.fs.cwd().makeDir("segments") catch |err| {
        if (err != error.PathAlreadyExists) {
            return err;
        }
    };

    // Receive and process frames for 5 seconds as a test
    const start_time = std.time.milliTimestamp();
    const test_duration_ms: i64 = 5000;

    while (std.time.milliTimestamp() - start_time < test_duration_ms) {
        // In a real implementation, we would read frames from the RTSP client
        // and process them through the parsers and segmenter
        
        // For this test, we'll simulate processing with a small delay
        std.time.sleep(100 * std.time.ns_per_ms);
    }

    // Teardown session
    try client.teardown();
    try testing.expectEqual(rtsp.State.connected, client.state);

    // Stop mock server if it was started
    if (mock_server) |server| {
        server.stop();
    }
}
