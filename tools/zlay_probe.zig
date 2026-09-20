const std = @import("std");
const zui = @import("zui");

fn emit(frame: *const zui.elements.Frame, node_index: u16, index: *usize) void {
    const b = frame.nodes[node_index].bounds;
    std.debug.print("row_gap_padding|{d}|{d:.3}|{d:.3}|{d:.3}|{d:.3}\n", .{ index.*, b.x, b.y, b.w, b.h });
    index.* += 1;
    var child = frame.nodes[node_index].first_child;
    while (child) |child_index| : (child = frame.nodes[child_index].next_sibling) emit(frame, child_index, index);
}

fn emitNamed(frame: *const zui.elements.Frame, name: []const u8, node_index: u16, index: *usize) void {
    const b = frame.nodes[node_index].bounds;
    std.debug.print("{s}|{d}|{d:.3}|{d:.3}|{d:.3}|{d:.3}\n", .{ name, index.*, b.x, b.y, b.w, b.h });
    index.* += 1;
    var child = frame.nodes[node_index].first_child;
    while (child) |child_index| : (child = frame.nodes[child_index].next_sibling) emitNamed(frame, name, child_index, index);
}

pub fn main() !void {
    const alloc = std.heap.page_allocator;
    const frame = try alloc.create(zui.elements.Frame);
    defer alloc.destroy(frame);
    frame.* = .{};
    frame.allocator = alloc;
    zui.elements.element.beginFrame(frame);

    const root = zui.div().w(200).h(100).flex_row().gap(3).p(10)
        .child(zui.div().w(30).h(20))
        .child(zui.div().h(20).flex_1());
    zui.elements.layout.layout(frame, root, .{ .w = 200, .h = 100 });

    var index: usize = 0;
    emit(frame, root.index, &index);
    zui.elements.element.endFrame();

    frame.reset(@ptrFromInt(1), .{});
    zui.elements.element.beginFrame(frame);
    const percentage = zui.div().w(200).h(120).p(10)
        .child(zui.div().w_full().h_full().p(5)
        .child(zui.div().w_full().h_full()));
    zui.elements.layout.layout(frame, percentage, .{ .w = 200, .h = 120 });
    index = 0;
    emitNamed(frame, "percentage_nested", percentage.index, &index);
    zui.elements.element.endFrame();

    frame.reset(@ptrFromInt(1), .{});
    zui.elements.element.beginFrame(frame);
    const authored_percentage = zui.div().w(200).h(120)
        .child(zui.div().w_percent(0.5).h_percent(0.5));
    zui.elements.layout.layout(frame, authored_percentage, .{ .w = 200, .h = 120 });
    index = 0;
    emitNamed(frame, "authored_percentage", authored_percentage.index, &index);
    zui.elements.element.endFrame();

    frame.reset(@ptrFromInt(1), .{});
    zui.elements.element.beginFrame(frame);
    const wrap = zui.div().w(100).h(100).flex_row().flex_wrap().gap(4)
        .child(zui.div().w(40).h(10))
        .child(zui.div().w(40).h(10))
        .child(zui.div().w(40).h(10))
        .child(zui.div().absolute().right(3).top(4).size(8))
        .child(zui.div().absolute().inset(7));
    zui.elements.layout.layout(frame, wrap, .{ .w = 100, .h = 100 });
    index = 0;
    emitNamed(frame, "wrap_absolute", wrap.index, &index);

    zui.elements.element.endFrame();
    frame.reset(@ptrFromInt(1), .{});
    zui.elements.element.beginFrame(frame);
    const centered = zui.div().w(100).h(50).flex_row().items_center().justify_between().p(4)
        .child(zui.div().size(10))
        .child(zui.div().w(30).h(20));
    zui.elements.layout.layout(frame, centered, .{ .w = 100, .h = 50 });
    index = 0;
    emitNamed(frame, "center_between", centered.index, &index);
    zui.elements.element.endFrame();

    frame.reset(@ptrFromInt(1), .{});
    zui.elements.element.beginFrame(frame);
    const constrained = zui.div().w(100).h(20)
        .child(zui.div().h(20).flex_1().min_w(60).max_w(80));
    zui.elements.layout.layout(frame, constrained, .{ .w = 100, .h = 20 });
    index = 0;
    emitNamed(frame, "min_max", constrained.index, &index);
    zui.elements.element.endFrame();

    frame.reset(@ptrFromInt(1), .{});
    zui.elements.element.beginFrame(frame);
    const grid = zui.div().w(100).h(50)
        .grid_columns(&.{ .{ .length = 40 }, .{ .fr = 1 } })
        .grid_rows(&.{.{ .length = 20 }})
        .child(zui.div().h(20).grid_column(.{ .line = 1 }, .{ .line = 2 }))
        .child(zui.div().h(20).grid_column(.{ .line = 2 }, .{ .line = 3 }));
    zui.elements.layout.layout(frame, grid, .{ .w = 100, .h = 50 });
    index = 0;
    emitNamed(frame, "grid_basic", grid.index, &index);
    zui.elements.element.endFrame();

    frame.reset(@ptrFromInt(1), .{});
    zui.elements.element.beginFrame(frame);
    const column_grid = zui.div().w(100).h(40)
        .grid_columns(&.{ .{ .length = 50 }, .{ .length = 50 } })
        .grid_rows(&.{ .{ .length = 20 }, .{ .length = 20 } })
        .grid_auto_flow(.column)
        .child(zui.div())
        .child(zui.div())
        .child(zui.div());
    zui.elements.layout.layout(frame, column_grid, .{ .w = 100, .h = 40 });
    index = 0;
    emitNamed(frame, "grid_column_flow", column_grid.index, &index);
    zui.elements.element.endFrame();

    frame.reset(@ptrFromInt(1), .{});
    zui.elements.element.beginFrame(frame);
    const aspect = zui.div().w(100).h(60).flex_row().items_stretch()
        .child(zui.div().w(80).aspect_ratio(2));
    zui.elements.layout.layout(frame, aspect, .{ .w = 100, .h = 60 });
    index = 0;
    emitNamed(frame, "aspect_ratio", aspect.index, &index);
    zui.elements.element.endFrame();

    frame.reset(@ptrFromInt(1), .{});
    zui.elements.element.beginFrame(frame);
    const reverse = zui.div().w(100).h(20).flex_row_reverse()
        .child(zui.div().w(30).h(20))
        .child(zui.div().w(20).h(20));
    zui.elements.layout.layout(frame, reverse, .{ .w = 100, .h = 20 });
    index = 0;
    emitNamed(frame, "reverse_flow", reverse.index, &index);
    zui.elements.element.endFrame();

    frame.reset(@ptrFromInt(1), .{});
    zui.elements.element.beginFrame(frame);
    const wrap_reverse = zui.div().w(100).h(100).flex_row().flex_wrap_reverse()
        .child(zui.div().w(40).h(10))
        .child(zui.div().w(40).h(10))
        .child(zui.div().w(40).h(10));
    zui.elements.layout.layout(frame, wrap_reverse, .{ .w = 100, .h = 100 });
    index = 0;
    emitNamed(frame, "wrap_reverse", wrap_reverse.index, &index);
    zui.elements.element.endFrame();
}
