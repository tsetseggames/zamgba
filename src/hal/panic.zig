const std = @import("std");
const specs = @import("specs.zig");
const mgba = @import("mgba/log.zig");

/// Low-level bare-metal panic handler for GBA and freestanding environments.
///
/// Lifecycle:
/// 1. Immediately disables hardware interrupts (REG_IME = 0) to avoid ISR interference.
/// 2. Formats the panic message and return address (PC) into the shared HAL static buffer (0 bytes on stack).
/// 3. Sets the hardware backdrop color to RED (0x001F) for visual identification on hardware.
/// 4. Emits a FATAL message to the mGBA emulator debug port (terminates emulator VM).
/// 5. Hangs in an infinite loop (bare-metal hardware fallback).
pub fn panic(
    msg: []const u8,
    _: ?*std.builtin.StackTrace,
    ret_addr: ?usize,
) noreturn {
    if (specs.is_gba_target) {
        // Step 1: Disable all hardware interrupts immediately
        specs.MemorySections.REG_IME.* = 0;

        // Step 2: Format panic message and program counter safely into shared static buffer
        const formatted = if (ret_addr) |addr|
            std.fmt.bufPrint(&mgba.format_buf, "PANIC: {s} (pc: 0x{X:0>8})", .{ msg, addr }) catch |err| switch (err) {
                error.NoSpaceLeft => mgba.format_buf[0..],
            }
        else
            std.fmt.bufPrint(&mgba.format_buf, "PANIC: {s}", .{msg}) catch |err| switch (err) {
                error.NoSpaceLeft => mgba.format_buf[0..],
            };

        // Step 3: Turn background color red as visual indicator on hardware
        specs.MemorySections.PALRAM[0] = specs.Color.RED;

        // Step 4: Flush message to mGBA fatal log port if mGBA debug interface is available
        if (mgba.init()) {
            mgba.write(.fatal, formatted);
        }

        // Step 5: Hang execution
        while (true) {}
    } else {
        while (true) {}
    }
}
