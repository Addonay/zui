//! Theme tokens for the first component set (gap report §6).
//!
//! Semantic tokens, not per-widget colors: controls read the active palette
//! plus geometry tokens (radii, focus ring) so light/dark is more than a
//! background swap — surfaces, text, borders, and state overlays all move.
//! State overlays (hover/pressed/disabled) are derived here so every
//! control shares one state ladder.

const std = @import("std");
const color_mod = @import("../core/color.zig");

pub const Mode = enum { light, dark };

pub const Palette = struct {
    bg: color_mod.Color,
    surface: color_mod.Color,
    surface_raised: color_mod.Color,
    fg: color_mod.Color,
    muted: color_mod.Color,
    accent: color_mod.Color,
    accent_fg: color_mod.Color,
    border: color_mod.Color,
    focus_ring: color_mod.Color,
    danger: color_mod.Color,
    success: color_mod.Color,
    track: color_mod.Color,
};

pub const Spacing = struct {
    xs: f32 = 4,
    sm: f32 = 8,
    md: f32 = 12,
    lg: f32 = 16,
    xl: f32 = 24,
};

pub const Radii = struct {
    sm: f32 = 4,
    md: f32 = 8,
    lg: f32 = 12,
    full: f32 = 999,
};

pub const Typography = struct {
    label: f32 = 13,
    body: f32 = 14,
    title: f32 = 16,
};

pub const Theme = struct {
    mode: Mode,
    palette: Palette,
    spacing: Spacing = .{},
    radii: Radii = .{},
    type_scale: Typography = .{},
    /// Visible focus indicator width (§5C): rendered as the control border
    /// color swap plus a 2px ring. The token lives here so every control
    /// uses the same width and color.
    focus_ring_width: f32 = 2,
    button_h: f32 = 36,
    control_radius: f32 = 8,
};

pub const light: Theme = .{
    .mode = .light,
    .palette = .{
        .bg = .hex(0xf4f4f6),
        .surface = .hex(0xffffff),
        .surface_raised = .hex(0xececf0),
        .fg = .hex(0x1b1c22),
        .muted = .hex(0x5f6070),
        .accent = .hex(0x5b4ee0),
        .accent_fg = .hex(0xffffff),
        .border = .hex(0xd8d8e0),
        .focus_ring = .hex(0x5b4ee0),
        .danger = .hex(0xc93a3a),
        .success = .hex(0x1f8a4c),
        .track = .hex(0xdcdce4),
    },
};

pub const dark: Theme = .{
    .mode = .dark,
    .palette = .{
        .bg = .hex(0x16161d),
        .surface = .hex(0x1e1f2a),
        .surface_raised = .hex(0x262736),
        .fg = .hex(0xf2f2f5),
        .muted = .hex(0x9a9bb0),
        .accent = .hex(0x7c5cff),
        .accent_fg = .hex(0xffffff),
        .border = .hex(0x3a3b4d),
        .focus_ring = .hex(0x9a86ff),
        .danger = .hex(0xe06a6a),
        .success = .hex(0x3ddc84),
        .track = .hex(0xffffff14),
    },
};

/// Current theme. Thread-local builds diverge here later (per-window mode);
/// today every control shares one settable theme, defaulting to dark to
/// match the existing demos.
var active: Theme = dark;

pub fn current() Theme {
    return active;
}

pub fn set(t: Theme) void {
    active = t;
}

/// Shared state ladder: hover lightens dark surfaces / darkens light ones
/// by mixing toward fg; pressed goes one step further; disabled drops to
/// half alpha. One ladder, every control.
pub fn stateBg(t: Theme, base: color_mod.Color, state: @import("behavior.zig").VisualState) color_mod.Color {
    return switch (state) {
        .idle => base,
        .hovered => mix(base, t.palette.fg, if (t.mode == .dark) 0.08 else 0.05),
        .pressed => mix(base, t.palette.fg, if (t.mode == .dark) 0.16 else 0.10),
        .disabled => base.withAlpha(0.5),
    };
}

fn mix(a: color_mod.Color, b: color_mod.Color, t: f32) color_mod.Color {
    return .{
        .r = a.r + (b.r - a.r) * t,
        .g = a.g + (b.g - a.g) * t,
        .b = a.b + (b.b - a.b) * t,
        .a = a.a,
    };
}

test "state ladder moves in both modes" {
    const t = std.testing;
    for ([_]Theme{ light, dark }) |th| {
        const base = th.palette.surface;
        const hover = stateBg(th, base, .hovered);
        const pressed = stateBg(th, base, .pressed);
        try t.expect(hover.r != base.r or hover.g != base.g or hover.b != base.b);
        try t.expect(pressed.r != base.r or pressed.g != base.g or pressed.b != base.b);
        try t.expectEqual(@as(f32, 0.5), stateBg(th, base, .disabled).a);
    }
    // Focus rings differ per mode (not just a swapped background).
    try t.expect(light.palette.focus_ring.r != dark.palette.focus_ring.r or
        light.palette.focus_ring.g != dark.palette.focus_ring.g);
}

test "theme is settable and readable" {
    const t = std.testing;
    const prev = current();
    set(light);
    try t.expectEqual(Mode.light, current().mode);
    set(prev);
}
