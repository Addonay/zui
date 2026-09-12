//! vellz CLI: render a shared-corpus scene to raw premultiplied RGBA8.
//!
//! Usage:
//!   vellz-cli --scene tests/scenes/fill_rect_64.json --out out/fill_rect_64.rgba
//!
//! Outputs the same pixel format and metadata keys as `tools/oracle-rs`, so
//! `tools/compare.py` can compare them directly. This tool is development
//! tooling; it is not part of the distributed package.

const std = @import("std");
const vellz = @import("vellz");
const scene_mod = @import("scene.zig");

const kurbo = vellz.kurbo;
const peniko = vellz.peniko;

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;

    var args_iter = std.process.Args.Iterator.init(init.minimal.args);
    defer args_iter.deinit();
    _ = args_iter.skip(); // program name

    var scene_path: ?[]const u8 = null;
    var out_path: ?[]const u8 = null;
    while (args_iter.next()) |arg| {
        if (std.mem.eql(u8, arg, "--scene")) {
            scene_path = args_iter.next() orelse return usage();
        } else if (std.mem.eql(u8, arg, "--out")) {
            out_path = args_iter.next() orelse return usage();
        } else {
            return usage();
        }
    }
    const scene_file = scene_path orelse return usage();
    const out_file = out_path orelse return usage();

    const text = try std.Io.Dir.cwd().readFileAlloc(io, scene_file, allocator, .unlimited);
    defer allocator.free(text);

    var parsed = scene_mod.parse(allocator, text) catch |err| {
        std.debug.print("vellz-cli: invalid scene {s}: {s}\n", .{ scene_file, @errorName(err) });
        return err;
    };
    defer parsed.deinit();
    const scene = parsed.scene;

    const scene_dir = std.fs.path.dirname(scene_file) orelse ".";
    try renderScene(allocator, io, scene, text, out_file, scene_dir);
}

fn usage() error{InvalidArguments} {
    std.debug.print(
        "usage: vellz-cli --scene SCENE.json --out OUT.rgba\n",
        .{},
    );
    return error.InvalidArguments;
}

fn renderScene(
    allocator: std.mem.Allocator,
    io: std.Io,
    scene: scene_mod.Scene,
    scene_text: []const u8,
    out_file: []const u8,
    scene_dir: []const u8,
) !void {
    const cpu = vellz.cpu;
    const common = vellz.common;

    const settings: cpu.RenderSettings = .{
        .level = switch (scene.settings.level) {
            .fallback => vellz.simd.Level.fallback,
            // The port currently ships one portable backend; `Level.new()` is
            // broken upstream-side in `src/simd/root.zig` (see the report), so
            // "native" maps to the guaranteed baseline level.
            .native => vellz.simd.Level.baseline,
        },
        .num_threads = scene.settings.threads,
    };
    const rasterizer: cpu.RasterizerSettings = .{
        .render_mode = switch (scene.settings.mode) {
            .quality => .optimize_quality,
            .speed => .optimize_speed,
        },
        .target_init = switch (scene.target_init) {
            .clear => .{ .clear = peniko.color.Color.TRANSPARENT },
            .src_over => .src_over,
        },
        .pixel_format = .rgba8,
        .offset = .{ .x = 0, .y = 0 },
    };

    var ctx = try cpu.RenderContext.init(allocator, scene.width, scene.height, settings);
    defer ctx.deinit(allocator);
    var resources = cpu.Resources.init();
    defer resources.deinit(allocator);
    var pixmap = try common.pixmap.Pixmap.init(allocator, scene.width, scene.height);
    defer pixmap.deinit(allocator);

    var scratch_path = kurbo.BezPath.init();
    defer scratch_path.deinit(allocator);

    for (scene.commands) |command| {
        switch (command) {
            .set_transform => |c| ctx.setTransform(kurbo.Affine.new(c)),
            .reset_transform => ctx.resetTransform(),
            .set_paint_transform => |c| ctx.setPaintTransform(kurbo.Affine.new(c)),
            .reset_paint_transform => ctx.resetPaintTransform(),
            .set_paint => |spec| try applyPaint(&ctx, allocator, io, scene_dir, spec),
            .set_fill_rule => |rule| ctx.setFillRule(switch (rule) {
                .nonzero => .non_zero,
                .evenodd => .even_odd,
            }),
            .set_stroke => |spec| {
                var stroke = kurbo.Stroke.new(spec.width);
                if (spec.join) |join| stroke = stroke.withJoin(@fromBackingInt(@intCast(@backingInt(join))));
                if (spec.start_cap) |cap| stroke = stroke.withStartCap(@fromBackingInt(@intCast(@backingInt(cap))));
                if (spec.end_cap) |cap| stroke = stroke.withEndCap(@fromBackingInt(@intCast(@backingInt(cap))));
                if (spec.miter_limit) |limit| stroke = stroke.withMiterLimit(limit);
                if (spec.dash) |dash| stroke = try stroke.withDashes(spec.dash_offset, dash);
                ctx.setStroke(stroke);
            },
            .set_aliasing_threshold => |threshold| ctx.setAliasingThreshold(threshold),
            .fill_rect => |r| try ctx.fillRect(allocator, kurbo.Rect.new(r[0], r[1], r[2], r[3])),
            .stroke_rect => |r| try ctx.strokeRect(allocator, kurbo.Rect.new(r[0], r[1], r[2], r[3])),
            .fill_path => |svg| try fillPath(&ctx, allocator, &scratch_path, svg),
            .stroke_path => |svg| try strokePath(&ctx, allocator, &scratch_path, svg),
            .push_clip_path => |svg| try clipPath(&ctx, allocator, &scratch_path, svg),
            .pop_clip_path => ctx.popClipPath(),
            .push_clip_layer => |svg| try clipLayer(&ctx, allocator, &scratch_path, svg),
            .push_layer => |spec| try pushLayerSpec(&ctx, allocator, io, scene_dir, &scratch_path, spec),
            .pop_layer => ctx.popLayer(),
            .reset => ctx.reset(),
        }
    }

    try ctx.flush();
    try ctx.renderWith(&pixmap, &resources, rasterizer);

    const pixels = pixmap.dataAsU8Slice();
    const expected = @as(usize, scene.width) * @as(usize, scene.height) * 4;
    if (pixels.len != expected) return error.InvalidPixmapSize;

    std.Io.Dir.cwd().createDirPath(io, std.fs.path.dirname(out_file) orelse ".") catch {};
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = out_file, .data = pixels });

    const output_hash = fnv1a(pixels);
    const scene_hash = fnv1a(scene_text);
    std.debug.print(
        "ok {d}x{d} bytes={d} fnv1a={x:0>16} scene_fnv1a={x:0>16}\n",
        .{ scene.width, scene.height, expected, output_hash, scene_hash },
    );
}

fn fillPath(
    ctx: *vellz.cpu.RenderContext,
    allocator: std.mem.Allocator,
    scratch: *kurbo.BezPath,
    svg: []const u8,
) !void {
    scratch.* = kurbo.bezpath.fromSvg(allocator, svg) catch return error.InvalidPath;
    defer {
        scratch.deinit(allocator);
        scratch.* = kurbo.BezPath.init();
    }
    try ctx.fillPath(allocator, scratch.elements.items);
}

fn strokePath(
    ctx: *vellz.cpu.RenderContext,
    allocator: std.mem.Allocator,
    scratch: *kurbo.BezPath,
    svg: []const u8,
) !void {
    scratch.* = kurbo.bezpath.fromSvg(allocator, svg) catch return error.InvalidPath;
    defer {
        scratch.deinit(allocator);
        scratch.* = kurbo.BezPath.init();
    }
    try ctx.strokePath(allocator, scratch.elements.items);
}

fn clipPath(
    ctx: *vellz.cpu.RenderContext,
    allocator: std.mem.Allocator,
    scratch: *kurbo.BezPath,
    svg: []const u8,
) !void {
    scratch.* = kurbo.bezpath.fromSvg(allocator, svg) catch return error.InvalidPath;
    defer {
        scratch.deinit(allocator);
        scratch.* = kurbo.BezPath.init();
    }
    try ctx.pushClipPath(allocator, scratch.elements.items);
}

fn clipLayer(
    ctx: *vellz.cpu.RenderContext,
    allocator: std.mem.Allocator,
    scratch: *kurbo.BezPath,
    svg: []const u8,
) !void {
    scratch.* = kurbo.bezpath.fromSvg(allocator, svg) catch return error.InvalidPath;
    defer {
        scratch.deinit(allocator);
        scratch.* = kurbo.BezPath.init();
    }
    try ctx.pushClipLayer(allocator, scratch.elements.items);
}

fn fnv1a(bytes: []const u8) u64 {
    var hash: u64 = 0xcbf2_9ce4_8422_2325;
    for (bytes) |byte| {
        hash ^= @as(u64, byte);
        hash = hash *% 0x0000_0100_0000_01b3;
    }
    return hash;
}

// ---------------------------------------------------------------------------
// M2 paint and layer mapping
// ---------------------------------------------------------------------------

fn applyPaint(
    ctx: *vellz.cpu.RenderContext,
    allocator: std.mem.Allocator,
    io: std.Io,
    scene_dir: []const u8,
    spec: scene_mod.PaintSpec,
) !void {
    const common = vellz.common;
    switch (spec) {
        .solid => |rgba| ctx.setPaint(peniko.color.Color.fromRgba8(rgba[0], rgba[1], rgba[2], rgba[3])),
        .gradient => |g| {
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
            // `ColorStops.fromSlice` copies; the gradient owns the copy.
            gradient.stops = try peniko.ColorStops.fromSlice(allocator, stops);
            ctx.setPaint(common.paint.PaintType.fromGradient(gradient));
        },
        .image => |img| {
            var source = try loadRawPixmap(allocator, io, scene_dir, img.asset, img.width, img.height, img.format, img.alpha_type);
            const handle = common.shared.Shared(common.pixmap.Pixmap).create(allocator, source) catch |err| {
                source.deinit(allocator);
                return err;
            };
            const image = common.paint.Image{
                .image = common.paint.ImageSource.initPixmap(handle),
                .sampler = .{
                    .x_extend = std.meta.stringToEnum(peniko.Extend, @tagName(img.sampler.x_extend)).?,
                    .y_extend = std.meta.stringToEnum(peniko.Extend, @tagName(img.sampler.y_extend)).?,
                    .quality = std.meta.stringToEnum(peniko.ImageQuality, @tagName(img.sampler.quality)).?,
                    .alpha = @floatCast(img.sampler.alpha),
                },
            };
            ctx.setPaint(common.paint.PaintType.fromImage(image));
        },
    }
}

fn pushLayerSpec(
    ctx: *vellz.cpu.RenderContext,
    allocator: std.mem.Allocator,
    io: std.Io,
    scene_dir: []const u8,
    scratch: *kurbo.BezPath,
    spec: scene_mod.LayerSpec,
) !void {
    switch (spec) {
        .clip => |svg| try clipLayer(ctx, allocator, scratch, svg),
        .blend => |blend| {
            const mix = std.meta.stringToEnum(peniko.Mix, @tagName(blend.mix)).?;
            const compose = std.meta.stringToEnum(peniko.Compose, @tagName(blend.compose)).?;
            try ctx.pushBlendLayer(.{ .mix = mix, .compose = compose });
        },
        .opacity => |opacity| try ctx.pushOpacityLayer(@floatCast(opacity)),
        .mask => |mask_spec| {
            var source = try loadRawPixmap(
                allocator,
                io,
                scene_dir,
                mask_spec.asset,
                mask_spec.width,
                mask_spec.height,
                mask_spec.format,
                mask_spec.alpha_type,
            );
            defer source.deinit(allocator);

            // `vello_cpu` ignores masks whose size differs from the context,
            // so bring assets to the scene size with the oracle's exact
            // nearest-neighbor rule.
            var resampled = try resizeNearest(allocator, &source, ctx.width(), ctx.height());
            defer resampled.deinit(allocator);

            const mask = switch (mask_spec.kind) {
                .alpha => try vellz.common.mask.Mask.newAlpha(allocator, &resampled),
                .luminance => try vellz.common.mask.Mask.newLuminance(allocator, &resampled),
            };
            try ctx.pushMaskLayer(allocator, mask);
        },
    }
}

fn loadRawPixmap(
    allocator: std.mem.Allocator,
    io: std.Io,
    scene_dir: []const u8,
    asset: []const u8,
    width: u16,
    height: u16,
    format: scene_mod.ImageFormat,
    alpha_type: scene_mod.ImageAlphaType,
) !vellz.common.pixmap.Pixmap {
    const path = try std.fs.path.join(allocator, &.{ scene_dir, asset });
    defer allocator.free(path);

    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .unlimited);
    defer allocator.free(bytes);

    if (format == .bgra8) {
        var i: usize = 0;
        while (i + 3 < bytes.len) : (i += 4) std.mem.swap(u8, &bytes[i], &bytes[i + 2]);
    }

    const peniko_alpha: peniko.ImageAlphaType = switch (alpha_type) {
        .alpha => .alpha,
        .premultiplied => .alpha_premultiplied,
    };
    const metadata = vellz.common.pixmap.PixelMetadata.new(peniko_alpha, true);
    return vellz.common.pixmap.Pixmap.fromParts(allocator, bytes, width, height, metadata);
}

/// Nearest-neighbor resample with integer `src = dst * src_size / dst_size`,
/// matching `tools/oracle-rs`.
fn resizeNearest(
    allocator: std.mem.Allocator,
    src: *const vellz.common.pixmap.Pixmap,
    width: u16,
    height: u16,
) !vellz.common.pixmap.Pixmap {
    var out = try vellz.common.pixmap.Pixmap.init(allocator, width, height);
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
