const std = @import("std");
const hal = @import("zamgba-hal");
const gfx2d = @import("gfx2d/gfx2d.zig");
const sprite_mod = @import("sprite.zig");
const Sprite = sprite_mod.Sprite;
const StaticTile = gfx2d.StaticTile;
const SpriteSheet = gfx2d.SpriteSheet;
const BppMode = gfx2d.BppMode;
const AnimationDirection = gfx2d.AnimationDirection;
const AnimationTag = gfx2d.AnimationTag;
const TileError = gfx2d.TileError;

// Re-export AnimatedTiles and AnimationMode for compatibility
pub const AnimatedSpriteError = TileError;
pub const AnimatedTiles = gfx2d.AnimatedTiles;
pub const AnimationMode = gfx2d.AnimationMode;

/// Composite structure: Combines a spatial Sprite with AnimatedTiles.
pub const AnimatedSprite = struct {
    sprite: Sprite,
    tiles: AnimatedTiles,

    /// Creates and initializes an animated sprite from a converted SpriteSheet and position.
    pub fn init(sheet: *const SpriteSheet, mode: AnimationMode, x: i32, y: i32) AnimatedSpriteError!AnimatedSprite {
        _ = sheet;
        _ = mode;
        _ = x;
        _ = y;
        return error.Unimplemented;
    }

    /// Releases any allocated VRAM slot back to the VramAllocator.
    pub fn deinit(self: *AnimatedSprite) void {
        self.tiles.deinit();
    }

    /// Selects an animation tag by name (e.g. "fly", "run", "idle").
    pub fn play(self: *AnimatedSprite, tag_name: []const u8) bool {
        return self.tiles.play(tag_name);
    }

    /// Directly sets the current frame index.
    pub fn setFrame(self: *AnimatedSprite, frame_index: usize) void {
        self.tiles.setFrame(frame_index);
    }

    /// Advances the animation frame timer by 1 tick (~16.6ms at 60Hz).
    pub fn update(self: *AnimatedSprite) void {
        self.tiles.update();
    }

    /// Advances the animation frame timer with an explicit custom DMA queue.
    pub fn updateWithQueue(self: *AnimatedSprite, custom_queue: anytype) void {
        self.tiles.updateWithQueue(custom_queue);
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
