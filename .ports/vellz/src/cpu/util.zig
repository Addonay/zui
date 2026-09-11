//! Port of vello_cpu src/util.rs (Apache-2.0 OR MIT).
//!
//! Ownership/allocator note: everything in this file is a plain value; there
//! is no heap ownership and no allocator is taken.
//!
//! Rust traits become free functions over the fixed-width vectors from
//! `src/simd` (`NormalizedMulExt`, `Premultiply`). `EncodedImageExt` becomes a
//! pair of duck-typed helpers, so this file does not depend on the M2
//! `EncodedImage` type; both only read `x_advance`/`y_advance`/`sampler`.
//!
//! The upstream `scalar::div_255` is `(val + 255) >> 8`; the vector
//! `Div255Ext` used by `common/util.zig` keeps the same rounding behavior for
//! vectors.

const std = @import("std");
const simd = @import("../simd/root.zig");
const peniko = @import("../peniko/root.zig");
const math = @import("../common/math.zig");

/// Mirrors `Tile::WIDTH`; kept local so this file stays independent of the
/// in-flight `common/tile.zig` (see the leaf rule in `common/util.zig`).
pub const TILE_WIDTH: u16 = 4;
/// Mirrors `Tile::HEIGHT`; kept local for the same reason as [`TILE_WIDTH`].
pub const TILE_HEIGHT: u16 = 4;

/// Perform an approximate division by 255.
///
/// There are three reasons for having this method.
/// 1) Divisions are slower than shifting + adding, and the compiler does not
///    replace divisions by 255 with an equivalent.
/// 2) Integer divisions are usually not available in SIMD, so this provides a
///    good baseline implementation.
/// 3) There are two options for performing the division: the first exactly
///    preserves the rounding semantics of an integer division by 255
///    (`(val + 1 + (val >> 8)) >> 8`); the second (used here) has slightly
///    different rounding behavior but is much faster
///    (<https://github.com/linebender/vello/issues/904>), and is therefore
///    preferable for the high-performance pipeline.
///
/// Four properties worth mentioning:
/// - This actually calculates the ceiling of `val / 256`.
/// - Within the allowed range, rounding errors do not appear for values
///   divisible by 255, i.e. any call `div_255(val * 255)` always yields `val`.
/// - If there is a discrepancy, this division yields a value 1 higher than the
///   original.
/// - This holds for values of `val` up to and including `65279`. Do not call
///   this function with higher values.
pub fn div255(val: u16) u16 {
    std.debug.assert(val < 65280);
    return (val + 255) >> 8;
}

/// `NormalizedMulExt::normalized_mul` for `u8x32`: widen to `u16x32`, multiply,
/// divide by 255 with [`div255`] semantics, and narrow back to `u8x32`.
///
/// The wide vector type is local because `src/simd` only declares the widths
/// the upstream crates use directly.
pub fn normalizedMulU8(a: simd.U8x32, b: simd.U8x32) simd.U8x32 {
    const Wide = @Vector(32, u16);
    const Shift = @Vector(32, std.math.Log2Int(u16));
    const wide_a: Wide = a;
    const wide_b: Wide = b;
    const products = wide_a * wide_b;
    const divided = (products + @as(Wide, @splat(255))) >> @as(Shift, @splat(8));
    return @truncate(divided);
}

/// `Premultiply::premultiply` for `f32x4`.
///
/// Color components must already be premultiplied; the alpha vector is just
/// multiplied in.
pub fn premultiply(v: simd.F32x4, alphas: simd.F32x4) simd.F32x4 {
    return v * alphas;
}

/// `Premultiply::unpremultiply` for `f32x4`.
///
/// Performs `self / alphas`, but returns zero in every lane where `alphas` is
/// zero (upstream `select_f32x4(simd_eq(alphas, 0), 0, divided)`), avoiding the
/// NaN/Inf that the division alone would produce.
pub fn unpremultiply(v: simd.F32x4, alphas: simd.F32x4) simd.F32x4 {
    const zero: simd.F32x4 = @splat(0.0);
    const divided = v / alphas;
    return simd.select(simd.F32x4, alphas == zero, zero, divided);
}

/// `EncodedImageExt::has_skew`: whether the image transform has a non-zero
/// skew component.
pub fn hasSkew(image: anytype) bool {
    return !math.isNearlyZero(@as(f32, @floatCast(image.x_advance.y))) or
        !math.isNearlyZero(@as(f32, @floatCast(image.y_advance.x)));
}

/// `EncodedImageExt::nearest_neighbor`: whether the sampler requests the `Low`
/// quality (nearest-neighbor) path.
pub fn nearestNeighbor(image: anytype) bool {
    return image.sampler.quality == .low;
}

/// A horizontal span in pixel coordinates.
pub const Span = struct {
    /// The horizontal start position in pixels.
    x: u16,
    /// The horizontal span width in pixels.
    width: u16,

    /// Creates a span from pixel coordinates.
    pub fn new(x: u16, width: u16) Span {
        return .{ .x = x, .width = width };
    }

    /// Creates a span from tile coordinates.
    pub fn newTile(tile_x: u16, tile_width: u16) Span {
        return .{
            .x = tile_x * TILE_WIDTH,
            .width = tile_width * TILE_WIDTH,
        };
    }

    /// Returns the horizontal start position in tile coordinates.
    pub fn tileX(self: Span) u16 {
        return self.x / TILE_WIDTH;
    }

    /// Returns the exclusive horizontal end position in tile coordinates.
    pub fn tileEnd(self: Span) u16 {
        return divCeilU16(self.pixelEnd(), TILE_WIDTH);
    }

    /// Extends this span to include another span.
    pub fn extend(self: *Span, other: Span) void {
        const x = @min(self.x, other.x);
        const end = @max(self.pixelEnd(), other.pixelEnd());
        self.* = Span.new(x, end -| x);
    }

    /// Returns the intersection of this span with another span.
    pub fn intersect(self: Span, other: Span) ?Span {
        const x = @max(self.x, other.x);
        const end = @min(self.pixelEnd(), other.pixelEnd());
        if (x < end) return Span.new(x, end - x);
        return null;
    }

    /// Returns the horizontal start position in pixels.
    pub fn pixelX(self: Span) u16 {
        return self.x;
    }

    /// Returns the horizontal span width in pixels.
    pub fn pixelWidth(self: Span) u16 {
        return self.width;
    }

    /// Returns the exclusive horizontal end position in pixels.
    pub fn pixelEnd(self: Span) u16 {
        return self.x +| self.width;
    }
};

fn divCeilU16(value: u16, divisor: u16) u16 {
    // Rust's `u16::div_ceil` does not overflow; `(value + divisor - 1) / divisor`
    // would for `value` close to `u16::MAX`.
    if (value % divisor == 0) return value / divisor;
    return value / divisor + 1;
}

test "div_255_properties" {
    var i: u32 = 0;
    while (i < 256 * 255) : (i += 1) {
        const value: u16 = @intCast(i);
        const expected: u16 = @intCast(i / 255);
        const actual = div255(value);

        if (expected > actual) {
            std.debug.print(
                "div_255({d}) = {d} should be >= {d}\n",
                .{ value, actual, expected },
            );
            return error.TestUnexpectedResult;
        }

        const diff = if (expected > actual) expected - actual else actual - expected;
        if (diff > 1) {
            std.debug.print("div_255({d}) rounding error {d} > 1\n", .{ value, diff });
            return error.TestUnexpectedResult;
        }

        if (i % 255 == 0 and diff != 0) {
            std.debug.print("div_255({d}) must be exact for multiples of 255\n", .{value});
            return error.TestUnexpectedResult;
        }
    }
}

test "normalized_mul_u8x32" {
    const a: simd.U8x32 = @splat(200);
    const b: simd.U8x32 = @splat(128);
    const result = normalizedMulU8(a, b);
    try std.testing.expectEqual(@as(u8, 100), result[0]);

    const max = normalizedMulU8(@as(simd.U8x32, @splat(255)), @as(simd.U8x32, @splat(255)));
    try std.testing.expectEqual(@as(u8, 255), max[0]);
    const zero = normalizedMulU8(@as(simd.U8x32, @splat(0)), @as(simd.U8x32, @splat(255)));
    try std.testing.expectEqual(@as(u8, 0), zero[0]);
}

test "premultiply_and_unpremultiply" {
    const color: simd.F32x4 = .{ 0.5, 0.25, 1.0, 0.5 };
    const alpha: simd.F32x4 = .{ 0.5, 0.5, 0.5, 0.5 };
    try std.testing.expectEqual(
        simd.F32x4{ 0.25, 0.125, 0.5, 0.25 },
        premultiply(color, alpha),
    );
    try std.testing.expectEqual(
        simd.F32x4{ 1.0, 0.5, 2.0, 1.0 },
        unpremultiply(simd.F32x4{ 0.5, 0.25, 1.0, 0.5 }, alpha),
    );

    // Zero alpha lanes must produce zero, not Inf/NaN.
    const zero_alpha: simd.F32x4 = .{ 0.0, 0.5, 0.0, 0.5 };
    try std.testing.expectEqual(
        simd.F32x4{ 0.0, 1.0, 0.0, 1.0 },
        unpremultiply(simd.F32x4{ 0.25, 0.5, 0.25, 0.5 }, zero_alpha),
    );
}

test "encoded_image_ext" {
    const FakeImage = struct {
        x_advance: struct { x: f64, y: f64 },
        y_advance: struct { x: f64, y: f64 },
        sampler: struct { quality: peniko.ImageQuality },
    };

    const axis_aligned = FakeImage{
        .x_advance = .{ .x = 1.0, .y = 0.0 },
        .y_advance = .{ .x = 0.0, .y = 1.0 },
        .sampler = .{ .quality = .medium },
    };
    try std.testing.expect(!hasSkew(axis_aligned));
    try std.testing.expect(!nearestNeighbor(axis_aligned));

    const skewed = FakeImage{
        .x_advance = .{ .x = 1.0, .y = 0.5 },
        .y_advance = .{ .x = 0.0, .y = 1.0 },
        .sampler = .{ .quality = .low },
    };
    try std.testing.expect(hasSkew(skewed));
    try std.testing.expect(nearestNeighbor(skewed));

    const slight_skew = FakeImage{
        .x_advance = .{ .x = 1.0, .y = 1.0 / 8192.0 },
        .y_advance = .{ .x = 0.0, .y = 1.0 },
        .sampler = .{ .quality = .medium },
    };
    try std.testing.expect(!hasSkew(slight_skew));
}

test "span basics" {
    const span = Span.new(3, 4);
    try std.testing.expectEqual(@as(u16, 3), span.pixelX());
    try std.testing.expectEqual(@as(u16, 4), span.pixelWidth());
    try std.testing.expectEqual(@as(u16, 7), span.pixelEnd());
    try std.testing.expectEqual(@as(u16, 0), span.tileX());
    try std.testing.expectEqual(@as(u16, 2), span.tileEnd());

    const tile_span = Span.newTile(2, 3);
    try std.testing.expectEqual(Span.new(8, 12), tile_span);
    try std.testing.expectEqual(@as(u16, 2), tile_span.tileX());
    try std.testing.expectEqual(@as(u16, 5), tile_span.tileEnd());

    // `pixel_end` saturates instead of overflowing.
    try std.testing.expectEqual(std.math.maxInt(u16), Span.new(1, std.math.maxInt(u16)).pixelEnd());
}

test "span_extend_and_intersect" {
    var span = Span.new(4, 8);
    span.extend(Span.new(8, 8));
    try std.testing.expectEqual(Span.new(4, 12), span);

    span.extend(Span.new(0, 2));
    try std.testing.expectEqual(Span.new(0, 16), span);

    try std.testing.expectEqual(@as(?Span, Span.new(4, 4)), Span.new(0, 8).intersect(Span.new(4, 4)));
    try std.testing.expectEqual(@as(?Span, null), Span.new(0, 4).intersect(Span.new(4, 4)));
    try std.testing.expectEqual(@as(?Span, Span.new(2, 2)), Span.new(0, 4).intersect(Span.new(2, 2)));
}
