//! Port of vello_cpu src/coarse/cmd.rs (Apache-2.0 OR MIT).
//!
//! Render commands for a single row of strips.
//!
//! Ownership/allocator note: every command is a plain copyable value. Masks are
//! borrowed (`?*const Mask`) rather than copied; the owner of the mask must
//! outlive the bucketer and every rasterization that consumes these commands
//! (upstream stores an owned `Arc<Mask>` clone).
//!
//! Upstream's `AlphaIdx` (`NonZeroU32` + 1) is a layout optimization only: to
//! keep `Option<AlphaIdx>` 4 bytes. Zig does not need it, so `alpha_idx` is the
//! raw index exactly as documented in `docs/cpu-pipeline.md`.

const std = @import("std");
const peniko = @import("../../peniko/root.zig");
const paint_mod = @import("../../common/paint.zig");
const mask_mod = @import("../../common/mask.zig");
const depth = @import("depth.zig");
const util = @import("../util.zig");

pub const Span = util.Span;

const Paint = paint_mod.Paint;
const Mask = mask_mod.Mask;
const BlendMode = peniko.BlendMode;

/// A bucketed render command.
pub const RenderCmd = union(enum) {
    /// See [`PaintFill`].
    paint_fill: PaintFill,
    /// Push a new temporary layer buffer.
    push_buf: ?Span,
    /// Pop the last temporary layer buffer.
    pop_buf: void,
    /// See [`LayerFill`].
    layer_fill: LayerFill,
};

/// Fill a span with the given paint and optionally some alpha coverage.
pub const PaintFill = struct {
    /// The span to fill.
    span: Span,
    /// Index into the alpha buffer, or `null` for full coverage.
    alpha_idx: ?u32,
    /// Index into `CommandBucketer.paint_fill_attrs`.
    attrs_idx: u32,

    /// Create a new paint fill command.
    pub fn new(span: Span, alpha_idx: ?u32, attrs_idx: u32) PaintFill {
        return .{ .span = span, .alpha_idx = alpha_idx, .attrs_idx = attrs_idx };
    }

    /// The alpha coverage index, if any.
    pub fn alphaIdx(self: PaintFill) ?u32 {
        return self.alpha_idx;
    }
};

/// Fill a whole range of depth buckets with the given paint.
pub const DepthFill = struct {
    /// The depth buckets covered by this fill.
    bucket_range: depth.BucketRange,
    /// Index into `CommandBucketer.paint_fill_attrs`.
    attrs_idx: u32,

    /// Create a new depth fill command.
    pub fn new(bucket_range: depth.BucketRange, attrs_idx: u32) DepthFill {
        return .{ .bucket_range = bucket_range, .attrs_idx = attrs_idx };
    }

    /// The depth bucket range covered by this fill.
    pub fn bucketRange(self: DepthFill) depth.BucketRange {
        return self.bucket_range;
    }

    /// The pixel span covered by this fill.
    pub fn span(self: DepthFill) Span {
        return self.bucket_range.span();
    }
};

/// Composite a span from the current temporary layer buffer into the parent
/// buffer and optionally apply some alpha coverage.
pub const LayerFill = struct {
    /// The span to composite.
    span: Span,
    /// Index into the alpha buffer, or `null` for full coverage.
    alpha_idx: ?u32,
    /// Index into `CommandBucketer.layer_fill_attrs`.
    attrs_idx: u32,

    /// Create a new layer fill command.
    pub fn new(span: Span, alpha_idx: ?u32, attrs_idx: u32) LayerFill {
        return .{ .span = span, .alpha_idx = alpha_idx, .attrs_idx = attrs_idx };
    }

    /// The alpha coverage index, if any.
    pub fn alphaIdx(self: LayerFill) ?u32 {
        return self.alpha_idx;
    }
};

/// Attributes for a paint fill.
///
/// `mask` borrows the mask; see the file-level ownership note.
pub const PaintFillAttrs = struct {
    /// The paint to apply.
    paint: Paint,
    /// The blend mode used for the fill.
    blend_mode: BlendMode,
    /// An optional mask applied to the fill.
    mask: ?*const Mask,
    /// Monotonically increasing draw ID (starts at 1).
    draw_id: u32,
    /// Index of the thread-local alpha buffer that stores this fill's coverage.
    thread_idx: u8,
    /// Origin of the viewport this fill was bucketed into.
    ///
    /// See the comment in `CommandBucketer.bucketCommands` upstream: indexed
    /// paints are sampled relative to this origin because filter layers are
    /// anchored at `(0, 0)`.
    origin: [2]u16,
};

/// Attributes for a layer fill.
pub const LayerFillAttrs = struct {
    /// The blend mode used when compositing the layer.
    blend_mode: BlendMode,
    /// The layer opacity in `[0, 1]`.
    opacity: f32,
    /// An optional mask applied to the layer.
    mask: ?*const Mask,
    /// Monotonically increasing draw ID (starts at 1).
    draw_id: u32,
    /// In case there is any alpha associated with the layer command, this
    /// stores the index of the thread that stores the alpha.
    thread_idx: u8,
};

test "paint_fill_round_trip" {
    const fill = PaintFill.new(Span.new(4, 8), null, 3);
    try std.testing.expectEqual(Span.new(4, 8), fill.span);
    try std.testing.expectEqual(@as(?u32, null), fill.alphaIdx());
    try std.testing.expectEqual(@as(u32, 3), fill.attrs_idx);

    const masked = PaintFill.new(Span.new(0, 4), 42, 0);
    try std.testing.expectEqual(@as(?u32, 42), masked.alphaIdx());
}

test "depth_fill_span" {
    const fill = DepthFill.new(depth.BucketRange.new(1, 3), 7);
    try std.testing.expectEqual(depth.BucketRange.new(1, 3), fill.bucketRange());
    try std.testing.expectEqual(Span.new(128, 256), fill.span());
    try std.testing.expectEqual(@as(u32, 7), fill.attrs_idx);
}

test "layer_fill_round_trip" {
    const fill = LayerFill.new(Span.new(2, 2), 5, 1);
    try std.testing.expectEqual(Span.new(2, 2), fill.span);
    try std.testing.expectEqual(@as(?u32, 5), fill.alphaIdx());
    try std.testing.expectEqual(@as(u32, 1), fill.attrs_idx);
}

test "render_cmd_variants" {
    const paint = RenderCmd{ .paint_fill = PaintFill.new(Span.new(0, 4), null, 0) };
    const push = RenderCmd{ .push_buf = Span.new(0, 4) };
    const pop = RenderCmd{ .pop_buf = {} };
    const layer = RenderCmd{ .layer_fill = LayerFill.new(Span.new(0, 4), null, 0) };

    try std.testing.expect(std.meta.activeTag(paint) == .paint_fill);
    try std.testing.expectEqual(@as(?Span, Span.new(0, 4)), push.push_buf);
    try std.testing.expect(std.meta.activeTag(pop) == .pop_buf);
    try std.testing.expect(std.meta.activeTag(layer) == .layer_fill);
}
