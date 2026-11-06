//! Port of GPUI `platform/popup.rs`: parent-anchored popup windows (menus, dropdowns, context
//! menus, tooltips). The platform resolves the final position; Wayland does it through
//! `xdg_popup` and `xdg_positioner`, and X11 and headless reject the kind with
//! `PopupNotSupportedError`, as gpui_linux does on X11.

const std = @import("std");
const geometry = @import("../geometry.zig");
const window_mod = @import("../window.zig");

const Pixels = geometry.Pixels;
const Point = geometry.Point;
const Bounds = geometry.Bounds;

/// Options for a parent-anchored popup window (GPUI `PopupOptions`).
///
/// The popup's size comes from `WindowOptions.window_bounds`, whose origin is ignored. All
/// coordinates are in logical pixels.
pub const PopupOptions = struct {
    /// The window the popup is anchored to.
    parent: window_mod.AnyWindowHandle,
    /// The rectangle the popup is positioned relative to, in the parent window's coordinates.
    anchor_rect: Bounds(Pixels),
    /// Which point of `anchor_rect` the popup is anchored to.
    anchor: PopupAnchor = .center,
    /// The direction in which the popup extends away from the anchor point.
    gravity: PopupGravity = .center,
    /// How the platform may adjust the popup if it would be off-screen.
    constraint_adjustment: PopupConstraintAdjustment = .{},
    /// An additional offset applied after anchoring.
    offset: Point(Pixels) = .{ .x = 0, .y = 0 },
    /// Whether the popup takes an explicit input grab: it takes keyboard focus and is dismissed
    /// when the user clicks outside it. Open grabbing popups from a press handler.
    grab: bool = false,
};

/// The point of the anchor rectangle that a popup is anchored to (GPUI `PopupAnchor`).
pub const PopupAnchor = enum {
    center,
    top,
    bottom,
    left,
    right,
    top_left,
    bottom_left,
    top_right,
    bottom_right,
};

/// The direction in which a popup extends away from its anchor point (GPUI `PopupGravity`).
pub const PopupGravity = enum {
    center,
    top,
    bottom,
    left,
    right,
    top_left,
    bottom_left,
    top_right,
    bottom_right,
};

/// How a popup may be adjusted if the requested placement would put it off-screen (GPUI
/// `PopupConstraintAdjustment`). The bit values are the xdg-shell bitfield.
pub const PopupConstraintAdjustment = packed struct(u32) {
    slide_x: bool = false,
    slide_y: bool = false,
    flip_x: bool = false,
    flip_y: bool = false,
    resize_x: bool = false,
    resize_y: bool = false,
    _padding: u26 = 0,

    pub const SLIDE_X: PopupConstraintAdjustment = .{ .slide_x = true };
    pub const SLIDE_Y: PopupConstraintAdjustment = .{ .slide_y = true };
    pub const FLIP_X: PopupConstraintAdjustment = .{ .flip_x = true };
    pub const FLIP_Y: PopupConstraintAdjustment = .{ .flip_y = true };
    pub const RESIZE_X: PopupConstraintAdjustment = .{ .resize_x = true };
    pub const RESIZE_Y: PopupConstraintAdjustment = .{ .resize_y = true };

    pub fn bits(self: PopupConstraintAdjustment) u32 {
        return @bitCast(self);
    }
};

/// Returned when the platform has no native popup implementation (GPUI `PopupNotSupportedError`).
/// A caller that wants a popup everywhere treats it as a cue to draw an in-window popover.
pub const PopupNotSupportedError = error.PopupNotSupported;

/// The xdg-shell `xdg_positioner.anchor` value for `anchor`. The same numbers serve gravity.
pub fn xdg_anchor(anchor: PopupAnchor) u32 {
    return switch (anchor) {
        .center => 0,
        .top => 1,
        .bottom => 2,
        .left => 3,
        .right => 4,
        .top_left => 5,
        .bottom_left => 6,
        .top_right => 7,
        .bottom_right => 8,
    };
}

/// The xdg-shell `xdg_positioner.gravity` value for `gravity`.
pub fn xdg_gravity(gravity: PopupGravity) u32 {
    return switch (gravity) {
        .center => 0,
        .top => 1,
        .bottom => 2,
        .left => 3,
        .right => 4,
        .top_left => 5,
        .bottom_left => 6,
        .top_right => 7,
        .bottom_right => 8,
    };
}

/// The anchor rectangle as xdg_positioner.set_anchor_rect wants it: relative to the parent's
/// window geometry, and never outside it or empty. GPUI translates the rectangle by the geometry
/// origin, then pulls it at least one pixel inside the geometry, and clamps its bottom-right
/// corner. Returns integer `{x, y, width, height}` in logical pixels.
pub fn anchor_rect_in_geometry(anchor_rect: Bounds(Pixels), geometry_rect: Bounds(Pixels)) [4]i32 {
    const one: f32 = 1;
    const gx = anchor_rect.origin.x - geometry_rect.origin.x;
    const gy = anchor_rect.origin.y - geometry_rect.origin.y;
    const max_x = geometry_rect.size.width - one;
    const max_y = geometry_rect.size.height - one;
    // Origin: at least 0, at most one pixel short of the geometry's far edge.
    const x0 = @max(0, @min(gx, max_x));
    const y0 = @max(0, @min(gy, max_y));
    // Bottom-right: at most the geometry's far edge, at least one pixel past the origin.
    const x1 = @max(x0 + one, @min(gx + anchor_rect.size.width, geometry_rect.size.width));
    const y1 = @max(y0 + one, @min(gy + anchor_rect.size.height, geometry_rect.size.height));
    return .{
        @intFromFloat(x0),
        @intFromFloat(y0),
        @intFromFloat(x1 - x0),
        @intFromFloat(y1 - y0),
    };
}

test "xdg anchor and gravity values follow xdg-shell" {
    try std.testing.expectEqual(@as(u32, 0), xdg_anchor(.center));
    try std.testing.expectEqual(@as(u32, 2), xdg_anchor(.bottom));
    try std.testing.expectEqual(@as(u32, 8), xdg_anchor(.bottom_right));
    try std.testing.expectEqual(@as(u32, 5), xdg_gravity(.top_left));
    try std.testing.expectEqual(@as(u32, 7), xdg_gravity(.top_right));
}

test "constraint adjustment bits match the xdg-shell bitfield" {
    try std.testing.expectEqual(@as(u32, 0), (PopupConstraintAdjustment{}).bits());
    try std.testing.expectEqual(@as(u32, 1 | 4), (PopupConstraintAdjustment{ .slide_x = true, .flip_x = true }).bits());
    try std.testing.expectEqual(@as(u32, 32), PopupConstraintAdjustment.RESIZE_Y.bits());
    try std.testing.expectEqual(@as(u32, 8), PopupConstraintAdjustment.FLIP_Y.bits());
}

test "anchor rect inside the geometry is passed through" {
    const geo: Bounds(Pixels) = .{ .origin = .{ .x = 0, .y = 0 }, .size = .{ .width = 400, .height = 300 } };
    const anchor: Bounds(Pixels) = .{ .origin = .{ .x = 10, .y = 20 }, .size = .{ .width = 30, .height = 40 } };
    try std.testing.expectEqual([4]i32{ 10, 20, 30, 40 }, anchor_rect_in_geometry(anchor, geo));
}

test "anchor rect is translated by the geometry origin" {
    const geo: Bounds(Pixels) = .{ .origin = .{ .x = 5, .y = 7 }, .size = .{ .width = 400, .height = 300 } };
    const anchor: Bounds(Pixels) = .{ .origin = .{ .x = 15, .y = 27 }, .size = .{ .width = 30, .height = 40 } };
    try std.testing.expectEqual([4]i32{ 10, 20, 30, 40 }, anchor_rect_in_geometry(anchor, geo));
}

test "anchor rect outside the geometry is pulled inside, at least one pixel" {
    const geo: Bounds(Pixels) = .{ .origin = .{ .x = 0, .y = 0 }, .size = .{ .width = 100, .height = 100 } };
    // Starts past the far edge: the origin stops one pixel short of it.
    const past: Bounds(Pixels) = .{ .origin = .{ .x = 250, .y = 250 }, .size = .{ .width = 10, .height = 10 } };
    try std.testing.expectEqual([4]i32{ 99, 99, 1, 1 }, anchor_rect_in_geometry(past, geo));
    // Starts before the origin and runs past the far edge: clipped to the geometry.
    const over: Bounds(Pixels) = .{ .origin = .{ .x = -20, .y = -20 }, .size = .{ .width = 500, .height = 500 } };
    try std.testing.expectEqual([4]i32{ 0, 0, 100, 100 }, anchor_rect_in_geometry(over, geo));
    // Empty rectangles become one pixel.
    const empty: Bounds(Pixels) = .{ .origin = .{ .x = 50, .y = 50 }, .size = .{ .width = 0, .height = 0 } };
    try std.testing.expectEqual([4]i32{ 50, 50, 1, 1 }, anchor_rect_in_geometry(empty, geo));
}
