const std = @import("std");
const hal = @import("zamgba-hal");

pub const DmaQueueError = error{
    Unimplemented,
    QueueFull,
    ExceedsVblankBudget,
    InvalidTask,
};

pub const CAPACITY: usize = 16;
pub const MAX_BYTES_PER_VBLANK: usize = 4096; // 4 KB safe VBlank budget

pub const DmaQueue = struct {
    tasks: [CAPACITY]hal.dma.DmaTask = undefined,
    head: usize = 0,
    tail: usize = 0,
    task_count: usize = 0,
    staged_bytes: usize = 0,

    pub fn init() DmaQueue {
        return .{};
    }

    pub fn reset(self: *DmaQueue) void {
        self.head = 0;
        self.tail = 0;
        self.task_count = 0;
        self.staged_bytes = 0;
    }

    pub fn enqueue(self: *DmaQueue, task: hal.dma.DmaTask) DmaQueueError!void {
        _ = self;
        _ = task;
        return error.Unimplemented;
    }

    pub fn enqueueBytes(self: *DmaQueue, src: [*]const u8, dest: [*]volatile u8, bytes: u16) DmaQueueError!void {
        _ = self;
        _ = src;
        _ = dest;
        _ = bytes;
        return error.Unimplemented;
    }

    pub fn flush(self: *DmaQueue) void {
        _ = self;
    }

    pub fn clear(self: *DmaQueue) void {
        self.reset();
    }

    pub fn isEmpty(self: *const DmaQueue) bool {
        return self.task_count == 0;
    }

    pub fn count(self: *const DmaQueue) usize {
        return self.task_count;
    }

    pub fn getStagedBytes(self: *const DmaQueue) usize {
        return self.staged_bytes;
    }
};

test "DMQ001: DmaQueue initial state and capacity" {
    var queue = DmaQueue.init();
    try std.testing.expect(queue.isEmpty());
    try std.testing.expectEqual(@as(usize, 0), queue.count());
    try std.testing.expectEqual(@as(usize, 0), queue.getStagedBytes());
}

test "DMQ002: DmaQueue enqueue and FIFO flush" {
    var queue = DmaQueue.init();
    const src = [_]u32{ 0x12345678, 0x9ABCDEF0 };
    var dest = [_]u32{0} ** 2;

    const task = try hal.dma.DmaTask.initBytes(@ptrCast(&src), @ptrCast(&dest), 8);
    try queue.enqueue(task);

    try std.testing.expectEqual(@as(usize, 1), queue.count());
    try std.testing.expectEqual(@as(usize, 8), queue.getStagedBytes());

    queue.flush();
    try std.testing.expect(queue.isEmpty());
    try std.testing.expectEqualSlices(u32, &src, &dest);
}

test "DMQ003: DmaQueue rejects enqueue when capacity full" {
    var queue = DmaQueue.init();
    var src = [_]u8{1} ** 32;
    var dest = [_]u8{0} ** 32;

    var i: usize = 0;
    while (i < CAPACITY) : (i += 1) {
        const task = try hal.dma.DmaTask.initBytes(&src, &dest, 32);
        try queue.enqueue(task);
    }

    // 17th task must return QueueFull
    const overflow_task = try hal.dma.DmaTask.initBytes(&src, &dest, 32);
    try std.testing.expectError(error.QueueFull, queue.enqueue(overflow_task));
}

test "DMQ004: DmaQueue budget guard rejects tasks exceeding MAX_BYTES_PER_VBLANK" {
    var queue = DmaQueue.init();
    var src align(4) = [_]u8{0} ** 4096;
    var dest align(4) = [_]u8{0} ** 4096;

    // Enqueue 4096 bytes (budget reached)
    const task_full = try hal.dma.DmaTask.initBytes(&src, &dest, 4096);
    try queue.enqueue(task_full);

    // Any further bytes must return ExceedsVblankBudget
    const task_extra = try hal.dma.DmaTask.initBytes(&src, &dest, 32);
    try std.testing.expectError(error.ExceedsVblankBudget, queue.enqueue(task_extra));
}
