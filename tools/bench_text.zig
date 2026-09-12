//! Headless text-frame benchmark: the real element path on the cozmic engine.
//!
//! Builds frames of N text nodes (14px labels, 16px sentences, 16px wrapped
//! paragraphs), then times `elements.layout.layout` (measure + place) and
//! `elements.painter.paint` (glyph emission into a `gpu.Scene`) separately and
//! together, reporting ns/node, ns/char, scene glyphs and capacity drops. No
//! window or backend is created, so the run is `ZUI_BACKEND`-independent.
//!
//! Text rendering is always cozmic; there is no engine switch any more:
//!   zig build bench-text
//!   zig build bench-text -- --format json --iter 9 --warmup 3
//!
//! The engine is created once from the vendored corpus so runs are
//! host-independent, with the same host-system-font fallback the App's lazy
//! init uses. The cold row reports engine init plus the first frame. Use
//! `-Doptimize=ReleaseFast` for frame-cost numbers: Debug (the default) is
//! roughly an order slower.
//!
//! Layout reuse: `layout.measure` retains its per-node cozmic layout and
//! `painter` emits from it when the inputs match, so each text node is shaped
//! once per frame. Element rows report `shapes=` as `layout+paint` to make
//! that observable (`paint` is 0). The `raw` rows keep shaping in both spans,
//! so `shape/(shape+paint)` stays the share of cozmic work the retained
//! layout removes.

const std = @import("std");
const zui = @import("zui");
const cozmic = @import("cozmic");
const text_engine = zui.text_engine;
const elements = zui.elements;
const element = elements.element;

const engine_name = "cozmic";

const default_iters: usize = 9;
const default_warmup: usize = 3;
const quick_iters: usize = 3;
const quick_warmup: usize = 1;

/// Short UI labels, 14px.
const labels = [_][]const u8{
    "Inbox", "Today",  "Upcoming", "Completed",
    "Notes", "Search", "Settings", "Archive",
};

/// Sentences, 16px.
const sentences = [_][]const u8{
    "The quick brown fox jumps over the lazy dog.",
    "Pack my box with five dozen liquor jugs.",
    "How vexingly quick daft zebras jump!",
    "Sphinx of black quartz, judge my vow.",
};

/// Paragraphs, 16px, wrapped at 360px.
const paragraphs = [_][]const u8{
    "ZUI rebuilds transient elements every dirty frame: a layout pass sizes each node and a painter records quads and glyphs into one scene. Text cost lands in both phases, because each phase shapes its own cozmic layout.",
    "Element rows reuse the measured layout, so only the raw rows pay a second shape. This benchmark reports how much of the frame that uncached shaping costs.",
};

const Config = struct {
    name: []const u8,
    size: f32,
    /// Explicit width, which is both the measured slot and cozmic's wrap
    /// constraint (`text_engine.wrapWidth`). Null is unbounded.
    wrap: ?f32,
    texts: []const []const u8,
};

const configs = [_]Config{
    .{ .name = "label-14", .size = 14, .wrap = null, .texts = &labels },
    .{ .name = "sentence-16", .size = 16, .wrap = null, .texts = &sentences },
    .{ .name = "paragraph-16-wrap360", .size = 16, .wrap = 360, .texts = &paragraphs },
};

const node_counts = [_]usize{ 1, 16, 64, 256 };

/// Wide enough that unbounded rows stay single-line and the 360px paragraphs
/// keep their wrap width; tall enough not to clip the column in practice.
const viewport = zui.Rect{ .x = 0, .y = 0, .w = 720, .h = 4000 };

const Options = struct {
    iters: usize = default_iters,
    warmup: usize = default_warmup,
    json: bool = false,
};

fn truthy(value: []const u8) bool {
    return value.len != 0 and
        !std.mem.eql(u8, value, "0") and
        !std.ascii.eqlIgnoreCase(value, "false") and
        !std.ascii.eqlIgnoreCase(value, "no");
}

fn parseArgs(args: []const []const u8, environ: *const std.process.Environ.Map) Options {
    var iters: ?usize = null;
    var warmup: ?usize = null;
    var json = false;
    var quick = false;
    var i: usize = 1; // args[0] is the program path.
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--iter") and i + 1 < args.len) {
            iters = std.fmt.parseInt(usize, args[i + 1], 10) catch iters;
            i += 1;
        } else if (std.mem.eql(u8, arg, "--warmup") and i + 1 < args.len) {
            warmup = std.fmt.parseInt(usize, args[i + 1], 10) catch warmup;
            i += 1;
        } else if (std.mem.eql(u8, arg, "--format") and i + 1 < args.len) {
            json = std.mem.eql(u8, args[i + 1], "json");
            i += 1;
        } else if (std.mem.eql(u8, arg, "--json")) {
            json = true;
        } else if (std.mem.eql(u8, arg, "--quick")) {
            quick = true;
        }
    }
    const env_quick = if (environ.get("ZUI_BENCH_QUICK")) |v| truthy(v) else false;
    const use_quick = quick or env_quick;
    return .{
        .iters = @max(iters orelse if (use_quick) quick_iters else default_iters, 1),
        .warmup = warmup orelse if (use_quick) quick_warmup else default_warmup,
        .json = json,
    };
}

fn now(io: std.Io) std.Io.Timestamp {
    return std.Io.Clock.now(.awake, io);
}

fn elapsedNs(from: std.Io.Timestamp, to: std.Io.Timestamp) u64 {
    return @intCast(@max(0, from.durationTo(to).nanoseconds));
}

fn nsToMs(ns: u64) f64 {
    return @as(f64, @floatFromInt(ns)) / std.time.ns_per_ms;
}

const Stats = struct {
    mean_ns: f64,
    median_ns: f64,

    /// Sorts `times` in place (callers no longer need the original order).
    fn from(times: []u64) Stats {
        var sum: f64 = 0;
        for (times) |value| sum += @floatFromInt(value);
        std.mem.sort(u64, times, {}, std.sort.asc(u64));
        return .{
            .mean_ns = sum / @as(f64, @floatFromInt(times.len)),
            .median_ns = @floatFromInt(times[times.len / 2]),
        };
    }
};

const EngineInit = struct {
    engine: ?*text_engine.Engine = null,
    corpus: bool = false,
    init_ns: u64 = 0,
    message: ?[]const u8 = null,
};

/// Lazy-once cozmic engine. Prefers the vendored corpus (`Engine.init`) so
/// runs are host-independent; only falls back to the App's system-font path
/// (`Engine.initSystem`) when the corpus is unavailable, and says so.
fn initEngine(alloc: std.mem.Allocator, io: std.Io) EngineInit {
    const start = now(io);
    var result = EngineInit{};
    if (text_engine.Engine.init(alloc)) |engine| {
        result.engine = engine;
        result.corpus = true;
    } else |err| {
        std.debug.print(
            "bench-text: vendored corpus engine init failed: {s}; trying host system fonts\n",
            .{@errorName(err)},
        );
        if (text_engine.Engine.initSystem(alloc)) |engine| {
            result.engine = engine;
            result.message = "engine loaded host system fonts (host-dependent)";
        } else |sys_err| {
            result.message = @errorName(sys_err);
            std.debug.print("bench-text: cozmic engine unavailable: {s}\n", .{@errorName(sys_err)});
        }
    }
    result.init_ns = elapsedNs(start, now(io));
    return result;
}

fn buildFrame(
    frame: *element.Frame,
    engine: *text_engine.Engine,
    alloc: std.mem.Allocator,
    cfg: Config,
    n: usize,
) element.Element {
    frame.reset(@ptrFromInt(1), .{});
    frame.engine = engine;
    frame.allocator = alloc;
    element.beginFrame(frame);
    var root = element.div().p(8).gap(4);
    for (0..n) |i| {
        const value = cfg.texts[i % cfg.texts.len];
        // Same family the todo example uses for body text: the corpus has
        // Noto Sans.
        var node = element.text(value, .{ .font = "Noto Sans, sans-serif", .size = cfg.size });
        if (cfg.wrap) |width| node = node.w(width);
        root = root.child(node);
    }
    element.endFrame();
    return root;
}

fn configChars(cfg: Config, n: usize) usize {
    var total: usize = 0;
    for (0..n) |i| total += cfg.texts[i % cfg.texts.len].len;
    return total;
}

const ElementSample = struct {
    layout: Stats,
    paint: Stats,
    total: Stats,
    glyphs: usize,
    dropped: u64,
    cozmic_nodes: usize,
    cozmic_emitted: u64,
    cozmic_skipped: u64,
    cozmic_failures: u64,
    /// `Engine.layout` calls in the last timed iteration's layout span and
    /// paint span. With the measure→paint cache, cozmic rows show
    /// `layout_shapes == cozmic_nodes` and `paint_shapes == 0`.
    layout_shapes: u64,
    paint_shapes: u64,
};

/// Warm up (atlas, allocator, engine caches) and then time `iters` frames:
/// layout and paint are timed in separate spans of the same iteration, and
/// their per-iteration sum is the `total` series.
fn timeElement(
    arena: std.mem.Allocator,
    io: std.Io,
    frame: *element.Frame,
    engine: *text_engine.Engine,
    root: element.Element,
    scene: *zui.Scene,
    iters: usize,
    warmup: usize,
) !ElementSample {
    const layout_times = try arena.alloc(u64, iters);
    const paint_times = try arena.alloc(u64, iters);
    const total_times = try arena.alloc(u64, iters);
    // Drops from the last timed paint (the frame is identical each iteration,
    // so one paint's count describes the row; summing would scale with iters).
    var dropped: u64 = 0;
    // Shape calls of the last timed iteration, split measure vs paint.
    var layout_shapes: u64 = 0;
    var paint_shapes: u64 = 0;

    var k: usize = 0;
    while (k < warmup + iters) : (k += 1) {
        const timed = k >= warmup;
        const shapes_before = engine.layout_calls;
        const layout_start = now(io);
        elements.layout.layout(frame, root, viewport);
        const layout_end = now(io);
        const shapes_after_layout = engine.layout_calls;
        scene.clear();
        const dropped_before = scene.dropped;
        const paint_start = now(io);
        elements.painter.paint(frame, root, scene);
        const paint_end = now(io);
        const shapes_after_paint = engine.layout_calls;
        if (timed) {
            const layout_ns = elapsedNs(layout_start, layout_end);
            const paint_ns = elapsedNs(paint_start, paint_end);
            layout_times[k - warmup] = layout_ns;
            paint_times[k - warmup] = paint_ns;
            total_times[k - warmup] = layout_ns + paint_ns;
            dropped = scene.dropped - dropped_before;
            layout_shapes = shapes_after_layout - shapes_before;
            paint_shapes = shapes_after_paint - shapes_after_layout;
        }
    }

    var cozmic_nodes: usize = 0;
    for (frame.nodes[0..frame.node_count]) |node| {
        if (node.kind != .text) continue;
        if (node.cozmic_measured) cozmic_nodes += 1;
    }

    return .{
        .layout = Stats.from(layout_times),
        .paint = Stats.from(paint_times),
        .total = Stats.from(total_times),
        .glyphs = scene.glyph_len,
        .dropped = dropped,
        .cozmic_nodes = cozmic_nodes,
        .cozmic_emitted = frame.cozmic_painted_glyphs,
        .cozmic_skipped = frame.cozmic_skipped_glyphs,
        .cozmic_failures = frame.cozmic_paint_failures,
        .layout_shapes = layout_shapes,
        .paint_shapes = paint_shapes,
    };
}

/// Minimal cozmic renderer: counts callbacks, draws nothing.
const RawRenderer = struct {
    glyphs: usize = 0,
    rects: usize = 0,

    fn renderer(self: *RawRenderer) cozmic.render.Renderer {
        return .{ .ctx = @ptrCast(self), .vtable = &vtable };
    }

    const vtable = cozmic.render.Renderer.VTable{
        .rectangle = rectangle,
        .glyph = glyph,
    };

    fn rectangle(ctx: *anyopaque, x: i32, y: i32, w: u32, h: u32, color: cozmic.Color) void {
        _ = .{ x, y, w, h, color };
        const self: *RawRenderer = @ptrCast(@alignCast(ctx));
        self.rects += 1;
    }

    fn glyph(ctx: *anyopaque, physical_glyph: cozmic.layout.PhysicalGlyph, color: cozmic.Color) void {
        _ = .{ physical_glyph, color };
        const self: *RawRenderer = @ptrCast(@alignCast(ctx));
        self.glyphs += 1;
    }
};

const RawPass = struct {
    shape_ns: u64,
    paint_ns: u64,
    glyphs: usize,
    failures: usize,
};

/// One raw bridge pass over every text node: `Engine.layout` (measure-phase
/// shape) then `Engine.paint` (paint-phase shape + render iteration). This is
/// exactly the pair of calls `text_engine.measure`/`painter.paintText` make,
/// minus ZUI's atlas work.
fn runRawPass(
    engine: *text_engine.Engine,
    alloc: std.mem.Allocator,
    frame: *const element.Frame,
    io: std.Io,
) RawPass {
    var failures: usize = 0;

    const shape_start = now(io);
    for (frame.nodes[0..frame.node_count]) |*node| {
        if (node.kind != .text) continue;
        var layout = engine.layout(
            alloc,
            node.text_value,
            elements.text_engine.attrs(node),
            elements.text_engine.wrapWidth(node),
        ) catch {
            failures += 1;
            continue;
        };
        layout.deinit();
    }
    const shape_end = now(io);

    var renderer = RawRenderer{};
    const paint_start = now(io);
    for (frame.nodes[0..frame.node_count]) |*node| {
        if (node.kind != .text) continue;
        _ = engine.paint(
            alloc,
            node.text_value,
            elements.text_engine.attrs(node),
            elements.text_engine.wrapWidth(node),
            renderer.renderer(),
        ) catch {
            failures += 1;
            continue;
        };
    }
    const paint_end = now(io);

    return .{
        .shape_ns = elapsedNs(shape_start, shape_end),
        .paint_ns = elapsedNs(paint_start, paint_end),
        .glyphs = renderer.glyphs,
        .failures = failures,
    };
}

const RawSample = struct {
    shape: Stats,
    paint: Stats,
    glyphs: usize,
    failures: usize,
};

fn timeRaw(
    arena: std.mem.Allocator,
    io: std.Io,
    engine: *text_engine.Engine,
    alloc: std.mem.Allocator,
    frame: *const element.Frame,
    iters: usize,
    warmup: usize,
) !RawSample {
    const shape_times = try arena.alloc(u64, iters);
    const paint_times = try arena.alloc(u64, iters);
    var failures: usize = 0;
    var glyphs: usize = 0;

    var k: usize = 0;
    while (k < warmup + iters) : (k += 1) {
        const pass = runRawPass(engine, alloc, frame, io);
        failures += pass.failures;
        if (k >= warmup) {
            shape_times[k - warmup] = pass.shape_ns;
            paint_times[k - warmup] = pass.paint_ns;
            glyphs = pass.glyphs;
        }
    }

    return .{
        .shape = Stats.from(shape_times),
        .paint = Stats.from(paint_times),
        .glyphs = glyphs,
        .failures = failures,
    };
}

const ColdSample = struct {
    config: []const u8,
    nodes: usize,
    chars: usize,
    engine_init_ns: u64,
    build_ns: u64,
    layout_ns: u64,
    paint_ns: u64,
};

fn note(w: *std.Io.Writer, json: bool, comptime fmt: []const u8, args: anytype) !void {
    var buf: [512]u8 = undefined;
    const text = std.fmt.bufPrint(&buf, fmt, args) catch "note formatting overflow";
    if (json) {
        // Bench notes only contain fixed text plus error-name/config tokens;
        // escape-free JSON strings are safe here.
        try w.print("{{\"bench\":\"text-frame\",\"kind\":\"note\",\"engine\":\"{s}\",\"text\":\"{s}\"}}\n", .{ engine_name, text });
    } else {
        try w.print("  note: {s}\n", .{text});
    }
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    const opts = parseArgs(args, init.environ_map);

    var out_buf: [8192]u8 = undefined;
    var out: std.Io.File.Writer = .initStreaming(.stdout(), io, &out_buf);
    const w = &out.interface;

    const engine_init_info = initEngine(gpa, io);
    const engine = engine_init_info.engine;
    defer if (engine) |e| e.deinit();

    if (opts.json) {
        try w.print(
            "{{\"bench\":\"text-frame\",\"kind\":\"header\",\"engine\":\"{s}\",\"iters\":{d},\"warmup\":{d},\"corpus\":{},\"node_counts\":[1,16,64,256]}}\n",
            .{ engine_name, opts.iters, opts.warmup, engine_init_info.corpus },
        );
    } else {
        try w.print(
            "zui bench-text: engine={s} iters={d} warmup={d}\n",
            .{ engine_name, opts.iters, opts.warmup },
        );
    }

    if (engine == null) {
        try note(w, opts.json, "cozmic engine unavailable: {s}", .{engine_init_info.message orelse "unknown"});
        try note(w, opts.json, "nothing measured: no engine means no text path (there is no legacy fallback)", .{});
        try w.flush();
        return;
    }
    if (engine_init_info.corpus) {
        try note(w, opts.json, "cozmic engine: vendored corpus (deterministic, host-independent)", .{});
    } else {
        try note(w, opts.json, "cozmic engine: host system fonts (host-dependent)", .{});
    }

    const frame = try gpa.create(element.Frame);
    defer gpa.destroy(frame);
    frame.* = .{};
    const scene = try gpa.create(zui.Scene);
    defer gpa.destroy(scene);
    scene.* = .{};

    // Cold first frame: engine init (already measured) plus the first build,
    // layout and paint, including the first glyph rasterization for the
    // frame's text.
    var cold: ?ColdSample = null;
    var any_dropped: u64 = 0;
    {
        const cold_cfg = configs[0];
        const cold_n = node_counts[1];
        const build_start = now(io);
        const root = buildFrame(frame, engine.?, gpa, cold_cfg, cold_n);
        const build_end = now(io);
        elements.layout.layout(frame, root, viewport);
        const layout_end = now(io);
        scene.clear();
        elements.painter.paint(frame, root, scene);
        const paint_end = now(io);
        cold = .{
            .config = cold_cfg.name,
            .nodes = cold_n,
            .chars = configChars(cold_cfg, cold_n),
            .engine_init_ns = engine_init_info.init_ns,
            .build_ns = elapsedNs(build_start, build_end),
            .layout_ns = elapsedNs(build_end, layout_end),
            .paint_ns = elapsedNs(layout_end, paint_end),
        };
    }

    for (configs) |cfg| {
        for (node_counts) |n| {
            const chars = configChars(cfg, n);
            const root = buildFrame(frame, engine.?, gpa, cfg, n);

            const sample = try timeElement(arena, io, frame, engine.?, root, scene, opts.iters, opts.warmup);
            any_dropped += sample.dropped;
            const total_ns = sample.total.median_ns;
            const ns_per_node = total_ns / @as(f64, @floatFromInt(n));
            const ns_per_char = total_ns / @as(f64, @floatFromInt(chars));
            if (sample.cozmic_nodes != n) {
                try note(w, opts.json, "{s} n={d}: engine measured {d}/{d} text nodes (shape failure evidence)", .{ cfg.name, n, sample.cozmic_nodes, n });
            }
            if (opts.json) {
                try w.print(
                    "{{\"bench\":\"text-frame\",\"kind\":\"element\",\"engine\":\"{s}\",\"config\":\"{s}\",\"nodes\":{d},\"chars\":{d},\"iters\":{d},\"layout_mean_ns\":{d:.1},\"layout_median_ns\":{d:.1},\"paint_mean_ns\":{d:.1},\"paint_median_ns\":{d:.1},\"total_mean_ns\":{d:.1},\"total_median_ns\":{d:.1},\"ns_per_node\":{d:.1},\"ns_per_char\":{d:.2},\"scene_glyphs\":{d},\"scene_dropped\":{d},\"cozmic_nodes\":{d},\"cozmic_emitted\":{d},\"cozmic_skipped\":{d},\"cozmic_failures\":{d},\"layout_shapes\":{d},\"paint_shapes\":{d}}}\n",
                    .{
                        engine_name,             cfg.name,               n,
                        chars,                   opts.iters,             sample.layout.mean_ns,
                        sample.layout.median_ns, sample.paint.mean_ns,   sample.paint.median_ns,
                        sample.total.mean_ns,    sample.total.median_ns, ns_per_node,
                        ns_per_char,             sample.glyphs,          sample.dropped,
                        sample.cozmic_nodes,     sample.cozmic_emitted,  sample.cozmic_skipped,
                        sample.cozmic_failures,  sample.layout_shapes,   sample.paint_shapes,
                    },
                );
            } else {
                try w.print(
                    "  {s:<22} n={d:<3} chars={d:<5} layout={d:<10.0} paint={d:<10.0} total={d:<10.0} mean={d:<10.0} ns/node={d:<9.1} ns/char={d:<8.2} glyphs={d} shapes={d}+{d}",
                    .{
                        cfg.name,               n,
                        chars,                  sample.layout.median_ns,
                        sample.paint.median_ns, sample.total.median_ns,
                        sample.total.mean_ns,   ns_per_node,
                        ns_per_char,            sample.glyphs,
                        sample.layout_shapes,   sample.paint_shapes,
                    },
                );
                if (sample.dropped > 0) try w.print(" dropped={d}", .{sample.dropped});
                if (sample.cozmic_failures > 0) try w.print(" failures={d}", .{sample.cozmic_failures});
                if (sample.cozmic_skipped > 0) try w.print(" no-ink={d}", .{sample.cozmic_skipped});
                try w.print("\n", .{});
            }

            const raw_sample = try timeRaw(arena, io, engine.?, gpa, frame, opts.iters, opts.warmup);
            const sum_shape = raw_sample.shape.median_ns;
            const sum_paint = raw_sample.paint.median_ns;
            const sum_ns = sum_shape + sum_paint;
            const shape_share = if (sum_ns > 0) 100.0 * sum_shape / sum_ns else 0;
            const raw_ns_per_node = sum_ns / @as(f64, @floatFromInt(n));
            const raw_ns_per_char = sum_ns / @as(f64, @floatFromInt(chars));
            if (opts.json) {
                try w.print(
                    "{{\"bench\":\"text-frame\",\"kind\":\"raw\",\"engine\":\"{s}\",\"config\":\"{s}\",\"nodes\":{d},\"chars\":{d},\"iters\":{d},\"shape_mean_ns\":{d:.1},\"shape_median_ns\":{d:.1},\"raw_paint_mean_ns\":{d:.1},\"raw_paint_median_ns\":{d:.1},\"sum_median_ns\":{d:.1},\"ns_per_node\":{d:.1},\"ns_per_char\":{d:.2},\"reshape_share_pct\":{d:.2},\"raw_glyphs\":{d},\"failures\":{d}}}\n",
                    .{
                        engine_name,                cfg.name,                 n,
                        chars,                      opts.iters,               raw_sample.shape.mean_ns,
                        raw_sample.shape.median_ns, raw_sample.paint.mean_ns, raw_sample.paint.median_ns,
                        sum_ns,                     raw_ns_per_node,          raw_ns_per_char,
                        shape_share,                raw_sample.glyphs,        raw_sample.failures,
                    },
                );
            } else {
                try w.print(
                    "  raw {s:<18} n={d:<3} chars={d:<5} shape={d:<10.0} paint={d:<10.0} sum={d:<10.0} reshape={d:<6.1}% ns/node={d:<9.1} ns/char={d:<8.2} glyphs={d}",
                    .{
                        cfg.name,                   n,
                        chars,                      raw_sample.shape.median_ns,
                        raw_sample.paint.median_ns, sum_ns,
                        shape_share,                raw_ns_per_node,
                        raw_ns_per_char,            raw_sample.glyphs,
                    },
                );
                if (raw_sample.failures > 0) try w.print(" failures={d}", .{raw_sample.failures});
                try w.print("\n", .{});
            }
        }
    }

    if (cold) |c| {
        const total_ns = c.engine_init_ns + c.build_ns + c.layout_ns + c.paint_ns;
        if (opts.json) {
            try w.print(
                "{{\"bench\":\"text-frame\",\"kind\":\"cold\",\"engine\":\"{s}\",\"config\":\"{s}\",\"nodes\":{d},\"chars\":{d},\"engine_init_ns\":{d},\"build_ns\":{d},\"layout_ns\":{d},\"paint_ns\":{d},\"total_ns\":{d}}}\n",
                .{ engine_name, c.config, c.nodes, c.chars, c.engine_init_ns, c.build_ns, c.layout_ns, c.paint_ns, total_ns },
            );
        } else {
            try w.print(
                "  cold {s} n={d}: engine_init={d:.2}ms build={d:.3}ms layout={d:.3}ms paint={d:.3}ms total={d:.2}ms\n",
                .{
                    c.config,           c.nodes,             nsToMs(c.engine_init_ns),
                    nsToMs(c.build_ns), nsToMs(c.layout_ns), nsToMs(c.paint_ns),
                    nsToMs(total_ns),
                },
            );
        }
    }

    try note(w, opts.json, "element rows reuse the measure layout (shapes=layout+paint); raw rows shape in both spans and bound the uncached cost", .{});
    if (any_dropped > 0) {
        try note(w, opts.json, "scene capacity capped emission ({d} pushes dropped): shaping/rasterization still ran, see scene_dropped per row", .{any_dropped});
    }
    try note(w, opts.json, "engine init measured separately; warm rows reuse the engine (App lazy-once model)", .{});

    try w.flush();
}
