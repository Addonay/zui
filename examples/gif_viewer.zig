//! Port of GPUI's `examples/gif_viewer.rs`: shows an animated GIF, scaled to the window.
//!
//! Differences from the Rust version:
//! - The GIF is embedded with `@embedFile` and read as an embedded asset, not from `CARGO_MANIFEST_DIR`.
//! - `example_support::load_fonts` is not ported (no `TextSystem::add_fonts` yet).
//! - The image is decoded with all of its frames; the element advances through them using its
//!   element id, as GPUI does.

const std = @import("std");
const gpui = @import("zui");
const App = gpui.App;
const Context = gpui.Context;
const Div = gpui.Div;
const Window = gpui.Window;
const div = gpui.div;
const img = gpui.img;

/// GPUI's `AssetSource` over `examples/`, limited to the GIF this example shows.
const Assets = struct {
    const files = std.StaticStringMap([]const u8).initComptime(.{
        .{ "image/black-cat-typing.gif", @embedFile("assets/image/black-cat-typing.gif") },
    });

    pub fn load(_: *Assets, path: []const u8) ?[]const u8 {
        return files.get(path);
    }
};

var assets: Assets = .{};

const GifViewer = struct {
    gif_path: []const u8,

    pub fn render(self: *GifViewer, _: *Window, _: *Context(GifViewer)) *Div {
        return div().size_full().child(
            img(self.gif_path)
                .size_full()
                .object_fit(gpui.ObjectFit.contain)
                .id("gif"),
        );
    }
};

fn run_example(cx: *App) void {
    // example_support::load_fonts is not ported (see the note at the top of this file).
    _ = cx.open_window(.{ .focus = true }, struct {
        fn build(_: *Window, app: *App) gpui.Entity(GifViewer) {
            return app.new(GifViewer{ .gif_path = "image/black-cat-typing.gif" });
        }
    }.build) catch unreachable;
    cx.activate(true);
}

pub fn main() void {
    gpui.Application.new().with_assets(&assets).run(run_example);
}
