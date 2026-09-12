const std = @import("std");
const platform = @import("../platform/root.zig");
const elements = @import("../elements/root.zig");
const runtime = @import("../app/runtime.zig");
const limits = @import("../core/limits.zig");

pub const TextField = struct {
    pub const Options = struct {
        placeholder: []const u8 = "",
        text_color: @import("../core/color.zig").Color = .hex(0xf2f2f5),
        placeholder_color: @import("../core/color.zig").Color = .hex(0x6f7082),
        focus_color: @import("../core/color.zig").Color = .hex(0x7c5cff),
        /// Inner horizontal padding of the field box. The caret origin is
        /// read back from the built node's actual style, so text and caret
        /// stay aligned when this changes.
        padding: f32 = 8,
    };

    buffer: [limits.MAX_TEXT_LEN]u8 = undefined,
    len: usize = 0,
    caret: usize = 0,
    placeholder: []const u8,
    options: Options,

    pub fn init(_: *runtime.Context(TextField), options: Options) TextField {
        return .{ .placeholder = options.placeholder, .options = options };
    }

    pub fn trimmedText(self: *const TextField) []const u8 {
        return std.mem.trim(u8, self.buffer[0..self.len], " \t\r\n");
    }

    pub fn clear(self: *TextField, cx: *runtime.Context(TextField)) void {
        self.len = 0;
        self.caret = 0;
        cx.notify();
    }

    pub fn render(self: *TextField, window: *@import("../app/window.zig").Window, cx: *runtime.Context(TextField)) elements.Element {
        const focused = window.focused.eql(cx.focusHandle());
        const value = if (self.len == 0) self.placeholder else self.buffer[0..self.len];
        const color = if (self.len == 0) self.options.placeholder_color else self.options.text_color;
        const text_element = elements.text(value, .{ .size = 14, .color = color });
        var field = elements.div().flex_row().h(40).size_full().px(self.options.padding).items_center()
            .rounded_lg()
            .cursor_text()
            .border_1()
            .border_color(if (focused) self.options.focus_color else @import("../core/color.zig").Color.transparent)
            .child(text_element);
        if (focused) {
            // Caret advance comes from the same engine that paints the text
            // (`text_engine.caretX` shapes through the shared cozmic path),
            // so it cannot drift from the painted advances. `.unavailable`
            // (no engine installed, or no line-0 caret position) omits the
            // caret rather than mixing in a guessed advance.
            const frame = elements.element.currentFrame();
            const text_node = &frame.nodes[text_element.index];
            const caret = elements.text_engine.caretX(frame, text_node, self.caret);
            const local_x: ?f32 = switch (caret.source) {
                .cozmic => caret.x,
                .unavailable => null,
            };
            if (local_x) |x| {
                // The caret is an absolute child of the field and positions
                // from the field's border box, so its origin is the field's
                // own content offset (actual style padding, not a hardcoded
                // 8px) plus the engine-local prefix x.
                const origin_x = frame.nodes[field.index].style.padding.left;
                field = field.child(elements.div().absolute().left(origin_x + x).top(10).w(1).h(20).bg(self.options.focus_color));
            }
        }
        return field.withFocus(cx.focusHandle());
    }

    pub fn handleEvent(self: *TextField, event: platform.Event, cx: *runtime.Context(TextField)) bool {
        switch (event) {
            // Insertion lives here exclusively. Backends emit `.text` for
            // printable input (X11 XLookupString, Wayland evdev table) and
            // `.key` for physical keys, so the `.key` branch below must not
            // insert or every keystroke lands twice.
            .text => |text_event| {
                self.append(text_event.slice());
                cx.notify();
                return true;
            },
            .key => |key_event| {
                if (!key_event.pressed) return false;
                // Clipboard shortcuts (Ctrl on Linux/Windows, Cmd on macOS).
                // They run before the editing switch and consume the key so
                // no binding or text insertion fires for them.
                if (key_event.modifiers.ctrl or key_event.modifiers.super) {
                    switch (key_event.key) {
                        .v => {
                            if (cx.window) |win| {
                                var paste: [limits.MAX_TEXT_LEN]u8 = undefined;
                                const n = win.readClipboard(&paste);
                                if (n > 0) {
                                    self.append(paste[0..n]);
                                    cx.notify();
                                }
                            }
                            return true;
                        },
                        .c => {
                            if (cx.window) |win| _ = win.writeClipboard(self.buffer[0..self.len]);
                            return true;
                        },
                        .x => {
                            if (cx.window) |win| _ = win.writeClipboard(self.buffer[0..self.len]);
                            self.len = 0;
                            self.caret = 0;
                            cx.notify();
                            return true;
                        },
                        else => {},
                    }
                }
                switch (key_event.key) {
                    .left, .right, .home, .end => {
                        self.caret = switch (key_event.key) {
                            .left => self.previousBoundary(),
                            .right => self.nextBoundary(),
                            .home => 0,
                            .end => self.len,
                            else => unreachable,
                        };
                        cx.notify();
                        return true;
                    },
                    .delete => {
                        self.erase(self.caret, self.nextBoundary());
                        cx.notify();
                        return true;
                    },
                    .backspace => {
                        const start = self.previousBoundary();
                        self.erase(start, self.caret);
                        self.caret = start;
                        cx.notify();
                        return true;
                    },
                    // Consumed without inserting: the matching `.text`
                    // event does the insertion. Returning true keeps the
                    // window from firing the space key binding mid-typing.
                    .space => return true,
                    .enter, .escape, .tab => return false,
                    else => {},
                }
                return false;
            },
            else => {},
        }
        return false;
    }

    fn append(self: *TextField, bytes: []const u8) void {
        // Accept whole UTF-8 codepoints only, including at capacity. A field
        // is single-line: pasted newlines and control bytes are ignored.
        if (!std.unicode.utf8ValidateSlice(bytes)) return;
        var i: usize = 0;
        while (i < bytes.len) {
            const n = std.unicode.utf8ByteSequenceLength(bytes[i]) catch return;
            defer i += n;
            if (bytes[i] < 0x20 or bytes[i] == 0x7f) continue;
            if (n > self.buffer.len - self.len) break;
            std.mem.copyBackwards(u8, self.buffer[self.caret + n .. self.len + n], self.buffer[self.caret..self.len]);
            @memcpy(self.buffer[self.caret..][0..n], bytes[i..][0..n]);
            self.len += n;
            self.caret += n;
        }
    }

    fn previousBoundary(self: *const TextField) usize {
        if (self.caret == 0) return 0;
        var pos = self.caret - 1;
        while (pos > 0 and (self.buffer[pos] & 0xc0) == 0x80) pos -= 1;
        return pos;
    }

    fn nextBoundary(self: *const TextField) usize {
        if (self.caret == self.len) return self.len;
        var pos = self.caret + 1;
        while (pos < self.len and (self.buffer[pos] & 0xc0) == 0x80) pos += 1;
        return pos;
    }

    fn erase(self: *TextField, start: usize, end: usize) void {
        std.mem.copyForwards(u8, self.buffer[start .. self.len - (end - start)], self.buffer[end..self.len]);
        self.len -= end - start;
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
    @memset(field.buffer[0 .. field.buffer.len - 1], 'a');
    field.len = field.buffer.len - 1;
    field.caret = field.len;
    field.append("é");
    try std.testing.expectEqual(field.buffer.len - 1, field.len);
    try std.testing.expect(std.unicode.utf8ValidateSlice(field.buffer[0..field.len]));
}

test "caret x follows the engine's prefix width; no engine omits it" {
    // Regression: the caret used the old collection measure, so under the
    // engine it drifted from the painted advances with every prefix byte.
    // `text_engine.caretX` shapes through the same path paint uses.
    const t = std.testing;
    const text_engine = @import("../fonts/text_engine.zig");
    const App = @import("../app/app.zig").App;
    const Window = @import("../app/window.zig").Window;
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
    field.caret = 2;

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
