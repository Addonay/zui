//! Port of vello_cpu src/fine/lowp/image.rs (Apache-2.0 OR MIT).
//!
//! u8-native bilinear image painters for the low-precision pipeline. A paint
//! iteration emits one pixel column: four pixels (one per tile row) as 16 u8
//! values in the layout `4 * (4 * dx + y) + c`. Only complete 16-byte groups
//! are written, exactly like upstream's `chunks_exact_mut(16)`; a trailing
//! partial group is left untouched.
//!
//! Upstream's `U8Kernel` only overrides the two `Medium`-quality painters;
//! `Low` (nearest) and `High` (bicubic) stay on the f32 painters and are
//! converted by `paintU8` there. `fine/mod.zig` selects these painters under
//! the same condition.
//!
//! Numerical conventions:
//! - Positions and interpolation weights are computed in f32 exactly like the
//!   high-precision painter (strict IEEE, unfused `mul_add`); only the texel
//!   samples and interpolation products move to u8/u16.
//! - `f32_to_u8` reproduces the baseline/x86 saturating low-byte conversion
//!   from `common/util.zig`.
//! - The f32x4 position advances reuse [`image.ImagePainterData`] and the
//!   shared [`image.extend`]/[`image.fractFloor`] helpers.
//!
//! Divergences from upstream (behavior-preserving):
//! - Upstream is generic over `Simd` and uses `u8x16_painter!`; this port
//!   exposes `paint(dest: []u8)` directly.
//! - The u8x64 batch split in `alpha_composite_solid` (kernel ops) lives in
//!   `lowp/mod.zig`; nothing here needs 64-byte vectors.

const std = @import("std");
const simd = @import("../../../simd/root.zig");
const encode = @import("../../../common/encode.zig");
const pixmap_mod = @import("../../../common/pixmap.zig");
const image_mod = @import("../image.zig");

const F32x4 = simd.F32x4;
const U8x16 = simd.U8x16;
const U16x16 = simd.U16x16;
const U32x4 = simd.U32x4;

const Pixmap = pixmap_mod.Pixmap;
const ImagePainterData = image_mod.ImagePainterData;

/// `Tile::HEIGHT` as the row mask used by `splat_pos`.
const COLUMN_MASK: F32x4 = .{ 0.0, 1.0, 2.0, 3.0 };

/// Upstream `PosExt::splat_pos` for `f32x4`: lane `r` is
/// `pos + f32(r) * y_advance`.
inline fn splatPos(pos: f32, y_advance: f32) F32x4 {
    return simd.mulAddUnfused(
        COLUMN_MASK,
        @as(F32x4, @splat(y_advance)),
        @as(F32x4, @splat(pos)),
    );
}

/// `(v + 255) >> 8` for 16-lane u16 vectors (upstream `Div255Ext`).
inline fn div25516(v: U16x16) U16x16 {
    const Shift = @Vector(16, std.math.Log2Int(u16));
    return (v +% @as(U16x16, @splat(255))) >> @as(Shift, @splat(8));
}

/// Upstream `f32_to_u8` for one `f32x4` splatted to `f32x16`.
fn f32ToU8Wide(val: F32x4) U8x16 {
    return @import("../../../common/util.zig").f32ToU8(simd.elementWiseSplat(val));
}

/// Rust `f32 as u32` lane-wise (shared with the f32 image painter).
inline fn f32ToU32Vec(val: F32x4) U32x4 {
    return image_mod.f32ToU32Vec(val);
}

/// Assemble 16 texel bytes (four RGBA words, one per tile row) into a
/// `u8x16`. On little-endian targets this is a single bitcast of the word
/// vector; other targets keep the exact per-byte order via the scalar loop.
inline fn wordsToBytes(words: U32x4) U8x16 {
    if (comptime @import("builtin").cpu.arch.endian() == .little) {
        return @bitCast(words);
    }
    var out: U8x16 = undefined;
    inline for (0..4) |lane| {
        const bytes: [4]u8 = @bitCast(words[lane]);
        inline for (0..4) |component| out[lane * 4 + component] = bytes[component];
    }
    return out;
}

/// Upstream `sample`: four raw RGBA8 texels, one per tile row, in row-major
/// index order.
pub fn sampleU8(data: *const ImagePainterData, x_positions: F32x4, y_positions: F32x4) U8x16 {
    const idx = f32ToU32Vec(x_positions) +% (f32ToU32Vec(y_positions) *% data.width_u32);

    var words: U32x4 = undefined;
    inline for (0..4) |lane| {
        words[lane] = data.pixmap.sampleIdx(idx[lane]).toU32();
    }
    return wordsToBytes(words);
}

/// A bilinear image painter for the u8 pipeline (upstream
/// `BilinearImagePainter`).
pub const BilinearImagePainter = struct {
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

    /// Paint one pixel column per complete 16-byte group.
    pub fn paintU8(self: *Self, dest: []u8) void {
        var offset: usize = 0;
        while (offset + 16 <= dest.len) : (offset += 16) {
            simd.storeSlice(self.nextColumn(), dest[offset..][0..16]);
        }
    }

    /// Upstream `Iterator::next`: bilinear interpolation with u16 arithmetic.
    fn nextColumn(self: *Self) U8x16 {
        const x_positions = splatPos(
            @floatCast(self.data.cur_pos.x),
            self.data.y_advances[0],
        );
        const y_positions = splatPos(
            @floatCast(self.data.cur_pos.y),
            self.data.y_advances[1],
        );

        const x_extend = self.data.image.sampler.x_extend;
        const y_extend = self.data.image.sampler.y_extend;

        const fx = f32ToU8Wide(
            simd.mulAddUnfused(
                image_mod.fractFloor(x_positions + @as(F32x4, @splat(0.5))),
                @as(F32x4, @splat(255.0)),
                @as(F32x4, @splat(0.5)),
            ),
        );
        const fy = f32ToU8Wide(
            simd.mulAddUnfused(
                image_mod.fractFloor(y_positions + @as(F32x4, @splat(0.5))),
                @as(F32x4, @splat(255.0)),
                @as(F32x4, @splat(0.5)),
            ),
        );

        const fx_wide: U16x16 = @intCast(fx);
        const fy_wide: U16x16 = @intCast(fy);
        const fx_inv = @as(U16x16, @splat(255)) -% fx_wide;
        const fy_inv = @as(U16x16, @splat(255)) -% fy_wide;

        const half: F32x4 = @splat(0.5);
        const x_pos1 = image_mod.extend(
            x_positions - half,
            x_extend,
            self.data.width,
            self.data.width_inv,
        );
        const x_pos2 = image_mod.extend(
            x_positions + half,
            x_extend,
            self.data.width,
            self.data.width_inv,
        );
        const y_pos1 = image_mod.extend(
            y_positions - half,
            y_extend,
            self.data.height,
            self.data.height_inv,
        );
        const y_pos2 = image_mod.extend(
            y_positions + half,
            y_extend,
            self.data.height,
            self.data.height_inv,
        );

        const p00: U16x16 = @intCast(sampleU8(&self.data, x_pos1, y_pos1));
        const p10: U16x16 = @intCast(sampleU8(&self.data, x_pos2, y_pos1));
        const p01: U16x16 = @intCast(sampleU8(&self.data, x_pos1, y_pos2));
        const p11: U16x16 = @intCast(sampleU8(&self.data, x_pos2, y_pos2));

        const ip1 = div25516((p00 *% fx_inv) +% (p10 *% fx_wide));
        const ip2 = div25516((p01 *% fx_inv) +% (p11 *% fx_wide));
        const res = @as(U8x16, @truncate(div25516((ip1 *% fy_inv) +% (ip2 *% fy_wide))));

        self.data.cur_pos = self.data.cur_pos.addVec(self.data.image.x_advance);
        return res;
    }
};

/// A bilinear image painter for axis-aligned images (no skew) in the u8
/// pipeline (upstream `PlainBilinearImagePainter`).
///
/// Pre-computes the y sample positions and interpolation weights once.
pub const PlainBilinearImagePainter = struct {
    data: ImagePainterData,
    /// Pre-computed y sample positions (top row for the bilinear grid).
    y_pos1: F32x4,
    /// Pre-computed y sample positions (bottom row for the bilinear grid).
    y_pos2: F32x4,
    /// Pre-computed y interpolation weight.
    fy: U16x16,
    /// Pre-computed inverse y interpolation weight.
    fy_inv: U16x16,
    /// Current x position.
    cur_x_pos: F32x4,
    /// X advance per iteration.
    advance: f32,

    const Self = @This();

    pub fn init(
        image: *const encode.EncodedImage,
        pixmap: *const Pixmap,
        start_x: f64,
        start_y: f64,
    ) Self {
        const data = ImagePainterData.init(image, pixmap, start_x, start_y);

        // For axis-aligned images, y doesn't change across the strip.
        const y_positions = splatPos(
            @floatCast(data.cur_pos.y),
            data.y_advances[1],
        );

        // Pre-compute y extend positions.
        const half: F32x4 = @splat(0.5);
        const y_pos1 = image_mod.extend(
            y_positions - half,
            image.sampler.y_extend,
            data.height,
            data.height_inv,
        );
        const y_pos2 = image_mod.extend(
            y_positions + half,
            image.sampler.y_extend,
            data.height,
            data.height_inv,
        );

        // Pre-compute y interpolation weights.
        const fy_u8 = f32ToU8Wide(
            simd.mulAddUnfused(
                image_mod.fractFloor(y_positions + half),
                @as(F32x4, @splat(255.0)),
                @as(F32x4, @splat(0.5)),
            ),
        );
        const fy: U16x16 = @intCast(fy_u8);
        const fy_inv = @as(U16x16, @splat(255)) -% fy;

        const cur_x_pos = splatPos(
            @floatCast(data.cur_pos.x),
            data.y_advances[0],
        );

        return .{
            .data = data,
            .y_pos1 = y_pos1,
            .y_pos2 = y_pos2,
            .fy = fy,
            .fy_inv = fy_inv,
            .cur_x_pos = cur_x_pos,
            .advance = data.x_advances[0],
        };
    }

    /// Paint one pixel column per complete 16-byte group.
    pub fn paintU8(self: *Self, dest: []u8) void {
        var offset: usize = 0;
        while (offset + 16 <= dest.len) : (offset += 16) {
            simd.storeSlice(self.nextColumn(), dest[offset..][0..16]);
        }
    }

    /// Upstream `Iterator::next`.
    fn nextColumn(self: *Self) U8x16 {
        const half: F32x4 = @splat(0.5);
        const x_minus_half = self.cur_x_pos - half;
        const x_plus_half = self.cur_x_pos + half;

        // Only x needs to be extended per-iteration.
        const x_pos1 = image_mod.extend(
            x_minus_half,
            self.data.image.sampler.x_extend,
            self.data.width,
            self.data.width_inv,
        );
        const x_pos2 = image_mod.extend(
            x_plus_half,
            self.data.image.sampler.x_extend,
            self.data.width,
            self.data.width_inv,
        );

        // Compute x interpolation weights.
        const fx_u8 = f32ToU8Wide(
            simd.mulAddUnfused(
                image_mod.fractFloor(x_plus_half),
                @as(F32x4, @splat(255.0)),
                @as(F32x4, @splat(0.5)),
            ),
        );
        const fx: U16x16 = @intCast(fx_u8);
        const fx_inv = @as(U16x16, @splat(255)) -% fx;

        // Sample the 4 corners using pre-computed y positions.
        const p00: U16x16 = @intCast(sampleU8(&self.data, x_pos1, self.y_pos1));
        const p10: U16x16 = @intCast(sampleU8(&self.data, x_pos2, self.y_pos1));
        const p01: U16x16 = @intCast(sampleU8(&self.data, x_pos1, self.y_pos2));
        const p11: U16x16 = @intCast(sampleU8(&self.data, x_pos2, self.y_pos2));

        // Bilinear interpolation.
        const ip1 = div25516((p00 *% fx_inv) +% (p10 *% fx));
        const ip2 = div25516((p01 *% fx_inv) +% (p11 *% fx));
        const res = @as(U8x16, @truncate(div25516((ip1 *% self.fy_inv) +% (ip2 *% self.fy))));

        self.cur_x_pos += @as(F32x4, @splat(self.advance));
        return res;
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;
const paint_mod = @import("../../../common/paint.zig");
const kurbo = @import("../../../kurbo/root.zig");
const peniko = @import("../../../peniko/root.zig");

/// A minimal encoded image; the painters only read its sampler, transform and
/// advances. `opaque_id` sources own nothing, so there is no cleanup.
fn testImage(
    sampler: peniko.ImageSampler,
    x_advance: kurbo.Vec2,
    y_advance: kurbo.Vec2,
) encode.EncodedImage {
    return .{
        .source = paint_mod.ImageSource.initOpaqueId(paint_mod.ImageId.new(0)),
        .sampler = sampler,
        .may_have_transparency = false,
        .transform = kurbo.Affine.IDENTITY,
        .x_advance = x_advance,
        .y_advance = y_advance,
        .tint = null,
    };
}

test "plain bilinear u8 interpolates two texels" {
    const allocator = testing.allocator;
    var pixmap = try Pixmap.init(allocator, 2, 2);
    defer pixmap.deinit(allocator);
    pixmap.setPixel(0, 0, .{ .r = 10, .g = 20, .b = 30, .a = 40 });
    pixmap.setPixel(1, 0, .{ .r = 50, .g = 60, .b = 70, .a = 80 });
    pixmap.setPixel(0, 1, .{ .r = 90, .g = 100, .b = 110, .a = 120 });
    pixmap.setPixel(1, 1, .{ .r = 130, .g = 140, .b = 150, .a = 160 });

    const image = testImage(
        peniko.ImageSampler.new().withQuality(.medium),
        kurbo.Vec2.new(1.0, 0.0),
        kurbo.Vec2.new(0.0, 1.0),
    );
    // x = 1.0 has fraction 0.5, so the taps land on texel columns 0 and 1;
    // each lane's y fraction is 0, so it samples its own (clamped) row.
    var painter = PlainBilinearImagePainter.init(&image, &pixmap, 1.0, 0.5);

    var dest: [16]u8 = @splat(0);
    painter.paintU8(&dest);

    // (10 + 50) / 2 = 30 with the div_255 approximation, and so on.
    try testing.expectEqualSlices(u8, &[_]u8{ 30, 40, 50, 60 }, dest[0..4]);
    for (1..4) |row| {
        try testing.expectEqualSlices(u8, &[_]u8{ 110, 120, 130, 140 }, dest[4 * row ..][0..4]);
    }
}

test "bilinear u8 painter leaves a partial group untouched" {
    const allocator = testing.allocator;
    var pixmap = try Pixmap.init(allocator, 1, 1);
    defer pixmap.deinit(allocator);
    pixmap.setPixel(0, 0, .{ .r = 1, .g = 2, .b = 3, .a = 4 });

    const image = testImage(
        peniko.ImageSampler.new().withQuality(.medium),
        kurbo.Vec2.new(1.0, 0.0),
        kurbo.Vec2.new(0.0, 1.0),
    );
    var painter = BilinearImagePainter.init(&image, &pixmap, 0.5, 0.5);

    var dest: [20]u8 = @splat(9);
    painter.paintU8(&dest);

    for (dest[16..]) |value| {
        try testing.expectEqual(@as(u8, 9), value);
    }
}
