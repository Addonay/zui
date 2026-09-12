//! Narrow Cozmic adapter: draw already-positioned glyphs through `vellz.glifo`.
//!
//! This module is opt-in tooling: nothing in the rendering core
//! (`src/glifo`, `src/cpu`, ...) imports it, and it never imports Cozmic. A
//! caller feeds `PositionedGlyph` values that were already positioned by
//! whatever layout engine it uses (Cozmic, in the committed bridge test) and
//! supplies a `FontResolver` so the adapter can build a `glifo.FontData`.
//!
//! # Contract
//!
//! 1. Positioned glyphs only. The adapter never maps characters, shapes,
//!    kerns, wraps or reorders; it consumes `(glyph_id, font_id, font_size,
//!    x, y)` values in the order given and forwards them 1:1.
//! 2. A `glifo.GlyphRun` carries one font and one size, so the input is split
//!    into runs at font/size changes only. Consecutive glyphs are never
//!    regrouped or reordered.
//! 3. Positions are layout-space, y-down. `glifo` applies the font-space Y
//!    flip internally; the adapter must not pre-flip anything. Subpixel
//!    positions are passed through as f32 and quantized once by `glifo`;
//!    Cozmic's `.875` carry versus `glifo`'s clamp-to-bucket-3 differs by at
//!    most 0.125 px (documented residual, M3 plan §3).
//! 4. Synthetic embolden is forwarded to `glifo`, which dilates the outline
//!    with `kurbo.expand_path` (ported) exactly like upstream. It is never
//!    silently dropped.
//! 5. `FontData.blob` is the resolved byte slice, so the resolver must return
//!    a stable address for a given `font_id` (the slice's pointer is the
//!    font identity in cache keys, exactly like upstream `FontData`).

const std = @import("std");
const vellz = @import("vellz");
const glifo = vellz.glifo;
const kurbo = vellz.kurbo;

/// A glyph positioned by the caller's layout engine.
pub const PositionedGlyph = struct {
    /// Font-specific glyph id (not a Unicode code point).
    glyph_id: u32,
    /// Caller font id, resolved through `FontResolver`.
    font_id: u32,
    /// Font size in pixels per em for this glyph.
    font_size: f32,
    /// X position in layout space (y-down).
    x: f32,
    /// Y position in layout space (y-down).
    y: f32,
};

/// A font face resolved for a `font_id`.
pub const ResolvedFont = struct {
    /// Raw font bytes. The address is the font identity used by glyph cache
    /// keys, so the slice must stay valid (and at the same address) while any
    /// run using it is drawn or cached.
    bytes: []const u8,
    /// Face index within the blob (0 for a single-face font).
    index: u32 = 0,
};

/// Errors a `FontResolver` may report.
pub const ResolveError = error{
    /// The `font_id` is not known to the resolver.
    UnknownFont,
    /// The resolver understood the id but cannot provide the font (for
    /// example a format the port has not implemented).
    Unsupported,
} || std.mem.Allocator.Error;

/// Caller-supplied resolver: `font_id` -> font bytes, face index.
///
/// The callback style keeps the adapter free of allocator/ownership policy;
/// implementations usually look up a font map built by the layout engine.
pub const FontResolver = struct {
    /// Opaque context passed back on every call (a pointer to the caller's
    /// font map, for example).
    context: ?*anyopaque = null,
    /// Resolve `font_id`; must return a stable `bytes` address per id.
    resolveFn: *const fn (context: ?*anyopaque, font_id: u32) ResolveError!ResolvedFont,

    /// Resolve `font_id` through the callback.
    pub fn resolve(self: FontResolver, font_id: u32) ResolveError!ResolvedFont {
        return self.resolveFn(self.context, font_id);
    }
};

/// Whether the run is filled or stroked.
pub const Style = enum { fill, stroke };

/// Run-level options applied to every split run.
pub const Options = struct {
    /// Fill (default) or stroke the glyphs.
    style: Style = .fill,
    /// Forwarded to `glifo`'s builder; hint-requiring transforms run through
    /// the ported TrueType interpreter.
    hint: bool = false,
    /// Enable glyph-atlas-backed caching for the runs.
    atlas_cache: bool = true,
    /// Optional per-glyph transform (for example a skew for fake italics).
    glyph_transform: ?kurbo.Affine = null,
    /// Synthetic embolden forwarded verbatim; non-default amounts dilate the
    /// outline through the ported `kurbo.expand_path`.
    embolden: glifo.FontEmbolden = .{},
};

/// Draw `positioned` through `ctx` (a `vellz.cpu.RenderContext`, or any type
/// with a compatible `glyphRun(resources, font)` method).
///
/// Glyphs are forwarded 1:1 in input order and split into `glifo` runs only
/// where `font_id` or `font_size` changes. Allocates one scratch slice for
/// the whole list; every error (unknown font, unsupported feature, OOM,
/// backend failure) propagates to the caller.
pub fn drawRun(
    allocator: std.mem.Allocator,
    ctx: anytype,
    resources: anytype,
    resolver: FontResolver,
    positioned: []const PositionedGlyph,
    options: Options,
) !void {
    if (positioned.len == 0) return;

    const glyphs = try allocator.alloc(glifo.Glyph, positioned.len);
    defer allocator.free(glyphs);
    for (positioned, 0..) |glyph, i| {
        // 1:1 mapping: ids and positions are copied verbatim (no cmap, no
        // shaping, no y-flip).
        glyphs[i] = .{ .id = glyph.glyph_id, .x = glyph.x, .y = glyph.y };
    }

    var start: usize = 0;
    while (start < positioned.len) {
        const first = positioned[start];
        // `glifo.GlyphRun` is homogeneous in font and size; extend the run
        // while the next glyph agrees. Input order is preserved exactly.
        var end = start + 1;
        while (end < positioned.len and
            positioned[end].font_id == first.font_id and
            positioned[end].font_size == first.font_size)
        {
            end += 1;
        }

        const resolved = try resolver.resolve(first.font_id);
        const font = glifo.FontData.init(resolved.bytes, resolved.index);

        var builder = ctx.glyphRun(resources, font)
            .fontSize(first.font_size)
            .hint(options.hint)
            .atlasCache(options.atlas_cache)
            .fontEmbolden(options.embolden);
        if (options.glyph_transform) |transform| {
            builder = builder.glyphTransform(transform);
        }

        const run_glyphs = glyphs[start..end];
        switch (options.style) {
            .fill => try builder.fillGlyphs(allocator, glifo.iterate(run_glyphs)),
            .stroke => try builder.strokeGlyphs(allocator, glifo.iterate(run_glyphs)),
        }
        start = end;
    }
}

// --------------------------------------------------------------------- tests

const testing = std.testing;

/// Recording fake backend: proves the adapter forwards runs 1:1 without
/// shaping, cmap or reordering. It intentionally has no font parsing.
const RecordingBackend = struct {
    recorder: *Recorder,

    pub fn atlasCache(self: RecordingBackend, enabled: bool) RecordingBackend {
        var result = self;
        result.recorder.atlas_cache_calls += 1;
        result.recorder.last_atlas_cache = enabled;
        return result;
    }

    pub fn fillGlyphs(
        self: RecordingBackend,
        allocator: std.mem.Allocator,
        run: glifo.GlyphRun,
        glyphs: anytype,
    ) !void {
        try self.recorder.record(allocator, run, glyphs, .fill);
    }

    pub fn strokeGlyphs(
        self: RecordingBackend,
        allocator: std.mem.Allocator,
        run: glifo.GlyphRun,
        glyphs: anytype,
    ) !void {
        try self.recorder.record(allocator, run, glyphs, .stroke);
    }
};

const Recorder = struct {
    glyphs: std.ArrayListUnmanaged(glifo.Glyph) = .empty,
    run_sizes: std.ArrayListUnmanaged(f32) = .empty,
    run_fonts: std.ArrayListUnmanaged(usize) = .empty,
    run_styles: std.ArrayListUnmanaged(Style) = .empty,
    run_emboldens: std.ArrayListUnmanaged([2]f64) = .empty,
    resolve_calls: usize = 0,
    atlas_cache_calls: usize = 0,
    last_atlas_cache: bool = false,

    fn deinit(self: *Recorder, allocator: std.mem.Allocator) void {
        self.glyphs.deinit(allocator);
        self.run_sizes.deinit(allocator);
        self.run_fonts.deinit(allocator);
        self.run_styles.deinit(allocator);
        self.run_emboldens.deinit(allocator);
    }

    fn record(
        self: *Recorder,
        allocator: std.mem.Allocator,
        run: glifo.GlyphRun,
        glyphs: anytype,
        style: Style,
    ) !void {
        try self.run_sizes.append(allocator, run.font_size);
        try self.run_fonts.append(allocator, run.font.blob.len);
        try self.run_styles.append(allocator, style);
        try self.run_emboldens.append(allocator, run.font_embolden.amount);
        var iterator = glyphs;
        while (iterator.next()) |glyph| {
            try self.glyphs.append(allocator, glyph);
        }
    }
};

/// Fake context exposing `glyphRun(resources, font)` over `RecordingBackend`.
const RecordingContext = struct {
    recorder: *Recorder,

    pub fn glyphRun(
        self: *RecordingContext,
        resources: anytype,
        font: glifo.FontData,
    ) glifo.GlyphRunBuilder(RecordingBackend) {
        _ = resources;
        return glifo.GlyphRunBuilder(RecordingBackend).new(
            font,
            kurbo.Affine.IDENTITY,
            kurbo.Affine.IDENTITY,
            .{ .recorder = self.recorder },
        );
    }
};

/// Resolver over a fixed `(font_id, bytes)` table that counts lookups.
const TestResolver = struct {
    entries: []const struct { id: u32, bytes: []const u8 },
    calls: *usize,

    fn resolveFn(context: ?*anyopaque, font_id: u32) ResolveError!ResolvedFont {
        const self: *TestResolver = @ptrCast(@alignCast(context.?));
        self.calls.* += 1;
        for (self.entries) |entry| {
            if (entry.id == font_id) return .{ .bytes = entry.bytes };
        }
        return error.UnknownFont;
    }

    fn resolver(self: *TestResolver) FontResolver {
        return .{ .context = self, .resolveFn = resolveFn };
    }
};

test "adapter forwards positioned glyphs 1:1 without shaping" {
    const allocator = testing.allocator;
    var recorder = Recorder{};
    defer recorder.deinit(allocator);
    var ctx = RecordingContext{ .recorder = &recorder };

    const roboto = "roboto-bytes";
    const noto = "noto-bytes";
    var resolve_calls: usize = 0;
    var resolver_state = TestResolver{
        .entries = &.{
            .{ .id = 0, .bytes = roboto },
            .{ .id = 7, .bytes = noto },
        },
        .calls = &resolve_calls,
    };

    // Three runs: font 0/size 20 (3 glyphs), font 0/size 10 (2 glyphs),
    // font 7/size 20 (1 glyph). Positions are arbitrary on purpose: the
    // adapter must not inspect ids beyond forwarding them.
    const positioned = [_]PositionedGlyph{
        .{ .glyph_id = 44, .font_id = 0, .font_size = 20.0, .x = 0.0, .y = 1.5 },
        .{ .glyph_id = 41, .font_id = 0, .font_size = 20.0, .x = 12.25, .y = 1.5 },
        .{ .glyph_id = 48, .font_id = 0, .font_size = 20.0, .x = 24.5, .y = 1.5 },
        .{ .glyph_id = 48, .font_id = 0, .font_size = 10.0, .x = 3.0, .y = 0.0 },
        .{ .glyph_id = 51, .font_id = 0, .font_size = 10.0, .x = 8.0, .y = 0.0 },
        .{ .glyph_id = 999, .font_id = 7, .font_size = 20.0, .x = -2.0, .y = 4.0 },
    };

    try drawRun(allocator, &ctx, {}, resolver_state.resolver(), &positioned, .{
        .style = .fill,
        .hint = false,
        .atlas_cache = true,
    });

    // No shaping or reshaping: one resolver lookup per run, one atlas-cache
    // toggle per run, and every glyph delivered exactly once in order.
    try testing.expectEqual(@as(usize, 3), resolve_calls);
    try testing.expectEqual(@as(usize, 3), recorder.run_sizes.items.len);
    try testing.expectEqual(@as(usize, 3), recorder.atlas_cache_calls);
    try testing.expect(recorder.last_atlas_cache);
    try testing.expectEqual(@as(usize, positioned.len), recorder.glyphs.items.len);
    try testing.expectEqualSlices(f32, &[_]f32{ 20.0, 10.0, 20.0 }, recorder.run_sizes.items);
    try testing.expectEqualSlices(Style, &[_]Style{ .fill, .fill, .fill }, recorder.run_styles.items);
    // Font identity is the resolved slice (length is enough for the fake).
    try testing.expectEqual(@as(usize, roboto.len), recorder.run_fonts.items[0]);
    try testing.expectEqual(@as(usize, roboto.len), recorder.run_fonts.items[1]);
    try testing.expectEqual(@as(usize, noto.len), recorder.run_fonts.items[2]);
    for (positioned, recorder.glyphs.items) |expected, actual| {
        try testing.expectEqual(expected.glyph_id, actual.id);
        try testing.expectEqual(expected.x, actual.x);
        try testing.expectEqual(expected.y, actual.y);
    }
}

test "adapter splits runs only on font or size changes" {
    const allocator = testing.allocator;
    var recorder = Recorder{};
    defer recorder.deinit(allocator);
    var ctx = RecordingContext{ .recorder = &recorder };

    const bytes = "same-font";
    var resolve_calls: usize = 0;
    var resolver_state = TestResolver{
        .entries = &.{.{ .id = 1, .bytes = bytes }},
        .calls = &resolve_calls,
    };

    // Same font/size but interleaved other-font glyph: the split is by
    // consecutive runs, never a reorder or merge.
    const positioned = [_]PositionedGlyph{
        .{ .glyph_id = 1, .font_id = 1, .font_size = 16.0, .x = 0.0, .y = 0.0 },
        .{ .glyph_id = 2, .font_id = 1, .font_size = 16.0, .x = 5.0, .y = 0.0 },
        .{ .glyph_id = 3, .font_id = 1, .font_size = 12.0, .x = 7.0, .y = 0.0 },
        .{ .glyph_id = 4, .font_id = 1, .font_size = 16.0, .x = 9.0, .y = 0.0 },
    };

    try drawRun(allocator, &ctx, {}, resolver_state.resolver(), &positioned, .{
        .style = .stroke,
    });

    try testing.expectEqual(@as(usize, 3), resolve_calls);
    try testing.expectEqualSlices(f32, &[_]f32{ 16.0, 12.0, 16.0 }, recorder.run_sizes.items);
    try testing.expectEqualSlices(Style, &[_]Style{ .stroke, .stroke, .stroke }, recorder.run_styles.items);
    try testing.expectEqual(@as(usize, 4), recorder.glyphs.items.len);
    try testing.expectEqual(@as(u32, 1), recorder.glyphs.items[0].id);
    try testing.expectEqual(@as(u32, 2), recorder.glyphs.items[1].id);
    try testing.expectEqual(@as(u32, 3), recorder.glyphs.items[2].id);
    try testing.expectEqual(@as(u32, 4), recorder.glyphs.items[3].id);
}

test "adapter propagates unknown font ids and empty input" {
    const allocator = testing.allocator;
    var recorder = Recorder{};
    defer recorder.deinit(allocator);
    var ctx = RecordingContext{ .recorder = &recorder };

    var resolve_calls: usize = 0;
    var resolver_state = TestResolver{
        .entries = &.{.{ .id = 0, .bytes = "font" }},
        .calls = &resolve_calls,
    };

    const missing = [_]PositionedGlyph{
        .{ .glyph_id = 1, .font_id = 42, .font_size = 16.0, .x = 0.0, .y = 0.0 },
    };
    try testing.expectError(
        error.UnknownFont,
        drawRun(allocator, &ctx, {}, resolver_state.resolver(), &missing, .{}),
    );

    // Empty input is a no-op: no resolution, no runs.
    try drawRun(allocator, &ctx, {}, resolver_state.resolver(), &.{}, .{});
    try testing.expectEqual(@as(usize, 1), resolve_calls);
    try testing.expectEqual(@as(usize, 0), recorder.glyphs.items.len);
}

test "adapter forwards non-default embolden verbatim" {
    const allocator = testing.allocator;
    var recorder = Recorder{};
    defer recorder.deinit(allocator);
    var ctx = RecordingContext{ .recorder = &recorder };

    var resolve_calls: usize = 0;
    var resolver_state = TestResolver{
        .entries = &.{.{ .id = 0, .bytes = "font" }},
        .calls = &resolve_calls,
    };

    const positioned = [_]PositionedGlyph{
        .{ .glyph_id = 1, .font_id = 0, .font_size = 16.0, .x = 0.0, .y = 0.0 },
    };
    // The adapter forwards the embolden request verbatim; the real CPU backend
    // applies it through `prepareGlyphRun` -> `OutlineCache.getOrInsert`
    // (`kurbo.expandPath`; see the bridge test for pixel equivalence).
    try drawRun(allocator, &ctx, {}, resolver_state.resolver(), &positioned, .{
        .embolden = glifo.FontEmbolden.new(.{ 1.0, 0.0 }),
    });
    try testing.expectEqual(@as(usize, 1), recorder.glyphs.items.len);
    try testing.expectEqualDeep(
        [2]f64{ 1.0, 0.0 },
        recorder.run_emboldens.items[0],
    );
}
