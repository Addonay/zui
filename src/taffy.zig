//! Port of GPUI `taffy.rs`: the layout engine, backed by zafi (a Taffy port).

const std = @import("std");
const zafi = @import("zafi");
const geometry = @import("geometry.zig");
const style_mod = @import("style.zig");
const Window = @import("window.zig").Window;
const App = @import("app.zig").App;

const Pixels = geometry.Pixels;
const Size = geometry.Size;
const Point = geometry.Point;
const Bounds = geometry.Bounds;
const Style = style_mod.Style;

/// Identifies a node in the layout tree.
pub const LayoutId = zafi.NodeId;

/// Available space along one axis.
pub const AvailableSpace = union(enum) {
    definite: Pixels,
    min_content,
    max_content,

    pub fn min_size() Size(AvailableSpace) {
        return .{ .width = .min_content, .height = .min_content };
    }
    pub fn from(v: anytype) AvailableSpace {
        return switch (@TypeOf(v)) {
            AvailableSpace => v,
            else => .{ .definite = @floatCast(v) },
        };
    }
    fn toZafi(self: AvailableSpace, scale: f32) zafi.AvailableSpace {
        return switch (self) {
            .definite => |p| .{ .definite = p * scale },
            .min_content => .min_content,
            .max_content => .max_content,
        };
    }
    fn fromZafi(v: zafi.AvailableSpace, scale: f32) AvailableSpace {
        return switch (v) {
            .definite => |p| .{ .definite = p / scale },
            .min_content => .min_content,
            .max_content => .max_content,
        };
    }
};

/// A measure callback for leaves whose size depends on content (text, images).
pub const MeasureFn = struct {
    ctx: *anyopaque,
    func: *const fn (ctx: *anyopaque, known: Size(?Pixels), available: Size(AvailableSpace), window: *Window, cx: *App) Size(Pixels),
};

/// GPUI `TaffyLayoutEngine`.
pub const TaffyLayoutEngine = struct {
    taffy: zafi.Tree,
    absolute_layout_bounds: std.AutoHashMapUnmanaged(LayoutId, Bounds(Pixels)) = .empty,
    absolute_outer_origins: std.AutoHashMapUnmanaged(LayoutId, Point(f32)) = .empty,
    computed_layouts: std.AutoHashMapUnmanaged(LayoutId, void) = .empty,
    measures: std.ArrayList(MeasureFn) = .empty,
    scratch: std.ArrayList(LayoutId) = .empty,
    /// Per-frame storage for converted grid tracks.
    frame_arena: std.heap.ArenaAllocator,
    allocator: std.mem.Allocator,

    // Set during compute_layout for the measure trampoline.
    cur_window: ?*Window = null,
    cur_app: ?*App = null,
    cur_scale: f32 = 1,

    pub fn new(allocator: std.mem.Allocator) TaffyLayoutEngine {
        var t = zafi.Tree.init(allocator);
        t.disable_rounding();
        return .{ .taffy = t, .allocator = allocator, .frame_arena = .init(allocator) };
    }

    pub fn deinit(self: *TaffyLayoutEngine) void {
        self.taffy.deinit();
        self.absolute_layout_bounds.deinit(self.allocator);
        self.absolute_outer_origins.deinit(self.allocator);
        self.computed_layouts.deinit(self.allocator);
        self.measures.deinit(self.allocator);
        self.scratch.deinit(self.allocator);
        self.frame_arena.deinit();
    }

    pub fn clear(self: *TaffyLayoutEngine) void {
        self.taffy.clear();
        self.absolute_layout_bounds.clearRetainingCapacity();
        self.absolute_outer_origins.clearRetainingCapacity();
        self.computed_layouts.clearRetainingCapacity();
        self.measures.clearRetainingCapacity();
        _ = self.frame_arena.reset(.retain_capacity);
    }

    pub fn request_layout(self: *TaffyLayoutEngine, style: *const Style, rem_size: Pixels, scale_factor: f32, children: []const LayoutId) LayoutId {
        const ts = to_taffy(style, rem_size, scale_factor, self.frame_arena.allocator());
        if (children.len == 0) return self.taffy.new_leaf(ts) catch oom();
        return self.taffy.new_with_children(ts, children) catch oom();
    }

    pub fn request_measured_layout(self: *TaffyLayoutEngine, style: *const Style, rem_size: Pixels, scale_factor: f32, measure: MeasureFn) LayoutId {
        const ts = to_taffy(style, rem_size, scale_factor, self.frame_arena.allocator());
        self.measures.append(self.allocator, measure) catch oom();
        // Context holds the 1-based index into `measures` (0 = none).
        const ctx: ?*anyopaque = @ptrFromInt(self.measures.items.len);
        return self.taffy.new_leaf_with_context(ts, ctx) catch oom();
    }

    /// Makes an auto-sized root fill `sz` (GPUI `stretch_auto_size_to_fill`).
    pub fn stretch_auto_size_to_fill(self: *TaffyLayoutEngine, id: LayoutId, sz: Size(Pixels), scale_factor: f32) void {
        var s = self.taffy.style_of(id) catch return;
        const sw = s.size.width.is_auto();
        const sh = s.size.height.is_auto();
        if (!sw and !sh) return;
        if (sw) s.size.width = .length(@round(sz.width * scale_factor));
        if (sh) s.size.height = .length(@round(sz.height * scale_factor));
        self.taffy.set_style(id, s) catch oom();
    }

    pub fn compute_layout(self: *TaffyLayoutEngine, id: LayoutId, available_space: Size(AvailableSpace), window: *Window, cx: *App) void {
        const gop = self.computed_layouts.getOrPut(self.allocator, id) catch oom();
        if (gop.found_existing) {
            self.scratch.clearRetainingCapacity();
            self.scratch.append(self.allocator, id) catch oom();
            while (self.scratch.pop()) |n| {
                _ = self.absolute_layout_bounds.remove(n);
                _ = self.absolute_outer_origins.remove(n);
                const kids = self.taffy.children(n) catch &.{};
                self.scratch.appendSlice(self.allocator, kids) catch oom();
            }
        }
        const scale = window.scale_factor();
        self.cur_window = window;
        self.cur_app = cx;
        self.cur_scale = scale;
        current_engine = self;
        defer current_engine = null;
        self.taffy.compute_layout_with_measure(id, .{
            .width = available_space.width.toZafi(scale),
            .height = available_space.height.toZafi(scale),
        }, measureTrampoline) catch oom();
    }

    threadlocal var current_engine: ?*TaffyLayoutEngine = null;

    fn measureTrampoline(context: ?*anyopaque, inputs: zafi.LayoutInput, node_id: zafi.NodeId, s: *const zafi.Style) zafi.LayoutOutput {
        _ = node_id;
        return zafi.compute_leaf_layout(inputs, s, context, sizeMeasure);
    }

    fn sizeMeasure(context: ?*anyopaque, known: zafi.Size(?f32), avail: zafi.Size(zafi.AvailableSpace)) zafi.Size(f32) {
        const self = current_engine orelse return .{ .width = 0, .height = 0 };
        const idx = @intFromPtr(context);
        if (idx == 0) return .{ .width = 0, .height = 0 };
        const m = self.measures.items[idx - 1];
        const scale = self.cur_scale;
        const kd: Size(?Pixels) = .{
            .width = if (known.width) |w| w / scale else null,
            .height = if (known.height) |h| h / scale else null,
        };
        const av: Size(AvailableSpace) = .{
            .width = AvailableSpace.fromZafi(avail.width, scale),
            .height = AvailableSpace.fromZafi(avail.height, scale),
        };
        const out = m.func(m.ctx, kd, av, self.cur_window.?, self.cur_app.?);
        // Snap measured content to device pixels (GPUI ceils to avoid clipping).
        return .{ .width = @ceil(out.width * scale), .height = @ceil(out.height * scale) };
    }

    pub fn layout_bounds(self: *TaffyLayoutEngine, id: LayoutId, scale_factor: f32) Bounds(Pixels) {
        if (self.absolute_layout_bounds.get(id)) |b| return b;
        const lay = self.taffy.layout_of(id) catch unreachable;
        const loc: Point(f32) = .{ .x = lay.location.x, .y = lay.location.y };
        const parent = self.taffy.parent(id) catch null;
        const origin: Point(f32) = if (parent) |p| blk: {
            _ = self.layout_bounds(p, scale_factor);
            const po = self.absolute_outer_origins.get(p).?;
            break :blk .{ .x = po.x + loc.x, .y = po.y + loc.y };
        } else loc;
        self.absolute_outer_origins.put(self.allocator, id, origin) catch oom();
        const far: Point(f32) = .{ .x = origin.x + lay.size.width, .y = origin.y + lay.size.height };
        const x0 = roundHalfTowardZero(origin.x) / scale_factor;
        const y0 = roundHalfTowardZero(origin.y) / scale_factor;
        const x1 = roundHalfTowardZero(far.x) / scale_factor;
        const y1 = roundHalfTowardZero(far.y) / scale_factor;
        const b: Bounds(Pixels) = .{ .origin = .{ .x = x0, .y = y0 }, .size = .{ .width = x1 - x0, .height = y1 - y0 } };
        self.absolute_layout_bounds.put(self.allocator, id, b) catch oom();
        return b;
    }
};

fn roundHalfTowardZero(v: f32) f32 {
    const r = @round(v);
    if (@abs(v - @trunc(v)) == 0.5) return @trunc(v);
    return r;
}

fn oom() noreturn {
    @panic("out of memory");
}

// ---------------------------------------------------------------------------
// Style -> zafi conversion (GPUI `ToTaffy`).

fn absPx(l: geometry.AbsoluteLength, rem: Pixels, scale: f32) f32 {
    return l.to_pixels(rem) * scale;
}

fn lpFromDefinite(l: geometry.DefiniteLength, rem: Pixels, scale: f32) zafi.LengthPercentage {
    return switch (l) {
        .absolute => |a| .length(absPx(a, rem, scale)),
        .fraction => |f| .percent(f),
    };
}

fn lpaFromLength(l: geometry.Length, rem: Pixels, scale: f32) zafi.LengthPercentageAuto {
    return switch (l) {
        .auto => .auto(),
        .definite => |d| switch (d) {
            .absolute => |a| .length(absPx(a, rem, scale)),
            .fraction => |f| .percent(f),
        },
    };
}

fn dimFromLength(l: geometry.Length, rem: Pixels, scale: f32) zafi.Dimension {
    return switch (l) {
        .auto => .auto,
        .definite => |d| switch (d) {
            .absolute => |a| .length(absPx(a, rem, scale)),
            .fraction => |f| .percent(f),
        },
    };
}

fn alignItems(a: style_mod.AlignItems) zafi.AlignItems {
    return switch (a) {
        .start => .START,
        .end => .END,
        .flex_start => .FLEX_START,
        .flex_end => .FLEX_END,
        .center => .CENTER,
        .baseline => .BASELINE,
        .stretch => .STRETCH,
    };
}

fn alignContent(a: style_mod.AlignContent) zafi.AlignContent {
    return switch (a) {
        .start => .START,
        .end => .END,
        .flex_start => .FLEX_START,
        .flex_end => .FLEX_END,
        .center => .CENTER,
        .stretch => .STRETCH,
        .space_between => .SPACE_BETWEEN,
        .space_evenly => .SPACE_EVENLY,
        .space_around => .SPACE_AROUND,
    };
}

fn gridTemplate(t: style_mod.GridTemplate, arena: std.mem.Allocator) []const zafi.GridTemplateComponent {
    const helpers = zafi.style_helpers;
    const min: zafi.MinTrackSizingFunction = switch (t.min_size) {
        .zero => .zero,
        .min_content => .min_content,
        .max_content => .max_content,
    };
    const track = arena.alloc(zafi.TrackSizingFunction, 1) catch oom();
    track[0] = helpers.minmax(min, .fr(1.0));
    const comps = arena.alloc(zafi.GridTemplateComponent, 1) catch oom();
    comps[0] = helpers.repeat(t.repeat, track);
    return comps;
}

fn gridPlacement(p: style_mod.GridPlacement) zafi.GridPlacement {
    return switch (p) {
        .line => |l| .from_line_index(l),
        .span => |s| .from_span(s),
        .auto => .auto,
    };
}

/// Converts a GPUI style into a zafi style, in device pixels.
pub fn to_taffy(s: *const Style, rem: Pixels, scale: f32, arena: std.mem.Allocator) zafi.Style {
    var t: zafi.Style = .{};
    t.display = switch (s.display) {
        .block => .block,
        .flex => .flex,
        .grid => .grid,
        .none => .none,
    };
    t.overflow = .{ .x = overflow(s.overflow.x), .y = overflow(s.overflow.y) };
    t.scrollbar_width = absPx(s.scrollbar_width, rem, scale);
    t.position = switch (s.position) {
        .relative => .relative,
        .absolute => .absolute,
    };
    t.inset = .{
        .top = lpaFromLength(s.inset.top, rem, scale),
        .right = lpaFromLength(s.inset.right, rem, scale),
        .bottom = lpaFromLength(s.inset.bottom, rem, scale),
        .left = lpaFromLength(s.inset.left, rem, scale),
    };
    t.size = .{ .width = dimFromLength(s.size.width, rem, scale), .height = dimFromLength(s.size.height, rem, scale) };
    t.min_size = .{ .width = lpaFromLength(s.min_size.width, rem, scale), .height = lpaFromLength(s.min_size.height, rem, scale) };
    t.max_size = .{ .width = lpaFromLength(s.max_size.width, rem, scale), .height = lpaFromLength(s.max_size.height, rem, scale) };
    t.aspect_ratio = s.aspect_ratio;
    t.margin = .{
        .top = lpaFromLength(s.margin.top, rem, scale),
        .right = lpaFromLength(s.margin.right, rem, scale),
        .bottom = lpaFromLength(s.margin.bottom, rem, scale),
        .left = lpaFromLength(s.margin.left, rem, scale),
    };
    t.padding = .{
        .top = lpFromDefinite(s.padding.top, rem, scale),
        .right = lpFromDefinite(s.padding.right, rem, scale),
        .bottom = lpFromDefinite(s.padding.bottom, rem, scale),
        .left = lpFromDefinite(s.padding.left, rem, scale),
    };
    t.border = .{
        .top = .length(absPx(s.border_widths.top, rem, scale)),
        .right = .length(absPx(s.border_widths.right, rem, scale)),
        .bottom = .length(absPx(s.border_widths.bottom, rem, scale)),
        .left = .length(absPx(s.border_widths.left, rem, scale)),
    };
    if (s.align_items) |a| t.align_items = alignItems(a);
    if (s.align_self) |a| t.align_self = alignItems(a);
    if (s.align_content) |a| t.align_content = alignContent(a);
    if (s.justify_content) |a| t.justify_content = alignContent(a);
    t.gap = .{ .width = lpFromDefinite(s.gap.width, rem, scale), .height = lpFromDefinite(s.gap.height, rem, scale) };
    t.flex_direction = switch (s.flex_direction) {
        .row => .row,
        .column => .column,
        .row_reverse => .row_reverse,
        .column_reverse => .column_reverse,
    };
    t.flex_wrap = switch (s.flex_wrap) {
        .no_wrap => .no_wrap,
        .wrap => .wrap,
        .wrap_reverse => .wrap_reverse,
    };
    t.flex_basis = dimFromLength(s.flex_basis, rem, scale);
    t.flex_grow = s.flex_grow;
    t.flex_shrink = s.flex_shrink;
    if (s.grid_cols) |g| t.grid_template_columns = gridTemplate(g, arena);
    if (s.grid_rows) |g| t.grid_template_rows = gridTemplate(g, arena);
    if (s.grid_location) |loc| {
        t.grid_row = .{ .start = gridPlacement(loc.row.start), .end = gridPlacement(loc.row.end) };
        t.grid_column = .{ .start = gridPlacement(loc.column.start), .end = gridPlacement(loc.column.end) };
    }
    return t;
}

fn overflow(o: style_mod.Overflow) zafi.Overflow {
    return switch (o) {
        .visible => .visible,
        .clip => .clip,
        .hidden => .hidden,
        .scroll => .scroll,
    };
}
