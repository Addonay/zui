//! Port of GPUI `elements/svg.rs`: the `svg()` element. It rasterizes an SVG
//! to an alpha mask (cached in the sprite atlas) and paints it tinted with the
//! text color, like GPUI's `svg().path(...).text_color(...)`.

const std = @import("std");
const geometry = @import("../geometry.zig");
const style_mod = @import("../style.zig");
const scene = @import("../scene.zig");
const window_mod = @import("../window.zig");
const app_mod = @import("../app.zig");
const assets = @import("../assets.zig");
const asset_cache = @import("../asset_cache.zig");
const animation_mod = @import("animation.zig");
const div = @import("div.zig");

const Window = window_mod.Window;
const App = app_mod.App;
const Style = style_mod.Style;
const Pixels = geometry.Pixels;
const Size = geometry.Size;
const Point = geometry.Point;
const Bounds = geometry.Bounds;

/// An SVG element (GPUI `Svg`).
pub const Svg = div.StyledElement(SvgExt);

/// Creates an SVG element. Set its source with `path`, `external_path` or `data`.
pub fn svg() *Svg {
    return Svg.new();
}

/// A transformation applied when painting an SVG; it does not change layout or hitboxes (GPUI `Transformation`).
pub const Transformation = struct {
    scaling: Size(f32) = .{ .width = 1, .height = 1 },
    translation: Point(Pixels) = .{ .x = 0, .y = 0 },
    /// Clockwise rotation in radians.
    rotation: f32 = 0,
    alpha_factor_: f32 = 1.0,

    /// Scales along each axis.
    pub fn scale(s: Size(f32)) Transformation {
        return .{ .scaling = s };
    }

    /// Translates by `t`, in logical pixels.
    pub fn translate(t: Point(Pixels)) Transformation {
        return .{ .translation = t };
    }

    /// Rotates around the element center by radians, or by a `Percentage` of a full turn.
    pub fn rotate(angle: anytype) Transformation {
        return .{ .rotation = geometry.to_radians(angle) };
    }

    /// Creates a transformation that multiplies the SVG's alpha by `a` (GPUI `Transformation::alpha`).
    pub fn alpha(a: f32) Transformation {
        return .{ .alpha_factor_ = a };
    }

    pub fn with_scaling(self: Transformation, s: Size(f32)) Transformation {
        var t = self;
        t.scaling = s;
        return t;
    }

    pub fn with_translation(self: Transformation, tr: Point(Pixels)) Transformation {
        var t = self;
        t.translation = tr;
        return t;
    }

    pub fn with_rotation(self: Transformation, angle: anytype) Transformation {
        var t = self;
        t.rotation = geometry.to_radians(angle);
        return t;
    }

    /// Updates the alpha factor of this transformation (GPUI `Transformation::with_alpha`).
    pub fn with_alpha(self: Transformation, a: f32) Transformation {
        var t = self;
        t.alpha_factor_ = a;
        return t;
    }

    pub fn alpha_factor(self: Transformation) f32 {
        return self.alpha_factor_;
    }

    /// The matrix in device pixels, applied around `center` (GPUI `into_matrix`).
    pub fn into_matrix(self: Transformation, center: Point(Pixels), scale_factor: f32) scene.TransformationMatrix {
        const cx = center.x * scale_factor;
        const cy = center.y * scale_factor;
        // Read right to left: move the center to the origin, scale, rotate, then move back and apply the translation.
        return scene.TransformationMatrix.unit()
            .translate(.{ .x = cx + self.translation.x * scale_factor, .y = cy + self.translation.y * scale_factor })
            .rotate(self.rotation)
            .scale(self.scaling)
            .translate(.{ .x = -cx, .y = -cy });
    }
};

/// How a value's rate of change varies over one pass of a `TimedTransformation` (GPUI `Easing`).
pub const Easing = enum {
    linear,
    quadratic,
    ease_in_out,
    ease_out_quint,
    heartbeat,

    pub fn apply(self: Easing, delta: f32) f32 {
        return switch (self) {
            .linear => animation_mod.linear(delta),
            .quadratic => animation_mod.quadratic(delta),
            .ease_in_out => animation_mod.ease_in_out(delta),
            .ease_out_quint => animation_mod.ease_out_quint(delta),
            .heartbeat => animation_mod.heartbeat(delta),
        };
    }
};

/// A `Transformation` that repeatedly moves from one pose to another over a period
/// (GPUI `TimedTransformation`). Period and frame interval are in nanoseconds.
pub const TimedTransformation = struct {
    period: u64,
    from_: Transformation = .{},
    to_: Transformation = .{},
    scale_easing: Easing = .linear,
    translation_easing: Easing = .linear,
    rotation_easing: Easing = .linear,
    alpha_easing: Easing = .linear,
    alternate_: bool = false,
    min_frame_interval_: ?u64 = null,

    /// Creates a timed transformation that repeats every `period_ns` nanoseconds.
    pub fn new(period_ns: u64) TimedTransformation {
        return .{ .period = period_ns };
    }

    /// Creates a timed transformation that turns `from_t` clockwise, one full turn per `period_ns`.
    pub fn rotation(period_ns: u64, from_t: Transformation) TimedTransformation {
        return TimedTransformation.new(period_ns)
            .from(from_t)
            .to(from_t.with_rotation(from_t.rotation + 2.0 * std.math.pi));
    }

    /// Creates a static timed transformation that stays at `transformation`.
    pub fn from_transformation(transformation: Transformation) TimedTransformation {
        return TimedTransformation.new(0).from(transformation).to(transformation);
    }

    pub fn is_animated(self: TimedTransformation) bool {
        return self.period != 0 and !std.meta.eql(self.from_, self.to_);
    }

    pub fn from(self: TimedTransformation, transformation: Transformation) TimedTransformation {
        var copy = self;
        copy.from_ = transformation;
        return copy;
    }

    pub fn to(self: TimedTransformation, transformation: Transformation) TimedTransformation {
        var copy = self;
        copy.to_ = transformation;
        return copy;
    }

    pub fn with_easing(self: TimedTransformation, easing: Easing) TimedTransformation {
        var copy = self;
        copy.scale_easing = easing;
        copy.translation_easing = easing;
        copy.rotation_easing = easing;
        copy.alpha_easing = easing;
        return copy;
    }

    pub fn with_scale_easing(self: TimedTransformation, easing: Easing) TimedTransformation {
        var copy = self;
        copy.scale_easing = easing;
        return copy;
    }

    pub fn with_translation_easing(self: TimedTransformation, easing: Easing) TimedTransformation {
        var copy = self;
        copy.translation_easing = easing;
        return copy;
    }

    pub fn with_rotation_easing(self: TimedTransformation, easing: Easing) TimedTransformation {
        var copy = self;
        copy.rotation_easing = easing;
        return copy;
    }

    pub fn with_alpha_easing(self: TimedTransformation, easing: Easing) TimedTransformation {
        var copy = self;
        copy.alpha_easing = easing;
        return copy;
    }

    pub fn alternate(self: TimedTransformation) TimedTransformation {
        var copy = self;
        copy.alternate_ = true;
        return copy;
    }

    pub fn with_max_fps(self: TimedTransformation, max_fps: f32) TimedTransformation {
        var copy = self;
        if (std.math.isFinite(max_fps) and max_fps > 0.0) {
            copy.min_frame_interval_ = @intFromFloat(@as(f64, std.time.ns_per_s) / @as(f64, max_fps));
        }
        return copy;
    }

    pub fn min_frame_interval(self: TimedTransformation) ?u64 {
        return self.min_frame_interval_;
    }

    /// Returns the transformation at `elapsed_ns` after the synced animation clock started.
    pub fn at(self: TimedTransformation, elapsed_ns: u64) Transformation {
        if (self.period == 0) return self.from_;
        const rem_ns = elapsed_ns % self.period;
        var delta: f32 = @floatCast(@as(f64, @floatFromInt(rem_ns)) / @as(f64, @floatFromInt(self.period)));
        if (self.alternate_) {
            delta = 1.0 - @abs(2.0 * delta - 1.0);
        }

        const f = self.from_;
        const t = self.to_;
        const scale_t = self.scale_easing.apply(delta);
        const trans_t = self.translation_easing.apply(delta);
        const rot_t = self.rotation_easing.apply(delta);
        const alpha_t = self.alpha_easing.apply(delta);
        return .{
            .scaling = .{
                .width = f.scaling.width + (t.scaling.width - f.scaling.width) * scale_t,
                .height = f.scaling.height + (t.scaling.height - f.scaling.height) * scale_t,
            },
            .translation = .{
                .x = f.translation.x + (t.translation.x - f.translation.x) * trans_t,
                .y = f.translation.y + (t.translation.y - f.translation.y) * trans_t,
            },
            .rotation = f.rotation + (t.rotation - f.rotation) * rot_t,
            .alpha_factor_ = f.alpha_factor_ + (t.alpha_factor_ - f.alpha_factor_) * alpha_t,
        };
    }
};

/// Element-specific state and style for `Svg`.
pub const SvgExt = struct {
    path_: ?[]const u8 = null,
    external_path_: ?[]const u8 = null,
    data_: ?[]const u8 = null,
    transformation_: ?TimedTransformation = null,

    /// Sets the embedded asset path, read through the app's `AssetSource` (GPUI `path`).
    pub fn path(self: anytype, p: []const u8) @TypeOf(self) {
        self.ext.path_ = p;
        return self;
    }

    /// Sets a file path read from disk (GPUI `external_path`).
    pub fn external_path(self: anytype, p: []const u8) @TypeOf(self) {
        self.ext.external_path_ = p;
        return self;
    }

    /// Sets inline SVG bytes, which must outlive the frame (GPUI `data`).
    pub fn data(self: anytype, bytes: []const u8) @TypeOf(self) {
        self.ext.data_ = bytes;
        return self;
    }

    /// Transforms the painted artwork (GPUI `with_transformation`).
    pub fn with_transformation(self: anytype, t: Transformation) @TypeOf(self) {
        self.ext.transformation_ = TimedTransformation.from_transformation(t);
        return self;
    }

    /// Continuously animates the SVG without re-rendering its view (GPUI `with_timed_transformation`).
    pub fn with_timed_transformation(self: anytype, t: TimedTransformation) @TypeOf(self) {
        self.ext.transformation_ = t;
        return self;
    }

    /// Paints the mask tinted with `style.text.color`. Nothing is painted without a text color, as in GPUI.
    pub fn paint_ext(self: anytype, bounds: Bounds(Pixels), s: *const Style, window: *Window, cx: *App) void {
        const color = s.text.color orelse return;
        const e = &self.ext;
        const center = bounds.center();
        const sf = window.scale_factor();

        const anim: ?scene.SpriteAnimation = if (e.transformation_) |timed|
            if (timed.is_animated() and !cx.reduce_motion())
                scene.SpriteAnimation.init(timed, center, sf)
            else
                null
        else
            null;
        const pose: ?Transformation = if (e.transformation_) |timed| timed.from_ else null;
        const transformation = if (pose) |p| p.into_matrix(center, sf) else scene.TransformationMatrix.unit();
        const alpha_mul: f32 = if (anim != null) 1.0 else if (pose) |p| p.alpha_factor() else 1.0;

        if (e.data_) |bytes| {
            window.paint_animated_svg(bounds, e.path_ orelse "", bytes, transformation, anim, color.opacity(alpha_mul), cx) catch |err| {
                std.log.err("svg: paint_svg failed: {s}", .{@errorName(err)});
            };
        } else if (e.external_path_) |p| {
            // Nothing is painted until the file has loaded (GPUI loads it with `use_asset`).
            const bytes = window.use_asset(SvgFile, p, cx) orelse return;
            if (bytes.len == 0) return;
            window.paint_animated_svg(bounds, p, bytes, transformation, anim, color.opacity(alpha_mul), cx) catch |err| {
                std.log.err("svg: paint_svg failed: {s}", .{@errorName(err)});
            };
        } else if (e.path_) |p| {
            window.paint_animated_svg(bounds, p, null, transformation, anim, color.opacity(alpha_mul), cx) catch |err| {
                std.log.err("svg: paint_svg failed: {s}", .{@errorName(err)});
            };
        }
    }
};

/// The bytes of an SVG file on disk, loaded once per path (GPUI `SvgAsset`). An empty result means
/// the file could not be read.
pub const SvgFile = struct {
    pub const Source = []const u8;
    pub const Output = []const u8;

    pub fn clone_source(source: Source, allocator: std.mem.Allocator) error{OutOfMemory}!Source {
        return allocator.dupe(u8, source);
    }

    pub fn free_source(source: Source, allocator: std.mem.Allocator) void {
        allocator.free(source);
    }

    pub fn load(source: Source, cx: *asset_cache.LoadContext) Output {
        return assets.read_file(cx.allocator, source) catch @as(Output, &.{});
    }

    pub fn dispose(out: Output, app: *App) void {
        if (out.len > 0) app.allocator.free(out);
    }
};

test "transformation without rotation or scale only moves the origin" {
    const m = (Transformation{ .translation = .{ .x = 4, .y = 0 } }).into_matrix(.{ .x = 10, .y = 10 }, 1.0);
    const p = m.apply(.{ .x = 10, .y = 10 });
    try std.testing.expectApproxEqAbs(@as(f32, 14), p.x, 1e-4);
    try std.testing.expectApproxEqAbs(@as(f32, 10), p.y, 1e-4);
}

test "rotate takes radians or a percentage of a turn" {
    const geometry_mod = @import("../geometry.zig");
    try std.testing.expectApproxEqAbs(std.math.pi / 2.0, Transformation.rotate(geometry_mod.percentage(0.25)).rotation, 1e-6);
    try std.testing.expectEqual(@as(f32, 0.5), Transformation.rotate(@as(f32, 0.5)).rotation);
}

test "element protocol instantiates the svg hooks" {
    _ = &Svg.request_layout;
    _ = &Svg.prepaint;
    _ = &Svg.paint;
    _ = &Svg.path;
    _ = &Svg.external_path;
    _ = &Svg.data;
    _ = &Svg.with_transformation;
}

const TestContext = @import("../app/test_context.zig");
const color_mod = @import("../color.zig");

const square_svg =
    \\<svg xmlns="http://www.w3.org/2000/svg" width="16" height="16"><rect width="8" height="16"/></svg>
;

const AnimatedSvgView = struct {
    transformation: TimedTransformation = TimedTransformation.new(0),
    renders: ?*usize = null,

    pub fn render(self: *AnimatedSvgView, _: *Window, _: *app_mod.Context(AnimatedSvgView)) *div.Div {
        if (self.renders) |r| r.* += 1;
        const el = svg()
            .data(square_svg)
            .size(geometry.px(16))
            .text_color(color_mod.red());
        return div.div().child(SvgExt.with_timed_transformation(el, self.transformation));
    }

    fn set(this: *AnimatedSvgView, t: TimedTransformation, r: *usize, cx: *app_mod.Context(AnimatedSvgView)) void {
        this.transformation = t;
        this.renders = r;
        cx.notify();
    }
};

const Pose = struct {
    rotation_scale: [2][2]f32,
    center_offset: [2]f32,
    alpha: f32,
};

fn stepAnimationPose(vcx: *TestContext.VisualTestContext, cx: *TestContext.TestAppContext, advance_ns: u64) Pose {
    cx.executor().advance_clock(advance_ns);
    _ = vcx.window.simulate_next_frame(cx.app);
    vcx.window.advance_scene_animations(cx.app);
    for (vcx.window.rendered_frame.scene.monochrome_sprites.items) |sprite| {
        if (sprite.animation != .none) {
            const c = sprite.bounds.center();
            const a = sprite.transformation.rotation_scale[0][0];
            const b = sprite.transformation.rotation_scale[0][1];
            const cc = sprite.transformation.rotation_scale[1][0];
            const d = sprite.transformation.rotation_scale[1][1];
            const tx = sprite.transformation.translation[0];
            const ty = sprite.transformation.translation[1];
            return .{
                .rotation_scale = sprite.transformation.rotation_scale,
                .center_offset = .{
                    a * c.x + b * c.y + tx - c.x,
                    cc * c.x + d * c.y + ty - c.y,
                },
                .alpha = sprite.color.a,
            };
        }
    }
    @panic("the SVG should be painted as an animated sprite");
}

test "test_rotation_advances_without_rerendering" {
    var cx = TestContext.TestAppContext.single();
    defer cx.deinit();
    var renders: usize = 0;
    const timed = TimedTransformation.rotation(std.time.ns_per_s, .{});
    const view_res = cx.add_window_view(struct {
        fn build(_: *Window, app: *App) app_mod.Entity(AnimatedSvgView) {
            return app.new(AnimatedSvgView{});
        }
    }.build);
    const view_entity = view_res[0];
    const vcx = view_res[1];
    view_entity.update(cx.app, AnimatedSvgView.set, .{ timed, &renders });
    cx.run_until_parked();
    const renders_before = renders;

    for (0..4) |quarter| {
        const pose = stepAnimationPose(vcx, &cx, if (quarter == 0) 0 else 250 * std.time.ns_per_ms);
        const angle = @as(f32, @floatFromInt(quarter)) * (std.math.pi / 2.0);
        const s = @sin(angle);
        const c = @cos(angle);
        const expected = [4]f32{ c, -s, s, c };
        const actual = [4]f32{
            pose.rotation_scale[0][0],
            pose.rotation_scale[0][1],
            pose.rotation_scale[1][0],
            pose.rotation_scale[1][1],
        };
        for (actual, expected) |act, exp| {
            try std.testing.expectApproxEqAbs(exp, act, 1e-5);
        }
        for (pose.center_offset) |offset| {
            try std.testing.expect(@abs(offset) < 1e-3);
        }
    }
    try std.testing.expectEqual(renders_before, renders);
}

test "test_timed_transformation_eases_each_value_separately" {
    var cx = TestContext.TestAppContext.single();
    defer cx.deinit();
    var renders: usize = 0;
    const timed = TimedTransformation.new(std.time.ns_per_s)
        .from(Transformation.alpha(0.4))
        .to(Transformation.scale(.{ .width = 1.5, .height = 1.5 }).with_alpha(0.0))
        .with_scale_easing(.ease_out_quint);

    const view_res = cx.add_window_view(struct {
        fn build(_: *Window, app: *App) app_mod.Entity(AnimatedSvgView) {
            return app.new(AnimatedSvgView{});
        }
    }.build);
    view_res[0].update(cx.app, AnimatedSvgView.set, .{ timed, &renders });
    cx.run_until_parked();
    const renders_before = renders;

    const p0 = stepAnimationPose(view_res[1], &cx, 0);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), p0.rotation_scale[0][0], 1e-5);
    try std.testing.expectApproxEqAbs(@as(f32, 0.4), p0.alpha, 1e-5);

    const p1 = stepAnimationPose(view_res[1], &cx, 500 * std.time.ns_per_ms);
    const expected_scale = 1.0 + 0.5 * (1.0 - std.math.pow(f32, 0.5, 5));
    try std.testing.expectApproxEqAbs(expected_scale, p1.rotation_scale[0][0], 1e-5);
    try std.testing.expectApproxEqAbs(@as(f32, 0.2), p1.alpha, 1e-5);
    try std.testing.expectEqual(renders_before, renders);
}

test "test_heartbeat_returns_to_its_start" {
    var cx = TestContext.TestAppContext.single();
    defer cx.deinit();
    var renders: usize = 0;
    const timed = TimedTransformation.new(std.time.ns_per_s)
        .to(Transformation.scale(.{ .width = 1.12, .height = 1.12 }))
        .with_scale_easing(.heartbeat);

    const view_res = cx.add_window_view(struct {
        fn build(_: *Window, app: *App) app_mod.Entity(AnimatedSvgView) {
            return app.new(AnimatedSvgView{});
        }
    }.build);
    view_res[0].update(cx.app, AnimatedSvgView.set, .{ timed, &renders });
    cx.run_until_parked();

    try std.testing.expectApproxEqAbs(@as(f32, 1.0), stepAnimationPose(view_res[1], &cx, 0).rotation_scale[0][0], 1e-3);
    try std.testing.expectApproxEqAbs(@as(f32, 1.12), stepAnimationPose(view_res[1], &cx, 200 * std.time.ns_per_ms).rotation_scale[0][0], 1e-3);
    const second_beat = stepAnimationPose(view_res[1], &cx, 200 * std.time.ns_per_ms).rotation_scale[0][0];
    try std.testing.expect(second_beat > 1.05 and second_beat < 1.09);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), stepAnimationPose(view_res[1], &cx, 599 * std.time.ns_per_ms).rotation_scale[0][0], 1e-3);
}

test "test_scene_presents_as_often_as_its_least_capped_animation" {
    const CappedView = struct {
        spin: TimedTransformation,

        pub fn render(self: *@This(), _: *Window, _: *app_mod.Context(@This())) *div.Div {
            const s1 = SvgExt.with_timed_transformation(svg().data(square_svg).size(geometry.px(16)).text_color(color_mod.red()), self.spin.with_max_fps(10.0));
            const s2 = SvgExt.with_timed_transformation(svg().data(square_svg).size(geometry.px(16)).text_color(color_mod.red()), self.spin.with_max_fps(20.0));
            const s3 = svg().data(square_svg).size(geometry.px(16)).text_color(color_mod.red()).with_transformation(Transformation.alpha(0.5));
            return div.div().child(s1).child(s2).child(s3);
        }
    };

    var cx = TestContext.TestAppContext.init();
    defer cx.deinit();
    const spin = TimedTransformation.rotation(std.time.ns_per_s, .{});
    const view_res = cx.add_window_view(struct {
        fn build(_: *Window, app: *App) app_mod.Entity(CappedView) {
            return app.new(CappedView{ .spin = TimedTransformation.rotation(std.time.ns_per_s, .{}) });
        }
    }.build);
    _ = spin;
    cx.run_until_parked();
    try std.testing.expectEqual(@as(?u64, 50 * std.time.ns_per_ms), view_res[1].window.rendered_frame.scene.animation_frame_interval());
}

test "onRequestFrame advances and presents animated scene without re-rendering views" {
    var cx = TestContext.TestAppContext.single();
    defer cx.deinit();
    var renders: usize = 0;
    const timed = TimedTransformation.rotation(std.time.ns_per_s, .{});
    const view_res = cx.add_window_view(struct {
        fn build(_: *Window, app: *App) app_mod.Entity(AnimatedSvgView) {
            return app.new(AnimatedSvgView{});
        }
    }.build);
    view_res[0].update(cx.app, AnimatedSvgView.set, .{ timed, &renders });
    cx.run_until_parked();

    const renders_after_draw = renders;
    const platform_mod = @import("../platform.zig");
    const headless = @import("../platform/headless.zig");
    const hw: *headless.HeadlessWindow = @fieldParentPtr("base", view_res[1].window.platform_window);
    const draws_before = hw.draw_count;

    cx.executor().advance_clock(250 * std.time.ns_per_ms);
    view_res[1].window.platform_window.emit_request_frame(platform_mod.RequestFrameOptions{});

    try std.testing.expectEqual(renders_after_draw, renders);
    try std.testing.expectEqual(draws_before + 1, hw.draw_count);
}

test "reduce_motion disables sprite animation" {
    var cx = TestContext.TestAppContext.single();
    defer cx.deinit();
    cx.app.set_reduce_motion(true);
    var renders: usize = 0;
    const timed = TimedTransformation.rotation(std.time.ns_per_s, .{});
    const view_res = cx.add_window_view(struct {
        fn build(_: *Window, app: *App) app_mod.Entity(AnimatedSvgView) {
            return app.new(AnimatedSvgView{});
        }
    }.build);
    view_res[0].update(cx.app, AnimatedSvgView.set, .{ timed, &renders });
    cx.run_until_parked();
    try std.testing.expectEqual(@as(?u64, null), view_res[1].window.animation_frame_interval());
}

test {
    std.testing.refAllDecls(@This());
}
