const std = @import("std");
const tile = @import("tile.zig");

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

/// Parses Aseprite-exported JSON metadata into the unified SpriteMetadata model.
pub fn parseAsepriteJson(allocator: std.mem.Allocator, json_content: []const u8) MetadataError!SpriteMetadata {
    _ = allocator;
    _ = json_content;
    // Stub for TDD (intentionally unimplemented)
    return error.Unimplemented;
}

/// Automatically detects metadata format (or uses requested format) and parses into SpriteMetadata.
pub fn parseMetadata(
    allocator: std.mem.Allocator,
    json_content: []const u8,
    format: MetadataFormat,
) MetadataError!SpriteMetadata {
    _ = allocator;
    _ = json_content;
    _ = format;
    // Stub for TDD (intentionally unimplemented)
    return error.Unimplemented;
}

// ====================================================================
// Unit Tests for JSON Metadata Parser (TDD Red Phase)
// ====================================================================

const test_assets = @import("test_palettes");

test "parseAsepriteJson: real tsetseg broom asset JSON" {
    var meta = try parseAsepriteJson(std.testing.allocator, test_assets.json_broom);
    defer meta.deinit();

    // 1. Frame count & durations
    try std.testing.expectEqual(@as(usize, 8), meta.frames.len);
    for (meta.frames, 0..) |frame, i| {
        try std.testing.expectEqual(@as(u32, @intCast(i * 32)), frame.rect.x);
        try std.testing.expectEqual(@as(u32, 0), frame.rect.y);
        try std.testing.expectEqual(@as(u32, 32), frame.rect.w);
        try std.testing.expectEqual(@as(u32, 32), frame.rect.h);
        try std.testing.expectEqual(@as(u16, 100), frame.duration_ms);
    }

    // 2. Animation tags
    try std.testing.expectEqual(@as(usize, 1), meta.tags.len);
    try std.testing.expectEqualStrings("flying", meta.tags[0].name);
    try std.testing.expectEqual(@as(u16, 0), meta.tags[0].from);
    try std.testing.expectEqual(@as(u16, 7), meta.tags[0].to);
    try std.testing.expectEqual(AnimationDirection.forward, meta.tags[0].direction);
}

test "parseMetadata: auto-detection of Aseprite format" {
    var meta = try parseMetadata(std.testing.allocator, test_assets.json_broom, .auto);
    defer meta.deinit();

    try std.testing.expectEqual(@as(usize, 8), meta.frames.len);
    try std.testing.expectEqualStrings("flying", meta.tags[0].name);
}

test "parseAsepriteJson: frames as array format support" {
    const array_json =
        \\{
        \\  "frames": [
        \\    {
        \\      "filename": "hero 0.aseprite",
        \\      "frame": { "x": 0, "y": 0, "w": 16, "h": 16 },
        \\      "duration": 150
        \\    },
        \\    {
        \\      "filename": "hero 1.aseprite",
        \\      "frame": { "x": 16, "y": 0, "w": 16, "h": 16 },
        \\      "duration": 200
        \\    }
        \\  ],
        \\  "meta": {
        \\    "frameTags": [
        \\      { "name": "walk", "from": 0, "to": 1, "direction": "pingpong" }
        \\    ]
        \\  }
        \\}
    ;

    var meta = try parseAsepriteJson(std.testing.allocator, array_json);
    defer meta.deinit();

    try std.testing.expectEqual(@as(usize, 2), meta.frames.len);
    try std.testing.expectEqual(@as(u32, 16), meta.frames[1].rect.x);
    try std.testing.expectEqual(@as(u16, 200), meta.frames[1].duration_ms);
    try std.testing.expectEqual(AnimationDirection.pingpong, meta.tags[0].direction);
}

test "parseAsepriteJson: error handling on malformed JSON" {
    // Missing frames
    const no_frames_json =
        \\{ "meta": { "frameTags": [] } }
    ;
    try std.testing.expectError(error.MissingFrames, parseAsepriteJson(std.testing.allocator, no_frames_json));

    // Malformed JSON syntax
    const corrupted_json =
        \\{ "frames": [ invalid json syntax
    ;
    try std.testing.expectError(error.InvalidJson, parseAsepriteJson(std.testing.allocator, corrupted_json));
}
