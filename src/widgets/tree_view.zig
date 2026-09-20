//! Bounded tree navigation model. Nodes are flat, pre-order rows supplied by the caller.
const std = @import("std");
const platform = @import("../platform/root.zig");
const a11y = @import("../a11y/root.zig");
const elements = @import("../elements/root.zig");
const element_mod = @import("../elements/element.zig");
const core = @import("../core/root.zig");
const Window = @import("../app/window.zig").Window;

pub const Node = struct { key: u64, label: []const u8, depth: u16 = 0, parent: ?usize = null, has_children: bool = false, expanded: bool = true, disabled: bool = false };
pub const DropKind = enum { before, inside, after };
pub const DropTarget = struct { node: usize, kind: DropKind };
pub const Range = struct { start: usize, end: usize };
pub const TreeView = struct {
    pub const Options = struct { nodes: []Node, selected: usize = 0, disabled: bool = false, loading: bool = false, error_state: bool = false };
    options: Options,
    selected: usize,
    focused: bool = false,
    viewport_height: f32 = 240,
    row_height: f32 = 24,
    scroll_y: f32 = 0,
    overscan: usize = 2,
    dragging: ?usize = null,
    drop_target: ?DropTarget = null,
    pub const max_virtual_rows: usize = 128;
    pub fn init(options: Options) TreeView {
        return .{ .options = options, .selected = if (options.nodes.len == 0) 0 else @min(options.selected, options.nodes.len - 1) };
    }
    pub fn visibleRange(self: *const TreeView) Range {
        if (self.options.nodes.len == 0 or self.row_height <= 0) return .{ .start = 0, .end = 0 };
        const first = @min(self.options.nodes.len, @as(usize, @intFromFloat(@max(0, @floor(self.scroll_y / self.row_height)))));
        const count = @as(usize, @intFromFloat(@ceil(@max(0, self.viewport_height) / self.row_height))) + self.overscan * 2;
        return .{ .start = first, .end = @min(self.options.nodes.len, first + count) };
    }
    pub fn rowRect(self: *const TreeView, index: usize, width: f32) core.Rect {
        return .{ .x = 0, .y = @as(f32, @floatFromInt(index)) * self.row_height - self.scroll_y, .w = width, .h = self.row_height };
    }
    pub fn scrollTo(self: *TreeView, index: usize) void {
        if (self.options.nodes.len == 0) return;
        const i = @min(index, self.options.nodes.len - 1);
        const top = @as(f32, @floatFromInt(i)) * self.row_height;
        const bottom = top + self.row_height;
        if (top < self.scroll_y) self.scroll_y = top;
        if (bottom > self.scroll_y + self.viewport_height) self.scroll_y = bottom - self.viewport_height;
        self.scroll_y = @max(0, @min(self.scroll_y, @max(0, @as(f32, @floatFromInt(self.options.nodes.len)) * self.row_height - self.viewport_height)));
    }
    pub fn setDropTarget(self: *TreeView, target: ?DropTarget) void {
        self.drop_target = target;
    }
    pub fn handleInput(self: *TreeView, input: platform.event.InputEvent) bool {
        switch (input) {
            .drag_drop => |drop| {
                if (drop.kind == .exited or drop.kind == .ended) {
                    self.drop_target = null;
                    return true;
                }
                if (self.options.nodes.len == 0 or self.row_height <= 0) return false;
                const raw = @as(isize, @intFromFloat(@floor((drop.pos.y + self.scroll_y) / self.row_height)));
                if (raw < 0 or @as(usize, @intCast(raw)) >= self.options.nodes.len) return false;
                const index: usize = @intCast(raw);
                const within = @mod(drop.pos.y + self.scroll_y, self.row_height);
                self.drop_target = .{ .node = index, .kind = if (within < self.row_height / 3) .before else if (within > self.row_height * 2 / 3) .after else .inside };
                return true;
            },
            else => return false,
        }
    }
    fn focusId(self: *TreeView) u32 {
        return @truncate(@intFromPtr(self));
    }
    fn focusedEvent(target: *anyopaque, event: platform.Event, _: *anyopaque) bool {
        return @as(*TreeView, @ptrCast(@alignCast(target))).handleEvent(event);
    }
    fn semanticAction(target: *anyopaque, request: a11y.Request, _: *anyopaque) void {
        const self: *TreeView = @ptrCast(@alignCast(target));
        if (request.action == .activate and self.selected < self.options.nodes.len and self.options.nodes[self.selected].has_children) self.options.nodes[self.selected].expanded = !self.options.nodes[self.selected].expanded;
    }
    fn clickRow(target: *anyopaque, payload: *const element_mod.ListenerPayload, raw_window: *anyopaque) void {
        const self: *TreeView = @ptrCast(@alignCast(target));
        const index = @as(usize, @intCast(payload.bytes[0]));
        if (index < self.options.nodes.len and !self.options.nodes[index].disabled) self.selected = index;
        _ = raw_window;
    }
    fn pointerDown(target: *anyopaque, _: *const element_mod.ListenerPayload, _: *anyopaque) void {
        const self: *TreeView = @ptrCast(@alignCast(target));
        if (!self.options.disabled and !self.options.loading) self.dragging = self.selected;
    }
    fn pointerMove(target: *anyopaque, _: *const element_mod.ListenerPayload, raw_window: *anyopaque) void {
        const self: *TreeView = @ptrCast(@alignCast(target));
        const win: *Window = @ptrCast(@alignCast(raw_window));
        if (self.options.nodes.len == 0 or self.row_height <= 0) return;
        const p = win.pointerPosition();
        const raw = @as(isize, @intFromFloat(@floor((p.y + self.scroll_y) / self.row_height)));
        if (raw < 0 or @as(usize, @intCast(raw)) >= self.options.nodes.len) {
            self.drop_target = null;
            return;
        }
        const index: usize = @intCast(raw);
        const within = @mod(p.y + self.scroll_y, self.row_height);
        self.drop_target = .{ .node = index, .kind = if (within < self.row_height / 3) .before else if (within > self.row_height * 2 / 3) .after else .inside };
    }
    fn pointerUp(target: *anyopaque, _: *const element_mod.ListenerPayload, _: *anyopaque) void {
        const self: *TreeView = @ptrCast(@alignCast(target));
        self.dragging = null;
    }
    pub fn render(self: *TreeView) elements.Element {
        const focus = elements.FocusHandle{ .id = self.focusId(), .target = self, .event_fn = focusedEvent };
        var root = elements.div().w_full().h(self.viewport_height).overflow_hidden().scroll_y(self.scroll_y).withFocus(focus)
            .on_mouse_down(.{ .target = self, .call_fn = pointerDown })
            .on_mouse_move(.{ .target = self, .call_fn = pointerMove })
            .on_mouse_up(.{ .target = self, .call_fn = pointerUp })
            .semantic(.{ .role = .list, .name = "Tree", .position_in_set = 1, .set_size = 1, .states = .{ .disabled = self.options.disabled or self.options.loading, .scrollable = self.options.nodes.len > 0 }, .actions = .{ .activate = !self.options.disabled and !self.options.loading, .focus = true }, .handler = .{ .target = self, .call_fn = semanticAction } });
        const range = self.visibleRange();
        var emitted: usize = 0;
        var i = range.start;
        while (i < range.end and emitted < max_virtual_rows) : ({
            i += 1;
            emitted += 1;
        }) {
            if (!self.visible(i)) continue;
            var payload: element_mod.ListenerPayload = .{ .bytes = @splat(0) };
            payload.bytes[0] = @intCast(@min(i, 255));
            var row = elements.div().absolute().top(@as(f32, @floatFromInt(i)) * self.row_height).w_full().h(self.row_height)
                .p(4).pl(8 + @as(f32, @floatFromInt(self.options.nodes[i].depth)) * 14)
                .on_click(.{ .target = self, .payload = payload, .call_fn = clickRow })
                .on_mouse_down(.{ .target = self, .call_fn = pointerDown })
                .on_mouse_move(.{ .target = self, .call_fn = pointerMove })
                .on_mouse_up(.{ .target = self, .call_fn = pointerUp })
                .semantic(self.nodeSemantics(i));
            if (self.drop_target) |drop| {
                if (drop.node == i) row = row.border_1().border_color(.{ .r = 0.2, .g = 0.5, .b = 1, .a = 1 });
            }
            root = root.child(row.child(elements.text(self.options.nodes[i].label, .{})));
        }
        return root;
    }
    fn visible(self: *const TreeView, index: usize) bool {
        var parent = self.options.nodes[index].parent;
        while (parent) |p| {
            if (!self.options.nodes[p].expanded) return false;
            parent = self.options.nodes[p].parent;
        }
        return true;
    }
    fn move(self: *TreeView, delta: i2) bool {
        if (self.options.nodes.len == 0) return false;
        var i = self.selected;
        var n: usize = 0;
        while (n < self.options.nodes.len) : (n += 1) {
            i = if (delta > 0) (i + 1) % self.options.nodes.len else (i + self.options.nodes.len - 1) % self.options.nodes.len;
            if (self.visible(i) and !self.options.nodes[i].disabled) {
                self.selected = i;
                return true;
            }
        }
        return false;
    }
    pub fn handleEvent(self: *TreeView, event: platform.Event) bool {
        if (self.options.disabled or self.options.loading or self.options.nodes.len == 0 or event != .key or !event.key.pressed) return false;
        switch (event.key.key) {
            .up => return self.move(-1),
            .down => return self.move(1),
            .home => {
                self.selected = 0;
                return true;
            },
            .end => {
                self.selected = self.options.nodes.len - 1;
                return true;
            },
            .left => if (self.options.nodes[self.selected].has_children and self.options.nodes[self.selected].expanded) {
                self.options.nodes[self.selected].expanded = false;
                return true;
            },
            .right => if (self.options.nodes[self.selected].has_children and !self.options.nodes[self.selected].expanded) {
                self.options.nodes[self.selected].expanded = true;
                return true;
            },
            else => return false,
        }
        return false;
    }
    pub fn nodeSemantics(self: *const TreeView, index: usize) a11y.Properties {
        const node = self.options.nodes[index];
        return .{ .role = .listitem, .name = node.label, .position_in_set = index + 1, .set_size = self.options.nodes.len, .states = .{ .disabled = self.options.disabled or self.options.loading or node.disabled, .selected = self.selected == index, .focused = self.focused and self.selected == index, .expanded = if (node.has_children) node.expanded else null }, .actions = .{ .activate = !self.options.disabled and !self.options.loading and !node.disabled, .focus = true } };
    }
};

test "tree navigation respects collapsed ancestors and disabled rows" {
    var nodes = [_]Node{ .{ .key = 1, .label = "root", .has_children = true }, .{ .key = 2, .label = "child", .parent = 0 }, .{ .key = 3, .label = "disabled", .disabled = true } };
    var tree = TreeView.init(.{ .nodes = &nodes });
    try std.testing.expect(tree.handleEvent(.{ .key = .{ .key = .down, .pressed = true } }));
    try std.testing.expectEqual(@as(usize, 1), tree.selected);
    try std.testing.expect(tree.handleEvent(.{ .key = .{ .key = .up, .pressed = true } }));
    try std.testing.expect(tree.handleEvent(.{ .key = .{ .key = .left, .pressed = true } }));
    try std.testing.expect(tree.handleEvent(.{ .key = .{ .key = .down, .pressed = true } }));
    try std.testing.expectEqual(@as(usize, 0), tree.selected);
}
