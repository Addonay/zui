//! Virtualized list: fixed-height by default, with a bounded variable-height
//! mode supplied by HeightProvider.
//! Retain with cx.new(VirtualList, options). Builder returns one row's subtree;
//! it must fit its reported height and obey the frame's node/text budgets. No
//! invisible builder, text shaping, per-item state allocation or giant spacer.
//! Row keys derive from list key + index by default; provide item_key for data
//! identity across reorder. Focus stays on the list; this is not selection.
const std = @import("std");
const e = @import("../elements/root.zig");
const runtime = @import("../app/runtime.zig");
const Window = @import("../app/window.zig").Window;
const platform = @import("../platform/root.zig");
const ScrollArea = @import("scroll_area.zig").ScrollArea;

/// Borrowed variable row-height source. The callback must be stable for a
/// revision and width; hosts increment revision when data, fonts, or other
/// inputs change. The list samples and probes a bounded number of rows, so it
/// never constructs or measures every item just to find a scroll position.
pub const HeightProvider = struct {
    context: ?*anyopaque,
    height: *const fn (?*anyopaque, usize, f32) f64,
    revision: u64,
};

pub const VirtualList = struct {
    /// Placement used by `scrollToItem` when bringing a row into view.
    /// `nearest` is non-disruptive when the row is already fully visible.
    pub const ScrollStrategy = enum { top, center, bottom, nearest };
    pub const Options = struct {
        scroll: ScrollArea.Options,
        item_count: usize,
        item_height: f64,
        /// Optional variable-height source. `item_height` remains the initial
        /// estimate and the fixed-height behavior when this is null.
        height_provider: ?HeightProvider = null,
        overscan: usize = 2,
        context: ?*anyopaque = null,
        build_item: *const fn (?*anyopaque, usize, *Window) e.Element,
        item_key: ?*const fn (?*anyopaque, usize) u64 = null,
    };
    pub const Range = struct { start: usize = 0, end: usize = 0 };
    const MaxVariableProbes = 512;
    const SampleCount = 8;
    const VariableState = struct {
        initialized: bool = false,
        revision: u64 = 0,
        width: f32 = 0,
        item_count: usize = 0,
        provider_context: ?*anyopaque = null,
        provider_height: ?*const fn (?*anyopaque, usize, f32) f64 = null,
        average_height: f64 = 0,
        anchor_valid: bool = false,
        anchor_index: usize = 0,
        anchor_top: f64 = 0,
        pending_anchor: bool = false,
        pending_index: usize = 0,
        pending_intra: f64 = 0,
    };
    options: Options,
    scroll: ScrollArea,
    built_range: Range = .{},
    variable: VariableState = .{},
    built_start_top: f64 = 0,

    pub fn init(_: *runtime.Context(VirtualList), options: Options) VirtualList {
        std.debug.assert(std.math.isFinite(options.item_height) and options.item_height > 0);
        // f64 integer identity/offset precision is supported through 2^53.
        std.debug.assert(@as(f64, @floatFromInt(options.item_count)) < 9007199254740992);
        return .{ .options = options, .scroll = ScrollArea.fromOptions(options.scroll) };
    }
    pub fn handleEvent(self: *VirtualList, event: platform.Event, cx: *runtime.Context(VirtualList)) bool {
        return self.scroll.event(event, cx.window orelse return false);
    }
    fn fixedRange(self: *const VirtualList) Range {
        const count = self.options.item_count;
        if (count == 0 or self.scroll.model.viewport <= 0) return .{};
        const first: usize = @intFromFloat(@min(@as(f64, @floatFromInt(count)), @floor(self.scroll.model.offset / self.options.item_height)));
        const last: usize = @intFromFloat(@min(@as(f64, @floatFromInt(count)), @ceil((self.scroll.model.offset + self.scroll.model.viewport) / self.options.item_height)));
        return .{ .start = first -| self.options.overscan, .end = @min(count, last +| self.options.overscan) };
    }
    pub fn range(self: *const VirtualList) Range {
        // Variable layout is prepared by render. Keeping this accessor const
        // preserves the original API and makes it useful for frame inspection.
        return if (self.options.height_provider == null) self.fixedRange() else self.built_range;
    }
    pub fn itemKey(self: *const VirtualList, index: usize) u64 {
        if (self.options.item_key) |callback| return callback(self.options.context, index);
        return platform.id.fromSrc(self.options.scroll.key, @src(), index);
    }

    /// Scroll a row into view without constructing the collection. Fixed rows
    /// are exact; variable rows use the bounded height estimate and are
    /// corrected by the next render's provider probes.
    pub fn scrollToItem(self: *VirtualList, index: usize, strategy: ScrollStrategy) bool {
        if (self.options.item_count == 0 or index >= self.options.item_count) return false;

        const average = if (self.variable.average_height > 0) self.variable.average_height else self.options.item_height;
        var top = @as(f64, @floatFromInt(index)) * average;
        const height = if (self.options.height_provider) |provider| self.variableHeight(provider, index) else self.options.item_height;

        // Reuse the known anchor when the target is within the bounded probe
        // budget. This keeps keyboard navigation stable in variable lists.
        if (self.options.height_provider) |provider| if (self.variable.anchor_valid) {
            var cursor = self.variable.anchor_index;
            top = self.variable.anchor_top;
            if (cursor < index) {
                while (cursor < index and cursor - self.variable.anchor_index <= MaxVariableProbes) : (cursor += 1) top += self.variableHeight(provider, cursor);
            } else {
                while (cursor > index and self.variable.anchor_index - cursor <= MaxVariableProbes) {
                    cursor -= 1;
                    top -= self.variableHeight(provider, cursor);
                }
            }
            if (cursor != index) top = @as(f64, @floatFromInt(index)) * average;
        };

        const viewport = self.scroll.model.viewport;
        if (viewport <= 0) return false;
        const bottom = top + height;
        const target = switch (strategy) {
            .top => top,
            .center => top - (viewport - height) / 2,
            .bottom => bottom - viewport,
            .nearest => if (top < self.scroll.model.offset) top else if (bottom > self.scroll.model.offset + viewport) bottom - viewport else self.scroll.model.offset,
        };
        return self.scroll.model.jump(target);
    }
    fn variableHeight(self: *const VirtualList, provider: HeightProvider, index: usize) f64 {
        const height = provider.height(provider.context, index, self.options.scroll.width);
        return if (std.math.isFinite(height) and height > 0) height else self.options.item_height;
    }

    fn sampleVariableHeight(self: *VirtualList, provider: HeightProvider) void {
        const count = self.options.item_count;
        if (count == 0) {
            self.variable.average_height = self.options.item_height;
            return;
        }
        const samples = @min(count, SampleCount);
        var sum: f64 = 0;
        var i: usize = 0;
        while (i < samples) : (i += 1) {
            const index: usize = if (samples == 1) 0 else @intFromFloat(@floor(@as(f64, @floatFromInt(count - 1)) * @as(f64, @floatFromInt(i)) / @as(f64, @floatFromInt(samples - 1))));
            sum += self.variableHeight(provider, index);
        }
        self.variable.average_height = if (std.math.isFinite(sum) and sum > 0) sum / @as(f64, @floatFromInt(samples)) else self.options.item_height;
    }

    fn syncVariableProvider(self: *VirtualList) ?HeightProvider {
        const provider = self.options.height_provider orelse {
            self.variable = .{};
            return null;
        };
        const width = self.options.scroll.width;
        const changed = !self.variable.initialized or
            self.variable.revision != provider.revision or
            self.variable.width != width or
            self.variable.item_count != self.options.item_count or
            self.variable.provider_context != provider.context or
            self.variable.provider_height != provider.height;
        if (!changed) return provider;

        const pending_anchor = self.variable.initialized and self.variable.anchor_valid and self.options.item_count > 0;
        const pending_index = if (pending_anchor) @min(self.variable.anchor_index, self.options.item_count - 1) else 0;
        const pending_intra = if (pending_anchor) self.scroll.model.offset - self.variable.anchor_top else 0;
        self.variable = .{
            .initialized = true,
            .revision = provider.revision,
            .width = width,
            .item_count = self.options.item_count,
            .provider_context = provider.context,
            .provider_height = provider.height,
            .average_height = self.options.item_height,
            .pending_anchor = pending_anchor,
            .pending_index = pending_index,
            .pending_intra = pending_intra,
        };
        self.sampleVariableHeight(provider);
        return provider;
    }

    fn estimatedVariableExtent(self: *const VirtualList) f64 {
        const count = @as(f64, @floatFromInt(self.options.item_count));
        const extent = count * self.variable.average_height;
        return if (std.math.isFinite(extent) and extent > 0) extent else 0;
    }

    fn applyPendingAnchor(self: *VirtualList) void {
        if (!self.variable.pending_anchor or self.options.item_count == 0) return;
        const index = @min(self.variable.pending_index, self.options.item_count - 1);
        const top = @as(f64, @floatFromInt(index)) * self.variable.average_height;
        _ = self.scroll.model.jump(top + self.variable.pending_intra);
        self.variable.anchor_valid = true;
        self.variable.anchor_index = index;
        self.variable.anchor_top = top;
        self.variable.pending_anchor = false;
    }

    const VariablePosition = struct { index: usize, top: f64 };

    fn locateVariableFirst(self: *VirtualList, provider: HeightProvider) VariablePosition {
        const count = self.options.item_count;
        const offset = self.scroll.model.offset;
        const average = if (self.variable.average_height > 0) self.variable.average_height else self.options.item_height;
        const estimated_index: usize = @intFromFloat(@min(@as(f64, @floatFromInt(count - 1)), @floor(offset / average)));
        var index = estimated_index;
        var top = @as(f64, @floatFromInt(index)) * average;

        if (self.variable.anchor_valid) {
            const distance = if (self.variable.anchor_index > estimated_index)
                self.variable.anchor_index - estimated_index
            else
                estimated_index - self.variable.anchor_index;
            if (distance <= MaxVariableProbes) {
                index = self.variable.anchor_index;
                top = self.variable.anchor_top;
            }
        }

        var probes: usize = 0;
        while (index > 0 and top > offset and probes < MaxVariableProbes) : (probes += 1) {
            index -= 1;
            top -= self.variableHeight(provider, index);
        }
        while (index < count and probes < MaxVariableProbes) {
            const height = self.variableHeight(provider, index);
            if (top + height > offset) break;
            top += height;
            index += 1;
            probes += 1;
        }

        // If a very large jump exceeds the bounded correction budget, align
        // the estimated row to the requested offset. This keeps the frame
        // bounded and avoids an enormous transient negative coordinate.
        if (probes == MaxVariableProbes and (top > offset or index < count)) top = offset;
        return .{ .index = @min(index, count - 1), .top = top };
    }

    fn variableRange(self: *VirtualList, provider: HeightProvider) Range {
        const count = self.options.item_count;
        if (count == 0 or self.scroll.model.viewport <= 0) {
            self.built_start_top = 0;
            self.variable.anchor_valid = false;
            return .{};
        }

        const first_position = self.locateVariableFirst(provider);
        self.variable.anchor_valid = true;
        self.variable.anchor_index = first_position.index;
        self.variable.anchor_top = first_position.top;

        var start = first_position.index;
        var start_top = first_position.top;
        var leading: usize = 0;
        while (start > 0 and leading < self.options.overscan) : (leading += 1) {
            start -= 1;
            start_top -= self.variableHeight(provider, start);
        }

        const viewport_end = self.scroll.model.offset + self.scroll.model.viewport;
        var index = start;
        var top = start_top;
        var trailing: usize = 0;
        while (index < count) {
            const height = self.variableHeight(provider, index);
            if (index >= first_position.index and top >= viewport_end) {
                if (trailing >= self.options.overscan) break;
                trailing += 1;
            }
            top += height;
            index += 1;
        }
        self.built_start_top = start_top;
        return .{ .start = start, .end = index };
    }

    /// Host resize/data change contract: update options, then requestRender.
    /// Offset is reclamped before calculating the next visible range. Variable
    /// mode deliberately uses a bounded estimate/probe path; exact total
    /// height is not available from the HeightProvider seam without walking
    /// every item.
    pub fn render(self: *VirtualList, win: *Window, cx: *runtime.Context(VirtualList)) e.Element {
        self.scroll.options = self.options.scroll;
        const provider = self.syncVariableProvider();
        if (provider) |height_provider| {
            self.scroll.model.resize(self.options.scroll.height, self.estimatedVariableExtent());
            self.applyPendingAnchor();
            self.scroll.model.resize(self.options.scroll.height, self.estimatedVariableExtent());
            self.built_range = self.variableRange(height_provider);
        } else {
            self.scroll.model.resize(self.options.scroll.height, @as(f64, @floatFromInt(self.options.item_count)) * self.options.item_height);
            self.built_range = self.fixedRange();
            self.built_start_top = @as(f64, @floatFromInt(self.built_range.start)) * self.options.item_height;
        }
        var viewport = e.div().w_full().h(self.options.scroll.height);
        var variable_top = self.built_start_top;
        for (self.built_range.start..self.built_range.end) |index| {
            // Subtract in f64 BEFORE downcasting; fractional row placement is
            // retained even at tens of millions of logical pixels.
            const row_height = if (provider) |height_provider| self.variableHeight(height_provider, index) else self.options.item_height;
            const row_top = if (provider != null) variable_top else @as(f64, @floatFromInt(index)) * self.options.item_height;
            const y: f32 = @floatCast(row_top - self.scroll.model.offset);
            const row = e.div().keyed(self.itemKey(index)).absolute().top(y).w(self.options.scroll.width).h(@floatCast(row_height))
                .semantic(.{ .role = .listitem, .position_in_set = index + 1, .set_size = self.options.item_count })
                .child(self.options.build_item(self.options.context, index, win));
            viewport = viewport.child(row);
            if (provider != null) variable_top += row_height;
        }
        return self.scroll.renderViewport(win, cx.focusHandle(), viewport, .list);
    }
};

test "variable virtual list probes a bounded window and invalidates on revision" {
    const t = std.testing;
    var heights = VariableListTestHeights{};
    const provider = HeightProvider{ .context = &heights, .height = variableListTestHeight, .revision = 1 };
    var list = VirtualList{
        .options = .{
            .scroll = .{ .key = 900, .width = 300, .height = 100 },
            .item_count = 1_000_000,
            .item_height = 20,
            .height_provider = provider,
            .build_item = variableListTestRow,
        },
        .scroll = ScrollArea.fromOptions(.{ .key = 900, .width = 300, .height = 100 }),
    };
    _ = list.scroll.model.jump(10_000_000);
    const first = list.syncVariableProvider().?;
    list.scroll.model.resize(100, list.estimatedVariableExtent());
    list.built_range = list.variableRange(first);
    try t.expect(list.built_range.end > list.built_range.start);
    try t.expect(heights.calls <= VirtualList.SampleCount + VirtualList.MaxVariableProbes + 16);

    const old_anchor = list.variable.anchor_index;
    const old_offset = list.scroll.model.offset;
    heights.multiplier = 2;
    list.options.height_provider.?.revision = 2;
    const second = list.syncVariableProvider().?;
    list.scroll.model.resize(100, list.estimatedVariableExtent());
    list.applyPendingAnchor();
    list.scroll.model.resize(100, list.estimatedVariableExtent());
    list.built_range = list.variableRange(second);
    try t.expectEqual(@as(u64, 2), list.variable.revision);
    try t.expectEqual(old_anchor, list.variable.anchor_index);
    try t.expect(list.scroll.model.offset >= old_offset);
    try t.expect(list.built_range.end > list.built_range.start);
}

test "variable virtual list clamps an oversized jump without walking the collection" {
    const t = std.testing;
    var heights = VariableListTestHeights{};
    var list = VirtualList{
        .options = .{
            .scroll = .{ .key = 901, .width = 300, .height = 80 },
            .item_count = 1_000_000,
            .item_height = 20,
            .height_provider = .{ .context = &heights, .height = variableListTestHeight, .revision = 1 },
            .build_item = variableListTestRow,
        },
        .scroll = ScrollArea.fromOptions(.{ .key = 901, .width = 300, .height = 80 }),
    };
    _ = list.syncVariableProvider();
    list.scroll.model.resize(80, list.estimatedVariableExtent());
    _ = list.scroll.model.jump(std.math.floatMax(f64));
    const before = heights.calls;
    list.built_range = list.variableRange(list.options.height_provider.?);
    try t.expect(list.built_range.end > list.built_range.start);
    try t.expect(list.scroll.model.offset <= list.scroll.model.maxOffset());
    try t.expect(heights.calls - before <= VirtualList.MaxVariableProbes + 16);
}

test "virtual list scrollToItem supports placement strategies without building rows" {
    const t = std.testing;
    var list = VirtualList{
        .options = .{
            .scroll = .{ .key = 902, .width = 300, .height = 100 },
            .item_count = 100,
            .item_height = 20,
            .build_item = variableListTestRow,
        },
        .scroll = ScrollArea.fromOptions(.{ .key = 902, .width = 300, .height = 100 }),
    };
    list.scroll.model.resize(100, 2_000);
    try t.expect(list.scrollToItem(10, .top));
    try t.expectEqual(@as(f64, 200), list.scroll.model.offset);
    try t.expect(list.scrollToItem(20, .center));
    try t.expectEqual(@as(f64, 360), list.scroll.model.offset);
    try t.expect(list.scrollToItem(30, .bottom));
    try t.expectEqual(@as(f64, 520), list.scroll.model.offset);
    try t.expect(list.scrollToItem(31, .nearest));
    try t.expectEqual(@as(f64, 540), list.scroll.model.offset);
    try t.expect(!list.scrollToItem(100, .top));
}

const VariableListTestHeights = struct {
    calls: usize = 0,
    multiplier: f64 = 1,
};

fn variableListTestHeight(raw: ?*anyopaque, index: usize, _: f32) f64 {
    const heights: *VariableListTestHeights = @ptrCast(@alignCast(raw.?));
    heights.calls += 1;
    return @as(f64, @floatFromInt(10 + (index % 3) * 10)) * heights.multiplier;
}

fn variableListTestRow(_: ?*anyopaque, _: usize, _: *Window) e.Element {
    return e.div();
}
