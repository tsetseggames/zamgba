const std = @import("std");
const hal = @import("zamgba-hal");
const physics = @import("../physics/physics.zig");
const color = @import("color.zig");

/// Re-export GBA hardware 15-bit Bgr555 representation.
pub const Bgr555 = color.Bgr555;

/// Hardware-aligned 16-bit packed Screen Entry for GBA Text Backgrounds.
/// The definition is here: https://gbadev.net/tonc/regbg.html#sec-map
pub const ScreenEntry = packed struct(u16) {
    tile_index: u10 = 0,
    h_flip: bool = false,
    v_flip: bool = false,
    palette_bank: u4 = 0,

    pub inline fn raw(self: ScreenEntry) u16 {
        return @bitCast(self);
    }

    pub inline fn fromRaw(val: u16) ScreenEntry {
        return @bitCast(val);
    }
};

/// 4-bpp 8x8 Tile (32 bytes = 8 u32 words).
pub const Tile4bpp = [8]u32;

/// 8-bpp 8x8 Tile (64 bytes = 16 u32 words).
pub const Tile8bpp = [16]u32;

/// Tagged union representing typed tile graphics data in 4-bpp or 8-bpp format.
pub const TileData = union(enum) {
    bpp4: []const Tile4bpp,
    bpp8: []const Tile8bpp,

    pub fn tileCount(self: TileData) usize {
        return switch (self) {
            .bpp4 => |tiles| tiles.len,
            .bpp8 => |tiles| tiles.len,
        };
    }

    pub fn byteSize(self: TileData) usize {
        return switch (self) {
            .bpp4 => |tiles| tiles.len * @sizeOf(Tile4bpp),
            .bpp8 => |tiles| tiles.len * @sizeOf(Tile8bpp),
        };
    }

    pub fn wordCount(self: TileData) usize {
        return self.byteSize() / @sizeOf(u32);
    }

    pub fn rawPtr(self: TileData) [*]const u32 {
        return switch (self) {
            .bpp4 => |tiles| @ptrCast(tiles.ptr),
            .bpp8 => |tiles| @ptrCast(tiles.ptr),
        };
    }

    pub fn is8bpp(self: TileData) bool {
        return self == .bpp8;
    }
};

/// ROM-baked static TileSet asset containing graphics, palette, and tile collision lookup.
pub const TileSet = struct {
    tiles: TileData,
    palette: []const Bgr555,
    collision_flags: []const u8,
};

/// ROM-baked static map layer asset referencing a TileSet and cell entries.
pub const MapLayerData = struct {
    width: u16, // Width in tiles (e.g. 32, 64)
    height: u16, // Height in tiles (e.g. 32, 64)
    tileset: *const TileSet,
    entries: []const ScreenEntry, // Flattened 2D grid of ScreenEntry values (width * height)
    collision: ?[]const u8 = null, // Optional direct per-cell collision override grid
};

/// Converts hal.display.BgSize to physics.MapSize.
pub fn mapSizeFromBgSize(size: hal.display.BgSize) physics.MapSize {
    return switch (size) {
        .size_32x32 => .size_256x256,
        .size_64x32 => .size_512x256,
        .size_32x64 => .size_256x512,
        .size_64x64 => .size_512x512,
    };
}

/// Runtime background layer instance bound to a hardware BG channel.
pub const TileMapLayer = struct {
    bg_id: hal.display.BgId,
    charblock: u2,
    screenblock: u5,
    size: hal.display.BgSize,
    data: *const MapLayerData,
    scroll_x: i32 = 0,
    scroll_y: i32 = 0,
    priority: u2 = 1,

    /// Configures hardware registers and stages initial tiles/entries to VRAM.
    pub fn initHardware(self: *TileMapLayer) void {
        if (hal.specs.is_gba_target) {
            hal.display.setBgControl(self.bg_id, .{
                .priority = self.priority,
                .charblock = self.charblock,
                .screenblock = self.screenblock,
                .is_8bpp = self.data.tileset.tiles.is8bpp(),
                .size = self.size,
            });
            hal.display.enableBgLayer(self.bg_id);
            hal.display.writeRegister();

            // Copy palette data to PALRAM
            const pal = self.data.tileset.palette;
            for (pal, 0..) |col, i| {
                if (i >= hal.specs.MemorySections.PALRAM_SIZE_BYTES / @sizeOf(u16)) break;
                hal.specs.MemorySections.PALRAM[i] = col.raw();
            }

            // Copy tileset graphics data (32-bit words) to designated Charblock
            const cbb_ptr: [*]volatile u32 = @ptrCast(@alignCast(hal.specs.MemorySections.VRAM + (@as(usize, self.charblock) * hal.specs.MemorySections.CHARBLOCK_SIZE_WORDS)));
            const words_to_copy = @min(
                self.data.tileset.tiles.wordCount(),
                hal.specs.MemorySections.CHARBLOCK_SIZE_BYTES / @sizeOf(u32),
            );
            const tiles_raw = self.data.tileset.tiles.rawPtr();
            for (0..words_to_copy) |i| {
                cbb_ptr[i] = tiles_raw[i];
            }

            // Copy screenblock entries to designated Screenblock
            const sbb_ptr = hal.specs.MemorySections.VRAM + (@as(usize, self.screenblock) * hal.specs.MemorySections.SCREENBLOCK_SIZE_WORDS);
            const entries = self.data.entries;
            for (entries, 0..) |entry, i| {
                if (i >= @as(usize, self.size.screenblocksCount()) * hal.specs.MemorySections.SCREENBLOCK_SIZE_WORDS) break;
                sbb_ptr[i] = entry.raw();
            }

            self.setScroll(self.scroll_x, self.scroll_y);
        }
    }

    /// Updates the layer scroll position and writes to hardware scroll registers.
    pub fn setScroll(self: *TileMapLayer, x: i32, y: i32) void {
        self.scroll_x = x;
        self.scroll_y = y;
        if (hal.specs.is_gba_target) {
            hal.display.setBgScroll(
                self.bg_id,
                @truncate(@as(u32, @bitCast(x))),
                @truncate(@as(u32, @bitCast(y))),
            );
        }
    }

    /// Constant-time collision lookup for world coordinates (in pixels).
    pub fn getCollisionAt(self: *const TileMapLayer, world_x: i32, world_y: i32) u8 {
        if (world_x < 0 or world_y < 0) return 0;
        const tx = @as(usize, @intCast(world_x >> 3));
        const ty = @as(usize, @intCast(world_y >> 3));
        if (tx >= self.data.width or ty >= self.data.height) return 0;

        const cell_idx = ty * @as(usize, self.data.width) + tx;
        if (self.data.collision) |coll| {
            if (cell_idx < coll.len) {
                return coll[cell_idx];
            }
            return 0;
        }

        if (cell_idx < self.data.entries.len) {
            const entry = self.data.entries[cell_idx];
            if (entry.tile_index < self.data.tileset.collision_flags.len) {
                return self.data.tileset.collision_flags[entry.tile_index];
            }
        }
        return 0;
    }

    /// Adapts TileMapLayer to CollisionMap without dynamic memory allocations.
    pub fn asCollisionMap(self: *const TileMapLayer) physics.CollisionMap {
        const Adapter = struct {
            fn isTileSolid(ctx: ?*const anyopaque, tx: u16, ty: u16) bool {
                const layer: *const TileMapLayer = @ptrCast(@alignCast(ctx.?));
                const wx = @as(i32, tx) << 3;
                const wy = @as(i32, ty) << 3;
                return layer.getCollisionAt(wx, wy) != 0;
            }
        };

        return physics.CollisionMap.initWithContext(
            mapSizeFromBgSize(self.size),
            @ptrCast(self),
            Adapter.isTileSolid,
            .solid,
        );
    }
};

// ===================================================================
// Unit tests (TLM001 - TLM005)
// ===================================================================

test "TLM001: ScreenEntry packed encoding and decoding" {
    // 1. Default value check
    const default_entry = ScreenEntry{};
    try std.testing.expectEqual(@as(u16, 0), default_entry.raw());

    // 2. Individual fields
    const entry1 = ScreenEntry{
        .tile_index = 513,
        .h_flip = true,
        .v_flip = false,
        .palette_bank = 3,
    };
    // 513 | (1 << 10) | (0 << 11) | (3 << 12) = 513 + 1024 + 12288 = 13825 (0x3601)
    try std.testing.expectEqual(@as(u16, 0x3601), entry1.raw());

    // 3. Round-trip from raw
    const restored = ScreenEntry.fromRaw(0x3601);
    try std.testing.expectEqual(@as(u10, 513), restored.tile_index);
    try std.testing.expect(restored.h_flip);
    try std.testing.expect(!restored.v_flip);
    try std.testing.expectEqual(@as(u4, 3), restored.palette_bank);

    const entry_vflip = ScreenEntry{
        .tile_index = 42,
        .h_flip = false,
        .v_flip = true,
        .palette_bank = 15,
    };
    // 42 | (1 << 11) | (15 << 12) = 42 + 2048 + 61440 = 63530 (0xF82A)
    try std.testing.expectEqual(@as(u16, 0xF82A), entry_vflip.raw());
    const restored_v = ScreenEntry.fromRaw(0xF82A);
    try std.testing.expectEqual(@as(u10, 42), restored_v.tile_index);
    try std.testing.expect(!restored_v.h_flip);
    try std.testing.expect(restored_v.v_flip);
    try std.testing.expectEqual(@as(u4, 15), restored_v.palette_bank);
}

test "TLM002: MapLayerData cell entry resolution and dimensions" {
    const dummy_tiles = [_]Tile4bpp{[_]u32{0} ** 8};
    const dummy_pal = [_]Bgr555{Bgr555{}} ** 16;
    const dummy_coll = [_]u8{ 0, 1, 2, 0 };
    const tileset = TileSet{
        .tiles = .{ .bpp4 = &dummy_tiles },
        .palette = &dummy_pal,
        .collision_flags = &dummy_coll,
    };

    const entries = [_]ScreenEntry{
        .{ .tile_index = 1 },
        .{ .tile_index = 2 },
        .{ .tile_index = 0 },
        .{ .tile_index = 1, .palette_bank = 1 },
    };

    const layer_data = MapLayerData{
        .width = 2,
        .height = 2,
        .tileset = &tileset,
        .entries = &entries,
    };

    try std.testing.expectEqual(@as(u16, 2), layer_data.width);
    try std.testing.expectEqual(@as(u16, 2), layer_data.height);
    try std.testing.expectEqual(@as(u10, 1), layer_data.entries[0].tile_index);
    try std.testing.expectEqual(@as(u10, 1), layer_data.entries[3].tile_index);
    try std.testing.expectEqual(@as(u4, 1), layer_data.entries[3].palette_bank);
    try std.testing.expectEqual(@as(u16, 0x1001), layer_data.entries[3].raw());
}

test "TLM003: TileMapLayer world-to-tile coordinate collision lookup and boundary safety" {
    const dummy_tiles = [_]Tile4bpp{[_]u32{0} ** 8};
    const dummy_pal = [_]Bgr555{Bgr555{}} ** 16;
    // Tile 0: Passable (0), Tile 1: Solid (1), Tile 2: Hazard/Water (2)
    const dummy_coll = [_]u8{ 0, 1, 2 };
    const tileset = TileSet{
        .tiles = .{ .bpp4 = &dummy_tiles },
        .palette = &dummy_pal,
        .collision_flags = &dummy_coll,
    };

    // 4x4 Map:
    // [0, 1, 0, 2]
    // [1, 0, 0, 0]
    // [0, 0, 1, 1]
    // [2, 0, 0, 0]
    const entries = [_]ScreenEntry{
        .{ .tile_index = 0 }, .{ .tile_index = 1 }, .{ .tile_index = 0 }, .{ .tile_index = 2 },
        .{ .tile_index = 1 }, .{ .tile_index = 0 }, .{ .tile_index = 0 }, .{ .tile_index = 0 },
        .{ .tile_index = 0 }, .{ .tile_index = 0 }, .{ .tile_index = 1 }, .{ .tile_index = 1 },
        .{ .tile_index = 2 }, .{ .tile_index = 0 }, .{ .tile_index = 0 }, .{ .tile_index = 0 },
    };

    const layer_data = MapLayerData{
        .width = 4,
        .height = 4,
        .tileset = &tileset,
        .entries = &entries,
    };

    var layer = TileMapLayer{
        .bg_id = .bg1,
        .charblock = 0,
        .screenblock = 8,
        .size = .size_32x32,
        .data = &layer_data,
    };

    layer.setScroll(10, 20);
    try std.testing.expectEqual(@as(i32, 10), layer.scroll_x);
    try std.testing.expectEqual(@as(i32, 20), layer.scroll_y);

    // Coordinate tests (8px per tile):
    // (0, 0) -> Tile (0, 0) -> Tile 0 -> collision 0
    try std.testing.expectEqual(@as(u8, 0), layer.getCollisionAt(0, 0));
    // (8, 0) -> Tile (1, 0) -> Tile 1 -> collision 1
    try std.testing.expectEqual(@as(u8, 1), layer.getCollisionAt(8, 0));
    // (12, 4) -> Tile (1, 0) -> Tile 1 -> collision 1 (sub-tile coordinate)
    try std.testing.expectEqual(@as(u8, 1), layer.getCollisionAt(12, 4));
    // (24, 0) -> Tile (3, 0) -> Tile 2 -> collision 2
    try std.testing.expectEqual(@as(u8, 2), layer.getCollisionAt(24, 0));
    // (0, 8) -> Tile (0, 1) -> Tile 1 -> collision 1
    try std.testing.expectEqual(@as(u8, 1), layer.getCollisionAt(0, 8));
    // (16, 16) -> Tile (2, 2) -> Tile 1 -> collision 1
    try std.testing.expectEqual(@as(u8, 1), layer.getCollisionAt(16, 16));

    // Out of bounds checks
    try std.testing.expectEqual(@as(u8, 0), layer.getCollisionAt(-1, 0));
    try std.testing.expectEqual(@as(u8, 0), layer.getCollisionAt(0, -1));
    try std.testing.expectEqual(@as(u8, 0), layer.getCollisionAt(32, 0)); // 4 * 8 = 32 (out of bounds)
    try std.testing.expectEqual(@as(u8, 0), layer.getCollisionAt(0, 32));
}

test "TLM004: TileMapLayer collision override grid takes precedence over TileSet flags" {
    const dummy_tiles = [_]Tile4bpp{[_]u32{0} ** 8};
    const dummy_pal = [_]Bgr555{Bgr555{}} ** 16;
    // TileSet says Tile 0 is passable (0), Tile 1 is solid (1)
    const dummy_coll = [_]u8{ 0, 1 };
    const tileset = TileSet{
        .tiles = .{ .bpp4 = &dummy_tiles },
        .palette = &dummy_pal,
        .collision_flags = &dummy_coll,
    };

    // 2x2 map where all tiles visually are Tile 0
    const entries = [_]ScreenEntry{
        .{ .tile_index = 0 }, .{ .tile_index = 0 },
        .{ .tile_index = 0 }, .{ .tile_index = 0 },
    };

    // Explicit override grid marking (1, 0) as solid (1) and (1, 1) as ladder (3)
    const collision_grid = [_]u8{
        0, 1,
        0, 3,
    };

    const layer_data = MapLayerData{
        .width = 2,
        .height = 2,
        .tileset = &tileset,
        .entries = &entries,
        .collision = &collision_grid,
    };

    const layer = TileMapLayer{
        .bg_id = .bg0,
        .charblock = 0,
        .screenblock = 4,
        .size = .size_32x32,
        .data = &layer_data,
    };

    // (0, 0) -> 0
    try std.testing.expectEqual(@as(u8, 0), layer.getCollisionAt(0, 0));
    // (8, 0) -> override says 1 (despite visual tile being Tile 0)
    try std.testing.expectEqual(@as(u8, 1), layer.getCollisionAt(8, 0));
    // (8, 8) -> override says 3
    try std.testing.expectEqual(@as(u8, 3), layer.getCollisionAt(8, 8));
}

test "TLM005: TileMapLayer.asCollisionMap physics integration" {
    const dummy_tiles = [_]Tile4bpp{[_]u32{0} ** 8};
    const dummy_pal = [_]Bgr555{Bgr555{}} ** 16;
    const dummy_coll = [_]u8{ 0, 1 };
    const tileset = TileSet{
        .tiles = .{ .bpp4 = &dummy_tiles },
        .palette = &dummy_pal,
        .collision_flags = &dummy_coll,
    };

    // 32x32 tiles map with a wall at (2, 2)
    var entries = [_]ScreenEntry{.{}} ** (32 * 32);
    entries[2 * 32 + 2] = .{ .tile_index = 1 }; // Tile 1 at (2, 2)

    const layer_data = MapLayerData{
        .width = 32,
        .height = 32,
        .tileset = &tileset,
        .entries = &entries,
    };

    const layer = TileMapLayer{
        .bg_id = .bg0,
        .charblock = 0,
        .screenblock = 0,
        .size = .size_32x32,
        .data = &layer_data,
    };

    const coll_map = layer.asCollisionMap();
    try std.testing.expectEqual(physics.MapSize.size_256x256, coll_map.size);

    // Box at (0, 0, 8, 8) -> clear
    const box_clear = physics.AABB.fromInt(0, 0, 8, 8);
    try std.testing.expect(!coll_map.isColliding(box_clear));

    // Box at (16, 16, 8, 8) -> hit tile (2, 2)
    const box_hit = physics.AABB.fromInt(16, 16, 8, 8);
    try std.testing.expect(coll_map.isColliding(box_hit));
}

test "TLM006: TileData and Tile4bpp/Tile8bpp type-safety and byte sizing" {
    // 1. Tile4bpp and Tile8bpp size guarantees
    try std.testing.expectEqual(@as(usize, 32), @sizeOf(Tile4bpp));
    try std.testing.expectEqual(@as(usize, 64), @sizeOf(Tile8bpp));

    // 2. TileData tagged union operations
    const tiles_4bpp = [_]Tile4bpp{
        [_]u32{0} ** 8,
        [_]u32{0x11111111} ** 8,
    };
    const data_4bpp = TileData{ .bpp4 = &tiles_4bpp };
    try std.testing.expect(!data_4bpp.is8bpp());
    try std.testing.expectEqual(@as(usize, 2), data_4bpp.tileCount());
    try std.testing.expectEqual(@as(usize, 64), data_4bpp.byteSize());
    try std.testing.expectEqual(@as(usize, 16), data_4bpp.wordCount());

    const tiles_8bpp = [_]Tile8bpp{
        [_]u32{0} ** 16,
    };
    const data_8bpp = TileData{ .bpp8 = &tiles_8bpp };
    try std.testing.expect(data_8bpp.is8bpp());
    try std.testing.expectEqual(@as(usize, 1), data_8bpp.tileCount());
    try std.testing.expectEqual(@as(usize, 64), data_8bpp.byteSize());
    try std.testing.expectEqual(@as(usize, 16), data_8bpp.wordCount());
}
