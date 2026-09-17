//! Cozmic text engine: one cozmic layout drives measurement, painting,
//! caret hit-testing and per-script fallback.
//!
//! `Engine` owns a `cozmic.FontSystem` (shaping + font matching), a FreeType
//! `cozmic.Raster`, a `cozmic.SwashCache` wired to that raster, and the
//! glyph `Atlas` that caches rasterized coverage for the element painter.
//! `layout` shapes one `cozmic.Buffer`; `Layout` then exposes the shaped
//! runs, the measured extent, caret mapping and rendering, so no consumer
//! can disagree by building a second layout.
//!
//! Rasterization is cozmic's: the painter maps each `PhysicalGlyph` to
//! `Engine.cache.getImage(physical_glyph.cache_key)` and stores the returned
//! mask in `Engine.glyphs`. Atlas keys mirror the full cozmic raster key
//! (face, glyph, pixel size, subpixel bins, weight, flags) plus ZUI's
//! synthetic-dilation variant, because every one of those inputs changes the
//! rasterized image; `face_id` is the cozmic `FontId`, the face the glyph id
//! is meaningful in.
//!
//! Fonts: `init` prefers the deterministic vendored corpus shipped by the
//! cozmic package (`tests/fonts`, tried relative to the process cwd) and only
//! falls back to host system fonts when no candidate directory exists. A
//! candidate that exists but registers no face (empty, unreadable or
//! non-font files) fails with `error.FontCorpusIncomplete` instead of
//! degrading to host fonts, which would make tests host-dependent.
//! `initSystem` always uses host fonts (real use). Library-less hosts surface
//! `error.LibraryUnavailable` / `error.ShaperUnavailable` explicitly; tests
//! skip those, they are never silently degraded.
//!
//! Sizes: `TextAttrs.size` is quantized to the integer pixel size cozmic
//! rasterizes and the atlas keys entries with (`sizeToPx`: round, clamp to
//! 1..256) before shaping, measure and paint. Fractional sizes therefore
//! share one shaped size with the painter instead of shaping at one size and
//! rasterizing at another; `tracking` stays pixels per glyph at the
//! quantized size.
//!
//! Lifetimes: `Engine` is heap-allocated so its address is stable — the
//! `SwashCache` borrows `*Engine.raster` and every `Layout` borrows
//! `*Engine.fs`, so an `Engine` must outlive all `Layout`s made from it.
//! `CachedLayout` (the measure→paint handoff) borrows the engine exactly like
//! `Layout`; the element layer frees it at the frame boundary, before the
//! engine is deinited.

const std = @import("std");
const cozmic = @import("cozmic");
const build_options = @import("build_options");
const atlas = @import("atlas.zig");

/// Atlas type the engine owns; re-exported so the element painter can type
/// its renderer without importing the fonts package directly.
pub const Atlas = atlas.Atlas;
pub const AtlasEntry = atlas.AtlasEntry;
pub const AtlasKey = atlas.AtlasKey;
pub const BitmapContent = atlas.BitmapContent;

/// Font identifier used by cozmic layouts (canonical owner:
/// `cozmic.layout.FontId`; the dependency's root does not re-export it).
pub const FontId = cozmic.layout.FontId;
/// Caret position within a laid-out buffer (canonical owner:
/// `cozmic.buffer.CursorPosition`; the dependency's root does not re-export
/// it).
pub const CursorPosition = cozmic.buffer.CursorPosition;

/// Vendored test corpus shipped inside the fetched cozmic package. The build
/// resolves one file path in it and the directory is derived from that, so
/// there is no local checkout or fallback path to keep in sync.
pub const corpus_dirs = [_][]const u8{
    std.fs.path.dirname(build_options.cozmic_corpus_font) orelse ".",
};

/// Read `name` from the corpus. Caller owns the returned bytes;
/// `error.FileNotFound` when the package fixture is missing.
pub fn readCorpusFile(allocator: std.mem.Allocator, io: std.Io, name: []const u8) ![]u8 {
    var last_err: anyerror = error.FileNotFound;
    for (corpus_dirs) |dir| {
        const path = try std.fs.path.join(allocator, &.{ dir, name });
        defer allocator.free(path);
        if (std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(16 << 20))) |bytes| {
            return bytes;
        } else |err| {
            last_err = err;
        }
    }
    return last_err;
}

/// UI pixel size → integer pixel size used for shaping and atlas keys.
/// Pure and shared by measure and paint so both sides size identically
/// (atlas keys match). Rounds, clamps to 1..256; NaN and non-positive sizes
/// clamp to 1 instead of trapping.
pub fn sizeToPx(size: f32) u16 {
    const rounded = @round(size);
    if (!(rounded > 1)) return 1; // NaN or <= 1
    if (rounded >= 256) return 256;
    return @intFromFloat(rounded);
}

/// Attributes for one `Engine.layout` call. `family == null` selects the
/// generic sans-serif family (cozmic's configured default), and cozmic still
/// applies per-script fallback when the selected face lacks a codepoint.
pub const TextAttrs = struct {
    /// Named font family (e.g. "Inter", "Noto Sans Arabic"), or `null` for
    /// the generic sans-serif family.
    family: ?[]const u8 = null,
    /// Font size in pixels. Quantized before shaping to the integer pixel
    /// size cozmic rasterizes and keys the atlas with (`sizeToPx`: round,
    /// clamp to 1..256), so shaped advances and rasterized ink always use the
    /// same size.
    size: f32 = 16,
    /// Line height in pixels.
    line_height: f32 = 20,
    /// Font weight, 100..900 (400 is normal).
    weight: u16 = 400,
    /// Extra advance per glyph, in pixels (ZUI `TextStyle.tracking`). Cozmic
    /// expresses letter spacing in EM units and applies it at the quantized
    /// font size, so `Engine.layout` converts with that same size.
    tracking: f32 = 0,
    /// Wrapping mode used by the layout.
    wrap: cozmic.Wrap = .word_or_glyph,
};

/// What one `Layout.render` delivered to the caller's renderer.
pub const PaintStats = struct {
    /// Maximum painted extent, `max(glyph.x + glyph.w)` over every run.
    x_extent: f32,
    /// Glyph callbacks delivered (one per laid-out glyph).
    glyphs: usize,
    /// Rectangle callbacks delivered through the renderer vtable (text
    /// decorations).
    rects: usize,
};

/// Owns the shaping, rasterization and glyph-cache state for text.
///
/// Heap-allocated by `init`/`initSystem` (stable address: `Layout`, the
/// glyph cache and the atlas borrow into it). One engine is expected to be
/// shared by all layouts of a process/window; `Layout` operations are
/// read-only.
pub const Engine = struct {
    allocator: std.mem.Allocator,
    /// Shaping, matching and fallback.
    fs: cozmic.FontSystem,
    /// FreeType face registry used by the cache.
    raster: cozmic.Raster,
    /// Glyph image cache, wired to `raster`.
    cache: cozmic.SwashCache,
    /// Rasterized mask cache the painter emits from. Keys use cozmic
    /// `FontId` as `face_id`; `beginFrame` is called once per window paint.
    glyphs: Atlas = .{},
    /// `layout` calls since creation. Observability only (tests and
    /// bench-text prove that a node is shaped once per frame); shaping reads
    /// nothing from it.
    layout_calls: u64 = 0,

    /// Load the vendored deterministic corpus; fall back to host system fonts
    /// only when no corpus candidate directory exists. A candidate directory
    /// that exists but registers no face (empty, non-font files, parse
    /// errors) fails loudly (`FontCorpusIncomplete`) instead of degrading to
    /// system fonts, which would make tests host-dependent.
    pub fn init(allocator: std.mem.Allocator) !*Engine {
        return create(allocator, false, &corpus_dirs, true);
    }

    /// Load host system fonts only (real use). Fails with
    /// `error.NoFontsAvailable` when the host exposes none.
    pub fn initSystem(allocator: std.mem.Allocator) !*Engine {
        return create(allocator, true, &.{}, false);
    }

    /// Like `init`, but scans `dirs` instead of `corpus_dirs`. When
    /// `fallback_to_system` is false an absent directory list fails with
    /// `error.FontCorpusIncomplete` instead of touching host fonts; a
    /// present-but-broken directory always fails regardless of the flag.
    /// Exposed for tests and tools that must point the engine at a specific
    /// corpus.
    pub fn initWithDirs(
        allocator: std.mem.Allocator,
        dirs: []const []const u8,
        fallback_to_system: bool,
    ) !*Engine {
        return create(allocator, false, dirs, fallback_to_system);
    }

    fn create(
        allocator: std.mem.Allocator,
        system_only: bool,
        candidates: []const []const u8,
        fallback_to_system: bool,
    ) !*Engine {
        const self = try allocator.create(Engine);
        errdefer allocator.destroy(self);
        self.* = undefined;
        self.allocator = allocator;
        self.layout_calls = 0;
        self.glyphs = .{};

        self.fs = try cozmic.FontSystem.init(allocator);
        errdefer self.fs.deinit();

        // cozmic takes the process-wide single-threaded `Io` for sync font
        // discovery; the dependency uses the same instance for lazy reads.
        const io = std.Io.Threaded.global_single_threaded.io();
        var corpus_loaded = false;
        if (!system_only) {
            var found_dir = false;
            for (candidates) |dir| {
                const stats = self.fs.loadFontsDir(io, dir);
                if (stats.dirs_scanned != 0) found_dir = true;
                // A candidate that registered no face (absent, empty or
                // entirely unparseable) is not a usable corpus; remember that
                // and let a later candidate try, but never treat it as
                // missing and silently fall back to host fonts.
                if (stats.faces_added == 0) continue;
                if (!self.fs.hasShaper()) return error.ShaperUnavailable;
                if (stats.file_errors != 0) return error.FontCorpusIncomplete;
                corpus_loaded = true;
                break;
            }
            if (!corpus_loaded and (found_dir or !fallback_to_system)) {
                return error.FontCorpusIncomplete;
            }
        }
        if (!corpus_loaded) {
            _ = self.fs.loadSystemFonts(io);
            if (self.fs.fontIds().len == 0) return error.NoFontsAvailable;
        }

        self.raster = try cozmic.Raster.init(allocator);
        errdefer self.raster.deinit();
        try self.raster.addFromFontSystem(&self.fs, self.fs.fontIds());

        self.cache = cozmic.SwashCache.init(allocator, null);
        errdefer self.cache.deinit();
        self.cache.setRaster(&self.raster);

        return self;
    }

    pub fn deinit(self: *Engine) void {
        const allocator = self.allocator;
        self.glyphs.clear();
        self.cache.deinit();
        self.raster.deinit();
        self.fs.deinit();
        allocator.destroy(self);
    }

    /// Shape `text` into one layout. `width_opt == null` is unbounded;
    /// otherwise wrapping follows `attrs.wrap` at that pixel width. The
    /// returned `Layout` borrows this engine (which must outlive it).
    pub fn layout(
        self: *Engine,
        allocator: std.mem.Allocator,
        text: []const u8,
        attrs: TextAttrs,
        width_opt: ?f32,
    ) !Layout {
        self.layout_calls += 1;
        if (!(attrs.size > 0) or !(attrs.line_height > 0)) return error.InvalidMetrics;

        // Shape at the exact integer pixel size the painter rasterizes and
        // keys atlas entries with (`sizeToPx`: round, clamp to 1..256).
        // Otherwise fractional sizes advance at (say) 14.6px while rasterized
        // ink is hinted at 15px, and the atlas dedupes only on size_px.
        const size = quantizedSize(attrs.size);

        var buffer = try cozmic.Buffer.initWithAllocator(
            allocator,
            cozmic.Metrics.new(size, attrs.line_height),
        );
        errdefer buffer.deinit();

        buffer.setWrap(attrs.wrap);
        buffer.setSize(width_opt, null);

        var cozmic_attrs = cozmic.Attrs.init(allocator);
        defer cozmic_attrs.deinit();
        if (attrs.family) |family| cozmic_attrs.family = .{ .name = family };
        cozmic_attrs.weight = .{ .value = attrs.weight };
        // ZUI tracking is pixels per glyph; cozmic letter spacing is EM and
        // is applied at the quantized font size, so dividing by that same
        // size keeps the px-per-glyph mapping exact.
        if (attrs.tracking != 0) {
            _ = cozmic_attrs.with_letter_spacing(attrs.tracking / size);
        }

        try buffer.setText(text, &cozmic_attrs, .advanced, null);
        // Single shaping pass; `Layout` and all its readers (render, hit,
        // cursorPosition) use this buffer and never reshape.
        try buffer.shapeUntilScroll(&self.fs, false);

        var width: f32 = 0;
        var height: f32 = 0;
        var glyph_count: usize = 0;
        var runs = buffer.layoutRuns();
        while (runs.next()) |run| {
            width = @max(width, runExtent(run));
            height += run.line_height;
            glyph_count += run.glyphs.len;
        }

        return .{
            .allocator = allocator,
            .font_system = &self.fs,
            .buffer = buffer,
            .width = width,
            .height = height,
            .glyph_count = glyph_count,
        };
    }

    /// Unbounded width of `text`, from a freshly shaped layout. Exactly the
    /// `x_extent` that `paint` reports for the same text and attrs.
    pub fn measure(
        self: *Engine,
        allocator: std.mem.Allocator,
        text: []const u8,
        attrs: TextAttrs,
    ) !f32 {
        var l = try self.layout(allocator, text, attrs, null);
        defer l.deinit();
        return l.width;
    }

    /// Shape `text` and retain the result in one heap `CachedLayout` so a
    /// later paint can skip the second shape. The entry owns the shaped
    /// buffer and must be released with `CachedLayout.deinit` through the
    /// same `allocator` (the entry stores it, so freeing is independent of
    /// any later frame state).
    ///
    /// Inputs are recorded in the entry's key; consumers must call
    /// `CachedLayout.matches` before reuse or they may paint stale metrics.
    pub fn layoutCached(
        self: *Engine,
        allocator: std.mem.Allocator,
        text: []const u8,
        attrs: TextAttrs,
        width_opt: ?f32,
    ) !*CachedLayout {
        const cached = try allocator.create(CachedLayout);
        errdefer allocator.destroy(cached);
        cached.* = .{
            .layout = try self.layout(allocator, text, attrs, width_opt),
            .key = .{ .engine = self, .text = text, .attrs = attrs, .wrap_width = width_opt },
        };
        return cached;
    }

    /// Shape once and render through `renderer`. Only the returned stats are
    /// owned; the renderer sees cozmic's normal glyph/rectangle callbacks.
    pub fn paint(
        self: *Engine,
        allocator: std.mem.Allocator,
        text: []const u8,
        attrs: TextAttrs,
        width_opt: ?f32,
        renderer: cozmic.render.Renderer,
    ) !PaintStats {
        var l = try self.layout(allocator, text, attrs, width_opt);
        defer l.deinit();
        return l.render(renderer, opaqueBlack);
    }

    /// True when `font_id`'s ink at `wanted` still needs the 1px synthetic
    /// dilation: the request is bold-ish (>= 600), the matched face is
    /// lighter than requested, and the face cannot rasterize the requested
    /// weight itself. A variable face whose `wght` axis covers `wanted`
    /// forwards the requested weight to the rasterizer (`font_weight` is part
    /// of `CacheKey` and reaches `FT_Set_Var_Design_Coordinates`), so
    /// dilating on top would double-apply bold. Static faces that only match
    /// a lighter weight keep the synthetic approximation. Unknown ids return
    /// true (the glyph is skipped later anyway).
    pub fn needsSyntheticBold(self: *const Engine, font_id: FontId, wanted: u16) bool {
        if (wanted < 600) return false;
        const info = self.fs.db.face(font_id) orelse return true;
        if (info.weight >= wanted) return false;
        if (cozmic.font_system.variableWeightMatch(wanted, info.weight, info.variable_wght_min, info.variable_wght_max)) return false;
        return true;
    }
};

/// A shaped buffer plus its measured geometry. Borrows the `Engine` that
/// produced it.
pub const Layout = struct {
    /// Allocator backing `buffer` (and returned `distinctFonts` slices use
    /// the caller's allocator, not this one).
    allocator: std.mem.Allocator,
    /// Borrowed shaping/fallback system; must outlive this layout.
    font_system: *cozmic.FontSystem,
    buffer: cozmic.Buffer,
    /// `max(glyph.x + glyph.w)` over every run: the painted width.
    width: f32,
    /// Sum of all run line heights: the total painted height.
    height: f32,
    glyph_count: usize,

    pub fn deinit(self: *Layout) void {
        self.buffer.deinit();
        self.* = undefined;
    }

    /// Visible runs from the one shaping pass. Valid until `deinit`.
    pub fn runs(self: *const Layout) cozmic.buffer.LayoutRunIter {
        return self.buffer.layoutRuns();
    }

    /// Map pixel `(x, y)` to a cursor byte index (grapheme-safe). Never
    /// fails today; the error union leaves room for on-demand shaping.
    pub fn hit(self: *const Layout, x: f32, y: f32) cozmic.buffer.Error!?cozmic.Cursor {
        return self.buffer.hit(x, y);
    }

    /// Visual position of `cursor`, or `null` when it is not on a run.
    pub fn cursorPosition(self: *const Layout, cursor: cozmic.Cursor) ?CursorPosition {
        return self.buffer.cursorPosition(&cursor);
    }

    /// Nearest distinct visual grapheme caret on the same visual line.
    /// Strong caret only: split-caret affinity at bidi boundaries is deferred.
    pub fn visualMove(self: *const Layout, cursor: cozmic.Cursor, right: bool) ?cozmic.Cursor {
        const origin = self.cursorPosition(cursor) orelse return null;
        var best: ?cozmic.Cursor = null;
        var distance: f32 = std.math.inf(f32);
        if (cursor.line >= self.buffer.lines.items.len) return null;
        const text = self.buffer.lines.items[cursor.line].textSlice();
        var it = cozmic.unicode.graphemeIndices(text);
        var index: usize = 0;
        while (true) {
            const candidate = cozmic.Cursor{ .line = cursor.line, .index = index };
            if (self.cursorPosition(candidate)) |p| {
                const delta = if (right) p.x - origin.x else origin.x - p.x;
                if (@abs(p.y - origin.y) < 0.01 and delta > 0.01 and delta < distance) {
                    distance = delta;
                    best = candidate;
                }
            }
            _ = it.next() orelse break;
            index = it.pos;
        }
        return best;
    }

    /// Selection rectangles in layout-local coordinates, across wrapped runs
    /// and bidi spans. Caller owns the returned slice. Cursors use paragraph-
    /// local UTF-8 bytes (wrapped visual lines keep the same paragraph index).
    pub fn selectionRects(self: *const Layout, alloc: std.mem.Allocator, a: cozmic.Cursor, b: cozmic.Cursor) ![]@import("../core/geometry.zig").Rect {
        const Rect = @import("../core/geometry.zig").Rect;
        var out: std.ArrayList(Rect) = .empty;
        errdefer out.deinit(alloc);
        const reverse = a.line > b.line or (a.line == b.line and a.index > b.index);
        const start = if (reverse) b else a;
        const end = if (reverse) a else b;
        if (start.line == end.line and start.index == end.index) return out.toOwnedSlice(alloc);
        var it = self.runs();
        while (it.next()) |run| {
            if (run.line_i < start.line or run.line_i > end.line) continue;
            // Glyph ranges come directly from shaping. Interpolate only at
            // grapheme boundaries inside ligatures, respecting glyph direction.
            for (run.glyphs) |g| {
                const lo = if (run.line_i == start.line) @max(start.index, g.start) else g.start;
                const hi = if (run.line_i == end.line) @min(end.index, g.end) else g.end;
                if (lo >= hi or g.end <= g.start) continue;
                const cluster = run.text[g.start..g.end];
                const count: f32 = @floatFromInt(@max(1, cozmic.unicode.countGraphemes(cluster)));
                const left: f32 = @floatFromInt(cozmic.unicode.countGraphemes(run.text[g.start..lo]));
                const selected: f32 = @floatFromInt(cozmic.unicode.countGraphemes(run.text[lo..hi]));
                const width = g.w * selected / count;
                const x = if (g.level & 1 == 1) g.x + g.w - g.w * left / count - width else g.x + g.w * left / count;
                if (width > 0) try out.append(alloc, .{ .x = x, .y = run.line_top, .w = width, .h = run.line_height });
            }
        }
        return out.toOwnedSlice(alloc);
    }

    /// Number of laid-out glyphs in the whole layout.
    pub fn glyphCount(self: *const Layout) usize {
        return self.glyph_count;
    }

    /// Distinct `font_id`s used by the laid-out glyphs, ascending. Caller
    /// owns and frees the slice with `alloc`.
    pub fn distinctFonts(self: *const Layout, alloc: std.mem.Allocator) ![]FontId {
        var seen = std.AutoHashMap(FontId, void).init(alloc);
        defer seen.deinit();
        var runs_it = self.runs();
        while (runs_it.next()) |run| {
            for (run.glyphs) |glyph| try seen.put(glyph.font_id, {});
        }
        const ids = try alloc.alloc(FontId, seen.count());
        errdefer alloc.free(ids);
        var i: usize = 0;
        var keys = seen.keyIterator();
        while (keys.next()) |key| : (i += 1) ids[i] = key.*;
        std.mem.sort(FontId, ids, {}, std.sort.asc(FontId));
        return ids;
    }

    /// Render this exact layout through `renderer` and report the callbacks
    /// and the painted extent. `rects` counts rectangle callbacks that reach
    /// the wrapped renderer (text decorations).
    pub fn render(
        self: *Layout,
        renderer: cozmic.render.Renderer,
        color: cozmic.Color,
    ) cozmic.buffer.Error!PaintStats {
        var counter: CountingRenderer = .{ .inner = renderer };
        try self.buffer.render(self.font_system, counter.renderer(), color);

        var x_extent: f32 = 0;
        var runs_it = self.runs();
        while (runs_it.next()) |run| x_extent = @max(x_extent, runExtent(run));
        return .{
            .x_extent = x_extent,
            .glyphs = counter.glyphs,
            .rects = counter.rects,
        };
    }
};

/// Exact shape inputs a retained layout was built from. `CachedLayout.matches`
/// compares this against the current node inputs; any difference — including
/// the engine identity — invalidates the handoff and forces a reshape.
pub const LayoutKey = struct {
    engine: *Engine,
    text: []const u8,
    attrs: TextAttrs,
    /// Wrap width passed to `Engine.layout` (`null` = unbounded).
    wrap_width: ?f32,
};

/// A measure-phase `Layout` retained for the paint phase, plus the inputs it
/// was shaped from. Frame code stores it on the text node and frees it at the
/// next frame boundary or after paint (see `element.Node.cozmic_layout`).
///
/// Ownership: `Engine.layoutCached` heap-allocates the entry on the caller's
/// allocator and records that same allocator in `layout.allocator`; `deinit`
/// releases the shaped buffer and then the entry through it, so the entry can
/// be freed correctly even if the frame's allocator field changes in between.
/// Like a fresh `Layout`, the buffer borrows `Engine.fs`, so the engine must
/// outlive the entry.
///
/// `key.text` and `key.attrs.family` are borrowed slices; the key is only
/// meaningful while the frame/node that supplied them is alive, and `matches`
/// compares them by content so an in-place change is detected too.
pub const CachedLayout = struct {
    layout: Layout,
    key: LayoutKey,

    /// Free the shaped buffer and this entry. Safe on any entry produced by
    /// `Engine.layoutCached`; do not call twice (the node/frame setters clear
    /// the pointer).
    pub fn deinit(self: *CachedLayout) void {
        const allocator = self.layout.allocator;
        self.layout.deinit();
        allocator.destroy(self);
    }

    /// True when the retained layout was shaped from exactly these inputs.
    /// Callers must not reuse a non-matching layout: painting it would place
    /// stale metrics in a box that was measured for other inputs.
    pub fn matches(
        self: *const CachedLayout,
        engine: *Engine,
        text: []const u8,
        attrs: TextAttrs,
        wrap_width: ?f32,
    ) bool {
        return self.key.engine == engine and
            std.mem.eql(u8, self.key.text, text) and
            attrsEqual(self.key.attrs, attrs) and
            optionalF32Equal(self.key.wrap_width, wrap_width);
    }
};

/// Field-wise `TextAttrs` equality: slices compare by content (the recorded
/// family slice may alias node storage), and bit-exact float comparison is
/// the right invalidation bar (measure and paint read the same fields).
fn attrsEqual(a: TextAttrs, b: TextAttrs) bool {
    if (a.size != b.size or a.line_height != b.line_height) return false;
    if (a.weight != b.weight or a.tracking != b.tracking or a.wrap != b.wrap) return false;
    return optionalStrEqual(a.family, b.family);
}

fn optionalStrEqual(a: ?[]const u8, b: ?[]const u8) bool {
    if (a == null or b == null) return a == null and b == null;
    return std.mem.eql(u8, a.?, b.?);
}

fn optionalF32Equal(a: ?f32, b: ?f32) bool {
    if (a == null or b == null) return a == null and b == null;
    return a.? == b.?;
}

const opaqueBlack = cozmic.Color{ .value = 0xFF00_0000 };

/// ZUI pixel size a given `TextAttrs.size` is shaped and rasterized at.
/// Mirrors `sizeToPx` and returns it as f32 for cozmic metrics. Callers must
/// reject non-positive/NaN sizes first.
fn quantizedSize(size: f32) f32 {
    return @floatFromInt(sizeToPx(size));
}

/// Painted extent of one run. Shared by layout construction and rendering so
/// `Layout.width` and `PaintStats.x_extent` are bit-identical.
fn runExtent(run: cozmic.buffer.LayoutRun) f32 {
    var extent: f32 = 0;
    for (run.glyphs) |glyph| extent = @max(extent, glyph.x + glyph.w);
    return extent;
}

/// Forwards every callback to the wrapped renderer and counts them.
// ---------------------------------------------------------------------------
// Color glyph spike: does rasterization already deliver color ink, and does
// the coverage-only atlas reject it without corrupting the pool? (see
// docs/TEXT_ROADMAP.md)
// ---------------------------------------------------------------------------

/// Path of an installed color emoji font, probed like cozmic's own raster
/// tests (`raster_ft.zig`). CBDT bitmap faces (Twemoji, NotoColorEmoji) are
/// first: they produce color ink through the whole engine path today. COLRv1
/// faces are listed last so hosts with both prefer the working path; the
/// COLRv1 limitation itself is pinned by the second spike test below.
const color_font_paths = [_][]const u8{
    "/usr/share/fonts/twemoji/Twemoji.ttf",
    "/usr/share/fonts/truetype/noto/NotoColorEmoji.ttf",
    "/usr/share/fonts/noto/NotoColorEmoji.ttf",
    "/usr/share/fonts/google-noto-color-emoji-fonts/Noto-COLRv1.ttf",
};

test "color spike: engine rasterizes emoji as color ink the atlas rejects" {
    const t = testing;
    const alloc = t.allocator;
    const engine = try testEngine();
    defer engine.deinit();

    // An installed color emoji font, loaded directly into the engine's db.
    const bytes = blk: {
        for (color_font_paths) |path| {
            const data = std.Io.Dir.cwd().readFileAlloc(t.io, path, alloc, .limited(1 << 26)) catch continue;
            break :blk data;
        }
        return error.SkipZigTest;
    };
    defer alloc.free(bytes);
    const font_id = try engine.fs.db.addFaceFromBytes(bytes, 0, "spike-emoji");
    // db registration is metadata only: family matching still needs these
    // bytes in the HarfBuzz shaper backend (`addFontData`), and the FreeType
    // raster registry snapshot was taken at Engine.init, so register the
    // late face there too.
    try engine.fs.addFontData(font_id, bytes, 0, false, null);
    try engine.raster.addFromFontSystem(&engine.fs, &.{font_id});
    try t.expect(engine.raster.getFace(font_id) != null);

    // Shape a flag sequence and rasterize it through the engine's SwashCache.
    // Fallback for the non-Latin run must resolve to the color face (the db
    // query matches its real family name); this also proves the db-facing
    // family name for embedders.
    const info = engine.fs.db.face(font_id).?;
    try t.expect(info.families.len > 0);
    var layout = try engine.layout(alloc, "🇳🇿", .{ .family = info.families[0], .size = 16, .line_height = 20 }, null);
    defer layout.deinit();
    try t.expect(layout.glyphCount() > 0);
    var used_color_font = false;
    var runs_for_face = layout.runs();
    while (runs_for_face.next()) |run| {
        for (run.glyphs) |glyph| {
            if (glyph.font_id == font_id) used_color_font = true;
        }
    }
    try t.expect(used_color_font);
    var saw_color = false;
    var runs = layout.runs();
    while (runs.next()) |run| {
        for (run.glyphs) |glyph| {
            const image = engine.cache.getImage(glyph.physical(0, 0, 1.0).cache_key) catch continue;
            const view = image orelse continue;
            if (view.content == .color) {
                saw_color = true;
                try t.expectEqual(view.placement.width * view.placement.height * 4, view.data.len);
                try t.expect(view.placement.width > 0 and view.placement.height > 0);
                // Real ink, not an all-zero buffer: some pixel has alpha
                // (observed 76x72 with non-zero alpha on this host).
                var inked = false;
                var i: usize = 3;
                while (i < view.data.len) : (i += 4) {
                    if (view.data[i] != 0) {
                        inked = true;
                        break;
                    }
                }
                try t.expect(inked);
            }
        }
    }
    // A host whose only color font is env-blocked (COLRv1 with a FreeType
    // that does not traverse paint graphs) yields no color ink at all; that
    // environment case is pinned by the dedicated COLRv1 test below.
    if (!saw_color) return error.SkipZigTest;

    // The coverage-only atlas contract holds: color ink is rejected without
    // entering the pool, and cannot be read back as a mask entry.
    var probe = Atlas{};
    const fake_key = AtlasKey{ .face_id = font_id, .glyph_id = 99, .size_px = 16 };
    const rgba = [_]u8{ 255, 0, 0, 255 };
    try t.expectError(error.ColorUnsupported, probe.putBitmap(fake_key, 1, 1, 4, &rgba, 0, 0, .color, false));
    try t.expect(probe.get(fake_key) == null);
    try t.expectEqual(@as(usize, 0), probe.pixels_used);
}

test "color spike: COLRv1 renders empty ink at every load-flag combination" {
    // Environment observation, deliberately NOT a portable expectation: on
    // hosts whose FreeType does traverse COLRv1 paint graphs this font
    // produces ink and the assertions below would be false. Skip there.
    const t = testing;
    const alloc = t.allocator;
    var lib = cozmic.raster_ft.Library.init() catch |err| switch (err) {
        error.LibraryUnavailable => return error.SkipZigTest,
        else => return err,
    };
    defer lib.deinit();
    const bytes = std.Io.Dir.cwd().readFileAlloc(
        t.io,
        "/usr/share/fonts/google-noto-color-emoji-fonts/Noto-COLRv1.ttf",
        alloc,
        .limited(1 << 26),
    ) catch return error.SkipZigTest;
    defer alloc.free(bytes);
    var face = try cozmic.raster_ft.Face.initMemory(&lib, bytes, 0);
    defer face.deinit();
    if (!face.hasColor()) return error.SkipZigTest;
    // Emoji flags are GSUB ligatures: a lone regional indicator has no paint
    // data, so assert on both the lone codepoint and the shaped ligature gid
    // the engine layout above produced (3773 for "🇳🇿" on this corpus).
    const lone = face.charIndex('🇳');
    try t.expect(lone != 0);
    const ligature: u32 = 3773;
    // Raw-FT verdict (verified with an independent C probe against
    // FreeType 2.14.3, printing glyph formats and bitmaps): the COLRv1 base
    // glyphs load as outlines but every render path — FT_LOAD_COLOR,
    // FT_LOAD_RENDER, explicit FT_Render_Glyph — yields a 0x0 bitmap with a
    // null buffer. The CBDT control face yields 76x72 BGRA. Cozmic's flag
    // passing is therefore NOT the root cause; this FreeType build simply
    // does not rasterize COLRv1 paint graphs. See docs/TEXT_ROADMAP.md.
    const lone_render = try face.loadRenderFlags(lone, 48, cozmic.raster_ft.FT_LOAD_DEFAULT | cozmic.raster_ft.FT_LOAD_COLOR);
    const ligature_render = try face.loadRenderFlags(ligature, 48, cozmic.raster_ft.FT_LOAD_DEFAULT | cozmic.raster_ft.FT_LOAD_COLOR | cozmic.raster_ft.FT_LOAD_RENDER);
    // The pinned environment observation holds only while this FreeType
    // build cannot rasterize COLRv1. On a host where it can (or after a
    // cozmic upgrade), both renders have ink: skip instead of failing.
    if (lone_render.width > 0 or ligature_render.width > 0) return error.SkipZigTest;
}

const CountingRenderer = struct {
    inner: cozmic.render.Renderer,
    glyphs: usize = 0,
    rects: usize = 0,

    fn renderer(self: *CountingRenderer) cozmic.render.Renderer {
        return .{ .ctx = @ptrCast(self), .vtable = &vtable };
    }

    const vtable = cozmic.render.Renderer.VTable{
        .rectangle = rectangle,
        .glyph = glyph,
    };

    fn rectangle(ctx: *anyopaque, x: i32, y: i32, w: u32, h: u32, color: cozmic.Color) void {
        const self: *CountingRenderer = @ptrCast(@alignCast(ctx));
        self.rects += 1;
        self.inner.rectangle(x, y, w, h, color);
    }

    fn glyph(ctx: *anyopaque, physical_glyph: cozmic.layout.PhysicalGlyph, color: cozmic.Color) void {
        const self: *CountingRenderer = @ptrCast(@alignCast(ctx));
        self.glyphs += 1;
        self.inner.glyph(physical_glyph, color);
    }
};

// ---------------------------------------------------------------------------
// Tests (headless, deterministic: vendored corpus unless stated otherwise)
// ---------------------------------------------------------------------------

const testing = std.testing;
const test_attrs = TextAttrs{ .family = "Inter", .size = 16, .line_height = 20 };
const test_color = cozmic.Color{ .value = 0xFF00_0000 };

/// Corpus engine, skipping only when the host lacks the runtime libraries the
/// cozmic package loads via `dlopen`.
fn testEngine() !*Engine {
    return Engine.init(testing.allocator) catch |err| switch (err) {
        error.ShaperUnavailable, error.LibraryUnavailable, error.NoFontsAvailable => return error.SkipZigTest,
        else => return err,
    };
}

/// Minimal renderer used to observe callbacks without drawing.
const TestRenderer = struct {
    glyphs: usize = 0,
    rects: usize = 0,

    fn renderer(self: *TestRenderer) cozmic.render.Renderer {
        return .{ .ctx = @ptrCast(self), .vtable = &vtable };
    }

    const vtable = cozmic.render.Renderer.VTable{
        .rectangle = rectangle,
        .glyph = glyph,
    };

    fn rectangle(ctx: *anyopaque, x: i32, y: i32, w: u32, h: u32, color: cozmic.Color) void {
        _ = .{ x, y, w, h, color };
        const self: *TestRenderer = @ptrCast(@alignCast(ctx));
        self.rects += 1;
    }

    fn glyph(ctx: *anyopaque, physical_glyph: cozmic.layout.PhysicalGlyph, color: cozmic.Color) void {
        _ = .{ physical_glyph, color };
        const self: *TestRenderer = @ptrCast(@alignCast(ctx));
        self.glyphs += 1;
    }
};

test "text engine: measure equals paint extent" {
    const alloc = testing.allocator;
    const engine = try testEngine();
    defer engine.deinit();

    const Case = struct {
        text: []const u8,
        family: []const u8,
        width_opt: ?f32,
    };
    const wrapping =
        "The quick brown fox jumps over the lazy dog, then the dog jumps " ++
        "back over the fox while the quick brown fox keeps running far away.";
    const cases = [_]Case{
        .{ .text = "Hello world", .family = "Inter", .width_opt = null },
        .{ .text = "Hamburgefonstiv", .family = "Inter", .width_opt = null },
        .{ .text = "Order 66: 12,345.67 units", .family = "Inter", .width_opt = null },
        .{ .text = "خالصة", .family = "Inter", .width_opt = null },
        .{ .text = "Hello خالصة world", .family = "Inter", .width_opt = null },
        .{ .text = wrapping, .family = "Inter", .width_opt = 140 },
    };

    for (cases) |case| {
        const attrs = TextAttrs{ .family = case.family, .size = 16, .line_height = 20 };

        // One layout object backs both the measurement and the paint.
        var layout = try engine.layout(alloc, case.text, attrs, case.width_opt);
        defer layout.deinit();

        var renderer = TestRenderer{};
        const stats = try layout.render(renderer.renderer(), test_color);
        try testing.expectEqual(layout.width, stats.x_extent);
        try testing.expect(stats.glyphs > 0);
        try testing.expectEqual(layout.glyphCount(), stats.glyphs);

        // The glyph-derived width must track cozmic's own line width.
        var line_w_max: f32 = 0;
        var line_runs = layout.runs();
        while (line_runs.next()) |run| line_w_max = @max(line_w_max, run.line_w);
        try testing.expectApproxEqAbs(line_w_max, layout.width, 0.01);

        if (case.width_opt == null) {
            // The Engine helpers must agree with the explicit layout too.
            const measured = try engine.measure(alloc, case.text, attrs);
            try testing.expectEqual(layout.width, measured);

            var paint_renderer = TestRenderer{};
            const painted = try engine.paint(alloc, case.text, attrs, null, paint_renderer.renderer());
            try testing.expectEqual(measured, painted.x_extent);
            try testing.expect(painted.glyphs > 0);
        }
    }

    // The wrapping case actually wrapped (several runs) and grew in height.
    var wrapped = try engine.layout(alloc, wrapping, test_attrs, 140);
    defer wrapped.deinit();
    var runs = wrapped.runs();
    var count: usize = 0;
    while (runs.next()) |_| count += 1;
    try testing.expect(count > 1);
    try testing.expect(wrapped.height > wrapped.width);
}

test "text engine: caret round-trip stays on grapheme boundaries" {
    const alloc = testing.allocator;
    const engine = try testEngine();
    defer engine.deinit();

    const text = "Hello world";
    var layout = try engine.layout(alloc, text, test_attrs, null);
    defer layout.deinit();
    try testing.expect(layout.width > 0);

    // First run is the only run (single line); reuse its glyphs for bounds.
    var it = layout.runs();
    const first_run = it.next() orelse return error.TestUnexpectedResult;
    const first_line_w = first_run.line_w;
    try testing.expect(first_run.glyphs.len > 0);
    // `width` is the glyph-derived extent; it must track cozmic's line width.
    try testing.expectApproxEqAbs(first_line_w, layout.width, 0.01);

    const samples = [_]f32{ 0, layout.width * 0.2, layout.width * 0.5, layout.width * 0.8, layout.width };
    for (samples) |x| {
        const cursor = (try layout.hit(x, 0)) orelse return error.TestUnexpectedResult;
        try testing.expectEqual(@as(usize, 0), cursor.line);
        try testing.expect(cursor.index <= text.len);
        try testing.expect(cozmic.unicode.isGraphemeBoundary(text, cursor.index));

        const pos = layout.cursorPosition(cursor) orelse return error.TestUnexpectedResult;
        try testing.expect(pos.x >= -0.01);
        try testing.expect(pos.x <= first_line_w + 0.01);
        var inside = false;
        for (first_run.glyphs) |glyph| {
            if (pos.x >= glyph.x - 0.01 and pos.x <= glyph.x + glyph.w + 0.01) inside = true;
        }
        try testing.expect(inside);
    }

    // Past the end of the line: cursor lands on the final byte index.
    const end_cursor = (try layout.hit(layout.width + 10, 0)) orelse return error.TestUnexpectedResult;
    try testing.expectEqual(text.len, end_cursor.index);
    try testing.expect(cozmic.unicode.isGraphemeBoundary(text, end_cursor.index));
}

test "text engine: per-script fallback uses multiple fonts" {
    const alloc = testing.allocator;
    const engine = try testEngine();
    defer engine.deinit();

    var layout = try engine.layout(alloc, "Hello خالصة world", test_attrs, null);
    defer layout.deinit();

    const font_ids = try layout.distinctFonts(alloc);
    defer alloc.free(font_ids);
    try testing.expect(font_ids.len >= 2);

    var it = layout.runs();
    var glyphs: usize = 0;
    while (it.next()) |run| {
        for (run.glyphs) |glyph| {
            // No missing-glyph placeholders: fallback found real faces.
            try testing.expect(glyph.glyph_id != 0);
            glyphs += 1;
        }
    }
    try testing.expect(glyphs > 0);
}

test "text engine: rasterizing through the engine cache produces masks" {
    const alloc = testing.allocator;
    const engine = try testEngine();
    defer engine.deinit();

    var layout = try engine.layout(alloc, "Hello world", test_attrs, null);
    defer layout.deinit();

    // Every laid-out glyph yields a mask image with sane placement. This is
    // the exact call the element painter makes per glyph.
    var it = layout.runs();
    var masks: usize = 0;
    while (it.next()) |run| {
        for (run.glyphs) |glyph| {
            const physical = glyph.physical(0, run.line_y, 1.0);
            const image = try engine.cache.getImage(physical.cache_key) orelse continue;
            try testing.expectEqual(cozmic.swash_cache.ImageContent.mask, image.content);
            const bytes = @as(usize, image.placement.width) * image.placement.height;
            try testing.expectEqual(bytes, image.data.len);
            masks += 1;
        }
    }
    try testing.expect(masks > 0);
}

test "text engine: system fonts shape when available" {
    const alloc = testing.allocator;
    const engine = Engine.initSystem(alloc) catch |err| switch (err) {
        error.NoFontsAvailable, error.LibraryUnavailable, error.ShaperUnavailable => return error.SkipZigTest,
        else => return err,
    };
    defer engine.deinit();

    var layout = try engine.layout(alloc, "Hello", .{}, null);
    defer layout.deinit();
    try testing.expect(layout.glyphCount() > 0);
    try testing.expect(layout.width > 0);
}

test "text engine: deinit is leak-free" {
    const engine = try testEngine();
    engine.deinit();
}

test "text engine: tracking widens measure and paint equally" {
    const alloc = testing.allocator;
    const engine = try testEngine();
    defer engine.deinit();

    const plain = TextAttrs{ .family = "Inter", .size = 16, .line_height = 20 };
    var tracked = plain;
    tracked.tracking = 2;

    const text = "abcd";
    const base_w = try engine.measure(alloc, text, plain);
    const tracked_w = try engine.measure(alloc, text, tracked);
    try testing.expect(tracked_w > base_w);

    var layout = try engine.layout(alloc, text, tracked, null);
    defer layout.deinit();
    var renderer = TestRenderer{};
    const stats = try layout.render(renderer.renderer(), test_color);
    try testing.expectEqual(layout.width, stats.x_extent);
    try testing.expectApproxEqAbs(tracked_w, stats.x_extent, 0.001);
}

test "text engine: corpus selection never silently falls back to host fonts" {
    const alloc = testing.allocator;
    const io = std.testing.io;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    // Valid temp corpus: one real font copied out of the vendored corpus.
    const valid_path = blk: {
        try tmp.dir.createDirPath(io, "valid");
        const source = readCorpusFile(alloc, io, "Inter-Regular.ttf") catch |err| switch (err) {
            error.FileNotFound => return error.SkipZigTest,
            else => return err,
        };
        defer alloc.free(source);
        try tmp.dir.writeFile(io, .{ .sub_path = "valid/Inter-Regular.ttf", .data = source });
        break :blk try tmpSubPath(alloc, &tmp, "valid");
    };
    defer alloc.free(valid_path);

    const engine = Engine.initWithDirs(alloc, &.{valid_path}, true) catch |err| switch (err) {
        error.LibraryUnavailable, error.ShaperUnavailable => return error.SkipZigTest,
        else => return err,
    };
    defer engine.deinit();
    try testing.expect(engine.fs.fontIds().len > 0);
    var layout = try engine.layout(alloc, "Hello world", test_attrs, null);
    defer layout.deinit();
    try testing.expect(layout.glyphCount() > 0);

    // Present but broken: a `.ttf` that is not a font. Must fail loudly even
    // though `fallback_to_system` is true, otherwise tests silently run on
    // host fonts.
    try tmp.dir.createDirPath(io, "broken");
    try tmp.dir.writeFile(io, .{ .sub_path = "broken/not-a-font.ttf", .data = "definitely not a font" });
    const broken_path = try tmpSubPath(alloc, &tmp, "broken");
    defer alloc.free(broken_path);
    try testing.expectError(error.FontCorpusIncomplete, Engine.initWithDirs(alloc, &.{broken_path}, true));

    // Present but empty is just as broken: "no face loaded" is not "absent".
    try tmp.dir.createDirPath(io, "empty");
    const empty_path = try tmpSubPath(alloc, &tmp, "empty");
    defer alloc.free(empty_path);
    try testing.expectError(error.FontCorpusIncomplete, Engine.initWithDirs(alloc, &.{empty_path}, true));

    // Absent path, shared by the mixed and no-fallback checks.
    const missing_path = try tmpSubPath(alloc, &tmp, "missing");
    defer alloc.free(missing_path);

    // A broken candidate before a valid one does not poison the scan and does
    // not touch host fonts: the valid corpus still wins.
    const mixed = Engine.initWithDirs(alloc, &.{ broken_path, valid_path, missing_path }, true) catch |err| switch (err) {
        error.LibraryUnavailable, error.ShaperUnavailable => return error.SkipZigTest,
        else => return err,
    };
    mixed.deinit();

    // Absent dirs: without fallback the engine refuses; with fallback it
    // behaves like `initSystem` (host-dependent, so only assert the corpus
    // error is not what comes back).
    try testing.expectError(error.FontCorpusIncomplete, Engine.initWithDirs(alloc, &.{missing_path}, false));
    if (Engine.initWithDirs(alloc, &.{missing_path}, true)) |system_engine| {
        defer system_engine.deinit();
        try testing.expect(system_engine.fs.fontIds().len > 0);
    } else |err| switch (err) {
        error.NoFontsAvailable, error.LibraryUnavailable, error.ShaperUnavailable => {},
        else => return err,
    }
}

test "text engine: fractional sizes shape at the painter's pixel size" {
    const alloc = testing.allocator;
    const engine = try testEngine();
    defer engine.deinit();

    const text = "Hamburgefonstiv";
    // `sizeToPx` rounds, so the two fractional sizes land on different
    // integers; each must shape at exactly the integer the painter keys the
    // atlas with.
    try testing.expectEqual(@as(u16, 14), sizeToPx(14.4));
    try testing.expectEqual(@as(u16, 15), sizeToPx(14.6));

    var small = try engine.layout(alloc, text, .{ .family = "Inter", .size = 14.4, .line_height = 20 }, null);
    defer small.deinit();
    var large = try engine.layout(alloc, text, .{ .family = "Inter", .size = 14.6, .line_height = 20 }, null);
    defer large.deinit();

    var small_glyphs: usize = 0;
    var runs = small.runs();
    while (runs.next()) |run| {
        for (run.glyphs) |g| {
            try testing.expectEqual(@as(f32, 14), g.font_size);
            small_glyphs += 1;
        }
    }
    try testing.expect(small_glyphs > 0);
    runs = large.runs();
    while (runs.next()) |run| {
        for (run.glyphs) |g| try testing.expectEqual(@as(f32, 15), g.font_size);
    }
    try testing.expect(large.width > small.width);

    // Two attributes in the same rounding bucket shape identically: advances
    // and cache keys can no longer disagree with the painter.
    var same_px = try engine.layout(alloc, text, .{ .family = "Inter", .size = 14.49, .line_height = 20 }, null);
    defer same_px.deinit();
    try testing.expectEqual(small.width, same_px.width);

    // Tracking is pixels per glyph mapped through the quantized size: 14.6
    // shapes at 15, so the EM conversion must divide by 15 (dividing by 14.6
    // would add 3 * 15/14.6 px per glyph instead of exactly 3).
    const base_attrs = TextAttrs{ .family = "Inter", .size = 14.6, .line_height = 20 };
    var tracked_attrs = base_attrs;
    tracked_attrs.tracking = 3;
    const base_w = try engine.measure(alloc, "abcd", base_attrs);
    var tracked = try engine.layout(alloc, "abcd", tracked_attrs, null);
    defer tracked.deinit();
    try testing.expectEqual(@as(usize, 4), tracked.glyphCount());
    const glyphs: f32 = @floatFromInt(tracked.glyphCount());
    try testing.expectApproxEqAbs(base_w + 3 * glyphs, tracked.width, 0.01);
}

/// Cwd-relative path of a subdirectory under `testing.tmpDir`'s root, for
/// `Engine.initWithDirs`/cozmic's `loadFontsDir` (which resolve relative to
/// the process cwd). Caller frees.
fn tmpSubPath(alloc: std.mem.Allocator, tmp: *testing.TmpDir, sub: []const u8) ![]u8 {
    return std.fs.path.join(alloc, &.{ ".zig-cache", "tmp", &tmp.sub_path, sub });
}

test "text engine: cached layout key rejects changed inputs and engines" {
    const alloc = testing.allocator;
    const engine = try testEngine();
    defer engine.deinit();

    const attrs = TextAttrs{ .family = "Inter", .size = 16, .line_height = 20 };
    const calls_before = engine.layout_calls;
    const cached = try engine.layoutCached(alloc, "Hello", attrs, 100);
    defer cached.deinit();
    try testing.expectEqual(calls_before + 1, engine.layout_calls);
    try testing.expectEqual(@as(f32, 100), cached.key.wrap_width.?);
    try testing.expect(cached.matches(engine, "Hello", attrs, 100));

    // Any changed shape input invalidates the handoff.
    try testing.expect(!cached.matches(engine, "Hello!", attrs, 100));
    var changed = attrs;
    changed.size = 15;
    try testing.expect(!cached.matches(engine, "Hello", changed, 100));
    changed = attrs;
    changed.line_height = 24;
    try testing.expect(!cached.matches(engine, "Hello", changed, 100));
    changed = attrs;
    changed.tracking = 1;
    try testing.expect(!cached.matches(engine, "Hello", changed, 100));
    changed = attrs;
    changed.weight = 700;
    try testing.expect(!cached.matches(engine, "Hello", changed, 100));
    changed = attrs;
    changed.family = "Other Sans";
    try testing.expect(!cached.matches(engine, "Hello", changed, 100));
    try testing.expect(!cached.matches(engine, "Hello", attrs, 99));
    try testing.expect(!cached.matches(engine, "Hello", attrs, null));

    // Engine identity is part of the key: a different engine may shape with
    // different faces/fallback. `matches` only compares the pointer.
    try testing.expect(!cached.matches(@ptrFromInt(16), "Hello", attrs, 100));
}

test "text engine: sizeToPx rounds and clamps without trapping" {
    try testing.expectEqual(@as(u16, 14), sizeToPx(14));
    try testing.expectEqual(@as(u16, 14), sizeToPx(13.6));
    try testing.expectEqual(@as(u16, 1), sizeToPx(0.2));
    try testing.expectEqual(@as(u16, 256), sizeToPx(999));
    try testing.expectEqual(@as(u16, 1), sizeToPx(std.math.nan(f32)));
    try testing.expectEqual(@as(u16, 1), sizeToPx(-5));
}

test "text engine: synthetic bold is axis-aware" {
    const engine = try testEngine();
    defer engine.deinit();

    // Pick a lighter face and force a wght axis onto it: cozmic forwards
    // `key.font_weight` to the variation coordinates, so a 700 request inside
    // the axis is rasterized at 700 and must NOT be dilated again. Mutating
    // the test engine's db is safe (restored below) and keeps this coverage
    // host-independent.
    var info: ?*cozmic.font_system.FaceInfo = null;
    for (engine.fs.db.faces.items) |*fi| {
        if (fi.weight < 600) {
            info = fi;
            break;
        }
    }
    const face = info orelse return error.SkipZigTest;
    const saved_min = face.variable_wght_min;
    const saved_max = face.variable_wght_max;
    defer {
        face.variable_wght_min = saved_min;
        face.variable_wght_max = saved_max;
    }

    // Axis covers 700: the raster honors the request, no dilation.
    face.variable_wght_min = 100;
    face.variable_wght_max = 900;
    try testing.expect(!engine.needsSyntheticBold(face.id, 700));
    try testing.expect(!engine.needsSyntheticBold(face.id, 600));

    // Axis stops below the request: the raster cannot reach 700, dilate.
    face.variable_wght_max = 650;
    try testing.expect(engine.needsSyntheticBold(face.id, 700));

    // Static face (no axis data): keep the synthetic approximation.
    face.variable_wght_min = null;
    face.variable_wght_max = null;
    try testing.expect(engine.needsSyntheticBold(face.id, 700));

    // Non-bold requests never dilate.
    try testing.expect(!engine.needsSyntheticBold(face.id, 400));
    try testing.expect(!engine.needsSyntheticBold(face.id, 500));
}

test "text engine: real bold faces and unknown ids need no dilation" {
    const engine = try testEngine();
    defer engine.deinit();
    for (engine.fs.db.faces.items) |fi| {
        if (fi.weight < 700) continue;
        try testing.expect(!engine.needsSyntheticBold(fi.id, 700));
    }
    // The vendored corpus may ship no 700 face; the unknown-id paths below
    // are always exercised.
    try testing.expect(engine.needsSyntheticBold(999_999, 700));
    try testing.expect(!engine.needsSyntheticBold(999_999, 400));
}

test "selection geometry covers wrapped lines and mixed bidi without negative widths" {
    const alloc = std.testing.allocator;
    const engine = Engine.init(alloc) catch return error.SkipZigTest;
    defer engine.deinit();
    const text = "Latin אבג a\u{301} 👩🏽‍💻 more words wrapping across lines";
    var layout = try engine.layout(alloc, text, .{ .size = 16, .line_height = 20 }, 100);
    defer layout.deinit();
    const rects = try layout.selectionRects(alloc, .{ .line = 0, .index = text.len }, .{ .line = 0, .index = 0 });
    defer alloc.free(rects);
    try std.testing.expect(rects.len > 0);
    var max_y: f32 = 0;
    for (rects) |r| {
        try std.testing.expect(r.w > 0 and r.h == 20);
        try std.testing.expect(r.x >= -0.01);
        max_y = @max(max_y, r.y);
    }
    try std.testing.expect(max_y > 0);
    const hit = (try layout.hit(0, max_y)).?;
    try std.testing.expect(@import("cozmic").unicode.isGraphemeBoundary(text, hit.index));
    const pos = layout.cursorPosition(hit).?;
    try std.testing.expectApproxEqAbs(max_y, pos.y, 0.01);
    const empty = try layout.selectionRects(alloc, hit, hit);
    defer alloc.free(empty);
    try std.testing.expectEqual(@as(usize, 0), empty.len);
}
