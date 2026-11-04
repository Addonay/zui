//! Port of GPUI's `examples/opacity.rs`.
//!
//! Differences from the Rust version:
//! - Assets are embedded with `@embedFile` (see `Assets`).
//! - `image/black-cat-typing.gif` (4.4 MB) is not copied into `examples/assets/`, so the
//!   GIF in the panel does not load and is not drawn.
//! - Font loading (`example_support::load_fonts`) is not ported (no `TextSystem::add_fonts` yet).

const std = @import("std");
const gpui = @import("zui");
const App = gpui.App;
const Bounds = gpui.Bounds;
const BoxShadow = gpui.BoxShadow;
const ClickEvent = gpui.ClickEvent;
const Context = gpui.Context;
const Div = gpui.Div;
const Window = gpui.Window;
const WindowBounds = gpui.WindowBounds;
const WindowOptions = gpui.WindowOptions;
const div = gpui.div;
const hsla = gpui.hsla;
const img = gpui.img;
const px = gpui.px;
const rgb = gpui.rgb;
const size = gpui.size;
const svg = gpui.svg;

/// GPUI's `Assets` (an `AssetSource` over `examples/`), limited to the files this example loads.
const Assets = struct {
    const files = std.StaticStringMap([]const u8).initComptime(.{
        .{ "image/app-icon.png", @embedFile("assets/image/app-icon.png") },
        .{ "image/arrow_circle.svg", @embedFile("assets/image/arrow_circle.svg") },
    });

    pub fn load(_: *Assets, path: []const u8) ?[]const u8 {
        return files.get(path);
    }
};

var assets: Assets = .{};

/// `vec![...]` in Rust: copies the shadow list into the frame arena so the
/// slice outlives this function's stack frame.
fn shadows(list: []const BoxShadow) []const BoxShadow {
    return gpui.window.frame_arena().dupe(BoxShadow, list) catch @panic("OOM");
}

fn emoji(e: []const u8) *Div {
    return div()
        .child(e)
        .hover(gpui.style_refinement().opacity(0.5));
}

const HelloWorld = struct {
    _task: ?gpui.Task(void) = null,
    opacity: f32,
    animating: bool,

    fn new() HelloWorld {
        return .{
            ._task = null,
            .opacity = 0.5,
            .animating = false,
        };
    }

    fn start_animation(self: *HelloWorld, _: *const ClickEvent, _: *Window, cx: *Context(HelloWorld)) void {
        self.opacity = 0.0;
        self.animating = true;
        cx.notify();
    }

    pub fn render(self: *HelloWorld, window: *Window, cx: *Context(HelloWorld)) *Div {
        if (self.animating) {
            self.opacity += 0.005;
            if (self.opacity >= 1.0) {
                self.animating = false;
                self.opacity = 1.0;
            } else {
                window.request_animation_frame();
            }
        }

        return div()
            .flex()
            .flex_row()
            .size_full()
            .bg(rgb(0xe0e0e0))
            .text_xl()
            .child(
                div()
                    .flex()
                    .size_full()
                    .justify_center()
                    .items_center()
                    .border_1()
                    .text_color(gpui.blue())
                    .child(div().child("This is background text.")),
            )
            .child(
                div()
                    .id("panel")
                    .on_click(cx.listener(HelloWorld.start_animation))
                    .absolute()
                    .top_8()
                    .left_8()
                    .right_8()
                    .bottom_8()
                    .opacity(self.opacity)
                    .flex()
                    .justify_center()
                    .items_center()
                    .bg(gpui.white())
                    .border_3()
                    .border_color(gpui.red())
                    .text_color(gpui.yellow())
                    .child(
                        div()
                            .flex()
                            .flex_col()
                            .gap_2()
                            .justify_center()
                            .items_center()
                            .size(px(300.0))
                            .bg(gpui.blue())
                            .border_3()
                            .border_color(gpui.black())
                            .shadow(shadows(&.{
                                BoxShadow.new(px(10.0), px(10.0), hsla(0.0, 0.0, 0.0, 0.5)).with_blur_radius(px(1.0)).with_spread_radius(px(5.0)),
                            }))
                            .child(img("image/app-icon.png").size_8())
                            .child("Opacity Panel (Click to test)")
                            .child(
                                div()
                                    .id("deep-level-text")
                                    .flex()
                                    .justify_center()
                                    .items_center()
                                    .p_4()
                                    .bg(gpui.black())
                                    .text_color(gpui.white())
                                    .text_decoration_2()
                                    .text_decoration_wavy()
                                    .text_decoration_color(gpui.red())
                                    .child(gpui.format("opacity: {d:.1}", .{self.opacity})),
                            )
                            .child(
                                svg()
                                    .path("image/arrow_circle.svg")
                                    .text_color(gpui.black())
                                    .text_2xl()
                                    .size_8(),
                            )
                            .child(
                                div()
                                    .flex()
                                    .children(.{
                                        emoji("🎊"),
                                        emoji("✈️"),
                                        emoji("🎉"),
                                        emoji("🎈"),
                                        emoji("🎁"),
                                        emoji("🎂"),
                                    }),
                            )
                            .child(img("image/black-cat-typing.gif").size_12()),
                    ),
            );
    }
};

fn run_example(cx: *App) void {
    // example_support::load_fonts is not ported (no TextSystem::add_fonts yet).
    const bounds = Bounds(gpui.Pixels).centered(null, size(px(500.0), px(500.0)), cx);
    _ = cx.open_window(.{ .window_bounds = .{ .windowed = bounds } }, struct {
        fn build(_: *Window, app: *App) gpui.Entity(HelloWorld) {
            return app.new(HelloWorld.new());
        }
    }.build) catch unreachable;
    cx.activate(true);
}

pub fn main() void {
    gpui.Application.new().with_assets(&assets).run(run_example);
}
