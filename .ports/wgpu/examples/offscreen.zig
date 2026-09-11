//! Verification example: render offscreen into a texture through wgpu-native
//! and check the resulting pixels on the CPU.
//!
//! Run with: zig build run-offscreen
//!
//! The render target is a 64x64 RGBA8Unorm texture. A centered triangle is
//! drawn over a solid clear color; after rendering, the texture is copied to a
//! readback buffer and both regions are verified pixel by pixel.

const std = @import("std");
const wgpu = @import("wgpu");
const c = wgpu.c;
const common = @import("common.zig");

const width = 64;
const height = 64;
const bytes_per_row = width * 4; // 64 * 4 = 256, already 256-byte aligned

const clear_color = [4]f64{ 0.25, 0.5, 0.75, 1.0 };
const triangle_color = [4]f64{ 1.0, 0.0, 0.0, 1.0 };

const render_wgsl =
    \\@vertex
    \\fn vs(@builtin(vertex_index) index: u32) -> @builtin(position) vec4f {
    \\    var positions = array<vec2f, 3>(
    \\        vec2f(-0.5, -0.5),
    \\        vec2f( 0.5, -0.5),
    \\        vec2f( 0.0,  0.5),
    \\    );
    \\    return vec4f(positions[index], 0.0, 1.0);
    \\}
    \\
    \\@fragment
    \\fn fs() -> @location(0) vec4f {
    \\    return vec4f(1.0, 0.0, 0.0, 1.0);
    \\}
;

pub fn main(init: std.process.Init) !void {
    _ = init;
    common.installLogging(c.WGPULogLevel_Warn);

    const instance = c.wgpuCreateInstance(null) orelse {
        std.debug.print("FAIL: wgpuCreateInstance returned null\n", .{});
        return error.NoInstance;
    };
    defer c.wgpuInstanceRelease(instance);

    // ------------------------------------------------------------- adapter
    var adapter_query = common.AdapterQuery{};
    var adapter_options = c.wgpu_zig_init_WGPURequestAdapterOptions();
    adapter_options.powerPreference = c.WGPUPowerPreference_HighPerformance;
    _ = c.wgpuInstanceRequestAdapter(instance, &adapter_options, .{
        .callback = &common.AdapterQuery.onCallback,
        .userdata1 = &adapter_query,
    });
    const adapter = adapter_query.adapter orelse {
        std.debug.print("FAIL: no compatible adapter found\n", .{});
        return error.NoAdapter;
    };
    defer c.wgpuAdapterRelease(adapter);

    var adapter_info = c.wgpu_zig_init_WGPUAdapterInfo();
    if (c.wgpuAdapterGetInfo(adapter, &adapter_info) != c.WGPUStatus_Success) {
        std.debug.print("FAIL: wgpuAdapterGetInfo failed\n", .{});
        return error.AdapterInfoFailed;
    }
    defer c.wgpuAdapterInfoFreeMembers(adapter_info);
    common.printAdapterInfo(&adapter_info);

    // -------------------------------------------------------------- device
    var errors = common.ErrorTracker{};
    var device_desc = c.wgpu_zig_init_WGPUDeviceDescriptor();
    device_desc.label = wgpu.stringView("offscreen-device");
    device_desc.uncapturedErrorCallbackInfo = .{
        .callback = &common.ErrorTracker.onUncaptured,
        .userdata1 = &errors,
    };
    var device_query = common.DeviceQuery{};
    _ = c.wgpuAdapterRequestDevice(adapter, &device_desc, .{
        .callback = &common.DeviceQuery.onCallback,
        .userdata1 = &device_query,
    });
    const device = device_query.device orelse {
        std.debug.print("FAIL: device request failed\n", .{});
        return error.NoDevice;
    };
    defer c.wgpuDeviceRelease(device);

    const queue = c.wgpuDeviceGetQueue(device) orelse {
        std.debug.print("FAIL: wgpuDeviceGetQueue returned null\n", .{});
        return error.NoQueue;
    };
    defer c.wgpuQueueRelease(queue);

    // --------------------------------------------- render target and view
    var texture_desc = c.wgpu_zig_init_WGPUTextureDescriptor();
    texture_desc.label = wgpu.stringView("offscreen-color");
    texture_desc.usage = c.WGPUTextureUsage_RenderAttachment | c.WGPUTextureUsage_CopySrc;
    texture_desc.dimension = c.WGPUTextureDimension_2D;
    texture_desc.size = .{ .width = width, .height = height, .depthOrArrayLayers = 1 };
    texture_desc.format = c.WGPUTextureFormat_RGBA8Unorm;
    const texture = c.wgpuDeviceCreateTexture(device, &texture_desc) orelse {
        std.debug.print("FAIL: texture creation failed\n", .{});
        return error.TextureCreationFailed;
    };
    defer c.wgpuTextureRelease(texture);

    var view_desc = c.wgpu_zig_init_WGPUTextureViewDescriptor();
    view_desc.label = wgpu.stringView("offscreen-view");
    view_desc.format = c.WGPUTextureFormat_RGBA8Unorm;
    view_desc.dimension = c.WGPUTextureViewDimension_2D;
    const view = c.wgpuTextureCreateView(texture, &view_desc) orelse {
        std.debug.print("FAIL: texture view creation failed\n", .{});
        return error.TextureViewFailed;
    };
    defer c.wgpuTextureViewRelease(view);

    // ------------------------------------------------------- render pipeline
    const shader = createShader(device, render_wgsl) orelse {
        std.debug.print("FAIL: shader module creation failed\n", .{});
        return error.ShaderCreationFailed;
    };
    defer c.wgpuShaderModuleRelease(shader);

    var color_target = c.wgpu_zig_init_WGPUColorTargetState();
    color_target.format = c.WGPUTextureFormat_RGBA8Unorm;
    color_target.writeMask = c.WGPUColorWriteMask_All;

    var fragment_state = c.wgpu_zig_init_WGPUFragmentState();
    fragment_state.module = shader;
    fragment_state.entryPoint = wgpu.stringView("fs");
    fragment_state.targetCount = 1;
    fragment_state.targets = &color_target;

    var pipeline_desc = c.wgpu_zig_init_WGPURenderPipelineDescriptor();
    pipeline_desc.label = wgpu.stringView("triangle-pipeline");
    pipeline_desc.layout = null; // automatic pipeline layout
    pipeline_desc.vertex = .{
        .module = shader,
        .entryPoint = wgpu.stringView("vs"),
    };
    pipeline_desc.primitive = c.wgpu_zig_init_WGPUPrimitiveState();
    pipeline_desc.multisample = c.wgpu_zig_init_WGPUMultisampleState();
    pipeline_desc.fragment = &fragment_state;
    const pipeline = c.wgpuDeviceCreateRenderPipeline(device, &pipeline_desc) orelse {
        std.debug.print("FAIL: render pipeline creation failed\n", .{});
        return error.PipelineCreationFailed;
    };
    defer c.wgpuRenderPipelineRelease(pipeline);

    // ----------------------------------------------------------- readback buffer
    const readback_size: u64 = @as(u64, bytes_per_row) * height;
    var readback_desc = c.wgpu_zig_init_WGPUBufferDescriptor();
    readback_desc.label = wgpu.stringView("offscreen-readback");
    readback_desc.size = readback_size;
    readback_desc.usage = c.WGPUBufferUsage_MapRead | c.WGPUBufferUsage_CopyDst;
    const readback = c.wgpuDeviceCreateBuffer(device, &readback_desc) orelse {
        std.debug.print("FAIL: readback buffer creation failed\n", .{});
        return error.BufferCreationFailed;
    };
    defer c.wgpuBufferRelease(readback);

    // ------------------------------------------------------------ render pass
    var encoder_desc = c.wgpu_zig_init_WGPUCommandEncoderDescriptor();
    encoder_desc.label = wgpu.stringView("offscreen-encoder");
    const encoder = c.wgpuDeviceCreateCommandEncoder(device, &encoder_desc) orelse {
        std.debug.print("FAIL: command encoder creation failed\n", .{});
        return error.EncoderFailed;
    };
    defer c.wgpuCommandEncoderRelease(encoder);

    var color_attachment = c.wgpu_zig_init_WGPURenderPassColorAttachment();
    color_attachment.view = view;
    color_attachment.depthSlice = c.WGPU_DEPTH_SLICE_UNDEFINED;
    color_attachment.loadOp = c.WGPULoadOp_Clear;
    color_attachment.storeOp = c.WGPUStoreOp_Store;
    color_attachment.clearValue = .{
        .r = clear_color[0],
        .g = clear_color[1],
        .b = clear_color[2],
        .a = clear_color[3],
    };

    var pass_desc = c.wgpu_zig_init_WGPURenderPassDescriptor();
    pass_desc.label = wgpu.stringView("offscreen-pass");
    pass_desc.colorAttachmentCount = 1;
    pass_desc.colorAttachments = &color_attachment;
    const pass = c.wgpuCommandEncoderBeginRenderPass(encoder, &pass_desc) orelse {
        std.debug.print("FAIL: render pass creation failed\n", .{});
        return error.RenderPassFailed;
    };
    c.wgpuRenderPassEncoderSetPipeline(pass, pipeline);
    c.wgpuRenderPassEncoderDraw(pass, 3, 1, 0, 0);
    c.wgpuRenderPassEncoderEnd(pass);
    c.wgpuRenderPassEncoderRelease(pass);

    // ------------------------------------------------------- texture readback
    var copy_src: c.WGPUTexelCopyTextureInfo = .{
        .texture = texture,
        .mipLevel = 0,
        .origin = .{ .x = 0, .y = 0, .z = 0 },
        .aspect = c.WGPUTextureAspect_All,
    };
    var copy_dst: c.WGPUTexelCopyBufferInfo = .{
        .layout = .{
            .offset = 0,
            .bytesPerRow = bytes_per_row,
            .rowsPerImage = height,
        },
        .buffer = readback,
    };
    var copy_size = c.WGPUExtent3D{ .width = width, .height = height, .depthOrArrayLayers = 1 };
    c.wgpuCommandEncoderCopyTextureToBuffer(encoder, &copy_src, &copy_dst, &copy_size);

    var command_buffer_desc = c.wgpu_zig_init_WGPUCommandBufferDescriptor();
    command_buffer_desc.label = wgpu.stringView("offscreen-commands");
    const command_buffer = c.wgpuCommandEncoderFinish(encoder, &command_buffer_desc) orelse {
        std.debug.print("FAIL: command buffer creation failed\n", .{});
        return error.CommandBufferFailed;
    };
    defer c.wgpuCommandBufferRelease(command_buffer);

    c.wgpuQueueSubmit(queue, 1, &command_buffer);

    // ----------------------------------------------------------- pixel checks
    var map_state = common.MapState{};
    _ = c.wgpuBufferMapAsync(readback, c.WGPUMapMode_Read, 0, readback_size, .{
        .callback = &common.MapState.onCallback,
        .userdata1 = &map_state,
    });
    _ = c.wgpuDevicePoll(device, 1, null);
    if (!map_state.ok) {
        std.debug.print("FAIL: readback buffer map failed\n", .{});
        return error.MapFailed;
    }

    const mapped = c.wgpuBufferGetMappedRange(readback, 0, readback_size) orelse {
        std.debug.print("FAIL: wgpuBufferGetMappedRange returned null\n", .{});
        return error.MappedRangeFailed;
    };
    const pixels: [*]const u8 = @ptrCast(mapped);

    const expected_clear = [4]u8{
        colorToByte(clear_color[0]),
        colorToByte(clear_color[1]),
        colorToByte(clear_color[2]),
        colorToByte(clear_color[3]),
    };
    const expected_triangle = [4]u8{
        colorToByte(triangle_color[0]),
        colorToByte(triangle_color[1]),
        colorToByte(triangle_color[2]),
        colorToByte(triangle_color[3]),
    };

    // Inside the triangle (center of the texture) and outside it (near the
    // top-left corner) must show the two different expected colors.
    const center = pixelAt(pixels, width / 2, height / 2);
    const corner = pixelAt(pixels, 5, 5);
    std.debug.print("center pixel: {any} (expected {any})\n", .{ center, expected_triangle });
    std.debug.print("corner pixel: {any} (expected {any})\n", .{ corner, expected_clear });

    if (!pixelApproxEqual(center, expected_triangle, 2)) {
        std.debug.print("FAIL: center pixel does not match triangle color\n", .{});
        c.wgpuBufferUnmap(readback);
        return error.CenterPixelMismatch;
    }
    if (!pixelApproxEqual(corner, expected_clear, 2)) {
        std.debug.print("FAIL: corner pixel does not match clear color\n", .{});
        c.wgpuBufferUnmap(readback);
        return error.CornerPixelMismatch;
    }

    var triangle_pixels: usize = 0;
    var clear_pixels: usize = 0;
    var other_pixels: usize = 0;
    for (0..height) |y| {
        for (0..width) |x| {
            const pixel = pixelAt(pixels, x, y);
            if (pixelApproxEqual(pixel, expected_triangle, 2)) {
                triangle_pixels += 1;
            } else if (pixelApproxEqual(pixel, expected_clear, 2)) {
                clear_pixels += 1;
            } else {
                other_pixels += 1;
            }
        }
    }
    std.debug.print(
        "pixel census: {d} triangle, {d} clear, {d} other (of {d})\n",
        .{ triangle_pixels, clear_pixels, other_pixels, width * height },
    );
    c.wgpuBufferUnmap(readback);

    // A full-width, half-height triangle covers roughly a quarter of the
    // texture. Require a clear majority of both categories and no stray pixels
    // (anti-aliasing is not enabled, so every pixel is one of the two colors).
    if (triangle_pixels < 500 or clear_pixels < 500 or other_pixels != 0) {
        std.debug.print("FAIL: unexpected pixel census\n", .{});
        return error.PixelCensusFailed;
    }

    _ = c.wgpuDevicePoll(device, 1, null);
    if (errors.count != 0) {
        std.debug.print("FAIL: {d} uncaptured device error(s); last type={d} message=\"{s}\"\n", .{
            errors.count, errors.last_type, errors.last(),
        });
        return error.UncapturedDeviceError;
    }

    std.debug.print("PASS: offscreen render pixels verified\n", .{});
}

fn createShader(device: c.WGPUDevice, code: []const u8) c.WGPUShaderModule {
    var source = c.wgpu_zig_init_WGPUShaderSourceWGSL();
    source.chain.sType = c.WGPUSType_ShaderSourceWGSL;
    source.code = wgpu.stringView(code);

    var desc = c.wgpu_zig_init_WGPUShaderModuleDescriptor();
    desc.label = wgpu.stringView("offscreen-shader");
    desc.nextInChain = &source.chain;
    return c.wgpuDeviceCreateShaderModule(device, &desc);
}

fn pixelAt(pixels: [*]const u8, x: usize, y: usize) [4]u8 {
    const index = (y * width + x) * 4;
    return .{ pixels[index], pixels[index + 1], pixels[index + 2], pixels[index + 3] };
}

fn colorToByte(value: f64) u8 {
    return @intFromFloat(@round(value * 255.0));
}

fn pixelApproxEqual(a: [4]u8, b: [4]u8, tolerance: u8) bool {
    for (a, b) |lhs, rhs| {
        const diff = if (lhs > rhs) lhs - rhs else rhs - lhs;
        if (diff > tolerance) return false;
    }
    return true;
}
