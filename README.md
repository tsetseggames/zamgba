<p align="center">
  <img src="assets/zamgba-logo.svg" width="180" alt="Zamgba Logo" />
</p>

<h1 align="center">Zamgba</h1>

<p align="center">
  <strong>A type-safe Game Boy Advance (GBA) SDK and 2D Game Engine in pure <a href="https://ziglang.org">Zig</a>.</strong>
</p>

<p align="center">
  <a href="https://ziglang.org/"><img src="https://img.shields.io/badge/Zig-0.17.0%2B-F7A41D?logo=zig&logoColor=white" alt="Zig Version" /></a>
  <a href="build.zig.zon"><img src="https://img.shields.io/badge/version-v0.3.1-6366F1" alt="Version v0.3.1" /></a>
  <a href="https://en.wikipedia.org/wiki/Game_Boy_Advance"><img src="https://img.shields.io/badge/target-ARM7TDMI%20%28GBA%29-312E81" alt="Target GBA" /></a>
</p>

---

> [!IMPORTANT]
> **Disclaimer:** Zamgba is an unofficial homebrew development tool. It is not affiliated with, authorized, sponsored, or endorsed by Nintendo Co., Ltd. "Game Boy", "GBA", and "Game Boy Advance" are registered trademarks of Nintendo.

---

## 1. Overview & Showcase

**Zamgba** is an open-source Software Development Kit (SDK) and 2D game engine for the Game Boy Advance (GBA), written entirely in [**Zig**](https://ziglang.org).

Zamgba bridges the gap between low-level bare-metal hardware programming and modern game development workflows. It provides a clean, two-layer architecture:
- **`zamgba.hal`**: A type-safe hardware abstraction layer mapping GBA registers, VRAM, OAM, and display modes without raw pointer arithmetic.
- **`zamgba.engine`**: A high-level 2D engine featuring camera viewport tracking, parallax scrolling, sub-pixel tilemap physics, and automated VRAM streaming.

*For in-depth architectural breakdown, hardware memory mapping, and layering rules, see [docs/architecture.md](docs/architecture.md).*

### Showcase

Watch Zamgba in action — from source code and cross-compilation to running the interactive `tilemap_collision` demo in mGBA:

<p align="center">
  <a href="https://youtu.be/6hRcTL-eEYA" target="_blank"><img src="https://img.shields.io/badge/YouTube-Watch%20Showcase%20(20s)-FF0000?style=for-the-badge&logo=youtube&logoColor=white" alt="YouTube Showcase" /></a>
  &nbsp;&nbsp;&nbsp;&nbsp;
  <a href="https://www.bilibili.com/video/BV12PyjzSEzS/" target="_blank"><img src="https://img.shields.io/badge/Bilibili-观看演示视频%20(20秒)-00A1D6?style=for-the-badge&logo=bilibili&logoColor=white" alt="Bilibili Showcase" /></a>
</p>

> **Video Highlights (20s):**
> 1. Cross-compiling the `tilemap_collision` demo with [Zig](https://ziglang.org) via `zig build`.
> 2. Booting the compiled `.gba` binary inside the [mGBA](https://mgba.io/) emulator.
> 3. Real-time character movement, sub-pixel physics (`Fixed24_8`), and AABB collision resolution against LDtk tilemap boundaries.

---

## 2. Quickstart

### Prerequisites

1. Install [**Zig**](https://ziglang.org) (**0.17.0** or later). We recommend using [**zvm**](https://www.zvm.app/) (Zig Version Manager) to easily install and manage your [Zig](https://ziglang.org) toolchains.
2. Install the **[mGBA](https://mgba.io/)** emulator (recommended for assembly-level debugging and register logging).

### Build & Run

```bash
# 1. Clone the repository
git clone https://github.com/tsetseggames/zamgba.git
cd zamgba

# 2. Build standard ELF and GBA ROM binaries
zig build

# 3. Run a compiled demo on mGBA
mgba ./zig-out/bin/tilemap_collision.gba

# 4. Run unit tests on host
zig build test
```

Compiled `.gba` ROMs will be placed in `zig-out/bin/`. For assembly-level source debugging, run `mgba -d ./zig-out/bin/<rom_name>.gba`.

**Recommended First Demo**: Start with [`demo/engine/tilemap_collision.zig`](demo/engine/tilemap_collision.zig). — It ties together LDtk tilemap rendering, character movement, and continuous sub-pixel collision in one clean showcase of the modern asset workflow.

---

## 3. Interactive Demo ROMs

Zamgba includes over 17 standalone instructional and technical demo ROMs. Key highlights include:

| Demo ROM | Category | Highlights |
| :--- | :--- | :--- |
| **`camera_demo`** | Engine | Full-featured 2D camera viewport tracking, smooth lerp, deadzone, screen shake, and frustum culling in a 512×512 scrolling world. |
| **`parallax_scroll`** | Engine | Multi-layer Mode 0 background parallax scrolling across 4 independent text layers. |
| **`tilemap_collision`** | Engine | Continuous sub-pixel physics (`Fixed24_8`) colliding and sliding smoothly against background tile layers. |
| **`sprite_animation_streaming`** | Engine | Dynamic VRAM slot leasing via buddy allocator and DMA queue streaming during VBlank. |
| **`pong`** | Engine | Classic, fully playable Pong game with paddle kinematics, AI tracking, and score management. |
| **`background_hal`** | HAL | Direct register-level Mode 0 tiled background configuration and real-time hardware scrolling. |
| **`mode3_lines`** | HAL | Bresenham line rendering directly in Mode 3 true-color bitmap VRAM. |

👉 **For the complete demo catalog, source paths, and our roadmap for the durable showcase game (*Tsetseg's Quest*), see [docs/demo.md](docs/demo.md).**

---

## 4. Modern Asset Pipeline (`zurag`)

The biggest highlight of Zamgba is its integration with modern, industry-standard content creation tools via its built-in companion CLI tool **`zurag`**:

### Aseprite Animation Pipeline
Instead of manually slicing spritesheets or writing hardcoded frame offsets, `zurag` directly ingests **[Aseprite](https://www.aseprite.org)** JSON metadata and sprite sheets:
- Automatically packs 8×8 GBA tiles and slices frame tags.
- Supports both static ROM-to-VRAM preloading and real-time VRAM tile streaming via VBlank DMA.
- **Explore Demos**:
  - [`demo/engine/flappy_tsetseg.zig`](demo/engine/flappy_tsetseg.zig) (Static all-frame VRAM preloading)
  - [`demo/engine/flappy_tsetseg_streaming.zig`](demo/engine/flappy_tsetseg_streaming.zig) (DMA-driven single-slot VRAM streaming)

### LDtk Level Editor & TileMap Pipeline
Level design is performed in **[LDtk](https://ldtk.io)** (2D Level Designer) rather than legacy grid editors:
- Automatically parses LDtk `.ldtk` project files, extracts tile layers, deduplicates identical 8×8 tiles, and generates packed 16-bit `ScreenEntry` maps.
- Ingests LDtk `IntGrid` collision layers and integrates them directly into the engine's 2D physics system.
- **Explore Demos**:
  - [`demo/engine/ldtk_minimal.zig`](demo/engine/ldtk_minimal.zig) (Minimal standalone LDtk Mode 0 tilemap rendering)
  - [`demo/engine/camera_demo.zig`](demo/engine/camera_demo.zig) (Large scrolling LDtk world with smooth camera tracking)
  - [`demo/engine/tilemap_collision.zig`](demo/engine/tilemap_collision.zig) (Continuous sub-pixel box-to-tilemap physics and collision response)

---

## 5. Using Zamgba in Your Project

Zamgba can be referenced as a dependency in your own GBA game project via standard package workflows or Git submodules.

See the complete companion template at **[consumezamgba](https://github.com/fuzhouch/consumezamgba)**.

Add Zamgba to your `build.zig.zon`:
```zig
.{
    .name = .my_gba_game,
    .fingerprint = 0xd1b42ce21396a40a,
    .version = "0.1.0",
    .dependencies = .{
        .zamgba = .{
            .url = "https://github.com/tsetseggames/zamgba/archive/refs/tags/v0.3.1.tar.gz",
            .hash = "...", // or use a local path: .path = "../zamgba"
        },
    },
    .paths = .{ "build.zig", "build.zig.zon", "src" },
}
```

### 1. Freestanding Target Setup (`build.zig`)
In your `build.zig`, invoke `gba.arm.addROM()` to configure the freestanding ARM7TDMI cross-compilation target (`thumb-freestanding-eabi`), inject the custom linker script (`gba.ld`), and generate the `.gba` binary:

```zig
const std = @import("std");
const gba = @import("zamgba");

pub fn build(b: *std.Build) void {
    const optimize = b.standardOptimizeOption(.{});

    // 1. Add GBA ROM compilation step
    const rom = gba.arm.addROM(b, .{
        .name = "my_game",
        .root_source_file = b.path("src/main.zig"),
        .optimize = optimize,
    });

    b.installArtifact(rom.elf);
}
```

### 2. GBA ROM Header Registration (`src/main.zig`)
In your root source file, export the static GBA ROM header into the `.gba.header` section so that the GBA BIOS can validate and boot the cartridge:

```zig
const zamgba = @import("zamgba");

pub export var gameHeader linksection(".gba.header") = zamgba.hal.setupROMHeader(
    "MYGAME", // 12-char Game Title
    "GM01",   // 4-char Game Code
    "00",     // 2-char Maker Code
    0,        // Main version
);
```

### 3. Main Entry & Engine Loop (`src/main.zig`)
Define an exported `main()` function. Initialize the hardware and hand control over to `engine.run()`:

```zig
pub export fn main() noreturn {
    zamgba.engine.initHardware();
    var game = Game.init();
    zamgba.engine.run(&game);
}
```

### 4. Compile Aseprite Sprite Sheets via `zurag`
To compile Aseprite JSON metadata and spritesheet PNGs into zero-overhead [Zig](https://ziglang.org) data structures, obtain the `zurag` executable artifact from the `zamgba` dependency and register an asset conversion step in `build.zig`:

```zig
// In build.zig:
const zamgba_dep = b.dependency("zamgba", .{});
const hal_module = zamgba_dep.module("zamgba-hal");
const engine_module = zamgba_dep.module("zamgba-engine");
const zurag_exe = zamgba_dep.artifact("zurag");

// Generate Zig source from Aseprite PNG + JSON
const convert_broom_sprite = b.addRunArtifact(zurag_exe);
convert_broom_sprite.addArg("sprite");
convert_broom_sprite.addArg("--png");
convert_broom_sprite.addFileArg(b.path("assets/sprites/tsetseg_broom.png"));
convert_broom_sprite.addArg("--json");
convert_broom_sprite.addFileArg(b.path("assets/sprites/tsetseg_broom.json"));
convert_broom_sprite.addArg("--out");
const broom_zig_output = convert_broom_sprite.addOutputFileArg("tsetseg_broom.zig");

// Expose the generated code as an anonymous module
const broom_module = b.createModule(.{
    .root_source_file = broom_zig_output,
    .imports = &.{
        .{ .name = "zamgba-hal", .module = hal_module },
        .{ .name = "zamgba-engine", .module = engine_module },
    },
});
rom.elf.root_module.addImport("tsetseg_broom", broom_module);
```

Then in your game code (`src/main.zig`), import and instantiate the compiled sprite animations directly:

```zig
const broom = @import("tsetseg_broom");

// Preload palette and graphics tiles into VRAM
broom.loadPalette();
try broom.loadTiles();

// Instantiate AnimatedSprite
var player_spr = try engine.AnimatedSprite.init(
    Fixed24_8.fromInt(100),
    Fixed24_8.fromInt(60),
    broom.SPRITE_DESCRIPTOR,
    &broom.ANIM_HOVER,
);
```

### 5. Compile LDtk Levels & TileMaps via `zurag`
Similarly, compile LDtk `.ldtk` project files and tilesets into optimized GBA Mode 0 background tilemaps and collision masks:

```zig
// In build.zig:
const convert_large_dirt_map = b.addRunArtifact(zurag_exe);
convert_large_dirt_map.addArg("tilemap");
convert_large_dirt_map.addArg("--ldtk");
convert_large_dirt_map.addFileArg(b.path("assets/levels/world.ldtk"));
convert_large_dirt_map.addArg("--tileset");
convert_large_dirt_map.addFileArg(b.path("assets/tilesets/dirt_tileset.png"));
convert_large_dirt_map.addArg("--level");
convert_large_dirt_map.addArg("Level_0");
convert_large_dirt_map.addArg("--out");
const large_dirt_map_output = convert_large_dirt_map.addOutputFileArg("large_dirt_map.zig");

const large_dirt_map_module = b.createModule(.{
    .root_source_file = large_dirt_map_output,
    .imports = &.{
        .{ .name = "zamgba-hal", .module = hal_module },
        .{ .name = "zamgba-engine", .module = engine_module },
    },
});
rom.elf.root_module.addImport("large_dirt_map", large_dirt_map_module);
```

In your game code (`src/main.zig`), bind the tilemap layer and collision callback:

```zig
const large_dirt_map = @import("large_dirt_map");

// Load tiles and palette into Background VRAM blocks
large_dirt_map.load();

var bg_dirt = engine.TileMapLayer{
    .bg_index = 0,
    .screen_block_base = 8,
    .tile_block_base = 0,
    .map_size = .size_32x32,
    .color_mode = .bpp4,
    .entries = &large_dirt_map.SCREEN_ENTRIES,
};

// Check solid tile collision using generated masks
fn isTileSolid(tx: u16, ty: u16) bool {
    return large_dirt_map.isSolid(tx, ty);
}
```

---

## 6. Why [Zig](https://ziglang.org) & Zamgba?

GBA homebrew has traditionally relied on C/C++ toolchains like devkitARM. Zamgba chooses [Zig](https://ziglang.org) as its foundation for several compelling reasons:

1. **Modern Cross-Compilation Toolchain**: [Zig](https://ziglang.org) provides a self-contained, zero-dependency compiler that cross-compiles out of the box to `thumb-freestanding-eabi` (`arm7tdmi`), eliminating complex external toolchain setups.
2. **Type-Safe Hardware Registers**: [Zig](https://ziglang.org)'s `packed struct` and distinct integer types (`u1`, `u2`, `u5`, etc.) match GBA memory-mapped I/O (MMIO) registers bit-for-bit, providing compile-time type safety without cumbersome C bitmask macros.
3. **Zero-Cost Compile-Time Metaprogramming (`comptime`)**: Layout validation, ROM header generation, asset embedding, and math lookup tables are computed at compile time with zero runtime overhead.
4. **Predictable Bare-Metal Control**: [Zig](https://ziglang.org) does not have hidden control flow, runtime memory allocations, or a garbage collector. Every instruction and memory layout remains strictly under developer control, which is essential for constrained hardware with 384 KB of RAM.

### Zamgba Highlights
- **Type-Safe Hardware Abstraction (`zamgba.hal`)**: Directly maps GBA physical registers (MMIO), VRAM, PALRAM, and OAM into packed [Zig](https://ziglang.org) structs, eliminating unsafe pointer arithmetic and brittle C macros. Supports Graphics Modes 0 through 5 and hardware VBlank synchronization.
- **High-Level 2D Engine (`zamgba.engine`)**: Provides high-level game loop orchestration (`engine.run`), `StaticSprite` and `AnimatedSprite` entities, sub-pixel physics (`Fixed24_8`), and AABB collision detection.
- **Dynamic VRAM Streaming & DMA**: Features a dynamic VRAM tile allocator (`VramAllocator`) and VBlank DMA queue (`DmaQueue`) to stream multi-frame sprite animations seamlessly from ROM into VRAM without CPU copy stalls.
- **2D Camera & Parallax Scrolling**: Robust `Camera2D` supporting target tracking, lerp smoothing, deadzone margins, bounds clamping, screen shake, frustum culling, and multi-layer parallax scrolling.
- **Mode 0 TileMap Engine**: ScreenBlock management, packed 16-bit `ScreenEntry`, and continuous collision resolution against background tile layers (`moveAndCollide`).
- **Debugging & Diagnostics**: First-class mGBA debug register console logging (`zamgba.hal.mgba`), hardware `@panic` handler, and host-executable unit tests.

---

## 7. Architecture & Documentation Hub

Zamgba is engineered around a clean **2-Layer Architecture** that isolates raw hardware register manipulation from game-level logic:
- Low-Level Driver Layer (`zamgba.hal`)
- High-Level Framework Layer (`zamgba.engine`)

👉 **For an in-depth breakdown of memory layouts, register abstractions, and monomorphized run loops, read [docs/architecture.md](docs/architecture.md).**

Comprehensive architectural documents and guides are available in the [`docs/`](docs/) directory:

| Topic | Relevant Documents |
| :--- | :--- |
| **Overview & Design** | [docs/motivation.md](docs/motivation.md) • [docs/architecture.md](docs/architecture.md) • [docs/features.md](docs/features.md) |
| **Demos & Showcase** | [docs/demo.md](docs/demo.md) |
| **Graphics & TileMaps** | [docs/tilemap.md](docs/tilemap.md) • [docs/camera.md](docs/camera.md) • [docs/palette_and_sprite_loading.md](docs/palette_and_sprite_loading.md) |
| **Sprites & Memory** | [docs/sprite.md](docs/sprite.md) • [docs/vram_allocator.md](docs/vram_allocator.md) • [docs/tile_dma_queue.md](docs/tile_dma_queue.md) |
| **Physics & Math** | [docs/collision.md](docs/collision.md) • [docs/fixed_number.md](docs/fixed_number.md) |
| **Asset Pipeline** | [docs/tool_zurag_pic_conversion.md](docs/tool_zurag_pic_conversion.md) • [docs/png_decoder.md](docs/png_decoder.md) |
| **Hardware & Diagnostics** | [docs/compile.md](docs/compile.md) • [docs/irq_vblank.md](docs/irq_vblank.md) • [docs/debug_support.md](docs/debug_support.md) |

---

## 8. Milestones & Roadmap

- **Version 0.1.0** (2026-08-23): *Classic Pong & Core HAL*
  - [x] Responsive gamepad input polling
  - [x] Single-color square sprites and basic rendering
  - [x] AABB collision detection & kinematics (`pong.gba`)
- **Version 0.2.0** (2026-09-06): *Rich Sprites & Streaming Animation*
  - [x] Mode 0 tiled background & sprite mapping
  - [x] PNG and palette conversion CLI tool (`zurag`)
  - [x] Dynamic VRAM allocator (`VramAllocator`) and VBlank DMA queue (`DmaQueue`)
  - [x] High-performance streaming sprite animations (`flappy_tsetseg_streaming.gba`)
- **Version 0.3.1** (Current): *TileMaps, 2D Camera, & LDtk Pipeline*
  - [x] Mode 0 background TileMap engine (`ScreenEntry`, `TileSet`, `TileMapLayer`)
  - [x] Multi-layer parallax background scrolling (`parallax_scroll.gba`)
  - [x] 2D Camera system (`Camera2D`, smooth lerp, deadzone, screen shake, frustum culling)
  - [x] Continuous sub-pixel physics and tilemap collision (`moveAndCollide`)
  - [x] LDtk level editor import pipeline in `zurag` (`.ldtk` parser, IntGrid collision)
  - [x] True-color bitmap modes (Mode 3, 4, 5)
  - [x] mGBA debug register console logging and bare-metal panic handler
  - [x] Enforced 4-byte alignment for BIOS `irqHandler` preventing ARM-mode rotation crash ([#39](https://github.com/tsetseggames/zamgba/issues/39))
- **Version 0.3.1** (Current): Upgrade to [Zig](https://ziglang.org) **0.17.0** 
  - [x] Upgraded compiler toolchain to [Zig](https://ziglang.org) **0.17.0**
- **Version 0.4.0** (Next): *UI/HUD Layers & Sprite Priority*
  - [ ] Screen-space UI/HUD sprite rendering (`engine.drawSpriteUi`)
  - [ ] Sprite rendering priority control (`priority: u2` in OAM Attr2)
  - [ ] TileMap background layer depth priority
  - [ ] Bitmap Font typography & dialogue text box pipeline
  - [ ] Automated dynamic palette bank allocation (`PaletteAllocator`)
- **Version 0.5.0**: *Cartridge Save Data*
  - [ ] SRAM / Flash cartridge save state read and write API
- **Version 0.6.0**: *Chiptune Audio (PSG)*
  - [ ] Chiptune-to-code asset conversion tool (`duu`)
  - [ ] GBA PSG hardware sound channels (Tone, Sweep, Noise) playback
- **Version 0.7.0**: *Direct Audio (PCM)*
  - [ ] WAV/PCM audio conversion pipeline
  - [ ] DMA-driven Direct Audio PCM dual-channel playback
- **Version 0.8.0**: *Affine Transformations*
  - [ ] Fixed-point Sin/Cos trigonometric lookup table (LUT)
  - [ ] 32-slot OAM affine transformation matrix allocator
  - [ ] Sprite rotation and scaling API
- **Version 1.0.0**: *2D Platformer Engine Showcase*
  - [ ] Comprehensive platformer demo featuring physics, enemies, audio, and levels (*Tsetseg's Quest*)
- **Version 2.0.0**: *Pseudo-3D Engine*
  - [ ] Pseudo-3D raster rendering (Mode 7 style ground planes, raycasting)
- **Post-1.0.0**:
  - [ ] Dynamic multi-channel software audio mixer & real-time tracker module playback (`.xm`)

*For the complete design specifications of planned features, see [docs/features.md](docs/features.md).*

---

## 9. License, Copyright, and Legal Notice

### Legal Disclaimer
Zamgba is an independent, open-source homebrew development SDK and engine. It is **not** affiliated with, authorized, sponsored, or endorsed by Nintendo Co., Ltd. "Game Boy", "GBA", and "Game Boy Advance" are registered trademarks of Nintendo. Zamgba does not include any copyrighted Nintendo BIOS, SDK, or proprietary code; all hardware interfaces are clean-room implemented in [Zig](https://ziglang.org).

### Licensing
- **Source Code**: All library, engine, and build tooling code is open-source.
- **Art Assets (`assets/`)**: All game art assets, including sprite files and tilesets in `assets/`, are copyrighted works from the author's original game *["Tsetseg's Adventure"](https://store.steampowered.com/app/2337770/Tsetsegs_Adventure/)*. **All Rights Reserved.** You may use them locally to compile and run the demo ROMs provided in this repository, but you may not redistribute, modify, or use them in external commercial or open-source projects without explicit permission.
