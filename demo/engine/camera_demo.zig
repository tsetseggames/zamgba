const gba = @import("zamgba");
const hal = gba.hal;
const engine = gba.engine;
const broom = @import("tsetseg_broom");
const large_dirt_map = @import("large_dirt_map");

const Fixed24_8 = engine.physics.Fixed24_8;

// The standard ROM header for the GBA BIOS
export var gameHeader linksection(".gba.header") = hal.setupROMHeader(
    "CAMERADEMO",
    "ACMD",
    "00",
    0,
);

const Game = struct {
    player: engine.AnimatedSprite,
    camera: engine.Camera2D,
    bg_layer: engine.TileMapLayer,
    input: engine.input.InputState = .{},
    use_smoothing: bool = true,
    use_drag_margin: bool = true,

    pub fn init() !Game {
        engine.log.info("Camera Demo: Starting init", .{});

        // 1. Load sprite palette into OBJ Palette RAM
        broom.sheet.loadPalette(null);

        // 2. Configure single Mode 0 Background layer (512x512 = 64x64 tiles)
        // Uses Charblock 0 for tileset graphics and 4 Screenblocks (16..19).
        var bg = engine.TileMapLayer{
            .bg_id = .bg0,
            .charblock = 0,
            .screenblock = 16,
            .size = .size_64x64,
            .data = &large_dirt_map.Level_0_Background_data,
            .priority = 0,
        };
        bg.initHardware();

        // 3. Initialize player AnimatedSprite in .static mode
        var player_spr = try engine.AnimatedSprite.init(
            &broom.sheet,
            .static,
            Fixed24_8.fromInt(120),
            Fixed24_8.fromInt(100),
            .{ .tile_index = 0 },
        );
        try player_spr.setAnimation("flying");

        // 4. Initialize Camera2D with 512x512 world limits, smooth lerping, and drag margin
        var cam = engine.Camera2D.init(Fixed24_8.zero, Fixed24_8.zero);
        cam.limits = .{
            .min_x = Fixed24_8.zero,
            .min_y = Fixed24_8.zero,
            .max_x = Fixed24_8.fromInt(512 - 240),
            .max_y = Fixed24_8.fromInt(512 - 160),
        };
        cam.smooth_speed = Fixed24_8.fromFloat(0.125);
        cam.drag_margin = .{
            .width = 64,
            .height = 48,
        };
        cam.centerOn(player_spr.sprite.aabb.x, player_spr.sprite.aabb.y);

        engine.log.info("Camera Demo: Init finished successfully", .{});

        return .{
            .player = player_spr,
            .camera = cam,
            .bg_layer = bg,
        };
    }

    pub fn tick(self: *@This()) void {
        self.input.update();

        // 1. Move player using D-Pad
        const speed: i32 = 2;
        var x = self.player.sprite.aabb.x.toInt();
        var y = self.player.sprite.aabb.y.toInt();

        if (self.input.isPressed(.Left)) {
            x -= speed;
            self.player.sprite.h_flip = true;
        }
        if (self.input.isPressed(.Right)) {
            x += speed;
            self.player.sprite.h_flip = false;
        }
        if (self.input.isPressed(.Up)) y -= speed;
        if (self.input.isPressed(.Down)) y += speed;

        // Screen / world boundary clamping (512x512 world, 32x32 sprite)
        const max_x: i32 = 512 - @as(i32, @intCast(self.player.sprite.aabb.width));
        const max_y: i32 = 512 - @as(i32, @intCast(self.player.sprite.aabb.height));
        if (x < 0) x = 0;
        if (x > max_x) x = max_x;
        if (y < 0) y = 0;
        if (y > max_y) y = max_y;

        self.player.sprite.aabb.x = Fixed24_8.fromInt(x);
        self.player.sprite.aabb.y = Fixed24_8.fromInt(y);

        // 2. Button A: Trigger camera screen shake
        if (self.input.isJustPressed(.A)) {
            self.camera.shake(Fixed24_8.fromInt(6), Fixed24_8.fromFloat(0.85));
        }

        // 3. Button B: Toggle position smoothing (Lerp vs Instant Snap)
        if (self.input.isJustPressed(.B)) {
            self.use_smoothing = !self.use_smoothing;
            self.camera.smooth_speed = if (self.use_smoothing) Fixed24_8.fromFloat(0.125) else Fixed24_8.zero;
        }

        // 4. Button Select: Toggle deadzone / drag margin
        if (self.input.isJustPressed(.Select)) {
            self.use_drag_margin = !self.use_drag_margin;
            self.camera.drag_margin = if (self.use_drag_margin) .{ .width = 64, .height = 48 } else null;
        }

        // 5. Update target tracking and camera interpolation
        self.camera.follow(self.player.sprite.aabb);
        self.camera.update();

        // 6. Synchronize camera viewport with background scroll register
        self.camera.applyToTileMap(&self.bg_layer);

        // 7. Update sprite animations
        self.player.update();

        // 8. Register active camera for automatic frustum culling and world-to-screen coordinate translation
        engine.setCamera(&self.camera);

        // 9. Draw sprites (engine automatically culls offscreen sprites)
        engine.drawSprite(&self.player);
    }
};

export fn main() noreturn {
    engine.initHardware();
    var game = Game.init() catch |err| {
        engine.log.fatal("Game.init failed: {s}", .{@errorName(err)});
        while (true) {}
    };
    engine.run(&game);
}
