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

pub const specs = @import("specs.zig");
pub const MemorySections = specs.MemorySections;
pub const Screen = specs.Screen;
pub const Color = specs.Color;
pub const Palette = specs.Palette;
pub const Tile = specs.Tile;

pub const display = @import("display.zig");
pub const joypad = @import("joypad.zig");
pub const dma = @import("dma.zig");
pub const waitForVBlank = display.waitForVBlank;

pub const oam = @import("oam.zig");
pub const context = @import("context.zig");

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
