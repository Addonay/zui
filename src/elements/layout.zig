const std = @import("std");
const core = @import("../core/root.zig");
const element = @import("element.zig");
const text_engine = @import("text_engine.zig");

fn childCount(frame: *element.Frame, node: *const element.Node) usize {
    var count: usize = 0;
    var child = node.first_child;
    while (child) |index| : (child = frame.nodes[index].next_sibling) count += 1;
    return count;
}

pub fn measure(frame: *element.Frame, index: u16) core.Size {
    const node = &frame.nodes[index];
    var natural = core.Size{};

    switch (node.kind) {
        .image => {
            // Intrinsic size; one explicit axis derives the other by aspect
            // (explicit w+h / square below still win).
            natural.w = node.image.intrinsic_w;
            natural.h = node.image.intrinsic_h;
            if (node.style.width != null and node.style.height == null and
                node.image.intrinsic_w > 0 and node.image.intrinsic_h > 0)
            {
                natural.h = node.style.width.? * node.image.intrinsic_h / node.image.intrinsic_w;
            } else if (node.style.height != null and node.style.width == null and
                node.image.intrinsic_w > 0 and node.image.intrinsic_h > 0)
            {
                natural.w = node.style.height.? * node.image.intrinsic_w / node.image.intrinsic_h;
            }
        },
        .text => {
            // Text is always cozmic. With no engine installed the node has
            // no measurable ink (zero box, nothing painted); there is no
            // legacy/bitmap fallback.
            node.cozmic_measured = false;
            // Re-measuring owns the node's measure→paint handoff: drop the
            // previous layout first so a failed shape can never leave stale
            // cozmic state for paint to see.
            node.clearCozmicLayout();
            if (text_engine.engineFor(frame)) |engine| {
                if (text_engine.measureCached(engine, node, text_engine.frameAllocator(frame))) |size| {
                    natural.w = size.w;
                    natural.h = size.h;
                    node.cozmic_measured = true;
                } else |_| {
                    // Invalid metrics or OOM: the node keeps its zero natural
                    // size and paint counts the mismatch instead of drawing
                    // stale ink.
                }
            }
        },
        .spacer => {},
        .container => {
            var child = node.first_child;
            var normal_count: usize = 0;
            while (child) |child_index| : (child = frame.nodes[child_index].next_sibling) {
                const child_node = &frame.nodes[child_index];
                const child_size = measure(frame, child_index);
                if (child_node.style.absolute) continue;
                normal_count += 1;
                if (node.style.direction == .row) {
                    natural.w += child_size.w;
                    natural.h = @max(natural.h, child_size.h);
                } else {
                    natural.w = @max(natural.w, child_size.w);
                    natural.h += child_size.h;
                }
            }
            if (normal_count > 1) {
                const gaps = @as(f32, @floatFromInt(normal_count - 1)) * node.style.gap;
                if (node.style.direction == .row) natural.w += gaps else natural.h += gaps;
            }
            natural.w += node.style.padding.left + node.style.padding.right;
            natural.h += node.style.padding.top + node.style.padding.bottom;
        },
    }

    if (node.style.square) |side| {
        natural = .{ .w = side, .h = side };
    }
    // Measured-box semantics: an explicit width is the measured slot, not
    // the wrapped text extent. Cozmic shapes with the same value as its wrap
    // constraint (`text_engine.wrapWidth` returns `style.width`), so the
    // painted layout fits this slot, while row siblings and justification
    // advance by the slot.
    // The branch above only replaces the text advance, and only when the
    // cozmic measure actually ran; this clamp always wins.
    if (node.style.width) |width| natural.w = width;
    if (node.style.height) |height| natural.h = height;
    node.measured = natural;
    return natural;
}

pub fn layout(frame: *element.Frame, root: element.Element, viewport: core.Rect) void {
    _ = measure(frame, root.index);
    place(frame, root.index, viewport, true);
}

fn resolveSize(node: *const element.Node, available: core.Rect, forced: bool) core.Size {
    var result = node.measured;
    if (forced) result = .{ .w = available.w, .h = available.h };
    if (node.style.full_width) result.w = available.w;
    if (node.style.full_height) result.h = available.h;
    if (node.style.max_width_full) result.w = @min(result.w, available.w);
    if (node.style.square) |side| result = .{ .w = side, .h = side };
    if (node.style.width) |width| result.w = @min(width, available.w);
    if (node.style.height) |height| result.h = @min(height, available.h);
    return result;
}

fn place(frame: *element.Frame, index: u16, available: core.Rect, forced: bool) void {
    const node = &frame.nodes[index];
    const size = resolveSize(node, available, forced);
    node.bounds = .{ .x = available.x, .y = available.y, .w = @max(0, size.w), .h = @max(0, size.h) };
    if (node.kind != .container) return;

    const padding = node.style.padding;
    const content = core.Rect{
        .x = node.bounds.x + padding.left,
        .y = node.bounds.y + padding.top,
        .w = @max(0, node.bounds.w - padding.left - padding.right),
        .h = @max(0, node.bounds.h - padding.top - padding.bottom),
    };

    var total_main: f32 = 0;
    var flex_total: f32 = 0;
    var normal_count: usize = 0;
    var child = node.first_child;
    while (child) |child_index| : (child = frame.nodes[child_index].next_sibling) {
        const child_node = &frame.nodes[child_index];
        if (child_node.style.absolute) continue;
        normal_count += 1;
        flex_total += child_node.style.flex_grow;
        if (child_node.style.flex_grow == 0) {
            total_main += if (node.style.direction == .row) child_node.measured.w else child_node.measured.h;
        }
    }
    if (normal_count > 1) total_main += @as(f32, @floatFromInt(normal_count - 1)) * node.style.gap;
    const available_main = if (node.style.direction == .row) content.w else content.h;
    const remaining = @max(0, available_main - total_main);

    var dynamic_gap = node.style.gap;
    var cursor: f32 = if (node.style.direction == .row) content.x else content.y;
    if (node.style.justify == .center and flex_total == 0) cursor += remaining / 2;
    if (node.style.justify == .between and normal_count > 1 and flex_total == 0) {
        dynamic_gap = node.style.gap + remaining / @as(f32, @floatFromInt(normal_count - 1));
    }

    child = node.first_child;
    while (child) |child_index| : (child = frame.nodes[child_index].next_sibling) {
        const child_node = &frame.nodes[child_index];
        if (child_node.style.absolute) {
            placeAbsolute(frame, child_index, node.bounds);
            continue;
        }

        var child_size = child_node.measured;
        if (node.style.direction == .row) {
            if (child_node.style.flex_grow > 0 and flex_total > 0) child_size.w = remaining * child_node.style.flex_grow / flex_total;
            if (child_node.style.full_height) child_size.h = content.h;
            // Explicit heights must survive even when measured height is 0
            // (e.g. an empty gradient fill in a flex row); otherwise the
            // forced place below clamps them to the 0 measured height.
            if (child_node.style.height) |h| child_size.h = h;
            if (child_node.style.square) |s| child_size.h = s;
            var y = content.y;
            if (node.style.alignment == .center) y += (content.h - child_size.h) / 2;
            place(frame, child_index, .{ .x = cursor, .y = y, .w = child_size.w, .h = child_size.h }, true);
            cursor += child_size.w + dynamic_gap;
        } else {
            if (child_node.style.flex_grow > 0 and flex_total > 0) child_size.h = remaining * child_node.style.flex_grow / flex_total;
            const stretch = child_node.kind == .container and child_node.style.width == null and child_node.style.square == null;
            if (child_node.style.full_width or stretch) child_size.w = content.w;
            var x = content.x;
            if (node.style.alignment == .center) x += (content.w - child_size.w) / 2;
            place(frame, child_index, .{ .x = x, .y = cursor, .w = child_size.w, .h = child_size.h }, true);
            cursor += child_size.h + dynamic_gap;
        }
    }
}

fn placeAbsolute(frame: *element.Frame, index: u16, parent: core.Rect) void {
    const node = &frame.nodes[index];
    var rect = core.Rect{ .x = parent.x, .y = parent.y, .w = node.measured.w, .h = node.measured.h };
    if (node.style.inset_value) |inset| {
        rect = .{ .x = parent.x + inset, .y = parent.y + inset, .w = @max(0, parent.w - inset * 2), .h = @max(0, parent.h - inset * 2) };
    } else {
        if (node.style.left) |left| rect.x = parent.x + left;
        if (node.style.right) |right| rect.x = parent.x + parent.w - right - rect.w;
        if (node.style.top) |top| rect.y = parent.y + top;
    }
    place(frame, index, rect, true);
}

test "column layout applies padding and gap" {
    var frame = element.Frame{};
    frame.reset(@ptrFromInt(1), .{});
    element.beginFrame(&frame);
    defer element.endFrame();
    const root = element.div().w(100).p(10).gap(5)
        .child(element.div().h(20))
        .child(element.div().h(30));
    layout(&frame, root, .{ .w = 100, .h = 100 });
    try std.testing.expectEqual(@as(f32, 10), frame.nodes[1].bounds.x);
    try std.testing.expectEqual(@as(f32, 35), frame.nodes[2].bounds.y);
}

test "text measure matches engine measure" {
    const t = std.testing;
    const engine = try testEngine();
    defer engine.deinit();
    var frame = element.Frame{};
    frame.reset(@ptrFromInt(1), .{});
    frame.engine = engine;
    frame.allocator = t.allocator;
    element.beginFrame(&frame);
    defer element.endFrame();
    const root = element.text("abc", .{ .size = 14 });
    layout(&frame, root, .{ .w = 500, .h = 100 });
    const node = &frame.nodes[root.index];
    try t.expect(node.cozmic_measured);
    // NOTE: root text bounds stretch to the forced viewport; measured width
    // must match the engine layout the painter replays.
    const want = try engine.measure(t.allocator, "abc", text_engine.attrs(node));
    try t.expectApproxEqAbs(want, node.measured.w, 0.001);
    try t.expect(want > 0);
}

test "progress track fill is proportional and fits parent" {
    const t = std.testing;
    var frame = element.Frame{};
    frame.reset(@ptrFromInt(1), .{});
    element.beginFrame(&frame);
    defer element.endFrame();
    const root = element.progressTrack(0.5);
    layout(&frame, root, .{ .w = 200, .h = 10 });
    try t.expectApproxEqAbs(@as(f32, 200), frame.nodes[root.index].bounds.w, 0.5);
    const fill_idx = frame.nodes[root.index].first_child.?;
    // Half of the 200px track (the old fixed 520px child overflowed here).
    try t.expectApproxEqAbs(@as(f32, 100), frame.nodes[fill_idx].bounds.w, 2.0);
    try t.expectApproxEqAbs(@as(f32, 4), frame.nodes[fill_idx].bounds.h, 0.5);
}

test "row child keeps explicit height with zero measured height" {
    const t = std.testing;
    var frame = element.Frame{};
    frame.reset(@ptrFromInt(1), .{});
    element.beginFrame(&frame);
    defer element.endFrame();
    const root = element.div().flex_row().w(200).h(10)
        .child(element.div().h(4));
    layout(&frame, root, .{ .w = 200, .h = 10 });
    const child_idx = frame.nodes[root.index].first_child.?;
    try t.expectApproxEqAbs(@as(f32, 4), frame.nodes[child_idx].bounds.h, 0.001);
}

test "shaped measure matches the engine's own layout" {
    const t = std.testing;
    const engine = try testEngine();
    defer engine.deinit();

    var frame = element.Frame{};
    frame.reset(@ptrFromInt(1), .{});
    frame.engine = engine;
    frame.allocator = t.allocator;
    element.beginFrame(&frame);
    defer element.endFrame();
    const root = element.text("Hello", .{ .size = 14 });
    layout(&frame, root, .{ .w = 500, .h = 100 });
    const node = &frame.nodes[root.index];
    const want = try engine.measure(t.allocator, "Hello", text_engine.attrs(node));
    try t.expectApproxEqAbs(want, node.measured.w, 0.001);
    // And the shaped width is a real advance, not a zero box.
    try t.expect(want > 1.0);
}

test "text explicit width stays the measured slot" {
    // Regression: cozmic mode used to measure `.w(200)` text as its wrapped
    // extent, so a row sibling after it started at the text ink instead of
    // the 200px slot. The explicit slot is the measured box (the same value
    // is also cozmic's wrap constraint).
    const t = std.testing;
    const engine = try testEngine();
    defer engine.deinit();

    const frame = try t.allocator.create(element.Frame);
    defer t.allocator.destroy(frame);
    frame.* = .{};
    frame.reset(@ptrFromInt(1), .{});
    frame.engine = engine;
    frame.allocator = t.allocator;
    element.beginFrame(frame);
    defer element.endFrame();
    const root = element.div().w(500).h(50).flex_row()
        .child(element.text("x", .{ .size = 14 }).w(200))
        .child(element.text("y", .{ .size = 14 }));
    layout(frame, root, .{ .w = 500, .h = 50 });
    const x_index = frame.nodes[root.index].first_child.?;
    const y_index = frame.nodes[x_index].next_sibling.?;
    try t.expect(frame.nodes[x_index].cozmic_measured);
    try t.expectApproxEqAbs(@as(f32, 200), frame.nodes[x_index].measured.w, 0.001);
    try t.expectApproxEqAbs(@as(f32, 200), frame.nodes[y_index].bounds.x, 0.001);
}

test "text explicit width clamps when cozmic measure fails" {
    // The `.w()` measured-slot clamp is applied after the measure branch,
    // so it must hold on a failed cozmic shape too (invalid metrics), not
    // only when the layout succeeded.
    const t = std.testing;
    const engine = try testEngine();
    defer engine.deinit();

    const frame = try t.allocator.create(element.Frame);
    defer t.allocator.destroy(frame);
    frame.* = .{};
    frame.reset(@ptrFromInt(1), .{});
    frame.engine = engine;
    frame.allocator = t.allocator;
    element.beginFrame(frame);
    defer element.endFrame();
    // line_height 0 is invalid cozmic input; the explicit 200px slot must
    // still win.
    const root = element.div().w(500).h(50).flex_row()
        .child(element.text("x", .{ .size = 14, .line_height = 0 }).w(200))
        .child(element.text("y", .{ .size = 14 }));
    layout(frame, root, .{ .w = 500, .h = 50 });
    const x_index = frame.nodes[root.index].first_child.?;
    const y_index = frame.nodes[x_index].next_sibling.?;
    try t.expect(!frame.nodes[x_index].cozmic_measured);
    try t.expectApproxEqAbs(@as(f32, 200), frame.nodes[x_index].measured.w, 0.001);
    try t.expectApproxEqAbs(@as(f32, 200), frame.nodes[y_index].bounds.x, 0.001);
}

/// Corpus engine, skipping when the host lacks the libraries cozmic loads
/// via `dlopen`.
fn testEngine() !*@import("../fonts/text_engine.zig").Engine {
    const fonts = @import("../fonts/text_engine.zig");
    return fonts.Engine.init(std.testing.allocator) catch |err| switch (err) {
        error.ShaperUnavailable, error.LibraryUnavailable, error.NoFontsAvailable, error.FontCorpusIncomplete => return error.SkipZigTest,
        else => return err,
    };
}
