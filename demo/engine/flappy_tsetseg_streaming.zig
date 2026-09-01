const gba = @import("zamgba");
const hal = gba.hal;
const engine = gba.engine;
const broom = @import("tsetseg_broom");

const Collision = engine.physics.Collision;
const CollisionMap = engine.physics.CollisionMap;
const Fixed24_8 = engine.physics.Fixed24_8;

// The standard ROM header for the GBA BIOS
export var gameHeader linksection(".gba.header") = hal.setupROMHeader(
    "FLAPPYSTRM",
    "AFTS",
    "00",
    0,
);

// Map definition: 240x160 screen space with solid boundaries (240px wide, 160px high)
fn isBorderSolid(tx: u16, ty: u16) bool {
    return tx >= 30 or ty >= 20;
}

const Game = struct {
    player: engine.AnimatedSprite,
    enemies: [2]engine.Sprite,
    map: CollisionMap,
    input: engine.input.InputState,

    const PLAYER_START_X: i32 = 8;
    const PLAYER_START_Y: i32 = 64;

    const ENEMY_1_START_X: i32 = 90;
    const ENEMY_1_START_Y: i32 = 8;
    // 1.25 pixels/frame vertical patrol velocity
    const ENEMY_1_SPEED_Y = Fixed24_8.fromFloat(1.25);

    const ENEMY_2_START_X: i32 = 170;
    const ENEMY_2_START_Y: i32 = 120;
    const ENEMY_2_SPEED_Y = Fixed24_8.fromFloat(-1.25);

    // 2.0 pixels/frame horizontal & vertical movement speed
    const PLAYER_SPEED = Fixed24_8.fromInt(2);

    pub fn init() Game {
        // 1. Initialize Player using AnimatedSprite in streaming mode
        // Only 1 frame (32 slot units = 1024 bytes) is allocated in VRAM!
        var player_anim = engine.AnimatedSprite.init(&broom.sheet, .streaming, PLAYER_START_X, PLAYER_START_Y) catch unreachable;
        _ = player_anim.play("fly");

        // 2. Configure collision layers on the underlying Sprite
        const spr = player_anim.getSprite();
        spr.layer = Collision.layer(0); // Layer 0: Player
        spr.mask = Collision.layer(1); // Mask: Enemy

        var self = Game{
            .player = player_anim,
            .enemies = [_]engine.Sprite{
                engine.Sprite.init(ENEMY_1_START_X, ENEMY_1_START_Y, 16, 32),
                engine.Sprite.init(ENEMY_2_START_X, ENEMY_2_START_Y, 16, 32),
            },
            .map = CollisionMap.init(.size_256x256, isBorderSolid, .solid),
            .input = .{},
        };

        // Enemy collision configuration
        self.enemies[0].layer = Collision.layer(1); // Layer 1: Enemy
        self.enemies[0].mask = Collision.layer(0); // Mask: Player
        self.enemies[0].velocity_y = ENEMY_1_SPEED_Y;

        self.enemies[1].layer = Collision.layer(1);
        self.enemies[1].mask = Collision.layer(0);
        self.enemies[1].velocity_y = ENEMY_2_SPEED_Y;

        // Load 256-color palette to OBJ Palette RAM (0x05000200)
        const obj_pal = hal.MemorySections.PALRAM + 256;
        for (broom.palette, 0..) |col, i| {
            obj_pal[i] = col;
        }

        // Enemy visual setup (Red vertical pillars at Tile Index 256 in 4-bpp mode)
        self.enemies[0].tile_index = 256;
        self.enemies[0].palette_bank = 1;
        self.enemies[0].fillSolidColor(engine.Color.RED) catch {};

        self.enemies[1].tile_index = 256;
        self.enemies[1].palette_bank = 1;

        return self;
    }

    pub fn reset(self: *@This()) void {
        const spr = self.player.getSprite();
        spr.aabb.x = Fixed24_8.fromInt(PLAYER_START_X);
        spr.aabb.y = Fixed24_8.fromInt(PLAYER_START_Y);
        spr.velocity_x = Fixed24_8.zero;
        spr.velocity_y = Fixed24_8.zero;
        self.player.h_flip = false;
        self.player.setFrame(0);

        self.enemies[0].aabb.x = Fixed24_8.fromInt(ENEMY_1_START_X);
        self.enemies[0].aabb.y = Fixed24_8.fromInt(ENEMY_1_START_Y);
        self.enemies[0].velocity_y = ENEMY_1_SPEED_Y;

        self.enemies[1].aabb.x = Fixed24_8.fromInt(ENEMY_2_START_X);
        self.enemies[1].aabb.y = Fixed24_8.fromInt(ENEMY_2_START_Y);
        self.enemies[1].velocity_y = ENEMY_2_SPEED_Y;
    }

    pub fn tick(self: *@This()) void {
        self.input.update();

        // 1. Process player directional input & horizontal flipping
        var vx = Fixed24_8.zero;
        var vy = Fixed24_8.zero;

        if (self.input.isPressed(.Left)) {
            vx = vx.sub(PLAYER_SPEED);
            self.player.h_flip = true; // Face left
        }
        if (self.input.isPressed(.Right)) {
            vx = vx.add(PLAYER_SPEED);
            self.player.h_flip = false; // Face right
        }
        if (self.input.isPressed(.Up)) vy = vy.sub(PLAYER_SPEED);
        if (self.input.isPressed(.Down)) vy = vy.add(PLAYER_SPEED);

        const player_spr = self.player.getSprite();
        player_spr.velocity_x = vx;
        player_spr.velocity_y = vy;

        // 2. Move player and block on screen border
        _ = player_spr.moveAndCollide(self.map);

        // 3. Move enemies vertically and bounce on screen border
        for (&self.enemies) |*enemy| {
            const initial_vy = enemy.velocity_y;
            const res = enemy.moveAndCollide(self.map);
            if (res.collided_y) {
                enemy.velocity_y = initial_vy.neg();
            }
        }

        // 4. Update animated sprite (advances timer & stages DMA streaming transfer on frame switch)
        self.player.update();

        // 5. Check player-enemy collision
        if (engine.physics.checkOverlap(player_spr, &self.enemies) != null) {
            self.reset();
        }

        // 6. Draw active sprites
        engine.drawSprite(player_spr);
        engine.drawSprite(&self.enemies[0]);
        engine.drawSprite(&self.enemies[1]);
    }
};

export fn main() noreturn {
    var game = Game.init();
    engine.run(&game);
}
