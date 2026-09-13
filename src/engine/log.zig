const std = @import("std");
const builtin = @import("builtin");
const hal = @import("zamgba-hal");

pub const LogLevel = hal.mgba.log.LogLevel;
pub const BUFFER_SIZE: usize = 256;

/// Mock function hook for host-side unit testing verification.
pub var mock_write_override: ?*const fn (level: LogLevel, message: []const u8) void = null;

/// Low-level static message writer.
/// On GBA hardware target, directly invokes mGBA hardware debug registers with zero runtime overhead.
/// On host machine, redirects to mock hook or host debug console.
pub fn write(level: LogLevel, message: []const u8) void {
    if (mock_write_override) |mock_fn| {
        mock_fn(level, message);
        return;
    }

    if (comptime hal.specs.is_gba_target) {
        hal.mgba.log.write(level, message);
    } else {
        if (comptime builtin.mode == .Debug and !builtin.is_test) {
            std.debug.print("[{s}] {s}\n", .{ @tagName(level), message });
        }
    }
}

/// Helper function to format strings to buffer with null-termination safely.
pub fn formatToBuf(buf: []u8, comptime fmt: []const u8, args: anytype) []const u8 {
    if (buf.len == 0) return "";
    const max_chars = buf.len - 1;
    const formatted = std.fmt.bufPrint(buf[0..max_chars], fmt, args) catch |e| switch (e) {
        error.NoSpaceLeft => buf[0..max_chars],
    };
    buf[formatted.len] = 0;
    return formatted;
}

/// Core logging dispatcher with compile-time zero-cost optimization in Release builds.
/// In non-Debug builds, log statements are completely eliminated with 0 bytes ROM footprint.
pub fn log(comptime level: LogLevel, comptime fmt: []const u8, args: anytype) void {
    if (comptime builtin.mode != .Debug) return;
    var buf: [BUFFER_SIZE]u8 = undefined;
    const formatted = formatToBuf(&buf, fmt, args);
    write(level, formatted);
}

pub inline fn debug(comptime fmt: []const u8, args: anytype) void {
    log(.debug, fmt, args);
}

pub inline fn info(comptime fmt: []const u8, args: anytype) void {
    log(.info, fmt, args);
}

pub inline fn warn(comptime fmt: []const u8, args: anytype) void {
    log(.warn, fmt, args);
}

pub inline fn err(comptime fmt: []const u8, args: anytype) void {
    log(.err, fmt, args);
}

pub inline fn fatal(comptime fmt: []const u8, args: anytype) void {
    log(.fatal, fmt, args);
}

pub inline fn print(comptime fmt: []const u8, args: anytype) void {
    log(.info, fmt, args);
}

// ==================================================================
// Unit Tests (Strict TDD format)
// ==================================================================

var test_last_msg: [BUFFER_SIZE]u8 = [_]u8{0} ** BUFFER_SIZE;
var test_last_len: usize = 0;
var test_last_level: ?LogLevel = null;

fn mockWriteCollector(level: LogLevel, message: []const u8) void {
    const len = @min(message.len, BUFFER_SIZE);
    @memcpy(test_last_msg[0..len], message[0..len]);
    test_last_len = len;
    test_last_level = level;
}

fn resetTestState() void {
    @memset(&test_last_msg, 0);
    test_last_len = 0;
    test_last_level = null;
    mock_write_override = null;
}

test "LOG001: Static logging dispatch across all levels" {
    resetTestState();
    mock_write_override = mockWriteCollector;
    defer resetTestState();

    debug("Debug trace: {s}", .{"vram"});
    try std.testing.expectEqualStrings("Debug trace: vram", test_last_msg[0..test_last_len]);
    try std.testing.expectEqual(LogLevel.debug, test_last_level.?);

    info("Info msg: count={d}", .{42});
    try std.testing.expectEqualStrings("Info msg: count=42", test_last_msg[0..test_last_len]);
    try std.testing.expectEqual(LogLevel.info, test_last_level.?);

    warn("Warning alert: {d} fps", .{30});
    try std.testing.expectEqualStrings("Warning alert: 30 fps", test_last_msg[0..test_last_len]);
    try std.testing.expectEqual(LogLevel.warn, test_last_level.?);

    err("Critical error: 0x{X}", .{0xDEAD});
    try std.testing.expectEqualStrings("Critical error: 0xDEAD", test_last_msg[0..test_last_len]);
    try std.testing.expectEqual(LogLevel.err, test_last_level.?);

    fatal("System halting: {s}", .{"OOM"});
    try std.testing.expectEqualStrings("System halting: OOM", test_last_msg[0..test_last_len]);
    try std.testing.expectEqual(LogLevel.fatal, test_last_level.?);
}

test "LOG002: formatToBuf bounds checking and null termination" {
    var buf: [32]u8 = undefined;

    const s1 = formatToBuf(&buf, "Count: {d}", .{100});
    try std.testing.expectEqualStrings("Count: 100", s1);
    try std.testing.expectEqual(@as(u8, 0), buf[s1.len]);

    const s2 = formatToBuf(&buf, "Long string exceeding thirty-two characters: {s}", .{"ABCDEF123456"});
    try std.testing.expect(s2.len <= 31);
    try std.testing.expectEqual(@as(u8, 0), buf[s2.len]);
}

test "LOG003: Default host logging without mock hook is safe" {
    resetTestState();
    // In test environment without mock_write_override, should safely execute as a silent no-op
    info("Safe host logging test", .{});
    warn("Safe warning test", .{});
    err("Safe error test", .{});
}
