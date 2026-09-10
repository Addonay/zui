//! Null GPU device: validates every call, stores nothing, counts everything.
//!
//! Reference template for the real drivers, same role `platform/null.zig`
//! plays for windowing. Resource creation enforces the shared `Tracker`
//! pools; uploads/downloads additionally validate sizes against recorded
//! create-info; `mapTransferBuffer` hands out a fixed scratch slice so
//! staging code paths run unmodified. Used by headless tests and as the
//! last-resort fallback in `preferredOrder()`.
//!
//! TODO(gpu-null): uploads/downloads validate but move no bytes. If a test
//! ever needs byte-fidelity through staging (write → upload → download →
//! compare), back one transfer buffer with map_scratch instead of only
//! counting. Not needed yet — no test does this.

const std = @import("std");
const device = @import("device.zig");
const scene_mod = @import("scene.zig");
const limits = @import("../core/limits.zig");

const TextureMeta = struct {
    info: device.TextureCreateInfo = .{},
    live: bool = false,
};

pub const NullDevice = struct {
    tracker: device.Tracker = .{ .kind = .null },
    buffer_sizes: [limits.MAX_GPU_BUFFERS + 1]u32 = std.mem.zeroes([limits.MAX_GPU_BUFFERS + 1]u32),
    transfer_sizes: [limits.MAX_GPU_TRANSFER_BUFFERS + 1]u32 = std.mem.zeroes([limits.MAX_GPU_TRANSFER_BUFFERS + 1]u32),
    textures: [limits.MAX_GPU_TEXTURES + 1]TextureMeta = std.mem.zeroes([limits.MAX_GPU_TEXTURES + 1]TextureMeta),
    map_scratch: [limits.NULL_DEVICE_MAP_BYTES]u8 = std.mem.zeroes([limits.NULL_DEVICE_MAP_BYTES]u8),
    mapped: ?device.TransferBuffer = null,
    uploads: u64 = 0,
    downloads: u64 = 0,
    blits: u64 = 0,
    mipmaps: u64 = 0,
    passes_begun: u64 = 0,

    pub const vtable: device.VTable = makeVTable();

    fn makeVTable() device.VTable {
        // Null shares every stub behavior except the calls that need real
        // metadata (sizes, map memory, scene counting). Copy the shared
        // table and override those entries.
        var t = device.stub_vtable;
        t.kind = kindFn;
        t.createBuffer = createBufferFn;
        t.createTransferBuffer = createTransferBufferFn;
        t.createTexture = createTextureFn;
        t.createShader = createShaderFn;
        t.createComputePipeline = createComputePipelineFn;
        t.releaseBuffer = releaseBufferFn;
        t.releaseTransferBuffer = releaseTransferBufferFn;
        t.releaseTexture = releaseTextureFn;
        t.copyUploadToTexture = uploadToTextureFn;
        t.copyUploadToBuffer = uploadToBufferFn;
        t.copyDownloadFromTexture = downloadFromTextureFn;
        t.copyDownloadFromBuffer = downloadFromBufferFn;
        t.blitTexture = blitFn;
        t.generateMipmaps = mipmapFn;
        t.mapTransferBuffer = mapFn;
        t.unmapTransferBuffer = unmapFn;
        t.renderPassBegin = renderBeginFn;
        t.computePassBegin = computeBeginFn;
        t.copyPassBegin = copyBeginFn;
        t.acquireSwapchainTexture = acquireSwapchainFn;
        t.waitAndAcquireSwapchainTexture = acquireSwapchainFn;
        t.drawScene = drawSceneFn;
        return t;
    }

    pub fn handle(self: *@This()) device.Device {
        return .{ .ptr = self, .vtable = &vtable };
    }

    fn selfOf(ptr: *anyopaque) *@This() {
        return @ptrCast(@alignCast(ptr));
    }

    fn kindFn(ptr: *anyopaque) device.DeviceKind {
        _ = ptr;
        return .null;
    }

    fn createBufferFn(ptr: *anyopaque, info: device.BufferCreateInfo) device.CreateError!device.Buffer {
        if (info.usage == 0 or info.size == 0) return error.InvalidUsage;
        const self = selfOf(ptr);
        const id = try self.tracker.buffers.alloc();
        self.buffer_sizes[id] = info.size;
        return @fromBackingInt(@intCast(id));
    }

    fn createTransferBufferFn(ptr: *anyopaque, info: device.TransferBufferCreateInfo) device.CreateError!device.TransferBuffer {
        if (info.size == 0) return error.InvalidUsage;
        if (info.size > limits.NULL_DEVICE_MAP_BYTES) return error.InvalidUsage;
        const self = selfOf(ptr);
        const id = try self.tracker.transfer_buffers.alloc();
        self.transfer_sizes[id] = info.size;
        return @fromBackingInt(@intCast(id));
    }

    fn createTextureFn(ptr: *anyopaque, info: device.TextureCreateInfo) device.CreateError!device.Texture {
        if (info.usage == 0 or info.width == 0 or info.height == 0) return error.InvalidUsage;
        if (info.format == .invalid) return error.UnsupportedFormat;
        const self = selfOf(ptr);
        const id = try self.tracker.textures.alloc();
        self.textures[id] = .{ .info = info, .live = true };
        return @fromBackingInt(@intCast(id));
    }

    // Null stores no code, so any declared format is accepted — format
    // gating is a real-driver job (stub_vtable enforces it via
    // shaderFormatsFor). Usage errors (empty code) still fail.
    fn createShaderFn(ptr: *anyopaque, info: device.ShaderCreateInfo) device.CreateError!device.Shader {
        if (info.code.len == 0 or info.entrypoint.len == 0) return error.InvalidUsage;
        return @fromBackingInt(@intCast(try selfOf(ptr).tracker.shaders.alloc()));
    }

    fn createComputePipelineFn(ptr: *anyopaque, info: device.ComputePipelineCreateInfo) device.CreateError!device.ComputePipeline {
        if (info.code.len == 0) return error.InvalidUsage;
        return @fromBackingInt(@intCast(try selfOf(ptr).tracker.compute_pipelines.alloc()));
    }

    fn releaseBufferFn(ptr: *anyopaque, b: device.Buffer) void {
        const self = selfOf(ptr);
        if (self.tracker.buffers.free(@backingInt(b))) self.buffer_sizes[@backingInt(b)] = 0;
    }

    fn releaseTransferBufferFn(ptr: *anyopaque, t: device.TransferBuffer) void {
        const self = selfOf(ptr);
        if (self.mapped == t) self.mapped = null;
        if (self.tracker.transfer_buffers.free(@backingInt(t))) self.transfer_sizes[@backingInt(t)] = 0;
    }

    fn releaseTextureFn(ptr: *anyopaque, t: device.Texture) void {
        const self = selfOf(ptr);
        if (self.tracker.textures.free(@backingInt(t))) self.textures[@backingInt(t)].live = false;
    }

    fn checkTexture(self: *@This(), t: device.Texture) bool {
        const id = @backingInt(t);
        return id != 0 and id <= limits.MAX_GPU_TEXTURES and self.textures[id].live;
    }

    fn uploadToTextureFn(ptr: *anyopaque, cmd: *device.CommandBuffer, src: device.TextureTransferInfo, region: device.TextureRegion, cycle: bool) void {
        _ = cycle;
        _ = cmd;
        const self = selfOf(ptr);
        // Validate against recorded metadata; store nothing.
        if (!self.tracker.transfer_buffers.isLive(@backingInt(src.transfer_buffer))) return;
        if (!self.checkTexture(region.texture)) return;
        const meta = self.textures[@backingInt(region.texture)].info;
        const need = device.textureFormatSize(meta.format, region.w, region.h);
        const have = self.transfer_sizes[@backingInt(src.transfer_buffer)];
        if (src.offset + need > have) return;
        if (region.x + region.w > meta.width or region.y + region.h > meta.height) return;
        self.uploads += 1;
    }

    fn uploadToBufferFn(ptr: *anyopaque, cmd: *device.CommandBuffer, src: device.TransferBufferLocation, dest: device.BufferRegion, cycle: bool) void {
        _ = cycle;
        _ = cmd;
        const self = selfOf(ptr);
        if (!self.tracker.transfer_buffers.isLive(@backingInt(src.transfer_buffer))) return;
        if (!self.tracker.buffers.isLive(@backingInt(dest.buffer))) return;
        if (src.offset + dest.size > self.transfer_sizes[@backingInt(src.transfer_buffer)]) return;
        if (dest.offset + dest.size > self.buffer_sizes[@backingInt(dest.buffer)]) return;
        self.uploads += 1;
    }

    fn downloadFromTextureFn(ptr: *anyopaque, cmd: *device.CommandBuffer, region: device.TextureRegion, dest: device.TextureTransferInfo) void {
        _ = cmd;
        const self = selfOf(ptr);
        if (!self.checkTexture(region.texture)) return;
        if (!self.tracker.transfer_buffers.isLive(@backingInt(dest.transfer_buffer))) return;
        self.downloads += 1;
    }

    fn downloadFromBufferFn(ptr: *anyopaque, cmd: *device.CommandBuffer, src: device.BufferRegion, dest: device.TransferBufferLocation) void {
        _ = cmd;
        const self = selfOf(ptr);
        if (!self.tracker.buffers.isLive(@backingInt(src.buffer))) return;
        if (!self.tracker.transfer_buffers.isLive(@backingInt(dest.transfer_buffer))) return;
        self.downloads += 1;
    }

    fn blitFn(ptr: *anyopaque, cmd: *device.CommandBuffer, info: device.BlitInfo) void {
        _ = cmd;
        const self = selfOf(ptr);
        if (!self.checkTexture(info.source.texture)) return;
        if (!self.checkTexture(info.destination.texture)) return;
        self.blits += 1;
    }

    fn mipmapFn(ptr: *anyopaque, cmd: *device.CommandBuffer, t: device.Texture) void {
        _ = cmd;
        const self = selfOf(ptr);
        if (!self.checkTexture(t)) return;
        self.mipmaps += 1;
    }

    fn mapFn(ptr: *anyopaque, t: device.TransferBuffer, cycle: bool) device.MapError![]u8 {
        _ = cycle;
        const self = selfOf(ptr);
        const id = @backingInt(t);
        if (!self.tracker.transfer_buffers.isLive(id)) return error.UnknownHandle;
        if (self.mapped != null) return error.Unsupported; // one mapping at a time, like real drivers
        self.mapped = t;
        return self.map_scratch[0..self.transfer_sizes[id]];
    }

    fn unmapFn(ptr: *anyopaque, t: device.TransferBuffer) void {
        const self = selfOf(ptr);
        if (self.mapped == t) self.mapped = null;
    }

    fn renderBeginFn(ptr: *anyopaque, cmd: *device.CommandBuffer, info: device.RenderPassInfo) device.RenderPass {
        _ = info;
        const self = selfOf(ptr);
        self.passes_begun += 1;
        return .{ .dev = undefined, .cmd = cmd, .open = !cmd.dropped };
    }

    fn computeBeginFn(ptr: *anyopaque, cmd: *device.CommandBuffer, info: device.ComputePassInfo) device.ComputePass {
        _ = info;
        const self = selfOf(ptr);
        self.passes_begun += 1;
        return .{ .dev = undefined, .cmd = cmd, .open = !cmd.dropped };
    }

    fn copyBeginFn(ptr: *anyopaque, cmd: *device.CommandBuffer) device.CopyPass {
        const self = selfOf(ptr);
        self.passes_begun += 1;
        return .{ .dev = undefined, .cmd = cmd, .open = !cmd.dropped };
    }

    fn acquireSwapchainFn(ptr: *anyopaque, cmd: *device.CommandBuffer, surface: device.SurfaceHandle) device.SwapchainTexture {
        _ = cmd;
        _ = surface;
        _ = ptr;
        // Headless: never any swapchain image. Callers must handle .null.
        return .{};
    }

    fn drawSceneFn(ptr: *anyopaque, cmd: *device.CommandBuffer, scene: *const scene_mod.Scene, pixels: []const u8) bool {
        _ = scene;
        _ = pixels;
        _ = cmd;
        const self = selfOf(ptr);
        self.tracker.draws += 1;
        return true;
    }
};

test "null device round-trips one frame" {
    var n = NullDevice{};
    const d = n.handle();
    try std.testing.expectEqual(device.DeviceKind.null, d.kind());
    try std.testing.expectEqualStrings("null", d.driverName());
    d.claim(.{ .tag = .headless });
    try std.testing.expectEqual(@as(u32, 1), n.tracker.claims);
    try std.testing.expect(d.render(&scene_mod.Scene{}, &.{}));
    try std.testing.expectEqual(@as(u64, 1), n.tracker.frames);
    try std.testing.expectEqual(@as(u64, 1), n.tracker.draws);
    try std.testing.expectEqual(@as(u64, 1), n.tracker.submits);
}

test "null device validates uploads against recorded sizes" {
    var n = NullDevice{};
    const d = n.handle();

    const tb = try d.createTransferBuffer(.{ .size = 256 });
    const buf = try d.createBuffer(.{ .usage = device.BufferUsage.vertex, .size = 128 });
    const tex = try d.createTexture(.{
        .format = .r8g8b8a8_unorm,
        .usage = device.TextureUsage.sampler,
        .width = 8,
        .height = 8,
    });

    var cmd = d.acquireCommandBuffer();
    var copy = d.beginCopyPass(&cmd);
    // 8x8 RGBA = 256 bytes: exactly fills the staging buffer.
    copy.uploadToTexture(.{ .transfer_buffer = tb }, .{ .texture = tex, .w = 8, .h = 8 }, false);
    try std.testing.expectEqual(@as(u64, 1), n.uploads);
    // 9x8 would need 288 bytes: rejected, counter unchanged.
    copy.uploadToTexture(.{ .transfer_buffer = tb }, .{ .texture = tex, .w = 9, .h = 8 }, false);
    try std.testing.expectEqual(@as(u64, 1), n.uploads);
    // Buffer upload past the destination size: rejected.
    copy.uploadToBuffer(.{ .transfer_buffer = tb }, .{ .buffer = buf, .size = 129 }, false);
    try std.testing.expectEqual(@as(u64, 1), n.uploads);
    copy.uploadToBuffer(.{ .transfer_buffer = tb }, .{ .buffer = buf, .size = 128 }, false);
    try std.testing.expectEqual(@as(u64, 2), n.uploads);
    copy.downloadFromBuffer(.{ .buffer = buf, .size = 128 }, .{ .transfer_buffer = tb });
    try std.testing.expectEqual(@as(u64, 1), n.downloads);
    copy.end();

    // Map/unmap round-trips through scratch memory.
    const mem = try d.mapTransferBuffer(tb, false);
    try std.testing.expectEqual(@as(usize, 256), mem.len);
    mem[0] = 0xAB;
    try std.testing.expectError(error.Unsupported, d.mapTransferBuffer(tb, false)); // already mapped
    d.unmapTransferBuffer(tb);
    const mem2 = try d.mapTransferBuffer(tb, true);
    try std.testing.expectEqual(@as(u8, 0xAB), mem2[0]);
    d.unmapTransferBuffer(tb);
    try std.testing.expectError(error.UnknownHandle, d.mapTransferBuffer(.null, false));
}

test "null device full graphics frame" {
    var n = NullDevice{};
    const d = n.handle();
    try std.testing.expect(d.claimWindow(.{ .tag = .headless }));
    try std.testing.expectEqual(device.TextureFormat.b8g8r8a8_unorm, d.swapchainTextureFormat(.{ .tag = .headless }));
    try std.testing.expect(d.supportsPresentMode(.{ .tag = .headless }, .vsync));
    try std.testing.expect(!d.supportsPresentMode(.{ .tag = .headless }, .immediate));

    const vs = try d.createShader(.{ .code = &.{ 0x03, 0x02 }, .format = 0, .stage = .vertex });
    _ = vs; // null accepts any format (formats only gate real drivers)
    const sampler = try d.createSampler(.{});
    const target = try d.createTexture(.{
        .format = .b8g8r8a8_unorm,
        .usage = device.TextureUsage.color_target,
        .width = 800,
        .height = 600,
    });
    const pipe = try d.createGraphicsPipeline(.{
        .vertex_shader = try d.createShader(.{ .code = &.{1}, .stage = .vertex, .format = 0 }),
        .fragment_shader = try d.createShader(.{ .code = &.{1}, .stage = .fragment, .format = 0 }),
        .target_info = .{ .color_targets = &.{.{ .format = .b8g8r8a8_unorm }} },
    });
    const vbo = try d.createBuffer(.{ .usage = device.BufferUsage.vertex, .size = 1024 });

    var cmd = d.acquireCommandBuffer();
    d.pushVertexUniformData(&cmd, 0, &.{ 1, 2, 3, 4 });
    var pass = d.beginRenderPass(&cmd, .{ .color_targets = &.{.{ .texture = target }} });
    pass.bindPipeline(pipe);
    pass.setViewport(.{ .w = 800, .h = 600 });
    pass.setScissor(.{ .w = 800, .h = 600 });
    pass.bindVertexBuffers(0, &.{.{ .buffer = vbo }});
    pass.bindFragmentSamplers(0, &.{.{ .sampler = sampler, .texture = target }});
    pass.drawPrimitives(.{ .num_vertices = 3 });
    pass.drawIndexedPrimitives(.{ .num_indices = 3 });
    pass.end();
    // draw-after-end is a safe no-op, not a crash.
    pass.drawPrimitives(.{ .num_vertices = 3 });
    try std.testing.expect(d.submitCommandBuffer(&cmd));

    var cmd2 = d.acquireCommandBuffer();
    const fence = try d.submitAndAcquireFence(&cmd2);
    try std.testing.expect(d.queryFence(fence));
    try std.testing.expect(d.waitForFences(&.{fence}, true));
    d.releaseFence(fence);
    try std.testing.expect(!d.queryFence(fence));
    d.waitForIdle();
}
