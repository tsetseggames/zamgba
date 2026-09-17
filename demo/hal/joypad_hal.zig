const gba = @import("zamgba");
const hal = gba.hal;
const engine = gba.engine;

// The standard ROM header for the GBA BIOS
export var gameHeader linksection(".gba.header") = hal.setupROMHeader(
    "JOYPADHAL",
    "AJOY",
    "00",
    0,
);

export fn main() noreturn {
    // 1. Initialize Display
    // Set Mode 3 (Bitmap mode) and enable BG2 to draw directly to VRAM.
    hal.display.setMode3();
    hal.display.enableBgLayer(.bg2);
    hal.display.writeRegister();

    // 2. Initialize Input
    var input = engine.input.InputState{};

    // Box properties
    const box_size: i32 = 16;
    var box_x: i32 = (hal.Screen.WIDTH_PIXELS - box_size) / 2;
    var box_y: i32 = (hal.Screen.HEIGHT_PIXELS - box_size) / 2;
    var prev_x: i32 = box_x;
    var prev_y: i32 = box_y;

    const vram = hal.MemorySections.VRAM;

    // Clear entire screen to Black once at startup
    var i: usize = 0;
    while (i < hal.Screen.WIDTH_PIXELS * hal.Screen.HEIGHT_PIXELS) : (i += 1) {
        vram[i] = hal.Color.BLACK;
    }

    // 3. Game Loop
    while (true) {
        // ---------------------------------------------------------
        // A. GAME LOGIC (Executed during Active Display Period)
        // ---------------------------------------------------------

        // Update input state at the start of the logic frame
        input.update();

        var next_x = box_x;
        var next_y = box_y;

        // Move box based on D-pad input with boundary clamping
        if (input.isPressed(.Left)) {
            next_x -= 2;
            if (next_x < 0) next_x = 0;
        }
        if (input.isPressed(.Right)) {
            next_x += 2;
            if (next_x > hal.Screen.WIDTH_PIXELS - box_size) {
                next_x = hal.Screen.WIDTH_PIXELS - box_size;
            }
        }
        if (input.isPressed(.Up)) {
            next_y -= 2;
            if (next_y < 0) next_y = 0;
        }
        if (input.isPressed(.Down)) {
            next_y += 2;
            if (next_y > hal.Screen.HEIGHT_PIXELS - box_size) {
                next_y = hal.Screen.HEIGHT_PIXELS - box_size;
            }
        }

        // Determine box color (A -> Red, B -> Yellow, Default -> White)
        const box_color: u16 = if (input.isPressed(.A))
            hal.Color.RED
        else if (input.isPressed(.B))
            hal.Color.YELLOW
        else
            hal.Color.WHITE;

        // ---------------------------------------------------------
        // B. WAIT FOR VBLANK
        // ---------------------------------------------------------
        // Halt the CPU until the screen finishes drawing.
        hal.waitForVBlank();
        // const REG_VCOUNT = @as(*volatile u16, @ptrFromInt(0x04000006));
        // while (REG_VCOUNT.* >= 160) {}
        // while (REG_VCOUNT.* < 160) {}

        // ---------------------------------------------------------
        // C. RENDER (Executed during VBlank Period)
        // ---------------------------------------------------------
        // By drawing only AFTER waitForVBlank(), we guarantee that the
        // LCD is not actively scanning these pixels, eliminating flicker.

        // Erase old box position
        var sy: i32 = 0;
        while (sy < box_size) : (sy += 1) {
            var sx: i32 = 0;
            while (sx < box_size) : (sx += 1) {
                const pixel_x = @as(usize, @intCast(prev_x + sx));
                const pixel_y = @as(usize, @intCast(prev_y + sy));
                vram[pixel_y * hal.Screen.WIDTH_PIXELS + pixel_x] = hal.Color.BLACK;
            }
        }

        // Draw box at new position
        sy = 0;
        while (sy < box_size) : (sy += 1) {
            var sx: i32 = 0;
            while (sx < box_size) : (sx += 1) {
                const pixel_x = @as(usize, @intCast(next_x + sx));
                const pixel_y = @as(usize, @intCast(next_y + sy));
                vram[pixel_y * hal.Screen.WIDTH_PIXELS + pixel_x] = box_color;
            }
        }

        // Save current position for erasing in the next frame
        box_x = next_x;
        box_y = next_y;
        prev_x = box_x;
        prev_y = box_y;
    }
}
