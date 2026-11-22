const gba = @import("zamgba");
const hal = gba.hal;
const engine = gba.engine;
const broom = @import("tsetseg_broom");
const large_dirt_map = @import("large_dirt_map");

const CollisionMap = engine.physics.CollisionMap;
const Fixed24_8 = engine.physics.Fixed24_8;

// The standard ROM header for the GBA BIOS
export var gameHeader linksection(".gba.header") = hal.setupROMHeader(
    "TILECOLLISN",
    "ATCL",
    "00",
    0,
);

/// Checks whether a tile cell in the 64x64 grid is solid.
/// Dirt and BigRock layers are solid obstacles for the player.
fn isTileSolid(tx: u16, ty: u16) bool {
    if (tx >= 64 or ty >= 64) return true;
    const idx = @as(usize, ty) * 64 + tx;
    return large_dirt_map.Level_0_Dirt_entries[idx].tile_index != 0 or
        large_dirt_map.Level_0_BigRock_entries[idx].tile_index != 0;
}

const Game = struct {
    player: engine.AnimatedSprite,
    camera: engine.Camera2D,
    bg_layers: [4]engine.TileMapLayer,
    map: CollisionMap,
    input: engine.input.InputState = .{},

    pub fn init() !Game {
        engine.log.info("Tilemap Collision Demo: Starting init", .{});

        // 1. Load sprite palette into OBJ Palette RAM
        broom.sheet.loadPalette(null);

        // 2. Configure all 4 Mode 0 Background layers (512x512 text tilemaps = 64x64 tiles)
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

        // 3. Initialize player AnimatedSprite in .static mode at open coordinates (120, 100)
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

        // 5. Initialize 512x512 collision map for Dirt and BigRock obstacle testing
        const coll_map = CollisionMap.init(.size_512x512, isTileSolid, .solid);

        engine.log.info("Tilemap Collision Demo: Init finished successfully", .{});

        return .{
            .player = player_spr,
            .camera = cam,
            .bg_layers = .{ bg_grass, bg_rock, bg_dirt, bg_backdrop },
            .map = coll_map,
        };
    }

    pub fn tick(self: *@This()) void {
        self.input.update();

        // 1. Process D-Pad movement velocity
        const speed = Fixed24_8.fromInt(2);
        var vx = Fixed24_8.zero;
        var vy = Fixed24_8.zero;

        if (self.input.isPressed(.Left)) {
            vx = vx.sub(speed);
            self.player.sprite.h_flip = true;
        }
        if (self.input.isPressed(.Right)) {
            vx = vx.add(speed);
            self.player.sprite.h_flip = false;
        }
        if (self.input.isPressed(.Up)) vy = vy.sub(speed);
        if (self.input.isPressed(.Down)) vy = vy.add(speed);

        self.player.sprite.velocity_x = vx;
        self.player.sprite.velocity_y = vy;

        // 2. Move player and resolve tilemap collisions with wall sliding
        _ = self.player.sprite.moveAndCollide(self.map);

        // 3. Camera tracks player and updates background scroll registers
        self.camera.follow(self.player.sprite.aabb);
        self.camera.update();

        for (&self.bg_layers) |*layer| {
            self.camera.applyToTileMap(layer);
        }

        // 4. Update sprite animation frames
        self.player.update();

        // 5. Draw player sprite relative to active camera
        engine.setCamera(&self.camera);
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
