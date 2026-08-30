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
    Unimplemented,
    InvalidCount,
    UnalignedPointer,
};

/// Copy memory in 16-bit halfword units via GBA DMA hardware.
pub fn copy16(channel: Channel, dest: [*]volatile u16, src: [*]const u16, halfwords: u16) DmaError!void {
    _ = channel;
    _ = dest;
    _ = src;
    _ = halfwords;
    return error.Unimplemented;
}

/// Copy memory in 32-bit word units via GBA DMA hardware.
pub fn copy32(channel: Channel, dest: [*]volatile u32, src: [*]const u32, words: u16) DmaError!void {
    _ = channel;
    _ = dest;
    _ = src;
    _ = words;
    return error.Unimplemented;
}

/// Fill memory with a 16-bit constant value using fixed source address DMA.
pub fn fill16(channel: Channel, dest: [*]volatile u16, value: u16, halfwords: u16) DmaError!void {
    _ = channel;
    _ = dest;
    _ = value;
    _ = halfwords;
    return error.Unimplemented;
}

/// Fill memory with a 32-bit constant value using fixed source address DMA.
pub fn fill32(channel: Channel, dest: [*]volatile u32, value: u32, words: u16) DmaError!void {
    _ = channel;
    _ = dest;
    _ = value;
    _ = words;
    return error.Unimplemented;
}
