pub const point = @import("point.zig");
pub const Point2 = point.Point2;

pub const line = @import("line.zig");
pub const drawLine = line.drawLine;

pub const color = @import("color.zig");
pub const Color = color.Color;
pub const Bgr555 = color.Bgr555;

pub const vram_allocator = @import("vram_allocator.zig");
pub const dma_queue = @import("dma_queue.zig");

test {
    _ = @import("std").testing.refAllDecls(@This());
    _ = color;
    _ = vram_allocator;
    _ = dma_queue;
}
