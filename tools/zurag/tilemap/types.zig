const std = @import("std");
const engine = @import("zamgba-engine");

/// GBA hardware and engine tilemap constraints
pub const Limits = struct {
    pub const MAX_BG_LAYERS: usize = 4;
    pub const MAX_MAP_DIMENSION_PX: u32 = 4096;
    pub const TILE_SIZE_PX: u32 = 8;
    /// Maximum number of IntGrid values/layers, bounded by GBA engine's 16-bit CollisionMask
    pub const MAX_INTGRID_VALUE: i64 = @as(i64, @intCast(engine.physics.COLLISION_MASK_BITS));
};

pub const TilemapFormat = enum {
    auto,
    ldtk,
};

pub const TilemapError = error{
    TooManyLayers,
    InvalidMapDimensions,
    MapSizeExceedsLimit,
    IntGridValueOutOfRange,
    UnsupportedLayerType,
    UnsupportedGridSize,
    InvalidTilesetDefinition,
    MissingLevelData,
    InvalidJson,
    InvalidJsonSchema,
    UnsupportedJsonFormat,
    OutOfMemory,
    Unimplemented,
};

/// 8x8 Hardware tile placement entry
pub const ParsedTileEntry = struct {
    tile_id: u16,
    x: u16,
    y: u16,
    h_flip: bool,
    v_flip: bool,
    alpha: f32 = 1.0,
};

/// Entity instance extracted from LDtk
pub const ParsedEntity = struct {
    identifier: []const u8,
    x: i32,
    y: i32,
    width: u32,
    height: u32,
    custom_fields_json: ?[]const u8 = null,
};

pub const LayerType = enum {
    int_grid,
    tiles,
    entities,
    auto_layer,
};

/// Extracted tilemap layer representation
pub const ParsedLayer = struct {
    identifier: []const u8,
    layer_type: LayerType,
    grid_size: u32,
    c_wid: u32,
    c_hei: u32,
    tileset_rel_path: ?[]const u8 = null,
    tiles: []const ParsedTileEntry = &.{},
    collision_masks: ?[]const u16 = null,
    entities: []const ParsedEntity = &.{},
    has_alpha_warning: bool = false,
};

/// Extracted level container representation
pub const ParsedLevel = struct {
    identifier: []const u8,
    world_x: i32,
    world_y: i32,
    px_wid: u32,
    px_hei: u32,
    layers: []const ParsedLayer = &.{},
};

/// Unified tilemap project domain model
pub const TilemapMetadata = struct {
    arena: std.heap.ArenaAllocator,
    levels: []const ParsedLevel,

    pub fn deinit(self: *TilemapMetadata) void {
        self.arena.deinit();
    }
};
