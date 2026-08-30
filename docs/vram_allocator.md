# VRAM Buddy Allocator & Tile Memory Management

This document details the architecture, mathematical algorithms, data structures, and cross-layer concepts of the **Zero-Heap Bitwise Buddy Allocator** (`src/engine/vram_allocator.zig`) in Zamgba.

---

## 1. Overview and Hardware Physical Layout

GBA Video RAM (VRAM) has a total size of 96 KB. Under Tile Modes (Mode 0, 1, 2) with 1D OBJ Mapping enabled (`REG_DISPCNT` Bit 6 = 1):
- **OBJ VRAM Range**: `0x06010000` to `0x06017FFF` (Character Blocks 4 and 5), providing strictly **32 KB** of Sprite tile storage.
- **Hardware Tile Unit**: In GBA hardware OAM Attribute 2 (`attr2`), the 10-bit `tile_index` (bits 0–9) steps in units of **32 bytes** (the size of one 4-bpp 8x8 tile).
- **Total Capacity**: Exactly **1024 base 32-byte slot units**.

```
0x06010000                                                         0x06017FFF
+---------------------------------------------------------------------------+
| Slot 0 (32B) | Slot 1 (32B) | Slot 2 (32B) | ... | Slot 1023 (32B)        |
+---------------------------------------------------------------------------+
| <-------------------------- 1024 Tile Units (32 KB) --------------------> |
```

---

## 2. Unification of 4-Bpp and 8-Bpp Sprite Allocations

In 1D OBJ mapping, sprite dimensions naturally translate into power-of-2 ($2^N$) 32-byte slot units:

| Sprite Dimension | Pixel Count | 4-bpp Footprint (32B/tile) | 8-bpp Footprint (64B/tile) | Buddy Order ($2^N$) |
| :--- | :--- | :--- | :--- | :--- |
| **8x8** | 64 | 32 B = **1 unit** | 64 B = **2 units** | Order 0 (4-bpp) / Order 1 (8-bpp) |
| **16x16** | 256 | 128 B = **4 units** | 256 B = **8 units** | Order 2 (4-bpp) / Order 3 (8-bpp) |
| **32x32** | 1024 | 512 B = **16 units** | 1024 B = **32 units** | Order 4 (4-bpp) / Order 5 (8-bpp) |
| **64x64** | 4096 | 2048 B = **64 units** | 4096 B = **128 units** | Order 6 (4-bpp) / Order 7 (8-bpp) |

* **Formula**:
  $$\text{Units} = \begin{cases} (\text{width} \times \text{height}) / 64 & \text{if 4-bpp} \\ (\text{width} \times \text{height}) / 32 & \text{if 8-bpp} \end{cases}$$
* **Order Mapping**: `unitsToOrder(units)` computes $\text{order} = 16 - \text{@clz}(\text{units} - 1)$ using compiler intrinsics with zero runtime division.

---

## 3. Data Structures and Zero-Heap Design

All allocator metadata is statically allocated in `.bss` (~6 KB total memory) without any dynamic heap usage:

```zig
const BlockNode = struct {
    order: u4 = 0,         // Order of block (0..10, representing 2^order units)
    is_free: bool = false, // Allocation status
    next: i16 = -1,        // Index of next free block in doubly-linked list
    prev: i16 = -1,        // Index of previous free block in doubly-linked list
};

var nodes: [1024]BlockNode = undefined; // Per-unit metadata
var free_lists: [11]i16 = undefined;    // Head index for Orders 0..10 (-1 if empty)
var free_tile_count: u16 = 1024;        // Available units counter
```

---

## 4. Allocation & Coalescing Algorithms

### A. Allocation (`alloc` / `allocUnits`)
1. **Target Order**: `target_order = unitsToOrder(units)`.
2. **Search**: Scan `free_lists[target_order..10]` to find the smallest available order $\ge \text{target\_order}$.
3. **Buddy Splitting**: Pop the block from `free_lists[order]`. Repeatedly bisect the block downwards:
   $$\text{buddy\_index} = \text{block\_index} + (1 \ll (\text{order} - 1))$$
   Push the right buddy into `free_lists[order - 1]` and continue until `order == target_order`.
4. **Result**: Return `VramAllocation{ .tile_index, .tile_count, .byte_offset }`.

```
Order 10: [0 ----------------------------------------------------------- 1023]
                                   │ Split
Order 9:  [0 --------------- 511]                 [512 ---------- 1023] (Saved)
                   │ Split
Order 8:  [0 ----- 255]          [256 ----- 511] (Saved)
              │ ...
Order 2:  [0..3] (Allocated)  +  [4..7] (Saved for next 4-unit request)
```

### B. Deallocation and XOR-Based Coalescing (`free`)
1. **Locate Buddy via XOR**:
   $$\text{buddy\_index} = \text{current\_index} \oplus (1 \ll \text{current\_order})$$
   *Example*: Block 0 (Order 2) has buddy $0 \oplus 4 = 4$.
2. **Coalesce Check**: If `nodes[buddy_index]` is free and has identical `order`:
   - Detach buddy from `free_lists[current_order]`.
   - Merge into $\text{new\_index} = \min(\text{current\_index}, \text{buddy\_index})$ with $\text{order} = \text{current\_order} + 1$.
   - Cascade check upwards until an occupied buddy or `MAX_ORDER` is reached.
3. **Insert**: Push the coalesced block into `free_lists[order]`.

---

## 5. Cross-Layer Concepts: HAL vs. Engine

| Concept | HAL Layer (`zamgba-hal`) | Engine Layer (`zamgba-engine`) |
| :--- | :--- | :--- |
| **Physical VRAM Base** | `hal.specs.MemorySections.VRAM + 32768` (`0x06010000`, `[*]volatile u16`) | `alloc_info.toVramPointer(base_vram)` |
| **Tile Definition** | `hal.oam.Tile` (`BYTES_4BPP = 32`, `BYTES_8BPP = 64`) | `engine.SpriteSheet.tiles_per_frame` |
| **Slot Descriptor** | Hardware `ObjAttr.attr2` (`tile_index: u10`) | `engine.vram_allocator.VramAllocation` |
| **Sprite Association**| Raw `attr2` bit manipulation (`attr2 |= tile_index`) | `engine.Sprite.tile_index = alloc_info.tile_index` |
| **Animation Streaming** | Bare-metal `hal.dma.copy32` during VBlank | `AnimatedSprite` dynamically rewriting its fixed `VramAllocation` slot |

---

## 6. Direct Tile Management in HAL Layer

The HAL layer is deliberately **stateless** and does not provide dynamic memory heaps. However, it exposes direct, zero-overhead primitives for low-level ROM demos and custom engines:

### 1. Direct Memory Sections
```zig
const hal = @import("zamgba").hal;

// 1. Point directly to OBJ VRAM base (0x06010000)
// Since VRAM is a [*]volatile u16 pointer, 32768 words = 65536 bytes offset
const obj_vram: [*]volatile u16 = hal.MemorySections.VRAM + 32768;

// 2. Compute exact tile destination address (1 tile = 16 u16 words = 32 bytes)
const tile_dest_ptr = obj_vram + (tile_index * 16);
```

### 2. High-Speed DMA Hardware Transfers
```zig
// Copy raw 32-bit tile words from ROM to specific VRAM tile index via DMA 3
try hal.dma.copy32(
    .ch3,
    @as([*]volatile u32, @ptrCast(@alignCast(tile_dest_ptr))),
    @as([*]const u32, @ptrCast(@alignCast(raw_tile_data.ptr))),
    words_count,
);

// Clear a specific VRAM tile block to index 0 using DMA fill
try hal.dma.fill32(.ch3, @as([*]volatile u32, @ptrCast(@alignCast(tile_dest_ptr))), 0, words_count);
```

### 3. Direct OAM Binding
```zig
// Bind the tile index to OAM Attribute 2
var attr: hal.oam.ObjAttr = undefined;
attr.attr2 = tile_index; // Bits 0..9 set the base tile index
```
