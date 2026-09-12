//! Entry point to the autohinting algorithm.
//!
//! Port of `skrifa 0.44.0`'s `outline/autohint/hint/mod.rs`. The recorder
//! path (`hint_outline_with_recorder`, used by `HintPlan`/AOT) is not ported:
//! glifo only ever calls the JIT entry point, and the recorder selects
//! `QuirksMode::Aot` upstream, so omitting it is observable only through
//! `HintPlan`.

const std = @import("std");
const align_mod = @import("align_points.zig");
const hint_edges = @import("hint_edges.zig");
const metrics = @import("metrics.zig");
const outline_mod = @import("outline.zig");
const styles = @import("styles.zig");
const topo = @import("topo.zig");

const Dimension = @import("types.zig").Dimension;
const Outline = outline_mod.Outline;
const Scale = metrics.Scale;
const UnscaledStyleMetrics = metrics.UnscaledStyleMetrics;

/// Captures adjusted horizontal scale and outer edge positions for
/// horizontal metrics adjustments.
pub const EdgeMetrics = struct {
    left_opos: i32 = 0,
    left_pos: i32 = 0,
    right_opos: i32 = 0,
    right_pos: i32 = 0,
};

pub const HintedMetrics = struct {
    x_scale: i32 = 0,
    /// `null` when fewer than two horizontal edges were found (empty or
    /// degenerate outlines); horizontal metrics are not adjusted then.
    edge_metrics: ?EdgeMetrics = null,
};

/// Applies the complete hinting process to an outline (JIT quirks).
pub fn hintOutline(
    allocator: std.mem.Allocator,
    outline: *Outline,
    unscaled_metrics: *const UnscaledStyleMetrics,
    scale: *const Scale,
    glyph_style: ?styles.GlyphStyle,
) glyf.DrawError!HintedMetrics {
    // Upstream selects AOT quirks only when a recorder is present; the glifo
    // path never passes one.
    const quirks: metrics.QuirksMode = .jit;
    var scaled_metrics = metrics.scaleStyleMetrics(unscaled_metrics, scale.*, quirks);
    const scaled_scale = &scaled_metrics.scale;
    var axis = topo.Axis{};
    defer axis.deinit(allocator);
    const style_class = unscaled_metrics.styleClass();
    const hint_top_to_bottom = style_class.script.hint_top_to_bottom;
    outline.scaleBy(&scaled_metrics.scale);
    var hinted_metrics = HintedMetrics{ .x_scale = scaled_scale.x_scale };
    const script_group = style_class.script.group;
    // For the default script group, don't proceed without alignment zones;
    // FreeType swaps in a "dummy" hinter here.
    if (script_group == .default and scaled_metrics.axes[1].blues.len == 0) {
        return hinted_metrics;
    }
    for ([_]Dimension{ .horizontal, .vertical }) |dim| {
        if ((dim == .horizontal and scaled_scale.flags.contains(metrics.ScaleFlags.no_horizontal)) or
            (dim == .vertical and scaled_scale.flags.contains(metrics.ScaleFlags.no_vertical)))
        {
            continue;
        }
        axis.reset(dim, outline.orientation);
        _ = try topo.computeSegments(allocator, outline, &axis, script_group);
        topo.linkSegments(
            outline,
            &axis,
            scaled_metrics.axes[@intFromEnum(dim)].scale,
            script_group,
            unscaled_metrics.axes[@intFromEnum(dim)].maxWidth(),
        );
        try topo.computeEdges(
            allocator,
            &axis,
            &scaled_metrics.axes[@intFromEnum(dim)],
            hint_top_to_bottom,
            scaled_metrics.scale.y_scale,
            script_group,
        );
        if (dim == .vertical) {
            const style_allows = if (glyph_style) |style_value|
                !style_value.isNonBase()
            else
                true;
            if (script_group != .default or style_allows) {
                topo.computeBlueEdges(
                    &axis,
                    scaled_scale,
                    unscaled_metrics.axes[1].blues.asSlice(),
                    scaled_metrics.axes[1].blues.asSlice(),
                    script_group,
                );
            }
        } else {
            hinted_metrics.x_scale = scaled_metrics.axes[0].scale;
        }
        hint_edges.hintEdges(
            &axis,
            &scaled_metrics.axes[@intFromEnum(dim)],
            script_group,
            scaled_scale,
            hint_top_to_bottom,
        );
        align_mod.alignEdgePoints(outline, &axis, script_group, scaled_scale);
        align_mod.alignStrongPoints(outline, &axis);
        align_mod.alignWeakPoints(outline, dim);
        if (dim == .horizontal and axis.edges.items.len > 1) {
            const left = axis.edges.items[0];
            const right = axis.edges.items[axis.edges.items.len - 1];
            hinted_metrics.edge_metrics = .{
                .left_pos = left.pos,
                .left_opos = left.opos,
                .right_pos = right.pos,
                .right_opos = right.opos,
            };
        }
    }
    return hinted_metrics;
}

const glyf = @import("../glyf.zig");
