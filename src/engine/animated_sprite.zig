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
const engine = @import("engine.zig");

pub const AnimatedSpriteError = error{
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
    pingpong_reverse: bool = false,

    /// Creates and initializes an animated sprite from a converted SpriteSheet.
    pub fn init(sheet: *const SpriteSheet, mode: AnimationMode, x: i32, y: i32) AnimatedSpriteError!AnimatedSprite {
        if (sheet.frame_count == 0) return error.EmptySheet;

        var spr = Sprite.init(x, y, sheet.width, sheet.height);
        spr.bpp = sheet.bpp;

        var vram_alloc: ?vram_allocator.VramAllocation = null;
        if (mode == .streaming) {
            const alloc_res = vram_allocator.alloc(sheet.width, sheet.height, sheet.bpp) catch return error.OutOfVram;
            vram_alloc = alloc_res;
            spr.tile_index = alloc_res.tile_index;
        } else {
            spr.tile_index = 0;
        }

        var self = AnimatedSprite{
            .sprite = spr,
            .sheet = sheet,
            .mode = mode,
            .vram_alloc = vram_alloc,
            .current_frame = 0,
            .current_tag_index = null,
            .frame_timer = 0,
            .is_playing = true,
            .h_flip = false,
            .pingpong_reverse = false,
        };

        self.stageCurrentFrameWithQueue(null);
        return self;
    }

    /// Releases any allocated VRAM slot back to the VramAllocator.
    pub fn deinit(self: *AnimatedSprite) void {
        if (self.vram_alloc) |alloc_info| {
            vram_allocator.free(alloc_info) catch {};
            self.vram_alloc = null;
        }
    }

    /// Selects an animation tag by name (e.g. "fly", "run", "idle").
    pub fn play(self: *AnimatedSprite, tag_name: []const u8) bool {
        for (self.sheet.tags, 0..) |tag, i| {
            if (std.mem.eql(u8, tag.name, tag_name)) {
                self.current_tag_index = i;
                self.current_frame = tag.from_frame;
                self.frame_timer = 0;
                self.pingpong_reverse = false;
                self.is_playing = true;
                self.stageCurrentFrameWithQueue(null);
                return true;
            }
        }
        return false;
    }

    /// Directly sets the current frame index.
    pub fn setFrame(self: *AnimatedSprite, frame_index: usize) void {
        if (frame_index >= self.sheet.frame_count) return;
        self.current_frame = frame_index;
        self.frame_timer = 0;
        self.stageCurrentFrameWithQueue(null);
    }

    fn advanceFrame(self: *AnimatedSprite) void {
        if (self.current_tag_index) |t_idx| {
            if (t_idx < self.sheet.tags.len) {
                const tag = self.sheet.tags[t_idx];
                switch (tag.direction) {
                    .forward => {
                        if (self.current_frame >= tag.to_frame) {
                            self.current_frame = tag.from_frame;
                        } else {
                            self.current_frame += 1;
                        }
                    },
                    .reverse => {
                        if (self.current_frame <= tag.from_frame) {
                            self.current_frame = tag.to_frame;
                        } else {
                            self.current_frame -= 1;
                        }
                    },
                    .pingpong => {
                        if (!self.pingpong_reverse) {
                            if (self.current_frame >= tag.to_frame) {
                                self.pingpong_reverse = true;
                                if (tag.to_frame > tag.from_frame) {
                                    self.current_frame = tag.to_frame - 1;
                                }
                            } else {
                                self.current_frame += 1;
                            }
                        } else {
                            if (self.current_frame <= tag.from_frame) {
                                self.pingpong_reverse = false;
                                if (tag.to_frame > tag.from_frame) {
                                    self.current_frame = tag.from_frame + 1;
                                }
                            } else {
                                self.current_frame -= 1;
                            }
                        }
                    },
                }
                return;
            }
        }

        // Default: loop all frames forward
        self.current_frame = (self.current_frame + 1) % self.sheet.frame_count;
    }

    fn stageCurrentFrameWithQueue(self: *AnimatedSprite, custom_queue: ?*dma_queue.DmaQueue) void {
        if (self.mode == .streaming) {
            const alloc_res = self.vram_alloc orelse return;
            const bytes_per_frame = @as(usize, self.sheet.tile_count_per_frame) * (if (self.sheet.bpp == .bpp4) @as(usize, 32) else @as(usize, 64));
            const start = self.current_frame * bytes_per_frame;
            if (start + bytes_per_frame <= self.sheet.tiles.len) {
                const frame_src = self.sheet.tiles.ptr + start;
                const dest_ptr = alloc_res.toVramPointer(hal.specs.MemorySections.VRAM + 32768);

                if (custom_queue) |q| {
                    _ = q.enqueueBytes(frame_src, @ptrCast(dest_ptr), @as(u16, @intCast(bytes_per_frame))) catch {};
                } else {
                    _ = engine.enqueueDmaBytes(frame_src, @ptrCast(dest_ptr), @as(u16, @intCast(bytes_per_frame))) catch {};
                }
            }
        } else {
            const tile_step = if (self.sheet.bpp == .bpp4) self.sheet.tile_count_per_frame else self.sheet.tile_count_per_frame * 2;
            self.sprite.tile_index = @as(u16, @intCast(self.current_frame)) * tile_step;
        }
    }

    /// Advances the animation frame timer by 1 tick (~16.6ms at 60Hz).
    /// If frame advances, stages a DMA transfer (streaming mode) or updates tile_index (static mode).
    pub fn update(self: *AnimatedSprite) void {
        self.updateWithQueue(null);
    }

    /// Advances the animation frame timer with an explicit custom DMA queue (for testing).
    pub fn updateWithQueue(self: *AnimatedSprite, custom_queue: ?*dma_queue.DmaQueue) void {
        if (!self.is_playing or self.sheet.frame_count <= 1) return;

        self.frame_timer += 1;

        // Calculate ticks from duration_ms (60 FPS -> ~16.6ms per tick)
        const duration_ms = if (self.current_frame < self.sheet.durations_ms.len)
            self.sheet.durations_ms[self.current_frame]
        else
            100;
        const ticks: u16 = @max(1, @as(u16, @intCast((duration_ms + 8) / 16)));

        if (self.frame_timer >= ticks) {
            self.frame_timer = 0;
            self.advanceFrame();
            self.stageCurrentFrameWithQueue(custom_queue);
        }
    }

    pub fn getSprite(self: *AnimatedSprite) *Sprite {
        self.sprite.h_flip = self.h_flip;
        return &self.sprite;
    }
};

test "ANI001: AnimatedSprite init with streaming mode allocates 1-frame VRAM slot" {
    vram_allocator.reset();
    var queue = dma_queue.DmaQueue.init();

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

    var anim = try AnimatedSprite.init(&dummy_sheet, .streaming, 10, 20);
    defer anim.deinit();

    try std.testing.expect(anim.vram_alloc != null);
    try std.testing.expectEqual(@as(u16, 0), anim.sprite.tile_index);
    try std.testing.expectEqual(@as(u16, 4), anim.vram_alloc.?.tile_count);
    try std.testing.expectEqual(@as(usize, 0), anim.current_frame);

    // Initial frame 0 staged
    _ = &queue;
}

test "ANI002: AnimatedSprite init with static mode uses base tile_index" {
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

    var anim = try AnimatedSprite.init(&dummy_sheet, .static, 50, 60);
    defer anim.deinit();

    try std.testing.expect(anim.vram_alloc == null);
    try std.testing.expectEqual(@as(u16, 0), anim.sprite.tile_index);

    // Set frame 1 in static mode advances tile_index by 4
    anim.setFrame(1);
    try std.testing.expectEqual(@as(usize, 1), anim.current_frame);
    try std.testing.expectEqual(@as(u16, 4), anim.sprite.tile_index);
}

test "ANI003: play() selects tag and resets frame" {
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

    var anim = try AnimatedSprite.init(&dummy_sheet, .static, 0, 0);
    defer anim.deinit();

    try std.testing.expect(anim.play("attack"));
    try std.testing.expectEqual(@as(usize, 2), anim.current_frame);
    try std.testing.expect(!anim.play("non_existent"));
}

test "ANI004: updateWithQueue advances frame on timer expiration and stages DMA" {
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

    var anim = try AnimatedSprite.init(&dummy_sheet, .streaming, 0, 0);
    defer anim.deinit();
    _ = anim.play("walk");

    test_queue.clear();

    // Tick 1: timer = 1, frame stays 0
    anim.updateWithQueue(&test_queue);
    try std.testing.expectEqual(@as(usize, 0), anim.current_frame);
    try std.testing.expectEqual(@as(usize, 0), test_queue.count());

    // Tick 2: timer reaches 2, frame switches to 1, DMA task queued!
    anim.updateWithQueue(&test_queue);
    try std.testing.expectEqual(@as(usize, 1), anim.current_frame);
    try std.testing.expectEqual(@as(usize, 1), test_queue.count());
    try std.testing.expectEqual(@as(usize, 128), test_queue.getStagedBytes());
}

test "ANI005: deinit releases VRAM allocation back to buddy allocator" {
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

    var anim = try AnimatedSprite.init(&dummy_sheet, .streaming, 0, 0);
    // 32x32 8-bpp consumes 32 slot units
    try std.testing.expectEqual(initial_free - 32, vram_allocator.getFreeTileCount());

    anim.deinit();
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

    var anim = try AnimatedSprite.init(&dummy_sheet, .static, 0, 0);
    defer anim.deinit();
    _ = anim.play("ping");

    try std.testing.expectEqual(@as(usize, 0), anim.current_frame);
    anim.update(); // 0 -> 1
    try std.testing.expectEqual(@as(usize, 1), anim.current_frame);
    anim.update(); // 1 -> 2 (reaches top, switches to reverse)
    try std.testing.expectEqual(@as(usize, 2), anim.current_frame);
    anim.update(); // 2 -> 1
    try std.testing.expectEqual(@as(usize, 1), anim.current_frame);
    anim.update(); // 1 -> 0 (reaches bottom, switches to forward)
    try std.testing.expectEqual(@as(usize, 0), anim.current_frame);
}
