//! Offscreen GPU smoke test (M5/T1): acquire a device through the wgpu
//! backend, clear a 64x64 `Rgba8Unorm` texture through the checked-in clear
//! WGSL, read it back, assert every pixel, and release every handle.
//!
//! Run with: `zig build -Dgpu=true run-gpu-smoke`
//! Failure path: `zig build -Dgpu=true run-gpu-smoke-failure`
//! (`--force-adapter-failure` must return `error.NoAdapter` and exit 1.)

const std = @import("std");
const vellz = @import("vellz");
const wgpu = @import("wgpu");
const c = wgpu.c;

const backend = vellz.gpu.backend;
const render = vellz.gpu.render;

const width = 64;
const height = 64;

/// Premultiplied RGBA8 clear color, r least significant (WGSL
/// `unpack4x8unorm` lane order). Fully opaque, so it doubles as the expected
/// readback bytes: [0x40, 0x80, 0xBF, 0xFF].
const clear_color_u32: u32 = 0xFFBF8040;
const expected_pixel = [4]u8{ 0x40, 0x80, 0xBF, 0xFF };

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;

    var args = std.process.Args.Iterator.init(init.minimal.args);
    defer args.deinit();
    _ = args.skip(); // program name
    var force_adapter_failure = false;
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--force-adapter-failure")) {
            force_adapter_failure = true;
        }
    }

    c.wgpuSetLogCallback(&logCallback, null);
    c.wgpuSetLogLevel(c.WGPULogLevel_Warn);

    var instance = try backend.Instance.create();
    defer instance.deinit();

    var adapter = try backend.Adapter.acquire(&instance, .{
        .force_failure = force_adapter_failure,
    });
    defer adapter.deinit();
    if (force_adapter_failure) {
        // `Adapter.acquire` must never succeed with the Null backend.
        std.debug.print("FAIL: forced adapter failure unexpectedly returned an adapter\n", .{});
        return error.ForceAdapterFailureDidNotFail;
    }
    adapter.info.print();

    var dev = try backend.Device.acquire(allocator, &adapter, "vellz-gpu-smoke");
    defer dev.deinit();

    const limits = try dev.getLimits();
    std.debug.print("device: maxTextureDimension2D={d}\n", .{limits.max_texture_dimension_2d});
    if (limits.max_texture_dimension_2d < width or limits.max_texture_dimension_2d < height) {
        std.debug.print(
            "FAIL: adapter limit {d} is below the required {d}x{d}\n",
            .{ limits.max_texture_dimension_2d, width, height },
        );
        return error.UnsupportedCapability;
    }

    dev.pushErrorScope(c.WGPUErrorFilter_Validation);

    const texture = try backend.wgpu.createTexture2d(
        &dev,
        width,
        height,
        c.WGPUTextureFormat_RGBA8Unorm,
        c.WGPUTextureUsage_RenderAttachment | c.WGPUTextureUsage_CopySrc,
        "vellz-gpu-smoke-color",
    );
    defer c.wgpuTextureRelease(texture);

    const view = try backend.wgpu.createFullView(texture, c.WGPUTextureFormat_RGBA8Unorm, "vellz-gpu-smoke-view");
    defer c.wgpuTextureViewRelease(view);

    var pipeline = try backend.wgpu.ClearPipeline.create(&dev, c.WGPUTextureFormat_RGBA8Unorm, "vellz-gpu-smoke-clear");
    defer pipeline.deinit();

    const instances = [_]render.GpuClearInstance{
        render.GpuClearInstance.new(.{ 0, 0 }, .{ width, height }, .{ width, height }, clear_color_u32),
    };
    try backend.wgpu.clearTexture(
        &dev,
        view,
        c.WGPUTextureFormat_RGBA8Unorm,
        &pipeline,
        &instances,
    );
    try dev.popErrorScope();

    const pixels = try backend.readback.readTexture(allocator, &dev, texture, width, height);
    defer allocator.free(pixels);

    if (pixels.len != @as(usize, width) * height * 4) {
        std.debug.print("FAIL: readback returned {d} bytes\n", .{pixels.len});
        return error.PixelCountMismatch;
    }
    var mismatches: usize = 0;
    for (0..height) |y| {
        for (0..width) |x| {
            const at = (y * width + x) * 4;
            const pixel = pixels[at..][0..4];
            if (!std.mem.eql(u8, pixel, &expected_pixel)) {
                if (mismatches < 4) {
                    std.debug.print("FAIL: pixel ({d},{d}) = {any}, expected {any}\n", .{
                        x, y, pixel, expected_pixel,
                    });
                }
                mismatches += 1;
            }
        }
    }
    if (mismatches != 0) {
        std.debug.print("FAIL: {d} of {d} pixels differ from the clear color\n", .{
            mismatches, width * height,
        });
        return error.PixelMismatch;
    }
    std.debug.print(
        "pixels: all {d} match clear color {x:0>8} ({any})\n",
        .{ width * height, clear_color_u32, expected_pixel },
    );

    // No uncaptured errors and no device loss, and a clean final poll.
    try dev.check();
    if (!dev.poll()) {
        std.debug.print("FAIL: final wgpuDevicePoll failed\n", .{});
        return error.PollFailed;
    }

    std.debug.print("PASS: offscreen clear + readback verified (all handles released)\n", .{});
}

fn logCallback(level: c.WGPULogLevel, message: c.WGPUStringView, userdata: ?*anyopaque) callconv(.c) void {
    _ = userdata;
    const name = switch (level) {
        c.WGPULogLevel_Error => "error",
        c.WGPULogLevel_Warn => "warn",
        c.WGPULogLevel_Info => "info",
        c.WGPULogLevel_Debug => "debug",
        c.WGPULogLevel_Trace => "trace",
        else => "log",
    };
    std.debug.print("[wgpu-native/{s}] {s}\n", .{ name, backend.messageSlice(message) });
}
