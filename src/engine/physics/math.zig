const std = @import("std");

/// Signed 24.8 fixed-point number based on i32.
/// High 24 bits for the signed integer part, low 8 bits for the fractional part.
pub const Fixed24_8 = struct {
    raw: i32,

    pub const zero = Fixed24_8{ .raw = 0 };

    pub const fraction_bits = 8;
    pub const scale: i32 = 1 << fraction_bits;

    /// Create a Fixed24_8 from a signed integer.
    pub fn fromInt(i: i32) Fixed24_8 {
        return .{ .raw = i << fraction_bits };
    }

    /// Create a Fixed24_8 from a comptime-known float literal.
    /// Evaluated purely at compile-time with zero runtime floating-point overhead.
    pub fn fromFloat(comptime f: comptime_float) Fixed24_8 {
        return .{ .raw = @as(i32, @intFromFloat(f * @as(comptime_float, scale))) };
    }

    /// Create a Fixed24_8 from an integer part and an 8-bit fraction (0-255).
    pub fn fromParts(integer: i32, fraction: u8) Fixed24_8 {
        if (integer < 0) {
            return .{ .raw = (integer << fraction_bits) - @as(i32, fraction) };
        } else {
            return .{ .raw = (integer << fraction_bits) + @as(i32, fraction) };
        }
    }

    /// Create a Fixed24_8 from an integer and a fraction (numerator / denominator).
    pub fn fromFraction(integer: i32, numerator: i32, denominator: i32) Fixed24_8 {
        const frac = @divTrunc((numerator * scale), denominator);
        return .{ .raw = (integer << fraction_bits) + frac };
    }

    /// Convert back to an integer (arithmetic right shift preserves sign).
    pub fn toInt(self: Fixed24_8) i32 {
        return self.raw >> fraction_bits;
    }

    /// Negate a fixed-point number.
    pub fn neg(self: Fixed24_8) Fixed24_8 {
        return .{ .raw = -self.raw };
    }

    /// Add two fixed-point numbers.
    pub fn add(self: Fixed24_8, other: Fixed24_8) Fixed24_8 {
        return .{ .raw = self.raw + other.raw };
    }

    /// Subtract two fixed-point numbers.
    pub fn sub(self: Fixed24_8, other: Fixed24_8) Fixed24_8 {
        return .{ .raw = self.raw - other.raw };
    }

    /// Multiply two fixed-point numbers.
    pub fn mul(self: Fixed24_8, other: Fixed24_8) Fixed24_8 {
        const result_64 = @as(i64, self.raw) * @as(i64, other.raw);
        return .{ .raw = @as(i32, @intCast(result_64 >> fraction_bits)) };
    }

    /// Divide two fixed-point numbers.
    pub fn div(self: Fixed24_8, other: Fixed24_8) Fixed24_8 {
        const dividend_64 = @as(i64, self.raw) << fraction_bits;
        return .{ .raw = @as(i32, @intCast(@divTrunc(dividend_64, other.raw))) };
    }
};

test "MAT001: Fixed24_8 fromInt and toInt (positive and negative)" {
    const a = Fixed24_8.fromInt(5);
    try std.testing.expectEqual(@as(i32, 5 << 8), a.raw);
    try std.testing.expectEqual(@as(i32, 5), a.toInt());

    const neg_a = Fixed24_8.fromInt(-5);
    try std.testing.expectEqual(@as(i32, -5 << 8), neg_a.raw);
    try std.testing.expectEqual(@as(i32, -5), neg_a.toInt());
}

test "MAT002: Fixed24_8 fromFloat" {
    const a = Fixed24_8.fromFloat(3.5);
    try std.testing.expectEqual(@as(i32, (3 << 8) + 128), a.raw);
    try std.testing.expectEqual(@as(i32, 3), a.toInt());

    const neg_f = Fixed24_8.fromFloat(-2.5);
    try std.testing.expectEqual(@as(i32, (-2 << 8) - 128), neg_f.raw);
    try std.testing.expectEqual(@as(i32, -3), neg_f.toInt());

    const b = Fixed24_8.fromFloat(0.125); // 1/8 -> 32/256
    try std.testing.expectEqual(@as(i32, 32), b.raw);
}

test "MAT003: Fixed24_8 fromParts" {
    const a = Fixed24_8.fromParts(3, 128);
    try std.testing.expectEqual(@as(i32, (3 << 8) + 128), a.raw);
    try std.testing.expectEqual(@as(i32, 3), a.toInt());
}

test "MAT004: Fixed24_8 fromFraction" {
    const a = Fixed24_8.fromFraction(3, 1, 2); // 3 + 1/2 -> 3.5
    try std.testing.expectEqual(@as(i32, (3 << 8) + 128), a.raw);

    const b = Fixed24_8.fromFraction(0, 1, 4); // 0 + 1/4 -> 64/256
    try std.testing.expectEqual(@as(i32, 64), b.raw);
}

test "MAT005: Fixed24_8 add and sub" {
    const a = Fixed24_8.fromInt(5);
    const b = Fixed24_8.fromInt(3);
    const c = a.add(b);
    try std.testing.expectEqual(@as(i32, 8), c.toInt());

    const d = a.sub(b);
    try std.testing.expectEqual(@as(i32, 2), d.toInt());

    // Test with fractional parts
    const x = Fixed24_8.fromFloat(2.5);
    const y = Fixed24_8.fromFloat(1.5);
    const z = x.add(y);
    try std.testing.expectEqual(@as(i32, 4 << 8), z.raw); // 4.0
}

test "MAT006: Fixed24_8 mul" {
    const a = Fixed24_8.fromInt(5);
    const b = Fixed24_8.fromInt(3);
    const c = a.mul(b);
    try std.testing.expectEqual(@as(i32, 15), c.toInt());

    // 1.5 * 2 = 3
    const x = Fixed24_8.fromFloat(1.5);
    const y = Fixed24_8.fromInt(2);
    const z = x.mul(y);
    try std.testing.expectEqual(@as(i32, 3 << 8), z.raw);

    // Negative multiplication
    const neg_res = x.mul(Fixed24_8.fromInt(-2));
    try std.testing.expectEqual(@as(i32, -3 << 8), neg_res.raw);
}

test "MAT007: Fixed24_8 div" {
    const a = Fixed24_8.fromInt(15);
    const b = Fixed24_8.fromInt(3);
    const c = a.div(b);
    try std.testing.expectEqual(@as(i32, 5), c.toInt());

    // 5 / 2 = 2.5
    const x = Fixed24_8.fromInt(5);
    const y = Fixed24_8.fromInt(2);
    const z = x.div(y);
    try std.testing.expectEqual(Fixed24_8.fromFloat(2.5).raw, z.raw);
}

test "MAT008: Fixed24_8 neg" {
    const a = Fixed24_8.fromFloat(2.5);
    const b = a.neg();
    try std.testing.expectEqual(Fixed24_8.fromFloat(-2.5).raw, b.raw);
    try std.testing.expectEqual(a.raw, b.neg().raw);
}

test "MAT009: Fixed24_8 quick reference table conformity" {
    // 3.5 -> (3 << 8) + 128
    const val_3_5 = Fixed24_8.fromFloat(3.5);
    try std.testing.expectEqual(@as(i32, (3 << 8) + 128), val_3_5.raw);

    // 0.5 -> 128 (0x80)
    try std.testing.expectEqual(@as(i32, 128), Fixed24_8.fromFloat(0.5).raw);
    try std.testing.expectEqual(@as(i32, 128), Fixed24_8.fromFraction(0, 1, 2).raw);
    try std.testing.expectEqual(@as(i32, 128), Fixed24_8.fromParts(0, 128).raw);

    // 0.25 -> 64 (0x40)
    try std.testing.expectEqual(@as(i32, 64), Fixed24_8.fromFloat(0.25).raw);
    try std.testing.expectEqual(@as(i32, 64), Fixed24_8.fromFraction(0, 1, 4).raw);

    // 0.75 -> 192 (0xC0)
    try std.testing.expectEqual(@as(i32, 192), Fixed24_8.fromFloat(0.75).raw);
    try std.testing.expectEqual(@as(i32, 192), Fixed24_8.fromFraction(0, 3, 4).raw);

    // 0.125 -> 32 (0x20)
    try std.testing.expectEqual(@as(i32, 32), Fixed24_8.fromFloat(0.125).raw);
    try std.testing.expectEqual(@as(i32, 32), Fixed24_8.fromFraction(0, 1, 8).raw);

    // 0.375 -> 96 (0x60)
    try std.testing.expectEqual(@as(i32, 96), Fixed24_8.fromFloat(0.375).raw);
    try std.testing.expectEqual(@as(i32, 96), Fixed24_8.fromFraction(0, 3, 8).raw);

    // 0.625 -> 160 (0xA0)
    try std.testing.expectEqual(@as(i32, 160), Fixed24_8.fromFloat(0.625).raw);
    try std.testing.expectEqual(@as(i32, 160), Fixed24_8.fromFraction(0, 5, 8).raw);

    // 0.875 -> 224 (0xE0)
    try std.testing.expectEqual(@as(i32, 224), Fixed24_8.fromFloat(0.875).raw);
    try std.testing.expectEqual(@as(i32, 224), Fixed24_8.fromFraction(0, 7, 8).raw);

    // Verify integer + fraction combinations
    // 12.75 -> (12 << 8) + 192
    try std.testing.expectEqual(@as(i32, (12 << 8) + 192), Fixed24_8.fromFloat(12.75).raw);
    try std.testing.expectEqual(@as(i32, (12 << 8) + 192), Fixed24_8.fromFraction(12, 3, 4).raw);
}
