# GBA Affine Sprite Transformation Design & Roadmap

> [!NOTE]
> **Status:** Planned / Not Yet Implemented. Targeted for Milestone **1.0.0** (with background Mode 7 scaling in **2.0.0**).

This document outlines the technical requirements, hardware dependencies, and architectural evolution path for supporting Affine Transformation (rotation and scaling) in Zamgba without breaking the existing AABB collision system.

---

## 1. Overview of GBA Hardware Affine Sprites

The GBA ARM7TDMI hardware natively supports hardware-accelerated 2D rotation, scaling, and shearing for sprites via affine transformation matrices.

### Core Hardware Constraints:
1. **128 Sprites vs 32 Matrix Slots**:
   While the GBA can render up to 128 hardware sprites (`ObjAttr`), it only contains **32 hardware affine transformation parameter groups** (`ObjAffineAttr`). Each group contains 4 entries ($P_A, P_B, P_C, P_D$) in 8.8 fixed-point format:
   $$\begin{bmatrix} x' \\ y' \end{bmatrix} = \begin{bmatrix} P_A & P_B \\ P_C & P_D \end{bmatrix} \begin{bmatrix} x - x_c \\ y - y_c \end{bmatrix}$$
2. **Center-Based Rotation (Center Pivot)**:
   GBA hardware affine rotation is strictly centered on the sprite's geometric center ($(x + w/2, y + h/2)$).
3. **Double-Size Bounding Area**:
   When a rectangular sprite rotates 45 degrees, its bounding box expands to $\sqrt{2} \approx 1.414$ times the original dimension. The GBA provides a `Double Size` flag (`attr0` Bit 9) to expand the canvas bounding box and prevent edge clipping.

---

## 2. Implementation Dependencies

To implement affine sprites, the engine requires four key components:

### 1. Mathematical Layer: Sine/Cosine Fixed-Point LUT (`math.zig`)
Rotating by angle $\theta$ requires $\sin(\theta)$ and $\cos(\theta)$. To eliminate runtime trigonometry calculations on the ARM7TDMI, Zamgba will introduce a compile-time generated lookup table (LUT) of 256 or 360 entries:
```zig
pub const SinCosLUT = struct {
    // 256-step angle LUT (1 byte angle resolution)
    pub const table_sin: [256]Fixed8_8 = ...;
    pub const table_cos: [256]Fixed8_8 = ...;
};
```

### 2. Engine Layer: 32-Slot OAM Affine Matrix Allocator (`engine.zig`)
Similar to the existing 128-entry `shadow_oam`, the engine will manage a 32-entry shadow affine matrix pool:
```zig
pub const Engine = struct {
    shadow_oam: [128]hal.oam.ObjAttr,
    shadow_affine: [32]hal.oam.ObjAffineAttr,
    affine_matrix_count: usize,
    ...
};
```
During `eng.drawSprite(&spr)`, if `spr.is_affine == true`, the engine will dynamically allocate a matrix slot, compute $P_A, P_B, P_C, P_D$ from `spr.rotation` and `spr.scale`, and bind the slot index into `attr1`.

### 3. Visual Offset Transformation
The visual rendering system converts the top-left physics coordinate to GBA's center-pivot affine coordinate during `toOamAttr()`:
- `x_hw = (center_x - canvas_width / 2)`
- `y_hw = (center_y - canvas_height / 2)`

---

## 3. Impact on Existing Physics and Collision Framework

### Decoupling Visual Rotation from Physical Bounding Boxes
In classic GBA titles (e.g. *Metroid Fusion*, *Pokémon*, *Castlevania*), sprites rotate visually while the underlying collision model remains a standard Axis-Aligned Bounding Box (AABB):

```
      Visual Presentation (Affine Rotation)          Physics Collision (AABB)
                  / \                                   +---------------+
                /     \                                 |               |
              /  Hero   \                               |   AABB Box    |
                \     /                                 |               |
                  \ /                                   +---------------+
```

1. **Zero Collision Performance Hit**:
   Decoupling visual rotation from collision detection avoids high-overhead Oriented Bounding Box (OBB) or Separating Axis Theorem (SAT) algorithms on the ARM7 processor.
2. **Backward Compatibility**:
   `AABB`, `CollisionMap`, and `checkOverlap` remain completely unchanged.

### Evolution of `Sprite` Struct (Non-Breaking)
When affine support is added in Milestone 1.0.0, the `Sprite` structure will simply gain optional affine parameters with sensible defaults:
```zig
pub const Sprite = struct {
    aabb: AABB,
    velocity_x: i32 = 0,
    velocity_y: i32 = 0,
    layer: CollisionMask = Collision.NONE,
    mask: CollisionMask = Collision.ALL,

    // Future 1.0.0 Extension Fields:
    rotation: u8 = 0,                       // 0..255 (0 to 360 degrees)
    scale_x: Fixed24_8 = Fixed24_8.fromInt(1),
    scale_y: Fixed24_8 = Fixed24_8.fromInt(1),
    is_affine: bool = false,
    double_size: bool = false,
    ...
};
```

---

## 4. Milestone Roadmap Alignment

| Milestone | Target Feature | Affine & Math Prerequisites |
| :--- | :--- | :--- |
| **0.7.0 (Current)** | 2D Physics Engine | • `Fixed24_8` fixed-point math, `AABB`, `CollisionMap`, 16-layer `CollisionMask`. |
| **1.0.0** | 2D Platformer Engine | • **Sprite Affine System**: Fixed-point $\sin/\cos$ LUT, 32-matrix shadow allocator, Sprite rotation/scaling. |
| **2.0.0** | Pseudo-3D Engine | • **Background Mode 7 Affine System**: Extends the affine matrix math to Background Layers for pseudo-3D perspective tracks (*F-Zero* / *Mario Kart* style). |
