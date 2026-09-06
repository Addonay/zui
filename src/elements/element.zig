const std = @import("std");
const core = @import("../core/root.zig");
const platform = @import("../platform/root.zig");

pub const max_nodes = core.limits.MAX_LAYOUT_ELEMENTS;
pub const max_regions = 512;
pub const text_storage_len = 64 * 1024;

pub const FontWeight = enum { normal, medium, semibold, bold };
pub const Direction = enum { row, column };
pub const Align = enum { start, center };
pub const Justify = enum { start, center, between };

pub const ListenerPayload = extern union {
    bytes: [16]u8,
    alignment: u128,
};

pub const Listener = struct {
    target: *anyopaque,
    payload: ListenerPayload = .{ .bytes = @splat(0) },
    call_fn: *const fn (*anyopaque, *const ListenerPayload, *anyopaque) void,

    pub fn call(self: Listener, window: *anyopaque) void {
        self.call_fn(self.target, &self.payload, window);
    }
};

pub const FocusHandle = struct {
    id: u32 = 0,
    target: ?*anyopaque = null,
    event_fn: ?*const fn (*anyopaque, platform.Event, *anyopaque) bool = null,

    pub fn eql(self: FocusHandle, other: FocusHandle) bool {
        return self.id == other.id;
    }

    pub fn dispatch(self: FocusHandle, event: platform.Event, window: *anyopaque) bool {
        const callback = self.event_fn orelse return false;
        return callback(self.target orelse return false, event, window);
    }
};

pub const HitRegion = struct {
    bounds: core.Rect,
    listener: ?Listener = null,
    mouse_down_listener: ?Listener = null,
    double_click_listener: ?Listener = null,
    focus: ?FocusHandle = null,
};

pub const EdgeValues = struct {
    top: f32 = 0,
    right: f32 = 0,
    bottom: f32 = 0,
    left: f32 = 0,

    pub fn all(value: f32) EdgeValues {
        return .{ .top = value, .right = value, .bottom = value, .left = value };
    }
};

pub const Style = struct {
    direction: Direction = .column,
    alignment: Align = .start,
    justify: Justify = .start,
    gap: f32 = 0,
    width: ?f32 = null,
    height: ?f32 = null,
    square: ?f32 = null,
    full_width: bool = false,
    full_height: bool = false,
    max_width_full: bool = false,
    flex_grow: f32 = 0,
    padding: EdgeValues = .{},
    absolute: bool = false,
    inset_value: ?f32 = null,
    top: ?f32 = null,
    right: ?f32 = null,
    left: ?f32 = null,
    background: ?core.Color = null,
    gradient_to: ?core.Color = null,
    hover_background: ?core.Color = null,
    border_color: ?core.Color = null,
    hover_border: ?core.Color = null,
    border_width: f32 = 0,
    border_bottom_only: bool = false,
    dashed_border: bool = false,
    radius: f32 = 0,
    opacity: f32 = 1,
    blur: f32 = 0,
    shadow: bool = false,
    text_color: ?core.Color = null,
    pointer: bool = false,
};

pub const TextStyle = struct {
    size: f32 = 14,
    line_height: ?f32 = null,
    tracking: f32 = 0,
    font: []const u8 = "",
    weight: FontWeight = .normal,
    color: ?core.Color = null,
    strike: bool = false,
};

pub const NodeKind = enum { container, text, spacer };

pub const Node = struct {
    kind: NodeKind = .container,
    style: Style = .{},
    text_style: TextStyle = .{},
    text_value: []const u8 = "",
    first_child: ?u16 = null,
    last_child: ?u16 = null,
    next_sibling: ?u16 = null,
    bounds: core.Rect = .{},
    measured: core.Size = .{},
    listener: ?Listener = null,
    mouse_down_listener: ?Listener = null,
    double_click_listener: ?Listener = null,
    focus: ?FocusHandle = null,
};

pub const Frame = struct {
    nodes: [max_nodes]Node = undefined,
    node_count: usize = 0,
    regions: [max_regions]HitRegion = undefined,
    region_count: usize = 0,
    text_storage: [text_storage_len]u8 = undefined,
    text_len: usize = 0,
    window: ?*anyopaque = null,
    pointer: core.Point = .{ .x = -10000, .y = -10000 },

    pub fn reset(self: *Frame, window: *anyopaque, pointer: core.Point) void {
        self.node_count = 0;
        self.region_count = 0;
        self.text_len = 0;
        self.window = window;
        self.pointer = pointer;
    }

    fn createNode(self: *Frame, kind: NodeKind) u16 {
        if (self.node_count >= self.nodes.len) @panic("ZUI element limit exceeded");
        const index: u16 = @intCast(self.node_count);
        self.node_count += 1;
        self.nodes[index] = .{ .kind = kind };
        return index;
    }

    pub fn copyText(self: *Frame, value: []const u8) []const u8 {
        if (self.text_len + value.len > self.text_storage.len) @panic("ZUI frame text storage exceeded");
        const out = self.text_storage[self.text_len..][0..value.len];
        @memcpy(out, value);
        self.text_len += value.len;
        return out;
    }

    pub fn addRegion(self: *Frame, region: HitRegion) void {
        if (self.region_count >= self.regions.len) return;
        self.regions[self.region_count] = region;
        self.region_count += 1;
    }
};

threadlocal var active_frame: ?*Frame = null;

pub fn beginFrame(frame: *Frame) void {
    std.debug.assert(active_frame == null);
    active_frame = frame;
}

pub fn endFrame() void {
    active_frame = null;
}

pub fn currentFrame() *Frame {
    return active_frame orelse @panic("ZUI elements must be built during render");
}

pub fn currentWindow() *anyopaque {
    return currentFrame().window orelse @panic("ZUI render frame has no window");
}

pub const Element = struct {
    index: u16,

    fn node(self: Element) *Node {
        return &currentFrame().nodes[self.index];
    }

    pub fn flex_row(self: Element) Element {
        self.node().style.direction = .row;
        return self;
    }
    pub fn flex_col(self: Element) Element {
        self.node().style.direction = .column;
        return self;
    }
    pub fn flex_1(self: Element) Element {
        self.node().style.flex_grow = 1;
        return self;
    }
    pub fn items_center(self: Element) Element {
        self.node().style.alignment = .center;
        return self;
    }
    pub fn justify_center(self: Element) Element {
        self.node().style.justify = .center;
        return self;
    }
    pub fn justify_between(self: Element) Element {
        self.node().style.justify = .between;
        return self;
    }
    pub fn gap(self: Element, value: f32) Element {
        self.node().style.gap = value;
        return self;
    }
    pub fn w(self: Element, value: f32) Element {
        self.node().style.width = value;
        return self;
    }
    pub fn h(self: Element, value: f32) Element {
        self.node().style.height = value;
        return self;
    }
    pub fn w_full(self: Element) Element {
        self.node().style.full_width = true;
        return self;
    }
    pub fn size(self: Element, value: f32) Element {
        self.node().style.square = value;
        return self;
    }
    pub fn size_full(self: Element) Element {
        self.node().style.full_width = true;
        self.node().style.full_height = true;
        return self;
    }
    pub fn max_w_full(self: Element) Element {
        self.node().style.max_width_full = true;
        return self;
    }
    pub fn p(self: Element, value: f32) Element {
        self.node().style.padding = EdgeValues.all(value);
        return self;
    }
    pub fn px(self: Element, value: f32) Element {
        self.node().style.padding.left = value;
        self.node().style.padding.right = value;
        return self;
    }
    pub fn py(self: Element, value: f32) Element {
        self.node().style.padding.top = value;
        self.node().style.padding.bottom = value;
        return self;
    }
    pub fn pl(self: Element, value: f32) Element {
        self.node().style.padding.left = value;
        return self;
    }
    pub fn pr(self: Element, value: f32) Element {
        self.node().style.padding.right = value;
        return self;
    }
    pub fn pt(self: Element, value: f32) Element {
        self.node().style.padding.top = value;
        return self;
    }
    pub fn absolute(self: Element) Element {
        self.node().style.absolute = true;
        return self;
    }
    pub fn inset(self: Element, value: f32) Element {
        self.node().style.inset_value = value;
        return self;
    }
    pub fn top(self: Element, value: f32) Element {
        self.node().style.top = value;
        return self;
    }
    pub fn right(self: Element, value: f32) Element {
        self.node().style.right = value;
        return self;
    }
    pub fn left(self: Element, value: f32) Element {
        self.node().style.left = value;
        return self;
    }
    pub fn bg(self: Element, value: core.Color) Element {
        self.node().style.background = value;
        return self;
    }
    pub fn bg_gradient(self: Element, from: core.Color, to: core.Color) Element {
        self.node().style.background = from;
        self.node().style.gradient_to = to;
        return self;
    }
    pub fn opacity(self: Element, value: f32) Element {
        self.node().style.opacity = std.math.clamp(value, 0, 1);
        return self;
    }
    pub fn blur(self: Element, value: f32) Element {
        self.node().style.blur = value;
        return self;
    }
    pub fn rounded_lg(self: Element) Element {
        self.node().style.radius = 8;
        return self;
    }
    pub fn rounded_xl(self: Element) Element {
        self.node().style.radius = 12;
        return self;
    }
    pub fn rounded_2xl(self: Element) Element {
        self.node().style.radius = 16;
        return self;
    }
    pub fn rounded_full(self: Element) Element {
        self.node().style.radius = 999;
        return self;
    }
    pub fn border_1(self: Element) Element {
        self.node().style.border_width = 1;
        return self;
    }
    pub fn border_2(self: Element) Element {
        self.node().style.border_width = 2;
        return self;
    }
    pub fn border_b_1(self: Element) Element {
        self.node().style.border_width = 1;
        self.node().style.border_bottom_only = true;
        return self;
    }
    pub fn border_dashed(self: Element) Element {
        self.node().style.dashed_border = true;
        return self;
    }
    pub fn border_color(self: Element, value: core.Color) Element {
        self.node().style.border_color = value;
        return self;
    }
    pub fn shadow_lg(self: Element) Element {
        self.node().style.shadow = true;
        return self;
    }
    pub fn text_color(self: Element, value: core.Color) Element {
        self.node().style.text_color = value;
        return self;
    }
    pub fn cursor_pointer(self: Element) Element {
        self.node().style.pointer = true;
        return self;
    }
    pub fn hover_bg(self: Element, value: core.Color) Element {
        self.node().style.hover_background = value;
        return self;
    }
    pub fn hover_border(self: Element, value: core.Color) Element {
        self.node().style.hover_border = value;
        return self;
    }
    pub fn on_click(self: Element, listener: Listener) Element {
        self.node().listener = listener;
        return self;
    }
    pub fn on_mouse_down(self: Element, listener: Listener) Element {
        self.node().mouse_down_listener = listener;
        return self;
    }
    pub fn on_double_click(self: Element, listener: Listener) Element {
        self.node().double_click_listener = listener;
        return self;
    }

    pub fn withFocus(self: Element, focus: FocusHandle) Element {
        self.node().focus = focus;
        return self;
    }

    pub fn child(self: Element, value: anytype) Element {
        const T = @TypeOf(value);
        const child_element: Element = if (T == Element)
            value
        else if (@typeInfo(T) == .optional)
            if (value) |present| present else return self
        else if (@hasDecl(T, "toElement"))
            value.toElement()
        else
            @compileError("unsupported ZUI child type: " ++ @typeName(T));

        const parent = self.node();
        const child_node = &currentFrame().nodes[child_element.index];
        child_node.next_sibling = null;
        if (parent.last_child) |last| {
            currentFrame().nodes[last].next_sibling = child_element.index;
        } else {
            parent.first_child = child_element.index;
        }
        parent.last_child = child_element.index;
        return self;
    }

    pub fn children(self: Element, values: anytype, owner: anytype, render_fn: anytype, cx: anytype) Element {
        _ = owner;
        var result = self;
        for (values) |value| {
            if (render_fn(cx.current.?.value, value, cx)) |rendered| {
                result = result.child(rendered);
            }
        }
        return result;
    }
};

pub fn div() Element {
    const frame = currentFrame();
    return .{ .index = frame.createNode(.container) };
}

pub fn spacer() Element {
    const frame = currentFrame();
    const result = Element{ .index = frame.createNode(.spacer) };
    return result.flex_1();
}

pub fn text(value: []const u8, options: anytype) Element {
    const frame = currentFrame();
    const result = Element{ .index = frame.createNode(.text) };
    const n = result.node();
    n.text_value = value;
    const T = @TypeOf(options);
    if (@hasField(T, "size")) n.text_style.size = options.size;
    if (@hasField(T, "line_height")) n.text_style.line_height = options.line_height;
    if (@hasField(T, "tracking")) n.text_style.tracking = options.tracking;
    if (@hasField(T, "font")) n.text_style.font = options.font;
    if (@hasField(T, "weight")) n.text_style.weight = options.weight;
    if (@hasField(T, "color")) n.text_style.color = options.color;
    if (@hasField(T, "strike")) n.text_style.strike = options.strike;
    return result;
}

pub fn textFmt(comptime format: []const u8, args: anytype, options: anytype) Element {
    const frame = currentFrame();
    var buffer: [256]u8 = undefined;
    const formatted = std.fmt.bufPrint(&buffer, format, args) catch "text too long";
    return text(frame.copyText(formatted), options);
}

pub fn when(condition: bool, value: Element) Element {
    if (condition) return value;
    return div().size(0);
}

pub fn progressBar(value: f32, width: f32) Element {
    const fraction = std.math.clamp(value, 0, 1);
    return div().w(width).h(6).rounded_full().bg(core.Color.hex(0xffffff14))
        .child(div().w(width * fraction).h(6).rounded_full().bg_gradient(core.Color.hex(0x7c5cff), core.Color.hex(0x46d5e8)));
}

pub fn progressTrack(value: f32) Element {
    const fraction = std.math.clamp(value, 0, 1);
    return div().size_full().h(4).rounded_full().bg(core.Color.hex(0xffffff10))
        .child(div().w(520 * fraction).h(4).rounded_full().bg_gradient(core.Color.hex(0x7c5cff), core.Color.hex(0x46d5e8)));
}

pub fn formatToday() []const u8 {
    return "TODAY";
}
