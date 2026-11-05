//! Port of GPUI's `examples/image_loading.rs`: the loading and fallback states of `img()`.
//!
//! Differences from the Rust version:
//! - The loading placeholder shows as soon as an image starts loading. GPUI waits `LOADING_DELAY`
//!   first, which ZUI does not do yet, so image 1 flashes its placeholder for its 175 ms.
//! - `img(...)` takes a pointer to a type with `use_image`, not a closure. `ImageLoader` below is
//!   that type; it calls `window.use_asset` as GPUI's closure does.
//! - Image 4 is a missing file, as in GPUI: it shows the fallback. Its `on_click` is not ported,
//!   because ZUI has no way yet to remove a path from its own image cache.
//! - `example_support::load_fonts` and `cx.set_menus` are not ported.

const std = @import("std");
const gpui = @import("zui");
const log = std.log.scoped(.image_loading);
const App = gpui.App;
const AnyElement = gpui.AnyElement;
const Bounds = gpui.Bounds;
const ClickEvent = gpui.ClickEvent;
const Context = gpui.Context;
const Div = gpui.Div;
const Window = gpui.Window;
const WindowOptions = gpui.WindowOptions;
const black = gpui.black;
const div = gpui.div;
const img = gpui.img;
const px = gpui.px;
const red = gpui.red;
const size = gpui.size;
const white = gpui.white;

/// The assets this example loads: the app icon.
const Assets = struct {
    const files = std.StaticStringMap([]const u8).initComptime(.{
        .{ "image/app-icon.png", @embedFile("assets/image/app-icon.png") },
    });

    pub fn load(_: *Assets, path: []const u8) ?[]const u8 {
        return files.get(path);
    }
};

var assets: Assets = .{};

const IMAGE = "image/app-icon.png";

/// GPUI's `LoadImageParameters`: how long the load takes, and whether it fails.
const LoadImageParameters = struct {
    timeout_ns: u64,
    fail: bool,
};

/// GPUI's `LoadImageWithParameters` asset: waits for the timeout, then loads the icon, or fails.
const LoadImageWithParameters = struct {
    pub const Source = LoadImageParameters;
    pub const Output = gpui.ImageCacheError!*gpui.RenderImage;

    pub fn load(parameters: Source, cx: *gpui.LoadContext) Output {
        cx.sleep(parameters.timeout_ns) catch return error.FetchFailed;
        if (parameters.fail) {
            log.err("Intentionally failed to load image", .{});
            return error.FetchFailed;
        }
        return gpui.assets.load_detached(cx.allocator, cx.io, cx.asset_source, cx.http_client, .{ .embedded = IMAGE });
    }

    pub fn dispose(out: Output, app: *App) void {
        gpui.image_cache_mod.ImageAssetLoader.dispose(out, app);
    }
};

/// The image source for one of the asset-backed images: `window.use_asset` with its parameters.
const ImageLoader = struct {
    params: LoadImageParameters,

    pub fn use_image(self: *ImageLoader, window: *Window, cx: *App) ?gpui.ImageCacheError!*gpui.RenderImage {
        return window.use_asset(LoadImageWithParameters, self.params, cx);
    }
};

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
    image_1: ImageLoader,
    image_2: ImageLoader,
    image_3: ImageLoader,

    /// Clears the asset for the image that was clicked, so the next frame loads it again.
    fn on_click_image(_: *ImageLoadingExample, params: LoadImageParameters, _: *const ClickEvent, _: *Window, cx: *Context(ImageLoadingExample)) void {
        cx.app.remove_asset(LoadImageWithParameters, params);
    }

    pub fn render(self: *ImageLoadingExample, _: *Window, cx: *Context(ImageLoadingExample)) *Div {
        return div().flex().flex_col().size_full().justify_around().child(
            div().flex().flex_row().w_full().justify_around().child(
                div()
                    .flex()
                    .bg(white())
                    .size(px(300.0))
                    .justify_center()
                    .items_center()
                    .child(
                    // Loads within the 'loading delay', so GPUI would not show the loading state.
                    img(&self.image_1)
                        .id("image-1")
                        .border_1()
                        .size_12()
                        .with_fallback(fallback_element)
                        .border_color(red())
                        .with_loading(loading_element)
                        .on_click(cx.listener_with(self.image_1.params, ImageLoadingExample.on_click_image)),
                )
                    .child(
                    // Loads after a long delay.
                    img(&self.image_2)
                        .id("image-2")
                        .with_fallback(fallback_element)
                        .with_loading(loading_element)
                        .size_12()
                        .border_1()
                        .border_color(red())
                        .on_click(cx.listener_with(self.image_2.params, ImageLoadingExample.on_click_image)),
                )
                    .child(
                    // Fails after a long delay.
                    img(&self.image_3)
                        .id("image-3")
                        .with_fallback(fallback_element)
                        .with_loading(loading_element)
                        .size_12()
                        .border_1()
                        .border_color(red())
                        .on_click(cx.listener_with(self.image_3.params, ImageLoadingExample.on_click_image)),
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
    const options = WindowOptions{
        .window_bounds = .{ .windowed = Bounds(gpui.Pixels){
            .size = size(px(300.0), px(300.0)),
            .origin = gpui.point(px(200.0), px(200.0)),
        } },
    };
    _ = cx.open_window(options, struct {
        fn build(_: *Window, app: *App) gpui.Entity(ImageLoadingExample) {
            app.activate(false);
            const ms = std.time.ns_per_ms;
            return app.new(ImageLoadingExample{
                // Within the loading delay in GPUI (LOADING_DELAY - 25 ms).
                .image_1 = .{ .params = .{ .timeout_ns = 175 * ms, .fail = false } },
                .image_2 = .{ .params = .{ .timeout_ns = 5000 * ms, .fail = false } },
                .image_3 = .{ .params = .{ .timeout_ns = 5000 * ms, .fail = true } },
            });
        }
    }.build) catch unreachable;
}

pub fn main() void {
    gpui.Application.new().with_assets(&assets).run(run_example);
}
