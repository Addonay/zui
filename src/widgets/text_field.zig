const std = @import("std");
const platform = @import("../platform/root.zig");
const elements = @import("../elements/root.zig");
const runtime = @import("../app/runtime.zig");
const limits = @import("../core/limits.zig");
const editing = @import("editing.zig");
const Rect = @import("../core/geometry.zig").Rect;
const Window = @import("../app/window.zig").Window;

pub const TextField = struct {
    pub const Options = struct {
        placeholder: []const u8 = "",
        text_color: @import("../core/color.zig").Color = .hex(0xf2f2f5),
        placeholder_color: @import("../core/color.zig").Color = .hex(0x6f7082),
        focus_color: @import("../core/color.zig").Color = .hex(0x7c5cff),
        padding: f32 = 8,
        input_limit: usize = limits.MAX_TEXT_LEN,
        caret_reporter: platform.event.CaretReporter = .{},
    };
    model: editing.Model = .{},
    /// Read-only compatibility views. Mutate via model/append, not these.
    buffer: []const u8 = "",
    len: usize = 0,
    caret: usize = 0,
    placeholder: []const u8,
    options: Options,
    preedit: ?platform.event.CompositionText = null,
    composition_selection: ?editing.Model.Selection = null,
    display: [limits.MAX_TEXT_LEN + 256]u8 = undefined,
    dragging: bool = false,
    bounds: Rect = .{},

    pub fn init(_: *runtime.Context(TextField), options: Options) TextField {
        return .{ .placeholder = options.placeholder, .options = options, .model = .{ .input_limit = options.input_limit } };
    }
    fn sync(self: *TextField) void {
        self.buffer = self.model.text();
        self.len = self.model.len;
        self.caret = self.model.selection.active;
    }
    pub fn trimmedText(self: *const TextField) []const u8 {
        return std.mem.trim(u8, self.model.text(), " \t\r\n");
    }
    pub fn clear(self: *TextField, cx: *runtime.Context(TextField)) void {
        self.cancelComposition();
        self.model.selectAll();
        self.model.delete(false);
        self.sync();
        cx.notify();
    }
    pub fn append(self: *TextField, bytes: []const u8) void {
        self.cancelComposition();
        self.model.insert(bytes);
        self.sync();
    }
    fn cancelComposition(self: *TextField) void {
        if (self.composition_selection) |selection| self.model.selection = selection;
        self.preedit = null;
        self.composition_selection = null;
    }
    /// Composition never mutates committed text until commit, which is one
    /// history entry. Invalid replacement ranges reject the entire event.
    pub fn compose(self: *TextField, ev: platform.event.CompositionEvent) bool {
        switch (ev) {
            .cancel => self.cancelComposition(),
            .preedit, .commit => |payload| {
                const bytes = payload.slice() orelse return false;
                var selection = self.model.selection;
                if (payload.replacement) |r| {
                    if (r.start > r.end or r.end > self.model.len or self.model.snap(r.start) != r.start or self.model.snap(r.end) != r.end) return false;
                    selection = .{ .anchor = r.start, .active = r.end };
                }
                if (ev == .preedit) {
                    if (self.composition_selection == null) self.composition_selection = self.model.selection;
                    self.model.selection = selection;
                    self.preedit = payload;
                } else {
                    self.model.selection = if (payload.replacement != null) selection else if (self.preedit != null) self.model.selection else selection;
                    if (bytes.len == 0) {
                        if (self.model.selected().len > 0) self.model.delete(false);
                    } else self.model.insert(bytes);
                    self.preedit = null;
                    self.composition_selection = null;
                }
            },
        }
        self.sync();
        return true;
    }
    fn displayed(self: *TextField) []const u8 {
        if (self.preedit) |*p| {
            const bytes = p.slice() orelse return self.model.text();
            const start = self.model.selection.start();
            const end = self.model.selection.end();
            @memcpy(self.display[0..start], self.model.text()[0..start]);
            @memcpy(self.display[start..][0..bytes.len], bytes);
            const suffix = self.model.text()[end..];
            @memcpy(self.display[start + bytes.len ..][0..suffix.len], suffix);
            return self.display[0 .. start + bytes.len + suffix.len];
        }
        return self.model.text();
    }
    fn updateBounds(self: *TextField, window: *Window, cx: *runtime.Context(TextField)) void {
        for (window.ui_frame.regions[0..window.ui_frame.region_count]) |region| {
            if (region.focus) |focus| if (focus.eql(cx.focusHandle())) {
                self.bounds = region.bounds;
                return;
            };
        }
    }
    fn pointerDown(self: *TextField, window: *Window, cx: *runtime.Context(TextField)) void {
        self.dragging = true;
        self.pointerPlace(window, cx, false);
    }
    fn pointerMove(self: *TextField, window: *Window, cx: *runtime.Context(TextField)) void {
        if (self.dragging) self.pointerPlace(window, cx, true);
    }
    fn pointerUp(self: *TextField, _: *Window, _: *runtime.Context(TextField)) void {
        self.dragging = false;
    }
    fn pointerPlace(self: *TextField, window: *Window, cx: *runtime.Context(TextField), extend: bool) void {
        self.updateBounds(window, cx);
        self.cancelComposition();
        const engine = window.ui_frame.engine orelse return;
        var layout = engine.layout(elements.text_engine.frameAllocator(&window.ui_frame), self.model.text(), .{ .size = 14, .line_height = 17.5 }, null) catch return;
        defer layout.deinit();
        const cursor = (layout.hit(window.pointer_position.x - self.bounds.x - self.options.padding + self.model.scroll_x, 0) catch return) orelse return;
        self.model.place(cursor.index, extend);
        self.sync();
        cx.notify();
    }
    pub fn render(self: *TextField, window: *Window, cx: *runtime.Context(TextField)) elements.Element {
        self.sync();
        const focused = window.focused.eql(cx.focusHandle());
        const value = self.displayed();
        const empty = value.len == 0;
        const text_element = elements.text(if (empty) self.placeholder else value, .{ .size = 14, .color = if (empty) self.options.placeholder_color else self.options.text_color });
        var field = elements.div().flex_row().h(40).size_full().px(self.options.padding).items_center().rounded_lg().cursor_text().border_1()
            .border_color(if (focused) self.options.focus_color else @import("../core/color.zig").Color.transparent);
        const frame = elements.element.currentFrame();
        // Previous frame bounds provide the viewport, never guessed glyph widths.
        self.updateBounds(window, cx);
        if (frame.engine) |engine| {
            var shaped = engine.layout(elements.text_engine.frameAllocator(frame), value, elements.text_engine.attrs(&frame.nodes[text_element.index]), null) catch null;
            if (shaped) |*layout| {
                defer layout.deinit();
                const index = if (self.preedit) |p| self.model.selection.start() + p.marked.end else self.model.selection.active;
                const pos = layout.cursorPosition(.{ .line = 0, .index = index }) orelse if (empty) @import("../fonts/text_engine.zig").CursorPosition{ .x = 0, .y = 0 } else null;
                if (pos) |p| {
                    if (self.bounds.w > 0) self.model.ensureCaretVisible(p.x, self.bounds.w - 2 * self.options.padding);
                    if (focused) self.options.caret_reporter.update(.{ .x = self.bounds.x + self.options.padding + p.x - self.model.scroll_x, .y = self.bounds.y + 10, .w = 1, .h = 20 });
                }
                if (focused) {
                    const start = self.model.selection.start();
                    const end = if (self.preedit) |p| start + p.len else self.model.selection.end();
                    const rects = layout.selectionRects(elements.text_engine.frameAllocator(frame), .{ .line = 0, .index = start }, .{ .line = 0, .index = end }) catch null;
                    if (rects) |rs| {
                        defer elements.text_engine.frameAllocator(frame).free(rs);
                        for (rs) |r| field = field.child(elements.div().absolute().left(self.options.padding + r.x - self.model.scroll_x).top(if (self.preedit != null) 29 else 10).w(r.w).h(if (self.preedit != null) 1 else 20).bg(if (self.preedit != null) self.options.focus_color else @import("../core/color.zig").Color.hex(0x40376b)));
                    }
                }
                // Text after highlights, caret last: preserve painter order.
                field = field.child(text_element);
                if (focused) if (pos) |p| {
                    field = field.child(elements.div().absolute().left(self.options.padding + p.x - self.model.scroll_x).top(10).w(1).h(20).bg(self.options.focus_color));
                };
            } else field = field.child(text_element);
        } else field = field.child(text_element);
        frame.nodes[field.index].style.scroll_x = self.model.scroll_x;
        return field.withFocus(cx.focusHandle()).on_mouse_down(cx.listener(TextField, pointerDown)).on_mouse_move(cx.listener(TextField, pointerMove)).on_mouse_up(cx.listener(TextField, pointerUp));
    }
    pub fn handleEvent(self: *TextField, event: platform.Event, cx: *runtime.Context(TextField)) bool {
        defer self.sync();
        if (cx.window) |window| self.updateBounds(window, cx);
        switch (event) {
            .composition => |composition| {
                if (!self.compose(composition)) return false;
                cx.notify();
                return true;
            },
            .text => |text_event| {
                self.append(text_event.slice());
                cx.notify();
                return true;
            },
            .window => |ev| {
                if (ev == .unfocused) {
                    self.cancelComposition();
                    self.dragging = false;
                    cx.notify();
                }
                return false;
            },
            .key => |key| {
                if (!key.pressed) return false;
                const command = key.modifiers.ctrl or key.modifiers.super;
                if (self.preedit != null) {
                    if (key.key == .escape) {
                        self.cancelComposition();
                        cx.notify();
                    }
                    // Native IME owns physical editing keys until commit/cancel.
                    return true;
                }
                if (command) switch (key.key) {
                    .a => {
                        self.model.selectAll();
                        cx.notify();
                        return true;
                    },
                    .z => {
                        if (key.modifiers.shift) self.model.redo() else self.model.undo();
                        cx.notify();
                        return true;
                    },
                    .y => {
                        self.model.redo();
                        cx.notify();
                        return true;
                    },
                    .v => {
                        if (cx.window) |win| {
                            var paste: [limits.MAX_TEXT_LEN]u8 = undefined;
                            const n = win.readClipboard(&paste);
                            self.append(paste[0..n]);
                            cx.notify();
                        }
                        return true;
                    },
                    .c, .x => {
                        if (self.model.selected().len > 0) if (cx.window) |win| {
                            if (win.writeClipboard(self.model.selected()) and key.key == .x) {
                                self.model.delete(false);
                                cx.notify();
                            }
                        };
                        return true;
                    },
                    else => {},
                };
                switch (key.key) {
                    .left, .right, .home, .end => {
                        if (!command and (key.key == .left or key.key == .right) and (key.modifiers.shift or self.model.selected().len == 0)) {
                            if (cx.window) |win| if (win.ui_frame.engine) |engine| {
                                var layout = engine.layout(elements.text_engine.frameAllocator(&win.ui_frame), self.model.text(), .{ .size = 14, .line_height = 17.5 }, null) catch return true;
                                defer layout.deinit();
                                if (layout.visualMove(.{ .line = 0, .index = self.model.selection.active }, key.key == .right)) |cursor| self.model.place(cursor.index, key.modifiers.shift);
                                cx.notify();
                                return true;
                            };
                        }
                        self.model.move(switch (key.key) {
                            .left => if (command) .word_previous else .previous,
                            .right => if (command) .word_next else .next,
                            .home => .line_start,
                            .end => .line_end,
                            else => unreachable,
                        }, key.modifiers.shift);
                    },
                    .delete => self.model.delete(false),
                    .backspace => self.model.delete(true),
                    .space => return true,
                    else => return false,
                }
                cx.notify();
                return true;
            },
            else => return false,
        }
    }
};
test "insertion comes from text events only, never key events" {
    const t = std.testing;
    var store = runtime.EntityStore.init(t.allocator);
    defer store.deinit();
    const ent = store.create(TextField, .{ .placeholder = "ph" }, null);
    var cx = runtime.Context(TextField){ .store = &store, .current = ent, .window = null };
    const field = ent.readMut();

    // Printable insertion arrives as `.text` (X11 XLookupString, Wayland
    // evdev table) and is consumed.
    var tev = platform.event.TextEvent{};
    tev.text[0] = 'A';
    tev.len = 1;
    try t.expect(field.handleEvent(.{ .text = tev }, &cx));
    try t.expectEqual(@as(usize, 1), field.len);

    // The physical `.key` for the same letter must not insert again.
    try t.expect(!field.handleEvent(.{ .key = .{ .key = .a, .pressed = true } }, &cx));
    try t.expectEqual(@as(usize, 1), field.len);

    // Space is consumed (blocks the window space binding) but inserts
    // nothing — its `.text` twin does the inserting.
    try t.expect(field.handleEvent(.{ .key = .{ .key = .space, .pressed = true } }, &cx));
    try t.expectEqual(@as(usize, 1), field.len);

    // Editing keys still work; action keys fall through to bindings.
    try t.expect(field.handleEvent(.{ .key = .{ .key = .backspace, .pressed = true } }, &cx));
    try t.expectEqual(@as(usize, 0), field.len);
    try t.expect(!field.handleEvent(.{ .key = .{ .key = .enter, .pressed = true } }, &cx));
    try t.expect(!field.handleEvent(.{ .key = .{ .key = .a, .pressed = false } }, &cx));
}

test "clipboard shortcuts need a window and stay headless-safe" {
    const t = std.testing;
    var store = runtime.EntityStore.init(t.allocator);
    defer store.deinit();
    const ent = store.create(TextField, .{ .placeholder = "ph" }, null);
    var cx = runtime.Context(TextField){ .store = &store, .current = ent, .window = null };
    const field = ent.readMut();

    // No window attached: shortcuts consume the key but move no bytes.
    const ctrl_v = platform.event.KeyEvent{ .key = .v, .pressed = true, .modifiers = .{ .ctrl = true } };
    try t.expect(field.handleEvent(.{ .key = ctrl_v }, &cx));
    try t.expectEqual(@as(usize, 0), field.len);
}

test "caret editing preserves UTF-8 and inserts in the middle" {
    var store = runtime.EntityStore.init(std.testing.allocator);
    defer store.deinit();
    const ent = store.create(TextField, .{}, null);
    var cx = runtime.Context(TextField){ .store = &store, .current = ent, .window = null };
    const field = ent.readMut();
    field.append("aé🙂z");
    for ([_]platform.event.Key{ .left, .left, .backspace, .delete }) |key| {
        try std.testing.expect(field.handleEvent(.{ .key = .{ .key = key, .pressed = true } }, &cx));
    }
    try std.testing.expectEqualStrings("az", field.buffer[0..field.len]);
    field.append("é");
    try std.testing.expectEqualStrings("aéz", field.buffer[0..field.len]);
    try std.testing.expectEqual(@as(usize, 3), field.caret);
    field.clear(&cx);
    try std.testing.expectEqual(@as(usize, 0), field.caret);
    field.append("\n\tA\r");
    try std.testing.expectEqualStrings("A", field.buffer[0..field.len]);
    field.clear(&cx);
    @memset(field.model.buffer[0 .. limits.MAX_TEXT_LEN - 1], 'a');
    field.model.len = limits.MAX_TEXT_LEN - 1;
    field.model.place(field.model.len, false);
    field.append("é");
    try std.testing.expectEqual(limits.MAX_TEXT_LEN - 1, field.len);
    try std.testing.expect(std.unicode.utf8ValidateSlice(field.buffer[0..field.len]));
}

test "caret x follows the engine's prefix width; no engine omits it" {
    // Regression: the caret used the old collection measure, so under the
    // engine it drifted from the painted advances with every prefix byte.
    // `text_engine.caretX` shapes through the same path paint uses.
    const t = std.testing;
    const text_engine = @import("../fonts/text_engine.zig");
    const App = @import("../app/app.zig").App;
    const gpu = @import("../gpu/root.zig");

    var app = try App.initHeadless(t.allocator);
    defer app.deinit();
    const engine = text_engine.Engine.init(t.allocator) catch |err| switch (err) {
        error.ShaperUnavailable, error.LibraryUnavailable, error.NoFontsAvailable, error.FontCorpusIncomplete => return error.SkipZigTest,
        else => return err,
    };
    defer engine.deinit();

    var store = runtime.EntityStore.init(t.allocator);
    defer store.deinit();
    const ent = store.create(TextField, .{ .placeholder = "ph" }, null);
    const field = ent.readMut();
    field.append("abc");
    field.model.place(2, false);

    const win = try app.openWindow(.{}, struct {
        fn noop(_: *Window, _: *gpu.Scene) void {}
    }.noop);
    var cx = runtime.Context(TextField){ .store = &store, .current = ent, .window = win };
    win.focused = cx.focusHandle();
    const frame = &win.ui_frame;

    // Engine installed: caret x == the engine's prefix advance + the 8px pad.
    frame.reset(win, .{});
    frame.engine = engine;
    frame.allocator = t.allocator;
    elements.element.beginFrame(frame);
    const rendered = field.render(win, &cx);
    const text_index = frame.nodes[rendered.index].first_child.?;
    const caret_index = frame.nodes[text_index].next_sibling.?;
    const engine_caret_x = frame.nodes[caret_index].style.left.?;
    elements.element.endFrame();

    const attrs = elements.text_engine.attrs(&frame.nodes[text_index]);
    const prefix_w = try engine.measure(t.allocator, "ab", attrs);
    try t.expectApproxEqAbs(prefix_w + 8, engine_caret_x, 0.001);

    // A non-default field pad moves the caret origin with the field's actual
    // style (content offset + engine-local x), not a hardcoded 8px.
    field.options.padding = 12;
    frame.reset(win, .{});
    frame.engine = engine;
    frame.allocator = t.allocator;
    elements.element.beginFrame(frame);
    const rendered_wide = field.render(win, &cx);
    const wide_text_index = frame.nodes[rendered_wide.index].first_child.?;
    const wide_caret_index = frame.nodes[wide_text_index].next_sibling.?;
    const wide_pad = frame.nodes[rendered_wide.index].style.padding.left;
    const wide_caret_x = frame.nodes[wide_caret_index].style.left.?;
    elements.element.endFrame();
    try t.expectApproxEqAbs(@as(f32, 12), wide_pad, 0.001);
    try t.expectApproxEqAbs(prefix_w + wide_pad, wide_caret_x, 0.001);
    field.options.padding = 8;

    // No engine: the caret is omitted (`.unavailable`) instead of guessing
    // an advance that the painter would not match. The old fallbacks are
    // gone, so there must be no caret sibling at all.
    frame.reset(win, .{});
    frame.allocator = t.allocator;
    elements.element.beginFrame(frame);
    const rendered_bare = field.render(win, &cx);
    const bare_text_index = frame.nodes[rendered_bare.index].first_child.?;
    try t.expectEqual(@as(?u16, null), frame.nodes[bare_text_index].next_sibling);
    elements.element.endFrame();
}

test "composition preedit cancel replacement and commit are transactional" {
    var store = runtime.EntityStore.init(std.testing.allocator);
    defer store.deinit();
    const ent = store.create(TextField, .{}, null);
    var cx = runtime.Context(TextField){ .store = &store, .current = ent, .window = null };
    const field = ent.readMut();
    field.append("hello world");
    field.model.selection = .{ .anchor = 6, .active = 11 };
    var preedit = try platform.event.CompositionText.init("にほん");
    preedit.marked = .{ .start = 3, .end = 6 };
    try std.testing.expect(field.handleEvent(.{ .composition = .{ .preedit = preedit } }, &cx));
    try std.testing.expectEqualStrings("hello world", field.model.text());
    try std.testing.expectEqualStrings("hello にほん", field.displayed());
    try std.testing.expect(field.compose(.cancel));
    try std.testing.expectEqualStrings("world", field.model.selected());
    try std.testing.expect(field.compose(.{ .preedit = preedit }));
    try std.testing.expect(field.compose(.{ .commit = try platform.event.CompositionText.init("日本") }));
    try std.testing.expectEqualStrings("hello 日本", field.model.text());
    field.model.undo();
    try std.testing.expectEqualStrings("hello world", field.model.text());
    try std.testing.expectEqualStrings("world", field.model.selected());
    var invalid = preedit;
    invalid.replacement = .{ .start = 5, .end = 100 };
    try std.testing.expect(!field.compose(.{ .preedit = invalid }));
    try std.testing.expect(field.preedit == null);
}

test "field right arrow follows distinct visual caret in mixed RTL text" {
    const fonts = @import("../fonts/text_engine.zig");
    const App = @import("../app/app.zig").App;
    const gpu = @import("../gpu/root.zig");
    var app = try App.initHeadless(std.testing.allocator);
    defer app.deinit();
    const engine = fonts.Engine.init(std.testing.allocator) catch return error.SkipZigTest;
    defer engine.deinit();
    const win = try app.openWindow(.{}, struct {
        fn noop(_: *Window, _: *gpu.Scene) void {}
    }.noop);
    win.ui_frame.engine = engine;
    var store = runtime.EntityStore.init(std.testing.allocator);
    defer store.deinit();
    const ent = store.create(TextField, .{}, null);
    var cx = runtime.Context(TextField){ .store = &store, .current = ent, .window = win };
    const field = ent.readMut();
    field.append("a אבג z");
    // Inside the Hebrew run, physical Right moves toward a LOWER byte index.
    field.model.place(6, false);
    try std.testing.expect(field.handleEvent(.{ .key = .{ .key = .right, .pressed = true } }, &cx));
    try std.testing.expectEqual(@as(usize, 4), field.model.selection.active);
}
