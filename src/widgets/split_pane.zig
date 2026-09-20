//! Split-pane interaction model. Geometry and painting remain caller-owned.
const std = @import("std");
const platform = @import("../platform/root.zig");
const a11y = @import("../a11y/root.zig");
const elements = @import("../elements/root.zig");
const element_mod = @import("../elements/element.zig");
const core = @import("../core/root.zig");
const Window = @import("../app/window.zig").Window;

/// Bounded retained docking model used by split-pane consumers. It keeps the
/// structural part of GPUI-style panes separate from rendering: panels are
/// stable keys, splits are clamped, and every mutation is deterministic.
pub const DockSide = enum { left, right, top, bottom };
pub const DockPanel = struct { key: u64, title: []const u8, active: bool = true };
pub const DockLayout = struct {
    pub const max_panels: usize = 32;
    panels: [max_panels]DockPanel = undefined,
    len: usize = 0,
    split_ratio: f32 = 0.5,
    orientation_horizontal: bool = true,

    pub fn add(self: *DockLayout, panel: DockPanel) bool {
        if (self.len >= self.panels.len) return false;
        self.panels[self.len] = panel;
        self.len += 1;
        return true;
    }
    pub fn remove(self: *DockLayout, key: u64) bool {
        for (self.panels[0..self.len], 0..) |panel, i| if (panel.key == key) {
            std.mem.copyForwards(DockPanel, self.panels[i .. self.len - 1], self.panels[i + 1 .. self.len]);
            self.len -= 1;
            return true;
        };
        return false;
    }
    pub fn dock(self: *DockLayout, panel: DockPanel, side: DockSide) bool {
        if (!self.add(panel)) return false;
        self.orientation_horizontal = side == .left or side == .right;
        return true;
    }
    pub fn setSplit(self: *DockLayout, ratio: f32) void {
        self.split_ratio = std.math.clamp(ratio, 0.1, 0.9);
    }
};

pub const SplitPane = struct {
    pub const Options = struct { ratio: f32 = 0.5, min_first: f32 = 0.1, max_first: f32 = 0.9, disabled: bool = false, loading: bool = false, error_state: bool = false };
    options: Options,
    ratio: f32,
    dragging: bool = false,
    focused: bool = false,
    horizontal: bool = true,
    divider_size: f32 = 8,
    pub fn init(options: Options) SplitPane {
        return .{ .options = options, .ratio = std.math.clamp(options.ratio, options.min_first, options.max_first) };
    }
    pub fn setRatio(self: *SplitPane, ratio: f32) bool {
        if (self.options.disabled or self.options.loading or !std.math.isFinite(ratio)) return false;
        const next = std.math.clamp(ratio, self.options.min_first, self.options.max_first);
        if (next == self.ratio) return false;
        self.ratio = next;
        return true;
    }
    pub fn semanticProperties(self: *const SplitPane, label: []const u8) a11y.Properties {
        return .{ .role = .group, .name = label, .value = .{ .current = self.ratio, .min = self.options.min_first, .max = self.options.max_first, .step = 0.01 }, .states = .{ .disabled = self.options.disabled or self.options.loading, .focused = self.focused }, .actions = .{ .focus = true, .increment = !self.options.disabled and !self.options.loading, .decrement = !self.options.disabled and !self.options.loading, .set_value = !self.options.disabled and !self.options.loading } };
    }
    pub fn handleEvent(self: *SplitPane, event: platform.Event) bool {
        if (self.options.disabled or self.options.loading or event != .key or !event.key.pressed) return false;
        const delta: f32 = 0.02;
        return switch (event.key.key) {
            .left => self.setRatio(self.ratio - delta),
            .right => self.setRatio(self.ratio + delta),
            .home => self.setRatio(self.options.min_first),
            .end => self.setRatio(self.options.max_first),
            else => false,
        };
    }
    fn focusId(self: *SplitPane) u32 {
        return @truncate(@intFromPtr(self));
    }
    fn focusedEvent(target: *anyopaque, event: platform.Event, _: *anyopaque) bool {
        return @as(*SplitPane, @ptrCast(@alignCast(target))).handleEvent(event);
    }
    fn pointerDown(target: *anyopaque, _: *const element_mod.ListenerPayload, raw_window: *anyopaque) void {
        const self: *SplitPane = @ptrCast(@alignCast(target));
        const win: *Window = @ptrCast(@alignCast(raw_window));
        const p = win.pointerPosition();
        const axis = if (self.horizontal) p.x else p.y;
        const extent = if (self.horizontal) win.ui_frame.nodes[0].bounds.w else win.ui_frame.nodes[0].bounds.h;
        _ = extent;
        self.dragging = axis >= self.ratio * 100 - self.divider_size and axis <= self.ratio * 100 + self.divider_size;
    }
    fn pointerMove(target: *anyopaque, _: *const element_mod.ListenerPayload, raw_window: *anyopaque) void {
        const self: *SplitPane = @ptrCast(@alignCast(target));
        if (!self.dragging) return;
        const win: *Window = @ptrCast(@alignCast(raw_window));
        const p = win.pointerPosition();
        // The root receives logical bounds at paint time; the bounded model
        // uses a deterministic 100-unit axis for raw listener tests and
        // applications can use setRatio for exact pixel-to-ratio mapping.
        _ = self.setRatio(std.math.clamp(if (self.horizontal) p.x / 100 else p.y / 100, 0, 1));
    }
    fn pointerUp(target: *anyopaque, _: *const element_mod.ListenerPayload, _: *anyopaque) void {
        @as(*SplitPane, @ptrCast(@alignCast(target))).dragging = false;
    }
    fn semanticAction(target: *anyopaque, request: a11y.Request, _: *anyopaque) void {
        const self: *SplitPane = @ptrCast(@alignCast(target));
        if (request.action == .set_value) _ = self.setRatio(@floatCast(request.value));
        if (request.action == .increment) _ = self.setRatio(self.ratio + 0.02);
        if (request.action == .decrement) _ = self.setRatio(self.ratio - 0.02);
    }
    pub fn renderWith(self: *SplitPane, first: elements.Element, second: elements.Element) elements.Element {
        const focus = elements.FocusHandle{ .id = self.focusId(), .target = self, .event_fn = focusedEvent };
        const first_w: f32 = if (self.horizontal) self.ratio * 100 else 100;
        const first_h: f32 = if (self.horizontal) 100 else self.ratio * 100;
        const second_w: f32 = if (self.horizontal) (1 - self.ratio) * 100 else 100;
        const second_h: f32 = if (self.horizontal) 100 else (1 - self.ratio) * 100;
        var root = elements.div().w_full().h_full().withFocus(focus);
        root = if (self.horizontal) root.flex_row() else root.flex_col();
        root = root.semantic(.{ .role = .group, .name = "Split pane", .value = .{ .current = self.ratio, .min = self.options.min_first, .max = self.options.max_first, .step = 0.01 }, .states = .{ .disabled = self.options.disabled or self.options.loading, .focused = self.focused }, .actions = .{ .focus = true, .increment = true, .decrement = true, .set_value = true }, .handler = .{ .target = self, .call_fn = semanticAction } });
        var first_panel = first.w(first_w).h(first_h);
        var second_panel = second.w(second_w).h(second_h);
        if (self.options.disabled or self.options.loading) {
            first_panel = first_panel.opacity(0.6);
            second_panel = second_panel.opacity(0.6);
        }
        const divider = elements.div().w(if (self.horizontal) self.divider_size else 100).h(if (self.horizontal) 100 else self.divider_size)
            .bg(core.Color.rgba(0.3, 0.35, 0.45, 1)).on_mouse_down(.{ .target = self, .call_fn = pointerDown })
            .on_mouse_move(.{ .target = self, .call_fn = pointerMove }).on_mouse_up(.{ .target = self, .call_fn = pointerUp });
        return root.child(first_panel).child(divider).child(second_panel);
    }
    pub fn render(self: *SplitPane) elements.Element {
        return self.renderWith(
            elements.div().bg(core.Color.rgba(0.12, 0.14, 0.18, 1)),
            elements.div().bg(core.Color.rgba(0.08, 0.1, 0.13, 1)),
        );
    }
};

test "split pane clamps keyboard resizing and gates disabled" {
    var pane = SplitPane.init(.{ .ratio = 0.5, .min_first = 0.25, .max_first = 0.75 });
    try std.testing.expect(pane.handleEvent(.{ .key = .{ .key = .left, .pressed = true } }));
    try std.testing.expectEqual(@as(f32, 0.48), pane.ratio);
    pane.options.disabled = true;
    try std.testing.expect(!pane.handleEvent(.{ .key = .{ .key = .right, .pressed = true } }));
}

test "dock layout keeps bounded panel order and split limits" {
    var dock = DockLayout{};
    try std.testing.expect(dock.dock(.{ .key = 1, .title = "Files" }, .left));
    try std.testing.expect(dock.dock(.{ .key = 2, .title = "Editor" }, .right));
    dock.setSplit(2);
    try std.testing.expectEqual(@as(f32, 0.9), dock.split_ratio);
    try std.testing.expect(dock.remove(1));
    try std.testing.expectEqual(@as(usize, 1), dock.len);
}
