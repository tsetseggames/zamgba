const gba = @import("zamgba");
const hal = gba.hal;
const engine = gba.engine;

// The standard ROM header for the GBA BIOS
export var gameHeader linksection(".gba.header") = hal.setupROMHeader(
    "SPRITEINS",
    "ASPI",
    "00",
    0,
);

// Define a type-safe Game state structure.
// This struct completely encapsulates our state, making it highly modular
// and easy to serialize for SRAM/Flash save files.
const Game = struct {
    spr: engine.StaticSprite,
    dx: i32,

    /// Frame-by-frame tick method. Since we are passing an instance pointer,
    /// we have access to 'self' to update member variables dynamically.
    pub fn tick(self: *@This()) void {
        // 1. Move the sprite using the instance state
        const cur_x: i32 = @intCast(self.spr.sprite.aabb.x.toInt());
        const next_x = cur_x + self.dx;
        if (next_x >= 240 - 8 or next_x <= 0) {
            self.dx = -self.dx;
        }
        self.spr.sprite.aabb.x = engine.physics.Fixed24_8.fromInt(@intCast(@max(0, cur_x + self.dx)));

        // 2. Draw the sprite via the engine
        engine.drawSprite(&self.spr);
    }
};

export fn main() noreturn {
    engine.initHardware();

    // 1. Instantiate our game state on the stack
    var game = Game{
        .spr = engine.StaticSprite.init(116, 76, 8, 8, .{
            .tile_index = 0,
            .palette_bank = 0,
        }),
        .dx = 1,
    };

    // 2. Fill solid white color tile graphics & palette to hardware VRAM/PALRAM
    game.spr.fillSolidColor(engine.Color.WHITE) catch {};

    // 3. Start the engine loop, passing a POINTER to our instance.
    // The engine's compile-time run loop will cleanly locate and execute the instance's tick() method.
    engine.run(&game);
}
