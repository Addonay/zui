//! GPUI `Empty`: an element that renders nothing.

const element_mod = @import("../element.zig");
const window_mod = @import("../window.zig");
const taffy = @import("../taffy.zig");
const geometry = @import("../geometry.zig");
const style_mod = @import("../style.zig");

pub const Empty = struct {
    pub const RequestLayoutState = void;
    pub const PrepaintState = void;

    pub fn request_layout(_: *Empty, _: ?*const element_mod.GlobalElementId, window: *window_mod.Window, cx: *@import("../app.zig").App) struct { taffy.LayoutId, void } {
        const style: style_mod.Style = .{};
        return .{ window.request_layout(&style, &.{}, cx), {} };
    }
    pub fn prepaint(_: *Empty, _: ?*const element_mod.GlobalElementId, _: geometry.Bounds(geometry.Pixels), _: *void, _: *window_mod.Window, _: *@import("../app.zig").App) void {}
    pub fn paint(_: *Empty, _: ?*const element_mod.GlobalElementId, _: geometry.Bounds(geometry.Pixels), _: *void, _: *void, _: *window_mod.Window, _: *@import("../app.zig").App) void {}
};

var empty_instance: Empty = .{};

/// An element that renders nothing.
pub fn empty() element_mod.AnyElement {
    return element_mod.AnyElement.new(&empty_instance);
}
