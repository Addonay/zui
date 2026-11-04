//! Port of GPUI's `examples/uniform_list.rs`.
//!
//! Font loading (`example_support::load_fonts`) is not ported (no `TextSystem::add_fonts` yet).
//! The Rust `println!` in the click handler becomes `std.debug.print`.

const std = @import("std");
const gpui = @import("zui");
const App = gpui.App;
const AnyElement = gpui.AnyElement;
const Bounds = gpui.Bounds;
const ClickEvent = gpui.ClickEvent;
const Context = gpui.Context;
const Window = gpui.Window;
const WindowBounds = gpui.WindowBounds;
const WindowOptions = gpui.WindowOptions;
const div = gpui.div;
const px = gpui.px;
const rgb = gpui.rgb;
const size = gpui.size;
const uniform_list = gpui.uniform_list;
const Range = gpui.Range;

const UniformListExample = struct {
    fn on_item_click(_: *UniformListExample, item: usize, _: *const ClickEvent, _: *Window, _: *Context(UniformListExample)) void {
        std.debug.print("clicked Item {d}\n", .{item});
    }

    fn render_items(this: *UniformListExample, range: Range, _: *Window, cx: *Context(UniformListExample)) []AnyElement {
        _ = this;
        const alloc = gpui.window.frame_arena();
        var items: std.ArrayList(AnyElement) = .empty;
        var ix = range.start;
        while (ix < range.end) : (ix += 1) {
            const item = ix + 1;

            items.append(alloc, gpui.into_any_element(
                div()
                    .id(ix)
                    .px_2()
                    .cursor_pointer()
                    .on_click(cx.listener_with(item, on_item_click))
                    .child(gpui.format("Item {d}", .{item})),
            )) catch @panic("OOM");
        }
        return items.items;
    }

    pub fn render(_: *UniformListExample, _: *Window, cx: *Context(UniformListExample)) *gpui.Div {
        return div().size_full().bg(rgb(0xffffff)).child(
            uniform_list("entries", 50, cx.processor(render_items)).h_full(),
        );
    }
};

fn run_example(cx: *App) void {
    // example_support::load_fonts is not ported (no TextSystem::add_fonts yet).
    const bounds = Bounds(gpui.Pixels).centered(null, size(px(300.0), px(300.0)), cx);
    _ = cx.open_window(.{ .window_bounds = .{ .windowed = bounds } }, struct {
        fn build(_: *Window, app: *App) gpui.Entity(UniformListExample) {
            return app.new(UniformListExample{});
        }
    }.build) catch unreachable;
}

pub fn main() void {
    gpui.Application.new().run(run_example);
}
