//! Public API, from sokol_gfx.h:26699-27409 (resource lifecycle) and
//! 27418-29545 (public functions).
const std = @import("std");
const t = @import("types.zig");
const e = @import("enums.zig");
const constants = @import("constants.zig");
const defaults = @import("defaults.zig");
const formats = @import("formats.zig");
const core = @import("core.zig");
const validation = @import("validation.zig");
const backend = @import("backend.zig");

const state = core.state;

pub const SetupError = backend.SetupError || error{ UseZigAllocator, InvalidPoolSize, InvalidListenerCapacity };

/// Initializes the global graphics context with the given backend. The
/// allocator is used for all internal allocations until shutdown().
pub fn setup(allocator: std.mem.Allocator, backend_kind: e.Backend, desc: t.Desc) SetupError!void {
    std.debug.assert(core.sg == null);
    core.sg = .{ .allocator = allocator, .desc = desc, .pools = undefined, .backend = backend_kind, .commit_listeners = &.{} };
    errdefer core.sg = null;
    try initState(&core.sg.?, allocator, backend_kind, desc);
}

/// Initializes caller-owned device state; used by the Zig Device API.
pub fn initState(s: *core.State, allocator: std.mem.Allocator, backend_kind: e.Backend, desc: t.Desc) SetupError!void {
    std.debug.assert(desc._start_canary == 0 and desc._end_canary == 0);
    if (desc.allocator.alloc_fn != null or desc.allocator.free_fn != null) return error.UseZigAllocator;
    const desc_def = defaults.desc(desc, backend_kind);
    inline for (.{ "buffer_pool_size", "image_pool_size", "sampler_pool_size", "shader_pool_size", "pipeline_pool_size", "view_pool_size" }) |name| {
        const size = @field(desc_def, name);
        if (size <= 0 or size >= @import("pool.zig").max_pool_size) return error.InvalidPoolSize;
    }
    if (desc_def.max_commit_listeners <= 0) return error.InvalidListenerCapacity;
    var pools = try core.Pools.init(allocator, &desc_def);
    errdefer pools.deinit(allocator);
    const listeners = try allocator.alloc(t.CommitListener, @intCast(desc_def.max_commit_listeners));
    errdefer allocator.free(listeners);
    @memset(listeners, .{});
    s.* = .{
        .allocator = allocator,
        .desc = desc_def,
        .pools = pools,
        .backend = backend_kind,
        .commit_listeners = listeners,
    };
    const scope = core.enter(s);
    defer scope.end();
    try backend.setup(s);
    s.desc.vulkan.pipeline_cache_data = .{}; // initialization-only borrowed bytes
    overridePortableLimits();
}

fn overridePortableLimits() void {
    const s = state();
    if (!s.desc.enforce_portable_limits) return;
    s.limits.max_color_attachments = constants.max_portable_color_attachments;
    s.limits.max_texture_bindings_per_stage = constants.max_portable_texture_bindings_per_stage;
    if (s.features.compute) {
        s.limits.max_storage_buffer_bindings_per_stage = constants.max_portable_storagebuffer_bindings_per_stage;
        s.limits.max_storage_image_bindings_per_stage = constants.max_portable_storageimage_bindings_per_stage;
    }
}

pub fn shutdown() void {
    deinitState(state());
    core.sg = null;
}

/// Releases a caller-owned State without touching the raw singleton.
pub fn deinitState(s: *core.State) void {
    const scope = core.enter(s);
    defer scope.end();
    if (s.cur_pass.in_pass) endPass();
    @import("readback_task.zig").collect(s, true);
    s.readbacks.deinit(s.allocator);
    discardAllResources();
    backend.discard();
    s.allocator.free(s.commit_listeners);
    s.pools.deinit(s.allocator);
}

/// Releases the backend objects of every live resource; only valid at shutdown
/// since free queues and slots are not reset.
fn discardAllResources() void {
    const pools = &state().pools;
    for (pools.buffers.items[1..]) |*buf| if (core.stateValidFailedUnsealed(buf.slot.state)) backend.discardBuffer(buf);
    for (pools.images.items[1..]) |*img| if (core.stateValidFailedUnsealed(img.slot.state)) backend.discardImage(img);
    for (pools.samplers.items[1..]) |*smp| if (core.stateValidFailed(smp.slot.state)) backend.discardSampler(smp);
    for (pools.shaders.items[1..]) |*shd| if (core.stateValidFailed(shd.slot.state)) backend.discardShader(shd);
    for (pools.pipelines.items[1..]) |*pip| if (core.stateValidFailed(pip.slot.state)) backend.discardPipeline(pip);
    for (pools.views.items[1..]) |*view| if (core.stateValidFailed(view.slot.state)) backend.discardView(view);
}

pub fn isValid() bool {
    return core.current() != null;
}
pub fn queryDesc() t.Desc {
    return state().desc;
}
pub fn queryBackend() e.Backend {
    return state().backend;
}
pub fn queryFeatures() t.Features {
    return state().features;
}
pub fn queryLimits() t.Limits {
    return state().limits;
}

pub fn queryPixelformat(fmt: e.PixelFormat) t.PixelformatInfo {
    const index = @backingInt(fmt);
    std.debug.assert(index > @backingInt(e.PixelFormat.none) and index < core.num_pixel_formats);
    var res = state().formats[index];
    res.compressed = formats.isCompressed(fmt);
    res.bytes_per_pixel = if (res.compressed) 0 else formats.pixelSize(fmt);
    return res;
}

fn isPow2(val: i32) bool {
    return val > 0 and (val & (val - 1)) == 0;
}

pub fn queryRowPitch(fmt: e.PixelFormat, width: i32, row_align_bytes: i32) i32 {
    _ = state();
    std.debug.assert(width > 0 and isPow2(row_align_bytes));
    std.debug.assert(@backingInt(fmt) > @backingInt(e.PixelFormat.none) and @backingInt(fmt) < core.num_pixel_formats);
    return formats.rowPitch(fmt, width, row_align_bytes);
}

pub fn querySurfacePitch(fmt: e.PixelFormat, width: i32, height: i32, row_align_bytes: i32) i32 {
    _ = state();
    std.debug.assert(width > 0 and height > 0 and isPow2(row_align_bytes));
    std.debug.assert(@backingInt(fmt) > @backingInt(e.PixelFormat.none) and @backingInt(fmt) < core.num_pixel_formats);
    return formats.surfacePitch(fmt, width, height, row_align_bytes);
}

pub fn queryPassState() e.PassState {
    const pass = &state().cur_pass;
    if (!pass.in_pass) return .none;
    return if (pass.is_compute) .compute else .render;
}

pub fn queryStats() t.Stats {
    const s = state();
    inline for (.{ "buffers", "images", "views", "samplers", "shaders", "pipelines" }) |name| {
        @field(s.stats.total, name).alive = @field(s.pools, name).numAlive();
        @field(s.stats.total, name).free = @field(s.pools, name).numFree();
    }
    backend.collectStats(&s.stats.cur_frame);
    return s.stats;
}

pub fn installTraceHooks(hooks: t.TraceHooks) t.TraceHooks {
    const s = state();
    const old_hooks = s.hooks;
    s.hooks = hooks;
    return old_hooks;
}

// ---------------------------------------------------------------- resource lifecycle

const Kind = enum { buffer, image, sampler, shader, pipeline, view };

fn Handle(comptime kind: Kind) type {
    return switch (kind) {
        .buffer => t.Buffer,
        .image => t.Image,
        .sampler => t.Sampler,
        .shader => t.Shader,
        .pipeline => t.Pipeline,
        .view => t.View,
    };
}
fn Desc(comptime kind: Kind) type {
    return switch (kind) {
        .buffer => t.BufferDesc,
        .image => t.ImageDesc,
        .sampler => t.SamplerDesc,
        .shader => t.ShaderDesc,
        .pipeline => t.PipelineDesc,
        .view => t.ViewDesc,
    };
}
fn Res(comptime kind: Kind) type {
    return switch (kind) {
        .buffer => core.Buffer,
        .image => core.Image,
        .sampler => core.Sampler,
        .shader => core.Shader,
        .pipeline => core.Pipeline,
        .view => core.View,
    };
}
fn plural(comptime kind: Kind) []const u8 {
    return @tagName(kind) ++ "s";
}
fn item(comptime kind: Kind, comptime prefix: []const u8, comptime suffix: []const u8) e.LogItem {
    return @field(e.LogItem, prefix ++ @tagName(kind) ++ suffix);
}
/// Buffers and images may additionally be in the unsealed state.
fn initedState(comptime kind: Kind, s: e.ResourceState) bool {
    return if (kind == .buffer or kind == .image) core.stateValidFailedUnsealed(s) else core.stateValidFailed(s);
}

fn pool(comptime kind: Kind) *core.Pool(Res(kind)) {
    return &@field(state().pools, plural(kind));
}

fn lookup(comptime kind: Kind, id: u32) ?*Res(kind) {
    return pool(kind).lookup(id);
}

fn descDefaults(comptime kind: Kind, desc: Desc(kind)) Desc(kind) {
    const env = state().desc.environment.defaults;
    return switch (kind) {
        .buffer => defaults.buffer(desc),
        .image => defaults.image(desc, env),
        .sampler => defaults.sampler(desc),
        .shader => defaults.shader(desc, state().backend),
        .pipeline => defaults.pipeline(desc, env),
        .view => desc,
    };
}

fn allocResource(comptime kind: Kind) Handle(kind) {
    if (pool(kind).alloc()) |id| {
        core.resourceStatsInc(plural(kind), "allocated");
        return .{ .id = id };
    }
    core.logError(item(kind, "", "_pool_exhausted"));
    return .{};
}

fn deallocResource(comptime kind: Kind, res: *Res(kind)) void {
    std.debug.assert(res.slot.state == .alloc and res.slot.id != 0);
    pool(kind).free(res);
    core.resourceStatsInc(plural(kind), "deallocated");
}

fn initResource(comptime kind: Kind, res: *Res(kind), desc: *const Desc(kind)) void {
    std.debug.assert(res.slot.state == .alloc);
    switch (kind) {
        .buffer => {
            if (validation.bufferDesc(desc)) {
                core.bufferCommonInit(&res.cmn, desc);
                res.desc = core.retainedDesc(desc.*);
                var res_state = backend.createBuffer(res, desc);
                if (desc.usage.write_unsealed and res_state == .valid) res_state = .unsealed;
                res.slot.state = res_state;
            } else res.slot.state = .failed;
        },
        .image => {
            if (validation.imageDesc(desc)) {
                core.imageCommonInit(&res.cmn, desc);
                res.desc = core.retainedDesc(desc.*);
                var res_state = backend.createImage(res, desc);
                if (desc.usage.write_unsealed and res_state == .valid) res_state = .unsealed;
                res.slot.state = res_state;
            } else res.slot.state = .failed;
        },
        .sampler => {
            if (validation.samplerDesc(desc)) {
                core.samplerCommonInit(&res.cmn, desc);
                res.desc = core.retainedDesc(desc.*);
                res.slot.state = backend.createSampler(res, desc);
            } else res.slot.state = .failed;
        },
        .shader => {
            // NOTE: a failed shader validation doesn't count as 'inited', like the original
            if (!validation.shaderDesc(desc) or !validation.shaderBindingLimits(desc)) {
                res.slot.state = .failed;
                return;
            }
            core.shaderCommonInit(&res.cmn, desc);
            res.desc = core.retainedDesc(desc.*);
            res.slot.state = backend.createShader(res, desc);
        },
        .pipeline => {
            res.slot.state = .failed;
            if (validation.pipelineDesc(desc)) {
                if (core.lookupShader(desc.shader.id)) |shd| if (shd.slot.state == .valid) {
                    core.pipelineCommonInit(&res.cmn, desc, shd);
                    res.desc = core.retainedDesc(desc.*);
                    res.slot.state = backend.createPipeline(res, desc);
                };
            }
        },
        .view => {
            res.slot.state = .failed;
            if (validation.viewDesc(desc)) {
                const buf = core.lookupBuffer(desc.storage_buffer.buffer.id);
                const img = core.lookupImage(viewImageId(desc));
                const res_state: e.ResourceState = if (buf) |b| b.slot.state else if (img) |i| i.slot.state else .invalid;
                if (core.stateValidUnsealed(res_state)) {
                    core.viewCommonInit(&res.cmn, desc, buf, img);
                    res.desc = core.retainedDesc(desc.*);
                    if (res.cmn.type == .texture) {
                        // backends read the resolved mip and slice counts from the descriptor
                        res.desc.texture.mip_levels.count = res.cmn.img.mip_level_count;
                        res.desc.texture.slices.count = res.cmn.img.slice_count;
                    }
                    res.slot.state = backend.createView(res, desc);
                }
            }
        },
    }
    std.debug.assert(initedState(kind, res.slot.state));
    core.resourceStatsInc(plural(kind), "inited");
}

fn viewImageId(desc: *const t.ViewDesc) u32 {
    inline for (.{ "texture", "storage_image", "color_attachment", "resolve_attachment", "depth_stencil_attachment" }) |name| {
        const id = @field(desc, name).image.id;
        if (id != 0) return id;
    }
    return 0;
}

fn uninitResource(comptime kind: Kind, res: *Res(kind)) void {
    std.debug.assert(initedState(kind, res.slot.state));
    switch (kind) {
        .buffer => backend.discardBuffer(res),
        .image => backend.discardImage(res),
        .sampler => backend.discardSampler(res),
        .shader => backend.discardShader(res),
        .pipeline => backend.discardPipeline(res),
        .view => backend.discardView(res),
    }
    core.resetToAllocState(res);
    core.resourceStatsInc(plural(kind), "uninited");
}

fn Api(comptime kind: Kind) type {
    const H = Handle(kind);
    const D = Desc(kind);
    const name = @tagName(kind);
    return struct {
        fn alloc() H {
            _ = state();
            const res = allocResource(kind);
            core.trace("alloc_" ++ name, .{res});
            return res;
        }
        fn dealloc(id: H) void {
            if (lookup(kind, id.id)) |res| {
                if (res.slot.state == .alloc) deallocResource(kind, res) else core.logError(item(kind, "dealloc_", "_invalid_state"));
            }
            core.trace("dealloc_" ++ name, .{id});
        }
        fn defaultsOf(desc: D) D {
            _ = state();
            return descDefaults(kind, desc);
        }
        fn init(id: H, desc: D) void {
            const desc_def = descDefaults(kind, desc);
            if (lookup(kind, id.id)) |res| {
                if (res.slot.state == .alloc) initResource(kind, res, &desc_def) else core.logError(item(kind, "init_", "_invalid_state"));
            }
            core.trace("init_" ++ name, .{ id, &desc_def });
        }
        fn uninit(id: H) void {
            if (lookup(kind, id.id)) |res| {
                if (initedState(kind, res.slot.state)) {
                    uninitResource(kind, res);
                    std.debug.assert(res.slot.state == .alloc);
                } else if (res.slot.state != .alloc) core.logError(item(kind, "uninit_", "_invalid_state"));
            }
            core.trace("uninit_" ++ name, .{id});
        }
        fn fail(id: H) void {
            if (lookup(kind, id.id)) |res| {
                if (res.slot.state == .alloc) res.slot.state = .failed else core.logError(item(kind, "fail_", "_invalid_state"));
            }
            core.trace("fail_" ++ name, .{id});
        }
        fn queryState(id: H) e.ResourceState {
            const res = lookup(kind, id.id) orelse return .invalid;
            return res.slot.state;
        }
        fn make(desc: D) H {
            const desc_def = descDefaults(kind, desc);
            const id = allocResource(kind);
            if (id.id != 0) {
                const res = pool(kind).at(id.id);
                initResource(kind, res, &desc_def);
            }
            core.trace("make_" ++ name, .{ &desc_def, id });
            return id;
        }
        fn destroy(id: H) void {
            core.trace("destroy_" ++ name, .{id});
            const res = lookup(kind, id.id) orelse return;
            if (initedState(kind, res.slot.state)) uninitResource(kind, res);
            if (res.slot.state == .alloc) {
                deallocResource(kind, res);
                std.debug.assert(res.slot.state == .initial);
            }
        }
        fn slotInfo(id: H) t.SlotInfo {
            const res = lookup(kind, id.id) orelse return .{};
            return .{ .state = res.slot.state, .res_id = res.slot.id, .uninit_count = res.slot.uninit_count };
        }
    };
}

pub const allocBuffer = Api(.buffer).alloc;
pub const allocImage = Api(.image).alloc;
pub const allocSampler = Api(.sampler).alloc;
pub const allocShader = Api(.shader).alloc;
pub const allocPipeline = Api(.pipeline).alloc;
pub const allocView = Api(.view).alloc;
pub const deallocBuffer = Api(.buffer).dealloc;
pub const deallocImage = Api(.image).dealloc;
pub const deallocSampler = Api(.sampler).dealloc;
pub const deallocShader = Api(.shader).dealloc;
pub const deallocPipeline = Api(.pipeline).dealloc;
pub const deallocView = Api(.view).dealloc;
pub const queryBufferDefaults = Api(.buffer).defaultsOf;
pub const queryImageDefaults = Api(.image).defaultsOf;
pub const querySamplerDefaults = Api(.sampler).defaultsOf;
pub const queryShaderDefaults = Api(.shader).defaultsOf;
pub const queryPipelineDefaults = Api(.pipeline).defaultsOf;
pub const queryViewDefaults = Api(.view).defaultsOf;
pub const initBuffer = Api(.buffer).init;
pub const initImage = Api(.image).init;
pub const initSampler = Api(.sampler).init;
pub const initShader = Api(.shader).init;
pub const initPipeline = Api(.pipeline).init;
pub const initView = Api(.view).init;
pub const uninitBuffer = Api(.buffer).uninit;
pub const uninitImage = Api(.image).uninit;
pub const uninitSampler = Api(.sampler).uninit;
pub const uninitShader = Api(.shader).uninit;
pub const uninitPipeline = Api(.pipeline).uninit;
pub const uninitView = Api(.view).uninit;
pub const failBuffer = Api(.buffer).fail;
pub const failImage = Api(.image).fail;
pub const failSampler = Api(.sampler).fail;
pub const failShader = Api(.shader).fail;
pub const failPipeline = Api(.pipeline).fail;
pub const failView = Api(.view).fail;
pub const queryBufferState = Api(.buffer).queryState;
pub const queryImageState = Api(.image).queryState;
pub const querySamplerState = Api(.sampler).queryState;
pub const queryShaderState = Api(.shader).queryState;
pub const queryPipelineState = Api(.pipeline).queryState;
pub const queryViewState = Api(.view).queryState;
pub const makeBuffer = Api(.buffer).make;
pub const makeImage = Api(.image).make;
pub const makeSampler = Api(.sampler).make;
pub const makeShader = Api(.shader).make;
pub const makePipeline = Api(.pipeline).make;
pub const makeView = Api(.view).make;
pub const destroyBuffer = Api(.buffer).destroy;
pub const destroyImage = Api(.image).destroy;
pub const destroySampler = Api(.sampler).destroy;
pub const destroyShader = Api(.shader).destroy;
pub const destroyPipeline = Api(.pipeline).destroy;
pub const destroyView = Api(.view).destroy;

pub fn queryBufferInfo(buf_id: t.Buffer) t.BufferInfo {
    const buf = lookup(.buffer, buf_id.id) orelse return .{};
    // D3D11 has no multi-slot buffers
    const d3d11 = state().backend == .d3d11;
    return .{ .slot = Api(.buffer).slotInfo(buf_id), .num_slots = if (d3d11) 1 else buf.cmn.num_slots, .active_slot = if (d3d11) 0 else buf.cmn.active_slot };
}
pub fn queryImageInfo(img_id: t.Image) t.ImageInfo {
    const img = lookup(.image, img_id.id) orelse return .{};
    const d3d11 = state().backend == .d3d11;
    return .{ .slot = Api(.image).slotInfo(img_id), .num_slots = if (d3d11) 1 else img.cmn.num_slots, .active_slot = if (d3d11) 0 else img.cmn.active_slot };
}
pub fn querySamplerInfo(smp_id: t.Sampler) t.SamplerInfo {
    return .{ .slot = Api(.sampler).slotInfo(smp_id) };
}
pub fn queryShaderInfo(shd_id: t.Shader) t.ShaderInfo {
    return .{ .slot = Api(.shader).slotInfo(shd_id) };
}
pub fn queryPipelineInfo(pip_id: t.Pipeline) t.PipelineInfo {
    return .{ .slot = Api(.pipeline).slotInfo(pip_id) };
}
pub fn queryViewInfo(view_id: t.View) t.ViewInfo {
    return .{ .slot = Api(.view).slotInfo(view_id) };
}

pub fn queryBufferDesc(buf_id: t.Buffer) t.BufferDesc {
    const buf = lookup(.buffer, buf_id.id) orelse return .{};
    return .{ .size = buf.cmn.size, .usage = buf.cmn.usage };
}
pub fn queryBufferSize(buf_id: t.Buffer) usize {
    const buf = lookup(.buffer, buf_id.id) orelse return 0;
    return buf.cmn.size;
}
pub fn queryBufferUsage(buf_id: t.Buffer) t.BufferUsage {
    const buf = lookup(.buffer, buf_id.id) orelse return .{};
    return buf.cmn.usage;
}

pub fn queryImageDesc(img_id: t.Image) t.ImageDesc {
    const img = lookup(.image, img_id.id) orelse return .{};
    const cmn = &img.cmn;
    return .{
        .type = cmn.type,
        .width = cmn.width,
        .height = cmn.height,
        .num_slices = cmn.num_slices,
        .num_mipmaps = cmn.num_mipmaps,
        .usage = cmn.usage,
        .pixel_format = cmn.pixel_format,
        .sample_count = cmn.sample_count,
    };
}
pub fn queryImageType(img_id: t.Image) e.ImageType {
    const img = lookup(.image, img_id.id) orelse return .default;
    return img.cmn.type;
}
pub fn queryImageWidth(img_id: t.Image) i32 {
    const img = lookup(.image, img_id.id) orelse return 0;
    return img.cmn.width;
}
pub fn queryImageHeight(img_id: t.Image) i32 {
    const img = lookup(.image, img_id.id) orelse return 0;
    return img.cmn.height;
}
pub fn queryImageNumSlices(img_id: t.Image) i32 {
    const img = lookup(.image, img_id.id) orelse return 0;
    return img.cmn.num_slices;
}
pub fn queryImageNumMipmaps(img_id: t.Image) i32 {
    const img = lookup(.image, img_id.id) orelse return 0;
    return img.cmn.num_mipmaps;
}
pub fn queryImagePixelformat(img_id: t.Image) e.PixelFormat {
    const img = lookup(.image, img_id.id) orelse return .default;
    return img.cmn.pixel_format;
}
pub fn queryImageUsage(img_id: t.Image) t.ImageUsage {
    const img = lookup(.image, img_id.id) orelse return .{};
    return img.cmn.usage;
}
pub fn queryImageSampleCount(img_id: t.Image) i32 {
    const img = lookup(.image, img_id.id) orelse return 0;
    return img.cmn.sample_count;
}

pub fn queryViewType(view_id: t.View) e.ViewType {
    const view = lookup(.view, view_id.id) orelse return .invalid;
    return view.cmn.type;
}
/// May return an invalid handle if the view is invalid or not an image view.
pub fn queryViewImage(view_id: t.View) t.Image {
    const view = lookup(.view, view_id.id) orelse return .{};
    return .{ .id = view.cmn.img.ref.sref.id };
}
/// May return an invalid handle if the view is invalid or not a buffer view.
pub fn queryViewBuffer(view_id: t.View) t.Buffer {
    const view = lookup(.view, view_id.id) orelse return .{};
    return .{ .id = view.cmn.buf.ref.sref.id };
}

pub fn querySamplerDesc(smp_id: t.Sampler) t.SamplerDesc {
    const smp = lookup(.sampler, smp_id.id) orelse return .{};
    const cmn = &smp.cmn;
    return .{
        .min_filter = cmn.min_filter,
        .mag_filter = cmn.mag_filter,
        .mipmap_filter = cmn.mipmap_filter,
        .wrap_u = cmn.wrap_u,
        .wrap_v = cmn.wrap_v,
        .wrap_w = cmn.wrap_w,
        .min_lod = cmn.min_lod,
        .max_lod = cmn.max_lod,
        .border_color = cmn.border_color,
        .compare = cmn.compare,
        .max_anisotropy = cmn.max_anisotropy,
    };
}

pub fn queryShaderDesc(shd_id: t.Shader) t.ShaderDesc {
    var desc: t.ShaderDesc = .{};
    const shd = lookup(.shader, shd_id.id) orelse return desc;
    const cmn = &shd.cmn;
    for (&desc.uniform_blocks, cmn.uniform_blocks) |*dst, src| {
        dst.stage = src.stage;
        dst.size = src.size;
    }
    for (&desc.views, cmn.views) |*dst, src| {
        switch (src.view_type) {
            .texture => dst.texture = .{ .stage = src.stage, .image_type = src.image_type, .sample_type = src.sample_type, .multisampled = src.multisampled },
            .storagebuffer => dst.storage_buffer = .{ .stage = src.stage, .readonly = src.sbuf_readonly },
            .storageimage => dst.storage_image = .{ .stage = src.stage, .access_format = src.access_format, .image_type = src.image_type, .writeonly = src.simg_writeonly },
            else => {},
        }
    }
    for (&desc.samplers, cmn.samplers) |*dst, src| dst.* = .{ .stage = src.stage, .sampler_type = src.sampler_type };
    for (&desc.texture_sampler_pairs, cmn.texture_samplers) |*dst, src| dst.* = .{ .stage = src.stage, .view_slot = src.view_slot, .sampler_slot = src.sampler_slot };
    return desc;
}

pub fn queryPipelineDesc(pip_id: t.Pipeline) t.PipelineDesc {
    var desc: t.PipelineDesc = .{};
    const pip = lookup(.pipeline, pip_id.id) orelse return desc;
    const cmn = &pip.cmn;
    desc.compute = cmn.is_compute;
    desc.shader.id = cmn.shader.sref.id;
    desc.layout = cmn.layout;
    desc.depth = cmn.depth;
    desc.stencil = cmn.stencil;
    desc.color_count = cmn.color_count;
    for (0..@intCast(cmn.color_count)) |i| desc.colors[i] = cmn.colors[i];
    desc.primitive_type = cmn.primitive_type;
    desc.index_type = cmn.index_type;
    desc.cull_mode = cmn.cull_mode;
    desc.face_winding = cmn.face_winding;
    desc.sample_count = cmn.sample_count;
    desc.blend_color = cmn.blend_color;
    desc.alpha_to_coverage_enabled = cmn.alpha_to_coverage_enabled;
    return desc;
}

pub fn queryViewDesc(view_id: t.View) t.ViewDesc {
    var desc: t.ViewDesc = .{};
    const view = lookup(.view, view_id.id) orelse return desc;
    const img = &view.cmn.img;
    const image_view: t.ImageViewDesc = .{ .image = .{ .id = img.ref.sref.id }, .mip_level = img.mip_level, .slice = img.slice };
    switch (view.cmn.type) {
        .storagebuffer => desc.storage_buffer = .{ .buffer = .{ .id = view.cmn.buf.ref.sref.id }, .offset = view.cmn.buf.offset },
        .storageimage => desc.storage_image = image_view,
        .texture => desc.texture = .{
            .image = .{ .id = img.ref.sref.id },
            .mip_levels = .{ .base = img.mip_level, .count = img.mip_level_count },
            .slices = .{ .base = img.slice, .count = img.slice_count },
        },
        .colorattachment => desc.color_attachment = image_view,
        .resolveattachment => desc.resolve_attachment = image_view,
        .depthstencilattachment => desc.depth_stencil_attachment = image_view,
        else => unreachable,
    }
    return desc;
}

// ---------------------------------------------------------------- stats and commit listeners

pub fn enableStats() void {
    state().stats_enabled = true;
    backend.setStatsEnabled(true);
}
pub fn disableStats() void {
    state().stats_enabled = false;
    backend.setStatsEnabled(false);
}
pub fn statsEnabled() bool {
    return state().stats_enabled;
}

pub fn addCommitListener(listener: t.CommitListener) bool {
    std.debug.assert(listener.func != null);
    const s = state();
    const used = s.commit_listeners[0..s.commit_listeners_upper];
    // first check if the listener hadn't been added already
    for (used) |slot| {
        if (slot.func == listener.func and slot.user_data == listener.user_data) {
            core.logError(.identical_commit_listener);
            return false;
        }
    }
    // first try to plug a hole, then append to the end
    for (used) |*slot| {
        if (slot.func == null) {
            slot.* = listener;
            return true;
        }
    }
    if (s.commit_listeners_upper < s.commit_listeners.len) {
        s.commit_listeners[s.commit_listeners_upper] = listener;
        s.commit_listeners_upper += 1;
        return true;
    }
    core.logError(.commit_listener_array_full);
    return false;
}

pub fn removeCommitListener(listener: t.CommitListener) bool {
    std.debug.assert(listener.func != null);
    const s = state();
    for (s.commit_listeners[0..s.commit_listeners_upper]) |*slot| {
        // both the function pointer and user data must match
        if (slot.func == listener.func and slot.user_data == listener.user_data) {
            slot.* = .{};
            return true;
        }
    }
    return false;
}

fn notifyCommitListeners() void {
    const s = state();
    for (s.commit_listeners[0..s.commit_listeners_upper]) |listener| {
        if (listener.func) |func| func(listener.user_data);
    }
}

// ---------------------------------------------------------------- passes and draws

pub fn beginPass(pass: t.Pass) void {
    const s = state();
    std.debug.assert(!s.cur_pass.valid and !s.cur_pass.in_pass);
    std.debug.assert(core.attachmentsEmpty(&s.cur_pass.atts));
    std.debug.assert(pass._start_canary == 0 and pass._end_canary == 0);
    s.cur_pass.in_pass = true;
    const pass_def = defaults.pass(pass, s.desc.environment.defaults);
    core.trace("begin_pass", .{&pass_def});
    if (!validation.passAttachmentLimits(&pass_def)) return;
    if (!validation.beginPass(&pass_def)) return;
    const atts = core.attachmentsPtrs(&pass_def.attachments);
    if (!atts.empty) {
        if (!core.attachmentsAlive(&atts)) {
            core.logError(.beginpass_attachments_alive);
            return;
        }
        s.cur_pass.atts = pass.attachments;
        s.cur_pass.dim = core.attachmentsDim(&atts);
    } else if (!pass_def.compute) {
        // a swapchain pass; all values may be zero if the swapchain is invalid
        s.cur_pass.swapchain = .{
            .invalid = pass_def.swapchain.invalid,
            .color_fmt = pass_def.swapchain.color_format,
            .depth_fmt = pass_def.swapchain.depth_format,
            .sample_count = pass_def.swapchain.sample_count,
        };
        s.cur_pass.dim = .{ .width = pass_def.swapchain.width, .height = pass_def.swapchain.height };
    }
    s.cur_pass.action = pass_def.action;
    s.cur_pass.valid = true; // may be overruled by the backend
    s.cur_pass.is_compute = pass_def.compute;
    if (s.cur_pass.swapchain.invalid) {
        s.cur_pass.valid = false;
        return;
    }
    s.cur_pass.valid = backend.beginPass(&pass_def, &atts);
}

pub fn applyViewport(x: i32, y: i32, width: i32, height: i32, origin_top_left: bool) void {
    core.statsInc("num_apply_viewport");
    core.trace("apply_viewport", .{ x, y, width, height, origin_top_left });
    if (!state().cur_pass.valid) return;
    if (!validation.applyViewport()) return;
    backend.applyViewport(x, y, width, height, origin_top_left);
}

pub fn applyViewportf(x: f32, y: f32, width: f32, height: f32, origin_top_left: bool) void {
    applyViewport(@intFromFloat(x), @intFromFloat(y), @intFromFloat(width), @intFromFloat(height), origin_top_left);
}

pub fn applyScissorRect(x: i32, y: i32, width: i32, height: i32, origin_top_left: bool) void {
    core.statsInc("num_apply_scissor_rect");
    core.trace("apply_scissor_rect", .{ x, y, width, height, origin_top_left });
    if (!state().cur_pass.valid) return;
    if (!validation.applyScissorRect()) return;
    backend.applyScissorRect(x, y, width, height, origin_top_left);
}

pub fn applyScissorRectf(x: f32, y: f32, width: f32, height: f32, origin_top_left: bool) void {
    applyScissorRect(@intFromFloat(x), @intFromFloat(y), @intFromFloat(width), @intFromFloat(height), origin_top_left);
}

pub fn applyPipeline(pip_id: t.Pipeline) void {
    const s = state();
    core.statsInc("num_apply_pipeline");
    core.trace("apply_pipeline", .{pip_id});
    if (!s.cur_pass.valid) return;
    if (!validation.applyPipeline(pip_id)) {
        s.next_draw_valid = false;
        return;
    }
    const pip = core.lookupPipeline(pip_id.id) orelse {
        // only reachable with validation disabled
        s.next_draw_valid = false;
        return;
    };
    s.cur_pip = .init(pip);
    s.next_draw_valid = pip.slot.state == .valid;
    if (!s.next_draw_valid) return;
    s.use_indexed_draw = pip.cmn.index_type != .none;
    s.use_instanced_draw = pip.cmn.use_instanced_draw;
    backend.applyPipeline(pip);
}

pub fn applyBindings(bindings: t.Bindings) void {
    const s = state();
    core.statsInc("num_apply_bindings");
    core.trace("apply_bindings", .{&bindings});
    if (!s.cur_pass.valid) return;
    if (!validation.applyBindings(&bindings)) s.next_draw_valid = false;
    std.debug.assert(bindings._start_canary == 0 and bindings._end_canary == 0);
    if (!s.cur_pip.alive()) s.next_draw_valid = false;
    if (!s.next_draw_valid) return;

    var bnd: core.BindingsPtrs = .{ .pip = s.cur_pip.get() };
    const shd = bnd.pip.cmn.shader.get();
    if (!s.cur_pass.is_compute) {
        for (bnd.pip.cmn.vertex_buffer_layout_active, 0..) |active, i| {
            if (!active) continue;
            std.debug.assert(bindings.vertex_buffers[i].id != 0);
            const buf = core.lookupBuffer(bindings.vertex_buffers[i].id);
            if (buf != null and buf.?.slot.state == .valid) {
                bnd.vbs[i] = buf;
                bnd.vb_offsets[i] = bindings.vertex_buffer_offsets[i];
            } else s.next_draw_valid = false;
        }
        if (bindings.index_buffer.id != 0) {
            const buf = core.lookupBuffer(bindings.index_buffer.id);
            if (buf != null and buf.?.slot.state == .valid) {
                bnd.ib = buf;
                bnd.ib_offset = bindings.index_buffer_offset;
            } else s.next_draw_valid = false;
        }
    }
    for (&shd.cmn.views, &bindings.views, 0..) |sv, b, i| {
        if (sv.view_type == .invalid) continue;
        std.debug.assert(b.id != 0);
        const view = core.lookupView(b.id);
        bnd.views[i] = view;
        if (view) |v| {
            // NOTE: a valid reference also requires the resource state VALID
            const ref_valid = if (v.cmn.type == .storagebuffer) v.cmn.buf.ref.valid() else v.cmn.img.ref.valid();
            if (!ref_valid) s.next_draw_valid = false;
        } else s.next_draw_valid = false;
    }
    for (&shd.cmn.samplers, &bindings.samplers, 0..) |ss, b, i| {
        if (ss.stage == .none) continue;
        std.debug.assert(b.id != 0);
        bnd.smps[i] = core.lookupSampler(b.id);
        if (bnd.smps[i] == null) s.next_draw_valid = false;
    }
    if (s.next_draw_valid) s.next_draw_valid = backend.applyBindings(&bnd);
}

pub fn applyUniforms(ub_slot: usize, data: t.Range) void {
    const s = state();
    std.debug.assert(ub_slot < constants.max_uniformblock_bindslots);
    std.debug.assert(data.ptr != null and data.size > 0);
    core.statsInc("num_apply_uniforms");
    core.statsAdd("size_apply_uniforms", @truncate(data.size));
    core.trace("apply_uniforms", .{ @as(i32, @intCast(ub_slot)), &data });
    if (!s.cur_pass.valid) return;
    if (!validation.applyUniforms(ub_slot, &data)) {
        s.next_draw_valid = false;
        return;
    }
    if (!s.next_draw_valid) return;
    backend.applyUniforms(ub_slot, &data);
}

fn checkSkipDraw(num_elements: i32, num_instances: i32) bool {
    const s = state();
    // skip draws in invalid passes, after invalid bindings, and no-op draws
    return !s.cur_pass.valid or !s.next_draw_valid or num_elements == 0 or num_instances == 0;
}

pub fn draw(base_element: i32, num_elements: i32, num_instances: i32) void {
    core.statsInc("num_draw");
    core.trace("draw", .{ base_element, num_elements, num_instances });
    if (checkSkipDraw(num_elements, num_instances)) return;
    if (!validation.draw(base_element, num_elements, num_instances)) return;
    backend.draw(base_element, num_elements, num_instances, 0, 0);
}

pub fn drawEx(base_element: i32, num_elements: i32, num_instances: i32, base_vertex: i32, base_instance: i32) void {
    core.statsInc("num_draw_ex");
    core.trace("draw_ex", .{ base_element, num_elements, num_instances, base_vertex, base_instance });
    if (checkSkipDraw(num_elements, num_instances)) return;
    if (!validation.drawEx(base_element, num_elements, num_instances, base_vertex, base_instance)) return;
    backend.draw(base_element, num_elements, num_instances, base_vertex, base_instance);
}

pub fn dispatch(num_groups_x: i32, num_groups_y: i32, num_groups_z: i32) void {
    const s = state();
    core.statsInc("num_dispatch");
    core.trace("dispatch", .{ num_groups_x, num_groups_y, num_groups_z });
    if (!s.cur_pass.valid or !s.next_draw_valid) return;
    // skip no-op dispatches
    if (num_groups_x == 0 or num_groups_y == 0 or num_groups_z == 0) return;
    if (!validation.dispatch(num_groups_x, num_groups_y, num_groups_z)) return;
    backend.dispatch(num_groups_x, num_groups_y, num_groups_z);
}

pub fn endPass() void {
    const s = state();
    std.debug.assert(s.cur_pass.in_pass);
    core.statsInc("num_passes");
    core.trace("end_pass", .{});
    // NOTE: don't exit early if the pass is invalid
    if (!s.cur_pass.swapchain.invalid) {
        const atts = core.attachmentsPtrs(&s.cur_pass.atts);
        backend.endPass(&atts);
    }
    s.cur_pip = .{};
    s.cur_pass = .{};
}

pub fn commit() void {
    const s = state();
    std.debug.assert(!s.cur_pass.valid and !s.cur_pass.in_pass);
    backend.commit();
    backend.collectStats(&s.stats.cur_frame);
    backend.resetStats();
    s.stats.cur_frame.frame_index = s.frame_index;
    s.stats.prev_frame = s.stats.cur_frame;
    s.stats.cur_frame = .{};
    notifyCommitListeners();
    core.trace("commit", .{});
    s.frame_index +%= 1;
}

pub fn resetStateCache() void {
    _ = state();
    backend.resetStateCache();
    core.trace("reset_state_cache", .{});
}

// ---------------------------------------------------------------- data transfers

pub fn writeBufferTransient(desc: t.WriteBufferDesc) void {
    const s = state();
    core.statsInc("num_write_buffer_transient");
    const buf = core.lookupBuffer(desc.dst.buffer.id) orelse {
        core.logError(.write_buffer_transient_buffer_alive);
        return;
    };
    if (buf.slot.state != .valid) {
        core.logError(.write_buffer_transient_buffer_valid);
        return;
    }
    const desc_def = defaults.writeBuffer(desc);
    if (validation.writeBufferTransient(buf, &desc_def)) {
        // if this is the first call in a frame, rotate the active slot
        var first_time_in_frame = false;
        if (buf.cmn.write_transient_frame_index != s.frame_index) {
            first_time_in_frame = true;
            buf.cmn.write_transient_frame_index = s.frame_index;
            buf.cmn.active_slot += 1;
            if (buf.cmn.active_slot >= buf.cmn.num_slots) buf.cmn.active_slot = 0;
        }
        backend.writeBufferTransient(buf, &desc_def, first_time_in_frame);
    }
    core.trace("write_buffer_transient", .{&desc});
}

pub fn writeImageTransient(desc: t.WriteImageDesc) void {
    const s = state();
    core.statsInc("num_write_image_transient");
    const img = core.lookupImage(desc.dst.image.id) orelse {
        core.logError(.write_image_transient_image_alive);
        return;
    };
    if (img.slot.state != .valid) {
        core.logError(.write_image_transient_image_valid);
        return;
    }
    const desc_def = defaults.imageTransfer(t.WriteImageDesc, desc, img.desc);
    if (validation.writeImageTransient(img, &desc_def)) {
        var first_time_in_frame = false;
        if (img.cmn.write_transient_frame_index != s.frame_index) {
            first_time_in_frame = true;
            img.cmn.write_transient_frame_index = s.frame_index;
            img.cmn.active_slot += 1;
            if (img.cmn.active_slot >= img.cmn.num_slots) img.cmn.active_slot = 0;
        }
        backend.writeImageTransient(img, &desc_def, first_time_in_frame);
    }
    core.trace("write_image_transient", .{&desc});
}

pub fn writeBufferUnsealed(desc: t.WriteBufferDesc) void {
    _ = state();
    core.statsInc("num_write_buffer_unsealed");
    const buf = core.lookupBuffer(desc.dst.buffer.id) orelse {
        core.logError(.write_buffer_unsealed_buffer_alive);
        return;
    };
    if (buf.slot.state != .unsealed) {
        core.logError(.write_buffer_unsealed_buffer_unsealed);
        return;
    }
    const desc_def = defaults.writeBuffer(desc);
    if (validation.writeBufferUnsealed(buf, &desc_def)) backend.writeBufferUnsealed(buf, &desc_def);
    core.trace("write_buffer_unsealed", .{&desc});
}

pub fn writeImageUnsealed(desc: t.WriteImageDesc) void {
    _ = state();
    core.statsInc("num_write_image_unsealed");
    const img = core.lookupImage(desc.dst.image.id) orelse {
        core.logError(.write_image_unsealed_image_alive);
        return;
    };
    if (img.slot.state != .unsealed) {
        core.logError(.write_image_unsealed_image_unsealed);
        return;
    }
    const desc_def = defaults.imageTransfer(t.WriteImageDesc, desc, img.desc);
    if (validation.writeImageUnsealed(img, &desc_def)) backend.writeImageUnsealed(img, &desc_def);
    core.trace("write_image_unsealed", .{&desc});
}

pub fn sealBuffer(buf_id: t.Buffer) void {
    core.statsInc("num_seal_buffer");
    const buf = core.lookupBuffer(buf_id.id) orelse {
        core.logError(.seal_buffer_alive);
        return;
    };
    if (validation.sealBuffer(buf)) {
        backend.sealBuffer(buf);
        buf.slot.state = .valid;
    }
    core.trace("seal_buffer", .{buf_id});
}

pub fn sealImage(img_id: t.Image) void {
    core.statsInc("num_seal_image");
    const img = core.lookupImage(img_id.id) orelse {
        core.logError(.seal_image_alive);
        return;
    };
    if (validation.sealImage(img)) {
        backend.sealImage(img);
        img.slot.state = .valid;
    }
    core.trace("seal_image", .{img_id});
}

pub fn copyBufferToBuffer(desc: t.CopyBufferToBufferDesc) void {
    core.statsInc("num_copy_buffer_to_buffer");
    const src_buf = core.lookupBuffer(desc.src.buffer.id);
    const dst_buf = core.lookupBuffer(desc.dst.buffer.id);
    const src = src_buf orelse return core.logError(.copy_buffer_to_buffer_src_alive);
    const dst = dst_buf orelse return core.logError(.copy_buffer_to_buffer_dst_alive);
    if (src.slot.state != .valid) return core.logError(.copy_buffer_to_buffer_src_valid);
    if (dst.slot.state != .valid) return core.logError(.copy_buffer_to_buffer_dst_valid);
    if (validation.copyBufferToBuffer(src, dst, &desc)) {
        core.statsAdd("size_copy_buffer_to_buffer", @truncate(desc.size));
        backend.copyBufferToBuffer(src, dst, &desc);
    }
    core.trace("copy_buffer_to_buffer", .{&desc});
}

pub fn copyBufferToImage(desc: t.CopyBufferToImageDesc) void {
    core.statsInc("num_copy_buffer_to_image");
    const src_buf = core.lookupBuffer(desc.src.buffer.id);
    const dst_img = core.lookupImage(desc.dst.image.id);
    const src = src_buf orelse return core.logError(.copy_buffer_to_image_src_alive);
    const dst = dst_img orelse return core.logError(.copy_buffer_to_image_dst_alive);
    if (src.slot.state != .valid) return core.logError(.copy_buffer_to_image_src_valid);
    if (dst.slot.state != .valid) return core.logError(.copy_buffer_to_image_dst_valid);
    const desc_def = defaults.imageTransfer(t.CopyBufferToImageDesc, desc, dst.desc);
    if (validation.copyBufferToImage(src, dst, &desc_def)) {
        const copy_size = formats.imageCopySize(dst.cmn.pixel_format, desc_def.src.bytes_per_row, desc_def.src.bytes_per_slice, desc_def.size.width, desc_def.size.height, desc_def.size.num_slices);
        core.statsAdd("size_copy_buffer_to_image", @truncate(copy_size));
        backend.copyBufferToImage(src, dst, &desc_def);
    }
    core.trace("copy_buffer_to_image", .{&desc});
}

// ---------------------------------------------------------------- readback (zicr extension)

/// Waits for all committed GPU work and copies `out.len` bytes of a buffer,
/// starting at `offset`, into `out`. Must be called outside of passes; the
/// buffer needs `usage.copy_src`. Returns false if the read was rejected or failed.
pub fn readBuffer(buf_id: t.Buffer, offset: usize, out: []u8) bool {
    const buf = core.lookupBuffer(buf_id.id) orelse {
        core.logError(.read_buffer_alive);
        return false;
    };
    if (buf.slot.state != .valid) {
        core.logError(.read_buffer_valid);
        return false;
    }
    if (!validation.readBuffer(buf, offset, out.len)) return false;
    if (backend.readBuffer(buf, offset, out)) return true;
    core.logError(.read_buffer_failed);
    return false;
}

pub const ReadImageDesc = struct {
    image: t.Image = .{},
    mip_level: u32 = 0,
    x: u32 = 0,
    y: u32 = 0,
    slice: u32 = 0,
    /// 0: to the end of the mip level.
    width: u32 = 0,
    height: u32 = 0,
    num_slices: u32 = 0,
    /// 0: tightly packed.
    bytes_per_row: usize = 0,
    bytes_per_slice: usize = 0,
};

/// Resolves default image extents/pitches and validates a read destination.
/// Shared by synchronous reads and owned readback requests; records no GPU work.
pub fn resolveReadImage(desc: ReadImageDesc, size: usize) ?struct { image: *core.Image, region: core.ReadRegion } {
    const img = core.lookupImage(desc.image.id) orelse {
        core.logError(.read_image_alive);
        return null;
    };
    if (img.slot.state != .valid) {
        core.logError(.read_image_valid);
        return null;
    }
    const cmn = &img.cmn;
    var region: core.ReadRegion = .{
        .mip_level = desc.mip_level,
        .x = desc.x,
        .y = desc.y,
        .slice = desc.slice,
        .width = desc.width,
        .height = desc.height,
        .num_slices = desc.num_slices,
        .bytes_per_row = desc.bytes_per_row,
        .bytes_per_slice = desc.bytes_per_slice,
    };
    if (desc.mip_level < cmn.num_mipmaps) {
        const mip: i32 = @intCast(desc.mip_level);
        const slices = if (cmn.type == .@"3d") core.miplevelDim(cmn.num_slices, mip) else cmn.num_slices;
        if (region.width == 0) region.width = @intCast(@max(core.miplevelDim(cmn.width, mip) - @as(i32, @intCast(@min(desc.x, std.math.maxInt(i32)))), 0));
        if (region.height == 0) region.height = @intCast(@max(core.miplevelDim(cmn.height, mip) - @as(i32, @intCast(@min(desc.y, std.math.maxInt(i32)))), 0));
        if (region.num_slices == 0) region.num_slices = @intCast(@max(slices - @as(i32, @intCast(@min(desc.slice, std.math.maxInt(i32)))), 0));
        if (region.bytes_per_row == 0 and region.width > 0) region.bytes_per_row = @intCast(formats.rowPitch(cmn.pixel_format, @intCast(region.width), 1));
        if (region.bytes_per_slice == 0) region.bytes_per_slice = region.bytes_per_row * region.height;
    }
    if (!validation.readImage(img, &region, size)) return null;
    return .{ .image = img, .region = region };
}

/// Reads committed GPU work outside a pass into caller-owned memory.
pub fn readImage(desc: ReadImageDesc, out: []u8) bool {
    const resolved = resolveReadImage(desc, out.len) orelse return false;
    if (backend.readImage(resolved.image, &resolved.region, out)) return true;
    core.logError(.read_image_failed);
    return false;
}

pub fn pushDebugGroup(name: [*:0]const u8) void {
    _ = state();
    backend.pushDebugGroup(name);
    core.trace("push_debug_group", .{name});
}

pub fn popDebugGroup() void {
    _ = state();
    backend.popDebugGroup();
    core.trace("pop_debug_group", .{});
}

// ---------------------------------------------------------------- backend-specific queries

fn native(comptime tag: anytype, res: anytype) ?*@FieldType(@FieldType(@TypeOf(res.*), "native"), @tagName(tag)) {
    return if (res.native == tag) &@field(res.native, @tagName(tag)) else null;
}

/// Returns the D3D11 device, or null if the D3D11 backend isn't active.
pub fn d3d11Device() ?*const anyopaque {
    const s = core.current() orelse return null;
    return if (s.impl == .d3d11) s.impl.d3d11.device else null;
}
pub fn d3d11DeviceContext() ?*const anyopaque {
    const s = core.current() orelse return null;
    return if (s.impl == .d3d11) s.impl.d3d11.context else null;
}
pub fn d3d11QueryBufferInfo(buf_id: t.Buffer) t.D3d11BufferInfo {
    const buf = core.lookupBuffer(buf_id.id) orelse return .{};
    const n = native(.d3d11, buf) orelse return .{};
    return .{ .buf = n.object };
}
pub fn d3d11QueryImageInfo(img_id: t.Image) t.D3d11ImageInfo {
    const img = core.lookupImage(img_id.id) orelse return .{};
    const n = native(.d3d11, img) orelse return .{};
    return .{ .tex2d = n.texture_2d, .tex3d = n.texture_3d, .res = n.resource };
}
pub fn d3d11QuerySamplerInfo(smp_id: t.Sampler) t.D3d11SamplerInfo {
    const smp = core.lookupSampler(smp_id.id) orelse return .{};
    const n = native(.d3d11, smp) orelse return .{};
    return .{ .smp = n.object };
}
pub fn d3d11QueryShaderInfo(shd_id: t.Shader) t.D3d11ShaderInfo {
    const shd = core.lookupShader(shd_id.id) orelse return .{};
    const n = native(.d3d11, shd) orelse return .{};
    var res: t.D3d11ShaderInfo = .{ .vs = n.vertex, .fs = n.fragment };
    for (&res.cbufs, n.uniform_buffers) |*dst, src| dst.* = src;
    return res;
}
pub fn d3d11QueryPipelineInfo(pip_id: t.Pipeline) t.D3d11PipelineInfo {
    const pip = core.lookupPipeline(pip_id.id) orelse return .{};
    const n = native(.d3d11, pip) orelse return .{};
    return .{ .il = n.input_layout, .rs = n.rasterizer, .dss = n.depth_stencil, .bs = n.blend };
}
pub fn d3d11QueryViewInfo(view_id: t.View) t.D3d11ViewInfo {
    const view = core.lookupView(view_id.id) orelse return .{};
    const n = native(.d3d11, view) orelse return .{};
    return .{ .srv = n.srv, .uav = n.uav, .rtv = n.rtv, .dsv = n.dsv };
}

fn activeBackend(comptime tag: std.meta.Tag(backend.Impl)) ?*@FieldType(backend.Impl, @tagName(tag)) {
    const s = core.current() orelse return null;
    return if (s.impl == tag) &@field(s.impl, @tagName(tag)) else null;
}

fn nativeInfo(comptime tag: std.meta.Tag(backend.Impl), comptime kind: Kind, comptime Info: type, id: u32) Info {
    const res = lookup(kind, id) orelse return .{};
    if (res.native != @field(std.meta.Tag(@TypeOf(res.native)), @tagName(tag))) return .{};
    const module = switch (tag) {
        .metal => @import("backends/metal/backend.zig"),
        .wgpu => @import("backends/wgpu/backend.zig"),
        else => unreachable,
    };
    const name = switch (kind) {
        .buffer => "queryBufferInfo",
        .image => "queryImageInfo",
        .sampler => "querySamplerInfo",
        .shader => "queryShaderInfo",
        .pipeline => "queryPipelineInfo",
        .view => "queryViewInfo",
    };
    return @field(module, name)(res);
}

/// Returns the Metal device, or null if the Metal backend isn't active.
pub fn mtlDevice() ?*const anyopaque {
    return if (activeBackend(.metal)) |b| b.device() else null;
}
pub fn mtlRenderCommandEncoder() ?*const anyopaque {
    return if (activeBackend(.metal)) |b| b.renderCommandEncoder() else null;
}
pub fn mtlComputeCommandEncoder() ?*const anyopaque {
    return if (activeBackend(.metal)) |b| b.computeCommandEncoder() else null;
}
pub fn mtlCommandQueue() ?*const anyopaque {
    return if (activeBackend(.metal)) |b| b.commandQueue() else null;
}
pub fn mtlQueryBufferInfo(buf_id: t.Buffer) t.MtlBufferInfo {
    return nativeInfo(.metal, .buffer, t.MtlBufferInfo, buf_id.id);
}
pub fn mtlQueryImageInfo(img_id: t.Image) t.MtlImageInfo {
    return nativeInfo(.metal, .image, t.MtlImageInfo, img_id.id);
}
pub fn mtlQuerySamplerInfo(smp_id: t.Sampler) t.MtlSamplerInfo {
    return nativeInfo(.metal, .sampler, t.MtlSamplerInfo, smp_id.id);
}
pub fn mtlQueryShaderInfo(shd_id: t.Shader) t.MtlShaderInfo {
    return nativeInfo(.metal, .shader, t.MtlShaderInfo, shd_id.id);
}
pub fn mtlQueryPipelineInfo(pip_id: t.Pipeline) t.MtlPipelineInfo {
    return nativeInfo(.metal, .pipeline, t.MtlPipelineInfo, pip_id.id);
}

/// Returns the WebGPU device, or null if the WebGPU backend isn't active.
pub fn wgpuDevice() ?*const anyopaque {
    return if (activeBackend(.wgpu)) |b| b.device() else null;
}
pub fn wgpuQueue() ?*const anyopaque {
    return if (activeBackend(.wgpu)) |b| b.queue() else null;
}
pub fn wgpuCommandEncoder() ?*const anyopaque {
    return if (activeBackend(.wgpu)) |b| b.commandEncoder() else null;
}
pub fn wgpuRenderPassEncoder() ?*const anyopaque {
    return if (activeBackend(.wgpu)) |b| b.renderPassEncoder() else null;
}
pub fn wgpuComputePassEncoder() ?*const anyopaque {
    return if (activeBackend(.wgpu)) |b| b.computePassEncoder() else null;
}
pub fn wgpuQueryBufferInfo(buf_id: t.Buffer) t.WgpuBufferInfo {
    return nativeInfo(.wgpu, .buffer, t.WgpuBufferInfo, buf_id.id);
}
pub fn wgpuQueryImageInfo(img_id: t.Image) t.WgpuImageInfo {
    return nativeInfo(.wgpu, .image, t.WgpuImageInfo, img_id.id);
}
pub fn wgpuQuerySamplerInfo(smp_id: t.Sampler) t.WgpuSamplerInfo {
    return nativeInfo(.wgpu, .sampler, t.WgpuSamplerInfo, smp_id.id);
}
pub fn wgpuQueryShaderInfo(shd_id: t.Shader) t.WgpuShaderInfo {
    return nativeInfo(.wgpu, .shader, t.WgpuShaderInfo, shd_id.id);
}
pub fn wgpuQueryPipelineInfo(pip_id: t.Pipeline) t.WgpuPipelineInfo {
    return nativeInfo(.wgpu, .pipeline, t.WgpuPipelineInfo, pip_id.id);
}
pub fn wgpuQueryViewInfo(view_id: t.View) t.WgpuViewInfo {
    return nativeInfo(.wgpu, .view, t.WgpuViewInfo, view_id.id);
}

pub fn glQueryBufferInfo(buf_id: t.Buffer) t.GlBufferInfo {
    const buf = core.lookupBuffer(buf_id.id) orelse return .{};
    const n = native(.gl, buf) orelse return .{};
    return .{ .buf = n.ids, .active_slot = buf.cmn.active_slot };
}
pub fn glQueryImageInfo(img_id: t.Image) t.GlImageInfo {
    const img = core.lookupImage(img_id.id) orelse return .{};
    const n = native(.gl, img) orelse return .{};
    return .{ .tex = n.ids, .tex_target = n.target, .active_slot = img.cmn.active_slot };
}
pub fn glQuerySamplerInfo(smp_id: t.Sampler) t.GlSamplerInfo {
    const smp = core.lookupSampler(smp_id.id) orelse return .{};
    const n = native(.gl, smp) orelse return .{};
    return .{ .smp = n.id };
}
pub fn glQueryShaderInfo(shd_id: t.Shader) t.GlShaderInfo {
    const shd = core.lookupShader(shd_id.id) orelse return .{};
    const n = native(.gl, shd) orelse return .{};
    return .{ .prog = n.program };
}
pub fn glQueryViewInfo(view_id: t.View) t.GlViewInfo {
    const view = core.lookupView(view_id.id) orelse return .{};
    const n = native(.gl, view) orelse return .{};
    return .{ .tex_view = n.texture_views, .msaa_render_buffer = n.msaa_renderbuffer, .msaa_resolve_frame_buffer = n.resolve_framebuffer };
}
