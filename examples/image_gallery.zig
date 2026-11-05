//! Port of GPUI's `examples/image_gallery.rs`: a grid of remote images that can be replaced all at once.
//!
//! Differences from the Rust version:
//! - Both `image_cache(...)` sections are not ported. ZUI has no `ImageCache` trait, no `image_cache`
//!   element, no `RetainAllImageCache`, no `ImageCacheProvider` and no `ImageCacheItem` yet, so every
//!   image uses the app's own `AssetCache`, which keeps decoded images for the life of the app. The
//!   "Next Photos" button clears nothing; it only changes the URLs.
//! - The second gallery is kept, with the same images, so the page scrolls as in GPUI, but it is not
//!   managed by an LRU cache.
//! - The key that busts the URLs is a counter, not a millisecond timestamp.
//! - No `ReqwestClient`: ZUI has a built-in HTTP client, and `with_http_client` replaces it.
//! - `set_menus` and `example_support::load_fonts` are not ported.

const gpui = @import("zui");
const App = gpui.App;
const Bounds = gpui.Bounds;
const ClickEvent = gpui.ClickEvent;
const Context = gpui.Context;
const Div = gpui.Div;
const Window = gpui.Window;
const WindowOptions = gpui.WindowOptions;
const div = gpui.div;
const img = gpui.img;
const px = gpui.px;
const rgb = gpui.rgb;
const size = gpui.size;

const IMAGES_IN_GALLERY: usize = 30;

const ImageGallery = struct {
    image_key: u64 = 0,
    items_count: usize = IMAGES_IN_GALLERY,
    total_count: usize = 0,

    fn on_next_image(self: *ImageGallery, _: *const ClickEvent, _: *Window, cx: *Context(ImageGallery)) void {
        self.total_count += self.items_count;
        self.image_key += 1;
        cx.notify();
    }

    fn gallery(self: *const ImageGallery, image_url: []const u8) *Div {
        var grid = div()
            .id("image-gallery")
            .flex()
            .flex_row()
            .flex_wrap()
            .gap_x_4()
            .gap_y_2()
            .justify_around();
        for (0..self.items_count) |ix| {
            grid = grid.child(img(gpui.format("{s}-{d}", .{ image_url, ix })).size_20());
        }
        return grid;
    }

    pub fn render(self: *ImageGallery, _: *Window, cx: *Context(ImageGallery)) *Div {
        const image_url = gpui.format("https://picsum.photos/400/200?t={d}", .{self.image_key});

        const header = div()
            .w_full()
            .flex()
            .flex_row()
            .justify_between()
            .child(gpui.format("Example to show images and test memory usage (Rendered: {d} images).", .{self.total_count}))
            .child(
            div()
                .id("btn")
                .py_1()
                .px_4()
                .bg(gpui.black())
                .hover(gpui.style_refinement().opacity(0.8))
                .text_color(gpui.white())
                .text_center()
                .w_40()
                .child("Next Photos")
                .on_click(cx.listener(ImageGallery.on_next_image)),
        );

        const first = div()
            .id("main")
            .text_color(gpui.black())
            .bg(rgb(0xE9E9E9))
            .overflow_y_scroll()
            .p_4()
            .size_full()
            .flex()
            .flex_col()
            .items_center()
            .gap_2()
            .child(header)
            .child(self.gallery(image_url));

        const second = div()
            .id("main-2")
            .bg(rgb(0xE9E9E9))
            .text_color(gpui.black())
            .overflow_y_scroll()
            .p_4()
            .size_full()
            .flex()
            .flex_col()
            .items_center()
            .gap_2()
            .child(self.gallery(image_url));

        return div()
            .flex()
            .flex_col()
            .text_color(gpui.white())
            .child("Image gallery (without an image cache, see the top of this file):")
            .child(first)
            .child("Second gallery, same images:")
            .child(second);
    }
};

const Quit = gpui.Action("image_gallery", "Quit");

fn quit(_: *const Quit, cx: *App) void {
    cx.quit();
}

fn run_example(cx: *App) void {
    cx.activate(true);
    cx.on_action(Quit, quit);
    cx.bind_keys(&.{gpui.KeyBinding.new("cmd-q", Quit{}, null)});

    const window_options = WindowOptions{
        .titlebar = .{ .title = "Image Gallery", .appears_transparent = false },
        .window_bounds = .{ .windowed = Bounds(gpui.Pixels){
            .size = size(px(1100.0), px(860.0)),
            .origin = gpui.point(px(200.0), px(100.0)),
        } },
    };

    _ = cx.open_window(window_options, struct {
        fn build(_: *Window, app: *App) gpui.Entity(ImageGallery) {
            return app.new(ImageGallery{});
        }
    }.build) catch unreachable;
}

pub fn main() void {
    gpui.Application.new().run(run_example);
}
