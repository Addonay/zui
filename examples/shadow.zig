//! Port of GPUI's `examples/shadow.rs`.
//!
//! Font loading (`example_support::load_fonts`) is not ported: ZUI has no
//! `TextSystem::add_fonts` yet, so the system default font is used.

const gpui = @import("zui");
const App = gpui.App;
const Bounds = gpui.Bounds;
const BoxShadow = gpui.BoxShadow;
const Context = gpui.Context;
const Div = gpui.Div;
const Window = gpui.Window;
const WindowBounds = gpui.WindowBounds;
const WindowOptions = gpui.WindowOptions;
const div = gpui.div;
const hsla = gpui.hsla;
const px = gpui.px;
const relative = gpui.relative;
const rgb = gpui.rgb;
const size = gpui.size;

/// `vec![...]` in Rust: copies the shadow list into the frame arena so the
/// slice outlives this function's stack frame.
fn shadows(list: []const BoxShadow) []const BoxShadow {
    return gpui.window.frame_arena().dupe(BoxShadow, list) catch @panic("OOM");
}

const Shadow = struct {
    fn base() *Div {
        return div()
            .size_16()
            .bg(rgb(0xffffff))
            .rounded_full()
            .border_1()
            .border_color(hsla(0.0, 0.0, 0.0, 0.1));
    }

    fn square() *Div {
        return div()
            .size_16()
            .bg(rgb(0xffffff))
            .border_1()
            .border_color(hsla(0.0, 0.0, 0.0, 0.1));
    }

    fn rounded_small() *Div {
        return div()
            .size_16()
            .bg(rgb(0xffffff))
            .rounded(px(4.0))
            .border_1()
            .border_color(hsla(0.0, 0.0, 0.0, 0.1));
    }

    fn rounded_medium() *Div {
        return div()
            .size_16()
            .bg(rgb(0xffffff))
            .rounded(px(8.0))
            .border_1()
            .border_color(hsla(0.0, 0.0, 0.0, 0.1));
    }

    fn rounded_large() *Div {
        return div()
            .size_16()
            .bg(rgb(0xffffff))
            .rounded(px(12.0))
            .border_1()
            .border_color(hsla(0.0, 0.0, 0.0, 0.1));
    }
};

fn example(label: []const u8, child: anytype) *Div {
    return div()
        .flex()
        .flex_col()
        .justify_center()
        .items_center()
        .w(relative(1.0 / 6.0))
        .border_r_1()
        .border_color(hsla(0.0, 0.0, 0.0, 1.0))
        .child(
            div()
                .flex()
                .items_center()
                .justify_center()
                .flex_1()
                .py_12()
                .child(child),
        )
        .child(
            div()
                .w_full()
                .border_t_1()
                .border_color(hsla(0.0, 0.0, 0.0, 1.0))
                .p_1()
                .flex()
                .items_center()
                .child(label),
        );
}

const ShadowExample = struct {
    pub fn render(_: *ShadowExample, _: *Window, _: *Context(ShadowExample)) *Div {
        return div()
            .id("shadow-example")
            .overflow_y_scroll()
            .bg(rgb(0xffffff))
            .size_full()
            .text_xs()
            .child(div().flex().flex_col().w_full().children(.{
                div()
                    .border_b_1()
                    .border_color(hsla(0.0, 0.0, 0.0, 1.0))
                    .flex()
                    .flex_row()
                    .children(.{
                        example("Square", Shadow.square().shadow(shadows(&.{
                            BoxShadow.new(px(0.0), px(8.0), hsla(0.0, 0.5, 0.5, 0.3)).with_blur_radius(px(8.0)),
                        }))),
                        example("Rounded 4", Shadow.rounded_small().shadow(shadows(&.{
                            BoxShadow.new(px(0.0), px(8.0), hsla(0.0, 0.5, 0.5, 0.3)).with_blur_radius(px(8.0)),
                        }))),
                        example("Rounded 8", Shadow.rounded_medium().shadow(shadows(&.{
                            BoxShadow.new(px(0.0), px(8.0), hsla(0.0, 0.5, 0.5, 0.3)).with_blur_radius(px(8.0)),
                        }))),
                        example("Rounded 16", Shadow.rounded_large().shadow(shadows(&.{
                            BoxShadow.new(px(0.0), px(8.0), hsla(0.0, 0.5, 0.5, 0.3)).with_blur_radius(px(8.0)),
                        }))),
                        example("Circle", Shadow.base().shadow(shadows(&.{
                            BoxShadow.new(px(0.0), px(8.0), hsla(0.0, 0.5, 0.5, 0.3)).with_blur_radius(px(8.0)),
                        }))),
                    }),
                div()
                    .border_b_1()
                    .border_color(hsla(0.0, 0.0, 0.0, 1.0))
                    .flex()
                    .w_full()
                    .children(.{
                        example("None", Shadow.base()),
                        // 2Xsmall shadow
                        example("2X Small", Shadow.base().shadow_2xs()),
                        // Xsmall shadow
                        example("Extra Small", Shadow.base().shadow_xs()),
                        // Small shadow
                        example("Small", Shadow.base().shadow_sm()),
                        // Medium shadow
                        example("Medium", Shadow.base().shadow_md()),
                        // Large shadow
                        example("Large", Shadow.base().shadow_lg()),
                        example("Extra Large", Shadow.base().shadow_xl()),
                        example("2X Large", Shadow.base().shadow_2xl()),
                    }),
                // Horizontal list of increasing blur radii
                div()
                    .border_b_1()
                    .border_color(hsla(0.0, 0.0, 0.0, 1.0))
                    .flex()
                    .children(.{
                        example("Blur 0", Shadow.base().shadow(shadows(&.{
                            BoxShadow.new(px(0.0), px(8.0), hsla(0.0, 0.0, 0.0, 0.3)),
                        }))),
                        example("Blur 2", Shadow.base().shadow(shadows(&.{
                            BoxShadow.new(px(0.0), px(8.0), hsla(0.0, 0.0, 0.0, 0.3)).with_blur_radius(px(2.0)),
                        }))),
                        example("Blur 4", Shadow.base().shadow(shadows(&.{
                            BoxShadow.new(px(0.0), px(8.0), hsla(0.0, 0.0, 0.0, 0.3)).with_blur_radius(px(4.0)),
                        }))),
                        example("Blur 8", Shadow.base().shadow(shadows(&.{
                            BoxShadow.new(px(0.0), px(8.0), hsla(0.0, 0.0, 0.0, 0.3)).with_blur_radius(px(8.0)),
                        }))),
                        example("Blur 16", Shadow.base().shadow(shadows(&.{
                            BoxShadow.new(px(0.0), px(8.0), hsla(0.0, 0.0, 0.0, 0.3)).with_blur_radius(px(16.0)),
                        }))),
                    }),
                // Horizontal list of increasing spread radii
                div()
                    .border_b_1()
                    .border_color(hsla(0.0, 0.0, 0.0, 1.0))
                    .flex()
                    .children(.{
                        example("Spread 0", Shadow.base().shadow(shadows(&.{
                            BoxShadow.new(px(0.0), px(8.0), hsla(0.0, 0.0, 0.0, 0.3)).with_blur_radius(px(8.0)),
                        }))),
                        example("Spread 2", Shadow.base().shadow(shadows(&.{
                            BoxShadow.new(px(0.0), px(8.0), hsla(0.0, 0.0, 0.0, 0.3)).with_blur_radius(px(8.0)).with_spread_radius(px(2.0)),
                        }))),
                        example("Spread 4", Shadow.base().shadow(shadows(&.{
                            BoxShadow.new(px(0.0), px(8.0), hsla(0.0, 0.0, 0.0, 0.3)).with_blur_radius(px(8.0)).with_spread_radius(px(4.0)),
                        }))),
                        example("Spread 8", Shadow.base().shadow(shadows(&.{
                            BoxShadow.new(px(0.0), px(8.0), hsla(0.0, 0.0, 0.0, 0.3)).with_blur_radius(px(8.0)).with_spread_radius(px(8.0)),
                        }))),
                        example("Spread 16", Shadow.base().shadow(shadows(&.{
                            BoxShadow.new(px(0.0), px(8.0), hsla(0.0, 0.0, 0.0, 0.3)).with_blur_radius(px(8.0)).with_spread_radius(px(16.0)),
                        }))),
                    }),
                // Square spread examples
                div()
                    .border_b_1()
                    .border_color(hsla(0.0, 0.0, 0.0, 1.0))
                    .flex()
                    .children(.{
                        example("Square Spread 0", Shadow.square().shadow(shadows(&.{
                            BoxShadow.new(px(0.0), px(8.0), hsla(0.0, 0.0, 0.0, 0.3)).with_blur_radius(px(8.0)),
                        }))),
                        example("Square Spread 8", Shadow.square().shadow(shadows(&.{
                            BoxShadow.new(px(0.0), px(8.0), hsla(0.0, 0.0, 0.0, 0.3)).with_blur_radius(px(8.0)).with_spread_radius(px(8.0)),
                        }))),
                        example("Square Spread 16", Shadow.square().shadow(shadows(&.{
                            BoxShadow.new(px(0.0), px(8.0), hsla(0.0, 0.0, 0.0, 0.3)).with_blur_radius(px(8.0)).with_spread_radius(px(16.0)),
                        }))),
                    }),
                // Rounded large spread examples
                div()
                    .border_b_1()
                    .border_color(hsla(0.0, 0.0, 0.0, 1.0))
                    .flex()
                    .children(.{
                        example("Rounded Large Spread 0", Shadow.rounded_large().shadow(shadows(&.{
                            BoxShadow.new(px(0.0), px(8.0), hsla(0.0, 0.0, 0.0, 0.3)).with_blur_radius(px(8.0)),
                        }))),
                        example("Rounded Large Spread 8", Shadow.rounded_large().shadow(shadows(&.{
                            BoxShadow.new(px(0.0), px(8.0), hsla(0.0, 0.0, 0.0, 0.3)).with_blur_radius(px(8.0)).with_spread_radius(px(8.0)),
                        }))),
                        example("Rounded Large Spread 16", Shadow.rounded_large().shadow(shadows(&.{
                            BoxShadow.new(px(0.0), px(8.0), hsla(0.0, 0.0, 0.0, 0.3)).with_blur_radius(px(8.0)).with_spread_radius(px(16.0)),
                        }))),
                    }),
                // Directional shadows
                div()
                    .border_b_1()
                    .border_color(hsla(0.0, 0.0, 0.0, 1.0))
                    .flex()
                    .children(.{
                        example("Left", Shadow.base().shadow(shadows(&.{
                            BoxShadow.new(px(-8.0), px(0.0), hsla(0.0, 0.5, 0.5, 0.3)).with_blur_radius(px(8.0)),
                        }))),
                        example("Right", Shadow.base().shadow(shadows(&.{
                            BoxShadow.new(px(8.0), px(0.0), hsla(0.0, 0.5, 0.5, 0.3)).with_blur_radius(px(8.0)),
                        }))),
                        example("Top", Shadow.base().shadow(shadows(&.{
                            BoxShadow.new(px(0.0), px(-8.0), hsla(0.0, 0.5, 0.5, 0.3)).with_blur_radius(px(8.0)),
                        }))),
                        example("Bottom", Shadow.base().shadow(shadows(&.{
                            BoxShadow.new(px(0.0), px(8.0), hsla(0.0, 0.5, 0.5, 0.3)).with_blur_radius(px(8.0)),
                        }))),
                    }),
                // Square directional shadows
                div()
                    .border_b_1()
                    .border_color(hsla(0.0, 0.0, 0.0, 1.0))
                    .flex()
                    .children(.{
                        example("Square Left", Shadow.square().shadow(shadows(&.{
                            BoxShadow.new(px(-8.0), px(0.0), hsla(0.0, 0.5, 0.5, 0.3)).with_blur_radius(px(8.0)),
                        }))),
                        example("Square Right", Shadow.square().shadow(shadows(&.{
                            BoxShadow.new(px(8.0), px(0.0), hsla(0.0, 0.5, 0.5, 0.3)).with_blur_radius(px(8.0)),
                        }))),
                        example("Square Top", Shadow.square().shadow(shadows(&.{
                            BoxShadow.new(px(0.0), px(-8.0), hsla(0.0, 0.5, 0.5, 0.3)).with_blur_radius(px(8.0)),
                        }))),
                        example("Square Bottom", Shadow.square().shadow(shadows(&.{
                            BoxShadow.new(px(0.0), px(8.0), hsla(0.0, 0.5, 0.5, 0.3)).with_blur_radius(px(8.0)),
                        }))),
                    }),
                // Rounded large directional shadows
                div()
                    .border_b_1()
                    .border_color(hsla(0.0, 0.0, 0.0, 1.0))
                    .flex()
                    .children(.{
                        example("Rounded Large Left", Shadow.rounded_large().shadow(shadows(&.{
                            BoxShadow.new(px(-8.0), px(0.0), hsla(0.0, 0.5, 0.5, 0.3)).with_blur_radius(px(8.0)),
                        }))),
                        example("Rounded Large Right", Shadow.rounded_large().shadow(shadows(&.{
                            BoxShadow.new(px(8.0), px(0.0), hsla(0.0, 0.5, 0.5, 0.3)).with_blur_radius(px(8.0)),
                        }))),
                        example("Rounded Large Top", Shadow.rounded_large().shadow(shadows(&.{
                            BoxShadow.new(px(0.0), px(-8.0), hsla(0.0, 0.5, 0.5, 0.3)).with_blur_radius(px(8.0)),
                        }))),
                        example("Rounded Large Bottom", Shadow.rounded_large().shadow(shadows(&.{
                            BoxShadow.new(px(0.0), px(8.0), hsla(0.0, 0.5, 0.5, 0.3)).with_blur_radius(px(8.0)),
                        }))),
                    }),
                // Multiple shadows for different shapes
                div()
                    .border_b_1()
                    .border_color(hsla(0.0, 0.0, 0.0, 1.0))
                    .flex()
                    .children(.{
                        example("Circle Multiple", Shadow.base().shadow(shadows(&.{
                            BoxShadow.new(px(0.0), px(-12.0), hsla(0.0 / 360.0, 1.0, 0.5, 0.3)).with_blur_radius(px(8.0)).with_spread_radius(px(2.0)),
                            BoxShadow.new(px(12.0), px(0.0), hsla(60.0 / 360.0, 1.0, 0.5, 0.3)).with_blur_radius(px(8.0)).with_spread_radius(px(2.0)),
                            BoxShadow.new(px(0.0), px(12.0), hsla(120.0 / 360.0, 1.0, 0.5, 0.3)).with_blur_radius(px(8.0)).with_spread_radius(px(2.0)),
                            BoxShadow.new(px(-12.0), px(0.0), hsla(240.0 / 360.0, 1.0, 0.5, 0.3)).with_blur_radius(px(8.0)).with_spread_radius(px(2.0)),
                        }))),
                        example("Square Multiple", Shadow.square().shadow(shadows(&.{
                            BoxShadow.new(px(0.0), px(-12.0), hsla(0.0 / 360.0, 1.0, 0.5, 0.3)).with_blur_radius(px(8.0)).with_spread_radius(px(2.0)),
                            BoxShadow.new(px(12.0), px(0.0), hsla(60.0 / 360.0, 1.0, 0.5, 0.3)).with_blur_radius(px(8.0)).with_spread_radius(px(2.0)),
                            BoxShadow.new(px(0.0), px(12.0), hsla(120.0 / 360.0, 1.0, 0.5, 0.3)).with_blur_radius(px(8.0)).with_spread_radius(px(2.0)),
                            BoxShadow.new(px(-12.0), px(0.0), hsla(240.0 / 360.0, 1.0, 0.5, 0.3)).with_blur_radius(px(8.0)).with_spread_radius(px(2.0)),
                        }))),
                        example("Rounded Large Multiple", Shadow.rounded_large().shadow(shadows(&.{
                            BoxShadow.new(px(0.0), px(-12.0), hsla(0.0 / 360.0, 1.0, 0.5, 0.3)).with_blur_radius(px(8.0)).with_spread_radius(px(2.0)),
                            BoxShadow.new(px(12.0), px(0.0), hsla(60.0 / 360.0, 1.0, 0.5, 0.3)).with_blur_radius(px(8.0)).with_spread_radius(px(2.0)),
                            BoxShadow.new(px(0.0), px(12.0), hsla(120.0 / 360.0, 1.0, 0.5, 0.3)).with_blur_radius(px(8.0)).with_spread_radius(px(2.0)),
                            BoxShadow.new(px(-12.0), px(0.0), hsla(240.0 / 360.0, 1.0, 0.5, 0.3)).with_blur_radius(px(8.0)).with_spread_radius(px(2.0)),
                        }))),
                    }),
                // Inset shadows (CSS `box-shadow: inset ...`).
                div()
                    .border_b_1()
                    .border_color(hsla(0.0, 0.0, 0.0, 1.0))
                    .flex()
                    .w_full()
                    .children(.{
                        example("Inset basic", Shadow.base().shadow(shadows(&.{
                            BoxShadow.new(px(0.0), px(0.0), hsla(0.0, 0.0, 0.0, 0.5)).with_blur_radius(px(12.0)).with_inset(),
                        }))),
                        example("Inset offset", Shadow.base().shadow(shadows(&.{
                            BoxShadow.new(px(6.0), px(6.0), hsla(0.0, 0.0, 0.0, 0.5)).with_blur_radius(px(8.0)).with_inset(),
                        }))),
                        example("Inset spread", Shadow.base().shadow(shadows(&.{
                            BoxShadow.new(px(0.0), px(0.0), hsla(0.0, 0.0, 0.0, 0.5)).with_blur_radius(px(4.0)).with_spread_radius(px(8.0)).with_inset(),
                        }))),
                        example("Inset rounded", Shadow.rounded_large().shadow(shadows(&.{
                            BoxShadow.new(px(0.0), px(4.0), hsla(0.0, 0.0, 0.0, 0.5)).with_blur_radius(px(10.0)).with_spread_radius(px(2.0)).with_inset(),
                        }))),
                        example("Inset sharp", Shadow.square().shadow(shadows(&.{
                            BoxShadow.new(px(0.0), px(0.0), hsla(0.0, 0.0, 0.0, 0.6)).with_spread_radius(px(6.0)).with_inset(),
                        }))),
                    }),
                // Combined: drop + inset shadows on the same element.
                div()
                    .border_b_1()
                    .border_color(hsla(0.0, 0.0, 0.0, 1.0))
                    .flex()
                    .w_full()
                    .children(.{
                        example("Drop + Inset", Shadow.rounded_medium().shadow(shadows(&.{
                            BoxShadow.new(px(0.0), px(8.0), hsla(0.0, 0.0, 0.0, 0.25)).with_blur_radius(px(12.0)),
                            BoxShadow.new(px(0.0), px(2.0), hsla(0.0, 0.0, 0.0, 0.4)).with_blur_radius(px(4.0)).with_inset(),
                        }))),
                    }),
            }));
    }
};

fn run_example(cx: *App) void {
    // example_support::load_fonts is not ported (no TextSystem::add_fonts yet).
    const bounds = Bounds(gpui.Pixels).centered(null, size(px(1000.0), px(800.0)), cx);
    _ = cx.open_window(.{ .window_bounds = .{ .windowed = bounds } }, struct {
        fn build(_: *Window, app: *App) gpui.Entity(ShadowExample) {
            return app.new(ShadowExample{});
        }
    }.build) catch unreachable;
    cx.activate(true);
}

pub fn main() void {
    gpui.Application.new().run(run_example);
}
