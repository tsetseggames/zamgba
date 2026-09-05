const std = @import("std");

test {
    _ = @import("engine/gfx2d/vram_allocator.zig");
    _ = @import("engine/gfx2d/dma_queue.zig");
    _ = @import("engine/gfx2d/tile.zig");
    _ = @import("engine/gfx2d/gfx2d.zig");
    _ = @import("engine/animated_sprite.zig");
    _ = @import("engine/sprite.zig");
    _ = @import("engine/engine.zig");
    _ = @import("engine/physics/math.zig");
    _ = @import("engine/physics/aabb.zig");
    _ = @import("engine/physics/map.zig");
    _ = @import("engine/physics/layer.zig");
    _ = @import("engine/physics/overlap.zig");
}
