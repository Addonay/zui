//! Port of vello_cpu src/record.rs (Apache-2.0 OR MIT).
//!
//! `RecordedFill` is one recorded draw: a range of strips plus the paint,
//! blend mode, and optional mask that apply to it.
//!
//! Ownership/lifetime note: `mask` is an owned, reference-counted handle
//! (upstream stores an owned `Arc<Mask>`), so a recording stays valid even if
//! the render context later replaces or resets its current mask. The command
//! recorder releases it on `reset`/`deinit` through this type's `deinit`.
//!
//! `Drawable` (upstream `vello_common::record::Drawable`) has two methods:
//! `bbox(strips)` and `blend_mode()`. Both are implemented here directly on
//! `RecordedFill`; `common/record.zig` consumes them through comptime
//! duck typing (see `Drawable.assertImpl` there).

const std = @import("std");
const geometry = @import("../common/geometry.zig");
const peniko = @import("../peniko/root.zig");
const paint_mod = @import("../common/paint.zig");
const mask_mod = @import("../common/mask.zig");
const strip_mod = @import("../common/strip.zig");

const Paint = paint_mod.Paint;
const Mask = mask_mod.Mask;
const BlendMode = peniko.BlendMode;
const RectU16 = geometry.RectU16;
const Strip = strip_mod.Strip;

/// A half-open range of indices into the shared strip buffer.
pub const StripRange = struct {
    /// First strip index (inclusive).
    start: usize,
    /// Last strip index (exclusive).
    end: usize,
};

/// A recorded fill command.
pub const RecordedFill = struct {
    /// Index of the thread-local strip storage that owns these strips.
    thread_idx: u8,
    /// The range of strips this draw covers.
    strip_range: StripRange,
    /// The paint to apply.
    paint: Paint,
    /// The blend mode applied directly by this draw.
    blend_mode: BlendMode,
    /// An optional owned mask applied to this draw.
    mask: ?Mask,

    /// Create a new recorded fill.
    pub fn new(
        thread_idx: u8,
        strip_range: StripRange,
        paint: Paint,
        blend_mode: BlendMode,
        mask: ?Mask,
    ) RecordedFill {
        return .{
            .thread_idx = thread_idx,
            .strip_range = strip_range,
            .paint = paint,
            .blend_mode = blend_mode,
            .mask = mask,
        };
    }

    /// Upstream `Drawable::bbox`: the bounding box of the fill's strips.
    ///
    /// `strips` must be the slice the recorder was given when this fill was
    /// pushed (see `pushDraw`); the range indices are only meaningful against
    /// that slice.
    pub fn bbox(_: *const RecordedFill, strips: []const Strip) ?RectU16 {
        return strip_mod.stripBbox(strips);
    }

    /// Upstream `Drawable::blend_mode`.
    pub fn blendMode(self: *const RecordedFill) ?*const BlendMode {
        return &self.blend_mode;
    }

    /// Release the owned mask handle. Called by the command recorder on
    /// `reset`/`deinit` (`Drawable` resources are otherwise plain values).
    pub fn deinit(self: *RecordedFill, allocator: std.mem.Allocator) void {
        if (self.mask) |mask| mask.deinit(allocator);
        self.mask = null;
    }
};

test "recorded_fill_fields_and_blend_mode" {
    const fill = RecordedFill.new(
        2,
        .{ .start = 3, .end = 9 },
        Paint.fromAlphaColor(peniko.Color.BLACK),
        BlendMode.from(peniko.Mix.multiply),
        null,
    );

    try std.testing.expectEqual(@as(u8, 2), fill.thread_idx);
    try std.testing.expectEqual(@as(usize, 3), fill.strip_range.start);
    try std.testing.expectEqual(@as(usize, 9), fill.strip_range.end);
    try std.testing.expectEqual(peniko.Mix.multiply, fill.blendMode().?.mix);
    try std.testing.expectEqual(peniko.Compose.src_over, fill.blendMode().?.compose);
    try std.testing.expectEqual(@as(?Mask, null), fill.mask);
}

test "recorded_fill_bbox_delegates_to_strip_bbox" {
    const strips = [_]Strip{
        Strip.new(8, 4, 0, false),
        Strip.sentinel(4, 16),
    };
    const fill = RecordedFill.new(
        0,
        .{ .start = 0, .end = strips.len },
        Paint.fromAlphaColor(peniko.Color.BLACK),
        BlendMode.default,
        null,
    );

    try std.testing.expectEqual(
        @as(?RectU16, RectU16.new(8, 4, 12, 8)),
        fill.bbox(&strips),
    );

    const empty = [_]Strip{Strip.sentinel(0, 0)};
    try std.testing.expectEqual(@as(?RectU16, null), fill.bbox(&empty));
}
