const std = @import("std");
const t = std.testing;
const e = @import("element.zig");
const a = @import("zlay_adapter.zig");
const legacy = @import("layout.zig");
const core = @import("../core/root.zig");
const z = @import("layout");

fn agree(frame: *e.Frame, root: e.Element, viewport: core.Rect) !void {
    legacy.layoutLegacy(frame, root, viewport);
    const expected = try t.allocator.alloc(core.Rect, frame.node_count);
    defer t.allocator.free(expected);
    for (frame.nodes[0..frame.node_count], expected) |n, *r| r.* = n.bounds;
    try a.layout(frame, root, viewport);
    for (frame.nodes[0..frame.node_count], expected, 0..) |n, r, i| {
        for ([_]f32{ r.x, r.y, r.w, r.h }, [_]f32{ n.bounds.x, n.bounds.y, n.bounds.w, n.bounds.h }) |want, got| {
            if (@abs(want - got) > a.agreement_tolerance) std.debug.print("node {d}: legacy {any}, zlay {any}\n", .{ i, r, n.bounds });
            try t.expectApproxEqAbs(want, got, a.agreement_tolerance);
        }
    }
}

test "adapter agreement: nested column row padding gap grow full axes resize fractional origins" {
    const f = try t.allocator.create(e.Frame);
    defer t.allocator.destroy(f);
    f.* = .{};
    f.allocator = t.allocator;
    e.beginFrame(f);
    defer e.endFrame();
    const root = e.div().p(10).gap(5)
        .child(e.div().h(20).flex_row().gap(3)
            .child(e.div().w(30).h_full())
            .child(e.spacer())
            .child(e.div().w(20).h(10)))
        .child(e.div().w_full().flex_1());
    try agree(f, root, .{ .x = 0.25, .y = 0.75, .w = 200.5, .h = 100.5 });
    try agree(f, root, .{ .w = 301, .h = 151 });
}

test "adapter agreement: row wrapping absolute offsets inset and scroll" {
    const f = try t.allocator.create(e.Frame);
    defer t.allocator.destroy(f);
    f.* = .{};
    f.allocator = t.allocator;
    e.beginFrame(f);
    defer e.endFrame();
    const root = e.div().flex_row().flex_wrap().w(100).h(100).gap(4).scroll_y(5)
        .child(e.div().w(40).h(10))
        .child(e.div().w(40).h(10))
        .child(e.div().w(40).h(10))
        .child(e.div().absolute().right(3).top(4).size(8))
        .child(e.div().absolute().inset(7));
    try agree(f, root, .{ .w = 100, .h = 100 });
}

test "adapter agreement: center between square max width and paint-only borders" {
    const f = try t.allocator.create(e.Frame);
    defer t.allocator.destroy(f);
    f.* = .{};
    f.allocator = t.allocator;
    e.beginFrame(f);
    defer e.endFrame();
    const root = e.div().flex_row().items_center().justify_between().p(4).border_2()
        .child(e.div().size(10).max_w_full())
        .child(e.div().w(30).h(20));
    try agree(f, root, .{ .w = 100, .h = 50 });
}

test "adapter measurement callbacks: text handoff and image intrinsic aspect" {
    const fonts = @import("../fonts/text_engine.zig");
    const engine = fonts.Engine.init(t.allocator) catch |err| switch (err) {
        error.ShaperUnavailable, error.LibraryUnavailable, error.NoFontsAvailable, error.FontCorpusIncomplete => return error.SkipZigTest,
        else => return err,
    };
    defer engine.deinit();
    const f = try t.allocator.create(e.Frame);
    defer t.allocator.destroy(f);
    f.* = .{};
    f.allocator = t.allocator;
    f.engine = engine;
    const cache = try @import("../images/root.zig").Cache.init(t.allocator);
    defer cache.deinit(t.allocator);
    f.images = cache;
    _ = try cache.assets.preloadBytes("<svg width=\"40\" height=\"20\" xmlns=\"http://www.w3.org/2000/svg\"></svg>", 0);
    e.beginFrame(f);
    defer e.endFrame();
    const image = e.svg("<svg width=\"40\" height=\"20\" xmlns=\"http://www.w3.org/2000/svg\"></svg>").w(20);
    const text = e.text("a short wrapped sentence", .{ .size = 14 }).w(80);
    const root = e.div().flex_row().gap(5).child(text).child(image);
    try agree(f, root, .{ .w = 300, .h = 100 });
    try t.expect(f.nodes[text.index].cozmic_measured);
    try t.expect(@import("text_engine.zig").retainedLayout(f, &f.nodes[text.index]) != null);
    try t.expectApproxEqAbs(@as(f32, 10), f.nodes[image.index].bounds.h, a.agreement_tolerance);
}

test "adapter divergence fixture: grow weights below one" {
    const f = try t.allocator.create(e.Frame);
    defer t.allocator.destroy(f);
    f.* = .{};
    f.allocator = t.allocator;
    e.beginFrame(f);
    defer e.endFrame();
    const child = e.div().h(10);
    f.nodes[child.index].style.flex_grow = 0.25;
    const root = e.div().flex_row().child(child);
    legacy.layoutLegacy(f, root, .{ .w = 100, .h = 20 });
    try t.expectApproxEqAbs(@as(f32, 100), f.nodes[child.index].bounds.w, a.agreement_tolerance);
    try a.layout(f, root, .{ .w = 100, .h = 20 });
    try t.expectApproxEqAbs(@as(f32, 25), f.nodes[child.index].bounds.w, a.agreement_tolerance);
}

test "adapter divergence fixture: wrapped grow retains authored expansion" {
    const f = try t.allocator.create(e.Frame);
    defer t.allocator.destroy(f);
    f.* = .{};
    f.allocator = t.allocator;
    e.beginFrame(f);
    defer e.endFrame();
    const child = e.div().w(20).h(10).flex_1();
    const root = e.div().flex_row().flex_wrap().child(child);
    legacy.layoutLegacy(f, root, .{ .w = 100, .h = 20 });
    try t.expectApproxEqAbs(@as(f32, 20), f.nodes[child.index].bounds.w, a.agreement_tolerance);
    try a.layout(f, root, .{ .w = 100, .h = 20 });
    try t.expectApproxEqAbs(@as(f32, 100), f.nodes[child.index].bounds.w, a.agreement_tolerance);
}

test "adapter explicit unsupported ledger and column wrap exclusion" {
    try t.expect(a.unsupported.len > 0);
    const style = a.translateStyle(&.{ .style = .{ .direction = .column, .flex_wrap = true } }, null);
    try t.expectEqual(z.style.flex.FlexWrap.no_wrap, style.flex_wrap);
}

// These are dependency probes at the adapter boundary, NOT public grid
// support. Shared adapter translation supplies box sizing/padding/gaps; only
// these tests add the unexposed grid vocabulary. Oracle values: plan.md §M3,
// historical vendored Taffy 0.14 (not a fresh Rust oracle execution).
test "adapter current-pin grid rerun: 40px 20px tracks with 10px gap" {
    var tree = z.tree.TaffyTree.init(t.allocator);
    defer tree.deinit();
    tree.disable_rounding();
    const first = try tree.new_leaf(.{});
    const second = try tree.new_leaf(.{});
    var style = a.translateStyle(&.{ .style = .{ .gap = 10 } }, null);
    style.display = .grid;
    style.grid_template_columns = &.{ z.style.grid.grid_template_component_from_length(40), z.style.grid.grid_template_component_from_length(20) };
    const root = try tree.new_with_children(style, &.{ first, second });
    try tree.compute_layout(root, .{ .width = .max_content, .height = .max_content });
    try t.expectApproxEqAbs(@as(f32, 50), (try tree.layout(second)).location.x, a.agreement_tolerance);
}

test "adapter current-pin grid rerun: border-box 100 padding 10 one fr" {
    var tree = z.tree.TaffyTree.init(t.allocator);
    defer tree.deinit();
    tree.disable_rounding();
    const child = try tree.new_leaf(.{});
    var style = a.translateStyle(&.{ .style = .{ .width = 100, .padding = e.EdgeValues.all(10) } }, null);
    style.display = .grid;
    style.grid_template_columns = &.{z.style.grid.grid_template_component_from_fr(1)};
    const root = try tree.new_with_children(style, &.{child});
    try tree.compute_layout(root, .{ .width = .max_content, .height = .max_content });
    try t.expectApproxEqAbs(@as(f32, 80), (try tree.layout(child)).size.width, a.agreement_tolerance);
}

test "adapter current-pin grid rerun: min-width 60 in 40 track" {
    var tree = z.tree.TaffyTree.init(t.allocator);
    defer tree.deinit();
    tree.disable_rounding();
    const child = try tree.new_leaf(.{ .min_size = .{ .width = z.style.dimension.LengthPercentageAuto.length(60), .height = z.style.dimension.LengthPercentageAuto.auto() } });
    var style = a.translateStyle(&.{}, null);
    style.display = .grid;
    style.grid_template_columns = &.{z.style.grid.grid_template_component_from_length(40)};
    const root = try tree.new_with_children(style, &.{child});
    try tree.compute_layout(root, .{ .width = .max_content, .height = .max_content });
    try t.expectApproxEqAbs(@as(f32, 60), (try tree.layout(child)).size.width, a.agreement_tolerance);
}
