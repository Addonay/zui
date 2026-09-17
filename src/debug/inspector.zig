//! Opt-in JSONL frame snapshots and non-interactive geometry overlays.
//! Snapshots contain application text; never enable on sensitive data by default.
const std = @import("std");
const builtin = @import("builtin");
const element = @import("../elements/element.zig");
const geometry = @import("../core/geometry.zig");
const scene_mod = @import("../gpu/scene.zig");
const stats = @import("stats.zig");
const a11y = @import("../a11y/root.zig");

/// Borrowed sink. Receives one complete JSON line; bytes expire on return.
/// Return an error on write failure. Do not mutate/render the window here.
pub const Sink = struct {
    context: *anyopaque,
    write: *const fn (*anyopaque, []const u8) anyerror!void,
};
pub const Options = struct {
    enabled: bool = false,
    /// Null writes to stderr. A file sink can use its host's normal I/O API.
    sink: ?Sink = null,
};
pub const Overlay = struct {
    bounds: bool = false,
    hit_regions: bool = false,
    focus: bool = false,
};

pub fn environmentEnabled() bool {
    if (builtin.link_libc) {
        if (std.c.getenv("ZUI_INSPECT")) |raw| return std.mem.eql(u8, std.mem.span(raw), "1");
    }
    return false;
}

const Style = struct {
    direction: element.Direction,
    width: ?f32,
    height: ?f32,
    flex_grow: f32,
    gap: f32,
    padding: element.EdgeValues,
    absolute: bool,
    opacity: f32,
    border_width: f32,
    radius: f32,
};
const Semantic = struct { role: a11y.Role, name: []const u8 };
const Node = struct {
    index: usize,
    stable_key: u64,
    first_child: ?u16,
    next_sibling: ?u16,
    kind: element.NodeKind,
    bounds: geometry.Rect,
    style: Style,
    text_preview: []const u8,
    text_truncated: bool,
    semantic: ?Semantic,
    focus_id: ?u32,
    focused: bool,
};
const Region = struct {
    index: usize,
    bounds: geometry.Rect,
    focus_id: ?u32,
    focused: bool,
    owner_id: u32,
    owner_alive: bool,
    click: bool,
    mouse_down: bool,
    mouse_up: bool,
    mouse_move: bool,
    scroll: bool,
};

fn preview(text: []const u8) []const u8 {
    if (!std.unicode.utf8ValidateSlice(text)) return "[invalid UTF-8]";
    var end = @min(text.len, 120);
    while (end < text.len and end > 0 and text[end] & 0xc0 == 0x80) end -= 1;
    return text[0..end];
}

/// Caller owns the returned complete JSON line. Can be called after a headless
/// frame without enabling automatic output. Flat child/sibling links preserve
/// the tree even when construction order differs from tree order.
pub fn jsonLine(allocator: std.mem.Allocator, window: anytype) ![]u8 {
    const frame = &window.ui_frame;
    const nodes = try allocator.alloc(Node, frame.node_count);
    defer allocator.free(nodes);
    for (frame.nodes[0..frame.node_count], 0..) |node, index| {
        var semantic: ?Semantic = null;
        for (frame.semantic_bindings[0..frame.semantic_count]) |binding| {
            if (binding.index == index) semantic = .{ .role = binding.properties.role, .name = if (std.unicode.utf8ValidateSlice(binding.properties.name)) binding.properties.name else "[invalid UTF-8]" };
        }
        const text = preview(node.text_value);
        nodes[index] = .{
            .index = index,
            .stable_key = node.stable_key,
            .first_child = node.first_child,
            .next_sibling = node.next_sibling,
            .kind = node.kind,
            .bounds = node.bounds,
            .style = .{ .direction = node.style.direction, .width = node.style.width, .height = node.style.height, .flex_grow = node.style.flex_grow, .gap = node.style.gap, .padding = node.style.padding, .absolute = node.style.absolute, .opacity = node.style.opacity, .border_width = node.style.border_width, .radius = node.style.radius },
            .text_preview = text,
            .text_truncated = text.len < node.text_value.len,
            .semantic = semantic,
            .focus_id = if (node.focus) |focus| focus.id else null,
            .focused = if (node.focus) |focus| focus.id != 0 and focus.id == window.focused.id else false,
        };
    }
    const regions = try allocator.alloc(Region, frame.region_count);
    defer allocator.free(regions);
    for (frame.regions[0..frame.region_count], 0..) |region, index| {
        regions[index] = .{
            .index = index,
            .bounds = region.bounds,
            .focus_id = if (region.focus) |focus| focus.id else null,
            .focused = if (region.focus) |focus| focus.id != 0 and focus.id == window.focused.id else false,
            .owner_id = region.owner_id,
            .owner_alive = region.ownerAlive(),
            .click = region.listener != null,
            .mouse_down = region.mouse_down_listener != null,
            .mouse_up = region.mouse_up_listener != null,
            .mouse_move = region.mouse_move_listener != null,
            .scroll = region.scroll_listener != null,
        };
    }
    const json = try std.json.Stringify.valueAlloc(allocator, .{
        .type = "zui.frame",
        .version = 1,
        .window = window.id,
        .frame = window.render_count,
        .generation = frame.generation,
        .focused_id = window.focused.id,
        .elements = nodes,
        .hit_regions = regions,
        .stats = window.diagnostics(),
    }, .{});
    defer allocator.free(json);
    return std.mem.concat(allocator, u8, &.{ json, "\n" });
}

pub fn emit(window: anytype) void {
    if (!window.inspector.enabled) return;
    const allocator = window.allocator orelse std.heap.page_allocator;
    const line = jsonLine(allocator, window) catch {
        window.inspector_failures += 1;
        return;
    };
    defer allocator.free(line);
    if (window.inspector.sink) |sink| {
        sink.write(sink.context, line) catch {
            window.inspector_failures += 1;
        };
    } else std.debug.print("{s}", .{line});
}

/// Debug ink is appended, never participates in layout/hit testing. Capacity
/// preflight skips debug ink instead of rejecting otherwise valid app content.
/// Returns skipped debug rectangles; it never alters scene drop counters.
pub fn paintOverlay(frame: *const element.Frame, scene: *scene_mod.Scene, focused_id: u32, options: Overlay) u64 {
    if (!options.bounds and !options.hit_regions and !options.focus) return 0;
    var skipped: u64 = 0;
    for (frame.nodes[0..frame.node_count]) |node| {
        if (options.bounds) skipped += outline(scene, node.bounds, .{ .r = 0, .g = 0.7, .b = 1, .a = 0.7 }, 1);
    }
    for (frame.regions[0..frame.region_count]) |region| {
        if (options.hit_regions) skipped += outline(scene, region.bounds, .{ .r = 1, .g = 0.5, .b = 0, .a = 0.8 }, 1);
        if (options.focus) {
            if (region.focus) |focus| {
                if (focused_id != 0 and focused_id == focus.id)
                    skipped += outline(scene, region.bounds, .{ .r = 1, .g = 0, .b = 1, .a = 1 }, 2);
            }
        }
    }
    return skipped;
}

fn outline(scene: *scene_mod.Scene, rect: geometry.Rect, color: @import("../core/color.zig").Color, width: f32) u64 {
    if (!(rect.w > 0 and rect.h > 0)) return 0;
    if (scene.len == scene.quads.len or scene.command_len == scene.commands.len) return 1;
    _ = scene.push(.{ .x = rect.x, .y = rect.y, .w = rect.w, .h = rect.h, .color = color, .border_width = width });
    return 0;
}
