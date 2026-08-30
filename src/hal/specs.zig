// Memory section definitions and hardware constants for GBA.
// Pure leaf values with zero internal module dependencies.
// REF: https://www.coranac.com/tonc/text/hardware.htm#sec-memory

pub const MemorySections = struct {
    // System ROM: 00000000-00003FFF 16KiB,  32bit bus, read-only, executable
    //   Not used: 00004000-01FFFFFF
    // EWRAM     : 02000000-0203FFFF 256KiB, 16bit bus, multi-boot code.
    //   Not used: 02004000-02FFFFFF
    // IWRAM     : 03000000-03007FFF 32KiB,  32bit bus, for ARM code
    //   Not used: 03008000-03FFFFFF
    // IO RAM    : 04000000-040003FE 1KiB,   16bit bus, graphics, sound, buttons
    //   Not used: 04000400-04FFFFFF
    // PAL RAM   : 05000000-050003FF 1KiB,   16bit bus, 2 palette, 256 colors, 15-bit
    //   Not used: 05000400-05FFFFFF
    // VRAM      : 06000000-06017FFF 96KiB,  16bit bus, Video
    //   Not used: 06018000-06FFFFFF
    // OAM       : 07000000-070003FF 1KiB,   32bit bus, sprite control
    //   Not used: 07000400-07FFFFFF
    // PAK ROM   : 08000000-09FFFFFF 32MiB (variable), 16bit bus, Normal executable code
    // PAK ROM   : 0A000000-0BFFFFFF 32MiB (variable), 16bit bus, Normal executable code
    // PAK ROM   : 0C000000-0DFFFFFF 32MiB (variable), 16bit bus, Normal executable code
    // Cart SRAM : 0E000000-0E00FFFF 16KiB-64KiB (variable), 8bit bus, save data
    //   Not used: 0E010000-0FFFFFFF
    //   Not used: 10000000-FFFFFFFF
    pub const SYSROM = @as([*]u32, @ptrFromInt(0x00000000));
    pub const EWRAM = @as([*]u16, @ptrFromInt(0x02000000));
    pub const IWRAM = @as([*]u32, @ptrFromInt(0x03000000));
    pub const IORAM = @as([*]volatile u16, @ptrFromInt(0x04000000));
    pub const REG_DISPCNT = @as(*volatile u16, @ptrFromInt(0x04000000));
    pub const REG_DISPSTAT = @as(*volatile u16, @ptrFromInt(0x04000004));
    pub const REG_VCOUNT = @as(*volatile u16, @ptrFromInt(0x04000006));
    pub const REG_IE = @as(*volatile u16, @ptrFromInt(0x04000200));
    pub const REG_IF = @as(*volatile u16, @ptrFromInt(0x04000202));
    pub const REG_IME = @as(*volatile u16, @ptrFromInt(0x04000208));
    pub const REG_KEYINPUT = @as(*volatile u16, @ptrFromInt(0x04000130));
    pub const KEY_MASK = 0x03FF;
    pub const PALRAM = @as([*]volatile u16, @ptrFromInt(0x05000000));
    pub const VRAM = @as([*]volatile u16, @ptrFromInt(0x06000000));
    pub const OAM = @as([*]volatile u32, @ptrFromInt(0x07000000));
    pub const PAKROM = @as([*]u32, @ptrFromInt(0x08000000));
    pub const CARTROM = @as([*]volatile u32, @ptrFromInt(0x0E000000));

    pub const SYSROM_SIZE_BYTES = 16 * 1024;
    pub const EWROM_SIZE_BYTES = 256 * 1024;
    pub const IWROM_SIZE_BYTES = 32 * 1024;
    pub const IORAM_SIZE_BYTES = 1024;
    pub const PALRAM_SIZE_BYTES = 1024;
    pub const VRAM_SIZE_BYTES = 96 * 1024;
    pub const OARAM_SIZE_BYTES = 1024;
    pub const PAKROM_SIZE_BYTES = 32 * 1024 * 1024;
    pub const CARTROM_SIZE_BYTES = 64 * 1024;

    // BIOS interrupt flag for SWI IntrWait
    pub const BIOS_IF = @as(*volatile u16, @ptrFromInt(0x03007FF8));
    // Pointer to the user-defined interrupt handler function
    pub const USER_IRQ_HANDLER = @as(*volatile ?*const fn () callconv(.naked) void, @ptrFromInt(0x03007FFC));
};

pub const Screen = struct {
    pub const WIDTH_PIXELS = 240;
    pub const HEIGHT_PIXELS = 160;

    pub const MODE5_WIDTH_PIXELS = 160;
    pub const MODE5_HEIGHT_PIXELS = 128;
};

pub const Color = struct {
    pub const BLACK: u16 = 0x0000;
    pub const RED: u16 = 0x001F;
    pub const LIME: u16 = 0x03E0;
    pub const YELLOW: u16 = 0x03FF;
    pub const BLUE: u16 = 0x7C00;
    pub const MAG: u16 = 0x7C1F;
    pub const CYAN: u16 = 0x7FE0;
    pub const WHITE: u16 = 0x7FFF;
};
