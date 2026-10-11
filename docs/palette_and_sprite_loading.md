# Palette and Sprite Tile Loading Architecture

This document specifies the design of palette and sprite tile loading APIs in `zamgba-engine`, detailing both the **explicit index loading APIs** (delivered in **v0.3.0**) and the **automated resource allocators** (planned for **v0.4.0**).

---

## 1. Motivation & Problem Statement

In the Game Boy Advance architecture, Object Palette RAM (`OBJ_PALRAM` at `0x05000200`) and Object Video RAM (`OBJ_VRAM` at `0x06010000`) are globally shared hardware memory regions. 

Prior to v0.3.0, demo ROMs were forced to manipulate memory directly via low-level pointer arithmetic:
```zig
// Low-level raw pointer access previously required in demo code
const obj_pal = hal.MemorySections.OBJ_PALRAM;
for (sheet.palette, 0..) |col, i| {
    obj_pal[i] = col;
}

const obj_vram = hal.MemorySections.OBJ_VRAM;
const raw_tile_words: [*]const u16 = @ptrCast(@alignCast(sheet.raw_tiles.ptr));
for (0..total_words) |i| {
    obj_vram[i] = raw_tile_words[i];
}
```

This presents two major issues:
1. **Breach of Engine Abstraction**: High-level game code (`demo/engine/`) should not require raw pointer casts, word-offset math, or direct hardware memory section imports.
2. **Resource Collision in Multi-Sprite Games**: When multiple sprites coexist, copying blindly to `OBJ_PALRAM` or `OBJ_VRAM` at offset 0 causes subsequent sprites to overwrite previous ones.

---

## 2. GBA Hardware Constraints & Memory Layout

### 2.1 Object Palette RAM (`OBJ_PALRAM`)
- Total capacity: **512 bytes** (256 entries of 16-bit BGR555 colors).
- **4-bpp Mode**: Divided into **16 banks** (Bank 0 to 15), each containing 16 colors (color 0 is always transparent). Sprites select their palette via OAM Attr2 `palette_bank: u4`.
- **8-bpp Mode**: Uses the entire 256-color palette globally. OAM Attr2 `palette_bank` is ignored by hardware.

### 2.2 Object Video RAM (`OBJ_VRAM`)
- Total capacity: **32 KB** (located at `0x06010000` to `0x06017FFF`).
- In 4-bpp mode, contains up to **1024 tiles** (32 bytes per 8x8 tile).
- In 8-bpp mode, contains up to **512 tiles** (64 bytes per 8x8 tile).
- Sprites reference their visual graphic using a 10-bit base `tile_index` in OAM Attr2.

---

## 3. Two-Stage Evolution Roadmap

| Phase | Milestone | Scope & Philosophy |
| :--- | :---: | :--- |
| **Stage 1: Explicit Index APIs** | `v0.3.0` | Provides zero-cost, type-safe functions with explicit slot/bank parameters (`bank: u4`, `tile_index: u16`). Eliminates raw pointer arithmetic while keeping hardware control explicit. |
| **Stage 2: Automated Resource Allocators** | `v0.4.0` | Extends `VramAllocator` to manage static sprite allocations, and introduces `PaletteAllocator` to dynamically lease 4-bpp banks without manual slot tracking. |

---

## 4. Stage 1 (v0.3.0): Explicit Index Loading APIs

### 4.1 Palette Loading APIs

```zig
pub const palette = struct {
    /// Loads a 16-color palette slice into a specific 4-bpp OBJ palette bank (0..15).
    pub fn loadObjBank(bank: u4, colors: []const u16) void;

    /// Loads raw colors into OBJ PALRAM starting at a specific color index offset (0..255).
    /// Used for 8-bpp palettes (256 colors) or partial custom slices.
    pub fn loadObjColors(start_color_index: u9, colors: []const u16) void;
};
```

**Convenience Method on `SpriteSheet`**:
```zig
impl SpriteSheet {
    /// Loads the sheet's palette into OBJ PALRAM.
    /// - For 4-bpp sheets, requires explicit bank index (0..15).
    /// - For 8-bpp sheets, loads into color offset 0.
    pub fn loadPalette(self: *const SpriteSheet, bank: ?u4) void;
}
```

### 4.2 Static Sprite Tile Preloading APIs

```zig
impl AnimatedSprite {
    /// Copies all frame tiles from the underlying SpriteSheet into OBJ VRAM
    /// starting at the sprite's designated base `tile_index`.
    pub fn preloadStaticTiles(self: *const AnimatedSprite) void;
}
```

When initializing an `AnimatedSprite` in `.static` mode, an optional `tile_index` can be provided in options:
```zig
pub const StaticOptions = struct {
    tile_index: u16 = 0,
    palette_bank: u4 = 0,
};
```

### 4.3 Stage 1 Usage Example in Demos

```zig
// Load 256-color palette for 8-bpp animated sprite:
broom.sheet.loadPalette(null);

// Or load into 4-bpp Bank 1:
// enemy_sheet.loadPalette(1);

// Initialize static animated sprite with explicit tile offset:
var hero = try engine.AnimatedSprite.init(&hero_sheet, .static, x, y, .{
    .tile_index = 0,
});
hero.preloadStaticTiles(); // Automatically writes to OBJ_VRAM starting at tile 0

var enemy = try engine.AnimatedSprite.init(&enemy_sheet, .static, x, y, .{
    .tile_index = 64, // Sequential offset to avoid overwriting hero tiles
});
enemy.preloadStaticTiles(); // Writes to OBJ_VRAM starting at tile 64
```

---

## 5. Stage 2 (v0.4.0): Automated Resource Allocators

In v0.4.0, manual tracking of palette banks and tile offsets will become completely optional through two automatic managers:

### 5.1 Automated VRAM Static Allocation
- `AnimatedSprite.init(..., .static, ...)` will automatically request contiguous tile slots from the existing buddy allocator (`vram_allocator.alloc(total_frame_tiles)`).
- Calling `anim.preloadStaticTiles()` will automatically transfer tile data into the allocated block without requiring manual calculation of `tile_index`.
- `anim.deinit()` will free the allocated tile range back to the buddy pool.

### 5.2 Automated Palette Allocator (`PaletteAllocator`)
- Tracks the 16 4-bpp OBJ palette banks using a bitmask (`u16`).
- Provides `allocBank() -> error{OutOfBanks}!u4` and `freeBank(bank: u4) void`.
- `engine.loadSpritePaletteAuto(&sheet) -> !u4` automatically leases an available bank, uploads colors, and returns the assigned bank index.

---

## 6. References & Cross-Links

- **Features Plan**: [`docs/features.md`](features.md)
- **Demo Documentation**: [`docs/demo.md`](demo.md)
- **Engine Sprites**: `src/engine/sprite.zig`
- **VRAM Allocator**: `src/engine/gfx2d/vram_allocator.zig`
