//! Application-grade virtual table: O(visible + overscan) construction for
//! millions of rows. The framework never owns row data: the host supplies a
//! cell builder, a row-key provider (data identity across reorders), and a
//! sort callback that REPORTS requests back — the host reorders its own
//! data. Selection is a bounded range table (64 ranges), so ctrl/shift
//! multi-select works without per-row allocation.
//!
//! Deferred seams (documented, not implemented): per-column drag-resize,
//! column reorder, variable row heights (see virtual_list.HeightProvider).
const std = @import("std");
const e = @import("../elements/root.zig");
const runtime = @import("../app/runtime.zig");
const Window = @import("../app/window.zig").Window;
const platform = @import("../platform/root.zig");
const theme = @import("theme.zig");
const a11y = @import("../a11y/root.zig");
const ScrollModel = @import("scroll_model.zig").ScrollModel;

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
    pub const Options = struct {
        key: u64,
        width: f32 = 300,
        height: f32 = 300,
        label: []const u8 = "Table",
        tokens: ?theme.Theme = null,
        columns: []const Column,
        row_count: usize,
        row_height: f64,
        header_height: f32 = 24,
        overscan: usize = 2,
        context: ?*anyopaque = null,
        build_cell: *const fn (?*anyopaque, row: usize, col: usize, *Window) e.Element,
        /// Stable data identity across reorders; index-derived by default.
        row_key: ?*const fn (?*anyopaque, usize) u64 = null,
        sort_changed: ?*const fn (?*anyopaque, SortRequest, *Window) void = null,
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

    options: Options,
    model: ScrollModel = .{},
    selection: Selection = .{},
    sort: ?SortRequest = null,
    pressed_row: ?usize = null,

    pub fn init(_: *runtime.Context(VirtualTable), options: Options) VirtualTable {
        std.debug.assert(options.key != 0);
        std.debug.assert(std.math.isFinite(options.row_height) and options.row_height > 0);
        std.debug.assert(@as(f64, @floatFromInt(options.row_count)) < 9007199254740992);
        return .{ .options = options };
    }

    /// Host resize/data contract: update options, then requestRender. The
    /// offset is reclamped against the new extent on the next render.
    pub fn updateOptions(self: *VirtualTable, options: Options) void {
        self.options = options;
    }

    fn rowsViewportHeight(self: *const VirtualTable) f32 {
        return @max(0, self.options.height - self.options.header_height);
    }

    pub fn handleEvent(self: *VirtualTable, event: platform.Event, cx: *runtime.Context(VirtualTable)) bool {
        const win = cx.window orelse return false;
        if (event == .window) {
            if (event.window == .unfocused or event.window == .close_requested) self.pressed_row = null;
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

    /// Virtualization follows the active row.
    pub fn ensureVisible(self: *VirtualTable, row: usize) void {
        const top: f64 = @as(f64, @floatFromInt(row)) * self.options.row_height;
        const bottom = top + self.options.row_height;
        const view = @as(f64, self.rowsViewportHeight());
        if (top < self.model.offset) {
            _ = self.model.jump(top);
        } else if (bottom > self.model.offset + view) {
            _ = self.model.jump(bottom - view);
        }
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
        const remainder = self.model.scroll(-@as(f64, scroll.dy) * self.options.row_height);
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
        const frame = e.element.currentFrame();
        if (focus.owner_store) |store| frame.trackOwner(self, store, focus.id, focus.owner_generation);

        self.model.resize(self.rowsViewportHeight(), @as(f64, @floatFromInt(self.options.row_count)) * self.options.row_height);
        const count = self.options.row_count;

        var rows = e.div().w(self.options.width).h(self.rowsViewportHeight());
        if (count > 0) {
            const first: usize = @intFromFloat(@min(@as(f64, @floatFromInt(count)), @floor(self.model.offset / self.options.row_height)));
            const last: usize = @intFromFloat(@min(@as(f64, @floatFromInt(count)), @ceil((self.model.offset + self.rowsViewportHeight()) / self.options.row_height)));
            const start = first -| self.options.overscan;
            const end = @min(count, last +| self.options.overscan);
            const focused_here = win.focused.eql(focus);
            for (start..end) |index| {
                const y: f32 = @floatCast(@as(f64, @floatFromInt(index)) * self.options.row_height - self.model.offset);
                const selected = self.selection.isSelected(index);
                const active = index == self.selection.active;
                var row = e.div().keyed(self.rowKey(index)).absolute().top(y).w(self.options.width).h(@floatCast(self.options.row_height))
                    .withFocus(focus)
                    .semantic(.{ .role = .row, .name = "", .position_in_set = index + 1, .set_size = count, .states = .{ .selected = selected, .focused = active and focused_here } })
                    .bg(if (selected) theme.stateBg(t, t.palette.accent, .hovered) else if (active and focused_here) theme.stateBg(t, t.palette.surface, .hovered) else t.palette.surface)
                    .on_mouse_down(cx.listenerWith(RowRef, VirtualTable, rowDown, .{ .row = index }))
                    .on_mouse_up(cx.listenerWith(RowRef, VirtualTable, rowUp, .{ .row = index }));
                if (active and focused_here) row = row.border_color(t.palette.focus_ring);
                for (self.options.columns, 0..) |_, ci| {
                    row = row.child(self.options.build_cell(self.options.context, index, ci, win));
                }
                rows = rows.child(row);
            }
        }

        var root = e.div().keyed(self.options.key).w(self.options.width).h(self.options.height)
            .bg(t.palette.surface).withFocus(focus).on_scroll(.{ .target = self, .call_fn = wheel })
            .semantic(.{ .role = .table, .name = self.options.label, .states = .{ .focused = win.focused.eql(focus) }, .active_descendant = if (win.focused.eql(focus) and count > 0) self.rowKey(self.selection.active) else 0, .actions = .{ .focus = true } });
        if (win.focused.eql(focus)) root = root.border_color(t.palette.focus_ring);
        // Sticky header: painted outside the scrolled content, always built.
        var bar = e.div().keyed(platform.id.fromSrc(self.options.key, @src(), 0x9d3)).w(self.options.width).h(self.options.header_height).bg(t.palette.surface_raised).semantic(.{ .role = .tableheader, .name = "Headers" });
        for (self.options.columns, 0..) |col, ci| {
            const sorted = self.sort != null and self.sort.?.column == ci;
            const arrow: []const u8 = if (sorted) (if (self.sort.?.ascending) " ▲" else " ▼") else "";
            bar = bar.child(e.div().keyed(self.headerKey(ci)).w(col.width).h(self.options.header_height).flex_row().items_center().px(6)
                .semantic(.{ .role = .tableheader, .name = col.name, .position_in_set = ci + 1, .set_size = self.options.columns.len })
                .on_mouse_down(cx.listenerWith(usize, VirtualTable, headerClick, ci))
                .hover_bg(theme.stateBg(t, t.palette.surface, .hovered))
                .child(e.text(col.name, .{ .size = 12, .color = t.palette.muted })).child(e.text(arrow, .{ .size = 12, .color = t.palette.muted })));
        }
        root = root.child(bar);
        root = root.child(rows);
        return root;
    }
};
