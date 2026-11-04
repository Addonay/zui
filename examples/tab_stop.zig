//! Port of GPUI's `examples/tab_stop.rs`.
//!
//! Differences from the Rust version:
//! - Font loading (`example_support::load_fonts`) is not ported (no `TextSystem::add_fonts` yet).
//! - `Div::tab_group()` is not in ZUI yet, so the two tab groups are plain `tab_index` containers.

const gpui = @import("zui");
const App = gpui.App;
const Bounds = gpui.Bounds;
const ClickEvent = gpui.ClickEvent;
const Context = gpui.Context;
const Div = gpui.Div;
const FocusHandle = gpui.FocusHandle;
const KeyBinding = gpui.KeyBinding;
const Window = gpui.Window;
const WindowBounds = gpui.WindowBounds;
const WindowOptions = gpui.WindowOptions;
const div = gpui.div;
const px = gpui.px;
const size = gpui.size;

const Tab = gpui.Action("example", "Tab");
const TabPrev = gpui.Action("example", "TabPrev");

const Example = struct {
    focus_handle: FocusHandle,
    items: [5]FocusHandle,
    message: []const u8,

    fn new(window: *Window, cx: *App) Example {
        const items = [5]FocusHandle{
            cx.focus_handle().tab_index(1).tab_stop(true),
            cx.focus_handle().tab_index(2).tab_stop(true),
            cx.focus_handle().tab_index(3).tab_stop(true),
            cx.focus_handle(),
            cx.focus_handle().tab_index(2).tab_stop(true),
        };

        const focus_handle = cx.focus_handle();
        window.focus(focus_handle);

        return .{
            .focus_handle = focus_handle,
            .items = items,
            .message = "Press `Tab`, `Shift-Tab` to switch focus.",
        };
    }

    fn on_tab(this: *Example, _: *const Tab, window: *Window, cx: *Context(Example)) void {
        window.focus_next(cx.app);
        this.message = "You have pressed `Tab`.";
    }

    fn on_tab_prev(this: *Example, _: *const TabPrev, window: *Window, cx: *Context(Example)) void {
        window.focus_prev(cx.app);
        this.message = "You have pressed `Shift-Tab`.";
    }

    fn on_button1_click(this: *Example, _: *const ClickEvent, _: *Window, cx: *Context(Example)) void {
        this.message = "You have clicked Button 1.";
        cx.notify();
    }

    fn on_button2_click(this: *Example, _: *const ClickEvent, _: *Window, cx: *Context(Example)) void {
        this.message = "You have clicked Button 2.";
        cx.notify();
    }

    /// `fn tab_stop_style<T: Styled>(this: T) -> T`. Works on a `*StyleBuilder` (for `focus`) and on a `*Div` (for `when`).
    fn tab_stop_style(this: anytype) @TypeOf(this) {
        return this.border_3().border_color(gpui.blue());
    }

    fn button(id: []const u8) *Div {
        return div()
            .id(id)
            .h_10()
            .flex_1()
            .flex()
            .justify_center()
            .items_center()
            .border_1()
            .border_color(gpui.black())
            .bg(gpui.black())
            .text_color(gpui.white())
            .focus(tab_stop_style)
            .shadow_sm();
    }

    pub fn render(self: *Example, window: *Window, cx: *Context(Example)) *Div {
        var item_elems: [5]*Div = undefined;
        for (self.items, 0..) |item_handle, ix| {
            var item = div()
                .id(.{ "item", ix })
                .track_focus(&item_handle)
                .h_10()
                .w_full()
                .flex()
                .justify_center()
                .items_center()
                .border_1()
                .border_color(gpui.black())
                .when(item_handle.tab_stop_ and item_handle.is_focused(window), tab_stop_style);
            if (item_handle.tab_stop_) {
                item = item.hover(gpui.style_refinement().bg(gpui.black().opacity(0.1)))
                    .child(gpui.format("tab_index: {d}", .{item_handle.tab_index_}));
            } else {
                item = item.opacity(0.4).child("tab_stop: false");
            }
            item_elems[ix] = item;
        }

        return div()
            .id("app")
            .track_focus(&self.focus_handle)
            .on_action(Tab, cx.listener(Example.on_tab))
            .on_action(TabPrev, cx.listener(Example.on_tab_prev))
            .size_full()
            .flex()
            .flex_col()
            .p_4()
            .gap_3()
            .bg(gpui.white())
            .text_color(gpui.black())
            .child(self.message)
            .children(item_elems[0..])
            .child(
                div()
                    .flex()
                    .flex_row()
                    .gap_3()
                    .items_center()
                    .child(
                        button("el1")
                            .tab_index(4)
                            .child("Button 1")
                            .on_click(cx.listener(Example.on_button1_click)),
                    )
                    .child(
                        button("el2")
                            .tab_index(5)
                            .child("Button 2")
                            .on_click(cx.listener(Example.on_button2_click)),
                    ),
            )
            // Missing: `.tab_group()` on the two groups below (not in ZUI yet).
            .child(
                div()
                    .id("group-1")
                    .tab_index(6)
                    .tab_stop(false)
                    .child(button("group-1-button-1").tab_index(1).child("Tab index [6, 1]"))
                    .child(button("group-1-button-2").tab_index(2).child("Tab index [6, 2]"))
                    .child(button("group-1-button-3").tab_index(3).child("Tab index [6, 3]")),
            )
            .child(
                div()
                    .id("group-2")
                    .tab_index(7)
                    .tab_stop(false)
                    .child(button("group-2-button-1").tab_index(1).child("Tab index [7, 1]"))
                    .child(button("group-2-button-2").tab_index(2).child("Tab index [7, 2]"))
                    .child(button("group-2-button-3").tab_index(3).child("Tab index [7, 3]")),
            );
    }
};

fn run_example(cx: *App) void {
    // example_support::load_fonts is not ported (no TextSystem::add_fonts yet).
    cx.bind_keys(&.{
        KeyBinding.new("tab", Tab{}, null),
        KeyBinding.new("shift-tab", TabPrev{}, null),
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
