//! Port of vello_common filter/mod.rs (Apache-2.0 OR MIT).
//!
//! Common filter helper functions: the render-facing representation of a
//! `Filter` (`PreparedFilter`), the per-layer filter metadata (`FilterData`),
//! and the filter-layer placement math (`FilterLayerPlacement`).
//!
//! Not ported yet: the render-time submodules `filter/flood.rs`,
//! `filter/gaussian_blur.rs`, `filter/offset.rs`, and
//! `filter/drop_shadow.rs`. `PreparedFilter.new` therefore returns
//! `error.Unsupported` for every primitive (upstream dispatches to
//! `Flood::new` / `GaussianBlur::new` / `Offset::new` / `DropShadow::new`)
//! instead of panicking with `unimplemented!`.
//!
//! Ownership/allocator note: `FilterData` owns its `Filter` (and therefore the
//! shared filter graph); `deinit` releases it with the passed allocator.
//! `FilterLayerPlacement` is plain geometry and never allocates.

const std = @import("std");
const kurbo = @import("../kurbo/root.zig");
const geometry = @import("geometry.zig");
const math = @import("math.zig");
const util = @import("util.zig");
const filter_effects = @import("filter_effects.zig");

const Filter = filter_effects.Filter;
const PaddingU16 = geometry.PaddingU16;
const RectU16 = geometry.RectU16;

/// A filter that has been prepared for rendering.
///
/// Upstream's payloads are `Flood`, `GaussianBlur`, `Offset`, and
/// `DropShadow` from the `filter/` submodules, which are not ported yet (see
/// the module docs). Until they land, the variants carry no payload and
/// `new` reports `error.Unsupported` for all of them.
pub const PreparedFilter = union(enum) {
    /// A flood filter (`filter/flood.rs`, not ported yet).
    flood,
    /// A gaussian blur filter (`filter/gaussian_blur.rs`, not ported yet).
    gaussian_blur,
    /// An offset filter (`filter/offset.rs`, not ported yet).
    offset,
    /// A drop shadow filter (`filter/drop_shadow.rs`, not ported yet).
    drop_shadow,

    /// Errors from `new`.
    pub const NewError = error{Unsupported};

    /// Build a new prepared filter for the given transform.
    ///
    /// Upstream requires a single-primitive graph, then dispatches on the
    /// primitive. Both the multi-primitive panic and the per-primitive
    /// dispatch targets (the deferred `filter/` submodules) map to
    /// `error.Unsupported`.
    pub fn new(filter: *const Filter, transform: kurbo.Affine) NewError!PreparedFilter {
        _ = transform;

        const graph = filter.graph.get();
        if (graph.primitives.items.len != 1) {
            // Upstream: `unimplemented!("Multi-primitive filter graphs ...")`.
            return error.Unsupported;
        }

        return switch (graph.primitives.items[0]) {
            // Would become `Flood::new` / `GaussianBlur::new` /
            // `Offset::new` / `DropShadow::new`; those payload types do not
            // exist yet.
            .flood,
            .gaussian_blur,
            .offset,
            .drop_shadow,
            .drop_shadow_only,
            => error.Unsupported,
            // Upstream: "Other filter primitives not yet implemented".
            else => error.Unsupported,
        };
    }
};

/// Metadata about a filter layer and how it should be composited back into
/// the parent layer.
pub const FilterLayerPlacement = struct {
    /// The conceptual bounding box of the pixmap that needs to be allocated to
    /// render a layer correctly, including the area affected by the filter.
    ///
    /// For example, if the filter layer contains a rect spanning (200, 200)
    /// to (300, 300) with a blur that has a radius exceeding the rectangle by
    /// 40 pixels on each side, the pixmap bbox will be (160, 160) to
    /// (340, 340).
    ///
    /// See the comments in `FilterLayerPlacement.new` for more information.
    pixmap_bbox: RectU16,
    /// Rectangle in the parent layer's coordinate space the filtered pixmap is
    /// composited into.
    ///
    /// See the comments in `FilterLayerPlacement.new` for more information.
    dest_bbox: RectU16,
    /// Source x offset used when sampling from the filter pixmap.
    ///
    /// See the comments in `FilterLayerPlacement.new` for more information.
    src_x: u16,
    /// Source y offset used when sampling from the filter pixmap.
    ///
    /// See the comments in `FilterLayerPlacement.new` for more information.
    src_y: u16,

    /// The placement of an empty filter layer (upstream `pub(crate) EMPTY`).
    pub const EMPTY: FilterLayerPlacement = .{
        .pixmap_bbox = RectU16.ZERO,
        .dest_bbox = RectU16.ZERO,
        .src_x = 0,
        .src_y = 0,
    };

    /// Compute the placement of a filter layer from the tight bounding box of
    /// all its strips and the precomputed filter data.
    pub fn new(bbox: RectU16, filter_plan: *const FilterData) FilterLayerPlacement {
        if (bbox.isEmpty()) return EMPTY;

        // `bbox` is the tight bounding box across all strips in the filter
        // layer. We now need to expand it by the filter padding to know how
        // large of a pixmap we actually need to allocate. Also, as mentioned
        // in `FilterLayerPlacement.new` upstream, we need to ensure the pixmap
        // itself is also a multiple of the tile width / tile height.
        const expanded = bbox.expand(filter_plan.filter_padding);
        const pixmap_bbox = util.RectExt.snapToTileCoordinates(expanded);

        // Remember that in `RenderContext`, we eagerly shift everything drawn
        // by `source_shift` to conservatively ensure that everything that
        // might be needed for the filter is in the viewport area. Therefore,
        // when compositing the filter layer back, we need to undo that shift.
        const shift = filter_plan.sourceShift();
        // For example, if `shift_x` is 20 and `pixmap_bbox.x0` is 4, shifting
        // the pixmap back would place its left edge at -16. Since we start
        // compositing at x=0, we need to skip the first 16 pixels inside the
        // cropped pixmap (`src_x = 20 - 4`). If `pixmap_bbox.x0` is already
        // >= `shift_x`, nothing is clipped and `src_x` is 0.
        const src_x = shift[0] -| pixmap_bbox.x0;
        const src_y = shift[1] -| pixmap_bbox.y0;
        const dest_bbox = pixmap_bbox.relativeToOrigin(shift);

        return .{
            .pixmap_bbox = pixmap_bbox,
            .dest_bbox = dest_bbox,
            .src_x = src_x,
            .src_y = src_y,
        };
    }

    /// Return the source origin of the filter layer.
    pub fn srcOrigin(self: FilterLayerPlacement) [2]u16 {
        return .{ self.src_x, self.src_y };
    }
};

/// Precomputed data for a filter layer.
pub const FilterData = struct {
    /// The underlying filter.
    filter: Filter,
    /// The transform that was in place when the filter layer was invoked.
    transform: kurbo.Affine,
    /// Padding that needs to be added for the area where the filter is
    /// applied.
    ///
    /// See `Filter.filterExpansion`.
    filter_padding: PaddingU16,
    /// Padding that needs to be added to the source region for correct filter
    /// application.
    ///
    /// See `Filter.sourceExpansion`.
    source_padding: PaddingU16,

    /// Create precomputed data for a filter and transform.
    ///
    /// Takes ownership of `filter`; do not release the handle after this call.
    pub fn new(filter: Filter, transform: kurbo.Affine) FilterData {
        const source_padding = snappedPadding(filter.sourceExpansion(transform));
        const filter_padding = snappedPadding(filter.filterExpansion(transform));

        return .{
            .filter = filter,
            .transform = transform,
            .filter_padding = filter_padding,
            .source_padding = source_padding,
        };
    }

    /// Release the owned filter.
    pub fn deinit(self: *FilterData, allocator: std.mem.Allocator) void {
        self.filter.deinit(allocator);
        self.* = undefined;
    }

    /// By how much to shift all rendered contents to ensure that all rendered
    /// contents are visible in the viewport `[0, 0, width, height]`.
    pub fn sourceShift(self: FilterData) [2]u16 {
        return .{ self.source_padding.left, self.source_padding.top };
    }
};

fn snappedPadding(expansion: kurbo.Rect) PaddingU16 {
    std.debug.assert(
        expansion.x0 <= 0.0 and
            expansion.y0 <= 0.0 and
            expansion.x1 >= 0.0 and
            expansion.y1 >= 0.0,
    );

    // TODO (upstream): We technically shouldn't need to snap here.
    // `source_padding` is only used to shift the contents when rendering into
    // the render context, and the final pixmap bbox (which is derived from
    // `filter_padding`) will be snapped separately. However, not snapping
    // here causes larger mismatches with Vello GPU since the size of the final
    // pixmap determines in which way we decimate for the gaussian blur filter.
    // Therefore, we keep this for compatibility.
    return PaddingU16.new(
        snapUpU16(-expansion.x0, util.TILE_WIDTH),
        snapUpU16(-expansion.y0, util.TILE_HEIGHT),
        snapUpU16(expansion.x1, util.TILE_WIDTH),
        snapUpU16(expansion.y1, util.TILE_HEIGHT),
    );
}

/// `math.snapUp` with the saturating `f64 as u16` cast that upstream relies
/// on.
fn snapUpU16(value: f64, step: u16) u16 {
    const snapped = math.snapUp(value, step);
    return @intFromFloat(std.math.clamp(snapped, 0.0, @as(f64, std.math.maxInt(u16))));
}

/// Transform an offset's dx/dy using the affine transformation's linear part.
///
/// Returns `{ scaled_dx, scaled_dy }` in device space.
///
/// Upstream-private; retained here because the deferred `filter/offset.rs`
/// and `filter/drop_shadow.rs` ports need it.
fn transformOffsetParams(dx: f32, dy: f32, transform: kurbo.Affine) [2]f32 {
    const offset = kurbo.Vec2.new(@floatCast(dx), @floatCast(dy));
    const coeffs = transform.asCoeffs();
    const transformed = kurbo.Vec2.new(
        coeffs[0] * offset.x + coeffs[2] * offset.y,
        coeffs[1] * offset.x + coeffs[3] * offset.y,
    );
    return .{ @floatCast(transformed.x), @floatCast(transformed.y) };
}

test "filter data snaps gaussian blur padding to tiles" {
    const allocator = std.testing.allocator;

    const filter = try Filter.fromPrimitive(allocator, .{
        .gaussian_blur = .{ .std_deviation = 3.0, .edge_mode = .none },
    });
    // `FilterData.new` takes ownership of `filter`.
    var data = FilterData.new(filter, kurbo.Affine.IDENTITY);
    defer data.deinit(allocator);

    // The expansion is 3 * sigma = 9 on each side, snapped up to 12 (tile 4).
    try std.testing.expectEqual(PaddingU16.new(12, 12, 12, 12), data.filter_padding);
    try std.testing.expectEqual(PaddingU16.new(12, 12, 12, 12), data.source_padding);
    try std.testing.expectEqual([2]u16{ 12, 12 }, data.sourceShift());

    const placement = FilterLayerPlacement.new(RectU16.new(20, 20, 60, 60), &data);
    try std.testing.expectEqual(RectU16.new(8, 8, 72, 72), placement.pixmap_bbox);
    try std.testing.expectEqual(RectU16.new(0, 0, 60, 60), placement.dest_bbox);
    try std.testing.expectEqual([2]u16{ 4, 4 }, placement.srcOrigin());
}

test "filter layer placement starts at the origin when the pixmap already covers the shift" {
    const allocator = std.testing.allocator;

    const filter = try Filter.fromPrimitive(allocator, .{
        .gaussian_blur = .{ .std_deviation = 3.0, .edge_mode = .none },
    });
    var data = FilterData.new(filter, kurbo.Affine.IDENTITY);
    defer data.deinit(allocator);

    const placement = FilterLayerPlacement.new(RectU16.new(40, 0, 60, 20), &data);
    // bbox.expand(12) = (28, 0, 72, 32), already tile-aligned (the top is
    // clamped at 0).
    try std.testing.expectEqual(RectU16.new(28, 0, 72, 32), placement.pixmap_bbox);
    // 12 -| 28 saturates to 0; the top needs no clipping after the clamp.
    try std.testing.expectEqual([2]u16{ 0, 12 }, placement.srcOrigin());
    try std.testing.expectEqual(RectU16.new(16, 0, 60, 20), placement.dest_bbox);
}

test "filter layer placement of an empty bbox is EMPTY" {
    const allocator = std.testing.allocator;

    const filter = try Filter.fromPrimitive(allocator, .{
        .gaussian_blur = .{ .std_deviation = 3.0, .edge_mode = .none },
    });
    var data = FilterData.new(filter, kurbo.Affine.IDENTITY);
    defer data.deinit(allocator);

    const placement = FilterLayerPlacement.new(RectU16.new(10, 10, 10, 10), &data);
    try std.testing.expectEqual(FilterLayerPlacement.EMPTY, placement);
}

test "filter data uses separate filter and source padding for offsets" {
    const allocator = std.testing.allocator;

    const filter = try Filter.fromPrimitive(allocator, .{
        .offset = .{ .dx = 2.5, .dy = -3.0 },
    });
    var data = FilterData.new(filter, kurbo.Affine.IDENTITY);
    defer data.deinit(allocator);

    // Filter expansion (0, -3, 2.5, 0), snapped per side: (0, 4, 4, 0).
    try std.testing.expectEqual(PaddingU16.new(0, 4, 4, 0), data.filter_padding);
    // Source expansion (-2.5, 0, 0, 3), snapped per side: (4, 0, 0, 4).
    try std.testing.expectEqual(PaddingU16.new(4, 0, 0, 4), data.source_padding);
    try std.testing.expectEqual([2]u16{ 4, 0 }, data.sourceShift());
}

test "filter data scales blur padding with the transform" {
    const allocator = std.testing.allocator;

    const filter = try Filter.fromPrimitive(allocator, .{
        .gaussian_blur = .{ .std_deviation = 3.0, .edge_mode = .none },
    });
    var data = FilterData.new(filter, kurbo.Affine.scale(2.0));
    defer data.deinit(allocator);

    // 3 * sigma = 9 in user space, scaled by 2 => 18, snapped up to 20.
    try std.testing.expectEqual(PaddingU16.new(20, 20, 20, 20), data.filter_padding);
    try std.testing.expectEqual(PaddingU16.new(20, 20, 20, 20), data.source_padding);
}

test "prepared filter reports unsupported until the submodules land" {
    const allocator = std.testing.allocator;

    const filter = try Filter.fromPrimitive(allocator, .{
        .gaussian_blur = .{ .std_deviation = 1.0, .edge_mode = .none },
    });
    defer filter.deinit(allocator);

    try std.testing.expectError(error.Unsupported, PreparedFilter.new(&filter, kurbo.Affine.IDENTITY));
}

test "transform offset params applies the linear part" {
    // Scale (2, 3) with a translation that must be ignored.
    const transform = kurbo.Affine.new(.{ 2.0, 0.0, 0.0, 3.0, 10.0, 10.0 });
    try std.testing.expectEqual(
        [2]f32{ 4.0, -9.0 },
        transformOffsetParams(2.0, -3.0, transform),
    );

    // Rotation by 90 degrees maps (1, 0) to (0, 1).
    const rotated = transformOffsetParams(1.0, 0.0, kurbo.Affine.rotate(std.math.pi / 2.0));
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), rotated[0], 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), rotated[1], 1e-6);
}
