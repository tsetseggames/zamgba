const gba = @import("zamgba");
const hal = gba.hal;
const engine = gba.engine;

// The standard ROM header for the GBA BIOS
export var gameHeader linksection(".gba.header") = hal.setupROMHeader(
    "JOYPADINS",
    "AJPI",
    "00",
    0,
);

const Game = struct {
    spr: engine.Sprite,
    input: engine.input.InputState,
    current_color: engine.Color,

    pub fn tick(self: *@This()) void {
        self.input.update();

        const speed: i32 = 2;
        const max_x: i32 = hal.Screen.WIDTH_PIXELS - @as(i32, @intCast(self.spr.aabb.width));
        const max_y: i32 = hal.Screen.HEIGHT_PIXELS - @as(i32, @intCast(self.spr.aabb.height));

        var cur_x: i32 = @intCast(self.spr.aabb.x.toInt());
        var cur_y: i32 = @intCast(self.spr.aabb.y.toInt());
        var new_color: ?engine.Color = null;

        if (self.input.isPressed(.Left)) {
            cur_x -= speed;
            if (cur_x <= 0) {
                cur_x = 0;
                new_color = engine.Color.YELLOW;
            }
        }
        if (self.input.isPressed(.Right)) {
            cur_x += speed;
            if (cur_x >= max_x) {
                cur_x = max_x;
                new_color = engine.Color.GREEN;
            }
        }
        if (self.input.isPressed(.Up)) {
            cur_y -= speed;
            if (cur_y <= 0) {
                cur_y = 0;
                new_color = engine.Color.RED;
            }
        }
        if (self.input.isPressed(.Down)) {
            cur_y += speed;
            if (cur_y >= max_y) {
                cur_y = max_y;
                new_color = engine.Color.WHITE;
            }
        }

        self.spr.aabb.x = engine.physics.Fixed24_8.fromInt(@intCast(@max(0, cur_x)));
        self.spr.aabb.y = engine.physics.Fixed24_8.fromInt(@intCast(@max(0, cur_y)));

        if (new_color) |c| {
            if (c.r != self.current_color.r or c.g != self.current_color.g or c.b != self.current_color.b) {
                self.current_color = c;
                self.spr.fillSolidColor(c) catch {};
            }
        }

        engine.drawSprite(&self.spr);
    }
};

export fn main() noreturn {
    const spr_width: u16 = 16;
    const spr_height: u16 = 16;
    const start_x: u32 = @intCast((hal.Screen.WIDTH_PIXELS - @as(i32, @intCast(spr_width))) / 2);
    const start_y: u32 = @intCast((hal.Screen.HEIGHT_PIXELS - @as(i32, @intCast(spr_height))) / 2);

    var game = Game{
        .spr = engine.Sprite.init(start_x, start_y, spr_width, spr_height),
        .input = .{},
        .current_color = engine.Color.WHITE,
    };
    game.spr.tile_index = 0;
    game.spr.palette_bank = 0;

    game.spr.fillSolidColor(game.current_color) catch {};

    engine.run(&game);
}
