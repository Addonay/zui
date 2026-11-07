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
const Axis = geometry.Axis;
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

/// Where `Anchored.attach` puts the element: `corner` of the element on `corner` of `target` (GPUI `Placement::Attached`).
pub const Attachment = struct {
    target: Bounds(Pixels),
    corner: Anchor,
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
    /// Set by `attach`; takes the place of `anchor_position`.
    attached: ?Attachment = null,
    position_kind: AnchoredPositionMode = .window,
    extra_offset: ?Point(Pixels) = null,

    /// Sets which corner of the anchored element is attached to the anchor position.
    pub fn anchor(self: *Anchored, value: Anchor) *Anchored {
        self.anchor_corner = value;
        return self;
    }

    /// Sets the anchor position in window coordinates, otherwise the element's own origin is used.
    /// Replaces an earlier `attach`.
    pub fn position(self: *Anchored, value: Point(Pixels)) *Anchored {
        self.anchor_position = value;
        self.attached = null;
        return self;
    }

    /// Places the element next to `target`, with the element's `anchor` corner on `corner` of
    /// `target` (GPUI `Anchored::attach`). Use this instead of `position`. For example, a submenu puts
    /// its top-left corner on its row's top-right corner.
    ///
    /// If the element doesn't fit in the window, it moves to the other side of `target`, as long as
    /// that side fits better. A submenu moves from the right of its row to the left, and a dropdown
    /// moves from below its button to above. The offset flips with it. `AnchoredFitMode.switch_anchor`
    /// has no effect here. Replaces an earlier `position`.
    pub fn attach(self: *Anchored, target: Bounds(Pixels), corner: Anchor) *Anchored {
        self.attached = .{ .target = target, .corner = corner };
        self.anchor_position = null;
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
            .attached = self.attached,
            .offset = self.extra_offset,
            .child_size = children_bounds.size,
            .element_bounds = bounds,
            .limits = .{ .origin = zero_point(), .size = window.viewport_size() },
            .client_inset = window.client_inset() orelse 0,
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
    /// From `attach`. It gives the anchor position, and its placement flips sides instead of
    /// `fit_mode`'s anchor switching.
    attached: ?Attachment = null,
    offset: ?Point(Pixels),
    child_size: Size(Pixels),
    element_bounds: Bounds(Pixels),
    limits: Bounds(Pixels),
    /// The shadow area of a client-drawn window. It counts as no room, and margins grow by it.
    client_inset: Pixels = 0,
};

/// Computes the absolute origin of the anchored children, given the anchored layout and the window limits.
pub fn place(input: Placement) Bounds(Pixels) {
    const anchor_position: ?Point(Pixels) = if (input.attached) |attached| attached.target.corner(attached.corner) else input.anchor_position;
    const origin, var desired = input.position_mode.get_position_and_bounds(
        anchor_position,
        input.anchor,
        input.child_size,
        input.element_bounds,
        input.offset,
    );
    const limits = input.limits;

    if (input.attached) |attached| {
        // Compare against the window edges, not the snap margin, so an element that already fits
        // doesn't move. The client inset doesn't count as room either.
        const visible = limits.inset(input.client_inset);
        var corner = attached.corner;
        var anchor = input.anchor;
        var offset = input.offset orelse zero_point();
        for ([_]Axis{ .horizontal, .vertical }) |axis| {
            const corner_side = side_along(corner, axis);
            const is_outside_target = corner_side != .eq and side_along(anchor, axis) == opposite_side(corner_side);
            const overflow = overflow_along(desired, visible, axis);
            if (!is_outside_target or overflow == 0) continue;

            const flipped_corner = corner.other_side_along(axis);
            const flipped_anchor = anchor.other_side_along(axis);
            const flipped_offset: Point(Pixels) = switch (axis) {
                .horizontal => .{ .x = -offset.x, .y = offset.y },
                .vertical => .{ .x = offset.x, .y = -offset.y },
            };
            const flipped = input.position_mode.get_position_and_bounds(
                attached.target.corner(flipped_corner),
                flipped_anchor,
                input.child_size,
                input.element_bounds,
                flipped_offset,
            ).@"1";
            if (overflow_along(flipped, visible, axis) < overflow) {
                corner = flipped_corner;
                anchor = flipped_anchor;
                offset = flipped_offset;
                desired = flipped;
            }
        }
    } else if (input.fit_mode == .switch_anchor) {
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

    var edges: Edges(Pixels) = switch (input.fit_mode) {
        .snap_to_window_with_margin => |margin| margin,
        else => zero_edges(),
    };
    edges.top += input.client_inset;
    edges.right += input.client_inset;
    edges.bottom += input.client_inset;
    edges.left += input.client_inset;

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

/// Which side of the box along `axis` the anchor is on (GPUI `side_along`).
fn side_along(anchor: Anchor, axis: Axis) std.math.Order {
    return switch (axis) {
        .horizontal => switch (anchor) {
            .top_left, .bottom_left, .left_center => .lt,
            .top_center, .bottom_center => .eq,
            .top_right, .bottom_right, .right_center => .gt,
        },
        .vertical => switch (anchor) {
            .top_left, .top_right, .top_center => .lt,
            .left_center, .right_center => .eq,
            .bottom_left, .bottom_right, .bottom_center => .gt,
        },
    };
}

fn opposite_side(side: std.math.Order) std.math.Order {
    return switch (side) {
        .lt => .gt,
        .eq => .eq,
        .gt => .lt,
    };
}

/// How far `bounds` sticks out of `visible` along `axis`, on both sides together (GPUI `overflow_along`).
fn overflow_along(bounds: Bounds(Pixels), visible: Bounds(Pixels), axis: Axis) Pixels {
    return switch (axis) {
        .horizontal => @max(visible.left() - bounds.left(), 0) + @max(bounds.right() - visible.right(), 0),
        .vertical => @max(visible.top() - bounds.top(), 0) + @max(bounds.bottom() - visible.bottom(), 0),
    };
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

// -- window tests -------------------------------------------------------------

const TestAppContext = @import("../app/test_context.zig").TestAppContext;
const div_mod = @import("div.zig");
const deferred = @import("deferred.zig").deferred;

/// The anchor position read by `AnchoredTestView` on every frame.
var test_anchor_position: Point(Pixels) = .{ .x = 0, .y = 0 };

/// A deferred anchored menu over a scrollable container, like GPUI's `AnchoredTestView`.
const AnchoredTestView = struct {
    pub fn render(_: *AnchoredTestView, _: *Window, _: *app_mod.Context(AnchoredTestView)) *div_mod.Div {
        return div_mod.div().size_full().child(
            div_mod.div().id("scroll-container").size_full()
                .child(div_mod.div().h(geometry.px(2000)).w_full())
                .child(deferred(anchored()
                    .snap_to_window()
                    .position(test_anchor_position)
                    .child(div_mod.div().id("menu").w(geometry.px(200)).h(geometry.px(300)))).priority(1)),
        );
    }

    fn build(_: *Window, app: *App) app_mod.Entity(AnchoredTestView) {
        return app.new(AnchoredTestView{});
    }
};

/// Returns the bounds of the hitbox with the given size, if one was drawn.
fn find_hitbox_bounds(window: *const Window, width: Pixels, height: Pixels) ?Bounds(Pixels) {
    for (window.rendered_frame.hitboxes.items) |hitbox| {
        if (hitbox.bounds.size.width == width and hitbox.bounds.size.height == height) return hitbox.bounds;
    }
    return null;
}

test "anchored: places the menu at the window position without scrolling" {
    var cx = TestAppContext.init();
    defer cx.deinit();
    test_anchor_position = .{ .x = 100, .y = 100 };
    _, const vcx = cx.add_window_view(AnchoredTestView.build);

    const menu = find_hitbox_bounds(vcx.window, 200, 300);
    try std.testing.expect(menu != null);
    try std.testing.expectEqual(@as(Pixels, 100), menu.?.origin.x);
    try std.testing.expectEqual(@as(Pixels, 100), menu.?.origin.y);
}

test "anchored: snaps the menu inside the window bottom edge" {
    var cx = TestAppContext.init();
    defer cx.deinit();
    _, const vcx = cx.add_window_view(AnchoredTestView.build);
    const viewport = vcx.window.viewport_size();
    test_anchor_position = .{ .x = 100, .y = viewport.height - 100 };
    vcx.window.refresh();
    vcx.run_until_parked();

    const menu = find_hitbox_bounds(vcx.window, 200, 300);
    try std.testing.expect(menu != null);
    try std.testing.expectEqual(viewport.height - 300, menu.?.origin.y);
}

test "anchored attach moves to the side with room" {
    // The GPUI test with the same name, run through `place` with its 800x600 window.
    const trigger = struct {
        fn at(x: f32, y: f32) Bounds(Pixels) {
            return .{ .origin = .{ .x = x, .y = y }, .size = .{ .width = 100, .height = 20 } };
        }
    }.at;
    const Case = struct { target: Bounds(Pixels), corner: Anchor, anchor: Anchor, expected: Point(Pixels) };
    // A submenu sits to the right of its trigger, with their top edges lined up.
    // A dropdown sits below its button, with their left edges lined up.
    const cases = [_]Case{
        .{ .target = trigger(100, 100), .corner = .top_right, .anchor = .top_left, .expected = .{ .x = 198, .y = 104 } },
        .{ .target = trigger(550, 100), .corner = .top_right, .anchor = .top_left, .expected = .{ .x = 352, .y = 104 } },
        .{ .target = trigger(100, 400), .corner = .bottom_left, .anchor = .top_left, .expected = .{ .x = 98, .y = 96 } },
        // Ends 4px from the window edge: inside the snap margin but still fits, so it stays.
        .{ .target = trigger(498, 100), .corner = .top_right, .anchor = .top_left, .expected = .{ .x = 596, .y = 104 } },
        // Doesn't fit on either side. The left sticks out less, so it goes left and slides back in.
        .{ .target = .{ .origin = .{ .x = 180, .y = 100 }, .size = .{ .width = 500, .height = 20 } }, .corner = .top_right, .anchor = .top_left, .expected = .{ .x = 8, .y = 104 } },
        // Doesn't fit on either side, but the right sticks out less, so it stays right and slides back.
        .{ .target = .{ .origin = .{ .x = 50, .y = 100 }, .size = .{ .width = 650, .height = 20 } }, .corner = .top_right, .anchor = .top_left, .expected = .{ .x = 592, .y = 104 } },
        // A dropdown that runs off the right edge slides left. It never moves beside its button.
        .{ .target = trigger(700, 100), .corner = .bottom_left, .anchor = .top_left, .expected = .{ .x = 592, .y = 124 } },
        // Centered under its button, so it can move above it but never sideways.
        .{ .target = trigger(100, 400), .corner = .bottom_center, .anchor = .top_center, .expected = .{ .x = 48, .y = 96 } },
    };
    for (cases) |c| {
        const placed = place(.{
            .anchor = c.anchor,
            .fit_mode = .{ .snap_to_window_with_margin = .{ .top = 8, .right = 8, .bottom = 8, .left = 8 } },
            .position_mode = .window,
            .anchor_position = null,
            .attached = .{ .target = c.target, .corner = c.corner },
            .offset = .{ .x = -2, .y = 4 },
            .child_size = .{ .width = 200, .height = 300 },
            .element_bounds = .{ .origin = .{ .x = 0, .y = 0 }, .size = .{ .width = 0, .height = 0 } },
            .limits = .{ .origin = zero_point(), .size = .{ .width = 800, .height = 600 } },
        });
        try std.testing.expectEqual(c.expected.x, placed.origin.x);
        try std.testing.expectEqual(c.expected.y, placed.origin.y);
    }
}
