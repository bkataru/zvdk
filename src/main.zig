const std = @import("std");
const rtsp = @import("rtsp.zig");
const media = @import("media.zig");
const ts = @import("ts.zig");
const hls = @import("hls.zig");
const test_config = @import("test_config.zig");

const RtspClient = rtsp.RtspClient;
const H264Parser = media.h264.H264Parser;
const AacParser = media.aac.AacParser;
const TsEncoder = ts.TsEncoder;
const Segmenter = ts.Segmenter;
const HlsServer = hls.HlsServer;

var running: bool = true;

pub fn main() !void {
    // Parse command line arguments
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    // Check for arguments
    if (args.len < 2) {
        std.debug.print("Usage: zvdk <rtsp_url> [output_dir] [port]\n", .{});
        return;
    }

    // Get arguments
    const rtsp_url = args[1];
    const output_dir = if (args.len > 2) args[2] else "segments";
    const port = if (args.len > 3) try std.fmt.parseInt(u16, args[3], 10) else 8080;

    // Create output directory if it doesn't exist
    std.fs.cwd().makeDir(output_dir) catch |err| {
        if (err != error.PathAlreadyExists) {
            std.debug.print("Error creating output directory: {any}\n", .{err});
            return err;
        }
    };

    // Initialize RTSP client
    var client = try RtspClient.init(allocator, rtsp_url, .{}, null);
    defer client.deinit();

    std.debug.print("Connecting to RTSP server: {s}\n", .{rtsp_url});

    // Connect to RTSP server
    try client.connect();
    std.debug.print("Connected to RTSP server\n", .{});

    // Describe session
    try client.describe();
    std.debug.print("Media tracks found: {d}\n", .{client.tracks.items.len});

    // Setup tracks
    try client.setup();
    std.debug.print("Tracks setup\n", .{});

    // Initialize media parsers
    var h264_parser = H264Parser.init(allocator);
    defer h264_parser.deinit();

    var aac_parser = AacParser.init(allocator);
    defer aac_parser.deinit();

    // Initialize TS encoder
    var ts_encoder = TsEncoder.init(allocator);
    defer ts_encoder.deinit();

    // Initialize segmenter
    var segmenter = try Segmenter.init(allocator, output_dir, 10000, 6);
    defer segmenter.deinit();

    // Start HLS server
    var hls_server = try HlsServer.init(allocator, output_dir, port);
    var hls_server_running = true;
    
    // Start the server in a separate thread
    var server_thread = try std.Thread.spawn(.{}, struct {
        fn serverLoop(server: **HlsServer, is_running: *bool) !void {
            try server.*.start();
            while (is_running.*) {
                std.time.sleep(100 * std.time.ns_per_ms);
            }
            server.*.stop();
        }
    }.serverLoop, .{ &hls_server, &hls_server_running });

    // Start playing
    try client.play();
    std.debug.print("Playing RTSP stream\n", .{});
    std.debug.print("HLS stream available at http://localhost:{d}/index.m3u8\n", .{port});

    // Process frames
    const signal = std.posix.SIG.INT;
    const handler = struct {
        fn handleSignal(sig: i32) callconv(.C) void {
            _ = sig;
            running = false;
        }
    }.handleSignal;
    
    // Set up signal handler
    try std.posix.sigaction(signal, &std.posix.Sigaction{
        .handler = .{ .handler = handler },
        .mask = std.posix.empty_sigset,
        .flags = 0,
    }, null);

    std.debug.print("Press Ctrl+C to exit\n", .{});

    // Main processing loop
    while (running) {
        // In a real implementation, we would read frames from RTSP client
        // and process them appropriately
        std.time.sleep(1000 * std.time.ns_per_ms);
    }

    // Teardown and cleanup
    std.debug.print("Stopping...\n", .{});
    try client.teardown();
    hls_server_running = false;
    server_thread.join();
    std.debug.print("Done\n", .{});
}

test "simple test" {
    var list = std.ArrayList(i32).init(std.testing.allocator);
    defer list.deinit();
    try list.append(42);
    try std.testing.expectEqual(@as(i32, 42), list.pop());
}
