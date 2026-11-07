//! Port of GPUI's `examples/painting.rs`.
//!
//! Differences from the Rust version:
//! - The Rust logo (`lyon::extra::rust_logo::build_logo_path`) is not drawn. It is about 800 lines
//!   of SVG path data in lyon_extra, and ZUI has no lyon. Everything else is drawn as in GPUI.
//! - `example_support::load_fonts` is a no-op on native platforms, so it is not called.
//! - `cx.on_window_closed(|cx, _| cx.quit())` is not registered. `App.close_window` already quits
//!   when the last window closes on platforms that quit then, and no `on_window_closed` exists yet.
//! - `PathBuilder::dash_array(..)` is `dash_array_set(..)`, which can fail. `build()` errors are
//!   `catch unreachable`, as `unwrap()` is in Rust.
//! - The wave's `LineJoin::Bevel` is implicit: ZUI's stroker always uses bevel joins.
//! - GPUI clones the default paths in `render`. Here they are cloned in `paint`, because
//!   `paint_path` consumes the path it is given.
//! - Like the Rust source, the Dashed/Solid button does not call `cx.notify()`, so its label only
//!   changes on the next redraw (for example after the next stroke point).

const std = @import("std");
const gpui = @import("zui");
const App = gpui.App;
const Background = gpui.Background;
const Bounds = gpui.Bounds;
const ClickEvent = gpui.ClickEvent;
const Context = gpui.Context;
const Div = gpui.Div;
const MouseDownEvent = gpui.MouseDownEvent;
const MouseMoveEvent = gpui.MouseMoveEvent;
const MouseUpEvent = gpui.MouseUpEvent;
const Path = gpui.scene.Path;
const PathBuilder = gpui.path_builder.PathBuilder;
const Pixels = gpui.Pixels;
const Point = gpui.Point;
const Window = gpui.Window;
const WindowOptions = gpui.WindowOptions;
const canvas = gpui.canvas;
const div = gpui.div;
const linear_color_stop = gpui.linear_color_stop;
const linear_gradient = gpui.linear_gradient;
const point = gpui.point;
const px = gpui.px;
const quad = gpui.quad;
const rgb = gpui.rgb;
const size = gpui.size;

const DefaultLine = struct {
    path: Path(Pixels),
    color: Background,
};

const BackgroundQuad = struct {
    bounds: Bounds(Pixels),
    color: Background,
};

const PaintingViewer = struct {
    allocator: std.mem.Allocator,
    default_lines: []DefaultLine,
    background_quads: []BackgroundQuad,
    lines: std.ArrayList(std.ArrayList(Point(Pixels))),
    start: Point(Pixels),
    dashed: bool,
    _painting: bool,

    fn to_background(c: anytype) Background {
        return gpui.color.to_background(c);
    }

    fn new(allocator: std.mem.Allocator) !PaintingViewer {
        var default_lines: std.ArrayList(DefaultLine) = .empty;
        try build_default_lines(allocator, &default_lines);

        // Black squares beneath transparent paths.
        const quads = try allocator.dupe(BackgroundQuad, &[_]BackgroundQuad{
            .{ .bounds = .{ .origin = point(px(70.0), px(70.0)), .size = size(px(40.0), px(40.0)) }, .color = to_background(gpui.black()) },
            .{ .bounds = .{ .origin = point(px(170.0), px(70.0)), .size = size(px(40.0), px(40.0)) }, .color = to_background(gpui.black()) },
            .{ .bounds = .{ .origin = point(px(270.0), px(70.0)), .size = size(px(40.0), px(40.0)) }, .color = to_background(gpui.black()) },
            .{ .bounds = .{ .origin = point(px(370.0), px(70.0)), .size = size(px(40.0), px(40.0)) }, .color = to_background(gpui.black()) },
            .{ .bounds = .{ .origin = point(px(450.0), px(50.0)), .size = size(px(80.0), px(80.0)) }, .color = to_background(gpui.black()) },
        });

        return .{
            .allocator = allocator,
            .default_lines = try default_lines.toOwnedSlice(allocator),
            .background_quads = quads,
            .lines = .empty,
            .start = point(px(0.0), px(0.0)),
            .dashed = false,
            ._painting = false,
        };
    }

    fn build_default_lines(alloc: std.mem.Allocator, lines: *std.ArrayList(DefaultLine)) !void {
        // 50% opaque red path that extends across black quad.
        var builder = PathBuilder.fill(alloc);
        try builder.move_to(point(px(50.0), px(50.0)));
        try builder.line_to(point(px(130.0), px(50.0)));
        try builder.line_to(point(px(130.0), px(130.0)));
        try builder.line_to(point(px(50.0), px(130.0)));
        builder.close();
        const path = try builder.build();
        const red = rgb(0xFF0000).alpha(0.5);
        try lines.append(alloc, .{ .path = path, .color = to_background(red) });

        // 50% opaque blue path that extends across black quad.
        builder = PathBuilder.fill(alloc);
        try builder.move_to(point(px(150.0), px(50.0)));
        try builder.line_to(point(px(230.0), px(50.0)));
        try builder.line_to(point(px(230.0), px(130.0)));
        try builder.line_to(point(px(150.0), px(130.0)));
        builder.close();
        const blue_path = try builder.build();
        const blue = rgb(0x0000FF).alpha(0.5);
        try lines.append(alloc, .{ .path = blue_path, .color = to_background(blue) });

        // 50% opaque green path that extends across black quad.
        builder = PathBuilder.fill(alloc);
        try builder.move_to(point(px(250.0), px(50.0)));
        try builder.line_to(point(px(330.0), px(50.0)));
        try builder.line_to(point(px(330.0), px(130.0)));
        try builder.line_to(point(px(250.0), px(130.0)));
        builder.close();
        const green_path = try builder.build();
        const green = rgb(0x00FF00).alpha(0.5);
        try lines.append(alloc, .{ .path = green_path, .color = to_background(green) });

        // 50% opaque black path that extends across black quad.
        builder = PathBuilder.fill(alloc);
        try builder.move_to(point(px(350.0), px(50.0)));
        try builder.line_to(point(px(430.0), px(50.0)));
        try builder.line_to(point(px(430.0), px(130.0)));
        try builder.line_to(point(px(350.0), px(130.0)));
        builder.close();
        const black_path = try builder.build();
        const black = rgb(0x000000).alpha(0.5);
        try lines.append(alloc, .{ .path = black_path, .color = to_background(black) });

        // Two 50% opaque red circles overlapping - center should be darker red
        {
            const center = point(px(530.0), px(85.0));
            const radius = px(30.0);
            builder = PathBuilder.fill(alloc);
            try builder.move_to(point(center.x + radius, center.y));
            try builder.arc_to(point(radius, radius), px(0.0), false, false, point(center.x - radius, center.y));
            try builder.arc_to(point(radius, radius), px(0.0), false, false, point(center.x + radius, center.y));
            builder.close();
            const circle = try builder.build();
            const red1 = rgb(0xFF0000).alpha(0.5);
            try lines.append(alloc, .{ .path = circle, .color = to_background(red1) });
        }
        {
            const center = point(px(570.0), px(85.0));
            const radius = px(30.0);
            builder = PathBuilder.fill(alloc);
            try builder.move_to(point(center.x + radius, center.y));
            try builder.arc_to(point(radius, radius), px(0.0), false, false, point(center.x - radius, center.y));
            try builder.arc_to(point(radius, radius), px(0.0), false, false, point(center.x + radius, center.y));
            builder.close();
            const circle = try builder.build();
            const red2 = rgb(0xFF0000).alpha(0.5);
            try lines.append(alloc, .{ .path = circle, .color = to_background(red2) });
        }

        // draw a Rust logo: not ported (see the header).

        // draw a lightening bolt ⚡
        builder = PathBuilder.fill(alloc);
        const bolt = [_]Point(Pixels){
            point(px(150.0), px(300.0)),
            point(px(200.0), px(225.0)),
            point(px(200.0), px(275.0)),
            point(px(250.0), px(200.0)),
        };
        try builder.add_polygon(&bolt, false);
        const bolt_path = try builder.build();
        try lines.append(alloc, .{ .path = bolt_path, .color = to_background(rgb(0x1d4ed8)) });

        // draw a ⭐
        builder = PathBuilder.fill(alloc);
        try builder.move_to(point(px(350.0), px(200.0)));
        try builder.line_to(point(px(370.0), px(260.0)));
        try builder.line_to(point(px(430.0), px(260.0)));
        try builder.line_to(point(px(380.0), px(300.0)));
        try builder.line_to(point(px(400.0), px(360.0)));
        try builder.line_to(point(px(350.0), px(320.0)));
        try builder.line_to(point(px(300.0), px(360.0)));
        try builder.line_to(point(px(320.0), px(300.0)));
        try builder.line_to(point(px(270.0), px(260.0)));
        try builder.line_to(point(px(330.0), px(260.0)));
        try builder.line_to(point(px(350.0), px(200.0)));
        const star_path = try builder.build();
        const star_gradient = linear_gradient(
            180.0,
            linear_color_stop(rgb(0xFACC15), 0.7),
            linear_color_stop(rgb(0xD56D0C), 1.0),
        ).with_color_space(.oklab);
        try lines.append(alloc, .{ .path = star_path, .color = star_gradient });

        // draw linear gradient
        const square_bounds: Bounds(Pixels) = .{
            .origin = point(px(450.0), px(200.0)),
            .size = size(px(200.0), px(80.0)),
        };
        const height = square_bounds.size.height;
        const horizontal_offset = height;
        const vertical_offset = px(30.0);
        builder = PathBuilder.fill(alloc);
        try builder.move_to(square_bounds.bottom_left());
        try builder.curve_to(
            square_bounds.origin.add(point(horizontal_offset, vertical_offset)),
            square_bounds.origin.add(point(px(0.0), vertical_offset)),
        );
        try builder.line_to(square_bounds.top_right().add(point(-horizontal_offset, vertical_offset)));
        try builder.curve_to(
            square_bounds.bottom_right(),
            square_bounds.top_right().add(point(px(0.0), vertical_offset)),
        );
        try builder.line_to(square_bounds.bottom_left());
        const gradient_path = try builder.build();
        try lines.append(alloc, .{
            .path = gradient_path,
            .color = linear_gradient(
                180.0,
                linear_color_stop(gpui.blue(), 0.4),
                linear_color_stop(gpui.red(), 1.0),
            ),
        });

        // draw a pie chart
        const pie_center_radius = point(px(96.0), px(96.0));
        const pie_center = point(px(775.0), px(255.0));
        const Segment = struct { start: Point(Pixels), end: Point(Pixels), color: u32 };
        const segments = [_]Segment{
            .{ .start = point(px(871.0), px(255.0)), .end = point(px(747.0), px(163.0)), .color = 0x1374e9 },
            .{ .start = point(px(747.0), px(163.0)), .end = point(px(679.0), px(263.0)), .color = 0xe13527 },
            .{ .start = point(px(679.0), px(263.0)), .end = point(px(754.0), px(349.0)), .color = 0x0751ce },
            .{ .start = point(px(754.0), px(349.0)), .end = point(px(854.0), px(310.0)), .color = 0x209742 },
            .{ .start = point(px(854.0), px(310.0)), .end = point(px(871.0), px(255.0)), .color = 0xfbc10a },
        };
        for (segments) |segment| {
            builder = PathBuilder.fill(alloc);
            try builder.move_to(segment.start);
            try builder.arc_to(pie_center_radius, px(0.0), false, false, segment.end);
            try builder.line_to(pie_center);
            builder.close();
            const slice = try builder.build();
            try lines.append(alloc, .{ .path = slice, .color = to_background(rgb(segment.color)) });
        }

        // draw a wave
        builder = PathBuilder.stroke(alloc, px(1.0));
        _ = builder.with_style(.{ .stroke = .{ .line_width = 1.0 } });
        try builder.move_to(point(px(40.0), px(420.0)));
        var i: usize = 1;
        while (i < 50) : (i += 1) {
            const fi: f32 = @floatFromInt(i);
            try builder.line_to(point(
                px(40.0 + fi * 10.0),
                px(420.0 + @sin(fi * 10.0) * 40.0),
            ));
        }
        const wave = try builder.build();
        try lines.append(alloc, .{ .path = wave, .color = to_background(gpui.green()) });
    }

    fn clear(this: *PaintingViewer, cx: *Context(PaintingViewer)) void {
        this.lines.clearRetainingCapacity();
        cx.notify();
    }

    fn on_clear(this: *PaintingViewer, _: *const ClickEvent, _: *Window, cx: *Context(PaintingViewer)) void {
        this.clear(cx);
    }

    fn on_toggle_dashed(this: *PaintingViewer, _: *const ClickEvent, _: *Window, _: *Context(PaintingViewer)) void {
        this.dashed = !this.dashed;
    }

    fn on_mouse_down(this: *PaintingViewer, ev: *const MouseDownEvent, _: *Window, _: *Context(PaintingViewer)) void {
        this._painting = true;
        this.start = ev.position;
        var path: std.ArrayList(Point(Pixels)) = .empty;
        path.append(this.allocator, ev.position) catch @panic("OOM");
        this.lines.append(this.allocator, path) catch @panic("OOM");
    }

    fn on_mouse_move(this: *PaintingViewer, ev: *const MouseMoveEvent, _: *Window, cx: *Context(PaintingViewer)) void {
        if (!this._painting) return;

        const is_shifted = ev.modifiers.shift;
        var pos = ev.position;
        // When holding shift, draw a straight line
        if (is_shifted) {
            const dx = pos.x - this.start.x;
            const dy = pos.y - this.start.y;
            if (@abs(dx) > @abs(dy)) {
                pos.y = this.start.y;
            } else {
                pos.x = this.start.x;
            }
        }

        if (this.lines.items.len > 0) {
            const last = &this.lines.items[this.lines.items.len - 1];
            last.append(this.allocator, pos) catch @panic("OOM");
        }

        cx.notify();
    }

    fn on_mouse_up(this: *PaintingViewer, _: *const MouseUpEvent, _: *Window, _: *Context(PaintingViewer)) void {
        this._painting = false;
    }

    pub fn render(self: *PaintingViewer, _: *Window, cx: *Context(PaintingViewer)) *Div {
        const paint_ctx: PaintCtx = .{
            .allocator = self.allocator,
            .default_lines = self.default_lines,
            .background_quads = self.background_quads,
            .lines = self.lines.items,
            .dashed = self.dashed,
        };

        return div()
            .bg(gpui.white())
            .size_full()
            .p_4()
            .flex()
            .flex_col()
            .child(
                div()
                    .flex()
                    .gap_2()
                    .justify_between()
                    .items_center()
                    .child("Mouse down any point and drag to draw lines (Hold on shift key to draw straight lines)")
                    .child(
                        div()
                            .flex()
                            .gap_x_2()
                            .child(button(if (self.dashed) "Solid" else "Dashed", cx.listener(on_toggle_dashed)))
                            .child(button("Clear", cx.listener(on_clear))),
                    ),
            )
            .child(
                div()
                    .size_full()
                    .child(canvas(paint_ctx, prepaint, paint).size_full())
                    .on_mouse_down(.left, cx.listener(on_mouse_down))
                    .on_mouse_move(cx.listener(on_mouse_move))
                    .on_mouse_up(.left, cx.listener(on_mouse_up)),
            );
    }
};

/// What the canvas paints. `canvas` copies it into the frame arena.
const PaintCtx = struct {
    allocator: std.mem.Allocator,
    default_lines: []const DefaultLine,
    background_quads: []const BackgroundQuad,
    lines: []const std.ArrayList(Point(Pixels)),
    dashed: bool,
};

fn prepaint(_: PaintCtx, _: Bounds(Pixels), _: *Window, _: *App) void {}

fn paint(c: PaintCtx, _: Bounds(Pixels), _: *void, window: *Window, _: *App) void {
    // First draw background quads
    for (c.background_quads) |q| {
        window.paint_quad(quad(
            q.bounds,
            px(0.0),
            q.color,
            px(0.0),
            gpui.transparent_black(),
            .solid,
        ));
    }

    // Then draw the default paths on top
    for (c.default_lines) |line| {
        // paint_path consumes its path, so each frame paints a copy.
        const copy = line.path.clone() catch @panic("OOM");
        window.paint_path(copy, line.color);
    }

    for (c.lines) |points| {
        if (points.items.len < 2) continue;

        var builder = PathBuilder.stroke(c.allocator, px(1.0));
        if (c.dashed) builder.dash_array_set(&[_]Pixels{ px(4.0), px(2.0) }) catch @panic("OOM");
        for (points.items, 0..) |p, i| {
            if (i == 0) {
                builder.move_to(p) catch @panic("OOM");
            } else {
                builder.line_to(p) catch @panic("OOM");
            }
        }

        const path = builder.build() catch continue;
        window.paint_path(path, gpui.black());
    }
}

fn button(text: []const u8, on_click: anytype) *Div {
    return div()
        .id(text)
        .child(text)
        .bg(gpui.black())
        .text_color(gpui.white())
        .active(gpui.style_refinement().opacity(0.8))
        .flex()
        .px_3()
        .py_1()
        .on_click(on_click);
}

fn build_root(_: *Window, app: *App) gpui.Entity(PaintingViewer) {
    const viewer = PaintingViewer.new(app.allocator) catch @panic("OOM");
    return app.new(viewer);
}

fn run_example(cx: *App) void {
    _ = cx.open_window(.{ .focus = true }, build_root) catch unreachable;
    cx.activate(true);
}

pub fn main() void {
    gpui.Application.new().run(run_example);
}
