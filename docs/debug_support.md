# GBA Debug & Diagnostic Support Design (Target: v0.3.0)

This document details the architectural design, performance guards, and implementation plan for the Zamgba Debug and Logging subsystem (`engine.log` and `hal.mgba.log`). It also analyzes the font rendering requirements, copyright-free assets, industry-standard practices from Tonc and Butano, and incorporates learnings from bare-metal optimization pitfalls (see [Case Study: Undefined Behavior & Release Mode Divergence](zig_unreachable_case_study.md)).

---

## 1. Motivation: Why Debug Support is v0.3.0's Priority #1

As demonstrated in [Issue #32](https://github.com/tsetseggames/zamgba/issues/32) and detailed in [docs/zig_unreachable_case_study.md](zig_unreachable_case_study.md), bare-metal GBA games have no default standard output or operating system console. When a runtime error or `catch unreachable` is triggered:
- `ReleaseFast` may crash silently into a black screen via dead-code elimination or ARM traps.
- `ReleaseSmall` may mask the error and produce deceiving behavior.
- Developers are left guessing whether the cause is math, DMA, physics, memory alignment, or register corruption.

The primary objective of the **v0.3.0 Debug Subsystem** is to provide instant, zero-cost error reporting, stack-safe assertions, visual panic indicators, and real-time VRAM/DMA diagnostics.

---

## 2. The Core Philosophy: Two Debugging Channels

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
- Primary target for v0.3.0                                   - Recommended for target hardware/TV testing
```

---

## 3. Channel 1: Host Simulator Console Logging (v0.3.0 Primary Target)

### A. How It Works (The MMIO Emulator Loophole)
Modern GBA emulators (specifically **mGBA** and **No$GBA**) intercept reads and writes to unmapped/unused hardware I/O address ranges.
- **mGBA Debug Protocol**:
  - `REG_DEBUG_ENABLE` (`0x04FFF780`): Handshake register. Writing `0xC0DE` enables debugging; the emulator responds with `0x1EA0`.
  - `REG_DEBUG_FLAGS` (`0x04FFF700`): Writing `0x0100 | LogLevel` flushes the buffered message to the console.
  - `REG_DEBUG_STRING` (`0x04FFF600`): Null-terminated ASCII character buffer (up to 255 characters).
- Writing ASCII characters to these registers routes the text directly to the PC host terminal.
- It consumes **zero GBA VRAM** and uses the PC host operating system's native console fonts, eliminating any GBA font asset or licensing requirements.
- On real hardware, these writes are ignored by the memory controller, incurring practically zero overhead.

### B. Performance, Memory Safety, and Footprint Guard (The Zero-Cost Guarantee)
To protect GBA IWRAM stack space and ensure formatted print strings do not drag down CPU frame rates or inflate binary sizes, the subsystem adopts a **Module-level Static 80-byte Buffer** and enforces **Compile-time Elimination**:

```zig
const BUFFER_SIZE: usize = 80;

var format_buf: if (builtin.mode == .Debug) [BUFFER_SIZE]u8 else void =
    if (builtin.mode == .Debug) undefined else {};

pub fn log(comptime level: LogLevel, comptime fmt: []const u8, args: anytype) void {
    if (comptime builtin.mode != .Debug) return; // Completely stripped by compiler in non-Debug builds
    const formatted = formatToBuf(&format_buf, fmt, args);
    write(level, formatted);
}
```

> [!IMPORTANT]
> **80-Character Buffer Restriction & IWRAM Stack Protection**:
> - **Zero Stack Overhead**: GBA IWRAM stack space is extremely limited (~32 KB total). Allocating formatting buffers on the call stack inside deeply nested game logic risks silent stack overflows. Zamgba uses a single, module-level static buffer conditionally compiled strictly in Debug mode (0 bytes in Release).
> - **80-Character Max Length**: Single log messages are bounded to 80 characters (standard terminal width). Longer strings will be safely truncated at the 79th character with trailing null termination.

In `ReleaseFast` or `ReleaseSmall` builds, all debug formatting, log statements, and static buffers are completely eliminated at compile time from the output binary, ensuring **0 bytes of ROM/RAM** and **0 cycles of CPU overhead** in production.

In addition, during unit tests (`builtin.is_test`), hardware MMIO access is disabled at compile time (`comptime !specs.is_gba_target`), ensuring host-side test runner safety and silent execution by default.

### C. Running mGBA with Log Output Enabled
By default, mGBA filters out non-critical console logs. To capture engine logs on stdout, run mGBA with the `-l` (`--log-level`) option:

```bash
# Enable all log levels (Mask 31 = FATAL(1) | ERROR(2) | WARN(4) | INFO(8) | DEBUG(16))
mgba -l 31 --scale 4 ./zig-out/bin/flappy_tsetseg_streaming.gba
```

> [!NOTE]
> - **Decimal Integer Parameter**: mGBA's CLI argument parser strictly requires **decimal** integer values for `-l` / `--log-level` (e.g. `31`). Hexadecimal formats (such as `0x1F`) are not parsed properly and will silently result in zero log output.
> - **Emulator Internal Diagnostics**: When log level mask `31` is enabled, mGBA will also output its own internal hardware trace logs (e.g., `GBA DMA: Starting DMA 3 ...`) alongside Zamgba application logs.

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

## 5. Subsystem Implementation Plan for v0.3.0

We will implement the debugging subsystem in two tightly scoped phases:

### Phase 1: Emulator Debug Port Driver & Logging (`src/hal/mgba/log.zig` and `src/engine/log.zig`)
* **HAL Layer (`src/hal/mgba/log.zig`)**:
  - Handshake (`init() bool`, `isSupported() bool`) via `0x04FFF780`.
  - Atomic write routines to mGBA registers (`0x04FFF600`, `0x04FFF700`).
  - Supported log levels: `fatal`, `err`, `warn`, `info`, `debug`.
  - Compile-time target guard (`comptime !specs.is_gba_target`) ensuring host test safety and 0-overhead on GBA.
* **Engine Layer (`src/engine/log.zig`)**:
  - Ergonomic high-level API: `debug()`, `info()`, `warn()`, `err()`, `fatal()`, `print()`, `log()`.
  - Static 80-byte formatting buffer (preventing IWRAM stack bloat) utilizing `std.fmt.bufPrint` with safe null termination and truncation.
  - Compile-time stripping in non-Debug builds (`builtin.mode != .Debug`).
* **Visual Panic Hook**: In case of unhandled initialization error, flush the error message to mGBA log and turn backdrop color red (`RGB555(31, 0, 0)`), preventing silent black-screen hangs.

### Phase 2: Engine Diagnostics Dispatcher (`src/engine/debug.zig`)
* **`engine.debug.dumpVramMap()`**:
  Query the global `VramAllocator` singleton and output an ASCII map showing active sprite tile slices, free buddy tree levels, and memory fragmentation.
* **`engine.debug.dumpDmaStats()`**:
  Query the global `DmaQueue` singleton and print current frame task count, staged bytes, peak bandwidth, and safety headroom.
* **`engine.debug.dumpActiveSprites()`**:
  Dump all current frame registered sprites, their VRAM indices, Bpp depth, and animation modes (`streaming` vs. `static`).

---

## 6. Developer Diagnostic Report Example

When a developer triggers a dump (e.g. by pressing `Select`), the mGBA Terminal Console will output:

```text
=== [Zamgba Engine 0.3.0 Debug Diagnostics] ===
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
