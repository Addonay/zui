//! WebGPU backend, ported from the `_sg_wgpu_*` implementation of sokol_gfx.h:18428-20693
//! and the backend state of sokol_gfx.h:7855-7885. Driver functions are resolved at runtime
//! through the environment's get_proc_address (see sdk.zig).
const std = @import("std");
const core = @import("../../core.zig");
const t = @import("../../types.zig");
const e = @import("../../enums.zig");
const formats = @import("../../formats.zig");
const sdk = @import("sdk.zig");
const convert = @import("convert.zig");
const payload = @import("resources.zig");

const max_map_spins: usize = 1 << 26;
pub const PendingRead = @import("readback.zig").Pending;
const ScopeResult = @import("future.zig").ScopeResult;

/// Extra size of the uniform buffer, on top of the requested uniform_buffer_size.
const max_uniform_update_size: u32 = 1 << 16;
const max_ub_bindgroup_entries = 8;
const max_view_smp_bindgroup_entries = 32 + 12;
const max_ub_bindgroup_wgsl_slots = 2 * 8;
const max_view_smp_bindgroup_wgsl_slots = 128;
const max_vertex_buffers = 8;
const max_vertex_attributes = 16;
const max_color_attachments = 8;
const ub_bindgroup_index = 0;
const view_smp_bindgroup_index = 1;
const bindgroup_key_num_items = 1 + max_view_smp_bindgroup_entries;

/// Kind of resource referenced by a bindgroup cache key item (_sg_wgpu_bindgroups_cache_item_type_t).
const CacheItemType = enum(u8) {
    none = 0,
    view = 1,
    sampler = 2,
    pipeline = 3,
};

/// A cached or pooled bindgroup (_sg_wgpu_bindgroup_t).
pub const BindGroup = struct {
    slot: core.Slot = .{},
    bindgroup: ?sdk.BindGroup = null,
    key: CacheKey = .{},
};

const CacheKey = struct {
    hash: u64 = 0,
    items: [bindgroup_key_num_items]u64 = @splat(0),
};

const UniformSystem = struct {
    num_bytes: u32 = 0,
    offset: u32 = 0,
    staging: []u8 = &.{},
    buf: ?sdk.Buffer = null,
    dirty: bool = false,
    /// Indexed by sokol-gfx uniform block slot.
    bind_offsets: [max_ub_bindgroup_entries]u32 = @splat(0),
};

const VertexBufferCache = struct {
    buffer: u32 = 0,
    offset: u64 = 0,
};

const IndexBufferCache = struct {
    buffer: u32 = 0,
    offset: u64 = 0,
    format: sdk.IndexFormat = .undefined,
};

const BindingsCache = struct {
    vbs: [max_vertex_buffers]VertexBufferCache = @splat(.{}),
    ib: IndexBufferCache = .{},
    /// Id of the bindgroup bound at the view/sampler bindgroup index, 0 if none.
    bg: u32 = 0,
};

const BindgroupsCache = struct {
    num: u32 = 0,
    index_mask: u32 = 0,
    /// Bindgroup ids indexed by hash, 0 for empty items.
    items: []u32 = &.{},
};

/// The WebGPU backend state (_sg_wgpu_backend_t).
pub const Backend = struct {
    allocator: std.mem.Allocator,
    procs: sdk.Procs,
    dev: sdk.Device,
    queue_handle: sdk.Queue,
    /// wgpu-native's wgpuDevicePoll, used to wait for mapping; null if the library lacks it.
    device_poll: ?sdk.DevicePollFn = null,
    instance: ?sdk.Instance = null,
    wait_any: ?sdk.InstanceWaitAnyFn = null,
    wait_timeout_ns: u64 = 0,
    push_scope: ?sdk.PushErrorScopeFn = null,
    pop_scope: ?sdk.PopErrorScopeFn = null,
    scopes: std.ArrayList(*ScopeResult) = .empty,
    limits: sdk.Limits = .{},
    cmd_enc: ?sdk.CommandEncoder = null,
    rpass_enc: ?sdk.RenderPassEncoder = null,
    cpass_enc: ?sdk.ComputePassEncoder = null,
    uniform: UniformSystem = .{},
    bindings_cache: BindingsCache = .{},
    bindgroups_cache: BindgroupsCache = .{},
    bindgroups_pool: core.Pool(BindGroup),
    readbacks: std.ArrayList(*PendingRead) = .empty,

    pub fn init(s: *core.State) !Backend {
        const env = s.desc.environment.wgpu;
        const device_ptr = env.device orelse return error.MissingWgpuDevice;
        const get_proc_address = env.get_proc_address orelse return error.MissingWgpuProcAddress;
        std.debug.assert(s.desc.uniform_buffer_size > 0);
        const procs = try sdk.loadProcs(get_proc_address, env.user_data);
        var self: Backend = .{
            .allocator = s.allocator,
            .procs = procs,
            .dev = fromOpaque(sdk.Device, device_ptr),
            .queue_handle = undefined,
            .bindgroups_pool = undefined,
        };
        self.queue_handle = self.procs.wgpuDeviceGetQueue(self.dev) orelse return error.WgpuInitFailed;
        if (get_proc_address("wgpuDevicePoll", env.user_data)) |address| {
            self.device_poll = @ptrCast(@alignCast(address));
        }
        if (env.instance) |instance| {
            self.instance = fromOpaque(sdk.Instance, instance);
            self.wait_timeout_ns = env.wait_timeout_ns;
            if (get_proc_address("wgpuInstanceWaitAny", env.user_data)) |address| self.wait_any = @ptrCast(@alignCast(address));
        }
        if (get_proc_address("wgpuDevicePushErrorScope", env.user_data)) |address| self.push_scope = @ptrCast(@alignCast(address));
        if (get_proc_address("wgpuDevicePopErrorScope", env.user_data)) |address| self.pop_scope = @ptrCast(@alignCast(address));
        self.initCaps(s);
        try self.uniformSystemInit(s.desc.uniform_buffer_size);
        errdefer self.uniformSystemDiscard();
        const cache_size = s.desc.wgpu.bindgroups_cache_size;
        if (cache_size <= 1) {
            core.logPanic(.wgpu_bindgroupscache_size_greater_one);
            return error.WgpuInitFailed;
        }
        if (@popCount(@as(u32, @intCast(cache_size))) != 1) {
            core.logPanic(.wgpu_bindgroupscache_size_pow2);
            return error.WgpuInitFailed;
        }
        self.bindgroups_pool = try core.Pool(BindGroup).init(s.allocator, @intCast(cache_size));
        errdefer self.bindgroups_pool.deinit(s.allocator);
        const num: u32 = @intCast(cache_size);
        self.bindgroups_cache = .{ .num = num, .index_mask = num - 1, .items = try s.allocator.alloc(u32, num) };
        @memset(self.bindgroups_cache.items, 0);
        return self;
    }

    pub fn deinit(self: *Backend) void {
        self.collectReadbacks(true);
        self.collectScopes(true);
        self.scopes.deinit(self.allocator);
        self.readbacks.deinit(self.allocator);
        self.discardAllBindgroups();
        self.allocator.free(self.bindgroups_cache.items);
        self.bindgroups_cache = .{};
        self.bindgroups_pool.deinit(self.allocator);
        self.uniformSystemDiscard();
        // the command encoder is usually released in commit()
        if (self.cmd_enc) |enc| {
            self.procs.wgpuCommandEncoderRelease(enc);
            self.cmd_enc = null;
        }
        self.procs.wgpuQueueRelease(self.queue_handle);
    }

    pub fn resetStateCache(self: *Backend) void {
        self.bindings_cache = .{};
    }

    // ------------------------------------------------------------ capabilities

    fn hasFeature(self: *const Backend, feature: sdk.FeatureName) bool {
        return self.procs.wgpuDeviceHasFeature(self.dev, feature) != 0;
    }

    fn initCaps(self: *Backend, s: *core.State) void {
        s.features = .{
            .origin_top_left = true,
            .image_clamp_to_border = false,
            .mrt_independent_blend_state = true,
            .mrt_independent_write_mask = true,
            .compute = true,
            .msaa_texture_bindings = true,
            .draw_base_vertex = true,
            .draw_base_instance = true,
            .dual_source_blending = self.hasFeature(.dual_source_blending),
            .vertexformat_int10_n2 = false,
            .copy_buffer_to_image_relaxed_buffer_type = true,
            // when copying from a non-staging buffer, bytes-per-row must be a multiple of 256
            .copy_buffer_to_image_relaxed_bytes_per_row = false,
        };
        _ = self.procs.wgpuDeviceGetLimits(self.dev, &self.limits);
        const l = &self.limits;
        s.limits = .{
            .max_image_size_2d = @intCast(l.max_texture_dimension2_d),
            // not a bug, see: https://github.com/gpuweb/gpuweb/issues/1327
            .max_image_size_cube = @intCast(l.max_texture_dimension2_d),
            .max_image_size_3d = @intCast(l.max_texture_dimension3_d),
            .max_image_size_array = @intCast(l.max_texture_dimension2_d),
            .max_image_array_layers = @intCast(l.max_texture_array_layers),
            .max_vertex_attrs = max_vertex_attributes,
            .max_color_attachments = @intCast(@min(l.max_color_attachments, max_color_attachments)),
            .max_texture_bindings_per_stage = @intCast(@min(l.max_sampled_textures_per_shader_stage, 32)),
            .max_storage_buffer_bindings_per_stage = @intCast(@min(l.max_storage_buffers_per_shader_stage, 32)),
            .max_storage_image_bindings_per_stage = @intCast(@min(l.max_storage_textures_per_shader_stage, 32)),
        };
        self.initFormatCaps(&s.formats);
    }

    fn initFormatCaps(self: *const Backend, fmts: []t.PixelformatInfo) void {
        // sokol_gfx.h:10759-10803; flags: s=sample, f=filter, b=blend, r=render, m=msaa,
        // d=depth, c=compute read and write
        markFormat(fmts, .r8, "sfbrm");
        markFormat(fmts, .rg8, "sfbrm");
        markFormat(fmts, .rgba8, "sfbrm");
        markFormat(fmts, .srgb8a8, "sfbrm");
        markFormat(fmts, .bgra8, "sfbrm");
        markFormat(fmts, .r16f, "sfbrm");
        markFormat(fmts, .rg16f, "sfbrm");
        markFormat(fmts, .rgba16f, "sfbrm");
        markFormat(fmts, .rgb10a2, "sfbrm");

        markFormat(fmts, .r8sn, "sf");
        markFormat(fmts, .rg8sn, "sf");
        markFormat(fmts, .rgba8sn, "sf");
        // FIXME: can be made renderable via extension
        markFormat(fmts, .rg11b10f, "sf");

        // NOTE: msaa rendering is possible in WebGPU, but no resolve,
        // which is a combination that's not currently supported in sokol-gfx
        inline for (.{ .r8ui, .r8si, .rg8ui, .rg8si, .rgba8ui, .rgba8si, .r16ui, .r16si, .rg16ui, .rg16si, .rgba16ui, .rgba16si, .r32ui, .r32si, .rg32ui, .rg32si, .rgba32ui, .rgba32si }) |fmt| {
            markFormat(fmts, fmt, "sr");
        }

        if (self.hasFeature(.float32_filterable)) {
            markFormat(fmts, .r32f, "sfr");
            markFormat(fmts, .rg32f, "sfr");
            markFormat(fmts, .rgba32f, "sfr");
        } else {
            markFormat(fmts, .r32f, "sr");
            markFormat(fmts, .rg32f, "sr");
            markFormat(fmts, .rgba32f, "sr");
        }
        if (self.hasFeature(.float32_blendable)) {
            fmts[@backingInt(e.PixelFormat.r32f)].blend = true;
            fmts[@backingInt(e.PixelFormat.rg32f)].blend = true;
            fmts[@backingInt(e.PixelFormat.rgba32f)].blend = true;
        }
        if (self.hasFeature(.texture_formats_tier1)) {
            markFormat(fmts, .r16, "sbr");
            markFormat(fmts, .r16sn, "sbr");
            markFormat(fmts, .rg16, "sbr");
            markFormat(fmts, .rg16sn, "sbr");
            markFormat(fmts, .rgba16, "sbr");
            markFormat(fmts, .rgba16sn, "sbr");
            markFormat(fmts, .r8sn, "sbr");
            markFormat(fmts, .rg8sn, "sbr");
            markFormat(fmts, .rgba8sn, "sbr");
        }

        markFormat(fmts, .depth, "srmd");
        // NOTE: the C backend marks depth_stencil unconditionally, but WebGPU only allows the
        // Depth32FloatStencil8 texture format when the device has the feature enabled
        if (self.hasFeature(.depth32_float_stencil8)) markFormat(fmts, .depth_stencil, "srmd");

        markFormat(fmts, .rgb9e5, "sf");

        if (self.hasFeature(.texture_compression_bc)) {
            inline for (.{ .bc1_rgba, .bc2_rgba, .bc3_rgba, .bc3_srgba, .bc4_r, .bc4_rsn, .bc5_rg, .bc5_rgsn, .bc6h_rgbf, .bc6h_rgbuf, .bc7_rgba, .bc7_srgba }) |fmt| {
                markFormat(fmts, fmt, "sf");
            }
        }
        if (self.hasFeature(.texture_compression_etc2)) {
            inline for (.{ .etc2_rgb8, .etc2_srgb8, .etc2_rgb8a1, .etc2_rgba8, .etc2_srgb8a8, .eac_r11, .eac_r11sn, .eac_rg11, .eac_rg11sn }) |fmt| {
                markFormat(fmts, fmt, "sf");
            }
        }
        if (self.hasFeature(.texture_compression_astc)) {
            markFormat(fmts, .astc_4x4_rgba, "sf");
            markFormat(fmts, .astc_4x4_srgba, "sf");
        }

        // see: https://github.com/gpuweb/gpuweb/issues/513
        // NOTE: can't express read-only/write-only vs read-write in sokol-gfx,
        // e.g. some of the below formats are only read-write with texture-tier-2
        inline for (.{ .rgba8, .rgba8sn, .rgba8ui, .rgba8si, .rgba16ui, .rgba16si, .rgba16f, .r32ui, .r32si, .r32f, .rg32ui, .rg32si, .rg32f, .rgba32ui, .rgba32si, .rgba32f }) |fmt| {
            markFormat(fmts, fmt, "c");
        }
        if (self.hasFeature(.texture_formats_tier2)) {
            inline for (.{ .r8, .r8ui, .r8si, .r16ui, .r16si, .r16f }) |fmt| {
                markFormat(fmts, fmt, "c");
            }
        }
    }

    // ------------------------------------------------------------ uniform system

    fn uniformSystemInit(self: *Backend, uniform_buffer_size: i32) !void {
        // Add the max-uniform-update size (64 KB) to the requested buffer size, to prevent
        // validation errors in the WebGPU implementation if the entire buffer size is used per frame.
        const num_bytes: u32 = @intCast(uniform_buffer_size + max_uniform_update_size);
        self.uniform.num_bytes = num_bytes;
        self.uniform.staging = try self.allocator.alloc(u8, num_bytes);
        errdefer self.allocator.free(self.uniform.staging);
        self.uniform.buf = self.procs.wgpuDeviceCreateBuffer(self.dev, &sdk.BufferDescriptor{
            .size = num_bytes,
            .usage = sdk.BufferUsage.uniform | sdk.BufferUsage.copy_dst,
        }) orelse return error.WgpuInitFailed;
    }

    fn uniformSystemDiscard(self: *Backend) void {
        if (self.uniform.buf) |buf| {
            self.procs.wgpuBufferRelease(buf);
            self.uniform.buf = null;
        }
        if (self.uniform.staging.len > 0) {
            self.allocator.free(self.uniform.staging);
            self.uniform.staging = &.{};
        }
    }

    fn uniformSystemSetBindgroup(self: *Backend) void {
        self.uniform.dirty = false;
        const shd = core.state().cur_pip.get().cmn.shader.get();
        // NOTE: dynamic offsets must be in binding order, not in BindGroupEntry order
        var dyn_offsets: [max_ub_bindgroup_entries]u32 = @splat(0);
        for (0..max_ub_bindgroup_entries) |i| {
            if (shd.cmn.uniform_blocks[i].stage == .none) continue;
            const dynoffset_index = shd.native.wgpu.ub_dynoffsets[i];
            dyn_offsets[dynoffset_index] = self.uniform.bind_offsets[i];
        }
        const count: usize = shd.native.wgpu.ub_num_dynoffsets;
        if (core.state().cur_pass.is_compute) {
            self.procs.wgpuComputePassEncoderSetBindGroup(self.cpass_enc.?, ub_bindgroup_index, shd.native.wgpu.bg_ub, count, &dyn_offsets[0]);
        } else {
            self.procs.wgpuRenderPassEncoderSetBindGroup(self.rpass_enc.?, ub_bindgroup_index, shd.native.wgpu.bg_ub, count, &dyn_offsets[0]);
        }
    }

    fn uniformSystemOnCommit(self: *Backend) void {
        const offset = self.uniform.offset;
        self.procs.wgpuQueueWriteBuffer(self.queue_handle, self.uniform.buf, 0, @ptrCast(self.uniform.staging.ptr), offset);
        core.statsAdd("wgpu.uniforms.size_write_buffer", offset);
        self.uniform.offset = 0;
        self.uniform.bind_offsets = @splat(0);
    }

    // ------------------------------------------------------------ bindgroups pool and cache

    fn lookupBindgroup(self: *Backend, id: u32) ?*BindGroup {
        if (id == 0) return null;
        return self.bindgroups_pool.lookup(id);
    }

    fn allocBindgroup(self: *Backend) ?*BindGroup {
        const id = self.bindgroups_pool.alloc() orelse {
            core.logError(.wgpu_bindgroups_pool_exhausted);
            return null;
        };
        return self.bindgroups_pool.at(id);
    }

    fn resetBindgroupToAllocState(bg: *BindGroup) void {
        const slot = bg.slot;
        bg.* = .{};
        bg.slot = slot;
        bg.slot.state = .alloc;
    }

    fn discardBindgroup(self: *Backend, bg: *BindGroup) void {
        core.statsInc("wgpu.bindings.num_discard_bindgroup");
        if (bg.slot.state == .valid or bg.slot.state == .failed) {
            if (bg.bindgroup) |group| {
                self.procs.wgpuBindGroupRelease(group);
            }
            resetBindgroupToAllocState(bg);
        }
        if (bg.slot.state == .alloc) {
            self.bindgroups_pool.free(bg);
        }
    }

    fn discardAllBindgroups(self: *Backend) void {
        for (self.bindgroups_pool.items[1..]) |*bg| {
            if (bg.slot.state == .valid or bg.slot.state == .failed) self.discardBindgroup(bg);
        }
    }

    fn cacheIndex(self: *const Backend, hash: u64) usize {
        return @as(u32, @truncate(hash)) & self.bindgroups_cache.index_mask;
    }

    fn cacheGet(self: *const Backend, hash: u64) u32 {
        return self.bindgroups_cache.items[self.cacheIndex(hash)];
    }

    fn cacheSet(self: *Backend, hash: u64, id: u32) void {
        self.bindgroups_cache.items[self.cacheIndex(hash)] = id;
    }

    /// Called from the resource discard functions, to discard every cached bindgroup
    /// that references the resource (sokol_gfx.h:19083-19113).
    fn invalidateBindgroupsCache(self: *Backend, kind: CacheItemType, slot: *const core.Slot) void {
        // the key mask ignores the wgpu binding, so that every binding of the resource matches
        const key_mask = bindgroupCacheItem(kind, 0, 0xFFFFFFFF, 0xFFFFFFFF);
        const key_item = bindgroupCacheItem(kind, 0, slot.id, slot.uninit_count) & key_mask;
        for (0..self.bindgroups_cache.num) |cache_idx| {
            const bg_id = self.bindgroups_cache.items[cache_idx];
            if (bg_id == 0) continue;
            const bg = self.lookupBindgroup(bg_id) orelse {
                self.bindgroups_cache.items[cache_idx] = 0;
                continue;
            };
            if (bg.slot.state != .valid) continue;
            var invalidate = false;
            for (bg.key.items) |item| {
                if ((item & key_mask) == key_item) {
                    invalidate = true;
                    break;
                }
            }
            if (invalidate) {
                self.discardBindgroup(bg);
                self.bindgroups_cache.items[cache_idx] = 0;
                core.statsInc("wgpu.bindings.num_bindgroup_cache_invalidates");
            }
        }
    }

    fn initBindgroupCacheKey(key: *CacheKey, bnd: *const core.BindingsPtrs) void {
        const shd = bnd.pip.cmn.shader.get();
        key.items = @splat(0);
        key.items[0] = bindgroupCacheItem(.pipeline, 0xFF, bnd.pip.slot.id, bnd.pip.slot.uninit_count);
        for (0..32) |i| {
            if (shd.cmn.views[i].stage == .none) continue;
            const view = bnd.views[i].?;
            const item_idx = i + 1;
            std.debug.assert(item_idx < bindgroup_key_num_items);
            const binding: u8 = shd.native.wgpu.view_grp1_bnd_n[i];
            key.items[item_idx] = bindgroupCacheItem(.view, binding, view.slot.id, view.slot.uninit_count);
        }
        for (0..12) |i| {
            if (shd.cmn.samplers[i].stage == .none) continue;
            const smp = bnd.smps[i].?;
            const item_idx = i + 1 + 32;
            std.debug.assert(item_idx < bindgroup_key_num_items);
            const binding: u8 = shd.native.wgpu.smp_grp1_bnd_n[i];
            key.items[item_idx] = bindgroupCacheItem(.sampler, binding, smp.slot.id, smp.slot.uninit_count);
        }
        key.hash = murmurHash64(std.mem.sliceAsBytes(&key.items), 0x1234567887654321);
    }

    fn createBindgroup(self: *Backend, bnd: *const core.BindingsPtrs) ?*BindGroup {
        core.statsInc("wgpu.bindings.num_create_bindgroup");
        const bg = self.allocBindgroup() orelse return null;
        const shd = bnd.pip.cmn.shader.get();
        const bgl = shd.native.wgpu.bgl_view_smp.?;
        var bg_entries: [max_view_smp_bindgroup_entries]sdk.BindGroupEntry = @splat(.{});
        var bgl_index: usize = 0;
        for (0..32) |i| {
            if (shd.cmn.views[i].stage == .none) continue;
            const view = bnd.views[i].?;
            const entry = &bg_entries[bgl_index];
            entry.binding = shd.native.wgpu.view_grp1_bnd_n[i];
            if (view.cmn.type == .storagebuffer) {
                const buf = view.cmn.buf.ref.get();
                std.debug.assert(view.cmn.buf.offset >= 0 and @as(usize, @intCast(view.cmn.buf.offset)) < buf.cmn.size);
                const offset: usize = @intCast(view.cmn.buf.offset);
                entry.buffer = buf.native.wgpu.buf;
                entry.offset = offset;
                entry.size = buf.cmn.size - offset;
            } else {
                entry.texture_view = view.native.wgpu.view.?;
            }
            bgl_index += 1;
        }
        for (0..12) |i| {
            if (shd.cmn.samplers[i].stage == .none) continue;
            const entry = &bg_entries[bgl_index];
            entry.binding = shd.native.wgpu.smp_grp1_bnd_n[i];
            entry.sampler = bnd.smps[i].?.native.wgpu.smp.?;
            bgl_index += 1;
        }
        const bg_desc: sdk.BindGroupDescriptor = .{
            .layout = bgl,
            .entry_count = bgl_index,
            .entries = &bg_entries[0],
        };
        bg.bindgroup = self.procs.wgpuDeviceCreateBindGroup(self.dev, &bg_desc);
        if (bg.bindgroup == null) {
            core.logError(.wgpu_createbindgroup_failed);
            bg.slot.state = .failed;
            return bg;
        }
        initBindgroupCacheKey(&bg.key, bnd);
        bg.slot.state = .valid;
        return bg;
    }

    fn compareBindgroupCacheKey(k0: *const CacheKey, k1: *const CacheKey) bool {
        if (k0.hash != k1.hash) return false;
        if (!std.mem.eql(u64, &k0.items, &k1.items)) {
            core.statsInc("wgpu.bindings.num_bindgroup_cache_hash_vs_key_mismatch");
            return false;
        }
        return true;
    }

    // ------------------------------------------------------------ bindings cache

    fn setBindgroup(self: *Backend, bg_idx: u32, bg: ?*BindGroup) void {
        const id: u32 = if (bg) |b| b.slot.id else 0;
        if (self.bindings_cache.bg == id) {
            core.statsInc("wgpu.bindings.num_skip_redundant_bindgroup");
            return;
        }
        self.bindings_cache.bg = id;
        core.statsInc("wgpu.bindings.num_set_bindgroup");
        const group: ?sdk.BindGroup = if (bg) |b| b.bindgroup else null;
        if (core.state().cur_pass.is_compute) {
            self.procs.wgpuComputePassEncoderSetBindGroup(self.cpass_enc.?, bg_idx, group, 0, null);
        } else {
            self.procs.wgpuRenderPassEncoderSetBindGroup(self.rpass_enc.?, bg_idx, group, 0, null);
        }
    }

    fn applyBindingsBindgroup(self: *Backend, bnd: *const core.BindingsPtrs) bool {
        if (!core.state().desc.wgpu.disable_bindgroups_cache) {
            var key: CacheKey = .{};
            initBindgroupCacheKey(&key, bnd);
            const bg_id = self.cacheGet(key.hash);
            var bg: ?*BindGroup = null;
            if (bg_id != 0) {
                // potential cache hit
                bg = self.lookupBindgroup(bg_id);
                if (bg) |cached| {
                    if (cached.slot.state != .valid or !compareBindgroupCacheKey(&key, &cached.key)) {
                        // cache collision (or stale entry), need to delete the cached bindgroup
                        core.statsInc("wgpu.bindings.num_bindgroup_cache_collisions");
                        self.discardBindgroup(cached);
                        self.cacheSet(key.hash, 0);
                        bg = null;
                    } else {
                        core.statsInc("wgpu.bindings.num_bindgroup_cache_hits");
                    }
                }
            } else {
                core.statsInc("wgpu.bindings.num_bindgroup_cache_misses");
            }
            if (bg == null) {
                // either no cache entry yet, or cache collision, create new bindgroup and store in cache
                bg = self.createBindgroup(bnd) orelse return false;
                self.cacheSet(key.hash, bg.?.slot.id);
            }
            if (bg.?.slot.state == .valid) {
                self.setBindgroup(view_smp_bindgroup_index, bg);
            } else {
                return false;
            }
        } else {
            // bindgroups cache disabled, create and destroy bindgroup on the fly (expensive!)
            const bg = self.createBindgroup(bnd) orelse return false;
            if (bg.slot.state == .valid) {
                self.setBindgroup(view_smp_bindgroup_index, bg);
            }
            self.discardBindgroup(bg);
        }
        return true;
    }

    fn applyIndexBuffer(self: *Backend, bnd: *const core.BindingsPtrs) bool {
        const ib = bnd.ib;
        const offset: u64 = @intCast(bnd.ib_offset);
        const format = convert.indexFormat(bnd.pip.cmn.index_type);
        const ib_id: u32 = if (ib) |buf| buf.slot.id else 0;
        if (self.bindings_cache.ib.buffer != ib_id or self.bindings_cache.ib.offset != offset or self.bindings_cache.ib.format != format) {
            self.bindings_cache.ib = .{ .buffer = ib_id, .offset = if (ib != null) offset else 0, .format = if (ib != null) format else .undefined };
            if (ib) |buf| {
                const buf_size: u64 = buf.cmn.size;
                std.debug.assert(buf_size > offset);
                self.procs.wgpuRenderPassEncoderSetIndexBuffer(self.rpass_enc.?, buf.native.wgpu.buf, format, offset, buf_size - offset);
            }
            core.statsInc("wgpu.bindings.num_set_index_buffer");
        } else {
            core.statsInc("wgpu.bindings.num_skip_redundant_index_buffer");
        }
        return true;
    }

    fn applyVertexBuffers(self: *Backend, bnd: *const core.BindingsPtrs) bool {
        for (0..max_vertex_buffers) |slot| {
            const vb = bnd.vbs[slot];
            const offset: u64 = @intCast(bnd.vb_offsets[slot]);
            const vb_id: u32 = if (vb) |buf| buf.slot.id else 0;
            const cache = &self.bindings_cache.vbs[slot];
            if (cache.buffer != vb_id or cache.offset != offset) {
                cache.* = .{ .buffer = vb_id, .offset = if (vb != null) offset else 0 };
                if (vb) |buf| {
                    const buf_size: u64 = buf.cmn.size;
                    std.debug.assert(buf_size > offset);
                    self.procs.wgpuRenderPassEncoderSetVertexBuffer(self.rpass_enc.?, @intCast(slot), buf.native.wgpu.buf, offset, buf_size - offset);
                } else {
                    self.procs.wgpuRenderPassEncoderSetVertexBuffer(self.rpass_enc.?, @intCast(slot), null, 0, 0);
                }
                core.statsInc("wgpu.bindings.num_set_vertex_buffer");
            } else {
                core.statsInc("wgpu.bindings.num_skip_redundant_vertex_buffer");
            }
        }
        return true;
    }

    pub fn applyBindings(self: *Backend, bnd: *const core.BindingsPtrs) bool {
        var ok = true;
        if (!core.state().cur_pass.is_compute) {
            if (!self.applyIndexBuffer(bnd)) ok = false;
            if (!self.applyVertexBuffers(bnd)) ok = false;
        }
        if (!self.applyBindingsBindgroup(bnd)) ok = false;
        return ok;
    }

    // ------------------------------------------------------------ resource creation

    pub fn createBuffer(self: *Backend, buf: *core.Buffer, desc: *const t.BufferDesc) e.ResourceState {
        buf.native = .{ .wgpu = .{} };
        const res = &buf.native.wgpu;
        std.debug.assert(buf.cmn.size > 0);
        // buffer mapping size must be a multiple of 4, so round up the buffer size
        // (only a problem with index buffers containing an odd number of indices)
        const wgpu_size = roundupPow2(u64, @intCast(buf.cmn.size), 4);
        if (desc.wgpu_buffer) |injected| {
            res.buf = fromOpaque(sdk.Buffer, injected);
            self.procs.wgpuBufferAddRef(res.buf.?);
        } else if (desc.usage.staging_buffer or desc.usage.staging_index_buffer) {
            res.staging = self.allocator.alloc(u8, @intCast(wgpu_size)) catch return .failed;
        } else {
            const map_at_creation = desc.data.ptr != null or buf.cmn.usage.write_unsealed;
            const wgpu_desc: sdk.BufferDescriptor = .{
                .label = convert.stringView(desc.label),
                .usage = convert.bufferUsage(buf.cmn.usage),
                .size = wgpu_size,
                .mapped_at_creation = @intFromBool(map_at_creation),
            };
            res.buf = self.procs.wgpuDeviceCreateBuffer(self.dev, &wgpu_desc) orelse {
                core.logError(.wgpu_create_buffer_failed);
                return .failed;
            };
            if (map_at_creation) {
                // FIXME: inefficient on WASM
                const mapped = self.procs.wgpuBufferGetMappedRange(res.buf.?, 0, @intCast(wgpu_size)) orelse unreachable;
                res.mapped_ptr = @ptrCast(mapped);
                if (desc.data.ptr) |src| {
                    std.debug.assert(desc.data.size <= buf.cmn.size);
                    const bytes: [*]const u8 = @ptrCast(src);
                    @memcpy(res.mapped_ptr.?[0..desc.data.size], bytes[0..desc.data.size]);
                    self.procs.wgpuBufferUnmap(res.buf.?);
                    res.mapped_ptr = null;
                }
            }
        }
        return .valid;
    }

    pub fn discardBuffer(self: *Backend, buf: *core.Buffer) void {
        const res = switch (buf.native) {
            .wgpu => |*value| value,
            else => return,
        };
        if (res.mapped_ptr != null) {
            self.procs.wgpuBufferUnmap(res.buf.?);
            res.mapped_ptr = null;
        }
        if (res.staging) |staging| {
            self.allocator.free(staging);
            res.staging = null;
        }
        if (res.buf) |gpu_buf| {
            self.procs.wgpuBufferRelease(gpu_buf);
            res.buf = null;
        }
    }

    pub fn sealBuffer(self: *Backend, buf: *core.Buffer) void {
        const res = &buf.native.wgpu;
        std.debug.assert(res.buf != null and res.mapped_ptr != null);
        self.procs.wgpuBufferUnmap(res.buf.?);
        res.mapped_ptr = null;
    }

    pub fn createImage(self: *Backend, img: *core.Image, desc: *const t.ImageDesc) e.ResourceState {
        img.native = .{ .wgpu = .{} };
        const res = &img.native.wgpu;
        if (desc.wgpu_texture) |injected| {
            res.tex = fromOpaque(sdk.Texture, injected);
            self.procs.wgpuTextureAddRef(res.tex.?);
            return .valid;
        }
        var usage: u64 = sdk.TextureUsage.texture_binding;
        // NOTE: not in the C backend, which never reads images back; readImage needs it
        if (desc.usage.copy_src) usage |= sdk.TextureUsage.copy_src;
        if (desc.usage.color_attachment or desc.usage.resolve_attachment or desc.usage.depth_stencil_attachment) {
            usage |= sdk.TextureUsage.render_attachment;
        } else {
            usage |= sdk.TextureUsage.copy_dst;
        }
        if (desc.usage.storage_image) {
            usage |= sdk.TextureUsage.storage_binding;
        }
        const tex_desc: sdk.TextureDescriptor = .{
            .label = convert.stringView(desc.label),
            .usage = usage,
            .dimension = convert.textureDimension(img.cmn.type),
            .size = .{
                .width = @intCast(img.cmn.width),
                .height = @intCast(img.cmn.height),
                .depth_or_array_layers = @intCast(img.cmn.num_slices),
            },
            .format = convert.textureFormat(img.cmn.pixel_format),
            .mip_level_count = @intCast(img.cmn.num_mipmaps),
            .sample_count = @intCast(img.cmn.sample_count),
        };
        res.tex = self.procs.wgpuDeviceCreateTexture(self.dev, &tex_desc) orelse {
            core.logError(.wgpu_create_texture_failed);
            return .failed;
        };
        if (desc.data.mip_levels[0].ptr != null) {
            self.copyImageData(img, &desc.data);
        }
        return .valid;
    }

    pub fn discardImage(self: *Backend, img: *core.Image) void {
        const res = switch (img.native) {
            .wgpu => |*value| value,
            else => return,
        };
        if (res.tex) |tex| {
            self.procs.wgpuTextureRelease(tex);
            res.tex = null;
        }
    }

    pub fn sealImage(self: *Backend, img: *core.Image) void {
        // nothing to do here
        _ = self;
        _ = img;
    }

    pub fn createSampler(self: *Backend, smp: *core.Sampler, desc: *const t.SamplerDesc) e.ResourceState {
        smp.native = .{ .wgpu = .{} };
        const res = &smp.native.wgpu;
        if (desc.wgpu_sampler) |injected| {
            res.smp = fromOpaque(sdk.Sampler, injected);
            self.procs.wgpuSamplerAddRef(res.smp.?);
            return .valid;
        }
        var wgpu_desc: sdk.SamplerDescriptor = .{
            .label = convert.stringView(desc.label),
            .address_mode_u = convert.addressMode(desc.wrap_u),
            .address_mode_v = convert.addressMode(desc.wrap_v),
            .address_mode_w = convert.addressMode(desc.wrap_w),
            .mag_filter = convert.minMagFilter(desc.mag_filter),
            .min_filter = convert.minMagFilter(desc.min_filter),
            .mipmap_filter = convert.mipmapFilter(desc.mipmap_filter),
            .lod_min_clamp = desc.min_lod,
            .lod_max_clamp = desc.max_lod,
            .compare = convert.compareFunc(desc.compare),
            .max_anisotropy = @intCast(desc.max_anisotropy),
        };
        if (wgpu_desc.compare == .never) {
            wgpu_desc.compare = .undefined;
        }
        res.smp = self.procs.wgpuDeviceCreateSampler(self.dev, &wgpu_desc) orelse {
            core.logError(.wgpu_create_sampler_failed);
            return .failed;
        };
        return .valid;
    }

    pub fn discardSampler(self: *Backend, smp: *core.Sampler) void {
        self.invalidateBindgroupsCache(.sampler, &smp.slot);
        const res = switch (smp.native) {
            .wgpu => |*value| value,
            else => return,
        };
        if (res.smp) |sampler| {
            self.procs.wgpuSamplerRelease(sampler);
            res.smp = null;
        }
    }

    fn pumpFuture(self: *Backend, future: sdk.Future, wait: bool) bool {
        if (self.device_poll) |poll| {
            _ = poll(self.dev, @intFromBool(wait), null);
            return true;
        }
        if (self.wait_any) |wait_any| if (self.instance) |instance| {
            var info: sdk.FutureWaitInfo = .{ .future = future };
            const result = wait_any(instance, 1, @ptrCast(&info), if (wait) self.wait_timeout_ns else 0);
            return result == 1 or result == 2;
        };
        return false;
    }
    fn collectScopes(self: *Backend, wait: bool) void {
        var i: usize = 0;
        while (i < self.scopes.items.len) {
            const scope = self.scopes.items[i];
            if (wait) while (!scope.finished.load(.acquire)) {
                _ = self.pumpFuture(scope.future, false);
                std.atomic.spinLoopHint();
            };
            if (!scope.finished.load(.acquire)) {
                i += 1;
                continue;
            }
            scope.release();
            _ = self.scopes.swapRemove(i);
        }
    }
    fn beginScope(self: *Backend) !?*ScopeResult {
        if (@import("builtin").cpu.arch.isWasm() or self.push_scope == null or self.pop_scope == null) return null;
        if (self.device_poll == null and (self.instance == null or self.wait_any == null or self.wait_timeout_ns == 0)) return null;
        self.collectScopes(false);
        try self.scopes.ensureUnusedCapacity(self.allocator, 1);
        const scope = try self.allocator.create(ScopeResult);
        scope.* = .{ .allocator = self.allocator };
        self.scopes.appendAssumeCapacity(scope);
        self.push_scope.?(self.dev, 1); // validation
        return scope;
    }
    fn endScope(self: *Backend, maybe_scope: ?*ScopeResult) bool {
        const scope = maybe_scope orelse return true;
        defer scope.release();
        _ = scope.refs.fetchAdd(1, .monotonic);
        scope.future = self.pop_scope.?(self.dev, .{ .callback = ScopeResult.completed, .userdata1 = scope });
        for (0..max_map_spins) |_| {
            if (scope.finished.load(.acquire)) {
                if (scope.status == 1 and scope.error_type == 1) return true;
                core.log(.wgpu_create_shader_module_failed, .err, &scope.message);
                return false;
            }
            if (!self.pumpFuture(scope.future, true)) return false;
        }
        return false;
    }

    fn createShaderFunc(self: *Backend, func: *const t.ShaderFunction, label: ?[*:0]const u8) payload.ShaderFunc {
        var res: payload.ShaderFunc = .{};
        const entry = std.mem.span(func.entry.?);
        const len = @min(entry.len, payload.entry_name_size - 1);
        @memcpy(res.entry[0..len], entry[0..len]);
        res.entry[len] = 0;

        var wgsl: sdk.ShaderSourceWGSL = .{
            .chain = .{ .s_type = .shader_source_wgsl },
            .code = convert.stringView(func.source),
        };
        const module_desc: sdk.ShaderModuleDescriptor = .{
            .next_in_chain = &wgsl.chain,
            .label = convert.stringView(label),
        };
        // Native error scopes turn invalid WGSL into a normal creation failure.
        // Browser creation stays asynchronous and reports errors through its host.
        const scope = self.beginScope() catch {
            core.logError(.malloc_failed);
            return res;
        };
        res.module = self.procs.wgpuDeviceCreateShaderModule(self.dev, &module_desc);
        if (!self.endScope(scope)) {
            self.procs.wgpuShaderModuleRelease(res.module);
            res.module = null;
            return res;
        }
        if (res.module == null) {
            core.logError(.wgpu_create_shader_module_failed);
        }
        return res;
    }

    fn discardShaderFunc(self: *Backend, func: *payload.ShaderFunc) void {
        if (func.module) |module| {
            self.procs.wgpuShaderModuleRelease(module);
            func.module = null;
        }
    }

    /// Release-mode bounds check of the WGSL binding slots (_sg_wgpu_ensure_wgsl_bindslot_ranges).
    fn ensureWgslBindslotRanges(desc: *const t.ShaderDesc) bool {
        for (desc.uniform_blocks) |ub| {
            if (ub.stage != .none and ub.wgsl_group0_binding_n >= max_ub_bindgroup_wgsl_slots) {
                core.logError(.wgpu_uniformblock_wgsl_group0_binding_out_of_range);
                return false;
            }
        }
        for (desc.views) |view| {
            if (view.texture.stage != .none and view.texture.wgsl_group1_binding_n >= max_view_smp_bindgroup_wgsl_slots) {
                core.logError(.wgpu_texture_wgsl_group1_binding_out_of_range);
                return false;
            }
            if (view.storage_buffer.stage != .none and view.storage_buffer.wgsl_group1_binding_n >= max_view_smp_bindgroup_wgsl_slots) {
                core.logError(.wgpu_storagebuffer_wgsl_group1_binding_out_of_range);
                return false;
            }
            if (view.storage_image.stage != .none and view.storage_image.wgsl_group1_binding_n >= max_view_smp_bindgroup_wgsl_slots) {
                core.logError(.wgpu_storageimage_wgsl_group1_binding_out_of_range);
                return false;
            }
        }
        for (desc.samplers) |smp| {
            if (smp.stage != .none and smp.wgsl_group1_binding_n >= max_view_smp_bindgroup_wgsl_slots) {
                core.logError(.wgpu_sampler_wgsl_group1_binding_out_of_range);
                return false;
            }
        }
        return true;
    }

    pub fn createShader(self: *Backend, shd: *core.Shader, desc: *const t.ShaderDesc) e.ResourceState {
        shd.native = .{ .wgpu = .{} };
        const res = &shd.native.wgpu;
        const cmn = &shd.cmn;
        // a release-mode bounds check on the WGSL binding slots, to be consistent with the other backends
        if (!ensureWgslBindslotRanges(desc)) return .failed;

        // build shader modules
        var shd_valid = true;
        if (desc.vertex_func.source != null) {
            res.vertex_func = self.createShaderFunc(&desc.vertex_func, desc.label);
            shd_valid = shd_valid and res.vertex_func.module != null;
        }
        if (desc.fragment_func.source != null) {
            res.fragment_func = self.createShaderFunc(&desc.fragment_func, desc.label);
            shd_valid = shd_valid and res.fragment_func.module != null;
        }
        if (desc.compute_func.source != null) {
            res.compute_func = self.createShaderFunc(&desc.compute_func, desc.label);
            shd_valid = shd_valid and res.compute_func.module != null;
        }
        if (!shd_valid) {
            self.discardShaderFunc(&res.vertex_func);
            self.discardShaderFunc(&res.fragment_func);
            self.discardShaderFunc(&res.compute_func);
            return .failed;
        }

        // bind group layout and bind group for uniform blocks; also a mapping of sokol-gfx
        // bind slots to the dynamic-offset array indices of the setBindGroup call
        const DynoffsetMapping = struct { sokol_slot: u8, wgpu_slot: u8 };
        var bgl_entries: [max_view_smp_bindgroup_entries]sdk.BindGroupLayoutEntry = @splat(.{});
        var bg_entries: [max_view_smp_bindgroup_entries]sdk.BindGroupEntry = @splat(.{});
        var dynoffset_map: [max_ub_bindgroup_entries]DynoffsetMapping = undefined;
        var bgl_index: usize = 0;
        for (0..max_ub_bindgroup_entries) |i| {
            if (cmn.uniform_blocks[i].stage == .none) continue;
            res.ub_grp0_bnd_n[i] = desc.uniform_blocks[i].wgsl_group0_binding_n;
            const bg_entry = &bg_entries[bgl_index];
            const bgl_entry = &bgl_entries[bgl_index];
            bgl_entry.binding = res.ub_grp0_bnd_n[i];
            bgl_entry.visibility = convert.shaderStage(cmn.uniform_blocks[i].stage);
            bgl_entry.buffer.type = .uniform;
            bgl_entry.buffer.has_dynamic_offset = 1;
            bg_entry.binding = bgl_entry.binding;
            bg_entry.buffer = self.uniform.buf;
            bg_entry.size = max_uniform_update_size;
            dynoffset_map[bgl_index] = .{ .sokol_slot = @intCast(i), .wgpu_slot = @intCast(bgl_entry.binding) };
            bgl_index += 1;
        }
        const bgl_ub_desc: sdk.BindGroupLayoutDescriptor = .{ .entry_count = bgl_index, .entries = &bgl_entries[0] };
        res.bgl_ub = self.procs.wgpuDeviceCreateBindGroupLayout(self.dev, &bgl_ub_desc) orelse {
            core.logError(.wgpu_shader_create_bindgroup_layout_failed);
            return .failed;
        };
        const bg_ub_desc: sdk.BindGroupDescriptor = .{ .layout = res.bgl_ub, .entry_count = bgl_index, .entries = &bg_entries[0] };
        res.bg_ub = self.procs.wgpuDeviceCreateBindGroup(self.dev, &bg_ub_desc) orelse {
            core.logError(.wgpu_createbindgroup_failed);
            return .failed;
        };

        // sort the dynoffset map by wgpu bindings, the dynamic offsets of setBindGroup must be
        // in 'binding order', not in 'bindgroup entry order'
        std.mem.sort(DynoffsetMapping, dynoffset_map[0..bgl_index], {}, struct {
            fn lessThan(_: void, lhs: DynoffsetMapping, rhs: DynoffsetMapping) bool {
                return lhs.wgpu_slot < rhs.wgpu_slot;
            }
        }.lessThan);
        res.ub_num_dynoffsets = @intCast(bgl_index);
        for (0..bgl_index) |i| {
            res.ub_dynoffsets[dynoffset_map[i].sokol_slot] = @intCast(i);
        }

        // bind group layout for textures, storage buffers/images and samplers
        bgl_entries = @splat(.{});
        bgl_index = 0;
        for (0..32) |i| {
            if (cmn.views[i].stage == .none) continue;
            const bgl_entry = &bgl_entries[bgl_index];
            bgl_entry.visibility = convert.shaderStage(cmn.views[i].stage);
            switch (cmn.views[i].view_type) {
                .texture => {
                    res.view_grp1_bnd_n[i] = desc.views[i].texture.wgsl_group1_binding_n;
                    const msaa = cmn.views[i].multisampled;
                    bgl_entry.texture.view_dimension = convert.textureViewDimension(cmn.views[i].image_type);
                    bgl_entry.texture.sample_type = convert.textureSampleType(cmn.views[i].sample_type, msaa);
                    bgl_entry.texture.multisampled = @intFromBool(msaa);
                },
                .storagebuffer => {
                    res.view_grp1_bnd_n[i] = desc.views[i].storage_buffer.wgsl_group1_binding_n;
                    bgl_entry.buffer.type = if (cmn.views[i].sbuf_readonly) .read_only_storage else .storage;
                },
                .storageimage => {
                    res.view_grp1_bnd_n[i] = desc.views[i].storage_image.wgsl_group1_binding_n;
                    bgl_entry.storage_texture.access = if (cmn.views[i].simg_writeonly) .write_only else .read_write;
                    bgl_entry.storage_texture.format = convert.textureFormat(cmn.views[i].access_format);
                    bgl_entry.storage_texture.view_dimension = convert.textureViewDimension(cmn.views[i].image_type);
                },
                else => unreachable,
            }
            bgl_entry.binding = res.view_grp1_bnd_n[i];
            bgl_index += 1;
        }
        for (0..12) |i| {
            if (cmn.samplers[i].stage == .none) continue;
            res.smp_grp1_bnd_n[i] = desc.samplers[i].wgsl_group1_binding_n;
            const bgl_entry = &bgl_entries[bgl_index];
            bgl_entry.binding = res.smp_grp1_bnd_n[i];
            bgl_entry.visibility = convert.shaderStage(cmn.samplers[i].stage);
            bgl_entry.sampler.type = convert.samplerBindingType(cmn.samplers[i].sampler_type);
            bgl_index += 1;
        }
        const bgl_view_smp_desc: sdk.BindGroupLayoutDescriptor = .{ .entry_count = bgl_index, .entries = &bgl_entries[0] };
        res.bgl_view_smp = self.procs.wgpuDeviceCreateBindGroupLayout(self.dev, &bgl_view_smp_desc) orelse {
            core.logError(.wgpu_shader_create_bindgroup_layout_failed);
            return .failed;
        };
        return .valid;
    }

    pub fn discardShader(self: *Backend, shd: *core.Shader) void {
        const res = switch (shd.native) {
            .wgpu => |*value| value,
            else => return,
        };
        self.discardShaderFunc(&res.vertex_func);
        self.discardShaderFunc(&res.fragment_func);
        self.discardShaderFunc(&res.compute_func);
        if (res.bgl_ub) |layout| {
            self.procs.wgpuBindGroupLayoutRelease(layout);
            res.bgl_ub = null;
        }
        if (res.bg_ub) |group| {
            self.procs.wgpuBindGroupRelease(group);
            res.bg_ub = null;
        }
        if (res.bgl_view_smp) |layout| {
            self.procs.wgpuBindGroupLayoutRelease(layout);
            res.bgl_view_smp = null;
        }
    }

    pub fn createPipeline(self: *Backend, pip: *core.Pipeline, desc: *const t.PipelineDesc) e.ResourceState {
        pip.native = .{ .wgpu = .{} };
        const res = &pip.native.wgpu;
        const shd = pip.cmn.shader.get();
        const shd_res = &shd.native.wgpu;
        res.blend_color = .{
            .r = desc.blend_color.r,
            .g = desc.blend_color.g,
            .b = desc.blend_color.b,
            .a = desc.blend_color.a,
        };

        // - @group(0) for uniform blocks
        // - @group(1) for all image, sampler and storagebuffer resources
        const bgls = [_]?sdk.BindGroupLayout{ shd_res.bgl_ub, shd_res.bgl_view_smp };
        const layout_desc: sdk.PipelineLayoutDescriptor = .{
            .bind_group_layout_count = bgls.len,
            .bind_group_layouts = &bgls[0],
        };
        const layout = self.procs.wgpuDeviceCreatePipelineLayout(self.dev, &layout_desc) orelse {
            core.logError(.wgpu_create_pipeline_layout_failed);
            return .failed;
        };

        if (pip.cmn.is_compute) {
            const pip_desc: sdk.ComputePipelineDescriptor = .{
                .label = convert.stringView(desc.label),
                .layout = layout,
                .compute = .{
                    .module = shd_res.compute_func.module,
                    .entry_point = shd_res.compute_func.entryView(),
                },
            };
            const scope = self.beginScope() catch {
                core.logError(.malloc_failed);
                return .failed;
            };
            res.cpip = self.procs.wgpuDeviceCreateComputePipeline(self.dev, &pip_desc);
            if (!self.endScope(scope)) return .failed;
            self.procs.wgpuPipelineLayoutRelease(layout);
            if (res.cpip == null) {
                core.logError(.wgpu_create_compute_pipeline_failed);
                return .failed;
            }
            return .valid;
        }

        var vb_layouts = std.mem.zeroes([max_vertex_buffers]sdk.VertexBufferLayout);
        var vtx_attrs = std.mem.zeroes([max_vertex_buffers][max_vertex_attributes]sdk.VertexAttribute);
        var vb_num: usize = 0;
        for (0..max_vertex_buffers) |vb_idx| {
            const vbl_state = desc.layout.buffers[vb_idx];
            if (vbl_state.stride == 0) break;
            vb_layouts[vb_idx].array_stride = @intCast(vbl_state.stride);
            vb_layouts[vb_idx].step_mode = convert.stepMode(vbl_state.step_func);
            vb_layouts[vb_idx].attributes = &vtx_attrs[vb_idx][0];
            vb_num += 1;
        }
        for (0..max_vertex_attributes) |va_idx| {
            const va_state = desc.layout.attrs[va_idx];
            if (va_state.format == .invalid) break;
            const vb_idx: usize = @intCast(va_state.buffer_index);
            std.debug.assert(vb_idx < max_vertex_buffers and pip.cmn.vertex_buffer_layout_active[vb_idx]);
            const attr_idx = vb_layouts[vb_idx].attribute_count;
            vb_layouts[vb_idx].attribute_count += 1;
            vtx_attrs[vb_idx][attr_idx] = .{
                .format = convert.vertexFormat(va_state.format),
                .offset = @intCast(va_state.offset),
                .shader_location = @intCast(va_idx),
            };
        }

        var ds_state: sdk.DepthStencilState = .{};
        var frag_state: sdk.FragmentState = .{};
        var ctgt_state = std.mem.zeroes([max_color_attachments]sdk.ColorTargetState);
        var blend_state = std.mem.zeroes([max_color_attachments]sdk.BlendState);
        var pip_desc: sdk.RenderPipelineDescriptor = .{
            .label = convert.stringView(desc.label),
            .layout = layout,
            .vertex = .{
                .module = shd_res.vertex_func.module,
                .entry_point = shd_res.vertex_func.entryView(),
                .buffer_count = vb_num,
                .buffers = &vb_layouts[0],
            },
            .primitive = .{
                .topology = convert.topology(desc.primitive_type),
                .strip_index_format = convert.stripIndexFormat(desc.primitive_type, desc.index_type),
                .front_face = convert.frontFace(desc.face_winding),
                .cull_mode = convert.cullMode(desc.cull_mode),
            },
            .multisample = .{
                .count = @intCast(desc.sample_count),
                .mask = 0xFFFFFFFF,
                .alpha_to_coverage_enabled = @intFromBool(desc.alpha_to_coverage_enabled),
            },
        };
        if (desc.depth.pixel_format != .none) {
            const front = desc.stencil.front;
            const back = desc.stencil.back;
            ds_state = .{
                .format = convert.textureFormat(desc.depth.pixel_format),
                .depth_write_enabled = convert.optionalBool(desc.depth.write_enabled),
                .depth_compare = convert.compareFunc(desc.depth.compare),
                .stencil_front = .{
                    .compare = convert.compareFunc(front.compare),
                    .fail_op = convert.stencilOp(front.fail_op),
                    .depth_fail_op = convert.stencilOp(front.depth_fail_op),
                    .pass_op = convert.stencilOp(front.pass_op),
                },
                .stencil_back = .{
                    .compare = convert.compareFunc(back.compare),
                    .fail_op = convert.stencilOp(back.fail_op),
                    .depth_fail_op = convert.stencilOp(back.depth_fail_op),
                    .pass_op = convert.stencilOp(back.pass_op),
                },
                .stencil_read_mask = desc.stencil.read_mask,
                .stencil_write_mask = desc.stencil.write_mask,
                .depth_bias = @intFromFloat(desc.depth.bias),
                .depth_bias_slope_scale = desc.depth.bias_slope_scale,
                .depth_bias_clamp = desc.depth.bias_clamp,
            };
            pip_desc.depth_stencil = &ds_state;
        }
        if (desc.color_count > 0) {
            const color_count: usize = @intCast(desc.color_count);
            frag_state = .{
                .module = shd_res.fragment_func.module,
                .entry_point = shd_res.fragment_func.entryView(),
                .target_count = color_count,
                .targets = &ctgt_state[0],
            };
            for (0..color_count) |i| {
                const color = desc.colors[i];
                ctgt_state[i].format = convert.textureFormat(color.pixel_format);
                ctgt_state[i].write_mask = convert.colorWriteMask(color.write_mask);
                if (color.blend.enabled) {
                    ctgt_state[i].blend = &blend_state[i];
                    blend_state[i] = .{
                        .color = .{
                            .operation = convert.blendOp(color.blend.op_rgb),
                            .src_factor = convert.blendFactor(color.blend.src_factor_rgb),
                            .dst_factor = convert.blendFactor(color.blend.dst_factor_rgb),
                        },
                        .alpha = .{
                            .operation = convert.blendOp(color.blend.op_alpha),
                            .src_factor = convert.blendFactor(color.blend.src_factor_alpha),
                            .dst_factor = convert.blendFactor(color.blend.dst_factor_alpha),
                        },
                    };
                }
            }
            pip_desc.fragment = &frag_state;
        }
        const scope = self.beginScope() catch {
            core.logError(.malloc_failed);
            return .failed;
        };
        res.rpip = self.procs.wgpuDeviceCreateRenderPipeline(self.dev, &pip_desc);
        if (!self.endScope(scope)) return .failed;
        self.procs.wgpuPipelineLayoutRelease(layout);
        if (res.rpip == null) {
            core.logError(.wgpu_create_render_pipeline_failed);
            return .failed;
        }
        return .valid;
    }

    pub fn discardPipeline(self: *Backend, pip: *core.Pipeline) void {
        self.invalidateBindgroupsCache(.pipeline, &pip.slot);
        const res = switch (pip.native) {
            .wgpu => |*value| value,
            else => return,
        };
        if (res.rpip) |pipeline| {
            self.procs.wgpuRenderPipelineRelease(pipeline);
            res.rpip = null;
        }
        if (res.cpip) |pipeline| {
            self.procs.wgpuComputePipelineRelease(pipeline);
            res.cpip = null;
        }
    }

    pub fn createView(self: *Backend, view: *core.View, desc: *const t.ViewDesc) e.ResourceState {
        view.native = .{ .wgpu = .{} };
        if (view.cmn.type == .storagebuffer) return .valid;
        const img = view.cmn.img.ref.get();
        const tex = img.native.wgpu.tex orelse unreachable;
        std.debug.assert(view.cmn.img.mip_level_count >= 1 and view.cmn.img.slice_count >= 1);
        const aspect: sdk.TextureAspect = if (view.cmn.type == .depthstencilattachment)
            .all
        else if (core.isDepthOrDepthStencilFormat(img.cmn.pixel_format))
            .depth_only
        else
            .all;
        const dimension = if (view.cmn.type == .texture)
            convert.textureViewDimension(img.cmn.type)
        else
            convert.attachmentViewDimension(img.cmn.type);
        const texview_desc: sdk.TextureViewDescriptor = .{
            .label = convert.stringView(desc.label),
            .dimension = dimension,
            .base_mip_level = @intCast(view.cmn.img.mip_level),
            .mip_level_count = @intCast(view.cmn.img.mip_level_count),
            .base_array_layer = @intCast(view.cmn.img.slice),
            .array_layer_count = @intCast(view.cmn.img.slice_count),
            .aspect = aspect,
        };
        view.native.wgpu.view = self.procs.wgpuTextureCreateView(tex, &texview_desc) orelse {
            core.logError(.wgpu_create_texture_view_failed);
            return .failed;
        };
        return .valid;
    }

    pub fn discardView(self: *Backend, view: *core.View) void {
        self.invalidateBindgroupsCache(.view, &view.slot);
        const res = switch (view.native) {
            .wgpu => |*value| value,
            else => return,
        };
        if (res.view) |tex_view| {
            self.procs.wgpuTextureViewRelease(tex_view);
            res.view = null;
        }
    }

    // ------------------------------------------------------------ passes

    fn acquireCommandEncoder(self: *Backend) void {
        if (self.cmd_enc == null) {
            const desc: sdk.CommandEncoderDescriptor = .{};
            self.cmd_enc = self.procs.wgpuDeviceCreateCommandEncoder(self.dev, &desc);
            std.debug.assert(self.cmd_enc != null);
        }
    }

    fn beginComputePass(self: *Backend, pass: *const t.Pass) void {
        const desc: sdk.ComputePassDescriptor = .{ .label = convert.stringView(pass.label) };
        self.cpass_enc = self.procs.wgpuCommandEncoderBeginComputePass(self.cmd_enc.?, &desc);
        std.debug.assert(self.cpass_enc != null);
        // clear initial bindings
        self.procs.wgpuComputePassEncoderSetBindGroup(self.cpass_enc.?, ub_bindgroup_index, null, 0, null);
        self.procs.wgpuComputePassEncoderSetBindGroup(self.cpass_enc.?, view_smp_bindgroup_index, null, 0, null);
        core.statsInc("wgpu.bindings.num_set_bindgroup");
    }

    fn beginRenderPass(self: *Backend, pass: *const t.Pass, atts: *const core.AttachmentsPtrs) void {
        var color_atts = std.mem.zeroes([max_color_attachments]sdk.RenderPassColorAttachment);
        var ds_att: sdk.RenderPassDepthStencilAttachment = .{};
        var pass_desc: sdk.RenderPassDescriptor = .{ .label = convert.stringView(pass.label) };
        if (!atts.empty) {
            std.debug.assert(atts.num_color_views <= max_color_attachments);
            for (0..atts.num_color_views) |i| {
                const color_view = atts.color_views[i].?.native.wgpu.view;
                const resolve_view: ?sdk.TextureView = if (atts.resolve_views[i]) |view| view.native.wgpu.view else null;
                initColorAtt(&color_atts[i], &pass.action.colors[i], color_view, resolve_view);
            }
            pass_desc.color_attachment_count = atts.num_color_views;
            pass_desc.color_attachments = &color_atts[0];
            if (atts.ds_view) |ds_view| {
                const img = ds_view.cmn.img.ref.get();
                initDsAtt(&ds_att, &pass.action, img.cmn.pixel_format, ds_view.native.wgpu.view);
                pass_desc.depth_stencil_attachment = &ds_att;
            }
        } else {
            const swapchain = &pass.swapchain.wgpu;
            initColorAtt(&color_atts[0], &pass.action.colors[0], fromOpaqueOrNull(sdk.TextureView, swapchain.render_view), fromOpaqueOrNull(sdk.TextureView, swapchain.resolve_view));
            pass_desc.color_attachment_count = 1;
            pass_desc.color_attachments = &color_atts[0];
            if (fromOpaqueOrNull(sdk.TextureView, swapchain.depth_stencil_view)) |depth_view| {
                initDsAtt(&ds_att, &pass.action, pass.swapchain.depth_format, depth_view);
                pass_desc.depth_stencil_attachment = &ds_att;
            }
        }
        self.rpass_enc = self.procs.wgpuCommandEncoderBeginRenderPass(self.cmd_enc.?, &pass_desc);
        std.debug.assert(self.rpass_enc != null);
        self.procs.wgpuRenderPassEncoderSetBindGroup(self.rpass_enc.?, ub_bindgroup_index, null, 0, null);
        self.procs.wgpuRenderPassEncoderSetBindGroup(self.rpass_enc.?, view_smp_bindgroup_index, null, 0, null);
        core.statsInc("wgpu.bindings.num_set_bindgroup");
    }

    pub fn beginPass(self: *Backend, pass: *const t.Pass, atts: *const core.AttachmentsPtrs) bool {
        self.acquireCommandEncoder();
        self.bindings_cache = .{};
        if (pass.compute) {
            self.beginComputePass(pass);
        } else {
            self.beginRenderPass(pass, atts);
        }
        return true;
    }

    pub fn endPass(self: *Backend, atts: *const core.AttachmentsPtrs) void {
        _ = atts;
        if (self.rpass_enc) |enc| {
            self.procs.wgpuRenderPassEncoderEnd(enc);
            self.procs.wgpuRenderPassEncoderRelease(enc);
            self.rpass_enc = null;
        }
        if (self.cpass_enc) |enc| {
            self.procs.wgpuComputePassEncoderEnd(enc);
            self.procs.wgpuComputePassEncoderRelease(enc);
            self.cpass_enc = null;
        }
    }

    pub fn commit(self: *Backend) void {
        const enc = self.cmd_enc orelse return; // no valid pass in this frame
        self.uniformSystemOnCommit();
        const cmd_buf_desc: sdk.CommandBufferDescriptor = .{};
        const cmd_buf: ?sdk.CommandBuffer = self.procs.wgpuCommandEncoderFinish(enc, &cmd_buf_desc);
        std.debug.assert(cmd_buf != null);
        self.procs.wgpuCommandEncoderRelease(enc);
        self.cmd_enc = null;
        self.procs.wgpuQueueSubmit(self.queue_handle, 1, &cmd_buf);
        self.procs.wgpuCommandBufferRelease(cmd_buf.?);
    }

    pub fn applyViewport(self: *Backend, x: i32, y: i32, w: i32, h: i32, origin_top_left: bool) void {
        const height = core.state().cur_pass.dim.height;
        const yf: i32 = if (origin_top_left) y else height - (y + h);
        self.procs.wgpuRenderPassEncoderSetViewport(self.rpass_enc.?, @floatFromInt(x), @floatFromInt(yf), @floatFromInt(w), @floatFromInt(h), 0.0, 1.0);
    }

    pub fn applyScissorRect(self: *Backend, x: i32, y: i32, w: i32, h: i32, origin_top_left: bool) void {
        const dim = core.state().cur_pass.dim;
        const clip = core.clipRect(x, y, w, h, dim.width, dim.height);
        const sy: i32 = if (origin_top_left) clip.y else dim.height - (clip.y + clip.h);
        self.procs.wgpuRenderPassEncoderSetScissorRect(self.rpass_enc.?, @intCast(clip.x), @intCast(sy), @intCast(clip.w), @intCast(clip.h));
    }

    pub fn applyPipeline(self: *Backend, pip: *core.Pipeline) void {
        self.uniform.dirty = false;
        if (pip.cmn.is_compute) {
            std.debug.assert(core.state().cur_pass.is_compute);
            self.procs.wgpuComputePassEncoderSetPipeline(self.cpass_enc.?, pip.native.wgpu.cpip.?);
        } else {
            std.debug.assert(!core.state().cur_pass.is_compute);
            self.procs.wgpuRenderPassEncoderSetPipeline(self.rpass_enc.?, pip.native.wgpu.rpip.?);
            self.procs.wgpuRenderPassEncoderSetBlendConstant(self.rpass_enc.?, &pip.native.wgpu.blend_color);
            self.procs.wgpuRenderPassEncoderSetStencilReference(self.rpass_enc.?, pip.cmn.stencil.ref);
        }
    }

    pub fn applyUniforms(self: *Backend, ub_slot: usize, data: *const t.Range) void {
        const alignment = self.limits.min_uniform_buffer_offset_alignment;
        std.debug.assert(ub_slot < max_ub_bindgroup_entries);
        std.debug.assert(self.uniform.offset + data.size <= self.uniform.num_bytes);
        std.debug.assert((self.uniform.offset & (alignment - 1)) == 0);
        std.debug.assert(data.size <= max_uniform_update_size);
        core.statsInc("wgpu.uniforms.num_set_bindgroup");
        const src: [*]const u8 = @ptrCast(data.ptr.?);
        const start = self.uniform.offset;
        @memcpy(self.uniform.staging[start..][0..data.size], src[0..data.size]);
        self.uniform.bind_offsets[ub_slot] = start;
        self.uniform.offset = roundupPow2(u32, start + @as(u32, @intCast(data.size)), alignment);
        self.uniform.dirty = true;
    }

    pub fn draw(self: *Backend, base_element: i32, num_elements: i32, num_instances: i32, base_vertex: i32, base_instance: i32) void {
        if (self.uniform.dirty) self.uniformSystemSetBindgroup();
        if (core.state().use_indexed_draw) {
            self.procs.wgpuRenderPassEncoderDrawIndexed(self.rpass_enc.?, @intCast(num_elements), @intCast(num_instances), @intCast(base_element), base_vertex, @intCast(base_instance));
        } else {
            self.procs.wgpuRenderPassEncoderDraw(self.rpass_enc.?, @intCast(num_elements), @intCast(num_instances), @intCast(base_element), @intCast(base_instance));
        }
    }

    pub fn dispatch(self: *Backend, num_groups_x: i32, num_groups_y: i32, num_groups_z: i32) void {
        if (self.uniform.dirty) self.uniformSystemSetBindgroup();
        self.procs.wgpuComputePassEncoderDispatchWorkgroups(self.cpass_enc.?, @intCast(num_groups_x), @intCast(num_groups_y), @intCast(num_groups_z));
    }

    // ------------------------------------------------------------ data transfer

    /// Writes into the GPU buffer, or into the CPU staging buffer of a staging buffer (_sg_wgpu_copy_buffer_data).
    fn copyBufferData(self: *Backend, buf: *core.Buffer, dst_offset: usize, src_ptr: [*]const u8, src_offset: usize, copy_size: usize) void {
        const res = &buf.native.wgpu;
        if (buf.cmn.usage.staging_buffer or buf.cmn.usage.staging_index_buffer) {
            const staging = res.staging.?;
            @memcpy(staging[dst_offset..][0..copy_size], src_ptr[src_offset..][0..copy_size]);
        } else {
            // WebGPU's write-buffer requires the size to be a multiple of four, so the copy may be split
            const clamped_size = copy_size & ~@as(usize, 3);
            const extra_size = copy_size & 3;
            self.procs.wgpuQueueWriteBuffer(self.queue_handle, res.buf, dst_offset, @ptrCast(src_ptr + src_offset), clamped_size);
            if (extra_size > 0) {
                var extra_data = [4]u8{ 0, 0, 0, 0 };
                @memcpy(extra_data[0..extra_size], (src_ptr + src_offset + clamped_size)[0..extra_size]);
                self.procs.wgpuQueueWriteBuffer(self.queue_handle, res.buf, dst_offset + clamped_size, &extra_data, 4);
            }
        }
    }

    fn writeMiplevelData(self: *Backend, img: *core.Image, src: [*]const u8, src_size: usize, src_offset: usize, src_bytes_per_row: i32, src_bytes_per_slice: i32, mip_level: i32, x: i32, y: i32, slice: i32, width: i32, height: i32, num_slices: i32) void {
        std.debug.assert(src_bytes_per_row > 0 and src_bytes_per_slice > 0);
        std.debug.assert(mip_level >= 0 and mip_level < img.cmn.num_mipmaps);
        std.debug.assert(width > 0 and height > 0 and num_slices > 0);
        const block_dim = formats.blockDimension(img.cmn.pixel_format);
        const layout: sdk.TexelCopyBufferLayout = .{
            .offset = src_offset,
            .bytes_per_row = @intCast(src_bytes_per_row),
            .rows_per_image = @intCast(@divTrunc(src_bytes_per_slice, src_bytes_per_row)),
        };
        const copy_tex: sdk.TexelCopyTextureInfo = .{
            .texture = img.native.wgpu.tex,
            .mip_level = @intCast(mip_level),
            .origin = .{ .x = @intCast(x), .y = @intCast(y), .z = @intCast(slice) },
            .aspect = .all,
        };
        const extent: sdk.Extent3D = .{
            .width = @intCast(roundupPow2(i32, width, block_dim)),
            .height = @intCast(roundupPow2(i32, height, block_dim)),
            .depth_or_array_layers = @intCast(num_slices),
        };
        self.procs.wgpuQueueWriteTexture(self.queue_handle, &copy_tex, @ptrCast(src), src_size, &layout, &extent);
    }

    fn copyImageData(self: *Backend, img: *core.Image, data: *const t.ImageData) void {
        for (0..@intCast(img.cmn.num_mipmaps)) |mip| {
            const mip_level: i32 = @intCast(mip);
            const mip_width = core.miplevelDim(img.cmn.width, mip_level);
            const mip_height = core.miplevelDim(img.cmn.height, mip_level);
            const mip_depth_or_slices = if (img.cmn.type == .@"3d") core.miplevelDim(img.cmn.num_slices, mip_level) else img.cmn.num_slices;
            const bytes_per_row = formats.rowPitch(img.cmn.pixel_format, mip_width, 1);
            const bytes_per_slice = formats.surfacePitch(img.cmn.pixel_format, mip_width, mip_height, 1);
            const range = data.mip_levels[mip];
            self.writeMiplevelData(img, bytesOf(range.ptr), range.size, 0, bytes_per_row, bytes_per_slice, mip_level, 0, 0, 0, mip_width, mip_height, mip_depth_or_slices);
        }
    }

    pub fn writeBufferTransient(self: *Backend, buf: *core.Buffer, desc: *const t.WriteBufferDesc, first_time_in_frame: bool) void {
        _ = first_time_in_frame;
        self.copyBufferData(buf, desc.dst.offset, bytesOf(desc.src.data.ptr), desc.src.offset, desc.size);
    }

    pub fn writeImageTransient(self: *Backend, img: *core.Image, desc: *const t.WriteImageDesc, first_time_in_frame: bool) void {
        _ = first_time_in_frame;
        self.writeImage(img, desc);
    }

    pub fn writeBufferUnsealed(self: *Backend, buf: *core.Buffer, desc: *const t.WriteBufferDesc) void {
        _ = self;
        const mapped = buf.native.wgpu.mapped_ptr orelse unreachable;
        std.debug.assert((desc.dst.offset + desc.size) <= buf.cmn.size);
        const src = bytesOf(desc.src.data.ptr) + desc.src.offset;
        @memcpy(mapped[desc.dst.offset..][0..desc.size], src[0..desc.size]);
    }

    pub fn writeImageUnsealed(self: *Backend, img: *core.Image, desc: *const t.WriteImageDesc) void {
        self.writeImage(img, desc);
    }

    fn writeImage(self: *Backend, img: *core.Image, desc: *const t.WriteImageDesc) void {
        self.writeMiplevelData(img, bytesOf(desc.src.data.ptr), desc.src.data.size, desc.src.offset, desc.src.bytes_per_row, desc.src.bytes_per_slice, desc.dst.mip_level, desc.dst.x, desc.dst.y, desc.dst.slice, desc.size.width, desc.size.height, desc.size.num_slices);
    }

    pub fn copyBufferToBuffer(self: *Backend, src: *core.Buffer, dst: *core.Buffer, desc: *const t.CopyBufferToBufferDesc) void {
        std.debug.assert(src.cmn.usage.copy_src and dst.cmn.usage.copy_dst);
        if (src.cmn.usage.staging_buffer or src.cmn.usage.staging_index_buffer) {
            self.copyBufferData(dst, desc.dst.offset, src.native.wgpu.staging.?.ptr, desc.src.offset, desc.size);
        } else {
            self.acquireCommandEncoder();
            const wgpu_size = roundupPow2(u64, @intCast(desc.size), 4);
            self.procs.wgpuCommandEncoderCopyBufferToBuffer(self.cmd_enc.?, src.native.wgpu.buf, desc.src.offset, dst.native.wgpu.buf, desc.dst.offset, wgpu_size);
        }
    }

    pub fn copyBufferToImage(self: *Backend, src: *core.Buffer, dst: *core.Image, desc: *const t.CopyBufferToImageDesc) void {
        std.debug.assert(src.cmn.usage.copy_src and dst.cmn.usage.copy_dst);
        if (src.cmn.usage.staging_buffer) {
            self.writeMiplevelData(dst, src.native.wgpu.staging.?.ptr, src.cmn.size, desc.src.offset, desc.src.bytes_per_row, desc.src.bytes_per_slice, desc.dst.mip_level, desc.dst.x, desc.dst.y, desc.dst.slice, desc.size.width, desc.size.height, desc.size.num_slices);
        } else {
            self.acquireCommandEncoder();
            const block_dim = formats.blockDimension(dst.cmn.pixel_format);
            const src_info: sdk.TexelCopyBufferInfo = .{
                .layout = .{
                    .offset = desc.src.offset,
                    .bytes_per_row = @intCast(desc.src.bytes_per_row),
                    .rows_per_image = @intCast(@divTrunc(desc.src.bytes_per_slice, desc.src.bytes_per_row)),
                },
                .buffer = src.native.wgpu.buf,
            };
            const dst_info: sdk.TexelCopyTextureInfo = .{
                .texture = dst.native.wgpu.tex,
                .mip_level = @intCast(desc.dst.mip_level),
                .origin = .{ .x = @intCast(desc.dst.x), .y = @intCast(desc.dst.y), .z = @intCast(desc.dst.slice) },
                .aspect = .all,
            };
            const copy_size: sdk.Extent3D = .{
                .width = @intCast(roundupPow2(i32, desc.size.width, block_dim)),
                .height = @intCast(roundupPow2(i32, desc.size.height, block_dim)),
                .depth_or_array_layers = @intCast(desc.size.num_slices),
            };
            self.procs.wgpuCommandEncoderCopyBufferToTexture(self.cmd_enc.?, &src_info, &dst_info, &copy_size);
        }
    }

    // ------------------------------------------------------------ debugging

    pub fn pushDebugGroup(self: *Backend, name: [*:0]const u8) void {
        // WebGPU debug groups are not used by sokol-gfx (see _sg_push_debug_group)
        _ = .{ self, name };
    }

    /// Readback (zicr extension): waits for committed GPU work, copies buffer bytes into `out`.
    pub fn requestBufferRead(self: *Backend, buf: *core.Buffer, offset: usize, out: []u8) ?*PendingRead {
        const res = switch (buf.native) {
            .wgpu => |*value| value,
            else => return null,
        };
        if (res.staging != null) return null;
        const gpu_buf = res.buf orelse return null;
        // copies need 4-byte aligned offsets and sizes: copy an aligned superset and slice it
        const start = offset & ~@as(usize, 3);
        const end = std.mem.alignForward(usize, offset + out.len, 4);
        const readback = self.createReadback(end - start) orelse return null;
        const pending = self.newPending(readback, end - start, out) orelse {
            self.procs.wgpuBufferRelease(readback);
            return null;
        };
        var submitted = false;
        defer if (!submitted) {
            pending.data = &.{};
            pending.release();
        };
        const enc = self.procs.wgpuDeviceCreateCommandEncoder(self.dev, null) orelse return null;
        defer self.procs.wgpuCommandEncoderRelease(enc);
        self.procs.wgpuCommandEncoderCopyBufferToBuffer(enc, gpu_buf, start, readback, 0, end - start);
        if (!self.submitEncoder(enc)) return null;
        pending.offset = offset - start;
        submitted = true;
        pending.tracked = true;
        _ = pending.refs.fetchAdd(1, .monotonic);
        self.readbacks.appendAssumeCapacity(pending);
        pending.start();
        return pending;
    }

    /// Readback (zicr extension): waits for committed GPU work, copies an image region into `out`.
    /// The copy uses 256-byte aligned rows and the rows are repacked into the caller's pitches.
    pub fn requestImageRead(self: *Backend, img: *core.Image, region: *const core.ReadRegion, out: []u8) ?*PendingRead {
        const tex = switch (img.native) {
            .wgpu => |value| value.tex orelse return null,
            else => return null,
        };
        const bpp: usize = @intCast(formats.pixelSize(img.cmn.pixel_format));
        const row_bytes = @as(usize, region.width) * bpp;
        const aligned_row = std.mem.alignForward(usize, row_bytes, 256);
        const slice_bytes = aligned_row * region.height;
        const total = slice_bytes * region.num_slices;
        const readback = self.createReadback(total) orelse return null;
        const pending = self.newPending(readback, total, out) orelse {
            self.procs.wgpuBufferRelease(readback);
            return null;
        };
        var submitted = false;
        defer if (!submitted) {
            pending.data = &.{};
            pending.release();
        };
        const enc = self.procs.wgpuDeviceCreateCommandEncoder(self.dev, null) orelse return null;
        defer self.procs.wgpuCommandEncoderRelease(enc);
        const src: sdk.TexelCopyTextureInfo = .{
            .texture = tex,
            .mip_level = region.mip_level,
            .origin = .{ .x = region.x, .y = region.y, .z = region.slice },
            .aspect = .all,
        };
        const dst: sdk.TexelCopyBufferInfo = .{
            .layout = .{ .offset = 0, .bytes_per_row = @intCast(aligned_row), .rows_per_image = region.height },
            .buffer = readback,
        };
        const extent: sdk.Extent3D = .{ .width = region.width, .height = region.height, .depth_or_array_layers = region.num_slices };
        self.procs.wgpuCommandEncoderCopyTextureToBuffer(enc, &src, &dst, &extent);
        if (!self.submitEncoder(enc)) return null;
        pending.row_bytes = row_bytes;
        pending.source_row = aligned_row;
        pending.source_slice = slice_bytes;
        pending.target_row = region.bytes_per_row;
        pending.target_slice = region.bytes_per_slice;
        pending.rows = region.height;
        pending.slices = region.num_slices;
        submitted = true;
        pending.tracked = true;
        _ = pending.refs.fetchAdd(1, .monotonic);
        self.readbacks.appendAssumeCapacity(pending);
        pending.start();
        return pending;
    }

    fn collectReadbacks(self: *Backend, wait: bool) void {
        var i: usize = 0;
        while (i < self.readbacks.items.len) {
            const pending = self.readbacks.items[i];
            if (wait and !pending.callback_finished.load(.acquire)) {
                // Unmap cancels an outstanding mapping, including on device loss.
                self.procs.wgpuBufferUnmap(pending.buffer);
                if (comptime @import("builtin").cpu.arch.isWasm()) {
                    // JS callbacks cannot run until we return. The promise owns
                    // the wasm instance and imports until its callback completes.
                    pending.tracked = false;
                } else {
                    while (!pending.callback_finished.load(.acquire)) {
                        _ = self.pumpFuture(pending.future, false);
                        std.atomic.spinLoopHint();
                    }
                }
            } else if (!pending.callback_finished.load(.acquire)) {
                i += 1;
                continue;
            }
            pending.release();
            _ = self.readbacks.swapRemove(i);
        }
    }

    fn newPending(self: *Backend, buffer: sdk.Buffer, size: usize, out: []u8) ?*PendingRead {
        self.collectReadbacks(false);
        self.readbacks.ensureUnusedCapacity(self.allocator, 1) catch return null;
        const pending = self.allocator.create(PendingRead) catch return null;
        pending.* = .{ .allocator = self.allocator, .procs = self.procs, .device = self.dev, .device_poll = self.device_poll, .instance = self.instance, .wait_any = self.wait_any, .wait_timeout_ns = self.wait_timeout_ns, .buffer = buffer, .mapped_size = size, .data = out };
        return pending;
    }

    pub fn readBuffer(self: *Backend, buf: *core.Buffer, offset: usize, out: []u8) bool {
        if (buf.native.wgpu.staging) |data| {
            @memcpy(out, data[offset..][0..out.len]);
            return true;
        }
        if (comptime @import("builtin").cpu.arch.isWasm()) return false;
        const pending = self.requestBufferRead(buf, offset, out) orelse return false;
        pending.owns_data = false;
        return waitRead(pending);
    }

    pub fn readImage(self: *Backend, img: *core.Image, region: *const core.ReadRegion, out: []u8) bool {
        if (comptime @import("builtin").cpu.arch.isWasm()) return false;
        const pending = self.requestImageRead(img, region, out) orelse return false;
        pending.owns_data = false;
        return waitRead(pending);
    }

    fn waitRead(pending: *PendingRead) bool {
        defer pending.release();
        for (0..max_map_spins) |_| {
            // poll writes directly into the borrowed output, preserving image
            // padding. A late callback only publishes status; retirement never
            // polls/copies after this blocking caller has returned.
            if (pending.poll() catch return false) |_| return true;
            if (pending.device_poll) |poll| {
                _ = poll(pending.device, 1, null);
            } else if (pending.wait_any) |wait_any| {
                if (pending.wait_timeout_ns == 0) return false;
                var info: sdk.FutureWaitInfo = .{ .future = pending.future };
                if (wait_any(pending.instance, 1, @ptrCast(&info), pending.wait_timeout_ns) == 3) return false;
            } else return false;
        }
        // The callback still owns the pending state after a timeout.
        return false;
    }

    fn createReadback(self: *Backend, size: usize) ?sdk.Buffer {
        return self.procs.wgpuDeviceCreateBuffer(self.dev, &sdk.BufferDescriptor{
            .usage = sdk.BufferUsage.map_read | sdk.BufferUsage.copy_dst,
            .size = size,
        });
    }

    fn submitEncoder(self: *Backend, enc: sdk.CommandEncoder) bool {
        const cmd = self.procs.wgpuCommandEncoderFinish(enc, null) orelse return false;
        defer self.procs.wgpuCommandBufferRelease(cmd);
        const cmds = [_]?sdk.CommandBuffer{cmd};
        self.procs.wgpuQueueSubmit(self.queue_handle, 1, &cmds[0]);
        return true;
    }

    pub fn popDebugGroup(self: *Backend) void {
        _ = self;
    }

    // ------------------------------------------------------------ native object access

    pub fn device(self: *const Backend) ?*const anyopaque {
        return toOpaque(self.dev);
    }
    pub fn queue(self: *const Backend) ?*const anyopaque {
        return toOpaque(self.queue_handle);
    }
    pub fn commandEncoder(self: *const Backend) ?*const anyopaque {
        return toOpaque(self.cmd_enc);
    }
    pub fn renderPassEncoder(self: *const Backend) ?*const anyopaque {
        return toOpaque(self.rpass_enc);
    }
    pub fn computePassEncoder(self: *const Backend) ?*const anyopaque {
        return toOpaque(self.cpass_enc);
    }
};

// ---------------------------------------------------------------- pass attachments

fn initColorAtt(att: *sdk.RenderPassColorAttachment, action: *const t.ColorAttachmentAction, color_view: ?sdk.TextureView, resolve_view: ?sdk.TextureView) void {
    att.depth_slice = 0xFFFFFFFF; // WGPU_DEPTH_SLICE_UNDEFINED
    att.view = color_view;
    att.resolve_target = resolve_view;
    att.load_op = convert.loadOp(color_view, action.load_action);
    att.store_op = convert.storeOp(color_view, action.store_action);
    att.clear_value = .{
        .r = action.clear_value.r,
        .g = action.clear_value.g,
        .b = action.clear_value.b,
        .a = action.clear_value.a,
    };
}

fn initDsAtt(att: *sdk.RenderPassDepthStencilAttachment, action: *const t.PassAction, fmt: e.PixelFormat, view: ?sdk.TextureView) void {
    att.view = view;
    att.depth_load_op = convert.loadOp(view, action.depth.load_action);
    att.depth_store_op = convert.storeOp(view, action.depth.store_action);
    att.depth_clear_value = action.depth.clear_value;
    att.depth_read_only = 0;
    if (core.isDepthStencilFormat(fmt)) {
        att.stencil_load_op = convert.loadOp(view, action.stencil.load_action);
        att.stencil_store_op = convert.storeOp(view, action.stencil.store_action);
    } else {
        att.stencil_load_op = .undefined;
        att.stencil_store_op = .undefined;
    }
    att.stencil_clear_value = action.stencil.clear_value;
    att.stencil_read_only = 0;
}

// ---------------------------------------------------------------- helpers

fn markFormat(fmts: []t.PixelformatInfo, format: e.PixelFormat, comptime flags: []const u8) void {
    const info = &fmts[@backingInt(format)];
    inline for (flags) |flag| {
        switch (flag) {
            's' => info.sample = true,
            'f' => info.filter = true,
            'b' => info.blend = true,
            'r' => info.render = true,
            'm' => info.msaa = true,
            'd' => info.depth = true,
            'c' => {
                info.read = true;
                info.write = true;
            },
            else => unreachable,
        }
    }
}

fn bindgroupCacheItem(kind: CacheItemType, wgpu_binding: u8, id: u32, uninit_count: u32) u64 {
    // the format of cache key items is BBTCCCCCIIIIIIII (see _sg_wgpu_bindgroups_cache_key_t)
    const bb: u64 = wgpu_binding;
    const tt: u64 = @backingInt(kind) & 3;
    const cccc: u64 = uninit_count & ((1 << 22) - 1);
    const iiii: u64 = id;
    return (bb << 56) | (tt << 54) | (cccc << 32) | iiii;
}

/// MurmurHash64B, see https://github.com/aappleby/smhasher/blob/61a0530f28277f2e850bfc39600ce61d02b518de/src/MurmurHash2.cpp#L142
fn murmurHash64(bytes: []const u8, seed: u64) u64 {
    const m: u32 = 0x5bd1e995;
    const r: u5 = 24;
    var len: usize = bytes.len;
    var h1: u32 = @as(u32, @truncate(seed)) ^ @as(u32, @truncate(len));
    var h2: u32 = @truncate(seed >> 32);
    var pos: usize = 0;
    while (len >= 8) {
        var k1 = std.mem.readInt(u32, bytes[pos..][0..4], .little);
        pos += 4;
        k1 *%= m;
        k1 ^= k1 >> r;
        k1 *%= m;
        h1 *%= m;
        h1 ^= k1;
        len -= 4;
        var k2 = std.mem.readInt(u32, bytes[pos..][0..4], .little);
        pos += 4;
        k2 *%= m;
        k2 ^= k2 >> r;
        k2 *%= m;
        h2 *%= m;
        h2 ^= k2;
        len -= 4;
    }
    if (len >= 4) {
        var k1 = std.mem.readInt(u32, bytes[pos..][0..4], .little);
        pos += 4;
        k1 *%= m;
        k1 ^= k1 >> r;
        k1 *%= m;
        h1 *%= m;
        h1 ^= k1;
        len -= 4;
    }
    // tail, the cases of the original switch fall through
    if (len >= 3) h2 ^= @as(u32, bytes[pos + 2]) << 16;
    if (len >= 2) h2 ^= @as(u32, bytes[pos + 1]) << 8;
    if (len >= 1) {
        h2 ^= bytes[pos];
        h2 *%= m;
    }
    h1 ^= h2 >> 18;
    h1 *%= m;
    h2 ^= h1 >> 22;
    h2 *%= m;
    h1 ^= h2 >> 17;
    h1 *%= m;
    h2 ^= h1 >> 19;
    h2 *%= m;
    return (@as(u64, h1) << 32) | h2;
}

fn roundupPow2(comptime T: type, val: T, alignment: T) T {
    return (val + (alignment - 1)) & ~(alignment - 1);
}

fn fromOpaque(comptime T: type, ptr: *const anyopaque) T {
    return @ptrCast(@constCast(ptr));
}

fn fromOpaqueOrNull(comptime T: type, ptr: ?*const anyopaque) ?T {
    return fromOpaque(T, ptr orelse return null);
}

fn toOpaque(handle: anytype) ?*const anyopaque {
    return @ptrCast(handle);
}

fn bytesOf(ptr: ?*const anyopaque) [*]const u8 {
    return @ptrCast(ptr.?);
}

// ---------------------------------------------------------------- native object queries

pub fn queryBufferInfo(res: *const core.Buffer) t.WgpuBufferInfo {
    return .{ .buf = toOpaque(res.native.wgpu.buf) };
}

pub fn queryImageInfo(res: *const core.Image) t.WgpuImageInfo {
    return .{ .tex = toOpaque(res.native.wgpu.tex) };
}

pub fn querySamplerInfo(res: *const core.Sampler) t.WgpuSamplerInfo {
    return .{ .smp = toOpaque(res.native.wgpu.smp) };
}

pub fn queryShaderInfo(res: *const core.Shader) t.WgpuShaderInfo {
    return .{
        .vs_mod = toOpaque(res.native.wgpu.vertex_func.module),
        .fs_mod = toOpaque(res.native.wgpu.fragment_func.module),
        .bgl = toOpaque(res.native.wgpu.bgl_view_smp),
    };
}

pub fn queryPipelineInfo(res: *const core.Pipeline) t.WgpuPipelineInfo {
    return .{
        .render_pipeline = toOpaque(res.native.wgpu.rpip),
        .compute_pipeline = toOpaque(res.native.wgpu.cpip),
    };
}

pub fn queryViewInfo(res: *const core.View) t.WgpuViewInfo {
    return .{ .view = toOpaque(res.native.wgpu.view) };
}
