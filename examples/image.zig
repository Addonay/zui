//! Port of GPUI's `examples/image/image.rs`.
//!
//! Differences from the Rust version:
//! - Assets are embedded with `@embedFile` (see `Assets`) instead of read from `examples/`.
//!   The local file is therefore loaded as an embedded asset, not as a path.
//! - Remote images (`https://...`) are not fetched yet: ZUI's `Resource.uri` fails with
//!   `UnsupportedUri`, so those `img` elements draw nothing.
//! - `ReqwestClient` / `with_http_client` are not ported (no HTTP client in ZUI yet).
//! - `set_menus` is not ported (not in ZUI yet).
//! - Font loading (`example_support::load_fonts`) is not ported (no `TextSystem::add_fonts` yet).

const std = @import("std");
const gpui = @import("zui");
const App = gpui.App;
const Bounds = gpui.Bounds;
const Context = gpui.Context;
const Div = gpui.Div;
const ImageSource = gpui.ImageSource;
const Window = gpui.Window;
const WindowBounds = gpui.WindowBounds;
const WindowOptions = gpui.WindowOptions;
const div = gpui.div;
const img = gpui.img;
const px = gpui.px;
const rgb = gpui.rgb;
const size = gpui.size;

/// GPUI's `Assets` (an `AssetSource` over `examples/`), limited to the files this example loads.
const Assets = struct {
    const files = std.StaticStringMap([]const u8).initComptime(.{
        .{ "image/exif-orientation-rotate-180.jpg", @embedFile("assets/image/exif-orientation-rotate-180.jpg") },
        .{ "image/color.svg", @embedFile("assets/image/color.svg") },
    });

    pub fn load(_: *Assets, path: []const u8) ?[]const u8 {
        return files.get(path);
    }
};

var assets: Assets = .{};

/// `#[derive(IntoElement)] struct ImageContainer` plus its `RenderOnce` impl, as a function.
fn image_container(text: []const u8, src: ImageSource) *Div {
    return div().child(
        div()
            .flex_row()
            .size_full()
            .gap_4()
            .child(text)
            .child(img(src).size(px(256.0))),
    );
}

const ImageShowcase = struct {
    local_resource: []const u8,
    remote_resource: []const u8,
    asset_resource: []const u8,

    pub fn render(self: *ImageShowcase, _: *Window, _: *Context(ImageShowcase)) *Div {
        return div()
            .id("main")
            .bg(gpui.white())
            .overflow_y_scroll()
            .p_5()
            .size_full()
            .child(
                div()
                    .flex()
                    .flex_col()
                    .justify_center()
                    .items_center()
                    .gap_8()
                    .child(img("https://github.com/zed-industries/zed/actions/workflows/ci.yml/badge.svg"))
                    .child(
                        div()
                            .flex()
                            .flex_row()
                            .justify_center()
                            .items_center()
                            .gap_8()
                            .child(image_container(
                                "Image loaded from a local file with EXIF orientation",
                                ImageSource.from(self.local_resource),
                            ))
                            .child(image_container(
                                "Image loaded from a remote resource",
                                ImageSource.from(self.remote_resource),
                            ))
                            .child(image_container(
                                "Image loaded from an asset",
                                ImageSource.from(self.asset_resource),
                            )),
                    )
                    .child(
                        div()
                            .flex()
                            .flex_row()
                            .gap_8()
                            .child(
                                div()
                                    .flex_col()
                                    .child("Auto Width")
                                    .child(img("https://picsum.photos/800/400").h(px(180.0))),
                            )
                            .child(
                                div()
                                    .flex_col()
                                    .child("Auto Height")
                                    .child(img("https://picsum.photos/800/400").w(px(180.0))),
                            ),
                    )
                    .child(
                        div()
                            .flex()
                            .flex_col()
                            .justify_center()
                            .items_center()
                            .w_full()
                            .border_1()
                            .border_color(rgb(0xC0C0C0))
                            .child("image with max width 100%")
                            .child(img("https://picsum.photos/800/400").max_w_full()),
                    ),
            );
    }
};

const Quit = gpui.Action("image", "Quit");

fn quit(_: *const Quit, cx: *App) void {
    cx.quit();
}

fn run_example(cx: *App) void {
    // example_support::load_fonts and set_menus are not ported (see the note at the top of this file).
    cx.activate(true);
    cx.on_action(Quit, quit);
    cx.bind_keys(&.{gpui.KeyBinding.new("cmd-q", Quit{}, null)});

    const window_options = WindowOptions{
        .titlebar = .{ .title = "Image Example", .appears_transparent = false },
        .window_bounds = .{ .windowed = Bounds(gpui.Pixels){
            .size = size(px(1100.0), px(600.0)),
            .origin = gpui.point(px(200.0), px(200.0)),
        } },
    };

    _ = cx.open_window(window_options, struct {
        fn build(_: *Window, app: *App) gpui.Entity(ImageShowcase) {
            return app.new(ImageShowcase{
                // Embedded name of the local file (the Rust version uses an absolute path).
                .local_resource = "image/exif-orientation-rotate-180.jpg",
                .remote_resource = "https://picsum.photos/800/400",
                .asset_resource = "image/color.svg",
            });
        }
    }.build) catch unreachable;
}

pub fn main() void {
    gpui.Application.new().with_assets(&assets).run(run_example);
}
