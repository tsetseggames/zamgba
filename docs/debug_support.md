# GBA Debug & Diagnostic Support Design

This document details the architectural design, performance guards, and implementation plan for the Zamgba Debug and Logging subsystem (`engine.debug` and `hal.debug`). It also analyzes the font rendering requirements, copyright-free assets, and industry-standard practices from Tonc and Butano.

---

## 1. The Core Philosophy: Two Debugging Channels

GBA has no operating system console, but we can divide debug requirements into two distinct channels based on the use case:

```
                  ┌─────────────────────────────────────────┐
                  │          Zamgba Debug Subsystem         │
                  └────────────────────┬────────────────────┘
                                       │
         ┌─────────────────────────────┴─────────────────────────────┐
         ▼                                                           ▼
【Channel 1: Host Emulator Log】                             【Channel 2: On-Screen Display】
- mGBA / No$GBA Terminal Console                              - Screen Overlay (OSD HUD Text)
- ZERO GBA VRAM footprint                                     - Uses BG/OBJ VRAM tiles
- ZERO copyright / font design overhead                       - Requires a 1-bit or 4-bpp pixel font
- Primary target for 0.2.0-dev                                - Recommended for target hardware/TV testing
```

---

## 2. Channel 1: Host Simulator Console Logging (0.2.0-dev Focus)

### A. How It Works (The MMIO Emulator Loophole)
Modern GBA emulators (specifically **mGBA** and **No$GBA**) intercept reads and writes to unmapped/unused hardware I/O address ranges. 
- Writing ASCII characters to a specific register (mGBA: `0x04FFF780`, No$GBA: `0x04FFFEF0`) routes the text directly to the PC host terminal.
- It consumes **zero GBA VRAM** and uses the PC host operating system's native console fonts, eliminating any GBA font asset or licensing requirements.
- On real hardware, these writes are ignored by the memory controller, incurring practically zero overhead.

### B. Performance and Footprint Guard (The Zero-Cost Guarantee)
To ensure formatted print strings do not drag down GBA CPU frame rates, the subsystem enforces the **Release-Mode Erasure** rule:
```zig
pub fn print(comptime fmt: []const u8, args: anytype) void {
    if (builtin.mode != .Debug) return; // Completely stripped by compiler in Release
    // Runtime comptime formatting to stack buffer...
}
```
In `ReleaseFast` or `ReleaseSmall` builds, all debug formatting and log statements are completely eliminated from the output binary, ensuring **0 bytes of ROM** and **0 cycles of CPU overhead** in production.

---

## 3. Channel 2: On-Screen Text Display & Pixel Font Design

If a game needs to display debugging information directly on target GBA hardware, a pixel font is required to draw alphanumeric characters on the screen.

### A. Prior Art: How Tonc and Butano Do It
1. **`libtonc` (Tonc Text Engine - TTE)**:
   - embeds a default, simple **8x8 monochrome pixel font** directly inside the library as a static array of raw bits (1 bit per pixel).
   - The engine unpacks this 1bpp font at runtime to 4-bpp tiles and writes them directly to BG Map screen entries or Sprite VRAM.
   - Tonc’s default font is completely **public domain** (copyright-free).
2. **`Butano` (Modern C++ Engine)**:
   - Does not embed a font directly to avoid bloat. Instead, it provides a `bn::sprite_text_generator`.
   - It expects developers to import an **Aseprite PNG sprite sheet** containing ASCII glyphs. The build system converts this PNG into standard GBA 1D tiles, and the runtime generator maps ASCII characters to VRAM tile offsets:
     $$\text{vram\_tile\_index} = \text{character\_ascii\_code} - 32$$

### B. Copyright-Free Font Strategy for Zamgba
To eliminate any legal, licensing, or design hurdles, developers can choose one of three approaches:

1. **Own Custom-Designed PNG Font (No Copyright Risks)**:
   - You can easily draw your own 8x8 font in Aseprite. A standard ASCII set (char 32 'Space' to char 126 '~' = 95 characters) fits perfectly onto a **128x48 pixel PNG**.
   - Your custom sheet can be routed directly through `zurag` to generate a standard static `SpriteSheet` module.
2. **Public Domain / CC0 Open-Source Fonts**:
   - There are numerous high-quality, completely public domain pixel fonts available (such as *IBM PC BIOS Font*, *Unscii*, or Tonc's system font).
   - We can package a default CC0 8x8 monochrome font directly in `src/engine/debug_font.zig` as static byte tables, similar to libtonc.

---

## 4. Subsystem Implementation Plan for 0.2.0-dev

We will implement the debugging subsystem in two tightly scoped phases:

### Phase 1: Emulator Debug Port Driver (`src/hal/debug.zig`)
* Atomic, unsafe-free write routines to mGBA registers.
* Support for basic logging levels: `debug`, `info`, `warn`, `err`.
* Stack-only, fixed-size buffering (`[256]u8`) utilizing `std.fmt.format` to avoid heap allocations.

### Phase 2: Engine Diagnostics Dispatcher (`src/engine/debug.zig`)
* **`engine.debug.dumpVramMap()`**:
  Query the global `VramAllocator` singleton and output an ASCII map showing active sprite tile slices, free buddy tree levels, and memory fragmentation.
* **`engine.debug.dumpDmaStats()`**:
  Query the global `DmaQueue` singleton and print current frame task count, staged bytes, peak bandwidth, and safety headroom.
* **`engine.debug.dumpActiveSprites()`**:
  Dump all current frame registered sprites, their VRAM indices, Bpp depth, and animation modes (`streaming` vs. `static`).

---

## 5. Developer Diagnostic Report Example

When a developer triggers a dump (e.g. by pressing `Select`), the mGBA Terminal Console will output:

```text
=== [Zamgba Engine 0.2.0 Debug Diagnostics] ===
[VRAM Tiles]: 36 / 1024 slots (3.5% used, 988 free slots)
[DMA Budget]: 1024 / 4096 bytes (1 task, Peak: 1024 bytes)

[Active Resident Sprites]:
  #0 [Player]  tile_index: 0   (32x32, 8bpp, 32 units, mode: STREAMING)
  #1 [Enemy1]  tile_index: 256 (16x32, 4bpp, 2 units,  mode: STATIC)
  #2 [Enemy2]  tile_index: 256 (16x32, 4bpp, 2 units,  mode: STATIC)

[Buddy Allocator Free Lists]:
  Order 10 (1024 tiles): [0] (Split)
  Order 9  (512 tiles) : [512] (Free)
  Order 8  (256 tiles) : [256] (Free)
  Order 5  (32 tiles)  : [32]  (Allocated to Player)
==============================================
```
