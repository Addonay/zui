//! Native rendering/compute commands from sokol_gfx.h:12465-13288.
const std = @import("std");
const t = @import("../../types.zig");
const core = @import("../../core.zig");
const e = @import("../../enums.zig");
const formats = @import("../../formats.zig");
const c = @import("constants.zig");
const convert = @import("convert.zig");
const r = @import("resources.zig");

fn equal(a: f32, b: f32, tolerance: f32) bool {
    return (a - b) > -tolerance and (a - b) < tolerance;
}
fn imageView(desc: t.ViewDesc) t.ImageViewDesc {
    if (desc.storage_image.image.id != 0) return desc.storage_image;
    if (desc.color_attachment.image.id != 0) return desc.color_attachment;
    if (desc.resolve_attachment.image.id != 0) return desc.resolve_attachment;
    return desc.depth_stencil_attachment;
}
fn takeDirty(flags: *u8, bit: u8, barrier: u32, barriers: *u32) void {
    if (flags.* & bit == 0) return;
    barriers.* |= barrier;
    flags.* &= ~bit;
}

pub fn Commands(comptime Backend: type) type {
    return struct {
        pub fn barriers(self: *Backend, bindings: ?*const r.Bindings, attachments: ?*const r.Attachments) void {
            if (!self.cache.features.compute) return;
            var bits: u32 = 0;
            if (bindings) |bnd| {
                for (&bnd.vertex_buffers) |binding| {
                    if (binding) |buffer| takeDirty(&buffer.resource.gpu_dirty, r.Dirty.vertex, c.vertex_attrib_array_barrier_bit, &bits);
                }
                if (bnd.index_buffer) |buffer| takeDirty(&buffer.resource.gpu_dirty, r.Dirty.index, c.element_array_barrier_bit, &bits);
                for (&bnd.views) |optional| {
                    const view = optional orelse continue;
                    if (view.buffer) |buffer| {
                        takeDirty(&buffer.resource.gpu_dirty, r.Dirty.storage_buffer, c.shader_storage_barrier_bit, &bits);
                    } else if (view.image) |image| {
                        if (view.desc.texture.image.id != 0) takeDirty(&image.resource.gpu_dirty, r.Dirty.texture, c.texture_fetch_barrier_bit, &bits) else if (view.desc.storage_image.image.id != 0) takeDirty(&image.resource.gpu_dirty, r.Dirty.storage_image, c.shader_image_access_barrier_bit, &bits);
                    }
                }
            }
            if (attachments) |atts| {
                for (atts.colors[0..atts.num_colors]) |optional| {
                    const view = optional.?;
                    takeDirty(&view.image.?.resource.gpu_dirty, r.Dirty.attachment, c.framebuffer_barrier_bit, &bits);
                }
            }
            if (bits != 0) {
                self.cache.driver.memoryBarrier.?(bits);
                self.cache.count("num_memory_barriers", 1);
            }
            // Mark writers only after every alias has been read and cleared.
            if (bindings) |bnd| {
                for (&bnd.views, &bnd.shader.desc.views) |optional, required| {
                    const view = optional orelse continue;
                    if (view.buffer) |buffer| {
                        if (!required.storage_buffer.readonly) buffer.resource.gpu_dirty = r.Dirty.buffer_all;
                    } else if (view.desc.storage_image.image.id != 0) view.image.?.resource.gpu_dirty = r.Dirty.image_all;
                }
            }
        }

        pub fn beginPass(self: *Backend, pass: t.Pass, atts: *const r.Attachments) bool {
            if (pass.compute) {
                // Readback may leave a detached private framebuffer current.
                // Compute has no attachments; avoid carrying that incomplete
                // framebuffer into driver dispatch validation.
                self.cache.driver.bindFramebuffer.?(c.framebuffer, 0);
                return true;
            }
            const driver = self.cache.driver;
            const offscreen = !atts.empty();
            if (offscreen) {
                if (!self.gles) driver.enable.?(c.framebuffer_srgb);
                driver.bindFramebuffer.?(c.framebuffer, self.framebuffer);
                for (atts.colors[0..atts.num_colors], 0..) |optional, i| {
                    self.attachView(optional.?, c.color_attachment0 + @as(u32, @intCast(i)));
                }
                for (atts.num_colors..@intCast(self.cache.limits.max_color_attachments)) |i| {
                    const attachment = c.color_attachment0 + @as(u32, @intCast(i));
                    driver.framebufferRenderbuffer.?(c.framebuffer, attachment, c.renderbuffer, 0);
                    driver.framebufferTexture2D.?(c.framebuffer, attachment, c.texture_2d, 0, 0);
                }
                if (atts.depth_stencil) |view| {
                    inline for (.{ c.depth_attachment, c.depth_stencil_attachment }) |attachment| {
                        driver.framebufferRenderbuffer.?(c.framebuffer, attachment, c.renderbuffer, 0);
                        driver.framebufferTexture2D.?(c.framebuffer, attachment, c.texture_2d, 0, 0);
                    }
                    self.attachView(view, if (view.image.?.desc.pixel_format == .depth_stencil) c.depth_stencil_attachment else c.depth_attachment);
                } else {
                    driver.framebufferRenderbuffer.?(c.framebuffer, c.depth_stencil_attachment, c.renderbuffer, 0);
                    driver.framebufferTexture2D.?(c.framebuffer, c.depth_stencil_attachment, c.texture_2d, 0, 0);
                }
                if (!self.framebufferComplete()) return false;
                var draw_buffers: [8]u32 = @splat(c.none);
                for (draw_buffers[0..atts.num_colors], 0..) |*value, i| value.* = c.color_attachment0 + @as(u32, @intCast(i));
                driver.drawBuffers.?(self.cache.limits.max_color_attachments, &draw_buffers);
                self.barriers(null, atts);
            } else {
                if (!self.gles) {
                    if (formats.isSrgb(pass.swapchain.color_format)) driver.enable.?(c.framebuffer_srgb) else driver.disable.?(c.framebuffer_srgb);
                }
                driver.bindFramebuffer.?(c.framebuffer, pass.swapchain.gl.framebuffer);
            }
            const width = if (offscreen) atts.width else pass.swapchain.width;
            const height = if (offscreen) atts.height else pass.swapchain.height;
            driver.viewport.?(0, 0, width, height);
            driver.scissor.?(0, 0, width, height);
            const count = if (offscreen) atts.num_colors else 1;
            var clear_color = false;
            for (pass.action.colors[0..count]) |color| clear_color = clear_color or color.load_action == .clear;
            const clear_depth = pass.action.depth.load_action == .clear;
            const clear_stencil = pass.action.stencil.load_action == .clear;
            var flush_pipeline = false;
            if (clear_color) {
                var mask_changed = false;
                for (&self.cache.color_masks) |*mask| {
                    if (mask.* != .rgba) {
                        mask.* = .rgba;
                        mask_changed = true;
                    }
                }
                if (mask_changed) {
                    driver.colorMask.?(1, 1, 1, 1);
                    flush_pipeline = true;
                }
            }
            if (clear_depth) {
                if (!self.cache.depth.write_enabled) {
                    self.cache.depth.write_enabled = true;
                    driver.depthMask.?(1);
                    flush_pipeline = true;
                }
                if (self.cache.depth.compare != .always) {
                    self.cache.depth.compare = .always;
                    driver.depthFunc.?(c.always);
                    flush_pipeline = true;
                }
            }
            if (clear_stencil and self.cache.stencil.write_mask != 255) {
                self.cache.stencil.write_mask = 255;
                driver.stencilMask.?(255);
                flush_pipeline = true;
            }
            if (flush_pipeline) self.cache.current_pipeline = .{};
            for (pass.action.colors[0..count], 0..) |color, i| {
                if (color.load_action == .clear) {
                    const value = [_]f32{ color.clear_value.r, color.clear_value.g, color.clear_value.b, color.clear_value.a };
                    driver.clearBufferfv.?(c.color, @intCast(i), &value);
                }
            }
            if (!offscreen or atts.depth_stencil != null) {
                if (clear_depth and clear_stencil) driver.clearBufferfi.?(c.depth_stencil, 0, pass.action.depth.clear_value, pass.action.stencil.clear_value) else if (clear_depth) {
                    const value = [_]f32{pass.action.depth.clear_value};
                    driver.clearBufferfv.?(c.depth, 0, &value);
                } else if (clear_stencil) {
                    const value = [_]i32{pass.action.stencil.clear_value};
                    driver.clearBufferiv.?(c.stencil, 0, &value);
                }
            }
            return true;
        }

        pub fn attachView(self: *Backend, view: r.ViewBinding, attachment: u32) void {
            if (view.resource.msaa_renderbuffer != 0) {
                self.cache.driver.framebufferRenderbuffer.?(c.framebuffer, attachment, c.renderbuffer, view.resource.msaa_renderbuffer);
            } else {
                const image = view.image.?;
                const desc = imageView(view.desc.*);
                self.attachImage(image.resource, image.desc.*, desc.mip_level, desc.slice, attachment);
            }
        }

        pub fn endPass(self: *Backend, pass: t.Pass, atts: *const r.Attachments) void {
            if (pass.compute or atts.empty()) return;
            const driver = self.cache.driver;
            var read_bound = false;
            var draw_bound = false;
            for (atts.resolves[0..atts.num_colors], 0..) |optional, i| {
                const view = optional orelse continue;
                if (view.resource.resolve_framebuffer == 0) continue;
                if (!read_bound) {
                    driver.bindFramebuffer.?(c.read_framebuffer, self.framebuffer);
                    read_bound = true;
                }
                const desc = view.image.?.desc;
                driver.bindFramebuffer.?(c.draw_framebuffer, view.resource.resolve_framebuffer);
                driver.readBuffer.?(c.color_attachment0 + @as(u32, @intCast(i)));
                driver.blitFramebuffer.?(0, 0, desc.width, desc.height, 0, 0, desc.width, desc.height, c.color_buffer_bit, c.nearest);
                draw_bound = true;
            }
            if (self.gles) {
                if (draw_bound) driver.bindFramebuffer.?(c.framebuffer, self.framebuffer);
                var invalidate: [10]u32 = undefined;
                var count: usize = 0;
                for (pass.action.colors[0..atts.num_colors], 0..) |color, i| {
                    if (color.store_action == .dontcare) {
                        invalidate[count] = c.color_attachment0 + @as(u32, @intCast(i));
                        count += 1;
                    }
                }
                // Preserve the original GLES invalidation rule, including the
                // absence-of-depth-view condition in the bundled source.
                if (atts.depth_stencil == null) {
                    if (pass.action.depth.store_action == .dontcare) {
                        invalidate[count] = c.depth_attachment;
                        count += 1;
                    }
                    if (pass.action.stencil.store_action == .dontcare) {
                        invalidate[count] = c.stencil_attachment;
                        count += 1;
                    }
                }
                if (count != 0) driver.invalidateFramebuffer.?(c.draw_framebuffer, @intCast(count), &invalidate);
            }
        }

        pub fn viewport(self: *Backend, height: i32, x: i32, y: i32, width: i32, h: i32, origin_top_left: bool) void {
            self.cache.driver.viewport.?(x, if (origin_top_left) height - (y + h) else y, width, h);
        }
        pub fn scissor(self: *Backend, height: i32, x: i32, y: i32, width: i32, h: i32, origin_top_left: bool) void {
            self.cache.driver.scissor.?(x, if (origin_top_left) height - (y + h) else y, width, h);
        }

        pub fn applyPipeline(self: *Backend, pipeline: r.PipelineBinding, shader: *const r.Shader) void {
            const cache = &self.cache;
            if (cache.current_pipeline.res_id == pipeline.slot.res_id and cache.current_pipeline.uninit_count == pipeline.slot.uninit_count) return;
            cache.current_pipeline = pipeline.slot;
            if (cache.program != shader.program) {
                cache.program = shader.program;
                cache.driver.useProgram.?(shader.program);
                cache.count("num_use_program", 1);
            }
            if (!pipeline.desc.compute) self.renderState(pipeline.desc.*);
        }

        pub fn toggle(self: *Backend, token: u32, enabled: bool) void {
            if (enabled) self.cache.driver.enable.?(token) else self.cache.driver.disable.?(token);
            self.cache.count("num_render_state", 1);
        }

        pub fn renderState(self: *Backend, desc: t.PipelineDesc) void {
            const cache = &self.cache;
            const driver = cache.driver;
            cache.primitive_type = convert.primitiveType(desc.primitive_type);
            cache.index_type = convert.indexType(desc.index_type);
            if (desc.depth.compare != cache.depth.compare) {
                cache.depth.compare = desc.depth.compare;
                driver.depthFunc.?(convert.compareFunc(desc.depth.compare));
                cache.count("num_render_state", 1);
            }
            if (desc.depth.write_enabled != cache.depth.write_enabled) {
                cache.depth.write_enabled = desc.depth.write_enabled;
                driver.depthMask.?(@intFromBool(desc.depth.write_enabled));
                cache.count("num_render_state", 1);
            }
            if (!equal(desc.depth.bias, cache.depth.bias, 0.000001) or !equal(desc.depth.bias_slope_scale, cache.depth.bias_slope_scale, 0.000001)) {
                cache.depth.bias = desc.depth.bias;
                cache.depth.bias_slope_scale = desc.depth.bias_slope_scale;
                driver.polygonOffset.?(desc.depth.bias_slope_scale, desc.depth.bias);
                cache.count("num_render_state", 1);
                const enabled = !(equal(desc.depth.bias, 0, 0.000001) and equal(desc.depth.bias_slope_scale, 0, 0.000001));
                if (enabled != cache.polygon_offset) {
                    cache.polygon_offset = enabled;
                    self.toggle(c.polygon_offset_fill, enabled);
                }
            }
            if (desc.stencil.enabled != cache.stencil.enabled) {
                cache.stencil.enabled = desc.stencil.enabled;
                self.toggle(c.stencil_test, desc.stencil.enabled);
            }
            if (desc.stencil.write_mask != cache.stencil.write_mask) {
                cache.stencil.write_mask = desc.stencil.write_mask;
                driver.stencilMask.?(desc.stencil.write_mask);
                cache.count("num_render_state", 1);
            }
            inline for (.{ .{ "front", c.front }, .{ "back", c.back } }) |face| {
                const value = @field(desc.stencil, face[0]);
                const old = &@field(cache.stencil, face[0]);
                if (value.compare != old.compare or desc.stencil.read_mask != cache.stencil.read_mask or desc.stencil.ref != cache.stencil.ref) {
                    old.compare = value.compare;
                    driver.stencilFuncSeparate.?(face[1], convert.compareFunc(value.compare), desc.stencil.ref, desc.stencil.read_mask);
                    cache.count("num_render_state", 1);
                }
                if (value.fail_op != old.fail_op or value.depth_fail_op != old.depth_fail_op or value.pass_op != old.pass_op) {
                    old.fail_op = value.fail_op;
                    old.depth_fail_op = value.depth_fail_op;
                    old.pass_op = value.pass_op;
                    driver.stencilOpSeparate.?(face[1], convert.stencilOp(value.fail_op), convert.stencilOp(value.depth_fail_op), convert.stencilOp(value.pass_op));
                    cache.count("num_render_state", 1);
                }
            }
            cache.stencil.read_mask = desc.stencil.read_mask;
            cache.stencil.ref = desc.stencil.ref;
            if (desc.color_count > 0) {
                const blend = desc.colors[0].blend;
                if (blend.enabled != cache.blend.enabled) {
                    cache.blend.enabled = blend.enabled;
                    self.toggle(c.blend, blend.enabled);
                }
                if (blend.src_factor_rgb != cache.blend.src_factor_rgb or blend.dst_factor_rgb != cache.blend.dst_factor_rgb or blend.src_factor_alpha != cache.blend.src_factor_alpha or blend.dst_factor_alpha != cache.blend.dst_factor_alpha) {
                    cache.blend.src_factor_rgb = blend.src_factor_rgb;
                    cache.blend.dst_factor_rgb = blend.dst_factor_rgb;
                    cache.blend.src_factor_alpha = blend.src_factor_alpha;
                    cache.blend.dst_factor_alpha = blend.dst_factor_alpha;
                    driver.blendFuncSeparate.?(convert.blendFactor(blend.src_factor_rgb), convert.blendFactor(blend.dst_factor_rgb), convert.blendFactor(blend.src_factor_alpha), convert.blendFactor(blend.dst_factor_alpha));
                    cache.count("num_render_state", 1);
                }
                if (blend.op_rgb != cache.blend.op_rgb or blend.op_alpha != cache.blend.op_alpha) {
                    cache.blend.op_rgb = blend.op_rgb;
                    cache.blend.op_alpha = blend.op_alpha;
                    driver.blendEquationSeparate.?(convert.blendOp(blend.op_rgb), convert.blendOp(blend.op_alpha));
                    cache.count("num_render_state", 1);
                }
                for (desc.colors[0..@intCast(desc.color_count)], 0..) |color, i| {
                    if (color.write_mask == cache.color_masks[i]) continue;
                    cache.color_masks[i] = color.write_mask;
                    const mask = @backingInt(color.write_mask);
                    if (cache.features.mrt_independent_write_mask) driver.colorMaski.?(@intCast(i), @intFromBool(mask & 1 != 0), @intFromBool(mask & 2 != 0), @intFromBool(mask & 4 != 0), @intFromBool(mask & 8 != 0)) else if (i == 0) driver.colorMask.?(@intFromBool(mask & 1 != 0), @intFromBool(mask & 2 != 0), @intFromBool(mask & 4 != 0), @intFromBool(mask & 8 != 0));
                    cache.count("num_render_state", 1);
                }
                const color = desc.blend_color;
                const old_color = cache.blend_color;
                if (!equal(color.r, old_color.r, 0.0001) or !equal(color.g, old_color.g, 0.0001) or !equal(color.b, old_color.b, 0.0001) or !equal(color.a, old_color.a, 0.0001)) {
                    cache.blend_color = color;
                    driver.blendColor.?(color.r, color.g, color.b, color.a);
                    cache.count("num_render_state", 1);
                }
            }
            if (desc.cull_mode != cache.cull_mode) {
                cache.cull_mode = desc.cull_mode;
                self.toggle(c.cull_face, desc.cull_mode != .none);
                if (desc.cull_mode != .none) {
                    driver.cullFace.?(if (desc.cull_mode == .front) c.front else c.back);
                    cache.count("num_render_state", 1);
                }
            }
            if (desc.face_winding != cache.winding) {
                cache.winding = desc.face_winding;
                driver.frontFace.?(if (desc.face_winding == .cw) c.cw else c.ccw);
                cache.count("num_render_state", 1);
            }
            if (desc.alpha_to_coverage_enabled != cache.alpha_to_coverage) {
                cache.alpha_to_coverage = desc.alpha_to_coverage_enabled;
                self.toggle(c.sample_alpha_to_coverage, desc.alpha_to_coverage_enabled);
            }
            if (!self.gles and desc.sample_count != cache.samples) {
                cache.samples = desc.sample_count;
                self.toggle(c.multisample, desc.sample_count > 1);
            }
        }

        pub fn applyBindings(self: *Backend, bnd: *const r.Bindings) bool {
            const cache = &self.cache;
            const driver = cache.driver;
            const shader = bnd.shader;
            if (!cache.features.gl_texture_views) {
                // BASE_LEVEL/MAX_LEVEL belong to the texture, not the binding.
                // One image may appear on many units only with the same range.
                for (&shader.desc.texture_sampler_pairs, 0..) |pair, i| {
                    if (pair.stage == .none) continue;
                    const view = bnd.views[pair.view_slot].?;
                    const image = view.image.?;
                    for ((&shader.desc.texture_sampler_pairs)[0..i]) |prior| {
                        if (prior.stage == .none) continue;
                        const other = bnd.views[prior.view_slot].?;
                        const other_image = other.image.?;
                        if (image.resource.ids[@intCast(image.active_slot)] != other_image.resource.ids[@intCast(other_image.active_slot)]) continue;
                        const a = view.desc.texture.mip_levels;
                        const b = other.desc.texture.mip_levels;
                        if (a.base != b.base or a.count != b.count) {
                            core.logError(.gl_texture_view_mip_alias_conflict);
                            return false;
                        }
                    }
                }
            }
            for (&shader.desc.texture_sampler_pairs, 0..) |pair, i| {
                if (pair.stage == .none) continue;
                const unit = shader.resource.texture_slots[i];
                if (unit < 0) continue;
                const view = bnd.views[pair.view_slot].?;
                const image = view.image.?;
                const sampler = bnd.samplers[pair.sampler_slot].?;
                const texture = if (cache.features.gl_texture_views) view.resource.texture_views[@intCast(image.active_slot)] else image.resource.ids[@intCast(image.active_slot)];
                cache.bindTexture(@intCast(unit), image.resource.target, texture, sampler.id);
                if (!cache.features.gl_texture_views and image.desc.sample_count == 1) {
                    cache.activeTexture(c.texture0 + @as(u32, @intCast(unit)));
                    const range = view.desc.texture.mip_levels;
                    driver.texParameteri.?(image.resource.target, c.texture_base_level, range.base);
                    driver.texParameteri.?(image.resource.target, c.texture_max_level, range.base + range.count - 1);
                }
            }
            for (&shader.desc.views, &bnd.views, 0..) |required, optional, i| {
                if (required.texture.stage == .none and required.storage_buffer.stage == .none and required.storage_image.stage == .none) continue;
                const view = optional.?;
                if (view.buffer) |buffer| {
                    cache.bindStorageBuffer(shader.resource.storage_buffer_bindings[i], buffer.resource.ids[@intCast(buffer.active_slot)], view.desc.storage_buffer.offset, @intCast(buffer.desc.size));
                } else if (view.desc.storage_image.image.id != 0) {
                    const image = view.image.?;
                    const desc = view.desc.storage_image;
                    const unit = shader.resource.storage_image_bindings[i];
                    driver.bindImageTexture.?(unit, image.resource.ids[@intCast(image.active_slot)], desc.mip_level, 0, desc.slice, if (required.storage_image.writeonly) c.write_only else c.read_write, convert.pixelInternalFormat(required.storage_image.access_format));
                    cache.count("num_bind_image_texture", 1);
                }
            }
            if (!bnd.pipeline.desc.compute) {
                cache.bindBuffer(c.element_array_buffer, if (bnd.index_buffer) |buffer| buffer.resource.ids[@intCast(buffer.active_slot)] else 0);
                cache.index_offset = bnd.index_offset;
                for (bnd.pipeline.resource.attrs[0..@intCast(cache.limits.max_vertex_attrs)], 0..) |attr, i| {
                    const old = &cache.attrs[i];
                    var changed = false;
                    var offset: i32 = 0;
                    var buffer_id: u32 = 0;
                    if (attr.buffer_index >= 0) {
                        const index: usize = @intCast(attr.buffer_index);
                        const buffer = bnd.vertex_buffers[index].?;
                        buffer_id = buffer.resource.ids[@intCast(buffer.active_slot)];
                        offset = bnd.vertex_offsets[index] + attr.offset;
                        if (buffer_id != old.buffer or attr.size != old.attribute.size or attr.type != old.attribute.type or attr.normalized != old.attribute.normalized or attr.base_type != old.attribute.base_type or attr.stride != old.attribute.stride or offset != old.attribute.offset or attr.divisor != old.attribute.divisor) {
                            cache.bindBuffer(c.array_buffer, buffer_id);
                            const pointer = Backend.offsetPointer(null, @bitCast(@as(isize, offset)));
                            if (attr.base_type == .float) driver.vertexAttribPointer.?(@intCast(i), attr.size, attr.type, attr.normalized, attr.stride, pointer) else driver.vertexAttribIPointer.?(@intCast(i), attr.size, attr.type, attr.stride, pointer);
                            cache.count("num_vertex_attrib_pointer", 1);
                            driver.vertexAttribDivisor.?(@intCast(i), @bitCast(@as(i32, attr.divisor)));
                            cache.count("num_vertex_attrib_divisor", 1);
                            changed = true;
                        }
                        if (old.attribute.buffer_index == -1) {
                            driver.enableVertexAttribArray.?(@intCast(i));
                            cache.count("num_enable_vertex_attrib_array", 1);
                            changed = true;
                        }
                    } else if (old.attribute.buffer_index != -1) {
                        driver.disableVertexAttribArray.?(@intCast(i));
                        cache.count("num_disable_vertex_attrib_array", 1);
                        changed = true;
                    }
                    if (changed) {
                        old.attribute = attr;
                        old.attribute.offset = offset;
                        old.buffer = buffer_id;
                    }
                }
            }
            self.barriers(bnd, null);
            return true;
        }

        pub fn applyUniforms(self: *Backend, shader: *const r.Shader, slot: usize, data: t.Range) void {
            const block = &shader.uniform_blocks[slot];
            const driver = self.cache.driver;
            for (block.uniforms[0..block.count]) |uniform| {
                if (uniform.location == -1) continue;
                self.cache.count("num_uniform", 1);
                const bytes: [*]const u8 = @ptrCast(data.ptr.?);
                const pointer = bytes + uniform.offset;
                switch (uniform.type) {
                    .float => driver.uniform1fv.?(uniform.location, uniform.count, @ptrCast(@alignCast(pointer))),
                    .float2 => driver.uniform2fv.?(uniform.location, uniform.count, @ptrCast(@alignCast(pointer))),
                    .float3 => driver.uniform3fv.?(uniform.location, uniform.count, @ptrCast(@alignCast(pointer))),
                    .float4 => driver.uniform4fv.?(uniform.location, uniform.count, @ptrCast(@alignCast(pointer))),
                    .int => driver.uniform1iv.?(uniform.location, uniform.count, @ptrCast(@alignCast(pointer))),
                    .int2 => driver.uniform2iv.?(uniform.location, uniform.count, @ptrCast(@alignCast(pointer))),
                    .int3 => driver.uniform3iv.?(uniform.location, uniform.count, @ptrCast(@alignCast(pointer))),
                    .int4 => driver.uniform4iv.?(uniform.location, uniform.count, @ptrCast(@alignCast(pointer))),
                    .mat4 => driver.uniformMatrix4fv.?(uniform.location, uniform.count, 0, @ptrCast(@alignCast(pointer))),
                    else => unreachable,
                }
            }
        }

        pub fn draw(self: *Backend, use_instanced: bool, base: i32, elements: i32, instances: i32, base_vertex: i32, base_instance: i32) void {
            const driver = self.cache.driver;
            const primitive = self.cache.primitive_type;
            const instanced = instances > 1 or use_instanced;
            if (self.cache.index_type != 0) {
                const bytes: i32 = if (self.cache.index_type == c.unsigned_short) 2 else 4;
                const pointer = Backend.offsetPointer(null, @bitCast(@as(isize, base * bytes + self.cache.index_offset)));
                if (instanced) {
                    if (base_vertex == 0 and base_instance == 0) driver.drawElementsInstanced.?(primitive, elements, self.cache.index_type, pointer, instances) else if (base_vertex != 0 and base_instance == 0 and self.cache.features.draw_base_vertex) driver.drawElementsInstancedBaseVertex.?(primitive, elements, self.cache.index_type, pointer, instances, base_vertex) else if (base_instance != 0 and self.cache.features.draw_base_instance) driver.drawElementsInstancedBaseVertexBaseInstance.?(primitive, elements, self.cache.index_type, pointer, instances, base_vertex, @intCast(base_instance));
                } else {
                    if (base_vertex == 0) driver.drawElements.?(primitive, elements, self.cache.index_type, pointer) else if (self.cache.features.draw_base_vertex) driver.drawElementsBaseVertex.?(primitive, elements, self.cache.index_type, pointer, base_vertex);
                }
            } else if (instanced) {
                if (base_instance == 0) driver.drawArraysInstanced.?(primitive, base, elements, instances) else if (self.cache.features.draw_base_instance) driver.drawArraysInstancedBaseInstance.?(primitive, base, elements, instances, @intCast(base_instance));
            } else driver.drawArrays.?(primitive, base, elements);
        }
        pub fn dispatch(self: *Backend, x: i32, y: i32, z: i32) void {
            if (self.cache.features.compute) self.cache.driver.dispatchCompute.?(@intCast(x), @intCast(y), @intCast(z));
        }
        pub fn commit(self: *Backend) void {
            self.cache.clearBuffers(false);
            self.cache.clearTextures(false);
        }
    };
}
