//! The zicr GPU layer: a portable, validated abstraction over the native graphics
//! APIs (Vulkan, D3D12, Metal, WebGPU, OpenGL/GLES/WebGL2), based on sokol_gfx.
//!
//! ```zig
//! var dev = try gpu.Device.init(allocator, .{ .backend = .{ .vulkan = vk_env } });
//! defer dev.deinit();
//! const vbuf = try dev.createBuffer(.{ .usage = .{ .vertex = true }, .data = std.mem.sliceAsBytes(&vertices) });
//! defer dev.destroy(vbuf);
//! var pass = dev.beginPass(.{ .target = .{ .swapchain = swapchain } });
//! pass.setPipeline(pipeline);
//! pass.setBindings(.{ .vertex_buffers = &.{.{ .buffer = vbuf }} });
//! pass.setUniforms(0, &params);
//! pass.draw(.{ .count = 3 });
//! pass.end();
//! dev.commit();
//! ```
//!
//! Resources are referenced through generation-checked handles. Creating a
//! resource returns an error for invalid descriptors; commands recorded with
//! invalid state are skipped and reported through the diagnostics callback.
const std = @import("std");
const builtin = @import("builtin");
const enums = @import("public_enums.zig");
const internal = @import("internal.zig");
const t = @import("types.zig");
const e = @import("enums.zig");
const core = @import("core.zig");
const log_messages = @import("log.zig");

/// The sokol-shaped core API this layer is built on. It is not stable and is
/// exposed for tests and tooling only.
pub const raw = internal;

/// Freestanding wasm import resolvers used by browser hosts.
pub const web = @import("web.zig");

/// Storage and numeric interpretation of image texels.
pub const PixelFormat = enums.PixelFormat;
/// Element width of an index buffer, or no indexed drawing.
pub const IndexType = enums.IndexType;
/// Texture dimensionality: 2D, cube, 3D or array.
pub const ImageType = enums.ImageType;
/// Numeric type expected when a shader samples an image.
pub const ImageSampleType = enums.ImageSampleType;
/// Filtering or comparison behavior expected by a shader binding.
pub const SamplerType = enums.SamplerType;
/// How vertices or indices form points, lines or triangles.
pub const PrimitiveType = enums.PrimitiveType;
/// Nearest or linear filtering between texels or mip levels.
pub const Filter = enums.Filter;
/// How sampling addresses outside the image are handled.
pub const Wrap = enums.Wrap;
/// Fixed color returned by clamp-to-border sampling when supported.
pub const BorderColor = enums.BorderColor;
/// Memory encoding of one vertex attribute.
pub const VertexFormat = enums.VertexFormat;
/// Whether vertex data advances per vertex or per instance.
pub const VertexStep = enums.VertexStep;
/// Scalar, vector or matrix type in reflected uniform data.
pub const UniformType = enums.UniformType;
/// Alignment rules for reflected uniform blocks.
pub const UniformLayout = enums.UniformLayout;
/// Which triangle faces are discarded before rasterization.
pub const CullMode = enums.CullMode;
/// Vertex order that identifies a front-facing triangle.
pub const FaceWinding = enums.FaceWinding;
/// Comparison used by depth, stencil or comparison sampling.
pub const CompareFunc = enums.CompareFunc;
/// How a stencil value changes after a stencil/depth test.
pub const StencilOp = enums.StencilOp;
/// Multiplier applied to source or destination color during blending.
pub const BlendFactor = enums.BlendFactor;
/// Operation combining weighted source and destination colors.
pub const BlendOp = enums.BlendOp;
/// Color channels that a render target may write.
pub const ColorMask = enums.ColorMask;
/// Shader stage that consumes a reflected binding.
pub const ShaderStage = enums.ShaderStage;
/// Numeric class of a shader vertex input.
pub const ShaderAttrBaseType = enums.ShaderAttrBaseType;
/// Lifecycle state of a resource handle.
pub const ResourceState = enums.ResourceState;
/// Binding or attachment role of a resource view.
pub const ViewType = enums.ViewType;
/// Current pass recording and validation state.
pub const PassState = enums.PassState;
/// Stable identifier for a diagnostic; use it instead of matching message text.
pub const LogItem = e.LogItem;
/// Capabilities available to this Device; query before using optional behavior.
pub const Features = t.Features;
/// GPU API counters collected for one frame when statistics are enabled.
pub const FrameStats = t.FrameStats;
/// Collected frame counters and backend-specific statistics.
pub const Stats = t.Stats;

/// Maximum color attachment slots in one pass.
pub const max_color_attachments = 8;
/// Maximum vertex-buffer binding slots.
pub const max_vertex_buffers = 8;
/// Maximum attributes in a vertex-input layout.
pub const max_vertex_attributes = 16;
/// Maximum reflected uniform-block slots.
pub const max_uniform_blocks = 8;
/// Maximum shader resource-view slots.
pub const max_views = 32;
/// Maximum shader sampler slots.
pub const max_samplers = 12;
/// Maximum combined GLSL texture/sampler pair declarations.
pub const max_texture_sampler_pairs = 32;
/// Maximum mip levels described by one image.
pub const max_mip_levels = 16;
/// Maximum individually reflected GLSL uniforms per block.
pub const max_uniform_block_members = 16;

// ---------------------------------------------------------------- handles

/// Typed, generation-checked resource handles; `.invalid` is never a live resource.
pub const Buffer = enum(u64) { invalid = 0, _ };
/// Device-owned image handle. The invalid value never names a live resource.
pub const Image = enum(u64) { invalid = 0, _ };
/// Device-owned sampler-state handle.
pub const Sampler = enum(u64) { invalid = 0, _ };
/// Device-owned shader and reflected binding-interface handle.
pub const Shader = enum(u64) { invalid = 0, _ };
/// Device-owned render or compute pipeline handle.
pub const Pipeline = enum(u64) { invalid = 0, _ };
/// Device-owned resource binding or attachment-view handle.
pub const View = enum(u64) { invalid = 0, _ };

fn id(handle: anytype) u32 {
    const value = @backingInt(handle);
    if (value == 0) return 0;
    if (value >> 32 != ctx().identity) return 0;
    return @truncate(value);
}

fn ownedHandle(comptime H: type, raw_id: u32) H {
    if (raw_id == 0) return .invalid;
    return @fromBackingInt((@as(u64, ctx().identity) << 32) | raw_id);
}

// ---------------------------------------------------------------- device setup

/// Graphics API selected for a Device; dummy is intended for tests.
pub const Backend = enum { dummy, vulkan, d3d12, d3d11, metal, wgpu, gl, gles };

/// Diagnostic delivered synchronously while an API operation is validated or executed.
pub const Diagnostic = struct {
    /// Severity of a diagnostic message.
    pub const Level = enum { panic, err, warn, info };
    item: LogItem,
    level: Level,
    /// The message text, available in debug builds.
    message: ?[]const u8,
};

/// Native removal/context-loss code and the identity of the affected Device.
pub const DeviceLoss = struct { device_id: u32, backend: Backend, native_code: i32 };
/// Ready state or the first recorded native device-loss condition.
pub const DeviceStatus = union(enum) { ready, lost: DeviceLoss };

/// Caller-owned native handles and loader callbacks for the selected graphics API.
pub const BackendOptions = union(Backend) {
    /// A backend without a GPU; every operation succeeds and does nothing.
    dummy,
    /// Native device creation must enable dynamic rendering, synchronization2
    /// and buffer device address. Enable supported independentBlend, dualSrcBlend,
    /// samplerAnisotropy and extended storage-image features when using those
    /// operations. Capability queries cannot recover a native device's enabled
    /// feature chain; tools/harness/vulkan.zig shows the creation contract.
    vulkan: struct {
        /// `vkGetInstanceProcAddr` of the loader that created `instance`.
        get_instance_proc_addr: *const anyopaque,
        instance: *const anyopaque,
        physical_device: *const anyopaque,
        device: *const anyopaque,
        queue: *const anyopaque,
        queue_family_index: u32,
        /// Initialization-only serialized cache. Incompatible driver/UUID data
        /// is ignored with a warning. Export updated data with pipelineCacheData.
        pipeline_cache_data: []const u8 = &.{},
        /// Enable only when VK_EXT_descriptor_buffer was enabled at native
        /// device creation. Classic descriptor sets are the portable default.
        use_descriptor_buffer: bool = false,
        /// Maximum descriptor sets per frame in the portable strategy.
        descriptor_set_capacity: u32 = 4096,
        /// Minimum initial-upload chunk size per in-flight frame. Large batches
        /// may use extra chunks; those retire after the frame fence. One normal
        /// chunk per frame is cached for reuse after peak loading bursts.
        copy_staging_buffer_size: u32 = 4 * 1024 * 1024,
        transient_staging_buffer_size: u32 = 16 * 1024 * 1024,
        descriptor_buffer_size: u32 = 16 * 1024 * 1024,
    },
    d3d12: struct {
        device: *const anyopaque,
        queue: *const anyopaque,
    },
    d3d11: struct {
        device: *const anyopaque,
        device_context: *const anyopaque,
        shader_debugging: bool = false,
    },
    metal: struct {
        device: *const anyopaque,
        platform: enum { macos, ios, simulator } = if (builtin.os.tag == .macos) .macos else .ios,
        force_managed_storage_mode: bool = false,
        use_command_buffer_with_retained_references: bool = false,
    },
    wgpu: struct {
        device: *const anyopaque,
        /// Optional native instance, needed by Dawn's future/event polling.
        instance: ?*const anyopaque = null,
        /// Positive values require TimedWaitAny enabled on that instance.
        /// Zero keeps polling non-blocking; use readback tickets without a
        /// native blocking provider. wgpu-native's DevicePoll needs no instance.
        wait_timeout_ns: u64 = 0,
        /// Resolves webgpu.h functions by name. wgpu-native v29's GetProcAddress
        /// is unimplemented: resolve exports with the native loader instead.
        get_proc_address: *const fn (name: [:0]const u8, user_data: ?*anyopaque) ?*const anyopaque,
        user_data: ?*anyopaque = null,
        bindgroups_cache_size: u32 = 1024,
        disable_bindgroups_cache: bool = false,
    },
    gl: GlOptions,
    gles: GlOptions,

    /// Loader for an already-current GL/GLES context. Keep its library alive until Device teardown.
    pub const GlOptions = struct {
        /// Resolves GL functions of the current context. On Windows desktop GL
        /// it may be null, then functions are loaded from opengl32.dll.
        get_proc_address: ?*const fn (name: [:0]const u8, user_data: ?*anyopaque) ?*const anyopaque,
        user_data: ?*anyopaque = null,
    };
};

/// Device creation settings, pool capacities, defaults and diagnostic policy.
pub const Options = struct {
    backend: BackendOptions,
    /// Defaults for swapchain passes and for attachment images and pipelines
    /// that don't specify a format or sample count.
    defaults: struct {
        /// null: BGRA8 on Metal and D3D, RGBA8 elsewhere. Required on WebGPU.
        color_format: ?PixelFormat = null,
        depth_format: PixelFormat = .depth_stencil,
        sample_count: u32 = 1,
    } = .{},
    pools: struct {
        buffers: u16 = 128,
        images: u16 = 128,
        samplers: u16 = 64,
        shaders: u16 = 32,
        pipelines: u16 = 64,
        views: u16 = 256,
    } = .{},
    /// Per-frame storage for uniform data.
    uniform_buffer_size: u32 = 4 * 1024 * 1024,
    max_commit_listeners: u32 = 1024,
    validation: Validation = if (internal_debug) .fatal else .off,
    /// Clamps limits to values that every backend supports.
    portable_limits: bool = false,
    /// Receives diagnostics; null logs them through `std.log` (scope `.zicr`).
    /// Callbacks must not mutate, destroy or reenter this Device.
    diagnostics: ?*const fn (Diagnostic) void = null,
    /// Delivered once on the calling/owning thread by status or the next command.
    /// Do not destroy/reenter this Device from its callback.
    on_device_lost: ?*const fn (DeviceLoss) void = null,

    /// How invalid commands are reported and whether they terminate execution.
    pub const Validation = enum {
        /// No validation (validation code is also compiled out without the
        /// `debug` build option).
        off,
        /// Invalid commands are reported and skipped.
        report,
        /// Invalid commands are reported, then panic. Resource creation
        /// with invalid descriptors returns `error.InvalidDescriptor` instead.
        fatal,
    };
};

const internal_debug = @import("config.zig").debug;

/// Device setup failure; native handles remain owned by the caller.
pub const InitError = error{ OutOfMemory, BackendUnavailable, BackendInitFailed, InvalidOptions };

/// Effective resource and binding limits; values may be clamped by portable_limits.
pub const Limits = struct {
    max_image_size_2d: u32,
    max_image_size_cube: u32,
    max_image_size_3d: u32,
    max_image_size_array: u32,
    max_image_array_layers: u32,
    max_vertex_attrs: u32,
    max_color_attachments: u32,
    max_texture_bindings_per_stage: u32,
    max_storage_buffer_bindings_per_stage: u32,
    max_storage_image_bindings_per_stage: u32,
};

/// Operations supported for a pixel format on this device.
pub const FormatInfo = struct {
    sample: bool,
    filter: bool,
    render: bool,
    blend: bool,
    msaa: bool,
    depth: bool,
    compressed: bool,
    read: bool,
    write: bool,
    /// 0 for compressed formats.
    bytes_per_pixel: u32,
};

/// Resource creation failure, including invalid descriptors, exhausted pools or device loss.
pub const CreateError = error{
    /// The pool of this resource type is full.
    PoolExhausted,
    /// The descriptor failed validation; diagnostics describe why.
    InvalidDescriptor,
    /// The backend could not create the resource.
    CreationFailed,
    /// Recreate the Device and its resources; see Device.status.
    DeviceLost,
};

/// Each Device owns pools, backend state and diagnostics independently.
const Context = struct {
    state: core.State,
    options: Options,
    identity: u32,
    creating: bool = false,
    loss_delivered: bool = false,
};
var next_device_identity: std.atomic.Value(u32) = .init(1);
fn ctx() *Context {
    return @ptrCast(@alignCast(core.state().desc.logger.user_data.?));
}

fn coreLogger(_: ?[*:0]const u8, level: u32, item_id: u32, message: ?[*:0]const u8, _: u32, _: ?[*:0]const u8, userdata: ?*anyopaque) void {
    const c: *Context = @ptrCast(@alignCast(userdata orelse return));
    const item: LogItem = @fromBackingInt(@intCast(item_id));
    const diag: Diagnostic = .{
        .item = item,
        .level = switch (level) {
            0 => .panic,
            1 => .err,
            2 => .warn,
            else => .info,
        },
        .message = if (message) |m| std.mem.span(m) else null,
    };
    if (c.options.diagnostics) |callback| {
        callback(diag);
    } else {
        const scoped = std.log.scoped(.zicr);
        const text = diag.message orelse @tagName(item);
        switch (diag.level) {
            .panic, .err => scoped.err("{s}", .{text}),
            .warn => scoped.warn("{s}", .{text}),
            .info => scoped.info("{s}", .{text}),
        }
    }
    // VALIDATION_FAILED is handled by `validated`; other panic items are fatal
    if (diag.level == .panic and item != .validation_failed) @panic(log_messages.message(item));
}

fn lossDetected() bool {
    const code = core.state().loss_code.load(.acquire);
    if (code == 0) return false;
    const c = ctx();
    if (!c.loss_delivered) {
        c.loss_delivered = true;
        if (c.options.on_device_lost) |callback| callback(.{ .device_id = c.identity, .backend = std.meta.activeTag(c.options.backend), .native_code = code });
    }
    return true;
}

/// Runs a core command and applies the validation policy: in `.fatal` mode a
/// command that failed validation panics after its diagnostics were reported.
inline fn validated(command: anytype, args: anytype) void {
    if (lossDetected()) return;
    const s = core.state();
    s.validate_error = .ok;
    @call(.auto, command, args);
    if (s.validate_error != .ok and ctx().options.validation == .fatal) {
        std.debug.panic("zicr.gpu: validation failed: {s}", .{@tagName(s.validate_error)});
    }
}

/// An independent GPU device with owned backend state and resource pools.
/// Do not copy it. Calls on one Device require external serialization; independent
/// Devices can run on different threads. Shared native handles retain their
/// native API's external-synchronization requirements. GL contexts must be current
/// by the caller before using their Device. Resources belong to their creator.
pub const Device = struct {
    context: *Context,

    fn enter(self: *const Device) core.Scope {
        return core.enter(&self.context.state);
    }
    /// Create independent GPU state around caller-owned native device/context handles.
    pub fn init(allocator: std.mem.Allocator, options: Options) InitError!Device {
        inline for (@typeInfo(@TypeOf(options.pools)).@"struct".field_names) |name| {
            if (@field(options.pools, name) == 0) return error.InvalidOptions;
        }
        if (options.uniform_buffer_size == 0 or options.max_commit_listeners == 0 or options.defaults.sample_count == 0) return error.InvalidOptions;
        var desc: t.Desc = .{
            .buffer_pool_size = options.pools.buffers,
            .image_pool_size = options.pools.images,
            .sampler_pool_size = options.pools.samplers,
            .shader_pool_size = options.pools.shaders,
            .pipeline_pool_size = options.pools.pipelines,
            .view_pool_size = options.pools.views,
            .uniform_buffer_size = std.math.cast(i32, options.uniform_buffer_size) orelse return error.InvalidOptions,
            .max_commit_listeners = std.math.cast(i32, options.max_commit_listeners) orelse return error.InvalidOptions,
            .disable_validation = options.validation == .off,
            .enforce_portable_limits = options.portable_limits,
            .logger = .{ .func = coreLogger },
        };
        desc.environment.defaults = .{
            .color_format = optionalEnum(e.PixelFormat, options.defaults.color_format),
            .depth_format = enumCast(e.PixelFormat, options.defaults.depth_format),
            .sample_count = std.math.cast(i32, options.defaults.sample_count) orelse return error.InvalidOptions,
        };
        const kind: e.Backend = switch (options.backend) {
            .dummy => .dummy,
            .vulkan => |vk| blk: {
                desc.environment.vulkan = .{
                    .instance = vk.instance,
                    .physical_device = vk.physical_device,
                    .device = vk.device,
                    .queue = vk.queue,
                    .queue_family_index = vk.queue_family_index,
                    .get_instance_proc_addr = vk.get_instance_proc_addr,
                };
                desc.vulkan = .{
                    .pipeline_cache_data = rangeOf(vk.pipeline_cache_data),
                    .use_descriptor_buffer = vk.use_descriptor_buffer,
                    .descriptor_set_capacity = vk.descriptor_set_capacity,
                    .copy_staging_buffer_size = std.math.cast(i32, vk.copy_staging_buffer_size) orelse return error.InvalidOptions,
                    .transient_staging_buffer_size = std.math.cast(i32, vk.transient_staging_buffer_size) orelse return error.InvalidOptions,
                    .descriptor_buffer_size = std.math.cast(i32, vk.descriptor_buffer_size) orelse return error.InvalidOptions,
                };
                break :blk .vulkan;
            },
            .d3d12 => |dx| blk: {
                desc.environment.d3d12 = .{ .device = dx.device, .queue = dx.queue };
                break :blk .d3d12;
            },
            .d3d11 => |dx| blk: {
                desc.environment.d3d11 = .{ .device = dx.device, .device_context = dx.device_context };
                desc.d3d11.shader_debugging = dx.shader_debugging;
                break :blk .d3d11;
            },
            .metal => |mtl| blk: {
                desc.environment.metal = .{ .device = mtl.device };
                desc.metal = .{ .force_managed_storage_mode = mtl.force_managed_storage_mode, .use_command_buffer_with_retained_references = mtl.use_command_buffer_with_retained_references };
                break :blk switch (mtl.platform) {
                    .macos => .metal_macos,
                    .ios => .metal_ios,
                    .simulator => .metal_simulator,
                };
            },
            .wgpu => |wgpu| blk: {
                if (options.defaults.color_format == null) return error.InvalidOptions;
                desc.environment.wgpu = .{ .instance = wgpu.instance, .wait_timeout_ns = wgpu.wait_timeout_ns, .device = wgpu.device, .get_proc_address = wgpu.get_proc_address, .user_data = wgpu.user_data };
                desc.wgpu = .{ .bindgroups_cache_size = std.math.cast(i32, wgpu.bindgroups_cache_size) orelse return error.InvalidOptions, .disable_bindgroups_cache = wgpu.disable_bindgroups_cache };
                break :blk .wgpu;
            },
            .gl, .gles => |gl| blk: {
                desc.environment.gl = .{ .get_proc_address = gl.get_proc_address, .user_data = gl.user_data };
                break :blk if (options.backend == .gl) .glcore else .gles3;
            },
        };
        const context = try allocator.create(Context);
        errdefer allocator.destroy(context);
        const identity = next_device_identity.fetchAdd(1, .monotonic);
        if (identity == 0) @panic("zicr.gpu: device identity exhausted");
        context.* = .{ .state = undefined, .options = options, .identity = identity };
        desc.logger.user_data = context;
        @import("api.zig").initState(&context.state, allocator, kind, desc) catch |err| return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            error.BackendNotPorted, error.MetalNotAvailable => error.BackendUnavailable,
            error.InvalidPoolSize, error.InvalidListenerCapacity, error.UseZigAllocator => error.InvalidOptions,
            else => error.BackendInitFailed,
        };
        return .{ .context = context };
    }

    /// Drain pending work and release owned GPU resources. Release readback tickets first.
    pub fn deinit(self: *Device) void {
        const context = self.context;
        const allocator = context.state.allocator;
        @import("api.zig").deinitState(&context.state);
        allocator.destroy(context);
        self.* = undefined;
    }

    /// Poll removal status without waiting for the GPU. Once lost, resource
    /// creation fails and commands are skipped. To recover, release readbacks,
    /// deinit this Device, recreate the native device and rebuild GPU resources
    /// from CPU descriptors/data. New Device identities reject every old handle.
    pub fn status(self: *const Device) DeviceStatus {
        const scope = self.enter();
        defer scope.end();
        @import("backend.zig").pollDeviceLoss();
        if (!lossDetected()) return .ready;
        return .{ .lost = .{ .device_id = self.context.identity, .backend = std.meta.activeTag(self.context.options.backend), .native_code = self.context.state.loss_code.load(.acquire) } };
    }

    /// Forward host-owned WebGPU device.lost / WebGL context-loss events here.
    /// Thread-safe while this Device remains alive; callback delivery is deferred
    /// to status/commands on its owning thread. A zero code is normalized to -1.
    pub fn notifyLost(self: *const Device, native_code: i32) void {
        _ = self.context.state.loss_code.cmpxchgStrong(0, if (native_code == 0) -1 else native_code, .acq_rel, .acquire);
    }

    /// Allocates a serialized Vulkan pipeline cache for persistence by the app.
    /// Bytes are driver/device specific; initialization ignores incompatible data.
    pub fn pipelineCacheData(self: *const Device, allocator: std.mem.Allocator) (std.mem.Allocator.Error || error{ UnsupportedBackend, DriverError })![]u8 {
        const scope = self.enter();
        defer scope.end();
        if (self.context.state.impl != .vulkan) return error.UnsupportedBackend;
        return @import("backends/vulkan/pipeline_cache.zig").data(&self.context.state.impl.vulkan, allocator);
    }

    /// Return the selected backend.
    pub fn backend(self: *const Device) Backend {
        const device_scope = self.enter();
        defer device_scope.end();
        return switch (internal.queryBackend()) {
            .glcore => .gl,
            .gles3 => .gles,
            .d3d11 => .d3d11,
            .d3d12 => .d3d12,
            .metal_ios, .metal_macos, .metal_simulator => .metal,
            .wgpu => .wgpu,
            .vulkan => .vulkan,
            else => .dummy,
        };
    }

    /// Return backend capabilities. Vulkan callers must honor the native-device
    /// feature-enablement contract in BackendOptions before using optional paths.
    pub fn features(self: *const Device) Features {
        const device_scope = self.enter();
        defer device_scope.end();
        return internal.queryFeatures();
    }

    /// Return effective device limits, including optional portable limits.
    pub fn limits(self: *const Device) Limits {
        const device_scope = self.enter();
        defer device_scope.end();
        const l = internal.queryLimits();
        var res: Limits = undefined;
        inline for (@typeInfo(Limits).@"struct".field_names) |name| @field(res, name) = @intCast(@max(@field(l, name), 0));
        return res;
    }

    /// Return support for sampling, rendering and storage in a pixel format.
    pub fn formatInfo(self: *const Device, format: PixelFormat) FormatInfo {
        const device_scope = self.enter();
        defer device_scope.end();
        std.debug.assert(format != .none);
        const info = internal.queryPixelformat(enumCast(e.PixelFormat, format));
        return .{
            .sample = info.sample,
            .filter = info.filter,
            .render = info.render,
            .blend = info.blend,
            .msaa = info.msaa,
            .depth = info.depth,
            .compressed = info.compressed,
            .read = info.read,
            .write = info.write,
            .bytes_per_pixel = @intCast(info.bytes_per_pixel),
        };
    }

    /// Statistics of the previous frame and resource totals.
    pub fn stats(self: *const Device) Stats {
        const device_scope = self.enter();
        defer device_scope.end();
        return internal.queryStats();
    }

    /// Enable or disable collection of frame counters.
    pub fn setStatsEnabled(self: *Device, enabled: bool) void {
        const device_scope = self.enter();
        defer device_scope.end();
        if (enabled) internal.enableStats() else internal.disableStats();
    }

    /// Resets the backend's state cache after native rendering code changed the
    /// API state behind the device's back.
    pub fn resetStateCache(self: *Device) void {
        const device_scope = self.enter();
        defer device_scope.end();
        internal.resetStateCache();
    }

    // ------------------------------------------------------------ resources

    /// Create a device-owned buffer, copying initialization data before returning.
    pub fn createBuffer(self: *Device, desc: BufferDesc) CreateError!Buffer {
        const device_scope = self.enter();
        defer device_scope.end();
        return create(Buffer, internal.makeBuffer, desc.toInternal());
    }

    /// Create a device-owned image from its dimensions, format and initial data.
    pub fn createImage(self: *Device, desc: ImageDesc) CreateError!Image {
        const device_scope = self.enter();
        defer device_scope.end();
        return create(Image, internal.makeImage, desc.toInternal());
    }

    /// Create sampling/filter/address state.
    pub fn createSampler(self: *Device, desc: SamplerDesc) CreateError!Sampler {
        const device_scope = self.enter();
        defer device_scope.end();
        return create(Sampler, internal.makeSampler, desc.toInternal());
    }

    /// Create shader functions and their reflected binding interface.
    pub fn createShader(self: *Device, desc: ShaderDesc) CreateError!Shader {
        const device_scope = self.enter();
        defer device_scope.end();
        return create(Shader, internal.makeShader, desc.toInternal());
    }

    /// Create render or compute pipeline state compatible with its shader.
    pub fn createPipeline(self: *Device, desc: PipelineDesc) CreateError!Pipeline {
        const device_scope = self.enter();
        defer device_scope.end();
        return create(Pipeline, internal.makePipeline, desc.toInternal());
    }

    /// Create a typed resource binding or image attachment view.
    pub fn createView(self: *Device, desc: ViewDesc) CreateError!View {
        const device_scope = self.enter();
        defer device_scope.end();
        return create(View, internal.makeView, desc.toInternal());
    }

    /// Destroys a resource of any kind; invalid and stale handles are ignored.
    pub fn destroy(self: *Device, handle: anytype) void {
        const device_scope = self.enter();
        defer device_scope.end();
        const raw_id = id(handle);
        switch (@TypeOf(handle)) {
            Buffer => internal.destroyBuffer(.{ .id = raw_id }),
            Image => internal.destroyImage(.{ .id = raw_id }),
            Sampler => internal.destroySampler(.{ .id = raw_id }),
            Shader => internal.destroyShader(.{ .id = raw_id }),
            Pipeline => internal.destroyPipeline(.{ .id = raw_id }),
            View => internal.destroyView(.{ .id = raw_id }),
            else => @compileError("not a resource handle: " ++ @typeName(@TypeOf(handle))),
        }
    }

    /// The state of a resource; `.invalid` for invalid or stale handles.
    pub fn state(self: *const Device, handle: anytype) ResourceState {
        const device_scope = self.enter();
        defer device_scope.end();
        const raw_id = id(handle);
        const s = switch (@TypeOf(handle)) {
            Buffer => internal.queryBufferState(.{ .id = raw_id }),
            Image => internal.queryImageState(.{ .id = raw_id }),
            Sampler => internal.querySamplerState(.{ .id = raw_id }),
            Shader => internal.queryShaderState(.{ .id = raw_id }),
            Pipeline => internal.queryPipelineState(.{ .id = raw_id }),
            View => internal.queryViewState(.{ .id = raw_id }),
            else => @compileError("not a resource handle: " ++ @typeName(@TypeOf(handle))),
        };
        return @fromBackingInt(@intCast(@backingInt(s)));
    }

    /// Return buffer metadata, or null for an invalid or foreign handle.
    pub fn bufferInfo(self: *const Device, buffer: Buffer) ?BufferInfo {
        const device_scope = self.enter();
        defer device_scope.end();
        const buf = core.lookupBuffer(id(buffer)) orelse return null;
        return .{
            .state = @fromBackingInt(@intCast(@backingInt(buf.slot.state))),
            .size = buf.cmn.size,
            .usage = .fromInternal(buf.cmn.usage),
            .num_slots = @intCast(buf.cmn.num_slots),
            .active_slot = @intCast(buf.cmn.active_slot),
        };
    }

    /// Return image metadata, or null for an invalid or foreign handle.
    pub fn imageInfo(self: *const Device, image: Image) ?ImageInfo {
        const device_scope = self.enter();
        defer device_scope.end();
        const img = core.lookupImage(id(image)) orelse return null;
        return .{
            .state = @fromBackingInt(@intCast(@backingInt(img.slot.state))),
            .type = @fromBackingInt(@intCast(@backingInt(img.cmn.type))),
            .usage = .fromInternal(img.cmn.usage),
            .width = @intCast(@max(img.cmn.width, 0)),
            .height = @intCast(@max(img.cmn.height, 0)),
            .slices = @intCast(@max(img.cmn.num_slices, 0)),
            .mip_levels = @intCast(@max(img.cmn.num_mipmaps, 0)),
            .format = @fromBackingInt(@intCast(@backingInt(img.cmn.pixel_format))),
            .sample_count = @intCast(@max(img.cmn.sample_count, 0)),
        };
    }

    /// Return view metadata with handles owned by this Device, or null if invalid.
    pub fn viewInfo(self: *const Device, view: View) ?ViewInfo {
        const device_scope = self.enter();
        defer device_scope.end();
        const v = core.lookupView(id(view)) orelse return null;
        return .{
            .state = @fromBackingInt(@intCast(@backingInt(v.slot.state))),
            .type = @fromBackingInt(@intCast(@backingInt(v.cmn.type))),
            .buffer = ownedHandle(Buffer, v.cmn.buf.ref.sref.id),
            .image = ownedHandle(Image, v.cmn.img.ref.sref.id),
        };
    }

    // ------------------------------------------------------------ data transfers

    /// Writes into a buffer: before `seal` for buffers created with
    /// `.writes = .unsealed`, else once per frame for `.writes = .transient`.
    pub fn writeBuffer(self: *Device, buffer: Buffer, offset: usize, data: []const u8) void {
        const device_scope = self.enter();
        defer device_scope.end();
        const desc: t.WriteBufferDesc = .{ .src = .{ .data = rangeOf(data) }, .dst = .{ .buffer = .{ .id = id(buffer) }, .offset = offset }, .size = data.len };
        if (core.lookupBuffer(id(buffer))) |buf| if (buf.slot.state == .unsealed) return validated(internal.writeBufferUnsealed, .{desc});
        validated(internal.writeBufferTransient, .{desc});
    }

    /// Writes a region of an image, see `writeBuffer` for when writes are allowed.
    pub fn writeImage(self: *Device, image: Image, region: ImageRegion, data: []const u8, layout: DataLayout) void {
        const device_scope = self.enter();
        defer device_scope.end();
        const transfer = resolveTransfer(image, region, layout);
        const desc: t.WriteImageDesc = .{
            .src = .{ .data = rangeOf(data), .bytes_per_row = transfer.bytes_per_row, .bytes_per_slice = transfer.bytes_per_slice },
            .dst = region.location(image),
            .size = transfer.extent,
        };
        if (core.lookupImage(id(image))) |img| if (img.slot.state == .unsealed) return validated(internal.writeImageUnsealed, .{desc});
        validated(internal.writeImageTransient, .{desc});
    }

    /// Unsealed resources are CPU initialization resources: draws that bind them
    /// are skipped until they are sealed.
    /// Ends the unsealed phase of a buffer or image created with `.writes = .unsealed`.
    pub fn seal(self: *Device, handle: anytype) void {
        const device_scope = self.enter();
        defer device_scope.end();
        switch (@TypeOf(handle)) {
            Buffer => validated(internal.sealBuffer, .{t.Buffer{ .id = id(handle) }}),
            Image => validated(internal.sealImage, .{t.Image{ .id = id(handle) }}),
            else => @compileError("only buffers and images can be sealed"),
        }
    }

    /// Record a byte-range copy between buffers with matching copy usages.
    pub fn copyBuffer(self: *Device, copy: BufferCopy) void {
        const device_scope = self.enter();
        defer device_scope.end();
        validated(internal.copyBufferToBuffer, .{t.CopyBufferToBufferDesc{
            .src = .{ .buffer = .{ .id = id(copy.src) }, .offset = copy.src_offset },
            .dst = .{ .buffer = .{ .id = id(copy.dst) }, .offset = copy.dst_offset },
            .size = copy.size,
        }});
    }

    /// Record a buffer-to-image region copy using the supplied row and slice layout.
    pub fn copyBufferToImage(self: *Device, copy: BufferToImageCopy) void {
        const device_scope = self.enter();
        defer device_scope.end();
        const transfer = resolveTransfer(copy.dst, copy.region, copy.layout);
        validated(internal.copyBufferToImage, .{t.CopyBufferToImageDesc{
            .src = .{ .buffer = .{ .id = id(copy.src) }, .offset = copy.src_offset, .bytes_per_row = transfer.bytes_per_row, .bytes_per_slice = transfer.bytes_per_slice },
            .dst = copy.region.location(copy.dst),
            .size = transfer.extent,
        }});
    }

    // ------------------------------------------------------------ readback

    /// Waits for all committed GPU work, then copies `out.len` bytes of a buffer
    /// starting at `offset`. Call outside of passes, typically after `commit`;
    /// the buffer needs `usage.copy_src`.
    pub fn readBuffer(self: *Device, buffer: Buffer, offset: usize, out: []u8) ReadError!void {
        const device_scope = self.enter();
        defer device_scope.end();
        if (!readChecked(internal.readBuffer, .{ t.Buffer{ .id = id(buffer) }, offset, out })) return error.ReadFailed;
    }

    /// Waits for all committed GPU work, then copies a region of an image into
    /// `out`, in the row order of the image's storage (on GL, rendered images
    /// have their first row at the bottom, see `Features.origin_top_left`).
    /// The image needs `usage.copy_src`; compressed, depth and multisampled
    /// images can't be read.
    pub fn readImage(self: *Device, image: Image, region: ImageRegion, out: []u8, layout: DataLayout) ReadError!void {
        const device_scope = self.enter();
        defer device_scope.end();
        const desc: internal.ReadImageDesc = .{
            .image = .{ .id = id(image) },
            .mip_level = region.mip_level,
            .x = region.x,
            .y = region.y,
            .slice = region.slice,
            .width = region.width orelse 0,
            .height = region.height orelse 0,
            .num_slices = region.slices orelse 0,
            .bytes_per_row = layout.bytes_per_row orelse 0,
            .bytes_per_slice = layout.bytes_per_slice orelse 0,
        };
        if (!readChecked(internal.readImage, .{ desc, out })) return error.ReadFailed;
    }

    /// Copies a buffer into an owned readback ticket. WebGPU submits committed
    /// work and schedules mapping without blocking; the source may then be destroyed.
    pub fn requestReadBuffer(self: *Device, buffer: Buffer, offset: usize, size: usize) (ReadError || std.mem.Allocator.Error)!Readback {
        const device_scope = self.enter();
        defer device_scope.end();
        if (lossDetected()) return error.ReadFailed;
        const context_ptr = ctx();
        context_ptr.creating = true;
        defer context_ptr.creating = false;
        const allocator = core.state().allocator;
        const buf = core.lookupBuffer(id(buffer)) orelse return error.ReadFailed;
        if (buf.slot.state != .valid) return error.ReadFailed;
        if (!@import("validation.zig").readBuffer(buf, offset, size)) return error.ReadFailed;
        if (size == 0 or offset > buf.cmn.size or size > buf.cmn.size - offset or !buf.cmn.usage.copy_src or core.state().cur_pass.in_pass) return error.ReadFailed;
        const data = try allocator.alloc(u8, size);
        errdefer allocator.free(data);
        if (core.state().impl == .wgpu and buf.native.wgpu.staging == null) {
            const pending = core.state().impl.wgpu.requestBufferRead(buf, offset, data) orelse return error.ReadFailed;
            return .{ .allocator = allocator, .data = data, .pending = pending };
        }
        if (core.state().impl == .gl and buf.native.gl.staging == null) {
            try @import("readback_task.zig").prepare(core.state());
            const task = @import("backends/gl/readback.zig").buffer(&core.state().impl.gl, buf, offset, data) orelse return error.ReadFailed;
            @import("readback_task.zig").register(core.state(), task);
            return .{ .allocator = allocator, .data = data, .native_task = task };
        }
        if (core.state().impl == .metal) {
            try @import("readback_task.zig").prepare(core.state());
            const task = @import("backends/metal/commands.zig").requestBufferRead(&core.state().impl.metal, buf, offset, data) orelse return error.ReadFailed;
            @import("readback_task.zig").register(core.state(), task);
            return .{ .allocator = allocator, .data = data, .native_task = task };
        }
        if (core.state().impl == .d3d11 and buf.native.d3d11.staging == null) {
            try @import("readback_task.zig").prepare(core.state());
            const task = @import("backends/d3d11/readback.zig").buffer(&core.state().impl.d3d11, buf, offset, data) orelse return error.ReadFailed;
            @import("readback_task.zig").register(core.state(), task);
            return .{ .allocator = allocator, .data = data, .native_task = task };
        }
        if (core.state().impl == .d3d12 and buf.native.d3d12.staging == null) {
            try @import("readback_task.zig").prepare(core.state());
            const task = @import("backends/d3d12/commands.zig").requestBufferRead(&core.state().impl.d3d12, buf, offset, data) orelse return error.ReadFailed;
            @import("readback_task.zig").register(core.state(), task);
            return .{ .allocator = allocator, .data = data, .native_task = task };
        }
        if (core.state().impl == .vulkan) {
            try @import("readback_task.zig").prepare(core.state());
            const task = core.state().impl.vulkan.requestBufferRead(buf, offset, data) orelse return error.ReadFailed;
            @import("readback_task.zig").register(core.state(), task);
            return .{ .allocator = allocator, .data = data, .native_task = task };
        }
        try self.readBuffer(buffer, offset, data);
        return .{ .allocator = allocator, .data = data };
    }

    /// Image equivalent of requestReadBuffer. Pitches have the same meaning as
    /// readImage. Padding bytes are initialized to zero; no destination is borrowed.
    pub fn requestReadImage(self: *Device, image: Image, region: ImageRegion, layout: DataLayout) (ReadError || std.mem.Allocator.Error)!Readback {
        const device_scope = self.enter();
        defer device_scope.end();
        if (lossDetected()) return error.ReadFailed;
        const context_ptr = ctx();
        context_ptr.creating = true;
        defer context_ptr.creating = false;
        const img = core.lookupImage(id(image)) orelse return error.ReadFailed;
        if (img.slot.state != .valid or region.mip_level >= img.cmn.num_mipmaps) return error.ReadFailed;
        const mip: i32 = @intCast(region.mip_level);
        const width: usize = @intCast(core.miplevelDim(img.cmn.width, mip));
        const height: usize = @intCast(core.miplevelDim(img.cmn.height, mip));
        const slices: usize = @intCast(if (img.cmn.type == .@"3d") core.miplevelDim(img.cmn.num_slices, mip) else img.cmn.num_slices);
        if (region.x >= width or region.y >= height or region.slice >= slices) return error.ReadFailed;
        const w = region.width orelse (width - region.x);
        const h = region.height orelse (height - region.y);
        const n = region.slices orelse (slices - region.slice);
        const bpp: usize = @intCast(@import("formats.zig").pixelSize(img.cmn.pixel_format));
        if (w == 0 or h == 0 or n == 0 or w > width - region.x or h > height - region.y or n > slices - region.slice or bpp == 0 or img.cmn.sample_count != 1 or !img.cmn.usage.copy_src or core.state().cur_pass.in_pass) return error.ReadFailed;
        if (@import("formats.zig").isCompressed(img.cmn.pixel_format) or core.isDepthOrDepthStencilFormat(img.cmn.pixel_format)) return error.ReadFailed;
        const row = std.math.mul(usize, w, bpp) catch return error.ReadFailed;
        const row_pitch = layout.bytes_per_row orelse row;
        const minimum_slice = std.math.mul(usize, row_pitch, h) catch return error.ReadFailed;
        const slice_pitch = layout.bytes_per_slice orelse minimum_slice;
        if (row_pitch < row or slice_pitch < minimum_slice) return error.ReadFailed;
        const last_slice = std.math.mul(usize, n - 1, slice_pitch) catch return error.ReadFailed;
        const last_row = std.math.mul(usize, h - 1, row_pitch) catch return error.ReadFailed;
        const size = std.math.add(usize, last_slice, std.math.add(usize, last_row, row) catch return error.ReadFailed) catch return error.ReadFailed;
        const desc: internal.ReadImageDesc = .{ .image = .{ .id = id(image) }, .mip_level = region.mip_level, .x = region.x, .y = region.y, .slice = region.slice, .width = @intCast(w), .height = @intCast(h), .num_slices = @intCast(n), .bytes_per_row = row_pitch, .bytes_per_slice = slice_pitch };
        const resolved = @import("api.zig").resolveReadImage(desc, size) orelse return error.ReadFailed;
        const allocator = core.state().allocator;
        const data = try allocator.alloc(u8, size);
        errdefer allocator.free(data);
        @memset(data, 0);
        if (core.state().impl == .wgpu) {
            const pending = core.state().impl.wgpu.requestImageRead(resolved.image, &resolved.region, data) orelse return error.ReadFailed;
            return .{ .allocator = allocator, .data = data, .pending = pending };
        }
        if (core.state().impl == .gl) {
            try @import("readback_task.zig").prepare(core.state());
            const task = @import("backends/gl/readback.zig").image(&core.state().impl.gl, resolved.image, &resolved.region, data) orelse return error.ReadFailed;
            @import("readback_task.zig").register(core.state(), task);
            return .{ .allocator = allocator, .data = data, .native_task = task };
        }
        if (core.state().impl == .metal) {
            try @import("readback_task.zig").prepare(core.state());
            const task = @import("backends/metal/commands.zig").requestImageRead(&core.state().impl.metal, resolved.image, &resolved.region, data) orelse return error.ReadFailed;
            @import("readback_task.zig").register(core.state(), task);
            return .{ .allocator = allocator, .data = data, .native_task = task };
        }
        if (core.state().impl == .d3d11) {
            try @import("readback_task.zig").prepare(core.state());
            const task = @import("backends/d3d11/readback.zig").image(&core.state().impl.d3d11, resolved.image, &resolved.region, data) orelse return error.ReadFailed;
            @import("readback_task.zig").register(core.state(), task);
            return .{ .allocator = allocator, .data = data, .native_task = task };
        }
        if (core.state().impl == .d3d12) {
            try @import("readback_task.zig").prepare(core.state());
            const task = @import("backends/d3d12/commands.zig").requestImageRead(&core.state().impl.d3d12, resolved.image, &resolved.region, data) orelse return error.ReadFailed;
            @import("readback_task.zig").register(core.state(), task);
            return .{ .allocator = allocator, .data = data, .native_task = task };
        }
        if (core.state().impl == .vulkan) {
            try @import("readback_task.zig").prepare(core.state());
            const task = core.state().impl.vulkan.requestImageRead(resolved.image, &resolved.region, data) orelse return error.ReadFailed;
            @import("readback_task.zig").register(core.state(), task);
            return .{ .allocator = allocator, .data = data, .native_task = task };
        }
        try self.readImage(image, region, data, layout);
        return .{ .allocator = allocator, .data = data };
    }

    // ------------------------------------------------------------ passes and frames

    /// Begin a render pass with attachment views or a caller-owned swapchain image.
    pub fn beginPass(self: *Device, desc: PassDesc) Pass {
        const device_scope = self.enter();
        defer device_scope.end();
        validated(internal.beginPass, .{desc.toInternal()});
        return .{ .device = self };
    }

    /// Begin a compute pass; end it before committing or starting another pass.
    pub fn beginComputePass(self: *Device, label: ?[:0]const u8) Pass {
        const device_scope = self.enter();
        defer device_scope.end();
        validated(internal.beginPass, .{t.Pass{ .compute = true, .label = if (label) |l| l.ptr else null }});
        return .{ .device = self };
    }

    /// Finishes the frame: submits recorded work and advances to the next frame.
    pub fn commit(self: *Device) void {
        const device_scope = self.enter();
        defer device_scope.end();
        @import("backend.zig").pollDeviceLoss();
        if (lossDetected()) return;
        internal.commit();
        @import("readback_task.zig").collect(core.state(), false);
        _ = lossDetected();
    }

    /// Calls `listener` at every commit; returns false if it is already
    /// registered or the listener capacity is exhausted.
    pub fn addCommitListener(self: *Device, listener: CommitListener) bool {
        const device_scope = self.enter();
        defer device_scope.end();
        return internal.addCommitListener(.{ .func = listener.func, .user_data = listener.user_data });
    }

    /// Remove a previously registered listener; return whether it was present.
    pub fn removeCommitListener(self: *Device, listener: CommitListener) bool {
        const device_scope = self.enter();
        defer device_scope.end();
        return internal.removeCommitListener(.{ .func = listener.func, .user_data = listener.user_data });
    }

    /// Begin a named native GPU debug group where the backend supports it.
    pub fn pushDebugGroup(self: *Device, name: [:0]const u8) void {
        const device_scope = self.enter();
        defer device_scope.end();
        internal.pushDebugGroup(name.ptr);
    }

    /// End the most recently pushed native GPU debug group.
    pub fn popDebugGroup(self: *Device) void {
        const device_scope = self.enter();
        defer device_scope.end();
        internal.popDebugGroup();
    }
};

fn create(comptime H: type, comptime make: anytype, desc: anytype) CreateError!H {
    if (lossDetected()) return error.DeviceLost;
    const c = ctx();
    const s = core.state();
    s.validate_error = .ok;
    c.creating = true;
    defer c.creating = false;
    const handle = make(desc);
    if (handle.id == 0) return error.PoolExhausted;
    const res_state = switch (H) {
        Buffer => internal.queryBufferState(handle),
        Image => internal.queryImageState(handle),
        Sampler => internal.querySamplerState(handle),
        Shader => internal.queryShaderState(handle),
        Pipeline => internal.queryPipelineState(handle),
        View => internal.queryViewState(handle),
        else => unreachable,
    };
    if ((res_state == .valid or res_state == .unsealed) and !lossDetected()) return ownedHandle(H, handle.id);
    const invalid = s.validate_error != .ok;
    switch (H) {
        Buffer => internal.destroyBuffer(handle),
        Image => internal.destroyImage(handle),
        Sampler => internal.destroySampler(handle),
        Shader => internal.destroyShader(handle),
        Pipeline => internal.destroyPipeline(handle),
        View => internal.destroyView(handle),
        else => unreachable,
    }
    if (lossDetected()) return error.DeviceLost;
    return if (invalid) error.InvalidDescriptor else error.CreationFailed;
}

/// Owned readback ticket. Do not copy it. Poll and deinit on the device's owning
/// thread, and release all tickets before destroying the device or native loader.
/// GPU-backed requests enqueue work and poll fences/maps without waiting. CPU
/// staging/dummy buffers may complete immediately. Cancellation retires GPU
/// resources only after their completion signal.
pub const Readback = struct {
    allocator: std.mem.Allocator,
    data: []u8,
    pending: ?*@import("backends/wgpu/readback.zig").Pending = null,
    native_task: ?*@import("readback_task.zig").Task = null,

    /// null means not ready: return to the browser event loop before polling again.
    /// Ready bytes remain valid until deinit, including across repeated polls.
    pub fn poll(self: *Readback) ReadError!?[]const u8 {
        if (self.pending) |pending| return pending.poll();
        if (self.native_task) |task| {
            const scope = core.enter(task.owner);
            defer scope.end();
            if (!try task.poll(false)) return null;
        }
        return self.data;
    }

    /// Cancelling a pending ticket is safe; its callback retains the mapping state.
    pub fn deinit(self: *Readback) void {
        if (self.pending) |pending| pending.release() else if (self.native_task) |task| {
            const scope = core.enter(task.owner);
            defer scope.end();
            task.release();
        } else self.allocator.free(self.data);
        self.* = undefined;
    }
};

/// A rejected or failed readback operation; diagnostics provide further details.
pub const ReadError = error{
    /// The read was rejected (see diagnostics) or the backend failed to read.
    ReadFailed,
};

/// Like `validated`, but a rejected read returns an error in every mode.
fn readChecked(comptime read: anytype, args: anytype) bool {
    if (lossDetected()) return false;
    const c = ctx();
    c.creating = true;
    defer c.creating = false;
    return @call(.auto, read, args);
}

/// Callback invoked by commit; its userdata must remain valid while registered.
pub const CommitListener = struct {
    func: *const fn (user_data: ?*anyopaque) void,
    user_data: ?*anyopaque = null,
};

// ---------------------------------------------------------------- conversions

fn enumCast(comptime T: type, value: anytype) T {
    return @fromBackingInt(@intCast(@backingInt(value)));
}

/// Maps null to the internal "default" (zero) value.
fn optionalEnum(comptime T: type, value: anytype) T {
    return if (value) |v| enumCast(T, v) else @fromBackingInt(@intCast(0));
}

fn int(value: anytype) i32 {
    return std.math.cast(i32, value) orelse std.math.maxInt(i32);
}

fn optionalInt(value: anytype) i32 {
    return if (value) |v| int(v) else 0;
}

fn rangeOf(data: []const u8) t.Range {
    return .{ .ptr = if (data.len == 0) null else data.ptr, .size = data.len };
}

fn labelOf(label: ?[:0]const u8) ?[*:0]const u8 {
    return if (label) |l| l.ptr else null;
}

// ---------------------------------------------------------------- buffers

/// How a buffer or image gets its content.
pub const Writes = enum {
    /// Initialized with data at creation (or by GPU writes for storage resources).
    immutable,
    /// Written with `Device.writeBuffer`/`writeImage` until `Device.seal`.
    unsealed,
    /// Rewritten at most once per frame with `Device.writeBuffer`/`writeImage`.
    transient,
    /// Written by GPU copies (`copyBuffer`/`copyBufferToImage`).
    copy,
};

/// Buffer roles and write policy, fixed when the buffer is created.
pub const BufferUsage = struct {
    vertex: bool = false,
    index: bool = false,
    storage: bool = false,
    /// A CPU-side source for copies to GPU buffers and images.
    staging: bool = false,
    /// A staging buffer whose content is copied into index buffers.
    staging_index: bool = false,
    copy_src: bool = false,
    writes: Writes = .immutable,

    fn toInternal(self: BufferUsage) t.BufferUsage {
        return .{
            .vertex_buffer = self.vertex,
            .index_buffer = self.index,
            .storage_buffer = self.storage,
            .staging_buffer = self.staging,
            .staging_index_buffer = self.staging_index,
            .write_unsealed = self.writes == .unsealed,
            .write_transient = self.writes == .transient,
            .copy_src = self.copy_src,
            .copy_dst = self.writes == .copy,
        };
    }

    fn fromInternal(u: t.BufferUsage) BufferUsage {
        return .{
            .vertex = u.vertex_buffer,
            .index = u.index_buffer,
            .storage = u.storage_buffer,
            .staging = u.staging_buffer,
            .staging_index = u.staging_index_buffer,
            .copy_src = u.copy_src,
            .writes = if (u.write_unsealed) .unsealed else if (u.write_transient) .transient else if (u.copy_dst) .copy else .immutable,
        };
    }
};

/// A native object to adopt instead of creating one.
pub const NativeObject = union(enum) {
    gl: u32,
    metal: *const anyopaque,
    d3d11: *const anyopaque,
    wgpu: *const anyopaque,
};

/// Buffer size, initial bytes, usage and optional injected native storage.
pub const BufferDesc = struct {
    /// Without any of vertex/index/storage/staging, a vertex buffer.
    usage: BufferUsage = .{},
    /// null: the size of `data`.
    size: ?usize = null,
    data: ?[]const u8 = null,
    label: ?[:0]const u8 = null,
    native: ?NativeObject = null,

    fn toInternal(self: BufferDesc) t.BufferDesc {
        var res: t.BufferDesc = .{
            .size = self.size orelse 0,
            .usage = self.usage.toInternal(),
            .data = if (self.data) |d| rangeOf(d) else .{},
            .label = labelOf(self.label),
        };
        if (self.native) |n| switch (n) {
            .gl => |b| res.gl_buffer = b,
            .metal => |b| res.mtl_buffer = b,
            .d3d11 => |b| res.d3d11_buffer = b,
            .wgpu => |b| res.wgpu_buffer = b,
        };
        return res;
    }
};

/// Buffer lifecycle and effective creation properties.
pub const BufferInfo = struct {
    state: ResourceState,
    size: usize,
    usage: BufferUsage,
    num_slots: u32,
    active_slot: u32,
};

/// Source/destination byte ranges for a GPU buffer copy.
pub const BufferCopy = struct {
    src: Buffer,
    src_offset: usize = 0,
    dst: Buffer,
    dst_offset: usize = 0,
    size: usize,
};

// ---------------------------------------------------------------- images

/// Image sampling, attachment, storage, copy and write roles.
pub const ImageUsage = struct {
    storage: bool = false,
    color_attachment: bool = false,
    resolve_attachment: bool = false,
    depth_stencil_attachment: bool = false,
    copy_src: bool = false,
    writes: Writes = .immutable,

    fn toInternal(self: ImageUsage) t.ImageUsage {
        return .{
            .storage_image = self.storage,
            .color_attachment = self.color_attachment,
            .resolve_attachment = self.resolve_attachment,
            .depth_stencil_attachment = self.depth_stencil_attachment,
            .immutable = self.writes == .immutable or self.writes == .unsealed,
            .write_unsealed = self.writes == .unsealed,
            .write_transient = self.writes == .transient,
            .copy_src = self.copy_src,
            .copy_dst = self.writes == .copy,
        };
    }

    fn fromInternal(u: t.ImageUsage) ImageUsage {
        return .{
            .storage = u.storage_image,
            .color_attachment = u.color_attachment,
            .resolve_attachment = u.resolve_attachment,
            .depth_stencil_attachment = u.depth_stencil_attachment,
            .copy_src = u.copy_src,
            .writes = if (u.write_unsealed) .unsealed else if (u.write_transient) .transient else if (u.copy_dst) .copy else .immutable,
        };
    }
};

/// Image dimensions, format, mip data, usage and optional native storage.
pub const ImageDesc = struct {
    type: ImageType = .@"2d",
    usage: ImageUsage = .{},
    width: u32,
    height: u32,
    /// The depth of 3D images or the number of array layers; null: 1, or 6 for cube maps.
    slices: ?u32 = null,
    mip_levels: u32 = 1,
    /// null: the default color or depth format for attachments, else RGBA8.
    format: ?PixelFormat = null,
    /// null: the default sample count for attachments, else 1.
    sample_count: ?u32 = null,
    /// The content of each mip level, with all faces, layers or depth slices.
    data: []const []const u8 = &.{},
    label: ?[:0]const u8 = null,
    native: ?NativeImage = null,

    /// Native image handles borrowed by the Device; retain them through all GPU use.
    pub const NativeImage = union(enum) {
        gl: struct { texture: u32, target: u32 = 0 },
        metal: *const anyopaque,
        d3d11: *const anyopaque,
        wgpu: *const anyopaque,
    };

    fn toInternal(self: ImageDesc) t.ImageDesc {
        std.debug.assert(self.data.len <= max_mip_levels);
        var res: t.ImageDesc = .{
            .type = enumCast(e.ImageType, self.type),
            .usage = self.usage.toInternal(),
            .width = int(self.width),
            .height = int(self.height),
            .num_slices = optionalInt(self.slices),
            .num_mipmaps = int(self.mip_levels),
            .pixel_format = optionalEnum(e.PixelFormat, self.format),
            .sample_count = optionalInt(self.sample_count),
            .label = labelOf(self.label),
        };
        for (self.data, 0..) |level, i| res.data.mip_levels[i] = rangeOf(level);
        if (self.native) |n| switch (n) {
            .gl => |gl| {
                res.gl_texture = gl.texture;
                res.gl_texture_target = gl.target;
            },
            .metal => |tex| res.mtl_texture = tex,
            .d3d11 => |tex| res.d3d11_texture = tex,
            .wgpu => |tex| res.wgpu_texture = tex,
        };
        return res;
    }
};

/// Image lifecycle and effective dimensions, format and usage.
pub const ImageInfo = struct {
    state: ResourceState,
    type: ImageType,
    usage: ImageUsage,
    width: u32,
    height: u32,
    slices: u32,
    mip_levels: u32,
    format: PixelFormat,
    sample_count: u32,
};

/// A region of one mip level; null sizes extend to the end of the mip level.
pub const ImageRegion = struct {
    mip_level: u32 = 0,
    x: u32 = 0,
    y: u32 = 0,
    slice: u32 = 0,
    width: ?u32 = null,
    height: ?u32 = null,
    slices: ?u32 = null,

    fn location(self: ImageRegion, image: Image) t.ImageLocation {
        return .{ .image = .{ .id = id(image) }, .mip_level = int(self.mip_level), .x = int(self.x), .y = int(self.y), .slice = int(self.slice) };
    }
    fn extent(self: ImageRegion) t.ImageExtent {
        return .{ .width = optionalInt(self.width), .height = optionalInt(self.height), .num_slices = optionalInt(self.slices) };
    }
};

const Transfer = struct { extent: t.ImageExtent, bytes_per_row: i32, bytes_per_slice: i32 };

/// Resolves a region's default size to the end of its mip level and the
/// default pitches to tightly packed rows and slices of the region.
fn resolveTransfer(image: Image, region: ImageRegion, layout: DataLayout) Transfer {
    var res: Transfer = .{ .extent = region.extent(), .bytes_per_row = layout.bytesPerRow(), .bytes_per_slice = layout.bytesPerSlice() };
    const img = core.lookupImage(id(image)) orelse return res;
    const cmn = &img.cmn;
    if (region.mip_level >= cmn.num_mipmaps) return res;
    const mip: i32 = @intCast(region.mip_level);
    const formats = core.formats;
    if (res.extent.width == 0) res.extent.width = @max(core.miplevelDim(cmn.width, mip) - int(region.x), 0);
    if (res.extent.height == 0) res.extent.height = @max(core.miplevelDim(cmn.height, mip) - int(region.y), 0);
    if (res.extent.num_slices == 0) {
        const slices = if (cmn.type == .@"3d") core.miplevelDim(cmn.num_slices, mip) else cmn.num_slices;
        res.extent.num_slices = @max(slices - int(region.slice), 0);
    }
    if (res.bytes_per_row == 0 and res.extent.width > 0) res.bytes_per_row = formats.rowPitch(cmn.pixel_format, res.extent.width, 1);
    if (res.bytes_per_slice == 0 and res.extent.height > 0) res.bytes_per_slice = formats.numRows(cmn.pixel_format, res.extent.height) * res.bytes_per_row;
    return res;
}

/// The memory layout of image data; null pitches are tightly packed.
pub const DataLayout = struct {
    bytes_per_row: ?u32 = null,
    bytes_per_slice: ?u32 = null,

    fn bytesPerRow(self: DataLayout) i32 {
        return optionalInt(self.bytes_per_row);
    }
    fn bytesPerSlice(self: DataLayout) i32 {
        return optionalInt(self.bytes_per_slice);
    }
};

/// GPU transfer from a buffer layout into an image subresource region.
pub const BufferToImageCopy = struct {
    src: Buffer,
    src_offset: usize = 0,
    layout: DataLayout = .{},
    dst: Image,
    region: ImageRegion = .{},
};

// ---------------------------------------------------------------- samplers

/// Filtering, address, comparison and anisotropy settings for a sampler.
pub const SamplerDesc = struct {
    min_filter: Filter = .nearest,
    mag_filter: Filter = .nearest,
    mipmap_filter: Filter = .nearest,
    wrap_u: Wrap = .repeat,
    wrap_v: Wrap = .repeat,
    wrap_w: Wrap = .repeat,
    min_lod: f32 = 0,
    max_lod: f32 = std.math.floatMax(f32),
    border_color: BorderColor = .opaque_black,
    /// A comparison sampler for depth textures when set.
    compare: ?CompareFunc = null,
    max_anisotropy: u32 = 1,
    label: ?[:0]const u8 = null,
    native: ?NativeSampler = null,

    /// Borrowed native sampler handle for resource injection.
    pub const NativeSampler = union(enum) {
        gl: u32,
        metal: *const anyopaque,
        d3d11: *const anyopaque,
        wgpu: *const anyopaque,
    };

    fn toInternal(self: SamplerDesc) t.SamplerDesc {
        var res: t.SamplerDesc = .{
            .min_filter = enumCast(e.Filter, self.min_filter),
            .mag_filter = enumCast(e.Filter, self.mag_filter),
            .mipmap_filter = enumCast(e.Filter, self.mipmap_filter),
            .wrap_u = enumCast(e.Wrap, self.wrap_u),
            .wrap_v = enumCast(e.Wrap, self.wrap_v),
            .wrap_w = enumCast(e.Wrap, self.wrap_w),
            .min_lod = self.min_lod,
            // the core treats 0 as "unset"; the smallest positive value has the same effect
            .max_lod = if (self.max_lod == 0) std.math.floatMin(f32) else self.max_lod,
            .border_color = enumCast(e.BorderColor, self.border_color),
            .compare = if (self.compare) |c| enumCast(e.CompareFunc, c) else .never,
            .max_anisotropy = @max(self.max_anisotropy, 1),
            .label = labelOf(self.label),
        };
        if (self.native) |n| switch (n) {
            .gl => |s| res.gl_sampler = s,
            .metal => |s| res.mtl_sampler = s,
            .d3d11 => |s| res.d3d11_sampler = s,
            .wgpu => |s| res.wgpu_sampler = s,
        };
        return res;
    }
};

// ---------------------------------------------------------------- shaders

/// Shader code for one stage.
pub const ShaderFunction = struct {
    code: union(enum) {
        /// GLSL, HLSL, MSL or WGSL source.
        source: [:0]const u8,
        /// SPIR-V, DXBC/DXIL or a Metal library.
        bytecode: []const u8,
    },
    entry: ?[:0]const u8 = null,
    /// The HLSL target profile when compiling source on D3D, e.g. "vs_5_0".
    d3d_target: ?[:0]const u8 = null,

    fn toInternal(self: ShaderFunction) t.ShaderFunction {
        return switch (self.code) {
            .source => |s| .{ .source = s.ptr, .entry = labelOf(self.entry), .d3d11_target = labelOf(self.d3d_target) },
            .bytecode => |b| .{ .bytecode = rangeOf(b), .entry = labelOf(self.entry), .d3d11_target = labelOf(self.d3d_target) },
        };
    }
};

/// Per-backend binding numbers of a shader resource.
pub const BindSlots = struct {
    /// D3D register number (b, t, u or s depending on the resource).
    hlsl: u8 = 0,
    /// The read/write (`u`) register of read/write storage buffers on D3D.
    hlsl_uav: u8 = 0,
    msl: u8 = 0,
    wgsl: u8 = 0,
    spirv: u8 = 0,
    glsl: u8 = 0,
};

/// Reflected vertex input with its backend-specific name or semantic.
pub const ShaderAttr = struct {
    /// Checked against the vertex format of the pipeline when set.
    base_type: ?ShaderAttrBaseType = null,
    glsl_name: ?[:0]const u8 = null,
    hlsl_semantic: ?[:0]const u8 = null,
    hlsl_semantic_index: u8 = 0,
};

/// Uniform byte layout and native binding locations for one shader stage.
pub const ShaderUniformBlock = struct {
    slot: u3,
    stage: ShaderStage,
    size: u32,
    layout: UniformLayout = .native,
    bindings: BindSlots = .{},
    /// GL only: the uniforms making up the block, in memory order.
    glsl_uniforms: []const GlslUniform = &.{},

    /// One named GLSL uniform used to upload a reflected uniform block.
    pub const GlslUniform = struct {
        type: UniformType,
        array_count: u16 = 1,
        name: [:0]const u8,
    };
};

/// Shader-visible texture, storage buffer or storage-image declaration.
pub const ShaderView = struct {
    slot: u5,
    stage: ShaderStage,
    kind: union(enum) {
        texture: struct {
            image_type: ImageType = .@"2d",
            sample_type: ImageSampleType = .float,
            multisampled: bool = false,
        },
        storage_buffer: struct { readonly: bool = true },
        storage_image: struct {
            image_type: ImageType = .@"2d",
            access_format: PixelFormat,
            writeonly: bool = false,
        },
    },
    bindings: BindSlots = .{},
};

/// Sampler declaration and backend-specific binding locations.
pub const ShaderSampler = struct {
    slot: u4,
    stage: ShaderStage,
    type: SamplerType = .filtering,
    bindings: BindSlots = .{},
};

/// Texture/sampler pair used to form a combined GLSL sampler binding.
pub const TextureSamplerPair = struct {
    stage: ShaderStage,
    view: u5,
    sampler: u4,
    /// GL only: the name of the combined sampler uniform.
    glsl_name: ?[:0]const u8 = null,
};

/// Shader functions, reflected inputs and binding declarations for pipeline creation.
pub const ShaderDesc = struct {
    stages: union(enum) {
        render: struct { vertex: ShaderFunction, fragment: ShaderFunction },
        compute: struct {
            function: ShaderFunction,
            /// Metal only: the threadgroup size of the compute function.
            threads_per_threadgroup: [3]u32 = .{ 0, 0, 0 },
        },
    },
    /// Vertex attributes by location.
    attrs: []const ShaderAttr = &.{},
    uniform_blocks: []const ShaderUniformBlock = &.{},
    views: []const ShaderView = &.{},
    samplers: []const ShaderSampler = &.{},
    texture_sampler_pairs: []const TextureSamplerPair = &.{},
    label: ?[:0]const u8 = null,

    fn toInternal(self: ShaderDesc) t.ShaderDesc {
        std.debug.assert(self.attrs.len <= max_vertex_attributes and self.texture_sampler_pairs.len <= max_texture_sampler_pairs);
        var res: t.ShaderDesc = .{ .label = labelOf(self.label) };
        switch (self.stages) {
            .render => |r| {
                res.vertex_func = r.vertex.toInternal();
                res.fragment_func = r.fragment.toInternal();
            },
            .compute => |c| {
                res.compute_func = c.function.toInternal();
                res.mtl_threads_per_threadgroup = .{ .x = int(c.threads_per_threadgroup[0]), .y = int(c.threads_per_threadgroup[1]), .z = int(c.threads_per_threadgroup[2]) };
            },
        }
        for (self.attrs, 0..) |attr, i| res.attrs[i] = .{
            .base_type = optionalEnum(e.ShaderAttrBaseType, attr.base_type),
            .glsl_name = labelOf(attr.glsl_name),
            .hlsl_sem_name = labelOf(attr.hlsl_semantic),
            .hlsl_sem_index = attr.hlsl_semantic_index,
        };
        for (self.uniform_blocks) |ub| {
            const dst = &res.uniform_blocks[ub.slot];
            dst.* = .{
                .stage = enumCast(e.ShaderStage, ub.stage),
                .size = ub.size,
                .layout = enumCast(e.UniformLayout, ub.layout),
                .hlsl_register_b_n = ub.bindings.hlsl,
                .msl_buffer_n = ub.bindings.msl,
                .wgsl_group0_binding_n = ub.bindings.wgsl,
                .spirv_set0_binding_n = ub.bindings.spirv,
            };
            std.debug.assert(ub.glsl_uniforms.len <= max_uniform_block_members);
            for (ub.glsl_uniforms, 0..) |u, i| dst.glsl_uniforms[i] = .{ .type = enumCast(e.UniformType, u.type), .array_count = u.array_count, .glsl_name = u.name.ptr };
        }
        for (self.views) |view| {
            const dst = &res.views[view.slot];
            const stage = enumCast(e.ShaderStage, view.stage);
            const b = view.bindings;
            switch (view.kind) {
                .texture => |tex| dst.texture = .{
                    .stage = stage,
                    .image_type = enumCast(e.ImageType, tex.image_type),
                    .sample_type = enumCast(e.ImageSampleType, tex.sample_type),
                    .multisampled = tex.multisampled,
                    .hlsl_register_t_n = b.hlsl,
                    .msl_texture_n = b.msl,
                    .wgsl_group1_binding_n = b.wgsl,
                    .spirv_set1_binding_n = b.spirv,
                },
                .storage_buffer => |sbuf| dst.storage_buffer = .{
                    .stage = stage,
                    .readonly = sbuf.readonly,
                    .hlsl_register_t_n = b.hlsl,
                    .hlsl_register_u_n = b.hlsl_uav,
                    .msl_buffer_n = b.msl,
                    .wgsl_group1_binding_n = b.wgsl,
                    .spirv_set1_binding_n = b.spirv,
                    .glsl_binding_n = b.glsl,
                },
                .storage_image => |simg| dst.storage_image = .{
                    .stage = stage,
                    .image_type = enumCast(e.ImageType, simg.image_type),
                    .access_format = enumCast(e.PixelFormat, simg.access_format),
                    .writeonly = simg.writeonly,
                    .hlsl_register_u_n = b.hlsl_uav,
                    .msl_texture_n = b.msl,
                    .wgsl_group1_binding_n = b.wgsl,
                    .spirv_set1_binding_n = b.spirv,
                    .glsl_binding_n = b.glsl,
                },
            }
        }
        for (self.samplers) |smp| res.samplers[smp.slot] = .{
            .stage = enumCast(e.ShaderStage, smp.stage),
            .sampler_type = enumCast(e.SamplerType, smp.type),
            .hlsl_register_s_n = smp.bindings.hlsl,
            .msl_sampler_n = smp.bindings.msl,
            .wgsl_group1_binding_n = smp.bindings.wgsl,
            .spirv_set1_binding_n = smp.bindings.spirv,
        };
        for (self.texture_sampler_pairs, 0..) |pair, i| res.texture_sampler_pairs[i] = .{
            .stage = enumCast(e.ShaderStage, pair.stage),
            .view_slot = pair.view,
            .sampler_slot = pair.sampler,
            .glsl_name = labelOf(pair.glsl_name),
        };
        return res;
    }
};

// ---------------------------------------------------------------- pipelines

/// Stride and stepping for one vertex-buffer binding.
pub const VertexBufferLayout = struct {
    /// null: computed from the attributes using this buffer.
    stride: ?u32 = null,
    step: VertexStep = .per_vertex,
    step_rate: u32 = 1,
};

/// Location, buffer slot, byte offset and encoding of one vertex attribute.
pub const VertexAttr = struct {
    format: VertexFormat,
    buffer: u3 = 0,
    /// null: packed after the previous attribute of the same buffer.
    offset: ?u32 = null,
};

/// Stencil comparison and operations for one triangle face.
pub const StencilFace = struct {
    compare: CompareFunc = .always,
    fail: StencilOp = .keep,
    depth_fail: StencilOp = .keep,
    pass: StencilOp = .keep,
};

/// Front/back stencil tests, masks and reference value.
pub const StencilState = struct {
    enabled: bool = false,
    front: StencilFace = .{},
    back: StencilFace = .{},
    read_mask: u8 = 0,
    write_mask: u8 = 0,
    ref: u8 = 0,
};

/// Depth comparison, write control and attachment format.
pub const DepthState = struct {
    /// null: the device's default depth format; `.none` for no depth attachment.
    format: ?PixelFormat = null,
    compare: CompareFunc = .always,
    write: bool = false,
    bias: f32 = 0,
    bias_slope_scale: f32 = 0,
    bias_clamp: f32 = 0,
};

/// Color and alpha blending equations and factors.
pub const Blend = struct {
    src_rgb: BlendFactor = .one,
    dst_rgb: BlendFactor = .zero,
    op_rgb: BlendOp = .add,
    src_alpha: BlendFactor = .one,
    dst_alpha: BlendFactor = .zero,
    op_alpha: BlendOp = .add,
};

/// Render-target format, blend state and channel write mask.
pub const ColorTarget = struct {
    /// null: the device's default color format.
    format: ?PixelFormat = null,
    write_mask: ColorMask = .rgba,
    /// null: blending disabled.
    blend: ?Blend = null,
};

/// Shader, vertex layout and fixed state for a render or compute pipeline.
pub const PipelineDesc = struct {
    shader: Shader,
    compute: bool = false,
    vertex_buffers: []const VertexBufferLayout = &.{},
    vertex_attrs: []const VertexAttr = &.{},
    primitive: PrimitiveType = .triangles,
    index_type: IndexType = .none,
    cull_mode: CullMode = .none,
    face_winding: FaceWinding = .cw,
    depth: DepthState = .{},
    stencil: StencilState = .{},
    /// The color attachments; empty for depth-only rendering.
    colors: []const ColorTarget = &.{.{}},
    /// null: the device's default sample count.
    sample_count: ?u32 = null,
    blend_color: [4]f32 = .{ 0, 0, 0, 0 },
    alpha_to_coverage: bool = false,
    label: ?[:0]const u8 = null,

    fn toInternal(self: PipelineDesc) t.PipelineDesc {
        std.debug.assert(self.vertex_buffers.len <= max_vertex_buffers and self.vertex_attrs.len <= max_vertex_attributes and self.colors.len <= max_color_attachments);
        var res: t.PipelineDesc = .{
            .compute = self.compute,
            .shader = .{ .id = id(self.shader) },
            .primitive_type = enumCast(e.PrimitiveType, self.primitive),
            .index_type = enumCast(e.IndexType, self.index_type),
            .cull_mode = enumCast(e.CullMode, self.cull_mode),
            .face_winding = enumCast(e.FaceWinding, self.face_winding),
            .depth = .{
                .pixel_format = optionalEnum(e.PixelFormat, self.depth.format),
                .compare = enumCast(e.CompareFunc, self.depth.compare),
                .write_enabled = self.depth.write,
                .bias = self.depth.bias,
                .bias_slope_scale = self.depth.bias_slope_scale,
                .bias_clamp = self.depth.bias_clamp,
            },
            .stencil = .{
                .enabled = self.stencil.enabled,
                .front = stencilFace(self.stencil.front),
                .back = stencilFace(self.stencil.back),
                .read_mask = self.stencil.read_mask,
                .write_mask = self.stencil.write_mask,
                .ref = self.stencil.ref,
            },
            .color_count = @intCast(self.colors.len),
            .sample_count = optionalInt(self.sample_count),
            .blend_color = .{ .r = self.blend_color[0], .g = self.blend_color[1], .b = self.blend_color[2], .a = self.blend_color[3] },
            .alpha_to_coverage_enabled = self.alpha_to_coverage,
            .label = labelOf(self.label),
        };
        for (self.vertex_buffers, 0..) |vb, i| res.layout.buffers[i] = .{
            .stride = optionalInt(vb.stride),
            .step_func = enumCast(e.VertexStep, vb.step),
            .step_rate = int(vb.step_rate),
        };
        for (self.vertex_attrs, 0..) |attr, i| res.layout.attrs[i] = .{
            .format = enumCast(e.VertexFormat, attr.format),
            .buffer_index = attr.buffer,
            .offset = optionalInt(attr.offset),
        };
        // the core marks depth-only pipelines with a first color format of none
        if (self.colors.len == 0 and !self.compute) res.colors[0].pixel_format = .none;
        for (self.colors, 0..) |color, i| {
            res.colors[i] = .{ .pixel_format = optionalEnum(e.PixelFormat, color.format), .write_mask = enumCast(e.ColorMask, color.write_mask) };
            if (color.blend) |b| res.colors[i].blend = .{
                .enabled = true,
                .src_factor_rgb = enumCast(e.BlendFactor, b.src_rgb),
                .dst_factor_rgb = enumCast(e.BlendFactor, b.dst_rgb),
                .op_rgb = enumCast(e.BlendOp, b.op_rgb),
                .src_factor_alpha = enumCast(e.BlendFactor, b.src_alpha),
                .dst_factor_alpha = enumCast(e.BlendFactor, b.dst_alpha),
                .op_alpha = enumCast(e.BlendOp, b.op_alpha),
            };
        }
        return res;
    }

    fn stencilFace(face: StencilFace) t.StencilFaceState {
        return .{
            .compare = enumCast(e.CompareFunc, face.compare),
            .fail_op = enumCast(e.StencilOp, face.fail),
            .depth_fail_op = enumCast(e.StencilOp, face.depth_fail),
            .pass_op = enumCast(e.StencilOp, face.pass),
        };
    }
};

// ---------------------------------------------------------------- views

/// Typed texture/storage binding or render attachment referencing a device resource.
pub const ViewDesc = union(enum) {
    /// A sampled texture, optionally restricted to a range of mips and layers.
    /// GL/GLES without native texture views emulate mip ranges at bind time;
    /// one backing texture must use the same mip range on all units in a draw.
    /// Layer subsets require native texture views and otherwise fail creation.
    texture: struct {
        image: Image,
        base_mip: u32 = 0,
        /// null: all mip levels from `base_mip`.
        mip_count: ?u32 = null,
        base_layer: u32 = 0,
        layer_count: ?u32 = null,
        label: ?[:0]const u8 = null,
    },
    storage_buffer: struct {
        buffer: Buffer,
        /// Must be a multiple of 256.
        offset: u32 = 0,
        label: ?[:0]const u8 = null,
    },
    storage_image: ImageTarget,
    color_attachment: ImageTarget,
    resolve_attachment: ImageTarget,
    depth_stencil_attachment: ImageTarget,

    /// One mip level and slice of an image.
    pub const ImageTarget = struct {
        image: Image,
        mip_level: u32 = 0,
        slice: u32 = 0,
        label: ?[:0]const u8 = null,
    };

    fn toInternal(self: ViewDesc) t.ViewDesc {
        var res: t.ViewDesc = .{};
        switch (self) {
            .texture => |v| {
                res.texture = .{
                    .image = .{ .id = id(v.image) },
                    .mip_levels = .{ .base = int(v.base_mip), .count = optionalInt(v.mip_count) },
                    .slices = .{ .base = int(v.base_layer), .count = optionalInt(v.layer_count) },
                };
                res.label = labelOf(v.label);
            },
            .storage_buffer => |v| {
                res.storage_buffer = .{ .buffer = .{ .id = id(v.buffer) }, .offset = int(v.offset) };
                res.label = labelOf(v.label);
            },
            inline .storage_image, .color_attachment, .resolve_attachment, .depth_stencil_attachment => |v, tag| {
                @field(res, @tagName(tag)) = .{ .image = .{ .id = id(v.image) }, .mip_level = int(v.mip_level), .slice = int(v.slice) };
                res.label = labelOf(v.label);
            },
        }
        return res;
    }
};

/// View lifecycle, role and referenced device-owned resource handles.
pub const ViewInfo = struct {
    state: ResourceState,
    type: ViewType,
    /// The viewed buffer of storage buffer views, else `.invalid`.
    buffer: Buffer,
    /// The viewed image of image views, else `.invalid`.
    image: Image,
};

// ---------------------------------------------------------------- passes

/// Whether attachment results must be retained after a pass.
pub const Store = enum { store, dont_care };

/// Load/clear and store behavior for a color attachment.
pub const ColorAction = struct {
    load: union(enum) { clear: [4]f32, load, dont_care } = .{ .clear = .{ 0.5, 0.5, 0.5, 1 } },
    store: Store = .store,
};

/// Load/clear and store behavior for a depth attachment.
pub const DepthAction = struct {
    load: union(enum) { clear: f32, load, dont_care } = .{ .clear = 1 },
    store: Store = .dont_care,
};

/// Load/clear and store behavior for a stencil attachment.
pub const StencilAction = struct {
    load: union(enum) { clear: u8, load, dont_care } = .{ .clear = 0 },
    store: Store = .dont_care,
};

/// The render targets provided by the window system for swapchain passes.
pub const Swapchain = struct {
    width: u32,
    height: u32,
    /// null: the device defaults.
    sample_count: ?u32 = null,
    color_format: ?PixelFormat = null,
    depth_format: ?PixelFormat = null,
    /// Skips the pass, e.g. while a window is minimized.
    invalid: bool = false,
    native: Native = .none,

    /// Backend-specific swapchain image or framebuffer for the current frame.
    pub const Native = union(enum) {
        none,
        gl: struct { framebuffer: u32 = 0 },
        metal: struct { current_drawable: *const anyopaque, depth_stencil_texture: ?*const anyopaque = null, msaa_color_texture: ?*const anyopaque = null },
        d3d11: struct { render_view: *const anyopaque, resolve_view: ?*const anyopaque = null, depth_stencil_view: ?*const anyopaque = null },
        /// ID3D12Resource pointers; the device creates the views.
        d3d12: struct { render_target: *const anyopaque, resolve_target: ?*const anyopaque = null, depth_stencil_target: ?*const anyopaque = null },
        wgpu: struct { render_view: *const anyopaque, resolve_view: ?*const anyopaque = null, depth_stencil_view: ?*const anyopaque = null },
        vulkan: struct {
            render_image: *const anyopaque,
            render_view: *const anyopaque,
            resolve_image: ?*const anyopaque = null,
            resolve_view: ?*const anyopaque = null,
            depth_stencil_image: ?*const anyopaque = null,
            depth_stencil_view: ?*const anyopaque = null,
            /// Signal for presentation; use one per swapchain image so a submit
            /// fence cannot cause reuse while the presentation engine still waits.
            render_finished_semaphore: *const anyopaque,
            /// Signaled by acquiring this image; the rendering submission waits.
            present_complete_semaphore: *const anyopaque,
        },
    };

    fn toInternal(self: Swapchain) t.Swapchain {
        var res: t.Swapchain = .{
            .invalid = self.invalid,
            .width = int(self.width),
            .height = int(self.height),
            .sample_count = optionalInt(self.sample_count),
            .color_format = optionalEnum(e.PixelFormat, self.color_format),
            .depth_format = optionalEnum(e.PixelFormat, self.depth_format),
        };
        switch (self.native) {
            .none => {},
            .gl => |gl| res.gl = .{ .framebuffer = gl.framebuffer },
            .metal => |mtl| res.metal = .{ .current_drawable = mtl.current_drawable, .depth_stencil_texture = mtl.depth_stencil_texture, .msaa_color_texture = mtl.msaa_color_texture },
            .d3d11 => |dx| res.d3d11 = .{ .render_view = dx.render_view, .resolve_view = dx.resolve_view, .depth_stencil_view = dx.depth_stencil_view },
            .d3d12 => |dx| res.d3d12 = .{ .render_target = dx.render_target, .resolve_target = dx.resolve_target, .depth_stencil_target = dx.depth_stencil_target },
            .wgpu => |w| res.wgpu = .{ .render_view = w.render_view, .resolve_view = w.resolve_view, .depth_stencil_view = w.depth_stencil_view },
            .vulkan => |vk| res.vulkan = .{
                .render_image = vk.render_image,
                .render_view = vk.render_view,
                .resolve_image = vk.resolve_image,
                .resolve_view = vk.resolve_view,
                .depth_stencil_image = vk.depth_stencil_image,
                .depth_stencil_view = vk.depth_stencil_view,
                .render_finished_semaphore = vk.render_finished_semaphore,
                .present_complete_semaphore = vk.present_complete_semaphore,
            },
        }
        return res;
    }
};

/// Attachment views of an offscreen render pass.
pub const Attachments = struct {
    colors: []const View = &.{},
    /// Resolve targets by color attachment index; `.invalid` for none.
    resolves: []const View = &.{},
    depth_stencil: View = .invalid,
};

/// Render-pass target, attachment actions, dimensions and optional debug label.
pub const PassDesc = struct {
    target: union(enum) {
        swapchain: Swapchain,
        attachments: Attachments,
    },
    /// Load and store actions by color attachment; missing entries use the defaults.
    colors: []const ColorAction = &.{},
    depth: DepthAction = .{},
    stencil: StencilAction = .{},
    label: ?[:0]const u8 = null,

    fn toInternal(self: PassDesc) t.Pass {
        std.debug.assert(self.colors.len <= max_color_attachments);
        var res: t.Pass = .{ .label = labelOf(self.label) };
        switch (self.target) {
            .swapchain => |sc| res.swapchain = sc.toInternal(),
            .attachments => |atts| {
                std.debug.assert(atts.colors.len <= max_color_attachments and atts.resolves.len <= max_color_attachments);
                for (atts.colors, 0..) |view, i| res.attachments.colors[i] = .{ .id = id(view) };
                for (atts.resolves, 0..) |view, i| res.attachments.resolves[i] = .{ .id = id(view) };
                res.attachments.depth_stencil = .{ .id = id(atts.depth_stencil) };
            },
        }
        for (&res.action.colors, 0..) |*dst, i| {
            const action: ColorAction = if (i < self.colors.len) self.colors[i] else .{};
            switch (action.load) {
                .clear => |c| {
                    dst.load_action = .clear;
                    dst.clear_value = .{ .r = c[0], .g = c[1], .b = c[2], .a = c[3] };
                },
                .load => dst.load_action = .load,
                .dont_care => dst.load_action = .dontcare,
            }
            dst.store_action = storeAction(action.store);
        }
        switch (self.depth.load) {
            .clear => |c| {
                res.action.depth.load_action = .clear;
                res.action.depth.clear_value = c;
            },
            .load => res.action.depth.load_action = .load,
            .dont_care => res.action.depth.load_action = .dontcare,
        }
        res.action.depth.store_action = storeAction(self.depth.store);
        switch (self.stencil.load) {
            .clear => |c| {
                res.action.stencil.load_action = .clear;
                res.action.stencil.clear_value = c;
            },
            .load => res.action.stencil.load_action = .load,
            .dont_care => res.action.stencil.load_action = .dontcare,
        }
        res.action.stencil.store_action = storeAction(self.stencil.store);
        return res;
    }

    fn storeAction(store: Store) e.StoreAction {
        return switch (store) {
            .store => .store,
            .dont_care => .dontcare,
        };
    }
};

/// Pixel rectangle used by viewport and scissor commands.
pub const Rect = struct { x: i32 = 0, y: i32 = 0, width: i32, height: i32 };

/// Vertex buffer and byte offset bound to one vertex-input slot.
pub const BufferBinding = struct {
    buffer: Buffer,
    offset: u32 = 0,
};

/// Resources for the next draw or dispatch. Views and samplers are listed by
/// bind slot; unused slots in between are `.invalid`.
pub const Bindings = struct {
    vertex_buffers: []const BufferBinding = &.{},
    index_buffer: ?BufferBinding = null,
    views: []const View = &.{},
    samplers: []const Sampler = &.{},

    fn toInternal(self: Bindings) t.Bindings {
        std.debug.assert(self.vertex_buffers.len <= max_vertex_buffers and self.views.len <= max_views and self.samplers.len <= max_samplers);
        var res: t.Bindings = .{};
        for (self.vertex_buffers, 0..) |vb, i| {
            res.vertex_buffers[i] = .{ .id = id(vb.buffer) };
            res.vertex_buffer_offsets[i] = int(vb.offset);
        }
        if (self.index_buffer) |ib| {
            res.index_buffer = .{ .id = id(ib.buffer) };
            res.index_buffer_offset = int(ib.offset);
        }
        for (self.views, 0..) |view, i| res.views[i] = .{ .id = id(view) };
        for (self.samplers, 0..) |smp, i| res.samplers[i] = .{ .id = id(smp) };
        return res;
    }
};

/// Vertex/index range and instance parameters for a draw command.
pub const Draw = struct {
    /// The first vertex, or the first index of indexed draws.
    first: u32 = 0,
    count: u32,
    instances: u32 = 1,
    /// Added to every index of indexed draws.
    base_vertex: i32 = 0,
    first_instance: u32 = 0,
};

/// A render or compute pass, recorded until `end`.
pub const Pass = struct {
    device: *Device,

    /// Coordinate origin used to interpret a viewport or scissor rectangle.
    pub const Origin = enum { bottom_left, top_left };

    /// Set the viewport in pixels using the selected coordinate origin.
    pub fn setViewport(self: *Pass, rect: Rect, origin: Origin) void {
        const device_scope = self.device.enter();
        defer device_scope.end();
        validated(internal.applyViewport, .{ rect.x, rect.y, rect.width, rect.height, origin == .top_left });
    }

    /// Set the scissor rectangle in pixels using the selected coordinate origin.
    pub fn setScissor(self: *Pass, rect: Rect, origin: Origin) void {
        const device_scope = self.device.enter();
        defer device_scope.end();
        validated(internal.applyScissorRect, .{ rect.x, rect.y, rect.width, rect.height, origin == .top_left });
    }

    /// Bind render or compute pipeline state for subsequent commands.
    pub fn setPipeline(self: *Pass, pipeline: Pipeline) void {
        const device_scope = self.device.enter();
        defer device_scope.end();
        validated(internal.applyPipeline, .{t.Pipeline{ .id = id(pipeline) }});
    }

    /// Bind vertex/index buffers, shader views and samplers.
    pub fn setBindings(self: *Pass, bindings: Bindings) void {
        const device_scope = self.device.enter();
        defer device_scope.end();
        validated(internal.applyBindings, .{bindings.toInternal()});
    }

    /// Sets the uniform block at `slot` from a pointer to a value or a slice.
    pub fn setUniforms(self: *Pass, slot: u3, data: anytype) void {
        const device_scope = self.device.enter();
        defer device_scope.end();
        const bytes = asBytes(data);
        validated(internal.applyUniforms, .{ @as(usize, slot), t.Range{ .ptr = bytes.ptr, .size = bytes.len } });
    }

    /// Record a draw using the current pipeline, bindings and uniforms.
    pub fn draw(self: *Pass, args: Draw) void {
        const device_scope = self.device.enter();
        defer device_scope.end();
        if (args.base_vertex == 0 and args.first_instance == 0) {
            validated(internal.draw, .{ int(args.first), int(args.count), int(args.instances) });
        } else {
            validated(internal.drawEx, .{ int(args.first), int(args.count), int(args.instances), args.base_vertex, int(args.first_instance) });
        }
    }

    /// Record compute workgroup counts, rather than individual thread counts.
    pub fn dispatch(self: *Pass, x: u32, y: u32, z: u32) void {
        const device_scope = self.device.enter();
        defer device_scope.end();
        validated(internal.dispatch, .{ int(x), int(y), int(z) });
    }

    /// End this pass before committing or starting another pass.
    pub fn end(self: *Pass) void {
        const device_scope = self.device.enter();
        defer device_scope.end();
        if (lossDetected() and !core.state().cur_pass.in_pass) return;
        internal.endPass();
    }
};

fn asBytes(data: anytype) []const u8 {
    const T = @TypeOf(data);
    const info = @typeInfo(T).pointer;
    return switch (info.size) {
        .one => switch (@typeInfo(info.child)) {
            .array => std.mem.sliceAsBytes(data[0..]),
            else => std.mem.asBytes(data),
        },
        .slice => std.mem.sliceAsBytes(data),
        else => @compileError("setUniforms expects a pointer to a value or a slice, got " ++ @typeName(T)),
    };
}
