//! Port of GPUI's `examples/window_shadow.rs`.
//!
//! Differences from the Rust version:
//! - Font loading (`example_support::load_fonts`) is not ported (no `TextSystem::add_fonts` yet).
//! - The Rust closures that capture `shadow_size`, `rounding` and the decorations are file
//!   constants and plain functions here, since Zig has no closures.
//! - The observer is registered on the entity in the window builder, through `Entity.update`,
//!   because `Context(T)` has no window of its own.
//! - Client decorations need a compositor on X11, as in GPUI: without one the window manager
//!   keeps the frame and `window_decorations()` reports `.server`, so the custom titlebar is
//!   not drawn there. Wayland and the headless platform honour the request.

const gpui = @import("zui");
const App = gpui.App;
const Bounds = gpui.Bounds;
const BoxShadow = gpui.BoxShadow;
const Context = gpui.Context;
const CursorStyle = gpui.CursorStyle;
const Decorations = gpui.Decorations;
const Div = gpui.Div;
const Entity = gpui.Entity;
const Hitbox = gpui.Hitbox;
const HitboxBehavior = gpui.HitboxBehavior;
const Hsla = gpui.Hsla;
const MouseButton = gpui.MouseButton;
const MouseDownEvent = gpui.MouseDownEvent;
const MouseMoveEvent = gpui.MouseMoveEvent;
const ClickEvent = gpui.ClickEvent;
const Pixels = gpui.Pixels;
const Point = gpui.Point;
const ResizeEdge = gpui.ResizeEdge;
const Size = gpui.Size;
const Window = gpui.Window;
const WindowBackgroundAppearance = gpui.WindowBackgroundAppearance;
const WindowDecorations = gpui.WindowDecorations;
const WindowOptions = gpui.WindowOptions;
const black = gpui.black;
const canvas = gpui.canvas;
const div = gpui.div;
const green = gpui.green;
const point = gpui.point;
const px = gpui.px;
const rgb = gpui.rgb;
const size = gpui.size;
const transparent_black = gpui.transparent_black;
const white = gpui.white;

const SHADOW_SIZE: Pixels = 10.0;
const ROUNDING: Pixels = 10.0;
const BORDER_SIZE: Pixels = 1.0;

// Things to do:
// 1. We need a way of calculating which edge or corner the mouse is on,
//    and then dispatch on that
// 2. We need to improve the shadow rendering significantly
// 3. We need to implement the techniques in here in Zed

const WindowShadow = struct {
    fn on_appearance_changed(_: *WindowShadow, window: *Window, _: *Context(WindowShadow)) void {
        window.refresh();
    }

    fn observe_appearance(_: *WindowShadow, window: *Window, cx: *Context(WindowShadow)) void {
        _ = cx.observe_window_appearance(window, on_appearance_changed);
    }

    fn on_backdrop_mouse_move(_: *const MouseMoveEvent, window: *Window, _: *App) void {
        window.refresh();
    }

    fn on_backdrop_mouse_down(e: *const MouseDownEvent, window: *Window, _: *App) void {
        const win_size = window.window_bounds().get_bounds().size;
        if (resize_edge(e.position, SHADOW_SIZE, win_size)) |edge| {
            window.start_window_resize(edge);
        } else {
            window.start_window_move();
        }
    }

    fn on_inner_mouse_move(_: *const MouseMoveEvent, window: *Window, _: *App) void {
        window.stop_propagation();
    }

    fn on_titlebar_mouse_down(_: *const MouseDownEvent, window: *Window, _: *App) void {
        window.start_window_move();
    }

    fn on_titlebar_click(e: *const ClickEvent, window: *Window, _: *App) void {
        if (e.is_right_click()) {
            window.show_window_menu(e.position());
        }
    }

    pub fn render(_: *WindowShadow, window: *Window, _: *Context(WindowShadow)) *Div {
        const decorations = window.window_decorations();
        window.set_client_inset(SHADOW_SIZE);

        const grey = rgb(0x808080);
        var backdrop = div().id("window-backdrop").bg(transparent_black());
        switch (decorations) {
            .server => {},
            .client => |client| {
                backdrop = backdrop.bg(transparent_black());
                backdrop = backdrop.child(
                    canvas(EdgeCtx{}, prepaint_edges, paint_edges).size_full().absolute(),
                );
                if (!(client.tiling.top or client.tiling.right)) backdrop = backdrop.rounded_tr(ROUNDING);
                if (!(client.tiling.top or client.tiling.left)) backdrop = backdrop.rounded_tl(ROUNDING);
                if (!client.tiling.top) backdrop = backdrop.pt(SHADOW_SIZE);
                if (!client.tiling.bottom) backdrop = backdrop.pb(SHADOW_SIZE);
                if (!client.tiling.left) backdrop = backdrop.pl(SHADOW_SIZE);
                if (!client.tiling.right) backdrop = backdrop.pr(SHADOW_SIZE);
                backdrop = backdrop
                    .on_mouse_move(on_backdrop_mouse_move)
                    .on_mouse_down(MouseButton.left, on_backdrop_mouse_down);
            },
        }
        backdrop = backdrop.size_full();

        var inner = div().cursor(CursorStyle.arrow);
        switch (decorations) {
            .server => {},
            .client => |client| {
                inner = inner.border_color(grey);
                if (!(client.tiling.top or client.tiling.right)) inner = inner.rounded_tr(ROUNDING);
                if (!(client.tiling.top or client.tiling.left)) inner = inner.rounded_tl(ROUNDING);
                if (!client.tiling.top) inner = inner.border_t(BORDER_SIZE);
                if (!client.tiling.bottom) inner = inner.border_b(BORDER_SIZE);
                if (!client.tiling.left) inner = inner.border_l(BORDER_SIZE);
                if (!client.tiling.right) inner = inner.border_r(BORDER_SIZE);
                if (!client.tiling.is_tiled()) {
                    inner = inner.shadow(shadows(&.{
                        BoxShadow.new(px(0.0), px(0.0), Hsla{ .h = 0.0, .s = 0.0, .l = 0.0, .a = 0.4 })
                            .with_blur_radius(SHADOW_SIZE / 2.0),
                    }));
                }
            },
        }
        inner = inner
            .on_mouse_move(on_inner_mouse_move)
            .bg(rgb(0xCCCCFF))
            .size_full()
            .flex()
            .flex_col()
            .justify_around()
            .child(
                div().w_full().flex().flex_row().justify_around().child(
                    div()
                        .flex()
                        .bg(white())
                        .size(px(300.0))
                        .justify_center()
                        .items_center()
                        .shadow_lg()
                        .border_1()
                        .border_color(rgb(0x0000ff))
                        .text_xl()
                        .text_color(rgb(0xffffff))
                        .child(titlebar(decorations)),
                ),
            );

        return backdrop.child(inner);
    }
};

/// The custom titlebar: a green box that drags the window, with its label, when the app draws the frame.
fn titlebar(decorations: Decorations) *Div {
    var hello = div()
        .id("hello")
        .w(px(200.0))
        .h(px(100.0))
        .bg(green())
        .shadow(shadows(&.{
            BoxShadow.new(px(0.0), px(0.0), Hsla{ .h = 0.0, .s = 0.0, .l = 0.0, .a = 1.0 })
                .with_blur_radius(px(20.0)),
        }));
    switch (decorations) {
        .server => {},
        .client => {
            hello = hello
                .on_mouse_down(MouseButton.left, WindowShadow.on_titlebar_mouse_down)
                .on_click(WindowShadow.on_titlebar_click)
                .text_color(black())
                .child("this is the custom titlebar");
        },
    }
    return hello;
}

fn shadows(list: []const BoxShadow) []const BoxShadow {
    return gpui.window.frame_arena().dupe(BoxShadow, list) catch @panic("OOM");
}

/// The edge or corner of the window at `pos`, or null in the middle (GPUI `resize_edge`).
fn resize_edge(pos: Point(Pixels), shadow_size: Pixels, win_size: Size(Pixels)) ?ResizeEdge {
    if (pos.y < shadow_size and pos.x < shadow_size) return .top_left;
    if (pos.y < shadow_size and pos.x > win_size.width - shadow_size) return .top_right;
    if (pos.y < shadow_size) return .top;
    if (pos.y > win_size.height - shadow_size and pos.x < shadow_size) return .bottom_left;
    if (pos.y > win_size.height - shadow_size and pos.x > win_size.width - shadow_size) return .bottom_right;
    if (pos.y > win_size.height - shadow_size) return .bottom;
    if (pos.x < shadow_size) return .left;
    if (pos.x > win_size.width - shadow_size) return .right;
    return null;
}

/// The canvas over the shadow area: it sets the resize cursor for the edge under the mouse.
const EdgeCtx = struct {};

fn prepaint_edges(_: EdgeCtx, _: Bounds(Pixels), window: *Window, _: *App) Hitbox {
    const win_size = window.window_bounds().get_bounds().size;
    return window.insert_hitbox(.{ .origin = point(px(0.0), px(0.0)), .size = win_size }, HitboxBehavior.normal);
}

fn paint_edges(_: EdgeCtx, _: Bounds(Pixels), hitbox: *Hitbox, window: *Window, _: *App) void {
    const mouse = window.mouse_position();
    const win_size = window.window_bounds().get_bounds().size;
    const edge = resize_edge(mouse, SHADOW_SIZE, win_size) orelse return;
    window.set_cursor_style(switch (edge) {
        .top, .bottom => CursorStyle.resize_up_down,
        .left, .right => CursorStyle.resize_left_right,
        .top_left, .bottom_right => CursorStyle.resize_up_left_down_right,
        .top_right, .bottom_left => CursorStyle.resize_up_right_down_left,
    }, hitbox);
}

fn run_example(cx: *App) void {
    // example_support::load_fonts is not ported (no TextSystem::add_fonts yet).
    const bounds = Bounds(Pixels).centered(null, size(px(600.0), px(600.0)), cx);
    _ = cx.open_window(WindowOptions{
        .window_bounds = .{ .windowed = bounds },
        .window_background = WindowBackgroundAppearance.@"opaque",
        .window_decorations = WindowDecorations.client,
    }, build_window) catch unreachable;
}

fn build_window(window: *Window, app: *App) Entity(WindowShadow) {
    const entity = app.new(WindowShadow{});
    entity.update(app, WindowShadow.observe_appearance, .{window});
    return entity;
}

pub fn main() void {
    gpui.Application.new().run(run_example);
}
