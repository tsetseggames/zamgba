const std = @import("std");
const hal = @import("zamgba-hal");

/// Loads a 16-color palette slice into a specific 4-bpp OBJ palette bank (0..15).
pub fn loadObjBank(bank: u4, colors: []const u16) void {
    loadObjBankToBuffer(bank, colors, hal.MemorySections.OBJ_PALRAM);
}

/// Testable buffer-backed implementation for loading into an OBJ palette bank.
pub fn loadObjBankToBuffer(bank: u4, colors: []const u16, pal_buffer: [*]volatile u16) void {
    _ = bank;
    _ = colors;
    _ = pal_buffer;
    // Stub for TDD Red Phase
}

/// Loads raw colors into OBJ PALRAM starting at a specific color index offset (0..255).
pub fn loadObjColors(start_color_index: u9, colors: []const u16) void {
    loadObjColorsToBuffer(start_color_index, colors, hal.MemorySections.OBJ_PALRAM);
}

/// Testable buffer-backed implementation for loading colors starting at an offset.
pub fn loadObjColorsToBuffer(start_color_index: u9, colors: []const u16, pal_buffer: [*]volatile u16) void {
    _ = start_color_index;
    _ = colors;
    _ = pal_buffer;
    // Stub for TDD Red Phase
}

// ====================================================================
// Unit Tests (TDD Red Phase)
// ====================================================================

test "PAL001: palette.loadObjBankToBuffer writes 16 colors to target bank" {
    var mock_pal = [_]u16{0} ** 256;
    const colors = [_]u16{
        0x0001, 0x0002, 0x0003, 0x0004,
        0x0005, 0x0006, 0x0007, 0x0008,
        0x0009, 0x000A, 0x000B, 0x000C,
        0x000D, 0x000E, 0x000F, 0x0010,
    };

    loadObjBankToBuffer(2, &colors, &mock_pal);

    // Bank 2 starts at index 32
    try std.testing.expectEqual(@as(u16, 0x0001), mock_pal[32]);
    try std.testing.expectEqual(@as(u16, 0x0010), mock_pal[47]);
    // Other banks should remain untouched
    try std.testing.expectEqual(@as(u16, 0), mock_pal[0]);
    try std.testing.expectEqual(@as(u16, 0), mock_pal[48]);
}

test "PAL002: palette.loadObjColorsToBuffer writes slice of colors at starting offset" {
    var mock_pal = [_]u16{0} ** 256;
    const colors = [_]u16{ 0x1234, 0x5678, 0x9ABC };

    loadObjColorsToBuffer(100, &colors, &mock_pal);

    try std.testing.expectEqual(@as(u16, 0x1234), mock_pal[100]);
    try std.testing.expectEqual(@as(u16, 0x5678), mock_pal[101]);
    try std.testing.expectEqual(@as(u16, 0x9ABC), mock_pal[102]);
    try std.testing.expectEqual(@as(u16, 0), mock_pal[99]);
    try std.testing.expectEqual(@as(u16, 0), mock_pal[103]);
}
