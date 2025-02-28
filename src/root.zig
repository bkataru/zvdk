//! Core library interface for RTSP to HLS conversion

const std = @import("std");

// Core modules
pub const rtsp = @import("rtsp.zig");
pub const media = @import("media.zig");
pub const ts = @import("ts.zig");
pub const hls = @import("hls.zig");
pub const common = @import("common.zig");

// Re-exported core types
pub const Config = @import("common.zig").Config;
pub const Error = @import("common.zig").Error;
pub const version = std.SemanticVersion{ .major = 0, .minor = 1, .patch = 0 };

test {
    // Import all tests
    std.testing.refAllDecls(@This());
}
