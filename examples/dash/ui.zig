//! Small shared builders for the dashboard modules.

const zui = @import("zui");

const theme = @import("theme.zig");

pub fn label(value: []const u8, size: f32, color: zui.Color) zui.Element {
    return zui.text(value, .{ .font = theme.font, .size = size, .line_height = size + 6, .color = color });
}

pub fn strong(value: []const u8, size: f32, color: zui.Color) zui.Element {
    return zui.text(value, .{ .font = theme.font, .size = size, .line_height = size + 6, .weight = .semibold, .color = color });
}

pub fn icon(bytes: []const u8, size: f32, color: zui.Color) zui.Element {
    return zui.svg(bytes).w(size).h(size).tint(color);
}
