const std = @import("std");
const hal = @import("zamgba-hal");
const physics = @import("physics/physics.zig");
const AABB = physics.AABB;
const Fixed24_8 = physics.Fixed24_8;
const CollisionMap = physics.CollisionMap;
const CollisionMask = physics.CollisionMask;
const Collision = physics.Collision;

const gfx2d = @import("gfx2d/gfx2d.zig");
const Color = gfx2d.Color;
const vram_allocator = gfx2d.vram_allocator;
const dma_queue = gfx2d.dma_queue;

pub const SpriteError = error{
    InvalidDimensions,
    OutOfVram,
    EmptySheet,
    TagNotFound,
    InvalidFrameIndex,
    Unimplemented,
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
    bpp: hal.specs.BppMode,
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

const ShapeSize = struct {
    shape: u16,
    size: u16,
};

/// Validates width and height against GBA hardware OBJ dimensions and returns Shape and Size bits.
fn getShapeAndSize(width: u16, height: u16) SpriteError!ShapeSize {
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

/// Result of collision check during movement.
pub const CollisionResult = struct {
    collided_x: bool = false,
    collided_y: bool = false,

    pub fn hasCollided(self: CollisionResult) bool {
        return self.collided_x or self.collided_y;
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

    /// Initialize a Sprite with Fixed24_8 sub-pixel coordinates and validates GBA hardware sprite dimensions.
    pub fn init(x: Fixed24_8, y: Fixed24_8, width: u16, height: u16) SpriteError!Sprite {
        _ = try getShapeAndSize(width, height);
        return .{
            .aabb = AABB.init(x, y, width, height),
        };
    }

    /// Check if this sprite can interact with another sprite based on 16-bit layer and mask filtering.
    pub inline fn canCollideWith(self: *const Sprite, other: *const Sprite) bool {
        return Collision.canInteract(self.layer, self.mask, other.layer, other.mask);
    }

    /// Internal helper to advance and collide a single axis (X or Y).
    fn moveAxis(self: *Sprite, collision_map: CollisionMap, axis: enum { x, y }) bool {
        const vel = switch (axis) {
            .x => self.velocity_x,
            .y => self.velocity_y,
        };
        if (vel.raw == 0) return false;

        const test_box = switch (axis) {
            .x => AABB.init(self.aabb.x.add(vel), self.aabb.y, self.aabb.width, self.aabb.height),
            .y => AABB.init(self.aabb.x, self.aabb.y.add(vel), self.aabb.width, self.aabb.height),
        };

        if (collision_map.isColliding(test_box)) {
            switch (axis) {
                .x => self.velocity_x = Fixed24_8.zero,
                .y => self.velocity_y = Fixed24_8.zero,
            }
            return true;
        } else {
            switch (axis) {
                .x => self.aabb.x = test_box.x,
                .y => self.aabb.y = test_box.y,
            }
            return false;
        }
    }

    /// Move the sprite by its current velocity, checking and resolving collisions
    /// independently on X and Y axes against the CollisionMap.
    pub fn moveAndCollide(self: *Sprite, collision_map: CollisionMap) CollisionResult {
        return .{
            .collided_x = self.moveAxis(collision_map, .x),
            .collided_y = self.moveAxis(collision_map, .y),
        };
    }
};

/// Compiles an engine-level sprite and graphical tile settings into a hardware OAM attribute.
fn compileOamAttr(
    spr: *const Sprite,
    tile_index: u16,
    palette_bank: u4,
    bpp: hal.specs.BppMode,
) hal.oam.ObjAttr {
    if (!spr.visible) {
        return .{ .attr0 = 160, .attr1 = 0, .attr2 = 0, .fill = 0 };
    }

    const shape_size = getShapeAndSize(spr.aabb.width, spr.aabb.height) catch ShapeSize{
        .shape = hal.oam.Shape.SQUARE,
        .size = hal.oam.Size.SIZE_0,
    };

    const y_val: i32 = @intCast(spr.aabb.y.toInt());
    const x_val: i32 = @intCast(spr.aabb.x.toInt());

    const y_hw: u16 = @as(u16, @bitCast(@as(i16, @truncate(y_val)))) & 0x00FF;
    const x_hw: u16 = @as(u16, @bitCast(@as(i16, @truncate(x_val)))) & 0x01FF;

    const bpp_bit: u16 = if (bpp == .bpp8) (1 << 13) else 0;
    const h_flip_bit: u16 = if (spr.h_flip) (1 << 12) else 0;
    const v_flip_bit: u16 = if (spr.v_flip) (1 << 13) else 0;

    const attr0: u16 = y_hw | (shape_size.shape << 14) | bpp_bit;
    const attr1: u16 = x_hw | (shape_size.size << 14) | h_flip_bit | v_flip_bit;
    const attr2: u16 = (tile_index & 0x03FF) | (@as(u16, palette_bank & 0x0F) << 12);

    return .{
        .attr0 = attr0,
        .attr1 = attr1,
        .attr2 = attr2,
        .fill = 0,
    };
}

/// Static GBA sprite: Combines spatial/physics properties (Sprite) with VRAM tile/palette metadata.
pub const StaticSprite = struct {
    sprite: Sprite,
    tile_index: u16 = 0,
    palette_bank: u4 = 0,
    bpp: hal.specs.BppMode = .bpp4,

    pub const Options = struct {
        tile_index: u16 = 0,
        palette_bank: u4 = 0,
        bpp: hal.specs.BppMode = .bpp4,
    };

    pub fn init(x: Fixed24_8, y: Fixed24_8, width: u16, height: u16, options: Options) SpriteError!StaticSprite {
        return .{
            .sprite = try Sprite.init(x, y, width, height),
            .tile_index = options.tile_index,
            .palette_bank = options.palette_bank,
            .bpp = options.bpp,
        };
    }

    pub fn toOamAttr(self: *const StaticSprite) hal.oam.ObjAttr {
        return compileOamAttr(&self.sprite, self.tile_index, self.palette_bank, self.bpp);
    }

    /// Internal helper: fills custom VRAM and PALRAM memory buffers with solid color tile graphics and palette entry.
    pub fn fillSolidColorToBuffers(
        self: *const StaticSprite,
        vram_obj_base: []volatile u16,
        palram_obj_base: []volatile u16,
        color: Color,
    ) SpriteError!void {
        const width = self.sprite.aabb.width;
        const height = self.sprite.aabb.height;
        if (width == 0 or height == 0 or width % hal.specs.Tile.WIDTH_PIXELS != 0 or height % hal.specs.Tile.HEIGHT_PIXELS != 0) {
            return SpriteError.InvalidDimensions;
        }
        const bgr15 = color.toBgr555();

        const bank_offset = @as(usize, self.palette_bank & hal.specs.Palette.BANK_MASK) * hal.specs.Palette.COLORS_PER_BANK;
        std.debug.assert(bank_offset + hal.specs.Palette.PRIMARY_COLOR_INDEX < palram_obj_base.len);
        palram_obj_base[bank_offset + hal.specs.Palette.PRIMARY_COLOR_INDEX] = bgr15;

        const tile_word_offset = @as(usize, self.tile_index) * hal.specs.Tile.WORDS_4BPP;
        const total_tiles = (@as(usize, width) / hal.specs.Tile.WIDTH_PIXELS) * (@as(usize, height) / hal.specs.Tile.HEIGHT_PIXELS);
        const total_words = total_tiles * hal.specs.Tile.WORDS_4BPP;

        std.debug.assert(tile_word_offset + total_words <= vram_obj_base.len);
        for (0..total_words) |i| {
            vram_obj_base[tile_word_offset + i] = hal.specs.Tile.SOLID_COLOR_1_PATTERN_4BPP;
        }
    }

    /// Fills GBA OBJ VRAM and updates OBJ PALRAM with solid color tile graphics.
    pub fn fillSolidColor(self: *const StaticSprite, color: Color) SpriteError!void {
        const obj_pal = hal.MemorySections.OBJ_PALRAM;
        const obj_vram = hal.MemorySections.OBJ_VRAM;

        const pal_slice = obj_pal[0..hal.MemorySections.OBJ_PALRAM_SIZE_WORDS];
        const vram_slice = obj_vram[0..hal.MemorySections.OBJ_VRAM_SIZE_WORDS];

        try self.fillSolidColorToBuffers(vram_slice, pal_slice, color);
    }
};

/// Animated GBA sprite: Combines a spatial Sprite with frame sequencing, VRAM staging, and tag state.
pub const AnimatedSprite = struct {
    sprite: Sprite,
    sheet: *const SpriteSheet,
    mode: AnimationMode,
    vram_alloc: ?vram_allocator.VramAllocation = null,

    current_frame: usize = 0,
    current_tag_index: ?usize = null,
    frame_timer: u16 = 0,
    is_playing: bool = true,
    pingpong_reverse: bool = false,
    palette_bank: u4 = 0,

    /// Creates and initializes an animated sprite from a converted SpriteSheet and position.
    pub fn init(sheet: *const SpriteSheet, mode: AnimationMode, x: Fixed24_8, y: Fixed24_8) SpriteError!AnimatedSprite {
        if (sheet.frame_count == 0) return error.EmptySheet;

        const spr = try Sprite.init(x, y, sheet.width, sheet.height);

        var vram_alloc: ?vram_allocator.VramAllocation = null;
        if (mode == .streaming) {
            const size = hal.oam.SpriteSize.fromDimensions(sheet.width, sheet.height) catch return error.InvalidDimensions;
            const alloc_res = vram_allocator.alloc(size, sheet.bpp) catch return error.OutOfVram;
            vram_alloc = alloc_res;
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
            .pingpong_reverse = false,
            .palette_bank = 0,
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
    pub fn setAnimation(self: *AnimatedSprite, tag_name: []const u8) SpriteError!void {
        for (self.sheet.tags, 0..) |tag, i| {
            if (std.mem.eql(u8, tag.name, tag_name)) {
                return self.setAnimationByIndex(i);
            }
        }
        return error.TagNotFound;
    }

    /// Selects an animation tag by index without runtime string lookup.
    pub fn setAnimationByIndex(self: *AnimatedSprite, tag_index: usize) SpriteError!void {
        if (tag_index >= self.sheet.tags.len) return error.TagNotFound;
        const tag = self.sheet.tags[tag_index];
        self.current_tag_index = tag_index;
        self.current_frame = tag.from_frame;
        self.frame_timer = 0;
        self.pingpong_reverse = false;
        self.is_playing = true;
        self.stageCurrentFrameWithQueue(null);
    }

    /// Directly sets the current frame index.
    pub fn setFrame(self: *AnimatedSprite, frame_index: usize) SpriteError!void {
        if (frame_index >= self.sheet.frame_count) return error.InvalidFrameIndex;
        self.current_frame = frame_index;
        self.frame_timer = 0;
        self.stageCurrentFrameWithQueue(null);
    }

    pub fn advanceFrame(self: *AnimatedSprite) void {
        if (self.current_tag_index) |t_idx| {
            std.debug.assert(t_idx < self.sheet.tags.len);
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

        // Default: loop all frames forward
        self.current_frame = (self.current_frame + 1) % self.sheet.frame_count;
    }

    pub fn stageCurrentFrameWithQueue(self: *AnimatedSprite, custom_queue: ?*dma_queue.DmaQueue) void {
        if (self.mode == .streaming) {
            const alloc_res = self.vram_alloc orelse return;
            const bytes_per_frame = @as(usize, self.sheet.tile_count_per_frame) * (if (self.sheet.bpp == .bpp4) hal.specs.Tile.BYTES_4BPP else hal.specs.Tile.BYTES_8BPP);
            const start = self.current_frame * bytes_per_frame;

            // Invariant: current_frame is guaranteed to be within 0..sheet.frame_count - 1.
            std.debug.assert(start + bytes_per_frame <= self.sheet.tiles.len);

            const frame_src = self.sheet.tiles.ptr + start;
            const dest_ptr = alloc_res.toVramPointer(hal.specs.MemorySections.OBJ_VRAM);

            const q = custom_queue orelse &dma_queue.global_queue;
            _ = q.enqueueBytes(frame_src, @ptrCast(dest_ptr), @as(u16, @intCast(bytes_per_frame))) catch {};
        }
    }

    /// Advances the animation frame timer by 1 tick (~16.6ms at 60Hz).
    pub fn update(self: *AnimatedSprite) void {
        self.updateWithQueue(null);
    }

    /// Advances the animation frame timer with an explicit custom DMA queue (internal for testing).
    pub fn updateWithQueue(self: *AnimatedSprite, custom_queue: ?*dma_queue.DmaQueue) void {
        if (!self.is_playing or self.sheet.frame_count <= 1) return;

        self.frame_timer += 1;

        // Calculate ticks from duration_ms (60 FPS -> ~16.6ms per tick)
        const duration_ms = if (self.sheet.durations_ms.len > 0) blk: {
            std.debug.assert(self.current_frame < self.sheet.durations_ms.len);
            break :blk self.sheet.durations_ms[self.current_frame];
        } else DEFAULT_FRAME_DURATION_MS;
        const ticks: u16 = @max(1, @as(u16, @intCast((duration_ms + (MS_PER_TICK_APPROX / 2)) / MS_PER_TICK_APPROX)));

        if (self.frame_timer >= ticks) {
            self.frame_timer = 0;
            self.advanceFrame();
            self.stageCurrentFrameWithQueue(custom_queue);
        }
    }

    /// Derives the current hardware tile_index in VRAM.
    pub fn getTileIndex(self: *const AnimatedSprite) u16 {
        if (self.mode == .streaming) {
            std.debug.assert(self.vram_alloc != null);
            return self.vram_alloc.?.tile_index;
        } else {
            const tile_step = if (self.sheet.bpp == .bpp4)
                self.sheet.tile_count_per_frame
            else
                self.sheet.tile_count_per_frame * 2;
            return @as(u16, @intCast(self.current_frame)) * tile_step;
        }
    }

    /// Compiles into a GBA hardware OAM attribute.
    pub fn toOamAttr(self: *const AnimatedSprite) hal.oam.ObjAttr {
        const tile_idx = self.getTileIndex();
        return compileOamAttr(&self.sprite, tile_idx, self.palette_bank, self.sheet.bpp);
    }

    /// Accesses the underlying Sprite component.
    pub fn getSprite(self: *AnimatedSprite) *Sprite {
        return &self.sprite;
    }
};

// ====================================================================
// Unit Tests
// ====================================================================

test "SPR001: init validates dimensions" {
    const spr = try Sprite.init(Fixed24_8.fromInt(10), Fixed24_8.fromInt(20), 8, 8);
    try std.testing.expectEqual(@as(u16, 8), spr.aabb.width);
    try std.testing.expectEqual(@as(u16, 8), spr.aabb.height);

    try std.testing.expectError(SpriteError.InvalidDimensions, Sprite.init(Fixed24_8.fromInt(10), Fixed24_8.fromInt(20), 12, 12));
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

test "SPR004: compileOamAttr encoding" {
    var spr = try Sprite.init(Fixed24_8.fromInt(10), Fixed24_8.fromInt(20), 16, 32); // Vertical (shape 2, size 2)

    const attr = compileOamAttr(&spr, 4, 2, .bpp4);
    // attr0: Y=20 (0x14), shape=2 -> (2 << 14) | 20 = 0x8014
    try std.testing.expectEqual(@as(u16, 0x8014), attr.attr0);
    // attr1: X=10 (0x0A), size=2 -> (2 << 14) | 10 = 0x800A
    try std.testing.expectEqual(@as(u16, 0x800A), attr.attr1);
    // attr2: tile_index=4, palette_bank=2 -> (2 << 12) | 4 = 0x2004
    try std.testing.expectEqual(@as(u16, 0x2004), attr.attr2);
}

test "SPR006: StaticSprite fillSolidColorToBuffers mock buffer" {
    var mock_vram: [1024]u16 = [_]u16{0} ** 1024;
    var mock_palram: [256]u16 = [_]u16{0} ** 256;

    const fill_spr = try StaticSprite.init(Fixed24_8.fromInt(0), Fixed24_8.fromInt(0), 16, 8, .{
        .tile_index = 2,
        .palette_bank = 1,
    });

    try fill_spr.fillSolidColorToBuffers(&mock_vram, &mock_palram, Color.RED);

    // Palette bank 1, color index 1 -> offset (1 * 16 + 1) = 17
    try std.testing.expectEqual(hal.Color.RED, mock_palram[17]);

    // Words for 2 4bpp tiles = 2 * 16 = 32 words starting at tile index 2 (word offset 32)
    try std.testing.expectEqual(hal.specs.Tile.SOLID_COLOR_1_PATTERN_4BPP, mock_vram[32]);
    try std.testing.expectEqual(hal.specs.Tile.SOLID_COLOR_1_PATTERN_4BPP, mock_vram[32 + 31]);
}

fn mockWallAtTile3_0(tx: u16, ty: u16) bool {
    return tx == 3 and ty == 0;
}

test "SPR007: Sprite moveAndCollide stops against map obstacles" {
    const map = CollisionMap.init(.size_256x256, mockWallAtTile3_0, .solid);

    // Sprite at x=8, y=0, size 8x8 (tile 1, 0)
    var spr = try Sprite.init(Fixed24_8.fromInt(8), Fixed24_8.fromInt(0), 8, 8);
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
    const spr1 = try Sprite.init(Fixed24_8.fromInt(10), Fixed24_8.fromInt(10), 16, 16);
    const spr2 = try Sprite.init(Fixed24_8.fromInt(20), Fixed24_8.fromInt(20), 16, 16);
    const spr3 = try Sprite.init(Fixed24_8.fromInt(50), Fixed24_8.fromInt(50), 16, 16);

    try std.testing.expect(spr1.aabb.isColliding(spr2.aabb));
    try std.testing.expect(spr1.aabb.collidesWith(spr2.aabb));
    try std.testing.expect(!spr1.aabb.isColliding(spr3.aabb));
}

test "SPR009: Sprite layer and mask filtering" {
    var player = try Sprite.init(Fixed24_8.fromInt(0), Fixed24_8.fromInt(0), 16, 16);
    player.layer = Collision.layer(0); // Layer 0: Player
    player.mask = Collision.layer(1); // Mask: Only Enemy (Layer 1)

    var enemy = try Sprite.init(Fixed24_8.fromInt(0), Fixed24_8.fromInt(0), 16, 16);
    enemy.layer = Collision.layer(1); // Layer 1: Enemy
    enemy.mask = Collision.layer(0); // Mask: Only Player (Layer 0)

    var item = try Sprite.init(Fixed24_8.fromInt(0), Fixed24_8.fromInt(0), 8, 8);
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
    var spr = try Sprite.init(Fixed24_8.fromInt(10), Fixed24_8.fromInt(20), 16, 16);
    spr.h_flip = true;
    spr.v_flip = true;

    const attr = compileOamAttr(&spr, 0, 0, .bpp4);
    const expected_attr1: u16 = 10 | (1 << 14) | (1 << 12) | (1 << 13);
    try std.testing.expectEqual(expected_attr1, attr.attr1);
}

test "SPR011: toOamAttr 8-bpp color mode encoding" {
    const spr = try Sprite.init(Fixed24_8.fromInt(10), Fixed24_8.fromInt(20), 32, 32);

    const attr = compileOamAttr(&spr, 0, 0, .bpp8);
    const expected_attr0: u16 = 20 | (1 << 13);
    try std.testing.expectEqual(expected_attr0, attr.attr0);
}

test "SPR013: StaticSprite composition and toOamAttr output" {
    const static_spr = try StaticSprite.init(Fixed24_8.fromInt(15), Fixed24_8.fromInt(25), 32, 16, .{
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

test "SPR014: StaticSprite composition and toOamAttr with custom palette bank" {
    const solid_spr = try StaticSprite.init(Fixed24_8.fromInt(5), Fixed24_8.fromInt(10), 8, 8, .{
        .tile_index = 1,
        .palette_bank = 2,
    });

    try std.testing.expectEqual(@as(u16, 1), solid_spr.tile_index);
    try std.testing.expectEqual(@as(u4, 2), solid_spr.palette_bank);

    const attr = solid_spr.toOamAttr();
    try std.testing.expectEqual(@as(u16, 10), attr.attr0);
    try std.testing.expectEqual(@as(u16, 5), attr.attr1);
    try std.testing.expectEqual(@as(u16, (2 << 12) | 1), attr.attr2);
}

fn mockAllPassable(_: u16, _: u16) bool {
    return false;
}

test "SPR015: moveAndCollide boundary handling in all 4 directions across solid and empty maps" {
    const map_solid = CollisionMap.init(.size_256x256, mockAllPassable, .solid);
    const map_empty = CollisionMap.init(.size_256x256, mockAllPassable, .empty);

    // 1. Move Left across boundary x=0 (x: 4 -> -4, span [-4, 4))
    {
        var spr_solid = try Sprite.init(Fixed24_8.fromInt(4), Fixed24_8.fromInt(64), 8, 8);
        spr_solid.velocity_x = Fixed24_8.fromInt(-8);
        const res_solid = spr_solid.moveAndCollide(map_solid);
        try std.testing.expect(res_solid.collided_x);
        try std.testing.expectEqual(@as(i32, 4), spr_solid.aabb.x.toInt());
        try std.testing.expectEqual(Fixed24_8.zero.raw, spr_solid.velocity_x.raw);

        var spr_empty = try Sprite.init(Fixed24_8.fromInt(4), Fixed24_8.fromInt(64), 8, 8);
        spr_empty.velocity_x = Fixed24_8.fromInt(-8);
        const res_empty = spr_empty.moveAndCollide(map_empty);
        try std.testing.expect(!res_empty.collided_x);
        try std.testing.expectEqual(@as(i32, -4), spr_empty.aabb.x.toInt());
    }

    // 2. Move Up across boundary y=0 (y: 4 -> -4, span [-4, 4))
    {
        var spr_solid = try Sprite.init(Fixed24_8.fromInt(64), Fixed24_8.fromInt(4), 8, 8);
        spr_solid.velocity_y = Fixed24_8.fromInt(-8);
        const res_solid = spr_solid.moveAndCollide(map_solid);
        try std.testing.expect(res_solid.collided_y);
        try std.testing.expectEqual(@as(i32, 4), spr_solid.aabb.y.toInt());
        try std.testing.expectEqual(Fixed24_8.zero.raw, spr_solid.velocity_y.raw);

        var spr_empty = try Sprite.init(Fixed24_8.fromInt(64), Fixed24_8.fromInt(4), 8, 8);
        spr_empty.velocity_y = Fixed24_8.fromInt(-8);
        const res_empty = spr_empty.moveAndCollide(map_empty);
        try std.testing.expect(!res_empty.collided_y);
        try std.testing.expectEqual(@as(i32, -4), spr_empty.aabb.y.toInt());
    }

    // 3. Move Right across boundary x=256 (x: 250 -> 258, right edge 266, span [258, 266))
    {
        var spr_solid = try Sprite.init(Fixed24_8.fromInt(250), Fixed24_8.fromInt(64), 8, 8);
        spr_solid.velocity_x = Fixed24_8.fromInt(8);
        const res_solid = spr_solid.moveAndCollide(map_solid);
        try std.testing.expect(res_solid.collided_x);
        try std.testing.expectEqual(@as(i32, 250), spr_solid.aabb.x.toInt());
        try std.testing.expectEqual(Fixed24_8.zero.raw, spr_solid.velocity_x.raw);

        var spr_empty = try Sprite.init(Fixed24_8.fromInt(250), Fixed24_8.fromInt(64), 8, 8);
        spr_empty.velocity_x = Fixed24_8.fromInt(8);
        const res_empty = spr_empty.moveAndCollide(map_empty);
        try std.testing.expect(!res_empty.collided_x);
        try std.testing.expectEqual(@as(i32, 258), spr_empty.aabb.x.toInt());
    }

    // 4. Move Down across boundary y=256 (y: 250 -> 258, bottom edge 266, span [258, 266))
    {
        var spr_solid = try Sprite.init(Fixed24_8.fromInt(64), Fixed24_8.fromInt(250), 8, 8);
        spr_solid.velocity_y = Fixed24_8.fromInt(8);
        const res_solid = spr_solid.moveAndCollide(map_solid);
        try std.testing.expect(res_solid.collided_y);
        try std.testing.expectEqual(@as(i32, 250), spr_solid.aabb.y.toInt());
        try std.testing.expectEqual(Fixed24_8.zero.raw, spr_solid.velocity_y.raw);

        var spr_empty = try Sprite.init(Fixed24_8.fromInt(64), Fixed24_8.fromInt(250), 8, 8);
        spr_empty.velocity_y = Fixed24_8.fromInt(8);
        const res_empty = spr_empty.moveAndCollide(map_empty);
        try std.testing.expect(!res_empty.collided_y);
        try std.testing.expectEqual(@as(i32, 258), spr_empty.aabb.y.toInt());
    }
}

test "ANI001: AnimatedSprite init with streaming mode allocates 1-frame VRAM slot" {
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
        .tags = &[_]AnimationTag{},
    };

    var anim_spr = try AnimatedSprite.init(&dummy_sheet, .streaming, Fixed24_8.zero, Fixed24_8.zero);
    defer anim_spr.deinit();

    try std.testing.expect(anim_spr.vram_alloc != null);
    try std.testing.expectEqual(@as(u16, 4), anim_spr.vram_alloc.?.tile_count);
}

test "ANI002: AnimatedSprite init with static mode uses base tile_index and advances with frame" {
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

    var anim_spr = try AnimatedSprite.init(&dummy_sheet, .static, Fixed24_8.zero, Fixed24_8.zero);
    defer anim_spr.deinit();

    try std.testing.expect(anim_spr.vram_alloc == null);
    try std.testing.expectEqual(@as(u16, 0), anim_spr.getTileIndex());

    anim_spr.advanceFrame();
    try std.testing.expectEqual(@as(u16, 4), anim_spr.getTileIndex());
}

test "ANI003: AnimatedSprite setAnimation and setAnimationByIndex select tag and reset frame" {
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
            .{ .name = "run", .from_frame = 2, .to_frame = 3, .direction = .forward },
        },
    };

    var anim_spr = try AnimatedSprite.init(&dummy_sheet, .static, Fixed24_8.zero, Fixed24_8.zero);
    defer anim_spr.deinit();

    try anim_spr.setAnimation("run");
    try std.testing.expectEqual(@as(usize, 2), anim_spr.current_frame);
    try std.testing.expectEqual(@as(u16, 8), anim_spr.getTileIndex());

    anim_spr.advanceFrame();
    try std.testing.expectEqual(@as(usize, 3), anim_spr.current_frame);

    // Loops back to from_frame (2)
    anim_spr.advanceFrame();
    try std.testing.expectEqual(@as(usize, 2), anim_spr.current_frame);

    try anim_spr.setAnimationByIndex(0);
    try std.testing.expectEqual(@as(usize, 0), anim_spr.current_frame);
}

test "ANI004: AnimatedSprite updateWithQueue advances frame on timer expiration and stages DMA" {
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
        .durations_ms = &[_]u16{ 32, 32 }, // 2 ticks per frame
        .tags = &[_]AnimationTag{
            .{ .name = "walk", .from_frame = 0, .to_frame = 1, .direction = .forward },
        },
    };

    var anim_spr = try AnimatedSprite.init(&dummy_sheet, .streaming, Fixed24_8.zero, Fixed24_8.zero);
    defer anim_spr.deinit();
    try anim_spr.setAnimation("walk");

    // Clear initial stage transfer from init/setAnimation
    test_queue.flush();

    // Tick 1 (16ms) -> Still frame 0
    anim_spr.updateWithQueue(&test_queue);
    try std.testing.expectEqual(@as(usize, 0), anim_spr.current_frame);
    try std.testing.expectEqual(@as(usize, 0), test_queue.task_count);

    // Tick 2 (32ms) -> Advances to frame 1 and enqueues DMA
    anim_spr.updateWithQueue(&test_queue);
    try std.testing.expectEqual(@as(usize, 1), anim_spr.current_frame);
    try std.testing.expectEqual(@as(usize, 1), test_queue.task_count);
}

test "ANI005: AnimatedSprite deinit releases VRAM allocation back to buddy allocator" {
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

    var anim_spr = try AnimatedSprite.init(&dummy_sheet, .streaming, Fixed24_8.zero, Fixed24_8.zero);
    try std.testing.expectEqual(initial_free - 32, vram_allocator.getFreeTileCount());

    anim_spr.deinit();
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

    var anim_spr = try AnimatedSprite.init(&dummy_sheet, .static, Fixed24_8.zero, Fixed24_8.zero);
    defer anim_spr.deinit();
    try anim_spr.setAnimation("ping");

    try std.testing.expectEqual(@as(usize, 0), anim_spr.current_frame);
    anim_spr.advanceFrame();
    try std.testing.expectEqual(@as(usize, 1), anim_spr.current_frame);
    anim_spr.advanceFrame();
    try std.testing.expectEqual(@as(usize, 2), anim_spr.current_frame);

    // Pingpong reverse direction
    anim_spr.advanceFrame();
    try std.testing.expectEqual(@as(usize, 1), anim_spr.current_frame);
    anim_spr.advanceFrame();
    try std.testing.expectEqual(@as(usize, 0), anim_spr.current_frame);

    // Forward direction again
    anim_spr.advanceFrame();
    try std.testing.expectEqual(@as(usize, 1), anim_spr.current_frame);
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
        .tags = &[_]AnimationTag{
            .{ .name = "idle", .from_frame = 0, .to_frame = 1, .direction = .forward },
        },
    };

    var anim_spr = try AnimatedSprite.init(&dummy_sheet, .static, Fixed24_8.fromInt(20), Fixed24_8.fromInt(30));
    defer anim_spr.deinit();

    try anim_spr.setAnimation("idle");
    try std.testing.expectError(SpriteError.TagNotFound, anim_spr.setAnimation("non_existent"));

    try anim_spr.setAnimationByIndex(0);
    try std.testing.expectError(SpriteError.TagNotFound, anim_spr.setAnimationByIndex(5));

    try anim_spr.setFrame(1);
    try std.testing.expectError(SpriteError.InvalidFrameIndex, anim_spr.setFrame(10));

    const spr = anim_spr.getSprite();
    spr.h_flip = true;

    const attr = anim_spr.toOamAttr();
    try std.testing.expectEqual(@as(u16, 30), attr.attr0 & 0x00FF);
    try std.testing.expectEqual(@as(u16, 20 | (1 << 14) | (1 << 12)), attr.attr1);
}

test "ANI008: AnimatedSprite without tags loops all frames forward by default" {
    const dummy_tiles: [3 * 128]u8 align(4) = [_]u8{0} ** (3 * 128);
    const dummy_sheet = SpriteSheet{
        .bpp = .bpp4,
        .width = 16,
        .height = 16,
        .tile_count_per_frame = 4,
        .frame_count = 3,
        .tiles = &dummy_tiles,
        .durations_ms = &[_]u16{ 16, 16, 16 },
        .tags = &[_]AnimationTag{},
    };

    var anim_spr = try AnimatedSprite.init(&dummy_sheet, .static, Fixed24_8.zero, Fixed24_8.zero);
    defer anim_spr.deinit();

    try std.testing.expectEqual(@as(usize, 0), anim_spr.current_frame);
    anim_spr.advanceFrame();
    try std.testing.expectEqual(@as(usize, 1), anim_spr.current_frame);
    anim_spr.advanceFrame();
    try std.testing.expectEqual(@as(usize, 2), anim_spr.current_frame);
    anim_spr.advanceFrame();
    try std.testing.expectEqual(@as(usize, 0), anim_spr.current_frame);
}
