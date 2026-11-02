//! Color types ported from GPUI's color.rs: RGBA, HSLA, and background fills.
const std = @import("std");

/// Error returned when a string is not a `#rgb`, `#rgba`, `#rrggbb` or `#rrggbbaa` color.
pub const HexParseError = error{InvalidHexColor};

/// Converts an RGB hex color code to a color.
pub fn rgb(hex: u32) Rgba {
    return .{
        .r = channel(@truncate((hex >> 16) & 0xff)),
        .g = channel(@truncate((hex >> 8) & 0xff)),
        .b = channel(@truncate(hex & 0xff)),
        .a = 1.0,
    };
}

/// Converts an RGBA hex color code to a color.
pub fn rgba(hex: u32) Rgba {
    return .{
        .r = channel(@truncate((hex >> 24) & 0xff)),
        .g = channel(@truncate((hex >> 16) & 0xff)),
        .b = channel(@truncate((hex >> 8) & 0xff)),
        .a = channel(@truncate(hex & 0xff)),
    };
}

/// Constructs an `Hsla` from plain values, clamping each to [0, 1].
pub fn hsla(h: f32, s: f32, l: f32, a: f32) Hsla {
    return .{
        .h = clamp01(h),
        .s = clamp01(s),
        .l = clamp01(l),
        .a = clamp01(a),
    };
}

/// Opaque grey in `Hsla`, with lightness and opacity clamped to [0, 1].
pub fn opaque_grey(lightness: f32, opacity: f32) Hsla {
    return .{ .h = 0, .s = 0, .l = clamp01(lightness), .a = clamp01(opacity) };
}

/// Pure black in `Hsla`.
pub const black = Hsla.black;
/// Pure white in `Hsla`.
pub const white = Hsla.white;
/// The color red in `Hsla`.
pub const red = Hsla.red;
/// The color blue in `Hsla`.
pub const blue = Hsla.blue;
/// The color green in `Hsla`.
pub const green = Hsla.green;
/// The color yellow in `Hsla`.
pub const yellow = Hsla.yellow;
/// Transparent black in `Hsla`.
pub const transparent_black = Hsla.transparent_black;

/// Transparent white in `Hsla`.
pub fn transparent_white() Hsla {
    return .{ .h = 0, .s = 0, .l = 1, .a = 0 };
}

/// Converts a `Hsla` or `Rgba` to `Hsla`.
pub fn to_hsla(v: anytype) Hsla {
    const T = @TypeOf(v);
    if (T == Hsla) return v;
    if (T == Rgba) return v.to_hsla();
    @compileError("to_hsla expects Hsla or Rgba, found " ++ @typeName(T));
}

/// Converts a `Hsla`, `Rgba` or `Background` to `Background`.
pub fn to_background(v: anytype) Background {
    const T = @TypeOf(v);
    if (T == Background) return v;
    if (T == Hsla or T == Rgba) return solid_background(v);
    @compileError("to_background expects Hsla, Rgba or Background, found " ++ @typeName(T));
}

/// Swaps an RGBA premultiplied-alpha pixel to BGRA in place. Requires at least 4 bytes.
pub fn swap_rgba_pa_to_bgra(pixel: []u8) void {
    std.debug.assert(pixel.len >= 4);
    std.mem.swap(u8, &pixel[0], &pixel[2]);
    if (pixel[3] > 0) {
        const alpha: f32 = @as(f32, @floatFromInt(pixel[3])) / 255.0;
        pixel[0] = saturatingU8(@as(f32, @floatFromInt(pixel[0])) / alpha);
        pixel[1] = saturatingU8(@as(f32, @floatFromInt(pixel[1])) / alpha);
        pixel[2] = saturatingU8(@as(f32, @floatFromInt(pixel[2])) / alpha);
    }
}

/// An RGBA color with components in the range 0.0 to 1.0.
pub const Rgba = extern struct {
    /// Red component.
    r: f32,
    /// Green component.
    g: f32,
    /// Blue component.
    b: f32,
    /// Alpha component.
    a: f32,

    pub const default: Rgba = .{ .r = 0, .g = 0, .b = 0, .a = 0 };

    /// Parses `#rgb`, `#rgba`, `#rrggbb` or `#rrggbbaa`, ignoring surrounding whitespace.
    pub fn from_hex(text: []const u8) HexParseError!Rgba {
        const trimmed = std.mem.trim(u8, text, " \t\r\n");
        if (trimmed.len == 0 or trimmed[0] != '#') return error.InvalidHexColor;
        const hex = trimmed[1..];

        var r: u8 = 0;
        var g: u8 = 0;
        var b: u8 = 0;
        var a: u8 = 0xff;
        switch (hex.len) {
            3, 4 => {
                r = duplicateDigit(try hexDigit(hex[0]));
                g = duplicateDigit(try hexDigit(hex[1]));
                b = duplicateDigit(try hexDigit(hex[2]));
                a = if (hex.len == 4) duplicateDigit(try hexDigit(hex[3])) else 0xff;
            },
            6, 8 => {
                r = try hexPair(hex[0..2]);
                g = try hexPair(hex[2..4]);
                b = try hexPair(hex[4..6]);
                a = if (hex.len == 8) try hexPair(hex[6..8]) else 0xff;
            },
            else => return error.InvalidHexColor,
        }

        return .{
            .r = channel(r),
            .g = channel(g),
            .b = channel(b),
            .a = channel(a),
        };
    }

    /// Blends `other` on top of `self` based on `other`'s alpha.
    pub fn blend(self: Rgba, other: Rgba) Rgba {
        if (other.a >= 1.0) return other;
        if (other.a <= 0.0) return self;
        return .{
            .r = (self.r * (1.0 - other.a)) + (other.r * other.a),
            .g = (self.g * (1.0 - other.a)) + (other.g * other.a),
            .b = (self.b * (1.0 - other.a)) + (other.b * other.a),
            .a = self.a,
        };
    }

    /// Returns the same RGB channels with the alpha set to `a`, clamped to [0, 1].
    pub fn alpha(self: Rgba, a: f32) Rgba {
        return .{ .r = self.r, .g = self.g, .b = self.b, .a = clamp01(a) };
    }

    /// Returns the same color with its alpha multiplied by `factor`, clamped to [0, 1].
    pub fn opacity(self: Rgba, factor: f32) Rgba {
        return .{ .r = self.r, .g = self.g, .b = self.b, .a = self.a * clamp01(factor) };
    }

    /// Converts to `Hsla`.
    pub fn to_hsla(self: Rgba) Hsla {
        return rgbaToHsla(self);
    }

    /// Packs into `0xRRGGBBAA`, truncating each channel.
    pub fn to_u32(self: Rgba) u32 {
        const r: u32 = saturatingU32(self.r * 255.0);
        const g: u32 = saturatingU32(self.g * 255.0);
        const b: u32 = saturatingU32(self.b * 255.0);
        const a: u32 = saturatingU32(self.a * 255.0);
        return (r << 24) | (g << 16) | (b << 8) | a;
    }
};

/// An HSLA color with components in the range 0.0 to 1.0.
pub const Hsla = extern struct {
    /// Hue.
    h: f32,
    /// Saturation.
    s: f32,
    /// Lightness.
    l: f32,
    /// Alpha.
    a: f32,

    pub const default: Hsla = .{ .h = 0, .s = 0, .l = 0, .a = 0 };

    /// The color red.
    pub fn red() Hsla {
        return .{ .h = 0, .s = 1, .l = 0.5, .a = 1 };
    }

    /// The color green.
    pub fn green() Hsla {
        return .{ .h = 0.3333333333, .s = 1, .l = 0.25, .a = 1 };
    }

    /// The color blue.
    pub fn blue() Hsla {
        return .{ .h = 0.6666666667, .s = 1, .l = 0.5, .a = 1 };
    }

    /// The color yellow.
    pub fn yellow() Hsla {
        return .{ .h = 0.1666666667, .s = 1, .l = 0.5, .a = 1 };
    }

    /// Pure black.
    pub fn black() Hsla {
        return .{ .h = 0, .s = 0, .l = 0, .a = 1 };
    }

    /// Pure white.
    pub fn white() Hsla {
        return .{ .h = 0, .s = 0, .l = 1, .a = 1 };
    }

    /// Transparent black.
    pub fn transparent_black() Hsla {
        return .{ .h = 0, .s = 0, .l = 0, .a = 0 };
    }

    /// Converts to `Rgba`.
    pub fn to_rgb(self: Hsla) Rgba {
        return hslaToRgba(self);
    }

    /// Returns true if the color is fully transparent.
    pub fn is_transparent(self: Hsla) bool {
        return self.a == 0.0;
    }

    /// Returns true if the color is fully opaque.
    pub fn is_opaque(self: Hsla) bool {
        return self.a == 1.0;
    }

    /// Blends `other` on top of `self` using `other`'s alpha.
    pub fn blend(self: Hsla, other: Hsla) Hsla {
        if (other.a >= 1.0) return other;
        if (other.a <= 0.0) return self;
        return rgbaToHsla(hslaToRgba(self).blend(hslaToRgba(other)));
    }

    /// Returns the same hue and lightness with no saturation.
    pub fn grayscale(self: Hsla) Hsla {
        return .{ .h = self.h, .s = 0, .l = self.l, .a = self.a };
    }

    /// Reduces alpha by `factor` in [0, 1]; 1.0 makes the color fully transparent.
    pub fn fade_out(self: *Hsla, factor: f32) void {
        self.a *= 1.0 - clamp01(factor);
    }

    /// Returns the same color with its alpha multiplied by `factor`, clamped to [0, 1].
    pub fn opacity(self: Hsla, factor: f32) Hsla {
        return .{ .h = self.h, .s = self.s, .l = self.l, .a = self.a * clamp01(factor) };
    }

    /// Returns the same hue, saturation and lightness with alpha set to `a`, clamped to [0, 1].
    pub fn alpha(self: Hsla, a: f32) Hsla {
        return .{ .h = self.h, .s = self.s, .l = self.l, .a = clamp01(a) };
    }

    /// Compares field by field using total ordering, so NaN equals NaN with the same bits.
    pub fn eq(self: Hsla, other: Hsla) bool {
        return self.cmp(other) == .eq;
    }

    /// Total ordering over (h, s, l, a), following `f32::total_cmp`.
    pub fn cmp(self: Hsla, other: Hsla) std.math.Order {
        const pairs = .{
            .{ self.h, other.h },
            .{ self.s, other.s },
            .{ self.l, other.l },
            .{ self.a, other.a },
        };
        inline for (pairs) |pair| {
            const order = std.math.order(totalOrderKey(pair[0]), totalOrderKey(pair[1]));
            if (order != .eq) return order;
        }
        return .eq;
    }
};

/// Maps a float to an integer whose signed order matches `f32::total_cmp`.
fn totalOrderKey(value: f32) i32 {
    const bits: i32 = @bitCast(value);
    const mask: i32 = @bitCast(@as(u32, @bitCast(bits >> 31)) >> 1);
    return bits ^ mask;
}

/// Creates a solid background from a color.
pub fn solid_background(color: anytype) Background {
    var background = Background.default;
    background.solid = to_hsla(color);
    return background;
}

/// Creates a linear gradient. `angle` is in degrees, 0 pointing up and increasing clockwise.
pub fn linear_gradient(angle: f32, from: LinearColorStop, to: LinearColorStop) Background {
    var background = Background.default;
    background.tag = .linear_gradient;
    background.gradient_angle_or_pattern_height = angle;
    background.colors = .{ from, to };
    return background;
}

/// Creates a diagonal-stripe pattern. Matches GPUI's packing, which wraps on overflow as in release builds.
pub fn pattern_slash(color: anytype, width: f32, interval: f32) Background {
    const width_scaled: u32 = saturatingU32(width * 255.0);
    const interval_scaled: u32 = saturatingU32(interval * 255.0);
    const height: f32 = @floatFromInt(width_scaled *% 0xFFFF +% interval_scaled);

    var background = Background.default;
    background.tag = .pattern_slash;
    background.solid = to_hsla(color);
    background.gradient_angle_or_pattern_height = height;
    return background;
}

/// Creates a checkerboard background with square cells of `size`.
pub fn checkerboard(color: anytype, size: f32) Background {
    var background = Background.default;
    background.tag = .checkerboard;
    background.solid = to_hsla(color);
    background.gradient_angle_or_pattern_height = size;
    return background;
}

/// Creates a color stop for a linear gradient. `percentage` is in [0, 1].
pub fn linear_color_stop(color: anytype, percentage: f32) LinearColorStop {
    return .{ .color = to_hsla(color), .percentage = percentage };
}

/// Kind of a `Background`.
pub const BackgroundTag = enum(i32) {
    solid = 0,
    linear_gradient = 1,
    pattern_slash = 2,
    checkerboard = 3,
};

/// Color space used for gradient interpolation.
pub const ColorSpace = enum(i32) {
    /// The sRGB color space.
    srgb = 0,
    /// The Oklab color space.
    oklab = 1,

    pub const default: ColorSpace = .srgb;
};

/// A color stop in a linear gradient.
pub const LinearColorStop = extern struct {
    /// The color of the stop.
    color: Hsla,
    /// Position of the stop along the gradient, in [0, 1].
    percentage: f32,

    pub const default: LinearColorStop = .{ .color = Hsla.default, .percentage = 0 };

    /// Returns the stop with its color's alpha multiplied by `factor`.
    pub fn opacity(self: LinearColorStop, factor: f32) LinearColorStop {
        return .{ .color = self.color.opacity(factor), .percentage = self.percentage };
    }
};

/// A solid color or gradient fill. Laid out to match GPUI's `#[repr(C)]` struct, which is uploaded to the GPU.
pub const Background = extern struct {
    /// Which kind of fill this is.
    tag: BackgroundTag,
    /// Interpolation color space for gradients.
    color_space: ColorSpace,
    /// Solid color, or the pattern color for pattern backgrounds.
    solid: Hsla,
    /// Gradient angle in degrees, or pattern size.
    gradient_angle_or_pattern_height: f32,
    /// Gradient stops, used by linear gradients only.
    colors: [2]LinearColorStop,
    /// Padding for alignment, always zero.
    pad: u32,

    pub const default: Background = .{
        .tag = .solid,
        .color_space = ColorSpace.default,
        .solid = Hsla.default,
        .gradient_angle_or_pattern_height = 0,
        .colors = .{ LinearColorStop.default, LinearColorStop.default },
        .pad = 0,
    };

    /// Returns the color if this is a solid background.
    pub fn as_solid(self: Background) ?Hsla {
        return if (self.tag == .solid) self.solid else null;
    }

    /// Returns the background with its interpolation color space set to `color_space`.
    pub fn with_color_space(self: Background, color_space: ColorSpace) Background {
        var background = self;
        background.color_space = color_space;
        return background;
    }

    /// Returns the background with its alpha multiplied by `factor`.
    pub fn opacity(self: Background, factor: f32) Background {
        var background = self;
        background.solid = self.solid.opacity(factor);
        background.colors = .{ self.colors[0].opacity(factor), self.colors[1].opacity(factor) };
        return background;
    }

    /// Returns true if the fill is fully transparent.
    pub fn is_transparent(self: Background) bool {
        return switch (self.tag) {
            .solid, .pattern_slash, .checkerboard => self.solid.is_transparent(),
            .linear_gradient => self.colors[0].color.is_transparent() and self.colors[1].color.is_transparent(),
        };
    }
};

fn channel(value: u8) f32 {
    return @as(f32, @floatFromInt(value)) / 255.0;
}

fn clamp01(value: f32) f32 {
    return std.math.clamp(value, 0.0, 1.0);
}

fn saturatingU8(value: f32) u8 {
    if (!(value > 0)) return 0;
    if (value >= 255.0) return 255;
    return @intFromFloat(value);
}

fn saturatingU32(value: f32) u32 {
    if (!(value > 0)) return 0;
    if (value >= 4294967296.0) return std.math.maxInt(u32);
    return @intFromFloat(value);
}

fn hexDigit(c: u8) HexParseError!u8 {
    return switch (c) {
        '0'...'9' => c - '0',
        'a'...'f' => c - 'a' + 10,
        'A'...'F' => c - 'A' + 10,
        else => error.InvalidHexColor,
    };
}

fn hexPair(pair: []const u8) HexParseError!u8 {
    const high = try hexDigit(pair[0]);
    const low = try hexDigit(pair[1]);
    return (high << 4) | low;
}

fn duplicateDigit(digit: u8) u8 {
    return (digit << 4) | digit;
}

fn remEuclid(lhs: f32, rhs: f32) f32 {
    const remainder = @rem(lhs, rhs);
    return if (remainder < 0.0) remainder + @abs(rhs) else remainder;
}

/// Sector of the hue wheel, saturating like Rust's `as i32`; NaN maps to sector 0.
fn hueSector(scaled_hue: f32) i32 {
    const floored = @floor(scaled_hue);
    if (std.math.isNan(floored)) return 0;
    return @intFromFloat(std.math.clamp(floored, -1.0, 7.0));
}

fn hslaToRgba(color: Hsla) Rgba {
    const c = (1.0 - @abs(2.0 * color.l - 1.0)) * color.s;
    const x = c * (1.0 - @abs(@rem(color.h * 6.0, 2.0) - 1.0));
    const m = color.l - c / 2.0;
    const cm = c + m;
    const xm = x + m;

    const channels: [3]f32 = switch (hueSector(color.h * 6.0)) {
        0, 6 => .{ cm, xm, m },
        1 => .{ xm, cm, m },
        2 => .{ m, cm, xm },
        3 => .{ m, xm, cm },
        4 => .{ xm, m, cm },
        else => .{ cm, m, xm },
    };

    return .{
        .r = clamp01(channels[0]),
        .g = clamp01(channels[1]),
        .b = clamp01(channels[2]),
        .a = color.a,
    };
}

fn rgbaToHsla(color: Rgba) Hsla {
    const max = @max(color.r, @max(color.g, color.b));
    const min = @min(color.r, @min(color.g, color.b));
    const delta = max - min;

    const l = (max + min) / 2.0;
    const s: f32 = if (l == 0.0 or l == 1.0)
        0.0
    else if (l < 0.5)
        delta / (2.0 * l)
    else
        delta / (2.0 - 2.0 * l);

    const h: f32 = if (delta == 0.0)
        0.0
    else if (max == color.r)
        remEuclid((color.g - color.b) / delta, 6.0) / 6.0
    else if (max == color.g)
        ((color.b - color.r) / delta + 2.0) / 6.0
    else
        ((color.r - color.g) / delta + 4.0) / 6.0;

    return .{ .h = h, .s = s, .l = l, .a = color.a };
}

fn expectRgbaEqual(expected: Rgba, actual: Rgba) !void {
    try std.testing.expectEqual(expected.r, actual.r);
    try std.testing.expectEqual(expected.g, actual.g);
    try std.testing.expectEqual(expected.b, actual.b);
    try std.testing.expectEqual(expected.a, actual.a);
}

fn expectHslaEqual(expected: Hsla, actual: Hsla) !void {
    try std.testing.expectEqual(expected.h, actual.h);
    try std.testing.expectEqual(expected.s, actual.s);
    try std.testing.expectEqual(expected.l, actual.l);
    try std.testing.expectEqual(expected.a, actual.a);
}

test "deserialize three-value hex to rgba" {
    try expectRgbaEqual(rgba(0xff0099ff), try Rgba.from_hex("#f09"));
}

test "deserialize four-value hex to rgba" {
    try expectRgbaEqual(rgba(0xff0099ff), try Rgba.from_hex("#f09f"));
}

test "deserialize six-value hex to rgba" {
    try expectRgbaEqual(rgba(0xff0099ff), try Rgba.from_hex("#ff0099"));
}

test "deserialize eight-value hex to rgba" {
    try expectRgbaEqual(rgba(0xff0099ff), try Rgba.from_hex("#ff0099ff"));
}

test "deserialize eight-value hex with padding to rgba" {
    try expectRgbaEqual(rgba(0xf5f5f5ff), try Rgba.from_hex(" #f5f5f5ff   "));
}

test "deserialize eight-value hex with mixed case to rgba" {
    try expectRgbaEqual(rgba(0xdeadbeef), try Rgba.from_hex("#DeAdbEeF"));
}

test "rejects malformed hex" {
    try std.testing.expectError(error.InvalidHexColor, Rgba.from_hex("f09"));
    try std.testing.expectError(error.InvalidHexColor, Rgba.from_hex("#ff000"));
    try std.testing.expectError(error.InvalidHexColor, Rgba.from_hex("#gg0099"));
}

test "background solid" {
    const color = to_hsla(rgba(0xff0099ff));
    var background = to_background(color);
    try std.testing.expectEqual(BackgroundTag.solid, background.tag);
    try expectHslaEqual(color, background.solid);

    try expectHslaEqual(color.opacity(0.5), background.opacity(0.5).solid);
    try std.testing.expect(!background.is_transparent());
    background.solid = hsla(0.0, 0.0, 0.0, 0.0);
    try std.testing.expect(background.is_transparent());
}

test "background linear gradient" {
    const from = linear_color_stop(rgba(0xff0099ff), 0.0);
    const to = linear_color_stop(rgba(0x00ff99ff), 1.0);
    const background = linear_gradient(90.0, from, to);
    try std.testing.expectEqual(BackgroundTag.linear_gradient, background.tag);
    try expectHslaEqual(from.color, background.colors[0].color);
    try std.testing.expectEqual(from.percentage, background.colors[0].percentage);
    try expectHslaEqual(to.color, background.colors[1].color);
    try std.testing.expectEqual(to.percentage, background.colors[1].percentage);

    try expectHslaEqual(from.color.opacity(0.5), background.opacity(0.5).colors[0].color);
    try expectHslaEqual(to.color.opacity(0.5), background.opacity(0.5).colors[1].color);
    try std.testing.expect(!background.is_transparent());
    try std.testing.expect(background.opacity(0.0).is_transparent());
}

test "rgba alpha" {
    const color: Rgba = .{ .r = 0.2, .g = 0.6, .b = 1.0, .a = 0.8 };
    try std.testing.expectEqual(@as(f32, 0.25), color.alpha(0.25).a);
    try std.testing.expectEqual(@as(f32, 1.0), color.alpha(1.5).a);
}

test "rgba opacity" {
    const color: Rgba = .{ .r = 0.2, .g = 0.6, .b = 1.0, .a = 0.8 };
    try std.testing.expect(@abs(color.opacity(0.5).a - 0.4) < 1e-6);
    try std.testing.expectEqual(@as(f32, 0.8), color.opacity(2.0).a);
}

test "rgba packs to u32" {
    try std.testing.expectEqual(@as(u32, 0xff0099ff), rgba(0xff0099ff).to_u32());
}

test "hsla and rgba round trip" {
    const color = rgba(0x3399ffff);
    const back = color.to_hsla().to_rgb();
    try std.testing.expect(@abs(back.r - color.r) < 1e-5);
    try std.testing.expect(@abs(back.g - color.g) < 1e-5);
    try std.testing.expect(@abs(back.b - color.b) < 1e-5);
    try std.testing.expectEqual(color.a, back.a);
}

test "hsla eq uses total ordering" {
    try std.testing.expect(hsla(0.7, 1.0, 0.5, 0.7).eq(hsla(0.7, 1.0, 0.5, 0.7)));
    try std.testing.expect(!red().eq(blue()));
}

test "hsla fade_out and grayscale" {
    var color = red();
    color.fade_out(0.25);
    try std.testing.expectEqual(@as(f32, 0.75), color.a);
    try std.testing.expectEqual(@as(f32, 0.0), red().grayscale().s);
}

test "named colors" {
    try std.testing.expect(black().is_opaque());
    try std.testing.expect(transparent_black().is_transparent());
    try std.testing.expect(transparent_white().is_transparent());
    try std.testing.expectEqual(@as(f32, 1.0), opaque_grey(2.0, 1.0).l);
}

test "swap premultiplied rgba to bgra" {
    var pixel = [_]u8{ 255, 0, 0, 255 };
    swap_rgba_pa_to_bgra(&pixel);
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 255, 255 }, &pixel);
}
