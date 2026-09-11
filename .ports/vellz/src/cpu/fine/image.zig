//! Port of vello_cpu src/fine/common/image.rs (Apache-2.0 OR MIT).
//!
//! Fine-rasterization image painters. [`ImagePainter.init`] selects the
//! painter upstream selects:
//!
//! - nearest neighbor without skew: [`PlainNN`] (the fastest path),
//! - nearest neighbor with skew: [`NN`],
//! - filtering: `Filtered(1)` (bilinear, `ImageQuality.medium`) or
//!   `Filtered(2)` (bicubic, `ImageQuality.high`).
//!
//! One paint iteration emits one pixel column: four pixels (one per tile row)
//! as 16 f32 values in the layout `4 * (4 * dx + y) + c`. Only complete
//! 16-float groups are written, exactly like upstream's `chunks_exact_mut(16)`
//! loops; a trailing partial group is left untouched.
//!
//! Numerical conventions:
//! - Strict IEEE f32 arithmetic. Upstream's `.mul_add` is transcribed as the
//!   unfused `a * b + c` ([`simd.mulAddUnfused`]), matching the
//!   `fallback`/`baseline` `fearless_simd` backend the port targets.
//! - u8 samples are widened to f32 in `0..255` without normalization; each
//!   painter multiplies by `1.0 / 255.0` exactly where upstream does.
//! - Rust `f32 as u32` saturating casts are reproduced by [`f32ToU32`], for
//!   both pixel indices and the reflect-mode ULP bias.
//!
//! Divergences from upstream (behavior-preserving):
//! - The `impl Iterator` painters become `paint(dest: []f32)` methods, and the
//!   four painters are a tagged union instead of boxed trait objects.
//! - [`sample`] builds the `f32x16` directly from four `PremulRgba8` byte
//!   arrays instead of `u32x4 -> u8x16 -> u8_to_f32`; `toU8Array` and
//!   `to_ne_bytes` yield the same lane order.
//! - `f32ToU32` is a scalar lane loop rather than `to_int::<u32x4>`; the
//!   semantics are Rust's saturating float-to-int cast.
//!
//! Borrowing: the painters hold raw pointers to the encoded image and the
//! pixmap, matching upstream's `&'a` borrows. Both must outlive the painter.

const std = @import("std");
const simd = @import("../../simd/root.zig");
const kurbo = @import("../../kurbo/root.zig");
const peniko = @import("../../peniko/root.zig");
const encode = @import("../../common/encode.zig");
const pixmap_mod = @import("../../common/pixmap.zig");
const cpu_util = @import("../util.zig");

const F32x4 = simd.F32x4;
const F32x16 = simd.F32x16;
const U32x4 = simd.U32x4;

const Point = kurbo.Point;
const Affine = kurbo.Affine;
const Vec2 = kurbo.Vec2;
const Pixmap = pixmap_mod.Pixmap;
const Extend = peniko.Extend;
const ImageSampler = peniko.ImageSampler;

/// `1.0 / 255.0` (upstream splats this same f32 constant).
const ONE_OVER_255: f32 = 1.0 / 255.0;

/// `splat_pos`'s row mask: lane `r` is tile row `r`.
const COLUMN_MASK: F32x4 = .{ 0.0, 1.0, 2.0, 3.0 };

// ---------------------------------------------------------------------------
// Painter selection
// ---------------------------------------------------------------------------

/// A painter for an encoded image, chosen by [`ImagePainter.init`].
///
/// Upstream boxes one of four painter types at runtime; this port keeps the
/// same four variants in a tagged union so the caller can stack-allocate the
/// chosen painter and paint strip rows without dynamic dispatch.
pub const ImagePainter = union(enum) {
    /// Nearest-neighbor, axis-aligned (no skew).
    plain_nn: PlainNN,
    /// Nearest-neighbor with an arbitrary transform.
    nn: NN,
    /// Bilinear filtering (`ImageQuality.medium`).
    filtered_medium: Filtered(1),
    /// Bicubic filtering (`ImageQuality.high`).
    filtered_high: Filtered(2),

    /// Create the painter upstream's `indexed_fill` would select for `image`.
    ///
    /// `start_x`/`start_y` are the sampler coordinates of the first pixel
    /// center (upstream passes `f64(pixel) + 0.5`).
    pub fn init(
        image: *const encode.EncodedImage,
        pixmap: *const Pixmap,
        start_x: f64,
        start_y: f64,
    ) ImagePainter {
        if (cpu_util.nearestNeighbor(image)) {
            if (cpu_util.hasSkew(image)) {
                return .{ .nn = NN.init(image, pixmap, start_x, start_y) };
            }
            return .{ .plain_nn = PlainNN.init(image, pixmap, start_x, start_y) };
        }

        // Upstream's "plain medium quality" constructor is the same painter as
        // the generic filtered one.
        if (image.sampler.quality == .medium) {
            return .{ .filtered_medium = Filtered(1).init(image, pixmap, start_x, start_y) };
        }
        return .{ .filtered_high = Filtered(2).init(image, pixmap, start_x, start_y) };
    }

    /// Paint complete four-pixel columns into `dest` (16 f32 per column).
    ///
    /// A trailing partial group is left untouched, matching upstream's
    /// `chunks_exact_mut(16)`.
    pub fn paint(self: *ImagePainter, dest: []f32) void {
        switch (self.*) {
            inline else => |*painter| painter.paint(dest),
        }
    }
};

// ---------------------------------------------------------------------------
// Common painter data
// ---------------------------------------------------------------------------

/// Data shared by the image painters (upstream `ImagePainterData`).
///
/// `width`/`height` and their reciprocals are kept as f32x4 splats because
/// that is how [`extend`] consumes them upstream.
pub const ImagePainterData = struct {
    /// Position of the first pixel center in image space. The `NN` and
    /// `Filtered` painters advance this once per emitted pixel column.
    cur_pos: Point,
    /// The encoded image; painters read its sampler and advances.
    image: *const encode.EncodedImage,
    /// The source pixmap.
    pixmap: *const Pixmap,
    /// `(x, y)` components of `image.x_advance` as f32.
    x_advances: [2]f32,
    /// `(x, y)` components of `image.y_advance` as f32.
    y_advances: [2]f32,
    /// `pixmap.height` as f32, splatted.
    height: F32x4,
    /// `1.0 / height`, splatted.
    height_inv: F32x4,
    /// `pixmap.width` as f32, splatted.
    width: F32x4,
    /// `1.0 / width`, splatted.
    width_inv: F32x4,
    /// `pixmap.width` as u32, splatted.
    width_u32: U32x4,

    /// `start_pos` is the transformed first pixel position, stored as
    /// `cur_pos` (upstream's field name).
    pub fn init(
        image: *const encode.EncodedImage,
        pixmap: *const Pixmap,
        start_x: f64,
        start_y: f64,
    ) ImagePainterData {
        const width: f32 = @floatFromInt(pixmap.width);
        const height: f32 = @floatFromInt(pixmap.height);
        const start_pos = image.transform.transformPoint(Point.new(start_x, start_y));

        return .{
            .cur_pos = start_pos,
            .image = image,
            .pixmap = pixmap,
            .x_advances = .{ @floatCast(image.x_advance.x), @floatCast(image.x_advance.y) },
            .y_advances = .{ @floatCast(image.y_advance.x), @floatCast(image.y_advance.y) },
            .height = @splat(height),
            .height_inv = @splat(1.0 / height),
            .width = @splat(width),
            .width_inv = @splat(1.0 / width),
            .width_u32 = @splat(pixmap.width),
        };
    }
};

// ---------------------------------------------------------------------------
// Nearest-neighbor painters
// ---------------------------------------------------------------------------

/// Nearest-neighbor painter for images without skew (upstream
/// `PlainNNImagePainter`).
///
/// This is the fastest image path: only the x position of each row changes
/// between columns, so the y positions are computed once at construction.
pub const PlainNN = struct {
    data: ImagePainterData,
    /// Per-row y sample position, computed once.
    y_positions: F32x4,
    /// Per-row x sample position for the current column.
    cur_x_pos: F32x4,
    /// `image.x_advance.x` as f32; added to every row each column.
    advance: f32,

    const Self = @This();

    pub fn init(
        image: *const encode.EncodedImage,
        pixmap: *const Pixmap,
        start_x: f64,
        start_y: f64,
    ) Self {
        const data = ImagePainterData.init(image, pixmap, start_x, start_y);

        return .{
            .data = data,
            .y_positions = extend(
                splatPos(@floatCast(data.cur_pos.y), data.y_advances[1]),
                image.sampler.y_extend,
                data.height,
                data.height_inv,
            ),
            .cur_x_pos = splatPos(@floatCast(data.cur_pos.x), data.y_advances[0]),
            .advance = @floatCast(image.x_advance.x),
        };
    }

    pub fn paint(self: *Self, dest: []f32) void {
        var offset: usize = 0;
        while (offset + 16 <= dest.len) : (offset += 16) {
            const x_pos = extend(
                self.cur_x_pos,
                self.data.image.sampler.x_extend,
                self.data.width,
                self.data.width_inv,
            );
            const samples = sample(&self.data, x_pos, self.y_positions);
            self.cur_x_pos += @as(F32x4, @splat(self.advance));
            simd.storeSlice(samples * @as(F32x16, @splat(ONE_OVER_255)), dest[offset..][0..16]);
        }
    }
};

/// Nearest-neighbor painter for arbitrary transforms (upstream
/// `NNImagePainter`).
pub const NN = struct {
    data: ImagePainterData,

    const Self = @This();

    pub fn init(
        image: *const encode.EncodedImage,
        pixmap: *const Pixmap,
        start_x: f64,
        start_y: f64,
    ) Self {
        return .{ .data = ImagePainterData.init(image, pixmap, start_x, start_y) };
    }

    pub fn paint(self: *Self, dest: []f32) void {
        var offset: usize = 0;
        while (offset + 16 <= dest.len) : (offset += 16) {
            const x_positions = extend(
                splatPos(@floatCast(self.data.cur_pos.x), self.data.y_advances[0]),
                self.data.image.sampler.x_extend,
                self.data.width,
                self.data.width_inv,
            );
            const y_positions = extend(
                splatPos(@floatCast(self.data.cur_pos.y), self.data.y_advances[1]),
                self.data.image.sampler.y_extend,
                self.data.height,
                self.data.height_inv,
            );
            const samples = sample(&self.data, x_positions, y_positions);
            self.data.cur_pos = self.data.cur_pos.addVec(self.data.image.x_advance);
            simd.storeSlice(samples * @as(F32x16, @splat(ONE_OVER_255)), dest[offset..][0..16]);
        }
    }
};

// ---------------------------------------------------------------------------
// Filtered painter
// ---------------------------------------------------------------------------

/// Filtered image painter (upstream `FilteredImagePainter<QUALITY>`).
///
/// `quality` uses the numeric `ImageQuality` values: `1` is bilinear
/// (medium) filtering and `2` is bicubic (high) filtering.
pub fn Filtered(comptime quality: u8) type {
    if (quality != 1 and quality != 2) {
        @compileError("Filtered image painter quality must be 1 (bilinear) or 2 (bicubic)");
    }

    return struct {
        data: ImagePainterData,

        const Self = @This();

        pub fn init(
            image: *const encode.EncodedImage,
            pixmap: *const Pixmap,
            start_x: f64,
            start_y: f64,
        ) Self {
            return .{ .data = ImagePainterData.init(image, pixmap, start_x, start_y) };
        }

        pub fn paint(self: *Self, dest: []f32) void {
            var offset: usize = 0;
            while (offset + 16 <= dest.len) : (offset += 16) {
                simd.storeSlice(self.nextColumn(), dest[offset..][0..16]);
            }
        }

        /// Compute one pixel column, normalized to `[0, 1]` per component.
        fn nextColumn(self: *Self) F32x16 {
            // The base positions are not extended: only the individual taps
            // are, which is what lets the extend mode clamp each tap.
            const x_positions = splatPos(@floatCast(self.data.cur_pos.x), self.data.y_advances[0]);
            const y_positions = splatPos(@floatCast(self.data.cur_pos.y), self.data.y_advances[1]);

            const x_fract = fractFloor(x_positions + @as(F32x4, @splat(0.5)));
            const y_fract = fractFloor(y_positions + @as(F32x4, @splat(0.5)));

            var interpolated: F32x16 = @splat(0.0);

            if (quality == 1) {
                // Medium: bilinear. Sample the rectangle spanning the
                // (-0.5, -0.5)..(0.5, 0.5) offsets and interpolate linearly.
                // The sum of all `cx * cy` combinations is 1.0 (modulo
                // floating-point impreciseness), keeping colors in range.
                const one: F32x4 = @splat(1.0);
                const cx = [2]F32x4{ one - x_fract, x_fract };
                const cy = [2]F32x4{ one - y_fract, y_fract };

                const offsets = [2]f32{ -0.5, 0.5 };
                const x_taps = [2]F32x4{
                    extend(
                        x_positions + @as(F32x4, @splat(offsets[0])),
                        self.data.image.sampler.x_extend,
                        self.data.width,
                        self.data.width_inv,
                    ),
                    extend(
                        x_positions + @as(F32x4, @splat(offsets[1])),
                        self.data.image.sampler.x_extend,
                        self.data.width,
                        self.data.width_inv,
                    ),
                };
                const y_taps = [2]F32x4{
                    extend(
                        y_positions + @as(F32x4, @splat(offsets[0])),
                        self.data.image.sampler.y_extend,
                        self.data.height,
                        self.data.height_inv,
                    ),
                    extend(
                        y_positions + @as(F32x4, @splat(offsets[1])),
                        self.data.image.sampler.y_extend,
                        self.data.height,
                        self.data.height_inv,
                    ),
                };

                for (0..2) |x_idx| {
                    for (0..2) |y_idx| {
                        const color_sample = sample(&self.data, x_taps[x_idx], y_taps[y_idx]);
                        const w = simd.elementWiseSplat(cx[x_idx] * cy[y_idx]);
                        interpolated = simd.mulAddUnfused(w, color_sample, interpolated);
                    }
                }

                interpolated *= @as(F32x16, @splat(ONE_OVER_255));
            } else {
                // High: bicubic. Sample the 4x4 grid around the position with
                // a cubic (Mitchell, B = C = 1/3) filter.
                const cx = weights(x_fract);
                const cy = weights(y_fract);

                const offsets = [4]f32{ -1.5, -0.5, 0.5, 1.5 };
                const x_taps = [4]F32x4{
                    extend(
                        x_positions + @as(F32x4, @splat(offsets[0])),
                        self.data.image.sampler.x_extend,
                        self.data.width,
                        self.data.width_inv,
                    ),
                    extend(
                        x_positions + @as(F32x4, @splat(offsets[1])),
                        self.data.image.sampler.x_extend,
                        self.data.width,
                        self.data.width_inv,
                    ),
                    extend(
                        x_positions + @as(F32x4, @splat(offsets[2])),
                        self.data.image.sampler.x_extend,
                        self.data.width,
                        self.data.width_inv,
                    ),
                    extend(
                        x_positions + @as(F32x4, @splat(offsets[3])),
                        self.data.image.sampler.x_extend,
                        self.data.width,
                        self.data.width_inv,
                    ),
                };
                const y_taps = [4]F32x4{
                    extend(
                        y_positions + @as(F32x4, @splat(offsets[0])),
                        self.data.image.sampler.y_extend,
                        self.data.height,
                        self.data.height_inv,
                    ),
                    extend(
                        y_positions + @as(F32x4, @splat(offsets[1])),
                        self.data.image.sampler.y_extend,
                        self.data.height,
                        self.data.height_inv,
                    ),
                    extend(
                        y_positions + @as(F32x4, @splat(offsets[2])),
                        self.data.image.sampler.y_extend,
                        self.data.height,
                        self.data.height_inv,
                    ),
                    extend(
                        y_positions + @as(F32x4, @splat(offsets[3])),
                        self.data.image.sampler.y_extend,
                        self.data.height,
                        self.data.height_inv,
                    ),
                };

                for (0..4) |x_idx| {
                    for (0..4) |y_idx| {
                        const color_sample = sample(&self.data, x_taps[x_idx], y_taps[y_idx]);
                        const w = simd.elementWiseSplat(cx[x_idx] * cy[y_idx]);
                        interpolated = simd.mulAddUnfused(w, color_sample, interpolated);
                    }
                }

                interpolated *= @as(F32x16, @splat(ONE_OVER_255));

                // The cubic filter can overshoot, pushing a color component
                // above the (premultiplied) alpha. Clamp to alpha so later
                // u8-based compositing cannot overflow.
                const alphas = simd.splat4th(interpolated);
                interpolated = @min(interpolated, alphas);
                interpolated = @min(interpolated, @as(F32x16, @splat(1.0)));
                interpolated = @max(interpolated, @as(F32x16, @splat(0.0)));
            }

            self.data.cur_pos = self.data.cur_pos.addVec(self.data.image.x_advance);
            return interpolated;
        }
    };
}

// ---------------------------------------------------------------------------
// Sampling helpers
// ---------------------------------------------------------------------------

/// Upstream `PosExt::splat_pos` for `f32x4`: lane `r` is
/// `pos + f32(r) * y_advance`. The `x_advance` argument upstream also takes is
/// unused, so it is not part of this signature.
inline fn splatPos(pos: f32, y_advance: f32) F32x4 {
    return simd.mulAddUnfused(
        COLUMN_MASK,
        @as(F32x4, @splat(y_advance)),
        @as(F32x4, @splat(pos)),
    );
}

/// Positive fractional part: `val - floor(val)`, always in `[0, 1)` even for
/// negative inputs (upstream `fract_floor`).
pub fn fractFloor(val: F32x4) F32x4 {
    return val - @floor(val);
}

/// Upstream `extend`: map sample positions into the image for `mode`.
///
/// `max`/`inv_max` are the splats of the image dimension and its reciprocal.
/// Note that `max` is exclusive, so every branch clamps to `max - 1`.
pub fn extend(val: F32x4, mode: Extend, max: F32x4, inv_max: F32x4) F32x4 {
    const one: F32x4 = @splat(1.0);

    switch (mode) {
        .pad => {
            return @max(@min(val, max - one), @as(F32x4, @splat(0.0)));
        },
        .repeat => {
            // `(val * inv_max).floor() * max` is the nearest multiple of
            // `max` below `val`; subtracting it wraps `val` into range.
            const floored = @floor(val * inv_max);
            return @min(simd.mulAddUnfused(max, -floored, val), max - one);
        },
        .reflect => {
            // <https://github.com/google/skia/blob/220738774f7a0ce4a6c7bd17519a336e5e5dea5b/src/opts/SkRasterPipeline_opts.h#L3274-L3290>
            const two: F32x4 = @splat(2.0);
            const u = val - (@floor(val * inv_max * @as(F32x4, @splat(0.5))) * two) * max;
            const s = @floor(u * inv_max);
            const m = u - (two * s) * (u - max);

            const bias_in_ulps = @trunc(s);

            // Note that this is a wrapping subtraction of the raw bit
            // patterns. It would yield NaN if `m` were 0 with a positive
            // bias, but since `max` is always an integer, `u` and `s` must be
            // integers too and `m` is 0 only when the bias is 0.
            const m_bits: U32x4 = @bitCast(m);
            const biased_bits = m_bits -% f32ToU32Vec(bias_in_ulps);
            const reflected: F32x4 = @bitCast(biased_bits);
            return @min(reflected, max - one);
        },
    }
}

/// Sample four pixels, one per tile row, widening their RGBA bytes to f32
/// values in `0..255` without normalization (upstream `sample`, whose result
/// is then widened by `u8_to_f32`).
pub fn sample(data: *const ImagePainterData, x_positions: F32x4, y_positions: F32x4) F32x16 {
    // Release-mode Rust wraps here; debug builds panic on overflow, so the
    // wrapping operators also keep checked Zig builds quiet.
    const idx = f32ToU32Vec(x_positions) +% (f32ToU32Vec(y_positions) *% data.width_u32);

    var out: F32x16 = undefined;
    inline for (0..4) |lane| {
        const rgba = data.pixmap.sampleIdx(idx[lane]).toU8Array();
        inline for (0..4) |component| {
            out[lane * 4 + component] = @floatFromInt(rgba[component]);
        }
    }
    return out;
}

/// Rust's `f32 as u32` saturating cast: NaN and values at or below zero
/// become 0, values at or above `u32::MAX` saturate, everything else truncates
/// toward zero.
pub fn f32ToU32(value: f32) u32 {
    if (std.math.isNan(value)) return 0;
    if (value <= 0.0) return 0;
    if (value >= 4294967295.0) return std.math.maxInt(u32);
    return @intFromFloat(value);
}

/// Lane-wise [`f32ToU32`].
inline fn f32ToU32Vec(val: F32x4) U32x4 {
    var out: U32x4 = undefined;
    inline for (0..4) |lane| out[lane] = f32ToU32(val[lane]);
    return out;
}

// ---------------------------------------------------------------------------
// Cubic filter weights
// ---------------------------------------------------------------------------

/// The 4x4 cubic weights for a fractional value (upstream `weights`).
pub fn weights(fract: F32x4) [4]F32x4 {
    const mf = MF_RESAMPLER;
    return .{
        singleWeight(fract, @splat(mf[0][0]), @splat(mf[0][1]), @splat(mf[0][2]), @splat(mf[0][3])),
        singleWeight(fract, @splat(mf[1][0]), @splat(mf[1][1]), @splat(mf[1][2]), @splat(mf[1][3])),
        singleWeight(fract, @splat(mf[2][0]), @splat(mf[2][1]), @splat(mf[2][2]), @splat(mf[2][3])),
        singleWeight(fract, @splat(mf[3][0]), @splat(mf[3][1]), @splat(mf[3][2]), @splat(mf[3][3])),
    };
}

/// Upstream `single_weight`: `t.mul_add(d, c).mul_add(t, b).mul_add(t, a)`
/// with every `mul_add` unfused.
fn singleWeight(t: F32x4, a: F32x4, b: F32x4, c: F32x4, d: F32x4) F32x4 {
    const t1 = simd.mulAddUnfused(t, d, c);
    const t2 = simd.mulAddUnfused(t1, t, b);
    return simd.mulAddUnfused(t2, t, a);
}

/// Mitchell filter with `B = 1/3` and `C = 1/3` (upstream `mf_resampler`).
const MF_RESAMPLER: [4][4]f32 = mfResampler();

/// The resampling matrix for the Mitchell filter. See [`cubicResampler`].
fn mfResampler() [4][4]f32 {
    return cubicResampler(1.0 / 3.0, 1.0 / 3.0);
}

/// Cubic resampling matrix borrowed from Skia:
/// <https://github.com/google/skia/blob/220fef664978643a47d4559ae9e762b91aba534a/include/core/SkSamplingOptions.h#L33-L50>
///
/// `B` and `C` shape the cubic kernel; the resulting 4x4 matrix holds the
/// polynomial coefficients that [`weights`] evaluates at `x_fract`/`y_fract`.
fn cubicResampler(b: f32, c: f32) [4][4]f32 {
    return .{
        .{
            (1.0 / 6.0) * b,
            -(3.0 / 6.0) * b - c,
            (3.0 / 6.0) * b + 2.0 * c,
            -(1.0 / 6.0) * b - c,
        },
        .{
            1.0 - (2.0 / 6.0) * b,
            0.0,
            -3.0 + (12.0 / 6.0) * b + c,
            2.0 - (9.0 / 6.0) * b - c,
        },
        .{
            (1.0 / 6.0) * b,
            (3.0 / 6.0) * b + c,
            3.0 - (15.0 / 6.0) * b - 2.0 * c,
            -2.0 + (9.0 / 6.0) * b + c,
        },
        .{ 0.0, 0.0, -c, (1.0 / 6.0) * b + c },
    };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;
const paint_mod = @import("../../common/paint.zig");

/// A minimal encoded image; the painters only read its sampler, transform and
/// advances. `opaque_id` sources own nothing, so there is no cleanup.
fn testImage(
    sampler: ImageSampler,
    transform: Affine,
    x_advance: Vec2,
    y_advance: Vec2,
) encode.EncodedImage {
    return .{
        .source = paint_mod.ImageSource.initOpaqueId(paint_mod.ImageId.new(0)),
        .sampler = sampler,
        .may_have_transparency = false,
        .transform = transform,
        .x_advance = x_advance,
        .y_advance = y_advance,
        .tint = null,
    };
}

/// Compare one pixel column against expected RGBA bytes in `0..255`.
fn expectColumn(dest: []const f32, column: usize, expected: [4][4]u8) !void {
    for (expected, 0..) |pixel, y| {
        for (pixel, 0..) |byte, component| {
            const actual = dest[column * 16 + 4 * y + component];
            const wanted = @as(f32, @floatFromInt(byte)) * ONE_OVER_255;
            try testing.expectEqual(wanted, actual);
        }
    }
}

test "extend pad clamps into [0, max - 1]" {
    const max: F32x4 = @splat(4.0);
    const inv_max: F32x4 = @splat(1.0 / 4.0);
    const result = extend(F32x4{ -2.0, -0.5, 3.5, 5.0 }, .pad, max, inv_max);
    try testing.expectEqual(F32x4{ 0.0, 0.0, 3.0, 3.0 }, result);
}

test "extend repeat wraps into [0, max - 1]" {
    const max: F32x4 = @splat(4.0);
    const inv_max: F32x4 = @splat(1.0 / 4.0);
    const result = extend(F32x4{ -1.0, 0.5, 3.9, 4.5 }, .repeat, max, inv_max);
    try testing.expectEqual(F32x4{ 3.0, 0.5, 3.0, 0.5 }, result);
}

test "extend reflect mirrors and wraps at multiples of max" {
    const max: F32x4 = @splat(4.0);
    const inv_max: F32x4 = @splat(1.0 / 4.0);
    const result = extend(F32x4{ 0.5, 2.5, 8.0, -8.0 }, .reflect, max, inv_max);
    try testing.expectEqual(F32x4{ 0.5, 2.5, 0.0, 0.0 }, result);
}

test "extend_overflow (upstream test)" {
    const max: F32x4 = @splat(128.0);
    const max_inv: F32x4 = @splat(1.0 / 128.0);

    const num: F32x4 = @splat(127.00001);
    const res = extend(num, .repeat, max, max_inv);

    try testing.expect(res[0] <= 127.0);
}

test "extend keeps every finite input in range" {
    const max: F32x4 = @splat(8.0);
    const inv_max: F32x4 = @splat(1.0 / 8.0);

    var i: i32 = -40;
    while (i <= 40) : (i += 1) {
        const val: F32x4 = @splat(@as(f32, @floatFromInt(i)) * 0.7);
        inline for (.{ Extend.pad, Extend.repeat, Extend.reflect }) |mode| {
            const result = extend(val, mode, max, inv_max);
            inline for (0..4) |lane| {
                try testing.expect(result[lane] >= 0.0 and result[lane] <= 7.0);
            }
        }
    }
}

test "fract_floor returns the positive fractional part" {
    const result = fractFloor(F32x4{ -1.25, -0.5, 0.0, 2.75 });
    try testing.expectEqual(F32x4{ 0.75, 0.5, 0.0, 0.75 }, result);
}

test "f32_to_u32 matches Rust saturating casts" {
    try testing.expectEqual(@as(u32, 0), f32ToU32(std.math.nan(f32)));
    try testing.expectEqual(@as(u32, 0), f32ToU32(-1.5));
    try testing.expectEqual(@as(u32, 0), f32ToU32(-0.0));
    try testing.expectEqual(@as(u32, 0), f32ToU32(0.99));
    try testing.expectEqual(@as(u32, 3), f32ToU32(3.99));
    try testing.expectEqual(std.math.maxInt(u32), f32ToU32(std.math.inf(f32)));
    try testing.expectEqual(std.math.maxInt(u32), f32ToU32(1.0e30));
}

test "cubic weights sum to one" {
    const fract: F32x4 = .{ 0.0, 0.25, 0.5, 0.75 };
    const w = weights(fract);
    inline for (0..4) |lane| {
        var sum: f32 = 0.0;
        inline for (0..4) |tap| sum += w[tap][lane];
        try testing.expectApproxEqAbs(@as(f32, 1.0), sum, 1.0e-6);
    }
}

test "sample reads one rgba quad per tile row" {
    const allocator = testing.allocator;
    var pixmap = try Pixmap.init(allocator, 2, 2);
    defer pixmap.deinit(allocator);
    pixmap.setPixel(0, 0, .{ .r = 10, .g = 20, .b = 30, .a = 40 });
    pixmap.setPixel(1, 0, .{ .r = 50, .g = 60, .b = 70, .a = 80 });
    pixmap.setPixel(0, 1, .{ .r = 90, .g = 100, .b = 110, .a = 120 });
    pixmap.setPixel(1, 1, .{ .r = 130, .g = 140, .b = 150, .a = 160 });

    const image = testImage(
        ImageSampler.new(),
        Affine.IDENTITY,
        Vec2.new(1.0, 0.0),
        Vec2.new(0.0, 1.0),
    );
    const data = ImagePainterData.init(&image, &pixmap, 0.5, 0.5);

    // Lane 0 -> (0, 0), lane 1 -> (1, 0), lane 2 -> (0, 1), lane 3 -> (1, 1).
    const result = sample(&data, .{ 0.0, 1.0, 0.0, 1.0 }, .{ 0.0, 0.0, 1.0, 1.0 });
    try testing.expectEqual(F32x16{
        10,  20,  30,  40,
        50,  60,  70,  80,
        90,  100, 110, 120,
        130, 140, 150, 160,
    }, result);
}

test "plain_nn emits a normalized column and ignores a partial group" {
    const allocator = testing.allocator;
    var pixmap = try Pixmap.init(allocator, 2, 2);
    defer pixmap.deinit(allocator);
    pixmap.setPixel(0, 0, .{ .r = 10, .g = 20, .b = 30, .a = 40 });
    pixmap.setPixel(1, 0, .{ .r = 50, .g = 60, .b = 70, .a = 80 });
    pixmap.setPixel(0, 1, .{ .r = 90, .g = 100, .b = 110, .a = 120 });
    pixmap.setPixel(1, 1, .{ .r = 130, .g = 140, .b = 150, .a = 160 });

    const image = testImage(
        ImageSampler.new().withQuality(.low),
        Affine.IDENTITY,
        Vec2.new(1.0, 0.0),
        Vec2.new(0.0, 1.0),
    );
    var painter = ImagePainter.init(&image, &pixmap, 0.5, 0.5);
    try testing.expectEqual(std.meta.Tag(ImagePainter).plain_nn, std.meta.activeTag(painter));

    // One complete column plus a trailing partial group that must be left
    // untouched.
    var dest: [20]f32 = @splat(-1.0);
    painter.paint(&dest);

    // Rows 1..3 clamp to y = 1.0 under `.pad`.
    try expectColumn(&dest, 0, .{
        .{ 10, 20, 30, 40 },
        .{ 90, 100, 110, 120 },
        .{ 90, 100, 110, 120 },
        .{ 90, 100, 110, 120 },
    });
    for (dest[16..20]) |value| {
        try testing.expectEqual(@as(f32, -1.0), value);
    }
}

test "nn painter recomputes both axes per column" {
    const allocator = testing.allocator;
    var pixmap = try Pixmap.init(allocator, 2, 2);
    defer pixmap.deinit(allocator);
    pixmap.setPixel(0, 0, .{ .r = 10, .g = 20, .b = 30, .a = 40 });
    pixmap.setPixel(1, 0, .{ .r = 50, .g = 60, .b = 70, .a = 80 });
    pixmap.setPixel(0, 1, .{ .r = 90, .g = 100, .b = 110, .a = 120 });
    pixmap.setPixel(1, 1, .{ .r = 130, .g = 140, .b = 150, .a = 160 });

    const image = testImage(
        ImageSampler.new().withQuality(.low),
        Affine.IDENTITY,
        Vec2.new(1.0, 0.0),
        Vec2.new(0.0, 1.0),
    );
    var painter = NN.init(&image, &pixmap, 0.5, 0.5);

    var dest: [16]f32 = @splat(0.0);
    painter.paint(&dest);

    try expectColumn(&dest, 0, .{
        .{ 10, 20, 30, 40 },
        .{ 90, 100, 110, 120 },
        .{ 90, 100, 110, 120 },
        .{ 90, 100, 110, 120 },
    });
}

test "filtered_medium bilinearly blends two texels" {
    const allocator = testing.allocator;
    var pixmap = try Pixmap.init(allocator, 2, 2);
    defer pixmap.deinit(allocator);
    pixmap.setPixel(0, 0, .{ .r = 10, .g = 20, .b = 30, .a = 40 });
    pixmap.setPixel(1, 0, .{ .r = 50, .g = 60, .b = 70, .a = 80 });
    pixmap.setPixel(0, 1, .{ .r = 90, .g = 100, .b = 110, .a = 120 });
    pixmap.setPixel(1, 1, .{ .r = 130, .g = 140, .b = 150, .a = 160 });

    const image = testImage(
        ImageSampler.new().withQuality(.medium),
        Affine.IDENTITY,
        Vec2.new(1.0, 0.0),
        Vec2.new(0.0, 1.0),
    );
    // x = 1.0 has fraction 0.5, so the taps land on texel columns 0 and 1;
    // each lane's y fraction is 0, so it samples its own (clamped) row.
    var painter = ImagePainter.init(&image, &pixmap, 1.0, 0.5);
    try testing.expectEqual(std.meta.Tag(ImagePainter).filtered_medium, std.meta.activeTag(painter));

    var dest: [16]f32 = @splat(0.0);
    painter.paint(&dest);

    try expectColumn(&dest, 0, .{
        .{ 30, 40, 50, 60 }, // (10 + 50) / 2, ...
        .{ 110, 120, 130, 140 },
        .{ 110, 120, 130, 140 },
        .{ 110, 120, 130, 140 },
    });
}

test "filtered_high clamps rgb to alpha" {
    const allocator = testing.allocator;
    var pixmap = try Pixmap.init(allocator, 3, 3);
    defer pixmap.deinit(allocator);
    // A high-contrast checkerboard makes the cubic kernel overshoot; every
    // pixel is opaque, so premultiplied output must stay in [0, 1].
    for (0..3) |y| {
        for (0..3) |x| {
            const value: u8 = if ((x + y) % 2 == 0) 0 else 255;
            pixmap.setPixel(@intCast(x), @intCast(y), .{ .r = value, .g = value, .b = value, .a = 255 });
        }
    }

    const image = testImage(
        ImageSampler.new().withQuality(.high),
        Affine.IDENTITY,
        Vec2.new(1.0, 0.0),
        Vec2.new(0.0, 1.0),
    );
    var painter = ImagePainter.init(&image, &pixmap, 0.5, 0.5);
    try testing.expectEqual(std.meta.Tag(ImagePainter).filtered_high, std.meta.activeTag(painter));

    var dest: [16]f32 = @splat(-1.0);
    painter.paint(&dest);

    for (0..4) |pixel| {
        const r = dest[4 * pixel + 0];
        const g = dest[4 * pixel + 1];
        const b = dest[4 * pixel + 2];
        const a = dest[4 * pixel + 3];
        for ([_]f32{ r, g, b, a }) |value| {
            try testing.expect(std.math.isFinite(value));
            try testing.expect(value >= 0.0 and value <= 1.0);
        }
        try testing.expect(r <= a and g <= a and b <= a);
    }
}

test "image painter selection matches upstream" {
    const allocator = testing.allocator;
    var pixmap = try Pixmap.init(allocator, 1, 1);
    defer pixmap.deinit(allocator);

    const Tag = std.meta.Tag(ImagePainter);
    const neutral_transform = Affine.IDENTITY;
    const x_only = Vec2.new(1.0, 0.0);
    const y_only = Vec2.new(0.0, 1.0);

    const axis_aligned = testImage(ImageSampler.new().withQuality(.low), neutral_transform, x_only, y_only);
    try testing.expectEqual(Tag.plain_nn, std.meta.activeTag(ImagePainter.init(&axis_aligned, &pixmap, 0.5, 0.5)));

    const skewed = testImage(
        ImageSampler.new().withQuality(.low),
        neutral_transform,
        Vec2.new(1.0, 0.25),
        y_only,
    );
    try testing.expectEqual(Tag.nn, std.meta.activeTag(ImagePainter.init(&skewed, &pixmap, 0.5, 0.5)));

    const medium = testImage(ImageSampler.new().withQuality(.medium), neutral_transform, x_only, y_only);
    try testing.expectEqual(Tag.filtered_medium, std.meta.activeTag(ImagePainter.init(&medium, &pixmap, 0.5, 0.5)));

    const high = testImage(ImageSampler.new().withQuality(.high), neutral_transform, x_only, y_only);
    try testing.expectEqual(Tag.filtered_high, std.meta.activeTag(ImagePainter.init(&high, &pixmap, 0.5, 0.5)));
}
