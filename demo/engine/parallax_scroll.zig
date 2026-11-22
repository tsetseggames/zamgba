const gba = @import("zamgba");
const hal = gba.hal;
const engine = gba.engine;
const broom = @import("tsetseg_broom");
const large_dirt_map = @import("large_dirt_map");

const Fixed24_8 = engine.physics.Fixed24_8;

// The standard ROM header for the GBA BIOS
export var gameHeader linksection(".gba.header") = hal.setupROMHeader(
    "PARALLAX",
    "APLX",
    "00",
    0,
);

const ParallaxLayer = struct {
    layer: engine.TileMapLayer,
    factor_x: Fixed24_8,
    factor_y: Fixed24_8,
};

const Game = struct {
    player: engine.AnimatedSprite,
    camera: engine.Camera2D,
    parallax_layers: [4]ParallaxLayer,
    input: engine.input.InputState = .{},
    use_smoothing: bool = true,

    pub fn init() !Game {
        engine.log.info("Parallax Scroll Demo: Starting init", .{});

        // 1. Load sprite palette into OBJ Palette RAM
        broom.sheet.loadPalette(null);

        // 2. Configure 4 Mode 0 Background layers (512x512 text tilemaps = 64x64 tiles)
        // All layers share Charblock 0 for tileset graphics.
        // Each 64x64 layer occupies 4 Screenblocks (2 KB * 4 = 8 KB).
        var bg_backdrop = engine.TileMapLayer{
            .bg_id = .bg3,
            .charblock = 0,
            .screenblock = 16,
            .size = .size_64x64,
            .data = &large_dirt_map.Level_0_Background_data,
            .priority = 3,
        };
        bg_backdrop.initHardware();

        var bg_dirt = engine.TileMapLayer{
            .bg_id = .bg2,
            .charblock = 0,
            .screenblock = 20,
            .size = .size_64x64,
            .data = &large_dirt_map.Level_0_Dirt_data,
            .priority = 2,
        };
        bg_dirt.initHardware();

        var bg_rock = engine.TileMapLayer{
            .bg_id = .bg1,
            .charblock = 0,
            .screenblock = 24,
            .size = .size_64x64,
            .data = &large_dirt_map.Level_0_BigRock_data,
            .priority = 1,
        };
        bg_rock.initHardware();

        var bg_grass = engine.TileMapLayer{
            .bg_id = .bg0,
            .charblock = 0,
            .screenblock = 28,
            .size = .size_64x64,
            .data = &large_dirt_map.Level_0_Grass_data,
            .priority = 0,
        };
        bg_grass.initHardware();

        // 3. Initialize player AnimatedSprite in .static mode
        var player_spr = try engine.AnimatedSprite.init(
            &broom.sheet,
            .static,
            Fixed24_8.fromInt(120),
            Fixed24_8.fromInt(100),
            .{ .tile_index = 0 },
        );
        try player_spr.preloadStaticTiles();
        try player_spr.setAnimation("flying");

        // 4. Initialize Camera2D with 512x512 world limits
        var cam = engine.Camera2D.init(Fixed24_8.zero, Fixed24_8.zero);
        cam.limits = .{
            .min_x = Fixed24_8.zero,
            .min_y = Fixed24_8.zero,
            .max_x = Fixed24_8.fromInt(512 - 240),
            .max_y = Fixed24_8.fromInt(512 - 160),
        };
        cam.smooth_speed = Fixed24_8.fromFloat(0.125);
        cam.centerOn(player_spr.sprite.aabb.x, player_spr.sprite.aabb.y);

        engine.log.info("Parallax Scroll Demo: Init finished successfully", .{});

        return .{
            .player = player_spr,
            .camera = cam,
            .parallax_layers = .{
                .{
                    .layer = bg_backdrop,
                    .factor_x = Fixed24_8.fromFloat(0.25),
                    .factor_y = Fixed24_8.fromFloat(0.25),
                },
                .{
                    .layer = bg_dirt,
                    .factor_x = Fixed24_8.fromFloat(0.75),
                    .factor_y = Fixed24_8.fromFloat(0.75),
                },
                .{
                    .layer = bg_rock,
                    .factor_x = Fixed24_8.fromFloat(0.50),
                    .factor_y = Fixed24_8.fromFloat(0.75), // Same with dirt
                },
                .{
                    .layer = bg_grass,
                    .factor_x = Fixed24_8.fromFloat(0.75),
                    .factor_y = Fixed24_8.fromFloat(0.75),
                },
            },
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

        // 4. Update target tracking and camera interpolation
        self.camera.follow(self.player.sprite.aabb);
        self.camera.update();

        // 5. Synchronize camera viewport with background scroll registers via parallax scaling
        for (&self.parallax_layers) |*item| {
            self.camera.applyToTileMapWithParallax(&item.layer, item.factor_x, item.factor_y);
        }

        // 6. Update sprite animations
        self.player.update();

        // 7. Register active camera for automatic frustum culling and world-to-screen coordinate translation
        engine.setCamera(&self.camera);

        // 8. Draw sprites (engine automatically culls offscreen sprites)
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
