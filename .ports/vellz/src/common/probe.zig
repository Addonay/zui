//! Port of `vello_common/src/probe.rs` (Apache-2.0 OR MIT).
//!
//! The probe renders a small grid exercising the renderer's core features and
//! compares the result against the pinned upstream reference image imported as
//! `tests/fixtures/upstream/probe.rgba`:
//!
//!     sha256 01c87c436d7b3cfaa357dfaad9259f57b4fdcb27a62da9658afb10056ee54bea
//!
//! Scene construction and comparison policy are transcribed from the pinned
//! upstream revision: all four channels, per-channel absolute tolerance 3,
//! with pixels where both alphas are zero treated as equal. The `Filter`
//! element keeps its upstream discriminant (bit 4 of the difference mask) but
//! is absent from `PROBE_ELEMENTS`, matching upstream's "temporarily disabled"
//! comment; drawing it fails with `error.Unsupported` instead of silently
//! skipping (filter layers are M2 and not implemented by the CPU port yet).
//!
//! `drawScene` is generic over the renderer (Zig's stand-in for upstream's
//! `ProbeRenderer` trait): it calls `setTransform`, `setPaint`, `fillPath`,
//! `fillRect`, `pushLayer`, `popLayer`, `setPaintTransform`, and
//! `resetPaintTransform` on `ctx`. It receives an `ImageSource` and consumes
//! it, exactly like upstream `draw_scene`.

const std = @import("std");
const kurbo = @import("../kurbo/root.zig");
const peniko = @import("../peniko/root.zig");
const paint_mod = @import("paint.zig");
const pixmap_mod = @import("pixmap.zig");
const shared_mod = @import("shared.zig");

const Pixmap = pixmap_mod.Pixmap;
const PaintType = paint_mod.PaintType;
const css = peniko.palette.css;

/// The pinned upstream reference image (`vello_common/assets/probe.rgba`),
/// imported byte-for-byte. See `tests/fixtures/upstream/README.md`.
///
/// The build adds `tests/fixtures/upstream/probe.rgba` to the `vellz` module
/// as the anonymous `probe_reference` import, because `@embedFile` may only
/// read inside the module's package path.
const REFERENCE_RGBA = @embedFile("probe_reference");

/// Number of elements laid out per grid row (upstream `ELEMENTS_PER_ROW`).
pub const ELEMENTS_PER_ROW: usize = 3;
/// Margin between grid cells (upstream `ELEMENT_MARGIN`).
pub const ELEMENT_MARGIN: f64 = 1.0;

const RECT_SIZE: f64 = 10.0;
const CIRCLE_RADIUS: f64 = 5.0;
const CIRCLE_CENTER_OFFSET_X: f64 = 1.5;
const IMAGE_SOURCE_SIZE: f64 = 5.0;
const PATH_TOLERANCE: f64 = 0.1;

/// The active elements used in the probe (upstream `PROBE_ELEMENTS`).
///
/// `ProbeFeature::Filter` is temporarily disabled upstream and therefore
/// absent here as well.
pub const PROBE_ELEMENTS: [8]ProbeFeature = .{
    .solid_rect,
    .alpha_blending,
    .gradient,
    .image_nearest,
    // Temporarily disabled upstream:
    // .filter,
    .image_bilinear,
    .opacity_layer,
    .blending,
    .transformed,
};

/// Per-channel absolute tolerance used when comparing probe pixels
/// (upstream `CHANNEL_TOLERANCE`).
pub const CHANNEL_TOLERANCE: u8 = 3;

/// A feature exercised by the renderer probe.
///
/// Each discriminant is the stable bit index used by
/// `ProbeStatistics.difference_mask`; existing discriminants must not be
/// changed when features are reordered, disabled, or added (upstream
/// `ProbeFeature`).
pub const ProbeFeature = enum(u8) {
    /// Drawing a solid rectangle.
    solid_rect = 0,
    /// Alpha blending overlapping shapes.
    alpha_blending = 1,
    /// Drawing a linear gradient.
    gradient = 2,
    /// Drawing an image with nearest-neighbor sampling.
    image_nearest = 3,
    /// Applying a filter effect.
    filter = 4,
    /// Drawing an image with bilinear sampling.
    image_bilinear = 5,
    /// Drawing within a layer with reduced opacity.
    opacity_layer = 6,
    /// Drawing within a layer with a blend mode.
    blending = 7,
    /// Drawing with a non-identity transform.
    transformed = 8,

    /// The feature's cell bounds including its two-element margin, used by the
    /// grid layout (upstream `ProbeFeature::bounds`).
    pub fn bounds(self: ProbeFeature) [2]f64 {
        const size: [2]f64 = switch (self) {
            .solid_rect,
            .gradient,
            .image_nearest,
            .image_bilinear,
            .filter,
            .opacity_layer,
            => .{ RECT_SIZE, RECT_SIZE },
            .transformed => .{
                RECT_SIZE * @sqrt(2.0),
                RECT_SIZE * @sqrt(2.0),
            },
            .alpha_blending, .blending => .{
                CIRCLE_RADIUS * 2.0 + CIRCLE_CENTER_OFFSET_X * 2.0,
                CIRCLE_RADIUS * 2.0,
            },
        };
        return .{
            size[0] + ELEMENT_MARGIN * 2.0,
            size[1] + ELEMENT_MARGIN * 2.0,
        };
    }
};

/// Summary of the differences between the expected and actual probe images
/// (upstream `ProbeStatistics`).
pub const ProbeStatistics = struct {
    /// Number of active features exercised by the probe.
    element_count: u8 = 0,
    /// Width and height of the actual probe image.
    actual_size: [2]u16 = .{ 0, 0 },
    /// Number of pixels whose channels differ by more than the probe
    /// tolerance.
    different_pixel_count: u32 = 0,
    /// Largest absolute difference between corresponding red, green, blue, and
    /// alpha channels.
    max_channel_discrepancy: [4]u8 = .{ 0, 0, 0, 0 },
    /// Bitmask identifying probe features containing a pixel outside the probe
    /// tolerance. Bit `n` corresponds to the `ProbeFeature` discriminant `n`.
    difference_mask: u32 = 0,

    /// Returns whether `feature` contained a pixel outside the probe
    /// tolerance.
    pub fn differs(self: ProbeStatistics, feature: ProbeFeature) bool {
        return self.difference_mask & featureBit(feature) != 0;
    }
};

fn featureBit(feature: ProbeFeature) u32 {
    return @as(u32, 1) << @as(u5, @intCast(@backingInt(feature)));
}

/// A probe image stored as RGBA8 bytes.
///
/// `data` is borrowed: the caller keeps ownership of the allocation (or, for
/// the pinned reference, of the embedded constant).
pub const ProbeImage = struct {
    /// Width of the image in pixels.
    width: u16,
    /// Height of the image in pixels.
    height: u16,
    /// The image data as RGBA8 bytes.
    data: []const u8,

    /// Consume a pixmap and return its RGBA8 bytes un-premultiplied
    /// (upstream `ProbeImage::from_pixmap`).
    pub fn fromPixmap(allocator: std.mem.Allocator, pixmap: *Pixmap) std.mem.Allocator.Error!ProbeImage {
        const width = pixmap.width;
        const height = pixmap.height;
        const data = try pixmap.takeRgba8(allocator, .alpha);
        return .{ .width = width, .height = height, .data = data };
    }
};

/// Probe failure output (upstream `ProbeResult`).
pub const ProbeResult = struct {
    /// The expected probe image.
    expected: ProbeImage,
    /// The actual probe image.
    actual: ProbeImage,

    /// Return the statistics of the probe (upstream `ProbeResult::statistics`).
    pub fn statistics(self: ProbeResult) ProbeStatistics {
        const layout = GridLayout.fromElements(&PROBE_ELEMENTS);
        var result = ProbeStatistics{
            .element_count = PROBE_ELEMENTS.len,
            .actual_size = .{ self.actual.width, self.actual.height },
        };

        const pixel_count = @min(
            self.expected.data.len / 4,
            self.actual.data.len / 4,
        );
        var pixel_index: usize = 0;
        while (pixel_index < pixel_count) : (pixel_index += 1) {
            const expected = self.expected.data[pixel_index * 4 ..][0..4];
            const actual = self.actual.data[pixel_index * 4 ..][0..4];

            if (expected[3] != 0 or actual[3] != 0) {
                for (0..4) |channel| {
                    const difference = absDiff(expected[channel], actual[channel]);
                    result.max_channel_discrepancy[channel] =
                        @max(result.max_channel_discrepancy[channel], difference);
                }
            }

            if (!pixelsWithinTolerance(expected, actual, CHANNEL_TOLERANCE)) {
                result.different_pixel_count += 1;

                const cell_index = layout.cellIndexForPixel(pixel_index);
                if (cell_index < PROBE_ELEMENTS.len) {
                    result.difference_mask |= featureBit(PROBE_ELEMENTS[cell_index]);
                }
            }
        }

        return result;
    }
};

/// Result of running the renderer probe (upstream `Probe<E>`, minus the
/// render-error variant because Zig propagates render errors as errors).
pub const Probe = union(enum) {
    /// The probe matched the bundled reference image.
    success,
    /// The probe did not match the bundled reference image.
    mismatch: ProbeResult,

    /// Returns `true` when the probe matched the bundled reference image.
    pub fn isSuccess(self: Probe) bool {
        return self == .success;
    }
};

/// The bundled reference as a `ProbeImage` view.
pub fn referenceImage() ProbeImage {
    const size = canvasSize();
    return .{ .width = size[0], .height = size[1], .data = REFERENCE_RGBA };
}

/// Construct a new probe result by inspecting the provided image and comparing
/// it against the bundled reference output (upstream `Probe::from_actual`).
pub fn fromActual(actual: ProbeImage) Probe {
    const expected = referenceImage();
    const matches_reference = expected.width == actual.width and
        expected.height == actual.height and
        expected.data.len == actual.data.len and
        blk: {
            const pixel_count = expected.data.len / 4;
            var pixel_index: usize = 0;
            while (pixel_index < pixel_count) : (pixel_index += 1) {
                const expected_pixel = expected.data[pixel_index * 4 ..][0..4];
                const actual_pixel = actual.data[pixel_index * 4 ..][0..4];
                if (!pixelsWithinTolerance(
                    expected_pixel,
                    actual_pixel,
                    CHANNEL_TOLERANCE,
                )) break :blk false;
            }
            break :blk true;
        };

    if (matches_reference) return .success;
    return .{ .mismatch = .{ .expected = expected, .actual = actual } };
}

/// The statistics of comparing `actual` against the pinned reference, plus
/// whether the two buffers are byte-identical.
pub const ProbeComparison = struct {
    /// Per-pixel statistics under the upstream tolerance policy.
    statistics: ProbeStatistics,
    /// Whether every byte matched exactly (stronger than the tolerance
    /// policy; recorded so exactness is never lost in the tolerance).
    byte_exact: bool,

    /// Whether every pixel is within the upstream tolerance.
    pub fn passed(self: ProbeComparison) bool {
        return self.statistics.different_pixel_count == 0;
    }
};

/// Compare an actual image against the pinned reference, always computing the
/// statistics (not only on failure) so callers can record the measured
/// maximum channel difference.
pub fn compareReference(actual: ProbeImage) ProbeComparison {
    const expected = referenceImage();
    const statistics = (ProbeResult{
        .expected = expected,
        .actual = actual,
    }).statistics();
    const byte_exact = expected.width == actual.width and
        expected.height == actual.height and
        std.mem.eql(u8, expected.data, actual.data);
    return .{ .statistics = statistics, .byte_exact = byte_exact };
}

/// Return the canvas size of the shared probe scene (upstream `canvas_size`).
pub fn canvasSize() [2]u16 {
    return GridLayout.fromElements(&PROBE_ELEMENTS).canvasSize();
}

/// Return the pixmap that is referenced when drawing images in the scene
/// (upstream `probe_image_pixmap`).
pub fn probeImagePixmap(allocator: std.mem.Allocator) std.mem.Allocator.Error!Pixmap {
    const edge: u16 = @intFromFloat(IMAGE_SOURCE_SIZE);
    var pixmap = try Pixmap.init(allocator, edge, edge);
    errdefer pixmap.deinit(allocator);

    const red = peniko.Color.fromRgba8(255, 0, 0, 255).premultiply().toRgba8();
    var y: u16 = 0;
    while (y < pixmap.height) : (y += 1) {
        var x: u16 = 0;
        while (x < pixmap.width) : (x += 1) {
            pixmap.setPixel(x, y, red);
        }
    }

    pixmap.setMayHaveTransparency(false);
    return pixmap;
}

/// Create the shared image source for the probe's image elements.
///
/// Ownership follows upstream `ImageSource::Pixmap(Arc::new(...))`: the
/// returned source owns one reference and is consumed by `drawScene`.
pub fn probeImageSource(allocator: std.mem.Allocator) std.mem.Allocator.Error!paint_mod.ImageSource {
    const handle = try shared_mod.Shared(Pixmap).create(
        allocator,
        try probeImagePixmap(allocator),
    );
    return paint_mod.ImageSource.initPixmap(handle);
}

/// Draw the full shared probe scene into a rendering context (upstream
/// `draw_scene`). Consumes `image`.
pub fn drawScene(
    ctx: anytype,
    allocator: std.mem.Allocator,
    image: paint_mod.ImageSource,
) !void {
    const layout = GridLayout.fromElements(&PROBE_ELEMENTS);
    var image_nearest = imagePaint(image.clone(), .low);
    defer image_nearest.deinit(allocator);
    var image_bilinear = imagePaint(image, .medium);
    defer image_bilinear.deinit(allocator);

    ctx.setTransform(kurbo.Affine.IDENTITY);

    for (PROBE_ELEMENTS, 0..) |element, index| {
        try drawProbeElement(
            ctx,
            allocator,
            layout.cellRect(index),
            element,
            &image_nearest,
            &image_bilinear,
        );
    }
}

/// Whether two RGBA8 pixels are within `channel_tolerance` on all four
/// channels; pixels where both alphas are zero compare equal regardless of
/// their color channels (upstream `pixels_within_tolerance`).
pub fn pixelsWithinTolerance(
    expected: []const u8,
    actual: []const u8,
    channel_tolerance: u8,
) bool {
    if (expected[3] == 0 and actual[3] == 0) return true;
    for (0..4) |channel| {
        if (absDiff(expected[channel], actual[channel]) > channel_tolerance) {
            return false;
        }
    }
    return true;
}

fn absDiff(a: u8, b: u8) u8 {
    return if (a > b) a - b else b - a;
}

/// Grid layout of the probe elements (upstream `GridLayout`).
const GridLayout = struct {
    columns: usize,
    rows: usize,
    cell_width: f64,
    cell_height: f64,

    fn fromElements(elements: []const ProbeFeature) GridLayout {
        if (elements.len == 0) {
            return .{ .columns = 0, .rows = 0, .cell_width = 0.0, .cell_height = 0.0 };
        }
        const columns = @min(ELEMENTS_PER_ROW, elements.len);
        const rows = (elements.len + columns - 1) / columns;
        var cell_width: f64 = 0.0;
        var cell_height: f64 = 0.0;
        for (elements) |element| {
            const bounds = element.bounds();
            cell_width = @max(cell_width, bounds[0]);
            cell_height = @max(cell_height, bounds[1]);
        }
        return .{
            .columns = columns,
            .rows = rows,
            .cell_width = cell_width,
            .cell_height = cell_height,
        };
    }

    fn canvasSize(self: GridLayout) [2]u16 {
        const stride = self.cellStride();
        // Margin only exists between cells, so subtract one.
        const width = @as(f64, @floatFromInt(self.columns)) * stride[0] - ELEMENT_MARGIN;
        const height = @as(f64, @floatFromInt(self.rows)) * stride[1] - ELEMENT_MARGIN;
        return .{
            @intFromFloat(@ceil(width)),
            @intFromFloat(@ceil(height)),
        };
    }

    fn cellStride(self: GridLayout) [2]f64 {
        return .{
            self.cell_width + ELEMENT_MARGIN,
            self.cell_height + ELEMENT_MARGIN,
        };
    }

    fn cellRect(self: GridLayout, index: usize) kurbo.Rect {
        const column = index % self.columns;
        const row = index / self.columns;
        const stride = self.cellStride();
        const x0 = @as(f64, @floatFromInt(column)) * stride[0];
        const y0 = @as(f64, @floatFromInt(row)) * stride[1];
        return kurbo.Rect.new(x0, y0, x0 + self.cell_width, y0 + self.cell_height);
    }

    fn cellIndexForPixel(self: GridLayout, pixel_index: usize) usize {
        const stride = self.cellStride();
        const image_width: usize = self.canvasSize()[0];
        const x = pixel_index % image_width;
        const y = pixel_index / image_width;
        const column = x / @as(usize, @intFromFloat(stride[0]));
        const row = y / @as(usize, @intFromFloat(stride[1]));
        return row * self.columns + column;
    }
};

fn imagePaint(image: paint_mod.ImageSource, quality: peniko.ImageQuality) PaintType {
    return paint_mod.PaintType.fromImage(.{
        .image = image,
        .sampler = .{
            .x_extend = .pad,
            .y_extend = .pad,
            .quality = quality,
            .alpha = 1.0,
        },
    });
}

fn drawProbeElement(
    ctx: anytype,
    allocator: std.mem.Allocator,
    cell: kurbo.Rect,
    element: ProbeFeature,
    image_nearest: *const PaintType,
    image_bilinear: *const PaintType,
) !void {
    switch (element) {
        .solid_rect => {
            ctx.setPaint(css.BLUE);
            try ctx.fillRect(allocator, centeredRect(cell, RECT_SIZE, RECT_SIZE));
        },
        .transformed => {
            try drawTransformedRect(ctx, allocator, centeredRect(cell, RECT_SIZE, RECT_SIZE));
        },
        .alpha_blending => {
            const center = cell.center();
            ctx.setPaint(css.YELLOW.withAlpha(0.5));
            var left = try kurbo.Circle.new(
                kurbo.Point.new(center.x - CIRCLE_CENTER_OFFSET_X, center.y),
                CIRCLE_RADIUS,
            ).toPath(PATH_TOLERANCE, allocator);
            defer left.deinit(allocator);
            try ctx.fillPath(allocator, left.elements.items);

            ctx.setPaint(css.GREEN.withAlpha(0.5));
            var right = try kurbo.Circle.new(
                kurbo.Point.new(center.x + CIRCLE_CENTER_OFFSET_X, center.y),
                CIRCLE_RADIUS,
            ).toPath(PATH_TOLERANCE, allocator);
            defer right.deinit(allocator);
            try ctx.fillPath(allocator, right.elements.items);
        },
        .gradient => {
            const rect = centeredRect(cell, RECT_SIZE, RECT_SIZE);
            var gradient = try linearGradient(allocator, &rect);
            errdefer gradient.deinit();
            ctx.setPaint(PaintType.fromGradient(gradient));
            try ctx.fillRect(allocator, rect);
        },
        .image_nearest => {
            try drawCenteredPaddedImage(ctx, allocator, cell, image_nearest);
        },
        .filter => {
            // Upstream `draw_blurred_rect` is disabled: the element is not in
            // `PROBE_ELEMENTS`. Filter layers are the remaining M2 work; fail
            // explicitly if the upstream list is ever re-enabled.
            return error.Unsupported;
        },
        .image_bilinear => {
            try drawCenteredPaddedImage(ctx, allocator, cell, image_bilinear);
        },
        .opacity_layer => {
            try drawOpacityLayerRect(ctx, allocator, centeredRect(cell, RECT_SIZE, RECT_SIZE));
        },
        .blending => {
            try drawLayeredDifferenceCircles(ctx, allocator, cell);
        },
    }
}

fn centeredRect(cell: kurbo.Rect, width: f64, height: f64) kurbo.Rect {
    const center = cell.center();
    return kurbo.Rect.new(
        center.x - width * 0.5,
        center.y - height * 0.5,
        center.x + width * 0.5,
        center.y + height * 0.5,
    );
}

fn drawCenteredPaddedImage(
    ctx: anytype,
    allocator: std.mem.Allocator,
    cell: kurbo.Rect,
    image_paint: *const PaintType,
) !void {
    const dst_rect = centeredRect(cell, RECT_SIZE, RECT_SIZE);
    const image_origin_x = dst_rect.x0 + (RECT_SIZE - IMAGE_SOURCE_SIZE) * 0.5;
    const image_origin_y = dst_rect.y0 + (RECT_SIZE - IMAGE_SOURCE_SIZE) * 0.5;
    ctx.setPaint(try image_paint.clone(allocator));
    ctx.setPaintTransform(kurbo.Affine.translate(
        kurbo.Vec2.new(image_origin_x, image_origin_y),
    ));
    try ctx.fillRect(allocator, dst_rect);
    ctx.resetPaintTransform();
}

fn drawTransformedRect(ctx: anytype, allocator: std.mem.Allocator, rect: kurbo.Rect) !void {
    const center = rect.center();
    ctx.setTransform(
        kurbo.Affine.translate(kurbo.Vec2.new(center.x, center.y))
            .compose(kurbo.Affine.rotate(std.math.pi / 4.0))
            .compose(kurbo.Affine.translate(kurbo.Vec2.new(-center.x, -center.y))),
    );
    ctx.setPaint(css.BLUE);
    try ctx.fillRect(allocator, rect);
    ctx.setTransform(kurbo.Affine.IDENTITY);
}

fn drawOpacityLayerRect(
    ctx: anytype,
    allocator: std.mem.Allocator,
    rect: kurbo.Rect,
) !void {
    try ctx.pushLayer(allocator, null, null, 0.5, null, null);
    ctx.setPaint(css.ORANGE_RED);
    try ctx.fillRect(allocator, rect);
    ctx.popLayer();
}

fn drawLayeredDifferenceCircles(
    ctx: anytype,
    allocator: std.mem.Allocator,
    cell: kurbo.Rect,
) !void {
    const center = cell.center();

    try ctx.pushLayer(allocator, null, null, null, null, null);
    ctx.setPaint(css.YELLOW.withAlpha(0.5));
    var left = try kurbo.Circle.new(
        kurbo.Point.new(center.x - CIRCLE_CENTER_OFFSET_X, center.y),
        CIRCLE_RADIUS,
    ).toPath(PATH_TOLERANCE, allocator);
    defer left.deinit(allocator);
    try ctx.fillPath(allocator, left.elements.items);

    try ctx.pushLayer(
        allocator,
        null,
        peniko.BlendMode.new(.difference, .src_over),
        null,
        null,
        null,
    );
    ctx.setPaint(css.GREEN.withAlpha(0.5));
    var right = try kurbo.Circle.new(
        kurbo.Point.new(center.x + CIRCLE_CENTER_OFFSET_X, center.y),
        CIRCLE_RADIUS,
    ).toPath(PATH_TOLERANCE, allocator);
    defer right.deinit(allocator);
    try ctx.fillPath(allocator, right.elements.items);
    ctx.popLayer();
    ctx.popLayer();
}

fn linearGradient(
    allocator: std.mem.Allocator,
    rect: *const kurbo.Rect,
) std.mem.Allocator.Error!peniko.Gradient {
    const stops = [_]peniko.ColorStop{
        .{ .offset = 0.0, .color = css.BLUE },
        .{ .offset = 1.0, .color = css.RED },
    };
    var gradient = peniko.Gradient{
        .kind = .{ .linear = peniko.LinearGradientPosition.new(
            kurbo.Point.new(rect.x0, rect.y0),
            kurbo.Point.new(rect.x1, rect.y0),
        ) },
        .extend = .pad,
    };
    gradient.stops = try peniko.ColorStops.fromSlice(allocator, &stops);
    return gradient;
}

// ---------------------------------------------------------------------------
// Tests (ports of the upstream probe.rs tests plus layout checks)
// ---------------------------------------------------------------------------

const testing = std.testing;

test "probe canvas size and grid layout" {
    try testing.expectEqual([2]u16{ 51, 51 }, canvasSize());

    const layout = GridLayout.fromElements(&PROBE_ELEMENTS);
    try testing.expectEqual(@as(usize, 3), layout.columns);
    try testing.expectEqual(@as(usize, 3), layout.rows);
    try testing.expectEqual(@as(f64, 10.0 * @sqrt(2.0) + 2.0), layout.cell_width);
    try testing.expectEqual(@as(f64, 10.0 * @sqrt(2.0) + 2.0), layout.cell_height);
}

test "probe image pixmap is opaque red" {
    var pixmap = try probeImagePixmap(testing.allocator);
    defer pixmap.deinit(testing.allocator);
    try testing.expectEqual(@as(u16, 5), pixmap.width);
    try testing.expectEqual(@as(u16, 5), pixmap.height);
    try testing.expect(!pixmap.mayHaveTransparency());
    for (pixmap.data()) |pixel| {
        try testing.expectEqual(peniko.PremulRgba8{ .r = 255, .g = 0, .b = 0, .a = 255 }, pixel);
    }
}

test "probe_result_reports_pixel_and_cell_differences" {
    const allocator = testing.allocator;
    const size = canvasSize();
    const pixel_count = @as(usize, size[0]) * @as(usize, size[1]);

    const expected_data = try allocator.alloc(u8, pixel_count * 4);
    defer allocator.free(expected_data);
    @memset(expected_data, 255);

    const actual_data = try allocator.dupe(u8, expected_data);
    defer allocator.free(actual_data);

    const layout = GridLayout.fromElements(&PROBE_ELEMENTS);

    const setChannel = struct {
        fn set(data: []u8, image_width: usize, l: GridLayout, cell_index: usize, channel: usize, value: u8) void {
            const center = l.cellRect(cell_index).center();
            const x: usize = @intFromFloat(@floor(center.x));
            const y: usize = @intFromFloat(@floor(center.y));
            data[(y * image_width + x) * 4 + channel] = value;
        }
    }.set;

    // This stays within the probe tolerance.
    setChannel(actual_data, @as(usize, size[0]), layout, 0, 0, 254);

    setChannel(actual_data, @as(usize, size[0]), layout, 1, 0, 249);
    setChannel(actual_data, @as(usize, size[0]), layout, 5, 1, 0);
    setChannel(actual_data, @as(usize, size[0]), layout, 5, 3, 100);

    const result = ProbeResult{
        .expected = .{ .width = size[0], .height = size[1], .data = expected_data },
        .actual = .{ .width = size[0], .height = size[1], .data = actual_data },
    };
    const statistics = result.statistics();
    try testing.expectEqual(@as(u8, 8), statistics.element_count);
    try testing.expectEqual([2]u16{ size[0], size[1] }, statistics.actual_size);
    try testing.expectEqual(@as(u32, 2), statistics.different_pixel_count);
    try testing.expectEqual([4]u8{ 6, 255, 0, 155 }, statistics.max_channel_discrepancy);
    try testing.expectEqual(
        @as(u32, (1 << 1) | (1 << 6)),
        statistics.difference_mask,
    );
    try testing.expect(statistics.differs(.alpha_blending));
    try testing.expect(statistics.differs(.opacity_layer));
    try testing.expect(!statistics.differs(.filter));
    try testing.expect(!statistics.differs(.image_bilinear));
}

test "probe_statistics_reports_actual_size" {
    const result = ProbeResult{
        .expected = .{ .width = 1, .height = 1, .data = &[_]u8{ 0, 0, 0, 0 } },
        .actual = .{ .width = 2, .height = 1, .data = &[_]u8{ 0, 0, 0, 0, 0, 0, 0, 0 } },
    };
    try testing.expectEqual([2]u16{ 2, 1 }, result.statistics().actual_size);
}

test "probe reference matches itself and flags a tolerance violation" {
    const reference = referenceImage();

    const comparison = compareReference(reference);
    try testing.expect(comparison.passed());
    try testing.expect(comparison.byte_exact);
    try testing.expect(fromActual(reference).isSuccess());

    // One channel beyond the tolerance must be reported (and attributed).
    const mutated = try testing.allocator.dupe(u8, reference.data);
    defer testing.allocator.free(mutated);
    mutated[0] = reference.data[0] +% (CHANNEL_TOLERANCE + 1);

    const probe = fromActual(.{
        .width = reference.width,
        .height = reference.height,
        .data = mutated,
    });
    try testing.expect(!probe.isSuccess());
    switch (probe) {
        .mismatch => |result| {
            const statistics = result.statistics();
            try testing.expectEqual(@as(u32, 1), statistics.different_pixel_count);
            try testing.expect(statistics.differs(.solid_rect));
        },
        .success => return error.TestUnexpectedResult,
    }
}
