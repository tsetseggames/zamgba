const std = @import("std");
const hal = @import("zamgba-hal");
const sprite_mod = @import("sprite.zig");
const Sprite = sprite_mod.Sprite;
const StaticTile = sprite_mod.StaticTile;
const SpriteSheet = sprite_mod.SpriteSheet;
const BppMode = sprite_mod.BppMode;
const AnimationDirection = sprite_mod.AnimationDirection;
const AnimationTag = sprite_mod.AnimationTag;
const vram_allocator = @import("vram_allocator.zig");
const dma_queue = @import("dma_queue.zig");
const engine = @import("engine.zig");

pub const AnimatedSpriteError = error{
    OutOfVram,
    EmptySheet,
    TagNotFound,
    Unimplemented,
};

pub const AnimationMode = enum {
    streaming, // VRAM slot is allocated once; frame switches stream via DMA
    static, // All frames resident in VRAM; frame switches shift tile_index
};

/// High-level component managing sprite animation timing, VRAM staging, and tag sequencing.
pub const AnimatedTiles = struct {
    sheet: *const SpriteSheet,
    mode: AnimationMode,
    vram_alloc: ?vram_allocator.VramAllocation = null,

    current_frame: usize = 0,
    current_tag_index: ?usize = null,
    frame_timer: u16 = 0,
    is_playing: bool = true,
    pingpong_reverse: bool = false,
    palette_bank: u4 = 0,

    /// Initializes animation tiles from a SpriteSheet.
    pub fn init(sheet: *const SpriteSheet, mode: AnimationMode) AnimatedSpriteError!AnimatedTiles {
        _ = sheet;
        _ = mode;
        return error.Unimplemented;
    }

    /// Releases any allocated VRAM slot back to the VramAllocator.
    pub fn deinit(self: *AnimatedTiles) void {
        _ = self;
    }

    /// Selects an animation tag by name (e.g. "fly", "run", "idle").
    pub fn play(self: *AnimatedTiles, tag_name: []const u8) bool {
        _ = self;
        _ = tag_name;
        return false;
    }

    /// Directly sets the current frame index.
    pub fn setFrame(self: *AnimatedTiles, frame_index: usize) void {
        _ = self;
        _ = frame_index;
    }

    /// Advances the animation frame timer by 1 tick (~16.6ms at 60Hz).
    pub fn update(self: *AnimatedTiles) void {
        self.updateWithQueue(null);
    }

    /// Advances the animation frame timer with an explicit custom DMA queue (for testing/custom scheduling).
    pub fn updateWithQueue(self: *AnimatedTiles, custom_queue: ?*dma_queue.DmaQueue) void {
        _ = self;
        _ = custom_queue;
    }

    /// Derives the current StaticTile description (tile_index, palette_bank, bpp) for rendering.
    pub fn getTile(self: *const AnimatedTiles) StaticTile {
        _ = self;
        return .{};
    }
};

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
    pub fn updateWithQueue(self: *AnimatedSprite, custom_queue: ?*dma_queue.DmaQueue) void {
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

test "ANI001: AnimatedTiles init with streaming mode allocates 1-frame VRAM slot" {
    vram_allocator.reset();

    const dummy_sheet = SpriteSheet{
        .bpp = .bpp4,
        .width = 16,
        .height = 16,
        .tile_count_per_frame = 4,
        .frame_count = 3,
        .tiles = &[_]u8{0} ** (3 * 128),
        .durations_ms = &[_]u16{ 100, 100, 100 },
        .tags = &[_]AnimationTag{
            .{ .name = "run", .from_frame = 0, .to_frame = 2, .direction = .forward },
        },
    };

    var anim_tiles = try AnimatedTiles.init(&dummy_sheet, .streaming);
    defer anim_tiles.deinit();

    try std.testing.expect(anim_tiles.vram_alloc != null);
    try std.testing.expectEqual(@as(u16, 0), anim_tiles.getTile().tile_index);
    try std.testing.expectEqual(@as(u16, 4), anim_tiles.vram_alloc.?.tile_count);
    try std.testing.expectEqual(@as(usize, 0), anim_tiles.current_frame);
}

test "ANI002: AnimatedTiles init with static mode uses base tile_index and advances with frame" {
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

    var anim_tiles = try AnimatedTiles.init(&dummy_sheet, .static);
    defer anim_tiles.deinit();

    try std.testing.expect(anim_tiles.vram_alloc == null);
    try std.testing.expectEqual(@as(u16, 0), anim_tiles.getTile().tile_index);

    // Set frame 1 in static mode advances tile_index by 4
    anim_tiles.setFrame(1);
    try std.testing.expectEqual(@as(usize, 1), anim_tiles.current_frame);
    try std.testing.expectEqual(@as(u16, 4), anim_tiles.getTile().tile_index);
}

test "ANI003: AnimatedTiles play selects tag and resets frame" {
    const dummy_sheet = SpriteSheet{
        .bpp = .bpp4,
        .width = 16,
        .height = 16,
        .tile_count_per_frame = 4,
        .frame_count = 4,
        .tiles = &[_]u8{0} ** 512,
        .durations_ms = &[_]u16{ 100, 100, 100, 100 },
        .tags = &[_]AnimationTag{
            .{ .name = "idle", .from_frame = 0, .to_frame = 1, .direction = .forward },
            .{ .name = "attack", .from_frame = 2, .to_frame = 3, .direction = .forward },
        },
    };

    var anim_tiles = try AnimatedTiles.init(&dummy_sheet, .static);
    defer anim_tiles.deinit();

    try std.testing.expect(anim_tiles.play("attack"));
    try std.testing.expectEqual(@as(usize, 2), anim_tiles.current_frame);
    try std.testing.expect(!anim_tiles.play("non_existent"));
}

test "ANI004: AnimatedTiles updateWithQueue advances frame on timer expiration and stages DMA" {
    vram_allocator.reset();
    var test_queue = dma_queue.DmaQueue.init();

    const dummy_sheet = SpriteSheet{
        .bpp = .bpp4,
        .width = 16,
        .height = 16,
        .tile_count_per_frame = 4,
        .frame_count = 2,
        .tiles = &[_]u8{0} ** 256,
        .durations_ms = &[_]u16{ 32, 32 }, // 32ms ~= 2 ticks at 60Hz
        .tags = &[_]AnimationTag{
            .{ .name = "walk", .from_frame = 0, .to_frame = 1, .direction = .forward },
        },
    };

    var anim_tiles = try AnimatedTiles.init(&dummy_sheet, .streaming);
    defer anim_tiles.deinit();
    _ = anim_tiles.play("walk");

    test_queue.clear();

    // Tick 1: timer = 1, frame stays 0
    anim_tiles.updateWithQueue(&test_queue);
    try std.testing.expectEqual(@as(usize, 0), anim_tiles.current_frame);
    try std.testing.expectEqual(@as(usize, 0), test_queue.count());

    // Tick 2: timer reaches 2, frame switches to 1, DMA task queued!
    anim_tiles.updateWithQueue(&test_queue);
    try std.testing.expectEqual(@as(usize, 1), anim_tiles.current_frame);
    try std.testing.expectEqual(@as(usize, 1), test_queue.count());
    try std.testing.expectEqual(@as(usize, 128), test_queue.getStagedBytes());
}

test "ANI005: AnimatedTiles deinit releases VRAM allocation back to buddy allocator" {
    vram_allocator.reset();
    const initial_free = vram_allocator.getFreeTileCount();

    const dummy_sheet = SpriteSheet{
        .bpp = .bpp8,
        .width = 32,
        .height = 32,
        .tile_count_per_frame = 16,
        .frame_count = 2,
        .tiles = &[_]u8{0} ** 2048,
        .durations_ms = &[_]u16{ 100, 100 },
        .tags = &[_]AnimationTag{},
    };

    var anim_tiles = try AnimatedTiles.init(&dummy_sheet, .streaming);
    // 32x32 8-bpp consumes 32 slot units
    try std.testing.expectEqual(initial_free - 32, vram_allocator.getFreeTileCount());

    anim_tiles.deinit();
    // Memory coalesced and restored to full capacity
    try std.testing.expectEqual(initial_free, vram_allocator.getFreeTileCount());
}

test "ANI006: pingpong animation direction reverses correctly" {
    const dummy_sheet = SpriteSheet{
        .bpp = .bpp4,
        .width = 16,
        .height = 16,
        .tile_count_per_frame = 4,
        .frame_count = 3,
        .tiles = &[_]u8{0} ** (3 * 128),
        .durations_ms = &[_]u16{ 16, 16, 16 }, // 16ms = 1 tick per frame
        .tags = &[_]AnimationTag{
            .{ .name = "ping", .from_frame = 0, .to_frame = 2, .direction = .pingpong },
        },
    };

    var anim_tiles = try AnimatedTiles.init(&dummy_sheet, .static);
    defer anim_tiles.deinit();
    _ = anim_tiles.play("ping");

    try std.testing.expectEqual(@as(usize, 0), anim_tiles.current_frame);
    anim_tiles.update(); // 0 -> 1
    try std.testing.expectEqual(@as(usize, 1), anim_tiles.current_frame);
    anim_tiles.update(); // 1 -> 2 (reaches top, switches to reverse)
    try std.testing.expectEqual(@as(usize, 2), anim_tiles.current_frame);
    anim_tiles.update(); // 2 -> 1
    try std.testing.expectEqual(@as(usize, 1), anim_tiles.current_frame);
    anim_tiles.update(); // 1 -> 0 (reaches bottom, switches to forward)
    try std.testing.expectEqual(@as(usize, 0), anim_tiles.current_frame);
}

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
    // 16x16: shape=0, size=1, h_flip=1 -> attr1 has 20 | (1 << 14) | (1 << 12)
    try std.testing.expectEqual(@as(u16, 30), attr.attr0 & 0x00FF);
    try std.testing.expectEqual(@as(u16, 20 | (1 << 14) | (1 << 12)), attr.attr1);
}
