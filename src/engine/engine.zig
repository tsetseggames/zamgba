const builtin = @import("builtin");
const hal = @import("zamgba-hal");

pub const Sprite = @import("sprite.zig").Sprite;
pub const StaticSprite = @import("sprite.zig").StaticSprite;
pub const StaticTile = gfx2d.StaticTile;
pub const AnimationDirection = gfx2d.AnimationDirection;
pub const AnimationTag = gfx2d.AnimationTag;
pub const SpriteSheet = gfx2d.SpriteSheet;
pub const Color = gfx2d.Color;

pub var shadow_oam: [128]hal.oam.ObjAttr = undefined;
pub var sprite_count: usize = 0;
pub var is_initialized: bool = false;

/// Initializes the global engine state, resets subsystem allocators and queues, and configures hardware display registers.
pub fn initHardware() void {
    if (builtin.target.os.tag == .freestanding) {
        hal.display.setMode0();
        hal.display.enableSpriteLayer();
        hal.display.setSpriteMapping(.linear_1d);
        hal.display.writeRegister();
    }

    for (&shadow_oam) |*obj| {
        obj.* = .{
            .attr0 = 160, // Pushed offscreen
            .attr1 = 0,
            .attr2 = 0,
            .fill = 0,
        };
    }
    sprite_count = 0;
    vram_allocator.reset();
    dma_queue.global_queue.reset();
    is_initialized = true;
}

/// Completes the frame lifecycle:
/// 1. Waits for VBlank.
/// 2. Flushes staged DMA transfer queue to VRAM.
/// 3. Flushes staged shadow OAM to GBA hardware OAM.
/// 4. Resets dynamic frame sprite counter.
pub fn nextFrame() void {
    // Wait for VBlank
    hal.waitForVBlank();

    // Flush DMA transfers to VRAM during VBlank
    dma_queue.global_queue.flush();

    // Flush shadow memory to hardware
    const hw_oam = @as([*]volatile hal.oam.ObjAttr, @ptrCast(@alignCast(hal.MemorySections.OAM)));
    for (shadow_oam, 0..) |obj, i| {
        hw_oam[i] = obj;
    }

    // Reset the sprite count so the next frame draws from slot 0
    sprite_count = 0;
}

/// Enqueues a DMA memory transfer to be executed during the upcoming VBlank.
pub fn enqueueDmaTask(task: hal.dma.DmaTask) dma_queue.DmaQueueError!void {
    return dma_queue.global_queue.enqueue(task);
}

/// Enqueues a raw byte transfer via DMA to be executed during the upcoming VBlank.
pub fn enqueueDmaBytes(src: [*]const u8, dest: [*]volatile u8, bytes: u16) dma_queue.DmaQueueError!void {
    return dma_queue.global_queue.enqueueBytes(src, dest, bytes);
}

/// Sets the maximum bytes permitted for DMA streaming transfer in a single VBlank.
pub fn setDmaVblankBudget(bytes: usize) void {
    dma_queue.global_queue.setMaxBytesPerVblank(bytes);
}

/// Registers a sprite to be rendered in the current frame.
/// Dynamically maps the high-level sprite into the next available OAM slot.
pub fn drawSprite(spr: anytype) void {
    if (sprite_count >= 128) return; // GBA hardware limit
    const T = @TypeOf(spr);
    const PtrInfo = @typeInfo(T);
    const TargetType = if (PtrInfo == .pointer) PtrInfo.pointer.child else T;

    if (@hasDecl(TargetType, "toOamAttr")) {
        shadow_oam[sprite_count] = spr.toOamAttr();
        sprite_count += 1;
    }
}

/// Starts the game loop using the global engine singleton.
/// Supports either:
/// 1. A static namespace/type with a public `tick() void` function (e.g. `@This()`).
/// 2. An instantiated struct pointer with a public `tick(self) void` method (e.g. `&game`).
pub fn run(context: anytype) noreturn {
    const T = @TypeOf(context);
    if (T == type) {
        // Static namespace/file context
        const has_tick = @hasDecl(context, "tick");
        if (!has_tick) {
            @compileError("Context type must define a public 'tick() void' function.");
        }
        while (true) {
            context.tick();
            nextFrame();
        }
    } else {
        // Instantiated object context
        const PtrInfo = @typeInfo(T);
        if (PtrInfo != .pointer) {
            @compileError("engine.run must be passed a pointer for struct instances (e.g., &game).");
        }
        const ChildType = PtrInfo.pointer.child;
        const has_tick = @hasDecl(ChildType, "tick");
        if (!has_tick) {
            @compileError("Instance type must define a public 'tick() void' method.");
        }
        while (true) {
            context.tick();
            nextFrame();
        }
    }
}

pub const gfx2d = @import("gfx2d/gfx2d.zig");
pub const input = @import("input.zig");
pub const physics = @import("physics/physics.zig");
pub const vram_allocator = gfx2d.vram_allocator;
pub const dma_queue = gfx2d.dma_queue;
pub const AnimatedTiles = gfx2d.AnimatedTiles;
pub const AnimatedSprite = @import("animated_sprite.zig").AnimatedSprite;
pub const AnimationMode = gfx2d.AnimationMode;

test {
    _ = physics;
    _ = @import("sprite.zig");
    _ = gfx2d;
}

test "ENG001: Engine singleton initHardware and drawSprite staging" {
    const std = @import("std");
    initHardware();
    try std.testing.expect(is_initialized);
    try std.testing.expectEqual(@as(usize, 0), sprite_count);

    // Verify all 128 shadow OAM entries were pushed offscreen (attr0 = 160)
    for (shadow_oam) |obj| {
        try std.testing.expectEqual(@as(u16, 160), obj.attr0);
    }

    const test_spr = StaticSprite.init(10, 20, 8, 8, .{});
    drawSprite(&test_spr);
    try std.testing.expectEqual(@as(usize, 1), sprite_count);
    try std.testing.expectEqual(@as(u16, 20), shadow_oam[0].attr0 & 0x00FF);
    try std.testing.expectEqual(@as(u16, 10), shadow_oam[0].attr1 & 0x01FF);
}
