//! Non-blocking GL/GLES/WebGL2 readback through private pixel-pack/copy buffers
//! and fence objects. All memory views are created only after the fence signals.
const std = @import("std");
const builtin = @import("builtin");
const core = @import("../../core.zig");
const e = @import("../../enums.zig");
const formats = @import("../../formats.zig");
const t = @import("../../types.zig");
const c = @import("constants.zig");
const convert = @import("convert.zig");
const Backend = @import("backend.zig").Backend;
const Task = @import("../../readback_task.zig").Task;
const pack_buffer = 0x88EB;
const stream_read = 0x88E1;
const Read = struct {
    task: Task,
    backend: *Backend,
    buffer: u32 = 0,
    framebuffer: u32 = 0,
    fence: ?*anyopaque = null,
    transfer_size: usize,
    region: ?core.ReadRegion = null,
    pixel_format: e.PixelFormat = .none,
    read_type: u32 = 0,
    fn create(backend: *Backend, out: []u8, bytes: usize, index: bool) ?*Read {
        const driver = backend.cache.driver;
        if (driver.fenceSync == null or driver.clientWaitSync == null or driver.deleteSync == null or driver.flush == null) return null;
        const size = std.math.cast(isize, bytes) orelse return null;
        const self = backend.allocator.create(Read) catch return null;
        self.* = .{ .task = .{ .owner = core.state(), .allocator = backend.allocator, .data = out, .poll_fn = poll, .destroy_fn = destroy }, .backend = backend, .transfer_size = bytes };
        driver.genBuffers.?(1, @ptrCast(&self.buffer));
        if (self.buffer == 0) {
            backend.allocator.destroy(self);
            return null;
        }
        // WebGL copy operations preserve the index/other buffer category. Creating
        // an index destination must restore the VAO's element binding afterwards.
        const target: u32 = if (index and builtin.cpu.arch.isWasm()) c.element_array_buffer else c.copy_write_buffer;
        var saved: i32 = 0;
        if (target == c.element_array_buffer) driver.getIntegerv.?(0x8895, @ptrCast(&saved));
        driver.bindBuffer.?(target, self.buffer);
        driver.bufferData.?(target, size, null, stream_read);
        driver.bindBuffer.?(target, @bitCast(saved));
        return self;
    }
    fn finish(self: *Read) bool {
        const driver = self.backend.cache.driver;
        self.fence = driver.fenceSync.?(0x9117, 0); // GL_SYNC_GPU_COMMANDS_COMPLETE
        if (self.fence == null) return false;
        driver.flush.?();
        return true;
    }
    fn poll(task: *Task, wait: bool) error{ReadFailed}!bool {
        const self: *Read = @fieldParentPtr("task", task);
        const driver = self.backend.cache.driver;
        var status = driver.clientWaitSync.?(self.fence, 0, 0);
        if (wait and status == 0x911B and !builtin.cpu.arch.isWasm()) {
            status = driver.clientWaitSync.?(self.fence, 1, std.math.maxInt(u64));
        }
        if (status == 0x911B) {
            // WebGL cannot block its event loop at teardown. GL deletion retains
            // queued object references, so cancelling an unfinished PBO is safe.
            if (wait and builtin.cpu.arch.isWasm()) return error.ReadFailed;
            return false;
        }
        if (status != 0x911A and status != 0x911C) return error.ReadFailed;
        if (task.refs == 1) return true;
        const scratch = task.allocator.alloc(u8, self.transfer_size) catch return error.ReadFailed;
        defer task.allocator.free(scratch);
        driver.bindBuffer.?(c.copy_read_buffer, self.buffer);
        defer driver.bindBuffer.?(c.copy_read_buffer, 0);
        if (!self.backend.gles or builtin.cpu.arch.isWasm()) {
            const get = driver.getBufferSubData orelse return error.ReadFailed;
            get(c.copy_read_buffer, 0, @intCast(scratch.len), scratch.ptr);
        } else {
            const map = driver.mapBufferRange orelse return error.ReadFailed;
            const source: [*]const u8 = @ptrCast(map(c.copy_read_buffer, 0, @intCast(scratch.len), c.map_read_bit) orelse return error.ReadFailed);
            @memcpy(scratch, source[0..scratch.len]);
            if (driver.unmapBuffer.?(c.copy_read_buffer) == 0) return error.ReadFailed;
        }
        if (self.region) |region| {
            const type_size = scalarSize(self.read_type);
            const output_bpp: usize = @intCast(formats.pixelSize(self.pixel_format));
            const components = if (self.pixel_format == .rgb10a2 or self.pixel_format == .rg11b10f) 0 else output_bpp / scalarSize(convert.pixelType(self.pixel_format));
            for (0..region.num_slices) |slice| for (0..region.height) |row| for (0..region.width) |col| {
                const at = ((slice * region.height + row) * region.width + col) * 4 * type_size;
                const to = slice * region.bytes_per_slice + row * region.bytes_per_row + col * output_bpp;
                const dst = task.data[to..][0..output_bpp];
                if (self.pixel_format == .rgb10a2) {
                    const rgba: [4]f32 = @bitCast(scratch[at..][0..16].*);
                    const encoded: u32 = @as(u32, @intFromFloat(@round(std.math.clamp(rgba[0], 0, 1) * 1023))) |
                        (@as(u32, @intFromFloat(@round(std.math.clamp(rgba[1], 0, 1) * 1023))) << 10) |
                        (@as(u32, @intFromFloat(@round(std.math.clamp(rgba[2], 0, 1) * 1023))) << 20) |
                        (@as(u32, @intFromFloat(@round(std.math.clamp(rgba[3], 0, 1) * 3))) << 30);
                    @memcpy(dst, std.mem.asBytes(&encoded));
                } else if (self.pixel_format == .rg11b10f) {
                    const rgba: [4]f32 = @bitCast(scratch[at..][0..16].*);
                    const r: u16 = @bitCast(@as(f16, @floatCast(rgba[0])));
                    const g: u16 = @bitCast(@as(f16, @floatCast(rgba[1])));
                    const b: u16 = @bitCast(@as(f16, @floatCast(rgba[2])));
                    const encoded: u32 = (@as(u32, r >> 4) & 0x7ff) | ((@as(u32, g >> 4) & 0x7ff) << 11) | ((@as(u32, b >> 5) & 0x3ff) << 22);
                    @memcpy(dst, std.mem.asBytes(&encoded));
                } else if (convert.pixelType(self.pixel_format) == c.half_float) {
                    for (0..components) |component| {
                        const value: f32 = @bitCast(scratch[at + component * 4 ..][0..4].*);
                        const half: f16 = @floatCast(value);
                        @memcpy(dst[component * 2 ..][0..2], std.mem.asBytes(&half));
                    }
                } else if (self.read_type == c.int or self.read_type == c.unsigned_int) {
                    const output_size = output_bpp / components;
                    for (0..components) |component| {
                        const raw: u32 = @bitCast(scratch[at + component * 4 ..][0..4].*);
                        switch (output_size) {
                            1 => dst[component] = @truncate(raw),
                            2 => {
                                const value: u16 = @truncate(raw);
                                @memcpy(dst[component * 2 ..][0..2], std.mem.asBytes(&value));
                            },
                            else => @memcpy(dst[component * 4 ..][0..4], std.mem.asBytes(&raw)),
                        }
                    }
                } else {
                    @memcpy(dst, scratch[at..][0..output_bpp]);
                    if (self.pixel_format == .bgra8) std.mem.swap(u8, &dst[0], &dst[2]);
                }
            };
        } else @memcpy(task.data, scratch[0..task.data.len]);
        return true;
    }
    fn destroyResources(self: *Read) void {
        const driver = self.backend.cache.driver;
        if (self.fence != null) driver.deleteSync.?(self.fence);
        if (self.framebuffer != 0) driver.deleteFramebuffers.?(1, @ptrCast(&self.framebuffer));
        if (self.buffer != 0) driver.deleteBuffers.?(1, @ptrCast(&self.buffer));
        self.task.allocator.destroy(self);
    }
    fn destroy(task: *Task) void {
        const self: *Read = @fieldParentPtr("task", task);
        task.allocator.free(task.data);
        self.destroyResources();
    }
};
fn scalarSize(kind: u32) usize {
    return switch (kind) {
        c.byte, c.unsigned_byte => 1,
        c.short, c.unsigned_short, c.half_float => 2,
        else => 4,
    };
}
pub fn buffer(backend: *Backend, source: *core.Buffer, offset: usize, out: []u8) ?*Task {
    const driver = backend.cache.driver;
    if (backend.cache.features.compute and source.native.gl.gpu_dirty != 0) driver.memoryBarrier.?(c.all_barrier_bits);
    const self = Read.create(backend, out, out.len, source.cmn.usage.index_buffer) orelse return null;
    var success = false;
    defer if (!success) self.destroyResources();
    driver.bindBuffer.?(c.copy_read_buffer, source.native.gl.ids[@intCast(source.cmn.active_slot)]);
    driver.bindBuffer.?(c.copy_write_buffer, self.buffer);
    driver.copyBufferSubData.?(c.copy_read_buffer, c.copy_write_buffer, @intCast(offset), 0, @intCast(out.len));
    driver.bindBuffer.?(c.copy_read_buffer, 0);
    driver.bindBuffer.?(c.copy_write_buffer, 0);
    if (!self.finish()) return null;
    success = true;
    return &self.task;
}
pub fn image(backend: *Backend, source: *core.Image, region: *const core.ReadRegion, out: []u8) ?*Task {
    backend.resetTextureMipRange(&source.native.gl, source.desc, source.cmn.active_slot);
    const driver = backend.cache.driver;
    if (backend.cache.features.compute and source.native.gl.gpu_dirty != 0) driver.memoryBarrier.?(c.all_barrier_bits);
    const fmt = source.cmn.pixel_format;
    if (builtin.cpu.arch.isWasm() and (fmt == .rgb10a2 or fmt == .rg11b10f)) return null;
    const original_type = convert.pixelType(fmt);
    const integer = switch (convert.pixelFormat(fmt)) {
        c.red_integer, c.rg_integer, c.rgba_integer => true,
        else => false,
    };
    const read_type = if (integer) (if (original_type == c.byte or original_type == c.short or original_type == c.int) c.int else c.unsigned_int) else if (original_type == c.half_float or fmt == .rgb10a2 or fmt == .rg11b10f) c.float else original_type;
    const slice_bytes = std.math.mul(usize, region.width, region.height) catch return null;
    const bytes = std.math.mul(usize, std.math.mul(usize, slice_bytes, region.num_slices) catch return null, 4 * scalarSize(read_type)) catch return null;
    const self = Read.create(backend, out, bytes, false) orelse return null;
    var success = false;
    defer if (!success) self.destroyResources();
    self.region = region.*;
    self.pixel_format = fmt;
    self.read_type = read_type;
    var saved: i32 = 0;
    driver.getIntegerv.?(c.framebuffer_binding, @ptrCast(&saved));
    defer driver.bindFramebuffer.?(c.framebuffer, @bitCast(saved));
    driver.genFramebuffers.?(1, @ptrCast(&self.framebuffer));
    if (self.framebuffer == 0) return null;
    driver.bindFramebuffer.?(c.framebuffer, self.framebuffer);
    driver.bindBuffer.?(pack_buffer, self.buffer);
    defer driver.bindBuffer.?(pack_buffer, 0);
    driver.pixelStorei.?(c.pack_alignment, 1);
    driver.pixelStorei.?(c.pack_row_length, 0);
    defer driver.pixelStorei.?(c.pack_alignment, 4);
    driver.readBuffer.?(c.color_attachment0);
    for (0..region.num_slices) |slice| {
        const texture = source.native.gl.ids[@intCast(source.cmn.active_slot)];
        const mip: i32 = @intCast(region.mip_level);
        const layer: i32 = @intCast(region.slice + slice);
        switch (source.cmn.type) {
            .@"2d" => driver.framebufferTexture2D.?(c.framebuffer, c.color_attachment0, source.native.gl.target, texture, mip),
            .cube => driver.framebufferTexture2D.?(c.framebuffer, c.color_attachment0, convert.cubeFace(layer), texture, mip),
            else => driver.framebufferTextureLayer.?(c.framebuffer, c.color_attachment0, texture, mip, layer),
        }
        if (driver.checkFramebufferStatus.?(c.framebuffer) != c.framebuffer_complete) return null;
        const offset = slice * slice_bytes * 4 * scalarSize(read_type);
        driver.readPixels.?(@intCast(region.x), @intCast(region.y), @intCast(region.width), @intCast(region.height), if (integer) c.rgba_integer else c.rgba, read_type, if (offset == 0) null else @ptrFromInt(offset));
    }
    if (!self.finish()) return null;
    success = true;
    return &self.task;
}
