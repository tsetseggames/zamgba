# 2D Collision Framework Design for GBA

This document outlines the architecture, data structures, and development plan for a 2D Axis-Aligned Bounding Box (AABB) collision detection framework in `zamgba`, targeting GBA constraints.

## 1. Core Data Structures

### Fixed-Point Math (`Fixed24_8`)
To avoid slow floating-point operations on the GBA's ARM7TDMI processor, positional data relies on a 24.8 fixed-point representation using `u32`.
- **Bits 8-31**: Integer part (24 bits).
- **Bits 0-7**: Fractional part (8 bits).

```zig
pub const Fixed24_8 = struct {
    raw: u32,

    pub fn fromInt(i: u32) Fixed24_8 { ... }
    pub fn toInt(self: Fixed24_8) u32 { ... }
    pub fn add(self: Fixed24_8, other: Fixed24_8) Fixed24_8 { ... }
    pub fn sub(self: Fixed24_8, other: Fixed24_8) Fixed24_8 { ... }
    pub fn mul(self: Fixed24_8, other: Fixed24_8) Fixed24_8 { ... }
    // Division requires careful implementation to avoid performance hits
};
```

### AABB Structure
Defines the bounding box for sprites and entities using fixed-point coordinates.

```zig
pub const AABB = struct {
    x: Fixed24_8,
    y: Fixed24_8,
    width: u16,  // Integer pixels
    height: u16, // Integer pixels

    pub fn isColliding(self: AABB, other: AABB) bool { ... }
    pub fn collidesWith(self: AABB, other: AABB) bool { ... }
};
```

## 2. Map Collision (Text Background)

GBA Text Backgrounds use 8x8 pixel tiles. The framework supports the four standard GBA Text BG sizes:
- 256x256 (32x32 tiles)
- 512x256 (64x32 tiles)
- 256x512 (32x64 tiles)
- 512x512 (64x64 tiles)

### Streaming Map Interface
Since map data can be large, the framework streams collision data via a callback or interface, converting world coordinates to tile coordinates without requiring full grid allocation in RAM.

```zig
pub const MapSize = enum(u2) {
    size_256x256 = 0,
    size_512x256 = 1,
    size_256x512 = 2,
    size_512x512 = 3,
};

pub const OutOfBoundsBehavior = enum {
    solid,
    empty,
};

pub const CollisionMap = struct {
    size: MapSize,
    context: ?*const anyopaque = null,
    is_tile_solid_fn: ContextTileSolidFn,
    out_of_bounds: OutOfBoundsBehavior = .solid,

    pub fn initWithContext(
        size: MapSize,
        context: ?*const anyopaque,
        is_tile_solid_fn: ContextTileSolidFn,
        out_of_bounds: OutOfBoundsBehavior,
    ) CollisionMap { ... }

    pub fn init(
        size: MapSize,
        is_tile_solid_fn: NoContextTileSolidFn,
        out_of_bounds: OutOfBoundsBehavior,
    ) CollisionMap { ... }

    pub fn isTileSolid(self: CollisionMap, tx: u16, ty: u16) bool { ... }
    pub fn isColliding(self: CollisionMap, box: AABB) bool { ... }
    pub fn collidesWith(self: CollisionMap, box: AABB) bool { ... }
    pub fn getFirstCollidingTile(self: CollisionMap, box: AABB) ?TilePos { ... }
};
```

**Algorithm**:
1. Convert `box.x` and `box.y` from `Fixed24_8` to tile grid bounds via `>> (8 + 3)`.
2. Determine `[min_tx, max_tx]` and `[min_ty, max_ty]`.
3. Iterate over the tiles within this bounding grid.
4. Call `isTileSolid` for each tile. Return `true` immediately upon encountering a solid tile.

## 3. Sprite and Physics Integration

In Zamgba, visual rendering and physics are unified into a single `Sprite` structure to eliminate duplicate state, minimize EWRAM usage, and provide sub-pixel accuracy natively.

```zig
pub const Sprite = struct {
    aabb: AABB,
    velocity_x: i32 = 0, // 24.8 signed fixed-point velocity
    velocity_y: i32 = 0, // 24.8 signed fixed-point velocity

    // 16-bit Collision Layer & Mask (4 bytes total, perfectly aligned)
    layer: CollisionMask = Collision.NONE,
    mask: CollisionMask = Collision.ALL,

    tile_index: u16 = 0,
    palette_bank: u8 = 0,
    visible: bool = true,

    pub fn moveAndCollide(self: *Sprite, map: CollisionMap) CollisionResult { ... }
    pub inline fn canCollideWith(self: *const Sprite, other: *const Sprite) bool { ... }
    pub fn toOamAttr(self: *const Sprite) hal.oam.ObjAttr { ... }
};
```

### Sprite-to-Sprite Overlap Queries
Zamgba provides zero-heap slice query helpers for entity interactions:

```zig
// One-to-many query (e.g. player hitting any enemy)
pub fn checkOverlap(target: *const Sprite, others: []Sprite) ?*Sprite { ... }

// Many-to-many pairwise check with compile-time inlined callback
pub fn checkAllOverlaps(
    sprites: []Sprite,
    context: anytype,
    comptime on_overlap: fn (ctx: @TypeOf(context), a: *Sprite, b: *Sprite) void,
) void { ... }
```

---

## 4. 16-Bit Collision Layer and Mask System (`CollisionMask`)

To prevent unnecessary geometric overlap tests (e.g. bullets colliding with other bullets, or enemies triggering enemy patrol logic), Zamgba provides a 16-layer filtering mechanism using bitmasks.

### 4.1 Architecture and Hardware Considerations (GBA ARM7TDMI)
- **Zero Cycle Overhead**: On the 32-bit ARM7TDMI, bitwise AND/OR operations on `u16` take **1 clock cycle**, identical to `u8`.
- **Optimal Memory Alignment**: Storing two `u16` fields (`layer` and `mask`) occupies exactly **4 bytes**, perfectly aligning with adjacent 16-bit and 8-bit fields without padding bytes or memory holes.
- **Capacity**: 16 distinct layers (Indices `0` to `15`) cover the requirements of commercial-grade 2D action games.

```zig
pub const CollisionMask = u16;

pub const Collision = struct {
    pub const ALL: CollisionMask = 0xFFFF;
    pub const NONE: CollisionMask = 0x0000;

    pub inline fn layer(index: u4) CollisionMask {
        return @as(CollisionMask, 1) << index;
    }

    pub inline fn canInteract(
        layer_a: CollisionMask,
        mask_a: CollisionMask,
        layer_b: CollisionMask,
        mask_b: CollisionMask,
    ) bool {
        return ((layer_a & mask_b) != 0) or ((layer_b & mask_a) != 0);
    }
};
```

### 4.2 Comparison with Existing Frameworks

| Feature | **Godot** | **Raylib** | **Butano (GBA)** | **Zamgba** |
| :--- | :--- | :--- | :--- | :--- |
| **Language / Target** | C++ (PC/Mobile) | C (Cross-platform) | C++20 (GBA) | **Zig (GBA)** |
| **Layer Filtering** | 32-bit Layer & Mask | None (Manual checks) | None (Manual checks) | **16-bit Layer & Mask (`u16`)** |
| **Collision Query** | Signals & Dynamic BVH Tree | Pure functions (`CheckCollisionRecs`) | Manual loop (`rect.intersects`) | **Bitmask filter + `AABB.isColliding`** |
| **Memory Cost** | High (Heap / Node hierarchy) | Zero (Pass by value) | Low (Bare structs) | **Zero Heap (Flat 28-byte `Sprite`)** |
| **Map Physics** | Kinematic/CharacterBody2D | Custom/External | Custom/External | **Built-in `moveAndCollide(map)`** |

### 4.3 Practical Usage Example

Developers define application-specific layers without modifying framework code:

```zig
// 1. Define game-specific layers
const Layers = struct {
    pub const PLAYER:      CollisionMask = Collision.layer(0);
    pub const ENEMY:       CollisionMask = Collision.layer(1);
    pub const PLAYER_SHOT: CollisionMask = Collision.layer(2);
    pub const ENEMY_SHOT:  CollisionMask = Collision.layer(3);
    pub const ITEM:        CollisionMask = Collision.layer(4);
};

// 2. Configure Sprite instances
player.layer = Layers.PLAYER;
player.mask = Layers.ENEMY | Layers.ENEMY_SHOT | Layers.ITEM;

bullet.layer = Layers.PLAYER_SHOT;
bullet.mask = Layers.ENEMY; // Only hits enemies

// 3. Collision filtering query in tick()
if (bullet.canCollideWith(&enemy) and bullet.aabb.isColliding(enemy.aabb)) {
    // Trigger hit logic
}
```

---

## 5. Development Plan & Progress

- [x] **Phase 1: Math and Base Physics (`src/engine/physics/math.zig`, `src/engine/physics/aabb.zig`)**
  - Implemented `Fixed24_8` fixed-point math with `fromFloat` (comptime), `fromParts`, `fromFraction`, and arithmetic operations.
  - Implemented `AABB` struct with `isColliding` and `collidesWith` boundary overlap algorithms.
  - Unit tests verifying arithmetic, sub-pixel precision, and quick reference tables.

- [x] **Phase 2: Map Collision System (`src/engine/physics/map.zig`)**
  - Implemented `CollisionMap` supporting 4 standard GBA Text BG sizes.
  - Implemented streaming callbacks (`initWithContext`, `init`, `noContextAdapter`) and `OutOfBoundsBehavior`.
  - Implemented tile grid mapping and fast range queries (`isColliding`, `getFirstCollidingTile`).
  - Unit tests covering tile overlap, sub-pixel crossing, and streaming contexts.

- [x] **Phase 3: Unified Sprite & 16-Bit Layer System (`src/engine/sprite.zig`, `src/engine/physics/layer.zig`, `src/engine/physics/overlap.zig`)**
  - Unified rendering and physics into a single 28-byte `Sprite` embedding `aabb: AABB` and signed velocities.
  - Implemented 16-bit `CollisionMask` with 1-cycle bitwise filter (`canCollideWith`).
  - Implemented entity slice queries (`checkOverlap` and `checkAllOverlaps`).

- [x] **Phase 4: Demonstration ROM (`demo/engine/collision_demo.zig`)**
  - Fully built and verified GBA ROM (`collision_demo.gba`) using engine-tier APIs.
  - Interactive D-Pad controlled yellow player, bouncing patrol red enemies, and map border collision handling.
