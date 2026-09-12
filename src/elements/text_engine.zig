//! Element text-style → cozmic engine inputs.
//!
//! `layout.measure` and `painter.paintText` MUST both build their inputs
//! through this module: two different mappings would let the measured width
//! and the painted extent drift. The only decision point is `frame.engine`
//! (`engineFor`): with an engine, measure shapes one cozmic layout and paint
//! replays it; without one, text measures as zero and paints nothing (there
//! is no legacy fallback any more).
//!
//! Layout reuse: `measureCached` retains the shaped `Layout` on the node and
//! `retainedLayout` validates it against the exact inputs paint would replay,
//! so the paint phase emits from the measure layout without a second shape
//! whenever the key matches.

const std = @import("std");
const cozmic = @import("cozmic");
const core = @import("../core/root.zig");
const fonts = @import("../fonts/text_engine.zig");
const element = @import("element.zig");

/// The engine installed in a frame, or null when text has none (measure
/// collapses, paint emits nothing). `layout.measure` and `painter.paintText`
/// both read the frame through this one predicate.
pub fn engineFor(frame: *const element.Frame) ?*fonts.Engine {
    return frame.engine;
}

/// Allocator for per-call cozmic layouts. Frames carry the App allocator;
/// headless callers that never set one get the page allocator instead of a
/// crash, and the layout frees through the same allocator.
pub fn frameAllocator(frame: *const element.Frame) std.mem.Allocator {
    return frame.allocator orelse std.heap.page_allocator;
}

/// Cozmic attributes for one text node. Size/line-height/weight/tracking are
/// exact; `family` is the first CSS-list segment (generics drop to cozmic's
/// default sans family).
pub fn attrs(node: *const element.Node) fonts.TextAttrs {
    return .{
        .family = firstFamily(node.text_style.font),
        .size = node.text_style.size,
        .line_height = node.text_style.line_height orelse node.text_style.size * 1.25,
        .weight = cozmicWeight(node.text_style.weight),
        .tracking = node.text_style.tracking,
    };
}

/// Explicit wrap width in pixels, or null for unbounded. Only `style.width`
/// is used: bounds are placed after measuring and must not feed back.
pub fn wrapWidth(node: *const element.Node) ?f32 {
    return node.style.width;
}

/// One cozmic layout for `node`; caller deinits. Errors propagate so callers
/// can record a failed shape instead of painting stale ink.
pub fn shape(
    engine: *fonts.Engine,
    node: *const element.Node,
    alloc: std.mem.Allocator,
) !fonts.Layout {
    return engine.layout(alloc, node.text_value, attrs(node), wrapWidth(node));
}

/// Measure-phase shape that retains the layout on the node for paint
/// (`Element` state: `Node.cozmic_layout`). This is the one shape a node pays
/// per frame when paint can replay it; `retainedLayout` validates reuse.
///
/// On success the node owns the entry (replacing and freeing any previous
/// one). On failure the node is left as the caller found it: `layout.measure`
/// clears the previous entry before deciding the engine, so a failed shape
/// can never keep a stale layout.
pub fn measureCached(
    engine: *fonts.Engine,
    node: *element.Node,
    alloc: std.mem.Allocator,
) !core.Size {
    const cached = try engine.layoutCached(alloc, node.text_value, attrs(node), wrapWidth(node));
    node.setCozmicLayout(cached);
    return .{ .w = cached.layout.width, .h = cached.layout.height };
}

/// The node's retained layout when it is valid for the exact shape inputs
/// paint would use *and* for the engine the frame has installed. Null means
/// "reshape": no retained layout, no engine, or a key mismatch (text, attrs,
/// wrap width, engine) whose stale metrics must not be painted.
pub fn retainedLayout(frame: *const element.Frame, node: *const element.Node) ?*fonts.CachedLayout {
    const cached = node.cozmic_layout orelse return null;
    const engine = engineFor(frame) orelse return null;
    if (!cached.matches(engine, node.text_value, attrs(node), wrapWidth(node))) return null;
    return cached;
}

/// Synthetic-bold decision for one glyph, axis-aware (see
/// `fonts.Engine.needsSyntheticBold`): a variable face whose `wght` axis
/// covers the request rasterizes the requested weight itself, so it must not
/// be dilated again; static faces keep the 1px approximation. This is the one
/// mapping both the atlas key and the upload dilation use.
pub fn syntheticBold(engine: *fonts.Engine, requested: element.FontWeight, font_id: fonts.FontId) bool {
    return engine.needsSyntheticBold(font_id, cozmicWeight(requested));
}

/// Which metric produced a caret. `.unavailable` means the caret must be
/// omitted: no engine is installed, or the index cannot be placed on layout
/// line 0, and guessing would drift from the painted cozmic advances.
pub const CaretSource = enum { cozmic, unavailable };

/// Caret x plus the metric that owns it. `x` is layout-local: measured from
/// the node's own run start, before its bounds/padding; callers add the
/// content-box origin they place the node at.
pub const CaretPosition = struct {
    x: f32,
    source: CaretSource,
};

/// Visual x of the caret at byte `index` under the exact cozmic layout
/// `measure`/`paint` use.
///
/// Single-line contract: the index is matched against layout line 0 only,
/// which is exactly the widget model (`TextField` strips newlines on input).
/// A node whose caret cannot be placed on line 0 - no engine, shape failure,
/// or an index that falls on another line - reports `.unavailable` rather
/// than a guessed position. An empty layout reports x=0 as `.cozmic`.
pub fn caretX(frame: *const element.Frame, node: *const element.Node, index: usize) CaretPosition {
    const engine = engineFor(frame) orelse return .{ .x = 0, .source = .unavailable };
    var layout = shape(engine, node, frameAllocator(frame)) catch
        return .{ .x = 0, .source = .unavailable };
    defer layout.deinit();
    if (layout.glyphCount() == 0) return .{ .x = 0, .source = .cozmic };
    const clamped = @min(index, node.text_value.len);
    const position = layout.cursorPosition(.{ .line = 0, .index = clamped }) orelse
        return .{ .x = 0, .source = .unavailable };
    return .{ .x = position.x, .source = .cozmic };
}

/// ZUI weight enum → cozmic/OpenType numeric weight.
pub fn cozmicWeight(weight: element.FontWeight) u16 {
    return switch (weight) {
        .normal => 400,
        .medium => 500,
        .semibold => 600,
        .bold => 700,
    };
}

/// First family in a CSS-ish list (`"Inter, sans-serif"` → `"Inter"`).
/// Generic families and empty names return null (cozmic's default sans).
pub fn firstFamily(font_name: []const u8) ?[]const u8 {
    var rest = font_name;
    if (std.mem.indexOfScalar(u8, rest, ',')) |comma| rest = rest[0..comma];
    const name = std.mem.trim(u8, rest, " \t\r\n");
    if (name.len == 0) return null;
    const generic = [_][]const u8{
        "sans-serif",    "serif",        "monospace",     "system-ui",
        "ui-sans-serif", "ui-monospace", "-apple-system", "sans",
        "system",
    };
    for (generic) |g| {
        if (std.ascii.eqlIgnoreCase(name, g)) return null;
    }
    return name;
}

test "first family picks the first CSS segment" {
    const t = std.testing;
    try t.expectEqualStrings("Inter", firstFamily("Inter, sans-serif").?);
    try t.expectEqualStrings("Noto Sans", firstFamily(" Noto Sans , monospace ").?);
    try t.expect(firstFamily("sans-serif") == null);
    try t.expect(firstFamily("") == null);
    try t.expect(firstFamily(", serif") == null);
}

test "cozmic weight mapping covers the ZUI enum" {
    const t = std.testing;
    try t.expectEqual(@as(u16, 400), cozmicWeight(.normal));
    try t.expectEqual(@as(u16, 500), cozmicWeight(.medium));
    try t.expectEqual(@as(u16, 600), cozmicWeight(.semibold));
    try t.expectEqual(@as(u16, 700), cozmicWeight(.bold));
}

test "caretX reports its engine source and stays line-0 only" {
    const t = std.testing;
    var frame = element.Frame{};
    frame.allocator = t.allocator;
    var node = element.Node{
        .kind = .text,
        .text_value = "abc",
        .text_style = .{ .size = 16, .line_height = 20 },
    };

    // No engine: paint draws nothing, so the caret must be omitted.
    try t.expectEqual(CaretSource.unavailable, caretX(&frame, &node, 2).source);

    const engine = fonts.Engine.init(t.allocator) catch |err| switch (err) {
        error.ShaperUnavailable, error.LibraryUnavailable, error.NoFontsAvailable, error.FontCorpusIncomplete => return error.SkipZigTest,
        else => return err,
    };
    defer engine.deinit();
    frame.engine = engine;

    const caret = caretX(&frame, &node, 2);
    try t.expectEqual(CaretSource.cozmic, caret.source);
    const prefix = try engine.measure(t.allocator, "ab", attrs(&node));
    try t.expectApproxEqAbs(prefix, caret.x, 0.01);

    // Empty layout: the caret sits at the run start.
    node.text_value = "";
    const empty = caretX(&frame, &node, 0);
    try t.expectEqual(CaretSource.cozmic, empty.source);
    try t.expectEqual(@as(f32, 0), empty.x);

    // The contract is line 0: an index on a later line reports unavailable
    // instead of a guessed x.
    node.text_value = "a\nb";
    const multi = caretX(&frame, &node, 3);
    try t.expectEqual(CaretSource.unavailable, multi.source);
}

// ---------------------------------------------------------------------------
// Element-level parity: measure == paint through the real element path
// ---------------------------------------------------------------------------

const gpu = @import("../gpu/root.zig");
const layout_mod = @import("layout.zig");
const painter = @import("painter.zig");
const testing = std.testing;

/// Corpus engine, skipping only when the host lacks the runtime libraries the
/// cozmic package loads via `dlopen` (or the vendored corpus is absent).
fn parityEngine(alloc: std.mem.Allocator) !*fonts.Engine {
    return fonts.Engine.init(alloc) catch |err| switch (err) {
        error.ShaperUnavailable, error.LibraryUnavailable, error.NoFontsAvailable => return error.SkipZigTest,
        else => return err,
    };
}

/// Laid-out glyphs that produce no ink in the scene: `.notdef` placeholders
/// and whitespace. Counted from the layout itself, so wrap-dropped source
/// spaces cannot skew the expectation.
fn layoutSkippedGlyphs(reference: *const fonts.Layout) usize {
    var skipped: usize = 0;
    var runs = reference.runs();
    while (runs.next()) |run| {
        for (run.glyphs) |g| {
            if (g.glyph_id == 0) {
                skipped += 1;
                continue;
            }
            if (g.start < run.text.len) {
                switch (run.text[g.start]) {
                    ' ', '\t', '\n', '\r' => skipped += 1,
                    else => {},
                }
            }
        }
    }
    return skipped;
}

/// One element-level parity check for `text` with the given style: layout and
/// paint through the element path, compared against a fresh engine layout
/// shaped from the exact same node inputs.
fn expectElementParity(
    alloc: std.mem.Allocator,
    engine: *fonts.Engine,
    text: []const u8,
    size: f32,
    line_height: f32,
    tracking: f32,
    wrap_width: ?f32,
) !void {
    const frame = try alloc.create(element.Frame);
    defer alloc.destroy(frame);
    const scene = try alloc.create(gpu.Scene);
    defer alloc.destroy(scene);

    frame.* = .{};
    frame.reset(@ptrFromInt(1), .{});
    frame.engine = engine;
    frame.allocator = alloc;
    element.beginFrame(frame);
    defer element.endFrame();

    const box_w = wrap_width orelse 500;
    var text_el = element.text(text, .{
        .font = "Inter",
        .size = size,
        .line_height = line_height,
        .tracking = tracking,
    });
    if (wrap_width) |w| text_el = text_el.w(w);
    const root = element.div().w(box_w).h(400).child(text_el);
    layout_mod.layout(frame, root, .{ .w = 500, .h = 400 });

    const text_index = frame.nodes[root.index].first_child.?;
    const node = &frame.nodes[text_index];
    try testing.expect(node.measured.w > 0);
    try testing.expect(node.cozmic_measured);

    // Reference layout from the same engine inputs the element path uses.
    var reference = try shape(engine, node, alloc);
    defer reference.deinit();

    if (wrap_width) |w| {
        try testing.expectEqual(w, node.measured.w);
        try testing.expect(reference.width <= w + 0.01);
    } else {
        try testing.expectApproxEqAbs(reference.width, node.measured.w, 0.01);
    }
    try testing.expectApproxEqAbs(reference.height, node.measured.h, 0.01);

    scene.* = .{};
    painter.paint(frame, root, scene);

    // Painted extent tracks the reference layout; every laid-out glyph is
    // either emitted ink or a skipped zero-ink/missing glyph; the scene holds
    // exactly the inked ones: layout glyphs minus spaces and minus `.notdef`
    // glyphs.
    try testing.expectApproxEqAbs(reference.width, frame.cozmic_painted_extent, 0.01);
    const skipped = layoutSkippedGlyphs(&reference);
    const laid_out = reference.glyphCount();
    try testing.expectEqual(
        @as(u64, @intCast(laid_out)),
        frame.cozmic_painted_glyphs + frame.cozmic_skipped_glyphs,
    );
    try testing.expectEqual(
        frame.cozmic_painted_glyphs,
        @as(u64, @intCast(scene.glyphSlice().len)),
    );
    try testing.expectEqual(laid_out - skipped, scene.glyphSlice().len);
    try testing.expect(scene.glyphSlice().len > 0);
    if (wrap_width != null) {
        // Wrapped text painted across several lines.
        try testing.expect(reference.height > reference.width);
    }
}

test "element parity: measured width equals painted scene extent" {
    const alloc = testing.allocator;
    const engine = try parityEngine(alloc);
    defer engine.deinit();

    const wrapping =
        "The quick brown fox jumps over the lazy dog, then the dog jumps " ++
        "back over the fox while the quick brown fox keeps running far away.";

    const Case = struct {
        text: []const u8,
        size: f32 = 16,
        line_height: f32 = 20,
        tracking: f32 = 0,
        wrap_width: ?f32 = null,
    };
    const cases = [_]Case{
        .{ .text = "Hello world" },
        .{ .text = "Hamburgefonstiv" },
        .{ .text = "Order 66: 12,345.67 units", .tracking = 1.5 },
        .{ .text = wrapping, .wrap_width = 140 },
        .{ .text = "Hello خالصة שלום world" },
    };

    for (cases) |case| {
        try expectElementParity(
            alloc,
            engine,
            case.text,
            case.size,
            case.line_height,
            case.tracking,
            case.wrap_width,
        );
    }
}

test "element parity: missing glyphs keep element measurement consistent" {
    const alloc = testing.allocator;
    const engine = try parityEngine(alloc);
    defer engine.deinit();

    const frame = try alloc.create(element.Frame);
    defer alloc.destroy(frame);
    frame.* = .{};
    frame.reset(@ptrFromInt(1), .{});
    frame.engine = engine;
    frame.allocator = alloc;
    element.beginFrame(frame);
    defer element.endFrame();

    // U+6F22 (CJK) is covered by none of the vendored corpus faces, so it
    // shapes as `.notdef`. The element painter skips that glyph's ink; the
    // layout around it must still measure exactly like the element box.
    const text = "Hi 漢!";
    const text_el = element.text(text, .{ .font = "Inter", .size = 16, .line_height = 20 });
    const root = element.div().w(500).h(400).child(text_el);
    layout_mod.layout(frame, root, .{ .w = 500, .h = 400 });

    const text_index = frame.nodes[root.index].first_child.?;
    const node = &frame.nodes[text_index];
    try testing.expect(node.cozmic_measured);
    try testing.expect(node.measured.w > 0);

    var reference = try shape(engine, node, alloc);
    defer reference.deinit();
    try testing.expectApproxEqAbs(reference.width, node.measured.w, 0.01);
    try testing.expectApproxEqAbs(reference.height, node.measured.h, 0.01);
    try testing.expect(reference.width > 0);
    try testing.expect(reference.glyphCount() >= 4);

    var notdef: usize = 0;
    var runs = reference.runs();
    while (runs.next()) |run| {
        for (run.glyphs) |g| if (g.glyph_id == 0) {
            notdef += 1;
        };
    }
    try testing.expect(notdef > 0);

    // Layout-level rendering walks every glyph, `.notdef` included, so the
    // shaped run (and the counters built on it) stays intact even when the
    // element painter skips the missing ink.
    var counter = EngineCounter{};
    const stats = try reference.render(counter.renderer(), .{ .value = 0xFF00_0000 });
    try testing.expectEqual(reference.width, stats.x_extent);
    try testing.expectEqual(reference.glyphCount(), stats.glyphs);
}

/// Counting renderer for layout-level renders (no drawing).
const EngineCounter = struct {
    glyphs: usize = 0,

    fn renderer(self: *EngineCounter) cozmic.render.Renderer {
        return .{ .ctx = @ptrCast(self), .vtable = &vtable };
    }

    const vtable = cozmic.render.Renderer.VTable{
        .rectangle = rectangle,
        .glyph = glyph,
    };

    fn rectangle(ctx: *anyopaque, x: i32, y: i32, w: u32, h: u32, color: cozmic.Color) void {
        _ = .{ ctx, x, y, w, h, color };
    }

    fn glyph(ctx: *anyopaque, physical_glyph: cozmic.layout.PhysicalGlyph, color: cozmic.Color) void {
        _ = .{ physical_glyph, color };
        const self: *EngineCounter = @ptrCast(@alignCast(ctx));
        self.glyphs += 1;
    }
};

test "element parity: corpus engine backs deterministic element frames" {
    const t = testing;
    const alloc = t.allocator;
    const io = t.io;

    // Deterministic leg: a temp corpus with one vendored font.
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const valid_path = blk: {
        const source = fonts.readCorpusFile(alloc, io, "Inter-Regular.ttf") catch |err| switch (err) {
            error.FileNotFound => return error.SkipZigTest,
            else => return err,
        };
        defer alloc.free(source);
        try tmp.dir.createDirPath(io, "valid");
        try tmp.dir.writeFile(io, .{ .sub_path = "valid/Inter-Regular.ttf", .data = source });
        break :blk try std.fs.path.join(alloc, &.{ ".zig-cache", "tmp", &tmp.sub_path, "valid" });
    };
    defer alloc.free(valid_path);

    const corpus_engine = fonts.Engine.initWithDirs(alloc, &.{valid_path}, true) catch |err| switch (err) {
        error.LibraryUnavailable, error.ShaperUnavailable => return error.SkipZigTest,
        else => return err,
    };
    defer corpus_engine.deinit();
    try expectElementParity(alloc, corpus_engine, "Hello world", 16, 20, 0, null);
    try expectElementParity(alloc, corpus_engine, "Hamburgefonstiv", 16, 20, 1.5, null);
}

test "element parity: system engine backs element frames" {
    // Host leg: the production `initSystem` engine must drive the same
    // element parity (measure and cozmic paint both agree with the engine
    // reference). Skipped when the host has no usable system fonts.
    const alloc = testing.allocator;
    const engine = fonts.Engine.initSystem(alloc) catch |err| switch (err) {
        error.NoFontsAvailable, error.LibraryUnavailable, error.ShaperUnavailable => return error.SkipZigTest,
        else => return err,
    };
    defer engine.deinit();
    try expectElementParity(alloc, engine, "Hello world", 16, 20, 0, null);
}

test "element parity: measure->paint shapes each text node exactly once" {
    const alloc = testing.allocator;
    const engine = try parityEngine(alloc);
    defer engine.deinit();

    const frame = try alloc.create(element.Frame);
    defer alloc.destroy(frame);
    frame.* = .{};
    frame.reset(@ptrFromInt(1), .{});
    frame.engine = engine;
    frame.allocator = alloc;
    element.beginFrame(frame);
    defer element.endFrame();

    var root = element.div().w(400).h(200).flex_col();
    const labels = [_][]const u8{ "Inbox", "Settings", "Completed", "Archive", "The quick brown fox jumps over the lazy dog." };
    for (labels) |label| root = root.child(element.text(label, .{ .size = 14 }));
    layout_mod.layout(frame, root, .{ .w = 400, .h = 200 });

    // Measure shaped exactly one layout per text node and retained each one.
    const shaped_by_measure = engine.layout_calls;
    try testing.expectEqual(@as(u64, labels.len), shaped_by_measure);
    for (frame.nodes[0..frame.node_count]) |node| {
        if (node.kind != .text) continue;
        try testing.expect(node.cozmic_measured);
        try testing.expect(node.cozmic_layout != null);
    }

    const scene = try alloc.create(gpu.Scene);
    defer alloc.destroy(scene);
    scene.* = .{};
    painter.paint(frame, root, scene);

    // Paint consumed the handoffs without shaping anything again, then
    // released them (a repaint reshapes; see the scene-equality test).
    try testing.expectEqual(shaped_by_measure, engine.layout_calls);
    try testing.expect(scene.glyphSlice().len > 0);
    try testing.expectEqual(@as(u64, 0), frame.cozmic_paint_failures);
    for (frame.nodes[0..frame.node_count]) |node| try testing.expect(node.cozmic_layout == null);
}

test "element parity: retained layout and reshape paint the same scene" {
    const alloc = testing.allocator;
    const engine = try parityEngine(alloc);
    defer engine.deinit();

    const frame = try alloc.create(element.Frame);
    defer alloc.destroy(frame);
    frame.* = .{};
    frame.reset(@ptrFromInt(1), .{});
    frame.engine = engine;
    frame.allocator = alloc;
    element.beginFrame(frame);
    defer element.endFrame();

    // Mixed script (per-script fallback) + wrapping + strike (per-run quads):
    // every kind of output the emit pass produces.
    const text = "Hello خالصة world: the quick brown fox jumps over the lazy dog, then the dog jumps back.";
    const root = element.text(text, .{ .size = 16, .line_height = 20, .strike = true }).w(140);
    layout_mod.layout(frame, root, .{ .w = 500, .h = 300 });
    const node = &frame.nodes[root.index];
    try testing.expect(node.cozmic_measured);
    try testing.expect(node.cozmic_layout != null);

    const cached_scene = try alloc.create(gpu.Scene);
    defer alloc.destroy(cached_scene);
    cached_scene.* = .{};
    const shaped_by_measure = engine.layout_calls;
    painter.paint(frame, root, cached_scene);
    // First paint reused the measure layout: no second shape...
    try testing.expectEqual(shaped_by_measure, engine.layout_calls);
    try testing.expect(cached_scene.glyphSlice().len > 0);
    try testing.expect(cached_scene.slice().len > 1); // wrapped: several run rules

    // ...and released it. The same frame repainted reshapes from the same
    // inputs and must produce byte-identical glyphs and decorations.
    const reshaped_scene = try alloc.create(gpu.Scene);
    defer alloc.destroy(reshaped_scene);
    reshaped_scene.* = .{};
    painter.paint(frame, root, reshaped_scene);
    try testing.expectEqual(shaped_by_measure + 1, engine.layout_calls); // reshaped
    try testing.expectEqual(cached_scene.glyphSlice().len, reshaped_scene.glyphSlice().len);
    for (cached_scene.glyphSlice(), reshaped_scene.glyphSlice()) |a, b| try testing.expectEqualDeep(a, b);
    try testing.expectEqual(cached_scene.slice().len, reshaped_scene.slice().len);
    for (cached_scene.slice(), reshaped_scene.slice()) |a, b| try testing.expectEqualDeep(a, b);
}
