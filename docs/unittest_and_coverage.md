# Unit Testing & Code Coverage Guide

This document explains how unit tests and test coverage reports are configured and executed in the `zamgba` project.

---

## 1. Overview & Architecture

Because Game Boy Advance (GBA) targets a freestanding `arm7tdmi` architecture, unit testing requires special consideration:

* **Host Execution**: Unit tests are compiled and executed natively on the **developer's host machine** (x86_64/AArch64), rather than in an ARM emulator.
* **Hardware Register Isolation**: Code interacting directly with GBA MMIO hardware registers (`0x04000000`, `0x07000000`, etc.) cannot execute on the host. Tests focus on pure logic, math, physics, collision detection, and offline asset compilers (such as `zurag`).
* **Test Artifact Installation**: The primary unit test binary is compiled and installed to `zig-out/tests/unittest`.

---

## 2. Running Unit Tests

To run the complete unit test suite across `zamgba`:

```bash
zig build test
```

### Build Steps Involved:
1. Compiles the core SDK unit tests (`src/unittest.zig`) and engine tests (`src/engine/engine.zig`).
2. Compiles and executes toolchain tests (`tools/zurag/main.zig`).
3. Installs the compiled test executable to `zig-out/tests/unittest`.

---

## 3. Code Coverage with `kcov`

The build system includes automatic integration with [kcov](https://github.com/SimonKagstrom/kcov), an open-source code coverage analysis tool for compiled binaries with DWARF debugging info.

### Prerequisites (Optional)
Install `kcov` using your system's package manager:

* **Debian / Ubuntu**:
  ```bash
  sudo apt-get install kcov
  ```
* **Arch Linux**:
  ```bash
  sudo pacman -S kcov
  ```
* **Fedora**:
  ```bash
  sudo dnf install kcov
  ```

*Note: On platforms where `kcov` is not installed or unavailable (such as native Windows), `build.zig` dynamically skips the coverage step without failing the build.*

### How Coverage Filtering Works
To avoid inflating the codebase line count with Zig's standard library and `compiler_rt` runtime internals (which would otherwise dilute coverage percentages down to < 1%):
* **Source Filtering**: `build.zig` invokes `kcov` with `--include-pattern=src/,tools/` to restrict coverage metrics exclusively to Zamgba source files.
* **Standard DWARF Symbols**: Test compilation enables `.use_llvm = true` and `.use_lld = true` to emit standard DWARF symbols that `kcov` can reliably map back to source lines.

### Generating Coverage Reports

To generate an HTML coverage report:

```bash
zig build coverage
```

### Viewing the Report

Once generated, the coverage artifacts are placed in `zig-out/tests/`:

* **Entry Point**: Open `zig-out/tests/index.html` in any web browser.
* **Command Line Quick View**:
  ```bash
  xdg-open zig-out/tests/index.html
  ```

---

## 4. Best Practices & Guidelines

1. **Deterministic Test Assets**: When testing file conversion logic (such as in `tools/zurag`), avoid runtime disk I/O. Use compile-time `@embedFile` within asset modules (`assets/palettes/test_assets.zig`) so that tests are 100% self-contained and reproducible across any working directory.
2. **Never Touch Hardware Pointers in Tests**: Mock drawing contexts or test software abstractions directly instead of referencing volatile hardware addresses.
