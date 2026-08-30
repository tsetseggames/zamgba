# Fixed-Point Number Design for GBA (`Fixed24_8`)

This document explains the design principles, performance considerations, and usage of the 24.8 fixed-point arithmetic structure (`Fixed24_8`) in Zamgba.

---

## 1. Overview and Architecture

GBA uses an **ARM7TDMI** processor without a Floating-Point Unit (FPU). Any standard 32-bit floating-point operation (`f32`) incurs heavy software emulation (`__aeabi_fadd`, `__aeabi_fmul`, etc.) costing tens to hundreds of CPU cycles per calculation.

To achieve high-performance physics and collision detection, Zamgba uses a fixed-point representation:
- **Underlying Type**: `i32` (32-bit signed two's complement integer).
- **Format**: `Fixed24_8`
  - High 24 bits (Bits 8–31): Signed integer part (range: $-8,388,608$ to $+8,388,607$).
  - Low 8 bits (Bits 0–7): Fractional part ($1 / 256 \approx 0.00390625$ resolution).

```
 31                          8 7         0
+-----------------------------+-----------+
|    Signed Integer (24 bits) | Frac (8b) |
+-----------------------------+-----------+
```

---

## 2. Preventing Runtime Floating-Point Overhead

### The Problem
Allowing dynamic float conversion at runtime (e.g. `Fixed24_8.fromFloat(dynamic_f32)`) risks silently pulling in compiler soft-float libraries and burning frame cycles.

### The Solution: Comptime-Guaranteed Literals
Zig provides the `comptime` parameter qualifier. By constraining the constructor parameter to `comptime f: comptime_float`, the conversion is strictly evaluated at compile time:

```zig
pub fn fromFloat(comptime f: comptime_float) Fixed24_8 {
    return .{ .raw = @as(i32, @intFromFloat(f * @as(comptime_float, scale))) };
}
```

#### Detailed Breakdown of `@as(i32, @intFromFloat(f * @as(comptime_float, scale)))`
1. `scale` is defined as `1 << 8` (`256`).
2. `@as(comptime_float, scale)` coerces the integer `256` into a compile-time float `256.0` to satisfy Zig's strict type-matching for floating-point arithmetic.
3. `f * 256.0` scales the float value into fixed-point representation (e.g., `3.5 * 256.0 = 896.0` or `-1.5 * 256.0 = -384.0`).
4. `@intFromFloat(...)` converts the compile-time float to a signed integer.
5. `@as(i32, ...)` coerces the compile-time integer literal into an `i32` for storing in `.raw`.
6. Because all inputs are `comptime`, LLVM folds this entire expression into a single immediate constant (e.g. `896` / `0x380`) during compilation, resulting in **zero** runtime instructions.

---

## 3. Fractional Representation and Calculation Rules

In `Fixed24_8`, the low 8 bits represent fractional increments.
An 8-bit unsigned integer ranges from `0` to `255`, dividing `1.0` into **256 discrete steps** ($\frac{1}{256} = 0.00390625$).

$$\text{Fraction Counter (Low 8 Bits)} = \text{Decimal Part} \times 256$$

### Why $128$ Represents $0.5$
$$0.5 \times 256 = 128 \implies 3.5 = (3 \ll 8) + 128 = 896$$

### Bit Weight Table (Powers of Two)
Each bit in the 8-bit fraction field corresponds to a negative power of 2 ($2^{-n}$):

| Bit Position | Fractional Weight | Decimal Weight | Raw Counter Value | Hex Value |
| :--- | :--- | :--- | :--- | :--- |
| **Bit 7 (MSB)** | $1/2$ | **0.5** | **128** | `0x80` |
| **Bit 6** | $1/4$ | **0.25** | **64** | `0x40` |
| **Bit 5** | $1/8$ | **0.125** | **32** | `0x20` |
| **Bit 4** | $1/16$ | **0.0625** | **16** | `0x10` |
| **Bit 3** | $1/32$ | **0.03125** | **8** | `0x08` |
| **Bit 2** | $1/64$ | **0.015625** | **4** | `0x04` |
| **Bit 1** | $1/128$ | **0.0078125** | **2** | `0x02` |
| **Bit 0 (LSB)** | $1/256$ | **0.00390625** | **1** | `0x01` |

### Common Values Quick Reference

| Decimal | Fraction Formula | Calculation | Raw Byte (8-bit) |
| :--- | :--- | :--- | :--- |
| **0.5** | $1/2$ | $128$ | `128` (`0x80`) |
| **0.25** | $1/4$ | $64$ | `64` (`0x40`) |
| **0.75** | $3/4$ | $128 + 64$ | `192` (`0xC0`) |
| **0.125** | $1/8$ | $32$ | `32` (`0x20`) |
| **0.375** | $3/8$ | $64 + 32$ | `96` (`0x60`) |
| **0.625** | $5/8$ | $128 + 32$ | `160` (`0xA0`) |
| **0.875** | $7/8$ | $128 + 64 + 32$ | `224` (`0xE0`) |

### Universal Formula for Any Decimal
To convert an arbitrary decimal value $0.x$:
$$\text{fraction} = \text{round}(0.x \times 256)$$
- **Example for $0.1$**: $0.1 \times 256 = 25.6 \approx 26$ ($26 / 256 = 0.1015625$)
- **Example for $0.33$**: $0.33 \times 256 = 84.48 \approx 84$ ($84 / 256 = 0.328125$)

---

## 4. Alternative Construction Methods

For runtime values where fractions or parts are computed from integers:

- **`fromParts(integer: i32, fraction: u8)`**: Combines an integer and an 8-bit fraction counter with proper sign handling.
- **`fromFraction(integer: i32, num: i32, den: i32)`**: Constructs value from rational numbers (e.g. `fromFraction(3, 1, 2)` for $3 + \frac{1}{2}$, using `@divTrunc`).
- **`fromInt(i: i32)`**: Simple whole integer constructor (`i << 8`).
- **`Fixed24_8.zero`**: Constant for $0.0$.
- **`neg()`**: Negates a value (`-self.raw`).

---

## 5. Assignment, Passing, and Memory Semantics

### Direct Assignment (`=`)
Because `Fixed24_8` wraps a single 32-bit field (`raw: i32`), instances can and should be copied using standard assignment:

```zig
var a = Fixed24_8.fromFloat(3.5);
var b: Fixed24_8 = a; // Direct copy
```

### Efficiency on ARM7TDMI
1. **Single-Cycle Copy**:
   A 32-bit value fits exactly into an ARM core register (`r0`–`r12`). Copying values between variables compiles into a single instruction (`mov r1, r0` or `ldr`/`str`), requiring only 1 clock cycle.
2. **Pass by Value**:
   Functions accept `Fixed24_8` parameters by value instead of pointers. Per the ARM Architecture Procedure Call Standard (AAPCS), up to 4 arguments are passed directly in registers `r0`–`r3` without memory or pointer dereference overhead:
   ```zig
   pub fn add(self: Fixed24_8, other: Fixed24_8) Fixed24_8 {
       return .{ .raw = self.raw + other.raw };
   }
   ```
3. **Batch Copying**:
   When copying slices or arrays of `Fixed24_8`, use `@memcpy`:
   ```zig
   @memcpy(dest_slice, src_slice);
   ```

---

## 6. From Unsigned to Signed: Design Decisions & Screen Impact

In earlier versions of Zamgba, `Fixed24_8` was represented as an unsigned integer (`raw: u32`). Moving to a fully signed `raw: i32` representation resolved fundamental architectural trade-offs:

### 1. Unified Velocity & Position Model
- **Problem**: Velocity components (`velocity_x`, `velocity_y`) are inherently signed vectors (e.g., `-1.5` pixels/frame when moving left or up). With unsigned `Fixed24_8`, velocity had to be kept as raw `i32` with manual bit shifts (`vx >> 8`), creating semantic duplication and risk of mixing raw pixel integers with fixed-point integers.
- **Solution**: `Sprite.velocity_x` and `velocity_y` are now typed as `Fixed24_8`. Both positions and velocities use identical arithmetic methods (`.add()`, `.sub()`, `.mul()`, `.div()`, `.neg()`), catching unit mismatches at compile time.

### 2. Direction Flipping & Wall Bouncing
- Inverting movement direction on wall collisions or input flips now executes via `.neg()` (`enemy.velocity_y = enemy.velocity_y.neg()`).
- On ARM7TDMI, negating a 32-bit signed register is a single-cycle instruction (`rsb r0, r0, #0` or `neg`), avoiding branching and absolute value conversions.

### 3. Screen Coordinate & OAM Hardware Mapping
Converting `Fixed24_8` to integer screen coordinates (`toInt()`) uses arithmetic right shift (`raw >> 8` / `ASR` on ARM):
- **Positive Coordinates (On-screen)**: `toInt()` maps directly to the integer pixel grid with sub-pixel truncation.
- **Negative Coordinates (Entering/Exiting Screen)**: Two's complement arithmetic right shift computes floor division (`floor(x)`), mapping $[-0.5, 0.0)$ consistently to $-1\text{px}$.
- **GBA OAM Register Alignment**:
  ```zig
  const y_hw: u16 = @as(u16, @bitCast(@as(i16, @truncate(y_val)))) & 0x00FF; // 8-bit wrap (0..255)
  const x_hw: u16 = @as(u16, @bitCast(@as(i16, @truncate(x_val)))) & 0x01FF; // 9-bit wrap (0..511)
  ```
  The GBA OBJ hardware wraps negative coordinates smoothly around screen boundaries (e.g. $X = -8 \implies 504$ in 9-bit coordinates). Floor rounding ensures continuous, jitter-free sprite entry from the left and top screen borders.
