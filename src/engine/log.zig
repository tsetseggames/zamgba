const std = @import("std");
const builtin = @import("builtin");
const hal = @import("zamgba-hal");

pub const LogLevel = hal.mgba.log.LogLevel;
pub const BUFFER_SIZE: usize = hal.mgba.log.BUFFER_SIZE;

/// Mock function hook available strictly during host-side unit testing.
var mock_write_override: if (builtin.is_test) ?*const fn (level: LogLevel, message: []const u8) void else void =
    if (builtin.is_test) null else {};

/// Low-level static message writer.
/// On GBA hardware target, directly invokes mGBA hardware debug registers with zero runtime overhead.
/// On host machine, redirects to mock hook (during test) or host debug console.
fn write(level: LogLevel, message: []const u8) void {
    if (comptime builtin.is_test) {
        if (mock_write_override) |mock_fn| {
            mock_fn(level, message);
        }
        return;
    }

    if (comptime hal.specs.is_gba_target) {
        hal.mgba.log.write(level, message);
    } else {
        if (comptime builtin.mode == .Debug) {
            std.debug.print("[{s}] {s}\n", .{ @tagName(level), message });
        }
    }
}

/// Helper function to format strings to buffer with null-termination safely.
fn formatToBuf(buf: []u8, comptime fmt: []const u8, args: anytype) []const u8 {
    if (buf.len == 0) return "";
    const max_chars = buf.len - 1;
    const formatted = std.fmt.bufPrint(buf[0..max_chars], fmt, args) catch |e| switch (e) {
        error.NoSpaceLeft => buf[0..max_chars],
    };
    buf[formatted.len] = 0;
    return formatted;
}

/// Core logging dispatcher with compile-time zero-cost optimization in Release builds.
/// In non-Debug builds, log statements and formatting are completely eliminated with 0 bytes ROM/RAM footprint.
pub fn log(comptime level: LogLevel, comptime fmt: []const u8, args: anytype) void {
    if (comptime builtin.mode != .Debug) return;
    const formatted = formatToBuf(&hal.mgba.log.format_buf, fmt, args);
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

const TestContext = struct {
    var last_msg: [BUFFER_SIZE]u8 = [_]u8{0} ** BUFFER_SIZE;
    var last_len: usize = 0;
    var last_level: ?LogLevel = null;

    fn mockWriteCollector(level: LogLevel, message: []const u8) void {
        const len = @min(message.len, BUFFER_SIZE);
        @memcpy(last_msg[0..len], message[0..len]);
        last_len = len;
        last_level = level;
    }

    fn reset() void {
        @memset(&last_msg, 0);
        last_len = 0;
        last_level = null;
        mock_write_override = null;
    }
};

test "LOG001: Static logging dispatch across all levels" {
    TestContext.reset();
    mock_write_override = TestContext.mockWriteCollector;
    defer TestContext.reset();

    debug("Debug trace: {s}", .{"vram"});
    try std.testing.expectEqualStrings("Debug trace: vram", TestContext.last_msg[0..TestContext.last_len]);
    try std.testing.expectEqual(LogLevel.debug, TestContext.last_level.?);

    info("Info msg: count={d}", .{42});
    try std.testing.expectEqualStrings("Info msg: count=42", TestContext.last_msg[0..TestContext.last_len]);
    try std.testing.expectEqual(LogLevel.info, TestContext.last_level.?);

    warn("Warning alert: {d} fps", .{30});
    try std.testing.expectEqualStrings("Warning alert: 30 fps", TestContext.last_msg[0..TestContext.last_len]);
    try std.testing.expectEqual(LogLevel.warn, TestContext.last_level.?);

    err("Critical error: 0x{X}", .{0xDEAD});
    try std.testing.expectEqualStrings("Critical error: 0xDEAD", TestContext.last_msg[0..TestContext.last_len]);
    try std.testing.expectEqual(LogLevel.err, TestContext.last_level.?);

    fatal("System halting: {s}", .{"OOM"});
    try std.testing.expectEqualStrings("System halting: OOM", TestContext.last_msg[0..TestContext.last_len]);
    try std.testing.expectEqual(LogLevel.fatal, TestContext.last_level.?);
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
    TestContext.reset();
    // In test environment without mock_write_override, should safely execute as a silent no-op
    info("Safe host logging test", .{});
    warn("Safe warning test", .{});
    err("Safe error test", .{});
}
