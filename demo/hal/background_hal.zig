const gba = @import("zamgba");
const hal = gba.hal;
const display = hal.display;
const joypad = hal.joypad;
const MemorySections = hal.MemorySections;
const Palette = hal.Palette;
const Tile = hal.Tile;

// The standard ROM header for the GBA BIOS
export var gameHeader linksection(".gba.header") = hal.setupROMHeader(
    "BGHAL",
    "ABGH",
    "00",
    0,
);

// Configuration constants for the demo background layer
const BG_ID: display.BgId = .bg0;
const BG_CBB: u2 = 0;
const BG_SBB: u5 = 16;
const BG_SIZE: display.BgSize = .size_32x32;
const PALETTE_BANK_SHIFT: u4 = 12;

export fn main() noreturn {
    // 1. Initialize Display
    // Configure GBA Picture Processing Unit (PPU) in Mode 0 (tiled text mode)
    // and enable background layer 0 (BG0).
    display.setMode0();
    display.enableBgLayer(BG_ID);
    display.writeRegister();

    // 2. Configure BG0 Control Register (REG_BG0CNT)
    // - Priority 0 (top visual layer)
    // - Charblock 0 for tile image graphics
    // - Screenblock 16 for 32x32 map entries
    // - 4-bpp color depth (16-color sub-palettes)
    // - 32x32 tiles (256x256 pixels)
    display.setBgControl(BG_ID, .{
        .priority = 0,
        .charblock = BG_CBB,
        .screenblock = BG_SBB,
        .is_8bpp = false,
        .size = BG_SIZE,
    });

    // 3. Setup Background Palette (PALRAM: 0x05000000)
    // Bank 0 (Limes & Whites)
    const bank0 = 0 * Palette.COLORS_PER_BANK;
    MemorySections.PALRAM[bank0 + 0] = hal.Color.BLACK;
    MemorySections.PALRAM[bank0 + 1] = hal.Color.WHITE;
    MemorySections.PALRAM[bank0 + 2] = hal.Color.LIME;
    MemorySections.PALRAM[bank0 + 3] = hal.Color.YELLOW;

    // Bank 1 (Reds & Cyans)
    const bank1 = 1 * Palette.COLORS_PER_BANK;
    MemorySections.PALRAM[bank1 + 0] = hal.Color.BLACK;
    MemorySections.PALRAM[bank1 + 1] = hal.Color.RED;
    MemorySections.PALRAM[bank1 + 2] = hal.Color.CYAN;
    MemorySections.PALRAM[bank1 + 3] = hal.Color.MAG;

    // 4. Setup Tile Graphics in Charblock 0 (0x06000000)
    // 4-bpp mode: each tile is 8x8 pixels = 64 pixels (16 u16 words per tile).
    const cbb_ptr = MemorySections.VRAM + (BG_CBB * MemorySections.CHARBLOCK_SIZE_WORDS);

    // Tile 0: Solid / Empty background (index 0 for all pixels)
    const tile0_offset = 0 * Tile.WORDS_4BPP;
    for (0..Tile.WORDS_4BPP) |i| {
        cbb_ptr[tile0_offset + i] = 0x0000;
    }

    // Tile 1: Bordered box (border index 1, interior index 2)
    // Row 0 & 7: solid border color (0x1111)
    // Rows 1..6: left/right border (1), middle (2) -> 0x2221, 0x1222
    const tile1_offset = 1 * Tile.WORDS_4BPP;
    cbb_ptr[tile1_offset + 0] = Tile.SOLID_COLOR_1_PATTERN_4BPP;
    cbb_ptr[tile1_offset + 1] = Tile.SOLID_COLOR_1_PATTERN_4BPP;
    for (1..Tile.HEIGHT_PIXELS - 1) |row| {
        cbb_ptr[tile1_offset + row * 2 + 0] = 0x2221;
        cbb_ptr[tile1_offset + row * 2 + 1] = 0x1222;
    }
    cbb_ptr[tile1_offset + (Tile.HEIGHT_PIXELS - 1) * 2 + 0] = Tile.SOLID_COLOR_1_PATTERN_4BPP;
    cbb_ptr[tile1_offset + (Tile.HEIGHT_PIXELS - 1) * 2 + 1] = Tile.SOLID_COLOR_1_PATTERN_4BPP;

    // Tile 2: Cross / Plus sign (index 3)
    const tile2_offset = 2 * Tile.WORDS_4BPP;
    for (0..Tile.HEIGHT_PIXELS) |row| {
        if (row == 3 or row == 4) {
            cbb_ptr[tile2_offset + row * 2 + 0] = 0x3333;
            cbb_ptr[tile2_offset + row * 2 + 1] = 0x3333;
        } else {
            cbb_ptr[tile2_offset + row * 2 + 0] = 0x0330;
            cbb_ptr[tile2_offset + row * 2 + 1] = 0x0330;
        }
    }

    // Tile 3: Diagonal stripe pattern
    const tile3_offset = 3 * Tile.WORDS_4BPP;
    for (0..Tile.HEIGHT_PIXELS) |row| {
        const shift: u4 = @intCast((row % 4) * 4);
        const p1: u16 = @as(u16, 0x0002) << shift;
        const p2: u16 = @as(u16, 0x0020) << shift;
        cbb_ptr[tile3_offset + row * 2 + 0] = p1 | 0x0001;
        cbb_ptr[tile3_offset + row * 2 + 1] = p2 | 0x0010;
    }

    // 5. Populate Screenblock 16 with Screen Entries
    const sbb_ptr = MemorySections.VRAM + (BG_SBB * MemorySections.SCREENBLOCK_SIZE_WORDS);
    const map_w = BG_SIZE.tileWidth();
    const map_h = BG_SIZE.tileHeight();

    // Fill a decorative repeating grid pattern
    for (0..map_h) |ty| {
        for (0..map_w) |tx| {
            const index = ty * map_w + tx;
            // Select tile pattern based on coordinates
            const tile_id: u16 = if ((tx % 4 == 0) or (ty % 4 == 0))
                1 // Bordered box
            else if ((tx + ty) % 2 == 0)
                2 // Cross pattern
            else
                3; // Diagonal pattern

            // Alternate palette bank between Bank 0 and Bank 1
            const pal_bank: u16 = if ((tx / 2 + ty / 2) % 2 == 0) 0 else 1;

            // Screen Entry layout: [15..12: palette_bank] [11: v_flip] [10: h_flip] [9..0: tile_index]
            const entry: u16 = tile_id | (pal_bank << PALETTE_BANK_SHIFT);
            sbb_ptr[index] = entry;
        }
    }

    var scroll_x: i32 = 0;
    var scroll_y: i32 = 0;

    // 6. Main Interactive Game Loop
    while (true) {
        // Read joypad buttons
        const keys = joypad.readRaw();

        // Control scroll coordinates via D-Pad
        if ((keys & @intFromEnum(joypad.Key.Left)) != 0) {
            scroll_x -= 1;
        }
        if ((keys & @intFromEnum(joypad.Key.Right)) != 0) {
            scroll_x += 1;
        }
        if ((keys & @intFromEnum(joypad.Key.Up)) != 0) {
            scroll_y -= 1;
        }
        if ((keys & @intFromEnum(joypad.Key.Down)) != 0) {
            scroll_y += 1;
        }

        // Automatic slow diagonal drift when no keys are held
        if ((keys & (@intFromEnum(joypad.Key.Left) | @intFromEnum(joypad.Key.Right) |
            @intFromEnum(joypad.Key.Up) | @intFromEnum(joypad.Key.Down))) == 0)
        {
            scroll_x += 1;
        }

        // Wait for VBlank interrupt to eliminate tearing
        hal.waitForVBlank();

        // Update hardware scroll registers (REG_BG0HOFS, REG_BG0VOFS)
        display.setBgScroll(
            BG_ID,
            @truncate(@as(u32, @bitCast(scroll_x))),
            @truncate(@as(u32, @bitCast(scroll_y))),
        );
    }
}
