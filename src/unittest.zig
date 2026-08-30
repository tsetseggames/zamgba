const std = @import("std");

test {
    _ = @import("engine/vram_allocator.zig");
    _ = @import("engine/engine.zig");
    _ = @import("engine/physics/math.zig");
    _ = @import("engine/physics/aabb.zig");
    _ = @import("engine/physics/map.zig");
    _ = @import("engine/physics/layer.zig");
    _ = @import("engine/physics/overlap.zig");
}
