const std = @import("std");
const hal = @import("zamgba-hal");

pub const DmaQueueError = error{
    QueueFull,
    ExceedsVblankBudget,
    InvalidTask,
};

pub const CAPACITY: usize = 16;
pub const DEFAULT_MAX_BYTES_PER_VBLANK: usize = 4096; // 4 KB safe VBlank budget
pub const HARDWARE_MAX_SAFE_LIMIT: usize = 16384; // 16 KB upper physical safety limit (~20% VBlank)

pub const DmaQueue = struct {
    tasks: [CAPACITY]hal.dma.DmaTask = undefined,
    head: usize = 0,
    tail: usize = 0,
    task_count: usize = 0,
    staged_bytes: usize = 0,
    max_bytes_per_vblank: usize = DEFAULT_MAX_BYTES_PER_VBLANK,

    pub fn init() DmaQueue {
        return .{};
    }

    pub fn reset(self: *DmaQueue) void {
        self.head = 0;
        self.tail = 0;
        self.task_count = 0;
        self.staged_bytes = 0;
        self.max_bytes_per_vblank = DEFAULT_MAX_BYTES_PER_VBLANK;
    }

    /// Dynamically adjust the maximum allowed VBlank transfer budget for the active scene.
    pub fn setMaxBytesPerVblank(self: *DmaQueue, bytes: usize) void {
        self.max_bytes_per_vblank = @min(bytes, HARDWARE_MAX_SAFE_LIMIT);
    }

    pub fn getMaxBytesPerVblank(self: *const DmaQueue) usize {
        return self.max_bytes_per_vblank;
    }

    pub fn enqueue(self: *DmaQueue, task: hal.dma.DmaTask) DmaQueueError!void {
        if (self.task_count >= CAPACITY) {
            return error.QueueFull;
        }

        const task_bytes = @as(usize, task.count) * (if (task.unit == .word_32) @as(usize, 4) else @as(usize, 2));
        if (self.staged_bytes + task_bytes > self.max_bytes_per_vblank) {
            return error.ExceedsVblankBudget;
        }

        self.tasks[self.tail] = task;
        self.tail = (self.tail + 1) % CAPACITY;
        self.task_count += 1;
        self.staged_bytes += task_bytes;
    }

    pub fn enqueueBytes(self: *DmaQueue, src: [*]const u8, dest: [*]volatile u8, bytes: u16) DmaQueueError!void {
        const task = hal.dma.DmaTask.initBytes(src, dest, bytes) catch return error.InvalidTask;
        return self.enqueue(task);
    }

    pub fn flush(self: *DmaQueue) void {
        while (self.task_count > 0) {
            const task = self.tasks[self.head];
            switch (task.unit) {
                .word_32 => {
                    const d_ptr = @as([*]volatile u32, @ptrFromInt(task.dest_address));
                    const s_ptr = @as([*]const u32, @ptrFromInt(task.src_address));
                    hal.dma.copy32(.ch3, d_ptr, s_ptr, task.count) catch {};
                },
                .halfword_16 => {
                    const d_ptr = @as([*]volatile u16, @ptrFromInt(task.dest_address));
                    const s_ptr = @as([*]const u16, @ptrFromInt(task.src_address));
                    hal.dma.copy16(.ch3, d_ptr, s_ptr, task.count) catch {};
                },
            }
            self.head = (self.head + 1) % CAPACITY;
            self.task_count -= 1;
        }
        self.head = 0;
        self.tail = 0;
        self.staged_bytes = 0;
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

test "DMQ005: enqueueBytes helper and clear" {
    var queue = DmaQueue.init();
    var src align(4) = [_]u8{ 10, 20, 30, 40 };
    var dest align(4) = [_]u8{0} ** 4;

    try queue.enqueueBytes(&src, &dest, 4);
    try std.testing.expectEqual(@as(usize, 1), queue.count());
    try std.testing.expectEqual(@as(usize, 4), queue.getStagedBytes());

    queue.clear();
    try std.testing.expect(queue.isEmpty());
    try std.testing.expectEqual(@as(usize, 0), queue.getStagedBytes());
}

test "DMQ006: setMaxBytesPerVblank dynamically reconfigures budget" {
    var queue = DmaQueue.init();
    try std.testing.expectEqual(DEFAULT_MAX_BYTES_PER_VBLANK, queue.getMaxBytesPerVblank());

    // Expand budget to 8 KB for heavy animation scene
    queue.setMaxBytesPerVblank(8192);
    try std.testing.expectEqual(@as(usize, 8192), queue.getMaxBytesPerVblank());

    // Ensure clamp against HARDWARE_MAX_SAFE_LIMIT
    queue.setMaxBytesPerVblank(32768);
    try std.testing.expectEqual(HARDWARE_MAX_SAFE_LIMIT, queue.getMaxBytesPerVblank());
}
