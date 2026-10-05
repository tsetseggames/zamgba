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

fn getIntField(comptime T: type, obj: std.json.ObjectMap, key: []const u8) ?T {
    const val = obj.get(key) orelse return null;
    return switch (val) {
        .integer => |i| if (i >= std.math.minInt(T) and i <= std.math.maxInt(T)) @intCast(i) else null,
        else => null,
    };
}

fn getStringField(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const val = obj.get(key) orelse return null;
    return switch (val) {
        .string => |s| s,
        else => null,
    };
}

fn getFloatField(comptime T: type, obj: std.json.ObjectMap, key: []const u8) ?T {
    const val = obj.get(key) orelse return null;
    return switch (val) {
        .float => |f| @floatCast(f),
        .integer => |i| @floatFromInt(i),
        else => null,
    };
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
    const c_wid: u16 = @intCast(tileset_c_wid);
    const tl_id = base_tile_id;
    const tr_id = base_tile_id + 1;
    const bl_id = base_tile_id + c_wid;
    const br_id = base_tile_id + c_wid + 1;

    const x0 = grid_x * 2;
    const x1 = grid_x * 2 + 1;
    const y0 = grid_y * 2;
    const y1 = grid_y * 2 + 1;

    const id0 = if (h_flip) (if (v_flip) br_id else tr_id) else (if (v_flip) bl_id else tl_id);
    const id1 = if (h_flip) (if (v_flip) bl_id else tl_id) else (if (v_flip) br_id else tr_id);
    const id2 = if (h_flip) (if (v_flip) tr_id else br_id) else (if (v_flip) tl_id else bl_id);
    const id3 = if (h_flip) (if (v_flip) tl_id else bl_id) else (if (v_flip) tr_id else br_id);

    return [4]ParsedTileEntry{
        .{ .tile_id = id0, .x = x0, .y = y0, .h_flip = h_flip, .v_flip = v_flip },
        .{ .tile_id = id1, .x = x1, .y = y0, .h_flip = h_flip, .v_flip = v_flip },
        .{ .tile_id = id2, .x = x0, .y = y1, .h_flip = h_flip, .v_flip = v_flip },
        .{ .tile_id = id3, .x = x1, .y = y1, .h_flip = h_flip, .v_flip = v_flip },
    };
}

const TilesetDef = struct {
    uid: i64,
    px_wid: u32,
    c_wid_8: u32,
};

fn parseTilesetDefs(allocator: std.mem.Allocator, root: std.json.ObjectMap) !std.AutoHashMap(i64, TilesetDef) {
    var map = std.AutoHashMap(i64, TilesetDef).init(allocator);
    errdefer map.deinit();

    const defs_val = root.get("defs") orelse return map;
    if (defs_val != .object) return map;
    const tilesets_val = defs_val.object.get("tilesets") orelse return map;
    if (tilesets_val != .array) return map;

    for (tilesets_val.array.items) |ts_item| {
        if (ts_item != .object) continue;
        const ts_obj = ts_item.object;
        const uid = getIntField(i64, ts_obj, "uid") orelse continue;
        const px_wid = getIntField(u32, ts_obj, "pxWid") orelse 256;
        const c_wid_8 = px_wid / Limits.TILE_SIZE_PX;
        try map.put(uid, .{ .uid = uid, .px_wid = px_wid, .c_wid_8 = c_wid_8 });
    }

    return map;
}

/// Parses raw LDtk project JSON content and validates against GBA hardware constraints
pub fn parseLdtkJson(
    allocator: std.mem.Allocator,
    root: std.json.ObjectMap,
) types.TilemapError!TilemapMetadata {
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const aa = arena.allocator();

    var tileset_defs = parseTilesetDefs(aa, root) catch return types.TilemapError.OutOfMemory;
    defer tileset_defs.deinit();

    // Validate IntGrid value definitions in defs.layers
    if (root.get("defs")) |defs_val| {
        if (defs_val == .object) {
            if (defs_val.object.get("layers")) |layers_def_val| {
                if (layers_def_val == .array) {
                    for (layers_def_val.array.items) |ld_item| {
                        if (ld_item != .object) continue;
                        if (ld_item.object.get("intGridValues")) |igv_val| {
                            if (igv_val == .array) {
                                for (igv_val.array.items) |v_item| {
                                    if (v_item != .object) continue;
                                    const v = getIntField(i64, v_item.object, "value") orelse continue;
                                    if (v < 1 or v > Limits.MAX_INTGRID_VALUE) {
                                        return types.TilemapError.IntGridValueOutOfRange;
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    const levels_val = root.get("levels") orelse return types.TilemapError.MissingLevelData;
    if (levels_val != .array or levels_val.array.items.len == 0) {
        return types.TilemapError.MissingLevelData;
    }

    var parsed_levels: std.ArrayList(ParsedLevel) = .empty;
    defer parsed_levels.deinit(aa);

    for (levels_val.array.items) |lvl_item| {
        if (lvl_item != .object) return types.TilemapError.InvalidJsonSchema;
        const lvl_obj = lvl_item.object;

        const identifier = getStringField(lvl_obj, "identifier") orelse "Level";
        const world_x = getIntField(i32, lvl_obj, "worldX") orelse 0;
        const world_y = getIntField(i32, lvl_obj, "worldY") orelse 0;
        const px_wid = getIntField(u32, lvl_obj, "pxWid") orelse return types.TilemapError.InvalidMapDimensions;
        const px_hei = getIntField(u32, lvl_obj, "pxHei") orelse return types.TilemapError.InvalidMapDimensions;

        // Validation on map dimensions
        if (px_wid == 0 or px_hei == 0 or
            px_wid % Limits.TILE_SIZE_PX != 0 or px_hei % Limits.TILE_SIZE_PX != 0)
        {
            return types.TilemapError.InvalidMapDimensions;
        }

        if (px_wid > Limits.MAX_MAP_DIMENSION_PX or px_hei > Limits.MAX_MAP_DIMENSION_PX) {
            return types.TilemapError.MapSizeExceedsLimit;
        }

        var parsed_layers: std.ArrayList(ParsedLayer) = .empty;
        defer parsed_layers.deinit(aa);
        var bg_layer_count: usize = 0;

        if (lvl_obj.get("layerInstances")) |layers_val| {
            if (layers_val == .array) {
                for (layers_val.array.items) |layer_item| {
                    if (layer_item != .object) continue;
                    const layer_obj = layer_item.object;

                    const type_str = getStringField(layer_obj, "__type") orelse continue;
                    const layer_type: LayerType = if (std.mem.eql(u8, type_str, "IntGrid"))
                        .int_grid
                    else if (std.mem.eql(u8, type_str, "AutoLayer"))
                        .auto_layer
                    else if (std.mem.eql(u8, type_str, "Tiles"))
                        .tiles
                    else if (std.mem.eql(u8, type_str, "Entities"))
                        .entities
                    else
                        return types.TilemapError.UnsupportedLayerType;

                    const layer_id = getStringField(layer_obj, "__identifier") orelse "Layer";
                    const grid_size = getIntField(u32, layer_obj, "__gridSize") orelse Limits.TILE_SIZE_PX;
                    const c_wid = getIntField(u32, layer_obj, "__cWid") orelse (px_wid / grid_size);
                    const c_hei = getIntField(u32, layer_obj, "__cHei") orelse (px_hei / grid_size);
                    const tileset_rel_path = if (getStringField(layer_obj, "__tilesetRelPath")) |p|
                        try aa.dupe(u8, p)
                    else
                        null;

                    // Parse IntGrid collision masks
                    var collision_masks: ?[]const u16 = null;
                    if (layer_type == .int_grid) {
                        if (layer_obj.get("intGridCsv")) |csv_val| {
                            if (csv_val == .array) {
                                const masks = try aa.alloc(u16, csv_val.array.items.len);
                                for (csv_val.array.items, 0..) |cell, idx| {
                                    const val = switch (cell) {
                                        .integer => |i| i,
                                        else => 0,
                                    };
                                    if (val < 0 or val > Limits.MAX_INTGRID_VALUE) {
                                        return types.TilemapError.IntGridValueOutOfRange;
                                    }
                                    masks[idx] = if (val == 0)
                                        0
                                    else
                                        @as(u16, 1) << @intCast(val - 1);
                                }
                                collision_masks = masks;
                            }
                        }
                    }

                    // Parse tiles (autoLayerTiles & gridTiles)
                    var tiles_list: std.ArrayList(ParsedTileEntry) = .empty;
                    defer tiles_list.deinit(aa);
                    var has_alpha_warning = false;

                    const tileset_def_uid = getIntField(i64, layer_obj, "__tilesetDefUid") orelse -1;
                    const tileset_c_wid_8 = if (tileset_defs.get(tileset_def_uid)) |ts|
                        ts.c_wid_8
                    else
                        32;

                    const tile_arrays = [_]?std.json.Value{
                        layer_obj.get("autoLayerTiles"),
                        layer_obj.get("gridTiles"),
                    };

                    for (tile_arrays) |opt_arr| {
                        const arr_val = opt_arr orelse continue;
                        if (arr_val != .array) continue;

                        for (arr_val.array.items) |t_item| {
                            if (t_item != .object) continue;
                            const t_obj = t_item.object;

                            const px_val = t_obj.get("px") orelse continue;
                            if (px_val != .array or px_val.array.items.len < 2) continue;
                            const px_x = switch (px_val.array.items[0]) {
                                .integer => |i| @as(i32, @intCast(i)),
                                else => 0,
                            };
                            const px_y = switch (px_val.array.items[1]) {
                                .integer => |i| @as(i32, @intCast(i)),
                                else => 0,
                            };

                            const f_bits = getIntField(u8, t_obj, "f") orelse 0;
                            const h_flip = (f_bits & 1) != 0;
                            const v_flip = (f_bits & 2) != 0;
                            const tile_id = getIntField(u16, t_obj, "t") orelse 0;
                            const alpha = getFloatField(f32, t_obj, "a") orelse 1.0;

                            if (alpha != 1.0) {
                                has_alpha_warning = true;
                            }

                            if (grid_size == 16) {
                                const gx: u16 = @intCast(@divTrunc(px_x, 16));
                                const gy: u16 = @intCast(@divTrunc(px_y, 16));

                                // If src coordinates are given, calculate 8x8 base tile ID accurately
                                var base_8x8_id = tile_id;
                                if (t_obj.get("src")) |src_val| {
                                    if (src_val == .array and src_val.array.items.len >= 2) {
                                        const src_x = switch (src_val.array.items[0]) {
                                            .integer => |i| @as(u32, @intCast(i)),
                                            else => 0,
                                        };
                                        const src_y = switch (src_val.array.items[1]) {
                                            .integer => |i| @as(u32, @intCast(i)),
                                            else => 0,
                                        };
                                        base_8x8_id = @intCast((src_x / 8) + (src_y / 8) * tileset_c_wid_8);
                                    }
                                }

                                const sub_tiles = split16x16Tile(base_8x8_id, tileset_c_wid_8, gx, gy, h_flip, v_flip);
                                for (sub_tiles) |st| {
                                    try tiles_list.append(aa, st);
                                }
                            } else {
                                const gx: u16 = @intCast(@divTrunc(px_x, 8));
                                const gy: u16 = @intCast(@divTrunc(px_y, 8));
                                try tiles_list.append(aa, .{
                                    .tile_id = tile_id,
                                    .x = gx,
                                    .y = gy,
                                    .h_flip = h_flip,
                                    .v_flip = v_flip,
                                    .alpha = 1.0,
                                });
                            }
                        }
                    }

                    // Check if this layer counts towards visual GBA hardware background layers
                    const is_visual_bg = (layer_type == .tiles or layer_type == .auto_layer or
                        (layer_type == .int_grid and tiles_list.items.len > 0));

                    if (is_visual_bg) {
                        bg_layer_count += 1;
                        if (bg_layer_count > Limits.MAX_BG_LAYERS) {
                            return types.TilemapError.TooManyLayers;
                        }
                    }

                    // Parse entities
                    var entities_list: std.ArrayList(ParsedEntity) = .empty;
                    defer entities_list.deinit(aa);
                    if (layer_type == .entities) {
                        if (layer_obj.get("entityInstances")) |ents_val| {
                            if (ents_val == .array) {
                                for (ents_val.array.items) |ent_item| {
                                    if (ent_item != .object) continue;
                                    const ent_obj = ent_item.object;

                                    const ent_id = getStringField(ent_obj, "__identifier") orelse "Entity";
                                    const px_val = ent_obj.get("px") orelse continue;
                                    if (px_val != .array or px_val.array.items.len < 2) continue;
                                    const ent_x = switch (px_val.array.items[0]) {
                                        .integer => |i| @as(i32, @intCast(i)),
                                        else => 0,
                                    };
                                    const ent_y = switch (px_val.array.items[1]) {
                                        .integer => |i| @as(i32, @intCast(i)),
                                        else => 0,
                                    };
                                    const ent_w = getIntField(u32, ent_obj, "width") orelse 16;
                                    const ent_h = getIntField(u32, ent_obj, "height") orelse 16;

                                    try entities_list.append(aa, .{
                                        .identifier = try aa.dupe(u8, ent_id),
                                        .x = ent_x,
                                        .y = ent_y,
                                        .width = ent_w,
                                        .height = ent_h,
                                    });
                                }
                            }
                        }
                    }

                    // Skip empty Entities layers
                    if (layer_type == .entities and entities_list.items.len == 0) {
                        continue;
                    }

                    // Skip empty IntGrid helper layers when visual auto-layers are already present
                    if (layer_type == .int_grid and tiles_list.items.len == 0 and parsed_layers.items.len > 0) {
                        continue;
                    }

                    try parsed_layers.append(aa, .{
                        .identifier = try aa.dupe(u8, layer_id),
                        .layer_type = layer_type,
                        .grid_size = grid_size,
                        .c_wid = c_wid,
                        .c_hei = c_hei,
                        .tileset_rel_path = tileset_rel_path,
                        .tiles = try tiles_list.toOwnedSlice(aa),
                        .collision_masks = collision_masks,
                        .entities = try entities_list.toOwnedSlice(aa),
                        .has_alpha_warning = has_alpha_warning,
                    });
                }
            }
        }

        try parsed_levels.append(aa, .{
            .identifier = try aa.dupe(u8, identifier),
            .world_x = world_x,
            .world_y = world_y,
            .px_wid = px_wid,
            .px_hei = px_hei,
            .layers = try parsed_layers.toOwnedSlice(aa),
        });
    }

    return TilemapMetadata{
        .arena = arena,
        .levels = try parsed_levels.toOwnedSlice(aa),
    };
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
            try std.testing.expect(layer.entities.len >= 1);
            // Verify Player entity coordinates
            var found_player = false;
            for (layer.entities) |ent| {
                if (std.mem.eql(u8, ent.identifier, "Player")) {
                    found_player = true;
                    try std.testing.expectEqual(@as(i32, 48), ent.x);
                    try std.testing.expectEqual(@as(i32, 200), ent.y);
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
