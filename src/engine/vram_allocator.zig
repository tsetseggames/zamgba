const std = @import("std");
const hal = @import("zamgba-hal");
const BppMode = hal.specs.BppMode;

pub const VramError = error{
    OutOfVram,
    InvalidSpriteSize,
    InvalidAlignment,
    BlockNotAllocated,
};

/// Hardware allocation descriptor returned by VramAllocator.
pub const VramAllocation = struct {
    tile_index: u16, // Hardware base tile index (0..1023)
    tile_count: u16, // Number of 32-byte slot units allocated
    byte_offset: u32, // Offset in bytes from OBJ VRAM base (0x06010000)

    pub fn toVramPointer(self: VramAllocation, base_vram: [*]volatile u16) [*]volatile u16 {
        // 1 tile index unit = 32 bytes = 16 u16 words
        return base_vram + (@as(usize, self.tile_index) * 16);
    }
};

const BlockNode = struct {
    order: u4 = 0,
    is_free: bool = false,
    next: i16 = -1,
    prev: i16 = -1,
};

pub const TOTAL_TILES: u16 = 1024;
pub const MAX_ORDER: usize = 10; // 2^10 = 1024

var nodes: [TOTAL_TILES]BlockNode = undefined;
var free_lists: [MAX_ORDER + 1]i16 = undefined;
var free_tile_count: u16 = TOTAL_TILES;
var is_initialized: bool = false;

fn pushFree(order: usize, idx: i16) void {
    const old_head = free_lists[order];
    nodes[@as(usize, @intCast(idx))].next = old_head;
    nodes[@as(usize, @intCast(idx))].prev = -1;
    nodes[@as(usize, @intCast(idx))].is_free = true;
    nodes[@as(usize, @intCast(idx))].order = @as(u4, @intCast(order));

    if (old_head != -1) {
        nodes[@as(usize, @intCast(old_head))].prev = idx;
    }
    free_lists[order] = idx;
}

fn removeFree(order: usize, idx: i16) void {
    const u_idx = @as(usize, @intCast(idx));
    const p = nodes[u_idx].prev;
    const n = nodes[u_idx].next;

    if (p != -1) {
        nodes[@as(usize, @intCast(p))].next = n;
    } else {
        free_lists[order] = n;
    }

    if (n != -1) {
        nodes[@as(usize, @intCast(n))].prev = p;
    }

    nodes[u_idx].next = -1;
    nodes[u_idx].prev = -1;
    nodes[u_idx].is_free = false;
}

fn popFree(order: usize) ?i16 {
    const head = free_lists[order];
    if (head == -1) return null;
    removeFree(order, head);
    return head;
}

/// Initializes or resets the global VRAM Buddy Allocator singleton.
pub fn init() void {
    reset();
}

/// Clears all allocations and resets VRAM state to 1024 contiguous free tiles.
pub fn reset() void {
    for (&nodes) |*n| {
        n.* = .{
            .order = 0,
            .is_free = false,
            .next = -1,
            .prev = -1,
        };
    }
    for (&free_lists) |*head| {
        head.* = -1;
    }

    pushFree(MAX_ORDER, 0);
    free_tile_count = TOTAL_TILES;
    is_initialized = true;
}

/// Calculate the power-of-2 32-byte tile slot units required for a given sprite dimension and bit depth.
pub fn calculateRequiredUnits(width: u16, height: u16, bpp: BppMode) VramError!u16 {
    if (width == 0 or height == 0 or width % 8 != 0 or height % 8 != 0) {
        return error.InvalidSpriteSize;
    }
    const pixels: u32 = @as(u32, width) * @as(u32, height);
    return switch (bpp) {
        .bpp4 => @as(u16, @intCast(pixels / 64)), // pixels / 2 / 32
        .bpp8 => @as(u16, @intCast(pixels / 32)), // pixels / 32
    };
}

/// Allocates a contiguous VRAM block suitable for a sprite with given dimensions and bit depth.
pub fn alloc(width: u16, height: u16, bpp: BppMode) VramError!VramAllocation {
    const units = try calculateRequiredUnits(width, height, bpp);
    return allocUnits(units);
}

/// Computes the smallest power-of-2 buddy tree order (0..10) capable of holding `units`.
/// Example: 1 unit -> Order 0 (2^0 = 1), 32 units -> Order 5 (2^5 = 32), 33 units -> Order 6 (2^6 = 64).
pub fn unitsToOrder(units: u16) usize {
    if (units <= 1) return 0;
    const leading_zeros = @as(usize, @clz(units - 1));
    return 16 - leading_zeros;
}

/// Allocates a block with exact power-of-2 unit count.
pub fn allocUnits(units: u16) VramError!VramAllocation {
    if (!is_initialized) {
        init();
    }
    if (units == 0 or units > TOTAL_TILES) {
        return error.OutOfVram;
    }

    // Determine target buddy order (ceil to power of 2)
    const target_order = unitsToOrder(units);
    if (target_order > MAX_ORDER) {
        return error.OutOfVram;
    }

    // Find smallest available order >= target_order
    var order: usize = target_order;
    while (order <= MAX_ORDER and free_lists[order] == -1) : (order += 1) {}

    if (order > MAX_ORDER) {
        return error.OutOfVram;
    }

    // Pop the block and split buddies downwards if needed
    const blk_idx = popFree(order).?;
    while (order > target_order) {
        order -= 1;
        const buddy_idx = blk_idx + @as(i16, @intCast(@as(u16, 1) << @as(u4, @intCast(order))));
        pushFree(order, buddy_idx);
    }

    nodes[@as(usize, @intCast(blk_idx))].order = @as(u4, @intCast(target_order));
    nodes[@as(usize, @intCast(blk_idx))].is_free = false;

    const allocated_units = @as(u16, 1) << @as(u4, @intCast(target_order));
    free_tile_count -= allocated_units;

    return VramAllocation{
        .tile_index = @as(u16, @intCast(blk_idx)),
        .tile_count = allocated_units,
        .byte_offset = @as(u32, @intCast(blk_idx)) * 32,
    };
}

/// Frees an allocated VRAM block and coalesces adjacent buddies.
pub fn free(alloc_info: VramAllocation) VramError!void {
    if (!is_initialized) return error.BlockNotAllocated;

    const blk_idx = alloc_info.tile_index;
    if (blk_idx >= TOTAL_TILES or nodes[blk_idx].is_free) {
        return error.BlockNotAllocated;
    }

    var current_idx: i16 = @as(i16, @intCast(blk_idx));
    var current_order: usize = nodes[blk_idx].order;
    const allocated_units = @as(u16, 1) << @as(u4, @intCast(current_order));
    free_tile_count += allocated_units;

    // Coalesce buddies upwards
    while (current_order < MAX_ORDER) {
        const buddy_idx = current_idx ^ @as(i16, @intCast(@as(u16, 1) << @as(u4, @intCast(current_order))));
        if (buddy_idx < 0 or buddy_idx >= @as(i16, @intCast(TOTAL_TILES))) break;

        const u_buddy = @as(usize, @intCast(buddy_idx));
        if (nodes[u_buddy].is_free and nodes[u_buddy].order == current_order) {
            removeFree(current_order, buddy_idx);
            current_idx = @min(current_idx, buddy_idx);
            current_order += 1;
        } else {
            break;
        }
    }

    pushFree(current_order, current_idx);
}

/// Returns the total number of free 32-byte 4-bpp tile units currently available.
pub fn getFreeTileCount() u16 {
    if (!is_initialized) return TOTAL_TILES;
    return free_tile_count;
}

test "VRM001: calculateRequiredUnits for 4bpp and 8bpp sizes" {
    // 4-bpp sprites (32 bytes / 8x8 tile)
    try std.testing.expectEqual(@as(u16, 1), try calculateRequiredUnits(8, 8, .bpp4));
    try std.testing.expectEqual(@as(u16, 4), try calculateRequiredUnits(16, 16, .bpp4));
    try std.testing.expectEqual(@as(u16, 16), try calculateRequiredUnits(32, 32, .bpp4));
    try std.testing.expectEqual(@as(u16, 64), try calculateRequiredUnits(64, 64, .bpp4));

    // 8-bpp sprites (64 bytes / 8x8 tile = 2 slot units)
    try std.testing.expectEqual(@as(u16, 2), try calculateRequiredUnits(8, 8, .bpp8));
    try std.testing.expectEqual(@as(u16, 8), try calculateRequiredUnits(16, 16, .bpp8));
    try std.testing.expectEqual(@as(u16, 32), try calculateRequiredUnits(32, 32, .bpp8));
    try std.testing.expectEqual(@as(u16, 128), try calculateRequiredUnits(64, 64, .bpp8));

    // Invalid unaligned sizes
    try std.testing.expectError(error.InvalidSpriteSize, calculateRequiredUnits(7, 8, .bpp4));
    try std.testing.expectError(error.InvalidSpriteSize, calculateRequiredUnits(0, 16, .bpp4));
}

test "VRM002: alloc single 8x8 4bpp sprite (1 unit)" {
    reset();
    const a1 = try alloc(8, 8, .bpp4);
    try std.testing.expectEqual(@as(u16, 0), a1.tile_index);
    try std.testing.expectEqual(@as(u16, 1), a1.tile_count);
    try std.testing.expectEqual(@as(u32, 0), a1.byte_offset);
}

test "VRM003: alloc 32x32 8bpp sprite (32 units)" {
    reset();
    const a1 = try alloc(32, 32, .bpp8);
    try std.testing.expectEqual(@as(u16, 0), a1.tile_index);
    try std.testing.expectEqual(@as(u16, 32), a1.tile_count);
    try std.testing.expectEqual(@as(u32, 0), a1.byte_offset);
}

test "VRM004: buddy splitting and merging on free" {
    reset();
    const a1 = try alloc(16, 16, .bpp4); // 4 units (index 0..3)
    const a2 = try alloc(16, 16, .bpp4); // 4 units (index 4..7)

    try std.testing.expectEqual(@as(u16, 0), a1.tile_index);
    try std.testing.expectEqual(@as(u16, 4), a2.tile_index);

    try free(a1);
    try free(a2);

    try std.testing.expectEqual(TOTAL_TILES, getFreeTileCount());
}

test "VRM005: OutOfVram error when memory exhausted" {
    reset();
    // 64x64 8-bpp sprite takes 128 units. 8 such sprites consume 8 * 128 = 1024 units (100% VRAM).
    var i: usize = 0;
    while (i < 8) : (i += 1) {
        _ = try alloc(64, 64, .bpp8);
    }

    // 9th allocation must fail
    try std.testing.expectError(error.OutOfVram, alloc(8, 8, .bpp4));
}

test "VRM006: free invalid block or double-free returns BlockNotAllocated" {
    reset();
    const a1 = try alloc(16, 16, .bpp4);
    try free(a1);

    // Double-free must fail
    try std.testing.expectError(error.BlockNotAllocated, free(a1));

    // Invalid tile index must fail
    const invalid_alloc = VramAllocation{
        .tile_index = 2000,
        .tile_count = 4,
        .byte_offset = 2000 * 32,
    };
    try std.testing.expectError(error.BlockNotAllocated, free(invalid_alloc));
}

test "VRM007: allocUnits edge cases and toVramPointer" {
    reset();
    try std.testing.expectError(error.OutOfVram, allocUnits(0));
    try std.testing.expectError(error.OutOfVram, allocUnits(2048));

    const a = try allocUnits(16);
    // Mock base VRAM address
    const mock_vram = @as([*]volatile u16, @ptrFromInt(0x06010000));
    const ptr = a.toVramPointer(mock_vram);
    try std.testing.expectEqual(@as(usize, 0x06010000), @intFromPtr(ptr));
}

test "VRM008: unitsToOrder computes exact power-of-2 order" {
    try std.testing.expectEqual(@as(usize, 0), unitsToOrder(0));
    try std.testing.expectEqual(@as(usize, 0), unitsToOrder(1));
    try std.testing.expectEqual(@as(usize, 1), unitsToOrder(2));
    try std.testing.expectEqual(@as(usize, 2), unitsToOrder(3)); // Ceil: 3 -> 4 (Order 2)
    try std.testing.expectEqual(@as(usize, 2), unitsToOrder(4));
    try std.testing.expectEqual(@as(usize, 3), unitsToOrder(8));
    try std.testing.expectEqual(@as(usize, 4), unitsToOrder(16));
    try std.testing.expectEqual(@as(usize, 5), unitsToOrder(32));
    try std.testing.expectEqual(@as(usize, 6), unitsToOrder(64));
    try std.testing.expectEqual(@as(usize, 7), unitsToOrder(128));
    try std.testing.expectEqual(@as(usize, 10), unitsToOrder(1024));
}
