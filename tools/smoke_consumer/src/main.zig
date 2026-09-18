//! Minimal external consumer of the zui package: exercises the public
//! module surface (`zui.hex`, geometry helpers, limits) without opening
//! a window, so the smoke test stays headless-safe on any machine.
//!
//! It also proves gap §6A: an out-of-tree package defines a custom element
//! through the PUBLIC API only (no core edits) — stable identity,
//! intrinsic measurement, prepaint (hit region + semantic node), ordered
//! scene emission, and frame-end teardown.

const std = @import("std");
const zui = @import("zui");

// --- External custom element: a tiny bar chart, defined here only. --------
const ChartState = struct {
    values: []const f32,
    teardown_calls: u32 = 0,
    clicks: u32 = 0,
};

fn chartMeasure(state: *anyopaque, frame: *zui.elements.Frame) zui.core.Size {
    _ = frame;
    const s: *ChartState = @ptrCast(@alignCast(state));
    return .{ .w = @as(f32, @floatFromInt(s.values.len)) * 10, .h = 20 };
}

fn chartPrepaint(state: *anyopaque, frame: *zui.elements.Frame, index: u16, bounds: zui.Rect, clip: zui.Rect) void {
    _ = bounds;
    _ = clip;
    const s: *ChartState = @ptrCast(@alignCast(state));
    frame.nodes[index].mouse_down_listener = .{ .target = state, .call_fn = chartClick };
    const el: zui.Element = .{ .index = index, .generation = frame.generation };
    _ = el.semantic(.{ .role = .group, .name = "smoke-chart" });
    _ = s;
}

fn chartClick(target: *anyopaque, _: *const zui.elements.element.ListenerPayload, _: *anyopaque) void {
    const s: *ChartState = @ptrCast(@alignCast(target));
    s.clicks += 1;
}

fn chartPaint(state: *anyopaque, frame: *zui.elements.Frame, index: u16, bounds: zui.Rect, scene: *zui.Scene, clip: zui.Rect) void {
    _ = frame;
    _ = index;
    const s: *ChartState = @ptrCast(@alignCast(state));
    var canvas = zui.Canvas.init(scene, clip);
    canvas.fillRect(bounds, zui.hex(0x1e1f2a), 4);
    for (s.values, 0..) |v, i| {
        const x = bounds.x + @as(f32, @floatFromInt(i)) * 10 + 1;
        canvas.fillRect(.{ .x = x, .y = bounds.y + bounds.h * (1 - v), .w = 8, .h = bounds.h * v }, zui.hex(0x7c5cff), 1);
    }
}

fn chartTeardown(state: *anyopaque) void {
    const s: *ChartState = @ptrCast(@alignCast(state));
    s.teardown_calls += 1;
}

const chart_vtable: zui.CustomVTable = .{
    .measure = chartMeasure,
    .prepaint = chartPrepaint,
    .paint = chartPaint,
    .teardown = chartTeardown,
};

fn exerciseCustomElement() void {
    const alloc = std.heap.page_allocator;
    const frame = alloc.create(zui.elements.Frame) catch unreachable;
    defer alloc.destroy(frame);
    frame.* = .{};
    frame.reset(@ptrFromInt(1), .{});
    frame.allocator = alloc;
    zui.elements.element.beginFrame(frame);

    var chart = ChartState{ .values = &.{ 0.25, 0.5, 1.0 } };
    const root = zui.div().w(200).h(100)
        .child(zui.custom(&chart, &chart_vtable).keyed(777));
    zui.elements.layout.layout(frame, root, .{ .w = 200, .h = 100 });

    const idx = frame.nodes[root.index].first_child.?;
    std.debug.assert(frame.nodes[idx].measured.w == 30);
    std.debug.assert(frame.nodes[idx].measured.h == 20);

    const scene = alloc.create(zui.Scene) catch unreachable;
    defer alloc.destroy(scene);
    scene.* = .{};
    zui.elements.painter.paint(frame, root, scene);
    // Background + 3 bars, in order.
    std.debug.assert(scene.slice().len == 4);
    std.debug.assert(frame.semantic_tree.find(777) != null);
    std.debug.assert(frame.region_count == 1);
    frame.regions[0].mouse_down_listener.?.call(@ptrFromInt(1));
    std.debug.assert(chart.clicks == 1);

    std.debug.assert(chart.teardown_calls == 0);
    zui.elements.element.endFrame();
    std.debug.assert(chart.teardown_calls == 1);
    std.debug.print("smoke: custom element ok (30x20, 4 quads, click + semantic + teardown)\n", .{});
}

pub fn main() void {
    const red = zui.hex(0xff0000);
    const p = zui.point(1, 2);
    const s = zui.size(640, 480);
    const r = zui.rect(p.x, p.y, s.w, s.h);
    std.debug.print("smoke: color={d},{d},{d} rect={d}x{d} max_windows={d}\n", .{
        red.r,
        red.g,
        red.b,
        r.w,
        r.h,
        zui.core.limits.MAX_WINDOWS,
    });
    exerciseCustomElement();
}
