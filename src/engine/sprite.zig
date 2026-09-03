const std = @import("std");
const hal = @import("zamgba-hal");
const Color = @import("color.zig").Color;
const physics = @import("physics/physics.zig");
const AABB = physics.AABB;
const Fixed24_8 = physics.Fixed24_8;
const CollisionMap = physics.CollisionMap;
const CollisionMask = physics.CollisionMask;
const Collision = physics.Collision;

pub const SpriteError = error{
    InvalidDimensions,
    Unimplemented,
};

pub const BppMode = enum(u1) {
    bpp4 = 0,
    bpp8 = 1,
};

pub const AnimationDirection = enum(u2) {
    forward = 0,
    reverse = 1,
    pingpong = 2,
};

pub const AnimationTag = struct {
    name: []const u8,
    from_frame: u16,
    to_frame: u16,
    direction: AnimationDirection = .forward,
};

pub const SpriteSheet = struct {
    bpp: BppMode,
    width: u16,
    height: u16,
    tile_count_per_frame: u16,
    frame_count: u16,
    palette: ?[]const u16 = null,
    tiles: []const u8,
    durations_ms: []const u16,
    tags: []const AnimationTag,
};

pub const ShapeSize = struct {
    shape: u16,
    size: u16,
};

/// Validates width and height against GBA hardware OBJ dimensions and returns Shape and Size bits.
pub fn getShapeAndSize(width: u16, height: u16) SpriteError!ShapeSize {
    if (width == 8 and height == 8) return .{ .shape = hal.oam.Shape.SQUARE, .size = hal.oam.Size.SIZE_0 };
    if (width == 16 and height == 16) return .{ .shape = hal.oam.Shape.SQUARE, .size = hal.oam.Size.SIZE_1 };
    if (width == 32 and height == 32) return .{ .shape = hal.oam.Shape.SQUARE, .size = hal.oam.Size.SIZE_2 };
    if (width == 64 and height == 64) return .{ .shape = hal.oam.Shape.SQUARE, .size = hal.oam.Size.SIZE_3 };

    if (width == 16 and height == 8) return .{ .shape = hal.oam.Shape.HORIZONTAL, .size = hal.oam.Size.SIZE_0 };
    if (width == 32 and height == 8) return .{ .shape = hal.oam.Shape.HORIZONTAL, .size = hal.oam.Size.SIZE_1 };
    if (width == 32 and height == 16) return .{ .shape = hal.oam.Shape.HORIZONTAL, .size = hal.oam.Size.SIZE_2 };
    if (width == 64 and height == 32) return .{ .shape = hal.oam.Shape.HORIZONTAL, .size = hal.oam.Size.SIZE_3 };

    if (width == 8 and height == 16) return .{ .shape = hal.oam.Shape.VERTICAL, .size = hal.oam.Size.SIZE_0 };
    if (width == 8 and height == 32) return .{ .shape = hal.oam.Shape.VERTICAL, .size = hal.oam.Size.SIZE_1 };
    if (width == 16 and height == 32) return .{ .shape = hal.oam.Shape.VERTICAL, .size = hal.oam.Size.SIZE_2 };
    if (width == 32 and height == 64) return .{ .shape = hal.oam.Shape.VERTICAL, .size = hal.oam.Size.SIZE_3 };

    return SpriteError.InvalidDimensions;
}

fn colorToBgr555(color: anytype) u16 {
    const T = @TypeOf(color);
    if (T == u16) {
        return color;
    } else if (T == Color or T == *const Color) {
        return color.toBgr555();
    } else if (@hasDecl(T, "toBgr555")) {
        return color.toBgr555();
    } else {
        @compileError("Expected u16 (BGR555) or engine.Color type.");
    }
}

/// Result of collision check during movement.
pub const CollisionResult = struct {
    collided_x: bool = false,
    collided_y: bool = false,

    pub fn hasCollided(self: CollisionResult) bool {
        return self.collided_x or self.collided_y;
    }
};

/// Represents a static GBA tile attribute in VRAM.
/// Can be used as a Sprite tile source or as a Background Screen Entry.
pub const StaticTile = struct {
    tile_index: u16 = 0,
    palette_bank: u4 = 0,
    bpp: BppMode = .bpp4,

    /// Converts the static tile into a GBA Background Screen Entry (16-bit text BG map cell).
    pub inline fn toScreenEntry(self: StaticTile, h_flip: bool, v_flip: bool) u16 {
        const h_bit: u16 = if (h_flip) (1 << 10) else 0;
        const v_bit: u16 = if (v_flip) (1 << 11) else 0;
        return (self.tile_index & 0x03FF) | h_bit | v_bit | (@as(u16, self.palette_bank) << 12);
    }
};

/// Represents a tile capable of filling solid colors into OBJ VRAM / PALRAM.
pub const ColorFillTile = struct {
    tile_index: u16 = 0,
    palette_bank: u4 = 0,
    bpp: BppMode = .bpp4,

    pub inline fn getTile(self: ColorFillTile) StaticTile {
        return .{
            .tile_index = self.tile_index,
            .palette_bank = self.palette_bank,
            .bpp = self.bpp,
        };
    }

    /// Fills custom VRAM and PALRAM memory buffers with solid color tile graphics and palette entry.
    pub fn fillSolidColorToBuffers(
        self: ColorFillTile,
        width: u16,
        height: u16,
        vram_obj_base: []volatile u16,
        palram_obj_base: []volatile u16,
        color: anytype,
    ) SpriteError!void {
        _ = self;
        _ = width;
        _ = height;
        _ = vram_obj_base;
        _ = palram_obj_base;
        _ = color;
        return error.Unimplemented;
    }

    /// Fills GBA OBJ VRAM and updates OBJ PALRAM with solid color tile graphics.
    pub fn fillSolidColor(self: ColorFillTile, width: u16, height: u16, color: anytype) SpriteError!void {
        _ = self;
        _ = width;
        _ = height;
        _ = color;
        return error.Unimplemented;
    }
};

/// High-level orthogonal Sprite: encapsulates AABB, velocity, collision layers, flips, and visibility.
pub const Sprite = struct {
    aabb: AABB,
    velocity_x: Fixed24_8 = Fixed24_8.zero,
    velocity_y: Fixed24_8 = Fixed24_8.zero,

    /// 16-bit collision layer (self classification)
    layer: CollisionMask = Collision.NONE,

    /// 16-bit collision mask (layers this sprite interacts with)
    mask: CollisionMask = Collision.ALL,

    /// Horizontal flip (face left / right)
    h_flip: bool = false,

    /// Vertical flip
    v_flip: bool = false,

    visible: bool = true,

    /// Initialize a Sprite with integer pixel coordinates and dimensions.
    pub fn init(x: i32, y: i32, width: u16, height: u16) Sprite {
        return .{
            .aabb = AABB.fromInt(x, y, width, height),
        };
    }

    /// Initialize a Sprite with Fixed24_8 sub-pixel coordinates.
    pub fn initFixed(x: Fixed24_8, y: Fixed24_8, width: u16, height: u16) Sprite {
        return .{
            .aabb = AABB.init(x, y, width, height),
        };
    }

    /// Initializes a sprite and verifies its width and height are valid GBA sprite dimensions.
    pub fn initChecked(x: i32, y: i32, width: u16, height: u16) SpriteError!Sprite {
        _ = try getShapeAndSize(width, height);
        return init(x, y, width, height);
    }

    /// Check if this sprite can interact with another sprite based on 16-bit layer and mask filtering.
    pub inline fn canCollideWith(self: *const Sprite, other: *const Sprite) bool {
        return Collision.canInteract(self.layer, self.mask, other.layer, other.mask);
    }

    /// Move the sprite by its current velocity, checking and resolving collisions
    /// independently on X and Y axes against the CollisionMap.
    pub fn moveAndCollide(self: *Sprite, collision_map: CollisionMap) CollisionResult {
        var result = CollisionResult{};

        // 1. Move along X axis
        if (self.velocity_x.raw != 0) {
            const next_x = self.aabb.x.add(self.velocity_x);
            const test_box_x = AABB.init(next_x, self.aabb.y, self.aabb.width, self.aabb.height);

            if (next_x.raw < 0 or collision_map.isColliding(test_box_x)) {
                result.collided_x = true;
                self.velocity_x = Fixed24_8.zero;
            } else {
                self.aabb.x = next_x;
            }
        }

        // 2. Move along Y axis
        if (self.velocity_y.raw != 0) {
            const next_y = self.aabb.y.add(self.velocity_y);
            const test_box_y = AABB.init(self.aabb.x, next_y, self.aabb.width, self.aabb.height);

            if (next_y.raw < 0 or collision_map.isColliding(test_box_y)) {
                result.collided_y = true;
                self.velocity_y = Fixed24_8.zero;
            } else {
                self.aabb.y = next_y;
            }
        }

        return result;
    }

    /// Compiles the engine-level sprite and provided static tile into a hardware OAM attribute.
    pub fn toOamAttr(self: *const Sprite, tile: StaticTile) hal.oam.ObjAttr {
        if (!self.visible) {
            return .{ .attr0 = 160, .attr1 = 0, .attr2 = 0, .fill = 0 };
        }

        const shape_size = getShapeAndSize(self.aabb.width, self.aabb.height) catch ShapeSize{
            .shape = hal.oam.Shape.SQUARE,
            .size = hal.oam.Size.SIZE_0,
        };

        const y_val: i32 = @intCast(self.aabb.y.toInt());
        const x_val: i32 = @intCast(self.aabb.x.toInt());

        const y_hw: u16 = @as(u16, @bitCast(@as(i16, @truncate(y_val)))) & 0x00FF;
        const x_hw: u16 = @as(u16, @bitCast(@as(i16, @truncate(x_val)))) & 0x01FF;

        const bpp_bit: u16 = if (tile.bpp == .bpp8) (1 << 13) else 0;
        const h_flip_bit: u16 = if (self.h_flip) (1 << 12) else 0;
        const v_flip_bit: u16 = if (self.v_flip) (1 << 13) else 0;

        const attr0: u16 = y_hw | (shape_size.shape << 14) | bpp_bit;
        const attr1: u16 = x_hw | (shape_size.size << 14) | h_flip_bit | v_flip_bit;
        const attr2: u16 = (tile.tile_index & 0x03FF) | (@as(u16, tile.palette_bank & 0x0F) << 12);

        return .{
            .attr0 = attr0,
            .attr1 = attr1,
            .attr2 = attr2,
            .fill = 0,
        };
    }
};

/// Composite structure: Combines a Sprite with a StaticTile.
pub const StaticSprite = struct {
    sprite: Sprite,
    tile: StaticTile = .{},

    pub fn init(x: i32, y: i32, width: u16, height: u16, tile: StaticTile) StaticSprite {
        return .{
            .sprite = Sprite.init(x, y, width, height),
            .tile = tile,
        };
    }

    pub fn toOamAttr(self: *const StaticSprite) hal.oam.ObjAttr {
        return self.sprite.toOamAttr(self.tile);
    }
};

/// Composite structure: Combines a Sprite with a ColorFillTile.
pub const ColorFillSprite = struct {
    sprite: Sprite,
    tile: ColorFillTile = .{},

    pub fn init(x: i32, y: i32, width: u16, height: u16, tile: ColorFillTile) ColorFillSprite {
        return .{
            .sprite = Sprite.init(x, y, width, height),
            .tile = tile,
        };
    }

    pub fn toOamAttr(self: *const ColorFillSprite) hal.oam.ObjAttr {
        return self.sprite.toOamAttr(self.tile.getTile());
    }

    pub fn fillSolidColor(self: *const ColorFillSprite, color: anytype) SpriteError!void {
        return self.tile.fillSolidColor(self.sprite.aabb.width, self.sprite.aabb.height, color);
    }
};

test "SPR001: initChecked validates dimensions" {
    const spr = try Sprite.initChecked(10, 20, 8, 8);
    try std.testing.expectEqual(@as(u16, 8), spr.aabb.width);
    try std.testing.expectEqual(@as(u16, 8), spr.aabb.height);

    try std.testing.expectError(SpriteError.InvalidDimensions, Sprite.initChecked(10, 20, 12, 12));
}

test "SPR002: getShapeAndSize valid dimensions" {
    // Square
    try std.testing.expectEqual(ShapeSize{ .shape = hal.oam.Shape.SQUARE, .size = hal.oam.Size.SIZE_0 }, try getShapeAndSize(8, 8));
    try std.testing.expectEqual(ShapeSize{ .shape = hal.oam.Shape.SQUARE, .size = hal.oam.Size.SIZE_1 }, try getShapeAndSize(16, 16));
    try std.testing.expectEqual(ShapeSize{ .shape = hal.oam.Shape.SQUARE, .size = hal.oam.Size.SIZE_2 }, try getShapeAndSize(32, 32));
    try std.testing.expectEqual(ShapeSize{ .shape = hal.oam.Shape.SQUARE, .size = hal.oam.Size.SIZE_3 }, try getShapeAndSize(64, 64));

    // Horizontal
    try std.testing.expectEqual(ShapeSize{ .shape = hal.oam.Shape.HORIZONTAL, .size = hal.oam.Size.SIZE_0 }, try getShapeAndSize(16, 8));
    try std.testing.expectEqual(ShapeSize{ .shape = hal.oam.Shape.HORIZONTAL, .size = hal.oam.Size.SIZE_1 }, try getShapeAndSize(32, 8));
    try std.testing.expectEqual(ShapeSize{ .shape = hal.oam.Shape.HORIZONTAL, .size = hal.oam.Size.SIZE_2 }, try getShapeAndSize(32, 16));
    try std.testing.expectEqual(ShapeSize{ .shape = hal.oam.Shape.HORIZONTAL, .size = hal.oam.Size.SIZE_3 }, try getShapeAndSize(64, 32));

    // Vertical
    try std.testing.expectEqual(ShapeSize{ .shape = hal.oam.Shape.VERTICAL, .size = hal.oam.Size.SIZE_0 }, try getShapeAndSize(8, 16));
    try std.testing.expectEqual(ShapeSize{ .shape = hal.oam.Shape.VERTICAL, .size = hal.oam.Size.SIZE_1 }, try getShapeAndSize(8, 32));
    try std.testing.expectEqual(ShapeSize{ .shape = hal.oam.Shape.VERTICAL, .size = hal.oam.Size.SIZE_2 }, try getShapeAndSize(16, 32));
    try std.testing.expectEqual(ShapeSize{ .shape = hal.oam.Shape.VERTICAL, .size = hal.oam.Size.SIZE_3 }, try getShapeAndSize(32, 64));
}

test "SPR003: getShapeAndSize invalid dimensions" {
    try std.testing.expectError(SpriteError.InvalidDimensions, getShapeAndSize(10, 10));
    try std.testing.expectError(SpriteError.InvalidDimensions, getShapeAndSize(8, 80));
    try std.testing.expectError(SpriteError.InvalidDimensions, getShapeAndSize(128, 128));
}

test "SPR004: toOamAttr encoding with StaticTile" {
    var spr = Sprite.init(10, 20, 16, 32); // Vertical (shape 2, size 2)
    const tile = StaticTile{ .tile_index = 4, .palette_bank = 2, .bpp = .bpp4 };

    const attr = spr.toOamAttr(tile);
    // attr0: Y=20 (0x14), shape=2 -> (2 << 14) | 20 = 0x8014
    try std.testing.expectEqual(@as(u16, 0x8014), attr.attr0);
    // attr1: X=10 (0x0A), size=2 -> (2 << 14) | 10 = 0x800A
    try std.testing.expectEqual(@as(u16, 0x800A), attr.attr1);
    // attr2: tile_index=4, palette_bank=2 -> (2 << 12) | 4 = 0x2004
    try std.testing.expectEqual(@as(u16, 0x2004), attr.attr2);
}

test "SPR005: colorToBgr555 supports u16, Color, and custom duck-typed structs" {
    // 1. u16 (e.g., hal.Color)
    const raw_color: u16 = hal.Color.RED;
    try std.testing.expectEqual(hal.Color.RED, colorToBgr555(raw_color));

    // 2. engine.Color struct value
    const eng_color = Color.RED;
    try std.testing.expectEqual(hal.Color.RED, colorToBgr555(eng_color));

    // 3. Custom struct with a toBgr555() method (duck typing)
    const CustomColor = struct {
        pub fn toBgr555(self: @This()) u16 {
            _ = self;
            return 0x1234;
        }
    };
    const custom = CustomColor{};
    try std.testing.expectEqual(@as(u16, 0x1234), colorToBgr555(custom));
}

test "SPR006: ColorFillTile fillSolidColorToBuffers mock buffer" {
    var mock_vram: [1024]u16 = [_]u16{0} ** 1024;
    var mock_palram: [256]u16 = [_]u16{0} ** 256;

    const fill_tile = ColorFillTile{ .tile_index = 2, .palette_bank = 1 };

    // Stub returns error.Unimplemented in Red Phase
    try fill_tile.fillSolidColorToBuffers(16, 8, &mock_vram, &mock_palram, Color.RED);

    // Palette bank 1, color index 1 -> offset (1 * 16 + 1) = 17
    try std.testing.expectEqual(hal.Color.RED, mock_palram[17]);

    // Tile index 2 -> offset (2 * 16) = 32 words. 2 tiles = 32 words.
    for (32..64) |i| {
        try std.testing.expectEqual(@as(u16, 0x1111), mock_vram[i]);
    }
    try std.testing.expectEqual(@as(u16, 0), mock_vram[31]);
    try std.testing.expectEqual(@as(u16, 0), mock_vram[64]);
}

fn mockWallAtTile3_0(tx: u16, ty: u16) bool {
    return tx == 3 and ty == 0;
}

test "SPR007: Sprite moveAndCollide stops against map obstacles" {
    const map = CollisionMap.init(.size_256x256, mockWallAtTile3_0, .solid);

    // Sprite at x=8, y=0, size 8x8 (tile 1, 0)
    var spr = Sprite.init(8, 0, 8, 8);
    spr.velocity_x = Fixed24_8.fromInt(8); // Move right by 8 pixels per step

    // Step 1: Moves from x=8 to x=16 (tile 2) -> Clear
    var res = spr.moveAndCollide(map);
    try std.testing.expect(!res.hasCollided());
    try std.testing.expectEqual(@as(i32, 16), spr.aabb.x.toInt());

    // Step 2: Next step would move from x=16 to x=24 (tile 3, which is solid) -> Collision!
    res = spr.moveAndCollide(map);
    try std.testing.expect(res.collided_x);
    try std.testing.expect(!res.collided_y);
    try std.testing.expect(res.hasCollided());
    try std.testing.expectEqual(@as(i32, 16), spr.aabb.x.toInt());
    try std.testing.expectEqual(Fixed24_8.zero.raw, spr.velocity_x.raw);

    // Step 3: Test negative velocity (moving left)
    spr.velocity_x = Fixed24_8.fromInt(-8);
    res = spr.moveAndCollide(map);
    try std.testing.expect(!res.hasCollided());
    try std.testing.expectEqual(@as(i32, 8), spr.aabb.x.toInt());
}

test "SPR008: Sprite collision via AABB" {
    const spr1 = Sprite.init(10, 10, 16, 16);
    const spr2 = Sprite.init(20, 20, 16, 16);
    const spr3 = Sprite.init(50, 50, 16, 16);

    try std.testing.expect(spr1.aabb.isColliding(spr2.aabb));
    try std.testing.expect(spr1.aabb.collidesWith(spr2.aabb));
    try std.testing.expect(!spr1.aabb.isColliding(spr3.aabb));
}

test "SPR009: Sprite layer and mask filtering" {
    var player = Sprite.init(0, 0, 16, 16);
    player.layer = Collision.layer(0); // Layer 0: Player
    player.mask = Collision.layer(1); // Mask: Only Enemy (Layer 1)

    var enemy = Sprite.init(0, 0, 16, 16);
    enemy.layer = Collision.layer(1); // Layer 1: Enemy
    enemy.mask = Collision.layer(0); // Mask: Only Player (Layer 0)

    var item = Sprite.init(0, 0, 8, 8);
    item.layer = Collision.layer(2); // Layer 2: Item
    item.mask = Collision.layer(3); // Mask: Layer 3

    // Player and Enemy can collide
    try std.testing.expect(player.canCollideWith(&enemy));
    try std.testing.expect(enemy.canCollideWith(&player));

    // Player and Item cannot collide (masks do not match)
    try std.testing.expect(!player.canCollideWith(&item));
    try std.testing.expect(!item.canCollideWith(&player));
}

test "SPR010: toOamAttr horizontal and vertical flip encoding" {
    var spr = Sprite.init(10, 20, 16, 16);
    spr.h_flip = true;
    spr.v_flip = true;
    const tile = StaticTile{ .tile_index = 0, .palette_bank = 0, .bpp = .bpp4 };

    const attr = spr.toOamAttr(tile);
    const expected_attr1: u16 = 10 | (1 << 14) | (1 << 12) | (1 << 13);
    try std.testing.expectEqual(expected_attr1, attr.attr1);
}

test "SPR011: toOamAttr 8-bpp color mode encoding" {
    const spr = Sprite.init(10, 20, 32, 32);
    const tile = StaticTile{ .tile_index = 0, .palette_bank = 0, .bpp = .bpp8 };

    const attr = spr.toOamAttr(tile);
    const expected_attr0: u16 = 20 | (1 << 13);
    try std.testing.expectEqual(expected_attr0, attr.attr0);
}

test "SPR012: StaticTile toScreenEntry text background encoding" {
    const tile = StaticTile{
        .tile_index = 105,
        .palette_bank = 3,
        .bpp = .bpp4,
    };

    // No flip: (3 << 12) | 105 = 0x3069
    try std.testing.expectEqual(@as(u16, 0x3069), tile.toScreenEntry(false, false));

    // H-flip: bit 10
    try std.testing.expectEqual(@as(u16, 0x3469), tile.toScreenEntry(true, false));

    // V-flip: bit 11
    try std.testing.expectEqual(@as(u16, 0x3869), tile.toScreenEntry(false, true));

    // Both flips: bit 10 and 11
    try std.testing.expectEqual(@as(u16, 0x3C69), tile.toScreenEntry(true, true));
}

test "SPR013: StaticSprite composition and toOamAttr output" {
    const static_spr = StaticSprite.init(15, 25, 32, 16, .{
        .tile_index = 12,
        .palette_bank = 4,
        .bpp = .bpp4,
    });

    const attr = static_spr.toOamAttr();
    // 32x16 Horizontal: shape=1, size=2 -> attr0 has (1 << 14) | 25, attr1 has (2 << 14) | 15
    try std.testing.expectEqual(@as(u16, (1 << 14) | 25), attr.attr0);
    try std.testing.expectEqual(@as(u16, (2 << 14) | 15), attr.attr1);
    try std.testing.expectEqual(@as(u16, (4 << 12) | 12), attr.attr2);
}

test "SPR014: ColorFillSprite composition and getTile" {
    const solid_spr = ColorFillSprite.init(5, 10, 8, 8, .{
        .tile_index = 1,
        .palette_bank = 2,
    });

    const tile = solid_spr.tile.getTile();
    try std.testing.expectEqual(@as(u16, 1), tile.tile_index);
    try std.testing.expectEqual(@as(u4, 2), tile.palette_bank);

    const attr = solid_spr.toOamAttr();
    try std.testing.expectEqual(@as(u16, 10), attr.attr0);
    try std.testing.expectEqual(@as(u16, 5), attr.attr1);
    try std.testing.expectEqual(@as(u16, (2 << 12) | 1), attr.attr2);
}
