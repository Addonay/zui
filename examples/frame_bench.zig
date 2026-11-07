//! Not a GPUI example: times `Window.draw` on the headless platform, so only ZUI's own work counts,
//! not a renderer or a display. Build it with `-Doptimize=ReleaseFast`, since Debug numbers mean little.

const std = @import("std");
const gpui = @import("zui");
const App = gpui.App;
const Context = gpui.Context;
const Div = gpui.Div;
const Entity = gpui.Entity;
const Window = gpui.Window;
const div = gpui.div;
const px = gpui.px;
const red = gpui.red;
const blue = gpui.blue;
const style_refinement = gpui.style_refinement;

const view_count = 20;
const rows_per_view = 60;

const Rows = struct {
    pub fn render(_: *Rows, _: *Window, _: *Context(Rows)) *Div {
        var el = div().id("rows").w(px(300)).h(px(600)).flex().flex_col();
        for (0..rows_per_view) |i| {
            el = el.child(div().id(i).h(px(10)).bg(red()).hover(style_refinement().bg(blue()))
                .child(gpui.format("row {d}", .{i})));
        }
        return el;
    }
    fn touch(_: *Rows, cx: *Context(Rows)) void {
        cx.notify();
    }
};

const Grid = struct {
    views: [view_count]Entity(Rows),
    cached: bool,

    pub fn render(self: *Grid, _: *Window, _: *Context(Grid)) *Div {
        var el = div().flex().flex_wrap().size_full();
        for (self.views) |view| {
            if (self.cached) {
                el = el.child(view.cached(style_refinement().w(px(300)).h(px(600))));
            } else {
                el = el.child(view);
            }
        }
        return el;
    }
    fn touch(_: *Grid, cx: *Context(Grid)) void {
        cx.notify();
    }
    fn new(app: *App, cached: bool) Entity(Grid) {
        var views: [view_count]Entity(Rows) = undefined;
        for (&views) |*view| view.* = app.new(Rows{});
        return app.new(Grid{ .views = views, .cached = cached });
    }
    fn build_uncached(_: *Window, app: *App) Entity(Grid) {
        return new(app, false);
    }
    fn build_cached(_: *Window, app: *App) Entity(Grid) {
        return new(app, true);
    }
};

/// Many plain elements: what an element costs, without text.
const Quads = struct {
    pub fn render(_: *Quads, _: *Window, _: *Context(Quads)) *Div {
        var el = div().flex().flex_wrap().size_full();
        for (0..10_000) |_| el = el.child(div().w(px(4)).h(px(4)).bg(red()));
        return el;
    }
    fn touch(_: *Quads, cx: *Context(Quads)) void {
        cx.notify();
    }
    fn build(_: *Window, app: *App) Entity(Quads) {
        return app.new(Quads{});
    }
};

/// Many different lines: what text costs once it is shaped.
const Lines = struct {
    pub fn render(_: *Lines, _: *Window, _: *Context(Lines)) *Div {
        var el = div().flex().flex_col().size_full();
        for (0..2000) |i| {
            el = el.child(gpui.format("the quick brown fox jumps over the lazy dog {d}", .{i}));
        }
        return el;
    }
    fn touch(_: *Lines, cx: *Context(Lines)) void {
        cx.notify();
    }
    fn build(_: *Window, app: *App) Entity(Lines) {
        return app.new(Lines{});
    }
};

fn now_ns() u64 {
    return gpui.executor.now_ns();
}

const frames = 60;

fn report(name: []const u8, samples: *[frames]u64) void {
    std.mem.sort(u64, samples, {}, std.sort.asc(u64));
    var total: u64 = 0;
    for (samples) |s| total += s;
    std.debug.print("{s:<28} median {d:>9.1} us  best {d:>9.1} us  mean {d:>9.1} us\n", .{
        name,
        @as(f64, @floatFromInt(samples[frames / 2])) / 1000,
        @as(f64, @floatFromInt(samples[0])) / 1000,
        @as(f64, @floatFromInt(total / frames)) / 1000,
    });
}

/// Redraws `frames` frames, each after `touch`.
fn run(name: []const u8, comptime build: anytype, comptime touch: anytype) void {
    const allocator = std.heap.smp_allocator;
    const app = App.init(allocator, gpui.platform.headless_platform(allocator)) catch @panic("no app");
    const handle = app.open_window(.{}, build) catch @panic("no window");
    const window = handle.window(app).?;
    const root: Entity(gpui.window.RootViewType(build)) = .{ .entity_id_ = handle.entity_id_ };
    for (0..5) |_| window.draw(app);
    var samples: [frames]u64 = undefined;
    for (&samples, 0..) |*sample, i| {
        touch(root, app, i);
        const start = now_ns();
        window.draw(app);
        sample.* = now_ns() - start;
    }
    report(name, &samples);
}

fn touch_root(root: anytype, app: *App, _: usize) void {
    root.update(app, @TypeOf(root).Type.touch, .{});
}

fn touch_one_view(root: Entity(Grid), app: *App, i: usize) void {
    const view = root.read(app).views[i % view_count];
    view.update(app, Rows.touch, .{});
}

pub fn main() void {
    std.debug.print("{d} views of {d} rows, and so on; {d} frames each\n", .{ view_count, rows_per_view, frames });
    run("views, uncached", Grid.build_uncached, touch_root);
    run("views, cached, none dirty", Grid.build_cached, touch_root);
    run("views, cached, one dirty", Grid.build_cached, touch_one_view);
    run("10k quads", Quads.build, touch_root);
    run("2000 lines of text", Lines.build, touch_root);
}
