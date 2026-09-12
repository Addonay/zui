//! Autohinting metrics: scale parameters, stem widths and alignment zones.
//!
//! Port of `skrifa 0.44.0`'s `outline/autohint/metrics/{mod,scale}.rs`.
//! Unscaled metrics are computed per style/script (`widths.zig`, `blues.zig`)
//! and scaled here with exactly the upstream fixed-point operations.

const std = @import("std");
const hint = @import("../hint.zig");
const bz = @import("blue_zones.zig");
const fixed = @import("fixed.zig");
const styles = @import("styles.zig");

pub const BlueZones = bz.BlueZones;

/// An unscaled alignment zone (upstream `UnscaledBlue`).
pub const UnscaledBlue = struct {
    /// Position of the blue.
    position: i32 = 0,
    /// Overshoot value of the blue.
    overshoot: i32 = 0,
    /// Maximum extent of outlines used to compute this blue.
    ascender: i32 = 0,
    /// Minimum extent of outlines used to compute this blue.
    descender: i32 = 0,
    /// Active zones for this blue.
    zones: BlueZones = .none,
};

/// A scaled alignment zone (upstream `ScaledBlue`).
pub const ScaledBlue = struct {
    /// Scaled position of the blue.
    position: ScaledWidth = .{},
    /// Scaled overshoot for the blue.
    overshoot: ScaledWidth = .{},
    /// Active zones for this blue.
    zones: BlueZones = .none,
    /// True if the blue is active.
    is_active: bool = false,
};

pub const fixedMul = fixed.mul;
pub const fixedDiv = fixed.div;
pub const fixedMulDiv = fixed.mulDiv;
pub const pixRound = fixed.pixRound;
pub const pixFloor = fixed.pixFloor;
pub const derivedConstant = fixed.derivedConstant;

pub const dimension = @import("types.zig");
pub const Dimension = dimension.Dimension;

/// Controls quirks for the different autohinters (`QuirksMode` upstream).
pub const QuirksMode = enum {
    /// Just in time hinter; matches FreeType. glifo's per-glyph path uses it.
    jit,
    /// Ahead of time hinter; matches ttfautohint.
    aot,
};

/// Maximum number of widths, same for Latin and CJK.
pub const max_widths: usize = 16;
/// Maximum number of blue values.
pub const max_blues: usize = 8;

/// A fixed-capacity vector mirroring upstream's `SmallVec<T, N>`.
pub fn SmallVec(comptime T: type, comptime cap: usize) type {
    return struct {
        items: [cap]T = std.mem.zeroes([cap]T),
        len: usize = 0,
        const Self = @This();

        pub fn clear(self: *Self) void {
            self.len = 0;
        }

        /// Appends when there is room; returns false when full.
        pub fn push(self: *Self, value: T) bool {
            if (self.len >= cap) return false;
            self.items[self.len] = value;
            self.len += 1;
            return true;
        }

        pub fn asSlice(self: *const Self) []const T {
            return self.items[0..self.len];
        }

        pub fn asMutSlice(self: *Self) []T {
            return self.items[0..self.len];
        }

        pub fn last(self: *const Self) ?T {
            if (self.len == 0) return null;
            return self.items[self.len - 1];
        }
    };
}

pub const UnscaledWidths = SmallVec(i32, max_widths);
pub const UnscaledBlues = SmallVec(UnscaledBlue, max_blues);
pub const ScaledWidths = SmallVec(ScaledWidth, max_widths);
pub const ScaledBlues = SmallVec(ScaledBlue, max_blues);

/// Metrics for the set of stems along a single axis.
pub const WidthMetrics = struct {
    /// Used for creating edges.
    edge_distance_threshold: i32 = 0,
    /// Default stem thickness.
    standard_width: i32 = 0,
    /// Is standard width very light?
    is_extra_light: bool = false,
};

/// A scaled stem width.
pub const ScaledWidth = struct {
    /// Width after applying scale.
    scaled: i32 = 0,
    /// Grid-fitted width.
    fitted: i32 = 0,
};

/// Unscaled metrics for a single axis.
pub const UnscaledAxisMetrics = struct {
    dim: Dimension = .horizontal,
    widths: UnscaledWidths = .{},
    width_metrics: WidthMetrics = .{},
    blues: UnscaledBlues = .{},

    pub fn maxWidth(self: *const UnscaledAxisMetrics) ?i32 {
        return self.widths.last();
    }
};

/// Scaled metrics for a single axis.
pub const ScaledAxisMetrics = struct {
    dim: Dimension = .horizontal,
    /// Font unit to 26.6 scale in the axis direction.
    scale: i32 = 0,
    /// 1/64 pixel delta in the axis direction.
    delta: i32 = 0,
    widths: ScaledWidths = .{},
    width_metrics: WidthMetrics = .{},
    blues: ScaledBlues = .{},

    pub fn maxWidth(self: *const ScaledAxisMetrics) ?i32 {
        return self.widths.last();
    }
};

/// Unscaled metrics for a single style and script.
pub const UnscaledStyleMetrics = struct {
    /// Index of style class.
    class_ix: u16 = 0,
    /// Monospaced digits?
    digits_have_same_width: bool = false,
    /// Per-dimension unscaled metrics.
    axes: [2]UnscaledAxisMetrics = .{ .{}, .{} },

    pub fn styleClass(self: *const UnscaledStyleMetrics) *const styles.StyleClass {
        return &styles.STYLE_CLASSES[self.class_ix];
    }

    pub fn horizontalMetrics(self: *const UnscaledStyleMetrics) *const UnscaledAxisMetrics {
        return &self.axes[0];
    }

    pub fn verticalMetrics(self: *const UnscaledStyleMetrics) *const UnscaledAxisMetrics {
        return &self.axes[1];
    }
};

/// Scaled metrics for a single style and script.
pub const ScaledStyleMetrics = struct {
    /// Multidimensional scaling factors and deltas.
    scale: Scale = .{},
    /// Per-dimension scaled metrics.
    axes: [2]ScaledAxisMetrics = .{ .{ .dim = .horizontal }, .{ .dim = .vertical } },

    pub fn horizontalMetrics(self: *const ScaledStyleMetrics) *const ScaledAxisMetrics {
        return &self.axes[0];
    }

    pub fn verticalMetrics(self: *const ScaledStyleMetrics) *const ScaledAxisMetrics {
        return &self.axes[1];
    }
};

/// Flags that determine hinting functionality (upstream `ScaleFlags`).
pub const ScaleFlags = struct {
    bits: u32 = 0,

    /// Stem width snapping.
    pub const horizontal_snap = ScaleFlags{ .bits = 1 << 0 };
    /// Stem height snapping.
    pub const vertical_snap = ScaleFlags{ .bits = 1 << 1 };
    /// Stem width/height adjustment.
    pub const stem_adjust = ScaleFlags{ .bits = 1 << 2 };
    /// Monochrome rendering.
    pub const mono = ScaleFlags{ .bits = 1 << 3 };
    /// Disable horizontal hinting.
    pub const no_horizontal = ScaleFlags{ .bits = 1 << 4 };
    /// Disable vertical hinting.
    pub const no_vertical = ScaleFlags{ .bits = 1 << 5 };
    /// Disable advance hinting.
    pub const no_advance = ScaleFlags{ .bits = 1 << 6 };

    pub fn contains(self: ScaleFlags, other: ScaleFlags) bool {
        return self.bits & other.bits == other.bits;
    }
};

/// Captures scaling parameters which may be modified during metrics
/// computation.
pub const Scale = struct {
    /// Flags that determine hinting functionality.
    flags: ScaleFlags = .{},
    /// Font unit to 26.6 scale in the X direction.
    x_scale: i32 = 0,
    /// Font unit to 26.6 scale in the Y direction.
    y_scale: i32 = 0,
    /// In 1/64 device pixels.
    x_delta: i32 = 0,
    /// In 1/64 device pixels.
    y_delta: i32 = 0,
    /// Font size in pixels per em.
    size: f32 = 0,
    /// From the source font.
    units_per_em: i32 = 0,

    /// Creates initial scaling parameters from metrics and hinting target.
    pub fn new(
        size: f32,
        units_per_em: i32,
        is_italic: bool,
        target: hint.Target,
        group: styles.ScriptGroup,
    ) Scale {
        // `Fixed::from_bits((size * 64.0) as i32) / Fixed::from_bits(upem)`
        const scale = fixedDiv(fixed.saturatingF32ToI32(size * 64.0), units_per_em);
        var flags: u32 = 0;
        const is_mono = target == .mono;
        const is_light = target.isLight() or target.preserveLinearMetrics();
        // Snap vertical stems for monochrome and horizontal LCD rendering.
        if (is_mono or target.isLcd()) flags |= ScaleFlags.horizontal_snap.bits;
        // Snap horizontal stems for monochrome and vertical LCD rendering.
        if (is_mono or target.isVerticalLcd()) flags |= ScaleFlags.vertical_snap.bits;
        // Adjust stems to full pixels unless in LCD or light modes.
        if (!(target.isLcd() or is_light)) flags |= ScaleFlags.stem_adjust.bits;
        if (is_mono) flags |= ScaleFlags.mono.bits;
        if (group == .default) {
            // Disable horizontal hinting completely for LCD, light hinting
            // and italic fonts.
            if (target.isLcd() or is_light or is_italic) {
                flags |= ScaleFlags.no_horizontal.bits;
            }
        }
        // CJK doesn't hint advances.
        if (group != .default) flags |= ScaleFlags.no_advance.bits;
        return .{
            .flags = .{ .bits = flags },
            .x_scale = scale,
            .y_scale = scale,
            .x_delta = 0,
            .y_delta = 0,
            .size = size,
            .units_per_em = units_per_em,
        };
    }
};

/// `af_sort_and_quantize_widths`: sort ascending and merge clusters not
/// larger than `threshold` into their mean.
pub fn sortAndQuantizeWidths(widths: *UnscaledWidths, threshold: i32) void {
    if (widths.len <= 1) return;
    std.mem.sort(i32, widths.asMutSlice(), {}, std.sort.asc(i32));
    const table = widths.asMutSlice();
    var cur_ix: usize = 0;
    var cur_val = table[cur_ix];
    const last_ix = table.len - 1;
    var ix: usize = 1;
    while (ix < table.len) {
        if ((table[ix] -% cur_val) > threshold or ix == last_ix) {
            var sum: i32 = 0;
            if ((table[ix] -% cur_val <= threshold) and ix == last_ix) {
                ix += 1;
            }
            for (table[cur_ix..ix]) |*val| {
                sum +%= val.*;
                val.* = 0;
            }
            table[cur_ix] = @divTrunc(sum, @as(i32, @intCast(ix)));
            if (ix < last_ix) {
                cur_ix = ix + 1;
                cur_val = table[cur_ix];
            }
        }
        ix += 1;
    }
    cur_ix = 1;
    for (1..table.len) |scan_ix| {
        if (table[scan_ix] != 0) {
            table[cur_ix] = table[scan_ix];
            cur_ix += 1;
        }
    }
    widths.len = cur_ix;
}

/// Computes scaled metrics for one style/script (`aflatin.c` /
/// `afcjk.c` dispatch).
pub fn scaleStyleMetrics(
    unscaled_metrics: *const UnscaledStyleMetrics,
    initial_scale: Scale,
    quirks: QuirksMode,
) ScaledStyleMetrics {
    var scale = initial_scale;
    const use_default = unscaled_metrics.styleClass().script.group == .default;
    var axes: [2]ScaledAxisMetrics = undefined;
    for (0..2) |dim_ix| {
        const axis = &unscaled_metrics.axes[dim_ix];
        axes[dim_ix] = if (use_default)
            scaleDefaultAxisMetrics(axis, &scale, quirks)
        else
            scaleCjkAxisMetrics(axis, &scale);
    }
    return .{ .scale = scale, .axes = axes };
}

fn scaleDefaultAxisMetrics(
    unscaled: *const UnscaledAxisMetrics,
    scale: *Scale,
    quirks: QuirksMode,
) ScaledAxisMetrics {
    var axis = ScaledAxisMetrics{ .dim = unscaled.dim };
    if (unscaled.dim == .horizontal) {
        axis.scale = scale.x_scale;
        axis.delta = scale.x_delta;
    } else {
        axis.scale = scale.y_scale;
        axis.delta = scale.y_delta;
    }
    // Correct Y scale to optimize alignment.
    if (indexOfBlue(unscaled.blues.asSlice(), ScaleFlagsBits.adjustment)) |blue_ix| {
        const unscaled_blue = unscaled.blues.items[blue_ix];
        const scaled = fixedMul(axis.scale, unscaled_blue.overshoot);
        const fitted = (scaled +% 40) & ~@as(i32, 63);
        if (scaled != fitted and unscaled.dim == .vertical) {
            const new_scale = fixedMulDiv(axis.scale, fitted, scaled);
            // Scaling should not adjust by more than 2 pixels.
            var max_height = scale.units_per_em;
            for (unscaled.blues.asSlice()) |blue_value| {
                max_height = @max(max_height, @max(blue_value.ascender, -blue_value.descender));
            }
            var dist: i32 = @intCast(@abs(fixedMul(max_height, new_scale -% axis.scale)));
            dist &= ~@as(i32, 127);
            if (dist == 0) {
                axis.scale = new_scale;
                scale.y_scale = new_scale;
            }
        }
    }
    // Now scale the widths. FreeType ensures there is always at least one
    // width entry (the standard width), even if width extraction found none.
    axis.width_metrics = unscaled.width_metrics;
    if (unscaled.widths.len == 0 and quirks == .aot) {
        const scaled = fixedMul(axis.scale, axis.width_metrics.standard_width);
        _ = axis.widths.push(.{ .scaled = scaled, .fitted = scaled });
    } else {
        for (unscaled.widths.asSlice()) |unscaled_width| {
            const scaled = fixedMul(axis.scale, unscaled_width);
            _ = axis.widths.push(.{ .scaled = scaled, .fitted = scaled });
        }
    }
    // Compute extra light property: a standard width less than 5/8 pixels.
    axis.width_metrics.is_extra_light =
        fixedMul(axis.width_metrics.standard_width, axis.scale) < (32 + 8);
    if (unscaled.dim == .vertical) {
        for (unscaled.blues.asSlice()) |unscaled_blue| {
            const scaled_position = fixedMul(axis.scale, unscaled_blue.position) +% axis.delta;
            const scaled_overshoot = fixedMul(axis.scale, unscaled_blue.overshoot) +% axis.delta;
            var blue_value = ScaledBlue{
                .position = .{ .scaled = scaled_position, .fitted = scaled_position },
                .overshoot = .{ .scaled = scaled_overshoot, .fitted = scaled_overshoot },
                .zones = unscaled_blue.zones,
                .is_active = false,
            };
            // Only activate blue zones less than 3/4 pixel tall.
            const dist = fixedMul(unscaled_blue.position -% unscaled_blue.overshoot, axis.scale);
            if (dist >= -48 and dist <= 48) {
                var delta: i32 = @intCast(@abs(dist));
                if (delta < 32) {
                    delta = 0;
                } else if (delta < 48) {
                    delta = 32;
                } else {
                    delta = 64;
                }
                if (dist < 0) delta = -delta;
                blue_value.position.fitted = pixRound(blue_value.position.scaled);
                blue_value.overshoot.fitted = blue_value.position.fitted - delta;
                blue_value.is_active = true;
            }
            _ = axis.blues.push(blue_value);
        }
        // Use sub-top blue zone if it doesn't overlap another non-sub-top
        // blue zone.
        for (0..axis.blues.len) |blue_ix| {
            const blue_value = axis.blues.items[blue_ix];
            if (!blue_value.zones.isSubTop() or !blue_value.is_active) continue;
            for (axis.blues.asSlice()) |blue2| {
                if (blue2.zones.isSubTop() or !blue2.is_active) continue;
                if (blue2.position.fitted <= blue_value.overshoot.fitted and
                    blue2.overshoot.fitted >= blue_value.position.fitted)
                {
                    axis.blues.items[blue_ix].is_active = false;
                    break;
                }
            }
        }
    }
    return axis;
}

fn scaleCjkAxisMetrics(unscaled: *const UnscaledAxisMetrics, scale: *Scale) ScaledAxisMetrics {
    var axis = ScaledAxisMetrics{ .dim = unscaled.dim };
    if (unscaled.dim == .horizontal) {
        axis.scale = scale.x_scale;
        axis.delta = scale.x_delta;
    } else {
        axis.scale = scale.y_scale;
        axis.delta = scale.y_delta;
    }
    const axis_scale = axis.scale;
    for (unscaled.blues.asSlice()) |unscaled_blue| {
        const position = fixedMul(unscaled_blue.position, axis_scale) +% axis.delta;
        const overshoot = fixedMul(unscaled_blue.overshoot, axis_scale) +% axis.delta;
        var blue_value = ScaledBlue{
            .position = .{ .scaled = position, .fitted = position },
            .overshoot = .{ .scaled = overshoot, .fitted = overshoot },
            .zones = unscaled_blue.zones,
            .is_active = false,
        };
        // A blue zone is only active if it is less than 3/4 pixels tall.
        const dist = fixedMul(unscaled_blue.position -% unscaled_blue.overshoot, axis_scale);
        if (dist >= -48 and dist <= 48) {
            blue_value.position.fitted = pixRound(blue_value.position.scaled);
            // For CJK, "overshoot" is actually undershoot.
            const delta1 = fixedDiv(blue_value.position.fitted, axis_scale) -% unscaled_blue.overshoot;
            var delta2 = fixedMul(@intCast(@abs(delta1)), axis_scale);
            if (delta2 < 32) {
                delta2 = 0;
            } else {
                delta2 = pixRound(delta2);
            }
            if (delta1 < 0) delta2 = -delta2;
            blue_value.overshoot.fitted = blue_value.position.fitted - delta2;
            blue_value.is_active = true;
        }
        _ = axis.blues.push(blue_value);
    }
    // FreeType never computes scaled width values; match that.
    for (unscaled.widths.asSlice()) |_| {
        _ = axis.widths.push(.{});
    }
    axis.width_metrics = unscaled.width_metrics;
    return axis;
}

fn indexOfBlue(blues: []const UnscaledBlue, flag: u16) ?usize {
    for (blues, 0..) |blue_value, ix| {
        if (blue_value.zones.bits & flag == flag) return ix;
    }
    return null;
}

const ScaleFlagsBits = struct {
    const adjustment: u16 = 1 << 4;
};

test "sort and quantize widths matches upstream" {
    var widths = UnscaledWidths{};
    for ([_]i32{ 60, 20, 40, 35 }) |w| _ = widths.push(w);
    sortAndQuantizeWidths(&widths, 10);
    try std.testing.expectEqualSlices(i32, &[_]i32{ 20, 35, 13, 60 }, widths.asSlice());

    var widths2 = UnscaledWidths{};
    for ([_]i32{ 60, 20, 40, 35 }) |w| _ = widths2.push(w);
    sortAndQuantizeWidths(&widths2, 20);
    try std.testing.expectEqualSlices(i32, &[_]i32{ 31, 60 }, widths2.asSlice());

    var single = UnscaledWidths{};
    _ = single.push(1);
    sortAndQuantizeWidths(&single, 10);
    try std.testing.expectEqualSlices(i32, &[_]i32{1}, single.asSlice());
}

test "scale flags for glifo target" {
    const scale = Scale.new(16.0, 2048, false, hint.glifo_target, .default);
    try std.testing.expect(scale.flags.contains(ScaleFlags.no_horizontal));
    try std.testing.expect(!scale.flags.contains(ScaleFlags.stem_adjust));
    try std.testing.expect(!scale.flags.contains(ScaleFlags.no_advance));
    try std.testing.expectEqual(@as(i32, 0x8000), scale.x_scale);
}
