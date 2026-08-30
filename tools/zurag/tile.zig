const std = @import("std");
const hal = @import("zamgba-hal");
const png = @import("png.zig");
const types = @import("metadata/types.zig");
const BppMode = @import("main.zig").BppMode;

// Re-export Rect from metadata/types.zig
pub const Rect = types.Rect;

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
    var tile: Tile4bpp = undefined;
    var byte_idx: usize = 0;

    for (0..TILE_HEIGHT) |y| {
        var x: usize = 0;
        while (x < TILE_WIDTH) : (x += PIXELS_PER_BYTE_4BPP) {
            const p0: u8 = @truncate(pixels_8x8[y][x] % COLORS_PER_BANK);
            const p1: u8 = @truncate(pixels_8x8[y][x + 1] % COLORS_PER_BANK);
            tile[byte_idx] = (p0 & PIXEL_4BPP_MASK) | ((p1 & PIXEL_4BPP_MASK) << BITS_PER_PIXEL_4BPP);
            byte_idx += 1;
        }
    }

    return tile;
}

/// Packs a single 8x8 pixel block into a GBA 8-bpp tile (64 bytes).
pub fn packTile8bpp(pixels_8x8: *const [TILE_HEIGHT][TILE_WIDTH]u8) TileError!Tile8bpp {
    var tile: Tile8bpp = undefined;
    for (0..TILE_HEIGHT) |y| {
        for (0..TILE_WIDTH) |x| {
            tile[y * TILE_WIDTH + x] = pixels_8x8[y][x];
        }
    }
    return tile;
}

/// Slices a sprite frame from an IndexedImage according to a Rect and packs it into 1D GBA tiles.
pub fn sliceSpriteFrame(
    allocator: std.mem.Allocator,
    img: *const png.IndexedImage,
    rect: Rect,
    mode: BppMode,
) TileError!SlicedFrame {
    // 1. Dimension validation (must be non-zero multiples of 8)
    if (rect.w == 0 or rect.h == 0 or rect.w % TILE_WIDTH != 0 or rect.h % TILE_HEIGHT != 0) {
        return error.InvalidDimensions;
    }

    // 2. Bounds check against image
    if (rect.x + rect.w > img.width or rect.y + rect.h > img.height) {
        return error.SliceOutOfBounds;
    }

    const tiles_x = rect.w / TILE_WIDTH;
    const tiles_y = rect.h / TILE_HEIGHT;
    const tile_count = tiles_x * tiles_y;

    const is_8bpp = (mode == .bpp8);
    const bytes_per_tile = if (is_8bpp) hal.oam.Tile.BYTES_8BPP else hal.oam.Tile.BYTES_4BPP;
    const total_bytes = tile_count * bytes_per_tile;

    // 3. Multi-bank conflict detection (for 4-bpp modes)
    var detected_bank: u8 = 0;
    var first_bank: ?u8 = null;

    if (mode == .bpp4) {
        // In single 16-color mode (bpp4), all non-transparent pixels must be <= 15 (Bank 0)
        for (0..rect.h) |ry| {
            for (0..rect.w) |rx| {
                const px = img.getPixel(rect.x + @as(u32, @intCast(rx)), rect.y + @as(u32, @intCast(ry)));
                if (px >= COLORS_PER_BANK) {
                    return error.MultiBankColorConflict;
                }
            }
        }
        detected_bank = 0;
    } else if (mode == .bpp4x16) {
        // In 16-bank mode (bpp4x16), all non-transparent pixels in this frame must share the same bank
        for (0..rect.h) |ry| {
            for (0..rect.w) |rx| {
                const px = img.getPixel(rect.x + @as(u32, @intCast(rx)), rect.y + @as(u32, @intCast(ry)));
                if (px > 0) {
                    const bank: u8 = @intCast(px / COLORS_PER_BANK);
                    if (first_bank) |b| {
                        if (b != bank) {
                            return error.MultiBankColorConflict;
                        }
                    } else {
                        first_bank = bank;
                    }
                }
            }
        }
        detected_bank = first_bank orelse 0;
    }

    // 4. Allocate output 1D tile buffer
    const bytes = try allocator.alloc(u8, total_bytes);
    errdefer allocator.free(bytes);

    // 5. Slice and pack each 8x8 tile in row-major 1D order
    for (0..tiles_y) |ty| {
        for (0..tiles_x) |tx| {
            var block_8x8: [TILE_HEIGHT][TILE_WIDTH]u8 = undefined;

            for (0..TILE_HEIGHT) |py| {
                for (0..TILE_WIDTH) |px| {
                    const img_x = rect.x + @as(u32, @intCast(tx * TILE_WIDTH + px));
                    const img_y = rect.y + @as(u32, @intCast(ty * TILE_HEIGHT + py));
                    block_8x8[py][px] = img.getPixel(img_x, img_y);
                }
            }

            const tile_idx = ty * tiles_x + tx;
            if (is_8bpp) {
                const packed_tile = try packTile8bpp(&block_8x8);
                @memcpy(bytes[tile_idx * hal.oam.Tile.BYTES_8BPP .. (tile_idx + 1) * hal.oam.Tile.BYTES_8BPP], &packed_tile);
            } else {
                const packed_tile = try packTile4bpp(&block_8x8);
                @memcpy(bytes[tile_idx * hal.oam.Tile.BYTES_4BPP .. (tile_idx + 1) * hal.oam.Tile.BYTES_4BPP], &packed_tile);
            }
        }
    }

    return SlicedFrame{
        .width = rect.w,
        .height = rect.h,
        .tile_count = tile_count,
        .bytes = bytes,
        .detected_bank = detected_bank,
        .allocator = allocator,
    };
}

// ====================================================================
// Unit Tests for Tile Slicing & Packing (TDD Red Phase)
// ====================================================================

test "TIL001: packTile4bpp: nibble order and modulo re-indexing" {
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

test "TIL002: packTile8bpp: 64-byte linear packing" {
    var sample: [TILE_HEIGHT][TILE_WIDTH]u8 = @splat(@splat(0));
    sample[0][0] = 42;
    sample[TILE_HEIGHT - 1][TILE_WIDTH - 1] = 99;

    const tile = try packTile8bpp(&sample);
    try std.testing.expectEqual(hal.oam.Tile.BYTES_8BPP, tile.len);
    try std.testing.expectEqual(@as(u8, 42), tile[0]);
    try std.testing.expectEqual(@as(u8, 99), tile[TILE_PIXEL_COUNT - 1]);
}

test "TIL003: sliceSpriteFrame: real asset frame 0 slicing 32x32 (4-bpp vs 8-bpp)" {
    const test_assets = @import("test_palettes");
    const frame0_rect = Rect{ .x = 0, .y = 0, .w = 32, .h = 32 };
    const expected_tiles_32x32 = (32 / TILE_WIDTH) * (32 / TILE_HEIGHT); // 16 tiles

    // 1. Slicing 16-color asset under 4-bpp mode
    var img_16 = try png.decompressIndexedPixels(std.testing.allocator, test_assets.png_pal16);
    defer img_16.deinit();
    var frame_4bpp = try sliceSpriteFrame(std.testing.allocator, &img_16, frame0_rect, .bpp4);
    defer frame_4bpp.deinit();
    try std.testing.expectEqual(expected_tiles_32x32, frame_4bpp.tile_count);
    try std.testing.expectEqual(expected_tiles_32x32 * hal.oam.Tile.BYTES_4BPP, frame_4bpp.bytes.len); // 512 bytes

    // 2. Slicing rich broom asset under 8-bpp mode
    var img_broom = try png.decompressIndexedPixels(std.testing.allocator, test_assets.png_broom);
    defer img_broom.deinit();
    var frame_8bpp = try sliceSpriteFrame(std.testing.allocator, &img_broom, frame0_rect, .bpp8);
    defer frame_8bpp.deinit();
    try std.testing.expectEqual(expected_tiles_32x32, frame_8bpp.tile_count);
    try std.testing.expectEqual(expected_tiles_32x32 * hal.oam.Tile.BYTES_8BPP, frame_8bpp.bytes.len); // 1024 bytes
}

test "TIL004: sliceSpriteFrame: reject invalid dimensions and out of bounds" {
    const test_assets = @import("test_palettes");
    var img = try png.decompressIndexedPixels(std.testing.allocator, test_assets.png_broom);
    defer img.deinit();

    // Invalid non-8-multiple dimensions
    const invalid_dim = Rect{ .x = 0, .y = 0, .w = 10, .h = 10 };
    try std.testing.expectError(error.InvalidDimensions, sliceSpriteFrame(std.testing.allocator, &img, invalid_dim, .bpp4));

    // Out of bounds slice (x: 240, w: 32 -> extends to 272 > image width 256)
    const oob_rect = Rect{ .x = 240, .y = 0, .w = 32, .h = 32 };
    try std.testing.expectError(error.SliceOutOfBounds, sliceSpriteFrame(std.testing.allocator, &img, oob_rect, .bpp4));
}

test "TIL005: sliceSpriteFrame: reject multi-bank color conflict in 4-bpp mode" {
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
