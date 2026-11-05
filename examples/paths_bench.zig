//! Port of GPUI's `examples/paths_bench.rs`: 2000 gradient-filled stars, repainted every frame.
//! It is a benchmark for path rasterization, so it asks for an animation frame on every render.
//!
//! Differences from the Rust version:
//! - `example_support::load_fonts` is a no-op on native platforms, so it is not called.
//! - `canvas(prepaint, paint)` is `canvas_fn(ctx, paint)`: the prepaint closure in the Rust
//!   source does nothing, so it is left out.
//! - The default lines are cloned in `paint`, because `paint_path` consumes its path (as in
//!   `painting.zig`). The clone is part of what this benchmark measures, as it is in GPUI.
//! - The window title is "Vulkan", as in the Rust source, although the renderer is not Vulkan.

const std = @import("std");
const gpui = @import("zui");
const App = gpui.App;
const Background = gpui.Background;
const Bounds = gpui.Bounds;
const Context = gpui.Context;
const Div = gpui.Div;
const Entity = gpui.Entity;
const Path = gpui.scene.Path;
const PathBuilder = gpui.path_builder.PathBuilder;
const Pixels = gpui.Pixels;
const Window = gpui.Window;
const WindowOptions = gpui.WindowOptions;
const canvas_fn = gpui.canvas_fn;
const div = gpui.div;
const linear_color_stop = gpui.linear_color_stop;
const linear_gradient = gpui.linear_gradient;
const point = gpui.point;
const px = gpui.px;
const rgb = gpui.rgb;
const size = gpui.size;

const DEFAULT_WINDOW_WIDTH: Pixels = px(1024.0);
const DEFAULT_WINDOW_HEIGHT: Pixels = px(768.0);

const DefaultLine = struct {
    path: Path(Pixels),
    color: Background,
};

const PaintingViewer = struct {
    default_lines: []DefaultLine,
    _painting: bool,

    fn new(allocator: std.mem.Allocator) !PaintingViewer {
        var lines: std.ArrayList(DefaultLine) = .empty;

        // draw a lightening bolt ⚡
        for (0..2000) |_| {
            // draw a ⭐
            var builder = PathBuilder.fill(allocator);
            try builder.move_to(point(px(350.0), px(100.0)));
            try builder.line_to(point(px(370.0), px(160.0)));
            try builder.line_to(point(px(430.0), px(160.0)));
            try builder.line_to(point(px(380.0), px(200.0)));
            try builder.line_to(point(px(400.0), px(260.0)));
            try builder.line_to(point(px(350.0), px(220.0)));
            try builder.line_to(point(px(300.0), px(260.0)));
            try builder.line_to(point(px(320.0), px(200.0)));
            try builder.line_to(point(px(270.0), px(160.0)));
            try builder.line_to(point(px(330.0), px(160.0)));
            try builder.line_to(point(px(350.0), px(100.0)));
            const path = try builder.build();
            const color = linear_gradient(
                180.0,
                linear_color_stop(rgb(0xFACC15), 0.7),
                linear_color_stop(rgb(0xD56D0C), 1.0),
            ).with_color_space(.oklab);
            try lines.append(allocator, .{ .path = path, .color = color });
        }

        return .{
            .default_lines = try lines.toOwnedSlice(allocator),
            ._painting = false,
        };
    }

    pub fn render(self: *PaintingViewer, window: *Window, _: *Context(PaintingViewer)) *Div {
        window.request_animation_frame();
        return div().size_full().child(
            canvas_fn(PaintCtx{ .default_lines = self.default_lines }, paint).size_full(),
        );
    }
};

/// What the canvas paints. `canvas_fn` copies it into the frame arena.
const PaintCtx = struct {
    default_lines: []const DefaultLine,
};

fn paint(c: PaintCtx, _: Bounds(Pixels), window: *Window, _: *App) void {
    for (c.default_lines) |line| {
        // paint_path consumes its path, so each frame paints a copy.
        const copy = line.path.clone() catch @panic("OOM");
        window.paint_path(copy, line.color);
    }
}

fn build_root(_: *Window, app: *App) Entity(PaintingViewer) {
    const viewer = PaintingViewer.new(app.allocator) catch @panic("OOM");
    return app.new(viewer);
}

fn run_example(cx: *App) void {
    _ = cx.open_window(WindowOptions{
        .titlebar = .{ .title = "Vulkan" },
        .focus = true,
        .window_bounds = .{ .windowed = Bounds(Pixels).centered(null, size(DEFAULT_WINDOW_WIDTH, DEFAULT_WINDOW_HEIGHT), cx) },
    }, build_root) catch unreachable;
    cx.activate(true);
}

pub fn main() void {
    gpui.Application.new().run(run_example);
}
