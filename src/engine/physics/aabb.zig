const std = @import("std");
const Fixed24_8 = @import("math.zig").Fixed24_8;

/// Axis-Aligned Bounding Box (AABB) in 2D space.
/// Coordinates are stored as Fixed24_8 for sub-pixel movement.
/// Dimensions (width, height) are integer pixels.
pub const AABB = struct {
    x: Fixed24_8,
    y: Fixed24_8,
    width: u16,
    height: u16,

    /// Create an AABB with Fixed24_8 coordinates.
    pub fn init(x: Fixed24_8, y: Fixed24_8, width: u16, height: u16) AABB {
        return .{
            .x = x,
            .y = y,
            .width = width,
            .height = height,
        };
    }

    /// Create an AABB with integer coordinates.
    pub fn fromInt(x: i32, y: i32, width: u16, height: u16) AABB {
        return .{
            .x = Fixed24_8.fromInt(x),
            .y = Fixed24_8.fromInt(y),
            .width = width,
            .height = height,
        };
    }

    /// Returns the right boundary (x + width) in Fixed24_8.
    pub fn right(self: AABB) Fixed24_8 {
        return .{ .raw = self.x.raw + (@as(i32, @intCast(self.width)) << Fixed24_8.fraction_bits) };
    }

    /// Returns the bottom boundary (y + height) in Fixed24_8.
    pub fn bottom(self: AABB) Fixed24_8 {
        return .{ .raw = self.y.raw + (@as(i32, @intCast(self.height)) << Fixed24_8.fraction_bits) };
    }

    /// Check if this AABB collides with another AABB.
    /// Uses standard half-open interval [left, right) and [top, bottom).
    /// Touching edges (e.g. self.right == other.x) are considered non-colliding.
    pub fn isColliding(self: AABB, other: AABB) bool {
        const self_r = self.right().raw;
        const self_b = self.bottom().raw;
        const other_r = other.right().raw;
        const other_b = other.bottom().raw;

        return self.x.raw < other_r and
            self_r > other.x.raw and
            self.y.raw < other_b and
            self_b > other.y.raw;
    }

    /// Alias for isColliding.
    pub fn collidesWith(self: AABB, other: AABB) bool {
        return self.isColliding(other);
    }

    /// Check if a 2D point (px, py) is contained within this AABB.
    pub fn containsPoint(self: AABB, px: Fixed24_8, py: Fixed24_8) bool {
        return px.raw >= self.x.raw and
            px.raw < self.right().raw and
            py.raw >= self.y.raw and
            py.raw < self.bottom().raw;
    }
};

test "ABB001: AABB isColliding basic overlap" {
    const box1 = AABB.fromInt(10, 10, 20, 20); // [10, 30) x [10, 30)
    const box2 = AABB.fromInt(20, 20, 20, 20); // [20, 40) x [20, 40)
    try std.testing.expect(box1.isColliding(box2));
    try std.testing.expect(box2.collidesWith(box1));
}

test "ABB002: AABB isColliding separated" {
    const box1 = AABB.fromInt(0, 0, 10, 10);
    const box2 = AABB.fromInt(20, 20, 10, 10);
    try std.testing.expect(!box1.isColliding(box2));
    try std.testing.expect(!box2.collidesWith(box1));
}

test "ABB003: AABB isColliding touching boundary does not collide" {
    const box1 = AABB.fromInt(0, 0, 10, 10); // [0, 10) x [0, 10)
    const box2 = AABB.fromInt(10, 0, 10, 10); // [10, 20) x [0, 10)
    try std.testing.expect(!box1.isColliding(box2));
    try std.testing.expect(!box2.collidesWith(box1));
}

test "ABB004: AABB sub-pixel collision" {
    // box1: [0, 10) x [0, 10)
    const box1 = AABB.fromInt(0, 0, 10, 10);
    // box2: [9.5, 19.5) x [0, 10) -> overlaps by 0.5 pixels
    const box2 = AABB.init(Fixed24_8.fromFloat(9.5), Fixed24_8.fromInt(0), 10, 10);
    try std.testing.expect(box1.isColliding(box2));

    // box3: [10.0039, 20.0039) -> slightly past 10 -> no collision
    const box3 = AABB.init(Fixed24_8.fromParts(10, 1), Fixed24_8.fromInt(0), 10, 10);
    try std.testing.expect(!box1.isColliding(box3));
}

test "ABB005: AABB containsPoint" {
    const box = AABB.fromInt(10, 10, 20, 20); // [10, 30) x [10, 30)

    try std.testing.expect(box.containsPoint(Fixed24_8.fromInt(10), Fixed24_8.fromInt(10)));
    try std.testing.expect(box.containsPoint(Fixed24_8.fromFloat(29.9), Fixed24_8.fromFloat(29.9)));
    try std.testing.expect(!box.containsPoint(Fixed24_8.fromInt(30), Fixed24_8.fromInt(20)));
    try std.testing.expect(!box.containsPoint(Fixed24_8.fromInt(5), Fixed24_8.fromInt(15)));
}
