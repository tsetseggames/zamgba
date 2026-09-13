const std = @import("std");
const gba = @import("zamgba");
const hal = gba.hal;

pub const panic = gba.panic;

// The standard ROM header for the GBA BIOS
export var gameHeader linksection(".gba.header") = hal.setupROMHeader(
    "MGBAINIT",
    "AMGI",
    "00",
    0,
);

const REG_DEBUG_ENABLE = @as(*volatile u16, @ptrFromInt(0x04FFF780));
const MGBA_ENABLE_MAGIC: u16 = 0xC0DE;
const MGBA_RESPONSE_MAGIC: u16 = 0x1DEA;

export fn main() noreturn {
    // 1. Read initial state before handshake
    const initial_val = REG_DEBUG_ENABLE.*;

    // 2. Perform mGBA handshake by writing 0xC0DE ("CODE")
    REG_DEBUG_ENABLE.* = MGBA_ENABLE_MAGIC;

    // 3. Read back value after handshake (expected 0x1DEA "IDEA")
    const readback_val = REG_DEBUG_ENABLE.*;

    // 4. Format and output diagnostics via mGBA log port
    const msg1 = std.fmt.bufPrint(
        &hal.mgba.log.format_buf,
        "mGBA init test: initial=0x{X:0>4}, readback=0x{X:0>4}",
        .{ initial_val, readback_val },
    ) catch unreachable;
    hal.mgba.log.write(.info, msg1);

    if (readback_val == MGBA_RESPONSE_MAGIC) {
        hal.mgba.log.write(.info, "Result: Matched MGBA_RESPONSE_MAGIC (0x1DEA 'IDEA')");
    } else {
        const msg2 = std.fmt.bufPrint(
            &hal.mgba.log.format_buf,
            "Result: Unexpected readback (expected 0x1DEA, got 0x{X:0>4})",
            .{readback_val},
        ) catch unreachable;
        hal.mgba.log.write(.warn, msg2);
    }

    // 5. Test hal.mgba.log.isRunOnMgba() helper
    const running_on_mgba = hal.mgba.log.isRunOnMgba();
    const msg3 = std.fmt.bufPrint(
        &hal.mgba.log.format_buf,
        "isRunOnMgba() status: {}",
        .{running_on_mgba},
    ) catch unreachable;
    hal.mgba.log.write(.info, msg3);

    hal.mgba.log.write(.info, "Direct MMIO log write verified successfully.");

    // 6. Infinite loop
    while (true) {}
}
