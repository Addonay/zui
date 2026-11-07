//! Native D3D12 backend, the counterpart of the D3D12 design in DESIGN.md.
//! Resource creation, shaders, pipelines and views live here; passes, bindings
//! and transfers are in commands.zig.
const std = @import("std");
const t = @import("../../types.zig");
const e = @import("../../enums.zig");
const core = @import("../../core.zig");
const config = @import("../../config.zig");
const formats = @import("../../formats.zig");
const k = @import("constants.zig");
const sdk = @import("sdk.zig");
const memory = @import("memory.zig");
const res = @import("resources.zig");
const cmds = @import("commands.zig");
const convert = @import("../dxgi/convert.zig");
const dx = @import("../dxgi/constants.zig");
const Compiler = @import("../dxgi/compiler.zig").Compiler;
const Library = @import("../../platform/windows_library.zig").Library;

const num_inflight = @import("../../constants.zig").num_inflight_frames;
/// Shader-visible descriptors per frame for SRVs and UAVs, and samplers.
const srv_per_frame = 8192;
const sampler_per_frame = 1024;
const staging_per_frame = 16 * 1024 * 1024;

const Frame = struct {
    allocator: ?*sdk.Object = null,
    list: ?*sdk.Object = null,
    /// The fence value signaled by the last submission of this frame.
    fence_value: u64 = 0,
};

pub const Backend = struct {
    allocator: std.mem.Allocator,
    logger: t.Logger,
    device: *sdk.Object,
    queue: *sdk.Object,
    library: Library,
    serialize: sdk.RootSignatureSerializeFn,
    serialize_versioned: ?sdk.VersionedRootSignatureSerializeFn = null,
    root_signature_1_1: bool = false,
    fence: ?*sdk.Object = null,
    fence_event: sdk.Handle = null,
    fence_value: u64 = 0,
    frames: [num_inflight]Frame = @splat(.{}),
    frame_slot: usize = num_inflight - 1,
    frame_open: bool = false,
    one_shot_allocator: ?*sdk.Object = null,
    one_shot_list: ?*sdk.Object = null,
    deferred: std.ArrayList(memory.Deferred) = .empty,
    /// Enough spare retirements to destroy every live pool slot (at most two
    /// descriptors/objects each). Replenished before resource creation/uploads.
    retirement_budget: usize = 0,
    /// CPU-only descriptor heaps, indexed by `memory.Kind`.
    heaps: [4]memory.Heap = @splat(.{}),
    /// Shader-visible descriptor heaps, sliced per frame.
    srv_ring: memory.DescriptorRing = .{},
    sampler_ring: memory.DescriptorRing = .{},
    /// Upload memory for uniform blocks and transient or staged copies.
    uniforms: memory.Upload = .{},
    staging: memory.Upload = .{},
    /// Null descriptors copied into unbound descriptor table slots.
    null_srv: usize = 0,
    null_uav: usize = 0,
    null_sampler: usize = 0,
    /// Swapchain descriptors live in reserved slots after the pool, one per frame slot.
    swapchain_slots: u32 = 0,
    /// The swapchain targets of the current pass, see commands.beginPass.
    swapchain: struct {
        render: ?*sdk.Object = null,
        resolve: ?*sdk.Object = null,
        depth: ?*sdk.Object = null,
    } = .{},
    compiler: Compiler = .{},

    /// Creates the backend and fills in features, limits and pixel format caps (DESIGN.md "Environment and frames").
    pub fn init(s: *core.State) !Backend {
        const env = s.desc.environment.d3d12;
        const device = sdk.fromOpaque(env.device orelse return error.MissingD3d12Device);
        const queue = sdk.fromOpaque(env.queue orelse return error.MissingD3d12Device);
        var library = Library.open("d3d12.dll") catch return error.D3d12InitFailed;
        const serialize = library.lookup(sdk.RootSignatureSerializeFn, "D3D12SerializeRootSignature") orelse {
            library.close();
            return error.D3d12InitFailed;
        };
        _ = sdk.addRef(device);
        _ = sdk.addRef(queue);
        var self: Backend = .{ .allocator = s.allocator, .logger = s.desc.logger, .device = device, .queue = queue, .library = library, .serialize = serialize };
        errdefer self.deinit();
        self.serialize_versioned = library.lookup(sdk.VersionedRootSignatureSerializeFn, "D3D12SerializeVersionedRootSignature");
        var highest_root_version: u32 = k.root_signature_version_1_1;
        self.root_signature_1_1 = self.serialize_versioned != null and sdk.checkFeatureSupport(device, k.feature_root_signature, &highest_root_version, @sizeOf(u32)) >= 0 and highest_root_version >= k.root_signature_version_1_1;

        inline for (.{ "buffer_pool_size", "image_pool_size", "sampler_pool_size", "shader_pool_size", "pipeline_pool_size", "view_pool_size" }) |field| {
            const count: usize = @intCast(@max(0, @field(s.desc, field)));
            self.retirement_budget = std.math.add(usize, self.retirement_budget, std.math.mul(usize, count, 2) catch return error.OutOfMemory) catch return error.OutOfMemory;
        }
        if (!self.reserveRelease()) return error.OutOfMemory;
        try self.createCommandObjects();
        try self.createHeaps(&s.desc);
        self.initCaps(s);
        return self;
    }

    /// Waits for submitted work and destroys all backend objects (_sg_d3d12_discard_backend).
    pub fn deinit(self: *Backend) void {
        self.collectDeferred(true);
        self.deferred.deinit(self.allocator);
        for (&self.frames) |*frame| {
            sdk.release(frame.list);
            sdk.release(frame.allocator);
        }
        sdk.release(self.one_shot_list);
        sdk.release(self.one_shot_allocator);
        if (self.fence_event) |event| sdk.closeEvent(event);
        sdk.release(self.fence);
        self.fence = null;
        for (&self.heaps) |*heap| heap.deinit(self.allocator);
        self.srv_ring.heap.deinit(self.allocator);
        self.sampler_ring.heap.deinit(self.allocator);
        self.uniforms.deinit();
        self.staging.deinit();
        self.compiler.deinit();
        sdk.release(self.queue);
        sdk.release(self.device);
        self.library.close();
        self.* = undefined;
    }

    pub fn resetStateCache(self: *Backend) void {
        _ = self;
    }

    fn createCommandObjects(self: *Backend) !void {
        if (sdk.createFence(self.device, 0, &self.fence) < 0 or self.fence == null) return error.D3d12InitFailed;
        self.fence_event = sdk.createEvent();
        if (self.fence_event == null) return error.D3d12InitFailed;
        for (&self.frames) |*frame| try self.createList(&frame.allocator, &frame.list);
        try self.createList(&self.one_shot_allocator, &self.one_shot_list);
    }

    fn createList(self: *Backend, allocator: *?*sdk.Object, list: *?*sdk.Object) !void {
        if (sdk.createCommandAllocator(self.device, k.command_list_type_direct, allocator) < 0 or allocator.* == null) {
            core.logError(.d3d12_create_command_objects_failed);
            return error.D3d12InitFailed;
        }
        if (sdk.createCommandList(self.device, k.command_list_type_direct, allocator.*.?, list) < 0 or list.* == null) {
            core.logError(.d3d12_create_command_objects_failed);
            return error.D3d12InitFailed;
        }
        // command lists are created recording; close them so that the first reset succeeds
        _ = sdk.listClose(list.*.?);
    }

    fn createHeaps(self: *Backend, desc: *const t.Desc) !void {
        const views: u32 = @intCast(desc.view_pool_size);
        const samplers: u32 = @intCast(desc.sampler_pool_size);
        const slots: u32 = @intCast(num_inflight);
        self.swapchain_slots = views;
        self.heaps[@backingInt(memory.Kind.view)] = try memory.Heap.init(self.allocator, self.device, k.heap_type_cbv_srv_uav, 2 * views + 2, false);
        self.heaps[@backingInt(memory.Kind.sampler)] = try memory.Heap.init(self.allocator, self.device, k.heap_type_sampler, samplers + 1, false);
        self.heaps[@backingInt(memory.Kind.rtv)] = try memory.Heap.init(self.allocator, self.device, k.heap_type_rtv, views + slots, false);
        self.heaps[@backingInt(memory.Kind.dsv)] = try memory.Heap.init(self.allocator, self.device, k.heap_type_dsv, views + slots, false);
        // the reserved swapchain slots are not handed out by allocate()
        self.heaps[@backingInt(memory.Kind.rtv)].capacity = views;
        self.heaps[@backingInt(memory.Kind.dsv)].capacity = views;

        self.srv_ring = .{ .heap = try memory.Heap.init(self.allocator, self.device, k.heap_type_cbv_srv_uav, slots * srv_per_frame, true), .per_frame = srv_per_frame };
        self.sampler_ring = .{ .heap = try memory.Heap.init(self.allocator, self.device, k.heap_type_sampler, slots * sampler_per_frame, true), .per_frame = sampler_per_frame };

        const cpu_view = &self.heaps[@backingInt(memory.Kind.view)];
        self.null_srv = cpu_view.allocate();
        self.null_uav = cpu_view.allocate();
        self.null_sampler = self.heaps[@backingInt(memory.Kind.sampler)].allocate();
        const null_srv_desc: sdk.ShaderResourceViewDesc = .{ .format = dx.format_r8g8b8a8_unorm, .view_dimension = k.srv_dimension_texture2d, .payload = .{ .texture_2d = .{ .mip_levels = 1 } } };
        sdk.createShaderResourceView(self.device, null, &null_srv_desc, self.null_srv);
        const null_uav_desc: sdk.UnorderedAccessViewDesc = .{ .format = dx.format_r8g8b8a8_unorm, .view_dimension = k.uav_dimension_texture2d };
        sdk.createUnorderedAccessView(self.device, null, &null_uav_desc, self.null_uav);
        const null_sampler_desc: sdk.SamplerDesc = .{ .filter = dx.filter_min_mag_mip_point, .address_u = 1, .address_v = 1, .address_w = 1, .max_anisotropy = 1, .max_lod = 3.402823466e+38 };
        sdk.createSampler(self.device, &null_sampler_desc, self.null_sampler);

        const upload_size = std.mem.alignForward(usize, @intCast(desc.uniform_buffer_size), 256);
        self.uniforms = try memory.Upload.init(self.device, upload_size, num_inflight);
        self.staging = try memory.Upload.init(self.device, staging_per_frame, num_inflight);
    }

    fn initCaps(self: *Backend, s: *core.State) void {
        s.features.origin_top_left = true;
        s.features.image_clamp_to_border = true;
        s.features.mrt_independent_blend_state = true;
        s.features.mrt_independent_write_mask = true;
        s.features.compute = true;
        s.features.msaa_texture_bindings = true;
        s.features.draw_base_vertex = true;
        s.features.draw_base_instance = true;
        s.features.dual_source_blending = true;
        s.features.copy_buffer_to_image_relaxed_buffer_type = true;
        // copies from GPU buffers need 256-byte row pitches, as on WebGPU
        s.features.copy_buffer_to_image_relaxed_bytes_per_row = false;

        s.limits.max_image_size_2d = 16384;
        s.limits.max_image_size_cube = 16384;
        s.limits.max_image_size_3d = 2048;
        s.limits.max_image_size_array = 16384;
        s.limits.max_image_array_layers = 2048;
        s.limits.max_vertex_attrs = 16;
        s.limits.max_color_attachments = 8;
        s.limits.max_texture_bindings_per_stage = 32;
        s.limits.max_storage_buffer_bindings_per_stage = 8;
        s.limits.max_storage_image_bindings_per_stage = 8;
        if (s.desc.enforce_portable_limits) {
            s.limits.max_color_attachments = 4;
            s.limits.max_texture_bindings_per_stage = 16;
            s.limits.max_storage_buffer_bindings_per_stage = 8;
            s.limits.max_storage_image_bindings_per_stage = 4;
        }
        for (1..core.num_pixel_formats) |fmt_index| {
            const pixel: e.PixelFormat = @fromBackingInt(@intCast(fmt_index));
            const srv = self.formatSupport(convert.srvFormat(pixel));
            const rtv = self.formatSupport(convert.rtvUavFormat(pixel));
            const dsv = self.formatSupport(convert.dsvFormat(pixel));
            const depth = dsv.support1 & dx.format_support_depth_stencil != 0;
            const render_caps = if (depth) dsv.support1 else rtv.support1;
            s.formats[fmt_index] = .{
                .sample = srv.support1 & dx.format_support_texture2d != 0,
                .filter = srv.support1 & dx.format_support_shader_sample != 0,
                .render = depth or rtv.support1 & dx.format_support_render_target != 0,
                .blend = render_caps & dx.format_support_blendable != 0,
                .msaa = render_caps & dx.format_support_multisample_rendertarget != 0,
                .depth = depth,
                .read = rtv.support2 & k.format_support2_uav_typed_load != 0,
                .write = rtv.support2 & k.format_support2_uav_typed_store != 0,
            };
        }
    }

    fn formatSupport(self: *Backend, format: u32) sdk.FormatSupport {
        var info: sdk.FormatSupport = .{ .format = format };
        if (format == dx.format_unknown) return .{};
        if (sdk.checkFeatureSupport(self.device, k.feature_format_support, &info, @sizeOf(sdk.FormatSupport)) < 0) return .{};
        return info;
    }

    // ------------------------------------------------------------ frames

    /// Waits for the frame slot that is recorded next and resets its command objects (DESIGN.md "Environment and frames").
    /// Returns false if the command list could not be reset.
    pub fn acquireFrame(self: *Backend) bool {
        if (self.frame_open) return true;
        self.frame_slot = (self.frame_slot + 1) % num_inflight;
        const frame = &self.frames[self.frame_slot];
        memory.waitFence(self.fence.?, self.fence_event, frame.fence_value);
        self.collectDeferred(false);
        if (sdk.allocatorReset(frame.allocator.?) < 0 or sdk.listReset(frame.list.?, frame.allocator.?) < 0) {
            core.logError(.d3d12_command_list_failed);
            return false;
        }
        self.uniforms.begin(self.frame_slot);
        self.staging.begin(self.frame_slot);
        self.srv_ring.begin(self.frame_slot);
        self.sampler_ring.begin(self.frame_slot);
        var heaps = [_]?*sdk.Object{ self.srv_ring.heap.object, self.sampler_ring.heap.object };
        sdk.setDescriptorHeaps(frame.list.?, 2, &heaps);
        self.frame_open = true;
        return true;
    }

    /// The open command list of the current frame, acquired by the first recorded command.
    pub fn frameList(self: *Backend) ?*sdk.Object {
        if (!self.acquireFrame()) return null;
        return self.frames[self.frame_slot].list;
    }

    /// Closes and submits the current frame, then signals its fence value.
    pub fn submitFrame(self: *Backend) void {
        if (!self.frame_open) return;
        const frame = &self.frames[self.frame_slot];
        if (sdk.listClose(frame.list.?) < 0) core.logError(.d3d12_command_list_failed);
        var lists = [_]?*sdk.Object{frame.list};
        core.statsInc("d3d12.num_queue_submits");
        sdk.queueExecuteCommandLists(self.queue, 1, &lists);
        self.fence_value += 1;
        self.signalProgress();
        frame.fence_value = self.fence_value;
        self.frame_open = false;
    }

    fn signalProgress(self: *Backend) void {
        const result = sdk.queueSignal(self.queue, self.fence.?, self.fence_value);
        if (result < 0) {
            const reason = sdk.getDeviceRemovedReason(self.device);
            if (reason >= 0) @panic("D3D12 completion signaling failed without device removal");
            core.recordLoss(reason);
        }
    }

    pub fn commit(self: *Backend) void {
        if (self.frame_open) self.submitFrame() else if (self.deferred.items.len > 0) {
            // Resource-only frames must also advance retirement. This signal is
            // ordered after private readback submissions without a CPU wait.
            self.fence_value += 1;
            self.signalProgress();
        }
        self.collectDeferred(false);
    }

    /// Starts recording on the one-shot command list, used for initial data, unsealed writes and readback.
    /// `endOneShot` executes it and waits for the GPU to finish it.
    pub fn beginOneShot(self: *Backend) ?*sdk.Object {
        // A separate list must never execute ahead of recorded frame commands.
        std.debug.assert(!self.frame_open);
        if (sdk.allocatorReset(self.one_shot_allocator.?) < 0 or sdk.listReset(self.one_shot_list.?, self.one_shot_allocator.?) < 0) {
            core.logError(.d3d12_command_list_failed);
            return null;
        }
        return self.one_shot_list;
    }

    pub fn endOneShot(self: *Backend) void {
        core.statsInc("d3d12.num_one_shot_submits");
        if (sdk.listClose(self.one_shot_list.?) < 0) core.logError(.d3d12_command_list_failed);
        var lists = [_]?*sdk.Object{self.one_shot_list};
        core.statsInc("d3d12.num_queue_submits");
        sdk.queueExecuteCommandLists(self.queue, 1, &lists);
        self.fence_value += 1;
        self.signalProgress();
        memory.waitFence(self.fence.?, self.fence_event, self.fence_value);
    }

    /// Reserve before creation, never at destruction: failure leaves existing
    /// resources/recorded commands untouched. Until the next creation, at most
    /// retirement_budget live-pool entries and one temporary upload can retire.
    pub fn reserveRelease(self: *Backend) bool {
        self.deferred.ensureUnusedCapacity(self.allocator, self.retirement_budget + 1) catch {
            core.logError(.malloc_failed);
            return false;
        };
        return true;
    }

    /// Defers the release of a COM object until the GPU can no longer use it.
    pub fn releaseLater(self: *Backend, object: ?*sdk.Object) void {
        const value = object orelse return;
        self.deferred.appendAssumeCapacity(.{ .fence_value = self.fence_value + 1, .item = .{ .object = value } });
    }

    /// Defers the free of a CPU descriptor until the GPU can no longer use it.
    fn freeDescriptorLater(self: *Backend, kind: memory.Kind, handle: usize) void {
        if (handle == 0) return;
        self.deferred.appendAssumeCapacity(.{ .fence_value = self.fence_value + 1, .item = .{ .descriptor = .{ .kind = kind, .handle = handle } } });
    }

    /// Releases the deferred items whose fence value completed; with `all`, waits and releases everything.
    fn collectDeferred(self: *Backend, all: bool) void {
        const fence = self.fence orelse {
            // no fence means no submission ever happened, so nothing can still be in use
            for (self.deferred.items) |item| releaseItem(self, item);
            self.deferred.clearRetainingCapacity();
            return;
        };
        if (all) {
            self.submitFrame();
            memory.waitFence(fence, self.fence_event, self.fence_value);
        }
        const completed = sdk.fenceCompletedValue(fence);
        var i: usize = 0;
        while (i < self.deferred.items.len) {
            const item = self.deferred.items[i];
            if (!all and item.fence_value > completed) {
                i += 1;
                continue;
            }
            releaseItem(self, item);
            _ = self.deferred.swapRemove(i);
        }
    }

    fn releaseItem(self: *Backend, item: memory.Deferred) void {
        switch (item.item) {
            .object => |object| sdk.release(object),
            .descriptor => |d| self.heaps[@backingInt(d.kind)].free(self.allocator, d.handle),
        }
    }

    // ------------------------------------------------------------ resources

    pub fn createBuffer(self: *Backend, buf: *core.Buffer, desc: *const t.BufferDesc) e.ResourceState {
        if (!self.reserveRelease()) return .failed;
        buf.native = .{ .d3d12 = .{} };
        const payload = &buf.native.d3d12;
        std.debug.assert(buf.cmn.size > 0);
        if (desc.usage.staging_buffer or desc.usage.staging_index_buffer) {
            const data = self.allocator.alloc(u8, buf.cmn.size) catch return .failed;
            if (desc.data.ptr != null) @memcpy(data, @as([*]const u8, @ptrCast(desc.data.ptr.?))[0..buf.cmn.size]);
            payload.staging = data;
            return .valid;
        }
        const flags: u32 = if (buf.cmn.usage.storage_buffer) k.resource_flag_allow_unordered_access else 0;
        const heap: sdk.HeapProperties = .{ .type = k.heap_default };
        const resource_desc = memory.bufferDesc(buf.cmn.size, flags);
        if (sdk.createCommittedResource(self.device, &heap, k.heap_flag_none, &resource_desc, k.state_common, &payload.resource) < 0 or payload.resource == null) {
            core.logError(.d3d12_create_buffer_failed);
            return .failed;
        }
        payload.gpu_address = sdk.resourceGpuAddress(payload.resource.?);
        self.setName(payload.resource, desc.label);
        if (desc.data.ptr != null) {
            if (!cmds.uploadBufferOneShot(self, buf, 0, &desc.data)) return .failed;
        }
        return .valid;
    }

    pub fn discardBuffer(self: *Backend, buf: *core.Buffer) void {
        if (buf.native != .d3d12) return;
        const payload = &buf.native.d3d12;
        if (payload.staging) |data| self.allocator.free(data);
        self.releaseLater(payload.resource);
        payload.* = .{};
    }

    pub fn createImage(self: *Backend, img: *core.Image, desc: *const t.ImageDesc) e.ResourceState {
        if (!self.reserveRelease()) return .failed;
        img.native = .{ .d3d12 = .{} };
        const payload = &img.native.d3d12;
        payload.format = convert.textureFormat(desc.pixel_format);
        if (payload.format == dx.format_unknown) {
            core.logError(.d3d12_create_texture_unsupported_pixel_format);
            return .failed;
        }
        var flags: u32 = 0;
        if (desc.usage.color_attachment or desc.usage.resolve_attachment) flags |= k.resource_flag_allow_render_target;
        if (desc.usage.depth_stencil_attachment) flags |= k.resource_flag_allow_depth_stencil;
        if (desc.usage.storage_image) flags |= k.resource_flag_allow_unordered_access;
        const is_3d = desc.type == .@"3d";
        const resource_desc: sdk.ResourceDesc = .{
            .dimension = if (is_3d) k.dimension_texture3d else k.dimension_texture2d,
            .width = @intCast(desc.width),
            .height = @intCast(desc.height),
            .depth_or_array_size = @intCast(desc.num_slices),
            .mip_levels = @intCast(desc.num_mipmaps),
            .format = payload.format,
            .sample_desc = .{ .count = @intCast(@max(desc.sample_count, 1)), .quality = 0 },
            .layout = k.texture_layout_unknown,
            .flags = flags,
        };
        const heap: sdk.HeapProperties = .{ .type = k.heap_default };
        if (sdk.createCommittedResource(self.device, &heap, k.heap_flag_none, &resource_desc, k.state_common, &payload.resource) < 0 or payload.resource == null) {
            core.logError(.d3d12_create_texture_failed);
            return .failed;
        }
        self.setName(payload.resource, desc.label);
        if (desc.data.mip_levels[0].ptr != null) {
            if (!cmds.uploadImageOneShot(self, img, desc)) return .failed;
        }
        return .valid;
    }

    pub fn discardImage(self: *Backend, img: *core.Image) void {
        if (img.native != .d3d12) return;
        self.releaseLater(img.native.d3d12.resource);
        img.native = .{ .d3d12 = .{} };
    }

    pub fn createSampler(self: *Backend, smp: *core.Sampler, desc: *const t.SamplerDesc) e.ResourceState {
        if (!self.reserveRelease()) return .failed;
        smp.native = .{ .d3d12 = .{} };
        const payload = &smp.native.d3d12;
        const native: sdk.SamplerDesc = .{
            .filter = convert.filter(desc.min_filter, desc.mag_filter, desc.mipmap_filter, desc.compare != .never, desc.max_anisotropy),
            .address_u = convert.addressMode(desc.wrap_u),
            .address_v = convert.addressMode(desc.wrap_v),
            .address_w = convert.addressMode(desc.wrap_w),
            .max_anisotropy = desc.max_anisotropy,
            .comparison_func = convert.compareFunc(desc.compare),
            .min_lod = desc.min_lod,
            .max_lod = desc.max_lod,
            .border_color = switch (desc.border_color) {
                .transparent_black => .{ 0, 0, 0, 0 },
                .opaque_white => .{ 1, 1, 1, 1 },
                else => .{ 0, 0, 0, 1 },
            },
        };
        payload.handle = self.heaps[@backingInt(memory.Kind.sampler)].allocate();
        if (payload.handle == 0) {
            core.logError(.d3d12_descriptor_heap_full);
            return .failed;
        }
        sdk.createSampler(self.device, &native, payload.handle);
        return .valid;
    }

    pub fn discardSampler(self: *Backend, smp: *core.Sampler) void {
        if (smp.native != .d3d12) return;
        self.freeDescriptorLater(.sampler, smp.native.d3d12.handle);
        smp.native = .{ .d3d12 = .{} };
    }

    fn stageIndex(stage: e.ShaderStage) usize {
        return switch (stage) {
            .vertex => 0,
            .fragment => 1,
            .compute => 2,
            else => unreachable,
        };
    }

    fn visibility(stage: usize) u32 {
        return switch (stage) {
            0 => k.shader_visibility_vertex,
            1 => k.shader_visibility_pixel,
            else => k.shader_visibility_all,
        };
    }

    /// The bytecode of one shader function: copied from the caller, or compiled from HLSL source.
    /// Returns null without an error if the function is absent, and fails with an error on compile failure.
    fn copyBytecode(self: *Backend, function: t.ShaderFunction, default_target: [*:0]const u8) error{ CompileFailed, OutOfMemory }!?[]u8 {
        if (function.bytecode.ptr != null) {
            const bytes: [*]const u8 = @ptrCast(function.bytecode.ptr.?);
            return try self.allocator.dupe(u8, bytes[0..function.bytecode.size]);
        }
        if (function.source == null) return null;
        var source = function;
        if (source.d3d11_target == null) source.d3d11_target = default_target;
        const blob = self.compiler.compile(source, false, self.logger) orelse return error.CompileFailed;
        defer sdk.release(blob);
        const bytes: [*]const u8 = @ptrCast(sdk.getBufferPointer(blob) orelse return error.CompileFailed);
        return try self.allocator.dupe(u8, bytes[0..sdk.getBufferSize(blob)]);
    }

    pub fn createShader(self: *Backend, shd: *core.Shader, desc: *const t.ShaderDesc) e.ResourceState {
        if (!self.reserveRelease()) return .failed;
        shd.native = .{ .d3d12 = .{} };
        const payload = &shd.native.d3d12;
        for (&payload.semantic_names, &payload.semantic_indices, desc.attrs) |*name, *index, attr| {
            if (attr.hlsl_sem_name) |value| {
                const count = @min(31, std.mem.len(value));
                @memcpy(name[0..count], value[0..count]);
            }
            index.* = attr.hlsl_sem_index;
        }
        const targets = .{ .{ &payload.vertex, desc.vertex_func, "vs_5_0" }, .{ &payload.fragment, desc.fragment_func, "ps_5_0" }, .{ &payload.compute, desc.compute_func, "cs_5_0" } };
        inline for (targets) |target| {
            const code = self.copyBytecode(target[1], target[2]) catch return self.shaderFailed(payload);
            if (code) |bytes| target[0].* = bytes;
        }
        if (shd.cmn.is_compute) {
            if (payload.compute.len == 0) return self.shaderFailed(payload);
        } else if (payload.vertex.len == 0 or payload.fragment.len == 0) return self.shaderFailed(payload);
        if (!self.createRootSignature(shd, desc, payload)) return self.shaderFailed(payload);
        return .valid;
    }

    fn shaderFailed(self: *Backend, payload: *res.Shader) e.ResourceState {
        self.discardShaderPayload(payload);
        return .failed;
    }

    fn discardShaderPayload(self: *Backend, payload: *res.Shader) void {
        self.releaseLater(payload.root_signature);
        if (payload.vertex.len > 0) self.allocator.free(payload.vertex);
        if (payload.fragment.len > 0) self.allocator.free(payload.fragment);
        if (payload.compute.len > 0) self.allocator.free(payload.compute);
        payload.* = .{};
    }

    /// Builds the root signature from the shader's bindings: one root CBV per uniform
    /// block, and one descriptor table per stage and kind covering registers 0..max.
    fn createRootSignature(self: *Backend, shd: *const core.Shader, desc: *const t.ShaderDesc, payload: *res.Shader) bool {
        var params: [8 + res.stage_count * 3]sdk.RootParameter = undefined;
        var ranges: [res.stage_count * 3]sdk.RootDescriptorRange = undefined;
        var num_params: usize = 0;
        var num_ranges: usize = 0;
        for (shd.cmn.uniform_blocks, desc.uniform_blocks, 0..) |block, required, i| {
            if (block.stage == .none) continue;
            payload.ub_param[i] = @intCast(num_params);
            params[num_params] = .{ .parameter_type = k.root_parameter_cbv, .payload = .{ .descriptor = .{ .shader_register = required.hlsl_register_b_n } }, .shader_visibility = visibility(stageIndex(block.stage)) };
            num_params += 1;
        }
        var counts = std.mem.zeroes([res.stage_count][3]u32);
        for (shd.cmn.views, desc.views, 0..) |view, required, i| {
            if (view.stage == .none) continue;
            const stage = stageIndex(view.stage);
            var binding: res.Binding = .{ .active = true, .stage = @intCast(stage), .kind = .srv };
            if (view.view_type == .texture) {
                binding.register = required.texture.hlsl_register_t_n;
            } else if (view.view_type == .storagebuffer and view.sbuf_readonly) {
                binding.register = required.storage_buffer.hlsl_register_t_n;
            } else if (view.view_type == .storagebuffer) {
                binding.kind = .uav;
                binding.register = required.storage_buffer.hlsl_register_u_n;
            } else {
                binding.kind = .uav;
                binding.register = required.storage_image.hlsl_register_u_n;
            }
            payload.views[i] = binding;
            const kind = @backingInt(binding.kind);
            counts[stage][kind] = @max(counts[stage][kind], @as(u32, binding.register) + 1);
        }
        for (shd.cmn.samplers, desc.samplers, 0..) |sampler, required, i| {
            if (sampler.stage == .none) continue;
            const stage = stageIndex(sampler.stage);
            payload.samplers[i] = .{ .active = true, .stage = @intCast(stage), .kind = .sampler, .register = required.hlsl_register_s_n };
            const kind = @backingInt(res.TableKind.sampler);
            counts[stage][kind] = @max(counts[stage][kind], @as(u32, required.hlsl_register_s_n) + 1);
        }
        const range_types = [_]u32{ k.range_type_srv, k.range_type_uav, k.range_type_sampler };
        for (0..res.stage_count) |stage| for (0..3) |kind| {
            const count = counts[stage][kind];
            if (count == 0) continue;
            ranges[num_ranges] = .{ .range_type = range_types[kind], .num_descriptors = count, .base_shader_register = 0, .register_space = 0, .offset_in_descriptors_from_table_start = k.descriptor_range_offset_append };
            params[num_params] = .{ .parameter_type = k.root_parameter_descriptor_table, .payload = .{ .table = .{ .num_ranges = 1, .ranges = ranges[num_ranges..].ptr } }, .shader_visibility = visibility(stage) };
            payload.tables[stage][kind] = .{ .param = @intCast(num_params), .count = count };
            num_params += 1;
            num_ranges += 1;
        };
        const flags: u32 = if (shd.cmn.is_compute) 0 else k.root_signature_flag_allow_input_assembler_input_layout;
        const root_desc: sdk.RootSignatureDesc = .{ .num_parameters = @intCast(num_params), .parameters = params[0..num_params].ptr, .flags = flags };
        var blob: ?*sdk.Object = null;
        var error_blob: ?*sdk.Object = null;
        const status = if (self.root_signature_1_1) blk: {
            var params1: [8 + res.stage_count * 3]sdk.RootParameter1 = undefined;
            var ranges1: [res.stage_count * 3]sdk.RootDescriptorRange1 = undefined;
            var range_index: usize = 0;
            for (params[0..num_params], 0..) |parameter, index| {
                params1[index] = .{ .parameter_type = parameter.parameter_type, .shader_visibility = parameter.shader_visibility };
                if (parameter.parameter_type == k.root_parameter_descriptor_table) {
                    const range = parameter.payload.table.ranges.?[0];
                    ranges1[range_index] = .{
                        .range_type = range.range_type,
                        .num_descriptors = range.num_descriptors,
                        .base_shader_register = range.base_shader_register,
                        .register_space = range.register_space,
                        // Table contents are immutable until its frame fence.
                        // Keep buffer bounds checks when the driver optimizes static
                        // descriptors; data may change through ordered uploads/UAVs.
                        .flags = if (range.range_type == k.range_type_sampler) 0 else k.descriptor_range_data_volatile | k.descriptor_range_static_keeping_buffer_bounds_checks,
                        .offset_in_descriptors_from_table_start = range.offset_in_descriptors_from_table_start,
                    };
                    params1[index].payload = .{ .table = .{ .num_ranges = 1, .ranges = ranges1[range_index..].ptr } };
                    range_index += 1;
                } else {
                    const descriptor = parameter.payload.descriptor;
                    // Uniform ring bytes are immutable while this binding is used.
                    params1[index].payload = .{ .descriptor = .{ .shader_register = descriptor.shader_register, .register_space = descriptor.register_space, .flags = k.root_descriptor_data_static_while_set_at_execute } };
                }
            }
            const versioned: sdk.VersionedRootSignatureDesc = .{ .payload = .{ .v1_1 = .{ .num_parameters = @intCast(num_params), .parameters = params1[0..num_params].ptr, .flags = flags } } };
            break :blk self.serialize_versioned.?(&versioned, &blob, &error_blob);
        } else self.serialize(&root_desc, k.root_signature_version_1_0, &blob, &error_blob);
        sdk.release(error_blob);
        if (status < 0 or blob == null) {
            core.logError(.d3d12_serialize_root_signature_failed);
            sdk.release(blob);
            return false;
        }
        defer sdk.release(blob);
        if (sdk.createRootSignature(self.device, blob.?, &payload.root_signature) < 0 or payload.root_signature == null) {
            core.logError(.d3d12_create_root_signature_failed);
            return false;
        }
        self.setName(payload.root_signature, desc.label);
        return true;
    }

    pub fn discardShader(self: *Backend, shd: *core.Shader) void {
        if (shd.native != .d3d12) return;
        self.discardShaderPayload(&shd.native.d3d12);
    }

    pub fn createPipeline(self: *Backend, pip: *core.Pipeline, desc: *const t.PipelineDesc) e.ResourceState {
        if (!self.reserveRelease()) return .failed;
        _ = desc;
        pip.native = .{ .d3d12 = .{} };
        const payload = &pip.native.d3d12;
        const shd = pip.cmn.shader.get();
        const shader = &shd.native.d3d12;
        if (pip.cmn.is_compute) {
            const pso_desc: sdk.ComputePipelineStateDesc = .{
                .root_signature = shader.root_signature,
                .cs = .{ .ptr = shader.compute.ptr, .size = shader.compute.len },
            };
            if (sdk.createComputePipelineState(self.device, &pso_desc, &payload.pso) < 0 or payload.pso == null) {
                core.logError(.d3d12_create_pipeline_failed);
                return .failed;
            }
            return .valid;
        }
        var elements: [16]sdk.InputElementDesc = @splat(.{});
        var count: usize = 0;
        for (pip.cmn.layout.attrs, 0..) |attr, i| {
            if (attr.format == .invalid) break;
            const layout = pip.cmn.layout.buffers[@intCast(attr.buffer_index)];
            elements[i] = .{
                .semantic_name = @ptrCast(&shader.semantic_names[i]),
                .semantic_index = shader.semantic_indices[i],
                .format = convert.vertexFormat(attr.format),
                .input_slot = @intCast(attr.buffer_index),
                .aligned_byte_offset = @intCast(attr.offset),
                .input_slot_class = convert.inputClass(layout.step_func),
                .instance_data_step_rate = if (layout.step_func == .per_instance) @intCast(layout.step_rate) else 0,
            };
            payload.vertex_strides[@intCast(attr.buffer_index)] = @intCast(layout.stride);
            count += 1;
        }
        const depth_format: u32 = if (pip.cmn.depth.pixel_format == .none or pip.cmn.depth.pixel_format == .default) 0 else convert.dsvFormat(pip.cmn.depth.pixel_format);
        var pso_desc: sdk.GraphicsPipelineStateDesc = .{
            .root_signature = shader.root_signature,
            .vs = .{ .ptr = shader.vertex.ptr, .size = shader.vertex.len },
            .ps = .{ .ptr = shader.fragment.ptr, .size = shader.fragment.len },
            .input_layout = .{ .elements = if (count > 0) @as([*]const sdk.InputElementDesc, &elements) else null, .num_elements = @intCast(count) },
            .primitive_topology_type = topologyType(pip.cmn.primitive_type),
            .num_render_targets = @intCast(pip.cmn.color_count),
            .dsv_format = depth_format,
            .sample_desc = .{ .count = @intCast(@max(pip.cmn.sample_count, 1)), .quality = 0 },
        };
        pso_desc.rasterizer = .{
            .fill_mode = dx.fill_solid,
            .cull_mode = convert.cullMode(pip.cmn.cull_mode),
            .front_counter_clockwise = @intFromBool(pip.cmn.face_winding == .ccw),
            .depth_bias = @intFromFloat(pip.cmn.depth.bias),
            .depth_bias_clamp = pip.cmn.depth.bias_clamp,
            .slope_scaled_depth_bias = pip.cmn.depth.bias_slope_scale,
            .depth_clip_enable = 1,
            .multisample_enable = @intFromBool(pip.cmn.sample_count > 1),
        };
        pso_desc.depth_stencil = .{
            .depth_enable = @intFromBool(depth_format != 0),
            .depth_write_mask = if (pip.cmn.depth.write_enabled) dx.depth_write_mask_all else dx.depth_write_mask_zero,
            .depth_func = convert.compareFunc(pip.cmn.depth.compare),
            .stencil_enable = @intFromBool(pip.cmn.stencil.enabled),
            .stencil_read_mask = pip.cmn.stencil.read_mask,
            .stencil_write_mask = pip.cmn.stencil.write_mask,
            .front_face = stencilFace(pip.cmn.stencil.front),
            .back_face = stencilFace(pip.cmn.stencil.back),
        };
        pso_desc.blend.alpha_to_coverage_enable = @intFromBool(pip.cmn.alpha_to_coverage_enabled);
        pso_desc.blend.independent_blend_enable = 1;
        for (&pso_desc.blend.render_target, 0..) |*target, i| {
            if (i < @as(usize, @intCast(pip.cmn.color_count))) {
                const color = pip.cmn.colors[i];
                pso_desc.rtv_formats[i] = convert.rtvUavFormat(color.pixel_format);
                target.* = .{
                    .blend_enable = @intFromBool(color.blend.enabled),
                    .src_blend = convert.blendFactor(color.blend.src_factor_rgb),
                    .dest_blend = convert.blendFactor(color.blend.dst_factor_rgb),
                    .blend_op = convert.blendOp(color.blend.op_rgb),
                    .src_blend_alpha = convert.blendFactor(color.blend.src_factor_alpha),
                    .dest_blend_alpha = convert.blendFactor(color.blend.dst_factor_alpha),
                    .blend_op_alpha = convert.blendOp(color.blend.op_alpha),
                    .render_target_write_mask = convert.colorMask(color.write_mask),
                };
            } else target.* = .{ .src_blend = dx.blend_one, .dest_blend = dx.blend_zero, .blend_op = dx.blend_op_add, .src_blend_alpha = dx.blend_one, .dest_blend_alpha = dx.blend_zero, .blend_op_alpha = dx.blend_op_add, .render_target_write_mask = @intCast(dx.color_write_enable_all) };
        }
        if (sdk.createGraphicsPipelineState(self.device, &pso_desc, &payload.pso) < 0 or payload.pso == null) {
            core.logError(.d3d12_create_pipeline_failed);
            return .failed;
        }
        self.setName(payload.pso, pip.desc.label);
        payload.topology = convert.topology(pip.cmn.primitive_type);
        payload.index_format = convert.indexFormat(pip.cmn.index_type);
        payload.stencil_ref = pip.desc.stencil.ref;
        payload.blend_color = .{ pip.cmn.blend_color.r, pip.cmn.blend_color.g, pip.cmn.blend_color.b, pip.cmn.blend_color.a };
        return .valid;
    }

    fn topologyType(value: e.PrimitiveType) u32 {
        return switch (value) {
            .points => k.primitive_topology_type_point,
            .lines, .line_strip => k.primitive_topology_type_line,
            else => k.primitive_topology_type_triangle,
        };
    }

    fn stencilFace(value: t.StencilFaceState) sdk.StencilOpDesc {
        return .{ .stencil_fail_op = convert.stencilOp(value.fail_op), .stencil_depth_fail_op = convert.stencilOp(value.depth_fail_op), .stencil_pass_op = convert.stencilOp(value.pass_op), .stencil_func = convert.compareFunc(value.compare) };
    }

    pub fn discardPipeline(self: *Backend, pip: *core.Pipeline) void {
        if (pip.native != .d3d12) return;
        self.releaseLater(pip.native.d3d12.pso);
        pip.native = .{ .d3d12 = .{} };
    }

    /// `view.desc` holds the descriptor with resolved mip and slice counts.
    pub fn createView(self: *Backend, view: *core.View, unresolved: *const t.ViewDesc) e.ResourceState {
        if (!self.reserveRelease()) return .failed;
        _ = unresolved;
        const desc = &view.desc;
        view.native = .{ .d3d12 = .{} };
        const payload = &view.native.d3d12;
        const cpu_view = &self.heaps[@backingInt(memory.Kind.view)];
        const cpu_rtv = &self.heaps[@backingInt(memory.Kind.rtv)];
        const cpu_dsv = &self.heaps[@backingInt(memory.Kind.dsv)];
        switch (view.cmn.type) {
            .storagebuffer => {
                const buf = view.cmn.buf.ref.get();
                const resource = buf.native.d3d12.resource orelse return .failed;
                const first: u64 = @intCast(@divTrunc(view.cmn.buf.offset, 4));
                const count: u32 = @intCast(@divTrunc(buf.cmn.size - @as(usize, @intCast(view.cmn.buf.offset)), 4));
                const srv_desc: sdk.ShaderResourceViewDesc = .{ .format = dx.format_r32_typeless, .view_dimension = k.srv_dimension_buffer, .payload = .{ .buffer = .{ .first_element = first, .num_elements = count, .flags = k.buffer_srv_flag_raw } } };
                payload.srv = cpu_view.allocate();
                if (payload.srv == 0) return self.viewFailed(payload);
                sdk.createShaderResourceView(self.device, resource, &srv_desc, payload.srv);
                const uav_desc: sdk.UnorderedAccessViewDesc = .{ .format = dx.format_r32_typeless, .view_dimension = k.uav_dimension_buffer, .payload = .{ .buffer = .{ .first_element = first, .num_elements = count, .flags = k.buffer_uav_flag_raw } } };
                payload.uav = cpu_view.allocate();
                if (payload.uav == 0) return self.viewFailed(payload);
                sdk.createUnorderedAccessView(self.device, resource, &uav_desc, payload.uav);
            },
            .texture => {
                const img = view.cmn.img.ref.get();
                const resource = img.native.d3d12.resource orelse return .failed;
                const range = desc.texture;
                const msaa = img.desc.sample_count > 1;
                var srv: sdk.ShaderResourceViewDesc = .{ .format = convert.srvFormat(img.desc.pixel_format) };
                const mip: u32 = @intCast(range.mip_levels.base);
                const mips: u32 = @intCast(range.mip_levels.count);
                const first: u32 = @intCast(range.slices.base);
                const slices: u32 = @intCast(range.slices.count);
                switch (img.desc.type) {
                    .@"2d" => if (msaa) {
                        srv.view_dimension = k.srv_dimension_texture2dms;
                    } else {
                        srv.view_dimension = k.srv_dimension_texture2d;
                        srv.payload = .{ .texture_2d = .{ .most_detailed_mip = mip, .mip_levels = mips } };
                    },
                    .cube => {
                        srv.view_dimension = k.srv_dimension_texturecube;
                        srv.payload = .{ .texture_cube = .{ .most_detailed_mip = mip, .mip_levels = mips } };
                    },
                    .array => if (msaa) {
                        srv.view_dimension = k.srv_dimension_texture2dmsarray;
                        srv.payload = .{ .texture_2d_ms_array = .{ .first_array_slice = first, .array_size = slices } };
                    } else {
                        srv.view_dimension = k.srv_dimension_texture2darray;
                        srv.payload = .{ .texture_2d_array = .{ .most_detailed_mip = mip, .mip_levels = mips, .first_array_slice = first, .array_size = slices } };
                    },
                    .@"3d" => {
                        srv.view_dimension = k.srv_dimension_texture3d;
                        srv.payload = .{ .texture_3d = .{ .most_detailed_mip = mip, .mip_levels = mips } };
                    },
                    else => unreachable,
                }
                payload.srv = cpu_view.allocate();
                if (payload.srv == 0) return self.viewFailed(payload);
                sdk.createShaderResourceView(self.device, resource, &srv, payload.srv);
            },
            .storageimage => {
                const img = view.cmn.img.ref.get();
                const resource = img.native.d3d12.resource orelse return .failed;
                const selected = desc.storage_image;
                const uav = uavDesc(img, selected.mip_level, selected.slice);
                payload.uav = cpu_view.allocate();
                if (payload.uav == 0) return self.viewFailed(payload);
                sdk.createUnorderedAccessView(self.device, resource, &uav, payload.uav);
            },
            .colorattachment => {
                const img = view.cmn.img.ref.get();
                const resource = img.native.d3d12.resource orelse return .failed;
                const rtv = rtvDesc(img, desc.color_attachment.mip_level, desc.color_attachment.slice);
                payload.rtv = cpu_rtv.allocate();
                if (payload.rtv == 0) return self.viewFailed(payload);
                sdk.createRenderTargetView(self.device, resource, &rtv, payload.rtv);
            },
            .depthstencilattachment => {
                const img = view.cmn.img.ref.get();
                const resource = img.native.d3d12.resource orelse return .failed;
                const dsv = dsvDesc(img, desc.depth_stencil_attachment.mip_level, desc.depth_stencil_attachment.slice);
                payload.dsv = cpu_dsv.allocate();
                if (payload.dsv == 0) return self.viewFailed(payload);
                sdk.createDepthStencilView(self.device, resource, &dsv, payload.dsv);
            },
            // resolve attachments are used through their image only
            .resolveattachment => {},
            else => unreachable,
        }
        return .valid;
    }

    fn viewFailed(self: *Backend, payload: *res.View) e.ResourceState {
        core.logError(.d3d12_descriptor_heap_full);
        self.discardViewPayload(payload);
        return .failed;
    }

    fn discardViewPayload(self: *Backend, payload: *res.View) void {
        self.freeDescriptorLater(.view, payload.srv);
        self.freeDescriptorLater(.view, payload.uav);
        self.freeDescriptorLater(.rtv, payload.rtv);
        self.freeDescriptorLater(.dsv, payload.dsv);
        payload.* = .{};
    }

    pub fn discardView(self: *Backend, view: *core.View) void {
        if (view.native != .d3d12) return;
        self.discardViewPayload(&view.native.d3d12);
    }

    fn uavDesc(img: *const core.Image, mip: i32, slice: i32) sdk.UnorderedAccessViewDesc {
        var uav: sdk.UnorderedAccessViewDesc = .{ .format = convert.rtvUavFormat(img.desc.pixel_format) };
        switch (img.desc.type) {
            .@"2d" => {
                uav.view_dimension = k.uav_dimension_texture2d;
                uav.payload = .{ .texture_2d = .{ .mip_slice = @intCast(mip) } };
            },
            .cube, .array => {
                uav.view_dimension = k.uav_dimension_texture2darray;
                uav.payload = .{ .texture_2d_array = .{ .mip_slice = @intCast(mip), .first_array_slice = @intCast(slice), .array_size = 1 } };
            },
            .@"3d" => {
                uav.view_dimension = k.uav_dimension_texture3d;
                uav.payload = .{ .texture_3d = .{ .mip_slice = @intCast(mip), .first_w_slice = @intCast(slice), .w_size = 1 } };
            },
            else => unreachable,
        }
        return uav;
    }

    fn rtvDesc(img: *const core.Image, mip: i32, slice: i32) sdk.RenderTargetViewDesc {
        const msaa = img.desc.sample_count > 1;
        var rtv: sdk.RenderTargetViewDesc = .{ .format = convert.rtvUavFormat(img.desc.pixel_format) };
        switch (img.desc.type) {
            .@"2d" => {
                rtv.view_dimension = if (msaa) k.rtv_dimension_texture2dms else k.rtv_dimension_texture2d;
                rtv.payload = .{ .texture_2d = .{ .mip_slice = @intCast(mip) } };
            },
            .cube, .array => if (msaa) {
                rtv.view_dimension = k.rtv_dimension_texture2dmsarray;
                rtv.payload = .{ .texture_2d_ms_array = .{ .first_array_slice = @intCast(slice), .array_size = 1 } };
            } else {
                rtv.view_dimension = k.rtv_dimension_texture2darray;
                rtv.payload = .{ .texture_2d_array = .{ .mip_slice = @intCast(mip), .first_array_slice = @intCast(slice), .array_size = 1 } };
            },
            .@"3d" => {
                rtv.view_dimension = k.rtv_dimension_texture3d;
                rtv.payload = .{ .texture_3d = .{ .mip_slice = @intCast(mip), .first_w_slice = @intCast(slice), .w_size = 1 } };
            },
            else => unreachable,
        }
        return rtv;
    }

    fn dsvDesc(img: *const core.Image, mip: i32, slice: i32) sdk.DepthStencilViewDesc {
        const msaa = img.desc.sample_count > 1;
        var dsv: sdk.DepthStencilViewDesc = .{ .format = convert.dsvFormat(img.desc.pixel_format) };
        switch (img.desc.type) {
            .@"2d" => {
                dsv.view_dimension = if (msaa) k.dsv_dimension_texture2dms else k.dsv_dimension_texture2d;
                dsv.payload = .{ .texture_2d = .{ .mip_slice = @intCast(mip) } };
            },
            .cube, .array => if (msaa) {
                dsv.view_dimension = k.dsv_dimension_texture2dmsarray;
                dsv.payload = .{ .texture_2d_ms_array = .{ .first_array_slice = @intCast(slice), .array_size = 1 } };
            } else {
                dsv.view_dimension = k.dsv_dimension_texture2darray;
                dsv.payload = .{ .texture_2d_array = .{ .mip_slice = @intCast(mip), .first_array_slice = @intCast(slice), .array_size = 1 } };
            },
            else => unreachable,
        }
        return dsv;
    }

    /// Names a D3D12 object for debugging tools, in debug builds only.
    pub fn setName(self: *Backend, object: ?*sdk.Object, label: ?[*:0]const u8) void {
        _ = self;
        if (!config.debug) return;
        const name = label orelse return;
        const object_value = object orelse return;
        var wide: [128:0]u16 = @splat(0);
        const text = std.mem.span(name);
        for (text[0..@min(text.len, wide.len - 1)], 0..) |char, i| wide[i] = char;
        _ = sdk.setName(object_value, &wide);
    }

    pub fn readBuffer(self: *Backend, buf: *core.Buffer, offset: usize, out: []u8) bool {
        return cmds.readBuffer(self, buf, offset, out);
    }

    pub fn readImage(self: *Backend, img: *core.Image, region: *const core.ReadRegion, out: []u8) bool {
        return cmds.readImage(self, img, region, out);
    }

    // command functions, which receive the backend as `self`
    pub const beginPass = cmds.beginPass;
    pub const endPass = cmds.endPass;
    pub const applyViewport = cmds.applyViewport;
    pub const applyScissorRect = cmds.applyScissorRect;
    pub const applyPipeline = cmds.applyPipeline;
    pub const applyBindings = cmds.applyBindings;
    pub const applyUniforms = cmds.applyUniforms;
    pub const draw = cmds.draw;
    pub const dispatch = cmds.dispatch;
    pub const writeBufferTransient = cmds.writeBufferTransient;
    pub const writeImageTransient = cmds.writeImageTransient;
    pub const writeBufferUnsealed = cmds.writeBufferUnsealed;
    pub const writeImageUnsealed = cmds.writeImageUnsealed;
    pub const sealBuffer = cmds.sealBuffer;
    pub const sealImage = cmds.sealImage;
    pub const copyBufferToBuffer = cmds.copyBufferToBuffer;
    pub const copyBufferToImage = cmds.copyBufferToImage;
    pub const pushDebugGroup = cmds.pushDebugGroup;
    pub const popDebugGroup = cmds.popDebugGroup;
};
