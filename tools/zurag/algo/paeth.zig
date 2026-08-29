const std = @import("std");

/// Paeth linear extrapolation predictor pure function.
pub fn paethPredictor(a: u8, b: u8, c: u8) u8 {
    const p: i32 = @as(i32, a) + @as(i32, b) - @as(i32, c);
    const pa = @abs(p - @as(i32, a));
    const pb = @abs(p - @as(i32, b));
    const pc = @abs(p - @as(i32, c));
    if (pa <= pb and pa <= pc) return a;
    if (pb <= pc) return b;
    return c;
}

test "paethPredictor algorithm accuracy and tie-breaking" {
    // 1. Vertical tendency (b == c) -> choose a (10)
    try std.testing.expectEqual(@as(u8, 10), paethPredictor(10, 20, 20));

    // 2. Horizontal tendency (a == c) -> choose b (10)
    try std.testing.expectEqual(@as(u8, 10), paethPredictor(20, 10, 20));

    // 3. Diagonal tendency (closest to c) -> choose c (120)
    try std.testing.expectEqual(@as(u8, 120), paethPredictor(100, 150, 120));

    // 4. All equal tie -> choose a (50)
    try std.testing.expectEqual(@as(u8, 50), paethPredictor(50, 50, 50));

    // 5. a and b tie and closer than c -> prefer a (20)
    try std.testing.expectEqual(@as(u8, 20), paethPredictor(20, 20, 10));

    // 6. Extreme boundary test (0 and 255) -> choose b (255)
    try std.testing.expectEqual(@as(u8, 255), paethPredictor(0, 255, 0));
}
