//! vellz CLI: render a shared-corpus scene to raw premultiplied RGBA8, or
//! render the ported upstream probe scene and compare it against the pinned
//! reference.
//!
//! Usage:
//!   vellz-cli --scene tests/scenes/fill_rect_64.json --out out/fill_rect_64.rgba
//!   vellz-cli --probe [--out out/probe.rgba]
//!
//! Scene output uses the same pixel format and metadata keys as
//! `tools/oracle-rs`, so `tools/compare.py` can compare them directly.
//! `--probe` renders `vellz.common.probe`'s scene at the upstream reference
//! settings (`Level.fallback`, 0 threads, `RenderMode.optimize_quality`,
//! `TargetInit.clear(css.WHITE)`), compares the un-premultiplied RGBA8 result
//! against the embedded `tests/fixtures/upstream/probe.rgba` with upstream's
//! probe policy (all four channels, per-channel absolute tolerance 3), prints
//! the measured maximum channel difference, and exits non-zero on a mismatch.
//! This tool is development tooling; it is not part of the distributed package.

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
    var probe_mode = false;
    var dump_glyphs = false;
    var dump_cmap = false;
    var font_path: ?[]const u8 = null;
    var font_index: u32 = 0;
    var font_size: ?f32 = null;
    var level_override: ?[]const u8 = null;
    var id_specs: std.ArrayList([]const u8) = .empty;
    defer id_specs.deinit(allocator);
    while (args_iter.next()) |arg| {
        if (std.mem.eql(u8, arg, "--scene")) {
            scene_path = args_iter.next() orelse return usage();
        } else if (std.mem.eql(u8, arg, "--out")) {
            out_path = args_iter.next() orelse return usage();
        } else if (std.mem.eql(u8, arg, "--probe")) {
            probe_mode = true;
        } else if (std.mem.eql(u8, arg, "--dump-glyphs")) {
            dump_glyphs = true;
        } else if (std.mem.eql(u8, arg, "--dump-cmap")) {
            dump_cmap = true;
        } else if (std.mem.eql(u8, arg, "--font")) {
            font_path = args_iter.next() orelse return usage();
        } else if (std.mem.eql(u8, arg, "--index")) {
            const value = args_iter.next() orelse return usage();
            font_index = std.fmt.parseInt(u32, value, 10) catch return usage();
        } else if (std.mem.eql(u8, arg, "--size")) {
            const value = args_iter.next() orelse return usage();
            font_size = std.fmt.parseFloat(f32, value) catch return usage();
        } else if (std.mem.eql(u8, arg, "--level")) {
            level_override = args_iter.next() orelse return usage();
        } else if (std.mem.eql(u8, arg, "--gids") or std.mem.eql(u8, arg, "--codepoints")) {
            try id_specs.append(allocator, args_iter.next() orelse return usage());
        } else {
            return usage();
        }
    }

    if (probe_mode) {
        if (scene_path != null) return usage();
        return runProbe(allocator, io, out_path);
    }
    if (dump_glyphs or dump_cmap) {
        if (scene_path != null or out_path != null) return usage();
        const font_file = font_path orelse return usage();
        const blob = try std.Io.Dir.cwd().readFileAlloc(
            io,
            font_file,
            allocator,
            .unlimited,
        );
        defer allocator.free(blob);
        if (dump_glyphs) {
            return runDumpGlyphs(allocator, io, blob, font_index, font_size orelse return usage(), id_specs.items);
        }
        return runDumpCmap(allocator, io, blob, font_index, id_specs.items);
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
    try renderScene(allocator, io, scene, text, out_file, scene_dir, level_override);
}

fn usage() error{InvalidArguments} {
    std.debug.print(
        "usage: vellz-cli --scene SCENE.json --out OUT.rgba [--level fallback|native|avx2|...]\n" ++
            "       vellz-cli --probe [--out OUT.rgba]\n" ++
            "       vellz-cli --dump-glyphs --font FONT [--index N] --size PPEM --gids 1,3,5-9\n" ++
            "       vellz-cli --dump-cmap --font FONT [--index N] --codepoints 65,0x1F600\n",
        .{},
    );
    return error.InvalidArguments;
}

/// Prints the Zig `glifo` path elements for `--gids` in the same canonical
/// text format as `tools/oracle-rs --dump-glyphs`, so the two can be
/// byte-compared. This is the M3 T2 bit-exactness gate.
fn runDumpGlyphs(
    allocator: std.mem.Allocator,
    io: std.Io,
    blob: []const u8,
    font_index: u32,
    size: f32,
    id_specs: []const []const u8,
) !void {
    const glifo = vellz.glifo;
    const font = try glifo.Font.init(blob, font_index);
    const outlines = font.outlines() catch |err| {
        std.debug.print("vellz-cli: outlines unavailable: {s}\n", .{@errorName(err)});
        return err;
    };

    var gids: std.ArrayList(u32) = .empty;
    defer gids.deinit(allocator);
    for (id_specs) |spec| try parseIdList(allocator, &gids, spec);

    var stdout_buffer: [4096]u8 = undefined;
    var file_writer = std.Io.File.stdout().writerStreaming(io, &stdout_buffer);
    glifo.dump.writeGlyphDump(
        &file_writer.interface,
        allocator,
        &outlines,
        font_index,
        size,
        gids.items,
    ) catch |err| {
        std.debug.print("vellz-cli: dumping glyphs: {s}\n", .{@errorName(err)});
        return err;
    };
    try file_writer.flush();
}

/// cmap companion to `--dump-glyphs`; same format as the oracle's
/// `--dump-cmap`.
fn runDumpCmap(
    allocator: std.mem.Allocator,
    io: std.Io,
    blob: []const u8,
    font_index: u32,
    id_specs: []const []const u8,
) !void {
    const glifo = vellz.glifo;
    const font = try glifo.Font.init(blob, font_index);

    var codepoints: std.ArrayList(u32) = .empty;
    defer codepoints.deinit(allocator);
    for (id_specs) |spec| try parseIdList(allocator, &codepoints, spec);

    var stdout_buffer: [4096]u8 = undefined;
    var file_writer = std.Io.File.stdout().writerStreaming(io, &stdout_buffer);
    try glifo.dump.writeCmapDump(
        &file_writer.interface,
        font_index,
        font.charmap(),
        codepoints.items,
    );
    try file_writer.flush();
}

/// Parses `1,3,5-9` with decimal or `0x` hex values into `ids`.
fn parseIdList(
    allocator: std.mem.Allocator,
    ids: *std.ArrayList(u32),
    spec: []const u8,
) !void {
    var parts = std.mem.splitScalar(u8, spec, ',');
    while (parts.next()) |raw_part| {
        const part = std.mem.trim(u8, raw_part, " \t");
        if (part.len == 0) continue;
        if (std.mem.indexOfScalar(u8, part, '-')) |dash| {
            const start = parseU32(part[0..dash]) orelse return error.InvalidArguments;
            const end = parseU32(part[dash + 1 ..]) orelse return error.InvalidArguments;
            if (end < start) return error.InvalidArguments;
            var id = start;
            while (id <= end) : (id += 1) try ids.append(allocator, id);
        } else {
            try ids.append(allocator, parseU32(part) orelse return error.InvalidArguments);
        }
    }
}

fn parseU32(text: []const u8) ?u32 {
    if (std.mem.startsWith(u8, text, "0x") or std.mem.startsWith(u8, text, "0X")) {
        return std.fmt.parseInt(u32, text[2..], 16) catch null;
    }
    return std.fmt.parseInt(u32, text, 10) catch null;
}

/// Render the probe scene, compare against the embedded pinned upstream
/// reference, optionally write the un-premultiplied RGBA8 result, and report
/// the exact metrics. Exits non-zero on a mismatch.
fn runProbe(allocator: std.mem.Allocator, io: std.Io, out_path: ?[]const u8) !void {
    const common_probe = vellz.common.probe;

    var pixmap = try vellz.cpu.probe.renderProbePixmap(allocator);
    defer pixmap.deinit(allocator);

    const actual = try common_probe.ProbeImage.fromPixmap(allocator, &pixmap);
    defer allocator.free(actual.data);

    const comparison = common_probe.compareReference(actual);
    const statistics = comparison.statistics;

    if (out_path) |out_file| {
        std.Io.Dir.cwd().createDirPath(io, std.fs.path.dirname(out_file) orelse ".") catch {};
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = out_file, .data = actual.data });
    }

    std.debug.print(
        "probe {d}x{d} bytes={d} fnv1a={x:0>16} different_pixels={d} " ++
            "max_channel_diff=[{d},{d},{d},{d}] byte_exact={}\n",
        .{
            actual.width,
            actual.height,
            actual.data.len,
            fnv1a(actual.data),
            statistics.different_pixel_count,
            statistics.max_channel_discrepancy[0],
            statistics.max_channel_discrepancy[1],
            statistics.max_channel_discrepancy[2],
            statistics.max_channel_discrepancy[3],
            comparison.byte_exact,
        },
    );

    if (!comparison.passed()) {
        for (common_probe.PROBE_ELEMENTS) |feature| {
            if (statistics.differs(feature)) {
                std.debug.print("probe: feature {s} differs\n", .{@tagName(feature)});
            }
        }
        return error.ProbeMismatch;
    }
}

fn renderScene(
    allocator: std.mem.Allocator,
    io: std.Io,
    scene: scene_mod.Scene,
    scene_text: []const u8,
    out_file: []const u8,
    scene_dir: []const u8,
    level_override: ?[]const u8,
) !void {
    const cpu = vellz.cpu;
    const common = vellz.common;

    const level = if (level_override) |name|
        vellz.simd.Level.fromName(name) orelse {
            std.debug.print("vellz-cli: unknown SIMD level '{s}'\n", .{name});
            return error.InvalidArguments;
        }
    else switch (scene.settings.level) {
        .fallback => vellz.simd.Level.fallback,
        // `Level.new()` detects the best level the build target supports
        // (SSE2/AVX2/AVX-512 on x86-64, Neon on aarch64).
        .native => vellz.simd.Level.new(),
    };

    const settings: cpu.RenderSettings = .{
        .level = level,
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
            .fill_blurred_rounded_rect => |spec| try ctx.fillBlurredRoundedRect(
                allocator,
                kurbo.Rect.new(spec.rect[0], spec.rect[1], spec.rect[2], spec.rect[3]),
                @floatCast(spec.radius),
                @floatCast(spec.std_dev),
                spec.invert,
            ),
            .fill_path => |svg| try fillPath(&ctx, allocator, &scratch_path, svg),
            .stroke_path => |svg| try strokePath(&ctx, allocator, &scratch_path, svg),
            .push_clip_path => |svg| try clipPath(&ctx, allocator, &scratch_path, svg),
            .pop_clip_path => ctx.popClipPath(),
            .push_clip_layer => |svg| try clipLayer(&ctx, allocator, &scratch_path, svg),
            .push_layer => |spec| try pushLayerSpec(&ctx, allocator, io, scene_dir, &scratch_path, spec),
            .pop_layer => ctx.popLayer(),
            .set_filter_effect => |spec| {
                const filter = try buildFilter(allocator, spec);
                ctx.setFilterEffect(filter);
            },
            .reset_filter_effect => ctx.resetFilterEffect(),
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
            const mask = try loadMask(
                allocator,
                io,
                scene_dir,
                mask_spec,
                ctx.width(),
                ctx.height(),
            );
            try ctx.pushMaskLayer(allocator, mask);
        },
        .filter => |filter_spec| {
            const filter = try buildFilter(allocator, filter_spec.filter);

            var clip_elements: ?[]const kurbo.PathEl = null;
            if (filter_spec.clip) |svg| {
                scratch.* = kurbo.bezpath.fromSvg(allocator, svg) catch return error.InvalidPath;
                clip_elements = scratch.elements.items;
            }
            defer {
                if (filter_spec.clip != null) {
                    scratch.deinit(allocator);
                    scratch.* = kurbo.BezPath.init();
                }
            }

            const blend: ?peniko.BlendMode = if (filter_spec.blend) |blend| .{
                .mix = std.meta.stringToEnum(peniko.Mix, @tagName(blend.mix)).?,
                .compose = std.meta.stringToEnum(peniko.Compose, @tagName(blend.compose)).?,
            } else null;
            const opacity: ?f32 = if (filter_spec.opacity) |value| @floatCast(value) else null;
            const mask: ?vellz.common.mask.Mask = if (filter_spec.mask) |mask_spec|
                try loadMask(allocator, io, scene_dir, mask_spec, ctx.width(), ctx.height())
            else
                null;

            try ctx.pushLayer(allocator, clip_elements, blend, opacity, mask, filter);
        },
    }
}

/// Loads a mask asset and resamples it to the scene size.
///
/// `vello_cpu` ignores masks whose size differs from the context, so assets
/// are brought to the scene size with the oracle's exact nearest-neighbor
/// rule.
fn loadMask(
    allocator: std.mem.Allocator,
    io: std.Io,
    scene_dir: []const u8,
    mask_spec: scene_mod.MaskSpec,
    width: u16,
    height: u16,
) !vellz.common.mask.Mask {
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

    var resampled = try resizeNearest(allocator, &source, width, height);
    defer resampled.deinit(allocator);

    return switch (mask_spec.kind) {
        .alpha => try vellz.common.mask.Mask.newAlpha(allocator, &resampled),
        .luminance => try vellz.common.mask.Mask.newLuminance(allocator, &resampled),
    };
}

/// Builds a single-primitive filter from a scene spec.
fn buildFilter(
    allocator: std.mem.Allocator,
    spec: scene_mod.FilterSpec,
) !vellz.common.filter_effects.Filter {
    const fe = vellz.common.filter_effects;
    const toColor = struct {
        fn call(rgba: [4]u8) peniko.Color {
            return peniko.color.Color.fromRgba8(rgba[0], rgba[1], rgba[2], rgba[3]);
        }
    }.call;
    const toEdgeMode = struct {
        fn call(mode: scene_mod.EdgeMode) fe.EdgeMode {
            return std.meta.stringToEnum(fe.EdgeMode, @tagName(mode)).?;
        }
    }.call;

    const primitive: fe.FilterPrimitive = switch (spec) {
        .flood => |rgba| .{ .flood = .{ .color = toColor(rgba) } },
        .gaussian_blur => |blur| .{ .gaussian_blur = .{
            .std_deviation = @floatCast(blur.std_deviation),
            .edge_mode = toEdgeMode(blur.edge_mode),
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
            .edge_mode = toEdgeMode(shadow.edge_mode),
        } },
        .drop_shadow_only => |shadow| .{ .drop_shadow_only = .{
            .dx = @floatCast(shadow.dx),
            .dy = @floatCast(shadow.dy),
            .std_deviation = @floatCast(shadow.std_deviation),
            .color = toColor(shadow.rgba8),
            .edge_mode = toEdgeMode(shadow.edge_mode),
        } },
    };
    return fe.Filter.fromPrimitive(allocator, primitive);
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
