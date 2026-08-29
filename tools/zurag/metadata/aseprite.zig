const std = @import("std");
const metadata = @import("../metadata.zig");

/// Parses Aseprite-exported JSON metadata (Hash or Array format) into the unified SpriteMetadata model.
pub fn parseAsepriteJson(allocator: std.mem.Allocator, json_content: []const u8) metadata.MetadataError!metadata.SpriteMetadata {
    _ = allocator;
    _ = json_content;
    // Stub for TDD (intentionally unimplemented)
    return error.Unimplemented;
}

// ====================================================================
// Unit Tests for Aseprite Adapter (TDD Red Phase)
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
    try std.testing.expectEqual(metadata.AnimationDirection.forward, meta.tags[0].direction);
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
    try std.testing.expectEqual(metadata.AnimationDirection.pingpong, meta.tags[0].direction);
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
