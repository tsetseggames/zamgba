const std = @import("std");
const engine = @import("zamgba-engine");
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
    if (root.contains("jsonVersion")) return true;

    const header_val = root.get("__header__") orelse return false;
    if (header_val != .object) return false;

    const app_val = header_val.object.get("app") orelse return false;
    if (app_val != .string) return false;

    return std.mem.indexOf(u8, app_val.string, "LDtk") != null;
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

fn validateIntGridDefs(root: std.json.ObjectMap) types.TilemapError!void {
    const defs_val = root.get("defs") orelse return;
    if (defs_val != .object) return;
    const layers_def = defs_val.object.get("layers") orelse return;
    if (layers_def != .array) return;

    for (layers_def.array.items) |ld_item| {
        if (ld_item != .object) continue;
        const igv = ld_item.object.get("intGridValues") orelse continue;
        if (igv != .array) continue;

        for (igv.array.items) |v_item| {
            if (v_item != .object) continue;
            const v = getIntField(i64, v_item.object, "value") orelse continue;
            if (v < 1 or v > Limits.MAX_INTGRID_VALUE) {
                return types.TilemapError.IntGridValueOutOfRange;
            }
        }
    }
}

fn parseIntGridCollisions(aa: std.mem.Allocator, layer_obj: std.json.ObjectMap) types.TilemapError!?[]const u16 {
    const csv_val = layer_obj.get("intGridCsv") orelse return null;
    if (csv_val != .array) return null;

    const masks = aa.alloc(u16, csv_val.array.items.len) catch return types.TilemapError.OutOfMemory;
    for (csv_val.array.items, 0..) |cell, idx| {
        const val = switch (cell) {
            .integer => |i| i,
            else => 0,
        };
        if (val < 0 or val > Limits.MAX_INTGRID_VALUE) {
            return types.TilemapError.IntGridValueOutOfRange;
        }
        masks[idx] = if (val == 0)
            engine.physics.Collision.NONE
        else
            engine.physics.Collision.layer(@intCast(val - 1));
    }
    return masks;
}

const RawTileInfo = struct {
    px_x: i32,
    px_y: i32,
    tile_id: u16,
    h_flip: bool,
    v_flip: bool,
    alpha: f32,
    src_x: ?u32,
    src_y: ?u32,
};

fn parseRawTileObject(t_obj: std.json.ObjectMap) ?RawTileInfo {
    const px_val = t_obj.get("px") orelse return null;
    if (px_val != .array or px_val.array.items.len < 2) return null;
    const px_x = switch (px_val.array.items[0]) {
        .integer => |i| @as(i32, @intCast(i)),
        else => return null,
    };
    const px_y = switch (px_val.array.items[1]) {
        .integer => |i| @as(i32, @intCast(i)),
        else => return null,
    };

    const f_bits = getIntField(u8, t_obj, "f") orelse 0;
    const h_flip = (f_bits & 1) != 0;
    const v_flip = (f_bits & 2) != 0;
    const tile_id = getIntField(u16, t_obj, "t") orelse 0;
    const alpha = getFloatField(f32, t_obj, "a") orelse 1.0;

    var src_x: ?u32 = null;
    var src_y: ?u32 = null;
    if (t_obj.get("src")) |src_val| {
        if (src_val == .array and src_val.array.items.len >= 2) {
            src_x = switch (src_val.array.items[0]) {
                .integer => |i| @as(u32, @intCast(i)),
                else => null,
            };
            src_y = switch (src_val.array.items[1]) {
                .integer => |i| @as(u32, @intCast(i)),
                else => null,
            };
        }
    }

    return .{
        .px_x = px_x,
        .px_y = px_y,
        .tile_id = tile_id,
        .h_flip = h_flip,
        .v_flip = v_flip,
        .alpha = alpha,
        .src_x = src_x,
        .src_y = src_y,
    };
}

fn append16x16SubTiles(
    aa: std.mem.Allocator,
    tiles_list: *std.ArrayList(ParsedTileEntry),
    raw_tile: RawTileInfo,
    tileset_c_wid_8: u32,
) types.TilemapError!void {
    const gx: u16 = @intCast(@divTrunc(raw_tile.px_x, 16));
    const gy: u16 = @intCast(@divTrunc(raw_tile.px_y, 16));

    var base_8x8_id = raw_tile.tile_id;
    if (raw_tile.src_x != null and raw_tile.src_y != null) {
        base_8x8_id = @intCast((raw_tile.src_x.? / 8) + (raw_tile.src_y.? / 8) * tileset_c_wid_8);
    }

    const sub_tiles = split16x16Tile(base_8x8_id, tileset_c_wid_8, gx, gy, raw_tile.h_flip, raw_tile.v_flip);
    for (sub_tiles) |st| {
        tiles_list.append(aa, st) catch return types.TilemapError.OutOfMemory;
    }
}

fn append8x8Tile(
    aa: std.mem.Allocator,
    tiles_list: *std.ArrayList(ParsedTileEntry),
    raw_tile: RawTileInfo,
) types.TilemapError!void {
    const gx: u16 = @intCast(@divTrunc(raw_tile.px_x, 8));
    const gy: u16 = @intCast(@divTrunc(raw_tile.px_y, 8));
    tiles_list.append(aa, .{
        .tile_id = raw_tile.tile_id,
        .x = gx,
        .y = gy,
        .h_flip = raw_tile.h_flip,
        .v_flip = raw_tile.v_flip,
        .alpha = 1.0,
    }) catch return types.TilemapError.OutOfMemory;
}

fn appendTileEntries(
    aa: std.mem.Allocator,
    tiles_list: *std.ArrayList(ParsedTileEntry),
    raw_tile: RawTileInfo,
    grid_size: u32,
    tileset_c_wid_8: u32,
    has_alpha_warning: *bool,
) types.TilemapError!void {
    if (raw_tile.alpha != 1.0) {
        has_alpha_warning.* = true;
    }

    switch (grid_size) {
        8 => try append8x8Tile(aa, tiles_list, raw_tile),
        16 => try append16x16SubTiles(aa, tiles_list, raw_tile, tileset_c_wid_8),
        else => return types.TilemapError.UnsupportedGridSize,
    }
}

fn parseLayerTiles(
    aa: std.mem.Allocator,
    layer_obj: std.json.ObjectMap,
    grid_size: u32,
    tileset_defs: std.AutoHashMap(i64, TilesetDef),
    has_alpha_warning: *bool,
) types.TilemapError![]const ParsedTileEntry {
    if (grid_size != 8 and grid_size != 16) {
        return types.TilemapError.UnsupportedGridSize;
    }

    var tiles_list: std.ArrayList(ParsedTileEntry) = .empty;
    defer tiles_list.deinit(aa);

    const tileset_def_uid = getIntField(i64, layer_obj, "__tilesetDefUid") orelse -1;
    const tileset_c_wid_8: u32 = if (tileset_defs.get(tileset_def_uid)) |ts|
        ts.c_wid_8
    else if (grid_size == 16)
        return types.TilemapError.InvalidTilesetDefinition
    else
        0;

    const tile_arrays = [_]?std.json.Value{
        layer_obj.get("autoLayerTiles"),
        layer_obj.get("gridTiles"),
    };

    for (tile_arrays) |opt_arr| {
        const arr_val = opt_arr orelse continue;
        if (arr_val != .array) continue;

        for (arr_val.array.items) |t_item| {
            if (t_item != .object) continue;
            const raw_tile = parseRawTileObject(t_item.object) orelse continue;
            try appendTileEntries(aa, &tiles_list, raw_tile, grid_size, tileset_c_wid_8, has_alpha_warning);
        }
    }

    return tiles_list.toOwnedSlice(aa) catch return types.TilemapError.OutOfMemory;
}

fn parseEntities(aa: std.mem.Allocator, layer_obj: std.json.ObjectMap) types.TilemapError![]const ParsedEntity {
    var entities_list: std.ArrayList(ParsedEntity) = .empty;
    defer entities_list.deinit(aa);

    const ents_val = layer_obj.get("entityInstances") orelse return &[_]ParsedEntity{};
    if (ents_val != .array) return &[_]ParsedEntity{};

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

        entities_list.append(aa, .{
            .identifier = aa.dupe(u8, ent_id) catch return types.TilemapError.OutOfMemory,
            .x = ent_x,
            .y = ent_y,
            .width = ent_w,
            .height = ent_h,
        }) catch return types.TilemapError.OutOfMemory;
    }

    return entities_list.toOwnedSlice(aa) catch return types.TilemapError.OutOfMemory;
}

fn parseLayerInstance(
    aa: std.mem.Allocator,
    layer_obj: std.json.ObjectMap,
    px_wid: u32,
    px_hei: u32,
    tileset_defs: std.AutoHashMap(i64, TilesetDef),
    bg_layer_count: *usize,
    int_grid_count: *usize,
) types.TilemapError!?ParsedLayer {
    const type_str = getStringField(layer_obj, "__type") orelse return null;
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

    if (layer_type == .int_grid) {
        int_grid_count.* += 1;
        if (int_grid_count.* > 1) {
            return types.TilemapError.MultipleIntGridLayersNotSupported;
        }
    }

    const layer_id = getStringField(layer_obj, "__identifier") orelse "Layer";
    const grid_size = getIntField(u32, layer_obj, "__gridSize") orelse Limits.TILE_SIZE_PX;
    const c_wid = getIntField(u32, layer_obj, "__cWid") orelse (px_wid / grid_size);
    const c_hei = getIntField(u32, layer_obj, "__cHei") orelse (px_hei / grid_size);
    const tileset_rel_path = if (getStringField(layer_obj, "__tilesetRelPath")) |p|
        aa.dupe(u8, p) catch return types.TilemapError.OutOfMemory
    else
        null;

    const collision_masks = if (layer_type == .int_grid)
        try parseIntGridCollisions(aa, layer_obj)
    else
        null;

    var has_alpha_warning = false;
    const tiles = if (layer_type != .entities)
        try parseLayerTiles(aa, layer_obj, grid_size, tileset_defs, &has_alpha_warning)
    else
        &[_]ParsedTileEntry{};

    const is_visual_bg = (layer_type == .tiles or layer_type == .auto_layer or
        (layer_type == .int_grid and tiles.len > 0));

    if (is_visual_bg) {
        bg_layer_count.* += 1;
        if (bg_layer_count.* > Limits.MAX_BG_LAYERS) {
            return types.TilemapError.TooManyLayers;
        }
    }

    const entities = if (layer_type == .entities)
        try parseEntities(aa, layer_obj)
    else
        &[_]ParsedEntity{};

    // Skip empty Entities layers
    if (layer_type == .entities and entities.len == 0) {
        return null;
    }

    return ParsedLayer{
        .identifier = aa.dupe(u8, layer_id) catch return types.TilemapError.OutOfMemory,
        .layer_type = layer_type,
        .grid_size = grid_size,
        .c_wid = c_wid,
        .c_hei = c_hei,
        .tileset_rel_path = tileset_rel_path,
        .tiles = tiles,
        .collision_masks = collision_masks,
        .entities = entities,
        .has_alpha_warning = has_alpha_warning,
    };
}

fn parseLevel(
    aa: std.mem.Allocator,
    lvl_item: std.json.Value,
    tileset_defs: std.AutoHashMap(i64, TilesetDef),
) types.TilemapError!ParsedLevel {
    if (lvl_item != .object) return types.TilemapError.InvalidJsonSchema;
    const lvl_obj = lvl_item.object;

    const identifier = getStringField(lvl_obj, "identifier") orelse "Level";
    const world_x = getIntField(i32, lvl_obj, "worldX") orelse 0;
    const world_y = getIntField(i32, lvl_obj, "worldY") orelse 0;
    const px_wid = getIntField(u32, lvl_obj, "pxWid") orelse return types.TilemapError.InvalidMapDimensions;
    const px_hei = getIntField(u32, lvl_obj, "pxHei") orelse return types.TilemapError.InvalidMapDimensions;

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
    var int_grid_count: usize = 0;

    if (lvl_obj.get("layerInstances")) |layers_val| {
        if (layers_val == .array) {
            for (layers_val.array.items) |layer_item| {
                if (layer_item != .object) continue;
                if (try parseLayerInstance(
                    aa,
                    layer_item.object,
                    px_wid,
                    px_hei,
                    tileset_defs,
                    &bg_layer_count,
                    &int_grid_count,
                )) |layer| {
                    parsed_layers.append(aa, layer) catch return types.TilemapError.OutOfMemory;
                }
            }
        }
    }

    return ParsedLevel{
        .identifier = aa.dupe(u8, identifier) catch return types.TilemapError.OutOfMemory,
        .world_x = world_x,
        .world_y = world_y,
        .px_wid = px_wid,
        .px_hei = px_hei,
        .layers = parsed_layers.toOwnedSlice(aa) catch return types.TilemapError.OutOfMemory,
    };
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

    try validateIntGridDefs(root);

    const levels_val = root.get("levels") orelse return types.TilemapError.MissingLevelData;
    if (levels_val != .array or levels_val.array.items.len == 0) {
        return types.TilemapError.MissingLevelData;
    }

    var parsed_levels: std.ArrayList(ParsedLevel) = .empty;
    defer parsed_levels.deinit(aa);

    for (levels_val.array.items) |lvl_item| {
        const level = try parseLevel(aa, lvl_item, tileset_defs);
        parsed_levels.append(aa, level) catch return types.TilemapError.OutOfMemory;
    }

    return TilemapMetadata{
        .arena = arena,
        .levels = parsed_levels.toOwnedSlice(aa) catch return types.TilemapError.OutOfMemory,
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
    // 4 visual AutoLayers conforming to GBA Mode 0 hardware limit + 1 IntGrid collision layer
    try std.testing.expectEqual(@as(usize, 5), level.layers.len);
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

test "LDT009: Reject 16x16 tile layer with missing tileset definition" {
    const raw_json =
        \\{
        \\  "jsonVersion": "1.5.3",
        \\  "defs": { "tilesets": [], "layers": [] },
        \\  "levels": [
        \\    {
        \\      "identifier": "Level_0",
        \\      "worldX": 0, "worldY": 0, "pxWid": 256, "pxHei": 256,
        \\      "layerInstances": [
        \\        {
        \\          "__identifier": "Tiles16",
        \\          "__type": "Tiles",
        \\          "__gridSize": 16,
        \\          "__cWid": 16,
        \\          "__cHei": 16,
        \\          "__tilesetDefUid": 999,
        \\          "gridTiles": [{ "px": [0, 0], "src": [0, 0], "f": 0, "t": 0, "a": 1.0 }]
        \\        }
        \\      ]
        \\    }
        \\  ]
        \\}
    ;
    try std.testing.expectError(error.InvalidTilesetDefinition, parseJsonHelper(std.testing.allocator, raw_json));
}

test "LDT010: Reject unsupported tile grid size (e.g. 24x24 or 32x32)" {
    const raw_json_24 =
        \\{
        \\  "jsonVersion": "1.5.3",
        \\  "defs": { "tilesets": [], "layers": [] },
        \\  "levels": [
        \\    {
        \\      "identifier": "Level_0",
        \\      "worldX": 0, "worldY": 0, "pxWid": 240, "pxHei": 240,
        \\      "layerInstances": [
        \\        {
        \\          "__identifier": "Tiles24",
        \\          "__type": "Tiles",
        \\          "__gridSize": 24,
        \\          "__cWid": 10,
        \\          "__cHei": 10,
        \\          "__tilesetDefUid": 1,
        \\          "gridTiles": [{ "px": [0, 0], "src": [0, 0], "f": 0, "t": 0, "a": 1.0 }]
        \\        }
        \\      ]
        \\    }
        \\  ]
        \\}
    ;
    try std.testing.expectError(error.UnsupportedGridSize, parseJsonHelper(std.testing.allocator, raw_json_24));

    const raw_json_32 =
        \\{
        \\  "jsonVersion": "1.5.3",
        \\  "defs": { "tilesets": [], "layers": [] },
        \\  "levels": [
        \\    {
        \\      "identifier": "Level_0",
        \\      "worldX": 0, "worldY": 0, "pxWid": 256, "pxHei": 256,
        \\      "layerInstances": [
        \\        {
        \\          "__identifier": "Tiles32",
        \\          "__type": "Tiles",
        \\          "__gridSize": 32,
        \\          "__cWid": 8,
        \\          "__cHei": 8,
        \\          "__tilesetDefUid": 1,
        \\          "gridTiles": [{ "px": [0, 0], "src": [0, 0], "f": 0, "t": 0, "a": 1.0 }]
        \\        }
        \\      ]
        \\    }
        \\  ]
        \\}
    ;
    try std.testing.expectError(error.UnsupportedGridSize, parseJsonHelper(std.testing.allocator, raw_json_32));
}

test "LDT011: Reject level with multiple IntGrid layers" {
    const raw_json =
        \\{
        \\  "jsonVersion": "1.5.3",
        \\  "defs": {
        \\    "tilesets": [],
        \\    "layers": [
        \\      { "identifier": "Collisions1", "type": "IntGrid", "gridSize": 8, "intGridValues": [{ "value": 1, "identifier": "Solid" }] },
        \\      { "identifier": "Collisions2", "type": "IntGrid", "gridSize": 8, "intGridValues": [{ "value": 1, "identifier": "Solid" }] }
        \\    ]
        \\  },
        \\  "levels": [
        \\    {
        \\      "identifier": "Level_0",
        \\      "worldX": 0, "worldY": 0, "pxWid": 240, "pxHei": 160,
        \\      "layerInstances": [
        \\        {
        \\          "__identifier": "Collisions1",
        \\          "__type": "IntGrid",
        \\          "__gridSize": 8,
        \\          "__cWid": 30,
        \\          "__cHei": 20,
        \\          "intGridCsv": [1, 0, 0]
        \\        },
        \\        {
        \\          "__identifier": "Collisions2",
        \\          "__type": "IntGrid",
        \\          "__gridSize": 8,
        \\          "__cWid": 30,
        \\          "__cHei": 20,
        \\          "intGridCsv": [0, 1, 0]
        \\        }
        \\      ]
        \\    }
        \\  ]
        \\}
    ;
    try std.testing.expectError(error.MultipleIntGridLayersNotSupported, parseJsonHelper(std.testing.allocator, raw_json));
}

test "LDT012: Reject 1 tiled IntGrid + 4 visual layers exceeding 4 BG limit" {
    const raw_json =
        \\{
        \\  "jsonVersion": "1.5.3",
        \\  "defs": {
        \\    "tilesets": [{ "uid": 1, "pxWid": 128, "pxHei": 128, "tileGridSize": 8 }],
        \\    "layers": [
        \\      { "identifier": "TerrainIntGrid", "type": "IntGrid", "gridSize": 8, "intGridValues": [{ "value": 1, "identifier": "Solid" }] }
        \\    ]
        \\  },
        \\  "levels": [
        \\    {
        \\      "identifier": "Level_0",
        \\      "worldX": 0, "worldY": 0, "pxWid": 240, "pxHei": 160,
        \\      "layerInstances": [
        \\        {
        \\          "__identifier": "TerrainIntGrid",
        \\          "__type": "IntGrid",
        \\          "__gridSize": 8,
        \\          "__cWid": 30,
        \\          "__cHei": 20,
        \\          "__tilesetDefUid": 1,
        \\          "intGridCsv": [1, 0, 0],
        \\          "autoLayerTiles": [{ "px": [0, 0], "src": [0, 0], "f": 0, "t": 1, "a": 1.0 }]
        \\        },
        \\        { "__identifier": "BG1", "__type": "AutoLayer", "__gridSize": 8, "__cWid": 30, "__cHei": 20, "autoLayerTiles": [] },
        \\        { "__identifier": "BG2", "__type": "AutoLayer", "__gridSize": 8, "__cWid": 30, "__cHei": 20, "autoLayerTiles": [] },
        \\        { "__identifier": "BG3", "__type": "AutoLayer", "__gridSize": 8, "__cWid": 30, "__cHei": 20, "autoLayerTiles": [] },
        \\        { "__identifier": "BG4", "__type": "AutoLayer", "__gridSize": 8, "__cWid": 30, "__cHei": 20, "autoLayerTiles": [] }
        \\      ]
        \\    }
        \\  ]
        \\}
    ;
    // 1 tiled IntGrid (1 BG) + 4 AutoLayers (4 BG) = 5 visual BG layers -> TooManyLayers
    try std.testing.expectError(error.TooManyLayers, parseJsonHelper(std.testing.allocator, raw_json));
}

test "LDT013: Parse pure IntGrid and Entities without visual BG layers" {
    const raw_json =
        \\{
        \\  "jsonVersion": "1.5.3",
        \\  "defs": {
        \\    "tilesets": [],
        \\    "layers": [
        \\      { "identifier": "LogicGrid", "type": "IntGrid", "gridSize": 8, "intGridValues": [{ "value": 1, "identifier": "Solid" }] }
        \\    ]
        \\  },
        \\  "levels": [
        \\    {
        \\      "identifier": "Level_LogicOnly",
        \\      "worldX": 0, "worldY": 0, "pxWid": 240, "pxHei": 160,
        \\      "layerInstances": [
        \\        {
        \\          "__identifier": "LogicGrid",
        \\          "__type": "IntGrid",
        \\          "__gridSize": 8,
        \\          "__cWid": 30,
        \\          "__cHei": 20,
        \\          "intGridCsv": [1, 0, 1]
        \\        },
        \\        {
        \\          "__identifier": "Spawns",
        \\          "__type": "Entities",
        \\          "__gridSize": 8,
        \\          "__cWid": 30,
        \\          "__cHei": 20,
        \\          "entityInstances": [
        \\            {
        \\              "__identifier": "PlayerStart",
        \\              "__grid": [2, 3],
        \\              "px": [16, 24],
        \\              "width": 16,
        \\              "height": 16
        \\            }
        \\          ]
        \\        }
        \\      ]
        \\    }
        \\  ]
        \\}
    ;
    var project = try parseJsonHelper(std.testing.allocator, raw_json);
    defer project.deinit();

    const level = project.levels[0];
    try std.testing.expectEqual(@as(usize, 2), level.layers.len);

    const int_grid_layer = level.layers[0];
    try std.testing.expectEqual(LayerType.int_grid, int_grid_layer.layer_type);
    try std.testing.expect(int_grid_layer.collision_masks != null);
    try std.testing.expectEqual(@as(usize, 0), int_grid_layer.tiles.len);

    const entities_layer = level.layers[1];
    try std.testing.expectEqual(LayerType.entities, entities_layer.layer_type);
    try std.testing.expectEqual(@as(usize, 1), entities_layer.entities.len);
    try std.testing.expectEqualStrings("PlayerStart", entities_layer.entities[0].identifier);
}

test "LDT014: End-to-end 16x16 tile layer expansion into four 8x8 subtiles" {
    const raw_json =
        \\{
        \\  "jsonVersion": "1.5.3",
        \\  "defs": {
        \\    "tilesets": [
        \\      { "uid": 100, "identifier": "World16", "pxWid": 32, "pxHei": 32 }
        \\    ],
        \\    "layers": [
        \\      { "identifier": "Terrain16", "type": "Tiles", "gridSize": 16 }
        \\    ]
        \\  },
        \\  "levels": [
        \\    {
        \\      "identifier": "Level_16x16",
        \\      "worldX": 0, "worldY": 0, "pxWid": 64, "pxHei": 64,
        \\      "layerInstances": [
        \\        {
        \\          "__identifier": "Terrain16",
        \\          "__type": "Tiles",
        \\          "__gridSize": 16,
        \\          "__cWid": 4,
        \\          "__cHei": 4,
        \\          "__tilesetDefUid": 100,
        \\          "gridTiles": [
        \\            { "px": [16, 0], "src": [0, 0], "f": 0, "t": 0, "d": [1], "a": 1.0 },
        \\            { "px": [0, 16], "src": [0, 0], "f": 1, "t": 0, "d": [2], "a": 1.0 }
        \\          ]
        \\        }
        \\      ]
        \\    }
        \\  ]
        \\}
    ;
    var project = try parseJsonHelper(std.testing.allocator, raw_json);
    defer project.deinit();

    const level = project.levels[0];
    try std.testing.expectEqual(@as(usize, 1), level.layers.len);

    const terrain_layer = level.layers[0];
    try std.testing.expectEqual(LayerType.tiles, terrain_layer.layer_type);
    // 2 16x16 tiles -> expanded to 8 8x8 subtiles
    try std.testing.expectEqual(@as(usize, 8), terrain_layer.tiles.len);

    // 1st 16x16 tile at cell (gx=1, gy=0) -> pixel (px=16, py=0) -> 8x8 cells:
    // Top-Left: (x=2, y=0), tile_id=0, h_flip=false, v_flip=false
    try std.testing.expectEqual(@as(u16, 2), terrain_layer.tiles[0].x);
    try std.testing.expectEqual(@as(u16, 0), terrain_layer.tiles[0].y);
    try std.testing.expectEqual(@as(u32, 0), terrain_layer.tiles[0].tile_id);
    try std.testing.expectEqual(false, terrain_layer.tiles[0].h_flip);

    // Top-Right: (x=3, y=0), tile_id=1
    try std.testing.expectEqual(@as(u16, 3), terrain_layer.tiles[1].x);
    try std.testing.expectEqual(@as(u16, 0), terrain_layer.tiles[1].y);
    try std.testing.expectEqual(@as(u32, 1), terrain_layer.tiles[1].tile_id);

    // Bottom-Left: (x=2, y=1), tile_id=4 (since tileset_c_wid_8 = 32 / 8 = 4)
    try std.testing.expectEqual(@as(u16, 2), terrain_layer.tiles[2].x);
    try std.testing.expectEqual(@as(u16, 1), terrain_layer.tiles[2].y);
    try std.testing.expectEqual(@as(u32, 4), terrain_layer.tiles[2].tile_id);

    // Bottom-Right: (x=3, y=1), tile_id=5
    try std.testing.expectEqual(@as(u16, 3), terrain_layer.tiles[3].x);
    try std.testing.expectEqual(@as(u16, 1), terrain_layer.tiles[3].y);
    try std.testing.expectEqual(@as(u32, 5), terrain_layer.tiles[3].tile_id);

    // 2nd 16x16 tile at cell (gx=0, gy=1) with f=1 (horizontal flip):
    // Top-Left becomes sub-tile 1 (flipped): (x=0, y=2), tile_id=1, h_flip=true
    try std.testing.expectEqual(@as(u16, 0), terrain_layer.tiles[4].x);
    try std.testing.expectEqual(@as(u16, 2), terrain_layer.tiles[4].y);
    try std.testing.expectEqual(@as(u32, 1), terrain_layer.tiles[4].tile_id);
    try std.testing.expectEqual(true, terrain_layer.tiles[4].h_flip);

    // Top-Right becomes sub-tile 0 (flipped): (x=1, y=2), tile_id=0, h_flip=true
    try std.testing.expectEqual(@as(u16, 1), terrain_layer.tiles[5].x);
    try std.testing.expectEqual(@as(u16, 2), terrain_layer.tiles[5].y);
    try std.testing.expectEqual(@as(u32, 0), terrain_layer.tiles[5].tile_id);
    try std.testing.expectEqual(true, terrain_layer.tiles[5].h_flip);

    // Bottom-Left becomes sub-tile 3 (flipped): (x=0, y=3), tile_id=5, h_flip=true
    try std.testing.expectEqual(@as(u16, 0), terrain_layer.tiles[6].x);
    try std.testing.expectEqual(@as(u16, 3), terrain_layer.tiles[6].y);
    try std.testing.expectEqual(@as(u32, 5), terrain_layer.tiles[6].tile_id);
    try std.testing.expectEqual(true, terrain_layer.tiles[6].h_flip);

    // Bottom-Right becomes sub-tile 2 (flipped): (x=1, y=3), tile_id=4, h_flip=true
    try std.testing.expectEqual(@as(u16, 1), terrain_layer.tiles[7].x);
    try std.testing.expectEqual(@as(u16, 3), terrain_layer.tiles[7].y);
    try std.testing.expectEqual(@as(u32, 4), terrain_layer.tiles[7].tile_id);
    try std.testing.expectEqual(true, terrain_layer.tiles[7].h_flip);
}
