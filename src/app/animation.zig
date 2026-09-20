//! Frame-driven animation primitives: duration tweens, analytic springs,
//! keyframe tracks, easings, and phase interpolation.
//!
//! This is the motion layer behind `Window.requestAnimation`: entities step
//! these states from the window clock in `render` and re-request frames
//! while anything is unsettled. The spring integrator is transliterated
//! from GPUI `crates/gpui/src/spring.rs` (analytic propagator, all three
//! damping regimes), so behavior matches GPUI's springs; the tween/keyframe
//! API is ZUI's own (Zig has no closure capture, so easings are function
//! pointers and animated outputs are computed inline by the caller).
//!
//! Image/SVG rotation, scale, and translation are emitted through the scene's
//! image-blit transform; arbitrary nested transforms and shear remain separate
//! work.

const std = @import("std");

// ---------------------------------------------------------------------------
// Easings — GPUI `elements/animation.rs` parity.
// ---------------------------------------------------------------------------

/// Linear easing: the identity.
pub fn linear(t: f32) f32 {
    return t;
}

/// Quadratic easing: t * t.
pub fn quadratic(t: f32) f32 {
    return t * t;
}

/// Quadratic ease-in-out: slow ends, fast middle.
pub fn easeInOut(t: f32) f32 {
    if (t < 0.5) return 2 * t * t;
    const x = -2 * t + 2;
    return 1 - x * x / 2;
}

/// Quint ease-out: fast start, decelerating stop.
pub fn easeOutQuint(t: f32) f32 {
    return 1 - std.math.pow(f32, 1 - t, 5);
}

/// Forward-then-reverse wrapper (GPUI `bounce(easing)` generalized: Zig
/// takes the inner easing as a function pointer).
pub fn bounce(t: f32, inner: *const fn (f32) f32) f32 {
    if (t < 0.5) return inner(t * 2) else return inner((1 - t) * 2);
}

/// The `bounce(ease_in_out)` composition by name.
pub fn bounceEaseInOut(t: f32) f32 {
    return bounce(t, &easeInOut);
}

/// Breathing alpha between min and max (GPUI `pulsating_between`).
pub fn pulsatingBetween(min: f32, max: f32, t: f32) f32 {
    const range = max - min;
    const s = @sin(t * 2 * std.math.pi);
    const breath = (s * s * s + s) / 2;
    return min + ((breath + 1) / 2) * range;
}

// ---------------------------------------------------------------------------
// Tween — duration-based animation with delay and repeat modes.
// ---------------------------------------------------------------------------

/// Duration-based animation state. Advance once per frame with clamped
/// seconds; read `delta()` (eased 0..1 progress) and map it onto any
/// property inline, like GPUI's `with_animation` closure does.
pub const Tween = struct {
    duration_s: f32,
    /// Start delay in seconds; `delta()` reads 0 until it elapses.
    delay_s: f32 = 0,
    /// Extra cycles after the first; null repeats forever.
    repeat: ?u32 = 0,
    /// Odd cycles run 1 → 0 instead of 0 → 1.
    pingpong: bool = false,
    easing: *const fn (f32) f32 = &linear,
    elapsed_s: f32 = 0,

    pub fn init(duration_s: f32) Tween {
        std.debug.assert(std.math.isFinite(duration_s) and duration_s >= 0);
        return .{ .duration_s = duration_s };
    }

    pub fn advance(self: *Tween, dt_s: f32) void {
        if (dt_s <= 0 or !std.math.isFinite(dt_s)) return;
        self.elapsed_s += dt_s;
    }

    /// Seconds into the run excluding the start delay (never negative).
    fn activeElapsed(self: *const Tween) f32 {
        return @max(0, self.elapsed_s - self.delay_s);
    }

    /// Completed full cycles (a partial final cycle does not count).
    pub fn completedCycles(self: *const Tween) u32 {
        if (self.duration_s <= 0) return 1;
        return @intFromFloat(@floor(self.activeElapsed() / self.duration_s));
    }

    pub fn done(self: *const Tween) bool {
        if (self.repeat) |extra| return self.completedCycles() > extra else return false;
    }

    /// Raw 0..1 progress within the current cycle (1 once finished).
    pub fn progress(self: *const Tween) f32 {
        if (self.duration_s <= 0) return 1;
        if (self.done()) return 1;
        const active = self.activeElapsed();
        if (active <= 0) return 0;
        return @min(1, (active - @as(f32, @floatFromInt(self.completedCycles())) * self.duration_s) / self.duration_s);
    }

    /// Eased progress, ping-pong reversed on odd cycles.
    pub fn delta(self: *const Tween) f32 {
        const p = self.progress();
        if (self.pingpong and !self.done() and self.completedCycles() % 2 == 1) {
            return self.easing(1 - p);
        }
        return self.easing(p);
    }

    /// Map the eased delta onto a scalar range.
    pub fn value(self: *const Tween, from: f32, to: f32) f32 {
        return from + (to - from) * self.delta();
    }
};

// ---------------------------------------------------------------------------
// GPUI Animation/AnimationElement policy without heap closures.
// ---------------------------------------------------------------------------

/// Declarative animation policy matching the source-level behavior of GPUI's
/// `Animation`: one-shot or repeating, optional shared-clock phase, easing,
/// and a render-rate cap. The element/view layer owns the property mapping;
/// this value owns only timing policy.
pub const Animation = struct {
    duration_s: f32,
    oneshot: bool = true,
    synced: bool = false,
    max_fps: ?f32 = null,
    easing: *const fn (f32) f32 = &linear,

    pub fn init(duration_s: f32) Animation {
        std.debug.assert(std.math.isFinite(duration_s) and duration_s >= 0);
        return .{ .duration_s = duration_s };
    }

    pub fn repeat(self: Animation) Animation {
        var out = self;
        out.oneshot = false;
        return out;
    }

    pub fn repeatSynced(self: Animation) Animation {
        var out = self.repeat();
        out.synced = true;
        return out;
    }

    pub fn withEasing(self: Animation, easing: *const fn (f32) f32) Animation {
        var out = self;
        out.easing = easing;
        return out;
    }

    pub fn withMaxFps(self: Animation, fps: f32) Animation {
        var out = self;
        out.max_fps = if (std.math.isFinite(fps) and fps > 0) fps else null;
        return out;
    }
};

/// Retained animation clock. Callers sample `phase()` while building an
/// element and request a new Window frame while `advance()` returns true.
/// `synced` tracks an externally supplied absolute clock through `setTime`,
/// avoiding a hidden global clock in headless tests.
pub const AnimationTrack = struct {
    animation: Animation,
    elapsed_s: f32 = 0,
    last_time_s: ?f32 = null,

    pub fn init(animation: Animation) AnimationTrack {
        return .{ .animation = animation };
    }

    pub fn reset(self: *AnimationTrack) void {
        self.elapsed_s = 0;
        self.last_time_s = null;
    }

    pub fn advance(self: *AnimationTrack, dt_s: f32) bool {
        if (dt_s > 0 and std.math.isFinite(dt_s)) self.elapsed_s += dt_s;
        return !self.done();
    }

    pub fn setTime(self: *AnimationTrack, absolute_s: f32) bool {
        if (!std.math.isFinite(absolute_s)) return !self.done();
        const previous = self.last_time_s orelse absolute_s;
        self.last_time_s = absolute_s;
        return self.advance(@max(0, absolute_s - previous));
    }

    pub fn cycles(self: *const AnimationTrack) u32 {
        if (self.animation.duration_s <= 0) return 1;
        return @intFromFloat(@floor(self.elapsed_s / self.animation.duration_s));
    }

    pub fn done(self: *const AnimationTrack) bool {
        return self.animation.oneshot and self.animation.duration_s > 0 and self.elapsed_s >= self.animation.duration_s;
    }

    pub fn phase(self: *const AnimationTrack) f32 {
        if (self.animation.duration_s <= 0) return 1;
        if (self.animation.oneshot) return self.animation.easing(@min(1, self.elapsed_s / self.animation.duration_s));
        const cycle = @as(f32, @floatFromInt(self.cycles()));
        return self.animation.easing((self.elapsed_s / self.animation.duration_s) - cycle);
    }

    pub fn nextFrameDelay(self: *const AnimationTrack) ?f32 {
        if (self.done()) return null;
        if (self.animation.max_fps) |fps| return 1 / fps;
        return 0;
    }
};

// ---------------------------------------------------------------------------
// Springs — transliterated from GPUI `crates/gpui/src/spring.rs`.
// ---------------------------------------------------------------------------

/// Damped harmonic oscillator parameters: stiffness k, damping c, mass m.
pub const SpringConfig = struct {
    stiffness: f32,
    damping: f32,
    mass: f32,

    pub fn init(stiffness: f32, damping: f32, mass: f32) SpringConfig {
        std.debug.assert(std.math.isFinite(stiffness) and stiffness > 0);
        std.debug.assert(std.math.isFinite(damping) and damping >= 0);
        std.debug.assert(std.math.isFinite(mass) and mass > 0);
        return .{ .stiffness = stiffness, .damping = damping, .mass = mass };
    }

    /// Natural angular frequency and damping ratio (ω₀, ζ).
    pub fn canonical(self: SpringConfig) struct { omega: f32, zeta: f32 } {
        return .{
            .omega = @sqrt(self.stiffness / self.mass),
            .zeta = self.damping / (2 * @sqrt(self.stiffness * self.mass)),
        };
    }

    /// Analytic step toward a fixed target. Frame-rate independent and
    /// velocity-preserving: retargeting mid-flight redirects momentum.
    pub fn step(self: SpringConfig, state: SpringState, target: f32, dt: f32) SpringState {
        const p = self.propagator(dt);
        const displacement = state.position - target;
        return .{
            .position = target + p[0][0] * displacement + p[0][1] * state.velocity,
            .velocity = p[1][0] * displacement + p[1][1] * state.velocity,
        };
    }

    /// Step toward a target moving at constant velocity (first-order hold,
    /// so a dragged target does not lag a frame behind).
    pub fn stepRamp(self: SpringConfig, state: SpringState, target: f32, target_velocity: f32, dt: f32) SpringState {
        const c = self.canonical();
        const lag = -2 * c.zeta * target_velocity / c.omega;
        const displacement = state.position - target - lag;
        const velocity = state.velocity - target_velocity;
        const p = self.propagator(dt);
        const moved = target + target_velocity * dt;
        return .{
            .position = moved + lag + p[0][0] * displacement + p[0][1] * velocity,
            .velocity = target_velocity + p[1][0] * displacement + p[1][1] * velocity,
        };
    }

    /// Exact state-transition matrix for a constant target. Must not be
    /// reused across differing frame deltas.
    pub fn propagator(self: SpringConfig, dt: f32) [2][2]f32 {
        const c = self.canonical();
        const w0 = c.omega;
        const zeta = c.zeta;
        const tolerance: f32 = 1e-4;
        if (zeta < 1 - tolerance) {
            const decay = zeta * w0;
            const wd = w0 * @sqrt(1 - zeta * zeta);
            const e = @exp(-decay * dt);
            const s = @sin(wd * dt);
            const co = @cos(wd * dt);
            const s_over_w = s / wd;
            return .{
                .{ e * (co + decay * s_over_w), e * s_over_w },
                .{ -e * w0 * w0 * s_over_w, e * (co - decay * s_over_w) },
            };
        } else if (zeta > 1 + tolerance) {
            const root = @sqrt(zeta * zeta - 1);
            const root_sum = zeta + root;
            const slow = -w0 / root_sum;
            const fast = -w0 * root_sum;
            const denom = slow - fast;
            const slow_e = @exp(slow * dt);
            const fast_e = @exp(fast * dt);
            return .{
                .{ (-fast * slow_e + slow * fast_e) / denom, (slow_e - fast_e) / denom },
                .{ slow * fast * (fast_e - slow_e) / denom, (slow * slow_e - fast * fast_e) / denom },
            };
        } else {
            const e = @exp(-w0 * dt);
            return .{
                .{ e * (1 + w0 * dt), e * dt },
                .{ -e * w0 * w0 * dt, e * (1 - w0 * dt) },
            };
        }
    }

    /// Settled when displacement is within epsilon and velocity within
    /// epsilon * ω₀ (matching animated-units-per-second scale).
    pub fn isSettled(self: SpringConfig, state: SpringState, target: f32, epsilon: f32) bool {
        const w0 = self.canonical().omega;
        return std.math.isFinite(epsilon) and epsilon >= 0 and
            @abs(state.position - target) <= epsilon and
            @abs(state.velocity) <= epsilon * w0;
    }

    /// Conservative seconds after which the spring stays settled, or null
    /// when no finite time exists (undamped / degenerate inputs). GPUI
    /// returns a Duration; seconds keep this free of clock types.
    pub fn settleTime(self: SpringConfig, state: SpringState, target: f32, epsilon: f32) ?f32 {
        const displacement = state.position - target;
        if (displacement == 0 and state.velocity == 0) return 0;
        const c = self.canonical();
        const w0 = c.omega;
        const zeta = c.zeta;
        if (!std.math.isFinite(w0) or w0 <= 0 or !std.math.isFinite(zeta) or zeta <= 0) return null;
        if (!std.math.isFinite(epsilon) or epsilon <= 0) return null;
        const velocity_threshold = epsilon * w0;
        const tolerance: f32 = 1e-4;
        if (zeta < 1 - tolerance) {
            const decay = zeta * w0;
            const wd = w0 * @sqrt(1 - zeta * zeta);
            const sine_coefficient = (state.velocity + decay * displacement) / wd;
            const position_envelope = @sqrt(displacement * displacement + sine_coefficient * sine_coefficient);
            const velocity_cosine = wd * sine_coefficient - decay * displacement;
            const velocity_sine = -wd * displacement - decay * sine_coefficient;
            const velocity_envelope = @sqrt(velocity_cosine * velocity_cosine + velocity_sine * velocity_sine);
            return findSettleTime(epsilon, velocity_threshold, 0, w0, .{ .exp = .{ .decay = decay, .position_envelope = position_envelope, .velocity_envelope = velocity_envelope } });
        } else if (zeta > 1 + tolerance) {
            const root = @sqrt(zeta * zeta - 1);
            const root_sum = zeta + root;
            const slow = -w0 / root_sum;
            const fast = -w0 * root_sum;
            const denom = slow - fast;
            const slow_coefficient = (state.velocity - fast * displacement) / denom;
            const fast_coefficient = (slow * displacement - state.velocity) / denom;
            return findSettleTime(epsilon, velocity_threshold, 0, w0, .{ .overdamped = .{ .slow = slow, .fast = fast, .slow_coefficient = slow_coefficient, .fast_coefficient = fast_coefficient } });
        } else {
            const linear_coefficient = state.velocity + w0 * displacement;
            const position_constant = @abs(displacement);
            const position_linear = @abs(linear_coefficient);
            const velocity_constant = @abs(linear_coefficient - w0 * displacement);
            const velocity_linear = w0 * @abs(linear_coefficient);
            const position_decay_start = envelopeDecayStart(position_constant, position_linear, w0);
            const velocity_decay_start = envelopeDecayStart(velocity_constant, velocity_linear, w0);
            return findSettleTime(epsilon, velocity_threshold, @max(position_decay_start, velocity_decay_start), w0, .{ .critical = .{ .w0 = w0, .position_constant = position_constant, .position_linear = position_linear, .velocity_constant = velocity_constant, .velocity_linear = velocity_linear } });
        }
    }
};

/// Instantaneous spring position and velocity.
pub const SpringState = struct {
    position: f32 = 0,
    velocity: f32 = 0,
};

/// How a stateful spring advances (GPUI `SpringPlayback`).
pub const SpringPlayback = enum {
    /// Advance toward the latest target, preserving velocity on retarget.
    running,
    /// Hold position and velocity until resumed.
    paused,
    /// Hold position, discard velocity.
    stopped,
    /// Snap to the latest target, discard velocity.
    completed,
    /// Return to the initial value, discard velocity.
    cancelled,
};

/// Stateful spring: config + target + playback mode + live state. A fresh
/// spring starts AT its target (GPUI mount behavior) unless constructed
/// with an explicit initial position.
pub const Spring = struct {
    config: SpringConfig,
    target: f32,
    epsilon: f32 = 0.001,
    initial: ?f32 = null,
    playback: SpringPlayback = .running,
    state: SpringState = .{},
    started: bool = false,

    pub fn init(config: SpringConfig, target: f32) Spring {
        return .{ .config = config, .target = target };
    }

    /// Advance one frame; returns true while still moving (caller keeps
    /// requesting animation frames). Applies playback semantics.
    pub fn advance(self: *Spring, dt_s: f32) bool {
        switch (self.playback) {
            .paused => return false,
            .stopped => {
                self.state.velocity = 0;
                return false;
            },
            .completed => {
                self.state = .{ .position = self.target, .velocity = 0 };
                self.started = true;
                return false;
            },
            .cancelled => {
                self.state = .{ .position = self.initial orelse self.target, .velocity = 0 };
                self.started = true;
                return false;
            },
            .running => {},
        }
        if (!self.started) {
            self.started = true;
            if (self.initial) |initial| {
                self.state = .{ .position = initial, .velocity = 0 };
            } else {
                self.state = .{ .position = self.target, .velocity = 0 };
                return false;
            }
        }
        self.state = self.config.step(self.state, self.target, @max(0, dt_s));
        return !self.config.isSettled(self.state, self.target, self.epsilon);
    }

    pub fn retarget(self: *Spring, target: f32) void {
        self.target = target;
        if (self.playback != .running) self.playback = .running;
    }

    pub fn settled(self: *const Spring) bool {
        return self.config.isSettled(self.state, self.target, self.epsilon);
    }
};

/// Adapts a zero-start spring to a duration-based easing (GPUI
/// `sampled_easing`). The easing can overshoot 0..1; retargeting restarts
/// it — use `SpringConfig.step` when velocity must survive.
pub const SampledEasing = struct {
    config: SpringConfig,
    duration_s: f32,

    pub fn init(config: SpringConfig, epsilon: f32) SampledEasing {
        // Zero-start spring toward 1.0; undamped never settles (infinite).
        const duration = config.settleTime(.{}, 1.0, epsilon) orelse std.math.inf(f32);
        return .{ .config = config, .duration_s = duration };
    }

    pub fn eval(self: *const SampledEasing, progress: f32) f32 {
        if (progress <= 0) return 0;
        if (progress >= 1) return 1;
        return self.config.step(.{}, 1.0, progress * self.duration_s).position;
    }
};

const Envelope = union(enum) {
    exp: struct { decay: f32, position_envelope: f32, velocity_envelope: f32 },
    overdamped: struct { slow: f32, fast: f32, slow_coefficient: f32, fast_coefficient: f32 },
    critical: struct { w0: f32, position_constant: f32, position_linear: f32, velocity_constant: f32, velocity_linear: f32 },
};

fn envelopeAt(env: Envelope, time: f32) struct { position: f32, velocity: f32 } {
    return switch (env) {
        .exp => |e| .{
            .position = e.position_envelope * @exp(-e.decay * time),
            .velocity = e.velocity_envelope * @exp(-e.decay * time),
        },
        .overdamped => |o| .{
            .position = @abs(o.slow_coefficient) * @exp(o.slow * time) + @abs(o.fast_coefficient) * @exp(o.fast * time),
            .velocity = @abs(o.slow) * @abs(o.slow_coefficient) * @exp(o.slow * time) + @abs(o.fast) * @abs(o.fast_coefficient) * @exp(o.fast * time),
        },
        .critical => |k| .{
            .position = (k.position_constant + k.position_linear * time) * @exp(-k.w0 * time),
            .velocity = (k.velocity_constant + k.velocity_linear * time) * @exp(-k.w0 * time),
        },
    };
}

fn envelopeDecayStart(constant: f32, linear_term: f32, decay: f32) f32 {
    if (linear_term == 0) return 0;
    return @max(0, 1 / decay - constant / linear_term);
}

fn findSettleTime(position_threshold: f32, velocity_threshold: f32, decay_start: f32, natural_frequency: f32, env: Envelope) ?f32 {
    const below = struct {
        fn below(position_threshold_: f32, velocity_threshold_: f32, env_: Envelope, time: f32) bool {
            const e = envelopeAt(env_, time);
            return e.position <= position_threshold_ and e.velocity <= velocity_threshold_;
        }
    }.below;
    if (below(position_threshold, velocity_threshold, env, decay_start)) return decay_start;
    var lower = decay_start;
    var upper = @max(decay_start, 1 / natural_frequency);
    while (!below(position_threshold, velocity_threshold, env, upper)) {
        lower = upper;
        upper *= 2;
        if (!std.math.isFinite(upper)) return null;
    }
    var i: usize = 0;
    while (i < 32) : (i += 1) {
        const mid = (lower + upper) / 2;
        if (below(position_threshold, velocity_threshold, env, mid)) {
            upper = mid;
        } else {
            lower = mid;
        }
    }
    return upper;
}

// ---------------------------------------------------------------------------
// Phase interpolation (GPUI `AnimationPhase`) and color lerp.
// ---------------------------------------------------------------------------

/// Interpolate over an arbitrary phase range (extrapolates outside it).
pub fn interpolateBetween(from: f32, to: f32, start: f32, end: f32, phase: f32) f32 {
    const t = if (start == end)
        (if (phase < start) @as(f32, 0) else @as(f32, 1))
    else
        (phase - start) / (end - start);
    return from + (to - from) * t;
}

/// Interpolate with the normalized coordinate clamped to 0..1.
pub fn interpolateBetweenClamped(from: f32, to: f32, start: f32, end: f32, phase: f32) f32 {
    const t = if (start == end)
        (if (phase < start) @as(f32, 0) else @as(f32, 1))
    else
        @min(1, @max(0, (phase - start) / (end - start)));
    return from + (to - from) * t;
}

pub fn lerpRgba(from: @import("../core/color.zig").Color, to: @import("../core/color.zig").Color, t: f32) @import("../core/color.zig").Color {
    return .{
        .r = from.r + (to.r - from.r) * t,
        .g = from.g + (to.g - from.g) * t,
        .b = from.b + (to.b - from.b) * t,
        .a = from.a + (to.a - from.a) * t,
    };
}

// ---------------------------------------------------------------------------
// Keyframes — timed scalar tracks with per-segment easings.
// ---------------------------------------------------------------------------

pub const Keyframe = struct {
    time_s: f32,
    value: f32,
    easing: *const fn (f32) f32 = &linear,
};

/// Borrowed, time-sorted track. Evaluate at any time; ends clamp.
pub const Keyframes = struct {
    frames: []const Keyframe,

    pub fn duration(self: *const Keyframes) f32 {
        if (self.frames.len == 0) return 0;
        return @max(0, self.frames[self.frames.len - 1].time_s);
    }

    pub fn eval(self: *const Keyframes, time_s: f32) f32 {
        if (self.frames.len == 0) return 0;
        if (time_s <= self.frames[0].time_s) return self.frames[0].value;
        var i: usize = 1;
        while (i < self.frames.len) : (i += 1) {
            if (time_s <= self.frames[i].time_s) {
                const a = self.frames[i - 1];
                const b = self.frames[i];
                const span = b.time_s - a.time_s;
                const t = if (span <= 0) @as(f32, 1) else (time_s - a.time_s) / span;
                return a.value + (b.value - a.value) * b.easing(@min(1, @max(0, t)));
            }
        }
        return self.frames[self.frames.len - 1].value;
    }
};

// ---------------------------------------------------------------------------
// Clock — window-time delta helper.
// ---------------------------------------------------------------------------

/// Tracks the last frame time and yields clamped seconds. Suspend/resume
/// gaps clamp to 0.1s so one step never explodes a spring or tween.
pub const Clock = struct {
    last_ms: ?i64 = null,

    pub fn tick(self: *Clock, now_ms: i64) f32 {
        const last = self.last_ms orelse now_ms;
        self.last_ms = now_ms;
        return @min(0.1, @max(0, @as(f32, @floatFromInt(now_ms - last)) / 1000));
    }
};

// ---------------------------------------------------------------------------
// Tests — spring math mirrors GPUI `spring.rs` test properties.
// ---------------------------------------------------------------------------

test "spring canonical frequency and damping ratio" {
    const config = SpringConfig.init(170.0, 14.0, 1.0);
    const c = config.canonical();
    try std.testing.expectApproxEqAbs(@sqrt(@as(f32, 170)), c.omega, 1e-4);
    try std.testing.expectApproxEqAbs(14.0 / (2 * @sqrt(@as(f32, 170))), c.zeta, 1e-4);
}

test "spring step composes across regimes (GPUI semigroup)" {
    const start = SpringState{ .position = -3, .velocity = 5 };
    for ([_]f32{ 4.0, 20.0, 40.0 }) |damping| {
        const config = SpringConfig.init(100.0, damping, 1.0);
        const stepped = config.step(config.step(start, 7.0, 0.013), 7.0, 0.021);
        const direct = config.step(start, 7.0, 0.034);
        try std.testing.expectApproxEqAbs(direct.position, stepped.position, 2e-4);
        try std.testing.expectApproxEqAbs(direct.velocity, stepped.velocity, 2e-4);
    }
}

test "propagators compose with the expected determinant" {
    for ([_]f32{ 0.4, 1.0, 1.5 }) |zeta| {
        const w0: f32 = 12.0;
        const config = SpringConfig.init(w0 * w0, 2 * zeta * w0, 1.0);
        const first = config.propagator(0.013);
        const second = config.propagator(0.021);
        const direct = config.propagator(0.034);
        // combined = second * first (matrix product)
        var combined: [2][2]f32 = undefined;
        for (0..2) |r| {
            for (0..2) |col| {
                combined[r][col] = second[r][0] * first[0][col] + second[r][1] * first[1][col];
            }
        }
        for (0..2) |r| {
            for (0..2) |col| {
                try std.testing.expectApproxEqAbs(direct[r][col], combined[r][col], 2e-4);
            }
        }
        const det = direct[0][0] * direct[1][1] - direct[0][1] * direct[1][0];
        try std.testing.expectApproxEqAbs(@exp(-2 * zeta * w0 * 0.034), det, 2e-4);
    }
}

test "ramp tracks steady-state lag" {
    const w0: f32 = 10.0;
    const zeta: f32 = 0.8;
    const target_velocity: f32 = 3.0;
    const config = SpringConfig.init(w0 * w0, 2 * zeta * w0, 1.0);
    const lag = -2 * zeta * target_velocity / w0;
    const next = config.stepRamp(.{ .position = lag, .velocity = target_velocity }, 0.0, target_velocity, 0.25);
    try std.testing.expectApproxEqAbs(target_velocity * 0.25 + lag, next.position, 1e-4);
    try std.testing.expectApproxEqAbs(target_velocity, next.velocity, 1e-4);
}

test "settling requires low velocity" {
    const config = SpringConfig.init(100.0, 10.0, 1.0);
    try std.testing.expect(!config.isSettled(.{ .position = 1, .velocity = 1 }, 1.0, 0.01));
    try std.testing.expect(config.isSettled(.{ .position = 1.005, .velocity = 0.05 }, 1.0, 0.01));
    var state = SpringState{};
    var i: usize = 0;
    while (i < 600) : (i += 1) state = config.step(state, 3.0, 1.0 / 60.0);
    try std.testing.expect(config.isSettled(state, 3.0, 0.001));
}

test "settle time is conservative, undamped never settles" {
    for ([_]f32{ 4.0, 20.0, 40.0 }) |damping| {
        const config = SpringConfig.init(100.0, damping, 1.0);
        const duration = config.settleTime(.{ .position = -2, .velocity = 4 }, 3.0, 0.001) orelse return error.TestExpectedSettleTime;
        for ([_]f32{ 0.0, 0.1, 1.0 }) |extra| {
            const state = config.step(.{ .position = -2, .velocity = 4 }, 3.0, duration + extra);
            try std.testing.expect(config.isSettled(state, 3.0, 0.001));
        }
    }
    const undamped = SpringConfig.init(100.0, 0.0, 1.0);
    try std.testing.expect(undamped.settleTime(.{ .position = 0, .velocity = 0 }, 1.0, 0.001) == null);
    try std.testing.expect(undamped.settleTime(.{ .position = -2, .velocity = 4 }, 1.0, 0.001) == null);
}

test "sampled easing has exact endpoints and can overshoot" {
    const config = SpringConfig.init(100.0, 6.0, 1.0);
    const easing = SampledEasing.init(config, 0.001);
    try std.testing.expect(std.math.isFinite(easing.duration_s));
    try std.testing.expectEqual(@as(f32, 0), easing.eval(0));
    try std.testing.expectEqual(@as(f32, 1), easing.eval(1));
    var overshoots = false;
    var step: usize = 1;
    while (step < 100) : (step += 1) {
        if (easing.eval(@as(f32, @floatFromInt(step)) / 100.0) > 1.0) overshoots = true;
    }
    try std.testing.expect(overshoots);
}

test "spring playback modes hold, snap, and resume" {
    var spring = Spring.init(SpringConfig.init(170.0, 14.0, 1.0), 98.0);
    // Fresh springs start at target and report no motion.
    try std.testing.expect(!spring.advance(1.0 / 60.0));
    try std.testing.expect(spring.settled());
    spring.retarget(196.0);
    try std.testing.expect(spring.advance(1.0 / 60.0)); // moving now
    spring.playback = .paused;
    const held = spring.state;
    try std.testing.expect(!spring.advance(1.0));
    try std.testing.expectEqual(held.position, spring.state.position);
    try std.testing.expectEqual(held.velocity, spring.state.velocity);
    spring.playback = .stopped;
    try std.testing.expect(!spring.advance(1.0));
    try std.testing.expectEqual(@as(f32, 0), spring.state.velocity);
    spring.playback = .completed;
    try std.testing.expect(!spring.advance(0));
    try std.testing.expectEqual(@as(f32, 196), spring.state.position);
    spring.playback = .cancelled;
    try std.testing.expect(!spring.advance(0));
    try std.testing.expectEqual(@as(f32, 196), spring.state.position); // no initial: falls back to target
}

test "spring retarget preserves velocity (momentum redirect)" {
    var spring = Spring.init(SpringConfig.init(170.0, 14.0, 1.0), 0.0);
    _ = spring.advance(1.0 / 60.0);
    spring.retarget(98.0);
    var i: usize = 0;
    while (i < 10) : (i += 1) _ = spring.advance(1.0 / 60.0);
    const velocity_before = spring.state.velocity;
    spring.retarget(196.0); // rapid re-click: no velocity reset
    try std.testing.expectEqual(velocity_before, spring.state.velocity);
}

test "easings match GPUI endpoints" {
    try std.testing.expectEqual(@as(f32, 0.3), linear(0.3));
    try std.testing.expectEqual(@as(f32, 0.25), quadratic(0.5));
    try std.testing.expectEqual(@as(f32, 0), easeInOut(0));
    try std.testing.expectEqual(@as(f32, 1), easeInOut(1));
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), easeInOut(0.5), 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 0), easeOutQuint(0), 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 1), easeOutQuint(1), 1e-6);
    try std.testing.expectEqual(@as(f32, 0), bounceEaseInOut(0));
    try std.testing.expectEqual(@as(f32, 0), bounceEaseInOut(1));
    try std.testing.expectEqual(@as(f32, 1), bounceEaseInOut(0.5));
    try std.testing.expect(pulsatingBetween(0.1, 0.9, 0) >= 0.1 and pulsatingBetween(0.1, 0.9, 0) <= 0.9);
}

test "tween delay, repeat, pingpong, and done" {
    var once = Tween.init(2.0);
    try std.testing.expectEqual(@as(f32, 0), once.delta());
    once.advance(1.0);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), once.delta(), 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 75), once.value(50, 100), 1e-4);
    try std.testing.expect(!once.done());
    once.advance(1.0);
    try std.testing.expect(once.done());
    try std.testing.expectEqual(@as(f32, 1), once.delta());

    var delayed = Tween{ .duration_s = 2.0, .delay_s = 1.0 };
    delayed.advance(0.5);
    try std.testing.expectEqual(@as(f32, 0), delayed.delta());
    delayed.advance(1.0); // 1.5 total, 0.5 into the run
    try std.testing.expectApproxEqAbs(@as(f32, 0.25), delayed.delta(), 1e-6);

    var thrice = Tween{ .duration_s = 1.0, .repeat = 2 };
    thrice.advance(2.5);
    try std.testing.expect(!thrice.done());
    try std.testing.expectEqual(@as(u32, 2), thrice.completedCycles());
    thrice.advance(0.5);
    try std.testing.expect(thrice.done());

    var forever = Tween{ .duration_s = 1.0, .repeat = null };
    forever.advance(1000.0);
    try std.testing.expect(!forever.done());

    var pingpong = Tween{ .duration_s = 1.0, .repeat = null, .pingpong = true };
    pingpong.advance(0.25);
    try std.testing.expectApproxEqAbs(@as(f32, 0.25), pingpong.delta(), 1e-6);
    pingpong.advance(1.0); // 1.25 total: odd cycle, reversed
    try std.testing.expectApproxEqAbs(@as(f32, 0.75), pingpong.delta(), 1e-6);
}

test "animation track repeats, throttles, syncs, and completes" {
    var track = AnimationTrack.init(Animation.init(2).repeat().withMaxFps(30));
    try std.testing.expect(track.advance(0.5));
    try std.testing.expectApproxEqAbs(@as(f32, 0.25), track.phase(), 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0 / 30.0), track.nextFrameDelay().?, 1e-6);
    try std.testing.expect(track.setTime(2.5));
    try std.testing.expectApproxEqAbs(@as(f32, 0.25), track.phase(), 1e-6);

    var once = AnimationTrack.init(Animation.init(1));
    try std.testing.expect(!once.advance(1.1));
    try std.testing.expectEqual(@as(f32, 1), once.phase());
    try std.testing.expect(once.nextFrameDelay() == null);
}

test "keyframes evaluate segments with easing and clamp ends" {
    const track = Keyframes{ .frames = &.{
        .{ .time_s = 0, .value = 0 },
        .{ .time_s = 1, .value = 10, .easing = &quadratic },
        .{ .time_s = 2, .value = 20 },
    } };
    try std.testing.expectEqual(@as(f32, 2), track.duration());
    try std.testing.expectEqual(@as(f32, 0), track.eval(-1)); // clamped start
    try std.testing.expectEqual(@as(f32, 0), track.eval(0));
    // Segment [0,1] eases with the END key's quadratic: 10 * 0.5² = 2.5.
    try std.testing.expectApproxEqAbs(@as(f32, 2.5), track.eval(0.5), 1e-5);
    try std.testing.expectEqual(@as(f32, 10), track.eval(1));
    // Segment [1,2] is linear: midpoint 15.
    try std.testing.expectApproxEqAbs(@as(f32, 15), track.eval(1.5), 1e-5);
    try std.testing.expectEqual(@as(f32, 20), track.eval(99)); // clamped end
    try std.testing.expectEqual(@as(f32, 0), (Keyframes{ .frames = &.{} }).eval(5));
}

test "phase interpolation over arbitrary ranges" {
    try std.testing.expectEqual(@as(f32, 15), interpolateBetween(10, 20, 1, 2, 1.5));
    try std.testing.expectEqual(@as(f32, 10), interpolateBetweenClamped(10, 20, 2, 3, 1.5));
    try std.testing.expectEqual(@as(f32, 25), interpolateBetween(10, 20, 2, 3, 3.5));
}

test "clock yields clamped seconds" {
    var clock = Clock{};
    try std.testing.expectEqual(@as(f32, 0), clock.tick(1000));
    try std.testing.expectApproxEqAbs(@as(f32, 0.016), clock.tick(1016), 1e-6);
    try std.testing.expectEqual(@as(f32, 0.1), clock.tick(1016 + 5000)); // suspend clamp
    try std.testing.expectEqual(@as(f32, 0), clock.tick(900)); // backwards: no negative dt
}
