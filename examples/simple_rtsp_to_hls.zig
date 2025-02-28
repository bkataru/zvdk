const std = @import("std");
const zvdk = @import("zvdk");

// Global variable for signal handling
var g_running: bool = true;

pub fn main() !void {
    // Initialize
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Parse command line arguments
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 2) {
        std.debug.print("Usage: {s} <rtsp_url> [output_dir] [port]\n", .{args[0]});
        return;
    }

    const rtsp_url = args[1];
    const output_dir = if (args.len > 2) args[2] else "segments";
    const port = if (args.len > 3) try std.fmt.parseInt(u16, args[3], 10) else 8080;

    // Create output directory
    std.fs.cwd().makeDir(output_dir) catch |err| {
        if (err != error.PathAlreadyExists) return err;
    };

    // Initialize RTSP client
    var client = try zvdk.rtsp.RtspClient.init(allocator, rtsp_url, .{}, null);
    defer client.deinit();

    // Connect and setup
    try client.connect();
    try client.describe();
    try client.setup();

    // Initialize components
    var h264_parser = zvdk.media.h264.H264Parser.init(allocator);
    defer h264_parser.deinit();

    var aac_parser = zvdk.media.aac.AacParser.init(allocator);
    defer aac_parser.deinit();

    var ts_encoder = zvdk.ts.TsEncoder.init(allocator);
    defer ts_encoder.deinit();

    var segmenter = try zvdk.ts.Segmenter.init(allocator, output_dir, 10000, 6);
    defer segmenter.deinit();

    // Initialize HLS server
    var hls_server = try zvdk.hls.HlsServer.init(allocator, output_dir, port);
    defer hls_server.deinit();

    // Start HLS server in a separate thread
    var server_running = true;
    var server_thread = try std.Thread.spawn(.{}, struct {
        fn serverLoop(server: **zvdk.hls.HlsServer, is_running: *bool) !void {
            try server.*.start();
            while (is_running.*) {
                std.time.sleep(100 * std.time.ns_per_ms);
            }
            server.*.stop();
        }
    }.serverLoop, .{ &hls_server, &server_running });

    // Start playing
    try client.play();
    std.debug.print("RTSP stream started\n", .{});
    std.debug.print("HLS stream available at http://localhost:{d}/index.m3u8\n", .{port});

    // Setup signal handling for graceful shutdown
    const signal = std.posix.SIG.INT;
    
    try std.posix.sigaction(signal, &std.posix.Sigaction{
        .handler = .{ .handler = struct {
            fn handleSignal(sig: i32) callconv(.C) void {
                _ = sig;
                g_running = false;
            }
        }.handleSignal },
        .mask = std.posix.empty_sigset,
        .flags = 0,
    }, null);

    std.debug.print("Press Ctrl+C to exit\n", .{});
    
    // Main processing loop
    while (g_running) {
        // In a real implementation, we would read frames from the RTSP client
        // and process them to create TS segments

        // Simulated frame processing for demo purposes
        // For demo: create a new segment every few seconds
        const segment = try segmenter.createSegment("sample_segment", "segment_1.ts");
        try hls_server.addSegment(segment);
        std.debug.print("Created segment: {s}\n", .{segment.filename});

        // Sleep to avoid busy loop
        std.time.sleep(3000 * std.time.ns_per_ms);
    }

    // Cleanup
    std.debug.print("Shutting down...\n", .{});
    try client.teardown();
    server_running = false;
    server_thread.join();
    std.debug.print("Done\n", .{});
}
