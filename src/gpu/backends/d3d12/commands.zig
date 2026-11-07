//! Passes, bindings, draws, transfers and readback of the D3D12 backend. The
//! functions take the backend as `self`; each records into the current frame's
//! command list, or into the one-shot list where DESIGN.md says so.
const std = @import("std");
const t = @import("../../types.zig");
const e = @import("../../enums.zig");
const core = @import("../../core.zig");
const config = @import("../../config.zig");
const formats = @import("../../formats.zig");
const k = @import("constants.zig");
const sdk = @import("sdk.zig");
const memory = @import("memory.zig");
const res = @import("resources.zig");
const convert = @import("../dxgi/convert.zig");
const dx = @import("../dxgi/constants.zig");
const Backend = @import("backend.zig").Backend;

/// Where a copy reads from: an array of footprints, each `pitch` bytes per row and
/// `stride` bytes apart. Offsets and strides are 512-byte aligned, pitches 256-byte aligned.
const Footprints = struct {
    resource: *sdk.Object,
    offset: u64,
    pitch: u32,
    stride: u64,
};

fn barrier(list: *sdk.Object, resource: *sdk.Object, before: u32, after: u32) void {
    if (before == after) return;
    const transition: sdk.ResourceBarrier = .{
        .type = k.barrier_type_transition,
        .flags = k.barrier_flag_none,
        .payload = .{ .transition = .{ .resource = resource, .subresource = 0xffffffff, .state_before = before, .state_after = after } },
    };
    sdk.resourceBarrier(list, 1, @ptrCast(&transition));
}

/// Transitions a tracked resource to `after`, unless it is already in that state.
fn useState(list: *sdk.Object, resource: *sdk.Object, state: *u32, after: u32) void {
    barrier(list, resource, state.*, after);
    state.* = after;
}

/// Makes a tracked resource usable as an unordered access view, with a UAV barrier between consecutive uses.
fn useUav(list: *sdk.Object, resource: *sdk.Object, state: *u32) void {
    if (state.* == k.state_unordered_access) {
        const uav: sdk.ResourceBarrier = .{ .type = k.barrier_type_uav, .flags = k.barrier_flag_none, .payload = .{ .uav = .{ .resource = resource } } };
        sdk.resourceBarrier(list, 1, @ptrCast(&uav));
    } else useState(list, resource, state, k.state_unordered_access);
}

fn alignUp(value: usize, alignment: usize) usize {
    return std.mem.alignForward(usize, value, alignment);
}

// ---------------------------------------------------------------- passes

pub fn beginPass(self: *Backend, pass: *const t.Pass, atts: *const core.AttachmentsPtrs) bool {
    const list = self.frameList() orelse return false;
    if (pass.compute) return true;
    const st = core.state();
    var rtvs: [8]usize = @splat(0);
    var count: u32 = 0;
    var dsv: usize = 0;
    self.swapchain = .{};
    if (atts.empty) {
        // the swapchain targets get descriptors in the slots reserved for this frame slot
        const sc = pass.swapchain.d3d12;
        const slot = self.swapchain_slots + @as(u32, @intCast(self.frame_slot));
        const render = sdk.fromOpaque(sc.render_target orelse return false);
        self.swapchain.render = render;
        self.swapchain.resolve = if (sc.resolve_target) |ptr| sdk.fromOpaque(ptr) else null;
        const rtv_handle = self.heaps[@backingInt(memory.Kind.rtv)].handle(slot);
        sdk.createRenderTargetView(self.device, render, null, rtv_handle);
        barrier(list, render, k.state_present, k.state_render_target);
        rtvs[0] = rtv_handle;
        count = 1;
        if (sc.depth_stencil_target) |ptr| {
            self.swapchain.depth = sdk.fromOpaque(ptr);
            dsv = self.heaps[@backingInt(memory.Kind.dsv)].handle(slot);
            sdk.createDepthStencilView(self.device, self.swapchain.depth.?, null, dsv);
        }
    } else {
        count = @intCast(atts.num_color_views);
        for (0..atts.num_color_views) |i| {
            const view = atts.color_views[i].?;
            const img = view.cmn.img.ref.get();
            useState(list, img.native.d3d12.resource.?, &img.native.d3d12.state, k.state_render_target);
            rtvs[i] = view.native.d3d12.rtv;
        }
        if (atts.ds_view) |view| {
            const img = view.cmn.img.ref.get();
            useState(list, img.native.d3d12.resource.?, &img.native.d3d12.state, k.state_depth_write);
            dsv = view.native.d3d12.dsv;
        }
    }
    const dsv_ptr: ?*const usize = if (dsv != 0) &dsv else null;
    sdk.omSetRenderTargets(list, count, &rtvs, dsv_ptr);

    const dim = st.cur_pass.dim;
    const viewport: sdk.Viewport = .{ .width = @floatFromInt(dim.width), .height = @floatFromInt(dim.height) };
    sdk.rsSetViewports(list, 1, &viewport);
    const rect: sdk.Rect = .{ .right = dim.width, .bottom = dim.height };
    sdk.rsSetScissorRects(list, 1, &rect);

    for (0..count) |i| {
        const color = pass.action.colors[i];
        if (color.load_action != .clear) continue;
        const rgba = [4]f32{ color.clear_value.r, color.clear_value.g, color.clear_value.b, color.clear_value.a };
        sdk.clearRenderTargetView(list, rtvs[i], &rgba);
    }
    var flags: u32 = 0;
    if (pass.action.depth.load_action == .clear) flags |= k.clear_depth;
    if (pass.action.stencil.load_action == .clear) flags |= k.clear_stencil;
    if (flags != 0 and dsv != 0) {
        sdk.clearDepthStencilView(list, dsv, flags, pass.action.depth.clear_value, pass.action.stencil.clear_value);
    }
    return true;
}

pub fn endPass(self: *Backend, atts: *const core.AttachmentsPtrs) void {
    defer self.swapchain = .{};
    const st = core.state();
    if (st.cur_pass.is_compute or !self.frame_open) return;
    const list = self.frames[self.frame_slot].list.?;
    if (!atts.empty) {
        for (0..atts.num_color_views) |i| {
            const resolve = atts.resolve_views[i] orelse continue;
            const color = atts.color_views[i].?;
            const src_img = color.cmn.img.ref.get();
            const dst_img = resolve.cmn.img.ref.get();
            useState(list, src_img.native.d3d12.resource.?, &src_img.native.d3d12.state, k.state_resolve_source);
            useState(list, dst_img.native.d3d12.resource.?, &dst_img.native.d3d12.state, k.state_resolve_dest);
            const src_sub = convert.subresource(@intCast(color.cmn.img.mip_level), @intCast(color.cmn.img.slice), @intCast(src_img.cmn.num_mipmaps));
            const dst_sub = convert.subresource(@intCast(resolve.cmn.img.mip_level), @intCast(resolve.cmn.img.slice), @intCast(dst_img.cmn.num_mipmaps));
            sdk.resolveSubresource(list, dst_img.native.d3d12.resource, dst_sub, src_img.native.d3d12.resource, src_sub, convert.rtvUavFormat(src_img.cmn.pixel_format));
        }
    } else if (self.swapchain.render) |render| {
        if (self.swapchain.resolve) |resolve| {
            barrier(list, render, k.state_render_target, k.state_resolve_source);
            barrier(list, resolve, k.state_present, k.state_resolve_dest);
            sdk.resolveSubresource(list, resolve, 0, render, 0, convert.rtvUavFormat(st.cur_pass.swapchain.color_fmt));
            barrier(list, resolve, k.state_resolve_dest, k.state_present);
            barrier(list, render, k.state_resolve_source, k.state_present);
        } else {
            barrier(list, render, k.state_render_target, k.state_present);
        }
    }
}

// ---------------------------------------------------------------- state and draws

pub fn applyViewport(self: *Backend, x: i32, y: i32, w: i32, h: i32, origin_top_left: bool) void {
    const list = self.frameList() orelse return;
    const dim = core.state().cur_pass.dim;
    const viewport: sdk.Viewport = .{
        .top_left_x = @floatFromInt(x),
        .top_left_y = @floatFromInt(if (origin_top_left) y else dim.height - (y + h)),
        .width = @floatFromInt(w),
        .height = @floatFromInt(h),
    };
    sdk.rsSetViewports(list, 1, &viewport);
}

pub fn applyScissorRect(self: *Backend, x: i32, y: i32, w: i32, h: i32, origin_top_left: bool) void {
    const list = self.frameList() orelse return;
    const dim = core.state().cur_pass.dim;
    const clip = core.clipRect(x, y, w, h, dim.width, dim.height);
    const top = if (origin_top_left) clip.y else dim.height - (clip.y + clip.h);
    const rect: sdk.Rect = .{ .left = clip.x, .top = top, .right = clip.x + clip.w, .bottom = top + clip.h };
    sdk.rsSetScissorRects(list, 1, &rect);
}

pub fn applyPipeline(self: *Backend, pip: *core.Pipeline) void {
    const list = self.frameList() orelse return;
    const payload = &pip.native.d3d12;
    const shader = &pip.cmn.shader.get().native.d3d12;
    sdk.setPipelineState(list, payload.pso);
    if (pip.cmn.is_compute) {
        sdk.setComputeRootSignature(list, shader.root_signature);
        return;
    }
    sdk.setGraphicsRootSignature(list, shader.root_signature);
    sdk.iaSetPrimitiveTopology(list, payload.topology);
    sdk.omSetBlendFactor(list, &payload.blend_color);
    sdk.omSetStencilRef(list, payload.stencil_ref);
}

pub fn applyBindings(self: *Backend, bnd: *const core.BindingsPtrs) bool {
    const list = self.frameList() orelse return false;
    const st = core.state();
    const pip = bnd.pip;
    const is_compute = pip.cmn.is_compute;
    const shader = &pip.cmn.shader.get().native.d3d12;

    if (!is_compute) {
        for (bnd.vbs, bnd.vb_offsets, 0..) |maybe_buf, offset, i| {
            const buf = maybe_buf orelse continue;
            const payload = &buf.native.d3d12;
            useState(list, payload.resource.?, &payload.state, k.state_vertex_and_constant_buffer);
            const view: sdk.VertexBufferView = .{
                .buffer_location = payload.gpu_address + @as(u64, @intCast(offset)),
                .size_in_bytes = @intCast(buf.cmn.size - @as(usize, @intCast(offset))),
                .stride_in_bytes = pip.native.d3d12.vertex_strides[i],
            };
            sdk.iaSetVertexBuffer(list, @intCast(i), &view);
        }
        if (bnd.ib) |buf| {
            const payload = &buf.native.d3d12;
            useState(list, payload.resource.?, &payload.state, k.state_index_buffer);
            const view: sdk.IndexBufferView = .{
                .buffer_location = payload.gpu_address + @as(u64, @intCast(bnd.ib_offset)),
                .size_in_bytes = @intCast(buf.cmn.size - @as(usize, @intCast(bnd.ib_offset))),
                .format = pip.native.d3d12.index_format,
            };
            sdk.iaSetIndexBuffer(list, &view);
        } else sdk.iaSetIndexBuffer(list, null);
    }

    // the handles of every register of every stage, zero where nothing is bound
    var srv_handles: [res.stage_count][32]usize = std.mem.zeroes([res.stage_count][32]usize);
    var uav_handles: [res.stage_count][32]usize = std.mem.zeroes([res.stage_count][32]usize);
    var smp_handles: [res.stage_count][12]usize = std.mem.zeroes([res.stage_count][12]usize);
    const read_state: u32 = if (is_compute) k.state_non_pixel_shader_resource else k.state_pixel_shader_resource | k.state_non_pixel_shader_resource;
    for (0..32) |i| {
        const binding = shader.views[i];
        if (!binding.active) continue;
        const view = bnd.views[i] orelse continue;
        const payload = &view.native.d3d12;
        switch (view.cmn.type) {
            .texture => {
                const img = view.cmn.img.ref.get();
                useState(list, img.native.d3d12.resource.?, &img.native.d3d12.state, read_state);
            },
            .storagebuffer => {
                const buf = view.cmn.buf.ref.get();
                if (binding.kind == .srv) {
                    useState(list, buf.native.d3d12.resource.?, &buf.native.d3d12.state, read_state);
                } else useUav(list, buf.native.d3d12.resource.?, &buf.native.d3d12.state);
            },
            .storageimage => {
                const img = view.cmn.img.ref.get();
                useUav(list, img.native.d3d12.resource.?, &img.native.d3d12.state);
            },
            else => unreachable,
        }
        if (binding.kind == .uav) {
            uav_handles[binding.stage][binding.register] = payload.uav;
        } else srv_handles[binding.stage][binding.register] = payload.srv;
    }
    for (0..12) |i| {
        const binding = shader.samplers[i];
        if (!binding.active) continue;
        const smp = bnd.smps[i] orelse continue;
        smp_handles[binding.stage][binding.register] = smp.native.d3d12.handle;
    }

    // one descriptor table per stage and kind, filled from the persistent heaps
    for (0..res.stage_count) |stage| for (0..3) |kind| {
        const table = shader.tables[stage][kind];
        if (table.count == 0) continue;
        const sampler_kind = kind == @backingInt(res.TableKind.sampler);
        const ring: *memory.DescriptorRing = if (sampler_kind) &self.sampler_ring else &self.srv_ring;
        const range = ring.alloc(table.count) orelse {
            core.logError(.d3d12_descriptor_ring_overflow);
            st.next_draw_valid = false;
            return false;
        };
        const heap_type: u32 = if (sampler_kind) k.heap_type_sampler else k.heap_type_cbv_srv_uav;
        for (0..table.count) |register| {
            const source = switch (kind) {
                0 => if (srv_handles[stage][register] != 0) srv_handles[stage][register] else self.null_srv,
                1 => if (uav_handles[stage][register] != 0) uav_handles[stage][register] else self.null_uav,
                else => if (smp_handles[stage][register] != 0) smp_handles[stage][register] else self.null_sampler,
            };
            sdk.copyDescriptorsSimple(self.device, 1, range.cpu + @as(usize, register) * ring.heap.increment, source, heap_type);
        }
        if (is_compute) {
            sdk.setComputeRootDescriptorTable(list, table.param, range.gpu);
        } else sdk.setGraphicsRootDescriptorTable(list, table.param, range.gpu);
    };
    return true;
}

pub fn applyUniforms(self: *Backend, ub_slot: usize, data: *const t.Range) void {
    const list = self.frameList() orelse return;
    const st = core.state();
    const pip = st.cur_pip.get();
    const shader = &pip.cmn.shader.get().native.d3d12;
    const size = data.size;
    const aligned = alignUp(size, 256);
    const region = self.uniforms.alloc(aligned, 256) orelse {
        core.logError(.d3d12_uniform_buffer_overflow);
        st.next_draw_valid = false;
        return;
    };
    const source: [*]const u8 = @ptrCast(data.ptr.?);
    @memcpy(region.ptr[0..size], source[0..size]);
    @memset(region.ptr[size..aligned], 0);
    const param = shader.ub_param[ub_slot];
    if (pip.cmn.is_compute) {
        sdk.setComputeRootConstantBufferView(list, param, region.gpu);
    } else sdk.setGraphicsRootConstantBufferView(list, param, region.gpu);
}

pub fn draw(self: *Backend, base_element: i32, num_elements: i32, num_instances: i32, base_vertex: i32, base_instance: i32) void {
    const list = self.frameList() orelse return;
    if (core.state().use_indexed_draw) {
        sdk.drawIndexedInstanced(list, @intCast(num_elements), @intCast(num_instances), @intCast(base_element), base_vertex, @intCast(base_instance));
    } else {
        sdk.drawInstanced(list, @intCast(num_elements), @intCast(num_instances), @intCast(base_element), @intCast(base_instance));
    }
}

pub fn dispatch(self: *Backend, x: i32, y: i32, z: i32) void {
    const list = self.frameList() orelse return;
    sdk.dispatch(list, @intCast(x), @intCast(y), @intCast(z));
}

// ---------------------------------------------------------------- transfers

/// Copies `rows` rows of `row_bytes` for each of `slices` slices from `src` (row and slice pitches
/// given in bytes) into `dst`, where rows are `pitch` and slices `stride` bytes apart.
fn repackRows(dst: [*]u8, src: [*]const u8, src_row: usize, src_slice: usize, row_bytes: usize, rows: usize, slices: usize, pitch: usize, stride: usize) void {
    for (0..slices) |s| for (0..rows) |r| {
        @memcpy(dst[s * stride + r * pitch ..][0..row_bytes], src[s * src_slice + r * src_row ..][0..row_bytes]);
    };
}

const Layout = struct { row_bytes: usize, rows: usize, pitch: usize, stride: usize };

/// Query a single-slice footprint from the device. Array and depth slices are
/// copied separately at 512-byte-aligned placements; never infer BC block rows.
fn layout(self: *Backend, format: e.PixelFormat, width: i32, height: i32) ?Layout {
    const block: usize = @intCast(formats.blockDimension(format));
    const desc: sdk.ResourceDesc = .{ .dimension = k.dimension_texture2d, .width = alignUp(@intCast(width), block), .height = @intCast(alignUp(@intCast(height), block)), .depth_or_array_size = 1, .mip_levels = 1, .format = convert.textureFormat(format), .sample_desc = .{ .count = 1 } };
    var placed: sdk.PlacedFootprint = .{};
    var rows: u32 = 0;
    var row_bytes: u64 = 0;
    var total: u64 = 0;
    sdk.getCopyableFootprints(self.device, &desc, 0, 1, 0, @ptrCast(&placed), @ptrCast(&rows), @ptrCast(&row_bytes), &total);
    if (total == std.math.maxInt(u64) or rows == 0 or row_bytes == 0 or placed.footprint.row_pitch == 0) {
        core.logError(.d3d12_create_temp_buffer_failed);
        return null;
    }
    return .{ .row_bytes = @intCast(row_bytes), .rows = rows, .pitch = placed.footprint.row_pitch, .stride = alignUp(@intCast(total), k.texture_data_placement_alignment) };
}

/// A CPU-written upload buffer for one-shot transfers, released after the GPU finished with it.
const TempUpload = struct {
    resource: *sdk.Object,
    ptr: [*]u8,

    fn create(self: *Backend, size: usize) ?TempUpload {
        const heap: sdk.HeapProperties = .{ .type = k.heap_upload };
        const desc = memory.bufferDesc(size, 0);
        var resource: ?*sdk.Object = null;
        if (sdk.createCommittedResource(self.device, &heap, k.heap_flag_none, &desc, k.state_generic_read, &resource) < 0 or resource == null) {
            core.logError(.d3d12_create_temp_buffer_failed);
            return null;
        }
        var mapped: ?*anyopaque = null;
        if (sdk.resourceMap(resource.?, 0, &mapped) < 0 or mapped == null) {
            sdk.release(resource);
            core.logError(.d3d12_create_temp_buffer_failed);
            return null;
        }
        return .{ .resource = resource.?, .ptr = @ptrCast(mapped.?) };
    }

    /// Frame uploads retain their staging resource until the frame fence completes.
    fn finish(self: TempUpload, backend: *Backend, recorded_in_frame: bool) void {
        if (recorded_in_frame) {
            sdk.resourceUnmap(self.resource, 0);
            backend.releaseLater(self.resource);
        } else self.destroy();
    }

    fn destroy(self: TempUpload) void {
        sdk.resourceUnmap(self.resource, 0);
        sdk.release(self.resource);
    }
};

/// Copies the initial data of a buffer, or any range of CPU data, with a one-shot upload.
pub fn uploadBufferOneShot(self: *Backend, buf: *core.Buffer, offset: usize, data: *const t.Range) bool {
    const temp = TempUpload.create(self, data.size) orelse return false;
    var recorded_in_frame = false;
    defer temp.finish(self, recorded_in_frame);
    if (!self.reserveRelease()) return false;
    const source: [*]const u8 = @ptrCast(data.ptr.?);
    @memcpy(temp.ptr[0..data.size], source[0..data.size]);
    const list = self.frameList() orelse return false;
    const payload = &buf.native.d3d12;
    useState(list, payload.resource.?, &payload.state, k.state_copy_dest);
    sdk.copyBufferRegion(list, payload.resource, offset, temp.resource, 0, data.size);
    recorded_in_frame = true;
    return true;
}

/// Copies the initial data of all mip levels and slices of an image with one-shot uploads.
pub fn uploadImageOneShot(self: *Backend, img: *core.Image, desc: *const t.ImageDesc) bool {
    const is_3d = desc.type == .@"3d";
    const mips: usize = @intCast(desc.num_mipmaps);
    var total: usize = 0;
    var offsets: [16]usize = undefined;
    var plans: [16]Layout = undefined;
    for (0..mips) |m| {
        const mip: i32 = @intCast(m);
        const slices: usize = @intCast(if (is_3d) formats.mipDimension(desc.num_slices, mip) else desc.num_slices);
        const plan = layout(self, desc.pixel_format, formats.mipDimension(desc.width, mip), formats.mipDimension(desc.height, mip)) orelse return false;
        plans[m] = plan;
        total = alignUp(total, k.texture_data_placement_alignment);
        offsets[m] = total;
        total += plan.stride * slices;
    }
    const temp = TempUpload.create(self, total) orelse return false;
    var recorded_in_frame = false;
    defer temp.finish(self, recorded_in_frame);
    if (!self.reserveRelease()) return false;
    for (0..mips) |m| {
        const data = desc.data.mip_levels[m];
        const mip: i32 = @intCast(m);
        const plan = plans[m];
        const slices: usize = @intCast(if (is_3d) formats.mipDimension(desc.num_slices, mip) else desc.num_slices);
        const source: [*]const u8 = @ptrCast(data.ptr orelse break);
        const src_slice: usize = if (is_3d) @intCast(formats.surfacePitch(desc.pixel_format, formats.mipDimension(desc.width, mip), formats.mipDimension(desc.height, mip), 1)) else data.size / slices;
        repackRows(temp.ptr + offsets[m], source, plan.row_bytes, src_slice, plan.row_bytes, plan.rows, slices, plan.pitch, plan.stride);
    }
    const list = self.frameList() orelse return false;
    useState(list, img.native.d3d12.resource.?, &img.native.d3d12.state, k.state_copy_dest);
    for (0..mips) |m| {
        const mip: i32 = @intCast(m);
        const slices: u32 = @intCast(if (is_3d) formats.mipDimension(desc.num_slices, mip) else desc.num_slices);
        const footprints: Footprints = .{ .resource = temp.resource, .offset = offsets[m], .pitch = @intCast(plans[m].pitch), .stride = @intCast(plans[m].stride) };
        recordImageCopy(list, img, @intCast(m), 0, 0, 0, @intCast(formats.mipDimension(desc.width, mip)), @intCast(formats.mipDimension(desc.height, mip)), slices, footprints);
    }
    recorded_in_frame = true;
    return true;
}

/// Copies every footprint of `source` into the image. Each slice of the region is one
/// placed-footprint copy, to array slice `slice + s` or depth slice `slice + s` of a 3D image.
fn recordImageCopy(list: *sdk.Object, img: *core.Image, mip: u32, x: u32, y: u32, slice: u32, width: u32, height: u32, slices: u32, source: Footprints) void {
    const payload = &img.native.d3d12;
    useState(list, payload.resource.?, &payload.state, k.state_copy_dest);
    const is_3d = img.desc.type == .@"3d";
    const mip_count: u32 = @intCast(img.cmn.num_mipmaps);
    const format = convert.baseFormat(img.desc.pixel_format);
    for (0..slices) |s| {
        const index: u32 = @intCast(s);
        const dst: sdk.TextureCopyLocation = .{
            .resource = payload.resource,
            .type = k.texture_copy_subresource_index,
            .payload = .{ .subresource_index = if (is_3d) mip else mip + (slice + index) * mip_count },
        };
        const src: sdk.TextureCopyLocation = .{
            .resource = source.resource,
            .type = k.texture_copy_placed_footprint,
            .payload = .{ .placed = .{
                .offset = source.offset + index * source.stride,
                .footprint = .{ .format = format, .width = width, .height = height, .depth = 1, .row_pitch = source.pitch },
            } },
        };
        sdk.copyTextureRegion(list, &dst, x, y, if (is_3d) slice + index else 0, &src, null);
    }
}

/// Writes a region of CPU data into the image through the frame's upload ring.
pub fn writeImageTransient(self: *Backend, img: *core.Image, desc: *const t.WriteImageDesc, first_time_in_frame: bool) void {
    _ = first_time_in_frame;
    const list = self.frameList() orelse return;
    const plan = layout(self, img.desc.pixel_format, desc.size.width, desc.size.height) orelse return;
    const slices: usize = @intCast(desc.size.num_slices);
    const region = self.staging.alloc(plan.stride * slices, 512) orelse {
        core.logError(.d3d12_staging_overflow);
        return;
    };
    const source: [*]const u8 = @ptrCast(desc.src.data.ptr.?);
    repackRows(region.ptr, source + desc.src.offset, @intCast(desc.src.bytes_per_row), @intCast(desc.src.bytes_per_slice), plan.row_bytes, plan.rows, slices, plan.pitch, plan.stride);
    recordImageCopy(list, img, @intCast(desc.dst.mip_level), @intCast(desc.dst.x), @intCast(desc.dst.y), @intCast(desc.dst.slice), @intCast(desc.size.width), @intCast(desc.size.height), @intCast(slices), .{ .resource = region.resource, .offset = region.offset, .pitch = @intCast(plan.pitch), .stride = @intCast(plan.stride) });
}

pub fn writeBufferTransient(self: *Backend, buf: *core.Buffer, desc: *const t.WriteBufferDesc, first_time_in_frame: bool) void {
    _ = first_time_in_frame;
    const payload = &buf.native.d3d12;
    const source: [*]const u8 = @ptrCast(desc.src.data.ptr.?);
    if (payload.staging) |data| {
        @memcpy(data[desc.dst.offset..][0..desc.size], source[desc.src.offset..][0..desc.size]);
        return;
    }
    const list = self.frameList() orelse return;
    const region = self.staging.alloc(desc.size, 16) orelse {
        core.logError(.d3d12_staging_overflow);
        return;
    };
    @memcpy(region.ptr[0..desc.size], source[desc.src.offset..][0..desc.size]);
    useState(list, payload.resource.?, &payload.state, k.state_copy_dest);
    sdk.copyBufferRegion(list, payload.resource, desc.dst.offset, region.resource, region.offset, desc.size);
}

/// Writes CPU data into an image with a one-shot upload, before the image is used by the GPU.
pub fn writeImageUnsealed(self: *Backend, img: *core.Image, desc: *const t.WriteImageDesc) void {
    const plan = layout(self, img.desc.pixel_format, desc.size.width, desc.size.height) orelse return;
    const slices: usize = @intCast(desc.size.num_slices);
    const temp = TempUpload.create(self, plan.stride * slices) orelse return;
    var recorded_in_frame = false;
    defer temp.finish(self, recorded_in_frame);
    if (!self.reserveRelease()) return;
    const source: [*]const u8 = @ptrCast(desc.src.data.ptr.?);
    repackRows(temp.ptr, source + desc.src.offset, @intCast(desc.src.bytes_per_row), @intCast(desc.src.bytes_per_slice), plan.row_bytes, plan.rows, slices, plan.pitch, plan.stride);
    const list = self.frameList() orelse return;
    recordImageCopy(list, img, @intCast(desc.dst.mip_level), @intCast(desc.dst.x), @intCast(desc.dst.y), @intCast(desc.dst.slice), @intCast(desc.size.width), @intCast(desc.size.height), @intCast(slices), .{ .resource = temp.resource, .offset = 0, .pitch = @intCast(plan.pitch), .stride = @intCast(plan.stride) });
    recorded_in_frame = true;
}

pub fn writeBufferUnsealed(self: *Backend, buf: *core.Buffer, desc: *const t.WriteBufferDesc) void {
    const payload = &buf.native.d3d12;
    const source: [*]const u8 = @ptrCast(desc.src.data.ptr.?);
    if (payload.staging) |data| {
        @memcpy(data[desc.dst.offset..][0..desc.size], source[desc.src.offset..][0..desc.size]);
        return;
    }
    const range: t.Range = .{ .ptr = source + desc.src.offset, .size = desc.size };
    _ = uploadBufferOneShot(self, buf, desc.dst.offset, &range);
}

pub fn sealBuffer(self: *Backend, buf: *core.Buffer) void {
    _ = .{ self, buf };
}

pub fn sealImage(self: *Backend, img: *core.Image) void {
    _ = .{ self, img };
}

pub fn copyBufferToBuffer(self: *Backend, src: *core.Buffer, dst: *core.Buffer, desc: *const t.CopyBufferToBufferDesc) void {
    if (dst.native.d3d12.staging) |data| {
        // GPU data copied into CPU-backed staging memory is read back first
        if (src.native.d3d12.staging) |source| {
            @memcpy(data[desc.dst.offset..][0..desc.size], source[desc.src.offset..][0..desc.size]);
        } else _ = readBuffer(self, src, desc.src.offset, data[desc.dst.offset..][0..desc.size]);
        return;
    }
    const list = self.frameList() orelse return;
    const dst_payload = &dst.native.d3d12;
    if (src.native.d3d12.staging) |data| {
        const region = self.staging.alloc(desc.size, 16) orelse {
            core.logError(.d3d12_staging_overflow);
            return;
        };
        @memcpy(region.ptr[0..desc.size], data[desc.src.offset..][0..desc.size]);
        useState(list, dst_payload.resource.?, &dst_payload.state, k.state_copy_dest);
        sdk.copyBufferRegion(list, dst_payload.resource, desc.dst.offset, region.resource, region.offset, desc.size);
        return;
    }
    const src_payload = &src.native.d3d12;
    useState(list, src_payload.resource.?, &src_payload.state, k.state_copy_source);
    useState(list, dst_payload.resource.?, &dst_payload.state, k.state_copy_dest);
    sdk.copyBufferRegion(list, dst_payload.resource, desc.dst.offset, src_payload.resource, desc.src.offset, desc.size);
}

pub fn copyBufferToImage(self: *Backend, src: *core.Buffer, dst: *core.Image, desc: *const t.CopyBufferToImageDesc) void {
    const list = self.frameList() orelse return;
    const plan = layout(self, dst.desc.pixel_format, desc.size.width, desc.size.height) orelse return;
    const slices: usize = @intCast(desc.size.num_slices);
    const mip: u32 = @intCast(desc.dst.mip_level);
    const x: u32 = @intCast(desc.dst.x);
    const y: u32 = @intCast(desc.dst.y);
    const slice: u32 = @intCast(desc.dst.slice);
    const width: u32 = @intCast(desc.size.width);
    const height: u32 = @intCast(desc.size.height);
    if (src.native.d3d12.staging) |data| {
        // CPU data is repacked into the upload ring with the footprint layout
        const region = self.staging.alloc(plan.stride * slices, 512) orelse {
            core.logError(.d3d12_staging_overflow);
            return;
        };
        repackRows(region.ptr, data.ptr + desc.src.offset, @intCast(desc.src.bytes_per_row), @intCast(desc.src.bytes_per_slice), plan.row_bytes, plan.rows, slices, plan.pitch, plan.stride);
        recordImageCopy(list, dst, mip, x, y, slice, width, height, @intCast(slices), .{ .resource = region.resource, .offset = region.offset, .pitch = @intCast(plan.pitch), .stride = @intCast(plan.stride) });
        return;
    }
    const src_payload = &src.native.d3d12;
    useState(list, src_payload.resource.?, &src_payload.state, k.state_copy_source);
    const pitch: u32 = @intCast(desc.src.bytes_per_row);
    const stride: u64 = @intCast(desc.src.bytes_per_slice);
    // GPU sources need 512-byte aligned slice offsets; otherwise each slice moves into a temporary buffer
    if (desc.src.offset % k.texture_data_placement_alignment == 0 and (slices == 1 or stride % k.texture_data_placement_alignment == 0)) {
        recordImageCopy(list, dst, mip, x, y, slice, width, height, @intCast(slices), .{ .resource = src_payload.resource.?, .offset = desc.src.offset, .pitch = pitch, .stride = stride });
        return;
    }
    const temp_stride: u64 = @intCast(alignUp(@as(usize, pitch) * plan.rows, k.texture_data_placement_alignment));
    if (!self.reserveRelease()) {
        core.logError(.d3d12_create_temp_buffer_failed);
        return;
    }
    const temp_desc = memory.bufferDesc(@intCast(temp_stride * slices), 0);
    const heap: sdk.HeapProperties = .{ .type = k.heap_default };
    var temp: ?*sdk.Object = null;
    if (sdk.createCommittedResource(self.device, &heap, k.heap_flag_none, &temp_desc, k.state_copy_dest, &temp) < 0 or temp == null) {
        core.logError(.d3d12_create_temp_buffer_failed);
        return;
    }
    const copy_bytes = @as(u64, pitch) * @as(u64, @intCast(plan.rows));
    for (0..slices) |s| {
        sdk.copyBufferRegion(list, temp, @as(u64, s) * temp_stride, src_payload.resource, @as(u64, @intCast(desc.src.offset)) + @as(u64, s) * stride, copy_bytes);
    }
    barrier(list, temp.?, k.state_copy_dest, k.state_copy_source);
    recordImageCopy(list, dst, mip, x, y, slice, width, height, @intCast(slices), .{ .resource = temp.?, .offset = 0, .pitch = pitch, .stride = temp_stride });
    self.releaseLater(temp);
}

pub fn pushDebugGroup(self: *Backend, name: [*:0]const u8) void {
    if (!config.debug) return;
    if (!self.frame_open) return;
    sdk.listBeginEvent(self.frames[self.frame_slot].list.?, 1, name);
}

pub fn popDebugGroup(self: *Backend) void {
    if (!config.debug) return;
    if (!self.frame_open) return;
    sdk.listEndEvent(self.frames[self.frame_slot].list.?);
}

// ---------------------------------------------------------------- readback (zicr extension)

fn createReadback(self: *Backend, size: usize) ?*sdk.Object {
    const heap: sdk.HeapProperties = .{ .type = k.heap_readback };
    const desc = memory.bufferDesc(size, 0);
    var resource: ?*sdk.Object = null;
    if (sdk.createCommittedResource(self.device, &heap, k.heap_flag_none, &desc, k.state_copy_dest, &resource) < 0 or resource == null) {
        core.logError(.d3d12_readback_failed);
        return null;
    }
    return resource;
}

/// Readback (zicr extension): submits the frame, waits for it, and copies buffer bytes into `out`.
pub fn readBuffer(self: *Backend, buf: *core.Buffer, offset: usize, out: []u8) bool {
    const payload = &buf.native.d3d12;
    if (payload.staging) |data| {
        @memcpy(out, data[offset..][0..out.len]);
        return true;
    }
    self.submitFrame();
    const readback = createReadback(self, out.len) orelse return false;
    defer sdk.release(readback);
    const list = self.beginOneShot() orelse return false;
    useState(list, payload.resource.?, &payload.state, k.state_copy_source);
    sdk.copyBufferRegion(list, readback, 0, payload.resource, offset, out.len);
    self.endOneShot();
    var mapped: ?*anyopaque = null;
    if (sdk.resourceMap(readback, 0, &mapped) < 0 or mapped == null) return false;
    defer sdk.resourceUnmap(readback, 0);
    const source: [*]const u8 = @ptrCast(mapped.?);
    @memcpy(out, source[0..out.len]);
    return true;
}

/// Readback (zicr extension): submits the frame, waits for it, and copies an image region into `out`.
pub fn readImage(self: *Backend, img: *core.Image, region: *const core.ReadRegion, out: []u8) bool {
    self.submitFrame();
    const plan = layout(self, img.desc.pixel_format, @intCast(region.width), @intCast(region.height)) orelse return false;
    const slices: usize = region.num_slices;
    const readback = createReadback(self, plan.stride * slices) orelse return false;
    defer sdk.release(readback);
    const list = self.beginOneShot() orelse return false;
    const payload = &img.native.d3d12;
    useState(list, payload.resource.?, &payload.state, k.state_copy_source);
    const is_3d = img.desc.type == .@"3d";
    const mip_count: u32 = @intCast(img.cmn.num_mipmaps);
    const format = convert.baseFormat(img.desc.pixel_format);
    for (0..slices) |s| {
        const index: u32 = @intCast(s);
        const dst: sdk.TextureCopyLocation = .{
            .resource = readback,
            .type = k.texture_copy_placed_footprint,
            .payload = .{ .placed = .{ .offset = @as(u64, s) * @as(u64, @intCast(plan.stride)), .footprint = .{ .format = format, .width = @intCast(region.width), .height = @intCast(region.height), .depth = 1, .row_pitch = @intCast(plan.pitch) } } },
        };
        const src: sdk.TextureCopyLocation = .{
            .resource = payload.resource,
            .type = k.texture_copy_subresource_index,
            .payload = .{ .subresource_index = if (is_3d) region.mip_level else region.mip_level + (region.slice + index) * mip_count },
        };
        const z = if (is_3d) region.slice + index else 0;
        const box: sdk.Box = .{
            .left = region.x,
            .top = region.y,
            .front = z,
            .right = region.x + region.width,
            .bottom = region.y + region.height,
            .back = z + 1,
        };
        sdk.copyTextureRegion(list, &dst, 0, 0, 0, &src, &box);
    }
    self.endOneShot();
    var mapped: ?*anyopaque = null;
    if (sdk.resourceMap(readback, 0, &mapped) < 0 or mapped == null) return false;
    defer sdk.resourceUnmap(readback, 0);
    const source: [*]const u8 = @ptrCast(mapped.?);
    for (0..slices) |s| for (0..plan.rows) |y| {
        @memcpy(out[s * region.bytes_per_slice + y * region.bytes_per_row ..][0..plan.row_bytes], source[s * plan.stride + y * plan.pitch ..][0..plan.row_bytes]);
    };
    return true;
}

/// Readback copies have dedicated command objects/fences. They never reset the
/// frame or upload command allocator, and request/poll do not wait for the GPU.
const NativeRead = struct {
    task: @import("../../readback_task.zig").Task,
    backend: *Backend,
    buffer: ?*sdk.Object = null,
    allocator: ?*sdk.Object = null,
    list: ?*sdk.Object = null,
    fence: ?*sdk.Object = null,
    event: sdk.Handle = null,
    row_bytes: usize = 0,
    rows: usize = 1,
    slices: usize = 1,
    source_pitch: usize = 0,
    source_stride: usize = 0,
    target_row: usize = 0,
    target_slice: usize = 0,
    fn create(backend: *Backend, size: usize, out: []u8) ?*NativeRead {
        const self = backend.allocator.create(NativeRead) catch return null;
        self.* = .{ .task = .{ .owner = core.state(), .allocator = backend.allocator, .data = out, .poll_fn = poll, .destroy_fn = destroy }, .backend = backend };
        var success = false;
        defer if (!success) self.destroyResources();
        self.buffer = createReadback(backend, size) orelse return null;
        if (sdk.createCommandAllocator(backend.device, k.command_list_type_direct, &self.allocator) < 0 or self.allocator == null) return null;
        if (sdk.createCommandList(backend.device, k.command_list_type_direct, self.allocator.?, &self.list) < 0 or self.list == null) return null;
        if (sdk.createFence(backend.device, 0, &self.fence) < 0 or self.fence == null) return null;
        success = true;
        return self;
    }
    fn submit(self: *NativeRead) bool {
        if (sdk.listClose(self.list.?) < 0) return false;
        var lists = [_]?*sdk.Object{self.list};
        core.statsInc("d3d12.num_queue_submits");
        sdk.queueExecuteCommandLists(self.backend.queue, 1, &lists);
        const result = sdk.queueSignal(self.backend.queue, self.fence.?, 1);
        if (result < 0) {
            const removed = sdk.getDeviceRemovedReason(self.backend.device);
            // A healthy queue which cannot signal provides no safe completion
            // proof. Never free possibly live GPU objects on that fatal path.
            if (removed >= 0) @panic("D3D12 queue cannot signal completion without device removal");
            core.recordLoss(removed);
            return false;
        }
        return true;
    }
    fn poll(task: *@import("../../readback_task.zig").Task, wait: bool) error{ReadFailed}!bool {
        const self: *NativeRead = @alignCast(@fieldParentPtr("task", task));
        var completed = sdk.fenceCompletedValue(self.fence.?);
        if (completed == std.math.maxInt(u64)) {
            core.recordLoss(sdk.getDeviceRemovedReason(self.backend.device));
            return error.ReadFailed;
        }
        if (completed < 1 and wait) {
            self.event = sdk.createEvent();
            memory.waitFence(self.fence.?, self.event, 1);
            completed = sdk.fenceCompletedValue(self.fence.?);
        }
        if (completed == std.math.maxInt(u64)) {
            core.recordLoss(sdk.getDeviceRemovedReason(self.backend.device));
            return error.ReadFailed;
        }
        if (completed < 1) return false;
        if (task.refs == 1) return true;
        var mapped: ?*anyopaque = null;
        if (sdk.resourceMap(self.buffer.?, 0, &mapped) < 0 or mapped == null) return error.ReadFailed;
        defer sdk.resourceUnmap(self.buffer.?, 0);
        const source: [*]const u8 = @ptrCast(mapped.?);
        if (self.row_bytes == 0) {
            @memcpy(task.data, source[0..task.data.len]);
        } else for (0..self.slices) |slice| for (0..self.rows) |row| {
            const from = slice * self.source_stride + row * self.source_pitch;
            const to = slice * self.target_slice + row * self.target_row;
            @memcpy(task.data[to..][0..self.row_bytes], source[from..][0..self.row_bytes]);
        };
        return true;
    }
    fn destroyResources(self: *NativeRead) void {
        sdk.release(self.list);
        sdk.release(self.allocator);
        sdk.release(self.buffer);
        sdk.release(self.fence);
        if (self.event) |event| sdk.closeEvent(event);
        self.task.allocator.destroy(self);
    }
    fn destroy(task: *@import("../../readback_task.zig").Task) void {
        const self: *NativeRead = @alignCast(@fieldParentPtr("task", task));
        task.allocator.free(task.data);
        self.destroyResources();
    }
};
pub fn requestBufferRead(self: *Backend, buffer: *core.Buffer, offset: usize, out: []u8) ?*@import("../../readback_task.zig").Task {
    self.submitFrame();
    const read = NativeRead.create(self, out.len, out) orelse return null;
    var success = false;
    defer if (!success) read.destroyResources();
    const payload = &buffer.native.d3d12;
    useState(read.list.?, payload.resource.?, &payload.state, k.state_copy_source);
    sdk.copyBufferRegion(read.list.?, read.buffer, 0, payload.resource, offset, out.len);
    if (!read.submit()) return null;
    success = true;
    return &read.task;
}
pub fn requestImageRead(self: *Backend, image: *core.Image, region: *const core.ReadRegion, out: []u8) ?*@import("../../readback_task.zig").Task {
    self.submitFrame();
    const plan = layout(self, image.desc.pixel_format, @intCast(region.width), @intCast(region.height)) orelse return null;
    const read = NativeRead.create(self, plan.stride * region.num_slices, out) orelse return null;
    var success = false;
    defer if (!success) read.destroyResources();
    read.row_bytes = plan.row_bytes;
    read.rows = region.height;
    read.slices = region.num_slices;
    read.source_pitch = plan.pitch;
    read.source_stride = plan.stride;
    read.target_row = region.bytes_per_row;
    read.target_slice = region.bytes_per_slice;
    const payload = &image.native.d3d12;
    useState(read.list.?, payload.resource.?, &payload.state, k.state_copy_source);
    const is3d = image.desc.type == .@"3d";
    for (0..region.num_slices) |slice| {
        const dst: sdk.TextureCopyLocation = .{ .resource = read.buffer, .type = k.texture_copy_placed_footprint, .payload = .{ .placed = .{ .offset = slice * plan.stride, .footprint = .{ .format = convert.baseFormat(image.desc.pixel_format), .width = region.width, .height = region.height, .depth = 1, .row_pitch = @intCast(plan.pitch) } } } };
        const src: sdk.TextureCopyLocation = .{ .resource = payload.resource, .type = k.texture_copy_subresource_index, .payload = .{ .subresource_index = if (is3d) region.mip_level else region.mip_level + (region.slice + @as(u32, @intCast(slice))) * @as(u32, @intCast(image.cmn.num_mipmaps)) } };
        const z: u32 = if (is3d) region.slice + @as(u32, @intCast(slice)) else 0;
        const box: sdk.Box = .{ .left = region.x, .top = region.y, .front = z, .right = region.x + region.width, .bottom = region.y + region.height, .back = z + 1 };
        sdk.copyTextureRegion(read.list.?, &dst, 0, 0, 0, &src, &box);
    }
    if (!read.submit()) return null;
    success = true;
    return &read.task;
}
