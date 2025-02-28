//! SDP (Session Description Protocol) parser

const std = @import("std");
const common = @import("../common.zig");
const rtsp = @import("../rtsp.zig");
const MediaInfo = rtsp.MediaInfo;
const MediaType = rtsp.MediaType;
const ProtoType = rtsp.ProtoType;

/// SDP Parser errors
const Error = error{
    InvalidSdp,
    UnsupportedCodec,
    MissingField,
    InvalidFormat,
};

/// SDP Parser for extracting media information
pub const SdpParser = struct {
    allocator: std.mem.Allocator,
    content: []const u8,
    media_descriptions: std.ArrayList(MediaInfo),

    const Self = @This();

    /// Initialize a new SDP parser
    pub fn init(allocator: std.mem.Allocator, content: []const u8) Self {
        return Self{
            .allocator = allocator,
            .content = content,
            .media_descriptions = std.ArrayList(MediaInfo).init(allocator),
        };
    }

    /// Parse SDP content and return list of media descriptions
    pub fn parse(self: *Self) !void {
        var lines = std.mem.tokenize(u8, self.content, "\r\n");
        var current_media: ?MediaInfo = null;

        while (lines.next()) |line| {
            if (line.len < 2) continue;

            switch (line[0]) {
                'm' => {
                    if (line[1] != '=') continue;
                    if (current_media != null) {
                        try self.media_descriptions.append(current_media.?);
                    }
                    current_media = try self.parseMediaLine(line[2..]);
                },
                'a' => {
                    if (line[1] != '=') continue;
                    if (current_media != null) {
                        try self.parseAttributeLine(line[2..], &current_media.?);
                    }
                },
                else => {},
            }
        }

        if (current_media != null) {
            try self.media_descriptions.append(current_media.?);
        }
    }

    /// Parse media line like "m=video 0 RTP/AVP 96"
    fn parseMediaLine(self: *Self, line: []const u8) !MediaInfo {
        var iter = std.mem.tokenize(u8, line, " ");
        const media_type_str = iter.next() orelse return Error.InvalidFormat;
        const port_str = iter.next() orelse return Error.InvalidFormat;
        const proto_str = iter.next() orelse return Error.InvalidFormat;
        const payload_type_str = iter.next() orelse return Error.InvalidFormat;

        const media_type = if (std.mem.eql(u8, media_type_str, "video"))
            MediaType.video
        else if (std.mem.eql(u8, media_type_str, "audio"))
            MediaType.audio
        else
            return Error.UnsupportedCodec;

        const port = try std.fmt.parseInt(u16, port_str, 10);
        const payload_type = try std.fmt.parseInt(u8, payload_type_str, 10);

        return MediaInfo{
            .media_type = media_type,
            .codec = try self.allocator.dupe(u8, ""),
            .clock_rate = 0,
            .control_url = try self.allocator.dupe(u8, ""),
            .protocol = if (std.mem.containsAtLeast(u8, proto_str, 1, "TCP")) .tcp else .udp,
            .port = port,
            .payload_type = payload_type,
        };
    }

    /// Parse attribute line like "a=rtpmap:96 H264/90000"
    fn parseAttributeLine(self: *Self, line: []const u8, media: *MediaInfo) !void {
        if (std.mem.startsWith(u8, line, "rtpmap:")) {
            const value = line["rtpmap:".len..];
            var iter = std.mem.tokenize(u8, value, " ");
            _ = iter.next(); // Skip payload type

            const encoding = iter.next() orelse return Error.InvalidFormat;
            var encoding_parts = std.mem.split(u8, encoding, "/");
            const codec = encoding_parts.first();
            const clock_rate_str = encoding_parts.next() orelse return Error.InvalidFormat;

            media.codec = try self.allocator.dupe(u8, codec);
            media.clock_rate = try std.fmt.parseInt(u32, clock_rate_str, 10);
        } else if (std.mem.startsWith(u8, line, "control:")) {
            const control_url = line["control:".len..];
            media.control_url = try self.allocator.dupe(u8, control_url);
        }
    }

    /// Clean up resources
    pub fn deinit(self: *Self) void {
        for (self.media_descriptions.items) |*media| {
            media.deinit(self.allocator);
        }
        self.media_descriptions.deinit();
    }
};

test "sdp parser - basic media description" {
    const sdp_str =
        \\v=0
        \\o=- 123456 11 IN IP4 127.0.0.1
        \\s=Test Stream
        \\c=IN IP4 127.0.0.1
        \\t=0 0
        \\m=video 0 RTP/AVP 96
        \\a=rtpmap:96 H264/90000
        \\a=control:track1
        \\m=audio 0 RTP/AVP 97
        \\a=rtpmap:97 AAC/48000
        \\a=control:track2
    ;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var parser = SdpParser.init(allocator, sdp_str);
    defer parser.deinit();

    try parser.parse();
    try std.testing.expectEqual(@as(usize, 2), parser.media_descriptions.items.len);

    // Check video track
    const video = parser.media_descriptions.items[0];
    try std.testing.expectEqual(MediaType.video, video.media_type);
    try std.testing.expectEqualStrings("H264", video.codec);
    try std.testing.expectEqual(@as(u32, 90000), video.clock_rate);
    try std.testing.expectEqualStrings("track1", video.control_url);
    try std.testing.expectEqual(@as(u8, 96), video.payload_type);

    // Check audio track
    const audio = parser.media_descriptions.items[1];
    try std.testing.expectEqual(MediaType.audio, audio.media_type);
    try std.testing.expectEqualStrings("AAC", audio.codec);
    try std.testing.expectEqual(@as(u32, 48000), audio.clock_rate);
    try std.testing.expectEqualStrings("track2", audio.control_url);
    try std.testing.expectEqual(@as(u8, 97), audio.payload_type);
}
