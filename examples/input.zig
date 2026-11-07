//! Port of GPUI's `examples/input.rs`: a single-line text input that implements the
//! platform text input protocol (`EntityInputHandler`), with selection, clipboard,
//! IME composition and a keystroke log.
//!
//! Differences from input.rs, caused by ZUI APIs that do not exist yet:
//! - `observe_keystrokes` is replaced by a capture-phase key listener on the root
//! - the keyboard layout name and its change observer are left out

const std = @import("std");
const gpui = @import("zui");

const App = gpui.App;
const Bounds = gpui.Bounds;
const ClipboardItem = gpui.ClipboardItem;
const Context = gpui.Context;
const CursorStyle = gpui.CursorStyle;
const Div = gpui.Div;
const ElementInputHandler = gpui.ElementInputHandler;
const Entity = gpui.Entity;
const FocusHandle = gpui.FocusHandle;
const GlobalElementId = gpui.GlobalElementId;
const Hsla = gpui.Hsla;
const KeyBinding = gpui.KeyBinding;
const KeyDownEvent = gpui.KeyDownEvent;
const Keystroke = gpui.Keystroke;
const LayoutId = gpui.LayoutId;
const MouseButton = gpui.MouseButton;
const MouseDownEvent = gpui.MouseDownEvent;
const MouseMoveEvent = gpui.MouseMoveEvent;
const MouseUpEvent = gpui.MouseUpEvent;
const PaintQuad = gpui.PaintQuad;
const Pixels = gpui.Pixels;
const Point = gpui.Point;
const ShapedLine = gpui.text_system.ShapedLine;
const Style = gpui.Style;
const TextRun = gpui.TextRun;
const UnderlineStyle = gpui.UnderlineStyle;
const Window = gpui.Window;
const WindowOptions = gpui.WindowOptions;
const black = gpui.black;
const blue = gpui.blue;
const div = gpui.div;
const fill = gpui.fill;
const format = gpui.format;
const hsla = gpui.hsla;
const opaque_grey = gpui.opaque_grey;
const point = gpui.point;
const px = gpui.px;
const relative = gpui.relative;
const rgb = gpui.rgb;
const rgba = gpui.rgba;
const size = gpui.size;
const white = gpui.white;
const yellow = gpui.yellow;

const Range = gpui.platform.Range;
const UTF16Selection = gpui.platform.UTF16Selection;

const Backspace = gpui.Action("text_input", "Backspace");
const Delete = gpui.Action("text_input", "Delete");
const Left = gpui.Action("text_input", "Left");
const Right = gpui.Action("text_input", "Right");
const SelectLeft = gpui.Action("text_input", "SelectLeft");
const SelectRight = gpui.Action("text_input", "SelectRight");
const SelectAll = gpui.Action("text_input", "SelectAll");
const Home = gpui.Action("text_input", "Home");
const End = gpui.Action("text_input", "End");
const ShowCharacterPalette = gpui.Action("text_input", "ShowCharacterPalette");
const Paste = gpui.Action("text_input", "Paste");
const Cut = gpui.Action("text_input", "Cut");
const Copy = gpui.Action("text_input", "Copy");
const Quit = gpui.Action("text_input", "Quit");

/// Heap storage for text and keystrokes that outlive a frame.
const gpa = std.heap.smp_allocator;

fn oom() noreturn {
    @panic("out of memory");
}

/// Number of bytes in the UTF-8 sequence starting with `byte`, clamped to the remaining input.
fn sequence_len(text: []const u8, index: usize) usize {
    const len = std.unicode.utf8ByteSequenceLength(text[index]) catch 1;
    return @min(len, text.len - index);
}

/// UTF-16 code units of one UTF-8 sequence: four-byte sequences are the supplementary planes.
fn utf16_units(sequence: []const u8) usize {
    return if (sequence.len == 4) 2 else 1;
}

const TextInput = struct {
    focus_handle: FocusHandle,
    content: []const u8,
    placeholder: []const u8,
    selected_range: Range,
    selection_reversed: bool,
    marked_range: ?Range,
    last_layout: ?ShapedLine,
    last_bounds: ?Bounds(Pixels),
    is_selecting: bool,

    fn left(self: *TextInput, _: *const Left, window: *Window, cx: *Context(TextInput)) void {
        if (self.selected_range.is_empty()) {
            self.move_to(self.previous_boundary(self.cursor_offset()), window, cx);
        } else {
            self.move_to(self.selected_range.start, window, cx);
        }
    }

    fn right(self: *TextInput, _: *const Right, window: *Window, cx: *Context(TextInput)) void {
        if (self.selected_range.is_empty()) {
            self.move_to(self.next_boundary(self.selected_range.end), window, cx);
        } else {
            self.move_to(self.selected_range.end, window, cx);
        }
    }

    fn select_left(self: *TextInput, _: *const SelectLeft, window: *Window, cx: *Context(TextInput)) void {
        self.select_to(self.previous_boundary(self.cursor_offset()), window, cx);
    }

    fn select_right(self: *TextInput, _: *const SelectRight, window: *Window, cx: *Context(TextInput)) void {
        self.select_to(self.next_boundary(self.cursor_offset()), window, cx);
    }

    fn select_all(self: *TextInput, _: *const SelectAll, window: *Window, cx: *Context(TextInput)) void {
        self.move_to(0, window, cx);
        self.select_to(self.content.len, window, cx);
    }

    fn home(self: *TextInput, _: *const Home, window: *Window, cx: *Context(TextInput)) void {
        self.move_to(0, window, cx);
    }

    fn end(self: *TextInput, _: *const End, window: *Window, cx: *Context(TextInput)) void {
        self.move_to(self.content.len, window, cx);
    }

    fn backspace(self: *TextInput, _: *const Backspace, window: *Window, cx: *Context(TextInput)) void {
        if (self.selected_range.is_empty()) {
            const prev = self.previous_boundary(self.cursor_offset());
            window.play_system_bell();
            if (self.cursor_offset() == prev) return;
            self.select_to(prev, window, cx);
        }
        self.replace_text_in_range(null, "", window, cx);
    }

    fn delete(self: *TextInput, _: *const Delete, window: *Window, cx: *Context(TextInput)) void {
        if (self.selected_range.is_empty()) {
            const next = self.next_boundary(self.cursor_offset());
            window.play_system_bell();
            if (self.cursor_offset() == next) return;
            self.select_to(next, window, cx);
        }
        self.replace_text_in_range(null, "", window, cx);
    }

    fn on_mouse_down(self: *TextInput, event: *const MouseDownEvent, window: *Window, cx: *Context(TextInput)) void {
        self.is_selecting = true;
        window.request_virtual_keyboard();
        if (event.modifiers.shift) {
            self.select_to(self.index_for_mouse_position(event.position), window, cx);
        } else {
            self.move_to(self.index_for_mouse_position(event.position), window, cx);
        }
    }

    fn on_mouse_up(self: *TextInput, _: *const MouseUpEvent, _: *Window, _: *Context(TextInput)) void {
        self.is_selecting = false;
    }

    fn on_mouse_move(self: *TextInput, event: *const MouseMoveEvent, window: *Window, cx: *Context(TextInput)) void {
        if (!self.is_selecting) return;
        self.select_to(self.index_for_mouse_position(event.position), window, cx);
    }

    fn show_character_palette(_: *TextInput, _: *const ShowCharacterPalette, window: *Window, _: *Context(TextInput)) void {
        window.show_character_palette();
    }

    fn paste(self: *TextInput, _: *const Paste, window: *Window, cx: *Context(TextInput)) void {
        const item = cx.read_from_clipboard() orelse return;
        const text = item.text() orelse return;
        const single_line = std.mem.replaceOwned(u8, gpa, text, "\n", " ") catch oom();
        defer gpa.free(single_line);
        self.replace_text_in_range(null, single_line, window, cx);
    }

    fn copy(self: *TextInput, _: *const Copy, _: *Window, cx: *Context(TextInput)) void {
        if (!self.selected_range.is_empty()) {
            cx.write_to_clipboard(ClipboardItem.new_string(self.content[self.selected_range.start..self.selected_range.end]));
        }
    }

    fn cut(self: *TextInput, _: *const Cut, window: *Window, cx: *Context(TextInput)) void {
        if (!self.selected_range.is_empty()) {
            cx.write_to_clipboard(ClipboardItem.new_string(self.content[self.selected_range.start..self.selected_range.end]));
            self.replace_text_in_range(null, "", window, cx);
        }
    }

    fn move_to(self: *TextInput, offset: usize, window: *Window, cx: *Context(TextInput)) void {
        self.selected_range = .{ .start = offset, .end = offset };
        self.selection_reversed = false;
        window.invalidate_character_coordinates();
        cx.notify();
    }

    fn cursor_offset(self: *const TextInput) usize {
        return if (self.selection_reversed) self.selected_range.start else self.selected_range.end;
    }

    fn index_for_mouse_position(self: *const TextInput, position: Point(Pixels)) usize {
        if (self.content.len == 0) return 0;
        const bounds = self.last_bounds orelse return 0;
        const line = self.last_layout orelse return 0;
        if (position.y < bounds.top()) return 0;
        if (position.y > bounds.bottom()) return self.content.len;
        return line.closest_index_for_x(position.x - bounds.left());
    }

    fn select_to(self: *TextInput, offset: usize, window: *Window, cx: *Context(TextInput)) void {
        if (self.selection_reversed) {
            self.selected_range.start = offset;
        } else {
            self.selected_range.end = offset;
        }
        if (self.selected_range.end < self.selected_range.start) {
            self.selection_reversed = !self.selection_reversed;
            std.mem.swap(usize, &self.selected_range.start, &self.selected_range.end);
        }
        window.invalidate_character_coordinates();
        cx.notify();
    }

    fn offset_from_utf16(self: *const TextInput, offset: usize) usize {
        var utf8_offset: usize = 0;
        var utf16_count: usize = 0;
        var index: usize = 0;
        while (index < self.content.len) {
            if (utf16_count >= offset) break;
            const len = sequence_len(self.content, index);
            utf16_count += utf16_units(self.content[index..][0..len]);
            utf8_offset += len;
            index += len;
        }
        return utf8_offset;
    }

    fn offset_to_utf16(self: *const TextInput, offset: usize) usize {
        var utf16_offset: usize = 0;
        var utf8_count: usize = 0;
        var index: usize = 0;
        while (index < self.content.len) {
            if (utf8_count >= offset) break;
            const len = sequence_len(self.content, index);
            utf8_count += len;
            utf16_offset += utf16_units(self.content[index..][0..len]);
            index += len;
        }
        return utf16_offset;
    }

    fn range_to_utf16(self: *const TextInput, range: Range) Range {
        return .{ .start = self.offset_to_utf16(range.start), .end = self.offset_to_utf16(range.end) };
    }

    fn range_from_utf16(self: *const TextInput, range_utf16: Range) Range {
        return .{ .start = self.offset_from_utf16(range_utf16.start), .end = self.offset_from_utf16(range_utf16.end) };
    }

    fn previous_boundary(self: *const TextInput, offset: usize) usize {
        var graphemes = gpui.unicode.graphemeIndices(self.content);
        var result: usize = 0;
        while (graphemes.next()) |index| {
            if (index >= offset) break;
            result = index;
        }
        return result;
    }

    fn next_boundary(self: *const TextInput, offset: usize) usize {
        var graphemes = gpui.unicode.graphemeIndices(self.content);
        while (graphemes.next()) |index| {
            if (index > offset) return index;
        }
        return self.content.len;
    }

    /// Replaces the content. The old text may still be referenced by `last_layout`, so the
    /// layout is dropped with it (GPUI keeps the text alive through reference counting).
    fn set_content(self: *TextInput, new_content: []u8) void {
        if (self.content.len > 0) gpa.free(@constCast(self.content));
        self.content = new_content;
        self.last_layout = null;
    }

    fn reset(self: *TextInput, window: *Window, cx: *Context(TextInput)) void {
        self.set_content(@constCast(""));
        self.selected_range = .{ .start = 0, .end = 0 };
        self.selection_reversed = false;
        self.marked_range = null;
        self.last_layout = null;
        self.last_bounds = null;
        self.is_selecting = false;
        window.invalidate_character_coordinates();
        cx.notify();
    }

    // -- EntityInputHandler ------------------------------------------------

    pub fn text_for_range(self: *TextInput, range_utf16: Range, actual_range: *?Range, _: *Window, _: *Context(TextInput)) ?[]const u8 {
        const range = self.range_from_utf16(range_utf16);
        actual_range.* = self.range_to_utf16(range);
        return self.content[range.start..range.end];
    }

    pub fn selected_text_range(self: *TextInput, _: bool, _: *Window, _: *Context(TextInput)) ?UTF16Selection {
        return .{ .range = self.range_to_utf16(self.selected_range), .reversed = self.selection_reversed };
    }

    pub fn set_selected_text_range(self: *TextInput, range_utf16: Range, window: *Window, cx: *Context(TextInput)) void {
        self.selected_range = self.range_from_utf16(range_utf16);
        self.selection_reversed = false;
        window.invalidate_character_coordinates();
        cx.notify();
    }

    pub fn text_length_utf16(self: *const TextInput, _: *Window, _: *Context(TextInput)) ?usize {
        var count: usize = 0;
        var index: usize = 0;
        while (index < self.content.len) {
            const len = sequence_len(self.content, index);
            count += utf16_units(self.content[index..][0..len]);
            index += len;
        }
        return count;
    }

    pub fn marked_text_range(self: *const TextInput, _: *Window, _: *Context(TextInput)) ?Range {
        const marked = self.marked_range orelse return null;
        return self.range_to_utf16(marked);
    }

    pub fn unmark_text(self: *TextInput, window: *Window, cx: *Context(TextInput)) void {
        self.marked_range = null;
        cx.notify();
        _ = window;
    }

    pub fn replace_text_in_range(self: *TextInput, range_utf16: ?Range, new_text: []const u8, window: *Window, cx: *Context(TextInput)) void {
        const range = if (range_utf16) |r| self.range_from_utf16(r) else self.marked_range orelse self.selected_range;

        const updated = std.mem.concat(gpa, u8, &.{ self.content[0..range.start], new_text, self.content[range.end..] }) catch oom();
        self.set_content(updated);
        const caret = range.start + new_text.len;
        self.selected_range = .{ .start = caret, .end = caret };
        self.selection_reversed = false;
        self.marked_range = null;
        cx.notify();
        _ = window;
    }

    pub fn replace_and_mark_text_in_range(self: *TextInput, range_utf16: ?Range, new_text: []const u8, new_selected_range_utf16: ?Range, window: *Window, cx: *Context(TextInput)) void {
        const range = if (range_utf16) |r| self.range_from_utf16(r) else self.marked_range orelse self.selected_range;

        const updated = std.mem.concat(gpa, u8, &.{ self.content[0..range.start], new_text, self.content[range.end..] }) catch oom();
        self.set_content(updated);
        self.marked_range = if (new_text.len > 0) .{ .start = range.start, .end = range.start + new_text.len } else null;

        const insertion_start_utf16 = self.offset_to_utf16(range.start);
        const inserted_length_utf16 = blk: {
            var count: usize = 0;
            var index: usize = 0;
            while (index < new_text.len) {
                const len = sequence_len(new_text, index);
                count += utf16_units(new_text[index..][0..len]);
                index += len;
            }
            break :blk count;
        };
        self.selected_range = if (new_selected_range_utf16) |selected| blk: {
            const start_utf16 = insertion_start_utf16 + @min(selected.start, inserted_length_utf16);
            const end_utf16 = insertion_start_utf16 + @min(selected.end, inserted_length_utf16);
            break :blk self.range_from_utf16(.{ .start = start_utf16, .end = end_utf16 });
        } else .{ .start = range.start + new_text.len, .end = range.start + new_text.len };
        self.selection_reversed = false;

        cx.notify();
        _ = window;
    }

    pub fn bounds_for_range(self: *TextInput, range_utf16: Range, element_bounds: Bounds(Pixels), _: *Window, _: *Context(TextInput)) ?Bounds(Pixels) {
        const last_layout = self.last_layout orelse return null;
        const range = self.range_from_utf16(range_utf16);
        return Bounds(Pixels).from_corners(
            point(element_bounds.left() + last_layout.x_for_index(range.start), element_bounds.top()),
            point(element_bounds.left() + last_layout.x_for_index(range.end), element_bounds.bottom()),
        );
    }

    pub fn character_index_for_point(self: *TextInput, position: Point(Pixels), _: *Window, _: *Context(TextInput)) ?usize {
        const bounds = self.last_bounds orelse return null;
        const line_point = bounds.localize(position) orelse return null;
        const last_layout = self.last_layout orelse return null;
        if (!std.mem.eql(u8, last_layout.text, self.content)) return null;
        const utf8_index = last_layout.closest_index_for_x(line_point.x);
        return self.offset_to_utf16(utf8_index);
    }

    pub fn render(self: *TextInput, _: *Window, cx: *Context(TextInput)) *Div {
        return div()
            .flex()
            .key_context("TextInput")
            .track_focus(&self.focus_handle)
            .cursor(CursorStyle.i_beam)
            .on_action(Backspace, cx.listener(TextInput.backspace))
            .on_action(Delete, cx.listener(TextInput.delete))
            .on_action(Left, cx.listener(TextInput.left))
            .on_action(Right, cx.listener(TextInput.right))
            .on_action(SelectLeft, cx.listener(TextInput.select_left))
            .on_action(SelectRight, cx.listener(TextInput.select_right))
            .on_action(SelectAll, cx.listener(TextInput.select_all))
            .on_action(Home, cx.listener(TextInput.home))
            .on_action(End, cx.listener(TextInput.end))
            .on_action(ShowCharacterPalette, cx.listener(TextInput.show_character_palette))
            .on_action(Paste, cx.listener(TextInput.paste))
            .on_action(Cut, cx.listener(TextInput.cut))
            .on_action(Copy, cx.listener(TextInput.copy))
            .on_mouse_down(.left, cx.listener(TextInput.on_mouse_down))
            .on_mouse_up(.left, cx.listener(TextInput.on_mouse_up))
            .on_mouse_up_out(.left, cx.listener(TextInput.on_mouse_up))
            .on_mouse_move(cx.listener(TextInput.on_mouse_move))
            .bg(rgb(0xeeeeee))
            .line_height(px(30.0))
            .text_size(px(24.0))
            .child(
                div()
                    .h(px(30.0 + 4.0 * 2.0))
                    .w_full()
                    .p(px(4.0))
                    .bg(white())
                    .child(TextElement{ .input = cx.entity() }),
            );
    }
};

const TextElement = struct {
    input: Entity(TextInput),

    pub const RequestLayoutState = void;
    pub const PrepaintState = struct {
        line: ShapedLine,
        cursor: ?PaintQuad,
        selection: ?PaintQuad,
    };

    pub fn request_layout(self: *TextElement, _: ?*const GlobalElementId, window: *Window, cx: *App) struct { LayoutId, void } {
        _ = self;
        var style: Style = .{};
        style.size.width = .{ .definite = relative(1.0) };
        style.size.height = .{ .definite = .{ .absolute = .{ .pixels = window.line_height() } } };
        return .{ window.request_layout(&style, &.{}, cx), {} };
    }

    pub fn prepaint(self: *TextElement, _: ?*const GlobalElementId, bounds: Bounds(Pixels), _: *void, window: *Window, cx: *App) PrepaintState {
        const input = self.input.read(cx);
        const content = input.content;
        const selected_range = input.selected_range;
        const cursor = input.cursor_offset();
        const style = window.text_style();

        const display_text, const text_color = if (content.len == 0)
            .{ input.placeholder, hsla(0.0, 0.0, 0.0, 0.2) }
        else
            .{ content, style.color };

        const run: TextRun = .{
            .len = display_text.len,
            .font = style.font(),
            .color = text_color,
            .background_color = null,
            .underline = null,
            .strikethrough = null,
        };
        const arena = gpui.window.frame_arena();
        const runs: []const TextRun = if (input.marked_range) |marked| blk: {
            const parts = [_]TextRun{
                .{ .len = marked.start, .font = run.font, .color = run.color, .background_color = null, .underline = null, .strikethrough = null },
                .{
                    .len = marked.end - marked.start,
                    .font = run.font,
                    .color = run.color,
                    .background_color = null,
                    .underline = UnderlineStyle{ .color = run.color, .thickness = px(1.0), .wavy = false },
                    .strikethrough = null,
                },
                .{ .len = display_text.len - marked.end, .font = run.font, .color = run.color, .background_color = null, .underline = null, .strikethrough = null },
            };
            var kept = arena.alloc(TextRun, parts.len) catch oom();
            var count: usize = 0;
            for (parts) |part| {
                if (part.len > 0) {
                    kept[count] = part;
                    count += 1;
                }
            }
            break :blk kept[0..count];
        } else arena.dupe(TextRun, &.{run}) catch oom();

        const font_size = style.font_size.to_pixels(window.rem_size());
        const line = window.text_system().shape_line(display_text, font_size, runs, null) catch |err|
            std.debug.panic("shape_line failed: {s}", .{@errorName(err)});

        const cursor_pos = line.x_for_index(cursor);
        var selection: ?PaintQuad = null;
        var cursor_quad: ?PaintQuad = null;
        if (selected_range.is_empty()) {
            cursor_quad = fill(.{
                .origin = point(bounds.left() + cursor_pos, bounds.top()),
                .size = size(px(2.0), bounds.bottom() - bounds.top()),
            }, blue());
        } else {
            selection = fill(Bounds(Pixels).from_corners(
                point(bounds.left() + line.x_for_index(selected_range.start), bounds.top()),
                point(bounds.left() + line.x_for_index(selected_range.end), bounds.bottom()),
            ), rgba(0x3311ff30));
        }
        return .{ .line = line, .cursor = cursor_quad, .selection = selection };
    }

    pub fn paint(self: *TextElement, _: ?*const GlobalElementId, bounds: Bounds(Pixels), _: *void, prepaint_state: *PrepaintState, window: *Window, cx: *App) void {
        const focus_handle = self.input.read(cx).focus_handle;
        window.handle_input(&focus_handle, ElementInputHandler(TextInput).new(bounds, self.input), cx);
        if (prepaint_state.selection) |selection| window.paint_quad(selection);
        prepaint_state.line.paint(bounds.origin, window.line_height(), .left, null, window, cx) catch |err|
            std.debug.panic("paint line failed: {s}", .{@errorName(err)});
        if (focus_handle.is_focused(window)) {
            if (prepaint_state.cursor) |cursor| window.paint_quad(cursor);
        }
        self.input.update(cx, store_layout, .{ prepaint_state.line, bounds });
    }

    fn store_layout(input: *TextInput, line: ShapedLine, bounds: Bounds(Pixels), _: *Context(TextInput)) void {
        input.last_layout = line;
        input.last_bounds = bounds;
    }
};

const InputExample = struct {
    text_input: Entity(TextInput),
    recent_keystrokes: std.ArrayList(Keystroke) = .empty,
    focus_handle: FocusHandle,

    fn clear_recent_keystrokes(self: *InputExample) void {
        for (self.recent_keystrokes.items) |keystroke| {
            if (keystroke.key.len > 0) gpa.free(@constCast(keystroke.key));
            if (keystroke.key_char) |key_char| {
                if (key_char.len > 0) gpa.free(@constCast(key_char));
            }
        }
        self.recent_keystrokes.clearRetainingCapacity();
    }

    /// Stands in for GPUI's `cx.observe_keystrokes`: a capture-phase listener on the root sees
    /// every key-down on the focus path before any handler can stop it. The strings are copied
    /// because the event's slices are only valid during dispatch.
    fn record_keystroke(self: *InputExample, event: *const KeyDownEvent, _: *Window, cx: *Context(InputExample)) void {
        const keystroke = event.keystroke;
        const owned: Keystroke = .{
            .modifiers = keystroke.modifiers,
            .key = gpa.dupe(u8, keystroke.key) catch oom(),
            .key_char = if (keystroke.key_char) |key_char| (gpa.dupe(u8, key_char) catch oom()) else null,
        };
        self.recent_keystrokes.append(gpa, owned) catch oom();
        cx.notify();
    }

    fn on_reset_click(self: *InputExample, _: *const MouseUpEvent, window: *Window, cx: *Context(InputExample)) void {
        self.clear_recent_keystrokes();
        self.text_input.update_in(window, cx, TextInput.reset, .{});
        cx.notify();
    }

    pub fn render(self: *InputExample, _: *Window, cx: *Context(InputExample)) *Div {
        const header = div()
            .bg(white())
            .border_b_1()
            .border_color(black())
            .flex()
            .flex_row()
            .justify_between()
            .child("Keyboard")
            .child(
                div()
                    .border_1()
                    .border_color(black())
                    .px_2()
                    .bg(yellow())
                    .child("Reset")
                    .hover(gpui.style_refinement().bg(yellow().blend(opaque_grey(0.5, 0.5))).cursor_pointer())
                    .on_mouse_up(.left, cx.listener(InputExample.on_reset_click)),
            );
        var root = div()
            .bg(rgb(0xaaaaaa))
            .track_focus(&self.focus_handle)
            .capture_key_down(cx.listener(InputExample.record_keystroke))
            .flex()
            .flex_col()
            .size_full()
            .child(header)
            .child(self.text_input);
        var index = self.recent_keystrokes.items.len;
        while (index > 0) {
            index -= 1;
            const keystroke = self.recent_keystrokes.items[index];
            const unparsed = keystroke.unparse(gpui.window.frame_arena()) catch oom();
            const key_char_label = if (keystroke.key_char) |key_char| format("-> \"{s}\"", .{key_char}) else "";
            root = root.child(format("{s} {s}", .{ unparsed, key_char_label }));
        }
        return root;
    }
};

fn quit(_: *const Quit, cx: *App) void {
    cx.quit();
}

fn focus_text_input(_: *InputExample, focus: FocusHandle, window: *Window, _: *Context(InputExample)) void {
    window.focus(focus);
}

fn build_input_example(_: *Window, app: *App) Entity(InputExample) {
    const text_input = app.new(TextInput{
        .focus_handle = app.focus_handle(),
        .content = "",
        .placeholder = "Type here...",
        .selected_range = .{ .start = 0, .end = 0 },
        .selection_reversed = false,
        .marked_range = null,
        .last_layout = null,
        .last_bounds = null,
        .is_selecting = false,
    });
    return app.new(InputExample{
        .text_input = text_input,
        .focus_handle = app.focus_handle(),
    });
}

fn run_example(cx: *App) void {
    const bounds = Bounds(Pixels).centered(null, size(px(300.0), px(300.0)), cx);
    cx.bind_keys(&.{
        KeyBinding.new("backspace", Backspace{}, null),
        KeyBinding.new("delete", Delete{}, null),
        KeyBinding.new("left", Left{}, null),
        KeyBinding.new("right", Right{}, null),
        KeyBinding.new("shift-left", SelectLeft{}, null),
        KeyBinding.new("shift-right", SelectRight{}, null),
        KeyBinding.new("cmd-a", SelectAll{}, null),
        KeyBinding.new("cmd-v", Paste{}, null),
        KeyBinding.new("cmd-c", Copy{}, null),
        KeyBinding.new("cmd-x", Cut{}, null),
        KeyBinding.new("home", Home{}, null),
        KeyBinding.new("end", End{}, null),
        KeyBinding.new("ctrl-cmd-space", ShowCharacterPalette{}, null),
    });

    const window = cx.open_window(.{ .window_bounds = .{ .windowed = bounds } }, build_input_example) catch unreachable;
    // GPUI's cx.on_keyboard_layout_change is missing in ZUI, so the layout name is not refreshed.
    const text_input = window.update(cx, struct {
        fn get(view: *InputExample, _: *Window, _: *Context(InputExample)) Entity(TextInput) {
            return view.text_input;
        }
    }.get, .{}) catch unreachable;
    const focus = text_input.read(cx).focus_handle;
    window.update(cx, focus_text_input, .{focus}) catch unreachable;
    cx.activate(true);

    cx.on_action(Quit, quit);
    cx.bind_keys(&.{KeyBinding.new("cmd-q", Quit{}, null)});
}

pub fn main() void {
    gpui.Application.new().run(run_example);
}
