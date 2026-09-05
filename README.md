# Introduction

> [!IMPORTANT]
> **Disclaimer:** Zamgba is an unofficial homebrew development tool. It is not affiliated with, authorized, sponsored, or endorsed by Nintendo Co., Ltd. "Game Boy", "GBA", and "Game Boy Advance" are registered trademarks of Nintendo.


[Zamgba](https://github.com/fuzhouch/zamgba) is a project to learn
how to program for [Game Boy Advance](https://en.wikipedia.org/wiki/Game_Boy_Advance).
My goal is to use Game Boy Advance as a target platform to
develop my own video gamed as hobby.

The motivation was brought when I learn [TIC-80](https://tic80.com), a
popular open source fantasy console. I love the idea behind
(which was indeed brought by
[PICO-8](https://www.lexaloffle.com/pico-8.php)), that a fantasy console
should include all tools needed for development. However, it brings a
limitation, that it is not easy to make use of modern
graphics or music composing tools into development workflow, such as
[Asprite](https://www.aseprite.org)
or [Famistudio](https://www.famistudio.org/).
Besides, I would like to program targeting a true hardware with
low-level concepts (e.g. IRQs.). A high-level
scripting language used by fantasy console does not allow me do this.

[Game Boy Advance](https://en.wikipedia.org/wiki/Game_Boy_Advance) has
been a popular gaming hardware since I was a kid.
Though it has reached end-of-life for a long time, there are many
games available. People play them on real hardwares (GBA, GBA SP,
Nintendo DS or 3DS), hardware simulator
([Analogue Pocket](https://www.analogue.co) or emulators
(either via desktop or many retro handheld devices). Unlike
fantasy consoles,
[Game Boy Advance](https://en.wikipedia.org/wiki/Game_Boy_Advance)
is based on real ARM processor. The knowledge of hardware programming
is still useful nowadays.

Overall, [Game Boy Advance](https://en.wikipedia.org/wiki/Game_Boy_Advance)
appears to be a better target platform than fantasy console for me to
create 2D based, retro style game for fun.

## The programming languages

I use [Zig programming language](https://ziglang.org) to construct my
project. Zig is a low-level language just like C, but it comes with many
language constructs to prevent memory bugs. Meanwhile, Zig comes with a
perfect compiler toolchain, which keeps cross-compiling in mind from
the first day.


## How can I (as a reader) use the project

With **v0.1.0**, Zamgba is ready as an early, open-source SDK and lightweight 2D engine for learning and creating Game Boy Advance programs in pure Zig.

You can use this project to:
1. **Learn GBA Hardware Programming**: Explore how GBA MMIO registers, VRAM, and OAM can be mapped cleanly into type-safe Zig constructs without fragile C pointer arithmetic.
2. **Build Your Own GBA Demos & Games**: Use the built-in HAL and engine loop to write your own ROMs, test 2D collisions, and run them on real hardware or emulators like mGBA.
3. **Reference as a Dependency**: Integrate Zamgba into your own external game repository using git submodules (see `consumezamgba` below).

*Note*: As of v0.1.0, this is an early developer preview. It is great for small retro games (like Pong), tech demos, and learning bare-metal development, but not yet intended for full commercial productions. Feedback, suggestions, and PRs are welcome!

## ...But I'm a hacker!

Well, if you are also interested programming GBA in Zig, follow the
steps below:

1. Install Zig. The codebase is compiled with Zig version **0.16.0** or later.
2. Clone [Zamgba](https://github.com/fuzhouch/zamgba) source code.
3. Build with command: `zig build`. You will get the compiled demo ROM binaries inside `zig-out/bin/` (e.g., `zig-out/bin/sprite_engine.gba`).
4. Run any ROM using an emulator. For example: `mgba ./zig-out/bin/sprite_engine.gba`.
5. For debugging, use `mgba -d ./zig-out/bin/sprite_engine.gba`. It's a powerful assembly debugging tool to solve a lot of problems.

## Built-In Demo ROMs

Zamgba includes several interactive and instructional demo ROMs categorised by abstraction layers:

### 1. Hardware Abstraction Layer (HAL) Demos
*   **`mode3_lines`** (`demo/hal/mode3_lines.zig`): Demonstrates basic Mode 3 bitmap graphics. Renders three intersecting colored lines on a bitmap background using low-level, context-agnostic line-drawing algorithms.
*   **`sprite_hal`** (`demo/hal/sprite_hal.zig`): Demonstrates direct, register-level sprite setup on the GBA. Manually populates palette memory (PALRAM) and sprite tile memory (VRAM), configures packed `ObjAttr` coordinates, and bounces a single white 8x8 block smoothly left-to-right inside a VBlank-synchronized loop.

### 2. High-Level Engine Demos
*   **`sprite_engine`** (`demo/engine/sprite_engine.zig`): Showcases our high-level **Static Namespace / File** engine loop. State is declared cleanly as file-scope `var` variables, and the loop is started via `engine.run(@This())`. The engine automatically manages VBlank timing, OAM hardware uploads, and dynamic slot allocation.
*   **`sprite_instanced`** (`demo/engine/sprite_instanced.zig`): Showcases our high-level **Pointer-to-Instance** engine loop. Encapsulates the entire game state inside a type-safe structure (`const Game = struct { ... }`) and passes an instance pointer `engine.run(&game)`. This is the recommended structure for larger, multi-sprite/multi-level modular games requiring state serialization (SRAM/Flash cartridge saving).
*   **`joypad_instanced`** (`demo/engine/joypad_instanced.zig`): Demonstrates high-level sprite movement via D-pad input using engine-layer APIs. Changes sprite color dynamically upon hitting screen boundaries (Top: Red, Bottom: White, Left: Yellow, Right: Green).
*   **`collision_demo`** (`demo/engine/collision_demo.zig`): Demonstrates the 2D physics engine, AABB collision detection, and `CollisionMap` streaming. Features a player square responding to D-pad inputs, two bouncing patrol enemies, and game state reset upon collision.
*   **`flappy_tsetseg`** (`demo/engine/flappy_tsetseg.zig`): Demonstrates animated multi-frame 8-bpp sprite playback with static all-frame VRAM preloading.
*   **`flappy_tsetseg_streaming`** (`demo/engine/flappy_tsetseg_streaming.zig`): Demonstrates high-performance VRAM Streaming sprite animation. Only a single 32x32 frame slot (1 KB) is allocated via `VramAllocator`; subsequent frames stream asynchronously from ROM into VRAM via `AnimatedSprite` and `DmaQueue` during VBlank.
*   **`pong`** (`demo/engine/pong.zig`): A complete, playable classic Pong game built entirely on `zamgba-engine`. Features player paddle D-pad controls, AI paddle tracking, top/bottom wall reflections, AABB paddle-ball collision response, and scoring/resets.

### Can I reference your library as a dependency?

Yes. Please check the example at: https://github.com/fuzhouch/consumezamgba.

You can manage Zamgba as a dependency via git submodule or standard package workflows.

The example project shows three steps to enable your project building a GBA ROM:

1. ``build.zig`` calls ``@import("zamgba").arm.addROM()`` to define
   a target. The API defines proper target to build code targeting
   ARM7tdmi. It also defines step to do ``objcopy``, which is required
   to convert built ELF file to an ``.gba`` image that can be recognized
   by mgba.
2. In source code, define a ``gameHeader`` to register GBA rom header
   required by GBA device. It must be done by calling
   ``@import("zamgba").setupROMHeader()``.
3. Define main() function entry point with ``export`` keyword. It is
   required by ``zamgba`` to locate the entry point while booting.


Enjoy!

## Milestones

* **Version 0.1.0** (2026-08-23): Capable of writing a classic pong game. Supported features:
  - [x] Respond to gamepad input
  - [x] Single color/square sprites
  - [x] Hardcoded collision detection 
* **Version 0.2.0**: Capable of writing a game with rich sprites graphics. Supported features:
  - [x] Mode 0 support
  - [x] PNG-sprite-to-code conversion tool (`zurag`)
  - [x] Color palettes conversion tool (`zurag`)
  - [x] Engine-level streaming sprite loader & VBlank DMA manager
* **Version 0.3.0**: Capable of writing a game with rich sprites and scrolling background. Supported features:
  - [ ] Camera
  - [ ] Background TileMap engine (ScreenBlock management & packed 16-bit ScreenEntry)
  - [x] True color background, via mode 3, 4, 5
* **Version 0.4.0**: Capable of writing a game with chiptune music. Supported features:
  - [ ] Chiptune-to-code conversion tool
  - [ ] Support chiptune playing music
* **Version 0.5.0**: Capable of writing a game with save data. Supported features:
  - [ ] Save state read/write API
* **Version 0.6.0**: Capable of playing Direct Audio. Supported features:
  - [ ] Wav file to code conversion tool
  - [ ] Direct Audio playback API
* **Version 0.7.0**: Capable of writing a game with 2D physics. Supported features:
  - [x] 2D collision & detection API
* **Version 0.8.0**: Capable of writing a game with affine sprite transformations. Supported features:
  - [ ] Fixed-point Sin/Cos lookup table (LUT)
  - [ ] 32-slot OAM affine matrix allocator
  - [ ] Sprite rotation and scaling API

## License and Copyright

This repository contains both open-source code for the `zamgba` SDK/engine and proprietary art assets used for testing and demonstration purposes.

* **Source Code**: The library and engine source code is open-source. *(Feel free to add a specific `LICENSE` file like MIT or Zlib to the repository if you haven't already).*
* **Art Assets (`assets/`)**: All art assets, including the Sprite files inside the `assets/` directory (e.g., `tsetseg-ride-on-broom-*`), are from the author's original game *["Tsetseg's Adventure"](https://store.steampowered.com/app/2337770/Tsetsegs_Adventure/)*. The copyrights for these assets belong entirely to the author. **All Rights Reserved.** You may use them locally to compile and run the demo ROMs provided in this repository, but you may not redistribute, modify, or use these visual assets in your own projects, open-source or commercial, without explicit permission.
* **Version 1.0.0**: Capable of writing a 2D platformer game.
* **Version 2.0.0**: Capable of writing a pseudo-3D game.
