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
    const root = e.div().p(10).gap(5).items_start()
        .child(e.div().h(20).flex_row().gap(3).items_start()
            .child(e.div().w(30).h_full())
            .child(e.spacer())
            .child(e.div().w(20).h(10)))
        .child(e.div().w_full().flex_1());
    try agree(f, root, .{ .x = 0.25, .y = 0.75, .w = 200.5, .h = 100.5 });
    try agree(f, root, .{ .w = 301, .h = 151 });
}

test "adapter oracle: row wrapping stretches definite cross-axis lines" {
    const f = try t.allocator.create(e.Frame);
    defer t.allocator.destroy(f);
    f.* = .{};
    f.allocator = t.allocator;
    e.beginFrame(f);
    defer e.endFrame();
    const root = e.div().flex_row().flex_wrap().w(100).h(100).gap(4)
        .child(e.div().w(40).h(10))
        .child(e.div().w(40).h(10))
        .child(e.div().w(40).h(10))
        .child(e.div().absolute().right(3).top(4).size(8))
        .child(e.div().absolute().inset(7));
    try a.layout(f, root, .{ .w = 100, .h = 100 });
    const first = f.nodes[f.nodes[root.index].first_child.?].bounds;
    const second_index = f.nodes[f.nodes[root.index].first_child.?].next_sibling.?;
    const second = f.nodes[second_index].bounds;
    const third_index = f.nodes[second_index].next_sibling.?;
    const third = f.nodes[third_index].bounds;
    try t.expectApproxEqAbs(@as(f32, 0), first.y, a.agreement_tolerance);
    try t.expectApproxEqAbs(@as(f32, 0), second.y, a.agreement_tolerance);
    try t.expectApproxEqAbs(@as(f32, 52), third.y, a.agreement_tolerance);
}

test "adapter oracle: nested percentage sizes resolve through content boxes" {
    const f = try t.allocator.create(e.Frame);
    defer t.allocator.destroy(f);
    f.* = .{};
    f.allocator = t.allocator;
    e.beginFrame(f);
    defer e.endFrame();
    const root = e.div().w(200).h(120).p(10)
        .child(e.div().w_full().h_full().p(5)
        .child(e.div().w_full().h_full()));
    try a.layout(f, root, .{ .w = 200, .h = 120 });
    const child = f.nodes[root.index].first_child.?;
    const grandchild = f.nodes[child].first_child.?;
    try t.expectApproxEqAbs(@as(f32, 0), f.nodes[root.index].bounds.x, a.agreement_tolerance);
    try t.expectApproxEqAbs(@as(f32, 200), f.nodes[root.index].bounds.w, a.agreement_tolerance);
    try t.expectApproxEqAbs(@as(f32, 10), f.nodes[child].bounds.x, a.agreement_tolerance);
    try t.expectApproxEqAbs(@as(f32, 180), f.nodes[child].bounds.w, a.agreement_tolerance);
    try t.expectApproxEqAbs(@as(f32, 15), f.nodes[grandchild].bounds.x, a.agreement_tolerance);
    try t.expectApproxEqAbs(@as(f32, 170), f.nodes[grandchild].bounds.w, a.agreement_tolerance);
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
    const root = e.div().flex_row().gap(5).items_start().child(text).child(image);
    try agree(f, root, .{ .w = 300, .h = 100 });
    try t.expect(f.nodes[text.index].cozmic_measured);
    try t.expect(@import("text_engine.zig").retainedLayout(f, &f.nodes[text.index]) != null);
    try t.expect(f.nodes[text.index].baseline != null);
    try t.expect(f.nodes[text.index].last_baseline != null);
    try t.expectApproxEqAbs(@as(f32, 10), f.nodes[image.index].bounds.h, a.agreement_tolerance);
}

test "adapter oracle: available-space text reflow retains resolved wrap width" {
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
    e.beginFrame(f);
    defer e.endFrame();
    const text = e.text("available space should reflow this text", .{ .size = 14 }).w_percent(1);
    const root = e.div().w(80).child(text);
    try a.layout(f, root, .{ .w = 80, .h = 200 });
    try t.expectEqual(@as(?f32, 80), f.nodes[text.index].style.width);
    try t.expect(f.nodes[text.index].measured.h > 20);
    try t.expect(@import("text_engine.zig").retainedLayout(f, &f.nodes[text.index]) != null);
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

test "adapter keeps legacy leaf padding and relative offsets explicit" {
    const node = e.Node{ .kind = .text, .style = .{ .padding = .{ .left = 3, .top = 2 }, .left = 4, .top = 5 } };
    const style = a.translateStyle(&node, null);
    try t.expectApproxEqAbs(@as(f32, 0), style.padding.left.resolve(100), 0.001);
    try t.expect(style.inset.left.is_auto());
    try t.expect(style.inset.top.is_auto());
}

test "adapter translates public align-content vocabulary" {
    const values = [_]struct { input: e.AlignContent, expected: z.style.alignment.AlignContentKeyword }{
        .{ .input = .start, .expected = .start },
        .{ .input = .center, .expected = .center },
        .{ .input = .end, .expected = .end },
        .{ .input = .stretch, .expected = .stretch },
        .{ .input = .between, .expected = .space_between },
        .{ .input = .around, .expected = .space_around },
        .{ .input = .evenly, .expected = .space_evenly },
    };
    for (values) |value| {
        const translated = a.translateStyle(&.{ .style = .{ .align_content = value.input } }, null);
        try t.expectEqual(value.expected, translated.align_content.?.keyword_value());
    }
}

test "adapter preserves public cross-axis alignment values" {
    const values = [_]struct { input: e.Align, expected: z.style.alignment.AlignItemsKeyword }{
        .{ .input = .start, .expected = .flex_start },
        .{ .input = .center, .expected = .center },
        .{ .input = .end, .expected = .flex_end },
        .{ .input = .stretch, .expected = .stretch },
    };
    for (values) |value| {
        const translated = a.translateStyle(&.{ .style = .{ .alignment = value.input } }, null);
        try t.expectEqual(value.expected, translated.align_items.?.keyword_value());
    }
}

test "adapter translates baseline alignment and overflow contract" {
    const baseline = a.translateStyle(&.{ .style = .{ .alignment = .baseline } }, null);
    try t.expectEqual(z.style.alignment.AlignItemsKeyword.baseline, baseline.align_items.?.keyword_value());
    const clipped = a.translateStyle(&.{ .style = .{ .overflow_x = .clip, .overflow_y = .scroll } }, null);
    try t.expectEqual(z.style.Overflow.clip, clipped.overflow.x);
    try t.expectEqual(z.style.Overflow.scroll, clipped.overflow.y);
}

test "adapter exposes scrollbar gutter and named grid lines" {
    const f = try t.allocator.create(e.Frame);
    defer t.allocator.destroy(f);
    f.* = .{};
    f.allocator = t.allocator;
    e.beginFrame(f);
    defer e.endFrame();
    const root = e.div().grid_columns(&.{ .{ .length = 40 }, .{ .length = 60 } })
        .grid_column_line_name(0, "start")
        .grid_column_line_name(1, "middle")
        .grid_column_line_name(2, "end")
        .scrollbar_width(7)
        .overflow(.scroll, .scroll);
    const translated = a.translateStyleWithFrame(f, &f.nodes[root.index], null);
    try t.expectEqual(@as(f32, 7), translated.scrollbar_width);
    try t.expectEqual(@as(usize, 3), translated.grid_template_column_names.len);
    try t.expectEqual(@as(usize, 1), translated.grid_template_column_names[1].len);
    try t.expect(std.mem.eql(u8, "middle", translated.grid_template_column_names[1][0]));
}

test "adapter retains scroll region and scrollbar output" {
    const f = try t.allocator.create(e.Frame);
    defer t.allocator.destroy(f);
    f.* = .{};
    f.allocator = t.allocator;
    e.beginFrame(f);
    defer e.endFrame();
    const root = e.div().w(50).h(20).overflow(.scroll, .scroll).scrollbar_width(5)
        .child(e.div().w(100).h(40));
    try a.layout(f, root, .{ .w = 50, .h = 20 });
    const node = &f.nodes[root.index];
    try t.expectApproxEqAbs(@as(f32, 5), node.scrollbar_size.w, a.agreement_tolerance);
    try t.expectApproxEqAbs(@as(f32, 5), node.scrollbar_size.h, a.agreement_tolerance);
    try t.expect(node.scrollWidth() >= 100);
    try t.expect(node.scrollHeight() >= 40);
}

test "adapter translates intrinsic sizing and percentage min max constraints" {
    const f = try t.allocator.create(e.Frame);
    defer t.allocator.destroy(f);
    f.* = .{};
    f.allocator = t.allocator;
    e.beginFrame(f);
    defer e.endFrame();
    const node = e.div().w_min_content().h_max_content().min_w_percent(0.25).max_h_percent(0.75);
    const translated = a.translateStyleWithFrame(f, &f.nodes[node.index], null);
    try t.expectEqual(z.style.dimension.Dimension.min_content, translated.size.width);
    try t.expectEqual(z.style.dimension.Dimension.max_content, translated.size.height);
    try t.expectEqual(@as(?f32, 50), translated.min_size.width.resolve(200));
    try t.expectEqual(@as(?f32, 75), translated.max_size.height.resolve(100));
}

test "adapter translates public main-axis distribution vocabulary" {
    const values = [_]struct { input: e.Justify, expected: z.style.alignment.AlignContentKeyword }{
        .{ .input = .start, .expected = .flex_start },
        .{ .input = .center, .expected = .center },
        .{ .input = .end, .expected = .flex_end },
        .{ .input = .between, .expected = .space_between },
        .{ .input = .around, .expected = .space_around },
        .{ .input = .evenly, .expected = .space_evenly },
    };
    for (values) |value| {
        const translated = a.translateStyle(&.{ .style = .{ .justify = value.input } }, null);
        try t.expectEqual(value.expected, translated.justify_content.?.keyword_value());
    }
}

test "adapter translates reverse flex directions" {
    const values = [_]struct { input: e.Direction, expected: z.style.flex.FlexDirection }{
        .{ .input = .row, .expected = .row },
        .{ .input = .column, .expected = .column },
        .{ .input = .row_reverse, .expected = .row_reverse },
        .{ .input = .column_reverse, .expected = .column_reverse },
    };
    for (values) |value| {
        const translated = a.translateStyle(&.{ .style = .{ .direction = value.input } }, null);
        try t.expectEqual(value.expected, translated.flex_direction);
    }
}

test "adapter translates reverse wrapping" {
    const style = a.translateStyle(&.{ .style = .{ .direction = .row, .flex_wrap = true, .flex_wrap_reverse = true } }, null);
    try t.expectEqual(z.style.flex.FlexWrap.wrap_reverse, style.flex_wrap);
}

test "adapter translates public flex shrink and basis" {
    const translated = a.translateStyle(&.{ .style = .{ .flex_shrink = 0.25, .flex_basis = 37 } }, null);
    try t.expectApproxEqAbs(@as(f32, 0.25), translated.flex_shrink, 0.001);
    try t.expectEqual(z.style.dimension.Dimension.length(37), translated.flex_basis);
}

test "adapter translates compact min and max constraints" {
    const f = try t.allocator.create(e.Frame);
    defer t.allocator.destroy(f);
    f.* = .{};
    f.allocator = t.allocator;
    e.beginFrame(f);
    defer e.endFrame();
    const node = e.div().min_w(60).max_w(80).min_h(10).max_h(40);
    const translated = a.translateStyleWithFrame(f, &f.nodes[node.index], null);
    try t.expectEqual(@as(?f32, 60), translated.min_size.width.resolve(100));
    try t.expectEqual(@as(?f32, 80), translated.max_size.width.resolve(100));
    try t.expectEqual(@as(?f32, 10), translated.min_size.height.resolve(100));
    try t.expectEqual(@as(?f32, 40), translated.max_size.height.resolve(100));
}

test "adapter translates compact aspect ratio" {
    const f = try t.allocator.create(e.Frame);
    defer t.allocator.destroy(f);
    f.* = .{};
    f.allocator = t.allocator;
    e.beginFrame(f);
    defer e.endFrame();
    const node = e.div().w(80).aspect_ratio(2);
    const translated = a.translateStyleWithFrame(f, &f.nodes[node.index], null);
    try t.expectEqual(@as(?f32, 2), translated.aspect_ratio);
}

test "adapter translates public grid track templates" {
    const f = try t.allocator.create(e.Frame);
    defer t.allocator.destroy(f);
    f.* = .{};
    f.allocator = t.allocator;
    e.beginFrame(f);
    defer e.endFrame();
    const node = e.div()
        .grid_columns(&.{ .{ .length = 40 }, .{ .fr = 1 } })
        .grid_rows(&.{.{ .length = 20 }});
    const translated = a.translateStyleWithFrame(f, &f.nodes[node.index], null);
    try t.expectEqual(z.style.Display.grid, translated.display);
    try t.expectEqual(@as(usize, 2), translated.grid_template_columns.len);
    try t.expectEqual(@as(usize, 1), translated.grid_template_rows.len);
}

test "adapter translates full grid track vocabulary and named placement" {
    const f = try t.allocator.create(e.Frame);
    defer t.allocator.destroy(f);
    f.* = .{};
    f.allocator = t.allocator;
    e.beginFrame(f);
    defer e.endFrame();
    const node = e.div()
        .grid_columns(&.{
            .{ .percent = 0.25 },
            e.GridTrack{ .auto = {} },
            .{ .minmax = .{ .min = .{ .length = 20 }, .max = .{ .fr = 1 } } },
        })
        .grid_column(.{ .named_line = .{ .name = "content", .index = 1 } }, .{ .named_span = .{ .name = "content", .count = 2 } });
    const translated = a.translateStyleWithFrame(f, &f.nodes[node.index], null);
    try t.expectEqual(@as(usize, 3), translated.grid_template_columns.len);
    try t.expectEqual(@as(?i16, 1), translated.grid_column.start.line_index());
    try t.expectEqual(@as(?u16, 2), translated.grid_column.end.span_value());
}

test "adapter oracle: percentage aspect ratio survives fractional resize" {
    const f = try t.allocator.create(e.Frame);
    defer t.allocator.destroy(f);
    f.* = .{};
    f.allocator = t.allocator;
    e.beginFrame(f);
    defer e.endFrame();
    const child = e.div().w_percent(0.5).aspect_ratio(2);
    const root = e.div().w_percent(1).h_percent(1).child(child);
    try a.layout(f, root, .{ .x = 0.25, .y = 0.5, .w = 200, .h = 120 });
    try t.expectApproxEqAbs(@as(f32, 100), f.nodes[child.index].bounds.w, a.agreement_tolerance);
    try t.expectApproxEqAbs(@as(f32, 50), f.nodes[child.index].bounds.h, a.agreement_tolerance);
    try a.layout(f, root, .{ .x = 0.25, .y = 0.5, .w = 301.5, .h = 121.25 });
    try t.expectApproxEqAbs(@as(f32, 150.75), f.nodes[child.index].bounds.w, a.agreement_tolerance);
    try t.expectApproxEqAbs(@as(f32, 75.375), f.nodes[child.index].bounds.h, a.agreement_tolerance);
}

test "adapter translates public grid line placement" {
    const f = try t.allocator.create(e.Frame);
    defer t.allocator.destroy(f);
    f.* = .{};
    f.allocator = t.allocator;
    e.beginFrame(f);
    defer e.endFrame();
    const node = e.div()
        .grid_column(.{ .line = 2 }, .{ .line = 3 })
        .grid_row(.{ .line = 1 }, .{ .span = 2 });
    const translated = a.translateStyleWithFrame(f, &f.nodes[node.index], null);
    try t.expectEqual(@as(?i16, 2), translated.grid_column.start.line_index());
    try t.expectEqual(@as(?i16, 3), translated.grid_column.end.line_index());
    try t.expectEqual(@as(?u16, 2), translated.grid_row.end.span_value());
}

test "adapter translates public grid auto-flow" {
    const f = try t.allocator.create(e.Frame);
    defer t.allocator.destroy(f);
    f.* = .{};
    f.allocator = t.allocator;
    e.beginFrame(f);
    defer e.endFrame();
    const node = e.div().grid_auto_flow(.column_dense);
    const translated = a.translateStyleWithFrame(f, &f.nodes[node.index], null);
    try t.expectEqual(z.style.Display.grid, translated.display);
    try t.expectEqual(z.style.grid.GridAutoFlow.column_dense, translated.grid_auto_flow);
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
