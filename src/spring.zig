//! Port of GPUI `spring.rs`: an analytic damped harmonic oscillator, spring
//! targets and the `SpringAnimation` builder. Durations are nanoseconds (`u64`).

const std = @import("std");
const color = @import("color.zig");
const geometry = @import("geometry.zig");

const Rems = geometry.Rems;
const Hsla = color.Hsla;
const Rgba = color.Rgba;

const critical_damping_tolerance: f32 = 1e-4;
const default_spring_epsilon: f32 = 0.001;

/// Duration returned when a spring never settles (GPUI `Duration::MAX`).
pub const max_duration: u64 = std.math.maxInt(u64);

/// The physical parameters of a damped harmonic oscillator.
pub const SpringConfig = struct {
    /// The spring stiffness, conventionally written as k.
    stiffness: f32,
    /// The viscous damping coefficient, conventionally written as c.
    damping: f32,
    /// The moving mass, conventionally written as m.
    mass: f32,

    /// Creates a spring from its physical parameters.
    pub fn new(stiffness: f32, damping: f32, mass: f32) SpringConfig {
        return .{ .stiffness = stiffness, .damping = damping, .mass = mass };
    }

    /// Returns the natural angular frequency and damping ratio.
    pub fn canonical(self: SpringConfig) struct { f32, f32 } {
        const natural_frequency = @sqrt(self.stiffness / self.mass);
        const damping_ratio = self.damping / (2.0 * @sqrt(self.stiffness * self.mass));
        return .{ natural_frequency, damping_ratio };
    }

    /// Advances a spring toward a target that stays fixed for `delta_time` seconds.
    /// Analytic, so it is frame-rate independent and preserves velocity on retarget.
    pub fn step(self: SpringConfig, state: SpringState, target: f32, delta_time: f32) SpringState {
        const matrix = self.propagator(delta_time);
        const displacement = state.position - target;
        return .{
            .position = target + matrix[0][0] * displacement + matrix[0][1] * state.velocity,
            .velocity = matrix[1][0] * displacement + matrix[1][1] * state.velocity,
        };
    }

    /// Advances a spring toward a target moving at a constant velocity.
    pub fn step_ramp(self: SpringConfig, state: SpringState, target: f32, target_velocity: f32, delta_time: f32) SpringState {
        const natural_frequency, const damping_ratio = self.canonical();
        const steady_state_lag = -2.0 * damping_ratio * target_velocity / natural_frequency;
        const displacement = state.position - target - steady_state_lag;
        const velocity = state.velocity - target_velocity;
        const matrix = self.propagator(delta_time);
        const moved_target = target + target_velocity * delta_time;
        return .{
            .position = moved_target + steady_state_lag + matrix[0][0] * displacement + matrix[0][1] * velocity,
            .velocity = target_velocity + matrix[1][0] * displacement + matrix[1][1] * velocity,
        };
    }

    /// Returns the exact state-transition matrix for a constant target.
    /// Must not be reused when the frame delta changes.
    pub fn propagator(self: SpringConfig, delta_time: f32) [2][2]f32 {
        const natural_frequency, const damping_ratio = self.canonical();

        if (damping_ratio < 1.0 - critical_damping_tolerance) {
            const decay = damping_ratio * natural_frequency;
            const damped_frequency = natural_frequency * @sqrt(1.0 - damping_ratio * damping_ratio);
            const exponential = @exp(-decay * delta_time);
            const sine = @sin(damped_frequency * delta_time);
            const cosine = @cos(damped_frequency * delta_time);
            const sine_over_frequency = sine / damped_frequency;
            return .{
                .{
                    exponential * (cosine + decay * sine_over_frequency),
                    exponential * sine_over_frequency,
                },
                .{
                    -exponential * natural_frequency * natural_frequency * sine_over_frequency,
                    exponential * (cosine - decay * sine_over_frequency),
                },
            };
        } else if (damping_ratio > 1.0 + critical_damping_tolerance) {
            const root = @sqrt(damping_ratio * damping_ratio - 1.0);
            const root_sum = damping_ratio + root;
            const slow_root = -natural_frequency / root_sum;
            const fast_root = -natural_frequency * root_sum;
            const denominator = slow_root - fast_root;
            const slow_exponential = @exp(slow_root * delta_time);
            const fast_exponential = @exp(fast_root * delta_time);
            return .{
                .{
                    (-fast_root * slow_exponential + slow_root * fast_exponential) / denominator,
                    (slow_exponential - fast_exponential) / denominator,
                },
                .{
                    slow_root * fast_root * (fast_exponential - slow_exponential) / denominator,
                    (slow_root * slow_exponential - fast_root * fast_exponential) / denominator,
                },
            };
        } else {
            const exponential = @exp(-natural_frequency * delta_time);
            return .{
                .{
                    exponential * (1.0 + natural_frequency * delta_time),
                    exponential * delta_time,
                },
                .{
                    -exponential * natural_frequency * natural_frequency * delta_time,
                    exponential * (1.0 - natural_frequency * delta_time),
                },
            };
        }
    }

    /// Tests displacement and velocity against a positional tolerance.
    /// Velocity is compared with `epsilon * natural_frequency`.
    pub fn is_settled(self: SpringConfig, state: SpringState, target: f32, epsilon: f32) bool {
        const natural_frequency, _ = self.canonical();
        return std.math.isFinite(epsilon) and epsilon >= 0.0 and
            @abs(state.position - target) <= epsilon and
            @abs(state.velocity) <= epsilon * natural_frequency;
    }

    /// Returns a conservative time in nanoseconds after which the spring remains settled.
    /// An undamped spring returns `max_duration`.
    pub fn settle_time(self: SpringConfig, state: SpringState, target: f32, epsilon: f32) u64 {
        const displacement = state.position - target;
        if (displacement == 0.0 and state.velocity == 0.0) return 0;

        const natural_frequency, const damping_ratio = self.canonical();
        if (!std.math.isFinite(natural_frequency) or natural_frequency <= 0.0 or
            !std.math.isFinite(damping_ratio) or damping_ratio <= 0.0 or
            !std.math.isFinite(epsilon) or epsilon <= 0.0)
        {
            return max_duration;
        }

        const velocity_threshold = epsilon * natural_frequency;

        if (damping_ratio < 1.0 - critical_damping_tolerance) {
            const decay = damping_ratio * natural_frequency;
            const damped_frequency = natural_frequency * @sqrt(1.0 - damping_ratio * damping_ratio);
            const sine_coefficient = (state.velocity + decay * displacement) / damped_frequency;
            const velocity_cosine = damped_frequency * sine_coefficient - decay * displacement;
            const velocity_sine = -damped_frequency * displacement - decay * sine_coefficient;
            return find_settle_time(epsilon, velocity_threshold, 0.0, natural_frequency, .{ .damped = .{
                .position_envelope = std.math.hypot(displacement, sine_coefficient),
                .velocity_envelope = std.math.hypot(velocity_cosine, velocity_sine),
                .decay = decay,
            } });
        } else if (damping_ratio > 1.0 + critical_damping_tolerance) {
            const root = @sqrt(damping_ratio * damping_ratio - 1.0);
            const root_sum = damping_ratio + root;
            const slow_root = -natural_frequency / root_sum;
            const fast_root = -natural_frequency * root_sum;
            const denominator = slow_root - fast_root;
            return find_settle_time(epsilon, velocity_threshold, 0.0, natural_frequency, .{ .overdamped = .{
                .slow_coefficient = (state.velocity - fast_root * displacement) / denominator,
                .fast_coefficient = (slow_root * displacement - state.velocity) / denominator,
                .slow_root = slow_root,
                .fast_root = fast_root,
            } });
        } else {
            const linear_coefficient = state.velocity + natural_frequency * displacement;
            const position_constant = @abs(displacement);
            const position_linear = @abs(linear_coefficient);
            const velocity_constant = @abs(linear_coefficient - natural_frequency * displacement);
            const velocity_linear = natural_frequency * @abs(linear_coefficient);
            const position_decay_start = envelope_decay_start(position_constant, position_linear, natural_frequency);
            const velocity_decay_start = envelope_decay_start(velocity_constant, velocity_linear, natural_frequency);
            return find_settle_time(epsilon, velocity_threshold, @max(position_decay_start, velocity_decay_start), natural_frequency, .{ .critical = .{
                .position_constant = position_constant,
                .position_linear = position_linear,
                .velocity_constant = velocity_constant,
                .velocity_linear = velocity_linear,
                .natural_frequency = natural_frequency,
            } });
        }
    }
};

/// The instantaneous position and velocity of a spring.
pub const SpringState = struct {
    /// The current value in the animated unit.
    position: f32 = 0,
    /// The current value's change per second.
    velocity: f32 = 0,
};

/// A stateful spring's playback mode (GPUI `SpringPlayback`).
pub const SpringPlayback = enum {
    /// Advances toward the latest target, preserving velocity across retargets.
    running,
    /// Holds the current position and velocity until playback resumes.
    paused,
    /// Holds the current position and discards velocity.
    stopped,
    /// Snaps to the latest target and discards velocity.
    completed,
    /// Returns to the initial value and discards velocity.
    cancelled,
};

/// A potentially overshooting coordinate within an animation (GPUI `AnimationPhase`).
pub const AnimationPhase = struct {
    /// The unbounded phase coordinate.
    value: f32 = 0,

    /// Restricts this phase to `range`, given as `[first, second]` in either order.
    pub fn clamp(self: AnimationPhase, range: [2]f32) AnimationPhase {
        return .{ .value = std.math.clamp(self.value, @min(range[0], range[1]), @max(range[0], range[1])) };
    }

    /// Interpolates between `from` and `to`, using 0 and 1 as phase coordinates.
    pub fn interpolate(self: AnimationPhase, from: anytype, to: anytype) @TypeOf(from) {
        return interpolate_value(@TypeOf(from), from, to, self.value);
    }

    /// Interpolates between `from` and `to` without extrapolating beyond 0 and 1.
    pub fn interpolate_clamped(self: AnimationPhase, from: anytype, to: anytype) @TypeOf(from) {
        return interpolate_value(@TypeOf(from), from, to, std.math.clamp(self.value, 0.0, 1.0));
    }

    /// Interpolates between `from` and `to` over the phase coordinates `range`.
    pub fn interpolate_between(self: AnimationPhase, range: [2]f32, from: anytype, to: anytype) @TypeOf(from) {
        const start, const end = range;
        const phase = if (start == end) (if (self.value < start) @as(f32, 0.0) else 1.0) else (self.value - start) / (end - start);
        return interpolate_value(@TypeOf(from), from, to, phase);
    }

    /// Like `interpolate_between`, without extrapolating beyond the range.
    pub fn interpolate_between_clamped(self: AnimationPhase, range: [2]f32, from: anytype, to: anytype) @TypeOf(from) {
        const start, const end = range;
        const phase = if (start == end) (if (self.value < start) @as(f32, 0.0) else 1.0) else std.math.clamp((self.value - start) / (end - start), 0.0, 1.0);
        return interpolate_value(@TypeOf(from), from, to, phase);
    }
};

/// Returns the one-dimensional spring coordinate of a spring target.
pub fn spring_target(target: anytype) f32 {
    return switch (@TypeOf(target)) {
        f32 => target,
        Rems, AnimationPhase => target.value,
        bool => if (target) 1.0 else 0.0,
        else => @compileError("not a spring target: " ++ @typeName(@TypeOf(target))),
    };
}

/// The value a spring animator receives for target type `T` (GPUI `SpringTarget::Output`).
pub fn SpringOutput(comptime T: type) type {
    return switch (T) {
        bool => AnimationPhase,
        else => T,
    };
}

/// Projects a spring coordinate into the animated output for `target` (GPUI `SpringTarget::resolve`).
pub fn spring_resolve(target: anytype, value: f32) SpringOutput(@TypeOf(target)) {
    return switch (@TypeOf(target)) {
        f32 => value,
        Rems => .{ .value = value },
        AnimationPhase, bool => .{ .value = value },
        else => @compileError("not a spring target: " ++ @typeName(@TypeOf(target))),
    };
}

/// Interpolates two values of type `T` at `phase`, taking the shortest hue path for `Hsla`.
pub fn interpolate_value(comptime T: type, from: T, to: T, phase: f32) T {
    switch (T) {
        f32 => return from + (to - from) * phase,
        Rems => return .{ .value = from.value + (to.value - from.value) * phase },
        Rgba => return .{
            .r = interpolate_value(f32, from.r, to.r, phase),
            .g = interpolate_value(f32, from.g, to.g, phase),
            .b = interpolate_value(f32, from.b, to.b, phase),
            .a = interpolate_value(f32, from.a, to.a, phase),
        },
        Hsla => {
            const hue_delta = @mod(to.h - from.h + 0.5, 1.0) - 0.5;
            return .{
                .h = @mod(from.h + hue_delta * phase, 1.0),
                .s = interpolate_value(f32, from.s, to.s, phase),
                .l = interpolate_value(f32, from.l, to.l, phase),
                .a = interpolate_value(f32, from.a, to.a, phase),
            };
        },
        else => @compileError("cannot interpolate " ++ @typeName(T)),
    }
}

/// A stateful spring animation targeting a value (GPUI `SpringAnimation<T>`).
pub fn SpringAnimationOf(comptime T: type) type {
    return struct {
        const Self = @This();

        config: SpringConfig,
        target: T,
        epsilon: f32 = default_spring_epsilon,
        initial: ?f32 = null,
        playback_mode: SpringPlayback = .running,

        /// Sets the target value or path of this spring.
        pub fn to(self: Self, target: anytype) SpringAnimationOf(@TypeOf(target)) {
            return .{
                .config = self.config,
                .target = target,
                .epsilon = self.epsilon,
                .initial = self.initial,
                .playback_mode = self.playback_mode,
            };
        }

        /// Sets the settling tolerance in the target's scalar coordinate space.
        pub fn with_epsilon(self: Self, epsilon: f32) Self {
            var copy = self;
            copy.epsilon = epsilon;
            return copy;
        }

        /// Sets how the spring advances or resolves its current value.
        pub fn playback(self: Self, mode: SpringPlayback) Self {
            var copy = self;
            copy.playback_mode = mode;
            return copy;
        }

        /// Sets the value used when the element has no prior spring state.
        pub fn from(self: Self, initial: anytype) Self {
            var copy = self;
            copy.initial = spring_target(initial);
            return copy;
        }
    };
}

/// Entry point for building spring animations (GPUI `SpringAnimation::new`).
pub const SpringAnimation = struct {
    /// Creates a spring animation builder without a target.
    pub fn new(config: SpringConfig) SpringAnimationOf(void) {
        return .{ .config = config, .target = {} };
    }
};

/// Adapts a spring starting at zero with no velocity to a duration-based easing.
/// Returns the settle time in nanoseconds and an easing that can overshoot 0..1.
/// Comptime-only: the easing closes over `config`. Retargeting this form restarts
/// the spring; use `SpringConfig.step` to preserve velocity.
pub fn sampled_easing(comptime config: SpringConfig, comptime epsilon: f32) struct { u64, *const fn (f32) f32 } {
    const initial_state: SpringState = .{ .position = 0, .velocity = 0 };
    const duration = comptime config.settle_time(initial_state, 1.0, epsilon);
    const duration_seconds = comptime secs_f32(duration);
    return .{ duration, struct {
        fn ease(progress: f32) f32 {
            if (progress <= 0.0) return 0.0;
            if (progress >= 1.0) return 1.0;
            return config.step(initial_state, 1.0, progress * duration_seconds).position;
        }
    }.ease };
}

/// Converts nanoseconds to seconds as `f32`.
pub fn secs_f32(nanoseconds: u64) f32 {
    return @as(f32, @floatFromInt(nanoseconds)) / @as(f32, std.time.ns_per_s);
}

fn envelope_decay_start(constant: f32, linear: f32, decay: f32) f32 {
    if (linear == 0.0) return 0.0;
    return @max(1.0 / decay - constant / linear, 0.0);
}

/// Closed-form envelope of a settling spring, evaluated at a time.
const SettleEnvelope = union(enum) {
    damped: struct { position_envelope: f32, velocity_envelope: f32, decay: f32 },
    overdamped: struct { slow_coefficient: f32, fast_coefficient: f32, slow_root: f32, fast_root: f32 },
    critical: struct { position_constant: f32, position_linear: f32, velocity_constant: f32, velocity_linear: f32, natural_frequency: f32 },

    fn eval(self: SettleEnvelope, time: f32) [2]f32 {
        switch (self) {
            .damped => |d| {
                const exponential = @exp(-d.decay * time);
                return .{ d.position_envelope * exponential, d.velocity_envelope * exponential };
            },
            .overdamped => |o| {
                const slow_term = @abs(o.slow_coefficient) * @exp(o.slow_root * time);
                const fast_term = @abs(o.fast_coefficient) * @exp(o.fast_root * time);
                return .{ slow_term + fast_term, @abs(o.slow_root) * slow_term + @abs(o.fast_root) * fast_term };
            },
            .critical => |c| {
                const exponential = @exp(-c.natural_frequency * time);
                return .{
                    (c.position_constant + c.position_linear * time) * exponential,
                    (c.velocity_constant + c.velocity_linear * time) * exponential,
                };
            },
        }
    }
};

fn find_settle_time(
    position_threshold: f32,
    velocity_threshold: f32,
    decay_start: f32,
    natural_frequency: f32,
    envelope: SettleEnvelope,
) u64 {
    if (below_threshold(envelope, decay_start, position_threshold, velocity_threshold)) return duration_from_secs(decay_start);

    var lower_bound = decay_start;
    var upper_bound = @max(decay_start, 1.0 / natural_frequency);
    while (!below_threshold(envelope, upper_bound, position_threshold, velocity_threshold)) {
        lower_bound = upper_bound;
        upper_bound *= 2.0;
        if (!std.math.isFinite(upper_bound)) return max_duration;
    }

    for (0..32) |_| {
        const midpoint = (lower_bound + upper_bound) / 2.0;
        if (below_threshold(envelope, midpoint, position_threshold, velocity_threshold)) {
            upper_bound = midpoint;
        } else {
            lower_bound = midpoint;
        }
    }
    return duration_from_secs(upper_bound);
}

fn below_threshold(envelope: SettleEnvelope, time: f32, position_threshold: f32, velocity_threshold: f32) bool {
    const values = envelope.eval(time);
    return values[0] <= position_threshold and values[1] <= velocity_threshold;
}

fn duration_from_secs(seconds: f32) u64 {
    if (!std.math.isFinite(seconds)) return max_duration;
    if (seconds <= 0.0) return 0;
    const nanoseconds = @as(f64, seconds) * @as(f64, std.time.ns_per_s);
    if (!(nanoseconds < 18446744073709551615.0)) return max_duration;
    return @intFromFloat(nanoseconds);
}

test "spring targets resolve typed outputs" {
    try std.testing.expectEqual(@as(f32, 12.0), spring_target(@as(f32, 12.0)));
    try std.testing.expectEqual(@as(f32, 14.0), spring_resolve(@as(f32, 12.0), 14.0));
    try std.testing.expectEqual(@as(f32, 0.0), spring_target(false));
    try std.testing.expectEqual(@as(f32, 1.0), spring_target(true));
    try std.testing.expectEqual(AnimationPhase{ .value = 1.25 }, spring_resolve(true, 1.25));
}

test "animation phases interpolate over arbitrary ranges" {
    const phase: AnimationPhase = .{ .value = 1.5 };
    try std.testing.expectEqual(@as(f32, 15.0), phase.interpolate_between(.{ 1.0, 2.0 }, @as(f32, 10.0), @as(f32, 20.0)));
    try std.testing.expectEqual(@as(f32, 10.0), phase.interpolate_between_clamped(.{ 2.0, 3.0 }, @as(f32, 10.0), @as(f32, 20.0)));
    const later: AnimationPhase = .{ .value = 3.5 };
    try std.testing.expectEqual(@as(f32, 25.0), later.interpolate_between(.{ 2.0, 3.0 }, @as(f32, 10.0), @as(f32, 20.0)));
}

test "hsla interpolation takes the shortest hue path" {
    const epsilon: f32 = 1e-4;
    const from: Hsla = .{ .h = 0.9, .s = 0.5, .l = 0.5, .a = 1.0 };
    const to: Hsla = .{ .h = 0.1, .s = 1.0, .l = 0.75, .a = 0.5 };
    const result = (AnimationPhase{ .value = 0.5 }).interpolate(from, to);

    try std.testing.expect(result.h < epsilon or (1.0 - result.h) < epsilon);
    try std.testing.expect(@abs(result.s - 0.75) < epsilon);
    try std.testing.expect(@abs(result.l - 0.625) < epsilon);
    try std.testing.expect(@abs(result.a - 0.75) < epsilon);
}

test "propagators compose and have expected determinant" {
    for ([_]f32{ 0.4, 1.0, 1.5 }) |damping_ratio| {
        const natural_frequency: f32 = 12.0;
        const config = SpringConfig.new(natural_frequency * natural_frequency, 2.0 * damping_ratio * natural_frequency, 1.0);
        const first = config.propagator(0.013);
        const second = config.propagator(0.021);
        const combined = multiply(second, first);
        const direct = config.propagator(0.034);

        for (0..2) |row| {
            for (0..2) |column| {
                try std.testing.expect(@abs(combined[row][column] - direct[row][column]) < 2e-4);
            }
        }

        const determinant = direct[0][0] * direct[1][1] - direct[0][1] * direct[1][0];
        const expected = @exp(-2.0 * damping_ratio * natural_frequency * 0.034);
        try std.testing.expect(@abs(determinant - expected) < 2e-4);
    }
}

test "step preserves semigroup for every damping regime" {
    const state: SpringState = .{ .position = -3.0, .velocity = 5.0 };
    for ([_]f32{ 4.0, 20.0, 40.0 }) |damping| {
        const config = SpringConfig.new(100.0, damping, 1.0);
        const stepped = config.step(config.step(state, 7.0, 0.013), 7.0, 0.021);
        const direct = config.step(state, 7.0, 0.034);

        try std.testing.expect(@abs(stepped.position - direct.position) < 2e-4);
        try std.testing.expect(@abs(stepped.velocity - direct.velocity) < 2e-4);
    }
}

test "ramp tracks steady state lag" {
    const epsilon: f32 = 1e-4;
    const natural_frequency: f32 = 10.0;
    const damping_ratio: f32 = 0.8;
    const target_velocity: f32 = 3.0;
    const config = SpringConfig.new(natural_frequency * natural_frequency, 2.0 * damping_ratio * natural_frequency, 1.0);
    const lag = -2.0 * damping_ratio * target_velocity / natural_frequency;
    const state: SpringState = .{ .position = lag, .velocity = target_velocity };
    const next = config.step_ramp(state, 0.0, target_velocity, 0.25);

    try std.testing.expect(@abs(next.position - (target_velocity * 0.25 + lag)) < epsilon);
    try std.testing.expect(@abs(next.velocity - target_velocity) < epsilon);
}

test "settling requires low velocity" {
    const config = SpringConfig.new(100.0, 10.0, 1.0);
    try std.testing.expect(!config.is_settled(.{ .position = 1.0, .velocity = 1.0 }, 1.0, 0.01));
    try std.testing.expect(config.is_settled(.{ .position = 1.005, .velocity = 0.05 }, 1.0, 0.01));
}

test "settle time is conservative for every damping regime" {
    const initial_state: SpringState = .{ .position = -2.0, .velocity = 4.0 };
    for ([_]f32{ 4.0, 20.0, 40.0 }) |damping| {
        const config = SpringConfig.new(100.0, damping, 1.0);
        const duration = config.settle_time(initial_state, 3.0, 0.001);
        try std.testing.expect(duration != max_duration);

        for ([_]f32{ 0.0, 0.1, 1.0 }) |additional_time| {
            const state = config.step(initial_state, 3.0, secs_f32(duration) + additional_time);
            try std.testing.expect(config.is_settled(state, 3.0, 0.001));
        }
    }
}

test "settle time accounts for motion outside an instantaneous tolerance" {
    const config = SpringConfig.new(100.0, 2.0, 1.0);
    const state: SpringState = .{ .position = 1.125, .velocity = 1.25 };
    try std.testing.expect(config.is_settled(state, 1.0, 0.125));

    const duration = config.settle_time(state, 1.0, 0.125);
    try std.testing.expect(duration > 0);
    try std.testing.expect(config.is_settled(config.step(state, 1.0, secs_f32(duration)), 1.0, 0.125));
}

test "undamped spring never settles" {
    const config = SpringConfig.new(100.0, 0.0, 1.0);
    try std.testing.expectEqual(max_duration, config.settle_time(.{ .position = 0.0, .velocity = 0.0 }, 1.0, 0.001));
}

test "sampled easing has exact endpoints and can overshoot" {
    const config = comptime SpringConfig.new(100.0, 6.0, 1.0);
    const sampled = comptime sampled_easing(config, 0.001);
    const easing = sampled[1];

    try std.testing.expect(sampled[0] != max_duration);
    try std.testing.expectEqual(@as(f32, 0.0), easing(0.0));
    try std.testing.expectEqual(@as(f32, 1.0), easing(1.0));

    var overshoots = false;
    for (1..100) |step| {
        if (easing(@as(f32, @floatFromInt(step)) / 100.0) > 1.0) overshoots = true;
    }
    try std.testing.expect(overshoots);
}

fn multiply(left: [2][2]f32, right: [2][2]f32) [2][2]f32 {
    return .{
        .{
            left[0][0] * right[0][0] + left[0][1] * right[1][0],
            left[0][0] * right[0][1] + left[0][1] * right[1][1],
        },
        .{
            left[1][0] * right[0][0] + left[1][1] * right[1][0],
            left[1][0] * right[0][1] + left[1][1] * right[1][1],
        },
    };
}
