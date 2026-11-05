//! Port of GPUI's `examples/anchor.rs`.
//!
//! Differences from the Rust version:
//! - Font loading (`example_support::load_fonts`) is not ported (no `TextSystem::add_fonts` yet).
//! - `Half::half()` is the free function `gpui.half(value)`.
//! - GPUI's `.when(is_hoverable, ...)` contains the label, so the "Center" button, which has no
//!   corner, draws no label and no border. This is kept as in GPUI.

const gpui = @import("zui");
const Anchor = gpui.Anchor;
const App = gpui.App;
const Bounds = gpui.Bounds;
const Context = gpui.Context;
const Div = gpui.Div;
const Pixels = gpui.Pixels;
const Point = gpui.Point;
const Window = gpui.Window;
const anchored = gpui.anchored;
const deferred = gpui.deferred;
const div = gpui.div;
const point = gpui.point;
const px = gpui.px;
const size = gpui.size;

const ButtonDemo = struct {
    label: []const u8,
    corner: ?Anchor,
};

const buttons = [_]ButtonDemo{
    .{ .label = "TopLeft", .corner = .top_left },
    .{ .label = "TopCenter", .corner = .top_center },
    .{ .label = "TopRight", .corner = .top_right },
    .{ .label = "LeftCenter", .corner = .left_center },
    .{ .label = "Center", .corner = null },
    .{ .label = "RightCenter", .corner = .right_center },
    .{ .label = "BottomLeft", .corner = .bottom_left },
    .{ .label = "BottomCenter", .corner = .bottom_center },
    .{ .label = "BottomRight", .corner = .bottom_right },
};

fn resolved_position(corner: Anchor, button_size: gpui.Size(Pixels)) Point(Pixels) {
    const offset = point(px(0.0), -button_size.height);
    const along = switch (corner.other_side_along(.vertical)) {
        .top_left => point(px(0.0), px(0.0)),
        .top_center => point(gpui.half(button_size.width), px(0.0)),
        .top_right => point(button_size.width, px(0.0)),
        .left_center => point(button_size.width, gpui.half(button_size.height)),
        .right_center => point(px(0.0), gpui.half(button_size.height)),
        .bottom_left => point(px(0.0), button_size.height),
        .bottom_center => point(button_size.width / 2.0, button_size.height),
        .bottom_right => point(button_size.width, button_size.height),
    };
    return offset.add(along);
}

const AnchorDemo = struct {
    hovered_button: ?usize,

    fn on_button_hover(this: *AnchorDemo, index: usize, hovered: *const bool, _: *Window, cx: *Context(AnchorDemo)) void {
        if (hovered.*) {
            this.hovered_button = index;
        } else if (this.hovered_button == index) {
            this.hovered_button = null;
        }
        cx.notify();
    }

    pub fn render(self: *AnchorDemo, _: *Window, cx: *Context(AnchorDemo)) *Div {
        const button_size = size(px(120.0), px(65.0));

        var grid = div()
            .size_128()
            .grid()
            .grid_cols(3)
            .gap_6()
            .relative();

        for (buttons, 0..) |button, index| {
            const is_hovered = self.hovered_button == index;
            const is_hoverable = button.corner != null;

            var label_box = div()
                .id(.{ "button", index })
                .w(button_size.width)
                .h(button_size.height)
                .flex()
                .items_center()
                .justify_center()
                .bg(gpui.white());
            if (is_hoverable) {
                label_box = label_box
                    .border_1()
                    .rounded_lg()
                    .border_color(gpui.black())
                    .hover(gpui.style_refinement().bg(gpui.black()).text_color(gpui.white()))
                    .on_hover(cx.listener_with(index, AnchorDemo.on_button_hover))
                    .child(button.label);
            }

            var cell = div().relative().child(label_box);
            if (is_hovered) {
                if (button.corner) |corner| {
                    const position = resolved_position(corner, button_size);
                    cell = cell.child(deferred(
                        anchored()
                            .anchor(corner)
                            .position(position)
                            .position_mode(.local)
                            .snap_to_window()
                            .child(
                                div()
                                    .py_0p5()
                                    .px_2()
                                    .bg(gpui.black().opacity(0.75))
                                    .text_color(gpui.rgb(0xffffff))
                                    .rounded_sm()
                                    .shadow_sm()
                                    .min_w(px(100.0))
                                    .text_sm()
                                    .child(button.label),
                            ),
                    ));
                }
            }
            grid = grid.child(cell);
        }

        return div()
            .flex()
            .flex_col()
            .size_full()
            .items_center()
            .justify_center()
            .bg(gpui.white())
            .gap_4()
            .p_10()
            .child("Popover with Anchor")
            .child(grid);
    }
};

fn run_example(cx: *App) void {
    // example_support::load_fonts is not ported (no TextSystem::add_fonts yet).
    const bounds = Bounds(Pixels).centered(null, size(px(750.0), px(600.0)), cx);
    _ = cx.open_window(.{ .window_bounds = .{ .windowed = bounds } }, struct {
        fn build(_: *Window, app: *App) gpui.Entity(AnchorDemo) {
            return app.new(AnchorDemo{ .hovered_button = null });
        }
    }.build) catch unreachable;
    cx.activate(true);
}

pub fn main() void {
    gpui.Application.new().run(run_example);
}
