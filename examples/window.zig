//! Port of GPUI's `examples/window.rs`.
//!
//! Differences from the Rust version:
//! - Font loading (`example_support::load_fonts`) is not ported (no `TextSystem::add_fonts` yet).
//! - Prompts are drawn by GPUI's fallback renderer, which Linux uses, and the answer goes to a
//!   plain function instead of a `oneshot` receiver awaited in a spawned task.
//! - "Window bounds changed" is printed by `cx.observe_window_bounds`, on moves and resizes.
//!   Wayland does not report moves, so there the line appears for resizes only.
//! - "Hide Application" restores the app after 3 seconds with a background timer instead of a
//!   spawned task, since ZUI has no async. The timer gets the `App`, which lives for the process.
//! - Each `WindowOptions` the Rust code builds with `..Default::default()` spells out only the
//!   fields that differ, as Zig does.
//! - Closures that capture `window_bounds` are plain functions here: the bounds are computed when
//!   the button is clicked, which is where GPUI's computed them too, on the same centered rect.
//! - Window kinds, `show`, `is_movable` and `is_resizable` are honoured where the platform
//!   supports them. Linux ignores `is_movable`, `is_resizable` and `is_minimizable` (GPUI does
//!   too), so those three buttons open ordinary windows there.

const std = @import("std");
const gpui = @import("zui");
const App = gpui.App;
const Bounds = gpui.Bounds;
const ClickEvent = gpui.ClickEvent;
const Context = gpui.Context;
const Div = gpui.Div;
const KeyBinding = gpui.KeyBinding;
const Pixels = gpui.Pixels;
const Window = gpui.Window;
const WindowBounds = gpui.WindowBounds;
const WindowOptions = gpui.WindowOptions;
const div = gpui.div;
const px = gpui.px;
const rgb = gpui.rgb;
const size = gpui.size;

const Quit = gpui.Action("window", "Quit");

const PromptButton = gpui.PromptButton;

const SubWindow = struct {
    custom_titlebar: bool,
    is_dialog: bool,

    pub fn render(self: *SubWindow, _: *Window, _: *Context(SubWindow)) *Div {
        return div()
            .flex()
            .flex_col()
            .bg(rgb(0xffffff))
            .size_full()
            .gap_2()
            .when(self.custom_titlebar, add_custom_titlebar)
            .child(
                div()
                    .p_8()
                    .flex()
                    .flex_col()
                    .gap_2()
                    .child("SubWindow")
                    .when(self.is_dialog, add_nested_dialog_button)
                    .child(button("Close", close_window)),
            );
    }
};

/// A sub window builder for one combination of its flags. `open_window` takes a plain function,
/// so each combination gets its own, generated at compile time.
fn SubWindowBuilder(comptime custom_titlebar: bool, comptime is_dialog: bool) type {
    return struct {
        fn build(_: *Window, app: *App) gpui.Entity(SubWindow) {
            return app.new(SubWindow{ .custom_titlebar = custom_titlebar, .is_dialog = is_dialog });
        }
    };
}

fn add_custom_titlebar(parent: *Div) *Div {
    return parent.child(
        div()
            .flex()
            .h(px(32.0))
            .px_4()
            .bg(gpui.blue())
            .text_color(gpui.white())
            .w_full()
            .child(
                div()
                    .flex()
                    .items_center()
                    .justify_center()
                    .size_full()
                    .child("Custom Titlebar"),
            ),
    );
}

fn add_nested_dialog_button(parent: *Div) *Div {
    return parent.child(button("Open Nested Dialog", open_nested_dialog));
}

fn button(text: []const u8, comptime on_click: fn (*Window, *App) void) *Div {
    const Click = struct {
        fn handle(_: *const ClickEvent, window: *Window, cx: *App) void {
            on_click(window, cx);
        }
    };
    return div()
        .id(text)
        .flex_none()
        .px_2()
        .bg(rgb(0xf7f7f7))
        .active(gpui.style_refinement().opacity(0.85))
        .border_1()
        .border_color(rgb(0xe0e0e0))
        .rounded_sm()
        .cursor_pointer()
        .child(text)
        .on_click(Click.handle);
}

const WindowDemo = struct {
    pub fn render(_: *WindowDemo, _: *Window, _: *Context(WindowDemo)) *Div {
        return div()
            .p_4()
            .flex()
            .flex_wrap()
            .bg(rgb(0xffffff))
            .size_full()
            .justify_center()
            .content_center()
            .gap_2()
            .child(button("Normal", open_normal))
            .child(button("Popup", open_popup))
            .child(button("Floating", open_floating))
            .child(button("Dialog", open_dialog))
            .child(button("Custom Titlebar", open_custom_titlebar))
            .child(button("Invisible", open_invisible))
            .child(button("Unmovable", open_unmovable))
            .child(button("Unresizable", open_unresizable))
            .child(button("Unminimizable", open_unminimizable))
            .child(button("Hide Application", hide_application))
            .child(button("Resize", resize_window))
            .child(button("Prompt", open_prompt))
            .child(button("Prompt (non-English)", open_prompt_non_english));
    }
};

/// A 300x300 window centered on the primary display, as the buttons open them.
fn centered_300(cx: *App) WindowBounds {
    return .{ .windowed = Bounds(Pixels).centered(null, size(px(300.0), px(300.0)), cx) };
}

fn open_sub_window(cx: *App, options: WindowOptions, comptime custom_titlebar: bool, comptime is_dialog: bool) void {
    _ = cx.open_window(options, SubWindowBuilder(custom_titlebar, is_dialog).build) catch unreachable;
}

fn open_normal(_: *Window, cx: *App) void {
    open_sub_window(cx, .{ .window_bounds = centered_300(cx) }, false, false);
}

fn open_popup(_: *Window, cx: *App) void {
    open_sub_window(cx, .{ .window_bounds = centered_300(cx), .kind = .popup }, false, false);
}

fn open_floating(_: *Window, cx: *App) void {
    open_sub_window(cx, .{ .window_bounds = centered_300(cx), .kind = .floating }, false, false);
}

fn open_dialog(_: *Window, cx: *App) void {
    open_sub_window(cx, .{ .window_bounds = centered_300(cx), .kind = .dialog }, false, true);
}

fn open_custom_titlebar(_: *Window, cx: *App) void {
    open_sub_window(cx, .{ .titlebar = null, .window_bounds = centered_300(cx) }, true, false);
}

fn open_invisible(_: *Window, cx: *App) void {
    open_sub_window(cx, .{ .show = false, .window_bounds = centered_300(cx) }, false, false);
}

fn open_unmovable(_: *Window, cx: *App) void {
    open_sub_window(cx, .{ .is_movable = false, .titlebar = null, .window_bounds = centered_300(cx) }, false, false);
}

fn open_unresizable(_: *Window, cx: *App) void {
    open_sub_window(cx, .{ .is_resizable = false, .window_bounds = centered_300(cx) }, false, false);
}

fn open_unminimizable(_: *Window, cx: *App) void {
    open_sub_window(cx, .{ .is_minimizable = false, .window_bounds = centered_300(cx) }, false, false);
}

fn open_nested_dialog(_: *Window, cx: *App) void {
    const bounds = Bounds(Pixels).centered(null, size(px(250.0), px(200.0)), cx);
    open_sub_window(cx, .{ .window_bounds = .{ .windowed = bounds }, .kind = .dialog }, false, true);
}

fn hide_application(_: *Window, cx: *App) void {
    cx.hide();
    // Restore the application after 3 seconds.
    cx.background_executor().after(cx.foreground_executor(), 3_000_000_000, restore_application, cx);
}

fn restore_application(cx: *App) void {
    cx.activate(false);
}

fn resize_window(window: *Window, _: *App) void {
    const content_size = window.bounds().size;
    window.resize(size(content_size.height, content_size.width));
}

fn close_window(window: *Window, _: *App) void {
    window.remove_window();
}

fn open_prompt(window: *Window, cx: *App) void {
    window.prompt(.info, "Are you sure?", null, &.{ "OK", "Cancel" }, cx, on_prompt_answer);
}

fn open_prompt_non_english(window: *Window, cx: *App) void {
    window.prompt(.info, "Are you sure?", null, &.{ PromptButton{ .ok = "确定" }, PromptButton{ .cancel = "取消" } }, cx, on_prompt_answer);
}

fn on_prompt_answer(response: *const gpui.PromptResponse, _: *Window, _: *App) void {
    if (response.index == 0) {
        std.debug.print("You have clicked Ok\n", .{});
    } else {
        std.debug.print("You have clicked Cancel\n", .{});
    }
}

fn on_bounds_changed(_: *WindowDemo, window: *Window, _: *Context(WindowDemo)) void {
    const bounds = window.bounds();
    std.debug.print("Window bounds changed: origin ({d}, {d}) size {d}x{d}\n", .{
        bounds.origin.x, bounds.origin.y, bounds.size.width, bounds.size.height,
    });
}

fn observe_bounds(self: *WindowDemo, window: *Window, cx: *Context(WindowDemo)) void {
    _ = self;
    _ = cx.observe_window_bounds(window, on_bounds_changed);
}

fn quit(_: *const Quit, cx: *App) void {
    cx.quit();
}

fn build_window(window: *Window, app: *App) gpui.Entity(WindowDemo) {
    const demo = app.new(WindowDemo{});
    demo.update(app, observe_bounds, .{window});
    return demo;
}

fn run_example(cx: *App) void {
    // example_support::load_fonts is not ported (no TextSystem::add_fonts yet).
    const bounds = Bounds(Pixels).centered(null, size(px(800.0), px(600.0)), cx);

    _ = cx.open_window(WindowOptions{
        .window_bounds = .{ .windowed = bounds },
    }, build_window) catch unreachable;

    cx.activate(true);
    cx.on_action(Quit, quit);
    cx.bind_keys(&.{KeyBinding.new("cmd-q", Quit{}, null)});
}

pub fn main() void {
    gpui.Application.new().run(run_example);
}
