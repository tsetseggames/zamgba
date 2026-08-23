const gba = @import("zamgba");
const engine = gba.engine;
const Collision = engine.physics.Collision;
const CollisionMap = engine.physics.CollisionMap;
const Fixed24_8 = engine.physics.Fixed24_8;

// The standard ROM header for the GBA BIOS
export var gameHeader linksection(".gba.header") = gba.hal.setupROMHeader(
    "COLLISION",
    "ACOL",
    "00",
    0,
);

// Map definition: 240x160 screen space with solid boundaries
fn isBorderSolid(tx: u16, ty: u16) bool {
    // 30 tiles wide (240px) x 20 tiles high (160px)
    return tx >= 30 or ty >= 20;
}

const Game = struct {
    player: engine.Sprite,
    enemies: [2]engine.Sprite,
    map: CollisionMap,
    input: engine.input.InputState,

    const PLAYER_START_X: u32 = 0;
    const PLAYER_START_Y: u32 = 80;

    const ENEMY_1_START_X: u32 = 80;  // 1/3 of screen width (240 / 3)
    const ENEMY_1_START_Y: u32 = 8;
    const ENEMY_1_SPEED_Y: i32 = (1 << 8) + 128; // 1.5 pixels/frame

    const ENEMY_2_START_X: u32 = 160; // 2/3 of screen width (240 * 2 / 3)
    const ENEMY_2_START_Y: u32 = 144;
    const ENEMY_2_SPEED_Y: i32 = -((1 << 8) + 128); // -1.5 pixels/frame

    const PLAYER_SPEED: i32 = 2 << 8; // 2.0 pixels/frame

    pub fn init() Game {
        var self = Game{
            .player = engine.Sprite.init(PLAYER_START_X, PLAYER_START_Y, 8, 8),
            .enemies = [_]engine.Sprite{
                engine.Sprite.init(ENEMY_1_START_X, ENEMY_1_START_Y, 8, 8),
                engine.Sprite.init(ENEMY_2_START_X, ENEMY_2_START_Y, 8, 8),
            },
            .map = CollisionMap.init(.size_256x256, isBorderSolid, .solid),
            .input = .{},
        };

        // Configure 16-bit collision layers
        self.player.layer = Collision.layer(0); // Layer 0: Player
        self.player.mask = Collision.layer(1);  // Mask: Enemy

        self.enemies[0].layer = Collision.layer(1); // Layer 1: Enemy
        self.enemies[0].mask = Collision.layer(0);  // Mask: Player
        self.enemies[0].velocity_y = ENEMY_1_SPEED_Y;

        self.enemies[1].layer = Collision.layer(1);
        self.enemies[1].mask = Collision.layer(0);
        self.enemies[1].velocity_y = ENEMY_2_SPEED_Y;

        // Visual setup (Yellow for player, Red for enemies)
        self.player.tile_index = 0;
        self.player.palette_bank = 0;
        self.player.fillSolidColor(engine.Color.YELLOW) catch {};

        self.enemies[0].tile_index = 1;
        self.enemies[0].palette_bank = 1;
        self.enemies[0].fillSolidColor(engine.Color.RED) catch {};

        self.enemies[1].tile_index = 1; // Share the red tile
        self.enemies[1].palette_bank = 1;

        return self;
    }

    pub fn reset(self: *@This()) void {
        self.player.aabb.x = Fixed24_8.fromInt(PLAYER_START_X);
        self.player.aabb.y = Fixed24_8.fromInt(PLAYER_START_Y);
        self.player.velocity_x = 0;
        self.player.velocity_y = 0;

        self.enemies[0].aabb.x = Fixed24_8.fromInt(ENEMY_1_START_X);
        self.enemies[0].aabb.y = Fixed24_8.fromInt(ENEMY_1_START_Y);
        self.enemies[0].velocity_y = ENEMY_1_SPEED_Y;

        self.enemies[1].aabb.x = Fixed24_8.fromInt(ENEMY_2_START_X);
        self.enemies[1].aabb.y = Fixed24_8.fromInt(ENEMY_2_START_Y);
        self.enemies[1].velocity_y = ENEMY_2_SPEED_Y;
    }

    pub fn tick(self: *@This(), eng: *engine.Engine) void {
        self.input.update();

        // 1. Process player input velocity
        var vx: i32 = 0;
        var vy: i32 = 0;

        if (self.input.isPressed(.Left)) vx -= PLAYER_SPEED;
        if (self.input.isPressed(.Right)) vx += PLAYER_SPEED;
        if (self.input.isPressed(.Up)) vy -= PLAYER_SPEED;
        if (self.input.isPressed(.Down)) vy += PLAYER_SPEED;

        self.player.velocity_x = vx;
        self.player.velocity_y = vy;

        // 2. Move player and resolve map border collisions
        _ = self.player.moveAndCollide(self.map);

        // 3. Move enemies vertically and bounce on map border collisions
        for (&self.enemies) |*enemy| {
            const initial_vy = enemy.velocity_y;
            const res = enemy.moveAndCollide(self.map);
            if (res.collided_y) {
                // Reverse direction on map wall collision
                enemy.velocity_y = -initial_vy;
            }
        }

        // 4. Check player-enemy collision via physics.checkOverlap
        if (engine.physics.checkOverlap(&self.player, &self.enemies) != null) {
            self.reset();
        }

        // 5. Draw all active sprites
        eng.drawSprite(&self.player);
        eng.drawSprite(&self.enemies[0]);
        eng.drawSprite(&self.enemies[1]);
    }
};

export fn main() noreturn {
    var game = Game.init();
    var eng = engine.Engine.init();
    eng.run(&game);
}
