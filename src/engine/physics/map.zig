const std = @import("std");
const Fixed24_8 = @import("math.zig").Fixed24_8;
const AABB = @import("aabb.zig").AABB;

/// Standard GBA Text Background map dimensions.
pub const MapSize = enum(u2) {
    size_256x256 = 0, // 32x32 tiles (1 screen block)
    size_512x256 = 1, // 64x32 tiles (2 screen blocks horizontally)
    size_256x512 = 2, // 32x64 tiles (2 screen blocks vertically)
    size_512x512 = 3, // 64x64 tiles (4 screen blocks)

    pub fn pixelWidth(self: MapSize) u16 {
        return switch (self) {
            .size_256x256, .size_256x512 => 256,
            .size_512x256, .size_512x512 => 512,
        };
    }

    pub fn pixelHeight(self: MapSize) u16 {
        return switch (self) {
            .size_256x256, .size_512x256 => 256,
            .size_256x512, .size_512x512 => 512,
        };
    }

    pub fn tileWidth(self: MapSize) u16 {
        return self.pixelWidth() >> 3; // 8 pixels per tile
    }

    pub fn tileHeight(self: MapSize) u16 {
        return self.pixelHeight() >> 3; // 8 pixels per tile
    }
};

/// How to treat coordinates outside the map boundaries.
pub const OutOfBoundsBehavior = enum {
    solid, // Out of bounds is impassable/solid (default)
    empty, // Out of bounds is walkable/empty
};

/// Callback signature for streaming tile solid states with a context pointer.
/// Return true if the tile is solid/blocked, false if passable.
pub const ContextTileSolidFn = *const fn (ctx: ?*const anyopaque, tx: u16, ty: u16) bool;
pub const TileSolidFn = ContextTileSolidFn; // Alias for backward compatibility

/// Callback signature for stateless tile solid checks without a context pointer.
pub const NoContextTileSolidFn = *const fn (tx: u16, ty: u16) bool;
pub const SimpleTileSolidFn = NoContextTileSolidFn; // Alias for backward compatibility

/// Map collision detection supporting GBA Text Background sizes and streaming data access.
pub const CollisionMap = struct {
    size: MapSize,
    context: ?*const anyopaque = null,
    is_tile_solid_fn: ContextTileSolidFn,
    out_of_bounds: OutOfBoundsBehavior = .solid,

    /// Adapter for stateless function pointers without context.
    fn noContextAdapter(ctx: ?*const anyopaque, tx: u16, ty: u16) bool {
        const fn_ptr: NoContextTileSolidFn = @ptrCast(@alignCast(ctx.?));
        return fn_ptr(tx, ty);
    }

    /// Initialize a CollisionMap with an explicit context pointer (for stateful/instance data).
    pub fn initWithContext(
        size: MapSize,
        context: ?*const anyopaque,
        is_tile_solid_fn: ContextTileSolidFn,
        out_of_bounds: OutOfBoundsBehavior,
    ) CollisionMap {
        return .{
            .size = size,
            .context = context,
            .is_tile_solid_fn = is_tile_solid_fn,
            .out_of_bounds = out_of_bounds,
        };
    }

    /// Initialize a CollisionMap with a stateless function pointer (no context).
    pub fn init(
        size: MapSize,
        is_tile_solid_fn: NoContextTileSolidFn,
        out_of_bounds: OutOfBoundsBehavior,
    ) CollisionMap {
        return .{
            .size = size,
            .context = @ptrCast(is_tile_solid_fn),
            .is_tile_solid_fn = noContextAdapter,
            .out_of_bounds = out_of_bounds,
        };
    }

    /// Check if a tile at (tx, ty) is solid.
    pub fn isTileSolid(self: CollisionMap, tx: u16, ty: u16) bool {
        if (tx >= self.size.tileWidth() or ty >= self.size.tileHeight()) {
            return self.out_of_bounds == .solid;
        }
        return self.is_tile_solid_fn(self.context, tx, ty);
    }

    /// Check if an AABB collides with any solid tiles in the map.
    pub fn isColliding(self: CollisionMap, box: AABB) bool {
        if (box.width == 0 or box.height == 0) return false;

        const left_raw = box.x.raw;
        const right_raw = box.right().raw;
        const top_raw = box.y.raw;
        const bottom_raw = box.bottom().raw;

        const min_tx = @as(u16, @intCast(left_raw >> (Fixed24_8.fraction_bits + 3)));
        const max_tx = @as(u16, @intCast((right_raw - 1) >> (Fixed24_8.fraction_bits + 3)));
        const min_ty = @as(u16, @intCast(top_raw >> (Fixed24_8.fraction_bits + 3)));
        const max_ty = @as(u16, @intCast((bottom_raw - 1) >> (Fixed24_8.fraction_bits + 3)));

        var ty = min_ty;
        while (ty <= max_ty) : (ty += 1) {
            var tx = min_tx;
            while (tx <= max_tx) : (tx += 1) {
                if (self.isTileSolid(tx, ty)) {
                    return true;
                }
            }
        }
        return false;
    }

    /// Alias for isColliding.
    pub fn collidesWith(self: CollisionMap, box: AABB) bool {
        return self.isColliding(box);
    }

    /// Tile coordinate structure.
    pub const TilePos = struct {
        tx: u16,
        ty: u16,
    };

    /// Returns the first colliding solid tile's coordinates if any, or null if clear.
    pub fn getFirstCollidingTile(self: CollisionMap, box: AABB) ?TilePos {
        if (box.width == 0 or box.height == 0) return null;

        const left_raw = box.x.raw;
        const right_raw = box.right().raw;
        const top_raw = box.y.raw;
        const bottom_raw = box.bottom().raw;

        const min_tx = @as(u16, @intCast(left_raw >> (Fixed24_8.fraction_bits + 3)));
        const max_tx = @as(u16, @intCast((right_raw - 1) >> (Fixed24_8.fraction_bits + 3)));
        const min_ty = @as(u16, @intCast(top_raw >> (Fixed24_8.fraction_bits + 3)));
        const max_ty = @as(u16, @intCast((bottom_raw - 1) >> (Fixed24_8.fraction_bits + 3)));

        var ty = min_ty;
        while (ty <= max_ty) : (ty += 1) {
            var tx = min_tx;
            while (tx <= max_tx) : (tx += 1) {
                if (self.isTileSolid(tx, ty)) {
                    return .{ .tx = tx, .ty = ty };
                }
            }
        }
        return null;
    }
};

// Unit tests
test "MapSize pixel and tile dimensions" {
    const s256 = MapSize.size_256x256;
    try std.testing.expectEqual(@as(u16, 256), s256.pixelWidth());
    try std.testing.expectEqual(@as(u16, 256), s256.pixelHeight());
    try std.testing.expectEqual(@as(u16, 32), s256.tileWidth());
    try std.testing.expectEqual(@as(u16, 32), s256.tileHeight());

    const s512_256 = MapSize.size_512x256;
    try std.testing.expectEqual(@as(u16, 512), s512_256.pixelWidth());
    try std.testing.expectEqual(@as(u16, 256), s512_256.pixelHeight());
    try std.testing.expectEqual(@as(u16, 64), s512_256.tileWidth());
    try std.testing.expectEqual(@as(u16, 32), s512_256.tileHeight());

    const s256_512 = MapSize.size_256x512;
    try std.testing.expectEqual(@as(u16, 256), s256_512.pixelWidth());
    try std.testing.expectEqual(@as(u16, 512), s256_512.pixelHeight());
    try std.testing.expectEqual(@as(u16, 32), s256_512.tileWidth());
    try std.testing.expectEqual(@as(u16, 64), s256_512.tileHeight());

    const s512 = MapSize.size_512x512;
    try std.testing.expectEqual(@as(u16, 512), s512.pixelWidth());
    try std.testing.expectEqual(@as(u16, 512), s512.pixelHeight());
    try std.testing.expectEqual(@as(u16, 64), s512.tileWidth());
    try std.testing.expectEqual(@as(u16, 64), s512.tileHeight());
}

fn mockSolidAt2_2(tx: u16, ty: u16) bool {
    return tx == 2 and ty == 2;
}

test "CollisionMap simple callback collision check" {
    const map = CollisionMap.init(.size_256x256, mockSolidAt2_2, .solid);

    // Box at (0, 0, 8, 8) -> tile (0, 0) -> no collision
    const box_clear = AABB.fromInt(0, 0, 8, 8);
    try std.testing.expect(!map.isColliding(box_clear));

    // Box at (16, 16, 8, 8) -> tile (2, 2) -> collision! (16 / 8 = 2)
    const box_hit = AABB.fromInt(16, 16, 8, 8);
    try std.testing.expect(map.isColliding(box_hit));
    try std.testing.expect(map.collidesWith(box_hit));

    const tile = map.getFirstCollidingTile(box_hit);
    try std.testing.expect(tile != null);
    try std.testing.expectEqual(@as(u16, 2), tile.?.tx);
    try std.testing.expectEqual(@as(u16, 2), tile.?.ty);
}

test "CollisionMap sub-pixel tile overlap" {
    const map = CollisionMap.init(.size_256x256, mockSolidAt2_2, .solid);

    // Box at x=15.5, y=16 (width 8, height 8) -> spans x: [15.5, 23.5)
    // 15.5 is tile 1, 23.499 is tile 2 -> touches tile (2, 2) -> collision!
    const box_subpixel = AABB.init(Fixed24_8.fromFloat(15.5), Fixed24_8.fromInt(16), 8, 8);
    try std.testing.expect(map.isColliding(box_subpixel));

    // Box at x=8.0, y=16, width=8 -> spans x: [8.0, 16.0) -> only tile 1 (8..15) -> does NOT touch tile 2!
    const box_touch_edge = AABB.fromInt(8, 16, 8, 8);
    try std.testing.expect(!map.isColliding(box_touch_edge));
}

test "CollisionMap contextual streaming callback" {
    const CustomState = struct {
        wall_x: u16,
        wall_y: u16,

        fn isSolid(ctx: ?*const anyopaque, tx: u16, ty: u16) bool {
            const self: *const @This() = @ptrCast(@alignCast(ctx.?));
            return tx == self.wall_x and ty == self.wall_y;
        }
    };

    var state = CustomState{ .wall_x = 5, .wall_y = 5 };
    const map = CollisionMap.initWithContext(.size_512x512, &state, CustomState.isSolid, .solid);

    const box = AABB.fromInt(40, 40, 8, 8); // (40 / 8 = 5)
    try std.testing.expect(map.isColliding(box));

    // Dynamically change streamed state
    state.wall_x = 10;
    try std.testing.expect(!map.isColliding(box));
}

test "CollisionMap out of bounds behavior" {
    // Map with out_of_bounds = .solid
    const map_solid = CollisionMap.init(.size_256x256, mockSolidAt2_2, .solid);
    // Box outside map (x=300)
    const box_oob = AABB.fromInt(300, 0, 8, 8);
    try std.testing.expect(map_solid.isColliding(box_oob));

    // Map with out_of_bounds = .empty
    const map_empty = CollisionMap.init(.size_256x256, mockSolidAt2_2, .empty);
    try std.testing.expect(!map_empty.isColliding(box_oob));
}
