//! Port of GPUI `input.rs`. A view handles text input by providing the methods of GPUI's
//! `EntityInputHandler` trait and registering an `ElementInputHandler` during paint:
//!
//! ```zig
//! window.handle_input(&focus, gpui.ElementInputHandler(Editor).new(bounds, view), cx);
//! ```
//!
//! Every range is in UTF-16 code units, as in GPUI.
const std = @import("std");
const app_mod = @import("app.zig");
const geometry = @import("geometry.zig");
const platform = @import("platform.zig");
const window_mod = @import("window.zig");

const App = app_mod.App;
const Bounds = geometry.Bounds;
const Pixels = geometry.Pixels;
const Point = geometry.Point;
const Range = platform.Range;
const UTF16Selection = platform.UTF16Selection;
const PlatformInputHandler = platform.PlatformInputHandler;
const Window = window_mod.Window;

/// Fails compilation with a clear message when `V` lacks a required method of
/// GPUI's `EntityInputHandler`. `accepts_text_input` is optional and defaults to true.
pub fn assert_entity_input_handler(comptime V: type) void {
    for ([_][]const u8{
        "text_for_range",
        "selected_text_range",
        "marked_text_range",
        "unmark_text",
        "replace_text_in_range",
        "replace_and_mark_text_in_range",
        "bounds_for_range",
        "character_index_for_point",
    }) |name| {
        if (!@hasDecl(V, name)) @compileError(@typeName(V) ++ " must implement " ++ name ++ " to handle text input");
    }
}

/// The canonical `PlatformInputHandler`: forwards to a view's `EntityInputHandler` methods.
/// A view released while its handler is still installed reads as a field with no text.
pub fn ElementInputHandler(comptime V: type) type {
    comptime assert_entity_input_handler(V);
    return struct {
        view: app_mod.WeakEntity(V),
        element_bounds: Bounds(Pixels),

        const Self = @This();

        /// Lives in the frame arena, like everything else built during a frame.
        pub fn new(element_bounds: Bounds(Pixels), view: app_mod.Entity(V)) *Self {
            const self = window_mod.frame_arena().create(Self) catch @panic("out of memory");
            self.* = .{ .view = view.downgrade(), .element_bounds = element_bounds };
            return self;
        }

        pub fn platform_input_handler(self: *Self) PlatformInputHandler {
            return .{ .ctx = self, .vtable = &vtable };
        }

        const vtable: PlatformInputHandler.VTable = .{
            .selected_text_range = selected_text_range,
            .marked_text_range = marked_text_range,
            .text_for_range = text_for_range,
            .replace_text_in_range = replace_text_in_range,
            .replace_and_mark_text_in_range = replace_and_mark_text_in_range,
            .unmark_text = unmark_text,
            .bounds_for_range = bounds_for_range,
            .character_index_for_point = character_index_for_point,
            .accepts_text_input = accepts_text_input,
            .paste = paste,
            .selection_bounds_for_range = selection_bounds_for_range,
            .set_selected_text_range = set_selected_text_range,
            .text_length_utf16 = text_length_utf16,
            .text_input_configuration = text_input_configuration,
            .text_input_editable_range = text_input_editable_range,
        };

        fn from(ctx: *anyopaque) *Self {
            return @ptrCast(@alignCast(ctx));
        }

        fn selected_text_range(ctx: *anyopaque, ignore_disabled_input: bool, window: *Window, cx: *App) ?UTF16Selection {
            const view = from(ctx).view.upgrade(cx) orelse return null;
            return view.update_in(window, cx, V.selected_text_range, .{ignore_disabled_input});
        }
        fn marked_text_range(ctx: *anyopaque, window: *Window, cx: *App) ?Range {
            const view = from(ctx).view.upgrade(cx) orelse return null;
            return view.update_in(window, cx, V.marked_text_range, .{});
        }
        fn text_for_range(ctx: *anyopaque, range: Range, adjusted: *?Range, window: *Window, cx: *App) ?[]const u8 {
            const view = from(ctx).view.upgrade(cx) orelse return null;
            return view.update_in(window, cx, V.text_for_range, .{ range, adjusted });
        }
        fn replace_text_in_range(ctx: *anyopaque, range: ?Range, text: []const u8, window: *Window, cx: *App) void {
            const view = from(ctx).view.upgrade(cx) orelse return;
            view.update_in(window, cx, V.replace_text_in_range, .{ range, text });
        }
        fn replace_and_mark_text_in_range(ctx: *anyopaque, range: ?Range, text: []const u8, new_selected: ?Range, window: *Window, cx: *App) void {
            const view = from(ctx).view.upgrade(cx) orelse return;
            view.update_in(window, cx, V.replace_and_mark_text_in_range, .{ range, text, new_selected });
        }
        fn unmark_text(ctx: *anyopaque, window: *Window, cx: *App) void {
            const view = from(ctx).view.upgrade(cx) orelse return;
            view.update_in(window, cx, V.unmark_text, .{});
        }
        fn bounds_for_range(ctx: *anyopaque, range: Range, window: *Window, cx: *App) ?Bounds(Pixels) {
            const self = from(ctx);
            const view = self.view.upgrade(cx) orelse return null;
            return view.update_in(window, cx, V.bounds_for_range, .{ range, self.element_bounds });
        }
        fn character_index_for_point(ctx: *anyopaque, point: Point(Pixels), window: *Window, cx: *App) ?usize {
            const view = from(ctx).view.upgrade(cx) orelse return null;
            return view.update_in(window, cx, V.character_index_for_point, .{point});
        }
        fn accepts_text_input(ctx: *anyopaque, window: *Window, cx: *App) bool {
            const view = from(ctx).view.upgrade(cx) orelse return false;
            if (!@hasDecl(V, "accepts_text_input")) return true;
            return view.update_in(window, cx, V.accepts_text_input, .{});
        }
        // The optional methods below use GPUI's trait defaults when the view does not define them.
        fn paste(ctx: *anyopaque, item: platform.ClipboardItem, window: *Window, cx: *App) void {
            const view = from(ctx).view.upgrade(cx) orelse return;
            if (@hasDecl(V, "paste")) {
                view.update_in(window, cx, V.paste, .{item});
            } else if (item.text()) |text| {
                view.update_in(window, cx, V.replace_text_in_range, .{ @as(?Range, null), text });
            }
        }
        fn selection_bounds_for_range(ctx: *anyopaque, range: Range, element_bounds: Bounds(Pixels), window: *Window, cx: *App) []const Bounds(Pixels) {
            const view = from(ctx).view.upgrade(cx) orelse return &.{};
            if (!@hasDecl(V, "selection_bounds_for_range")) return &.{};
            return view.update_in(window, cx, V.selection_bounds_for_range, .{ range, element_bounds });
        }
        fn set_selected_text_range(ctx: *anyopaque, range: Range, window: *Window, cx: *App) void {
            const view = from(ctx).view.upgrade(cx) orelse return;
            if (!@hasDecl(V, "set_selected_text_range")) return;
            view.update_in(window, cx, V.set_selected_text_range, .{range});
        }
        fn text_length_utf16(ctx: *anyopaque, window: *Window, cx: *App) ?usize {
            const view = from(ctx).view.upgrade(cx) orelse return null;
            if (!@hasDecl(V, "text_length_utf16")) return null;
            return view.update_in(window, cx, V.text_length_utf16, .{});
        }
        fn text_input_configuration(ctx: *anyopaque, window: *Window, cx: *App) platform.TextInputConfiguration {
            const view = from(ctx).view.upgrade(cx) orelse return .{};
            if (!@hasDecl(V, "text_input_configuration")) return .{};
            return view.update_in(window, cx, V.text_input_configuration, .{});
        }
        fn text_input_editable_range(ctx: *anyopaque, window: *Window, cx: *App) ?Range {
            const view = from(ctx).view.upgrade(cx) orelse return null;
            if (!@hasDecl(V, "text_input_editable_range")) return null;
            return view.update_in(window, cx, V.text_input_editable_range, .{});
        }
    };
}

/// UTF-16 length of UTF-8 text. Invalid sequences count as one replacement character per byte.
pub fn utf16_len(text: []const u8) usize {
    var count: usize = 0;
    var i: usize = 0;
    while (i < text.len) {
        const seq = std.unicode.utf8ByteSequenceLength(text[i]) catch {
            count += 1;
            i += 1;
            continue;
        };
        count += if (seq == 4) 2 else 1;
        i += seq;
    }
    return count;
}

test "utf16_len counts surrogate pairs as two" {
    try std.testing.expectEqual(@as(usize, 0), utf16_len(""));
    try std.testing.expectEqual(@as(usize, 3), utf16_len("abc"));
    try std.testing.expectEqual(@as(usize, 2), utf16_len("\u{e9}\u{4e2d}"));
    try std.testing.expectEqual(@as(usize, 3), utf16_len("a\u{1f600}"));
}
