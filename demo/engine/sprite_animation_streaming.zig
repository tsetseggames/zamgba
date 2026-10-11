const gba = @import("zamgba");
const hal = gba.hal;
const engine = gba.engine;
const broom = @import("tsetseg_broom");

const Fixed24_8 = engine.physics.Fixed24_8;

// The standard ROM header for the GBA BIOS
export var gameHeader linksection(".gba.header") = hal.setupROMHeader(
    "ANIMSTRM",
    "AAST",
    "00",
    0,
);

const Game = struct {
    anim: engine.AnimatedSprite,
    input: engine.input.InputState = .{},

    pub fn init() !Game {
        engine.log.info("Sprite Animation Streaming Demo: Starting init", .{});

        // 1. Load 256-color palette to OBJ Palette RAM (0x05000200)
        const obj_pal = hal.MemorySections.OBJ_PALRAM;
        for (broom.palette, 0..) |col, i| {
            obj_pal[i] = col;
        }

        // 2. Initialize AnimatedSprite in .streaming mode (screen center: 104, 64)
        // In streaming mode, only 1 frame slot is allocated dynamically in VRAM.
        // Subsequent frames stream asynchronously from ROM into VRAM via DMA during VBlank.
        var anim_spr = try engine.AnimatedSprite.init(
            &broom.sheet,
            .streaming,
            Fixed24_8.fromInt(104),
            Fixed24_8.fromInt(64),
        );

        engine.log.info("AnimatedSprite initialized. Setting animation...", .{});
        try anim_spr.setAnimation("flying");
        engine.log.info("Game init finished successfully. DmaQueue count={d}", .{dma_queue_count()});

        return .{
            .anim = anim_spr,
        };
    }

    pub fn tick(self: *@This()) void {
        self.input.update();

        // 1. Move sprite using D-Pad
        const speed: i32 = 2;
        var x = self.anim.sprite.aabb.x.toInt();
        var y = self.anim.sprite.aabb.y.toInt();

        if (self.input.isPressed(.Left)) {
            x -= speed;
            self.anim.sprite.h_flip = true; // Face left
        }
        if (self.input.isPressed(.Right)) {
            x += speed;
            self.anim.sprite.h_flip = false; // Face right
        }
        if (self.input.isPressed(.Up)) y -= speed;
        if (self.input.isPressed(.Down)) y += speed;

        // Screen boundary clamping (32x32 sprite)
        const max_x: i32 = hal.Screen.WIDTH_PIXELS - @as(i32, @intCast(self.anim.sprite.aabb.width));
        const max_y: i32 = hal.Screen.HEIGHT_PIXELS - @as(i32, @intCast(self.anim.sprite.aabb.height));
        if (x < 0) x = 0;
        if (x > max_x) x = max_x;
        if (y < 0) y = 0;
        if (y > max_y) y = max_y;

        self.anim.sprite.aabb.x = Fixed24_8.fromInt(x);
        self.anim.sprite.aabb.y = Fixed24_8.fromInt(y);

        // 2. Button A: Toggle playback (play / pause)
        if (self.input.isJustPressed(.A)) {
            self.anim.is_playing = !self.anim.is_playing;
        }

        // 3. Button B: Advance single frame manually when paused
        if (self.input.isJustPressed(.B)) {
            self.anim.advanceFrame();
        }

        // 4. Advance animation frame timer (in .streaming mode, enqueues DMA transfer on frame advance)
        self.anim.update();

        // 5. Draw active sprite
        engine.drawSprite(&self.anim);
    }
};

fn dma_queue_count() usize {
    return engine.dma_queue.global_queue.count();
}

export fn main() noreturn {
    engine.initHardware();
    var game = Game.init() catch |err| {
        engine.log.fatal("Game.init failed: {s}", .{@errorName(err)});
        while (true) {}
    };
    engine.run(&game);
}
