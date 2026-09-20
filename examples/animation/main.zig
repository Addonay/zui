//! ZUI animation demo — a transliteration of GPUI's
//! `crates/gpui/examples/animation.rs` into Zig.
//!
//! What it shows: two analytic springs (a position ball and a phase bar)
//! retargeted by clicking the card — rapid clicks redirect momentum because
//! the stepper preserves velocity — plus a draggable damping slider that
//! retunes the spring live, and a 2s repeating eased spinner.
//!
//! Motion math lives in the framework (`zui.animation`: tweens, springs,
//! keyframes, easings, phase interpolation); this file only wires it to
//! elements. `Window.springValue` provides the retained, velocity-preserving
//! scalar spring state that GPUI's `with_spring` element modifier supplies.
//!
//! Run it live:   zig build run-animation
//! Headless test: ZUI_SELFTEST=1 zig build run-animation
//! Snapshot:      ZUI_SNAPSHOT=/tmp/animation.ppm zig build run-animation

const std = @import("std");
const zui = @import("zui");

const anim = zui.animation;
const SpringConfig = anim.SpringConfig;

const App = zui.App;
const Context = zui.Context;
const Window = zui.Window;
const Entity = zui.Entity;
const Element = zui.Element;

// ---------------------------------------------------------------------------
// Demo constants — mirror the GPUI example's layout numbers.
// ---------------------------------------------------------------------------

const MIN_DAMPING: f32 = 2.0;
const MAX_DAMPING: f32 = 32.0;
const SLIDER_WIDTH: f32 = 224.0;
const BALL_TRAVEL: f32 = 98.0; // px per phase, like the GPUI example
const BALL_SIZE: f32 = 24.0;
const SPIN_PERIOD_MS: i64 = 2000;

const ORANGE = zui.hex(0xf97316ff);
const GREEN = zui.hex(0x22c55eff);
const PURPLE = zui.hex(0xa855f7ff);
const BLUE = zui.hex(0x3b82f6ff);
const BLUE_DARK = zui.hex(0x2563ebff);

const ARROW_CIRCLE_SVG: []const u8 =
    \\<svg width="32" height="32" viewBox="0 0 16 16" fill="none" xmlns="http://www.w3.org/2000/svg">
    \\<path d="M3 8C3 6.67392 3.52678 5.40215 4.46446 4.46447C5.40214 3.52679 6.67391 3.00001 7.99999 3.00001C9.39779 3.00527 10.7394 3.55069 11.7444 4.52223L13 5.77778" stroke="black" stroke-linecap="round" stroke-linejoin="round"/>
    \\<path d="M13 3.00001V5.77778H10.2222" stroke="black" stroke-linecap="round" stroke-linejoin="round"/>
    \\<path d="M13 8C13 9.32608 12.4732 10.5978 11.5355 11.5355C10.5978 12.4732 9.32607 13 7.99999 13C6.60219 12.9947 5.26054 12.4493 4.25555 11.4778L3 10.2222" stroke="black" stroke-linecap="round" stroke-linejoin="round"/>
    \\<path d="M5.77777 10.2222H3V13" stroke="black" stroke-linecap="round" stroke-linejoin="round"/>
    \\</svg>
;

// ---------------------------------------------------------------------------
// Demo entity — mirrors GPUI's `AnimationExample` struct fields.
// ---------------------------------------------------------------------------

const AnimationExample = struct {
    pub const Options = struct {};

    spring_phase: u8 = 0,
    spring_damping: f32 = 14.0,
    damping_drag: ?struct { start_x: f32, start_damping: f32 } = null,

    spin_epoch_ms: ?i64 = null,

    label_buf: [96]u8 = undefined,
    label_len: usize = 0,

    pub fn init(_: *Context(@This()), _: Options) @This() {
        return .{};
    }

    fn springConfig(self: *const @This()) SpringConfig {
        return SpringConfig.init(170.0, self.spring_damping, 1.0);
    }

    fn posTarget(self: *const @This()) f32 {
        return BALL_TRAVEL * @as(f32, @floatFromInt(self.spring_phase));
    }

    fn phaseTarget(self: *const @This()) f32 {
        return @floatFromInt(self.spring_phase);
    }

    // -- interactions (same listener fires for mouse and keyboard) --------

    fn advancePhase(self: *@This(), cx: *Context(@This())) void {
        // Retarget only: velocity is preserved, so rapid clicks redirect
        // momentum instead of restarting the motion.
        self.spring_phase = (self.spring_phase + 1) % 3;
        cx.notify();
    }

    fn cardClicked(self: *@This(), window: *Window, cx: *Context(@This())) void {
        _ = window;
        self.advancePhase(cx);
    }

    fn sliderDown(self: *@This(), window: *Window, cx: *Context(@This())) void {
        self.damping_drag = .{ .start_x = window.pointer_position.x, .start_damping = self.spring_damping };
        cx.notify();
    }

    fn sliderMove(self: *@This(), window: *Window, cx: *Context(@This())) void {
        const drag = self.damping_drag orelse return;
        const delta = (window.pointer_position.x - drag.start_x) / SLIDER_WIDTH;
        self.spring_damping = @min(MAX_DAMPING, @max(MIN_DAMPING, drag.start_damping + delta * (MAX_DAMPING - MIN_DAMPING)));
        cx.notify();
    }

    fn sliderUp(self: *@This(), window: *Window, cx: *Context(@This())) void {
        _ = window;
        self.damping_drag = null;
        cx.notify();
    }

    fn adjustDamping(self: *@This(), delta: f32, cx: *Context(@This())) void {
        self.spring_damping = @min(MAX_DAMPING, @max(MIN_DAMPING, self.spring_damping + delta));
        cx.notify();
    }

    pub fn handleEvent(self: *@This(), event: zui.platform.Event, cx: *Context(@This())) bool {
        if (event != .key or !event.key.pressed) return false;
        if (event.key.modifiers.ctrl or event.key.modifiers.alt or event.key.modifiers.super) return false;
        switch (event.key.key) {
            .left => {
                self.adjustDamping(-1, cx);
                return true;
            },
            .right => {
                self.adjustDamping(1, cx);
                return true;
            },
            else => return false,
        }
    }

    // -- render ------------------------------------------------------------

    pub fn render(self: *@This(), window: *Window, cx: *Context(@This())) Element {
        const now_ms = window.timeMs();
        // The spinner repeats forever, so frames keep coming even after the
        // springs settle — same as GPUI's `.repeat()` animation.
        window.requestAnimation();

        const config = self.springConfig();
        const damping_ratio = config.canonical().zeta;
        const damping_fraction = (self.spring_damping - MIN_DAMPING) / (MAX_DAMPING - MIN_DAMPING);
        const ball_x = window.springValue(0xA11CE2, config, self.posTarget(), 0.25);
        const phase = window.springValue(0xA11CE3, config, self.phaseTarget(), 0.001);

        self.label_len = blk: {
            const text = std.fmt.bufPrint(&self.label_buf, "Drag damping: {d:.1} (ζ {d:.2})", .{ self.spring_damping, damping_ratio }) catch {
                @memcpy(self.label_buf[0.."damping".len], "damping");
                break :blk "damping".len;
            };
            break :blk text.len;
        };

        const bar_w, const bar_color = if (phase <= 1.0)
            .{
                anim.interpolateBetween(48, 224, 0, 1, phase),
                anim.lerpRgba(ORANGE, GREEN, anim.interpolateBetweenClamped(0, 1, 0, 1, phase)),
            }
        else
            .{
                anim.interpolateBetween(224, 96, 1, 2, phase),
                anim.lerpRgba(GREEN, PURPLE, anim.interpolateBetweenClamped(0, 1, 1, 2, phase)),
            };

        // 2s repeating clock through bounce(ease_in_out), matching GPUI's
        // `Transformation::rotate(percentage(delta))`.
        const epoch = self.spin_epoch_ms orelse now_ms;
        self.spin_epoch_ms = epoch;
        const spin_t: f32 = @as(f32, @floatFromInt(@mod(now_ms - epoch, SPIN_PERIOD_MS))) / @as(f32, SPIN_PERIOD_MS);
        const spin_eased = anim.bounceEaseInOut(spin_t);

        const card = zui.div().flex_col().gap(8).p(8).w(240)
            .rounded(8).bg(zui.Color.black.withAlpha(0.06)).cursor_pointer()
            .keyed(0xA11CE0).withFocus(cx.focusHandle())
            .semantic(.{ .role = .button, .name = "Advance spring phase", .actions = .{ .activate = true, .focus = true } })
            .on_mouse_down(cx.listener(@This(), cardClicked))
            .child(zui.textFmt("Target phase {d}: click rapidly to redirect momentum", .{self.spring_phase}, .{ .size = 13, .color = zui.Color.black }).w(224))
            .child(zui.div().flex_col().gap(4)
                .child(zui.text(self.label_buf[0..self.label_len], .{ .size = 12, .color = zui.Color.black }))
                .child(zui.div().h(20).w(SLIDER_WIDTH).cursor_pointer()
                .keyed(0xA11CE1).withFocus(cx.focusHandle())
                .semantic(.{ .role = .slider, .name = "Spring damping", .value = .{ .current = self.spring_damping, .min = MIN_DAMPING, .max = MAX_DAMPING, .step = 0.1 }, .actions = .{ .focus = true, .increment = true, .decrement = true, .set_value = true } })
                .on_mouse_down(cx.listener(@This(), sliderDown))
                .on_mouse_move(cx.listener(@This(), sliderMove))
                .on_mouse_up(cx.listener(@This(), sliderUp))
                .child(zui.div().absolute().top(8).h(4).w_full().rounded_full().bg(zui.Color.black.withAlpha(0.19)))
                .child(zui.div().absolute().top(8).h(4).w(SLIDER_WIDTH * damping_fraction).rounded_full().bg(BLUE))
                .child(zui.div().absolute().top(3).left(SLIDER_WIDTH * damping_fraction - 7).size(14).rounded_full().bg(BLUE_DARK))))
            .child(zui.div().h(32).w_full()
                .child(zui.div().absolute().top(4).left(ball_x).size(BALL_SIZE).rounded_full().bg(BLUE)))
            .child(zui.div().h(24).w(bar_w).rounded(4).bg(bar_color));

        const spinner = zui.div().flex_row().items_center().justify_center().p(8)
            .child(zui.svg(ARROW_CIRCLE_SVG).w(32).h(32).rotate(spin_eased * 2 * std.math.pi));

        return zui.div().flex_col().size_full().justify_between().bg(zui.Color.white)
            .child(zui.div().flex_col().flex_1().justify_center().items_center().gap(16).p(16)
                .child(zui.text("Hello Animation", .{ .size = 20, .color = zui.Color.black }))
                .child(card)
                .child(spinner))
            .child(zui.div().flex_row().h(64).w_full().p(8).justify_center().items_center()
            .bg(zui.Color.black.withAlpha(0.05))
            .child(zui.text("Other Panel", .{ .size = 13, .color = zui.Color.black })));
    }
};

// ---------------------------------------------------------------------------
// App wiring.
// ---------------------------------------------------------------------------

fn buildRoot(window: *Window, vcx: *Context(AnimationExample)) Entity(AnimationExample) {
    const view = vcx.new(AnimationExample, .{});
    // Inline SVG bytes must be registered with the asset service before
    // first paint (dash does the same in its buildRoot); otherwise the
    // painter shows the image placeholder.
    if (window.images) |cache| {
        _ = cache.assets.preloadBytes(ARROW_CIRCLE_SVG, 0) catch |err| {
            std.log.err("asset preload: {s}", .{@errorName(err)});
        };
    }
    return view;
}

fn onOpen(cx: *App) void {
    const bounds = zui.Bounds.centered(null, zui.size(300, 300), cx);
    _ = cx.openWindow(.{ .bounds = bounds, .title = "Animation" }, buildRoot) catch |err| std.log.err("open window: {s}", .{@errorName(err)});
    cx.activate(false);
}

fn snapshotHeadless(gpa: std.mem.Allocator, path: []const u8) !void {
    var app = try App.initHeadless(gpa);
    defer app.deinit();
    const win = try app.openWindow(.{
        .bounds = .{ .origin = .{ .x = 0, .y = 0 }, .size = .{ .w = 300, .h = 300 } },
        .title = "Animation",
    }, buildRoot);
    _ = app.step();

    const width: u32 = 300;
    const height: u32 = 300;
    const pixels = try gpa.alloc(u8, @as(usize, width) * height * 4);
    defer gpa.free(pixels);
    var renderer = zui.gpu.vellz.Renderer.init(gpa);
    defer renderer.deinit();
    try renderer.render(pixels, width, height, .rgba32, zui.Color.white, &win.scene, app.glyphPixels(), app.imagePixels());

    var path_buf: [4096]u8 = undefined;
    if (path.len >= path_buf.len) return error.NameTooLong;
    @memcpy(path_buf[0..path.len], path);
    path_buf[path.len] = 0;
    const name: [*:0]const u8 = path_buf[0..path.len :0];
    const file = std.c.fopen(name, "wb") orelse return error.CannotOpenSnapshot;
    defer _ = std.c.fclose(file);
    var header: [64]u8 = undefined;
    const header_text = try std.fmt.bufPrint(&header, "P6\n{d} {d}\n255\n", .{ width, height });
    if (std.c.fwrite(header_text.ptr, 1, header_text.len, file) != header_text.len) return error.SnapshotWriteFailed;
    var i: usize = 0;
    while (i < pixels.len) : (i += 4) {
        if (std.c.fwrite(pixels.ptr + i, 1, 3, file) != 3) return error.SnapshotWriteFailed;
    }
    std.debug.print("animation snapshot: {d} quads {d} glyphs -> {s}\n", .{ win.scene.slice().len, win.scene.glyphSlice().len, path });
}

pub fn main(init: std.process.Init) !void {
    if (std.c.getenv("ZUI_SNAPSHOT")) |raw| {
        try snapshotHeadless(init.gpa, std.mem.span(raw));
        return;
    }
    if (std.c.getenv("ZUI_SELFTEST") != null) {
        try selftestHeadless(init.gpa);
        return;
    }
    var app = try App.init(init.gpa);
    defer app.deinit();
    app.run(onOpen);
}

// ---------------------------------------------------------------------------
// Headless selftest — mirrors GPUI's `clicking_spring_position_changes_
// the_target` test plus damping/slider coverage.
// ---------------------------------------------------------------------------

var selftest_view: ?Entity(AnimationExample) = null;

fn selftestBuildRoot(window: *Window, vcx: *Context(AnimationExample)) Entity(AnimationExample) {
    const view = buildRoot(window, vcx);
    selftest_view = view;
    return view;
}

fn selftestHeadless(gpa: std.mem.Allocator) !void {
    const out = std.debug.print;
    var app = try App.initHeadless(gpa);
    defer app.deinit();
    const win = try app.openWindow(.{
        .bounds = .{ .origin = .{ .x = 0, .y = 0 }, .size = .{ .w = 300, .h = 300 } },
        .title = "Animation",
    }, selftestBuildRoot);
    _ = app.step();
    const null_backend = app.getNullBackend() orelse return error.SelftestNeedsNullBackend;
    const view = selftest_view orelse return error.SelftestNoView;

    var failures: u32 = 0;
    const check = struct {
        fn ok(cond: bool, count: *u32, comptime fmt: []const u8, args: anytype) void {
            if (cond) {
                out("selftest PASS: " ++ fmt ++ "\n", args);
            } else {
                out("selftest FAIL: " ++ fmt ++ "\n", args);
                count.* += 1;
            }
        }
    }.ok;

    // -- 0. initial state mirrors the GPUI fixture --
    check(view.read().spring_phase == 0, &failures, "phase starts at 0", .{});
    check(view.read().spring_damping == 14.0, &failures, "damping starts at 14", .{});
    check(win.scene.slice().len >= 7, &failures, "initial animation frame rendered", .{});

    // -- 1. clicking the spring card advances the phase (GPUI's test) --
    var clicked = false;
    for (win.ui_frame.regions[0..win.ui_frame.region_count]) |region| {
        if (region.bounds.w == 240 and region.bounds.h > 100) {
            _ = null_backend.pushEvent(.{ .mouse = .{ .pos = .{ .x = region.bounds.x + 10, .y = region.bounds.y + 10 }, .button = .left, .pressed = true } });
            _ = null_backend.pushEvent(.{ .mouse = .{ .pos = .{ .x = region.bounds.x + 10, .y = region.bounds.y + 10 }, .button = .left, .pressed = false } });
            clicked = true;
            break;
        }
    }
    _ = app.step();
    check(clicked, &failures, "found and clicked the spring card", .{});
    check(view.read().spring_phase == 1, &failures, "click advances phase to 1 (got {d})", .{view.read().spring_phase});

    // -- 2. stepping the spring converges on the new target --
    {
        var position_spring = anim.Spring.init(view.read().springConfig(), 0);
        position_spring.epsilon = 0.25;
        _ = position_spring.advance(0);
        position_spring.retarget(BALL_TRAVEL);
        var i: usize = 0;
        while (i < 600) : (i += 1) {
            _ = position_spring.advance(1.0 / 60.0);
        }
        check(@abs(position_spring.state.position - BALL_TRAVEL) < 1.0, &failures, "ball settles at 98px (got {d:.1})", .{position_spring.state.position});
        check(position_spring.settled(), &failures, "position spring reports settled", .{});
    }

    // -- 3. damping drag retunes the spring --
    {
        const before = view.read().spring_damping;
        const entity = view.readMut();
        entity.damping_drag = .{ .start_x = 100, .start_damping = before };
        win.pointer_position = .{ .x = 100 + SLIDER_WIDTH / 2, .y = 0 };
        var cx = Context(AnimationExample){ .store = &app.entities, .current = view, .window = win };
        entity.sliderMove(win, &cx);
        entity.sliderUp(win, &cx);
        const expect = @min(MAX_DAMPING, before + 0.5 * (MAX_DAMPING - MIN_DAMPING));
        check(@abs(view.read().spring_damping - expect) < 0.01, &failures, "half-track drag retunes damping to {d:.1} (got {d:.1})", .{ expect, view.read().spring_damping });
        check(view.read().damping_drag == null, &failures, "drag released on mouse up", .{});
    }

    // -- 4. spinner clock advances --
    {
        const e0 = view.read().spin_epoch_ms;
        _ = app.step();
        const e1 = view.read().spin_epoch_ms;
        check(e0 != null and e1 != null and e0.? == e1.?, &failures, "spin epoch pinned on first frame", .{});

        // Halfway through the bounce clock is a half-turn. Verify the value
        // survives the element -> scene -> image blit path, not just the
        // scalar animation helper.
        view.readMut().spin_epoch_ms = win.timeMs() - SPIN_PERIOD_MS / 4;
        win.requestRender();
        _ = app.step();
        var half_turn = false;
        for (win.scene.imageSlice()) |image| {
            if (@abs(image.rotation - std.math.pi) < 0.15) half_turn = true;
        }
        check(half_turn, &failures, "spinner emits a half-turn image transform", .{});
    }

    if (failures > 0) {
        out("selftest: {d} FAILURES\n", .{failures});
        std.process.exit(1);
    }
    out("selftest: all checks passed\n", .{});
}
