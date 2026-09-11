//! Port of peniko 0.6.1 (color usage) / color 0.3.3 color.rs, colorspace.rs,
//! tag.rs (Apache-2.0 OR MIT).
//!
//! Only the sRGB subset needed by peniko 0.6.1 and Vello is ported: [`Srgb`],
//! [`OpaqueColor`], [`AlphaColor`], and [`PremulColor`]. The remaining color
//! spaces, dynamic colors, parsing, and serialization are out of scope for
//! this port.
//!
//! Numerical fidelity:
//! - Premultiplication, un-premultiplication, `with_alpha`, `multiply_alpha`,
//!   and the packed RGBA8 conversions follow upstream bit-for-bit (including
//!   the "add 0.5 then saturating cast" rounding of `fast_round_to_u8`).
//! - `Srgb::toLinearSrgb`/`fromLinearSrgb` use the exact upstream formulas and
//!   constants. Zig's `std.math.pow` is a pure-Zig implementation rather than
//!   the platform libm `powf`, so results may differ from Rust by one or two
//!   ULPs. sRGB-to-sRGB conversions never take this path, so pixel parity for
//!   the sRGB renderer is unaffected.

const std = @import("std");
const rgba8 = @import("rgba8.zig");

/// Predefined color palettes (upstream `color::palette`).
pub const palette = @import("palette.zig");

pub const Rgba8 = rgba8.Rgba8;
pub const PremulRgba8 = rgba8.PremulRgba8;

/// The color space tag for dynamic colors.
///
/// Upstream `color::ColorSpaceTag`. Only sRGB has a concrete color space
/// implementation in this port; the remaining tags are kept so that
/// `Gradient.interpolation_cs` round-trips upstream values unchanged.
pub const ColorSpaceTag = enum(u8) {
    srgb = 0,
    linear_srgb = 1,
    lab = 2,
    lch = 3,
    hsl = 4,
    hwb = 5,
    oklab = 6,
    oklch = 7,
    display_p3 = 8,
    a98_rgb = 9,
    prophoto_rgb = 10,
    rec2020 = 11,
    aces_cg = 12,
    xyz_d50 = 13,
    xyz_d65 = 14,
    aces2065_1 = 15,

    pub const default: ColorSpaceTag = .srgb;

    /// Return the discriminant as a `u8`.
    pub fn toU8(self: ColorSpaceTag) u8 {
        return @backingInt(self);
    }

    /// Convert a discriminant back into a tag, or `null` if it is unknown.
    pub fn fromU8(value: u8) ?ColorSpaceTag {
        return switch (value) {
            0 => .srgb,
            1 => .linear_srgb,
            2 => .lab,
            3 => .lch,
            4 => .hsl,
            5 => .hwb,
            6 => .oklab,
            7 => .oklch,
            8 => .display_p3,
            9 => .a98_rgb,
            10 => .prophoto_rgb,
            11 => .rec2020,
            12 => .aces_cg,
            13 => .xyz_d50,
            14 => .xyz_d65,
            15 => .aces2065_1,
            else => null,
        };
    }

    /// The layout of the color space, identifying its hue channel (if any).
    pub fn layout(self: ColorSpaceTag) ColorSpaceLayout {
        return switch (self) {
            .lch, .oklch => .hue_third,
            .hsl, .hwb => .hue_first,
            else => .rectangular,
        };
    }
};

/// The hue direction for interpolation (CSS Color 4 `hue-interpolation-method`).
pub const HueDirection = enum(u8) {
    /// Hue angles take the shorter of the two arcs.
    shorter = 0,
    /// Hue angles take the longer of the two arcs.
    longer = 1,
    /// Hue angles increase as they are interpolated.
    increasing = 2,
    /// Hue angles decrease as they are interpolated.
    decreasing = 3,

    pub const default: HueDirection = .shorter;

    /// Return the discriminant as a `u8`.
    pub fn toU8(self: HueDirection) u8 {
        return @backingInt(self);
    }

    /// Convert a discriminant back, or `null` if it is unknown.
    pub fn fromU8(value: u8) ?HueDirection {
        if (value > 3) return null;
        return @fromBackingInt(@intCast(value));
    }
};

/// The layout of a color space, particularly which component is hue.
pub const ColorSpaceLayout = enum {
    /// No hue component.
    rectangular,
    /// Hue is the first component.
    hue_first,
    /// Hue is the third component.
    hue_third,

    /// Multiply all components except for hue by `scale`.
    ///
    /// Used for both premultiplying and un-premultiplying (CSS Color 4 §12.3).
    pub fn scale(self: ColorSpaceLayout, components: [3]f32, factor: f32) [3]f32 {
        return switch (self) {
            .rectangular => .{
                components[0] * factor,
                components[1] * factor,
                components[2] * factor,
            },
            .hue_first => .{
                components[0],
                components[1] * factor,
                components[2] * factor,
            },
            .hue_third => .{
                components[0] * factor,
                components[1] * factor,
                components[2],
            },
        };
    }

    /// The index of the hue channel, or `null` if the layout is rectangular.
    pub fn hueChannel(self: ColorSpaceLayout) ?usize {
        return switch (self) {
            .rectangular => null,
            .hue_first => 0,
            .hue_third => 2,
        };
    }
};

/// The standard RGB color space (IEC 61966-2-1).
///
/// The duck-typed equivalent of `color::ColorSpace` for this port: a zero-sized
/// type exposing `IS_LINEAR`, `LAYOUT`, `TAG`, `WHITE_COMPONENTS`,
/// `toLinearSrgb`, and `fromLinearSrgb`.
pub const Srgb = struct {
    pub const IS_LINEAR: bool = false;
    pub const LAYOUT: ColorSpaceLayout = .rectangular;
    pub const TAG: ?ColorSpaceTag = .srgb;
    pub const WHITE_COMPONENTS: [3]f32 = .{ 1.0, 1.0, 1.0 };

    /// Convert an sRGB-encoded component to linear light.
    ///
    /// Mirrors upstream `Srgb::to_linear_srgb`, including the sign-preserving
    /// transfer function for negative components.
    pub fn toLinearSrgb(src: [3]f32) [3]f32 {
        return .{ srgbToLinear(src[0]), srgbToLinear(src[1]), srgbToLinear(src[2]) };
    }

    /// Convert a linear-light component to sRGB encoding.
    ///
    /// Mirrors upstream `Srgb::from_linear_srgb`.
    pub fn fromLinearSrgb(src: [3]f32) [3]f32 {
        return .{ linearToSrgb(src[0]), linearToSrgb(src[1]), linearToSrgb(src[2]) };
    }

    /// Convert components between color spaces.
    ///
    /// The sRGB specialization of upstream `ColorSpace::convert`; the Hsl/Hwb
    /// special cases are not ported because those spaces are not.
    pub fn convert(comptime TargetCS: type, src: [3]f32) [3]f32 {
        if (TargetCS == Srgb) return src;
        return TargetCS.fromLinearSrgb(toLinearSrgb(src));
    }

    /// Clamp the components to the natural gamut of the color space.
    pub fn clip(src: [3]f32) [3]f32 {
        return .{
            std.math.clamp(src[0], 0.0, 1.0),
            std.math.clamp(src[1], 0.0, 1.0),
            std.math.clamp(src[2], 0.0, 1.0),
        };
    }
};

/// `1.0f32 / 1.055f32` evaluated with the f32-rounded divisor, matching Rust's
/// `1.0f32 / 1.055f32` bit-for-bit (a comptime `1.0 / 1.055` differs by one
/// ULP because the divisor keeps extra precision).
const INV_1_055: f32 = @as(f32, 1.0) / @as(f32, 1.055);

fn srgbToLinear(x: f32) f32 {
    if (@abs(x) <= 0.04045) {
        return x * (1.0 / 12.92);
    }
    return std.math.copysign(std.math.pow(f32, (@abs(x) + 0.055) * INV_1_055, 2.4), x);
}

fn linearToSrgb(x: f32) f32 {
    if (@abs(x) <= 0.0031308) {
        return x * 12.92;
    }
    return std.math.copysign(1.055 * std.math.pow(f32, @abs(x), 1.0 / 2.4) - 0.055, x);
}

fn addAlpha(rgb: [3]f32, alpha: f32) [4]f32 {
    return .{ rgb[0], rgb[1], rgb[2], alpha };
}

/// Fast rounding of `f32` to `u8`, rounding ties up, with the saturating cast
/// semantics of Rust's `as u8` (NaN maps to 0).
///
/// Mirrors upstream `fast_round_to_u8`: on the range 0-255 it agrees with
/// rounding except for exactly `0.49999997`, where the tie in
/// `0.49999997 + 0.5` rounds up to `1.0`.
inline fn fastRoundToU8(a: f32) u8 {
    const v = a + 0.5;
    if (std.math.isNan(v)) return 0;
    if (v <= 0.0) return 0;
    if (v >= 255.0) return 255;
    return @intFromFloat(v);
}

/// An opaque color in a color space known at compile time.
pub fn OpaqueColor(comptime CS: type) type {
    return struct {
        /// The components, whose interpretation depends on the color space.
        components: [3]f32,
        /// The color space (zero-sized for [`Srgb`]).
        cs: CS = .{},

        const Self = @This();

        /// A black color.
        pub const BLACK: Self = .{ .components = .{ 0.0, 0.0, 0.0 } };
        /// The color space's white.
        pub const WHITE: Self = .{ .components = CS.WHITE_COMPONENTS };

        /// Create a color from the given components.
        pub fn new(components: [3]f32) Self {
            return .{ .components = components };
        }

        /// Convert a color into a different color space.
        pub fn convert(self: Self, comptime TargetCS: type) OpaqueColor(TargetCS) {
            return OpaqueColor(TargetCS).new(CS.convert(TargetCS, self.components));
        }

        /// Add an alpha channel.
        pub fn withAlpha(self: Self, alpha: f32) AlphaColor(CS) {
            return AlphaColor(CS).new(addAlpha(self.components, alpha));
        }

        /// Pack the color into 8-bit sRGB.
        pub fn toRgba8(self: Self) Rgba8 {
            const c = self.convert(Srgb).components;
            return .{
                .r = fastRoundToU8(c[0] * 255.0),
                .g = fastRoundToU8(c[1] * 255.0),
                .b = fastRoundToU8(c[2] * 255.0),
                .a = 255,
            };
        }
    };
}

/// A color with an alpha channel, in a color space known at compile time.
///
/// Color channels are straight (not premultiplied). See [`PremulColor`] for
/// the premultiplied form.
pub fn AlphaColor(comptime CS: type) type {
    return struct {
        /// The first three components are the color channels; the fourth is
        /// alpha.
        components: [4]f32,
        /// The color space (zero-sized for [`Srgb`]).
        cs: CS = .{},

        const Self = @This();

        /// A black color.
        pub const BLACK: Self = .{ .components = .{ 0.0, 0.0, 0.0, 1.0 } };
        /// A fully transparent color.
        pub const TRANSPARENT: Self = .{ .components = .{ 0.0, 0.0, 0.0, 0.0 } };
        /// The color space's white.
        pub const WHITE: Self = .{ .components = addAlpha(CS.WHITE_COMPONENTS, 1.0) };

        /// Create a color from the given components.
        pub fn new(components: [4]f32) Self {
            return .{ .components = components };
        }

        /// Split into the opaque color and the alpha component.
        pub fn split(self: Self) struct { color: OpaqueColor(CS), alpha: f32 } {
            return .{
                .color = OpaqueColor(CS).new(.{
                    self.components[0],
                    self.components[1],
                    self.components[2],
                }),
                .alpha = self.components[3],
            };
        }

        /// Set the alpha channel, replacing the existing alpha.
        pub fn withAlpha(self: Self, alpha: f32) Self {
            return .{
                .components = .{
                    self.components[0],
                    self.components[1],
                    self.components[2],
                    alpha,
                },
            };
        }

        /// Split out the opaque components, discarding alpha.
        pub fn discardAlpha(self: Self) OpaqueColor(CS) {
            return self.split().color;
        }

        /// Convert a color into a different color space.
        pub fn convert(self: Self, comptime TargetCS: type) AlphaColor(TargetCS) {
            const converted = CS.convert(TargetCS, .{
                self.components[0],
                self.components[1],
                self.components[2],
            });
            return AlphaColor(TargetCS).new(addAlpha(converted, self.components[3]));
        }

        /// Convert to the corresponding premultiplied form.
        pub fn premultiply(self: Self) PremulColor(CS) {
            const scaled = CS.LAYOUT.scale(.{
                self.components[0],
                self.components[1],
                self.components[2],
            }, self.components[3]);
            return PremulColor(CS).new(addAlpha(scaled, self.components[3]));
        }

        /// Multiply alpha by the given factor.
        pub fn multiplyAlpha(self: Self, rhs: f32) Self {
            return .{
                .components = .{
                    self.components[0],
                    self.components[1],
                    self.components[2],
                    self.components[3] * rhs,
                },
            };
        }

        /// Pack the color into straight 8-bit sRGB.
        pub fn toRgba8(self: Self) Rgba8 {
            const c = self.convert(Srgb).components;
            return .{
                .r = fastRoundToU8(c[0] * 255.0),
                .g = fastRoundToU8(c[1] * 255.0),
                .b = fastRoundToU8(c[2] * 255.0),
                .a = fastRoundToU8(c[3] * 255.0),
            };
        }

        /// Create a color from 8-bit RGBA values.
        ///
        /// Only defined for sRGB (upstream `AlphaColor::<Srgb>::from_rgba8`).
        pub fn fromRgba8(r: u8, g: u8, b: u8, a: u8) Self {
            comptime {
                if (CS != Srgb) {
                    @compileError("AlphaColor.fromRgba8 is only defined for AlphaColor(Srgb)");
                }
            }
            return .{ .components = .{
                u8ToF32(r),
                u8ToF32(g),
                u8ToF32(b),
                u8ToF32(a),
            } };
        }

        /// Create a color from 8-bit RGB values with an opaque alpha.
        ///
        /// Only defined for sRGB (upstream `AlphaColor::<Srgb>::from_rgb8`).
        pub fn fromRgb8(r: u8, g: u8, b: u8) Self {
            comptime {
                if (CS != Srgb) {
                    @compileError("AlphaColor.fromRgb8 is only defined for AlphaColor(Srgb)");
                }
            }
            return .{ .components = .{ u8ToF32(r), u8ToF32(g), u8ToF32(b), 1.0 } };
        }
    };
}

/// A color with premultiplied alpha, in a color space known at compile time.
///
/// Following CSS Color 4, in cylindrical color spaces the hue channel is not
/// premultiplied.
pub fn PremulColor(comptime CS: type) type {
    return struct {
        /// The first three components are premultiplied color channels; the
        /// fourth is alpha.
        components: [4]f32,
        /// The color space (zero-sized for [`Srgb`]).
        cs: CS = .{},

        const Self = @This();

        /// A black color.
        pub const BLACK: Self = .{ .components = .{ 0.0, 0.0, 0.0, 1.0 } };
        /// A fully transparent color.
        pub const TRANSPARENT: Self = .{ .components = .{ 0.0, 0.0, 0.0, 0.0 } };
        /// The color space's white.
        pub const WHITE: Self = .{ .components = addAlpha(CS.WHITE_COMPONENTS, 1.0) };

        /// Create a color from the given components.
        pub fn new(components: [4]f32) Self {
            return .{ .components = components };
        }

        /// Split out the opaque components, discarding alpha.
        ///
        /// The result of calling this on a fully transparent color is black.
        pub fn discardAlpha(self: Self) OpaqueColor(CS) {
            return self.unPremultiply().discardAlpha();
        }

        /// Convert a color into a different color space.
        pub fn convert(self: Self, comptime TargetCS: type) PremulColor(TargetCS) {
            if (TargetCS == CS) {
                return PremulColor(TargetCS).new(self.components);
            }
            if (TargetCS.IS_LINEAR and CS.IS_LINEAR) {
                const converted = CS.convert(TargetCS, .{
                    self.components[0],
                    self.components[1],
                    self.components[2],
                });
                return PremulColor(TargetCS).new(addAlpha(converted, self.components[3]));
            }
            return self.unPremultiply().convert(TargetCS).premultiply();
        }

        /// Convert to the corresponding straight-alpha form.
        pub fn unPremultiply(self: Self) AlphaColor(CS) {
            const alpha = self.components[3];
            const scale: f32 = if (alpha == 0.0) 1.0 else 1.0 / alpha;
            const scaled = CS.LAYOUT.scale(.{
                self.components[0],
                self.components[1],
                self.components[2],
            }, scale);
            return AlphaColor(CS).new(addAlpha(scaled, alpha));
        }

        /// Multiply alpha by the given factor.
        pub fn multiplyAlpha(self: Self, rhs: f32) Self {
            const scaled = CS.LAYOUT.scale(.{
                self.components[0],
                self.components[1],
                self.components[2],
            }, rhs);
            return .{ .components = .{
                scaled[0],
                scaled[1],
                scaled[2],
                self.components[3] * rhs,
            } };
        }

        /// Pack the color into premultiplied 8-bit sRGB.
        pub fn toRgba8(self: Self) PremulRgba8 {
            const c = self.convert(Srgb).components;
            return .{
                .r = fastRoundToU8(c[0] * 255.0),
                .g = fastRoundToU8(c[1] * 255.0),
                .b = fastRoundToU8(c[2] * 255.0),
                .a = fastRoundToU8(c[3] * 255.0),
            };
        }

        /// Create a color from premultiplied 8-bit RGBA values.
        ///
        /// Only defined for sRGB (upstream
        /// `PremulColor::<Srgb>::from_rgba8`).
        pub fn fromRgba8(r: u8, g: u8, b: u8, a: u8) Self {
            comptime {
                if (CS != Srgb) {
                    @compileError("PremulColor.fromRgba8 is only defined for PremulColor(Srgb)");
                }
            }
            return .{ .components = .{
                u8ToF32(r),
                u8ToF32(g),
                u8ToF32(b),
                u8ToF32(a),
            } };
        }

        /// Create a color from premultiplied 8-bit RGB values with an opaque
        /// alpha.
        ///
        /// Only defined for sRGB (upstream `PremulColor::<Srgb>::from_rgb8`).
        pub fn fromRgb8(r: u8, g: u8, b: u8) Self {
            comptime {
                if (CS != Srgb) {
                    @compileError("PremulColor.fromRgb8 is only defined for PremulColor(Srgb)");
                }
            }
            return .{ .components = .{ u8ToF32(r), u8ToF32(g), u8ToF32(b), 1.0 } };
        }
    };
}

/// `color::u8_to_f32`: multiply by the reciprocal rather than dividing.
inline fn u8ToF32(x: u8) f32 {
    return @as(f32, @floatFromInt(x)) * (1.0 / 255.0);
}

/// The RGBA color type used by brushes (upstream `peniko::Color`).
pub const Color = AlphaColor(Srgb);

/// Round to nearest, ties away from zero, saturating like Rust's `as u8`.
fn realRoundToU8(v: f32) u8 {
    const r = @round(v);
    if (std.math.isNan(r) or r <= 0.0) return 0;
    if (r >= 255.0) return 255;
    return @intFromFloat(r);
}

fn nextDown(v: f32) f32 {
    return std.math.nextAfter(f32, v, -std.math.inf(f32));
}

fn nextUp(v: f32) f32 {
    return std.math.nextAfter(f32, v, std.math.inf(f32));
}

/// Relative comparison used by the transfer-function tests; `std.math.pow` is
/// not guaranteed to be bit-identical to the platform libm `powf`.
fn expectRelativelyClose(expected: f32, actual: f32) !void {
    const tolerance = 8.0 * std.math.floatEps(f32) * @max(@abs(expected), 1.0);
    try std.testing.expect(@abs(expected - actual) <= tolerance);
}

test "to_rgba8_saturation" {
    // Upstream `to_rgba8_saturation`: Rust's saturating `as u8` cast.
    const r = 0;
    const g = 0;
    const b = 255;
    const a = 255;

    const ac = AlphaColor(Srgb).new(.{ -1.01, -0.5, 1.01, 2.0 });
    try std.testing.expectEqual(Rgba8{ .r = r, .g = g, .b = b, .a = a }, ac.toRgba8());

    const pc = PremulColor(Srgb).new(.{ -1.01, -0.5, 1.01, 2.0 });
    try std.testing.expectEqual(PremulRgba8{ .r = r, .g = g, .b = b, .a = a }, pc.toRgba8());
}

test "to_rgba8 rounding matches upstream" {
    // Oracle values captured from `color` 0.3.3 on the pinned toolchain.
    const ac = AlphaColor(Srgb).new(.{ 0.5, 0.25, 0.75, 0.5 });
    try std.testing.expectEqual(Rgba8{ .r = 128, .g = 64, .b = 191, .a = 128 }, ac.toRgba8());

    const pc = PremulColor(Srgb).new(.{ 0.5, 0.25, 0.75, 0.5 });
    try std.testing.expectEqual(
        PremulRgba8{ .r = 128, .g = 64, .b = 191, .a = 128 },
        pc.toRgba8(),
    );

    const almost = AlphaColor(Srgb).new(.{ 0.0019607842, 0.0, 0.0, 1.0 });
    try std.testing.expectEqual(@as(u8, 1), almost.toRgba8().r);

    const bytes = AlphaColor(Srgb).new(.{
        1.0 / 255.0,
        2.0 / 255.0,
        254.0 / 255.0,
        1.0,
    });
    try std.testing.expectEqual(Rgba8{ .r = 1, .g = 2, .b = 254, .a = 255 }, bytes.toRgba8());
}

test "fast_round" {
    // Port of upstream `fast_round`: the only input in -1..=256 where
    // `(a + 0.5) as u8` differs from `a.round() as u8` is 0.49999997.
    const allocator = std.testing.allocator;
    var failures: std.ArrayList(f32) = .empty;
    defer failures.deinit(allocator);

    var v: f32 = -1.0;
    while (v <= 256.0) : (v += 0.5) {
        const abs_v = @abs(v);
        const frac = abs_v - @trunc(abs_v);
        try std.testing.expect(frac == 0.0 or frac == 0.5);

        const values = [5]f32{
            nextDown(nextDown(v)),
            nextDown(v),
            v,
            nextUp(v),
            nextUp(nextUp(v)),
        };
        for (values) |val| {
            if (realRoundToU8(val) != fastRoundToU8(val)) {
                try failures.append(allocator, val);
            }
        }
    }
    try std.testing.expectEqualSlices(f32, &.{0.49999997}, failures.items);
}

test "srgb transfer functions" {
    // (input, linear, srgb) triples produced by the upstream Rust
    // implementation. `std.math.pow` may differ by a couple of ULPs from the
    // platform libm, so compare relatively.
    const cases = [_]struct { x: f32, linear: f32, srgb: f32 }{
        .{ .x = 0.0, .linear = 0.0, .srgb = 0.0 },
        .{ .x = 0.0001, .linear = 7.739938e-6, .srgb = 0.001292 },
        .{ .x = 0.0031308, .linear = 0.00024232198, .srgb = 0.040449936 },
        .{ .x = 0.0031309, .linear = 0.00024232971, .srgb = 0.040451176 },
        .{ .x = 0.04045, .linear = 0.003130805, .srgb = 0.22220546 },
        .{ .x = 0.04046, .linear = 0.0031315938, .srgb = 0.22223404 },
        .{ .x = 0.5, .linear = 0.21404114, .srgb = 0.7353569 },
        .{ .x = 1.0, .linear = 1.0, .srgb = 0.99999994 },
        .{ .x = 2.0, .linear = 4.9538465, .srgb = 1.353256 },
        .{ .x = -0.5, .linear = -0.21404114, .srgb = -0.7353569 },
        .{ .x = -1.0, .linear = -1.0, .srgb = -0.99999994 },
    };
    for (cases) |case| {
        try expectRelativelyClose(case.linear, Srgb.toLinearSrgb(.{ case.x, case.x, case.x })[0]);
        try expectRelativelyClose(case.srgb, Srgb.fromLinearSrgb(.{ case.x, case.x, case.x })[0]);
    }

    // NaN propagates and negative values preserve their sign.
    try std.testing.expect(std.math.isNan(Srgb.toLinearSrgb(.{ std.math.nan(f32), 0, 0 })[0]));
    try std.testing.expect(std.math.signbit(Srgb.toLinearSrgb(.{ -0.25, 0, 0 })[0]));
    try std.testing.expect(std.math.signbit(Srgb.fromLinearSrgb(.{ -0.25, 0, 0 })[0]));
}

test "srgb transfer round trip" {
    const values = [_]f32{ 0.0, 1e-8, -1e-8, 0.0001, 0.0031308, 0.04045, 0.5, 1.0, 2.0, -0.5, -1.0 };
    for (values) |x| {
        const linear = Srgb.toLinearSrgb(.{ x, x, x });
        const round_tripped = Srgb.fromLinearSrgb(linear);
        try expectRelativelyClose(x, round_tripped[0]);

        const encoded = Srgb.fromLinearSrgb(.{ x, x, x });
        const linear_again = Srgb.toLinearSrgb(encoded);
        try expectRelativelyClose(x, linear_again[0]);
    }
}

test "srgb clip" {
    try std.testing.expectEqual([3]f32{ 0.4, 0.0, 1.0 }, Srgb.clip(.{ 0.4, -0.2, 1.2 }));
}

test "premultiply and un_premultiply" {
    const a = AlphaColor(Srgb).new(.{ 0.2, 0.4, 0.6, 0.5 });
    const p = a.premultiply();
    try std.testing.expectEqualSlices(f32, &.{ 0.1, 0.2, 0.3, 0.5 }, &p.components);

    const u = p.unPremultiply();
    try std.testing.expectEqualSlices(f32, &a.components, &u.components);

    // Fully transparent colors un-premultiply to black (scale of 1, not 1/0).
    const transparent = AlphaColor(Srgb).new(.{ 0.25, 0.5, 0.75, 0.0 }).premultiply();
    try std.testing.expectEqualSlices(
        f32,
        &.{ 0.0, 0.0, 0.0, 0.0 },
        &transparent.unPremultiply().components,
    );
}

test "with_alpha and multiply_alpha" {
    const a = AlphaColor(Srgb).new(.{ 0.2, 0.4, 0.6, 0.8 });
    try std.testing.expectEqualSlices(
        f32,
        &.{ 0.2, 0.4, 0.6, 0.25 },
        &a.withAlpha(0.25).components,
    );
    try std.testing.expectEqualSlices(
        f32,
        &.{ 0.2, 0.4, 0.6, 0.4 },
        &a.multiplyAlpha(0.5).components,
    );

    const p = a.premultiply();
    try std.testing.expectEqualSlices(
        f32,
        &.{ 0.080000006, 0.16000001, 0.24000001, 0.4 },
        &p.multiplyAlpha(0.5).components,
    );
    try std.testing.expectEqualSlices(
        f32,
        &.{ 0.32000002, 0.64000005, 0.96000004, 1.6 },
        &p.multiplyAlpha(2.0).components,
    );
}

test "split and discard_alpha" {
    const a = AlphaColor(Srgb).new(.{ 0.1, 0.2, 0.3, 0.4 });
    const split = a.split();
    try std.testing.expectEqual(0.4, split.alpha);
    try std.testing.expectEqualSlices(f32, &.{ 0.1, 0.2, 0.3 }, &split.color.components);

    const premultiplied = PremulColor(Srgb).new(.{ 0.05, 0.1, 0.15, 0.5 });
    try std.testing.expectEqualSlices(
        f32,
        &.{ 0.1, 0.2, 0.3 },
        &premultiplied.discardAlpha().components,
    );
}

test "from_rgb8 and from_rgba8" {
    const c = AlphaColor(Srgb).fromRgb8(255, 128, 0);
    try std.testing.expectEqual(u8ToF32(255), c.components[0]);
    try std.testing.expectEqual(u8ToF32(128), c.components[1]);
    try std.testing.expectEqual(@as(f32, 0.0), c.components[2]);
    try std.testing.expectEqual(@as(f32, 1.0), c.components[3]);

    const t = AlphaColor(Srgb).fromRgba8(0, 0, 0, 0);
    try std.testing.expectEqualSlices(f32, &AlphaColor(Srgb).TRANSPARENT.components, &t.components);
}

test "opaque color" {
    const o = OpaqueColor(Srgb).new(.{ 1.0, 0.5, 0.25 });
    try std.testing.expectEqualSlices(
        f32,
        &.{ 1.0, 0.5, 0.25, 0.5 },
        &o.withAlpha(0.5).components,
    );
    try std.testing.expectEqual(
        Rgba8{ .r = 255, .g = 128, .b = 64, .a = 255 },
        o.toRgba8(),
    );
}

test "color space tag round trip" {
    inline for (0..16) |value| {
        const tag = ColorSpaceTag.fromU8(@intCast(value)).?;
        try std.testing.expectEqual(@as(u8, @intCast(value)), tag.toU8());
    }
    try std.testing.expectEqual(@as(?ColorSpaceTag, null), ColorSpaceTag.fromU8(16));
    try std.testing.expectEqual(ColorSpaceLayout.hue_first, ColorSpaceTag.hsl.layout());
    try std.testing.expectEqual(ColorSpaceLayout.hue_third, ColorSpaceTag.oklch.layout());
    try std.testing.expectEqual(ColorSpaceLayout.rectangular, ColorSpaceTag.srgb.layout());
}

test "hue direction round trip" {
    inline for (0..4) |value| {
        const direction = HueDirection.fromU8(@intCast(value)).?;
        try std.testing.expectEqual(@as(u8, @intCast(value)), direction.toU8());
    }
    try std.testing.expectEqual(@as(?HueDirection, null), HueDirection.fromU8(4));
    try std.testing.expectEqual(HueDirection.shorter, HueDirection.default);
}

test "color layout is renderer friendly" {
    // The renderer reinterprets component arrays; alpha colors must be four
    // tightly packed f32 with no padding from the zero-sized color space.
    try std.testing.expectEqual(@as(usize, 16), @sizeOf(AlphaColor(Srgb)));
    try std.testing.expectEqual(@as(usize, 16), @sizeOf(PremulColor(Srgb)));
    try std.testing.expectEqual(@as(usize, 12), @sizeOf(OpaqueColor(Srgb)));
    try std.testing.expectEqual(@as(usize, 0), @offsetOf(AlphaColor(Srgb), "components"));
    try std.testing.expectEqual(@as(usize, 0), @offsetOf(PremulColor(Srgb), "components"));
    try std.testing.expectEqual(@as(usize, 0), @offsetOf(OpaqueColor(Srgb), "components"));
}
