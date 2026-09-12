//! CPU glue for the renderer probe and its oracle comparison.
//!
//! This is the port of the reference-generation path in
//! `vello_tests/src/regenerate_probe_reference.rs`:
//!
//! - `renderProbePixmap` renders `common/probe.zig`'s scene with the exact
//!   settings that produced the committed `tests/fixtures/upstream/probe.rgba`
//!   reference: `Level::fallback`, 0 threads, `RenderMode::OptimizeQuality`,
//!   `TargetInit::Clear(css::WHITE)`, then un-premultiplies via
//!   `take_rgba8(ImageAlphaType::Alpha)`.
//! - The test at the bottom of this file is the end-to-end oracle check
//!   against that pinned reference using upstream's probe policy (see
//!   `common/probe.zig`).
//!
//! Upstream implements `ProbeRenderer` for a wrapper around `RenderContext`;
//! `RenderContext` already exposes the same method shapes, so
//! `common.probe.drawScene` takes `&ctx` directly.

const std = @import("std");
const simd = @import("../simd/root.zig");
const peniko = @import("../peniko/root.zig");
const common_probe = @import("../common/probe.zig");
const pixmap_mod = @import("../common/pixmap.zig");
const render_mod = @import("render.zig");

const Pixmap = pixmap_mod.Pixmap;

/// Render the shared probe scene into a new pixmap using the exact upstream
/// reference settings (`render_probe_pixmap`).
pub fn renderProbePixmap(allocator: std.mem.Allocator) !Pixmap {
    const size = common_probe.canvasSize();
    const settings: render_mod.RenderSettings = .{
        .level = simd.Level.fallback,
        .num_threads = 0,
    };
    var ctx = try render_mod.RenderContext.init(allocator, size[0], size[1], settings);
    defer ctx.deinit(allocator);

    try common_probe.drawScene(
        &ctx,
        allocator,
        try common_probe.probeImageSource(allocator),
    );

    try ctx.flush();

    var resources = render_mod.Resources.init();
    defer resources.deinit(allocator);

    var pixmap = try Pixmap.init(allocator, size[0], size[1]);
    errdefer pixmap.deinit(allocator);

    try ctx.renderWith(&pixmap, &resources, .{
        .render_mode = .optimize_quality,
        .target_init = .{ .clear = peniko.palette.css.WHITE },
        .pixel_format = .rgba8,
        .offset = .{ .x = 0, .y = 0 },
    });

    return pixmap;
}

fn printDifferingPixels(
    expected: common_probe.ProbeImage,
    actual: common_probe.ProbeImage,
    limit: usize,
) void {
    const width = actual.width;
    const pixel_count = @min(expected.data.len / 4, actual.data.len / 4);
    var printed: usize = 0;
    var pixel_index: usize = 0;
    while (pixel_index < pixel_count and printed < limit) : (pixel_index += 1) {
        const e = expected.data[pixel_index * 4 ..][0..4];
        const a = actual.data[pixel_index * 4 ..][0..4];
        if (!common_probe.pixelsWithinTolerance(e, a, common_probe.CHANNEL_TOLERANCE)) {
            std.debug.print(
                "probe diff pixel ({d},{d}): expected [{d} {d} {d} {d}] actual [{d} {d} {d} {d}]\n",
                .{
                    pixel_index % width, pixel_index / width,
                    e[0],                e[1],
                    e[2],                e[3],
                    a[0],                a[1],
                    a[2],                a[3],
                },
            );
            printed += 1;
        }
    }
}

test "probe scene matches the pinned upstream reference" {
    const allocator = std.testing.allocator;

    var pixmap = try renderProbePixmap(allocator);
    defer pixmap.deinit(allocator);

    const actual = try common_probe.ProbeImage.fromPixmap(allocator, &pixmap);
    defer allocator.free(actual.data);

    const comparison = common_probe.compareReference(actual);
    const statistics = comparison.statistics;

    std.debug.print(
        "probe {d}x{d}: different pixels {d}, max channel diff [r g b a] = [{d} {d} {d} {d}], byte-exact {}\n",
        .{
            actual.width,
            actual.height,
            statistics.different_pixel_count,
            statistics.max_channel_discrepancy[0],
            statistics.max_channel_discrepancy[1],
            statistics.max_channel_discrepancy[2],
            statistics.max_channel_discrepancy[3],
            comparison.byte_exact,
        },
    );

    if (!comparison.passed()) {
        for (common_probe.PROBE_ELEMENTS) |feature| {
            if (statistics.differs(feature)) {
                std.debug.print("probe: feature {s} differs\n", .{@tagName(feature)});
            }
        }
        printDifferingPixels(common_probe.referenceImage(), actual, 8);
    }

    try std.testing.expectEqual(@as(u8, 8), statistics.element_count);
    try std.testing.expectEqual([2]u16{ 51, 51 }, statistics.actual_size);
    try std.testing.expect(comparison.passed());

    // Exact equality is preferred for the f32/scalar path; keep it asserted
    // so any later drift is caught even while staying inside tolerance 3.
    try std.testing.expect(comparison.byte_exact);
}
