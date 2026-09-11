//! Port of cosmic-text `edit/mod.rs` + `edit/editor.rs` (editable buffer).
//!
//! Connected to the canonical subsystem types (ownership map in
//! `types.zig`): `cursor.zig` (`Cursor`/`Affinity`/`Motion`/`Scroll`),
//! `line_ending.zig`, `attrs.zig` (`Attrs`/`AttrsList`), `layout.zig`,
//! `font_system.zig`, and `buffer.zig` (`Buffer`/`BufferLine`). This file owns
//! only `Editor`, `Selection`, `Change`, `ChangeItem`, `Action`, and
//! `BufferRef`.
//!
//! Grapheme correctness: Backspace/Delete, the Previous/Next (and Left/Right)
//! cursor motions, and hit testing all step UAX #29 grapheme clusters through
//! `unicode.zig` (`prevGraphemeStart`, `nextGraphemeEnd`, `graphemeIndices`,
//! `isGraphemeBoundary`). Word motions and word selection expansion use
//! `unicode.wordBounds` (UAX #29 WB), and indent/auto-indent whitespace uses
//! `unicode.isWhitespace`.
//!
//! Preserved exactly from the Rust original:
//!   * `delete_range` split/append ending preservation + undo-text assembly
//!     (removed line texts joined by their endings);
//!   * `insert_at` line ensuring, `after` split, `final_attrs` from span-1,
//!     first/middle/last distribution with `remaining_split_len` bookkeeping,
//!     and cursor landing (`len - after_len`);
//!   * `selection_bounds` for Normal/Line/Word (word expansion via UAX #29
//!     word starts/ends);
//!   * `action` dispatch: Insert control filtering (`\t`, `\n`, U+0092
//!     allowed), Enter auto-indent, Backspace/Delete grapheme joining,
//!     Indent/Unindent `tab_width` math, Click/DoubleClick/TripleClick/Drag
//!     selection modes, Scroll;
//!   * `shape_as_needed` `cursor_moved` branch, now calling the real
//!     `Buffer.shapeUntilCursor`/`shapeUntilScroll` with the real FontSystem.
//!
//! TODO(layout): hit testing, cursor positions, and rendering still use the
//! interim monospace grid (`Editor.glyph_advance`) instead of
//! `Buffer.layoutRuns()` glyph boxes; delete the grid path once the buffer's
//! layout runs are consumed here.
//! TODO(vi/syntect): feature-gated editors.

const std = @import("std");

const Allocator = std.mem.Allocator;

const attrs = @import("attrs.zig");
const cursor_mod = @import("cursor.zig");
const line_ending = @import("line_ending.zig");
const layout = @import("layout.zig");
const font_system = @import("font_system.zig");
const font_mod = @import("font.zig");
const buffer_mod = @import("buffer.zig");
const buffer_line_mod = @import("buffer_line.zig");
const unicode = @import("unicode.zig");

/// Local error set: allocator failures plus the canonical buffer/shaper
/// errors this module can surface, plus editor-only errors (no panics).
pub const Error = buffer_mod.Error || error{
    InvalidData,
    ChangeInProgress,
};

// ---------------------------------------------------------------------------
// Canonical type aliases (no local stand-ins; see `types.zig`)
// ---------------------------------------------------------------------------

pub const LineEnding = line_ending.LineEnding;
pub const LineIter = line_ending.LineIter;
pub const Line = line_ending.Line;

pub const Affinity = cursor_mod.Affinity;
pub const Cursor = cursor_mod.Cursor;
pub const LayoutCursor = cursor_mod.LayoutCursor;
pub const Motion = cursor_mod.Motion;
pub const Scroll = cursor_mod.Scroll;

pub const Attrs = attrs.Attrs;
pub const AttrsList = attrs.AttrsList;

pub const FontSystem = font_system.FontSystem;

pub const Buffer = buffer_mod.Buffer;
/// Canonical owner of `BufferLine` is `buffer_line.zig` (re-exported here so
/// `edit` consumers use one import).
pub const BufferLine = buffer_line_mod.BufferLine;

/// Re-export the canonical laid-out line type (`layout.zig` owns it) so edit
/// consumers do not need a second import.
pub const LayoutLine = layout.LayoutLine;

/// A `Buffer` that the editor either owns or borrows, mirroring the Rust
/// `BufferRef`.
pub const BufferRef = union(enum) {
    /// The editor owns (and deinitializes) this buffer.
    owned: Buffer,
    /// The editor mutates a caller-owned buffer and must not deinit it.
    borrowed: *Buffer,

    /// Borrow the underlying buffer.
    pub fn get(self: *const BufferRef) *const Buffer {
        return switch (self.*) {
            .owned => &self.owned,
            .borrowed => self.borrowed,
        };
    }

    /// Mutably borrow the underlying buffer.
    pub fn getMut(self: *BufferRef) *Buffer {
        return switch (self.*) {
            .owned => &self.owned,
            .borrowed => self.borrowed,
        };
    }

    pub fn isOwned(self: *const BufferRef) bool {
        return self.* == .owned;
    }

    /// Deinitialize the buffer only when this ref owns it.
    pub fn deinit(self: *BufferRef) void {
        switch (self.*) {
            .owned => self.owned.deinit(),
            .borrowed => {},
        }
    }
};

// ---------------------------------------------------------------------------
// Selection, changes, actions
// ---------------------------------------------------------------------------

/// Selection mode, mirroring cosmic-text `Selection`.
pub const Selection = union(enum) {
    none: void,
    normal: Cursor,
    line: Cursor,
    word: Cursor,

    pub fn eql(a: Selection, b: Selection) bool {
        return std.meta.eql(a, b);
    }
};

/// One undoable change item, mirroring `ChangeItem`.
pub const ChangeItem = struct {
    start: Cursor,
    end: Cursor,
    text: std.ArrayList(u8),
    insert: bool,

    pub fn deinit(self: *ChangeItem, allocator: Allocator) void {
        self.text.deinit(allocator);
        self.* = undefined;
    }

    pub fn reverse(self: *ChangeItem) void {
        self.insert = !self.insert;
    }
};

/// A logical change grouping items, mirroring `Change`.
pub const Change = struct {
    items: std.ArrayList(ChangeItem),

    pub fn init(allocator: Allocator) Change {
        _ = allocator;
        return .{ .items = .empty };
    }

    pub fn deinit(self: *Change, allocator: Allocator) void {
        for (self.items.items) |*item| item.deinit(allocator);
        self.items.deinit(allocator);
        self.* = undefined;
    }

    pub fn reverse(self: *Change) void {
        std.mem.reverse(ChangeItem, self.items.items);
        for (self.items.items) |*item| item.reverse();
    }
};

/// An editing action, mirroring cosmic-text `Action`.
pub const Action = union(enum) {
    motion: Motion,
    escape: void,
    insert: u21,
    enter: void,
    backspace: void,
    delete: void,
    indent: void,
    unindent: void,
    click: struct { x: i32, y: i32 },
    double_click: struct { x: i32, y: i32 },
    triple_click: struct { x: i32, y: i32 },
    drag: struct { x: i32, y: i32 },
    scroll: struct { pixels: f32 },
};

// ---------------------------------------------------------------------------
// Editor
// ---------------------------------------------------------------------------

/// RGBA color (canonical owner `attrs.Color`).
pub const Color = attrs.Color;

/// Minimal renderer interface: filled rectangles only. Glyph rasterization
/// arrives with the font/renderer port.
/// TODO(render): full `Renderer` (glyphs, decorations with font metrics).
pub const Renderer = struct {
    ptr: *anyopaque,
    rectangleFn: *const fn (ptr: *anyopaque, x: i32, y: i32, w: u32, h: u32, color: Color) void,

    pub fn rectangle(self: Renderer, x: i32, y: i32, w: u32, h: u32, color: Color) void {
        self.rectangleFn(self.ptr, x, y, w, h, color);
    }
};

/// Editable buffer wrapper, mirroring cosmic-text `Editor` (the struct form
/// of `Editor<'buffer>` + the `Edit` trait methods).
pub const Editor = struct {
    allocator: Allocator,
    buffer_ref: BufferRef,
    cursor: Cursor,
    cursor_x_opt: ?i32,
    selection: Selection,
    cursor_moved: bool,
    auto_indent: bool,
    change: ?Change,
    /// Interim monospace cell width for `hit`/`cursorPosition`/`render`
    /// until they consume `Buffer.layoutRuns()`. The buffer still owns real
    /// shaping; this only backs the naive grid.
    /// TODO(layout): delete with the naive hit/render path.
    glyph_advance: f32 = 10,

    /// Create an editor owning a fresh empty buffer.
    pub fn init(allocator: Allocator) Error!Editor {
        var buf = try Buffer.initWithAllocator(allocator, .{ .font_size = 14, .line_height = 20 });
        errdefer buf.deinit();
        try buf.lines.append(allocator, BufferLine.empty(allocator));
        return .{
            .allocator = allocator,
            .buffer_ref = .{ .owned = buf },
            .cursor = .{},
            .cursor_x_opt = null,
            .selection = .{ .none = {} },
            .cursor_moved = false,
            .auto_indent = false,
            .change = null,
        };
    }

    /// Create an editor editing a caller-owned buffer (the buffer outlives
    /// the editor; `deinit` leaves it intact).
    pub fn initWithBuffer(allocator: Allocator, buf: *Buffer) Editor {
        return .{
            .allocator = allocator,
            .buffer_ref = .{ .borrowed = buf },
            .cursor = .{},
            .cursor_x_opt = null,
            .selection = .{ .none = {} },
            .cursor_moved = false,
            .auto_indent = false,
            .change = null,
        };
    }

    pub fn deinit(self: *Editor) void {
        self.buffer_ref.deinit();
        if (self.change) |*c| c.deinit(self.allocator);
        self.* = undefined;
    }

    /// Borrow the underlying buffer.
    pub fn buffer(self: *const Editor) *const Buffer {
        return self.buffer_ref.get();
    }

    /// Mutably borrow the underlying buffer.
    pub fn bufferMut(self: *Editor) *Buffer {
        return self.buffer_ref.getMut();
    }

    pub fn getCursor(self: *const Editor) Cursor {
        return self.cursor;
    }

    pub fn setCursor(self: *Editor, cursor: Cursor) void {
        if (!std.meta.eql(self.cursor, cursor)) {
            self.cursor = cursor;
            self.cursor_moved = true;
            self.bufferMut().setRedraw(true);
        }
    }

    pub fn getSelection(self: *const Editor) Selection {
        return self.selection;
    }

    pub fn setSelection(self: *Editor, selection: Selection) void {
        if (!Selection.eql(self.selection, selection)) {
            self.selection = selection;
            self.bufferMut().setRedraw(true);
        }
    }

    pub fn getAutoIndent(self: *const Editor) bool {
        return self.auto_indent;
    }

    pub fn setAutoIndent(self: *Editor, auto_indent: bool) void {
        self.auto_indent = auto_indent;
    }

    pub fn getTabWidth(self: *const Editor) u16 {
        return self.buffer().getTabWidth();
    }

    pub fn setTabWidth(self: *Editor, tab_width: u16) void {
        self.bufferMut().setTabWidth(tab_width);
    }

    /// Ordered selection bounds, with Line/Word expansion.
    pub fn selectionBounds(self: *const Editor) ?SelectionBounds {
        const cur = self.cursor;
        const lines = self.buffer().lines.items;
        switch (self.selection) {
            .none => return null,
            .normal => |select| {
                return switch (select.order(cur)) {
                    .gt => .{ .start = cur, .end = select },
                    else => .{ .start = select, .end = cur },
                };
            },
            .line => |select| {
                const s = @min(select.line, cur.line);
                const e = @max(select.line, cur.line);
                if (e >= lines.len) return null;
                return .{
                    .start = Cursor.new(s, 0),
                    .end = Cursor.new(e, lines[e].textSlice().len),
                };
            },
            .word => |select| {
                var start: Cursor = undefined;
                var end: Cursor = undefined;
                switch (select.order(cur)) {
                    .gt => {
                        start = cur;
                        end = select;
                    },
                    else => {
                        start = select;
                        end = cur;
                    },
                }
                if (start.line >= lines.len) return null;
                if (end.line >= lines.len) return null;
                start.index = prevWordStart(lines[start.line].textSlice(), start.index);
                end.index = nextWordEnd(lines[end.line].textSlice(), end.index);
                return .{ .start = start, .end = end };
            },
        }
    }

    /// Shape the buffer with the real engine, mirroring `shape_as_needed`:
    /// shapes until the cursor when it moved, else until the scroll position,
    /// then clears `cursor_moved`. Errors propagate (never silently dropped).
    pub fn shapeAsNeeded(self: *Editor, font_system_: *FontSystem, prune: bool) Error!void {
        const buf = self.bufferMut();
        if (self.cursor_moved) {
            try buf.shapeUntilCursor(font_system_, self.cursor, prune);
            self.cursor_moved = false;
        } else {
            try buf.shapeUntilScroll(font_system_, prune);
        }
    }

    /// Delete `[start, end)`, preserving endings across joined lines and
    /// recording undo text (removed texts joined by their endings).
    pub fn deleteRange(self: *Editor, start_in: Cursor, end_in: Cursor) Error!void {
        var start = start_in;
        var end = end_in;
        if (start.order(end) == .gt) {
            const tmp = start;
            start = end;
            end = tmp;
        }
        const allocator = self.allocator;
        const buf = self.bufferMut();
        if (start.line >= buf.lines.items.len) return error.InvalidCursor;
        if (end.line >= buf.lines.items.len) return error.InvalidCursor;
        if (start.index > buf.lines.items[start.line].textSlice().len) {
            return error.InvalidCursor;
        }
        if (end.index > buf.lines.items[end.line].textSlice().len) {
            return error.InvalidCursor;
        }

        var change_lines: std.ArrayList(BufferLine) = .empty;
        defer {
            for (change_lines.items) |*l| l.deinit();
            change_lines.deinit(allocator);
        }

        var end_line_opt: ?BufferLine = null;
        defer if (end_line_opt) |*l| l.deinit();
        if (end.line > start.line) {
            var after = try buf.lines.items[end.line].splitOff(end.index);
            const removed = buf.lines.orderedRemove(end.line);
            change_lines.insert(allocator, 0, removed) catch |e| {
                var r = removed;
                r.deinit();
                after.deinit();
                return e;
            };
            end_line_opt = after;
        }

        var li = end.line;
        while (li > start.line + 1) {
            li -= 1;
            const removed = buf.lines.orderedRemove(li);
            change_lines.insert(allocator, 0, removed) catch |e| {
                var r = removed;
                r.deinit();
                return e;
            };
        }

        {
            const line = &buf.lines.items[start.line];
            var after_opt: ?BufferLine = null;
            defer if (after_opt) |*l| l.deinit();
            if (start.line == end.line) {
                after_opt = try line.splitOff(end.index);
            }
            const removed = try line.splitOff(start.index);
            change_lines.insert(allocator, 0, removed) catch |e| {
                var r = removed;
                r.deinit();
                return e;
            };
            if (after_opt) |after| {
                try line.append(&after);
            }
            if (end_line_opt) |*end_line| {
                if (end_line.ending == .none) {
                    _ = end_line.setEnding(line.ending);
                }
                try line.append(end_line);
            }
        }

        var text: std.ArrayList(u8) = .empty;
        errdefer text.deinit(allocator);
        var first = true;
        var last_ending: LineEnding = .none;
        for (change_lines.items) |*l| {
            if (!first) {
                try text.appendSlice(allocator, last_ending.asStr());
            }
            first = false;
            try text.appendSlice(allocator, l.textSlice());
            last_ending = l.ending;
        }

        if (self.change) |*c| {
            try c.items.append(allocator, .{
                .start = start,
                .end = end,
                .text = text,
                .insert = false,
            });
        } else {
            text.deinit(allocator);
        }
    }

    /// Insert `data` at `cursor`, splitting lines on `LineIter` boundaries.
    /// Returns the cursor just past the inserted text.
    /// Takes ownership of `attrs_list` when non-null (pass the list by value
    /// and do not deinit it afterwards).
    pub fn insertAt(
        self: *Editor,
        cursor_in: Cursor,
        data: []const u8,
        attrs_list: ?AttrsList,
    ) Error!Cursor {
        var cursor = cursor_in;
        if (data.len == 0) {
            if (attrs_list) |a| {
                var owned = a;
                owned.deinit();
            }
            return cursor;
        }
        const allocator = self.allocator;
        const buf = self.bufferMut();
        const start = cursor;

        // Ensure enough lines exist for this cursor.
        while (cursor.line >= buf.lines.items.len) {
            var last_ending: LineEnding = .none;
            if (buf.lines.items.len > 0) {
                const last = &buf.lines.items[buf.lines.items.len - 1];
                last_ending = last.ending;
                if (last_ending == .none) {
                    _ = last.setEnding(LineEnding.default);
                    last_ending = last.ending;
                }
            }
            var line = BufferLine.empty(allocator);
            errdefer line.deinit();
            if (attrs_list) |a| {
                var borrowed = try a.defaults(allocator);
                defer borrowed.deinit();
                const fresh = try AttrsList.init(allocator, &borrowed);
                line.attrs_list.deinit();
                line.attrs_list = fresh;
            } else if (buf.lines.items.len > 0) {
                const last = &buf.lines.items[buf.lines.items.len - 1];
                var borrowed = try last.attrs_list.defaults(allocator);
                defer borrowed.deinit();
                const fresh = try AttrsList.init(allocator, &borrowed);
                line.attrs_list.deinit();
                line.attrs_list = fresh;
            }
            line.ending = last_ending;
            try buf.lines.append(allocator, line);
        }

        if (cursor.index > buf.lines.items[cursor.line].textSlice().len) {
            return error.InvalidCursor;
        }
        // Collect the text after the insertion point; rejoined below.
        var after = try buf.lines.items[cursor.line].splitOff(cursor.index);
        defer after.deinit();
        const after_len = after.textSlice().len;

        // Attributes for the inserted text: explicit, else the previous
        // character's span (mirrors `get_span(index.saturating_sub(1))`).
        var final_attrs: AttrsList = if (attrs_list) |a| a else blk: {
            const span_attrs = buf.lines.items[cursor.line].attrs_list.get_span(cursor.index -| 1);
            break :blk AttrsList.init_owned(allocator, try span_attrs.clone_with(allocator));
        };
        defer final_attrs.deinit();

        // Split the data into lines; a trailing line with no ending always
        // exists (mirrors the `lines.push((default, None))` rule).
        var parts: std.ArrayList(Line) = .empty;
        defer parts.deinit(allocator);
        var diter = LineIter.init(data);
        while (diter.next()) |item| try parts.append(allocator, item);
        if (parts.items.len == 0 or parts.items[parts.items.len - 1].ending != .none) {
            try parts.append(allocator, .{ .start = 0, .end = 0, .ending = .none });
        }
        var remaining = data.len;
        var front: usize = 0;
        var back: usize = parts.items.len;
        const insert_line = cursor.line + 1;

        // First data line joins the current line. `splitOff` returns the
        // suffix, so swapping hands the prefix to the new line.
        {
            const item = parts.items[front];
            front += 1;
            const data_line = data[item.start..item.end];
            var piece = try final_attrs.split_off(data_line.len);
            std.mem.swap(AttrsList, &final_attrs, &piece);
            var tmp = BufferLine.initOwned(allocator, data_line, item.ending, piece, .advanced) catch |e| {
                var p = piece;
                p.deinit();
                return e;
            };
            errdefer tmp.deinit();
            remaining -= data_line.len + item.ending.asStr().len;
            try buf.lines.items[cursor.line].append(&tmp);
            tmp.deinit();
        }
        // Last data line joins `after` (skipped when only one part exists).
        if (back > front) {
            back -= 1;
            const item = parts.items[back];
            const data_line = data[item.start..item.end];
            remaining -= data_line.len + item.ending.asStr().len;
            var piece = try final_attrs.split_off(remaining);
            std.mem.swap(AttrsList, &final_attrs, &piece);
            // Scope the errdefer to the insert so later errors cannot
            // double-free the line now owned by `buf`.
            {
                var tmp = BufferLine.initOwned(allocator, data_line, item.ending, piece, .advanced) catch |e| {
                    var p = piece;
                    p.deinit();
                    return e;
                };
                errdefer tmp.deinit();
                try tmp.append(&after);
                try buf.lines.insert(allocator, insert_line, tmp);
            }
            cursor.line += 1;
            // Middle lines, newest first at `insert_line` (mirrors `rev()`).
            while (back > front) {
                back -= 1;
                const m = parts.items[back];
                const mline = data[m.start..m.end];
                remaining -= mline.len + m.ending.asStr().len;
                var mpiece = try final_attrs.split_off(remaining);
                std.mem.swap(AttrsList, &final_attrs, &mpiece);
                var mtmp = BufferLine.initOwned(allocator, mline, m.ending, mpiece, .advanced) catch |e| {
                    var p = mpiece;
                    p.deinit();
                    return e;
                };
                errdefer mtmp.deinit();
                try buf.lines.insert(allocator, insert_line, mtmp);
                cursor.line += 1;
            }
        } else {
            // Single-line insert: rejoin `after` onto the current line.
            try buf.lines.items[cursor.line].append(&after);
        }
        if (remaining != 0) return error.InvalidData;
        cursor.index = buf.lines.items[cursor.line].textSlice().len - after_len;

        if (self.change) |*c| {
            var owned: std.ArrayList(u8) = .empty;
            errdefer owned.deinit(allocator);
            try owned.appendSlice(allocator, data);
            try c.items.append(allocator, .{
                .start = start,
                .end = cursor,
                .text = owned,
                .insert = true,
            });
        }
        return cursor;
    }

    /// Copy the selection, joining lines with `\n`. Null when no selection.
    pub fn copySelection(self: *const Editor) Error!?std.ArrayList(u8) {
        const bounds = self.selectionBounds() orelse return null;
        const lines = self.buffer().lines.items;
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(self.allocator);
        const start = bounds.start;
        const end = bounds.end;
        if (start.line == end.line) {
            try out.appendSlice(self.allocator, lines[start.line].textSlice()[start.index..end.index]);
        } else {
            try out.appendSlice(self.allocator, lines[start.line].textSlice()[start.index..]);
            try out.append(self.allocator, '\n');
        }
        var li = start.line + 1;
        while (li < end.line) : (li += 1) {
            try out.appendSlice(self.allocator, lines[li].textSlice());
            try out.append(self.allocator, '\n');
        }
        if (end.line > start.line) {
            try out.appendSlice(self.allocator, lines[end.line].textSlice()[0..end.index]);
        }
        return out;
    }

    /// Delete the selection, resetting the cursor to its start.
    pub fn deleteSelection(self: *Editor) Error!bool {
        const bounds = self.selectionBounds() orelse return false;
        self.cursor = bounds.start;
        self.selection = .{ .none = {} };
        try self.deleteRange(bounds.start, bounds.end);
        return true;
    }

    /// Replace the selection (if any) with `data`, moving the cursor past it.
    pub fn insertString(self: *Editor, data: []const u8, attrs_list: ?AttrsList) Error!void {
        _ = try self.deleteSelection();
        const new_cursor = try self.insertAt(self.cursor, data, attrs_list);
        self.setCursor(new_cursor);
    }

    /// Apply a recorded change. Refused (false) while another change is open.
    pub fn applyChange(self: *Editor, change: *const Change) Error!bool {
        if (self.change) |pending| {
            if (pending.items.items.len > 0) {
                self.change = pending;
                return false;
            }
            // Empty pending change: drop it and proceed.
            var drop = pending;
            drop.deinit(self.allocator);
            self.change = null;
        }
        for (change.items.items) |*item| {
            if (item.insert) {
                self.cursor = try self.insertAt(item.start, item.text.items, null);
            } else {
                self.cursor = item.start;
                try self.deleteRange(item.start, item.end);
            }
        }
        return true;
    }

    pub fn startChange(self: *Editor) void {
        if (self.change == null) {
            self.change = Change.init(self.allocator);
        }
    }

    pub fn finishChange(self: *Editor) ?Change {
        if (self.change) |c| {
            self.change = null;
            return c;
        }
        return null;
    }

    /// Full buffer text with endings, for tests/debugging. Caller owns it.
    pub fn fullText(self: *const Editor) Allocator.Error!std.ArrayList(u8) {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(self.allocator);
        for (self.buffer().lines.items) |*line| {
            try out.appendSlice(self.allocator, line.textSlice());
            try out.appendSlice(self.allocator, line.ending.asStr());
        }
        return out;
    }

    /// Interim grapheme-aware hit test on the monospace grid.
    /// TODO(layout): replace with `Buffer.hit` layout-run hit testing.
    pub fn hit(self: *const Editor, x: f32, y: f32) ?Cursor {
        return hitLines(
            self.buffer().lines.items,
            x,
            y,
            self.buffer().metrics.line_height,
            self.glyph_advance,
        );
    }

    /// Interim grapheme-aware cursor position on the monospace grid.
    /// TODO(layout): replace with `Buffer.cursorPosition`.
    pub fn cursorPosition(self: *const Editor) ?CursorPosition {
        return cursorPositionLines(
            self.buffer().lines.items,
            &self.cursor,
            self.buffer().metrics.line_height,
            self.glyph_advance,
        );
    }

    /// Perform an `Action` on the editor.
    pub fn action(self: *Editor, font_system_: *FontSystem, act: Action) Error!void {
        // Motion/hit are grapheme-stepped locally (see file header); the
        // FontSystem is threaded for API parity and forward to nested
        // `Enter` actions (callers shape with `shapeAsNeeded`).
        const old_cursor = self.cursor;
        switch (act) {
            .motion => |motion| {
                if (motionCursor(
                    self.buffer().lines.items,
                    self.cursor,
                    self.cursor_x_opt,
                    self.buffer().metrics.line_height,
                    motion,
                )) |r| {
                    self.cursor = r.cursor;
                    self.cursor_x_opt = r.x_opt;
                }
            },
            .escape => {
                switch (self.selection) {
                    .none => {},
                    else => self.bufferMut().setRedraw(true),
                }
                self.selection = .{ .none = {} };
            },
            .insert => |cp| {
                if (isControl(cp) and cp != '\t' and cp != '\n' and cp != 0x92) {
                    // Filter out control characters (use actions instead).
                } else if (cp == '\n') {
                    try self.action(font_system_, .{ .enter = {} });
                } else {
                    var buf: [4]u8 = undefined;
                    const len = std.unicode.utf8Encode(cp, &buf) catch return;
                    try self.insertString(buf[0..len], null);
                }
            },
            .enter => {
                if (self.auto_indent) {
                    var line_text: std.ArrayList(u8) = .empty;
                    defer line_text.deinit(self.allocator);
                    try line_text.append(self.allocator, '\n');
                    const text = self.buffer().lines.items[self.cursor.line].textSlice();
                    var it = unicode.codepointIterator(text);
                    while (it.next()) |cp| {
                        if (!unicode.isWhitespace(cp.value)) break;
                        var enc: [4]u8 = undefined;
                        const n = std.unicode.utf8Encode(cp.value, &enc) catch break;
                        try line_text.appendSlice(self.allocator, enc[0..n]);
                    }
                    try self.insertString(line_text.items, null);
                } else {
                    try self.insertString("\n", null);
                }
            },
            .backspace => {
                if (!(try self.deleteSelection())) {
                    const end = self.cursor;
                    if (self.cursor.index > 0) {
                        // Whole UAX #29 grapheme cluster before the cursor.
                        self.cursor.index = unicode.prevGraphemeStart(
                            self.buffer().lines.items[self.cursor.line].textSlice(),
                            self.cursor.index,
                        );
                    } else if (self.cursor.line > 0) {
                        self.cursor.line -= 1;
                        self.cursor.index = self.buffer().lines.items[self.cursor.line].textSlice().len;
                    }
                    if (!std.meta.eql(self.cursor, end)) {
                        try self.deleteRange(self.cursor, end);
                    }
                }
            },
            .delete => {
                if (!(try self.deleteSelection())) {
                    const start = self.cursor;
                    var end = self.cursor;
                    const text = self.buffer().lines.items[start.line].textSlice();
                    if (start.index < text.len) {
                        // Whole UAX #29 grapheme cluster at the cursor.
                        end.index = unicode.nextGraphemeEnd(text, start.index);
                    } else if (start.line + 1 < self.buffer().lines.items.len) {
                        end.line += 1;
                        end.index = 0;
                    }
                    if (!std.meta.eql(start, end)) {
                        self.cursor = start;
                        try self.deleteRange(start, end);
                    }
                }
            },
            .indent => {
                const bounds: SelectionBounds = self.selectionBounds() orelse
                    .{ .start = self.cursor, .end = self.cursor };
                const tab_width: usize = @intCast(self.getTabWidth());
                var line_i = bounds.start.line;
                while (line_i <= bounds.end.line) : (line_i += 1) {
                    var after_whitespace: usize = 0;
                    var required_indent: usize = 0;
                    const text = self.buffer().lines.items[line_i].textSlice();
                    if (self.selection == .none) {
                        // Count whitespace codepoints backwards from the
                        // cursor (`None` means the whole prefix is blank).
                        const whitespace_length = trailingWhitespaceCodepoints(
                            text,
                            self.cursor.index,
                        ) orelse self.cursor.index;
                        if (tab_width > 0) {
                            required_indent = tab_width - (whitespace_length % tab_width);
                        }
                        after_whitespace = @min(self.cursor.index, text.len);
                    } else {
                        var count: usize = 0;
                        var it = unicode.codepointIterator(text);
                        var found = false;
                        while (it.next()) |cp| {
                            if (!unicode.isWhitespace(cp.value)) {
                                after_whitespace = it.pos - cp.len;
                                if (tab_width > 0) {
                                    required_indent = tab_width - (count % tab_width);
                                }
                                found = true;
                                break;
                            }
                            count += 1;
                        }
                        if (!found) {
                            after_whitespace = 0;
                            required_indent = 0;
                        }
                    }
                    if (required_indent > 0) {
                        var spaces: std.ArrayList(u8) = .empty;
                        defer spaces.deinit(self.allocator);
                        var s: usize = 0;
                        while (s < required_indent) : (s += 1) {
                            try spaces.append(self.allocator, ' ');
                        }
                        const at = Cursor.new(line_i, after_whitespace);
                        _ = try self.insertAt(at, spaces.items, null);
                        if (self.cursor.line == line_i) {
                            if (self.cursor.index < after_whitespace) {
                                self.cursor.index = after_whitespace;
                            }
                            self.cursor.index += required_indent;
                        }
                        switch (self.selection) {
                            .none => {},
                            .normal => |*sel| {
                                if (sel.line == line_i and sel.index >= after_whitespace) {
                                    sel.index += required_indent;
                                }
                            },
                            .line => |*sel| {
                                if (sel.line == line_i and sel.index >= after_whitespace) {
                                    sel.index += required_indent;
                                }
                            },
                            .word => |*sel| {
                                if (sel.line == line_i and sel.index >= after_whitespace) {
                                    sel.index += required_indent;
                                }
                            },
                        }
                    }
                    self.bufferMut().setRedraw(true);
                }
            },
            .unindent => {
                const bounds: SelectionBounds = self.selectionBounds() orelse
                    .{ .start = self.cursor, .end = self.cursor };
                const tab_width: usize = @intCast(self.getTabWidth());
                var line_i = bounds.start.line;
                while (line_i <= bounds.end.line) : (line_i += 1) {
                    const text = self.buffer().lines.items[line_i].textSlice();
                    var last_indent: usize = 0;
                    var after_whitespace: usize = text.len;
                    var count: usize = 0;
                    var it = unicode.codepointIterator(text);
                    while (it.next()) |cp| {
                        const cp_start = it.pos - cp.len;
                        if (!unicode.isWhitespace(cp.value)) {
                            after_whitespace = cp_start;
                            break;
                        }
                        if (tab_width > 0 and count % tab_width == 0) {
                            last_indent = cp_start;
                        }
                        count += 1;
                    }
                    if (last_indent == after_whitespace) continue;
                    try self.deleteRange(
                        Cursor.new(line_i, last_indent),
                        Cursor.new(line_i, after_whitespace),
                    );
                    // Saturating adjust (upstream can underflow here).
                    if (self.cursor.line == line_i and self.cursor.index > last_indent) {
                        self.cursor.index = last_indent +
                            (self.cursor.index -| after_whitespace);
                    }
                    switch (self.selection) {
                        .none => {},
                        .normal => |*sel| {
                            if (sel.line == line_i and sel.index > last_indent) {
                                sel.index = last_indent + (sel.index -| after_whitespace);
                            }
                        },
                        .line => |*sel| {
                            if (sel.line == line_i and sel.index > last_indent) {
                                sel.index = last_indent + (sel.index -| after_whitespace);
                            }
                        },
                        .word => |*sel| {
                            if (sel.line == line_i and sel.index > last_indent) {
                                sel.index = last_indent + (sel.index -| after_whitespace);
                            }
                        },
                    }
                    self.bufferMut().setRedraw(true);
                }
            },
            .click => |pos| {
                self.setSelection(.{ .none = {} });
                const x: f32 = @floatFromInt(pos.x);
                const y: f32 = @floatFromInt(pos.y);
                if (self.hit(x, y)) |new_cursor| {
                    if (!std.meta.eql(new_cursor, self.cursor)) {
                        self.cursor = new_cursor;
                        self.bufferMut().setRedraw(true);
                    }
                }
            },
            .double_click => |pos| {
                self.setSelection(.{ .none = {} });
                const x: f32 = @floatFromInt(pos.x);
                const y: f32 = @floatFromInt(pos.y);
                if (self.hit(x, y)) |new_cursor| {
                    if (!std.meta.eql(new_cursor, self.cursor)) {
                        self.cursor = new_cursor;
                        self.bufferMut().setRedraw(true);
                    }
                    self.selection = .{ .word = self.cursor };
                    self.bufferMut().setRedraw(true);
                }
            },
            .triple_click => |pos| {
                self.setSelection(.{ .none = {} });
                const x: f32 = @floatFromInt(pos.x);
                const y: f32 = @floatFromInt(pos.y);
                if (self.hit(x, y)) |new_cursor| {
                    if (!std.meta.eql(new_cursor, self.cursor)) {
                        self.cursor = new_cursor;
                    }
                    self.selection = .{ .line = self.cursor };
                    self.bufferMut().setRedraw(true);
                }
            },
            .drag => |pos| {
                if (self.selection == .none) {
                    self.selection = .{ .normal = self.cursor };
                    self.bufferMut().setRedraw(true);
                }
                const x: f32 = @floatFromInt(pos.x);
                const y: f32 = @floatFromInt(pos.y);
                if (self.hit(x, y)) |new_cursor| {
                    if (!std.meta.eql(new_cursor, self.cursor)) {
                        self.cursor = new_cursor;
                        self.bufferMut().setRedraw(true);
                    }
                }
            },
            .scroll => |s| {
                self.bufferMut().scroll.vertical += s.pixels;
                self.bufferMut().setRedraw(true);
            },
        }
        if (!std.meta.eql(old_cursor, self.cursor)) {
            self.cursor_moved = true;
            self.bufferMut().setRedraw(true);
        }
    }

    /// Render selection highlights, the cursor, and decorations.
    ///
    /// One visual run per buffer line on the interim monospace grid:
    ///   * multi-line selections extend the last rect of each non-final line
    ///     to the buffer edge (RTL extends `min` to 0, else `max` to width);
    ///   * empty interior lines highlight full width;
    ///   * the cursor draws a 1px-wide rect;
    ///   * underline/strikethrough spans draw 1px rects.
    /// TODO(layout): render from `Buffer.layoutRuns()` glyph boxes.
    pub fn render(
        self: *const Editor,
        renderer: Renderer,
        text_color: Color,
        cursor_color: Color,
        selection_color: Color,
        selected_text_color: Color,
    ) void {
        _ = selected_text_color;
        const bounds = self.selectionBounds();
        const buf = self.buffer();
        const width: i32 = if (buf.width_opt) |w| floatToI32Saturating(w) else 0;
        const line_height = buf.metrics.line_height;
        for (buf.lines.items, 0..) |*line, line_i| {
            const text = line.textSlice();
            const line_top: i32 = floatToI32Saturating(
                @as(f32, @floatFromInt(line_i)) * line_height,
            );
            const lh: u32 = @intCast(@max(floatToI32Saturating(line_height), 0));
            const rtl = detectRtlLine(text);

            if (bounds) |b| {
                if (line_i >= b.start.line and line_i <= b.end.line) {
                    var spans = highlightRun(
                        self.allocator,
                        text,
                        line_i,
                        b.start,
                        b.end,
                        self.glyph_advance,
                    ) catch continue;
                    defer spans.deinit(self.allocator);
                    if (spans.items.len == 0 and unicode.countGraphemes(text) == 0 and b.end.line > line_i) {
                        renderer.rectangle(0, line_top, @intCast(@max(width, 0)), lh, selection_color);
                    } else {
                        const len = spans.items.len;
                        for (spans.items, 0..) |h, idx| {
                            var min = floatToI32Saturating(h.x);
                            var max = floatToI32Saturating(h.x + h.width);
                            if (idx == len - 1 and b.end.line > line_i) {
                                if (rtl) {
                                    min = 0;
                                } else {
                                    max = width;
                                }
                            }
                            renderer.rectangle(
                                min,
                                line_top,
                                @intCast(@max(max - min, 0)),
                                lh,
                                selection_color,
                            );
                        }
                    }
                }
            }

            if (cursorPositionLines(buf.lines.items, &self.cursor, line_height, self.glyph_advance)) |pos| {
                // Never `@intFromFloat` untrusted floats: saturate and fall
                // back to the logical cursor line on NaN/inf/degenerate metrics.
                const cursor_line: usize = blk: {
                    if (!std.math.isFinite(pos.y) or !std.math.isFinite(line_height) or line_height <= 0) {
                        break :blk self.cursor.line;
                    }
                    const f = @floor(pos.y / line_height);
                    if (!std.math.isFinite(f) or f < 0) break :blk 0;
                    if (f >= @as(f32, @floatFromInt(buf.lines.items.len))) {
                        break :blk self.cursor.line;
                    }
                    break :blk @intFromFloat(f);
                };
                if (cursor_line == line_i) {
                    renderer.rectangle(floatToI32Saturating(pos.x), line_top, 1, lh, cursor_color);
                }
            }

            // Decorations from span flags (metric-free 1px lines).
            var has_underline = line.attrs_list.default_attrs.text_decoration.underline != .none;
            var has_strike = line.attrs_list.default_attrs.text_decoration.strikethrough;
            if (!has_underline or !has_strike) {
                for (line.attrs_list.spans.items) |*s| {
                    has_underline = has_underline or s.attrs.text_decoration.underline != .none;
                    has_strike = has_strike or s.attrs.text_decoration.strikethrough;
                }
            }
            const run_w: i32 = floatToI32Saturating(
                @as(f32, @floatFromInt(unicode.countGraphemes(text))) * self.glyph_advance,
            );
            if (has_underline) {
                renderer.rectangle(0, line_top + @as(i32, @intCast(lh)) - 2, @intCast(@max(run_w, 0)), 1, text_color);
            }
            if (has_strike) {
                renderer.rectangle(0, line_top + @divTrunc(@as(i32, @intCast(lh)), 2), @intCast(@max(run_w, 0)), 1, text_color);
            }
        }
    }
};

/// Ordered selection bounds.
pub const SelectionBounds = struct {
    start: Cursor,
    end: Cursor,
};

/// Highlighted span on the interim monospace grid.
pub const Highlight = struct {
    x: f32,
    width: f32,
};

pub const MotionResult = struct {
    cursor: Cursor,
    x_opt: ?i32,
};

pub const CursorPosition = struct {
    x: f32,
    y: f32,
};

/// Per-grapheme selection spans for one line (mirrors `LayoutRun.highlight`).
pub fn highlightRun(
    allocator: Allocator,
    text: []const u8,
    line_i: usize,
    cursor_start: Cursor,
    cursor_end: Cursor,
    advance: f32,
) Allocator.Error!std.ArrayList(Highlight) {
    var out: std.ArrayList(Highlight) = .empty;
    errdefer out.deinit(allocator);

    // Collect cluster starts so each cluster's byte range is known.
    var starts: std.ArrayList(usize) = .empty;
    defer starts.deinit(allocator);
    var git = unicode.graphemeIndices(text);
    while (git.next()) |s| try starts.append(allocator, s);

    var range_opt: ?Highlight = null;
    for (starts.items, 0..) |c_start, gi| {
        const c_end = if (gi + 1 < starts.items.len) starts.items[gi + 1] else text.len;
        const c_x = @as(f32, @floatFromInt(gi)) * advance;
        const selected = (cursor_start.line != line_i or c_end > cursor_start.index) and
            (cursor_end.line != line_i or c_start < cursor_end.index);
        if (selected) {
            if (range_opt) |r| {
                range_opt = .{ .x = @min(r.x, c_x), .width = @max(r.x + r.width, c_x + advance) - @min(r.x, c_x) };
            } else {
                range_opt = .{ .x = c_x, .width = advance };
            }
        } else if (range_opt) |r| {
            range_opt = null;
            if (r.width > 0) try out.append(allocator, r);
        }
    }
    if (range_opt) |r| {
        if (r.width > 0) try out.append(allocator, r);
    }
    return out;
}

// ---------------------------------------------------------------------------
// Cursor motions (grapheme- and word-correct)
// ---------------------------------------------------------------------------

/// Simplified text motions on the buffer's lines. Visual/RTL-sensitive
/// motions (Up/Down with glyph columns, Left/Right mirroring, Page by pixels)
/// are approximated until the layout port is consumed here.
/// TODO(layout): delegate to `Buffer.cursorMotion`.
pub fn motionCursor(
    lines: []const BufferLine,
    cursor: Cursor,
    cursor_x_opt: ?i32,
    line_height: f32,
    motion: Motion,
) ?MotionResult {
    var cur = cursor;
    var x_opt = cursor_x_opt;
    switch (motion) {
        .layout_cursor => |lc| {
            if (lines.len == 0) return null;
            cur.line = @min(lc.line, lines.len - 1);
            const text = lines[cur.line].textSlice();
            cur.index = @min(lc.glyph, text.len);
            if (!unicode.isGraphemeBoundary(text, cur.index)) {
                cur.index = unicode.prevGraphemeStart(text, cur.index);
            }
            cur.affinity = .after;
        },
        .previous => {
            if (cur.line >= lines.len) return null;
            const text = lines[cur.line].textSlice();
            if (cur.index > 0) {
                // Whole grapheme cluster before the cursor.
                cur.index = unicode.prevGraphemeStart(text, cur.index);
                cur.affinity = .after;
            } else if (cur.line > 0) {
                cur.line -= 1;
                cur.index = lines[cur.line].textSlice().len;
                cur.affinity = .after;
            }
            x_opt = null;
        },
        .next => {
            if (cur.line >= lines.len) return null;
            const text = lines[cur.line].textSlice();
            if (cur.index < text.len) {
                // Whole grapheme cluster at the cursor.
                cur.index = unicode.nextGraphemeEnd(text, cur.index);
                cur.affinity = .before;
            } else if (cur.line + 1 < lines.len) {
                cur.line += 1;
                cur.index = 0;
                cur.affinity = .before;
            }
            x_opt = null;
        },
        .left => {
            if (cur.line >= lines.len) return null;
            return motionCursor(lines, cur, x_opt, line_height, .previous);
        },
        .right => {
            if (cur.line >= lines.len) return null;
            return motionCursor(lines, cur, x_opt, line_height, .next);
        },
        .up => {
            if (cur.line >= lines.len) return null;
            if (x_opt == null) x_opt = @intCast(@min(cur.index, std.math.maxInt(i32)));
            if (cur.line > 0) {
                cur.line -= 1;
                const text = lines[cur.line].textSlice();
                cur.index = @min(@as(usize, @intCast(@max(x_opt.?, 0))), text.len);
                if (!unicode.isGraphemeBoundary(text, cur.index)) {
                    cur.index = unicode.prevGraphemeStart(text, cur.index);
                }
            }
        },
        .down => {
            if (cur.line >= lines.len) return null;
            if (x_opt == null) x_opt = @intCast(@min(cur.index, std.math.maxInt(i32)));
            if (cur.line + 1 < lines.len) {
                cur.line += 1;
                const text = lines[cur.line].textSlice();
                cur.index = @min(@as(usize, @intCast(@max(x_opt.?, 0))), text.len);
                if (!unicode.isGraphemeBoundary(text, cur.index)) {
                    cur.index = unicode.prevGraphemeStart(text, cur.index);
                }
            }
        },
        .home, .paragraph_start => {
            cur.index = 0;
            x_opt = null;
        },
        .soft_home => {
            if (cur.line >= lines.len) return null;
            cur.index = firstNonWhitespace(lines[cur.line].textSlice());
            x_opt = null;
        },
        .end, .paragraph_end => {
            if (cur.line >= lines.len) return null;
            cur.index = lines[cur.line].textSlice().len;
            x_opt = null;
        },
        .page_up => {
            if (cur.line >= lines.len) return null;
            if (x_opt == null) x_opt = @intCast(@min(cur.index, std.math.maxInt(i32)));
            const want: usize = @intCast(@max(x_opt.?, 0));
            cur.line -|= @min(cur.line, 10);
            cur.index = @min(want, lines[cur.line].textSlice().len);
        },
        .page_down => {
            if (cur.line >= lines.len) return null;
            if (x_opt == null) x_opt = @intCast(@min(cur.index, std.math.maxInt(i32)));
            const want: usize = @intCast(@max(x_opt.?, 0));
            cur.line = @min(cur.line + 10, lines.len - 1);
            cur.index = @min(want, lines[cur.line].textSlice().len);
        },
        .vertical => |px| {
            const count = @divTrunc(px, floatToI32Saturating(line_height));
            if (count < 0) {
                var k: i32 = 0;
                while (k > count) : (k -= 1) {
                    const r = motionCursor(lines, cur, x_opt, line_height, .up) orelse return null;
                    cur = r.cursor;
                    x_opt = r.x_opt;
                }
            } else {
                var k: i32 = 0;
                while (k < count) : (k += 1) {
                    const r = motionCursor(lines, cur, x_opt, line_height, .down) orelse return null;
                    cur = r.cursor;
                    x_opt = r.x_opt;
                }
            }
        },
        .previous_word => {
            if (cur.line >= lines.len) return null;
            const text = lines[cur.line].textSlice();
            if (cur.index > 0) {
                cur.index = prevWordStart(text, cur.index);
            } else if (cur.line > 0) {
                cur.line -= 1;
                cur.index = lines[cur.line].textSlice().len;
            }
            x_opt = null;
        },
        .next_word => {
            if (cur.line >= lines.len) return null;
            const text = lines[cur.line].textSlice();
            if (cur.index < text.len) {
                cur.index = nextWordEnd(text, cur.index);
            } else if (cur.line + 1 < lines.len) {
                cur.line += 1;
                cur.index = 0;
            }
            x_opt = null;
        },
        .left_word => {
            if (cur.line >= lines.len) return null;
            return motionCursor(lines, cur, x_opt, line_height, .previous_word);
        },
        .right_word => {
            if (cur.line >= lines.len) return null;
            return motionCursor(lines, cur, x_opt, line_height, .next_word);
        },
        .buffer_start => {
            cur.line = 0;
            cur.index = 0;
            x_opt = null;
        },
        .buffer_end => {
            if (lines.len == 0) return null;
            cur.line = lines.len - 1;
            cur.index = lines[cur.line].textSlice().len;
            x_opt = null;
        },
        .goto_line => |goal| {
            if (lines.len == 0) return null;
            cur.line = @min(goal, lines.len - 1);
            cur.index = @min(cur.index, lines[cur.line].textSlice().len);
        },
    }
    return MotionResult{ .cursor = cur, .x_opt = x_opt };
}

/// Interim grapheme-aware hit test over `lines` (monospace grid).
pub fn hitLines(
    lines: []const BufferLine,
    x: f32,
    y: f32,
    line_height: f32,
    advance: f32,
) ?Cursor {
    if (lines.len == 0) return null;
    if (!std.math.isFinite(y) or !std.math.isFinite(line_height) or line_height <= 0) {
        return null;
    }
    const f = @floor(y / line_height);
    if (!std.math.isFinite(f)) return null;
    if (f < 0) return Cursor.new(0, 0);
    if (f >= @as(f32, @floatFromInt(lines.len))) {
        // Below the last line: logical end of the last line.
        const last = lines.len - 1;
        return Cursor.newWithAffinity(last, lines[last].textSlice().len, .before);
    }
    const line_i: usize = @intFromFloat(f);
    const text = lines[line_i].textSlice();
    var cx: f32 = 0;
    var it = unicode.graphemeIndices(text);
    while (it.next()) |c_start| {
        // `GraphemeIndices.pos` is the end of the cluster just yielded.
        const c_end = it.pos;
        if (x >= cx and x <= cx + advance) {
            const right_half = x >= cx + advance / 2.0;
            if (right_half) {
                return Cursor.newWithAffinity(line_i, c_end, .before);
            }
            return Cursor.newWithAffinity(line_i, c_start, .after);
        }
        cx += advance;
    }
    return Cursor.newWithAffinity(line_i, text.len, .before);
}

/// Interim grapheme-aware cursor position over `lines` (monospace grid).
pub fn cursorPositionLines(
    lines: []const BufferLine,
    cursor: *const Cursor,
    line_height: f32,
    advance: f32,
) ?CursorPosition {
    if (cursor.line >= lines.len) return null;
    const text = lines[cursor.line].textSlice();
    const clamped = @min(cursor.index, text.len);
    var n: usize = 0;
    var it = unicode.graphemeIndices(text);
    while (it.next()) |s| {
        if (s >= clamped) break;
        n += 1;
    }
    return .{
        .x = @as(f32, @floatFromInt(n)) * advance,
        .y = @as(f32, @floatFromInt(cursor.line)) * line_height,
    };
}

// ---------------------------------------------------------------------------
// UTF-8 / word / whitespace helpers (canonical UAX #29 via `unicode.zig`)
// ---------------------------------------------------------------------------

pub fn isControl(cp: u21) bool {
    return (cp < 0x20 or (cp >= 0x7F and cp <= 0x9F));
}

/// Word-character approximation used to decide whether a UAX #29 word
/// segment is a "word" for `previous_word`/`next_word` (mirrors the
/// `unicode-segmentation` `is_word` rule: at least one alphanumeric).
fn isWordChar(cp: u21) bool {
    if (cp < 0x80) {
        return (cp >= 'A' and cp <= 'Z') or (cp >= 'a' and cp <= 'z') or
            (cp >= '0' and cp <= '9') or cp == '_';
    }
    return true;
}

fn wordSegmentIsWord(text: []const u8, r: unicode.WordRange) bool {
    var it = unicode.codepointIterator(text[r.start..r.end]);
    while (it.next()) |cp| {
        if (isWordChar(cp.value)) return true;
    }
    return false;
}

/// Start of the previous UAX #29 word before `index` (0 when none).
pub fn prevWordStart(text: []const u8, index: usize) usize {
    var found: usize = 0;
    var it = unicode.wordBounds(text);
    while (it.next()) |r| {
        if (r.start >= index) break;
        if (wordSegmentIsWord(text, r)) found = r.start;
    }
    return found;
}

/// End of the next UAX #29 word after `index` (`text.len` when none).
pub fn nextWordEnd(text: []const u8, index: usize) usize {
    var it = unicode.wordBounds(text);
    while (it.next()) |r| {
        if (!wordSegmentIsWord(text, r)) continue;
        if (r.end > index) return r.end;
    }
    return text.len;
}

pub fn firstNonWhitespace(text: []const u8) usize {
    // Codepoint loop so multi-byte spaces (NBSP, EM SPACE, …) count.
    // Empty or all-whitespace lines return 0 (`unwrap_or(0)` in the oracle).
    var it = unicode.codepointIterator(text);
    while (it.next()) |cp| {
        if (!unicode.isWhitespace(cp.value)) return it.pos - cp.len;
    }
    return 0;
}

/// Number of trailing whitespace codepoints at the end of `text[0..end]`,
/// or null when the whole prefix is whitespace (or empty). Mirrors
/// `text.chars().rev().position(|c| !c.is_whitespace())`.
fn trailingWhitespaceCodepoints(text: []const u8, end: usize) ?usize {
    const limit = @min(end, text.len);
    var count: usize = 0;
    var saw_non_ws = false;
    var it = unicode.codepointIterator(text[0..limit]);
    while (it.next()) |cp| {
        if (unicode.isWhitespace(cp.value)) {
            count += 1;
        } else {
            count = 0;
            saw_non_ws = true;
        }
    }
    return if (saw_non_ws) count else null;
}

fn isRtlCp(cp: u21) bool {
    return (cp >= 0x0590 and cp <= 0x08FF) or
        (cp >= 0xFB1D and cp <= 0xFDFF) or
        (cp >= 0xFE70 and cp <= 0xFEFF);
}

pub fn detectRtlLine(text: []const u8) bool {
    var it = unicode.codepointIterator(text);
    while (it.next()) |cp| {
        if (isRtlCp(cp.value)) return true;
        if ((cp.value >= 'A' and cp.value <= 'Z') or (cp.value >= 'a' and cp.value <= 'z')) {
            return false;
        }
    }
    return false;
}

fn floatToI32Saturating(v: f32) i32 {
    if (std.math.isNan(v)) return 0;
    const trunc = @trunc(v);
    const max: f32 = @floatFromInt(std.math.maxInt(i32));
    const min: f32 = @floatFromInt(std.math.minInt(i32));
    return @intFromFloat(std.math.clamp(trunc, min, max));
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

fn testColor(value: u32) Color {
    return .{ .value = value };
}

const TestRenderer = struct {
    rects: std.ArrayList([5]i64),

    pub fn renderer(self: *TestRenderer) Renderer {
        return .{ .ptr = self, .rectangleFn = rect };
    }

    fn rect(ptr: *anyopaque, x: i32, y: i32, w: u32, h: u32, color: Color) void {
        const self: *TestRenderer = @ptrCast(@alignCast(ptr));
        self.rects.append(std.testing.allocator, .{ x, y, w, h, color.value }) catch {};
    }
};

/// Real font fixture: the shared TTF corpus lives in `tests/fonts` next to
/// `src/`. `@src().file` is only the basename in this Zig version, so probe
/// the common working directories (`zig test src/edit.zig` runs from the
/// package root; `zig build test` also resolves `tests/fonts`).
const FONT_FIXTURE_PATHS = [_][]const u8{
    "tests/fonts/Inter-Regular.ttf",
    "../tests/fonts/Inter-Regular.ttf",
    "src/../tests/fonts/Inter-Regular.ttf",
};

/// Read the first loadable font fixture; fails (never skips) when the
/// checked-in corpus is missing.
fn readFontFixture(allocator: Allocator) ![]u8 {
    var last_err: anyerror = error.FileNotFound;
    for (FONT_FIXTURE_PATHS) |path| {
        if (std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, allocator, .limited(1 << 24))) |bytes| {
            return bytes;
        } else |e| {
            last_err = e;
        }
    }
    return last_err;
}

test "insert and delete round-trip with endings" {
    const alloc = std.testing.allocator;
    var ed = try Editor.init(alloc);
    defer ed.deinit();

    ed.startChange();
    const end = try ed.insertAt(Cursor.new(0, 0), "LF\nCRLF\r\nCR\rLFCR\n\rNONE", null);
    var ch0 = ed.finishChange().?;
    defer ch0.deinit(alloc);
    var t = try ed.fullText();
    defer t.deinit(alloc);
    try std.testing.expectEqualStrings("LF\nCRLF\r\nCR\rLFCR\n\rNONE", t.items);

    // Undo text round-trips through applyChange(reverse).
    ed.startChange();
    try ed.deleteRange(Cursor.new(0, 0), end);
    var ch = ed.finishChange().?;
    defer ch.deinit(alloc);
    var t2 = try ed.fullText();
    defer t2.deinit(alloc);
    try std.testing.expectEqualStrings("", t2.items);

    ch.reverse();
    try std.testing.expect(try ed.applyChange(&ch));
    var t3 = try ed.fullText();
    defer t3.deinit(alloc);
    try std.testing.expectEqualStrings("LF\nCRLF\r\nCR\rLFCR\n\rNONE", t3.items);
}

test "delete_range joins lines preserving endings" {
    const alloc = std.testing.allocator;
    var ed = try Editor.init(alloc);
    defer ed.deinit();
    _ = try ed.insertAt(Cursor.new(0, 0), "hello\nworld\n", null);
    // Lines: "hello"(lf) "world"(lf) ""(none).
    try std.testing.expect(ed.buffer().lines.items.len == 3);
    ed.startChange();
    try ed.deleteRange(Cursor.new(0, 2), Cursor.new(1, 3));
    var ch = ed.finishChange().?;
    defer ch.deinit(alloc);
    // "he" + "ld" joined; undo text is "llo\nwor".
    var t = try ed.fullText();
    defer t.deinit(alloc);
    try std.testing.expectEqualStrings("held\n", t.items);
    try std.testing.expect(ch.items.items.len == 1);
    try std.testing.expectEqualStrings("llo\nwor", ch.items.items[0].text.items);
    try std.testing.expect(!ch.items.items[0].insert);
}

test "insert_at splits lines and lands cursor" {
    const alloc = std.testing.allocator;
    var ed = try Editor.init(alloc);
    defer ed.deinit();
    _ = try ed.insertAt(Cursor.new(0, 0), "ab", null);
    const cur = try ed.insertAt(Cursor.new(0, 1), "X\nY", null);
    try std.testing.expect(cur.line == 1 and cur.index == 1);
    var t = try ed.fullText();
    defer t.deinit(alloc);
    try std.testing.expectEqualStrings("aX\nYb", t.items);
    // Trailing newline creates an empty final line.
    _ = try ed.insertAt(Cursor.new(1, 2), "\n", null);
    try std.testing.expect(ed.buffer().lines.items.len == 3);
}

test "selection bounds normal/line/word" {
    const alloc = std.testing.allocator;
    var ed = try Editor.init(alloc);
    defer ed.deinit();
    _ = try ed.insertAt(Cursor.new(0, 0), "hello world\nsecond line", null);

    ed.cursor = Cursor.new(0, 8);
    ed.selection = .{ .normal = Cursor.new(0, 2) };
    const n = ed.selectionBounds().?;
    try std.testing.expect(n.start.index == 2 and n.end.index == 8);

    // Reversed anchor order normalizes.
    ed.selection = .{ .normal = Cursor.new(1, 4) };
    ed.cursor = Cursor.new(0, 1);
    const n2 = ed.selectionBounds().?;
    try std.testing.expect(n2.start.line == 0 and n2.end.line == 1);

    // Line mode spans whole lines.
    ed.selection = .{ .line = Cursor.new(1, 2) };
    ed.cursor = Cursor.new(0, 0);
    const l = ed.selectionBounds().?;
    try std.testing.expect(l.start.line == 0 and l.start.index == 0);
    try std.testing.expect(l.end.line == 1 and l.end.index == 11);

    // Word mode expands to UAX #29 word boundaries ("world" is 6..11).
    ed.selection = .{ .word = Cursor.new(0, 0) };
    ed.cursor = Cursor.new(0, 8);
    const w = ed.selectionBounds().?;
    try std.testing.expect(w.start.index == 0 and w.end.index == 11);

    ed.selection = .{ .none = {} };
    try std.testing.expect(ed.selectionBounds() == null);
}

test "word motions use UAX #29 word bounds across punctuation" {
    const s = "hello, world";
    try std.testing.expect(prevWordStart(s, s.len) == 7);
    try std.testing.expect(nextWordEnd(s, 5) == 12);
    try std.testing.expect(nextWordEnd(s, 0) == 5);
    try std.testing.expect(prevWordStart(s, 3) == 0);
    // Word selection bounds split on the comma, not the alnum run only.
    const alloc = std.testing.allocator;
    var ed = try Editor.init(alloc);
    defer ed.deinit();
    _ = try ed.insertAt(Cursor.new(0, 0), s, null);
    ed.selection = .{ .word = Cursor.new(0, 8) };
    ed.cursor = Cursor.new(0, 8);
    const b = ed.selectionBounds().?;
    try std.testing.expect(b.start.index == 7 and b.end.index == 12);
}

test "copy and delete selection" {
    const alloc = std.testing.allocator;
    var ed = try Editor.init(alloc);
    defer ed.deinit();
    _ = try ed.insertAt(Cursor.new(0, 0), "foo\nbar\nbaz", null);
    ed.cursor = Cursor.new(1, 1);
    ed.selection = .{ .normal = Cursor.new(0, 1) };
    var copied = (try ed.copySelection()).?;
    defer copied.deinit(alloc);
    try std.testing.expectEqualStrings("oo\nb", copied.items);
    try std.testing.expect(try ed.deleteSelection());
    var t = try ed.fullText();
    defer t.deinit(alloc);
    try std.testing.expectEqualStrings("far\nbaz", t.items);
    try std.testing.expect(ed.cursor.line == 0 and ed.cursor.index == 1);
    try std.testing.expect(!try ed.deleteSelection());
}

test "action insert/enter/backspace/delete" {
    const alloc = std.testing.allocator;
    var fsys = try FontSystem.init(alloc);
    defer fsys.deinit();
    var ed = try Editor.init(alloc);
    defer ed.deinit();

    // Control characters are filtered (except tab/newline).
    try ed.action(&fsys, .{ .insert = 0x01 });
    var t0 = try ed.fullText();
    defer t0.deinit(alloc);
    try std.testing.expectEqualStrings("", t0.items);

    try ed.action(&fsys, .{ .insert = 'a' });
    try ed.action(&fsys, .{ .insert = 'b' });
    // '\n' routes to Enter.
    try ed.action(&fsys, .{ .insert = '\n' });
    try ed.action(&fsys, .{ .insert = 'c' });
    var t = try ed.fullText();
    defer t.deinit(alloc);
    try std.testing.expectEqualStrings("ab\nc", t.items);

    // Backspace joins lines at column 0.
    try ed.action(&fsys, .{ .motion = .home });
    try ed.action(&fsys, .backspace);
    var t2 = try ed.fullText();
    defer t2.deinit(alloc);
    try std.testing.expectEqualStrings("abc", t2.items);

    // Delete removes the grapheme under the cursor.
    try ed.action(&fsys, .{ .motion = .home });
    try ed.action(&fsys, .delete);
    var t3 = try ed.fullText();
    defer t3.deinit(alloc);
    try std.testing.expectEqualStrings("bc", t3.items);
}

test "regression: delete at start removes e + combining acute" {
    const alloc = std.testing.allocator;
    var fsys = try FontSystem.init(alloc);
    defer fsys.deinit();
    var ed = try Editor.init(alloc);
    defer ed.deinit();

    // Type "e" + U+0301 (combining acute) = one grapheme cluster.
    try ed.action(&fsys, .{ .insert = 'e' });
    try ed.action(&fsys, .{ .insert = 0x0301 });
    var typed = try ed.fullText();
    defer typed.deinit(alloc);
    try std.testing.expectEqualStrings("e\xcc\x81", typed.items);
    try std.testing.expect(ed.cursor.index == 3);

    try ed.action(&fsys, .{ .motion = .home });
    try std.testing.expect(ed.cursor.index == 0);
    try ed.action(&fsys, .delete);

    var t = try ed.fullText();
    defer t.deinit(alloc);
    // Both codepoints of the cluster are gone (pre-fix left U+0301 behind).
    try std.testing.expectEqualStrings("", t.items);
}

test "regression: backspace removes the whole trailing grapheme cluster" {
    const alloc = std.testing.allocator;
    var fsys = try FontSystem.init(alloc);
    defer fsys.deinit();
    var ed = try Editor.init(alloc);
    defer ed.deinit();
    try ed.action(&fsys, .{ .insert = 'e' });
    try ed.action(&fsys, .{ .insert = 0x0301 });
    try ed.action(&fsys, .backspace);
    var t = try ed.fullText();
    defer t.deinit(alloc);
    try std.testing.expectEqualStrings("", t.items);
}

test "regression: previous/next motions and hit stay on grapheme boundaries" {
    const alloc = std.testing.allocator;
    var fsys = try FontSystem.init(alloc);
    defer fsys.deinit();
    var ed = try Editor.init(alloc);
    defer ed.deinit();
    try ed.action(&fsys, .{ .insert = 'e' });
    try ed.action(&fsys, .{ .insert = 0x0301 });
    try std.testing.expect(ed.cursor.index == 3);

    // Previous steps the whole cluster, Next steps it back.
    try ed.action(&fsys, .{ .motion = .previous });
    try std.testing.expect(ed.cursor.index == 0);
    try ed.action(&fsys, .{ .motion = .next });
    try std.testing.expect(ed.cursor.index == 3);

    // Hit testing never lands inside the cluster: left half -> 0,
    // right half -> 3 (never 1 or 2).
    const left = ed.hit(2, 5).?;
    try std.testing.expect(left.index == 0);
    const right = ed.hit(8, 5).?;
    try std.testing.expect(right.index == 3);
}

test "action enter respects auto-indent" {
    const alloc = std.testing.allocator;
    var fsys = try FontSystem.init(alloc);
    defer fsys.deinit();
    var ed = try Editor.init(alloc);
    defer ed.deinit();
    ed.setAutoIndent(true);
    try ed.insertString("    code", null);
    try ed.action(&fsys, .{ .motion = .end });
    try ed.action(&fsys, .enter);
    var t = try ed.fullText();
    defer t.deinit(alloc);
    try std.testing.expectEqualStrings("    code\n    ", t.items);
}

test "action edge: backspace rejoins lines and delete splits them" {
    const alloc = std.testing.allocator;
    var fsys = try FontSystem.init(alloc);
    defer fsys.deinit();
    var ed = try Editor.init(alloc);
    defer ed.deinit();
    try ed.insertString("ab\ncd", null);
    try ed.action(&fsys, .{ .motion = .buffer_start });
    try ed.action(&fsys, .delete);
    var t = try ed.fullText();
    defer t.deinit(alloc);
    try std.testing.expectEqualStrings("b\ncd", t.items);
    try ed.action(&fsys, .{ .motion = .buffer_end });
    try ed.action(&fsys, .backspace);
    ed.selection = .{ .none = {} };
    var t2 = try ed.fullText();
    defer t2.deinit(alloc);
    try std.testing.expectEqualStrings("b\nc", t2.items);
}

test "action indent and unindent" {
    const alloc = std.testing.allocator;
    var fsys = try FontSystem.init(alloc);
    defer fsys.deinit();
    var ed = try Editor.init(alloc);
    defer ed.deinit();
    try ed.insertString("x", null);
    // No selection: indent to the next multiple of tab width (8). The
    // cursor sits after 'x', so 8 spaces land there and it moves past them.
    try ed.action(&fsys, .indent);
    var t = try ed.fullText();
    defer t.deinit(alloc);
    try std.testing.expectEqualStrings("x        ", t.items);
    try std.testing.expect(ed.cursor.index == 9);
    // Unindent with no leading whitespace is a no-op (trailing spaces are
    // not leading whitespace).
    try ed.action(&fsys, .unindent);
    var t2 = try ed.fullText();
    defer t2.deinit(alloc);
    try std.testing.expectEqualStrings("x        ", t2.items);

    // Leading whitespace unindents by one tab stop.
    var ed2 = try Editor.init(alloc);
    defer ed2.deinit();
    try ed2.insertString("    x", null);
    try ed2.action(&fsys, .unindent);
    var t2b = try ed2.fullText();
    defer t2b.deinit(alloc);
    try std.testing.expectEqualStrings("x", t2b.items);
    try std.testing.expect(ed2.cursor.index == 1);

    // Multi-line selection indents every line.
    try ed.insertString("\ny", null);
    ed.cursor = Cursor.new(1, 1);
    ed.selection = .{ .line = Cursor.new(0, 0) };
    try ed.action(&fsys, .indent);
    var t3 = try ed.fullText();
    defer t3.deinit(alloc);
    try std.testing.expectEqualStrings("        x        \n        y", t3.items);
}

test "action click drag selection and escape" {
    const alloc = std.testing.allocator;
    var fsys = try FontSystem.init(alloc);
    defer fsys.deinit();
    var ed = try Editor.init(alloc);
    defer ed.deinit();
    try ed.insertString("hello", null);

    try ed.action(&fsys, .{ .click = .{ .x = 2, .y = 5 } });
    try std.testing.expect(ed.cursor.index == 0);
    try ed.action(&fsys, .{ .drag = .{ .x = 45, .y = 5 } });
    try std.testing.expect(ed.selection != .none);
    const b = ed.selectionBounds().?;
    try std.testing.expect(b.start.index == 0 and b.end.index == 5);

    try ed.action(&fsys, .escape);
    try std.testing.expect(ed.selection == .none);

    try ed.action(&fsys, .{ .double_click = .{ .x = 15, .y = 5 } });
    try std.testing.expect(ed.selection == .word);
    try ed.action(&fsys, .{ .triple_click = .{ .x = 15, .y = 5 } });
    try std.testing.expect(ed.selection == .line);
}

test "change tracking start/finish/apply" {
    const alloc = std.testing.allocator;
    var ed = try Editor.init(alloc);
    defer ed.deinit();
    try std.testing.expect(ed.finishChange() == null);
    ed.startChange();
    _ = try ed.insertAt(Cursor.new(0, 0), "ab", null);
    var ch = ed.finishChange().?;
    defer ch.deinit(alloc);
    try std.testing.expect(ch.items.items.len == 1);
    try std.testing.expect(ch.items.items[0].insert);

    // Applying while a change is open is refused.
    ed.startChange();
    _ = try ed.insertAt(Cursor.new(0, 2), "z", null);
    try std.testing.expect(!try ed.applyChange(&ch));
    var open = ed.finishChange().?;
    defer open.deinit(alloc);

    ch.reverse();
    try std.testing.expect(try ed.applyChange(&ch));
    var t = try ed.fullText();
    defer t.deinit(alloc);
    try std.testing.expectEqualStrings("z", t.items);
}

test "shape_as_needed consumes cursor_moved" {
    const alloc = std.testing.allocator;
    var fsys = try FontSystem.init(alloc);
    defer fsys.deinit();
    var ed = try Editor.init(alloc);
    defer ed.deinit();
    try ed.insertString("hi", null);
    try std.testing.expect(ed.cursor_moved);
    try ed.shapeAsNeeded(&fsys, false);
    try std.testing.expect(!ed.cursor_moved);
    // Second call takes the scroll branch and stays clear.
    try ed.shapeAsNeeded(&fsys, true);
    try std.testing.expect(!ed.cursor_moved);
}

test "render highlights selection and cursor" {
    const alloc = std.testing.allocator;
    var ed = try Editor.init(alloc);
    defer ed.deinit();
    ed.bufferMut().width_opt = 200;
    try ed.insertString("ab\ncd", null);
    ed.cursor = Cursor.new(1, 1);
    ed.selection = .{ .normal = Cursor.new(0, 1) };
    var tr = TestRenderer{ .rects = .empty };
    defer tr.rects.deinit(alloc);
    ed.render(tr.renderer(), testColor(1), testColor(2), testColor(3), testColor(4));
    // Line 0: one highlight rect extended to the edge (not last line) +
    // cursor? (cursor is on line 1) + line 1: highlight + 1px cursor.
    // Just assert we got highlight + cursor rects with the right colors.
    var saw_selection = false;
    var saw_cursor = false;
    for (tr.rects.items) |r| {
        if (r[4] == 3) {
            saw_selection = true;
            // First line's rect reaches the buffer edge (width 200).
            if (r[1] == 0) try std.testing.expect(r[0] + r[2] == 200);
        }
        if (r[4] == 2) {
            saw_cursor = true;
            try std.testing.expect(r[2] == 1);
        }
    }
    try std.testing.expect(saw_selection and saw_cursor);
}

test "render empty interior line highlights full width" {
    const alloc = std.testing.allocator;
    var ed = try Editor.init(alloc);
    defer ed.deinit();
    ed.bufferMut().width_opt = 200;
    try ed.insertString("a\n\nb", null);
    ed.cursor = Cursor.new(2, 1);
    ed.selection = .{ .normal = Cursor.new(0, 0) };
    var tr = TestRenderer{ .rects = .empty };
    defer tr.rects.deinit(alloc);
    ed.render(tr.renderer(), testColor(1), testColor(2), testColor(3), testColor(4));
    var saw_full = false;
    for (tr.rects.items) |r| {
        // Middle empty line (line_top 20) gets a full-width selection rect.
        if (r[4] == 3 and r[1] == 20 and r[0] == 0 and r[2] == 200) saw_full = true;
    }
    try std.testing.expect(saw_full);
}

test "render decorations emit rects" {
    const alloc = std.testing.allocator;
    var ed = try Editor.init(alloc);
    defer ed.deinit();
    var default_attrs = Attrs.init(alloc);
    defer default_attrs.deinit();
    _ = default_attrs.with_underline(.single);
    const list = try AttrsList.init(alloc, &default_attrs);
    // insertAt takes ownership of the attrs list (mirrors Rust move).
    _ = try ed.insertAt(Cursor.new(0, 0), "ab", list);
    var tr = TestRenderer{ .rects = .empty };
    defer tr.rects.deinit(alloc);
    ed.render(tr.renderer(), testColor(9), testColor(2), testColor(3), testColor(4));
    var saw_deco = false;
    for (tr.rects.items) |r| {
        if (r[4] == 9) saw_deco = true;
    }
    try std.testing.expect(saw_deco);
}

test "hit rejects NaN/inf and saturates huge y" {
    const alloc = std.testing.allocator;
    var ed = try Editor.init(alloc);
    defer ed.deinit();
    _ = try ed.insertAt(Cursor.new(0, 0), "a\nb", null);
    try std.testing.expect(ed.hit(5, std.math.nan(f32)) == null);
    try std.testing.expect(ed.hit(5, std.math.inf(f32)) == null);
    try std.testing.expect(ed.hit(5, -std.math.inf(f32)) == null);
    // Huge finite y saturates to the last line instead of trapping.
    const huge = ed.hit(5, 1e30).?;
    try std.testing.expect(huge.line == ed.buffer().lines.items.len - 1);
    try std.testing.expect(huge.index == ed.buffer().lines.items[huge.line].textSlice().len);
    // Negative y clamps to the start of the buffer.
    const neg = ed.hit(5, -5).?;
    try std.testing.expect(neg.line == 0 and neg.index == 0);
    // Degenerate line height returns null instead of dividing by zero.
    ed.bufferMut().metrics.line_height = 0;
    try std.testing.expect(ed.hit(5, 5) == null);
    ed.bufferMut().metrics.line_height = 20;
    // Non-finite line height also returns null.
    ed.bufferMut().metrics.line_height = std.math.inf(f32);
    try std.testing.expect(ed.hit(5, 5) == null);
}

test "word motions handle more than 64 tokens" {
    const alloc = std.testing.allocator;
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(alloc);
    var i: usize = 0;
    while (i < 100) : (i += 1) {
        try text.appendSlice(alloc, "a ");
    }
    const s = text.items;
    // UAX #29 word starts are 0, 2, 4, …; ends 1, 3, 5, ….
    try std.testing.expect(nextWordEnd(s, 0) == 1);
    try std.testing.expect(prevWordStart(s, s.len) == 198);
    try std.testing.expect(prevWordStart(s, 100) == 98);
    try std.testing.expect(nextWordEnd(s, 100) == 101);
    try std.testing.expect(prevWordStart(s, 150) == 148);
    try std.testing.expect(nextWordEnd(s, 148) == 149);
}

test "firstNonWhitespace handles unicode spaces" {
    const s = " \t\xc2\xa0\xe2\x80\x83hi";
    try std.testing.expect(firstNonWhitespace(s) == 7);
    try std.testing.expect(firstNonWhitespace("") == 0);
    try std.testing.expect(firstNonWhitespace("   ") == 0);
    try std.testing.expect(unicode.isWhitespace(0xA0));
    try std.testing.expect(unicode.isWhitespace(0x2003));
    try std.testing.expect(!unicode.isWhitespace('a'));
}

test "empty line hit and cursor sit at horizontal zero" {
    const alloc = std.testing.allocator;
    var ed = try Editor.init(alloc);
    defer ed.deinit();
    try ed.insertString("a\n\nb", null);
    // Middle line is empty; hit maps to its start and the cursor sits at x=0.
    const hit = ed.hit(50, 30).?;
    try std.testing.expect(hit.line == 1 and hit.index == 0);
    ed.cursor = Cursor.new(1, 0);
    const pos = ed.cursorPosition().?;
    try std.testing.expect(pos.x == 0);
    try std.testing.expect(pos.y == 20);
}

test "edit with borrowed buffer leaves it intact on deinit" {
    const alloc = std.testing.allocator;
    var buf = try Buffer.initWithAllocator(alloc, .{ .font_size = 14, .line_height = 20 });
    defer buf.deinit();
    try buf.lines.append(alloc, BufferLine.empty(alloc));
    {
        var ed = Editor.initWithBuffer(alloc, &buf);
        try ed.insertString("borrowed", null);
        var t = try ed.fullText();
        defer t.deinit(alloc);
        try std.testing.expectEqualStrings("borrowed", t.items);
        ed.deinit();
    }
    try std.testing.expect(buf.lines.items.len == 1);
    try std.testing.expectEqualStrings("borrowed", buf.lines.items[0].textSlice());
}

test "e2e: type e+U+0301cole, Delete at 0 leaves \"cole\" (real font fixture)" {
    const alloc = std.testing.allocator;
    var fsys = try FontSystem.init(alloc);
    defer fsys.deinit();

    // Real font from the checked-in corpus (`../tests/fonts` from `src/`).
    const font_bytes = try readFontFixture(alloc);
    defer alloc.free(font_bytes);
    var real_font = try font_mod.Font.init(alloc, 0, font_bytes, false, null);
    defer real_font.deinit();
    try std.testing.expect(real_font.metrics().units_per_em > 0);

    // Register the face so the real buffer shaping path resolves it.
    _ = try fsys.dbMut().addFace(
        "tests/fonts/Inter-Regular.ttf",
        0,
        &.{"Inter"},
        "Inter-Regular",
        font_system.WEIGHT_NORMAL,
        .normal,
        .normal,
        false,
    );

    var ed = try Editor.init(alloc);
    defer ed.deinit();

    // Type "e" + U+0301 (combining acute) + "cole".
    try ed.action(&fsys, .{ .insert = 'e' });
    try ed.action(&fsys, .{ .insert = 0x0301 });
    try ed.action(&fsys, .{ .insert = 'c' });
    try ed.action(&fsys, .{ .insert = 'o' });
    try ed.action(&fsys, .{ .insert = 'l' });
    try ed.action(&fsys, .{ .insert = 'e' });

    // Shape through the real Buffer/FontSystem path (not the old no-op).
    try ed.shapeAsNeeded(&fsys, false);

    // Delete at index 0 must remove both codepoints of the cluster.
    try ed.action(&fsys, .{ .motion = .home });
    try ed.action(&fsys, .delete);

    var t = try ed.fullText();
    defer t.deinit(alloc);
    try std.testing.expectEqualStrings("cole", t.items);
}
