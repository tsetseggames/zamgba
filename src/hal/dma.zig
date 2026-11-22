const std = @import("std");
const specs = @import("specs.zig");
const is_gba_target = specs.is_gba_target;

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

pub const MockDmaRegisters = struct {
    sad: u32 = 0,
    dad: u32 = 0,
    cnt_l: u16 = 0,
    cnt_h: u16 = 0,
};

pub var mock_regs_override: ?*MockDmaRegisters = null;

pub const Regs = struct {
    sad: *volatile u32,
    dad: *volatile u32,
    cnt_l: *volatile u16,
    cnt_h: *volatile u16,

    pub inline fn baseForChannel(channel: Channel) usize {
        return 0x040000B0 + @as(usize, @backingInt(channel)) * 12;
    }

    pub inline fn forChannel(channel: Channel) Regs {
        const base = baseForChannel(channel);
        return .{
            .sad = @as(*volatile u32, @ptrFromInt(base)),
            .dad = @as(*volatile u32, @ptrFromInt(base + 4)),
            .cnt_l = @as(*volatile u16, @ptrFromInt(base + 8)),
            .cnt_h = @as(*volatile u16, @ptrFromInt(base + 10)),
        };
    }
};

/// Copy memory in 16-bit halfword units via GBA DMA hardware.
pub inline fn copy16(channel: Channel, dest: [*]volatile u16, src: [*]const u16, halfwords: u16) DmaError!void {
    if (halfwords == 0) return error.InvalidCount;

    if (comptime is_gba_target) {
        const r = Regs.forChannel(channel);
        r.cnt_h.* = 0; // Disable channel before reprogramming
        r.sad.* = @truncate(@intFromPtr(src));
        r.dad.* = @truncate(@intFromPtr(dest));
        r.cnt_l.* = halfwords;
        r.cnt_h.* = @as(u16, @bitCast(DmaControl{
            .transfer_type = .halfword_16,
            .dest_adjust = .increment,
            .src_adjust = .increment,
            .start_time = .immediate,
            .enable = true,
        }));
    } else {
        if (mock_regs_override) |m| {
            m.cnt_h = 0;
            m.sad = @truncate(@intFromPtr(src));
            m.dad = @truncate(@intFromPtr(dest));
            m.cnt_l = halfwords;
            m.cnt_h = @as(u16, @bitCast(DmaControl{
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
}

/// Copy memory in 32-bit word units via GBA DMA hardware.
pub inline fn copy32(channel: Channel, dest: [*]volatile u32, src: [*]const u32, words: u16) DmaError!void {
    if (words == 0) return error.InvalidCount;

    if (comptime is_gba_target) {
        const r = Regs.forChannel(channel);
        r.cnt_h.* = 0; // Disable channel before reprogramming
        r.sad.* = @truncate(@intFromPtr(src));
        r.dad.* = @truncate(@intFromPtr(dest));
        r.cnt_l.* = words;
        r.cnt_h.* = @as(u16, @bitCast(DmaControl{
            .transfer_type = .word_32,
            .dest_adjust = .increment,
            .src_adjust = .increment,
            .start_time = .immediate,
            .enable = true,
        }));
    } else {
        if (mock_regs_override) |m| {
            m.cnt_h = 0;
            m.sad = @truncate(@intFromPtr(src));
            m.dad = @truncate(@intFromPtr(dest));
            m.cnt_l = words;
            m.cnt_h = @as(u16, @bitCast(DmaControl{
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
}

/// Fill memory with a 16-bit constant value using fixed source address DMA.
pub inline fn fill16(channel: Channel, dest: [*]volatile u16, value: u16, halfwords: u16) DmaError!void {
    if (halfwords == 0) return error.InvalidCount;

    if (comptime is_gba_target) {
        const r = Regs.forChannel(channel);
        r.cnt_h.* = 0;
        r.sad.* = @truncate(@intFromPtr(&value));
        r.dad.* = @truncate(@intFromPtr(dest));
        r.cnt_l.* = halfwords;
        r.cnt_h.* = @as(u16, @bitCast(DmaControl{
            .transfer_type = .halfword_16,
            .dest_adjust = .increment,
            .src_adjust = .fixed,
            .start_time = .immediate,
            .enable = true,
        }));
    } else {
        if (mock_regs_override) |m| {
            m.cnt_h = 0;
            m.sad = @truncate(@intFromPtr(&value));
            m.dad = @truncate(@intFromPtr(dest));
            m.cnt_l = halfwords;
            m.cnt_h = @as(u16, @bitCast(DmaControl{
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
}

/// Fill memory with a 32-bit constant value using fixed source address DMA.
pub inline fn fill32(channel: Channel, dest: [*]volatile u32, value: u32, words: u16) DmaError!void {
    if (words == 0) return error.InvalidCount;

    if (comptime is_gba_target) {
        const r = Regs.forChannel(channel);
        r.cnt_h.* = 0;
        r.sad.* = @truncate(@intFromPtr(&value));
        r.dad.* = @truncate(@intFromPtr(dest));
        r.cnt_l.* = words;
        r.cnt_h.* = @as(u16, @bitCast(DmaControl{
            .transfer_type = .word_32,
            .dest_adjust = .increment,
            .src_adjust = .fixed,
            .start_time = .immediate,
            .enable = true,
        }));
    } else {
        if (mock_regs_override) |m| {
            m.cnt_h = 0;
            m.sad = @truncate(@intFromPtr(&value));
            m.dad = @truncate(@intFromPtr(dest));
            m.cnt_l = words;
            m.cnt_h = @as(u16, @bitCast(DmaControl{
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
    var dest_buf: [8]u8 align(4) = @splat(0);

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
    var dest: [4]u16 = @splat(0);
    try copy16(.ch3, &dest, &src, 4);
    try std.testing.expectEqualSlices(u16, &src, &dest);
}

test "DMA004: copy32 copies words to destination" {
    const src = [_]u32{ 0x12345678, 0x9ABCDEF0 };
    var dest: [2]u32 = @splat(0);
    try copy32(.ch3, &dest, &src, 2);
    try std.testing.expectEqualSlices(u32, &src, &dest);
}

test "DMA005: fill16 fills destination buffer with constant halfword" {
    var dest: [4]u16 = @splat(0);
    try fill16(.ch3, &dest, 0x7FFF, 4);
    const expected = [_]u16{ 0x7FFF, 0x7FFF, 0x7FFF, 0x7FFF };
    try std.testing.expectEqualSlices(u16, &expected, &dest);
}

test "DMA006: fill32 fills destination buffer with constant word" {
    var dest: [4]u32 = @splat(0);
    try fill32(.ch3, &dest, 0x11223344, 4);
    const expected = [_]u32{ 0x11223344, 0x11223344, 0x11223344, 0x11223344 };
    try std.testing.expectEqualSlices(u32, &expected, &dest);
}

test "DMA007: DmaTask initBytes rejects unaligned bytes or odd pointers" {
    var src_buf align(4) = [_]u8{ 1, 2, 3, 4, 5, 6, 7, 8 };
    var dest_buf: [8]u8 align(4) = @splat(0);

    // Odd byte lengths
    try std.testing.expectError(error.UnalignedPointer, DmaTask.initBytes(&src_buf, &dest_buf, 3));
    try std.testing.expectError(error.UnalignedPointer, DmaTask.initBytes(&src_buf, &dest_buf, 5));

    // Unaligned pointer offset
    const unaligned_src: [*]const u8 = @ptrCast(&src_buf[1]);
    try std.testing.expectError(error.UnalignedPointer, DmaTask.initBytes(unaligned_src, &dest_buf, 4));

    const unaligned_dest: [*]volatile u8 = @ptrCast(&dest_buf[1]);
    try std.testing.expectError(error.UnalignedPointer, DmaTask.initBytes(&src_buf, unaligned_dest, 4));
}

test "DMA008: copy16 / copy32 / fill16 / fill32 reject zero count" {
    var dest16: [2]u16 = @splat(0);
    const src16 = [_]u16{ 1, 2 };
    try std.testing.expectError(error.InvalidCount, copy16(.ch0, &dest16, &src16, 0));
    try std.testing.expectError(error.InvalidCount, fill16(.ch0, &dest16, 0x1234, 0));

    var dest32: [2]u32 = @splat(0);
    const src32 = [_]u32{ 1, 2 };
    try std.testing.expectError(error.InvalidCount, copy32(.ch0, &dest32, &src32, 0));
    try std.testing.expectError(error.InvalidCount, fill32(.ch0, &dest32, 0x12345678, 0));
}

test "DMA009: Regs MMIO register base address calculation for CH0..CH3" {
    try std.testing.expectEqual(@as(usize, 0x040000B0), Regs.baseForChannel(.ch0));
    try std.testing.expectEqual(@as(usize, 0x040000BC), Regs.baseForChannel(.ch1));
    try std.testing.expectEqual(@as(usize, 0x040000C8), Regs.baseForChannel(.ch2));
    try std.testing.expectEqual(@as(usize, 0x040000D4), Regs.baseForChannel(.ch3));
}

test "DMA010: copy16 and copy32 hardware register configuration in mock mode" {
    var mock_regs = MockDmaRegisters{};
    mock_regs_override = &mock_regs;
    defer mock_regs_override = null;

    const src16 = [_]u16{ 0x1111, 0x2222 };
    var dest16 = [_]u16{ 0, 0 };

    try copy16(.ch2, &dest16, &src16, 2);
    try std.testing.expectEqual(@as(u32, @truncate(@intFromPtr(&src16))), mock_regs.sad);
    try std.testing.expectEqual(@as(u32, @truncate(@intFromPtr(&dest16))), mock_regs.dad);
    try std.testing.expectEqual(@as(u16, 2), mock_regs.cnt_l);
    // 16-bit, increment/increment, immediate, enable -> 0x8000
    try std.testing.expectEqual(@as(u16, 0x8000), mock_regs.cnt_h);

    const src32 = [_]u32{0xAABBCCDD};
    var dest32 = [_]u32{0};

    try copy32(.ch1, &dest32, &src32, 1);
    try std.testing.expectEqual(@as(u32, @truncate(@intFromPtr(&src32))), mock_regs.sad);
    try std.testing.expectEqual(@as(u32, @truncate(@intFromPtr(&dest32))), mock_regs.dad);
    try std.testing.expectEqual(@as(u16, 1), mock_regs.cnt_l);
    // 32-bit (bit 10 = 1), increment/increment, immediate, enable -> 0x8400
    try std.testing.expectEqual(@as(u16, 0x8400), mock_regs.cnt_h);
}

test "DMA011: fill16 and fill32 sets src_adjust to fixed in hardware register in mock mode" {
    var mock_regs = MockDmaRegisters{};
    mock_regs_override = &mock_regs;
    defer mock_regs_override = null;

    var dest16 = [_]u16{ 0, 0, 0 };
    try fill16(.ch3, &dest16, 0x5555, 3);
    try std.testing.expectEqual(@as(u32, @truncate(@intFromPtr(&dest16))), mock_regs.dad);
    try std.testing.expectEqual(@as(u16, 3), mock_regs.cnt_l);
    // 16-bit, dest increment, src fixed (bits 7-8 = 2 -> 0x0100), enable (bit 15 = 1) -> 0x8100
    try std.testing.expectEqual(@as(u16, 0x8100), mock_regs.cnt_h);

    var dest32 = [_]u32{ 0, 0 };
    try fill32(.ch0, &dest32, 0x12345678, 2);
    try std.testing.expectEqual(@as(u32, @truncate(@intFromPtr(&dest32))), mock_regs.dad);
    try std.testing.expectEqual(@as(u16, 2), mock_regs.cnt_l);
    // 32-bit (0x0400), dest increment, src fixed (0x0100), enable (0x8000) -> 0x8500
    try std.testing.expectEqual(@as(u16, 0x8500), mock_regs.cnt_h);
}

test "DMA012: DmaControl bitmask full enum permutations" {
    // DestAddressControl permutations
    const ctrl_dec = DmaControl{ .dest_adjust = .decrement };
    try std.testing.expectEqual(@as(u16, 1 << 5), @as(u16, @bitCast(ctrl_dec)));

    const ctrl_reload = DmaControl{ .dest_adjust = .reload };
    try std.testing.expectEqual(@as(u16, 3 << 5), @as(u16, @bitCast(ctrl_reload)));

    // SourceAddressControl permutations
    const ctrl_src_dec = DmaControl{ .src_adjust = .decrement };
    try std.testing.expectEqual(@as(u16, 1 << 7), @as(u16, @bitCast(ctrl_src_dec)));

    const ctrl_src_forbid = DmaControl{ .src_adjust = .forbidden };
    try std.testing.expectEqual(@as(u16, 3 << 7), @as(u16, @bitCast(ctrl_src_forbid)));

    // TimingMode permutations
    const ctrl_hblank = DmaControl{ .start_time = .hblank };
    try std.testing.expectEqual(@as(u16, 2 << 12), @as(u16, @bitCast(ctrl_hblank)));

    const ctrl_special = DmaControl{ .start_time = .special };
    try std.testing.expectEqual(@as(u16, 3 << 12), @as(u16, @bitCast(ctrl_special)));

    // Gamepak DRQ & Repeat
    const ctrl_drq = DmaControl{ .gamepak_drq = true, .repeat = true };
    try std.testing.expectEqual(@as(u16, (1 << 11) | (1 << 9)), @as(u16, @bitCast(ctrl_drq)));
}
