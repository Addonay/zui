//! Offscreen GPU renderer for shared-corpus scenes (M5 T4/T5).
//!
//! Usage:
//!   vellz-gpu-render --scene tests/scenes/fill_rect_64.json --out out/gpu/fill_rect_64.rgba
//!                    [--no-depth] [--adapter-info]
//!
//! Replays a corpus scene into a `vellz.gpu.Scene`, renders it offscreen with
//! the wgpu backend into an `Rgba8Unorm` texture (optionally with a
//! `Depth24Plus` attachment), reads the premultiplied RGBA8 bytes back, and
//! writes them to `--out`. The printed line matches `vellz-cli`'s metrics so
//! `tools/gpu_corpus.sh` can compare both with `tools/compare_raw.py`.
//!
//! Unsupported scene features (gradients, images, layers, strokes beyond the
//! ported subset) fail with a typed error; there is no CPU fallback.

const std = @import("std");
const vellz = @import("vellz");
const wgpu = @import("wgpu");
const c = wgpu.c;
const scene_mod = @import("scene.zig");

const backend = vellz.gpu.backend;
const gpu_scene = vellz.gpu.scene;

const kurbo = vellz.kurbo;
const peniko = vellz.peniko;
const common = vellz.common;

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;

    var args_iter = std.process.Args.Iterator.init(init.minimal.args);
    defer args_iter.deinit();
    _ = args_iter.skip();

    var scene_path: ?[]const u8 = null;
    var out_path: ?[]const u8 = null;
    var use_depth = true;
    var print_adapter = false;
    while (args_iter.next()) |arg| {
        if (std.mem.eql(u8, arg, "--scene")) {
            scene_path = args_iter.next() orelse return usage();
        } else if (std.mem.eql(u8, arg, "--out")) {
            out_path = args_iter.next() orelse return usage();
        } else if (std.mem.eql(u8, arg, "--no-depth")) {
            use_depth = false;
        } else if (std.mem.eql(u8, arg, "--adapter-info")) {
            print_adapter = true;
        } else {
            return usage();
        }
    }
    const scene_file = scene_path orelse return usage();
    const out_file = out_path orelse return usage();

    const text = try std.Io.Dir.cwd().readFileAlloc(io, scene_file, allocator, .unlimited);
    defer allocator.free(text);

    var parsed = scene_mod.parse(allocator, text) catch |err| {
        std.debug.print("vellz-gpu-render: invalid scene {s}: {s}\n", .{ scene_file, @errorName(err) });
        return err;
    };
    defer parsed.deinit();
    const parsed_scene = parsed.scene;

    // Device bootstrap (offscreen: no surface anywhere).
    var instance = try backend.Instance.create();
    defer instance.deinit();
    var adapter = try backend.Adapter.acquire(&instance, .{});
    defer adapter.deinit();
    if (print_adapter) adapter.info.print();
    std.debug.print(
        "adapter: backend={s} type={s} execution={s}\n",
        .{ adapter.info.backendName(), adapter.info.adapterTypeName(), adapter.info.executionKind() },
    );

    var dev = try backend.Device.acquire(allocator, &adapter, "vellz-gpu-render");
    defer dev.deinit();

    // Build the GPU scene from the corpus commands.
    var gpu = try gpu_scene.Scene.init(allocator, parsed_scene.width, parsed_scene.height);
    defer gpu.deinit();

    var scratch_path = kurbo.BezPath.init();
    defer scratch_path.deinit(allocator);

    for (parsed_scene.commands) |command| {
        switch (command) {
            .set_transform => |affine| gpu.setTransform(kurbo.Affine.new(affine)),
            .reset_transform => gpu.resetTransform(),
            .set_paint_transform => |affine| gpu.setPaintTransform(kurbo.Affine.new(affine)),
            .reset_paint_transform => gpu.resetPaintTransform(),
            .set_paint => |spec| try applyPaint(&gpu, spec),
            .set_fill_rule => |rule| gpu.setFillRule(switch (rule) {
                .nonzero => .non_zero,
                .evenodd => .even_odd,
            }),
            .fill_rect => |r| try gpu.fillRect(&kurbo.Rect.new(r[0], r[1], r[2], r[3])),
            .stroke_rect => |r| try gpu.strokeRect(&kurbo.Rect.new(r[0], r[1], r[2], r[3])),
            .set_stroke => |spec| gpu.setStroke(try strokeFromSpec(spec)),
            .fill_path => |svg| {
                try parseSvg(allocator, &scratch_path, svg);
                defer resetScratch(allocator, &scratch_path);
                try gpu.fillPath(scratch_path.elements.items);
            },
            .stroke_path => |svg| {
                try parseSvg(allocator, &scratch_path, svg);
                defer resetScratch(allocator, &scratch_path);
                try gpu.strokePath(scratch_path.elements.items);
            },
            .reset => try gpu.reset(),
            .set_aliasing_threshold => |threshold| gpu.setAliasingThreshold(threshold),
            .push_clip_path => |svg| {
                try parseSvg(allocator, &scratch_path, svg);
                defer resetScratch(allocator, &scratch_path);
                try gpu.pushClipPath(scratch_path.elements.items);
            },
            .pop_clip_path => try gpu.popClipPath(),
            .fill_blurred_rounded_rect,
            .push_clip_layer,
            .push_layer,
            .pop_layer,
            .set_filter_effect,
            .reset_filter_effect,
            => {
                std.debug.print(
                    "vellz-gpu-render: scene command '{s}' is not supported by the root strip milestone\n",
                    .{@tagName(command)},
                );
                return error.Unsupported;
            },
        }
    }

    const width: u32 = parsed_scene.width;
    const height: u32 = parsed_scene.height;
    if (width == 0 or height == 0) return error.InvalidSize;

    const target_format = c.WGPUTextureFormat_RGBA8Unorm;

    const texture = try backend.wgpu.createTexture2d(
        &dev,
        width,
        height,
        target_format,
        c.WGPUTextureUsage_RenderAttachment | c.WGPUTextureUsage_CopySrc,
        "vellz-gpu-target",
    );
    defer c.wgpuTextureRelease(texture);
    const target_view = try backend.wgpu.createFullView(texture, target_format, "vellz-gpu-target-view");
    defer c.wgpuTextureViewRelease(target_view);

    var depth_texture: c.WGPUTexture = null;
    var depth_view: ?c.WGPUTextureView = null;
    defer if (depth_view) |view| c.wgpuTextureViewRelease(view);
    defer if (depth_texture != null) c.wgpuTextureRelease(depth_texture);
    if (use_depth) {
        depth_texture = try backend.wgpu.createTexture2d(
            &dev,
            width,
            height,
            c.WGPUTextureFormat_Depth24Plus,
            c.WGPUTextureUsage_RenderAttachment,
            "vellz-gpu-depth",
        );
        depth_view = try backend.wgpu.createFullView(
            depth_texture,
            c.WGPUTextureFormat_Depth24Plus,
            "vellz-gpu-depth-view",
        );
    }

    var renderer = try backend.renderer.Renderer.init(allocator, &dev, target_format, width, height);
    defer renderer.deinit();

    const target_init: backend.renderer.TargetInit = switch (parsed_scene.target_init) {
        .clear => .{ .clear = peniko.color.Color.TRANSPARENT },
        .src_over => .src_over,
    };
    try renderer.render(&gpu, target_view, depth_view, target_init);

    const pixels = try backend.readback.readTexture(allocator, &dev, texture, width, height);
    defer allocator.free(pixels);

    const expected = @as(usize, width) * height * 4;
    if (pixels.len != expected) return error.InvalidPixmapSize;

    std.Io.Dir.cwd().createDirPath(io, std.fs.path.dirname(out_file) orelse ".") catch {};
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = out_file, .data = pixels });

    std.debug.print(
        "ok {d}x{d} bytes={d} fnv1a={x:0>16} scene_fnv1a={x:0>16} depth={s}\n",
        .{ width, height, expected, fnv1a(pixels), fnv1a(text), if (use_depth) "on" else "off" },
    );
}

fn usage() error{InvalidArguments} {
    std.debug.print(
        "usage: vellz-gpu-render --scene SCENE.json --out OUT.rgba [--no-depth] [--adapter-info]\n",
        .{},
    );
    return error.InvalidArguments;
}

fn applyPaint(gpu: *gpu_scene.Scene, spec: scene_mod.PaintSpec) !void {
    switch (spec) {
        .solid => |rgba| {
            gpu.setPaint(common.paint.PaintType.fromAlphaColor(
                peniko.color.Color.fromRgba8(rgba[0], rgba[1], rgba[2], rgba[3]),
            ));
        },
        .gradient, .image => {
            std.debug.print(
                "vellz-gpu-render: paint kind '{s}' needs the encoded-paint milestone\n",
                .{@tagName(spec)},
            );
            return error.Unsupported;
        },
    }
}

fn parseSvg(
    allocator: std.mem.Allocator,
    scratch: *kurbo.BezPath,
    svg: []const u8,
) !void {
    scratch.* = kurbo.bezpath.fromSvg(allocator, svg) catch return error.InvalidPath;
}

/// Map a corpus stroke spec onto `kurbo.Stroke` (same mapping as `vellz-cli`).
fn strokeFromSpec(spec: scene_mod.StrokeSpec) !kurbo.Stroke {
    var stroke = kurbo.Stroke.new(spec.width);
    if (spec.join) |join| stroke = stroke.withJoin(@fromBackingInt(@intCast(@backingInt(join))));
    if (spec.start_cap) |cap| stroke = stroke.withStartCap(@fromBackingInt(@intCast(@backingInt(cap))));
    if (spec.end_cap) |cap| stroke = stroke.withEndCap(@fromBackingInt(@intCast(@backingInt(cap))));
    if (spec.miter_limit) |limit| stroke = stroke.withMiterLimit(limit);
    if (spec.dash) |dash| stroke = try stroke.withDashes(spec.dash_offset, dash);
    return stroke;
}

fn resetScratch(allocator: std.mem.Allocator, scratch: *kurbo.BezPath) void {
    scratch.deinit(allocator);
    scratch.* = kurbo.BezPath.init();
}

fn fnv1a(bytes: []const u8) u64 {
    var hash: u64 = 0xcbf2_9ce4_8422_2325;
    for (bytes) |byte| {
        hash ^= @as(u64, byte);
        hash = hash *% 0x0000_0100_0000_01b3;
    }
    return hash;
}
