//! Port of vello_cpu src/fine/common/rounded_blurred_rect.rs (Apache-2.0 OR
//! MIT).
//!
//! Drawing blurred, rounded rectangles. The implementation is adapted from
//! <https://git.sr.ht/~raph/blurrr/tree/master/src/distfield.rs>.
//!
//! The upstream filler is a `Painter` over 8-lane `f32x8` vectors; this port
//! keeps the same lane layout and operation order and exposes `paint`/`paintU8`
//! with the same contract as the other M2 painters (`gradient.zig`,
//! `image.zig`): only complete chunks are written, trailing pixels keep
//! whatever the caller initialized the buffer with.
//!
//! Ownership/allocator note: the filler borrows the encoded rectangle for the
//! duration of a single `paint` call and owns no heap data.

const std = @import("std");
const simd = @import("../../simd/root.zig");
const kurbo = @import("../../kurbo/root.zig");
const encode = @import("../../common/encode.zig");
const math = @import("../../common/math.zig");
const common_util = @import("../../common/util.zig");

const Point = kurbo.Point;
const Vec2 = kurbo.Vec2;
const F32x4 = simd.F32x4;
const F32x8 = simd.F32x8;

/// Iterator that emits one f32x8 of blur coverage per call.
///
/// The vector layout matches `f32x8::splat_pos`: lanes 0-3 are a pixel column
/// (four rows down the tile) and lanes 4-7 are the next column, i.e. eight
/// pixels in column-major order.
pub const BlurredRoundedRectFiller = struct {
    r: F32x8,
    g: F32x8,
    b: F32x8,
    a: F32x8,
    invert: bool,
    alpha_calculator: AlphaCalculator,

    /// Create a filler for one span.
    ///
    /// `start_x`/`start_y` are the sample position of the first pixel
    /// (upstream `sampler_x`/`sampler_y`).
    pub fn init(
        rect: *const encode.EncodedBlurredRoundedRectangle,
        start_x: f64,
        start_y: f64,
    ) BlurredRoundedRectFiller {
        const start_pos = rect.transform.transformPoint(Point.new(start_x, start_y));
        const color_components = rect.color.asPremulF32().components;

        return .{
            .r = @splat(color_components[0]),
            .g = @splat(color_components[1]),
            .b = @splat(color_components[2]),
            .a = @splat(color_components[3]),
            .invert = rect.invert,
            .alpha_calculator = AlphaCalculator.init(
                start_pos,
                rect.x_advance,
                rect.y_advance,
                rect,
            ),
        };
    }

    /// Paint one span into `dest`, processing complete 8-pixel chunks only.
    pub fn paint(self: *BlurredRoundedRectFiller, dest: []f32) void {
        var i: usize = 0;
        while (i + 32 <= dest.len) : (i += 32) {
            const result = self.nextResult();

            inline for (0..8) |lane| {
                dest[i + 4 * lane] = result.r[lane];
                dest[i + 4 * lane + 1] = result.g[lane];
                dest[i + 4 * lane + 2] = result.b[lane];
                dest[i + 4 * lane + 3] = result.a[lane];
            }
        }
    }

    /// Paint one span as u8 bytes, processing complete 16-pixel (64-byte)
    /// chunks only.
    ///
    /// This is upstream's `Painter::paint_u8` for
    /// `BlurredRoundedRectFiller`: two f32x8 results per chunk, converted
    /// through `u8x16::from_f32` (`f32_to_u8(v * 255 + 0.5)`, saturating).
    /// The f32 kernel never calls it; the u8 kernel's `apply_painter` does
    /// (upstream implements both methods on the same filler).
    pub fn paintU8(self: *BlurredRoundedRectFiller, dest: []u8) void {
        var i: usize = 0;
        while (i + 64 <= dest.len) : (i += 64) {
            const first = self.nextResult();
            const second = self.nextResult();

            const r = columnToU8(simd.combineF32x8(first.r, second.r));
            const g = columnToU8(simd.combineF32x8(first.g, second.g));
            const b = columnToU8(simd.combineF32x8(first.b, second.b));
            const a = columnToU8(simd.combineF32x8(first.a, second.a));

            inline for (0..16) |lane| {
                dest[i + 4 * lane] = r[lane];
                dest[i + 4 * lane + 1] = g[lane];
                dest[i + 4 * lane + 2] = b[lane];
                dest[i + 4 * lane + 3] = a[lane];
            }
        }
    }

    /// One alpha-calculator step with the invert fold applied (upstream
    /// `Iterator::next`).
    fn nextResult(self: *BlurredRoundedRectFiller) struct {
        r: F32x8,
        g: F32x8,
        b: F32x8,
        a: F32x8,
    } {
        var coverage = self.alpha_calculator.next();
        if (self.invert) {
            coverage = @as(F32x8, @splat(1.0)) - coverage;
        }

        return .{
            .r = self.r * coverage,
            .g = self.g * coverage,
            .b = self.b * coverage,
            .a = self.a * coverage,
        };
    }
};

/// Convert one normalized f32 pixel column to bytes (upstream
/// `u8x16::from_f32`).
fn columnToU8(column: simd.F32x16) simd.U8x16 {
    return common_util.f32ToU8(simd.mulAddUnfused(
        column,
        @as(simd.F32x16, @splat(255.0)),
        @as(simd.F32x16, @splat(0.5)),
    ));
}

/// Blur-coverage iterator (upstream `AlphaCalculator`).
const AlphaCalculator = struct {
    cur_pos: Point,
    x_advance: Vec2,
    y_advance: Vec2,
    rect: *const encode.EncodedBlurredRoundedRectangle,

    fn init(
        start_pos: Point,
        x_advance: Vec2,
        y_advance: Vec2,
        rect: *const encode.EncodedBlurredRoundedRectangle,
    ) AlphaCalculator {
        return .{
            .cur_pos = start_pos,
            .x_advance = x_advance,
            .y_advance = y_advance,
            .rect = rect,
        };
    }

    fn next(self: *AlphaCalculator) F32x8 {
        const x_advance_x: f32 = @floatCast(self.x_advance.x);
        const x_advance_y: f32 = @floatCast(self.x_advance.y);
        const y_advance_x: f32 = @floatCast(self.y_advance.x);
        const y_advance_y: f32 = @floatCast(self.y_advance.y);

        const i_pos = splatPos(@floatCast(self.cur_pos.x), x_advance_x, y_advance_x);
        const j_pos = splatPos(@floatCast(self.cur_pos.y), x_advance_y, y_advance_y);

        const rect = self.rect;
        const v1: F32x8 = @splat(0.5);
        const v0: F32x8 = @splat(0.0);
        const height: F32x8 = @splat(rect.height);
        const width: F32x8 = @splat(rect.width);
        const r1: F32x8 = @splat(rect.r1);
        const h: F32x8 = @splat(rect.h);
        const w: F32x8 = @splat(rect.w);
        const scale: F32x8 = @splat(rect.scale);
        const std_dev_inv: F32x8 = @splat(rect.std_dev_inv);
        const min_edge: F32x8 = @splat(rect.min_edge);

        const y = j_pos - v1 * height;
        // Equivalent to `r1 + |y| - h * 0.5`; `mulSub` is a separate
        // multiply/subtract on the baseline backend, so keep it unfused.
        const y0 = r1 - simd.mulAddUnfused(h, v1, -@abs(y));
        const y1 = @max(y0, v0);

        const x = i_pos - v1 * width;
        const x0 = r1 - simd.mulAddUnfused(w, v1, -@abs(x));
        const x1 = @max(x0, v0);

        const d_pos = powF32x8(
            powF32x8(x1, rect.exponent) + powF32x8(y1, rect.exponent),
            rect.recip_exponent,
        );
        const d_neg = @min(@max(x0, y0), v0);
        const d = d_pos + d_neg - r1;
        const z = scale * (erf7F32x8(std_dev_inv * (min_edge + d)) -
            erf7F32x8(std_dev_inv * d));

        self.cur_pos = self.cur_pos.addVec(self.x_advance.mulScalar(2.0));

        return z;
    }
};

/// Upstream `f32x8::splat_pos`: one `f32x4::splat_pos` for the first pixel
/// column and one for the column one x advance further along (the same helper
/// as `cpu/fine/gradient.zig`; kept local because upstream's is a SIMD trait
/// method).
inline fn splatPos(pos: f32, x_advance: f32, y_advance: f32) F32x8 {
    return simd.combineF32x4(splatPos4(pos, y_advance), splatPos4(pos + x_advance, y_advance));
}

/// Upstream `f32x4::splat_pos`: lane `r` is `f32(r) * y_advance + pos`.
inline fn splatPos4(pos: f32, y_advance: f32) F32x4 {
    const columns: F32x4 = .{ 0.0, 1.0, 2.0, 3.0 };
    return simd.mulAddUnfused(columns, @as(F32x4, @splat(y_advance)), @as(F32x4, @splat(pos)));
}

/// Vector `powf`: upstream loops over the eight lanes calling `f32::powf`.
fn powF32x8(base: F32x8, exponent: f32) F32x8 {
    var out: F32x8 = undefined;
    inline for (0..8) |lane| {
        // adapt: upstream calls `f32::powf` (libm `powf`); `std.math.pow` is
        // the portable two-argument `pow` used elsewhere in the port.
        out[lane] = std.math.pow(f32, base[lane], exponent);
    }
    return out;
}

/// Vector `compute_erf7` (upstream `FloatExt for f32x8`).
fn erf7F32x8(value: F32x8) F32x8 {
    var out: F32x8 = undefined;
    inline for (0..8) |lane| {
        out[lane] = math.computeErf7(value[lane]);
    }
    return out;
}

test "filler writes two columns per chunk" {
    const rect = encode.EncodedBlurredRoundedRectangle{
        .exponent = 1.0,
        .recip_exponent = 1.0,
        .scale = 0.5,
        .std_dev_inv = 1.0,
        .min_edge = 20.0,
        .w = 20.0,
        .h = 20.0,
        .width = 20.0,
        .height = 20.0,
        .r1 = 10.0,
        .invert = false,
        .color = @import("../../common/paint.zig").PremulColor.fromAlphaColor(
            @import("../../peniko/root.zig").Color.BLACK,
        ),
        .transform = kurbo.Affine.IDENTITY,
        .x_advance = Vec2.new(1.0, 0.0),
        .y_advance = Vec2.new(0.0, 1.0),
    };

    var filler = BlurredRoundedRectFiller.init(&rect, 0.5, 0.5);
    var dest: [32]f32 = @splat(-1.0);
    filler.paint(&dest);

    // Every lane was written and the color is opaque black with coverage
    // scaling both the color (0) and alpha.
    for (0..8) |lane| {
        try std.testing.expectEqual(@as(f32, 0.0), dest[4 * lane]);
        try std.testing.expect(dest[4 * lane + 3] >= 0.0);
    }
    // A trailing partial chunk is left untouched.
    var partial: [16]f32 = @splat(-1.0);
    var filler2 = BlurredRoundedRectFiller.init(&rect, 0.5, 0.5);
    filler2.paint(&partial);
    try std.testing.expectEqual(@as(f32, -1.0), partial[15]);
}
