const std = @import("std");
pub const paeth = @import("paeth.zig");

pub const FilterType = enum(u8) {
    none = 0,
    sub = 1,
    up = 2,
    average = 3,
    paeth = 4,
    _,
};

pub const UnfilterError = error{
    InvalidFilterType,
    InvalidScanlineLength,
    Unimplemented,
};

/// Frame-level scanline unfilter entry point.
pub fn unfilterScanlines(
    pixels: []u8,
    raw_scanlines: []const u8,
    width: usize,
    height: usize,
) UnfilterError!void {
    const stride = width; // 1 byte per pixel for 8-bit indexed
    const row_size = 1 + stride;
    if (raw_scanlines.len != height * row_size) {
        return error.InvalidScanlineLength;
    }

    for (0..height) |y| {
        const row_start = y * row_size;
        const raw_filter = raw_scanlines[row_start];
        const src_row = raw_scanlines[row_start + 1 .. row_start + row_size];
        const dst_row = pixels[y * stride .. (y + 1) * stride];
        const prev_row = if (y > 0) pixels[(y - 1) * stride .. y * stride] else null;

        const filter_type: FilterType = @enumFromInt(raw_filter);

        switch (filter_type) {
            .none => {
                @memcpy(dst_row, src_row);
            },
            .sub => {
                var a: u8 = 0;
                for (0..stride) |x| {
                    const val = src_row[x] +% a;
                    dst_row[x] = val;
                    a = val;
                }
            },
            .up => {
                for (0..stride) |x| {
                    const b: u8 = if (prev_row) |p| p[x] else 0;
                    dst_row[x] = src_row[x] +% b;
                }
            },
            .average => {
                var a: u8 = 0;
                for (0..stride) |x| {
                    const b: u8 = if (prev_row) |p| p[x] else 0;
                    const avg: u8 = @intCast((@as(u16, a) + @as(u16, b)) / 2);
                    const val = src_row[x] +% avg;
                    dst_row[x] = val;
                    a = val;
                }
            },
            .paeth => {
                var a: u8 = 0;
                for (0..stride) |x| {
                    const b: u8 = if (prev_row) |p| p[x] else 0;
                    const c: u8 = if (x > 0 and prev_row != null) prev_row.?[x - 1] else 0;
                    const p = paeth.paethPredictor(a, b, c);
                    const val = src_row[x] +% p;
                    dst_row[x] = val;
                    a = val;
                }
            },
            _ => return error.InvalidFilterType,
        }
    }
}

test "unfilterScanlines row 0 boundary conditions for Up, Average, and Paeth" {
    // 3 pixels per row, 3 independent single-row tests
    // 1. Row 0 with Filter 2 (Up): Above is assumed 0 -> Recon = src
    const raw_row0_up = [_]u8{ 2, 10, 20, 30 };
    var pixels_up: [3]u8 = undefined;
    try unfilterScanlines(&pixels_up, &raw_row0_up, 3, 1);
    try std.testing.expectEqual(@as(u8, 10), pixels_up[0]);
    try std.testing.expectEqual(@as(u8, 20), pixels_up[1]);
    try std.testing.expectEqual(@as(u8, 30), pixels_up[2]);

    // 2. Row 0 with Filter 3 (Average): Above is assumed 0 -> avg = floor(left / 2)
    const raw_row0_avg = [_]u8{ 3, 10, 20, 30 };
    var pixels_avg: [3]u8 = undefined;
    try unfilterScanlines(&pixels_avg, &raw_row0_avg, 3, 1);
    // x=0: a=0, b=0 -> avg=0 -> 10
    try std.testing.expectEqual(@as(u8, 10), pixels_avg[0]);
    // x=1: a=10, b=0 -> avg=5 -> 20 + 5 = 25
    try std.testing.expectEqual(@as(u8, 25), pixels_avg[1]);
    // x=2: a=25, b=0 -> avg=12 -> 30 + 12 = 42
    try std.testing.expectEqual(@as(u8, 42), pixels_avg[2]);

    // 3. Row 0 with Filter 4 (Paeth): Above and upper-left are assumed 0
    const raw_row0_paeth = [_]u8{ 4, 10, 20, 30 };
    var pixels_paeth: [3]u8 = undefined;
    try unfilterScanlines(&pixels_paeth, &raw_row0_paeth, 3, 1);
    // x=0: a=0, b=0, c=0 -> Paeth=0 -> 10
    try std.testing.expectEqual(@as(u8, 10), pixels_paeth[0]);
    // x=1: a=10, b=0, c=0 -> Paeth=10 -> 20 + 10 = 30
    try std.testing.expectEqual(@as(u8, 30), pixels_paeth[1]);
    // x=2: a=30, b=0, c=0 -> Paeth=30 -> 30 + 30 = 60
    try std.testing.expectEqual(@as(u8, 60), pixels_paeth[2]);
}

test "unfilterScanlines subsequent rows referencing prior row for Up, Average, and Paeth" {
    // 3 pixels per row, 4 consecutive rows
    const raw_scanlines = [_]u8{
        // Row 0 (None): 10, 20, 30 -> Recon_0 = [10, 20, 30]
        0, 10, 20, 30,
        // Row 1 (Up): 5, 5, 5 -> Recon_1 = [10+5, 20+5, 30+5] = [15, 25, 35]
        2, 5,  5,  5,
        // Row 2 (Average): 4, 4, 4 (using Recon_1 = [15, 25, 35])
        // x=0: a=0, b=15 -> avg=7 -> 4+7 = 11
        // x=1: a=11, b=25 -> avg=18 -> 4+18 = 22
        // x=2: a=22, b=35 -> avg=28 -> 4+28 = 32
        // Recon_2 = [11, 22, 32]
        3, 4,  4,  4,
        // Row 3 (Paeth): 2, 2, 2 (using Recon_2 = [11, 22, 32])
        // x=0: a=0, b=11, c=0 -> Paeth=11 -> 2+11 = 13
        // x=1: a=13, b=22, c=11 -> p=24 -> Paeth=22 (b) -> 2+22 = 24
        // x=2: a=24, b=32, c=22 -> p=34 -> Paeth=32 (b) -> 2+32 = 34
        // Recon_3 = [13, 24, 34]
        4, 2,  2,  2,
    };

    var pixels: [3 * 4]u8 = undefined;
    try unfilterScanlines(&pixels, &raw_scanlines, 3, 4);

    // Verify Row 0 (None)
    try std.testing.expectEqual(@as(u8, 10), pixels[0]);
    try std.testing.expectEqual(@as(u8, 20), pixels[1]);
    try std.testing.expectEqual(@as(u8, 30), pixels[2]);

    // Verify Row 1 (Up)
    try std.testing.expectEqual(@as(u8, 15), pixels[3]);
    try std.testing.expectEqual(@as(u8, 25), pixels[4]);
    try std.testing.expectEqual(@as(u8, 35), pixels[5]);

    // Verify Row 2 (Average)
    try std.testing.expectEqual(@as(u8, 11), pixels[6]);
    try std.testing.expectEqual(@as(u8, 22), pixels[7]);
    try std.testing.expectEqual(@as(u8, 32), pixels[8]);

    // Verify Row 3 (Paeth)
    try std.testing.expectEqual(@as(u8, 13), pixels[9]);
    try std.testing.expectEqual(@as(u8, 24), pixels[10]);
    try std.testing.expectEqual(@as(u8, 34), pixels[11]);
}
