const std = @import("std");
const gba = @import("zamgba");
const engine = gba.engine;
const Collision = engine.physics.Collision;
const Fixed24_8 = engine.physics.Fixed24_8;

// Standard GBA ROM header
export var gameHeader linksection(".gba.header") = gba.hal.setupROMHeader(
    "PONG",
    "APNG",
    "00",
    0,
);

const PADDLE_W: u16 = 8;
const PADDLE_H: u16 = 32; // Standard GBA vertical 8x32 sprite (Shape.VERTICAL, Size.SIZE_1)
const BALL_SIZE: u16 = 8; // Standard GBA square 8x8 sprite

const SCREEN_W: i32 = 240;
const SCREEN_H: i32 = 160;

const PLAYER_X: u32 = 12;
const AI_X: u32 = 240 - 12 - PADDLE_W; // 220

const PADDLE_SPEED = Fixed24_8.fromInt(2); // 2.0 pixels/frame
const BALL_SPEED_X = Fixed24_8.fromFloat(2.25); // 2.25 pixels/frame
const BALL_SPEED_Y = Fixed24_8.fromFloat(1.5); // 1.5 pixels/frame

const Game = struct {
    player: engine.Sprite,
    ai: engine.Sprite,
    ball: engine.Sprite,
    input: engine.input.InputState,

    pub fn init() Game {
        var self = Game{
            .player = engine.Sprite.init(PLAYER_X, (SCREEN_H - PADDLE_H) / 2, PADDLE_W, PADDLE_H),
            .ai = engine.Sprite.init(AI_X, (SCREEN_H - PADDLE_H) / 2, PADDLE_W, PADDLE_H),
            .ball = engine.Sprite.init((SCREEN_W - BALL_SIZE) / 2, (SCREEN_H - BALL_SIZE) / 2, BALL_SIZE, BALL_SIZE),
            .input = .{},
        };

        // 16-bit collision layer assignments
        self.player.layer = Collision.layer(0); // Player layer
        self.player.mask = Collision.layer(2); // Interacts with Ball

        self.ai.layer = Collision.layer(1); // AI layer
        self.ai.mask = Collision.layer(2); // Interacts with Ball

        self.ball.layer = Collision.layer(2); // Ball layer
        self.ball.mask = Collision.layer(0) | Collision.layer(1);

        // Ball initial velocity
        self.ball.velocity_x = BALL_SPEED_X;
        self.ball.velocity_y = BALL_SPEED_Y;

        // Visual setup
        // Player: Green 8x32 paddle (4 tiles = 64 bytes)
        self.player.tile_index = 0;
        self.player.palette_bank = 0;
        self.player.fillSolidColor(engine.Color.GREEN) catch {};

        // AI: Red 8x32 paddle (4 tiles, starts at tile index 4)
        self.ai.tile_index = 4;
        self.ai.palette_bank = 1;
        self.ai.fillSolidColor(engine.Color.RED) catch {};

        // Ball: Yellow 8x8 square (1 tile, starts at tile index 8)
        self.ball.tile_index = 8;
        self.ball.palette_bank = 2;
        self.ball.fillSolidColor(engine.Color.YELLOW) catch {};

        return self;
    }

    pub fn resetBall(self: *@This(), serve_right: bool) void {
        self.ball.aabb.x = Fixed24_8.fromInt((SCREEN_W - BALL_SIZE) / 2);
        self.ball.aabb.y = Fixed24_8.fromInt((SCREEN_H - BALL_SIZE) / 2);
        self.ball.velocity_x = if (serve_right) BALL_SPEED_X else BALL_SPEED_X.neg();
        self.ball.velocity_y = BALL_SPEED_Y;
    }

    pub fn tick(self: *@This(), eng: *engine.Engine) void {
        self.input.update();

        // 1. Player paddle control (D-Pad Up / Down)
        var player_vy = Fixed24_8.zero;
        if (self.input.isPressed(.Up)) player_vy = player_vy.sub(PADDLE_SPEED);
        if (self.input.isPressed(.Down)) player_vy = player_vy.add(PADDLE_SPEED);

        const cur_player_y = self.player.aabb.y.toInt();
        const next_player_y = std.math.clamp(cur_player_y + player_vy.toInt(), 0, SCREEN_H - PADDLE_H);
        self.player.aabb.y = Fixed24_8.fromInt(next_player_y);

        // 2. AI paddle tracking logic
        const ball_center_y = self.ball.aabb.y.toInt() + BALL_SIZE / 2;
        const ai_center_y = self.ai.aabb.y.toInt() + PADDLE_H / 2;
        var ai_vy = Fixed24_8.zero;
        if (ai_center_y < ball_center_y - 2) {
            ai_vy = PADDLE_SPEED.sub(Fixed24_8.fromFloat(0.25)); // Slightly slower for balanced gameplay
        } else if (ai_center_y > ball_center_y + 2) {
            ai_vy = PADDLE_SPEED.sub(Fixed24_8.fromFloat(0.25)).neg();
        }

        const cur_ai_y = self.ai.aabb.y.toInt();
        const next_ai_y = std.math.clamp(cur_ai_y + ai_vy.toInt(), 0, SCREEN_H - PADDLE_H);
        self.ai.aabb.y = Fixed24_8.fromInt(next_ai_y);

        // 3. Move Ball with sub-pixel precision
        self.ball.aabb.x = self.ball.aabb.x.add(self.ball.velocity_x);
        self.ball.aabb.y = self.ball.aabb.y.add(self.ball.velocity_y);

        const cur_ball_x_px = self.ball.aabb.x.toInt();
        const cur_ball_y_px = self.ball.aabb.y.toInt();

        // 4. Ball bounce on top and bottom screen boundaries
        if (cur_ball_y_px <= 0) {
            self.ball.aabb.y = Fixed24_8.fromInt(0);
            self.ball.velocity_y = Fixed24_8{ .raw = @intCast(@abs(self.ball.velocity_y.raw)) };
        } else if (cur_ball_y_px >= SCREEN_H - BALL_SIZE) {
            self.ball.aabb.y = Fixed24_8.fromInt(SCREEN_H - BALL_SIZE);
            self.ball.velocity_y = Fixed24_8{ .raw = -@as(i32, @intCast(@abs(self.ball.velocity_y.raw))) };
        }

        // 5. Paddle vs Ball AABB collision
        if (self.player.aabb.isColliding(self.ball.aabb)) {
            // Ball hits Player paddle -> bounce right
            self.ball.aabb.x = Fixed24_8.fromInt(PLAYER_X + PADDLE_W);
            self.ball.velocity_x = Fixed24_8{ .raw = @intCast(@abs(self.ball.velocity_x.raw)) };
        } else if (self.ai.aabb.isColliding(self.ball.aabb)) {
            // Ball hits AI paddle -> bounce left
            self.ball.aabb.x = Fixed24_8.fromInt(AI_X - BALL_SIZE);
            self.ball.velocity_x = Fixed24_8{ .raw = -@as(i32, @intCast(@abs(self.ball.velocity_x.raw))) };
        }

        // 6. Goal scoring and ball reset
        if (cur_ball_x_px <= 0) {
            // Ball missed left paddle (AI scored) -> serve toward player
            self.resetBall(true);
        } else if (cur_ball_x_px >= SCREEN_W - BALL_SIZE) {
            // Ball missed right paddle (Player scored) -> serve toward AI
            self.resetBall(false);
        }

        // 7. Commit sprites to engine renderer
        eng.drawSprite(&self.player);
        eng.drawSprite(&self.ai);
        eng.drawSprite(&self.ball);
    }
};

export fn main() noreturn {
    var game = Game.init();
    var eng = engine.Engine.init();
    eng.run(&game);
}
