const std = @import("std");
const Color = @import("zamgba-engine").Color;

pub const BppMode = @import("main.zig").BppMode;

pub const GBA_COLOR_BLACK: u16 = Color.BLACK.toBgr555();

pub const PNG_SIGNATURE_LEN: usize = 8;
pub const PNG_SIGNATURE: [PNG_SIGNATURE_LEN]u8 = .{ 137, 80, 78, 71, 13, 10, 26, 10 };

pub const CHUNK_LEN_SIZE: usize = 4;
pub const CHUNK_TYPE_SIZE: usize = 4;
pub const CHUNK_CRC_SIZE: usize = 4;

pub const IHDR_CHUNK_TYPE: *const [4]u8 = "IHDR";
pub const PLTE_CHUNK_TYPE: *const [4]u8 = "PLTE";
pub const IEND_CHUNK_TYPE: *const [4]u8 = "IEND";

pub const IHDR_DATA_LEN: u32 = 13;
pub const MIN_PNG_HEADER_LEN: usize = PNG_SIGNATURE_LEN + CHUNK_LEN_SIZE + CHUNK_TYPE_SIZE + IHDR_DATA_LEN + CHUNK_CRC_SIZE;

pub const BYTES_PER_PALETTE_COLOR: usize = 3;
pub const MAX_PALETTE_COLORS: usize = 256;
pub const MAX_PLTE_DATA_LEN: usize = MAX_PALETTE_COLORS * BYTES_PER_PALETTE_COLOR;

pub const PALETTE_BANKS_COUNT: usize = 16;
pub const COLORS_PER_BANK: usize = 16;

// Byte offsets for parsing the PNG header and IHDR chunk
const IHDR_LEN_START: usize = PNG_SIGNATURE_LEN;
const IHDR_LEN_END: usize = IHDR_LEN_START + CHUNK_LEN_SIZE;

const IHDR_TYPE_START: usize = IHDR_LEN_END;
const IHDR_TYPE_END: usize = IHDR_TYPE_START + CHUNK_TYPE_SIZE;

const IHDR_DATA_START: usize = IHDR_TYPE_END;
const IHDR_WIDTH_START: usize = IHDR_DATA_START + 0;
const IHDR_WIDTH_END: usize = IHDR_WIDTH_START + 4;

const IHDR_HEIGHT_START: usize = IHDR_WIDTH_END;
const IHDR_HEIGHT_END: usize = IHDR_HEIGHT_START + 4;

const IHDR_BIT_DEPTH_POS: usize = IHDR_HEIGHT_END;
const IHDR_COLOR_TYPE_POS: usize = IHDR_BIT_DEPTH_POS + 1;
const IHDR_COMPRESSION_POS: usize = IHDR_COLOR_TYPE_POS + 1;
const IHDR_FILTER_POS: usize = IHDR_COMPRESSION_POS + 1;
const IHDR_INTERLACE_POS: usize = IHDR_FILTER_POS + 1;

pub const ColorType = enum(u8) {
    grayscale = 0,
    truecolor = 2,
    indexed = 3,
    grayscale_alpha = 4,
    truecolor_alpha = 6,
    _,
};

pub const PngHeader = struct {
    width: u32,
    height: u32,
    bit_depth: u8,
    color_type: ColorType,
    compression_method: u8,
    filter_method: u8,
    interlace_method: u8,
};

pub const PngHeaderError = error{
    InvalidPngSignature,
    TruncatedHeader,
    InvalidIhdrChunk,
    NotIndexedColor,
    UnsupportedBitDepth,
};

pub const PngError = PngHeaderError || error{
    MissingPaletteChunk,
    InvalidPaletteChunk,
    ColorCountExceedsLimit,
    Unimplemented,
};

pub const PaletteResult = union(enum) {
    bpp4: [16]u16,
    bpp4x16: [16][16]u16,
    bpp8: [256]u16,
};

/// Converts 24-bit RGB (8 bits per channel) to GBA 15-bit BGR555 color.
pub fn rgbToGba(r: u8, g: u8, b: u8) u16 {
    const r5: u16 = r >> 3;
    const g5: u16 = g >> 3;
    const b5: u16 = b >> 3;
    return r5 | (g5 << 5) | (b5 << 10);
}

/// Extracts and converts the palette from an indexed PNG according to the requested BppMode.
pub fn extractPalette(bytes: []const u8, mode: BppMode) PngError!PaletteResult {
    _ = try parseHeader(bytes);

    var offset: usize = MIN_PNG_HEADER_LEN;

    while (offset + CHUNK_LEN_SIZE + CHUNK_TYPE_SIZE + CHUNK_CRC_SIZE <= bytes.len) {
        const chunk_len = std.mem.readInt(u32, bytes[offset..][0..CHUNK_LEN_SIZE], .big);
        const chunk_type = bytes[offset + CHUNK_LEN_SIZE .. offset + CHUNK_LEN_SIZE + CHUNK_TYPE_SIZE];

        const total_chunk_len = CHUNK_LEN_SIZE + CHUNK_TYPE_SIZE + chunk_len + CHUNK_CRC_SIZE;
        if (offset + total_chunk_len > bytes.len) {
            return error.TruncatedHeader;
        }

        if (std.mem.eql(u8, chunk_type, PLTE_CHUNK_TYPE)) {
            if (chunk_len > MAX_PLTE_DATA_LEN) {
                return error.ColorCountExceedsLimit;
            }
            if (chunk_len % BYTES_PER_PALETTE_COLOR != 0) {
                return error.InvalidPaletteChunk;
            }

            const plte_data = bytes[offset + CHUNK_LEN_SIZE + CHUNK_TYPE_SIZE .. offset + CHUNK_LEN_SIZE + CHUNK_TYPE_SIZE + chunk_len];
            const color_count = chunk_len / BYTES_PER_PALETTE_COLOR;

            var raw_colors: [MAX_PALETTE_COLORS]u16 = @splat(GBA_COLOR_BLACK);
            for (0..color_count) |i| {
                const r = plte_data[i * BYTES_PER_PALETTE_COLOR + 0];
                const g = plte_data[i * BYTES_PER_PALETTE_COLOR + 1];
                const b = plte_data[i * BYTES_PER_PALETTE_COLOR + 2];
                raw_colors[i] = rgbToGba(r, g, b);
            }

            switch (mode) {
                .bpp8 => {
                    return PaletteResult{ .bpp8 = raw_colors };
                },
                .bpp4x16 => {
                    var banks: [PALETTE_BANKS_COUNT][COLORS_PER_BANK]u16 = @splat(@splat(GBA_COLOR_BLACK));
                    for (0..PALETTE_BANKS_COUNT) |b| {
                        for (0..COLORS_PER_BANK) |c| {
                            banks[b][c] = raw_colors[b * COLORS_PER_BANK + c];
                        }
                    }
                    return PaletteResult{ .bpp4x16 = banks };
                },
                else => {
                    return error.Unimplemented;
                },
            }
        }

        if (std.mem.eql(u8, chunk_type, IEND_CHUNK_TYPE)) {
            break;
        }

        offset += total_chunk_len;
    }

    return error.MissingPaletteChunk;
}

pub fn parseHeader(bytes: []const u8) PngHeaderError!PngHeader {
    if (bytes.len < MIN_PNG_HEADER_LEN) {
        return error.TruncatedHeader;
    }

    if (!std.mem.eql(u8, bytes[0..PNG_SIGNATURE_LEN], &PNG_SIGNATURE)) {
        return error.InvalidPngSignature;
    }

    const ihdr_len = std.mem.readInt(u32, bytes[IHDR_LEN_START..IHDR_LEN_END], .big);
    if (ihdr_len != IHDR_DATA_LEN) {
        return error.InvalidIhdrChunk;
    }

    if (!std.mem.eql(u8, bytes[IHDR_TYPE_START..IHDR_TYPE_END], IHDR_CHUNK_TYPE)) {
        return error.InvalidIhdrChunk;
    }

    const width = std.mem.readInt(u32, bytes[IHDR_WIDTH_START..IHDR_WIDTH_END], .big);
    const height = std.mem.readInt(u32, bytes[IHDR_HEIGHT_START..IHDR_HEIGHT_END], .big);
    const bit_depth = bytes[IHDR_BIT_DEPTH_POS];
    const raw_color_type = bytes[IHDR_COLOR_TYPE_POS];
    const compression_method = bytes[IHDR_COMPRESSION_POS];
    const filter_method = bytes[IHDR_FILTER_POS];
    const interlace_method = bytes[IHDR_INTERLACE_POS];

    const color_type: ColorType = @enumFromInt(raw_color_type);

    if (color_type != .indexed) {
        return error.NotIndexedColor;
    }

    if (bit_depth != 1 and bit_depth != 2 and bit_depth != 4 and bit_depth != 8) {
        return error.UnsupportedBitDepth;
    }

    return .{
        .width = width,
        .height = height,
        .bit_depth = bit_depth,
        .color_type = color_type,
        .compression_method = compression_method,
        .filter_method = filter_method,
        .interlace_method = interlace_method,
    };
}

// Compile-time embedded test assets (no runtime disk reading)
const test_palettes = if (@hasDecl(root, "test_palettes")) @import("test_palettes") else struct {
    pub const png_rgb: []const u8 = "";
    pub const png_pal256: []const u8 = "";
    pub const png_pal32: []const u8 = "";
    pub const png_pal16: []const u8 = "";
    pub const png_pal8: []const u8 = "";
};
const root = @import("root");
const png_rgb = @import("test_palettes").png_rgb;
const png_pal256 = @import("test_palettes").png_pal256;
const png_pal32 = @import("test_palettes").png_pal32;
const png_pal16 = @import("test_palettes").png_pal16;
const png_pal8 = @import("test_palettes").png_pal8;

// ====================================================================
// 19 TDD Test Cases for Palette Extraction
// ====================================================================

// Test 1: RGB/RGBA PNG mode -> errors out with NotIndexedColor
test "TDD 01: reject RGB PNG file" {
    try std.testing.expectError(error.NotIndexedColor, extractPalette(png_rgb, .auto));
}

// Test 2: Corrupted PLTE with > 256 colors
test "TDD 02: reject palette chunk declaring > 256 colors" {
    // Construct fake header + oversized PLTE chunk (257 colors = 771 bytes)
    var fake_png: [MIN_PNG_HEADER_LEN + CHUNK_LEN_SIZE + CHUNK_TYPE_SIZE + 771 + CHUNK_CRC_SIZE]u8 = undefined;
    @memcpy(fake_png[0..MIN_PNG_HEADER_LEN], png_pal256[0..MIN_PNG_HEADER_LEN]);
    std.mem.writeInt(u32, fake_png[MIN_PNG_HEADER_LEN .. MIN_PNG_HEADER_LEN + 4], 771, .big);
    @memcpy(fake_png[MIN_PNG_HEADER_LEN + 4 .. MIN_PNG_HEADER_LEN + 8], "PLTE");
    @memset(fake_png[MIN_PNG_HEADER_LEN + 8 .. MIN_PNG_HEADER_LEN + 8 + 771], 0);
    std.mem.writeInt(u32, fake_png[MIN_PNG_HEADER_LEN + 8 + 771 ..][0..4], 0, .big);

    try std.testing.expectError(error.ColorCountExceedsLimit, extractPalette(&fake_png, .auto));
}

// Test 3: Missing PLTE or non-multiple-of-3 length
test "TDD 03: reject missing or malformed PLTE chunk" {
    // Missing PLTE chunk
    const no_plte_png = [_]u8{
        0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a,
        0x00, 0x00, 0x00, 0x0d, 'I',  'H',  'D',  'R',
        0x00, 0x00, 0x00, 0x20, 0x00, 0x00, 0x00, 0x20,
        0x08, 0x03, 0x00, 0x00, 0x00, 0xca, 0x77, 0x56,
        0xd6, 0x00, 0x00, 0x00, 0x00, 'I',  'E',  'N',
        'D',  0xae, 0x42, 0x60, 0x82,
    };
    try std.testing.expectError(error.MissingPaletteChunk, extractPalette(&no_plte_png, .auto));

    // Malformed PLTE length (10 bytes, not a multiple of 3)
    var malformed_len_png: [MIN_PNG_HEADER_LEN + CHUNK_LEN_SIZE + CHUNK_TYPE_SIZE + 10 + CHUNK_CRC_SIZE]u8 = undefined;
    @memcpy(malformed_len_png[0..MIN_PNG_HEADER_LEN], png_pal256[0..MIN_PNG_HEADER_LEN]);
    std.mem.writeInt(u32, malformed_len_png[MIN_PNG_HEADER_LEN .. MIN_PNG_HEADER_LEN + 4], 10, .big);
    @memcpy(malformed_len_png[MIN_PNG_HEADER_LEN + 4 .. MIN_PNG_HEADER_LEN + 8], "PLTE");
    @memset(malformed_len_png[MIN_PNG_HEADER_LEN + 8 .. MIN_PNG_HEADER_LEN + 8 + 10], 0);
    std.mem.writeInt(u32, malformed_len_png[MIN_PNG_HEADER_LEN + 8 + 10 ..][0..4], 0, .big);

    try std.testing.expectError(error.InvalidPaletteChunk, extractPalette(&malformed_len_png, .auto));
}

// Test 4: 256 colors, --bpp 8 -> returns 256 colors
test "TDD 04: 256-color PNG with --bpp 8 returns full 256 palette" {
    const res = try extractPalette(png_pal256, .bpp8);
    switch (res) {
        .bpp8 => |pal| {
            try std.testing.expectEqual(@as(usize, 256), pal.len);
        },
        else => return error.TestExpectedEqual,
    }
}

// Test 5: 256 colors, --bpp 4x16 -> returns 16 banks of 16 colors
test "TDD 05: 256-color PNG with --bpp 4x16 returns 16 banks" {
    const res = try extractPalette(png_pal256, .bpp4x16);
    switch (res) {
        .bpp4x16 => |banks| {
            try std.testing.expectEqual(@as(usize, 16), banks.len);
            try std.testing.expectEqual(@as(usize, 16), banks[0].len);
        },
        else => return error.TestExpectedEqual,
    }
}

// Test 6: 256 colors, --bpp 4 -> errors out (exceeds 16 colors)
test "TDD 06: 256-color PNG with --bpp 4 errors out" {
    try std.testing.expectError(error.ColorCountExceedsLimit, extractPalette(png_pal256, .bpp4));
}

// Test 7: 32 colors, --bpp 8 -> returns 256 colors with 0x0000 padding
test "TDD 07: 32-color PNG with --bpp 8 returns 256 palette padded with black" {
    const res = try extractPalette(png_pal32, .bpp8);
    switch (res) {
        .bpp8 => |pal| {
            // Colors after index 31 must be padded with GBA_COLOR_BLACK
            for (pal[32..]) |color| {
                try std.testing.expectEqual(GBA_COLOR_BLACK, color);
            }
        },
        else => return error.TestExpectedEqual,
    }
}

// Test 8: 32 colors, --bpp 4x16 -> returns 16 banks with banks 2..15 padded with 0x0000
test "TDD 08: 32-color PNG with --bpp 4x16 returns 16 banks with padded trailing banks" {
    const res = try extractPalette(png_pal32, .bpp4x16);
    switch (res) {
        .bpp4x16 => |banks| {
            for (banks[2..]) |bank| {
                for (bank) |color| {
                    try std.testing.expectEqual(GBA_COLOR_BLACK, color);
                }
            }
        },
        else => return error.TestExpectedEqual,
    }
}

// Test 9: 32 colors, --bpp 4 -> errors out (exceeds 16 colors)
test "TDD 09: 32-color PNG with --bpp 4 errors out" {
    try std.testing.expectError(error.ColorCountExceedsLimit, extractPalette(png_pal32, .bpp4));
}

// Test 10: 32 colors, --bpp auto -> automatically selects 8-bpp mode
test "TDD 10: 32-color PNG with --bpp auto selects 8-bpp mode" {
    const res = try extractPalette(png_pal32, .auto);
    switch (res) {
        .bpp8 => {},
        else => return error.TestExpectedEqual,
    }
}

// Test 11: 16 colors, --bpp 4 -> returns 16 colors
test "TDD 11: 16-color PNG with --bpp 4 returns 16-color palette" {
    const res = try extractPalette(png_pal16, .bpp4);
    switch (res) {
        .bpp4 => |pal| {
            try std.testing.expectEqual(@as(usize, 16), pal.len);
        },
        else => return error.TestExpectedEqual,
    }
}

// Test 12: 16 colors, --bpp 4x16 -> returns 16 banks with banks 1..15 padded with 0x0000
test "TDD 12: 16-color PNG with --bpp 4x16 returns 16 banks with banks 1..15 padded" {
    const res = try extractPalette(png_pal16, .bpp4x16);
    switch (res) {
        .bpp4x16 => |banks| {
            for (banks[1..]) |bank| {
                for (bank) |color| {
                    try std.testing.expectEqual(GBA_COLOR_BLACK, color);
                }
            }
        },
        else => return error.TestExpectedEqual,
    }
}

// Test 13: 16 colors, --bpp 8 -> returns 256 colors with indices 16..255 padded with 0x0000
test "TDD 13: 16-color PNG with --bpp 8 returns 256 palette padded" {
    const res = try extractPalette(png_pal16, .bpp8);
    switch (res) {
        .bpp8 => |pal| {
            for (pal[16..]) |color| {
                try std.testing.expectEqual(GBA_COLOR_BLACK, color);
            }
        },
        else => return error.TestExpectedEqual,
    }
}

// Test 14: 16 colors, --bpp auto -> automatically selects 4-bpp mode
test "TDD 14: 16-color PNG with --bpp auto selects 4-bpp mode" {
    const res = try extractPalette(png_pal16, .auto);
    switch (res) {
        .bpp4 => {},
        else => return error.TestExpectedEqual,
    }
}

// Test 15: 8 colors, --bpp 4 -> returns 16 colors with indices 8..15 padded with 0x0000
test "TDD 15: 8-color PNG with --bpp 4 returns 16 palette padded" {
    const res = try extractPalette(png_pal8, .bpp4);
    switch (res) {
        .bpp4 => |pal| {
            for (pal[8..]) |color| {
                try std.testing.expectEqual(GBA_COLOR_BLACK, color);
            }
        },
        else => return error.TestExpectedEqual,
    }
}

// Test 16: 8 colors, --bpp 4x16 -> returns 16 banks with bank 0 padded and banks 1..15 zeroed
test "TDD 16: 8-color PNG with --bpp 4x16 returns 16 banks padded" {
    const res = try extractPalette(png_pal8, .bpp4x16);
    switch (res) {
        .bpp4x16 => |banks| {
            for (banks[0][8..]) |color| {
                try std.testing.expectEqual(GBA_COLOR_BLACK, color);
            }
            for (banks[1..]) |bank| {
                for (bank) |color| {
                    try std.testing.expectEqual(GBA_COLOR_BLACK, color);
                }
            }
        },
        else => return error.TestExpectedEqual,
    }
}

// Test 17: 8 colors, --bpp 8 -> returns 256 colors with indices 8..255 padded with 0x0000
test "TDD 17: 8-color PNG with --bpp 8 returns 256 palette padded" {
    const res = try extractPalette(png_pal8, .bpp8);
    switch (res) {
        .bpp8 => |pal| {
            for (pal[8..]) |color| {
                try std.testing.expectEqual(GBA_COLOR_BLACK, color);
            }
        },
        else => return error.TestExpectedEqual,
    }
}

// Test 18: 8 colors, --bpp auto -> automatically selects 4-bpp mode
test "TDD 18: 8-color PNG with --bpp auto selects 4-bpp mode" {
    const res = try extractPalette(png_pal8, .auto);
    switch (res) {
        .bpp4 => {},
        else => return error.TestExpectedEqual,
    }
}

// Test 19: BGR555 conversion precision for standard extreme colors
test "TDD 19: rgbToGba conversion accuracy" {
    try std.testing.expectEqual(Color.BLACK.toBgr555(), rgbToGba(0, 0, 0)); // Black
    try std.testing.expectEqual(Color.RED.toBgr555(), rgbToGba(255, 0, 0)); // Red: R=31, G=0, B=0
    try std.testing.expectEqual(Color.LIME.toBgr555(), rgbToGba(0, 255, 0)); // Green: R=0, G=31, B=0
    try std.testing.expectEqual(Color.BLUE.toBgr555(), rgbToGba(0, 0, 255)); // Blue: R=0, G=0, B=31
    try std.testing.expectEqual(Color.WHITE.toBgr555(), rgbToGba(255, 255, 255)); // White: R=31, G=31, B=31
    // Truncation check (lower 3 bits discarded: 7 >> 3 == 0)
    try std.testing.expectEqual(GBA_COLOR_BLACK, rgbToGba(7, 7, 7));
}
