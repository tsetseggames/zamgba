const gba = @import("zamgba");
const hal = gba.hal;
const engine = gba.engine;
const broom = @import("tsetseg_broom");

const Collision = engine.physics.Collision;
const CollisionMap = engine.physics.CollisionMap;
const Fixed24_8 = engine.physics.Fixed24_8;

// The standard ROM header for the GBA BIOS
export var gameHeader linksection(".gba.header") = hal.setupROMHeader(
    "FLAPPYTSET",
    "AFTT",
    "00",
    0,
);

// Map definition: 240x160 screen space with solid boundaries (240px wide, 160px high)
fn isBorderSolid(tx: u16, ty: u16) bool {
    return tx >= 30 or ty >= 20;
}

const Game = struct {
    player: engine.Sprite,
    enemies: [2]engine.Sprite,
    map: CollisionMap,
    input: engine.input.InputState,

    anim_frame: u16 = 0,
    anim_timer: u16 = 0,

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
    const FRAME_DURATION_TICKS: u16 = 6; // 6 frames at 60Hz ~= 100ms per animation frame

    // In GBA 1D 8-bpp mapping, a 32x32 sprite (1024 bytes) advances by 32 tile index units per frame
    const TILES_PER_FRAME_8BPP: u16 = 32;

    pub fn init() Game {
        var self = Game{
            // Player is 32x32 matching the flying animation bounding box
            .player = engine.Sprite.init(PLAYER_START_X, PLAYER_START_Y, 32, 32),
            .enemies = [_]engine.Sprite{
                engine.Sprite.init(ENEMY_1_START_X, ENEMY_1_START_Y, 16, 32),
                engine.Sprite.init(ENEMY_2_START_X, ENEMY_2_START_Y, 16, 32),
            },
            .map = CollisionMap.init(.size_256x256, isBorderSolid, .solid),
            .input = .{},
        };

        // Configure collision layers
        self.player.layer = Collision.layer(0); // Layer 0: Player
        self.player.mask = Collision.layer(1); // Mask: Enemy

        self.enemies[0].layer = Collision.layer(1); // Layer 1: Enemy
        self.enemies[0].mask = Collision.layer(0); // Mask: Player
        self.enemies[0].velocity_y = ENEMY_1_SPEED_Y;

        self.enemies[1].layer = Collision.layer(1);
        self.enemies[1].mask = Collision.layer(0);
        self.enemies[1].velocity_y = ENEMY_2_SPEED_Y;

        // Configure visual modes
        self.player.bpp = .bpp8;
        self.player.tile_index = 0;
        self.player.palette_bank = 0;
        self.player.h_flip = false; // Default: faces right

        // Load 256-color palette to OBJ Palette RAM (0x05000200)
        const obj_pal = hal.MemorySections.PALRAM + 256;
        for (broom.palette, 0..) |col, i| {
            obj_pal[i] = col;
        }

        // Load all 8 animation frames (8KB = 4096 words) to OBJ VRAM (0x06010000)
        const obj_vram = hal.MemorySections.VRAM + 32768;
        const raw_tile_words = @as([*]const u16, @ptrCast(@alignCast(broom.raw_tiles.ptr)));
        const total_words = broom.raw_tiles.len / 2;
        for (0..total_words) |i| {
            obj_vram[i] = raw_tile_words[i];
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
        self.player.aabb.x = Fixed24_8.fromInt(PLAYER_START_X);
        self.player.aabb.y = Fixed24_8.fromInt(PLAYER_START_Y);
        self.player.velocity_x = Fixed24_8.zero;
        self.player.velocity_y = Fixed24_8.zero;
        self.player.h_flip = false;
        self.anim_frame = 0;
        self.anim_timer = 0;

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

        self.player.velocity_x = vx;
        self.player.velocity_y = vy;

        // 2. Move player and block on screen border
        _ = self.player.moveAndCollide(self.map);

        // 3. Move enemies vertically and bounce on screen border
        for (&self.enemies) |*enemy| {
            const initial_vy = enemy.velocity_y;
            const res = enemy.moveAndCollide(self.map);
            if (res.collided_y) {
                enemy.velocity_y = initial_vy.neg();
            }
        }

        // 4. Advance animation cycle (8 frames, looping)
        self.anim_timer += 1;
        if (self.anim_timer >= FRAME_DURATION_TICKS) {
            self.anim_timer = 0;
            self.anim_frame = (self.anim_frame + 1) % broom.frame_count;
        }
        self.player.tile_index = self.anim_frame * TILES_PER_FRAME_8BPP;

        // 5. Check player-enemy collision
        if (engine.physics.checkOverlap(&self.player, &self.enemies) != null) {
            self.reset();
        }

        // 6. Draw active sprites
        engine.drawSprite(&self.player);
        engine.drawSprite(&self.enemies[0]);
        engine.drawSprite(&self.enemies[1]);
    }
};

export fn main() noreturn {
    var game = Game.init();
    engine.run(&game);
}
