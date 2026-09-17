const MemorySections = @import("specs.zig").MemorySections;
const is_gba_target = @import("specs.zig").is_gba_target;
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

pub const DCNT_OBJ: u16 = 0x1000;
pub const DCNT_OBJ_1D: u16 = 0x0040;

/// Background layer identifiers (Mode 0: BG0, BG1, BG2, BG3).
pub const BgId = enum(u2) {
    bg0 = 0,
    bg1 = 1,
    bg2 = 2,
    bg3 = 3,

    pub inline fn dcntBit(self: BgId) u16 {
        return @as(u16, 1) << (@as(u4, @intFromEnum(self)) + 8);
    }
};

/// GBA Text Background map layout and size configurations.
pub const BgSize = enum(u2) {
    size_32x32 = 0, // 256x256 px, 1 SBB
    size_64x32 = 1, // 512x256 px, 2 SBBs horizontally
    size_32x64 = 2, // 256x512 px, 2 SBBs vertically
    size_64x64 = 3, // 512x512 px, 4 SBBs (2x2)

    pub fn tileWidth(self: BgSize) u16 {
        return switch (self) {
            .size_32x32, .size_32x64 => 32,
            .size_64x32, .size_64x64 => 64,
        };
    }

    pub fn tileHeight(self: BgSize) u16 {
        return switch (self) {
            .size_32x32, .size_64x32 => 32,
            .size_32x64, .size_64x64 => 64,
        };
    }

    pub fn pixelWidth(self: BgSize) u16 {
        return self.tileWidth() * 8;
    }

    pub fn pixelHeight(self: BgSize) u16 {
        return self.tileHeight() * 8;
    }

    pub fn screenblocksCount(self: BgSize) u8 {
        return switch (self) {
            .size_32x32 => 1,
            .size_64x32, .size_32x64 => 2,
            .size_64x64 => 4,
        };
    }
};

/// Background Control Register (REG_BGxCNT) bitfield layout.
pub const BgControl = packed struct(u16) {
    priority: u2 = 0,
    charblock: u2 = 0,
    unused1: u2 = 0,
    mosaic: bool = false,
    is_8bpp: bool = false,
    screenblock: u5 = 0,
    wraparound: bool = false,
    size: BgSize = .size_32x32,

    pub inline fn raw(self: BgControl) u16 {
        return @bitCast(self);
    }

    pub inline fn fromRaw(val: u16) BgControl {
        return @bitCast(val);
    }
};

/// Enables rendering of the specified background layer in REG_DISPCNT shadow value.
pub fn enableBgLayer(bg: BgId) void {
    value |= bg.dcntBit();
}

/// Disables rendering of the specified background layer in REG_DISPCNT shadow value.
pub fn disableBgLayer(bg: BgId) void {
    value &= ~bg.dcntBit();
}

/// Checks if the specified background layer is enabled in REG_DISPCNT shadow value.
pub fn isBgLayerEnabled(bg: BgId) bool {
    return (value & bg.dcntBit()) != 0;
}

/// Returns the VRAM pointer for the given Character Base Block (0..3, 16KB each).
fn getCharblockPtr(cbb: u2) [*]volatile u16 {
    return MemorySections.VRAM + (@as(usize, cbb) * (MemorySections.CHARBLOCK_SIZE_BYTES / @sizeOf(u16)));
}

/// Returns the VRAM pointer for the given Screen Base Block (0..31, 2KB each).
fn getScreenblockPtr(sbb: u5) [*]volatile u16 {
    return MemorySections.VRAM + (@as(usize, sbb) * (MemorySections.SCREENBLOCK_SIZE_BYTES / @sizeOf(u16)));
}

/// Sets the background control register (REG_BGxCNT) on real GBA hardware.
pub fn setBgControl(bg: BgId, control: BgControl) void {
    if (is_gba_target) {
        switch (bg) {
            .bg0 => MemorySections.REG_BG0CNT.* = control.raw(),
            .bg1 => MemorySections.REG_BG1CNT.* = control.raw(),
            .bg2 => MemorySections.REG_BG2CNT.* = control.raw(),
            .bg3 => MemorySections.REG_BG3CNT.* = control.raw(),
        }
    }
}

/// Sets the background scroll offsets (REG_BGxHOFS, REG_BGxVOFS) on real GBA hardware.
pub fn setBgScroll(bg: BgId, x: u9, y: u9) void {
    if (is_gba_target) {
        switch (bg) {
            .bg0 => {
                MemorySections.REG_BG0HOFS.* = x;
                MemorySections.REG_BG0VOFS.* = y;
            },
            .bg1 => {
                MemorySections.REG_BG1HOFS.* = x;
                MemorySections.REG_BG1VOFS.* = y;
            },
            .bg2 => {
                MemorySections.REG_BG2HOFS.* = x;
                MemorySections.REG_BG2VOFS.* = y;
            },
            .bg3 => {
                MemorySections.REG_BG3HOFS.* = x;
                MemorySections.REG_BG3VOFS.* = y;
            },
        }
    }
}

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
    enableBgLayer(.bg2);
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

test "BG001: BgControl packed struct encoding and raw bitcast" {
    const std = @import("std");

    // 1. Default value check (all zeros)
    const default_cnt = BgControl{};
    try std.testing.expectEqual(@as(u16, 0x0000), default_cnt.raw());

    // 2. Individual fields
    var cnt = BgControl{ .priority = 2 };
    try std.testing.expectEqual(@as(u16, 0x0002), cnt.raw());

    cnt = BgControl{ .charblock = 3 };
    try std.testing.expectEqual(@as(u16, 0x000C), cnt.raw());

    cnt = BgControl{ .mosaic = true };
    try std.testing.expectEqual(@as(u16, 0x0040), cnt.raw());

    cnt = BgControl{ .is_8bpp = true };
    try std.testing.expectEqual(@as(u16, 0x0080), cnt.raw());

    cnt = BgControl{ .screenblock = 28 };
    try std.testing.expectEqual(@as(u16, 28 << 8), cnt.raw());

    cnt = BgControl{ .wraparound = true };
    try std.testing.expectEqual(@as(u16, 0x2000), cnt.raw());

    cnt = BgControl{ .size = .size_64x64 };
    try std.testing.expectEqual(@as(u16, 3 << 14), cnt.raw());

    // 3. Combined bitfield validation
    const combined = BgControl{
        .priority = 1,
        .charblock = 2,
        .mosaic = true,
        .is_8bpp = false,
        .screenblock = 15,
        .wraparound = false,
        .size = .size_64x32,
    };
    // Expected: 1 | (2 << 2) | (1 << 6) | (15 << 8) | (1 << 14) = 1 + 8 + 0x40 + 0x0F00 + 0x4000 = 0x4F49
    try std.testing.expectEqual(@as(u16, 0x4F49), combined.raw());

    // Round-trip fromRaw
    const restored = BgControl.fromRaw(0x4F49);
    try std.testing.expectEqual(@as(u2, 1), restored.priority);
    try std.testing.expectEqual(@as(u2, 2), restored.charblock);
    try std.testing.expect(restored.mosaic);
    try std.testing.expect(!restored.is_8bpp);
    try std.testing.expectEqual(@as(u5, 15), restored.screenblock);
    try std.testing.expect(!restored.wraparound);
    try std.testing.expectEqual(BgSize.size_64x32, restored.size);
}

test "BG002: enableBgLayer, disableBgLayer, isBgLayerEnabled bit manipulation in display.value" {
    const std = @import("std");
    value = 0;

    try std.testing.expect(!isBgLayerEnabled(.bg0));
    try std.testing.expect(!isBgLayerEnabled(.bg1));
    try std.testing.expect(!isBgLayerEnabled(.bg2));
    try std.testing.expect(!isBgLayerEnabled(.bg3));

    enableBgLayer(.bg0);
    try std.testing.expectEqual(@as(u16, 0x0100), value);
    try std.testing.expect(isBgLayerEnabled(.bg0));
    try std.testing.expect(!isBgLayerEnabled(.bg1));

    enableBgLayer(.bg3);
    try std.testing.expectEqual(@as(u16, 0x0900), value);
    try std.testing.expect(isBgLayerEnabled(.bg0));
    try std.testing.expect(isBgLayerEnabled(.bg3));

    enableBgLayer(.bg1);
    enableBgLayer(.bg2);
    try std.testing.expectEqual(@as(u16, 0x0F00), value);
    try std.testing.expect(isBgLayerEnabled(.bg1));
    try std.testing.expect(isBgLayerEnabled(.bg2));

    disableBgLayer(.bg0);
    try std.testing.expectEqual(@as(u16, 0x0E00), value);
    try std.testing.expect(!isBgLayerEnabled(.bg0));
    try std.testing.expect(isBgLayerEnabled(.bg1));
    try std.testing.expect(isBgLayerEnabled(.bg2));
    try std.testing.expect(isBgLayerEnabled(.bg3));
}

test "BG003: Charblock and Screenblock VRAM address helpers" {
    const std = @import("std");

    try std.testing.expectEqual(@as(usize, 0x06000000), @intFromPtr(getCharblockPtr(0)));
    try std.testing.expectEqual(@as(usize, 0x06004000), @intFromPtr(getCharblockPtr(1)));
    try std.testing.expectEqual(@as(usize, 0x06008000), @intFromPtr(getCharblockPtr(2)));
    try std.testing.expectEqual(@as(usize, 0x0600C000), @intFromPtr(getCharblockPtr(3)));

    try std.testing.expectEqual(@as(usize, 0x06000000), @intFromPtr(getScreenblockPtr(0)));
    try std.testing.expectEqual(@as(usize, 0x06000800), @intFromPtr(getScreenblockPtr(1)));
    try std.testing.expectEqual(@as(usize, 0x0600F800), @intFromPtr(getScreenblockPtr(31)));
}

test "BG004: BgSize dimension and screenblock count helpers" {
    const std = @import("std");

    const s32x32 = BgSize.size_32x32;
    try std.testing.expectEqual(@as(u16, 32), s32x32.tileWidth());
    try std.testing.expectEqual(@as(u16, 32), s32x32.tileHeight());
    try std.testing.expectEqual(@as(u16, 256), s32x32.pixelWidth());
    try std.testing.expectEqual(@as(u16, 256), s32x32.pixelHeight());
    try std.testing.expectEqual(@as(u8, 1), s32x32.screenblocksCount());

    const s64x32 = BgSize.size_64x32;
    try std.testing.expectEqual(@as(u16, 64), s64x32.tileWidth());
    try std.testing.expectEqual(@as(u16, 32), s64x32.tileHeight());
    try std.testing.expectEqual(@as(u16, 512), s64x32.pixelWidth());
    try std.testing.expectEqual(@as(u16, 256), s64x32.pixelHeight());
    try std.testing.expectEqual(@as(u8, 2), s64x32.screenblocksCount());

    const s32x64 = BgSize.size_32x64;
    try std.testing.expectEqual(@as(u16, 32), s32x64.tileWidth());
    try std.testing.expectEqual(@as(u16, 64), s32x64.tileHeight());
    try std.testing.expectEqual(@as(u16, 256), s32x64.pixelWidth());
    try std.testing.expectEqual(@as(u16, 512), s32x64.pixelHeight());
    try std.testing.expectEqual(@as(u8, 2), s32x64.screenblocksCount());

    const s64x64 = BgSize.size_64x64;
    try std.testing.expectEqual(@as(u16, 64), s64x64.tileWidth());
    try std.testing.expectEqual(@as(u16, 64), s64x64.tileHeight());
    try std.testing.expectEqual(@as(u16, 512), s64x64.pixelWidth());
    try std.testing.expectEqual(@as(u16, 512), s64x64.pixelHeight());
    try std.testing.expectEqual(@as(u8, 4), s64x64.screenblocksCount());
}
