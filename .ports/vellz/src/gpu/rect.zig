//! Port of `vello_gpu/src/rect.rs` (Apache-2.0 OR MIT).
//!
//! Decomposition of a recorded rectangle into the pixel-aligned main part and
//! up to four anti-aliased edge strips used by the rectangle fast path. The
//! packed `frac` word is consumed by the render shader's `unpack4x8unorm`
//! edge-coverage calculation (see `render.wgsl`).
//!
//! This module is CPU-safe: it imports only `vellz.common`/`vellz.kurbo`.

const std = @import("std");
const kurbo = @import("../kurbo/root.zig");
const geometry = @import("../common/geometry.zig");

const Rect = kurbo.Rect;
const RectU16 = geometry.RectU16;

/// The threshold of the rectangle size after which a rectangle should be split
/// up into multiple smaller ones.
const LARGE_RECT_SPLIT_THRESHOLD: u16 = 32;

/// Integer rectangle geometry and its packed fractional edge coverage.
pub const RectPart = struct {
    /// Pixel-aligned bounds of this rectangle part.
    rect: RectU16,
    /// Packed fractional coverage for the four edges.
    frac: u32,

    /// Return this part shifted by `shift`.
    pub fn shift(self: RectPart, delta: [2]i32) RectPart {
        return .{ .rect = self.rect.shift(delta), .frac = self.frac };
    }
};

/// A decomposed rectangle.
pub const SplitRect = struct {
    /// Main rectangle interior, or the complete rectangle when it is not split.
    main: RectPart,
    /// Top antialiased strip, if required.
    top: ?RectPart,
    /// Bottom antialiased strip, if required.
    bottom: ?RectPart,
    /// Left antialiased strip between the top and bottom strips, if required.
    left: ?RectPart,
    /// Right antialiased strip between the top and bottom strips, if required.
    right: ?RectPart,
};

/// Split a pixel-aligned rectangle into its interior and anti-aliased edge
/// strips (upstream `split_rect`).
///
/// The rectangle must have non-negative extent and lie within the u16 viewport
/// domain; callers clip it before calling.
pub fn splitRect(rect: Rect) SplitRect {
    const sx0 = @floor(rect.x0);
    const sy0 = @floor(rect.y0);
    const sx1 = @ceil(rect.x1);
    const sy1 = @ceil(rect.y1);

    const x: u16 = @intFromFloat(sx0);
    const y: u16 = @intFromFloat(sy0);
    // Guaranteed positive because zero-area and inverted rectangles are
    // rejected by the caller.
    const width: u16 = @intFromFloat(sx1 - sx0);
    const height: u16 = @intFromFloat(sy1 - sy0);

    // Note that `top_frac` and `left_frac` store the actual coverage, while
    // `right_frac` and `bottom_frac` store one minus the coverage. This is on
    // purpose and handled that way in the shader.
    const left_frac: f32 = @floatCast(rect.x0 - sx0);
    const top_frac: f32 = @floatCast(rect.y0 - sy0);
    const right_frac: f32 = @floatCast(sx1 - rect.x1);
    const bottom_frac: f32 = @floatCast(sy1 - rect.y1);

    // There's a balance to strike between reducing work in the fragment shader
    // by splitting out the inner part of the rectangle without anti-aliasing,
    // and additional overhead that arises from rendering 5 rectangles instead
    // of just one. `LARGE_RECT_SPLIT_THRESHOLD` matches upstream's measured
    // low-tier tablet value.
    if (rect.x1 - rect.x0 < @as(f64, @floatFromInt(LARGE_RECT_SPLIT_THRESHOLD)) or
        rect.y1 - rect.y0 < @as(f64, @floatFromInt(LARGE_RECT_SPLIT_THRESHOLD)))
    {
        return .{
            .main = .{
                .rect = RectU16.new(x, y, x + width, y + height),
                .frac = packUnorm4x8(.{ left_frac, top_frac, right_frac, bottom_frac }),
            },
            .top = null,
            .bottom = null,
            .left = null,
            .right = null,
        };
    }

    const has_left_aa = left_frac > 0.0;
    const has_top_aa = top_frac > 0.0;
    const has_right_aa = right_frac > 0.0;
    const has_bottom_aa = bottom_frac > 0.0;
    const has_top_strip = has_top_aa or has_left_aa or has_right_aa;
    const has_bottom_strip = has_bottom_aa or has_left_aa or has_right_aa;
    const left_inset: u16 = @intFromBool(has_left_aa);
    const right_inset: u16 = @intFromBool(has_right_aa);
    const top_inset: u16 = @intFromBool(has_top_strip);
    const bottom_inset: u16 = @intFromBool(has_bottom_strip);
    const inner_x = x + left_inset;
    const inner_y = y + top_inset;
    // Can't underflow because both extent sides are at least
    // `LARGE_RECT_SPLIT_THRESHOLD` (larger than 2).
    const inner_width = width - left_inset - right_inset;
    const inner_height = height - top_inset - bottom_inset;

    return .{
        .main = .{
            .rect = RectU16.new(inner_x, inner_y, inner_x + inner_width, inner_y + inner_height),
            .frac = 0,
        },
        .top = if (has_top_strip) .{
            .rect = RectU16.new(x, y, x + width, y + 1),
            .frac = packUnorm4x8(.{ left_frac, top_frac, right_frac, 0.0 }),
        } else null,
        .bottom = if (has_bottom_strip) .{
            .rect = RectU16.new(x, y + height - 1, x + width, y + height),
            .frac = packUnorm4x8(.{ left_frac, 0.0, right_frac, bottom_frac }),
        } else null,
        .left = if (has_left_aa) .{
            .rect = RectU16.new(x, inner_y, x + 1, inner_y + inner_height),
            .frac = packUnorm4x8(.{ left_frac, 0.0, 0.0, 0.0 }),
        } else null,
        .right = if (has_right_aa) .{
            .rect = RectU16.new(x + width - 1, inner_y, x + width, inner_y + inner_height),
            .frac = packUnorm4x8(.{ 0.0, 0.0, right_frac, 0.0 }),
        } else null,
    };
}

/// Pack four normalized `f32` coverage values into `u8` lanes in the same
/// layout as WGSL `pack4x8unorm` (upstream `pack_unorm4x8`).
fn packUnorm4x8(v: [4]f32) u32 {
    const q = struct {
        fn call(f: f32) u8 {
            return @intFromFloat(f * 255.0 + 0.5);
        }
    }.call;
    return @as(u32, q(v[0])) |
        (@as(u32, q(v[1])) << 8) |
        (@as(u32, q(v[2])) << 16) |
        (@as(u32, q(v[3])) << 24);
}

// ---------------------------------------------------------------------------
// Tests (ported from `rect.rs`)
// ---------------------------------------------------------------------------

const testing = std.testing;

fn part(x: u16, y: u16, width: u16, height: u16, frac: [4]f32) RectPart {
    return .{
        .rect = RectU16.new(x, y, x + width, y + height),
        .frac = packUnorm4x8(frac),
    };
}

test "splitter keeps small rect whole" {
    const rect = Rect.new(10.25, 20.5, 25.75, 35.25);
    const split = splitRect(rect);

    try testing.expectEqual(part(10, 20, 16, 16, .{ 0.25, 0.5, 0.25, 0.75 }), split.main);
    try testing.expectEqual(@as(?RectPart, null), split.top);
    try testing.expectEqual(@as(?RectPart, null), split.bottom);
    try testing.expectEqual(@as(?RectPart, null), split.left);
    try testing.expectEqual(@as(?RectPart, null), split.right);
}

test "splitter keeps subpixel rect inside one pixel" {
    const rect = Rect.new(10.125, 20.25, 10.875, 20.75);
    const split = splitRect(rect);

    try testing.expectEqual(part(10, 20, 1, 1, .{ 0.125, 0.25, 0.125, 0.25 }), split.main);
    try testing.expectEqual(@as(?RectPart, null), split.top);
}

test "splitter keeps subpixel rect spanning two pixels in width" {
    const rect = Rect.new(10.75, 20.125, 11.25, 20.875);
    const split = splitRect(rect);

    try testing.expectEqual(part(10, 20, 2, 1, .{ 0.75, 0.125, 0.75, 0.125 }), split.main);
}

test "splitter keeps subpixel rect spanning two pixels in height" {
    const rect = Rect.new(10.125, 20.75, 10.875, 21.25);
    const split = splitRect(rect);

    try testing.expectEqual(part(10, 20, 1, 2, .{ 0.125, 0.75, 0.125, 0.75 }), split.main);
}

test "splitter keeps multi-pixel width rect within one pixel height" {
    const rect = Rect.new(10.25, 20.125, 14.75, 20.875);
    const split = splitRect(rect);

    try testing.expectEqual(part(10, 20, 5, 1, .{ 0.25, 0.125, 0.25, 0.125 }), split.main);
}

test "splitter keeps multi-pixel height rect within one pixel width" {
    const rect = Rect.new(10.125, 20.25, 10.875, 24.75);
    const split = splitRect(rect);

    try testing.expectEqual(part(10, 20, 1, 5, .{ 0.125, 0.25, 0.125, 0.25 }), split.main);
}

test "splitter splits large rect into five parts" {
    const rect = Rect.new(10.25, 20.5, 42.75, 52.75);
    const split = splitRect(rect);

    try testing.expectEqual(part(11, 21, 31, 31, .{ 0.0, 0.0, 0.0, 0.0 }), split.main);
    try testing.expectEqual(part(10, 20, 33, 1, .{ 0.25, 0.5, 0.25, 0.0 }), split.top.?);
    try testing.expectEqual(part(10, 52, 33, 1, .{ 0.25, 0.0, 0.25, 0.25 }), split.bottom.?);
    try testing.expectEqual(part(10, 21, 1, 31, .{ 0.25, 0.0, 0.0, 0.0 }), split.left.?);
    try testing.expectEqual(part(42, 21, 1, 31, .{ 0.0, 0.0, 0.25, 0.0 }), split.right.?);
}

test "splitter omits unneeded edge parts" {
    const rect = Rect.new(10.0, 20.5, 42.0, 53.0);
    const split = splitRect(rect);

    try testing.expectEqual(part(10, 21, 32, 32, .{ 0.0, 0.0, 0.0, 0.0 }), split.main);
    try testing.expectEqual(part(10, 20, 32, 1, .{ 0.0, 0.5, 0.0, 0.0 }), split.top.?);
    try testing.expectEqual(@as(?RectPart, null), split.bottom);
    try testing.expectEqual(@as(?RectPart, null), split.left);
    try testing.expectEqual(@as(?RectPart, null), split.right);
}

test "splitter handles large rect with only vertical aa" {
    const rect = Rect.new(5.0, 2.25, 37.0, 34.75);
    const split = splitRect(rect);

    try testing.expectEqual(part(5, 3, 32, 31, .{ 0.0, 0.0, 0.0, 0.0 }), split.main);
    try testing.expectEqual(part(5, 2, 32, 1, .{ 0.0, 0.25, 0.0, 0.0 }), split.top.?);
    try testing.expectEqual(part(5, 34, 32, 1, .{ 0.0, 0.0, 0.0, 0.25 }), split.bottom.?);
    try testing.expectEqual(@as(?RectPart, null), split.left);
    try testing.expectEqual(@as(?RectPart, null), split.right);
}

test "splitter keeps large aligned rect as single main rect" {
    const rect = Rect.new(10.0, 20.0, 42.0, 60.0);
    const split = splitRect(rect);

    try testing.expectEqual(part(10, 20, 32, 40, .{ 0.0, 0.0, 0.0, 0.0 }), split.main);
    try testing.expectEqual(@as(?RectPart, null), split.top);
    try testing.expectEqual(@as(?RectPart, null), split.bottom);
    try testing.expectEqual(@as(?RectPart, null), split.left);
    try testing.expectEqual(@as(?RectPart, null), split.right);
}
