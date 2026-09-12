//! TrueType `glyf` outline extraction, bit-exact with `skrifa 0.44.0`.
//!
//! Port of the unhinted `FreeTypeScaler` path in
//! `skrifa/src/outline/glyf/mod.rs`, the `to_path` FreeType conversion in
//! `skrifa/src/outline/path.rs`, and the `read-points-fast` decoding in
//! `read-fonts/src/tables/glyf.rs`.
//!
//! The critical invariant is that scaling runs in fixed point exactly like
//! FreeType/skrifa: glyph coordinates are font-unit `i32`s, the scale factor is
//! a 16.16 `Fixed` (`Fixed::from_bits(trunc(ppem * 64)) / Fixed::from_bits(upem)`
//! with `read-fonts`' round-half-away-from-zero division), points become 26.6
//! `F26Dot6`, phantom points shift the outline (`x_min - lsb`), and only
//! `F26Dot6::to_f32` converts to `f32`. A f32 reimplementation is not
//! bit-identical; see `.ports/vellz/docs/glifo-m3-plan.md` §2.
//!
//! Ported scope: simple glyphs, composite glyphs with transforms and point
//! matching, empty glyphs, phantom-point lsb/advance adjustment,
//! `PathStyle::FreeType`, and the embedded TrueType interpreter
//! (`hint.zig`): hinted scaling (`computeHintedScale`, phantom rounding),
//! `HintOutline` buffers, simple/composite glyf programs and the rounded
//! hinted advance. Hinted outlines are bit-identical to skrifa; any
//! interpreter failure is `error.HintError`, never a silent unhinted draw.
//!
//! Deferred with typed errors: HarfBuzz path style (`error.Unsupported`),
//! non-empty variation coordinates (`error.Unsupported`; `gvar`/`HVAR` deltas
//! are not ported), CFF/bitmap faces (rejected by `font.Font.outlines`),
//! `hdmx` advances outside backward compatibility, and embolden (rejected by
//! the outline cache). Instruction-less fonts (`prefer_interpreter == false`)
//! are drawn by the autohinter through `hinting.zig`; `draw` itself still
//! rejects an interpreter instance for them, so a hinted draw can never
//! silently fall back to unhinted output.

const std = @import("std");

const font_mod = @import("font.zig");
const tables = @import("tables/root.zig");
const sfnt = tables.sfnt;
const raw = tables.glyf;
const Loca = tables.loca.Loca;
const hint_mod = @import("hint.zig");

pub const GlyphId = font_mod.GlyphId;
pub const NormalizedCoord = font_mod.NormalizedCoord;
pub const Font = font_mod.Font;

/// The TrueType interpreter instance (one per font/size/location).
pub const HintInstance = hint_mod.HintInstance;
pub const HintProgram = hint_mod.ProgramData;
pub const HintTarget = hint_mod.Target;
pub const HintSmoothMode = hint_mod.SmoothMode;
/// The configured hinting target glifo uses (see `hint.glifo_target`).
pub const glifo_hint_target = hint_mod.glifo_target;

/// Kept in sync with `skrifa`'s `GLYF_COMPOSITE_RECURSION_LIMIT`.
pub const composite_recursion_limit: usize = 32;
/// Maximum total points in one outline, per the `maxp`/`loca` u16 limits.
pub const max_points: usize = std.math.maxInt(u16);
pub const phantom_point_count: usize = 4;

pub const DrawError = sfnt.Error || error{
    Truncated,
    OutOfBounds,
    MalformedData,
    TooManyPoints,
    RecursionLimitExceeded,
    InvalidAnchorPoint,
    ContourOrder,
    ExpectedQuad,
    ExpectedQuadOrOnCurve,
    ExpectedCubic,
    /// The interpreter rejected the glyph's bytecode. Never approximated:
    /// hinted output is only emitted when the full program ran bit-exactly.
    HintError,
    /// Not ported yet; never approximated.
    Unsupported,
    OutOfMemory,
};

// ---------------------------------------------------------------- fixed point

/// `read-fonts` `Fixed` (16.16) multiplication: round half away from zero.
pub fn fixedMul(a: i32, b: i32) i32 {
    const ab: i64 = @as(i64, a) * @as(i64, b);
    const adjust: i64 = 0x8000 - @as(i64, @intFromBool(ab < 0));
    return @truncate((ab + adjust) >> 16);
}

/// `read-fonts` `Fixed` division: `(au << 16 + bu >> 1) / bu`, sign applied
/// afterwards, `0x7fffffff` when the divisor is zero.
pub fn fixedDiv(a: i32, b: i32) i32 {
    const negative = (a < 0) != (b < 0);
    const au: u64 = @abs(@as(i64, a));
    const bu: u64 = @abs(@as(i64, b));
    const q: u32 = if (bu == 0)
        0x7FFFFFFF
    else
        @truncate(((au << 16) + (bu >> 1)) / bu);
    const bits: i32 = @bitCast(q);
    return if (negative) -%bits else bits;
}

/// `Fixed::to_i32`: `(bits + 0x8000) >> 16` with wrapping add.
pub fn fixedToI32(bits: i32) i32 {
    const wrapped: i32 = @bitCast(@as(u32, @bitCast(bits)) +% 0x8000);
    return wrapped >> 16;
}

/// `F26Dot6::round` (font-types): `(bits + 32) & !63`, wrapping add.
pub fn roundF26Point(bits: i32) i32 {
    return (bits +% 32) & ~@as(i32, 63);
}

/// `F26Dot6::from_i32`: `bits << 6` (high bits discarded, like Rust's shift).
pub fn f26FromI32(value: i32) i32 {
    return @bitCast(@as(u32, @bitCast(value)) << 6);
}

/// `F26Dot6::to_i32`: `(bits + 32) >> 6` with wrapping add.
pub fn f26ToI32(bits: i32) i32 {
    const wrapped: i32 = @bitCast(@as(u32, @bitCast(bits)) +% 32);
    return wrapped >> 6;
}

/// `F26Dot6::to_f32`: `bits as f32 * (1/64)`, the only float conversion in the
/// pipeline.
pub fn f26ToF32(bits: i32) f32 {
    return @as(f32, @floatFromInt(bits)) * (1.0 / 64.0);
}

/// `PointCoord::midpoint` for 26.6 points: `wrapping_add / 2` (truncating).
pub fn f26Midpoint(a: i32, b: i32) i32 {
    return @divTrunc(a +% b, 2);
}

/// Rust `f32 as i32`: saturating, NaN maps to 0, truncation toward zero.
fn saturatingF32ToI32(value: f32) i32 {
    if (std.math.isNan(value)) return 0;
    if (value >= 2147483648.0) return std.math.maxInt(i32);
    if (value < -2147483648.0) return std.math.minInt(i32);
    return @intFromFloat(value);
}

/// `Scale26Dot6`: converts font units to 26.6 pixels.
pub const Scale26Dot6 = struct {
    scale_bits: i32,
    is_scaled: bool,

    pub fn init(ppem: ?f32, units_per_em: u16) Scale26Dot6 {
        if (ppem) |size| {
            if (units_per_em > 0) {
                return .{
                    .scale_bits = fixedDiv(
                        saturatingF32ToI32(size * 64.0),
                        @as(i32, units_per_em),
                    ),
                    .is_scaled = true,
                };
            }
        }
        return .{ .scale_bits = 0x10000, .is_scaled = false };
    }

    /// `Scale26Dot6::apply`: font-unit value to `F26Dot6` bits.
    pub fn apply(self: Scale26Dot6, value: i32) i32 {
        return fixedMul(value, self.scale_bits);
    }

    /// `Scale26Dot6::mul`: `F26Dot6` bits to scaled `F26Dot6` bits.
    pub fn mul(self: Scale26Dot6, value: i32) i32 {
        return fixedMul(value, self.scale_bits);
    }
};

/// Rust `f64 as i32`: saturating, NaN maps to 0, truncation toward zero.
fn saturatingF64ToI32(value: f64) i32 {
    if (std.math.isNan(value)) return 0;
    if (value >= 2147483648.0) return std.math.maxInt(i32);
    if (value < -2147483648.0) return std.math.minInt(i32);
    return @intFromFloat(value);
}

/// `F26Dot6::from_f64(ppem).round().to_f32()`: the ppem quantization applied
/// when the font does not support fractional scaling (head bit 3 unset).
fn roundPpemForHinting(ppem: f32) f32 {
    const frac: f64 = (if (std.math.signbit(ppem)) @as(f64, 0.0) else @as(f64, 1.0)) - 0.5;
    const bits = saturatingF64ToI32(@as(f64, ppem) * 64.0 + frac);
    const rounded = (bits +% 32) & ~@as(i32, 63);
    return @as(f32, @floatFromInt(rounded)) * (1.0 / 64.0);
}

pub const PointI32 = hint_mod.Point;
pub const Point26 = hint_mod.Point;

/// Emitted path style; only `FreeType` is ported.
pub const PathStyle = enum {
    freetype,
    harfbuzz,
};

pub const DrawSettings = struct {
    /// Pixel size; `null` means unscaled (font units in 26.6).
    size: ?f32 = null,
    /// Normalized variation coordinates. Non-empty is `error.Unsupported`
    /// until `gvar`/`HVAR` deltas land.
    coords: []const NormalizedCoord = &.{},
    path_style: PathStyle = .freetype,
    /// Hinting instance already configured for `size` (glifo's `HintCache`
    /// owns it). `null` draws unhinted. The instance is ignored when
    /// `is_enabled()` is false, matching `skrifa`'s `OutlineGlyph::draw`.
    hint_instance: ?*const hint_mod.HintInstance = null,
    /// Enables the interpreter's pedantic error checking.
    pedantic_hinting: bool = false,
};

/// Mirrors `skrifa::outline::AdjustedMetrics` (only the fields the `glyf`
/// scaler can produce).
pub const AdjustedMetrics = struct {
    has_overlaps: bool,
    lsb: ?f32,
    advance_width: ?f32,
};

/// Information needed to scale one glyph; mirrors `skrifa`'s `Outline`.
pub const Outline = struct {
    glyph_id: GlyphId,
    glyph: ?raw.Glyph = null,
    /// Sum of the point counts of all simple glyphs in the outline.
    points: usize = 0,
    /// Sum of the contour counts of all simple glyphs in the outline.
    contours: usize = 0,
    max_simple_points: usize = 0,
    max_other_points: usize = 0,
    has_hinting: bool = false,
    has_overlaps: bool = false,
};

/// The `glyf` scaler for one face.
pub const Outlines = struct {
    font: Font,
    loca: Loca,
    glyf_data: []const u8,
    upem: u16,
    glyph_count: u16,
    /// `fpgm`/`prep`/`cvt` plus the `maxp` interpreter limits (M3 hinting).
    program: hint_mod.ProgramData = .{},
    /// OS/2 `sTypoAscender`/`sTypoDescender` (0 without the table), used for
    /// the vertical phantom points.
    ascent: i32 = 0,
    descent: i32 = 0,
    /// `head` bit 3 unset: fractional ppem is rounded before hinting.
    fractional_size_hinting: bool = true,
    /// True when the font carries bytecode (`fpgm`/`prep`/maxp instructions).
    /// `Engine::AutoFallback` (`hinting.zig`) selects the interpreter only
    /// for these fonts and the autohinter otherwise.
    prefer_interpreter: bool = false,
    /// The font carries `hdmx` width records; hinted advances would need them
    /// (not ported), so hinting such fonts is a typed error.
    has_hdmx: bool = false,

    pub fn init(
        font: Font,
        head: tables.head.Head,
        maxp: tables.maxp.Maxp,
        loca_data: []const u8,
        glyf_data: []const u8,
    ) Outlines {
        const fpgm = font.face.table(sfnt.tag_fpgm) orelse &.{};
        const prep = font.face.table(sfnt.tag_prep) orelse &.{};
        const cvt = font.face.table(sfnt.tag_cvt) orelse &.{};
        var ascent: i32 = 0;
        var descent: i32 = 0;
        if (font.face.table(sfnt.tag_os2)) |os2| {
            ascent = sfnt.readI16(os2, 68) orelse 0;
            descent = sfnt.readI16(os2, 70) orelse 0;
        }
        const max_instructions: u16 = maxp.maxSizeOfInstructions() orelse 0;
        return .{
            .font = font,
            .loca = Loca.parse(loca_data, head.indexToLocFormat() == 1),
            .glyf_data = glyf_data,
            .upem = head.unitsPerEm(),
            .glyph_count = maxp.numGlyphs(),
            .program = .{
                .fpgm = fpgm,
                .prep = prep,
                .cvt = cvt,
                .max_function_defs = maxp.maxFunctionDefs() orelse 0,
                .max_instruction_defs = maxp.maxInstructionDefs() orelse 0,
                // +4 phantom points, saturating like upstream.
                .max_twilight_points = (maxp.maxTwilightPoints() orelse 0) +| 4,
                // FreeType heuristic for buggy fonts: +32 stack elements.
                .max_stack_elements = (maxp.maxStackElements() orelse 0) +| 32,
                .max_storage = maxp.maxStorage() orelse 0,
                .axis_count = 0,
            },
            .ascent = ascent,
            .descent = descent,
            .fractional_size_hinting = !head.forceIntegerPpem(),
            .prefer_interpreter = !(max_instructions == 0 and fpgm.len == 0 and prep.len == 0),
            .has_hdmx = font.face.table(sfnt.tag_hdmx) != null,
        };
    }

    pub fn glyphCount(self: *const Outlines) usize {
        return self.glyph_count;
    }

    /// An empty outline collection for faces without a `glyf` table
    /// (bitmap-only faces). Every lookup reports `error.OutOfBounds`, which
    /// the draw loop treats as "skip this glyph", matching upstream's
    /// `outline_glyphs().get()` returning `None`.
    pub fn empty(font: Font) Outlines {
        return .{
            .font = font,
            .loca = Loca.parse(&.{}, false),
            .glyf_data = &.{},
            .upem = font.unitsPerEm(),
            .glyph_count = font.numGlyphs(),
        };
    }

    pub fn unitsPerEm(self: *const Outlines) u16 {
        return self.upem;
    }

    pub fn computeScale(self: *const Outlines, ppem: ?f32) Scale26Dot6 {
        return Scale26Dot6.init(ppem, self.upem);
    }

    /// `skrifa::outline::glyf::Outlines::compute_hinted_scale`: rounds ppem
    /// through 26.6 when the font does not support fractional scaling.
    pub fn computeHintedScale(self: *const Outlines, ppem: ?f32) Scale26Dot6 {
        if (ppem) |size| {
            if (!self.fractional_size_hinting) {
                return self.computeScale(roundPpemForHinting(size));
            }
        }
        return self.computeScale(ppem);
    }

    /// The `(scale, rounded_ppem)` pair `HintingInstance::reconfigure` derives
    /// from the hinted scale, exactly as skrifa does.
    pub fn hintedScaleAndPpem(self: *const Outlines, size: f32) struct { scale: i32, ppem: i32 } {
        const scale = self.computeHintedScale(size).scale_bits;
        const ppem = (fixedMul(scale, @as(i32, self.upem)) +% 32) >> 6;
        return .{ .scale = scale, .ppem = ppem };
    }

    /// Builds and configures a `HintInstance` for this face (runs `fpgm` and
    /// `prep`). Callers own the instance through glifo's `HintCache`.
    pub fn createHintInstance(
        self: *const Outlines,
        allocator: std.mem.Allocator,
        size: f32,
        target: hint_mod.Target,
    ) DrawError!hint_mod.HintInstance {
        var instance = hint_mod.HintInstance.init(allocator);
        errdefer instance.deinit();
        const sp = self.hintedScaleAndPpem(size);
        instance.reconfigure(self.program, sp.scale, sp.ppem, target, &.{}, size) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.HintError,
        };
        return instance;
    }

    pub fn getGlyph(self: *const Outlines, gid: GlyphId) DrawError!?raw.Glyph {
        const bytes = try self.loca.glyphBytes(gid, self.glyf_data);
        if (bytes) |data| return try raw.Glyph.parse(data);
        return null;
    }

    /// Collects the point/contour totals for a glyph (and its components).
    pub fn outline(self: *const Outlines, gid: GlyphId) DrawError!Outline {
        var result = Outline{ .glyph_id = gid };
        const glyph = try self.getGlyph(gid);
        if (glyph) |g| try self.outlineRec(g, &result, 0);
        result.glyph = glyph;
        return result;
    }

    fn outlineRec(
        self: *const Outlines,
        glyph: raw.Glyph,
        result: *Outline,
        recurse_depth: usize,
    ) DrawError!void {
        if (recurse_depth > composite_recursion_limit) {
            return error.RecursionLimitExceeded;
        }
        switch (glyph.kind) {
            .simple => {
                const simple = glyph.simple();
                const num_points = simple.numPoints();
                result.max_simple_points = @max(result.max_simple_points, num_points + 4);
                result.points += num_points;
                result.contours += simple.contourCount();
                result.has_hinting = result.has_hinting or simple.instructionLength() != 0;
                result.max_other_points = @max(result.max_other_points, num_points + 4);
                result.has_overlaps = result.has_overlaps or simple.hasOverlappingContours();
            },
            .composite => {
                const composite = glyph.composite();
                const point_base = result.points;
                var it = composite.componentIterator();
                while (it.next()) |component| {
                    result.has_overlaps = result.has_overlaps or
                        (component.flags & raw.composite_overlap_compound) != 0;
                    const component_glyph = try self.getGlyph(component.glyph);
                    if (component_glyph) |cg| {
                        try self.outlineRec(cg, result, recurse_depth + 1);
                    }
                }
                const count_and_instructions = composite.countAndInstructions();
                const has_hinting = if (count_and_instructions.instructions) |ins|
                    ins.len != 0
                else
                    false;
                if (has_hinting) {
                    const num_points_in_composite = result.points - point_base + 4;
                    result.max_other_points = @max(
                        result.max_other_points,
                        num_points_in_composite,
                    );
                }
                result.has_hinting = result.has_hinting or has_hinting;
            },
        }
    }

    /// Scales one glyph and emits the FreeType path into `pen`.
    ///
    /// The pen is duck-typed (`pen.zig` provides `PathElementPen` and
    /// `PathPen`); its methods take f32 coordinates and may fail with an
    /// allocation error, which is why this entry point returns an error union.
    ///
    /// When `settings.hint_instance` is set, the TrueType interpreter runs
    /// (`fpgm`/`prep` during instance configuration, the glyph program here);
    /// any interpreter failure is reported as `error.HintError` instead of
    /// being swallowed, so a hinted outline is never approximated by an
    /// unhinted one.
    pub fn draw(
        self: *const Outlines,
        allocator: std.mem.Allocator,
        gid: GlyphId,
        settings: DrawSettings,
        pen: anytype,
    ) DrawError!AdjustedMetrics {
        if (settings.coords.len != 0) return error.Unsupported;
        switch (settings.path_style) {
            .freetype => {},
            .harfbuzz => return error.Unsupported,
        }
        var hint_instance: ?*const hint_mod.HintInstance = null;
        if (settings.hint_instance) |instance| {
            if (instance.isEnabled()) {
                if (!self.prefer_interpreter) {
                    // `Engine::AutoFallback` chooses the autohinter for this
                    // font (`hinting.zig`); an interpreter instance here
                    // would be a configuration bug, never a silent unhinted
                    // draw.
                    return error.Unsupported;
                }
                // `hdmx` advances are only consulted when backward
                // compatibility is off; that path is not ported, so gate it.
                if (self.has_hdmx and !instance.backwardCompatibility()) {
                    return error.Unsupported;
                }
                hint_instance = instance;
            } else {
                // Upstream draws unhinted at the instance's size and rounds
                // the advance.
                var metrics = try self.draw(allocator, gid, .{
                    .size = instance.size,
                    .coords = settings.coords,
                    .path_style = settings.path_style,
                }, pen);
                if (metrics.advance_width) |advance| {
                    metrics.advance_width = @round(advance);
                }
                return metrics;
            }
        }
        const info = try self.outline(gid);
        if (info.points > max_points) return error.TooManyPoints;
        var scaler = try Scaler.init(
            allocator,
            self,
            &info,
            settings.size,
            hint_instance,
            settings.pedantic_hinting,
        );
        defer scaler.deinit();

        try scaler.load(info.glyph, gid, 0);

        const phantom = scaler.phantom;
        const x_shift = phantom[0].x;
        if (x_shift != 0) {
            for (scaler.scaled.items[0..scaler.point_count]) |*point| {
                point.x = point.x -% x_shift;
            }
        }
        try contourToPath(
            scaler.scaled.items[0..scaler.point_count],
            scaler.flags.items[0..scaler.point_count],
            scaler.contours.items,
            .freetype,
            pen,
        );
        const advance = phantom[1].x -% phantom[0].x;
        // `HintingInstance::draw` rounds the advance when hinting is applied.
        const final_advance = if (hint_instance != null) roundF26Point(advance) else advance;
        return .{
            .has_overlaps = info.has_overlaps,
            .lsb = f26ToF32(phantom[0].x),
            .advance_width = f26ToF32(final_advance),
        };
    }

    /// `OutlineGlyph::draw_unscaled` for `glyf`: runs the unhinted FreeType
    /// scaler with no ppem and pushes raw font-unit points into `sink`.
    ///
    /// `sink` is duck-typed and must provide `tryReserve(usize) DrawError!void`
    /// and `push(UnscaledSinkPoint) DrawError!void`. Returns the adjusted
    /// advance width in font units (`>> 6`), like upstream.
    pub fn drawUnscaled(
        self: *const Outlines,
        allocator: std.mem.Allocator,
        gid: GlyphId,
        sink: anytype,
    ) DrawError!i32 {
        const info = try self.outline(gid);
        if (info.points > max_points) return error.TooManyPoints;
        var scaler = try Scaler.init(allocator, self, &info, null, null, false);
        defer scaler.deinit();
        try scaler.load(info.glyph, gid, 0);
        try sink.tryReserve(scaler.point_count);
        var contour_start: usize = 0;
        for (scaler.contours.items) |contour_end_raw| {
            const contour_end: usize = contour_end_raw;
            if (contour_end >= contour_start) {
                var ix = contour_start;
                while (ix <= contour_end) : (ix += 1) {
                    const point = scaler.scaled.items[ix];
                    try sink.push(.{
                        .x = @truncate(point.x >> 6),
                        .y = @truncate(point.y >> 6),
                        .flags = scaler.flags.items[ix] & raw.flag_on_curve_point,
                        .is_contour_start = ix == contour_start,
                    });
                }
            }
            contour_start = contour_end + 1;
        }
        const advance = scaler.phantom[1].x -% scaler.phantom[0].x;
        return advance >> 6;
    }
};

/// One raw unscaled outline point for the autohinter (`UnscaledPoint`).
pub const UnscaledSinkPoint = struct {
    /// Font-unit coordinate (`F26Dot6` bits >> 6, truncated to `i16`).
    x: i16,
    y: i16,
    /// On-curve/cubic flags with markers removed.
    flags: u8,
    /// True for the first point of a contour.
    is_contour_start: bool,
};

/// State for one outline load. Mirrors `skrifa`'s `FreeTypeScaler`.
const Scaler = struct {
    outlines: *const Outlines,
    allocator: std.mem.Allocator,
    scale: Scale26Dot6,
    point_count: usize = 0,
    contour_count: usize = 0,
    phantom: [phantom_point_count]Point26 = .{
        .{ .x = 0, .y = 0 },
        .{ .x = 0, .y = 0 },
        .{ .x = 0, .y = 0 },
        .{ .x = 0, .y = 0 },
    },
    scaled: std.ArrayList(Point26) = .empty,
    unscaled: std.ArrayList(PointI32) = .empty,
    contours: std.ArrayList(u16) = .empty,
    flags: std.ArrayList(u8) = .empty,
    // M3 hinting state. The interpreter buffers are only allocated when
    // `is_hinted` so unhinted draws keep the old behavior (and the old
    // allocations/leak profile).
    hint_instance: ?*const hint_mod.HintInstance = null,
    is_hinted: bool = false,
    pedantic_hinting: bool = false,
    stack: std.ArrayList(i32) = .empty,
    cvt: std.ArrayList(i32) = .empty,
    storage: std.ArrayList(i32) = .empty,
    twilight_scaled: std.ArrayList(Point26) = .empty,
    twilight_original: std.ArrayList(Point26) = .empty,
    twilight_flags: std.ArrayList(u8) = .empty,
    original_scaled: std.ArrayList(Point26) = .empty,
    unscaled_copy: std.ArrayList(Point26) = .empty,

    fn init(
        allocator: std.mem.Allocator,
        outlines: *const Outlines,
        outline: *const Outline,
        ppem: ?f32,
        hint_instance: ?*const hint_mod.HintInstance,
        pedantic_hinting: bool,
    ) DrawError!Scaler {
        var scaler = Scaler{
            .outlines = outlines,
            .allocator = allocator,
            .scale = if (hint_instance != null)
                outlines.computeHintedScale(ppem)
            else
                outlines.computeScale(ppem),
            .hint_instance = hint_instance,
            .pedantic_hinting = pedantic_hinting,
        };
        scaler.is_hinted = hint_instance != null and scaler.scale.is_scaled;
        errdefer scaler.deinit();
        const other_capacity = @max(
            @max(outline.max_simple_points, outline.max_other_points),
            phantom_point_count,
        );
        try scaler.scaled.ensureTotalCapacity(allocator, outline.points + phantom_point_count);
        try scaler.unscaled.ensureTotalCapacity(allocator, other_capacity);
        try scaler.flags.ensureTotalCapacity(allocator, outline.points + phantom_point_count);
        try scaler.contours.ensureTotalCapacity(allocator, outline.contours);
        if (scaler.is_hinted) {
            const program = outlines.program;
            try scaler.stack.resize(allocator, program.max_stack_elements);
            try scaler.cvt.resize(allocator, program.cvtLen());
            @memset(scaler.cvt.items, 0);
            try scaler.storage.resize(allocator, program.max_storage);
            @memset(scaler.storage.items, 0);
            try scaler.twilight_scaled.resize(allocator, program.max_twilight_points);
            try scaler.twilight_original.resize(allocator, program.max_twilight_points);
            for (scaler.twilight_scaled.items) |*p| p.* = .{};
            for (scaler.twilight_original.items) |*p| p.* = .{};
            try scaler.twilight_flags.resize(allocator, program.max_twilight_points);
            @memset(scaler.twilight_flags.items, 0);
            // Component-local scratch buffers for the interpreter input.
            try scaler.original_scaled.resize(allocator, other_capacity);
            try scaler.unscaled_copy.resize(allocator, other_capacity);
        }
        return scaler;
    }

    fn deinit(self: *Scaler) void {
        self.scaled.deinit(self.allocator);
        self.unscaled.deinit(self.allocator);
        self.contours.deinit(self.allocator);
        self.flags.deinit(self.allocator);
        self.stack.deinit(self.allocator);
        self.cvt.deinit(self.allocator);
        self.storage.deinit(self.allocator);
        self.twilight_scaled.deinit(self.allocator);
        self.twilight_original.deinit(self.allocator);
        self.twilight_flags.deinit(self.allocator);
        self.original_scaled.deinit(self.allocator);
        self.unscaled_copy.deinit(self.allocator);
        self.* = undefined;
    }

    /// Runs the glyf program for one hint input; interpreter errors are
    /// surfaced as `error.HintError` (never swallowed).
    fn runHint(self: *Scaler, input: *hint_mod.HintOutline) DrawError!void {
        const hinter = self.hint_instance orelse return;
        hinter.hint(self.outlines.program, input, self.pedantic_hinting) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.HintError,
        };
    }

    /// `Scaler::load`: sets up phantom points, then dispatches.
    fn load(
        self: *Scaler,
        glyph: ?raw.Glyph,
        gid: GlyphId,
        recurse_depth: usize,
    ) DrawError!void {
        if (recurse_depth > composite_recursion_limit) {
            return error.RecursionLimitExceeded;
        }
        const bounds: [4]i16 = if (glyph) |g| g.bounds() else .{ 0, 0, 0, 0 };
        const lsb = self.outlines.font.lsb(gid);
        const advance = self.outlines.font.advanceWidth(gid);
        self.setupPhantomPoints(bounds, lsb, advance);
        if (glyph) |g| {
            switch (g.kind) {
                .simple => try self.loadSimple(g.simple(), gid),
                .composite => try self.loadComposite(g.composite(), gid, recurse_depth),
            }
        } else {
            try self.loadEmpty();
        }
    }

    /// The four "phantom" points as computed by FreeType.
    ///
    /// Points 0/1 shift the outline and produce the adjusted lsb/advance;
    /// points 2/3 come from the OS/2 vertical metrics and participate in the
    /// interpreter's glyph zone.
    fn setupPhantomPoints(self: *Scaler, bounds: [4]i16, lsb: i32, advance: i32) void {
        self.phantom[0].x = bounds[0] - lsb;
        self.phantom[0].y = 0;
        self.phantom[1].x = self.phantom[0].x +% advance;
        self.phantom[1].y = 0;
        const ascent = self.outlines.ascent;
        const descent = self.outlines.descent;
        const tsb = ascent - @as(i32, bounds[3]);
        const vadvance = ascent - descent;
        self.phantom[2].x = 0;
        self.phantom[2].y = @as(i32, bounds[3]) +% tsb;
        self.phantom[3].x = 0;
        self.phantom[3].y = self.phantom[2].y -% vadvance;
    }

    fn loadEmpty(self: *Scaler) DrawError!void {
        if (self.scale.is_scaled) {
            for (0..phantom_point_count) |i| {
                self.phantom[i] = self.scalePoint(self.phantom[i]);
            }
        } else {
            for (0..phantom_point_count) |i| {
                self.phantom[i] = .{
                    .x = f26FromI32(self.phantom[i].x),
                    .y = f26FromI32(self.phantom[i].y),
                };
            }
        }
    }

    fn scalePoint(self: Scaler, point: Point26) Point26 {
        return .{ .x = self.scale.mul(point.x), .y = self.scale.mul(point.y) };
    }

    fn loadSimple(self: *Scaler, glyph: raw.SimpleGlyph, gid: GlyphId) DrawError!void {
        const points_start = self.point_count;
        const point_count = glyph.numPoints();
        const phantom_start = point_count;
        const points_end = points_start + point_count + phantom_point_count;

        try self.scaled.resize(self.allocator, points_end);
        try self.flags.resize(self.allocator, points_end);
        try self.unscaled.resize(
            self.allocator,
            @max(self.unscaled.items.len, point_count + phantom_point_count),
        );
        const unscaled = self.unscaled.items[0 .. point_count + phantom_point_count];
        // Scratch memory upstream leaves at zero; keep deterministic.
        @memset(self.flags.items[points_start..points_end], 0);

        try readPointsFast(
            glyph.glyphData(),
            unscaled[0..point_count],
            self.flags.items[points_start..points_end],
        );

        const contour_count = glyph.contourCount();
        var contour_index: usize = 0;
        var last_end_pt: u16 = 0;
        while (contour_index < contour_count) : (contour_index += 1) {
            const end_pt = glyph.endPoint(contour_index).?;
            if (end_pt < last_end_pt) return error.MalformedData;
            last_end_pt = end_pt;
            try self.contours.append(self.allocator, end_pt);
        }
        self.point_count += point_count;
        self.contour_count += contour_count;

        var i: usize = 0;
        while (i < phantom_point_count) : (i += 1) {
            unscaled[phantom_start + i] = .{ .x = self.phantom[i].x, .y = self.phantom[i].y };
        }

        if (self.scale.is_scaled) {
            for (unscaled, 0..) |point, ix| {
                self.scaled.items[points_start + ix] = .{
                    .x = self.scale.apply(point.x),
                    .y = self.scale.apply(point.y),
                };
            }
        } else {
            for (unscaled, 0..) |point, ix| {
                self.scaled.items[points_start + ix] = .{
                    .x = f26FromI32(point.x),
                    .y = f26FromI32(point.y),
                };
            }
        }
        for (0..phantom_point_count) |phantom_ix| {
            self.phantom[phantom_ix] = self.scaled.items[points_start + phantom_start + phantom_ix];
        }

        // Hint this glyph (or component) if the font's program is active for
        // it. Upstream never hints when instructions are missing, but still
        // rounds the phantom points when backward compatibility is off.
        const instructions = glyph.instructions();
        if (self.is_hinted) {
            const hinter = self.hint_instance.?;
            const contours_local =
                self.contours.items[self.contour_count - contour_count .. self.contour_count];
            if (instructions.len != 0) {
                const local_len = point_count + phantom_point_count;
                const scaled = self.scaled.items[points_start..points_end];
                const flags = self.flags.items[points_start..points_end];
                @memcpy(self.original_scaled.items[0..local_len], scaled);
                for (scaled[phantom_start..]) |*point| {
                    point.x = roundF26Point(point.x);
                    point.y = roundF26Point(point.y);
                }
                var input = hint_mod.HintOutline{
                    .glyph_id = gid,
                    .unscaled = unscaled,
                    .scaled = scaled,
                    .original_scaled = self.original_scaled.items[0..local_len],
                    .flags = flags,
                    .contours = contours_local,
                    .phantom = self.phantom[0..],
                    .bytecode = instructions,
                    .stack = self.stack.items,
                    .cvt = self.cvt.items,
                    .storage = self.storage.items,
                    .twilight_scaled = self.twilight_scaled.items,
                    .twilight_original_scaled = self.twilight_original.items,
                    .twilight_flags = self.twilight_flags.items,
                    .is_composite = false,
                    .coords = &.{},
                };
                try self.runHint(&input);
            } else if (!hinter.backwardCompatibility()) {
                for (self.scaled.items[points_start + phantom_start .. points_end]) |*point| {
                    point.x = roundF26Point(point.x);
                    point.y = roundF26Point(point.y);
                }
            }
        }

        if (points_start != 0) {
            for (self.contours.items[self.contour_count - contour_count ..]) |*contour_end| {
                contour_end.* +%= @truncate(points_start);
            }
        }
    }

    fn loadComposite(
        self: *Scaler,
        glyph: raw.CompositeGlyph,
        gid: GlyphId,
        recurse_depth: usize,
    ) DrawError!void {
        const point_base = self.point_count;
        const contour_base = self.contour_count;
        if (self.scale.is_scaled) {
            for (0..phantom_point_count) |i| {
                self.phantom[i] = self.scalePoint(self.phantom[i]);
            }
        } else {
            for (0..phantom_point_count) |i| {
                self.phantom[i] = .{
                    .x = f26FromI32(self.phantom[i].x),
                    .y = f26FromI32(self.phantom[i].y),
                };
            }
        }

        var it = glyph.componentIterator();
        while (it.next()) |component| {
            const saved_phantom = self.phantom;
            const start_point = self.point_count;
            const component_glyph = try self.outlines.getGlyph(component.glyph);
            try self.load(component_glyph, component.glyph, recurse_depth + 1);
            const end_point = self.point_count;
            if ((component.flags & raw.composite_use_my_metrics) == 0) {
                self.phantom = saved_phantom;
            }

            const xx = fixedFromF2Dot14(component.transform.xx);
            const yx = fixedFromF2Dot14(component.transform.yx);
            const xy = fixedFromF2Dot14(component.transform.xy);
            const yy = fixedFromF2Dot14(component.transform.yy);
            const have_xform = (component.flags & (raw.composite_we_have_a_scale |
                raw.composite_we_have_an_x_and_y_scale |
                raw.composite_we_have_a_two_by_two)) != 0;
            if (have_xform) {
                if (self.scale.is_scaled) {
                    for (self.scaled.items[start_point..end_point]) |*point| {
                        const x = fixedMul(point.x, xx) +% fixedMul(point.y, xy);
                        const y = fixedMul(point.x, yx) +% fixedMul(point.y, yy);
                        point.* = .{ .x = x, .y = y };
                    }
                } else {
                    for (self.scaled.items[start_point..end_point]) |*point| {
                        const unscaled_x = f26ToI32(point.x);
                        const unscaled_y = f26ToI32(point.y);
                        const x = fixedMul(unscaled_x, xx) +% fixedMul(unscaled_y, xy);
                        const y = fixedMul(unscaled_x, yx) +% fixedMul(unscaled_y, yy);
                        point.* = .{ .x = f26FromI32(x), .y = f26FromI32(y) };
                    }
                }
            }

            const anchor_offset: Point26 = switch (component.anchor) {
                .offset => |offset| blk: {
                    var x: i32 = offset.x;
                    var y: i32 = offset.y;
                    if (have_xform and
                        (component.flags & (raw.composite_scaled_component_offset |
                            raw.composite_unscaled_component_offset)) ==
                            raw.composite_scaled_component_offset)
                    {
                        x = fixedMul(x, hypotFixed(xx, xy));
                        y = fixedMul(y, hypotFixed(yy, yx));
                    }
                    if (self.scale.is_scaled) {
                        var scaled_offset = Point26{
                            .x = self.scale.apply(x),
                            .y = self.scale.apply(y),
                        };
                        // ROUND_XY_TO_GRID only applies when hinting, and
                        // only the y coordinate is rounded (FreeType).
                        if (self.is_hinted and
                            (component.flags & raw.composite_round_xy_to_grid) != 0)
                        {
                            scaled_offset.y = roundF26Point(scaled_offset.y);
                        }
                        break :blk scaled_offset;
                    }
                    break :blk .{ .x = f26FromI32(x), .y = f26FromI32(y) };
                },
                .point => |anchor| blk: {
                    const base_index = point_base + anchor.base;
                    const component_index = start_point + anchor.component;
                    if (base_index >= self.scaled.items.len or
                        component_index >= self.scaled.items.len)
                    {
                        return error.InvalidAnchorPoint;
                    }
                    const base_point = self.scaled.items[base_index];
                    const component_point = self.scaled.items[component_index];
                    break :blk .{
                        .x = base_point.x -% component_point.x,
                        .y = base_point.y -% component_point.y,
                    };
                },
            };
            if (anchor_offset.x != 0 or anchor_offset.y != 0) {
                for (self.scaled.items[start_point..end_point]) |*point| {
                    point.x +%= anchor_offset.x;
                    point.y +%= anchor_offset.y;
                }
            }
        }
        // Composite glyph programs run over the accumulated component points
        // plus the phantom points; `unscaled` and `original_scaled` are copies
        // of the current scaled point set and contours are made relative to
        // the composite's point base.
        if (self.is_hinted) {
            const instructions = glyph.countAndInstructions().instructions orelse &.{};
            if (instructions.len != 0) {
                const end_point = self.point_count + phantom_point_count;
                const range_len = end_point - point_base;
                if (range_len > self.original_scaled.items.len or
                    range_len > self.unscaled_copy.items.len)
                {
                    return error.OutOfMemory;
                }
                const scaled = self.scaled.items[point_base..end_point];
                const flags = self.flags.items[point_base..end_point];
                const phantom_start = range_len - phantom_point_count;
                for (0..phantom_point_count) |i| {
                    scaled[phantom_start + i] = self.phantom[i];
                    flags[phantom_start + i] = 0;
                }
                for (scaled, 0..) |point, ix| {
                    self.unscaled_copy.items[ix] = point;
                }
                @memcpy(self.original_scaled.items[0..range_len], scaled);
                for (scaled[phantom_start..]) |*point| {
                    point.x = roundF26Point(point.x);
                    point.y = roundF26Point(point.y);
                }
                // Clear the "touched" flags used during IUP processing.
                for (flags) |*flag| flag.* &= ~hint_mod.marker_touched;
                const contours_local = self.contours.items[contour_base..self.contour_count];
                if (point_base != 0) {
                    const delta: u16 = @truncate(point_base);
                    for (contours_local) |*contour_end| contour_end.* -%= delta;
                }
                var input = hint_mod.HintOutline{
                    .glyph_id = gid,
                    .unscaled = self.unscaled_copy.items[0..range_len],
                    .scaled = scaled,
                    .original_scaled = self.original_scaled.items[0..range_len],
                    .flags = flags,
                    .contours = contours_local,
                    .phantom = self.phantom[0..],
                    .bytecode = instructions,
                    .stack = self.stack.items,
                    .cvt = self.cvt.items,
                    .storage = self.storage.items,
                    .twilight_scaled = self.twilight_scaled.items,
                    .twilight_original_scaled = self.twilight_original.items,
                    .twilight_flags = self.twilight_flags.items,
                    .is_composite = true,
                    .coords = &.{},
                };
                try self.runHint(&input);
                if (point_base != 0) {
                    const delta: u16 = @truncate(point_base);
                    for (contours_local) |*contour_end| contour_end.* +%= delta;
                }
            }
        }
    }
};

fn fixedFromF2Dot14(value: i16) i32 {
    return @as(i32, value) * 4;
}

/// FreeType's `hypot` guess used for scaled component offsets.
fn hypotFixed(a: i32, b: i32) i32 {
    const abs_a: i32 = @intCast(@abs(a));
    const abs_b: i32 = @intCast(@abs(b));
    return if (abs_a > abs_b)
        abs_a +% ((3 *% abs_b) >> 3)
    else
        abs_b +% ((3 *% abs_a) >> 3);
}

/// `SimpleGlyph::read_points_fast` for `Point<i32>` (font units) plus raw
/// flag bytes (masked to the on-curve bit, matching read-fonts with
/// `spec_next` disabled).
fn readPointsFast(
    glyph_data: []const u8,
    points: []PointI32,
    flags: []u8,
) DrawError!void {
    const n_points = points.len;
    if (flags.len < n_points) return error.MalformedData;
    if (n_points == 0) return;

    var flag_cursor: usize = 0;
    var read_flags_bytes: usize = 0;
    var i: usize = 0;
    while (flag_cursor < glyph_data.len) {
        const flag_bits = glyph_data[flag_cursor];
        flag_cursor += 1;
        read_flags_bytes += 1;
        if ((flag_bits & raw.flag_repeat) != 0) {
            if (flag_cursor >= glyph_data.len) return error.Truncated;
            const repeat = glyph_data[flag_cursor];
            flag_cursor += 1;
            read_flags_bytes += 1;
            const remaining = n_points - i;
            const count = @min(@as(usize, repeat) + 1, remaining);
            for (flags[i .. i + count]) |*flag| flag.* = flag_bits;
            i += count;
        } else {
            flags[i] = flag_bits;
            i += 1;
        }
        if (i == n_points) break;
    }
    if (i < n_points) return error.Truncated;

    var cursor = read_flags_bytes;
    var x: i32 = 0;
    for (flags[0..n_points], points) |flag, *point| {
        var delta: i32 = 0;
        if ((flag & raw.flag_x_short_vector) != 0) {
            if (cursor >= glyph_data.len) return error.Truncated;
            delta = glyph_data[cursor];
            cursor += 1;
            if ((flag & raw.flag_x_same_or_positive) == 0) delta = -delta;
        } else if ((flag & raw.flag_x_same_or_positive) == 0) {
            const value = sfnt.readI16(glyph_data, cursor) orelse return error.Truncated;
            delta = value;
            cursor += 2;
        }
        x +%= delta;
        point.x = x;
    }
    var y: i32 = 0;
    for (flags[0..n_points], points) |flag, *point| {
        var delta: i32 = 0;
        if ((flag & raw.flag_y_short_vector) != 0) {
            if (cursor >= glyph_data.len) return error.Truncated;
            delta = glyph_data[cursor];
            cursor += 1;
            if ((flag & raw.flag_y_same_or_positive) == 0) delta = -delta;
        } else if ((flag & raw.flag_y_same_or_positive) == 0) {
            const value = sfnt.readI16(glyph_data, cursor) orelse return error.Truncated;
            delta = value;
            cursor += 2;
        }
        y +%= delta;
        point.y = y;
    }
    // Drop every bit except on-curve (read-fonts without `spec_next`).
    for (flags[0..n_points]) |*flag| flag.* &= raw.flag_on_curve_point;
}

// ------------------------------------------------------------ path conversion

pub const PathContourPoint = struct {
    x: i32,
    y: i32,
    flags: u8,

    fn isOnCurve(self: PathContourPoint) bool {
        return (self.flags & raw.flag_on_curve_point) != 0;
    }

    fn isOffCurveQuad(self: PathContourPoint) bool {
        return (self.flags & (raw.flag_on_curve_point | raw.flag_cubic)) == 0;
    }

    fn isOffCurveCubic(self: PathContourPoint) bool {
        return (self.flags & raw.flag_cubic) != 0;
    }

    fn toF32(self: PathContourPoint) [2]f32 {
        return .{ f26ToF32(self.x), f26ToF32(self.y) };
    }

    fn midpoint(self: PathContourPoint, other: PathContourPoint) PathContourPoint {
        return .{
            .x = f26Midpoint(self.x, other.x),
            .y = f26Midpoint(self.y, other.y),
            .flags = other.flags,
        };
    }
};

/// `path::to_path` entry point.
fn contourToPath(
    points: []const Point26,
    flags: []const u8,
    contours: []const u16,
    style: PathStyle,
    pen: anytype,
) DrawError!void {
    for (contours, 0..) |contour_end, contour_ix| {
        const start_ix: usize = if (contour_ix > 0)
            @as(usize, contours[contour_ix - 1]) + 1
        else
            0;
        const end_ix: usize = contour_end;
        if (end_ix < start_ix) return error.ContourOrder;
        if (end_ix >= points.len) return error.ContourOrder;
        if (flags.len < points.len) return error.MalformedData;
        // Upstream only supports FreeType in this pipeline; HarfBuzz is
        // rejected in `draw` before reaching here.
        if (style != .freetype) return error.Unsupported;
        try contourToPathFreetype(PathPointView(Point26){
            .points = points[start_ix .. end_ix + 1],
            .flags = flags[start_ix .. end_ix + 1],
        }, pen);
    }
}

/// A read-only view over contour points in either of the two forms the
/// scaler produces: parallel 26.6 `Point26`/flag slices, or the packed
/// `PathContourPoint` array the autohinter keeps.
fn PathPointView(comptime T: type) type {
    return struct {
        points: []const T,
        flags: ?[]const u8 = null,

        fn len(self: @This()) usize {
            return self.points.len;
        }

        fn get(self: @This(), ix: usize) PathContourPoint {
            if (comptime T == PathContourPoint) {
                return self.points[ix];
            } else {
                const f = self.flags.?;
                return .{ .x = self.points[ix].x, .y = self.points[ix].y, .flags = f[ix] };
            }
        }
    };
}

/// Runs the FreeType path conversion over raw packed contour points. Used by
/// the autohinter, which keeps its own point representation.
pub fn contourPointsToPath(
    points: []const PathContourPoint,
    style: PathStyle,
    pen: anytype,
) DrawError!void {
    if (style != .freetype) return error.Unsupported;
    try contourToPathFreetype(PathPointView(PathContourPoint){ .points = points }, pen);
}

fn contourToPathFreetype(points: anytype, pen: anytype) DrawError!void {
    const n = points.len();
    const first = points.get(0);
    const last = points.get(n - 1);

    var start_point: PathContourPoint = undefined;
    var omit_last = false;
    var start_ix: usize = 0;
    if (first.isOffCurveQuad()) {
        if (last.isOnCurve()) {
            // The last point is on curve, so start there.
            omit_last = true;
            start_point = last;
        } else {
            // Both off curve: start at the implied midpoint.
            start_point = last.midpoint(first);
        }
    } else {
        // Starting with an on-curve point: consume it.
        start_point = first;
        start_ix = 1;
    }
    const start_f32 = start_point.toF32();
    try pen.moveTo(start_f32[0], start_f32[1]);

    var state: PendingState = .empty;
    if (omit_last) {
        const end_ix = n - 1;
        var ix = start_ix;
        while (ix < end_ix) : (ix += 1) {
            try state.emit(ix, points.get(ix), pen);
        }
    } else {
        var ix = start_ix;
        while (ix < n) : (ix += 1) {
            try state.emit(ix, points.get(ix), pen);
        }
    }
    try state.finish(0, start_point, pen);
}

const PendingState = union(enum) {
    empty,
    pending_quad: PathContourPoint,
    pending_cubic: PathContourPoint,
    two_pending_cubics: struct { c0: PathContourPoint, c1: PathContourPoint },

    fn emit(self: *PendingState, ix: usize, point: PathContourPoint, pen: anytype) DrawError!void {
        _ = ix;
        switch (self.*) {
            .empty => {
                if (point.isOffCurveQuad()) {
                    self.* = .{ .pending_quad = point };
                } else if (point.isOffCurveCubic()) {
                    self.* = .{ .pending_cubic = point };
                } else {
                    const p = point.toF32();
                    try pen.lineTo(p[0], p[1]);
                }
            },
            .pending_quad => |quad| {
                if (point.isOffCurveQuad()) {
                    const c0 = quad.toF32();
                    const p = quad.midpoint(point).toF32();
                    try pen.quadTo(c0[0], c0[1], p[0], p[1]);
                    self.* = .{ .pending_quad = point };
                } else if (point.isOffCurveCubic()) {
                    return error.ExpectedQuadOrOnCurve;
                } else {
                    const c0 = quad.toF32();
                    const p = point.toF32();
                    try pen.quadTo(c0[0], c0[1], p[0], p[1]);
                    self.* = .empty;
                }
            },
            .pending_cubic => |cubic| {
                if (point.isOffCurveCubic()) {
                    self.* = .{ .two_pending_cubics = .{ .c0 = cubic, .c1 = point } };
                } else {
                    return error.ExpectedCubic;
                }
            },
            .two_pending_cubics => |cubics| {
                if (point.isOffCurveQuad()) {
                    return error.ExpectedCubic;
                } else if (point.isOffCurveCubic()) {
                    const c0 = cubics.c0.toF32();
                    const c1 = cubics.c1.toF32();
                    const p = cubics.c1.midpoint(point).toF32();
                    try pen.curveTo(c0[0], c0[1], c1[0], c1[1], p[0], p[1]);
                    self.* = .{ .pending_cubic = point };
                } else {
                    const c0 = cubics.c0.toF32();
                    const c1 = cubics.c1.toF32();
                    const p = point.toF32();
                    try pen.curveTo(c0[0], c0[1], c1[0], c1[1], p[0], p[1]);
                    self.* = .empty;
                }
            },
        }
    }

    fn finish(self: *PendingState, start_ix: usize, start_point: PathContourPoint, pen: anytype) DrawError!void {
        switch (self.*) {
            .empty => {},
            else => {
                var closing = start_point;
                closing.flags = raw.flag_on_curve_point;
                try self.emit(start_ix, closing, pen);
            },
        }
        try pen.close();
    }
};

// --------------------------------------------------------------------- tests

test "fixed point primitives match read-fonts" {
    // font-types' own test vectors.
    try std.testing.expectEqual(@as(i32, 0x00010000), fixedMul(0x00010000, 0x00010000)); // 1*1
    try std.testing.expectEqual(@as(i32, 0x00008000), fixedMul(0x8000, 0x10000)); // 0.5*1
    try std.testing.expectEqual(@as(i32, 0x30000), fixedDiv(0x30000, 0x10000)); // 3/1
    try std.testing.expectEqual(@as(i32, 0x18000), fixedDiv(0x30000, 0x20000)); // 3/2
    try std.testing.expectEqual(@as(i32, 0x7FFFFFFF), fixedDiv(1, 0));
    try std.testing.expectEqual(@as(i32, 0), fixedToI32(0x7FFF));
    try std.testing.expectEqual(@as(i32, 1), fixedToI32(0x8000));
    try std.testing.expectEqual(@as(i32, 0), fixedToI32(-0x8000));
    try std.testing.expectEqual(@as(i32, 64), f26FromI32(1));
    try std.testing.expectEqual(@as(i32, -192), f26FromI32(-3));
    try std.testing.expectEqual(@as(i32, 1), f26ToI32(64));
    try std.testing.expectEqual(@as(i32, -1), f26ToI32(-64));
    try std.testing.expectEqual(@as(i32, 26), f26ToI32(f26FromI32(26)));
    try std.testing.expectEqual(@as(i32, -26), f26ToI32(f26FromI32(-26)));
}

test "scale factors match the FreeType 16.16 formula" {
    // 16px over 2048upem: Fixed::from_bits(1024) / Fixed::from_bits(2048).
    try std.testing.expectEqual(@as(i32, 0x8000), Scale26Dot6.init(16.0, 2048).scale_bits);
    // ppem == upem is a scale factor of 64 (one font unit is one pixel).
    try std.testing.expectEqual(@as(i32, 0x400000), Scale26Dot6.init(2048.0, 2048).scale_bits);
    try std.testing.expect(!Scale26Dot6.init(null, 2048).is_scaled);
    try std.testing.expect(!Scale26Dot6.init(16.0, 0).is_scaled);
    try std.testing.expectEqual(@as(i32, 0x10000), Scale26Dot6.init(null, 2048).scale_bits);
    // 14.5px: (928 << 16 + 1024) / 2048 = 29696 (0x7400).
    try std.testing.expectEqual(@as(i32, 0x7400), Scale26Dot6.init(14.5, 2048).scale_bits);
    try std.testing.expectEqual(@as(i32, 0x7400), Scale26Dot6.init(14.5, 2048).scale_bits);
}

test "saturating float to int matches Rust casts" {
    try std.testing.expectEqual(@as(i32, 0), saturatingF32ToI32(std.math.nan(f32)));
    try std.testing.expectEqual(std.math.maxInt(i32), saturatingF32ToI32(1e30));
    try std.testing.expectEqual(std.math.minInt(i32), saturatingF32ToI32(-1e30));
    try std.testing.expectEqual(@as(i32, -3), saturatingF32ToI32(-3.9));
    try std.testing.expectEqual(@as(i32, 0), saturatingF32ToI32(-0.0));
}

test "Roboto glyph 37 scales and emits the oracle path" {
    const fixture = @import("test_fixture.zig");
    const pen_mod = @import("pen.zig");
    const font = try Font.init(try fixture.roboto(), 0);
    const outlines = try font.outlines();
    var pen = pen_mod.PathElementPen.init(std.testing.allocator);
    defer pen.deinit();
    const metrics = try outlines.draw(std.testing.allocator, 37, .{ .size = 16.0 }, &pen);
    try std.testing.expectEqual(@as(f32, 0.0), metrics.lsb.?);
    try std.testing.expectEqual(@as(f32, 10.4375), metrics.advance_width.?);
    // First two elements recorded from the pinned oracle at 16px.
    try std.testing.expectEqual(@as(usize, 13), pen.elements.items.len);
    const first = pen.elements.items[0].move_to;
    try std.testing.expectEqual(@as(u32, 0x40f38000), @as(u32, @bitCast(first[0])));
    try std.testing.expectEqual(@as(u32, 0x403e0000), @as(u32, @bitCast(first[1])));
}

test "empty glyph emits no elements" {
    const fixture = @import("test_fixture.zig");
    const pen_mod = @import("pen.zig");
    const font = try Font.init(try fixture.roboto(), 0);
    const outlines = try font.outlines();
    var pen = pen_mod.PathElementPen.init(std.testing.allocator);
    defer pen.deinit();
    const metrics = try outlines.draw(std.testing.allocator, 1, .{ .size = 16.0 }, &pen);
    try std.testing.expectEqual(@as(usize, 0), pen.elements.items.len);
    try std.testing.expectEqual(@as(f32, 0.0), metrics.advance_width.?);
    // `gid == numGlyphs` and beyond: `loca` has no end offset, matching
    // upstream's `ReadError::OutOfBounds`.
    try std.testing.expectError(
        error.OutOfBounds,
        outlines.draw(std.testing.allocator, font.numGlyphs(), .{ .size = 16.0 }, &pen),
    );
    try std.testing.expectError(
        error.OutOfBounds,
        outlines.draw(std.testing.allocator, 9999, .{ .size = 16.0 }, &pen),
    );
}

test "unsupported inputs fail with typed errors" {
    const fixture = @import("test_fixture.zig");
    const pen_mod = @import("pen.zig");
    const font = try Font.init(try fixture.roboto(), 0);
    const outlines = try font.outlines();
    var pen = pen_mod.PathElementPen.init(std.testing.allocator);
    defer pen.deinit();
    try std.testing.expectError(
        error.Unsupported,
        outlines.draw(std.testing.allocator, 37, .{ .size = 16.0, .coords = &.{0} }, &pen),
    );
    try std.testing.expectError(
        error.Unsupported,
        outlines.draw(
            std.testing.allocator,
            37,
            .{ .size = 16.0, .path_style = .harfbuzz },
            &pen,
        ),
    );
}
