//! Port of GPUI's `examples/grid_layout.rs`.
//!
//! Font loading (`example_support::load_fonts`) is not ported (no `TextSystem::add_fonts` yet).

const std = @import("std");
const gpui = @import("zui");
const App = gpui.App;
const AnyElement = gpui.AnyElement;
const Bounds = gpui.Bounds;
const Context = gpui.Context;
const Hsla = gpui.Hsla;
const Pixels = gpui.Pixels;
const Size = gpui.Size;
const Window = gpui.Window;
const WindowBounds = gpui.WindowBounds;
const WindowOptions = gpui.WindowOptions;
const container_query = gpui.container_query;
const div = gpui.div;
const px = gpui.px;
const rgb = gpui.rgb;
const size = gpui.size;

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
        return container_query(layout).into_any_element();
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
