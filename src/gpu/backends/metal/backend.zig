//! Metal backend: state, device capabilities and resources, from sokol_gfx.h:7519-7718
//! (state) and 16010-17960 (resource and setup functions). Passes, bindings, draws and
//! transfers live in commands.zig.
const std = @import("std");
const t = @import("../../types.zig");
const e = @import("../../enums.zig");
const core = @import("../../core.zig");
const constants = @import("../../constants.zig");
const sdk = @import("sdk.zig");
const convert = @import("convert.zig");
const r = @import("resources.zig");
const commands = @import("commands.zig");
const IdPool = @import("idpool.zig").IdPool;

const num_inflight = constants.num_inflight_frames;

/// Clear-cache comparison flags (_sg_mtl_cache_cmp_result_t).
pub const cache_cmp_equal: u8 = 0;
pub const cache_cmp_sref: u8 = 1 << 1;
pub const cache_cmp_offset: u8 = 1 << 2;
pub const cache_cmp_activeslot: u8 = 1 << 3;

pub const CacheBuf = struct {
    sref: core.SlotRef = .{},
    active_slot: i32 = 0,
    offset: i32 = 0,
};

pub const CacheTex = struct {
    sref: core.SlotRef = .{},
    active_slot: i32 = 0,
};

/// Last-applied resource bindings, to skip redundant Metal calls (_sg_mtl_cache_t).
pub const StateCache = struct {
    cur_pip: core.SlotRef = .{},
    cur_ibuf: core.Ref(core.Buffer) = .{},
    cur_ibuf_offset: i32 = 0,
    cur_vsbufs: [r.max_stage_buffer_bindings]CacheBuf = @splat(.{}),
    cur_fsbufs: [r.max_stage_buffer_bindings]CacheBuf = @splat(.{}),
    cur_csbufs: [r.max_stage_buffer_bindings]CacheBuf = @splat(.{}),
    cur_vstexs: [r.max_stage_texture_bindings]CacheTex = @splat(.{}),
    cur_fstexs: [r.max_stage_texture_bindings]CacheTex = @splat(.{}),
    cur_cstexs: [r.max_stage_texture_bindings]CacheTex = @splat(.{}),
    cur_vssmps: [r.max_stage_sampler_bindings]core.SlotRef = @splat(.{}),
    cur_fssmps: [r.max_stage_sampler_bindings]core.SlotRef = @splat(.{}),
    cur_cssmps: [r.max_stage_sampler_bindings]core.SlotRef = @splat(.{}),
};

pub const Backend = struct {
    // passes, bindings, draws and transfers, see commands.zig
    pub const beginPass = commands.beginPass;
    pub const endPass = commands.endPass;
    pub const applyViewport = commands.applyViewport;
    pub const applyScissorRect = commands.applyScissorRect;
    pub const applyPipeline = commands.applyPipeline;
    pub const applyBindings = commands.applyBindings;
    pub const applyUniforms = commands.applyUniforms;
    pub const draw = commands.draw;
    pub const dispatch = commands.dispatch;
    pub const commit = commands.commit;
    pub const writeBufferTransient = commands.writeBufferTransient;
    pub const writeImageTransient = commands.writeImageTransient;
    pub const writeBufferUnsealed = commands.writeBufferUnsealed;
    pub const writeImageUnsealed = commands.writeImageUnsealed;
    pub const sealBuffer = commands.sealBuffer;
    pub const sealImage = commands.sealImage;
    pub const copyBufferToBuffer = commands.copyBufferToBuffer;
    pub const copyBufferToImage = commands.copyBufferToImage;
    pub const pushDebugGroup = commands.pushDebugGroup;
    pub const popDebugGroup = commands.popDebugGroup;
    pub const readBuffer = commands.readBuffer;
    pub const readImage = commands.readImage;

    allocator: std.mem.Allocator,
    loss: *std.atomic.Value(i32),
    valid: bool = false,
    /// macOS (`_SG_TARGET_MACOS`) rather than iOS or the simulator.
    macos: bool = false,
    use_shared_storage_mode: bool = false,
    cur_frame_rotate_index: u32 = 0,
    ub_size: i32 = 0,
    cur_ub_offset: i32 = 0,
    cur_ub_base_ptr: ?[*]u8 = null,
    cache: StateCache = .{},
    idpool: IdPool,
    /// Limits the number of frames in flight, signaled when a command buffer completes.
    sem: sdk.Id = null,
    mtl_device: sdk.Id = null,
    cmd_queue: sdk.Id = null,
    /// Owned references, released when the buffer is committed or the encoder ended.
    cmd_buffer: sdk.Id = null,
    render_cmd_encoder: sdk.Id = null,
    compute_cmd_encoder: sdk.Id = null,
    blit_cmd_encoder: sdk.Id = null,
    /// Borrowed from the application's swapchain, presented at the end of the pass.
    cur_drawable: sdk.Id = null,
    uniform_buffers: [num_inflight]sdk.Id = @splat(null),

    /// Creates the device objects and fills in features, limits and pixel format caps
    /// (_sg_mtl_setup_backend and _sg_mtl_init_caps).
    pub fn init(s: *core.State) !Backend {
        if (comptime !sdk.available) return error.MetalNotAvailable;
        const device_handle: sdk.Id = if (s.desc.environment.metal.device) |ptr| @constCast(ptr) else return error.MissingMetalDevice;
        const macos = s.backend == .metal_macos;
        var self: Backend = .{
            .allocator = s.allocator,
            .loss = &s.loss_code,
            .macos = macos,
            .ub_size = s.desc.uniform_buffer_size,
            .idpool = try IdPool.init(s.allocator, &s.desc),
            .mtl_device = sdk.retain(device_handle),
        };
        errdefer self.destroy();
        std.debug.assert(self.ub_size > 0);

        self.sem = sdk.semaphoreCreate(@as(isize, num_inflight));
        self.cmd_queue = sdk.msg(sdk.Id, device_handle, "newCommandQueue", .{});
        if (self.cmd_queue == null) return error.MetalInitFailed;
        for (&self.uniform_buffers, 0..) |*buffer, i| {
            const options = sdk.resource_cpu_cache_write_combined | sdk.resource_storage_shared;
            buffer.* = sdk.msg(sdk.Id, device_handle, "newBufferWithLength:options:", .{ uint(self.ub_size), options });
            if (buffer.* == null) return error.MetalInitFailed;
            if (core.config.debug) setLabelFmt(buffer.*, "sg-uniform-buffer.{d}", .{i});
        }

        if (s.desc.metal.force_managed_storage_mode) {
            self.use_shared_storage_mode = false;
        } else if (respondsTo(device_handle, "supportsFamily:")) {
            // on Intel Macs, always use managed resources even though the device says it
            // supports unified memory (because of texture restrictions)
            self.use_shared_storage_mode = supportsFamily(device_handle, sdk.gpu_family_apple1);
        } else {
            // macOS: managed, iOS: shared
            self.use_shared_storage_mode = !macos;
        }
        initCaps(device_handle, s);
        self.valid = true;
        return self;
    }

    /// Waits for the frames in flight and releases every object (_sg_mtl_discard_backend).
    pub fn deinit(self: *Backend) void {
        std.debug.assert(self.valid);
        if (self.cmd_buffer != null) self.commit();
        // wait for the last frame to finish, then give the semaphore back
        for (0..num_inflight) |_| sdk.semaphoreWait(self.sem);
        for (0..num_inflight) |_| sdk.semaphoreSignal(self.sem);
        self.idpool.garbageCollect(core.state().frame_index + @as(u32, num_inflight) + 2);
        self.valid = false;
        self.destroy();
    }

    /// Releases the owned objects; valid for a partially initialized backend too.
    fn destroy(self: *Backend) void {
        self.idpool.deinit(self.allocator);
        self.cur_drawable = null;
        // NOTE: a command buffer and encoders still in progress are owned by the backend
        sdk.release(self.blit_cmd_encoder);
        sdk.release(self.compute_cmd_encoder);
        sdk.release(self.render_cmd_encoder);
        sdk.release(self.cmd_buffer);
        self.blit_cmd_encoder = null;
        self.compute_cmd_encoder = null;
        self.render_cmd_encoder = null;
        self.cmd_buffer = null;
        sdk.release(self.sem);
        sdk.release(self.cmd_queue);
        sdk.release(self.mtl_device);
        for (&self.uniform_buffers) |*buffer| {
            sdk.release(buffer.*);
            buffer.* = null;
        }
        self.sem = null;
        self.cmd_queue = null;
        self.mtl_device = null;
    }

    pub fn resetStateCache(self: *Backend) void {
        self.cache = .{};
    }

    pub fn device(self: *const Backend) ?*const anyopaque {
        return self.mtl_device;
    }

    pub fn renderCommandEncoder(self: *const Backend) ?*const anyopaque {
        return self.render_cmd_encoder;
    }

    pub fn computeCommandEncoder(self: *const Backend) ?*const anyopaque {
        return self.compute_cmd_encoder;
    }

    pub fn commandQueue(self: *const Backend) ?*const anyopaque {
        return self.cmd_queue;
    }

    // ------------------------------------------------------------ buffers

    fn managedOrSharedOptions(self: *const Backend) sdk.Uint {
        if (self.macos) {
            return if (self.use_shared_storage_mode) sdk.resource_storage_shared else sdk.resource_storage_managed;
        }
        return sdk.resource_storage_shared;
    }

    fn bufferResourceOptions(self: *const Backend, usage: *const t.BufferUsage) sdk.Uint {
        var res = self.managedOrSharedOptions();
        if (usage.write_transient or usage.write_unsealed) res |= sdk.resource_cpu_cache_write_combined;
        return res;
    }

    pub fn createBuffer(self: *Backend, buf: *core.Buffer, desc: *const t.BufferDesc) e.ResourceState {
        buf.native = .{ .metal = .{} };
        const res = &buf.native.metal;
        std.debug.assert(buf.cmn.size > 0);
        const options = self.bufferResourceOptions(&buf.cmn.usage);
        // macOS blit buffer copies need four-byte aligned spans. Keep the public
        // logical size while padding backing storage, including odd byte buffers.
        const native_size = (std.math.add(usize, buf.cmn.size, 3) catch return .failed) & ~@as(usize, 3);
        var padded: ?[]u8 = null;
        defer if (padded) |bytes| self.allocator.free(bytes);
        if (desc.data.ptr != null and native_size != buf.cmn.size) {
            padded = self.allocator.alloc(u8, native_size) catch return .failed;
            @memcpy(padded.?[0..buf.cmn.size], @as([*]const u8, @ptrCast(desc.data.ptr.?))[0..buf.cmn.size]);
            @memset(padded.?[buf.cmn.size..], 0);
        }
        for (0..@intCast(buf.cmn.num_slots)) |slot| {
            var mtl_buf: sdk.Id = null;
            if (desc.mtl_buffer) |injected| {
                std.debug.assert(slot == 0);
                mtl_buf = sdk.retain(@constCast(injected));
            } else {
                if (desc.data.ptr) |bytes| {
                    std.debug.assert(desc.data.size > 0);
                    mtl_buf = sdk.msg(sdk.Id, self.mtl_device, "newBufferWithBytes:length:options:", .{ if (padded) |copy| @as(*const anyopaque, copy.ptr) else bytes, native_size, options });
                } else {
                    mtl_buf = sdk.msg(sdk.Id, self.mtl_device, "newBufferWithLength:options:", .{ native_size, options });
                }
                if (mtl_buf == null) {
                    core.logError(.metal_create_buffer_failed);
                    return .failed;
                }
            }
            if (core.config.debug) if (desc.label) |label| setLabelFmt(mtl_buf, "{s}.{d}", .{ std.mem.span(label), slot });
            res.buf[slot] = self.idpool.addResource(mtl_buf);
        }
        return .valid;
    }

    pub fn discardBuffer(self: *Backend, buf: *core.Buffer) void {
        const res = switch (buf.native) {
            .metal => |*m| m,
            else => return,
        };
        for (0..@intCast(buf.cmn.num_slots)) |slot| {
            // releasing slot 0 is a no-op
            self.idpool.releaseResource(core.state().frame_index, res.buf[slot]);
        }
    }

    // ------------------------------------------------------------ images

    /// Sets up the texture descriptor for an image (_sg_mtl_init_texdesc).
    fn initTexDesc(self: *const Backend, mtl_desc: sdk.Id, img: *const core.Image) bool {
        const cmn = &img.cmn;
        const pixel_format = convert.pixelFormat(cmn.pixel_format, self.macos);
        if (pixel_format == .invalid) {
            core.logError(.metal_texture_format_not_supported);
            return false;
        }
        sdk.msg(void, mtl_desc, "setTextureType:", .{convert.textureType(cmn.type, cmn.sample_count > 1)});
        sdk.msg(void, mtl_desc, "setPixelFormat:", .{pixel_format});
        sdk.msg(void, mtl_desc, "setWidth:", .{uint(cmn.width)});
        sdk.msg(void, mtl_desc, "setHeight:", .{uint(cmn.height)});
        sdk.msg(void, mtl_desc, "setDepth:", .{uint(if (cmn.type == .@"3d") cmn.num_slices else 1)});
        sdk.msg(void, mtl_desc, "setMipmapLevelCount:", .{uint(cmn.num_mipmaps)});
        sdk.msg(void, mtl_desc, "setArrayLength:", .{uint(if (cmn.type == .array) cmn.num_slices else 1)});
        sdk.msg(void, mtl_desc, "setSampleCount:", .{uint(cmn.sample_count)});

        const usg = &cmn.usage;
        const any_attachment = usg.color_attachment or usg.resolve_attachment or usg.depth_stencil_attachment;
        var tex_usage: sdk.Uint = sdk.texture_usage_shader_read;
        if (any_attachment) tex_usage |= sdk.texture_usage_render_target;
        if (usg.storage_image) tex_usage |= sdk.texture_usage_shader_write;
        sdk.msg(void, mtl_desc, "setUsage:", .{tex_usage});

        const options: sdk.Uint = if (any_attachment or usg.storage_image or usg.copy_dst)
            sdk.resource_storage_private
        else
            self.managedOrSharedOptions();
        sdk.msg(void, mtl_desc, "setResourceOptions:", .{options});
        return true;
    }

    /// Writes one mip level, or a range of slices of it, into a texture (_sg_mtl_write_miplevel_data).
    pub fn writeMiplevelData(
        img: *const core.Image,
        mtl_tex: sdk.Id,
        src_ptr: [*]const u8,
        src_size: usize,
        src_offset: usize,
        bytes_per_row: i32,
        bytes_per_slice: i32,
        mip_level: i32,
        x: i32,
        y: i32,
        slice: i32,
        width: i32,
        height: i32,
        num_slices: i32,
    ) void {
        std.debug.assert(bytes_per_row > 0 and bytes_per_slice > 0);
        std.debug.assert(mip_level >= 0 and mip_level < img.cmn.num_mipmaps);
        std.debug.assert(width > 0 and height > 0 and num_slices > 0);
        std.debug.assert(src_offset + core.formats.imageCopySize(img.cmn.pixel_format, bytes_per_row, bytes_per_slice, width, height, num_slices) <= src_size);

        // bytesPerImage is only supplied for 3D textures, see the Metal docs for replaceRegion
        const is_3d = img.cmn.type == .@"3d";
        const region = if (is_3d)
            sdk.region3d(uint(x), uint(y), uint(slice), uint(width), uint(height), uint(num_slices))
        else
            sdk.region2d(uint(x), uint(y), uint(width), uint(height));
        const bytes_per_image: i32 = if (is_3d) bytes_per_slice else 0;
        const mtl_slice_index: i32 = if (is_3d) 0 else slice;
        const mtl_num_slices: i32 = if (is_3d) 1 else num_slices;
        var i: i32 = 0;
        while (i < mtl_num_slices) : (i += 1) {
            const offset = src_offset + @as(usize, @intCast(i)) * @as(usize, @intCast(bytes_per_slice));
            sdk.msg(void, mtl_tex, "replaceRegion:mipmapLevel:slice:withBytes:bytesPerRow:bytesPerImage:", .{
                region,
                uint(mip_level),
                uint(mtl_slice_index + i),
                @as(*const anyopaque, @ptrCast(src_ptr + offset)),
                uint(bytes_per_row),
                uint(bytes_per_image),
            });
        }
    }

    fn copyImageData(img: *const core.Image, mtl_tex: sdk.Id, data: *const t.ImageData) void {
        var mip_level: i32 = 0;
        while (mip_level < img.cmn.num_mipmaps) : (mip_level += 1) {
            const range = data.mip_levels[@intCast(mip_level)];
            std.debug.assert(range.ptr != null and range.size > 0);
            const mip_width = core.miplevelDim(img.cmn.width, mip_level);
            const mip_height = core.miplevelDim(img.cmn.height, mip_level);
            const mip_depth_or_slices = if (img.cmn.type == .@"3d") core.miplevelDim(img.cmn.num_slices, mip_level) else img.cmn.num_slices;
            const bytes_per_row = core.formats.rowPitch(img.cmn.pixel_format, mip_width, 1);
            const bytes_per_slice = core.formats.surfacePitch(img.cmn.pixel_format, mip_width, mip_height, 1);
            writeMiplevelData(
                img,
                mtl_tex,
                @ptrCast(range.ptr),
                range.size,
                0,
                bytes_per_row,
                bytes_per_slice,
                mip_level,
                0,
                0,
                0,
                mip_width,
                mip_height,
                mip_depth_or_slices,
            );
        }
    }

    pub fn createImage(self: *Backend, img: *core.Image, desc: *const t.ImageDesc) e.ResourceState {
        img.native = .{ .metal = .{} };
        const res = &img.native.metal;
        const mtl_desc = sdk.allocInit("MTLTextureDescriptor");
        if (!self.initTexDesc(mtl_desc, img)) {
            sdk.release(mtl_desc);
            return .failed;
        }
        for (0..@intCast(img.cmn.num_slots)) |slot| {
            var mtl_tex: sdk.Id = null;
            if (desc.mtl_texture) |injected| {
                std.debug.assert(slot == 0);
                mtl_tex = sdk.retain(@constCast(injected));
            } else {
                mtl_tex = sdk.msg(sdk.Id, self.mtl_device, "newTextureWithDescriptor:", .{mtl_desc});
                if (mtl_tex == null) {
                    sdk.release(mtl_desc);
                    core.logError(.metal_create_texture_failed);
                    return .failed;
                }
                if (desc.data.mip_levels[0].ptr != null) copyImageData(img, mtl_tex, &desc.data);
            }
            if (core.config.debug) if (desc.label) |label| setLabelFmt(mtl_tex, "{s}.{d}", .{ std.mem.span(label), slot });
            res.tex[slot] = self.idpool.addResource(mtl_tex);
        }
        sdk.release(mtl_desc);
        return .valid;
    }

    pub fn discardImage(self: *Backend, img: *core.Image) void {
        const res = switch (img.native) {
            .metal => |*m| m,
            else => return,
        };
        for (0..@intCast(img.cmn.num_slots)) |slot| {
            self.idpool.releaseResource(core.state().frame_index, res.tex[slot]);
        }
    }

    // ------------------------------------------------------------ samplers

    pub fn createSampler(self: *Backend, smp: *core.Sampler, desc: *const t.SamplerDesc) e.ResourceState {
        smp.native = .{ .metal = .{} };
        const res = &smp.native.metal;
        const clamp_to_border = core.state().features.image_clamp_to_border;
        var mtl_smp: sdk.Id = null;
        if (desc.mtl_sampler) |injected| {
            mtl_smp = sdk.retain(@constCast(injected));
        } else {
            const mtl_desc = sdk.allocInit("MTLSamplerDescriptor");
            sdk.msg(void, mtl_desc, "setSAddressMode:", .{convert.addressMode(desc.wrap_u, clamp_to_border)});
            sdk.msg(void, mtl_desc, "setTAddressMode:", .{convert.addressMode(desc.wrap_v, clamp_to_border)});
            sdk.msg(void, mtl_desc, "setRAddressMode:", .{convert.addressMode(desc.wrap_w, clamp_to_border)});
            if (clamp_to_border) sdk.msg(void, mtl_desc, "setBorderColor:", .{convert.borderColor(desc.border_color)});
            sdk.msg(void, mtl_desc, "setMinFilter:", .{convert.minMagFilter(desc.min_filter)});
            sdk.msg(void, mtl_desc, "setMagFilter:", .{convert.minMagFilter(desc.mag_filter)});
            sdk.msg(void, mtl_desc, "setMipFilter:", .{convert.mipFilter(desc.mipmap_filter)});
            sdk.msg(void, mtl_desc, "setLodMinClamp:", .{desc.min_lod});
            sdk.msg(void, mtl_desc, "setLodMaxClamp:", .{desc.max_lod});
            // FIXME: lodAverage?
            sdk.msg(void, mtl_desc, "setMaxAnisotropy:", .{@as(sdk.Uint, desc.max_anisotropy)});
            sdk.msg(void, mtl_desc, "setNormalizedCoordinates:", .{true});
            sdk.msg(void, mtl_desc, "setCompareFunction:", .{convert.compareFunc(desc.compare)});
            if (core.config.debug) if (desc.label) |label| sdk.msg(void, mtl_desc, "setLabel:", .{sdk.nsString(label)});
            mtl_smp = sdk.msg(sdk.Id, self.mtl_device, "newSamplerStateWithDescriptor:", .{mtl_desc});
            sdk.release(mtl_desc);
            if (mtl_smp == null) {
                core.logError(.metal_create_sampler_failed);
                return .failed;
            }
        }
        res.sampler_state = self.idpool.addResource(mtl_smp);
        return .valid;
    }

    pub fn discardSampler(self: *Backend, smp: *core.Sampler) void {
        const res = switch (smp.native) {
            .metal => |*m| m,
            else => return,
        };
        self.idpool.releaseResource(core.state().frame_index, res.sampler_state);
    }

    // ------------------------------------------------------------ shaders

    /// Compiles MSL source into a library, logging the compiler output on failure.
    fn compileLibrary(self: *const Backend, src: [*:0]const u8) sdk.Id {
        var err: sdk.Id = null;
        const lib = sdk.msg(sdk.Id, self.mtl_device, "newLibraryWithSource:options:error:", .{ sdk.nsString(src), @as(sdk.Id, null), &err });
        if (err != null) {
            core.logError(.metal_shader_compilation_failed);
            core.logMsg(.metal_shader_compilation_output, sdk.errorText(err) orelse "");
        }
        return lib;
    }

    /// Loads precompiled metallib bytecode (_sg_mtl_library_from_bytecode).
    fn libraryFromBytecode(self: *const Backend, ptr: [*]const u8, num_bytes: usize) sdk.Id {
        const lib_data = sdk.dispatchDataCopy(ptr, num_bytes);
        var err: sdk.Id = null;
        const lib = sdk.msg(sdk.Id, self.mtl_device, "newLibraryWithData:error:", .{ lib_data, &err });
        if (err != null) {
            core.logError(.metal_shader_creation_failed);
            core.logMsg(.metal_shader_compilation_output, sdk.errorText(err) orelse "");
        }
        sdk.release(lib_data);
        return lib;
    }

    fn createShaderFunc(self: *Backend, func: *const t.ShaderFunction, label: ?[*:0]const u8, label_ext: [*:0]const u8, res: *r.ShaderFunc) bool {
        var lib: sdk.Id = null;
        if (func.bytecode.ptr) |bytes| {
            lib = self.libraryFromBytecode(@ptrCast(bytes), func.bytecode.size);
        } else if (func.source) |src| {
            lib = self.compileLibrary(src);
        }
        if (lib == null) return false;
        if (core.config.debug) if (label) |text| setLabelFmt(lib, "{s}.{s}", .{ std.mem.span(text), std.mem.span(label_ext) });

        const entry = func.entry orelse {
            sdk.release(lib);
            core.logError(.metal_shader_entry_not_found);
            return false;
        };
        const mtl_func = sdk.msg(sdk.Id, lib, "newFunctionWithName:", .{sdk.nsString(entry)});
        if (mtl_func == null) {
            core.logError(.metal_shader_entry_not_found);
            sdk.release(lib);
            return false;
        }
        res.mtl_lib = self.idpool.addResource(lib);
        res.mtl_func = self.idpool.addResource(mtl_func);
        return true;
    }

    fn discardShaderFunc(self: *Backend, func: *const r.ShaderFunc) void {
        // it is valid to release slot 0
        self.idpool.releaseResource(core.state().frame_index, func.mtl_func);
        self.idpool.releaseResource(core.state().frame_index, func.mtl_lib);
    }

    /// Out-of-range check of the MSL bindslots, active in release builds too (_sg_mtl_ensure_msl_bindslot_ranges).
    fn ensureMslBindslotRanges(desc: *const t.ShaderDesc) bool {
        for (desc.uniform_blocks) |ub| {
            if (ub.stage != .none and ub.msl_buffer_n >= r.max_stage_ub_bindings) {
                core.logError(.metal_uniformblock_msl_buffer_slot_out_of_range);
                return false;
            }
        }
        for (desc.views) |view| {
            if (view.texture.stage != .none and view.texture.msl_texture_n >= r.max_stage_texture_bindings) {
                core.logError(.metal_image_msl_texture_slot_out_of_range);
                return false;
            }
            if (view.storage_buffer.stage != .none and
                (view.storage_buffer.msl_buffer_n < r.max_stage_ub_bindings or view.storage_buffer.msl_buffer_n >= r.max_stage_ub_sbuf_bindings))
            {
                core.logError(.metal_storagebuffer_msl_buffer_slot_out_of_range);
                return false;
            }
            if (view.storage_image.stage != .none and view.storage_image.msl_texture_n >= r.max_stage_texture_bindings) {
                core.logError(.metal_storageimage_msl_texture_slot_out_of_range);
                return false;
            }
        }
        for (desc.samplers) |smp| {
            if (smp.stage != .none and smp.msl_sampler_n >= r.max_stage_sampler_bindings) {
                core.logError(.metal_sampler_msl_sampler_slot_out_of_range);
                return false;
            }
        }
        return true;
    }

    pub fn createShader(self: *Backend, shd: *core.Shader, desc: *const t.ShaderDesc) e.ResourceState {
        shd.native = .{ .metal = .{} };
        const res = &shd.native.metal;
        // do a MSL bindslot range check also in release mode, and fail the shader if it fails
        if (!ensureMslBindslotRanges(desc)) return .failed;

        res.threads_per_threadgroup = .{
            .width = uint(desc.mtl_threads_per_threadgroup.x),
            .height = uint(desc.mtl_threads_per_threadgroup.y),
            .depth = uint(desc.mtl_threads_per_threadgroup.z),
        };
        for (desc.uniform_blocks, 0..) |ub, i| res.ub_buffer_n[i] = ub.msl_buffer_n;
        for (desc.views, 0..) |view, i| {
            if (view.storage_buffer.stage != .none) {
                res.view_buffer_texture_n[i] = view.storage_buffer.msl_buffer_n;
            } else if (view.texture.stage != .none) {
                res.view_buffer_texture_n[i] = view.texture.msl_texture_n;
            } else if (view.storage_image.stage != .none) {
                res.view_buffer_texture_n[i] = view.storage_image.msl_texture_n;
            }
        }
        for (desc.samplers, 0..) |smp, i| res.smp_sampler_n[i] = smp.msl_sampler_n;

        // create metal library and function objects; every function is attempted
        var valid = true;
        if (desc.vertex_func.source != null or desc.vertex_func.bytecode.ptr != null) {
            valid = self.createShaderFunc(&desc.vertex_func, desc.label, "vs", &res.vertex_func) and valid;
        }
        if (desc.fragment_func.source != null or desc.fragment_func.bytecode.ptr != null) {
            valid = self.createShaderFunc(&desc.fragment_func, desc.label, "fs", &res.fragment_func) and valid;
        }
        if (desc.compute_func.source != null or desc.compute_func.bytecode.ptr != null) {
            valid = self.createShaderFunc(&desc.compute_func, desc.label, "cs", &res.compute_func) and valid;
        }
        // NOTE: no eager cleanup on partial failure, discardShader handles it
        return if (valid) .valid else .failed;
    }

    pub fn discardShader(self: *Backend, shd: *core.Shader) void {
        const res = switch (shd.native) {
            .metal => |*m| m,
            else => return,
        };
        self.discardShaderFunc(&res.vertex_func);
        self.discardShaderFunc(&res.fragment_func);
        self.discardShaderFunc(&res.compute_func);
    }

    // ------------------------------------------------------------ pipelines

    pub fn createPipeline(self: *Backend, pip: *core.Pipeline, desc: *const t.PipelineDesc) e.ResourceState {
        pip.native = .{ .metal = .{} };
        const res = &pip.native.metal;
        const shd = pip.cmn.shader.get();
        const shd_res = &shd.native.metal;
        if (pip.cmn.is_compute) {
            const cp_desc = sdk.allocInit("MTLComputePipelineDescriptor");
            sdk.msg(void, cp_desc, "setComputeFunction:", .{self.idpool.id(shd_res.compute_func.mtl_func)});
            sdk.msg(void, cp_desc, "setThreadGroupSizeIsMultipleOfThreadExecutionWidth:", .{true});
            for (shd.cmn.views, 0..) |view, i| {
                if (view.view_type != .storagebuffer) continue;
                if (!view.sbuf_readonly) continue;
                const mtl_slot = shd_res.view_buffer_texture_n[i];
                const buffers = sdk.msg(sdk.Id, cp_desc, "buffers", .{});
                const buffer_desc = sdk.msg(sdk.Id, buffers, "objectAtIndexedSubscript:", .{uint(mtl_slot)});
                sdk.msg(void, buffer_desc, "setMutability:", .{sdk.mutability_immutable});
            }
            if (core.config.debug) if (desc.label) |label| sdk.msg(void, cp_desc, "setLabel:", .{sdk.nsString(label)});

            var err: sdk.Id = null;
            const cps = sdk.msg(sdk.Id, self.mtl_device, "newComputePipelineStateWithDescriptor:options:reflection:error:", .{
                cp_desc,
                @as(sdk.Uint, 0),
                @as(?*anyopaque, null),
                &err,
            });
            sdk.release(cp_desc);
            if (cps == null) {
                core.logError(.metal_create_cps_failed);
                if (err != null) core.logMsg(.metal_create_cps_output, sdk.errorText(err) orelse "");
                return .failed;
            }
            res.cps = self.idpool.addResource(cps);
            res.threads_per_threadgroup = shd_res.threads_per_threadgroup;
        } else {
            res.prim_type = convert.primitiveType(desc.primitive_type);
            res.index_size = convert.indexSize(pip.cmn.index_type);
            if (pip.cmn.index_type != .none) res.index_type = convert.indexType(pip.cmn.index_type);
            res.cull_mode = convert.cullMode(desc.cull_mode);
            res.winding = convert.winding(desc.face_winding);
            res.stencil_ref = desc.stencil.ref;

            // vertex descriptor
            const vtx_desc = sdk.allocInit("MTLVertexDescriptor");
            const attributes = sdk.msg(sdk.Id, vtx_desc, "attributes", .{});
            for (desc.layout.attrs, 0..) |a_state, attr_index| {
                if (a_state.format == .invalid) break;
                std.debug.assert(a_state.buffer_index >= 0 and a_state.buffer_index < constants.max_vertexbuffer_bindslots);
                std.debug.assert(pip.cmn.vertex_buffer_layout_active[@intCast(a_state.buffer_index)]);
                const attr = sdk.msg(sdk.Id, attributes, "objectAtIndexedSubscript:", .{uint(attr_index)});
                sdk.msg(void, attr, "setFormat:", .{convert.vertexFormat(a_state.format)});
                sdk.msg(void, attr, "setOffset:", .{uint(a_state.offset)});
                sdk.msg(void, attr, "setBufferIndex:", .{uint(vertexBufferBindslot(@intCast(a_state.buffer_index)))});
            }
            const layouts = sdk.msg(sdk.Id, vtx_desc, "layouts", .{});
            for (pip.cmn.vertex_buffer_layout_active, 0..) |active, layout_index| {
                if (!active) continue;
                const l_state = desc.layout.buffers[layout_index];
                const mtl_vb_slot = vertexBufferBindslot(layout_index);
                std.debug.assert(l_state.stride > 0);
                const layout = sdk.msg(sdk.Id, layouts, "objectAtIndexedSubscript:", .{uint(mtl_vb_slot)});
                sdk.msg(void, layout, "setStride:", .{uint(l_state.stride)});
                sdk.msg(void, layout, "setStepFunction:", .{convert.vertexStep(l_state.step_func)});
                sdk.msg(void, layout, "setStepRate:", .{uint(l_state.step_rate)});
            }

            // render pipeline descriptor
            const rp_desc = sdk.allocInit("MTLRenderPipelineDescriptor");
            sdk.msg(void, rp_desc, "setVertexDescriptor:", .{vtx_desc});
            // the descriptor retains what it needs
            sdk.release(vtx_desc);
            sdk.msg(void, rp_desc, "setVertexFunction:", .{self.idpool.id(shd_res.vertex_func.mtl_func)});
            sdk.msg(void, rp_desc, "setFragmentFunction:", .{self.idpool.id(shd_res.fragment_func.mtl_func)});
            sdk.msg(void, rp_desc, "setRasterSampleCount:", .{uint(desc.sample_count)});
            sdk.msg(void, rp_desc, "setAlphaToCoverageEnabled:", .{desc.alpha_to_coverage_enabled});
            sdk.msg(void, rp_desc, "setAlphaToOneEnabled:", .{false});
            sdk.msg(void, rp_desc, "setRasterizationEnabled:", .{true});
            sdk.msg(void, rp_desc, "setDepthAttachmentPixelFormat:", .{convert.pixelFormat(desc.depth.pixel_format, self.macos)});
            if (desc.depth.pixel_format == .depth_stencil) {
                sdk.msg(void, rp_desc, "setStencilAttachmentPixelFormat:", .{convert.pixelFormat(desc.depth.pixel_format, self.macos)});
            }
            const color_attachments = sdk.msg(sdk.Id, rp_desc, "colorAttachments", .{});
            for (desc.colors[0..@intCast(desc.color_count)], 0..) |cs, i| {
                const ca = sdk.msg(sdk.Id, color_attachments, "objectAtIndexedSubscript:", .{uint(i)});
                sdk.msg(void, ca, "setPixelFormat:", .{convert.pixelFormat(cs.pixel_format, self.macos)});
                sdk.msg(void, ca, "setWriteMask:", .{convert.colorWriteMask(cs.write_mask)});
                sdk.msg(void, ca, "setBlendingEnabled:", .{cs.blend.enabled});
                sdk.msg(void, ca, "setAlphaBlendOperation:", .{convert.blendOp(cs.blend.op_alpha)});
                sdk.msg(void, ca, "setRgbBlendOperation:", .{convert.blendOp(cs.blend.op_rgb)});
                sdk.msg(void, ca, "setDestinationAlphaBlendFactor:", .{convert.blendFactor(cs.blend.dst_factor_alpha)});
                sdk.msg(void, ca, "setDestinationRGBBlendFactor:", .{convert.blendFactor(cs.blend.dst_factor_rgb)});
                sdk.msg(void, ca, "setSourceAlphaBlendFactor:", .{convert.blendFactor(cs.blend.src_factor_alpha)});
                sdk.msg(void, ca, "setSourceRGBBlendFactor:", .{convert.blendFactor(cs.blend.src_factor_rgb)});
            }

            // Buffer mutability: vertex buffers and storage buffers are not updated while in
            // flight (dynamic buffers are double-buffered). Storage buffers applied to the
            // vertex stage must be readonly in the shader, fragment stage may write them.
            const vertex_buffers = sdk.msg(sdk.Id, rp_desc, "vertexBuffers", .{});
            for (pip.cmn.vertex_buffer_layout_active, 0..) |active, i| {
                if (!active) continue;
                const vb = sdk.msg(sdk.Id, vertex_buffers, "objectAtIndexedSubscript:", .{uint(vertexBufferBindslot(i))});
                sdk.msg(void, vb, "setMutability:", .{sdk.mutability_immutable});
            }
            for (shd.cmn.views, 0..) |view, i| {
                if (view.view_type != .storagebuffer) continue;
                const mtl_slot = shd_res.view_buffer_texture_n[i];
                switch (view.stage) {
                    .vertex => {
                        const vb = sdk.msg(sdk.Id, vertex_buffers, "objectAtIndexedSubscript:", .{uint(mtl_slot)});
                        sdk.msg(void, vb, "setMutability:", .{sdk.mutability_immutable});
                    },
                    .fragment => if (view.sbuf_readonly) {
                        const fb = sdk.msg(sdk.Id, sdk.msg(sdk.Id, rp_desc, "fragmentBuffers", .{}), "objectAtIndexedSubscript:", .{uint(mtl_slot)});
                        sdk.msg(void, fb, "setMutability:", .{sdk.mutability_immutable});
                    },
                    else => {},
                }
            }
            if (core.config.debug) if (desc.label) |label| sdk.msg(void, rp_desc, "setLabel:", .{sdk.nsString(label)});

            var err: sdk.Id = null;
            const rps = sdk.msg(sdk.Id, self.mtl_device, "newRenderPipelineStateWithDescriptor:error:", .{ rp_desc, &err });
            sdk.release(rp_desc);
            if (rps == null) {
                core.logError(.metal_create_rps_failed);
                if (err != null) core.logMsg(.metal_create_rps_output, sdk.errorText(err) orelse "");
                return .failed;
            }
            res.rps = self.idpool.addResource(rps);

            // depth-stencil state
            const ds_desc = sdk.allocInit("MTLDepthStencilDescriptor");
            sdk.msg(void, ds_desc, "setDepthCompareFunction:", .{convert.compareFunc(desc.depth.compare)});
            sdk.msg(void, ds_desc, "setDepthWriteEnabled:", .{desc.depth.write_enabled});
            if (desc.stencil.enabled) {
                const sb = &desc.stencil.back;
                const back = sdk.allocInit("MTLStencilDescriptor");
                setStencilFace(back, sb, desc.stencil);
                sdk.msg(void, ds_desc, "setBackFaceStencil:", .{back});
                sdk.release(back);
                const sf = &desc.stencil.front;
                const front = sdk.allocInit("MTLStencilDescriptor");
                setStencilFace(front, sf, desc.stencil);
                sdk.msg(void, ds_desc, "setFrontFaceStencil:", .{front});
                sdk.release(front);
            }
            if (core.config.debug) if (desc.label) |label| setLabelFmt(ds_desc, "{s}.dss", .{std.mem.span(label)});

            const dss = sdk.msg(sdk.Id, self.mtl_device, "newDepthStencilStateWithDescriptor:", .{ds_desc});
            sdk.release(ds_desc);
            if (dss == null) {
                core.logError(.metal_create_dss_failed);
                return .failed;
            }
            res.dss = self.idpool.addResource(dss);
        }
        return .valid;
    }

    fn setStencilFace(stencil: sdk.Id, face: *const t.StencilFaceState, state: t.StencilState) void {
        sdk.msg(void, stencil, "setStencilFailureOperation:", .{convert.stencilOp(face.fail_op)});
        sdk.msg(void, stencil, "setDepthFailureOperation:", .{convert.stencilOp(face.depth_fail_op)});
        sdk.msg(void, stencil, "setDepthStencilPassOperation:", .{convert.stencilOp(face.pass_op)});
        sdk.msg(void, stencil, "setStencilCompareFunction:", .{convert.compareFunc(face.compare)});
        sdk.msg(void, stencil, "setReadMask:", .{uint(state.read_mask)});
        sdk.msg(void, stencil, "setWriteMask:", .{uint(state.write_mask)});
    }

    pub fn discardPipeline(self: *Backend, pip: *core.Pipeline) void {
        const res = switch (pip.native) {
            .metal => |*m| m,
            else => return,
        };
        self.idpool.releaseResource(core.state().frame_index, res.cps);
        self.idpool.releaseResource(core.state().frame_index, res.rps);
        self.idpool.releaseResource(core.state().frame_index, res.dss);
    }

    // ------------------------------------------------------------ views

    pub fn createView(self: *Backend, view: *core.View, desc: *const t.ViewDesc) e.ResourceState {
        view.native = .{ .metal = .{} };
        const res = &view.native.metal;
        if (view.cmn.type == .texture or view.cmn.type == .storageimage) {
            const cmn = &view.cmn.img;
            const img = cmn.ref.get();
            std.debug.assert(cmn.mip_level_count >= 1 and cmn.slice_count >= 1);
            for (0..@intCast(img.cmn.num_slots)) |slot| {
                const mtl_tex = self.idpool.id(img.native.metal.tex[slot]);
                const tex_view = sdk.msg(sdk.Id, mtl_tex, "newTextureViewWithPixelFormat:textureType:levels:slices:", .{
                    convert.pixelFormat(img.cmn.pixel_format, self.macos),
                    convert.textureType(img.cmn.type, img.cmn.sample_count > 1),
                    sdk.NSRange{ .location = uint(cmn.mip_level), .length = uint(cmn.mip_level_count) },
                    sdk.NSRange{ .location = uint(cmn.slice), .length = uint(cmn.slice_count) },
                });
                if (tex_view == null) {
                    core.logError(.metal_create_textureview_failed);
                    return .failed;
                }
                if (core.config.debug) if (desc.label) |label| setLabelFmt(tex_view, "{s}.{d}", .{ std.mem.span(label), slot });
                res.tex_view[slot] = self.idpool.addResource(tex_view);
            }
        }
        return .valid;
    }

    pub fn discardView(self: *Backend, view: *core.View) void {
        const res = switch (view.native) {
            .metal => |*m| m,
            else => return,
        };
        for (res.tex_view) |slot| self.idpool.releaseResource(core.state().frame_index, slot);
    }

    // ------------------------------------------------------------ helpers

    /// Storage buffer offset that every uniform block binding is aligned to.
    pub fn uniformAlignment(self: *const Backend) i32 {
        return if (self.macos or core.state().backend == .metal_simulator) 256 else 16;
    }
};

// ------------------------------------------------------------ setup helpers

fn uint(value: anytype) sdk.Uint {
    return @intCast(value);
}

/// Index of the Metal buffer bound to vertex buffer slot `slot`, past the uniform and
/// storage buffer slots (_sg_mtl_vertexbuffer_bindslot).
pub fn vertexBufferBindslot(slot: usize) usize {
    return slot + r.max_stage_ub_sbuf_bindings;
}

fn respondsTo(object: sdk.Id, comptime name: [:0]const u8) bool {
    return sdk.msg(bool, object, "respondsToSelector:", .{sdk.selector(name)});
}

fn supportsFamily(device: sdk.Id, family: sdk.Uint) bool {
    return sdk.msg(bool, device, "supportsFamily:", .{family});
}

fn setLabelFmt(object: sdk.Id, comptime fmt: []const u8, args: anytype) void {
    var buf: [256]u8 = undefined;
    const text = std.fmt.bufPrint(buf[0 .. buf.len - 1], fmt, args) catch return;
    buf[text.len] = 0;
    sdk.msg(void, object, "setLabel:", .{sdk.nsString(@ptrCast(&buf))});
}

fn formatInfo(s: *core.State, fmt: e.PixelFormat) *t.PixelformatInfo {
    return &s.formats[@backingInt(fmt)];
}

// pixel format capability sets, from sokol_gfx.h:9695-9762
fn capsAll(info: *t.PixelformatInfo) void {
    info.sample = true;
    info.filter = true;
    info.blend = true;
    info.render = true;
    info.msaa = true;
}
fn capsSr(info: *t.PixelformatInfo) void {
    info.sample = true;
    info.render = true;
}
fn capsSrm(info: *t.PixelformatInfo) void {
    info.sample = true;
    info.render = true;
    info.msaa = true;
}
fn capsSf(info: *t.PixelformatInfo) void {
    info.sample = true;
    info.filter = true;
}
fn capsSbr(info: *t.PixelformatInfo) void {
    info.sample = true;
    info.blend = true;
    info.render = true;
}
fn capsSfbr(info: *t.PixelformatInfo) void {
    info.sample = true;
    info.filter = true;
    info.blend = true;
    info.render = true;
}
fn capsSrmd(info: *t.PixelformatInfo) void {
    info.sample = true;
    info.render = true;
    info.msaa = true;
    info.depth = true;
}
fn capsComputeAll(info: *t.PixelformatInfo) void {
    info.read = true;
    info.write = true;
}

/// Feature flags, limits and pixel formats of the Metal device (_sg_mtl_init_caps).
fn initCaps(device: sdk.Id, s: *core.State) void {
    const macos = s.backend == .metal_macos;
    s.features = .{
        .origin_top_left = true,
        .mrt_independent_blend_state = true,
        .mrt_independent_write_mask = true,
        .compute = true,
        .msaa_texture_bindings = true,
        .draw_base_vertex = true,
        .draw_base_instance = true,
        .dual_source_blending = true,
        .vertexformat_int10_n2 = true,
        .copy_buffer_to_image_relaxed_buffer_type = true,
        .copy_buffer_to_image_relaxed_bytes_per_row = true,
    };
    // clamp-to-border sampling needs an Apple7 or Mac2 GPU, or Metal 3 on newer systems
    s.features.image_clamp_to_border = respondsTo(device, "supportsFamily:") and
        (supportsFamily(device, sdk.gpu_family_apple7) or supportsFamily(device, sdk.gpu_family_mac2) or supportsFamily(device, sdk.gpu_family_metal3));

    if (macos) {
        s.limits.max_image_size_2d = 16 * 1024;
        s.limits.max_image_size_cube = 16 * 1024;
        s.limits.max_image_size_3d = 2 * 1024;
        s.limits.max_image_size_array = 16 * 1024;
        s.limits.max_image_array_layers = 2 * 1024;
        s.limits.max_texture_bindings_per_stage = @min(128, constants.max_view_bindslots);
    } else {
        // newer iOS devices support 16k textures
        s.limits.max_image_size_2d = 8 * 1024;
        s.limits.max_image_size_cube = 8 * 1024;
        s.limits.max_image_size_3d = 2 * 1024;
        s.limits.max_image_size_array = 8 * 1024;
        s.limits.max_image_array_layers = 2 * 1024;
        s.limits.max_texture_bindings_per_stage = @min(96, constants.max_view_bindslots); // since iPhone8
    }
    s.limits.max_storage_image_bindings_per_stage = s.limits.max_texture_bindings_per_stage; // shared with texture bindings
    s.limits.max_storage_buffer_bindings_per_stage = @min(r.max_stage_buffer_bindings - (constants.max_vertexbuffer_bindslots + constants.max_uniformblock_bindslots), constants.max_view_bindslots);
    s.limits.max_color_attachments = @min(8, constants.max_color_attachments);
    s.limits.max_vertex_attrs = constants.max_vertex_attributes;

    // the formats of the header's table, with the platform differences
    capsAll(formatInfo(s, .r8));
    capsAll(formatInfo(s, .r8sn));
    capsSrm(formatInfo(s, .r8ui));
    capsSrm(formatInfo(s, .r8si));
    if (macos) capsAll(formatInfo(s, .r16)) else capsSfbr(formatInfo(s, .r16));
    if (macos) capsAll(formatInfo(s, .r16sn)) else capsSfbr(formatInfo(s, .r16sn));
    capsSrm(formatInfo(s, .r16ui));
    capsSrm(formatInfo(s, .r16si));
    capsAll(formatInfo(s, .r16f));
    capsAll(formatInfo(s, .rg8));
    capsAll(formatInfo(s, .rg8sn));
    capsSrm(formatInfo(s, .rg8ui));
    capsSrm(formatInfo(s, .rg8si));
    capsSr(formatInfo(s, .r32ui));
    capsSr(formatInfo(s, .r32si));
    if (macos) capsAll(formatInfo(s, .r32f)) else capsSbr(formatInfo(s, .r32f));
    if (macos) capsAll(formatInfo(s, .rg16)) else capsSfbr(formatInfo(s, .rg16));
    if (macos) capsAll(formatInfo(s, .rg16sn)) else capsSfbr(formatInfo(s, .rg16sn));
    capsSrm(formatInfo(s, .rg16ui));
    capsSrm(formatInfo(s, .rg16si));
    capsAll(formatInfo(s, .rg16f));
    capsAll(formatInfo(s, .rgba8));
    capsAll(formatInfo(s, .srgb8a8));
    capsAll(formatInfo(s, .rgba8sn));
    capsSrm(formatInfo(s, .rgba8ui));
    capsSrm(formatInfo(s, .rgba8si));
    capsAll(formatInfo(s, .bgra8));
    capsAll(formatInfo(s, .sbgr8a8));
    capsAll(formatInfo(s, .rgb10a2));
    capsAll(formatInfo(s, .rg11b10f));
    if (macos) {
        capsSf(formatInfo(s, .rgb9e5));
        capsSrm(formatInfo(s, .rg32ui));
        capsSrm(formatInfo(s, .rg32si));
    } else {
        capsAll(formatInfo(s, .rgb9e5));
        capsSr(formatInfo(s, .rg32ui));
        capsSr(formatInfo(s, .rg32si));
    }
    if (macos) capsAll(formatInfo(s, .rg32f)) else capsSbr(formatInfo(s, .rg32f));
    if (macos) capsAll(formatInfo(s, .rgba16)) else capsSfbr(formatInfo(s, .rgba16));
    if (macos) capsAll(formatInfo(s, .rgba16sn)) else capsSfbr(formatInfo(s, .rgba16sn));
    capsSrm(formatInfo(s, .rgba16ui));
    capsSrm(formatInfo(s, .rgba16si));
    capsAll(formatInfo(s, .rgba16f));
    if (macos) {
        capsSrm(formatInfo(s, .rgba32ui));
        capsSrm(formatInfo(s, .rgba32si));
        capsAll(formatInfo(s, .rgba32f));
    } else {
        capsSr(formatInfo(s, .rgba32ui));
        capsSr(formatInfo(s, .rgba32si));
        capsSr(formatInfo(s, .rgba32f));
    }
    capsSrmd(formatInfo(s, .depth));
    capsSrmd(formatInfo(s, .depth_stencil));
    if (macos) {
        capsSf(formatInfo(s, .bc1_rgba));
        capsSf(formatInfo(s, .bc2_rgba));
        capsSf(formatInfo(s, .bc3_rgba));
        capsSf(formatInfo(s, .bc3_srgba));
        capsSf(formatInfo(s, .bc4_r));
        capsSf(formatInfo(s, .bc4_rsn));
        capsSf(formatInfo(s, .bc5_rg));
        capsSf(formatInfo(s, .bc5_rgsn));
        capsSf(formatInfo(s, .bc6h_rgbf));
        capsSf(formatInfo(s, .bc6h_rgbuf));
        capsSf(formatInfo(s, .bc7_rgba));
        capsSf(formatInfo(s, .bc7_srgba));
    } else {
        capsSf(formatInfo(s, .etc2_rgb8));
        capsSf(formatInfo(s, .etc2_srgb8));
        capsSf(formatInfo(s, .etc2_rgb8a1));
        capsSf(formatInfo(s, .etc2_rgba8));
        capsSf(formatInfo(s, .etc2_srgb8a8));
        capsSf(formatInfo(s, .eac_r11));
        capsSf(formatInfo(s, .eac_r11sn));
        capsSf(formatInfo(s, .eac_rg11));
        capsSf(formatInfo(s, .eac_rg11sn));
        capsSf(formatInfo(s, .astc_4x4_rgba));
        capsSf(formatInfo(s, .astc_4x4_srgba));
    }

    // compute shader access
    for ([_]e.PixelFormat{ .r8, .r8sn, .r8ui, .r8si, .r16, .r16sn, .r16ui, .r16si, .r16f, .rg8, .rg8sn, .rg8ui, .rg8si, .r32ui, .r32si, .r32f, .rg16, .rg16sn, .rg16ui, .rg16si, .rg16f, .rgba8, .rgba8sn, .rgba8ui, .rgba8si, .bgra8, .rgb10a2, .rg11b10f, .rg32ui, .rg32si, .rg32f, .rgba16, .rgba16sn, .rgba16ui, .rgba16si, .rgba16f, .rgba32ui, .rgba32si, .rgba32f }) |fmt| {
        capsComputeAll(formatInfo(s, fmt));
    }
}

// ------------------------------------------------------------ free functions

/// sg_mtl_query_buffer_info(): the Metal buffers of each slot, unless the slot is unused.
pub fn queryBufferInfo(res: *const core.Buffer) t.MtlBufferInfo {
    var info: t.MtlBufferInfo = .{};
    const native = switch (res.native) {
        .metal => |m| m,
        else => return info,
    };
    const backend = backendOrNull() orelse return info;
    for (0..@intCast(res.cmn.num_slots)) |i| {
        if (native.buf[i] != 0) info.buf[i] = backend.idpool.id(native.buf[i]);
    }
    info.active_slot = res.cmn.active_slot;
    return info;
}

/// sg_mtl_query_image_info(): the Metal textures of each slot, unless the slot is unused.
pub fn queryImageInfo(res: *const core.Image) t.MtlImageInfo {
    var info: t.MtlImageInfo = .{};
    const native = switch (res.native) {
        .metal => |m| m,
        else => return info,
    };
    const backend = backendOrNull() orelse return info;
    for (0..@intCast(res.cmn.num_slots)) |i| {
        if (native.tex[i] != 0) info.tex[i] = backend.idpool.id(native.tex[i]);
    }
    info.active_slot = res.cmn.active_slot;
    return info;
}

pub fn querySamplerInfo(res: *const core.Sampler) t.MtlSamplerInfo {
    var info: t.MtlSamplerInfo = .{};
    const native = switch (res.native) {
        .metal => |m| m,
        else => return info,
    };
    const backend = backendOrNull() orelse return info;
    if (native.sampler_state != 0) info.smp = backend.idpool.id(native.sampler_state);
    return info;
}

pub fn queryShaderInfo(res: *const core.Shader) t.MtlShaderInfo {
    var info: t.MtlShaderInfo = .{};
    const native = switch (res.native) {
        .metal => |m| m,
        else => return info,
    };
    const backend = backendOrNull() orelse return info;
    if (native.vertex_func.mtl_lib != 0) info.vertex_lib = backend.idpool.id(native.vertex_func.mtl_lib);
    if (native.fragment_func.mtl_lib != 0) info.fragment_lib = backend.idpool.id(native.fragment_func.mtl_lib);
    if (native.vertex_func.mtl_func != 0) info.vertex_func = backend.idpool.id(native.vertex_func.mtl_func);
    if (native.fragment_func.mtl_func != 0) info.fragment_func = backend.idpool.id(native.fragment_func.mtl_func);
    return info;
}

pub fn queryPipelineInfo(res: *const core.Pipeline) t.MtlPipelineInfo {
    var info: t.MtlPipelineInfo = .{};
    const native = switch (res.native) {
        .metal => |m| m,
        else => return info,
    };
    const backend = backendOrNull() orelse return info;
    if (native.rps != 0) info.rps = backend.idpool.id(native.rps);
    if (native.dss != 0) info.dss = backend.idpool.id(native.dss);
    return info;
}

/// The active Metal backend, or null when another backend is set up.
fn backendOrNull() ?*Backend {
    const s = if (core.sg) |*value| value else return null;
    return switch (s.impl) {
        .metal => &s.impl.metal,
        else => null,
    };
}

comptime {
    // analyze every entry point, including those the shared core does not reach on this target
    _ = &Backend.init;
    _ = &Backend.deinit;
    _ = &Backend.resetStateCache;
    _ = &Backend.device;
    _ = &Backend.renderCommandEncoder;
    _ = &Backend.computeCommandEncoder;
    _ = &Backend.commandQueue;
    _ = &Backend.createBuffer;
    _ = &Backend.discardBuffer;
    _ = &Backend.createImage;
    _ = &Backend.discardImage;
    _ = &Backend.createSampler;
    _ = &Backend.discardSampler;
    _ = &Backend.createShader;
    _ = &Backend.discardShader;
    _ = &Backend.createPipeline;
    _ = &Backend.discardPipeline;
    _ = &Backend.createView;
    _ = &Backend.discardView;
    _ = &Backend.beginPass;
    _ = &Backend.endPass;
    _ = &Backend.applyViewport;
    _ = &Backend.applyScissorRect;
    _ = &Backend.applyPipeline;
    _ = &Backend.applyBindings;
    _ = &Backend.applyUniforms;
    _ = &Backend.draw;
    _ = &Backend.dispatch;
    _ = &Backend.commit;
    _ = &Backend.writeBufferTransient;
    _ = &Backend.writeImageTransient;
    _ = &Backend.writeBufferUnsealed;
    _ = &Backend.writeImageUnsealed;
    _ = &Backend.sealBuffer;
    _ = &Backend.sealImage;
    _ = &Backend.copyBufferToBuffer;
    _ = &Backend.copyBufferToImage;
    _ = &Backend.pushDebugGroup;
    _ = &Backend.popDebugGroup;
    _ = &Backend.readBuffer;
    _ = &Backend.readImage;
    _ = &queryBufferInfo;
    _ = &queryImageInfo;
    _ = &querySamplerInfo;
    _ = &queryShaderInfo;
    _ = &queryPipelineInfo;
}
