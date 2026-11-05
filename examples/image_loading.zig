//! Port of GPUI's `examples/image_loading.rs`: the loading and fallback states of `img()`.
//!
//! Differences from the Rust version:
//! - Images 1 to 3 are not ported. They load through a custom `Asset` with a timer, read with
//!   `window.use_asset` and cleared with `cx.remove_asset`, and ZUI has none of those yet. Image 1 and
//!   image 2 are replaced by remote URLs, so the loading state shows while the download runs, and
//!   the failure case (image 3) is left out.
//! - Image 4 is a missing file, as in GPUI: it shows the fallback.
//! - The `on_click` handlers that remove an asset from the cache are not ported.
//! - No `Assets` source: nothing here is embedded.
//! - `example_support::load_fonts` and `cx.set_menus` are not ported.

const gpui = @import("zui");
const App = gpui.App;
const AnyElement = gpui.AnyElement;
const Bounds = gpui.Bounds;
const Context = gpui.Context;
const Div = gpui.Div;
const Window = gpui.Window;
const WindowBounds = gpui.WindowBounds;
const WindowOptions = gpui.WindowOptions;
const black = gpui.black;
const div = gpui.div;
const img = gpui.img;
const px = gpui.px;
const red = gpui.red;
const size = gpui.size;
const white = gpui.white;

/// A pulsing grey square shown while an image loads (GPUI `loading_element`).
fn loading_element() AnyElement {
    return div()
        .size_full()
        .flex_none()
        .p_0p5()
        .rounded_xs()
        .child(gpui.with_animation(
            div().size_full(),
            "loading-bg",
            gpui.Animation.new(3_000_000_000).repeat().with_easing(gpui.pulsating_between(0.04, 0.24)),
            pulse,
        ))
        .into_any_element();
}

fn pulse(this: *Div, delta: f32) *Div {
    return this.bg(black().opacity(delta));
}

/// A bordered "?" shown when an image fails to load (GPUI `fallback_element`).
fn fallback_element() AnyElement {
    const fallback_color = black().opacity(0.5);

    return div()
        .size_full()
        .flex_none()
        .p_0p5()
        .child(
        div()
            .size_full()
            .flex()
            .items_center()
            .justify_center()
            .rounded_xs()
            .text_sm()
            .text_color(fallback_color)
            .border_1()
            .border_color(fallback_color)
            .child("?"),
    ).into_any_element();
}

const ImageLoadingExample = struct {
    pub fn render(_: *ImageLoadingExample, _: *Window, _: *Context(ImageLoadingExample)) *Div {
        return div().flex().flex_col().size_full().justify_around().child(
            div().flex().flex_row().w_full().justify_around().child(
                div()
                    .flex()
                    .bg(white())
                    .size(px(300.0))
                    .justify_center()
                    .items_center()
                    .child(
                    img("https://picsum.photos/seed/zui-loading-1/200/200")
                        .id("image-1")
                        .border_1()
                        .size_12()
                        .with_fallback(fallback_element)
                        .border_color(red())
                        .with_loading(loading_element),
                )
                    .child(
                    img("https://picsum.photos/seed/zui-loading-2/200/200")
                        .id("image-2")
                        .with_fallback(fallback_element)
                        .with_loading(loading_element)
                        .size_12()
                        .border_1()
                        .border_color(red()),
                )
                    .child(
                    // Ensure that the normal image loader doesn't spam logs.
                    img(gpui.Resource{ .path = "this/file/really/shouldn't/exist/or/won't/be/an/image/I/hope" })
                        .id("image-4")
                        .border_1()
                        .size_12()
                        .with_fallback(fallback_element)
                        .border_color(red())
                        .with_loading(loading_element),
                ),
            ),
        );
    }
};

fn run_example(cx: *App) void {
    // example_support::load_fonts is not ported (see the note at the top of this file).
    const options = WindowOptions{
        .window_bounds = .{ .windowed = Bounds(gpui.Pixels){
            .size = size(px(300.0), px(300.0)),
            .origin = gpui.point(px(200.0), px(200.0)),
        } },
    };
    _ = cx.open_window(options, struct {
        fn build(_: *Window, app: *App) gpui.Entity(ImageLoadingExample) {
            app.activate(false);
            return app.new(ImageLoadingExample{});
        }
    }.build) catch unreachable;
}

pub fn main() void {
    gpui.Application.new().run(run_example);
}
