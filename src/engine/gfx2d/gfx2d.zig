pub const point = @import("point.zig");
pub const Point2 = point.Point2;

pub const line = @import("line.zig");
pub const drawLine = line.drawLine;

pub const color = @import("color.zig");
pub const Color = color.Color;

pub const vram_allocator = @import("vram_allocator.zig");
pub const dma_queue = @import("dma_queue.zig");

pub const tile = @import("tile.zig");
pub const StaticTile = tile.StaticTile;
pub const ColorFillTile = tile.ColorFillTile;
pub const AnimatedTiles = tile.AnimatedTiles;
pub const SpriteSheet = tile.SpriteSheet;
pub const AnimationDirection = tile.AnimationDirection;
pub const AnimationTag = tile.AnimationTag;
pub const AnimationMode = tile.AnimationMode;
pub const TileError = tile.TileError;

test {
    _ = @import("std").testing.refAllDecls(@This());
    _ = color;
    _ = tile;
    _ = vram_allocator;
    _ = dma_queue;
}
