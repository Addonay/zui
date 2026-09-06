//! Device-pixel rounding: crisp edges without layout jitter.
//!
//! Follows the GPUI pattern (`gpui/src/taffy.rs:270-344`): Taffy's own
//! rounding stays **off** (`disable_rounding`), layout and caching run in
//! pure logical pixels, and a single post-pass snaps the final edges to
//! the device grid. Two phases:
//!
//! 1. **Pre-layout** — snap definite style inputs with [`roundToDevicePx`]
//!   / [`ceilToDevicePx`] (borders round *up* so a 1px border never
//!   vanishes at 1.25x scale).
//! 2. **Post-layout** — snap each node's absolute edges with [`snapEdge`]
//!   (round-half-toward-zero), then re-derive `w/h` as `right - left`.
//!
//! ## Why not round during layout?
//!
//! Rounding mid-layout accumulates error down the tree (each level snaps
//! the residual of the last) and poisons the [`cache.NodeCache`], whose
//! keys are scale-independent logical sizes. A single end pass keeps the
//! cache valid across DPI changes and bounds total error to ±0.5 device px
//! per edge, independent of tree depth. Bevy 0.16 converged on the same
//! design (physical-only rounding at the end, custom mid-layout rounding
//! removed).
//!
//! ## The edge-closure vs stability trade-off
//!
//! Snapping `x` and `x+w` independently can leave a 1-device-px seam or
//! overlap between adjacent siblings (edges fail to "close"). Snapping
//! only origins accumulates drift on long translated strips. GPUI's
//! documented choice — and ours — is stability: snap every absolute edge
//! with ties toward zero, accept at most 1px residual on percentage-sized
//! descendants, and never let a rounded child shift its siblings.

/// Snap a logical value to the device grid (`scale` = device px per logical
/// px). Ties round away from zero (Zig `@round`); prefer [`snapEdge`] for
/// layout edges where tie direction matters.
pub fn roundToDevicePx(value: f32, scale: f32) f32 {
    if (scale <= 0) return value;
    return @round(value * scale) / scale;
}

/// Snap up to the device grid. Use for border widths and minimum sizes:
/// a hairline must never round down to zero physical pixels.
pub fn ceilToDevicePx(value: f32, scale: f32) f32 {
    if (scale <= 0) return value;
    return @ceil(value * scale) / scale;
}

/// Snap down to the device grid. Use for maximum constraints.
pub fn floorToDevicePx(value: f32, scale: f32) f32 {
    if (scale <= 0) return value;
    return @floor(value * scale) / scale;
}

/// Post-layout edge snap: round-half-**toward-zero** on absolute edges.
///
/// Positive edges behave like `@floor(x + 0.5)`, negative edges like
/// `@ceil(x - 0.5)`. Symmetric around zero, so a strip translated by `-k`
/// snaps to the mirror of `+k` — no systematic leftward drift on scrolled
/// content. Non-positive scales disable snapping (headless tests).
pub fn snapEdge(value: f32, scale: f32) f32 {
    if (scale <= 0) return value;
    const scaled = value * scale;
    const magnitude = @abs(scaled);
    const lower = @floor(magnitude);
    // A half-device-pixel tie goes toward zero. This is the subtle
    // distinction between GPUI's `round_half_toward_zero` and Zig's
    // `@round`, which rounds exact positive halves away from zero.
    const rounded = lower + @as(f32, if (magnitude - lower > 0.5) 1 else 0);
    return (if (scaled < 0) -rounded else rounded) / scale;
}

/// Snap a `(pos, size)` pair by snapping both absolute edges.
/// Returns the adjusted pair; size stays `>= 0` even if both edges snap
/// onto the same device pixel (collapses to zero, never negative).
pub fn snapSpan(pos: f32, size: f32, scale: f32) struct { pos: f32, size: f32 } {
    if (scale <= 0) return .{ .pos = pos, .size = size };
    const p0 = snapEdge(pos, scale);
    const p1 = snapEdge(pos + size, scale);
    return .{ .pos = p0, .size = @max(0, p1 - p0) };
}

test "rounding snaps to scale" {
    const testing = @import("std").testing;
    try testing.expectEqual(@as(f32, 10), roundToDevicePx(10.4, 1));
    try testing.expectEqual(@as(f32, 10.5), roundToDevicePx(10.49, 2));
    try testing.expectEqual(@as(f32, 11), ceilToDevicePx(10.1, 1));
    try testing.expectEqual(@as(f32, 10), snapEdge(10.4, 1));
}

test "ceil never drops hairlines" {
    const testing = @import("std").testing;
    try testing.expectEqual(@as(f32, 1), ceilToDevicePx(0.2, 1));
    try testing.expectEqual(@as(f32, 0.5), ceilToDevicePx(0.2, 2));
}

test "floor caps maximums" {
    const testing = @import("std").testing;
    try testing.expectEqual(@as(f32, 10), floorToDevicePx(10.9, 1));
}

test "snap edge is symmetric around zero" {
    const testing = @import("std").testing;
    try testing.expectEqual(@as(f32, 10), snapEdge(10.4, 1));
    try testing.expectEqual(@as(f32, -10), snapEdge(-10.4, 1));
    // Exact halves go toward zero on both sides.
    try testing.expectEqual(@as(f32, 10), snapEdge(10.5, 1));
    try testing.expectEqual(@as(f32, -10), snapEdge(-10.5, 1));
}

test "snap span keeps size non-negative" {
    const testing = @import("std").testing;
    const a = snapSpan(0.4, 10, 1);
    try testing.expectEqual(@as(f32, 0), a.pos);
    try testing.expectEqual(@as(f32, 10), a.size);
    // Sub-pixel sliver collapses to zero, never negative.
    const b = snapSpan(0.4, 0.1, 1);
    try testing.expect(b.size >= 0);
}

test "non-positive scale disables snapping" {
    const testing = @import("std").testing;
    try testing.expectEqual(@as(f32, 10.37), roundToDevicePx(10.37, 0));
    try testing.expectEqual(@as(f32, 10.37), snapEdge(10.37, -1));
}
