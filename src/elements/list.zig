//! Port of GPUI `elements/list.rs`: a scrollable list of variable-height items. Items are
//! rendered on demand and their measured heights are cached, so only the visible range plus
//! overdraw is laid out. Keep a `ListState` on your view and pass it to `list` each frame.
//!
//! Divergences from GPUI: heights live in a Fenwick tree instead of a sum tree, every item is
//! treated as ready (no `set_item_measurement_readiness`), and autoscroll requests are not
//! honored because the window has no autoscroll channel yet.

const std = @import("std");
const geometry = @import("../geometry.zig");
const style_mod = @import("../style.zig");
const styled_mod = @import("../styled.zig");
const element_mod = @import("../element.zig");
const window_mod = @import("../window.zig");
const app_mod = @import("../app.zig");
const taffy = @import("../taffy.zig");
const interactive = @import("../interactive.zig");
const uniform_list = @import("uniform_list.zig");

const App = app_mod.App;
const EntityId = app_mod.EntityId;
const Window = window_mod.Window;
const Pixels = geometry.Pixels;
const Point = geometry.Point;
const Size = geometry.Size;
const Bounds = geometry.Bounds;
const Edges = geometry.Edges;
const point = geometry.point;
const Style = style_mod.Style;
const StyleRefinement = style_mod.StyleRefinement;
const AnyElement = element_mod.AnyElement;
const GlobalElementId = element_mod.GlobalElementId;
const LayoutId = taffy.LayoutId;
const AvailableSpace = taffy.AvailableSpace;
const Hitbox = window_mod.Hitbox;
const DispatchPhase = window_mod.DispatchPhase;
const ScrollWheelEvent = interactive.ScrollWheelEvent;
const ScrollDelta = interactive.ScrollDelta;
const Range = uniform_list.Range;

fn oom() noreturn {
    @panic("out of memory");
}

/// Whether the list scrolls from the top (most lists) or from the bottom (chat logs).
pub const ListAlignment = enum {
    /// The list scrolls from top to bottom, like most lists.
    top,
    /// The list scrolls from bottom to top, like a chat log.
    bottom,
};

/// A scroll event that has been converted to be in terms of the list's items.
pub const ListScrollEvent = struct {
    /// The range of items currently visible in the list, after applying the scroll event.
    visible_range: Range,
    /// The number of items in the list.
    count: usize,
    /// Whether the list has been scrolled away from its default position.
    is_scrolled: bool,
    /// Whether the list is currently following the tail.
    is_following_tail: bool,
};

/// Called after the list scrolls (GPUI `set_scroll_handler` closure).
pub const ScrollHandler = struct {
    ctx: *anyopaque,
    func: *const fn (ctx: *anyopaque, event: *const ListScrollEvent, window: *Window, cx: *App) void,
};

/// Renders the item at an index into the frame arena (GPUI `render_item`).
/// Build one with `Context(T).item_processor`.
pub const ItemRenderer = struct {
    ctx: *anyopaque,
    func: *const fn (ctx: *anyopaque, ix: usize, window: *Window, cx: *App) AnyElement,

    pub fn call(self: ItemRenderer, ix: usize, window: *Window, cx: *App) AnyElement {
        return self.func(self.ctx, ix, window, cx);
    }
};

/// The sizing behavior to apply during layout.
pub const ListSizingBehavior = enum {
    /// The list should calculate its size based on the size of its items.
    infer,
    /// The list should not calculate a fixed size.
    auto,
};

/// The horizontal sizing behavior to apply during layout.
pub const ListHorizontalSizingBehavior = enum {
    /// List items' width can never exceed the width of the list.
    fit_list,
    /// List items' width may go over the width of the list, if any item is wider.
    unconstrained,
};

/// The measuring behavior to apply during layout.
pub const ListMeasuringBehavior = union(enum) {
    /// Measure all items on the next layout. The flag records whether that already happened.
    measure: bool,
    /// Only measure visible items and overdraw.
    visible,

    fn reset(self: *ListMeasuringBehavior) void {
        switch (self.*) {
            .measure => self.* = .{ .measure = false },
            .visible => {},
        }
    }
};

/// Controls whether the list automatically follows new content at the end.
pub const FollowMode = enum {
    /// Normal scrolling, with no automatic following.
    normal,
    /// The list follows the tail while scrolled to the bottom.
    tail,
};

/// An offset into the list's items: an item index and pixels off that item's top.
pub const ListOffset = struct {
    /// The index of an item in the list.
    item_ix: usize = 0,
    /// The number of pixels to offset from the item index.
    offset_in_item: Pixels = 0,
};

const PendingScroll = union(enum) {
    absolute: Pixels,
    proportional: f32,
};

const ScrollAnchor = struct {
    position: ListOffset,
    pending: ?PendingScroll = null,
};

const FollowState = enum {
    normal,
    tail_following,
    tail_stopped,

    fn start_following(self: *FollowState) void {
        if (self.* == .tail_stopped) self.* = .tail_following;
    }

    fn stop_following(self: *FollowState) void {
        if (self.* == .tail_following) self.* = .tail_stopped;
    }
};

/// Measured or estimated size of one item.
const ListItem = struct {
    measured: ?Size(Pixels) = null,
    size_hint: ?Size(Pixels) = null,
    /// Set by `ListState.splice_focusable`. A focused item stays rendered when it scrolls out of view.
    focus_handle: ?window_mod.FocusHandle = null,

    fn current_size_hint(self: ListItem) ?Size(Pixels) {
        return self.measured orelse self.size_hint;
    }

    fn height(self: ListItem) f64 {
        const s = self.current_size_hint() orelse return 0;
        return @floatCast(s.height);
    }

    fn is_unknown(self: ListItem) bool {
        return self.measured == null and self.size_hint == null;
    }
};

/// Prefix sums over item heights, as a Fenwick tree with 1-based indices.
const HeightIndex = struct {
    values: std.ArrayList(f64) = .empty,
    tree: std.ArrayList(f64) = .empty,

    fn len(self: *const HeightIndex) usize {
        return self.values.items.len;
    }

    /// Recomputes every height from `items` in O(n).
    fn rebuild(self: *HeightIndex, allocator: std.mem.Allocator, items: []const ListItem) void {
        const n = items.len;
        self.values.resize(allocator, n) catch oom();
        self.tree.resize(allocator, n + 1) catch oom();
        for (items, 0..) |item, i| self.values.items[i] = item.height();
        self.tree.items[0] = 0;
        for (1..n + 1) |i| self.tree.items[i] = self.values.items[i - 1];
        for (1..n + 1) |i| {
            const j = i + lowbit(i);
            if (j <= n) self.tree.items[j] += self.tree.items[i];
        }
    }

    fn set(self: *HeightIndex, ix: usize, height: f64) void {
        const delta = height - self.values.items[ix];
        if (delta == 0) return;
        self.values.items[ix] = height;
        const n = self.len();
        var i = ix + 1;
        while (i <= n) : (i += lowbit(i)) self.tree.items[i] += delta;
    }

    /// Sum of the heights of the first `count` items.
    fn prefix(self: *const HeightIndex, count: usize) f64 {
        var i = @min(count, self.len());
        var sum: f64 = 0;
        while (i > 0) : (i -= lowbit(i)) sum += self.tree.items[i];
        return sum;
    }

    fn total(self: *const HeightIndex) f64 {
        return self.prefix(self.len());
    }

    /// Largest count `c` with `prefix(c) <= h` (strict: `< h`), found by a Fenwick descent.
    fn search(self: *const HeightIndex, h: f64, strict: bool) usize {
        const n = self.len();
        if (n == 0) return 0;
        var pos: usize = 0;
        var sum: f64 = 0;
        var step: usize = @as(usize, 1) << std.math.log2_int(usize, n);
        while (step > 0) : (step >>= 1) {
            const next = pos + step;
            if (next <= n) {
                const candidate = sum + self.tree.items[next];
                const fits = if (strict) candidate < h else candidate <= h;
                if (fits) {
                    pos = next;
                    sum = candidate;
                }
            }
        }
        return pos;
    }

};

fn lowbit(i: usize) usize {
    return i & (0 -% i);
}

/// The shared state of a list, kept by the view across frames (GPUI `StateInner`).
const StateInner = struct {
    allocator: std.mem.Allocator,
    last_layout_bounds: ?Bounds(Pixels) = null,
    last_padding: ?Edges(Pixels) = null,
    items: std.ArrayList(ListItem) = .empty,
    heights: HeightIndex = .{},
    unknown_count: usize = 0,
    scroll_anchor: ?ScrollAnchor = null,
    alignment: ListAlignment,
    overdraw: Pixels,
    reset: bool = false,
    scroll_handler: ?ScrollHandler = null,
    measuring_behavior: ListMeasuringBehavior = .visible,
    follow_state: FollowState = .normal,
    /// Content height when a scrollbar drag began; null when no drag is in progress.
    scrollbar_drag_start_height: ?Pixels = null,

    fn count(self: *const StateInner) usize {
        return self.items.items.len;
    }

    fn total_height(self: *const StateInner) Pixels {
        return @floatCast(self.heights.total());
    }

    fn prefix_px(self: *const StateInner, item_ix: usize) Pixels {
        return @floatCast(self.heights.prefix(item_ix));
    }

    fn scroll_top_px(self: *const StateInner, top: ListOffset) Pixels {
        return self.prefix_px(top.item_ix) + top.offset_in_item;
    }

    fn logical_scroll_top(self: *const StateInner) ListOffset {
        if (self.scroll_anchor) |anchor| return anchor.position;
        return switch (self.alignment) {
            .top => .{ .item_ix = 0, .offset_in_item = 0 },
            .bottom => .{ .item_ix = self.count(), .offset_in_item = 0 },
        };
    }

    /// Replaces the item at `ix`, keeping the height index and unknown count in sync.
    fn set_item(self: *StateInner, ix: usize, item: ListItem) void {
        const old = self.items.items[ix];
        if (old.is_unknown()) self.unknown_count -= 1;
        var stored = item;
        stored.focus_handle = old.focus_handle;
        if (stored.is_unknown()) self.unknown_count += 1;
        self.items.items[ix] = stored;
        self.heights.set(ix, item.height());
    }

    fn rebuild_heights(self: *StateInner) void {
        self.heights.rebuild(self.allocator, self.items.items);
        self.unknown_count = 0;
        for (self.items.items) |item| {
            if (item.is_unknown()) self.unknown_count += 1;
        }
    }

    /// Replaces `old_len` items at `start` with `new_len` unmeasured items.
    fn splice_items(self: *StateInner, start: usize, old_len: usize, new_len: usize) void {
        var next: std.ArrayList(ListItem) = .empty;
        const total = self.count() - old_len + new_len;
        next.ensureTotalCapacity(self.allocator, total) catch oom();
        next.appendSliceAssumeCapacity(self.items.items[0..start]);
        for (0..new_len) |_| next.appendAssumeCapacity(.{});
        next.appendSliceAssumeCapacity(self.items.items[start + old_len ..]);
        self.items.deinit(self.allocator);
        self.items = next;
        self.rebuild_heights();
    }

    fn set_scroll_anchor(self: *StateInner, position: ?ListOffset) void {
        const pos = position orelse {
            self.scroll_anchor = null;
            return;
        };
        var pending: ?PendingScroll = null;
        if (self.scroll_anchor) |anchor| {
            if (anchor.pending) |p| {
                if (pos.item_ix < self.count()) {
                    pending = switch (p) {
                        .absolute => .{ .absolute = pos.offset_in_item },
                        .proportional => blk: {
                            const hint = self.items.items[pos.item_ix].size_hint orelse break :blk null;
                            if (hint.height <= 0) break :blk null;
                            break :blk PendingScroll{ .proportional = std.math.clamp(pos.offset_in_item / hint.height, 0, 1) };
                        },
                    };
                }
            }
        }
        self.scroll_anchor = .{ .position = pos, .pending = pending };
    }

    fn visible_range(self: *const StateInner, height: Pixels, top: ListOffset) Range {
        const start_y = self.scroll_top_px(top);
        const pos = self.heights.search(@as(f64, start_y + height), true);
        return .{ .start = top.item_ix, .end = @max(top.item_ix, @min(pos + 1, self.count())) };
    }

    fn scroll(
        self: *StateInner,
        scroll_top: ListOffset,
        height: Pixels,
        delta: Point(Pixels),
        current_view: ?EntityId,
        window: *Window,
        cx: *App,
    ) void {
        // Scroll events are dropped after a reset, since the logical scroll top is unknown until layout.
        if (self.reset or delta.y == 0) return;
        const padding = self.last_padding orelse Edges(Pixels){};
        const scroll_max = @max(self.total_height() + padding.top + padding.bottom - height, 0);
        const new_scroll_top = std.math.clamp(self.scroll_top_px(scroll_top) - delta.y, 0, scroll_max);
        if (self.alignment == .bottom and new_scroll_top == scroll_max) {
            self.set_scroll_anchor(null);
        } else {
            self.set_scroll_anchor(self.offset_for_height(new_scroll_top));
        }
        if (delta.y > 0) self.follow_state.stop_following();
        if (self.scroll_handler) |handler| {
            const event: ListScrollEvent = .{
                .visible_range = self.visible_range(height, scroll_top),
                .count = self.count(),
                .is_scrolled = self.scroll_anchor != null,
                .is_following_tail = self.follow_state == .tail_following,
            };
            handler.func(handler.ctx, &event, window, cx);
        }
        if (current_view) |id| cx.notify(id);
    }

    /// The item and pixel offset at the vertical position `h` (GPUI `find(Height(h), Right)`).
    fn offset_for_height(self: *const StateInner, h: Pixels) ListOffset {
        const ix = self.heights.search(@as(f64, h), false);
        return .{ .item_ix = ix, .offset_in_item = h - self.prefix_px(ix) };
    }

    /// Lays out every item once, for `ListMeasuringBehavior.measure`.
    fn layout_all_items(self: *StateInner, available_width: Pixels, renderer: ItemRenderer, window: *Window, cx: *App) void {
        switch (self.measuring_behavior) {
            .visible => return,
            .measure => |has_measured| {
                if (has_measured) return;
                self.measuring_behavior = .{ .measure = true };
            },
        }
        const available_item_space: Size(AvailableSpace) = .{
            .width = .{ .definite = available_width },
            .height = .min_content,
        };
        for (0..self.count()) |ix| {
            const item = self.items.items[ix];
            const size_ = item.measured orelse blk: {
                const element = renderer.call(ix, window, cx);
                break :blk element.layout_as_root(available_item_space, window, cx);
            };
            self.set_item(ix, .{ .measured = size_ });
        }
        self.measuring_behavior = .{ .measure = true };
    }

    fn any_laid_out_item_focused(self: *const StateInner, layouts: []const ItemLayout, window: *const Window, cx: *const App) bool {
        for (layouts) |layout| {
            const handle = self.items.items[layout.index].focus_handle orelse continue;
            if (handle.contains_focused(window, cx)) return true;
        }
        return false;
    }

    /// Lays out the items that are visible or in overdraw around `scroll_top`, and updates the
    /// cached sizes of every item laid out (GPUI `layout_items`).
    fn layout_items(
        self: *StateInner,
        available_width: ?Pixels,
        available_height: Pixels,
        padding: Edges(Pixels),
        renderer: ItemRenderer,
        window: *Window,
        cx: *App,
    ) LayoutItemsResponse {
        const arena = window_mod.frame_arena();
        var rendered_height: Pixels = padding.top;
        var max_item_width: Pixels = 0;
        var scroll_top = self.logical_scroll_top();
        if (self.follow_state == .tail_following) {
            scroll_top = .{ .item_ix = self.count(), .offset_in_item = 0 };
            self.set_scroll_anchor(scroll_top);
        }
        const preserve_anchor = scroll_top.item_ix < self.count();
        if (!preserve_anchor) self.follow_state.start_following();

        const available_item_space: Size(AvailableSpace) = .{
            .width = if (available_width) |w| .{ .definite = w } else .max_content,
            .height = .min_content,
        };

        // Forward walk over visible items and trailing overdraw, from the scroll top.
        const forward_start = scroll_top.item_ix;
        var forward_layouts: std.ArrayList(ItemLayout) = .empty;
        var forward_sizes: std.ArrayList(Size(Pixels)) = .empty;
        var ix = forward_start;
        while (ix < self.count()) : (ix += 1) {
            const local_ix = ix - forward_start;
            const visible_height = rendered_height - scroll_top.offset_in_item;
            if (visible_height >= available_height + self.overdraw) break;
            const item = self.items.items[ix];
            var element_size: Size(Pixels) = undefined;
            if (visible_height >= available_height and item.measured != null) {
                element_size = item.measured.?;
            } else {
                const element = renderer.call(ix, window, cx);
                element_size = element.layout_as_root(available_item_space, window, cx);
                if (local_ix == 0) {
                    if (self.scroll_anchor) |*anchor| {
                        if (anchor.pending) |pending| {
                            scroll_top.offset_in_item = switch (pending) {
                                .absolute => |offset| @min(offset, element_size.height),
                                .proportional => |fraction| element_size.height * fraction,
                            };
                            anchor.position = scroll_top;
                            anchor.pending = null;
                        }
                    }
                }
                if (visible_height < available_height) {
                    forward_layouts.append(arena, .{ .index = ix, .element = element, .size = element_size }) catch oom();
                }
            }
            rendered_height += element_size.height;
            max_item_width = @max(max_item_width, element_size.width);
            forward_sizes.append(arena, element_size) catch oom();
        }
        rendered_height += padding.bottom;

        // Items before the scroll top are rendered when the visible ones do not fill the list.
        var first_ix = @min(forward_start, self.count());
        var backward_layouts: std.ArrayList(ItemLayout) = .empty;
        var backward_sizes: std.ArrayList(Size(Pixels)) = .empty;
        if (rendered_height - scroll_top.offset_in_item < available_height) {
            while (rendered_height < available_height) {
                if (first_ix == 0) break;
                first_ix -= 1;
                const element = renderer.call(first_ix, window, cx);
                const element_size = element.layout_as_root(available_item_space, window, cx);
                rendered_height += element_size.height;
                backward_sizes.append(arena, element_size) catch oom();
                backward_layouts.append(arena, .{ .index = first_ix, .element = element, .size = element_size }) catch oom();
            }
            scroll_top = .{ .item_ix = first_ix, .offset_in_item = rendered_height - available_height };
            switch (self.alignment) {
                .top => {
                    scroll_top.offset_in_item = @max(scroll_top.offset_in_item, 0);
                    self.set_scroll_anchor(scroll_top);
                },
                .bottom => self.set_scroll_anchor(null),
            }
        }

        // Measure items in the leading overdraw, which are not painted.
        var leading_overdraw = scroll_top.offset_in_item;
        while (leading_overdraw < self.overdraw) {
            if (first_ix == 0) break;
            first_ix -= 1;
            const size_ = self.items.items[first_ix].measured orelse blk: {
                const element = renderer.call(first_ix, window, cx);
                break :blk element.layout_as_root(available_item_space, window, cx);
            };
            leading_overdraw += size_.height;
            backward_sizes.append(arena, size_) catch oom();
        }

        // Write back the measurements: backward items in ascending order, then forward items.
        var write_ix = first_ix;
        var k = backward_sizes.items.len;
        while (k > 0) {
            k -= 1;
            self.set_item(write_ix, .{ .measured = backward_sizes.items[k] });
            write_ix += 1;
        }
        for (forward_sizes.items) |s| {
            self.set_item(write_ix, .{ .measured = s });
            write_ix += 1;
        }

        var item_layouts: std.ArrayList(ItemLayout) = .empty;
        k = backward_layouts.items.len;
        while (k > 0) {
            k -= 1;
            item_layouts.append(arena, backward_layouts.items[k]) catch oom();
        }
        for (forward_layouts.items) |layout| item_layouts.append(arena, layout) catch oom();

        // None of the visible items has the focus: render the first focused item past them, so that
        // it keeps receiving keyboard input. It lies outside the list's bounds, so it is not painted.
        if (!self.any_laid_out_item_focused(item_layouts.items, window, cx)) {
            for (self.items.items, 0..) |item, focus_ix| {
                const handle = item.focus_handle orelse continue;
                if (!handle.contains_focused(window, cx)) continue;
                const element = renderer.call(focus_ix, window, cx);
                const element_size = element.layout_as_root(available_item_space, window, cx);
                item_layouts.append(arena, .{ .index = focus_ix, .element = element, .size = element_size }) catch oom();
                break;
            }
        }

        // Resume following once the user scrolls back to the bottom.
        if (self.follow_state == .tail_stopped) {
            const last_padding = self.last_padding orelse Edges(Pixels){};
            const total = self.total_height() + last_padding.top + last_padding.bottom;
            const scroll_offset = self.scroll_top_px(scroll_top);
            if (scroll_offset + available_height >= total - 1) self.follow_state.start_following();
        }

        return .{ .max_item_width = max_item_width, .scroll_top = scroll_top, .item_layouts = item_layouts };
    }

    /// Lays out and prepaints the visible items. An item that requests autoscroll (GPUI
    /// `request_autoscroll`) moves the scroll position, and the items are prepainted again from there,
    /// without autoscroll the second time (GPUI's retry loop around `prepaint_items`).
    fn prepaint_items(
        self: *StateInner,
        bounds: Bounds(Pixels),
        padding: Edges(Pixels),
        renderer: ItemRenderer,
        window: *Window,
        cx: *App,
    ) LayoutItemsResponse {
        var autoscroll = true;
        while (true) {
            var attempt: PrepaintAttempt = .{ .state = self, .bounds = bounds, .padding = padding, .autoscroll = autoscroll, .renderer = renderer, .cx = cx };
            if (window.transact(&attempt, PrepaintAttempt.run)) |_| {
                return attempt.response;
            } else |_| {
                self.set_scroll_anchor(attempt.request);
                autoscroll = false;
            }
        }
    }

    fn snap_to_end(self: *StateInner) void {
        self.set_scroll_anchor(.{ .item_ix = self.count(), .offset_in_item = 0 });
    }
};

/// One attempt at prepainting the visible items, run inside `Window.transact` so that a retry leaves
/// nothing from the failed one behind (GPUI's closure in `prepaint_items`).
const PrepaintAttempt = struct {
    state: *StateInner,
    bounds: Bounds(Pixels),
    padding: Edges(Pixels),
    autoscroll: bool,
    renderer: ItemRenderer,
    cx: *App,
    response: LayoutItemsResponse = undefined,
    /// Where to scroll to show the requested area, set when `run` returns `error.Autoscroll`.
    request: ListOffset = .{ .item_ix = 0, .offset_in_item = 0 },

    fn run(self: *PrepaintAttempt, window: *Window) error{Autoscroll}!void {
        const state = self.state;
        switch (state.measuring_behavior) {
            .measure => |has_measured| if (!has_measured) state.layout_all_items(self.bounds.size.width, self.renderer, window, self.cx),
            .visible => {},
        }
        var response = state.layout_items(self.bounds.size.width, self.bounds.size.height, self.padding, self.renderer, window, self.cx);
        // A request made while laying out came from outside the items, so it is not ours to honor.
        _ = window.take_autoscroll();

        // Paint only the visible items, when there is space for them past the padding.
        if (self.bounds.size.height > self.padding.top + self.padding.bottom) {
            var item_origin = self.bounds.origin.add(point(@as(Pixels, 0), self.padding.top));
            item_origin.y -= response.scroll_top.offset_in_item;
            for (response.item_layouts.items) |*item| {
                window.push_content_mask(.{ .bounds = self.bounds });
                item.element.prepaint_at(item_origin, window, self.cx);
                window.pop_content_mask();

                const requested = window.take_autoscroll();
                if (requested) |area| if (self.autoscroll) {
                    if (area.origin.y < self.bounds.origin.y) {
                        self.request = self.top_request(item.index, item_origin.y, area.origin.y, window);
                        return error.Autoscroll;
                    }
                    if (area.origin.y + area.size.height > self.bounds.origin.y + self.bounds.size.height) {
                        self.request = self.bottom_request(item.index, item_origin.y, area.origin.y + area.size.height, window);
                        return error.Autoscroll;
                    }
                };
                item_origin.y += item.size.height;
            }
        } else {
            response.item_layouts.clearRetainingCapacity();
        }
        self.response = response;
    }

    /// The offset that puts the top of the requested area at the top of the list. It walks back
    /// through earlier items when the area starts above item `item_index` (GPUI's top branch).
    fn top_request(self: *PrepaintAttempt, item_index: usize, item_origin_y: Pixels, area_top: Pixels, window: *Window) ListOffset {
        var ix = item_index;
        var offset = area_top - item_origin_y;
        while (offset < 0) {
            if (ix == 0) {
                offset = 0;
                break;
            }
            ix -= 1;
            offset += self.item_height(ix, window);
        }
        return .{ .item_ix = ix, .offset_in_item = offset };
    }

    /// The offset that puts the bottom of the requested area at the bottom of the list, walking back
    /// through earlier items to fill the space above it (GPUI's bottom branch).
    fn bottom_request(self: *PrepaintAttempt, item_index: usize, item_origin_y: Pixels, area_bottom: Pixels, window: *Window) ListOffset {
        var ix = item_index;
        var height = self.bounds.size.height - self.padding.top - self.padding.bottom;
        height -= area_bottom - item_origin_y;
        while (height > 0) {
            if (ix == 0) break;
            ix -= 1;
            height -= self.item_height(ix, window);
        }
        return .{ .item_ix = ix, .offset_in_item = if (height < 0) -height else 0 };
    }

    /// The height of item `ix`: its measured one, or one it is laid out for now (GPUI `size` or `layout_as_root`).
    fn item_height(self: *PrepaintAttempt, ix: usize, window: *Window) Pixels {
        if (self.state.items.items[ix].measured) |measured| return measured.height;
        const element = self.renderer.call(ix, window, self.cx);
        const laid_out = element.layout_as_root(.{ .width = .{ .definite = self.bounds.size.width }, .height = .min_content }, window, self.cx);
        return laid_out.height;
    }
};

/// Result of laying out the visible items (GPUI `LayoutItemsResponse`).
const LayoutItemsResponse = struct {
    max_item_width: Pixels,
    scroll_top: ListOffset,
    item_layouts: std.ArrayList(ItemLayout),
};

const ItemLayout = struct {
    index: usize,
    element: AnyElement,
    size: Size(Pixels),
};

/// Frame state of the `List` element after prepaint (GPUI `ListPrepaintState`).
pub const ListPrepaintState = struct {
    hitbox: Hitbox,
    layout: LayoutItemsResponse,
};

/// The list state that views hold on behalf of a `List` element (GPUI `ListState`).
/// Copies share the same state.
pub const ListState = struct {
    inner: *StateInner,

    /// Creates a list of `item_count` items. The overdraw is how far beyond the viewport items are laid out.
    pub fn new(initial_count: usize, alignment: ListAlignment, overdraw: Pixels) ListState {
        const allocator = std.heap.smp_allocator;
        const inner = allocator.create(StateInner) catch oom();
        inner.* = .{ .allocator = allocator, .alignment = alignment, .overdraw = overdraw };
        const state: ListState = .{ .inner = inner };
        state.splice(.{ .start = 0, .end = 0 }, initial_count);
        return state;
    }

    /// Frees the state. Only call this once no element uses the list.
    pub fn deinit(self: ListState) void {
        self.inner.items.deinit(self.inner.allocator);
        self.inner.heights.values.deinit(self.inner.allocator);
        self.inner.heights.tree.deinit(self.inner.allocator);
        self.inner.allocator.destroy(self.inner);
    }

    /// Measures all items on the first layout, so the scrollbar size is exact.
    pub fn measure_all(self: ListState) ListState {
        self.inner.measuring_behavior = .{ .measure = false };
        return self;
    }

    /// Pre-populates every unmeasured item with a uniform height hint.
    pub fn with_uniform_item_height(self: ListState, height: Pixels) ListState {
        self.apply_uniform_item_height(height);
        return self;
    }

    /// Resets the list to `element_count` items. Scroll events are dropped until the next paint.
    pub fn reset(self: ListState, element_count: usize) void {
        const state = self.inner;
        state.reset = true;
        state.measuring_behavior.reset();
        state.set_scroll_anchor(null);
        self.splice(.{ .start = 0, .end = state.count() }, element_count);
    }

    /// Like `reset`, with every item pre-populated with a uniform height hint.
    pub fn reset_with_uniform_height(self: ListState, element_count: usize, height: Pixels) void {
        self.reset(element_count);
        self.apply_uniform_item_height(height);
    }

    fn apply_uniform_item_height(self: ListState, height: Pixels) void {
        const state = self.inner;
        const default_hint: Size(Pixels) = .{ .width = 0, .height = height };
        for (state.items.items) |*item| {
            item.* = .{ .measured = null, .size_hint = item.current_size_hint() orelse default_hint };
        }
        state.rebuild_heights();
    }

    /// Remeasures every item, keeping the proportional scroll position.
    pub fn remeasure(self: ListState) void {
        self.remeasure_items_with_mode(.{ .start = 0, .end = self.inner.count() }, .proportional);
    }

    /// Marks the items in `range` for remeasurement, keeping the absolute scroll position.
    pub fn remeasure_items(self: ListState, range: Range) void {
        self.remeasure_items_with_mode(range, .absolute);
    }

    const RemeasureMode = enum { absolute, proportional };

    fn remeasure_items_with_mode(self: ListState, range: Range, mode: RemeasureMode) void {
        const state = self.inner;
        const end = @min(range.end, state.count());
        if (state.scroll_anchor) |anchor| {
            if (anchor.position.item_ix >= range.start and anchor.position.item_ix < end) {
                const pending: ?PendingScroll = switch (mode) {
                    .absolute => PendingScroll{ .absolute = anchor.position.offset_in_item },
                    .proportional => blk: {
                        const measured = state.items.items[anchor.position.item_ix].measured orelse break :blk anchor.pending;
                        const fraction: f32 = if (measured.height > 0)
                            std.math.clamp(anchor.position.offset_in_item / measured.height, 0, 1)
                        else
                            0;
                        break :blk PendingScroll{ .proportional = fraction };
                    },
                };
                state.scroll_anchor.?.pending = pending;
            }
        }
        for (range.start..end) |ix| {
            const item = state.items.items[ix];
            state.set_item(ix, .{ .measured = null, .size_hint = item.current_size_hint() });
        }
        state.measuring_behavior.reset();
    }

    /// The number of items in the list.
    pub fn item_count(self: ListState) usize {
        return self.inner.count();
    }

    /// Whether the list is scrolled to its end, or null when it is not scrollable or its
    /// content height is not yet known.
    pub fn is_scrolled_to_end(self: ListState) ?bool {
        const state = self.inner;
        const bounds = state.last_layout_bounds orelse return null;
        if (state.unknown_count > 0) return null;
        const padding = state.last_padding orelse Edges(Pixels){};
        const content_height = state.total_height() + padding.top + padding.bottom;
        const scroll_max = @max(content_height - bounds.size.height, 0);
        if (scroll_max <= 0) return null;
        return state.scroll_top_px(state.logical_scroll_top()) >= scroll_max;
    }

    /// Tells the list that the items in `old_range` were replaced by `count` items to measure.
    pub fn splice(self: ListState, old_range: Range, count: usize) void {
        const state = self.inner;
        const start = @min(old_range.start, state.count());
        const end = @max(start, @min(old_range.end, state.count()));
        state.splice_items(start, end - start, count);
        if (state.scroll_anchor) |*anchor| {
            if (anchor.position.item_ix >= start and anchor.position.item_ix < end) {
                anchor.position = .{ .item_ix = start, .offset_in_item = 0 };
                anchor.pending = null;
            } else if (end <= anchor.position.item_ix) {
                anchor.position.item_ix = anchor.position.item_ix - (end - start) + count;
            }
        }
    }

    /// Like `splice`, and gives each new item its focus handle (`null` for an item that cannot take
    /// focus). A focused item that scrolls out of view is still rendered after the visible ones, so
    /// keyboard interaction with it continues (GPUI `splice_focusable`; a slice takes the place of
    /// its iterator).
    pub fn splice_focusable(self: ListState, old_range: Range, focus_handles: []const ?window_mod.FocusHandle) void {
        self.splice(old_range, focus_handles.len);
        const state = self.inner;
        const start = @min(old_range.start, state.count());
        for (focus_handles, 0..) |handle, i| {
            if (start + i >= state.count()) break;
            state.items.items[start + i].focus_handle = handle;
        }
    }

    /// Sets the handler called after the list scrolls.
    pub fn set_scroll_handler(self: ListState, handler: ScrollHandler) void {
        self.inner.scroll_handler = handler;
    }

    /// The current scroll offset, in terms of the list's items.
    pub fn logical_scroll_top(self: ListState) ListOffset {
        return self.inner.logical_scroll_top();
    }

    /// Scrolls the list by `distance` pixels, positive towards the end.
    pub fn scroll_by(self: ListState, distance: Pixels) void {
        if (distance == 0) return;
        const state = self.inner;
        const current = state.logical_scroll_top();
        if (distance < 0) state.follow_state.stop_following();
        const start_pixel = state.scroll_top_px(current);
        const new_pixel = @max(start_pixel + distance, 0);
        state.set_scroll_anchor(state.offset_for_height(new_pixel));
    }

    /// Called when the user starts dragging the scrollbar. The content height is frozen until
    /// `scrollbar_drag_ended`, so the thumb stays put while items are measured (GPUI `scrollbar_drag_started`).
    pub fn scrollbar_drag_started(self: ListState) void {
        self.inner.scrollbar_drag_start_height = self.inner.total_height();
    }

    /// Called when the user stops dragging the scrollbar (GPUI `scrollbar_drag_ended`).
    pub fn scrollbar_drag_ended(self: ListState) void {
        self.inner.scrollbar_drag_start_height = null;
    }

    /// Whether a scrollbar drag is in progress (GPUI `is_scrollbar_dragging`).
    pub fn is_scrollbar_dragging(self: ListState) bool {
        return self.inner.scrollbar_drag_start_height != null;
    }

    /// Scrolls to the position the scrollbar thumb is at. `point.y` is the non-positive offset from
    /// `scroll_px_offset_for_scrollbar`. Dragging to the frozen end resumes following the tail, if
    /// the list follows it (GPUI `set_offset_from_scrollbar`).
    pub fn set_offset_from_scrollbar(self: ListState, offset: Point(Pixels)) void {
        const state = self.inner;
        const bounds = state.last_layout_bounds orelse return;
        const padding = state.last_padding orelse Edges(Pixels){};
        // The drag maps positions with the height it started with, so the thumb stays consistent.
        const content_height = state.scrollbar_drag_start_height orelse state.total_height();
        const scroll_max = @max(content_height + padding.top + padding.bottom - bounds.size.height, 0);
        const new_scroll_top = std.math.clamp(-offset.y, 0, scroll_max);
        // Content may have grown during the drag, so the frozen end can be above the live one.
        const dragged_to_end = scroll_max > 0 and new_scroll_top >= @max(scroll_max - 1, 0);
        if (dragged_to_end and state.follow_state != .normal) {
            state.follow_state = .tail_following;
            state.set_scroll_anchor(.{ .item_ix = state.count(), .offset_in_item = 0 });
            return;
        }
        state.follow_state.stop_following();
        if (state.alignment == .bottom and new_scroll_top == scroll_max) {
            state.set_scroll_anchor(null);
        } else {
            state.set_scroll_anchor(state.offset_for_height(new_scroll_top));
        }
    }

    /// Scrolls to the very end, past the last item. Layout walks back from the end, so the
    /// bottom of the last item stays visible even while it grows.
    pub fn scroll_to_end(self: ListState) void {
        self.inner.set_scroll_anchor(.{ .item_ix = self.inner.count(), .offset_in_item = 0 });
    }

    /// Sets the follow mode. In `tail` mode the list snaps to the end on each layout and
    /// resumes following once the user scrolls back to the bottom.
    pub fn set_follow_mode(self: ListState, mode: FollowMode) void {
        const state = self.inner;
        if (mode == .normal) self.pause_following_tail();
        switch (mode) {
            .normal => state.follow_state = .normal,
            .tail => {
                state.follow_state = .tail_following;
                state.snap_to_end();
            },
        }
    }

    /// Freezes the list at its current position, keeping tail mode so it resumes at the bottom.
    pub fn pause_following_tail(self: ListState) void {
        self.inner.follow_state.stop_following();
    }

    /// Whether the list is actively following the tail.
    pub fn is_following_tail(self: ListState) bool {
        return self.inner.follow_state == .tail_following;
    }

    /// Scrolls the list to the given offset.
    pub fn scroll_to(self: ListState, scroll_top: ListOffset) void {
        const state = self.inner;
        var top = scroll_top;
        if (top.item_ix >= state.count()) {
            top = .{ .item_ix = state.count(), .offset_in_item = 0 };
        }
        if (top.item_ix < state.count()) state.follow_state.stop_following();
        state.set_scroll_anchor(top);
    }

    /// Scrolls the minimum distance that makes item `ix` fully visible.
    pub fn scroll_to_reveal_item(self: ListState, ix: usize) void {
        const state = self.inner;
        var scroll_top = state.logical_scroll_top();
        const height: Pixels = if (state.last_layout_bounds) |b| b.size.height else 0;
        const padding = state.last_padding orelse Edges(Pixels){};
        if (ix <= scroll_top.item_ix) {
            scroll_top = .{ .item_ix = ix, .offset_in_item = 0 };
        } else {
            const bottom = state.prefix_px(ix + 1) + padding.top;
            const goal_top = @max(0, bottom - height + padding.bottom);
            const start_ix = state.heights.search(@as(f64, goal_top), true);
            const start_item_top = state.prefix_px(start_ix);
            if (start_ix >= scroll_top.item_ix) {
                scroll_top = .{ .item_ix = start_ix, .offset_in_item = goal_top - start_item_top };
            }
        }
        state.set_scroll_anchor(scroll_top);
    }

    /// The bounds of item `ix` in window coordinates, if it has been laid out.
    pub fn bounds_for_item(self: ListState, ix: usize) ?Bounds(Pixels) {
        const state = self.inner;
        const bounds = state.last_layout_bounds orelse Bounds(Pixels){};
        const scroll_top = state.logical_scroll_top();
        if (ix < scroll_top.item_ix or ix >= state.count()) return null;
        const item = state.items.items[ix];
        const measured = item.measured orelse return null;
        const scroll_top_px = state.scroll_top_px(scroll_top);
        const top = bounds.top() + state.prefix_px(ix) - scroll_top_px;
        return Bounds(Pixels).from_corners(
            point(bounds.left(), top),
            point(bounds.right(), top + measured.height),
        );
    }

    /// The maximum scroll offset of the measured content, as a non-positive offset.
    pub fn max_offset_for_scrollbar(self: ListState) Point(Pixels) {
        const state = self.inner;
        const bounds = state.last_layout_bounds orelse Bounds(Pixels){};
        return .{ .x = 0, .y = @max(state.total_height() - bounds.size.height, 0) };
    }

    /// The current scroll offset in pixels, for scrollbars, as a non-positive offset.
    pub fn scroll_px_offset_for_scrollbar(self: ListState) Point(Pixels) {
        const state = self.inner;
        if (state.scroll_anchor == null and state.alignment == .bottom) {
            return .{ .x = 0, .y = -self.max_offset_for_scrollbar().y };
        }
        return .{ .x = 0, .y = -state.scroll_top_px(state.logical_scroll_top()) };
    }

    /// The bounds of the viewport in pixels.
    pub fn viewport_bounds(self: ListState) Bounds(Pixels) {
        return self.inner.last_layout_bounds orelse Bounds(Pixels){};
    }

    /// Whether item `ix` is entirely above the viewport, or null before the list is laid out.
    /// A zero-height viewport still answers, so callers do not see the answer flicker.
    pub fn item_is_above_viewport(self: ListState, ix: usize) ?bool {
        const viewport = self.inner.last_layout_bounds orelse return null;
        if (ix < self.inner.logical_scroll_top().item_ix) return true;
        const item_bounds = self.bounds_for_item(ix) orelse return null;
        return item_bounds.bottom() <= viewport.top();
    }

    /// Whether item `ix` is entirely below the viewport, or null before the list is laid out.
    pub fn item_is_below_viewport(self: ListState, ix: usize) ?bool {
        const viewport = self.inner.last_layout_bounds orelse return null;
        if (ix < self.inner.logical_scroll_top().item_ix) return false;
        const item_bounds = self.bounds_for_item(ix) orelse return null;
        return item_bounds.top() >= viewport.bottom();
    }
};

/// A list element (GPUI `List`), created by `list`.
pub const List = struct {
    state: ListState,
    render_item: ItemRenderer,
    base_style: StyleRefinement = .{},
    sizing_behavior: ListSizingBehavior = .auto,

    pub const RequestLayoutState = struct {};
    pub const PrepaintState = ListPrepaintState;

    const StyledM = styled_mod.Styled(*List);

        pub fn style(self: *List) *StyleRefinement {
        return &self.base_style;
    }

    pub fn into_any_element(self: *List) AnyElement {
        return AnyElement.new(self);
    }

    /// Sets the sizing behavior for the list.
    pub fn with_sizing_behavior(self: *List, behavior: ListSizingBehavior) *List {
        self.sizing_behavior = behavior;
        return self;
    }

    /// Measured size of an `infer`-sized list (GPUI `request_measured_layout` closure).
    const MeasuredSize = struct {
        max_item_width: Pixels,
        total_height: Pixels,

        fn measure(ctx: *anyopaque, known: Size(?Pixels), available: Size(AvailableSpace), _: *Window, _: *App) Size(Pixels) {
            const measured_size: *const MeasuredSize = @ptrCast(@alignCast(ctx));
            const width = known.width orelse switch (available.width) {
                .definite => |x| x,
                .min_content, .max_content => measured_size.max_item_width,
            };
            const height = switch (available.height) {
                .definite => |avail_h| @min(measured_size.total_height, avail_h),
                .min_content, .max_content => measured_size.total_height,
            };
            return .{ .width = width, .height = height };
        }
    };

    pub fn request_layout(self: *List, gid: ?*const GlobalElementId, window: *Window, cx: *App) struct { LayoutId, RequestLayoutState } {
        _ = gid;
        const state = self.state.inner;
        var style_: Style = .{};
        const layout_id = switch (self.sizing_behavior) {
            .infer => blk: {
                style_.overflow.y = .scroll;
                style_.refine(&self.base_style);
                const has_text = style_.text_style() != null;
                if (has_text) window.push_text_style(style_.text);
                defer if (has_text) window.pop_text_style();

                const available_height = if (state.last_layout_bounds) |b| b.size.height else state.overdraw;
                const bounds_size = if (state.last_layout_bounds) |b| b.size else Size(Pixels){};
                const padding = style_.padding.to_pixels(.{
                    Size(geometry.AbsoluteLength){ .width = .{ .pixels = bounds_size.width }, .height = .{ .pixels = bounds_size.height } },
                    window.rem_size(),
                });
                const response = state.layout_items(null, available_height, padding, self.render_item, window, cx);
                const measured = window_mod.frame_arena().create(MeasuredSize) catch oom();
                measured.* = .{ .max_item_width = response.max_item_width, .total_height = state.total_height() };
                break :blk window.request_measured_layout(&style_, .{ .ctx = measured, .func = MeasuredSize.measure });
            },
            .auto => blk: {
                style_.refine(&self.base_style);
                const has_text = style_.text_style() != null;
                if (has_text) window.push_text_style(style_.text);
                defer if (has_text) window.pop_text_style();
                break :blk window.request_layout(&style_, &.{}, cx);
            },
        };
        return .{ layout_id, .{} };
    }

    pub fn prepaint(self: *List, gid: ?*const GlobalElementId, bounds: Bounds(Pixels), rl: *RequestLayoutState, window: *Window, cx: *App) ListPrepaintState {
        _ = gid;
        _ = rl;
        const state = self.state.inner;
        state.reset = false;
        var style_: Style = .{};
        style_.refine(&self.base_style);
        const hitbox = window.insert_hitbox(bounds, .normal);

        // A new width invalidates every cached height, since text wraps differently.
        if (state.last_layout_bounds == null or state.last_layout_bounds.?.size.width != bounds.size.width) {
            for (state.items.items) |*item| item.* = .{ .focus_handle = item.focus_handle };
            state.rebuild_heights();
            state.measuring_behavior.reset();
        }

        const padding = style_.padding.to_pixels(.{
            Size(geometry.AbsoluteLength){ .width = .{ .pixels = bounds.size.width }, .height = .{ .pixels = bounds.size.height } },
            window.rem_size(),
        });
        const layout = state.prepaint_items(bounds, padding, self.render_item, window, cx);
        state.last_layout_bounds = bounds;
        state.last_padding = padding;
        return .{ .hitbox = hitbox, .layout = layout };
    }

    const ScrollCtx = struct {
        state: *StateInner,
        hitbox: Hitbox,
        height: Pixels,
        scroll_top: ListOffset,
        accumulated: ScrollDelta = ScrollDelta.default,
        current_view: ?EntityId,
    };

    fn onScrollWheel(raw: *anyopaque, e: *const ScrollWheelEvent, phase: DispatchPhase, window: *Window, cx: *App) void {
        const c: *ScrollCtx = @ptrCast(@alignCast(raw));
        if (phase != .bubble or !c.hitbox.should_handle_scroll(window)) return;
        c.accumulated = c.accumulated.coalesce(e.delta);
        const pixel_delta = c.accumulated.pixel_delta(geometry.px(20));
        c.state.scroll(c.scroll_top, c.height, pixel_delta, c.current_view, window, cx);
    }

    pub fn paint(self: *List, gid: ?*const GlobalElementId, bounds: Bounds(Pixels), rl: *RequestLayoutState, pp: *ListPrepaintState, window: *Window, cx: *App) void {
        _ = gid;
        _ = rl;
        // Registered before the children paint: bubble runs in reverse, so children can stop the scroll.
        const ctx = window_mod.frame_arena().create(ScrollCtx) catch oom();
        ctx.* = .{
            .state = self.state.inner,
            .hitbox = pp.hitbox,
            .height = bounds.size.height,
            .scroll_top = pp.layout.scroll_top,
            .current_view = window.current_view(),
        };
        window.on_mouse_event(ScrollWheelEvent, ctx, onScrollWheel);

        window.push_content_mask(.{ .bounds = bounds });
        for (pp.layout.item_layouts.items) |*item| item.element.paint(window, cx);
        window.pop_content_mask();
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
        pub const overflow_scroll = StyledM.overflow_scroll;
        pub const overflow_x_scroll = StyledM.overflow_x_scroll;
        pub const overflow_y_scroll = StyledM.overflow_y_scroll;
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

/// Lays out a list of variable-height items, rendering them with `render_item` (GPUI `list`).
pub fn list(state: ListState, render_item: ItemRenderer) *List {
    const element = window_mod.frame_arena().create(List) catch oom();
    element.* = .{ .state = state, .render_item = render_item };
    return element;
}

const TestAppContext = @import("../app/test_context.zig").TestAppContext;
const VisualTestContext = @import("../app/test_context.zig").VisualTestContext;
const Context = app_mod.Context;
const Entity = app_mod.Entity;
const div_mod = @import("div.zig");
const canvas_mod = @import("canvas.zig");
const Div = div_mod.Div;

/// Set by each test before it opens a window, read by `TestListView.build`.
var test_list_state: ?ListState = null;
var test_item_height: Pixels = 20;

const TestListView = struct {
    const Self = @This();
    state: ListState,
    item_height: Pixels,

    fn build(_: *Window, app: *App) Entity(Self) {
        return app.new(Self{ .state = test_list_state.?, .item_height = test_item_height });
    }

    pub fn render(self: *Self, _: *Window, cx: *Context(Self)) *Div {
        return div_mod.div().w_full().h_full().child(list(self.state, cx.item_processor(render_item)).w_full().h_full());
    }

    fn render_item(self: *Self, _: usize, _: *Window, _: *Context(Self)) AnyElement {
        return div_mod.div().h(geometry.px(self.item_height)).w_full().into_any_element();
    }

    fn set_item_height(self: *Self, height: Pixels, _: *Context(Self)) void {
        self.item_height = height;
    }
};

const OpenedList = struct {
    view: Entity(TestListView),
    vcx: *VisualTestContext,
};

/// Opens a window showing `state` with `item_height` items, drawn at `width` x `height`.
fn open_list(cx: *TestAppContext, state: ListState, item_height: Pixels, width: f32, height: f32) OpenedList {
    test_list_state = state;
    test_item_height = item_height;
    // Open at the final size so the first layout is the one the test observes.
    const handle = cx.add_window_with_options(.{
        .window_bounds = .{ .windowed = geometry.bounds(geometry.point(geometry.px(0), geometry.px(0)), geometry.size(geometry.px(width), geometry.px(height))) },
    }, TestListView.build);
    const visual = cx.allocator.create(VisualTestContext) catch @panic("OOM");
    visual.* = .{ .window = handle.window(cx.app) orelse unreachable, .cx = cx };
    cx.visual_contexts.append(cx.allocator, visual) catch @panic("OOM");
    return .{ .view = handle.root(cx.app) catch unreachable, .vcx = visual };
}

fn resize_list(vcx: *VisualTestContext, width: f32, height: f32) void {
    vcx.simulate_resize(geometry.size(geometry.px(width), geometry.px(height)));
    vcx.run_until_parked();
}

test "list: heights index answers prefix sums and offset searches" {
    const state = ListState.new(4, .top, 0);
    defer state.deinit();
    const heights = [_]Pixels{ 10, 20, 30, 40 };
    for (heights, 0..) |h, ix| state.inner.set_item(ix, .{ .measured = .{ .width = 0, .height = h } });

    try std.testing.expectEqual(@as(Pixels, 30), state.inner.prefix_px(2));
    try std.testing.expectEqual(@as(Pixels, 100), state.inner.total_height());
    // Right search: the item containing a position, where boundaries belong to the next item.
    try std.testing.expectEqual(@as(usize, 2), state.inner.heights.search(30, false));
    try std.testing.expectEqual(@as(usize, 4), state.inner.heights.search(100, false));
    // Left search: boundaries belong to the item above them.
    try std.testing.expectEqual(@as(usize, 1), state.inner.heights.search(29.9, true));
    try std.testing.expectEqual(@as(usize, 1), state.inner.heights.search(30, true));
}

test "list: splice keeps the scroll anchor on surviving items" {
    const state = ListState.new(5, .top, 0);
    defer state.deinit();
    state.scroll_to(.{ .item_ix = 3, .offset_in_item = 7 });
    state.splice(.{ .start = 0, .end = 1 }, 2);
    try std.testing.expectEqual(@as(usize, 6), state.item_count());
    try std.testing.expectEqual(@as(usize, 4), state.logical_scroll_top().item_ix);
    try std.testing.expectEqual(@as(Pixels, 7), state.logical_scroll_top().offset_in_item);
    // Splicing over the anchored item moves the anchor to the start of the replacement.
    state.splice(.{ .start = 4, .end = 6 }, 1);
    try std.testing.expectEqual(@as(usize, 4), state.logical_scroll_top().item_ix);
    try std.testing.expectEqual(@as(Pixels, 0), state.logical_scroll_top().offset_in_item);
}

test "list: reset drops scroll events until the next paint" {
    var cx = TestAppContext.init();
    defer cx.deinit();
    const state = ListState.new(5, .top, 10);
    state.scroll_to(.{ .item_ix = 0, .offset_in_item = 0 });
    const opened = open_list(&cx, state, 20, 100, 20);

    state.reset(5);
    opened.vcx.simulate_scroll(geometry.point(geometry.px(1), geometry.px(1)), geometry.point(geometry.px(0), geometry.px(-500)));
    try std.testing.expectEqual(@as(usize, 0), state.logical_scroll_top().item_ix);
    try std.testing.expectEqual(@as(Pixels, 0), state.logical_scroll_top().offset_in_item);
}

test "list: scroll_by moves by pixels in both directions" {
    var cx = TestAppContext.init();
    defer cx.deinit();
    const state = ListState.new(5, .top, 10);
    _ = open_list(&cx, state, 20, 100, 100);

    state.scroll_by(30);
    try std.testing.expectEqual(@as(usize, 1), state.logical_scroll_top().item_ix);
    try std.testing.expectEqual(@as(Pixels, 10), state.logical_scroll_top().offset_in_item);

    state.scroll_by(-30);
    try std.testing.expectEqual(@as(usize, 0), state.logical_scroll_top().item_ix);
    try std.testing.expectEqual(@as(Pixels, 0), state.logical_scroll_top().offset_in_item);

    state.scroll_by(0);
    try std.testing.expectEqual(@as(usize, 0), state.logical_scroll_top().item_ix);
    try std.testing.expectEqual(@as(Pixels, 0), state.logical_scroll_top().offset_in_item);
}

test "list: viewport queries are unknown before layout" {
    const state = ListState.new(5, .top, 10).measure_all();
    defer state.deinit();
    try std.testing.expectEqual(@as(?bool, null), state.item_is_above_viewport(0));
    try std.testing.expectEqual(@as(?bool, null), state.item_is_below_viewport(0));
}

test "list: viewport queries classify items above, inside and below the viewport" {
    var cx = TestAppContext.init();
    defer cx.deinit();
    const state = ListState.new(5, .top, 10).measure_all();
    state.scroll_to(.{ .item_ix = 2, .offset_in_item = 0 });
    _ = open_list(&cx, state, 20, 100, 20);

    try std.testing.expectEqual(@as(?bool, true), state.item_is_above_viewport(1));
    try std.testing.expectEqual(@as(?bool, false), state.item_is_below_viewport(1));
    try std.testing.expectEqual(@as(?bool, false), state.item_is_above_viewport(2));
    try std.testing.expectEqual(@as(?bool, false), state.item_is_below_viewport(2));
    try std.testing.expectEqual(@as(?bool, false), state.item_is_above_viewport(3));
    try std.testing.expectEqual(@as(?bool, true), state.item_is_below_viewport(3));
}

test "list: an item scrolled partly off the top is not yet above the viewport" {
    var cx = TestAppContext.init();
    defer cx.deinit();
    const state = ListState.new(5, .top, 10).measure_all();
    state.scroll_to(.{ .item_ix = 2, .offset_in_item = 20 });
    _ = open_list(&cx, state, 20, 100, 20);

    try std.testing.expectEqual(@as(?bool, true), state.item_is_above_viewport(2));
    try std.testing.expectEqual(@as(?bool, false), state.item_is_below_viewport(2));
}

test "list: a zero-height viewport keeps viewport queries stable" {
    var cx = TestAppContext.init();
    defer cx.deinit();
    const state = ListState.new(5, .top, 10).measure_all();
    state.scroll_to(.{ .item_ix = 2, .offset_in_item = 0 });
    const opened = open_list(&cx, state, 20, 100, 20);

    try std.testing.expectEqual(@as(?bool, false), state.item_is_above_viewport(3));
    try std.testing.expectEqual(@as(?bool, true), state.item_is_below_viewport(3));

    resize_list(opened.vcx, 100, 0);
    try std.testing.expectEqual(@as(?bool, true), state.item_is_above_viewport(1));
    try std.testing.expectEqual(@as(?bool, false), state.item_is_below_viewport(1));
    try std.testing.expectEqual(@as(?bool, false), state.item_is_above_viewport(3));
    try std.testing.expectEqual(@as(?bool, true), state.item_is_below_viewport(3));
}

test "list: scrolling to the end before layout reports the end item above the viewport" {
    var cx = TestAppContext.init();
    defer cx.deinit();
    const state = ListState.new(5, .top, 10).measure_all();
    _ = open_list(&cx, state, 20, 100, 20);

    state.scroll_to_end();
    try std.testing.expectEqual(state.item_count(), state.logical_scroll_top().item_ix);
    try std.testing.expectEqual(@as(?bool, true), state.item_is_above_viewport(0));
    try std.testing.expectEqual(@as(?bool, false), state.item_is_below_viewport(0));
}

test "list: measure_all keeps the scroll range after a width change" {
    var cx = TestAppContext.init();
    defer cx.deinit();
    const state = ListState.new(10, .top, 0).measure_all();
    const opened = open_list(&cx, state, 50, 100, 200);

    try std.testing.expectEqual(@as(Pixels, 300), state.max_offset_for_scrollbar().y);
    resize_list(opened.vcx, 200, 200);
    try std.testing.expectEqual(@as(Pixels, 300), state.max_offset_for_scrollbar().y);
}

test "list: remeasure keeps the proportional scroll position" {
    var cx = TestAppContext.init();
    defer cx.deinit();
    const state = ListState.new(10, .top, 10);
    state.scroll_to(.{ .item_ix = 2, .offset_in_item = 40 });
    const opened = open_list(&cx, state, 100, 100, 200);

    var offset = state.logical_scroll_top();
    try std.testing.expectEqual(@as(usize, 2), offset.item_ix);
    try std.testing.expectEqual(@as(Pixels, 40), offset.offset_in_item);

    cx.update_entity(opened.view, TestListView.set_item_height, .{@as(Pixels, 50)});
    state.remeasure();
    resize_list(opened.vcx, 100, 200);

    offset = state.logical_scroll_top();
    try std.testing.expectEqual(@as(usize, 2), offset.item_ix);
    try std.testing.expectEqual(@as(Pixels, 20), offset.offset_in_item);
}

test "list: a scrollbar drag moves the list and reports that it is dragging" {
    var cx = TestAppContext.init();
    defer cx.deinit();
    // 10 items of 50px in a 200px viewport: the scroll range is 300px.
    const state = ListState.new(10, .top, 0).measure_all();
    _ = open_list(&cx, state, 50, 100, 200);

    try std.testing.expect(!state.is_scrollbar_dragging());
    state.scrollbar_drag_started();
    try std.testing.expect(state.is_scrollbar_dragging());
    state.set_offset_from_scrollbar(.{ .x = 0, .y = -150 });
    state.scrollbar_drag_ended();
    try std.testing.expect(!state.is_scrollbar_dragging());

    const offset = state.logical_scroll_top();
    try std.testing.expectEqual(@as(usize, 3), offset.item_ix);
    try std.testing.expectEqual(@as(Pixels, 0), offset.offset_in_item);
}

test "list: a scrollbar drag is clamped to the content height it started with" {
    var cx = TestAppContext.init();
    defer cx.deinit();
    const state = ListState.new(10, .top, 0).measure_all();
    const opened = open_list(&cx, state, 50, 100, 200);

    state.scrollbar_drag_started();
    // Items grow to 100px during the drag, so the live range is 1000px. The thumb must still
    // map to the 300px range it started with: a drag far past the end clamps to 300px, which is
    // item 3 at 100px per item. Without the freeze it would reach 600px, item 6.
    cx.update_entity(opened.view, TestListView.set_item_height, .{@as(Pixels, 100)});
    state.remeasure();
    resize_list(opened.vcx, 100, 200);
    state.set_offset_from_scrollbar(.{ .x = 0, .y = -600 });
    state.scrollbar_drag_ended();

    const offset = state.logical_scroll_top();
    try std.testing.expectEqual(@as(usize, 3), offset.item_ix);
    try std.testing.expectEqual(@as(Pixels, 0), offset.offset_in_item);
}

test "list: dragging the scrollbar away from the tail stops following, and back to the end resumes" {
    var cx = TestAppContext.init();
    defer cx.deinit();
    const state = ListState.new(10, .top, 0).measure_all();
    _ = open_list(&cx, state, 50, 100, 200);

    state.set_follow_mode(.tail);
    try std.testing.expect(state.is_following_tail());

    state.scrollbar_drag_started();
    state.set_offset_from_scrollbar(.{ .x = 0, .y = -150 });
    state.scrollbar_drag_ended();
    try std.testing.expect(!state.is_following_tail());
    try std.testing.expectEqual(@as(usize, 3), state.logical_scroll_top().item_ix);

    state.scrollbar_drag_started();
    state.set_offset_from_scrollbar(.{ .x = 0, .y = -300 });
    state.scrollbar_drag_ended();
    try std.testing.expect(state.is_following_tail());
}

/// Which items the focus test rendered in the last frame, and the handle of the focused one.
var focus_test_rendered: [100]bool = @splat(false);
var focus_test_state: ?ListState = null;

var focus_test_handle: ?window_mod.FocusHandle = null;

const FocusTestView = struct {
    state: ListState,
    focus: window_mod.FocusHandle,

    fn build(_: *Window, app: *App) app_mod.Entity(FocusTestView) {
        return app.new(FocusTestView{ .state = focus_test_state.?, .focus = focus_test_handle.? });
    }

    pub fn render(self: *FocusTestView, _: *Window, cx: *Context(FocusTestView)) *div_mod.Div {
        return div_mod.div().w_full().h_full().child(list(self.state, cx.item_processor(render_item)).w_full().h_full());
    }

    fn render_item(self: *FocusTestView, ix: usize, _: *Window, _: *Context(FocusTestView)) AnyElement {
        focus_test_rendered[ix] = true;
        const item = div_mod.div().h(geometry.px(50)).w_full();
        if (ix == 80) _ = item.track_focus(&self.focus);
        return item.into_any_element();
    }
};

test "list: a focused item scrolled out of view is still rendered, after the visible items" {
    var cx = TestAppContext.init();
    defer cx.deinit();
    focus_test_rendered = @splat(false);
    // Item 80 takes the focus. It is rendered while it is in view, so the next frame knows it is focused.
    const state = ListState.new(0, .top, 0);
    focus_test_state = state;
    const handle = cx.app.focus_handle();
    focus_test_handle = handle;
    var handles: [100]?window_mod.FocusHandle = @splat(null);
    handles[80] = handle;
    state.splice_focusable(.{ .start = 0, .end = 0 }, &handles);
    const vcx = open_focus_test(&cx);
    state.scroll_to(.{ .item_ix = 80, .offset_in_item = 0 });
    vcx.window.refresh();
    vcx.run_until_parked();
    try std.testing.expect(focus_test_rendered[80]);
    // Focus only takes a handle the last frame drew, so this comes after the frame above.
    vcx.window.focus(handle);
    vcx.window.refresh();
    vcx.run_until_parked();
    try std.testing.expect(vcx.window.focus_id == handle.id);

    // Scrolled back to the top, item 80 is out of view, but it keeps being rendered.
    focus_test_rendered = @splat(false);
    state.scroll_to(.{ .item_ix = 0, .offset_in_item = 0 });
    vcx.window.refresh();
    vcx.run_until_parked();
    try std.testing.expect(focus_test_rendered[80]);
    try std.testing.expect(focus_test_rendered[0]);
    try std.testing.expect(!focus_test_rendered[50]);
}

test "list: splice_focusable gives the new items their handles, and measuring an item keeps its handle" {
    var cx = TestAppContext.init();
    defer cx.deinit();
    const state = ListState.new(3, .top, 0);
    const handle = cx.app.focus_handle();
    // Items 1 and 2 are replaced by null and the handle, so the handle lands at index 2.
    state.splice_focusable(.{ .start = 1, .end = 2 }, &.{ null, handle });
    try std.testing.expect(state.inner.items.items[0].focus_handle == null);
    try std.testing.expect(state.inner.items.items[1].focus_handle == null);
    try std.testing.expect(state.inner.items.items[2].focus_handle != null);
    try std.testing.expect(state.inner.items.items[3].focus_handle == null);

    state.inner.set_item(2, .{ .measured = .{ .width = 10, .height = 10 } });
    try std.testing.expect(state.inner.items.items[2].focus_handle != null);
}

/// Item 1 is 100 pixels tall and asks for autoscroll to its own bounds, which reach past the viewport.
var autoscroll_test_requested: bool = false;

const AutoscrollTestView = struct {
    state: ListState,

    fn build(_: *Window, app: *App) app_mod.Entity(AutoscrollTestView) {
        return app.new(AutoscrollTestView{ .state = focus_test_state.? });
    }

    pub fn render(self: *AutoscrollTestView, _: *Window, cx: *Context(AutoscrollTestView)) *div_mod.Div {
        return div_mod.div().w_full().h_full().child(list(self.state, cx.item_processor(render_item)).w_full().h_full());
    }

    fn render_item(_: *AutoscrollTestView, ix: usize, _: *Window, _: *Context(AutoscrollTestView)) AnyElement {
        if (ix != 1) return div_mod.div().h(geometry.px(50)).w_full().into_any_element();
        return div_mod.div().h(geometry.px(100)).w_full().child(canvas_mod.canvas({}, request_own_bounds, paint_nothing).size_full()).into_any_element();
    }

    fn request_own_bounds(_: void, bounds: Bounds(Pixels), window: *Window, _: *App) void {
        if (autoscroll_test_requested) window.request_autoscroll(bounds);
    }

    fn paint_nothing(_: void, _: Bounds(Pixels), _: *void, _: *Window, _: *App) void {}
};

test "list: an autoscroll request from an item scrolls the list so the requested area is visible" {
    var cx = TestAppContext.init();
    defer cx.deinit();
    const state = ListState.new(10, .top, 0);
    focus_test_state = state;
    autoscroll_test_requested = true;
    defer autoscroll_test_requested = false;
    const handle = cx.add_window_with_options(.{
        .window_bounds = .{ .windowed = geometry.bounds(geometry.point(geometry.px(0), geometry.px(0)), geometry.size(geometry.px(100), geometry.px(100))) },
    }, AutoscrollTestView.build);
    const vcx = cx.allocator.create(VisualTestContext) catch @panic("OOM");
    vcx.* = .{ .window = handle.window(cx.app) orelse unreachable, .cx = &cx };
    cx.visual_contexts.append(cx.allocator, vcx) catch @panic("OOM");
    vcx.run_until_parked();

    // Item 1 starts at 50 and runs to 150, past the bottom at 100. Scrolling to item 1 at offset 0 shows it.
    try std.testing.expectEqual(@as(usize, 1), state.logical_scroll_top().item_ix);
    try std.testing.expectEqual(@as(Pixels, 0), state.logical_scroll_top().offset_in_item);
}

fn open_focus_test(cx: *TestAppContext) *VisualTestContext {
    const handle = cx.add_window_with_options(.{
        .window_bounds = .{ .windowed = geometry.bounds(geometry.point(geometry.px(0), geometry.px(0)), geometry.size(geometry.px(100), geometry.px(100))) },
    }, FocusTestView.build);
    const visual = cx.allocator.create(VisualTestContext) catch @panic("OOM");
    visual.* = .{ .window = handle.window(cx.app) orelse unreachable, .cx = cx };
    cx.visual_contexts.append(cx.allocator, visual) catch @panic("OOM");
    return visual;
}
