const MemorySections = @import("specs.zig").MemorySections;
const REG_DISPCNT = MemorySections.REG_DISPCNT;
const REG_DISPSTAT = MemorySections.REG_DISPSTAT;
const REG_IE = MemorySections.REG_IE;
const REG_IF = MemorySections.REG_IF;
const REG_IME = MemorySections.REG_IME;

pub var value: u16 = 0;

pub fn writeRegister() void {
    (REG_DISPCNT.*) = value;
}

pub fn loadRegister() void {
    value = (REG_DISPCNT.*);
}

// DCNT_MODE
pub fn setMode0() void {
    value |= 0x0000;
}
pub fn setMode1() void {
    value |= 0x0001;
}
pub fn setMode2() void {
    value |= 0x0002;
}
pub fn setMode3() void {
    value |= 0x0003;
}
pub fn setMode4() void {
    value |= 0x0004;
}
pub fn setMode5() void {
    value |= 0x0005;
}

// DCNT_GB
pub fn isGBC() bool {
    return (REG_DISPCNT.*) & 0x08 == 0x08;
}

// DCNT_PAGE
pub fn selectPage1() void {
    value |= 0x0010;
}
pub fn selectPage0() void {
    value &= 0xFFEF;
}

pub fn isPage0() bool {
    return (REG_DISPCNT.*) & 0x0010 == 0;
}

pub fn isPage1() bool {
    return (REG_DISPCNT.*) & 0x0010 != 0;
}

pub fn getPage() u8 {
    if (((REG_DISPCNT.*) & 0x0010) == 0) {
        return 0;
    }
    return 1;
}

pub fn waitForVBlank() void {

    // Acknowledge any pending VBlank interrupts in REG_IF before waiting
    REG_IF.* = 0x0001;

    // Enable VBlank interrupt in DISPSTAT
    REG_DISPSTAT.* |= 0x0008;

    // Enable VBlank interrupt in IE
    REG_IE.* |= 0x0001;

    // Enable Master Interrupt
    REG_IME.* = 1;

    asm volatile ("swi 0x05" ::: .{
            .r0 = true,
            .r1 = true,
            .r2 = true,
            .r3 = true,
            .memory = true,
        });
}

pub fn flipPage() void {
    (REG_DISPCNT.*) ^= 0x0010;
}

// TODO
// DCNT_HB
// DCNT_OM
// DCNT_FB
// DCNT_BG{0-3}
pub fn setBackground0() void {
    value |= 0x0100;
}

pub fn setBackground1() void {
    value |= 0x0200;
}

pub fn setBackground2() void {
    value |= 0x0400;
}

pub fn setBackground3() void {
    value |= 0x0800;
}

pub fn unsetBackground0() void {
    value &= 0xFEFF;
}

pub fn unsetBackground1() void {
    value &= 0xFDFF;
}

pub fn unsetBackground2() void {
    value &= 0xFBFF;
}

pub fn unsetBackground3() void {
    value &= 0xF7FF;
}

pub const DCNT_OBJ: u16 = 0x1000;
pub const DCNT_OBJ_1D: u16 = 0x0040;

/// Sprite (OBJ) VRAM tile memory addressing mode.
pub const SpriteMapping = enum(u1) {
    grid_2d = 0,
    linear_1d = 1,
};

/// Enable GBA Sprite (OBJ) rendering layer.
pub fn enableSprites() void {
    value |= DCNT_OBJ;
}

/// Alias for enableSprites for layer naming consistency.
pub const enableSpriteLayer = enableSprites;

/// Disable GBA Sprite (OBJ) rendering layer.
pub fn disableSprites() void {
    value &= ~DCNT_OBJ;
}

/// Alias for disableSprites for layer naming consistency.
pub const disableSpriteLayer = disableSprites;

/// Set the Sprite (OBJ) VRAM tile memory addressing mode.
pub fn setSpriteMapping(mode: SpriteMapping) void {
    switch (mode) {
        .linear_1d => value |= DCNT_OBJ_1D,
        .grid_2d => value &= ~DCNT_OBJ_1D,
    }
}

/// Convenience shortcut to configure 1D linear Sprite tile addressing.
pub fn setSpriteMapping1D() void {
    setSpriteMapping(.linear_1d);
}

/// Convenience shortcut to configure 2D grid Sprite tile addressing.
pub fn setSpriteMapping2D() void {
    setSpriteMapping(.grid_2d);
}
//
// REG_DISPSTAT
// REG_VCOUNT

// ===================================================================
// Unit tests
// ===================================================================

test "display.SetModeAndBackground" {
    const std = @import("std");
    value = 0;

    // Do not call .writeRegister() because it's only available when
    // running on a real GBA device. The address of REG_DISPCNT can
    // write to any result but what we want.
    setMode3();
    setBackground2();
    try std.testing.expect(value == 0x0403);
}

test "display.SpriteLayerAndMapping" {
    const std = @import("std");
    value = 0;

    enableSprites();
    try std.testing.expectEqual(DCNT_OBJ, value);

    setSpriteMapping1D();
    try std.testing.expectEqual(DCNT_OBJ | DCNT_OBJ_1D, value);

    setSpriteMapping2D();
    try std.testing.expectEqual(DCNT_OBJ, value);

    setSpriteMapping(.linear_1d);
    try std.testing.expectEqual(DCNT_OBJ | DCNT_OBJ_1D, value);

    disableSprites();
    try std.testing.expectEqual(DCNT_OBJ_1D, value);
}
