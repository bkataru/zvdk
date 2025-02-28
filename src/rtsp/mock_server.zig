//! Mock RTSP server for testing

const std = @import("std");
const common = @import("../common.zig");
const Error = common.Error;

/// Mock RTSP server configuration
pub const MockServerConfig = struct {
    port: u16 = 8554,
    video_file: ?[]const u8 = null,
    audio_file: ?[]const u8 = null,
    simulate_errors: bool = false,
};

/// Mock RTSP server for testing
pub const MockRtspServer = struct {
    allocator: std.mem.Allocator,
    config: MockServerConfig,
    server: std.net.Server,
    running: std.atomic.Value(bool),
    thread: ?std.Thread,

    const Self = @This();

    /// Start a mock RTSP server
    pub fn start(allocator: std.mem.Allocator, config: MockServerConfig) !*Self {
        var server = try allocator.create(Self);
        errdefer allocator.destroy(server);

        const address = std.net.Address.initIp4([4]u8{ 127, 0, 0, 1 }, config.port);
        
        server.* = .{
            .allocator = allocator,
            .config = config,
            .server = try std.net.Server.init(.{
                .address = address,
                .reuse_address = true,
            }),
            .running = std.atomic.Value(bool).init(true),
            .thread = null,
        };

        server.thread = try std.Thread.spawn(.{}, serverLoop, .{server});
        return server;
    }

    fn serverLoop(self: *Self) void {
        while (self.running.load(.Acquire)) {
            const conn = self.server.accept() catch |err| {
                std.log.err("RTSP mock server accept error: {}", .{err});
                continue;
            };
            
            const client = conn.stream;
            handleClient(self, client) catch |err| {
                std.log.err("RTSP mock server client error: {}", .{err});
            };
        }
    }

    fn handleClient(self: *Self, stream: std.net.Stream) !void {
        defer stream.close();
        var buffer: [4096]u8 = undefined;
        
        // Simple request-response loop
        while (self.running.load(.Acquire)) {
            const bytes_read = try stream.read(&buffer);
            if (bytes_read == 0) break; // Client disconnected
            
            const request = buffer[0..bytes_read];
            
            // Respond based on request type
            if (std.mem.indexOf(u8, request, "OPTIONS") != null) {
                try stream.writeAll(
                    \\RTSP/1.0 200 OK
                    \\CSeq: 1
                    \\Public: DESCRIBE, SETUP, PLAY, PAUSE, TEARDOWN
                    \\
                    \\
                );
            } else if (std.mem.indexOf(u8, request, "DESCRIBE") != null) {
                // Extract CSeq
                var cseq: u32 = 1;
                if (std.mem.indexOf(u8, request, "CSeq:")) |cseq_pos| {
                    const cseq_line = std.mem.sliceTo(request[cseq_pos..], '\r');
                    const cseq_value = std.mem.trim(u8, cseq_line[5..], " \t");
                    cseq = std.fmt.parseInt(u32, cseq_value, 10) catch 1;
                }
                
                // Create SDP description with video and audio tracks
                const sdp = 
                    \\v=0
                    \\o=- 12345 12345 IN IP4 127.0.0.1
                    \\s=Mock RTSP Stream
                    \\t=0 0
                    \\m=video 0 RTP/AVP 96
                    \\a=rtpmap:96 H264/90000
                    \\a=fmtp:96 packetization-mode=1; profile-level-id=42e01f
                    \\m=audio 0 RTP/AVP 97
                    \\a=rtpmap:97 MPEG4-GENERIC/44100/2
                    \\a=fmtp:97 streamtype=5; profile-level-id=1; mode=AAC-hbr; sizelength=13; indexlength=3; indexdeltalength=3; config=1208
                    \\
                    \\
                ;
                
                const response = try std.fmt.allocPrint(
                    self.allocator,
                    \\RTSP/1.0 200 OK
                    \\CSeq: {d}
                    \\Content-Type: application/sdp
                    \\Content-Length: {d}
                    \\
                    \\{s}
                    ,
                    .{ cseq, sdp.len, sdp }
                );
                defer self.allocator.free(response);
                
                try stream.writeAll(response);
            } else if (std.mem.indexOf(u8, request, "SETUP") != null) {
                // Extract CSeq
                var cseq: u32 = 1;
                if (std.mem.indexOf(u8, request, "CSeq:")) |cseq_pos| {
                    const cseq_line = std.mem.sliceTo(request[cseq_pos..], '\r');
                    const cseq_value = std.mem.trim(u8, cseq_line[5..], " \t");
                    cseq = std.fmt.parseInt(u32, cseq_value, 10) catch 1;
                }
                
                const response = try std.fmt.allocPrint(
                    self.allocator,
                    \\RTSP/1.0 200 OK
                    \\CSeq: {d}
                    \\Session: 12345678
                    \\Transport: RTP/AVP;unicast;client_port=8000-8001;server_port=9000-9001
                    \\
                    \\
                    ,
                    .{cseq}
                );
                defer self.allocator.free(response);
                
                try stream.writeAll(response);
            } else if (std.mem.indexOf(u8, request, "PLAY") != null) {
                // Extract CSeq
                var cseq: u32 = 1;
                if (std.mem.indexOf(u8, request, "CSeq:")) |cseq_pos| {
                    const cseq_line = std.mem.sliceTo(request[cseq_pos..], '\r');
                    const cseq_value = std.mem.trim(u8, cseq_line[5..], " \t");
                    cseq = std.fmt.parseInt(u32, cseq_value, 10) catch 1;
                }
                
                const response = try std.fmt.allocPrint(
                    self.allocator,
                    \\RTSP/1.0 200 OK
                    \\CSeq: {d}
                    \\Session: 12345678
                    \\Range: npt=0.000-
                    \\RTP-Info: url=rtsp://localhost:8554/test/track1;seq=1;rtptime=0,url=rtsp://localhost:8554/test/track2;seq=1;rtptime=0
                    \\
                    \\
                    ,
                    .{cseq}
                );
                defer self.allocator.free(response);
                
                try stream.writeAll(response);
                
                // TODO: Start sending RTP packets based on configured media files
                // For now, just simulate a small delay
                std.time.sleep(100 * std.time.ns_per_ms);
            } else if (std.mem.indexOf(u8, request, "TEARDOWN") != null) {
                // Extract CSeq
                var cseq: u32 = 1;
                if (std.mem.indexOf(u8, request, "CSeq:")) |cseq_pos| {
                    const cseq_line = std.mem.sliceTo(request[cseq_pos..], '\r');
                    const cseq_value = std.mem.trim(u8, cseq_line[5..], " \t");
                    cseq = std.fmt.parseInt(u32, cseq_value, 10) catch 1;
                }
                
                const response = try std.fmt.allocPrint(
                    self.allocator,
                    \\RTSP/1.0 200 OK
                    \\CSeq: {d}
                    \\Session: 12345678
                    \\
                    \\
                    ,
                    .{cseq}
                );
                defer self.allocator.free(response);
                
                try stream.writeAll(response);
                break; // End the connection after teardown
            }
        }
    }

    /// Stop the mock RTSP server
    pub fn stop(self: *Self) void {
        self.running.store(false, .Release);
        if (self.thread) |thread| {
            thread.join();
            self.thread = null;
        }
        self.server.close();
    }

    /// Clean up resources
    pub fn deinit(self: *Self) void {
        if (self.running.load(.Acquire)) {
            self.stop();
        }
        self.allocator.destroy(self);
    }
};

test "mock rtsp server" {
    const testing = std.testing;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    
    // Skip if we don't want to run network tests
    if (true) return error.SkipZigTest;
    
    var server = try MockRtspServer.start(allocator, .{});
    defer server.deinit();
    
    // TODO: Add actual connection tests
    std.time.sleep(100 * std.time.ns_per_ms);
}
