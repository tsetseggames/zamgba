const std = @import("std");
const builtin = @import("builtin");

/// GBA DMA Channels (DMA 0 to DMA 3).
pub const Channel = enum(u2) {
    ch0 = 0,
    ch1 = 1,
    ch2 = 2,
    ch3 = 3,
};

/// Destination address control modes for DMA transfer.
pub const DestAddressControl = enum(u2) {
    increment = 0,
    decrement = 1,
    fixed = 2,
    reload = 3,
};

/// Source address control modes for DMA transfer.
pub const SourceAddressControl = enum(u2) {
    increment = 0,
    decrement = 1,
    fixed = 2,
    forbidden = 3,
};

/// Transfer unit width (16-bit halfword or 32-bit word).
pub const TransferUnit = enum(u1) {
    halfword_16 = 0,
    word_32 = 1,
};

/// Start timing modes for DMA transfers.
pub const TimingMode = enum(u2) {
    immediate = 0,
    vblank = 1,
    hblank = 2,
    special = 3,
};

/// Strongly typed packed representation of GBA DMAxCNT_H register (16-bit).
pub const DmaControl = packed struct(u16) {
    _pad: u5 = 0,
    dest_adjust: DestAddressControl = .increment,
    src_adjust: SourceAddressControl = .increment,
    repeat: bool = false,
    transfer_type: TransferUnit = .halfword_16,
    gamepak_drq: bool = false,
    start_time: TimingMode = .immediate,
    irq_enable: bool = false,
    enable: bool = false,
};

/// Standalone descriptor of a pending DMA memory transfer.
pub const DmaTask = struct {
    src_address: usize,
    dest_address: usize,
    count: u16,
    unit: TransferUnit = .word_32,

    pub fn initBytes(src: [*]const u8, dest: [*]volatile u8, bytes: u16) DmaError!DmaTask {
        if (bytes == 0) return error.InvalidCount;
        const src_addr = @intFromPtr(src);
        const dest_addr = @intFromPtr(dest);

        if ((src_addr & 3 == 0) and (dest_addr & 3 == 0) and (bytes & 3 == 0)) {
            return DmaTask{
                .src_address = src_addr,
                .dest_address = dest_addr,
                .count = bytes / 4,
                .unit = .word_32,
            };
        } else if ((src_addr & 1 == 0) and (dest_addr & 1 == 0) and (bytes & 1 == 0)) {
            return DmaTask{
                .src_address = src_addr,
                .dest_address = dest_addr,
                .count = bytes / 2,
                .unit = .halfword_16,
            };
        } else {
            return error.UnalignedPointer;
        }
    }
};

pub const DmaError = error{
    InvalidCount,
    UnalignedPointer,
};

const is_gba_target = builtin.target.os.tag == .freestanding or builtin.target.cpu.arch == .arm or builtin.target.cpu.arch == .thumb;

const Regs = struct {
    sad: *volatile u32,
    dad: *volatile u32,
    cnt_l: *volatile u16,
    cnt_h: *volatile u16,

    fn forChannel(channel: Channel) Regs {
        const base = 0x040000B0 + @as(usize, @intFromEnum(channel)) * 12;
        return .{
            .sad = @as(*volatile u32, @ptrFromInt(base)),
            .dad = @as(*volatile u32, @ptrFromInt(base + 4)),
            .cnt_l = @as(*volatile u16, @ptrFromInt(base + 8)),
            .cnt_h = @as(*volatile u16, @ptrFromInt(base + 10)),
        };
    }
};

/// Copy memory in 16-bit halfword units via GBA DMA hardware.
pub fn copy16(channel: Channel, dest: [*]volatile u16, src: [*]const u16, halfwords: u16) DmaError!void {
    if (halfwords == 0) return error.InvalidCount;

    if (is_gba_target) {
        const r = Regs.forChannel(channel);
        r.cnt_h.* = 0; // Disable channel before reprogramming
        r.sad.* = @intFromPtr(src);
        r.dad.* = @intFromPtr(dest);
        r.cnt_l.* = halfwords;
        r.cnt_h.* = @as(u16, @bitCast(DmaControl{
            .transfer_type = .halfword_16,
            .dest_adjust = .increment,
            .src_adjust = .increment,
            .start_time = .immediate,
            .enable = true,
        }));
    } else {
        for (0..halfwords) |i| {
            dest[i] = src[i];
        }
    }
}

/// Copy memory in 32-bit word units via GBA DMA hardware.
pub fn copy32(channel: Channel, dest: [*]volatile u32, src: [*]const u32, words: u16) DmaError!void {
    if (words == 0) return error.InvalidCount;

    if (is_gba_target) {
        const r = Regs.forChannel(channel);
        r.cnt_h.* = 0; // Disable channel before reprogramming
        r.sad.* = @intFromPtr(src);
        r.dad.* = @intFromPtr(dest);
        r.cnt_l.* = words;
        r.cnt_h.* = @as(u16, @bitCast(DmaControl{
            .transfer_type = .word_32,
            .dest_adjust = .increment,
            .src_adjust = .increment,
            .start_time = .immediate,
            .enable = true,
        }));
    } else {
        for (0..words) |i| {
            dest[i] = src[i];
        }
    }
}

/// Fill memory with a 16-bit constant value using fixed source address DMA.
pub fn fill16(channel: Channel, dest: [*]volatile u16, value: u16, halfwords: u16) DmaError!void {
    if (halfwords == 0) return error.InvalidCount;

    if (is_gba_target) {
        const r = Regs.forChannel(channel);
        r.cnt_h.* = 0;
        r.sad.* = @intFromPtr(&value);
        r.dad.* = @intFromPtr(dest);
        r.cnt_l.* = halfwords;
        r.cnt_h.* = @as(u16, @bitCast(DmaControl{
            .transfer_type = .halfword_16,
            .dest_adjust = .increment,
            .src_adjust = .fixed,
            .start_time = .immediate,
            .enable = true,
        }));
    } else {
        for (0..halfwords) |i| {
            dest[i] = value;
        }
    }
}

/// Fill memory with a 32-bit constant value using fixed source address DMA.
pub fn fill32(channel: Channel, dest: [*]volatile u32, value: u32, words: u16) DmaError!void {
    if (words == 0) return error.InvalidCount;

    if (is_gba_target) {
        const r = Regs.forChannel(channel);
        r.cnt_h.* = 0;
        r.sad.* = @intFromPtr(&value);
        r.dad.* = @intFromPtr(dest);
        r.cnt_l.* = words;
        r.cnt_h.* = @as(u16, @bitCast(DmaControl{
            .transfer_type = .word_32,
            .dest_adjust = .increment,
            .src_adjust = .fixed,
            .start_time = .immediate,
            .enable = true,
        }));
    } else {
        for (0..words) |i| {
            dest[i] = value;
        }
    }
}

test "DMA001: DmaControl packed struct bit alignment" {
    var ctrl = DmaControl{};
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
    const task32 = try DmaTask.initBytes(&src_buf, &dest_buf, 8);
    try std.testing.expectEqual(@as(u16, 2), task32.count);
    try std.testing.expectEqual(TransferUnit.word_32, task32.unit);

    // 6 bytes, 2-byte aligned -> 3 halfwords (16-bit)
    const task16 = try DmaTask.initBytes(&src_buf, &dest_buf, 6);
    try std.testing.expectEqual(@as(u16, 3), task16.count);
    try std.testing.expectEqual(TransferUnit.halfword_16, task16.unit);

    // 0 bytes -> InvalidCount error
    try std.testing.expectError(error.InvalidCount, DmaTask.initBytes(&src_buf, &dest_buf, 0));
}

test "DMA003: copy16 copies halfwords to destination" {
    const src = [_]u16{ 0x1234, 0x5678, 0x9ABC, 0xDEF0 };
    var dest = [_]u16{0} ** 4;
    try copy16(.ch3, &dest, &src, 4);
    try std.testing.expectEqualSlices(u16, &src, &dest);
}

test "DMA004: copy32 copies words to destination" {
    const src = [_]u32{ 0x12345678, 0x9ABCDEF0 };
    var dest = [_]u32{0} ** 2;
    try copy32(.ch3, &dest, &src, 2);
    try std.testing.expectEqualSlices(u32, &src, &dest);
}

test "DMA005: fill16 fills destination buffer with constant halfword" {
    var dest = [_]u16{0} ** 4;
    try fill16(.ch3, &dest, 0x7FFF, 4);
    const expected = [_]u16{ 0x7FFF, 0x7FFF, 0x7FFF, 0x7FFF };
    try std.testing.expectEqualSlices(u16, &expected, &dest);
}

test "DMA006: fill32 fills destination buffer with constant word" {
    var dest = [_]u32{0} ** 4;
    try fill32(.ch3, &dest, 0x11223344, 4);
    const expected = [_]u32{ 0x11223344, 0x11223344, 0x11223344, 0x11223344 };
    try std.testing.expectEqualSlices(u32, &expected, &dest);
}
