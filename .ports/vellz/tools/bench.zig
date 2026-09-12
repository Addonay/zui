//! In-process CPU renderer benchmark for the vellz port.
//!
//! Measures the plan.md §12 stages separately:
//!   1. scene construction (paint/path setup replayed per frame),
//!   2. CPU preprocessing (flatten/tile/strip: `fill*` + `flush`),
//!   3. coarse bucketing (`StageTimings.bucket_ns`, inside `renderWith`),
//!   4. fine rasterization (`StageTimings.fine_ns`, inside `renderWith`),
//! plus the total iteration wall time and the one-time asset setup.
//!
//! Every scene is rendered repeatedly into the same context/pixmap, with a
//! `RenderContext.reset` between iterations, exactly like a frame loop. Each
//! iteration is timed individually; the tables report the median across runs
//! (the min is collected as a noise-resistant cross-check).
//!
//! The output is a Markdown table plus a speedup summary comparing the
//! requested SIMD levels (default: `fallback` vs the detected native level).
//!
//! Usage:
//!   vellz-bench [--scene PATH]... [--runs N] [--warmup N]
//!               [--levels fallback,native] [--modes quality,speed]
//!               [--threads N]
//!
//! This is development tooling; it is not part of the distributed package.

const std = @import("std");
const builtin = @import("builtin");
const vellz = @import("vellz");
const scene_mod = @import("scene.zig");

const kurbo = vellz.kurbo;
const peniko = vellz.peniko;
const common = vellz.common;
const cpu = vellz.cpu;

/// Clock supplied to `cpu.settings.StageTimings`; the library stays free of
/// platform timers, the tool owns the `std.Io` instance.
var clock_io: std.Io = undefined;

fn nowNs() u64 {
    const timestamp = std.Io.Timestamp.now(clock_io, .awake);
    if (timestamp.nanoseconds <= 0) return 0;
    return @intCast(@min(timestamp.nanoseconds, std.math.maxInt(u64)));
}

const DEFAULT_SCENES = [_][]const u8{
    "tests/scenes/fill_wave_seams_128.json",
    "tests/scenes/fill_tile_grid_128.json",
    "tests/scenes/image_bilinear_64.json",
    "tests/scenes/gradient_repeat_128.json",
};

const LevelPair = struct { name: []const u8, level: vellz.simd.Level };

const StatKind = enum {
    min,
    median,
    mean,
};

const Options = struct {
    scenes: std.ArrayList([]const u8) = .empty,
    levels: std.ArrayList([]const u8) = .empty,
    modes: std.ArrayList([]const u8) = .empty,
    runs: usize = 30,
    warmup: usize = 5,
    threads: u16 = 0,
    stat: StatKind = .min,

    fn deinit(self: *Options, allocator: std.mem.Allocator) void {
        self.scenes.deinit(allocator);
        self.levels.deinit(allocator);
        self.modes.deinit(allocator);
    }
};

const Phase = enum(usize) {
    construct = 0,
    preprocess = 1,
    bucket = 2,
    fine = 3,
    render = 4,
    total = 5,

    fn label(self: Phase) []const u8 {
        return switch (self) {
            .construct => "construct",
            .preprocess => "preprocess",
            .bucket => "bucket",
            .fine => "fine",
            .render => "render",
            .total => "total",
        };
    }
};

const all_phases = [_]Phase{ .construct, .preprocess, .bucket, .fine, .render, .total };

const Sample = struct {
    construct_ns: u64,
    preprocess_ns: u64,
    bucket_ns: u64,
    fine_ns: u64,
    render_ns: u64,
    total_ns: u64,

    fn get(self: Sample, phase: Phase) u64 {
        return switch (phase) {
            .construct => self.construct_ns,
            .preprocess => self.preprocess_ns,
            .bucket => self.bucket_ns,
            .fine => self.fine_ns,
            .render => self.render_ns,
            .total => self.total_ns,
        };
    }
};

const Stats = struct {
    min_ns: u64 = std.math.maxInt(u64),
    median_ns: u64 = 0,
    mean_ns: u64 = 0,
};

const RunResult = struct {
    scene: []const u8,
    mode_name: []const u8,
    level_name: []const u8,
    stats: [6]Stats,
    setup_ns: u64,
    /// FNV-1a of the rendered pixmap; all levels of a scene/mode must agree.
    pixmap_hash: u64,
};

/// One replayed scene operation; the SVG paths are parsed during the
/// construction phase of every iteration, matching a real frame build.
const Op = union(enum) {
    set_paint: scene_mod.PaintSpec,
    set_paint_transform: scene_mod.Affine,
    reset_paint_transform,
    set_transform: scene_mod.Affine,
    reset_transform,
    fill_rect: [4]f64,
    fill_path: []const u8,
};

const Plan = struct {
    /// Parsed scene; owns the arena all `Op` slices point into.
    parsed: scene_mod.Parsed,
    width: u16,
    height: u16,
    ops: []const Op,

    /// Decoded image asset, shared with each iteration's paint via
    /// `clone`/`release`.
    image_handle: ?common.shared.Shared(common.pixmap.Pixmap) = null,
    image_spec: ?scene_mod.ImageSpec = null,
};

pub fn main(init: std.process.Init) !void {
    clock_io = init.io;
    const allocator = init.gpa;

    var options = Options{};
    defer options.deinit(allocator);

    var args = std.process.Args.Iterator.init(init.minimal.args);
    defer args.deinit();
    _ = args.skip();
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--scene")) {
            try options.scenes.append(allocator, args.next() orelse return usage());
        } else if (std.mem.eql(u8, arg, "--runs")) {
            options.runs = std.fmt.parseInt(usize, args.next() orelse return usage(), 10) catch
                return usage();
        } else if (std.mem.eql(u8, arg, "--warmup")) {
            options.warmup = std.fmt.parseInt(usize, args.next() orelse return usage(), 10) catch
                return usage();
        } else if (std.mem.eql(u8, arg, "--level")) {
            try options.levels.append(allocator, args.next() orelse return usage());
        } else if (std.mem.eql(u8, arg, "--levels")) {
            const list = args.next() orelse return usage();
            var it = std.mem.splitScalar(u8, list, ',');
            while (it.next()) |item| try options.levels.append(allocator, item);
        } else if (std.mem.eql(u8, arg, "--mode")) {
            try options.modes.append(allocator, args.next() orelse return usage());
        } else if (std.mem.eql(u8, arg, "--modes")) {
            const list = args.next() orelse return usage();
            var it = std.mem.splitScalar(u8, list, ',');
            while (it.next()) |item| try options.modes.append(allocator, item);
        } else if (std.mem.eql(u8, arg, "--threads")) {
            options.threads = std.fmt.parseInt(u16, args.next() orelse return usage(), 10) catch
                return usage();
        } else if (std.mem.eql(u8, arg, "--stat")) {
            const name = args.next() orelse return usage();
            options.stat = std.meta.stringToEnum(StatKind, name) orelse return usage();
        } else {
            return usage();
        }
    }

    if (options.scenes.items.len == 0) {
        for (DEFAULT_SCENES) |scene| try options.scenes.append(allocator, scene);
    }
    if (options.levels.items.len == 0) {
        try options.levels.append(allocator, "fallback");
        try options.levels.append(allocator, "native");
    }
    if (options.modes.items.len == 0) {
        try options.modes.append(allocator, "quality");
        try options.modes.append(allocator, "speed");
    }

    var level_pairs: std.ArrayList(LevelPair) = .empty;
    defer level_pairs.deinit(allocator);
    for (options.levels.items) |name| {
        const level = vellz.simd.Level.fromName(name) orelse {
            std.debug.print("vellz-bench: unknown SIMD level '{s}'\n", .{name});
            return usage();
        };
        try level_pairs.append(allocator, .{ .name = name, .level = level });
    }

    var results: std.ArrayList(RunResult) = .empty;
    defer results.deinit(allocator);

    // Environment header (plan.md §12: record hardware, build mode, threads).
    std.debug.print(
        "# vellz CPU benchmark\n\n" ++
            "- CPU: {s}\n" ++
            "- Build: {s}, Zig {s}\n" ++
            "- Detected SIMD level: {s}\n" ++
            "- Threads: {d} (0 = single-threaded dispatch)\n" ++
            "- Runs per sample: {d} (warmup {d}), statistic: {s}\n" ++
            "- Clock: std.Io monotonic wall time; phases from RasterizerSettings.timings\n",
        .{
            builtin.cpu.model.name,
            @tagName(builtin.mode),
            builtin.zig_version_string,
            @tagName(vellz.simd.Level.detect()),
            options.threads,
            options.runs,
            options.warmup,
            @tagName(options.stat),
        },
    );

    for (options.scenes.items) |scene_path| {
        for (options.modes.items) |mode_name| {
            const mode: cpu.RenderMode = if (std.mem.eql(u8, mode_name, "quality"))
                .optimize_quality
            else if (std.mem.eql(u8, mode_name, "speed"))
                .optimize_speed
            else
                return usage();
            for (level_pairs.items) |pair| {
                const result = try benchScene(
                    allocator,
                    scene_path,
                    mode,
                    mode_name,
                    pair,
                    options,
                );
                try results.append(allocator, result);
            }
        }
    }

    var stdout_buffer: [4096]u8 = undefined;
    var file_writer = std.Io.File.stdout().writerStreaming(init.io, &stdout_buffer);
    try printTables(&file_writer.interface, allocator, results.items, options.stat);
    try file_writer.flush();
}

fn usage() error{InvalidArguments} {
    std.debug.print(
        "usage: vellz-bench [--scene PATH]... [--runs N] [--warmup N] " ++
            "[--levels fallback,native] [--modes quality,speed] [--threads N]\n",
        .{},
    );
    return error.InvalidArguments;
}

/// Read and plan one scene; load image assets once (excluded from the
/// per-iteration numbers and reported as `setup`).
fn loadPlan(allocator: std.mem.Allocator, scene_path: []const u8) !Plan {
    const text = try std.Io.Dir.cwd().readFileAlloc(clock_io, scene_path, allocator, .unlimited);
    defer allocator.free(text);

    var parsed = scene_mod.parse(allocator, text) catch return error.InvalidScene;
    errdefer parsed.deinit();
    const scene = parsed.scene;

    // The plan copies everything it needs so the parsed arena can be freed.
    var ops: std.ArrayList(Op) = .empty;
    errdefer ops.deinit(allocator);
    var image_spec: ?scene_mod.ImageSpec = null;

    for (scene.commands) |command| {
        switch (command) {
            .set_paint => |spec| {
                if (spec == .image) image_spec = spec.image;
                try ops.append(allocator, .{ .set_paint = spec });
            },
            .set_paint_transform => |affine| try ops.append(allocator, .{ .set_paint_transform = affine }),
            .reset_paint_transform => try ops.append(allocator, .reset_paint_transform),
            .set_transform => |affine| try ops.append(allocator, .{ .set_transform = affine }),
            .reset_transform => try ops.append(allocator, .reset_transform),
            .fill_rect => |rect| try ops.append(allocator, .{ .fill_rect = rect }),
            .fill_path => |svg| try ops.append(allocator, .{ .fill_path = svg }),
            .reset => {}, // handled by the harness
            else => {
                std.debug.print(
                    "vellz-bench: scene '{s}' uses a command this harness does not plan\n",
                    .{scene_path},
                );
                return error.UnsupportedCommand;
            },
        }
    }

    const scene_dir = std.fs.path.dirname(scene_path) orelse ".";

    var plan = Plan{
        .parsed = parsed,
        .width = scene.width,
        .height = scene.height,
        .ops = try ops.toOwnedSlice(allocator),
    };

    if (image_spec) |spec| {
        const pixmap = try loadRawPixmap(allocator, scene_dir, spec);
        plan.image_handle = common.shared.Shared(common.pixmap.Pixmap).create(
            allocator,
            pixmap,
        ) catch |err| {
            var owned = pixmap;
            owned.deinit(allocator);
            return err;
        };
        plan.image_spec = spec;
    }

    return plan;
}

fn freePlan(allocator: std.mem.Allocator, plan: *Plan) void {
    allocator.free(plan.ops);
    if (plan.image_handle) |handle| handle.release(allocator);
    plan.parsed.deinit();
}

fn loadRawPixmap(
    allocator: std.mem.Allocator,
    scene_dir: []const u8,
    spec: scene_mod.ImageSpec,
) !common.pixmap.Pixmap {
    const path = try std.fs.path.join(allocator, &.{ scene_dir, spec.asset });
    defer allocator.free(path);

    const bytes = try std.Io.Dir.cwd().readFileAlloc(clock_io, path, allocator, .unlimited);
    defer allocator.free(bytes);
    if (spec.format == .bgra8) {
        var i: usize = 0;
        while (i + 3 < bytes.len) : (i += 4) std.mem.swap(u8, &bytes[i], &bytes[i + 2]);
    }

    const peniko_alpha: peniko.ImageAlphaType = switch (spec.alpha_type) {
        .alpha => .alpha,
        .premultiplied => .alpha_premultiplied,
    };
    const metadata = common.pixmap.PixelMetadata.new(peniko_alpha, true);
    return common.pixmap.Pixmap.fromParts(allocator, bytes, spec.width, spec.height, metadata);
}

fn benchScene(
    allocator: std.mem.Allocator,
    scene_path: []const u8,
    mode: cpu.RenderMode,
    mode_name: []const u8,
    pair: LevelPair,
    options: Options,
) !RunResult {
    var plan = try loadPlan(allocator, scene_path);
    defer freePlan(allocator, &plan);

    const settings: cpu.RenderSettings = .{
        .level = pair.level,
        .num_threads = options.threads,
    };
    var ctx = try cpu.RenderContext.init(allocator, plan.width, plan.height, settings);
    defer ctx.deinit(allocator);
    var resources = cpu.Resources.init();
    defer resources.deinit(allocator);
    var pixmap = try common.pixmap.Pixmap.init(allocator, plan.width, plan.height);
    defer pixmap.deinit(allocator);

    var timings = cpu.settings.StageTimings{ .now_ns = nowNs };
    const rasterizer: cpu.RasterizerSettings = .{
        .render_mode = mode,
        .target_init = .{ .clear = peniko.color.Color.TRANSPARENT },
        .pixel_format = .rgba8,
        .offset = .{ .x = 0, .y = 0 },
        .timings = &timings,
    };

    // One-time setup: renderer/pixmap allocation first-touch.
    const setup_start = nowNs();
    @memset(pixmap.dataAsU8SliceMut(), 0);
    const setup_ns = nowNs() - setup_start;

    // Sample buffers: 6 phases per run.
    const runs = @max(options.runs, 1);
    var samples = try allocator.alloc(Sample, runs);
    defer allocator.free(samples);

    var iter: usize = 0;
    const total_iters = options.warmup + runs;
    while (iter < total_iters) : (iter += 1) {
        const sample_start = nowNs();
        // ------------------------------------------------ construction phase
        var construct_ns: u64 = 0;
        var preprocess_ns: u64 = 0;
        const reset_start = nowNs();
        ctx.reset();
        construct_ns += nowNs() - reset_start;

        for (plan.ops) |op| {
            switch (op) {
                .set_paint => |spec| {
                    const start = nowNs();
                    try applyPaint(allocator, &ctx, &plan, spec);
                    construct_ns += nowNs() - start;
                },
                .set_paint_transform => |affine| {
                    const start = nowNs();
                    ctx.setPaintTransform(kurbo.Affine.new(affine));
                    construct_ns += nowNs() - start;
                },
                .reset_paint_transform => ctx.resetPaintTransform(),
                .set_transform => |affine| ctx.setTransform(kurbo.Affine.new(affine)),
                .reset_transform => ctx.resetTransform(),
                .fill_rect => |rect| {
                    const start = nowNs();
                    try ctx.fillRect(allocator, kurbo.Rect.new(rect[0], rect[1], rect[2], rect[3]));
                    preprocess_ns += nowNs() - start;
                },
                .fill_path => |svg| {
                    const parse_start = nowNs();
                    var path = kurbo.bezpath.fromSvg(allocator, svg) catch return error.InvalidPath;
                    construct_ns += nowNs() - parse_start;
                    defer {
                        path.deinit(allocator);
                        path = undefined;
                    }
                    const start = nowNs();
                    try ctx.fillPath(allocator, path.elements.items);
                    preprocess_ns += nowNs() - start;
                },
            }
        }

        const flush_start = nowNs();
        try ctx.flush();
        preprocess_ns += nowNs() - flush_start;

        // -------------------------------------------------- rasterization
        timings.bucket_ns = 0;
        timings.fine_ns = 0;
        const render_start = nowNs();
        try ctx.renderWith(&pixmap, &resources, rasterizer);
        const render_ns = nowNs() - render_start;
        const total_ns = nowNs() - sample_start;

        const sample = Sample{
            .construct_ns = construct_ns,
            .preprocess_ns = preprocess_ns,
            .bucket_ns = timings.bucket_ns,
            .fine_ns = timings.fine_ns,
            .render_ns = render_ns,
            .total_ns = total_ns,
        };
        if (iter >= options.warmup) {
            samples[iter - options.warmup] = sample;
        }
    }

    var stats: [6]Stats = undefined;
    inline for (all_phases) |phase| {
        const values = try allocator.alloc(u64, runs);
        defer allocator.free(values);
        for (samples, 0..) |sample, i| {
            values[i] = sample.get(phase);
        }
        std.mem.sort(u64, values, {}, std.sort.asc(u64));
        const min = values[0];
        const median = values[values.len / 2];
        var sum: u128 = 0;
        for (values) |value| sum += value;
        stats[@intFromEnum(phase)] = .{
            .min_ns = min,
            .median_ns = median,
            .mean_ns = @intCast(sum / values.len),
        };
    }

    return .{
        .scene = scene_path,
        .mode_name = mode_name,
        .level_name = pair.name,
        .stats = stats,
        .setup_ns = setup_ns,
        .pixmap_hash = fnv1a(pixmap.dataAsU8Slice()),
    };
}

fn fnv1a(bytes: []const u8) u64 {
    var hash: u64 = 0xcbf2_9ce4_8422_2325;
    for (bytes) |byte| {
        hash ^= byte;
        hash *%= 0x0000_0100_0000_01b3;
    }
    return hash;
}

/// Apply one scene paint; gradient stops and image handles are rebuilt every
/// iteration exactly like a frame that re-submits its paints.
fn applyPaint(
    allocator: std.mem.Allocator,
    ctx: *cpu.RenderContext,
    plan: *const Plan,
    spec: scene_mod.PaintSpec,
) !void {
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
            gradient.stops = try peniko.ColorStops.fromSlice(allocator, stops);
            ctx.setPaint(common.paint.PaintType.fromGradient(gradient));
        },
        .image => |img| {
            const template = plan.image_handle orelse return error.MissingAsset;
            const image = common.paint.Image{
                .image = common.paint.ImageSource.initPixmap(template.clone()),
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

fn statValue(stats: Stats, kind: StatKind) u64 {
    return switch (kind) {
        .min => stats.min_ns,
        .median => stats.median_ns,
        .mean => stats.mean_ns,
    };
}

fn printTables(
    writer: *std.Io.Writer,
    allocator: std.mem.Allocator,
    results: []const RunResult,
    stat: StatKind,
) !void {
    // Raw per-scene table.
    try writer.print(
        "\n## Per-scene phase times ({s}, microseconds) and output hash\n\n",
        .{@tagName(stat)},
    );
    try writer.writeAll(
        "| scene | mode | level | setup | construct | preprocess | bucket | fine | render | total | fnv1a |\n" ++
            "| --- | --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |\n",
    );
    for (results) |result| {
        try writer.print(
            "| {s} | {s} | {s} | {d} | {d} | {d} | {d} | {d} | {d} | {d} | {x:0>16} |\n",
            .{
                shortName(result.scene),
                result.mode_name,
                result.level_name,
                toUs(result.setup_ns),
                toUs(statValue(result.stats[@intFromEnum(Phase.construct)], stat)),
                toUs(statValue(result.stats[@intFromEnum(Phase.preprocess)], stat)),
                toUs(statValue(result.stats[@intFromEnum(Phase.bucket)], stat)),
                toUs(statValue(result.stats[@intFromEnum(Phase.fine)], stat)),
                toUs(statValue(result.stats[@intFromEnum(Phase.render)], stat)),
                toUs(statValue(result.stats[@intFromEnum(Phase.total)], stat)),
                result.pixmap_hash,
            },
        );
    }

    // Speedup summary: consecutive levels per (scene, mode), first is the
    // baseline (normally `fallback`).
    try writer.writeAll("\n## Speedup vs first level (from selected statistic)\n\n");
    var header_levels: std.ArrayList([]const u8) = .empty;
    defer header_levels.deinit(allocator);
    for (results) |result| {
        if (std.mem.eql(u8, result.scene, results[0].scene) and
            std.mem.eql(u8, result.mode_name, results[0].mode_name))
        {
            try header_levels.append(allocator, result.level_name);
        }
    }

    try writer.writeAll("| scene | mode | phase |");
    for (header_levels.items[1..]) |name| {
        try writer.print(" {s} (x) |", .{name});
    }
    try writer.writeAll("\n| --- | --- | --- |");
    for (header_levels.items[1..]) |_| try writer.writeAll(" ---: |");
    try writer.writeAll("\n");

    const group = header_levels.items.len;
    var i: usize = 0;
    while (i + group <= results.len) : (i += group) {
        const base = results[i];
        for (all_phases) |phase| {
            try writer.print(
                "| {s} | {s} | {s} |",
                .{ shortName(base.scene), base.mode_name, phase.label() },
            );
            const base_ns = statValue(base.stats[@intFromEnum(phase)], stat);
            for (results[i + 1 ..][0 .. group - 1]) |other| {
                const other_ns = statValue(other.stats[@intFromEnum(phase)], stat);
                if (base_ns == 0 or other_ns == 0) {
                    try writer.writeAll(" n/a |");
                } else {
                    try writer.print(" {d:.2} |", .{@as(f64, @floatFromInt(base_ns)) /
                        @as(f64, @floatFromInt(other_ns))});
                }
            }
            try writer.writeAll("\n");
        }
    }

    try writer.writeAll(
        "\n`fallback` is the scalar backend; `native` is the level detected for the build target.\n" ++
            "`bucket`/`fine` are measured inside `renderWith` via `RasterizerSettings.timings`;\n" ++
            "`render` is the whole `renderWith` call, so `bucket + fine <= render`.\n" ++
            "All levels of a (scene, mode) row must print the same `fnv1a` hash; `min` is the\n" ++
            "robust default statistic on shared/contended machines (`--stat median` for medians).\n",
    );
}

fn shortName(path: []const u8) []const u8 {
    return std.fs.path.stem(path);
}

fn toUs(ns: u64) u64 {
    return ns / std.time.ns_per_us;
}
