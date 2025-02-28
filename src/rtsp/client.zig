//! RTSP client implementation

const std = @import("std");
const common = @import("../common.zig");
const rtsp = @import("../rtsp.zig");
const Track = @import("track.zig").Track;
const TestConfig = @import("../test_config.zig").TestConfig;
const SdpParser = @import("sdp.zig").SdpParser;

const Error = common.Error;

/// RTSP client states
const State = enum {
    disconnected,
    connected,
    described,
    setup,
    playing,
    paused,
};

/// RTSP client configuration
pub const Config = struct {
    connection_timeout_ms: u32 = 5000,
    keep_alive_interval_ms: u32 = 30000,
    max_retries: u32 = 3,
    buffer_size: usize = 4096,
    base_port: u16 = 8000,
};

/// RTSP client for receiving media streams
pub const RtspClient = struct {
    allocator: std.mem.Allocator,
    url: []const u8,
    config: Config,
    state: State,
    test_config: ?TestConfig,

    // TCP connection for RTSP control
    tcp_conn: ?std.net.Stream,
    session_id: ?[]const u8,
    cseq: u32,

    // Media tracks
    tracks: std.ArrayList(Track),

    const Self = @This();

    /// Initialize a new RTSP client
    pub fn init(allocator: std.mem.Allocator, url: []const u8, config: Config, test_config_opt: ?TestConfig) !Self {
        return Self{
            .allocator = allocator,
            .url = try allocator.dupe(u8, url),
            .config = config,
            .state = .disconnected,
            .tcp_conn = null,
            .session_id = null,
            .cseq = 1,
            .tracks = std.ArrayList(Track).init(allocator),
            .test_config = test_config_opt,
        };
    }

    /// Connect to RTSP server
    pub fn connect(self: *Self) !void {
        if (self.state != .disconnected) return;

        var url_to_use = self.url;
        // Use test configuration if provided
        if (self.test_config) |*test_config| {
            if (test_config.test_config.use_live_urls) {
                if (test_config.streams.len > 0) {
                    url_to_use = test_config.streams[0].rtsp_url;
                }
            } else {
                url_to_use = test_config.test_config.dummy_rtsp_url;
            }
        }

        // For simplicity, just extract the domain from the URL manually
        var url_parts = std.mem.split(u8, url_to_use, "://");
        _ = url_parts.next(); // Skip the protocol part
        const rest = url_parts.next() orelse return Error.RtspConnectionFailed;
        
        const domain_end = std.mem.indexOfAny(u8, rest, ":/") orelse rest.len;
        const host = rest[0..domain_end];
        
        // Extract port, default to 554 for RTSP
        const port: u16 = if (domain_end < rest.len and rest[domain_end] == ':') blk: {
            const port_start = domain_end + 1;
            const port_end = std.mem.indexOfAny(u8, rest[port_start..], "/") orelse rest.len - port_start;
            const port_str = rest[port_start..port_start + port_end];
            break :blk std.fmt.parseInt(u16, port_str, 10) catch 554;
        } else 554;

        // Lookup address
        const addr = try std.net.Address.resolveIp(host, port);

        // Connect TCP socket
        self.tcp_conn = try std.net.tcpConnectToAddress(addr);
        errdefer if (self.tcp_conn) |conn| conn.close();

        self.state = .connected;
    }

    /// Send DESCRIBE request and parse SDP
    pub fn describe(self: *Self) !void {
        if (self.state != .connected) return Error.RtspConnectionFailed;

        const request = try std.fmt.allocPrint(
            self.allocator,
            "DESCRIBE {s} RTSP/1.0\r\nCSeq: {d}\r\nAccept: application/sdp\r\n\r\n",
            .{ self.url, self.cseq },
        );
        defer self.allocator.free(request);

        try self.sendRequest(request);
        const response = try self.readResponse();
        defer self.allocator.free(response);

        const sdp_start = std.mem.indexOf(u8, response, "\r\n\r\n") orelse return Error.SdpParseError;
        const sdp_content = response[sdp_start + 4 ..];

        // Parse SDP
        var parser = SdpParser.init(self.allocator, sdp_content);
        defer parser.deinit();
        try parser.parse();

        // Create tracks
        for (parser.media_descriptions.items) |media| {
            var track = try Track.init(self.allocator, media);
            errdefer track.deinit();
            try self.tracks.append(track);
        }

        self.state = .described;
        self.cseq += 1;
    }

    /// Setup media tracks
    pub fn setup(self: *Self) !void {
        if (self.state != .described) return Error.RtspConnectionFailed;

        const base_port = self.config.base_port;

        for (self.tracks.items, 0..) |*track, i| {
            const port = base_port + (@as(u16, @intCast(i)) * 2);
            try track.setup(port);

            // Send SETUP request
            const request = try std.fmt.allocPrint(
                self.allocator,
                "SETUP {s}/{s} RTSP/1.0\r\nCSeq: {d}\r\nTransport: RTP/AVP;unicast;client_port={d}-{d}\r\n{s}\r\n",
                .{
                    self.url,
                    track.control_url,
                    self.cseq,
                    port,
                    port + 1,
                    if (self.session_id) |sid|
                        try std.fmt.allocPrint(self.allocator, "Session: {s}\r\n", .{sid})
                    else
                        "",
                },
            );
            defer self.allocator.free(request);

            try self.sendRequest(request);
            const response = try self.readResponse();
            defer self.allocator.free(response);

            // Extract session ID from first track setup
            if (i == 0) {
                const session_start = std.mem.indexOf(u8, response, "Session: ") orelse return Error.RtspConnectionFailed;
                const session_end = std.mem.indexOfPos(u8, response, session_start, "\r\n") orelse return Error.RtspConnectionFailed;
                const session_id = response[session_start + 9 .. session_end];
                self.session_id = try self.allocator.dupe(u8, session_id);
            }

            self.cseq += 1;
        }

        self.state = .setup;
    }

    /// Start playing
    pub fn play(self: *Self) !void {
        if (self.state != .setup and self.state != .paused) return Error.RtspConnectionFailed;
        if (self.session_id == null) return Error.RtspConnectionFailed;

        const request = try std.fmt.allocPrint(
            self.allocator,
            "PLAY {s} RTSP/1.0\r\nCSeq: {d}\r\nSession: {s}\r\nRange: npt=0.000-\r\n\r\n",
            .{ self.url, self.cseq, self.session_id.? },
        );
        defer self.allocator.free(request);

        try self.sendRequest(request);
        const response = try self.readResponse();
        defer self.allocator.free(response);

        self.state = .playing;
        self.cseq += 1;
    }

    /// Stop playing
    pub fn pause(self: *Self) !void {
        if (self.state != .playing) return;
        if (self.session_id == null) return Error.RtspConnectionFailed;

        const request = try std.fmt.allocPrint(
            self.allocator,
            "PAUSE {s} RTSP/1.0\r\nCSeq: {d}\r\nSession: {s}\r\n\r\n",
            .{ self.url, self.cseq, self.session_id.? },
        );
        defer self.allocator.free(request);

        try self.sendRequest(request);
        const response = try self.readResponse();
        defer self.allocator.free(response);

        self.state = .paused;
        self.cseq += 1;
    }

    /// Teardown session
    pub fn teardown(self: *Self) !void {
        if (self.state == .disconnected) return;
        if (self.session_id == null) return Error.RtspConnectionFailed;

        const request = try std.fmt.allocPrint(
            self.allocator,
            "TEARDOWN {s} RTSP/1.0\r\nCSeq: {d}\r\nSession: {s}\r\n\r\n",
            .{ self.url, self.cseq, self.session_id.? },
        );
        defer self.allocator.free(request);

        try self.sendRequest(request);
        const response = try self.readResponse();
        defer self.allocator.free(response);

        self.state = .disconnected;
        self.cseq += 1;
    }

    /// Send raw request
    fn sendRequest(self: *Self, request: []const u8) !void {
        if (self.tcp_conn == null) return Error.RtspConnectionFailed;
        try self.tcp_conn.?.writer().writeAll(request);
    }

    /// Read response with timeout
    fn readResponse(self: *Self) ![]u8 {
        if (self.tcp_conn == null) return Error.RtspConnectionFailed;

        var buf = try self.allocator.alloc(u8, self.config.buffer_size);
        errdefer self.allocator.free(buf);

        var total_read: usize = 0;
        const start_time = std.time.milliTimestamp();

        while (true) {
            // Check timeout
            const elapsed = std.time.milliTimestamp() - start_time;
            if (elapsed > self.config.connection_timeout_ms) return Error.RtspConnectionFailed;

            // Read chunk
            const bytes_read = try self.tcp_conn.?.read(buf[total_read..]);
            if (bytes_read == 0) break;
            total_read += bytes_read;

            // Look for end of response
            if (std.mem.indexOf(u8, buf[0..total_read], "\r\n\r\n")) |pos| {
                // Check if we have Content-Length
                const content_length = blk: {
                    const content_len_str = "Content-Length: ";
                    if (std.mem.indexOf(u8, buf[0..total_read], content_len_str)) |start| {
                        const end = std.mem.indexOfPos(u8, buf[0..total_read], start, "\r\n") orelse break :blk 0;
                        const len_str = buf[start + content_len_str.len .. end];
                        break :blk try std.fmt.parseInt(usize, len_str, 10);
                    }
                    break :blk 0;
                };

                // If we have the full response, return it
                if (total_read >= pos + 4 + content_length) {
                    return buf[0..total_read];
                }
            }

            // Grow buffer if needed
            if (total_read == buf.len) {
                buf = try self.allocator.realloc(buf, buf.len * 2);
            }
        }

        return buf[0..total_read];
    }

    pub fn deinit(self: *Self) void {
        self.allocator.free(self.url);
        if (self.session_id) |sid| {
            self.allocator.free(sid);
        }
        for (self.tracks.items) |*track| {
            track.deinit();
        }
        self.tracks.deinit();
        if (self.tcp_conn) |conn| {
            conn.close();
        }
    }
};

test "rtsp client connect and describe" {
    // This test requires a local RTSP server
    if (true) return error.SkipZigTest;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var client = try RtspClient.init(allocator, "rtsp://localhost:8554/test", .{}, null);
    defer client.deinit();

    try client.connect();
    try std.testing.expectEqual(State.connected, client.state);

    try client.describe();
    try std.testing.expectEqual(State.described, client.state);
    try std.testing.expect(client.tracks.items.len > 0);
}
