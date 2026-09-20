//! Contract-level regression coverage for the GPUI consumer widget surface.
test {
    _ = @import("editor.zig");
    _ = @import("text_area.zig");
    _ = @import("tabs.zig");
    _ = @import("tree_view.zig");
    _ = @import("split_pane.zig");
    _ = @import("command_palette.zig");
}

test "widget render contracts enter layout, hit, and semantic pipelines" {
    const std = @import("std");
    const element = @import("../elements/element.zig");
    const layout = @import("../elements/layout.zig");
    const painter = @import("../elements/painter.zig");
    const gpu = @import("../gpu/root.zig");
    const core = @import("../core/root.zig");
    const tree_mod = @import("tree_view.zig");
    const tabs_mod = @import("tabs.zig");
    const split_mod = @import("split_pane.zig");
    const editor_mod = @import("editor.zig");
    const palette_mod = @import("command_palette.zig");

    const frame = try std.testing.allocator.create(element.Frame);
    defer std.testing.allocator.destroy(frame);
    frame.* = .{};
    frame.reset(@ptrFromInt(1), .{ .x = 4, .y = 4 });
    frame.allocator = std.testing.allocator;
    const scene = try std.testing.allocator.create(gpu.Scene);
    defer std.testing.allocator.destroy(scene);
    scene.* = .{};

    var nodes = [_]tree_mod.Node{
        .{ .key = 1, .label = "root", .has_children = true },
        .{ .key = 2, .label = "child", .parent = 0 },
        .{ .key = 3, .label = "other" },
    };
    var tree = tree_mod.TreeView.init(.{ .nodes = &nodes });
    tree.viewport_height = 24;
    tree.overscan = 0;
    const tabs = [_]tabs_mod.Tab{ .{ .key = 1, .label = "One" }, .{ .key = 2, .label = "Two" } };
    var tab_widget = tabs_mod.Tabs.init(.{ .tabs = &tabs });
    var split = split_mod.SplitPane.init(.{});
    var editor = editor_mod.Editor.init("hello", true);
    const commands = [_]palette_mod.Command{.{ .key = 1, .label = "Open" }};
    var palette = palette_mod.CommandPalette.init(.{ .commands = &commands });
    palette.open = true;

    element.beginFrame(frame);
    defer element.endFrame();
    const root = element.div().w(320).h(400)
        .child(tree.render())
        .child(tab_widget.render())
        .child(split.render())
        .child(editor.render("Editor"))
        .child(palette.render());
    layout.layout(frame, root, core.rect(0, 0, 320, 400));
    painter.paint(frame, root, scene);
    try std.testing.expect(frame.node_count >= 10);
    try std.testing.expect(frame.semantic_count >= 5);
    try std.testing.expect(frame.region_count >= 5);
    try std.testing.expectEqual(tree_mod.Range{ .start = 0, .end = 1 }, tree.visibleRange());
}
