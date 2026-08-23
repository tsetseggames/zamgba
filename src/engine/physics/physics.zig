pub const math = @import("math.zig");
pub const Fixed24_8 = math.Fixed24_8;

pub const aabb = @import("aabb.zig");
pub const AABB = aabb.AABB;

pub const map = @import("map.zig");
pub const MapSize = map.MapSize;
pub const OutOfBoundsBehavior = map.OutOfBoundsBehavior;
pub const CollisionMap = map.CollisionMap;
pub const ContextTileSolidFn = map.ContextTileSolidFn;
pub const NoContextTileSolidFn = map.NoContextTileSolidFn;
pub const TileSolidFn = map.TileSolidFn;
pub const SimpleTileSolidFn = map.SimpleTileSolidFn;

pub const layer = @import("layer.zig");
pub const CollisionMask = layer.CollisionMask;
pub const Collision = layer.Collision;

pub const overlap = @import("overlap.zig");
pub const checkOverlap = overlap.checkOverlap;
pub const checkOverlapConst = overlap.checkOverlapConst;
pub const checkAllOverlaps = overlap.checkAllOverlaps;

test {
    _ = math;
    _ = aabb;
    _ = map;
    _ = layer;
    _ = overlap;
}
