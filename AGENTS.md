# Zamgba Agent Guidelines

This document provides essential context for AI agents working in the `zamgba` repository.

## Project Overview
Zamgba is a self-learning project for Game Boy Advance (GBA) programming using the **Zig** programming language (targeting Zig version **0.16.0** or later). It contains a library SDK (`zamgba`), a Hardware Abstraction Layer (`zamgba-hal`), platform-agnostic 2D graphics helper routines (`zamgba-engine`), and example demo ROMs.

---

## Code Architecture & File Layout

- **`build.zig` / `build.zig.zon`**: Build configuration. Defines target CPU (`arm7tdmi`), optimization modes, exposes `zamgba` module dependencies, and exports build helpers for consumers.
- **`src/zamgba.zig`**: The main entry point module for client integration, exposing `hal` and `engine`.
- **`src/build/arm.zig`**: Build scripts helper functions (`addROM`, `addStaticLibrary`) that set up the correct cross-compilation target query (`thumb`, `arm7tdmi`, `freestanding`) and post-compile step (`objcopy`) to generate `.gba` binary.
- **`src/hal/`** (Hardware Abstraction Layer):
  - `hal.zig`: Core HAL file. Defines memory sections (VRAM, EWRAM, IWRAM, IORAM, etc.), screen dimensions (Mode 3, Mode 5), default color constants, boot logic (`_start`, `_boot`), and ROM header setup tools.
  - `gba.ld`: The custom linker script defining the memory layout for the GBA (mapping `.gba.header`, `.gba.start`, `.gba.boot`, `.gba.main` sections to the beginning of the text area in `pakrom`).
  - `header.zig`: Structure definition and template for GBA ROM headers.
  - `display.zig`: Safe wrappers for GBA display controls (`REG_DISPCNT`, `REG_DISPSTAT`, `REG_VCOUNT`), register reading/writing, and page flipping.
  - `context.zig`: Hardware-backed bitmap drawing contexts (e.g., `Mode3Context`, `Mode5Context`) wrapping raw VRAM with bounds checks.
- **`src/engine/gfx2d/`** (2D Graphics Algorithms):
  - `gfx2d.zig`: Exposes drawing helpers.
  - `line.zig` / `point.zig`: Implementation of generic drawing algorithms (e.g. Bresenham's line algorithm via `drawLine`) designed to be context-agnostic.
- **`demo/first.zig`**: Entry point for the sample ROM demonstration using Mode 3 context to draw colored lines.
- **`src/unittest.zig`**: Root file for compiling unit tests.

---

## Essential Commands

- **Build**: `zig build`
  - Generates standard ELF binaries with debugging symbols (e.g., `zig-out/bin/first`).
  - Generates GBA-compatible ROM binaries (e.g., `zig-out/bin/first.gba`) using `objcopy` (.bin output format).
- **Test**: `zig build test`
  - Runs unit tests defined in the files imported by `src/unittest.zig`.
  - **Crucial Gotcha**: Unit tests compile and execute on the **host machine**. Manipulation of hardware registers (`REG_DISPCNT`, etc.) will not execute correctly on the host. Tests must mock drawing contexts or test purely logic-based structures.
- **Run**: `mgba ./zig-out/bin/first.gba`
  - Runs the compiled GBA ROM on the mGBA emulator.
- **Debug**: `mgba -d ./zig-out/bin/first.gba`
  - Starts mGBA with assembly-level GDB debugging support.

---

## Gotchas and Important Patterns

### 1. Boot Entry and Calling Conventions
- **Naked Function Requirement**: The low-level boot sequence entry point `_start` in `src/hal/hal.zig` must use `callconv(.naked)`. 
- **Why**: As of Zig 0.16.0, the compiler strictly emits standard ABI prologues (which push registers onto uninitialized stacks) for normal exported functions. Since `_start` runs before the stack is even set up, normal function prologues will cause a silent hardware/emulator crash (rendering a blank white screen). Using `callconv(.naked)` prevents the compiler from adding stack management prologues.
- **Prior Versioning**: Older Zig versions used `.Naked`. In 0.16.0+, only `.naked` is valid.

### 2. GBA Boot Logic Assembly Workaround
- **Inline Assembly Branch**: The boot logic in `_boot()` intentionally uses inline assembly (`asm volatile`) rather than Zig's built-in compile-time checks (e.g. `@hasDecl(root, "main")`) to call the user's `main()` function. 
- **Why**: `@hasDecl` is evaluated at compile time and caused an endless loop during boot under certain target configurations. **Do not refactor the boot sequence to use `@hasDecl`**.

### 3. Register Access and Unit Testing
- **Avoid Register Writes in Tests**: GBA hardware register writing functions (such as `display.writeRegister()` which writes directly to `0x04000000`) must **never** be invoked in unit tests.
- **Pattern**: When testing components like `display`, only verify their software-side state (e.g., checking `display.value`). Avoid writing to or reading from actual volatile pointers when executed on host test machines.

### 4. Client Integration Requirements
To successfully use Zamgba in an external/client project:
1. **Target Hook**: The client's `build.zig` must use `@import("zamgba").arm.addROM(...)` to construct the freestanding target, apply the linker script (`gba.ld`), and invoke `objcopy`.
2. **Explicit ROM Header Registration**: The client must explicitly expose a static `export var gameHeader linksection(".gba.header") = hal.setupROMHeader(...)` variable so that the GBA BIOS can validate and boot the ROM.
3. **Noreturn Main Function**: The client must define an exported `export fn main() noreturn` function ending in an infinite loop (`while (true) {}`), as the GBA has no operating system to return execution to.

---

## Agent Behavior & Communication Rules

- **Language Requirement**: All committed code, commit messages, code comments, design docs (`docs/`), READMEs, and test descriptions must strictly be written in English.
- **Documentation**: All code comments, READMEs, and guides must be written in English.
- **Design Documents**: Architectural guidelines are listed in the `docs/` folder. Always consult `compile.md` and `features.md` before making modifications to compiling/linking rules or features planning.
- **Communication Style**: Direct and to the point. No conversational filler, pleasantries, or emojis.

### Demo Guidelines
- When adding a new demo, place the newly added demo ROM to the corresponding subfolder inside `demo/` (e.g., `demo/hal/` for hardware-abstraction layer demos).

---

## Strict Test-Driven Development (TDD) & Review Workflow

Every new feature, tool, and algorithm implementation MUST strictly adhere to the following lifecycle:

`TDD Red` -> `Commit` -> `Review` -> `Commit` -> `TDD Green` -> `Review` -> `Commit`

### Lifecycle Phases

1. **Step 1: Interface & Test Definition (TDD Red Phase)**
   - Define public data structures, types, and stub functions (returning `error.Unimplemented` or stub values).
   - Write comprehensive unit tests that cover all edge cases, validations, and expected behaviors.
   - **Test Naming Convention**: All unit test blocks MUST follow the `[XXX000: description]` format (a 3-uppercase-letter module prefix + 3-digit sequential number + description):
     - `CLI001`: CLI argument parser tests (`tools/zurag/main.zig`)
     - `PNG001`: PNG header, palette, and IDAT decompression tests (`tools/zurag/png.zig`)
     - `PTH001`: Paeth predictor algorithm tests (`tools/zurag/algo/paeth.zig`)
     - `UNF001`: PNG scanline unfiltering tests (`tools/zurag/algo/unfilter.zig`)
     - `TIL001`: 8x8 Tile packing and sprite frame slicing tests (`tools/zurag/tile.zig`)
     - `MET001`: Unified metadata dispatcher tests (`tools/zurag/metadata.zig`)
     - `ASE001`: Aseprite JSON metadata adapter tests (`tools/zurag/metadata/aseprite.zig`)
     - `GEN001`: Code generator output tests (`tools/zurag/codegen.zig`)
     - `CLR001`: Color representation and conversion tests (`src/engine/color.zig`)
     - `SPR001`: Engine sprite representation and OAM encoding tests (`src/engine/sprite.zig`)
     - `MAT001`, `ABB001`, `MAP001`, `LAY001`, `OVL001`: Physics sub-engine tests
     - `LDT001`: LDtk JSON parser and tilemap converter tests (`tools/zurag/ldtk.zig`)
   - Run `zig build test` to prove that the new tests fail (Red state) without breaking existing tests.
   - Commit the Red state.

2. **Step 2: Review Phase (Post-Red Review)**
   - Follow the **Interactive Review Mode** rules below.
   - Once the user confirms the review is complete, commit and push, then transition to TDD Green.

3. **Step 3: Incremental Implementation (TDD Green Phase)**
   - Implement the concrete function logic one step at a time.
   - Run `zig build test` to verify that all target unit tests transition from Red to Green.
   - Refactor: Clean up magic numbers (replace with named constants) and enforce the Principle of Least Visibility.

4. **Step 4: Review Phase (Post-Green Review)**
   - Follow the **Interactive Review Mode** rules below.
   - Once the user confirms the review is complete, commit and push.

---

### Interactive Review Mode Rules

During any Review Phase, the agent and developer operate under the following rules:

1. **Q&A Driven Iteration**:
   - The developer asks questions, requests explanations, or points out adjustments; the agent answers and modifies the codebase accordingly.
2. **Preservation of Unit Tests**:
   - Unit tests are the source of truth for behavioral correctness.
   - Adding new unit tests during the review phase is permitted and encouraged.
   - Existing unit tests must **never** be modified or deleted arbitrarily. Modifying an existing unit test is allowed only when the developer explicitly requests it. If in doubt, ask the developer for confirmation before making changes to tests.
3. **Multi-round Review Cycles**:
   - The review Q&A process may span multiple rounds.
   - When the developer explicitly confirms that the current review round is finished, the agent must `commit` and `push` the changes, then transition into the next phase (e.g., TDD Green or the next feature task).
