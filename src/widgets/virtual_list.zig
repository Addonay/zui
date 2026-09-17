//! Fixed-height list: O(visible + overscan) construction, independent of count.
//! Retain with cx.new(VirtualList, options). Builder returns one row's subtree;
//! it must fit item_height and obey the frame's node/text budgets. No invisible
//! builder, text shaping, per-item state allocation or million-pixel spacer.
//! Row keys derive from list key + index by default; provide item_key for data
//! identity across reorder. Focus stays on the list; this is not selection.
const std = @import("std");
const e = @import("../elements/root.zig");
const runtime = @import("../app/runtime.zig");
const Window = @import("../app/window.zig").Window;
const platform = @import("../platform/root.zig");
const ScrollArea = @import("scroll_area.zig").ScrollArea;

/// Deferred variable-height seam. A future implementation may accept this
/// borrowed provider, cache prefix sums, invalidate by revision/width, and
/// preserve a stable item + intra-item anchor. It is NOT accepted by this
/// fixed-height list: no O(n) measurements masquerading as virtualization.
pub const HeightProvider = struct {
    context: ?*anyopaque,
    height: *const fn (?*anyopaque, usize, f32) f64,
    revision: u64,
};

pub const VirtualList = struct {
    pub const Options = struct {
        scroll: ScrollArea.Options,
        item_count: usize,
        item_height: f64,
        overscan: usize = 2,
        context: ?*anyopaque = null,
        build_item: *const fn (?*anyopaque, usize, *Window) e.Element,
        item_key: ?*const fn (?*anyopaque, usize) u64 = null,
    };
    pub const Range = struct { start: usize = 0, end: usize = 0 };
    options: Options,
    scroll: ScrollArea,
    built_range: Range = .{},

    pub fn init(_: *runtime.Context(VirtualList), options: Options) VirtualList {
        std.debug.assert(std.math.isFinite(options.item_height) and options.item_height > 0);
        // f64 integer identity/offset precision is supported through 2^53.
        std.debug.assert(@as(f64, @floatFromInt(options.item_count)) < 9007199254740992);
        return .{ .options = options, .scroll = ScrollArea.fromOptions(options.scroll) };
    }
    pub fn handleEvent(self: *VirtualList, event: platform.Event, cx: *runtime.Context(VirtualList)) bool {
        return self.scroll.event(event, cx.window orelse return false);
    }
    pub fn range(self: *const VirtualList) Range {
        const count = self.options.item_count;
        if (count == 0 or self.scroll.model.viewport <= 0) return .{};
        const first: usize = @intFromFloat(@min(@as(f64, @floatFromInt(count)), @floor(self.scroll.model.offset / self.options.item_height)));
        const last: usize = @intFromFloat(@min(@as(f64, @floatFromInt(count)), @ceil((self.scroll.model.offset + self.scroll.model.viewport) / self.options.item_height)));
        return .{ .start = first -| self.options.overscan, .end = @min(count, last +| self.options.overscan) };
    }
    pub fn itemKey(self: *const VirtualList, index: usize) u64 {
        if (self.options.item_key) |callback| return callback(self.options.context, index);
        return platform.id.fromSrc(self.options.scroll.key, @src(), index);
    }
    /// Host resize/data change contract: update options, then requestRender.
    /// Offset is reclamped before calculating the next visible range.
    pub fn render(self: *VirtualList, win: *Window, cx: *runtime.Context(VirtualList)) e.Element {
        self.scroll.options = self.options.scroll;
        self.scroll.model.resize(self.options.scroll.height, @as(f64, @floatFromInt(self.options.item_count)) * self.options.item_height);
        self.built_range = self.range();
        var viewport = e.div().w_full().h(self.options.scroll.height);
        for (self.built_range.start..self.built_range.end) |index| {
            // Subtract in f64 BEFORE downcasting; fractional row placement is
            // retained even at tens of millions of logical pixels.
            const y: f32 = @floatCast(@as(f64, @floatFromInt(index)) * self.options.item_height - self.scroll.model.offset);
            const row = e.div().keyed(self.itemKey(index)).absolute().top(y).w(self.options.scroll.width).h(@floatCast(self.options.item_height))
                .semantic(.{ .role = .listitem, .position_in_set = index + 1, .set_size = self.options.item_count })
                .child(self.options.build_item(self.options.context, index, win));
            viewport = viewport.child(row);
        }
        return self.scroll.renderViewport(win, cx.focusHandle(), viewport, .list);
    }
};
