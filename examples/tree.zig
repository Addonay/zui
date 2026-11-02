//! Port of GPUI's `examples/tree.rs`.
//!
//! Renders a div with deep children hierarchy. This example is useful to exemplify that Zed can
//! handle deep hierarchies (even though it cannot just yet!).

const std = @import("std");
const gpui = @import("zui");
const App = gpui.App;
const Bounds = gpui.Bounds;
const Context = gpui.Context;
const Hsla = gpui.Hsla;
const Window = gpui.Window;
const WindowOptions = gpui.WindowOptions;
const div = gpui.div;
const px = gpui.px;
const size = gpui.size;

/// The `next_div` closure of the Rust example: a padded div with the next color in the cycle.
fn next_div(colors: []const Hsla, ix: *usize) *gpui.Div {
    const c = colors[ix.* % colors.len];
    ix.* += 1;
    return div().p_0p5().bg(c);
}

const Tree = struct {
    /// `GPUI_TREE_DEPTH` env var, default 50.
    fn depth() u64 {
        const raw = std.c.getenv("GPUI_TREE_DEPTH") orelse return 50;
        return std.fmt.parseInt(u64, std.mem.span(raw), 10) catch 50;
    }

    pub fn render(_: *Tree, _: *Window, _: *Context(Tree)) *gpui.Div {
        var remaining = depth();
        const colors = [_]Hsla{ gpui.red(), gpui.blue(), gpui.green(), gpui.yellow() };
        var next_color: usize = 0;
        var innermost_node = next_div(&colors, &next_color);
        while (remaining > 0) {
            innermost_node = next_div(&colors, &next_color).child(innermost_node);
            remaining -= 1;
        }
        return innermost_node;
    }
};

fn run_example(cx: *App) void {
    const bounds = Bounds(gpui.Pixels).centered(null, size(px(300.0), px(300.0)), cx);
    _ = cx.open_window(.{ .window_bounds = .{ .windowed = bounds } }, struct {
        fn build(_: *Window, app: *App) gpui.Entity(Tree) {
            return app.new(Tree{});
        }
    }.build) catch unreachable;
}

pub fn main() void {
    gpui.Application.new().run(run_example);
}
