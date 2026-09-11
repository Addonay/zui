//! End-to-end integration fixture (owner review gate).
//!
//! Exercises the connected pipeline through the public API:
//!   mixed Latin/Arabic -> wrapping -> click-to-caret -> selection ->
//!   insertion -> grapheme-cluster deletion.
//!
//! Uses the vendored test fonts (tests/fonts) so results do not depend on
//! host font installation. The current shaping backend is the charmap seam;
//! when the HarfBuzz backend lands, these assertions should keep passing
//! unchanged (they only assert contract-level behavior).

const std = @import("std");

const buffer_mod = @import("buffer.zig");
const edit_mod = @import("edit.zig");
const attrs_mod = @import("attrs.zig");
const font_system_mod = @import("font_system.zig");
const cursor_mod = @import("cursor.zig");
const unicode = @import("unicode.zig");
const layout_mod = @import("layout.zig");
const font_raster_mod = @import("font_raster.zig");
const swash_mod = @import("swash_cache.zig");

const ARABIC = "\u{0645}\u{0631}\u{062D}\u{0628}\u{0627}"; // مرحبا
const MIXED = "Hello " ++ ARABIC ++ " world " ++ ARABIC;
const FONT_DIRS = [_][]const u8{ "tests/fonts/", "src/../tests/fonts/", "../tests/fonts/" };

fn readFontFile(alloc: std.mem.Allocator, name: []const u8) ![]u8 {
    var last_err: anyerror = error.FileNotFound;
    for (FONT_DIRS) |dir| {
        const path = try std.fs.path.join(alloc, &.{ dir, name });
        defer alloc.free(path);
        if (std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, alloc, .limited(1 << 24))) |bytes| {
            return bytes;
        } else |e| {
            last_err = e;
        }
    }
    return last_err;
}

fn addFont(
    fsys: *font_system_mod.FontSystem,
    alloc: std.mem.Allocator,
    file: []const u8,
    family: []const u8,
    mono: bool,
) !void {
    // The backend copies the bytes; free ours after `addFontData`.
    const bytes = try readFontFile(alloc, file);
    defer alloc.free(bytes);
    const id = try fsys.dbMut().addFace(
        file,
        0,
        &.{family},
        family,
        font_system_mod.WEIGHT_NORMAL,
        .normal,
        .normal,
        mono,
    );
    try fsys.addFontData(id, bytes, 0, false, null);
}

fn testFontSystem(alloc: std.mem.Allocator) !font_system_mod.FontSystem {
    var fsys = try font_system_mod.FontSystem.init(alloc);
    errdefer fsys.deinit();
    try addFont(&fsys, alloc, "Inter-Regular.ttf", "Inter", false);
    try addFont(&fsys, alloc, "NotoSansArabic.ttf", "Noto Sans Arabic", false);
    return fsys;
}

test "e2e: mixed Latin/Arabic wraps and produces RTL glyph levels" {
    const alloc = std.testing.allocator;
    var fsys = try testFontSystem(alloc);
    defer fsys.deinit();

    var attrs = attrs_mod.Attrs.init(alloc);
    defer attrs.deinit();

    var buf = try buffer_mod.Buffer.initWithAllocator(alloc, attrs_mod.Metrics.new(16, 20));
    defer buf.deinit();
    buf.setWrap(.word);
    buf.setSize(80, 400);
    try buf.setText(MIXED, &attrs, .advanced, null);
    try buf.shapeUntilScroll(&fsys, false);

    // 1. Wrapping: the text is wider than 80px and must produce several runs.
    var it = buf.layoutRuns();
    var runs: usize = 0;
    var rtl_glyphs: usize = 0;
    var ltr_glyphs: usize = 0;
    var first_glyph: ?struct { x: f32, w: f32, y: f32 } = null;
    while (it.next()) |run| {
        runs += 1;
        for (run.glyphs) |g| {
            if (g.level % 2 == 1) {
                rtl_glyphs += 1;
            } else {
                ltr_glyphs += 1;
            }
        }
        if (first_glyph == null and run.glyphs.len > 0) {
            first_glyph = .{ .x = run.glyphs[0].x, .w = run.glyphs[0].w, .y = run.line_y };
        }
    }
    try std.testing.expect(runs > 1);
    try std.testing.expect(ltr_glyphs > 0);
    try std.testing.expect(rtl_glyphs > 0);

    // 2. Click-to-caret: clicking inside the first glyph maps back to a cursor
    // whose caret position is inside (or at the edge of) that glyph, and the
    // byte index sits on a grapheme boundary.
    const g = first_glyph.?;
    const click_x = g.x + g.w * 0.4;
    const clicked = buf.hit(click_x, g.y);
    try std.testing.expect(clicked != null);
    const c = clicked.?;
    const pos = buf.cursorPosition(&c);
    try std.testing.expect(pos != null);
    try std.testing.expect(pos.?.x >= g.x - 1.0 and pos.?.x <= g.x + g.w + 1.0);
    try std.testing.expect(unicode.isGraphemeBoundary(buf.lines.items[0].textSlice(), c.index));
}

test "e2e: selection, insertion, and grapheme deletion through the Editor" {
    const alloc = std.testing.allocator;
    var fsys = try testFontSystem(alloc);
    defer fsys.deinit();

    var attrs = attrs_mod.Attrs.init(alloc);
    defer attrs.deinit();

    var buf = try buffer_mod.Buffer.initWithAllocator(alloc, attrs_mod.Metrics.new(16, 20));
    defer buf.deinit();
    try buf.setText("hello world", &attrs, .advanced, null);
    try buf.shapeUntilScroll(&fsys, false);

    var ed = edit_mod.Editor.initWithBuffer(alloc, &buf);
    defer ed.deinit();

    // 3. Selection: cover "hello" and verify the ordered bounds.
    ed.setCursor(cursor_mod.Cursor.new(0, 0));
    ed.setSelection(.{ .normal = cursor_mod.Cursor.new(0, 5) });
    const bounds = ed.selectionBounds();
    try std.testing.expect(bounds != null);
    try std.testing.expectEqual(@as(usize, 0), bounds.?.start.index);
    try std.testing.expectEqual(@as(usize, 5), bounds.?.end.index);

    // 4. Insertion over the selection replaces "hello" with "HI".
    try ed.insertString("HI", null);
    var t = try ed.fullText();
    defer t.deinit(alloc);
    try std.testing.expectEqualStrings("HI world", t.items);

    // 5. Grapheme deletion: reset to "e" + U+0301 + "cole"; Delete at home
    // removes the whole cluster (both codepoints), leaving "cole".
    try buf.setText("e\u{0301}cole", &attrs, .advanced, null);
    try buf.shapeUntilScroll(&fsys, false);
    ed.setSelection(.{ .none = {} });
    try ed.action(&fsys, .{ .motion = .home });
    try ed.action(&fsys, .delete);
    var t2 = try ed.fullText();
    defer t2.deinit(alloc);
    try std.testing.expectEqualStrings("cole", t2.items);

    // 6. Selection + insertion still works after shaping was invalidated.
    ed.setCursor(cursor_mod.Cursor.new(0, 0));
    ed.setSelection(.{ .normal = cursor_mod.Cursor.new(0, 4) });
    try ed.insertString("done", null);
    var t3 = try ed.fullText();
    defer t3.deinit(alloc);
    try std.testing.expectEqualStrings("done", t3.items);
}

test "e2e: HarfBuzz backend produces real per-font advances" {
    const alloc = std.testing.allocator;

    // Inter and FiraMono have different advances/upems. Under the charmap
    // stand-in both would measure identically (0.6em per glyph); with the
    // real backend the laid-out widths must differ.
    const Case = struct { file: []const u8, family: []const u8, mono: bool };
    const cases = [_]Case{
        .{ .file = "Inter-Regular.ttf", .family = "Inter", .mono = false },
        .{ .file = "FiraMono-Medium.ttf", .family = "FiraMono", .mono = true },
    };

    var widths: [2]f32 = undefined;
    for (cases, 0..) |case, i| {
        var fsys = try font_system_mod.FontSystem.init(alloc);
        defer fsys.deinit();
        try addFont(&fsys, alloc, case.file, case.family, case.mono);
        try std.testing.expect(fsys.hasShaper());

        var attrs = attrs_mod.Attrs.init(alloc);
        defer attrs.deinit();
        var buf = try buffer_mod.Buffer.initWithAllocator(alloc, attrs_mod.Metrics.new(16, 20));
        defer buf.deinit();
        buf.setWrap(.none);
        buf.setSize(10_000, 400);
        try buf.setText("Hamburgefonstiv", &attrs, .advanced, null);
        try buf.shapeUntilScroll(&fsys, false);

        var width: f32 = 0;
        var it = buf.layoutRuns();
        while (it.next()) |run| width = @max(width, run.line_w);
        try std.testing.expect(width > 0);
        widths[i] = width;
    }
    try std.testing.expect(widths[0] != widths[1]);
}

test "e2e: FreeType raster produces coverage for shaped glyphs" {
    const alloc = std.testing.allocator;
    var fsys = try testFontSystem(alloc);
    defer fsys.deinit();

    // Bridge the shaped fonts into the raster registry and attach it.
    var raster = try font_raster_mod.Raster.init(alloc);
    defer raster.deinit();
    try raster.addFromFontSystem(&fsys, fsys.fontIds());

    var cache = swash_mod.SwashCache.init(alloc, null);
    defer cache.deinit();
    cache.setRaster(&raster);

    var attrs = attrs_mod.Attrs.init(alloc);
    defer attrs.deinit();
    var buf = try buffer_mod.Buffer.initWithAllocator(alloc, attrs_mod.Metrics.new(32, 40));
    defer buf.deinit();
    try buf.setText("A", &attrs, .advanced, null);
    try buf.shapeUntilScroll(&fsys, false);

    const Vis = struct {
        count: usize = 0,
        fn visit(ctx: *anyopaque, x: i32, y: i32, color: u32) void {
            _ = x;
            _ = y;
            _ = color;
            const v: *@This() = @ptrCast(@alignCast(ctx));
            v.count += 1;
        }
    };
    var vis: Vis = .{};
    var painted: usize = 0;
    var it = buf.layoutRuns();
    while (it.next()) |run| {
        for (run.glyphs) |g| {
            if (g.w <= 0 or g.glyph_id == 0) continue;
            const pg = g.physical(0, 0, 1);
            painted += try cache.withPixels(
                pg.cache_key,
                swash_mod.rgba(255, 255, 255, 255),
                &vis,
                Vis.visit,
            );
        }
    }
    // Real FreeType coverage must emit pixels for the shaped 'A'.
    try std.testing.expect(painted > 0);
    try std.testing.expect(vis.count == painted);
}

test "e2e: ellipsize reaches the real layout with U+2026" {
    const alloc = std.testing.allocator;
    var fsys = try testFontSystem(alloc);
    defer fsys.deinit();

    var attrs = attrs_mod.Attrs.init(alloc);
    defer attrs.deinit();

    var buf = try buffer_mod.Buffer.initWithAllocator(alloc, attrs_mod.Metrics.new(16, 20));
    defer buf.deinit();
    buf.setWrap(.word);
    buf.setSize(120, 24);
    buf.setEllipsize(.{ .end = .{ .lines = 1 } });
    try buf.setText("a fairly long line that will not fit on one row at all", &attrs, .advanced, null);
    try buf.shapeUntilScroll(&fsys, false);

    var saw_ellipsis = false;
    var it = buf.layoutRuns();
    while (it.next()) |run| {
        for (run.glyphs) |gl| {
            // The ellipsis glyph is emitted with a zero-length source cluster.
            if (gl.start == gl.end and gl.w > 0) saw_ellipsis = true;
        }
    }
    try std.testing.expect(saw_ellipsis);
}

test "fixture compiles against canonical layout types" {
    // Compile-time contract check: these names must resolve to one owner and
    // stay mutually assignable (guard against re-duplication).
    const a: layout_mod.LayoutGlyph = .{
        .start = 0,
        .end = 1,
        .font_size = 16,
        .font_weight = attrs_mod.Weight.normal,
        .line_height_opt = null,
        .font_id = 0,
        .glyph_id = 0,
        .x = 0,
        .y = 0,
        .w = 0,
        .level = 0,
        .x_offset = 0,
        .y_offset = 0,
        .color_opt = null,
        .metadata = 0,
        .cache_key_flags = .{},
    };
    const b: buffer_mod.LayoutRun = .{
        .line_i = 0,
        .text = "",
        .rtl = false,
        .glyphs = &.{a},
        .decorations = &.{},
        .line_y = 0,
        .line_top = 0,
        .line_height = 0,
        .line_w = 0,
    };
    try std.testing.expect(b.glyphs.len == 1);
}
