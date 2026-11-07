//! Port of GPUI `text_system.rs`, built on cozmic (the Zig port of cosmic-text).
//!
//! `TextSystem` owns the cozmic `FontSystem` (system font discovery, shaping, per-script
//! fallback), a FreeType raster and swash image cache for glyph bitmaps, and the GPUI
//! line layout cache. Shaping calls cozmic's `ShapeLine` directly with one attribute
//! span per run, and never asks cozmic to wrap: wrapping is done here by `LineWrapper`
//! over the unwrapped `LineLayout`.
//!
//! `FontId` indexes the text system's table of resolved fonts. An entry holds the cozmic
//! face that glyph ids are meaningful in, so a glyph that fell back to another face gets its
//! own entry. Glyphs are rasterized through that face.
//!
//! Lifetimes: `ShapedLine`, `WrappedLine` and the layouts they reference are valid for the
//! frame they were produced in and the next one (see `line_layout.zig`). Strings returned by
//! shaping point into the cache and share that lifetime.

const std = @import("std");
const cozmic = @import("cozmic");
const geometry = @import("geometry.zig");
const style = @import("style.zig");
const atlas = @import("atlas.zig");
const window_mod = @import("window.zig");

pub const font_mod = @import("text_system/font.zig");
pub const line_layout = @import("text_system/line_layout.zig");
const lw_mod = @import("text_system/line_wrapper.zig");
pub const line = @import("text_system/line.zig");

const Allocator = std.mem.Allocator;
const Pixels = geometry.Pixels;
const DevicePixels = geometry.DevicePixels;
const Bounds = geometry.Bounds;
const Size = geometry.Size;
const Point = geometry.Point;
const TextRun = style.TextRun;

// Re-exported font descriptions.
pub const SharedString = font_mod.SharedString;
pub const Font = font_mod.Font;
pub const FontWeight = font_mod.FontWeight;
pub const FontStyle = font_mod.FontStyle;
pub const FontFeatures = font_mod.FontFeatures;
pub const FontFeature = font_mod.FontFeature;
pub const FontFallbacks = font_mod.FontFallbacks;
pub const font = font_mod.font;

// Re-exported layout types.
pub const FontRun = line_layout.FontRun;
pub const ShapedRun = line_layout.ShapedRun;
pub const ShapedGlyph = line_layout.ShapedGlyph;
pub const LineLayout = line_layout.LineLayout;
pub const WrappedLineLayout = line_layout.WrappedLineLayout;
pub const WrapBoundary = line_layout.WrapBoundary;
pub const IndexResult = line_layout.IndexResult;
pub const LineLayoutCache = line_layout.LineLayoutCache;
pub const LineWrapper = lw_mod.LineWrapper;
pub const TruncateFrom = lw_mod.TruncateFrom;
pub const IndentAdjustment = lw_mod.IndentAdjustment;
pub const LineFragment = lw_mod.LineFragment;
pub const Boundary = lw_mod.Boundary;
pub const ShapedLine = line.ShapedLine;
pub const WrappedLine = line.WrappedLine;
pub const DecorationRun = line.DecorationRun;

/// An opaque identifier for a resolved font (an index into the text system's font table).
pub const FontId = u32;
/// A glyph index within the face of a run.
pub const GlyphId = u32;

/// Number of subpixel glyph variants along the X axis.
pub const SUBPIXEL_VARIANTS_X: f32 = 4;
/// Number of subpixel glyph variants along the Y axis.
pub const SUBPIXEL_VARIANTS_Y: f32 = 1;

/// Sentinel for a font entry without a backing face (no fonts installed).
const NO_FACE: u32 = std.math.maxInt(u32);

/// Most missing-glyph reports kept before new ones are dropped (GPUI `MAX_REPORTED_MISSING_GLYPHS`).
const MAX_MISSING_GLYPHS = 1024;

/// Marks a face that no installed font has for a character (see `text_presentation_font`).
const NO_FONT: FontId = std.math.maxInt(FontId);

/// A byte range of a line drawn with a different font than its run (see `apply_text_presentation`).
const FontRunOverride = struct { start: usize, end: usize, font_id: FontId };

/// The byte offset where the character that ends at `end` starts.
fn prev_char_start(text: []const u8, end: usize) usize {
    var i = end;
    while (i > 0 and (text[i - 1] & 0xC0) == 0x80) i -= 1;
    return if (i > 0) i - 1 else 0;
}

/// The font of the run that holds byte `index`, or null past the runs.
fn font_at(runs: []const FontRun, index: usize) ?FontId {
    var offset: usize = 0;
    for (runs) |run| {
        if (index < offset + run.len) return run.font_id;
        offset += run.len;
    }
    return null;
}

/// Appends `len` bytes in `font_id` to `list`, extending the last run when it has the same font.
fn append_font_run(allocator: Allocator, list: *std.ArrayList(FontRun), len: usize, font_id: FontId) !void {
    if (len == 0) return;
    if (list.items.len > 0) {
        const last = &list.items[list.items.len - 1];
        if (last.font_id == font_id) {
            last.len += len;
            return;
        }
    }
    try list.append(allocator, .{ .len = len, .font_id = font_id });
}

/// Whether `haystack` contains `needle`, ignoring ASCII case.
fn ascii_contains_ci(haystack: []const u8, needle: []const u8) bool {
    if (needle.len > haystack.len) return false;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[i..][0..needle.len], needle)) return true;
    }
    return false;
}

/// Number of entries of the sorted `values` that are `<= index`.
fn partition_point_usize(values: []const usize, index: usize) usize {
    var lo: usize = 0;
    var hi: usize = values.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        if (values[mid] <= index) lo = mid + 1 else hi = mid;
    }
    return lo;
}

/// Maps the virtual font names to the families behind them (GPUI `font_name_with_fallbacks`). `system` is
/// what ".SystemUIFont" stands for. GPUI's `font_name_with_fallbacks_shared` is the same function, since
/// `SharedString` is `[]const u8` here.
pub fn font_name_with_fallbacks(name: []const u8, system: []const u8) []const u8 {
    if (std.mem.eql(u8, name, ".SystemUIFont")) return system;
    if (std.mem.eql(u8, name, ".ZedSans") or std.mem.eql(u8, name, "Zed Plex Sans")) return "IBM Plex Sans";
    if (std.mem.eql(u8, name, ".ZedMono") or std.mem.eql(u8, name, "Zed Plex Mono")) return "Lilex";
    return name;
}

/// The distance from the baseline to the underline, for a line of `line_height`.
pub fn underline_y_offset(line_height: Pixels, ascent: Pixels, descent: Pixels) Pixels {
    const UNDERLINE_DESCENT_OFFSET_FACTOR: f32 = 0.618;
    const padding_top = (line_height - ascent - descent) / 2.0;
    return padding_top + ascent + descent * UNDERLINE_DESCENT_OFFSET_FACTOR;
}

/// Parameters identifying one rasterized glyph (GPUI `RenderGlyphParams`).
pub const RenderGlyphParams = struct {
    font_id: FontId,
    glyph_id: GlyphId,
    font_size: Pixels,
    subpixel_variant: Point(u8),
    scale_factor: f32,
    is_emoji: bool,

    /// Atlas key: a hash of every field, in the texture kind the glyph is stored in.
    pub fn atlas_key(self: *const RenderGlyphParams) atlas.AtlasKey {
        var h = std.hash.Wyhash.init(0x67_6c_79_70_68);
        h.update(std.mem.asBytes(&self.font_id));
        h.update(std.mem.asBytes(&self.glyph_id));
        const size_bits: u32 = @bitCast(self.font_size);
        h.update(std.mem.asBytes(&size_bits));
        h.update(std.mem.asBytes(&self.subpixel_variant.x));
        h.update(std.mem.asBytes(&self.subpixel_variant.y));
        const scale_bits: u32 = @bitCast(self.scale_factor);
        h.update(std.mem.asBytes(&scale_bits));
        h.update(std.mem.asBytes(&self.is_emoji));
        return .{ .glyph = .{
            .id = h.final(),
            .texture_kind = if (self.is_emoji) .polychrome else .monochrome,
        } };
    }
};

/// Vertical metrics and design-space box of a font (GPUI `FontMetrics`). The quantities are stored in
/// font units; the methods scale them to pixels. The fields carry an `_units` suffix because Zig does
/// not allow a field and a method with the same name, as GPUI has (`metrics.ascent(font_size)`).
pub const FontMetrics = struct {
    /// Font units per em.
    units_per_em: u32 = 1000,
    /// Distance from the baseline to the top of the tallest glyph, in font units.
    ascent_units: f32 = 800,
    /// Distance from the baseline to the bottom of the lowest glyph, in font units (positive).
    descent_units: f32 = 200,
    /// The recommended extra space between lines, in font units (`hhea` lineGap).
    line_gap_units: f32 = 0,
    underline_position_units: f32 = -100,
    underline_thickness_units: f32 = 50,
    /// Height of a capital letter (`OS/2` sCapHeight, version 2 and later), or 0.7 em when the font has none.
    cap_height_units: f32 = 700,
    /// Height of a lowercase x (`OS/2` sxHeight, version 2 and later), or 0.5 em when the font has none.
    x_height_units: f32 = 500,
    /// Font bounding box in font units (`head` xMin/yMin/xMax/yMax, or an estimate).
    bounding_box_units: Bounds(f32) = .{ .origin = .{ .x = 0, .y = -800 }, .size = .{ .width = 1000, .height = 1000 } },

    fn scale(self: FontMetrics, units: f32, font_size: Pixels) Pixels {
        return (units / @as(f32, @floatFromInt(self.units_per_em))) * font_size;
    }
    /// The recommended distance from the baseline to the top of the glyphs, in pixels.
    pub fn ascent(self: FontMetrics, font_size: Pixels) Pixels {
        return self.scale(self.ascent_units, font_size);
    }
    /// The recommended distance from the baseline to the bottom of the glyphs, in pixels.
    pub fn descent(self: FontMetrics, font_size: Pixels) Pixels {
        return self.scale(self.descent_units, font_size);
    }
    /// The recommended extra space between lines, in pixels.
    pub fn line_gap(self: FontMetrics, font_size: Pixels) Pixels {
        return self.scale(self.line_gap_units, font_size);
    }
    /// The suggested position of the underline, in pixels.
    pub fn underline_position(self: FontMetrics, font_size: Pixels) Pixels {
        return self.scale(self.underline_position_units, font_size);
    }
    /// The suggested thickness of the underline, in pixels.
    pub fn underline_thickness(self: FontMetrics, font_size: Pixels) Pixels {
        return self.scale(self.underline_thickness_units, font_size);
    }
    /// The height of a capital letter, in pixels.
    pub fn cap_height(self: FontMetrics, font_size: Pixels) Pixels {
        return self.scale(self.cap_height_units, font_size);
    }
    /// The height of a lowercase x, in pixels.
    pub fn x_height(self: FontMetrics, font_size: Pixels) Pixels {
        return self.scale(self.x_height_units, font_size);
    }
    /// The outer limits of the area the font covers, in pixels.
    pub fn bounding_box(self: FontMetrics, font_size: Pixels) Bounds(Pixels) {
        const b = self.bounding_box_units;
        return .{
            .origin = .{ .x = self.scale(b.origin.x, font_size), .y = self.scale(b.origin.y, font_size) },
            .size = .{ .width = self.scale(b.size.width, font_size), .height = self.scale(b.size.height, font_size) },
        };
    }
};

/// The spacing a fallback font must have to stand in for a missing glyph (GPUI `FallbackFontClass`).
pub const FallbackFontClass = enum {
    /// A proportionally spaced fallback font.
    proportional,
    /// A fixed-width fallback font.
    monospace,
};

/// A grapheme cluster that no font in the fallback chain can draw (GPUI `MissingGlyph`).
pub const MissingGlyph = struct {
    /// The grapheme's UTF-8 text.
    text: []const u8,
    /// The spacing the font it was shaped with had.
    class: FallbackFontClass,

    /// Creates a report for `grapheme` (GPUI `MissingGlyph::new`). The text is not copied.
    pub fn new(grapheme_text: []const u8, class: FallbackFontClass) MissingGlyph {
        return .{ .text = grapheme_text, .class = class };
    }

    /// The unresolved grapheme cluster (GPUI `grapheme`).
    pub fn grapheme(self: MissingGlyph) []const u8 {
        return self.text;
    }

    /// The spacing behavior required of a fallback font (GPUI `font_class`).
    pub fn font_class(self: MissingGlyph) FallbackFontClass {
        return self.class;
    }
};

/// Result of rasterizing a glyph to bytes.
pub const RasterizedGlyph = struct {
    size: Size(DevicePixels),
    /// A8 coverage for monochrome glyphs, premultiplied RGBA for color glyphs.
    bytes: []const u8,
};

/// A resolved font (one table entry per `FontId`).
const FontEntry = struct {
    /// The cozmic face glyph ids are meaningful in, or `NO_FACE`.
    face: u32 = NO_FACE,
    /// Family used when shaping: a named family, or a generic one for `.sans_serif`/`.monospace`.
    family_kind: cozmic.font_system.FamilyTag = .sans_serif,
    family_name: []u8 = &.{},
    weight: u16 = 400,
    style: cozmic.attrs.Style = .normal,
    features: []FontFeature = &.{},
    /// The `Font` this entry was resolved from (owned copies), for lookup; null for face entries.
    key: ?Font = null,
    metrics: ?FontMetrics = null,
};

/// Per-face data read from the font file once.
const FaceData = struct {
    is_color: bool = false,
    metrics: ?FontMetrics = null,
};

const RasterKey = struct {
    font_id: u32,
    glyph_id: u32,
    size_bits: u32,
    sub_x: u8,
    sub_y: u8,
    scale_bits: u32,
    is_emoji: bool,

    fn from(p: *const RenderGlyphParams) RasterKey {
        return .{
            .font_id = p.font_id,
            .glyph_id = p.glyph_id,
            .size_bits = @bitCast(p.font_size),
            .sub_x = p.subpixel_variant.x,
            .sub_y = p.subpixel_variant.y,
            .scale_bits = @bitCast(p.scale_factor),
            .is_emoji = p.is_emoji,
        };
    }
};

const WidthKey = struct { font_id: FontId, size_bits: u32 };

/// Pending glyph raster job handed to the atlas through a `TileBuilder`.
const TileJob = struct {
    ts: *TextSystem,
    params: RenderGlyphParams,
};

/// Families tried, in order, when a requested family and its fallbacks are missing.
const SANS_CANDIDATES = [_][]const u8{ "Inter", "Noto Sans", "Open Sans", "DejaVu Sans", "Liberation Sans", "FreeSans", "Arial" };
const MONO_CANDIDATES = [_][]const u8{ "Noto Sans Mono", "DejaVu Sans Mono", "Liberation Mono", "FiraMono", "Inter" };

/// The GPUI text system: font resolution, shaping, line layout caching and glyph rasterization.
pub const TextSystem = struct {
    allocator: Allocator,
    fs: cozmic.FontSystem,
    raster: ?cozmic.Raster = null,
    swash: ?cozmic.SwashCache = null,
    /// For text laid out outside any window's draw.
    layout_cache: LineLayoutCache,
    /// The cache in use: the drawing window's while it draws (GPUI's `WindowTextSystem` has one per
    /// window), since a cached view's layouts are named by position in its own window's frames.
    active_cache: *LineLayoutCache,

    fonts: std.ArrayList(FontEntry) = .empty,
    /// Hash of a `Font` to its entry; verified with `Font.eql` on lookup.
    font_index: std.AutoHashMapUnmanaged(u64, FontId) = .empty,
    /// Plain entries interned per cozmic face, for glyphs that fell back to another face.
    face_index: std.AutoHashMapUnmanaged(u32, FontId) = .empty,
    face_data: std.AutoHashMapUnmanaged(u32, FaceData) = .empty,
    raster_bounds_cache: std.AutoHashMapUnmanaged(RasterKey, Bounds(DevicePixels)) = .empty,
    char_widths: std.AutoHashMapUnmanaged(WidthKey, *lw_mod.CharWidthCache) = .empty,

    /// Scratch runs reused by every shaping call.
    font_runs_scratch: std.ArrayList(FontRun) = .empty,
    tile_job: TileJob = undefined,
    tile_bytes: std.ArrayList(u8) = .empty,

    /// Whether shaping collects missing glyphs (GPUI `enable_missing_glyph_reporting`). Off by default.
    missing_glyph_reporting: bool = false,
    /// Keys of the reports already queued, so each (class, grapheme) is reported once until `add_fonts`.
    missing_glyph_seen: std.StringHashMapUnmanaged(void) = .empty,
    /// Reports waiting for `take_missing_glyphs`. Their texts are owned by the queue.
    missing_glyph_pending: std.ArrayList(MissingGlyph) = .empty,
    /// The face chosen for a character followed by U+FE0E, per character (see `text_presentation_font`).
    presentation_faces: std.AutoHashMapUnmanaged(u21, FontId) = .empty,

    /// Loads the system fonts and sets up glyph rasterization. Never fails for lack of fonts:
    /// text then measures as zero width, and layout still works.
    pub fn create(allocator: Allocator) !*TextSystem {
        const self = try allocator.create(TextSystem);
        errdefer allocator.destroy(self);
        self.* = .{
            .allocator = allocator,
            .fs = try cozmic.FontSystem.init(allocator),
            .layout_cache = undefined,
            .active_cache = undefined,
        };
        errdefer self.fs.deinit();
        self.layout_cache = self.new_layout_cache();
        self.active_cache = &self.layout_cache;

        const io = std.Io.Threaded.global_single_threaded.io();
        _ = self.fs.loadSystemFonts(io);

        // Rasterization is optional: without FreeType, glyphs are simply not drawn.
        if (cozmic.Raster.init(allocator)) |r| {
            self.raster = r;
            self.raster.?.addFromFontSystem(&self.fs, self.fs.fontIds()) catch {};
            self.swash = cozmic.SwashCache.init(allocator, null);
            self.swash.?.setRaster(&self.raster.?);
        } else |_| {}
        return self;
    }

    pub fn destroy(self: *TextSystem) void {
        const allocator = self.allocator;
        self.layout_cache.deinit();
        for (self.fonts.items) |*e| free_entry(allocator, e);
        self.fonts.deinit(allocator);
        self.font_index.deinit(allocator);
        self.face_index.deinit(allocator);
        self.face_data.deinit(allocator);
        self.raster_bounds_cache.deinit(allocator);
        var cw = self.char_widths.valueIterator();
        while (cw.next()) |c| {
            c.*.deinit(allocator);
            allocator.destroy(c.*);
        }
        self.char_widths.deinit(allocator);
        self.font_runs_scratch.deinit(allocator);
        self.tile_bytes.deinit(allocator);
        self.clear_missing_glyph_seen();
        self.missing_glyph_seen.deinit(allocator);
        for (self.missing_glyph_pending.items) |g| allocator.free(g.text);
        self.missing_glyph_pending.deinit(allocator);
        self.presentation_faces.deinit(allocator);
        if (self.swash) |*s| s.deinit();
        if (self.raster) |*r| r.deinit();
        self.fs.deinit();
        allocator.destroy(self);
    }

    fn free_entry(allocator: Allocator, e: *FontEntry) void {
        allocator.free(e.family_name);
        allocator.free(e.features);
        if (e.key) |*k| {
            allocator.free(@constCast(k.family));
            allocator.free(@constCast(k.features.features));
        }
    }

    // -- font resolution -------------------------------------------------

    /// Resolves `font` to a `FontId`, reusing an earlier resolution of an equal font.
    /// Adds in-memory font files, usable by family name from then on (GPUI `add_fonts`). The bytes
    /// are copied. Fonts resolved earlier keep their result until asked for again; text laid out
    /// with them stays valid.
    pub fn add_fonts(self: *TextSystem, fonts: []const []const u8) !void {
        for (fonts) |bytes| {
            const before = self.fs.fontIds().len;
            _ = try self.fs.addFontBytes(bytes);
            if (self.raster) |*raster| try raster.addFromFontSystem(&self.fs, self.fs.fontIds()[before..]);
        }
        // A family asked for before may now resolve to a new face, and a glyph reported missing may now exist.
        self.font_index.clearRetainingCapacity();
        self.presentation_faces.clearRetainingCapacity();
        self.clear_missing_glyph_seen();
    }

    /// Turns missing-glyph collection on or off (GPUI `enable_missing_glyph_reporting` and its disable).
    /// Turning it off drops the reports not yet taken.
    pub fn set_missing_glyph_reporting(self: *TextSystem, on: bool) void {
        self.missing_glyph_reporting = on;
        if (!on) {
            for (self.missing_glyph_pending.items) |g| self.allocator.free(g.text);
            self.missing_glyph_pending.clearRetainingCapacity();
        }
    }

    /// Takes the missing glyphs reported since the last call (GPUI `MissingGlyphReceiver::recv`, polled).
    /// Each grapheme appears once per font class until `add_fonts`, and at most 1024 are queued before
    /// new ones are dropped. The caller frees the result with `free_missing_glyphs`.
    pub fn take_missing_glyphs(self: *TextSystem) ![]MissingGlyph {
        return self.missing_glyph_pending.toOwnedSlice(self.allocator);
    }

    /// Frees a result of `take_missing_glyphs`.
    pub fn free_missing_glyphs(self: *TextSystem, glyphs: []MissingGlyph) void {
        for (glyphs) |g| self.allocator.free(g.text);
        self.allocator.free(glyphs);
    }

    fn clear_missing_glyph_seen(self: *TextSystem) void {
        var it = self.missing_glyph_seen.keyIterator();
        while (it.next()) |key| self.allocator.free(key.*);
        self.missing_glyph_seen.clearRetainingCapacity();
    }

    /// Queues a report for `text` in `class` unless it was reported before. Allocation failure drops it.
    fn report_missing_glyph(self: *TextSystem, text: []const u8, class: FallbackFontClass) void {
        if (self.missing_glyph_pending.items.len >= MAX_MISSING_GLYPHS) return;
        const key = self.allocator.alloc(u8, 1 + text.len) catch return;
        key[0] = @intFromEnum(class);
        @memcpy(key[1..], text);
        if (self.missing_glyph_seen.contains(key)) {
            self.allocator.free(key);
            return;
        }
        if (self.missing_glyph_seen.count() >= MAX_MISSING_GLYPHS) self.clear_missing_glyph_seen();
        self.missing_glyph_seen.put(self.allocator, key, {}) catch {
            self.allocator.free(key);
            return;
        };
        const copy = self.allocator.dupe(u8, text) catch return;
        self.missing_glyph_pending.append(self.allocator, MissingGlyph.new(copy, class)) catch self.allocator.free(copy);
    }

    /// The spacing class of the face `fid` shapes with (GPUI `fallback_font_class`).
    fn fallback_class(self: *TextSystem, fid: FontId) FallbackFontClass {
        const e = self.entry(fid);
        if (e.face == NO_FACE) return .proportional;
        const info = self.fs.db.face(e.face) orelse return .proportional;
        return if (info.monospaced) .monospace else .proportional;
    }

    /// Reports the graphemes of `text` that have a glyph with id 0 in `result_runs`, which is how cozmic
    /// marks a character no face in the fallback chain can draw.
    fn report_missing_glyphs(self: *TextSystem, text: []const u8, result_runs: []const ShapedRun) void {
        var starts: std.ArrayList(usize) = .empty;
        defer starts.deinit(self.allocator);
        var graphemes = cozmic.unicode.graphemeIndices(text);
        while (graphemes.next()) |start| starts.append(self.allocator, start) catch return;

        for (result_runs) |run| {
            var class: ?FallbackFontClass = null;
            for (run.glyphs) |glyph| {
                if (glyph.id != 0 or glyph.index >= text.len) continue;
                // The grapheme that contains the glyph's byte: the last start at or before it.
                const k = partition_point_usize(starts.items, glyph.index);
                if (k == 0) continue;
                const begin = starts.items[k - 1];
                const end = if (k < starts.items.len) starts.items[k] else text.len;
                if (class == null) class = self.fallback_class(run.font_id);
                self.report_missing_glyph(text[begin..end], class.?);
            }
        }
    }


    pub fn font_id(self: *TextSystem, f: *const Font) !FontId {
        var h = std.hash.Wyhash.init(0);
        f.hash(&h);
        const hv = h.final();
        if (self.font_index.get(hv)) |id| {
            const e = &self.fonts.items[id];
            if (e.key) |k| if (Font.eql(k, f.*)) return id;
        }
        const id = try self.resolve_new(f);
        // A hash collision keeps the existing slot; the new entry is still valid by id.
        const gop = try self.font_index.getOrPut(self.allocator, hv);
        if (!gop.found_existing) gop.value_ptr.* = id;
        return id;
    }

    /// `fid` for callers that cannot handle errors. Only allocation failure reaches the panic.
    pub fn resolve_font(self: *TextSystem, f: *const Font) FontId {
        return self.font_id(f) catch @panic("OOM resolving font");
    }

    /// The font entry for `id`.
    fn entry(self: *TextSystem, id: FontId) *FontEntry {
        return &self.fonts.items[id];
    }

    /// Resolves a new font: the named family, then fallbacks, then a generic family.
    fn resolve_new(self: *TextSystem, f: *const Font) !FontId {
        const allocator = self.allocator;
        const wght: u16 = weight_value(f.weight);
        const cz_style = to_cozmic_style(f.style);
        const wants_mono = is_monospace_name(f.family);

        var face: u32 = NO_FACE;
        var family_kind: cozmic.font_system.FamilyTag = .name;
        var family_name: []const u8 = f.family;

        if (!is_generic_name(f.family)) {
            if (self.query_name(f.family, wght, cz_style)) |id| face = id;
        }
        if (face == NO_FACE) {
            if (f.fallbacks) |fb| {
                for (fb.families) |name| {
                    if (self.query_name(name, wght, cz_style)) |id| {
                        face = id;
                        family_name = name;
                        break;
                    }
                }
            }
        }
        if (face == NO_FACE) {
            // No named family matched: shape with the generic family, and use a known
            // installed family for the face so metrics and rasterization have one.
            family_kind = if (wants_mono) .monospace else .sans_serif;
            family_name = "";
            const candidates: []const []const u8 = if (wants_mono) &MONO_CANDIDATES else &SANS_CANDIDATES;
            for (candidates) |name| {
                if (self.query_name(name, wght, cz_style)) |id| {
                    face = id;
                    family_kind = .name;
                    family_name = name;
                    break;
                }
            }
            if (face == NO_FACE and self.fs.db.faces.items.len > 0) face = self.fs.db.faces.items[0].id;
        }

        // Shaping uses the family name the entry was resolved with.
        const owned_family = try allocator.dupe(u8, if (family_kind == .name) family_name else "");
        errdefer allocator.free(owned_family);
        const owned_features = try allocator.dupe(FontFeature, f.features.features);
        errdefer allocator.free(owned_features);
        const key_family = try allocator.dupe(u8, f.family);
        errdefer allocator.free(key_family);
        const key_features = try allocator.dupe(FontFeature, f.features.features);
        errdefer allocator.free(key_features);

        const e: FontEntry = .{
            .face = face,
            .family_kind = family_kind,
            .family_name = owned_family,
            .weight = wght,
            .style = cz_style,
            .features = owned_features,
            .key = .{
                .family = key_family,
                .features = .{ .features = key_features },
                .fallbacks = null,
                .weight = f.weight,
                .style = f.style,
            },
        };
        try self.fonts.append(allocator, e);
        return @intCast(self.fonts.items.len - 1);
    }

    /// The face for a plain family name (`null` when the database has no such family).
    fn query_name(self: *TextSystem, name: []const u8, wght: u16, cz_style: cozmic.attrs.Style) ?u32 {
        const fam: cozmic.font_system.Family = if (is_generic_name(name))
            .{ .sans_serif = {} }
        else
            .{ .name = name };
        const s: cozmic.font_system.Style = switch (cz_style) {
            .normal => .normal,
            .italic => .italic,
            .oblique => .oblique,
        };
        return self.fs.db.query(fam, wght, .normal, s);
    }

    /// A plain entry for a cozmic face, used for glyphs that fell back to that face.
    fn intern_face(self: *TextSystem, face: u32) !FontId {
        const gop = try self.face_index.getOrPut(self.allocator, face);
        if (gop.found_existing) return gop.value_ptr.*;
        const info = self.fs.db.face(face);
        const name: []const u8 = if (info) |i| (if (i.families.len > 0) i.families[0] else "") else "";
        const owned = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(owned);
        const weight: u16 = if (info) |i| i.weight else 400;
        try self.fonts.append(self.allocator, .{
            .face = face,
            .family_kind = .name,
            .family_name = owned,
            .weight = weight,
        });
        const id: FontId = @intCast(self.fonts.items.len - 1);
        gop.value_ptr.* = id;
        return id;
    }

    /// Every family name in the font database, sorted, without duplicates (GPUI `all_font_names`).
    /// The caller frees the slice; the names belong to the text system and live as long as it does.
    pub fn all_font_names(self: *TextSystem, allocator: Allocator) ![]const []const u8 {
        var names: std.ArrayList([]const u8) = .empty;
        errdefer names.deinit(allocator);
        for (self.fs.db.faces.items) |face| {
            for (face.families) |family| try names.append(allocator, family);
        }
        std.mem.sort([]const u8, names.items, {}, less_than_name);
        var unique: usize = 0;
        for (names.items, 0..) |name, i| {
            if (i == 0 or !std.mem.eql(u8, names.items[unique - 1], name)) {
                names.items[unique] = name;
                unique += 1;
            }
        }
        names.shrinkRetainingCapacity(unique);
        return names.toOwnedSlice(allocator);
    }

    // -- metrics ----------------------------------------------------------

    /// Metrics of `fid`, read from the face the first time and cached.
    pub fn font_metrics(self: *TextSystem, fid: FontId) FontMetrics {
        const e = self.entry(fid);
        if (e.metrics) |m| return m;
        const m = self.compute_metrics(e.face);
        e.metrics = m;
        return m;
    }

    fn compute_metrics(self: *TextSystem, face: u32) FontMetrics {
        var out: FontMetrics = .{};
        if (face == NO_FACE) return out;
        const data = self.face_info(face);
        if (data.metrics) |m| return m;
        if (self.fs.shaper()) |adapter| {
            const sm = adapter.fontMetrics(face);
            const upem: f32 = if (sm.units_per_em > 0) sm.units_per_em else 1000;
            out.units_per_em = @intFromFloat(upem);
            out.ascent_units = sm.ascent * upem;
            out.descent_units = sm.descent * upem;
            if (sm.underline) |d| {
                out.underline_position_units = d.offset;
                out.underline_thickness_units = d.thickness;
            } else {
                out.underline_position_units = -0.1 * upem;
                out.underline_thickness_units = 0.05 * upem;
            }
        }
        if (self.fs.fontBytes(face)) |bytes| {
            const tables = scan_tables(bytes);
            if (tables.head) |h| {
                out.bounding_box_units = h.box;
                out.units_per_em = h.units_per_em;
            }
            // The shaping backend does not report these, so they come from the tables directly.
            if (tables.hhea_line_gap) |gap| out.line_gap_units = gap;
            if (tables.os2) |os2| {
                if (os2.x_height > 0) out.x_height_units = os2.x_height;
                if (os2.cap_height > 0) out.cap_height_units = os2.cap_height;
            }
        }
        if (out.bounding_box_units.size.width <= 0) {
            out.bounding_box_units = .{
                .origin = .{ .x = 0, .y = -out.ascent_units },
                .size = .{ .width = @floatFromInt(out.units_per_em), .height = out.ascent_units + out.descent_units },
            };
        }
        self.face_data_mut(face).metrics = out;
        return out;
    }

    fn face_info(self: *TextSystem, face: u32) FaceData {
        if (self.face_data.get(face)) |d| return d;
        var d: FaceData = .{};
        if (self.fs.fontBytes(face)) |bytes| {
            d.is_color = scan_tables(bytes).color;
        }
        self.face_data.put(self.allocator, face, d) catch {};
        return d;
    }

    fn face_data_mut(self: *TextSystem, face: u32) *FaceData {
        _ = self.face_info(face);
        return self.face_data.getPtr(face).?;
    }

    /// The bounding box of `fid` at `font_size` (GPUI `bounding_box`).
    pub fn bounding_box(self: *TextSystem, fid: FontId, font_size: Pixels) Bounds(Pixels) {
        return self.font_metrics(fid).bounding_box(font_size);
    }

    /// Ascent (distance above the baseline) of `fid` at `font_size`.
    pub fn ascent(self: *TextSystem, fid: FontId, font_size: Pixels) Pixels {
        return self.font_metrics(fid).ascent(font_size);
    }

    /// Descent (distance below the baseline) of `fid` at `font_size`.
    pub fn descent(self: *TextSystem, fid: FontId, font_size: Pixels) Pixels {
        return self.font_metrics(fid).descent(font_size);
    }

    /// The recommended baseline offset from the top of a line `line_height` tall, for `fid` at `font_size`
    /// (GPUI `baseline_offset`).
    pub fn baseline_offset(self: *TextSystem, fid: FontId, font_size: Pixels, line_height: Pixels) Pixels {
        const ascent_px = self.ascent(fid, font_size);
        const descent_px = self.descent(fid, font_size);
        const padding_top = (line_height - ascent_px - descent_px) / 2.0;
        return padding_top + ascent_px;
    }

    /// Units per em of `fid`.
    pub fn units_per_em(self: *TextSystem, fid: FontId) u32 {
        return self.font_metrics(fid).units_per_em;
    }

    /// The height of a capital letter in `fid` at `font_size`.
    pub fn cap_height(self: *TextSystem, fid: FontId, font_size: Pixels) Pixels {
        return self.font_metrics(fid).cap_height(font_size);
    }

    /// The height of a lowercase x in `fid` at `font_size`.
    pub fn x_height(self: *TextSystem, fid: FontId, font_size: Pixels) Pixels {
        return self.font_metrics(fid).x_height(font_size);
    }

    /// The advance of `ch` in `fid` at `font_size`, as a size whose height is 0 (horizontal text).
    /// Fails when the font has no glyph for `ch` (GPUI `advance`).
    pub fn advance(self: *TextSystem, fid: FontId, font_size: Pixels, ch: u21) !Size(Pixels) {
        const e = self.entry(fid);
        if (e.face == NO_FACE) return error.GlyphNotFound;
        const adapter = self.fs.shaper() orelse return error.GlyphNotFound;
        const gid = adapter.mapGlyph(e.face, ch);
        if (gid == 0) return error.GlyphNotFound;
        return .{ .width = adapter.advanceEm(e.face, gid) * font_size, .height = 0 };
    }

    /// The typographic bounds of `ch` in `fid` at `font_size` (GPUI `typographic_bounds`): the origin is
    /// 0 and the size is the advance. The cosmic backend does not measure glyph ink, so this is the same
    /// box GPUI's cosmic backend reports. Fails when the font has no glyph for `ch`.
    pub fn typographic_bounds(self: *TextSystem, fid: FontId, font_size: Pixels, ch: u21) !Bounds(Pixels) {
        return .{ .origin = .{ .x = 0, .y = 0 }, .size = try self.advance(fid, font_size, ch) };
    }

    /// Width of `m` in `fid` at `font_size`: the width of `m`'s typographic bounds (GPUI `em_width`).
    pub fn em_width(self: *TextSystem, fid: FontId, font_size: Pixels) !Pixels {
        return (try self.typographic_bounds(fid, font_size, 'm')).size.width;
    }

    /// Advance of `m` (GPUI `em_advance`).
    pub fn em_advance(self: *TextSystem, fid: FontId, font_size: Pixels) !Pixels {
        return (try self.advance(fid, font_size, 'm')).width;
    }

    /// Width of `0` (GPUI `ch_width`).
    pub fn ch_width(self: *TextSystem, fid: FontId, font_size: Pixels) !Pixels {
        return (try self.typographic_bounds(fid, font_size, '0')).size.width;
    }

    /// Advance of `0` (GPUI `ch_advance`).
    pub fn ch_advance(self: *TextSystem, fid: FontId, font_size: Pixels) !Pixels {
        return (try self.advance(fid, font_size, '0')).width;
    }

    /// The font `fid` was resolved from, or null for a fallback face that no request names (GPUI `get_font_for_id`).
    /// The result's strings belong to the text system.
    pub fn get_font_for_id(self: *TextSystem, fid: FontId) ?Font {
        if (fid >= self.fonts.items.len) return null;
        return self.fonts.items[fid].key;
    }

    /// Resolves each font now, so that the first text shaped with it does not pay for the lookup (GPUI
    /// `prewarm_fonts`). Cozmic loads a face's data on first use, so this only fills the font table.
    pub fn prewarm_fonts(self: *TextSystem, fonts: []const Font) void {
        for (fonts) |*f| _ = self.resolve_font(f);
    }

    /// Shaped width of one character, from the line cache (0 when no font can shape it).
    pub fn layout_width(self: *TextSystem, fid: FontId, font_size: Pixels, ch: u21) Pixels {
        var buf: [4]u8 = undefined;
        const n = std.unicode.utf8Encode(ch, &buf) catch return 0;
        const runs = [_]FontRun{.{ .len = n, .font_id = fid }};
        const layout = self.active_cache.layout_line(buf[0..n], font_size, &runs, null) catch return 0;
        return layout.width;
    }

    /// Shaped width of an `m` in `fid` at `font_size` (GPUI `em_layout_width`).
    pub fn em_layout_width(self: *TextSystem, fid: FontId, font_size: Pixels) Pixels {
        return self.layout_width(fid, font_size, 'm');
    }

    // -- shaping ------------------------------------------------------------

    /// Shapes `text` as one line, with each run's font (GPUI `layout_line`), through the cache.
    pub fn layout_line(self: *TextSystem, text: []const u8, font_size: Pixels, runs: []const FontRun, force_width: ?Pixels) !*const LineLayout {
        return self.active_cache.layout_line(text, font_size, runs, force_width);
    }

    /// Shapes `text` as one line, styled by `runs` (GPUI `shape_line`). `text` must not contain newlines.
    pub fn shape_line(self: *TextSystem, text: []const u8, font_size: Pixels, runs: []const TextRun, force_width: ?Pixels) !ShapedLine {
        std.debug.assert(std.mem.indexOfScalar(u8, text, '\n') == null);
        const arena = window_mod.frame_arena();
        var decorations: std.ArrayList(DecorationRun) = .empty;
        for (runs) |run| {
            if (decorations.items.len > 0) {
                const last = &decorations.items[decorations.items.len - 1];
                if (decoration_eql(last, run)) {
                    last.len += @intCast(run.len);
                    continue;
                }
            }
            try decorations.append(arena, decoration_of(run));
        }

        try self.build_font_runs(runs);
        try self.apply_text_presentation(text, &self.font_runs_scratch);
        const layout = try self.active_cache.layout_line(text, font_size, self.font_runs_scratch.items, force_width);
        return .{ .layout = layout, .text = layout.text, .decoration_runs = decorations.items };
    }

    /// Shapes a possibly multi-line string, wrapping at `wrap_width` (GPUI `shape_text`).
    /// The result is allocated in the frame arena. Lines are split on `\n`.
    pub fn shape_text(self: *TextSystem, text: []const u8, font_size: Pixels, runs: []const TextRun, wrap_width: ?Pixels, line_clamp: ?usize) ![]WrappedLine {
        const arena = window_mod.frame_arena();
        // Working copy of the runs; the lengths are consumed as lines are carved out.
        var remaining: std.ArrayList(TextRun) = .empty;
        for (runs) |run| if (run.len > 0) try remaining.append(arena, run);
        var run_ix: usize = 0;

        var lines: std.ArrayList(WrappedLine) = .empty;
        var wrapped_lines: usize = 0;

        var line_start: usize = 0;
        var split = std.mem.splitScalar(u8, text, '\n');
        while (split.next()) |line_text| {
            const line_end = line_start + line_text.len;
            var decorations: std.ArrayList(DecorationRun) = .empty;
            self.font_runs_scratch.clearRetainingCapacity();

            var run_start = line_start;
            while (run_start < line_end) {
                if (run_ix >= remaining.items.len) break;
                const run = &remaining.items[run_ix];
                const len_within_line = @min(line_end - run_start, run.len);

                var decoration_changed = true;
                if (decorations.items.len > 0) {
                    const last = &decorations.items[decorations.items.len - 1];
                    if (decoration_eql(last, run.*)) {
                        last.len += @intCast(len_within_line);
                        decoration_changed = false;
                    }
                }
                if (decoration_changed) {
                    var d = decoration_of(run.*);
                    d.len = @intCast(len_within_line);
                    try decorations.append(arena, d);
                }

                const fid = self.resolve_font(&run.font);
                if (self.font_runs_scratch.items.len > 0) {
                    const last = &self.font_runs_scratch.items[self.font_runs_scratch.items.len - 1];
                    if (last.font_id == fid and !decoration_changed) {
                        last.len += len_within_line;
                    } else {
                        try self.font_runs_scratch.append(self.allocator, .{ .len = len_within_line, .font_id = fid });
                    }
                } else {
                    try self.font_runs_scratch.append(self.allocator, .{ .len = len_within_line, .font_id = fid });
                }

                run.len -= len_within_line;
                if (run.len == 0) run_ix += 1;
                run_start += len_within_line;
            }

            try self.apply_text_presentation(line_text, &self.font_runs_scratch);
            const max_lines: ?usize = if (line_clamp) |max| max -| wrapped_lines else null;
            const layout = try self.active_cache.layout_wrapped_line(line_text, font_size, self.font_runs_scratch.items, wrap_width, max_lines);
            wrapped_lines += layout.wrap_boundaries().len;
            try lines.append(arena, .{ .layout = layout, .text = layout.unwrapped_layout.text, .decoration_runs = decorations.items });

            // Skip the `\n` that ends this line.
            if (run_ix < remaining.items.len) {
                const run = &remaining.items[run_ix];
                run.len -= 1;
                if (run.len == 0) run_ix += 1;
            }
            line_start = line_end + 1;
        }
        return lines.items;
    }

    /// Converts `runs` into `font_runs_scratch`, merging runs that share a font and decorations.
    fn build_font_runs(self: *TextSystem, runs: []const TextRun) !void {
        self.font_runs_scratch.clearRetainingCapacity();
        var last_run: ?TextRun = null;
        for (runs) |run| {
            var decoration_changed = true;
            if (last_run) |lr| {
                if (std.meta.eql(lr.color, run.color) and std.meta.eql(lr.underline, run.underline) and std.meta.eql(lr.strikethrough, run.strikethrough)) {
                    decoration_changed = false;
                }
            }
            if (decoration_changed) last_run = run;

            const fid = self.resolve_font(&run.font);
            if (self.font_runs_scratch.items.len > 0) {
                const last = &self.font_runs_scratch.items[self.font_runs_scratch.items.len - 1];
                if (last.font_id == fid and !decoration_changed) {
                    last.len += run.len;
                    continue;
                }
            }
            try self.font_runs_scratch.append(self.allocator, .{ .len = run.len, .font_id = fid });
        }
    }

    /// Text presentation. A character followed by U+FE0E (VARIATION SELECTOR-15) asks for its text form, but
    /// font fallback ignores selectors: for U+2764 and similar it takes the color emoji face first, so the
    /// heart came out in color. Such a character is moved to a face that is not a color face and covers it.
    /// Its run's font is kept when that face already covers it, and every other character keeps its font.
    fn apply_text_presentation(self: *TextSystem, text: []const u8, runs: *std.ArrayList(FontRun)) !void {
        const selector = "\u{fe0e}";
        var overrides: std.ArrayList(FontRunOverride) = .empty;
        defer overrides.deinit(self.allocator);
        var at: usize = 0;
        while (std.mem.indexOfPos(u8, text, at, selector)) |sel| {
            at = sel + selector.len;
            if (sel == 0) continue;
            const base_start = prev_char_start(text, sel);
            const cp = std.unicode.utf8Decode(text[base_start..sel]) catch continue;
            if (cp >= 0xFE00 and cp <= 0xFE0F) continue; // another selector, not a base character
            const run_font = font_at(runs.items, base_start) orelse continue;
            const fid = (try self.text_presentation_font(run_font, cp)) orelse continue;
            if (fid == run_font) continue;
            try overrides.append(self.allocator, .{ .start = base_start, .end = sel + selector.len, .font_id = fid });
        }
        if (overrides.items.len == 0) return;

        // Rebuild the runs with each override cut out of the run it falls in.
        var out: std.ArrayList(FontRun) = .empty;
        errdefer out.deinit(self.allocator);
        var ov: usize = 0;
        var run_start: usize = 0;
        for (runs.items) |run| {
            const run_end = run_start + run.len;
            var p = run_start;
            while (p < run_end) {
                while (ov < overrides.items.len and overrides.items[ov].end <= p) ov += 1;
                var piece_end: usize = run_end;
                var piece_font: FontId = run.font_id;
                if (ov < overrides.items.len and overrides.items[ov].start <= p) {
                    piece_end = @min(overrides.items[ov].end, run_end);
                    piece_font = overrides.items[ov].font_id;
                } else if (ov < overrides.items.len) {
                    piece_end = @min(overrides.items[ov].start, run_end);
                }
                try append_font_run(self.allocator, &out, piece_end - p, piece_font);
                p = piece_end;
            }
            run_start = run_end;
        }
        runs.deinit(self.allocator);
        runs.* = out;
    }

    /// The face for `cp` in text presentation, as an entry of its own: `run_font` when it is a non-color
    /// face that covers `cp`, else the first non-color face that does (preferring the run's weight).
    /// Null when no face covers it. Answers are cached per character.
    fn text_presentation_font(self: *TextSystem, run_font: FontId, cp: u21) !?FontId {
        const adapter = self.fs.shaper() orelse return null;
        const e = self.entry(run_font);
        if (e.face != NO_FACE and !self.face_info(e.face).is_color and adapter.mapGlyph(e.face, cp) != 0) return run_font;
        if (self.presentation_faces.get(cp)) |cached| return if (cached == NO_FONT) null else cached;

        // Among the covering faces, prefer the run's weight, then the run's spacing (a proportional run keeps
        // a proportional face). Faces named after emoji are skipped even when they are not color faces.
        const run_monospaced = if (e.face != NO_FACE) if (self.fs.db.face(e.face)) |info| info.monospaced else false else false;
        var chosen: ?u32 = null;
        var best: u8 = 0;
        for (self.fs.db.faces.items) |face| {
            if (self.face_info(face.id).is_color) continue;
            if (face.families.len > 0 and ascii_contains_ci(face.families[0], "emoji")) continue;
            if (adapter.mapGlyph(face.id, cp) == 0) continue;
            const score: u8 = (if (face.weight == e.weight) @as(u8, 2) else 0) + (if (face.monospaced == run_monospaced) @as(u8, 1) else 0);
            if (chosen == null or score > best) {
                chosen = face.id;
                best = score;
            }
            if (best == 3) break;
        }
        const fid: FontId = if (chosen) |face| try self.intern_face(face) else NO_FONT;
        try self.presentation_faces.put(self.allocator, cp, fid);
        return if (fid == NO_FONT) null else fid;
    }

    /// A `LineWrapper` for `font` at `font_size`, sharing this text system's width cache.
    pub fn line_wrapper(self: *TextSystem, f: Font, font_size: Pixels) LineWrapper {
        const id = self.resolve_font(&f);
        const key: WidthKey = .{ .font_id = id, .size_bits = @bitCast(font_size) };
        const gop = self.char_widths.getOrPut(self.allocator, key) catch @panic("OOM");
        if (!gop.found_existing) {
            const cache = self.allocator.create(lw_mod.CharWidthCache) catch @panic("OOM");
            cache.* = .{};
            gop.value_ptr.* = cache;
        }
        return LineWrapper.init(self.allocator, id, font_size, .{ .ctx = self, .width_fn = width_callback }, gop.value_ptr.*);
    }

    fn width_callback(ctx: *anyopaque, fid: u32, font_size: Pixels, ch: u21) Pixels {
        const self: *TextSystem = @ptrCast(@alignCast(ctx));
        return self.layout_width(fid, font_size, ch);
    }

    /// Ends the frame: frees layouts that were not used in it or the previous one.
    pub fn finish_frame(self: *TextSystem) void {
        self.layout_cache.finish_frame();
    }

    /// A cache that shapes with this text system, for a window to own.
    pub fn new_layout_cache(self: *TextSystem) LineLayoutCache {
        return LineLayoutCache.init(self.allocator, .{ .ctx = self, .shape_fn = shape_for_cache });
    }

    // -- shaping backend -----------------------------------------------------

    fn shape_for_cache(ctx: *anyopaque, allocator: Allocator, text: []const u8, font_size: Pixels, runs: []const FontRun, force_width: ?Pixels) anyerror!LineLayout {
        _ = force_width;
        const self: *TextSystem = @ptrCast(@alignCast(ctx));
        return self.shape(allocator, text, font_size, runs);
    }

    /// Shapes `text` with cozmic: one attribute span per run, no cozmic wrapping.
    fn shape(self: *TextSystem, allocator: Allocator, text: []const u8, font_size: Pixels, runs: []const FontRun) !LineLayout {
        const adapter = self.fs.shaper() orelse return self.empty_layout(allocator, font_size, text, runs);

        var defaults = cozmic.attrs.Attrs.init(allocator);
        defer defaults.deinit();
        var list = try cozmic.attrs.AttrsList.init(allocator, &defaults);
        defer list.deinit();
        var offset: usize = 0;
        for (runs) |run| {
            if (run.len == 0) continue;
            const e = self.entry(run.font_id);
            var a = cozmic.attrs.Attrs.init(allocator);
            defer a.deinit();
            a.family = switch (e.family_kind) {
                .name => .{ .name = e.family_name },
                .serif => .serif,
                .sans_serif => .sans_serif,
                .cursive => .cursive,
                .fantasy => .fantasy,
                .monospace => .monospace,
            };
            _ = a.with_weight(.{ .value = e.weight }).with_style(e.style);
            for (e.features) |feature| {
                _ = try a.font_features.set(cozmic.attrs.FeatureTag.new(&feature.tag), feature.value);
            }
            try list.add_span(offset, offset + run.len, &a);
            offset += run.len;
        }

        var shaped: cozmic.shape.ShapeLine = .{};
        defer shaped.deinit(allocator);
        var scratch = cozmic.shape.ShapeBuffer.init();
        defer scratch.deinit(allocator);
        try shaped.build(allocator, adapter, &scratch, text, &list, .advanced, 4, .auto);

        var out: std.ArrayList(cozmic.layout.LayoutLine) = .empty;
        defer {
            for (out.items) |*l| l.deinit();
            out.deinit(allocator);
        }
        try shaped.layoutToBuffer(allocator, &scratch, font_size, null, .none, .{ .none = {} }, null, &out, null, .disabled);

        var result_runs: std.ArrayList(ShapedRun) = .empty;
        errdefer {
            for (result_runs.items) |run| allocator.free(run.glyphs);
            result_runs.deinit(allocator);
        }
        var glyphs: std.ArrayList(ShapedGlyph) = .empty;
        errdefer glyphs.deinit(allocator);

        var asc: Pixels = 0;
        var desc: Pixels = 0;
        var width: Pixels = 0;
        var cur_face: u32 = NO_FACE;
        var cur_font: FontId = 0;
        var have_run = false;

        for (out.items) |*ll| {
            asc = @max(asc, ll.max_ascent);
            desc = @max(desc, ll.max_descent);
            width = @max(width, ll.w);
            for (ll.glyphs.items) |g| {
                if (!have_run or g.font_id != cur_face) {
                    if (have_run) {
                        try result_runs.append(allocator, .{ .font_id = cur_font, .glyphs = try glyphs.toOwnedSlice(allocator) });
                        glyphs = .empty;
                    }
                    cur_face = g.font_id;
                    cur_font = try self.font_for_glyph(g.font_id, g.start, runs);
                    have_run = true;
                }
                const face_data = self.face_info(g.font_id);
                try glyphs.append(allocator, .{
                    .id = g.glyph_id,
                    .position = .{ .x = g.x + font_size * g.x_offset, .y = g.y - font_size * g.y_offset },
                    .index = g.start,
                    .is_emoji = face_data.is_color,
                });
            }
        }
        if (have_run) try result_runs.append(allocator, .{ .font_id = cur_font, .glyphs = try glyphs.toOwnedSlice(allocator) });
        if (self.missing_glyph_reporting) self.report_missing_glyphs(text, result_runs.items);

        if (asc == 0 and desc == 0 and runs.len > 0) {
            asc = self.ascent(runs[0].font_id, font_size);
            desc = self.descent(runs[0].font_id, font_size);
        }
        return .{
            .font_size = font_size,
            .width = width,
            .ascent = asc,
            .descent = desc,
            .runs = try result_runs.toOwnedSlice(allocator),
            .len = text.len,
        };
    }

    /// The layout used when no shaper is available: zero width, font-derived metrics.
    fn empty_layout(self: *TextSystem, allocator: Allocator, font_size: Pixels, text: []const u8, runs: []const FontRun) !LineLayout {
        var asc: Pixels = font_size * 0.8;
        var desc: Pixels = font_size * 0.2;
        if (runs.len > 0) {
            asc = self.ascent(runs[0].font_id, font_size);
            desc = self.descent(runs[0].font_id, font_size);
        }
        return .{
            .font_size = font_size,
            .width = 0,
            .ascent = asc,
            .descent = desc,
            .runs = try allocator.alloc(ShapedRun, 0),
            .len = text.len,
        };
    }

    /// The font id for glyphs of cozmic `face` at byte `index`: the requested run's id when the
    /// face matches it, otherwise an interned entry for the fallback face.
    fn font_for_glyph(self: *TextSystem, face: u32, index: usize, runs: []const FontRun) !FontId {
        var offset: usize = 0;
        for (runs) |run| {
            if (index < offset + run.len) {
                if (self.entry(run.font_id).face == face) return run.font_id;
                break;
            }
            offset += run.len;
        }
        return self.intern_face(face);
    }

    // -- glyph rasterization ---------------------------------------------------

    /// The swash image of a glyph at its scaled size, or null when it has no bitmap.
    fn glyph_image(self: *TextSystem, params: *const RenderGlyphParams) !?cozmic.swash_cache.SwashImageView {
        if (self.swash == null) return null;
        const swash = &self.swash.?;
        const e = self.entry(params.font_id);
        if (e.face == NO_FACE or params.glyph_id > std.math.maxInt(u16)) return null;
        const size = params.font_size * params.scale_factor;
        const key: cozmic.glyph_cache.CacheKey = .{
            .font_id = e.face,
            .glyph_id = @intCast(params.glyph_id),
            .font_size_bits = @bitCast(size),
            .x_bin = @enumFromInt(@min(params.subpixel_variant.x, 3)),
            .y_bin = @enumFromInt(@min(params.subpixel_variant.y, 3)),
            .font_weight = e.weight,
            .flags = .{},
        };
        return swash.getImage(key);
    }

    /// Bounds of the rasterized glyph, relative to the glyph origin (y down). Cached per params.
    pub fn raster_bounds(self: *TextSystem, params: *const RenderGlyphParams) !Bounds(DevicePixels) {
        const key = RasterKey.from(params);
        if (self.raster_bounds_cache.get(key)) |b| return b;
        var out: Bounds(DevicePixels) = .{ .origin = .{ .x = 0, .y = 0 }, .size = .{ .width = 0, .height = 0 } };
        if (try self.glyph_image(params)) |img| {
            out = .{
                .origin = .{ .x = img.placement.left, .y = -img.placement.top },
                .size = .{ .width = @intCast(img.placement.width), .height = @intCast(img.placement.height) },
            };
        }
        self.raster_bounds_cache.put(self.allocator, key, out) catch {};
        return out;
    }

    /// Rasterizes a glyph into bytes (A8 for monochrome, premultiplied RGBA for color), in the frame arena.
    pub fn rasterize_glyph(self: *TextSystem, params: *const RenderGlyphParams) !RasterizedGlyph {
        const tile = (try self.build_glyph_tile(params)) orelse return .{ .size = .{ .width = 0, .height = 0 }, .bytes = &.{} };
        const bytes = try window_mod.frame_arena().dupe(u8, tile.bytes);
        return .{ .size = tile.size, .bytes = bytes };
    }

    /// A `TileBuilder` that rasterizes `params` when the atlas needs it. The builder is
    /// used synchronously, so it references a copy of `params` held by the text system.
    pub fn tile_builder(self: *TextSystem, params: *const RenderGlyphParams) atlas.TileBuilder {
        self.tile_job = .{ .ts = self, .params = params.* };
        return .{ .context = &self.tile_job, .build_fn = build_tile };
    }

    fn build_tile(context: *anyopaque) anyerror!?atlas.TileData {
        const job: *TileJob = @ptrCast(@alignCast(context));
        const tile = (try job.ts.build_glyph_tile(&job.params)) orelse return null;
        return tile;
    }

    /// Converts the swash image of `params` into atlas bytes, in `tile_bytes`.
    fn build_glyph_tile(self: *TextSystem, params: *const RenderGlyphParams) !?atlas.TileData {
        const rb = try self.raster_bounds(params);
        if (rb.size.width <= 0 or rb.size.height <= 0) return null;
        const view = (try self.glyph_image(params)) orelse return null;
        const w: usize = view.placement.width;
        const h: usize = view.placement.height;
        const pixels = w * h;
        const allocator = self.allocator;

        self.tile_bytes.clearRetainingCapacity();
        if (params.is_emoji) {
            try self.tile_bytes.resize(allocator, pixels * 4);
            const out = self.tile_bytes.items;
            switch (view.content) {
                .color => {
                    if (view.data.len < pixels * 4) return null;
                    for (0..pixels) |i| {
                        const a: u32 = view.data[i * 4 + 3];
                        for (0..3) |c| {
                            out[i * 4 + c] = @intCast((@as(u32, view.data[i * 4 + c]) * a + 127) / 255);
                        }
                        out[i * 4 + 3] = @intCast(a);
                    }
                },
                .mask, .subpixel_mask => {
                    // A coverage mask has no color; premultiplied white with that alpha.
                    if (view.data.len < pixels) return null;
                    for (0..pixels) |i| {
                        const a = view.data[i];
                        out[i * 4 + 0] = a;
                        out[i * 4 + 1] = a;
                        out[i * 4 + 2] = a;
                        out[i * 4 + 3] = a;
                    }
                },
            }
        } else {
            try self.tile_bytes.resize(allocator, pixels);
            const out = self.tile_bytes.items;
            switch (view.content) {
                .mask => {
                    if (view.data.len < pixels) return null;
                    @memcpy(out, view.data[0..pixels]);
                },
                .subpixel_mask => {
                    // Average the color channels into one coverage value.
                    if (view.data.len < pixels * 3) return null;
                    for (0..pixels) |i| {
                        const sum: u32 = @as(u32, view.data[i * 3]) + view.data[i * 3 + 1] + view.data[i * 3 + 2];
                        out[i] = @intCast(sum / 3);
                    }
                },
                .color => {
                    if (view.data.len < pixels * 4) return null;
                    for (0..pixels) |i| out[i] = view.data[i * 4 + 3];
                },
            }
        }
        return .{
            .size = .{ .width = @intCast(w), .height = @intCast(h) },
            .bytes = self.tile_bytes.items,
        };
    }
};

// ---------------------------------------------------------------------------
// Helpers.

fn weight_value(w: FontWeight) u16 {
    const v = std.math.clamp(@round(w.value), 1, 1000);
    return @intFromFloat(v);
}

fn to_cozmic_style(s: FontStyle) cozmic.attrs.Style {
    return switch (s) {
        .normal => .normal,
        .italic => .italic,
        .oblique => .oblique,
    };
}

/// Generic and platform aliases that mean the system UI font.
fn is_generic_name(name: []const u8) bool {
    const generic = [_][]const u8{ ".SystemUIFont", ".ZedSans", ".ZedMono", "sans-serif", "system-ui", "monospace", "Zed Plex Sans", "IBM Plex Sans" };
    for (generic) |g| if (std.mem.eql(u8, name, g)) return true;
    return false;
}

fn is_monospace_name(name: []const u8) bool {
    if (std.mem.eql(u8, name, ".ZedMono") or std.mem.eql(u8, name, "monospace")) return true;
    var buf: [64]u8 = undefined;
    if (name.len > buf.len) return false;
    const lower = std.ascii.lowerString(buf[0..name.len], name);
    return std.mem.indexOf(u8, lower, "mono") != null;
}

fn decoration_of(run: TextRun) DecorationRun {
    return .{
        .len = @intCast(run.len),
        .color = run.color,
        .background_color = run.background_color,
        .underline = run.underline,
        .strikethrough = run.strikethrough,
    };
}

fn decoration_eql(d: *const DecorationRun, run: TextRun) bool {
    return std.meta.eql(d.color, run.color) and
        std.meta.eql(d.background_color, run.background_color) and
        std.meta.eql(d.underline, run.underline) and
        std.meta.eql(d.strikethrough, run.strikethrough);
}

/// Values read from a font file's tables.
const TableScan = struct {
    head: ?struct { box: Bounds(f32), units_per_em: u32 } = null,
    /// `hhea` lineGap, in font units.
    hhea_line_gap: ?f32 = null,
    /// `OS/2` heights in font units, for version 2 tables and later.
    os2: ?struct { x_height: f32, cap_height: f32 } = null,
    color: bool = false,
};

/// Reads the `head`, `hhea` and `OS/2` tables and detects color-glyph tables in an sfnt (or the first
/// face of a TTC).
fn scan_tables(bytes: []const u8) TableScan {
    var out: TableScan = .{};
    if (bytes.len < 12) return out;
    var dir: usize = 0;
    if (std.mem.eql(u8, bytes[0..4], "ttcf")) {
        dir = be32(bytes, 12) orelse return out;
    }
    const num_tables = be16(bytes, dir + 4) orelse return out;
    var i: usize = 0;
    while (i < num_tables) : (i += 1) {
        const rec = dir + 12 + i * 16;
        if (rec + 16 > bytes.len) break;
        const tag = bytes[rec .. rec + 4];
        const off = be32(bytes, rec + 8) orelse break;
        const len = be32(bytes, rec + 12) orelse break;
        if (std.mem.eql(u8, tag, "CBDT") or std.mem.eql(u8, tag, "sbix") or std.mem.eql(u8, tag, "COLR") or std.mem.eql(u8, tag, "SVG ")) {
            out.color = true;
        } else if (std.mem.eql(u8, tag, "head") and off + 54 <= bytes.len and len >= 54) {
            const upem = be16(bytes, off + 18) orelse continue;
            const x_min: f32 = @floatFromInt(be16s(bytes, off + 36));
            const y_min: f32 = @floatFromInt(be16s(bytes, off + 38));
            const x_max: f32 = @floatFromInt(be16s(bytes, off + 40));
            const y_max: f32 = @floatFromInt(be16s(bytes, off + 42));
            out.head = .{
                .units_per_em = upem,
                .box = .{ .origin = .{ .x = x_min, .y = -y_max }, .size = .{ .width = x_max - x_min, .height = y_max - y_min } },
            };
        } else if (std.mem.eql(u8, tag, "hhea") and off + 10 <= bytes.len) {
            // version(4), ascender(2), descender(2), lineGap(2)
            out.hhea_line_gap = @floatFromInt(be16s(bytes, off + 8));
        } else if (std.mem.eql(u8, tag, "OS/2") and off + 90 <= bytes.len) {
            // sxHeight is at 86 and sCapHeight at 88, both from version 2 on.
            const version = be16(bytes, off) orelse continue;
            if (version >= 2) out.os2 = .{
                .x_height = @floatFromInt(be16s(bytes, off + 86)),
                .cap_height = @floatFromInt(be16s(bytes, off + 88)),
            };
        }
    }
    return out;
}

fn be16(b: []const u8, at: usize) ?u16 {
    if (at + 2 > b.len) return null;
    return std.mem.readInt(u16, b[at..][0..2], .big);
}

fn be16s(b: []const u8, at: usize) i16 {
    if (at + 2 > b.len) return 0;
    return std.mem.readInt(i16, b[at..][0..2], .big);
}

fn be32(b: []const u8, at: usize) ?usize {
    if (at + 4 > b.len) return null;
    return std.mem.readInt(u32, b[at..][0..4], .big);
}

// ---------------------------------------------------------------------------
// Tests. They need a font: when the host has none, they check the zero-width path instead.

const testing = std.testing;

fn less_than_name(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

test "all_font_names is sorted and has no duplicates" {
    const ts = try TextSystem.create(testing.allocator);
    defer ts.destroy();
    const names = try ts.all_font_names(testing.allocator);
    defer testing.allocator.free(names);
    try testing.expect(names.len > 0);
    for (names[1..], names[0 .. names.len - 1]) |next, prev| {
        try testing.expect(std.mem.lessThan(u8, prev, next));
    }
}

test "text system creates, resolves and shapes without crashing" {
    const ts = try TextSystem.create(testing.allocator);
    defer ts.destroy();

    const f = font(".SystemUIFont");
    const id = try ts.font_id(&f);
    const again = try ts.font_id(&f);
    try testing.expectEqual(id, again);

    const runs = [_]TextRun{.{ .len = 5, .font = f, .color = .{ .h = 0, .s = 0, .l = 0, .a = 1 } }};
    const shaped = try ts.shape_line("Hello", 16, &runs, null);
    try testing.expectEqual(@as(usize, 5), shaped.len());
    if (ts.fs.hasShaper() and ts.fs.fontIds().len > 0) {
        try testing.expect(shaped.width() > 0);
        try testing.expect(shaped.layout.runs.len > 0);
        try testing.expect(ts.ascent(id, 16) > 0);
    } else {
        try testing.expectEqual(@as(f32, 0), shaped.width());
    }
    ts.finish_frame();
}

test "resolve_font maps unknown names to a generic family without failing" {
    const ts = try TextSystem.create(testing.allocator);
    defer ts.destroy();
    const a = try ts.font_id(&font("Zed Plex Sans"));
    const b = try ts.font_id(&font("A Family That Does Not Exist"));
    _ = a;
    _ = b;
}

test "text_system shape_text splits lines on newlines" {
    const ts = try TextSystem.create(testing.allocator);
    defer ts.destroy();
    const f = font(".SystemUIFont");
    const runs = [_]TextRun{.{ .len = 7, .font = f, .color = .{ .h = 0, .s = 0, .l = 0, .a = 1 } }};
    // The frame arena is the window's; these tests run outside a frame, so it uses its fallback.
    const lines = try ts.shape_text("ab\ncde", 16, &runs, null, null);
    try testing.expectEqual(@as(usize, 2), lines.len);
    try testing.expectEqualStrings("ab", lines[0].text);
    try testing.expectEqualStrings("cde", lines[1].text);
    ts.finish_frame();
}

test "atlas key depends on every render parameter" {
    const base: RenderGlyphParams = .{ .font_id = 1, .glyph_id = 2, .font_size = 16, .subpixel_variant = .{ .x = 0, .y = 0 }, .scale_factor = 1, .is_emoji = false };
    var other = base;
    other.subpixel_variant.x = 1;
    const a = base.atlas_key().glyph;
    const b = other.atlas_key().glyph;
    try testing.expect(a.id != b.id);
    try testing.expectEqual(atlas.AtlasTextureKind.monochrome, a.texture_kind);
    var emoji = base;
    emoji.is_emoji = true;
    try testing.expectEqual(atlas.AtlasTextureKind.polychrome, emoji.atlas_key().glyph.texture_kind);
}

test "no-font layout is zero width with font-derived metrics" {
    const ts = try TextSystem.create(testing.allocator);
    defer ts.destroy();
    const f = font(".SystemUIFont");
    const id = try ts.font_id(&f);
    const runs = [_]FontRun{.{ .len = 3, .font_id = id }};
    var l = try ts.empty_layout(testing.allocator, 16, "abc", &runs);
    defer l.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 3), l.len);
    try testing.expectEqual(@as(f32, 0), l.width);
    try testing.expect(l.ascent > 0);
}

test "glyphs shape and rasterize with a real font" {
    const ts = try TextSystem.create(testing.allocator);
    defer ts.destroy();
    if (!ts.fs.hasShaper() or ts.swash == null or ts.fs.fontIds().len == 0) return error.SkipZigTest;

    const f = font(".SystemUIFont");
    const id = try ts.font_id(&f);
    const runs = [_]FontRun{.{ .len = 1, .font_id = id }};
    const layout = try ts.layout_line("H", 16, &runs, null);
    try testing.expect(layout.width > 0);
    const glyph = layout.runs[0].glyphs[0];
    var params: RenderGlyphParams = .{
        .font_id = layout.runs[0].font_id,
        .glyph_id = glyph.id,
        .font_size = 16,
        .subpixel_variant = .{ .x = 0, .y = 0 },
        .scale_factor = 1,
        .is_emoji = false,
    };
    const rb = try ts.raster_bounds(&params);
    try testing.expect(rb.size.width > 0 and rb.size.height > 0);
    // Cached: a second query returns the same bounds.
    try testing.expectEqual(rb, try ts.raster_bounds(&params));

    const raster = try ts.rasterize_glyph(&params);
    try testing.expectEqual(@as(usize, @intCast(rb.size.width * rb.size.height)), raster.bytes.len);
    var any_ink = false;
    for (raster.bytes) |b| any_ink = any_ink or b != 0;
    try testing.expect(any_ink);

    // The atlas path builds the same bytes.
    var builder = ts.tile_builder(&params);
    const tile = (try builder.build()).?;
    try testing.expectEqual(raster.size, tile.size);
    try testing.expectEqualSlices(u8, raster.bytes, tile.bytes);
}

test "shape_text wraps long text at the given width" {
    const ts = try TextSystem.create(testing.allocator);
    defer ts.destroy();
    if (!ts.fs.hasShaper() or ts.fs.fontIds().len == 0) return error.SkipZigTest;
    const f = font(".SystemUIFont");
    const text = "alpha beta gamma delta epsilon zeta eta theta";
    const runs = [_]TextRun{.{ .len = text.len, .font = f, .color = .{ .h = 0, .s = 0, .l = 0, .a = 1 } }};
    const lines = try ts.shape_text(text, 16, &runs, 80, null);
    try testing.expectEqual(@as(usize, 1), lines.len);
    try testing.expect(lines[0].wrap_count() > 1);
    const unwrapped = try ts.shape_text(text, 16, &runs, null, null);
    try testing.expectEqual(@as(usize, 1), unwrapped[0].wrap_count());
    try testing.expect(unwrapped[0].size(20).width > 80);
    ts.finish_frame();
}

test "underline offset sits below the baseline" {
    const off = underline_y_offset(20, 15, 4);
    try testing.expect(off > 15);
}

test "add_fonts: a font from memory resolves by family name, shapes and rasterizes" {
    const ts = try TextSystem.create(testing.allocator);
    defer ts.destroy();
    const io = testing.io;
    // cozmic's test font, from the fetched package. Absent if packages live elsewhere.
    var pkg = std.Io.Dir.cwd().openDir(io, "zig-pkg", .{ .iterate = true }) catch return error.SkipZigTest;
    defer pkg.close(io);
    var bytes: ?[]u8 = null;
    defer if (bytes) |b| testing.allocator.free(b);
    var it = pkg.iterate();
    while (try it.next(io)) |entry| {
        if (!std.mem.startsWith(u8, entry.name, "cozmic-")) continue;
        var path_buffer: [256]u8 = undefined;
        const path = try std.fmt.bufPrint(&path_buffer, "{s}/tests/fonts/FiraMono-Medium.ttf", .{entry.name});
        const file = pkg.openFile(io, path, .{}) catch continue;
        defer file.close(io);
        const data = try testing.allocator.alloc(u8, @intCast(try file.length(io)));
        _ = try file.readPositionalAll(io, data, 0);
        bytes = data;
        break;
    }
    const font_bytes = bytes orelse return error.SkipZigTest;
    // Installed already, this test would prove nothing.
    if (ts.fs.db.query(.{ .name = "Fira Mono" }, 500, .normal, .normal) != null) return error.SkipZigTest;

    const f = font("Fira Mono");
    const before = try ts.font_id(&f);
    try ts.add_fonts(&.{font_bytes});
    const after = try ts.font_id(&f);
    try testing.expect(before != after);
    const face = ts.fs.db.query(.{ .name = "Fira Mono" }, 500, .normal, .normal).?;
    try testing.expectEqual(face, ts.fonts.items[after].face);

    const runs = [_]FontRun{.{ .len = 1, .font_id = after }};
    const layout = try ts.layout_cache.layout_line("A", 16, &runs, null);
    try testing.expect(layout.width > 0);
    try testing.expect((try ts.raster.?.ensureFace(face)) != null);
}

fn put_u16(buf: []u8, at: usize, v: u16) void {
    std.mem.writeInt(u16, buf[at..][0..2], v, .big);
}

fn put_u32(buf: []u8, at: usize, v: u32) void {
    std.mem.writeInt(u32, buf[at..][0..4], v, .big);
}

test "scan_tables reads OS/2 heights, hhea line gap and head from a table directory" {
    // A 246-byte sfnt with three tables: OS/2 (version 2) at 60, hhea at 156 and head at 192.
    var buf: [246]u8 = @splat(0);
    put_u32(&buf, 0, 0x00010000);
    put_u16(&buf, 4, 3);
    const tags = [_]struct { tag: *const [4]u8, off: u32, len: u32 }{
        .{ .tag = "OS/2", .off = 60, .len = 96 },
        .{ .tag = "hhea", .off = 156, .len = 36 },
        .{ .tag = "head", .off = 192, .len = 54 },
    };
    for (tags, 0..) |t, i| {
        const rec = 12 + i * 16;
        @memcpy(buf[rec .. rec + 4], t.tag);
        put_u32(&buf, rec + 8, t.off);
        put_u32(&buf, rec + 12, t.len);
    }
    put_u16(&buf, 60, 2); // OS/2 version
    put_u16(&buf, 60 + 86, 500); // sxHeight
    put_u16(&buf, 60 + 88, 700); // sCapHeight
    put_u16(&buf, 156 + 8, 42); // hhea lineGap
    put_u16(&buf, 192 + 18, 1000); // unitsPerEm
    put_u16(&buf, 192 + 42, @bitCast(@as(i16, 800))); // yMax

    const scan = scan_tables(&buf);
    try testing.expect(!scan.color);
    const os2 = scan.os2 orelse return error.TestUnexpectedResult;
    try testing.expectEqual(@as(f32, 500), os2.x_height);
    try testing.expectEqual(@as(f32, 700), os2.cap_height);
    try testing.expectEqual(@as(f32, 42), scan.hhea_line_gap orelse return error.TestUnexpectedResult);
    const head = scan.head orelse return error.TestUnexpectedResult;
    try testing.expectEqual(@as(u32, 1000), head.units_per_em);
    try testing.expectEqual(@as(f32, -800), head.box.origin.y);

    // A version 1 OS/2 table has no heights, so none are reported.
    put_u16(&buf, 60, 1);
    try testing.expect(scan_tables(&buf).os2 == null);
}

test "font_name_with_fallbacks maps the virtual font names" {
    try testing.expectEqualStrings("Inter", font_name_with_fallbacks(".SystemUIFont", "Inter"));
    try testing.expectEqualStrings("IBM Plex Sans", font_name_with_fallbacks(".ZedSans", "Inter"));
    try testing.expectEqualStrings("Lilex", font_name_with_fallbacks("Zed Plex Mono", "Inter"));
    try testing.expectEqualStrings("Arial", font_name_with_fallbacks("Arial", "Inter"));
}

test "get_font_for_id returns the font a request resolved to, and prewarm reuses it" {
    const ts = try TextSystem.create(testing.allocator);
    defer ts.destroy();
    const f = font("Zed Plex Sans");
    const id = try ts.font_id(&f);
    const back = ts.get_font_for_id(id) orelse return error.TestUnexpectedResult;
    try testing.expectEqualStrings("Zed Plex Sans", back.family);
    try testing.expect(ts.get_font_for_id(std.math.maxInt(FontId) - 1) == null);

    const g = font("Another Family");
    ts.prewarm_fonts(&.{ f, g });
    try testing.expectEqual(id, try ts.font_id(&f));
    try testing.expect(ts.get_font_for_id(try ts.font_id(&g)) != null);
}

test "typographic bounds, em widths and baseline offset agree with the advance and metrics" {
    const ts = try TextSystem.create(testing.allocator);
    defer ts.destroy();
    if (!ts.fs.hasShaper() or ts.fs.fontIds().len == 0) return error.SkipZigTest;
    const id = try ts.font_id(&font(".SystemUIFont"));

    const tb = try ts.typographic_bounds(id, 16, 'm');
    try testing.expectEqual(@as(f32, 0), tb.origin.x);
    try testing.expectEqual(@as(f32, 0), tb.origin.y);
    try testing.expect(tb.size.width > 0);
    try testing.expectApproxEqAbs((try ts.advance(id, 16, 'm')).width, tb.size.width, 0.0001);
    try testing.expectApproxEqAbs(tb.size.width, try ts.em_width(id, 16), 0.0001);
    try testing.expectApproxEqAbs(tb.size.width, try ts.em_advance(id, 16), 0.0001);
    try testing.expectError(error.GlyphNotFound, ts.typographic_bounds(id, 16, 0x10ffff));

    // The baseline sits where the ascent and descent centre in the line.
    const a = ts.ascent(id, 16);
    const d = ts.descent(id, 16);
    try testing.expect(a > 0 and d > 0);
    try testing.expectApproxEqAbs((30 - a - d) / 2.0 + a, ts.baseline_offset(id, 16, 30), 0.0001);

    // The heights come from the font's own tables, which the synthetic test above checks.
    const face = ts.entry(id).face;
    const bytes = ts.fs.fontBytes(face) orelse return error.SkipZigTest;
    const os2 = scan_tables(bytes).os2 orelse return error.SkipZigTest;
    const upem: f32 = @floatFromInt(ts.units_per_em(id));
    try testing.expectApproxEqAbs(os2.cap_height / upem * 16, ts.cap_height(id, 16), 0.0001);
    try testing.expectApproxEqAbs(os2.x_height / upem * 16, ts.x_height(id, 16), 0.0001);
}

test "a character followed by U+FE0E is drawn from a text face, not the color emoji face" {
    const ts = try TextSystem.create(testing.allocator);
    defer ts.destroy();
    if (!ts.fs.hasShaper() or ts.fs.fontIds().len == 0) return error.SkipZigTest;
    const f = font(".SystemUIFont");
    const id = try ts.font_id(&f);

    // Only meaningful where fallback picks a color face for the bare heart; elsewhere there is nothing to fix.
    const plain = [_]FontRun{.{ .len = "\u{2764}".len, .font_id = id }};
    const plain_layout = try ts.layout_line("\u{2764}", 16, &plain, null);
    var plain_is_color = false;
    for (plain_layout.runs) |run| for (run.glyphs) |g| {
        plain_is_color = plain_is_color or g.is_emoji;
    };
    if (!plain_is_color) return error.SkipZigTest;

    const text = "a\u{2764}\u{fe0e}b";
    const runs = [_]TextRun{.{ .len = text.len, .font = f, .color = .{ .h = 0, .s = 0, .l = 0, .a = 1 } }};
    const shaped = try ts.shape_line(text, 16, &runs, null);
    try testing.expectEqual(@as(usize, text.len), shaped.len());
    var glyphs: usize = 0;
    for (shaped.layout.runs) |run| for (run.glyphs) |g| {
        glyphs += 1;
        try testing.expect(!g.is_emoji);
        // The glyph must come out at text size. A monochrome emoji face (Twemoji) rasterized at 4-5x here.
        const p: RenderGlyphParams = .{ .font_id = run.font_id, .glyph_id = g.id, .font_size = 16, .subpixel_variant = .{ .x = 0, .y = 0 }, .scale_factor = 1, .is_emoji = false };
        const rb = try ts.raster_bounds(&p);
        try testing.expect(rb.size.width <= 32 and rb.size.height <= 32);
    };
    try testing.expect(glyphs >= 3);
    try testing.expect(shaped.width() > 0);
    ts.finish_frame();
}

test "missing glyphs are reported once per grapheme while reporting is on" {
    const ts = try TextSystem.create(testing.allocator);
    defer ts.destroy();
    if (!ts.fs.hasShaper() or ts.fs.fontIds().len == 0) return error.SkipZigTest;
    const f = font(".SystemUIFont");
    const color: @import("color.zig").Hsla = .{ .h = 0, .s = 0, .l = 0, .a = 1 };

    // U+10FFFF is a noncharacter that no installed font draws.
    const text = "a\u{10ffff}b";
    const runs = [_]TextRun{.{ .len = text.len, .font = f, .color = color }};
    _ = try ts.shape_line(text, 16, &runs, null);
    const none = try ts.take_missing_glyphs();
    defer ts.free_missing_glyphs(none);
    try testing.expectEqual(@as(usize, 0), none.len);

    ts.set_missing_glyph_reporting(true);
    defer ts.set_missing_glyph_reporting(false);
    const other = "b\u{10ffff}";
    const other_runs = [_]TextRun{.{ .len = other.len, .font = f, .color = color }};
    _ = try ts.shape_line(other, 16, &other_runs, null);
    const reported = try ts.take_missing_glyphs();
    defer ts.free_missing_glyphs(reported);
    try testing.expectEqual(@as(usize, 1), reported.len);
    try testing.expectEqualStrings("\u{10ffff}", reported[0].grapheme());
    try testing.expectEqual(FallbackFontClass.proportional, reported[0].font_class());

    // The same grapheme again is not reported twice.
    const again = "c\u{10ffff}";
    const again_runs = [_]TextRun{.{ .len = again.len, .font = f, .color = color }};
    _ = try ts.shape_line(again, 16, &again_runs, null);
    const repeat = try ts.take_missing_glyphs();
    defer ts.free_missing_glyphs(repeat);
    try testing.expectEqual(@as(usize, 0), repeat.len);
}
