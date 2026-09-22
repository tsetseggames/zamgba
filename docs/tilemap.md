# Background Tilemap Engine & Map Pipeline Architecture for GBA

This document outlines the architecture, hardware integration, data structures, asset pipeline, and development plan for the 2D Background Tilemap engine in `zamgba`.

---

## 1. Core Concepts & GBA Hardware Support

### 1.1 Dedicated Hardware Background Pipelines (Mode 0)
On the Game Boy Advance, backgrounds (BG) and tilemaps are rendered using dedicated hardware pipelines inside the Picture Processing Unit (PPU). 

In **Mode 0** (the standard 2D tile mode), the GBA provides **4 independent hardware Text background layers** (`BG0`, `BG1`, `BG2`, `BG3`) alongside the dedicated Sprite (OBJ) layer:
* **Zero-CPU Scrolling**: Each background layer provides dedicated hardware scroll registers (`REG_BGxHOFS` and `REG_BGxVOFS`). Moving a map requires writing only two 16-bit registers per frame—scrolling and raster clipping consume 0 CPU cycles.
* **Hardware Compositing & Priority**: Each background layer has an independent priority setting (0 to 3, configured in `REG_BGxCNT`). The PPU composites layers line-by-line and performs hardware alpha blending or clipping without software framebuffers.

### 1.2 Two-Tier Indirect Addressing: Charblocks and Screenblocks
Unlike Sprites (which require distinct dynamic OAM attributes for position, size, and transforms), a GBA Tilemap has zero per-tile runtime overhead. It uses a 2-tier indirect VRAM addressing scheme:

```
VRAM (0x06000000)
├── Character Blocks (Charblock / CBB 0~3, 16 KB each)
│   └── 8x8 pixel raw tile image data (4-bpp / 8-bpp)
└── Screen Blocks (Screenblock / SBB 0~31, 2 KB each)
    └── 32x32 array of 16-bit packed Screen Entries
```

#### Hardware Screen Entry (`u16`)
Every cell in a text screenblock is a single 16-bit packed integer:
* **Bits 0–9**: `tile_index` (0–1023, index into the assigned Charblock).
* **Bit 10**: `h_flip` (Horizontal tile mirroring).
* **Bit 11**: `v_flip` (Vertical tile mirroring).
* **Bits 12–15**: `palette_bank` (0–15, selecting the 16-color palette bank in 4-bpp mode).

### 1.3 Map Sizing: Fit-in-SBB vs. Streaming Large Maps
The GBA hardware text background engine natively supports 4 base layouts controlled by `REG_BGxCNT.screen_size`:
* **32×32 tiles (256×256 px)**: 1 SBB (2 KB) — Ideal for UI/HUD, fixed menus, minigames.
* **64×32 tiles (512×256 px)**: 2 contiguous SBBs (4 KB) — Horizontal scrolling rooms.
* **32×64 tiles (256×512 px)**: 2 contiguous SBBs (4 KB) — Vertical scrolling shafts.
* **64×64 tiles (512×512 px)**: 4 contiguous SBBs (8 KB) — Medium exploration arenas.

For larger levels (e.g. 2048×1024 platformers or infinite scrolling stages), VRAM cannot hold the whole map at once. A **streaming ring buffer** is used: VRAM holds only the 32×32 or 64×64 visible window, and as the camera moves past tile boundaries, newly revealed seams (rows/columns) are streamed into VRAM during VBlank via DMA.

### 1.4 Video Mode Analysis & Why Engine v0.3.0 Exclusively Targets Mode 0

| GBA Video Mode | Layer Configuration | Key Characteristics | Target Use Cases |
| :--- | :--- | :--- | :--- |
| **Mode 0 (Tile)** | **BG0, BG1, BG2, BG3 (All Text)** | 4 independent tiled layers; supports 4-bpp/8-bpp, hardware mirroring, and 0-CPU scrolling on all layers. | **Standard 2D games** (Platformers, Action RPGs, Shmups, Top-down). |
| **Mode 1 (Mixed)** | **BG0, BG1 (Text)<br>BG2 (Affine)** | 2 regular text layers + 1 affine (rotation/scaling) layer; drops BG3. | Mode 7 pseudo-3D ground planes, giant rotating gears, World maps (*F-Zero*, *Mario Kart*). |
| **Mode 2 (Affine)** | **BG2, BG3 (All Affine)** | 2 affine layers only; no text layers (no 4-bpp memory savings or hardware tile flipping). | Specialized arcade ports or dual-plane affine distortion. |
| **Mode 3 (Bitmap)** | **BG2 (Unique, 15-bit RGB555)** | Single-buffered true color 240×160 framebuffer (`[160][240]u16`); no tile/SBB indexing. | Static title CGs, software 3D/raycasting demos. |
| **Mode 4 (Bitmap)** | **BG2 (Unique, 8-bpp Indexed)** | Double-buffered 240×160 with page flipping; software rendering only. | Full-motion video cutscenes, 3D software rasterizers (*Doom GBA*). |
| **Mode 5 (Bitmap)** | **BG2 (Unique, 15-bit RGB555)** | Double-buffered true color scaled to 160×128. | High frame-rate 3D software rendering. |

#### Strategic Rationale for Engine v0.3.0
1. **Universal 2D Game Coverage**: Over 95% of commercial GBA 2D titles (*Castlevania: Aria of Sorrow*, *Mega Man Zero*, *Kirby & The Amazing Mirror*, *Pokémon Emerald*) run entirely within **Mode 0**.
2. **Maximum Layering Capacity**: Mode 0 provides the maximum number of simultaneous hardware layers (4 Text BGs + Sprites), which cleanly maps to a full production 2D layer stack:
   - `BG0`: UI / HUD / Dialogue text box (highest priority, static).
   - `BG1`: Foreground / Main gameplay map with collision.
   - `BG2`: Parallax midground (scrolling at fractional speed).
   - `BG3`: Far background / Sky backdrop.
   - `OBJ`: Player, enemies, items, and particle sprites.
3. **Architectural Separation**: Bitmap modes (Modes 3, 4, 5) and Affine modes (Modes 1, 2) are already available at the **HAL tier** (`zamgba.hal.display`, `zamgba.hal.context`). The high-level **Engine tier** (TileMap, Camera, AABB Physics) specifically targets the tile-based abstraction, making Mode 0 the only mode required for v0.3.0. Future affine support (e.g. Mode 1 rotation) will be introduced in milestone v0.8.0.

---

## 2. API Design: Godot-Inspired Mental Model with Static ROM Implementation

### 2.1 The Abstraction Bridge
Zamgba adopts the clear conceptual hierarchy of modern game engines (such as Godot's `TileSet` and `TileMapLayer`), but replaces dynamic runtime heap allocations with flat, ROM-baked static structures:

| Concept | Godot Architecture | Zamgba Engine Model | GBA Hardware Reality |
| :--- | :--- | :--- | :--- |
| **TileSet** | Heap Resource with texture atlases & collision polygons | Flat, static struct in ROM containing raw tile data, palettes, and collision lookup tables | Charblock (CBB) + Palette Memory (PALRAM) |
| **TileMapLayer** | Scene graph node holding sparse dictionary grid of tiles | Lightweight runtime struct referencing ROM-baked entries array + assigned hardware BG channel | Screenblock (SBB) + `REG_BGxCNT` + `REG_BGxHOFS/VOFS` |
| **Tile Collision** | SAT polygon collision on dynamic BVH trees | O(1) grid lookup into ROM collision enum table | Sub-pixel `Fixed24_8 >> 11` index calculation |

### 2.2 ROM-Resident Zero-Heap Philosophy
* **ROM Storage**: Maps, tiles, palettes, and collision grids are baked at compile time into read-only Game Pak ROM (`pakrom`), consuming **0 bytes of IWRAM/EWRAM**.
* **Runtime Layer Struct**: The runtime `TileMapLayer` object is lightweight (under 24 bytes), containing only the assigned hardware `BgId`, allocated SBB/CBB indices, and current scroll coordinates.

---

## 3. Key Data Structures

### 3.1 Hardware-Aligned Screen Entry (`ScreenEntry`)
```zig
pub const ScreenEntry = packed struct(u16) {
    tile_index: u10 = 0,
    h_flip: bool = false,
    v_flip: bool = false,
    palette_bank: u4 = 0,

    pub inline fn raw(self: ScreenEntry) u16 {
        return @bitCast(self);
    }

    pub inline fn fromRaw(val: u16) ScreenEntry {
        return @bitCast(val);
    }
};
```

### 3.2 ROM TileSet Asset (`TileSet`, `TileData`, `Bgr555`)
```zig
pub const Bgr555 = packed struct(u16) {
    r: u5 = 0,
    g: u5 = 0,
    b: u5 = 0,
    unused: u1 = 0,

    pub inline fn raw(self: Bgr555) u16 {
        return @bitCast(self);
    }
    pub inline fn fromRaw(val: u16) Bgr555 {
        return @bitCast(val);
    }
};

pub const Tile4bpp = [8]u32;  // 32 bytes (8x8 pixels at 4-bpp)
pub const Tile8bpp = [16]u32; // 64 bytes (8x8 pixels at 8-bpp)

pub const TileData = union(enum) {
    bpp4: []const Tile4bpp,
    bpp8: []const Tile8bpp,

    pub fn tileCount(self: TileData) usize { ... }
    pub fn byteSize(self: TileData) usize { ... }
    pub fn wordCount(self: TileData) usize { ... }
    pub fn rawPtr(self: TileData) [*]const u32 { ... }
    pub fn is8bpp(self: TileData) bool { ... }
};

pub const TileSet = struct {
    tiles: TileData,              // Type-safe 4-bpp or 8-bpp tile array
    palette: []const Bgr555,      // Type-safe 15-bit BGR palette colors
    collision_flags: []const u8,  // Collision type for each tile index
};
```

### 3.3 ROM Map Layer Asset (`MapLayerData`)
```zig
pub const MapLayerData = struct {
    width: u16,                   // Width in tiles (e.g. 32, 64, 200)
    height: u16,                  // Height in tiles (e.g. 32, 32, 100)
    tileset: *const TileSet,      // Reference to the shared TileSet
    entries: []const ScreenEntry, // Flattened 2D grid of ScreenEntry values (width * height)
    collision: ?[]const u8 = null,// Optional direct per-cell collision override grid
};
```

### 3.4 Runtime Layer Instance (`TileMapLayer`)
```zig
pub const TileMapLayer = struct {
    bg_id: hal.display.BgId,
    charblock: u2,
    screenblock: u5,
    size: hal.display.BgSize,
    data: *const MapLayerData,
    scroll_x: i32 = 0,
    scroll_y: i32 = 0,
    priority: u2 = 1,

    /// Uploads tileset and screenblock entries to VRAM via DMA and configures REG_BGxCNT
    pub fn initHardware(self: *TileMapLayer) void { ... }

    /// Updates the hardware scroll registers
    pub fn setScroll(self: *TileMapLayer, x: i32, y: i32) void {
        self.scroll_x = x;
        self.scroll_y = y;
        hal.display.setBgScroll(self.bg_id, @intCast(x & 0x1FF), @intCast(y & 0x1FF));
    }

    /// O(1) constant-time collision lookup for world coordinates
    pub fn getCollisionAt(self: *const TileMapLayer, world_x: i32, world_y: i32) u8 {
        if (world_x < 0 or world_y < 0) return 0;
        const tx = @as(usize, @intCast(world_x >> 3));
        const ty = @as(usize, @intCast(world_y >> 3));
        if (tx >= self.data.width or ty >= self.data.height) return 0;

        // Check per-cell collision override first, or fallback to TileSet lookup
        if (self.data.collision) |coll| {
            return coll[ty * self.data.width + tx];
        }
        const entry = self.data.entries[ty * self.data.width + tx];
        if (entry.tile_index < self.data.tileset.collision_flags.len) {
            return self.data.tileset.collision_flags[entry.tile_index];
        }
        return 0;
    }
};
```

---

## 4. Integration with Existing Subsystems

### 4.1 Collision Subsystem Integration (`docs/collision.md`)
The TileMap engine plugs directly into the existing `CollisionMap` streaming interface defined in `src/engine/physics/map.zig`:

```zig
// Adapting TileMapLayer to CollisionMap without dynamic allocations:
pub fn asCollisionMap(layer: *const TileMapLayer) physics.CollisionMap {
    return physics.CollisionMap.initWithContext(
        map_size_from_bg_size(layer.size),
        @ptrCast(layer),
        struct {
            fn isTileSolid(ctx: ?*const anyopaque, tx: u16, ty: u16) bool {
                const self: *const TileMapLayer = @ptrCast(@alignCast(ctx.?));
                return self.getCollisionAt(@as(i32, tx) << 3, @as(i32, ty) << 3) != 0;
            }
        }.isTileSolid,
        .solid,
    );
}
```
This enables unified physics execution: `sprite.moveAndCollide(layer.asCollisionMap())` works seamlessly out of the box with fixed-point `Fixed24_8` precision and 1-cycle collision masks (`CollisionMask`).

### 4.2 VRAM Streaming & DMA Queue Integration (`docs/tile_loading.md`)
* **Tile Data Loading**:
  Tileset graphics are loaded into the target Charblock using the engine's centralized `DmaQueue` (`dma_queue.global_queue.enqueueBytes(...)`) or synchronized bulk DMA transfer during level initialization.
* **Dynamic Seam Streaming**:
  For maps larger than 64×64 tiles, camera position deltas across 8-pixel boundaries trigger incremental row/column DMA copy tasks scheduled through `dma_queue.enqueueDmaBytes`, respecting the VBlank budget guard to prevent display tearing.

---

## 5. Tooling Integration: Why Prioritize LDtk over Tiled

For a solo developer maintaining both the GBA SDK and the asset pipeline tool (`tools/zurag`), **LDtk (Level Designer Toolkit)** is prioritized as the primary level editor integration format over Tiled.

### 5.1 Comparison Matrix

| Evaluation Criteria | **LDtk** (Primary Choice) | **Tiled** (Secondary / Deferred) |
| :--- | :--- | :--- |
| **File Format & Parser Simplicity** | **Single, pure JSON file (`.ldtk`)**. Directly deserializable via `std.json` with zero external dependencies. | Multiple formats (`.tmx` XML, `.tmj` JSON, `.tsx`/`.tsj` external tilesets). Requires complex multi-format branching. |
| **Tile Layer Compression** | Clean, uncompressed integer arrays (`intGridCsv`, `gridTiles`). | Fragmented across raw CSV, Base64, and Base64 + Gzip/Zlib/Zstd compression. |
| **Entity & Spawn Points** | **First-class entity system** with typed fields (`x`, `y`, custom enums/identifiers) exposed directly in JSON. | Object layers requiring custom XML/JSON parsing and untyped string property conversions. |
| **Collision Integration** | **Native `IntGrid` layer**. Perfect 1:1 match for GBA collision enum indices (`1: Solid`, `2: Ladder`, `3: Hazard`). | Requires manual conventions (e.g. naming layers or custom tile properties). |
| **Auto-Tiling Rules** | Built-in rule-based visual auto-tiling over simple collision grids. | Supported, but requires complex `automap` rule file configurations. |
| **Maintenance Cost for `zurag`** | **Very low**: ~300 lines of clean Zig in `tools/zurag/ldtk.zig`. | **High**: requires complex XML/compression/multi-file dependency resolvers. |

### 5.2 Toolchain Workflow with `zurag`
```
LDtk Project (.ldtk)
        │
        ▼
tools/zurag ldtk level.ldtk -o src/assets/level.zig
        ├── 1. Extracts & deduplicates 8x8 tiles into 4-bpp / 8-bpp binary blobs
        ├── 2. Packs visual layers into []const ScreenEntry arrays
        ├── 3. Extracts IntGrid into []const u8 collision flags
        └── 4. Generates typed LevelEntities struct (PlayerSpawn, EnemySpawns)
        │
        ▼
Generated Zig Code (ROM-baked, ready for TileMapLayer)
```

---

## 6. Implementation Roadmap

### Phase 1: HAL & Static TileMap Foundation (v0.3.0)
1. **HAL Layer**:
   - Add `REG_BGxCNT` bitfield structures in `src/hal/display.zig` (Charblock, Screenblock, Priority, Size, 4bpp/8bpp).
   - Implement `setBgControl()`, `enableBgLayer()`, and `setBgScroll()`.
2. **Engine Layer**:
   - Implement `ScreenEntry`, `TileSet`, `MapLayerData`, and `TileMapLayer` in `src/engine/gfx2d/tilemap.zig`.
   - Support standard hardware SBB sizes (`32x32`, `64x32`, `32x64`, `64x64`).
   - Implement `TileMapLayer.asCollisionMap()` bridge to integrate with `src/engine/physics/map.zig`.
3. **Demo**:
   - Create `demo/engine/tilemap_demo.zig` demonstrating Mode 0 background rendering, camera scrolling via D-pad, and player collision against tilemap obstacles.

### Phase 2: Tooling & LDtk Pipeline (`tools/zurag`) (v0.3.0)
1. Implement `tools/zurag/ldtk.zig` parser to convert `.ldtk` JSON into compile-time Zig structures.
2. Generate automatic tileset extraction, palette extraction, packed screen entries, and IntGrid collision arrays.
3. Unit tests under `LDT001` test suite.

### Phase 3: Large Map Seam Streaming & Camera Viewport (v0.3.x / v0.4.0)
1. Implement `Camera2D` entity managing viewport tracking, bounding bounds, and dead zones.
2. Implement ring-buffer seam updater for maps exceeding 64×64 tiles, scheduling seam tile writes via `dma_queue`.

---

## 7. Future Extension: Affine Backgrounds & Mode 7 (v0.8.0)

### 7.1 Hardware Differences: Text vs. Affine Backgrounds
In GBA **Mode 1** (`BG0`, `BG1` Text + `BG2` Affine) and **Mode 2** (`BG2`, `BG3` Affine), the Picture Processing Unit (PPU) supports hardware matrix transformation (rotation, scaling, shear, and perspective distortion):

| Property | Text Backgrounds (Mode 0) | Affine Backgrounds (Mode 1 / Mode 2) |
| :--- | :--- | :--- |
| **PPU Channels** | `BG0`, `BG1`, `BG2`, `BG3` | `BG2`, `BG3` only |
| **Color Depth** | 4-bpp (16-color) or 8-bpp (256-color) | Strictly 8-bpp (256-color) only |
| **Screen Entry Size** | 16-bit (`u16`) with tile index, flips, and bank | 8-bit (`u8`) raw tile index (0..255) only |
| **Hardware Mirroring** | Hardware `h_flip` and `v_flip` bits | Not supported in hardware screen entries |
| **Hardware Registers** | `REG_BGxHOFS`, `REG_BGxVOFS` (Offset only) | `REG_BGxPA`, `PB`, `PC`, `PD` (2x2 Matrix) + `REG_BGxX`, `Y` (28.8 Fixed-Point reference points) |
| **Affine Sizes** | 32×32, 64×32, 32×64, 64×64 | 16×16 (128px), 32×32 (256px), 64×64 (512px), 128×128 (1024px) |

### 7.2 Abstraction Hierarchy Evolution
To keep the engine zero-overhead, orthogonal, and simple:
1. **`TileMapLayer` Remains Strictly 2D Mode 0**: 
   The core `TileMapLayer` will continue targeting standard text backgrounds with zero matrix math overhead.
2. **`AffineTileMapLayer` for Transformed Planes**:
   A dedicated `AffineTileMapLayer` will be introduced in milestone v0.8.0:
   - Holds the 2x2 fixed-point transformation matrix (`Fixed8_8` `pa`, `pb`, `pc`, `pd`) and pivot coordinates (`dx`, `dy`).
   - Supports 8-bit screen entries (`[]const u8`).
   - Updates `REG_BGxPA..PD` and reference registers during VBlank.
3. **`MapLayerData` Reusability**:
   `MapLayerData` can represent affine layers via an `is_affine: bool = false` flag or an 8-bit entry slice variation, sharing the same `TileSet` palette and graphics definitions.
4. **`Camera2D` vs. `Camera3D`**:
   - `Camera2D`: Manages 2D `(x, y)` scrolling, bounding box clamping, dead zones, and screen shake.
   - `Camera3D`: A dedicated Mode 7 / Pseudo-3D camera that computes the transformation matrix (pitch, yaw, height/altitude, horizon line) and projectively maps 3D world coordinates onto the affine registers of `AffineTileMapLayer`.
   - Keeping `Camera2D` and `Camera3D` distinct prevents 3D trigonometric code and matrix overhead from polluting pure 2D platformers and top-down games.
