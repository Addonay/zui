//! Renderer-independent, frame-owned accessibility snapshot. No native bridge.
const std = @import("std");
const Rect = @import("../core/geometry.zig").Rect;
const element = @import("../elements/element.zig");
const limits = @import("../core/limits.zig");
pub const accesskit = @import("accesskit.zig");
pub const capacity = limits.MAX_A11Y_ELEMENTS;
pub const Role = enum { group, button, checkbox, radio_group, radio, switch_control, slider, progress, text_input, label, dialog, list, listitem, menu, menuitem, menuitem_checkbox, tooltip, combobox, listbox, option, table, row, tableheader, cell };
pub const Action = enum { activate, increment, decrement, set_value, set_text_selection, focus };
pub const Request = struct {
    action: Action,
    value: f64 = 0,
    /// Bounded UTF-8 value for editable text actions. The slice is borrowed
    /// for the synchronous Tree.perform call; native bridges copy it before
    /// queueing.
    text: []const u8 = "",
    selection: ?TextSelection = null,
};
pub const Actions = packed struct { activate: bool = false, increment: bool = false, decrement: bool = false, set_value: bool = false, set_text_selection: bool = false, focus: bool = false };
pub const States = struct { modal: bool = false, expanded: ?bool = null, disabled: bool = false, checked: ?bool = null, selected: bool = false, focused: bool = false, read_only: bool = false, hidden: bool = false, scrollable: bool = false };
pub const Value = struct { current: f64, min: f64 = 0, max: f64 = 1, step: f64 = 0 };
/// UTF-8 byte offsets converted to Unicode scalar character indices by the
/// producer. AccessKit text positions use character indices, not byte offsets.
pub const TextSelection = struct { anchor: u32 = 0, focus: u32 = 0 };
pub const TextRange = struct { start: u32 = 0, end: u32 = 0 };
/// Geometry is indexed by Unicode scalar character. Positions and widths are
/// layout-local logical pixels; ranges retain the source UTF-8 byte span for
/// each character so editing and AT actions can round-trip safely.
pub const TextGeometry = struct {
    positions: []const f32 = &.{},
    widths: []const f32 = &.{},
    ranges: []const TextRange = &.{},
};
pub const Handler = struct {
    target: *anyopaque,
    call_fn: *const fn (*anyopaque, Request, *anyopaque) void,
};
pub const Properties = struct {
    role: Role,
    name: []const u8 = "",
    text_value: []const u8 = "",
    value: ?Value = null,
    /// One-based virtual collection position and logical collection size.
    position_in_set: ?usize = null,
    set_size: ?usize = null,
    states: States = .{},
    actions: Actions = .{},
    /// Stable-key relationships, not transient element indices.
    labelled_by: u64 = 0,
    described_by: u64 = 0,
    controls: u64 = 0,
    active_descendant: u64 = 0,
    handler: ?Handler = null,
};
pub const Binding = struct { index: u16, properties: Properties, text_selection_slot: u8 = 0, text_geometry_slot: u8 = 0 };
pub const Node = struct {
    key: u64,
    parent: u64,
    bounds: Rect,
    properties: Properties,
    focus: ?element.FocusHandle = null,
    owner: ?element.OwnerRef = null,
};
pub const Tree = struct {
    nodes: [capacity]Node = undefined,
    count: usize = 0,
    dropped: usize = 0,
    duplicate_keys: usize = 0,
    unkeyed: usize = 0,
    invalid_utf8: usize = 0,
    generation: u64 = 0,

    pub fn find(self: *const Tree, key: u64) ?*const Node {
        for (self.nodes[0..self.count]) |*node| if (node.key == key) return node;
        return null;
    }
    /// Resolve against the CURRENT snapshot and owner generation, never a
    /// cached native pointer. Caller passes the owning window on the UI thread.
    pub fn perform(self: *const Tree, key: u64, request: Request, window: *@import("../app/window.zig").Window) bool {
        const node = self.find(key) orelse return false;
        if (node.properties.states.disabled or node.properties.states.hidden) return false;
        if (node.owner) |owner| if (element.entity_is_alive_fn) |alive| {
            if (!alive(owner.store, owner.id, owner.generation)) return false;
        };
        const allowed = switch (request.action) {
            .activate => node.properties.actions.activate,
            .increment => node.properties.actions.increment,
            .decrement => node.properties.actions.decrement,
            .set_value => node.properties.actions.set_value,
            .set_text_selection => node.properties.actions.set_text_selection,
            .focus => node.properties.actions.focus,
        };
        if (!allowed) return false;
        if (request.action == .focus) {
            const handle = node.focus orelse return false;
            if (!handle.isLive()) return false;
            if (window.focus_scope) |scope| if (scope.modal and !scope.contains(handle.id)) return false;
            window.setFocused(handle);
        } else {
            const handler = node.properties.handler orelse return false;
            handler.call_fn(handler.target, request, window);
        }
        window.requestRender();
        return true;
    }
};

/// Called by painter after layout, once per frame. Names/values were copied
/// into Frame.text_storage by semantic(); valid until that frame is reset.
pub fn build(frame: *element.Frame, root: element.Element) void {
    frame.semantic_tree = .{ .generation = frame.generation };
    visit(frame, root.index, 0, .{ .x = -1e9, .y = -1e9, .w = 2e9, .h = 2e9 });
}
pub fn append(frame: *element.Frame, root: element.Element) void {
    visit(frame, root.index, 0, .{ .x = -1e9, .y = -1e9, .w = 2e9, .h = 2e9 });
}
fn intersection(a: Rect, b: Rect) Rect {
    const x = @max(a.x, b.x);
    const y = @max(a.y, b.y);
    return .{ .x = x, .y = y, .w = @max(0, @min(a.x + a.w, b.x + b.w) - x), .h = @max(0, @min(a.y + a.h, b.y + b.h) - y) };
}
fn visit(frame: *element.Frame, index: u16, parent: u64, clip: Rect) void {
    const node = &frame.nodes[index];
    const tree = &frame.semantic_tree;
    const bounds = intersection(node.bounds, clip);
    var next_parent = parent;
    for (frame.semantic_bindings[0..frame.semantic_count]) |binding| {
        if (binding.index != index) continue;
        if (node.stable_key == 0) {
            tree.unkeyed += 1;
            break;
        }
        if (tree.find(node.stable_key) != null) {
            tree.duplicate_keys += 1;
            break;
        }
        if (tree.count == capacity) {
            tree.dropped += 1;
            break;
        }
        var props = binding.properties;
        if (!std.unicode.utf8ValidateSlice(props.name) or !std.unicode.utf8ValidateSlice(props.text_value)) {
            tree.invalid_utf8 += 1;
            break;
        }
        props.states.hidden = props.states.hidden or bounds.w <= 0 or bounds.h <= 0;
        var owner: ?element.OwnerRef = null;
        if (props.handler) |handler| owner = frame.lookupOwner(handler.target);
        tree.nodes[tree.count] = .{ .key = node.stable_key, .parent = parent, .bounds = bounds, .properties = props, .focus = node.focus, .owner = owner };
        tree.count += 1;
        next_parent = node.stable_key;
        break;
    }
    const p = node.style.padding;
    const child_clip = intersection(clip, .{ .x = node.bounds.x + p.left, .y = node.bounds.y + p.top, .w = @max(0, node.bounds.w - p.left - p.right), .h = @max(0, node.bounds.h - p.top - p.bottom) });
    var child = node.first_child;
    while (child) |i| : (child = frame.nodes[i].next_sibling) visit(frame, i, next_parent, child_clip);
}
