const std = @import("std");
const Fixed24_8 = @import("math.zig").Fixed24_8;
const AABB = @import("aabb.zig").AABB;
const CollisionMap = @import("map.zig").CollisionMap;
const Sprite = @import("../sprite.zig").Sprite;

/// Result of collision check during movement.
pub const CollisionResult = struct {
    collided_x: bool = false,
    collided_y: bool = false,

    pub fn hasCollided(self: CollisionResult) bool {
        return self.collided_x or self.collided_y;
    }
};

/// Physics-enabled entity wrapper that manages sub-pixel AABB movement,
/// velocity vectors, map collision resolution, and synchronization with visual Sprite.
pub const PhysicsSprite = struct {
    aabb: AABB,
    velocity_x: Fixed24_8 = Fixed24_8.fromInt(0),
    velocity_y: Fixed24_8 = Fixed24_8.fromInt(0),

    /// Create a PhysicsSprite with an explicit AABB.
    pub fn init(aabb: AABB) PhysicsSprite {
        return .{
            .aabb = aabb,
            .velocity_x = Fixed24_8.fromInt(0),
            .velocity_y = Fixed24_8.fromInt(0),
        };
    }

    /// Automatically construct a PhysicsSprite from an existing Sprite.
    /// Automatically assigns an AABB matching the Sprite's position and dimensions.
    pub fn fromSprite(spr: *const Sprite) PhysicsSprite {
        return .{
            .aabb = AABB.init(
                Fixed24_8.fromInt(@intCast(@max(0, spr.x))),
                Fixed24_8.fromInt(@intCast(@max(0, spr.y))),
                @intCast(spr.width),
                @intCast(spr.height),
            ),
            .velocity_x = Fixed24_8.fromInt(0),
            .velocity_y = Fixed24_8.fromInt(0),
        };
    }

    /// Synchronizes the physics position back to the visual Sprite for rendering.
    pub fn syncToSprite(self: *const PhysicsSprite, spr: *Sprite) void {
        spr.x = @intCast(self.aabb.x.toInt());
        spr.y = @intCast(self.aabb.y.toInt());
    }

    /// Check if this physics sprite collides with another physics sprite.
    pub fn isColliding(self: PhysicsSprite, other: PhysicsSprite) bool {
        return self.aabb.isColliding(other.aabb);
    }

    /// Alias for isColliding.
    pub fn collidesWith(self: PhysicsSprite, other: PhysicsSprite) bool {
        return self.aabb.collidesWith(other.aabb);
    }

    /// Move the sprite by its current velocity, checking and resolving collisions
    /// independently on X and Y axes against the CollisionMap.
    pub fn moveAndCollide(self: *PhysicsSprite, collision_map: CollisionMap) CollisionResult {
        var result = CollisionResult{};

        // 1. Move along X axis
        if (self.velocity_x.raw != 0) {
            const next_x = self.aabb.x.add(self.velocity_x);
            const test_box_x = AABB.init(next_x, self.aabb.y, self.aabb.width, self.aabb.height);

            if (collision_map.isColliding(test_box_x)) {
                result.collided_x = true;
                self.velocity_x = Fixed24_8.fromInt(0);
            } else {
                self.aabb.x = next_x;
            }
        }

        // 2. Move along Y axis
        if (self.velocity_y.raw != 0) {
            const next_y = self.aabb.y.add(self.velocity_y);
            const test_box_y = AABB.init(self.aabb.x, next_y, self.aabb.width, self.aabb.height);

            if (collision_map.isColliding(test_box_y)) {
                result.collided_y = true;
                self.velocity_y = Fixed24_8.fromInt(0);
            } else {
                self.aabb.y = next_y;
            }
        }

        return result;
    }
};

// Unit tests
test "PhysicsSprite fromSprite auto assigns AABB" {
    const spr = Sprite.init(16, 24, 32, 32);
    const phys = PhysicsSprite.fromSprite(&spr);

    try std.testing.expectEqual(@as(u32, 16), phys.aabb.x.toInt());
    try std.testing.expectEqual(@as(u32, 24), phys.aabb.y.toInt());
    try std.testing.expectEqual(@as(u16, 32), phys.aabb.width);
    try std.testing.expectEqual(@as(u16, 32), phys.aabb.height);
}

test "PhysicsSprite syncToSprite updates visual Sprite coordinates" {
    var spr = Sprite.init(0, 0, 16, 16);
    var phys = PhysicsSprite.fromSprite(&spr);

    phys.aabb.x = Fixed24_8.fromFloat(25.5);
    phys.aabb.y = Fixed24_8.fromFloat(40.2);

    phys.syncToSprite(&spr);
    try std.testing.expectEqual(@as(i32, 25), spr.x);
    try std.testing.expectEqual(@as(i32, 40), spr.y);
}

test "PhysicsSprite sprite vs sprite collision" {
    const phys1 = PhysicsSprite.init(AABB.fromInt(10, 10, 16, 16));
    const phys2 = PhysicsSprite.init(AABB.fromInt(20, 20, 16, 16));
    const phys3 = PhysicsSprite.init(AABB.fromInt(50, 50, 16, 16));

    try std.testing.expect(phys1.isColliding(phys2));
    try std.testing.expect(phys1.collidesWith(phys2));
    try std.testing.expect(!phys1.isColliding(phys3));
}

fn mockWallAtTile3_0(tx: u16, ty: u16) bool {
    // Tile (3, 0) is at pixel x: [24, 32)
    return tx == 3 and ty == 0;
}

test "PhysicsSprite moveAndCollide stops against map obstacles" {
    const map = CollisionMap.init(.size_256x256, mockWallAtTile3_0, .solid);

    // Sprite at x=8, y=0, size 8x8 (tile 1, 0)
    var phys = PhysicsSprite.init(AABB.fromInt(8, 0, 8, 8));
    phys.velocity_x = Fixed24_8.fromInt(8); // Move right by 8 pixels per step

    // Step 1: Moves from x=8 to x=16 (tile 2) -> Clear
    var res = phys.moveAndCollide(map);
    try std.testing.expect(!res.hasCollided());
    try std.testing.expectEqual(@as(u32, 16), phys.aabb.x.toInt());

    // Step 2: Next step would move from x=16 to x=24 (tile 3, which is solid) -> Collision!
    res = phys.moveAndCollide(map);
    try std.testing.expect(res.collided_x);
    try std.testing.expect(!res.collided_y);
    try std.testing.expect(res.hasCollided());
    // Position should NOT have advanced into the wall
    try std.testing.expectEqual(@as(u32, 16), phys.aabb.x.toInt());
    // Velocity on X is stopped (zeroed out)
    try std.testing.expectEqual(@as(u32, 0), phys.velocity_x.raw);
}
