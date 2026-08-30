# Zurag: Aseprite Image & Animation Converter for GBA

`zurag` (*Mongolian for "picture"*, pronounced */zu.rɐɢ/*) is a dedicated, zero-dependency asset conversion CLI tool built into the Zamgba toolchain. It converts Aseprite-exported Indexed-color PNG sprite sheets and JSON metadata into optimized, type-safe Zig source code ready for compilation into GBA ROMs.

---

## 1. Overview & Purpose

GBA hardware requires image data to be structured in specific formats:
* **Palette Data**: 15-bit BGR555 colors packed into 16-bit integers (`[16]u16` or `[256]u16`).
* **Tile Data**: 8x8 pixel blocks stored linearly in either 4-bpp (32 bytes/tile) or 8-bpp (64 bytes/tile) format.
* **Sprite Mapping**: 1D linear mapping for dynamic VRAM allocation.

`zurag` bridges the gap between modern pixel art workflows (Aseprite) and GBA hardware constraints entirely in pure Zig without external dependencies (such as Python, ImageMagick, or Node.js).

---

## 2. Command-Line Interface (CLI)

### Syntax
```bash
zurag --png <input.png> [--json <input.json>] [--output <output.zig>] [options]
zurag -h | --help
```

### Options

| Option | Short | Description | Default |
| :--- | :--- | :--- | :--- |
| `--png <path>` | `-p` | Path to the input Indexed-color PNG sprite sheet (exported from Aseprite). **Required**. | *None* |
| `--json <path>` | `-j` | Path to the input Aseprite JSON frame metadata. Required unless `--palette-only` is set. | *None* |
| `--output <path>`| `-o` | Path to write the generated Zig source file. If omitted, outputs to `stdout`. | `stdout` |
| `--bpp <mode>` | | Bits-per-pixel color mode: `4`, `4x16`, `8`, `auto`. | `auto` |
| `--color-adjust`| `-c` | Enable full-range rounded RGB to GBA BGR555 color scaling: `(c * 31 + 127) / 255`. | `false` |
| `--palette-only`| `-P` | Extract palette data only. Skips tile/frame conversion; `--json` is not required. | `false` |
| `--no-palette`  | `-N` | Omit palette definition in generated sprite code (for external shared master palettes). | `false` |
| `--help` | `-h` | Display usage and help message to `stdout`. | |

*Note: Command-line options may be passed in any order.*

---

## 3. Color Depth & Palette Modes (`--bpp`)

GBA OBJ Palette RAM (`0x05000200`) provides 512 bytes for up to 256 colors. `zurag` supports three core color modes:

### A. Single 16-Color Mode (`--bpp 4`)
* **Usage**: Standard 4-bpp sprites (characters, bullets, small enemies).
* **Palette**: Produces a single `[16]u16` BGR555 palette. Missing entries are padded with `0x0000`.
* **Validation**: Errors out immediately if the image contains more than 16 colors.

### B. 16-Bank 4-Bpp Mode (`--bpp 4x16`)
* **Usage**: Allows a single 256-color master PNG to contain sprites belonging to 16 distinct 16-color palette banks (e.g., character color variations, different enemy types, UI).
* **Palette**: Generates 16 banks of 16 colors (`[16][16]u16`) or a flat `[256]u16` table.
* **Pixel Re-indexing**: Tile pixels are automatically folded via `pixel % 16` to 4-bit values.
* **Bank Attribution**: The recommended OAM palette bank (`pixel / 16`) is recorded per animation frame.
* **Validation**: Errors out if any individual sprite frame uses colors from multiple palette banks.

### C. 256-Color Mode (`--bpp 8`)
* **Usage**: 8-bpp sprites (large bosses, full-screen graphics, detailed illustrations).
* **Palette**: Produces a full `[256]u16` BGR555 palette.
* **Tile Memory**: 64 bytes per 8x8 tile.

### D. Auto-Detection (`--bpp auto`)
* Evaluates the maximum used color index across the image:
  * Uses $\le 16$ colors $\rightarrow$ automatically chooses `4`.
  * Uses $> 16$ colors $\rightarrow$ automatically chooses `8`.

---

## 4. Palette-Only Mode (`--palette-only`)

When `--palette-only` (`-P`) is specified:
* `zurag` parses the PNG's `PLTE` chunk and converts it to GBA BGR555 colors.
* No sprite slicing or tile packing occurs.
* `--json` is **not** required.
* **Use Cases**: Global master palettes, dynamic palette swapping (damage flash, poisoned state, day/night cycles), and palette cycling effects.

---

## 5. Build System Integration (`build.zig`)

`zurag` is integrated into the Zamgba build graph as a native host executable. It serves two workflows:

```zig
// In build.zig
const host_target = b.standardTargetOptions(.{});
const optimize = b.standardOptimizeOption(.{});

// 1. Compile zurag for the host machine
const zurag_exe = b.addExecutable(.{
    .name = "zurag",
    .root_module = b.createModule(.{
        .root_source_file = b.path("tools/zurag/main.zig"),
        .target = host_target,
        .optimize = optimize,
    }),
});

// Expose as an installable standalone binary in zig-out/bin/zurag
b.installArtifact(zurag_exe);

// 2. Automate sprite conversion as an implicit build step for ROM compilation
const convert_player_sprite = b.addRunArtifact(zurag_exe);
convert_player_sprite.addArgs(&.{ "--bpp", "4" });
convert_player_sprite.addArg("--png");
convert_player_sprite.addFileArg(b.path("assets/player.png"));
convert_player_sprite.addArg("--json");
convert_player_sprite.addFileArg(b.path("assets/player.json"));
convert_player_sprite.addArg("--output");
const player_sprite_zig = convert_player_sprite.addOutputFileArg("player_sprite.zig");

// 3. Inject generated Zig code into the GBA ROM module
const player_sprite_mod = b.createModule(.{
    .root_source_file = player_sprite_zig,
});
rom_exe.root_module.addImport("player_sprite", player_sprite_mod);
```

### Build Caching & Concurrency
* **Automatic Cache Invalidation**: Zig automatically hashes `assets/player.png` and `assets/player.json`. If neither file changes, `zurag` will not be re-executed.
* **Parallel Execution**: Multiple `RunArtifact` steps execute concurrently across available CPU cores.

---

## 6. Slicing Architecture & Metadata Adapter Pattern

`zurag` strictly decouples file parsing from image transformations using an **Adapter Pattern** with a unified domain model (`SpriteMetadata`):

```
┌─────────────────────────────────┐     ┌──────────────────────────────────┐
│       Aseprite JSON File        │     │      Other Pixel Editors         │
│     (Hash or Array Schema)      │     │  (e.g., Pixelorama / Tiled / ...)│
└────────────────┬────────────────┘     └────────────────┬─────────────────┘
                 │                                       │
                 ▼                                       ▼
┌─────────────────────────────────┐     ┌──────────────────────────────────┐
│      Aseprite JSON Adapter      │     │     Future Software Adapters     │
└────────────────┬────────────────┘     └────────────────┬─────────────────┘
                 │                                       │
                 └───────────────────┬───────────────────┘
                                     │ Normalizes into unified model
                                     ▼
                      ===============================
                      │       SpriteMetadata        │
                      │  ([]Frame, []Tag, direction)│
                      ===============================
                                     │
                                     │ Slice Coordinates (Rect{ x, y, w, h })
                                     ▼
┌─────────────────────────────────┐     ┌──────────────────────────────────┐
│       IndexedImage (2D)         │ ──> │ sliceSpriteFrame (Image Slicer)  │
│  (Decompressed & Unfiltered)    │     └────────────────┬─────────────────┘
└─────────────────────────────────┘                      │ 1D Tile Byte Streams
                                                         ▼
                                        ┌──────────────────────────────────┐
                                        │          Code Generator          │
                                        │ (Combines Palettes, Tiles, Tags) │
                                        └──────────────────────────────────┘
```

### Pipeline Responsibilities:
1. **Metadata Adapter Pipeline (`json.zig`)**:
   * **Unified Domain Model (`SpriteMetadata`)**: Decouples the engine and image slicer from specific pixel editor schemas. Contains normalized `[]Frame` (`Rect` + `duration_ms`) and `[]Tag` (`name`, `from`, `to`, `direction`).
   * **Adapter Dispatcher (`parseMetadata`)**: Probes JSON content to auto-detect software origins (e.g. Aseprite `"meta"`/`"frames"` keys) and delegates to the appropriate format adapter.
   * **Aseprite Adapter (`parseAsepriteJson`)**: Handles both Aseprite's Hash format (`"frames": { ... }`) and Array format (`"frames": [ ... ]`).
2. **Image Slicer (`sliceSpriteFrame` in `tile.zig`)**:
   * Operates purely on raw `IndexedImage` pixels and a `Rect` without coupling to JSON formats.
   * Enforces GBA hardware alignment: width and height must be non-zero multiples of 8x8 tiles (`hal.oam.Tile.WIDTH_PIXELS` and `HEIGHT_PIXELS`).
   * Slices 2D rectangular areas into 1D row-major 8x8 tile sequences.
   * Packs pixels using `packTile4bpp` (32 bytes/tile, `% 16` modulo folding with lower/upper nibble packing) or `packTile8bpp` (64 bytes/tile).
   * Validates color bank consistency for 4-bpp frames, detecting and rejecting `error.MultiBankColorConflict`.
3. **Code Generator (`main.zig`)**:
   * Emits type-safe Zig source code adhering to the `zamgba-engine` data contract (`engine.SpriteSheet`).

---

## 7. Sprite Generation Workflows

`zurag` supports two primary artist-to-engine workflows to fit different project scales:

### Workflow A: Self-Contained Standalone Sprite
* **Best For**: Isolated particles, standalone UI elements, interactive tech demos, and quick prototyping.
* **Characteristics**: Every sprite file includes its own self-contained palette, tile stream, duration list, and `SpriteSheet` contract.
* **CLI Command**:
  ```bash
  zurag --png player.png --json player.json --bpp 4 --output player.zig
  ```
* **Runtime Usage**:
  ```zig
  const player = @import("player.zig");
  // Load self-contained palette into OBJ Palette Bank 0
  hal.dma.copy16(&player.palette, &PALRAM_OBJ[0], player.palette.len);
  ```

---

### Workflow B: Shared Master Palette (Production Standard)
* **Best For**: Large-scale retro productions sharing a global 256-color palette (16 banks of 16 colors), palette swapping (1P vs 2P variations, damage flashes, elemental recolors), and minimizing ROM duplication.
* **Characteristics**: The global master palette is compiled once. Individual character sprites are compiled with `--no-palette` (`-N`) to strip duplicate palette data and prevent ROM bloat.
* **Step 1 — Compile Master Palette (`--palette-only`)**:
  ```bash
  zurag --png master_palette.png --palette-only --bpp 4x16 --output master_palette.zig
  ```
* **Step 2 — Compile Individual Sprites (`--no-palette`)**:
  ```bash
  zurag --png hero.png --json hero.json --bpp 4x16 --no-palette --output hero.zig
  zurag --png enemy.png --json enemy.json --bpp 4x16 --no-palette --output enemy.zig
  ```
* **Runtime Usage**:
  ```zig
  const master_pal = @import("master_palette.zig");
  const hero = @import("hero.zig");
  const enemy = @import("enemy.zig");

  // Load global 256-color palette once at scene startup via DMA
  hal.dma.copy16(&master_pal.raw_palette, PALRAM_OBJ, 256);

  // Render hero using Bank 0, enemy using Bank 1 (zero extra palette ROM overhead!)
  ```
