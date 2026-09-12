//! Autohinting state for a font instance.
//!
//! Port of `skrifa 0.44.0`'s `outline/autohint/instance.rs`. One instance is
//! built per (font, location) and reused across sizes; per-style metrics are
//! computed lazily at draw time exactly like upstream's
//! `UnscaledStyleMetricsSet::Lazy`.

const std = @import("std");
const glyf = @import("../glyf.zig");
const hint_mod = @import("../hint.zig");
const align_mod = @import("align_points.zig");
const hint = @import("hint.zig");
const metrics = @import("metrics.zig");
const outline_mod = @import("outline.zig");
const shaper_mod = @import("shaper.zig");
const styles = @import("styles.zig");
const style_metrics = @import("style_metrics.zig");

pub const Instance = struct {
    allocator: std.mem.Allocator,
    font: glyf.Font,
    outlines: glyf.Outlines,
    styles: styles.GlyphStyleMap = .{},
    /// Lazily computed unscaled metrics per style class index.
    metrics: []?metrics.UnscaledStyleMetrics = &.{},
    target: hint_mod.Target = hint_mod.Target.default,
    is_fixed_width: bool = false,
    is_italic: bool = false,

    /// Builds an instance for a face. `outlines` must be the same outline
    /// collection the instance will draw from.
    pub fn init(
        allocator: std.mem.Allocator,
        outlines: *const glyf.Outlines,
        target: hint_mod.Target,
        coords: []const glyf.NormalizedCoord,
    ) glyf.DrawError!Instance {
        // Variation coordinates are deferred (`gvar`/`HVAR` deltas are not
        // ported); never approximate them.
        if (coords.len != 0) return error.Unsupported;
        var shaper = shaper_mod.Shaper.init(outlines.font, .best_effort);
        var instance = Instance{
            .allocator = allocator,
            .font = outlines.font,
            .outlines = outlines.*,
            .styles = try styles.GlyphStyleMap.init(
                allocator,
                outlines.font.numGlyphs(),
                &shaper,
            ),
            .metrics = &.{},
            .target = target,
            .is_fixed_width = outlines.font.isFixedPitch(),
            .is_italic = outlines.font.isItalic(),
        };
        errdefer instance.deinit();
        instance.metrics = try allocator.alloc(?metrics.UnscaledStyleMetrics, styles.STYLE_CLASSES.len);
        for (instance.metrics) |*entry| entry.* = null;
        return instance;
    }

    pub fn deinit(self: *Instance) void {
        self.styles.deinit(self.allocator);
        if (self.metrics.len > 0) self.allocator.free(self.metrics);
        self.metrics = &.{};
    }

    /// Autohinting is always active once configured.
    pub fn isEnabled(self: *const Instance) bool {
        _ = self;
        return true;
    }

    fn metricsFor(
        self: *Instance,
        class_ix: u16,
    ) glyf.DrawError!*const metrics.UnscaledStyleMetrics {
        if (class_ix >= self.metrics.len) return error.Unsupported;
        if (self.metrics[class_ix] == null) {
            var shaper = shaper_mod.Shaper.init(self.font, .best_effort);
            const style_class = &styles.STYLE_CLASSES[class_ix];
            self.metrics[class_ix] = try style_metrics.computeUnscaledStyleMetrics(
                self.allocator,
                &shaper,
                &self.outlines,
                style_class,
                .jit,
            );
        }
        return &self.metrics[class_ix].?;
    }

    /// Draws one glyph with the autohinter.
    pub fn draw(
        self: *Instance,
        allocator: std.mem.Allocator,
        gid: glyf.GlyphId,
        size: f32,
        coords: []const glyf.NormalizedCoord,
        path_style: glyf.PathStyle,
        pen: anytype,
    ) glyf.DrawError!glyf.AdjustedMetrics {
        if (coords.len != 0) return error.Unsupported;
        if (path_style != .freetype) return error.Unsupported;
        const style = self.styles.styleFor(gid) orelse return error.Unsupported;
        const style_metrics_value = try self.metricsFor(style.styleIndex() orelse return error.Unsupported);
        const units_per_em: i32 = self.outlines.unitsPerEm();
        const scale = metrics.Scale.new(
            size,
            units_per_em,
            self.is_italic,
            self.target,
            style_metrics_value.styleClass().script.group,
        );
        var outline = outline_mod.Outline{};
        defer outline.deinit(allocator);
        try outline.fill(allocator, &self.outlines, gid, .jit);
        const hinted_metrics = try hint.hintOutline(
            allocator,
            &outline,
            style_metrics_value,
            &scale,
            style,
        );
        const h_advance = outline.advance;
        var pp1x: i32 = 0;
        var pp2x: i32 = metrics.fixedMul(h_advance, hinted_metrics.x_scale);
        const is_light = self.target.isLight() or self.target.preserveLinearMetrics();
        // FreeType's advance-width adjustment for non-light hinting.
        if (!is_light) {
            if (!scale.flags.contains(metrics.ScaleFlags.no_advance)) {
                if (hinted_metrics.edge_metrics) |edge_metrics| {
                    const old_rsb = pp2x - edge_metrics.right_opos;
                    const old_lsb = edge_metrics.left_opos;
                    const new_lsb = edge_metrics.left_pos;
                    var pp1x_uh = new_lsb - old_lsb;
                    var pp2x_uh = edge_metrics.right_pos + old_rsb;
                    if (old_lsb < 24) pp1x_uh -= 8;
                    if (old_rsb < 24) pp2x_uh += 8;
                    pp1x = metrics.pixRound(pp1x_uh);
                    pp2x = metrics.pixRound(pp2x_uh);
                    if (pp1x >= new_lsb and old_lsb > 0) pp1x -= 64;
                    if (pp2x <= edge_metrics.right_pos and old_rsb > 0) pp2x += 64;
                } else {
                    pp1x = metrics.pixRound(pp1x);
                    pp2x = metrics.pixRound(pp2x);
                }
            } else {
                pp1x = metrics.pixRound(pp1x);
                pp2x = metrics.pixRound(pp2x);
            }
        } else {
            pp1x = metrics.pixRound(pp1x);
            pp2x = metrics.pixRound(pp2x);
        }
        if (pp1x != 0) {
            for (outline.points.items) |*point| {
                point.x = point.x -% pp1x;
            }
        }
        const advance: i32 = if (!is_light and
            (self.is_fixed_width or
                (style_metrics_value.digits_have_same_width and style.isDigit())))
            metrics.fixedMul(h_advance, scale.x_scale)
        else if (h_advance != 0)
            pp2x -% pp1x
        else
            0;
        try outline.toPath(allocator, path_style, pen);
        const info = self.outlines.outline(gid) catch |err| switch (err) {
            error.OutOfBounds => glyf.Outline{ .glyph_id = gid },
            else => return err,
        };
        return .{
            .has_overlaps = info.has_overlaps,
            .lsb = null,
            .advance_width = glyf.f26ToF32(metrics.pixRound(advance)),
        };
    }
};

test "autohint draws a Latin glyph deterministically" {
    const fixture = @import("../test_fixture.zig");
    const pen_mod = @import("../pen.zig");
    const font = try glyf.Font.init(try fixture.notoSans(), 0);
    const outlines = try font.outlines();
    var instance = try Instance.init(
        std.testing.allocator,
        &outlines,
        glyf.glifo_hint_target,
        &.{},
    );
    defer instance.deinit();

    var pen = pen_mod.PathElementPen.init(std.testing.allocator);
    defer pen.deinit();
    const adjusted = try instance.draw(
        std.testing.allocator,
        36,
        16.0,
        &.{},
        .freetype,
        &pen,
    );
    try std.testing.expectEqual(@as(f32, 10.0), adjusted.advance_width.?);
    try std.testing.expect(adjusted.lsb == null);
    try std.testing.expect(!adjusted.has_overlaps);
    try std.testing.expect(pen.elements.items.len > 0);

    var pen2 = pen_mod.PathElementPen.init(std.testing.allocator);
    defer pen2.deinit();
    _ = try instance.draw(std.testing.allocator, 36, 16.0, &.{}, .freetype, &pen2);
    try std.testing.expectEqual(pen.elements.items.len, pen2.elements.items.len);
    for (pen.elements.items, pen2.elements.items) |a, b| {
        try std.testing.expect(std.meta.eql(a, b));
    }
}

test "autohint rejects deferred inputs" {
    const fixture = @import("../test_fixture.zig");
    const font = try glyf.Font.init(try fixture.notoSans(), 0);
    const outlines = try font.outlines();
    try std.testing.expectError(
        error.Unsupported,
        Instance.init(std.testing.allocator, &outlines, glyf.glifo_hint_target, &.{0}),
    );
}
