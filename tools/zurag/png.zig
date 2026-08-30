const std = @import("std");
const Color = @import("zamgba-engine").Color;
const unfilter = @import("algo/unfilter.zig");

pub const BppMode = @import("main.zig").BppMode;

const GBA_COLOR_BLACK: u16 = Color.BLACK.toBgr555();

const PNG_SIGNATURE_LEN: usize = 8;
const PNG_SIGNATURE: [PNG_SIGNATURE_LEN]u8 = .{ 137, 80, 78, 71, 13, 10, 26, 10 };

const CHUNK_LEN_SIZE: usize = 4;
const CHUNK_TYPE_SIZE: usize = 4;
const CHUNK_CRC_SIZE: usize = 4;

const IHDR_CHUNK_TYPE: *const [4]u8 = "IHDR";
const PLTE_CHUNK_TYPE: *const [4]u8 = "PLTE";
const IDAT_CHUNK_TYPE: *const [4]u8 = "IDAT";
const IEND_CHUNK_TYPE: *const [4]u8 = "IEND";

const IHDR_DATA_LEN: u32 = 13;
const MIN_PNG_HEADER_LEN: usize = PNG_SIGNATURE_LEN + CHUNK_LEN_SIZE + CHUNK_TYPE_SIZE + IHDR_DATA_LEN + CHUNK_CRC_SIZE;

const BYTES_PER_PALETTE_COLOR: usize = 3;
const MAX_PALETTE_COLORS: usize = 256;
const MAX_PLTE_DATA_LEN: usize = MAX_PALETTE_COLORS * BYTES_PER_PALETTE_COLOR;

const PALETTE_BANKS_COUNT: usize = 16;
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

pub const PngError = PngHeaderError || unfilter.UnfilterError || error{
    MissingPaletteChunk,
    InvalidPaletteChunk,
    ColorCountExceedsLimit,
    MissingIdatChunk,
    DecompressionFailed,
    OutOfMemory,
    Unimplemented,
};

pub const PngAuxChunks = struct {
    has_trns: bool = false,
    has_bkgd: bool = false,
};

pub const IndexedImage = struct {
    width: u32,
    height: u32,
    pixels: []u8,
    aux_chunks: PngAuxChunks = .{},
    allocator: std.mem.Allocator,

    pub fn deinit(self: *IndexedImage) void {
        self.allocator.free(self.pixels);
    }

    pub fn getPixel(self: *const IndexedImage, x: u32, y: u32) u8 {
        return self.pixels[y * self.width + x];
    }
};

/// Decompresses PNG IDAT chunks and restores the uncompressed, unfiltered 2D indexed pixel array.
pub fn decompressIndexedPixels(allocator: std.mem.Allocator, bytes: []const u8) PngError!IndexedImage {
    const header = try parseHeader(bytes);

    var idat_list: std.ArrayList(u8) = .empty;
    defer idat_list.deinit(allocator);

    var offset: usize = MIN_PNG_HEADER_LEN;
    var has_idat = false;
    var aux_chunks = PngAuxChunks{};

    while (offset + CHUNK_LEN_SIZE + CHUNK_TYPE_SIZE + CHUNK_CRC_SIZE <= bytes.len) {
        const chunk_len = std.mem.readInt(u32, bytes[offset..][0..CHUNK_LEN_SIZE], .big);
        const chunk_type = bytes[offset + CHUNK_LEN_SIZE .. offset + CHUNK_LEN_SIZE + CHUNK_TYPE_SIZE];

        const total_chunk_len = CHUNK_LEN_SIZE + CHUNK_TYPE_SIZE + chunk_len + CHUNK_CRC_SIZE;
        if (offset + total_chunk_len > bytes.len) {
            return error.TruncatedHeader;
        }

        if (std.mem.eql(u8, chunk_type, IDAT_CHUNK_TYPE)) {
            has_idat = true;
            const idat_payload = bytes[offset + CHUNK_LEN_SIZE + CHUNK_TYPE_SIZE .. offset + CHUNK_LEN_SIZE + CHUNK_TYPE_SIZE + chunk_len];
            try idat_list.appendSlice(allocator, idat_payload);
        } else if (std.mem.eql(u8, chunk_type, "tRNS")) {
            aux_chunks.has_trns = true;
        } else if (std.mem.eql(u8, chunk_type, "bKGD")) {
            aux_chunks.has_bkgd = true;
        } else if (std.mem.eql(u8, chunk_type, IEND_CHUNK_TYPE)) {
            break;
        }

        offset += total_chunk_len;
    }

    if (!has_idat or idat_list.items.len == 0) {
        return error.MissingIdatChunk;
    }

    var in_reader: std.Io.Reader = .fixed(idat_list.items);
    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();

    var decompress: std.compress.flate.Decompress = .init(&in_reader, .zlib, &.{});
    _ = decompress.reader.streamRemaining(&aw.writer) catch return error.DecompressionFailed;

    const raw_scanlines = aw.written();
    const width: usize = header.width;
    const height: usize = header.height;

    const pixels = try allocator.alloc(u8, width * height);
    errdefer allocator.free(pixels);

    try unfilter.unfilterScanlines(pixels, raw_scanlines, width, height);

    return IndexedImage{
        .width = header.width,
        .height = header.height,
        .pixels = pixels,
        .aux_chunks = aux_chunks,
        .allocator = allocator,
    };
}

pub const PaletteResult = union(enum) {
    bpp4: [16]u16,
    bpp4x16: [16][16]u16,
    bpp8: [256]u16,
};

pub const ExtractPaletteOptions = struct {
    mode: BppMode = .auto,
    color_adjust: bool = false,
};

/// Converts 24-bit RGB (8 bits per channel) to GBA 15-bit BGR555 color.
/// If color_adjust is true, uses full-range rounded scaling: ((c * 31 + 127) / 255).
/// If color_adjust is false, uses standard fast 3-bit truncation: (c >> 3).
pub fn rgbToGba(r: u8, g: u8, b: u8, color_adjust: bool) u16 {
    if (color_adjust) {
        const r5: u16 = @intCast((@as(u32, r) * 31 + 127) / 255);
        const g5: u16 = @intCast((@as(u32, g) * 31 + 127) / 255);
        const b5: u16 = @intCast((@as(u32, b) * 31 + 127) / 255);
        return r5 | (g5 << 5) | (b5 << 10);
    } else {
        const r5: u16 = r >> 3;
        const g5: u16 = g >> 3;
        const b5: u16 = b >> 3;
        return r5 | (g5 << 5) | (b5 << 10);
    }
}

/// Extracts and converts the palette from an indexed PNG according to the requested BppMode and options.
pub fn extractPalette(bytes: []const u8, options: ExtractPaletteOptions) PngError!PaletteResult {
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
                raw_colors[i] = rgbToGba(r, g, b, options.color_adjust);
            }

            const effective_mode: BppMode = switch (options.mode) {
                .auto => if (color_count <= COLORS_PER_BANK) .bpp4 else .bpp8,
                else => options.mode,
            };

            switch (effective_mode) {
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
                .bpp4 => {
                    if (color_count > COLORS_PER_BANK) {
                        return error.ColorCountExceedsLimit;
                    }
                    var pal: [COLORS_PER_BANK]u16 = @splat(GBA_COLOR_BLACK);
                    @memcpy(pal[0..color_count], raw_colors[0..color_count]);
                    return PaletteResult{ .bpp4 = pal };
                },
                .auto => unreachable,
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

// ====================================================================
// PNG Header Parsing Unit Tests
// ====================================================================

test "PNG001: parse valid indexed PNG header from asset bytes" {
    // Exact 33 header bytes from assets/tsetseg-ride-on-broom-64x64-0001.png
    const valid_indexed_header = [_]u8{
        0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, // PNG Signature
        0x00, 0x00, 0x00, 0x0d, // IHDR Length = 13
        0x49, 0x48, 0x44, 0x52, // "IHDR"
        0x00, 0x00, 0x01, 0x00, // Width = 256
        0x00, 0x00, 0x00, 0x20, // Height = 32
        0x08, // Bit Depth = 8
        0x03, // Color Type = 3 (Indexed)
        0x00, // Compression = 0
        0x00, // Filter = 0
        0x00, // Interlace = 0
        0xca, 0x77, 0x56, 0xd6, // CRC
    };

    const header = try parseHeader(&valid_indexed_header);
    try std.testing.expectEqual(@as(u32, 256), header.width);
    try std.testing.expectEqual(@as(u32, 32), header.height);
    try std.testing.expectEqual(@as(u8, 8), header.bit_depth);
    try std.testing.expectEqual(ColorType.indexed, header.color_type);
}

test "PNG002: reject invalid signature" {
    var corrupted = [_]u8{0} ** MIN_PNG_HEADER_LEN;
    try std.testing.expectError(error.InvalidPngSignature, parseHeader(&corrupted));
}

test "PNG003: reject non-indexed RGB or RGBA PNG" {
    var rgb_header = [_]u8{
        0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a,
        0x00, 0x00, 0x00, 0x0d, 0x49, 0x48, 0x44, 0x52,
        0x00, 0x00, 0x00, 0x20, 0x00, 0x00, 0x00, 0x20,
        0x08,
        0x06, // RGBA Truecolor with alpha (Color Type 6)
        0x00,
        0x00,
        0x00,
        0x00,
        0x00,
        0x00,
        0x00,
    };
    try std.testing.expectError(error.NotIndexedColor, parseHeader(&rgb_header));
}

test "PNG004: reject truncated header" {
    const short_slice = [_]u8{ 0x89, 0x50, 0x4e, 0x47 };
    try std.testing.expectError(error.TruncatedHeader, parseHeader(&short_slice));
}

// ====================================================================
// Palette Extraction Unit Tests
// ====================================================================

test "PNG005: reject RGB PNG file on palette extraction" {
    const test_assets = @import("test_palettes");
    try std.testing.expectError(error.NotIndexedColor, extractPalette(test_assets.png_rgb, .{}));
}

test "PNG006: reject palette chunk declaring > 256 colors" {
    const test_assets = @import("test_palettes");
    // Construct fake header + oversized PLTE chunk (257 colors = 771 bytes)
    var fake_png: [MIN_PNG_HEADER_LEN + CHUNK_LEN_SIZE + CHUNK_TYPE_SIZE + 771 + CHUNK_CRC_SIZE]u8 = undefined;
    @memcpy(fake_png[0..MIN_PNG_HEADER_LEN], test_assets.png_pal256[0..MIN_PNG_HEADER_LEN]);
    std.mem.writeInt(u32, fake_png[MIN_PNG_HEADER_LEN .. MIN_PNG_HEADER_LEN + 4], 771, .big);
    @memcpy(fake_png[MIN_PNG_HEADER_LEN + 4 .. MIN_PNG_HEADER_LEN + 8], "PLTE");
    @memset(fake_png[MIN_PNG_HEADER_LEN + 8 .. MIN_PNG_HEADER_LEN + 8 + 771], 0);
    std.mem.writeInt(u32, fake_png[MIN_PNG_HEADER_LEN + 8 + 771 ..][0..4], 0, .big);

    try std.testing.expectError(error.ColorCountExceedsLimit, extractPalette(&fake_png, .{}));
}

test "PNG007: reject missing or malformed PLTE chunk" {
    const test_assets = @import("test_palettes");
    // Missing PLTE chunk
    const no_plte_png = [_]u8{
        0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a,
        0x00, 0x00, 0x00, 0x0d, 'I',  'H',  'D',  'R',
        0x00, 0x00, 0x00, 0x20, 0x00, 0x00, 0x00, 0x20,
        0x08, 0x03, 0x00, 0x00, 0x00, 0xca, 0x77, 0x56,
        0xd6, 0x00, 0x00, 0x00, 0x00, 'I',  'E',  'N',
        'D',  0xae, 0x42, 0x60, 0x82,
    };
    try std.testing.expectError(error.MissingPaletteChunk, extractPalette(&no_plte_png, .{}));

    // Malformed PLTE length (10 bytes, not a multiple of 3)
    var malformed_len_png: [MIN_PNG_HEADER_LEN + CHUNK_LEN_SIZE + CHUNK_TYPE_SIZE + 10 + CHUNK_CRC_SIZE]u8 = undefined;
    @memcpy(malformed_len_png[0..MIN_PNG_HEADER_LEN], test_assets.png_pal256[0..MIN_PNG_HEADER_LEN]);
    std.mem.writeInt(u32, malformed_len_png[MIN_PNG_HEADER_LEN .. MIN_PNG_HEADER_LEN + 4], 10, .big);
    @memcpy(malformed_len_png[MIN_PNG_HEADER_LEN + 4 .. MIN_PNG_HEADER_LEN + 8], "PLTE");
    @memset(malformed_len_png[MIN_PNG_HEADER_LEN + 8 .. MIN_PNG_HEADER_LEN + 8 + 10], 0);
    std.mem.writeInt(u32, malformed_len_png[MIN_PNG_HEADER_LEN + 8 + 10 ..][0..4], 0, .big);

    try std.testing.expectError(error.InvalidPaletteChunk, extractPalette(&malformed_len_png, .{}));
}

test "PNG008: 256-color PNG with --bpp 8 returns full 256 palette" {
    const test_assets = @import("test_palettes");
    const res = try extractPalette(test_assets.png_pal256, .{ .mode = .bpp8 });
    switch (res) {
        .bpp8 => |pal| {
            try std.testing.expectEqual(@as(usize, 256), pal.len);
        },
        else => return error.TestExpectedEqual,
    }
}

test "PNG009: 256-color PNG with --bpp 4x16 returns 16 banks" {
    const test_assets = @import("test_palettes");
    const res = try extractPalette(test_assets.png_pal256, .{ .mode = .bpp4x16 });
    switch (res) {
        .bpp4x16 => |banks| {
            try std.testing.expectEqual(@as(usize, 16), banks.len);
            try std.testing.expectEqual(@as(usize, 16), banks[0].len);
        },
        else => return error.TestExpectedEqual,
    }
}

test "PNG010: 256-color PNG with --bpp 4 errors out" {
    const test_assets = @import("test_palettes");
    try std.testing.expectError(error.ColorCountExceedsLimit, extractPalette(test_assets.png_pal256, .{ .mode = .bpp4 }));
}

test "PNG011: 32-color PNG with --bpp 8 returns 256 palette padded with black" {
    const test_assets = @import("test_palettes");
    const res = try extractPalette(test_assets.png_pal32, .{ .mode = .bpp8 });
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

test "PNG012: 32-color PNG with --bpp 4x16 returns 16 banks with padded trailing banks" {
    const test_assets = @import("test_palettes");
    const res = try extractPalette(test_assets.png_pal32, .{ .mode = .bpp4x16 });
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

test "PNG013: 32-color PNG with --bpp 4 errors out" {
    const test_assets = @import("test_palettes");
    try std.testing.expectError(error.ColorCountExceedsLimit, extractPalette(test_assets.png_pal32, .{ .mode = .bpp4 }));
}

test "PNG014: 32-color PNG with --bpp auto selects 8-bpp mode" {
    const test_assets = @import("test_palettes");
    const res = try extractPalette(test_assets.png_pal32, .{ .mode = .auto });
    switch (res) {
        .bpp8 => {},
        else => return error.TestExpectedEqual,
    }
}

test "PNG015: 16-color PNG with --bpp 4 returns 16-color palette" {
    const test_assets = @import("test_palettes");
    const res = try extractPalette(test_assets.png_pal16, .{ .mode = .bpp4 });
    switch (res) {
        .bpp4 => |pal| {
            try std.testing.expectEqual(@as(usize, 16), pal.len);
        },
        else => return error.TestExpectedEqual,
    }
}

test "PNG016: 16-color PNG with --bpp 4x16 returns 16 banks with banks 1..15 padded" {
    const test_assets = @import("test_palettes");
    const res = try extractPalette(test_assets.png_pal16, .{ .mode = .bpp4x16 });
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

test "PNG017: 16-color PNG with --bpp 8 returns 256 palette padded" {
    const test_assets = @import("test_palettes");
    const res = try extractPalette(test_assets.png_pal16, .{ .mode = .bpp8 });
    switch (res) {
        .bpp8 => |pal| {
            for (pal[16..]) |color| {
                try std.testing.expectEqual(GBA_COLOR_BLACK, color);
            }
        },
        else => return error.TestExpectedEqual,
    }
}

test "PNG018: 16-color PNG with --bpp auto selects 4-bpp mode" {
    const test_assets = @import("test_palettes");
    const res = try extractPalette(test_assets.png_pal16, .{ .mode = .auto });
    switch (res) {
        .bpp4 => {},
        else => return error.TestExpectedEqual,
    }
}

test "PNG019: 8-color PNG with --bpp 4 returns 16 palette padded" {
    const test_assets = @import("test_palettes");
    const res = try extractPalette(test_assets.png_pal8, .{ .mode = .bpp4 });
    switch (res) {
        .bpp4 => |pal| {
            for (pal[8..]) |color| {
                try std.testing.expectEqual(GBA_COLOR_BLACK, color);
            }
        },
        else => return error.TestExpectedEqual,
    }
}

test "PNG020: 8-color PNG with --bpp 4x16 returns 16 banks padded" {
    const test_assets = @import("test_palettes");
    const res = try extractPalette(test_assets.png_pal8, .{ .mode = .bpp4x16 });
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

test "PNG021: 8-color PNG with --bpp 8 returns 256 palette padded" {
    const test_assets = @import("test_palettes");
    const res = try extractPalette(test_assets.png_pal8, .{ .mode = .bpp8 });
    switch (res) {
        .bpp8 => |pal| {
            for (pal[8..]) |color| {
                try std.testing.expectEqual(GBA_COLOR_BLACK, color);
            }
        },
        else => return error.TestExpectedEqual,
    }
}

test "PNG022: 8-color PNG with --bpp auto selects 4-bpp mode" {
    const test_assets = @import("test_palettes");
    const res = try extractPalette(test_assets.png_pal8, .{ .mode = .auto });
    switch (res) {
        .bpp4 => {},
        else => return error.TestExpectedEqual,
    }
}

test "PNG023: rgbToGba conversion accuracy (standard vs color-adjust)" {
    // Standard mode (color_adjust = false)
    try std.testing.expectEqual(Color.BLACK.toBgr555(), rgbToGba(0, 0, 0, false));
    try std.testing.expectEqual(Color.RED.toBgr555(), rgbToGba(255, 0, 0, false));
    try std.testing.expectEqual(Color.LIME.toBgr555(), rgbToGba(0, 255, 0, false));
    try std.testing.expectEqual(Color.BLUE.toBgr555(), rgbToGba(0, 0, 255, false));
    try std.testing.expectEqual(Color.WHITE.toBgr555(), rgbToGba(255, 255, 255, false));
    // Truncation check (7 >> 3 == 0)
    try std.testing.expectEqual(GBA_COLOR_BLACK, rgbToGba(7, 7, 7, false));

    // Color-adjust mode (color_adjust = true)
    try std.testing.expectEqual(Color.BLACK.toBgr555(), rgbToGba(0, 0, 0, true));
    try std.testing.expectEqual(Color.RED.toBgr555(), rgbToGba(255, 0, 0, true));
    try std.testing.expectEqual(Color.LIME.toBgr555(), rgbToGba(0, 255, 0, true));
    try std.testing.expectEqual(Color.BLUE.toBgr555(), rgbToGba(0, 0, 255, true));
    try std.testing.expectEqual(Color.WHITE.toBgr555(), rgbToGba(255, 255, 255, true));
    // Rounded scaling check ((7 * 31 + 127) / 255 == 1)
    try std.testing.expectEqual(@as(u16, 1 | (1 << 5) | (1 << 10)), rgbToGba(7, 7, 7, true));
}

// ====================================================================
// IDAT Decompression Unit Tests
// ====================================================================

test "PNG024: decompressIndexedPixels from real tsetseg flying broom asset" {
    const test_assets = @import("test_palettes");
    var img = try decompressIndexedPixels(std.testing.allocator, test_assets.png_broom);
    defer img.deinit();

    // Verify dimensions & buffer length
    try std.testing.expectEqual(@as(u32, 256), img.width);
    try std.testing.expectEqual(@as(u32, 32), img.height);
    try std.testing.expectEqual(@as(usize, 256 * 32), img.pixels.len);

    // Verify background top-left pixel is transparent color (index 0)
    try std.testing.expectEqual(@as(u8, 0), img.getPixel(0, 0));

    // Sample character area in Frame 0 (center of 32x32 area)
    var found_non_zero = false;
    for (0..32) |y| {
        for (0..32) |x| {
            if (img.getPixel(@intCast(x), @intCast(y)) > 0) {
                found_non_zero = true;
                break;
            }
        }
        if (found_non_zero) break;
    }
    try std.testing.expect(found_non_zero);
}

test "PNG025: decompressIndexedPixels: multiple IDAT chunks concatenation" {
    const test_assets = @import("test_palettes");
    const png_broom = test_assets.png_broom;
    // Locate the original IDAT in png_broom
    var offset: usize = MIN_PNG_HEADER_LEN;
    var idat_offset: usize = 0;
    var idat_len: usize = 0;

    while (offset + CHUNK_LEN_SIZE + CHUNK_TYPE_SIZE + CHUNK_CRC_SIZE <= png_broom.len) {
        const chunk_len = std.mem.readInt(u32, png_broom[offset..][0..CHUNK_LEN_SIZE], .big);
        const chunk_type = png_broom[offset + CHUNK_LEN_SIZE .. offset + CHUNK_LEN_SIZE + CHUNK_TYPE_SIZE];
        if (std.mem.eql(u8, chunk_type, IDAT_CHUNK_TYPE)) {
            idat_offset = offset;
            idat_len = chunk_len;
            break;
        }
        offset += CHUNK_LEN_SIZE + CHUNK_TYPE_SIZE + chunk_len + CHUNK_CRC_SIZE;
    }

    // Split IDAT payload into 2 chunks (half1, half2)
    const half1 = idat_len / 2;
    const half2 = idat_len - half1;
    const payload = png_broom[idat_offset + CHUNK_LEN_SIZE + CHUNK_TYPE_SIZE .. idat_offset + CHUNK_LEN_SIZE + CHUNK_TYPE_SIZE + idat_len];

    var multi_idat_png: std.ArrayList(u8) = .empty;
    defer multi_idat_png.deinit(std.testing.allocator);

    // Copy up to start of original IDAT
    try multi_idat_png.appendSlice(std.testing.allocator, png_broom[0..idat_offset]);

    // Append IDAT 1
    var len_buf1: [4]u8 = undefined;
    std.mem.writeInt(u32, &len_buf1, @intCast(half1), .big);
    try multi_idat_png.appendSlice(std.testing.allocator, &len_buf1);
    try multi_idat_png.appendSlice(std.testing.allocator, IDAT_CHUNK_TYPE);
    try multi_idat_png.appendSlice(std.testing.allocator, payload[0..half1]);
    try multi_idat_png.appendSlice(std.testing.allocator, &[_]u8{ 0, 0, 0, 0 }); // Dummy CRC

    // Append IDAT 2
    var len_buf2: [4]u8 = undefined;
    std.mem.writeInt(u32, &len_buf2, @intCast(half2), .big);
    try multi_idat_png.appendSlice(std.testing.allocator, &len_buf2);
    try multi_idat_png.appendSlice(std.testing.allocator, IDAT_CHUNK_TYPE);
    try multi_idat_png.appendSlice(std.testing.allocator, payload[half1..]);
    try multi_idat_png.appendSlice(std.testing.allocator, &[_]u8{ 0, 0, 0, 0 }); // Dummy CRC

    // Append IEND
    const iend_chunk = [_]u8{ 0, 0, 0, 0, 'I', 'E', 'N', 'D', 0xae, 0x42, 0x60, 0x82 };
    try multi_idat_png.appendSlice(std.testing.allocator, &iend_chunk);

    var img = try decompressIndexedPixels(std.testing.allocator, multi_idat_png.items);
    defer img.deinit();

    try std.testing.expectEqual(@as(u32, 256), img.width);
    try std.testing.expectEqual(@as(u32, 32), img.height);
}

test "PNG026: decompressIndexedPixels: detect tRNS and bKGD auxiliary chunks" {
    const test_assets = @import("test_palettes");
    const png_broom = test_assets.png_broom;
    // 1. Real asset png_broom contains tRNS
    var img = try decompressIndexedPixels(std.testing.allocator, png_broom);
    defer img.deinit();
    try std.testing.expect(img.aux_chunks.has_trns);
    try std.testing.expect(!img.aux_chunks.has_bkgd);

    // 2. Insert synthetic bKGD chunk
    var bkgd_png: std.ArrayList(u8) = .empty;
    defer bkgd_png.deinit(std.testing.allocator);

    try bkgd_png.appendSlice(std.testing.allocator, png_broom[0..MIN_PNG_HEADER_LEN]);
    // bKGD chunk: length 1, type bKGD, data 0x00, crc 0x00000000
    try bkgd_png.appendSlice(std.testing.allocator, &[_]u8{ 0, 0, 0, 1, 'b', 'K', 'G', 'D', 0, 0, 0, 0, 0 });
    try bkgd_png.appendSlice(std.testing.allocator, png_broom[MIN_PNG_HEADER_LEN..]);

    var img_bkgd = try decompressIndexedPixels(std.testing.allocator, bkgd_png.items);
    defer img_bkgd.deinit();
    try std.testing.expect(img_bkgd.aux_chunks.has_bkgd);
}

test "PNG027: decompressIndexedPixels error on missing or corrupted IDAT" {
    // PNG with no IDAT
    const no_idat = [_]u8{
        0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a,
        0x00, 0x00, 0x00, 0x0d, 'I',  'H',  'D',  'R',
        0x00, 0x00, 0x00, 0x20, 0x00, 0x00, 0x00, 0x20,
        0x08, 0x03, 0x00, 0x00, 0x00, 0xca, 0x77, 0x56,
        0xd6, 0x00, 0x00, 0x00, 0x00, 'I',  'E',  'N',
        'D',  0xae, 0x42, 0x60, 0x82,
    };
    try std.testing.expectError(error.MissingIdatChunk, decompressIndexedPixels(std.testing.allocator, &no_idat));

    // PNG with corrupted IDAT payload
    const corrupted_idat = [_]u8{
        0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a,
        0x00, 0x00, 0x00, 0x0d, 'I',  'H',  'D',  'R',
        0x00, 0x00, 0x00, 0x20, 0x00, 0x00, 0x00, 0x20,
        0x08, 0x03, 0x00, 0x00, 0x00, 0xca, 0x77, 0x56,
        0xd6, 0x00, 0x00, 0x00, 0x04, 'I',  'D',  'A',
        'T',
        0xff, 0xff, 0xff, 0xff, // Invalid zlib header/stream
        0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00,
        'I',  'E',  'N',  'D',
        0xae, 0x42, 0x60, 0x82,
    };
    try std.testing.expectError(error.DecompressionFailed, decompressIndexedPixels(std.testing.allocator, &corrupted_idat));
}
