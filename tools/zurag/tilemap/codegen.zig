const std = @import("std");
const types = @import("types.zig");
const png = @import("../png.zig");
const tile = @import("../tile.zig");
const engine = @import("zamgba-engine");

pub const TilemapCodegenOptions = struct {
    map_name: []const u8 = "map",
    tileset_name: []const u8 = "tileset",
    bpp: png.BppMode = .bpp4,
    color_adjust: bool = false,
    no_palette: bool = false,
    no_tileset: bool = false,
};

pub const TilemapCodegenError = error{
    InvalidMetadata,
    NoLevelsFound,
    ImageDecodeError,
    TileSliceError,
    PaletteExtractError,
    WriteError,
    OutOfMemory,
    Unimplemented,
};

/// Generates Zig source code for ROM-resident GBA Mode 0 tilemap structures from parsed TilemapMetadata.
pub fn generateTilemapZigSource(
    allocator: std.mem.Allocator,
    metadata: *const types.TilemapMetadata,
    tileset_png_bytes: ?[]const u8,
    options: TilemapCodegenOptions,
) TilemapCodegenError![]u8 {
    _ = allocator;
    _ = metadata;
    _ = tileset_png_bytes;
    _ = options;
    return error.Unimplemented;
}

// ====================================================================
// Unit Tests for Tilemap Code Generator (TDD Red Phase)
// ====================================================================

test "TMC001: Generate single layer map ScreenEntry ROM table" {
    const test_assets = @import("test_palettes");
    const tilemap = @import("../tilemap.zig");

    var meta = try tilemap.parseMetadata(std.testing.allocator, test_assets.ldtk_t01_intgrid, .auto);
    defer meta.deinit();

    const out = try generateTilemapZigSource(std.testing.allocator, &meta, null, .{
        .map_name = "test_level",
    });
    defer std.testing.allocator.free(out);

    try std.testing.expect(std.mem.indexOf(u8, out, "pub const ScreenEntry = engine.ScreenEntry;") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "pub const MapLayerData = engine.MapLayerData;") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "pub const Level_0_AutoLayer_entries: [") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, ".tile_index =") != null);
}

test "TMC002: Generate multi-layer map layer definitions and MapLayerData" {
    const test_assets = @import("test_palettes");
    const tilemap = @import("../tilemap.zig");

    var meta = try tilemap.parseMetadata(std.testing.allocator, test_assets.ldtk_t03_4bg, .auto);
    defer meta.deinit();

    const out = try generateTilemapZigSource(std.testing.allocator, &meta, null, .{
        .map_name = "multi_bg_map",
    });
    defer std.testing.allocator.free(out);

    try std.testing.expect(std.mem.indexOf(u8, out, "Level_0_BG0_entries") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "Level_0_BG1_entries") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "Level_0_BG2_entries") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "Level_0_BG3_entries") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "pub const Level_0_BG0_data: MapLayerData = .{") != null);
}

test "TMC003: Generate IntGrid collision masks table" {
    const test_assets = @import("test_palettes");
    const tilemap = @import("../tilemap.zig");

    var meta = try tilemap.parseMetadata(std.testing.allocator, test_assets.ldtk_t01_intgrid, .auto);
    defer meta.deinit();

    const out = try generateTilemapZigSource(std.testing.allocator, &meta, null, .{
        .map_name = "collision_level",
    });
    defer std.testing.allocator.free(out);

    try std.testing.expect(std.mem.indexOf(u8, out, "pub const Level_0_IntGrid_collision_masks: [") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "0x0001") != null); // layer 0 bit
}

test "TMC004: Generate level entities array and typed declarations" {
    const test_assets = @import("test_palettes");
    const tilemap = @import("../tilemap.zig");

    var meta = try tilemap.parseMetadata(std.testing.allocator, test_assets.ldtk_t04_entities, .auto);
    defer meta.deinit();

    const out = try generateTilemapZigSource(std.testing.allocator, &meta, null, .{
        .map_name = "dungeon_entities",
    });
    defer std.testing.allocator.free(out);

    try std.testing.expect(std.mem.indexOf(u8, out, "pub const Entity = struct {") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "pub const Level_0_entities: [") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, ".identifier = \"PlayerSpawn\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, ".x = 32") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, ".y = 48") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, ".identifier = \"EnemyOrc\"") != null);
}

test "TMC005: Generate tile flip bitfields (h_flip, v_flip) in ScreenEntry" {
    const test_assets = @import("test_palettes");
    const tilemap = @import("../tilemap.zig");

    var meta = try tilemap.parseMetadata(std.testing.allocator, test_assets.ldtk_t05_flips, .auto);
    defer meta.deinit();

    const out = try generateTilemapZigSource(std.testing.allocator, &meta, null, .{
        .map_name = "flip_map",
    });
    defer std.testing.allocator.free(out);

    try std.testing.expect(std.mem.indexOf(u8, out, ".h_flip = true") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, ".v_flip = true") != null);
}

test "TMC006: Generate complete map with tileset PNG and palette" {
    const test_assets = @import("test_palettes");
    const tilemap = @import("../tilemap.zig");

    var meta = try tilemap.parseMetadata(std.testing.allocator, test_assets.ldtk_t01_intgrid, .auto);
    defer meta.deinit();

    const out = try generateTilemapZigSource(std.testing.allocator, &meta, test_assets.png_pal16, .{
        .map_name = "full_map",
        .bpp = .bpp4,
    });
    defer std.testing.allocator.free(out);

    try std.testing.expect(std.mem.indexOf(u8, out, "pub const palette: [16]u16 = [_]u16{") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "pub const tileset_tiles: [") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "pub const tileset: engine.TileSet = .{") != null);
}

test "TMC007: Reject invalid or empty tilemap metadata" {
    var empty_meta = types.TilemapMetadata{
        .arena = std.heap.ArenaAllocator.init(std.testing.allocator),
        .levels = &.{},
    };
    defer empty_meta.deinit();

    try std.testing.expectError(
        error.NoLevelsFound,
        generateTilemapZigSource(std.testing.allocator, &empty_meta, null, .{}),
    );
}
