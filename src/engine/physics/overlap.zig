const std = @import("std");
const Sprite = @import("../sprite.zig").Sprite;

/// Checks if `target` collides with any sprite in the `others` slice.
/// Automatically skips `target` if it resides in the same slice.
/// Applies 16-bit layer/mask filtering before performing AABB geometric tests.
/// Returns a pointer to the first colliding Sprite in `others`, or `null` if none match.
pub fn checkOverlap(target: *const Sprite, others: []Sprite) ?*Sprite {
    for (others) |*other| {
        if (target == other) continue;
        if (!target.canCollideWith(other)) continue;
        if (target.aabb.isColliding(other.aabb)) {
            return other;
        }
    }
    return null;
}

/// Read-only / const version of `checkOverlap`.
pub fn checkOverlapConst(target: *const Sprite, others: []const Sprite) ?*const Sprite {
    for (others) |*other| {
        if (target == other) continue;
        if (!target.canCollideWith(other)) continue;
        if (target.aabb.isColliding(other.aabb)) {
            return other;
        }
    }
    return null;
}

/// Evaluates all pairwise combinations within a `Sprite` slice without heap allocations.
/// Filters pairs via 16-bit layer/mask, performing AABB checks only when masks match.
/// For each colliding pair, `on_overlap(context, a, b)` is invoked.
pub fn checkAllOverlaps(
    sprites: []Sprite,
    context: anytype,
    comptime on_overlap: fn (ctx: @TypeOf(context), a: *Sprite, b: *Sprite) void,
) void {
    if (sprites.len < 2) return;
    var i: usize = 0;
    while (i < sprites.len - 1) : (i += 1) {
        var j: usize = i + 1;
        while (j < sprites.len) : (j += 1) {
            const a = &sprites[i];
            const b = &sprites[j];
            if (!a.canCollideWith(b)) continue;
            if (a.aabb.isColliding(b.aabb)) {
                on_overlap(context, a, b);
            }
        }
    }
}

// Unit tests
test "checkOverlap finds matching colliding sprite" {
    const Collision = @import("layer.zig").Collision;

    var player = Sprite.init(10, 10, 16, 16);
    player.layer = Collision.layer(0); // Player
    player.mask = Collision.layer(1);  // Only interacts with Enemy

    var enemies = [_]Sprite{
        Sprite.init(50, 50, 16, 16), // Enemy 0: Far away (no collision)
        Sprite.init(15, 15, 16, 16), // Enemy 1: Overlaps player (collision!)
        Sprite.init(12, 12, 16, 16), // Enemy 2: Also overlaps
    };
    for (&enemies) |*e| {
        e.layer = Collision.layer(1);
        e.mask = Collision.layer(0);
    }

    const hit = checkOverlap(&player, &enemies);
    try std.testing.expect(hit != null);
    // Should return the first matching hit (Enemy 1 at index 1)
    try std.testing.expectEqual(&enemies[1], hit.?);
}

test "checkOverlap skips self when target is in the same slice" {
    var pool = [_]Sprite{
        Sprite.init(10, 10, 16, 16),
        Sprite.init(50, 50, 16, 16),
    };
    // Testing pool[0] against the whole pool slice
    const hit = checkOverlap(&pool[0], &pool);
    // Should skip pool[0] == pool[0], pool[1] does not overlap -> null
    try std.testing.expect(hit == null);
}

test "checkOverlap layer mask filtering" {
    const Collision = @import("layer.zig").Collision;

    var player = Sprite.init(10, 10, 16, 16);
    player.layer = Collision.layer(0);
    player.mask = Collision.layer(1); // Only Enemy

    var items = [_]Sprite{
        Sprite.init(10, 10, 16, 16), // Overlaps physically, but is Item (Layer 2)
    };
    items[0].layer = Collision.layer(2);
    items[0].mask = Collision.layer(3);

    const hit = checkOverlap(&player, &items);
    try std.testing.expect(hit == null);
}

test "checkAllOverlaps pairwise collision callbacks" {
    const Collision = @import("layer.zig").Collision;

    const Counter = struct {
        count: u32 = 0,

        fn onHit(self: *@This(), a: *Sprite, b: *Sprite) void {
            _ = a;
            _ = b;
            self.count += 1;
        }
    };

    var sprites = [_]Sprite{
        Sprite.init(10, 10, 16, 16), // 0: Overlaps with 1
        Sprite.init(15, 15, 16, 16), // 1: Overlaps with 0
        Sprite.init(100, 100, 16, 16), // 2: Separated
    };
    for (&sprites) |*s| {
        s.layer = Collision.layer(0);
        s.mask = Collision.layer(0);
    }

    var counter = Counter{};
    checkAllOverlaps(&sprites, &counter, Counter.onHit);

    // Only pair (0, 1) collides
    try std.testing.expectEqual(@as(u32, 1), counter.count);
}
