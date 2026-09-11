//! Port of vello_common render_state.rs (Apache-2.0 OR MIT).
//!
//! Ownership/allocator note: `RenderState` is a plain value. Its paint may be
//! an image (shared pixmap) and its gradient stops are owned by the peniko
//! types; duplicating or dropping a state that holds those must go through
//! `paint.PaintType.clone`/`deinit` with the owning allocator.
//! `RenderState.default` itself is a solid black paint with no owned
//! resources.

const std = @import("std");
const kurbo = @import("../kurbo/root.zig");
const peniko = @import("../peniko/root.zig");
const paint = @import("paint.zig");
const transforms = @import("transforms.zig");

/// A render state which contains the style properties for path rendering.
pub const RenderState = struct {
    /// The paint type (solid color, gradient, or image).
    paint: paint.PaintType,
    /// Stroke style for path stroking operations.
    stroke: kurbo.Stroke,
    /// Fill rule for path filling operations.
    fill_rule: peniko.Fill,
    /// Blend mode for compositing.
    blend_mode: peniko.BlendMode,
    /// The tint for image painting.
    tint: ?paint.Tint,
    /// State of active transforms.
    transforms: transforms.Transforms,

    /// The upstream `Default`: black solid paint, width-1 bevel stroke with
    /// butt caps, non-zero fill, normal/src-over blending, no tint, identity
    /// transforms.
    pub const default: RenderState = .{
        .paint = paint.PaintType.fromAlphaColor(peniko.color.Color.BLACK),
        .stroke = kurbo.Stroke.new(1.0)
            .withJoin(.bevel)
            .withStartCap(.butt)
            .withEndCap(.butt),
        .fill_rule = .non_zero,
        .blend_mode = peniko.BlendMode.new(.normal, .src_over),
        .tint = null,
        .transforms = transforms.Transforms.default,
    };

    /// Reset to default state.
    pub fn reset(self: *RenderState) void {
        self.* = default;
    }
};

test "render_state_default_matches_upstream" {
    const state = RenderState.default;
    try std.testing.expectEqual(peniko.color.Color.BLACK, state.paint.solid);
    try std.testing.expectEqual(@as(f64, 1.0), state.stroke.width);
    try std.testing.expectEqual(kurbo.Join.bevel, state.stroke.join);
    try std.testing.expectEqual(kurbo.Cap.butt, state.stroke.start_cap);
    try std.testing.expectEqual(kurbo.Cap.butt, state.stroke.end_cap);
    try std.testing.expectEqual(peniko.Fill.non_zero, state.fill_rule);
    try std.testing.expectEqual(peniko.Mix.normal, state.blend_mode.mix);
    try std.testing.expectEqual(peniko.Compose.src_over, state.blend_mode.compose);
    try std.testing.expectEqual(@as(?paint.Tint, null), state.tint);
    try std.testing.expectEqual(transforms.Transforms.default, state.transforms);
}

test "render_state_reset" {
    var state = RenderState.default;
    state.fill_rule = .even_odd;
    state.paint = paint.PaintType.fromAlphaColor(peniko.color.Color.fromRgb8(255, 0, 0));
    state.transforms.setTransform(kurbo.Affine.scale(2.0));

    state.reset();

    try std.testing.expectEqual(peniko.Fill.non_zero, state.fill_rule);
    try std.testing.expectEqual(transforms.Transforms.default, state.transforms);
    try std.testing.expectEqual(peniko.color.Color.BLACK, state.paint.solid);
}
