//! Staging resources plus EVENT queries. Requests enqueue and flush; polling uses
//! DONOTFLUSH queries and DO_NOT_WAIT maps, never a blocking Map on the GPU path.
const std = @import("std");
const core = @import("../../core.zig");
const Task = @import("../../readback_task.zig").Task;
const Backend = @import("backend.zig").Backend;
const sdk = @import("sdk.zig");
const c = @import("../dxgi/constants.zig");
const convert = @import("../dxgi/convert.zig");
const Read = struct {
    task: Task,
    backend: *Backend,
    staging: ?*sdk.Object = null,
    query: ?*sdk.Object = null,
    region: ?core.ReadRegion = null,
    volume: bool = false,
    row_bytes: usize = 0,
    fn create(backend: *Backend, out: []u8) ?*Read {
        const self = backend.allocator.create(Read) catch return null;
        self.* = .{ .task = .{ .owner = core.state(), .allocator = backend.allocator, .data = out, .poll_fn = poll, .destroy_fn = destroy }, .backend = backend };
        const desc: sdk.QueryDesc = .{};
        if (sdk.createQuery(backend.device, &desc, &self.query) < 0 or self.query == null) {
            backend.allocator.destroy(self);
            return null;
        }
        return self;
    }
    fn submit(self: *Read) void {
        sdk.endQuery(self.backend.context, self.query.?);
        sdk.flush(self.backend.context);
    }
    fn poll(task: *Task, wait: bool) error{ReadFailed}!bool {
        const self: *Read = @alignCast(@fieldParentPtr("task", task));
        var ready: u32 = 0;
        while (true) {
            const status = sdk.queryData(self.backend.context, self.query.?, &ready, if (wait) 0 else 1);
            if (status < 0) {
                const reason = sdk.getDeviceRemovedReason(self.backend.device);
                if (reason < 0) core.recordLoss(reason);
                return error.ReadFailed;
            }
            if (status == 0 and ready != 0) break;
            if (!wait) return false;
            std.atomic.spinLoopHint();
        }
        if (task.refs == 1) return true;
        const layers: usize = if (self.volume) 1 else if (self.region) |r| r.num_slices else 1;
        for (0..layers) |layer| {
            var mapped: sdk.MappedSubresource = .{};
            const status = sdk.map(self.backend.context, self.staging, @intCast(layer), c.map_read, if (wait) 0 else 0x100000, @ptrCast(&mapped));
            if (@as(u32, @bitCast(status)) == 0x887a000a) return false; // WAS_STILL_DRAWING
            if (status < 0 or mapped.data == null) return error.ReadFailed;
            defer sdk.unmap(self.backend.context, self.staging, @intCast(layer));
            const source: [*]const u8 = @ptrCast(mapped.data.?);
            if (self.region) |region| {
                const depth: usize = if (self.volume) region.num_slices else 1;
                for (0..depth) |z| for (0..region.height) |row| {
                    const to = (if (self.volume) z else layer) * region.bytes_per_slice + row * region.bytes_per_row;
                    @memcpy(task.data[to..][0..self.row_bytes], source[z * mapped.depth_pitch + row * mapped.row_pitch ..][0..self.row_bytes]);
                };
            } else @memcpy(task.data, source[0..task.data.len]);
        }
        return true;
    }
    fn destroyResources(self: *Read) void {
        sdk.release(self.query);
        sdk.release(self.staging);
        self.task.allocator.destroy(self);
    }
    fn destroy(task: *Task) void {
        const self: *Read = @alignCast(@fieldParentPtr("task", task));
        task.allocator.free(task.data);
        self.destroyResources();
    }
};
pub fn buffer(backend: *Backend, source: *core.Buffer, offset: usize, out: []u8) ?*Task {
    const self = Read.create(backend, out) orelse return null;
    var success = false;
    defer if (!success) self.destroyResources();
    const desc: sdk.BufferDesc = .{ .byte_width = @intCast(out.len), .usage = c.usage_staging, .cpu_access_flags = c.cpu_access_read };
    if (sdk.createBuffer(backend.device, @ptrCast(&desc), null, &self.staging) < 0 or self.staging == null) return null;
    const box: sdk.Box = .{ .left = @intCast(offset), .right = @intCast(offset + out.len), .bottom = 1, .back = 1 };
    sdk.copySubresourceRegion(backend.context, self.staging, 0, 0, 0, 0, source.native.d3d11.object, 0, @ptrCast(&box));
    self.submit();
    success = true;
    return &self.task;
}
pub fn image(backend: *Backend, source: *core.Image, region: *const core.ReadRegion, out: []u8) ?*Task {
    const self = Read.create(backend, out) orelse return null;
    var success = false;
    defer if (!success) self.destroyResources();
    self.region = region.*;
    self.volume = source.cmn.type == .@"3d";
    self.row_bytes = @intCast(core.formats.rowPitch(source.cmn.pixel_format, @intCast(region.width), 1));
    const layers: u32 = if (self.volume) 1 else region.num_slices;
    if (self.volume) {
        const desc: sdk.Texture3DDesc = .{ .width = region.width, .height = region.height, .depth = region.num_slices, .mip_levels = 1, .format = source.native.d3d11.format, .usage = c.usage_staging, .cpu_access_flags = c.cpu_access_read };
        if (sdk.createTexture3D(backend.device, @ptrCast(&desc), null, &self.staging) < 0 or self.staging == null) return null;
    } else {
        const desc: sdk.Texture2DDesc = .{ .width = region.width, .height = region.height, .mip_levels = 1, .array_size = layers, .format = source.native.d3d11.format, .sample_desc = .{ .count = 1 }, .usage = c.usage_staging, .cpu_access_flags = c.cpu_access_read };
        if (sdk.createTexture2D(backend.device, @ptrCast(&desc), null, &self.staging) < 0 or self.staging == null) return null;
    }
    for (0..layers) |layer| {
        const box: sdk.Box = .{ .left = region.x, .top = region.y, .front = if (self.volume) region.slice else 0, .right = region.x + region.width, .bottom = region.y + region.height, .back = if (self.volume) region.slice + region.num_slices else 1 };
        const subresource = convert.subresource(region.mip_level, if (self.volume) 0 else region.slice + @as(u32, @intCast(layer)), @intCast(source.cmn.num_mipmaps));
        sdk.copySubresourceRegion(backend.context, self.staging, @intCast(layer), 0, 0, 0, source.native.d3d11.resource, subresource, @ptrCast(&box));
    }
    self.submit();
    success = true;
    return &self.task;
}
