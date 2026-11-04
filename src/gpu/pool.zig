//! Resource pools with generation-counted slots, from sokol_gfx.h:8373-8670.
const std = @import("std");
const e = @import("enums.zig");

pub const slot_shift = 16;
pub const slot_mask: u32 = (1 << slot_shift) - 1;
pub const max_pool_size = 1 << slot_shift;

pub const Slot = struct {
    id: u32 = 0,
    uninit_count: u32 = 0,
    state: e.ResourceState = .initial,
};

/// A resource id plus uninit count, used to detect stale references.
pub const SlotRef = struct {
    id: u32 = 0,
    uninit_count: u32 = 0,

    pub fn of(slot: *const Slot) SlotRef {
        return .{ .id = slot.id, .uninit_count = slot.uninit_count };
    }
    pub fn eqlSlot(self: SlotRef, slot: *const Slot) bool {
        return self.id == slot.id and self.uninit_count == slot.uninit_count;
    }
};

pub fn slotIndex(id: u32) usize {
    const index = id & slot_mask;
    std.debug.assert(index != 0);
    return index;
}

/// A fixed-capacity pool of resources of type `T`, which must have a `slot: Slot`
/// field. Item 0 is reserved for the invalid id.
pub fn Pool(comptime T: type) type {
    return struct {
        const Self = @This();
        items: []T,
        gen_ctrs: []u32,
        free_queue: []u32,
        queue_top: usize,

        pub fn init(allocator: std.mem.Allocator, num: usize) !Self {
            std.debug.assert(num >= 1 and num < max_pool_size);
            const size = num + 1;
            const items = try allocator.alloc(T, size);
            errdefer allocator.free(items);
            @memset(items, .{});
            const gen_ctrs = try allocator.alloc(u32, size);
            errdefer allocator.free(gen_ctrs);
            @memset(gen_ctrs, 0);
            const free_queue = try allocator.alloc(u32, num);
            // never allocate the zero-th pool item since the invalid id is 0
            for (free_queue, 0..) |*index, i| index.* = @intCast(size - 1 - i);
            return .{ .items = items, .gen_ctrs = gen_ctrs, .free_queue = free_queue, .queue_top = num };
        }

        pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
            allocator.free(self.free_queue);
            allocator.free(self.gen_ctrs);
            allocator.free(self.items);
            self.* = undefined;
        }

        /// Allocates a slot and returns its new id, or null if the pool is exhausted.
        pub fn alloc(self: *Self) ?u32 {
            if (self.queue_top == 0) return null;
            self.queue_top -= 1;
            const index = self.free_queue[self.queue_top];
            std.debug.assert(index > 0 and index < self.items.len);
            const slot = &self.items[index].slot;
            std.debug.assert(slot.id == 0 and slot.state == .initial);
            self.gen_ctrs[index] +%= 1;
            slot.id = (self.gen_ctrs[index] << slot_shift) | (index & slot_mask);
            slot.state = .alloc;
            return slot.id;
        }

        /// Returns the slot of an allocated resource to the free queue.
        pub fn free(self: *Self, item: *T) void {
            const index: u32 = @intCast(slotIndex(item.slot.id));
            std.debug.assert(self.queue_top < self.items.len - 1);
            if (std.debug.runtime_safety) {
                for (self.free_queue[0..self.queue_top]) |queued| std.debug.assert(queued != index);
            }
            self.free_queue[self.queue_top] = index;
            self.queue_top += 1;
            item.slot = .{};
        }

        /// Returns the item addressed by an id without checking the id's generation.
        pub fn at(self: *Self, id: u32) *T {
            const index = slotIndex(id);
            std.debug.assert(index < self.items.len);
            return &self.items[index];
        }

        /// Returns the item for an id, or null if the id is invalid or stale.
        pub fn lookup(self: *Self, id: u32) ?*T {
            if (id == 0) return null;
            const index = id & slot_mask;
            if (index == 0 or index >= self.items.len) return null;
            const item = &self.items[index];
            return if (item.slot.id == id) item else null;
        }

        pub fn numAlive(self: *const Self) u32 {
            return @intCast(self.items.len - 1 - self.queue_top);
        }
        pub fn numFree(self: *const Self) u32 {
            return @intCast(self.queue_top);
        }
    };
}
