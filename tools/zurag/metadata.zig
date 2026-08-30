const std = @import("std");
pub const types = @import("metadata/types.zig");
pub const aseprite = @import("metadata/aseprite.zig");

// Re-export common domain types for consumers
pub const Rect = types.Rect;
pub const AnimationDirection = types.AnimationDirection;
pub const Frame = types.Frame;
pub const Tag = types.Tag;
pub const SpriteMetadata = types.SpriteMetadata;
pub const MetadataFormat = types.MetadataFormat;
pub const MetadataError = types.MetadataError;

/// Automatically detects metadata format (or uses requested format) and parses into SpriteMetadata.
pub fn parseMetadata(
    allocator: std.mem.Allocator,
    json_content: []const u8,
    format: MetadataFormat,
) MetadataError!SpriteMetadata {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, json_content, .{}) catch {
        return MetadataError.InvalidJson;
    };
    defer parsed.deinit();

    if (parsed.value != .object) {
        return MetadataError.InvalidJson;
    }

    const root = parsed.value.object;

    switch (format) {
        .aseprite => return aseprite.parseJsonMetadata(allocator, root),
        .auto => {
            if (aseprite.detectCreatorAppAndVersion(root)) {
                return aseprite.parseJsonMetadata(allocator, root);
            }
            return MetadataError.UnsupportedJsonFormat;
        },
    }
}

// ====================================================================
// Unit Tests for Metadata Dispatcher (TDD Red Phase)
// ====================================================================

test "MET001: parseMetadata: auto-detection of Aseprite format" {
    const test_assets = @import("test_palettes");
    var meta = try parseMetadata(std.testing.allocator, test_assets.json_broom, .auto);
    defer meta.deinit();

    try std.testing.expectEqualStrings("Aseprite", meta.app);
    try std.testing.expectEqual(@as(usize, 8), meta.frames.len);
    try std.testing.expectEqualStrings("flying", meta.tags[0].name);
}

test "MET002: parseMetadata: explicit format dispatch for Aseprite" {
    const test_assets = @import("test_palettes");
    var meta = try parseMetadata(std.testing.allocator, test_assets.json_broom, .aseprite);
    defer meta.deinit();

    try std.testing.expectEqualStrings("Aseprite", meta.app);
    try std.testing.expectEqual(@as(usize, 8), meta.frames.len);
    try std.testing.expectEqualStrings("flying", meta.tags[0].name);
}

test "MET003: parseMetadata: reject unsupported JSON format in auto mode" {
    // Has frames and meta, but app is not Aseprite
    const foreign_json =
        \\{
        \\  "frames": [],
        \\  "meta": { "app": "http://www.custom-foreign-tool.com/", "version": "1.0.0" }
        \\}
    ;
    try std.testing.expectError(error.UnsupportedJsonFormat, parseMetadata(std.testing.allocator, foreign_json, .auto));
}

test "MET004: parseMetadata: memory deinit and leak check" {
    const test_assets = @import("test_palettes");
    var meta = try parseMetadata(std.testing.allocator, test_assets.json_broom, .auto);
    // Deinit frees all frames, tags, and tag name strings
    meta.deinit();
}

test "MET005: parseMetadata: auto-detection supports LibreSprite app signature" {
    const libresprite_json =
        \\{
        \\  "frames": {
        \\    "frame0": { "frame": { "x": 0, "y": 0, "w": 16, "h": 16 }, "duration": 100 }
        \\  },
        \\  "meta": {
        \\    "app": "https://libresprite.github.io/",
        \\    "version": "1.0-dev",
        \\    "frameTags": []
        \\  }
        \\}
    ;
    var meta = try parseMetadata(std.testing.allocator, libresprite_json, .auto);
    defer meta.deinit();
    try std.testing.expectEqualStrings("LibreSprite", meta.app);
    try std.testing.expectEqual(@as(usize, 1), meta.frames.len);
}

test {
    _ = aseprite;
}
