//! Port of GPUI `elements/animation.rs`: animates an element over time with
//! easing functions, or drives it with a stateful spring. Times are nanoseconds.
//!
//! Differences from GPUI: animations run on the monotonic clock only (no synced
//! or `max_fps` throttled variants), and `reduce_motion` is honored through `App`.

const std = @import("std");
const element_mod = @import("../element.zig");
const window_mod = @import("../window.zig");
const app_mod = @import("../app.zig");
const geometry = @import("../geometry.zig");
const taffy = @import("../taffy.zig");
const spring = @import("../spring.zig");

const Window = window_mod.Window;
const App = app_mod.App;
const Pixels = geometry.Pixels;
const Bounds = geometry.Bounds;
const LayoutId = taffy.LayoutId;
const AnyElement = element_mod.AnyElement;
const ElementId = element_mod.ElementId;
const GlobalElementId = element_mod.GlobalElementId;
const SpringConfig = spring.SpringConfig;
const SpringState = spring.SpringState;
const SpringPlayback = spring.SpringPlayback;

/// A function mapping normalized time in 0..1 to an animated value. May overshoot.
pub const EasingFn = *const fn (f32) f32;

/// The linear easing function, or delta itself.
pub fn linear(delta: f32) f32 {
    return delta;
}

/// The quadratic easing function, delta * delta.
pub fn quadratic(delta: f32) f32 {
    return delta * delta;
}

/// Starts and ends slowly but speeds up in the middle.
pub fn ease_in_out(delta: f32) f32 {
    if (delta < 0.5) return 2.0 * delta * delta;
    const x = -2.0 * delta + 2.0;
    return 1.0 - x * x / 2.0;
}

/// Starts quickly and decelerates to a stop.
pub fn ease_out_quint(delta: f32) f32 {
    return 1.0 - std.math.pow(f32, 1.0 - delta, 5);
}

/// Applies `easing` forward over the first half and in reverse over the second half.
/// Comptime because the result closes over `easing`.
pub fn bounce(comptime easing: EasingFn) EasingFn {
    return struct {
        fn ease(delta: f32) f32 {
            if (delta < 0.5) return easing(delta * 2.0);
            return easing((1.0 - delta) * 2.0);
        }
    }.ease;
}

/// Pulsating alpha that slows down as it approaches `minimum`. Comptime because the result closes over the range.
pub fn pulsating_between(comptime minimum: f32, comptime maximum: f32) EasingFn {
    return struct {
        fn ease(delta: f32) f32 {
            const range = maximum - minimum;
            // Combine sine and cubic terms for a more natural breathing rhythm.
            const t = @sin(delta * 2.0 * std.math.pi);
            const breath = (t * t * t + t) / 2.0;
            const normalized_alpha = (breath + 1.0) / 2.0;
            return minimum + normalized_alpha * range;
        }
    }.ease;
}

/// An animation applied to an element (GPUI `Animation`).
pub const Animation = struct {
    /// The time for which this animation runs, in nanoseconds.
    duration: u64,
    /// Whether the animation runs once; when false it repeats.
    oneshot: bool = true,
    /// Maps normalized time to the animated value. The output is not clamped.
    easing: EasingFn = &linear,

    /// Creates an animation of `duration` nanoseconds, linear and run once.
    pub fn new(duration: u64) Animation {
        return .{ .duration = duration };
    }

    /// Makes the animation loop when it finishes.
    pub fn repeat(self: Animation) Animation {
        var copy = self;
        copy.oneshot = false;
        return copy;
    }

    /// Sets the easing function.
    pub fn with_easing(self: Animation, easing: EasingFn) Animation {
        var copy = self;
        copy.easing = easing;
        return copy;
    }
};

/// Persistent per-element progress through an animation chain.
const AnimationState = struct {
    start_ns: u64,
    animation_ix: usize = 0,
};

/// The result of advancing an animation by one frame.
const AnimationFrame = struct {
    animation_ix: usize,
    delta: f32,
    done: bool,
};

/// Advances `state` to `now` and returns the normalized, un-eased progress.
fn advance_animation(animations: []const Animation, state: *AnimationState, now: u64, reduce_motion: bool) AnimationFrame {
    if (reduce_motion) {
        const last = animations.len - 1;
        return .{ .animation_ix = last, .delta = if (animations[last].oneshot) 1.0 else 0.0, .done = true };
    }

    const animation_ix = state.animation_ix;
    const animation = animations[animation_ix];
    const elapsed = now -| state.start_ns;
    var delta: f32 = if (animation.duration == 0)
        1.0
    else
        @floatCast(@as(f64, @floatFromInt(elapsed)) / @as(f64, @floatFromInt(animation.duration)));
    var done = false;

    if (delta > 1.0) {
        if (animation.oneshot) {
            if (animation_ix >= animations.len - 1) {
                done = true;
            } else {
                state.start_ns = now;
                state.animation_ix += 1;
            }
            delta = 1.0;
        } else {
            delta = @rem(delta, 1.0);
        }
    }
    return .{ .animation_ix = animation_ix, .delta = delta, .done = done };
}

/// An element animated by `animator(element, animation_index, eased_delta)` (GPUI `AnimationElement`).
pub fn AnimationElement(comptime E: type, comptime animator: anytype) type {
    return struct {
        const Self = @This();

        pub const RequestLayoutState = AnyElement;
        pub const PrepaintState = void;

        key: ElementId,
        element: ?E,
        animations: []const Animation,

        pub fn id(self: *Self) ?ElementId {
            return self.key;
        }

        pub fn request_layout(self: *Self, gid: ?*const GlobalElementId, window: *Window, cx: *App) struct { LayoutId, AnyElement } {
            const now = @import("../executor.zig").now_ns();
            const state = window.element_state(AnimationState, (gid orelse unreachable).*, .{ .start_ns = now });
            const frame = advance_animation(self.animations, state, now, cx.reduce_motion);
            const eased = self.animations[frame.animation_ix].easing(frame.delta);

            const element = self.element orelse unreachable;
            self.element = null;
            const any = element_mod.into_any_element(animator(element, frame.animation_ix, eased));
            if (!frame.done) window.request_animation_frame();
            return .{ any.request_layout(window, cx), any };
        }

        pub fn prepaint(_: *Self, _: ?*const GlobalElementId, _: Bounds(Pixels), element: *AnyElement, window: *Window, cx: *App) void {
            element.prepaint(window, cx);
        }

        pub fn paint(_: *Self, _: ?*const GlobalElementId, _: Bounds(Pixels), element: *AnyElement, _: *void, window: *Window, cx: *App) void {
            element.paint(window, cx);
        }
    };
}

/// Persistent state of a spring-driven element.
const SpringElementState = struct {
    spring: SpringState,
    target: f32,
    config: SpringConfig,
    initial: f32,
    playback_mode: SpringPlayback,
    updated_at: u64,
};

/// An element whose animator receives a value driven by a spring (GPUI `SpringAnimationElement`).
pub fn SpringAnimationElement(comptime E: type, comptime T: type, comptime animator: anytype) type {
    return struct {
        const Self = @This();

        pub const RequestLayoutState = AnyElement;
        pub const PrepaintState = void;

        key: ElementId,
        element: ?E,
        config: SpringConfig,
        target: T,
        epsilon: f32,
        initial: ?f32,
        playback_mode: SpringPlayback,

        pub fn id(self: *Self) ?ElementId {
            return self.key;
        }

        pub fn request_layout(self: *Self, gid: ?*const GlobalElementId, window: *Window, cx: *App) struct { LayoutId, AnyElement } {
            const now = @import("../executor.zig").now_ns();
            const target_value = spring.spring_target(self.target);
            const initial = self.initial orelse target_value;
            const state = window.element_state(SpringElementState, (gid orelse unreachable).*, .{
                .spring = .{ .position = initial, .velocity = 0 },
                .target = target_value,
                .config = self.config,
                .initial = initial,
                .playback_mode = self.playback_mode,
                .updated_at = now,
            });

            const elapsed = spring.secs_f32(now -| state.updated_at);
            if (state.playback_mode == .running) {
                state.spring = state.config.step(state.spring, state.target, elapsed);
            }
            state.config = self.config;
            state.target = target_value;

            const done = switch (self.playback_mode) {
                .running => if (cx.reduce_motion) blk: {
                    state.spring = .{ .position = state.target, .velocity = 0 };
                    break :blk true;
                } else blk: {
                    const settled = state.config.is_settled(state.spring, state.target, self.epsilon);
                    if (settled) state.spring = .{ .position = state.target, .velocity = 0 };
                    break :blk settled;
                },
                .paused => true,
                .stopped => blk: {
                    state.spring.velocity = 0;
                    break :blk true;
                },
                .completed => blk: {
                    state.spring = .{ .position = state.target, .velocity = 0 };
                    break :blk true;
                },
                .cancelled => blk: {
                    state.spring = .{ .position = state.initial, .velocity = 0 };
                    break :blk true;
                },
            };
            state.playback_mode = self.playback_mode;
            state.updated_at = now;

            const element = self.element orelse unreachable;
            self.element = null;
            const value = spring.spring_resolve(self.target, state.spring.position);
            const any = element_mod.into_any_element(animator(element, value));
            if (!done) window.request_animation_frame();
            return .{ any.request_layout(window, cx), any };
        }

        pub fn prepaint(_: *Self, _: ?*const GlobalElementId, _: Bounds(Pixels), element: *AnyElement, window: *Window, cx: *App) void {
            element.prepaint(window, cx);
        }

        pub fn paint(_: *Self, _: ?*const GlobalElementId, _: Bounds(Pixels), element: *AnyElement, _: *void, window: *Window, cx: *App) void {
            element.paint(window, cx);
        }
    };
}

/// Adapts a one-value animator to the chain form used by `AnimationElement`.
fn SingleAnimator(comptime E: type, comptime animator: anytype) type {
    return struct {
        fn call(element: E, _: usize, delta: f32) E {
            return animator(element, delta);
        }
    };
}

/// The `with_animation`, `with_animations` and `with_spring` methods for an element of type `Self` (GPUI `AnimationExt`).
pub fn AnimationExt(comptime Self: type) type {
    return struct {
        /// Renders the element with `animation`, passing its eased progress to `animator`.
        pub fn with_animation(element: Self, id: anytype, animation: Animation, comptime animator: anytype) *AnimationElement(Self, SingleAnimator(Self, animator).call) {
            const animations = window_mod.frame_arena().dupe(Animation, &.{animation}) catch oom();
            return new_animation_element(Self, SingleAnimator(Self, animator).call, element, id, animations);
        }

        /// Renders the element with a chain of animations; `animator` receives the active index.
        pub fn with_animations(element: Self, id: anytype, animations: []const Animation, comptime animator: anytype) *AnimationElement(Self, animator) {
            const owned = window_mod.frame_arena().dupe(Animation, animations) catch oom();
            return new_animation_element(Self, animator, element, id, owned);
        }

        /// Renders the element at the value of a spring. The element id keeps position and velocity across target changes.
        pub fn with_spring(element: Self, id: anytype, animation: anytype, comptime animator: anytype) *SpringAnimationElement(Self, @TypeOf(animation.target), animator) {
            const Element = SpringAnimationElement(Self, @TypeOf(animation.target), animator);
            const created = window_mod.frame_arena().create(Element) catch oom();
            created.* = .{
                .key = ElementId.from(id),
                .element = element,
                .config = animation.config,
                .target = animation.target,
                .epsilon = animation.epsilon,
                .initial = animation.initial,
                .playback_mode = animation.playback_mode,
            };
            return created;
        }
    };
}

/// GPUI `with_animation`: animates any element pointer with one `Animation`.
pub fn with_animation(element: anytype, id: anytype, animation: Animation, comptime animator: anytype) *AnimationElement(@TypeOf(element), SingleAnimator(@TypeOf(element), animator).call) {
    return AnimationExt(@TypeOf(element)).with_animation(element, id, animation, animator);
}

/// GPUI `with_animations`: animates any element pointer with a chain of animations.
pub fn with_animations(element: anytype, id: anytype, animations: []const Animation, comptime animator: anytype) *AnimationElement(@TypeOf(element), animator) {
    return AnimationExt(@TypeOf(element)).with_animations(element, id, animations, animator);
}

/// GPUI `with_spring`: drives any element pointer with a spring animation.
pub fn with_spring(element: anytype, id: anytype, animation: anytype, comptime animator: anytype) *SpringAnimationElement(@TypeOf(element), @TypeOf(animation.target), animator) {
    return AnimationExt(@TypeOf(element)).with_spring(element, id, animation, animator);
}

fn new_animation_element(comptime E: type, comptime animator: anytype, element: E, id: anytype, animations: []const Animation) *AnimationElement(E, animator) {
    const Element = AnimationElement(E, animator);
    const created = window_mod.frame_arena().create(Element) catch oom();
    created.* = .{ .key = ElementId.from(id), .element = element, .animations = animations };
    return created;
}

fn oom() noreturn {
    @panic("out of memory");
}

test "linear, quadratic and ease in out endpoints" {
    try std.testing.expectEqual(@as(f32, 0.0), linear(0.0));
    try std.testing.expectEqual(@as(f32, 0.25), quadratic(0.5));
    try std.testing.expectEqual(@as(f32, 0.0), ease_in_out(0.0));
    try std.testing.expectEqual(@as(f32, 0.5), ease_in_out(0.5));
    try std.testing.expectEqual(@as(f32, 1.0), ease_in_out(1.0));
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), ease_out_quint(1.0), 1e-6);
}

test "bounce returns to the start" {
    const bounced = bounce(linear);
    try std.testing.expectEqual(@as(f32, 0.0), bounced(0.0));
    try std.testing.expectEqual(@as(f32, 1.0), bounced(0.5));
    try std.testing.expectEqual(@as(f32, 0.0), bounced(1.0));
}

test "pulsating easing stays inside its range" {
    const pulse = pulsating_between(0.2, 0.8);
    var step: usize = 0;
    while (step <= 100) : (step += 1) {
        const value = pulse(@as(f32, @floatFromInt(step)) / 100.0);
        try std.testing.expect(value >= 0.2 - 1e-5 and value <= 0.8 + 1e-5);
    }
}

test "oneshot animation reports progress then completes" {
    const animations = [_]Animation{Animation.new(1_000)};
    var state: AnimationState = .{ .start_ns = 0 };

    const halfway = advance_animation(&animations, &state, 500, false);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), halfway.delta, 1e-6);
    try std.testing.expect(!halfway.done);

    const finished = advance_animation(&animations, &state, 1_500, false);
    try std.testing.expectEqual(@as(f32, 1.0), finished.delta);
    try std.testing.expect(finished.done);
}

test "repeating animation wraps its phase" {
    const animations = [_]Animation{Animation.new(1_000).repeat()};
    var state: AnimationState = .{ .start_ns = 0 };
    const wrapped = advance_animation(&animations, &state, 1_250, false);
    try std.testing.expectApproxEqAbs(@as(f32, 0.25), wrapped.delta, 1e-6);
    try std.testing.expect(!wrapped.done);
}

test "animation chain advances to the next stage" {
    const animations = [_]Animation{ Animation.new(1_000), Animation.new(1_000) };
    var state: AnimationState = .{ .start_ns = 0 };

    const first = advance_animation(&animations, &state, 1_200, false);
    try std.testing.expectEqual(@as(usize, 0), first.animation_ix);
    try std.testing.expect(!first.done);
    try std.testing.expectEqual(@as(usize, 1), state.animation_ix);

    const second = advance_animation(&animations, &state, 1_700, false);
    try std.testing.expectEqual(@as(usize, 1), second.animation_ix);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), second.delta, 1e-6);
}

test "reduce motion renders a single static frame" {
    const oneshot = [_]Animation{Animation.new(1_000)};
    var state: AnimationState = .{ .start_ns = 0 };
    const frame = advance_animation(&oneshot, &state, 10, true);
    try std.testing.expectEqual(@as(f32, 1.0), frame.delta);
    try std.testing.expect(frame.done);

    const repeating = [_]Animation{Animation.new(1_000).repeat()};
    const repeated = advance_animation(&repeating, &state, 10, true);
    try std.testing.expectEqual(@as(f32, 0.0), repeated.delta);
}

// -- window tests -------------------------------------------------------------

const TestAppContext = @import("../app/test_context.zig").TestAppContext;
const div_mod = @import("div.zig");
const Div = div_mod.Div;
const Context = app_mod.Context;

/// The first spring value the animator received in the current test.
var test_spring_first: ?f32 = null;

fn grow_box(element: *Div, delta: f32) *Div {
    return element.w(geometry.px(10 + delta));
}

fn record_spring(element: *Div, value: f32) *Div {
    if (test_spring_first == null) test_spring_first = value;
    return element;
}

/// A view whose box is animated with a repeating animation.
const AnimationTestView = struct {
    pub fn render(_: *AnimationTestView, _: *Window, _: *Context(AnimationTestView)) *Div {
        return div_mod.div().size_full().child(with_animation(
            div_mod.div().id("box").w(geometry.px(10)).h(geometry.px(10)),
            "box-animation",
            Animation.new(60 * std.time.ns_per_s).repeat(),
            grow_box,
        ));
    }

    fn build(_: *Window, app: *App) app_mod.Entity(AnimationTestView) {
        return app.new(AnimationTestView{});
    }
};

/// A view whose box follows a spring from 0 towards 100.
const SpringTestView = struct {
    pub fn render(_: *SpringTestView, _: *Window, _: *Context(SpringTestView)) *Div {
        const animation = spring.SpringAnimation.new(spring.SpringConfig.new(100, 2, 1))
            .to(@as(f32, 100))
            .from(@as(f32, 0));
        return div_mod.div().size_full().child(with_spring(
            div_mod.div().id("spring-box").w(geometry.px(10)).h(geometry.px(10)),
            "spring-animation",
            animation,
            record_spring,
        ));
    }

    fn build(_: *Window, app: *App) app_mod.Entity(SpringTestView) {
        return app.new(SpringTestView{});
    }
};

test "with_animation requests animation frames while it runs" {
    var cx = TestAppContext.init();
    defer cx.deinit();
    _, const vcx = cx.add_window_view(AnimationTestView.build);
    try std.testing.expect(vcx.window.animation_requested);
}

test "with_animation renders a single static frame under reduce motion" {
    var cx = TestAppContext.init();
    defer cx.deinit();
    cx.app.set_reduce_motion(true);
    _, const vcx = cx.add_window_view(AnimationTestView.build);
    try std.testing.expect(!vcx.window.animation_requested);
}

test "with_spring drives the element from its initial value and keeps animating" {
    var cx = TestAppContext.init();
    defer cx.deinit();
    test_spring_first = null;
    _, const vcx = cx.add_window_view(SpringTestView.build);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), test_spring_first orelse return error.TestExpectedEqual, 1e-6);
    try std.testing.expect(vcx.window.animation_requested);
}
