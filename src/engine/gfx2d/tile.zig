const std = @import("std");
const hal = @import("zamgba-hal");
const Color = @import("color.zig").Color;
const vram_allocator = @import("../vram_allocator.zig");
const dma_queue = @import("../dma_queue.zig");
const engine = @import("../engine.zig");

pub const TileError = error{
    InvalidDimensions,
    OutOfVram,
    EmptySheet,
    TagNotFound,
    Unimplemented,
};

pub const BppMode = hal.specs.BppMode;

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

pub const AnimationMode = enum {
    streaming, // VRAM slot is allocated once; frame switches stream via DMA
    static, // All frames resident in VRAM; frame switches shift tile_index
};

// Software animation timing constants (60Hz ~ 16.6ms per frame)
const DEFAULT_FRAME_DURATION_MS: u16 = 100;
const MS_PER_TICK_APPROX: u16 = 16;

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

    /// Internal helper: fills custom VRAM and PALRAM memory buffers with solid color tile graphics and palette entry.
    /// Used by `fillSolidColor` and test mocks.
    fn fillSolidColorToBuffers(
        self: ColorFillTile,
        width: u16,
        height: u16,
        vram_obj_base: []volatile u16,
        palram_obj_base: []volatile u16,
        color: Color,
    ) TileError!void {
        if (width == 0 or height == 0 or width % hal.specs.Tile.WIDTH_PIXELS != 0 or height % hal.specs.Tile.HEIGHT_PIXELS != 0) {
            return TileError.InvalidDimensions;
        }
        const bgr15 = color.toBgr555();

        const bank_offset = @as(usize, self.palette_bank & hal.specs.Palette.BANK_MASK) * hal.specs.Palette.COLORS_PER_BANK;
        if (bank_offset + hal.specs.Palette.PRIMARY_COLOR_INDEX < palram_obj_base.len) {
            palram_obj_base[bank_offset + hal.specs.Palette.PRIMARY_COLOR_INDEX] = bgr15;
        }

        const tile_word_offset = @as(usize, self.tile_index) * hal.specs.Tile.WORDS_4BPP;
        const total_tiles = (@as(usize, width) / hal.specs.Tile.WIDTH_PIXELS) * (@as(usize, height) / hal.specs.Tile.HEIGHT_PIXELS);
        const total_words = total_tiles * hal.specs.Tile.WORDS_4BPP;

        if (tile_word_offset + total_words <= vram_obj_base.len) {
            for (0..total_words) |i| {
                vram_obj_base[tile_word_offset + i] = hal.specs.Tile.SOLID_COLOR_1_PATTERN_4BPP;
            }
        }
    }

    /// Fills GBA OBJ VRAM and updates OBJ PALRAM with solid color tile graphics.
    pub fn fillSolidColor(self: ColorFillTile, width: u16, height: u16, color: Color) TileError!void {
        const obj_pal = hal.MemorySections.OBJ_PALRAM;
        const obj_vram = hal.MemorySections.OBJ_VRAM;

        const pal_slice = obj_pal[0..hal.MemorySections.OBJ_PALRAM_SIZE_WORDS];
        const vram_slice = obj_vram[0..hal.MemorySections.OBJ_VRAM_SIZE_WORDS];

        try self.fillSolidColorToBuffers(width, height, vram_slice, pal_slice, color);
    }
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
    pub fn init(sheet: *const SpriteSheet, mode: AnimationMode) TileError!AnimatedTiles {
        if (sheet.frame_count == 0) return error.EmptySheet;

        var vram_alloc: ?vram_allocator.VramAllocation = null;
        if (mode == .streaming) {
            const alloc_res = vram_allocator.alloc(sheet.width, sheet.height, sheet.bpp) catch return error.OutOfVram;
            vram_alloc = alloc_res;
        }

        var self = AnimatedTiles{
            .sheet = sheet,
            .mode = mode,
            .vram_alloc = vram_alloc,
            .current_frame = 0,
            .current_tag_index = null,
            .frame_timer = 0,
            .is_playing = true,
            .pingpong_reverse = false,
            .palette_bank = 0,
        };

        self.stageCurrentFrameWithQueue(null);
        return self;
    }

    /// Releases any allocated VRAM slot back to the VramAllocator.
    pub fn deinit(self: *AnimatedTiles) void {
        if (self.vram_alloc) |alloc_info| {
            vram_allocator.free(alloc_info) catch {};
            self.vram_alloc = null;
        }
    }

    /// Selects an animation tag by name (e.g. "fly", "run", "idle").
    pub fn play(self: *AnimatedTiles, tag_name: []const u8) bool {
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
    pub fn setFrame(self: *AnimatedTiles, frame_index: usize) void {
        if (frame_index >= self.sheet.frame_count) return;
        self.current_frame = frame_index;
        self.frame_timer = 0;
        self.stageCurrentFrameWithQueue(null);
    }

    fn advanceFrame(self: *AnimatedTiles) void {
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

    fn stageCurrentFrameWithQueue(self: *AnimatedTiles, custom_queue: ?*dma_queue.DmaQueue) void {
        if (self.mode == .streaming) {
            const alloc_res = self.vram_alloc orelse return;
            const bytes_per_frame = @as(usize, self.sheet.tile_count_per_frame) * (if (self.sheet.bpp == .bpp4) hal.specs.Tile.BYTES_4BPP else hal.specs.Tile.BYTES_8BPP);
            const start = self.current_frame * bytes_per_frame;
            if (start + bytes_per_frame <= self.sheet.tiles.len) {
                const frame_src = self.sheet.tiles.ptr + start;
                const dest_ptr = alloc_res.toVramPointer(hal.specs.MemorySections.OBJ_VRAM);

                if (custom_queue) |q| {
                    _ = q.enqueueBytes(frame_src, @ptrCast(dest_ptr), @as(u16, @intCast(bytes_per_frame))) catch {};
                } else {
                    _ = engine.enqueueDmaBytes(frame_src, @ptrCast(dest_ptr), @as(u16, @intCast(bytes_per_frame))) catch {};
                }
            }
        }
    }

    /// Advances the animation frame timer by 1 tick (~16.6ms at 60Hz).
    pub fn update(self: *AnimatedTiles) void {
        self.updateWithQueue(null);
    }

    /// Advances the animation frame timer with an explicit custom DMA queue (for testing/custom scheduling).
    pub fn updateWithQueue(self: *AnimatedTiles, custom_queue: ?*dma_queue.DmaQueue) void {
        if (!self.is_playing or self.sheet.frame_count <= 1) return;

        self.frame_timer += 1;

        // Calculate ticks from duration_ms (60 FPS -> ~16.6ms per tick)
        const duration_ms = if (self.current_frame < self.sheet.durations_ms.len)
            self.sheet.durations_ms[self.current_frame]
        else
            DEFAULT_FRAME_DURATION_MS;
        const ticks: u16 = @max(1, @as(u16, @intCast((duration_ms + (MS_PER_TICK_APPROX / 2)) / MS_PER_TICK_APPROX)));

        if (self.frame_timer >= ticks) {
            self.frame_timer = 0;
            self.advanceFrame();
            self.stageCurrentFrameWithQueue(custom_queue);
        }
    }

    /// Derives the current StaticTile description (tile_index, palette_bank, bpp) for rendering.
    pub fn getTile(self: *const AnimatedTiles) StaticTile {
        const tile_idx: u16 = if (self.mode == .streaming)
            if (self.vram_alloc) |a| a.tile_index else 0
        else blk: {
            const tile_step = if (self.sheet.bpp == .bpp4)
                self.sheet.tile_count_per_frame
            else
                self.sheet.tile_count_per_frame * 2;
            break :blk @as(u16, @intCast(self.current_frame)) * tile_step;
        };

        return .{
            .tile_index = tile_idx,
            .palette_bank = self.palette_bank,
            .bpp = self.sheet.bpp,
        };
    }
};

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

test "SPR006: ColorFillTile fillSolidColorToBuffers mock buffer" {
    var mock_vram: [1024]u16 = [_]u16{0} ** 1024;
    var mock_palram: [256]u16 = [_]u16{0} ** 256;

    const fill_tile = ColorFillTile{ .tile_index = 2, .palette_bank = 1 };

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

test "ANI001: AnimatedTiles init with streaming mode allocates 1-frame VRAM slot" {
    vram_allocator.reset();

    const dummy_tiles: [3 * 128]u8 align(4) = [_]u8{0} ** (3 * 128);
    const dummy_sheet = SpriteSheet{
        .bpp = .bpp4,
        .width = 16,
        .height = 16,
        .tile_count_per_frame = 4,
        .frame_count = 3,
        .tiles = &dummy_tiles,
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
    const dummy_tiles: [256]u8 align(4) = [_]u8{0} ** 256;
    const dummy_sheet = SpriteSheet{
        .bpp = .bpp4,
        .width = 16,
        .height = 16,
        .tile_count_per_frame = 4,
        .frame_count = 2,
        .tiles = &dummy_tiles,
        .durations_ms = &[_]u16{ 100, 100 },
        .tags = &[_]AnimationTag{},
    };

    var anim_tiles = try AnimatedTiles.init(&dummy_sheet, .static);
    defer anim_tiles.deinit();

    try std.testing.expect(anim_tiles.vram_alloc == null);
    try std.testing.expectEqual(@as(u16, 0), anim_tiles.getTile().tile_index);

    anim_tiles.setFrame(1);
    try std.testing.expectEqual(@as(usize, 1), anim_tiles.current_frame);
    try std.testing.expectEqual(@as(u16, 4), anim_tiles.getTile().tile_index);
}

test "ANI003: AnimatedTiles play selects tag and resets frame" {
    const dummy_tiles: [512]u8 align(4) = [_]u8{0} ** 512;
    const dummy_sheet = SpriteSheet{
        .bpp = .bpp4,
        .width = 16,
        .height = 16,
        .tile_count_per_frame = 4,
        .frame_count = 4,
        .tiles = &dummy_tiles,
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

    const dummy_tiles: [256]u8 align(4) = [_]u8{0} ** 256;
    const dummy_sheet = SpriteSheet{
        .bpp = .bpp4,
        .width = 16,
        .height = 16,
        .tile_count_per_frame = 4,
        .frame_count = 2,
        .tiles = &dummy_tiles,
        .durations_ms = &[_]u16{ 32, 32 },
        .tags = &[_]AnimationTag{
            .{ .name = "walk", .from_frame = 0, .to_frame = 1, .direction = .forward },
        },
    };

    var anim_tiles = try AnimatedTiles.init(&dummy_sheet, .streaming);
    defer anim_tiles.deinit();
    _ = anim_tiles.play("walk");

    test_queue.clear();

    anim_tiles.updateWithQueue(&test_queue);
    try std.testing.expectEqual(@as(usize, 0), anim_tiles.current_frame);
    try std.testing.expectEqual(@as(usize, 0), test_queue.count());

    anim_tiles.updateWithQueue(&test_queue);
    try std.testing.expectEqual(@as(usize, 1), anim_tiles.current_frame);
    try std.testing.expectEqual(@as(usize, 1), test_queue.count());
    try std.testing.expectEqual(@as(usize, 128), test_queue.getStagedBytes());
}

test "ANI005: AnimatedTiles deinit releases VRAM allocation back to buddy allocator" {
    vram_allocator.reset();
    const initial_free = vram_allocator.getFreeTileCount();

    const dummy_tiles: [2048]u8 align(4) = [_]u8{0} ** 2048;
    const dummy_sheet = SpriteSheet{
        .bpp = .bpp8,
        .width = 32,
        .height = 32,
        .tile_count_per_frame = 16,
        .frame_count = 2,
        .tiles = &dummy_tiles,
        .durations_ms = &[_]u16{ 100, 100 },
        .tags = &[_]AnimationTag{},
    };

    var anim_tiles = try AnimatedTiles.init(&dummy_sheet, .streaming);
    try std.testing.expectEqual(initial_free - 32, vram_allocator.getFreeTileCount());

    anim_tiles.deinit();
    try std.testing.expectEqual(initial_free, vram_allocator.getFreeTileCount());
}

test "ANI006: pingpong animation direction reverses correctly" {
    const dummy_tiles: [3 * 128]u8 align(4) = [_]u8{0} ** (3 * 128);
    const dummy_sheet = SpriteSheet{
        .bpp = .bpp4,
        .width = 16,
        .height = 16,
        .tile_count_per_frame = 4,
        .frame_count = 3,
        .tiles = &dummy_tiles,
        .durations_ms = &[_]u16{ 16, 16, 16 },
        .tags = &[_]AnimationTag{
            .{ .name = "ping", .from_frame = 0, .to_frame = 2, .direction = .pingpong },
        },
    };

    var anim_tiles = try AnimatedTiles.init(&dummy_sheet, .static);
    defer anim_tiles.deinit();
    _ = anim_tiles.play("ping");

    try std.testing.expectEqual(@as(usize, 0), anim_tiles.current_frame);
    anim_tiles.update();
    try std.testing.expectEqual(@as(usize, 1), anim_tiles.current_frame);
    anim_tiles.update();
    try std.testing.expectEqual(@as(usize, 2), anim_tiles.current_frame);
    anim_tiles.update();
    try std.testing.expectEqual(@as(usize, 1), anim_tiles.current_frame);
    anim_tiles.update();
    try std.testing.expectEqual(@as(usize, 0), anim_tiles.current_frame);
}
