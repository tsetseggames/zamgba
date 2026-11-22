# Motivation and Background

## Why GBA and Zig?

[Zamgba](https://github.com/fuzhouch/zamgba) was born out of a desire to learn how to program directly for the [Game Boy Advance](https://en.wikipedia.org/wiki/Game_Boy_Advance) and develop hobby retro video games targeting real hardware.

### From Fantasy Consoles to Real Silicon

The original motivation emerged while exploring [TIC-80](https://tic80.com), a popular open-source fantasy console. The core philosophy of fantasy consoles (pioneered by [PICO-8](https://www.lexaloffle.com/pico-8.php))—providing an all-in-one environment with built-in editors—is wonderful for quick prototyping. However, it introduces practical constraints:
- **Tooling Friction**: It is difficult to integrate modern dedicated graphics, animation, and audio tools (such as [Aseprite](https://www.aseprite.org) or [FamiStudio](https://www.famistudio.org/)) into a fantasy console's self-contained workflow.
- **Abstraction Limits**: High-level scripting languages on fantasy consoles obscure real hardware concepts such as memory-mapped I/O (MMIO), display timing registers, scanline interrupts (IRQs), and Direct Memory Access (DMA).

In contrast, the [Game Boy Advance](https://en.wikipedia.org/wiki/Game_Boy_Advance) is a classic 32-bit handheld powered by an ARM7TDMI RISC processor. Its architecture strikes an ideal balance:
- Real silicon with authentic hardware registers, scanline timers, and memory banks.
- Fast, accessible hardware that is deeply understood and well-documented.
- A thriving ecosystem of real hardware (GBA, GBA SP, Nintendo DS/3DS, FPGA consoles like the Analogue Pocket) and high-accuracy emulators (like mGBA) with assembly-level debuggers.
- The low-level concepts learned on ARM7TDMI remain relevant in modern embedded systems programming.

### Why Zig?

Traditional GBA homebrew relies heavily on C or C++ (e.g. devkitARM / libgba). While capable, C lacks modern compile-time metaprogramming and safety guarantees, often relying on macros and raw pointer arithmetic that easily lead to memory bugs and alignment faults.

[Zig](https://ziglang.org) is an exceptional fit for bare-metal GBA development:
- **First-Class Cross-Compilation**: Zig includes a built-in cross-compiler with out-of-the-box support for `arm-freestanding`.
- **Type-Safe Hardware Mapping**: Packed structs, enums with explicit backing integer types, and pointer attributes allow mapping GBA MMIO registers directly into expressive, type-safe structures without runtime overhead.
- **Comptime Metaprogramming**: Zig's `comptime` enables zero-overhead abstractions, compile-time tile deduplication, and automated asset embedding.
- **Safety and Clarity**: Explicit error handling and well-defined behavior prevent subtle bugs common in freestanding C codebases.
