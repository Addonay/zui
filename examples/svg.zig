//! Port of GPUI's `examples/svg/svg.rs`.
//!
//! The Rust version reads assets from `examples/` at run time. This port embeds
//! the files it uses with `@embedFile`, so it does not depend on the working directory.

const std = @import("std");
const gpui = @import("zui");
const App = gpui.App;
const Bounds = gpui.Bounds;
const Context = gpui.Context;
const Window = gpui.Window;
const WindowBounds = gpui.WindowBounds;
const WindowOptions = gpui.WindowOptions;
const div = gpui.div;
const px = gpui.px;
const rgb = gpui.rgb;
const size = gpui.size;
const svg = gpui.svg;

/// GPUI's `Assets` (an `AssetSource` over `examples/`), limited to the files this example loads.
const Assets = struct {
    const files = std.StaticStringMap([]const u8).initComptime(.{
        .{ "svg/dragon.svg", @embedFile("assets/svg/dragon.svg") },
    });

    pub fn load(_: *Assets, path: []const u8) ?[]const u8 {
        return files.get(path);
    }
};

var assets: Assets = .{};

const SvgExample = struct {
    pub fn render(_: *SvgExample, _: *Window, _: *Context(SvgExample)) *gpui.Div {
        return div()
            .flex()
            .flex_row()
            .size_full()
            .justify_center()
            .items_center()
            .gap_8()
            .bg(rgb(0xffffff))
            .child(
                svg()
                    .path("svg/dragon.svg")
                    .size_8()
                    .text_color(rgb(0xff0000)),
            )
            .child(
                svg()
                    .path("svg/dragon.svg")
                    .size_8()
                    .text_color(rgb(0x00ff00)),
            )
            .child(
                svg()
                    .path("svg/dragon.svg")
                    .size_8()
                    .text_color(rgb(0x0000ff)),
            );
    }
};

fn run_example(cx: *App) void {
    // example_support::load_fonts is not ported (no TextSystem::add_fonts yet).
    const bounds = Bounds(gpui.Pixels).centered(null, size(px(300.0), px(300.0)), cx);
    _ = cx.open_window(.{ .window_bounds = .{ .windowed = bounds } }, struct {
        fn build(_: *Window, app: *App) gpui.Entity(SvgExample) {
            return app.new(SvgExample{});
        }
    }.build) catch unreachable;
    cx.activate(true);
}

pub fn main() void {
    gpui.Application.new().with_assets(&assets).run(run_example);
}
