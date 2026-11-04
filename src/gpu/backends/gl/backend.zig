//! Native GL resource operations. References the GL backend in sokol_gfx.h.
//! Invokes the active context driver through native Zig function pointers.
const std = @import("std");
const is_web = builtin.cpu.arch.isWasm();
const builtin = @import("builtin");
const t = @import("../../types.zig");
const e = @import("../../enums.zig");
const formats = @import("../../formats.zig");
const caps = @import("capabilities.zig");
const c = @import("constants.zig");
const convert = @import("convert.zig");
const r = @import("resources.zig");
const Cache = @import("cache.zig").Cache;
const driver_api = @import("dispatch.zig");
const core = @import("../../core.zig");

const apple_unpack_workaround = switch (builtin.os.tag) {
    .macos, .ios, .maccatalyst, .tvos, .watchos, .visionos => true,
    else => false,
};

pub const Backend = struct {
    const Commands = @import("commands.zig").Commands(@This());
    pub const barriers = Commands.barriers;
    pub const beginPass = Commands.beginPass;
    pub const endPass = Commands.endPass;
    pub const viewport = Commands.viewport;
    pub const scissor = Commands.scissor;
    pub const applyPipeline = Commands.applyPipeline;
    pub const renderState = Commands.renderState;
    pub const applyBindings = Commands.applyBindings;
    pub const applyUniforms = Commands.applyUniforms;
    pub const draw = Commands.draw;
    pub const dispatch = Commands.dispatch;
    pub const commit = Commands.commit;
    pub const attachView = Commands.attachView;
    pub const toggle = Commands.toggle;
    allocator: std.mem.Allocator,
    cache: Cache,
    logger: t.Logger,
    gles: bool,
    version: i32,
    extensions: caps.Extensions,
    format_info: caps.Table,
    max_anisotropy: i32 = 1,
    immutable_storage: bool = false,
    vao: u32 = 0,
    framebuffer: u32 = 0,
    readback_framebuffer: u32 = 0,
    apple_unpack_warned: bool = false,

    pub fn init(allocator: std.mem.Allocator, kind: e.Backend, loader: driver_api.GetProcAddress, user_data: ?*anyopaque, logger: t.Logger) !Backend {
        std.debug.assert(kind == .glcore or kind == .gles3);
        const driver = driver_api.Dispatch.load(loader, user_data);
        try driver.require(.{ "getIntegerv", "getStringi" });
        var major: i32 = 0;
        var minor: i32 = 0;
        driver.getIntegerv.?(c.major_version, @ptrCast(&major));
        driver.getIntegerv.?(c.minor_version, @ptrCast(&minor));
        const version = major * 100 + minor * 10;
        const gles = kind == .gles3;
        if (version < (if (gles) @as(i32, 300) else @as(i32, 330))) return error.UnsupportedOpenGlVersion;
        try driver.require(.{
            "bindVertexArray", "genVertexArrays", "deleteVertexArrays", "genFramebuffers", "deleteFramebuffers", "bindFramebuffer", "bindRenderbuffer", "genRenderbuffers", "deleteRenderbuffers", "renderbufferStorageMultisample", "framebufferTextureLayer", "framebufferTexture2D", "framebufferRenderbuffer", "checkFramebufferStatus", "drawBuffers", "readBuffer", "blitFramebuffer", "clearBufferfi", "clearBufferfv", "clearBufferiv", "genBuffers", "deleteBuffers", "bindBuffer", "bufferData", "bufferSubData", "copyBufferSubData", "genTextures", "deleteTextures", "activeTexture", "bindTexture", "texParameteri", "texImage2D", "texImage3D", "texSubImage2D", "texSubImage3D", "compressedTexImage2D", "compressedTexImage3D", "compressedTexSubImage2D", "compressedTexSubImage3D", "genSamplers", "deleteSamplers", "bindSampler", "samplerParameteri", "samplerParameterf", "samplerParameterfv", "createShader", "shaderSource", "compileShader", "getShaderiv", "getShaderInfoLog", "deleteShader", "createProgram", "deleteProgram", "attachShader", "linkProgram", "getProgramiv", "getProgramInfoLog", "getUniformLocation", "getAttribLocation", "useProgram", "uniform1i", "uniform1fv", "uniform2fv", "uniform3fv", "uniform4fv", "uniform1iv", "uniform2iv", "uniform3iv", "uniform4iv", "uniformMatrix4fv", "enable", "disable", "depthFunc", "depthMask", "stencilFunc", "stencilOp", "stencilFuncSeparate", "stencilOpSeparate", "stencilMask", "blendFuncSeparate", "blendEquationSeparate", "blendColor", "colorMask", "polygonOffset", "frontFace", "cullFace", "pixelStorei", "viewport", "scissor", "enableVertexAttribArray", "disableVertexAttribArray", "vertexAttribPointer", "vertexAttribIPointer", "vertexAttribDivisor", "drawArrays", "drawElements", "drawArraysInstanced", "drawElementsInstanced",
        });
        const compute = version >= (if (gles) @as(i32, 310) else @as(i32, 430));
        if (compute) try driver.require(.{ "dispatchCompute", "memoryBarrier", "bindBufferRange", "bindBufferBase", "bindImageTexture" });
        if (!gles or version >= 320) try driver.require(.{ "colorMaski", "drawElementsBaseVertex", "drawElementsInstancedBaseVertex" });
        if (!gles and version >= 420) try driver.require(.{ "drawElementsInstancedBaseVertexBaseInstance", "drawArraysInstancedBaseInstance" });
        if (!gles) try driver.require(.{ "texImage2DMultisample", "texImage3DMultisample" });
        if (!gles and version >= 430) try driver.require(.{"textureView"});
        if (gles) try driver.require(.{ "texStorage2D", "texStorage3D", "invalidateFramebuffer" });
        if (!gles and version >= 420) try driver.require(.{ "texStorage2D", "texStorage3D", "texStorage2DMultisample", "texStorage3DMultisample" });
        var extensions: caps.Extensions = .{ .etc2 = gles and !is_web };
        var extension_count: i32 = 0;
        driver.getIntegerv.?(c.num_extensions, @ptrCast(&extension_count));
        for (0..@intCast(@max(0, extension_count))) |i| {
            const name = driver.getStringi.?(c.extensions, @intCast(i)) orelse continue;
            const extension = std.mem.span(name);
            const patterns = .{
                .{ "_texture_compression_s3tc", "s3tc" },             .{ "_compressed_texture_s3tc", "s3tc" },
                .{ "_texture_compression_rgtc", "rgtc" },             .{ "_texture_compression_bptc", "bptc" },
                .{ "_ES3_compatibility", "etc2" },                    .{ "_compressed_texture_etc", "etc2" },
                .{ "_texture_compression_astc_ldr", "astc" },         .{ "_compressed_texture_astc", "astc" },
                .{ "_color_buffer_float", "colorbuffer_float" },      .{ "_color_buffer_half_float", "colorbuffer_half_float" },
                .{ "_texture_float_linear", "texture_float_linear" }, .{ "_float_blend", "float_blend" },
                .{ "_texture_filter_anisotropic", "anisotropic" },
            };
            inline for (patterns) |pattern| {
                if (std.mem.indexOf(u8, extension, pattern[0]) != null) @field(extensions, pattern[1]) = true;
            }
        }
        if (is_web and extensions.colorbuffer_float) extensions.colorbuffer_half_float = true;
        const features: t.Features = .{
            .image_clamp_to_border = !gles,
            .mrt_independent_write_mask = !gles or version >= 320,
            .compute = compute,
            .msaa_texture_bindings = !gles,
            .gl_texture_views = version >= 430,
            .separate_buffer_types = gles and is_web,
            .draw_base_vertex = version >= 320,
            .draw_base_instance = !gles and version >= 420,
            .dual_source_blending = !gles and version >= 330,
            .vertexformat_int10_n2 = true,
            .copy_buffer_to_image_relaxed_buffer_type = true,
            .copy_buffer_to_image_relaxed_bytes_per_row = true,
        };
        var backend: Backend = .{
            .allocator = allocator,
            .cache = .{ .driver = driver, .features = features },
            .logger = logger,
            .gles = gles,
            .version = version,
            .extensions = extensions,
            .format_info = caps.formats(gles, compute, extensions),
            .immutable_storage = gles or version >= 420,
        };
        const limits = &backend.cache.limits;
        limits.max_image_size_2d = backend.integer(c.max_texture_size);
        limits.max_image_size_array = limits.max_image_size_2d;
        limits.max_image_size_cube = backend.integer(c.max_cube_map_texture_size);
        limits.max_image_size_3d = backend.integer(c.max_3d_texture_size);
        limits.max_image_array_layers = backend.integer(c.max_array_texture_layers);
        limits.max_vertex_attrs = @min(backend.integer(c.max_vertex_attribs), 16);
        limits.max_color_attachments = @min(backend.integer(c.max_draw_buffers), 8);
        limits.max_texture_bindings_per_stage = @min(backend.integer(c.max_texture_image_units), 32);
        if (compute) {
            limits.max_storage_buffer_bindings_per_stage = @min(backend.integer(c.max_shader_storage_buffer_bindings), 32);
            limits.max_storage_image_bindings_per_stage = @min(backend.integer(c.max_image_units), 32);
        }
        limits.gl_max_vertex_uniform_components = backend.integer(c.max_vertex_uniform_components);
        limits.gl_max_combined_texture_image_units = backend.integer(c.max_combined_texture_image_units);
        if (extensions.anisotropic) backend.max_anisotropy = backend.integer(c.max_texture_max_anisotropy_ext);
        errdefer backend.deinit();
        driver.genVertexArrays.?(1, @ptrCast(&backend.vao));
        if (backend.vao == 0) return error.OpenGlResourceCreationFailed;
        driver.bindVertexArray.?(backend.vao);
        driver.genFramebuffers.?(1, @ptrCast(&backend.framebuffer));
        if (backend.framebuffer == 0) return error.OpenGlResourceCreationFailed;
        driver.pixelStorei.?(c.unpack_alignment, 1);
        if (!gles) driver.enable.?(c.texture_cube_map_seamless);
        backend.cache.reset(backend.vao, gles);
        return backend;
    }

    pub fn deinit(self: *Backend) void {
        if (self.readback_framebuffer != 0) self.cache.driver.deleteFramebuffers.?(1, @ptrCast(&self.readback_framebuffer));
        if (self.framebuffer != 0) self.cache.driver.deleteFramebuffers.?(1, @ptrCast(&self.framebuffer));
        if (self.vao != 0) self.cache.driver.deleteVertexArrays.?(1, @ptrCast(&self.vao));
        self.framebuffer = 0;
        self.vao = 0;
    }
    fn integer(self: *const Backend, token: u32) i32 {
        var value: i32 = 0;
        self.cache.driver.getIntegerv.?(token, @ptrCast(&value));
        return value;
    }
    fn message(self: *Backend, level: u32, item: e.LogItem, text: ?[*:0]const u8) void {
        if (self.logger.func) |callback| callback("sg", level, @backingInt(item), text, 0, null, self.logger.user_data);
    }

    pub fn createBuffer(self: *Backend, buffer: *r.Buffer, desc: t.BufferDesc) bool {
        if (apple_unpack_workaround and (desc.usage.staging_buffer or desc.usage.staging_index_buffer)) {
            buffer.staging = self.allocator.alloc(u8, desc.size) catch return false;
            return true;
        }
        buffer.injected = desc.gl_buffer != 0;
        const target = convert.bufferTarget(desc.usage);
        const slots: usize = if (desc.usage.write_transient) 2 else 1;
        for (buffer.ids[0..slots]) |*id| {
            if (buffer.injected) {
                id.* = desc.gl_buffer;
                continue;
            }
            self.cache.driver.genBuffers.?(1, @ptrCast(id));
            if (id.* == 0) return false;
            const saved = self.cache.buffers[Cache.bufferIndex(target)];
            self.cache.bindBuffer(target, id.*);
            self.cache.driver.bufferData.?(target, @intCast(desc.size), null, convert.bufferUsage(desc.usage));
            if (desc.data.ptr) |data| self.cache.driver.bufferSubData.?(target, 0, @intCast(desc.size), data);
            self.cache.restoreBuffer(target, saved);
        }
        return true;
    }
    pub fn discardBuffer(self: *Backend, buffer: *r.Buffer) void {
        if (buffer.staging) |data| self.allocator.free(data);
        for (&buffer.ids) |*id| {
            if (id.* == 0) continue;
            self.cache.invalidateBuffer(id.*);
            if (!buffer.injected) self.cache.driver.deleteBuffers.?(1, @ptrCast(id));
        }
        buffer.* = .{};
    }
    pub fn writeBuffer(self: *Backend, buffer: *r.Buffer, usage: t.BufferUsage, active_slot: i32, desc: t.WriteBufferDesc) void {
        const source: [*]const u8 = @ptrCast(desc.src.data.ptr.?);
        const data = source + desc.src.offset;
        if (buffer.staging) |staging| {
            @memcpy(staging[desc.dst.offset..][0..desc.size], data[0..desc.size]);
            return;
        }
        const target = convert.bufferTarget(usage);
        const saved = self.cache.buffers[Cache.bufferIndex(target)];
        self.cache.bindBuffer(target, buffer.ids[@intCast(active_slot)]);
        self.cache.driver.bufferSubData.?(target, @intCast(desc.dst.offset), @intCast(desc.size), data);
        self.cache.restoreBuffer(target, saved);
    }
    pub fn createSampler(self: *Backend, sampler: *r.Sampler, desc: t.SamplerDesc) bool {
        sampler.injected = desc.gl_sampler != 0;
        if (sampler.injected) {
            sampler.id = desc.gl_sampler;
            return true;
        }
        const driver = self.cache.driver;
        driver.genSamplers.?(1, @ptrCast(&sampler.id));
        if (sampler.id == 0) return false;
        driver.samplerParameteri.?(sampler.id, c.texture_min_filter, @intCast(convert.minFilter(desc.min_filter, desc.mipmap_filter)));
        driver.samplerParameteri.?(sampler.id, c.texture_mag_filter, @intCast(convert.magFilter(desc.mag_filter)));
        driver.samplerParameterf.?(sampler.id, c.texture_min_lod, std.math.clamp(desc.min_lod, 0, 1000));
        driver.samplerParameterf.?(sampler.id, c.texture_max_lod, std.math.clamp(desc.max_lod, 0, 1000));
        driver.samplerParameteri.?(sampler.id, c.texture_wrap_s, @intCast(convert.wrap(desc.wrap_u, self.gles)));
        driver.samplerParameteri.?(sampler.id, c.texture_wrap_t, @intCast(convert.wrap(desc.wrap_v, self.gles)));
        driver.samplerParameteri.?(sampler.id, c.texture_wrap_r, @intCast(convert.wrap(desc.wrap_w, self.gles)));
        if (!self.gles) {
            const border: [4]f32 = switch (desc.border_color) {
                .transparent_black => .{ 0, 0, 0, 0 },
                .opaque_white => .{ 1, 1, 1, 1 },
                else => .{ 0, 0, 0, 1 },
            };
            driver.samplerParameterfv.?(sampler.id, c.texture_border_color, &border);
        }
        driver.samplerParameteri.?(sampler.id, c.texture_compare_mode, if (desc.compare == .never) @intCast(c.none) else @intCast(c.compare_ref_to_texture));
        if (desc.compare != .never) driver.samplerParameteri.?(sampler.id, c.texture_compare_func, @intCast(convert.compareFunc(desc.compare)));
        if (self.extensions.anisotropic and desc.max_anisotropy > 1) driver.samplerParameteri.?(sampler.id, c.texture_max_anisotropy_ext, @intCast(@min(desc.max_anisotropy, @as(u32, @intCast(self.max_anisotropy)))));
        return true;
    }
    pub fn discardSampler(self: *Backend, sampler: *r.Sampler) void {
        self.cache.invalidateTexture(0, sampler.id);
        if (!sampler.injected and sampler.id != 0) self.cache.driver.deleteSamplers.?(1, @ptrCast(&sampler.id));
        sampler.* = .{};
    }
    fn shaderLog(self: *Backend, id: u32, program: bool, item: e.LogItem) void {
        const driver = self.cache.driver;
        var length: i32 = 0;
        if (program) driver.getProgramiv.?(id, c.info_log_length, @ptrCast(&length)) else driver.getShaderiv.?(id, c.info_log_length, @ptrCast(&length));
        if (length <= 0) return;
        const data = self.allocator.allocSentinel(u8, @intCast(length), 0) catch return;
        defer self.allocator.free(data);
        if (program) driver.getProgramInfoLog.?(id, length, @ptrCast(&length), data.ptr) else driver.getShaderInfoLog.?(id, length, @ptrCast(&length), data.ptr);
        self.message(1, item, data.ptr);
    }
    fn compileShader(self: *Backend, stage: e.ShaderStage, source: [*:0]const u8) u32 {
        const driver = self.cache.driver;
        const shader = driver.createShader.?(convert.shaderStage(stage));
        if (shader == 0) return 0;
        const sources = [_][*:0]const u8{source};
        driver.shaderSource.?(shader, 1, &sources, null);
        driver.compileShader.?(shader);
        var status: i32 = 0;
        driver.getShaderiv.?(shader, c.compile_status, @ptrCast(&status));
        if (status != 0) return shader;
        self.shaderLog(shader, false, .gl_shader_compilation_failed);
        driver.deleteShader.?(shader);
        return 0;
    }
    pub fn createShader(self: *Backend, shader: *r.Shader, desc: t.ShaderDesc) bool {
        if (self.cache.features.compute) {
            for (desc.views) |view| {
                if (view.storage_buffer.stage != .none and view.storage_buffer.glsl_binding_n >= self.cache.limits.max_storage_buffer_bindings_per_stage) {
                    self.message(1, .gl_storagebuffer_glsl_binding_out_of_range, null);
                    return false;
                }
                if (view.storage_image.stage != .none and view.storage_image.glsl_binding_n >= self.cache.limits.max_storage_image_bindings_per_stage) {
                    self.message(1, .gl_storageimage_glsl_binding_out_of_range, null);
                    return false;
                }
            }
        }
        for (&shader.attribute_names, desc.attrs) |*dst, attribute| {
            @memset(dst, 0);
            if (attribute.glsl_name) |name| {
                const count = @min(31, std.mem.len(name));
                @memcpy(dst[0..count], name[0..count]);
            }
        }
        const driver = self.cache.driver;
        const program = driver.createProgram.?();
        if (program == 0) return false;
        var succeeded = false;
        defer if (!succeeded) driver.deleteProgram.?(program);
        if (desc.compute_func.source) |source| {
            const function = self.compileShader(.compute, source);
            if (function == 0) return false;
            defer driver.deleteShader.?(function);
            driver.attachShader.?(program, function);
            driver.linkProgram.?(program);
        } else if (desc.vertex_func.source != null and desc.fragment_func.source != null) {
            // Compile both stages before deciding failure, matching the source
            // diagnostics and cleanup even when both stages contain errors.
            const vertex = self.compileShader(.vertex, desc.vertex_func.source.?);
            const fragment = self.compileShader(.fragment, desc.fragment_func.source.?);
            defer if (vertex != 0) driver.deleteShader.?(vertex);
            defer if (fragment != 0) driver.deleteShader.?(fragment);
            if (vertex == 0 or fragment == 0) return false;
            driver.attachShader.?(program, vertex);
            driver.attachShader.?(program, fragment);
            driver.linkProgram.?(program);
        } else return false;
        var status: i32 = 0;
        driver.getProgramiv.?(program, c.link_status, @ptrCast(&status));
        if (status == 0) {
            self.shaderLog(program, true, .gl_shader_linking_failed);
            return false;
        }
        for (&shader.uniform_blocks, desc.uniform_blocks) |*block, block_desc| {
            if (block_desc.stage == .none) continue;
            var offset: u32 = 0;
            for (block_desc.glsl_uniforms, 0..) |uniform, i| {
                if (uniform.type == .invalid) break;
                const alignment = formats.uniformAlignment(uniform.type, uniform.array_count, block_desc.layout);
                offset = (offset + alignment - 1) & ~(alignment - 1);
                const name = uniform.glsl_name orelse return false;
                const location = driver.getUniformLocation.?(program, name);
                if (location == -1) self.message(2, .gl_uniformblock_name_not_found_in_shader, name);
                block.uniforms[i] = .{ .location = location, .type = uniform.type, .count = uniform.array_count, .offset = @truncate(offset) };
                offset += formats.uniformSize(uniform.type, uniform.array_count, block_desc.layout);
                block.count += 1;
            }
            if (block_desc.layout == .std140) offset = (offset + 15) & ~@as(u32, 15);
            std.debug.assert(block_desc.size == offset);
        }
        for (desc.views, 0..) |view, i| {
            if (view.storage_buffer.stage != .none) shader.storage_buffer_bindings[i] = view.storage_buffer.glsl_binding_n else if (view.storage_image.stage != .none) shader.storage_image_bindings[i] = view.storage_image.glsl_binding_n;
        }
        const saved_program: u32 = @bitCast(self.integer(c.current_program));
        driver.useProgram.?(program);
        defer driver.useProgram.?(saved_program);
        var texture_unit: i32 = 0;
        for (desc.texture_sampler_pairs, 0..) |pair, i| {
            if (pair.stage == .none) continue;
            const name = pair.glsl_name orelse return false;
            const location = driver.getUniformLocation.?(program, name);
            if (location == -1) {
                shader.texture_slots[i] = -1;
                self.message(2, .gl_image_sampler_name_not_found_in_shader, name);
            } else {
                driver.uniform1i.?(location, texture_unit);
                shader.texture_slots[i] = @intCast(texture_unit);
                texture_unit += 1;
            }
        }
        shader.program = program;
        succeeded = true;
        return true;
    }
    pub fn discardShader(self: *Backend, shader: *r.Shader) void {
        if (shader.program != 0) {
            self.cache.invalidateProgram(shader.program);
            self.cache.driver.deleteProgram.?(shader.program);
        }
        shader.* = .{};
    }
    pub fn createPipeline(self: *Backend, pipeline: *r.Pipeline, shader: *const r.Shader, desc: t.PipelineDesc) bool {
        if (desc.compute) return true;
        for (desc.layout.attrs, 0..) |attr, i| {
            if (i >= @as(usize, @intCast(self.cache.limits.max_vertex_attrs)) or attr.format == .invalid) break;
            const layout = desc.layout.buffers[@intCast(attr.buffer_index)];
            var location: i32 = @intCast(i);
            if (shader.attribute_names[i][0] != 0) location = self.cache.driver.getAttribLocation.?(shader.program, &shader.attribute_names[i]);
            if (location == -1) {
                self.message(2, .gl_vertex_attribute_not_found_in_shader, &shader.attribute_names[i]);
                continue;
            }
            if (location < 0 or location >= self.cache.limits.max_vertex_attrs) return false;
            const dst = &pipeline.attrs[@intCast(location)];
            if (dst.buffer_index != -1) return false;
            dst.* = .{
                .buffer_index = @intCast(attr.buffer_index),
                .divisor = if (layout.step_func == .per_vertex) 0 else @bitCast(@as(u8, @truncate(@as(u32, @bitCast(layout.step_rate))))),
                .stride = @truncate(@as(u32, @bitCast(layout.stride))),
                .size = @intCast(convert.vertexComponents(attr.format)),
                .offset = attr.offset,
                .type = convert.vertexType(attr.format),
                .normalized = convert.vertexNormalized(attr.format),
                .base_type = formats.vertexBaseType(attr.format),
            };
            pipeline.active_vertex_buffers[@intCast(attr.buffer_index)] = true;
        }
        return true;
    }

    pub fn createImage(self: *Backend, image: *r.Image, desc: t.ImageDesc) bool {
        const index = @backingInt(desc.pixel_format);
        if (index <= 1 or index >= 69 or !self.format_info[index].sample) {
            self.message(1, .gl_texture_format_not_supported, null);
            return false;
        }
        image.injected = desc.gl_texture != 0;
        if (image.injected) {
            image.target = if (desc.gl_texture_target != 0) desc.gl_texture_target else convert.textureTarget(desc.type, desc.sample_count, self.gles);
            image.ids[0] = desc.gl_texture;
            return true;
        }
        if (desc.sample_count > 1 and !self.cache.features.msaa_texture_bindings) return desc.usage.color_attachment or desc.usage.depth_stencil_attachment;
        image.target = convert.textureTarget(desc.type, desc.sample_count, self.gles);
        const slots: usize = if (desc.usage.write_transient) 2 else 1;
        const driver = self.cache.driver;
        const internal_format = convert.pixelInternalFormat(desc.pixel_format);
        for (image.ids[0..slots]) |*id| {
            driver.genTextures.?(1, @ptrCast(id));
            if (id.* == 0) return false;
            const saved = self.cache.textures[0];
            self.cache.bindTexture(0, image.target, id.*, 0);
            if (self.immutable_storage) {
                if (desc.type == .@"2d" or desc.type == .cube) {
                    if (desc.sample_count > 1) driver.texStorage2DMultisample.?(image.target, desc.sample_count, internal_format, desc.width, desc.height, 1) else driver.texStorage2D.?(image.target, desc.num_mipmaps, internal_format, desc.width, desc.height);
                } else {
                    if (desc.sample_count > 1) driver.texStorage3DMultisample.?(image.target, desc.sample_count, internal_format, desc.width, desc.height, desc.num_slices, 1) else driver.texStorage3D.?(image.target, desc.num_mipmaps, internal_format, desc.width, desc.height, desc.num_slices);
                }
            }
            // Mutable storage needs an explicit mip range for sampler completeness.
            // Multisample targets do not accept texture mip-range parameters.
            if (!self.immutable_storage and desc.sample_count == 1) driver.texParameteri.?(image.target, c.texture_max_level, desc.num_mipmaps - 1);
            for (0..@intCast(desc.num_mipmaps)) |level| {
                const mip: i32 = @intCast(level);
                const data = desc.data.mip_levels[level];
                const width = formats.mipDimension(desc.width, mip);
                const height = formats.mipDimension(desc.height, mip);
                const depth = if (desc.type == .@"3d") formats.mipDimension(desc.num_slices, mip) else desc.num_slices;
                if (desc.type == .cube) {
                    const pitch = formats.surfacePitch(desc.pixel_format, width, height, 1);
                    for (0..6) |face| {
                        const pointer = if (data.ptr != null) offsetPointer(data.ptr, face * @as(usize, @intCast(pitch))) else null;
                        self.initialImageData(image, desc, convert.cubeFace(@intCast(face)), mip, width, height, depth, pointer, pitch);
                    }
                } else self.initialImageData(image, desc, image.target, mip, width, height, depth, data.ptr, @intCast(data.size));
            }
            self.cache.restoreTexture(0, saved);
        }
        return true;
    }
    fn initialImageData(self: *Backend, image: *const r.Image, desc: t.ImageDesc, target: u32, mip: i32, width: i32, height: i32, depth: i32, data: ?*const anyopaque, size: i32) void {
        _ = image;
        if (self.immutable_storage and data == null) return;
        const driver = self.cache.driver;
        const compressed = formats.isCompressed(desc.pixel_format);
        const internal_format = convert.pixelInternalFormat(desc.pixel_format);
        const planar = desc.type == .@"2d" or desc.type == .cube;
        if (compressed) {
            if (self.immutable_storage) {
                if (planar) driver.compressedTexSubImage2D.?(target, mip, 0, 0, width, height, internal_format, size, data) else driver.compressedTexSubImage3D.?(target, mip, 0, 0, 0, width, height, depth, internal_format, size, data);
            } else {
                const bytes = formats.surfacePitch(desc.pixel_format, width, height, 1) * (if (planar) @as(i32, 1) else depth);
                if (planar) driver.compressedTexImage2D.?(target, mip, internal_format, width, height, 0, bytes, data) else driver.compressedTexImage3D.?(target, mip, internal_format, width, height, depth, 0, bytes, data);
            }
        } else {
            const pixel_format = convert.pixelFormat(desc.pixel_format);
            const pixel_type = convert.pixelType(desc.pixel_format);
            if (self.immutable_storage) {
                if (planar) driver.texSubImage2D.?(target, mip, 0, 0, width, height, pixel_format, pixel_type, data) else driver.texSubImage3D.?(target, mip, 0, 0, 0, width, height, depth, pixel_format, pixel_type, data);
            } else if (desc.sample_count > 1) {
                if (planar) driver.texImage2DMultisample.?(target, desc.sample_count, internal_format, width, height, 1) else driver.texImage3DMultisample.?(target, desc.sample_count, internal_format, width, height, depth, 1);
            } else {
                if (planar) driver.texImage2D.?(target, mip, @intCast(internal_format), width, height, 0, pixel_format, pixel_type, data) else driver.texImage3D.?(target, mip, @intCast(internal_format), width, height, depth, 0, pixel_format, pixel_type, data);
            }
        }
    }
    pub fn discardImage(self: *Backend, image: *r.Image) void {
        for (&image.ids) |*id| {
            if (id.* == 0) continue;
            self.cache.invalidateTexture(id.*, 0);
            if (!image.injected) self.cache.driver.deleteTextures.?(1, @ptrCast(id));
        }
        image.* = .{};
    }
    pub fn writeImage(self: *Backend, image: *r.Image, desc: t.ImageDesc, active_slot: i32, write: t.WriteImageDesc) void {
        const saved = self.cache.textures[0];
        self.cache.bindTexture(0, image.target, image.ids[@intCast(active_slot)], 0);
        self.writeImageData(image, desc, write.src.data.ptr, write.src.offset, write.src.bytes_per_row, write.src.bytes_per_slice, write.dst, write.size);
        self.cache.restoreTexture(0, saved);
    }
    pub fn offsetPointer(pointer: ?*const anyopaque, offset: usize) ?*const anyopaque {
        const address = (if (pointer) |value| @intFromPtr(value) else @as(usize, 0)) + offset;
        return if (address == 0) null else @ptrFromInt(address);
    }
    fn writeImageData(self: *Backend, image: *const r.Image, desc: t.ImageDesc, pointer: ?*const anyopaque, offset: usize, bytes_per_row: i32, bytes_per_slice: i32, dst: t.ImageLocation, size: t.ImageExtent) void {
        const driver = self.cache.driver;
        const compressed = formats.isCompressed(desc.pixel_format);
        driver.pixelStorei.?(c.unpack_row_length, @divTrunc(bytes_per_row, formats.blockSize(desc.pixel_format)));
        driver.pixelStorei.?(c.unpack_image_height, @divTrunc(bytes_per_slice, bytes_per_row));
        defer {
            driver.pixelStorei.?(c.unpack_row_length, 0);
            driver.pixelStorei.?(c.unpack_image_height, 0);
        }
        const source = offsetPointer(pointer, offset);
        const compressed_size = formats.surfacePitch(desc.pixel_format, size.width, size.height, 1);
        if (desc.type == .@"2d" or desc.type == .cube) {
            const count: usize = if (desc.type == .cube) @intCast(size.num_slices) else 1;
            for (0..count) |i| {
                const target = if (desc.type == .cube) convert.cubeFace(dst.slice + @as(i32, @intCast(i))) else image.target;
                const data = offsetPointer(source, i * @as(usize, @intCast(bytes_per_slice)));
                if (compressed) driver.compressedTexSubImage2D.?(target, dst.mip_level, dst.x, dst.y, size.width, size.height, convert.pixelInternalFormat(desc.pixel_format), compressed_size, data) else driver.texSubImage2D.?(target, dst.mip_level, dst.x, dst.y, size.width, size.height, convert.pixelFormat(desc.pixel_format), convert.pixelType(desc.pixel_format), data);
            }
        } else {
            if (compressed) driver.compressedTexSubImage3D.?(image.target, dst.mip_level, dst.x, dst.y, dst.slice, size.width, size.height, size.num_slices, convert.pixelInternalFormat(desc.pixel_format), compressed_size * size.num_slices, source) else driver.texSubImage3D.?(image.target, dst.mip_level, dst.x, dst.y, dst.slice, size.width, size.height, size.num_slices, convert.pixelFormat(desc.pixel_format), convert.pixelType(desc.pixel_format), source);
        }
    }
    pub fn copyBuffer(self: *Backend, src: *r.Buffer, dst: *r.Buffer, src_usage: t.BufferUsage, dst_usage: t.BufferUsage, src_slot: i32, dst_slot: i32, desc: t.CopyBufferToBufferDesc) void {
        if (src.staging) |data| {
            const target = convert.bufferTarget(dst_usage);
            const saved = self.cache.buffers[Cache.bufferIndex(target)];
            self.cache.bindBuffer(target, dst.ids[@intCast(dst_slot)]);
            self.cache.driver.bufferSubData.?(target, @intCast(desc.dst.offset), @intCast(desc.size), data[desc.src.offset..].ptr);
            self.cache.restoreBuffer(target, saved);
            return;
        }
        const driver = self.cache.driver;
        if (self.cache.features.compute and (src_usage.storage_buffer or dst_usage.storage_buffer)) driver.memoryBarrier.?(c.buffer_update_barrier_bit);
        driver.bindBuffer.?(c.copy_read_buffer, src.ids[@intCast(src_slot)]);
        driver.bindBuffer.?(c.copy_write_buffer, dst.ids[@intCast(dst_slot)]);
        driver.copyBufferSubData.?(c.copy_read_buffer, c.copy_write_buffer, @intCast(desc.src.offset), @intCast(desc.dst.offset), @intCast(desc.size));
        driver.bindBuffer.?(c.copy_read_buffer, 0);
        driver.bindBuffer.?(c.copy_write_buffer, 0);
    }
    pub fn copyBufferToImage(self: *Backend, src: *r.Buffer, dst: *r.Image, src_usage: t.BufferUsage, dst_desc: t.ImageDesc, src_slot: i32, dst_slot: i32, desc: t.CopyBufferToImageDesc) void {
        const driver = self.cache.driver;
        const pointer: ?*const anyopaque = if (src.staging) |data| data.ptr else null;
        if (apple_unpack_workaround and pointer == null and desc.src.offset != 0 and !self.apple_unpack_warned) {
            self.message(2, .gl_apple_pixel_unpack_offset_bug, null);
            self.apple_unpack_warned = true;
        }
        if (self.cache.features.compute and (src_usage.storage_buffer or dst_desc.usage.storage_image)) driver.memoryBarrier.?(c.buffer_update_barrier_bit | c.texture_update_barrier_bit | c.pixel_buffer_barrier_bit);
        if (pointer == null) driver.bindBuffer.?(c.pixel_unpack_buffer, src.ids[@intCast(src_slot)]);
        const saved = self.cache.textures[0];
        self.cache.bindTexture(0, dst.target, dst.ids[@intCast(dst_slot)], 0);
        self.writeImageData(dst, dst_desc, pointer, desc.src.offset, desc.src.bytes_per_row, desc.src.bytes_per_slice, desc.dst, desc.size);
        self.cache.restoreTexture(0, saved);
        driver.bindBuffer.?(c.pixel_unpack_buffer, 0);
    }
    /// Framebuffer/readback mip levels are absolute, independent of the last
    /// emulated sampler view. Restore the backing texture's complete mip range.
    pub fn resetTextureMipRange(self: *Backend, image: *const r.Image, desc: t.ImageDesc, active_slot: i32) void {
        if (self.cache.features.gl_texture_views or desc.sample_count != 1 or desc.num_mipmaps <= 1) return;
        const saved = self.cache.textures[0];
        self.cache.bindTexture(0, image.target, image.ids[@intCast(active_slot)], 0);
        self.cache.activeTexture(c.texture0);
        self.cache.driver.texParameteri.?(image.target, c.texture_base_level, 0);
        self.cache.driver.texParameteri.?(image.target, c.texture_max_level, desc.num_mipmaps - 1);
        self.cache.bindTexture(0, saved.target, saved.texture, saved.sampler);
    }

    pub fn attachImage(self: *Backend, image: *const r.Image, desc: t.ImageDesc, mip_level: i32, slice: i32, attachment: u32) void {
        self.resetTextureMipRange(image, desc, 0);
        const driver = self.cache.driver;
        switch (desc.type) {
            .@"2d" => driver.framebufferTexture2D.?(c.framebuffer, attachment, image.target, image.ids[0], mip_level),
            .cube => driver.framebufferTexture2D.?(c.framebuffer, attachment, convert.cubeFace(slice), image.ids[0], mip_level),
            else => driver.framebufferTextureLayer.?(c.framebuffer, attachment, image.ids[0], mip_level, slice),
        }
    }
    pub fn framebufferComplete(self: *Backend) bool {
        const status = self.cache.driver.checkFramebufferStatus.?(c.framebuffer);
        if (status == c.framebuffer_complete) return true;
        self.message(1, switch (status) {
            c.framebuffer_undefined => .gl_framebuffer_status_undefined,
            c.framebuffer_incomplete_attachment => .gl_framebuffer_status_incomplete_attachment,
            c.framebuffer_incomplete_missing_attachment => .gl_framebuffer_status_incomplete_missing_attachment,
            c.framebuffer_unsupported => .gl_framebuffer_status_unsupported,
            c.framebuffer_incomplete_multisample => .gl_framebuffer_status_incomplete_multisample,
            else => .gl_framebuffer_status_unknown,
        }, null);
        return false;
    }
    pub fn createView(self: *Backend, view: *r.View, descriptor: t.ViewDesc, image: ?*const r.Image, image_desc: t.ImageDesc) bool {
        const driver = self.cache.driver;
        if (descriptor.texture.image.id != 0 and !self.cache.features.gl_texture_views) {
            const full_slices = switch (image_desc.type) {
                .array => image_desc.num_slices,
                .cube => 6,
                else => 1,
            };
            if (descriptor.texture.slices.base != 0 or descriptor.texture.slices.count != full_slices) {
                self.message(1, .gl_texture_view_slice_range_unsupported, null);
                return false;
            }
        }
        if (descriptor.texture.image.id != 0 and self.cache.features.gl_texture_views) {
            const source = image.?;
            const desc = descriptor.texture;
            const slots: usize = if (image_desc.usage.write_transient) 2 else 1;
            for (view.texture_views[0..slots], 0..) |*id, i| {
                driver.genTextures.?(1, @ptrCast(id));
                if (id.* == 0) return false;
                driver.textureView.?(id.*, source.target, source.ids[i], convert.pixelInternalFormat(image_desc.pixel_format), @intCast(desc.mip_levels.base), @intCast(desc.mip_levels.count), @intCast(desc.slices.base), @intCast(desc.slices.count));
            }
        } else if (descriptor.color_attachment.image.id != 0 or descriptor.depth_stencil_attachment.image.id != 0) {
            if (image_desc.sample_count > 1 and !self.cache.features.msaa_texture_bindings) {
                driver.genRenderbuffers.?(1, @ptrCast(&view.msaa_renderbuffer));
                if (view.msaa_renderbuffer == 0) return false;
                driver.bindRenderbuffer.?(c.renderbuffer, view.msaa_renderbuffer);
                driver.renderbufferStorageMultisample.?(c.renderbuffer, image_desc.sample_count, convert.pixelInternalFormat(image_desc.pixel_format), image_desc.width, image_desc.height);
            }
        } else if (descriptor.resolve_attachment.image.id != 0) {
            const saved: u32 = @bitCast(self.integer(c.framebuffer_binding));
            driver.genFramebuffers.?(1, @ptrCast(&view.resolve_framebuffer));
            if (view.resolve_framebuffer == 0) return false;
            driver.bindFramebuffer.?(c.framebuffer, view.resolve_framebuffer);
            defer driver.bindFramebuffer.?(c.framebuffer, saved);
            self.attachImage(image.?, image_desc, descriptor.resolve_attachment.mip_level, descriptor.resolve_attachment.slice, c.color_attachment0);
            if (!self.framebufferComplete()) return false;
            const buffer = [_]u32{c.color_attachment0};
            driver.drawBuffers.?(1, &buffer);
        }
        return true;
    }
    /// Readback (zicr extension). GL reads synchronize with all submitted commands.
    pub fn readBuffer(self: *Backend, buffer: *r.Buffer, usage: t.BufferUsage, active_slot: i32, offset: usize, out: []u8) bool {
        _ = usage;
        if (buffer.staging) |data| {
            @memcpy(out, data[offset..][0..out.len]);
            return true;
        }
        const driver = self.cache.driver;
        if (self.cache.features.compute) driver.memoryBarrier.?(c.all_barrier_bits);
        driver.bindBuffer.?(c.copy_read_buffer, buffer.ids[@intCast(active_slot)]);
        defer driver.bindBuffer.?(c.copy_read_buffer, 0);
        // GLES has no glGetBufferSubData, even if the loader resolves the symbol
        if (!self.gles or is_web) if (driver.getBufferSubData) |getBufferSubData| {
            getBufferSubData(c.copy_read_buffer, @intCast(offset), @intCast(out.len), out.ptr);
            return true;
        };
        const map = driver.mapBufferRange orelse return false;
        const mapped: [*]const u8 = @ptrCast(map(c.copy_read_buffer, @intCast(offset), @intCast(out.len), c.map_read_bit) orelse return false);
        @memcpy(out, mapped[0..out.len]);
        return driver.unmapBuffer.?(c.copy_read_buffer) != 0;
    }

    /// Readback (zicr extension): reads an image region in storage row order
    /// through the backend's framebuffer object, one slice at a time.
    pub fn readImage(self: *Backend, image: *r.Image, desc: t.ImageDesc, active_slot: i32, region: *const core.ReadRegion, out: []u8) bool {
        // WebGL cannot promise exact packed-format readback through canonical
        // RGBA8/FLOAT conversion. Report unsupported instead of losing bits.
        if (is_web and (desc.pixel_format == .rgb10a2 or desc.pixel_format == .rg11b10f)) return false;
        self.resetTextureMipRange(image, desc, active_slot);
        const driver = self.cache.driver;
        const read_pixels = driver.readPixels orelse return false;
        if (self.cache.features.compute) driver.memoryBarrier.?(c.all_barrier_bits);
        const saved: u32 = @bitCast(self.integer(c.framebuffer_binding));
        defer driver.bindFramebuffer.?(c.framebuffer, saved);
        // Keep readback attachments separate from an MRT pass: WebGL forbids
        // attaching the same image to two colour slots of one framebuffer.
        if (self.readback_framebuffer == 0) driver.genFramebuffers.?(1, @ptrCast(&self.readback_framebuffer));
        if (self.readback_framebuffer == 0) return false;
        driver.bindFramebuffer.?(c.framebuffer, self.readback_framebuffer);
        const texture = image.ids[@intCast(active_slot)];
        const mip: i32 = @intCast(region.mip_level);
        const bytes_per_pixel: usize = @intCast(formats.pixelSize(desc.pixel_format));
        driver.pixelStorei.?(c.pack_alignment, 1);
        driver.pixelStorei.?(c.pack_row_length, @intCast(region.bytes_per_row / bytes_per_pixel));
        defer {
            driver.pixelStorei.?(c.pack_row_length, 0);
            driver.pixelStorei.?(c.pack_alignment, 4);
        }
        driver.readBuffer.?(c.color_attachment0);
        var ok = true;
        for (0..region.num_slices) |i| {
            const slice: i32 = @intCast(region.slice + i);
            switch (desc.type) {
                .@"2d" => driver.framebufferTexture2D.?(c.framebuffer, c.color_attachment0, image.target, texture, mip),
                .cube => driver.framebufferTexture2D.?(c.framebuffer, c.color_attachment0, convert.cubeFace(slice), texture, mip),
                else => driver.framebufferTextureLayer.?(c.framebuffer, c.color_attachment0, texture, mip, slice),
            }
            if (driver.checkFramebufferStatus.?(c.framebuffer) != c.framebuffer_complete) {
                ok = false;
                break;
            }
            const dst = out[i * region.bytes_per_slice ..];
            read_pixels(@intCast(region.x), @intCast(region.y), @intCast(region.width), @intCast(region.height), convert.pixelFormat(desc.pixel_format), convert.pixelType(desc.pixel_format), dst.ptr);
        }
        driver.framebufferTexture2D.?(c.framebuffer, c.color_attachment0, c.texture_2d, 0, 0);
        return ok;
    }

    pub fn discardView(self: *Backend, view: *r.View) void {
        for (&view.texture_views) |*id| {
            if (id.* == 0) continue;
            self.cache.invalidateTexture(id.*, 0);
            self.cache.driver.deleteTextures.?(1, @ptrCast(id));
        }
        if (view.msaa_renderbuffer != 0) self.cache.driver.deleteRenderbuffers.?(1, @ptrCast(&view.msaa_renderbuffer));
        if (view.resolve_framebuffer != 0) self.cache.driver.deleteFramebuffers.?(1, @ptrCast(&view.resolve_framebuffer));
        view.* = .{};
    }
};
