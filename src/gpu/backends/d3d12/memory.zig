//! Descriptor heaps, the per-frame upload rings, fences and deferred release
//! for the D3D12 backend (DESIGN.md "Memory" and "Descriptors").
const std = @import("std");
const sdk = @import("sdk.zig");
const constants = @import("constants.zig");

/// A CPU-only descriptor heap with a free list, or a shader-visible heap that
/// is sliced per frame (`Frames`).
pub const Heap = struct {
    object: ?*sdk.Object = null,
    start: usize = 0,
    gpu_start: u64 = 0,
    increment: usize = 0,
    capacity: u32 = 0,
    next: u32 = 0,
    free_list: std.ArrayList(u32) = .empty,

    pub fn init(allocator: std.mem.Allocator, device: *sdk.Object, heap_type: u32, capacity: u32, shader_visible: bool) !Heap {
        const desc: sdk.DescriptorHeapDesc = .{
            .type = heap_type,
            .num_descriptors = capacity,
            .flags = if (shader_visible) constants.descriptor_heap_flag_shader_visible else constants.descriptor_heap_flag_none,
        };
        var heap: Heap = .{ .capacity = capacity };
        if (sdk.createDescriptorHeap(device, &desc, &heap.object) < 0 or heap.object == null) return error.D3d12InitFailed;
        errdefer sdk.release(heap.object);
        // Freeing a descriptor must never allocate or silently lose a slot.
        if (!shader_visible) try heap.free_list.ensureTotalCapacity(allocator, capacity);
        heap.start = sdk.heapStartCpu(heap.object.?);
        heap.gpu_start = if (shader_visible) sdk.heapStartGpu(heap.object.?) else 0;
        heap.increment = sdk.getDescriptorHandleIncrementSize(device, heap_type);
        return heap;
    }

    pub fn deinit(self: *Heap, allocator: std.mem.Allocator) void {
        sdk.release(self.object);
        self.free_list.deinit(allocator);
        self.* = .{};
    }

    pub fn handle(self: *const Heap, index: u32) usize {
        return self.start + @as(usize, index) * self.increment;
    }

    /// Allocates one descriptor of a CPU-only heap, or returns 0 when the heap is full.
    pub fn allocate(self: *Heap) usize {
        if (self.free_list.pop()) |index| return self.handle(index);
        if (self.next == self.capacity) return 0;
        self.next += 1;
        return self.handle(self.next - 1);
    }

    pub fn free(self: *Heap, allocator: std.mem.Allocator, descriptor: usize) void {
        if (descriptor == 0) return;
        const index: u32 = @intCast((descriptor - self.start) / self.increment);
        _ = allocator;
        self.free_list.appendAssumeCapacity(index);
    }
};

/// A shader-visible descriptor heap split into one linear slice per frame.
pub const DescriptorRing = struct {
    heap: Heap = .{},
    per_frame: u32 = 0,
    base: u32 = 0,
    used: u32 = 0,

    pub fn begin(self: *DescriptorRing, slot: usize) void {
        self.base = @as(u32, @intCast(slot)) * self.per_frame;
        self.used = 0;
    }

    /// Reserves `count` contiguous descriptors and returns the first CPU and GPU handles.
    pub fn alloc(self: *DescriptorRing, count: u32) ?struct { cpu: usize, gpu: u64 } {
        if (self.used + count > self.per_frame) return null;
        const index = self.base + self.used;
        self.used += count;
        return .{ .cpu = self.heap.handle(index), .gpu = self.heap.gpu_start + @as(u64, index) * self.heap.increment };
    }
};

/// A persistently mapped upload buffer, split into one region per frame.
pub const Upload = struct {
    resource: ?*sdk.Object = null,
    mapped: ?[*]u8 = null,
    gpu_address: u64 = 0,
    per_frame: usize = 0,
    base: usize = 0,
    used: usize = 0,

    pub fn init(device: *sdk.Object, per_frame: usize, frames: usize) !Upload {
        const size = per_frame * frames;
        var self: Upload = .{ .per_frame = per_frame };
        const heap: sdk.HeapProperties = .{ .type = constants.heap_upload };
        if (sdk.createCommittedResource(device, &heap, constants.heap_flag_none, &bufferDesc(size, 0), constants.state_generic_read, &self.resource) < 0 or self.resource == null) return error.D3d12InitFailed;
        var mapped: ?*anyopaque = null;
        if (sdk.resourceMap(self.resource.?, 0, &mapped) < 0 or mapped == null) return error.D3d12InitFailed;
        self.mapped = @ptrCast(mapped);
        self.gpu_address = sdk.resourceGpuAddress(self.resource.?);
        return self;
    }

    pub fn deinit(self: *Upload) void {
        if (self.resource) |resource| sdk.resourceUnmap(resource, 0);
        sdk.release(self.resource);
        self.* = .{};
    }

    pub fn begin(self: *Upload, slot: usize) void {
        self.base = slot * self.per_frame;
        self.used = 0;
    }

    pub const Region = struct { resource: *sdk.Object, offset: u64, ptr: [*]u8, gpu: u64 };

    /// Reserves `size` bytes aligned to `alignment` in the current frame's region.
    pub fn alloc(self: *Upload, size: usize, alignment: usize) ?Region {
        const start = std.mem.alignForward(usize, self.base + self.used, alignment);
        if (start + size > self.base + self.per_frame) return null;
        self.used = start + size - self.base;
        return .{
            .resource = self.resource.?,
            .offset = start,
            .ptr = self.mapped.? + start,
            .gpu = self.gpu_address + start,
        };
    }
};

/// CPU descriptor heaps by kind, indexed by `Kind`.
pub const Kind = enum(u8) { view = 0, sampler = 1, rtv = 2, dsv = 3 };

/// A COM object or descriptor that the GPU may still reference, released once
/// `fence_value` has completed.
pub const Deferred = struct {
    fence_value: u64,
    item: union(enum) {
        object: *sdk.Object,
        descriptor: struct { kind: Kind, handle: usize },
    },
};

pub fn bufferDesc(size: usize, flags: u32) sdk.ResourceDesc {
    return .{
        .dimension = constants.dimension_buffer,
        .width = size,
        .height = 1,
        .depth_or_array_size = 1,
        .mip_levels = 1,
        .format = 0,
        .sample_desc = .{ .count = 1, .quality = 0 },
        .layout = constants.texture_layout_row_major,
        .flags = flags,
    };
}

/// Waits until the fence reached `value`, blocking the calling thread.
pub fn waitFence(fence: *sdk.Object, event: sdk.Handle, value: u64) void {
    while (true) {
        const completed = sdk.fenceCompletedValue(fence);
        if (completed == std.math.maxInt(u64)) {
            @import("../../core.zig").recordLoss(@bitCast(@as(u32, 0x887a0005)));
            return;
        }
        if (completed >= value) return;
        // An event-registration failure (including OOM) is not completion. Keep
        // the objects alive and retry/poll; a null event is a valid blocking wait.
        if (sdk.fenceSetEventOnCompletion(fence, value, event) >= 0) {
            if (event != null) sdk.waitEvent(event, sdk.infinite);
        } else std.atomic.spinLoopHint();
    }
}
