# UI, HUD & Screen-Space Rendering Architecture

This document details the architectural design, hardware constraints, trade-offs, and implementation strategy for building User Interfaces (UI) and Heads-Up Displays (HUD) in Zamgba.

---

## 1. The Core Challenge on GBA Hardware

Unlike modern game engines (e.g. Godot, Unity) that offer a unified 2D Canvas hierarchy with automatic layout anchoring and floating-point transform hierarchies, the Game Boy Advance provides strictly hardware-bound rendering pipelines:
* **4 Background Tile Layers (`BG0`–`BG3`)**: Hardware scanline engines configured via Charblocks and Screenblocks.
* **128 Hardware Sprite (OBJ) Slots**: Managed via Object Attribute Memory (OAM).
* **2-Bit Scanline Priority (`0`–`3`)**: Determines per-pixel depth ordering across all active layers and sprites.

In GBA game development, UI and HUD elements must be constructed using either **TileMap Background Layers** or **Screen-Space Sprites**, each with distinct mechanical and performance trade-offs.

---

## 2. Two HUD Construction Paradigms

```
┌────────────────────────────────────────────────────────────────────────┐
│                        GBA 240x160 Display                             │
├──────────────────────────────────┬─────────────────────────────────────┤
│ 1. TileMap HUD (e.g., BG0)       │ 2. Screen-Space Sprite HUD          │
│    - Fixed Top/Bottom Bar        │    - Floating Hearts / Icons        │
│    - Text / Dialogue Boxes       │    - Dynamic Cooldown Gauges        │
│    - Scroll registers stay (0,0) │    - Rendered via drawSpriteUi()    │
│    - Consumes 1 BG hardware layer│    - Consumes OAM sprite slots (0..127)│
└──────────────────────────────────┴─────────────────────────────────────┘
```

### Approach A: TileMap Background HUD (e.g. `BG0`)
* **Mechanism**: Dedicate a hardware background layer (typically `BG0` configured with `priority: 0`) as a static overlay plane. While world layers (`BG1`–`BG3`) receive camera scroll offsets via `cam.applyToTileMap(&layer)`, the HUD layer is left un-scrolled (`scroll_x = 0`, `scroll_y = 0`).
* **Pros**:
  - **Zero OAM Slot Overhead**: Leaves all 128 sprite slots available for game actors (player, enemies, bullets, VFX).
  - **Large Coverage Area**: Can render full-width status bars, window borders, dialogue boxes, or inventory screens with zero sprite-per-scanline limit issues.
  - **Low Per-Frame CPU Overhead**: Static UI tiles remain in VRAM; CPU does not need to submit draw calls each frame.
* **Cons**:
  - **Consumes a Full Hardware BG Layer**: The GBA only has 4 background layers (Mode 0). Dedicating `BG0` to HUD leaves only 3 layers for parallax scrolling, main terrain, and foreground effects.
  - **8x8 Grid Alignment**: Pixel-smooth motion or non-grid-aligned sub-pixel indicators require complex VRAM tile blitting.

### Approach B: Screen-Space Sprite HUD (`engine.drawSpriteUi`)
* **Mechanism**: Render standard `StaticSprite` and `AnimatedSprite` instances directly in screen coordinates $(0 \le X < 240, 0 \le Y < 160)$, bypassing `Camera2D` viewport translations and frustum culling.
* **Pros**:
  - **Pixel-Accurate Positioning**: Can be placed at arbitrary sub-pixel coordinates anywhere on the screen.
  - **Dynamic Animation & Palette Effects**: Reuses existing `AnimatedSprite`, streaming VRAM allocators, and palette cycling without custom tilemap code.
  - **Conserves BG Layers**: Frees all 4 background layers for rich multi-layer parallax scrolling and map geometry.
* **Cons**:
  - **Consumes OAM Slots**: Every HUD icon, digit, or heart takes away from the 128 hardware sprite limit.
  - **Scanline Drop-Out Limit**: GBA hardware can render a maximum of **128 OBJ pixels per scanline**. A row of many wide sprite UI icons can cause in-game sprites on that scanline to flicker or disappear.

---

## 3. Comparison Matrix

| Metric / Requirement | TileMap Background HUD (`BG0`) | Screen-Space Sprite HUD (`drawSpriteUi`) |
| :--- | :--- | :--- |
| **GBA Resource Consumed** | 1 BG Layer (`BG0`–`BG3`) | OAM Slots (1–128) + OBJ VRAM |
| **Positioning Flexibility** | Rigid 8x8 tile grid (unless using windowing/HDMA) | Free pixel-level $(X, Y)$ coordinates |
| **Animation Complexity** | High (requires updating ScreenEntries or Charblock) | Low (native `AnimatedSprite` / `DmaQueue`) |
| **Scanline Fill-Rate Risk** | None (hardware background pipeline) | High if multiple sprites share scanlines |
| **Typical Best Use Cases** | Dialogue boxes, static top/bottom status bars, text menus | Floating health hearts, minimap markers, damage numbers, ammo counters |

---

## 4. Coordinate Spaces & Engine Camera Transformations

Zamgba strictly separates coordinate transformations inside the engine pipeline:

```
World Space (Game Physics / Level) ───[ Camera2D Transform: (X - CamX, Y - CamY) ]───► Viewport Culling ──► Shadow OAM
Screen Space (HUD / UI Elements)   ───[ Identity: (X, Y) ]───────────────────────────► Direct Stage     ──► Shadow OAM
```

### 1. World-Space Sprites (`engine.drawSprite(spr)`)
* Coordinates are evaluated relative to the game world.
* Transformed to screen coordinates: $X_{\text{screen}} = X_{\text{world}} - \text{Cam}_X$, $Y_{\text{screen}} = Y_{\text{world}} - \text{Cam}_Y$.
* Subject to camera frustum culling (`camera.isAABBVisible`): sprites completely outside the visible 240x160 viewport are discarded immediately before consuming an OAM slot.

### 2. Screen-Space Sprites (`engine.drawSpriteUi(spr)`)
* Coordinates map directly to the 240x160 GBA LCD screen.
* Camera offset is completely ignored (no translation applied).
* Frustum culling is bypassed, ensuring UI components remain fixed on screen regardless of camera scrolling.

---

## 5. Hardware Layer Depth & 2-Bit Priority System

The GBA Video Controller resolves pixel visibility on every scanline using a **2-bit hardware priority value** (`0..3`), where `0` is foremost (highest priority) and `3` is rearmost:

$$\text{Priority 0 (Foremost)} > \text{Priority 1} > \text{Priority 2} > \text{Priority 3 (Background)}$$

```
Priority 0: [HUD Tilemap BG0] + [UI Sprites (priority: 0)]
Priority 1: [Foreground BG1 (Canopy/Trees)] + [Player/Enemy Sprites (priority: 1)]
Priority 2: [Main Playfield BG2 (Terrain/Walls)]
Priority 3: [Distant Parallax BG3 (Mountains/Clouds)] + [Backdrop Color]
```

### A. Priority Resolution Rules
1. **Between Different Priority Levels**: Lower priority number always renders in front of higher priority number (e.g. Priority 0 renders over Priority 1).
2. **Same Priority between BG and Sprite**: Sprites have higher precedence than Backgrounds of the same priority level.
3. **Same Priority among Sprites**: Resolved by OAM slot index (lower OAM index renders in front of higher OAM index).
4. **Same Priority among Backgrounds**: Resolved by BG index (`BG0` > `BG1` > `BG2` > `BG3`).

### B. Hardware Control Points
* **Sprite Priority**: Stored in OAM `Attr2` bits 10–11 (`0..3`).
* **Background Layer Priority**: Stored in `REG_BGxCNT` bits 0–1 (`0..3`).

---

## 6. Bitmap Fonts & Text Typography Pipeline *(Planned v0.4.0)*

*(To be implemented: 8x8 / proportional 1-bpp/4-bpp font sheet asset pipeline, string-to-tilemap blitter, dynamic text box rendering, and dialogue typewriter animation).*

---

## 7. UI Lifecycle & Menu State Management *(Planned v0.4.0)*

*(To be implemented: UI view navigation stack, modal pause menus, input focus arbitration, and HUD data binding).*
