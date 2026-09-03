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

const PLAYER_X: i32 = 12;
const AI_X: i32 = 240 - 12 - @as(i32, @intCast(PADDLE_W)); // 220

const PADDLE_SPEED = Fixed24_8.fromInt(2); // 2.0 pixels/frame
const BALL_SPEED_X = Fixed24_8.fromFloat(2.25); // 2.25 pixels/frame
const BALL_SPEED_Y = Fixed24_8.fromFloat(1.5); // 1.5 pixels/frame

const Game = struct {
    player: engine.ColorFillSprite,
    ai: engine.ColorFillSprite,
    ball: engine.ColorFillSprite,
    input: engine.input.InputState,

    pub fn init() Game {
        var self = Game{
            .player = engine.ColorFillSprite.init(PLAYER_X, (SCREEN_H - PADDLE_H) / 2, PADDLE_W, PADDLE_H, .{
                .tile_index = 0,
                .palette_bank = 0,
            }),
            .ai = engine.ColorFillSprite.init(AI_X, (SCREEN_H - PADDLE_H) / 2, PADDLE_W, PADDLE_H, .{
                .tile_index = 4,
                .palette_bank = 1,
            }),
            .ball = engine.ColorFillSprite.init((SCREEN_W - BALL_SIZE) / 2, (SCREEN_H - BALL_SIZE) / 2, BALL_SIZE, BALL_SIZE, .{
                .tile_index = 8,
                .palette_bank = 2,
            }),
            .input = .{},
        };

        // 16-bit collision layer assignments
        self.player.sprite.layer = Collision.layer(0); // Player layer
        self.player.sprite.mask = Collision.layer(2); // Interacts with Ball

        self.ai.sprite.layer = Collision.layer(1); // AI layer
        self.ai.sprite.mask = Collision.layer(2); // Interacts with Ball

        self.ball.sprite.layer = Collision.layer(2); // Ball layer
        self.ball.sprite.mask = Collision.layer(0) | Collision.layer(1);

        // Ball initial velocity
        self.ball.sprite.velocity_x = BALL_SPEED_X;
        self.ball.sprite.velocity_y = BALL_SPEED_Y;

        // Visual setup
        // Player: Green 8x32 paddle (4 tiles = 64 bytes)
        self.player.fillSolidColor(engine.Color.GREEN) catch {};

        // AI: Red 8x32 paddle (4 tiles, starts at tile index 4)
        self.ai.fillSolidColor(engine.Color.RED) catch {};

        // Ball: Yellow 8x8 square (1 tile, starts at tile index 8)
        self.ball.fillSolidColor(engine.Color.YELLOW) catch {};

        return self;
    }

    pub fn resetBall(self: *@This(), serve_right: bool) void {
        self.ball.sprite.aabb.x = Fixed24_8.fromInt((SCREEN_W - BALL_SIZE) / 2);
        self.ball.sprite.aabb.y = Fixed24_8.fromInt((SCREEN_H - BALL_SIZE) / 2);
        self.ball.sprite.velocity_x = if (serve_right) BALL_SPEED_X else BALL_SPEED_X.neg();
        self.ball.sprite.velocity_y = BALL_SPEED_Y;
    }

    pub fn tick(self: *@This()) void {
        self.input.update();

        // 1. Player paddle control (D-Pad Up / Down)
        var player_vy = Fixed24_8.zero;
        if (self.input.isPressed(.Up)) player_vy = player_vy.sub(PADDLE_SPEED);
        if (self.input.isPressed(.Down)) player_vy = player_vy.add(PADDLE_SPEED);

        const cur_player_y = self.player.sprite.aabb.y.toInt();
        const next_player_y = std.math.clamp(cur_player_y + player_vy.toInt(), 0, SCREEN_H - PADDLE_H);
        self.player.sprite.aabb.y = Fixed24_8.fromInt(next_player_y);

        // 2. AI paddle tracking logic
        const ball_center_y = self.ball.sprite.aabb.y.toInt() + @as(i32, @intCast(BALL_SIZE)) / 2;
        const ai_center_y = self.ai.sprite.aabb.y.toInt() + @as(i32, @intCast(PADDLE_H)) / 2;
        var ai_vy = Fixed24_8.zero;
        if (ai_center_y < ball_center_y - 2) {
            ai_vy = PADDLE_SPEED.sub(Fixed24_8.fromFloat(0.25)); // Slightly slower for balanced gameplay
        } else if (ai_center_y > ball_center_y + 2) {
            ai_vy = PADDLE_SPEED.sub(Fixed24_8.fromFloat(0.25)).neg();
        }

        const cur_ai_y = self.ai.sprite.aabb.y.toInt();
        const next_ai_y = std.math.clamp(cur_ai_y + ai_vy.toInt(), 0, SCREEN_H - PADDLE_H);
        self.ai.sprite.aabb.y = Fixed24_8.fromInt(next_ai_y);

        // 3. Move Ball with sub-pixel precision
        self.ball.sprite.aabb.x = self.ball.sprite.aabb.x.add(self.ball.sprite.velocity_x);
        self.ball.sprite.aabb.y = self.ball.sprite.aabb.y.add(self.ball.sprite.velocity_y);

        const cur_ball_x_px = self.ball.sprite.aabb.x.toInt();
        const cur_ball_y_px = self.ball.sprite.aabb.y.toInt();

        // 4. Ball bounce on top and bottom screen boundaries
        if (cur_ball_y_px <= 0) {
            self.ball.sprite.aabb.y = Fixed24_8.fromInt(0);
            self.ball.sprite.velocity_y = Fixed24_8{ .raw = @intCast(@abs(self.ball.sprite.velocity_y.raw)) };
        } else if (cur_ball_y_px >= SCREEN_H - BALL_SIZE) {
            self.ball.sprite.aabb.y = Fixed24_8.fromInt(SCREEN_H - BALL_SIZE);
            self.ball.sprite.velocity_y = Fixed24_8{ .raw = -@as(i32, @intCast(@abs(self.ball.sprite.velocity_y.raw))) };
        }

        // 5. Paddle vs Ball AABB collision
        if (self.player.sprite.aabb.isColliding(self.ball.sprite.aabb)) {
            // Ball hits Player paddle -> bounce right
            self.ball.sprite.aabb.x = Fixed24_8.fromInt(PLAYER_X + PADDLE_W);
            self.ball.sprite.velocity_x = Fixed24_8{ .raw = @intCast(@abs(self.ball.sprite.velocity_x.raw)) };
        } else if (self.ai.sprite.aabb.isColliding(self.ball.sprite.aabb)) {
            // Ball hits AI paddle -> bounce left
            self.ball.sprite.aabb.x = Fixed24_8.fromInt(AI_X - @as(i32, @intCast(BALL_SIZE)));
            self.ball.sprite.velocity_x = Fixed24_8{ .raw = -@as(i32, @intCast(@abs(self.ball.sprite.velocity_x.raw))) };
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
        engine.drawSprite(&self.player);
        engine.drawSprite(&self.ai);
        engine.drawSprite(&self.ball);
    }
};

export fn main() noreturn {
    var game = Game.init();
    engine.run(&game);
}
