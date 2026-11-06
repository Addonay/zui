//! Port of GPUI `elements/uniform_list.rs`: a lazily rendered list of items that all have the
//! height of the first item. Only the visible range is rendered, so the list scales to millions of rows.

const std = @import("std");
const geometry = @import("../geometry.zig");
const style_mod = @import("../style.zig");
const styled_mod = @import("../styled.zig");
const color_mod = @import("../color.zig");
const element_mod = @import("../element.zig");
const window_mod = @import("../window.zig");
const app_mod = @import("../app.zig");
const taffy = @import("../taffy.zig");
const interactive = @import("../interactive.zig");
const div = @import("div.zig");
const list_mod = @import("list.zig");

const App = app_mod.App;
const Window = window_mod.Window;
const Pixels = geometry.Pixels;
const Point = geometry.Point;
const Size = geometry.Size;
const Bounds = geometry.Bounds;
const point = geometry.point;
const size = geometry.size;
const Style = style_mod.Style;
const StyleRefinement = style_mod.StyleRefinement;
const AnyElement = element_mod.AnyElement;
const ElementId = element_mod.ElementId;
const GlobalElementId = element_mod.GlobalElementId;
const LayoutId = taffy.LayoutId;
const AvailableSpace = taffy.AvailableSpace;
const Hitbox = window_mod.Hitbox;
const DispatchPhase = window_mod.DispatchPhase;
const Interactivity = div.Interactivity;
const InteractiveElementState = div.InteractiveElementState;
const ScrollHandle = div.ScrollHandle;
const ScrollWheelEvent = interactive.ScrollWheelEvent;
const ListSizingBehavior = list_mod.ListSizingBehavior;
const ListHorizontalSizingBehavior = list_mod.ListHorizontalSizingBehavior;

fn oom() noreturn {
    @panic("out of memory");
}

/// A half-open range of item indices (GPUI `Range<usize>`).
pub const Range = struct {
    start: usize = 0,
    end: usize = 0,

    pub fn len(self: Range) usize {
        return self.end - self.start;
    }
};

/// Renders the items of a visible range into the frame arena (GPUI `render_items`).
/// Build one with `Context(T).processor`.
pub const RangeRenderer = struct {
    ctx: *anyopaque,
    func: *const fn (ctx: *anyopaque, range: Range, window: *Window, cx: *App) []AnyElement,

    pub fn call(self: RangeRenderer, range: Range, window: *Window, cx: *App) []AnyElement {
        return self.func(self.ctx, range, window, cx);
    }
};

/// Draws extra elements over a uniform list, such as indent guides (GPUI `UniformListDecoration`).
pub const UniformListDecoration = struct {
    ctx: *anyopaque,
    func: *const fn (ctx: *anyopaque, visible_range: Range, bounds: Bounds(Pixels), scroll_offset: Point(Pixels), item_height: Pixels, item_count: usize, window: *Window, cx: *App) AnyElement,

    pub fn compute(self: UniformListDecoration, visible_range: Range, bounds: Bounds(Pixels), scroll_offset: Point(Pixels), item_height: Pixels, item_count: usize, window: *Window, cx: *App) AnyElement {
        return self.func(self.ctx, visible_range, bounds, scroll_offset, item_height, item_count, window, cx);
    }
};

/// Where to place the element scrolled to.
pub const ScrollStrategy = enum {
    /// Place the element at the top of the list's viewport.
    top,
    /// Place the element in the middle of the viewport, as far as the list allows.
    center,
    /// Place the element at the bottom of the viewport, as far as the list allows.
    bottom,
    /// Scroll the minimum amount to make the element visible.
    nearest,
};

pub const DeferredScrollToItem = struct {
    item_index: usize,
    strategy: ScrollStrategy,
    /// The offset in number of items.
    offset: usize = 0,
    scroll_strict: bool = false,
};

/// The size of an item and of its contents.
pub const ItemSize = struct {
    /// The size of the item.
    item: Size(Pixels) = .{},
    /// The size of the contents, which may be larger than the item when bounded by a parent.
    contents: Size(Pixels) = .{},
};

pub const UniformListScrollState = struct {
    base_handle: ScrollHandle,
    deferred_scroll_to_item: ?DeferredScrollToItem = null,
    /// Size of the item, captured during last layout.
    last_item_size: ?ItemSize = null,
    /// The height of one item, from the last layout.
    item_height: Pixels = 0,
    /// Whether the list was vertically flipped during last layout.
    y_flipped: bool = false,
};

/// A handle for controlling the scroll position of a uniform list. Store it in your view
/// and pass it to `track_scroll` on each frame.
pub const UniformListScrollHandle = struct {
    state: *UniformListScrollState,

    pub fn new() UniformListScrollHandle {
        const allocator = std.heap.page_allocator;
        const s = allocator.create(UniformListScrollState) catch oom();
        s.* = .{ .base_handle = ScrollHandle.new(allocator) };
        return .{ .state = s };
    }

    /// Scrolls so the item is visible; no scrolling happens if it already is.
    pub fn scroll_to_item(self: UniformListScrollHandle, ix: usize, strategy: ScrollStrategy) void {
        self.state.deferred_scroll_to_item = .{ .item_index = ix, .strategy = strategy };
    }

    /// Scrolls so the item sits at `strategy`'s position, even if it is already visible.
    pub fn scroll_to_item_strict(self: UniformListScrollHandle, ix: usize, strategy: ScrollStrategy) void {
        self.state.deferred_scroll_to_item = .{ .item_index = ix, .strategy = strategy, .scroll_strict = true };
    }

    /// Like `scroll_to_item`, but the viewport shrinks by `offset` items from the strategy's edge.
    pub fn scroll_to_item_with_offset(self: UniformListScrollHandle, ix: usize, strategy: ScrollStrategy, offset: usize) void {
        self.state.deferred_scroll_to_item = .{ .item_index = ix, .strategy = strategy, .offset = offset };
    }

    /// Like `scroll_to_item_strict`, with the viewport shrunk by `offset` items.
    pub fn scroll_to_item_strict_with_offset(self: UniformListScrollHandle, ix: usize, strategy: ScrollStrategy, offset: usize) void {
        self.state.deferred_scroll_to_item = .{ .item_index = ix, .strategy = strategy, .offset = offset, .scroll_strict = true };
    }

    /// Whether the list is flipped vertically.
    pub fn y_flipped(self: UniformListScrollHandle) bool {
        return self.state.y_flipped;
    }

    /// Whether the contents are taller than the list.
    pub fn is_scrollable(self: UniformListScrollHandle) bool {
        const size_ = self.state.last_item_size orelse return false;
        return size_.contents.height > size_.item.height;
    }

    /// Whether the list is scrolled to its end, or null if it is not scrollable.
    pub fn is_scrolled_to_end(self: UniformListScrollHandle) ?bool {
        const base = self.state.base_handle;
        const max_offset = base.max_offset();
        if (max_offset.height <= 0) return null;
        return -base.offset().y >= max_offset.height;
    }

    pub fn scroll_to_bottom(self: UniformListScrollHandle) void {
        self.scroll_to_item(std.math.maxInt(usize), .bottom);
    }

    /// The item at the top of the list, or the item a pending scroll is going to (GPUI
    /// `logical_scroll_top_index`, which is test-only there). GPUI reads this from the child bounds of
    /// the visible items; items here are uniform, so the offset and the item height give the same index.
    pub fn logical_scroll_top_index(self: UniformListScrollHandle) usize {
        if (self.state.deferred_scroll_to_item) |deferred| return deferred.item_index;
        const item_height = self.state.item_height;
        if (item_height <= 0) return 0;
        const offset = self.state.base_handle.offset();
        const index = @floor(-offset.y / item_height);
        return if (index <= 0) 0 else @intFromFloat(index);
    }
};

/// Saturating float-to-index conversion, matching Rust's `as usize` (NaN and negatives map to 0).
fn saturating_index(f: f64) usize {
    if (std.math.isNan(f) or f <= 0) return 0;
    if (f >= 18446744073709551615.0) return std.math.maxInt(usize);
    return @intFromFloat(f);
}

/// A list element for efficiently laying out and displaying a list of uniform-height elements.
pub const UniformList = struct {
    const Self = @This();

    item_count: usize,
    item_to_measure_index: usize = 0,
    render_items: RangeRenderer,
    decorations: std.ArrayList(UniformListDecoration) = .empty,
    interactivity: Interactivity = .{},
    scroll_handle: ?UniformListScrollHandle = null,
    sizing_behavior: ListSizingBehavior = .auto,
    horizontal_sizing_behavior: ListHorizontalSizingBehavior = .fit_list,

    pub const RequestLayoutState = struct {
        items: std.ArrayList(AnyElement) = .empty,
        decorations: std.ArrayList(AnyElement) = .empty,
    };

    pub const PrepaintState = struct {
        hitbox: ?Hitbox = null,
        style: Style = .{},
        state: ?*InteractiveElementState = null,
        scroll_offset: Point(Pixels) = .{},
        max_scroll: Size(Pixels) = .{},
    };

    const StyledM = styled_mod.Styled(*Self);

    pub fn style(self: *Self) *StyleRefinement {
        return &self.interactivity.base_style;
    }

    pub fn element_id(self: *Self) ?ElementId {
        return self.interactivity.element_id;
    }

    pub fn into_any_element(self: *Self) AnyElement {
        return AnyElement.new(self);
    }

    /// Selects the item whose width is used to lay out the list; defaults to item 0.
    pub fn with_width_from_item(self: *Self, item_index: ?usize) *Self {
        self.item_to_measure_index = item_index orelse 0;
        return self;
    }

    /// Sets the sizing behavior, similar to the `List` element.
    pub fn with_sizing_behavior(self: *Self, behavior: ListSizingBehavior) *Self {
        self.sizing_behavior = behavior;
        return self;
    }

    /// Sets how items are laid out horizontally. `unconstrained` lets items overflow the list
    /// width and scrolls horizontally.
    pub fn with_horizontal_sizing_behavior(self: *Self, behavior: ListHorizontalSizingBehavior) *Self {
        self.horizontal_sizing_behavior = behavior;
        switch (behavior) {
            .fit_list => self.interactivity.base_style.overflow.x = null,
            .unconstrained => self.interactivity.base_style.overflow.x = .scroll,
        }
        return self;
    }

    /// Adds a decoration drawn over the list.
    pub fn with_decoration(self: *Self, decoration: UniformListDecoration) *Self {
        self.decorations.append(window_mod.frame_arena(), decoration) catch oom();
        return self;
    }

    /// Tracks the scroll position in `handle`.
    pub fn track_scroll(self: *Self, handle: *const UniformListScrollHandle) *Self {
        self.interactivity.tracked_scroll_handle = handle.state.base_handle;
        self.scroll_handle = handle.*;
        return self;
    }

    /// Sets whether the list is flipped vertically, so item 0 appears at the bottom.
    pub fn y_flipped(self: *Self, flipped: bool) *Self {
        const handle = self.scroll_handle orelse return self;
        const state = handle.state;
        const base = state.base_handle;
        const offset = base.offset();
        if (state.last_item_size) |last| {
            if (state.y_flipped != flipped) {
                base.set_offset(point(offset.x, -(offset.y + last.contents.height - last.item.height)));
                state.y_flipped = flipped;
            }
        } else if (flipped) {
            base.set_offset(point(offset.x, -std.math.floatMax(Pixels)));
            state.y_flipped = flipped;
        }
        return self;
    }

    /// Adds a scroll wheel listener on the list.
    pub fn on_scroll_wheel(self: *Self, listener: anytype) *Self {
        self.interactivity.scroll_wheel_listeners.append(window_mod.frame_arena(), app_mod.to_listener(ScrollWheelEvent, listener)) catch oom();
        return self;
    }

    /// Assigns the element id (GPUI `.id()`), needed for state that persists across frames.
    pub fn id(self: *Self, eid: anytype) *Self {
        self.interactivity.element_id = ElementId.from(eid);
        return self;
    }

    fn measure_item(self: *const Self, list_width: ?Pixels, window: *Window, cx: *App) Size(Pixels) {
        if (self.item_count == 0) return .{};
        const item_ix = @min(self.item_to_measure_index, self.item_count - 1);
        const items = self.render_items.call(.{ .start = item_ix, .end = item_ix + 1 }, window, cx);
        if (items.len == 0) return .{};
        const available: Size(AvailableSpace) = .{
            .width = if (list_width) |width| .{ .definite = width } else .max_content,
            .height = .min_content,
        };
        return items[items.len - 1].layout_as_root(available, window, cx);
    }

    pub fn request_layout(self: *Self, gid: ?*const GlobalElementId, window: *Window, cx: *App) struct { LayoutId, RequestLayoutState } {
        _ = gid;
        const item_size = self.measure_item(null, window, cx);
        var style_: Style = .{};
        style_.refine(&self.interactivity.base_style);
        const has_text = style_.text_style() != null;
        if (has_text) window.push_text_style(style_.text);
        defer if (has_text) window.pop_text_style();

        const layout_id = switch (self.sizing_behavior) {
            .infer => blk: {
                const measured = window_mod.frame_arena().create(MeasuredSize) catch oom();
                measured.* = .{ .item = item_size, .item_count = self.item_count };
                break :blk window.request_measured_layout(&style_, .{ .ctx = measured, .func = MeasuredSize.measure });
            },
            .auto => window.request_layout(&style_, &.{}, cx),
        };
        return .{ layout_id, .{} };
    }

    /// The item-based measurement used by `ListSizingBehavior.infer`.
    const MeasuredSize = struct {
        item: Size(Pixels),
        item_count: usize,

        fn measure(ctx: *anyopaque, known: Size(?Pixels), available: Size(AvailableSpace), _: *Window, _: *App) Size(Pixels) {
            const measured_size: *const MeasuredSize = @ptrCast(@alignCast(ctx));
            const desired_height = measured_size.item.height * @as(f32, @floatFromInt(measured_size.item_count));
            const width = known.width orelse switch (available.width) {
                .definite => |avail_w| avail_w,
                .min_content, .max_content => measured_size.item.width,
            };
            const height = switch (available.height) {
                .definite => |avail_h| @min(desired_height, avail_h),
                .min_content, .max_content => desired_height,
            };
            return .{ .width = width, .height = height };
        }
    };

    pub fn prepaint(self: *Self, gid: ?*const GlobalElementId, bounds: Bounds(Pixels), rl: *RequestLayoutState, window: *Window, cx: *App) PrepaintState {
        var pp: PrepaintState = .{};
        if (gid) |g| pp.state = window.element_state(InteractiveElementState, g.*, .{});

        const hitbox = window.insert_hitbox(bounds, .normal);
        pp.hitbox = hitbox;
        pp.style = self.interactivity.compute_style(&hitbox, pp.state, window, cx);
        const style_ = &pp.style;

        const rem = window.rem_size();
        const border_px = style_.border_widths.to_pixels(.{rem});
        const padding = style_.padding.to_pixels(.{
            Size(geometry.AbsoluteLength){ .width = .{ .pixels = bounds.size.width }, .height = .{ .pixels = bounds.size.height } },
            rem,
        });

        const padded_bounds = Bounds(Pixels).from_corners(
            bounds.origin.add(point(border_px.left + padding.left, border_px.top + padding.top)),
            bounds.bottom_right().sub(point(border_px.right + padding.right, border_px.bottom + padding.bottom)),
        );

        const can_scroll_horizontally = self.horizontal_sizing_behavior == .unconstrained;
        const longest_item_size = self.measure_item(null, window, cx);
        const content_width = if (can_scroll_horizontally) @max(padded_bounds.size.width, longest_item_size.width) else padded_bounds.size.width;
        const content_size: Size(Pixels) = .{
            .width = content_width,
            .height = longest_item_size.height * @as(f32, @floatFromInt(self.item_count)),
        };

        var shared_scroll_to_item: ?DeferredScrollToItem = null;
        if (self.scroll_handle) |handle| {
            handle.state.last_item_size = .{ .item = padded_bounds.size, .contents = content_size };
            handle.state.item_height = longest_item_size.height;
            shared_scroll_to_item = handle.state.deferred_scroll_to_item;
            handle.state.deferred_scroll_to_item = null;
        }

        var scroll_offset: Point(Pixels) = if (self.interactivity.tracked_scroll_handle) |sh|
            sh.offset()
        else if (pp.state) |st|
            st.scroll_offset
        else
            .{};

        const is_flipped = if (self.scroll_handle) |handle| handle.state.y_flipped else false;
        const item_height = longest_item_size.height;
        const item_count_f: f32 = @floatFromInt(self.item_count);

        if (self.item_count > 0) {
            const content_height = item_height * item_count_f;

            const is_scrolled_vertically = scroll_offset.y != 0;
            const max_scroll_offset = padded_bounds.size.height - content_height;
            if (is_scrolled_vertically and scroll_offset.y < max_scroll_offset) {
                scroll_offset.y = max_scroll_offset;
            }

            const content_width_with_padding = content_size.width + padding.left + padding.right;
            const is_scrolled_horizontally = can_scroll_horizontally and scroll_offset.x != 0;
            if (is_scrolled_horizontally and content_width_with_padding <= padded_bounds.size.width) {
                scroll_offset.x = 0;
            }

            if (shared_scroll_to_item) |deferred| {
                var item_index = deferred.item_index;
                var strategy = deferred.strategy;
                if (is_flipped) {
                    item_index = self.item_count -| (item_index +| 1);
                }
                const list_height = padded_bounds.size.height;
                const item_top = item_height * @as(f32, @floatFromInt(item_index));
                const item_bottom = item_top + item_height;
                const scroll_top = -scroll_offset.y;
                const offset_pixels = item_height * @as(f32, @floatFromInt(deferred.offset));

                const is_above = item_top < scroll_top + offset_pixels;
                const is_below = item_bottom > scroll_top + list_height;

                if (deferred.scroll_strict or is_above or is_below) {
                    if (strategy == .nearest) {
                        if (is_above) {
                            strategy = .top;
                        } else if (is_below) {
                            strategy = .bottom;
                        }
                    }

                    const max_scroll = @max(content_height - list_height, 0);
                    switch (strategy) {
                        .top => scroll_offset.y = -std.math.clamp(item_top - offset_pixels, 0, max_scroll),
                        .center => {
                            const item_center = item_top + item_height / 2;
                            const viewport_height = list_height - offset_pixels;
                            const viewport_center = offset_pixels + viewport_height / 2;
                            const target_scroll_top = item_center - viewport_center;
                            scroll_offset.y = -std.math.clamp(target_scroll_top, 0, max_scroll);
                        },
                        .bottom => scroll_offset.y = -std.math.clamp(item_bottom - list_height, 0, max_scroll),
                        .nearest => {},
                    }
                }
            }

            const scroll_top: f64 = -@as(f64, scroll_offset.y);
            const item_height_f64: f64 = item_height;
            const first_visible_ix = saturating_index(@floor((scroll_top - @as(f64, padding.top)) / item_height_f64));
            const last_visible_ix = saturating_index(@ceil((scroll_top + @as(f64, padded_bounds.size.height)) / item_height_f64));
            const visible_range: Range = .{
                .start = first_visible_ix,
                .end = @max(first_visible_ix, @min(last_visible_ix, self.item_count)),
            };

            const items: []AnyElement = if (is_flipped) blk: {
                const flipped_range: Range = .{
                    .start = self.item_count -| visible_range.end,
                    .end = self.item_count -| visible_range.start,
                };
                const rendered = self.render_items.call(flipped_range, window, cx);
                std.mem.reverse(AnyElement, rendered);
                break :blk rendered;
            } else self.render_items.call(visible_range, window, cx);

            window.push_content_mask(.{ .bounds = bounds });
            defer window.pop_content_mask();

            const laid_out = @min(items.len, visible_range.len());
            for (items[0..laid_out], 0..) |item, i| {
                const ix = visible_range.start + i;
                const item_top: f64 = item_height_f64 * @as(f64, @floatFromInt(ix)) - scroll_top;
                const item_origin = padded_bounds.origin.add(point(scroll_offset.x, @as(Pixels, @floatCast(item_top))));

                const available_width = if (can_scroll_horizontally)
                    padded_bounds.size.width + @abs(scroll_offset.x)
                else
                    padded_bounds.size.width;
                const available_space: Size(AvailableSpace) = .{
                    .width = .{ .definite = available_width },
                    .height = .{ .definite = item_height },
                };
                _ = item.layout_as_root(available_space, window, cx);
                item.prepaint_at(item_origin, window, cx);
                rl.items.append(window_mod.frame_arena(), item) catch oom();
            }

            const decorated_bounds: Bounds(Pixels) = .{
                .origin = padded_bounds.origin.add(scroll_offset),
                .size = padded_bounds.size,
            };
            for (self.decorations.items) |decoration| {
                const element = decoration.compute(visible_range, decorated_bounds, scroll_offset, item_height, self.item_count, window, cx);
                _ = element.layout_as_root(.{
                    .width = .{ .definite = decorated_bounds.size.width },
                    .height = .{ .definite = decorated_bounds.size.height },
                }, window, cx);
                element.prepaint_at(decorated_bounds.origin, window, cx);
                rl.decorations.append(window_mod.frame_arena(), element) catch oom();
            }
        }

        pp.scroll_offset = scroll_offset;
        pp.max_scroll = .{
            .width = @max(0, content_size.width - padded_bounds.size.width),
            .height = @max(0, content_size.height - padded_bounds.size.height),
        };
        if (self.scroll_handle) |handle| {
            handle.state.base_handle.state.bounds = bounds;
            handle.state.base_handle.state.max_offset = pp.max_scroll;
            handle.state.base_handle.set_offset(scroll_offset);
        } else if (pp.state) |st| {
            st.scroll_offset = scroll_offset;
        }
        return pp;
    }

    pub fn paint(self: *Self, gid: ?*const GlobalElementId, bounds: Bounds(Pixels), rl: *RequestLayoutState, pp: *PrepaintState, window: *Window, cx: *App) void {
        _ = gid;
        const s = &pp.style;
        if (s.visibility == .hidden) return;

        if (pp.hitbox) |*hb| {
            if (s.mouse_cursor) |c| window.set_cursor_style(c, hb);
            const ctx = window_mod.frame_arena().create(ScrollCtx) catch oom();
            ctx.* = .{ .list = self, .hitbox = hb.*, .state = pp.state, .max_scroll = pp.max_scroll };
            window.on_mouse_event(ScrollWheelEvent, ctx, onScrollWheel);
        }

        window.push_element_opacity(s.opacity);
        defer window.pop_element_opacity();

        const rem = window.rem_size();
        const radii = s.corner_radii.to_pixels(rem).clamp_radii_for_quad_size(bounds.size);
        window.paint_drop_shadows(bounds, radii, s.box_shadow);
        if (s.background) |bgf| {
            const bgc = bgf.get_color() orelse color_mod.to_background(color_mod.transparent_black());
            if (!bgc.is_transparent()) {
                window.paint_quad(.{ .bounds = bounds, .corner_radii = radii, .background = bgc });
            }
        }
        window.paint_inset_shadows(bounds, radii, s.box_shadow);

        const mask = s.overflow_mask(bounds, rem);
        if (mask) |mk| window.push_content_mask(.{ .bounds = mk });
        for (rl.items.items) |item| item.paint(window, cx);
        for (rl.decorations.items) |decoration| decoration.paint(window, cx);
        if (mask != null) window.pop_content_mask();

        if (s.is_border_visible()) {
            if (s.border_color) |bc| {
                const bw = s.border_widths.to_pixels(.{rem});
                window.paint_quad(.{
                    .bounds = bounds,
                    .corner_radii = radii,
                    .background = color_mod.to_background(color_mod.transparent_black()),
                    .border_widths = bw,
                    .border_color = bc,
                    .border_style = s.border_style,
                });
            }
        }
    }

    const ScrollCtx = struct {
        list: *Self,
        hitbox: Hitbox,
        state: ?*InteractiveElementState,
        max_scroll: Size(Pixels),
    };

    fn onScrollWheel(raw: *anyopaque, e: *const ScrollWheelEvent, phase: DispatchPhase, window: *Window, cx: *App) void {
        const c: *ScrollCtx = @ptrCast(@alignCast(raw));
        if (phase != .bubble or !c.hitbox.should_handle_scroll(window)) return;
        for (c.list.interactivity.scroll_wheel_listeners.items) |l| l.call(e, window, cx);

        const delta = e.delta.pixel_delta(window.line_height());
        const can_scroll_horizontally = c.list.horizontal_sizing_behavior == .unconstrained;
        var offset: Point(Pixels) = if (c.list.interactivity.tracked_scroll_handle) |sh|
            sh.offset()
        else if (c.state) |st|
            st.scroll_offset
        else
            return;

        offset.y = std.math.clamp(offset.y + delta.y, -c.max_scroll.height, 0);
        if (can_scroll_horizontally) {
            offset.x = std.math.clamp(offset.x + delta.x, -c.max_scroll.width, 0);
        }

        if (c.list.interactivity.tracked_scroll_handle) |sh| sh.set_offset(offset);
        if (c.state) |st| st.scroll_offset = offset;
        window.refresh();
        window.stop_propagation();
    }

    // Styled methods (generated from styled.zig, same aliases as `StyledElement`).
        pub const text_style = StyledM.text_style;
        pub const block = StyledM.block;
        pub const flex = StyledM.flex;
        pub const grid = StyledM.grid;
        pub const hidden = StyledM.hidden;
        pub const scrollbar_width = StyledM.scrollbar_width;
        pub const whitespace_normal = StyledM.whitespace_normal;
        pub const whitespace_nowrap = StyledM.whitespace_nowrap;
        pub const text_ellipsis = StyledM.text_ellipsis;
        pub const text_ellipsis_start = StyledM.text_ellipsis_start;
        pub const text_ellipsis_middle = StyledM.text_ellipsis_middle;
        pub const text_overflow = StyledM.text_overflow;
        pub const text_align = StyledM.text_align;
        pub const text_left = StyledM.text_left;
        pub const text_center = StyledM.text_center;
        pub const text_right = StyledM.text_right;
        pub const truncate = StyledM.truncate;
        pub const line_clamp = StyledM.line_clamp;
        pub const flex_col = StyledM.flex_col;
        pub const flex_col_reverse = StyledM.flex_col_reverse;
        pub const flex_row = StyledM.flex_row;
        pub const flex_row_reverse = StyledM.flex_row_reverse;
        pub const flex_1 = StyledM.flex_1;
        pub const flex_auto = StyledM.flex_auto;
        pub const flex_initial = StyledM.flex_initial;
        pub const flex_none = StyledM.flex_none;
        pub const flex_basis = StyledM.flex_basis;
        pub const flex_grow = StyledM.flex_grow;
        pub const flex_grow_0 = StyledM.flex_grow_0;
        pub const flex_grow_1 = StyledM.flex_grow_1;
        pub const flex_shrink = StyledM.flex_shrink;
        pub const flex_shrink_0 = StyledM.flex_shrink_0;
        pub const flex_shrink_1 = StyledM.flex_shrink_1;
        pub const flex_wrap = StyledM.flex_wrap;
        pub const flex_wrap_reverse = StyledM.flex_wrap_reverse;
        pub const flex_nowrap = StyledM.flex_nowrap;
        pub const items_start = StyledM.items_start;
        pub const items_end = StyledM.items_end;
        pub const items_center = StyledM.items_center;
        pub const items_baseline = StyledM.items_baseline;
        pub const items_stretch = StyledM.items_stretch;
        pub const self_start = StyledM.self_start;
        pub const self_end = StyledM.self_end;
        pub const self_flex_start = StyledM.self_flex_start;
        pub const self_flex_end = StyledM.self_flex_end;
        pub const self_center = StyledM.self_center;
        pub const self_baseline = StyledM.self_baseline;
        pub const self_stretch = StyledM.self_stretch;
        pub const justify_start = StyledM.justify_start;
        pub const justify_end = StyledM.justify_end;
        pub const justify_center = StyledM.justify_center;
        pub const justify_between = StyledM.justify_between;
        pub const justify_around = StyledM.justify_around;
        pub const justify_evenly = StyledM.justify_evenly;
        pub const content_normal = StyledM.content_normal;
        pub const content_center = StyledM.content_center;
        pub const content_start = StyledM.content_start;
        pub const content_end = StyledM.content_end;
        pub const content_between = StyledM.content_between;
        pub const content_around = StyledM.content_around;
        pub const content_evenly = StyledM.content_evenly;
        pub const content_stretch = StyledM.content_stretch;
        pub const aspect_ratio = StyledM.aspect_ratio;
        pub const aspect_square = StyledM.aspect_square;
        pub const bg = StyledM.bg;
        pub const border_dashed = StyledM.border_dashed;
        pub const border_color = StyledM.border_color;
        pub const text_color = StyledM.text_color;
        pub const font_weight = StyledM.font_weight;
        pub const text_bg = StyledM.text_bg;
        pub const text_size = StyledM.text_size;
        pub const text_xs = StyledM.text_xs;
        pub const text_sm = StyledM.text_sm;
        pub const text_base = StyledM.text_base;
        pub const text_lg = StyledM.text_lg;
        pub const text_xl = StyledM.text_xl;
        pub const text_2xl = StyledM.text_2xl;
        pub const text_3xl = StyledM.text_3xl;
        pub const italic = StyledM.italic;
        pub const not_italic = StyledM.not_italic;
        pub const underline = StyledM.underline;
        pub const line_through = StyledM.line_through;
        pub const text_decoration_none = StyledM.text_decoration_none;
        pub const text_decoration_color = StyledM.text_decoration_color;
        pub const text_decoration_solid = StyledM.text_decoration_solid;
        pub const text_decoration_wavy = StyledM.text_decoration_wavy;
        pub const text_decoration_0 = StyledM.text_decoration_0;
        pub const text_decoration_1 = StyledM.text_decoration_1;
        pub const text_decoration_2 = StyledM.text_decoration_2;
        pub const text_decoration_4 = StyledM.text_decoration_4;
        pub const text_decoration_8 = StyledM.text_decoration_8;
        pub const font_family = StyledM.font_family;
        pub const font_features = StyledM.font_features;
        pub const font = StyledM.font;
        pub const line_height = StyledM.line_height;
        pub const opacity = StyledM.opacity;
        pub const grid_cols = StyledM.grid_cols;
        pub const grid_cols_min_content = StyledM.grid_cols_min_content;
        pub const grid_cols_max_content = StyledM.grid_cols_max_content;
        pub const grid_rows = StyledM.grid_rows;
        pub const grid_rows_min_content = StyledM.grid_rows_min_content;
        pub const grid_rows_max_content = StyledM.grid_rows_max_content;
        pub const col_start = StyledM.col_start;
        pub const col_start_auto = StyledM.col_start_auto;
        pub const col_end = StyledM.col_end;
        pub const col_end_auto = StyledM.col_end_auto;
        pub const col_span = StyledM.col_span;
        pub const col_span_full = StyledM.col_span_full;
        pub const row_start = StyledM.row_start;
        pub const row_start_auto = StyledM.row_start_auto;
        pub const row_end = StyledM.row_end;
        pub const row_end_auto = StyledM.row_end_auto;
        pub const row_span = StyledM.row_span;
        pub const row_span_full = StyledM.row_span_full;
        pub const debug = StyledM.debug;
        pub const debug_below = StyledM.debug_below;
        pub const visible = StyledM.visible;
        pub const invisible = StyledM.invisible;
        pub const relative = StyledM.relative;
        pub const absolute = StyledM.absolute;
        pub const overflow_hidden = StyledM.overflow_hidden;
        pub const overflow_x_hidden = StyledM.overflow_x_hidden;
        pub const overflow_y_hidden = StyledM.overflow_y_hidden;
        pub const cursor = StyledM.cursor;
        pub const cursor_default = StyledM.cursor_default;
        pub const cursor_pointer = StyledM.cursor_pointer;
        pub const cursor_text = StyledM.cursor_text;
        pub const cursor_move = StyledM.cursor_move;
        pub const cursor_not_allowed = StyledM.cursor_not_allowed;
        pub const cursor_context_menu = StyledM.cursor_context_menu;
        pub const cursor_crosshair = StyledM.cursor_crosshair;
        pub const cursor_vertical_text = StyledM.cursor_vertical_text;
        pub const cursor_alias = StyledM.cursor_alias;
        pub const cursor_copy = StyledM.cursor_copy;
        pub const cursor_no_drop = StyledM.cursor_no_drop;
        pub const cursor_grab = StyledM.cursor_grab;
        pub const cursor_grabbing = StyledM.cursor_grabbing;
        pub const cursor_ew_resize = StyledM.cursor_ew_resize;
        pub const cursor_ns_resize = StyledM.cursor_ns_resize;
        pub const cursor_nesw_resize = StyledM.cursor_nesw_resize;
        pub const cursor_nwse_resize = StyledM.cursor_nwse_resize;
        pub const cursor_col_resize = StyledM.cursor_col_resize;
        pub const cursor_row_resize = StyledM.cursor_row_resize;
        pub const cursor_n_resize = StyledM.cursor_n_resize;
        pub const cursor_e_resize = StyledM.cursor_e_resize;
        pub const cursor_s_resize = StyledM.cursor_s_resize;
        pub const cursor_w_resize = StyledM.cursor_w_resize;
        pub const border = StyledM.border;
        pub const border_0 = StyledM.border_0;
        pub const border_1 = StyledM.border_1;
        pub const border_2 = StyledM.border_2;
        pub const border_3 = StyledM.border_3;
        pub const border_4 = StyledM.border_4;
        pub const border_5 = StyledM.border_5;
        pub const border_6 = StyledM.border_6;
        pub const border_7 = StyledM.border_7;
        pub const border_8 = StyledM.border_8;
        pub const border_9 = StyledM.border_9;
        pub const border_10 = StyledM.border_10;
        pub const border_11 = StyledM.border_11;
        pub const border_12 = StyledM.border_12;
        pub const border_16 = StyledM.border_16;
        pub const border_20 = StyledM.border_20;
        pub const border_24 = StyledM.border_24;
        pub const border_32 = StyledM.border_32;
        pub const border_t = StyledM.border_t;
        pub const border_t_0 = StyledM.border_t_0;
        pub const border_t_1 = StyledM.border_t_1;
        pub const border_t_2 = StyledM.border_t_2;
        pub const border_t_3 = StyledM.border_t_3;
        pub const border_t_4 = StyledM.border_t_4;
        pub const border_t_5 = StyledM.border_t_5;
        pub const border_t_6 = StyledM.border_t_6;
        pub const border_t_7 = StyledM.border_t_7;
        pub const border_t_8 = StyledM.border_t_8;
        pub const border_t_9 = StyledM.border_t_9;
        pub const border_t_10 = StyledM.border_t_10;
        pub const border_t_11 = StyledM.border_t_11;
        pub const border_t_12 = StyledM.border_t_12;
        pub const border_t_16 = StyledM.border_t_16;
        pub const border_t_20 = StyledM.border_t_20;
        pub const border_t_24 = StyledM.border_t_24;
        pub const border_t_32 = StyledM.border_t_32;
        pub const border_b = StyledM.border_b;
        pub const border_b_0 = StyledM.border_b_0;
        pub const border_b_1 = StyledM.border_b_1;
        pub const border_b_2 = StyledM.border_b_2;
        pub const border_b_3 = StyledM.border_b_3;
        pub const border_b_4 = StyledM.border_b_4;
        pub const border_b_5 = StyledM.border_b_5;
        pub const border_b_6 = StyledM.border_b_6;
        pub const border_b_7 = StyledM.border_b_7;
        pub const border_b_8 = StyledM.border_b_8;
        pub const border_b_9 = StyledM.border_b_9;
        pub const border_b_10 = StyledM.border_b_10;
        pub const border_b_11 = StyledM.border_b_11;
        pub const border_b_12 = StyledM.border_b_12;
        pub const border_b_16 = StyledM.border_b_16;
        pub const border_b_20 = StyledM.border_b_20;
        pub const border_b_24 = StyledM.border_b_24;
        pub const border_b_32 = StyledM.border_b_32;
        pub const border_r = StyledM.border_r;
        pub const border_r_0 = StyledM.border_r_0;
        pub const border_r_1 = StyledM.border_r_1;
        pub const border_r_2 = StyledM.border_r_2;
        pub const border_r_3 = StyledM.border_r_3;
        pub const border_r_4 = StyledM.border_r_4;
        pub const border_r_5 = StyledM.border_r_5;
        pub const border_r_6 = StyledM.border_r_6;
        pub const border_r_7 = StyledM.border_r_7;
        pub const border_r_8 = StyledM.border_r_8;
        pub const border_r_9 = StyledM.border_r_9;
        pub const border_r_10 = StyledM.border_r_10;
        pub const border_r_11 = StyledM.border_r_11;
        pub const border_r_12 = StyledM.border_r_12;
        pub const border_r_16 = StyledM.border_r_16;
        pub const border_r_20 = StyledM.border_r_20;
        pub const border_r_24 = StyledM.border_r_24;
        pub const border_r_32 = StyledM.border_r_32;
        pub const border_l = StyledM.border_l;
        pub const border_l_0 = StyledM.border_l_0;
        pub const border_l_1 = StyledM.border_l_1;
        pub const border_l_2 = StyledM.border_l_2;
        pub const border_l_3 = StyledM.border_l_3;
        pub const border_l_4 = StyledM.border_l_4;
        pub const border_l_5 = StyledM.border_l_5;
        pub const border_l_6 = StyledM.border_l_6;
        pub const border_l_7 = StyledM.border_l_7;
        pub const border_l_8 = StyledM.border_l_8;
        pub const border_l_9 = StyledM.border_l_9;
        pub const border_l_10 = StyledM.border_l_10;
        pub const border_l_11 = StyledM.border_l_11;
        pub const border_l_12 = StyledM.border_l_12;
        pub const border_l_16 = StyledM.border_l_16;
        pub const border_l_20 = StyledM.border_l_20;
        pub const border_l_24 = StyledM.border_l_24;
        pub const border_l_32 = StyledM.border_l_32;
        pub const border_x = StyledM.border_x;
        pub const border_x_0 = StyledM.border_x_0;
        pub const border_x_1 = StyledM.border_x_1;
        pub const border_x_2 = StyledM.border_x_2;
        pub const border_x_3 = StyledM.border_x_3;
        pub const border_x_4 = StyledM.border_x_4;
        pub const border_x_5 = StyledM.border_x_5;
        pub const border_x_6 = StyledM.border_x_6;
        pub const border_x_7 = StyledM.border_x_7;
        pub const border_x_8 = StyledM.border_x_8;
        pub const border_x_9 = StyledM.border_x_9;
        pub const border_x_10 = StyledM.border_x_10;
        pub const border_x_11 = StyledM.border_x_11;
        pub const border_x_12 = StyledM.border_x_12;
        pub const border_x_16 = StyledM.border_x_16;
        pub const border_x_20 = StyledM.border_x_20;
        pub const border_x_24 = StyledM.border_x_24;
        pub const border_x_32 = StyledM.border_x_32;
        pub const border_y = StyledM.border_y;
        pub const border_y_0 = StyledM.border_y_0;
        pub const border_y_1 = StyledM.border_y_1;
        pub const border_y_2 = StyledM.border_y_2;
        pub const border_y_3 = StyledM.border_y_3;
        pub const border_y_4 = StyledM.border_y_4;
        pub const border_y_5 = StyledM.border_y_5;
        pub const border_y_6 = StyledM.border_y_6;
        pub const border_y_7 = StyledM.border_y_7;
        pub const border_y_8 = StyledM.border_y_8;
        pub const border_y_9 = StyledM.border_y_9;
        pub const border_y_10 = StyledM.border_y_10;
        pub const border_y_11 = StyledM.border_y_11;
        pub const border_y_12 = StyledM.border_y_12;
        pub const border_y_16 = StyledM.border_y_16;
        pub const border_y_20 = StyledM.border_y_20;
        pub const border_y_24 = StyledM.border_y_24;
        pub const border_y_32 = StyledM.border_y_32;
        pub const m = StyledM.m;
        pub const m_0 = StyledM.m_0;
        pub const m_neg_0 = StyledM.m_neg_0;
        pub const m_0p5 = StyledM.m_0p5;
        pub const m_neg_0p5 = StyledM.m_neg_0p5;
        pub const m_1 = StyledM.m_1;
        pub const m_neg_1 = StyledM.m_neg_1;
        pub const m_1p5 = StyledM.m_1p5;
        pub const m_neg_1p5 = StyledM.m_neg_1p5;
        pub const m_2 = StyledM.m_2;
        pub const m_neg_2 = StyledM.m_neg_2;
        pub const m_2p5 = StyledM.m_2p5;
        pub const m_neg_2p5 = StyledM.m_neg_2p5;
        pub const m_3 = StyledM.m_3;
        pub const m_neg_3 = StyledM.m_neg_3;
        pub const m_3p5 = StyledM.m_3p5;
        pub const m_neg_3p5 = StyledM.m_neg_3p5;
        pub const m_4 = StyledM.m_4;
        pub const m_neg_4 = StyledM.m_neg_4;
        pub const m_5 = StyledM.m_5;
        pub const m_neg_5 = StyledM.m_neg_5;
        pub const m_6 = StyledM.m_6;
        pub const m_neg_6 = StyledM.m_neg_6;
        pub const m_7 = StyledM.m_7;
        pub const m_neg_7 = StyledM.m_neg_7;
        pub const m_8 = StyledM.m_8;
        pub const m_neg_8 = StyledM.m_neg_8;
        pub const m_9 = StyledM.m_9;
        pub const m_neg_9 = StyledM.m_neg_9;
        pub const m_10 = StyledM.m_10;
        pub const m_neg_10 = StyledM.m_neg_10;
        pub const m_11 = StyledM.m_11;
        pub const m_neg_11 = StyledM.m_neg_11;
        pub const m_12 = StyledM.m_12;
        pub const m_neg_12 = StyledM.m_neg_12;
        pub const m_16 = StyledM.m_16;
        pub const m_neg_16 = StyledM.m_neg_16;
        pub const m_20 = StyledM.m_20;
        pub const m_neg_20 = StyledM.m_neg_20;
        pub const m_24 = StyledM.m_24;
        pub const m_neg_24 = StyledM.m_neg_24;
        pub const m_32 = StyledM.m_32;
        pub const m_neg_32 = StyledM.m_neg_32;
        pub const m_40 = StyledM.m_40;
        pub const m_neg_40 = StyledM.m_neg_40;
        pub const m_48 = StyledM.m_48;
        pub const m_neg_48 = StyledM.m_neg_48;
        pub const m_56 = StyledM.m_56;
        pub const m_neg_56 = StyledM.m_neg_56;
        pub const m_64 = StyledM.m_64;
        pub const m_neg_64 = StyledM.m_neg_64;
        pub const m_72 = StyledM.m_72;
        pub const m_neg_72 = StyledM.m_neg_72;
        pub const m_80 = StyledM.m_80;
        pub const m_neg_80 = StyledM.m_neg_80;
        pub const m_96 = StyledM.m_96;
        pub const m_neg_96 = StyledM.m_neg_96;
        pub const m_112 = StyledM.m_112;
        pub const m_neg_112 = StyledM.m_neg_112;
        pub const m_128 = StyledM.m_128;
        pub const m_neg_128 = StyledM.m_neg_128;
        pub const m_auto = StyledM.m_auto;
        pub const m_px = StyledM.m_px;
        pub const m_neg_px = StyledM.m_neg_px;
        pub const m_full = StyledM.m_full;
        pub const m_neg_full = StyledM.m_neg_full;
        pub const m_1_2 = StyledM.m_1_2;
        pub const m_neg_1_2 = StyledM.m_neg_1_2;
        pub const m_1_3 = StyledM.m_1_3;
        pub const m_neg_1_3 = StyledM.m_neg_1_3;
        pub const m_2_3 = StyledM.m_2_3;
        pub const m_neg_2_3 = StyledM.m_neg_2_3;
        pub const m_1_4 = StyledM.m_1_4;
        pub const m_neg_1_4 = StyledM.m_neg_1_4;
        pub const m_2_4 = StyledM.m_2_4;
        pub const m_neg_2_4 = StyledM.m_neg_2_4;
        pub const m_3_4 = StyledM.m_3_4;
        pub const m_neg_3_4 = StyledM.m_neg_3_4;
        pub const m_1_5 = StyledM.m_1_5;
        pub const m_neg_1_5 = StyledM.m_neg_1_5;
        pub const m_2_5 = StyledM.m_2_5;
        pub const m_neg_2_5 = StyledM.m_neg_2_5;
        pub const m_3_5 = StyledM.m_3_5;
        pub const m_neg_3_5 = StyledM.m_neg_3_5;
        pub const m_4_5 = StyledM.m_4_5;
        pub const m_neg_4_5 = StyledM.m_neg_4_5;
        pub const m_1_6 = StyledM.m_1_6;
        pub const m_neg_1_6 = StyledM.m_neg_1_6;
        pub const m_5_6 = StyledM.m_5_6;
        pub const m_neg_5_6 = StyledM.m_neg_5_6;
        pub const m_1_12 = StyledM.m_1_12;
        pub const m_neg_1_12 = StyledM.m_neg_1_12;
        pub const mt = StyledM.mt;
        pub const mt_0 = StyledM.mt_0;
        pub const mt_neg_0 = StyledM.mt_neg_0;
        pub const mt_0p5 = StyledM.mt_0p5;
        pub const mt_neg_0p5 = StyledM.mt_neg_0p5;
        pub const mt_1 = StyledM.mt_1;
        pub const mt_neg_1 = StyledM.mt_neg_1;
        pub const mt_1p5 = StyledM.mt_1p5;
        pub const mt_neg_1p5 = StyledM.mt_neg_1p5;
        pub const mt_2 = StyledM.mt_2;
        pub const mt_neg_2 = StyledM.mt_neg_2;
        pub const mt_2p5 = StyledM.mt_2p5;
        pub const mt_neg_2p5 = StyledM.mt_neg_2p5;
        pub const mt_3 = StyledM.mt_3;
        pub const mt_neg_3 = StyledM.mt_neg_3;
        pub const mt_3p5 = StyledM.mt_3p5;
        pub const mt_neg_3p5 = StyledM.mt_neg_3p5;
        pub const mt_4 = StyledM.mt_4;
        pub const mt_neg_4 = StyledM.mt_neg_4;
        pub const mt_5 = StyledM.mt_5;
        pub const mt_neg_5 = StyledM.mt_neg_5;
        pub const mt_6 = StyledM.mt_6;
        pub const mt_neg_6 = StyledM.mt_neg_6;
        pub const mt_7 = StyledM.mt_7;
        pub const mt_neg_7 = StyledM.mt_neg_7;
        pub const mt_8 = StyledM.mt_8;
        pub const mt_neg_8 = StyledM.mt_neg_8;
        pub const mt_9 = StyledM.mt_9;
        pub const mt_neg_9 = StyledM.mt_neg_9;
        pub const mt_10 = StyledM.mt_10;
        pub const mt_neg_10 = StyledM.mt_neg_10;
        pub const mt_11 = StyledM.mt_11;
        pub const mt_neg_11 = StyledM.mt_neg_11;
        pub const mt_12 = StyledM.mt_12;
        pub const mt_neg_12 = StyledM.mt_neg_12;
        pub const mt_16 = StyledM.mt_16;
        pub const mt_neg_16 = StyledM.mt_neg_16;
        pub const mt_20 = StyledM.mt_20;
        pub const mt_neg_20 = StyledM.mt_neg_20;
        pub const mt_24 = StyledM.mt_24;
        pub const mt_neg_24 = StyledM.mt_neg_24;
        pub const mt_32 = StyledM.mt_32;
        pub const mt_neg_32 = StyledM.mt_neg_32;
        pub const mt_40 = StyledM.mt_40;
        pub const mt_neg_40 = StyledM.mt_neg_40;
        pub const mt_48 = StyledM.mt_48;
        pub const mt_neg_48 = StyledM.mt_neg_48;
        pub const mt_56 = StyledM.mt_56;
        pub const mt_neg_56 = StyledM.mt_neg_56;
        pub const mt_64 = StyledM.mt_64;
        pub const mt_neg_64 = StyledM.mt_neg_64;
        pub const mt_72 = StyledM.mt_72;
        pub const mt_neg_72 = StyledM.mt_neg_72;
        pub const mt_80 = StyledM.mt_80;
        pub const mt_neg_80 = StyledM.mt_neg_80;
        pub const mt_96 = StyledM.mt_96;
        pub const mt_neg_96 = StyledM.mt_neg_96;
        pub const mt_112 = StyledM.mt_112;
        pub const mt_neg_112 = StyledM.mt_neg_112;
        pub const mt_128 = StyledM.mt_128;
        pub const mt_neg_128 = StyledM.mt_neg_128;
        pub const mt_auto = StyledM.mt_auto;
        pub const mt_px = StyledM.mt_px;
        pub const mt_neg_px = StyledM.mt_neg_px;
        pub const mt_full = StyledM.mt_full;
        pub const mt_neg_full = StyledM.mt_neg_full;
        pub const mt_1_2 = StyledM.mt_1_2;
        pub const mt_neg_1_2 = StyledM.mt_neg_1_2;
        pub const mt_1_3 = StyledM.mt_1_3;
        pub const mt_neg_1_3 = StyledM.mt_neg_1_3;
        pub const mt_2_3 = StyledM.mt_2_3;
        pub const mt_neg_2_3 = StyledM.mt_neg_2_3;
        pub const mt_1_4 = StyledM.mt_1_4;
        pub const mt_neg_1_4 = StyledM.mt_neg_1_4;
        pub const mt_2_4 = StyledM.mt_2_4;
        pub const mt_neg_2_4 = StyledM.mt_neg_2_4;
        pub const mt_3_4 = StyledM.mt_3_4;
        pub const mt_neg_3_4 = StyledM.mt_neg_3_4;
        pub const mt_1_5 = StyledM.mt_1_5;
        pub const mt_neg_1_5 = StyledM.mt_neg_1_5;
        pub const mt_2_5 = StyledM.mt_2_5;
        pub const mt_neg_2_5 = StyledM.mt_neg_2_5;
        pub const mt_3_5 = StyledM.mt_3_5;
        pub const mt_neg_3_5 = StyledM.mt_neg_3_5;
        pub const mt_4_5 = StyledM.mt_4_5;
        pub const mt_neg_4_5 = StyledM.mt_neg_4_5;
        pub const mt_1_6 = StyledM.mt_1_6;
        pub const mt_neg_1_6 = StyledM.mt_neg_1_6;
        pub const mt_5_6 = StyledM.mt_5_6;
        pub const mt_neg_5_6 = StyledM.mt_neg_5_6;
        pub const mt_1_12 = StyledM.mt_1_12;
        pub const mt_neg_1_12 = StyledM.mt_neg_1_12;
        pub const mb = StyledM.mb;
        pub const mb_0 = StyledM.mb_0;
        pub const mb_neg_0 = StyledM.mb_neg_0;
        pub const mb_0p5 = StyledM.mb_0p5;
        pub const mb_neg_0p5 = StyledM.mb_neg_0p5;
        pub const mb_1 = StyledM.mb_1;
        pub const mb_neg_1 = StyledM.mb_neg_1;
        pub const mb_1p5 = StyledM.mb_1p5;
        pub const mb_neg_1p5 = StyledM.mb_neg_1p5;
        pub const mb_2 = StyledM.mb_2;
        pub const mb_neg_2 = StyledM.mb_neg_2;
        pub const mb_2p5 = StyledM.mb_2p5;
        pub const mb_neg_2p5 = StyledM.mb_neg_2p5;
        pub const mb_3 = StyledM.mb_3;
        pub const mb_neg_3 = StyledM.mb_neg_3;
        pub const mb_3p5 = StyledM.mb_3p5;
        pub const mb_neg_3p5 = StyledM.mb_neg_3p5;
        pub const mb_4 = StyledM.mb_4;
        pub const mb_neg_4 = StyledM.mb_neg_4;
        pub const mb_5 = StyledM.mb_5;
        pub const mb_neg_5 = StyledM.mb_neg_5;
        pub const mb_6 = StyledM.mb_6;
        pub const mb_neg_6 = StyledM.mb_neg_6;
        pub const mb_7 = StyledM.mb_7;
        pub const mb_neg_7 = StyledM.mb_neg_7;
        pub const mb_8 = StyledM.mb_8;
        pub const mb_neg_8 = StyledM.mb_neg_8;
        pub const mb_9 = StyledM.mb_9;
        pub const mb_neg_9 = StyledM.mb_neg_9;
        pub const mb_10 = StyledM.mb_10;
        pub const mb_neg_10 = StyledM.mb_neg_10;
        pub const mb_11 = StyledM.mb_11;
        pub const mb_neg_11 = StyledM.mb_neg_11;
        pub const mb_12 = StyledM.mb_12;
        pub const mb_neg_12 = StyledM.mb_neg_12;
        pub const mb_16 = StyledM.mb_16;
        pub const mb_neg_16 = StyledM.mb_neg_16;
        pub const mb_20 = StyledM.mb_20;
        pub const mb_neg_20 = StyledM.mb_neg_20;
        pub const mb_24 = StyledM.mb_24;
        pub const mb_neg_24 = StyledM.mb_neg_24;
        pub const mb_32 = StyledM.mb_32;
        pub const mb_neg_32 = StyledM.mb_neg_32;
        pub const mb_40 = StyledM.mb_40;
        pub const mb_neg_40 = StyledM.mb_neg_40;
        pub const mb_48 = StyledM.mb_48;
        pub const mb_neg_48 = StyledM.mb_neg_48;
        pub const mb_56 = StyledM.mb_56;
        pub const mb_neg_56 = StyledM.mb_neg_56;
        pub const mb_64 = StyledM.mb_64;
        pub const mb_neg_64 = StyledM.mb_neg_64;
        pub const mb_72 = StyledM.mb_72;
        pub const mb_neg_72 = StyledM.mb_neg_72;
        pub const mb_80 = StyledM.mb_80;
        pub const mb_neg_80 = StyledM.mb_neg_80;
        pub const mb_96 = StyledM.mb_96;
        pub const mb_neg_96 = StyledM.mb_neg_96;
        pub const mb_112 = StyledM.mb_112;
        pub const mb_neg_112 = StyledM.mb_neg_112;
        pub const mb_128 = StyledM.mb_128;
        pub const mb_neg_128 = StyledM.mb_neg_128;
        pub const mb_auto = StyledM.mb_auto;
        pub const mb_px = StyledM.mb_px;
        pub const mb_neg_px = StyledM.mb_neg_px;
        pub const mb_full = StyledM.mb_full;
        pub const mb_neg_full = StyledM.mb_neg_full;
        pub const mb_1_2 = StyledM.mb_1_2;
        pub const mb_neg_1_2 = StyledM.mb_neg_1_2;
        pub const mb_1_3 = StyledM.mb_1_3;
        pub const mb_neg_1_3 = StyledM.mb_neg_1_3;
        pub const mb_2_3 = StyledM.mb_2_3;
        pub const mb_neg_2_3 = StyledM.mb_neg_2_3;
        pub const mb_1_4 = StyledM.mb_1_4;
        pub const mb_neg_1_4 = StyledM.mb_neg_1_4;
        pub const mb_2_4 = StyledM.mb_2_4;
        pub const mb_neg_2_4 = StyledM.mb_neg_2_4;
        pub const mb_3_4 = StyledM.mb_3_4;
        pub const mb_neg_3_4 = StyledM.mb_neg_3_4;
        pub const mb_1_5 = StyledM.mb_1_5;
        pub const mb_neg_1_5 = StyledM.mb_neg_1_5;
        pub const mb_2_5 = StyledM.mb_2_5;
        pub const mb_neg_2_5 = StyledM.mb_neg_2_5;
        pub const mb_3_5 = StyledM.mb_3_5;
        pub const mb_neg_3_5 = StyledM.mb_neg_3_5;
        pub const mb_4_5 = StyledM.mb_4_5;
        pub const mb_neg_4_5 = StyledM.mb_neg_4_5;
        pub const mb_1_6 = StyledM.mb_1_6;
        pub const mb_neg_1_6 = StyledM.mb_neg_1_6;
        pub const mb_5_6 = StyledM.mb_5_6;
        pub const mb_neg_5_6 = StyledM.mb_neg_5_6;
        pub const mb_1_12 = StyledM.mb_1_12;
        pub const mb_neg_1_12 = StyledM.mb_neg_1_12;
        pub const my = StyledM.my;
        pub const my_0 = StyledM.my_0;
        pub const my_neg_0 = StyledM.my_neg_0;
        pub const my_0p5 = StyledM.my_0p5;
        pub const my_neg_0p5 = StyledM.my_neg_0p5;
        pub const my_1 = StyledM.my_1;
        pub const my_neg_1 = StyledM.my_neg_1;
        pub const my_1p5 = StyledM.my_1p5;
        pub const my_neg_1p5 = StyledM.my_neg_1p5;
        pub const my_2 = StyledM.my_2;
        pub const my_neg_2 = StyledM.my_neg_2;
        pub const my_2p5 = StyledM.my_2p5;
        pub const my_neg_2p5 = StyledM.my_neg_2p5;
        pub const my_3 = StyledM.my_3;
        pub const my_neg_3 = StyledM.my_neg_3;
        pub const my_3p5 = StyledM.my_3p5;
        pub const my_neg_3p5 = StyledM.my_neg_3p5;
        pub const my_4 = StyledM.my_4;
        pub const my_neg_4 = StyledM.my_neg_4;
        pub const my_5 = StyledM.my_5;
        pub const my_neg_5 = StyledM.my_neg_5;
        pub const my_6 = StyledM.my_6;
        pub const my_neg_6 = StyledM.my_neg_6;
        pub const my_7 = StyledM.my_7;
        pub const my_neg_7 = StyledM.my_neg_7;
        pub const my_8 = StyledM.my_8;
        pub const my_neg_8 = StyledM.my_neg_8;
        pub const my_9 = StyledM.my_9;
        pub const my_neg_9 = StyledM.my_neg_9;
        pub const my_10 = StyledM.my_10;
        pub const my_neg_10 = StyledM.my_neg_10;
        pub const my_11 = StyledM.my_11;
        pub const my_neg_11 = StyledM.my_neg_11;
        pub const my_12 = StyledM.my_12;
        pub const my_neg_12 = StyledM.my_neg_12;
        pub const my_16 = StyledM.my_16;
        pub const my_neg_16 = StyledM.my_neg_16;
        pub const my_20 = StyledM.my_20;
        pub const my_neg_20 = StyledM.my_neg_20;
        pub const my_24 = StyledM.my_24;
        pub const my_neg_24 = StyledM.my_neg_24;
        pub const my_32 = StyledM.my_32;
        pub const my_neg_32 = StyledM.my_neg_32;
        pub const my_40 = StyledM.my_40;
        pub const my_neg_40 = StyledM.my_neg_40;
        pub const my_48 = StyledM.my_48;
        pub const my_neg_48 = StyledM.my_neg_48;
        pub const my_56 = StyledM.my_56;
        pub const my_neg_56 = StyledM.my_neg_56;
        pub const my_64 = StyledM.my_64;
        pub const my_neg_64 = StyledM.my_neg_64;
        pub const my_72 = StyledM.my_72;
        pub const my_neg_72 = StyledM.my_neg_72;
        pub const my_80 = StyledM.my_80;
        pub const my_neg_80 = StyledM.my_neg_80;
        pub const my_96 = StyledM.my_96;
        pub const my_neg_96 = StyledM.my_neg_96;
        pub const my_112 = StyledM.my_112;
        pub const my_neg_112 = StyledM.my_neg_112;
        pub const my_128 = StyledM.my_128;
        pub const my_neg_128 = StyledM.my_neg_128;
        pub const my_auto = StyledM.my_auto;
        pub const my_px = StyledM.my_px;
        pub const my_neg_px = StyledM.my_neg_px;
        pub const my_full = StyledM.my_full;
        pub const my_neg_full = StyledM.my_neg_full;
        pub const my_1_2 = StyledM.my_1_2;
        pub const my_neg_1_2 = StyledM.my_neg_1_2;
        pub const my_1_3 = StyledM.my_1_3;
        pub const my_neg_1_3 = StyledM.my_neg_1_3;
        pub const my_2_3 = StyledM.my_2_3;
        pub const my_neg_2_3 = StyledM.my_neg_2_3;
        pub const my_1_4 = StyledM.my_1_4;
        pub const my_neg_1_4 = StyledM.my_neg_1_4;
        pub const my_2_4 = StyledM.my_2_4;
        pub const my_neg_2_4 = StyledM.my_neg_2_4;
        pub const my_3_4 = StyledM.my_3_4;
        pub const my_neg_3_4 = StyledM.my_neg_3_4;
        pub const my_1_5 = StyledM.my_1_5;
        pub const my_neg_1_5 = StyledM.my_neg_1_5;
        pub const my_2_5 = StyledM.my_2_5;
        pub const my_neg_2_5 = StyledM.my_neg_2_5;
        pub const my_3_5 = StyledM.my_3_5;
        pub const my_neg_3_5 = StyledM.my_neg_3_5;
        pub const my_4_5 = StyledM.my_4_5;
        pub const my_neg_4_5 = StyledM.my_neg_4_5;
        pub const my_1_6 = StyledM.my_1_6;
        pub const my_neg_1_6 = StyledM.my_neg_1_6;
        pub const my_5_6 = StyledM.my_5_6;
        pub const my_neg_5_6 = StyledM.my_neg_5_6;
        pub const my_1_12 = StyledM.my_1_12;
        pub const my_neg_1_12 = StyledM.my_neg_1_12;
        pub const mx = StyledM.mx;
        pub const mx_0 = StyledM.mx_0;
        pub const mx_neg_0 = StyledM.mx_neg_0;
        pub const mx_0p5 = StyledM.mx_0p5;
        pub const mx_neg_0p5 = StyledM.mx_neg_0p5;
        pub const mx_1 = StyledM.mx_1;
        pub const mx_neg_1 = StyledM.mx_neg_1;
        pub const mx_1p5 = StyledM.mx_1p5;
        pub const mx_neg_1p5 = StyledM.mx_neg_1p5;
        pub const mx_2 = StyledM.mx_2;
        pub const mx_neg_2 = StyledM.mx_neg_2;
        pub const mx_2p5 = StyledM.mx_2p5;
        pub const mx_neg_2p5 = StyledM.mx_neg_2p5;
        pub const mx_3 = StyledM.mx_3;
        pub const mx_neg_3 = StyledM.mx_neg_3;
        pub const mx_3p5 = StyledM.mx_3p5;
        pub const mx_neg_3p5 = StyledM.mx_neg_3p5;
        pub const mx_4 = StyledM.mx_4;
        pub const mx_neg_4 = StyledM.mx_neg_4;
        pub const mx_5 = StyledM.mx_5;
        pub const mx_neg_5 = StyledM.mx_neg_5;
        pub const mx_6 = StyledM.mx_6;
        pub const mx_neg_6 = StyledM.mx_neg_6;
        pub const mx_7 = StyledM.mx_7;
        pub const mx_neg_7 = StyledM.mx_neg_7;
        pub const mx_8 = StyledM.mx_8;
        pub const mx_neg_8 = StyledM.mx_neg_8;
        pub const mx_9 = StyledM.mx_9;
        pub const mx_neg_9 = StyledM.mx_neg_9;
        pub const mx_10 = StyledM.mx_10;
        pub const mx_neg_10 = StyledM.mx_neg_10;
        pub const mx_11 = StyledM.mx_11;
        pub const mx_neg_11 = StyledM.mx_neg_11;
        pub const mx_12 = StyledM.mx_12;
        pub const mx_neg_12 = StyledM.mx_neg_12;
        pub const mx_16 = StyledM.mx_16;
        pub const mx_neg_16 = StyledM.mx_neg_16;
        pub const mx_20 = StyledM.mx_20;
        pub const mx_neg_20 = StyledM.mx_neg_20;
        pub const mx_24 = StyledM.mx_24;
        pub const mx_neg_24 = StyledM.mx_neg_24;
        pub const mx_32 = StyledM.mx_32;
        pub const mx_neg_32 = StyledM.mx_neg_32;
        pub const mx_40 = StyledM.mx_40;
        pub const mx_neg_40 = StyledM.mx_neg_40;
        pub const mx_48 = StyledM.mx_48;
        pub const mx_neg_48 = StyledM.mx_neg_48;
        pub const mx_56 = StyledM.mx_56;
        pub const mx_neg_56 = StyledM.mx_neg_56;
        pub const mx_64 = StyledM.mx_64;
        pub const mx_neg_64 = StyledM.mx_neg_64;
        pub const mx_72 = StyledM.mx_72;
        pub const mx_neg_72 = StyledM.mx_neg_72;
        pub const mx_80 = StyledM.mx_80;
        pub const mx_neg_80 = StyledM.mx_neg_80;
        pub const mx_96 = StyledM.mx_96;
        pub const mx_neg_96 = StyledM.mx_neg_96;
        pub const mx_112 = StyledM.mx_112;
        pub const mx_neg_112 = StyledM.mx_neg_112;
        pub const mx_128 = StyledM.mx_128;
        pub const mx_neg_128 = StyledM.mx_neg_128;
        pub const mx_auto = StyledM.mx_auto;
        pub const mx_px = StyledM.mx_px;
        pub const mx_neg_px = StyledM.mx_neg_px;
        pub const mx_full = StyledM.mx_full;
        pub const mx_neg_full = StyledM.mx_neg_full;
        pub const mx_1_2 = StyledM.mx_1_2;
        pub const mx_neg_1_2 = StyledM.mx_neg_1_2;
        pub const mx_1_3 = StyledM.mx_1_3;
        pub const mx_neg_1_3 = StyledM.mx_neg_1_3;
        pub const mx_2_3 = StyledM.mx_2_3;
        pub const mx_neg_2_3 = StyledM.mx_neg_2_3;
        pub const mx_1_4 = StyledM.mx_1_4;
        pub const mx_neg_1_4 = StyledM.mx_neg_1_4;
        pub const mx_2_4 = StyledM.mx_2_4;
        pub const mx_neg_2_4 = StyledM.mx_neg_2_4;
        pub const mx_3_4 = StyledM.mx_3_4;
        pub const mx_neg_3_4 = StyledM.mx_neg_3_4;
        pub const mx_1_5 = StyledM.mx_1_5;
        pub const mx_neg_1_5 = StyledM.mx_neg_1_5;
        pub const mx_2_5 = StyledM.mx_2_5;
        pub const mx_neg_2_5 = StyledM.mx_neg_2_5;
        pub const mx_3_5 = StyledM.mx_3_5;
        pub const mx_neg_3_5 = StyledM.mx_neg_3_5;
        pub const mx_4_5 = StyledM.mx_4_5;
        pub const mx_neg_4_5 = StyledM.mx_neg_4_5;
        pub const mx_1_6 = StyledM.mx_1_6;
        pub const mx_neg_1_6 = StyledM.mx_neg_1_6;
        pub const mx_5_6 = StyledM.mx_5_6;
        pub const mx_neg_5_6 = StyledM.mx_neg_5_6;
        pub const mx_1_12 = StyledM.mx_1_12;
        pub const mx_neg_1_12 = StyledM.mx_neg_1_12;
        pub const ml = StyledM.ml;
        pub const ml_0 = StyledM.ml_0;
        pub const ml_neg_0 = StyledM.ml_neg_0;
        pub const ml_0p5 = StyledM.ml_0p5;
        pub const ml_neg_0p5 = StyledM.ml_neg_0p5;
        pub const ml_1 = StyledM.ml_1;
        pub const ml_neg_1 = StyledM.ml_neg_1;
        pub const ml_1p5 = StyledM.ml_1p5;
        pub const ml_neg_1p5 = StyledM.ml_neg_1p5;
        pub const ml_2 = StyledM.ml_2;
        pub const ml_neg_2 = StyledM.ml_neg_2;
        pub const ml_2p5 = StyledM.ml_2p5;
        pub const ml_neg_2p5 = StyledM.ml_neg_2p5;
        pub const ml_3 = StyledM.ml_3;
        pub const ml_neg_3 = StyledM.ml_neg_3;
        pub const ml_3p5 = StyledM.ml_3p5;
        pub const ml_neg_3p5 = StyledM.ml_neg_3p5;
        pub const ml_4 = StyledM.ml_4;
        pub const ml_neg_4 = StyledM.ml_neg_4;
        pub const ml_5 = StyledM.ml_5;
        pub const ml_neg_5 = StyledM.ml_neg_5;
        pub const ml_6 = StyledM.ml_6;
        pub const ml_neg_6 = StyledM.ml_neg_6;
        pub const ml_7 = StyledM.ml_7;
        pub const ml_neg_7 = StyledM.ml_neg_7;
        pub const ml_8 = StyledM.ml_8;
        pub const ml_neg_8 = StyledM.ml_neg_8;
        pub const ml_9 = StyledM.ml_9;
        pub const ml_neg_9 = StyledM.ml_neg_9;
        pub const ml_10 = StyledM.ml_10;
        pub const ml_neg_10 = StyledM.ml_neg_10;
        pub const ml_11 = StyledM.ml_11;
        pub const ml_neg_11 = StyledM.ml_neg_11;
        pub const ml_12 = StyledM.ml_12;
        pub const ml_neg_12 = StyledM.ml_neg_12;
        pub const ml_16 = StyledM.ml_16;
        pub const ml_neg_16 = StyledM.ml_neg_16;
        pub const ml_20 = StyledM.ml_20;
        pub const ml_neg_20 = StyledM.ml_neg_20;
        pub const ml_24 = StyledM.ml_24;
        pub const ml_neg_24 = StyledM.ml_neg_24;
        pub const ml_32 = StyledM.ml_32;
        pub const ml_neg_32 = StyledM.ml_neg_32;
        pub const ml_40 = StyledM.ml_40;
        pub const ml_neg_40 = StyledM.ml_neg_40;
        pub const ml_48 = StyledM.ml_48;
        pub const ml_neg_48 = StyledM.ml_neg_48;
        pub const ml_56 = StyledM.ml_56;
        pub const ml_neg_56 = StyledM.ml_neg_56;
        pub const ml_64 = StyledM.ml_64;
        pub const ml_neg_64 = StyledM.ml_neg_64;
        pub const ml_72 = StyledM.ml_72;
        pub const ml_neg_72 = StyledM.ml_neg_72;
        pub const ml_80 = StyledM.ml_80;
        pub const ml_neg_80 = StyledM.ml_neg_80;
        pub const ml_96 = StyledM.ml_96;
        pub const ml_neg_96 = StyledM.ml_neg_96;
        pub const ml_112 = StyledM.ml_112;
        pub const ml_neg_112 = StyledM.ml_neg_112;
        pub const ml_128 = StyledM.ml_128;
        pub const ml_neg_128 = StyledM.ml_neg_128;
        pub const ml_auto = StyledM.ml_auto;
        pub const ml_px = StyledM.ml_px;
        pub const ml_neg_px = StyledM.ml_neg_px;
        pub const ml_full = StyledM.ml_full;
        pub const ml_neg_full = StyledM.ml_neg_full;
        pub const ml_1_2 = StyledM.ml_1_2;
        pub const ml_neg_1_2 = StyledM.ml_neg_1_2;
        pub const ml_1_3 = StyledM.ml_1_3;
        pub const ml_neg_1_3 = StyledM.ml_neg_1_3;
        pub const ml_2_3 = StyledM.ml_2_3;
        pub const ml_neg_2_3 = StyledM.ml_neg_2_3;
        pub const ml_1_4 = StyledM.ml_1_4;
        pub const ml_neg_1_4 = StyledM.ml_neg_1_4;
        pub const ml_2_4 = StyledM.ml_2_4;
        pub const ml_neg_2_4 = StyledM.ml_neg_2_4;
        pub const ml_3_4 = StyledM.ml_3_4;
        pub const ml_neg_3_4 = StyledM.ml_neg_3_4;
        pub const ml_1_5 = StyledM.ml_1_5;
        pub const ml_neg_1_5 = StyledM.ml_neg_1_5;
        pub const ml_2_5 = StyledM.ml_2_5;
        pub const ml_neg_2_5 = StyledM.ml_neg_2_5;
        pub const ml_3_5 = StyledM.ml_3_5;
        pub const ml_neg_3_5 = StyledM.ml_neg_3_5;
        pub const ml_4_5 = StyledM.ml_4_5;
        pub const ml_neg_4_5 = StyledM.ml_neg_4_5;
        pub const ml_1_6 = StyledM.ml_1_6;
        pub const ml_neg_1_6 = StyledM.ml_neg_1_6;
        pub const ml_5_6 = StyledM.ml_5_6;
        pub const ml_neg_5_6 = StyledM.ml_neg_5_6;
        pub const ml_1_12 = StyledM.ml_1_12;
        pub const ml_neg_1_12 = StyledM.ml_neg_1_12;
        pub const mr = StyledM.mr;
        pub const mr_0 = StyledM.mr_0;
        pub const mr_neg_0 = StyledM.mr_neg_0;
        pub const mr_0p5 = StyledM.mr_0p5;
        pub const mr_neg_0p5 = StyledM.mr_neg_0p5;
        pub const mr_1 = StyledM.mr_1;
        pub const mr_neg_1 = StyledM.mr_neg_1;
        pub const mr_1p5 = StyledM.mr_1p5;
        pub const mr_neg_1p5 = StyledM.mr_neg_1p5;
        pub const mr_2 = StyledM.mr_2;
        pub const mr_neg_2 = StyledM.mr_neg_2;
        pub const mr_2p5 = StyledM.mr_2p5;
        pub const mr_neg_2p5 = StyledM.mr_neg_2p5;
        pub const mr_3 = StyledM.mr_3;
        pub const mr_neg_3 = StyledM.mr_neg_3;
        pub const mr_3p5 = StyledM.mr_3p5;
        pub const mr_neg_3p5 = StyledM.mr_neg_3p5;
        pub const mr_4 = StyledM.mr_4;
        pub const mr_neg_4 = StyledM.mr_neg_4;
        pub const mr_5 = StyledM.mr_5;
        pub const mr_neg_5 = StyledM.mr_neg_5;
        pub const mr_6 = StyledM.mr_6;
        pub const mr_neg_6 = StyledM.mr_neg_6;
        pub const mr_7 = StyledM.mr_7;
        pub const mr_neg_7 = StyledM.mr_neg_7;
        pub const mr_8 = StyledM.mr_8;
        pub const mr_neg_8 = StyledM.mr_neg_8;
        pub const mr_9 = StyledM.mr_9;
        pub const mr_neg_9 = StyledM.mr_neg_9;
        pub const mr_10 = StyledM.mr_10;
        pub const mr_neg_10 = StyledM.mr_neg_10;
        pub const mr_11 = StyledM.mr_11;
        pub const mr_neg_11 = StyledM.mr_neg_11;
        pub const mr_12 = StyledM.mr_12;
        pub const mr_neg_12 = StyledM.mr_neg_12;
        pub const mr_16 = StyledM.mr_16;
        pub const mr_neg_16 = StyledM.mr_neg_16;
        pub const mr_20 = StyledM.mr_20;
        pub const mr_neg_20 = StyledM.mr_neg_20;
        pub const mr_24 = StyledM.mr_24;
        pub const mr_neg_24 = StyledM.mr_neg_24;
        pub const mr_32 = StyledM.mr_32;
        pub const mr_neg_32 = StyledM.mr_neg_32;
        pub const mr_40 = StyledM.mr_40;
        pub const mr_neg_40 = StyledM.mr_neg_40;
        pub const mr_48 = StyledM.mr_48;
        pub const mr_neg_48 = StyledM.mr_neg_48;
        pub const mr_56 = StyledM.mr_56;
        pub const mr_neg_56 = StyledM.mr_neg_56;
        pub const mr_64 = StyledM.mr_64;
        pub const mr_neg_64 = StyledM.mr_neg_64;
        pub const mr_72 = StyledM.mr_72;
        pub const mr_neg_72 = StyledM.mr_neg_72;
        pub const mr_80 = StyledM.mr_80;
        pub const mr_neg_80 = StyledM.mr_neg_80;
        pub const mr_96 = StyledM.mr_96;
        pub const mr_neg_96 = StyledM.mr_neg_96;
        pub const mr_112 = StyledM.mr_112;
        pub const mr_neg_112 = StyledM.mr_neg_112;
        pub const mr_128 = StyledM.mr_128;
        pub const mr_neg_128 = StyledM.mr_neg_128;
        pub const mr_auto = StyledM.mr_auto;
        pub const mr_px = StyledM.mr_px;
        pub const mr_neg_px = StyledM.mr_neg_px;
        pub const mr_full = StyledM.mr_full;
        pub const mr_neg_full = StyledM.mr_neg_full;
        pub const mr_1_2 = StyledM.mr_1_2;
        pub const mr_neg_1_2 = StyledM.mr_neg_1_2;
        pub const mr_1_3 = StyledM.mr_1_3;
        pub const mr_neg_1_3 = StyledM.mr_neg_1_3;
        pub const mr_2_3 = StyledM.mr_2_3;
        pub const mr_neg_2_3 = StyledM.mr_neg_2_3;
        pub const mr_1_4 = StyledM.mr_1_4;
        pub const mr_neg_1_4 = StyledM.mr_neg_1_4;
        pub const mr_2_4 = StyledM.mr_2_4;
        pub const mr_neg_2_4 = StyledM.mr_neg_2_4;
        pub const mr_3_4 = StyledM.mr_3_4;
        pub const mr_neg_3_4 = StyledM.mr_neg_3_4;
        pub const mr_1_5 = StyledM.mr_1_5;
        pub const mr_neg_1_5 = StyledM.mr_neg_1_5;
        pub const mr_2_5 = StyledM.mr_2_5;
        pub const mr_neg_2_5 = StyledM.mr_neg_2_5;
        pub const mr_3_5 = StyledM.mr_3_5;
        pub const mr_neg_3_5 = StyledM.mr_neg_3_5;
        pub const mr_4_5 = StyledM.mr_4_5;
        pub const mr_neg_4_5 = StyledM.mr_neg_4_5;
        pub const mr_1_6 = StyledM.mr_1_6;
        pub const mr_neg_1_6 = StyledM.mr_neg_1_6;
        pub const mr_5_6 = StyledM.mr_5_6;
        pub const mr_neg_5_6 = StyledM.mr_neg_5_6;
        pub const mr_1_12 = StyledM.mr_1_12;
        pub const mr_neg_1_12 = StyledM.mr_neg_1_12;
        pub const p = StyledM.p;
        pub const p_0 = StyledM.p_0;
        pub const p_neg_0 = StyledM.p_neg_0;
        pub const p_0p5 = StyledM.p_0p5;
        pub const p_neg_0p5 = StyledM.p_neg_0p5;
        pub const p_1 = StyledM.p_1;
        pub const p_neg_1 = StyledM.p_neg_1;
        pub const p_1p5 = StyledM.p_1p5;
        pub const p_neg_1p5 = StyledM.p_neg_1p5;
        pub const p_2 = StyledM.p_2;
        pub const p_neg_2 = StyledM.p_neg_2;
        pub const p_2p5 = StyledM.p_2p5;
        pub const p_neg_2p5 = StyledM.p_neg_2p5;
        pub const p_3 = StyledM.p_3;
        pub const p_neg_3 = StyledM.p_neg_3;
        pub const p_3p5 = StyledM.p_3p5;
        pub const p_neg_3p5 = StyledM.p_neg_3p5;
        pub const p_4 = StyledM.p_4;
        pub const p_neg_4 = StyledM.p_neg_4;
        pub const p_5 = StyledM.p_5;
        pub const p_neg_5 = StyledM.p_neg_5;
        pub const p_6 = StyledM.p_6;
        pub const p_neg_6 = StyledM.p_neg_6;
        pub const p_7 = StyledM.p_7;
        pub const p_neg_7 = StyledM.p_neg_7;
        pub const p_8 = StyledM.p_8;
        pub const p_neg_8 = StyledM.p_neg_8;
        pub const p_9 = StyledM.p_9;
        pub const p_neg_9 = StyledM.p_neg_9;
        pub const p_10 = StyledM.p_10;
        pub const p_neg_10 = StyledM.p_neg_10;
        pub const p_11 = StyledM.p_11;
        pub const p_neg_11 = StyledM.p_neg_11;
        pub const p_12 = StyledM.p_12;
        pub const p_neg_12 = StyledM.p_neg_12;
        pub const p_16 = StyledM.p_16;
        pub const p_neg_16 = StyledM.p_neg_16;
        pub const p_20 = StyledM.p_20;
        pub const p_neg_20 = StyledM.p_neg_20;
        pub const p_24 = StyledM.p_24;
        pub const p_neg_24 = StyledM.p_neg_24;
        pub const p_32 = StyledM.p_32;
        pub const p_neg_32 = StyledM.p_neg_32;
        pub const p_40 = StyledM.p_40;
        pub const p_neg_40 = StyledM.p_neg_40;
        pub const p_48 = StyledM.p_48;
        pub const p_neg_48 = StyledM.p_neg_48;
        pub const p_56 = StyledM.p_56;
        pub const p_neg_56 = StyledM.p_neg_56;
        pub const p_64 = StyledM.p_64;
        pub const p_neg_64 = StyledM.p_neg_64;
        pub const p_72 = StyledM.p_72;
        pub const p_neg_72 = StyledM.p_neg_72;
        pub const p_80 = StyledM.p_80;
        pub const p_neg_80 = StyledM.p_neg_80;
        pub const p_96 = StyledM.p_96;
        pub const p_neg_96 = StyledM.p_neg_96;
        pub const p_112 = StyledM.p_112;
        pub const p_neg_112 = StyledM.p_neg_112;
        pub const p_128 = StyledM.p_128;
        pub const p_neg_128 = StyledM.p_neg_128;
        pub const p_px = StyledM.p_px;
        pub const p_neg_px = StyledM.p_neg_px;
        pub const p_full = StyledM.p_full;
        pub const p_neg_full = StyledM.p_neg_full;
        pub const p_1_2 = StyledM.p_1_2;
        pub const p_neg_1_2 = StyledM.p_neg_1_2;
        pub const p_1_3 = StyledM.p_1_3;
        pub const p_neg_1_3 = StyledM.p_neg_1_3;
        pub const p_2_3 = StyledM.p_2_3;
        pub const p_neg_2_3 = StyledM.p_neg_2_3;
        pub const p_1_4 = StyledM.p_1_4;
        pub const p_neg_1_4 = StyledM.p_neg_1_4;
        pub const p_2_4 = StyledM.p_2_4;
        pub const p_neg_2_4 = StyledM.p_neg_2_4;
        pub const p_3_4 = StyledM.p_3_4;
        pub const p_neg_3_4 = StyledM.p_neg_3_4;
        pub const p_1_5 = StyledM.p_1_5;
        pub const p_neg_1_5 = StyledM.p_neg_1_5;
        pub const p_2_5 = StyledM.p_2_5;
        pub const p_neg_2_5 = StyledM.p_neg_2_5;
        pub const p_3_5 = StyledM.p_3_5;
        pub const p_neg_3_5 = StyledM.p_neg_3_5;
        pub const p_4_5 = StyledM.p_4_5;
        pub const p_neg_4_5 = StyledM.p_neg_4_5;
        pub const p_1_6 = StyledM.p_1_6;
        pub const p_neg_1_6 = StyledM.p_neg_1_6;
        pub const p_5_6 = StyledM.p_5_6;
        pub const p_neg_5_6 = StyledM.p_neg_5_6;
        pub const p_1_12 = StyledM.p_1_12;
        pub const p_neg_1_12 = StyledM.p_neg_1_12;
        pub const pt = StyledM.pt;
        pub const pt_0 = StyledM.pt_0;
        pub const pt_neg_0 = StyledM.pt_neg_0;
        pub const pt_0p5 = StyledM.pt_0p5;
        pub const pt_neg_0p5 = StyledM.pt_neg_0p5;
        pub const pt_1 = StyledM.pt_1;
        pub const pt_neg_1 = StyledM.pt_neg_1;
        pub const pt_1p5 = StyledM.pt_1p5;
        pub const pt_neg_1p5 = StyledM.pt_neg_1p5;
        pub const pt_2 = StyledM.pt_2;
        pub const pt_neg_2 = StyledM.pt_neg_2;
        pub const pt_2p5 = StyledM.pt_2p5;
        pub const pt_neg_2p5 = StyledM.pt_neg_2p5;
        pub const pt_3 = StyledM.pt_3;
        pub const pt_neg_3 = StyledM.pt_neg_3;
        pub const pt_3p5 = StyledM.pt_3p5;
        pub const pt_neg_3p5 = StyledM.pt_neg_3p5;
        pub const pt_4 = StyledM.pt_4;
        pub const pt_neg_4 = StyledM.pt_neg_4;
        pub const pt_5 = StyledM.pt_5;
        pub const pt_neg_5 = StyledM.pt_neg_5;
        pub const pt_6 = StyledM.pt_6;
        pub const pt_neg_6 = StyledM.pt_neg_6;
        pub const pt_7 = StyledM.pt_7;
        pub const pt_neg_7 = StyledM.pt_neg_7;
        pub const pt_8 = StyledM.pt_8;
        pub const pt_neg_8 = StyledM.pt_neg_8;
        pub const pt_9 = StyledM.pt_9;
        pub const pt_neg_9 = StyledM.pt_neg_9;
        pub const pt_10 = StyledM.pt_10;
        pub const pt_neg_10 = StyledM.pt_neg_10;
        pub const pt_11 = StyledM.pt_11;
        pub const pt_neg_11 = StyledM.pt_neg_11;
        pub const pt_12 = StyledM.pt_12;
        pub const pt_neg_12 = StyledM.pt_neg_12;
        pub const pt_16 = StyledM.pt_16;
        pub const pt_neg_16 = StyledM.pt_neg_16;
        pub const pt_20 = StyledM.pt_20;
        pub const pt_neg_20 = StyledM.pt_neg_20;
        pub const pt_24 = StyledM.pt_24;
        pub const pt_neg_24 = StyledM.pt_neg_24;
        pub const pt_32 = StyledM.pt_32;
        pub const pt_neg_32 = StyledM.pt_neg_32;
        pub const pt_40 = StyledM.pt_40;
        pub const pt_neg_40 = StyledM.pt_neg_40;
        pub const pt_48 = StyledM.pt_48;
        pub const pt_neg_48 = StyledM.pt_neg_48;
        pub const pt_56 = StyledM.pt_56;
        pub const pt_neg_56 = StyledM.pt_neg_56;
        pub const pt_64 = StyledM.pt_64;
        pub const pt_neg_64 = StyledM.pt_neg_64;
        pub const pt_72 = StyledM.pt_72;
        pub const pt_neg_72 = StyledM.pt_neg_72;
        pub const pt_80 = StyledM.pt_80;
        pub const pt_neg_80 = StyledM.pt_neg_80;
        pub const pt_96 = StyledM.pt_96;
        pub const pt_neg_96 = StyledM.pt_neg_96;
        pub const pt_112 = StyledM.pt_112;
        pub const pt_neg_112 = StyledM.pt_neg_112;
        pub const pt_128 = StyledM.pt_128;
        pub const pt_neg_128 = StyledM.pt_neg_128;
        pub const pt_px = StyledM.pt_px;
        pub const pt_neg_px = StyledM.pt_neg_px;
        pub const pt_full = StyledM.pt_full;
        pub const pt_neg_full = StyledM.pt_neg_full;
        pub const pt_1_2 = StyledM.pt_1_2;
        pub const pt_neg_1_2 = StyledM.pt_neg_1_2;
        pub const pt_1_3 = StyledM.pt_1_3;
        pub const pt_neg_1_3 = StyledM.pt_neg_1_3;
        pub const pt_2_3 = StyledM.pt_2_3;
        pub const pt_neg_2_3 = StyledM.pt_neg_2_3;
        pub const pt_1_4 = StyledM.pt_1_4;
        pub const pt_neg_1_4 = StyledM.pt_neg_1_4;
        pub const pt_2_4 = StyledM.pt_2_4;
        pub const pt_neg_2_4 = StyledM.pt_neg_2_4;
        pub const pt_3_4 = StyledM.pt_3_4;
        pub const pt_neg_3_4 = StyledM.pt_neg_3_4;
        pub const pt_1_5 = StyledM.pt_1_5;
        pub const pt_neg_1_5 = StyledM.pt_neg_1_5;
        pub const pt_2_5 = StyledM.pt_2_5;
        pub const pt_neg_2_5 = StyledM.pt_neg_2_5;
        pub const pt_3_5 = StyledM.pt_3_5;
        pub const pt_neg_3_5 = StyledM.pt_neg_3_5;
        pub const pt_4_5 = StyledM.pt_4_5;
        pub const pt_neg_4_5 = StyledM.pt_neg_4_5;
        pub const pt_1_6 = StyledM.pt_1_6;
        pub const pt_neg_1_6 = StyledM.pt_neg_1_6;
        pub const pt_5_6 = StyledM.pt_5_6;
        pub const pt_neg_5_6 = StyledM.pt_neg_5_6;
        pub const pt_1_12 = StyledM.pt_1_12;
        pub const pt_neg_1_12 = StyledM.pt_neg_1_12;
        pub const pb = StyledM.pb;
        pub const pb_0 = StyledM.pb_0;
        pub const pb_neg_0 = StyledM.pb_neg_0;
        pub const pb_0p5 = StyledM.pb_0p5;
        pub const pb_neg_0p5 = StyledM.pb_neg_0p5;
        pub const pb_1 = StyledM.pb_1;
        pub const pb_neg_1 = StyledM.pb_neg_1;
        pub const pb_1p5 = StyledM.pb_1p5;
        pub const pb_neg_1p5 = StyledM.pb_neg_1p5;
        pub const pb_2 = StyledM.pb_2;
        pub const pb_neg_2 = StyledM.pb_neg_2;
        pub const pb_2p5 = StyledM.pb_2p5;
        pub const pb_neg_2p5 = StyledM.pb_neg_2p5;
        pub const pb_3 = StyledM.pb_3;
        pub const pb_neg_3 = StyledM.pb_neg_3;
        pub const pb_3p5 = StyledM.pb_3p5;
        pub const pb_neg_3p5 = StyledM.pb_neg_3p5;
        pub const pb_4 = StyledM.pb_4;
        pub const pb_neg_4 = StyledM.pb_neg_4;
        pub const pb_5 = StyledM.pb_5;
        pub const pb_neg_5 = StyledM.pb_neg_5;
        pub const pb_6 = StyledM.pb_6;
        pub const pb_neg_6 = StyledM.pb_neg_6;
        pub const pb_7 = StyledM.pb_7;
        pub const pb_neg_7 = StyledM.pb_neg_7;
        pub const pb_8 = StyledM.pb_8;
        pub const pb_neg_8 = StyledM.pb_neg_8;
        pub const pb_9 = StyledM.pb_9;
        pub const pb_neg_9 = StyledM.pb_neg_9;
        pub const pb_10 = StyledM.pb_10;
        pub const pb_neg_10 = StyledM.pb_neg_10;
        pub const pb_11 = StyledM.pb_11;
        pub const pb_neg_11 = StyledM.pb_neg_11;
        pub const pb_12 = StyledM.pb_12;
        pub const pb_neg_12 = StyledM.pb_neg_12;
        pub const pb_16 = StyledM.pb_16;
        pub const pb_neg_16 = StyledM.pb_neg_16;
        pub const pb_20 = StyledM.pb_20;
        pub const pb_neg_20 = StyledM.pb_neg_20;
        pub const pb_24 = StyledM.pb_24;
        pub const pb_neg_24 = StyledM.pb_neg_24;
        pub const pb_32 = StyledM.pb_32;
        pub const pb_neg_32 = StyledM.pb_neg_32;
        pub const pb_40 = StyledM.pb_40;
        pub const pb_neg_40 = StyledM.pb_neg_40;
        pub const pb_48 = StyledM.pb_48;
        pub const pb_neg_48 = StyledM.pb_neg_48;
        pub const pb_56 = StyledM.pb_56;
        pub const pb_neg_56 = StyledM.pb_neg_56;
        pub const pb_64 = StyledM.pb_64;
        pub const pb_neg_64 = StyledM.pb_neg_64;
        pub const pb_72 = StyledM.pb_72;
        pub const pb_neg_72 = StyledM.pb_neg_72;
        pub const pb_80 = StyledM.pb_80;
        pub const pb_neg_80 = StyledM.pb_neg_80;
        pub const pb_96 = StyledM.pb_96;
        pub const pb_neg_96 = StyledM.pb_neg_96;
        pub const pb_112 = StyledM.pb_112;
        pub const pb_neg_112 = StyledM.pb_neg_112;
        pub const pb_128 = StyledM.pb_128;
        pub const pb_neg_128 = StyledM.pb_neg_128;
        pub const pb_px = StyledM.pb_px;
        pub const pb_neg_px = StyledM.pb_neg_px;
        pub const pb_full = StyledM.pb_full;
        pub const pb_neg_full = StyledM.pb_neg_full;
        pub const pb_1_2 = StyledM.pb_1_2;
        pub const pb_neg_1_2 = StyledM.pb_neg_1_2;
        pub const pb_1_3 = StyledM.pb_1_3;
        pub const pb_neg_1_3 = StyledM.pb_neg_1_3;
        pub const pb_2_3 = StyledM.pb_2_3;
        pub const pb_neg_2_3 = StyledM.pb_neg_2_3;
        pub const pb_1_4 = StyledM.pb_1_4;
        pub const pb_neg_1_4 = StyledM.pb_neg_1_4;
        pub const pb_2_4 = StyledM.pb_2_4;
        pub const pb_neg_2_4 = StyledM.pb_neg_2_4;
        pub const pb_3_4 = StyledM.pb_3_4;
        pub const pb_neg_3_4 = StyledM.pb_neg_3_4;
        pub const pb_1_5 = StyledM.pb_1_5;
        pub const pb_neg_1_5 = StyledM.pb_neg_1_5;
        pub const pb_2_5 = StyledM.pb_2_5;
        pub const pb_neg_2_5 = StyledM.pb_neg_2_5;
        pub const pb_3_5 = StyledM.pb_3_5;
        pub const pb_neg_3_5 = StyledM.pb_neg_3_5;
        pub const pb_4_5 = StyledM.pb_4_5;
        pub const pb_neg_4_5 = StyledM.pb_neg_4_5;
        pub const pb_1_6 = StyledM.pb_1_6;
        pub const pb_neg_1_6 = StyledM.pb_neg_1_6;
        pub const pb_5_6 = StyledM.pb_5_6;
        pub const pb_neg_5_6 = StyledM.pb_neg_5_6;
        pub const pb_1_12 = StyledM.pb_1_12;
        pub const pb_neg_1_12 = StyledM.pb_neg_1_12;
        pub const px = StyledM.px;
        pub const px_0 = StyledM.px_0;
        pub const px_neg_0 = StyledM.px_neg_0;
        pub const px_0p5 = StyledM.px_0p5;
        pub const px_neg_0p5 = StyledM.px_neg_0p5;
        pub const px_1 = StyledM.px_1;
        pub const px_neg_1 = StyledM.px_neg_1;
        pub const px_1p5 = StyledM.px_1p5;
        pub const px_neg_1p5 = StyledM.px_neg_1p5;
        pub const px_2 = StyledM.px_2;
        pub const px_neg_2 = StyledM.px_neg_2;
        pub const px_2p5 = StyledM.px_2p5;
        pub const px_neg_2p5 = StyledM.px_neg_2p5;
        pub const px_3 = StyledM.px_3;
        pub const px_neg_3 = StyledM.px_neg_3;
        pub const px_3p5 = StyledM.px_3p5;
        pub const px_neg_3p5 = StyledM.px_neg_3p5;
        pub const px_4 = StyledM.px_4;
        pub const px_neg_4 = StyledM.px_neg_4;
        pub const px_5 = StyledM.px_5;
        pub const px_neg_5 = StyledM.px_neg_5;
        pub const px_6 = StyledM.px_6;
        pub const px_neg_6 = StyledM.px_neg_6;
        pub const px_7 = StyledM.px_7;
        pub const px_neg_7 = StyledM.px_neg_7;
        pub const px_8 = StyledM.px_8;
        pub const px_neg_8 = StyledM.px_neg_8;
        pub const px_9 = StyledM.px_9;
        pub const px_neg_9 = StyledM.px_neg_9;
        pub const px_10 = StyledM.px_10;
        pub const px_neg_10 = StyledM.px_neg_10;
        pub const px_11 = StyledM.px_11;
        pub const px_neg_11 = StyledM.px_neg_11;
        pub const px_12 = StyledM.px_12;
        pub const px_neg_12 = StyledM.px_neg_12;
        pub const px_16 = StyledM.px_16;
        pub const px_neg_16 = StyledM.px_neg_16;
        pub const px_20 = StyledM.px_20;
        pub const px_neg_20 = StyledM.px_neg_20;
        pub const px_24 = StyledM.px_24;
        pub const px_neg_24 = StyledM.px_neg_24;
        pub const px_32 = StyledM.px_32;
        pub const px_neg_32 = StyledM.px_neg_32;
        pub const px_40 = StyledM.px_40;
        pub const px_neg_40 = StyledM.px_neg_40;
        pub const px_48 = StyledM.px_48;
        pub const px_neg_48 = StyledM.px_neg_48;
        pub const px_56 = StyledM.px_56;
        pub const px_neg_56 = StyledM.px_neg_56;
        pub const px_64 = StyledM.px_64;
        pub const px_neg_64 = StyledM.px_neg_64;
        pub const px_72 = StyledM.px_72;
        pub const px_neg_72 = StyledM.px_neg_72;
        pub const px_80 = StyledM.px_80;
        pub const px_neg_80 = StyledM.px_neg_80;
        pub const px_96 = StyledM.px_96;
        pub const px_neg_96 = StyledM.px_neg_96;
        pub const px_112 = StyledM.px_112;
        pub const px_neg_112 = StyledM.px_neg_112;
        pub const px_128 = StyledM.px_128;
        pub const px_neg_128 = StyledM.px_neg_128;
        pub const px_px = StyledM.px_px;
        pub const px_neg_px = StyledM.px_neg_px;
        pub const px_full = StyledM.px_full;
        pub const px_neg_full = StyledM.px_neg_full;
        pub const px_1_2 = StyledM.px_1_2;
        pub const px_neg_1_2 = StyledM.px_neg_1_2;
        pub const px_1_3 = StyledM.px_1_3;
        pub const px_neg_1_3 = StyledM.px_neg_1_3;
        pub const px_2_3 = StyledM.px_2_3;
        pub const px_neg_2_3 = StyledM.px_neg_2_3;
        pub const px_1_4 = StyledM.px_1_4;
        pub const px_neg_1_4 = StyledM.px_neg_1_4;
        pub const px_2_4 = StyledM.px_2_4;
        pub const px_neg_2_4 = StyledM.px_neg_2_4;
        pub const px_3_4 = StyledM.px_3_4;
        pub const px_neg_3_4 = StyledM.px_neg_3_4;
        pub const px_1_5 = StyledM.px_1_5;
        pub const px_neg_1_5 = StyledM.px_neg_1_5;
        pub const px_2_5 = StyledM.px_2_5;
        pub const px_neg_2_5 = StyledM.px_neg_2_5;
        pub const px_3_5 = StyledM.px_3_5;
        pub const px_neg_3_5 = StyledM.px_neg_3_5;
        pub const px_4_5 = StyledM.px_4_5;
        pub const px_neg_4_5 = StyledM.px_neg_4_5;
        pub const px_1_6 = StyledM.px_1_6;
        pub const px_neg_1_6 = StyledM.px_neg_1_6;
        pub const px_5_6 = StyledM.px_5_6;
        pub const px_neg_5_6 = StyledM.px_neg_5_6;
        pub const px_1_12 = StyledM.px_1_12;
        pub const px_neg_1_12 = StyledM.px_neg_1_12;
        pub const py = StyledM.py;
        pub const py_0 = StyledM.py_0;
        pub const py_neg_0 = StyledM.py_neg_0;
        pub const py_0p5 = StyledM.py_0p5;
        pub const py_neg_0p5 = StyledM.py_neg_0p5;
        pub const py_1 = StyledM.py_1;
        pub const py_neg_1 = StyledM.py_neg_1;
        pub const py_1p5 = StyledM.py_1p5;
        pub const py_neg_1p5 = StyledM.py_neg_1p5;
        pub const py_2 = StyledM.py_2;
        pub const py_neg_2 = StyledM.py_neg_2;
        pub const py_2p5 = StyledM.py_2p5;
        pub const py_neg_2p5 = StyledM.py_neg_2p5;
        pub const py_3 = StyledM.py_3;
        pub const py_neg_3 = StyledM.py_neg_3;
        pub const py_3p5 = StyledM.py_3p5;
        pub const py_neg_3p5 = StyledM.py_neg_3p5;
        pub const py_4 = StyledM.py_4;
        pub const py_neg_4 = StyledM.py_neg_4;
        pub const py_5 = StyledM.py_5;
        pub const py_neg_5 = StyledM.py_neg_5;
        pub const py_6 = StyledM.py_6;
        pub const py_neg_6 = StyledM.py_neg_6;
        pub const py_7 = StyledM.py_7;
        pub const py_neg_7 = StyledM.py_neg_7;
        pub const py_8 = StyledM.py_8;
        pub const py_neg_8 = StyledM.py_neg_8;
        pub const py_9 = StyledM.py_9;
        pub const py_neg_9 = StyledM.py_neg_9;
        pub const py_10 = StyledM.py_10;
        pub const py_neg_10 = StyledM.py_neg_10;
        pub const py_11 = StyledM.py_11;
        pub const py_neg_11 = StyledM.py_neg_11;
        pub const py_12 = StyledM.py_12;
        pub const py_neg_12 = StyledM.py_neg_12;
        pub const py_16 = StyledM.py_16;
        pub const py_neg_16 = StyledM.py_neg_16;
        pub const py_20 = StyledM.py_20;
        pub const py_neg_20 = StyledM.py_neg_20;
        pub const py_24 = StyledM.py_24;
        pub const py_neg_24 = StyledM.py_neg_24;
        pub const py_32 = StyledM.py_32;
        pub const py_neg_32 = StyledM.py_neg_32;
        pub const py_40 = StyledM.py_40;
        pub const py_neg_40 = StyledM.py_neg_40;
        pub const py_48 = StyledM.py_48;
        pub const py_neg_48 = StyledM.py_neg_48;
        pub const py_56 = StyledM.py_56;
        pub const py_neg_56 = StyledM.py_neg_56;
        pub const py_64 = StyledM.py_64;
        pub const py_neg_64 = StyledM.py_neg_64;
        pub const py_72 = StyledM.py_72;
        pub const py_neg_72 = StyledM.py_neg_72;
        pub const py_80 = StyledM.py_80;
        pub const py_neg_80 = StyledM.py_neg_80;
        pub const py_96 = StyledM.py_96;
        pub const py_neg_96 = StyledM.py_neg_96;
        pub const py_112 = StyledM.py_112;
        pub const py_neg_112 = StyledM.py_neg_112;
        pub const py_128 = StyledM.py_128;
        pub const py_neg_128 = StyledM.py_neg_128;
        pub const py_px = StyledM.py_px;
        pub const py_neg_px = StyledM.py_neg_px;
        pub const py_full = StyledM.py_full;
        pub const py_neg_full = StyledM.py_neg_full;
        pub const py_1_2 = StyledM.py_1_2;
        pub const py_neg_1_2 = StyledM.py_neg_1_2;
        pub const py_1_3 = StyledM.py_1_3;
        pub const py_neg_1_3 = StyledM.py_neg_1_3;
        pub const py_2_3 = StyledM.py_2_3;
        pub const py_neg_2_3 = StyledM.py_neg_2_3;
        pub const py_1_4 = StyledM.py_1_4;
        pub const py_neg_1_4 = StyledM.py_neg_1_4;
        pub const py_2_4 = StyledM.py_2_4;
        pub const py_neg_2_4 = StyledM.py_neg_2_4;
        pub const py_3_4 = StyledM.py_3_4;
        pub const py_neg_3_4 = StyledM.py_neg_3_4;
        pub const py_1_5 = StyledM.py_1_5;
        pub const py_neg_1_5 = StyledM.py_neg_1_5;
        pub const py_2_5 = StyledM.py_2_5;
        pub const py_neg_2_5 = StyledM.py_neg_2_5;
        pub const py_3_5 = StyledM.py_3_5;
        pub const py_neg_3_5 = StyledM.py_neg_3_5;
        pub const py_4_5 = StyledM.py_4_5;
        pub const py_neg_4_5 = StyledM.py_neg_4_5;
        pub const py_1_6 = StyledM.py_1_6;
        pub const py_neg_1_6 = StyledM.py_neg_1_6;
        pub const py_5_6 = StyledM.py_5_6;
        pub const py_neg_5_6 = StyledM.py_neg_5_6;
        pub const py_1_12 = StyledM.py_1_12;
        pub const py_neg_1_12 = StyledM.py_neg_1_12;
        pub const pl = StyledM.pl;
        pub const pl_0 = StyledM.pl_0;
        pub const pl_neg_0 = StyledM.pl_neg_0;
        pub const pl_0p5 = StyledM.pl_0p5;
        pub const pl_neg_0p5 = StyledM.pl_neg_0p5;
        pub const pl_1 = StyledM.pl_1;
        pub const pl_neg_1 = StyledM.pl_neg_1;
        pub const pl_1p5 = StyledM.pl_1p5;
        pub const pl_neg_1p5 = StyledM.pl_neg_1p5;
        pub const pl_2 = StyledM.pl_2;
        pub const pl_neg_2 = StyledM.pl_neg_2;
        pub const pl_2p5 = StyledM.pl_2p5;
        pub const pl_neg_2p5 = StyledM.pl_neg_2p5;
        pub const pl_3 = StyledM.pl_3;
        pub const pl_neg_3 = StyledM.pl_neg_3;
        pub const pl_3p5 = StyledM.pl_3p5;
        pub const pl_neg_3p5 = StyledM.pl_neg_3p5;
        pub const pl_4 = StyledM.pl_4;
        pub const pl_neg_4 = StyledM.pl_neg_4;
        pub const pl_5 = StyledM.pl_5;
        pub const pl_neg_5 = StyledM.pl_neg_5;
        pub const pl_6 = StyledM.pl_6;
        pub const pl_neg_6 = StyledM.pl_neg_6;
        pub const pl_7 = StyledM.pl_7;
        pub const pl_neg_7 = StyledM.pl_neg_7;
        pub const pl_8 = StyledM.pl_8;
        pub const pl_neg_8 = StyledM.pl_neg_8;
        pub const pl_9 = StyledM.pl_9;
        pub const pl_neg_9 = StyledM.pl_neg_9;
        pub const pl_10 = StyledM.pl_10;
        pub const pl_neg_10 = StyledM.pl_neg_10;
        pub const pl_11 = StyledM.pl_11;
        pub const pl_neg_11 = StyledM.pl_neg_11;
        pub const pl_12 = StyledM.pl_12;
        pub const pl_neg_12 = StyledM.pl_neg_12;
        pub const pl_16 = StyledM.pl_16;
        pub const pl_neg_16 = StyledM.pl_neg_16;
        pub const pl_20 = StyledM.pl_20;
        pub const pl_neg_20 = StyledM.pl_neg_20;
        pub const pl_24 = StyledM.pl_24;
        pub const pl_neg_24 = StyledM.pl_neg_24;
        pub const pl_32 = StyledM.pl_32;
        pub const pl_neg_32 = StyledM.pl_neg_32;
        pub const pl_40 = StyledM.pl_40;
        pub const pl_neg_40 = StyledM.pl_neg_40;
        pub const pl_48 = StyledM.pl_48;
        pub const pl_neg_48 = StyledM.pl_neg_48;
        pub const pl_56 = StyledM.pl_56;
        pub const pl_neg_56 = StyledM.pl_neg_56;
        pub const pl_64 = StyledM.pl_64;
        pub const pl_neg_64 = StyledM.pl_neg_64;
        pub const pl_72 = StyledM.pl_72;
        pub const pl_neg_72 = StyledM.pl_neg_72;
        pub const pl_80 = StyledM.pl_80;
        pub const pl_neg_80 = StyledM.pl_neg_80;
        pub const pl_96 = StyledM.pl_96;
        pub const pl_neg_96 = StyledM.pl_neg_96;
        pub const pl_112 = StyledM.pl_112;
        pub const pl_neg_112 = StyledM.pl_neg_112;
        pub const pl_128 = StyledM.pl_128;
        pub const pl_neg_128 = StyledM.pl_neg_128;
        pub const pl_px = StyledM.pl_px;
        pub const pl_neg_px = StyledM.pl_neg_px;
        pub const pl_full = StyledM.pl_full;
        pub const pl_neg_full = StyledM.pl_neg_full;
        pub const pl_1_2 = StyledM.pl_1_2;
        pub const pl_neg_1_2 = StyledM.pl_neg_1_2;
        pub const pl_1_3 = StyledM.pl_1_3;
        pub const pl_neg_1_3 = StyledM.pl_neg_1_3;
        pub const pl_2_3 = StyledM.pl_2_3;
        pub const pl_neg_2_3 = StyledM.pl_neg_2_3;
        pub const pl_1_4 = StyledM.pl_1_4;
        pub const pl_neg_1_4 = StyledM.pl_neg_1_4;
        pub const pl_2_4 = StyledM.pl_2_4;
        pub const pl_neg_2_4 = StyledM.pl_neg_2_4;
        pub const pl_3_4 = StyledM.pl_3_4;
        pub const pl_neg_3_4 = StyledM.pl_neg_3_4;
        pub const pl_1_5 = StyledM.pl_1_5;
        pub const pl_neg_1_5 = StyledM.pl_neg_1_5;
        pub const pl_2_5 = StyledM.pl_2_5;
        pub const pl_neg_2_5 = StyledM.pl_neg_2_5;
        pub const pl_3_5 = StyledM.pl_3_5;
        pub const pl_neg_3_5 = StyledM.pl_neg_3_5;
        pub const pl_4_5 = StyledM.pl_4_5;
        pub const pl_neg_4_5 = StyledM.pl_neg_4_5;
        pub const pl_1_6 = StyledM.pl_1_6;
        pub const pl_neg_1_6 = StyledM.pl_neg_1_6;
        pub const pl_5_6 = StyledM.pl_5_6;
        pub const pl_neg_5_6 = StyledM.pl_neg_5_6;
        pub const pl_1_12 = StyledM.pl_1_12;
        pub const pl_neg_1_12 = StyledM.pl_neg_1_12;
        pub const pr = StyledM.pr;
        pub const pr_0 = StyledM.pr_0;
        pub const pr_neg_0 = StyledM.pr_neg_0;
        pub const pr_0p5 = StyledM.pr_0p5;
        pub const pr_neg_0p5 = StyledM.pr_neg_0p5;
        pub const pr_1 = StyledM.pr_1;
        pub const pr_neg_1 = StyledM.pr_neg_1;
        pub const pr_1p5 = StyledM.pr_1p5;
        pub const pr_neg_1p5 = StyledM.pr_neg_1p5;
        pub const pr_2 = StyledM.pr_2;
        pub const pr_neg_2 = StyledM.pr_neg_2;
        pub const pr_2p5 = StyledM.pr_2p5;
        pub const pr_neg_2p5 = StyledM.pr_neg_2p5;
        pub const pr_3 = StyledM.pr_3;
        pub const pr_neg_3 = StyledM.pr_neg_3;
        pub const pr_3p5 = StyledM.pr_3p5;
        pub const pr_neg_3p5 = StyledM.pr_neg_3p5;
        pub const pr_4 = StyledM.pr_4;
        pub const pr_neg_4 = StyledM.pr_neg_4;
        pub const pr_5 = StyledM.pr_5;
        pub const pr_neg_5 = StyledM.pr_neg_5;
        pub const pr_6 = StyledM.pr_6;
        pub const pr_neg_6 = StyledM.pr_neg_6;
        pub const pr_7 = StyledM.pr_7;
        pub const pr_neg_7 = StyledM.pr_neg_7;
        pub const pr_8 = StyledM.pr_8;
        pub const pr_neg_8 = StyledM.pr_neg_8;
        pub const pr_9 = StyledM.pr_9;
        pub const pr_neg_9 = StyledM.pr_neg_9;
        pub const pr_10 = StyledM.pr_10;
        pub const pr_neg_10 = StyledM.pr_neg_10;
        pub const pr_11 = StyledM.pr_11;
        pub const pr_neg_11 = StyledM.pr_neg_11;
        pub const pr_12 = StyledM.pr_12;
        pub const pr_neg_12 = StyledM.pr_neg_12;
        pub const pr_16 = StyledM.pr_16;
        pub const pr_neg_16 = StyledM.pr_neg_16;
        pub const pr_20 = StyledM.pr_20;
        pub const pr_neg_20 = StyledM.pr_neg_20;
        pub const pr_24 = StyledM.pr_24;
        pub const pr_neg_24 = StyledM.pr_neg_24;
        pub const pr_32 = StyledM.pr_32;
        pub const pr_neg_32 = StyledM.pr_neg_32;
        pub const pr_40 = StyledM.pr_40;
        pub const pr_neg_40 = StyledM.pr_neg_40;
        pub const pr_48 = StyledM.pr_48;
        pub const pr_neg_48 = StyledM.pr_neg_48;
        pub const pr_56 = StyledM.pr_56;
        pub const pr_neg_56 = StyledM.pr_neg_56;
        pub const pr_64 = StyledM.pr_64;
        pub const pr_neg_64 = StyledM.pr_neg_64;
        pub const pr_72 = StyledM.pr_72;
        pub const pr_neg_72 = StyledM.pr_neg_72;
        pub const pr_80 = StyledM.pr_80;
        pub const pr_neg_80 = StyledM.pr_neg_80;
        pub const pr_96 = StyledM.pr_96;
        pub const pr_neg_96 = StyledM.pr_neg_96;
        pub const pr_112 = StyledM.pr_112;
        pub const pr_neg_112 = StyledM.pr_neg_112;
        pub const pr_128 = StyledM.pr_128;
        pub const pr_neg_128 = StyledM.pr_neg_128;
        pub const pr_px = StyledM.pr_px;
        pub const pr_neg_px = StyledM.pr_neg_px;
        pub const pr_full = StyledM.pr_full;
        pub const pr_neg_full = StyledM.pr_neg_full;
        pub const pr_1_2 = StyledM.pr_1_2;
        pub const pr_neg_1_2 = StyledM.pr_neg_1_2;
        pub const pr_1_3 = StyledM.pr_1_3;
        pub const pr_neg_1_3 = StyledM.pr_neg_1_3;
        pub const pr_2_3 = StyledM.pr_2_3;
        pub const pr_neg_2_3 = StyledM.pr_neg_2_3;
        pub const pr_1_4 = StyledM.pr_1_4;
        pub const pr_neg_1_4 = StyledM.pr_neg_1_4;
        pub const pr_2_4 = StyledM.pr_2_4;
        pub const pr_neg_2_4 = StyledM.pr_neg_2_4;
        pub const pr_3_4 = StyledM.pr_3_4;
        pub const pr_neg_3_4 = StyledM.pr_neg_3_4;
        pub const pr_1_5 = StyledM.pr_1_5;
        pub const pr_neg_1_5 = StyledM.pr_neg_1_5;
        pub const pr_2_5 = StyledM.pr_2_5;
        pub const pr_neg_2_5 = StyledM.pr_neg_2_5;
        pub const pr_3_5 = StyledM.pr_3_5;
        pub const pr_neg_3_5 = StyledM.pr_neg_3_5;
        pub const pr_4_5 = StyledM.pr_4_5;
        pub const pr_neg_4_5 = StyledM.pr_neg_4_5;
        pub const pr_1_6 = StyledM.pr_1_6;
        pub const pr_neg_1_6 = StyledM.pr_neg_1_6;
        pub const pr_5_6 = StyledM.pr_5_6;
        pub const pr_neg_5_6 = StyledM.pr_neg_5_6;
        pub const pr_1_12 = StyledM.pr_1_12;
        pub const pr_neg_1_12 = StyledM.pr_neg_1_12;
        pub const inset = StyledM.inset;
        pub const inset_0 = StyledM.inset_0;
        pub const inset_neg_0 = StyledM.inset_neg_0;
        pub const inset_0p5 = StyledM.inset_0p5;
        pub const inset_neg_0p5 = StyledM.inset_neg_0p5;
        pub const inset_1 = StyledM.inset_1;
        pub const inset_neg_1 = StyledM.inset_neg_1;
        pub const inset_1p5 = StyledM.inset_1p5;
        pub const inset_neg_1p5 = StyledM.inset_neg_1p5;
        pub const inset_2 = StyledM.inset_2;
        pub const inset_neg_2 = StyledM.inset_neg_2;
        pub const inset_2p5 = StyledM.inset_2p5;
        pub const inset_neg_2p5 = StyledM.inset_neg_2p5;
        pub const inset_3 = StyledM.inset_3;
        pub const inset_neg_3 = StyledM.inset_neg_3;
        pub const inset_3p5 = StyledM.inset_3p5;
        pub const inset_neg_3p5 = StyledM.inset_neg_3p5;
        pub const inset_4 = StyledM.inset_4;
        pub const inset_neg_4 = StyledM.inset_neg_4;
        pub const inset_5 = StyledM.inset_5;
        pub const inset_neg_5 = StyledM.inset_neg_5;
        pub const inset_6 = StyledM.inset_6;
        pub const inset_neg_6 = StyledM.inset_neg_6;
        pub const inset_7 = StyledM.inset_7;
        pub const inset_neg_7 = StyledM.inset_neg_7;
        pub const inset_8 = StyledM.inset_8;
        pub const inset_neg_8 = StyledM.inset_neg_8;
        pub const inset_9 = StyledM.inset_9;
        pub const inset_neg_9 = StyledM.inset_neg_9;
        pub const inset_10 = StyledM.inset_10;
        pub const inset_neg_10 = StyledM.inset_neg_10;
        pub const inset_11 = StyledM.inset_11;
        pub const inset_neg_11 = StyledM.inset_neg_11;
        pub const inset_12 = StyledM.inset_12;
        pub const inset_neg_12 = StyledM.inset_neg_12;
        pub const inset_16 = StyledM.inset_16;
        pub const inset_neg_16 = StyledM.inset_neg_16;
        pub const inset_20 = StyledM.inset_20;
        pub const inset_neg_20 = StyledM.inset_neg_20;
        pub const inset_24 = StyledM.inset_24;
        pub const inset_neg_24 = StyledM.inset_neg_24;
        pub const inset_32 = StyledM.inset_32;
        pub const inset_neg_32 = StyledM.inset_neg_32;
        pub const inset_40 = StyledM.inset_40;
        pub const inset_neg_40 = StyledM.inset_neg_40;
        pub const inset_48 = StyledM.inset_48;
        pub const inset_neg_48 = StyledM.inset_neg_48;
        pub const inset_56 = StyledM.inset_56;
        pub const inset_neg_56 = StyledM.inset_neg_56;
        pub const inset_64 = StyledM.inset_64;
        pub const inset_neg_64 = StyledM.inset_neg_64;
        pub const inset_72 = StyledM.inset_72;
        pub const inset_neg_72 = StyledM.inset_neg_72;
        pub const inset_80 = StyledM.inset_80;
        pub const inset_neg_80 = StyledM.inset_neg_80;
        pub const inset_96 = StyledM.inset_96;
        pub const inset_neg_96 = StyledM.inset_neg_96;
        pub const inset_112 = StyledM.inset_112;
        pub const inset_neg_112 = StyledM.inset_neg_112;
        pub const inset_128 = StyledM.inset_128;
        pub const inset_neg_128 = StyledM.inset_neg_128;
        pub const inset_auto = StyledM.inset_auto;
        pub const inset_px = StyledM.inset_px;
        pub const inset_neg_px = StyledM.inset_neg_px;
        pub const inset_full = StyledM.inset_full;
        pub const inset_neg_full = StyledM.inset_neg_full;
        pub const inset_1_2 = StyledM.inset_1_2;
        pub const inset_neg_1_2 = StyledM.inset_neg_1_2;
        pub const inset_1_3 = StyledM.inset_1_3;
        pub const inset_neg_1_3 = StyledM.inset_neg_1_3;
        pub const inset_2_3 = StyledM.inset_2_3;
        pub const inset_neg_2_3 = StyledM.inset_neg_2_3;
        pub const inset_1_4 = StyledM.inset_1_4;
        pub const inset_neg_1_4 = StyledM.inset_neg_1_4;
        pub const inset_2_4 = StyledM.inset_2_4;
        pub const inset_neg_2_4 = StyledM.inset_neg_2_4;
        pub const inset_3_4 = StyledM.inset_3_4;
        pub const inset_neg_3_4 = StyledM.inset_neg_3_4;
        pub const inset_1_5 = StyledM.inset_1_5;
        pub const inset_neg_1_5 = StyledM.inset_neg_1_5;
        pub const inset_2_5 = StyledM.inset_2_5;
        pub const inset_neg_2_5 = StyledM.inset_neg_2_5;
        pub const inset_3_5 = StyledM.inset_3_5;
        pub const inset_neg_3_5 = StyledM.inset_neg_3_5;
        pub const inset_4_5 = StyledM.inset_4_5;
        pub const inset_neg_4_5 = StyledM.inset_neg_4_5;
        pub const inset_1_6 = StyledM.inset_1_6;
        pub const inset_neg_1_6 = StyledM.inset_neg_1_6;
        pub const inset_5_6 = StyledM.inset_5_6;
        pub const inset_neg_5_6 = StyledM.inset_neg_5_6;
        pub const inset_1_12 = StyledM.inset_1_12;
        pub const inset_neg_1_12 = StyledM.inset_neg_1_12;
        pub const top = StyledM.top;
        pub const top_0 = StyledM.top_0;
        pub const top_neg_0 = StyledM.top_neg_0;
        pub const top_0p5 = StyledM.top_0p5;
        pub const top_neg_0p5 = StyledM.top_neg_0p5;
        pub const top_1 = StyledM.top_1;
        pub const top_neg_1 = StyledM.top_neg_1;
        pub const top_1p5 = StyledM.top_1p5;
        pub const top_neg_1p5 = StyledM.top_neg_1p5;
        pub const top_2 = StyledM.top_2;
        pub const top_neg_2 = StyledM.top_neg_2;
        pub const top_2p5 = StyledM.top_2p5;
        pub const top_neg_2p5 = StyledM.top_neg_2p5;
        pub const top_3 = StyledM.top_3;
        pub const top_neg_3 = StyledM.top_neg_3;
        pub const top_3p5 = StyledM.top_3p5;
        pub const top_neg_3p5 = StyledM.top_neg_3p5;
        pub const top_4 = StyledM.top_4;
        pub const top_neg_4 = StyledM.top_neg_4;
        pub const top_5 = StyledM.top_5;
        pub const top_neg_5 = StyledM.top_neg_5;
        pub const top_6 = StyledM.top_6;
        pub const top_neg_6 = StyledM.top_neg_6;
        pub const top_7 = StyledM.top_7;
        pub const top_neg_7 = StyledM.top_neg_7;
        pub const top_8 = StyledM.top_8;
        pub const top_neg_8 = StyledM.top_neg_8;
        pub const top_9 = StyledM.top_9;
        pub const top_neg_9 = StyledM.top_neg_9;
        pub const top_10 = StyledM.top_10;
        pub const top_neg_10 = StyledM.top_neg_10;
        pub const top_11 = StyledM.top_11;
        pub const top_neg_11 = StyledM.top_neg_11;
        pub const top_12 = StyledM.top_12;
        pub const top_neg_12 = StyledM.top_neg_12;
        pub const top_16 = StyledM.top_16;
        pub const top_neg_16 = StyledM.top_neg_16;
        pub const top_20 = StyledM.top_20;
        pub const top_neg_20 = StyledM.top_neg_20;
        pub const top_24 = StyledM.top_24;
        pub const top_neg_24 = StyledM.top_neg_24;
        pub const top_32 = StyledM.top_32;
        pub const top_neg_32 = StyledM.top_neg_32;
        pub const top_40 = StyledM.top_40;
        pub const top_neg_40 = StyledM.top_neg_40;
        pub const top_48 = StyledM.top_48;
        pub const top_neg_48 = StyledM.top_neg_48;
        pub const top_56 = StyledM.top_56;
        pub const top_neg_56 = StyledM.top_neg_56;
        pub const top_64 = StyledM.top_64;
        pub const top_neg_64 = StyledM.top_neg_64;
        pub const top_72 = StyledM.top_72;
        pub const top_neg_72 = StyledM.top_neg_72;
        pub const top_80 = StyledM.top_80;
        pub const top_neg_80 = StyledM.top_neg_80;
        pub const top_96 = StyledM.top_96;
        pub const top_neg_96 = StyledM.top_neg_96;
        pub const top_112 = StyledM.top_112;
        pub const top_neg_112 = StyledM.top_neg_112;
        pub const top_128 = StyledM.top_128;
        pub const top_neg_128 = StyledM.top_neg_128;
        pub const top_auto = StyledM.top_auto;
        pub const top_px = StyledM.top_px;
        pub const top_neg_px = StyledM.top_neg_px;
        pub const top_full = StyledM.top_full;
        pub const top_neg_full = StyledM.top_neg_full;
        pub const top_1_2 = StyledM.top_1_2;
        pub const top_neg_1_2 = StyledM.top_neg_1_2;
        pub const top_1_3 = StyledM.top_1_3;
        pub const top_neg_1_3 = StyledM.top_neg_1_3;
        pub const top_2_3 = StyledM.top_2_3;
        pub const top_neg_2_3 = StyledM.top_neg_2_3;
        pub const top_1_4 = StyledM.top_1_4;
        pub const top_neg_1_4 = StyledM.top_neg_1_4;
        pub const top_2_4 = StyledM.top_2_4;
        pub const top_neg_2_4 = StyledM.top_neg_2_4;
        pub const top_3_4 = StyledM.top_3_4;
        pub const top_neg_3_4 = StyledM.top_neg_3_4;
        pub const top_1_5 = StyledM.top_1_5;
        pub const top_neg_1_5 = StyledM.top_neg_1_5;
        pub const top_2_5 = StyledM.top_2_5;
        pub const top_neg_2_5 = StyledM.top_neg_2_5;
        pub const top_3_5 = StyledM.top_3_5;
        pub const top_neg_3_5 = StyledM.top_neg_3_5;
        pub const top_4_5 = StyledM.top_4_5;
        pub const top_neg_4_5 = StyledM.top_neg_4_5;
        pub const top_1_6 = StyledM.top_1_6;
        pub const top_neg_1_6 = StyledM.top_neg_1_6;
        pub const top_5_6 = StyledM.top_5_6;
        pub const top_neg_5_6 = StyledM.top_neg_5_6;
        pub const top_1_12 = StyledM.top_1_12;
        pub const top_neg_1_12 = StyledM.top_neg_1_12;
        pub const bottom = StyledM.bottom;
        pub const bottom_0 = StyledM.bottom_0;
        pub const bottom_neg_0 = StyledM.bottom_neg_0;
        pub const bottom_0p5 = StyledM.bottom_0p5;
        pub const bottom_neg_0p5 = StyledM.bottom_neg_0p5;
        pub const bottom_1 = StyledM.bottom_1;
        pub const bottom_neg_1 = StyledM.bottom_neg_1;
        pub const bottom_1p5 = StyledM.bottom_1p5;
        pub const bottom_neg_1p5 = StyledM.bottom_neg_1p5;
        pub const bottom_2 = StyledM.bottom_2;
        pub const bottom_neg_2 = StyledM.bottom_neg_2;
        pub const bottom_2p5 = StyledM.bottom_2p5;
        pub const bottom_neg_2p5 = StyledM.bottom_neg_2p5;
        pub const bottom_3 = StyledM.bottom_3;
        pub const bottom_neg_3 = StyledM.bottom_neg_3;
        pub const bottom_3p5 = StyledM.bottom_3p5;
        pub const bottom_neg_3p5 = StyledM.bottom_neg_3p5;
        pub const bottom_4 = StyledM.bottom_4;
        pub const bottom_neg_4 = StyledM.bottom_neg_4;
        pub const bottom_5 = StyledM.bottom_5;
        pub const bottom_neg_5 = StyledM.bottom_neg_5;
        pub const bottom_6 = StyledM.bottom_6;
        pub const bottom_neg_6 = StyledM.bottom_neg_6;
        pub const bottom_7 = StyledM.bottom_7;
        pub const bottom_neg_7 = StyledM.bottom_neg_7;
        pub const bottom_8 = StyledM.bottom_8;
        pub const bottom_neg_8 = StyledM.bottom_neg_8;
        pub const bottom_9 = StyledM.bottom_9;
        pub const bottom_neg_9 = StyledM.bottom_neg_9;
        pub const bottom_10 = StyledM.bottom_10;
        pub const bottom_neg_10 = StyledM.bottom_neg_10;
        pub const bottom_11 = StyledM.bottom_11;
        pub const bottom_neg_11 = StyledM.bottom_neg_11;
        pub const bottom_12 = StyledM.bottom_12;
        pub const bottom_neg_12 = StyledM.bottom_neg_12;
        pub const bottom_16 = StyledM.bottom_16;
        pub const bottom_neg_16 = StyledM.bottom_neg_16;
        pub const bottom_20 = StyledM.bottom_20;
        pub const bottom_neg_20 = StyledM.bottom_neg_20;
        pub const bottom_24 = StyledM.bottom_24;
        pub const bottom_neg_24 = StyledM.bottom_neg_24;
        pub const bottom_32 = StyledM.bottom_32;
        pub const bottom_neg_32 = StyledM.bottom_neg_32;
        pub const bottom_40 = StyledM.bottom_40;
        pub const bottom_neg_40 = StyledM.bottom_neg_40;
        pub const bottom_48 = StyledM.bottom_48;
        pub const bottom_neg_48 = StyledM.bottom_neg_48;
        pub const bottom_56 = StyledM.bottom_56;
        pub const bottom_neg_56 = StyledM.bottom_neg_56;
        pub const bottom_64 = StyledM.bottom_64;
        pub const bottom_neg_64 = StyledM.bottom_neg_64;
        pub const bottom_72 = StyledM.bottom_72;
        pub const bottom_neg_72 = StyledM.bottom_neg_72;
        pub const bottom_80 = StyledM.bottom_80;
        pub const bottom_neg_80 = StyledM.bottom_neg_80;
        pub const bottom_96 = StyledM.bottom_96;
        pub const bottom_neg_96 = StyledM.bottom_neg_96;
        pub const bottom_112 = StyledM.bottom_112;
        pub const bottom_neg_112 = StyledM.bottom_neg_112;
        pub const bottom_128 = StyledM.bottom_128;
        pub const bottom_neg_128 = StyledM.bottom_neg_128;
        pub const bottom_auto = StyledM.bottom_auto;
        pub const bottom_px = StyledM.bottom_px;
        pub const bottom_neg_px = StyledM.bottom_neg_px;
        pub const bottom_full = StyledM.bottom_full;
        pub const bottom_neg_full = StyledM.bottom_neg_full;
        pub const bottom_1_2 = StyledM.bottom_1_2;
        pub const bottom_neg_1_2 = StyledM.bottom_neg_1_2;
        pub const bottom_1_3 = StyledM.bottom_1_3;
        pub const bottom_neg_1_3 = StyledM.bottom_neg_1_3;
        pub const bottom_2_3 = StyledM.bottom_2_3;
        pub const bottom_neg_2_3 = StyledM.bottom_neg_2_3;
        pub const bottom_1_4 = StyledM.bottom_1_4;
        pub const bottom_neg_1_4 = StyledM.bottom_neg_1_4;
        pub const bottom_2_4 = StyledM.bottom_2_4;
        pub const bottom_neg_2_4 = StyledM.bottom_neg_2_4;
        pub const bottom_3_4 = StyledM.bottom_3_4;
        pub const bottom_neg_3_4 = StyledM.bottom_neg_3_4;
        pub const bottom_1_5 = StyledM.bottom_1_5;
        pub const bottom_neg_1_5 = StyledM.bottom_neg_1_5;
        pub const bottom_2_5 = StyledM.bottom_2_5;
        pub const bottom_neg_2_5 = StyledM.bottom_neg_2_5;
        pub const bottom_3_5 = StyledM.bottom_3_5;
        pub const bottom_neg_3_5 = StyledM.bottom_neg_3_5;
        pub const bottom_4_5 = StyledM.bottom_4_5;
        pub const bottom_neg_4_5 = StyledM.bottom_neg_4_5;
        pub const bottom_1_6 = StyledM.bottom_1_6;
        pub const bottom_neg_1_6 = StyledM.bottom_neg_1_6;
        pub const bottom_5_6 = StyledM.bottom_5_6;
        pub const bottom_neg_5_6 = StyledM.bottom_neg_5_6;
        pub const bottom_1_12 = StyledM.bottom_1_12;
        pub const bottom_neg_1_12 = StyledM.bottom_neg_1_12;
        pub const left = StyledM.left;
        pub const left_0 = StyledM.left_0;
        pub const left_neg_0 = StyledM.left_neg_0;
        pub const left_0p5 = StyledM.left_0p5;
        pub const left_neg_0p5 = StyledM.left_neg_0p5;
        pub const left_1 = StyledM.left_1;
        pub const left_neg_1 = StyledM.left_neg_1;
        pub const left_1p5 = StyledM.left_1p5;
        pub const left_neg_1p5 = StyledM.left_neg_1p5;
        pub const left_2 = StyledM.left_2;
        pub const left_neg_2 = StyledM.left_neg_2;
        pub const left_2p5 = StyledM.left_2p5;
        pub const left_neg_2p5 = StyledM.left_neg_2p5;
        pub const left_3 = StyledM.left_3;
        pub const left_neg_3 = StyledM.left_neg_3;
        pub const left_3p5 = StyledM.left_3p5;
        pub const left_neg_3p5 = StyledM.left_neg_3p5;
        pub const left_4 = StyledM.left_4;
        pub const left_neg_4 = StyledM.left_neg_4;
        pub const left_5 = StyledM.left_5;
        pub const left_neg_5 = StyledM.left_neg_5;
        pub const left_6 = StyledM.left_6;
        pub const left_neg_6 = StyledM.left_neg_6;
        pub const left_7 = StyledM.left_7;
        pub const left_neg_7 = StyledM.left_neg_7;
        pub const left_8 = StyledM.left_8;
        pub const left_neg_8 = StyledM.left_neg_8;
        pub const left_9 = StyledM.left_9;
        pub const left_neg_9 = StyledM.left_neg_9;
        pub const left_10 = StyledM.left_10;
        pub const left_neg_10 = StyledM.left_neg_10;
        pub const left_11 = StyledM.left_11;
        pub const left_neg_11 = StyledM.left_neg_11;
        pub const left_12 = StyledM.left_12;
        pub const left_neg_12 = StyledM.left_neg_12;
        pub const left_16 = StyledM.left_16;
        pub const left_neg_16 = StyledM.left_neg_16;
        pub const left_20 = StyledM.left_20;
        pub const left_neg_20 = StyledM.left_neg_20;
        pub const left_24 = StyledM.left_24;
        pub const left_neg_24 = StyledM.left_neg_24;
        pub const left_32 = StyledM.left_32;
        pub const left_neg_32 = StyledM.left_neg_32;
        pub const left_40 = StyledM.left_40;
        pub const left_neg_40 = StyledM.left_neg_40;
        pub const left_48 = StyledM.left_48;
        pub const left_neg_48 = StyledM.left_neg_48;
        pub const left_56 = StyledM.left_56;
        pub const left_neg_56 = StyledM.left_neg_56;
        pub const left_64 = StyledM.left_64;
        pub const left_neg_64 = StyledM.left_neg_64;
        pub const left_72 = StyledM.left_72;
        pub const left_neg_72 = StyledM.left_neg_72;
        pub const left_80 = StyledM.left_80;
        pub const left_neg_80 = StyledM.left_neg_80;
        pub const left_96 = StyledM.left_96;
        pub const left_neg_96 = StyledM.left_neg_96;
        pub const left_112 = StyledM.left_112;
        pub const left_neg_112 = StyledM.left_neg_112;
        pub const left_128 = StyledM.left_128;
        pub const left_neg_128 = StyledM.left_neg_128;
        pub const left_auto = StyledM.left_auto;
        pub const left_px = StyledM.left_px;
        pub const left_neg_px = StyledM.left_neg_px;
        pub const left_full = StyledM.left_full;
        pub const left_neg_full = StyledM.left_neg_full;
        pub const left_1_2 = StyledM.left_1_2;
        pub const left_neg_1_2 = StyledM.left_neg_1_2;
        pub const left_1_3 = StyledM.left_1_3;
        pub const left_neg_1_3 = StyledM.left_neg_1_3;
        pub const left_2_3 = StyledM.left_2_3;
        pub const left_neg_2_3 = StyledM.left_neg_2_3;
        pub const left_1_4 = StyledM.left_1_4;
        pub const left_neg_1_4 = StyledM.left_neg_1_4;
        pub const left_2_4 = StyledM.left_2_4;
        pub const left_neg_2_4 = StyledM.left_neg_2_4;
        pub const left_3_4 = StyledM.left_3_4;
        pub const left_neg_3_4 = StyledM.left_neg_3_4;
        pub const left_1_5 = StyledM.left_1_5;
        pub const left_neg_1_5 = StyledM.left_neg_1_5;
        pub const left_2_5 = StyledM.left_2_5;
        pub const left_neg_2_5 = StyledM.left_neg_2_5;
        pub const left_3_5 = StyledM.left_3_5;
        pub const left_neg_3_5 = StyledM.left_neg_3_5;
        pub const left_4_5 = StyledM.left_4_5;
        pub const left_neg_4_5 = StyledM.left_neg_4_5;
        pub const left_1_6 = StyledM.left_1_6;
        pub const left_neg_1_6 = StyledM.left_neg_1_6;
        pub const left_5_6 = StyledM.left_5_6;
        pub const left_neg_5_6 = StyledM.left_neg_5_6;
        pub const left_1_12 = StyledM.left_1_12;
        pub const left_neg_1_12 = StyledM.left_neg_1_12;
        pub const right = StyledM.right;
        pub const right_0 = StyledM.right_0;
        pub const right_neg_0 = StyledM.right_neg_0;
        pub const right_0p5 = StyledM.right_0p5;
        pub const right_neg_0p5 = StyledM.right_neg_0p5;
        pub const right_1 = StyledM.right_1;
        pub const right_neg_1 = StyledM.right_neg_1;
        pub const right_1p5 = StyledM.right_1p5;
        pub const right_neg_1p5 = StyledM.right_neg_1p5;
        pub const right_2 = StyledM.right_2;
        pub const right_neg_2 = StyledM.right_neg_2;
        pub const right_2p5 = StyledM.right_2p5;
        pub const right_neg_2p5 = StyledM.right_neg_2p5;
        pub const right_3 = StyledM.right_3;
        pub const right_neg_3 = StyledM.right_neg_3;
        pub const right_3p5 = StyledM.right_3p5;
        pub const right_neg_3p5 = StyledM.right_neg_3p5;
        pub const right_4 = StyledM.right_4;
        pub const right_neg_4 = StyledM.right_neg_4;
        pub const right_5 = StyledM.right_5;
        pub const right_neg_5 = StyledM.right_neg_5;
        pub const right_6 = StyledM.right_6;
        pub const right_neg_6 = StyledM.right_neg_6;
        pub const right_7 = StyledM.right_7;
        pub const right_neg_7 = StyledM.right_neg_7;
        pub const right_8 = StyledM.right_8;
        pub const right_neg_8 = StyledM.right_neg_8;
        pub const right_9 = StyledM.right_9;
        pub const right_neg_9 = StyledM.right_neg_9;
        pub const right_10 = StyledM.right_10;
        pub const right_neg_10 = StyledM.right_neg_10;
        pub const right_11 = StyledM.right_11;
        pub const right_neg_11 = StyledM.right_neg_11;
        pub const right_12 = StyledM.right_12;
        pub const right_neg_12 = StyledM.right_neg_12;
        pub const right_16 = StyledM.right_16;
        pub const right_neg_16 = StyledM.right_neg_16;
        pub const right_20 = StyledM.right_20;
        pub const right_neg_20 = StyledM.right_neg_20;
        pub const right_24 = StyledM.right_24;
        pub const right_neg_24 = StyledM.right_neg_24;
        pub const right_32 = StyledM.right_32;
        pub const right_neg_32 = StyledM.right_neg_32;
        pub const right_40 = StyledM.right_40;
        pub const right_neg_40 = StyledM.right_neg_40;
        pub const right_48 = StyledM.right_48;
        pub const right_neg_48 = StyledM.right_neg_48;
        pub const right_56 = StyledM.right_56;
        pub const right_neg_56 = StyledM.right_neg_56;
        pub const right_64 = StyledM.right_64;
        pub const right_neg_64 = StyledM.right_neg_64;
        pub const right_72 = StyledM.right_72;
        pub const right_neg_72 = StyledM.right_neg_72;
        pub const right_80 = StyledM.right_80;
        pub const right_neg_80 = StyledM.right_neg_80;
        pub const right_96 = StyledM.right_96;
        pub const right_neg_96 = StyledM.right_neg_96;
        pub const right_112 = StyledM.right_112;
        pub const right_neg_112 = StyledM.right_neg_112;
        pub const right_128 = StyledM.right_128;
        pub const right_neg_128 = StyledM.right_neg_128;
        pub const right_auto = StyledM.right_auto;
        pub const right_px = StyledM.right_px;
        pub const right_neg_px = StyledM.right_neg_px;
        pub const right_full = StyledM.right_full;
        pub const right_neg_full = StyledM.right_neg_full;
        pub const right_1_2 = StyledM.right_1_2;
        pub const right_neg_1_2 = StyledM.right_neg_1_2;
        pub const right_1_3 = StyledM.right_1_3;
        pub const right_neg_1_3 = StyledM.right_neg_1_3;
        pub const right_2_3 = StyledM.right_2_3;
        pub const right_neg_2_3 = StyledM.right_neg_2_3;
        pub const right_1_4 = StyledM.right_1_4;
        pub const right_neg_1_4 = StyledM.right_neg_1_4;
        pub const right_2_4 = StyledM.right_2_4;
        pub const right_neg_2_4 = StyledM.right_neg_2_4;
        pub const right_3_4 = StyledM.right_3_4;
        pub const right_neg_3_4 = StyledM.right_neg_3_4;
        pub const right_1_5 = StyledM.right_1_5;
        pub const right_neg_1_5 = StyledM.right_neg_1_5;
        pub const right_2_5 = StyledM.right_2_5;
        pub const right_neg_2_5 = StyledM.right_neg_2_5;
        pub const right_3_5 = StyledM.right_3_5;
        pub const right_neg_3_5 = StyledM.right_neg_3_5;
        pub const right_4_5 = StyledM.right_4_5;
        pub const right_neg_4_5 = StyledM.right_neg_4_5;
        pub const right_1_6 = StyledM.right_1_6;
        pub const right_neg_1_6 = StyledM.right_neg_1_6;
        pub const right_5_6 = StyledM.right_5_6;
        pub const right_neg_5_6 = StyledM.right_neg_5_6;
        pub const right_1_12 = StyledM.right_1_12;
        pub const right_neg_1_12 = StyledM.right_neg_1_12;
        pub const w = StyledM.w;
        pub const w_0 = StyledM.w_0;
        pub const w_neg_0 = StyledM.w_neg_0;
        pub const w_0p5 = StyledM.w_0p5;
        pub const w_neg_0p5 = StyledM.w_neg_0p5;
        pub const w_1 = StyledM.w_1;
        pub const w_neg_1 = StyledM.w_neg_1;
        pub const w_1p5 = StyledM.w_1p5;
        pub const w_neg_1p5 = StyledM.w_neg_1p5;
        pub const w_2 = StyledM.w_2;
        pub const w_neg_2 = StyledM.w_neg_2;
        pub const w_2p5 = StyledM.w_2p5;
        pub const w_neg_2p5 = StyledM.w_neg_2p5;
        pub const w_3 = StyledM.w_3;
        pub const w_neg_3 = StyledM.w_neg_3;
        pub const w_3p5 = StyledM.w_3p5;
        pub const w_neg_3p5 = StyledM.w_neg_3p5;
        pub const w_4 = StyledM.w_4;
        pub const w_neg_4 = StyledM.w_neg_4;
        pub const w_5 = StyledM.w_5;
        pub const w_neg_5 = StyledM.w_neg_5;
        pub const w_6 = StyledM.w_6;
        pub const w_neg_6 = StyledM.w_neg_6;
        pub const w_7 = StyledM.w_7;
        pub const w_neg_7 = StyledM.w_neg_7;
        pub const w_8 = StyledM.w_8;
        pub const w_neg_8 = StyledM.w_neg_8;
        pub const w_9 = StyledM.w_9;
        pub const w_neg_9 = StyledM.w_neg_9;
        pub const w_10 = StyledM.w_10;
        pub const w_neg_10 = StyledM.w_neg_10;
        pub const w_11 = StyledM.w_11;
        pub const w_neg_11 = StyledM.w_neg_11;
        pub const w_12 = StyledM.w_12;
        pub const w_neg_12 = StyledM.w_neg_12;
        pub const w_16 = StyledM.w_16;
        pub const w_neg_16 = StyledM.w_neg_16;
        pub const w_20 = StyledM.w_20;
        pub const w_neg_20 = StyledM.w_neg_20;
        pub const w_24 = StyledM.w_24;
        pub const w_neg_24 = StyledM.w_neg_24;
        pub const w_32 = StyledM.w_32;
        pub const w_neg_32 = StyledM.w_neg_32;
        pub const w_40 = StyledM.w_40;
        pub const w_neg_40 = StyledM.w_neg_40;
        pub const w_48 = StyledM.w_48;
        pub const w_neg_48 = StyledM.w_neg_48;
        pub const w_56 = StyledM.w_56;
        pub const w_neg_56 = StyledM.w_neg_56;
        pub const w_64 = StyledM.w_64;
        pub const w_neg_64 = StyledM.w_neg_64;
        pub const w_72 = StyledM.w_72;
        pub const w_neg_72 = StyledM.w_neg_72;
        pub const w_80 = StyledM.w_80;
        pub const w_neg_80 = StyledM.w_neg_80;
        pub const w_96 = StyledM.w_96;
        pub const w_neg_96 = StyledM.w_neg_96;
        pub const w_112 = StyledM.w_112;
        pub const w_neg_112 = StyledM.w_neg_112;
        pub const w_128 = StyledM.w_128;
        pub const w_neg_128 = StyledM.w_neg_128;
        pub const w_auto = StyledM.w_auto;
        pub const w_px = StyledM.w_px;
        pub const w_neg_px = StyledM.w_neg_px;
        pub const w_full = StyledM.w_full;
        pub const w_neg_full = StyledM.w_neg_full;
        pub const w_1_2 = StyledM.w_1_2;
        pub const w_neg_1_2 = StyledM.w_neg_1_2;
        pub const w_1_3 = StyledM.w_1_3;
        pub const w_neg_1_3 = StyledM.w_neg_1_3;
        pub const w_2_3 = StyledM.w_2_3;
        pub const w_neg_2_3 = StyledM.w_neg_2_3;
        pub const w_1_4 = StyledM.w_1_4;
        pub const w_neg_1_4 = StyledM.w_neg_1_4;
        pub const w_2_4 = StyledM.w_2_4;
        pub const w_neg_2_4 = StyledM.w_neg_2_4;
        pub const w_3_4 = StyledM.w_3_4;
        pub const w_neg_3_4 = StyledM.w_neg_3_4;
        pub const w_1_5 = StyledM.w_1_5;
        pub const w_neg_1_5 = StyledM.w_neg_1_5;
        pub const w_2_5 = StyledM.w_2_5;
        pub const w_neg_2_5 = StyledM.w_neg_2_5;
        pub const w_3_5 = StyledM.w_3_5;
        pub const w_neg_3_5 = StyledM.w_neg_3_5;
        pub const w_4_5 = StyledM.w_4_5;
        pub const w_neg_4_5 = StyledM.w_neg_4_5;
        pub const w_1_6 = StyledM.w_1_6;
        pub const w_neg_1_6 = StyledM.w_neg_1_6;
        pub const w_5_6 = StyledM.w_5_6;
        pub const w_neg_5_6 = StyledM.w_neg_5_6;
        pub const w_1_12 = StyledM.w_1_12;
        pub const w_neg_1_12 = StyledM.w_neg_1_12;
        pub const h = StyledM.h;
        pub const h_0 = StyledM.h_0;
        pub const h_neg_0 = StyledM.h_neg_0;
        pub const h_0p5 = StyledM.h_0p5;
        pub const h_neg_0p5 = StyledM.h_neg_0p5;
        pub const h_1 = StyledM.h_1;
        pub const h_neg_1 = StyledM.h_neg_1;
        pub const h_1p5 = StyledM.h_1p5;
        pub const h_neg_1p5 = StyledM.h_neg_1p5;
        pub const h_2 = StyledM.h_2;
        pub const h_neg_2 = StyledM.h_neg_2;
        pub const h_2p5 = StyledM.h_2p5;
        pub const h_neg_2p5 = StyledM.h_neg_2p5;
        pub const h_3 = StyledM.h_3;
        pub const h_neg_3 = StyledM.h_neg_3;
        pub const h_3p5 = StyledM.h_3p5;
        pub const h_neg_3p5 = StyledM.h_neg_3p5;
        pub const h_4 = StyledM.h_4;
        pub const h_neg_4 = StyledM.h_neg_4;
        pub const h_5 = StyledM.h_5;
        pub const h_neg_5 = StyledM.h_neg_5;
        pub const h_6 = StyledM.h_6;
        pub const h_neg_6 = StyledM.h_neg_6;
        pub const h_7 = StyledM.h_7;
        pub const h_neg_7 = StyledM.h_neg_7;
        pub const h_8 = StyledM.h_8;
        pub const h_neg_8 = StyledM.h_neg_8;
        pub const h_9 = StyledM.h_9;
        pub const h_neg_9 = StyledM.h_neg_9;
        pub const h_10 = StyledM.h_10;
        pub const h_neg_10 = StyledM.h_neg_10;
        pub const h_11 = StyledM.h_11;
        pub const h_neg_11 = StyledM.h_neg_11;
        pub const h_12 = StyledM.h_12;
        pub const h_neg_12 = StyledM.h_neg_12;
        pub const h_16 = StyledM.h_16;
        pub const h_neg_16 = StyledM.h_neg_16;
        pub const h_20 = StyledM.h_20;
        pub const h_neg_20 = StyledM.h_neg_20;
        pub const h_24 = StyledM.h_24;
        pub const h_neg_24 = StyledM.h_neg_24;
        pub const h_32 = StyledM.h_32;
        pub const h_neg_32 = StyledM.h_neg_32;
        pub const h_40 = StyledM.h_40;
        pub const h_neg_40 = StyledM.h_neg_40;
        pub const h_48 = StyledM.h_48;
        pub const h_neg_48 = StyledM.h_neg_48;
        pub const h_56 = StyledM.h_56;
        pub const h_neg_56 = StyledM.h_neg_56;
        pub const h_64 = StyledM.h_64;
        pub const h_neg_64 = StyledM.h_neg_64;
        pub const h_72 = StyledM.h_72;
        pub const h_neg_72 = StyledM.h_neg_72;
        pub const h_80 = StyledM.h_80;
        pub const h_neg_80 = StyledM.h_neg_80;
        pub const h_96 = StyledM.h_96;
        pub const h_neg_96 = StyledM.h_neg_96;
        pub const h_112 = StyledM.h_112;
        pub const h_neg_112 = StyledM.h_neg_112;
        pub const h_128 = StyledM.h_128;
        pub const h_neg_128 = StyledM.h_neg_128;
        pub const h_auto = StyledM.h_auto;
        pub const h_px = StyledM.h_px;
        pub const h_neg_px = StyledM.h_neg_px;
        pub const h_full = StyledM.h_full;
        pub const h_neg_full = StyledM.h_neg_full;
        pub const h_1_2 = StyledM.h_1_2;
        pub const h_neg_1_2 = StyledM.h_neg_1_2;
        pub const h_1_3 = StyledM.h_1_3;
        pub const h_neg_1_3 = StyledM.h_neg_1_3;
        pub const h_2_3 = StyledM.h_2_3;
        pub const h_neg_2_3 = StyledM.h_neg_2_3;
        pub const h_1_4 = StyledM.h_1_4;
        pub const h_neg_1_4 = StyledM.h_neg_1_4;
        pub const h_2_4 = StyledM.h_2_4;
        pub const h_neg_2_4 = StyledM.h_neg_2_4;
        pub const h_3_4 = StyledM.h_3_4;
        pub const h_neg_3_4 = StyledM.h_neg_3_4;
        pub const h_1_5 = StyledM.h_1_5;
        pub const h_neg_1_5 = StyledM.h_neg_1_5;
        pub const h_2_5 = StyledM.h_2_5;
        pub const h_neg_2_5 = StyledM.h_neg_2_5;
        pub const h_3_5 = StyledM.h_3_5;
        pub const h_neg_3_5 = StyledM.h_neg_3_5;
        pub const h_4_5 = StyledM.h_4_5;
        pub const h_neg_4_5 = StyledM.h_neg_4_5;
        pub const h_1_6 = StyledM.h_1_6;
        pub const h_neg_1_6 = StyledM.h_neg_1_6;
        pub const h_5_6 = StyledM.h_5_6;
        pub const h_neg_5_6 = StyledM.h_neg_5_6;
        pub const h_1_12 = StyledM.h_1_12;
        pub const h_neg_1_12 = StyledM.h_neg_1_12;
        pub const size = StyledM.size;
        pub const size_0 = StyledM.size_0;
        pub const size_neg_0 = StyledM.size_neg_0;
        pub const size_0p5 = StyledM.size_0p5;
        pub const size_neg_0p5 = StyledM.size_neg_0p5;
        pub const size_1 = StyledM.size_1;
        pub const size_neg_1 = StyledM.size_neg_1;
        pub const size_1p5 = StyledM.size_1p5;
        pub const size_neg_1p5 = StyledM.size_neg_1p5;
        pub const size_2 = StyledM.size_2;
        pub const size_neg_2 = StyledM.size_neg_2;
        pub const size_2p5 = StyledM.size_2p5;
        pub const size_neg_2p5 = StyledM.size_neg_2p5;
        pub const size_3 = StyledM.size_3;
        pub const size_neg_3 = StyledM.size_neg_3;
        pub const size_3p5 = StyledM.size_3p5;
        pub const size_neg_3p5 = StyledM.size_neg_3p5;
        pub const size_4 = StyledM.size_4;
        pub const size_neg_4 = StyledM.size_neg_4;
        pub const size_5 = StyledM.size_5;
        pub const size_neg_5 = StyledM.size_neg_5;
        pub const size_6 = StyledM.size_6;
        pub const size_neg_6 = StyledM.size_neg_6;
        pub const size_7 = StyledM.size_7;
        pub const size_neg_7 = StyledM.size_neg_7;
        pub const size_8 = StyledM.size_8;
        pub const size_neg_8 = StyledM.size_neg_8;
        pub const size_9 = StyledM.size_9;
        pub const size_neg_9 = StyledM.size_neg_9;
        pub const size_10 = StyledM.size_10;
        pub const size_neg_10 = StyledM.size_neg_10;
        pub const size_11 = StyledM.size_11;
        pub const size_neg_11 = StyledM.size_neg_11;
        pub const size_12 = StyledM.size_12;
        pub const size_neg_12 = StyledM.size_neg_12;
        pub const size_16 = StyledM.size_16;
        pub const size_neg_16 = StyledM.size_neg_16;
        pub const size_20 = StyledM.size_20;
        pub const size_neg_20 = StyledM.size_neg_20;
        pub const size_24 = StyledM.size_24;
        pub const size_neg_24 = StyledM.size_neg_24;
        pub const size_32 = StyledM.size_32;
        pub const size_neg_32 = StyledM.size_neg_32;
        pub const size_40 = StyledM.size_40;
        pub const size_neg_40 = StyledM.size_neg_40;
        pub const size_48 = StyledM.size_48;
        pub const size_neg_48 = StyledM.size_neg_48;
        pub const size_56 = StyledM.size_56;
        pub const size_neg_56 = StyledM.size_neg_56;
        pub const size_64 = StyledM.size_64;
        pub const size_neg_64 = StyledM.size_neg_64;
        pub const size_72 = StyledM.size_72;
        pub const size_neg_72 = StyledM.size_neg_72;
        pub const size_80 = StyledM.size_80;
        pub const size_neg_80 = StyledM.size_neg_80;
        pub const size_96 = StyledM.size_96;
        pub const size_neg_96 = StyledM.size_neg_96;
        pub const size_112 = StyledM.size_112;
        pub const size_neg_112 = StyledM.size_neg_112;
        pub const size_128 = StyledM.size_128;
        pub const size_neg_128 = StyledM.size_neg_128;
        pub const size_auto = StyledM.size_auto;
        pub const size_px = StyledM.size_px;
        pub const size_neg_px = StyledM.size_neg_px;
        pub const size_full = StyledM.size_full;
        pub const size_neg_full = StyledM.size_neg_full;
        pub const size_1_2 = StyledM.size_1_2;
        pub const size_neg_1_2 = StyledM.size_neg_1_2;
        pub const size_1_3 = StyledM.size_1_3;
        pub const size_neg_1_3 = StyledM.size_neg_1_3;
        pub const size_2_3 = StyledM.size_2_3;
        pub const size_neg_2_3 = StyledM.size_neg_2_3;
        pub const size_1_4 = StyledM.size_1_4;
        pub const size_neg_1_4 = StyledM.size_neg_1_4;
        pub const size_2_4 = StyledM.size_2_4;
        pub const size_neg_2_4 = StyledM.size_neg_2_4;
        pub const size_3_4 = StyledM.size_3_4;
        pub const size_neg_3_4 = StyledM.size_neg_3_4;
        pub const size_1_5 = StyledM.size_1_5;
        pub const size_neg_1_5 = StyledM.size_neg_1_5;
        pub const size_2_5 = StyledM.size_2_5;
        pub const size_neg_2_5 = StyledM.size_neg_2_5;
        pub const size_3_5 = StyledM.size_3_5;
        pub const size_neg_3_5 = StyledM.size_neg_3_5;
        pub const size_4_5 = StyledM.size_4_5;
        pub const size_neg_4_5 = StyledM.size_neg_4_5;
        pub const size_1_6 = StyledM.size_1_6;
        pub const size_neg_1_6 = StyledM.size_neg_1_6;
        pub const size_5_6 = StyledM.size_5_6;
        pub const size_neg_5_6 = StyledM.size_neg_5_6;
        pub const size_1_12 = StyledM.size_1_12;
        pub const size_neg_1_12 = StyledM.size_neg_1_12;
        pub const min_size = StyledM.min_size;
        pub const min_size_0 = StyledM.min_size_0;
        pub const min_size_neg_0 = StyledM.min_size_neg_0;
        pub const min_size_0p5 = StyledM.min_size_0p5;
        pub const min_size_neg_0p5 = StyledM.min_size_neg_0p5;
        pub const min_size_1 = StyledM.min_size_1;
        pub const min_size_neg_1 = StyledM.min_size_neg_1;
        pub const min_size_1p5 = StyledM.min_size_1p5;
        pub const min_size_neg_1p5 = StyledM.min_size_neg_1p5;
        pub const min_size_2 = StyledM.min_size_2;
        pub const min_size_neg_2 = StyledM.min_size_neg_2;
        pub const min_size_2p5 = StyledM.min_size_2p5;
        pub const min_size_neg_2p5 = StyledM.min_size_neg_2p5;
        pub const min_size_3 = StyledM.min_size_3;
        pub const min_size_neg_3 = StyledM.min_size_neg_3;
        pub const min_size_3p5 = StyledM.min_size_3p5;
        pub const min_size_neg_3p5 = StyledM.min_size_neg_3p5;
        pub const min_size_4 = StyledM.min_size_4;
        pub const min_size_neg_4 = StyledM.min_size_neg_4;
        pub const min_size_5 = StyledM.min_size_5;
        pub const min_size_neg_5 = StyledM.min_size_neg_5;
        pub const min_size_6 = StyledM.min_size_6;
        pub const min_size_neg_6 = StyledM.min_size_neg_6;
        pub const min_size_7 = StyledM.min_size_7;
        pub const min_size_neg_7 = StyledM.min_size_neg_7;
        pub const min_size_8 = StyledM.min_size_8;
        pub const min_size_neg_8 = StyledM.min_size_neg_8;
        pub const min_size_9 = StyledM.min_size_9;
        pub const min_size_neg_9 = StyledM.min_size_neg_9;
        pub const min_size_10 = StyledM.min_size_10;
        pub const min_size_neg_10 = StyledM.min_size_neg_10;
        pub const min_size_11 = StyledM.min_size_11;
        pub const min_size_neg_11 = StyledM.min_size_neg_11;
        pub const min_size_12 = StyledM.min_size_12;
        pub const min_size_neg_12 = StyledM.min_size_neg_12;
        pub const min_size_16 = StyledM.min_size_16;
        pub const min_size_neg_16 = StyledM.min_size_neg_16;
        pub const min_size_20 = StyledM.min_size_20;
        pub const min_size_neg_20 = StyledM.min_size_neg_20;
        pub const min_size_24 = StyledM.min_size_24;
        pub const min_size_neg_24 = StyledM.min_size_neg_24;
        pub const min_size_32 = StyledM.min_size_32;
        pub const min_size_neg_32 = StyledM.min_size_neg_32;
        pub const min_size_40 = StyledM.min_size_40;
        pub const min_size_neg_40 = StyledM.min_size_neg_40;
        pub const min_size_48 = StyledM.min_size_48;
        pub const min_size_neg_48 = StyledM.min_size_neg_48;
        pub const min_size_56 = StyledM.min_size_56;
        pub const min_size_neg_56 = StyledM.min_size_neg_56;
        pub const min_size_64 = StyledM.min_size_64;
        pub const min_size_neg_64 = StyledM.min_size_neg_64;
        pub const min_size_72 = StyledM.min_size_72;
        pub const min_size_neg_72 = StyledM.min_size_neg_72;
        pub const min_size_80 = StyledM.min_size_80;
        pub const min_size_neg_80 = StyledM.min_size_neg_80;
        pub const min_size_96 = StyledM.min_size_96;
        pub const min_size_neg_96 = StyledM.min_size_neg_96;
        pub const min_size_112 = StyledM.min_size_112;
        pub const min_size_neg_112 = StyledM.min_size_neg_112;
        pub const min_size_128 = StyledM.min_size_128;
        pub const min_size_neg_128 = StyledM.min_size_neg_128;
        pub const min_size_auto = StyledM.min_size_auto;
        pub const min_size_px = StyledM.min_size_px;
        pub const min_size_neg_px = StyledM.min_size_neg_px;
        pub const min_size_full = StyledM.min_size_full;
        pub const min_size_neg_full = StyledM.min_size_neg_full;
        pub const min_size_1_2 = StyledM.min_size_1_2;
        pub const min_size_neg_1_2 = StyledM.min_size_neg_1_2;
        pub const min_size_1_3 = StyledM.min_size_1_3;
        pub const min_size_neg_1_3 = StyledM.min_size_neg_1_3;
        pub const min_size_2_3 = StyledM.min_size_2_3;
        pub const min_size_neg_2_3 = StyledM.min_size_neg_2_3;
        pub const min_size_1_4 = StyledM.min_size_1_4;
        pub const min_size_neg_1_4 = StyledM.min_size_neg_1_4;
        pub const min_size_2_4 = StyledM.min_size_2_4;
        pub const min_size_neg_2_4 = StyledM.min_size_neg_2_4;
        pub const min_size_3_4 = StyledM.min_size_3_4;
        pub const min_size_neg_3_4 = StyledM.min_size_neg_3_4;
        pub const min_size_1_5 = StyledM.min_size_1_5;
        pub const min_size_neg_1_5 = StyledM.min_size_neg_1_5;
        pub const min_size_2_5 = StyledM.min_size_2_5;
        pub const min_size_neg_2_5 = StyledM.min_size_neg_2_5;
        pub const min_size_3_5 = StyledM.min_size_3_5;
        pub const min_size_neg_3_5 = StyledM.min_size_neg_3_5;
        pub const min_size_4_5 = StyledM.min_size_4_5;
        pub const min_size_neg_4_5 = StyledM.min_size_neg_4_5;
        pub const min_size_1_6 = StyledM.min_size_1_6;
        pub const min_size_neg_1_6 = StyledM.min_size_neg_1_6;
        pub const min_size_5_6 = StyledM.min_size_5_6;
        pub const min_size_neg_5_6 = StyledM.min_size_neg_5_6;
        pub const min_size_1_12 = StyledM.min_size_1_12;
        pub const min_size_neg_1_12 = StyledM.min_size_neg_1_12;
        pub const min_w = StyledM.min_w;
        pub const min_w_0 = StyledM.min_w_0;
        pub const min_w_neg_0 = StyledM.min_w_neg_0;
        pub const min_w_0p5 = StyledM.min_w_0p5;
        pub const min_w_neg_0p5 = StyledM.min_w_neg_0p5;
        pub const min_w_1 = StyledM.min_w_1;
        pub const min_w_neg_1 = StyledM.min_w_neg_1;
        pub const min_w_1p5 = StyledM.min_w_1p5;
        pub const min_w_neg_1p5 = StyledM.min_w_neg_1p5;
        pub const min_w_2 = StyledM.min_w_2;
        pub const min_w_neg_2 = StyledM.min_w_neg_2;
        pub const min_w_2p5 = StyledM.min_w_2p5;
        pub const min_w_neg_2p5 = StyledM.min_w_neg_2p5;
        pub const min_w_3 = StyledM.min_w_3;
        pub const min_w_neg_3 = StyledM.min_w_neg_3;
        pub const min_w_3p5 = StyledM.min_w_3p5;
        pub const min_w_neg_3p5 = StyledM.min_w_neg_3p5;
        pub const min_w_4 = StyledM.min_w_4;
        pub const min_w_neg_4 = StyledM.min_w_neg_4;
        pub const min_w_5 = StyledM.min_w_5;
        pub const min_w_neg_5 = StyledM.min_w_neg_5;
        pub const min_w_6 = StyledM.min_w_6;
        pub const min_w_neg_6 = StyledM.min_w_neg_6;
        pub const min_w_7 = StyledM.min_w_7;
        pub const min_w_neg_7 = StyledM.min_w_neg_7;
        pub const min_w_8 = StyledM.min_w_8;
        pub const min_w_neg_8 = StyledM.min_w_neg_8;
        pub const min_w_9 = StyledM.min_w_9;
        pub const min_w_neg_9 = StyledM.min_w_neg_9;
        pub const min_w_10 = StyledM.min_w_10;
        pub const min_w_neg_10 = StyledM.min_w_neg_10;
        pub const min_w_11 = StyledM.min_w_11;
        pub const min_w_neg_11 = StyledM.min_w_neg_11;
        pub const min_w_12 = StyledM.min_w_12;
        pub const min_w_neg_12 = StyledM.min_w_neg_12;
        pub const min_w_16 = StyledM.min_w_16;
        pub const min_w_neg_16 = StyledM.min_w_neg_16;
        pub const min_w_20 = StyledM.min_w_20;
        pub const min_w_neg_20 = StyledM.min_w_neg_20;
        pub const min_w_24 = StyledM.min_w_24;
        pub const min_w_neg_24 = StyledM.min_w_neg_24;
        pub const min_w_32 = StyledM.min_w_32;
        pub const min_w_neg_32 = StyledM.min_w_neg_32;
        pub const min_w_40 = StyledM.min_w_40;
        pub const min_w_neg_40 = StyledM.min_w_neg_40;
        pub const min_w_48 = StyledM.min_w_48;
        pub const min_w_neg_48 = StyledM.min_w_neg_48;
        pub const min_w_56 = StyledM.min_w_56;
        pub const min_w_neg_56 = StyledM.min_w_neg_56;
        pub const min_w_64 = StyledM.min_w_64;
        pub const min_w_neg_64 = StyledM.min_w_neg_64;
        pub const min_w_72 = StyledM.min_w_72;
        pub const min_w_neg_72 = StyledM.min_w_neg_72;
        pub const min_w_80 = StyledM.min_w_80;
        pub const min_w_neg_80 = StyledM.min_w_neg_80;
        pub const min_w_96 = StyledM.min_w_96;
        pub const min_w_neg_96 = StyledM.min_w_neg_96;
        pub const min_w_112 = StyledM.min_w_112;
        pub const min_w_neg_112 = StyledM.min_w_neg_112;
        pub const min_w_128 = StyledM.min_w_128;
        pub const min_w_neg_128 = StyledM.min_w_neg_128;
        pub const min_w_auto = StyledM.min_w_auto;
        pub const min_w_px = StyledM.min_w_px;
        pub const min_w_neg_px = StyledM.min_w_neg_px;
        pub const min_w_full = StyledM.min_w_full;
        pub const min_w_neg_full = StyledM.min_w_neg_full;
        pub const min_w_1_2 = StyledM.min_w_1_2;
        pub const min_w_neg_1_2 = StyledM.min_w_neg_1_2;
        pub const min_w_1_3 = StyledM.min_w_1_3;
        pub const min_w_neg_1_3 = StyledM.min_w_neg_1_3;
        pub const min_w_2_3 = StyledM.min_w_2_3;
        pub const min_w_neg_2_3 = StyledM.min_w_neg_2_3;
        pub const min_w_1_4 = StyledM.min_w_1_4;
        pub const min_w_neg_1_4 = StyledM.min_w_neg_1_4;
        pub const min_w_2_4 = StyledM.min_w_2_4;
        pub const min_w_neg_2_4 = StyledM.min_w_neg_2_4;
        pub const min_w_3_4 = StyledM.min_w_3_4;
        pub const min_w_neg_3_4 = StyledM.min_w_neg_3_4;
        pub const min_w_1_5 = StyledM.min_w_1_5;
        pub const min_w_neg_1_5 = StyledM.min_w_neg_1_5;
        pub const min_w_2_5 = StyledM.min_w_2_5;
        pub const min_w_neg_2_5 = StyledM.min_w_neg_2_5;
        pub const min_w_3_5 = StyledM.min_w_3_5;
        pub const min_w_neg_3_5 = StyledM.min_w_neg_3_5;
        pub const min_w_4_5 = StyledM.min_w_4_5;
        pub const min_w_neg_4_5 = StyledM.min_w_neg_4_5;
        pub const min_w_1_6 = StyledM.min_w_1_6;
        pub const min_w_neg_1_6 = StyledM.min_w_neg_1_6;
        pub const min_w_5_6 = StyledM.min_w_5_6;
        pub const min_w_neg_5_6 = StyledM.min_w_neg_5_6;
        pub const min_w_1_12 = StyledM.min_w_1_12;
        pub const min_w_neg_1_12 = StyledM.min_w_neg_1_12;
        pub const min_h = StyledM.min_h;
        pub const min_h_0 = StyledM.min_h_0;
        pub const min_h_neg_0 = StyledM.min_h_neg_0;
        pub const min_h_0p5 = StyledM.min_h_0p5;
        pub const min_h_neg_0p5 = StyledM.min_h_neg_0p5;
        pub const min_h_1 = StyledM.min_h_1;
        pub const min_h_neg_1 = StyledM.min_h_neg_1;
        pub const min_h_1p5 = StyledM.min_h_1p5;
        pub const min_h_neg_1p5 = StyledM.min_h_neg_1p5;
        pub const min_h_2 = StyledM.min_h_2;
        pub const min_h_neg_2 = StyledM.min_h_neg_2;
        pub const min_h_2p5 = StyledM.min_h_2p5;
        pub const min_h_neg_2p5 = StyledM.min_h_neg_2p5;
        pub const min_h_3 = StyledM.min_h_3;
        pub const min_h_neg_3 = StyledM.min_h_neg_3;
        pub const min_h_3p5 = StyledM.min_h_3p5;
        pub const min_h_neg_3p5 = StyledM.min_h_neg_3p5;
        pub const min_h_4 = StyledM.min_h_4;
        pub const min_h_neg_4 = StyledM.min_h_neg_4;
        pub const min_h_5 = StyledM.min_h_5;
        pub const min_h_neg_5 = StyledM.min_h_neg_5;
        pub const min_h_6 = StyledM.min_h_6;
        pub const min_h_neg_6 = StyledM.min_h_neg_6;
        pub const min_h_7 = StyledM.min_h_7;
        pub const min_h_neg_7 = StyledM.min_h_neg_7;
        pub const min_h_8 = StyledM.min_h_8;
        pub const min_h_neg_8 = StyledM.min_h_neg_8;
        pub const min_h_9 = StyledM.min_h_9;
        pub const min_h_neg_9 = StyledM.min_h_neg_9;
        pub const min_h_10 = StyledM.min_h_10;
        pub const min_h_neg_10 = StyledM.min_h_neg_10;
        pub const min_h_11 = StyledM.min_h_11;
        pub const min_h_neg_11 = StyledM.min_h_neg_11;
        pub const min_h_12 = StyledM.min_h_12;
        pub const min_h_neg_12 = StyledM.min_h_neg_12;
        pub const min_h_16 = StyledM.min_h_16;
        pub const min_h_neg_16 = StyledM.min_h_neg_16;
        pub const min_h_20 = StyledM.min_h_20;
        pub const min_h_neg_20 = StyledM.min_h_neg_20;
        pub const min_h_24 = StyledM.min_h_24;
        pub const min_h_neg_24 = StyledM.min_h_neg_24;
        pub const min_h_32 = StyledM.min_h_32;
        pub const min_h_neg_32 = StyledM.min_h_neg_32;
        pub const min_h_40 = StyledM.min_h_40;
        pub const min_h_neg_40 = StyledM.min_h_neg_40;
        pub const min_h_48 = StyledM.min_h_48;
        pub const min_h_neg_48 = StyledM.min_h_neg_48;
        pub const min_h_56 = StyledM.min_h_56;
        pub const min_h_neg_56 = StyledM.min_h_neg_56;
        pub const min_h_64 = StyledM.min_h_64;
        pub const min_h_neg_64 = StyledM.min_h_neg_64;
        pub const min_h_72 = StyledM.min_h_72;
        pub const min_h_neg_72 = StyledM.min_h_neg_72;
        pub const min_h_80 = StyledM.min_h_80;
        pub const min_h_neg_80 = StyledM.min_h_neg_80;
        pub const min_h_96 = StyledM.min_h_96;
        pub const min_h_neg_96 = StyledM.min_h_neg_96;
        pub const min_h_112 = StyledM.min_h_112;
        pub const min_h_neg_112 = StyledM.min_h_neg_112;
        pub const min_h_128 = StyledM.min_h_128;
        pub const min_h_neg_128 = StyledM.min_h_neg_128;
        pub const min_h_auto = StyledM.min_h_auto;
        pub const min_h_px = StyledM.min_h_px;
        pub const min_h_neg_px = StyledM.min_h_neg_px;
        pub const min_h_full = StyledM.min_h_full;
        pub const min_h_neg_full = StyledM.min_h_neg_full;
        pub const min_h_1_2 = StyledM.min_h_1_2;
        pub const min_h_neg_1_2 = StyledM.min_h_neg_1_2;
        pub const min_h_1_3 = StyledM.min_h_1_3;
        pub const min_h_neg_1_3 = StyledM.min_h_neg_1_3;
        pub const min_h_2_3 = StyledM.min_h_2_3;
        pub const min_h_neg_2_3 = StyledM.min_h_neg_2_3;
        pub const min_h_1_4 = StyledM.min_h_1_4;
        pub const min_h_neg_1_4 = StyledM.min_h_neg_1_4;
        pub const min_h_2_4 = StyledM.min_h_2_4;
        pub const min_h_neg_2_4 = StyledM.min_h_neg_2_4;
        pub const min_h_3_4 = StyledM.min_h_3_4;
        pub const min_h_neg_3_4 = StyledM.min_h_neg_3_4;
        pub const min_h_1_5 = StyledM.min_h_1_5;
        pub const min_h_neg_1_5 = StyledM.min_h_neg_1_5;
        pub const min_h_2_5 = StyledM.min_h_2_5;
        pub const min_h_neg_2_5 = StyledM.min_h_neg_2_5;
        pub const min_h_3_5 = StyledM.min_h_3_5;
        pub const min_h_neg_3_5 = StyledM.min_h_neg_3_5;
        pub const min_h_4_5 = StyledM.min_h_4_5;
        pub const min_h_neg_4_5 = StyledM.min_h_neg_4_5;
        pub const min_h_1_6 = StyledM.min_h_1_6;
        pub const min_h_neg_1_6 = StyledM.min_h_neg_1_6;
        pub const min_h_5_6 = StyledM.min_h_5_6;
        pub const min_h_neg_5_6 = StyledM.min_h_neg_5_6;
        pub const min_h_1_12 = StyledM.min_h_1_12;
        pub const min_h_neg_1_12 = StyledM.min_h_neg_1_12;
        pub const max_size = StyledM.max_size;
        pub const max_size_0 = StyledM.max_size_0;
        pub const max_size_neg_0 = StyledM.max_size_neg_0;
        pub const max_size_0p5 = StyledM.max_size_0p5;
        pub const max_size_neg_0p5 = StyledM.max_size_neg_0p5;
        pub const max_size_1 = StyledM.max_size_1;
        pub const max_size_neg_1 = StyledM.max_size_neg_1;
        pub const max_size_1p5 = StyledM.max_size_1p5;
        pub const max_size_neg_1p5 = StyledM.max_size_neg_1p5;
        pub const max_size_2 = StyledM.max_size_2;
        pub const max_size_neg_2 = StyledM.max_size_neg_2;
        pub const max_size_2p5 = StyledM.max_size_2p5;
        pub const max_size_neg_2p5 = StyledM.max_size_neg_2p5;
        pub const max_size_3 = StyledM.max_size_3;
        pub const max_size_neg_3 = StyledM.max_size_neg_3;
        pub const max_size_3p5 = StyledM.max_size_3p5;
        pub const max_size_neg_3p5 = StyledM.max_size_neg_3p5;
        pub const max_size_4 = StyledM.max_size_4;
        pub const max_size_neg_4 = StyledM.max_size_neg_4;
        pub const max_size_5 = StyledM.max_size_5;
        pub const max_size_neg_5 = StyledM.max_size_neg_5;
        pub const max_size_6 = StyledM.max_size_6;
        pub const max_size_neg_6 = StyledM.max_size_neg_6;
        pub const max_size_7 = StyledM.max_size_7;
        pub const max_size_neg_7 = StyledM.max_size_neg_7;
        pub const max_size_8 = StyledM.max_size_8;
        pub const max_size_neg_8 = StyledM.max_size_neg_8;
        pub const max_size_9 = StyledM.max_size_9;
        pub const max_size_neg_9 = StyledM.max_size_neg_9;
        pub const max_size_10 = StyledM.max_size_10;
        pub const max_size_neg_10 = StyledM.max_size_neg_10;
        pub const max_size_11 = StyledM.max_size_11;
        pub const max_size_neg_11 = StyledM.max_size_neg_11;
        pub const max_size_12 = StyledM.max_size_12;
        pub const max_size_neg_12 = StyledM.max_size_neg_12;
        pub const max_size_16 = StyledM.max_size_16;
        pub const max_size_neg_16 = StyledM.max_size_neg_16;
        pub const max_size_20 = StyledM.max_size_20;
        pub const max_size_neg_20 = StyledM.max_size_neg_20;
        pub const max_size_24 = StyledM.max_size_24;
        pub const max_size_neg_24 = StyledM.max_size_neg_24;
        pub const max_size_32 = StyledM.max_size_32;
        pub const max_size_neg_32 = StyledM.max_size_neg_32;
        pub const max_size_40 = StyledM.max_size_40;
        pub const max_size_neg_40 = StyledM.max_size_neg_40;
        pub const max_size_48 = StyledM.max_size_48;
        pub const max_size_neg_48 = StyledM.max_size_neg_48;
        pub const max_size_56 = StyledM.max_size_56;
        pub const max_size_neg_56 = StyledM.max_size_neg_56;
        pub const max_size_64 = StyledM.max_size_64;
        pub const max_size_neg_64 = StyledM.max_size_neg_64;
        pub const max_size_72 = StyledM.max_size_72;
        pub const max_size_neg_72 = StyledM.max_size_neg_72;
        pub const max_size_80 = StyledM.max_size_80;
        pub const max_size_neg_80 = StyledM.max_size_neg_80;
        pub const max_size_96 = StyledM.max_size_96;
        pub const max_size_neg_96 = StyledM.max_size_neg_96;
        pub const max_size_112 = StyledM.max_size_112;
        pub const max_size_neg_112 = StyledM.max_size_neg_112;
        pub const max_size_128 = StyledM.max_size_128;
        pub const max_size_neg_128 = StyledM.max_size_neg_128;
        pub const max_size_auto = StyledM.max_size_auto;
        pub const max_size_px = StyledM.max_size_px;
        pub const max_size_neg_px = StyledM.max_size_neg_px;
        pub const max_size_full = StyledM.max_size_full;
        pub const max_size_neg_full = StyledM.max_size_neg_full;
        pub const max_size_1_2 = StyledM.max_size_1_2;
        pub const max_size_neg_1_2 = StyledM.max_size_neg_1_2;
        pub const max_size_1_3 = StyledM.max_size_1_3;
        pub const max_size_neg_1_3 = StyledM.max_size_neg_1_3;
        pub const max_size_2_3 = StyledM.max_size_2_3;
        pub const max_size_neg_2_3 = StyledM.max_size_neg_2_3;
        pub const max_size_1_4 = StyledM.max_size_1_4;
        pub const max_size_neg_1_4 = StyledM.max_size_neg_1_4;
        pub const max_size_2_4 = StyledM.max_size_2_4;
        pub const max_size_neg_2_4 = StyledM.max_size_neg_2_4;
        pub const max_size_3_4 = StyledM.max_size_3_4;
        pub const max_size_neg_3_4 = StyledM.max_size_neg_3_4;
        pub const max_size_1_5 = StyledM.max_size_1_5;
        pub const max_size_neg_1_5 = StyledM.max_size_neg_1_5;
        pub const max_size_2_5 = StyledM.max_size_2_5;
        pub const max_size_neg_2_5 = StyledM.max_size_neg_2_5;
        pub const max_size_3_5 = StyledM.max_size_3_5;
        pub const max_size_neg_3_5 = StyledM.max_size_neg_3_5;
        pub const max_size_4_5 = StyledM.max_size_4_5;
        pub const max_size_neg_4_5 = StyledM.max_size_neg_4_5;
        pub const max_size_1_6 = StyledM.max_size_1_6;
        pub const max_size_neg_1_6 = StyledM.max_size_neg_1_6;
        pub const max_size_5_6 = StyledM.max_size_5_6;
        pub const max_size_neg_5_6 = StyledM.max_size_neg_5_6;
        pub const max_size_1_12 = StyledM.max_size_1_12;
        pub const max_size_neg_1_12 = StyledM.max_size_neg_1_12;
        pub const max_w = StyledM.max_w;
        pub const max_w_0 = StyledM.max_w_0;
        pub const max_w_neg_0 = StyledM.max_w_neg_0;
        pub const max_w_0p5 = StyledM.max_w_0p5;
        pub const max_w_neg_0p5 = StyledM.max_w_neg_0p5;
        pub const max_w_1 = StyledM.max_w_1;
        pub const max_w_neg_1 = StyledM.max_w_neg_1;
        pub const max_w_1p5 = StyledM.max_w_1p5;
        pub const max_w_neg_1p5 = StyledM.max_w_neg_1p5;
        pub const max_w_2 = StyledM.max_w_2;
        pub const max_w_neg_2 = StyledM.max_w_neg_2;
        pub const max_w_2p5 = StyledM.max_w_2p5;
        pub const max_w_neg_2p5 = StyledM.max_w_neg_2p5;
        pub const max_w_3 = StyledM.max_w_3;
        pub const max_w_neg_3 = StyledM.max_w_neg_3;
        pub const max_w_3p5 = StyledM.max_w_3p5;
        pub const max_w_neg_3p5 = StyledM.max_w_neg_3p5;
        pub const max_w_4 = StyledM.max_w_4;
        pub const max_w_neg_4 = StyledM.max_w_neg_4;
        pub const max_w_5 = StyledM.max_w_5;
        pub const max_w_neg_5 = StyledM.max_w_neg_5;
        pub const max_w_6 = StyledM.max_w_6;
        pub const max_w_neg_6 = StyledM.max_w_neg_6;
        pub const max_w_7 = StyledM.max_w_7;
        pub const max_w_neg_7 = StyledM.max_w_neg_7;
        pub const max_w_8 = StyledM.max_w_8;
        pub const max_w_neg_8 = StyledM.max_w_neg_8;
        pub const max_w_9 = StyledM.max_w_9;
        pub const max_w_neg_9 = StyledM.max_w_neg_9;
        pub const max_w_10 = StyledM.max_w_10;
        pub const max_w_neg_10 = StyledM.max_w_neg_10;
        pub const max_w_11 = StyledM.max_w_11;
        pub const max_w_neg_11 = StyledM.max_w_neg_11;
        pub const max_w_12 = StyledM.max_w_12;
        pub const max_w_neg_12 = StyledM.max_w_neg_12;
        pub const max_w_16 = StyledM.max_w_16;
        pub const max_w_neg_16 = StyledM.max_w_neg_16;
        pub const max_w_20 = StyledM.max_w_20;
        pub const max_w_neg_20 = StyledM.max_w_neg_20;
        pub const max_w_24 = StyledM.max_w_24;
        pub const max_w_neg_24 = StyledM.max_w_neg_24;
        pub const max_w_32 = StyledM.max_w_32;
        pub const max_w_neg_32 = StyledM.max_w_neg_32;
        pub const max_w_40 = StyledM.max_w_40;
        pub const max_w_neg_40 = StyledM.max_w_neg_40;
        pub const max_w_48 = StyledM.max_w_48;
        pub const max_w_neg_48 = StyledM.max_w_neg_48;
        pub const max_w_56 = StyledM.max_w_56;
        pub const max_w_neg_56 = StyledM.max_w_neg_56;
        pub const max_w_64 = StyledM.max_w_64;
        pub const max_w_neg_64 = StyledM.max_w_neg_64;
        pub const max_w_72 = StyledM.max_w_72;
        pub const max_w_neg_72 = StyledM.max_w_neg_72;
        pub const max_w_80 = StyledM.max_w_80;
        pub const max_w_neg_80 = StyledM.max_w_neg_80;
        pub const max_w_96 = StyledM.max_w_96;
        pub const max_w_neg_96 = StyledM.max_w_neg_96;
        pub const max_w_112 = StyledM.max_w_112;
        pub const max_w_neg_112 = StyledM.max_w_neg_112;
        pub const max_w_128 = StyledM.max_w_128;
        pub const max_w_neg_128 = StyledM.max_w_neg_128;
        pub const max_w_auto = StyledM.max_w_auto;
        pub const max_w_px = StyledM.max_w_px;
        pub const max_w_neg_px = StyledM.max_w_neg_px;
        pub const max_w_full = StyledM.max_w_full;
        pub const max_w_neg_full = StyledM.max_w_neg_full;
        pub const max_w_1_2 = StyledM.max_w_1_2;
        pub const max_w_neg_1_2 = StyledM.max_w_neg_1_2;
        pub const max_w_1_3 = StyledM.max_w_1_3;
        pub const max_w_neg_1_3 = StyledM.max_w_neg_1_3;
        pub const max_w_2_3 = StyledM.max_w_2_3;
        pub const max_w_neg_2_3 = StyledM.max_w_neg_2_3;
        pub const max_w_1_4 = StyledM.max_w_1_4;
        pub const max_w_neg_1_4 = StyledM.max_w_neg_1_4;
        pub const max_w_2_4 = StyledM.max_w_2_4;
        pub const max_w_neg_2_4 = StyledM.max_w_neg_2_4;
        pub const max_w_3_4 = StyledM.max_w_3_4;
        pub const max_w_neg_3_4 = StyledM.max_w_neg_3_4;
        pub const max_w_1_5 = StyledM.max_w_1_5;
        pub const max_w_neg_1_5 = StyledM.max_w_neg_1_5;
        pub const max_w_2_5 = StyledM.max_w_2_5;
        pub const max_w_neg_2_5 = StyledM.max_w_neg_2_5;
        pub const max_w_3_5 = StyledM.max_w_3_5;
        pub const max_w_neg_3_5 = StyledM.max_w_neg_3_5;
        pub const max_w_4_5 = StyledM.max_w_4_5;
        pub const max_w_neg_4_5 = StyledM.max_w_neg_4_5;
        pub const max_w_1_6 = StyledM.max_w_1_6;
        pub const max_w_neg_1_6 = StyledM.max_w_neg_1_6;
        pub const max_w_5_6 = StyledM.max_w_5_6;
        pub const max_w_neg_5_6 = StyledM.max_w_neg_5_6;
        pub const max_w_1_12 = StyledM.max_w_1_12;
        pub const max_w_neg_1_12 = StyledM.max_w_neg_1_12;
        pub const max_h = StyledM.max_h;
        pub const max_h_0 = StyledM.max_h_0;
        pub const max_h_neg_0 = StyledM.max_h_neg_0;
        pub const max_h_0p5 = StyledM.max_h_0p5;
        pub const max_h_neg_0p5 = StyledM.max_h_neg_0p5;
        pub const max_h_1 = StyledM.max_h_1;
        pub const max_h_neg_1 = StyledM.max_h_neg_1;
        pub const max_h_1p5 = StyledM.max_h_1p5;
        pub const max_h_neg_1p5 = StyledM.max_h_neg_1p5;
        pub const max_h_2 = StyledM.max_h_2;
        pub const max_h_neg_2 = StyledM.max_h_neg_2;
        pub const max_h_2p5 = StyledM.max_h_2p5;
        pub const max_h_neg_2p5 = StyledM.max_h_neg_2p5;
        pub const max_h_3 = StyledM.max_h_3;
        pub const max_h_neg_3 = StyledM.max_h_neg_3;
        pub const max_h_3p5 = StyledM.max_h_3p5;
        pub const max_h_neg_3p5 = StyledM.max_h_neg_3p5;
        pub const max_h_4 = StyledM.max_h_4;
        pub const max_h_neg_4 = StyledM.max_h_neg_4;
        pub const max_h_5 = StyledM.max_h_5;
        pub const max_h_neg_5 = StyledM.max_h_neg_5;
        pub const max_h_6 = StyledM.max_h_6;
        pub const max_h_neg_6 = StyledM.max_h_neg_6;
        pub const max_h_7 = StyledM.max_h_7;
        pub const max_h_neg_7 = StyledM.max_h_neg_7;
        pub const max_h_8 = StyledM.max_h_8;
        pub const max_h_neg_8 = StyledM.max_h_neg_8;
        pub const max_h_9 = StyledM.max_h_9;
        pub const max_h_neg_9 = StyledM.max_h_neg_9;
        pub const max_h_10 = StyledM.max_h_10;
        pub const max_h_neg_10 = StyledM.max_h_neg_10;
        pub const max_h_11 = StyledM.max_h_11;
        pub const max_h_neg_11 = StyledM.max_h_neg_11;
        pub const max_h_12 = StyledM.max_h_12;
        pub const max_h_neg_12 = StyledM.max_h_neg_12;
        pub const max_h_16 = StyledM.max_h_16;
        pub const max_h_neg_16 = StyledM.max_h_neg_16;
        pub const max_h_20 = StyledM.max_h_20;
        pub const max_h_neg_20 = StyledM.max_h_neg_20;
        pub const max_h_24 = StyledM.max_h_24;
        pub const max_h_neg_24 = StyledM.max_h_neg_24;
        pub const max_h_32 = StyledM.max_h_32;
        pub const max_h_neg_32 = StyledM.max_h_neg_32;
        pub const max_h_40 = StyledM.max_h_40;
        pub const max_h_neg_40 = StyledM.max_h_neg_40;
        pub const max_h_48 = StyledM.max_h_48;
        pub const max_h_neg_48 = StyledM.max_h_neg_48;
        pub const max_h_56 = StyledM.max_h_56;
        pub const max_h_neg_56 = StyledM.max_h_neg_56;
        pub const max_h_64 = StyledM.max_h_64;
        pub const max_h_neg_64 = StyledM.max_h_neg_64;
        pub const max_h_72 = StyledM.max_h_72;
        pub const max_h_neg_72 = StyledM.max_h_neg_72;
        pub const max_h_80 = StyledM.max_h_80;
        pub const max_h_neg_80 = StyledM.max_h_neg_80;
        pub const max_h_96 = StyledM.max_h_96;
        pub const max_h_neg_96 = StyledM.max_h_neg_96;
        pub const max_h_112 = StyledM.max_h_112;
        pub const max_h_neg_112 = StyledM.max_h_neg_112;
        pub const max_h_128 = StyledM.max_h_128;
        pub const max_h_neg_128 = StyledM.max_h_neg_128;
        pub const max_h_auto = StyledM.max_h_auto;
        pub const max_h_px = StyledM.max_h_px;
        pub const max_h_neg_px = StyledM.max_h_neg_px;
        pub const max_h_full = StyledM.max_h_full;
        pub const max_h_neg_full = StyledM.max_h_neg_full;
        pub const max_h_1_2 = StyledM.max_h_1_2;
        pub const max_h_neg_1_2 = StyledM.max_h_neg_1_2;
        pub const max_h_1_3 = StyledM.max_h_1_3;
        pub const max_h_neg_1_3 = StyledM.max_h_neg_1_3;
        pub const max_h_2_3 = StyledM.max_h_2_3;
        pub const max_h_neg_2_3 = StyledM.max_h_neg_2_3;
        pub const max_h_1_4 = StyledM.max_h_1_4;
        pub const max_h_neg_1_4 = StyledM.max_h_neg_1_4;
        pub const max_h_2_4 = StyledM.max_h_2_4;
        pub const max_h_neg_2_4 = StyledM.max_h_neg_2_4;
        pub const max_h_3_4 = StyledM.max_h_3_4;
        pub const max_h_neg_3_4 = StyledM.max_h_neg_3_4;
        pub const max_h_1_5 = StyledM.max_h_1_5;
        pub const max_h_neg_1_5 = StyledM.max_h_neg_1_5;
        pub const max_h_2_5 = StyledM.max_h_2_5;
        pub const max_h_neg_2_5 = StyledM.max_h_neg_2_5;
        pub const max_h_3_5 = StyledM.max_h_3_5;
        pub const max_h_neg_3_5 = StyledM.max_h_neg_3_5;
        pub const max_h_4_5 = StyledM.max_h_4_5;
        pub const max_h_neg_4_5 = StyledM.max_h_neg_4_5;
        pub const max_h_1_6 = StyledM.max_h_1_6;
        pub const max_h_neg_1_6 = StyledM.max_h_neg_1_6;
        pub const max_h_5_6 = StyledM.max_h_5_6;
        pub const max_h_neg_5_6 = StyledM.max_h_neg_5_6;
        pub const max_h_1_12 = StyledM.max_h_1_12;
        pub const max_h_neg_1_12 = StyledM.max_h_neg_1_12;
        pub const gap = StyledM.gap;
        pub const gap_0 = StyledM.gap_0;
        pub const gap_neg_0 = StyledM.gap_neg_0;
        pub const gap_0p5 = StyledM.gap_0p5;
        pub const gap_neg_0p5 = StyledM.gap_neg_0p5;
        pub const gap_1 = StyledM.gap_1;
        pub const gap_neg_1 = StyledM.gap_neg_1;
        pub const gap_1p5 = StyledM.gap_1p5;
        pub const gap_neg_1p5 = StyledM.gap_neg_1p5;
        pub const gap_2 = StyledM.gap_2;
        pub const gap_neg_2 = StyledM.gap_neg_2;
        pub const gap_2p5 = StyledM.gap_2p5;
        pub const gap_neg_2p5 = StyledM.gap_neg_2p5;
        pub const gap_3 = StyledM.gap_3;
        pub const gap_neg_3 = StyledM.gap_neg_3;
        pub const gap_3p5 = StyledM.gap_3p5;
        pub const gap_neg_3p5 = StyledM.gap_neg_3p5;
        pub const gap_4 = StyledM.gap_4;
        pub const gap_neg_4 = StyledM.gap_neg_4;
        pub const gap_5 = StyledM.gap_5;
        pub const gap_neg_5 = StyledM.gap_neg_5;
        pub const gap_6 = StyledM.gap_6;
        pub const gap_neg_6 = StyledM.gap_neg_6;
        pub const gap_7 = StyledM.gap_7;
        pub const gap_neg_7 = StyledM.gap_neg_7;
        pub const gap_8 = StyledM.gap_8;
        pub const gap_neg_8 = StyledM.gap_neg_8;
        pub const gap_9 = StyledM.gap_9;
        pub const gap_neg_9 = StyledM.gap_neg_9;
        pub const gap_10 = StyledM.gap_10;
        pub const gap_neg_10 = StyledM.gap_neg_10;
        pub const gap_11 = StyledM.gap_11;
        pub const gap_neg_11 = StyledM.gap_neg_11;
        pub const gap_12 = StyledM.gap_12;
        pub const gap_neg_12 = StyledM.gap_neg_12;
        pub const gap_16 = StyledM.gap_16;
        pub const gap_neg_16 = StyledM.gap_neg_16;
        pub const gap_20 = StyledM.gap_20;
        pub const gap_neg_20 = StyledM.gap_neg_20;
        pub const gap_24 = StyledM.gap_24;
        pub const gap_neg_24 = StyledM.gap_neg_24;
        pub const gap_32 = StyledM.gap_32;
        pub const gap_neg_32 = StyledM.gap_neg_32;
        pub const gap_40 = StyledM.gap_40;
        pub const gap_neg_40 = StyledM.gap_neg_40;
        pub const gap_48 = StyledM.gap_48;
        pub const gap_neg_48 = StyledM.gap_neg_48;
        pub const gap_56 = StyledM.gap_56;
        pub const gap_neg_56 = StyledM.gap_neg_56;
        pub const gap_64 = StyledM.gap_64;
        pub const gap_neg_64 = StyledM.gap_neg_64;
        pub const gap_72 = StyledM.gap_72;
        pub const gap_neg_72 = StyledM.gap_neg_72;
        pub const gap_80 = StyledM.gap_80;
        pub const gap_neg_80 = StyledM.gap_neg_80;
        pub const gap_96 = StyledM.gap_96;
        pub const gap_neg_96 = StyledM.gap_neg_96;
        pub const gap_112 = StyledM.gap_112;
        pub const gap_neg_112 = StyledM.gap_neg_112;
        pub const gap_128 = StyledM.gap_128;
        pub const gap_neg_128 = StyledM.gap_neg_128;
        pub const gap_px = StyledM.gap_px;
        pub const gap_neg_px = StyledM.gap_neg_px;
        pub const gap_full = StyledM.gap_full;
        pub const gap_neg_full = StyledM.gap_neg_full;
        pub const gap_1_2 = StyledM.gap_1_2;
        pub const gap_neg_1_2 = StyledM.gap_neg_1_2;
        pub const gap_1_3 = StyledM.gap_1_3;
        pub const gap_neg_1_3 = StyledM.gap_neg_1_3;
        pub const gap_2_3 = StyledM.gap_2_3;
        pub const gap_neg_2_3 = StyledM.gap_neg_2_3;
        pub const gap_1_4 = StyledM.gap_1_4;
        pub const gap_neg_1_4 = StyledM.gap_neg_1_4;
        pub const gap_2_4 = StyledM.gap_2_4;
        pub const gap_neg_2_4 = StyledM.gap_neg_2_4;
        pub const gap_3_4 = StyledM.gap_3_4;
        pub const gap_neg_3_4 = StyledM.gap_neg_3_4;
        pub const gap_1_5 = StyledM.gap_1_5;
        pub const gap_neg_1_5 = StyledM.gap_neg_1_5;
        pub const gap_2_5 = StyledM.gap_2_5;
        pub const gap_neg_2_5 = StyledM.gap_neg_2_5;
        pub const gap_3_5 = StyledM.gap_3_5;
        pub const gap_neg_3_5 = StyledM.gap_neg_3_5;
        pub const gap_4_5 = StyledM.gap_4_5;
        pub const gap_neg_4_5 = StyledM.gap_neg_4_5;
        pub const gap_1_6 = StyledM.gap_1_6;
        pub const gap_neg_1_6 = StyledM.gap_neg_1_6;
        pub const gap_5_6 = StyledM.gap_5_6;
        pub const gap_neg_5_6 = StyledM.gap_neg_5_6;
        pub const gap_1_12 = StyledM.gap_1_12;
        pub const gap_neg_1_12 = StyledM.gap_neg_1_12;
        pub const gap_x = StyledM.gap_x;
        pub const gap_x_0 = StyledM.gap_x_0;
        pub const gap_x_neg_0 = StyledM.gap_x_neg_0;
        pub const gap_x_0p5 = StyledM.gap_x_0p5;
        pub const gap_x_neg_0p5 = StyledM.gap_x_neg_0p5;
        pub const gap_x_1 = StyledM.gap_x_1;
        pub const gap_x_neg_1 = StyledM.gap_x_neg_1;
        pub const gap_x_1p5 = StyledM.gap_x_1p5;
        pub const gap_x_neg_1p5 = StyledM.gap_x_neg_1p5;
        pub const gap_x_2 = StyledM.gap_x_2;
        pub const gap_x_neg_2 = StyledM.gap_x_neg_2;
        pub const gap_x_2p5 = StyledM.gap_x_2p5;
        pub const gap_x_neg_2p5 = StyledM.gap_x_neg_2p5;
        pub const gap_x_3 = StyledM.gap_x_3;
        pub const gap_x_neg_3 = StyledM.gap_x_neg_3;
        pub const gap_x_3p5 = StyledM.gap_x_3p5;
        pub const gap_x_neg_3p5 = StyledM.gap_x_neg_3p5;
        pub const gap_x_4 = StyledM.gap_x_4;
        pub const gap_x_neg_4 = StyledM.gap_x_neg_4;
        pub const gap_x_5 = StyledM.gap_x_5;
        pub const gap_x_neg_5 = StyledM.gap_x_neg_5;
        pub const gap_x_6 = StyledM.gap_x_6;
        pub const gap_x_neg_6 = StyledM.gap_x_neg_6;
        pub const gap_x_7 = StyledM.gap_x_7;
        pub const gap_x_neg_7 = StyledM.gap_x_neg_7;
        pub const gap_x_8 = StyledM.gap_x_8;
        pub const gap_x_neg_8 = StyledM.gap_x_neg_8;
        pub const gap_x_9 = StyledM.gap_x_9;
        pub const gap_x_neg_9 = StyledM.gap_x_neg_9;
        pub const gap_x_10 = StyledM.gap_x_10;
        pub const gap_x_neg_10 = StyledM.gap_x_neg_10;
        pub const gap_x_11 = StyledM.gap_x_11;
        pub const gap_x_neg_11 = StyledM.gap_x_neg_11;
        pub const gap_x_12 = StyledM.gap_x_12;
        pub const gap_x_neg_12 = StyledM.gap_x_neg_12;
        pub const gap_x_16 = StyledM.gap_x_16;
        pub const gap_x_neg_16 = StyledM.gap_x_neg_16;
        pub const gap_x_20 = StyledM.gap_x_20;
        pub const gap_x_neg_20 = StyledM.gap_x_neg_20;
        pub const gap_x_24 = StyledM.gap_x_24;
        pub const gap_x_neg_24 = StyledM.gap_x_neg_24;
        pub const gap_x_32 = StyledM.gap_x_32;
        pub const gap_x_neg_32 = StyledM.gap_x_neg_32;
        pub const gap_x_40 = StyledM.gap_x_40;
        pub const gap_x_neg_40 = StyledM.gap_x_neg_40;
        pub const gap_x_48 = StyledM.gap_x_48;
        pub const gap_x_neg_48 = StyledM.gap_x_neg_48;
        pub const gap_x_56 = StyledM.gap_x_56;
        pub const gap_x_neg_56 = StyledM.gap_x_neg_56;
        pub const gap_x_64 = StyledM.gap_x_64;
        pub const gap_x_neg_64 = StyledM.gap_x_neg_64;
        pub const gap_x_72 = StyledM.gap_x_72;
        pub const gap_x_neg_72 = StyledM.gap_x_neg_72;
        pub const gap_x_80 = StyledM.gap_x_80;
        pub const gap_x_neg_80 = StyledM.gap_x_neg_80;
        pub const gap_x_96 = StyledM.gap_x_96;
        pub const gap_x_neg_96 = StyledM.gap_x_neg_96;
        pub const gap_x_112 = StyledM.gap_x_112;
        pub const gap_x_neg_112 = StyledM.gap_x_neg_112;
        pub const gap_x_128 = StyledM.gap_x_128;
        pub const gap_x_neg_128 = StyledM.gap_x_neg_128;
        pub const gap_x_px = StyledM.gap_x_px;
        pub const gap_x_neg_px = StyledM.gap_x_neg_px;
        pub const gap_x_full = StyledM.gap_x_full;
        pub const gap_x_neg_full = StyledM.gap_x_neg_full;
        pub const gap_x_1_2 = StyledM.gap_x_1_2;
        pub const gap_x_neg_1_2 = StyledM.gap_x_neg_1_2;
        pub const gap_x_1_3 = StyledM.gap_x_1_3;
        pub const gap_x_neg_1_3 = StyledM.gap_x_neg_1_3;
        pub const gap_x_2_3 = StyledM.gap_x_2_3;
        pub const gap_x_neg_2_3 = StyledM.gap_x_neg_2_3;
        pub const gap_x_1_4 = StyledM.gap_x_1_4;
        pub const gap_x_neg_1_4 = StyledM.gap_x_neg_1_4;
        pub const gap_x_2_4 = StyledM.gap_x_2_4;
        pub const gap_x_neg_2_4 = StyledM.gap_x_neg_2_4;
        pub const gap_x_3_4 = StyledM.gap_x_3_4;
        pub const gap_x_neg_3_4 = StyledM.gap_x_neg_3_4;
        pub const gap_x_1_5 = StyledM.gap_x_1_5;
        pub const gap_x_neg_1_5 = StyledM.gap_x_neg_1_5;
        pub const gap_x_2_5 = StyledM.gap_x_2_5;
        pub const gap_x_neg_2_5 = StyledM.gap_x_neg_2_5;
        pub const gap_x_3_5 = StyledM.gap_x_3_5;
        pub const gap_x_neg_3_5 = StyledM.gap_x_neg_3_5;
        pub const gap_x_4_5 = StyledM.gap_x_4_5;
        pub const gap_x_neg_4_5 = StyledM.gap_x_neg_4_5;
        pub const gap_x_1_6 = StyledM.gap_x_1_6;
        pub const gap_x_neg_1_6 = StyledM.gap_x_neg_1_6;
        pub const gap_x_5_6 = StyledM.gap_x_5_6;
        pub const gap_x_neg_5_6 = StyledM.gap_x_neg_5_6;
        pub const gap_x_1_12 = StyledM.gap_x_1_12;
        pub const gap_x_neg_1_12 = StyledM.gap_x_neg_1_12;
        pub const gap_y = StyledM.gap_y;
        pub const gap_y_0 = StyledM.gap_y_0;
        pub const gap_y_neg_0 = StyledM.gap_y_neg_0;
        pub const gap_y_0p5 = StyledM.gap_y_0p5;
        pub const gap_y_neg_0p5 = StyledM.gap_y_neg_0p5;
        pub const gap_y_1 = StyledM.gap_y_1;
        pub const gap_y_neg_1 = StyledM.gap_y_neg_1;
        pub const gap_y_1p5 = StyledM.gap_y_1p5;
        pub const gap_y_neg_1p5 = StyledM.gap_y_neg_1p5;
        pub const gap_y_2 = StyledM.gap_y_2;
        pub const gap_y_neg_2 = StyledM.gap_y_neg_2;
        pub const gap_y_2p5 = StyledM.gap_y_2p5;
        pub const gap_y_neg_2p5 = StyledM.gap_y_neg_2p5;
        pub const gap_y_3 = StyledM.gap_y_3;
        pub const gap_y_neg_3 = StyledM.gap_y_neg_3;
        pub const gap_y_3p5 = StyledM.gap_y_3p5;
        pub const gap_y_neg_3p5 = StyledM.gap_y_neg_3p5;
        pub const gap_y_4 = StyledM.gap_y_4;
        pub const gap_y_neg_4 = StyledM.gap_y_neg_4;
        pub const gap_y_5 = StyledM.gap_y_5;
        pub const gap_y_neg_5 = StyledM.gap_y_neg_5;
        pub const gap_y_6 = StyledM.gap_y_6;
        pub const gap_y_neg_6 = StyledM.gap_y_neg_6;
        pub const gap_y_7 = StyledM.gap_y_7;
        pub const gap_y_neg_7 = StyledM.gap_y_neg_7;
        pub const gap_y_8 = StyledM.gap_y_8;
        pub const gap_y_neg_8 = StyledM.gap_y_neg_8;
        pub const gap_y_9 = StyledM.gap_y_9;
        pub const gap_y_neg_9 = StyledM.gap_y_neg_9;
        pub const gap_y_10 = StyledM.gap_y_10;
        pub const gap_y_neg_10 = StyledM.gap_y_neg_10;
        pub const gap_y_11 = StyledM.gap_y_11;
        pub const gap_y_neg_11 = StyledM.gap_y_neg_11;
        pub const gap_y_12 = StyledM.gap_y_12;
        pub const gap_y_neg_12 = StyledM.gap_y_neg_12;
        pub const gap_y_16 = StyledM.gap_y_16;
        pub const gap_y_neg_16 = StyledM.gap_y_neg_16;
        pub const gap_y_20 = StyledM.gap_y_20;
        pub const gap_y_neg_20 = StyledM.gap_y_neg_20;
        pub const gap_y_24 = StyledM.gap_y_24;
        pub const gap_y_neg_24 = StyledM.gap_y_neg_24;
        pub const gap_y_32 = StyledM.gap_y_32;
        pub const gap_y_neg_32 = StyledM.gap_y_neg_32;
        pub const gap_y_40 = StyledM.gap_y_40;
        pub const gap_y_neg_40 = StyledM.gap_y_neg_40;
        pub const gap_y_48 = StyledM.gap_y_48;
        pub const gap_y_neg_48 = StyledM.gap_y_neg_48;
        pub const gap_y_56 = StyledM.gap_y_56;
        pub const gap_y_neg_56 = StyledM.gap_y_neg_56;
        pub const gap_y_64 = StyledM.gap_y_64;
        pub const gap_y_neg_64 = StyledM.gap_y_neg_64;
        pub const gap_y_72 = StyledM.gap_y_72;
        pub const gap_y_neg_72 = StyledM.gap_y_neg_72;
        pub const gap_y_80 = StyledM.gap_y_80;
        pub const gap_y_neg_80 = StyledM.gap_y_neg_80;
        pub const gap_y_96 = StyledM.gap_y_96;
        pub const gap_y_neg_96 = StyledM.gap_y_neg_96;
        pub const gap_y_112 = StyledM.gap_y_112;
        pub const gap_y_neg_112 = StyledM.gap_y_neg_112;
        pub const gap_y_128 = StyledM.gap_y_128;
        pub const gap_y_neg_128 = StyledM.gap_y_neg_128;
        pub const gap_y_px = StyledM.gap_y_px;
        pub const gap_y_neg_px = StyledM.gap_y_neg_px;
        pub const gap_y_full = StyledM.gap_y_full;
        pub const gap_y_neg_full = StyledM.gap_y_neg_full;
        pub const gap_y_1_2 = StyledM.gap_y_1_2;
        pub const gap_y_neg_1_2 = StyledM.gap_y_neg_1_2;
        pub const gap_y_1_3 = StyledM.gap_y_1_3;
        pub const gap_y_neg_1_3 = StyledM.gap_y_neg_1_3;
        pub const gap_y_2_3 = StyledM.gap_y_2_3;
        pub const gap_y_neg_2_3 = StyledM.gap_y_neg_2_3;
        pub const gap_y_1_4 = StyledM.gap_y_1_4;
        pub const gap_y_neg_1_4 = StyledM.gap_y_neg_1_4;
        pub const gap_y_2_4 = StyledM.gap_y_2_4;
        pub const gap_y_neg_2_4 = StyledM.gap_y_neg_2_4;
        pub const gap_y_3_4 = StyledM.gap_y_3_4;
        pub const gap_y_neg_3_4 = StyledM.gap_y_neg_3_4;
        pub const gap_y_1_5 = StyledM.gap_y_1_5;
        pub const gap_y_neg_1_5 = StyledM.gap_y_neg_1_5;
        pub const gap_y_2_5 = StyledM.gap_y_2_5;
        pub const gap_y_neg_2_5 = StyledM.gap_y_neg_2_5;
        pub const gap_y_3_5 = StyledM.gap_y_3_5;
        pub const gap_y_neg_3_5 = StyledM.gap_y_neg_3_5;
        pub const gap_y_4_5 = StyledM.gap_y_4_5;
        pub const gap_y_neg_4_5 = StyledM.gap_y_neg_4_5;
        pub const gap_y_1_6 = StyledM.gap_y_1_6;
        pub const gap_y_neg_1_6 = StyledM.gap_y_neg_1_6;
        pub const gap_y_5_6 = StyledM.gap_y_5_6;
        pub const gap_y_neg_5_6 = StyledM.gap_y_neg_5_6;
        pub const gap_y_1_12 = StyledM.gap_y_1_12;
        pub const gap_y_neg_1_12 = StyledM.gap_y_neg_1_12;
        pub const rounded = StyledM.rounded;
        pub const rounded_none = StyledM.rounded_none;
        pub const rounded_xs = StyledM.rounded_xs;
        pub const rounded_sm = StyledM.rounded_sm;
        pub const rounded_md = StyledM.rounded_md;
        pub const rounded_lg = StyledM.rounded_lg;
        pub const rounded_xl = StyledM.rounded_xl;
        pub const rounded_2xl = StyledM.rounded_2xl;
        pub const rounded_3xl = StyledM.rounded_3xl;
        pub const rounded_full = StyledM.rounded_full;
        pub const rounded_t = StyledM.rounded_t;
        pub const rounded_t_none = StyledM.rounded_t_none;
        pub const rounded_t_xs = StyledM.rounded_t_xs;
        pub const rounded_t_sm = StyledM.rounded_t_sm;
        pub const rounded_t_md = StyledM.rounded_t_md;
        pub const rounded_t_lg = StyledM.rounded_t_lg;
        pub const rounded_t_xl = StyledM.rounded_t_xl;
        pub const rounded_t_2xl = StyledM.rounded_t_2xl;
        pub const rounded_t_3xl = StyledM.rounded_t_3xl;
        pub const rounded_t_full = StyledM.rounded_t_full;
        pub const rounded_b = StyledM.rounded_b;
        pub const rounded_b_none = StyledM.rounded_b_none;
        pub const rounded_b_xs = StyledM.rounded_b_xs;
        pub const rounded_b_sm = StyledM.rounded_b_sm;
        pub const rounded_b_md = StyledM.rounded_b_md;
        pub const rounded_b_lg = StyledM.rounded_b_lg;
        pub const rounded_b_xl = StyledM.rounded_b_xl;
        pub const rounded_b_2xl = StyledM.rounded_b_2xl;
        pub const rounded_b_3xl = StyledM.rounded_b_3xl;
        pub const rounded_b_full = StyledM.rounded_b_full;
        pub const rounded_r = StyledM.rounded_r;
        pub const rounded_r_none = StyledM.rounded_r_none;
        pub const rounded_r_xs = StyledM.rounded_r_xs;
        pub const rounded_r_sm = StyledM.rounded_r_sm;
        pub const rounded_r_md = StyledM.rounded_r_md;
        pub const rounded_r_lg = StyledM.rounded_r_lg;
        pub const rounded_r_xl = StyledM.rounded_r_xl;
        pub const rounded_r_2xl = StyledM.rounded_r_2xl;
        pub const rounded_r_3xl = StyledM.rounded_r_3xl;
        pub const rounded_r_full = StyledM.rounded_r_full;
        pub const rounded_l = StyledM.rounded_l;
        pub const rounded_l_none = StyledM.rounded_l_none;
        pub const rounded_l_xs = StyledM.rounded_l_xs;
        pub const rounded_l_sm = StyledM.rounded_l_sm;
        pub const rounded_l_md = StyledM.rounded_l_md;
        pub const rounded_l_lg = StyledM.rounded_l_lg;
        pub const rounded_l_xl = StyledM.rounded_l_xl;
        pub const rounded_l_2xl = StyledM.rounded_l_2xl;
        pub const rounded_l_3xl = StyledM.rounded_l_3xl;
        pub const rounded_l_full = StyledM.rounded_l_full;
        pub const rounded_tl = StyledM.rounded_tl;
        pub const rounded_tl_none = StyledM.rounded_tl_none;
        pub const rounded_tl_xs = StyledM.rounded_tl_xs;
        pub const rounded_tl_sm = StyledM.rounded_tl_sm;
        pub const rounded_tl_md = StyledM.rounded_tl_md;
        pub const rounded_tl_lg = StyledM.rounded_tl_lg;
        pub const rounded_tl_xl = StyledM.rounded_tl_xl;
        pub const rounded_tl_2xl = StyledM.rounded_tl_2xl;
        pub const rounded_tl_3xl = StyledM.rounded_tl_3xl;
        pub const rounded_tl_full = StyledM.rounded_tl_full;
        pub const rounded_tr = StyledM.rounded_tr;
        pub const rounded_tr_none = StyledM.rounded_tr_none;
        pub const rounded_tr_xs = StyledM.rounded_tr_xs;
        pub const rounded_tr_sm = StyledM.rounded_tr_sm;
        pub const rounded_tr_md = StyledM.rounded_tr_md;
        pub const rounded_tr_lg = StyledM.rounded_tr_lg;
        pub const rounded_tr_xl = StyledM.rounded_tr_xl;
        pub const rounded_tr_2xl = StyledM.rounded_tr_2xl;
        pub const rounded_tr_3xl = StyledM.rounded_tr_3xl;
        pub const rounded_tr_full = StyledM.rounded_tr_full;
        pub const rounded_bl = StyledM.rounded_bl;
        pub const rounded_bl_none = StyledM.rounded_bl_none;
        pub const rounded_bl_xs = StyledM.rounded_bl_xs;
        pub const rounded_bl_sm = StyledM.rounded_bl_sm;
        pub const rounded_bl_md = StyledM.rounded_bl_md;
        pub const rounded_bl_lg = StyledM.rounded_bl_lg;
        pub const rounded_bl_xl = StyledM.rounded_bl_xl;
        pub const rounded_bl_2xl = StyledM.rounded_bl_2xl;
        pub const rounded_bl_3xl = StyledM.rounded_bl_3xl;
        pub const rounded_bl_full = StyledM.rounded_bl_full;
        pub const rounded_br = StyledM.rounded_br;
        pub const rounded_br_none = StyledM.rounded_br_none;
        pub const rounded_br_xs = StyledM.rounded_br_xs;
        pub const rounded_br_sm = StyledM.rounded_br_sm;
        pub const rounded_br_md = StyledM.rounded_br_md;
        pub const rounded_br_lg = StyledM.rounded_br_lg;
        pub const rounded_br_xl = StyledM.rounded_br_xl;
        pub const rounded_br_2xl = StyledM.rounded_br_2xl;
        pub const rounded_br_3xl = StyledM.rounded_br_3xl;
        pub const rounded_br_full = StyledM.rounded_br_full;
        pub const shadow = StyledM.shadow;
        pub const shadow_none = StyledM.shadow_none;
        pub const shadow_2xs = StyledM.shadow_2xs;
        pub const shadow_xs = StyledM.shadow_xs;
        pub const shadow_sm = StyledM.shadow_sm;
        pub const shadow_md = StyledM.shadow_md;
        pub const shadow_lg = StyledM.shadow_lg;
        pub const shadow_xl = StyledM.shadow_xl;
        pub const shadow_2xl = StyledM.shadow_2xl;
};

/// Lazily renders `item_count` items of uniform height, drawing only the visible range
/// through `render_items` (GPUI `uniform_list`). The list scrolls vertically by default.
pub fn uniform_list(id: anytype, item_count: usize, render_items: RangeRenderer) *UniformList {
    const list = window_mod.frame_arena().create(UniformList) catch oom();
    list.* = .{
        .item_count = item_count,
        .render_items = render_items,
        .interactivity = .{
            .element_id = ElementId.from(id),
            .base_style = .{ .overflow = .{ .y = .scroll } },
        },
    };
    return list;
}

const TestAppContext = @import("../app/test_context.zig").TestAppContext;
const Action = @import("../action.zig").Action;
const Context = app_mod.Context;
const Entity = app_mod.Entity;
const Div = div.Div;

test "uniform_list: scroll strategy nearest only scrolls when the selection leaves the viewport" {
    const SelectNext = Action("example", "SelectNext");
    const SelectPrev = Action("example", "SelectPrev");

    const TestView = struct {
        const Self = @This();
        index: usize = 0,
        length: usize = 47,
        scroll_handle: UniformListScrollHandle,
        focus_handle: window_mod.FocusHandle,
        visible_range: Range = .{},

        fn build(window: *Window, app: *App) Entity(Self) {
            const focus = app.focus_handle();
            window.focus(focus);
            return app.new(Self{ .scroll_handle = UniformListScrollHandle.new(), .focus_handle = focus });
        }

        fn select_next(self: *Self, _: *const SelectNext, window: *Window, _: *Context(Self)) void {
            self.index = if (self.index + 1 == self.length) 0 else self.index + 1;
            self.scroll_handle.scroll_to_item(self.index, .nearest);
            window.refresh();
        }

        fn select_previous(self: *Self, _: *const SelectPrev, window: *Window, _: *Context(Self)) void {
            self.index = if (self.index == 0) self.length - 1 else self.index - 1;
            self.scroll_handle.scroll_to_item(self.index, .nearest);
            window.refresh();
        }

        fn render_items(self: *Self, range: Range, window: *Window, cx: *Context(Self)) []AnyElement {
            _ = window;
            _ = cx;
            self.visible_range = range;
            const items = window_mod.frame_arena().alloc(AnyElement, range.len()) catch oom();
            for (range.start..range.end, 0..) |ix, i| {
                items[i] = div.div().id(ix).h(geometry.px(20)).child(window_mod.format("Item {d}", .{ix})).into_any_element();
            }
            return items;
        }

        pub fn render(self: *Self, _: *Window, cx: *Context(Self)) *Div {
            return div.div()
                .id("list-example")
                .track_focus(&self.focus_handle)
                .on_action(SelectNext, cx.listener(select_next))
                .on_action(SelectPrev, cx.listener(select_previous))
                .size_full()
                .child(uniform_list("entries", self.length, cx.processor(render_items))
                    .track_scroll(&self.scroll_handle)
                    .h(geometry.px(200)));
        }
    };

    var cx = TestAppContext.init();
    defer cx.deinit();
    const view, const vcx = cx.add_window_view(TestView.build);

    // 10 out of 47 items are visible. The first 9 selections do not scroll.
    for (1..10) |ix| {
        vcx.dispatch_action(SelectNext{});
        const v = view.read(cx.app);
        try std.testing.expectEqual(ix, v.index);
        try std.testing.expectEqual(Range{ .start = 0, .end = 10 }, v.visible_range);
    }
    // After that, each selection scrolls the list down by one item.
    for (10..47) |ix| {
        vcx.dispatch_action(SelectNext{});
        const v = view.read(cx.app);
        try std.testing.expectEqual(ix, v.index);
        try std.testing.expectEqual(Range{ .start = ix - 9, .end = ix + 1 }, v.visible_range);
    }
    // Past the last item the selection wraps to the start.
    vcx.dispatch_action(SelectNext{});
    {
        const v = view.read(cx.app);
        try std.testing.expectEqual(@as(usize, 0), v.index);
        try std.testing.expectEqual(Range{ .start = 0, .end = 10 }, view.read(cx.app).visible_range);
    }
    // Wrap back to the last item.
    vcx.dispatch_action(SelectPrev{});
    try std.testing.expectEqual(@as(usize, 46), view.read(cx.app).index);
    try std.testing.expectEqual(Range{ .start = 37, .end = 47 }, view.read(cx.app).visible_range);
    // The first 9 selections up do not scroll.
    for (0..9) |k| {
        const ix = 45 - k;
        vcx.dispatch_action(SelectPrev{});
        const v = view.read(cx.app);
        try std.testing.expectEqual(ix, v.index);
        try std.testing.expectEqual(Range{ .start = 37, .end = 47 }, v.visible_range);
    }
    // Then each selection scrolls up by one item.
    for (0..37) |k| {
        const ix = 36 - k;
        vcx.dispatch_action(SelectPrev{});
        const v = view.read(cx.app);
        try std.testing.expectEqual(ix, v.index);
        try std.testing.expectEqual(Range{ .start = ix, .end = ix + 10 }, v.visible_range);
    }
}

test "uniform_list: logical_scroll_top_index is the pending target, then the first visible item" {
    const TestView = struct {
        const Self = @This();
        scroll_handle: UniformListScrollHandle,
        visible_range: Range = .{},

        fn build(_: *Window, app: *App) Entity(Self) {
            return app.new(Self{ .scroll_handle = UniformListScrollHandle.new() });
        }

        fn render_items(self: *Self, range: Range, _: *Window, _: *Context(Self)) []AnyElement {
            self.visible_range = range;
            const items = window_mod.frame_arena().alloc(AnyElement, range.len()) catch oom();
            for (range.start..range.end, 0..) |ix, i| {
                items[i] = div.div().id(ix).h(geometry.px(20)).child(window_mod.format("Item {d}", .{ix})).into_any_element();
            }
            return items;
        }

        pub fn render(self: *Self, _: *Window, cx: *Context(Self)) *Div {
            return div.div().size_full().child(uniform_list("entries", 47, cx.processor(render_items))
                .track_scroll(&self.scroll_handle)
                .h(geometry.px(200)));
        }
    };

    var cx = TestAppContext.init();
    defer cx.deinit();
    const view, const vcx = cx.add_window_view(TestView.build);
    vcx.run_until_parked();
    const handle = view.read(cx.app).scroll_handle;
    // Before the frame that scrolls, the answer is the item asked for.
    handle.scroll_to_item(20, .top);
    try std.testing.expectEqual(@as(usize, 20), handle.logical_scroll_top_index());
    vcx.window.refresh();
    vcx.run_until_parked();
    // Once it is drawn, the top visible item is.
    try std.testing.expectEqual(@as(usize, 20), view.read(cx.app).visible_range.start);
    try std.testing.expectEqual(@as(usize, 20), handle.logical_scroll_top_index());
}

test "uniform_list: item positions stay exact far down a 10 million item list" {
    const Entry = struct { ix: usize, top: Pixels };
    const ItemCtx = struct {
        ix: usize,
        recorded: *std.ArrayList(Entry),
        allocator: std.mem.Allocator,
    };

    const Recorder = struct {
        fn paint(ctx: ItemCtx, bounds: geometry.Bounds(Pixels), _: *Window, _: *App) void {
            ctx.recorded.append(ctx.allocator, .{ .ix = ctx.ix, .top = bounds.origin.y }) catch oom();
        }
    };

    const FarView = struct {
        const Self = @This();
        scroll_handle: UniformListScrollHandle,
        recorded: *std.ArrayList(Entry),

        fn build(_: *Window, app: *App) Entity(Self) {
            const recorded = std.testing.allocator.create(std.ArrayList(Entry)) catch oom();
            recorded.* = .empty;
            return app.new(Self{ .scroll_handle = UniformListScrollHandle.new(), .recorded = recorded });
        }

        fn render_items(self: *Self, range: Range, _: *Window, _: *Context(Self)) []AnyElement {
            const items = window_mod.frame_arena().alloc(AnyElement, range.len()) catch oom();
            for (range.start..range.end, 0..) |ix, i| {
                items[i] = element_canvas(.{ .ix = ix, .recorded = self.recorded, .allocator = std.testing.allocator });
            }
            return items;
        }

        fn element_canvas(ctx: ItemCtx) AnyElement {
            const element = @import("canvas.zig").canvas_fn(ctx, Recorder.paint).w_full().h(geometry.px(24));
            return AnyElement.new(element);
        }

        pub fn render(self: *Self, _: *Window, cx: *Context(Self)) *Div {
            return div.div().size_full().child(uniform_list("entries", 10_000_000, cx.processor(render_items))
                .track_scroll(&self.scroll_handle)
                .h(geometry.px(200)));
        }
    };

    var cx = TestAppContext.init();
    defer cx.deinit();
    const view, const vcx = cx.add_window_view(FarView.build);
    const state = view.read(cx.app);
    defer {
        state.recorded.deinit(std.testing.allocator);
        std.testing.allocator.destroy(state.recorded);
    }

    // Past 2^27px, f32 only represents multiples of 16px. The offset is 16px into item 9_000_002,
    // and the items must still be laid out 24px apart from that point.
    state.recorded.clearRetainingCapacity();
    state.scroll_handle.state.base_handle.set_offset(point(geometry.px(0), geometry.px(-216_000_064)));
    vcx.window.refresh();
    vcx.run_until_parked();

    const recorded = state.recorded.items;
    var checked: usize = 0;
    for (recorded) |entry| {
        if (entry.ix < 9_000_002 or entry.ix >= 9_000_011) continue;
        const expected: Pixels = -16 + 24 * @as(f32, @floatFromInt(entry.ix - 9_000_002));
        try std.testing.expectEqual(expected, entry.top);
        checked += 1;
    }
    try std.testing.expectEqual(@as(usize, 9), checked);
}
