//! GPU error-policy tests (M5 T5): unsupported capabilities and device loss
//! must return typed errors, and every later call must fail instead of
//! falling back to the CPU path.
//!
//! Run with: `zig build -Dgpu=true run-gpu-errors`
//!
//! Checks:
//! 1. `Renderer.init` with a target larger than the device's resource texture
//!    dimension returns `error.UnsupportedCapability`.
//! 2. After `wgpuDeviceDestroy`, the device-lost callback flips the wrapper to
//!    lost and `Device.check` / `Renderer.render` return `error.DeviceLost`.
//! 3. The forced-adapter-failure path returns `error.NoAdapter` (duplicated
//!    from the smoke test so this executable is a single error-policy gate).
//! 4. Image paints reject unbound textures (`error.MissingTextureBinding`)
//!    and textures that are also the render target
//!    (`error.TextureFeedbackLoop`).

const std = @import("std");
const vellz = @import("vellz");
const wgpu = @import("wgpu");
const c = wgpu.c;

const backend = vellz.gpu.backend;
const gpu_scene = vellz.gpu.scene;

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;

    var failed = false;

    // 1. Unsupported capability: an oversized target must be rejected before
    // any resource is created.
    {
        var instance = try backend.Instance.create();
        defer instance.deinit();
        var adapter = try backend.Adapter.acquire(&instance, .{});
        defer adapter.deinit();
        var dev = try backend.Device.acquire(allocator, &adapter, "vellz-gpu-errors-limits");
        const limits = try dev.getLimits();
        const too_large = @min(limits.max_texture_dimension_2d, 4096) + 1;
        const result = backend.renderer.Renderer.init(
            allocator,
            &dev,
            c.WGPUTextureFormat_RGBA8Unorm,
            too_large,
            64,
        );
        if (result) |*renderer| {
            var owned = renderer.*;
            owned.deinit();
            std.debug.print("FAIL: {d}x64 target was accepted above the resource limit\n", .{too_large});
            failed = true;
        } else |err| {
            if (err != error.UnsupportedCapability) {
                std.debug.print("FAIL: oversized target returned {s}, expected UnsupportedCapability\n", .{@errorName(err)});
                failed = true;
            } else {
                std.debug.print("PASS: oversized target -> error.UnsupportedCapability\n", .{});
            }
        }
        dev.deinit();
    }

    // 2. Device loss: destroy the device, poll, then require DeviceLost from
    // both the device wrapper and a render attempt.
    {
        var instance = try backend.Instance.create();
        defer instance.deinit();
        var adapter = try backend.Adapter.acquire(&instance, .{});
        defer adapter.deinit();
        var dev = try backend.Device.acquire(allocator, &adapter, "vellz-gpu-errors-loss");

        var renderer = try backend.renderer.Renderer.init(
            allocator,
            &dev,
            c.WGPUTextureFormat_RGBA8Unorm,
            64,
            64,
        );
        defer renderer.deinit();

        const texture = try backend.wgpu.createTexture2d(
            &dev,
            64,
            64,
            c.WGPUTextureFormat_RGBA8Unorm,
            c.WGPUTextureUsage_RenderAttachment | c.WGPUTextureUsage_CopySrc,
            "vellz-gpu-errors-target",
        );
        defer c.wgpuTextureRelease(texture);
        const view = try backend.wgpu.createFullView(
            texture,
            c.WGPUTextureFormat_RGBA8Unorm,
            "vellz-gpu-errors-target-view",
        );
        defer c.wgpuTextureViewRelease(view);

        c.wgpuDeviceDestroy(dev.handle);

        var scene = try gpu_scene.Scene.init(allocator, 64, 64);
        defer scene.deinit();

        // First attempt a render on the destroyed device. wgpu-native routes
        // the core `DeviceError::Lost` through the error sink on use, which
        // fires the device-lost callback; the render must surface
        // `error.DeviceLost`, never a CPU fallback.
        const result = renderer.render(
            &scene,
            view,
            null,
            .{ .clear = vellz.peniko.color.Color.TRANSPARENT },
        );
        if (result) |_| {
            std.debug.print("FAIL: renderer accepted a scene on a destroyed device\n", .{});
            failed = true;
        } else |err| {
            if (err != error.DeviceLost) {
                std.debug.print("FAIL: destroyed-device render returned {s}, expected DeviceLost\n", .{@errorName(err)});
                failed = true;
            } else {
                std.debug.print("PASS: destroyed-device render -> error.DeviceLost\n", .{});
            }
        }

        _ = dev.poll();
        if (!dev.isLost()) {
            std.debug.print("FAIL: device-lost callback did not fire after wgpuDeviceDestroy\n", .{});
            failed = true;
        } else if (dev.check()) |_| {
            std.debug.print("FAIL: Device.check succeeded on a destroyed device\n", .{});
            failed = true;
        } else |err| {
            if (err != error.DeviceLost) {
                std.debug.print("FAIL: Device.check returned {s}, expected DeviceLost\n", .{@errorName(err)});
                failed = true;
            } else {
                std.debug.print("PASS: destroyed device -> error.DeviceLost\n", .{});
            }
        }

        dev.deinit();
    }

    // 4. Image-binding policy: an image paint with no bound texture fails
    // with `MissingTextureBinding`, and a texture that is also the render
    // target fails with `TextureFeedbackLoop`. Both are emitted before any
    // command is submitted and never fall back to a CPU path.
    {
        var instance = try backend.Instance.create();
        defer instance.deinit();
        var adapter = try backend.Adapter.acquire(&instance, .{});
        defer adapter.deinit();
        var dev = try backend.Device.acquire(allocator, &adapter, "vellz-gpu-errors-bindings");
        defer dev.deinit();

        var renderer = try backend.renderer.Renderer.init(
            allocator,
            &dev,
            c.WGPUTextureFormat_RGBA8Unorm,
            64,
            64,
        );
        defer renderer.deinit();

        const target = try backend.wgpu.createTexture2d(
            &dev,
            64,
            64,
            c.WGPUTextureFormat_RGBA8Unorm,
            c.WGPUTextureUsage_RenderAttachment | c.WGPUTextureUsage_CopySrc,
            "vellz-gpu-errors-image-target",
        );
        defer c.wgpuTextureRelease(target);
        const target_view = try backend.wgpu.createFullView(
            target,
            c.WGPUTextureFormat_RGBA8Unorm,
            "vellz-gpu-errors-image-target-view",
        );
        defer c.wgpuTextureViewRelease(target_view);

        var scene = try gpu_scene.Scene.init(allocator, 64, 64);
        defer scene.deinit();
        const source = try vellz.common.paint.ImageSource.initExternalTexture(
            vellz.common.paint.TextureId.new(42),
            vellz.common.geometry.RectU16.new(0, 0, 1, 1),
            true,
        );
        scene.setPaint(vellz.common.paint.PaintType.fromImage(.{
            .image = source,
            .sampler = .{},
        }));
        try scene.fillRect(&vellz.kurbo.Rect.new(0, 0, 64, 64));

        const missing = renderer.renderWithBindings(
            &scene,
            target_view,
            null,
            .{ .clear = vellz.peniko.color.Color.TRANSPARENT },
            .{},
            target,
        );
        if (missing) |_| {
            std.debug.print("FAIL: unbound image texture was accepted\n", .{});
            failed = true;
        } else |err| {
            if (err != error.MissingTextureBinding) {
                std.debug.print("FAIL: unbound image returned {s}, expected MissingTextureBinding\n", .{@errorName(err)});
                failed = true;
            } else {
                std.debug.print("PASS: unbound image -> error.MissingTextureBinding\n", .{});
            }
        }

        const entries = [_]backend.renderer.TextureBindings.Entry{.{
            .id = 42,
            .texture = .{ .view = target_view, .texture = target },
        }};
        const feedback = renderer.renderWithBindings(
            &scene,
            target_view,
            null,
            .{ .clear = vellz.peniko.color.Color.TRANSPARENT },
            .{ .entries = &entries },
            target,
        );
        if (feedback) |_| {
            std.debug.print("FAIL: feedback-loop image texture was accepted\n", .{});
            failed = true;
        } else |err| {
            if (err != error.TextureFeedbackLoop) {
                std.debug.print("FAIL: feedback-loop image returned {s}, expected TextureFeedbackLoop\n", .{@errorName(err)});
                failed = true;
            } else {
                std.debug.print("PASS: feedback-loop image -> error.TextureFeedbackLoop\n", .{});
            }
        }
    }

    // 3. Forced adapter failure (same contract as the smoke test).
    {
        var instance = try backend.Instance.create();
        defer instance.deinit();
        const result = backend.Adapter.acquire(&instance, .{ .force_failure = true });
        if (result) |*adapter| {
            var owned = adapter.*;
            owned.deinit();
            std.debug.print("FAIL: forced adapter failure returned an adapter\n", .{});
            failed = true;
        } else |err| {
            if (err != error.NoAdapter) {
                std.debug.print("FAIL: forced adapter failure returned {s}, expected NoAdapter\n", .{@errorName(err)});
                failed = true;
            } else {
                std.debug.print("PASS: forced adapter failure -> error.NoAdapter\n", .{});
            }
        }
    }

    if (failed) return error.GpuErrorPolicyFailed;
    std.debug.print("PASS: GPU error policy (capability, device loss, adapter failure, image bindings)\n", .{});
}
