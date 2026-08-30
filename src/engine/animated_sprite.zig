const std = @import("std");
const hal = @import("zamgba-hal");
const sprite_mod = @import("sprite.zig");
const Sprite = sprite_mod.Sprite;
const SpriteSheet = sprite_mod.SpriteSheet;
const BppMode = sprite_mod.BppMode;
const AnimationDirection = sprite_mod.AnimationDirection;
const AnimationTag = sprite_mod.AnimationTag;
const vram_allocator = @import("vram_allocator.zig");
const dma_queue = @import("dma_queue.zig");

pub const AnimatedSpriteError = error{
    Unimplemented,
    OutOfVram,
    EmptySheet,
    TagNotFound,
};

pub const AnimationMode = enum {
    streaming, // VRAM slot is allocated once; frame switches stream via DMA
    static, // All frames resident in VRAM; frame switches shift tile_index
};

pub const AnimatedSprite = struct {
    sprite: Sprite,
    sheet: *const SpriteSheet,
    mode: AnimationMode,
    vram_alloc: ?vram_allocator.VramAllocation = null,

    current_frame: usize = 0,
    current_tag_index: ?usize = null,
    frame_timer: u16 = 0,
    is_playing: bool = true,
    h_flip: bool = false,

    /// Creates and initializes an animated sprite from a converted SpriteSheet.
    pub fn init(sheet: *const SpriteSheet, mode: AnimationMode, x: i32, y: i32) AnimatedSpriteError!AnimatedSprite {
        _ = sheet;
        _ = mode;
        _ = x;
        _ = y;
        return error.Unimplemented;
    }

    /// Releases any allocated VRAM slot back to the VramAllocator.
    pub fn deinit(self: *AnimatedSprite) void {
        _ = self;
    }

    /// Selects an animation tag by name (e.g. "fly", "run", "idle").
    pub fn play(self: *AnimatedSprite, tag_name: []const u8) bool {
        _ = self;
        _ = tag_name;
        return false;
    }

    /// Directly sets the current frame index.
    pub fn setFrame(self: *AnimatedSprite, frame_index: usize, queue: *dma_queue.DmaQueue) void {
        _ = self;
        _ = frame_index;
        _ = queue;
    }

    /// Advances the animation frame timer by 1 tick (~16.6ms at 60Hz).
    /// If frame advances, stages a DMA transfer (streaming mode) or updates tile_index (static mode).
    pub fn update(self: *AnimatedSprite, queue: *dma_queue.DmaQueue) void {
        _ = self;
        _ = queue;
    }

    pub fn getSprite(self: *AnimatedSprite) *Sprite {
        self.sprite.h_flip = self.h_flip;
        return &self.sprite;
    }
};

test "ANI001: AnimatedSprite init stub returns Unimplemented" {
    const dummy_sheet = SpriteSheet{
        .bpp = .bpp4,
        .width = 16,
        .height = 16,
        .tile_count_per_frame = 4,
        .frame_count = 2,
        .tiles = &[_]u8{0} ** 256,
        .durations_ms = &[_]u16{ 100, 100 },
        .tags = &[_]AnimationTag{
            .{ .name = "idle", .from_frame = 0, .to_frame = 1, .direction = .forward },
        },
    };

    try std.testing.expectError(error.Unimplemented, AnimatedSprite.init(&dummy_sheet, .streaming, 10, 20));
}
