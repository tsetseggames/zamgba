# Zamgba SDK Architectural Design

The Zamgba SDK utilizes a consolidated, highly pragmatic **2-Layer Architecture** designed to completely isolate the GBA's bare-metal complexities from the user-facing game logic.

---

```mermaid
graph TD
    subgraph High-Level Framework (Developer Facing)
        E[engine.Engine] --> SS[engine.StaticSprite / AnimatedSprite]
        SS --> S[engine.Sprite - Spatial/Physics]
        SS --> A[engine.SpriteAnimation - Frame Sequencing]
        E --> G[engine.gfx2d.Drawing Algorithms]
    end

    subgraph Low-Level Core (Under the Hood)
        E --> H[hal.waitForVBlank]
        E --> O[hal.oam.ObjAttr]
        H --> R[hal.MemorySections]
    end

    E ==>|1. Stages to shadow OAM & flushes graphics to| O
    SS ==>|2. Combines spatial + tile metadata into| O
```

---

## 1. The Low-Level Core (Under the Hood)

This layer acts as the GBA's **Hardware Driver Layer** (`zamgba.hal`). It handles direct physical registers, volatile memory segments, and strict hardware constraints. Game developers rarely touch this layer directly unless building low-level effects or custom renderers.

### Hardware Abstraction Layer (`zamgba.hal`)
Maps GBA physical registers and exposes safe, atomic timing controls.
*   **`hal.MemorySections`**: Direct pointers to physical segments like VRAM (`0x06000000`), PALRAM (`0x05000000`), and OAM (`0x07000000`).
*   **`hal.display`**: Configurations for GBA hardware register flags (Modes 0-5, Object enable, 1D/2D sprite mapping).
*   **`hal.waitForVBlank()`**: Synchronizes the CPU game loop with the hardware display beam, blocking execution until the brief vertical blanking window starts.
*   **`hal.oam.ObjAttr`**: A 64-bit packed struct defining the raw GBA hardware sprite attributes structure.
*   **`hal.context.Mode3Context` / `Mode5Context`**: State-backed bitmap drawing contexts. They wrap VRAM physical addresses with automatic horizontal/vertical boundary checks and expose a standardized `drawPixel()` interface used by high-level drawing algorithms.

---

## 2. The High-Level Framework (Developer Facing)

This is the **Game Engine Layer** (`zamgba.engine`). It is the primary API interface for the game developer, combining game loop orchestration, logical entities, and 2D drawing routines.

### A. Engine Orchestration (`zamgba.engine`)
*   **`engine.Sprite`**: A pure spatial and physics entity representing position (`Fixed24_8` sub-pixel coordinates), bounding box (`AABB`), velocity, collision layers/masks, and orientation (horizontal/vertical flip). It deliberately does **not** store graphical tile data.
*   **`engine.StaticSprite` / `engine.AnimatedSprite`**: Composite renderable entities combining `Sprite` with graphical VRAM descriptors (`tile_index`, `palette_bank`, `bpp`) or frame animation controllers (`SpriteAnimation`). They implement `toOamAttr() hal.oam.ObjAttr` to calculate the GBA's complex shape, size, palette, and tile index bitmasks.
*   **`engine.Engine`**:
    *   **Shadow OAM**: Manages an internal `shadow_oam: [128]hal.oam.ObjAttr` array to stage sprite data before rendering.
    *   **`drawSprite(spr)`**: Accepts a sprite pointer (`*StaticSprite` or `*AnimatedSprite`), dynamically staging it to the next available physical slot (0 to 127) for the current frame with optional camera frustum culling and screen coordinate transformation.
    *   **`nextFrame()`**: Bundles frame timing (`hal.waitForVBlank()`), graphics flushing (copying the shadow buffer to `hal.MemorySections.OAM`), DMA streaming queues, and dynamic sprite slot resets.
    *   **`run(context)`**: The compile-time monomorphized loop runner. It accepts either:
        1.  **Static Namespaces (`@This()` of a file)**: Treating files as implicit singleton structs for easy prototyping (state resides in file-scope variables).
        2.  **Instance Pointers (`&game`)**: Passing fully encapsulated game structs, supporting level transitions, and cartridge save state serialization (SRAM).

### B. 2D Graphics Algorithms (`zamgba.engine.gfx2d`)
Provides platform-agnostic, mathematics-based drawing routines for procedural rendering on bitmap or canvas contexts.
*   **`gfx2d.drawLine(start, end, color, context)`**: Implements Bresenham's line algorithm to paint lines onto bitmap-backed drawing buffers.
*   **`gfx2d.Point2` / `gfx2d.Vector2`**: High-level geometric structures for manipulating coordinates.

---

## 3. Key Design Tradeoffs & Benefits

1.  **Zero-Cost Abstractions**: By leveraging compile-time validation in `Engine.run` and `Engine.drawSprite`, all loops and coordinate transforms resolve with zero runtime dynamic dispatch (no vtables), leaving maximum performance for the GBA's 16.78 MHz CPU.
2.  **Encapsulation of Workarounds**: Hardware workarounds (like OAM Shadowing and VBlank DMA flushes) are tucked away into the Engine Core, allowing developers to draw sprites smoothly in a standard 60 FPS update-and-render game loop.
3.  **Strict Boundary**: The division between raw hardware representations (`hal`) and state management/game logic (`engine`) makes the architecture clear and maintainable.

## 4. Strict Layering Design Rules

To prevent spaghetti logic and ensure the GBA SDK stays modular and safe, Zamgba enforces the following strict architectural coupling rules:

1.  **Strict Linear Dependency (`engine` -> `hal`)**:
    The high-level `engine` module communicates directly downward through the `hal` abstraction layer. 
2.  **No Upward Dependency (Acyclic Layering)**:
    A lower-tier module (`hal`) is strictly oblivious to the tiers above it. `hal` cannot depend on `engine`.

---

## 5. Specialized Subsystem Architecture

* **Graphics & Tooling**: See [Aseprite & LDtk Asset Conversion (`zurag`)](tool_zurag_pic_conversion.md)
* **Audio Subsystem**: See [Audio System Architecture, Tooling (`duu`), & Roadmap](sound.md)
