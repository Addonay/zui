//! Latin (and shared) standard stem width computation.
//!
//! Port of `skrifa 0.44.0`'s `outline/autohint/metrics/widths.rs`.

const std = @import("std");
const glyf = @import("../glyf.zig");
const fixed = @import("fixed.zig");
const metrics = @import("metrics.zig");
const outline_mod = @import("outline.zig");
const shaper_mod = @import("shaper.zig");
const topo = @import("topo.zig");
const styles = @import("styles.zig");

pub const WidthResult = struct {
    metrics: metrics.WidthMetrics = .{},
    widths: metrics.UnscaledWidths = .{},
};

/// Computes all stem widths and initializes the standard width and height for
/// the given script. Returns `[horizontal, vertical]`.
pub fn computeWidths(
    allocator: std.mem.Allocator,
    shaper: *const shaper_mod.Shaper,
    outlines: *const glyf.Outlines,
    style: *const styles.StyleClass,
    quirks: metrics.QuirksMode,
) glyf.DrawError![2]WidthResult {
    var result = [2]WidthResult{ .{}, .{} };
    const units_per_em: i32 = outlines.unitsPerEm();
    var outline = outline_mod.Outline{};
    defer outline.deinit(allocator);
    var axis = topo.Axis{};
    defer axis.deinit(allocator);
    var cluster_shaper = shaper.clusterShaper(style);
    var shaped_cluster = shaper_mod.ShapedCluster.empty;
    defer shaped_cluster.deinit(allocator);
    // Take the first available glyph from the standard character set.
    var glyph: ?glyf.GlyphId = null;
    var clusters = std.mem.splitScalar(u8, style.script.std_chars, ' ');
    while (clusters.next()) |cluster| {
        try cluster_shaper.shape(allocator, cluster, &shaped_cluster);
        // Reject input that maps to more than a single glyph.
        if (shaped_cluster.items.len == 1 and shaped_cluster.items[0].id != 0) {
            const candidate = outlines.getGlyph(shaped_cluster.items[0].id) catch |err| switch (err) {
                error.OutOfBounds => continue,
                else => return err,
            };
            if (candidate != null) {
                glyph = shaped_cluster.items[0].id;
                break;
            }
        }
    }
    if (glyph) |gid| {
        const filled = outline.fill(allocator, outlines, gid, quirks);
        if (filled) |_| {
            if (outline.points.items.len > 0) {
                // Now process each dimension.
                for ([_]topo.Dimension{ .horizontal, .vertical }, 0..) |dim, dim_ix| {
                    axis.reset(dim, outline.orientation);
                    // Segment computation for widths always uses the default
                    // script group.
                    if (!try topo.computeSegments(allocator, &outline, &axis, .default)) continue;
                    topo.linkSegments(&outline, &axis, 0, .default, null);
                    const segments = axis.segments.items;
                    for (segments, 0..) |segment, segment_ix| {
                        const link_ix = segment.link_ix orelse continue;
                        if (link_ix <= segment_ix) continue;
                        const link = segments[link_ix];
                        if (link.link_ix != @as(?u16, @intCast(segment_ix))) continue;
                        const dist: i32 = @intCast(@abs(@as(i32, segment.pos) - link.pos));
                        if (result[dim_ix].widths.len < metrics.max_widths) {
                            _ = result[dim_ix].widths.push(dist);
                        } else {
                            break;
                        }
                    }
                    // FreeType always updates the width count to 1 when no
                    // widths were found.
                    if (result[dim_ix].widths.len == 0) {
                        _ = result[dim_ix].widths.push(0);
                    }
                    // The value 100 is a heuristic.
                    metrics.sortAndQuantizeWidths(&result[dim_ix].widths, @divTrunc(units_per_em, 100));
                }
            }
        } else |err| switch (err) {
            error.OutOfMemory => return err,
            else => {},
        }
    }
    for (&result) |*width_result| {
        // Now set derived values.
        const stdw: i32 = if (width_result.widths.len > 0)
            width_result.widths.items[0]
        else
            fixed.derivedConstant(units_per_em, 50);
        // Heuristic value: 20% of the smallest width.
        width_result.metrics.edge_distance_threshold = @divTrunc(stdw, 5);
        width_result.metrics.standard_width = stdw;
        width_result.metrics.is_extra_light = false;
    }
    return result;
}

test "width results derive from the first width" {
    var w = metrics.UnscaledWidths{};
    _ = w.push(54);
    try std.testing.expectEqual(@as(i32, 54), w.items[0]);
    try std.testing.expectEqual(@as(i32, 50), fixed.derivedConstant(2048, 50));
    try std.testing.expectEqual(@as(i32, 10), @divTrunc(w.items[0], 5));
}
