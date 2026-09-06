const std = @import("std");
const core = @import("../core/root.zig");
const element = @import("element.zig");

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
        .text => {
            var glyphs: usize = 0;
            for (node.text_value) |byte| if ((byte & 0xc0) != 0x80) {
                glyphs += 1;
            };
            const count = @as(f32, @floatFromInt(glyphs));
            natural.w = count * (node.text_style.size * 0.64 + node.text_style.tracking);
            natural.h = node.text_style.line_height orelse node.text_style.size * 1.25;
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
