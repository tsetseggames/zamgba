const std = @import("std");
const hal = @import("zamgba-hal");
const png = @import("png.zig");
const BppMode = @import("main.zig").BppMode;

// Internal GBA OBJ Tile constants directly referencing HAL hardware definition
const TILE_WIDTH: usize = hal.oam.Tile.WIDTH_PIXELS;
const TILE_HEIGHT: usize = hal.oam.Tile.HEIGHT_PIXELS;
const TILE_PIXEL_COUNT: usize = hal.oam.Tile.PIXEL_COUNT;

// Bitwise packing constants (internal)
const BITS_PER_PIXEL_4BPP: u3 = 4;
const PIXELS_PER_BYTE_4BPP: usize = 2;
const PIXEL_4BPP_MASK: u8 = 0x0F;
const COLORS_PER_BANK: usize = png.COLORS_PER_BANK;

// 4-bpp (16-color) Tile: 64 pixels packed at 4 bits/pixel = 32 bytes
pub const Tile4bpp = [hal.oam.Tile.BYTES_4BPP]u8;

// 8-bpp (256-color) Tile: 64 pixels at 8 bits/pixel = 64 bytes
pub const Tile8bpp = [hal.oam.Tile.BYTES_8BPP]u8;

// Slice rectangle in pixel coordinates
pub const Rect = struct {
    x: u32,
    y: u32,
    w: u32,
    h: u32,
};

// Sliced frame packaging result
pub const SlicedFrame = struct {
    width: u32,
    height: u32,
    tile_count: usize,
    bytes: []u8,
    detected_bank: u8,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *SlicedFrame) void {
        self.allocator.free(self.bytes);
    }
};

pub const TileError = error{
    InvalidDimensions,
    SliceOutOfBounds,
    MultiBankColorConflict,
    OutOfMemory,
    Unimplemented,
};

/// Packs a single 8x8 pixel block into a GBA 4-bpp tile (32 bytes).
/// Even pixels are placed in lower nibbles, odd pixels in upper nibbles with % 16 folding.
pub fn packTile4bpp(pixels_8x8: *const [TILE_HEIGHT][TILE_WIDTH]u8) TileError!Tile4bpp {
    _ = pixels_8x8;
    // Stub for TDD (intentionally unimplemented)
    return error.Unimplemented;
}

/// Packs a single 8x8 pixel block into a GBA 8-bpp tile (64 bytes).
pub fn packTile8bpp(pixels_8x8: *const [TILE_HEIGHT][TILE_WIDTH]u8) TileError!Tile8bpp {
    _ = pixels_8x8;
    // Stub for TDD (intentionally unimplemented)
    return error.Unimplemented;
}

/// Slices a sprite frame from an IndexedImage according to a Rect and packs it into 1D GBA tiles.
pub fn sliceSpriteFrame(
    allocator: std.mem.Allocator,
    img: *const png.IndexedImage,
    rect: Rect,
    mode: BppMode,
) TileError!SlicedFrame {
    _ = allocator;
    _ = img;
    _ = rect;
    _ = mode;
    // Stub for TDD (intentionally unimplemented)
    return error.Unimplemented;
}

// ====================================================================
// Unit Tests for Tile Slicing & Packing (TDD Red Phase)
// ====================================================================

const test_assets = @import("test_palettes");

test "packTile4bpp: nibble order and modulo re-indexing" {
    var sample: [TILE_HEIGHT][TILE_WIDTH]u8 = @splat(@splat(0));
    // Pixel 0 = 3 (lower nibble), Pixel 1 = 5 (upper nibble) -> byte 0 = (5 << 4) | 3 = 0x53
    sample[0][0] = 3;
    sample[0][1] = 5;
    // Pixel 2 = Bank 1 color (1 * 16 + 1 = 17) -> 17 % 16 = 1 (lower nibble), Pixel 3 = 0 -> byte 1 = 0x01
    sample[0][2] = 1 * COLORS_PER_BANK + 1;
    sample[0][3] = 0;

    const tile = try packTile4bpp(&sample);
    const expected_byte0: u8 = (5 << BITS_PER_PIXEL_4BPP) | 3;
    const expected_byte1: u8 = 1;
    try std.testing.expectEqual(expected_byte0, tile[0]);
    try std.testing.expectEqual(expected_byte1, tile[1]);
}

test "packTile8bpp: 64-byte linear packing" {
    var sample: [TILE_HEIGHT][TILE_WIDTH]u8 = @splat(@splat(0));
    sample[0][0] = 42;
    sample[TILE_HEIGHT - 1][TILE_WIDTH - 1] = 99;

    const tile = try packTile8bpp(&sample);
    try std.testing.expectEqual(hal.oam.Tile.BYTES_8BPP, tile.len);
    try std.testing.expectEqual(@as(u8, 42), tile[0]);
    try std.testing.expectEqual(@as(u8, 99), tile[TILE_PIXEL_COUNT - 1]);
}

test "sliceSpriteFrame: real asset frame 0 slicing 32x32 (4-bpp vs 8-bpp)" {
    var img = try png.decompressIndexedPixels(std.testing.allocator, test_assets.png_broom);
    defer img.deinit();

    const frame0_rect = Rect{ .x = 0, .y = 0, .w = 32, .h = 32 };
    const expected_tiles_32x32 = (32 / TILE_WIDTH) * (32 / TILE_HEIGHT); // 16 tiles

    // 1. Slicing under 4-bpp mode
    var frame_4bpp = try sliceSpriteFrame(std.testing.allocator, &img, frame0_rect, .bpp4);
    defer frame_4bpp.deinit();
    try std.testing.expectEqual(expected_tiles_32x32, frame_4bpp.tile_count);
    try std.testing.expectEqual(expected_tiles_32x32 * hal.oam.Tile.BYTES_4BPP, frame_4bpp.bytes.len); // 512 bytes

    // 2. Slicing under 8-bpp mode
    var frame_8bpp = try sliceSpriteFrame(std.testing.allocator, &img, frame0_rect, .bpp8);
    defer frame_8bpp.deinit();
    try std.testing.expectEqual(expected_tiles_32x32, frame_8bpp.tile_count);
    try std.testing.expectEqual(expected_tiles_32x32 * hal.oam.Tile.BYTES_8BPP, frame_8bpp.bytes.len); // 1024 bytes
}

test "sliceSpriteFrame: reject invalid dimensions and out of bounds" {
    var img = try png.decompressIndexedPixels(std.testing.allocator, test_assets.png_broom);
    defer img.deinit();

    // Invalid non-8-multiple dimensions
    const invalid_dim = Rect{ .x = 0, .y = 0, .w = 10, .h = 10 };
    try std.testing.expectError(error.InvalidDimensions, sliceSpriteFrame(std.testing.allocator, &img, invalid_dim, .bpp4));

    // Out of bounds slice (x: 240, w: 32 -> extends to 272 > image width 256)
    const oob_rect = Rect{ .x = 240, .y = 0, .w = 32, .h = 32 };
    try std.testing.expectError(error.SliceOutOfBounds, sliceSpriteFrame(std.testing.allocator, &img, oob_rect, .bpp4));
}

test "sliceSpriteFrame: reject multi-bank color conflict in 4-bpp mode" {
    var fake_pixels: [16 * 16]u8 = @splat(0);
    // Mix non-transparent Bank 0 color (index 2) and Bank 1 color (1 * 16 + 2 = 18) in the same frame
    fake_pixels[0] = 2;
    fake_pixels[1] = 1 * COLORS_PER_BANK + 2;

    const fake_img = png.IndexedImage{
        .width = 16,
        .height = 16,
        .pixels = &fake_pixels,
        .allocator = std.testing.allocator,
    };

    const rect = Rect{ .x = 0, .y = 0, .w = 16, .h = 16 };
    try std.testing.expectError(error.MultiBankColorConflict, sliceSpriteFrame(std.testing.allocator, &fake_img, rect, .bpp4));
}
