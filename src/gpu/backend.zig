//! Backend dispatch, the counterpart of the "generic backend" section in
//! sokol_gfx.h:24132-24741. The original selects one backend at compile time;
//! this port selects it in setup() and dispatches over a tagged union.
const std = @import("std");
const t = @import("types.zig");
const e = @import("enums.zig");
const core = @import("core.zig");

const GlBackend = @import("backends/gl/backend.zig").Backend;
const gl_res = @import("backends/gl/resources.zig");
const GlWin32Loader = @import("backends/gl/win32_loader.zig");
const D3d11Backend = @import("backends/d3d11/backend.zig").Backend;
const d3d11_res = @import("backends/d3d11/resources.zig");
const VulkanBackend = @import("backends/vulkan/backend.zig").Backend;
const WgpuBackend = @import("backends/wgpu/backend.zig").Backend;
const MetalBackend = @import("backends/metal/backend.zig").Backend;
const D3d12Backend = @import("backends/d3d12/backend.zig").Backend;
const dummy = @import("backends/dummy.zig");

pub const Impl = union(enum) {
    dummy: void,
    gl: GlBackend,
    d3d11: D3d11Backend,
    // These backends implement the backend contract of backends/CONTRACT.md
    // directly on the shared resource types.
    vulkan: VulkanBackend,
    wgpu: WgpuBackend,
    metal: MetalBackend,
    d3d12: D3d12Backend,
};

fn impl() *Impl {
    return &core.state().impl;
}

fn resourceState(ok: bool) e.ResourceState {
    return if (ok) .valid else .failed;
}

pub const SetupError = error{
    BackendNotPorted,
    MissingGlProcAddress,
    MissingD3d11Device,
    MissingD3d11Context,
    UnsupportedOpenGlVersion,
    OpenGlResourceCreationFailed,
    MissingOpenGlFunction,
    MissingVulkanLoader,
    MissingVulkanDevice,
    MissingVulkanExtension,
    VulkanInitFailed,
    MissingWgpuDevice,
    MissingWgpuProcAddress,
    WgpuInitFailed,
    MissingMetalDevice,
    MetalNotAvailable,
    MetalInitFailed,
    MissingD3d12Device,
    D3d12InitFailed,
} || std.mem.Allocator.Error;

/// Creates the backend, and fills in features, limits and pixel format caps.
pub fn setup(s: *core.State) !void {
    switch (s.backend) {
        .dummy => {
            dummy.setup(s);
            s.impl = .dummy;
        },
        .glcore, .gles3 => {
            const env = s.desc.environment.gl;
            var loader = env.get_proc_address;
            var user_data = env.user_data;
            if (comptime GlWin32Loader.available) if (loader == null and s.backend == .glcore) {
                // like _SOKOL_USE_WIN32_GL_LOADER: resolve through opengl32.dll
                s.gl_loader = GlWin32Loader.Loader.open() catch return error.MissingOpenGlFunction;
                loader = GlWin32Loader.Loader.getProcAddress;
                user_data = &s.gl_loader.?;
            };
            errdefer closeWin32GlLoader();
            const gl = try GlBackend.init(s.allocator, s.backend, loader orelse return error.MissingGlProcAddress, user_data, s.desc.logger);
            s.impl = .{ .gl = gl };
            s.features = gl.cache.features;
            s.limits = gl.cache.limits;
            for (&s.formats, 0..) |*info, i| info.* = gl.format_info[i];
        },
        .d3d11 => {
            const dx = try D3d11Backend.init(s.allocator, s.desc, null);
            s.impl = .{ .d3d11 = dx };
            s.features = dx.features;
            s.limits = dx.limits;
            for (&s.formats, 0..) |*info, i| info.* = dx.format_info[i];
        },
        .vulkan => s.impl = .{ .vulkan = try VulkanBackend.init(s) },
        .wgpu => s.impl = .{ .wgpu = try WgpuBackend.init(s) },
        .metal_ios, .metal_macos, .metal_simulator => s.impl = .{ .metal = try MetalBackend.init(s) },
        .d3d12 => s.impl = .{ .d3d12 = try D3d12Backend.init(s) },
        else => return error.BackendNotPorted,
    }
}

/// The opengl32.dll loader must outlive the GL function pointers it resolved.
fn closeWin32GlLoader() void {
    if (core.state().gl_loader) |*loader| loader.close();
    core.state().gl_loader = null;
}

pub fn discard() void {
    switch (impl().*) {
        inline .vulkan, .wgpu, .metal, .d3d12 => |*b| b.deinit(),
        .dummy => {},
        .gl => |*gl| {
            gl.deinit();
            closeWin32GlLoader();
        },
        .d3d11 => |*dx| dx.deinit(),
    }
    impl().* = .dummy;
}

/// Explicit polling for APIs which expose a removal status after device creation.
pub fn pollDeviceLoss() void {
    switch (impl().*) {
        .d3d12 => |*dx| {
            const code = @import("backends/d3d12/sdk.zig").getDeviceRemovedReason(dx.device);
            if (code < 0) core.recordLoss(code);
        },
        .d3d11 => |*dx| {
            const code = @import("backends/d3d11/sdk.zig").getDeviceRemovedReason(dx.device);
            if (code < 0) core.recordLoss(code);
        },
        else => {}, // Vulkan reports VkResult; GL/WebGPU loss events are host-owned.
    }
}

pub fn resetStateCache() void {
    switch (impl().*) {
        inline .vulkan, .wgpu, .metal, .d3d12 => |*b| b.resetStateCache(),
        .dummy, .d3d11 => {},
        .gl => |*gl| gl.cache.reset(gl.vao, gl.gles),
    }
}

/// Copies backend-maintained frame statistics into the shared statistics.
pub fn collectStats(frame: *t.FrameStats) void {
    switch (impl().*) {
        .vulkan, .wgpu, .metal, .d3d12 => {},
        .dummy => {},
        .gl => |*gl| frame.gl = gl.cache.stats,
        .d3d11 => |*dx| frame.d3d11 = dx.stats,
    }
}

pub fn resetStats() void {
    switch (impl().*) {
        .vulkan, .wgpu, .metal, .d3d12 => {},
        .dummy => {},
        .gl => |*gl| gl.cache.stats = .{},
        .d3d11 => |*dx| dx.stats = .{},
    }
}

pub fn setStatsEnabled(enabled: bool) void {
    switch (impl().*) {
        .vulkan, .wgpu, .metal, .d3d12 => {},
        .dummy => {},
        .gl => |*gl| gl.cache.stats_enabled = enabled,
        .d3d11 => |*dx| dx.stats_enabled = enabled,
    }
}

// ---------------------------------------------------------------- resources

pub fn createBuffer(buf: *core.Buffer, desc: *const t.BufferDesc) e.ResourceState {
    return switch (impl().*) {
        inline .vulkan, .wgpu, .metal, .d3d12 => |*b| b.createBuffer(buf, desc),
        .dummy => .valid,
        .gl => |*gl| blk: {
            buf.native = .{ .gl = .{} };
            break :blk resourceState(gl.createBuffer(&buf.native.gl, desc.*));
        },
        .d3d11 => |*dx| blk: {
            buf.native = .{ .d3d11 = .{} };
            break :blk resourceState(dx.createBuffer(&buf.native.d3d11, desc.*));
        },
    };
}

pub fn discardBuffer(buf: *core.Buffer) void {
    switch (impl().*) {
        inline .vulkan, .wgpu, .metal, .d3d12 => |*b| b.discardBuffer(buf),
        .dummy => {},
        .gl => |*gl| if (buf.native == .gl) gl.discardBuffer(&buf.native.gl),
        .d3d11 => |*dx| if (buf.native == .d3d11) dx.discardBuffer(&buf.native.d3d11),
    }
}

pub fn createImage(img: *core.Image, desc: *const t.ImageDesc) e.ResourceState {
    return switch (impl().*) {
        inline .vulkan, .wgpu, .metal, .d3d12 => |*b| b.createImage(img, desc),
        .dummy => .valid,
        .gl => |*gl| blk: {
            img.native = .{ .gl = .{} };
            break :blk resourceState(gl.createImage(&img.native.gl, desc.*));
        },
        .d3d11 => |*dx| blk: {
            img.native = .{ .d3d11 = .{} };
            break :blk resourceState(dx.createImage(&img.native.d3d11, desc.*));
        },
    };
}

pub fn discardImage(img: *core.Image) void {
    switch (impl().*) {
        inline .vulkan, .wgpu, .metal, .d3d12 => |*b| b.discardImage(img),
        .dummy => {},
        .gl => |*gl| if (img.native == .gl) gl.discardImage(&img.native.gl),
        .d3d11 => |*dx| if (img.native == .d3d11) dx.discardImage(&img.native.d3d11),
    }
}

pub fn createSampler(smp: *core.Sampler, desc: *const t.SamplerDesc) e.ResourceState {
    return switch (impl().*) {
        inline .vulkan, .wgpu, .metal, .d3d12 => |*b| b.createSampler(smp, desc),
        .dummy => .valid,
        .gl => |*gl| blk: {
            smp.native = .{ .gl = .{} };
            break :blk resourceState(gl.createSampler(&smp.native.gl, desc.*));
        },
        .d3d11 => |*dx| blk: {
            smp.native = .{ .d3d11 = .{} };
            break :blk resourceState(dx.createSampler(&smp.native.d3d11, desc.*));
        },
    };
}

pub fn discardSampler(smp: *core.Sampler) void {
    switch (impl().*) {
        inline .vulkan, .wgpu, .metal, .d3d12 => |*b| b.discardSampler(smp),
        .dummy => {},
        .gl => |*gl| if (smp.native == .gl) gl.discardSampler(&smp.native.gl),
        .d3d11 => |*dx| if (smp.native == .d3d11) dx.discardSampler(&smp.native.d3d11),
    }
}

pub fn createShader(shd: *core.Shader, desc: *const t.ShaderDesc) e.ResourceState {
    return switch (impl().*) {
        inline .vulkan, .wgpu, .metal, .d3d12 => |*b| b.createShader(shd, desc),
        .dummy => .valid,
        .gl => |*gl| blk: {
            shd.native = .{ .gl = .{} };
            break :blk resourceState(gl.createShader(&shd.native.gl, desc.*));
        },
        .d3d11 => |*dx| blk: {
            shd.native = .{ .d3d11 = .{} };
            break :blk resourceState(dx.createShader(&shd.native.d3d11, desc.*));
        },
    };
}

pub fn discardShader(shd: *core.Shader) void {
    switch (impl().*) {
        inline .vulkan, .wgpu, .metal, .d3d12 => |*b| b.discardShader(shd),
        .dummy => {},
        .gl => |*gl| if (shd.native == .gl) gl.discardShader(&shd.native.gl),
        .d3d11 => |*dx| if (shd.native == .d3d11) dx.discardShader(&shd.native.d3d11),
    }
}

pub fn createPipeline(pip: *core.Pipeline, desc: *const t.PipelineDesc) e.ResourceState {
    const shd = pip.cmn.shader.get();
    return switch (impl().*) {
        inline .vulkan, .wgpu, .metal, .d3d12 => |*b| b.createPipeline(pip, desc),
        .dummy => .valid,
        .gl => |*gl| blk: {
            pip.native = .{ .gl = .{} };
            break :blk resourceState(gl.createPipeline(&pip.native.gl, &shd.native.gl, desc.*));
        },
        .d3d11 => |*dx| blk: {
            pip.native = .{ .d3d11 = .{} };
            break :blk resourceState(dx.createPipeline(&pip.native.d3d11, &shd.native.d3d11, desc.*));
        },
    };
}

pub fn discardPipeline(pip: *core.Pipeline) void {
    switch (impl().*) {
        inline .vulkan, .wgpu, .metal, .d3d12 => |*b| b.discardPipeline(pip),
        .dummy => {},
        .gl => |*gl| gl.cache.invalidatePipeline(slotInfo(&pip.slot)),
        .d3d11 => |*dx| if (pip.native == .d3d11) dx.discardPipeline(&pip.native.d3d11),
    }
}

/// `view.desc` already holds the descriptor with resolved mip and slice counts.
pub fn createView(view: *core.View, desc: *const t.ViewDesc) e.ResourceState {
    const img = view.cmn.img.ref.ptr;
    const buf = view.cmn.buf.ref.ptr;
    return switch (impl().*) {
        inline .vulkan, .wgpu, .metal, .d3d12 => |*b| b.createView(view, desc),
        .dummy => .valid,
        .gl => |*gl| blk: {
            view.native = .{ .gl = .{} };
            const img_native = if (img) |i| &i.native.gl else null;
            break :blk resourceState(gl.createView(&view.native.gl, view.desc, img_native, if (img) |i| i.desc else .{}));
        },
        .d3d11 => |*dx| blk: {
            view.native = .{ .d3d11 = .{} };
            const buf_native = if (buf) |b| &b.native.d3d11 else null;
            const img_native = if (img) |i| &i.native.d3d11 else null;
            break :blk resourceState(dx.createView(&view.native.d3d11, view.desc, buf_native, if (buf) |b| b.desc else .{}, img_native, if (img) |i| i.desc else .{}));
        },
    };
}

pub fn discardView(view: *core.View) void {
    switch (impl().*) {
        inline .vulkan, .wgpu, .metal, .d3d12 => |*b| b.discardView(view),
        .dummy => {},
        .gl => |*gl| if (view.native == .gl) gl.discardView(&view.native.gl),
        .d3d11 => |*dx| if (view.native == .d3d11) dx.discardView(&view.native.d3d11),
    }
}

// ---------------------------------------------------------------- passes and commands

/// Returns false if the backend could not start the pass, which makes the
/// following commands in the pass no-ops.
pub fn beginPass(pass: *const t.Pass, atts: *const core.AttachmentsPtrs) bool {
    return switch (impl().*) {
        inline .vulkan, .wgpu, .metal, .d3d12 => |*b| b.beginPass(pass, atts),
        .dummy => true,
        .gl => |*gl| gl.beginPass(pass.*, &nativeAttachments(gl_res, .gl, atts)),
        .d3d11 => |*dx| dx.beginPass(pass.*, &nativeAttachments(d3d11_res, .d3d11, atts)),
    };
}

pub fn endPass(atts: *const core.AttachmentsPtrs) void {
    const cur_pass = &core.state().cur_pass;
    const pass: t.Pass = .{ .compute = cur_pass.is_compute, .action = cur_pass.action };
    switch (impl().*) {
        inline .vulkan, .wgpu, .metal, .d3d12 => |*b| b.endPass(atts),
        .dummy => {},
        .gl => |*gl| gl.endPass(pass, &nativeAttachments(gl_res, .gl, atts)),
        .d3d11 => |*dx| dx.endPass(pass, &nativeAttachments(d3d11_res, .d3d11, atts)),
    }
}

pub fn applyViewport(x: i32, y: i32, w: i32, h: i32, origin_top_left: bool) void {
    const height = core.state().cur_pass.dim.height;
    switch (impl().*) {
        inline .vulkan, .wgpu, .metal, .d3d12 => |*b| b.applyViewport(x, y, w, h, origin_top_left),
        .dummy => {},
        .gl => |*gl| gl.viewport(height, x, y, w, h, origin_top_left),
        .d3d11 => |*dx| dx.viewport(height, x, y, w, h, origin_top_left),
    }
}

pub fn applyScissorRect(x: i32, y: i32, w: i32, h: i32, origin_top_left: bool) void {
    const height = core.state().cur_pass.dim.height;
    switch (impl().*) {
        inline .vulkan, .wgpu, .metal, .d3d12 => |*b| b.applyScissorRect(x, y, w, h, origin_top_left),
        .dummy => {},
        .gl => |*gl| gl.scissor(height, x, y, w, h, origin_top_left),
        .d3d11 => |*dx| dx.scissor(height, x, y, w, h, origin_top_left),
    }
}

pub fn applyPipeline(pip: *core.Pipeline) void {
    const shd = pip.cmn.shader.get();
    switch (impl().*) {
        inline .vulkan, .wgpu, .metal, .d3d12 => |*b| b.applyPipeline(pip),
        .dummy => {},
        .gl => |*gl| gl.applyPipeline(.{ .resource = &pip.native.gl, .desc = &pip.desc, .slot = slotInfo(&pip.slot) }, &shd.native.gl),
        .d3d11 => |*dx| dx.applyPipeline(.{ .resource = &pip.native.d3d11, .desc = &pip.desc, .slot = slotInfo(&pip.slot) }, &shd.native.d3d11),
    }
}

pub fn applyBindings(bnd: *const core.BindingsPtrs) bool {
    return switch (impl().*) {
        inline .vulkan, .wgpu, .metal, .d3d12 => |*b| b.applyBindings(bnd),
        .dummy => true,
        .gl => |*gl| blk: {
            var native: gl_res.Bindings = undefined;
            nativeBindings(gl_res, .gl, bnd, &native);
            break :blk gl.applyBindings(&native);
        },
        .d3d11 => |*dx| blk: {
            var native: d3d11_res.Bindings = undefined;
            nativeBindings(d3d11_res, .d3d11, bnd, &native);
            break :blk dx.applyBindings(&native);
        },
    };
}

pub fn applyUniforms(ub_slot: usize, data: *const t.Range) void {
    const shd = core.state().cur_pip.get().cmn.shader.get();
    switch (impl().*) {
        inline .vulkan, .wgpu, .metal, .d3d12 => |*b| b.applyUniforms(ub_slot, data),
        .dummy => {},
        .gl => |*gl| gl.applyUniforms(&shd.native.gl, ub_slot, data.*),
        .d3d11 => |*dx| dx.applyUniforms(&shd.native.d3d11, ub_slot, data.*),
    }
}

pub fn draw(base_element: i32, num_elements: i32, num_instances: i32, base_vertex: i32, base_instance: i32) void {
    const s = core.state();
    switch (impl().*) {
        inline .vulkan, .wgpu, .metal, .d3d12 => |*b| b.draw(base_element, num_elements, num_instances, base_vertex, base_instance),
        .dummy => {},
        .gl => |*gl| gl.draw(s.use_instanced_draw, base_element, num_elements, num_instances, base_vertex, base_instance),
        .d3d11 => |*dx| dx.draw(s.use_indexed_draw, s.use_instanced_draw, base_element, num_elements, num_instances, base_vertex, base_instance),
    }
}

pub fn dispatch(x: i32, y: i32, z: i32) void {
    switch (impl().*) {
        inline .vulkan, .wgpu, .metal, .d3d12 => |*b| b.dispatch(x, y, z),
        .dummy => {},
        .gl => |*gl| gl.dispatch(x, y, z),
        .d3d11 => |*dx| dx.dispatch(x, y, z),
    }
}

pub fn commit() void {
    switch (impl().*) {
        inline .vulkan, .wgpu, .metal, .d3d12 => |*b| b.commit(),
        .dummy, .d3d11 => {},
        .gl => |*gl| gl.commit(),
    }
}

pub fn writeBufferTransient(buf: *core.Buffer, desc: *const t.WriteBufferDesc, first_time_in_frame: bool) void {
    switch (impl().*) {
        inline .vulkan, .wgpu, .metal, .d3d12 => |*b| b.writeBufferTransient(buf, desc, first_time_in_frame),
        .dummy => {},
        .gl => |*gl| gl.writeBuffer(&buf.native.gl, buf.cmn.usage, buf.cmn.active_slot, desc.*),
        .d3d11 => |*dx| dx.writeBuffer(&buf.native.d3d11, desc.*, true, first_time_in_frame),
    }
}

pub fn writeBufferUnsealed(buf: *core.Buffer, desc: *const t.WriteBufferDesc) void {
    switch (impl().*) {
        inline .vulkan, .wgpu, .metal, .d3d12 => |*b| b.writeBufferUnsealed(buf, desc),
        .dummy => {},
        .gl => |*gl| gl.writeBuffer(&buf.native.gl, buf.cmn.usage, buf.cmn.active_slot, desc.*),
        .d3d11 => |*dx| dx.writeBuffer(&buf.native.d3d11, desc.*, false, false),
    }
}

pub fn writeImageTransient(img: *core.Image, desc: *const t.WriteImageDesc, first_time_in_frame: bool) void {
    switch (impl().*) {
        inline .vulkan, .wgpu, .metal, .d3d12 => |*b| b.writeImageTransient(img, desc, first_time_in_frame),
        else => writeImage(img, desc),
    }
}

pub fn writeImageUnsealed(img: *core.Image, desc: *const t.WriteImageDesc) void {
    switch (impl().*) {
        inline .vulkan, .wgpu, .metal, .d3d12 => |*b| b.writeImageUnsealed(img, desc),
        else => writeImage(img, desc),
    }
}

fn writeImage(img: *core.Image, desc: *const t.WriteImageDesc) void {
    switch (impl().*) {
        .dummy => {},
        .gl => |*gl| gl.writeImage(&img.native.gl, img.desc, img.cmn.active_slot, desc.*),
        .d3d11 => |*dx| dx.writeImage(&img.native.d3d11, img.desc, desc.*),
        else => unreachable,
    }
}

pub fn sealBuffer(buf: *core.Buffer) void {
    switch (impl().*) {
        inline .vulkan, .wgpu, .metal, .d3d12 => |*b| b.sealBuffer(buf),
        else => {},
    }
}

pub fn sealImage(img: *core.Image) void {
    switch (impl().*) {
        inline .vulkan, .wgpu, .metal, .d3d12 => |*b| b.sealImage(img),
        else => {},
    }
}

pub fn copyBufferToBuffer(src: *core.Buffer, dst: *core.Buffer, desc: *const t.CopyBufferToBufferDesc) void {
    switch (impl().*) {
        inline .vulkan, .wgpu, .metal, .d3d12 => |*b| b.copyBufferToBuffer(src, dst, desc),
        .dummy => {},
        .gl => |*gl| gl.copyBuffer(&src.native.gl, &dst.native.gl, src.cmn.usage, dst.cmn.usage, src.cmn.active_slot, dst.cmn.active_slot, desc.*),
        .d3d11 => |*dx| dx.copyBuffer(&src.native.d3d11, &dst.native.d3d11, desc.*),
    }
}

pub fn copyBufferToImage(src: *core.Buffer, dst: *core.Image, desc: *const t.CopyBufferToImageDesc) void {
    switch (impl().*) {
        inline .vulkan, .wgpu, .metal, .d3d12 => |*b| b.copyBufferToImage(src, dst, desc),
        .dummy => {},
        .gl => |*gl| gl.copyBufferToImage(&src.native.gl, &dst.native.gl, src.cmn.usage, dst.desc, src.cmn.active_slot, dst.cmn.active_slot, desc.*),
        .d3d11 => |*dx| dx.copyBufferToImage(&src.native.d3d11, &dst.native.d3d11, dst.desc, desc.*),
    }
}

pub fn readBuffer(buf: *core.Buffer, offset: usize, out: []u8) bool {
    return switch (impl().*) {
        inline .vulkan, .wgpu, .metal, .d3d12 => |*b| b.readBuffer(buf, offset, out),
        .dummy => blk: {
            @memset(out, 0);
            break :blk true;
        },
        .gl => |*gl| gl.readBuffer(&buf.native.gl, buf.cmn.usage, buf.cmn.active_slot, offset, out),
        .d3d11 => |*dx| dx.readBuffer(&buf.native.d3d11, buf.desc, offset, out),
    };
}

pub fn readImage(img: *core.Image, region: *const core.ReadRegion, out: []u8) bool {
    return switch (impl().*) {
        inline .vulkan, .wgpu, .metal, .d3d12 => |*b| b.readImage(img, region, out),
        .dummy => blk: {
            @memset(out, 0);
            break :blk true;
        },
        .gl => |*gl| gl.readImage(&img.native.gl, img.desc, img.cmn.active_slot, region, out),
        .d3d11 => |*dx| dx.readImage(&img.native.d3d11, img.desc, region, out),
    };
}

pub fn pushDebugGroup(name: [*:0]const u8) void {
    switch (impl().*) {
        inline .vulkan, .wgpu, .metal, .d3d12 => |*b| b.pushDebugGroup(name),
        else => {},
    }
}

pub fn popDebugGroup() void {
    switch (impl().*) {
        inline .vulkan, .wgpu, .metal, .d3d12 => |*b| b.popDebugGroup(),
        else => {},
    }
}

// ---------------------------------------------------------------- GL and D3D11 glue

fn slotInfo(slot: *const core.Slot) t.SlotInfo {
    return .{ .state = slot.state, .res_id = slot.id, .uninit_count = slot.uninit_count };
}

fn bufferBinding(comptime R: type, comptime tag: anytype, buf: *core.Buffer) R.BufferBinding {
    return .{ .resource = &@field(buf.native, @tagName(tag)), .desc = &buf.desc, .active_slot = buf.cmn.active_slot };
}

fn imageBinding(comptime R: type, comptime tag: anytype, img: *core.Image) R.ImageBinding {
    return .{ .resource = &@field(img.native, @tagName(tag)), .desc = &img.desc, .active_slot = img.cmn.active_slot };
}

fn viewBinding(comptime R: type, comptime tag: anytype, view: *core.View) R.ViewBinding {
    var res: R.ViewBinding = .{ .resource = &@field(view.native, @tagName(tag)), .desc = &view.desc };
    if (view.cmn.type == .storagebuffer) {
        res.buffer = bufferBinding(R, tag, view.cmn.buf.ref.get());
    } else {
        res.image = imageBinding(R, tag, view.cmn.img.ref.get());
    }
    return res;
}

fn nativeAttachments(comptime R: type, comptime tag: anytype, atts: *const core.AttachmentsPtrs) R.Attachments {
    var res: R.Attachments = .{ .num_colors = atts.num_color_views };
    for (atts.color_views, atts.resolve_views, 0..) |color, resolve, i| {
        if (color) |view| res.colors[i] = viewBinding(R, tag, view);
        if (resolve) |view| res.resolves[i] = viewBinding(R, tag, view);
    }
    if (atts.ds_view) |view| res.depth_stencil = viewBinding(R, tag, view);
    if (!atts.empty) {
        const dim = core.attachmentsDim(atts);
        res.width = dim.width;
        res.height = dim.height;
    }
    return res;
}

fn nativeBindings(comptime R: type, comptime tag: anytype, bnd: *const core.BindingsPtrs, res: *R.Bindings) void {
    const pip = bnd.pip;
    const shd = pip.cmn.shader.get();
    // Build directly in the caller's scratch space rather than returning a
    // multi-kilobyte optional-binding aggregate by value on every draw.
    res.* = .{
        .pipeline = .{ .resource = &@field(pip.native, @tagName(tag)), .desc = &pip.desc, .slot = slotInfo(&pip.slot) },
        .shader = .{ .resource = &@field(shd.native, @tagName(tag)), .desc = &shd.desc },
        .vertex_offsets = bnd.vb_offsets,
        .index_offset = bnd.ib_offset,
    };
    for (&bnd.vbs, 0..) |vb, i| {
        if (vb) |buf| res.vertex_buffers[i] = bufferBinding(R, tag, buf);
    }
    if (bnd.ib) |buf| res.index_buffer = bufferBinding(R, tag, buf);
    for (&bnd.views, 0..) |optional, i| {
        if (optional) |view| res.views[i] = viewBinding(R, tag, view);
    }
    for (&bnd.smps, 0..) |optional, i| {
        if (optional) |smp| res.samplers[i] = &@field(smp.native, @tagName(tag));
    }
}
