const std = @import("std");
const metadata = @import("../metadata.zig");
const tile = @import("../tile.zig");

/// Detects whether the parsed JSON root object belongs to Aseprite or LibreSprite via meta.app signature.
pub fn detectCreatorAppAndVersion(root: std.json.ObjectMap) bool {
    const meta_val = root.get("meta") orelse return false;
    if (meta_val != .object) return false;

    const meta_obj = meta_val.object;
    const app_val = meta_obj.get("app") orelse return false;
    if (app_val != .string) return false;

    const app_str = app_val.string;
    return (std.mem.indexOf(u8, app_str, "aseprite.org") != null or
        std.mem.indexOf(u8, app_str, "libresprite") != null);
}

fn getIntField(comptime T: type, obj: std.json.ObjectMap, key: []const u8) ?T {
    const val = obj.get(key) orelse return null;
    return switch (val) {
        .integer => |i| if (i >= 0 and i <= std.math.maxInt(T)) @intCast(i) else null,
        else => null,
    };
}

fn parseSingleFrame(obj: std.json.ObjectMap) metadata.MetadataError!metadata.Frame {
    const frame_val = obj.get("frame") orelse return metadata.MetadataError.InvalidFrameData;
    const frame_obj = switch (frame_val) {
        .object => |o| o,
        else => return metadata.MetadataError.InvalidFrameData,
    };

    const x = getIntField(u32, frame_obj, "x") orelse return metadata.MetadataError.InvalidFrameData;
    const y = getIntField(u32, frame_obj, "y") orelse return metadata.MetadataError.InvalidFrameData;
    const w = getIntField(u32, frame_obj, "w") orelse return metadata.MetadataError.InvalidFrameData;
    const h = getIntField(u32, frame_obj, "h") orelse return metadata.MetadataError.InvalidFrameData;
    const duration = getIntField(u16, obj, "duration") orelse 100;

    return metadata.Frame{
        .rect = tile.Rect{ .x = x, .y = y, .w = w, .h = h },
        .duration_ms = duration,
    };
}

fn parseSingleTag(allocator: std.mem.Allocator, obj: std.json.ObjectMap) metadata.MetadataError!metadata.Tag {
    const name_val = obj.get("name") orelse return metadata.MetadataError.InvalidFrameData;
    const name_str = switch (name_val) {
        .string => |s| s,
        else => return metadata.MetadataError.InvalidFrameData,
    };

    const from = getIntField(u16, obj, "from") orelse 0;
    const to = getIntField(u16, obj, "to") orelse from;

    var direction = metadata.AnimationDirection.forward;
    if (obj.get("direction")) |dir_val| {
        if (dir_val == .string) {
            direction = metadata.AnimationDirection.fromString(dir_val.string);
        }
    }

    const owned_name = allocator.dupe(u8, name_str) catch return metadata.MetadataError.OutOfMemory;

    return metadata.Tag{
        .name = owned_name,
        .from = from,
        .to = to,
        .direction = direction,
    };
}

fn getMetaMap(root: std.json.ObjectMap) ?std.json.ObjectMap {
    const meta_val = root.get("meta") orelse return null;
    return if (meta_val == .object) meta_val.object else null;
}

fn extractAppName(meta: ?std.json.ObjectMap) []const u8 {
    const m = meta orelse return "Aseprite";
    const app = m.get("app") orelse return "Aseprite";
    if (app != .string) return "Aseprite";
    if (std.mem.indexOf(u8, app.string, "libresprite") != null) {
        return "LibreSprite";
    }
    return "Aseprite";
}

fn parseFrameTags(allocator: std.mem.Allocator, meta: ?std.json.ObjectMap) metadata.MetadataError![]metadata.Tag {
    const m = meta orelse return &.{};
    const tags_val = m.get("frameTags") orelse return &.{};
    if (tags_val != .array) return &.{};

    var tags_list: std.ArrayList(metadata.Tag) = .empty;
    defer tags_list.deinit(allocator);

    for (tags_val.array.items) |tag_item| {
        if (tag_item != .object) continue;
        const tag = try parseSingleTag(allocator, tag_item.object);
        try tags_list.append(allocator, tag);
    }

    return tags_list.toOwnedSlice(allocator);
}

/// Parses pre-parsed Aseprite JSON metadata into the unified SpriteMetadata model without reparsing.
pub fn parseJsonMetadata(allocator: std.mem.Allocator, root: std.json.ObjectMap) metadata.MetadataError!metadata.SpriteMetadata {
    const frames_val = root.get("frames") orelse return metadata.MetadataError.MissingFrames;

    var frames_list: std.ArrayList(metadata.Frame) = .empty;
    defer frames_list.deinit(allocator);

    switch (frames_val) {
        .object => |obj| {
            var it = obj.iterator();
            while (it.next()) |entry| {
                const frame_obj = switch (entry.value_ptr.*) {
                    .object => |o| o,
                    else => return metadata.MetadataError.InvalidFrameData,
                };
                const frame = try parseSingleFrame(frame_obj);
                try frames_list.append(allocator, frame);
            }
        },
        .array => |arr| {
            for (arr.items) |item| {
                const frame_obj = switch (item) {
                    .object => |o| o,
                    else => return metadata.MetadataError.InvalidFrameData,
                };
                const frame = try parseSingleFrame(frame_obj);
                try frames_list.append(allocator, frame);
            }
        },
        else => return metadata.MetadataError.MissingFrames,
    }

    if (frames_list.items.len == 0) {
        return metadata.MetadataError.MissingFrames;
    }

    const meta_obj = getMetaMap(root);
    const app_name = extractAppName(meta_obj);
    const owned_tags = try parseFrameTags(allocator, meta_obj);

    const owned_frames = try allocator.dupe(metadata.Frame, frames_list.items);
    errdefer allocator.free(owned_frames);

    return metadata.SpriteMetadata{
        .app = app_name,
        .frames = owned_frames,
        .tags = owned_tags,
        .allocator = allocator,
    };
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

    // 1. App name
    try std.testing.expectEqualStrings("Aseprite", meta.app);

    // 2. Frame count & durations
    try std.testing.expectEqual(@as(usize, 8), meta.frames.len);
    for (meta.frames, 0..) |frame, i| {
        try std.testing.expectEqual(@as(u32, @intCast(i * 32)), frame.rect.x);
        try std.testing.expectEqual(@as(u32, 0), frame.rect.y);
        try std.testing.expectEqual(@as(u32, 32), frame.rect.w);
        try std.testing.expectEqual(@as(u32, 32), frame.rect.h);
        try std.testing.expectEqual(@as(u16, 100), frame.duration_ms);
    }

    // 3. Animation tags
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

    try std.testing.expectEqualStrings("Aseprite", meta.app);
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
