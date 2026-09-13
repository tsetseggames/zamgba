const std = @import("std");
const specs = @import("../specs.zig");

pub const LogLevel = enum(u3) {
    fatal = 0,
    err = 1,
    warn = 2,
    info = 3,
    debug = 4,
};

pub const BUFFER_SIZE: usize = 128;

/// Module-level static buffer for string formatting in log and panic handlers.
/// Sharing a single static buffer in HAL eliminates stack allocations during panic
/// and avoids IWRAM stack exhaustion.
pub var format_buf: [BUFFER_SIZE]u8 = undefined;

const REG_DEBUG_STRING = @as([*]volatile u8, @ptrFromInt(0x04FFF600));
const REG_DEBUG_FLAGS = @as(*volatile u16, @ptrFromInt(0x04FFF700));
const REG_DEBUG_ENABLE = @as(*volatile u16, @ptrFromInt(0x04FFF780));

const MGBA_ENABLE_MAGIC: u16 = 0xC0DE;
const MGBA_RESPONSE_MAGIC: u16 = 0x1EA0;
const MGBA_SEND_FLAG: u16 = 0x0100;

/// Attempts to handshake with mGBA debug registers.
pub fn init() bool {
    if (comptime !specs.is_gba_target) return false;
    REG_DEBUG_ENABLE.* = MGBA_ENABLE_MAGIC;
    return REG_DEBUG_ENABLE.* == MGBA_RESPONSE_MAGIC;
}

/// Checks if mGBA debug interface is supported.
pub fn isSupported() bool {
    if (comptime !specs.is_gba_target) return false;
    return REG_DEBUG_ENABLE.* == MGBA_RESPONSE_MAGIC;
}

/// Writes raw message slice directly to mGBA hardware registers if interface is supported.
pub fn write(level: LogLevel, message: []const u8) void {
    if (comptime !specs.is_gba_target) return;
    if (!isSupported()) return;

    const max_len = 255;
    const copy_len = @min(message.len, max_len);
    for (0..copy_len) |i| {
        REG_DEBUG_STRING[i] = message[i];
    }
    REG_DEBUG_STRING[copy_len] = 0;
    REG_DEBUG_FLAGS.* = MGBA_SEND_FLAG | @intFromEnum(level);
}

// ==================================================================
// Unit Tests (Strict TDD format)
// ==================================================================

test "MGB001: LogLevel enum values and bit encoding" {
    try std.testing.expectEqual(@as(u3, 0), @intFromEnum(LogLevel.fatal));
    try std.testing.expectEqual(@as(u3, 1), @intFromEnum(LogLevel.err));
    try std.testing.expectEqual(@as(u3, 2), @intFromEnum(LogLevel.warn));
    try std.testing.expectEqual(@as(u3, 3), @intFromEnum(LogLevel.info));
    try std.testing.expectEqual(@as(u3, 4), @intFromEnum(LogLevel.debug));
}

test "MGB002: Host safety checks for unmapped GBA hardware operations" {
    // On host test targets, all hardware register operations must safely compile-time no-op
    try std.testing.expect(!init());
    try std.testing.expect(!isSupported());
    write(.info, "Safe host no-op");
}
