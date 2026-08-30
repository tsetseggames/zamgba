const std = @import("std");
const metadata = @import("../metadata.zig");
const tile = @import("../tile.zig");

/// Detects whether the parsed JSON root object belongs to Aseprite or LibreSprite via meta.app signature.
pub fn detectCreatorAppAndVersion(root: std.json.ObjectMap) bool {
    _ = root;
    // Stub for TDD (intentionally unimplemented)
    return false;
}

/// Parses pre-parsed Aseprite JSON metadata into the unified SpriteMetadata model without reparsing.
pub fn parseJsonMetadata(allocator: std.mem.Allocator, root: std.json.ObjectMap) metadata.MetadataError!metadata.SpriteMetadata {
    _ = allocator;
    _ = root;
    // Stub for TDD (intentionally unimplemented)
    return error.Unimplemented;
}

// ====================================================================
// Unit Tests for Aseprite Adapter (TDD Red Phase)
// ====================================================================

test "ASE001: parseJsonMetadata: real tsetseg broom asset JSON" {
    const test_assets = @import("test_palettes");
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, test_assets.json_broom, .{});
    defer parsed.deinit();

    try std.testing.expect(detectCreatorAppAndVersion(parsed.value.object));

    var meta = try parseJsonMetadata(std.testing.allocator, parsed.value.object);
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

test "ASE002: parseJsonMetadata: frames as array format support" {
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
        \\    "app": "http://www.aseprite.org/",
        \\    "version": "1.3.0",
        \\    "frameTags": [
        \\      { "name": "walk", "from": 0, "to": 1, "direction": "pingpong" }
        \\    ]
        \\  }
        \\}
    ;

    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, array_json, .{});
    defer parsed.deinit();

    var meta = try parseJsonMetadata(std.testing.allocator, parsed.value.object);
    defer meta.deinit();

    try std.testing.expectEqual(@as(usize, 2), meta.frames.len);
    try std.testing.expectEqual(@as(u32, 16), meta.frames[1].rect.x);
    try std.testing.expectEqual(@as(u16, 200), meta.frames[1].duration_ms);
    try std.testing.expectEqual(metadata.AnimationDirection.pingpong, meta.tags[0].direction);
}

test "ASE003: parseJsonMetadata: error handling on missing frames or invalid data" {
    // Missing frames
    const no_frames_json =
        \\{ "meta": { "app": "http://www.aseprite.org/", "frameTags": [] } }
    ;
    const parsed_no_frames = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, no_frames_json, .{});
    defer parsed_no_frames.deinit();
    try std.testing.expectError(error.MissingFrames, parseJsonMetadata(std.testing.allocator, parsed_no_frames.value.object));

    // Empty frames array
    const empty_frames_json =
        \\{ "frames": [], "meta": { "app": "http://www.aseprite.org/" } }
    ;
    const parsed_empty = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, empty_frames_json, .{});
    defer parsed_empty.deinit();
    try std.testing.expectError(error.MissingFrames, parseJsonMetadata(std.testing.allocator, parsed_empty.value.object));
}

test "ASE004: detectCreatorAppAndVersion: Aseprite and LibreSprite app signatures" {
    // Valid Aseprite app
    const ase_json =
        \\{ "meta": { "app": "http://www.aseprite.org/", "version": "1.3.0" } }
    ;
    const parsed_ase = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, ase_json, .{});
    defer parsed_ase.deinit();
    try std.testing.expect(detectCreatorAppAndVersion(parsed_ase.value.object));

    // Valid LibreSprite app
    const libre_json =
        \\{ "meta": { "app": "https://libresprite.github.io/", "version": "1.0-dev" } }
    ;
    const parsed_libre = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, libre_json, .{});
    defer parsed_libre.deinit();
    try std.testing.expect(detectCreatorAppAndVersion(parsed_libre.value.object));

    // Foreign app
    const foreign_json =
        \\{ "meta": { "app": "https://godotengine.org/", "version": "4.2" } }
    ;
    const parsed_foreign = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, foreign_json, .{});
    defer parsed_foreign.deinit();
    try std.testing.expect(!detectCreatorAppAndVersion(parsed_foreign.value.object));
}
