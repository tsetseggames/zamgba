// This file contains code used by linker scripts when building GBA
// executable.

// I didn't copy logic from ZigGBA because I found the definition
// varies with other projects like https://github.com/ryankurte/rust-gba.git.
// Unfortunatley none of them can be built from latest Rust / Zig since
// 2024-01. I decide to understand the full progress to make a code
// boot from scratch. So I really understand how it works.
//
// The code below is based on GBATek 3.0 backup below:
// https://fabiensanglard.net/another_world_polygons_GBA/gbatech.html
// https://github.com/gbadev-org/gbadoc
// http://r32.github.io/other/2023-03-22-gba-dev.html
const header = @import("header.zig");
const builtin = @import("builtin");
const is_gba_target = builtin.target.cpu.arch == .arm or builtin.target.cpu.arch == .thumb;

// Memory section for hardware read/write
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

pub const display = @import("display.zig");
pub const joypad = @import("joypad.zig");
pub const dma = @import("dma.zig");
pub const waitForVBlank = display.waitForVBlank;

pub const oam = @import("oam.zig");
pub const context = @import("context.zig");

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

// ==================================================================
// Below are boot code
// ==================================================================

// The variables below are defined in gba.ld.
extern var _sbss: u32;
extern var _ebss: u32;
extern var _sdata: u32;
extern var _edata: u32;
extern var _sidata: u32;
extern var __sp_irq: u32;
extern var __sp_usr: u32;

pub fn setupROMHeader(
    comptime gameTitle: []const u8,
    comptime gameCode: []const u8,
    comptime makerCode: []const u8,
    comptime softwareVersion: u8,
) header.Header {
    var h = header.headerTemplate;
    comptime {
        const isUpper = @import("std").ascii.isUpper;
        const isDigit = @import("std").ascii.isDigit;
        for (gameTitle, 0..) |eachCh, i| {
            const isValidChar = isUpper(eachCh) or isDigit(eachCh);
            if (isValidChar and i < 12) {
                h.gameTitle[i] = eachCh;
            } else {
                if (i >= 12) {
                    @compileError("Game name is too long: expect <= 12 characters.");
                } else if (!isValidChar) {
                    @compileError("Game name must be all Uppercase+digit.");
                }
            }
        }

        for (gameCode, 0..) |eachCh, i| {
            const isValidChar = isUpper(eachCh);
            if (isValidChar and i < 4) {
                h.gameCode[i] = eachCh;
            } else {
                if (i >= 4) {
                    @compileError("Game code is too long: expect <= 4 characters.");
                } else if (!isValidChar) {
                    @compileError("Game code must be all Uppercase.");
                }
            }
        }

        for (makerCode, 0..) |eachCh, i| {
            const isValidChar = isDigit(eachCh);
            if (isValidChar and i < 2) {
                h.makerCode[i] = eachCh;
            } else {
                if (i >= 2) {
                    @compileError("Maker code is too long: expect <= 2 characters.");
                } else if (!isValidChar) {
                    @compileError("Game code must be all digits.");
                }
            }
        }

        h.softwareVersion = softwareVersion;
        // Clean-room ROM header checksum calculation based on GBATEK spec
        var sum: u8 = 0;
        const header_bytes = @as([228]u8, @bitCast(h));
        for (header_bytes[0xA0..0xBD]) |byte| {
            sum +%= byte;
        }
        h.complementCheck = @as(u8, @intCast((-(0x19 + @as(i32, sum))) & 0xFF));
    }
    return h;
}

fn zeroBss() void {
    // Clear memory of .bss section
    // (between _sbss and _ebss), filling them to all 0.
    var dst = @as([*]u8, @ptrCast(&_sbss));
    const end = @as([*]u8, @ptrCast(&_ebss));
    while (@intFromPtr(dst) < @intFromPtr(end)) : (dst += 1) {
        dst[0] = 0;
    }
}

fn copyDataToEWRAM() void {
    // Copy .data section to EWRAM
    var src = @as([*]u8, @ptrCast(&_sidata));
    var dst = @as([*]u8, @ptrCast(&_sdata));
    const end = @as([*]u8, @ptrCast(&_edata));
    while (@intFromPtr(dst) < @intFromPtr(end)) {
        dst[0] = src[0];
        dst += 1;
        src += 1;
    }
}

comptime {
    if (is_gba_target) {
        _ = struct {
            export fn _boot() linksection(".gba.boot") void {
                zeroBss();
                copyDataToEWRAM();

                // Set up default IRQ handler for BIOS IntrWait functions (e.g. SWI 0x05)
                MemorySections.USER_IRQ_HANDLER.* = irqHandler;

                callUserMain();
                while (true) {}
            }

            export fn irqHandler() callconv(.naked) void {
                asm volatile (
                    \\.arm
                    \\.cpu arm7tdmi
                    \\
                    \\@ r0 = REG_BASE
                    \\mov r0, #0x04000000
                    \\
                    \\@ r1 = BIOS_IF pointer
                    \\ldr r1, =0x03007FF8
                    \\
                    \\@ Read REG_IF (0x04000202)
                    \\add r0, r0, #0x200
                    \\ldrh r2, [r0, #2]
                    \\
                    \\@ Acknowledge REG_IF hardware interrupts
                    \\strh r2, [r0, #2]
                    \\
                    \\@ Read BIOS_IF
                    \\ldrh r3, [r1]
                    \\
                    \\@ Acknowledge BIOS IntrWait interrupts
                    \\orr r3, r3, r2
                    \\strh r3, [r1]
                    \\
                    \\@ Return to BIOS IRQ dispatcher
                    \\bx lr
                );
            }

            export fn _start() linksection(".gba.start") callconv(.naked) void {
                asm volatile (
                    \\.arm
                    \\.cpu arm7tdmi
                    \\mov r0, #0x04000000
                    \\str r0, [r0, #0x208]
                    \\mov r0, #0x12
                    \\msr cpsr, r0
                    \\ldr sp, =__sp_irq
                    \\mov r0, #0x10
                    \\msr cpsr, r0
                    \\ldr sp, =__sp_usr
                    \\ldr r3, =_boot
                    \\bx r3
                );
            }
        };
    }
}

fn callUserMain() void {
    if (is_gba_target) {
        asm volatile (
            \\.thumb
            \\.cpu arm7tdmi
            \\ldr r0, =main
            \\bx r0
        );
    }
}

test {
    _ = @import("dma.zig");
    _ = @import("display.zig");
}
