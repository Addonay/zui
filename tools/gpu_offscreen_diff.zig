//! Optional WGPU/CPU pixel differential fixture.
//!
//! This renders the same opaque ZUI scene through Vellz CPU and the WGPU
//! bridge into an offscreen texture, maps the texture back, and compares every
//! pixel with a small tolerance. It intentionally uses only solid quads so a
//! failure points at the renderer boundary rather than font/image resources.

const std = @import("std");
const zui = @import("zui");
const vellz = @import("vellz");
const wgpu = @import("wgpu");

const c = wgpu.c;
const backend = vellz.gpu.backend;
const gpu_scene = vellz.gpu.scene;
const peniko = vellz.peniko;
const resources_mod = vellz.gpu.resources;
const bridge_mod = zui.gpu.wgpu_bridge;

const width: u32 = 64;
const height: u32 = 64;
const bytes_per_row: u32 = width * 4;

const MapState = struct {
    ok: bool = false,

    fn callback(
        status: c.WGPUMapAsyncStatus,
        _: c.WGPUStringView,
        userdata1: ?*anyopaque,
        _: ?*anyopaque,
    ) callconv(.c) void {
        const self: *@This() = @ptrCast(@alignCast(userdata1 orelse return));
        self.ok = status == c.WGPUMapAsyncStatus_Success;
    }
};

fn byte(value: f32) u8 {
    return @intFromFloat(@round(std.math.clamp(value, 0, 1) * 255));
}

fn absDiff(a: u8, b: u8) u8 {
    return if (a > b) a - b else b - a;
}

fn elapsedNs(from: std.Io.Timestamp, to: std.Io.Timestamp) u64 {
    return @intCast(@max(0, from.durationTo(to).nanoseconds));
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    var instance = backend.Instance.create() catch |err| {
        std.debug.print("SKIP: WGPU instance unavailable: {s}\n", .{@errorName(err)});
        return;
    };
    defer instance.deinit();
    var adapter = backend.Adapter.acquire(&instance, .{}) catch |err| {
        std.debug.print("SKIP: WGPU adapter unavailable: {s}\n", .{@errorName(err)});
        return;
    };
    defer adapter.deinit();
    var device = backend.Device.acquire(allocator, &adapter, "zui-offscreen-diff") catch |err| {
        std.debug.print("SKIP: WGPU device unavailable: {s}\n", .{@errorName(err)});
        return;
    };
    defer device.deinit();

    var source = zui.Scene{};
    var path_storage: zui.gpu.PathStorage = undefined;
    source.attachPathStorage(&path_storage);
    const image_pixels = [_]u8{
        255, 32, 32,  255, 32,  255, 32, 255,
        32,  32, 255, 255, 255, 255, 32, 255,
    };
    try std.testing.expect(source.push(.{
        .x = 0,
        .y = 0,
        .w = width,
        .h = height,
        .color = .{ .r = 0.18, .g = 0.42, .b = 0.76, .a = 1 },
    }));
    try std.testing.expect(source.push(.{
        .x = 12,
        .y = 12,
        .w = 24,
        .h = 20,
        .color = .{ .r = 0.92, .g = 0.64, .b = 0.11, .a = 1 },
        .radius = 5,
    }));
    try std.testing.expect(source.push(.{
        .x = 40,
        .y = 8,
        .w = 18,
        .h = 16,
        .color = .{ .r = 1, .g = 0.15, .b = 0.1, .a = 0.55 },
        .gradient_to = .{ .r = 0.1, .g = 0.25, .b = 1, .a = 0.55 },
    }));
    var triangle = zui.gpu.Path{ .color = .{ .r = 0.15, .g = 0.95, .b = 0.35, .a = 1 }, .stroke_width = 0 };
    triangle.segments[0] = .{ .move_to = .{ .x = 8, .y = 48 } };
    triangle.segments[1] = .{ .line_to = .{ .x = 28, .y = 48 } };
    triangle.segments[2] = .{ .line_to = .{ .x = 18, .y = 60 } };
    triangle.segments[3] = .close;
    triangle.segment_len = 4;
    try std.testing.expect(source.pushPath(triangle));
    try std.testing.expect(source.pushImage(.{
        .x = 32,
        .y = 40,
        .w = 16,
        .h = 16,
        .pool_offset = 0,
        .src_w = 2,
        .src_h = 2,
        .tint = .white,
        .clip = .{ .x = 32, .y = 40, .w = 16, .h = 16 },
    }));

    var cpu = zui.gpu.vellz.Renderer.init(allocator);
    defer cpu.deinit();
    var cpu_pixels: [width * height * 4]u8 = undefined;
    const cpu_start = std.Io.Clock.now(.awake, init.io);
    try cpu.render(&cpu_pixels, width, height, .rgba32, .{ .r = 0, .g = 0, .b = 0, .a = 1 }, &source, &.{}, &image_pixels);
    const cpu_ns = elapsedNs(cpu_start, std.Io.Clock.now(.awake, init.io));

    var texture_desc = c.wgpu_zig_init_WGPUTextureDescriptor();
    texture_desc.label = wgpu.stringView("zui-offscreen-color");
    texture_desc.usage = c.WGPUTextureUsage_RenderAttachment | c.WGPUTextureUsage_CopySrc;
    texture_desc.dimension = c.WGPUTextureDimension_2D;
    texture_desc.size = .{ .width = width, .height = height, .depthOrArrayLayers = 1 };
    texture_desc.format = c.WGPUTextureFormat_RGBA8Unorm;
    const texture = c.wgpuDeviceCreateTexture(device.handle, &texture_desc) orelse return error.TextureCreationFailed;
    defer c.wgpuTextureRelease(texture);
    var view_desc = c.wgpu_zig_init_WGPUTextureViewDescriptor();
    view_desc.label = wgpu.stringView("zui-offscreen-view");
    view_desc.format = c.WGPUTextureFormat_RGBA8Unorm;
    view_desc.dimension = c.WGPUTextureViewDimension_2D;
    const view = c.wgpuTextureCreateView(texture, &view_desc) orelse return error.TextureViewFailed;
    defer c.wgpuTextureViewRelease(view);

    var renderer = try backend.renderer.Renderer.init(allocator, &device, c.WGPUTextureFormat_RGBA8Unorm, width, height);
    defer renderer.deinit();
    var resources = try resources_mod.Resources.init(allocator);
    defer resources.deinit();
    try renderer.configureResources(&resources);
    var cache = bridge_mod.BridgeCache{};
    defer cache.deinit(allocator, &resources) catch {};

    var target = try gpu_scene.Scene.init(allocator, width, height);
    defer target.deinit();
    const bridge_start = std.Io.Clock.now(.awake, init.io);
    try bridge_mod.bridgeScene(allocator, &source, &target, null, null, &image_pixels, &.{}, &renderer, &resources, &cache);
    const bridge_ns = elapsedNs(bridge_start, std.Io.Clock.now(.awake, init.io));
    const render_start = std.Io.Clock.now(.awake, init.io);
    try renderer.renderWithResources(&target, view, null, .{ .clear = peniko.Color.fromRgba8(0, 0, 0, 255) }, .{}, null, &resources);
    const render_ns = elapsedNs(render_start, std.Io.Clock.now(.awake, init.io));

    var readback_desc = c.wgpu_zig_init_WGPUBufferDescriptor();
    readback_desc.label = wgpu.stringView("zui-offscreen-readback");
    readback_desc.size = @as(u64, bytes_per_row) * height;
    readback_desc.usage = c.WGPUBufferUsage_MapRead | c.WGPUBufferUsage_CopyDst;
    const readback = c.wgpuDeviceCreateBuffer(device.handle, &readback_desc) orelse return error.ReadbackBufferFailed;
    defer c.wgpuBufferRelease(readback);

    var encoder_desc = c.wgpu_zig_init_WGPUCommandEncoderDescriptor();
    encoder_desc.label = wgpu.stringView("zui-offscreen-copy");
    const encoder = c.wgpuDeviceCreateCommandEncoder(device.handle, &encoder_desc) orelse return error.EncoderFailed;
    defer c.wgpuCommandEncoderRelease(encoder);
    var copy_src: c.WGPUTexelCopyTextureInfo = .{ .texture = texture, .mipLevel = 0, .origin = .{ .x = 0, .y = 0, .z = 0 }, .aspect = c.WGPUTextureAspect_All };
    var copy_dst: c.WGPUTexelCopyBufferInfo = .{ .layout = .{ .offset = 0, .bytesPerRow = bytes_per_row, .rowsPerImage = height }, .buffer = readback };
    var copy_size = c.WGPUExtent3D{ .width = width, .height = height, .depthOrArrayLayers = 1 };
    c.wgpuCommandEncoderCopyTextureToBuffer(encoder, &copy_src, &copy_dst, &copy_size);
    var command_desc = c.wgpu_zig_init_WGPUCommandBufferDescriptor();
    command_desc.label = wgpu.stringView("zui-offscreen-copy-command");
    const command = c.wgpuCommandEncoderFinish(encoder, &command_desc) orelse return error.CommandFailed;
    defer c.wgpuCommandBufferRelease(command);
    const readback_start = std.Io.Clock.now(.awake, init.io);
    c.wgpuQueueSubmit(device.queue, 1, &command);

    var mapped = MapState{};
    _ = c.wgpuBufferMapAsync(readback, c.WGPUMapMode_Read, 0, @as(u64, bytes_per_row) * height, .{ .callback = &MapState.callback, .userdata1 = &mapped });
    _ = c.wgpuDevicePoll(device.handle, 1, null);
    if (!mapped.ok) return error.ReadbackMapFailed;
    defer c.wgpuBufferUnmap(readback);
    const raw = c.wgpuBufferGetMappedRange(readback, 0, @as(u64, bytes_per_row) * height) orelse return error.ReadbackRangeFailed;
    const gpu_pixels: [*]const u8 = @ptrCast(raw);
    const readback_ns = elapsedNs(readback_start, std.Io.Clock.now(.awake, init.io));

    var mismatches: usize = 0;
    var max_delta: u8 = 0;
    for (0..height) |y| for (0..width) |x| {
        const cpu_index = (y * width + x) * 4;
        const gpu_index = y * bytes_per_row + x * 4;
        for (0..4) |channel| {
            const delta = absDiff(cpu_pixels[cpu_index + channel], gpu_pixels[gpu_index + channel]);
            max_delta = @max(max_delta, delta);
            if (delta > 4) mismatches += 1;
        }
    };
    if (mismatches != 0) {
        for ([_]struct { x: usize, y: usize }{ .{ .x = 34, .y = 42 }, .{ .x = 40, .y = 48 }, .{ .x = 47, .y = 55 } }) |sample| {
            const ci = (sample.y * width + sample.x) * 4;
            const gi = sample.y * bytes_per_row + sample.x * 4;
            std.debug.print("sample ({d},{d}) cpu={any} gpu={any}\n", .{ sample.x, sample.y, cpu_pixels[ci .. ci + 4], gpu_pixels[gi .. gi + 4] });
        }
        std.debug.print("FAIL: CPU/WGPU offscreen differential pixels={d} max_delta={d} ({d} mismatches)\n", .{ width * height, max_delta, mismatches });
        return error.PixelDifferentialMismatch;
    }
    std.debug.print("PASS: CPU/WGPU offscreen differential pixels={d} max_delta={d} ({d} mismatches), cpu_us={d:.1} bridge_us={d:.1} render_us={d:.1} readback_us={d:.1}\n", .{
        width * height,
        max_delta,
        mismatches,
        @as(f64, @floatFromInt(cpu_ns)) / 1000.0,
        @as(f64, @floatFromInt(bridge_ns)) / 1000.0,
        @as(f64, @floatFromInt(render_ns)) / 1000.0,
        @as(f64, @floatFromInt(readback_ns)) / 1000.0,
    });
    _ = byte;
}
