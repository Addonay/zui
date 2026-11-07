//! Port of GPUI's `examples/popover.rs`.
//!
//! Differences from the Rust version:
//! - Font loading (`example_support::load_fonts`) is not ported (no `TextSystem::add_fonts` yet).
//! - GPUI's `.when(cond, |this| ...)` closures that capture state are written as `if` blocks,
//!   since Zig has no closures.

const gpui = @import("zui");
const App = gpui.App;
const ClickEvent = gpui.ClickEvent;
const Context = gpui.Context;
const Div = gpui.Div;
const Hsla = gpui.Hsla;
const MouseDownEvent = gpui.MouseDownEvent;
const Window = gpui.Window;
const WindowOptions = gpui.WindowOptions;
const anchored = gpui.anchored;
const deferred = gpui.deferred;
const div = gpui.div;
const px = gpui.px;

/// An example show use deferred to create a floating layers.
const HelloWorld = struct {
    open: bool,
    secondary_open: bool,

    fn open_popover(this: *HelloWorld, _: *const ClickEvent, _: *Window, cx: *Context(HelloWorld)) void {
        this.open = true;
        cx.notify();
    }

    fn close_popover(this: *HelloWorld, _: *const MouseDownEvent, _: *Window, cx: *Context(HelloWorld)) void {
        this.open = false;
        cx.notify();
    }

    fn open_secondary_popover(this: *HelloWorld, _: *const ClickEvent, _: *Window, cx: *Context(HelloWorld)) void {
        this.secondary_open = true;
        cx.notify();
    }

    fn close_secondary_popover(this: *HelloWorld, _: *const MouseDownEvent, _: *Window, cx: *Context(HelloWorld)) void {
        this.secondary_open = false;
        cx.notify();
    }

    fn render_secondary_popover(self: *HelloWorld, _: *Window, cx: *Context(HelloWorld)) *Div {
        var secondary = button("secondary-btn")
            .mt_2()
            .child("Child Popover")
            .on_click(cx.listener(HelloWorld.open_secondary_popover));
        if (self.secondary_open) {
            // Now GPUI supports nested deferred!
            secondary = secondary.child(
                deferred(
                    anchored()
                        .anchor(.top_left)
                        .snap_to_window_with_margin(px(8.0))
                        .child(
                            popover()
                                .child("This is second level Popover with nested deferred!")
                                .bg(gpui.white())
                                .border_color(gpui.blue())
                                .on_mouse_down_out(cx.listener(HelloWorld.close_secondary_popover)),
                        ),
                ).priority(2),
            );
        }
        return secondary;
    }

    pub fn render(self: *HelloWorld, window: *Window, cx: *Context(HelloWorld)) *Div {
        const opened = button("popover0").child("Opened Popover").child(
            deferred(
                anchored()
                    .anchor(.top_left)
                    .snap_to_window_with_margin(px(8.0))
                    .child(popover().w_96().gap_3().child(
                        "This is a default opened Popover, we can use deferred to render it in a floating layer.",
                    )),
            ).priority(0),
        );

        var toggled = button("popover1")
            .child("Open Popover")
            .on_click(cx.listener(HelloWorld.open_popover));
        if (self.open) {
            var first = popover()
                .w_96()
                .gap_3()
                .child("This is first level Popover, we can use deferred to render it in a floating layer.\nClick outside to close.");
            if (!self.secondary_open) {
                first = first.on_mouse_down_out(cx.listener(HelloWorld.close_popover));
            }
            // Here we need render popover after the content
            // to ensure it will be on top layer.
            first = first.child(self.render_secondary_popover(window, cx));

            toggled = toggled.child(
                deferred(
                    anchored()
                        .anchor(.top_left)
                        .snap_to_window_with_margin(px(8.0))
                        .child(first),
                ).priority(1),
            );
        }

        return div()
            .flex()
            .flex_col()
            .gap_3()
            .size_full()
            .bg(gpui.white())
            .text_color(gpui.black())
            .justify_center()
            .items_center()
            .child(
                div()
                    .flex()
                    .flex_row()
                    .gap_4()
                    .child(opened)
                    .child(toggled),
            )
            .child("Here is an example text rendered, to ensure the Popover will float above this contents.")
            .children(.{
                line(gpui.red()),
                line(gpui.yellow()),
                line(gpui.blue()),
                line(gpui.green()),
            });
    }
};

fn button(id: []const u8) *Div {
    return div()
        .id(id)
        .bg(gpui.black())
        .text_color(gpui.white())
        .px_3()
        .py_1();
}

fn popover() *Div {
    return div()
        .flex()
        .flex_col()
        .items_center()
        .justify_center()
        .shadow_lg()
        .p_3()
        .rounded_md()
        .bg(gpui.white())
        .text_color(gpui.black())
        .border_1()
        .text_sm()
        .border_color(gpui.black().opacity(0.1));
}

fn line(color: Hsla) *Div {
    return div().w(px(480.0)).h_2().bg(color.opacity(0.25));
}

fn run_example(cx: *App) void {
    // example_support::load_fonts is not ported (no TextSystem::add_fonts yet).
    _ = cx.open_window(WindowOptions{}, struct {
        fn build(_: *Window, app: *App) gpui.Entity(HelloWorld) {
            return app.new(HelloWorld{ .open = false, .secondary_open = false });
        }
    }.build) catch unreachable;
    cx.activate(true);
}

pub fn main() void {
    gpui.Application.new().run(run_example);
}
