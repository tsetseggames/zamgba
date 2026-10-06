const std = @import("std");
const physics = @import("physics/physics.zig");
const Fixed24_8 = physics.Fixed24_8;
const AABB = physics.AABB;

const gfx2d = @import("gfx2d/gfx2d.zig");
const Point2 = gfx2d.Point2;

const tilemap = @import("tilemap.zig");
const TileMapLayer = tilemap.TileMapLayer;

/// World boundary constraints for the camera.
pub const CameraLimits = struct {
    min_x: ?Fixed24_8 = null,
    min_y: ?Fixed24_8 = null,
    max_x: ?Fixed24_8 = null,
    max_y: ?Fixed24_8 = null,

    /// Clamps given (x, y) coordinates within the defined bounds using std.math.clamp.
    fn clamp(self: CameraLimits, x: Fixed24_8, y: Fixed24_8) struct { x: Fixed24_8, y: Fixed24_8 } {
        var rx = x.raw;
        var ry = y.raw;
        if (self.min_x) |min_x| rx = std.math.clamp(rx, min_x.raw, std.math.maxInt(i32));
        if (self.max_x) |max_x| rx = std.math.clamp(rx, std.math.minInt(i32), max_x.raw);
        if (self.min_y) |min_y| ry = std.math.clamp(ry, min_y.raw, std.math.maxInt(i32));
        if (self.max_y) |max_y| ry = std.math.clamp(ry, std.math.minInt(i32), max_y.raw);
        return .{
            .x = .{ .raw = rx },
            .y = .{ .raw = ry },
        };
    }
};

/// Margin window around the viewport center for drag-based target tracking (inspired by Godot Drag Margin).
pub const DragMargin = struct {
    width: u16,
    height: u16,
};

/// 2D Camera for viewport management, coordinate transformation, target tracking, and background scroll synchronization.
pub const Camera2D = struct {
    /// Top-left world coordinate of the camera viewport.
    x: Fixed24_8 = Fixed24_8.zero,
    y: Fixed24_8 = Fixed24_8.zero,

    /// Target position for smooth interpolation (lerping).
    target_x: Fixed24_8 = Fixed24_8.zero,
    target_y: Fixed24_8 = Fixed24_8.zero,

    /// Viewport dimensions in pixels (default: 240x160 for GBA).
    viewport_width: u16 = 240,
    viewport_height: u16 = 160,

    /// Optional world boundary limits.
    limits: CameraLimits = .{},

    /// Optional target tracking drag margin.
    drag_margin: ?DragMargin = null,

    /// Smoothing factor for position interpolation. 0 = instant snap, >0 = lerp interpolation.
    smooth_speed: Fixed24_8 = Fixed24_8.zero,

    /// Screen shake intensity and decay parameters.
    shake_intensity: Fixed24_8 = Fixed24_8.zero,
    shake_decay: Fixed24_8 = Fixed24_8.fromFloat(0.9),
    shake_offset_x: Fixed24_8 = Fixed24_8.zero,
    shake_offset_y: Fixed24_8 = Fixed24_8.zero,
    shake_step: u8 = 0,

    /// Initialize a Camera2D at the specified top-left world coordinates.
    pub fn init(x: Fixed24_8, y: Fixed24_8) Camera2D {
        // TDD Red Stub: Return empty/zeroed struct
        _ = x;
        _ = y;
        return .{};
    }

    /// Transforms world coordinates to screen pixel coordinates.
    pub fn worldToScreen(self: *const Camera2D, wx: Fixed24_8, wy: Fixed24_8) Point2 {
        // TDD Red Stub
        _ = self;
        _ = wx;
        _ = wy;
        return Point2.init(0, 0);
    }

    /// Transforms screen pixel coordinates to world coordinates.
    pub fn screenToWorld(self: *const Camera2D, sx: i32, sy: i32) Point2 {
        // TDD Red Stub
        _ = self;
        _ = sx;
        _ = sy;
        return Point2.init(0, 0);
    }

    /// Returns the active visible AABB of the camera in world coordinates.
    pub fn getVisibleAABB(self: *const Camera2D) AABB {
        // TDD Red Stub
        _ = self;
        return AABB.fromInt(0, 0, 0, 0);
    }

    /// Checks whether an entity's AABB intersects with the visible camera viewport.
    pub fn isAABBVisible(self: *const Camera2D, aabb: AABB) bool {
        // TDD Red Stub
        _ = self;
        _ = aabb;
        return false;
    }

    /// Centers the camera viewport on a world-space point instantly.
    pub fn centerOn(self: *Camera2D, target_x: Fixed24_8, target_y: Fixed24_8) void {
        // TDD Red Stub
        _ = self;
        _ = target_x;
        _ = target_y;
    }

    /// Sets the target look-at position (used with smooth_speed lerping).
    pub fn lookAt(self: *Camera2D, target_x: Fixed24_8, target_y: Fixed24_8) void {
        // TDD Red Stub
        _ = self;
        _ = target_x;
        _ = target_y;
    }

    /// Tracks a target AABB, respecting drag margin boundaries and limits.
    pub fn follow(self: *Camera2D, target: AABB) void {
        // TDD Red Stub
        _ = self;
        _ = target;
    }

    /// Triggers a screen shake effect with specified intensity and optional decay rate.
    pub fn shake(self: *Camera2D, intensity: Fixed24_8, decay: ?Fixed24_8) void {
        // TDD Red Stub
        _ = self;
        _ = intensity;
        _ = decay;
    }

    /// Updates camera position interpolation, boundary clamping, and screen shake decay.
    pub fn update(self: *Camera2D) void {
        // TDD Red Stub
        _ = self;
    }

    /// Synchronizes the camera viewport position to a hardware tilemap layer's scroll registers.
    pub fn applyToTileMap(self: *const Camera2D, layer: *TileMapLayer) void {
        // TDD Red Stub
        _ = self;
        _ = layer;
    }

    /// Synchronizes the camera viewport position to a tilemap layer with parallax scaling factors.
    pub fn applyToTileMapWithParallax(
        self: *const Camera2D,
        layer: *TileMapLayer,
        factor_x: Fixed24_8,
        factor_y: Fixed24_8,
    ) void {
        // TDD Red Stub
        _ = self;
        _ = layer;
        _ = factor_x;
        _ = factor_y;
    }
};

// ====================================================================
// Unit Tests
// ====================================================================

test "CAM000: CameraLimits bounds clamping logic" {
    const limits_full = CameraLimits{
        .min_x = Fixed24_8.fromInt(10),
        .min_y = Fixed24_8.fromInt(20),
        .max_x = Fixed24_8.fromInt(100),
        .max_y = Fixed24_8.fromInt(200),
    };

    // Within bounds
    const res1 = limits_full.clamp(Fixed24_8.fromInt(50), Fixed24_8.fromInt(60));
    try std.testing.expectEqual(Fixed24_8.fromInt(50).raw, res1.x.raw);
    try std.testing.expectEqual(Fixed24_8.fromInt(60).raw, res1.y.raw);

    // Below minimum
    const res2 = limits_full.clamp(Fixed24_8.fromInt(-5), Fixed24_8.fromInt(15));
    try std.testing.expectEqual(Fixed24_8.fromInt(10).raw, res2.x.raw);
    try std.testing.expectEqual(Fixed24_8.fromInt(20).raw, res2.y.raw);

    // Exceeding maximum
    const res3 = limits_full.clamp(Fixed24_8.fromInt(150), Fixed24_8.fromInt(250));
    try std.testing.expectEqual(Fixed24_8.fromInt(100).raw, res3.x.raw);
    try std.testing.expectEqual(Fixed24_8.fromInt(200).raw, res3.y.raw);

    // Partial bounds (only min_x and max_y)
    const limits_partial = CameraLimits{
        .min_x = Fixed24_8.fromInt(0),
        .max_y = Fixed24_8.fromInt(500),
    };
    const res4 = limits_partial.clamp(Fixed24_8.fromInt(-50), Fixed24_8.fromInt(600));
    try std.testing.expectEqual(Fixed24_8.fromInt(0).raw, res4.x.raw);
    try std.testing.expectEqual(Fixed24_8.fromInt(500).raw, res4.y.raw);
}

test "CAM001: Camera2D default initialization and dimensions" {
    const cam = Camera2D.init(Fixed24_8.fromInt(100), Fixed24_8.fromInt(200));
    try std.testing.expectEqual(Fixed24_8.fromInt(100).raw, cam.x.raw);
    try std.testing.expectEqual(Fixed24_8.fromInt(200).raw, cam.y.raw);
    try std.testing.expectEqual(Fixed24_8.fromInt(100).raw, cam.target_x.raw);
    try std.testing.expectEqual(Fixed24_8.fromInt(200).raw, cam.target_y.raw);
    try std.testing.expectEqual(@as(u16, 240), cam.viewport_width);
    try std.testing.expectEqual(@as(u16, 160), cam.viewport_height);
    try std.testing.expect(cam.limits.min_x == null);
    try std.testing.expect(cam.drag_margin == null);
}

test "CAM002: Camera2D world-to-screen and screen-to-world transformations" {
    const cam = Camera2D.init(Fixed24_8.fromInt(50), Fixed24_8.fromInt(30));

    const screen_pos = cam.worldToScreen(Fixed24_8.fromInt(70), Fixed24_8.fromInt(45));
    try std.testing.expectEqual(@as(i32, 20), screen_pos.x);
    try std.testing.expectEqual(@as(i32, 15), screen_pos.y);

    const world_pos = cam.screenToWorld(20, 15);
    try std.testing.expectEqual(@as(i32, 70), world_pos.x);
    try std.testing.expectEqual(@as(i32, 45), world_pos.y);
}

test "CAM003: Camera2D visible viewport AABB and frustum culling" {
    const cam = Camera2D.init(Fixed24_8.fromInt(100), Fixed24_8.fromInt(100));

    const vis_box = cam.getVisibleAABB();
    try std.testing.expectEqual(Fixed24_8.fromInt(100).raw, vis_box.x.raw);
    try std.testing.expectEqual(Fixed24_8.fromInt(100).raw, vis_box.y.raw);
    try std.testing.expectEqual(@as(u16, 240), vis_box.width);
    try std.testing.expectEqual(@as(u16, 160), vis_box.height);

    // Sprite inside viewport: (120, 120, 16, 16)
    try std.testing.expect(cam.isAABBVisible(AABB.fromInt(120, 120, 16, 16)));

    // Sprite overlapping left edge: (90, 120, 16, 16) -> right is 106 > 100
    try std.testing.expect(cam.isAABBVisible(AABB.fromInt(90, 120, 16, 16)));

    // Sprite overlapping bottom edge: (120, 250, 16, 16) -> y is 250 < 260
    try std.testing.expect(cam.isAABBVisible(AABB.fromInt(120, 250, 16, 16)));

    // Sprite completely offscreen to the left: (0, 0, 16, 16)
    try std.testing.expect(!cam.isAABBVisible(AABB.fromInt(0, 0, 16, 16)));

    // Sprite completely offscreen to the right: (400, 100, 16, 16)
    try std.testing.expect(!cam.isAABBVisible(AABB.fromInt(400, 100, 16, 16)));
}

test "CAM004: Camera2D world boundary limits clamping" {
    var cam = Camera2D.init(Fixed24_8.zero, Fixed24_8.zero);
    cam.limits = .{
        .min_x = Fixed24_8.fromInt(0),
        .min_y = Fixed24_8.fromInt(0),
        .max_x = Fixed24_8.fromInt(512 - 240), // 272
        .max_y = Fixed24_8.fromInt(512 - 160), // 352
    };

    // Try centering beyond top-left bounds
    cam.centerOn(Fixed24_8.fromInt(-100), Fixed24_8.fromInt(-100));
    try std.testing.expectEqual(Fixed24_8.fromInt(0).raw, cam.x.raw);
    try std.testing.expectEqual(Fixed24_8.fromInt(0).raw, cam.y.raw);

    // Try centering beyond bottom-right bounds
    cam.centerOn(Fixed24_8.fromInt(1000), Fixed24_8.fromInt(1000));
    try std.testing.expectEqual(Fixed24_8.fromInt(272).raw, cam.x.raw);
    try std.testing.expectEqual(Fixed24_8.fromInt(352).raw, cam.y.raw);
}

test "CAM005: Camera2D target centering and drag margin tracking" {
    var cam = Camera2D.init(Fixed24_8.zero, Fixed24_8.zero);

    // Centering on (300, 200) puts top-left at (300 - 120, 200 - 80) = (180, 120)
    cam.centerOn(Fixed24_8.fromInt(300), Fixed24_8.fromInt(200));
    try std.testing.expectEqual(Fixed24_8.fromInt(180).raw, cam.x.raw);
    try std.testing.expectEqual(Fixed24_8.fromInt(120).raw, cam.y.raw);

    // Configure 40x40 drag margin
    cam.drag_margin = .{ .width = 40, .height = 40 };

    // Target inside drag margin window: moving 5 pixels should NOT scroll camera
    const small_move_target = AABB.fromInt(305, 205, 16, 16);
    cam.follow(small_move_target);
    try std.testing.expectEqual(Fixed24_8.fromInt(180).raw, cam.x.raw);
    try std.testing.expectEqual(Fixed24_8.fromInt(120).raw, cam.y.raw);

    // Target pushed past right drag margin border (340 > 180 + 120 + 20 = 320)
    const large_move_target = AABB.fromInt(340, 200, 16, 16);
    cam.follow(large_move_target);
    try std.testing.expect(cam.x.raw > Fixed24_8.fromInt(180).raw);
}

test "CAM006: Camera2D position smoothing and screen shake decay" {
    var cam = Camera2D.init(Fixed24_8.zero, Fixed24_8.zero);
    cam.smooth_speed = Fixed24_8.fromFloat(0.5);
    cam.lookAt(Fixed24_8.fromInt(100), Fixed24_8.fromInt(100));

    // After 1 update with 0.5 lerp factor, x should move ~50
    cam.update();
    try std.testing.expectEqual(Fixed24_8.fromInt(50).raw, cam.x.raw);
    try std.testing.expectEqual(Fixed24_8.fromInt(50).raw, cam.y.raw);

    // Trigger shake
    cam.shake(Fixed24_8.fromInt(8), Fixed24_8.fromFloat(0.5));
    cam.update();
    try std.testing.expect(cam.shake_offset_x.raw != 0 or cam.shake_offset_y.raw != 0);

    // Decay shake to zero
    for (0..10) |_| {
        cam.update();
    }
    try std.testing.expectEqual(Fixed24_8.zero.raw, cam.shake_intensity.raw);
    try std.testing.expectEqual(Fixed24_8.zero.raw, cam.shake_offset_x.raw);
    try std.testing.expectEqual(Fixed24_8.zero.raw, cam.shake_offset_y.raw);
}

test "CAM007: Camera2D TileMapLayer scroll synchronization and parallax" {
    var dummy_tiles = [_]tilemap.ScreenEntry{tilemap.ScreenEntry.fromRaw(0)} ** 1024;
    const dummy_tileset = tilemap.TileSet{
        .tiles = tilemap.TileData{ .bpp4 = &[_]tilemap.Tile4bpp{} },
        .palette = &[_]tilemap.Bgr555{},
        .collision_masks = &[_]tilemap.CollisionMask{},
    };
    const map_data = tilemap.MapLayerData{
        .width = 32,
        .height = 32,
        .tileset = &dummy_tileset,
        .entries = &dummy_tiles,
    };
    var layer = tilemap.TileMapLayer{
        .bg_id = .bg0,
        .charblock = 0,
        .screenblock = 8,
        .size = .size_32x32,
        .data = &map_data,
    };

    var cam = Camera2D.init(Fixed24_8.fromInt(50), Fixed24_8.fromInt(70));

    cam.applyToTileMap(&layer);
    try std.testing.expectEqual(@as(u16, 50), layer.scroll_x);
    try std.testing.expectEqual(@as(u16, 70), layer.scroll_y);

    cam.applyToTileMapWithParallax(&layer, Fixed24_8.fromFloat(0.5), Fixed24_8.zero);
    try std.testing.expectEqual(@as(u16, 25), layer.scroll_x);
    try std.testing.expectEqual(@as(u16, 0), layer.scroll_y);
}

test "CAM008: Engine drawSprite camera viewport culling and coordinate offset" {
    const engine = @import("engine.zig");
    engine.initHardware();

    var cam = Camera2D.init(Fixed24_8.fromInt(100), Fixed24_8.fromInt(100));
    engine.setCamera(&cam);
    defer engine.setCamera(null);

    // Sprite 1 in-bounds: world pos (120, 120), screen pos should be (20, 20)
    const spr_on = try engine.StaticSprite.init(Fixed24_8.fromInt(120), Fixed24_8.fromInt(120), 8, 8, .{});
    engine.drawSprite(&spr_on);

    try std.testing.expectEqual(@as(usize, 1), engine.sprite_count);
    try std.testing.expectEqual(@as(u16, 20), engine.shadow_oam[0].attr0 & 0x00FF);
    try std.testing.expectEqual(@as(u16, 20), engine.shadow_oam[0].attr1 & 0x01FF);

    // Sprite 2 off-bounds: world pos (500, 500)
    const spr_off = try engine.StaticSprite.init(Fixed24_8.fromInt(500), Fixed24_8.fromInt(500), 8, 8, .{});
    engine.drawSprite(&spr_off);

    // Sprite 2 must be culled: sprite_count remains 1
    try std.testing.expectEqual(@as(usize, 1), engine.sprite_count);
}
