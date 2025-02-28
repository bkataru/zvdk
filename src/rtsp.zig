//! RTSP client implementation for streaming media

const std = @import("std");
const common = @import("common.zig");
const Error = common.Error;

pub const RtspClient = @import("rtsp/client.zig").RtspClient;
pub const SdpParser = @import("rtsp/sdp.zig").SdpParser;
pub const Track = @import("rtsp/track.zig").Track;
pub const MockRtspServer = @import("rtsp/mock_server.zig").MockRtspServer;
pub const MockServerConfig = @import("rtsp/mock_server.zig").MockServerConfig;

/// RTSP client states
pub const State = enum {
    disconnected,
    connected,
    described,
    setup,
    playing,
    paused,
};

/// RTSP Media track type
pub const MediaType = enum {
    video,
    audio,
};

/// RTSP Protocol type
pub const ProtoType = enum {
    tcp,
    udp,
};

/// Media track information from SDP
pub const MediaInfo = struct {
    media_type: MediaType,
    codec: []const u8,
    clock_rate: u32,
    control_url: []const u8,
    protocol: ProtoType = .udp,
    port: u16 = 0,
    payload_type: u8 = 0,

    pub fn deinit(self: *const MediaInfo, allocator: std.mem.Allocator) void {
        allocator.free(self.codec);
        allocator.free(self.control_url);
    }
};

/// Supported codecs
pub const CodecType = enum {
    h264,
    h265,
    aac,
    unknown,

    pub fn fromStr(codec: []const u8) CodecType {
        if (std.mem.eql(u8, codec, "H264")) return .h264;
        if (std.mem.eql(u8, codec, "H265")) return .h265;
        if (std.mem.eql(u8, codec, "AAC")) return .aac;
        return .unknown;
    }
};

test {
    std.testing.refAllDecls(@This());
}
