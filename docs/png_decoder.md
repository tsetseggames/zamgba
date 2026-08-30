# PNG Decoder Architecture and Design Decisions

`zurag` contains a dedicated, zero-dependency PNG decoder tailored specifically for Aseprite-exported indexed-color sprite sheets. This document explains the internal decoding pipeline, GBA hardware alignment rules, and design trade-offs.

---

## 1. Design Purpose & Architectural Trade-offs

### Zero-Dependency Philosophy
The primary design goal of the `zurag` PNG decoder is **100% pure Zig implementation** using only Zig's standard library (`std.compress.flate`). 
* It eliminates all external dependencies (such as `libpng`, `zlib.h`, `stb_image`, Python, or ImageMagick).
* It compiles out-of-the-box across Windows, Linux, and macOS without requiring system development headers or C compilers.

### Performance Trade-off Acknowledgement
Because this decoder is designed for clarity, safety, and zero external baggage, it is **not** as heavily optimized or SIMD-vectorized as dedicated industry C libraries like `libpng` or `libspng`. 
However, because GBA sprite sheets and retro tiles are relatively small (typically under 512x512 pixels), decoding takes only a few milliseconds during offline compilation, making this trade-off ideal for the `zamgba` build workflow.

---

## 2. The Decoding Pipeline

Decoding an indexed-color PNG follows a strict four-stage pipeline:

```
+-------------------------------------------------------------------------------+
| 1. Header & Signature (IHDR Chunk)                                            |
|    - Verify 8-byte PNG signature                                              |
|    - Validate Color Type == 3 (Indexed-color) and bit depth (8-bit / 4-bit)   |
+-------------------------------------------------------------------------------+
                                      │
                                      ▼
+-------------------------------------------------------------------------------+
| 2. Palette Extraction (PLTE Chunk)                                            |
|    - Extract RGB triplets (up to 256 colors)                                  |
|    - Convert RGB888 to GBA 15-bit BGR555 colors                               |
+-------------------------------------------------------------------------------+
                                      │
                                      ▼
+-------------------------------------------------------------------------------+
| 3. IDAT Concatenation & Zlib Inflation                                         |
|    - Sequentially concatenate payloads from all IDAT chunks                   |
|    - Inflate the zlib-compressed bitstream using std.compress.flate           |
+-------------------------------------------------------------------------------+
                                      │
                                      ▼
+-------------------------------------------------------------------------------+
| 4. Scanline Unfiltering (5 Filter Types)                                      |
|    - Reverse byte delta filters: None (0), Sub (1), Up (2), Average (3),     |
|      and Paeth (4) using previous row and previous pixel contexts             |
|    - Produce a clean 2D pixel index matrix                                    |
+-------------------------------------------------------------------------------+
```

---

## 3. Handling Ancillary Chunks & GBA Compatibility

According to the W3C PNG specification, PNG files may contain auxiliary/ancillary chunks (such as `tRNS`, `bKGD`, `sRGB`, `pHYs`, `gAMA`).

### Design Decision: Skipping `tRNS` and `bKGD`
* **GBA Hardware Constraint**: GBA PPU hardware strictly dictates that **Palette Index 0 is always the transparent color** for OBJ sprites.
* **Compatibility Choice**: `zurag` intentionally **ignores/skips** transparency overrides in `tRNS` chunks and background color redirects in `bKGD` chunks.
* **Developer Warning System**: While skipped, `zurag` tracks their presence via `PngAuxChunks` and outputs a diagnostic warning to `stderr`:
  ```text
  Warning: 'assets/player.png' contains a tRNS chunk which is ignored. GBA hardware enforces palette index 0 as transparent.
  ```

---

## 4. Submodule Organization

* **`tools/zurag/png.zig`**: Chunk scanner, header parser, palette extractor, and IDAT decompression driver.
* **`tools/zurag/algo/paeth.zig`**: Standalone implementation of the Paeth linear extrapolation predictor algorithm ($p = a + b - c$) with dedicated boundary tie-breaking tests.
* **`tools/zurag/algo/unfilter.zig`**: Generic scanline unfilter engine supporting None, Sub, Up, Average, and Paeth filter modes across all image scanlines.
