const gba = @import("zamgba");
const hal = gba.hal;

pub const panic = gba.panic;

// The standard ROM header for the GBA BIOS
export var gameHeader linksection(".gba.header") = hal.setupROMHeader(
    "PANICDEMO",
    "APNC",
    "00",
    0,
);

export fn main() noreturn {
    // Explicitly trigger a panic to test bare-metal panic handling.
    // This executes:
    // 1. REG_IME = 0 (disable interrupts)
    // 2. Format 128-byte panic message with PC
    // 3. hal.mgba.log.write(.fatal, ...)
    // 4. PALRAM[0] = Color.RED
    // 5. Hang in infinite loop
    @panic("Explicit panic triggered in panic_demo");
}
