//! COLR table parsing: v0 layers plus the v1 paint graph.
//!
//! Hand-written subset of the `read-fonts` 0.41.0 generated `COLR` accessors
//! (`tables/colr.rs` + `generated_colr.rs`) needed by `glifo/src/colr.rs` and
//! the `skrifa/src/color/{traversal,instance,transform}.rs` machinery it
//! drives: base glyph records, layer lists, clip lists/boxes, color lines and
//! every `Paint` format.
//!
//! Layout equivalence notes:
//! - Every record is parsed from a slice that starts at the record itself, so
//!   nested `Offset24`/`Offset32` values are relative to the record, exactly
//!   like `read-fonts`' `data.split_off(..)` resolution.
//! - `PaintAbs` is the absolute byte offset of a paint record within the COLR
//!   table. `read-fonts` uses `paint_offset + list_ptr` as the cycle-detection
//!   identity; the absolute offset has the same uniqueness (one COLR table per
//!   face) and is stable in Zig.
//! - Degradation follows `read-fonts`: a missing/zero/half-written table
//!   resolves to `null` rather than an error; record arrays that do not fit
//!   resolve to an empty slice (`ok().unwrap_or_default()`), while a malformed
//!   *paint record* stops the traversal with `error.MalformedFont` (upstream
//!   `PaintError`/`ReadError`, which `glifo`'s painter ignores).
//! - Variation deltas are not applied. This is exact for the only supported
//!   input: the run layer rejects non-empty `normalized_coords`, so `skrifa`
//!   would return `FloatItemDelta::ZERO` for every `Var*` record. The
//!   `var_index_base` fields are parsed and ignored.

const std = @import("std");
const sfnt = @import("sfnt.zig");

/// Errors while resolving a COLR paint graph.
///
/// Mirrors the `skrifa::color::PaintError` variants that traversal can raise;
/// `glifo`'s `ColrPainter` ignores paint errors (upstream behavior) but
/// propagates allocator failures from the sink.
pub const Error = error{
    /// Truncated record, zero/invalid offset or unknown paint format.
    MalformedFont,
    /// A `ColrGlyph`/`Glyph` paint references a missing base glyph.
    GlyphNotFound,
    /// The paint graph re-entered a node (HarfBuzz-style decycler check).
    PaintCycleDetected,
    /// Nesting exceeded `max_traversal_depth`.
    DepthLimitExceeded,
};

/// Depth at which traversal stops, matching skrifa's `MAX_TRAVERSAL_DEPTH`
/// (HarfBuzz's `HB_MAX_NESTING_LEVEL`).
pub const max_traversal_depth: usize = 64;

/// `read-fonts` `CompositeMode` (`generated_colr.rs`). Unknown values map to
/// `.unknown`, which `glifo` converts to `BlendMode::default()`.
pub const CompositeMode = enum(u8) {
    clear = 0,
    src = 1,
    dest = 2,
    src_over = 3,
    dest_over = 4,
    src_in = 5,
    dest_in = 6,
    src_out = 7,
    dest_out = 8,
    src_atop = 9,
    dest_atop = 10,
    xor = 11,
    plus = 12,
    screen = 13,
    overlay = 14,
    darken = 15,
    lighten = 16,
    color_dodge = 17,
    color_burn = 18,
    hard_light = 19,
    soft_light = 20,
    difference = 21,
    exclusion = 22,
    multiply = 23,
    hsl_hue = 24,
    hsl_saturation = 25,
    hsl_color = 26,
    hsl_luminosity = 27,
    unknown = 255,
};

pub fn compositeModeFromU8(raw: u8) CompositeMode {
    if (raw > 27) return .unknown;
    return @enumFromInt(raw);
}

/// `read-fonts` `colr::Extend`.
pub const Extend = enum(u8) {
    pad = 0,
    repeat = 1,
    reflect = 2,
    unknown = 3,
};

pub fn extendFromU8(raw: u8) Extend {
    if (raw > 2) return .unknown;
    return @enumFromInt(raw);
}

/// A paint record handle: `data` starts at the record, `abs` is its absolute
/// offset within the COLR table (used as the cycle-detection identity).
pub const Paint = struct {
    data: []const u8,
    abs: usize,

    fn sub(self: Paint, offset: usize) Error!Paint {
        if (offset > self.data.len) return error.MalformedFont;
        return .{ .data = self.data[offset..], .abs = self.abs + offset };
    }
};

/// Resolved (f32) affine transform (`read-fonts` `Affine2x3`). Field order is
/// `[xx, yx, xy, yy, dx, dy]`, matching `Matrix::elements`.
pub const Affine2x3 = struct {
    xx: f32,
    yx: f32,
    xy: f32,
    yy: f32,
    dx: f32,
    dy: f32,
};

/// Color line handle: a byte slice of `ColorStop` (stride 6) or `VarColorStop`
/// (stride 10) records. Accessors decode on demand so no alignment or copying
/// assumptions are needed.
pub const ColorStops = struct {
    data: []const u8,
    stride: u8,

    pub fn len(self: ColorStops) usize {
        return self.data.len / self.stride;
    }

    pub fn isEmpty(self: ColorStops) bool {
        return self.len() == 0;
    }

    /// Stop offset in 0..1 (`F2Dot14`), variation deltas not applied.
    pub fn offset(self: ColorStops, i: usize) f32 {
        return f2dot14ToF32(sfnt.readI16(self.data, i * self.stride).?);
    }

    pub fn paletteIndex(self: ColorStops, i: usize) u16 {
        return sfnt.readU16(self.data, i * self.stride + 2).?;
    }

    /// Stop alpha in 0..1 (`F2Dot14`), variation deltas not applied.
    pub fn alpha(self: ColorStops, i: usize) f32 {
        return f2dot14ToF32(sfnt.readI16(self.data, i * self.stride + 4).?);
    }
};

/// Semantic paint graph (`skrifa::color::instance::ResolvedPaint`), with child
/// paints left as handles so traversal stays lazy on malformed subtrees.
pub const ResolvedPaint = union(enum) {
    colr_layers: struct {
        start: usize,
        count: usize,
    },
    solid: struct {
        palette_index: u16,
        alpha: f32,
    },
    linear_gradient: struct {
        x0: f32,
        y0: f32,
        x1: f32,
        y1: f32,
        x2: f32,
        y2: f32,
        color_stops: ColorStops,
        extend: Extend,
    },
    radial_gradient: struct {
        x0: f32,
        y0: f32,
        radius0: f32,
        x1: f32,
        y1: f32,
        radius1: f32,
        color_stops: ColorStops,
        extend: Extend,
    },
    sweep_gradient: struct {
        center_x: f32,
        center_y: f32,
        start_angle: f32,
        end_angle: f32,
        color_stops: ColorStops,
        extend: Extend,
    },
    glyph: struct {
        glyph_id: u16,
        paint: Paint,
    },
    colr_glyph: struct {
        glyph_id: u16,
    },
    transform: struct {
        affine: Affine2x3,
        paint: Paint,
    },
    translate: struct {
        dx: f32,
        dy: f32,
        paint: Paint,
    },
    scale: struct {
        scale_x: f32,
        scale_y: f32,
        around_center: ?[2]f32,
        paint: Paint,
    },
    rotate: struct {
        angle: f32,
        around_center: ?[2]f32,
        paint: Paint,
    },
    skew: struct {
        x_skew_angle: f32,
        y_skew_angle: f32,
        around_center: ?[2]f32,
        paint: Paint,
    },
    composite: struct {
        source_paint: Paint,
        mode: CompositeMode,
        backdrop_paint: Paint,
    },
};

/// Resolved clip box in font units (`BoundingBox<f32>` after
/// `resolve_clip_box`; variation deltas are zero for supported inputs).
pub const ClipBox = struct {
    x_min: f32,
    y_min: f32,
    x_max: f32,
    y_max: f32,
};

/// A COLRv0 layer span.
pub const LayerRange = struct {
    start: usize,
    len: usize,
};

/// A COLRv0 layer record.
pub const V0Layer = struct {
    glyph_id: u16,
    palette_index: u16,
};

/// Parsed `COLR` table borrowing the font blob.
pub const Colr = struct {
    /// The whole `COLR` table.
    data: []const u8,

    /// Parse `data` as a `COLR` table.
    ///
    /// Returns `null` when the fixed header (including the version-1 fields
    /// when `version >= 1`) is not present; matching `read-fonts`, a font
    /// without a usable COLR table resolves to "no color glyphs".
    pub fn parse(data: []const u8) ?Colr {
        if (data.len < 14) return null;
        const table_version = sfnt.readU16(data, 0) orelse return null;
        if (table_version >= 1 and data.len < 34) return null;
        return .{ .data = data };
    }

    pub fn version(self: Colr) u16 {
        return sfnt.readU16(self.data, 0) orelse 0;
    }

    fn isV1(self: Colr) bool {
        return self.version() >= 1;
    }

    /// Record array at `offset_field` with `count` records of `stride` bytes,
    /// or `null` when the offset is zero/out of bounds or the array does not
    /// fit. `read-fonts`' nullable-offset + `read_array` behavior.
    fn recordArray(self: Colr, offset_field: usize, count: usize, stride: usize) ?[]const u8 {
        const off = sfnt.readU32(self.data, offset_field) orelse return null;
        if (off == 0) return null;
        if (off > self.data.len) return null;
        const len = count * stride;
        if (len > self.data.len - off) return null;
        return self.data[off .. off + len];
    }

    /// COLRv0 base glyph lookup: the layer-index range for `glyph_id`, or
    /// `null` when absent or malformed. `read-fonts` binary-searches the
    /// sorted base glyph records; duplicate records (malformed) can resolve to
    /// a different index than Zig's scan, which is unobservable for valid
    /// fonts.
    pub fn v0BaseGlyph(self: Colr, glyph_id: u32) ?LayerRange {
        if (glyph_id > 0xFFFF) return null;
        const count = sfnt.readU16(self.data, 2) orelse return null;
        if (count == 0) return null;
        const records = self.recordArray(4, count, 6) orelse return null;
        const gid: u16 = @intCast(glyph_id);

        var lo: usize = 0;
        var hi: usize = count;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            const found = sfnt.readU16(records, mid * 6).?;
            if (gid < found) {
                hi = mid;
            } else if (gid > found) {
                lo = mid + 1;
            } else {
                const start = sfnt.readU16(records, mid * 6 + 2).?;
                const num = sfnt.readU16(records, mid * 6 + 4).?;
                return .{ .start = start, .len = num };
            }
        }
        return null;
    }

    /// COLRv0 layer record at `index`, or `null` when out of range/malformed.
    pub fn v0Layer(self: Colr, index: usize) ?V0Layer {
        const count = sfnt.readU16(self.data, 12) orelse return null;
        if (index >= count) return null;
        const records = self.recordArray(8, count, 4) orelse return null;
        return .{
            .glyph_id = sfnt.readU16(records, index * 4).?,
            .palette_index = sfnt.readU16(records, index * 4 + 2).?,
        };
    }

    fn v1List(self: Colr, offset_field: usize) ?List {
        if (!self.isV1()) return null;
        const off = sfnt.readU32(self.data, offset_field) orelse return null;
        if (off == 0 or off > self.data.len) return null;
        return .{ .data = self.data[off..], .start = off };
    }

    /// COLRv1 base glyph paint for `glyph_id`, or `null` when absent.
    pub fn v1BaseGlyph(self: Colr, glyph_id: u32) ?Paint {
        if (glyph_id > 0xFFFF) return null;
        const gid: u16 = @intCast(glyph_id);
        const list = self.v1List(14) orelse return null;
        if (list.data.len < 4) return null;
        const count = sfnt.readU32(list.data, 0).?;
        const rec_len = @as(usize, count) * 6;
        if (rec_len > list.data.len - 4) return null;

        var lo: usize = 0;
        var hi: usize = count;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            const found = sfnt.readU16(list.data, 4 + mid * 6).?;
            if (gid < found) {
                hi = mid;
            } else if (gid > found) {
                lo = mid + 1;
            } else {
                const off = sfnt.readU32(list.data, 4 + mid * 6 + 2).?;
                if (off > list.data.len) return null;
                return .{ .data = list.data[off..], .abs = list.start + off };
            }
        }
        return null;
    }

    /// COLRv1 layer paint at `index`, or `null` when out of range.
    pub fn v1Layer(self: Colr, index: usize) ?Paint {
        const list = self.v1List(18) orelse return null;
        if (list.data.len < 4) return null;
        const count = sfnt.readU32(list.data, 0).?;
        if (index >= count) return null;
        const off = sfnt.readU32(list.data, 4 + index * 4) orelse return null;
        if (off > list.data.len) return null;
        return .{ .data = list.data[off..], .abs = list.start + off };
    }

    /// COLRv1 clip box for `glyph_id`, or `null` when absent/malformed.
    pub fn v1ClipBox(self: Colr, glyph_id: u32) ?ClipBox {
        if (glyph_id > 0xFFFF) return null;
        const gid: u16 = @intCast(glyph_id);
        const list = self.v1List(22) orelse return null;
        if (list.data.len < 5) return null;
        const count = sfnt.readU32(list.data, 1).?;
        const rec_len = @as(usize, count) * 7;
        if (rec_len > list.data.len - 5) return null;

        // `read-fonts` binary-searches clips by [startGlyphId, endGlyphId].
        var lo: usize = 0;
        var hi: usize = count;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            const rec = 5 + mid * 7;
            const start = sfnt.readU16(list.data, rec).?;
            const end = sfnt.readU16(list.data, rec + 2).?;
            if (gid < start) {
                hi = mid;
            } else if (gid > end) {
                lo = mid + 1;
            } else {
                const off = readU24(list.data, rec + 4) orelse return null;
                if (off > list.data.len) return null;
                return resolveClipBox(list.data[off..]);
            }
        }
        return null;
    }
};

/// A version-1 list (`BaseGlyphList`/`LayerList`/`ClipList`) plus its offset
/// within the COLR table; offsets inside the list are relative to `start`.
const List = struct {
    data: []const u8,
    start: usize,
};

fn resolveClipBox(cb: []const u8) ?ClipBox {
    if (cb.len < 1) return null;
    const format = cb[0];
    if (format != 1 and format != 2) return null;
    if (format == 1 and cb.len < 9) return null;
    if (format == 2 and cb.len < 13) return null;
    // Format 2 carries a varIndexBase at bytes 9..13; deltas are zero for the
    // supported (empty-coordinate) inputs, so only the base values are read.
    return .{
        .x_min = fwordToF32(sfnt.readI16(cb, 1).?),
        .y_min = fwordToF32(sfnt.readI16(cb, 3).?),
        .x_max = fwordToF32(sfnt.readI16(cb, 5).?),
        .y_max = fwordToF32(sfnt.readI16(cb, 7).?),
    };
}

/// Resolve a raw paint record into the semantic graph
/// (`skrifa::color::instance::resolve_paint`).
pub fn resolvePaint(paint: Paint) Error!ResolvedPaint {
    const data = paint.data;
    if (data.len < 1) return error.MalformedFont;
    const format = data[0];
    return switch (format) {
        1 => {
            if (data.len < 6) return error.MalformedFont;
            return .{ .colr_layers = .{
                .start = sfnt.readU32(data, 2).?,
                .count = data[1],
            } };
        },
        2, 3 => {
            const min_len: usize = if (format == 3) 9 else 5;
            if (data.len < min_len) return error.MalformedFont;
            return .{ .solid = .{
                .palette_index = sfnt.readU16(data, 1).?,
                .alpha = f2dot14ToF32(sfnt.readI16(data, 3).?),
            } };
        },
        4, 5 => {
            const min_len: usize = if (format == 5) 20 else 16;
            if (data.len < min_len) return error.MalformedFont;
            const line = try resolveColorLine(
                paint,
                readU24(data, 1) orelse return error.MalformedFont,
                format == 5,
            );
            return .{ .linear_gradient = .{
                .x0 = fwordToF32(sfnt.readI16(data, 4).?),
                .y0 = fwordToF32(sfnt.readI16(data, 6).?),
                .x1 = fwordToF32(sfnt.readI16(data, 8).?),
                .y1 = fwordToF32(sfnt.readI16(data, 10).?),
                .x2 = fwordToF32(sfnt.readI16(data, 12).?),
                .y2 = fwordToF32(sfnt.readI16(data, 14).?),
                .color_stops = line.stops,
                .extend = line.extend,
            } };
        },
        6, 7 => {
            const min_len: usize = if (format == 7) 20 else 16;
            if (data.len < min_len) return error.MalformedFont;
            const line = try resolveColorLine(
                paint,
                readU24(data, 1) orelse return error.MalformedFont,
                format == 7,
            );
            return .{ .radial_gradient = .{
                .x0 = fwordToF32(sfnt.readI16(data, 4).?),
                .y0 = fwordToF32(sfnt.readI16(data, 6).?),
                .radius0 = ufwordToF32(sfnt.readU16(data, 8).?),
                .x1 = fwordToF32(sfnt.readI16(data, 10).?),
                .y1 = fwordToF32(sfnt.readI16(data, 12).?),
                .radius1 = ufwordToF32(sfnt.readU16(data, 14).?),
                .color_stops = line.stops,
                .extend = line.extend,
            } };
        },
        8, 9 => {
            const min_len: usize = if (format == 9) 16 else 12;
            if (data.len < min_len) return error.MalformedFont;
            const line = try resolveColorLine(
                paint,
                readU24(data, 1) orelse return error.MalformedFont,
                format == 9,
            );
            return .{ .sweep_gradient = .{
                .center_x = fwordToF32(sfnt.readI16(data, 4).?),
                .center_y = fwordToF32(sfnt.readI16(data, 6).?),
                .start_angle = f2dot14ToF32(sfnt.readI16(data, 8).?),
                .end_angle = f2dot14ToF32(sfnt.readI16(data, 10).?),
                .color_stops = line.stops,
                .extend = line.extend,
            } };
        },
        10 => {
            if (data.len < 6) return error.MalformedFont;
            const child = try paint.sub(readU24(data, 1) orelse return error.MalformedFont);
            return .{ .glyph = .{
                .glyph_id = sfnt.readU16(data, 4).?,
                .paint = child,
            } };
        },
        11 => {
            if (data.len < 3) return error.MalformedFont;
            return .{ .colr_glyph = .{ .glyph_id = sfnt.readU16(data, 1).? } };
        },
        12, 13 => {
            const min_len: usize = if (format == 13) 32 else 28;
            if (data.len < min_len) return error.MalformedFont;
            const child = try paint.sub(readU24(data, 1) orelse return error.MalformedFont);
            const transform_paint = try paint.sub(readU24(data, 4) orelse return error.MalformedFont);
            return .{ .transform = .{
                .affine = try resolveAffine2x3(transform_paint),
                .paint = child,
            } };
        },
        14, 15 => {
            const min_len: usize = if (format == 15) 12 else 8;
            if (data.len < min_len) return error.MalformedFont;
            const child = try paint.sub(readU24(data, 1) orelse return error.MalformedFont);
            return .{ .translate = .{
                .dx = fwordToF32(sfnt.readI16(data, 4).?),
                .dy = fwordToF32(sfnt.readI16(data, 6).?),
                .paint = child,
            } };
        },
        16, 17 => {
            const min_len: usize = if (format == 17) 12 else 8;
            if (data.len < min_len) return error.MalformedFont;
            const child = try paint.sub(readU24(data, 1) orelse return error.MalformedFont);
            return .{ .scale = .{
                .scale_x = f2dot14ToF32(sfnt.readI16(data, 4).?),
                .scale_y = f2dot14ToF32(sfnt.readI16(data, 6).?),
                .around_center = null,
                .paint = child,
            } };
        },
        18, 19 => {
            const min_len: usize = if (format == 19) 16 else 12;
            if (data.len < min_len) return error.MalformedFont;
            const child = try paint.sub(readU24(data, 1) orelse return error.MalformedFont);
            return .{ .scale = .{
                .scale_x = f2dot14ToF32(sfnt.readI16(data, 4).?),
                .scale_y = f2dot14ToF32(sfnt.readI16(data, 6).?),
                .around_center = .{
                    fwordToF32(sfnt.readI16(data, 8).?),
                    fwordToF32(sfnt.readI16(data, 10).?),
                },
                .paint = child,
            } };
        },
        20, 21 => {
            const min_len: usize = if (format == 21) 10 else 6;
            if (data.len < min_len) return error.MalformedFont;
            const child = try paint.sub(readU24(data, 1) orelse return error.MalformedFont);
            const scale = f2dot14ToF32(sfnt.readI16(data, 4).?);
            return .{ .scale = .{
                .scale_x = scale,
                .scale_y = scale,
                .around_center = null,
                .paint = child,
            } };
        },
        22, 23 => {
            const min_len: usize = if (format == 23) 14 else 10;
            if (data.len < min_len) return error.MalformedFont;
            const child = try paint.sub(readU24(data, 1) orelse return error.MalformedFont);
            const scale = f2dot14ToF32(sfnt.readI16(data, 4).?);
            return .{ .scale = .{
                .scale_x = scale,
                .scale_y = scale,
                .around_center = .{
                    fwordToF32(sfnt.readI16(data, 6).?),
                    fwordToF32(sfnt.readI16(data, 8).?),
                },
                .paint = child,
            } };
        },
        24, 25 => {
            const min_len: usize = if (format == 25) 10 else 6;
            if (data.len < min_len) return error.MalformedFont;
            const child = try paint.sub(readU24(data, 1) orelse return error.MalformedFont);
            return .{ .rotate = .{
                .angle = f2dot14ToF32(sfnt.readI16(data, 4).?),
                .around_center = null,
                .paint = child,
            } };
        },
        26, 27 => {
            const min_len: usize = if (format == 27) 14 else 10;
            if (data.len < min_len) return error.MalformedFont;
            const child = try paint.sub(readU24(data, 1) orelse return error.MalformedFont);
            return .{ .rotate = .{
                .angle = f2dot14ToF32(sfnt.readI16(data, 4).?),
                .around_center = .{
                    fwordToF32(sfnt.readI16(data, 6).?),
                    fwordToF32(sfnt.readI16(data, 8).?),
                },
                .paint = child,
            } };
        },
        28, 29 => {
            const min_len: usize = if (format == 29) 12 else 8;
            if (data.len < min_len) return error.MalformedFont;
            const child = try paint.sub(readU24(data, 1) orelse return error.MalformedFont);
            return .{ .skew = .{
                .x_skew_angle = f2dot14ToF32(sfnt.readI16(data, 4).?),
                .y_skew_angle = f2dot14ToF32(sfnt.readI16(data, 6).?),
                .around_center = null,
                .paint = child,
            } };
        },
        30, 31 => {
            const min_len: usize = if (format == 31) 16 else 12;
            if (data.len < min_len) return error.MalformedFont;
            const child = try paint.sub(readU24(data, 1) orelse return error.MalformedFont);
            return .{ .skew = .{
                .x_skew_angle = f2dot14ToF32(sfnt.readI16(data, 4).?),
                .y_skew_angle = f2dot14ToF32(sfnt.readI16(data, 6).?),
                .around_center = .{
                    fwordToF32(sfnt.readI16(data, 8).?),
                    fwordToF32(sfnt.readI16(data, 10).?),
                },
                .paint = child,
            } };
        },
        32 => {
            if (data.len < 9) return error.MalformedFont;
            const source = try paint.sub(readU24(data, 1) orelse return error.MalformedFont);
            const backdrop = try paint.sub(readU24(data, 5) orelse return error.MalformedFont);
            return .{ .composite = .{
                .source_paint = source,
                .mode = compositeModeFromU8(data[4]),
                .backdrop_paint = backdrop,
            } };
        },
        else => error.MalformedFont,
    };
}

const ResolvedColorLine = struct {
    stops: ColorStops,
    extend: Extend,
};

fn resolveColorLine(paint: Paint, offset: u32, is_var: bool) Error!ResolvedColorLine {
    const line = try paint.sub(offset);
    if (line.data.len < 3) return error.MalformedFont;
    const extend = extendFromU8(line.data[0]);
    const count = sfnt.readU16(line.data, 1).?;
    const stride: u8 = if (is_var) 10 else 6;
    // `read_array(..).ok().unwrap_or_default()`: a truncated color line
    // resolves to zero stops, which traversal treats as "nothing to draw".
    const byte_len: usize = @as(usize, count) * stride;
    if (byte_len > line.data.len - 3) {
        return .{ .stops = .{ .data = &.{}, .stride = stride }, .extend = extend };
    }
    return .{ .stops = .{ .data = line.data[3 .. 3 + byte_len], .stride = stride }, .extend = extend };
}

fn resolveAffine2x3(record: Paint) Error!Affine2x3 {
    if (record.data.len < 24) return error.MalformedFont;
    return .{
        .xx = fixedToF32(@bitCast(sfnt.readU32(record.data, 0) orelse return error.MalformedFont)),
        .yx = fixedToF32(@bitCast(sfnt.readU32(record.data, 4) orelse return error.MalformedFont)),
        .xy = fixedToF32(@bitCast(sfnt.readU32(record.data, 8) orelse return error.MalformedFont)),
        .yy = fixedToF32(@bitCast(sfnt.readU32(record.data, 12) orelse return error.MalformedFont)),
        .dx = fixedToF32(@bitCast(sfnt.readU32(record.data, 16) orelse return error.MalformedFont)),
        .dy = fixedToF32(@bitCast(sfnt.readU32(record.data, 20) orelse return error.MalformedFont)),
    };
}

// ---------------------------------------------------------------- scalar conv

/// `font-types` `F2Dot14::to_f32`: split into the sign-extended integer half
/// plus the fractional half, then add. (Not `raw as f32 / 16384.0`; negative
/// values round differently.)
pub fn f2dot14ToF32(raw: i16) f32 {
    const int_mask: i16 = @bitCast(@as(u16, 0xC000));
    const int_part: f32 = @floatFromInt((raw & int_mask) >> 14);
    const fract_part: f32 = @as(f32, @floatFromInt(raw & ~int_mask)) / 16384.0;
    return int_part + fract_part;
}

/// `font-types` `Fixed::to_f32` (lossy 16.16 -> f32).
pub fn fixedToF32(raw: i32) f32 {
    return @as(f32, @floatFromInt(raw)) * (1.0 / 65536.0);
}

pub fn fwordToF32(raw: i16) f32 {
    return @floatFromInt(raw);
}

pub fn ufwordToF32(raw: u16) f32 {
    return @floatFromInt(raw);
}

fn readU24(data: []const u8, off: usize) ?u32 {
    if (off + 3 > data.len) return null;
    return (@as(u32, data[off]) << 16) | (@as(u32, data[off + 1]) << 8) | @as(u32, data[off + 2]);
}

// --------------------------------------------------------------------- tests

const testing = std.testing;
const test_fixture = @import("../test_fixture.zig");

fn faceFor(blob: []const u8) !sfnt.Face {
    return sfnt.Face.parse(blob, 0);
}

fn colrFor(blob: []const u8) !Colr {
    const face = try faceFor(blob);
    const table = face.table(sfnt.tag_colr) orelse return error.TestUnexpectedResult;
    return Colr.parse(table) orelse return error.TestUnexpectedResult;
}

test "noto colr v1 base glyphs resolve to colr layer paints" {
    const blob = try test_fixture.notoColor();
    const colr = try colrFor(blob);

    // "✅" U+2705 maps to glyph 2 in the subset.
    const paint = colr.v1BaseGlyph(2) orelse return error.TestUnexpectedResult;
    const resolved = try resolvePaint(paint);
    const layers = switch (resolved) {
        .colr_layers => |l| l,
        else => return error.TestUnexpectedResult,
    };
    try testing.expect(layers.count > 0);

    // Every layer of the first base glyph resolves to a paint.
    var i: usize = 0;
    while (i < layers.count) : (i += 1) {
        const layer = colr.v1Layer(layers.start + i) orelse return error.TestUnexpectedResult;
        _ = try resolvePaint(layer);
    }
    try testing.expect(colr.v1ClipBox(2) != null);
}

test "test_glyphs colr v0 and v1 lookups" {
    const blob = try test_fixture.colrTestGlyphs();
    const colr = try colrFor(blob);

    try testing.expectEqual(@as(u16, 1), colr.version());
    // Glyph 168 is the first COLRv0 base glyph (8 layers).
    const range = colr.v0BaseGlyph(168) orelse return error.TestUnexpectedResult;
    try testing.expectEqual(@as(usize, 0), range.start);
    try testing.expectEqual(@as(usize, 8), range.len);
    const layer = colr.v0Layer(range.start) orelse return error.TestUnexpectedResult;
    try testing.expectEqual(@as(u16, 176), layer.glyph_id);
    try testing.expect(colr.v0BaseGlyph(0) == null);

    // Glyph 8 is the first COLRv1 base glyph (its graph uses many formats);
    // glyph 1 is not a color glyph.
    try testing.expect(colr.v1BaseGlyph(1) == null);
    const paint = colr.v1BaseGlyph(8) orelse return error.TestUnexpectedResult;
    _ = try resolvePaint(paint);
}

test "colr layer and glyph paint formats resolve" {
    const blob = try test_fixture.colrTestGlyphs();
    const colr = try colrFor(blob);

    // Walk every base glyph paint graph and count the formats reached. This
    // exercises ColrLayers, Solid, all gradients, Glyph, ColrGlyph, the
    // transform family (uniform/around-center/skew/rotate/translate), and
    // Composite without depending on any single glyph's layout.
    var formats = std.EnumMap(FormatTag, usize){};
    var listed: usize = 0;
    var gid: u32 = 0;
    while (gid <= 221) : (gid += 1) {
        const paint = colr.v1BaseGlyph(gid) orelse continue;
        listed += 1;
        try walkFormats(colr, paint, &formats, 0);
    }
    try testing.expect(listed > 100);
    inline for (.{ .colr_layers, .solid, .linear_gradient, .radial_gradient, .sweep_gradient, .glyph, .colr_glyph, .transform, .translate, .scale, .rotate, .skew, .composite }) |tag| {
        try testing.expect(formats.get(tag) != null);
    }
}

const FormatTag = enum { colr_layers, solid, linear_gradient, radial_gradient, sweep_gradient, glyph, colr_glyph, transform, translate, scale, rotate, skew, composite };

fn walkFormats(
    colr: Colr,
    paint: Paint,
    formats: *std.EnumMap(FormatTag, usize),
    depth: usize,
) !void {
    if (depth > 32) return;
    const resolved = try resolvePaint(paint);
    const tag: FormatTag = switch (resolved) {
        .colr_layers => .colr_layers,
        .solid => .solid,
        .linear_gradient => .linear_gradient,
        .radial_gradient => .radial_gradient,
        .sweep_gradient => .sweep_gradient,
        .glyph => .glyph,
        .colr_glyph => .colr_glyph,
        .transform => .transform,
        .translate => .translate,
        .scale => .scale,
        .rotate => .rotate,
        .skew => .skew,
        .composite => .composite,
    };
    formats.put(tag, (formats.get(tag) orelse 0) + 1);
    switch (resolved) {
        .colr_layers => |layers| {
            var i: usize = 0;
            while (i < layers.count) : (i += 1) {
                const layer = colr.v1Layer(layers.start + i) orelse continue;
                try walkFormats(colr, layer, formats, depth + 1);
            }
        },
        .glyph => |g| try walkFormats(colr, g.paint, formats, depth + 1),
        .transform => |t| try walkFormats(colr, t.paint, formats, depth + 1),
        .translate => |t| try walkFormats(colr, t.paint, formats, depth + 1),
        .scale => |t| try walkFormats(colr, t.paint, formats, depth + 1),
        .rotate => |t| try walkFormats(colr, t.paint, formats, depth + 1),
        .skew => |t| try walkFormats(colr, t.paint, formats, depth + 1),
        .composite => |c| {
            try walkFormats(colr, c.backdrop_paint, formats, depth + 1);
            try walkFormats(colr, c.source_paint, formats, depth + 1);
        },
        else => {},
    }
}

test "f2dot14 and fixed conversions match font-types" {
    // Values from font-types' own round-trip tests.
    try testing.expectEqual(@as(f32, 1.75), f2dot14ToF32(0x7000));
    try testing.expectEqual(@as(f32, 0.0), f2dot14ToF32(0));
    try testing.expectEqual(@as(f32, -2.0), f2dot14ToF32(@bitCast(@as(u16, 0x8000))));
    // 1.5 in 16.16.
    try testing.expectEqual(@as(f32, 1.5), fixedToF32(0x18000));
    try testing.expectEqual(@as(f32, -1.5), fixedToF32(-0x18000));
}
