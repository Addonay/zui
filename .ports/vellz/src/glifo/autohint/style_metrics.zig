//! Unscaled style metrics assembly.
//!
//! Port of `skrifa 0.44.0`'s
//! `outline/autohint/metrics/scale.rs::compute_unscaled_style_metrics`:
//! stem widths, blue zones and digit advances for one style class.

const std = @import("std");
const glyf = @import("../glyf.zig");
const metrics = @import("metrics.zig");
const shaper_mod = @import("shaper.zig");
const styles = @import("styles.zig");
const blues = @import("blues.zig");
const widths = @import("widths.zig");

/// Computes unscaled metrics for the given shaper/outlines and style class.
pub fn computeUnscaledStyleMetrics(
    allocator: std.mem.Allocator,
    shaper: *const shaper_mod.Shaper,
    outlines: *const glyf.Outlines,
    style: *const styles.StyleClass,
    quirks: metrics.QuirksMode,
) glyf.DrawError!metrics.UnscaledStyleMetrics {
    const charmap = shaper.charmap();
    // No metrics without a Unicode cmap.
    if (charmap.isSymbol()) {
        return .{
            .class_ix = style.index,
            .axes = .{
                .{ .dim = .horizontal },
                .{ .dim = .vertical },
            },
        };
    }
    var result = metrics.UnscaledStyleMetrics{ .class_ix = style.index };
    const width_results = try widths.computeWidths(allocator, shaper, outlines, style, quirks);
    const blue_results = try blues.computeUnscaledBlues(allocator, shaper, outlines, style);
    var digit_advance: ?i32 = null;
    var digits_have_same_width = true;
    var ch: u21 = '0';
    while (ch <= '9') : (ch += 1) {
        if (charmap.map(ch)) |gid| {
            if (outlines.font.advanceWidthOpt(gid)) |advance| {
                if (digit_advance != null and digit_advance.? != advance) {
                    digits_have_same_width = false;
                    break;
                }
                digit_advance = advance;
            }
        }
    }
    result.digits_have_same_width = digits_have_same_width;
    result.axes = .{
        .{
            .dim = .horizontal,
            .blues = blue_results[0],
            .width_metrics = width_results[0].metrics,
            .widths = width_results[0].widths,
        },
        .{
            .dim = .vertical,
            .blues = blue_results[1],
            .width_metrics = width_results[1].metrics,
            .widths = width_results[1].widths,
        },
    };
    return result;
}

test "unscaled style metrics carry the style index" {
    const style = &styles.STYLE_CLASSES[styles.style.latn];
    try std.testing.expectEqual(@as(u16, styles.style.latn), style.index);
    try std.testing.expect(style.script.group == .default);
}
