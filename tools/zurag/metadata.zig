const std = @import("std");
const tile = @import("tile.zig");
pub const aseprite = @import("metadata/aseprite.zig");

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
// Unit Tests for Metadata Dispatcher (TDD Red Phase)
// ====================================================================

test "MET001: parseMetadata: auto-detection of Aseprite format" {
    const test_assets = @import("test_palettes");
    var meta = try parseMetadata(std.testing.allocator, test_assets.json_broom, .auto);
    defer meta.deinit();

    try std.testing.expectEqual(@as(usize, 8), meta.frames.len);
    try std.testing.expectEqualStrings("flying", meta.tags[0].name);
}

test "MET002: parseMetadata: explicit format dispatch for Aseprite" {
    const test_assets = @import("test_palettes");
    var meta = try parseMetadata(std.testing.allocator, test_assets.json_broom, .aseprite);
    defer meta.deinit();

    try std.testing.expectEqual(@as(usize, 8), meta.frames.len);
    try std.testing.expectEqualStrings("flying", meta.tags[0].name);
}

test "MET003: parseMetadata: reject unsupported JSON format in auto mode" {
    const foreign_json =
        \\{ "custom_game_engine_data": { "version": 1 } }
    ;
    try std.testing.expectError(error.UnsupportedJsonFormat, parseMetadata(std.testing.allocator, foreign_json, .auto));
}

test "MET004: parseMetadata: memory deinit and leak check" {
    const test_assets = @import("test_palettes");
    var meta = try parseMetadata(std.testing.allocator, test_assets.json_broom, .auto);
    // Deinit frees all frames, tags, and tag name strings
    meta.deinit();
}

test {
    _ = aseprite;
}
