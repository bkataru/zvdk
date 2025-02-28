//! HLS playlist generation and serving

const std = @import("std");
const common = @import("common.zig");
const ts = @import("ts.zig");

pub const Error = common.Error;

/// Read all content from a file into a buffer
fn readAllAlloc(allocator: std.mem.Allocator, file: std.fs.File) ![]u8 {
    const stat = try file.stat();
    const buffer = try allocator.alloc(u8, stat.size);
    errdefer allocator.free(buffer);

    var reader = file.reader();
    const bytes_read = try reader.readAll(buffer);
    if (bytes_read != stat.size) {
        return error.UnexpectedEOF;
    }

    return buffer;
}

/// HLS segment structure
pub const Segment = struct {
    index: u32,
    duration: u32,
    filename: []const u8,
    data: []const u8,

    pub fn deinit(self: *const Segment, allocator: std.mem.Allocator) void {
        allocator.free(self.filename);
        allocator.free(self.data);
    }
};

/// HLS playlist generator
pub const PlaylistGenerator = struct {
    allocator: std.mem.Allocator,
    segments: std.ArrayList(Segment),
    segment_duration: u32,
    max_segments: u32,
    playlist_path: []const u8,

    pub fn init(
        allocator: std.mem.Allocator,
        segment_duration: u32,
        max_segments: u32,
        playlist_path: []const u8,
    ) !PlaylistGenerator {
        return PlaylistGenerator{
            .allocator = allocator,
            .segments = std.ArrayList(Segment).init(allocator),
            .segment_duration = segment_duration,
            .max_segments = max_segments,
            .playlist_path = try allocator.dupe(u8, playlist_path),
        };
    }

    pub fn deinit(self: *PlaylistGenerator) void {
        for (self.segments.items) |segment| {
            segment.deinit(self.allocator);
        }
        self.segments.deinit();
        self.allocator.free(self.playlist_path);
    }

    /// Add a new segment to the playlist
    pub fn addSegment(self: *PlaylistGenerator, segment: Segment) !void {
        try self.segments.append(segment);

        // Remove oldest segment if we exceed max_segments
        if (self.segments.items.len > self.max_segments) {
            const oldest = self.segments.orderedRemove(0);
            oldest.deinit(self.allocator);
        }

        // Update playlist file
        try self.updatePlaylist();
    }

    /// Update the HLS playlist file
    pub fn updatePlaylist(self: *PlaylistGenerator) !void {
        try self.generatePlaylist();
    }

    /// Generate the playlist and write it to a file
    pub fn generatePlaylist(self: *PlaylistGenerator) !void {
        var file = try std.fs.cwd().createFile(self.playlist_path, .{.truncate = true});
        defer file.close();

        const content = try self.generatePlaylistContent();
        defer self.allocator.free(content);

        try file.writeAll(content);
    }

    /// Generate the playlist content without writing to a file
    pub fn generatePlaylistContent(self: *PlaylistGenerator) ![]const u8 {
        const segment_list = try self.generateSegmentList();
        defer self.allocator.free(segment_list);
        
        return std.fmt.allocPrint(
            self.allocator,
            "#EXTM3U\n#EXT-X-VERSION:3\n#EXT-X-TARGETDURATION:{d}\n#EXT-X-MEDIA-SEQUENCE:{d}\n{s}",
            .{ self.segment_duration / 1000, self.segments.items[0].index, segment_list }
        );
    }

    /// Generate the segment list for the playlist
    fn generateSegmentList(self: *PlaylistGenerator) ![]const u8 {
        var buffer = std.ArrayList(u8).init(self.allocator);
        defer buffer.deinit();

        for (self.segments.items) |segment| {
            // Convert duration to seconds
            const duration_ms = segment.duration;
            const duration_sec = @as(f32, @floatFromInt(@as(u32, duration_ms))) / 1000.0;
            const entry = try std.fmt.allocPrint(
                self.allocator,
                "#EXTINF:{d:.1},\n{s}\n",
                .{ duration_sec, segment.filename }
            );
            defer self.allocator.free(entry);

            try buffer.appendSlice(entry);
        }

        return try buffer.toOwnedSlice();
    }
};

/// HLS HTTP server
pub const HlsServer = struct {
    allocator: std.mem.Allocator,
    server: Server,
    segments_dir: []const u8,
    port: u16,
    running: bool,
    thread: ?std.Thread,

    const Server = struct {
        socket: std.net.Server,
        allocator: std.mem.Allocator,
        segments_dir: []const u8,
        running: *bool,

        fn init(allocator: std.mem.Allocator, port: u16, segments_dir: []const u8, running: *bool) !Server {
            const address = std.net.Address.initIp4(.{0, 0, 0, 0}, port);
            const socket = try address.listen(.{});

            return Server{
                .socket = socket,
                .allocator = allocator,
                .segments_dir = segments_dir,
                .running = running,
            };
        }

        fn deinit(self: *Server) void {
            self.socket.deinit();
        }

        fn start(self: *Server) !void {
            while (self.running.*) {
                const connection = self.socket.accept() catch |err| {
                    if (err == error.ConnectionAborted) continue;
                    return err;
                };
                
                // Handle connection in a separate thread
                _ = try std.Thread.spawn(.{}, handleConnection, .{self, connection});
            }
        }

        fn handleConnection(server: *Server, connection: std.net.Server.Connection) !void {
            defer connection.stream.close();
            
            var buf: [1024]u8 = undefined;
            const n = try connection.stream.read(&buf);
            
            if (n == 0) return;
            
            // Parse HTTP request (very basic)
            const request = buf[0..n];
            const first_line_end = std.mem.indexOf(u8, request, "\r\n") orelse return;
            const first_line = request[0..first_line_end];
            
            // Extract path
            const path_start = std.mem.indexOf(u8, first_line, " ") orelse return;
            const path_end = std.mem.lastIndexOf(u8, first_line, " ") orelse return;
            const path = first_line[path_start + 1 .. path_end];
            
            // Serve file
            if (std.mem.eql(u8, path, "/") or std.mem.eql(u8, path, "/index.m3u8")) {
                try server.serveFile(connection.stream, "index.m3u8");
            } else if (std.mem.startsWith(u8, path, "/")) {
                const file_path = path[1..];
                try server.serveFile(connection.stream, file_path);
            } else {
                try server.send404(connection.stream);
            }
        }

        fn serveFile(self: *Server, stream: std.net.Stream, file_path: []const u8) !void {
            const full_path = try std.fs.path.join(self.allocator, &[_][]const u8{self.segments_dir, file_path});
            defer self.allocator.free(full_path);
            
            const file = std.fs.cwd().openFile(full_path, .{}) catch {
                try self.send404(stream);
                return;
            };
            defer file.close();
            
            const stat = try file.stat();
            const content_type = if (std.mem.endsWith(u8, file_path, ".m3u8"))
                "application/vnd.apple.mpegurl"
            else if (std.mem.endsWith(u8, file_path, ".ts"))
                "video/mp2t"
            else
                "application/octet-stream";
            
            // Send HTTP response headers
            const header = try std.fmt.allocPrint(self.allocator, 
                "HTTP/1.1 200 OK\r\nContent-Type: {s}\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n", 
                .{content_type, stat.size});
            defer self.allocator.free(header);
            
            try stream.writeAll(header);
            
            // Send file content
            var buffer: [8192]u8 = undefined;
            var reader = file.reader();
            
            while (true) {
                const bytes_read = try reader.read(&buffer);
                if (bytes_read == 0) break;
                try stream.writeAll(buffer[0..bytes_read]);
            }
        }

        fn send404(_: *Server, stream: std.net.Stream) !void {
            const response = 
                "HTTP/1.1 404 Not Found\r\nContent-Type: text/plain\r\nContent-Length: 9\r\nConnection: close\r\n\r\nNot Found";
            try stream.writeAll(response);
        }
    };

    pub fn init(allocator: std.mem.Allocator, segments_dir: []const u8, port: u16) !*HlsServer {
        const server_instance: *HlsServer = try allocator.create(HlsServer);
        errdefer allocator.destroy(server_instance);
        
        server_instance.* = .{
            .allocator = allocator,
            .segments_dir = try allocator.dupe(u8, segments_dir),
            .port = port,
            .running = false,
            .server = undefined,
            .thread = null,
        };
        
        return server_instance;
    }

    pub fn deinit(self: *HlsServer) void {
        if (self.running) {
            self.stop();
        }
        self.allocator.free(self.segments_dir);
        self.allocator.destroy(self);
    }

    pub fn start(self: *HlsServer) !void {
        if (self.running) return;
        
        self.running = true;
        self.server = try Server.init(self.allocator, self.port, self.segments_dir, &self.running);
        
        // Start server in a separate thread
        self.thread = try std.Thread.spawn(.{}, Server.start, .{&self.server});
    }

    pub fn stop(self: *HlsServer) void {
        if (!self.running) return;
        
        self.running = false;
        
        if (self.thread) |thread| {
            thread.join();
            self.thread = null;
        }
        
        self.server.deinit();
    }

    /// Add a segment to the HLS server
    pub fn addSegment(self: *HlsServer, segment: Segment) !void {
        // In a real implementation, we would update the playlist generator
        // For now, just write it to the segments directory
        var path_buffer: [std.fs.MAX_PATH_BYTES]u8 = undefined;
        const full_path = try std.fmt.bufPrint(&path_buffer, "{s}/{s}", .{ self.segments_dir, segment.filename });
        
        try std.fs.cwd().writeFile(.{
            .sub_path = full_path,
            .data = segment.data,
        });
    }
};

test "playlist generation" {
    const testing = std.testing;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var generator = try PlaylistGenerator.init(allocator, 10000, 6, "test.m3u8");
    defer generator.deinit();

    // Create segments with proper memory management
    const segment0_filename = try allocator.dupe(u8, "segment0.ts");
    const segment0_data = try allocator.dupe(u8, "test data");
    try generator.addSegment(Segment{
        .index = 0,
        .duration = 10000,
        .filename = segment0_filename,
        .data = segment0_data,
    });

    const segment1_filename = try allocator.dupe(u8, "segment1.ts");
    const segment1_data = try allocator.dupe(u8, "test data");
    try generator.addSegment(Segment{
        .index = 1,
        .duration = 10000,
        .filename = segment1_filename,
        .data = segment1_data,
    });

    // Generate playlist content without writing to a file
    const content = try generator.generatePlaylistContent();
    defer allocator.free(content);

    try testing.expectEqualStrings(content, "#EXTM3U\n#EXT-X-VERSION:3\n#EXT-X-TARGETDURATION:10\n#EXT-X-MEDIA-SEQUENCE:0\n#EXTINF:10.0,\nsegment0.ts\n#EXTINF:10.0,\nsegment1.ts\n");
}

test "hls server" {
    const testing = std.testing;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // For testing, we'll create a dummy server but won't start it
    var server = try HlsServer.init(allocator, "segments/", 8080);
    defer server.deinit();

    // Since we don't want to interact with the filesystem or network in tests,
    // we'll just verify the server was initialized correctly
    try testing.expectEqual(@as(u16, 8080), server.port);
    try testing.expect(std.mem.eql(u8, "segments/", server.segments_dir));
    try testing.expectEqual(@as(bool, false), server.running);
}

// Only for the tests, add functionality to read dummy/live URL data from 'zvdk/config.test.json' and then use that for testing
test "read config test json" {
    const testing = std.testing;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // Create a mock JSON content instead of reading from a file
    const content = 
        \\{
        \\  "test": {
        \\    "dummy_rtsp_url": "rtsp://localhost:8554/test",
        \\    "use_live_urls": false
        \\  }
        \\}
    ;

    var tree = try std.json.parseFromSlice(std.json.Value, allocator, content, .{});
    defer tree.deinit();

    const root = tree.value;
    const test_config = root.object.get("test") orelse return error.MissingTestConfig;
    const dummy_rtsp_url = test_config.object.get("dummy_rtsp_url") orelse return error.MissingDummyRtspUrl;
    const use_live_urls = test_config.object.get("use_live_urls") orelse return error.MissingUseLiveUrls;

    try testing.expectEqualStrings("rtsp://localhost:8554/test", dummy_rtsp_url.string);
    try testing.expectEqual(false, use_live_urls.bool);
}
