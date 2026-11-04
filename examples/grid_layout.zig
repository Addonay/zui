//! Port of GPUI's `examples/grid_layout.rs`.
//!
//! Font loading (`example_support::load_fonts`) is not ported (no `TextSystem::add_fonts` yet).
//!
//! `container_query` is not in ZUI's src yet, so its element (GPUI `elements/container_query.rs`)
//! is written out in this file as `ContainerQuery`.

const std = @import("std");
const gpui = @import("zui");
const App = gpui.App;
const AnyElement = gpui.AnyElement;
const AvailableSpace = gpui.AvailableSpace;
const Bounds = gpui.Bounds;
const Context = gpui.Context;
const GlobalElementId = gpui.GlobalElementId;
const Hsla = gpui.Hsla;
const LayoutId = gpui.LayoutId;
const Pixels = gpui.Pixels;
const Size = gpui.Size;
const Style = gpui.Style;
const Window = gpui.Window;
const WindowBounds = gpui.WindowBounds;
const WindowOptions = gpui.WindowOptions;
const div = gpui.div;
const px = gpui.px;
const relative = gpui.relative;
const rgb = gpui.rgb;
const size = gpui.size;

/// GPUI `ContainerQuery`: lays out at its parent's size, then calls `render` with the size
/// it was given and lays the returned element out at that size.
const ContainerQuery = struct {
    render: *const fn (container_size: Size(Pixels), window: *Window, cx: *App) AnyElement,
    style: Style,

    pub const RequestLayoutState = void;
    pub const PrepaintState = ?AnyElement;

    pub fn request_layout(self: *ContainerQuery, _: ?*const GlobalElementId, window: *Window, cx: *App) struct { LayoutId, void } {
        return .{ window.request_layout(&self.style, &.{}, cx), {} };
    }

    pub fn prepaint(self: *ContainerQuery, _: ?*const GlobalElementId, bounds: Bounds(Pixels), _: *void, window: *Window, cx: *App) ?AnyElement {
        var child = self.render(bounds.size, window, cx);
        _ = child.layout_as_root(.{
            .width = AvailableSpace{ .definite = bounds.size.width },
            .height = AvailableSpace{ .definite = bounds.size.height },
        }, window, cx);
        child.prepaint_at(bounds.origin, window, cx);
        return child;
    }

    pub fn paint(_: *ContainerQuery, _: ?*const GlobalElementId, _: Bounds(Pixels), _: *void, prepaint_state: *?AnyElement, window: *Window, cx: *App) void {
        if (prepaint_state.*) |child| child.paint(window, cx);
    }
};

/// GPUI `container_query(render)`. The element fills its parent (`size_full`).
fn container_query(render: *const fn (container_size: Size(Pixels), window: *Window, cx: *App) AnyElement) AnyElement {
    var style: Style = .{};
    style.size.width = gpui.geometry.to_length(relative(1.0));
    style.size.height = gpui.geometry.to_length(relative(1.0));
    const element = gpui.window.frame_arena().create(ContainerQuery) catch @panic("OOM");
    element.* = .{ .render = render, .style = style };
    return AnyElement.new(element);
}

// https://en.wikipedia.org/wiki/Holy_grail_(web_design)
//
// Resize the window: the layout is chosen by `container_query` based on the
// measured size of the container, collapsing to a single stacked column when
// it becomes too narrow for the three-column grid.
const HolyGrailExample = struct {
    fn block(color: Hsla) *gpui.Div {
        return div()
            .size_full()
            .bg(color)
            .border_1()
            .border_dashed()
            .rounded_md()
            .border_color(gpui.white())
            .items_center();
    }

    fn layout(container_size: Size(Pixels), _: *Window, _: *App) AnyElement {
        const header = block(gpui.white()).child(gpui.format("Header — {d}", .{container_size.width}));
        const table_of_contents = block(gpui.red()).child("Table of contents");
        const content = block(gpui.green()).child("Content");
        const ad = block(gpui.blue()).child("AD :(").text_color(gpui.white());
        const footer = block(gpui.black())
            .text_color(gpui.white())
            .child("Footer");

        const container = div().gap_1().bg(rgb(0x505050)).shadow_lg().size_full();

        if (container_size.width < px(400.0)) {
            return gpui.into_any_element(container
                .flex()
                .flex_col()
                .child(header.h_12().flex_none())
                .child(table_of_contents.h_20().flex_none())
                .child(content.flex_1())
                .child(ad.h_20().flex_none())
                .child(footer.h_12().flex_none()));
        } else {
            return gpui.into_any_element(container
                .grid()
                .grid_cols(5)
                .grid_rows(5)
                .child(header.row_span(1).col_span_full())
                .child(table_of_contents.col_span(1).h_56())
                .child(content.col_span(3).row_span(3))
                .child(ad.col_span(1).row_span(3))
                .child(footer.row_span(1).col_span_full()));
        }
    }

    pub fn render(_: *HolyGrailExample, _: *Window, _: *Context(HolyGrailExample)) AnyElement {
        return container_query(layout);
    }
};

fn run_example(cx: *App) void {
    // example_support::load_fonts is not ported (no TextSystem::add_fonts yet).
    const bounds = Bounds(Pixels).centered(null, size(px(500.0), px(500.0)), cx);
    _ = cx.open_window(.{ .window_bounds = .{ .windowed = bounds } }, struct {
        fn build(_: *Window, app: *App) gpui.Entity(HolyGrailExample) {
            return app.new(HolyGrailExample{});
        }
    }.build) catch unreachable;
    cx.activate(true);
}

pub fn main() void {
    gpui.Application.new().run(run_example);
}
