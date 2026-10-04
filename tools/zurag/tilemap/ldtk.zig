const std = @import("std");
const types = @import("types.zig");
const test_assets = @import("test_palettes");

pub const Limits = types.Limits;
pub const TilemapError = types.TilemapError;
pub const ParsedTileEntry = types.ParsedTileEntry;
pub const ParsedEntity = types.ParsedEntity;
pub const LayerType = types.LayerType;
pub const ParsedLayer = types.ParsedLayer;
pub const ParsedLevel = types.ParsedLevel;
pub const TilemapMetadata = types.TilemapMetadata;

/// Detects whether the parsed JSON root object belongs to LDtk via `__header__` or `jsonVersion` signature.
pub fn detectLdtk(root: std.json.ObjectMap) bool {
    if (root.get("__header__")) |header_val| {
        if (header_val == .object) {
            if (header_val.object.get("app")) |app_val| {
                if (app_val == .string and std.mem.indexOf(u8, app_val.string, "LDtk") != null) {
                    return true;
                }
            }
        }
    }
    if (root.get("jsonVersion")) |_| {
        return true;
    }
    return false;
}

/// Splits a 16x16 tile placement into 4 standard 8x8 tile entries
pub fn split16x16Tile(
    base_tile_id: u16,
    tileset_c_wid: u32,
    grid_x: u16,
    grid_y: u16,
    h_flip: bool,
    v_flip: bool,
) [4]ParsedTileEntry {
    _ = base_tile_id;
    _ = tileset_c_wid;
    _ = grid_x;
    _ = grid_y;
    _ = h_flip;
    _ = v_flip;
    // Stub implementation returning dummy entries
    return [4]ParsedTileEntry{
        .{ .tile_id = 0, .x = 0, .y = 0, .h_flip = false, .v_flip = false },
        .{ .tile_id = 0, .x = 0, .y = 0, .h_flip = false, .v_flip = false },
        .{ .tile_id = 0, .x = 0, .y = 0, .h_flip = false, .v_flip = false },
        .{ .tile_id = 0, .x = 0, .y = 0, .h_flip = false, .v_flip = false },
    };
}

/// Parses raw LDtk project JSON content and validates against GBA hardware constraints
pub fn parseLdtkJson(
    allocator: std.mem.Allocator,
    root: std.json.ObjectMap,
) types.TilemapError!TilemapMetadata {
    _ = allocator;
    _ = root;
    // Stub implementation (Red Phase)
    return error.Unimplemented;
}

// ============================================================================
// Unit Tests (Red Phase)
// ============================================================================

fn parseJsonHelper(allocator: std.mem.Allocator, json_bytes: []const u8) types.TilemapError!TilemapMetadata {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, json_bytes, .{}) catch {
        return types.TilemapError.InvalidJson;
    };
    defer parsed.deinit();
    if (parsed.value != .object) return types.TilemapError.InvalidJson;
    return parseLdtkJson(allocator, parsed.value.object);
}

test "LDT001: Parse 8x8 IntGrid + auto-layer embed tileset" {
    const raw_json = test_assets.ldtk_t01_intgrid;
    var project = try parseJsonHelper(std.testing.allocator, raw_json);
    defer project.deinit();

    try std.testing.expectEqual(@as(usize, 1), project.levels.len);
    const level = project.levels[0];
    try std.testing.expectEqual(@as(u32, 256), level.px_wid);
    try std.testing.expectEqual(@as(u32, 256), level.px_hei);

    // Verify layer extraction
    try std.testing.expectEqual(@as(usize, 1), level.layers.len);
    const layer = level.layers[0];
    try std.testing.expectEqual(LayerType.int_grid, layer.layer_type);
    try std.testing.expect(layer.tiles.len > 0);
    try std.testing.expect(layer.collision_masks != null);
    try std.testing.expectEqual(@as(usize, 32 * 32), layer.collision_masks.?.len);
}

test "LDT002: 16x16 tile quad-splitting logic" {
    // 16x16 tile ID 0 in a tileset with 4 tiles across (each 8x8 is 2x2 grid in 16x16 units)
    // Tileset has c_wid = 4 (8x8 tiles per row)
    const sub_tiles = split16x16Tile(0, 4, 1, 2, false, false);

    // Sub-tile 0: top-left (x=2, y=4, tile_id=0)
    try std.testing.expectEqual(@as(u16, 0), sub_tiles[0].tile_id);
    try std.testing.expectEqual(@as(u16, 2), sub_tiles[0].x);
    try std.testing.expectEqual(@as(u16, 4), sub_tiles[0].y);

    // Sub-tile 1: top-right (x=3, y=4, tile_id=1)
    try std.testing.expectEqual(@as(u16, 1), sub_tiles[1].tile_id);
    try std.testing.expectEqual(@as(u16, 3), sub_tiles[1].x);
    try std.testing.expectEqual(@as(u16, 4), sub_tiles[1].y);

    // Sub-tile 2: bottom-left (x=2, y=5, tile_id=4)
    try std.testing.expectEqual(@as(u16, 4), sub_tiles[2].tile_id);
    try std.testing.expectEqual(@as(u16, 2), sub_tiles[2].x);
    try std.testing.expectEqual(@as(u16, 5), sub_tiles[2].y);

    // Sub-tile 3: bottom-right (x=3, y=5, tile_id=5)
    try std.testing.expectEqual(@as(u16, 5), sub_tiles[3].tile_id);
    try std.testing.expectEqual(@as(u16, 3), sub_tiles[3].x);
    try std.testing.expectEqual(@as(u16, 5), sub_tiles[3].y);

    // Test with H-Flip: sub-tiles swap horizontally and individual h_flip is true
    const h_flipped = split16x16Tile(0, 4, 1, 2, true, false);
    try std.testing.expectEqual(@as(u16, 1), h_flipped[0].tile_id); // Top-right tile placed at top-left
    try std.testing.expect(h_flipped[0].h_flip);
    try std.testing.expectEqual(@as(u16, 0), h_flipped[1].tile_id); // Top-left tile placed at top-right
    try std.testing.expect(h_flipped[1].h_flip);
}

test "LDT003: Parse pure tile layer without IntGrid (null collision_masks)" {
    const raw_json = test_assets.ldtk_t02_tile_only;
    var project = try parseJsonHelper(std.testing.allocator, raw_json);
    defer project.deinit();

    const level = project.levels[0];
    try std.testing.expectEqual(@as(usize, 1), level.layers.len);
    const layer = level.layers[0];
    try std.testing.expectEqual(LayerType.tiles, layer.layer_type);
    try std.testing.expect(layer.tiles.len > 0);
    try std.testing.expectEqual(@as(?[]const u16, null), layer.collision_masks);
}

test "LDT004: Parse multi-layer 4 BG configuration" {
    const raw_json = test_assets.ldtk_t03_4bg;
    var project = try parseJsonHelper(std.testing.allocator, raw_json);
    defer project.deinit();

    const level = project.levels[0];
    // Exactly 4 layers conforming to GBA Mode 0 hardware limit
    try std.testing.expectEqual(@as(usize, 4), level.layers.len);
}

test "LDT005: Parse and extract level entities" {
    const raw_json = test_assets.ldtk_t04_entities;
    var project = try parseJsonHelper(std.testing.allocator, raw_json);
    defer project.deinit();

    const level = project.levels[0];
    var found_entities_layer = false;
    for (level.layers) |layer| {
        if (layer.layer_type == .entities) {
            found_entities_layer = true;
            try std.testing.expect(layer.entities.len >= 2);
            // Verify PlayerSpawn entity coordinates
            var found_player = false;
            for (layer.entities) |ent| {
                if (std.mem.eql(u8, ent.identifier, "PlayerSpawn")) {
                    found_player = true;
                    try std.testing.expectEqual(@as(i32, 32), ent.x);
                    try std.testing.expectEqual(@as(i32, 192), ent.y);
                }
            }
            try std.testing.expect(found_player);
        }
    }
    try std.testing.expect(found_entities_layer);
}

test "LDT006: Parse tile flip flags (f=0, 1, 2, 3)" {
    const raw_json = test_assets.ldtk_t05_flips;
    var project = try parseJsonHelper(std.testing.allocator, raw_json);
    defer project.deinit();

    const layer = project.levels[0].layers[0];
    var has_h_flip = false;
    var has_v_flip = false;
    var has_both_flip = false;

    for (layer.tiles) |t| {
        if (t.h_flip and !t.v_flip) has_h_flip = true;
        if (!t.h_flip and t.v_flip) has_v_flip = true;
        if (t.h_flip and t.v_flip) has_both_flip = true;
    }

    try std.testing.expect(has_h_flip);
    try std.testing.expect(has_v_flip);
    try std.testing.expect(has_both_flip);
}

test "LDT007: Reject invalid maps violating GBA hardware constraints" {
    // E01: 5 background layers (exceeds GBA 4-layer hardware limit)
    const json_e01 = test_assets.ldtk_e01_5bg;
    try std.testing.expectError(error.TooManyLayers, parseJsonHelper(std.testing.allocator, json_e01));

    // E02: Non-8-multiple map dimensions (250x250)
    const json_e02 = test_assets.ldtk_e02_invalid_dim;
    try std.testing.expectError(error.InvalidMapDimensions, parseJsonHelper(std.testing.allocator, json_e02));

    // E03-X: Map width exceeds 4096px limit (5120x256)
    const json_e03_x = test_assets.ldtk_e03_large_x;
    try std.testing.expectError(error.MapSizeExceedsLimit, parseJsonHelper(std.testing.allocator, json_e03_x));

    // E03-Y: Map height exceeds 4096px limit (256x5120)
    const json_e03_y = test_assets.ldtk_e03_large_y;
    try std.testing.expectError(error.MapSizeExceedsLimit, parseJsonHelper(std.testing.allocator, json_e03_y));

    // E04: IntGrid value exceeds 16-bit mask range (> 16)
    const json_e04 = test_assets.ldtk_e04_intgrid_range;
    try std.testing.expectError(error.IntGridValueOutOfRange, parseJsonHelper(std.testing.allocator, json_e04));
}

test "LDT008: Handle tile alpha blending warning and clamp to 1.0" {
    const raw_json = test_assets.ldtk_e05_alpha_warn;
    var project = try parseJsonHelper(std.testing.allocator, raw_json);
    defer project.deinit();

    const layer = project.levels[0].layers[0];
    try std.testing.expect(layer.has_alpha_warning);
    // Verify all tile alphas are clamped to 1.0
    for (layer.tiles) |t| {
        try std.testing.expectEqual(@as(f32, 1.0), t.alpha);
    }
}
