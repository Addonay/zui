//! Port of vello_common filter/mod.rs and filter/{flood,gaussian_blur,
//! offset,drop_shadow}.rs (Apache-2.0 OR MIT).
//!
//! Common filter helper functions: the render-facing representation of a
//! `Filter` (`PreparedFilter` plus the `Flood`/`GaussianBlur`/`Offset`/
//! `DropShadow` payloads), the per-layer filter metadata (`FilterData`), and
//! the filter-layer placement math (`FilterLayerPlacement`). The render-time
//! algorithms live in `cpu/filter.zig`.
//!
//! Ownership/allocator note: `FilterData` owns its `Filter` (and therefore the
//! shared filter graph); `deinit` releases it with the passed allocator. The
//! prepared-filter payloads are plain values; only upstream's
//! `DecimationSizer` grows a vector, which this port replaces with a
//! fixed-capacity stack (the decimation count is bounded for every finite f32
//! variance).

const std = @import("std");
const kurbo = @import("../kurbo/root.zig");
const peniko = @import("../peniko/root.zig");
const geometry = @import("geometry.zig");
const math = @import("math.zig");
const util = @import("util.zig");
const filter_effects = @import("filter_effects.zig");

const EdgeMode = filter_effects.EdgeMode;
const Filter = filter_effects.Filter;
const PaddingU16 = geometry.PaddingU16;
const RectU16 = geometry.RectU16;

/// Maximum size of the gaussian kernel (must be odd and equal to or smaller
/// than `u8::MAX`); `MAX_KERNEL_SIZE` upstream.
pub const MAX_KERNEL_SIZE: usize = 13;

comptime {
    if (MAX_KERNEL_SIZE % 2 == 0) @compileError("MAX_KERNEL_SIZE must be odd");
    if (MAX_KERNEL_SIZE > std.math.maxInt(u8)) {
        @compileError("MAX_KERNEL_SIZE must be less than or equal to u8::MAX");
    }
}

/// A flood filter (`filter/flood.rs`).
pub const Flood = struct {
    /// The flood color.
    color: peniko.AlphaColor(peniko.Srgb),

    /// Create a new flood filter with the specified color.
    pub fn new(color: peniko.AlphaColor(peniko.Srgb)) Flood {
        return .{ .color = color };
    }
};

/// A gaussian blur (`filter/gaussian_blur.rs`).
pub const GaussianBlur = struct {
    /// The standard deviation.
    std_deviation: f32,
    /// Number of 2x decimation levels to use (0 means no decimation, direct
    /// convolution).
    n_decimations: usize,
    /// Pre-computed Gaussian kernel weights for the reduced blur. Only the
    /// first `kernel_size` elements are valid.
    kernel: [MAX_KERNEL_SIZE]f32,
    /// Actual length of the kernel (rest is padding up to `MAX_KERNEL_SIZE`).
    kernel_size: u8,
    /// Edge mode for handling out-of-bounds sampling.
    edge_mode: EdgeMode,

    /// Create a new gaussian blur with the specified standard deviation.
    pub fn new(std_deviation: f32, edge_mode: EdgeMode) GaussianBlur {
        const plan = planDecimatedBlur(std_deviation);
        return .{
            .std_deviation = std_deviation,
            .edge_mode = edge_mode,
            .n_decimations = plan.n_decimations,
            .kernel = plan.kernel,
            .kernel_size = plan.kernel_size,
        };
    }
};

/// The precomputed blur execution plan (upstream's tuple return).
pub const BlurPlan = struct {
    /// Number of 2x downsampling steps to perform (per axis).
    n_decimations: usize,
    /// Pre-computed Gaussian kernel weights (fixed-size array).
    kernel: [MAX_KERNEL_SIZE]f32,
    /// Actual length of the kernel (rest is zero-padded).
    kernel_size: u8,
};

/// Compute the blur execution plan based on standard deviation.
pub fn planDecimatedBlur(std_deviation: f32) BlurPlan {
    if (std_deviation <= 0.0) {
        // Invalid standard deviation, return identity kernel (no blur).
        var kernel: [MAX_KERNEL_SIZE]f32 = @splat(0.0);
        kernel[0] = 1.0;
        return .{ .n_decimations = 0, .kernel = kernel, .kernel_size = 1 };
    }

    // Variance (sigma^2) is additive: applying two blurs sequentially adds
    // their variances together. Each decimation level blurs the image twice
    // over the full round trip (0.75 variance for the [1,3,3,1]/8 downscale
    // plus 0.75 for the matching upscale reconstruction), and the 2x
    // downsampling rescales the remaining variance by 0.25.
    const variance = std_deviation * std_deviation;
    var n_decimations: usize = 0;
    var remaining_variance = variance;

    while (remaining_variance > 4.0) {
        remaining_variance = (remaining_variance - 1.5) * 0.25;
        n_decimations += 1;
    }

    const remaining_sigma = @sqrt(remaining_variance);
    const kernel = computeGaussianKernel(remaining_sigma);

    return .{
        .n_decimations = n_decimations,
        .kernel = kernel.kernel,
        .kernel_size = kernel.kernel_size,
    };
}

/// A computed 1D gaussian kernel (upstream's tuple return).
pub const GaussianKernel = struct {
    /// The normalized weights; only the first `kernel_size` are valid.
    kernel: [MAX_KERNEL_SIZE]f32,
    /// `2 * radius + 1`, clamped to `MAX_KERNEL_SIZE`.
    kernel_size: u8,
};

/// Compute 1D Gaussian kernel weights for separable convolution.
///
/// Uses the standard Gaussian formula `G(x) = exp(-x^2 / (2*sigma^2))`,
/// normalized to sum to 1.
pub fn computeGaussianKernel(std_deviation: f32) GaussianKernel {
    // Use radius = 3 sigma to capture 99.7% of the Gaussian distribution.
    const radius: usize = @intFromFloat(@ceil(3.0 * std_deviation));
    const kernel_size_usize = @min(1 + radius * 2, MAX_KERNEL_SIZE);
    const kernel_size: u8 = @intCast(kernel_size_usize);

    var kernel: [MAX_KERNEL_SIZE]f32 = @splat(0.0);
    const gaussian_denominator = 2.0 * std_deviation * std_deviation;
    var sum: f32 = 0.0;
    const kernel_center: f32 = @floatFromInt(kernel_size / 2);
    for (0..kernel_size_usize) |i| {
        // Distance from center (0 at center, increases outward).
        const x = @as(f32, @floatFromInt(i)) - kernel_center;
        // adapt: upstream calls `E.powf(y)` (libm `powf`); `@exp` is the
        // natural single-precision exponential and the kernel is normalized
        // afterwards, so the difference is limited to sub-ULP noise.
        kernel[i] = @exp(-x * x / gaussian_denominator);
        sum += kernel[i];
    }

    // Normalize weights to sum to 1.0.
    const scale = 1.0 / sum;
    for (0..kernel_size_usize) |i| {
        kernel[i] *= scale;
    }

    return .{ .kernel = kernel, .kernel_size = kernel_size };
}

/// Tracks dimensions through a chain of downscale/upscale operations
/// (`DecimationSizer`).
///
/// Upstream uses an unbounded `Vec`; this port uses a fixed-capacity stack.
/// For every finite f32 variance the plan performs fewer than 128
/// decimations, so the capacity is never exceeded; pushes beyond it are a
/// bug in `planDecimatedBlur` and trap.
pub const DecimationSizer = struct {
    width: u16,
    height: u16,
    /// Saved `(width, height)` pairs, oldest first.
    dim_stack: [128][2]u16 = undefined,
    /// Number of valid entries in `dim_stack`.
    dim_stack_len: usize = 0,

    /// Create a new sizer with the given initial dimensions.
    pub fn init(width: u16, height: u16) DecimationSizer {
        return .{ .width = width, .height = height };
    }

    /// Reset the sizer so it can be reused.
    pub fn reset(self: *DecimationSizer, width: u16, height: u16) void {
        self.width = width;
        self.height = height;
        self.dim_stack_len = 0;
    }

    /// Returns the current logical dimensions.
    pub fn current(self: *const DecimationSizer) [2]u16 {
        return .{ self.width, self.height };
    }

    /// Apply a new downscale operation.
    pub fn downscale(self: *DecimationSizer) [2]u16 {
        std.debug.assert(self.dim_stack_len < self.dim_stack.len);
        self.dim_stack[self.dim_stack_len] = .{ self.width, self.height };
        self.dim_stack_len += 1;
        self.width = divCeil2(self.width);
        self.height = divCeil2(self.height);
        return .{ self.width, self.height };
    }

    /// Apply a new upscale operation.
    pub fn upscale(self: *DecimationSizer) [2]u16 {
        std.debug.assert(self.dim_stack_len > 0);
        self.dim_stack_len -= 1;
        const target = self.dim_stack[self.dim_stack_len];
        // Clamp because upscale can exceed the target on odd dimensions
        // (e.g. 5 -> 3 -> 6 > 5).
        self.width = @min(self.width *| 2, target[0]);
        self.height = @min(self.height *| 2, target[1]);
        return .{ self.width, self.height };
    }

    fn divCeil2(value: u16) u16 {
        if (value % 2 == 0) return value / 2;
        return value / 2 + 1;
    }
};

/// A translation/shift filter (`filter/offset.rs`).
pub const Offset = struct {
    /// The x-offset that should be applied.
    dx: f32,
    /// The y-offset that should be applied.
    dy: f32,

    /// Create a new offset filter.
    pub fn new(dx: f32, dy: f32) Offset {
        return .{ .dx = dx, .dy = dy };
    }
};

/// A drop shadow filter (`filter/drop_shadow.rs`).
pub const DropShadow = struct {
    /// The x-offset of the shadow.
    dx: f32,
    /// The y-offset of the shadow.
    dy: f32,
    /// The color of the shadow.
    color: peniko.AlphaColor(peniko.Srgb),
    /// Standard deviation for the blur (for reference/debugging).
    std_deviation: f32,
    /// Edge mode for blur sampling.
    edge_mode: EdgeMode,
    /// Whether to composite the original input over the colored shadow.
    composite_original: bool,
    /// Number of 2x decimation levels to use (0 means direct convolution).
    n_decimations: usize,
    /// Pre-computed Gaussian kernel weights for the reduced blur.
    kernel: [MAX_KERNEL_SIZE]f32,
    /// Actual length of the kernel (kernel is padded to `MAX_KERNEL_SIZE`).
    kernel_size: u8,

    /// Create a new drop shadow filter with the specified parameters.
    pub fn new(
        dx: f32,
        dy: f32,
        std_deviation: f32,
        edge_mode: EdgeMode,
        color: peniko.AlphaColor(peniko.Srgb),
    ) DropShadow {
        return newImpl(dx, dy, std_deviation, edge_mode, color, true);
    }

    /// Create a new shadow-only drop shadow with the specified parameters.
    pub fn newShadowOnly(
        dx: f32,
        dy: f32,
        std_deviation: f32,
        edge_mode: EdgeMode,
        color: peniko.AlphaColor(peniko.Srgb),
    ) DropShadow {
        return newImpl(dx, dy, std_deviation, edge_mode, color, false);
    }

    fn newImpl(
        dx: f32,
        dy: f32,
        std_deviation: f32,
        edge_mode: EdgeMode,
        color: peniko.AlphaColor(peniko.Srgb),
        composite_original: bool,
    ) DropShadow {
        const plan = planDecimatedBlur(std_deviation);
        return .{
            .dx = dx,
            .dy = dy,
            .color = color,
            .std_deviation = std_deviation,
            .edge_mode = edge_mode,
            .composite_original = composite_original,
            .n_decimations = plan.n_decimations,
            .kernel = plan.kernel,
            .kernel_size = plan.kernel_size,
        };
    }
};

/// Scale a blur's standard deviation uniformly based on the transformation.
///
/// Extracts the scale factors from the transformation matrix using SVD and
/// averages them to get a uniform scale factor for the blur radius.
pub fn transformBlurParams(std_deviation: f32, transform: kurbo.Affine) f32 {
    const scales = util.extractScales(transform);
    const uniform_scale = (scales[0] + scales[1]) / 2.0;
    // TODO (upstream): support separate std_deviation for x and y axes to
    // handle non-uniform scaling.
    return std_deviation * uniform_scale;
}

/// Transform a drop shadow's offset and standard deviation using the affine
/// transformation (`transform_shadow_params`).
pub fn transformShadowParams(
    dx: f32,
    dy: f32,
    std_deviation: f32,
    transform: kurbo.Affine,
) [3]f32 {
    const scaled = transformOffsetParams(dx, dy, transform);
    const scaled_std_dev = transformBlurParams(std_deviation, transform);
    return .{ scaled[0], scaled[1], scaled_std_dev };
}

/// A filter that has been prepared for rendering.
pub const PreparedFilter = union(enum) {
    /// A flood filter.
    flood: Flood,
    /// A gaussian blur filter.
    gaussian_blur: GaussianBlur,
    /// An offset filter.
    offset: Offset,
    /// A drop shadow filter.
    drop_shadow: DropShadow,

    /// Errors from `new`.
    pub const NewError = error{Unsupported};

    /// Build a new prepared filter for the given transform.
    ///
    /// Upstream requires a single-primitive graph, then dispatches on the
    /// primitive. The multi-primitive panic and the unimplemented primitive
    /// dispatch map to `error.Unsupported`.
    pub fn new(filter: *const Filter, transform: kurbo.Affine) NewError!PreparedFilter {
        const graph = filter.graph.get();
        if (graph.primitives.items.len != 1) {
            // Upstream: `unimplemented!("Multi-primitive filter graphs are
            // not yet supported")`; typed error per the port error policy.
            return error.Unsupported;
        }

        return switch (graph.primitives.items[0]) {
            .flood => |flood| .{ .flood = Flood.new(flood.color) },
            .gaussian_blur => |blur| .{ .gaussian_blur = GaussianBlur.new(
                transformBlurParams(blur.std_deviation, transform),
                blur.edge_mode,
            ) },
            .drop_shadow => |shadow| blk: {
                const params = transformShadowParams(
                    shadow.dx,
                    shadow.dy,
                    shadow.std_deviation,
                    transform,
                );
                break :blk .{ .drop_shadow = DropShadow.new(
                    params[0],
                    params[1],
                    params[2],
                    shadow.edge_mode,
                    shadow.color,
                ) };
            },
            .drop_shadow_only => |shadow| blk: {
                const params = transformShadowParams(
                    shadow.dx,
                    shadow.dy,
                    shadow.std_deviation,
                    transform,
                );
                break :blk .{ .drop_shadow = DropShadow.newShadowOnly(
                    params[0],
                    params[1],
                    params[2],
                    shadow.edge_mode,
                    shadow.color,
                ) };
            },
            .offset => |offset| blk: {
                const scaled = transformOffsetParams(offset.dx, offset.dy, transform);
                break :blk .{ .offset = Offset.new(scaled[0], scaled[1]) };
            },
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

test "prepared filter dispatches each supported primitive" {
    const allocator = std.testing.allocator;

    const filter = try Filter.fromPrimitive(allocator, .{
        .gaussian_blur = .{ .std_deviation = 3.0, .edge_mode = .none },
    });
    defer filter.deinit(allocator);

    const prepared = try PreparedFilter.new(&filter, kurbo.Affine.IDENTITY);
    try std.testing.expectEqual(@as(f32, 3.0), prepared.gaussian_blur.std_deviation);
    try std.testing.expectEqual(@as(usize, 1), prepared.gaussian_blur.n_decimations);

    const flood_filter = try Filter.fromPrimitive(allocator, .{ .flood = .{
        .color = peniko.palette.css.RED,
    } });
    defer flood_filter.deinit(allocator);
    const flood = try PreparedFilter.new(&flood_filter, kurbo.Affine.IDENTITY);
    try std.testing.expectEqual(peniko.palette.css.RED, flood.flood.color);
}

test "prepared filter scales primitive parameters with the transform" {
    const allocator = std.testing.allocator;

    const blur_filter = try Filter.fromPrimitive(allocator, .{
        .gaussian_blur = .{ .std_deviation = 2.0, .edge_mode = .none },
    });
    defer blur_filter.deinit(allocator);
    const blurred = try PreparedFilter.new(&blur_filter, kurbo.Affine.scale(2.0));
    try std.testing.expectEqual(@as(f32, 4.0), blurred.gaussian_blur.std_deviation);

    const offset_filter = try Filter.fromPrimitive(allocator, .{
        .offset = .{ .dx = 1.0, .dy = -2.0 },
    });
    defer offset_filter.deinit(allocator);
    const offset = try PreparedFilter.new(
        &offset_filter,
        kurbo.Affine.new(.{ 2.0, 0.0, 0.0, 3.0, 10.0, 10.0 }),
    );
    try std.testing.expectEqual(@as(f32, 2.0), offset.offset.dx);
    try std.testing.expectEqual(@as(f32, -6.0), offset.offset.dy);
}

test "prepared filter reports unsupported for multi-primitive graphs" {
    const allocator = std.testing.allocator;

    const filter = try Filter.fromPrimitive(allocator, .{
        .flood = .{ .color = peniko.palette.css.RED },
    });
    defer filter.deinit(allocator);

    // Mutate the (uniquely owned) shared graph to hold two primitives.
    _ = try filter.graph.get().add(allocator, .{
        .gaussian_blur = .{ .std_deviation = 1.0, .edge_mode = .none },
    }, null);

    try std.testing.expectError(error.Unsupported, PreparedFilter.new(&filter, kurbo.Affine.IDENTITY));
}

test "prepared filter reports unsupported for unimplemented primitives" {
    const allocator = std.testing.allocator;

    const filter = try Filter.fromPrimitive(allocator, .{ .tile = {} });
    defer filter.deinit(allocator);

    try std.testing.expectError(error.Unsupported, PreparedFilter.new(&filter, kurbo.Affine.IDENTITY));
}

// Ported from upstream `vello_common/src/filter/gaussian_blur.rs` tests.

test "gaussian kernel small sigma" {
    const kernel = computeGaussianKernel(1.0);
    // For sigma=1.0, radius = ceil(3.0) = 3, size = 2*3+1 = 7.
    try std.testing.expectEqual(@as(u8, 7), kernel.kernel_size);

    for (0..kernel.kernel_size / 2) |i| {
        try std.testing.expect(@abs(kernel.kernel[i] - kernel.kernel[kernel.kernel_size - 1 - i]) < 1e-6);
    }

    var sum: f32 = 0.0;
    for (kernel.kernel[0..kernel.kernel_size]) |weight| sum += weight;
    try std.testing.expect(@abs(sum - 1.0) < 1e-6);

    const center_idx = kernel.kernel_size / 2;
    for (0..kernel.kernel_size) |i| {
        if (i != center_idx) {
            try std.testing.expect(kernel.kernel[center_idx] >= kernel.kernel[i]);
        }
    }
}

test "gaussian kernel very small sigma" {
    const kernel = computeGaussianKernel(0.1);
    try std.testing.expectEqual(@as(u8, 3), kernel.kernel_size);
    var sum: f32 = 0.0;
    for (kernel.kernel[0..kernel.kernel_size]) |weight| sum += weight;
    try std.testing.expect(@abs(sum - 1.0) < 1e-6);
    try std.testing.expect(kernel.kernel[1] > 0.9);
}

test "gaussian kernel fractional sigma" {
    const kernel = computeGaussianKernel(0.5);
    try std.testing.expectEqual(@as(u8, 5), kernel.kernel_size);
    var sum: f32 = 0.0;
    for (kernel.kernel[0..kernel.kernel_size]) |weight| sum += weight;
    try std.testing.expect(@abs(sum - 1.0) < 1e-6);
}

test "decimation plan boundaries" {
    try std.testing.expectEqual(@as(usize, 0), planDecimatedBlur(1.0).n_decimations);
    try std.testing.expectEqual(@as(usize, 2), planDecimatedBlur(5.0).n_decimations);
    try std.testing.expectEqual(@as(usize, 0), planDecimatedBlur(2.0).n_decimations);

    const negative = planDecimatedBlur(-1.0);
    try std.testing.expectEqual(@as(usize, 0), negative.n_decimations);
    try std.testing.expectEqual(@as(u8, 1), negative.kernel_size);
    try std.testing.expectEqual(@as(f32, 1.0), negative.kernel[0]);
}

test "decimation plan keeps large sigma kernels within the maximum size" {
    const plan = planDecimatedBlur(100.0);
    try std.testing.expectEqual(@as(u8, 11), plan.kernel_size);
    try std.testing.expectEqual(@as(usize, 6), plan.n_decimations);

    const kernel = computeGaussianKernel(100.0);
    try std.testing.expectEqual(@as(u8, MAX_KERNEL_SIZE), kernel.kernel_size);
    var sum: f32 = 0.0;
    for (kernel.kernel[0..kernel.kernel_size]) |weight| sum += weight;
    try std.testing.expect(@abs(sum - 1.0) < 1e-6);
}

test "decimation sizer tracks even and odd dimensions" {
    var sizer = DecimationSizer.init(8, 8);
    try std.testing.expectEqual([2]u16{ 8, 8 }, sizer.current());
    try std.testing.expectEqual([2]u16{ 4, 4 }, sizer.downscale());
    try std.testing.expectEqual([2]u16{ 2, 2 }, sizer.downscale());
    try std.testing.expectEqual([2]u16{ 4, 4 }, sizer.upscale());
    try std.testing.expectEqual([2]u16{ 8, 8 }, sizer.upscale());

    sizer.reset(5, 7);
    try std.testing.expectEqual([2]u16{ 3, 4 }, sizer.downscale());
    try std.testing.expectEqual([2]u16{ 2, 2 }, sizer.downscale());
    try std.testing.expectEqual([2]u16{ 3, 4 }, sizer.upscale());
    try std.testing.expectEqual([2]u16{ 5, 7 }, sizer.upscale());
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
