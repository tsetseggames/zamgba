const std = @import("std");

pub const PNG_SIGNATURE = [8]u8{ 137, 80, 78, 71, 13, 10, 26, 10 };

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

pub const PngError = error{
    InvalidPngSignature,
    TruncatedHeader,
    InvalidIhdrChunk,
    NotIndexedColor,
    UnsupportedBitDepth,
};

pub fn parseHeader(bytes: []const u8) PngError!PngHeader {
    if (bytes.len < 33) {
        return error.TruncatedHeader;
    }

    if (!std.mem.eql(u8, bytes[0..8], &PNG_SIGNATURE)) {
        return error.InvalidPngSignature;
    }

    const ihdr_len = std.mem.readInt(u32, bytes[8..12], .big);
    if (ihdr_len != 13) {
        return error.InvalidIhdrChunk;
    }

    if (!std.mem.eql(u8, bytes[12..16], "IHDR")) {
        return error.InvalidIhdrChunk;
    }

    const width = std.mem.readInt(u32, bytes[16..20], .big);
    const height = std.mem.readInt(u32, bytes[20..24], .big);
    const bit_depth = bytes[24];
    const raw_color_type = bytes[25];
    const compression_method = bytes[26];
    const filter_method = bytes[27];
    const interlace_method = bytes[28];

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

test "parse valid indexed PNG header from asset bytes" {
    // Exact 33 header bytes from assets/tsetseg-ride-on-broom-64x64-0001.png
    const valid_indexed_header = [_]u8{
        0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, // PNG Signature
        0x00, 0x00, 0x00, 0x0d,                         // IHDR Length = 13
        0x49, 0x48, 0x44, 0x52,                         // "IHDR"
        0x00, 0x00, 0x01, 0x00,                         // Width = 256
        0x00, 0x00, 0x00, 0x20,                         // Height = 32
        0x08,                                           // Bit Depth = 8
        0x03,                                           // Color Type = 3 (Indexed)
        0x00,                                           // Compression = 0
        0x00,                                           // Filter = 0
        0x00,                                           // Interlace = 0
        0xca, 0x77, 0x56, 0xd6,                         // CRC
    };

    const header = try parseHeader(&valid_indexed_header);
    try std.testing.expectEqual(@as(u32, 256), header.width);
    try std.testing.expectEqual(@as(u32, 32), header.height);
    try std.testing.expectEqual(@as(u8, 8), header.bit_depth);
    try std.testing.expectEqual(ColorType.indexed, header.color_type);
}

test "reject invalid signature" {
    var corrupted = [_]u8{0} ** 33;
    try std.testing.expectError(error.InvalidPngSignature, parseHeader(&corrupted));
}

test "reject non-indexed RGB or RGBA PNG" {
    var rgb_header = [_]u8{
        0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a,
        0x00, 0x00, 0x00, 0x0d,
        0x49, 0x48, 0x44, 0x52,
        0x00, 0x00, 0x00, 0x20,
        0x00, 0x00, 0x00, 0x20,
        0x08,
        0x06, // RGBA Truecolor with alpha (Color Type 6)
        0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00,
    };
    try std.testing.expectError(error.NotIndexedColor, parseHeader(&rgb_header));
}

test "reject truncated header" {
    const short_slice = [_]u8{ 0x89, 0x50, 0x4e, 0x47 };
    try std.testing.expectError(error.TruncatedHeader, parseHeader(&short_slice));
}
