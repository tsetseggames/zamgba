# Sprite Animation Tile Loading and Management

## 1. Input Format (Aseprite PNG + JSON)
Aseprite-exported Sprite Sheets (PNG) contain all pixel data, while the associated JSON (Array or Hash format, with Hash recommended for frame name indexing) contains slice coordinates for each frame (`frame`: `{x, y, w, h}`), animation durations (`duration`), and tags (`frameTags`).

## 2. Extracting Palettes from Aseprite PNG (16/256 Colors)
This is fully feasible without external tools, provided specific export settings are used:
* **Prerequisite**: The PNG must be exported from Aseprite using **Indexed** color mode (`Sprite -> Color Mode -> Indexed`), not RGB.
* **Technical Implementation**: Indexed PNG images contain a `PLTE` (Palette) data chunk.
  * The `PLTE` chunk stores colors sequentially: `R, G, B, R, G, B...`.
  * For 16-color palettes, the `PLTE` chunk is up to 48 bytes; for 256 colors, it is 768 bytes.
  * The GBA uses a 15-bit BGR555 color format. During parsing, read the RGB values from `PLTE` and convert them using the formula: `color = (R >> 3) | ((G >> 3) << 5) | ((B >> 3) << 10)`.

## 3. Direct Conversion from PNG+JSON to Zig
This is highly practical and aligns with Zig's build philosophy. A dedicated build-time tool can be written in pure Zig within the `zamgba` project.
* **JSON Parsing**: Use Zig's standard library `std.json` to parse the Aseprite JSON.
* **PNG Parsing**: Zig includes `std.compress.flate` (Zlib/Deflate decompression), allowing for a minimalist custom PNG parser:
  1. Parse the PNG header signature.
  2. Extract the `PLTE` chunk (convert palette to GBA format).
  3. Extract and concatenate all `IDAT` chunks, then decompress them using `std.compress.flate` to get the raw pixel indices.
  4. Extract the `tRNS` chunk (optional, handles transparency if index 0 is transparent).
* **Conversion to Zig**:
  * Using coordinates from the JSON, extract the corresponding 8x8 pixel blocks (Tiles) from the decompressed matrix (stored linearly: 4-bit per pixel for 16-color, 8-bit for 256-color).
  * Format the converted Tile arrays and animation metadata via `std.fmt` and output them to a `.zig` file.
* **Build Integration**: In `build.zig`, compile this tool via `b.addExecutable` and run it via `b.addRunArtifact` before compiling the ROM. Add the output `.zig` file as a module to the final build.

## 4. Cache Buffer Design for Fast Tile Switching
The GBA's OBJ VRAM is limited to 32KB (Character Blocks 4 and 5). It is impossible to load all animation frames for all sprites simultaneously.
* **OAM Index Switching (Fastest, Small Sprites)**:
  If a character's total animation set is small, load all frames into VRAM during level initialization. To animate, simply update the **Tile Index** in OAM Attribute 2. No memory copying is required during gameplay.
* **VRAM Slot Caching (Large/Complex Sprites)**:
  Design a VRAM Allocator.
  1. Partition the OBJ VRAM into fixed-size slots (e.g., 16x16, 32x32, or simply 8x8 tile granularity).
  2. When a sprite is spawned, allocate a VRAM slot for it.
  3. The sprite's OAM Tile Index always points to this fixed VRAM slot.
  4. **On Frame Switch**: When the animation advances, do not change the OAM Tile Index. Instead, copy the new frame's tile data from ROM into the allocated VRAM slot.

## 5. Streaming Sprite Loading Design
Combined with the VRAM Slot Cache, streaming avoids blocking the CPU with massive data copies during the active drawing period. It relies on hardware DMA and VBlank periods.

**Architecture**:
1. **DMA Transfer Queue**:
   Maintain a global queue for pending memory transfer tasks.
   ```zig
   const TransferTask = struct {
       src: [*]const u8,   // Address of new tile data in ROM
       dest: [*]u8,        // Target VRAM slot address
       words: u16,         // Number of 32-bit words to transfer
   };
   ```
2. **Game Loop (Logic Phase)**:
   * Iterate over all active sprites.
   * Update animation timers.
   * If a frame switch occurs, do not copy memory immediately. Calculate the ROM source and VRAM destination addresses, and push a new task to the DMA Queue.
3. **VBlank Phase (Hardware Interrupt/Wait)**:
   * Upon entering VBlank (when VRAM writes are fastest and do not cause tearing), execute the transfers.
   * Pop all tasks from the DMA Queue and stream data from ROM to VRAM using **DMA3** (32-bit transfer mode).
   * Clear the queue.

This "queue in logic -> transfer in VBlank via DMA" pipeline is the standard best practice for managing 2D sprite streaming on the GBA.

## 6. Detailed Implementation of the Conversion Tool

To achieve a dependency-free conversion pipeline, the tool will rely entirely on Zig's standard library and build system capabilities.

### Zero-Dependency Parsing
* **PNG Parsing**: The PNG format consists of chunks (Length, Type, Data, CRC). By using `std.mem.readInt`, the tool will parse the basic structure and extract the `IHDR` (dimensions/depth), `PLTE` (palette), and `IDAT` (pixel data) chunks. All `IDAT` payloads will be concatenated and decompressed directly using Zig's built-in `std.compress.flate` or `zlib` API.
* **JSON Parsing**: Zig's `std.json.parseFromSlice` will be used alongside strongly-typed structs (e.g., `Rect`, `Frame`) that mirror Aseprite's schema. This instantly converts the JSON text into memory structures without any manual string parsing.

### Code Generation: Sprite vs. Map
The tool will use file writers to output valid Zig source code (`pub const tiles = [_]u8{...};`), but the conversion logic differs based on the target layer:
* **Sprite (OBJ)**: Extracts pixels corresponding to the slice rectangles defined in the JSON, packing them strictly into linear 8x8 tile blocks (4-bit for 16-color, 8-bit for 256-color).
* **Map (BG)**: Scans the entire background image, slices it into 8x8 tiles, and performs **deduplication**. Unique tiles are written to a *Tile Data* array (Character Block), while a *Map Data* grid (Screen Block) is generated holding the indices, flip flags, and palette banks for each cell.

### Dual-Workflow Build System Integration
The Zig build system (`build.zig`) will be configured to serve two distinct workflows using the exact same codebase:
1. **Standalone Executable (Testing/Debugging)**: The tool is compiled for the host OS target using `b.addExecutable` and exposed via a dedicated build step (e.g., `zig build tools`). This outputs an executable in `zig-out/bin/` allowing developers to test the conversion logic manually.
2. **Implicit Build Step (ROM Compilation)**: Using `b.addRunArtifact`, the tool acts as a transparent, automated step during the standard `zig build` process. It takes the PNG and JSON as input arguments, outputs a generated `.zig` file via `addOutputFileArg`, and transforms it into a module (`b.createModule`). This module is then seamlessly injected into the final `arm7tdmi` GBA ROM build.

## 7. VRAM Management Strategy: Bitwise Buddy Allocator

To support both static and dynamically streaming sprites without severe memory fragmentation, `zamgba` implements a highly optimized **Bitwise Buddy Allocator** for VRAM management.

### Architectural Decision: 1D vs. 2D OBJ Mapping
To implement a dynamic allocator, the GBA display control register (`REG_DISPCNT`) **must be configured to use 1D OBJ Mapping**. 

Historically, **2D Mapping** was preferred in the manual-coding era because it is artist-friendly: VRAM acts as a 256x256 pixel canvas. Inspecting it in an emulator shows the exact Sprite Sheet the artist drew (WYSIWYG). However, this forces the engine to solve a complex 2D packing problem ("Tetris") during runtime to allocate memory, making dynamic allocation prohibitively difficult and prone to fragmentation.

Under **1D Mapping**, VRAM is treated as a continuous, flat 1D array of tiles. A 16x16 sprite (which visually forms a 2x2 grid) is "flattened" into a linear array of 4 consecutive tiles. While this looks scrambled and unintuitive in a VRAM viewer, it turns VRAM allocation into a standard 1D memory allocation problem, which perfectly suits the Buddy Allocator.

**The zamgba Pipeline Resolution**: In a modern engine pipeline, artists should not care about VRAM layouts. 
* Artists work exclusively in Aseprite with standard 2D workflows. 
* The build-time tool (`ase2gba.zig`) automatically slices and "flattens" the 2D PNG into the 1D arrays required by the hardware. 
* The engine dynamically streams these 1D arrays into VRAM via the Buddy Allocator. 
This grants the best of both worlds: a modern, unconstrained workflow for artists, and a highly efficient, linear VRAM allocator for the engine.

### Why the Buddy Allocator is the Perfect Fit
* **Size Alignment**: The GBA OBJ VRAM has 32KB of space. A single 4-bpp tile is 32 bytes, yielding exactly **1024 tiles**.
* **Power of 2**: GBA hardware sprite dimensions directly map to power-of-2 tile requirements: 8x8 (1 tile), 16x16 (4 tiles), 32x32 (16 tiles), and 64x64 (64 tiles). The Buddy algorithm intrinsically partitions memory into $2^N$ blocks, perfectly mirroring the hardware's demands.

### Data Structure and Performance (Zero-Pointer Design)
Traditional Buddy allocators use linked lists and pointers, which are slow and bloated. The `zamgba` implementation will be specifically tailored for the GBA:
* **Bit-Tree**: The entire allocation state is maintained using a flat binary tree stored as an array of bits (e.g., using Zig's `u32` integers as bitmasks). 
* **High Performance**: Memory overhead is negligible (a few dozen bytes). Finding a free block or its buddy uses fast bitwise math (such as Zig's `@clz` - count leading zeros), allowing allocations to resolve in minimal CPU cycles.
* **No Dynamic Memory**: All structures reside in static `.bss` memory.

### Integration with Streaming
When a sprite is created, it requests a block of $2^N$ tiles from the Buddy Allocator. 
* The allocator returns a hardware VRAM index, which is written to the sprite's OAM.
* For **streaming animations**, this allocated VRAM slot remains unchanged. The DMA transfer queue (described in Section 5) simply overwrites the memory inside this slot during VBlank.
* Upon sprite destruction, the slot is freed. If its "buddy" slot is also free, the allocator automatically merges them back into a larger block, effectively preventing fragmentation over the game's lifecycle.
