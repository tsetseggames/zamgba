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

### 1.3 Map Sizing & Hardware Multi-Screenblock Quadrant Layout
The GBA hardware text background engine natively supports 4 base layouts controlled by `REG_BGxCNT.screen_size`:
* **32×32 tiles (256×256 px)**: 1 SBB (2 KB) — Ideal for UI/HUD, fixed menus, minigames.
* **64×32 tiles (512×256 px)**: 2 contiguous SBBs (4 KB) — Horizontal scrolling rooms.
* **32×64 tiles (256×512 px)**: 2 contiguous SBBs (4 KB) — Vertical scrolling shafts.
* **64×64 tiles (512×512 px)**: 4 contiguous SBBs (8 KB) — Medium exploration arenas.

#### The Multi-Screenblock Quadrant Pitfall

A crucial hardware characteristic of the GBA is that **multi-Screenblock layouts are NOT stored as flat row-major arrays in VRAM**. 
Instead, each Screenblock always represents an autonomous 32×32 tile block (1,024 halfwords = 2,048 bytes). Larger map sizes are formed by stitching contiguous 32×32 SBBs together in a fixed quadrant topology:

```
1. size_32x32 (1 SBB: SBB 0)
   +-----------+
   |   SBB 0   |
   | (32 x 32) |
   +-----------+

2. size_64x32 (2 SBBs: SBB 0, SBB 1)
   +-----------+-----------+
   |   SBB 0   |   SBB 1   |
   | (32 x 32) | (32 x 32) |
   +-----------+-----------+

3. size_32x64 (2 SBBs: SBB 0, SBB 1)
   +-----------+
   |   SBB 0   |
   | (32 x 32) |
   +-----------+
   |   SBB 1   |
   | (32 x 32) |
   +-----------+

4. size_64x64 (4 SBBs: SBB 0, SBB 1, SBB 2, SBB 3)
   +-----------+-----------+
   |   SBB 0   |   SBB 1   |
   | (Top-Left)|(Top-Right)|
   +-----------+-----------+
   |   SBB 2   |   SBB 3   |
   |(Btm-Left) |(Btm-Right)|
   +-----------+-----------+
```

#### Linear Source Data vs. Quadrant VRAM Addressing

In standard game asset pipelines (including LDtk export via `zurag`), level map data is exported in standard row-major order:
$$\text{src\_index} = y \times \text{width} + x$$

If a 64×64 map were copied linearly into VRAM, row 0 (64 tiles) would spill into SBB 0 (first 32 tiles) and SBB 1 (second 32 tiles). However, the GBA PPU hardware expects SBB 0 to contain rows 0–31 of the top-left quadrant! A direct linear copy results in severe vertical row shearing and visual scrambling.

To place entries into VRAM correctly, `TileMapLayer.initHardware()` translates coordinates $(x, y)$ into the target SBB halfword offset:

```zig
fn getScreenEntryVramIndex(size: hal.display.BgSize, x: usize, y: usize) usize {
    const SBB_ENTRIES: usize = 1024;
    return switch (size) {
        .size_32x32 => y * 32 + x,
        .size_64x32 => (if (x < 32) 0 else SBB_ENTRIES) + y * 32 + (x % 32),
        .size_32x64 => (if (y < 32) 0 else SBB_ENTRIES) + (y % 32) * 32 + x,
        .size_64x64 => {
            const sbb_x: usize = if (x < 32) 0 else 1;
            const sbb_y: usize = if (y < 32) 0 else 1;
            const sbb_idx = sbb_y * 2 + sbb_x;
            return sbb_idx * SBB_ENTRIES + (y % 32) * 32 + (x % 32);
        },
    };
}
```

#### VRAM Memory Overlap: Charblocks vs. Screenblocks

Each Screenblock is 2 KB, while each Charblock (CBB) is 16 KB (the equivalent of 8 Screenblocks).
* `CBB 0`: SBB 0 – 7 (0x06000000 – 0x06003FFF)
* `CBB 1`: SBB 8 – 15 (0x06004000 – 0x06007FFF)
* `CBB 2`: SBB 16 – 23 (0x06008000 – 0x0600BFFF)
* `CBB 3`: SBB 24 – 31 (0x0600C000 – 0x0600FFFF)

When using Charblock 0 for tile graphics, multi-Screenblock maps should be allocated in high Screenblocks (e.g. SBB 28–31 at `0x0600E000` for a 64×64 map) to prevent tile graphics from corrupting map entries or vice versa.

#### Streaming for Extra-Large Maps

For levels larger than 64×64 (e.g. 2048×1024 platformers or infinite scrolling stages), VRAM cannot hold the whole map at once. A **streaming ring buffer** is used: VRAM holds only the 32×32 or 64×64 visible window, and as the camera moves past tile boundaries, newly revealed seams (rows/columns) are streamed into VRAM during VBlank via DMA.

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
* **Runtime Layer Struct**: The runtime `TileMapLayer` object is lightweight (under 28 bytes), containing only the assigned hardware `BgId`, allocated SBB/CBB indices, and current scroll coordinates.

### 2.3 Automated Background VRAM Management (`BgVramManager`)
Beginning with Issue #43, developers no longer manually compute Charblocks, Screenblocks, or multi-screenblock offsets. The engine introduces `BgVramManager`, a zero-heap VRAM layout manager inspired by Butano's block management:
1. **Tileset Deduplication**: Multiple background layers referencing the same static `*const TileSet` share the same allocated Charblock (CBB 0..3), saving precious VRAM.
2. **Conflict-Free SBB Allocation**: When Charblock $k$ is allocated for tiles, its overlapping Screenblocks ($8k \dots 8k+7$) are automatically blocked. Map entries are allocated in free, non-overlapping Screenblock regions (e.g. SBB 16..31).
3. **Contiguous Multi-Screenblock Placement**: For 64x64 maps (which require 4 contiguous Screenblocks arranged in quadrants), `BgVramManager` automatically finds a contiguous 4-SBB block.
4. **Zero-Config Developer API**:
   ```zig
   // Automated VRAM allocation and hardware initialization in one call:
   var bg_dirt = try engine.TileMapLayer.init(&large_dirt_map.Level_0_Dirt_data, .{ .priority = 2 });
   ```
   Manual placement is still accessible for low-level ROM hacking or custom demoscene effects via `options.manual_placement`.

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
    tiles: TileData,                        // Type-safe 4-bpp or 8-bpp tile array
    palette: []const Bgr555,                // Type-safe 15-bit BGR palette colors
    collision_masks: []const CollisionMask, // 16-bit collision layer mask for each tile index
};
```

### 3.3 ROM Map Layer Asset (`MapLayerData`)
`MapLayerData` is generated at compile time by `zurag` from LDtk levels or tilemaps. It self-describes its dimensions and hardware `BgSize`:
```zig
pub const MapLayerData = struct {
    width: u16,                   // Width in tiles (e.g. 32, 64)
    height: u16,                  // Height in tiles (e.g. 32, 64)
    size: hal.display.BgSize,     // Inferred or explicit hardware background size
    tileset: ?*const TileSet = null, // Reference to the shared TileSet
    entries: []const ScreenEntry, // Flattened 2D grid of ScreenEntry values (width * height)
};
```

### 3.4 Runtime Layer Instance (`TileMapLayer`)
`TileMapLayer` encapsulates a hardware Mode 0 background channel:
```zig
pub const TileMapLayerOptions = struct {
    bg_id: ?hal.display.BgId = null,
    priority: u2 = 1,
    collision_mask: CollisionMask = Collision.ALL,
    manual_placement: ?struct {
        charblock: u2,
        screenblock: u5,
    } = null,
};

pub const TileMapLayer = struct {
    bg_id: hal.display.BgId,
    charblock: u2,
    screenblock: u5,
    size: hal.display.BgSize,
    data: *const MapLayerData,
    scroll_x: i32 = 0,
    scroll_y: i32 = 0,
    priority: u2 = 1,
    collision_mask: CollisionMask = Collision.ALL,

    /// High-level constructor: automatically manages VRAM (CBB & SBB) and initializes hardware.
    pub fn init(data: *const MapLayerData, options: TileMapLayerOptions) !TileMapLayer { ... }

    /// Uploads tileset and screenblock entries to VRAM via DMA and configures REG_BGxCNT
    pub fn initHardware(self: *TileMapLayer) void { ... }

    /// Updates the hardware scroll registers
    pub fn setScroll(self: *TileMapLayer, x: i32, y: i32) void { ... }

    /// O(1) constant-time collision lookup for world coordinates, returning 16-bit CollisionMask
    pub fn getCollisionAt(self: *const TileMapLayer, world_x: i32, world_y: i32) CollisionMask { ... }

    /// Adapts TileMapLayer into a CollisionMap for physics engine integration
    pub fn asCollisionMap(self: *const TileMapLayer) physics.CollisionMap { ... }
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
                const wx = @as(i32, tx) << 3;
                const wy = @as(i32, ty) << 3;
                return (self.getCollisionAt(wx, wy) & self.collision_mask) != 0;
            }
        }.isTileSolid,
        .solid,
    );
}
```
This enables unified physics execution: `sprite.moveAndCollide(layer.asCollisionMap())` works seamlessly out of the box with fixed-point `Fixed24_8` precision and 1-cycle collision masks (`CollisionMask`).

### 4.2 Collision Definition Architecture: TileSet vs. Map Grid Decision Analysis

During the design of the collision model, two architectural paradigms were evaluated:

1. **Map-Grid Collision (Per-Cell Override Array on `MapLayerData`)**:
   - Every cell in the map has an independent collision mask entry (e.g. `[]const CollisionMask` of size `width * height`).
2. **TileSet-Bound Collision (`TileSet.collision_masks`)**:
   - Collision masks are bound directly to `tile_index` inside the `TileSet`.

#### Architectural Comparison Matrix

| Evaluation Metric | Map-Grid Override Array | TileSet-Bound Collision Mask (`zamgba` Choice) |
| :--- | :--- | :--- |
| **ROM Memory Footprint** | **Severe (~16 KB per 128×64 layer)**: Storing a separate 16-bit mask per cell on large stages rapidly exhausts cartridge ROM. | **Minimal (~256–512 B per TileSet)**: An array of 128~256 entries is shared across all map layers referencing the tileset (64x reduction). |
| **Ambiguity & Fallback Hazard** | **High**: Dual-source collision introduces subtle bugs when a developer defines masks on tilesets but forgets map grid entries (or vice versa). | **Zero**: Single source of truth. Every tile index deterministically maps to its collision attributes. |
| **GBA Palette-Bank Synergy** | **Irrelevant**: Ignores GBA's hardware strength of reusing tile bitmaps with different palette banks. | **Optimal**: Different visual variants (e.g. lit wall vs shadow wall) can share the same tile index + collision mask via `palette_bank`, or use a separate visual tile if passable. |
| **Passable Clones / Secret Passages** | Handled by overriding specific grid cells. | Handled cleanly by allocating a dedicated passable tile clone in the tileset (at merely 32 bytes for a 4-bpp tile) without burdening the entire map with a 16 KB grid table. |

**Final Architectural Decision**:
Collision is **strictly bound to `TileSet.collision_masks`**. `MapLayerData` does not store redundant per-cell collision arrays. The build tool (`zurag`) extracts collision classifications directly into the static ROM `TileSet` asset.

### 4.2 VRAM Streaming & DMA Queue Integration (`docs/sprite.md`)
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

### 5.3 Recommended LDtk Workflow for GBA Games

To balance LDtk's modern desktop level-editing capabilities with GBA hardware constraints, ZamGBA recommends the following 5 workflow rules for all projects:

1. **One LDtk Project per Game**: Maintain a single central `.ldtk` project file per game repository (e.g. `assets/world.ldtk`), keeping asset paths and level structures unified.
2. **Multi-Level Definition**: Define one or more levels within the project. `zurag tilemap` converts the entire project into a single Zig asset file, exporting a shared global `TileSet` alongside individual level descriptors (`Level0`, `Level1`, etc.).
3. **Single Tileset PNG Asset**: All visual layers and definitions must share exactly one common tileset PNG image. Multiple tileset PNG references are strictly rejected at conversion time (`error.MultipleTilesetsNotSupported`). Interactive entities (items, enemies, NPCs) should be marked as LDtk Entities; their sprite graphics are loaded separately through the engine's sprite system.
4. **Hardware-Aligned Layer Budget**: Each level may define at most 4 visual tile layers (mapping directly to GBA Mode 0 background layers `BG0`–`BG3`) and at most 1 `IntGrid` collision layer (mapping to a unified 16-bit `CollisionMask`).
5. **Bounded Map Dimensions**: Maximum map dimension is capped at 4096 × 4096 pixels (`512 × 512` 8x8 tiles). Maps exceeding this limit trigger `error.MapTooLarge`. Large worlds within this budget stream visible chunks into hardware Screenblocks dynamically via the Camera and TileMap streaming systems.

> **Note on LDtk Import Constraints**: For detailed specifications and architectural rationale on these constraints, see [docs/tool_zurag_pic_conversion.md (Section 8)](tool_zurag_pic_conversion.md#8-tilemap--ldtk-conversion-constraints-and-design-rationale).

---

## 6. Implementation Roadmap

### Phase 1: HAL & Static TileMap Foundation (v0.3.0)
1. **HAL Layer**:
   - Add `REG_BGxCNT` bitfield structures in `src/hal/display.zig` (Charblock, Screenblock, Priority, Size, 4bpp/8bpp).
   - Implement `setBgControl()`, `enableBgLayer()`, and `setBgScroll()`.
2. **Engine Layer**:
   - Implement `ScreenEntry`, `TileSet`, `MapLayerData`, and `TileMapLayer` in `src/engine/tilemap.zig`.
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
