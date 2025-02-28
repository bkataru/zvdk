# zvdk API Documentation

This document provides detailed information about using the zvdk library API.

## Table of Contents

1. [RTSP Client](#rtsp-client)
2. [Media Parsers](#media-parsers)
3. [Transport Stream (TS)](#transport-stream-ts)
4. [HLS](#hls)
5. [Error Handling](#error-handling)
6. [Complete Example](#complete-example)

## RTSP Client

The RTSP client is used to connect to RTSP servers and manage the streaming session.

### Initialization

```zig
const zvdk = @import("zvdk");
const RtspClient = zvdk.rtsp.RtspClient;

// Initialize with default options
var client = try RtspClient.init(allocator, rtsp_url, .{}, null);
defer client.deinit();

// Initialize with custom options
const options = RtspClient.Options{
    .timeout_ms = 5000,
    .reconnect_attempts = 3,
    .user_agent = "zvdk/1.0",
};
var client = try RtspClient.init(allocator, rtsp_url, options, null);
```

### Connection and Session Management

```zig
// Connect to the RTSP server
try client.connect();

// Get stream information
try client.describe();

// Setup tracks
try client.setup();

// Start streaming
try client.play();

// Stop streaming
try client.teardown();
```

### Track Information

After calling `describe()`, track information is available:

```zig
// Get number of tracks
const track_count = client.tracks.items.len;

// Access track information
for (client.tracks.items) |track| {
    std.debug.print("Track type: {s}\n", .{@tagName(track.media_type)});
    std.debug.print("Codec: {s}\n", .{track.codec});
    std.debug.print("Control URL: {s}\n", .{track.control_url});
}
```

## Media Parsers

Media parsers extract media frames from RTP packets.

### H.264 Parser

```zig
const H264Parser = zvdk.media.h264.H264Parser;

// Initialize parser
var parser = H264Parser.init(allocator);
defer parser.deinit();

// Parse RTP packet
const rtp_packet = ...;
const frame = try parser.parse(rtp_packet);
if (frame) |f| {
    // Use the H.264 frame
    defer f.deinit();
}
```

### AAC Parser

```zig
const AacParser = zvdk.media.aac.AacParser;

// Initialize parser
var parser = AacParser.init(allocator);
defer parser.deinit();

// Parse RTP packet
const rtp_packet = ...;
const frame = try parser.parse(rtp_packet);
if (frame) |f| {
    // Use the AAC frame
    defer f.deinit();
}
```

### H.265 Parser

```zig
const H265Parser = zvdk.media.h265.H265Parser;

// Initialize parser
var parser = H265Parser.init(allocator);
defer parser.deinit();

// Parse RTP packet
const rtp_packet = ...;
const frame = try parser.parse(rtp_packet);
if (frame) |f| {
    // Use the H.265 frame
    defer f.deinit();
}
```

## Transport Stream (TS)

The TS module handles creation of transport stream packets and segments.

### TS Encoder

```zig
const TsEncoder = zvdk.ts.TsEncoder;

// Initialize encoder
var encoder = TsEncoder.init(allocator);
defer encoder.deinit();

// Encode video frame
const video_frame = ...;
const video_ts = try encoder.encodeVideoPayload(video_frame);
defer video_ts.deinit();

// Encode audio frame
const audio_frame = ...;
const audio_ts = try encoder.encodeAudioPayload(audio_frame);
defer audio_ts.deinit();
```

### Segmenter

```zig
const Segmenter = zvdk.ts.Segmenter;

// Initialize segmenter
// Parameters: allocator, output directory, segment duration in ms, max segments
var segmenter = try Segmenter.init(allocator, "segments", 10000, 6);
defer segmenter.deinit();

// Add TS packets to current segment
try segmenter.addTsPackets(ts_packets);

// Finalize the current segment
const segment = try segmenter.finalizeSegment();

// Get segment info
std.debug.print("Segment filename: {s}\n", .{segment.filename});
std.debug.print("Segment duration: {d}ms\n", .{segment.duration});
```

## HLS

The HLS module handles playlist generation and HTTP serving of HLS content.

### Playlist Generator

```zig
const PlaylistGenerator = zvdk.hls.PlaylistGenerator;

// Initialize generator
// Parameters: allocator, segment duration in seconds, max segments, playlist path
var generator = try PlaylistGenerator.init(allocator, 10, 6, "index.m3u8");
defer generator.deinit();

// Add a segment
try generator.addSegment("segment0.ts", 10000);

// Generate playlist
try generator.generatePlaylist();

// Get playlist content as string
const content = try generator.generatePlaylistContent();
defer allocator.free(content);
```

### HLS Server

```zig
const HlsServer = zvdk.hls.HlsServer;

// Initialize server
// Parameters: allocator, segments directory, port
var server = try HlsServer.init(allocator, "segments", 8080);
defer server.deinit();

// Start the server
try server.start();

// Stop the server
server.stop();
```

## Error Handling

zvdk uses Zig's error handling system. Common errors include:

```zig
// Example of handling errors
const result = client.connect() catch |err| {
    switch (err) {
        error.ConnectionFailed => {
            std.debug.print("Could not connect to RTSP server\n", .{});
            return;
        },
        error.Timeout => {
            std.debug.print("Connection timed out\n", .{});
            return;
        },
        else => return err,
    }
};
```

## Complete Example

Here's a complete example showing how to use zvdk to stream from an RTSP source to HLS:

```zig
const std = @import("std");
const zvdk = @import("zvdk");

pub fn main() !void {
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

    // Initialize parsers
    var h264_parser = zvdk.media.h264.H264Parser.init(allocator);
    defer h264_parser.deinit();

    var aac_parser = zvdk.media.aac.AacParser.init(allocator);
    defer aac_parser.deinit();

    // Initialize TS encoder
    var ts_encoder = zvdk.ts.TsEncoder.init(allocator);
    defer ts_encoder.deinit();

    // Initialize segmenter
    var segmenter = try zvdk.ts.Segmenter.init(allocator, output_dir, 10000, 6);
    defer segmenter.deinit();

    // Initialize HLS server
    var hls_server = try zvdk.hls.HlsServer.init(allocator, output_dir, port);
    defer hls_server.deinit();

    // Start HLS server in a separate thread
    var server_running = true;
    var server_thread = try std.Thread.spawn(.{}, struct {
        fn serverLoop(server: *zvdk.hls.HlsServer, is_running: *bool) !void {
            try server.start();
            while (is_running.*) {
                std.time.sleep(100 * std.time.ns_per_ms);
            }
            server.stop();
        }
    }.serverLoop, .{ &hls_server, &server_running });

    // Start playing
    try client.play();
    std.debug.print("HLS stream available at http://localhost:{d}/index.m3u8\n", .{port});

    // Setup signal handling for graceful shutdown
    var running = true;
    const signal = std.os.Sigint;
    try std.os.sigaction(signal, &std.os.Sigaction{
        .handler = .{ .handler = struct {
            fn handleSignal(sig: i32) callconv(.C) void {
                _ = sig;
                running = false;
            }
        }.handleSignal },
        .mask = std.os.empty_sigset,
        .flags = 0,
    }, null);

    // Main processing loop
    while (running) {
        // Process frames from RTSP client
        try client.processFrames();
        
        // Example of frame processing (simplified)
        if (client.getFrame()) |frame| {
            defer frame.deinit();
            
            var ts_packets: *std.ArrayList(zvdk.ts.TsPacket) = undefined;
            
            if (frame.media_type == .video) {
                ts_packets = try ts_encoder.encodeVideoPayload(frame);
            } else if (frame.media_type == .audio) {
                ts_packets = try ts_encoder.encodeAudioPayload(frame);
            }
            
            defer ts_packets.deinit();
            
            try segmenter.addTsPackets(ts_packets.items);
            
            if (segmenter.shouldCreateNewSegment()) {
                const segment = try segmenter.finalizeSegment();
                try hls_server.addSegment(segment);
            }
        }
        
        std.time.sleep(10 * std.time.ns_per_ms);
    }

    // Cleanup
    try client.teardown();
    server_running = false;
    server_thread.join();
}
```

For more detailed examples, see the [examples directory](../examples/) in the repository.
