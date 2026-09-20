//! GPUI-compatible anchored placement without owning a renderer.
//!
//! `Anchored` computes the child rectangle from an anchor point and viewport.
//! The caller inserts the returned rectangle into its normal element tree;
//! this module deliberately emits no scene primitives.

const core = @import("../core/root.zig");

pub const Anchor = enum { top_left, top_right, bottom_left, bottom_right };
pub const PositionMode = enum { window, local };
pub const FitMode = union(enum) { switch_anchor, snap_to_window, snap_to_window_with_margin: Edges };
pub const Edges = struct { left: f32 = 0, top: f32 = 0, right: f32 = 0, bottom: f32 = 0 };

pub const Anchored = struct {
    anchor_corner: Anchor = .top_left,
    fit_mode: FitMode = .switch_anchor,
    position_mode: PositionMode = .window,
    position: ?core.Point = null,
    offset: core.Point = .{},

    pub fn init() Anchored {
        return .{};
    }
    pub fn anchor(self: Anchored, value: Anchor) Anchored {
        var out = self;
        out.anchor_corner = value;
        return out;
    }
    pub fn at(self: Anchored, value: core.Point) Anchored {
        var out = self;
        out.position = value;
        return out;
    }
    pub fn offsetBy(self: Anchored, value: core.Point) Anchored {
        var out = self;
        out.offset = value;
        return out;
    }
    pub fn local(self: Anchored) Anchored {
        var out = self;
        out.position_mode = .local;
        return out;
    }
    pub fn snapToWindow(self: Anchored) Anchored {
        var out = self;
        out.fit_mode = .snap_to_window;
        return out;
    }
    pub fn snapToWindowWithMargin(self: Anchored, edges: Edges) Anchored {
        var out = self;
        out.fit_mode = .{ .snap_to_window_with_margin = edges };
        return out;
    }

    pub fn layout(self: Anchored, parent: core.Rect, child: core.Size, viewport: core.Rect) core.Rect {
        const base: core.Point = self.position orelse if (self.position_mode == .window) .{ .x = parent.x, .y = parent.y } else .{ .x = 0, .y = 0 };
        const p: core.Point = if (self.position_mode == .local) .{ .x = parent.x + base.x + self.offset.x, .y = parent.y + base.y + self.offset.y } else .{ .x = base.x + self.offset.x, .y = base.y + self.offset.y };
        var corner = self.anchor_corner;
        var desired = place(corner, p, child);
        if (self.fit_mode == .switch_anchor) {
            if (desired.x < viewport.x or desired.x + desired.w > viewport.x + viewport.w) {
                const switched = place(horizontalFlip(corner), p, child);
                if (switched.x >= viewport.x and switched.x + switched.w <= viewport.x + viewport.w) {
                    corner = horizontalFlip(corner);
                    desired = switched;
                }
            }
            if (desired.y < viewport.y or desired.y + desired.h > viewport.y + viewport.h) {
                const switched = place(verticalFlip(corner), p, child);
                if (switched.y >= viewport.y and switched.y + switched.h <= viewport.y + viewport.h) desired = switched;
            }
        }
        const margin = switch (self.fit_mode) {
            .snap_to_window_with_margin => |e| e,
            else => Edges{},
        };
        if (self.fit_mode != .switch_anchor) {
            if (desired.x + desired.w > viewport.x + viewport.w) desired.x = viewport.x + viewport.w - margin.right - desired.w;
            if (desired.y + desired.h > viewport.y + viewport.h) desired.y = viewport.y + viewport.h - margin.bottom - desired.h;
            if (desired.x < viewport.x) desired.x = viewport.x + margin.left;
            if (desired.y < viewport.y) desired.y = viewport.y + margin.top;
        }
        return desired;
    }
};

fn place(anchor: Anchor, p: core.Point, s: core.Size) core.Rect {
    return .{ .x = if (anchor == .top_right or anchor == .bottom_right) p.x - s.w else p.x, .y = if (anchor == .bottom_left or anchor == .bottom_right) p.y - s.h else p.y, .w = s.w, .h = s.h };
}
fn horizontalFlip(a: Anchor) Anchor {
    return switch (a) {
        .top_left => .top_right,
        .top_right => .top_left,
        .bottom_left => .bottom_right,
        .bottom_right => .bottom_left,
    };
}
fn verticalFlip(a: Anchor) Anchor {
    return switch (a) {
        .top_left => .bottom_left,
        .top_right => .bottom_right,
        .bottom_left => .top_left,
        .bottom_right => .top_right,
    };
}
fn inside(a: core.Rect, v: core.Rect) bool {
    return a.x >= v.x and a.y >= v.y and a.x + a.w <= v.x + v.w and a.y + a.h <= v.y + v.h;
}

test "anchored switches and snaps without scene output" {
    const viewport = core.rect(0, 0, 100, 100);
    const switched = Anchored.init().anchor(.top_left).at(.{ .x = 90, .y = 90 }).layout(viewport, .{ .w = 20, .h = 20 }, viewport);
    try @import("std").testing.expectEqual(@as(f32, 70), switched.x);
    try @import("std").testing.expectEqual(@as(f32, 70), switched.y);
    const snapped = Anchored.init().anchor(.top_left).at(.{ .x = 95, .y = 95 }).snapToWindowWithMargin(.{ .left = 3, .top = 4, .right = 5, .bottom = 6 }).layout(viewport, .{ .w = 20, .h = 20 }, viewport);
    try @import("std").testing.expectEqual(@as(f32, 75), snapped.x);
    try @import("std").testing.expectEqual(@as(f32, 74), snapped.y);
}
