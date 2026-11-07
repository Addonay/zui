//! Pool of Objective-C objects referenced by small integer ids, with a deferred
//! release queue, from sokol_gfx.h:16010-16480 (_sg_mtl_idpool_t and its functions).
//!
//! The pool owns the objects it stores: `addResource` takes over one reference, and
//! the object is released when the resource is garbage-collected, a few frames after
//! `releaseResource`. Slot 0 is reserved and means "no object".
const std = @import("std");
const core = @import("../../core.zig");
const t = @import("../../types.zig");
const constants = @import("../../constants.zig");
const sdk = @import("sdk.zig");

const invalid_slot: i32 = 0;

pub const IdPool = struct {
    const ReleaseItem = struct {
        /// Frame index at which it is safe to release the object.
        frame_index: u32 = 0,
        slot_index: i32 = invalid_slot,
    };

    /// Objects by slot index, null for free slots and slot 0.
    objects: []sdk.Id,
    num_slots: i32,
    free_queue: []i32,
    free_queue_top: i32,
    release_queue: []ReleaseItem,
    release_queue_front: i32,
    release_queue_back: i32,

    /// Sizes the pool from the descriptor pool sizes (_sg_mtl_init_pool).
    pub fn init(allocator: std.mem.Allocator, desc: *const t.Desc) !IdPool {
        const num_slots: i32 = 2 *
            (2 * desc.buffer_pool_size +
                2 * desc.image_pool_size +
                1 * desc.sampler_pool_size +
                6 * desc.shader_pool_size +
                3 * desc.pipeline_pool_size +
                1 * desc.view_pool_size +
                128);
        const count: usize = @intCast(num_slots);
        const objects = try allocator.alloc(sdk.Id, count);
        errdefer allocator.free(objects);
        @memset(objects, null);
        const free_queue = try allocator.alloc(i32, count);
        errdefer allocator.free(free_queue);
        const release_queue = try allocator.alloc(ReleaseItem, count);
        errdefer allocator.free(release_queue);
        @memset(release_queue, .{});

        var pool: IdPool = .{
            .objects = objects,
            .num_slots = num_slots,
            .free_queue = free_queue,
            .free_queue_top = 0,
            .release_queue = release_queue,
            .release_queue_front = 0,
            .release_queue_back = 0,
        };
        // slot 0 is reserved, the free queue hands out the others in ascending order
        var i: i32 = num_slots - 1;
        while (i >= 1) : (i -= 1) {
            pool.free_queue[@intCast(pool.free_queue_top)] = i;
            pool.free_queue_top += 1;
        }
        return pool;
    }

    /// Releases every object still in the pool and frees the arrays (_sg_mtl_destroy_pool).
    pub fn deinit(self: *IdPool, allocator: std.mem.Allocator) void {
        for (self.objects) |object| sdk.release(object);
        allocator.free(self.release_queue);
        allocator.free(self.free_queue);
        allocator.free(self.objects);
        self.* = undefined;
    }

    fn allocSlot(self: *IdPool) i32 {
        std.debug.assert(self.free_queue_top > 0);
        self.free_queue_top -= 1;
        const slot = self.free_queue[@intCast(self.free_queue_top)];
        std.debug.assert(slot > 0 and slot < self.num_slots);
        return slot;
    }

    fn freeSlot(self: *IdPool, slot: i32) void {
        std.debug.assert(self.free_queue_top < self.num_slots);
        std.debug.assert(slot > 0 and slot < self.num_slots);
        self.free_queue[@intCast(self.free_queue_top)] = slot;
        self.free_queue_top += 1;
    }

    /// Takes over one reference to `object`, returns its slot or 0 for null.
    pub fn addResource(self: *IdPool, object: sdk.Id) i32 {
        if (object == null) return invalid_slot;
        core.statsInc("metal.idpool.num_added");
        const slot = self.allocSlot();
        std.debug.assert(self.objects[@intCast(slot)] == null);
        self.objects[@intCast(slot)] = object;
        return slot;
    }

    /// Queues the object in `slot` for release once the frames in flight have finished
    /// with it. Slot 0 is ignored.
    pub fn releaseResource(self: *IdPool, frame_index: u32, slot: i32) void {
        if (slot == invalid_slot) return;
        core.statsInc("metal.idpool.num_released");
        std.debug.assert(slot > 0 and slot < self.num_slots);
        std.debug.assert(self.objects[@intCast(slot)] != null);
        const release_index: usize = @intCast(self.release_queue_front);
        self.release_queue_front += 1;
        if (self.release_queue_front >= self.num_slots) {
            // wrap-around
            self.release_queue_front = 0;
        }
        // release queue full?
        std.debug.assert(self.release_queue_front != self.release_queue_back);
        std.debug.assert(self.release_queue[release_index].frame_index == 0);
        const safe_to_release_frame_index = frame_index + @as(u32, constants.num_inflight_frames) + 1;
        self.release_queue[release_index] = .{ .frame_index = safe_to_release_frame_index, .slot_index = slot };
    }

    /// Releases the objects whose release frame has passed (_sg_mtl_garbage_collect).
    pub fn garbageCollect(self: *IdPool, frame_index: u32) void {
        while (self.release_queue_back != self.release_queue_front) {
            const back: usize = @intCast(self.release_queue_back);
            if (frame_index < self.release_queue[back].frame_index) {
                // release items past this one are too young
                break;
            }
            core.statsInc("metal.idpool.num_garbage_collected");
            const slot = self.release_queue[back].slot_index;
            std.debug.assert(slot > 0 and slot < self.num_slots);
            std.debug.assert(self.objects[@intCast(slot)] != null);
            // the pool owns the reference, dropping it releases the object
            const object = self.objects[@intCast(slot)];
            self.objects[@intCast(slot)] = null;
            sdk.release(object);
            self.freeSlot(slot);
            self.release_queue[back] = .{};
            self.release_queue_back += 1;
            if (self.release_queue_back >= self.num_slots) {
                // wrap-around
                self.release_queue_back = 0;
            }
        }
    }

    /// The object in `slot`, borrowed from the pool (_sg_mtl_id).
    pub fn id(self: *const IdPool, slot: i32) sdk.Id {
        return self.objects[@intCast(slot)];
    }
};
