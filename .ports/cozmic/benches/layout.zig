const std = @import("std");
const cozmic = @import("cozmic");

const arabic_txt = @embedFile("data/arabic.txt");
const hebrew_txt = @embedFile("data/hebrew.txt");
const emoji_txt = @embedFile("data/emoji.txt");
const hello_txt = @embedFile("data/hello.txt");
const moby_txt = @embedFile("data/moby.txt");

fn initFontSystem(arena: std.mem.Allocator, io: std.Io) !cozmic.FontSystem {
    var fsys = try cozmic.FontSystem.init(arena);
    errdefer fsys.deinit();
    const fonts = [_]struct { file: []const u8, family: []const u8, mono: bool }{
        .{ .file = "tests/fonts/Inter-Regular.ttf", .family = "Inter", .mono = false },
        .{ .file = "tests/fonts/NotoSansArabic.ttf", .family = "Noto Sans Arabic", .mono = false },
        .{ .file = "tests/fonts/NotoSansHebrew.ttf", .family = "Noto Sans Hebrew", .mono = false },
        .{ .file = "tests/fonts/FiraMono-Medium.ttf", .family = "FiraMono", .mono = true },
    };
    for (fonts) |f| {
        const bytes = std.Io.Dir.cwd().readFileAlloc(io, f.file, arena, .limited(1 << 24)) catch continue;
        const id = fsys.dbMut().addFace(f.file, 0, &.{f.family}, f.family, cozmic.font_system.WEIGHT_NORMAL, .normal, .normal, f.mono) catch {
            arena.free(bytes);
            continue;
        };
        fsys.addFontData(id, bytes, 0, false, null) catch {};
        arena.free(bytes);
    }
    // Deterministic generic-family resolution, mirroring the upstream
    // bench-fairness patch (`set_sans_serif_family("Inter")` /
    // `set_monospace_family("FiraMono")`); the host has no Inter/FiraMono,
    // so queries resolve to the vendored faces.
    try fsys.dbMut().setSansFamily("Inter");
    try fsys.dbMut().setMonoFamily("FiraMono");
    return fsys;
}

fn parseArgs(args: []const []const u8) struct { iters: usize, warmup: usize, json: bool } {
    var iters: usize = 20;
    var warmup: usize = 5;
    var json = false;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--iter") and i + 1 < args.len) {
            iters = std.fmt.parseInt(usize, args[i + 1], 10) catch iters;
            i += 1;
        } else if (std.mem.eql(u8, args[i], "--warmup") and i + 1 < args.len) {
            warmup = std.fmt.parseInt(usize, args[i + 1], 10) catch warmup;
            i += 1;
        } else if (std.mem.eql(u8, args[i], "--format") and i + 1 < args.len) {
            json = std.mem.eql(u8, args[i + 1], "json");
            i += 1;
        }
    }
    return .{ .iters = iters, .warmup = warmup, .json = json };
}

fn timeIt(
    arena: std.mem.Allocator,
    fsys: *cozmic.FontSystem,
    text: []const u8,
    wrap: cozmic.Wrap,
    shaping: cozmic.Shaping,
    width: ?f32,
    iters: usize,
    warmup: usize,
    io: std.Io,
) !struct { mean_ns: f64, median_ns: f64, glyphs: usize, runs: usize } {
    var attrs = cozmic.attrs.Attrs.init(arena);
    defer attrs.deinit();
    var glyphs: usize = 0;
    var runs: usize = 0;
    // Warmup (discard).
    var k: usize = 0;
    while (k < warmup) : (k += 1) {
        var buf = try cozmic.Buffer.initWithAllocator(arena, cozmic.Metrics.new(10, 10));
        defer buf.deinit();
        try buf.setText(text, &attrs, shaping, null);
        buf.setWrap(wrap);
        buf.setSize(width, null);
        try buf.shapeUntilScroll(fsys, false);
        var it = buf.layoutRuns();
        while (it.next()) |_| {}
    }
    var times = try arena.alloc(u64, iters);
    defer arena.free(times);
    k = 0;
    while (k < iters) : (k += 1) {
        var buf = try cozmic.Buffer.initWithAllocator(arena, cozmic.Metrics.new(10, 10));
        defer buf.deinit();
        try buf.setText(text, &attrs, shaping, null);
        buf.setWrap(wrap);
        buf.setSize(width, null);
        const t0 = std.Io.Clock.now(.awake, io);
        try buf.shapeUntilScroll(fsys, false);
        var it = buf.layoutRuns();
        var r: usize = 0;
        var g: usize = 0;
        while (it.next()) |run| {
            r += 1;
            g += run.glyphs.len;
        }
        const t1 = std.Io.Clock.now(.awake, io);
        times[k] = @intCast(t0.durationTo(t1).nanoseconds);
        runs = r;
        glyphs = g;
    }
    std.mem.sort(u64, times, {}, std.sort.asc(u64));
    var sum: f64 = 0;
    for (times) |t| sum += @floatFromInt(t);
    const mean = sum / @as(f64, @floatFromInt(times.len));
    const median: f64 = @floatFromInt(times[times.len / 2]);
    return .{ .mean_ns = mean, .median_ns = median, .glyphs = glyphs, .runs = runs };
}

/// Mirrors `load FontSystem` in benches/layout.rs: construct a `FontSystem`
/// and load system fonts, once per iteration.
///
/// Harness note: upstream `FontSystem::new()` parses face metadata via fontdb
/// (plus fontconfig), while cozmic's `loadSystemFonts` registers face
/// metadata found by scanning font dirs; the numbers are comparable at the
/// scan-vs-load level but not byte-for-byte.
fn timeLoadFontSystem(
    arena: std.mem.Allocator,
    io: std.Io,
    iters: usize,
    warmup: usize,
) !struct { mean_ns: f64, median_ns: f64, faces: usize } {
    var faces: usize = 0;
    var k: usize = 0;
    while (k < warmup) : (k += 1) {
        var fsys = try cozmic.FontSystem.init(arena);
        const stats = fsys.loadSystemFonts(io);
        faces = stats.faces_added;
        fsys.deinit();
    }
    var times = try arena.alloc(u64, iters);
    defer arena.free(times);
    k = 0;
    while (k < iters) : (k += 1) {
        const t0 = std.Io.Clock.now(.awake, io);
        var fsys = try cozmic.FontSystem.init(arena);
        const stats = fsys.loadSystemFonts(io);
        fsys.deinit();
        const t1 = std.Io.Clock.now(.awake, io);
        times[k] = @intCast(t0.durationTo(t1).nanoseconds);
        faces = stats.faces_added;
    }
    std.mem.sort(u64, times, {}, std.sort.asc(u64));
    var sum: f64 = 0;
    for (times) |t| sum += @floatFromInt(t);
    return .{
        .mean_ns = sum / @as(f64, @floatFromInt(times.len)),
        .median_ns = @floatFromInt(times[times.len / 2]),
        .faces = faces,
    };
}

/// Mirrors benches/layout.rs: Wrap(None,Glyph,Word) x Shaping(Simple,Advanced)
/// over small + Moby Dick + arabic/hebrew/emoji, plus the `load FontSystem`
/// bench. Metrics(10,10), width 80. WordOrGlyph kept as Zig-only extra row
/// (Rust bench has no such row).
pub fn main(init: std.process.Init) !void {
    const arena: std.mem.Allocator = init.arena.allocator();
    const io = init.io;
    const args = try init.minimal.args.toSlice(arena);
    const opts = parseArgs(args[1..]);

    var out_buf: [8192]u8 = undefined;
    var out: std.Io.File.Writer = .init(.stdout(), io, &out_buf);
    const w = &out.interface;

    var fsys = try initFontSystem(arena, io);
    defer fsys.deinit();
    const samples = [_]struct { name: []const u8, text: []const u8 }{
        .{ .name = "small", .text = "Hello, world!" },
        .{ .name = "moby", .text = moby_txt },
        .{ .name = "arabic", .text = arabic_txt },
        .{ .name = "hebrew", .text = hebrew_txt },
        .{ .name = "emoji", .text = emoji_txt },
        .{ .name = "hello_mixed", .text = hello_txt },
    };
    // Comparison rows (match Rust bench): None/Glyph/Word x Simple/Advanced.
    // WordOrGlyph is extra coverage with no upstream bench row.
    const wraps = [_]cozmic.Wrap{ .none, .glyph, .word, .word_or_glyph };
    const shapings = [_]struct { name: []const u8, mode: cozmic.Shaping }{
        .{ .name = "simple", .mode = .basic },
        .{ .name = "advanced", .mode = .advanced },
    };

    if (!opts.json) try w.print("cozmic bench-layout: wrap x shaping matrix over {d} samples (iters={d} warmup={d})\n", .{ samples.len, opts.iters, opts.warmup });
    for (samples) |s| {
        for (wraps) |wrap| {
            for (shapings) |shape| {
                const r = try timeIt(arena, &fsys, s.text, wrap, shape.mode, 80, opts.iters, opts.warmup, io);
                const extra = if (wrap == .word_or_glyph) " (zig-only, no rust row)" else "";
                if (opts.json) {
                    try w.print("{{\"bench\":\"layout/{s}/Wrap({s}, {s})\",\"iters\":{d},\"mean_ns\":{d:.1},\"median_ns\":{d:.1},\"glyphs\":{d},\"runs\":{d}}}\n", .{ s.name, @tagName(wrap), shape.name, opts.iters, r.mean_ns, r.median_ns, r.glyphs, r.runs });
                } else {
                    try w.print("  {s} wrap={s} shape={s} width=80 runs={d} glyphs={d} mean={d:.0}ns median={d:.0}ns{s}\n", .{
                        s.name, @tagName(wrap), shape.name, r.runs, r.glyphs, r.mean_ns, r.median_ns, extra,
                    });
                }
            }
        }
    }

    // `load FontSystem` (upstream benches/layout.rs).
    const fl = try timeLoadFontSystem(arena, io, opts.iters, opts.warmup);
    if (opts.json) {
        try w.print("{{\"bench\":\"loadFontSystem\",\"iters\":{d},\"mean_ns\":{d:.1},\"median_ns\":{d:.1},\"faces\":{d}}}\n", .{ opts.iters, fl.mean_ns, fl.median_ns, fl.faces });
    } else {
        try w.print("  loadFontSystem faces={d} mean={d:.0}ns median={d:.0}ns\n", .{ fl.faces, fl.mean_ns, fl.median_ns });
    }
    try w.flush();
}
