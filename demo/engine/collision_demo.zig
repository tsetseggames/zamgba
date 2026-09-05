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
    player: engine.StaticSprite,
    enemies: [2]engine.StaticSprite,
    map: CollisionMap,
    input: engine.input.InputState,

    const PLAYER_START_X: i32 = 0;
    const PLAYER_START_Y: i32 = 80;

    const ENEMY_1_START_X: i32 = 80; // 1/3 of screen width (240 / 3)
    const ENEMY_1_START_Y: i32 = 8;
    const ENEMY_2_START_X: i32 = 160; // 2/3 of screen width (240 * 2 / 3)
    const ENEMY_2_START_Y: i32 = 8;

    const PLAYER_SPEED = Fixed24_8.fromInt(1);
    const ENEMY_1_SPEED_Y = Fixed24_8.fromInt(1);
    const ENEMY_2_SPEED_Y = Fixed24_8.fromInt(2);

    pub fn init() Game {
        var self = Game{
            .player = engine.StaticSprite.init(PLAYER_START_X, PLAYER_START_Y, 8, 8, .{
                .tile_index = 0,
                .palette_bank = 0,
            }),
            .enemies = [_]engine.StaticSprite{
                engine.StaticSprite.init(ENEMY_1_START_X, ENEMY_1_START_Y, 8, 8, .{
                    .tile_index = 1,
                    .palette_bank = 1,
                }),
                engine.StaticSprite.init(ENEMY_2_START_X, ENEMY_2_START_Y, 8, 8, .{
                    .tile_index = 1,
                    .palette_bank = 1,
                }),
            },
            .map = CollisionMap.init(.size_256x256, isBorderSolid, .solid),
            .input = .{},
        };

        // Configure 16-bit collision layers
        self.player.sprite.layer = Collision.layer(0); // Layer 0: Player
        self.player.sprite.mask = Collision.layer(1); // Mask: Enemy

        self.enemies[0].sprite.layer = Collision.layer(1); // Layer 1: Enemy
        self.enemies[0].sprite.mask = Collision.layer(0); // Mask: Player
        self.enemies[0].sprite.velocity_y = ENEMY_1_SPEED_Y;

        self.enemies[1].sprite.layer = Collision.layer(1);
        self.enemies[1].sprite.mask = Collision.layer(0);
        self.enemies[1].sprite.velocity_y = ENEMY_2_SPEED_Y;

        // Visual setup (Yellow for player, Red for enemies)
        self.player.fillSolidColor(engine.Color.YELLOW) catch {};
        self.enemies[0].fillSolidColor(engine.Color.RED) catch {};

        return self;
    }

    pub fn reset(self: *@This()) void {
        self.player.sprite.aabb.x = Fixed24_8.fromInt(PLAYER_START_X);
        self.player.sprite.aabb.y = Fixed24_8.fromInt(PLAYER_START_Y);
        self.player.sprite.velocity_x = Fixed24_8.zero;
        self.player.sprite.velocity_y = Fixed24_8.zero;

        self.enemies[0].sprite.aabb.x = Fixed24_8.fromInt(ENEMY_1_START_X);
        self.enemies[0].sprite.aabb.y = Fixed24_8.fromInt(ENEMY_1_START_Y);
        self.enemies[0].sprite.velocity_y = ENEMY_1_SPEED_Y;

        self.enemies[1].sprite.aabb.x = Fixed24_8.fromInt(ENEMY_2_START_X);
        self.enemies[1].sprite.aabb.y = Fixed24_8.fromInt(ENEMY_2_START_Y);
        self.enemies[1].sprite.velocity_y = ENEMY_2_SPEED_Y;
    }

    pub fn tick(self: *@This()) void {
        self.input.update();

        // 1. Process player input velocity
        var vx = Fixed24_8.zero;
        var vy = Fixed24_8.zero;

        if (self.input.isPressed(.Left)) vx = vx.sub(PLAYER_SPEED);
        if (self.input.isPressed(.Right)) vx = vx.add(PLAYER_SPEED);
        if (self.input.isPressed(.Up)) vy = vy.sub(PLAYER_SPEED);
        if (self.input.isPressed(.Down)) vy = vy.add(PLAYER_SPEED);

        self.player.sprite.velocity_x = vx;
        self.player.sprite.velocity_y = vy;

        // 2. Move player and resolve map border collisions
        _ = self.player.sprite.moveAndCollide(self.map);

        // 3. Move enemies vertically and bounce on map border collisions
        for (&self.enemies) |*enemy| {
            const initial_vy = enemy.sprite.velocity_y;
            const res = enemy.sprite.moveAndCollide(self.map);
            if (res.collided_y) {
                // Reverse direction on map wall collision
                enemy.sprite.velocity_y = initial_vy.neg();
            }
        }

        // 4. Check player-enemy collision
        for (&self.enemies) |*enemy| {
            if (self.player.sprite.canCollideWith(&enemy.sprite) and self.player.sprite.aabb.isColliding(enemy.sprite.aabb)) {
                self.reset();
                break;
            }
        }

        // 5. Draw all active sprites
        engine.drawSprite(&self.player);
        engine.drawSprite(&self.enemies[0]);
        engine.drawSprite(&self.enemies[1]);
    }
};

export fn main() noreturn {
    var game = Game.init();
    engine.run(&game);
}
