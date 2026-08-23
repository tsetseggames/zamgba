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

Nothing for now. This is a self-learning session to study the classic
[tonc](https://www.coranac.com/tonc/text/toc.htm) documentation.
The content of this repository is indeed a set of example code following
the tutorial. It is neither a game, nor a new emulator,
or an existing rom hack. 

If you are interested in how to learn hardware oriented programming, no
matter with Zig or other programming languages, you may (eventually) find
something useful here. :)

Though it sounds completely useless for now, it may change in the future.
If I happen to figure out a clear direction, I will update this
documentation and make it official.

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
*   **`sprite_engine`** (`demo/engine/sprite_engine.zig`): Showcases our high-level **Static Namespace / File** engine loop. State is declared cleanly as file-scope `var` variables, and the loop is started via `eng.run(@This())`. The engine automatically manages VBlank timing, OAM hardware uploads, and dynamic slot allocation.
*   **`sprite_instanced`** (`demo/engine/sprite_instanced.zig`): Showcases our high-level **Pointer-to-Instance** engine loop. Encapsulates the entire game state inside a type-safe structure (`const Game = struct { ... }`) and passes an instance pointer `eng.run(&game)`. This is the recommended structure for larger, multi-sprite/multi-level modular games requiring state serialization (SRAM/Flash cartridge saving).
*   **`joypad_instanced`** (`demo/engine/joypad_instanced.zig`): Demonstrates high-level sprite movement via D-pad input using engine-layer APIs. Changes sprite color dynamically upon hitting screen boundaries (Top: Red, Bottom: White, Left: Yellow, Right: Green).
*   **`collision_demo`** (`demo/engine/collision_demo.zig`): Demonstrates the 2D physics engine, AABB collision detection, and `CollisionMap` streaming. Features a player square responding to D-pad inputs, two bouncing patrol enemies, and game state reset upon collision.

### Can I reference your library as a dependency?

Yes. Please check example: https://github.com/fuzhouch/consumezamgba.

I recommend we use git submodule to manage zamgba as dependency. This
should fit the scenarios when developers have to work under a proxy.
By the time this doc is written (2024-01), ``zig build`` does not work
well with a proxy when downloading a remote package.

The example project shows three steps to enable your project building
a GBA rom:

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

* **Version 0.1.0**: Capable of writing a classic pong game. Supported features:
  - [x] Respond to gamepad input
  - [x] Single color/square sprites
  - [x] Hardcoded collision detection 
* **Version 0.2.0**: Capable of writing a game with rich sprites graphics. Supported features:
  - [x] Mode 0 support
  - [ ] PNG-sprite-to-code conversion tool
  - [ ] Color palettes conversion tool
* **Version 0.3.0**: Capable of writing a game with rich sprites and scrolling background. Supported features:
  - [ ] Camera
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
* **Version 1.0.0**: Capable of writing a 2D platformer game.
* **Version 2.0.0**: Capable of writing a pseudo-3D game.
