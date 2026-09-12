//! Port of vello_cpu src/fine/common/gradient/*.rs (Apache-2.0 OR MIT).
//!
//! Fine-rasterization gradient painters: `computeTVals` evaluates the
//! per-pixel gradient parameter `t` for one strip row (upstream
//! `calculate_t_vals`), and `GradientPainter` samples the f32 LUT to fill the
//! row scratch (upstream `GradientPainter::paint_f32`).
//!
//! Buffer layout: the fine rasterizer scratch is column-major tiles. `t_vals`
//! holds one f32 per pixel, index `4 * dx + y` for pixel column `dx`, tile row
//! `y` in `0..3`. The `dest` buffer passed to `paint` holds 16 f32 per pixel
//! column: pixel `(dx, y)`, component `c` at `4 * (4 * dx + y) + c`. `paint`
//! fills complete 8-pixel (32 f32) groups only, exactly like upstream
//! `chunks_exact_mut(32)`, and leaves a trailing partial group untouched.
//!
//! Numerical convention: upstream's portable/baseline `fearless_simd` backend
//! implements `mul_add(a, b)` as a separate multiply followed by an add
//! (unfused). Every upstream `.mul_add` below is therefore ported through
//! `simd.mulAddUnfused`, matching `common/encode.zig`. No
//! `@setFloatMode`: strict IEEE semantics throughout.
//!
//! Divergences from upstream:
//! - Upstream is generic over a `Simd` backend and iterates `ChunksExact`
//!   inside the painter; this port fixes the fallback/baseline float semantics
//!   (see above) and carries the t-value slice plus a cursor instead.
//! - Upstream panics when a destination group has no t values left
//!   (`next().unwrap()`); this port panics with an explicit message.
//! - The radial/sweep kinds are dispatched per chunk from `EncodedKind`
//!   instead of being pre-built objects; the arithmetic is identical.

const std = @import("std");
const simd = @import("../../simd/root.zig");
const common_util = @import("../../common/util.zig");
const encode = @import("../../common/encode.zig");
const kurbo = @import("../../kurbo/root.zig");
const peniko = @import("../../peniko/root.zig");

const F32x4 = simd.F32x4;
const F32x8 = simd.F32x8;
const F32x16 = simd.F32x16;
const U32x8 = simd.Vec(8, u32);
const Point = kurbo.Point;
const Extend = peniko.Extend;

/// Sentinel index written for NaN positions (upstream `GRADIENT_INVALID_POS`).
pub const GRADIENT_INVALID_POS: u32 = std.math.maxInt(u32);

/// `2.0 * core::f32::consts::PI`, evaluated in f32 as upstream does.
const TWO_PI: f32 = 2.0 * @as(f32, std.math.pi);

// ---------------------------------------------------------------------------
// Per-pixel parameter computation (upstream `calculate_t_vals`)
// ---------------------------------------------------------------------------

/// Compute per-pixel gradient parameter values for one strip row.
///
/// Mirrors upstream `calculate_t_vals` (plus `f32x8::splat_pos` and the
/// per-kind `cur_pos` implementations): `t_vals` is processed in chunks of
/// eight values (two pixel columns) and a trailing partial chunk is dropped,
/// like `chunks_exact_mut(8)`.
pub fn computeTVals(
    gradient: *const encode.EncodedGradient,
    t_vals: []f32,
    start_x: f64,
    start_y: f64,
) void {
    var cur_pos = gradient.transform.transformPoint(Point.new(start_x, start_y));
    const x_advance = gradient.x_advance;
    const y_advance = gradient.y_advance;

    // Upstream casts the f64 advances to f32 once, outside the loop.
    const x_advance_x: f32 = @floatCast(x_advance.x);
    const x_advance_y: f32 = @floatCast(x_advance.y);
    const y_advance_x: f32 = @floatCast(y_advance.x);
    const y_advance_y: f32 = @floatCast(y_advance.y);

    var i: usize = 0;
    while (i + 8 <= t_vals.len) : (i += 8) {
        // `x_pos` advances down the tile (y direction) within a column; the
        // second four lanes start one pixel column further along x.
        const x_pos = splatPos(@floatCast(cur_pos.x), x_advance_x, y_advance_x);
        const y_pos = splatPos(@floatCast(cur_pos.y), x_advance_y, y_advance_y);
        const pos = curPosForKind(gradient.kind, x_pos, y_pos);
        simd.storeSlice(pos, t_vals[i..][0..8]);

        // `cur_pos += 2.0 * gradient.x_advance`, in f64.
        cur_pos = cur_pos.addVec(x_advance.mulScalar(2.0));
    }
}

/// Upstream `f32x8::splat_pos`: one `f32x4::splat_pos` for the first pixel
/// column and one for the column one x advance further along.
///
/// `f32x4::splat_pos` is `column_mask.mul_add(y_advance, splat(pos))` with the
/// unfused fallback/baseline `mul_add`; the base of the second column is the
/// f32 sum `pos + x_advance`, not a fresh f64 cast.
inline fn splatPos(pos: f32, x_advance: f32, y_advance: f32) F32x8 {
    return simd.combineF32x4(splatPos4(pos, y_advance), splatPos4(pos + x_advance, y_advance));
}

/// Upstream `f32x4::splat_pos`: lane `r` is `f32(r) * y_advance + pos`.
inline fn splatPos4(pos: f32, y_advance: f32) F32x4 {
    const columns: F32x4 = .{ 0.0, 1.0, 2.0, 3.0 };
    return simd.mulAddUnfused(columns, @as(F32x4, @splat(y_advance)), @as(F32x4, @splat(pos)));
}

/// Upstream `SimdGradientKind::cur_pos` dispatch.
fn curPosForKind(kind: encode.EncodedKind, x_pos: F32x8, y_pos: F32x8) F32x8 {
    return switch (kind) {
        // `SimdLinearKind`: the position along the gradient line is the
        // interpolated x coordinate.
        .linear => x_pos,
        .sweep => |sweep| sweepCurPos(sweep, x_pos, y_pos),
        .radial => |radial| radialCurPos(radial, x_pos, y_pos),
    };
}

/// Upstream `SimdSweepKind::cur_pos`.
fn sweepCurPos(kind: encode.SweepKind, x_pos: F32x8, y_pos: F32x8) F32x8 {
    const angle = xYToUnitAngle(x_pos, y_pos) * @as(F32x8, @splat(TWO_PI));

    return (angle - @as(F32x8, @splat(kind.start_angle))) *
        @as(F32x8, @splat(kind.inv_angle_delta));
}

/// Upstream `x_y_to_unit_angle`: map a point to a unit angle.
///
/// The polynomial is the Skia slope approximation, followed by the quadrant
/// selects and a final NaN-clearing select (`phi == phi` is false for NaN).
fn xYToUnitAngle(x: F32x8, y: F32x8) F32x8 {
    const zero: F32x8 = @splat(0.0);
    const one: F32x8 = @splat(1.0);
    const quarter: F32x8 = @splat(1.0 / 4.0);
    const half: F32x8 = @splat(1.0 / 2.0);

    const x_abs = @abs(x);
    const y_abs = @abs(y);

    const slope = simd.min(x_abs, y_abs) / simd.max(x_abs, y_abs);
    const s = slope * slope;

    const a = simd.mulAddUnfused(
        @as(F32x8, @splat(-7.054_738_2e-3)),
        s,
        @as(F32x8, @splat(2.476_102e-2)),
    );
    const b = simd.mulAddUnfused(a, s, @as(F32x8, @splat(-5.185_397e-2)));
    const c = simd.mulAddUnfused(b, s, @as(F32x8, @splat(0.159_121_17)));

    var phi = slope * c;

    phi = simd.select(F32x8, x_abs < y_abs, quarter - phi, phi);
    phi = simd.select(F32x8, x < zero, half - phi, phi);
    phi = simd.select(F32x8, y < zero, one - phi, phi);
    // Clears all NaNs, using the property that NaN != NaN.
    phi = simd.select(F32x8, phi == phi, phi, zero);

    return phi;
}

/// Upstream `SimdRadialKind::cur_pos`.
fn radialCurPos(kind: encode.RadialKind, x_pos: F32x8, y_pos: F32x8) F32x8 {
    return switch (kind) {
        .radial => |radial| blk: {
            // `x.mul_add(x, y * y).sqrt()`, then `radius.mul_add(scale, bias)`.
            const radius = @sqrt(simd.mulAddUnfused(x_pos, x_pos, y_pos * y_pos));
            break :blk simd.mulAddUnfused(
                radius,
                @as(F32x8, @splat(radial.scale)),
                @as(F32x8, @splat(radial.bias)),
            );
        },
        .strip => |strip| blk: {
            // `y.mul_add(-y, scaled_r0_squared)`; negative `p1` is undefined
            // and becomes NaN so the painter's mask pass zeroes it.
            const scaled_r0_squared: F32x8 = @splat(strip.scaled_r0_squared);
            const p1 = simd.mulAddUnfused(y_pos, -y_pos, scaled_r0_squared);
            const mask = p1 < @as(F32x8, @splat(0.0));
            break :blk simd.select(
                F32x8,
                mask,
                @as(F32x8, @splat(std.math.nan(f32))),
                x_pos + @sqrt(p1),
            );
        },
        .focal => |focal| focalCurPos(focal, x_pos, y_pos),
    };
}

/// Upstream `SimdRadialKindInner::Focal::cur_pos`.
fn focalCurPos(focal: encode.RadialKind.Focal, x_pos: F32x8, y_pos: F32x8) F32x8 {
    const focal_data = focal.focal_data;
    const fp0: F32x8 = @splat(focal.fp0);
    const fp1: F32x8 = @splat(focal.fp1);

    var t = if (focal_data.isFocalOnCircle())
        // `y.mul_add(y / x, x)`.
        simd.mulAddUnfused(y_pos, y_pos / x_pos, x_pos)
    else if (focal_data.isWellBehaved()) blk: {
        // `x.mul_add(x, y * y).sqrt()`, then `x.mul_add(-fp0, radius)`.
        const radius = @sqrt(simd.mulAddUnfused(x_pos, x_pos, y_pos * y_pos));
        break :blk simd.mulAddUnfused(x_pos, -fp0, radius);
    } else if (focal_data.isSwapped() or (1.0 - focal_data.f_focal_x < 0.0)) blk: {
        // `x.mul_add(x, -(y * y)).sqrt()`, then `x.mul_add(-fp0, -radius)`.
        const radius = @sqrt(simd.mulAddUnfused(x_pos, x_pos, -(y_pos * y_pos)));
        break :blk simd.mulAddUnfused(x_pos, -fp0, -radius);
    } else blk: {
        const radius = @sqrt(simd.mulAddUnfused(x_pos, x_pos, -(y_pos * y_pos)));
        break :blk simd.mulAddUnfused(x_pos, -fp0, radius);
    };

    if (!focal_data.isWellBehaved()) {
        // Radii <= 0 should be masked out, too.
        const is_degenerate = t <= @as(F32x8, @splat(0.0));
        t = simd.select(F32x8, is_degenerate, @as(F32x8, @splat(std.math.nan(f32))), t);
    }

    if (1.0 - focal_data.f_focal_x < 0.0) {
        t = @as(F32x8, @splat(-1.0)) * t;
    }

    if (!focal_data.isNativelyFocal()) {
        t += fp1;
    }

    if (focal_data.isSwapped()) {
        t = @as(F32x8, @splat(1.0)) - t;
    }

    return t;
}

// ---------------------------------------------------------------------------
// LUT sampling painter (upstream `GradientPainter::paint_f32`)
// ---------------------------------------------------------------------------

/// Fine-rasterization painter that samples a gradient's f32 lookup table.
///
/// The `GradientPainter` borrows the encoded gradient (for `extend` and the
/// lazily built LUT) and the t-value slice; neither is owned.
pub const GradientPainter = struct {
    /// The encoded gradient: source of `extend` and owner of the LUT.
    gradient: *encode.EncodedGradient,
    /// The f32 lookup table (`gradient.f32Lut(allocator)`).
    lut: *const encode.GradientLut(f32),
    /// One f32 per pixel, index `4 * dx + y`.
    t_vals: []const f32,
    /// Cursor into `t_vals`, in values (advanced 8 at a time).
    t_idx: usize = 0,
    /// Whether the gradient can yield undefined positions (NaN bookkeeping).
    has_undefined: bool,
    /// `lut.scaleFactor()`, applied to the extended parameter before the
    /// lookup-index conversion.
    scale_factor: f32,

    /// Create a painter, building the gradient's f32 LUT on first use.
    ///
    /// The caller keeps ownership of `gradient` and `t_vals`; both must
    /// outlive the painter and `paint` calls.
    pub fn init(
        gradient: *encode.EncodedGradient,
        allocator: std.mem.Allocator,
        t_vals: []const f32,
    ) std.mem.Allocator.Error!GradientPainter {
        const lut = try gradient.f32Lut(allocator);

        return .{
            .gradient = gradient,
            .lut = lut,
            .t_vals = t_vals,
            .has_undefined = gradient.has_undefined,
            .scale_factor = lut.scaleFactor(),
        };
    }

    /// Paint one row into `dest`, processing complete 32-float (8-pixel)
    /// chunks only and leaving a trailing partial chunk untouched, like
    /// upstream `chunks_exact_mut(32)`.
    pub fn paint(self: *GradientPainter, dest: []f32) void {
        // Upstream clones the t-value iterator before the first pass when the
        // gradient can be undefined, then replays it to mask NaN positions.
        const masked_pass = self.has_undefined;

        self.paintPass(dest);

        if (masked_pass) {
            self.t_idx = 0;
            self.maskedPass(dest);
        }
    }

    /// Paint one row as u8 bytes, processing complete 32-byte (8-pixel)
    /// chunks only.
    ///
    /// This is the `U8Kernel::apply_painter` path for gradients with
    /// undefined positions (upstream keeps `gradient_painter_with_undefined`
    /// on the f32 painter and converts through `u8x16::from_f32`). The two
    /// passes mirror [`GradientPainter.paint`].
    pub fn paintU8(self: *GradientPainter, dest: []u8) void {
        const masked_pass = self.has_undefined;

        self.paintU8Pass(dest);

        if (masked_pass) {
            self.t_idx = 0;
            self.maskedU8Pass(dest);
        }
    }

    /// First u8 pass: sample the f32 LUT and convert each component.
    fn paintU8Pass(self: *GradientPainter, dest: []u8) void {
        const max_index: u32 = @intCast(self.lut.width() - 1);
        const max_index_v: U32x8 = @splat(max_index);

        var i: usize = 0;
        while (i + 32 <= dest.len) : (i += 32) {
            const indices = self.nextIndices();
            const clamped = @min(indices, max_index_v);
            inline for (0..8) |pixel| {
                const rgba = self.lut.get(@intCast(clamped[pixel]));
                inline for (0..4) |component| {
                    dest[i + 4 * pixel + component] = lutComponentToU8(rgba[component]);
                }
            }
        }
    }

    /// Second u8 pass: zero every pixel whose raw index is the invalid
    /// sentinel.
    fn maskedU8Pass(self: *GradientPainter, dest: []u8) void {
        const sentinel: U32x8 = @splat(GRADIENT_INVALID_POS);

        var i: usize = 0;
        while (i + 32 <= dest.len) : (i += 32) {
            const indices = self.nextIndices();
            const invalid = indices == sentinel;
            inline for (0..8) |pixel| {
                if (invalid[pixel]) {
                    @memset(dest[i + 4 * pixel ..][0..4], 0);
                }
            }
        }
    }

    /// First pass: sample the LUT for every complete 8-pixel chunk.
    fn paintPass(self: *GradientPainter, dest: []f32) void {
        const max_index: u32 = @intCast(self.lut.width() - 1);
        const max_index_v: U32x8 = @splat(max_index);

        var i: usize = 0;
        while (i + 32 <= dest.len) : (i += 32) {
            const indices = self.nextIndices();
            // Upstream `indices.min(max_index)`; NaN positions were replaced
            // by the sentinel and clamp to the last LUT entry here.
            const clamped = @min(indices, max_index_v);
            inline for (0..8) |pixel| {
                dest[i + 4 * pixel ..][0..4].* = self.lut.get(@intCast(clamped[pixel]));
            }
        }
    }

    /// Second pass: zero the four components of every pixel whose raw index
    /// is the invalid sentinel, recomputing the identical index math.
    fn maskedPass(self: *GradientPainter, dest: []f32) void {
        const sentinel: U32x8 = @splat(GRADIENT_INVALID_POS);

        var i: usize = 0;
        while (i + 32 <= dest.len) : (i += 32) {
            const indices = self.nextIndices();
            const invalid = indices == sentinel;
            inline for (0..8) |pixel| {
                if (invalid[pixel]) {
                    dest[i + 4 * pixel ..][0..4].* = .{ 0.0, 0.0, 0.0, 0.0 };
                }
            }
        }
    }

    /// Compute the lookup indices for the next complete 8-value t chunk.
    ///
    /// Mirrors upstream `Iterator for GradientPainter::next`: extend, NaN
    /// detection, scale, Rust `as u32` conversion, then sentinel substitution.
    fn nextIndices(self: *GradientPainter) U32x8 {
        // Upstream calls `next().unwrap()` here; a missing complete chunk is a
        // caller contract violation (the destination has more 8-pixel groups
        // than the t-value buffer), so fail loudly instead of reading garbage.
        if (self.t_idx + 8 > self.t_vals.len) {
            @panic("gradient painter: t_vals exhausted");
        }
        const pos = simd.fromSlice(F32x8, self.t_vals[self.t_idx..][0..8]);
        self.t_idx += 8;

        const extended = applyExtend(pos, self.gradient.extend);
        const valid = pos == pos;
        const scaled = extended * @as(F32x8, @splat(self.scale_factor));

        var indices: U32x8 = undefined;
        inline for (0..8) |lane| {
            indices[lane] = f32ToU32(scaled[lane]);
        }

        // In case we had any NaN's, set the index to an explicit invalid
        // sentinel. There probably is architecture-specific behavior for how
        // NaN is converted to an integer, so upstream applies its own
        // handling; mirror that with a select.
        return simd.select(U32x8, valid, indices, @as(U32x8, @splat(GRADIENT_INVALID_POS)));
    }
};

/// Upstream `apply_extend`: map a parameter into `[0, 1]` according to the
/// extend mode.
fn applyExtend(val: F32x8, extend: Extend) F32x8 {
    const zero: F32x8 = @splat(0.0);
    const one: F32x8 = @splat(1.0);

    return switch (extend) {
        .pad => simd.min(simd.max(val, zero), one),
        // Upstream calls `.fract()` after the subtraction; for a value already
        // in `[0, 1)` that is the identity, so it is elided here.
        .repeat => val - @floor(val),
        // See <https://github.com/google/skia/blob/220738774f7a0ce4a6c7bd17519a336e5e5dea5b/src/opts/SkRasterPipeline_opts.h#L6472-L6475>
        .reflect => blk: {
            const shifted = val - one;
            const reflected =
                @abs(shifted - @as(F32x8, @splat(2.0)) * @floor(shifted * @as(F32x8, @splat(0.5))) - one);
            break :blk simd.min(simd.max(reflected, zero), one);
        },
    };
}

/// Rust's `value as u32` for f32: truncate toward zero and saturate; NaN maps
/// to zero and values at or above the saturating bound map to `u32::MAX`
/// (which is also [`GRADIENT_INVALID_POS`], like upstream).
///
/// Public because the low-precision painter in `lowp/gradient.zig` shares the
/// same saturating conversion (upstream `to_int::<u32x16>`).
pub fn f32ToU32(value: f32) u32 {
    if (std.math.isNan(value)) return 0;
    if (value <= 0.0) return 0;
    // The f32 literal rounds to 2^32, matching Rust's saturating cast bound.
    if (value >= 4294967295.0) return GRADIENT_INVALID_POS;
    return @intFromFloat(value);
}

/// Convert one f32 LUT component to u8 via `u8x16::from_f32`
/// (`f32_to_u8(v * 255.0 + 0.5)`, unfused multiply-add).
fn lutComponentToU8(value: f32) u8 {
    const scaled: F32x16 = @splat(value * 255.0 + 0.5);
    return common_util.f32ToU8(scaled)[0];
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

/// Encode `kind` with `stops` and no paint transform, appending to `paints`.
/// The caller owns `paints` (release with [`releasePaints`]).
fn encodeTestGradient(
    allocator: std.mem.Allocator,
    paints: *std.ArrayList(encode.EncodedPaint),
    kind: peniko.GradientKind,
    stops: []const peniko.ColorStop,
    extend: peniko.Extend,
) !*encode.EncodedGradient {
    var gradient = try (peniko.Gradient{ .kind = kind, .extend = extend }).withStops(allocator, stops);
    defer gradient.deinit();

    const paint = try encode.encodeGradient(&gradient, allocator, paints, kurbo.Affine.IDENTITY, null);
    return &paints.items[paint.indexed.index()].gradient;
}

/// Release every encoded paint and the list itself.
fn releasePaints(allocator: std.mem.Allocator, paints: *std.ArrayList(encode.EncodedPaint)) void {
    for (paints.items) |*paint| paint.deinit(allocator);
    paints.deinit(allocator);
}

test "linear t values advance across two columns per chunk" {
    const allocator = testing.allocator;
    var paints: std.ArrayList(encode.EncodedPaint) = .empty;
    defer releasePaints(allocator, &paints);

    const stops = [_]peniko.ColorStop{
        peniko.ColorStop.init(0.0, peniko.palette.css.RED),
        peniko.ColorStop.init(1.0, peniko.palette.css.BLUE),
    };
    const gradient = try encodeTestGradient(
        allocator,
        &paints,
        .{ .linear = peniko.LinearGradientPosition.new(Point.new(0.0, 0.0), Point.new(1.0, 0.0)) },
        &stops,
        .pad,
    );

    // The encoded transform is the identity, so the x advance is (1, 0) and
    // the y advance is (0, 1). For a chunk starting at (0.5, 0.5):
    //  - lanes 0..3 are the first pixel column: x = 0.5 + r * 0.0 = 0.5;
    //  - lanes 4..7 are the second: x = (0.5 + 1.0) + r * 0.0 = 1.5;
    //  - the linear kind returns the x positions.
    // After each chunk `cur_pos += 2.0 * x_advance`, so the next chunk starts
    // at x = 2.5.
    var t_vals: [16]f32 = @splat(-1.0);
    computeTVals(gradient, &t_vals, 0.5, 0.5);

    try testing.expectEqualSlices(f32, &[_]f32{
        0.5, 0.5, 0.5, 0.5, 1.5, 1.5, 1.5, 1.5,
        2.5, 2.5, 2.5, 2.5, 3.5, 3.5, 3.5, 3.5,
    }, &t_vals);

    // A trailing partial chunk is dropped (`chunks_exact_mut(8)`).
    var partial: [12]f32 = @splat(-1.0);
    computeTVals(gradient, &partial, 0.5, 0.5);
    try testing.expectEqualSlices(f32, &[_]f32{
        0.5,  0.5,  0.5,  0.5,  1.5, 1.5, 1.5, 1.5,
        -1.0, -1.0, -1.0, -1.0,
    }, &partial);
}

test "x_y_to_unit_angle quadrants match upstream selects" {
    // Axis points: (1,0) -> 0, (0,1) -> 1/4, (-1,0) -> 1/2, (0,-1) -> 3/4.
    const x: F32x8 = .{ 1.0, 0.0, -1.0, 0.0, 1.0, 1.0, -1.0, 0.0 };
    const y: F32x8 = .{ 0.0, 1.0, 0.0, -1.0, 1.0, -1.0, -1.0, 0.0 };
    const phi = xYToUnitAngle(x, y);

    try testing.expectEqual(@as(f32, 0.0), phi[0]);
    try testing.expectEqual(@as(f32, 0.25), phi[1]);
    try testing.expectEqual(@as(f32, 0.5), phi[2]);
    try testing.expectEqual(@as(f32, 0.75), phi[3]);
    // The 45 degree diagonals approximate 1/8, 7/8 and 5/8.
    try testing.expectApproxEqAbs(@as(f32, 0.125), phi[4], 1e-4);
    try testing.expectApproxEqAbs(@as(f32, 0.875), phi[5], 1e-4);
    try testing.expectApproxEqAbs(@as(f32, 0.625), phi[6], 1e-4);
    // (0, 0) makes the slope 0/0 = NaN, which the `phi == phi` select clears.
    try testing.expectEqual(@as(f32, 0.0), phi[7]);
}

test "sweep cur_pos scales the unit angle" {
    // Unit angle 1/4 at (0, 1): t = 1/4 * (2 * pi) with start 0, delta 2 * pi.
    const kind = encode.SweepKind{ .start_angle = 0.0, .inv_angle_delta = 1.0 };
    const t = sweepCurPos(kind, @as(F32x8, @splat(0.0)), @as(F32x8, @splat(1.0)));
    inline for (0..8) |lane| {
        try testing.expectApproxEqAbs(@as(f32, 0.25 * TWO_PI), t[lane], 1e-6);
    }

    // A non-zero start angle is subtracted before the inverse-delta scaling.
    const shifted_kind = encode.SweepKind{
        .start_angle = 0.25 * TWO_PI,
        .inv_angle_delta = 1.0 / TWO_PI,
    };
    const zero_t = sweepCurPos(shifted_kind, @as(F32x8, @splat(0.0)), @as(F32x8, @splat(1.0)));
    inline for (0..8) |lane| {
        try testing.expectApproxEqAbs(@as(f32, 0.0), zero_t[lane], 1e-6);
    }
}

test "apply_extend matches upstream pad/repeat/reflect" {
    const input: F32x8 = .{ -1.5, -0.25, 0.0, 0.25, 0.75, 1.0, 1.25, 2.5 };

    const padded = applyExtend(input, .pad);
    try testing.expectEqual(F32x8{ 0.0, 0.0, 0.0, 0.25, 0.75, 1.0, 1.0, 1.0 }, padded);

    // `val - floor(val)`: negative values wrap into [0, 1).
    const repeated = applyExtend(input, .repeat);
    try testing.expectEqual(F32x8{ 0.5, 0.75, 0.0, 0.25, 0.75, 0.0, 0.25, 0.5 }, repeated);

    // `abs((val - 1) - 2 * floor((val - 1) * 0.5) - 1)`, clamped on [0, 1].
    const reflected = applyExtend(input, .reflect);
    try testing.expectEqual(F32x8{ 0.5, 0.25, 0.0, 0.25, 0.75, 1.0, 0.75, 0.5 }, reflected);
}

test "f32_to_u32 matches rust saturating cast" {
    try testing.expectEqual(@as(u32, 0), f32ToU32(std.math.nan(f32)));
    try testing.expectEqual(@as(u32, 0), f32ToU32(-1.0));
    try testing.expectEqual(@as(u32, 0), f32ToU32(-0.0));
    try testing.expectEqual(@as(u32, 0), f32ToU32(0.0));
    try testing.expectEqual(@as(u32, 0), f32ToU32(0.999));
    try testing.expectEqual(@as(u32, 1), f32ToU32(1.9));
    try testing.expectEqual(@as(u32, 254), f32ToU32(254.999));
    // The largest f32 below 2^32 truncates to itself.
    try testing.expectEqual(@as(u32, 4294967040), f32ToU32(4294967040.0));
    // 2^32 and above (including infinity) saturate to u32::MAX.
    try testing.expectEqual(GRADIENT_INVALID_POS, f32ToU32(4294967296.0));
    try testing.expectEqual(GRADIENT_INVALID_POS, f32ToU32(std.math.inf(f32)));
}

test "painter samples a two-color lut and leaves partial groups alone" {
    const allocator = testing.allocator;
    var paints: std.ArrayList(encode.EncodedPaint) = .empty;
    defer releasePaints(allocator, &paints);

    const stops = [_]peniko.ColorStop{
        peniko.ColorStop.init(0.0, peniko.palette.css.RED),
        peniko.ColorStop.init(1.0, peniko.palette.css.BLUE),
    };
    const gradient = try encodeTestGradient(
        allocator,
        &paints,
        .{ .linear = peniko.LinearGradientPosition.new(Point.new(0.0, 0.0), Point.new(1.0, 0.0)) },
        &stops,
        .pad,
    );
    const lut = try gradient.f32Lut(allocator);
    const max_index = lut.width() - 1;

    // Two pixel columns per chunk: t = 0 samples index 0 (red), t = 1 is
    // scaled by `width - 1` and samples the last index (blue).
    const t_vals = [_]f32{
        0.0, 0.0, 0.0, 0.0, 1.0, 1.0, 1.0, 1.0,
        0.0, 0.0, 0.0, 0.0, 1.0, 1.0, 1.0, 1.0,
    };
    var painter = try GradientPainter.init(gradient, allocator, &t_vals);

    // 32 floats (8 pixels) of paint plus an 8-float trailing partial group
    // that `paint` must leave untouched.
    var dest: [40]f32 = @splat(42.0);
    painter.paint(&dest);

    const first = lut.get(0);
    const last = lut.get(max_index);
    try testing.expectEqualSlices(f32, &[_]f32{ 1.0, 0.0, 0.0, 1.0 }, &first);
    // The last LUT entry is sampled at `t` one ulp below/above 1.0 because the
    // index scaling is done in f32, so the endpoint color is only approximate.
    try testing.expectApproxEqAbs(@as(f32, 0.0), last[0], 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 0.0), last[1], 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 1.0), last[2], 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 1.0), last[3], 1e-6);

    for (0..8) |pixel| {
        const expected = if (pixel < 4) first else last;
        try testing.expectEqualSlices(f32, &expected, dest[4 * pixel ..][0..4]);
    }
    for (dest[32..]) |value| {
        try testing.expectEqual(@as(f32, 42.0), value);
    }
}

test "u8 painting zeroes undefined positions when has_undefined" {
    const allocator = testing.allocator;
    var paints: std.ArrayList(encode.EncodedPaint) = .empty;
    defer releasePaints(allocator, &paints);

    const stops = [_]peniko.ColorStop{
        peniko.ColorStop.init(0.0, peniko.palette.css.RED),
        peniko.ColorStop.init(1.0, peniko.palette.css.BLUE),
    };
    // Equal radii with distinct centers encode as a `strip`, which can yield
    // undefined positions (`has_undefined = true`).
    const gradient = try encodeTestGradient(
        allocator,
        &paints,
        .{ .radial = peniko.RadialGradientPosition.newTwoPoint(
            Point.new(0.0, 0.0),
            1.0,
            Point.new(2.0, 0.0),
            1.0,
        ) },
        &stops,
        .pad,
    );
    try testing.expect(gradient.has_undefined);

    const lut = try gradient.f32Lut(allocator);
    const first = lut.get(0);
    var first_u8: [4]u8 = undefined;
    inline for (0..4) |component| {
        const scaled: F32x16 = @splat(first[component] * 255.0 + 0.5);
        first_u8[component] = common_util.f32ToU8(scaled)[0];
    }

    // First pixel column is undefined (NaN) and must be zeroed; the second
    // samples index 0.
    const t_vals = [_]f32{
        std.math.nan(f32), std.math.nan(f32), std.math.nan(f32), std.math.nan(f32),
        0.0,               0.0,               0.0,               0.0,
    };
    var painter = try GradientPainter.init(gradient, allocator, &t_vals);
    var dest: [32]u8 = @splat(42);
    painter.paintU8(&dest);

    for (dest[0..16]) |value| {
        try testing.expectEqual(@as(u8, 0), value);
    }
    for (0..4) |pixel| {
        try testing.expectEqualSlices(u8, &first_u8, dest[16 + 4 * pixel ..][0..4]);
    }
}

test "painter zeroes undefined positions when has_undefined" {
    const allocator = testing.allocator;
    var paints: std.ArrayList(encode.EncodedPaint) = .empty;
    defer releasePaints(allocator, &paints);

    const stops = [_]peniko.ColorStop{
        peniko.ColorStop.init(0.0, peniko.palette.css.RED),
        peniko.ColorStop.init(1.0, peniko.palette.css.BLUE),
    };
    // Equal radii with distinct centers encode as a `strip`, which can yield
    // undefined positions (`has_undefined = true`).
    const gradient = try encodeTestGradient(
        allocator,
        &paints,
        .{ .radial = peniko.RadialGradientPosition.newTwoPoint(
            Point.new(0.0, 0.0),
            1.0,
            Point.new(2.0, 0.0),
            1.0,
        ) },
        &stops,
        .pad,
    );
    try testing.expect(gradient.has_undefined);

    const lut = try gradient.f32Lut(allocator);
    const first = lut.get(0);

    // First pixel column is undefined (NaN) and must be zeroed; the second
    // samples index 0.
    const t_vals = [_]f32{
        std.math.nan(f32), std.math.nan(f32), std.math.nan(f32), std.math.nan(f32),
        0.0,               0.0,               0.0,               0.0,
    };
    var painter = try GradientPainter.init(gradient, allocator, &t_vals);
    var dest: [32]f32 = @splat(42.0);
    painter.paint(&dest);

    for (dest[0..16]) |value| {
        try testing.expectEqual(@as(f32, 0.0), value);
    }
    for (0..4) |pixel| {
        try testing.expectEqualSlices(f32, &first, dest[16 + 4 * pixel ..][0..4]);
    }
}
