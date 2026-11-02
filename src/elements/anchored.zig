//! Port of GPUI `elements/anchored.rs`: positions children relative to an anchor
//! point and keeps them inside the window.

const std = @import("std");
const geometry = @import("../geometry.zig");
const element_mod = @import("../element.zig");
const window_mod = @import("../window.zig");
const app_mod = @import("../app.zig");
const taffy = @import("../taffy.zig");
const style_mod = @import("../style.zig");

const Window = window_mod.Window;
const App = app_mod.App;
const Pixels = geometry.Pixels;
const Point = geometry.Point;
const Size = geometry.Size;
const Bounds = geometry.Bounds;
const Edges = geometry.Edges;
const Anchor = geometry.Anchor;
const LayoutId = taffy.LayoutId;
const AnyElement = element_mod.AnyElement;
const GlobalElementId = element_mod.GlobalElementId;
const Style = style_mod.Style;

/// Which algorithm to use when fitting the anchored element inside the window.
pub const AnchoredFitMode = union(enum) {
    /// Snap the anchored element to the window edge.
    snap_to_window,
    /// Snap to the window edge and leave the given margins.
    snap_to_window_with_margin: Edges(Pixels),
    /// Switch which corner the anchored element is attached to when it would overflow.
    switch_anchor,
};

/// Which coordinate space the anchor position is interpreted in.
pub const AnchoredPositionMode = enum {
    /// Position the anchored element relative to the window.
    window,
    /// Position the anchored element relative to its parent.
    local,

    fn get_position_and_bounds(
        self: AnchoredPositionMode,
        anchor_position: ?Point(Pixels),
        anchor: Anchor,
        size: Size(Pixels),
        element_bounds: Bounds(Pixels),
        offset: ?Point(Pixels),
    ) struct { Point(Pixels), Bounds(Pixels) } {
        const extra = offset orelse zero_point();
        switch (self) {
            .window => {
                const position = anchor_position orelse element_bounds.origin;
                return .{ position, Bounds(Pixels).from_anchor_and_size(anchor, position.add(extra), size) };
            },
            .local => {
                const position = anchor_position orelse zero_point();
                const origin = element_bounds.origin.add(position).add(extra);
                return .{ position, Bounds(Pixels).from_anchor_and_size(anchor, origin, size) };
            },
        }
    }
};

/// An element that avoids overflowing the window bounds (GPUI `Anchored`).
/// Its children should have no margin, to avoid measurement issues.
pub const Anchored = struct {
    pub const RequestLayoutState = struct { child_layout_ids: []LayoutId };
    pub const PrepaintState = void;

    children_list: element_mod.Children = .empty,
    anchor_corner: Anchor = .top_left,
    fit_mode: AnchoredFitMode = .switch_anchor,
    anchor_position: ?Point(Pixels) = null,
    position_kind: AnchoredPositionMode = .window,
    extra_offset: ?Point(Pixels) = null,

    /// Sets which corner of the anchored element is attached to the anchor position.
    pub fn anchor(self: *Anchored, value: Anchor) *Anchored {
        self.anchor_corner = value;
        return self;
    }

    /// Sets the anchor position in window coordinates, otherwise the element's own origin is used.
    pub fn position(self: *Anchored, value: Point(Pixels)) *Anchored {
        self.anchor_position = value;
        return self;
    }

    /// Offsets the final position by this amount, e.g. to leave a gap from the anchor.
    pub fn offset(self: *Anchored, value: Point(Pixels)) *Anchored {
        self.extra_offset = value;
        return self;
    }

    /// Sets whether `position` is relative to the window or to the parent element.
    pub fn position_mode(self: *Anchored, mode: AnchoredPositionMode) *Anchored {
        self.position_kind = mode;
        return self;
    }

    /// Snaps to the window edge instead of switching the anchor corner on overflow.
    pub fn snap_to_window(self: *Anchored) *Anchored {
        self.fit_mode = .snap_to_window;
        return self;
    }

    /// Snaps to the window edge and leaves `edges` as margins. Accepts `Edges(Pixels)` or a single `Pixels` value.
    pub fn snap_to_window_with_margin(self: *Anchored, edges: anytype) *Anchored {
        self.fit_mode = .{ .snap_to_window_with_margin = edges_from(edges) };
        return self;
    }

    pub fn children_mut(self: *Anchored) *element_mod.Children {
        return &self.children_list;
    }

    pub const child = element_mod.ParentElement(*Anchored).child;
    pub const children = element_mod.ParentElement(*Anchored).children;
    pub const extend = element_mod.ParentElement(*Anchored).extend;

    pub fn request_layout(self: *Anchored, _: ?*const GlobalElementId, window: *Window, cx: *App) struct { LayoutId, RequestLayoutState } {
        const ids = window_mod.frame_arena().alloc(LayoutId, self.children_list.items.len) catch oom();
        for (self.children_list.items, 0..) |child_element, index| ids[index] = child_element.request_layout(window, cx);

        const style: Style = .{ .position = .absolute, .display = .flex };
        return .{ window.request_layout(&style, ids, cx), .{ .child_layout_ids = ids } };
    }

    pub fn prepaint(self: *Anchored, _: ?*const GlobalElementId, bounds: Bounds(Pixels), state: *RequestLayoutState, window: *Window, cx: *App) void {
        const ids = state.child_layout_ids;
        if (ids.len == 0) return;

        var children_bounds = window.layout_bounds(ids[0]);
        for (ids[1..]) |id| children_bounds = union_bounds(children_bounds, window.layout_bounds(id));

        const placement = place(.{
            .anchor = self.anchor_corner,
            .fit_mode = self.fit_mode,
            .position_mode = self.position_kind,
            .anchor_position = self.anchor_position,
            .offset = self.extra_offset,
            .child_size = children_bounds.size,
            .element_bounds = bounds,
            .limits = .{ .origin = zero_point(), .size = window.viewport_size },
        });

        const shift = placement.origin.sub(bounds.origin);
        window.push_element_offset(.{ .x = @round(shift.x), .y = @round(shift.y) });
        defer window.pop_element_offset();
        for (self.children_list.items) |child_element| child_element.prepaint(window, cx);
    }

    pub fn paint(self: *Anchored, _: ?*const GlobalElementId, _: Bounds(Pixels), _: *RequestLayoutState, _: *void, window: *Window, cx: *App) void {
        for (self.children_list.items) |child_element| child_element.paint(window, cx);
    }
};

/// GPUI `anchored()`: an element that avoids overflowing the window bounds.
pub fn anchored() *Anchored {
    const element = window_mod.frame_arena().create(Anchored) catch oom();
    element.* = .{};
    return element;
}

/// Inputs to the anchored placement computation.
pub const Placement = struct {
    anchor: Anchor,
    fit_mode: AnchoredFitMode,
    position_mode: AnchoredPositionMode,
    anchor_position: ?Point(Pixels),
    offset: ?Point(Pixels),
    child_size: Size(Pixels),
    element_bounds: Bounds(Pixels),
    limits: Bounds(Pixels),
};

/// Computes the absolute origin of the anchored children, given the anchored layout and the window limits.
pub fn place(input: Placement) Bounds(Pixels) {
    const origin, var desired = input.position_mode.get_position_and_bounds(
        input.anchor_position,
        input.anchor,
        input.child_size,
        input.element_bounds,
        input.offset,
    );
    const limits = input.limits;

    if (input.fit_mode == .switch_anchor) {
        var anchor = input.anchor;

        if (desired.left() < limits.left() or desired.right() > limits.right()) {
            const switched = Bounds(Pixels).from_anchor_and_size(anchor.other_side_along(.horizontal), origin, input.child_size);
            if (!(switched.left() < limits.left() or switched.right() > limits.right())) {
                anchor = anchor.other_side_along(.horizontal);
                desired = switched;
            }
        }

        if (desired.top() < limits.top() or desired.bottom() > limits.bottom()) {
            const switched = Bounds(Pixels).from_anchor_and_size(anchor.other_side_along(.vertical), origin, input.child_size);
            if (!(switched.top() < limits.top() or switched.bottom() > limits.bottom())) {
                desired = switched;
            }
        }
    }

    const edges: Edges(Pixels) = switch (input.fit_mode) {
        .snap_to_window_with_margin => |margin| margin,
        else => zero_edges(),
    };

    // Overflowing horizontally snaps to the right edge, or aligns left when wider than the window.
    if (desired.right() > limits.right()) {
        desired.origin.x -= desired.right() - limits.right() + edges.right;
    }
    if (desired.left() < limits.left()) {
        desired.origin.x = limits.origin.x + edges.left;
    }

    if (desired.bottom() > limits.bottom()) {
        desired.origin.y -= desired.bottom() - limits.bottom() + edges.bottom;
    }
    if (desired.top() < limits.top()) {
        desired.origin.y = limits.origin.y + edges.top;
    }

    return desired;
}

/// Bounding box of two rectangles (GPUI `Bounds::union`).
fn union_bounds(a: Bounds(Pixels), b: Bounds(Pixels)) Bounds(Pixels) {
    const left = @min(a.left(), b.left());
    const top = @min(a.top(), b.top());
    const right = @max(a.right(), b.right());
    const bottom = @max(a.bottom(), b.bottom());
    return .{ .origin = .{ .x = left, .y = top }, .size = .{ .width = right - left, .height = bottom - top } };
}

fn zero_point() Point(Pixels) {
    return .{ .x = 0, .y = 0 };
}

fn zero_edges() Edges(Pixels) {
    return .{ .top = 0, .right = 0, .bottom = 0, .left = 0 };
}

fn edges_from(value: anytype) Edges(Pixels) {
    if (@TypeOf(value) == Edges(Pixels)) return value;
    const v: Pixels = value;
    return .{ .top = v, .right = v, .bottom = v, .left = v };
}

fn oom() noreturn {
    @panic("out of memory");
}

test "anchored position without scroll" {
    const placed = place(.{
        .anchor = .top_left,
        .fit_mode = .snap_to_window,
        .position_mode = .window,
        .anchor_position = .{ .x = 100, .y = 100 },
        .offset = null,
        .child_size = .{ .width = 200, .height = 300 },
        .element_bounds = .{ .origin = .{ .x = 0, .y = 0 }, .size = .{ .width = 800, .height = 600 } },
        .limits = .{ .origin = zero_point(), .size = .{ .width = 800, .height = 600 } },
    });
    try std.testing.expectEqual(@as(Pixels, 100), placed.origin.x);
    try std.testing.expectEqual(@as(Pixels, 100), placed.origin.y);
    try std.testing.expectEqual(@as(Pixels, 200), placed.size.width);
    try std.testing.expectEqual(@as(Pixels, 300), placed.size.height);
}

test "anchored snaps to window bottom edge" {
    const placed = place(.{
        .anchor = .top_left,
        .fit_mode = .snap_to_window,
        .position_mode = .window,
        .anchor_position = .{ .x = 100, .y = 500 },
        .offset = null,
        .child_size = .{ .width = 200, .height = 300 },
        .element_bounds = .{ .origin = .{ .x = 0, .y = 0 }, .size = .{ .width = 800, .height = 600 } },
        .limits = .{ .origin = zero_point(), .size = .{ .width = 800, .height = 600 } },
    });
    try std.testing.expectEqual(@as(Pixels, 100), placed.origin.x);
    try std.testing.expectEqual(@as(Pixels, 300), placed.origin.y);
}

test "anchored switches anchor corner on horizontal overflow" {
    const placed = place(.{
        .anchor = .top_left,
        .fit_mode = .switch_anchor,
        .position_mode = .window,
        .anchor_position = .{ .x = 700, .y = 100 },
        .offset = null,
        .child_size = .{ .width = 200, .height = 100 },
        .element_bounds = .{ .origin = .{ .x = 0, .y = 0 }, .size = .{ .width = 800, .height = 600 } },
        .limits = .{ .origin = zero_point(), .size = .{ .width = 800, .height = 600 } },
    });
    try std.testing.expectEqual(@as(Pixels, 500), placed.origin.x);
    try std.testing.expectEqual(@as(Pixels, 100), placed.origin.y);
}

test "anchored snap to window with margin keeps the margin" {
    const placed = place(.{
        .anchor = .top_left,
        .fit_mode = .{ .snap_to_window_with_margin = .{ .top = 0, .right = 10, .bottom = 20, .left = 5 } },
        .position_mode = .window,
        .anchor_position = .{ .x = 700, .y = 500 },
        .offset = null,
        .child_size = .{ .width = 200, .height = 300 },
        .element_bounds = .{ .origin = .{ .x = 0, .y = 0 }, .size = .{ .width = 800, .height = 600 } },
        .limits = .{ .origin = zero_point(), .size = .{ .width = 800, .height = 600 } },
    });
    try std.testing.expectEqual(@as(Pixels, 590), placed.origin.x);
    try std.testing.expectEqual(@as(Pixels, 280), placed.origin.y);
    try std.testing.expectEqual(@as(Pixels, 790), placed.right());
    try std.testing.expectEqual(@as(Pixels, 580), placed.bottom());
}

test "anchored local position mode is relative to the parent" {
    const placed = place(.{
        .anchor = .top_left,
        .fit_mode = .snap_to_window,
        .position_mode = .local,
        .anchor_position = .{ .x = 10, .y = 20 },
        .offset = .{ .x = 1, .y = 2 },
        .child_size = .{ .width = 50, .height = 50 },
        .element_bounds = .{ .origin = .{ .x = 100, .y = 200 }, .size = .{ .width = 80, .height = 80 } },
        .limits = .{ .origin = zero_point(), .size = .{ .width = 800, .height = 600 } },
    });
    try std.testing.expectEqual(@as(Pixels, 111), placed.origin.x);
    try std.testing.expectEqual(@as(Pixels, 222), placed.origin.y);
}
