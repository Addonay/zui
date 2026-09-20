//! Application-grade virtual table: O(visible + overscan) construction for
//! millions of rows. The framework never owns row data: the host supplies a
//! cell builder, a row-key provider (data identity across reorders), and a
//! sort callback that REPORTS requests back — the host reorders its own
//! data. Selection is a bounded range table (64 ranges), so ctrl/shift
//! multi-select works without per-row allocation.
//!
//! Deferred seams (documented, not implemented): richer reorder animations.
//! Bounded pointer/programmatic column reorder is available. Variable row heights are opt-in through
//! `virtual_list.HeightProvider`.
const std = @import("std");
const e = @import("../elements/root.zig");
const runtime = @import("../app/runtime.zig");
const Window = @import("../app/window.zig").Window;
const platform = @import("../platform/root.zig");
const theme = @import("theme.zig");
const a11y = @import("../a11y/root.zig");
const ScrollModel = @import("scroll_model.zig").ScrollModel;
const HeightProvider = @import("virtual_list.zig").HeightProvider;

pub const Column = struct {
    name: []const u8,
    width: f32,
};

/// Sort request reported to the host. The host reorders its own data and
/// refreshes options (row keys follow data identity via `row_key`).
pub const SortRequest = struct { column: usize, ascending: bool };

/// Per-listener identity (≤16 bytes, payload-listener contract).
pub const RowRef = extern struct { row: usize };

pub const VirtualTable = struct {
    pub const ScrollStrategy = @import("virtual_list.zig").VirtualList.ScrollStrategy;
    /// Retained column state is deliberately bounded so a borrowed options
    /// slice can never turn a table drag into an unbounded allocation.
    pub const max_columns: usize = 64;
    pub const min_column_width: f32 = 40;
    pub const max_column_width: f32 = 640;

    pub const Options = struct {
        key: u64,
        width: f32 = 300,
        height: f32 = 300,
        label: []const u8 = "Table",
        tokens: ?theme.Theme = null,
        columns: []const Column,
        row_count: usize,
        row_height: f64,
        /// Optional variable-height source. `row_height` remains the initial
        /// estimate and the complete fixed-height behavior when this is null.
        height_provider: ?HeightProvider = null,
        header_height: f32 = 24,
        overscan: usize = 2,
        context: ?*anyopaque = null,
        build_cell: *const fn (?*anyopaque, row: usize, col: usize, *Window) e.Element,
        /// Stable data identity across reorders; index-derived by default.
        row_key: ?*const fn (?*anyopaque, usize) u64 = null,
        sort_changed: ?*const fn (?*anyopaque, SortRequest, *Window) void = null,
        column_resized: ?*const fn (?*anyopaque, column: usize, width: f32, *Window) void = null,
        column_reordered: ?*const fn (?*anyopaque, from: usize, to: usize, *Window) void = null,
        activate: ?*const fn (?*anyopaque, usize, *Window) void = null,
    };
    /// Bounded selection range table over CURRENT row indices (like every
    /// conventional list box). Toggling inside a range splits it; splitting
    /// beyond the table drops the request (documented cap).
    pub const Selection = struct {
        pub const max_ranges = 64;
        anchor: usize = 0,
        active: usize = 0,
        ranges: [max_ranges]struct { start: usize, end: usize } = undefined,
        count: usize = 0,

        pub fn clear(self: *Selection) void {
            self.count = 0;
        }
        pub fn single(self: *Selection, row: usize) void {
            self.count = 1;
            self.ranges[0] = .{ .start = row, .end = row };
            self.anchor = row;
            self.active = row;
        }
        pub fn extendTo(self: *Selection, row: usize) void {
            self.active = row;
            self.count = 1;
            self.ranges[0] = .{ .start = @min(self.anchor, row), .end = @max(self.anchor, row) };
        }
        pub fn toggle(self: *Selection, row: usize) void {
            self.active = row;
            self.anchor = row;
            for (self.ranges[0..self.count]) |*r| {
                if (row >= r.start and row <= r.end) {
                    if (r.start == r.end) {
                        self.ranges[self.count - 1] = self.ranges[self.count - 1];
                        // Remove the single-row range by swap-with-last.
                        self.count -= 1;
                        if (self.count > 0) {
                            const i = for (self.ranges[0 .. self.count + 1], 0..) |rr, ri| {
                                if (rr.start == r.start and rr.end == r.end) break ri;
                            } else return;
                            self.ranges[i] = self.ranges[self.count];
                        }
                    } else if (row == r.start) {
                        r.start += 1;
                    } else if (row == r.end) {
                        r.end -= 1;
                    } else if (self.count < max_ranges) {
                        self.ranges[self.count] = .{ .start = row + 1, .end = r.end };
                        r.end = row - 1;
                        self.count += 1;
                    }
                    return;
                }
            }
            if (self.count < max_ranges) {
                self.ranges[self.count] = .{ .start = row, .end = row };
                self.count += 1;
            }
        }
        pub fn selectAll(self: *Selection, row_count: usize) void {
            if (row_count == 0) return;
            self.count = 1;
            self.ranges[0] = .{ .start = 0, .end = row_count - 1 };
        }
        pub fn isSelected(self: *const Selection, row: usize) bool {
            for (self.ranges[0..self.count]) |r| {
                if (row >= r.start and row <= r.end) return true;
            }
            return false;
        }
    };

    pub const Range = struct { start: usize = 0, end: usize = 0 };
    const MaxVariableProbes = 512;
    const SampleCount = 8;
    const VariableState = struct {
        initialized: bool = false,
        revision: u64 = 0,
        width: f32 = 0,
        row_count: usize = 0,
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
    const ColumnResize = struct {
        column: usize,
        start_x: f32,
        start_width: f32,
    };
    const ColumnReorder = struct {
        position: usize,
        start_x: f32,
        active: bool = false,
    };

    options: Options,
    model: ScrollModel = .{},
    selection: Selection = .{},
    sort: ?SortRequest = null,
    pressed_row: ?usize = null,
    built_range: Range = .{},
    variable: VariableState = .{},
    built_start_top: f64 = 0,
    column_widths: [max_columns]f32 = undefined,
    columns_initialized: bool = false,
    columns_ptr: ?[*]const Column = null,
    columns_len: usize = 0,
    resizing: ?ColumnResize = null,
    reordering: ?ColumnReorder = null,
    column_order: [max_columns]usize = undefined,
    column_order_initialized: bool = false,
    column_order_ptr: ?[*]const Column = null,

    pub fn init(_: *runtime.Context(VirtualTable), options: Options) VirtualTable {
        std.debug.assert(options.key != 0);
        std.debug.assert(std.math.isFinite(options.row_height) and options.row_height > 0);
        std.debug.assert(@as(f64, @floatFromInt(options.row_count)) < 9007199254740992);
        var table = VirtualTable{ .options = options };
        table.syncColumnWidths();
        table.syncColumnOrder();
        return table;
    }

    /// Host resize/data contract: update options, then requestRender. The
    /// offset is reclamped against the new extent on the next render.
    pub fn updateOptions(self: *VirtualTable, options: Options) void {
        self.options = options;
    }

    fn clampColumnWidth(width: f32) f32 {
        if (!std.math.isFinite(width)) return min_column_width;
        return @min(max_column_width, @max(min_column_width, width));
    }

    fn syncColumnWidths(self: *VirtualTable) void {
        const ptr: ?[*]const Column = if (self.options.columns.len == 0) null else self.options.columns.ptr;
        if (self.columns_initialized and self.columns_ptr == ptr and self.columns_len == self.options.columns.len) return;

        self.columns_initialized = true;
        self.columns_ptr = ptr;
        self.columns_len = self.options.columns.len;
        self.resizing = null;
        self.reordering = null;
        const count = @min(self.options.columns.len, max_columns);
        for (self.options.columns[0..count], 0..) |column, index| {
            self.column_widths[index] = clampColumnWidth(column.width);
        }
    }

    /// Return the retained width for a column. Columns beyond the bounded
    /// retained state remain borrowed/read-only and use their option width.
    pub fn columnWidth(self: *VirtualTable, column: usize) f32 {
        self.syncColumnWidths();
        if (column >= self.options.columns.len) return 0;
        return if (column < max_columns) self.column_widths[column] else clampColumnWidth(self.options.columns[column].width);
    }

    fn syncColumnOrder(self: *VirtualTable) void {
        const ptr: ?[*]const Column = if (self.options.columns.len == 0) null else self.options.columns.ptr;
        if (self.column_order_initialized and self.column_order_ptr == ptr and self.columns_len == self.options.columns.len) return;
        self.column_order_initialized = true;
        self.column_order_ptr = ptr;
        self.columns_len = self.options.columns.len;
        const count = @min(self.options.columns.len, max_columns);
        for (0..count) |index| self.column_order[index] = index;
    }

    pub fn orderedColumn(self: *VirtualTable, position: usize) usize {
        self.syncColumnOrder();
        if (position >= self.options.columns.len) return position;
        return if (position < max_columns) self.column_order[position] else position;
    }

    /// Reorder by logical column positions while retaining the host's stable
    /// source indices. Drag gestures remain a separate interaction layer.
    pub fn reorderColumn(self: *VirtualTable, from: usize, to: usize, win: *Window) bool {
        self.syncColumnOrder();
        const count = @min(self.options.columns.len, max_columns);
        if (from >= count or count == 0) return false;
        const target = @min(to, count - 1);
        if (from == target) return false;
        const moved = self.column_order[from];
        if (from < target) {
            for (from..target) |i| self.column_order[i] = self.column_order[i + 1];
        } else {
            var i = from;
            while (i > target) : (i -= 1) self.column_order[i] = self.column_order[i - 1];
        }
        self.column_order[target] = moved;
        if (self.options.column_reordered) |callback| callback(self.options.context, from, target, win);
        win.requestRender();
        return true;
    }

    fn rowsViewportHeight(self: *const VirtualTable) f32 {
        return @max(0, self.options.height - self.options.header_height);
    }

    fn fixedRange(self: *const VirtualTable) Range {
        const count = self.options.row_count;
        const viewport = self.rowsViewportHeight();
        if (count == 0 or viewport <= 0) return .{};
        const first: usize = @intFromFloat(@min(@as(f64, @floatFromInt(count)), @floor(self.model.offset / self.options.row_height)));
        const last: usize = @intFromFloat(@min(@as(f64, @floatFromInt(count)), @ceil((self.model.offset + viewport) / self.options.row_height)));
        return .{ .start = first -| self.options.overscan, .end = @min(count, last +| self.options.overscan) };
    }

    /// The range built by the most recent render. In fixed mode this remains
    /// derived directly from the scroll model, preserving the old inspection
    /// behavior; variable mode is prepared by render's bounded probe pass.
    pub fn range(self: *const VirtualTable) Range {
        return if (self.options.height_provider == null) self.fixedRange() else self.built_range;
    }

    fn variableHeight(self: *const VirtualTable, provider: HeightProvider, index: usize) f64 {
        const height = provider.height(provider.context, index, self.options.width);
        return if (std.math.isFinite(height) and height > 0) height else self.options.row_height;
    }

    fn sampleVariableHeight(self: *VirtualTable, provider: HeightProvider) void {
        const count = self.options.row_count;
        if (count == 0) {
            self.variable.average_height = self.options.row_height;
            return;
        }
        const samples = @min(count, SampleCount);
        var sum: f64 = 0;
        var i: usize = 0;
        while (i < samples) : (i += 1) {
            const index: usize = if (samples == 1) 0 else @intFromFloat(@floor(@as(f64, @floatFromInt(count - 1)) * @as(f64, @floatFromInt(i)) / @as(f64, @floatFromInt(samples - 1))));
            sum += self.variableHeight(provider, index);
        }
        self.variable.average_height = if (std.math.isFinite(sum) and sum > 0) sum / @as(f64, @floatFromInt(samples)) else self.options.row_height;
    }

    fn syncVariableProvider(self: *VirtualTable) ?HeightProvider {
        const provider = self.options.height_provider orelse {
            self.variable = .{};
            return null;
        };
        const changed = !self.variable.initialized or
            self.variable.revision != provider.revision or
            self.variable.width != self.options.width or
            self.variable.row_count != self.options.row_count or
            self.variable.provider_context != provider.context or
            self.variable.provider_height != provider.height;
        if (!changed) return provider;

        const pending_anchor = self.variable.initialized and self.variable.anchor_valid and self.options.row_count > 0;
        const pending_index = if (pending_anchor) @min(self.variable.anchor_index, self.options.row_count - 1) else 0;
        const pending_intra = if (pending_anchor) self.model.offset - self.variable.anchor_top else 0;
        self.variable = .{
            .initialized = true,
            .revision = provider.revision,
            .width = self.options.width,
            .row_count = self.options.row_count,
            .provider_context = provider.context,
            .provider_height = provider.height,
            .average_height = self.options.row_height,
            .pending_anchor = pending_anchor,
            .pending_index = pending_index,
            .pending_intra = pending_intra,
        };
        self.sampleVariableHeight(provider);
        return provider;
    }

    fn estimatedVariableExtent(self: *const VirtualTable) f64 {
        const count = @as(f64, @floatFromInt(self.options.row_count));
        const extent = count * self.variable.average_height;
        return if (std.math.isFinite(extent) and extent > 0) extent else 0;
    }

    fn applyPendingAnchor(self: *VirtualTable) void {
        if (!self.variable.pending_anchor or self.options.row_count == 0) return;
        const index = @min(self.variable.pending_index, self.options.row_count - 1);
        const top = @as(f64, @floatFromInt(index)) * self.variable.average_height;
        _ = self.model.jump(top + self.variable.pending_intra);
        self.variable.anchor_valid = true;
        self.variable.anchor_index = index;
        self.variable.anchor_top = top;
        self.variable.pending_anchor = false;
    }

    const VariablePosition = struct { index: usize, top: f64 };

    fn locateVariableFirst(self: *VirtualTable, provider: HeightProvider) VariablePosition {
        const count = self.options.row_count;
        const offset = self.model.offset;
        const average = if (self.variable.average_height > 0) self.variable.average_height else self.options.row_height;
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
        if (probes == MaxVariableProbes and (top > offset or index < count)) top = offset;
        return .{ .index = @min(index, count - 1), .top = top };
    }

    fn variableRange(self: *VirtualTable, provider: HeightProvider) Range {
        const count = self.options.row_count;
        const viewport = self.rowsViewportHeight();
        if (count == 0 or viewport <= 0) {
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

        const viewport_end = self.model.offset + @as(f64, viewport);
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

    pub fn handleEvent(self: *VirtualTable, event: platform.Event, cx: *runtime.Context(VirtualTable)) bool {
        const win = cx.window orelse return false;
        if (event == .window) {
            if (event.window == .unfocused or event.window == .close_requested or event.window == .cancelled) {
                self.pressed_row = null;
                self.resizing = null;
                self.reordering = null;
            }
            return false;
        }
        if (event != .key or !event.key.pressed) return false;
        const key_event = event.key;
        if (key_event.modifiers.ctrl and key_event.key == .a) {
            self.selection.selectAll(self.options.row_count);
            win.requestRender();
            return true;
        }
        if (key_event.modifiers.ctrl or key_event.modifiers.alt or key_event.modifiers.super) return false;
        switch (key_event.key) {
            .up, .down, .home, .end => {
                const old = self.selection.active;
                const active: usize = switch (key_event.key) {
                    .up => old -| 1,
                    .down => @min(self.options.row_count -| 1, old + 1),
                    .home => 0,
                    .end => self.options.row_count -| 1,
                    else => unreachable,
                };
                if (key_event.modifiers.shift) self.selection.extendTo(active) else self.selection.single(active);
                self.ensureVisible(active);
                win.requestRender();
                return true;
            },
            .space => {
                self.model.page(if (key_event.modifiers.shift) .up else .down);
                win.requestRender();
                return true;
            },
            .enter => {
                if (self.options.activate) |activate| activate(self.options.context, self.selection.active, win);
                return true;
            },
            else => return false,
        }
    }

    /// Scroll a row into view without constructing offscreen rows. Variable
    /// heights use the same bounded anchor/probe path as virtualization.
    pub fn scrollToRow(self: *VirtualTable, row: usize, strategy: ScrollStrategy) bool {
        if (self.options.row_count == 0 or row >= self.options.row_count) return false;
        const index = row;
        var top: f64 = @as(f64, @floatFromInt(index)) * self.options.row_height;
        var height = self.options.row_height;
        if (self.options.height_provider) |provider| {
            _ = self.syncVariableProvider();
            const average = if (self.variable.average_height > 0) self.variable.average_height else self.options.row_height;
            var cursor = @min(index, self.options.row_count - 1);
            top = @as(f64, @floatFromInt(cursor)) * average;
            if (self.variable.anchor_valid) {
                const distance = if (self.variable.anchor_index > cursor)
                    self.variable.anchor_index - cursor
                else
                    cursor - self.variable.anchor_index;
                if (distance <= MaxVariableProbes) {
                    cursor = self.variable.anchor_index;
                    top = self.variable.anchor_top;
                    if (cursor < index) {
                        while (cursor < index) : (cursor += 1) top += self.variableHeight(provider, cursor);
                    } else {
                        while (cursor > index) {
                            cursor -= 1;
                            top -= self.variableHeight(provider, cursor);
                        }
                    }
                }
            }
            height = self.variableHeight(provider, index);
        }
        const bottom = top + height;
        const view = @as(f64, self.rowsViewportHeight());
        const target = switch (strategy) {
            .top => top,
            .center => top - (view - height) / 2,
            .bottom => bottom - view,
            .nearest => if (top < self.model.offset) top else if (bottom > self.model.offset + view) bottom - view else self.model.offset,
        };
        return self.model.jump(target);
    }

    /// Virtualization follows the active row.
    pub fn ensureVisible(self: *VirtualTable, row: usize) void {
        _ = self.scrollToRow(row, .nearest);
    }

    pub fn rowKey(self: *const VirtualTable, index: usize) u64 {
        if (self.options.row_key) |callback| return callback(self.options.context, index);
        return platform.id.fromSrc(self.options.key, @src(), index);
    }

    fn headerKey(self: *const VirtualTable, col: usize) u64 {
        return platform.id.fromSrc(self.options.key, @src(), 0x7ab1e + col);
    }

    // -- listeners -------------------------------------------------------
    fn wheel(raw: *anyopaque, _: *const e.element.ListenerPayload, raw_win: *anyopaque) void {
        const self: *VirtualTable = @ptrCast(@alignCast(raw));
        const win: *Window = @ptrCast(@alignCast(raw_win));
        const scroll = win.scrollEvent();
        // ScrollModel consumes logical pixels. The input protocol carries
        // line-like deltas, so row_height remains the table's legacy line
        // conversion while the remainder is calculated and chained in pixels.
        const logical_delta = -@as(f64, scroll.dy) * self.options.row_height;
        const remainder = self.model.scroll(logical_delta);
        if (remainder != 0) win.chainScroll(scroll.dx, @floatCast(-remainder / self.options.row_height));
        win.requestRender();
    }
    fn headerClick(self: *VirtualTable, col: usize, cx: *runtime.Context(VirtualTable)) void {
        const win = cx.window orelse return;
        const current: ?SortRequest = self.sort;
        if (current) |s| {
            if (s.column == col) {
                self.sort = .{ .column = s.column, .ascending = !s.ascending };
            } else {
                self.sort = .{ .column = col, .ascending = true };
            }
        } else {
            self.sort = .{ .column = col, .ascending = true };
        }
        if (self.options.sort_changed) |cb| cb(self.options.context, .{ .column = col, .ascending = self.sort.?.ascending }, win);
        win.requestRender();
    }
    fn headerResizeDown(self: *VirtualTable, column: usize, cx: *runtime.Context(VirtualTable)) void {
        const win = cx.window orelse return;
        self.syncColumnWidths();
        if (column >= self.options.columns.len or column >= max_columns) return;
        self.resizing = .{
            .column = column,
            .start_x = win.pointer_position.x,
            .start_width = self.column_widths[column],
        };
        cx.notify();
    }
    fn headerResizeMove(self: *VirtualTable, win: *Window, cx: *runtime.Context(VirtualTable)) void {
        const state = self.resizing orelse return;
        if (!win.left_button_down) return;
        _ = self.applyColumnWidth(state.column, state.start_width + (win.pointer_position.x - state.start_x), win);
        cx.notify();
    }
    fn applyColumnWidth(self: *VirtualTable, column: usize, width: f32, win: *Window) bool {
        if (column >= self.options.columns.len or column >= max_columns) return false;
        const clamped = clampColumnWidth(width);
        if (clamped == self.column_widths[column]) return false;
        self.column_widths[column] = clamped;
        if (self.options.column_resized) |callback| callback(self.options.context, column, clamped, win);
        return true;
    }
    fn headerResizeUp(self: *VirtualTable, _: *Window, cx: *runtime.Context(VirtualTable)) void {
        if (self.resizing == null) return;
        self.resizing = null;
        cx.notify();
    }
    fn reorderTarget(self: *VirtualTable, x: f32) usize {
        const count = @min(self.options.columns.len, max_columns);
        if (count == 0) return 0;
        var cursor: f32 = 0;
        for (0..count) |position| {
            const width = self.columnWidth(self.orderedColumn(position));
            if (x < cursor + width / 2) return position;
            cursor += width;
        }
        return count - 1;
    }
    fn headerReorderDown(self: *VirtualTable, position: usize, cx: *runtime.Context(VirtualTable)) void {
        const win = cx.window orelse return;
        if (position >= @min(self.options.columns.len, max_columns)) return;
        self.reordering = .{ .position = position, .start_x = win.pointer_position.x };
        cx.notify();
    }
    fn headerReorderMove(self: *VirtualTable, win: *Window, cx: *runtime.Context(VirtualTable)) void {
        var state = self.reordering orelse return;
        if (!win.left_button_down) {
            self.reordering = null;
            return;
        }
        if (!state.active and @abs(win.pointer_position.x - state.start_x) < 4) return;
        state.active = true;
        const target = self.reorderTarget(win.pointer_position.x);
        if (target != state.position) {
            _ = self.reorderColumn(state.position, target, win);
            state.position = target;
        }
        self.reordering = state;
        cx.notify();
    }
    fn headerReorderUp(self: *VirtualTable, _: *Window, cx: *runtime.Context(VirtualTable)) void {
        if (self.reordering == null) return;
        self.reordering = null;
        cx.notify();
    }
    fn rowDown(self: *VirtualTable, ref: RowRef, cx: *runtime.Context(VirtualTable)) void {
        const win = cx.window orelse return;
        const mods = win.mouse_modifiers;
        if (mods.shift) {
            self.selection.extendTo(ref.row);
        } else if (mods.ctrl) {
            self.selection.toggle(ref.row);
        } else {
            self.selection.single(ref.row);
        }
        self.pressed_row = ref.row;
        cx.notify();
    }
    fn rowUp(self: *VirtualTable, ref: RowRef, cx: *runtime.Context(VirtualTable)) void {
        const win = cx.window orelse return;
        // Press-inside/release-inside = activate (behavior semantics).
        if (self.pressed_row == ref.row) {
            if (self.options.activate) |activate| activate(self.options.context, ref.row, win);
        }
        self.pressed_row = null;
        cx.notify();
    }

    pub fn render(self: *VirtualTable, win: *Window, cx: *runtime.Context(VirtualTable)) e.Element {
        const t = self.options.tokens orelse theme.current();
        const focus = cx.focusHandle();
        self.syncColumnWidths();
        if (!win.left_button_down or !win.focused.eql(focus)) self.pressed_row = null;
        if (!win.left_button_down or !win.focused.eql(focus)) self.resizing = null;
        if (!win.left_button_down or !win.focused.eql(focus)) self.reordering = null;
        const frame = e.element.currentFrame();
        if (focus.owner_store) |store| frame.trackOwner(self, store, focus.id, focus.owner_generation);

        const provider = self.syncVariableProvider();
        if (provider) |height_provider| {
            self.model.resize(self.rowsViewportHeight(), self.estimatedVariableExtent());
            self.applyPendingAnchor();
            self.model.resize(self.rowsViewportHeight(), self.estimatedVariableExtent());
            self.built_range = self.variableRange(height_provider);
        } else {
            self.model.resize(self.rowsViewportHeight(), @as(f64, @floatFromInt(self.options.row_count)) * self.options.row_height);
            self.built_range = self.fixedRange();
            self.built_start_top = @as(f64, @floatFromInt(self.built_range.start)) * self.options.row_height;
        }
        const count = self.options.row_count;

        var rows = e.div().w(self.options.width).h(self.rowsViewportHeight());
        if (count > 0) {
            const start = self.built_range.start;
            const end = self.built_range.end;
            const focused_here = win.focused.eql(focus);
            var row_top = self.built_start_top;
            for (start..end) |index| {
                const row_height = if (provider) |height_provider| self.variableHeight(height_provider, index) else self.options.row_height;
                const y: f32 = @floatCast(row_top - self.model.offset);
                const selected = self.selection.isSelected(index);
                const active = index == self.selection.active;
                var row = e.div().keyed(self.rowKey(index)).absolute().top(y).w(self.options.width).h(@floatCast(row_height))
                    .withFocus(focus)
                    .semantic(.{ .role = .row, .name = "", .position_in_set = index + 1, .set_size = count, .states = .{ .selected = selected, .focused = active and focused_here } })
                    .bg(if (selected) theme.stateBg(t, t.palette.accent, .hovered) else if (active and focused_here) theme.stateBg(t, t.palette.surface, .hovered) else t.palette.surface)
                    .on_mouse_down(cx.listenerWith(RowRef, VirtualTable, rowDown, .{ .row = index }))
                    .on_mouse_up(cx.listenerWith(RowRef, VirtualTable, rowUp, .{ .row = index }));
                if (active and focused_here) row = row.border_color(t.palette.focus_ring);
                for (0..self.options.columns.len) |position| {
                    const ci = self.orderedColumn(position);
                    row = row.child(self.options.build_cell(self.options.context, index, ci, win));
                }
                rows = rows.child(row);
                row_top += row_height;
            }
        }

        var root = e.div().keyed(self.options.key).w(self.options.width).h(self.options.height)
            .bg(t.palette.surface).withFocus(focus).on_scroll(.{ .target = self, .call_fn = wheel })
            .semantic(.{ .role = .table, .name = self.options.label, .states = .{ .focused = win.focused.eql(focus) }, .active_descendant = if (win.focused.eql(focus) and count > 0) self.rowKey(self.selection.active) else 0, .actions = .{ .focus = true } });
        if (win.focused.eql(focus)) root = root.border_color(t.palette.focus_ring);
        // Sticky header: painted outside the scrolled content, always built.
        var bar = e.div().keyed(platform.id.fromSrc(self.options.key, @src(), 0x9d3)).w(self.options.width).h(self.options.header_height).bg(t.palette.surface_raised).semantic(.{ .role = .tableheader, .name = "Headers" });
        for (0..self.options.columns.len) |position| {
            const ci = self.orderedColumn(position);
            const col = self.options.columns[ci];
            const sorted = self.sort != null and self.sort.?.column == ci;
            const arrow: []const u8 = if (sorted) (if (self.sort.?.ascending) " ▲" else " ▼") else "";
            var header = e.div().keyed(self.headerKey(ci)).w(self.columnWidth(ci)).h(self.options.header_height).flex_row().items_center().px(6)
                .withFocus(focus)
                .semantic(.{ .role = .tableheader, .name = col.name, .position_in_set = position + 1, .set_size = self.options.columns.len })
                .on_mouse_down(cx.listenerWith(usize, VirtualTable, headerClick, ci))
                .hover_bg(theme.stateBg(t, t.palette.surface, .hovered))
                .child(e.text(col.name, .{ .size = 12, .color = t.palette.muted })).child(e.text(arrow, .{ .size = 12, .color = t.palette.muted }));
            if (ci < max_columns) {
                header = header.child(e.div().keyed(platform.id.fromSrc(self.options.key, @src(), 0x8c00 + ci)).absolute().right(0).top(0).w(8).h_full()
                    .withFocus(focus)
                    .on_mouse_down(cx.listenerWith(usize, VirtualTable, headerResizeDown, ci))
                    .on_mouse_move(cx.listener(VirtualTable, headerResizeMove))
                    .on_mouse_up(cx.listener(VirtualTable, headerResizeUp))
                    .cursor_pointer());
            }
            if (position < max_columns) {
                header = header.child(e.div().keyed(platform.id.fromSrc(self.options.key, @src(), 0x8d00 + position)).absolute().left(0).top(0).w(8).h_full()
                    .withFocus(focus)
                    .on_mouse_down(cx.listenerWith(usize, VirtualTable, headerReorderDown, position))
                    .on_mouse_move(cx.listener(VirtualTable, headerReorderMove))
                    .on_mouse_up(cx.listener(VirtualTable, headerReorderUp))
                    .cursor_pointer());
            }
            bar = bar.child(header);
        }
        root = root.child(bar);
        root = root.child(rows);
        return root;
    }
};

const VirtualTableTestHeights = struct {
    calls: usize = 0,
    multiplier: f64 = 1,
};

fn virtualTableTestHeight(raw: ?*anyopaque, index: usize, _: f32) f64 {
    const state: *VirtualTableTestHeights = @ptrCast(@alignCast(raw.?));
    state.calls += 1;
    return @as(f64, @floatFromInt(10 + (index % 3) * 10)) * state.multiplier;
}

fn virtualTableTestCell(_: ?*anyopaque, _: usize, _: usize, _: *Window) e.Element {
    return e.div();
}

fn virtualTableTestOptions(
    columns: []const Column,
    row_count: usize,
    provider: ?HeightProvider,
) VirtualTable.Options {
    return .{
        .key = 0x7a11,
        .width = 300,
        .height = 100,
        .columns = columns,
        .row_count = row_count,
        .row_height = 20,
        .height_provider = provider,
        .build_cell = virtualTableTestCell,
    };
}

test "virtual table fixed mode preserves constant range and keys" {
    const t = std.testing;
    const columns = [_]Column{.{ .name = "value", .width = 100 }};
    var table = VirtualTable{ .options = virtualTableTestOptions(&columns, 1000, null) };
    table.model.resize(100, 1000 * 20);
    _ = table.model.jump(20 * 100);
    const range = table.range();
    try t.expectEqual(@as(usize, 98), range.start);
    try t.expectEqual(@as(usize, 106), range.end);
    try t.expectEqual(table.rowKey(17), table.rowKey(17));
}

test "virtual table variable range remains bounded and places rows by provider height" {
    const t = std.testing;
    const columns = [_]Column{.{ .name = "value", .width = 100 }};
    var heights = VirtualTableTestHeights{};
    const provider = HeightProvider{ .context = &heights, .height = virtualTableTestHeight, .revision = 1 };
    var table = VirtualTable{ .options = virtualTableTestOptions(&columns, 1_000_000, provider) };
    _ = table.syncVariableProvider();
    table.model.resize(100, table.estimatedVariableExtent());
    _ = table.model.jump(10_000);
    table.built_range = table.variableRange(provider);

    const range = table.range();
    try t.expect(range.end > range.start);
    // The fixture's minimum row is 10 logical pixels, so this is a bound on
    // actual row construction, independent of the million-row collection.
    try t.expect(range.end - range.start <= 15);
    try t.expect(heights.calls <= VirtualTable.SampleCount + VirtualTable.MaxVariableProbes + 32);
    try t.expect(table.variableHeight(provider, range.start) == 10 or
        table.variableHeight(provider, range.start) == 20 or
        table.variableHeight(provider, range.start) == 30);
    try t.expect(table.variableHeight(provider, range.start + 1) != table.variableHeight(provider, range.start));
}

test "virtual table variable provider invalidates by revision and width while retaining anchor" {
    const t = std.testing;
    const columns = [_]Column{.{ .name = "value", .width = 100 }};
    var heights = VirtualTableTestHeights{};
    var table = VirtualTable{ .options = virtualTableTestOptions(
        &columns,
        100_000,
        .{ .context = &heights, .height = virtualTableTestHeight, .revision = 1 },
    ) };
    const first_provider = table.syncVariableProvider().?;
    table.model.resize(100, table.estimatedVariableExtent());
    _ = table.model.jump(8_000);
    table.built_range = table.variableRange(first_provider);
    const anchor = table.variable.anchor_index;
    const key = table.rowKey(anchor);

    heights.multiplier = 2;
    table.options.height_provider.?.revision = 2;
    const second_provider = table.syncVariableProvider().?;
    table.model.resize(100, table.estimatedVariableExtent());
    table.applyPendingAnchor();
    table.model.resize(100, table.estimatedVariableExtent());
    table.built_range = table.variableRange(second_provider);
    try t.expectEqual(@as(u64, 2), table.variable.revision);
    try t.expectEqual(anchor, table.variable.anchor_index);
    try t.expectEqual(key, table.rowKey(anchor));

    table.options.width = 420;
    _ = table.syncVariableProvider();
    try t.expectEqual(@as(f32, 420), table.variable.width);
}

test "virtual table variable selection and ensureVisible use logical row positions" {
    const t = std.testing;
    const columns = [_]Column{.{ .name = "value", .width = 100 }};
    var heights = VirtualTableTestHeights{};
    const provider = HeightProvider{ .context = &heights, .height = virtualTableTestHeight, .revision = 1 };
    var table = VirtualTable{ .options = virtualTableTestOptions(&columns, 100, provider) };
    _ = table.syncVariableProvider();
    table.model.resize(100, table.estimatedVariableExtent());
    table.built_range = table.variableRange(provider);
    table.selection.single(10);
    table.ensureVisible(10);

    // Rows 0..9 total 190 logical pixels; the table viewport is 76px after
    // the 24px header, so row 10's bottom is exposed at offset 134px.
    try t.expectEqual(@as(f64, 134), table.model.offset);
    try t.expect(table.selection.isSelected(10));
    try t.expect(!table.selection.isSelected(11));
    table.ensureVisible(0);
    try t.expectEqual(@as(f64, 0), table.model.offset);
    try t.expect(table.scrollToRow(10, .top));
    try t.expectEqual(@as(f64, 190), table.model.offset);
    try t.expect(table.scrollToRow(10, .center));
    try t.expectEqual(@as(f64, 162), table.model.offset);
    try t.expect(!table.scrollToRow(100, .top));
}

const ColumnResizeProbe = struct {
    calls: usize = 0,
    column: usize = 0,
    width: f32 = 0,
};

fn virtualTableColumnResized(raw: ?*anyopaque, column: usize, width: f32, _: *Window) void {
    const probe: *ColumnResizeProbe = @ptrCast(@alignCast(raw.?));
    probe.calls += 1;
    probe.column = column;
    probe.width = width;
}

test "virtual table column resize retains, clamps, reports, and cancels" {
    const t = std.testing;
    var app = try @import("../app/app.zig").App.initHeadless(t.allocator);
    defer app.deinit();
    const win = try app.openWindow(.{}, struct {
        fn noop(_: *Window, _: *@import("../gpu/root.zig").Scene) void {}
    }.noop);
    var store = runtime.EntityStore.init(t.allocator);
    defer store.deinit();
    var probe = ColumnResizeProbe{};
    const columns = [_]Column{ .{ .name = "A", .width = 100 }, .{ .name = "B", .width = 80 } };
    var table = VirtualTable{ .options = .{
        .key = 0x7a12,
        .width = 300,
        .height = 120,
        .columns = &columns,
        .row_count = 10,
        .row_height = 20,
        .context = &probe,
        .build_cell = virtualTableTestCell,
        .column_resized = virtualTableColumnResized,
    } };
    try t.expectEqual(@as(f32, 100), table.columnWidth(0));
    table.resizing = .{ .column = 0, .start_x = 10, .start_width = 100 };
    win.left_button_down = true;
    win.pointer_position.x = 900;
    var cx = runtime.Context(VirtualTable){ .store = &store, .window = win };
    table.headerResizeMove(win, &cx);
    try t.expectEqual(@as(f32, VirtualTable.max_column_width), table.columnWidth(0));
    try t.expectEqual(@as(usize, 1), probe.calls);
    try t.expectEqual(@as(usize, 0), probe.column);
    table.resizing = .{ .column = 0, .start_x = 10, .start_width = table.columnWidth(0) };
    win.pointer_position.x = -1000;
    table.headerResizeMove(win, &cx);
    try t.expectEqual(@as(f32, VirtualTable.min_column_width), table.columnWidth(0));
    table.resizing = .{ .column = 0, .start_x = 0, .start_width = 100 };
    _ = table.handleEvent(.{ .window = .unfocused }, &cx);
    try t.expect(table.resizing == null);
}

const ColumnReorderProbe = struct {
    calls: usize = 0,
    from: usize = 0,
    to: usize = 0,
};

fn virtualTableColumnReordered(raw: ?*anyopaque, from: usize, to: usize, _: *Window) void {
    const probe: *ColumnReorderProbe = @ptrCast(@alignCast(raw.?));
    probe.calls += 1;
    probe.from = from;
    probe.to = to;
}

test "virtual table bounded programmatic column reorder preserves source identity" {
    const t = std.testing;
    var app = try @import("../app/app.zig").App.initHeadless(t.allocator);
    defer app.deinit();
    const win = try app.openWindow(.{}, struct {
        fn noop(_: *Window, _: *@import("../gpu/root.zig").Scene) void {}
    }.noop);
    var probe = ColumnReorderProbe{};
    const columns = [_]Column{
        .{ .name = "A", .width = 100 },
        .{ .name = "B", .width = 80 },
        .{ .name = "C", .width = 60 },
    };
    var table = VirtualTable{ .options = .{
        .key = 0x7a13,
        .columns = &columns,
        .row_count = 1,
        .row_height = 20,
        .context = &probe,
        .build_cell = virtualTableTestCell,
        .column_reordered = virtualTableColumnReordered,
    } };
    try t.expectEqual(@as(usize, 0), table.orderedColumn(0));
    try t.expectEqual(@as(usize, 1), table.orderedColumn(1));
    try t.expect(table.reorderColumn(0, 2, win));
    try t.expectEqual(@as(usize, 1), table.orderedColumn(0));
    try t.expectEqual(@as(usize, 2), table.orderedColumn(1));
    try t.expectEqual(@as(usize, 0), table.orderedColumn(2));
    try t.expectEqual(@as(usize, 1), probe.calls);
    try t.expectEqual(@as(usize, 0), probe.from);
    try t.expectEqual(@as(usize, 2), probe.to);
    try t.expect(!table.reorderColumn(99, 0, win));
    try t.expect(table.reorderColumn(0, 99, win));
    try t.expectEqual(@as(usize, 1), table.orderedColumn(2));

    var drag = VirtualTable{ .options = .{
        .key = 0x7a14,
        .columns = &columns,
        .row_count = 1,
        .row_height = 20,
        .context = &probe,
        .build_cell = virtualTableTestCell,
    } };
    drag.reordering = .{ .position = 0, .start_x = 0 };
    win.left_button_down = true;
    win.pointer_position.x = 300;
    var store = runtime.EntityStore.init(t.allocator);
    defer store.deinit();
    var cx = runtime.Context(VirtualTable){ .store = &store, .window = win };
    drag.headerReorderMove(win, &cx);
    try t.expectEqual(@as(usize, 0), drag.orderedColumn(2));
    win.left_button_down = false;
    drag.headerReorderMove(win, &cx);
    try t.expect(drag.reordering == null);
}
