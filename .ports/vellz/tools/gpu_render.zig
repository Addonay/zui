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
//! Images are registered in the shared image atlas cache (upstream
//! `Renderer::upload_image`) and sampled through `ImageSource.opaque_id`;
//! glyph runs draw through the GPU `DrawSink`/`GlyphRenderer` surface with the
//! same atlas cache backing the glyph pages.
//!
//! Masks are applied through the local mask adapt (uploaded mask texture +
//! dedicated multiply pass). Unsupported scene features (pixmap-only image
//! sources, destructive blends, filter graphs without a GPU plan) fail with a
//! typed error; there is no CPU fallback.

const std = @import("std");
const vellz = @import("vellz");
const wgpu = @import("wgpu");
const c = wgpu.c;
const scene_mod = @import("scene.zig");

const backend = vellz.gpu.backend;
const gpu_scene = vellz.gpu.scene;
const resources_mod = vellz.gpu.resources;
const text_mod = vellz.gpu.text;

const Asset = struct {
    id: common.paint.ImageId,
    path: []const u8,
    width: u16,
    height: u16,
    may_have_transparency: bool,
};

const kurbo = vellz.kurbo;
const peniko = vellz.peniko;
const common = vellz.common;
const glifo = vellz.glifo;

/// Renderer/resources used by lazy asset uploads (set before commands run).
var current_renderer: ?*backend.renderer.Renderer = null;
var current_resources: ?*resources_mod.Resources = null;

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

    // Persistent image/glyph resources. The atlas size is normalized against
    // the device limit *before* any image or glyph allocation.
    var resources = try resources_mod.Resources.init(allocator);
    defer resources.deinit();

    var renderer = try backend.renderer.Renderer.init(allocator, &dev, target_format, width, height);
    defer renderer.deinit();
    try renderer.configureResources(&resources);
    current_renderer = &renderer;
    current_resources = &resources;

    // Build the GPU scene from the corpus commands.
    var gpu = try gpu_scene.Scene.init(allocator, parsed_scene.width, parsed_scene.height);
    defer gpu.deinit();

    var scratch_path = kurbo.BezPath.init();
    defer scratch_path.deinit(allocator);

    var assets: std.ArrayList(Asset) = .empty;
    defer {
        for (assets.items) |asset| allocator.free(asset.path);
        assets.deinit(allocator);
    }
    var font_blobs: std.StringHashMapUnmanaged([]const u8) = .empty;
    defer {
        var iterator = font_blobs.iterator();
        while (iterator.next()) |entry| allocator.free(entry.value_ptr.*);
        font_blobs.deinit(allocator);
    }
    const scene_dir = std.fs.path.dirname(scene_file) orelse ".";

    for (parsed_scene.commands) |command| {
        switch (command) {
            .set_transform => |affine| gpu.setTransform(kurbo.Affine.new(affine)),
            .reset_transform => gpu.resetTransform(),
            .set_paint_transform => |affine| gpu.setPaintTransform(kurbo.Affine.new(affine)),
            .reset_paint_transform => gpu.resetPaintTransform(),
            .set_paint => |spec| try applyPaint(&gpu, allocator, io, scene_dir, &assets, spec),
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
            .fill_blurred_rounded_rect => |spec| try gpu.fillBlurredRoundedRect(
                kurbo.Rect.new(spec.rect[0], spec.rect[1], spec.rect[2], spec.rect[3]),
                @floatCast(spec.radius),
                @floatCast(spec.std_dev),
                spec.invert,
            ),
            .push_clip_layer => |svg| {
                try parseSvg(allocator, &scratch_path, svg);
                defer resetScratch(allocator, &scratch_path);
                try gpu.pushClipLayer(scratch_path.elements.items);
            },
            .push_layer => |spec| try pushLayerSpec(allocator, io, scene_dir, &gpu, &scratch_path, spec),
            .pop_layer => try gpu.popLayer(),
            .set_filter_effect => |filter_spec| gpu.setFilterEffect(try filterFromSpec(allocator, filter_spec)),
            .reset_filter_effect => gpu.resetFilterEffect(),
            .glyph_run => |spec| try renderGlyphRun(
                allocator,
                io,
                scene_dir,
                &gpu,
                &resources,
                &font_blobs,
                spec,
            ),
        }
    }

    const target_init: backend.renderer.TargetInit = switch (parsed_scene.target_init) {
        .clear => .{ .clear = peniko.color.Color.TRANSPARENT },
        .src_over => .src_over,
    };
    try renderer.renderWithResources(
        &gpu,
        target_view,
        depth_view,
        target_init,
        .{},
        texture,
        &resources,
    );

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

fn blendFromSpec(spec: scene_mod.BlendSpec) peniko.BlendMode {
    return .{
        .mix = std.meta.stringToEnum(peniko.Mix, @tagName(spec.mix)).?,
        .compose = std.meta.stringToEnum(peniko.Compose, @tagName(spec.compose)).?,
    };
}

fn edgeModeFromSpec(mode: scene_mod.EdgeMode) common.filter_effects.EdgeMode {
    return std.meta.stringToEnum(common.filter_effects.EdgeMode, @tagName(mode)).?;
}

fn filterFromSpec(allocator: std.mem.Allocator, spec: scene_mod.FilterSpec) !common.filter_effects.Filter {
    const fe = common.filter_effects;
    const toColor = struct {
        fn call(rgba: [4]u8) peniko.Color {
            return peniko.color.Color.fromRgba8(rgba[0], rgba[1], rgba[2], rgba[3]);
        }
    }.call;

    const primitive: fe.FilterPrimitive = switch (spec) {
        .flood => |rgba| .{ .flood = .{ .color = toColor(rgba) } },
        .gaussian_blur => |blur| .{ .gaussian_blur = .{
            .std_deviation = @floatCast(blur.std_deviation),
            .edge_mode = edgeModeFromSpec(blur.edge_mode),
        } },
        .offset => |offset| .{ .offset = .{
            .dx = @floatCast(offset.dx),
            .dy = @floatCast(offset.dy),
        } },
        .drop_shadow => |shadow| .{ .drop_shadow = .{
            .dx = @floatCast(shadow.dx),
            .dy = @floatCast(shadow.dy),
            .std_deviation = @floatCast(shadow.std_deviation),
            .color = toColor(shadow.rgba8),
            .edge_mode = edgeModeFromSpec(shadow.edge_mode),
        } },
        .drop_shadow_only => |shadow| .{ .drop_shadow_only = .{
            .dx = @floatCast(shadow.dx),
            .dy = @floatCast(shadow.dy),
            .std_deviation = @floatCast(shadow.std_deviation),
            .color = toColor(shadow.rgba8),
            .edge_mode = edgeModeFromSpec(shadow.edge_mode),
        } },
    };
    return fe.Filter.fromPrimitive(allocator, primitive);
}

/// Map a layer spec onto the GPU scene's layer stack.
///
/// Masks are loaded, nearest-resampled to the scene dimensions (exactly like
/// `vellz-cli`), and applied by the GPU mask adapt.
fn pushLayerSpec(
    allocator: std.mem.Allocator,
    io: std.Io,
    scene_dir: []const u8,
    gpu: *gpu_scene.Scene,
    scratch: *kurbo.BezPath,
    spec: scene_mod.LayerSpec,
) !void {
    switch (spec) {
        .clip => |svg| {
            try parseSvg(allocator, scratch, svg);
            defer resetScratch(allocator, scratch);
            try gpu.pushClipLayer(scratch.elements.items);
        },
        .blend => |blend| try gpu.pushBlendLayer(blendFromSpec(blend)),
        .opacity => |opacity| try gpu.pushOpacityLayer(@floatCast(opacity)),
        .mask => |mask_spec| {
            const mask = try loadMask(
                allocator,
                io,
                scene_dir,
                mask_spec,
                gpu.sceneWidth(),
                gpu.sceneHeight(),
            );
            try gpu.pushMaskLayer(mask);
        },
        .filter => |filter_spec| {
            const filter = try filterFromSpec(allocator, filter_spec.filter);
            var clip_elements: ?[]const kurbo.PathEl = null;
            if (filter_spec.clip) |svg| {
                try parseSvg(allocator, scratch, svg);
                clip_elements = scratch.elements.items;
            }
            defer if (clip_elements != null) resetScratch(allocator, scratch);

            const blend: ?peniko.BlendMode = if (filter_spec.blend) |blend|
                blendFromSpec(blend)
            else
                null;
            const opacity: ?f32 = if (filter_spec.opacity) |value| @floatCast(value) else null;
            var mask: ?common.mask.Mask = null;
            if (filter_spec.mask) |mask_spec| {
                mask = loadMask(
                    allocator,
                    io,
                    scene_dir,
                    mask_spec,
                    gpu.sceneWidth(),
                    gpu.sceneHeight(),
                ) catch |err| {
                    filter.deinit(allocator);
                    return err;
                };
            }
            // `pushLayer` takes ownership of both `filter` and `mask` on
            // success and releases them itself on error.
            try gpu.pushLayer(clip_elements, blend, opacity, mask, filter);
        },
    }
}

fn applyPaint(
    gpu: *gpu_scene.Scene,
    allocator: std.mem.Allocator,
    io: std.Io,
    scene_dir: []const u8,
    assets: *std.ArrayList(Asset),
    spec: scene_mod.PaintSpec,
) !void {
    switch (spec) {
        .solid => |rgba| {
            gpu.setPaint(common.paint.PaintType.fromAlphaColor(
                peniko.color.Color.fromRgba8(rgba[0], rgba[1], rgba[2], rgba[3]),
            ));
        },
        .gradient => |g| {
            var gradient: peniko.Gradient = .{};
            gradient.extend = std.meta.stringToEnum(peniko.Extend, @tagName(g.extend)).?;
            gradient.kind = switch (g.kind) {
                .linear => |l| .{ .linear = peniko.LinearGradientPosition.new(
                    .{ .x = l.start[0], .y = l.start[1] },
                    .{ .x = l.end[0], .y = l.end[1] },
                ) },
                .radial => |r| .{ .radial = peniko.RadialGradientPosition.newTwoPoint(
                    .{ .x = r.start_center[0], .y = r.start_center[1] },
                    @floatCast(r.start_radius),
                    .{ .x = r.end_center[0], .y = r.end_center[1] },
                    @floatCast(r.end_radius),
                ) },
                .sweep => |sw| .{ .sweep = peniko.SweepGradientPosition.new(
                    .{ .x = sw.center[0], .y = sw.center[1] },
                    @floatCast(sw.start_angle),
                    @floatCast(sw.end_angle),
                ) },
            };
            const stops = try allocator.alloc(peniko.ColorStop, g.stops.len);
            defer allocator.free(stops);
            for (g.stops, 0..) |stop, i| {
                stops[i] = .{
                    .offset = @floatCast(stop.offset),
                    .color = peniko.color.Color.fromRgba8(
                        stop.rgba8[0],
                        stop.rgba8[1],
                        stop.rgba8[2],
                        stop.rgba8[3],
                    ),
                };
            }
            gradient.stops = try peniko.ColorStops.fromSlice(allocator, stops);
            gpu.setPaint(common.paint.PaintType.fromGradient(gradient));
        },
        .image => |spec_image| {
            // Register the asset in the shared image atlas and reference it
            // by `opaque_id`, like a caller using `upload_image`.
            const asset = try loadAsset(allocator, io, scene_dir, assets, spec_image);
            const source = common.paint.ImageSource.initOpaqueId(asset.id);
            const image = common.paint.Image{
                .image = source,
                .sampler = .{
                    .x_extend = std.meta.stringToEnum(peniko.Extend, @tagName(spec_image.sampler.x_extend)).?,
                    .y_extend = std.meta.stringToEnum(peniko.Extend, @tagName(spec_image.sampler.y_extend)).?,
                    .quality = std.meta.stringToEnum(peniko.ImageQuality, @tagName(spec_image.sampler.quality)).?,
                    .alpha = @floatCast(spec_image.sampler.alpha),
                },
            };
            gpu.setPaint(common.paint.PaintType.fromImage(image));
        },
    }
}

/// Load (or reuse) a raw RGBA8 asset and upload it into the image atlas.
///
/// `Pixmap.fromParts` premultiplies straight-alpha bytes in place, so the
/// pixmap bytes are written to the `Rgba8Unorm` atlas as-is.
fn loadAsset(
    allocator: std.mem.Allocator,
    io: std.Io,
    scene_dir: []const u8,
    assets: *std.ArrayList(Asset),
    spec: scene_mod.ImageSpec,
) !*const Asset {
    for (assets.items) |*asset| {
        if (asset.width == spec.width and
            asset.height == spec.height and
            std.mem.eql(u8, asset.path, spec.asset))
        {
            return asset;
        }
    }

    const renderer = current_renderer orelse return error.DeviceLost;
    const resources = current_resources orelse return error.DeviceLost;
    var pixmap = try loadRawPixmap(allocator, io, scene_dir, spec);
    defer pixmap.deinit(allocator);

    const image_id = try renderer.uploadImage(resources, &pixmap);

    const path = try allocator.dupe(u8, spec.asset);
    errdefer allocator.free(path);
    try assets.append(allocator, .{
        .id = image_id,
        .path = path,
        .width = spec.width,
        .height = spec.height,
        .may_have_transparency = pixmap.mayHaveTransparency(),
    });
    return &assets.items[assets.items.len - 1];
}

/// Draw one positioned glyph run through the GPU glyph backend.
///
/// Deferred features (non-zero `embolden`, non-empty `normalized_coords`) are
/// typed `error.Unsupported`, never silently dropped. `decoration` is drawn
/// after the fill/stroke pass, matching the upstream decoration tests.
fn renderGlyphRun(
    allocator: std.mem.Allocator,
    io: std.Io,
    scene_dir: []const u8,
    scene: *gpu_scene.Scene,
    resources: *resources_mod.Resources,
    font_blobs: *std.StringHashMapUnmanaged([]const u8),
    spec: scene_mod.GlyphRunSpec,
) !void {
    if (spec.embolden) |amount| {
        if (amount[0] != 0.0 or amount[1] != 0.0) return error.Unsupported;
    }
    if (spec.normalized_coords) |coords| {
        if (coords.len != 0) return error.Unsupported;
    }

    const blob = font_blobs.get(spec.font.asset) orelse blk: {
        const path = try std.fs.path.join(allocator, &.{ scene_dir, spec.font.asset });
        defer allocator.free(path);
        const bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .unlimited);
        try font_blobs.put(allocator, spec.font.asset, bytes);
        break :blk bytes;
    };
    const font_data = glifo.FontData.init(blob, spec.font.index);

    const glyphs = try allocator.alloc(glifo.Glyph, spec.glyphs.len);
    defer allocator.free(glyphs);
    for (spec.glyphs, 0..) |glyph, i| {
        glyphs[i] = .{ .id = glyph.id, .x = glyph.x, .y = glyph.y };
    }

    var builder = text_mod.glyphRun(scene, resources, font_data)
        .fontSize(spec.font_size)
        .hint(spec.hint)
        .atlasCache(spec.atlas_cache);
    if (spec.glyph_transform) |transform| {
        builder = builder.glyphTransform(kurbo.Affine.new(transform));
    }

    switch (spec.style) {
        .fill => try builder.fillGlyphs(allocator, glifo.iterate(glyphs)),
        .stroke => try builder.strokeGlyphs(allocator, glifo.iterate(glyphs)),
    }

    if (spec.decoration) |decoration| {
        try builder.renderDecoration(
            allocator,
            glifo.iterate(glyphs),
            decoration.x_range,
            decoration.baseline_y,
            decoration.offset,
            decoration.size,
            decoration.buffer,
        );
    }
}

fn loadRawPixmap(
    allocator: std.mem.Allocator,
    io: std.Io,
    scene_dir: []const u8,
    spec: scene_mod.ImageSpec,
) !vellz.common.pixmap.Pixmap {
    const path = try std.fs.path.join(allocator, &.{ scene_dir, spec.asset });
    defer allocator.free(path);

    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .unlimited);
    defer allocator.free(bytes);

    if (spec.format == .bgra8) {
        var i: usize = 0;
        while (i + 3 < bytes.len) : (i += 4) std.mem.swap(u8, &bytes[i], &bytes[i + 2]);
    }

    const peniko_alpha: peniko.ImageAlphaType = switch (spec.alpha_type) {
        .alpha => .alpha,
        .premultiplied => .alpha_premultiplied,
    };
    const metadata = vellz.common.pixmap.PixelMetadata.new(peniko_alpha, true);
    return vellz.common.pixmap.Pixmap.fromParts(allocator, bytes, spec.width, spec.height, metadata);
}

/// Load a mask asset and nearest-resample it to the scene dimensions, exactly
/// like `tools/vellz_cli.zig` (the GPU scene drops mismatched masks).
fn loadMask(
    allocator: std.mem.Allocator,
    io: std.Io,
    scene_dir: []const u8,
    mask_spec: scene_mod.MaskSpec,
    width: u16,
    height: u16,
) !common.mask.Mask {
    var source = try loadRawPixmap(allocator, io, scene_dir, .{
        .asset = mask_spec.asset,
        .width = mask_spec.width,
        .height = mask_spec.height,
        .format = mask_spec.format,
        .alpha_type = mask_spec.alpha_type,
        .sampler = .{
            .x_extend = .pad,
            .y_extend = .pad,
            .quality = .low,
            .alpha = 1.0,
        },
    });
    defer source.deinit(allocator);

    var resampled = try resizeNearest(allocator, &source, width, height);
    defer resampled.deinit(allocator);

    return switch (mask_spec.kind) {
        .alpha => try common.mask.Mask.newAlpha(allocator, &resampled),
        .luminance => try common.mask.Mask.newLuminance(allocator, &resampled),
    };
}

/// Nearest-neighbor resample (mirrors `tools/vellz_cli.zig`).
fn resizeNearest(
    allocator: std.mem.Allocator,
    src: *const common.pixmap.Pixmap,
    width: u16,
    height: u16,
) !common.pixmap.Pixmap {
    var out = try common.pixmap.Pixmap.init(allocator, width, height);
    errdefer out.deinit(allocator);

    var y: u16 = 0;
    while (y < height) : (y += 1) {
        const sy: u16 = @intCast((@as(u32, y) * src.height) / height);
        var x: u16 = 0;
        while (x < width) : (x += 1) {
            const sx: u16 = @intCast((@as(u32, x) * src.width) / width);
            out.setPixel(x, y, src.sample(sx, sy));
        }
    }
    return out;
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
