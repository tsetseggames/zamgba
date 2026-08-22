const hal = @import("zamgba-hal");
const Color = @import("color.zig").Color;
const physics = @import("physics/physics.zig");
const AABB = physics.AABB;
const Fixed24_8 = physics.Fixed24_8;
const PhysicsSprite = physics.PhysicsSprite;

pub const SpriteError = error{
    InvalidDimensions,
};

pub const ShapeSize = struct {
    shape: u16,
    size: u16,
};

/// Validates width and height against GBA hardware OBJ dimensions and returns Shape and Size bits.
pub fn getShapeAndSize(width: u32, height: u32) SpriteError!ShapeSize {
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

/// A high-level representation of a Sprite.
/// This structure holds engine-level data (x, y, scale, texture)
/// which is automatically translated to hardware `ObjAttr` format by the engine.
pub const Sprite = struct {
    x: i32,
    y: i32,
    width: u32,
    height: u32,

    /// Hardware tile index start
    tile_index: u16,

    /// Palette bank (0-15)
    palette_bank: u8,

    visible: bool = true,

    pub fn init(x: i32, y: i32, width: u32, height: u32) Sprite {
        return .{
            .x = x,
            .y = y,
            .width = width,
            .height = height,
            .tile_index = 0,
            .palette_bank = 0,
        };
    }

    /// Initializes a sprite and verifies its width and height are valid GBA sprite dimensions.
    pub fn initChecked(x: i32, y: i32, width: u32, height: u32) SpriteError!Sprite {
        _ = try getShapeAndSize(width, height);
        return init(x, y, width, height);
    }

    /// Automatically allocates and returns an AABB matching this Sprite's position and size.
    pub fn toAABB(self: *const Sprite) AABB {
        return AABB.init(
            Fixed24_8.fromInt(@intCast(@max(0, self.x))),
            Fixed24_8.fromInt(@intCast(@max(0, self.y))),
            @intCast(self.width),
            @intCast(self.height),
        );
    }

    /// Automatically wraps this Sprite into a PhysicsSprite with an allocated AABB.
    pub fn toPhysicsSprite(self: *const Sprite) PhysicsSprite {
        return PhysicsSprite.fromSprite(self);
    }

    /// Compiles the engine-level sprite into a hardware OAM attribute.
    pub fn toOamAttr(self: *const Sprite) hal.oam.ObjAttr {
        if (!self.visible) {
            return .{ .attr0 = 160, .attr1 = 0, .attr2 = 0, .fill = 0 };
        }

        const shape_size = getShapeAndSize(self.width, self.height) catch ShapeSize{
            .shape = hal.oam.Shape.SQUARE,
            .size = hal.oam.Size.SIZE_0,
        };

        const y_hw: u16 = @as(u16, @bitCast(@as(i16, @truncate(self.y)))) & 0x00FF;
        const x_hw: u16 = @as(u16, @bitCast(@as(i16, @truncate(self.x)))) & 0x01FF;

        const attr0: u16 = y_hw | (shape_size.shape << 14);
        const attr1: u16 = x_hw | (shape_size.size << 14);
        const attr2: u16 = (self.tile_index & 0x03FF) | (@as(u16, self.palette_bank & 0x0F) << 12);

        return .{
            .attr0 = attr0,
            .attr1 = attr1,
            .attr2 = attr2,
            .fill = 0,
        };
    }

    /// Fills custom VRAM and PALRAM memory buffers with solid color tile graphics and palette entry.
    pub fn fillSolidColorToBuffers(
        self: *const Sprite,
        vram_obj_base: []volatile u16,
        palram_obj_base: []volatile u16,
        color: anytype,
    ) SpriteError!void {
        _ = try getShapeAndSize(self.width, self.height);
        const bgr15 = colorToBgr555(color);

        const bank_offset = @as(usize, self.palette_bank & 0x0F) * 16;
        if (bank_offset + 1 < palram_obj_base.len) {
            palram_obj_base[bank_offset + 1] = bgr15;
        }

        const tile_word_offset = @as(usize, self.tile_index) * 16;
        const total_tiles = (self.width / 8) * (self.height / 8);
        const total_words = total_tiles * 16;

        if (tile_word_offset + total_words <= vram_obj_base.len) {
            for (0..total_words) |i| {
                vram_obj_base[tile_word_offset + i] = 0x1111;
            }
        }
    }

    /// Fills GBA OBJ VRAM and updates OBJ PALRAM with solid color tile graphics for this sprite.
    /// `color` can be an `engine.Color` or a 15-bit BGR555 `u16` (e.g. `hal.Color.RED`).
    pub fn fillSolidColor(self: *const Sprite, color: anytype) SpriteError!void {
        const obj_pal = hal.MemorySections.PALRAM + 256;
        const obj_vram = hal.MemorySections.VRAM + 32768;

        const pal_slice = obj_pal[0..256];
        const vram_slice = obj_vram[0..16384];

        try self.fillSolidColorToBuffers(vram_slice, pal_slice, color);
    }
};

test "initChecked validates dimensions" {
    const std = @import("std");

    const spr = try Sprite.initChecked(10, 20, 8, 8);
    try std.testing.expectEqual(@as(u32, 8), spr.width);
    try std.testing.expectEqual(@as(u32, 8), spr.height);

    try std.testing.expectError(SpriteError.InvalidDimensions, Sprite.initChecked(10, 20, 12, 12));
}

test "getShapeAndSize valid dimensions" {
    const std = @import("std");

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

test "getShapeAndSize invalid dimensions" {
    const std = @import("std");

    try std.testing.expectError(SpriteError.InvalidDimensions, getShapeAndSize(10, 10));
    try std.testing.expectError(SpriteError.InvalidDimensions, getShapeAndSize(8, 80));
    try std.testing.expectError(SpriteError.InvalidDimensions, getShapeAndSize(128, 128));
}

test "toOamAttr encoding" {
    const std = @import("std");

    var spr = Sprite.init(10, 20, 16, 32); // Vertical (shape 2, size 2)
    spr.tile_index = 4;
    spr.palette_bank = 2;

    const attr = spr.toOamAttr();
    // attr0: Y=20 (0x14), shape=2 -> (2 << 14) | 20 = 0x8014
    try std.testing.expectEqual(@as(u16, 0x8014), attr.attr0);
    // attr1: X=10 (0x0A), size=2 -> (2 << 14) | 10 = 0x800A
    try std.testing.expectEqual(@as(u16, 0x800A), attr.attr1);
    // attr2: tile_index=4, palette_bank=2 -> (2 << 12) | 4 = 0x2004
    try std.testing.expectEqual(@as(u16, 0x2004), attr.attr2);
}

test "Sprite toAABB and toPhysicsSprite helpers" {
    const std = @import("std");

    const spr = Sprite.init(10, 20, 16, 32);
    const box = spr.toAABB();
    try std.testing.expectEqual(@as(u32, 10), box.x.toInt());
    try std.testing.expectEqual(@as(u32, 20), box.y.toInt());
    try std.testing.expectEqual(@as(u16, 16), box.width);
    try std.testing.expectEqual(@as(u16, 32), box.height);

    const phys = spr.toPhysicsSprite();
    try std.testing.expectEqual(@as(u32, 10), phys.aabb.x.toInt());
}

test "colorToBgr555 supports u16, Color, and custom duck-typed structs" {
    const std = @import("std");

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

test "fillSolidColorToBuffers mock buffer" {
    const std = @import("std");

    var mock_vram: [1024]u16 = [_]u16{0} ** 1024;
    var mock_palram: [256]u16 = [_]u16{0} ** 256;

    var spr = Sprite.init(0, 0, 16, 8); // Horizontal (shape 1, size 0): 2 tiles = 32 u16 words
    spr.tile_index = 2;
    spr.palette_bank = 1;

    try spr.fillSolidColorToBuffers(&mock_vram, &mock_palram, Color.RED);

    // Palette bank 1, color index 1 -> offset (1 * 16 + 1) = 17
    try std.testing.expectEqual(hal.Color.RED, mock_palram[17]);

    // Tile index 2 -> offset (2 * 16) = 32 words. 2 tiles = 32 words.
    for (32..64) |i| {
        try std.testing.expectEqual(@as(u16, 0x1111), mock_vram[i]);
    }
    try std.testing.expectEqual(@as(u16, 0), mock_vram[31]);
    try std.testing.expectEqual(@as(u16, 0), mock_vram[64]);
}
