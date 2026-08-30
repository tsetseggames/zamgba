const std = @import("std");
const hal = @import("zamgba-hal");

test "DMA001: DmaControl packed struct bit alignment" {
    var ctrl = hal.dma.DmaControl{};
    // Default zero-initialized
    try std.testing.expectEqual(@as(u16, 0), @as(u16, @bitCast(ctrl)));

    // Bit 15: Enable
    ctrl.enable = true;
    try std.testing.expectEqual(@as(u16, 0x8000), @as(u16, @bitCast(ctrl)));

    // Bit 14: IRQ Enable
    ctrl.irq_enable = true;
    try std.testing.expectEqual(@as(u16, 0xC000), @as(u16, @bitCast(ctrl)));

    // Bits 12-13: Start Timing = VBlank (1) -> (1 << 12) = 0x1000
    ctrl.start_time = .vblank;
    try std.testing.expectEqual(@as(u16, 0xD000), @as(u16, @bitCast(ctrl)));

    // Bit 10: 32-bit transfer -> (1 << 10) = 0x0400
    ctrl.transfer_type = .word_32;
    try std.testing.expectEqual(@as(u16, 0xD400), @as(u16, @bitCast(ctrl)));

    // Bits 7-8: Source fixed (2) -> (2 << 7) = 0x0100
    ctrl.src_adjust = .fixed;
    try std.testing.expectEqual(@as(u16, 0xD500), @as(u16, @bitCast(ctrl)));

    // Bits 5-6: Dest fixed (2) -> (2 << 5) = 0x0040
    ctrl.dest_adjust = .fixed;
    try std.testing.expectEqual(@as(u16, 0xD540), @as(u16, @bitCast(ctrl)));
}

test "DMA002: DmaTask initBytes computes alignment and count" {
    var src_buf align(4) = [_]u8{ 1, 2, 3, 4, 5, 6, 7, 8 };
    var dest_buf align(4) = [_]u8{0} ** 8;

    // 8 bytes, 4-byte aligned -> 2 words (32-bit)
    const task32 = try hal.dma.DmaTask.initBytes(&src_buf, &dest_buf, 8);
    try std.testing.expectEqual(@as(u16, 2), task32.count);
    try std.testing.expectEqual(hal.dma.TransferUnit.word_32, task32.unit);

    // 6 bytes, 2-byte aligned -> 3 halfwords (16-bit)
    const task16 = try hal.dma.DmaTask.initBytes(&src_buf, &dest_buf, 6);
    try std.testing.expectEqual(@as(u16, 3), task16.count);
    try std.testing.expectEqual(hal.dma.TransferUnit.halfword_16, task16.unit);

    // 0 bytes -> InvalidCount error
    try std.testing.expectError(error.InvalidCount, hal.dma.DmaTask.initBytes(&src_buf, &dest_buf, 0));
}

test "DMA003: copy16 copies halfwords to destination" {
    const src = [_]u16{ 0x1234, 0x5678, 0x9ABC, 0xDEF0 };
    var dest = [_]u16{0} ** 4;
    try hal.dma.copy16(.ch3, &dest, &src, 4);
    try std.testing.expectEqualSlices(u16, &src, &dest);
}

test "DMA004: copy32 copies words to destination" {
    const src = [_]u32{ 0x12345678, 0x9ABCDEF0 };
    var dest = [_]u32{0} ** 2;
    try hal.dma.copy32(.ch3, &dest, &src, 2);
    try std.testing.expectEqualSlices(u32, &src, &dest);
}

test "DMA005: fill16 fills destination buffer with constant halfword" {
    var dest = [_]u16{0} ** 4;
    try hal.dma.fill16(.ch3, &dest, 0x7FFF, 4);
    const expected = [_]u16{ 0x7FFF, 0x7FFF, 0x7FFF, 0x7FFF };
    try std.testing.expectEqualSlices(u16, &expected, &dest);
}

test "DMA006: fill32 fills destination buffer with constant word" {
    var dest = [_]u32{0} ** 4;
    try hal.dma.fill32(.ch3, &dest, 0x11223344, 4);
    const expected = [_]u32{ 0x11223344, 0x11223344, 0x11223344, 0x11223344 };
    try std.testing.expectEqualSlices(u32, &expected, &dest);
}

test {
    _ = @import("engine/physics/math.zig");
    _ = @import("engine/physics/aabb.zig");
    _ = @import("engine/physics/map.zig");
    _ = @import("engine/physics/layer.zig");
    _ = @import("engine/physics/overlap.zig");
}
