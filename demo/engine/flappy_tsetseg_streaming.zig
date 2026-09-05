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
    enemies: [2]engine.StaticSprite,
    map: CollisionMap,
    input: engine.input.InputState,

    const PLAYER_START_X: i32 = 8;
    const PLAYER_START_Y: i32 = 64;

    const ENEMY_1_START_X: i32 = 90;
    const ENEMY_1_START_Y: i32 = 8;
    const ENEMY_2_START_X: i32 = 180;
    const ENEMY_2_START_Y: i32 = 100;

    const PLAYER_SPEED = Fixed24_8.fromInt(2);
    const ENEMY_1_SPEED_Y = Fixed24_8.fromInt(1);
    const ENEMY_2_SPEED_Y = Fixed24_8.fromInt(1);

    pub fn init() Game {
        // 1. Initialize Player using AnimatedSprite in streaming mode
        // Only 1 frame (32 slot units = 1024 bytes) is allocated in VRAM!
        var player_anim = engine.AnimatedSprite.init(&broom.sheet, .streaming, PLAYER_START_X, PLAYER_START_Y) catch unreachable;
        _ = player_anim.setAnimation("fly");

        // 2. Configure collision layers on the underlying Sprite
        const spr = player_anim.getSprite();
        spr.layer = Collision.layer(0); // Layer 0: Player
        spr.mask = Collision.layer(1); // Mask: Enemy

        var self = Game{
            .player = player_anim,
            .enemies = [_]engine.StaticSprite{
                engine.StaticSprite.init(ENEMY_1_START_X, ENEMY_1_START_Y, 16, 32, .{
                    .tile_index = 256,
                    .palette_bank = 1,
                }),
                engine.StaticSprite.init(ENEMY_2_START_X, ENEMY_2_START_Y, 16, 32, .{
                    .tile_index = 256,
                    .palette_bank = 1,
                }),
            },
            .map = CollisionMap.init(.size_256x256, isBorderSolid, .solid),
            .input = .{},
        };

        // Enemy collision configuration
        self.enemies[0].sprite.layer = Collision.layer(1); // Layer 1: Enemy
        self.enemies[0].sprite.mask = Collision.layer(0); // Mask: Player
        self.enemies[0].sprite.velocity_y = ENEMY_1_SPEED_Y;

        self.enemies[1].sprite.layer = Collision.layer(1);
        self.enemies[1].sprite.mask = Collision.layer(0);
        self.enemies[1].sprite.velocity_y = ENEMY_2_SPEED_Y;

        // Load 256-color palette to OBJ Palette RAM (0x05000200)
        const obj_pal = hal.MemorySections.PALRAM + 256;
        for (broom.palette, 0..) |col, i| {
            obj_pal[i] = col;
        }

        // Enemy visual setup (Red vertical pillars at Tile Index 256 in 4-bpp mode)
        self.enemies[0].fillSolidColor(engine.Color.RED) catch {};

        return self;
    }

    pub fn reset(self: *@This()) void {
        const spr = self.player.getSprite();
        spr.aabb.x = Fixed24_8.fromInt(PLAYER_START_X);
        spr.aabb.y = Fixed24_8.fromInt(PLAYER_START_Y);
        spr.velocity_x = Fixed24_8.zero;
        spr.velocity_y = Fixed24_8.zero;
        spr.h_flip = false;
        self.player.setFrame(0);

        self.enemies[0].sprite.aabb.x = Fixed24_8.fromInt(ENEMY_1_START_X);
        self.enemies[0].sprite.aabb.y = Fixed24_8.fromInt(ENEMY_1_START_Y);
        self.enemies[0].sprite.velocity_y = ENEMY_1_SPEED_Y;

        self.enemies[1].sprite.aabb.x = Fixed24_8.fromInt(ENEMY_2_START_X);
        self.enemies[1].sprite.aabb.y = Fixed24_8.fromInt(ENEMY_2_START_Y);
        self.enemies[1].sprite.velocity_y = ENEMY_2_SPEED_Y;
    }

    pub fn tick(self: *@This()) void {
        self.input.update();

        // 1. Process player directional input & horizontal flipping
        var vx = Fixed24_8.zero;
        var vy = Fixed24_8.zero;

        const player_spr = self.player.getSprite();

        if (self.input.isPressed(.Left)) {
            vx = vx.sub(PLAYER_SPEED);
            player_spr.h_flip = true; // Face left
        }
        if (self.input.isPressed(.Right)) {
            vx = vx.add(PLAYER_SPEED);
            player_spr.h_flip = false; // Face right
        }
        if (self.input.isPressed(.Up)) vy = vy.sub(PLAYER_SPEED);
        if (self.input.isPressed(.Down)) vy = vy.add(PLAYER_SPEED);

        player_spr.velocity_x = vx;
        player_spr.velocity_y = vy;

        // 2. Move player and block on screen border
        _ = player_spr.moveAndCollide(self.map);

        // 3. Move enemies vertically and bounce on screen border
        for (&self.enemies) |*enemy| {
            const initial_vy = enemy.sprite.velocity_y;
            const res = enemy.sprite.moveAndCollide(self.map);
            if (res.collided_y) {
                enemy.sprite.velocity_y = initial_vy.neg();
            }
        }

        // 4. Update animated sprite (advances timer & stages DMA streaming transfer on frame switch)
        self.player.update();

        // 5. Check player-enemy collision
        for (&self.enemies) |*enemy| {
            if (player_spr.canCollideWith(&enemy.sprite) and player_spr.aabb.isColliding(enemy.sprite.aabb)) {
                self.reset();
                break;
            }
        }

        // 6. Draw active sprites
        engine.drawSprite(&self.player);
        engine.drawSprite(&self.enemies[0]);
        engine.drawSprite(&self.enemies[1]);
    }
};

export fn main() noreturn {
    engine.initHardware();
    var game = Game.init();
    engine.run(&game);
}
