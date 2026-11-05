//! Port of GPUI's `examples/on_window_close_quit.rs`.
//!
//! Differences from the Rust version:
//! - Font loading (`example_support::load_fonts`) is not ported (no `TextSystem::add_fonts` yet).
//! - `cx.windows().is_empty()` is `cx.window_count() == 0`, since ZUI has no handle list.
//! - Closing the window (cmd-w, or the window manager's close button) quits the app through
//!   `on_window_closed`. The process exits with status 0 once the last window is gone.

const gpui = @import("zui");
const App = gpui.App;
const Bounds = gpui.Bounds;
const Context = gpui.Context;
const Div = gpui.Div;
const Entity = gpui.Entity;
const FocusHandle = gpui.FocusHandle;
const KeyBinding = gpui.KeyBinding;
const Pixels = gpui.Pixels;
const Window = gpui.Window;
const WindowId = gpui.WindowId;
const div = gpui.div;
const px = gpui.px;
const rgb = gpui.rgb;
const size = gpui.size;

const CloseWindow = gpui.Action("example", "CloseWindow");

const ExampleWindow = struct {
    focus_handle: FocusHandle,

    fn close_window(_: *const CloseWindow, window: *Window, _: *App) void {
        window.remove_window();
    }

    pub fn render(self: *ExampleWindow, _: *Window, _: *Context(ExampleWindow)) *Div {
        return div()
            .on_action(CloseWindow, close_window)
            .track_focus(&self.focus_handle)
            .flex()
            .flex_col()
            .gap_3()
            .bg(rgb(0x505050))
            .size(px(500.0))
            .justify_center()
            .items_center()
            .shadow_lg()
            .border_1()
            .border_color(rgb(0x0000ff))
            .text_xl()
            .text_color(rgb(0xffffff))
            .child("Closing this window with cmd-w or the traffic lights should quit the application!");
    }
};

fn build_window(window: *Window, app: *App) Entity(ExampleWindow) {
    const focus_handle = app.focus_handle();
    window.focus(focus_handle);
    return app.new(ExampleWindow{ .focus_handle = focus_handle });
}

fn build_first_window(window: *Window, app: *App) Entity(ExampleWindow) {
    app.activate(false);
    return build_window(window, app);
}

fn on_window_closed(cx: *App, _: WindowId) void {
    if (cx.window_count() == 0) cx.quit();
}

fn run_example(cx: *App) void {
    // example_support::load_fonts is not ported (no TextSystem::add_fonts yet).
    var bounds = Bounds(Pixels).centered(null, size(px(500.0), px(500.0)), cx);

    cx.bind_keys(&.{KeyBinding.new("cmd-w", CloseWindow{}, null)});
    _ = cx.on_window_closed(on_window_closed);

    _ = cx.open_window(.{ .window_bounds = .{ .windowed = bounds } }, build_first_window) catch unreachable;

    bounds.origin.x += bounds.size.width;

    _ = cx.open_window(.{ .window_bounds = .{ .windowed = bounds } }, build_window) catch unreachable;
}

pub fn main() void {
    gpui.Application.new().run(run_example);
}
