# Fixed-Point Number Design for GBA (`Fixed24_8`)

This document explains the design principles, performance considerations, and usage of the 24.8 fixed-point arithmetic structure (`Fixed24_8`) in Zamgba.

---

## 1. Overview and Architecture

GBA uses an **ARM7TDMI** processor without a Floating-Point Unit (FPU). Any standard 32-bit floating-point operation (`f32`) incurs heavy software emulation (`__aeabi_fadd`, `__aeabi_fmul`, etc.) costing tens to hundreds of CPU cycles per calculation.

To achieve high-performance physics and collision detection, Zamgba uses a fixed-point representation:
- **Underlying Type**: `u32` (32 bits unsigned integer).
- **Format**: `Fixed24_8`
  - High 24 bits (Bits 8–31): Integer part.
  - Low 8 bits (Bits 0–7): Fractional part ($1 / 256 \approx 0.00390625$ resolution).

```
 31                          8 7         0
+-----------------------------+-----------+
|        Integer (24 bits)    | Frac (8b) |
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
    return .{ .raw = @as(u32, @intFromFloat(f * @as(comptime_float, scale))) };
}
```

#### Detailed Breakdown of `@as(u32, @intFromFloat(f * @as(comptime_float, scale)))`
1. `scale` is defined as `1 << 8` (`256`).
2. `@as(comptime_float, scale)` coerces the integer `256` into a compile-time float `256.0` to satisfy Zig's strict type-matching for floating-point arithmetic.
3. `f * 256.0` scales the float value into fixed-point representation (e.g., `3.5 * 256.0 = 896.0`).
4. `@intFromFloat(...)` converts the compile-time float `896.0` to an integer `896`.
5. `@as(u32, ...)` coerces the compile-time integer literal `896` into a standard `u32` for storing in `.raw`.
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

- **`fromParts(integer: u32, fraction: u8)`**: Directly combines an integer and an 8-bit fraction counter (`(integer << 8) | fraction`).
- **`fromFraction(integer: u32, num: u32, den: u32)`**: Constructs value from rational numbers (e.g. `fromFraction(3, 1, 2)` for $3 + \frac{1}{2}$).
- **`fromInt(i: u32)`**: Simple whole integer constructor (`i << 8`).

---

## 5. Assignment, Passing, and Memory Semantics

### Direct Assignment (`=`)
Because `Fixed24_8` wraps a single 32-bit field (`raw: u32`), instances can and should be copied using standard assignment:

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
