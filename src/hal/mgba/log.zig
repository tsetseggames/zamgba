const std = @import("std");
const builtin = @import("builtin");
const specs = @import("../specs.zig");
const is_gba_target = specs.is_gba_target;

pub const LogLevel = enum(u3) {
    fatal = 0,
    err = 1,
    warn = 2,
    info = 3,
    debug = 4,
};

pub const BUFFER_SIZE: usize = 256;
pub const MGBA_ENABLE_MAGIC: u16 = 0xC0DE;
pub const MGBA_RESPONSE_MAGIC: u16 = 0x1EA0;
pub const MGBA_SEND_FLAG: u16 = 0x0100;

pub const REG_DEBUG_STRING_ADDR: usize = 0x04FFF600;
pub const REG_DEBUG_FLAGS_ADDR: usize = 0x04FFF700;
pub const REG_DEBUG_ENABLE_ADDR: usize = 0x04FFF780;

pub const Regs = struct {
    pub const string_buf = @as([*]volatile u8, @ptrFromInt(REG_DEBUG_STRING_ADDR));
    pub const flags = @as(*volatile u16, @ptrFromInt(REG_DEBUG_FLAGS_ADDR));
    pub const enable = @as(*volatile u16, @ptrFromInt(REG_DEBUG_ENABLE_ADDR));
};

pub const MockMgbaDebug = struct {
    enable_reg: u16 = 0,
    flags_reg: u16 = 0,
    string_buffer: [BUFFER_SIZE]u8 = [_]u8{0} ** BUFFER_SIZE,
    string_len: usize = 0,
    last_level: ?LogLevel = null,
    send_count: usize = 0,

    pub fn reset(self: *MockMgbaDebug) void {
        self.enable_reg = 0;
        self.flags_reg = 0;
        @memset(&self.string_buffer, 0);
        self.string_len = 0;
        self.last_level = null;
        self.send_count = 0;
    }

    pub fn getSentString(self: *const MockMgbaDebug) []const u8 {
        return self.string_buffer[0..self.string_len];
    }
};

pub var mock_debug_override: ?*MockMgbaDebug = null;

/// Duck-typed Logger implementation for mGBA hardware debug port.
/// Zero-Sized Type (ZST) with 0 bytes of RAM footprint.
pub const MgbaLogger = struct {
    /// Attempts to handshake with mGBA debug registers.
    pub fn init(self: MgbaLogger) bool {
        _ = self;
        if (mock_debug_override) |mock| {
            mock.enable_reg = MGBA_RESPONSE_MAGIC;
            return true;
        }
        if (!is_gba_target) return false;
        Regs.enable.* = MGBA_ENABLE_MAGIC;
        return (Regs.enable.* == MGBA_RESPONSE_MAGIC);
    }

    /// Checks if mGBA debug interface is supported.
    pub fn isSupported(self: MgbaLogger) bool {
        _ = self;
        if (mock_debug_override) |mock| {
            return (mock.enable_reg == MGBA_RESPONSE_MAGIC);
        }
        if (!is_gba_target) return false;
        return (Regs.enable.* == MGBA_RESPONSE_MAGIC);
    }

    /// Writes raw message slice and triggers send.
    pub fn write(self: MgbaLogger, level: LogLevel, message: []const u8) void {
        if (mock_debug_override) |mock| {
            const max_len = BUFFER_SIZE - 1;
            const copy_len = @min(message.len, max_len);
            @memcpy(mock.string_buffer[0..copy_len], message[0..copy_len]);
            mock.string_buffer[copy_len] = 0;
            mock.string_len = copy_len;
            mock.last_level = level;
            mock.flags_reg = MGBA_SEND_FLAG | @intFromEnum(level);
            mock.send_count += 1;
            return;
        }
        if (!is_gba_target or !self.isSupported()) return;

        const max_len = BUFFER_SIZE - 1;
        const copy_len = @min(message.len, max_len);
        for (0..copy_len) |i| {
            Regs.string_buf[i] = message[i];
        }
        Regs.string_buf[copy_len] = 0;
        Regs.flags.* = MGBA_SEND_FLAG | @intFromEnum(level);
    }

    /// Formats data into buffer safely with trailing null terminator.
    pub fn formatToBuf(self: MgbaLogger, buf: []u8, comptime fmt: []const u8, args: anytype) []const u8 {
        _ = self;
        if (buf.len == 0) return "";
        const max_chars = buf.len - 1;
        const formatted = std.fmt.bufPrint(buf[0..max_chars], fmt, args) catch |e| switch (e) {
            error.NoSpaceLeft => buf[0..max_chars],
        };
        buf[formatted.len] = 0;
        return formatted;
    }
};

/// Global stateless constant instance for mGBA logger.
pub const logger: MgbaLogger = .{};

pub fn init() bool {
    return logger.init();
}

pub fn isSupported() bool {
    return logger.isSupported();
}

pub fn write(level: LogLevel, message: []const u8) void {
    logger.write(level, message);
}

pub fn formatToBuf(buf: []u8, comptime fmt: []const u8, args: anytype) []const u8 {
    return logger.formatToBuf(buf, fmt, args);
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

test "MGB002: mGBA hardware handshake and enable sequence" {
    var mock = MockMgbaDebug{};
    mock_debug_override = &mock;
    defer mock_debug_override = null;

    const test_logger = MgbaLogger{};
    try std.testing.expect(!test_logger.isSupported());

    const ok = test_logger.init();
    try std.testing.expect(ok);
    try std.testing.expectEqual(MGBA_RESPONSE_MAGIC, mock.enable_reg);
    try std.testing.expect(test_logger.isSupported());
}

test "MGB003: mGBA write and truncation at 255 bytes" {
    var mock = MockMgbaDebug{};
    mock_debug_override = &mock;
    defer mock_debug_override = null;

    const test_logger = MgbaLogger{};
    _ = test_logger.init();

    test_logger.write(.info, "Hello mGBA");
    try std.testing.expectEqualStrings("Hello mGBA", mock.getSentString());
    try std.testing.expectEqual(@as(u16, MGBA_SEND_FLAG | @intFromEnum(LogLevel.info)), mock.flags_reg);

    var long_msg: [300]u8 = [_]u8{'X'} ** 300;
    test_logger.write(.err, &long_msg);
    try std.testing.expectEqual(@as(usize, 255), mock.string_len);
    try std.testing.expectEqual(@as(u8, 0), mock.string_buffer[255]);
    try std.testing.expectEqual(LogLevel.err, mock.last_level.?);
}

test "MGB004: mGBA formatToBuf formatting and boundary termination" {
    const test_logger = MgbaLogger{};
    var buf: [32]u8 = undefined;

    const s1 = test_logger.formatToBuf(&buf, "Value: {d}", .{999});
    try std.testing.expectEqualStrings("Value: 999", s1);
    try std.testing.expectEqual(@as(u8, 0), buf[s1.len]);

    const s2 = test_logger.formatToBuf(&buf, "Long text overflow: {s}", .{"123456789012345678901234567890"});
    try std.testing.expect(s2.len <= 31);
    try std.testing.expectEqual(@as(u8, 0), buf[s2.len]);
}
