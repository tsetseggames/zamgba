const specs = @import("specs.zig");

/// GBA button bitmask
pub const Key = enum(u16) {
    A = 1 << 0,
    B = 1 << 1,
    Select = 1 << 2,
    Start = 1 << 3,
    Right = 1 << 4,
    Left = 1 << 5,
    Up = 1 << 6,
    Down = 1 << 7,
    R = 1 << 8,
    L = 1 << 9,
};

/// Read button status from hardware register
/// Note: GBA hardware sets pressed as 0 and released as 1.
/// We invert the bits so that pressed is 1.
pub fn readRaw() u16 {
    const raw = specs.MemorySections.REG_KEYINPUT.*;
    return (~raw) & specs.MemorySections.KEY_MASK;
}
