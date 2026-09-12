//! Port of vello_cpu src/fine/lowp/gradient.rs (Apache-2.0 OR MIT).
//!
//! Accelerated u8 gradient painter: samples the gradient's u8 lookup table
//! directly, one `u8x64` (16 pixels) per iteration, exactly like upstream.
//! Assumes that the gradient has no undefined positions (the radial
//! `has_undefined` case stays on the f32 painter in `fine/mod.zig`, matching
//! the `U8Kernel` dispatch upstream).
//!
//! Divergences from upstream (behavior-preserving):
//! - Upstream is generic over a `Simd` backend and iterates `ChunksExact`;
//!   this port carries the t-value slice plus a cursor, like the f32
//!   `GradientPainter` in `../gradient.zig`.
//! - The `to_int::<u32x16>` conversion is the scalar Rust saturating cast
//!   helper shared with the f32 painter.
//! - Rust's `.fract()` after the repeat-mode floor subtraction is elided: for
//!   any finite value `val - floor(val)` already lies in `[0, 1)`.

const std = @import("std");
const simd = @import("../../../simd/root.zig");
const encode = @import("../../../common/encode.zig");
const peniko = @import("../../../peniko/root.zig");
const gradient_mod = @import("../gradient.zig");

const F32x16 = simd.F32x16;
const U32x16 = simd.U32x16;
const U8x64 = simd.U8x64;
const Extend = peniko.Extend;

/// Fine-rasterization painter that samples a gradient's u8 lookup table.
///
/// The painter borrows the encoded gradient and the t-value slice; neither is
/// owned.
pub const GradientPainter = struct {
    /// The encoded gradient: source of `extend` and owner of the u8 LUT.
    gradient: *encode.EncodedGradient,
    /// The u8 lookup table (`gradient.u8Lut(allocator)`).
    lut: *const encode.GradientLut(u8),
    /// One f32 per pixel, index `4 * dx + y`.
    t_vals: []const f32,
    /// Cursor into `t_vals`, in values (advanced 16 at a time).
    t_idx: usize = 0,
    /// `lut.scaleFactor()`, applied to the extended parameter before the
    /// lookup-index conversion.
    scale_factor: f32,

    /// Create a painter, building the gradient's u8 LUT on first use.
    ///
    /// The caller keeps ownership of `gradient` and `t_vals`; both must
    /// outlive the painter and `paint` calls.
    pub fn init(
        gradient: *encode.EncodedGradient,
        allocator: std.mem.Allocator,
        t_vals: []const f32,
    ) std.mem.Allocator.Error!GradientPainter {
        const lut = try gradient.u8Lut(allocator);

        return .{
            .gradient = gradient,
            .lut = lut,
            .t_vals = t_vals,
            .scale_factor = lut.scaleFactor(),
        };
    }

    /// Paint complete 64-byte (16-pixel) groups into `dest`; a trailing partial
    /// group is left untouched, exactly like upstream `chunks_exact_mut(64)`.
    pub fn paintU8(self: *GradientPainter, dest: []u8) void {
        var i: usize = 0;
        while (i + 64 <= dest.len) : (i += 64) {
            dest[i..][0..64].* = self.next();
        }
    }

    /// Compute the next 16 pixels (64 bytes).
    ///
    /// Mirrors upstream `Iterator for GradientPainter::next`: extend, scale,
    /// Rust `as u32` conversion, then 16 u8 LUT lookups.
    fn next(self: *GradientPainter) [64]u8 {
        // Upstream calls `next().unwrap()` here; a missing complete chunk is a
        // caller contract violation (the destination has more 16-pixel groups
        // than the t-value buffer), so fail loudly instead of reading garbage.
        if (self.t_idx + 16 > self.t_vals.len) {
            @panic("lowp gradient painter: t_vals exhausted");
        }
        const pos = simd.fromSlice(F32x16, self.t_vals[self.t_idx..][0..16]);
        self.t_idx += 16;

        const extended = applyExtend(pos, self.gradient.extend);
        const scaled = extended * @as(F32x16, @splat(self.scale_factor));
        const indices = @import("../image.zig").f32ToU32VecN(scaled);

        var out: [64]u8 = undefined;
        inline for (0..16) |pixel| {
            const idx = indices[pixel];
            // Upstream indexes `self.lut.lut()[idx as usize]` directly; an
            // out-of-range index is a slice panic there, reproduced here.
            if (idx >= self.lut.width()) {
                @panic("lowp gradient painter: LUT index out of range");
            }
            out[4 * pixel ..][0..4].* = self.lut.get(idx);
        }
        return out;
    }
};

/// Upstream `apply_extend` for the low-precision painter.
///
/// `Repeat` uses `(val - floor(val))`; see the module note about `.fract()`.
fn applyExtend(val: F32x16, extend: Extend) F32x16 {
    const zero: F32x16 = @splat(0.0);
    const one: F32x16 = @splat(1.0);

    return switch (extend) {
        .pad => simd.min(simd.max(val, zero), one),
        .repeat => val - @floor(val),
        // See <https://github.com/google/skia/blob/220738774f7a0ce4a6c7bd17519a336e5e5dea5b/src/opts/SkRasterPipeline_opts.h#L6472-L6475>
        .reflect => blk: {
            const shifted = val - one;
            const reflected = @abs(
                shifted - @as(F32x16, @splat(2.0)) *
                    @floor(shifted * @as(F32x16, @splat(0.5))) - one,
            );
            break :blk simd.min(simd.max(reflected, zero), one);
        },
    };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

/// Encode `kind` with `stops` and no paint transform, appending to `paints`.
fn encodeTestGradient(
    allocator: std.mem.Allocator,
    paints: *std.ArrayList(encode.EncodedPaint),
    kind: peniko.GradientKind,
    stops: []const peniko.ColorStop,
    extend: peniko.Extend,
) !*encode.EncodedGradient {
    var gradient = try (peniko.Gradient{ .kind = kind, .extend = extend }).withStops(allocator, stops);
    defer gradient.deinit();

    const paint = try encode.encodeGradient(
        &gradient,
        allocator,
        paints,
        @import("../../../kurbo/root.zig").Affine.IDENTITY,
        null,
    );
    return &paints.items[paint.indexed.index()].gradient;
}

/// Release every encoded paint and the list itself.
fn releasePaints(allocator: std.mem.Allocator, paints: *std.ArrayList(encode.EncodedPaint)) void {
    for (paints.items) |*paint| paint.deinit(allocator);
    paints.deinit(allocator);
}

test "painter samples the u8 lut at both endpoints" {
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
        .{ .linear = peniko.LinearGradientPosition.new(
            @import("../../../kurbo/root.zig").Point.new(0.0, 0.0),
            @import("../../../kurbo/root.zig").Point.new(1.0, 0.0),
        ) },
        &stops,
        .pad,
    );
    const lut = try gradient.u8Lut(allocator);
    const last_idx = lut.width() - 1;

    // 16 t values: the first eight pixels are t = 0, the next eight t = 1.
    var t_vals: [16]f32 = undefined;
    for (0..8) |i| t_vals[i] = 0.0;
    for (8..16) |i| t_vals[i] = 1.0;

    var painter = try GradientPainter.init(gradient, allocator, &t_vals);
    var dest: [64]u8 = @splat(42);
    painter.paintU8(&dest);

    const first = lut.get(0);
    const last = lut.get(last_idx);
    for (0..8) |pixel| {
        try testing.expectEqualSlices(u8, &first, dest[4 * pixel ..][0..4]);
    }
    for (8..16) |pixel| {
        try testing.expectEqualSlices(u8, &last, dest[4 * pixel ..][0..4]);
    }
}

test "painter leaves a trailing partial group untouched" {
    const allocator = testing.allocator;
    var paints: std.ArrayList(encode.EncodedPaint) = .empty;
    defer releasePaints(allocator, &paints);

    const stops = [_]peniko.ColorStop{
        peniko.ColorStop.init(0.0, peniko.palette.css.RED),
        peniko.ColorStop.init(1.0, peniko.palette.css.RED),
    };
    const gradient = try encodeTestGradient(
        allocator,
        &paints,
        .{ .linear = peniko.LinearGradientPosition.new(
            @import("../../../kurbo/root.zig").Point.new(0.0, 0.0),
            @import("../../../kurbo/root.zig").Point.new(1.0, 0.0),
        ) },
        &stops,
        .pad,
    );

    var t_vals: [16]f32 = @splat(0.0);
    var painter = try GradientPainter.init(gradient, allocator, &t_vals);
    var dest: [68]u8 = @splat(7);
    painter.paintU8(&dest);

    for (dest[64..]) |value| {
        try testing.expectEqual(@as(u8, 7), value);
    }
}

test "apply_extend matches upstream pad/repeat/reflect" {
    const input: F32x16 = .{
        -1.5, -0.25, 0.0, 0.25, 0.75, 1.0, 1.25, 2.5,
        -1.5, -0.25, 0.0, 0.25, 0.75, 1.0, 1.25, 2.5,
    };

    const padded = applyExtend(input, .pad);
    try testing.expectEqual(
        F32x16{
            0.0, 0.0, 0.0, 0.25, 0.75, 1.0, 1.0, 1.0,
            0.0, 0.0, 0.0, 0.25, 0.75, 1.0, 1.0, 1.0,
        },
        padded,
    );

    const repeated = applyExtend(input, .repeat);
    try testing.expectEqual(
        F32x16{
            0.5, 0.75, 0.0, 0.25, 0.75, 0.0, 0.25, 0.5,
            0.5, 0.75, 0.0, 0.25, 0.75, 0.0, 0.25, 0.5,
        },
        repeated,
    );

    const reflected = applyExtend(input, .reflect);
    try testing.expectEqual(
        F32x16{
            0.5, 0.25, 0.0, 0.25, 0.75, 1.0, 0.75, 0.5,
            0.5, 0.25, 0.0, 0.25, 0.75, 1.0, 0.75, 0.5,
        },
        reflected,
    );
}
