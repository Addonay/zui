const std = @import("std");
const builtin = @import("builtin");
const core = @import("../core/root.zig");
const platform = @import("../platform/root.zig");
const fonts = @import("../fonts/root.zig");
const images = @import("../images/root.zig");

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

pub const NodeKind = enum { container, text, spacer, image };

/// Object-fit behavior for image nodes (GPUI `ObjectFit` parity).
pub const ImageFit = enum { contain, cover, fill };

/// Image content source. Slices are borrowed (same contract as text_value):
/// static bytes, `@embedFile`, or a caller-owned path string.
pub const ImageSource = union(enum) {
    bytes: []const u8,
    path: []const u8,
    handle: images.Handle,
};

pub const ImageDesc = struct {
    source: ImageSource = .{ .bytes = &.{} },
    /// True for `svg()`: rasterize as vector at draw size with tint.
    /// False for `img()`: decode raster bytes (SVG bytes still accepted
    /// and rasterized at intrinsic size, GPUI `img()` parity).
    svg: bool = false,
    fit: ImageFit = .contain,
    gray: bool = false,
    /// Replaces `currentColor` in SVGs (GPUI icon tint); multiplies alpha
    /// into raster blits together with style opacity.
    tint: ?core.Color = null,
    /// Intrinsic pixel size resolved at build (probe/header, no full
    /// decode); zero when unknown so layout collapses the node.
    intrinsic_w: f32 = 0,
    intrinsic_h: f32 = 0,
};

pub const Node = struct {
    kind: NodeKind = .container,
    style: Style = .{},
    text_style: TextStyle = .{},
    text_value: []const u8 = "",
    image: ImageDesc = .{},
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

/// Transient per-frame element tree (~2.5MB inline). Lives in the heap
/// `Window` (`ui_frame`); tests may stack ONE Frame plus ONE `Scene` but
/// must heap-allocate the font `Collection` alongside them. See the
/// "hot frame structs stay within stack budget" test in painter.zig.
pub const Frame = struct {
    nodes: [max_nodes]Node = undefined,
    node_count: usize = 0,
    regions: [max_regions]HitRegion = undefined,
    region_count: usize = 0,
    text_storage: [text_storage_len]u8 = undefined,
    text_len: usize = 0,
    window: ?*anyopaque = null,
    pointer: core.Point = .{ .x = -10000, .y = -10000 },
    /// Borrowed font stack for shaped measure/paint. Null keeps the bitmap
    /// fallback (headless tests, machines without fontconfig). Set per frame
    /// from `Window.fonts`; never owned here.
    fonts: ?*fonts.Collection = null,
    /// Borrowed image cache for img()/svg() resolution. Null drops images.
    /// Set per frame from `Window.images`; never owned here.
    images: ?*images.Cache = null,
    /// Owning App's step counter at render; pins image-cache entries.
    frame_id: u64 = 0,
    /// Allocator for cold image work (file reads, decode dividends).
    /// Null drops path sources and uncached decodes.
    allocator: ?std.mem.Allocator = null,

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
    pub fn object_fit(self: Element, fit: ImageFit) Element {
        self.node().image.fit = fit;
        return self;
    }
    pub fn grayscale(self: Element) Element {
        self.node().image.gray = true;
        return self;
    }
    pub fn tint(self: Element, value: core.Color) Element {
        self.node().image.tint = value;
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

/// Resolve intrinsic pixel size without a full decode: raster headers via
/// probe, SVG via width/height (or nanosvg's viewBox fallback). Path
/// sources read through the frame allocator; anything missing yields 0x0
/// so layout collapses the node instead of guessing.
fn resolveIntrinsic(source: ImageSource, is_svg: bool, allocator: ?std.mem.Allocator) struct { w: f32, h: f32 } {
    switch (source) {
        .handle => |h| return .{ .w = @floatFromInt(h.w), .h = @floatFromInt(h.h) },
        .bytes => |bytes| {
            if (is_svg or images.sniff(bytes) == .svg) {
                const s = images.svg.intrinsicSize(bytes) catch return .{ .w = 0, .h = 0 };
                return .{ .w = s.w, .h = s.h };
            }
            const p = images.raster.probe(bytes) catch return .{ .w = 0, .h = 0 };
            return .{ .w = @floatFromInt(p.w), .h = @floatFromInt(p.h) };
        },
        .path => |path| {
            const alloc = allocator orelse return .{ .w = 0, .h = 0 };
            const bytes = readPath(alloc, path) catch return .{ .w = 0, .h = 0 };
            defer alloc.free(bytes);
            return resolveIntrinsic(.{ .bytes = bytes }, is_svg, null);
        },
    }
}

/// Read a whole file (cold path: dirty-frame builds only). Caller frees.
/// Plain libc I/O, same pattern as the snapshot writer in examples/todo.
pub fn readPath(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    if (!builtin.link_libc) return error.Unreadable;
    var path_buf: [4096]u8 = undefined;
    if (path.len == 0 or path.len >= path_buf.len) return error.BadPath;
    @memcpy(path_buf[0..path.len], path);
    path_buf[path.len] = 0;
    const name: [*:0]const u8 = path_buf[0..path.len :0];
    const f = std.c.fopen(name, "rb") orelse return error.Unreadable;
    defer _ = std.c.fclose(f);
    // Chunked read; a short fread ends input (regular files).
    var cap: usize = 8192;
    var out = allocator.alloc(u8, cap) catch return error.OutOfMemory;
    errdefer allocator.free(out);
    var len: usize = 0;
    while (true) {
        if (len == cap) {
            if (cap >= core.limits.MAX_IMAGE_POOL_BYTES) return error.Unreadable;
            cap = @min(cap * 2, core.limits.MAX_IMAGE_POOL_BYTES);
            out = allocator.realloc(out, cap) catch return error.OutOfMemory;
        }
        const n = std.c.fread(out.ptr + len, 1, cap - len, f);
        len += n;
        if (n == 0) break;
    }
    if (!allocator.resize(out, len)) {
        const exact = allocator.alloc(u8, len) catch return error.OutOfMemory;
        @memcpy(exact, out[0..len]);
        allocator.free(out);
        return exact;
    }
    return out[0..len];
}

/// Image element from raw bytes (PNG/JPEG/GIF/BMP, or SVG which rasterizes
/// at intrinsic size — GPUI `img()` parity).
pub fn img(source: []const u8) Element {
    return makeImage(.{ .bytes = source }, false);
}

/// Image element from a file path (read at build on dirty frames).
pub fn imgPath(path: []const u8) Element {
    return makeImage(.{ .path = path }, false);
}

/// Image element from a decoded cache handle.
pub fn imgHandle(handle: images.Handle) Element {
    return makeImage(.{ .handle = handle }, false);
}

/// SVG element from raw bytes, tinted through `currentColor` (GPUI icon
/// parity: `.tint(text_color)` recolors lucide-style stroke icons).
pub fn svg(source: []const u8) Element {
    return makeImage(.{ .bytes = source }, true);
}

/// SVG element from a file path.
pub fn svgPath(path: []const u8) Element {
    return makeImage(.{ .path = path }, true);
}

fn makeImage(source: ImageSource, is_svg: bool) Element {
    const frame = currentFrame();
    const result = Element{ .index = frame.createNode(.image) };
    const n = result.node();
    n.image.source = source;
    n.image.svg = is_svg;
    const size = resolveIntrinsic(source, is_svg, frame.allocator);
    n.image.intrinsic_w = size.w;
    n.image.intrinsic_h = size.h;
    return result;
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

pub fn textAdvance(size: f32, tracking: f32, weight: FontWeight) f32 {
    // Single source of truth for horizontal text metrics. The painter draws
    // each glyph cell as scale*6 wide (scale = size/8, min 1px) plus tracking,
    // with bold/semibold widening pixels by ~30% of scale. Layout measure and
    // the TextField cursor must use this exact function or text overflows or
    // gaps (the old measure used size*0.64 vs the painter's size*0.75).
    const scale = @max(1.0, size / 8.0);
    const bold_extra = if (weight == .bold or weight == .semibold) scale * 0.3 else 0;
    return scale * 6.0 + tracking + bold_extra;
}

pub fn progressTrack(value: f32) Element {
    // Flex-proportioned fill: the old fixed 520px child overflowed windows
    // narrower than the design 560px column. Fill flexes with `fraction`,
    // spacer takes the rest, so the track always fits its parent.
    const fraction = std.math.clamp(value, 0, 1);
    var track = div().w_full().h(4).flex_row().rounded_full().bg(core.Color.hex(0xffffff10));
    if (fraction > 0.0001) {
        var fill = div().h(4).rounded_full().bg_gradient(core.Color.hex(0x7c5cff), core.Color.hex(0x46d5e8));
        fill.node().style.flex_grow = @max(0.0001, fraction);
        track = track.child(fill);
    }
    if (fraction < 0.9999) {
        var rest = spacer();
        rest.node().style.flex_grow = @max(0.0001, 1 - fraction);
        track = track.child(rest);
    }
    return track;
}

pub fn formatToday() []const u8 {
    return "TODAY";
}
