//! Port of GPUI's `examples/window_positioning.rs`.
//!
//! Differences from the Rust version:
//! - Font loading (`example_support::load_fonts`) is not ported (no `TextSystem::add_fonts` yet).
//! - `open_window` takes a plain function that cannot capture, so each window's text, bounds and
//!   color go through `next_content`. The builder reads it inside `open_window`, which calls the
//!   builder before it returns.
//! - Labels are formatted with the app's allocator, not the frame arena: the entity keeps them
//!   for the life of the window.
//! - `Display` is a plain struct here, so `screen.bounds()` and `screen.id()` are the fields
//!   `screen.bounds` and `screen.id`.
//! - `display_id` is passed through but the platforms position windows by their absolute
//!   bounds, which already name the display. Wayland does not let a client place a toplevel, so
//!   on Wayland the windows open where the compositor puts them.
//! - PopUp windows are override-redirect on X11, as in GPUI. Wayland has no pop-up toplevel here
//!   yet, so they open as normal windows there.

const std = @import("std");
const gpui = @import("zui");
const App = gpui.App;
const Bounds = gpui.Bounds;
const Context = gpui.Context;
const Div = gpui.Div;
const Hsla = gpui.Hsla;
const Pixels = gpui.Pixels;
const Size = gpui.Size;
const Window = gpui.Window;
const WindowBackgroundAppearance = gpui.WindowBackgroundAppearance;
const WindowOptions = gpui.WindowOptions;
const div = gpui.div;
const point = gpui.point;
const px = gpui.px;
const rgb = gpui.rgb;

const WindowContent = struct {
    text: []const u8,
    bounds: Bounds(Pixels),
    bg: Hsla,

    pub fn render(self: *WindowContent, window: *Window, _: *Context(WindowContent)) *Div {
        const window_bounds = window.bounds();

        return div()
            .flex()
            .flex_col()
            .bg(self.bg)
            .size_full()
            .items_center()
            .text_color(rgb(0xffffff))
            .child(self.text)
            .child(
                div()
                    .flex()
                    .flex_col()
                    .text_sm()
                    .items_center()
                    .size_full()
                    .child(gpui.format("origin: {d}, {d} size: {d}, {d}", .{
                        self.bounds.origin.x,
                        self.bounds.origin.y,
                        self.bounds.size.width,
                        self.bounds.size.height,
                    }))
                    .child(gpui.format("cx.bounds() origin: {d}, {d} size {d}, {d}", .{
                        window_bounds.origin.x,
                        window_bounds.origin.y,
                        window_bounds.size.width,
                        window_bounds.size.height,
                    })),
            );
    }
};

const NextContent = struct {
    label: []const u8,
    display_id: u32,
    bounds: Bounds(Pixels),
    bg: Hsla,
};

/// The content of the window `open_window` is building right now; see the header.
var next_content: NextContent = undefined;

fn build_content(_: *Window, app: *App) gpui.Entity(WindowContent) {
    const text = std.fmt.allocPrint(app.allocator, "{s} {d}", .{ next_content.label, next_content.display_id }) catch @panic("OOM");
    return app.new(WindowContent{
        .text = text,
        .bounds = next_content.bounds,
        .bg = next_content.bg,
    });
}

fn build_window_options(display_id: u32, bounds: Bounds(Pixels)) WindowOptions {
    return .{
        // Set the bounds of the window in screen coordinates.
        .window_bounds = .{ .windowed = bounds },
        // Specify the display_id to ensure the window is created on the correct screen.
        .display_id = display_id,
        .titlebar = null,
        .window_background = WindowBackgroundAppearance.transparent,
        .focus = false,
        .show = true,
        .kind = .popup,
        .is_movable = false,
        .app_id = null,
        .window_min_size = null,
        .window_decorations = null,
    };
}

fn open_content(cx: *App, display_id: u32, bounds: Bounds(Pixels), label: []const u8, bg: Hsla) void {
    next_content = .{ .label = label, .display_id = display_id, .bounds = bounds, .bg = bg };
    _ = cx.open_window(build_window_options(display_id, bounds), build_content) catch unreachable;
}

fn run_example(cx: *App) void {
    // example_support::load_fonts is not ported (no TextSystem::add_fonts yet).

    // Create several new windows, positioned in the top right corner of each screen.
    const window_size = Size(Pixels){
        .width = px(350.0),
        .height = px(75.0),
    };
    const margin_offset = px(150.0);

    for (cx.displays()) |screen| {
        const screen_bounds = screen.bounds;

        open_content(cx, screen.id, .{
            .origin = screen_bounds.origin.add(point(margin_offset, margin_offset)),
            .size = window_size,
        }, "Top Left", gpui.red());

        open_content(cx, screen.id, .{
            .origin = screen_bounds.top_right().sub(point(window_size.width + margin_offset, -margin_offset)),
            .size = window_size,
        }, "Top Right", gpui.red());

        open_content(cx, screen.id, .{
            .origin = screen_bounds.bottom_left().sub(point(-margin_offset, window_size.height + margin_offset)),
            .size = window_size,
        }, "Bottom Left", gpui.blue());

        open_content(cx, screen.id, .{
            .origin = screen_bounds.bottom_right().sub(point(window_size.width + margin_offset, window_size.height + margin_offset)),
            .size = window_size,
        }, "Bottom Right", gpui.blue());

        open_content(cx, screen.id, .{
            .origin = point(
                screen_bounds.center().x - window_size.center().x,
                screen_bounds.top() + margin_offset,
            ),
            .size = window_size,
        }, "Top Center", gpui.black());

        open_content(cx, screen.id, .{
            .origin = point(
                screen_bounds.left() + margin_offset,
                screen_bounds.center().y - window_size.center().y,
            ),
            .size = window_size,
        }, "Left Center", gpui.black());

        open_content(cx, screen.id, .{
            .origin = point(
                screen_bounds.center().x - window_size.center().x,
                screen_bounds.center().y - window_size.center().y,
            ),
            .size = window_size,
        }, "Center", gpui.black());

        open_content(cx, screen.id, .{
            .origin = point(
                screen_bounds.right() - window_size.width - margin_offset,
                screen_bounds.center().y - window_size.center().y,
            ),
            .size = window_size,
        }, "Right Center", gpui.black());

        open_content(cx, screen.id, .{
            .origin = point(
                screen_bounds.center().x - window_size.center().x,
                screen_bounds.bottom() - window_size.height - margin_offset,
            ),
            .size = window_size,
        }, "Bottom Center", gpui.black());
    }
}

pub fn main() void {
    gpui.Application.new().run(run_example);
}
