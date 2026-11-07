//! Native D3D11 resources and device capabilities, from sokol_gfx.h:14345-15356.
const std = @import("std");
const builtin = @import("builtin");
const sdk = @import("sdk.zig");
const c = @import("../dxgi/constants.zig");
const convert = @import("../dxgi/convert.zig");
const r = @import("resources.zig");
const t = @import("../../types.zig");
const e = @import("../../enums.zig");
const formats = @import("../../formats.zig");
const core = @import("../../core.zig");
const Compiler = @import("../dxgi/compiler.zig").Compiler;

const debug_name: sdk.Guid = .{ .data1 = 0x429b8c22, .data2 = 0x9188, .data3 = 0x4b0c, .data4 = .{ 0x87, 0x42, 0xac, 0xb0, 0xbf, 0x85, 0xc2, 0x00 } };

pub const Backend = struct {
    const Commands = @import("commands.zig").Commands(@This());
    pub const countStat = Commands.countStat;
    pub const beginPass = Commands.beginPass;
    pub const endPass = Commands.endPass;
    pub const viewport = Commands.viewport;
    pub const scissor = Commands.scissor;
    pub const applyPipeline = Commands.applyPipeline;
    pub const applyBindings = Commands.applyBindings;
    pub const applyUniforms = Commands.applyUniforms;
    pub const draw = Commands.draw;
    pub const dispatch = Commands.dispatch;
    pub const writeBuffer = Commands.writeBuffer;
    pub const writeImage = Commands.writeImage;
    pub const copyBuffer = Commands.copyBuffer;
    pub const copyBufferToImage = Commands.copyBufferToImage;
    allocator: std.mem.Allocator,
    device: *sdk.Object,
    context: *sdk.Object,
    logger: t.Logger,
    debugging: bool,
    compiler: Compiler = .{},
    features: t.Features = .{},
    limits: t.Limits = .{},
    format_info: [69]t.PixelformatInfo = @splat(.{}),
    stats: t.FrameStatsD3d11 = .{},
    stats_enabled: bool = true,
    swapchain_render: ?*sdk.Object = null,
    swapchain_resolve: ?*sdk.Object = null,

    pub fn init(allocator: std.mem.Allocator, desc: t.Desc, compile_fn: ?sdk.CompileFn) !Backend {
        const device = sdk.fromOpaque(desc.environment.d3d11.device orelse return error.MissingD3d11Device);
        const context = sdk.fromOpaque(desc.environment.d3d11.device_context orelse return error.MissingD3d11Context);
        var result: Backend = .{
            .allocator = allocator,
            .device = device,
            .context = context,
            .logger = desc.logger,
            .debugging = desc.d3d11.shader_debugging,
            .compiler = .{ .function = compile_fn },
            .features = .{
                .origin_top_left = true,
                .image_clamp_to_border = true,
                .mrt_independent_blend_state = true,
                .mrt_independent_write_mask = true,
                .compute = true,
                .msaa_texture_bindings = true,
                .draw_base_vertex = true,
                .draw_base_instance = true,
                .dual_source_blending = true,
                .copy_buffer_to_image_relaxed_bytes_per_row = true,
            },
        };
        const level = sdk.getFeatureLevel(device);
        const max_uavs: i32 = if (level >= c.feature_level_11_1) 32 else 8;
        result.limits = .{
            .max_image_size_2d = 16384,
            .max_image_size_cube = 16384,
            .max_image_size_3d = 2048,
            .max_image_size_array = 16384,
            .max_image_array_layers = 2048,
            .max_vertex_attrs = 16,
            .max_color_attachments = 8,
            .max_texture_bindings_per_stage = 32,
            .max_storage_buffer_bindings_per_stage = 32,
            .max_storage_image_bindings_per_stage = max_uavs,
            .d3d11_max_unordered_access_views = max_uavs,
        };
        for (2..69) |i| {
            const pixel: e.PixelFormat = @fromBackingInt(@intCast(i));
            const srv = result.formatCaps(convert.srvFormat(pixel));
            const rtv = result.formatCaps(convert.rtvUavFormat(pixel));
            const dsv = result.formatCaps(convert.dsvFormat(pixel));
            const depth = dsv & c.format_support_depth_stencil != 0;
            const render_caps = if (depth) dsv else rtv;
            result.format_info[i] = .{
                .sample = srv & c.format_support_texture2d != 0,
                .filter = srv & c.format_support_shader_sample != 0,
                .render = depth or rtv & c.format_support_render_target != 0,
                .blend = render_caps & c.format_support_blendable != 0,
                .msaa = render_caps & c.format_support_multisample_rendertarget != 0,
                .depth = depth,
                .read = rtv & c.format_support_typed_unordered_access_view != 0,
                .write = rtv & c.format_support_typed_unordered_access_view != 0,
            };
        }
        if (desc.enforce_portable_limits) {
            result.limits.max_color_attachments = 4;
            result.limits.max_texture_bindings_per_stage = 16;
            result.limits.max_storage_buffer_bindings_per_stage = 8;
            result.limits.max_storage_image_bindings_per_stage = 4;
        }
        if (level == c.feature_level_11_0) result.message(2, .d3d11_feature_level_0_detected, null);
        return result;
    }
    pub fn deinit(self: *Backend) void {
        self.compiler.deinit();
    }
    fn formatCaps(self: *Backend, format: u32) u32 {
        if (format == c.format_unknown) return 0;
        var flags: u32 = 0;
        const status = sdk.checkFormatSupport(self.device, format, @ptrCast(&flags));
        std.debug.assert(status >= 0 or status == @as(i32, @bitCast(@as(u32, 0x80004005))));
        return if (status >= 0) flags else 0;
    }
    pub fn message(self: *Backend, level: u32, item: e.LogItem, text: ?[*:0]const u8) void {
        if (self.logger.func) |callback| callback("sg", level, @backingInt(item), text, 0, null, self.logger.user_data);
    }
    fn label(_: *Backend, object: ?*sdk.Object, value: ?[*:0]const u8) void {
        if (builtin.mode == .debug) if (object) |resource| {
            _ = sdk.setPrivateData(resource, &debug_name, if (value) |text| @intCast(std.mem.len(text)) else 0, value);
        };
    }
    pub fn createBuffer(self: *Backend, buffer: *r.Buffer, desc: t.BufferDesc) bool {
        if (desc.d3d11_buffer) |object| {
            buffer.object = sdk.fromOpaque(object);
            _ = sdk.addRef(buffer.object.?);
            return true;
        }
        if (desc.usage.staging_buffer or desc.usage.staging_index_buffer) {
            buffer.staging = self.allocator.alloc(u8, desc.size) catch return false;
            return true;
        }
        const native: sdk.BufferDesc = .{
            .byte_width = @intCast(desc.size),
            .usage = convert.bufferUsage(desc.usage),
            .bind_flags = convert.bufferBindFlags(desc.usage),
            .cpu_access_flags = convert.bufferCpuAccess(desc.usage),
            .misc_flags = convert.bufferMiscFlags(desc.usage),
        };
        const data = [_]sdk.SubresourceData{.{ .data = desc.data.ptr }};
        const status = sdk.createBuffer(self.device, @ptrCast(&native), if (desc.data.ptr != null) &data else null, &buffer.object);
        if (status < 0 or buffer.object == null) {
            self.message(1, .d3d11_create_buffer_failed, null);
            return false;
        }
        self.label(buffer.object, desc.label);
        return true;
    }
    pub fn discardBuffer(self: *Backend, buffer: *r.Buffer) void {
        sdk.release(buffer.object);
        if (buffer.staging) |data| self.allocator.free(data);
        buffer.* = .{};
    }
    pub fn createImage(self: *Backend, image: *r.Image, desc: t.ImageDesc) bool {
        image.format = convert.textureFormat(desc.pixel_format);
        if (image.format == c.format_unknown) {
            self.message(1, .d3d11_create_2d_texture_unsupported_pixel_format, null);
            return false;
        }
        const injected = desc.d3d11_texture != null;
        const slices: usize = if (desc.type == .@"3d") 1 else @intCast(desc.num_slices);
        const count = slices * @as(usize, @intCast(desc.num_mipmaps));
        var initial: []sdk.SubresourceData = &.{};
        if (!injected and desc.data.mip_levels[0].ptr != null) {
            if (count > 16 * 2048) return false;
            initial = self.allocator.alloc(sdk.SubresourceData, count) catch return false;
            for (0..slices) |slice| for (0..@intCast(desc.num_mipmaps)) |mip| {
                const data = desc.data.mip_levels[mip];
                const offset = @divTrunc(data.size, slices) * slice;
                const width = formats.mipDimension(desc.width, @intCast(mip));
                const height = formats.mipDimension(desc.height, @intCast(mip));
                const bytes: [*]const u8 = @ptrCast(data.ptr.?);
                initial[slice * @as(usize, @intCast(desc.num_mipmaps)) + mip] = .{
                    .data = bytes + offset,
                    .sys_mem_pitch = @intCast(formats.rowPitch(desc.pixel_format, width, 1)),
                    .sys_mem_slice_pitch = if (desc.type == .@"3d") @intCast(formats.surfacePitch(desc.pixel_format, width, height, 1)) else 0,
                };
            };
        }
        defer if (initial.len != 0) self.allocator.free(initial);
        const data = if (initial.len != 0) initial.ptr else null;
        if (desc.type != .@"3d") {
            if (desc.d3d11_texture) |object| {
                image.texture_2d = sdk.fromOpaque(object);
                _ = sdk.addRef(image.texture_2d.?);
            } else {
                const native: sdk.Texture2DDesc = .{
                    .width = @intCast(desc.width),
                    .height = @intCast(desc.height),
                    .mip_levels = @intCast(desc.num_mipmaps),
                    .array_size = @intCast(desc.num_slices),
                    .format = image.format,
                    .sample_desc = .{ .count = @intCast(desc.sample_count), .quality = if (desc.sample_count > 1) c.standard_multisample_pattern else 0 },
                    .usage = c.usage_default,
                    .bind_flags = convert.imageBindFlags(desc.usage),
                    .misc_flags = if (desc.type == .cube) c.resource_misc_texturecube else 0,
                };
                const status = sdk.createTexture2D(self.device, @ptrCast(&native), data, &image.texture_2d);
                if (status < 0 or image.texture_2d == null) {
                    self.message(1, .d3d11_create_2d_texture_failed, null);
                    return false;
                }
                self.label(image.texture_2d, desc.label);
            }
            image.resource = image.texture_2d;
        } else {
            if (desc.d3d11_texture) |object| {
                image.texture_3d = sdk.fromOpaque(object);
                _ = sdk.addRef(image.texture_3d.?);
            } else {
                const native: sdk.Texture3DDesc = .{
                    .width = @intCast(desc.width),
                    .height = @intCast(desc.height),
                    .depth = @intCast(desc.num_slices),
                    .mip_levels = @intCast(desc.num_mipmaps),
                    .format = image.format,
                    .usage = c.usage_default,
                    .bind_flags = convert.imageBindFlags(desc.usage),
                };
                const status = sdk.createTexture3D(self.device, @ptrCast(&native), data, &image.texture_3d);
                if (status < 0 or image.texture_3d == null) {
                    self.message(1, .d3d11_create_3d_texture_failed, null);
                    return false;
                }
                self.label(image.texture_3d, desc.label);
            }
            image.resource = image.texture_3d;
        }
        _ = sdk.addRef(image.resource.?);
        return true;
    }
    pub fn discardImage(_: *Backend, image: *r.Image) void {
        sdk.release(image.texture_2d);
        sdk.release(image.texture_3d);
        sdk.release(image.resource);
        image.* = .{};
    }
    pub fn createSampler(self: *Backend, sampler: *r.Sampler, desc: t.SamplerDesc) bool {
        if (desc.d3d11_sampler) |object| {
            sampler.object = sdk.fromOpaque(object);
            _ = sdk.addRef(sampler.object.?);
            return true;
        }
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
        const status = sdk.createSamplerState(self.device, @ptrCast(&native), &sampler.object);
        if (status < 0 or sampler.object == null) {
            self.message(1, .d3d11_create_sampler_state_failed, null);
            return false;
        }
        self.label(sampler.object, desc.label);
        return true;
    }
    pub fn discardSampler(_: *Backend, sampler: *r.Sampler) void {
        sdk.release(sampler.object);
        sampler.* = .{};
    }
    fn slotsValid(self: *Backend, desc: t.ShaderDesc) bool {
        for (desc.uniform_blocks) |block| if (block.stage != .none and block.hlsl_register_b_n >= 8) {
            self.message(1, .d3d11_uniformblock_hlsl_register_b_out_of_range, null);
            return false;
        };
        for (desc.views) |view| {
            if (view.texture.stage != .none and view.texture.hlsl_register_t_n >= 32) {
                self.message(1, .d3d11_image_hlsl_register_t_out_of_range, null);
                return false;
            }
            if (view.storage_buffer.stage != .none) {
                if (view.storage_buffer.hlsl_register_t_n >= 32) {
                    self.message(1, .d3d11_storagebuffer_hlsl_register_t_out_of_range, null);
                    return false;
                }
                if (view.storage_buffer.hlsl_register_u_n >= 32) {
                    self.message(1, .d3d11_storagebuffer_hlsl_register_u_out_of_range, null);
                    return false;
                }
            }
            if (view.storage_image.stage != .none and view.storage_image.hlsl_register_u_n >= 32) {
                self.message(1, .d3d11_storageimage_hlsl_register_u_out_of_range, null);
                return false;
            }
        }
        for (desc.samplers) |sampler| if (sampler.stage != .none and sampler.hlsl_register_s_n >= 12) {
            self.message(1, .d3d11_sampler_hlsl_register_s_out_of_range, null);
            return false;
        };
        return true;
    }
    pub fn createShader(self: *Backend, shader: *r.Shader, desc: t.ShaderDesc) bool {
        if (!self.slotsValid(desc)) return false;
        for (&shader.semantic_names, &shader.semantic_indices, desc.attrs) |*name, *index, attr| {
            if (attr.hlsl_sem_name) |value| {
                const count = @min(31, std.mem.len(value));
                @memcpy(name[0..count], value[0..count]);
            }
            index.* = attr.hlsl_sem_index;
        }
        for (desc.uniform_blocks, 0..) |block, i| {
            shader.uniform_registers[i] = block.hlsl_register_b_n;
            if (block.stage == .none) continue;
            const native: sdk.BufferDesc = .{ .byte_width = (block.size + 15) & ~@as(u32, 15), .usage = c.usage_default, .bind_flags = c.bind_constant_buffer };
            const status = sdk.createBuffer(self.device, @ptrCast(&native), null, &shader.uniform_buffers[i]);
            if (status < 0 or shader.uniform_buffers[i] == null) {
                self.message(1, .d3d11_create_constant_buffer_failed, null);
                return false;
            }
            self.label(shader.uniform_buffers[i], desc.label);
            // D3D updates the entire rounded constant buffer. Pad an unaligned
            // public range so the driver never reads beyond the caller's data.
            if (block.size & 15 != 0) {
                const upload = self.allocator.alloc(u8, native.byte_width) catch return false;
                @memset(upload, 0);
                shader.uniform_uploads[i] = upload;
            }
            const slot = block.hlsl_register_b_n;
            switch (block.stage) {
                .vertex => shader.vertex_uniforms[slot] = shader.uniform_buffers[i],
                .fragment => shader.fragment_uniforms[slot] = shader.uniform_buffers[i],
                .compute => shader.compute_uniforms[slot] = shader.uniform_buffers[i],
                else => unreachable,
            }
        }
        for (desc.views, 0..) |view, i| {
            if (view.storage_buffer.stage != .none) {
                shader.srv_registers[i] = view.storage_buffer.hlsl_register_t_n;
                shader.uav_registers[i] = view.storage_buffer.hlsl_register_u_n;
            } else if (view.texture.stage != .none) shader.srv_registers[i] = view.texture.hlsl_register_t_n else if (view.storage_image.stage != .none) shader.uav_registers[i] = view.storage_image.hlsl_register_u_n;
        }
        for (desc.samplers, 0..) |sampler, i| shader.sampler_registers[i] = sampler.hlsl_register_s_n;
        var vertex_valid = false;
        var fragment_valid = false;
        var compute_valid = false;
        inline for (.{ .{ "vertex_func", "vertex" }, .{ "fragment_func", "fragment" }, .{ "compute_func", "compute" } }) |entry| {
            const function = @field(desc, entry[0]);
            if (function.bytecode.ptr != null or function.source != null) {
                var blob: ?*sdk.Object = null;
                var data = function.bytecode;
                if (data.ptr == null) {
                    blob = self.compiler.compile(function, self.debugging, self.logger);
                    if (blob) |value| data = .{ .ptr = sdk.getBufferPointer(value), .size = sdk.getBufferSize(value) };
                }
                defer sdk.release(blob);
                var valid = false;
                if (data.ptr != null and data.size > 0) {
                    const status = switch (comptime entry[1][0]) {
                        'v' => sdk.createVertexShader(self.device, data.ptr, data.size, null, &shader.vertex),
                        'f' => sdk.createPixelShader(self.device, data.ptr, data.size, null, &shader.fragment),
                        'c' => sdk.createComputeShader(self.device, data.ptr, data.size, null, &shader.compute),
                        else => unreachable,
                    };
                    valid = status >= 0 and @field(shader, entry[1]) != null;
                    if (valid) {
                        if (comptime entry[1][0] == 'v') {
                            const bytes: [*]const u8 = @ptrCast(data.ptr.?);
                            shader.vertex_bytecode = self.allocator.dupe(u8, bytes[0..data.size]) catch return false;
                        }
                        if (comptime entry[1][0] != 'c') self.label(@field(shader, entry[1]), desc.label);
                    }
                }
                switch (comptime entry[1][0]) {
                    'v' => vertex_valid = valid,
                    'f' => fragment_valid = valid,
                    'c' => compute_valid = valid,
                    else => unreachable,
                }
            }
        }
        return (vertex_valid and fragment_valid) or compute_valid;
    }
    pub fn discardShader(self: *Backend, shader: *r.Shader) void {
        sdk.release(shader.vertex);
        sdk.release(shader.fragment);
        sdk.release(shader.compute);
        for (shader.uniform_buffers) |buffer| sdk.release(buffer);
        for (shader.uniform_uploads) |upload| if (upload) |data| self.allocator.free(data);
        if (shader.vertex_bytecode) |data| self.allocator.free(data);
        shader.* = .{};
    }

    pub fn createPipeline(self: *Backend, pipeline: *r.Pipeline, shader: *const r.Shader, desc: t.PipelineDesc) bool {
        if (desc.compute) return true;
        const bytecode = shader.vertex_bytecode orelse return false;
        pipeline.index_format = convert.indexFormat(desc.index_type);
        pipeline.topology = convert.topology(desc.primitive_type);
        pipeline.stencil_ref = desc.stencil.ref;
        var elements: [16]sdk.InputElementDesc = @splat(.{});
        var count: usize = 0;
        for (desc.layout.attrs, 0..) |attr, i| {
            if (attr.format == .invalid) break;
            const layout = desc.layout.buffers[@intCast(attr.buffer_index)];
            elements[i] = .{
                .semantic_name = &shader.semantic_names[i],
                .semantic_index = shader.semantic_indices[i],
                .format = convert.vertexFormat(attr.format),
                .input_slot = @intCast(attr.buffer_index),
                .aligned_byte_offset = @intCast(attr.offset),
                .input_slot_class = convert.inputClass(layout.step_func),
                .instance_data_step_rate = if (layout.step_func == .per_instance) @intCast(layout.step_rate) else 0,
            };
            pipeline.vertex_strides[@intCast(attr.buffer_index)] = @intCast(layout.stride);
            count += 1;
        }
        if (count > 0) {
            const status = sdk.createInputLayout(self.device, &elements, @intCast(count), bytecode.ptr, bytecode.len, &pipeline.input_layout);
            if (status < 0 or pipeline.input_layout == null) {
                self.message(1, .d3d11_create_input_layout_failed, null);
                return false;
            }
            self.label(pipeline.input_layout, desc.label);
        }
        const rasterizer: sdk.RasterizerDesc = .{
            .fill_mode = c.fill_solid,
            .cull_mode = convert.cullMode(desc.cull_mode),
            .front_counter_clockwise = @intFromBool(desc.face_winding == .ccw),
            .depth_bias = @intFromFloat(desc.depth.bias),
            .depth_bias_clamp = desc.depth.bias_clamp,
            .slope_scaled_depth_bias = desc.depth.bias_slope_scale,
            .depth_clip_enable = 1,
            .scissor_enable = 1,
            .multisample_enable = @intFromBool(desc.sample_count > 1),
        };
        if (sdk.createRasterizerState(self.device, @ptrCast(&rasterizer), &pipeline.rasterizer) < 0 or pipeline.rasterizer == null) {
            self.message(1, .d3d11_create_rasterizer_state_failed, null);
            return false;
        }
        self.label(pipeline.rasterizer, desc.label);
        const depth_stencil: sdk.DepthStencilDesc = .{
            .depth_enable = 1,
            .depth_write_mask = if (desc.depth.write_enabled) c.depth_write_mask_all else c.depth_write_mask_zero,
            .depth_func = convert.compareFunc(desc.depth.compare),
            .stencil_enable = @intFromBool(desc.stencil.enabled),
            .stencil_read_mask = desc.stencil.read_mask,
            .stencil_write_mask = desc.stencil.write_mask,
            .front_face = stencilFace(desc.stencil.front),
            .back_face = stencilFace(desc.stencil.back),
        };
        if (sdk.createDepthStencilState(self.device, @ptrCast(&depth_stencil), &pipeline.depth_stencil) < 0 or pipeline.depth_stencil == null) {
            self.message(1, .d3d11_create_depth_stencil_state_failed, null);
            return false;
        }
        self.label(pipeline.depth_stencil, desc.label);
        var blend: sdk.BlendDesc = .{ .alpha_to_coverage_enable = @intFromBool(desc.alpha_to_coverage_enabled), .independent_blend_enable = 1 };
        for (&blend.render_target, 0..) |*target, i| {
            if (i < @as(usize, @intCast(desc.color_count))) {
                const color = desc.colors[i];
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
            } else target.* = .{ .src_blend = c.blend_one, .dest_blend = c.blend_zero, .blend_op = c.blend_op_add, .src_blend_alpha = c.blend_one, .dest_blend_alpha = c.blend_zero, .blend_op_alpha = c.blend_op_add, .render_target_write_mask = @intCast(c.color_write_enable_all) };
        }
        if (sdk.createBlendState(self.device, @ptrCast(&blend), &pipeline.blend) < 0 or pipeline.blend == null) {
            self.message(1, .d3d11_create_blend_state_failed, null);
            return false;
        }
        self.label(pipeline.blend, desc.label);
        return true;
    }
    fn stencilFace(value: t.StencilFaceState) sdk.StencilOpDesc {
        return .{ .stencil_fail_op = convert.stencilOp(value.fail_op), .stencil_depth_fail_op = convert.stencilOp(value.depth_fail_op), .stencil_pass_op = convert.stencilOp(value.pass_op), .stencil_func = convert.compareFunc(value.compare) };
    }
    pub fn discardPipeline(_: *Backend, pipeline: *r.Pipeline) void {
        sdk.release(pipeline.input_layout);
        sdk.release(pipeline.rasterizer);
        sdk.release(pipeline.depth_stencil);
        sdk.release(pipeline.blend);
        pipeline.* = .{};
    }
    pub fn createView(self: *Backend, view: *r.View, desc: t.ViewDesc, buffer: ?*const r.Buffer, buffer_desc: t.BufferDesc, image: ?*const r.Image, image_desc: t.ImageDesc) bool {
        if (desc.storage_buffer.buffer.id != 0) {
            const resource = buffer.?.object.?;
            const first: u32 = @intCast(@divTrunc(desc.storage_buffer.offset, 4));
            const count: u32 = @intCast(@divTrunc(buffer_desc.size - @as(usize, @intCast(desc.storage_buffer.offset)), 4));
            var srv: sdk.ShaderResourceViewDesc = .{ .format = c.format_r32_typeless, .view_dimension = c.srv_dimension_bufferex };
            srv.data.buffer_ex = .{ .first_element = first, .num_elements = count, .flags = c.bufferex_srv_flag_raw };
            if (sdk.createShaderResourceView(self.device, resource, @ptrCast(&srv), &view.srv) < 0 or view.srv == null) {
                self.message(1, .d3d11_create_buffer_srv_failed, null);
                return false;
            }
            self.label(view.srv, desc.label);
            if (!buffer_desc.usage.write_transient) {
                var uav: sdk.UnorderedAccessViewDesc = .{ .format = c.format_r32_typeless, .view_dimension = c.uav_dimension_buffer };
                uav.data.buffer = .{ .first_element = first, .num_elements = count, .flags = c.buffer_uav_flag_raw };
                if (sdk.createUnorderedAccessView(self.device, resource, @ptrCast(&uav), &view.uav) < 0 or view.uav == null) {
                    self.message(1, .d3d11_create_buffer_uav_failed, null);
                    return false;
                }
                self.label(view.uav, desc.label);
            }
            return true;
        }
        const parent = image orelse return false;
        const object = parent.resource orelse return false;
        const msaa = image_desc.sample_count > 1;
        if (desc.texture.image.id != 0) {
            const texture = desc.texture;
            var srv: sdk.ShaderResourceViewDesc = .{ .format = convert.srvFormat(image_desc.pixel_format) };
            switch (image_desc.type) {
                .@"2d" => {
                    srv.view_dimension = if (msaa) c.srv_dimension_texture2dms else c.srv_dimension_texture2d;
                    if (!msaa) srv.data.texture_2d = .{ .most_detailed_mip = @intCast(texture.mip_levels.base), .mip_levels = @intCast(texture.mip_levels.count) };
                },
                .cube => {
                    srv.view_dimension = c.srv_dimension_texturecube;
                    srv.data.texture_cube = .{ .most_detailed_mip = @intCast(texture.mip_levels.base), .mip_levels = @intCast(texture.mip_levels.count) };
                },
                .array => {
                    srv.view_dimension = if (msaa) c.srv_dimension_texture2dmsarray else c.srv_dimension_texture2darray;
                    if (msaa) srv.data.texture_2d_ms_array = .{ .first_array_slice = @intCast(texture.slices.base), .array_size = @intCast(texture.slices.count) } else srv.data.texture_2d_array = .{ .most_detailed_mip = @intCast(texture.mip_levels.base), .mip_levels = @intCast(texture.mip_levels.count), .first_array_slice = @intCast(texture.slices.base), .array_size = @intCast(texture.slices.count) };
                },
                .@"3d" => {
                    srv.view_dimension = c.srv_dimension_texture3d;
                    srv.data.texture_3d = .{ .most_detailed_mip = @intCast(texture.mip_levels.base), .mip_levels = @intCast(texture.mip_levels.count) };
                },
                else => unreachable,
            }
            if (sdk.createShaderResourceView(self.device, object, @ptrCast(&srv), &view.srv) < 0 or view.srv == null) {
                self.message(1, .d3d11_create_2d_srv_failed, null);
                return false;
            }
            self.label(view.srv, desc.label);
        } else if (desc.storage_image.image.id != 0) {
            const selected = desc.storage_image;
            var uav: sdk.UnorderedAccessViewDesc = .{ .format = convert.rtvUavFormat(image_desc.pixel_format) };
            switch (image_desc.type) {
                .@"2d" => {
                    uav.view_dimension = c.uav_dimension_texture2d;
                    uav.data.texture_2d = .{ .mip_slice = @intCast(selected.mip_level) };
                },
                .cube, .array => {
                    uav.view_dimension = c.uav_dimension_texture2darray;
                    uav.data.texture_2d_array = .{ .mip_slice = @intCast(selected.mip_level), .first_array_slice = @intCast(selected.slice), .array_size = 1 };
                },
                .@"3d" => {
                    uav.view_dimension = c.uav_dimension_texture3d;
                    uav.data.texture_3d = .{ .mip_slice = @intCast(selected.mip_level), .first_w_slice = @intCast(selected.slice), .w_size = 1 };
                },
                else => unreachable,
            }
            if (sdk.createUnorderedAccessView(self.device, object, @ptrCast(&uav), &view.uav) < 0 or view.uav == null) {
                self.message(1, .d3d11_create_uav_failed, null);
                return false;
            }
            self.label(view.uav, desc.label);
        } else if (desc.color_attachment.image.id != 0) {
            const selected = desc.color_attachment;
            var rtv: sdk.RenderTargetViewDesc = .{ .format = convert.rtvUavFormat(image_desc.pixel_format) };
            switch (image_desc.type) {
                .@"2d" => {
                    rtv.view_dimension = if (msaa) c.rtv_dimension_texture2dms else c.rtv_dimension_texture2d;
                    if (!msaa) rtv.data.texture_2d = .{ .mip_slice = @intCast(selected.mip_level) };
                },
                .cube, .array => {
                    rtv.view_dimension = if (msaa) c.rtv_dimension_texture2dmsarray else c.rtv_dimension_texture2darray;
                    if (msaa) rtv.data.texture_2d_ms_array = .{ .first_array_slice = @intCast(selected.slice), .array_size = 1 } else rtv.data.texture_2d_array = .{ .mip_slice = @intCast(selected.mip_level), .first_array_slice = @intCast(selected.slice), .array_size = 1 };
                },
                .@"3d" => {
                    rtv.view_dimension = c.rtv_dimension_texture3d;
                    rtv.data.texture_3d = .{ .mip_slice = @intCast(selected.mip_level), .first_w_slice = @intCast(selected.slice), .w_size = 1 };
                },
                else => unreachable,
            }
            if (sdk.createRenderTargetView(self.device, object, @ptrCast(&rtv), &view.rtv) < 0 or view.rtv == null) {
                self.message(1, .d3d11_create_rtv_failed, null);
                return false;
            }
            self.label(view.rtv, desc.label);
        } else if (desc.depth_stencil_attachment.image.id != 0) {
            const selected = desc.depth_stencil_attachment;
            var dsv: sdk.DepthStencilViewDesc = .{ .format = convert.dsvFormat(image_desc.pixel_format) };
            switch (image_desc.type) {
                .@"2d" => {
                    dsv.view_dimension = if (msaa) c.dsv_dimension_texture2dms else c.dsv_dimension_texture2d;
                    if (!msaa) dsv.data.texture_2d = .{ .mip_slice = @intCast(selected.mip_level) };
                },
                .cube, .array => {
                    dsv.view_dimension = if (msaa) c.dsv_dimension_texture2dmsarray else c.dsv_dimension_texture2darray;
                    if (msaa) dsv.data.texture_2d_ms_array = .{ .first_array_slice = @intCast(selected.slice), .array_size = 1 } else dsv.data.texture_2d_array = .{ .mip_slice = @intCast(selected.mip_level), .first_array_slice = @intCast(selected.slice), .array_size = 1 };
                },
                else => unreachable,
            }
            if (sdk.createDepthStencilView(self.device, object, @ptrCast(&dsv), &view.dsv) < 0 or view.dsv == null) {
                self.message(1, .d3d11_create_dsv_failed, null);
                return false;
            }
            self.label(view.dsv, desc.label);
        }
        // Resolve-attachment views only retain their common image reference.
        return true;
    }
    /// Readback (zicr extension): copies into a CPU-readable staging resource and
    /// maps it, which waits for the copy and all earlier work.
    pub fn readBuffer(self: *Backend, buffer: *r.Buffer, desc: t.BufferDesc, offset: usize, out: []u8) bool {
        _ = desc;
        if (buffer.staging) |data| {
            @memcpy(out, data[offset..][0..out.len]);
            return true;
        }
        const staging_desc: sdk.BufferDesc = .{ .byte_width = @intCast(out.len), .usage = c.usage_staging, .cpu_access_flags = c.cpu_access_read };
        var staging: ?*sdk.Object = null;
        if (sdk.createBuffer(self.device, @ptrCast(&staging_desc), null, &staging) < 0) return false;
        defer sdk.release(staging);
        const box: sdk.Box = .{ .left = @intCast(offset), .right = @intCast(offset + out.len), .bottom = 1, .back = 1 };
        sdk.copySubresourceRegion(self.context, staging, 0, 0, 0, 0, buffer.object, 0, @ptrCast(&box));
        var mapped: sdk.MappedSubresource = .{};
        if (sdk.map(self.context, staging, 0, c.map_read, 0, @ptrCast(&mapped)) < 0) return false;
        defer sdk.unmap(self.context, staging, 0);
        const src: [*]const u8 = @ptrCast(mapped.data orelse return false);
        @memcpy(out, src[0..out.len]);
        return true;
    }

    pub fn readImage(self: *Backend, image: *r.Image, desc: t.ImageDesc, region: *const core.ReadRegion, out: []u8) bool {
        const volume = desc.type == .@"3d";
        const layers: u32 = if (volume) 1 else region.num_slices;
        var staging: ?*sdk.Object = null;
        if (volume) {
            const tex_desc: sdk.Texture3DDesc = .{ .width = region.width, .height = region.height, .depth = region.num_slices, .mip_levels = 1, .format = image.format, .usage = c.usage_staging, .cpu_access_flags = c.cpu_access_read };
            if (sdk.createTexture3D(self.device, @ptrCast(&tex_desc), null, &staging) < 0) return false;
        } else {
            const tex_desc: sdk.Texture2DDesc = .{ .width = region.width, .height = region.height, .mip_levels = 1, .array_size = layers, .format = image.format, .sample_desc = .{ .count = 1 }, .usage = c.usage_staging, .cpu_access_flags = c.cpu_access_read };
            if (sdk.createTexture2D(self.device, @ptrCast(&tex_desc), null, &staging) < 0) return false;
        }
        defer sdk.release(staging);
        const mip_count: u32 = @intCast(desc.num_mipmaps);
        for (0..layers) |i| {
            const layer: u32 = @intCast(i);
            const box: sdk.Box = .{
                .left = region.x,
                .top = region.y,
                .front = if (volume) region.slice else 0,
                .right = region.x + region.width,
                .bottom = region.y + region.height,
                .back = if (volume) region.slice + region.num_slices else 1,
            };
            const src_sub = convert.subresource(region.mip_level, if (volume) 0 else region.slice + layer, mip_count);
            sdk.copySubresourceRegion(self.context, staging, layer, 0, 0, 0, image.resource, src_sub, @ptrCast(&box));
        }
        const row_bytes: usize = @intCast(formats.rowPitch(desc.pixel_format, @intCast(region.width), 1));
        for (0..layers) |i| {
            var mapped: sdk.MappedSubresource = .{};
            if (sdk.map(self.context, staging, @intCast(i), c.map_read, 0, @ptrCast(&mapped)) < 0) return false;
            defer sdk.unmap(self.context, staging, @intCast(i));
            const src: [*]const u8 = @ptrCast(mapped.data orelse return false);
            const depth: usize = if (volume) region.num_slices else 1;
            for (0..depth) |z| {
                const slice_index = if (volume) z else i;
                for (0..region.height) |y| {
                    const src_row = src[z * mapped.depth_pitch + y * mapped.row_pitch ..][0..row_bytes];
                    @memcpy(out[slice_index * region.bytes_per_slice + y * region.bytes_per_row ..][0..row_bytes], src_row);
                }
            }
        }
        return true;
    }

    pub fn discardView(_: *Backend, view: *r.View) void {
        sdk.release(view.srv);
        sdk.release(view.uav);
        sdk.release(view.rtv);
        sdk.release(view.dsv);
        view.* = .{};
    }
};
