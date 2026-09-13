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
  - `REG_DEBUG_ENABLE` (`0x04FFF780`): Handshake register. Writing `0xC0DE` ("CODE") enables debugging; the emulator responds with `0x1DEA` ("IDEA").
  - `REG_DEBUG_FLAGS` (`0x04FFF700`): Writing `0x0100 | LogLevel` flushes the buffered message to the console.
  - `REG_DEBUG_STRING` (`0x04FFF600`): Null-terminated ASCII character buffer (up to 255 characters).
- Writing ASCII characters to these registers routes the text directly to the PC host terminal.
- It consumes **zero GBA VRAM** and uses the PC host operating system's native console fonts, eliminating any GBA font asset or licensing requirements.
- On real hardware, these writes are ignored by the memory controller, incurring practically zero overhead.

#### Handshake Verification (`0xC0DE` -> `0x1DEA` "CODE" / "IDEA")
The mGBA debug interface uses the Hexspeak magic pair `0xC0DE` / `0x1DEA`:
- Handshake activation: `REG_DEBUG_ENABLE.* = 0xC0DE`
- Response verification: `REG_DEBUG_ENABLE.* == 0x1DEA`
- In Zamgba:
  - `hal.mgba.log.init()` performs the handshake write.
  - `hal.mgba.log.isRunOnMgba() bool` checks if the response magic matches `0x1DEA`.
  - `hal.mgba.log.write()` performs direct MMIO writes without per-message handshake polling, ensuring maximum logging throughput.

### B. Performance, Memory Safety, and Footprint Guard (The Zero-Cost Guarantee)
To protect GBA IWRAM stack space and ensure formatted print strings do not drag down CPU frame rates or inflate binary sizes, the subsystem adopts a **Module-level Static 128-byte Buffer** in the HAL layer (`hal.mgba.log.format_buf`), shared between `engine.log` and the bare-metal `panic` handler, while enforcing **Compile-time Elimination**:

```zig
// Defined in src/hal/mgba/log.zig
pub const BUFFER_SIZE: usize = 128;
pub var format_buf: [BUFFER_SIZE]u8 = undefined;

// In src/engine/log.zig:
pub fn log(comptime level: LogLevel, comptime fmt: []const u8, args: anytype) void {
    if (comptime builtin.mode != .Debug) return; // Completely stripped by compiler in non-Debug builds
    const formatted = formatToBuf(&hal.mgba.log.format_buf, fmt, args);
    write(level, formatted);
}
```

> [!IMPORTANT]
> **128-Character Buffer Restriction & IWRAM Stack Protection**:
> - **Zero Stack Overhead**: GBA IWRAM stack space is extremely limited (~32 KB total). Allocating formatting buffers on the call stack inside deeply nested game logic or during a critical stack-overflow panic risks silent faults. Zamgba uses a single, module-level static buffer in the HAL layer (`hal.mgba.log.format_buf`), shared safely across single-threaded execution and panic recovery.
> - **128-Character Max Length**: Single log/panic messages are bounded to 128 characters. Longer strings will be safely truncated at the 127th character with trailing null termination.

In `ReleaseFast` or `ReleaseSmall` builds, all debug logging calls and format parsing in `engine.log` are completely eliminated at compile time from the output binary (0 CPU cycles, 0 log text in ROM), while the shared static buffer remains accessible to the low-level `panic` handler if an assertion failure occurs.

In addition, during unit tests (`builtin.is_test`), hardware MMIO access is disabled at compile time (`comptime !specs.is_gba_target`), ensuring host-side test runner safety and silent execution by default.

### C. Performance Profile & Formatting Overhead (`std.fmt.bufPrint`)
Using `std.fmt.bufPrint` on bare-metal GBA introduces specific trade-offs compared to traditional C-style `vsnprintf`:

1. **Compile-Time Format Parsing (Zero Runtime String Parsing)**:
   - Traditional C libraries (`libgba` / devkitPro) use `vsnprintf`, which parses format strings (`%d`, `%s`, etc.) character-by-character at runtime.
   - Zig's `std.fmt` parses format strings (`{d}`, `{s}`, `{X}`) entirely at **comptime**. Format strings are converted directly into static type-specialized serialization calls, eliminating runtime parser overhead.
2. **Zero Heap Allocation**:
   - `std.fmt.bufPrint` writes directly to the bounded static buffer `format_buf` without any dynamic heap allocation.
3. **ARM7TDMI Software Division Consideration**:
   - The GBA's ARM7TDMI processor lacks a hardware division unit. Formatting decimal integers (`{d}`) requires software division subroutines (`__aeabi_uidivmod`), consuming several dozen CPU cycles per digit.
   - Formatting hexadecimal numbers (`{X}`) or strings (`{s}`) relies on simple bitshifts, masks, and memory copies, incurring minimal CPU overhead.
   - **Best Practice**: In performance-sensitive game loops, avoid continuous high-frequency logging of decimal integers per frame; use discrete or event-driven logging instead.

### D. Two-Stage Memory Copy & CPU Cycle Breakdown
When a log message traverses from `engine.log` to the hardware MMIO registers, it goes through a two-stage pipeline:

```
[Format Arguments] ──(Stage 1)──> [Static Buffer: format_buf] ──(Stage 2)──> [mGBA MMIO: 0x04FFF600]
```

1. **Stage 1: Serialization (`formatToBuf`)**:
   - Copies string literals and serialized values into `format_buf`.
   - Overhead: ~200–400 cycles for a standard string (including integer software division).
2. **Stage 2: MMIO Hardware Transfer (`hal.mgba.log.write`)**:
   - Copies bytes sequentially from `format_buf` to `0x04FFF600` via loop (`REG_DEBUG_STRING[i] = message[i]`).
   - Overhead: Memory bus wait states on MMIO space take ~4–7 cycles per byte transfer iteration.
   - For an 80-byte message: $80 \times 7 \approx 560$ cycles.
3. **Total Frame Budget Impact**:
   - Total runtime overhead per 80-character log invocation: **~800–1000 CPU cycles**.
   - With the GBA 16.78 MHz CPU delivering **~280,896 cycles per frame** (at 60 FPS), a full log message consumes **~0.3% of a frame budget**.
   - **Future Optimization Opportunity (Direct-to-MMIO)**: If tighter latency is desired in Debug builds, `std.fmt.bufPrint` can serialize directly into the `0x04FFF600` pointer slice on GBA hardware targets, eliminating Stage 1's intermediate static buffer copy.

### E. Running mGBA with Log Output Enabled
By default, mGBA filters out non-critical console logs. To capture engine logs on stdout, run mGBA with the `-l` (`--log-level`) option:

```bash
# Enable all log levels (Mask 31 = FATAL(1) | ERROR(2) | WARN(4) | INFO(8) | DEBUG(16))
mgba -l 31 --scale 4 ./zig-out/bin/flappy_tsetseg_streaming.gba
```

> [!NOTE]
> - **Decimal Integer Parameter**: mGBA's CLI argument parser strictly requires **decimal** integer values for `-l` / `--log-level` (e.g. `31`). Hexadecimal formats (such as `0x1F`) are not parsed properly and will silently result in zero log output.
> - **Emulator Internal Diagnostics**: When log level mask `31` is enabled, mGBA will also output its own internal hardware trace logs (e.g., `GBA DMA: Starting DMA 3 ...`) alongside Zamgba application logs.

### F. Bare-Metal Panic Handler Lifecycle (`src/hal/panic.zig`)

When a runtime assertion fails, an index goes out of bounds in Debug mode, or `catch unreachable` is tripped, the low-level `hal.panic` handler takes control. On bare-metal targets without an operating system, the handler executes a 5-step deterministic lifecycle:

```
[Panic Triggered]
       │
       ▼
 1. Disable Interrupts (REG_IME = 0)
       │
       ▼
 2. Format Message & PC into Shared Static Buffer (`format_buf`)
       │
       ▼
 3. Set Backdrop Palette to RED (`PALRAM[0] = 0x001F`)
       │
       ▼
 4. Flush FATAL Log to mGBA Port (`mgba.init()` & `mgba.write(.fatal, ...)`)
       │
       ▼
 5. Infinite Loop (`while (true) {}`)
```

1. **Interrupt Suppression (`REG_IME = 0`)**: Immediately disables master interrupt enable register (`REG_IME`) to prevent interrupts/ISRs from preempting or corrupting the panic state.
2. **Zero-Stack String Formatting**: Uses `std.fmt.bufPrint` against the preallocated static buffer `hal.mgba.log.format_buf` (128 bytes in IWRAM/EWRAM), consuming 0 bytes of stack frame to avoid stack overflow hazards. Both the panic message and Program Counter (`ret_addr`) are formatted.
3. **Visual Hardware Indicator (Red Screen)**: Sets backdrop palette `PALRAM[0]` to RED (`0x001F`). Even if running on physical GBA hardware with no debug cable or if emulator logging flags are omitted, developers instantly recognize a panic occurred rather than a silent freeze or black screen.
4. **Emulator Fatal Log Dispatch**: Calls `mgba.init()` to ensure MMIO registers are enabled, then flushes the formatted panic message with `LogLevel.fatal`. In mGBA, receiving a FATAL log halts the emulator execution and displays the error clearly on the host terminal.
5. **Deterministic Lockup**: Enters `while (true) {}` preventing undefined CPU execution on hardware.

---

## 4. Channel 2: On-Screen Text Display & Pixel Font Design

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

---

## 7. Testing Best Practices & Target Environment Assumptions (测试最佳实践)

### A. Debug Mode Target Assumption (mGBA)
- **Debug Builds**: When Zamgba is compiled in `Debug` optimization mode, the logging subsystem assumes execution under **mGBA** (with CLI `-l` / `--log-level` flags enabled).
- **Execution on Non-mGBA Targets in Debug Mode**:
  - If a `Debug` mode ROM is executed on physical GBA hardware (via flashcarts) or non-mGBA emulators (e.g. VBA, No$GBA), `hal.mgba.log.write()` will write to unmapped MMIO space (`0x04FFF600`–`0x04FFF780`).
  - While physical GBA bus controllers typically ignore unmapped MMIO writes as no-ops, certain flashcarts or legacy emulators may exhibit undefined behavior or unexpected bus locks.
  - If dynamic environment detection is needed before logging, developers can query `hal.mgba.log.isRunOnMgba()`.

### B. Zero-Cost Guarantee in Release Modes
- In release modes (`ReleaseFast`, `ReleaseSmall`), all `engine.log.*` statements and formatting routines are **completely eliminated at compile time** (`comptime builtin.mode != .Debug`).
- Release builds produce 0 byte MMIO writes, 0 CPU cycles spent on logging, and 0 log strings in ROM. They run identically and safely across all physical GBA consoles, flashcarts, and hardware emulators without any MMIO side effects.
