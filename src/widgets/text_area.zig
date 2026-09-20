//! TextArea is a policy wrapper around the bounded Editor primitive.
const std = @import("std");
const platform = @import("../platform/root.zig");
const editor_mod = @import("editor.zig");
const a11y = @import("../a11y/root.zig");
const elements = @import("../elements/root.zig");
const Window = @import("../app/window.zig").Window;

pub const TextArea = struct {
    pub const Options = struct { rows: usize = 4, disabled: bool = false, loading: bool = false, error_state: bool = false };
    options: Options,
    editor: editor_mod.Editor,
    focused: bool = false,

    pub fn init(text: []const u8, options: Options) TextArea {
        var ed = editor_mod.Editor.init(text, true);
        ed.disabled = options.disabled;
        ed.loading = options.loading;
        ed.error_state = options.error_state;
        return .{ .options = options, .editor = ed };
    }
    pub fn handleEvent(self: *TextArea, event: platform.Event) bool {
        if (self.options.disabled or self.options.loading) return false;
        self.editor.disabled = self.options.disabled;
        self.editor.loading = self.options.loading;
        return self.editor.handleEvent(event);
    }
    pub fn setFocused(self: *TextArea, focused: bool) void {
        self.focused = focused;
        self.editor.focused = focused;
    }
    pub fn setError(self: *TextArea, value: bool) void {
        self.options.error_state = value;
        self.editor.error_state = value;
    }
    pub fn semanticProperties(self: *const TextArea, label: []const u8) a11y.Properties {
        var properties = self.editor.semanticProperties(label);
        properties.states.disabled = self.options.disabled;
        properties.states.focused = self.focused;
        return properties;
    }
    fn focusId(self: *TextArea) u32 {
        return @truncate(@intFromPtr(self));
    }
    fn focusedEvent(target: *anyopaque, event: platform.Event, _: *anyopaque) bool {
        return @as(*TextArea, @ptrCast(@alignCast(target))).handleEvent(event);
    }
    fn semanticAction(target: *anyopaque, request: a11y.Request, _: *anyopaque) void {
        const self: *TextArea = @ptrCast(@alignCast(target));
        switch (request.action) {
            .set_value => {
                self.editor.replaceAll(request.text);
            },
            .set_text_selection => if (request.selection) |selection| self.editor.setSelection(selection.anchor, selection.focus),
            else => {},
        }
    }
    pub fn render(self: *TextArea, label: []const u8) elements.Element {
        const focus = elements.FocusHandle{ .id = self.focusId(), .target = self, .event_fn = focusedEvent };
        var props = self.semanticProperties(label);
        props.handler = .{ .target = self, .call_fn = semanticAction };
        return elements.div().w_full().h(@as(f32, @floatFromInt(self.options.rows)) * 20).p(6).rounded_lg().border_1().overflow_hidden().withFocus(focus)
            .semantic(props).text_selection(self.editor.characterIndex(self.editor.anchor), self.editor.characterIndex(self.editor.active)).child(elements.text(self.editor.text(), .{ .line_height = 20.0 }));
    }

    /// Window-aware render path used by the real text pipeline. It reuses the
    /// same shaped layout as paint and attaches scalar character geometry to
    /// the semantic node; `render()` remains a renderer-independent fallback.
    pub fn renderInWindow(self: *TextArea, window: *Window, label: []const u8) elements.Element {
        var root = self.render(label);
        const frame = elements.element.currentFrame();
        if (frame.engine) |engine| {
            var layout = engine.layout(elements.text_engine.frameAllocator(frame), self.editor.text(), .{ .size = 14, .line_height = 20 }, null) catch return root;
            defer layout.deinit();
            _ = window;
            if (layout.accessibilityGeometry(elements.text_engine.frameAllocator(frame))) |geometry_value| {
                var geometry = geometry_value;
                defer geometry.deinit(elements.text_engine.frameAllocator(frame));
                root = root.text_geometry(.{ .positions = geometry.positions, .widths = geometry.widths, .ranges = geometry.ranges });
            } else |_| {}
        }
        return root;
    }
};

test "textarea keeps newline semantics and state gates" {
    var area = TextArea.init("one", .{ .rows = 3 });
    const ev = platform.Event{ .text = .{ .text = .{'x'} ++ std.mem.zeroes([31]u8), .len = 1 } };
    try std.testing.expect(area.handleEvent(ev));
    try std.testing.expectEqualStrings("onex", area.editor.text());
    area.options.disabled = true;
    try std.testing.expect(!area.handleEvent(ev));
}

test "textarea exposes scalar selection indices and safe IME-neutral actions" {
    var area = TextArea.init("Aé你", .{});
    area.editor.setSelection(1, 3);
    const props = area.semanticProperties("Notes");
    try std.testing.expectEqual(@as(u32, 1), area.editor.characterIndex(area.editor.anchor));
    try std.testing.expectEqual(@as(u32, 2), area.editor.characterIndex(area.editor.active));
    try std.testing.expect(props.actions.set_text_selection);
    area.editor.setSelection(area.editor.byteIndexForCharacter(2), area.editor.byteIndexForCharacter(1));
    try std.testing.expectEqual(@as(usize, 3), area.editor.anchor);
    try std.testing.expectEqual(@as(usize, 1), area.editor.active);
}
