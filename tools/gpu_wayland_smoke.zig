//! Opt-in native Wayland WGPU surface smoke test.
//!
//! This validates the App/Window surface handoff plus the scene bridge slice:
//! ordered solid/rounded quads, rectangular clips, paths, and bounded
//! glyph/image cache reuse. The ordinary ZUI renderer still defaults to CPU
//! Vellz frames; WGPU remains explicit opt-in.

const std = @import("std");
const zui = @import("zui");
const vellz = @import("vellz");
const wgpu = @import("wgpu");

const c = wgpu.c;
const WaylandBackend = zui.platform.wayland.WaylandBackend;
const backend = vellz.gpu.backend;
const gpu_scene = vellz.gpu.scene;
const peniko = vellz.peniko;
const paint = vellz.common.paint;
const gpu_resources = vellz.gpu.resources;
const bridge = zui.gpu.wgpu_bridge;

const width: u32 = 320;
const height: u32 = 240;
const clear_color: u32 = 0xff3377cc;

pub fn main(init: std.process.Init) !void {
    if (!WaylandBackend.isAvailable()) {
        std.debug.print("SKIP: no usable Wayland client connection\n", .{});
        return;
    }

    const allocator = init.gpa;
    var wl = WaylandBackend.init(allocator, "ZUI WGPU Surface Smoke", width, height) catch |err| {
        std.debug.print("SKIP: Wayland backend unavailable: {s}\n", .{@errorName(err)});
        return;
    };
    defer wl.deinit();

    // Exercise the real App -> Window -> native surface handoff. This is
    // deliberately separate from the lower-level bridge checks below: the
    // App owns the WGPU bridge here and Window.present() submits the complete
    // retained ZUI scene through it.
    var app = zui.App.initWithBackend(allocator, wl.backendHandle());
    defer app.deinit();
    app.setRendererMode(.wgpu);
    const app_window = try app.openWindow(.{ .title = "ZUI WGPU App Handoff", .bounds = .{
        .origin = .{ .x = 0, .y = 0 },
        .size = .{ .w = @floatFromInt(width), .h = @floatFromInt(height) },
    } }, struct {
        fn draw(_: *zui.Window, scene: *zui.Scene) void {
            _ = scene.push(.{ .x = 0, .y = 0, .w = @floatFromInt(width), .h = @floatFromInt(height), .color = .{ .r = 0.12, .g = 0.28, .b = 0.52, .a = 1 } });
            _ = scene.push(.{ .x = 24, .y = 24, .w = 120, .h = 72, .radius = 12, .color = .{ .r = 0.95, .g = 0.72, .b = 0.18, .a = 1 } });
        }
    }.draw);
    if (app_window.renderBackend().selection.active != .wgpu) return error.AppWgpuHandoffUnavailable;
    if (!app.step()) return error.AppWgpuStepDidNotPresent;
    if (app_window.renderBackend().presented == 0) return error.AppWgpuFrameNotPresented;
    std.debug.print("PASS: App/Window WGPU handoff presented a complete Wayland scene\n", .{});

    // The App handoff above owns a WGPU surface for `wl`. A compositor
    // rejects a second FIFO surface on the same wl_surface, so the lower-level
    // bridge smoke deliberately uses a second native Wayland connection.
    var bridge_wl = WaylandBackend.init(allocator, "ZUI WGPU Bridge Smoke", width, height) catch |err| {
        std.debug.print("SKIP: second Wayland connection unavailable: {s}\n", .{@errorName(err)});
        return;
    };
    defer bridge_wl.deinit();
    const bridge_wl_surface = bridge_wl.surface orelse return error.MissingBridgeWaylandSurface;

    var instance = try backend.Instance.create();
    defer instance.deinit();
    var adapter = try backend.Adapter.acquire(&instance, .{});
    defer adapter.deinit();
    var device = try backend.Device.acquire(allocator, &adapter, "zui-wayland-surface-smoke");
    defer device.deinit();

    var source = c.wgpu_zig_init_WGPUSurfaceSourceWaylandSurface();
    source.display = @ptrCast(bridge_wl.display);
    source.surface = @ptrCast(bridge_wl_surface);
    var surface_desc = c.wgpu_zig_init_WGPUSurfaceDescriptor();
    surface_desc.label = wgpu.stringView("zui-wayland-surface-smoke");
    surface_desc.nextInChain = &source.chain;
    const surface = c.wgpuInstanceCreateSurface(instance.handle, &surface_desc) orelse return error.SurfaceCreateFailed;
    defer c.wgpuSurfaceRelease(surface);

    var caps = c.wgpu_zig_init_WGPUSurfaceCapabilities();
    if (c.wgpuSurfaceGetCapabilities(surface, adapter.handle, &caps) != c.WGPUStatus_Success) {
        return error.SurfaceCapabilitiesFailed;
    }
    defer c.wgpuSurfaceCapabilitiesFreeMembers(caps);
    if (caps.formatCount == 0 or caps.formats == null) return error.NoSurfaceFormat;

    const format = caps.formats[0];
    var config = c.wgpu_zig_init_WGPUSurfaceConfiguration();
    config.device = device.handle;
    config.format = format;
    config.usage = c.WGPUTextureUsage_RenderAttachment;
    config.width = width;
    config.height = height;
    config.alphaMode = c.WGPUCompositeAlphaMode_Auto;
    config.presentMode = c.WGPUPresentMode_Fifo;
    c.wgpuSurfaceConfigure(surface, &config);

    var renderer = try backend.renderer.Renderer.init(allocator, &device, format, width, height);
    defer renderer.deinit();
    var resources = try gpu_resources.Resources.init(allocator);
    defer resources.deinit();
    try renderer.configureResources(&resources);
    var bridge_cache = bridge.BridgeCache{};
    defer bridge_cache.deinit(allocator, &resources) catch |err| {
        std.debug.print("bridge cache deinit failed: {s}\n", .{@errorName(err)});
    };

    // Exercise the same App/Window backend policy around the typed native
    // bridge. The controller is not responsible for WGPU object ownership;
    // it records frame retirement and keeps resize/minimize policy explicit.
    var lifecycle = zui.gpu.render_backend.Controller.init(
        zui.gpu.render_backend.select(.wgpu, true, true, true),
        width,
        height,
    );
    lifecycle.setMinimized(true);
    if (lifecycle.beginFrame() != null) return error.MinimizedFrameWasSubmitted;
    lifecycle.setMinimized(false);

    var image_bytes = [_]u8{
        0xff, 0x66, 0x33, 0xff, 0x33, 0xcc, 0x66, 0xff,
        0x33, 0x66, 0xcc, 0xff, 0xcc, 0x33, 0x99, 0xff,
    };
    var zui_scene = zui.Scene{};
    var zui_strokes: zui.StrokeStorage = undefined;
    zui_scene.attachStrokeStorage(&zui_strokes);
    var zui_paths: zui.gpu.PathStorage = undefined;
    zui_scene.attachPathStorage(&zui_paths);
    _ = zui_scene.push(.{
        .x = 0,
        .y = 0,
        .w = @floatFromInt(width),
        .h = @floatFromInt(height),
        .color = .{ .r = 0.2, .g = 0.47, .b = 0.8, .a = 1 },
    });
    _ = zui_scene.pushStroke(.{
        .from = .{ .x = 16, .y = 24 },
        .to = .{ .x = 304, .y = 24 },
        .color = .{ .r = 1, .g = 0.85, .b = 0.2, .a = 1 },
        .width = 3,
        .clip = .{ .x = 0, .y = 0, .w = @floatFromInt(width), .h = @floatFromInt(height) },
    });
    var smoke_path = zui.gpu.Path{ .color = .{ .r = 1, .g = 0.3, .b = 0.1, .a = 1 } };
    smoke_path.segments[0] = .{ .move_to = .{ .x = 24, .y = 40 } };
    smoke_path.segments[1] = .{ .line_to = .{ .x = 96, .y = 40 } };
    smoke_path.segments[2] = .{ .line_to = .{ .x = 60, .y = 96 } };
    smoke_path.segments[3] = .close;
    smoke_path.segment_len = 4;
    _ = zui_scene.pushGroup(.{
        .opacity = 0.8,
        .transform = .{ 1, 0, 0, 1, 4, 2 },
        .clip = .{ .rounded = .{ .rect = .{ .x = 8, .y = 8, .w = 300, .h = 160 }, .radius = 12 } },
    });
    _ = zui_scene.pushPath(smoke_path);
    _ = zui_scene.popGroup();
    _ = zui_scene.pushImage(.{
        .x = 120,
        .y = 80,
        .w = 80,
        .h = 80,
        .pool_offset = 0,
        .src_w = 2,
        .src_h = 2,
        .tint = .white,
        .clip = .{ .x = 120, .y = 80, .w = 80, .h = 80 },
    });
    _ = zui_scene.pushImage(.{
        .x = 220,
        .y = 80,
        .w = 80,
        .h = 80,
        .pool_offset = 0,
        .src_w = 2,
        .src_h = 2,
        .gray = true,
        .clip = .{ .x = 220, .y = 80, .w = 80, .h = 80 },
    });
    const color_atlas_offset = zui.core.limits.MAX_ATLAS_PIXELS;
    const glyph_pool = try allocator.alloc(u8, color_atlas_offset + 16);
    defer allocator.free(glyph_pool);
    @memset(glyph_pool, 0);
    glyph_pool[0..4].* = .{ 0, 255, 255, 0 };
    glyph_pool[color_atlas_offset .. color_atlas_offset + 16].* = .{
        255, 0, 0,   255, 0,   255, 0, 255,
        0,   0, 255, 255, 255, 255, 0, 255,
    };
    _ = zui_scene.pushGlyph(.{
        .x = 40,
        .y = 40,
        .w = 2,
        .h = 2,
        .color = .{ .r = 1, .g = 0.4, .b = 0.1, .a = 1 },
        .atlas_offset = 0,
        .density = 1,
        .clip = .{ .x = 40, .y = 40, .w = 2, .h = 2 },
    });
    _ = zui_scene.pushGlyph(.{
        .x = 48,
        .y = 40,
        .w = 2,
        .h = 2,
        .color = .white,
        .atlas_offset = @intCast(color_atlas_offset),
        .density = 1,
        .clip = .{ .x = 48, .y = 40, .w = 2, .h = 2 },
    });

    var presented: u32 = 0;
    for (0..3) |_| {
        const frame_id = lifecycle.beginFrame() orelse return error.NoSurfaceFrames;
        var current = c.wgpu_zig_init_WGPUSurfaceTexture();
        c.wgpuSurfaceGetCurrentTexture(surface, &current);
        switch (current.status) {
            c.WGPUSurfaceGetCurrentTextureStatus_SuccessOptimal,
            c.WGPUSurfaceGetCurrentTextureStatus_SuccessSuboptimal,
            => {},
            c.WGPUSurfaceGetCurrentTextureStatus_Outdated,
            c.WGPUSurfaceGetCurrentTextureStatus_Lost,
            => {
                c.wgpuSurfaceConfigure(surface, &config);
                continue;
            },
            else => return error.SurfaceAcquireFailed,
        }
        const texture = current.texture orelse return error.SurfaceTextureMissing;
        defer c.wgpuTextureRelease(texture);
        const view = try backend.wgpu.createFullView(texture, format, "zui-wayland-surface-view");
        defer c.wgpuTextureViewRelease(view);

        var scene = try gpu_scene.Scene.init(allocator, @intCast(width), @intCast(height));
        defer scene.deinit();
        try bridge.bridgeScene(allocator, &zui_scene, &scene, null, null, &image_bytes, glyph_pool, &renderer, &resources, &bridge_cache);
        try renderer.renderWithResources(&scene, view, null, .{ .clear = peniko.Color.fromRgba8(0, 0, 0, 255) }, .{}, null, &resources);
        try device.check();
        if (c.wgpuSurfacePresent(surface) != c.WGPUStatus_Success) return error.SurfacePresentFailed;
        lifecycle.recordPresented(frame_id);
        presented += 1;
    }

    if (presented == 0) return error.NoSurfaceFrames;
    std.debug.print("PASS: Wayland WGPU surface presented {d} bridged ZUI scene frame(s), format={d}, clear=0x{x}\n", .{ presented, format, clear_color });
}

test "solid quad bridge preserves order and handles clips and rounded paths" {
    var source = zui.Scene{};
    var source_strokes: zui.StrokeStorage = undefined;
    source.attachStrokeStorage(&source_strokes);
    try std.testing.expect(source.push(.{
        .x = 1,
        .y = 2,
        .w = 10,
        .h = 11,
        .color = .{ .r = 1, .g = 0, .b = 0, .a = 1 },
    }));
    try std.testing.expect(source.push(.{
        .x = 20,
        .y = 22,
        .w = 5,
        .h = 6,
        .color = .{ .r = 0, .g = 1, .b = 0, .a = 0.5 },
    }));

    var target = try gpu_scene.Scene.init(std.testing.allocator, 64, 64);
    defer target.deinit();
    try bridge.bridgeSceneCompat(std.testing.allocator, &source, &target, null, null, &.{}, &.{}, null, null);
    try std.testing.expectEqual(@as(usize, 2), target.recorder.draws.items.len);

    source.clear();
    try std.testing.expect(source.push(.{
        .x = 0,
        .y = 0,
        .w = 12,
        .h = 12,
        .clip = .{ .x = 2, .y = 2, .w = 4, .h = 4 },
        .color = .{ .r = 1, .g = 1, .b = 1, .a = 1 },
    }));
    try bridge.bridgeSceneCompat(std.testing.allocator, &source, &target, null, null, &.{}, &.{}, null, null);

    source.clear();
    try std.testing.expect(source.push(.{
        .x = 0,
        .y = 0,
        .w = 4,
        .h = 4,
        .radius = 2,
        .color = .{ .r = 1, .g = 1, .b = 1, .a = 1 },
    }));
    try bridge.bridgeSceneCompat(std.testing.allocator, &source, &target, null, null, &.{}, &.{}, null, null);
    try std.testing.expect(target.recorder.draws.items.len >= 4);

    source.clear();
    try std.testing.expect(source.push(.{
        .x = 0,
        .y = 0,
        .w = 4,
        .h = 4,
        .border_width = 1,
        .color = .{ .r = 1, .g = 0, .b = 0, .a = 1 },
    }));
    try bridge.bridgeSceneCompat(std.testing.allocator, &source, &target, null, null, &.{}, &.{}, null, null);
    try std.testing.expect(target.recorder.draws.items.len >= 5);

    source.clear();
    try std.testing.expect(source.push(.{
        .x = 0,
        .y = 0,
        .w = 4,
        .h = 4,
        .gradient_to = .{ .r = 0, .g = 0, .b = 1, .a = 1 },
        .color = .{ .r = 1, .g = 0, .b = 0, .a = 1 },
    }));
    try bridge.bridgeSceneCompat(std.testing.allocator, &source, &target, null, null, &.{}, &.{}, null, null);
    switch (target.currentPaint()) {
        .gradient => |gradient| try std.testing.expectEqual(@as(usize, 2), gradient.stops.len()),
        else => return error.GradientBridgeDidNotProduceGradient,
    }

    source.clear();
    try std.testing.expect(source.pushImage(.{
        .x = 1,
        .y = 1,
        .w = 8,
        .h = 8,
        .pool_offset = 0,
        .src_w = 2,
        .src_h = 2,
        .src_x = 0.5,
        .src_y = 0.5,
        .src_crop_w = 1,
        .src_crop_h = 1,
        .gray = true,
        .tint = .{ .r = 0.8, .g = 1, .b = 0.9, .a = 0.75 },
        .rotation = 0.1,
        .scale_x = 0.8,
        .scale_y = 0.9,
        .translate_x = 1,
        .translate_y = -2,
        .radius = 2,
        .clip = .{ .x = 1, .y = 1, .w = 8, .h = 8 },
    }));
    var source_pixels: [16]u8 = @splat(255);
    try bridge.bridgeSceneCompat(std.testing.allocator, &source, &target, paint.ImageId.new(7), paint.ImageId.new(8), &source_pixels, &.{}, null, null);
    try std.testing.expectError(error.InvalidImagePoolReference, bridge.bridgeSceneCompat(std.testing.allocator, &source, &target, paint.ImageId.new(7), paint.ImageId.new(8), &.{}, &.{}, null, null));

    source.clear();
    try std.testing.expect(source.pushStroke(.{
        .from = .{ .x = 4, .y = 8 },
        .to = .{ .x = 48, .y = 8 },
        .color = .{ .r = 1, .g = 0.8, .b = 0.1, .a = 1 },
        .width = 2,
        .clip = .{ .x = 10, .y = 0, .w = 20, .h = 20 },
    }));
    const draws_before_stroke = target.recorder.draws.items.len;
    try bridge.bridgeSceneCompat(std.testing.allocator, &source, &target, null, null, &.{}, &.{}, null, null);
    try std.testing.expect(target.recorder.draws.items.len > draws_before_stroke);
}

test "glyph bridge cache reuses entries, releases owned ids, and rejects invalid pools" {
    const allocator = std.testing.allocator;
    var instance = try backend.Instance.create();
    defer instance.deinit();
    var adapter = try backend.Adapter.acquire(&instance, .{});
    defer adapter.deinit();
    var device = try backend.Device.acquire(allocator, &adapter, "zui-glyph-cache-test");
    defer device.deinit();
    var renderer = try backend.renderer.Renderer.init(allocator, &device, c.WGPUTextureFormat_RGBA8Unorm, 64, 64);
    defer renderer.deinit();
    var resources = try gpu_resources.Resources.init(allocator);
    defer resources.deinit();
    try renderer.configureResources(&resources);

    var source = zui.Scene{};
    try std.testing.expect(source.pushGlyph(.{
        .x = 4,
        .y = 5,
        .w = 2,
        .h = 2,
        .color = .white,
        .atlas_offset = 0,
        .density = 1,
        .clip = .{ .x = 0, .y = 0, .w = 16, .h = 16 },
    }));
    var glyph_pool = [_]u8{ 0, 64, 192, 255 };
    var target = try gpu_scene.Scene.init(allocator, 64, 64);
    defer target.deinit();
    var cache = bridge.BridgeCache{};
    defer cache.deinit(allocator, &resources) catch unreachable;

    try bridge.bridgeScene(allocator, &source, &target, null, null, &.{}, &glyph_pool, &renderer, &resources, &cache);
    try std.testing.expectEqual(@as(usize, 1), cache.len());
    try std.testing.expectEqual(@as(usize, 1), cache.uploadCount());
    const owned_id = cache.entries[0].image_id;
    try std.testing.expect(resources.image_cache.get(owned_id) != null);

    try target.reset();
    try bridge.bridgeScene(allocator, &source, &target, null, null, &.{}, &glyph_pool, &renderer, &resources, &cache);
    try std.testing.expectEqual(@as(usize, 1), cache.len());
    try std.testing.expectEqual(@as(usize, 1), cache.uploadCount());
    try std.testing.expectEqual(owned_id, cache.entries[0].image_id);

    source.clear();
    try std.testing.expect(source.pushGlyph(.{
        .x = 0,
        .y = 0,
        .w = 2,
        .h = 2,
        .color = .white,
        .atlas_offset = 1,
        .density = 1,
        .clip = .{ .x = 0, .y = 0, .w = 4, .h = 4 },
    }));
    try std.testing.expectError(
        error.InvalidGlyphPoolReference,
        bridge.bridgeScene(allocator, &source, &target, null, null, &.{}, &glyph_pool, &renderer, &resources, &cache),
    );
    try std.testing.expectEqual(@as(usize, 1), cache.len());
    try std.testing.expect(resources.image_cache.get(owned_id) != null);

    try cache.deinit(allocator, &resources);
    try std.testing.expectEqual(@as(usize, 0), cache.len());
    try std.testing.expect(resources.image_cache.get(owned_id) == null);
}

test "image bridge cache reuses normal and grayscale uploads and releases them" {
    const allocator = std.testing.allocator;
    var instance = try backend.Instance.create();
    defer instance.deinit();
    var adapter = try backend.Adapter.acquire(&instance, .{});
    defer adapter.deinit();
    var device = try backend.Device.acquire(allocator, &adapter, "zui-image-cache-test");
    defer device.deinit();
    var renderer = try backend.renderer.Renderer.init(allocator, &device, c.WGPUTextureFormat_RGBA8Unorm, 64, 64);
    defer renderer.deinit();
    var resources = try gpu_resources.Resources.init(allocator);
    defer resources.deinit();
    try renderer.configureResources(&resources);

    var source = zui.Scene{};
    try std.testing.expect(source.pushImage(.{
        .x = 2,
        .y = 3,
        .w = 16,
        .h = 16,
        .pool_offset = 0,
        .src_w = 2,
        .src_h = 2,
        .clip = .{ .x = 0, .y = 0, .w = 32, .h = 32 },
    }));
    try std.testing.expect(source.pushImage(.{
        .x = 20,
        .y = 3,
        .w = 16,
        .h = 16,
        .pool_offset = 0,
        .src_w = 2,
        .src_h = 2,
        .gray = true,
        .clip = .{ .x = 0, .y = 0, .w = 32, .h = 32 },
    }));
    var image_pool = [_]u8{
        0xff, 0x66, 0x33, 0xff, 0x33, 0xcc, 0x66, 0xff,
        0x33, 0x66, 0xcc, 0xff, 0xcc, 0x33, 0x99, 0xff,
    };
    var target = try gpu_scene.Scene.init(allocator, 64, 64);
    defer target.deinit();
    var cache = bridge.BridgeCache{};
    defer cache.deinit(allocator, &resources) catch unreachable;

    try bridge.bridgeScene(allocator, &source, &target, null, null, &image_pool, &.{}, &renderer, &resources, &cache);
    try std.testing.expectEqual(@as(usize, 2), cache.imageLen());
    try std.testing.expectEqual(@as(usize, 2), cache.uploadCount());
    const normal_id = cache.image_entries[0].image_id;
    const gray_id = cache.image_entries[1].image_id;
    try std.testing.expect(normal_id.asU32() != gray_id.asU32());
    try std.testing.expect(resources.image_cache.get(normal_id) != null);
    try std.testing.expect(resources.image_cache.get(gray_id) != null);

    try target.reset();
    try bridge.bridgeScene(allocator, &source, &target, null, null, &image_pool, &.{}, &renderer, &resources, &cache);
    try std.testing.expectEqual(@as(usize, 2), cache.imageLen());
    try std.testing.expectEqual(@as(usize, 2), cache.uploadCount());
    try std.testing.expectEqual(normal_id, cache.image_entries[0].image_id);
    try std.testing.expectEqual(gray_id, cache.image_entries[1].image_id);

    source.clear();
    try std.testing.expect(source.pushImage(.{
        .x = 0,
        .y = 0,
        .w = 4,
        .h = 4,
        .pool_offset = 1,
        .src_w = 2,
        .src_h = 2,
        .clip = .{ .x = 0, .y = 0, .w = 4, .h = 4 },
    }));
    try std.testing.expectError(
        error.InvalidImagePoolReference,
        bridge.bridgeScene(allocator, &source, &target, null, null, &image_pool, &.{}, &renderer, &resources, &cache),
    );
    try std.testing.expectEqual(@as(usize, 2), cache.imageLen());
    try std.testing.expectEqual(@as(usize, 2), cache.uploadCount());
    try std.testing.expect(resources.image_cache.get(normal_id) != null);
    try std.testing.expect(resources.image_cache.get(gray_id) != null);

    image_pool[0] ^= 1;
    source.clear();
    try std.testing.expect(source.pushImage(.{
        .x = 0,
        .y = 0,
        .w = 4,
        .h = 4,
        .pool_offset = 0,
        .src_w = 2,
        .src_h = 2,
        .clip = .{ .x = 0, .y = 0, .w = 4, .h = 4 },
    }));
    try target.reset();
    try bridge.bridgeScene(allocator, &source, &target, null, null, &image_pool, &.{}, &renderer, &resources, &cache);
    try std.testing.expectEqual(@as(usize, 3), cache.uploadCount());
    try std.testing.expectEqual(@as(usize, 3), cache.imageLen());

    try cache.deinit(allocator, &resources);
    try std.testing.expectEqual(@as(usize, 0), cache.imageLen());
    try std.testing.expect(resources.image_cache.get(normal_id) == null);
    try std.testing.expect(resources.image_cache.get(gray_id) == null);
}

test "path and shadow bridge preserves bounded scene primitives" {
    const allocator = std.testing.allocator;
    var source = zui.Scene{};
    const path_storage = try allocator.create(zui.gpu.PathStorage);
    defer allocator.destroy(path_storage);
    const shadow_storage = try allocator.create(zui.gpu.ShadowStorage);
    defer allocator.destroy(shadow_storage);
    source.attachPathStorage(path_storage);
    source.attachShadowStorage(shadow_storage);

    var path = zui.gpu.Path{ .color = zui.Color.white, .clip = .{ .x = 0, .y = 0, .w = 32, .h = 32 } };
    path.segments[0] = .{ .move_to = .{ .x = 2, .y = 2 } };
    path.segments[1] = .{ .line_to = .{ .x = 30, .y = 2 } };
    path.segments[2] = .{ .line_to = .{ .x = 16, .y = 28 } };
    path.segments[3] = .close;
    path.segment_len = 4;
    try std.testing.expect(source.pushGroup(.{
        .opacity = 0.75,
        .transform = .{ 1, 0, 0, 1, 1, 2 },
        .clip = .{ .rounded = .{ .rect = .{ .x = 0, .y = 0, .w = 32, .h = 32 }, .radius = 4 } },
    }));
    try std.testing.expect(source.pushPath(path));
    try std.testing.expect(source.popGroup());
    try std.testing.expect(source.pushShadow(.{
        .bounds = .{ .x = 2, .y = 2, .w = 28, .h = 26 },
        .radius = 3,
        .blur_radius = 2,
        .offset_y = 1,
        .color = .{ .r = 0, .g = 0, .b = 0, .a = 0.5 },
    }));

    var target = try gpu_scene.Scene.init(allocator, 32, 32);
    defer target.deinit();
    try bridge.bridgeScene(allocator, &source, &target, null, null, &.{}, &.{}, null, null, null);
    try std.testing.expectEqual(@as(usize, 4), source.commandSlice().len);
}

test "GPU damage and loss policy stay bounded and deterministic" {
    var damage = zui.gpu.DamageSet{};
    damage.invalidate(.{ .x = 1, .y = 2, .w = 3, .h = 4 });
    try std.testing.expectEqual(@as(usize, 1), damage.slice().len);
    damage.invalidateFull(.{ .x = 0, .y = 0, .w = 64, .h = 64 });
    try std.testing.expect(damage.full);

    var recovery = zui.gpu.device.RecoveryPolicy{};
    recovery.observe(error.DeviceLost);
    try std.testing.expectEqual(zui.gpu.device.RecoveryState.recreate, recovery.state);
    recovery.observe(error.DeviceLost);
    try std.testing.expect(recovery.usingSoftware());
}
