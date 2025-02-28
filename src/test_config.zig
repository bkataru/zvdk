//! Test configuration handling

const std = @import("std");

pub const TestStream = struct {
    id: []const u8,
    name: []const u8,
    rtsp_url: []const u8,

    pub fn deinit(self: *const TestStream, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.name);
        allocator.free(self.rtsp_url);
    }
};

pub const ConfigTest = struct {
    dummy_rtsp_url: []const u8,
    use_live_urls: bool,

    pub fn init() ConfigTest {
        return .{
            .dummy_rtsp_url = "",
            .use_live_urls = false,
        };
    }
};

pub const TestConfig = struct {
    streams: []TestStream = &[_]TestStream{},
    test_config: ConfigTest = ConfigTest.init(),
    allocator: std.mem.Allocator,

    pub fn load(allocator: std.mem.Allocator, config_path: []const u8) !TestConfig {
        const file = try std.fs.cwd().openFile(config_path, .{});
        defer file.close();

        const content = try file.readToEndAlloc(allocator, 1024 * 1024);
        defer allocator.free(content);

        var parser = std.json.Parser.init(allocator, false);
        defer parser.deinit();

        var tree = try parser.parse(content);
        defer tree.deinit();

        var config = .{ .allocator = allocator };

        // Parse streams array
        if (tree.root.Object.get("streams")) |streams_value| {
            const streams = streams_value.Array;
            config.streams = try allocator.alloc(TestStream, streams.items.len);
            for (streams.items, 0..) |stream, i| {
                config.streams[i] = TestStream{
                    .id = try allocator.dupe(u8, stream.Object.get("id").?.String),
                    .name = try allocator.dupe(u8, stream.Object.get("name").?.String),
                    .rtsp_url = try allocator.dupe(u8, stream.Object.get("rtsp_url").?.String),
                };
            }
        }

        // Parse test config
        if (tree.root.Object.get("test")) |test_config_value| {
            const test_obj = test_config_value.Object;
            config.test_config.dummy_rtsp_url = try allocator.dupe(u8, test_obj.get("dummy_rtsp_url").?.String);
            config.test_config.use_live_urls = test_obj.get("use_live_urls").?.Bool;
        }

        return config;
    }

    pub fn deinit(self: *TestConfig) void {
        self.allocator.free(self.test_config.dummy_rtsp_url);
        for (self.streams) |*stream| {
            stream.deinit(self.allocator);
        }
        self.allocator.free(self.streams);
    }
};

test "config parsing" {
    const testing = std.testing;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var config = try TestConfig.load(allocator, "config.test.json");
    defer config.deinit();

    try testing.expectEqual(@as(usize, 5), config.streams.len);
    try testing.expectEqualStrings("test-noida", config.streams[0].id);
    try testing.expectEqualStrings("Test Noida", config.streams[0].name);
    try testing.expectEqualStrings("rtsp://localhost:8554/test", config.test_config.dummy_rtsp_url);
    try testing.expect(config.test_config.use_live_urls);
}
