//! Minimal wgpu pipeline/encoding helpers for the offscreen GPU smoke test
//! (Apache-2.0 OR MIT).
//!
//! This is the seed of the T3 pipeline factory: shader modules are built from
//! the checked-in WGSL in `src/gpu/shaders/generated.zig`, and the rect-clear
//! pipeline mirrors upstream `create_clear_pipeline` exactly (empty pipeline
//! layout, 28-byte `GpuClearInstance` vertex layout with instance step mode,
//! `vs_main`/`fs_main`, target format `Rgba8Unorm`, triangle-strip,
//! `load: Load`). Bind-group/pipeline helpers for the strip, blend, copy, and
//! filter passes land in T3/T4.

const std = @import("std");
const wgpu = @import("wgpu");
const c = wgpu.c;
const device = @import("device.zig");
const shaders = @import("../shaders/generated.zig");
const common = @import("../render/common.zig");

pub const Error = device.Error || error{
    ShaderCreationFailed,
    PipelineCreationFailed,
    TextureCreationFailed,
    TextureViewCreationFailed,
    RenderPassFailed,
    CommandEncodingFailed,
};

/// Create a WGSL shader module from a checked-in source string.
pub fn createShaderModule(
    dev: *device.Device,
    code: []const u8,
    label: []const u8,
) Error!c.WGPUShaderModule {
    var source = c.wgpu_zig_init_WGPUShaderSourceWGSL();
    source.chain.sType = c.WGPUSType_ShaderSourceWGSL;
    source.code = wgpu.stringView(code);

    var desc = c.wgpu_zig_init_WGPUShaderModuleDescriptor();
    desc.label = wgpu.stringView(label);
    desc.nextInChain = &source.chain;
    return c.wgpuDeviceCreateShaderModule(dev.handle, &desc) orelse error.ShaderCreationFailed;
}

/// Create a 2D texture with the given size, format, and usage.
pub fn createTexture2d(
    dev: *device.Device,
    width: u32,
    height: u32,
    format: c.WGPUTextureFormat,
    usage: c.WGPUTextureUsage,
    label: []const u8,
) Error!c.WGPUTexture {
    var desc = c.wgpu_zig_init_WGPUTextureDescriptor();
    desc.label = wgpu.stringView(label);
    desc.usage = usage;
    desc.dimension = c.WGPUTextureDimension_2D;
    desc.size = .{ .width = width, .height = height, .depthOrArrayLayers = 1 };
    desc.format = format;
    return c.wgpuDeviceCreateTexture(dev.handle, &desc) orelse error.TextureCreationFailed;
}

/// Create a full-size 2D texture view.
pub fn createFullView(
    texture: c.WGPUTexture,
    format: c.WGPUTextureFormat,
    label: []const u8,
) Error!c.WGPUTextureView {
    var desc = c.wgpu_zig_init_WGPUTextureViewDescriptor();
    desc.label = wgpu.stringView(label);
    desc.format = format;
    desc.dimension = c.WGPUTextureViewDimension_2D;
    return c.wgpuTextureCreateView(texture, &desc) orelse error.TextureViewCreationFailed;
}

/// The rect-clear render pipeline (upstream `clear_pipeline` /
/// `root_clear_pipeline`).
pub const ClearPipeline = struct {
    pipeline: c.WGPURenderPipeline,
    format: c.WGPUTextureFormat,

    pub fn create(dev: *device.Device, format: c.WGPUTextureFormat, label: []const u8) Error!ClearPipeline {
        const module = try createShaderModule(dev, shaders.CLEAR, label);
        defer c.wgpuShaderModuleRelease(module);

        var layout_desc = c.wgpu_zig_init_WGPUPipelineLayoutDescriptor();
        layout_desc.label = wgpu.stringView("vellz-gpu-clear-layout");
        const layout = c.wgpuDeviceCreatePipelineLayout(dev.handle, &layout_desc) orelse {
            return error.PipelineCreationFailed;
        };
        defer c.wgpuPipelineLayoutRelease(layout);

        const attributes = [_]c.WGPUVertexAttribute{
            .{ .format = c.WGPUVertexFormat_Uint32x2, .offset = 0, .shaderLocation = 0 },
            .{ .format = c.WGPUVertexFormat_Uint32x2, .offset = 8, .shaderLocation = 1 },
            .{ .format = c.WGPUVertexFormat_Uint32x2, .offset = 16, .shaderLocation = 2 },
            .{ .format = c.WGPUVertexFormat_Uint32, .offset = 24, .shaderLocation = 3 },
        };
        var vertex_buffer = c.wgpu_zig_init_WGPUVertexBufferLayout();
        vertex_buffer.arrayStride = @sizeOf(common.GpuClearInstance);
        vertex_buffer.stepMode = c.WGPUVertexStepMode_Instance;
        vertex_buffer.attributeCount = attributes.len;
        vertex_buffer.attributes = &attributes;

        var color_target = c.wgpu_zig_init_WGPUColorTargetState();
        color_target.format = format;
        color_target.writeMask = c.WGPUColorWriteMask_All;

        var fragment = c.wgpu_zig_init_WGPUFragmentState();
        fragment.module = module;
        fragment.entryPoint = wgpu.stringView("fs_main");
        fragment.targetCount = 1;
        fragment.targets = &color_target;

        var primitive = c.wgpu_zig_init_WGPUPrimitiveState();
        primitive.topology = c.WGPUPrimitiveTopology_TriangleStrip;

        var desc = c.wgpu_zig_init_WGPURenderPipelineDescriptor();
        desc.label = wgpu.stringView(label);
        desc.layout = layout;
        desc.vertex = .{
            .module = module,
            .entryPoint = wgpu.stringView("vs_main"),
            .bufferCount = 1,
            .buffers = &vertex_buffer,
        };
        desc.primitive = primitive;
        desc.multisample = c.wgpu_zig_init_WGPUMultisampleState();
        desc.fragment = &fragment;

        const pipeline = c.wgpuDeviceCreateRenderPipeline(dev.handle, &desc) orelse {
            return error.PipelineCreationFailed;
        };
        return .{ .pipeline = pipeline, .format = format };
    }

    pub fn deinit(self: *ClearPipeline) void {
        c.wgpuRenderPipelineRelease(self.pipeline);
        self.* = undefined;
    }
};

/// Clear rectangles of a `format`-matching texture view with a list of
/// `GpuClearInstance` values, using the checked-in clear WGSL.
///
/// Mirrors upstream `clear_pass_inner`: the instances are uploaded to a
/// vertex buffer, the pass loads (preserves) the target, and each instance
/// draws a 4-vertex triangle strip.
pub fn clearTexture(
    dev: *device.Device,
    view: c.WGPUTextureView,
    texture_format: c.WGPUTextureFormat,
    pipeline: *const ClearPipeline,
    instances: []const common.GpuClearInstance,
) Error!void {
    if (instances.len == 0) return;
    if (pipeline.format != texture_format) return error.UnsupportedCapability;
    if (dev.isLost()) return error.DeviceLost;

    dev.pushErrorScope(c.WGPUErrorFilter_Validation);
    var scope_open = true;
    errdefer if (scope_open) {
        _ = dev.popErrorScope() catch {};
    };

    const instance_bytes: u64 = @as(u64, @sizeOf(common.GpuClearInstance)) * instances.len;
    var buffer_desc = c.wgpu_zig_init_WGPUBufferDescriptor();
    buffer_desc.label = wgpu.stringView("vellz-gpu-clear-instances");
    buffer_desc.size = instance_bytes;
    buffer_desc.usage = c.WGPUBufferUsage_Vertex | c.WGPUBufferUsage_CopyDst;
    const buffer = c.wgpuDeviceCreateBuffer(dev.handle, &buffer_desc) orelse {
        return error.OutOfMemory;
    };
    defer c.wgpuBufferRelease(buffer);
    c.wgpuQueueWriteBuffer(dev.queue, buffer, 0, instances.ptr, @intCast(instance_bytes));

    var encoder_desc = c.wgpu_zig_init_WGPUCommandEncoderDescriptor();
    encoder_desc.label = wgpu.stringView("vellz-gpu-clear-encoder");
    const encoder = c.wgpuDeviceCreateCommandEncoder(dev.handle, &encoder_desc) orelse {
        return error.CommandEncodingFailed;
    };
    defer c.wgpuCommandEncoderRelease(encoder);

    var color_attachment = c.wgpu_zig_init_WGPURenderPassColorAttachment();
    color_attachment.view = view;
    color_attachment.depthSlice = c.WGPU_DEPTH_SLICE_UNDEFINED;
    color_attachment.loadOp = c.WGPULoadOp_Load;
    color_attachment.storeOp = c.WGPUStoreOp_Store;
    color_attachment.clearValue = .{ .r = 0.0, .g = 0.0, .b = 0.0, .a = 0.0 };

    var pass_desc = c.wgpu_zig_init_WGPURenderPassDescriptor();
    pass_desc.label = wgpu.stringView("vellz-gpu-clear-pass");
    pass_desc.colorAttachmentCount = 1;
    pass_desc.colorAttachments = &color_attachment;
    const pass = c.wgpuCommandEncoderBeginRenderPass(encoder, &pass_desc) orelse {
        return error.RenderPassFailed;
    };
    c.wgpuRenderPassEncoderSetPipeline(pass, pipeline.pipeline);
    c.wgpuRenderPassEncoderSetVertexBuffer(pass, 0, buffer, 0, c.WGPU_WHOLE_SIZE);
    c.wgpuRenderPassEncoderDraw(pass, 4, @intCast(instances.len), 0, 0);
    c.wgpuRenderPassEncoderEnd(pass);
    c.wgpuRenderPassEncoderRelease(pass);

    var command_desc = c.wgpu_zig_init_WGPUCommandBufferDescriptor();
    command_desc.label = wgpu.stringView("vellz-gpu-clear-commands");
    const command_buffer = c.wgpuCommandEncoderFinish(encoder, &command_desc) orelse {
        return error.CommandEncodingFailed;
    };
    defer c.wgpuCommandBufferRelease(command_buffer);
    c.wgpuQueueSubmit(dev.queue, 1, &command_buffer);

    const scope_result = dev.popErrorScope();
    scope_open = false;
    try scope_result;
}
