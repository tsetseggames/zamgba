# Post-Mortem & Deep Dive: Issue #39 - `irqHandler` Alignment in Debug Builds

## Executive Summary

- **Bug Symptom**: In Debug builds (`zig build`), `demo/engine/sprite_animation_streaming.gba` booted to a black screen and hung in an infinite reset loop on the mGBA emulator. Under `--release=fast`, the identical ROM executed properly.
- **Root Cause**: The hardware IRQ entry point `irqHandler` in `src/hal/hal.zig` contains 32-bit ARM instructions. Because the build target is `thumb-freestanding-none` (`thumbv4t`), the linker placed `irqHandler` at a 2-byte aligned address (`0x0802B89E`) rather than a strict 4-byte boundary. The assembler emitted 2 bytes of padding to align the instruction stream, but the function symbol pointed to the padding. In ARM mode, unaligned execution corrupts PC-relative literal pool offset calculations and triggers ARMv4T unaligned word rotation (`0x03007FF8 ROR 16` -> `0x7FF80300`), crashing BIOS interrupt acknowledgement and forcing the emulator to reboot continuously.
- **Resolution**: Added a dedicated `.gba.irq` section to `src/hal/gba.ld` guarded by `. = ALIGN(4);`, and bound `irqHandler` explicitly to this section via `linksection(".gba.irq")`.

---

## 1. Technical Context: GBA BIOS & ARM7TDMI Interrupt Dispatch

The Game Boy Advance CPU is an **ARM7TDMI** processor with two instruction sets:
1. **ARM state**: 32-bit instructions, 4-byte aligned (`pc[1:0] == 00`).
2. **Thumb state**: 16-bit instructions, 2-byte aligned (`pc[0] == 0`).

### 1.1 Hardware Interrupt Transition
When a hardware interrupt (such as VBlank, HBlank, or DMA) fires:
1. The CPU hardware core automatically switches to **ARM state** (CPSR `T` bit is cleared to 0) and enters IRQ mode (`0x12`).
2. Execution vectors to the GBA BIOS IRQ dispatcher at `0x00000124`.
3. The BIOS handler looks up the user ISR pointer registered at `USER_IRQ_HANDLER` (`0x03007FFC`).
4. The BIOS invokes the user ISR via an indirect branch (`mov pc, r0` or `ldr pc, [r0]`).

### 1.2 The ARMv4T Mode Switch Limitation
Under the ARMv4T architecture:
- **`bx <reg>`** inspects Bit 0 of the destination address to switch between ARM (bit 0 = 0) and Thumb (bit 0 = 1).
- **`mov pc, <reg>`** and **`ldr pc, [...]` do NOT switch processor state**. They unconditionally branch in the current processor mode (ARM), ignoring bit 0.

Therefore, when the GBA BIOS enters `USER_IRQ_HANDLER`, the CPU is **guaranteed to be in 32-bit ARM mode**.

---

## 2. Why `irqHandler` Must Use ARM Instructions

Writing the top-level interrupt service routine in Thumb mode requires an ARM-to-Thumb trampoline stub:

```arm
.arm
    bx lr_thumb_target    @ Switch from ARM to Thumb mode
.thumb
    @ ... execute handler ...
    bx lr                 @ Switch back to ARM mode
```

This round-trip state transition adds CPU cycle overhead. In Zamgba, the VBlank ISR only performs three hardware register operations:
1. Read hardware interrupt flags from `REG_IF` (`0x04000202`).
2. Acknowledge the interrupt by writing the flags back to `REG_IF`.
3. OR the acknowledged flags into the BIOS interrupt mirror `BIOS_IF` (`0x03007FF8`) so BIOS calls like `VBlankIntrWait()` resume.

Executing this in ~10 native ARM instructions takes under 15 clock cycles without state-switching trampolines. Hence, `irqHandler` is written directly in `.arm` inline assembly.

---

## 3. Dissecting the Bug: The 2-Byte Alignment Trap

### 3.1 Unaligned Function Address
The Zamgba codebase is compiled targeting `thumb-freestanding-none`. By default, functions in the general `.text` section are only guaranteed 2-byte alignment (`ALIGN(2)`).

In Debug builds (`zig build`):
- `irqHandler` was placed at `0x0802B89E` (aligned to 2 bytes, but not 4 bytes).
- Because the inline assembly contains `.arm` instructions, the GNU assembler / LLVM MC engine recognized that 32-bit ARM instructions require 4-byte alignment, so it inserted 2 bytes of padding (`00 00`) before the first instruction (`push {r4, lr}`).
- However, the symbol `irqHandler` was defined at `0x0802B89E` (pointing directly at the padding).
- When the code registered the handler into `USER_IRQ_HANDLER`:
  ```zig
  hal.MemorySections.USER_IRQ_HANDLER.* = &hal.irqHandler;
  ```
  The pointer was written as `0x0802B89E` (or `0x0802B89F` with Thumb bit set).

### 3.2 Unaligned ARM Instruction Execution & ROR Rotation
When the BIOS executed `mov pc, r0` to jump to `0x0802B89E` in ARM mode:
1. `pc[1]` was set to 1.
2. The CPU executed the padding bytes as an invalid or unexpected instruction.
3. Subsequent PC-relative literal pool loads (`ldr r1, =0x03007FF8`) calculated literal pool offsets relative to an unaligned PC.
4. On ARMv4T processors, an unaligned 32-bit memory load performs **data rotation by `(address & 3) * 8` bits**:
   $$\text{Address } 0x03007FF8 \text{ rotated by } 16 \text{ bits} \implies 0x7FF80300$$
5. The CPU attempted to read and write from `0x7FF80300` instead of `0x03007FF8`.
6. mGBA debug log reported:
   ```text
   Bad memory Load16: 0x7FF80300
   Bad memory Store16: 0x7FF80300
   ```
7. Because `BIOS_IF` was never acknowledged, `VBlankIntrWait` hung forever or triggered an unhandled exception loop, resulting in a black screen.

### 3.3 Why ReleaseFast Appeared to Work
In `--release=fast` builds, dead-code elimination, inlining, and different code layout coincidentally positioned `irqHandler` at `0x08000BAC`—which happened to be a multiple of 4. As a result, no padding was inserted, literal pool addresses evaluated cleanly, and the handler executed without issue.

---

## 4. Architectural Resolution

### 4.1 Linker Script Enforcement (`src/hal/gba.ld`)
We established a dedicated linker output section `.gba.irq` inside `.text` immediately after `.gba.boot`, strictly preceded by a 4-byte alignment directive:

```ld
        . = ALIGN(4);
        *(.gba.boot)
        . = ALIGN(4);
        KEEP(*(.gba.irq))
        *(.text*)
```

### 4.2 Explicit Section Binding (`src/hal/hal.zig`)
We bound `irqHandler` to the `.gba.irq` section with naked calling convention to ensure zero compiler prologue interference:

```zig
pub fn irqHandler() linksection(".gba.irq") callconv(.naked) void {
    asm volatile (
        \\.arm
        \\push {r4, lr}
        \\ldr r0, =0x04000202
        \\ldrh r2, [r0]
        \\strh r2, [r0]
        \\ldr r1, =0x03007FF8
        \\ldrh r3, [r1]
        \\orr r3, r3, r2
        \\strh r3, [r1]
        \\pop {r4, lr}
        \\bx lr
    );
}
```

### 4.3 Verification
1. Inspecting the compiled binary via `llvm-objdump -t zig-out/bin/sprite_animation_streaming` confirms `irqHandler` is strictly placed at a 4-byte boundary.
2. Verified with mGBA in debug builds: clean boot, active VBlank interrupt servicing, DMA queue transfers operating every frame without memory faults.
