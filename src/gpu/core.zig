//! Shared runtime state, resource objects and helpers, from sokol_gfx.h:6983-7210
//! (structs), 8130-8230 (state), 8759-9267 (references and helpers).
const std = @import("std");
const t = @import("types.zig");
const e = @import("enums.zig");
pub const config = @import("config.zig");
pub const formats = @import("formats.zig");
const log_ = @import("log.zig");
const pool = @import("pool.zig");
const backend = @import("backend.zig");

pub const Slot = pool.Slot;
pub const SlotRef = pool.SlotRef;
pub const Pool = pool.Pool;

pub const num_pixel_formats = blk: {
    var max: u32 = 0;
    for (@typeInfo(e.PixelFormat).@"enum".field_values) |value| max = @max(max, value);
    break :blk max + 1;
};
pub const max_uniformblock_bindslots = 8;
/// Bit flag in required/applied binding masks that stands for sg_apply_bindings().
pub const bindings_flag: u32 = 1 << max_uniformblock_bindslots;

pub const Dim = struct { width: i32 = 0, height: i32 = 0 };
pub const Rect = struct { x: i32 = 0, y: i32 = 0, w: i32 = 0, h: i32 = 0 };

// ---------------------------------------------------------------- resources

pub const BufferCommon = struct {
    size: usize = 0,
    num_slots: i32 = 0,
    active_slot: i32 = 0,
    /// Last frame index the buffer was written with writeBufferTransient().
    write_transient_frame_index: u32 = 0,
    validate: struct {
        bind_frame_index: u32 = 0,
        copy_src_frame_index: u32 = 0,
        read_render_pass_index: u32 = 0,
        write_render_pass_index: u32 = 0,
    } = .{},
    usage: t.BufferUsage = .{},
};

pub const ImageCommon = struct {
    num_slots: i32 = 0,
    active_slot: i32 = 0,
    write_transient_frame_index: u32 = 0,
    validate: struct { bind_frame_index: u32 = 0 } = .{},
    type: e.ImageType = .default,
    width: i32 = 0,
    height: i32 = 0,
    num_slices: i32 = 0,
    num_mipmaps: i32 = 0,
    usage: t.ImageUsage = .{},
    pixel_format: e.PixelFormat = .default,
    sample_count: i32 = 0,
};

pub const SamplerCommon = struct {
    min_filter: e.Filter = .default,
    mag_filter: e.Filter = .default,
    mipmap_filter: e.Filter = .default,
    wrap_u: e.Wrap = .default,
    wrap_v: e.Wrap = .default,
    wrap_w: e.Wrap = .default,
    min_lod: f32 = 0,
    max_lod: f32 = 0,
    border_color: e.BorderColor = .default,
    compare: e.CompareFunc = .default,
    max_anisotropy: u32 = 0,
};

pub const ShaderAttr = struct { base_type: e.ShaderAttrBaseType = .undefined };
pub const ShaderUniformBlock = struct { stage: e.ShaderStage = .none, size: u32 = 0 };
pub const ShaderView = struct {
    stage: e.ShaderStage = .none,
    view_type: e.ViewType = .invalid,
    image_type: e.ImageType = .default,
    access_format: e.PixelFormat = .default,
    sample_type: e.ImageSampleType = .default,
    sbuf_readonly: bool = false,
    simg_writeonly: bool = false,
    multisampled: bool = false,
};
pub const ShaderSampler = struct { stage: e.ShaderStage = .none, sampler_type: e.SamplerType = .default };
pub const ShaderTextureSampler = struct { stage: e.ShaderStage = .none, view_slot: u8 = 0, sampler_slot: u8 = 0 };

pub const ShaderCommon = struct {
    required_bindings_and_uniforms: u32 = 0,
    is_compute: bool = false,
    attrs: [16]ShaderAttr = @splat(.{}),
    uniform_blocks: [8]ShaderUniformBlock = @splat(.{}),
    views: [32]ShaderView = @splat(.{}),
    samplers: [12]ShaderSampler = @splat(.{}),
    texture_samplers: [32]ShaderTextureSampler = @splat(.{}),
};

pub const PipelineCommon = struct {
    vertex_buffer_layout_active: [8]bool = @splat(false),
    use_instanced_draw: bool = false,
    is_compute: bool = false,
    required_bindings_and_uniforms: u32 = 0,
    shader: Ref(Shader) = .{},
    layout: t.VertexLayoutState = .{},
    depth: t.DepthState = .{},
    stencil: t.StencilState = .{},
    color_count: i32 = 0,
    colors: [8]t.ColorTargetState = @splat(.{}),
    primitive_type: e.PrimitiveType = .default,
    index_type: e.IndexType = .default,
    cull_mode: e.CullMode = .default,
    face_winding: e.FaceWinding = .default,
    sample_count: i32 = 0,
    blend_color: t.Color = .{},
    alpha_to_coverage_enabled: bool = false,
};

pub const BufferViewCommon = struct { ref: Ref(Buffer) = .{}, offset: i32 = 0 };
pub const ImageViewCommon = struct {
    ref: Ref(Image) = .{},
    mip_level: i32 = 0,
    slice: i32 = 0,
    mip_level_count: i32 = 0,
    slice_count: i32 = 0,
};
pub const ViewCommon = struct {
    type: e.ViewType = .invalid,
    buf: BufferViewCommon = .{},
    img: ImageViewCommon = .{},
};

/// Backend-specific payload of a resource. Exactly one backend is active per
/// setup(), so only the matching field is ever initialized.
pub fn Native(comptime Desc: type) type {
    return union(enum) {
        none: void,
        gl: @import("backends/gl/resources.zig").Resource(Desc),
        d3d11: @import("backends/d3d11/resources.zig").Resource(Desc),
        vulkan: @import("backends/vulkan/resources.zig").Resource(Desc),
        wgpu: @import("backends/wgpu/resources.zig").Resource(Desc),
        metal: @import("backends/metal/resources.zig").Resource(Desc),
        d3d12: @import("backends/d3d12/resources.zig").Resource(Desc),
    };
}

/// Each resource keeps the common state of the source plus its descriptor with
/// defaults applied and borrowed pointers cleared, which backends may read.
fn Resource(comptime Desc: type, comptime Common: type) type {
    return struct {
        slot: Slot = .{},
        cmn: Common = .{},
        desc: Desc = .{},
        native: Native(Desc) = .none,
    };
}
pub const Buffer = Resource(t.BufferDesc, BufferCommon);
pub const Image = Resource(t.ImageDesc, ImageCommon);
pub const Sampler = Resource(t.SamplerDesc, SamplerCommon);
pub const Shader = Resource(t.ShaderDesc, ShaderCommon);
pub const Pipeline = Resource(t.PipelineDesc, PipelineCommon);
pub const View = Resource(t.ViewDesc, ViewCommon);

/// A pointer to a pooled resource plus the slot identity it had when taken,
/// so that stale references can be detected (sokol_gfx.h:7018-7053).
pub fn Ref(comptime T: type) type {
    return struct {
        const Self = @This();
        ptr: ?*T = null,
        sref: SlotRef = .{},

        pub fn init(item: ?*T) Self {
            const res = item orelse return .{};
            std.debug.assert(res.slot.id != 0);
            return .{ .ptr = res, .sref = .of(&res.slot) };
        }
        pub fn isNull(self: Self) bool {
            return self.sref.id == 0;
        }
        pub fn alive(self: Self) bool {
            const res = self.ptr orelse return false;
            return self.sref.eqlSlot(&res.slot);
        }
        pub fn valid(self: Self) bool {
            return self.alive() and self.ptr.?.slot.state == .valid;
        }
        pub fn get(self: Self) *T {
            std.debug.assert(self.alive());
            return self.ptr.?;
        }
        pub fn getOrNull(self: Self) ?*T {
            return if (self.sref.id != 0 and self.alive()) self.ptr else null;
        }
        pub fn eql(self: Self, res: *const T) bool {
            return self.sref.eqlSlot(&res.slot);
        }
    };
}

/// Resolved pass attachments (_sg_attachments_ptrs_t).
pub const AttachmentsPtrs = struct {
    empty: bool = true,
    num_color_views: usize = 0,
    color_views: [8]?*View = @splat(null),
    resolve_views: [8]?*View = @splat(null),
    ds_view: ?*View = null,
};

/// Resolved resource bindings (_sg_bindings_ptrs_t).
pub const BindingsPtrs = struct {
    pip: *Pipeline,
    vb_offsets: [8]i32 = @splat(0),
    ib_offset: i32 = 0,
    vbs: [8]?*Buffer = @splat(null),
    ib: ?*Buffer = null,
    views: [32]?*View = @splat(null),
    smps: [12]?*Sampler = @splat(null),
};

/// A resolved image region for readback: one mip level, `bytes_per_row` and
/// `bytes_per_slice` apart in the destination (zicr extension).
pub const ReadRegion = struct {
    mip_level: u32,
    x: u32,
    y: u32,
    slice: u32,
    width: u32,
    height: u32,
    num_slices: u32,
    bytes_per_row: usize,
    bytes_per_slice: usize,
};

// ---------------------------------------------------------------- state

pub const Pools = struct {
    buffers: Pool(Buffer),
    images: Pool(Image),
    samplers: Pool(Sampler),
    shaders: Pool(Shader),
    pipelines: Pool(Pipeline),
    views: Pool(View),

    pub fn init(allocator: std.mem.Allocator, desc: *const t.Desc) !Pools {
        var buffers = try Pool(Buffer).init(allocator, @intCast(desc.buffer_pool_size));
        errdefer buffers.deinit(allocator);
        var images = try Pool(Image).init(allocator, @intCast(desc.image_pool_size));
        errdefer images.deinit(allocator);
        var samplers = try Pool(Sampler).init(allocator, @intCast(desc.sampler_pool_size));
        errdefer samplers.deinit(allocator);
        var shaders = try Pool(Shader).init(allocator, @intCast(desc.shader_pool_size));
        errdefer shaders.deinit(allocator);
        var pipelines = try Pool(Pipeline).init(allocator, @intCast(desc.pipeline_pool_size));
        errdefer pipelines.deinit(allocator);
        const views = try Pool(View).init(allocator, @intCast(desc.view_pool_size));
        return .{ .buffers = buffers, .images = images, .samplers = samplers, .shaders = shaders, .pipelines = pipelines, .views = views };
    }

    pub fn deinit(self: *Pools, allocator: std.mem.Allocator) void {
        self.views.deinit(allocator);
        self.pipelines.deinit(allocator);
        self.shaders.deinit(allocator);
        self.samplers.deinit(allocator);
        self.images.deinit(allocator);
        self.buffers.deinit(allocator);
    }
};

pub const CurPass = struct {
    valid: bool = false,
    in_pass: bool = false,
    is_compute: bool = false,
    dim: Dim = .{},
    atts: t.Attachments = .{},
    action: t.PassAction = .{},
    swapchain: struct {
        invalid: bool = false,
        color_fmt: e.PixelFormat = .default,
        depth_fmt: e.PixelFormat = .default,
        sample_count: i32 = 0,
    } = .{},
};

pub const ValidateState = struct {
    /// Running count of passes, keeps counting across frames.
    pass_index: u32 = 0,
    /// Bits 0..7: uniform blocks, bit 8: bindings.
    required_bindings_and_uniforms: u32 = 0,
    applied_bindings_and_uniforms: u32 = 0,
    write_buffer_transient_missing: bool = false,
    write_image_transient_missing: bool = false,
};

pub const State = struct {
    allocator: std.mem.Allocator,
    desc: t.Desc,
    frame_index: u32 = 1,
    /// First native loss code. Host callbacks may set this from another thread.
    loss_code: std.atomic.Value(i32) = .init(0),
    cur_pass: CurPass = .{},
    cur_pip: Ref(Pipeline) = .{},
    next_draw_valid: bool = false,
    use_indexed_draw: bool = false,
    use_instanced_draw: bool = false,
    validate: ValidateState = .{},
    validate_error: e.LogItem = .ok,
    pools: Pools,
    backend: e.Backend,
    features: t.Features = .{},
    limits: t.Limits = .{},
    formats: [num_pixel_formats]t.PixelformatInfo = @splat(.{}),
    stats_enabled: bool = true,
    stats: t.Stats = .{},
    hooks: t.TraceHooks = .{},
    commit_listeners: []t.CommitListener,
    commit_listeners_upper: usize = 0,
    impl: backend.Impl = .dummy,
    readbacks: std.ArrayList(*@import("readback_task.zig").Task) = .empty,
    gl_loader: ?@import("backends/gl/win32_loader.zig").Loader = null,
};

/// The raw compatibility API retains a singleton; public Devices own their State.
pub var sg: ?State = null;
const Selection = if (@import("builtin").cpu.arch.isWasm()) struct {
    var current: ?*State = null;
} else struct {
    threadlocal var current: ?*State = null;
};

/// Scoped dispatch keeps the translated core/backend internals source-shaped.
/// Selection is per thread and restored on return, including nested device calls.
pub const Scope = struct {
    previous: ?*State,
    pub fn end(self: Scope) void {
        Selection.current = self.previous;
    }
};
pub fn enter(selected: *State) Scope {
    const previous = Selection.current;
    Selection.current = selected;
    return .{ .previous = previous };
}
pub fn current() ?*State {
    if (Selection.current) |s| return s;
    if (sg) |*s| return s;
    return null;
}
pub fn state() *State {
    return current() orelse @panic("zicr.gpu: no device selected");
}

/// Records the first device loss without allocating or invoking application code.
pub fn recordLoss(code: i32) void {
    _ = state().loss_code.cmpxchgStrong(0, if (code == 0) -1 else code, .acq_rel, .acquire);
}

// ---------------------------------------------------------------- logging and stats

pub fn log(item: e.LogItem, level: log_.Level, msg: ?[*:0]const u8) void {
    log_.emit(state().desc.logger, item, level, msg, @src());
}
pub fn logPanic(item: e.LogItem) void {
    log(item, .panic, null);
}
pub fn logError(item: e.LogItem) void {
    log(item, .err, null);
}
pub fn logWarn(item: e.LogItem) void {
    log(item, .warn, null);
}
pub fn logInfo(item: e.LogItem) void {
    log(item, .info, null);
}
pub fn logMsg(item: e.LogItem, msg: [*:0]const u8) void {
    log(item, .info, msg);
}

/// Adds to a frame statistics counter; `path` is a dotted field path into
/// `sg_frame_stats`, for instance "num_draw" or "vk.num_cmd_copy_buffer".
pub fn statsAdd(comptime path: []const u8, value: u32) void {
    const s = state();
    if (s.stats_enabled) fieldPtr(&s.stats.cur_frame, path).* +%= value;
}
pub fn statsInc(comptime path: []const u8) void {
    statsAdd(path, 1);
}
pub fn resourceStatsInc(comptime kind: []const u8, comptime counter: []const u8) void {
    const s = state();
    if (s.stats_enabled) {
        @field(@field(s.stats.cur_frame, kind), counter) +%= 1;
        @field(@field(s.stats.total, kind), counter) +%= 1;
    }
}
fn FieldPtr(comptime T: type, comptime path: []const u8) type {
    const dot = comptime std.mem.indexOfScalar(u8, path, '.');
    if (dot) |i| return FieldPtr(@FieldType(T, path[0..i]), path[i + 1 ..]);
    return *@FieldType(T, path);
}
fn fieldPtr(base: anytype, comptime path: []const u8) FieldPtr(@typeInfo(@TypeOf(base)).pointer.child, path) {
    const dot = comptime std.mem.indexOfScalar(u8, path, '.');
    if (dot) |i| return fieldPtr(&@field(base, path[0..i]), path[i + 1 ..]);
    return &@field(base, path);
}

pub fn trace(comptime name: []const u8, arguments: anytype) void {
    const s = state();
    if (@field(s.hooks, name)) |callback| @call(.auto, callback, arguments ++ .{s.hooks.user_data});
}

// ---------------------------------------------------------------- lookups

pub fn lookupBuffer(id: u32) ?*Buffer {
    return state().pools.buffers.lookup(id);
}
pub fn lookupImage(id: u32) ?*Image {
    return state().pools.images.lookup(id);
}
pub fn lookupSampler(id: u32) ?*Sampler {
    return state().pools.samplers.lookup(id);
}
pub fn lookupShader(id: u32) ?*Shader {
    return state().pools.shaders.lookup(id);
}
pub fn lookupPipeline(id: u32) ?*Pipeline {
    return state().pools.pipelines.lookup(id);
}
pub fn lookupView(id: u32) ?*View {
    return state().pools.views.lookup(id);
}

// ---------------------------------------------------------------- helpers

pub fn stateValidFailed(s: e.ResourceState) bool {
    return s == .valid or s == .failed;
}
pub fn stateValidFailedUnsealed(s: e.ResourceState) bool {
    return s == .valid or s == .failed or s == .unsealed;
}
pub fn stateValidUnsealed(s: e.ResourceState) bool {
    return s == .valid or s == .unsealed;
}

pub fn miplevelDim(base_dim: i32, mip_level: i32) i32 {
    return @max(base_dim >> @intCast(mip_level), 1);
}

pub fn alignU32(val: u32, alignment: u32) u32 {
    std.debug.assert(alignment > 0 and (alignment & (alignment - 1)) == 0);
    return (val + (alignment - 1)) & ~(alignment - 1);
}

pub fn multiple(val: anytype, of: @TypeOf(val)) bool {
    return @mod(val, of) == 0;
}

/// Clips a rectangle against a framebuffer size (_sg_clipi).
pub fn clipRect(x: i32, y: i32, w: i32, h: i32, clip_width: i32, clip_height: i32) Rect {
    const cx = @min(@max(0, x), clip_width - 1);
    const cy = @min(@max(0, y), clip_height - 1);
    var cw = w;
    var ch = h;
    if (cx + cw > clip_width) cw = clip_width - cx;
    if (cy + ch > clip_height) ch = clip_height - cy;
    return .{ .x = cx, .y = cy, .w = @max(cw, 1), .h = @max(ch, 1) };
}

pub fn imageViewAlive(view: ?*const View) bool {
    const v = view orelse return false;
    return v.cmn.img.ref.alive();
}

pub fn imageViewDim(view: *const View) Dim {
    const img = view.cmn.img.ref.get();
    std.debug.assert(img.cmn.width > 0 and img.cmn.height > 0);
    return .{
        .width = miplevelDim(img.cmn.width, view.cmn.img.mip_level),
        .height = miplevelDim(img.cmn.height, view.cmn.img.mip_level),
    };
}

pub fn attachmentsEmpty(atts: *const t.Attachments) bool {
    for (atts.colors, atts.resolves) |color, resolve| {
        if (color.id != 0 or resolve.id != 0) return false;
    }
    return atts.depth_stencil.id == 0;
}

pub fn attachmentsPtrs(atts: *const t.Attachments) AttachmentsPtrs {
    var res: AttachmentsPtrs = .{};
    for (atts.colors, atts.resolves, 0..) |color, resolve, i| {
        if (color.id != 0) {
            res.empty = false;
            res.num_color_views += 1;
            res.color_views[i] = lookupView(color.id);
        }
        if (resolve.id != 0) {
            std.debug.assert(color.id != 0);
            res.empty = false;
            res.resolve_views[i] = lookupView(resolve.id);
        }
    }
    if (atts.depth_stencil.id != 0) {
        res.empty = false;
        res.ds_view = lookupView(atts.depth_stencil.id);
    }
    return res;
}

pub fn attachmentsDim(atts: *const AttachmentsPtrs) Dim {
    if (atts.ds_view) |view| return imageViewDim(view);
    return imageViewDim(atts.color_views[0].?);
}

pub fn attachmentsAlive(atts: *const AttachmentsPtrs) bool {
    for (0..atts.num_color_views) |i| {
        if (!imageViewAlive(atts.color_views[i])) return false;
        if (atts.resolve_views[i] != null and !imageViewAlive(atts.resolve_views[i])) return false;
    }
    if (atts.ds_view != null and !imageViewAlive(atts.ds_view)) return false;
    return true;
}

pub fn isDualSourceBlendFactor(f: e.BlendFactor) bool {
    return switch (f) {
        .src1_color, .one_minus_src1_color, .src1_alpha, .one_minus_src1_alpha => true,
        else => false,
    };
}

pub fn isValidAttachmentColorFormat(fmt: e.PixelFormat) bool {
    const info = state().formats[@backingInt(fmt)];
    return info.render and !info.depth;
}
pub fn isValidAttachmentDepthFormat(fmt: e.PixelFormat) bool {
    const info = state().formats[@backingInt(fmt)];
    return info.render and info.depth;
}
pub fn isValidStorageImageFormat(fmt: e.PixelFormat) bool {
    const info = state().formats[@backingInt(fmt)];
    return info.read or info.write;
}
pub fn isDepthOrDepthStencilFormat(fmt: e.PixelFormat) bool {
    return fmt == .depth or fmt == .depth_stencil;
}
pub fn isDepthStencilFormat(fmt: e.PixelFormat) bool {
    return fmt == .depth_stencil;
}

/// Resets a resource to the alloc state, preserving its slot and bumping the
/// uninit count so outstanding references become stale.
pub fn resetToAllocState(res: anytype) void {
    const slot = res.slot;
    res.* = .{};
    res.slot = slot;
    res.slot.uninit_count +%= 1;
    res.slot.state = .alloc;
}

// ---------------------------------------------------------------- common state init

pub fn bufferCommonInit(cmn: *BufferCommon, desc: *const t.BufferDesc) void {
    cmn.* = .{
        .size = desc.size,
        .num_slots = if (desc.usage.write_transient) @intCast(@import("constants.zig").num_inflight_frames) else 1,
        .usage = desc.usage,
    };
}

pub fn imageCommonInit(cmn: *ImageCommon, desc: *const t.ImageDesc) void {
    cmn.* = .{
        .num_slots = if (desc.usage.write_transient) @intCast(@import("constants.zig").num_inflight_frames) else 1,
        .type = desc.type,
        .width = desc.width,
        .height = desc.height,
        .num_slices = desc.num_slices,
        .num_mipmaps = desc.num_mipmaps,
        .usage = desc.usage,
        .pixel_format = desc.pixel_format,
        .sample_count = desc.sample_count,
    };
}

pub fn samplerCommonInit(cmn: *SamplerCommon, desc: *const t.SamplerDesc) void {
    cmn.* = .{
        .min_filter = desc.min_filter,
        .mag_filter = desc.mag_filter,
        .mipmap_filter = desc.mipmap_filter,
        .wrap_u = desc.wrap_u,
        .wrap_v = desc.wrap_v,
        .wrap_w = desc.wrap_w,
        .min_lod = desc.min_lod,
        .max_lod = desc.max_lod,
        .border_color = desc.border_color,
        .compare = desc.compare,
        .max_anisotropy = desc.max_anisotropy,
    };
}

pub fn isComputeShaderDesc(desc: *const t.ShaderDesc) bool {
    return desc.compute_func.source != null or desc.compute_func.bytecode.ptr != null;
}

pub fn shaderCommonInit(cmn: *ShaderCommon, desc: *const t.ShaderDesc) void {
    cmn.* = .{ .is_compute = isComputeShaderDesc(desc) };
    for (&cmn.attrs, desc.attrs) |*dst, src| dst.base_type = src.base_type;
    for (&cmn.uniform_blocks, desc.uniform_blocks, 0..) |*dst, src, i| {
        if (src.stage == .none) continue;
        cmn.required_bindings_and_uniforms |= @as(u32, 1) << @intCast(i);
        dst.* = .{ .stage = src.stage, .size = src.size };
    }
    for (&cmn.views, desc.views) |*dst, src| {
        if (src.texture.stage != .none) {
            dst.* = .{
                .stage = src.texture.stage,
                .view_type = .texture,
                .image_type = src.texture.image_type,
                .sample_type = src.texture.sample_type,
                .multisampled = src.texture.multisampled,
            };
        } else if (src.storage_buffer.stage != .none) {
            cmn.required_bindings_and_uniforms |= bindings_flag;
            dst.* = .{ .stage = src.storage_buffer.stage, .view_type = .storagebuffer, .sbuf_readonly = src.storage_buffer.readonly };
        } else if (src.storage_image.stage != .none) {
            cmn.required_bindings_and_uniforms |= bindings_flag;
            dst.* = .{
                .stage = src.storage_image.stage,
                .view_type = .storageimage,
                .image_type = src.storage_image.image_type,
                .access_format = src.storage_image.access_format,
                .simg_writeonly = src.storage_image.writeonly,
            };
        }
    }
    for (&cmn.samplers, desc.samplers) |*dst, src| {
        if (src.stage == .none) continue;
        cmn.required_bindings_and_uniforms |= bindings_flag;
        dst.* = .{ .stage = src.stage, .sampler_type = src.sampler_type };
    }
    for (&cmn.texture_samplers, desc.texture_sampler_pairs) |*dst, src| {
        if (src.stage == .none) continue;
        std.debug.assert(src.view_slot < 32 and cmn.views[src.view_slot].view_type == .texture);
        std.debug.assert(cmn.views[src.view_slot].stage == src.stage);
        std.debug.assert(src.sampler_slot < 12 and desc.samplers[src.sampler_slot].stage == src.stage);
        dst.* = .{ .stage = src.stage, .view_slot = src.view_slot, .sampler_slot = src.sampler_slot };
    }
}

pub fn pipelineCommonInit(cmn: *PipelineCommon, desc: *const t.PipelineDesc, shd: *Shader) void {
    std.debug.assert(desc.color_count >= 0 and desc.color_count <= 8);
    cmn.* = .{};
    for (desc.layout.attrs) |attr| {
        if (attr.format == .invalid) continue;
        std.debug.assert(attr.buffer_index >= 0 and attr.buffer_index < 8);
        cmn.vertex_buffer_layout_active[@intCast(attr.buffer_index)] = true;
        cmn.required_bindings_and_uniforms |= bindings_flag;
    }
    for (desc.layout.buffers) |buf| {
        if (buf.step_func == .per_instance) cmn.use_instanced_draw = true;
    }
    cmn.is_compute = desc.compute;
    cmn.shader = .init(shd);
    cmn.layout = desc.layout;
    cmn.depth = desc.depth;
    cmn.stencil = desc.stencil;
    cmn.color_count = desc.color_count;
    for (0..@intCast(desc.color_count)) |i| cmn.colors[i] = desc.colors[i];
    cmn.primitive_type = desc.primitive_type;
    cmn.index_type = desc.index_type;
    if (cmn.index_type != .none) cmn.required_bindings_and_uniforms |= bindings_flag;
    cmn.cull_mode = desc.cull_mode;
    cmn.face_winding = desc.face_winding;
    cmn.sample_count = desc.sample_count;
    cmn.blend_color = desc.blend_color;
    cmn.alpha_to_coverage_enabled = desc.alpha_to_coverage_enabled;
}

fn textureViewCommonInit(cmn: *ImageViewCommon, desc: *const t.TextureViewDesc, img: *Image) void {
    std.debug.assert(stateValidUnsealed(img.slot.state));
    cmn.ref = .init(img);
    cmn.mip_level = desc.mip_levels.base;
    cmn.mip_level_count = if (desc.mip_levels.count == 0) img.cmn.num_mipmaps - cmn.mip_level else desc.mip_levels.count;
    cmn.slice = desc.slices.base;
    cmn.slice_count = switch (img.cmn.type) {
        .@"2d", .@"3d" => 1,
        .cube => 6,
        .array => if (desc.slices.count == 0) img.cmn.num_slices - cmn.slice else desc.slices.count,
        else => unreachable,
    };
}

fn imageViewCommonInit(cmn: *ImageViewCommon, desc: *const t.ImageViewDesc, img: *Image) void {
    std.debug.assert(img.slot.state == .valid);
    cmn.* = .{ .ref = .init(img), .mip_level = desc.mip_level, .mip_level_count = 1, .slice = desc.slice, .slice_count = 1 };
}

pub fn viewCommonInit(cmn: *ViewCommon, desc: *const t.ViewDesc, buf: ?*Buffer, img: ?*Image) void {
    cmn.* = .{};
    if (desc.texture.image.id != 0) {
        cmn.type = .texture;
        textureViewCommonInit(&cmn.img, &desc.texture, img.?);
    } else if (desc.storage_buffer.buffer.id != 0) {
        std.debug.assert(buf.?.slot.state == .valid);
        cmn.type = .storagebuffer;
        cmn.buf = .{ .ref = .init(buf.?), .offset = desc.storage_buffer.offset };
    } else if (desc.storage_image.image.id != 0) {
        cmn.type = .storageimage;
        imageViewCommonInit(&cmn.img, &desc.storage_image, img.?);
    } else if (desc.color_attachment.image.id != 0) {
        cmn.type = .colorattachment;
        imageViewCommonInit(&cmn.img, &desc.color_attachment, img.?);
    } else if (desc.resolve_attachment.image.id != 0) {
        cmn.type = .resolveattachment;
        imageViewCommonInit(&cmn.img, &desc.resolve_attachment, img.?);
    } else if (desc.depth_stencil_attachment.image.id != 0) {
        cmn.type = .depthstencilattachment;
        imageViewCommonInit(&cmn.img, &desc.depth_stencil_attachment, img.?);
    } else unreachable;
}

// ---------------------------------------------------------------- stored descriptors

/// Returns a copy of a descriptor with every borrowed pointer cleared, so that
/// a resource never keeps references into caller memory after creation.
pub fn retainedDesc(desc: anytype) @TypeOf(desc) {
    var res = desc;
    res.label = null;
    switch (@TypeOf(desc)) {
        t.BufferDesc => res.data = .{},
        t.ImageDesc => res.data = .{},
        t.ShaderDesc => {
            inline for (.{ "vertex_func", "fragment_func", "compute_func" }) |name| @field(res, name) = .{};
            for (&res.attrs) |*attr| {
                attr.glsl_name = null;
                attr.hlsl_sem_name = null;
            }
            for (&res.uniform_blocks) |*block| {
                for (&block.glsl_uniforms) |*uniform| uniform.glsl_name = null;
            }
            for (&res.texture_sampler_pairs) |*pair| pair.glsl_name = null;
        },
        else => {},
    }
    return res;
}
