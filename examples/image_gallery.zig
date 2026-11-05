//! Port of GPUI's `examples/image_gallery.rs`: a grid of remote images that can be replaced all at once.
//!
//! Differences from the Rust version:
//! - The second gallery's LRU cache takes its size from `use_keyed_state`, which needs a comptime
//!   initializer, so `max_items` is fixed at `IMAGES_IN_GALLERY`. GPUI rebuilds the cache when the size
//!   changes; this one never changes size.
//! - The key that busts the URLs is a counter, not a millisecond timestamp.
//! - No `ReqwestClient`: ZUI has a built-in HTTP client.
//! - `set_menus` and `example_support::load_fonts` are not ported.

const std = @import("std");
const gpui = @import("zui");
const App = gpui.App;
const Bounds = gpui.Bounds;
const ClickEvent = gpui.ClickEvent;
const Context = gpui.Context;
const Div = gpui.Div;
const Window = gpui.Window;
const WindowOptions = gpui.WindowOptions;
const div = gpui.div;
const image_cache = gpui.image_cache;
const img = gpui.img;
const px = gpui.px;
const rgb = gpui.rgb;
const size = gpui.size;

const IMAGES_IN_GALLERY: usize = 30;

const ImageGallery = struct {
    image_key: u64 = 0,
    items_count: usize = IMAGES_IN_GALLERY,
    total_count: usize = 0,
    image_cache: gpui.Entity(gpui.RetainAllImageCache),

    fn on_next_image(self: *ImageGallery, _: *const ClickEvent, _: *Window, cx: *Context(ImageGallery)) void {
        self.image_cache.as_mut(cx.app).clear(cx.app);
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
            .image_cache(self.image_cache)
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
            .child("Manually managed image cache:")
            .child(first)
            .child("Automatically managed image cache:")
            .child(image_cache(SimpleLruCacheProvider{ .id = "lru-cache" }).child(second));
    }
};

/// GPUI's `SimpleLruCacheProvider`: the cache for the second gallery, kept in element state.
const SimpleLruCacheProvider = struct {
    id: []const u8,

    pub fn provide(self: *SimpleLruCacheProvider, window: *Window, cx: *App) gpui.AnyImageCache {
        const cache = window.use_keyed_state(self.id, cx, SimpleLruCache.new);
        return gpui.AnyImageCache.from(cache, cx);
    }
};

/// Keeps the `max_items` most recently used images and releases the others (GPUI `SimpleLruCache`).
const SimpleLruCache = struct {
    allocator: std.mem.Allocator,
    max_items: usize,
    /// The keys of `cache`, most recently used first.
    usages: std.ArrayList(u64) = .empty,
    cache: std.AutoHashMapUnmanaged(u64, gpui.ImageCacheItem) = .empty,

    fn new(cx: *Context(SimpleLruCache)) SimpleLruCache {
        return .{ .allocator = cx.app.allocator, .max_items = IMAGES_IN_GALLERY };
    }

    /// Called when the entity is released: releases every image.
    pub fn deinit(self: *SimpleLruCache, app: *App) void {
        var it = self.cache.valueIterator();
        while (it.next()) |item| item.release(app);
        self.cache.deinit(self.allocator);
        self.usages.deinit(self.allocator);
    }

    pub fn load(self: *SimpleLruCache, resource: gpui.Resource, window: *Window, cx: *App) ?gpui.ImageCacheError!*gpui.RenderImage {
        const key = gpui.hash(resource);

        if (self.cache.get(key)) |item| {
            const index = std.mem.indexOfScalar(u64, self.usages.items, key).?;
            _ = self.usages.orderedRemove(index);
            self.usages.insert(self.allocator, 0, key) catch return error.OutOfMemory;
            return item.use_image(window);
        }

        if (self.usages.items.len == self.max_items) {
            const oldest = self.usages.pop().?;
            const evicted = self.cache.fetchRemove(oldest).?.value;
            evicted.release(cx);
        }
        const item = gpui.ImageCacheItem.new(resource, cx) catch return error.OutOfMemory;
        self.cache.put(self.allocator, key, item) catch {
            item.release(cx);
            return error.OutOfMemory;
        };
        self.usages.insert(self.allocator, 0, key) catch return error.OutOfMemory;
        return item.use_image(window);
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
            return app.new(ImageGallery{ .image_cache = gpui.RetainAllImageCache.new(app) });
        }
    }.build) catch unreachable;
}

pub fn main() void {
    gpui.Application.new().run(run_example);
}
