const std = @import("std");
const metadata = @import("../metadata.zig");
const tile = @import("../tile.zig");

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

/// Parses Aseprite-exported JSON metadata (Hash or Array format) into the unified SpriteMetadata model.
pub fn parseAsepriteJson(allocator: std.mem.Allocator, json_content: []const u8) metadata.MetadataError!metadata.SpriteMetadata {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, json_content, .{}) catch {
        return metadata.MetadataError.InvalidJson;
    };
    defer parsed.deinit();

    const root = switch (parsed.value) {
        .object => |obj| obj,
        else => return metadata.MetadataError.InvalidJson,
    };

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

    // Parse meta.frameTags
    var tags_list: std.ArrayList(metadata.Tag) = .empty;
    defer tags_list.deinit(allocator);

    if (root.get("meta")) |meta_val| {
        if (meta_val == .object) {
            if (meta_val.object.get("frameTags")) |tags_val| {
                if (tags_val == .array) {
                    for (tags_val.array.items) |tag_item| {
                        if (tag_item == .object) {
                            const tag = try parseSingleTag(allocator, tag_item.object);
                            try tags_list.append(allocator, tag);
                        }
                    }
                }
            }
        }
    }

    const owned_frames = try allocator.dupe(metadata.Frame, frames_list.items);
    errdefer allocator.free(owned_frames);

    const owned_tags = try allocator.dupe(metadata.Tag, tags_list.items);

    return metadata.SpriteMetadata{
        .frames = owned_frames,
        .tags = owned_tags,
        .allocator = allocator,
    };
}

// ====================================================================
// Unit Tests for Aseprite Adapter (TDD Red Phase)
// ====================================================================

test "ASE001: parseAsepriteJson: real tsetseg broom asset JSON" {
    const test_assets = @import("test_palettes");
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

test "ASE002: parseAsepriteJson: frames as array format support" {
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

test "ASE003: parseAsepriteJson: error handling on malformed JSON" {
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
