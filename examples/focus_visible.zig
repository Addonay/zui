//! Port of GPUI's `examples/focus_visible.rs`.
//!
//! Font loading (`example_support::load_fonts`) is not ported (no `TextSystem::add_fonts` yet).

const gpui = @import("zui");
const App = gpui.App;
const Bounds = gpui.Bounds;
const ClickEvent = gpui.ClickEvent;
const Context = gpui.Context;
const Div = gpui.Div;
const FocusHandle = gpui.FocusHandle;
const KeyBinding = gpui.KeyBinding;
const SharedString = []const u8;
const Window = gpui.Window;
const WindowBounds = gpui.WindowBounds;
const WindowOptions = gpui.WindowOptions;
const div = gpui.div;
const px = gpui.px;
const size = gpui.size;

const Tab = gpui.Action("example", "Tab");
const TabPrev = gpui.Action("example", "TabPrev");
const Quit = gpui.Action("example", "Quit");

const Example = struct {
    focus_handle: FocusHandle,
    /// `(FocusHandle, &'static str)` in Rust.
    items: [3]struct { FocusHandle, []const u8 },
    message: SharedString,

    fn new(window: *Window, cx: *App) Example {
        const items = [3]struct { FocusHandle, []const u8 }{
            .{
                cx.focus_handle().tab_index(1).tab_stop(true),
                "Button with .focus() - always shows border when focused",
            },
            .{
                cx.focus_handle().tab_index(2).tab_stop(true),
                "Button with .focus_visible() - only shows border with keyboard",
            },
            .{
                cx.focus_handle().tab_index(3).tab_stop(true),
                "Button with both .focus() and .focus_visible()",
            },
        };

        const focus_handle = cx.focus_handle();
        window.focus(focus_handle);

        return .{
            .focus_handle = focus_handle,
            .items = items,
            .message = "Try clicking vs tabbing! Click shows no border, Tab shows border.",
        };
    }

    fn on_tab(this: *Example, _: *const Tab, window: *Window, cx: *Context(Example)) void {
        window.focus_next(cx.app);
        this.message = "Pressed Tab - focus-visible border should appear!";
    }

    fn on_tab_prev(this: *Example, _: *const TabPrev, window: *Window, cx: *Context(Example)) void {
        window.focus_prev(cx.app);
        this.message = "Pressed Shift-Tab - focus-visible border should appear!";
    }

    fn on_quit(_: *Example, _: *const Quit, _: *Window, cx: *Context(Example)) void {
        cx.app.quit();
    }

    fn on_button1_click(this: *Example, _: *const ClickEvent, _: *Window, cx: *Context(Example)) void {
        this.message = "Clicked button 1 - focus border is visible!";
        cx.notify();
    }

    fn on_button2_click(this: *Example, _: *const ClickEvent, _: *Window, cx: *Context(Example)) void {
        this.message = "Clicked button 2 - no border! Try Tab instead.";
        cx.notify();
    }

    fn on_button3_click(this: *Example, _: *const ClickEvent, _: *Window, cx: *Context(Example)) void {
        this.message = "Clicked button 3 - yellow border. Tab shows green!";
        cx.notify();
    }

    fn button_base(id: []const u8, label: []const u8) *Div {
        return div()
            .id(id)
            .h_16()
            .w_full()
            .flex()
            .justify_center()
            .items_center()
            .bg(gpui.rgb(0x2563eb))
            .text_color(gpui.white())
            .rounded_md()
            .cursor_pointer()
            .hover(gpui.style_refinement().bg(gpui.rgb(0x1d4ed8)))
            .child(label);
    }

    pub fn render(self: *Example, _: *Window, cx: *Context(Example)) *Div {
        return div()
            .id("app")
            .track_focus(&self.focus_handle)
            .on_action(Tab, cx.listener(Example.on_tab))
            .on_action(TabPrev, cx.listener(Example.on_tab_prev))
            .on_action(Quit, cx.listener(Example.on_quit))
            .size_full()
            .flex()
            .flex_col()
            .p_8()
            .gap_6()
            .bg(gpui.rgb(0xf3f4f6))
            .child(
                div()
                    .text_2xl()
                    .font_weight(gpui.FontWeight.BOLD)
                    .text_color(gpui.rgb(0x111827))
                    .child("CSS focus-visible Demo"),
            )
            .child(
                div()
                    .p_4()
                    .rounded_md()
                    .bg(gpui.rgb(0xdbeafe))
                    .text_color(gpui.rgb(0x1e3a8a))
                    .child(self.message),
            )
            .child(
                div()
                    .flex()
                    .flex_col()
                    .gap_4()
                    .child(
                        div()
                            .flex()
                            .flex_col()
                            .gap_2()
                            .child(
                                div()
                                    .text_sm()
                                    .font_weight(gpui.FontWeight.BOLD)
                                    .text_color(gpui.rgb(0x374151))
                                    .child("1. Regular .focus() - always visible:"),
                            )
                            .child(
                                button_base("button1", self.items[0][1])
                                    .track_focus(&self.items[0][0])
                                    .focus(gpui.style_refinement().border_4().border_color(gpui.rgb(0xfbbf24)))
                                    .on_click(cx.listener(Example.on_button1_click)),
                            ),
                    )
                    .child(
                        div()
                            .flex()
                            .flex_col()
                            .gap_2()
                            .child(
                                div()
                                    .text_sm()
                                    .font_weight(gpui.FontWeight.BOLD)
                                    .text_color(gpui.rgb(0x374151))
                                    .child("2. New .focus_visible() - only keyboard:"),
                            )
                            .child(
                                button_base("button2", self.items[1][1])
                                    .track_focus(&self.items[1][0])
                                    .focus_visible(gpui.style_refinement().border_4().border_color(gpui.rgb(0x10b981)))
                                    .on_click(cx.listener(Example.on_button2_click)),
                            ),
                    )
                    .child(
                        div()
                            .flex()
                            .flex_col()
                            .gap_2()
                            .child(
                                div()
                                    .text_sm()
                                    .font_weight(gpui.FontWeight.BOLD)
                                    .text_color(gpui.rgb(0x374151))
                                    .child("3. Both .focus() (yellow) and .focus_visible() (green):"),
                            )
                            .child(
                                button_base("button3", self.items[2][1])
                                    .track_focus(&self.items[2][0])
                                    .focus(gpui.style_refinement().border_4().border_color(gpui.rgb(0xfbbf24)))
                                    .focus_visible(gpui.style_refinement().border_4().border_color(gpui.rgb(0x10b981)))
                                    .on_click(cx.listener(Example.on_button3_click)),
                            ),
                    ),
            );
    }
};

fn run_example(cx: *App) void {
    // example_support::load_fonts is not ported (no TextSystem::add_fonts yet).
    cx.bind_keys(&.{
        KeyBinding.new("tab", Tab{}, null),
        KeyBinding.new("shift-tab", TabPrev{}, null),
        KeyBinding.new("cmd-q", Quit{}, null),
    });

    const bounds = Bounds(gpui.Pixels).centered(null, size(px(800.0), px(600.0)), cx);
    _ = cx.open_window(.{ .window_bounds = .{ .windowed = bounds } }, struct {
        fn build(window: *Window, app: *App) gpui.Entity(Example) {
            return app.new(Example.new(window, app));
        }
    }.build) catch unreachable;

    cx.activate(true);
}

pub fn main() void {
    gpui.Application.new().run(run_example);
}
