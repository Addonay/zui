//! Port of GPUI's `examples/gradient.rs`.

const gpui = @import("zui");
const App = gpui.App;
const Bounds = gpui.Bounds;
const ClickEvent = gpui.ClickEvent;
const ColorSpace = gpui.color.ColorSpace;
const Context = gpui.Context;
const Window = gpui.Window;
const WindowOptions = gpui.WindowOptions;
const div = gpui.div;
const linear_color_stop = gpui.linear_color_stop;
const linear_gradient = gpui.linear_gradient;
const point = gpui.point;
const px = gpui.px;

const GradientViewer = struct {
    color_space: ColorSpace,

    fn new() GradientViewer {
        return .{ .color_space = ColorSpace.default };
    }

    fn toggle_color_space(this: *GradientViewer, _: *const ClickEvent, _: *Window, cx: *Context(GradientViewer)) void {
        this.color_space = switch (this.color_space) {
            .oklab => .srgb,
            .srgb => .oklab,
        };
        cx.notify();
    }

    /// GPUI's `Display` for `ColorSpace`.
    fn display(color_space: ColorSpace) []const u8 {
        return switch (color_space) {
            .srgb => "sRGB",
            .oklab => "Oklab",
        };
    }

    pub fn render(self: *GradientViewer, _: *Window, cx: *Context(GradientViewer)) *gpui.Div {
        const color_space = self.color_space;

        return div()
            .bg(gpui.white())
            .size_full()
            .p_4()
            .flex()
            .flex_col()
            .gap_3()
            .child(
                div()
                    .flex()
                    .gap_2()
                    .justify_between()
                    .items_center()
                    .child("Gradient Examples")
                    .child(
                        div().flex().gap_2().items_center().child(
                            div()
                                .id("method")
                                .flex()
                                .px_3()
                                .py_1()
                                .text_sm()
                                .bg(gpui.black())
                                .text_color(gpui.white())
                                .child(gpui.format("{s}", .{display(color_space)}))
                                .active(gpui.style_refinement().opacity(0.8))
                                .on_click(cx.listener(GradientViewer.toggle_color_space)),
                        ),
                    ),
            )
            .child(
                div()
                    .flex()
                    .flex_1()
                    .gap_3()
                    .child(
                        div()
                            .size_full()
                            .rounded_xl()
                            .flex()
                            .items_center()
                            .justify_center()
                            .bg(gpui.red())
                            .text_color(gpui.white())
                            .child("Solid Color"),
                    )
                    .child(
                        div()
                            .size_full()
                            .rounded_xl()
                            .flex()
                            .items_center()
                            .justify_center()
                            .bg(gpui.blue())
                            .text_color(gpui.white())
                            .child("Solid Color"),
                    ),
            )
            .child(
                div()
                    .flex()
                    .flex_1()
                    .gap_3()
                    .h_24()
                    .text_color(gpui.white())
                    .child(
                        div().flex_1().rounded_xl().bg(linear_gradient(
                            45.0,
                            linear_color_stop(gpui.red(), 0.0),
                            linear_color_stop(gpui.blue(), 1.0),
                        ).with_color_space(color_space)),
                    )
                    .child(
                        div().flex_1().rounded_xl().bg(linear_gradient(
                            135.0,
                            linear_color_stop(gpui.red(), 0.0),
                            linear_color_stop(gpui.green(), 1.0),
                        ).with_color_space(color_space)),
                    )
                    .child(
                        div().flex_1().rounded_xl().bg(linear_gradient(
                            225.0,
                            linear_color_stop(gpui.green(), 0.0),
                            linear_color_stop(gpui.blue(), 1.0),
                        ).with_color_space(color_space)),
                    )
                    .child(
                        div().flex_1().rounded_xl().bg(linear_gradient(
                            315.0,
                            linear_color_stop(gpui.green(), 0.0),
                            linear_color_stop(gpui.yellow(), 1.0),
                        ).with_color_space(color_space)),
                    ),
            )
            .child(
                div()
                    .flex()
                    .flex_1()
                    .gap_3()
                    .h_24()
                    .text_color(gpui.white())
                    .child(
                        div().flex_1().rounded_xl().bg(linear_gradient(
                            0.0,
                            linear_color_stop(gpui.red(), 0.0),
                            linear_color_stop(gpui.white(), 1.0),
                        ).with_color_space(color_space)),
                    )
                    .child(
                        div().flex_1().rounded_xl().bg(linear_gradient(
                            90.0,
                            linear_color_stop(gpui.blue(), 0.0),
                            linear_color_stop(gpui.white(), 1.0),
                        ).with_color_space(color_space)),
                    )
                    .child(
                        div().flex_1().rounded_xl().bg(linear_gradient(
                            180.0,
                            linear_color_stop(gpui.green(), 0.0),
                            linear_color_stop(gpui.white(), 1.0),
                        ).with_color_space(color_space)),
                    )
                    .child(
                        div().flex_1().rounded_xl().bg(linear_gradient(
                            360.0,
                            linear_color_stop(gpui.yellow(), 0.0),
                            linear_color_stop(gpui.white(), 1.0),
                        ).with_color_space(color_space)),
                    ),
            )
            .child(
                div().flex_1().rounded_xl().bg(linear_gradient(
                    0.0,
                    linear_color_stop(gpui.green(), 0.05),
                    linear_color_stop(gpui.yellow(), 0.95),
                ).with_color_space(color_space)),
            )
            .child(
                div().flex_1().rounded_xl().bg(linear_gradient(
                    90.0,
                    linear_color_stop(gpui.blue(), 0.05),
                    linear_color_stop(gpui.red(), 0.95),
                ).with_color_space(color_space)),
            )
            .child(
                div()
                    .flex()
                    .flex_1()
                    .gap_3()
                    .child(
                        div().flex().flex_1().gap_3().child(
                            div().flex_1().rounded_xl().bg(linear_gradient(
                                90.0,
                                linear_color_stop(gpui.blue(), 0.5),
                                linear_color_stop(gpui.red(), 0.5),
                            ).with_color_space(color_space)),
                        ),
                    )
                    .child(
                        div().flex_1().rounded_xl().bg(linear_gradient(
                            180.0,
                            linear_color_stop(gpui.green(), 0.0),
                            linear_color_stop(gpui.blue(), 0.5),
                        ).with_color_space(color_space)),
                    ),
            )
            .child(div().h_24().child(gpui.canvas(color_space, struct {
                fn prepaint(_: ColorSpace, _: Bounds(gpui.Pixels), _: *Window, _: *App) void {}
            }.prepaint, struct {
                fn paint(color_space_: ColorSpace, bounds: Bounds(gpui.Pixels), _: *void, window: *Window, app: *App) void {
                    const sz = gpui.size(bounds.size.width * 0.8, px(80.0));
                    const square_bounds = Bounds(gpui.Pixels){
                        .origin = point(
                            gpui.half(bounds.size.width) - gpui.half(sz.width),
                            bounds.origin.y,
                        ),
                        .size = sz,
                    };
                    const height = square_bounds.size.height;
                    const horizontal_offset = height;
                    const vertical_offset = px(30.0);
                    var builder = gpui.path_builder.PathBuilder.fill(app.allocator);
                    builder.move_to(square_bounds.bottom_left()) catch unreachable;
                    builder.line_to(square_bounds.origin.add(point(horizontal_offset, vertical_offset))) catch unreachable;
                    builder.line_to(square_bounds.top_right().add(point(-horizontal_offset, vertical_offset))) catch unreachable;

                    builder.line_to(square_bounds.bottom_right()) catch unreachable;
                    builder.line_to(square_bounds.bottom_left()) catch unreachable;
                    const path = builder.build() catch unreachable;
                    window.paint_path(
                        path,
                        linear_gradient(
                            180.0,
                            linear_color_stop(gpui.red(), 0.0),
                            linear_color_stop(gpui.blue(), 1.0),
                        ).with_color_space(color_space_),
                    );
                }
            }.paint)));
    }
};

fn run_example(cx: *App) void {
    _ = cx.open_window(.{ .focus = true }, struct {
        fn build(_: *Window, app: *App) gpui.Entity(GradientViewer) {
            return app.new(GradientViewer.new());
        }
    }.build) catch unreachable;
    cx.activate(true);
}

pub fn main() void {
    gpui.Application.new().run(run_example);
}
