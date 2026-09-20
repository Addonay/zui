//! Daybook's visual language: quiet paper, ink, moss, and one terracotta cue.
const zui = @import("zui");
const shadcn = @import("shadcn-zui");
const base = shadcn.theme;

pub const bg = base.background;
pub const sidebar = base.page;
pub const paper = base.card;
pub const paper_hover = base.accent;
pub const line = base.border;
pub const ink = base.foreground;
pub const muted = base.muted_foreground;
pub const moss = base.success;
pub const moss_soft = base.accent;
pub const terracotta = base.primary;
pub const terracotta_soft = base.accent;
pub const danger = base.destructive;

// Compatibility aliases keep the view code readable while the old Daybook
// vocabulary is migrated into the smaller theme module.
pub const panel = sidebar;
pub const card = paper;
pub const card_hover = paper_hover;
pub const border = line;
pub const text = ink;
pub const faint = muted;
pub const accent = terracotta;
pub const good = moss;

pub const font = struct {
    pub const body = base.font;
    pub const sans = body;
    pub const display = body;
    pub const mono = "DejaVu Sans Mono, monospace";
};

pub fn label(value: []const u8, size: f32, color: zui.Color) zui.Element {
    return zui.text(value, .{ .font = font.body, .size = size, .line_height = size + 6, .color = color });
}

pub fn mono(value: []const u8, size: f32, color: zui.Color) zui.Element {
    return zui.text(value, .{ .font = font.mono, .size = size, .line_height = size + 6, .color = color });
}

pub fn display(value: []const u8, size: f32, color: zui.Color) zui.Element {
    return zui.text(value, .{ .font = font.display, .size = size, .line_height = size + 8, .weight = .bold, .color = color });
}
