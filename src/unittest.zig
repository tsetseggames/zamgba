const std = @import("std");

comptime {
    _ = @import("zamgba-hal").display;
    _ = @import("zamgba-engine").gfx2d;
    _ = @import("zamgba-engine").input;
    _ = @import("zamgba-engine").Color;
    _ = @import("zamgba-engine").Sprite;
    _ = @import("zamgba-engine").physics;
}

test {
    std.testing.refAllDecls(@import("zamgba-engine").physics);
    _ = @import("zamgba-engine").physics.math;
    _ = @import("zamgba-engine").physics.aabb;
}
