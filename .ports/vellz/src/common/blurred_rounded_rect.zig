//! Port of vello_common blurred_rounded_rect.rs (Apache-2.0 OR MIT).
//!
//! Ownership/allocator note: plain value, no heap data and no allocator.

const std = @import("std");
const kurbo = @import("../kurbo/root.zig");
const peniko = @import("../peniko/root.zig");

/// A blurred, rounded rectangle.
pub const BlurredRoundedRectangle = struct {
    /// The base rectangle to use for the blur effect.
    rect: kurbo.Rect,
    /// The color of the blurred rectangle.
    color: peniko.AlphaColor(peniko.Srgb),
    /// The radius of the rounded rectangle's corners.
    radius: f32,
    /// The standard deviation of the blur effect.
    std_dev: f32,
    /// Whether to paint the inverse (`1 - alpha`) of the blur coverage.
    ///
    /// When `true`, the paint is fully opaque outside the blurred rectangle and
    /// fades to transparent inside it. This is useful for implementing inset
    /// box shadows.
    invert: bool,

    /// The all-zero value: `Rect.ZERO`, transparent sRGB black, zero radius
    /// and standard deviation, and `invert = false`.
    ///
    /// Upstream does not implement `Default` for this struct (every call site
    /// uses a struct literal), so this constant is a Zig convenience with the
    /// values a derived `Default` would produce.
    pub const default: BlurredRoundedRectangle = .{
        .rect = kurbo.Rect.ZERO,
        .color = peniko.AlphaColor(peniko.Srgb).TRANSPARENT,
        .radius = 0.0,
        .std_dev = 0.0,
        .invert = false,
    };
};

test "default is the all-zero blurred rectangle" {
    const rect = BlurredRoundedRectangle.default;
    try std.testing.expectEqual(kurbo.Rect.ZERO, rect.rect);
    try std.testing.expectEqual(peniko.AlphaColor(peniko.Srgb).TRANSPARENT, rect.color);
    try std.testing.expectEqual(@as(f32, 0.0), rect.radius);
    try std.testing.expectEqual(@as(f32, 0.0), rect.std_dev);
    try std.testing.expect(!rect.invert);
}
