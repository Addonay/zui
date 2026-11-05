//! Port of GPUI `window/prompts.rs`: prompts shown inside the window.
//!
//! `Window.prompt` shows a message with answer buttons. An answer is delivered to a listener,
//! as GPUI delivers it to a `oneshot::Receiver<usize>`: ZUI has no await, so the caller passes
//! a plain function (or a `cx.listener`) and gets `PromptResponse` with the button's index.
//!
//! Linux has no native prompt (GPUI's `PlatformWindow::prompt` returns nothing there), so the
//! default builder is `fallback_prompt_renderer`, an entity drawn over the window. An app can
//! replace it with `App.set_prompt_builder`.
//!
//! Keyboard, when the fallback has focus: Left and Right (or Tab and Shift-Tab) move the
//! selection, Enter or Space chooses the selected button, and Escape chooses the cancel button
//! if there is one. GPUI's fallback handles none of these keys; its prompt has focus but no
//! bindings. Escape is the convention of the native prompts (GPUI's `PromptButton::is_cancel`).

const std = @import("std");
const app_mod = @import("../app.zig");
const window_mod = @import("../window.zig");
const platform_mod = @import("../platform.zig");
const color = @import("../color.zig");
const div_mod = @import("../elements/div.zig");
const interactive = @import("../interactive.zig");
const view_mod = @import("../view.zig");

const App = app_mod.App;
const Context = app_mod.Context;
const Window = window_mod.Window;
const WindowId = window_mod.WindowId;
const FocusHandle = window_mod.FocusHandle;
const FocusId = window_mod.FocusId;
const AnyView = view_mod.AnyView;
const Div = div_mod.Div;
const ClickEvent = interactive.ClickEvent;
const KeyDownEvent = interactive.KeyDownEvent;

pub const PromptLevel = platform_mod.PromptLevel;
pub const PromptButton = platform_mod.PromptButton;
pub const Listener = app_mod.Listener;

/// The event emitted when an answer is chosen (GPUI `PromptResponse`). `index` is the position
/// of the chosen button in the answers passed to `Window.prompt`.
pub const PromptResponse = struct {
    index: usize,
};

/// What a prompt builder returns: the view drawn over the window, and the subscription that
/// hears its answer (GPUI `RenderablePromptHandle`).
pub const RenderablePromptHandle = struct {
    view: AnyView,
    subscription: app_mod.Subscription,
};

/// The prompt a window is showing. Its buttons' labels live in `arena`, which is freed when the
/// prompt closes, after its view is released.
pub const ActivePrompt = struct {
    handle: RenderablePromptHandle,
    listener: Listener(PromptResponse),
    previous_focus: ?FocusId,
    arena: *std.heap.ArenaAllocator,
};

/// Builds the prompt a window shows (GPUI `PromptBuilder`). The strings and buttons are valid
/// until the prompt is answered or replaced.
pub const PromptBuilder = *const fn (
    level: PromptLevel,
    message: []const u8,
    detail: ?[]const u8,
    answers: []const PromptButton,
    handle: PromptHandle,
    window: *Window,
    app: *App,
) RenderablePromptHandle;

/// Given to a prompt builder so it can deliver the answer (GPUI `PromptHandle`).
pub const PromptHandle = struct {
    window_id: WindowId,

    /// Shows `entity` (a view with `Event = PromptResponse` and a `focus_handle` method) as the
    /// prompt, focuses it, and delivers its answers (GPUI `PromptHandle::with_view`).
    pub fn with_view(self: PromptHandle, entity: anytype, window: *Window, app: *App) RenderablePromptHandle {
        const V = @TypeOf(entity).Type;
        if (V.Event != PromptResponse) @compileError("a prompt view must emit PromptResponse");
        const focus = V.focus_handle(entity.read(app));
        const subscription = app.add_event_listener(entity.entity_id(), app_mod.type_id(PromptResponse), self.window_id, on_response);
        window.focus(focus);
        return .{ .view = AnyView.from(entity), .subscription = subscription };
    }
};

/// The answer arrived from the view of the window's open prompt. Stale answers, from a prompt
/// already replaced, are ignored.
fn on_response(app: *App, from: app_mod.EntityId, ctx: usize, payload: ?*const anyopaque) bool {
    const win = app.window_by_id(@intCast(ctx)) orelse return false;
    const active = win.prompt_ orelse return false;
    if (active.handle.view.entity_id != from) return false;
    const response: *const PromptResponse = @ptrCast(@alignCast(payload.?));

    // Close first: the listener may open another prompt.
    win.prompt_ = null;
    if (active.previous_focus) |id| win.focus(.{ .id = id }) else win.blur();
    app.release_entity(from);
    active.listener.call(response, win, app);
    free_arena(win.allocator, active.arena);
    win.refresh();
    return false;
}

pub fn free_arena(gpa: std.mem.Allocator, arena: *std.heap.ArenaAllocator) void {
    arena.deinit();
    gpa.destroy(arena);
}

/// Copies the answers into `arena`. Accepts `&.{ "OK", "Cancel" }` (read as GPUI reads `&str`),
/// `&.{ .{ .ok = "OK" } }` and arrays or slices of either.
pub fn copy_buttons(arena: std.mem.Allocator, answers: anytype) []PromptButton {
    const A = @TypeOf(answers);
    switch (@typeInfo(A)) {
        .pointer => |p| if (p.size == .one) {
            const child = @typeInfo(p.child);
            if (child == .@"struct" and child.@"struct".is_tuple) {
                const out = arena.alloc(PromptButton, child.@"struct".field_names.len) catch oom();
                inline for (child.@"struct".field_names, 0..) |name, i| out[i] = copy_button(arena, @field(answers.*, name));
                return out;
            }
            return copy_buttons(arena, answers.*);
        },
        else => {},
    }
    const out = arena.alloc(PromptButton, answers.len) catch oom();
    for (answers, out) |answer, *slot| slot.* = copy_button(arena, answer);
    return out;
}

fn copy_button(arena: std.mem.Allocator, answer: anytype) PromptButton {
    if (@TypeOf(answer) == PromptButton) return switch (answer) {
        .ok => |l| .{ .ok = dupe(arena, l) },
        .cancel => |l| .{ .cancel = dupe(arena, l) },
        .other => |l| .{ .other = dupe(arena, l) },
    };
    return PromptButton.from(dupe(arena, answer));
}

fn dupe(arena: std.mem.Allocator, text: []const u8) []const u8 {
    return arena.dupe(u8, text) catch oom();
}

fn oom() noreturn {
    @panic("out of memory");
}

/// GPUI's default prompt: a message with its buttons, drawn over the window. Used on Linux.
pub const FallbackPromptRenderer = struct {
    pub const Event = PromptResponse;

    level: PromptLevel,
    message: []const u8,
    detail: ?[]const u8,
    actions: []const PromptButton,
    focus: FocusHandle,
    /// The button Enter chooses. Left, Right, Tab and Shift-Tab move it.
    selected: usize = 0,

    pub fn focus_handle(self: *const FallbackPromptRenderer) FocusHandle {
        return self.focus;
    }

    pub fn render(self: *FallbackPromptRenderer, _: *Window, cx: *Context(FallbackPromptRenderer)) *Div {
        var prompt = div_mod.div()
            .cursor_default()
            .track_focus(&self.focus)
            .on_key_down(cx.listener(FallbackPromptRenderer.on_key_down))
            .w_72()
            .bg(color.white())
            .rounded_lg()
            .overflow_hidden()
            .p_3()
            .child(div_mod.div()
                .w_full()
                .flex()
                .flex_row()
                .justify_around()
                .child(div_mod.div().overflow_hidden().child(self.message)));

        if (self.detail) |detail| {
            prompt = prompt.child(div_mod.div()
                .w_full()
                .flex()
                .flex_row()
                .justify_around()
                .text_sm()
                .mb_2()
                .child(div_mod.div().child(detail)));
        }

        for (self.actions, 0..) |action, ix| {
            var row = div_mod.div()
                .flex()
                .flex_row()
                .justify_around()
                .border_1()
                .border_color(color.opaque_grey(0.2, 0.5))
                .mt_1()
                .rounded_xs()
                .cursor_pointer()
                .text_sm()
                .child(action.label())
                .id(ix)
                .on_click(cx.listener_with(ix, FallbackPromptRenderer.on_button));
            // The keyboard selection shows as a shaded button; GPUI's fallback shows none.
            if (ix == self.selected) row = row.bg(color.opaque_grey(0.9, 1.0));
            prompt = prompt.child(row);
        }

        return div_mod.div()
            .size_full()
            .child(div_mod.div()
                .size_full()
                .bg(color.opaque_grey(0.5, 0.6))
                .absolute()
                .top_0()
                .left_0()
                .occlude())
            .child(div_mod.div()
                .size_full()
                .absolute()
                .top_0()
                .left_0()
                .flex()
                .flex_col()
                .justify_around()
                .child(div_mod.div()
                    .w_full()
                    .flex()
                    .flex_row()
                    .justify_around()
                    .child(prompt)));
    }

    fn on_button(self: *FallbackPromptRenderer, ix: usize, _: *const ClickEvent, window: *Window, cx: *Context(FallbackPromptRenderer)) void {
        _ = self;
        window.stop_propagation();
        cx.emit(.{ .index = ix });
    }

    fn on_key_down(self: *FallbackPromptRenderer, event: *const KeyDownEvent, window: *Window, cx: *Context(FallbackPromptRenderer)) void {
        const keystroke = event.keystroke;
        if (keystroke.modifiers.control or keystroke.modifiers.platform or keystroke.modifiers.alt) return;
        const count = self.actions.len;
        if (count == 0) return;
        const key = keystroke.key;

        if (std.mem.eql(u8, key, "escape")) {
            for (self.actions, 0..) |action, ix| if (action.is_cancel()) {
                window.stop_propagation();
                cx.emit(.{ .index = ix });
                return;
            };
            return;
        }
        if (std.mem.eql(u8, key, "enter") or std.mem.eql(u8, key, "space") or std.mem.eql(u8, key, " ")) {
            window.stop_propagation();
            cx.emit(.{ .index = self.selected });
            return;
        }

        const backward = std.mem.eql(u8, key, "left") or (std.mem.eql(u8, key, "tab") and keystroke.modifiers.shift);
        const forward = std.mem.eql(u8, key, "right") or (std.mem.eql(u8, key, "tab") and !keystroke.modifiers.shift);
        if (!backward and !forward) return;
        self.selected = if (backward) (self.selected + count - 1) % count else (self.selected + 1) % count;
        window.stop_propagation();
        cx.notify();
    }
};

/// The default prompt builder: shows a `FallbackPromptRenderer` over the window.
pub fn fallback_prompt_renderer(
    level: PromptLevel,
    message: []const u8,
    detail: ?[]const u8,
    answers: []const PromptButton,
    handle: PromptHandle,
    window: *Window,
    app: *App,
) RenderablePromptHandle {
    const entity = app.new(FallbackPromptRenderer{
        .level = level,
        .message = message,
        .detail = detail,
        .actions = answers,
        .focus = app.focus_handle(),
    });
    return handle.with_view(entity, window, app);
}
