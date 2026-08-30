const hal = @import("zamgba-hal");

/// Engine-level 8-bit RGBA color representation.
pub const Color = struct {
    r: u8,
    g: u8,
    b: u8,
    a: u8 = 255,

    /// Creates a Color with 8-bit R, G, B components and full opacity (alpha = 255).
    pub fn rgb(r: u8, g: u8, b: u8) Color {
        return .{ .r = r, .g = g, .b = b, .a = 255 };
    }

    /// Creates a Color with 8-bit R, G, B, A components.
    pub fn rgba(r: u8, g: u8, b: u8, a: u8) Color {
        return .{ .r = r, .g = g, .b = b, .a = a };
    }

    /// Converts 8-bit RGBA color to GBA hardware 15-bit BGR555 u16 representation.
    pub fn toBgr555(self: Color) u16 {
        const r5: u16 = self.r >> 3;
        const g5: u16 = self.g >> 3;
        const b5: u16 = self.b >> 3;
        return r5 | (g5 << 5) | (b5 << 10);
    }

    /// Creates an engine Color from GBA hardware 15-bit BGR555 u16 format.
    pub fn fromBgr555(bgr555: u16) Color {
        const r5: u8 = @intCast(bgr555 & 0x1F);
        const g5: u8 = @intCast((bgr555 >> 5) & 0x1F);
        const b5: u8 = @intCast((bgr555 >> 10) & 0x1F);

        const r8: u8 = (r5 << 3) | (r5 >> 2);
        const g8: u8 = (g5 << 3) | (g5 >> 2);
        const b8: u8 = (b5 << 3) | (b5 >> 2);
        return .{ .r = r8, .g = g8, .b = b8, .a = 255 };
    }

    // Common color constants derived directly from hal.Color (BGR555) to stay synchronized
    pub const BLACK = fromBgr555(hal.Color.BLACK);
    pub const RED = fromBgr555(hal.Color.RED);
    pub const GREEN = fromBgr555(hal.Color.LIME);
    pub const LIME = GREEN;
    pub const BLUE = fromBgr555(hal.Color.BLUE);
    pub const YELLOW = fromBgr555(hal.Color.YELLOW);
    pub const MAGENTA = fromBgr555(hal.Color.MAG);
    pub const MAG = MAGENTA;
    pub const CYAN = fromBgr555(hal.Color.CYAN);
    pub const WHITE = fromBgr555(hal.Color.WHITE);
};

test "CLR001: Color toBgr555 matches hal.Color hardware values" {
    const std = @import("std");
    try std.testing.expectEqual(hal.Color.BLACK, Color.BLACK.toBgr555());
    try std.testing.expectEqual(hal.Color.RED, Color.RED.toBgr555());
    try std.testing.expectEqual(hal.Color.LIME, Color.GREEN.toBgr555());
    try std.testing.expectEqual(hal.Color.BLUE, Color.BLUE.toBgr555());
    try std.testing.expectEqual(hal.Color.YELLOW, Color.YELLOW.toBgr555());
    try std.testing.expectEqual(hal.Color.MAG, Color.MAGENTA.toBgr555());
    try std.testing.expectEqual(hal.Color.CYAN, Color.CYAN.toBgr555());
    try std.testing.expectEqual(hal.Color.WHITE, Color.WHITE.toBgr555());
}

test "CLR002: Color roundtrip fromBgr555 and toBgr555" {
    const std = @import("std");
    const original_bgr: u16 = 0x3E1F; // R=31, G=16, B=15
    const color = Color.fromBgr555(original_bgr);
    try std.testing.expectEqual(original_bgr, color.toBgr555());
}
