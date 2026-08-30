const std = @import("std");
const png = @import("png.zig");
const tile = @import("tile.zig");
const metadata = @import("metadata.zig");

pub const CodegenOptions = struct {
    sprite_name: []const u8 = "sprite",
    bpp: png.BppMode = .auto,
    color_adjust: bool = false,
    palette_only: bool = false,
};

pub const CodegenError = error{
    ImageDecodeError,
    MetadataParseError,
    TileSliceError,
    WriteError,
    OutOfMemory,
    Unimplemented,
};

/// Generates full, type-safe Zig source code from PNG and JSON asset bytes.
pub fn generateZigSource(
    allocator: std.mem.Allocator,
    png_bytes: []const u8,
    json_bytes: ?[]const u8,
    options: CodegenOptions,
) CodegenError![]u8 {
    _ = allocator;
    _ = png_bytes;
    _ = json_bytes;
    _ = options;
    // Stub for TDD (intentionally unimplemented)
    return error.Unimplemented;
}

// ====================================================================
// Unit Tests for Code Generator (TDD Red Phase)
// ====================================================================

test "GEN001: generateZigSource for palette-only mode" {
    const test_assets = @import("test_palettes");
    const out = try generateZigSource(std.testing.allocator, test_assets.png_pal16, null, .{
        .palette_only = true,
        .bpp = .bpp4,
    });
    defer std.testing.allocator.free(out);

    try std.testing.expect(std.mem.indexOf(u8, out, "pub const palette = [_]u16{") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "pub const frame_tiles") == null);
}

test "GEN002: generateZigSource full sprite with real flying broom asset" {
    const test_assets = @import("test_palettes");
    const out = try generateZigSource(std.testing.allocator, test_assets.png_broom, test_assets.json_broom, .{
        .sprite_name = "tsetseg_flying",
        .bpp = .bpp8,
    });
    defer std.testing.allocator.free(out);

    try std.testing.expect(std.mem.indexOf(u8, out, "pub const width: u16 = 32;") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "pub const height: u16 = 32;") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "pub const frame_count: u16 = 8;") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "pub const tile_count_per_frame: u16 = 16;") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"flying\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "pub const frame_tiles") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "pub const raw_tiles") != null);
}

test "GEN003: generateZigSource 4x16 banked mode syntax" {
    const test_assets = @import("test_palettes");
    const out = try generateZigSource(std.testing.allocator, test_assets.png_pal256, null, .{
        .palette_only = true,
        .bpp = .bpp4x16,
    });
    defer std.testing.allocator.free(out);

    try std.testing.expect(std.mem.indexOf(u8, out, "pub const palettes = [16][16]u16{") != null);
}

test "GEN004: generateZigSource error when missing json in full sprite mode" {
    const test_assets = @import("test_palettes");
    try std.testing.expectError(error.MetadataParseError, generateZigSource(std.testing.allocator, test_assets.png_broom, null, .{
        .palette_only = false,
    }));
}
