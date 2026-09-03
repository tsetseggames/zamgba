pub const point = @import("point.zig");
pub const Point2 = point.Point2;

pub const line = @import("line.zig");
pub const drawLine = line.drawLine;

pub const tile = @import("tile.zig");
pub const StaticTile = tile.StaticTile;
pub const ColorFillTile = tile.ColorFillTile;
pub const AnimatedTiles = tile.AnimatedTiles;
pub const SpriteSheet = tile.SpriteSheet;
pub const BppMode = tile.BppMode;
pub const AnimationDirection = tile.AnimationDirection;
pub const AnimationTag = tile.AnimationTag;
pub const AnimationMode = tile.AnimationMode;
pub const TileError = tile.TileError;

test {
    _ = @import("std").testing.refAllDecls(@This());
    _ = tile;
}
