//! GPUI `container_query` (`elements/container_query.rs`): contents chosen from the size the
//! element is given by its parent. The element fills its parent unless styled otherwise, and its
//! children cannot change its size because they do not exist until after layout.

const std = @import("std");
const geometry = @import("../geometry.zig");
const element_mod = @import("../element.zig");
const window_mod = @import("../window.zig");
const app_mod = @import("../app.zig");
const taffy = @import("../taffy.zig");
const style_mod = @import("../style.zig");
const div_mod = @import("div.zig");

const App = app_mod.App;
const Window = window_mod.Window;
const Pixels = geometry.Pixels;
const Size = geometry.Size;
const Bounds = geometry.Bounds;
const AnyElement = element_mod.AnyElement;
const AvailableSpace = taffy.AvailableSpace;

/// The element-specific part of a `ContainerQuery`: its render callback and the child it produced.
pub const ContainerQueryExt = struct {
    render: ?*const fn (size: Size(Pixels), window: *Window, cx: *App) AnyElement = null,
    child: ?AnyElement = null,

    /// Lays the render result out at the size this element was given, then places it at its origin.
    pub fn prepaint_ext(self: *ContainerQuery, bounds: Bounds(Pixels), window: *Window, cx: *App) void {
        const render = self.ext.render orelse return;
        var child = render(bounds.size, window, cx);
        _ = child.layout_as_root(.{
            .width = AvailableSpace{ .definite = bounds.size.width },
            .height = AvailableSpace{ .definite = bounds.size.height },
        }, window, cx);
        child.prepaint_at(bounds.origin, window, cx);
        self.ext.child = child;
    }

    pub fn paint_ext(self: *ContainerQuery, _: Bounds(Pixels), _: *const style_mod.Style, window: *Window, cx: *App) void {
        if (self.ext.child) |child| child.paint(window, cx);
    }
};

/// GPUI `ContainerQuery`. Styled like any element; `size_full` is its default size.
pub const ContainerQuery = div_mod.StyledElement(ContainerQueryExt);

/// GPUI `container_query(render)`. `render` gets the size the element was assigned and returns any
/// `IntoElement` value. It runs in prepaint, once per frame, as GPUI's does.
pub fn container_query(comptime render: anytype) *ContainerQuery {
    const Wrapper = struct {
        fn call(size: Size(Pixels), window: *Window, cx: *App) AnyElement {
            return element_mod.into_any_element(render(size, window, cx));
        }
    };
    const element = ContainerQuery.new();
    element.ext.render = Wrapper.call;
    return element.size_full();
}

// -- tests --------------------------------------------------------------------

const TestAppContext = @import("../app/test_context.zig").TestAppContext;
const Context = app_mod.Context;

/// The size the last render call received, and how many times it ran.
var test_seen_size: ?Size(Pixels) = null;
var test_render_count: usize = 0;

fn record_size(size: Size(Pixels), _: *Window, _: *App) AnyElement {
    test_seen_size = size;
    test_render_count += 1;
    return div_mod.div().into_any_element();
}

const ContainerQueryView = struct {
    pub fn render(_: *ContainerQueryView, _: *Window, _: *Context(ContainerQueryView)) *div_mod.Div {
        return div_mod.div().size_full().child(container_query(record_size));
    }

    fn build(_: *Window, app: *App) app_mod.Entity(ContainerQueryView) {
        return app.new(ContainerQueryView{});
    }
};

test "container_query renders once with the size its parent gave it" {
    var cx = TestAppContext.init();
    defer cx.deinit();
    test_seen_size = null;
    test_render_count = 0;
    _, const vcx = cx.add_window_view(ContainerQueryView.build);
    try std.testing.expectEqual(@as(usize, 1), test_render_count);
    const seen = test_seen_size orelse return error.TestExpectedEqual;
    try std.testing.expectEqual(vcx.window.viewport_size().width, seen.width);
    try std.testing.expectEqual(vcx.window.viewport_size().height, seen.height);
}
