const std = @import("std");
const hal = @import("zamgba-hal");
const physics = @import("physics/physics.zig");
const gfx2d = @import("gfx2d/gfx2d.zig");

pub const CollisionMask = physics.CollisionMask;
pub const Collision = physics.Collision;

/// Hardware 15-bit BGR555 color format.
pub const Bgr555 = gfx2d.Bgr555;

/// Reserved tile index representing an empty, transparent tile in GBA text background maps.
pub const EMPTY_TILE_INDEX: u16 = 0;

/// Hardware-aligned 16-bit packed Screen Entry for GBA Text Backgrounds.
/// The definition is here: https://gbadev.net/tonc/regbg.html#sec-map
pub const ScreenEntry = packed struct(u16) {
    tile_index: u10 = EMPTY_TILE_INDEX,
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

/// Maps 2D tile coordinates (x, y) into the GBA hardware Screenblock VRAM halfword index according to BgSize.
fn getScreenEntryVramIndex(size: hal.display.BgSize, x: usize, y: usize) usize {
    const SBB_ENTRIES: usize = 1024;
    return switch (size) {
        .size_32x32 => y * 32 + x,
        .size_64x32 => (if (x < 32) 0 else SBB_ENTRIES) + y * 32 + (x % 32),
        .size_32x64 => (if (y < 32) 0 else SBB_ENTRIES) + (y % 32) * 32 + x,
        .size_64x64 => {
            const sbb_x: usize = if (x < 32) 0 else 1;
            const sbb_y: usize = if (y < 32) 0 else 1;
            const sbb_idx = sbb_y * 2 + sbb_x;
            return sbb_idx * SBB_ENTRIES + (y % 32) * 32 + (x % 32);
        },
    };
}

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
    collision_masks: []const CollisionMask = &.{},
};

/// ROM-baked static map layer asset referencing a TileSet and cell entries.
pub const MapLayerData = struct {
    width: u16, // Width in tiles (e.g. 32, 64)
    height: u16, // Height in tiles (e.g. 32, 64)
    tileset: ?*const TileSet = null,
    entries: []const ScreenEntry, // Flattened 2D grid of ScreenEntry values (width * height)
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

/// Infers the hardware background size from tile grid dimensions.
fn inferBgSize(data: *const MapLayerData) hal.display.BgSize {
    if (data.width > 32 and data.height > 32) {
        return .size_64x64;
    } else if (data.width > 32) {
        return .size_64x32;
    } else if (data.height > 32) {
        return .size_32x64;
    } else {
        return .size_32x32;
    }
}

/// Configuration options for initializing a TileMapLayer with automated VRAM allocation.
pub const TileMapLayerOptions = struct {
    bg_id: hal.display.BgId,
    priority: ?u2 = null,
    collision_mask: CollisionMask = Collision.ALL,
    size: ?hal.display.BgSize = null,
    manual_placement: ?struct {
        charblock: u2,
        screenblock: u5,
    } = null,
};

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
    collision_mask: CollisionMask = Collision.ALL,

    /// Initializes a TileMapLayer with automated Charblock and Screenblock allocation
    /// managed by BgVramManager, automatically deduping tilesets and inferring layer size.
    pub fn init(
        manager: *BgVramManager,
        data: *const MapLayerData,
        options: TileMapLayerOptions,
    ) BgVramError!TileMapLayer {
        const size = options.size orelse inferBgSize(data);

        // 1. Claim hardware BG channel
        try manager.claimBgId(options.bg_id);

        // 2. Allocate or validate Charblock and Screenblock(s)
        var cbb: u2 = 0;
        var sbb: u5 = 0;

        if (options.manual_placement) |manual| {
            const count = BgVramManager.screenblockCount(size);
            if (@as(u6, manual.screenblock) + count > 32) return error.Conflict;

            // Check screenblock conflict against already mapped screenblocks
            for (0..count) |offset| {
                if (manager.sbb_map_occupied[manual.screenblock + offset]) {
                    return error.Conflict;
                }
                const cbb_of_sbb: usize = (manual.screenblock + offset) / 8;
                if (manager.cbb_occupied[cbb_of_sbb] and cbb_of_sbb != manual.charblock) {
                    return error.Conflict;
                }
            }

            // Check charblock conflict
            if (manager.cbb_occupied[manual.charblock]) {
                if (data.tileset != null and manager.cbb_tilesets[manual.charblock] != data.tileset) {
                    return error.Conflict;
                }
            } else {
                // Check if any SBB in this CBB was claimed by a screenblock from another CBB
                for (0..8) |s| {
                    const check_sbb = @as(usize, manual.charblock) * 8 + s;
                    if (manager.sbb_map_occupied[check_sbb]) {
                        // SBB belongs to another layer's map
                        if (check_sbb < manual.screenblock or check_sbb >= manual.screenblock + count) {
                            return error.Conflict;
                        }
                    }
                }
                manager.cbb_occupied[manual.charblock] = true;
                manager.cbb_tilesets[manual.charblock] = data.tileset;
                for (0..8) |s| {
                    manager.sbb_occupied[@as(usize, manual.charblock) * 8 + s] = true;
                }
            }

            for (0..count) |offset| {
                manager.sbb_occupied[manual.screenblock + offset] = true;
                manager.sbb_map_occupied[manual.screenblock + offset] = true;
            }

            cbb = manual.charblock;
            sbb = manual.screenblock;
        } else {
            if (data.tileset) |ts| {
                cbb = try manager.allocateTileSet(ts);
            }
            sbb = try manager.allocateScreenblocks(size);
        }

        const priority = options.priority orelse @as(u2, @intCast(@backingInt(options.bg_id)));

        var layer = TileMapLayer{
            .bg_id = options.bg_id,
            .charblock = cbb,
            .screenblock = sbb,
            .size = size,
            .data = data,
            .scroll_x = 0,
            .scroll_y = 0,
            .priority = priority,
            .collision_mask = options.collision_mask,
        };
        layer.initHardware();
        return layer;
    }

    /// Configures hardware registers and stages initial tiles/entries to VRAM.
    fn initHardware(self: *TileMapLayer) void {
        if (hal.specs.is_gba_target) {
            const is_8bpp = if (self.data.tileset) |ts| ts.tiles.is8bpp() else false;
            hal.display.setBgControl(self.bg_id, .{
                .priority = self.priority,
                .charblock = self.charblock,
                .screenblock = self.screenblock,
                .is_8bpp = is_8bpp,
                .size = self.size,
            });
            hal.display.enableBgLayer(self.bg_id);
            hal.display.writeRegister();

            if (self.data.tileset) |ts| {
                // Copy palette data to PALRAM
                const pal = ts.palette;
                for (pal, 0..) |col, i| {
                    if (i >= hal.specs.MemorySections.PALRAM_SIZE_BYTES / @sizeOf(u16)) break;
                    hal.specs.MemorySections.PALRAM[i] = col.raw();
                }

                // Copy tileset graphics data (32-bit words) to designated Charblock
                const cbb_ptr: [*]volatile u32 = @ptrCast(@alignCast(hal.specs.MemorySections.VRAM + (@as(usize, self.charblock) * hal.specs.MemorySections.CHARBLOCK_SIZE_WORDS)));
                const words_to_copy = @min(
                    ts.tiles.wordCount(),
                    hal.specs.MemorySections.CHARBLOCK_SIZE_BYTES / @sizeOf(u32),
                );
                const tiles_raw = ts.tiles.rawPtr();
                for (0..words_to_copy) |i| {
                    cbb_ptr[i] = tiles_raw[i];
                }
            }

            // Copy screenblock entries to designated Screenblock(s)
            const sbb_ptr = hal.specs.MemorySections.VRAM + (@as(usize, self.screenblock) * hal.specs.MemorySections.SCREENBLOCK_SIZE_WORDS);
            const entries = self.data.entries;
            const max_x = @min(@as(usize, self.data.width), @as(usize, self.size.tileWidth()));
            const max_y = @min(@as(usize, self.data.height), @as(usize, self.size.tileHeight()));
            for (0..max_y) |y| {
                for (0..max_x) |x| {
                    const src_idx = y * @as(usize, self.data.width) + x;
                    if (src_idx < entries.len) {
                        const dest_idx = getScreenEntryVramIndex(self.size, x, y);
                        sbb_ptr[dest_idx] = entries[src_idx].raw();
                    }
                }
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

    /// Constant-time collision lookup for world coordinates (in pixels), returning the 16-bit CollisionMask.
    pub fn getCollisionAt(self: *const TileMapLayer, world_x: i32, world_y: i32) CollisionMask {
        if (world_x < 0 or world_y < 0) return Collision.NONE;
        const tx = @as(usize, @intCast(world_x >> 3));
        const ty = @as(usize, @intCast(world_y >> 3));
        if (tx >= self.data.width or ty >= self.data.height) return Collision.NONE;

        const cell_idx = ty * @as(usize, self.data.width) + tx;
        if (cell_idx < self.data.entries.len) {
            const entry = self.data.entries[cell_idx];
            if (self.data.tileset) |ts| {
                if (entry.tile_index < ts.collision_masks.len) {
                    return ts.collision_masks[entry.tile_index];
                }
            }
        }
        return Collision.NONE;
    }

    /// Adapts TileMapLayer to CollisionMap without dynamic memory allocations.
    pub fn asCollisionMap(self: *const TileMapLayer) physics.CollisionMap {
        const Adapter = struct {
            fn isTileSolid(ctx: ?*const anyopaque, tx: u16, ty: u16) bool {
                const layer: *const TileMapLayer = @ptrCast(@alignCast(ctx.?));
                const wx = @as(i32, tx) << 3;
                const wy = @as(i32, ty) << 3;
                return (layer.getCollisionAt(wx, wy) & layer.collision_mask) != 0;
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

pub const BgVramError = error{
    OutOfCharblocks,
    OutOfScreenblocks,
    OutOfBgLayers,
    Conflict,
};

/// Automated Mode 0 Background VRAM Layout and Resource Manager.
/// Manages Charblock (CBB 0..3), Screenblock (SBB 0..31), and BG channel (BG0..BG3) allocations,
/// automatically handling tileset deduplication, multi-screenblock contiguous layout,
/// and mutual CBB/SBB overlap conflict prevention.
pub const BgVramManager = struct {
    cbb_occupied: [4]bool = @splat(false),
    cbb_tilesets: [4]?*const TileSet = @splat(null),
    sbb_occupied: [32]bool = @splat(false),
    sbb_map_occupied: [32]bool = @splat(false),
    bg_occupied: [4]bool = @splat(false),

    pub fn init() BgVramManager {
        return .{};
    }

    pub fn reset(self: *BgVramManager) void {
        self.* = .{};
        hal.display.clearBgVram();
    }

    /// Returns the number of contiguous 2 KB Screenblocks required by a given BgSize.
    fn screenblockCount(size: hal.display.BgSize) u6 {
        return switch (size) {
            .size_32x32 => 1,
            .size_64x32 => 2,
            .size_32x64 => 2,
            .size_64x64 => 4,
        };
    }

    /// Allocates or retrieves an existing Charblock (0..3) for the given TileSet.
    /// If the tileset is already allocated, returns the same Charblock (deduplication).
    fn allocateTileSet(self: *BgVramManager, tileset: *const TileSet) BgVramError!u2 {
        // 1. Deduplication check: return existing Charblock if tileset was already assigned
        for (0..4) |i| {
            if (self.cbb_occupied[i] and self.cbb_tilesets[i] == tileset) {
                return @as(u2, @intCast(i));
            }
        }

        // 2. Find lowest free CBB whose corresponding 8 SBBs are completely unallocated
        for (0..4) |i| {
            if (self.cbb_occupied[i]) continue;
            var sbb_conflict = false;
            for (0..8) |s| {
                if (self.sbb_occupied[i * 8 + s]) {
                    sbb_conflict = true;
                    break;
                }
            }
            if (sbb_conflict) continue;

            self.cbb_occupied[i] = true;
            self.cbb_tilesets[i] = tileset;
            for (0..8) |s| {
                self.sbb_occupied[i * 8 + s] = true;
            }
            return @as(u2, @intCast(i));
        }

        return error.OutOfCharblocks;
    }

    /// Allocates contiguous Screenblocks (0..31) for the requested background size.
    fn allocateScreenblocks(self: *BgVramManager, size: hal.display.BgSize) BgVramError!u5 {
        const count = screenblockCount(size);
        var i: usize = 0;
        while (i + count <= 32) : (i += 1) {
            var fits = true;
            for (0..count) |offset| {
                if (self.sbb_occupied[i + offset]) {
                    fits = false;
                    break;
                }
            }
            if (fits) {
                for (0..count) |offset| {
                    self.sbb_occupied[i + offset] = true;
                    self.sbb_map_occupied[i + offset] = true;
                }
                return @as(u5, @intCast(i));
            }
        }
        return error.OutOfScreenblocks;
    }

    /// Allocates the next available hardware BG channel (bg0..bg3).
    fn allocateBgId(self: *BgVramManager) BgVramError!hal.display.BgId {
        const bg_ids = [_]hal.display.BgId{ .bg0, .bg1, .bg2, .bg3 };
        for (0..4) |i| {
            if (!self.bg_occupied[i]) {
                self.bg_occupied[i] = true;
                return bg_ids[i];
            }
        }
        return error.OutOfBgLayers;
    }

    /// Claims a specific hardware BG channel, erroring on conflict.
    fn claimBgId(self: *BgVramManager, bg_id: hal.display.BgId) BgVramError!void {
        const idx = @backingInt(bg_id);
        if (self.bg_occupied[idx]) return error.Conflict;
        self.bg_occupied[idx] = true;
    }

    /// Manually marks a Charblock as occupied, associating it with an optional TileSet.
    fn markCharblockOccupied(self: *BgVramManager, cbb: u2, tileset: ?*const TileSet) BgVramError!void {
        if (self.cbb_occupied[cbb]) {
            if (tileset != null and self.cbb_tilesets[cbb] == tileset) {
                return;
            }
            return error.Conflict;
        }
        for (0..8) |s| {
            if (self.sbb_occupied[@as(usize, cbb) * 8 + s]) {
                return error.Conflict;
            }
        }
        self.cbb_occupied[cbb] = true;
        self.cbb_tilesets[cbb] = tileset;
        for (0..8) |s| {
            self.sbb_occupied[@as(usize, cbb) * 8 + s] = true;
        }
    }

    /// Manually marks a contiguous range of Screenblocks as occupied.
    fn markScreenblocksOccupied(self: *BgVramManager, base_sbb: u5, count: u6) BgVramError!void {
        if (@as(u6, base_sbb) + count > 32) return error.Conflict;
        for (0..count) |offset| {
            if (self.sbb_occupied[base_sbb + offset]) return error.Conflict;
        }
        for (0..count) |offset| {
            self.sbb_occupied[base_sbb + offset] = true;
            self.sbb_map_occupied[base_sbb + offset] = true;
        }
    }

    /// Manually marks a hardware BG channel as occupied.
    fn markBgIdOccupied(self: *BgVramManager, bg_id: hal.display.BgId) BgVramError!void {
        return self.claimBgId(bg_id);
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
    const dummy_tiles = [_]Tile4bpp{@splat(0)};
    const dummy_pal: [16]Bgr555 = @splat(Bgr555{});
    const dummy_coll = [_]CollisionMask{ 0, Collision.layer(0), Collision.layer(1), 0 };
    const tileset = TileSet{
        .tiles = .{ .bpp4 = &dummy_tiles },
        .palette = &dummy_pal,
        .collision_masks = &dummy_coll,
    };

    const entries = [_]ScreenEntry{
        .{ .tile_index = 1 },
        .{ .tile_index = 2 },
        .{ .tile_index = EMPTY_TILE_INDEX },
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
    const dummy_tiles = [_]Tile4bpp{@splat(0)};
    const dummy_pal: [16]Bgr555 = @splat(Bgr555{});
    // Tile 0: Passable (NONE), Tile 1: Solid (Layer 0), Tile 2: Hazard/Water (Layer 1)
    const dummy_coll = [_]CollisionMask{ Collision.NONE, Collision.layer(0), Collision.layer(1) };
    const tileset = TileSet{
        .tiles = .{ .bpp4 = &dummy_tiles },
        .palette = &dummy_pal,
        .collision_masks = &dummy_coll,
    };

    // 4x4 Map:
    // [0, 1, 0, 2]
    // [1, 0, 0, 0]
    // [0, 0, 1, 1]
    // [2, 0, 0, 0]
    const entries = [_]ScreenEntry{
        .{ .tile_index = EMPTY_TILE_INDEX }, .{ .tile_index = 1 },                .{ .tile_index = EMPTY_TILE_INDEX }, .{ .tile_index = 2 },
        .{ .tile_index = 1 },                .{ .tile_index = EMPTY_TILE_INDEX }, .{ .tile_index = EMPTY_TILE_INDEX }, .{ .tile_index = EMPTY_TILE_INDEX },
        .{ .tile_index = EMPTY_TILE_INDEX }, .{ .tile_index = EMPTY_TILE_INDEX }, .{ .tile_index = 1 },                .{ .tile_index = 1 },
        .{ .tile_index = 2 },                .{ .tile_index = EMPTY_TILE_INDEX }, .{ .tile_index = EMPTY_TILE_INDEX }, .{ .tile_index = EMPTY_TILE_INDEX },
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
    // (0, 0) -> Tile (0, 0) -> Tile 0 -> NONE
    try std.testing.expectEqual(Collision.NONE, layer.getCollisionAt(0, 0));
    // (8, 0) -> Tile (1, 0) -> Tile 1 -> Layer 0
    try std.testing.expectEqual(Collision.layer(0), layer.getCollisionAt(8, 0));
    // (12, 4) -> Tile (1, 0) -> Tile 1 -> Layer 0 (sub-tile coordinate)
    try std.testing.expectEqual(Collision.layer(0), layer.getCollisionAt(12, 4));
    // (24, 0) -> Tile (3, 0) -> Tile 2 -> Layer 1
    try std.testing.expectEqual(Collision.layer(1), layer.getCollisionAt(24, 0));
    // (0, 8) -> Tile (0, 1) -> Tile 1 -> Layer 0
    try std.testing.expectEqual(Collision.layer(0), layer.getCollisionAt(0, 8));
    // (16, 16) -> Tile (2, 2) -> Tile 1 -> Layer 0
    try std.testing.expectEqual(Collision.layer(0), layer.getCollisionAt(16, 16));

    // Out of bounds checks
    try std.testing.expectEqual(Collision.NONE, layer.getCollisionAt(-1, 0));
    try std.testing.expectEqual(Collision.NONE, layer.getCollisionAt(0, -1));
    try std.testing.expectEqual(Collision.NONE, layer.getCollisionAt(32, 0)); // 4 * 8 = 32 (out of bounds)
    try std.testing.expectEqual(Collision.NONE, layer.getCollisionAt(0, 32));
}

test "TLM004: TileMapLayer collision handling with empty or partial TileSet collision masks" {
    const dummy_tiles = [_]Tile4bpp{@splat(0)};
    const dummy_pal: [16]Bgr555 = @splat(Bgr555{});
    // TileSet provides collision mask only for Tile 0 (NONE) and Tile 1 (Layer 0)
    const partial_coll = [_]CollisionMask{ Collision.NONE, Collision.layer(0) };
    const tileset_partial = TileSet{
        .tiles = .{ .bpp4 = &dummy_tiles },
        .palette = &dummy_pal,
        .collision_masks = &partial_coll,
    };

    // 2x2 map referencing Tile 0, Tile 1, Tile 2 (out of collision_masks bounds), Tile 3
    const entries = [_]ScreenEntry{
        .{ .tile_index = EMPTY_TILE_INDEX }, .{ .tile_index = 1 },
        .{ .tile_index = 2 },                .{ .tile_index = 3 },
    };

    const layer_data = MapLayerData{
        .width = 2,
        .height = 2,
        .tileset = &tileset_partial,
        .entries = &entries,
    };

    const layer = TileMapLayer{
        .bg_id = .bg0,
        .charblock = 0,
        .screenblock = 4,
        .size = .size_32x32,
        .data = &layer_data,
    };

    // (0, 0) -> Tile 0 -> NONE
    try std.testing.expectEqual(Collision.NONE, layer.getCollisionAt(0, 0));
    // (8, 0) -> Tile 1 -> Layer 0
    try std.testing.expectEqual(Collision.layer(0), layer.getCollisionAt(8, 0));
    // (0, 8) -> Tile 2 (beyond collision_masks slice) -> safely falls back to NONE
    try std.testing.expectEqual(Collision.NONE, layer.getCollisionAt(0, 8));
    // (8, 8) -> Tile 3 (beyond collision_masks slice) -> safely falls back to NONE
    try std.testing.expectEqual(Collision.NONE, layer.getCollisionAt(8, 8));

    // Test with completely empty collision_masks
    const tileset_empty = TileSet{
        .tiles = .{ .bpp4 = &dummy_tiles },
        .palette = &dummy_pal,
        .collision_masks = &.{},
    };
    const layer_data_empty = MapLayerData{
        .width = 2,
        .height = 2,
        .tileset = &tileset_empty,
        .entries = &entries,
    };
    const layer_empty = TileMapLayer{
        .bg_id = .bg0,
        .charblock = 0,
        .screenblock = 4,
        .size = .size_32x32,
        .data = &layer_data_empty,
    };
    try std.testing.expectEqual(Collision.NONE, layer_empty.getCollisionAt(8, 0));
}

test "TLM005: TileMapLayer.asCollisionMap physics integration" {
    const dummy_tiles = [_]Tile4bpp{@splat(0)};
    const dummy_pal: [16]Bgr555 = @splat(Bgr555{});
    const dummy_coll = [_]CollisionMask{ Collision.NONE, Collision.layer(0), Collision.layer(2) };
    const tileset = TileSet{
        .tiles = .{ .bpp4 = &dummy_tiles },
        .palette = &dummy_pal,
        .collision_masks = &dummy_coll,
    };

    // 32x32 tiles map with a wall at (2, 2) [Layer 0] and water at (4, 4) [Layer 2]
    var entries: [32 * 32]ScreenEntry = @splat(.{});
    entries[2 * 32 + 2] = .{ .tile_index = 1 }; // Tile 1 at (2, 2)
    entries[4 * 32 + 4] = .{ .tile_index = 2 }; // Tile 2 at (4, 4)

    const layer_data = MapLayerData{
        .width = 32,
        .height = 32,
        .tileset = &tileset,
        .entries = &entries,
    };

    var layer = TileMapLayer{
        .bg_id = .bg0,
        .charblock = 0,
        .screenblock = 0,
        .size = .size_32x32,
        .data = &layer_data,
        .collision_mask = Collision.layer(0), // Only collide with solid walls
    };

    const coll_map = layer.asCollisionMap();
    try std.testing.expectEqual(physics.MapSize.size_256x256, coll_map.size);

    // Box at (0, 0, 8, 8) -> clear
    const box_clear = physics.AABB.fromInt(0, 0, 8, 8);
    try std.testing.expect(!coll_map.isColliding(box_clear));

    // Box at (16, 16, 8, 8) -> hit tile (2, 2) which has Layer 0
    const box_hit_wall = physics.AABB.fromInt(16, 16, 8, 8);
    try std.testing.expect(coll_map.isColliding(box_hit_wall));

    // Box at (32, 32, 8, 8) -> tile (4, 4) which has Layer 2 -> ignored by layer.collision_mask (Layer 0)
    const box_water = physics.AABB.fromInt(32, 32, 8, 8);
    try std.testing.expect(!coll_map.isColliding(box_water));

    // Switch collision_mask to include Layer 2
    layer.collision_mask = Collision.layer(0) | Collision.layer(2);
    try std.testing.expect(coll_map.isColliding(box_water));
}

test "TLM006: TileData and Tile4bpp/Tile8bpp type-safety and byte sizing" {
    // 1. Tile4bpp and Tile8bpp size guarantees
    try std.testing.expectEqual(@as(usize, 32), @sizeOf(Tile4bpp));
    try std.testing.expectEqual(@as(usize, 64), @sizeOf(Tile8bpp));

    // 2. TileData tagged union operations
    const tiles_4bpp = [_]Tile4bpp{
        @splat(0),
        @splat(0x11111111),
    };
    const data_4bpp = TileData{ .bpp4 = &tiles_4bpp };
    try std.testing.expect(!data_4bpp.is8bpp());
    try std.testing.expectEqual(@as(usize, 2), data_4bpp.tileCount());
    try std.testing.expectEqual(@as(usize, 64), data_4bpp.byteSize());
    try std.testing.expectEqual(@as(usize, 16), data_4bpp.wordCount());

    const tiles_8bpp = [_]Tile8bpp{
        @splat(0),
    };
    const data_8bpp = TileData{ .bpp8 = &tiles_8bpp };
    try std.testing.expect(data_8bpp.is8bpp());
    try std.testing.expectEqual(@as(usize, 1), data_8bpp.tileCount());
    try std.testing.expectEqual(@as(usize, 64), data_8bpp.byteSize());
    try std.testing.expectEqual(@as(usize, 16), data_8bpp.wordCount());
}

test "TLM007: getScreenEntryVramIndex multi-screenblock address calculation" {
    // 32x32: single SBB, linear row-major (y * 32 + x)
    try std.testing.expectEqual(@as(usize, 0), getScreenEntryVramIndex(.size_32x32, 0, 0));
    try std.testing.expectEqual(@as(usize, 31), getScreenEntryVramIndex(.size_32x32, 31, 0));
    try std.testing.expectEqual(@as(usize, 32), getScreenEntryVramIndex(.size_32x32, 0, 1));
    try std.testing.expectEqual(@as(usize, 1023), getScreenEntryVramIndex(.size_32x32, 31, 31));

    // 64x32: 2 SBBs horizontally
    // Left SBB (x < 32): y * 32 + x
    try std.testing.expectEqual(@as(usize, 0), getScreenEntryVramIndex(.size_64x32, 0, 0));
    try std.testing.expectEqual(@as(usize, 31), getScreenEntryVramIndex(.size_64x32, 31, 0));
    // Right SBB (x >= 32): 1024 + y * 32 + (x - 32)
    try std.testing.expectEqual(@as(usize, 1024), getScreenEntryVramIndex(.size_64x32, 32, 0));
    try std.testing.expectEqual(@as(usize, 1024 + 31), getScreenEntryVramIndex(.size_64x32, 63, 0));

    // 32x64: 2 SBBs vertically
    // Top SBB (y < 32): y * 32 + x
    try std.testing.expectEqual(@as(usize, 0), getScreenEntryVramIndex(.size_32x64, 0, 0));
    // Bottom SBB (y >= 32): 1024 + (y - 32) * 32 + x
    try std.testing.expectEqual(@as(usize, 1024), getScreenEntryVramIndex(.size_32x64, 0, 32));

    // 64x64: 4 SBBs (2x2)
    // SBB 0 (top-left): (0, 0) -> 0, (31, 31) -> 1023
    try std.testing.expectEqual(@as(usize, 0), getScreenEntryVramIndex(.size_64x64, 0, 0));
    try std.testing.expectEqual(@as(usize, 1023), getScreenEntryVramIndex(.size_64x64, 31, 31));
    // SBB 1 (top-right): (32, 0) -> 1024, (63, 31) -> 2047
    try std.testing.expectEqual(@as(usize, 1024), getScreenEntryVramIndex(.size_64x64, 32, 0));
    try std.testing.expectEqual(@as(usize, 2047), getScreenEntryVramIndex(.size_64x64, 63, 31));
    // SBB 2 (bottom-left): (0, 32) -> 2048, (31, 63) -> 3071
    try std.testing.expectEqual(@as(usize, 2048), getScreenEntryVramIndex(.size_64x64, 0, 32));
    try std.testing.expectEqual(@as(usize, 3071), getScreenEntryVramIndex(.size_64x64, 31, 63));
    // SBB 3 (bottom-right): (32, 32) -> 3072, (63, 63) -> 4095
    try std.testing.expectEqual(@as(usize, 3072), getScreenEntryVramIndex(.size_64x64, 32, 32));
    try std.testing.expectEqual(@as(usize, 4095), getScreenEntryVramIndex(.size_64x64, 63, 63));
}

test "TLM008: EMPTY_TILE_INDEX constant represents reserved transparent tile" {
    try std.testing.expectEqual(@as(u16, 0), EMPTY_TILE_INDEX);
    const default_entry = ScreenEntry{};
    try std.testing.expectEqual(EMPTY_TILE_INDEX, default_entry.tile_index);
}

// ===================================================================
// BgVramManager Unit Tests (BVM001 - BVM005)
// ===================================================================

test "BVM001: BgVramManager tileset deduplication in Charblock allocation" {
    var mgr = BgVramManager.init();

    const dummy_tiles1 = [_]Tile4bpp{@splat(0)};
    const dummy_pal1: [16]Bgr555 = @splat(Bgr555{});
    const ts1 = TileSet{
        .tiles = .{ .bpp4 = &dummy_tiles1 },
        .palette = &dummy_pal1,
    };

    const dummy_tiles2 = [_]Tile4bpp{@splat(1)};
    const dummy_pal2: [16]Bgr555 = @splat(Bgr555{});
    const ts2 = TileSet{
        .tiles = .{ .bpp4 = &dummy_tiles2 },
        .palette = &dummy_pal2,
    };

    const cbb1 = try mgr.allocateTileSet(&ts1);
    const cbb1_dup = try mgr.allocateTileSet(&ts1);
    try std.testing.expectEqual(cbb1, cbb1_dup);

    const cbb2 = try mgr.allocateTileSet(&ts2);
    try std.testing.expect(cbb1 != cbb2);

    const cbb2_dup = try mgr.allocateTileSet(&ts2);
    try std.testing.expectEqual(cbb2, cbb2_dup);
}

test "BVM002: BgVramManager screenblock allocation sizing and non-overlap" {
    try std.testing.expectEqual(@as(u6, 1), BgVramManager.screenblockCount(.size_32x32));
    try std.testing.expectEqual(@as(u6, 2), BgVramManager.screenblockCount(.size_64x32));
    try std.testing.expectEqual(@as(u6, 2), BgVramManager.screenblockCount(.size_32x64));
    try std.testing.expectEqual(@as(u6, 4), BgVramManager.screenblockCount(.size_64x64));

    var mgr = BgVramManager.init();

    const sbb1 = try mgr.allocateScreenblocks(.size_32x32);
    const sbb2 = try mgr.allocateScreenblocks(.size_64x32);
    const sbb3 = try mgr.allocateScreenblocks(.size_32x64);
    const sbb4 = try mgr.allocateScreenblocks(.size_64x64);

    try std.testing.expect(sbb2 >= sbb1 + 1);
    try std.testing.expect(sbb3 >= sbb2 + 2);
    try std.testing.expect(sbb4 >= sbb3 + 2);
    try std.testing.expect(@as(u6, sbb4) + 4 <= 32);
}

test "BVM003: BgVramManager memory overlap conflict prevention between CBB and SBB" {
    var mgr = BgVramManager.init();

    const dummy_tiles = [_]Tile4bpp{@splat(0)};
    const dummy_pal: [16]Bgr555 = @splat(Bgr555{});
    const ts = TileSet{
        .tiles = .{ .bpp4 = &dummy_tiles },
        .palette = &dummy_pal,
    };

    // Allocate CBB 0 for tileset (occupies SBB 0..7)
    const cbb = try mgr.allocateTileSet(&ts);
    try std.testing.expectEqual(@as(u2, 0), cbb);

    // Any subsequent screenblock allocation must NOT fall into SBB 0..7
    const sbb = try mgr.allocateScreenblocks(.size_32x32);
    try std.testing.expect(sbb >= 8);
}

test "BVM004: BgVramManager out-of-resource error reporting" {
    var mgr = BgVramManager.init();

    // 1. BG Layer channel exhaustion: max 4 layers (bg0..bg3)
    _ = try mgr.allocateBgId();
    _ = try mgr.allocateBgId();
    _ = try mgr.allocateBgId();
    _ = try mgr.allocateBgId();
    try std.testing.expectError(error.OutOfBgLayers, mgr.allocateBgId());

    // 2. Charblock exhaustion: max 4 CBBs
    const dummy_tiles1 = [_]Tile4bpp{@splat(0)};
    const dummy_tiles2 = [_]Tile4bpp{@splat(1)};
    const dummy_tiles3 = [_]Tile4bpp{@splat(2)};
    const dummy_tiles4 = [_]Tile4bpp{@splat(3)};
    const dummy_tiles5 = [_]Tile4bpp{@splat(4)};
    const dummy_pal: [16]Bgr555 = @splat(Bgr555{});
    const ts1 = TileSet{ .tiles = .{ .bpp4 = &dummy_tiles1 }, .palette = &dummy_pal };
    const ts2 = TileSet{ .tiles = .{ .bpp4 = &dummy_tiles2 }, .palette = &dummy_pal };
    const ts3 = TileSet{ .tiles = .{ .bpp4 = &dummy_tiles3 }, .palette = &dummy_pal };
    const ts4 = TileSet{ .tiles = .{ .bpp4 = &dummy_tiles4 }, .palette = &dummy_pal };
    const ts5 = TileSet{ .tiles = .{ .bpp4 = &dummy_tiles5 }, .palette = &dummy_pal };

    var mgr2 = BgVramManager.init();
    _ = try mgr2.allocateTileSet(&ts1);
    _ = try mgr2.allocateTileSet(&ts2);
    _ = try mgr2.allocateTileSet(&ts3);
    _ = try mgr2.allocateTileSet(&ts4);
    try std.testing.expectError(error.OutOfCharblocks, mgr2.allocateTileSet(&ts5));

    // 3. Screenblock exhaustion: 32 SBBs total.
    // Allocating 8 x 64x64 maps (8 * 4 = 32 SBBs) consumes all SBBs.
    var mgr3 = BgVramManager.init();
    for (0..8) |_| {
        _ = try mgr3.allocateScreenblocks(.size_64x64);
    }
    try std.testing.expectError(error.OutOfScreenblocks, mgr3.allocateScreenblocks(.size_32x32));
}

test "BVM005: BgVramManager manual placement and conflict rejection" {
    var mgr = BgVramManager.init();

    const dummy_tiles1 = [_]Tile4bpp{@splat(0)};
    const dummy_tiles2 = [_]Tile4bpp{@splat(1)};
    const dummy_pal: [16]Bgr555 = @splat(Bgr555{});
    const ts1 = TileSet{ .tiles = .{ .bpp4 = &dummy_tiles1 }, .palette = &dummy_pal };
    const ts2 = TileSet{ .tiles = .{ .bpp4 = &dummy_tiles2 }, .palette = &dummy_pal };

    // 1. Manual BG channel reservation and conflict
    try mgr.markBgIdOccupied(.bg2);
    try std.testing.expectError(error.Conflict, mgr.markBgIdOccupied(.bg2));
    const auto_bg = try mgr.allocateBgId();
    try std.testing.expect(auto_bg != .bg2);

    // 2. Manual Charblock reservation and conflict
    try mgr.markCharblockOccupied(0, &ts1);
    try std.testing.expectError(error.Conflict, mgr.markCharblockOccupied(0, &ts2));

    // 3. Manual Screenblock reservation in reserved CBB 0 (SBB 0..7) should conflict
    try std.testing.expectError(error.Conflict, mgr.markScreenblocksOccupied(0, 4));

    // 4. Valid manual Screenblock reservation
    try mgr.markScreenblocksOccupied(20, 4);
    try std.testing.expectError(error.Conflict, mgr.markScreenblocksOccupied(22, 2));
}

test "BVM006: BgVramManager.reset resets allocation states and clears hardware BG VRAM" {
    var mgr = BgVramManager.init();

    const dummy_tiles = [_]Tile4bpp{@splat(0)};
    const dummy_pal: [16]Bgr555 = @splat(Bgr555{});
    const ts = TileSet{
        .tiles = .{ .bpp4 = &dummy_tiles },
        .palette = &dummy_pal,
    };

    _ = try mgr.allocateTileSet(&ts);
    _ = try mgr.allocateScreenblocks(.size_64x64);
    _ = try mgr.allocateBgId();

    try std.testing.expect(mgr.cbb_occupied[0]);
    try std.testing.expect(mgr.sbb_occupied[0]);
    try std.testing.expect(mgr.bg_occupied[0]);

    hal.display.bg_vram_cleared = false;
    mgr.reset();

    for (0..4) |i| {
        try std.testing.expect(!mgr.cbb_occupied[i]);
        try std.testing.expect(mgr.cbb_tilesets[i] == null);
        try std.testing.expect(!mgr.bg_occupied[i]);
    }
    for (0..32) |i| {
        try std.testing.expect(!mgr.sbb_occupied[i]);
        try std.testing.expect(!mgr.sbb_map_occupied[i]);
    }
    try std.testing.expect(hal.display.bg_vram_cleared);
}

test "TLM009: TileMapLayer.init automated CBB/SBB allocation and dimension inference" {
    var mgr = BgVramManager.init();

    const dummy_tiles = [_]Tile4bpp{@splat(0)};
    const dummy_pal: [16]Bgr555 = @splat(Bgr555{});
    const ts = TileSet{
        .tiles = .{ .bpp4 = &dummy_tiles },
        .palette = &dummy_pal,
    };

    const entries_64x64: [4]ScreenEntry = @splat(ScreenEntry{});
    const layer_data_64x64 = MapLayerData{
        .width = 64,
        .height = 64,
        .tileset = &ts,
        .entries = &entries_64x64,
    };

    // Layer 1: 64x64 on BG3. Should infer size_64x64, allocate CBB 0, SBB 8..11, priority 3
    const layer1 = try TileMapLayer.init(&mgr, &layer_data_64x64, .{
        .bg_id = .bg3,
    });
    try std.testing.expectEqual(hal.display.BgId.bg3, layer1.bg_id);
    try std.testing.expectEqual(hal.display.BgSize.size_64x64, layer1.size);
    try std.testing.expectEqual(@as(u2, 0), layer1.charblock);
    try std.testing.expectEqual(@as(u5, 8), layer1.screenblock);
    try std.testing.expectEqual(@as(u2, 3), layer1.priority);

    // Layer 2: 32x32 on BG2 with shared tileset. Should deduplicate to CBB 0, allocate SBB 12, override priority 1
    const entries_32x32: [1]ScreenEntry = @splat(ScreenEntry{});
    const layer_data_32x32 = MapLayerData{
        .width = 32,
        .height = 32,
        .tileset = &ts,
        .entries = &entries_32x32,
    };

    const layer2 = try TileMapLayer.init(&mgr, &layer_data_32x32, .{
        .bg_id = .bg2,
        .priority = 1,
    });
    try std.testing.expectEqual(hal.display.BgId.bg2, layer2.bg_id);
    try std.testing.expectEqual(hal.display.BgSize.size_32x32, layer2.size);
    try std.testing.expectEqual(@as(u2, 0), layer2.charblock);
    try std.testing.expectEqual(@as(u5, 12), layer2.screenblock);
    try std.testing.expectEqual(@as(u2, 1), layer2.priority);
}

test "TLM010: TileMapLayer.init multiple layers with distinct tilesets and mutual non-overlap" {
    var mgr = BgVramManager.init();

    const dummy_tiles1 = [_]Tile4bpp{@splat(0)};
    const dummy_tiles2 = [_]Tile4bpp{@splat(1)};
    const dummy_pal: [16]Bgr555 = @splat(Bgr555{});
    const ts1 = TileSet{ .tiles = .{ .bpp4 = &dummy_tiles1 }, .palette = &dummy_pal };
    const ts2 = TileSet{ .tiles = .{ .bpp4 = &dummy_tiles2 }, .palette = &dummy_pal };

    // Layer 1: 64x32 (width=64, height=32, 2 SBBs) using ts1
    const entries_64x32: [2]ScreenEntry = @splat(ScreenEntry{});
    const data1 = MapLayerData{
        .width = 64,
        .height = 32,
        .tileset = &ts1,
        .entries = &entries_64x32,
    };
    const layer1 = try TileMapLayer.init(&mgr, &data1, .{ .bg_id = .bg0 });
    try std.testing.expectEqual(hal.display.BgSize.size_64x32, layer1.size);
    try std.testing.expectEqual(@as(u2, 0), layer1.charblock);
    try std.testing.expectEqual(@as(u5, 8), layer1.screenblock); // SBB 8..9

    // Layer 2: 32x64 (width=32, height=64, 2 SBBs) using ts2
    // CBB 1 (SBB 8..15) conflicts with SBB 8..9, so CBB 2 (SBB 16..23) is allocated!
    // Free SBBs are 10..15, so SBB 10..11 are allocated for layer2 screenblocks.
    const entries_32x64: [2]ScreenEntry = @splat(ScreenEntry{});
    const data2 = MapLayerData{
        .width = 32,
        .height = 64,
        .tileset = &ts2,
        .entries = &entries_32x64,
    };
    const layer2 = try TileMapLayer.init(&mgr, &data2, .{ .bg_id = .bg1 });
    try std.testing.expectEqual(hal.display.BgSize.size_32x64, layer2.size);
    try std.testing.expectEqual(@as(u2, 2), layer2.charblock);
    try std.testing.expectEqual(@as(u5, 10), layer2.screenblock);
}

test "TLM011: TileMapLayer.init BgId conflict rejection and manual placement override" {
    var mgr = BgVramManager.init();

    const dummy_tiles = [_]Tile4bpp{@splat(0)};
    const dummy_pal: [16]Bgr555 = @splat(Bgr555{});
    const ts = TileSet{ .tiles = .{ .bpp4 = &dummy_tiles }, .palette = &dummy_pal };
    const entries: [1]ScreenEntry = @splat(ScreenEntry{});
    const data = MapLayerData{
        .width = 32,
        .height = 32,
        .tileset = &ts,
        .entries = &entries,
    };

    // 1. First layer takes BG0
    _ = try TileMapLayer.init(&mgr, &data, .{ .bg_id = .bg0 });

    // 2. Second layer attempting to take BG0 must fail with Conflict
    try std.testing.expectError(error.Conflict, TileMapLayer.init(&mgr, &data, .{ .bg_id = .bg0 }));

    // 3. Manual placement override
    const manual_layer = try TileMapLayer.init(&mgr, &data, .{
        .bg_id = .bg1,
        .manual_placement = .{
            .charblock = 3,
            .screenblock = 28,
        },
    });
    try std.testing.expectEqual(@as(u2, 3), manual_layer.charblock);
    try std.testing.expectEqual(@as(u5, 28), manual_layer.screenblock);

    // 4. Overlapping manual placement must fail with Conflict
    try std.testing.expectError(error.Conflict, TileMapLayer.init(&mgr, &data, .{
        .bg_id = .bg2,
        .manual_placement = .{
            .charblock = 3,
            .screenblock = 28,
        },
    }));
}
