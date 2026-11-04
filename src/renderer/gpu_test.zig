//! Renders the same scenes with the GPU and CPU renderers and compares every pixel.
//! The CPU renderer is the reference (it follows GPUI's WGSL literally), so this also
//! proves the shaders and the instance packing. Skipped where no Vulkan 1.3 device exists.
//! `ZUI_GPU_TEST_DUMP=dir` writes each pair as PPM for inspection.
const std = @import("std");
const testing = std.testing;
const gpu = @import("../gpu/root.zig");
const vulkan = @import("vulkan.zig");
const gpu_renderer = @import("gpu.zig");
const cpu = @import("cpu.zig");
const scene = @import("../scene.zig");
const atlas = @import("../atlas.zig");
const color = @import("../color.zig");
const geometry = @import("../geometry.zig");

const Scene = scene.Scene;
const ScaledPixels = geometry.ScaledPixels;

fn rect(x: f32, y: f32, w: f32, h: f32) geometry.Bounds(ScaledPixels) {
    return .{ .origin = .{ .x = x, .y = y }, .size = .{ .width = w, .height = h } };
}

fn mask(x: f32, y: f32, w: f32, h: f32) scene.ContentMask(ScaledPixels) {
    return .{ .bounds = rect(x, y, w, h) };
}

const Tiles = struct { mono: atlas.AtlasTile, poly: atlas.AtlasTile, odd: atlas.AtlasTile };
const SceneFn = *const fn (*Scene, Tiles) anyerror!void;

/// Inserts the same tile bytes into either atlas.
fn insert_tiles(a: anytype) !Tiles {
    var mono_bytes: [16 * 16]u8 = undefined;
    for (&mono_bytes, 0..) |*b, i| b.* = @intCast(((i % 16) * 17) & 0xff);
    var poly_bytes: [16 * 16 * 4]u8 = undefined;
    for (0..16) |y| for (0..16) |x| {
        poly_bytes[(y * 16 + x) * 4 ..][0..4].* = .{ @intCast(x * 17), @intCast(y * 17), 128, 255 };
    };
    // Width 5: rows are padded in the staging data, as for most glyphs.
    var odd_bytes: [5 * 7]u8 = undefined;
    for (&odd_bytes, 0..) |*b, i| b.* = if ((i % 5 + i / 5) % 2 == 0) 255 else 40;
    return .{
        .odd = try a.insert(.monochrome, .{ .width = 5, .height = 7 }, &odd_bytes),
        .mono = try a.insert(.monochrome, .{ .width = 16, .height = 16 }, &mono_bytes),
        .poly = try a.insert(.polychrome, .{ .width = 16, .height = 16 }, &poly_bytes),
    };
}

fn scene_solid(sc: *Scene, _: Tiles) !void {
    try sc.insert_primitive(.{ .quad = .{ .bounds = rect(10, 10, 60, 40), .content_mask = mask(0, 0, 128, 128), .background = color.solid_background(color.red()) } });
    try sc.insert_primitive(.{ .quad = .{ .bounds = rect(40, 30, 60, 60), .content_mask = mask(0, 0, 128, 128), .background = color.solid_background(color.hsla(0.6, 0.8, 0.5, 0.5)) } });
}

fn scene_rounded_border(sc: *Scene, _: Tiles) !void {
    try sc.insert_primitive(.{ .quad = .{
        .bounds = rect(14, 14, 100, 100),
        .content_mask = mask(0, 0, 128, 128),
        .background = color.solid_background(color.hsla(0.3, 0.7, 0.5, 1)),
        .border_color = color.hsla(0.9, 0.8, 0.4, 1),
        .border_widths = .{ .top = 4, .right = 2, .bottom = 6, .left = 3 },
        .corner_radii = .{ .top_left = 20, .top_right = 8, .bottom_right = 30, .bottom_left = 0 },
    } });
}

fn scene_clip(sc: *Scene, _: Tiles) !void {
    try sc.insert_primitive(.{ .quad = .{ .bounds = rect(0, 0, 128, 128), .content_mask = mask(20, 30, 50, 40), .background = color.solid_background(color.white()) } });
}

fn scene_gradient(sc: *Scene, _: Tiles) !void {
    const stops = [2]color.LinearColorStop{ .{ .color = color.red(), .percentage = 0 }, .{ .color = color.blue(), .percentage = 1 } };
    try sc.insert_primitive(.{ .quad = .{ .bounds = rect(8, 8, 112, 112), .content_mask = mask(0, 0, 128, 128), .background = color.linear_gradient(45, stops[0], stops[1]) } });
}

fn scene_pattern(sc: *Scene, _: Tiles) !void {
    try sc.insert_primitive(.{ .quad = .{ .bounds = rect(4, 4, 120, 60), .content_mask = mask(0, 0, 128, 128), .background = color.pattern_slash(color.red(), 2, 5) } });
    try sc.insert_primitive(.{ .quad = .{ .bounds = rect(4, 70, 120, 50), .content_mask = mask(0, 0, 128, 128), .background = color.checkerboard(color.white(), 7) } });
}

fn scene_shadow(sc: *Scene, _: Tiles) !void {
    try sc.insert_primitive(.{ .quad = .{ .bounds = rect(0, 0, 128, 128), .content_mask = mask(0, 0, 128, 128), .background = color.solid_background(color.white()) } });
    try sc.insert_primitive(.{ .shadow = .{
        .bounds = rect(24, 24, 80, 80),
        .corner_radii = .{ .top_left = 8, .top_right = 8, .bottom_right = 8, .bottom_left = 8 },
        .content_mask = mask(0, 0, 128, 128),
        .color = color.hsla(0, 0, 0, 0.6),
        .blur_radius = 12,
    } });
}

fn scene_underline(sc: *Scene, _: Tiles) !void {
    try sc.insert_primitive(.{ .underline = .{ .bounds = rect(10, 20, 100, 2), .content_mask = mask(0, 0, 128, 128), .color = color.white(), .thickness = 2 } });
    try sc.insert_primitive(.{ .underline = .{ .bounds = rect(10, 60, 100, 8), .content_mask = mask(0, 0, 128, 128), .color = color.white(), .thickness = 2, .wavy = .{ .value = 1 } } });
}

fn scene_sprites(sc: *Scene, tiles: Tiles) !void {
    try sc.insert_primitive(.{ .monochrome_sprite = .{ .tile = tiles.mono, .bounds = rect(8, 8, 16, 16), .content_mask = mask(0, 0, 128, 128), .color = color.hsla(0.15, 0.9, 0.6, 1) } });
    try sc.insert_primitive(.{ .monochrome_sprite = .{ .tile = tiles.odd, .bounds = rect(8, 40, 5, 7), .content_mask = mask(0, 0, 128, 128), .color = color.white() } });
    try sc.insert_primitive(.{ .polychrome_sprite = .{ .tile = tiles.poly, .bounds = rect(40, 8, 16, 16), .content_mask = mask(0, 0, 128, 128) } });
    try sc.insert_primitive(.{ .polychrome_sprite = .{ .tile = tiles.poly, .bounds = rect(72, 8, 16, 16), .content_mask = mask(0, 0, 128, 128), .opacity = 0.5, .grayscale = .{ .value = 1 } } });
}

fn scene_path(sc: *Scene, _: Tiles) !void {
    var path = scene.Path(ScaledPixels).new(sc.allocator, .{ .x = 0, .y = 0 });
    path.content_mask = mask(0, 0, 128, 128);
    path.color = color.solid_background(color.red());
    path.move_to(.{ .x = 10, .y = 10 });
    try path.line_to(.{ .x = 110, .y = 20 });
    try path.line_to(.{ .x = 60, .y = 110 });
    try sc.insert_primitive(.{ .path = path });
    // Painted after the path, so the frame pass must resume with its contents loaded.
    try sc.insert_primitive(.{ .quad = .{ .bounds = rect(50, 50, 20, 20), .content_mask = mask(0, 0, 128, 128), .background = color.solid_background(color.white()) } });
}

const cases = [_]struct { name: []const u8, build: SceneFn, tolerance: u8 }{
    .{ .name = "solid", .build = scene_solid, .tolerance = 2 },
    .{ .name = "rounded_border", .build = scene_rounded_border, .tolerance = 8 },
    .{ .name = "clip", .build = scene_clip, .tolerance = 2 },
    .{ .name = "gradient", .build = scene_gradient, .tolerance = 4 },
    .{ .name = "pattern", .build = scene_pattern, .tolerance = 4 },
    .{ .name = "shadow", .build = scene_shadow, .tolerance = 4 },
    .{ .name = "underline", .build = scene_underline, .tolerance = 8 },
    .{ .name = "sprites", .build = scene_sprites, .tolerance = 4 },
    // MSAA sample positions differ from the CPU pattern: an edge pixel may differ by one sample of four.
    .{ .name = "path", .build = scene_path, .tolerance = 64 },
};

const size = 128;

fn dump(dir: []const u8, name: []const u8, suffix: []const u8, rgba: []const u8) void {
    var path_buf: [512]u8 = undefined;
    const path = std.fmt.bufPrintSentinel(&path_buf, "{s}/{s}_{s}.ppm", .{ dir, name, suffix }, 0) catch return;
    const file = std.c.fopen(path, "wb") orelse return;
    defer _ = std.c.fclose(file);
    var header: [64]u8 = undefined;
    const h = std.fmt.bufPrint(&header, "P6\n{d} {d}\n255\n", .{ size, size }) catch return;
    _ = std.c.fwrite(h.ptr, 1, h.len, file);
    var i: usize = 0;
    while (i < rgba.len) : (i += 4) _ = std.c.fwrite(rgba[i..].ptr, 1, 3, file);
}

test "GPU renderer matches the CPU renderer" {
    var ctx = vulkan.Context.init(.headless, .any) catch return error.SkipZigTest;
    defer ctx.deinit();
    var device = gpu.Device.init(testing.allocator, .{
        .backend = ctx.device_options(),
        .defaults = .{ .color_format = .rgba8, .depth_format = .none, .sample_count = 1 },
    }) catch return error.SkipZigTest;
    defer device.deinit();

    var renderer = try gpu_renderer.GpuRenderer.init(testing.allocator, &device, .rgba8);
    defer renderer.deinit();
    var gpu_atlas = gpu_renderer.GpuAtlas.init(testing.allocator, &device);
    defer gpu_atlas.deinit();
    const gpu_tiles = try insert_tiles(&gpu_atlas);

    var cpu_atlas = atlas.CpuAtlas.init(testing.allocator);
    defer cpu_atlas.deinit();
    const cpu_tiles = try insert_tiles(&cpu_atlas);
    var cpu_renderer = cpu.CpuRenderer.init(testing.allocator);
    defer cpu_renderer.deinit();

    const image = try device.createImage(.{ .width = size, .height = size, .format = .rgba8, .usage = .{ .color_attachment = true, .copy_src = true } });
    defer device.destroy(image);
    const view = try device.createView(.{ .color_attachment = .{ .image = image } });
    defer device.destroy(view);

    const dump_dir: ?[]const u8 = if (std.c.getenv("ZUI_GPU_TEST_DUMP")) |p| std.mem.span(p) else null;
    const clear = color.hsla(0.6, 0.2, 0.15, 1);
    var failed = false;

    for (cases) |case| {
        var gpu_pixels: [size * size * 4]u8 = undefined;
        {
            var sc = Scene.init(testing.allocator);
            defer sc.deinit();
            try case.build(&sc, gpu_tiles);
            sc.finish();
            try renderer.draw(&sc, &gpu_atlas, .{ .attachment = .{ .view = view, .width = size, .height = size } }, clear);
            device.commit();
            try device.readImage(image, .{}, &gpu_pixels, .{});
        }
        var cpu_pixels: [size * size * 4]u8 = undefined;
        {
            var sc = Scene.init(testing.allocator);
            defer sc.deinit();
            try case.build(&sc, cpu_tiles);
            sc.finish();
            cpu_renderer.draw(&sc, &cpu_atlas, .{ .pixels = &cpu_pixels, .width = size, .height = size, .stride = size * 4, .format = .rgba8 }, clear);
        }
        if (dump_dir) |dir| {
            dump(dir, case.name, "gpu", &gpu_pixels);
            dump(dir, case.name, "cpu", &cpu_pixels);
        }

        var worst: u8 = 0;
        var off_count: usize = 0;
        var worst_at: [2]usize = .{ 0, 0 };
        var i: usize = 0;
        while (i < gpu_pixels.len) : (i += 4) {
            var pixel_diff: u8 = 0;
            for (0..3) |c| pixel_diff = @max(pixel_diff, @max(gpu_pixels[i + c], cpu_pixels[i + c]) - @min(gpu_pixels[i + c], cpu_pixels[i + c]));
            if (pixel_diff > case.tolerance) off_count += 1;
            if (pixel_diff > worst) {
                worst = pixel_diff;
                worst_at = .{ (i / 4) % size, (i / 4) / size };
            }
        }
        if (off_count > 0) {
            failed = true;
            std.debug.print("{s}: {d} pixels differ by more than {d}; worst {d} at {any}\n", .{ case.name, off_count, case.tolerance, worst, worst_at });
        }
    }
    try testing.expect(!failed);
    try testing.expectEqual(gpu.DeviceStatus.ready, device.status());
}
