//! GL binding cache and invalidation, ported from sokol_gfx.h:11217-11569.
const std = @import("std");
const t = @import("../../types.zig");
const e = @import("../../enums.zig");
const resources = @import("resources.zig");
const Dispatch = @import("dispatch.zig").Dispatch;
const c = @import("constants.zig");

pub const TextureBinding = struct {
    target: u32 = 0,
    texture: u32 = 0,
    sampler: u32 = 0,
};
pub const CachedAttribute = struct {
    attribute: resources.Attribute = .{},
    buffer: u32 = 0,
};

pub const Cache = struct {
    driver: Dispatch,
    features: t.Features = .{},
    limits: t.Limits = .{},
    stats: t.FrameStatsGl = .{},
    stats_enabled: bool = true,
    buffers: [3]u32 = @splat(0),
    storage_buffers: [32]u32 = @splat(0),
    storage_buffer_offsets: [32]i32 = @splat(0),
    textures: [32]TextureBinding = @splat(.{}),
    active_texture: u32 = 0,
    attrs: [16]CachedAttribute = @splat(.{}),
    program: u32 = 0,
    current_pipeline: t.SlotInfo = .{},
    depth: t.DepthState = .{},
    stencil: t.StencilState = .{},
    blend: t.BlendState = .{},
    color_masks: [8]e.ColorMask = @splat(.default),
    cull_mode: e.CullMode = .default,
    winding: e.FaceWinding = .default,
    blend_color: t.Color = .{},
    polygon_offset: bool = false,
    samples: i32 = 0,
    alpha_to_coverage: bool = false,
    primitive_type: u32 = 0,
    index_type: u32 = 0,
    index_offset: i32 = 0,

    pub fn count(self: *Cache, comptime field: []const u8, n: u32) void {
        if (self.stats_enabled) @field(self.stats, field) +%= n;
    }
    pub fn bufferIndex(target: u32) usize {
        return switch (target) {
            c.array_buffer => 0,
            c.element_array_buffer => 1,
            c.shader_storage_buffer => 2,
            else => unreachable,
        };
    }
    pub fn bindBuffer(self: *Cache, target: u32, id: u32) void {
        const index = bufferIndex(target);
        if (self.buffers[index] == id) return;
        self.buffers[index] = id;
        if (index != 2 or self.features.compute) self.driver.bindBuffer.?(target, id);
        self.count("num_bind_buffer", 1);
    }
    pub fn restoreBuffer(self: *Cache, target: u32, saved: u32) void {
        // Sokol deliberately restores only nonzero saved bindings.
        if (saved != 0) self.bindBuffer(target, saved);
    }
    pub fn bindStorageBuffer(self: *Cache, binding: u8, buffer: u32, offset: i32, size: i32) void {
        std.debug.assert(binding < 32 and offset < size);
        if (self.storage_buffers[binding] == buffer and self.storage_buffer_offsets[binding] == offset) return;
        self.storage_buffers[binding] = buffer;
        self.storage_buffer_offsets[binding] = offset;
        self.buffers[2] = buffer;
        if (self.features.compute) {
            std.debug.assert(binding < self.limits.max_storage_buffer_bindings_per_stage);
            self.driver.bindBufferRange.?(c.shader_storage_buffer, binding, buffer, offset, size - offset);
        }
        self.count("num_bind_buffer", 1);
    }
    pub fn clearBuffers(self: *Cache, force: bool) void {
        const targets = [_]u32{ c.array_buffer, c.element_array_buffer, c.shader_storage_buffer };
        for (&self.buffers, targets, 0..) |*buffer, target, index| {
            if (force or buffer.* != 0) {
                if (index != 2 or self.features.compute) self.driver.bindBuffer.?(target, 0);
                buffer.* = 0;
                self.count("num_bind_buffer", 1);
            }
        }
        for (&self.storage_buffers, 0..) |*buffer, i| {
            if (force or buffer.* != 0) {
                if (self.features.compute and i < @as(usize, @intCast(self.limits.max_storage_buffer_bindings_per_stage))) self.driver.bindBufferBase.?(c.shader_storage_buffer, @intCast(i), 0);
                buffer.* = 0;
                self.count("num_bind_buffer", 1);
            }
        }
    }
    pub fn invalidateBuffer(self: *Cache, id: u32) void {
        const targets = [_]u32{ c.array_buffer, c.element_array_buffer, c.shader_storage_buffer };
        for (&self.buffers, targets) |*buffer, target| {
            if (buffer.* == id) {
                buffer.* = 0;
                self.driver.bindBuffer.?(target, 0);
                self.count("num_bind_buffer", 1);
            }
        }
        for (&self.storage_buffers, 0..) |*buffer, i| {
            if (buffer.* == id) {
                buffer.* = 0;
                self.buffers[2] = 0;
                if (self.features.compute and i < @as(usize, @intCast(self.limits.max_storage_buffer_bindings_per_stage))) self.driver.bindBufferBase.?(c.shader_storage_buffer, @intCast(i), 0);
                self.count("num_bind_buffer", 1);
            }
        }
        for (&self.attrs) |*attr| {
            if (attr.buffer == id) attr.buffer = 0;
        }
    }
    pub fn activeTexture(self: *Cache, unit: u32) void {
        if (self.active_texture == unit) return;
        self.active_texture = unit;
        self.driver.activeTexture.?(unit);
        self.count("num_active_texture", 1);
    }
    pub fn bindTexture(self: *Cache, unit: usize, target: u32, texture: u32, sampler: u32) void {
        std.debug.assert(unit < 32);
        if (unit >= @as(usize, @intCast(self.limits.gl_max_combined_texture_image_units))) return;
        const slot = &self.textures[unit];
        if (slot.target == target and slot.texture == texture and slot.sampler == sampler) return;
        self.activeTexture(c.texture0 + @as(u32, @intCast(unit)));
        if (target != slot.target and slot.target != 0) {
            self.driver.bindTexture.?(slot.target, 0);
            self.count("num_bind_texture", 1);
        }
        if (target != 0) {
            self.driver.bindTexture.?(target, texture);
            self.count("num_bind_texture", 1);
        }
        self.driver.bindSampler.?(@intCast(unit), sampler);
        self.count("num_bind_sampler", 1);
        slot.* = .{ .target = target, .texture = texture, .sampler = sampler };
    }
    pub fn restoreTexture(self: *Cache, unit: usize, saved: TextureBinding) void {
        if (saved.texture != 0) self.bindTexture(unit, saved.target, saved.texture, saved.sampler);
    }
    pub fn clearTextures(self: *Cache, force: bool) void {
        const count_units = @min(32, @as(usize, @intCast(self.limits.gl_max_combined_texture_image_units)));
        for (self.textures[0..count_units], 0..) |*slot, i| {
            if (force or slot.texture != 0) {
                const unit = c.texture0 + @as(u32, @intCast(i));
                self.driver.activeTexture.?(unit);
                self.count("num_active_texture", 1);
                inline for (.{ c.texture_2d, c.texture_cube_map, c.texture_3d, c.texture_2d_array }) |target| self.driver.bindTexture.?(target, 0);
                self.count("num_bind_texture", 4);
                self.driver.bindSampler.?(@intCast(i), 0);
                self.count("num_bind_sampler", 1);
                slot.* = .{};
                self.active_texture = unit;
            }
        }
    }
    pub fn invalidateTexture(self: *Cache, texture: u32, sampler: u32) void {
        for (&self.textures, 0..) |*slot, i| {
            if (slot.target != 0 and (texture == slot.texture or sampler == slot.sampler)) {
                self.activeTexture(c.texture0 + @as(u32, @intCast(i)));
                self.driver.bindTexture.?(slot.target, 0);
                self.count("num_bind_texture", 1);
                self.driver.bindSampler.?(@intCast(i), 0);
                self.count("num_bind_sampler", 1);
                slot.* = .{};
            }
        }
    }
    pub fn invalidateProgram(self: *Cache, program: u32) void {
        if (self.program == program) {
            self.program = 0;
            self.driver.useProgram.?(0);
            self.count("num_use_program", 1);
        }
    }
    pub fn invalidatePipeline(self: *Cache, slot: t.SlotInfo) void {
        if (self.current_pipeline.res_id == slot.res_id and self.current_pipeline.uninit_count == slot.uninit_count) self.current_pipeline = .{};
    }
    pub fn reset(self: *Cache, vao: u32, gles: bool) void {
        const driver = self.driver;
        self.buffers = @splat(0);
        self.storage_buffers = @splat(0);
        self.storage_buffer_offsets = @splat(0);
        self.textures = @splat(.{});
        self.active_texture = 0;
        self.attrs = @splat(.{});
        self.current_pipeline = .{};
        self.depth = .{ .compare = .always };
        const face: t.StencilFaceState = .{ .compare = .always, .fail_op = .keep, .depth_fail_op = .keep, .pass_op = .keep };
        self.stencil = .{ .front = face, .back = face };
        self.blend = .{ .src_factor_rgb = .one, .dst_factor_rgb = .zero, .op_rgb = .add, .src_factor_alpha = .one, .dst_factor_alpha = .zero, .op_alpha = .add };
        self.color_masks = @splat(.rgba);
        self.cull_mode = .none;
        self.winding = .cw;
        self.blend_color = .{};
        self.polygon_offset = false;
        self.samples = 1;
        self.alpha_to_coverage = false;
        self.index_type = 0;
        self.index_offset = 0;
        self.primitive_type = c.triangles;
        driver.bindVertexArray.?(vao);
        self.clearBuffers(true);
        self.clearTextures(true);
        for (0..@intCast(self.limits.max_vertex_attrs)) |i| {
            driver.disableVertexAttribArray.?(@intCast(i));
            self.count("num_disable_vertex_attrib_array", 1);
        }
        var program: i32 = 0;
        driver.getIntegerv.?(c.current_program, @ptrCast(&program));
        self.program = @bitCast(program);
        driver.enable.?(c.depth_test);
        driver.depthFunc.?(c.always);
        driver.depthMask.?(0);
        driver.disable.?(c.stencil_test);
        driver.stencilFunc.?(c.always, 0, 0);
        driver.stencilOp.?(c.keep, c.keep, c.keep);
        driver.stencilMask.?(0);
        self.count("num_render_state", 7);
        driver.disable.?(c.blend);
        driver.blendFuncSeparate.?(c.one, c.zero, c.one, c.zero);
        driver.blendEquationSeparate.?(c.func_add, c.func_add);
        driver.blendColor.?(0, 0, 0, 0);
        self.count("num_render_state", 4);
        driver.colorMask.?(1, 1, 1, 1);
        driver.polygonOffset.?(0, 0);
        driver.disable.?(c.polygon_offset_fill);
        driver.disable.?(c.cull_face);
        driver.frontFace.?(c.cw);
        driver.cullFace.?(c.back);
        driver.enable.?(c.scissor_test);
        driver.disable.?(c.sample_alpha_to_coverage);
        driver.enable.?(c.dither);
        driver.disable.?(c.polygon_offset_fill);
        self.count("num_render_state", 10);
        if (!gles) {
            driver.enable.?(c.multisample);
            driver.enable.?(c.program_point_size);
            self.count("num_render_state", 2);
        }
    }
};
