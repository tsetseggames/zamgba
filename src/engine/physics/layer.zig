const std = @import("std");

/// 16-bit collision mask supporting up to 16 distinct collision layers (0 to 15).
pub const CollisionMask = u16;

/// Helper utilities and constants for 16-layer collision filtering.
pub const Collision = struct {
    pub const ALL: CollisionMask = 0xFFFF;
    pub const NONE: CollisionMask = 0x0000;

    /// Returns the bitmask for a given layer index from 0 to 15.
    pub inline fn layer(index: u4) CollisionMask {
        return @as(CollisionMask, 1) << index;
    }

    /// Check if two entities can interact based on their layer and mask.
    /// Returns true if entity A's layer matches entity B's mask, or entity B's layer matches entity A's mask.
    pub inline fn canInteract(
        layer_a: CollisionMask,
        mask_a: CollisionMask,
        layer_b: CollisionMask,
        mask_b: CollisionMask,
    ) bool {
        return ((layer_a & mask_b) != 0) or ((layer_b & mask_a) != 0);
    }
};

test "Collision layer generation and bit shifting" {
    const l0 = Collision.layer(0);
    const l1 = Collision.layer(1);
    const l2 = Collision.layer(2);
    const l15 = Collision.layer(15);

    try std.testing.expectEqual(@as(u16, 0x0001), l0);
    try std.testing.expectEqual(@as(u16, 0x0002), l1);
    try std.testing.expectEqual(@as(u16, 0x0004), l2);
    try std.testing.expectEqual(@as(u16, 0x8000), l15);
}

test "Collision canInteract matching logic" {
    const layer_player = Collision.layer(0);
    const layer_enemy = Collision.layer(1);
    const layer_item = Collision.layer(2);
    const layer_bullet = Collision.layer(3);

    // Player collides with Enemy and Item
    const player_mask = layer_enemy | layer_item;
    // Bullet only collides with Enemy
    const bullet_mask = layer_enemy;
    // Enemy collides with Player and Bullet
    const enemy_mask = layer_player | layer_bullet;
    // Item only interacts with Player
    const item_mask = layer_player;

    // Player vs Enemy -> Match
    try std.testing.expect(Collision.canInteract(layer_player, player_mask, layer_enemy, enemy_mask));
    // Player vs Item -> Match
    try std.testing.expect(Collision.canInteract(layer_player, player_mask, layer_item, item_mask));
    // Bullet vs Enemy -> Match
    try std.testing.expect(Collision.canInteract(layer_bullet, bullet_mask, layer_enemy, enemy_mask));
    // Bullet vs Item -> No match (Bullet ignores Item, Item ignores Bullet)
    try std.testing.expect(!Collision.canInteract(layer_bullet, bullet_mask, layer_item, item_mask));
    // Bullet vs Player -> No match
    try std.testing.expect(!Collision.canInteract(layer_bullet, bullet_mask, layer_player, player_mask));
}
