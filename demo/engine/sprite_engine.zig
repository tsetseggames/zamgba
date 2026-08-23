const gba = @import("zamgba");
const hal = gba.hal;
const engine = gba.engine;

// The standard ROM header for the GBA BIOS
export var gameHeader linksection(".gba.header") = hal.setupROMHeader(
    "SPRITENG",
    "ASPE",
    "00",
    0,
);

// File-level globals. Since every Zig file is an implicit struct, these
// act as our clean Level/Game state fields without polluting other namespaces.
var spr: engine.Sprite = undefined;
var dx: i32 = 1;

/// The primary frame update callback for the active level/game.
/// This runs automatically on every frame within our engine loop.
pub fn tick(eng: *engine.Engine) void {
    // 1. Move the high-level sprite's position
    const cur_x: i32 = @intCast(spr.aabb.x.toInt());
    const next_x = cur_x + dx;
    if (next_x >= 240 - 8 or next_x <= 0) {
        dx = -dx;
    }
    spr.aabb.x = engine.physics.Fixed24_8.fromInt(@intCast(@max(0, cur_x + dx)));

    // 2. Draw the sprite (stages it dynamically in the next available OAM slot)
    eng.drawSprite(&spr);
}

export fn main() noreturn {
    // 1. Initialize Display (We still need to configure the hardware registers initially)
    hal.display.setMode0();
    hal.display.setObject();
    hal.display.setObject1D();
    hal.display.writeRegister();

    // 2. Initialize high-level sprite state (8x8 square sprite)
    spr = engine.Sprite.init(116, 76, 8, 8);
    spr.tile_index = 0;
    spr.palette_bank = 0;

    // 3. Fill solid white color tile graphics & palette to hardware VRAM/PALRAM
    spr.fillSolidColor(engine.Color.WHITE) catch {};

    // 4. Initialize Engine Context
    var eng = engine.Engine.init();

    // 5. Start the engine loop, passing @This() (our current file-struct type)
    // The engine's compile-time run loop will cleanly locate and execute our tick() method.
    eng.run(@This());
}
