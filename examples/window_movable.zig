//! Port of GPUI's `examples/window_movable.rs`.
//!
//! Differences from the Rust version:
//! - Font loading (`example_support::load_fonts`) is not ported (no `TextSystem::add_fonts` yet).
//! - The labels are built with `std.fmt.comptimePrint`, since each window's flags are comptime
//!   constants here and the window keeps its label for its whole life.
//! - `is_movable` and `app_owns_titlebar_drag` are stored but have no effect on Linux, as in GPUI:
//!   its Linux platforms ignore both, so the window manager keeps moving every window. Only the
//!   titlebar text and `appears_transparent` reach the platform.

const std = @import("std");
const gpui = @import("zui");
const App = gpui.App;
const Bounds = gpui.Bounds;
const Context = gpui.Context;
const Div = gpui.Div;
const Entity = gpui.Entity;
const FocusHandle = gpui.FocusHandle;
const Pixels = gpui.Pixels;
const Window = gpui.Window;
const WindowOptions = gpui.WindowOptions;
const div = gpui.div;
const px = gpui.px;
const rgb = gpui.rgb;
const size = gpui.size;

const ExampleWindow = struct {
    label: []const u8,
    focus_handle: FocusHandle,

    pub fn render(self: *ExampleWindow, _: *Window, _: *Context(ExampleWindow)) *Div {
        return div()
            .track_focus(&self.focus_handle)
            .flex()
            .flex_col()
            .gap_3()
            .bg(rgb(0x2e2e2e))
            .size_full()
            .justify_center()
            .items_center()
            .p_8()
            .text_lg()
            .text_color(rgb(0xffffff))
            .child(self.label)
            .child(
                div()
                    .text_sm()
                    .text_color(rgb(0xb0b0b0))
                    .child("Try to drag the titlebar, and check the Window menu."),
            );
    }
};

/// The window builder for one test window. The label is comptime, so the builder is too:
/// use `comptime Builder(label).build`.
fn Builder(comptime label: []const u8) type {
    return struct {
        fn build(window: *Window, app: *App) Entity(ExampleWindow) {
            const focus_handle = app.focus_handle();
            window.focus(focus_handle);
            return app.new(ExampleWindow{ .label = label, .focus_handle = focus_handle });
        }
    };
}

fn open_test_window(
    cx: *App,
    bounds: Bounds(Pixels),
    comptime label: []const u8,
    comptime is_movable: bool,
    comptime appears_transparent: bool,
    comptime app_owns_titlebar_drag: bool,
) void {
    const full_label = comptime std.fmt.comptimePrint(
        "{s}\nis_movable: {}\nappears_transparent: {}\napp_owns_titlebar_drag: {}",
        .{ label, is_movable, appears_transparent, app_owns_titlebar_drag },
    );

    _ = cx.open_window(
        WindowOptions{
            .window_bounds = .{ .windowed = bounds },
            .is_movable = is_movable,
            .app_owns_titlebar_drag = app_owns_titlebar_drag,
            .titlebar = .{
                .title = full_label,
                .appears_transparent = appears_transparent,
            },
        },
        comptime Builder(full_label).build,
    ) catch unreachable;
}

fn run_example(cx: *App) void {
    // example_support::load_fonts is not ported (no TextSystem::add_fonts yet).
    const window_size = size(px(420.0), px(280.0));
    const base = Bounds(Pixels).centered(null, window_size, cx);

    // (label, is_movable, appears_transparent, app_owns_titlebar_drag, col, row)
    const windows = .{
        .{ "Native titlebar, movable", true, false, false, 0.0, 0.0 },
        .{ "Native titlebar, NOT movable", false, false, false, 1.0, 0.0 },
        .{ "Custom titlebar, movable", true, true, false, 0.0, 1.0 },
        .{ "Custom titlebar, NOT movable", false, true, false, 1.0, 1.0 },
    };

    inline for (windows) |w| {
        var bounds = base;
        bounds.origin.x += window_size.width * w[4];
        bounds.origin.y += window_size.height * w[5];
        open_test_window(cx, bounds, w[0], w[1], w[2], w[3]);
    }
}

pub fn main() void {
    gpui.Application.new().run(run_example);
}
