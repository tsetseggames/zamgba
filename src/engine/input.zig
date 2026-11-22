const hal_joy = @import("zamgba-hal").joypad;

/// InputState maintains the current and previous states of the controller,
/// provides semantic methods to query input status, and tracks press duration.
pub const InputState = struct {
    current_raw: u16 = 0,
    previous_raw: u16 = 0,
    // Track duration (in frames) for each key (10 buttons total).
    durations: [10]u16 = @splat(0),

    /// Updates the input state using an explicit raw button bitmask.
    /// Useful for unit testing, replaying inputs, or custom input sources.
    pub fn updateWithRaw(self: *InputState, raw: u16) void {
        self.previous_raw = self.current_raw;
        self.current_raw = raw;

        // Update press duration for each button
        var i: usize = 0;
        while (i < 10) : (i += 1) {
            const mask = @as(u16, 1) << @intCast(i);
            if ((self.current_raw & mask) != 0) {
                // Increment duration if key is held
                if (self.durations[i] < 0xFFFF) {
                    self.durations[i] += 1;
                }
            } else {
                // Reset duration if key is released
                self.durations[i] = 0;
            }
        }
    }

    /// Updates the input state by reading the raw hardware input.
    /// Should be called once per frame in GBA runtime.
    pub fn update(self: *InputState) void {
        self.updateWithRaw(hal_joy.readRaw());
    }

    /// Returns the number of frames the key has been held.
    pub fn getDuration(self: *const InputState, key: hal_joy.Key) u16 {
        const index = @ctz(@backingInt(key));
        return self.durations[index];
    }

    /// Returns true if the specified key is currently held down.
    pub fn isPressed(self: *const InputState, key: hal_joy.Key) bool {
        return (self.current_raw & @backingInt(key)) != 0;
    }

    /// Returns true if the key was just pressed in the current frame.
    pub fn isJustPressed(self: *const InputState, key: hal_joy.Key) bool {
        const mask = @backingInt(key);
        return (self.current_raw & mask != 0) and (self.previous_raw & mask == 0);
    }

    /// Returns true if the key was released in the current frame.
    pub fn isJustReleased(self: *const InputState, key: hal_joy.Key) bool {
        const mask = @backingInt(key);
        return (self.current_raw & mask == 0) and (self.previous_raw & mask != 0);
    }
};

// ===================================================================
// Unit tests
// ===================================================================

test "InputState.PressedReleaseJustPressedJustReleased" {
    const std = @import("std");
    var input = InputState{};

    // Initial state: no buttons pressed
    try std.testing.expect(!input.isPressed(.A));
    try std.testing.expect(!input.isJustPressed(.A));
    try std.testing.expect(!input.isJustReleased(.A));

    // Frame 1: Press button A
    const raw_a = @backingInt(hal_joy.Key.A);
    input.updateWithRaw(raw_a);

    try std.testing.expect(input.isPressed(.A));
    try std.testing.expect(input.isJustPressed(.A));
    try std.testing.expect(!input.isJustReleased(.A));
    try std.testing.expect(!input.isPressed(.B));

    // Frame 2: Hold button A
    input.updateWithRaw(raw_a);

    try std.testing.expect(input.isPressed(.A));
    try std.testing.expect(!input.isJustPressed(.A));
    try std.testing.expect(!input.isJustReleased(.A));

    // Frame 3: Release button A
    input.updateWithRaw(0);

    try std.testing.expect(!input.isPressed(.A));
    try std.testing.expect(!input.isJustPressed(.A));
    try std.testing.expect(input.isJustReleased(.A));

    // Frame 4: Stay released
    input.updateWithRaw(0);

    try std.testing.expect(!input.isPressed(.A));
    try std.testing.expect(!input.isJustPressed(.A));
    try std.testing.expect(!input.isJustReleased(.A));
}

test "InputState.Durations" {
    const std = @import("std");
    var input = InputState{};

    const raw_b = @backingInt(hal_joy.Key.B);

    // Frame 1: Press B
    input.updateWithRaw(raw_b);
    try std.testing.expectEqual(@as(u16, 1), input.getDuration(.B));
    try std.testing.expectEqual(@as(u16, 0), input.getDuration(.A));

    // Frame 2: Hold B
    input.updateWithRaw(raw_b);
    try std.testing.expectEqual(@as(u16, 2), input.getDuration(.B));

    // Frame 3: Hold B
    input.updateWithRaw(raw_b);
    try std.testing.expectEqual(@as(u16, 3), input.getDuration(.B));

    // Frame 4: Release B
    input.updateWithRaw(0);
    try std.testing.expectEqual(@as(u16, 0), input.getDuration(.B));
}
