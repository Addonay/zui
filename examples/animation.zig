//! Port of GPUI's `examples/animation.rs`.
//!
//! Differences from the Rust version:
//! - Assets are embedded with `@embedFile` (see `Assets`), keyed by the same relative path.
//! - Font loading (`example_support::load_fonts`) is not ported (no `TextSystem::add_fonts` yet).
//! - `percentage(delta)` is written as `delta * tau` (radians). ZUI has no `percentage` yet.
//! - `Div::debug_selector` is left out; only the Rust test uses it.

const std = @import("std");
const gpui = @import("zui");
const App = gpui.App;
const AnimationPhase = gpui.spring.AnimationPhase;
const Bounds = gpui.Bounds;
const ClickEvent = gpui.ClickEvent;
const Context = gpui.Context;
const Div = gpui.Div;
const MouseDownEvent = gpui.MouseDownEvent;
const MouseMoveEvent = gpui.MouseMoveEvent;
const MouseUpEvent = gpui.MouseUpEvent;
const Pixels = gpui.Pixels;
const SpringAnimation = gpui.SpringAnimation;
const SpringConfig = gpui.SpringConfig;
const Transformation = gpui.Transformation;
const Window = gpui.Window;
const WindowBounds = gpui.WindowBounds;
const WindowOptions = gpui.WindowOptions;
const div = gpui.div;
const px = gpui.px;
const relative = gpui.relative;
const rgba = gpui.rgba;
const size = gpui.size;
const svg = gpui.svg;

/// GPUI's `Assets` (an `AssetSource` over `examples/`), limited to the files this example loads.
const Assets = struct {
    const files = std.StaticStringMap([]const u8).initComptime(.{
        .{ "image/arrow_circle.svg", @embedFile("assets/image/arrow_circle.svg") },
    });

    pub fn load(_: *Assets, path: []const u8) ?[]const u8 {
        return files.get(path);
    }
};

var assets: Assets = .{};

const ARROW_CIRCLE_SVG = "image/arrow_circle.svg";

const MINIMUM_DAMPING: f32 = 2.0;
const MAXIMUM_DAMPING: f32 = 32.0;
const DAMPING_SLIDER_WIDTH: Pixels = px(224.0);

const AnimationExample = struct {
    spring_phase: u8,
    spring_damping: f32,
    spring_damping_drag: ?struct { Pixels, f32 },

    fn phase_click(this: *AnimationExample, _: *const MouseDownEvent, _: *Window, cx: *Context(AnimationExample)) void {
        this.spring_phase = (this.spring_phase + 1) % 3;
        cx.notify();
    }

    fn stop_click(_: *const ClickEvent, window: *Window, _: *App) void {
        window.stop_propagation();
    }

    fn damping_mouse_down(this: *AnimationExample, event: *const MouseDownEvent, window: *Window, _: *Context(AnimationExample)) void {
        this.spring_damping_drag = .{ event.position.x, this.spring_damping };
        window.stop_propagation();
    }

    fn damping_mouse_move(this: *AnimationExample, event: *const MouseMoveEvent, window: *Window, cx: *Context(AnimationExample)) void {
        const drag = this.spring_damping_drag orelse return;
        const start_position, const start_damping = drag;

        const delta = (event.position.x - start_position) / DAMPING_SLIDER_WIDTH;
        this.spring_damping = std.math.clamp(
            start_damping + delta * (MAXIMUM_DAMPING - MINIMUM_DAMPING),
            MINIMUM_DAMPING,
            MAXIMUM_DAMPING,
        );
        window.stop_propagation();
        cx.notify();
    }

    fn damping_mouse_up(this: *AnimationExample, _: *const MouseUpEvent, window: *Window, _: *Context(AnimationExample)) void {
        this.spring_damping_drag = null;
        window.stop_propagation();
    }

    /// `.with_spring("spring-position", ..., |this, left| this.left(left))`.
    fn position_animator(this: *Div, left: f32) *Div {
        return this.left(px(left));
    }

    /// `.with_spring("spring-phase", ..., |this, phase| { ... this.w(width).bg(color) })`.
    fn phase_animator(this: *Div, phase: AnimationPhase) *Div {
        var width: Pixels = undefined;
        var color: gpui.Rgba = undefined;
        if (phase.value <= 1.0) {
            width = phase.interpolate_between(.{ 0.0, 1.0 }, px(48.0), px(224.0));
            color = phase.interpolate_between_clamped(.{ 0.0, 1.0 }, rgba(0xf97316ff), rgba(0x22c55eff));
        } else {
            width = phase.interpolate_between(.{ 1.0, 2.0 }, px(224.0), px(96.0));
            color = phase.interpolate_between_clamped(.{ 1.0, 2.0 }, rgba(0x22c55eff), rgba(0xa855f7ff));
        }
        return this.w(width).bg(color);
    }

    /// `.with_animation("image_circle", ..., |svg, delta| svg.with_transformation(rotate(percentage(delta))))`.
    fn spin(icon: *gpui.Svg, delta: f32) *gpui.Svg {
        // GPUI's `percentage(delta)` is `delta` of a full turn; `Transformation.rotate` takes radians.
        return icon.with_transformation(Transformation.rotate(delta * std.math.tau));
    }

    pub fn render(self: *AnimationExample, _: *Window, cx: *Context(AnimationExample)) *Div {
        const spring_phase = self.spring_phase;
        const spring_position = px(98.0 * @as(f32, @floatFromInt(spring_phase)));
        const spring_damping = self.spring_damping;
        const spring = SpringConfig.new(170.0, spring_damping, 1.0);
        const damping_ratio = spring.canonical()[1];
        const damping_fraction = (spring_damping - MINIMUM_DAMPING) / (MAXIMUM_DAMPING - MINIMUM_DAMPING);

        return div()
            .flex()
            .flex_col()
            .size_full()
            .bg(gpui.white())
            .text_color(gpui.black())
            .justify_around()
            .child(
                div()
                    .flex()
                    .flex_col()
                    .size_full()
                    .justify_around()
                    .child(
                        div()
                            .id("content")
                            .flex()
                            .flex_col()
                            .h(px(150.0))
                            .overflow_y_scroll()
                            .w_full()
                            .flex_1()
                            .justify_center()
                            .items_center()
                            .text_xl()
                            .gap_4()
                            .child("Hello Animation")
                            .child(
                                div()
                                    .id("spring-demo")
                                    .flex()
                                    .flex_col()
                                    .gap_2()
                                    .p_2()
                                    .w(px(240.0))
                                    .rounded_md()
                                    .bg(rgba(0x00000010))
                                    .cursor_pointer()
                                    .on_mouse_down(.left, cx.listener(AnimationExample.phase_click))
                                    .child(gpui.format("Target phase {d}: click rapidly to redirect momentum", .{spring_phase}))
                                    .child(
                                        div()
                                            .id("spring-damping-controls")
                                            .flex()
                                            .flex_col()
                                            .gap_1()
                                            .text_sm()
                                            .on_click(stop_click)
                                            .child(gpui.format("Drag damping: {d:.1} (ζ {d:.2})", .{ spring_damping, damping_ratio }))
                                            .child(
                                                div()
                                                    .id("spring-damping")
                                                    .relative()
                                                    .h(px(20.0))
                                                    .w(DAMPING_SLIDER_WIDTH)
                                                    .cursor_pointer()
                                                    .on_mouse_down(.left, cx.listener(damping_mouse_down))
                                                    .on_mouse_move(cx.listener(damping_mouse_move))
                                                    .on_mouse_up(.left, cx.listener(damping_mouse_up))
                                                    .on_mouse_up_out(.left, cx.listener(damping_mouse_up))
                                                    .child(
                                                        div()
                                                            .absolute()
                                                            .top(px(8.0))
                                                            .h(px(4.0))
                                                            .w_full()
                                                            .rounded_full()
                                                            .bg(rgba(0x00000030)),
                                                    )
                                                    .child(
                                                        div()
                                                            .absolute()
                                                            .top(px(8.0))
                                                            .h(px(4.0))
                                                            .w(relative(damping_fraction))
                                                            .rounded_full()
                                                            .bg(rgba(0x3b82f6ff)),
                                                    )
                                                    .child(
                                                        div()
                                                            .absolute()
                                                            .top(px(3.0))
                                                            .left(relative(damping_fraction))
                                                            .ml(px(-7.0))
                                                            .size(px(14.0))
                                                            .rounded_full()
                                                            .bg(rgba(0x2563ebff)),
                                                    ),
                                            ),
                                    )
                                    .child(
                                        div().relative().h(px(32.0)).w_full().child(
                                            // Missing: `.debug_selector("spring-position")` (only used by the Rust test).
                                            // `with_spring` is the free function: `StyledElement` has no alias for it yet.
                                            gpui.with_spring(
                                                div()
                                                    .absolute()
                                                    .top_1()
                                                    .size(px(24.0))
                                                    .rounded_full()
                                                    .bg(rgba(0x3b82f6ff))
                                                    .cursor_pointer(),
                                                "spring-position",
                                                SpringAnimation.new(spring).to(spring_position).with_epsilon(0.25),
                                                position_animator,
                                            ),
                                        ),
                                    )
                                    .child(
                                        gpui.with_spring(
                                            div().h(px(24.0)).rounded_sm(),
                                            "spring-phase",
                                            SpringAnimation.new(spring)
                                                .to(AnimationPhase{ .value = @floatFromInt(spring_phase) })
                                                .with_epsilon(0.001),
                                            phase_animator,
                                        ),
                                    ),
                            )
                            .child(
                                gpui.with_animation(
                                    svg()
                                        .size_20()
                                        .overflow_hidden()
                                        .path(ARROW_CIRCLE_SVG)
                                        .text_color(gpui.black()),
                                    "image_circle",
                                    gpui.Animation.new(2000).repeat().with_easing(gpui.bounce(gpui.ease_in_out)),
                                    spin,
                                ),
                            ),
                    )
                    .child(
                        div()
                            .flex()
                            .h(px(64.0))
                            .w_full()
                            .p_2()
                            .justify_center()
                            .items_center()
                            .border_t_1()
                            .border_color(gpui.black().opacity(0.1))
                            .bg(gpui.black().opacity(0.05))
                            .child("Other Panel"),
                    ),
            );
    }
};

fn run_example(cx: *App) void {
    // example_support::load_fonts is not ported (no TextSystem::add_fonts yet).
    const options = WindowOptions{
        .window_bounds = .{ .windowed = Bounds(Pixels).centered(null, size(px(300.0), px(300.0)), cx) },
    };
    _ = cx.open_window(options, struct {
        fn build(_: *Window, app: *App) gpui.Entity(AnimationExample) {
            app.activate(false);
            return app.new(AnimationExample{
                .spring_phase = 0,
                .spring_damping = 14.0,
                .spring_damping_drag = null,
            });
        }
    }.build) catch unreachable;
}

pub fn main() void {
    gpui.Application.new().with_assets(&assets).run(run_example);
}
