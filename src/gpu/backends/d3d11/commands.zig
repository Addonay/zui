//! Native D3D11 commands from sokol_gfx.h:15358-16000.
const std = @import("std");
const sdk = @import("sdk.zig");
const c = @import("../dxgi/constants.zig");
const convert = @import("../dxgi/convert.zig");
const r = @import("resources.zig");
const t = @import("../../types.zig");
const e = @import("../../enums.zig");

pub fn Commands(comptime Backend: type) type {
    return struct {
        pub fn countStat(self: *Backend, comptime group: []const u8, comptime field: []const u8) void {
            if (self.stats_enabled) @field(@field(self.stats, group), field) +%= 1;
        }
        pub fn beginPass(self: *Backend, pass: t.Pass, atts: *const r.Attachments) bool {
            if (pass.compute) return true;
            var targets: [8]?*sdk.Object = @splat(null);
            var depth: ?*sdk.Object = null;
            self.swapchain_render = null;
            self.swapchain_resolve = null;
            const offscreen = !atts.empty();
            const count_targets = if (offscreen) atts.num_colors else 1;
            if (offscreen) {
                for (atts.colors[0..atts.num_colors], 0..) |view, i| targets[i] = view.?.resource.rtv;
                if (atts.depth_stencil) |view| depth = view.resource.dsv;
            } else {
                targets[0] = if (pass.swapchain.d3d11.render_view) |pointer| sdk.fromOpaque(pointer) else null;
                depth = if (pass.swapchain.d3d11.depth_stencil_view) |pointer| sdk.fromOpaque(pointer) else null;
                self.swapchain_render = targets[0];
                self.swapchain_resolve = if (pass.swapchain.d3d11.resolve_view) |pointer| sdk.fromOpaque(pointer) else null;
            }
            sdk.omSetRenderTargets(self.context, 8, &targets, depth);
            self.countStat("pass", "num_om_set_render_targets");
            const width = if (offscreen) atts.width else pass.swapchain.width;
            const height = if (offscreen) atts.height else pass.swapchain.height;
            const initial_viewport: sdk.Viewport = .{ .width = @floatFromInt(width), .height = @floatFromInt(height), .max_depth = 1 };
            sdk.rsSetViewports(self.context, 1, @ptrCast(&initial_viewport));
            const rect: sdk.Rect = .{ .right = width, .bottom = height };
            sdk.rsSetScissorRects(self.context, 1, @ptrCast(&rect));
            for (pass.action.colors[0..count_targets], targets[0..count_targets]) |color, target| {
                if (color.load_action == .clear) {
                    const rgba = [_]f32{ color.clear_value.r, color.clear_value.g, color.clear_value.b, color.clear_value.a };
                    sdk.clearRenderTargetView(self.context, target, &rgba);
                    self.countStat("pass", "num_clear_render_target_view");
                }
            }
            var flags: u32 = 0;
            if (pass.action.depth.load_action == .clear) flags |= c.clear_depth;
            if (pass.action.stencil.load_action == .clear) flags |= c.clear_stencil;
            if (flags != 0 and depth != null) {
                sdk.clearDepthStencilView(self.context, depth, flags, pass.action.depth.clear_value, pass.action.stencil.clear_value);
                self.countStat("pass", "num_clear_depth_stencil_view");
            }
            return true;
        }
        pub fn endPass(self: *Backend, pass: t.Pass, atts: *const r.Attachments) void {
            if (!pass.compute) {
                if (!atts.empty()) {
                    for (atts.resolves[0..atts.num_colors], atts.colors[0..atts.num_colors]) |optional, color| {
                        const resolve = optional orelse continue;
                        const src = color.?.image.?;
                        const dst = resolve.image.?;
                        const source_view = color.?.desc.color_attachment;
                        const dest_view = resolve.desc.resolve_attachment;
                        sdk.resolveSubresource(self.context, dst.resource.resource, convert.subresource(@intCast(dest_view.mip_level), @intCast(dest_view.slice), @intCast(dst.desc.num_mipmaps)), src.resource.resource, convert.subresource(@intCast(source_view.mip_level), @intCast(source_view.slice), @intCast(src.desc.num_mipmaps)), convert.rtvUavFormat(src.desc.pixel_format));
                        self.countStat("pass", "num_resolve_subresource");
                    }
                } else if (self.swapchain_resolve) |resolve| {
                    var src: ?*sdk.Object = null;
                    var dst: ?*sdk.Object = null;
                    sdk.getResource(self.swapchain_render.?, &src);
                    sdk.getResource(resolve, &dst);
                    sdk.resolveSubresource(self.context, dst, 0, src, 0, convert.rtvUavFormat(pass.swapchain.color_format));
                    sdk.release(src);
                    sdk.release(dst);
                    self.countStat("pass", "num_resolve_subresource");
                }
            }
            self.swapchain_render = null;
            self.swapchain_resolve = null;
            sdk.clearState(self.context);
        }
        pub fn viewport(self: *Backend, height: i32, x: i32, y: i32, width: i32, h: i32, origin_top_left: bool) void {
            const view: sdk.Viewport = .{ .top_left_x = @floatFromInt(x), .top_left_y = @floatFromInt(if (origin_top_left) y else height - (y + h)), .width = @floatFromInt(width), .height = @floatFromInt(h), .max_depth = 1 };
            sdk.rsSetViewports(self.context, 1, @ptrCast(&view));
        }
        pub fn scissor(self: *Backend, height: i32, x: i32, y: i32, width: i32, h: i32, origin_top_left: bool) void {
            const rect: sdk.Rect = .{ .left = x, .top = if (origin_top_left) y else height - (y + h), .right = x + width, .bottom = if (origin_top_left) y + h else height - y };
            sdk.rsSetScissorRects(self.context, 1, @ptrCast(&rect));
        }
        pub fn applyPipeline(self: *Backend, binding: r.PipelineBinding, shader: *const r.Shader) void {
            const pipeline = binding.resource;
            if (binding.desc.compute) {
                sdk.csSetShader(self.context, shader.compute, null, 0);
                sdk.csSetConstantBuffers(self.context, 0, 8, &shader.compute_uniforms);
                self.countStat("pipeline", "num_cs_set_shader");
                self.countStat("pipeline", "num_cs_set_constant_buffers");
            } else {
                const color = binding.desc.blend_color;
                const blend = [_]f32{ color.r, color.g, color.b, color.a };
                sdk.rsSetState(self.context, pipeline.rasterizer);
                sdk.omSetDepthStencilState(self.context, pipeline.depth_stencil, pipeline.stencil_ref);
                sdk.omSetBlendState(self.context, pipeline.blend, &blend, 0xffffffff);
                sdk.iaSetPrimitiveTopology(self.context, pipeline.topology);
                sdk.iaSetInputLayout(self.context, pipeline.input_layout);
                sdk.vsSetShader(self.context, shader.vertex, null, 0);
                sdk.vsSetConstantBuffers(self.context, 0, 8, &shader.vertex_uniforms);
                sdk.psSetShader(self.context, shader.fragment, null, 0);
                sdk.psSetConstantBuffers(self.context, 0, 8, &shader.fragment_uniforms);
                inline for (.{ "num_rs_set_state", "num_om_set_depth_stencil_state", "num_om_set_blend_state", "num_ia_set_primitive_topology", "num_ia_set_input_layout", "num_vs_set_shader", "num_vs_set_constant_buffers", "num_ps_set_shader", "num_ps_set_constant_buffers" }) |field| self.countStat("pipeline", field);
            }
        }
        pub fn applyBindings(self: *Backend, bnd: *const r.Bindings) bool {
            var views: [3][32]?*sdk.Object = @splat(@splat(null));
            var uavs: [2][32]?*sdk.Object = @splat(@splat(null));
            var samplers: [3][12]?*sdk.Object = @splat(@splat(null));
            var buffers: [8]?*sdk.Object = @splat(null);
            var offsets: [8]u32 = @splat(0);
            const compute = bnd.pipeline.desc.compute;
            if (compute) sdk.csSetShaderResources(self.context, 0, 32, &views[2]);
            if (!compute) for (&bnd.vertex_buffers, &bnd.vertex_offsets, 0..) |optional, offset, i| {
                if (optional) |buffer| {
                    buffers[i] = buffer.resource.object;
                    offsets[i] = @intCast(offset);
                }
            };
            var fragment_uavs = false;
            for (&bnd.views, &bnd.shader.desc.views, 0..) |optional, required, i| {
                const view = optional orelse continue;
                const stage = if (required.texture.stage != .none) required.texture.stage else if (required.storage_buffer.stage != .none) required.storage_buffer.stage else required.storage_image.stage;
                if (stage == .none) continue;
                const stage_index: usize = @backingInt(stage) - 1;
                if (required.texture.stage != .none or (required.storage_buffer.stage != .none and required.storage_buffer.readonly)) {
                    views[stage_index][bnd.shader.resource.srv_registers[i]] = view.resource.srv;
                } else {
                    const slot = bnd.shader.resource.uav_registers[i];
                    if (stage != .compute and stage != .fragment) return false;
                    uavs[if (stage == .compute) @as(usize, 1) else 0][slot] = view.resource.uav;
                    fragment_uavs = fragment_uavs or stage == .fragment;
                }
            }
            for (&bnd.samplers, &bnd.shader.desc.samplers, 0..) |optional, required, i| {
                const sampler = optional orelse continue;
                if (required.stage == .none) continue;
                samplers[@backingInt(required.stage) - 1][bnd.shader.resource.sampler_registers[i]] = sampler.object;
            }
            if (compute) {
                sdk.csSetUnorderedAccessViews(self.context, 0, @intCast(self.limits.d3d11_max_unordered_access_views), &uavs[1], null);
                sdk.csSetShaderResources(self.context, 0, 32, &views[2]);
                sdk.csSetSamplers(self.context, 0, 12, &samplers[2]);
                inline for (.{ "num_cs_set_unordered_access_views", "num_cs_set_shader_resources", "num_cs_set_samplers" }) |field| self.countStat("bindings", field);
            } else {
                sdk.iaSetVertexBuffers(self.context, 0, 8, &buffers, &bnd.pipeline.resource.vertex_strides, &offsets);
                sdk.iaSetIndexBuffer(self.context, if (bnd.index_buffer) |buffer| buffer.resource.object else null, bnd.pipeline.resource.index_format, @intCast(bnd.index_offset));
                sdk.vsSetShaderResources(self.context, 0, 32, &views[0]);
                sdk.psSetShaderResources(self.context, 0, 32, &views[1]);
                sdk.vsSetSamplers(self.context, 0, 12, &samplers[0]);
                sdk.psSetSamplers(self.context, 0, 12, &samplers[1]);
                if (fragment_uavs) {
                    const first: u32 = @intCast(bnd.pipeline.desc.color_count);
                    const count_uavs = @as(u32, @intCast(self.limits.d3d11_max_unordered_access_views)) - first;
                    sdk.omSetRenderTargetsAndUnorderedAccessViews(self.context, c.keep_render_targets_and_depth_stencil, null, null, first, count_uavs, uavs[0][first..].ptr, null);
                    self.countStat("bindings", "num_om_set_rts_and_uavs");
                }
                inline for (.{ "num_ia_set_vertex_buffers", "num_ia_set_index_buffer", "num_vs_set_shader_resources", "num_ps_set_shader_resources", "num_vs_set_samplers", "num_ps_set_samplers" }) |field| self.countStat("bindings", field);
            }
            return true;
        }
        pub fn applyUniforms(self: *Backend, shader: *const r.Shader, slot: usize, data: t.Range) void {
            var pointer = data.ptr;
            if (shader.uniform_uploads[slot]) |upload| {
                const source: [*]const u8 = @ptrCast(data.ptr.?);
                @memcpy(upload[0..data.size], source[0..data.size]);
                pointer = upload.ptr;
            }
            sdk.updateSubresource(self.context, shader.uniform_buffers[slot], 0, null, pointer, 0, 0);
            self.countStat("uniforms", "num_update_subresource");
        }
        pub fn draw(self: *Backend, indexed: bool, use_instanced: bool, base: i32, elements: i32, instances: i32, base_vertex: i32, base_instance: i32) void {
            const instanced = use_instanced or instances > 1;
            if (indexed) {
                if (instanced) {
                    sdk.drawIndexedInstanced(self.context, @intCast(elements), @intCast(instances), @intCast(base), base_vertex, @intCast(base_instance));
                    self.countStat("draw", "num_draw_indexed_instanced");
                } else {
                    sdk.drawIndexed(self.context, @intCast(elements), @intCast(base), base_vertex);
                    self.countStat("draw", "num_draw_indexed");
                }
            } else {
                if (instanced) {
                    sdk.drawInstanced(self.context, @intCast(elements), @intCast(instances), @intCast(base), @intCast(base_instance));
                    self.countStat("draw", "num_draw_instanced");
                } else {
                    sdk.draw(self.context, @intCast(elements), @intCast(base));
                    self.countStat("draw", "num_draw");
                }
            }
        }
        pub fn dispatch(self: *Backend, x: i32, y: i32, z: i32) void {
            sdk.dispatch(self.context, @intCast(x), @intCast(y), @intCast(z));
        }
        pub fn writeBuffer(self: *Backend, buffer: *r.Buffer, desc: t.WriteBufferDesc, transient: bool, first: bool) void {
            const bytes: [*]const u8 = @ptrCast(desc.src.data.ptr.?);
            const source = bytes + desc.src.offset;
            if (buffer.staging) |staging| {
                @memcpy(staging[desc.dst.offset..][0..desc.size], source[0..desc.size]);
                return;
            }
            if (transient) {
                var mapped: sdk.MappedSubresource = .{};
                const status = sdk.map(self.context, buffer.object, 0, if (first) c.map_write_discard else c.map_write_no_overwrite, 0, @ptrCast(&mapped));
                if (self.stats_enabled) self.stats.num_map +%= 1;
                if (status < 0 or mapped.data == null) {
                    self.message(1, .d3d11_map_for_write_buffer_transient_failed, null);
                    return;
                }
                const target: [*]u8 = @ptrCast(mapped.data.?);
                @memcpy((target + desc.dst.offset)[0..desc.size], source[0..desc.size]);
                sdk.unmap(self.context, buffer.object, 0);
                if (self.stats_enabled) self.stats.num_unmap +%= 1;
            } else {
                const box: sdk.Box = .{ .left = @intCast(desc.dst.offset), .right = @intCast(desc.dst.offset + desc.size), .bottom = 1, .back = 1 };
                sdk.updateSubresource(self.context, buffer.object, 0, @ptrCast(&box), source, 0, 0);
            }
        }
        pub fn writeImage(self: *Backend, image: *const r.Image, desc: t.ImageDesc, write: t.WriteImageDesc) void {
            const source: [*]const u8 = @ptrCast(write.src.data.ptr.?);
            const volume = desc.type == .@"3d";
            const count: usize = if (volume) 1 else @intCast(write.size.num_slices);
            const first = if (volume) 0 else write.dst.slice;
            const box: sdk.Box = .{ .left = @intCast(write.dst.x), .right = @intCast(write.dst.x + write.size.width), .top = @intCast(write.dst.y), .bottom = @intCast(write.dst.y + write.size.height), .front = if (volume) @intCast(write.dst.slice) else 0, .back = if (volume) @intCast(write.dst.slice + write.size.num_slices) else 1 };
            for (0..count) |i| {
                const data = source + write.src.offset + i * @as(usize, @intCast(write.src.bytes_per_slice));
                const index = convert.subresource(@intCast(write.dst.mip_level), @as(u32, @intCast(first)) + @as(u32, @intCast(i)), @intCast(desc.num_mipmaps));
                sdk.updateSubresource(self.context, image.resource, index, @ptrCast(&box), data, @intCast(write.src.bytes_per_row), if (volume) @intCast(write.src.bytes_per_slice) else 0);
            }
        }
        pub fn copyBuffer(self: *Backend, source: *const r.Buffer, target: *const r.Buffer, desc: t.CopyBufferToBufferDesc) void {
            if (source.staging) |staging| {
                const box: sdk.Box = .{ .left = @intCast(desc.dst.offset), .right = @intCast(desc.dst.offset + desc.size), .bottom = 1, .back = 1 };
                sdk.updateSubresource(self.context, target.object, 0, @ptrCast(&box), staging[desc.src.offset..].ptr, 0, 0);
            } else {
                const box: sdk.Box = .{ .left = @intCast(desc.src.offset), .right = @intCast(desc.src.offset + desc.size), .bottom = 1, .back = 1 };
                sdk.copySubresourceRegion(self.context, target.object, 0, @intCast(desc.dst.offset), 0, 0, source.object, 0, @ptrCast(&box));
            }
        }
        pub fn copyBufferToImage(self: *Backend, buffer: *const r.Buffer, image: *const r.Image, desc: t.ImageDesc, copy: t.CopyBufferToImageDesc) void {
            self.writeImage(image, desc, .{ .src = .{ .data = .{ .ptr = buffer.staging.?.ptr, .size = buffer.staging.?.len }, .offset = copy.src.offset, .bytes_per_row = copy.src.bytes_per_row, .bytes_per_slice = copy.src.bytes_per_slice }, .dst = copy.dst, .size = copy.size });
        }
    };
}
