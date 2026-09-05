# Sprite Animation Tile Loading, VRAM Management & Streaming

This document outlines the architecture, hardware constraints, and implementation strategy for managing 2D sprite animations and dynamic VRAM tile streaming in Zamgba.

---

## 1. Hardware Constraints: Why GBA Cannot Hold Arbitrary Animations

### A. OBJ VRAM Capacity Limitations
* **VRAM Layout**: The GBA has 96 KB total Video RAM. In Tile Modes (Mode 0, 1, 2), Sprite (OBJ) character data is mapped to Charblock 4 and 5 (`0x06010000`–`0x06017FFF`), providing strictly **32 KB** of OBJ VRAM.
* **Tile Capacity**:
  - **4-bpp Mode** (32 bytes / 8x8 tile): Exactly **1024 tiles**.
  - **8-bpp Mode** (64 bytes / 8x8 tile): Exactly **512 tiles**.
* **Footprint Reality**:
  - A 32x32 pixel, 8-bpp sprite (e.g. Tsetseg flying animation) requires 16 tiles (1024 bytes) per frame. An 8-frame cycle consumes **8 KB** (25% of total OBJ VRAM).
  - A 64x64 pixel, 8-bpp boss requires 64 tiles (4096 bytes) per frame. An 8-frame cycle consumes **32 KB** (100% of OBJ VRAM), leaving zero memory for player, bullets, or enemies.

### B. Storage Asymmetry (ROM vs. VRAM)
GBA Game Pak ROMs can reach up to **32 MB** (1000x larger than OBJ VRAM), while EWRAM provides **256 KB**. ROM can easily store thousands of high-quality animation frames, but VRAM cannot hold them simultaneously.

### C. VBlank Timing and DMA Bandwidth Redline
* **VRAM Write Restrictions**: Writing to VRAM during active scanline rendering (HDraw) causes bus contention, visual tearing, and sprite corruption.
* **VBlank Window Budget**:
  - GBA runs at 60 FPS (228 total scanlines, 160 active visible lines, 68 VBlank lines).
  - The VBlank duration is **83,776 CPU cycles** (~5 milliseconds).
* **Transfer Speed**:
  - CPU copy loops take over 10 cycles per byte.
  - Hardware **Direct Memory Access (DMA 3)** transfers 32-bit words at 1–2 cycles per word. Streaming tile data during VBlank via DMA is essential for high-frame-rate rendering.

---

## 2. Paradigm Comparison: Modern Engines vs. GBA

| Aspect | Modern Engines (Godot, Raylib, Unity) | GBA Hardware Architecture |
| :--- | :--- | :--- |
| **VRAM Capacity** | Gigabytes of dedicated VRAM | 32 KB shared OBJ Tile RAM |
| **Sprite Animation** | Whole sprite sheets cached in GPU textures; animation shifts UV coordinates (`Rect2`) with zero CPU/GPU copy overhead. | Limited tile slots; animations exceeding VRAM must be dynamically paged/streamed from ROM to VRAM at runtime. |
| **Coordinate System** | Arbitrary floating-point rectangle slicing. | Rigid hardware-aligned bounding sizes (8x8, 16x16, 32x32, 64x64, 32x64, etc.) mapped to 8x8 tile matrices. |
| **Memory Access** | Asynchronous GPU texture uploads anytime. | VRAM writes strictly confined to the 83,776-cycle VBlank window. |

---

## 3. Prior Art in GBA Development

1. **`libtonc` (Low-Level C Library)**:
   Provides hardware register definitions (`REG_DMA3SAD`, `REG_DMA3DAD`, `REG_DMA3CNT`) and macro helpers (`dma3_cpy`). Developers must manually compute memory addresses, implement double-buffering, and write custom VBlank interrupt handlers, leading to fragmentation and repetitive boilerplate.
2. **`Butano` (Modern Advanced C++ Engine)**:
   Introduces an internal dynamic VRAM Buddy Allocator combined with an automatic DMA transfer queue. When a sprite advances its frame (`sprite.set_tiles(...)`), tiles are committed to a temporary queue and flushed via DMA3 during VBlank.

---

## 4. Mental Model Challenges for Modern Developers

1. **"Why can't I just play an animation?"**:
   Modern developers are accustomed to instant sprite sheet playback and may not realize that large sprite animation on retro hardware involves memory paging and DMA queue scheduling.
2. **Tile and BPP Constraints**:
   4-bpp vs. 8-bpp sprites have different byte lengths and stride rules. A 32x32 sprite is 16 tiles in 4-bpp (512 bytes) but requires 32 tile index units in 8-bpp (1024 bytes).
3. **VBlank Overdraw (DMA Tearing)**:
   Attempting to stream too many frames in a single frame (e.g., 10 large enemies changing animations simultaneously) will exceed the 83,776-cycle VBlank budget, extending DMA into HDraw and corrupting the display.

---

## 5. Layered Architecture: HAL vs. Engine

```
┌─────────────────────────────────────────────────────────┐
│                    User Game Logic                      │
│        player.playAnimation("fly");                     │
└────────────────────────────┬────────────────────────────┘
                             │
=============================▼=============================
  Engine Layer (State Machines, Allocator & Queued Streaming)
───────────────────────────────────────────────────────────
  1. AnimatedSprite / SpriteSheet
     - Tracks frame timers, tags, and loop states.
     - Static Mode: All frames resident; updates OAM tile_index.
     - Streaming Mode: Fixed VRAM slot; enqueues frame copy task.
  2. VramAllocator (Bitwise Buddy Allocator)
     - Manages 1024 4-bpp tile slots (32 KB OBJ VRAM).
     - Power-of-2 block allocation (1, 2, 4, 8, 16, 32, 64, 128 tiles).
     - Automatic buddy merging on sprite destruction.
  3. DmaQueue (Fixed Ring Buffer)
     - Staged transfer tasks: { src_rom, dest_vram, words }.
     - VBlank DMA Budget Guard (prevents exceeding cycle limit).
=============================┬=============================
                             │ eng.nextFrame() flushes during VBlank
=============================▼=============================
  HAL Layer (Atomic Hardware Access & Host Test Safety)
───────────────────────────────────────────────────────────
  src/hal/dma.zig
     - REG_DMAxSAD, REG_DMAxDAD, REG_DMAxCNT_L, REG_DMAxCNT_H.
     - copy16 / copy32 atomic transfer primitives.
     - Freestanding guard: real MMIO writes on GBA, memory mocks on host.
```

### HAL Layer Responsibilities (`src/hal/dma.zig`)
* Direct bitfield definitions for DMA0–DMA3 control registers.
* Safe, inline assembly/volatile memory wrappers for 16-bit and 32-bit DMA transfers.
* Target isolation: compiles real hardware writes when `builtin.target.os.tag == .freestanding`, and routes to mock host buffers during unit testing (`zig build test`).

### Engine Layer Responsibilities (`src/engine/`)
* **`VramAllocator`**: Flat bit-tree Buddy Allocator in `.bss` allocating hardware tile indices using `@clz` bitwise math with zero dynamic heap allocation. *(See full specification in [docs/vram_allocator.md](vram_allocator.md))*.
* **`AnimatedSprite`**: Clean high-level API (`play("run")`, `update()`, `setFrame(i)`).
* **`DmaQueue`**: Transparently collects pending frame transfers during the game logic tick and executes them via `hal.dma` when `eng.nextFrame()` reaches VBlank. *(See full specification in [docs/tile_dma_queue.md](tile_dma_queue.md))*.

---

## 6. Slicing, Asset Pipeline & 1D OBJ Mapping

### A. 1D vs. 2D OBJ Mapping
GBA display control register (`REG_DISPCNT`) is configured to **1D OBJ Mapping** (`OBJ_1D_MAP`).
* **2D Mapping**: Treats VRAM as a 256x256 pixel grid, requiring complex 2D rectangle bin-packing at runtime.
* **1D Mapping**: Treats VRAM as a continuous 1D array of 8x8 tiles. A 32x32 sprite is flattened into 16 consecutive tiles. This transforms VRAM management into standard 1D power-of-2 allocation, perfectly aligning with the Buddy Allocator.

### B. Zero-Dependency Build Tool (`zurag`)
1. **Parsing**: Slices Aseprite Indexed-color PNG (`PLTE`, `IDAT` Deflate) and JSON (`frame`, `frameTags`) into 1D row-major 8x8 tile sequences.
2. **Code Generation**: Emits strongly-typed Zig source matching the `engine.SpriteSheet` contract (`raw_tiles`, `frames`, `tags`, `palette`).
3. **Smart Footprint Diagnostics**:
   - Computes $\text{Total Tiles} = \text{Frame Count} \times \text{Tiles Per Frame}$.
   - If $\text{Total Tiles} \le 16$, marks asset as `prefer_streaming = false` (safe for full static VRAM caching).
   - If $\text{Total Tiles} > 32$, emits `pub const prefer_streaming = true;` to advise developers to stream the asset.

---

## 7. Runtime Diagnostics & Safety Guards

1. **VRAM Capacity Overflow**:
   When `VramAllocator.alloc()` cannot find a free buddy block, it returns `error.OutOfVram` with debug assertions reporting requested tile count and active memory footprint.
2. **DMA Bandwidth Budget Guard**:
   `DmaQueue` limits total words queued per frame (e.g. max 4 KB per VBlank). If budget is exceeded, non-critical transfers gracefully defer to the subsequent VBlank, preventing screen tearing and emulator crashes.
