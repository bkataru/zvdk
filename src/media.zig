//! Media codec parsing and frame handling

const std = @import("std");
const rtsp = @import("rtsp.zig");

pub const h264 = @import("media/h264.zig");
pub const h265 = @import("media/h265.zig");
pub const aac = @import("media/aac.zig");

/// Media frame types
pub const FrameType = enum {
    video,
    audio,
};

/// Media frame flags
pub const FrameFlags = struct {
    key_frame: bool = false,
    end_of_sequence: bool = false,
    corrupted: bool = false,
    config: bool = false,
};

/// Common media frame structure
pub const Frame = struct {
    frame_type: FrameType,
    codec: rtsp.CodecType,
    flags: FrameFlags = .{},
    pts: i64,
    dts: ?i64 = null,
    data: []const u8,
    allocator: std.mem.Allocator,

    /// Create a new media frame
    pub fn init(
        allocator: std.mem.Allocator,
        frame_type: FrameType,
        codec: rtsp.CodecType,
        pts: i64,
        data: []const u8,
    ) !Frame {
        const frame_data = try allocator.dupe(u8, data);
        errdefer allocator.free(frame_data);

        return Frame{
            .frame_type = frame_type,
            .codec = codec,
            .pts = pts,
            .data = frame_data,
            .allocator = allocator,
        };
    }

    /// Clean up frame resources
    pub fn deinit(self: *Frame) void {
        self.allocator.free(self.data);
    }
};

/// Parser interface
pub const Parser = struct {
    vtable: *const VTable,

    pub const VTable = struct {
        parse: *const fn (*Parser, []const u8) anyerror!?Frame,
        deinit: *const fn (*Parser) void,
    };

    pub fn parse(self: *Parser, data: []const u8) !?Frame {
        return self.vtable.parse(self, data);
    }

    pub fn deinit(self: *Parser) void {
        self.vtable.deinit(self);
    }
};

/// Frame queue for buffering frames
pub const FrameQueue = struct {
    frames: std.ArrayList(Frame),

    pub fn init(allocator: std.mem.Allocator) FrameQueue {
        return .{ .frames = std.ArrayList(Frame).init(allocator) };
    }

    pub fn append(self: *FrameQueue, frame: Frame) !void {
        try self.frames.append(frame);
    }

    pub fn popFirst(self: *FrameQueue) ?Frame {
        return if (self.frames.items.len > 0)
            self.frames.orderedRemove(0)
        else
            null;
    }

    pub fn deinit(self: *FrameQueue) void {
        for (self.frames.items) |*frame| {
            frame.deinit();
        }
        self.frames.deinit();
    }
};

test {
    std.testing.refAllDecls(@This());
}
