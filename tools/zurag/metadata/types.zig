const std = @import("std");
const tile = @import("../tile.zig");

pub const AnimationDirection = enum(u2) {
    forward = 0,
    reverse = 1,
    pingpong = 2,

    pub fn fromString(str: []const u8) AnimationDirection {
        if (std.mem.eql(u8, str, "reverse")) return .reverse;
        if (std.mem.eql(u8, str, "pingpong")) return .pingpong;
        return .forward;
    }
};

pub const Frame = struct {
    rect: tile.Rect,
    duration_ms: u16,
};

pub const Tag = struct {
    name: []const u8,
    from: u16,
    to: u16,
    direction: AnimationDirection = .forward,
};

/// Unified sprite metadata domain model (decoupled from specific export software)
pub const SpriteMetadata = struct {
    app: []const u8, // Creator application identifier (e.g. "Aseprite", "LibreSprite")
    frames: []Frame,
    tags: []Tag,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *SpriteMetadata) void {
        self.allocator.free(self.frames);
        for (self.tags) |tag| {
            self.allocator.free(tag.name);
        }
        self.allocator.free(self.tags);
    }
};

pub const MetadataFormat = enum {
    auto,
    aseprite,
};

pub const MetadataError = error{
    InvalidJson,
    MissingFrames,
    MissingMeta,
    InvalidFrameData,
    UnsupportedJsonFormat,
    OutOfMemory,
    Unimplemented,
};
