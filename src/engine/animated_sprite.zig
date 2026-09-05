const std = @import("std");
const hal = @import("zamgba-hal");
const gfx2d = @import("gfx2d/gfx2d.zig");
const Sprite = @import("sprite.zig").Sprite;
const SpriteSheet = gfx2d.SpriteSheet;
const AnimatedTiles = gfx2d.AnimatedTiles;
const AnimationMode = gfx2d.AnimationMode;
const AnimationTag = gfx2d.AnimationTag;
const TileError = gfx2d.TileError;

/// Composite structure: Combines a spatial Sprite with AnimatedTiles.
pub const AnimatedSprite = struct {
    sprite: Sprite,
    tiles: AnimatedTiles,

    /// Creates and initializes an animated sprite from a converted SpriteSheet and position.
    pub fn init(sheet: *const SpriteSheet, mode: AnimationMode, x: i32, y: i32) TileError!AnimatedSprite {
        const tiles = try AnimatedTiles.init(sheet, mode);
        const spr = Sprite.init(x, y, sheet.width, sheet.height);
        return .{
            .sprite = spr,
            .tiles = tiles,
        };
    }

    /// Releases any allocated VRAM slot back to the VramAllocator.
    pub fn deinit(self: *AnimatedSprite) void {
        self.tiles.deinit();
    }

    /// Selects an animation tag by name (e.g. "fly", "run", "idle").
    pub fn setAnimation(self: *AnimatedSprite, tag_name: []const u8) bool {
        return self.tiles.setAnimation(tag_name);
    }

    /// Selects an animation tag by index without runtime string lookup.
    pub fn setAnimationByIndex(self: *AnimatedSprite, tag_index: usize) bool {
        return self.tiles.setAnimationByIndex(tag_index);
    }

    /// Directly sets the current frame index.
    pub fn setFrame(self: *AnimatedSprite, frame_index: usize) void {
        self.tiles.setFrame(frame_index);
    }

    /// Advances the animation frame timer by 1 tick (~16.6ms at 60Hz).
    pub fn update(self: *AnimatedSprite) void {
        self.tiles.update();
    }

    /// Compiles into a GBA hardware OAM attribute.
    pub fn toOamAttr(self: *const AnimatedSprite) hal.oam.ObjAttr {
        return self.sprite.toOamAttr(self.tiles.getTile());
    }

    /// Accesses the underlying Sprite component.
    pub fn getSprite(self: *AnimatedSprite) *Sprite {
        return &self.sprite;
    }
};

test "ANI007: AnimatedSprite composition and toOamAttr output" {
    const dummy_sheet = SpriteSheet{
        .bpp = .bpp4,
        .width = 16,
        .height = 16,
        .tile_count_per_frame = 4,
        .frame_count = 2,
        .tiles = &[_]u8{0} ** 256,
        .durations_ms = &[_]u16{ 100, 100 },
        .tags = &[_]AnimationTag{},
    };

    var anim_spr = try AnimatedSprite.init(&dummy_sheet, .static, 20, 30);
    defer anim_spr.deinit();

    const spr = anim_spr.getSprite();
    spr.h_flip = true;

    const attr = anim_spr.toOamAttr();
    try std.testing.expectEqual(@as(u16, 30), attr.attr0 & 0x00FF);
    try std.testing.expectEqual(@as(u16, 20 | (1 << 14) | (1 << 12)), attr.attr1);
}
