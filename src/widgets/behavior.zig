//! Press/release activation semantics (gap report §5C).
//!
//! `Window.handleEvent` invokes a region's click listener on **press**, so
//! conventional button semantics (press-inside + release-inside = activate,
//! press-inside + release-outside = cancel) cannot use `on_click`. Widgets
//! built on this module attach `on_mouse_down` + `on_mouse_up` instead — the
//! window already arms pointer capture for regions with up/move listeners
//! and routes the release to the press source even outside its bounds — and
//! drive a `Pressable` through those two callbacks. Keyboard activation
//! (Enter/Space) converges on the same `activations` counter, so pointer,
//! keyboard, and (later) accessibility activation share one path.

const std = @import("std");
const platform = @import("../platform/root.zig");
const Window = @import("../app/window.zig").Window;

/// Effective visual state for theme lookup. The painter already highlights
/// hover via `hover_background`; this is the widget-owned half (pressed /
/// disabled need explicit colors because the painter has no notion of them).
pub const VisualState = enum { idle, hovered, pressed, disabled };

/// Presentation-independent bounded offset, paging, and scrollbar geometry.
pub const ScrollModel = @import("scroll_model.zig").ScrollModel;

pub const Pressable = struct {
    pressed: bool = false,
    hovered: bool = false,
    enabled: bool = true,
    /// Completed activations through every path (pointer + keyboard).
    /// Widgets mirror domain effects (clicks, toggles) off the `true`
    /// returns, not this counter; it exists for tests and diagnostics.
    activations: u64 = 0,

    /// Pointer went down inside the control. Ignored while disabled.
    pub fn pressBegin(self: *Pressable) void {
        if (!self.enabled) return;
        self.pressed = true;
    }

    /// Pointer released; `inside` is whether the release landed in the
    /// control (see `releaseInside`). Returns true exactly on
    /// press-inside/release-inside, and always clears the pressed latch so
    /// a press can never leak across a lost release.
    pub fn pressEnd(self: *Pressable, inside: bool) bool {
        defer self.pressed = false;
        if (!self.enabled) return false;
        if (self.pressed and inside) {
            return self.activate();
        }
        return false;
    }

    /// Capture cancelled (focus loss, unmount, teardown): drop the latch
    /// with no activation.
    pub fn cancel(self: *Pressable) void {
        self.pressed = false;
    }

    pub fn setHovered(self: *Pressable, hovered: bool) void {
        self.hovered = hovered;
    }

    pub fn setEnabled(self: *Pressable, enabled: bool) void {
        self.enabled = enabled;
        if (!enabled) self.pressed = false;
    }

    /// Keyboard half of the converged path: a non-repeat Enter/Space press
    /// activates exactly like a pointer release-inside. Returns true when
    /// the key was consumed as an activation.
    pub fn keyEvent(self: *Pressable, key: platform.event.Key, pressed: bool, repeat: bool) bool {
        if (!self.enabled) return false;
        if (!pressed or repeat) return false;
        if (key == .enter or key == .space) {
            return self.activate();
        }
        return false;
    }

    /// Single activation gate shared by pointer, keyboard and semantic actions.
    pub fn activate(self: *Pressable) bool {
        if (!self.enabled) return false;
        self.activations += 1;
        return true;
    }

    pub fn visual(self: *const Pressable) VisualState {
        if (!self.enabled) return .disabled;
        if (self.pressed) return .pressed;
        if (self.hovered) return .hovered;
        return .idle;
    }
};

/// Release-inside probe for `on_mouse_up` listeners. During the captured
/// region's up callback `Window.captured_mouse_region` still holds the
/// press source (the window clears it after dispatch) and
/// `pointer_position` is already the release point, so containment against
/// the source bounds answers inside/outside with no extra bookkeeping.
/// False when nothing captured the press (no press began here).
pub fn releaseInside(win: *const Window) bool {
    const captured = win.captured_mouse_region orelse return false;
    return captured.bounds.contains(win.pointer_position);
}

test "press-inside release-inside activates, release-outside cancels" {
    const t = std.testing;
    var p = Pressable{};
    p.pressBegin();
    try t.expect(p.pressEnd(true));
    try t.expectEqual(@as(u64, 1), p.activations);

    p.pressBegin();
    try t.expect(!p.pressEnd(false));
    try t.expectEqual(@as(u64, 1), p.activations);
    // Latch cleared: a stray release never activates.
    try t.expect(!p.pressEnd(true));
    try t.expectEqual(@as(u64, 1), p.activations);
}

test "disabled pressable ignores every path" {
    const t = std.testing;
    var p = Pressable{ .enabled = false };
    p.pressBegin();
    try t.expect(!p.pressEnd(true));
    try t.expect(!p.keyEvent(.enter, true, false));
    try t.expectEqual(@as(u64, 0), p.activations);
    try t.expectEqual(VisualState.disabled, p.visual());
}

test "keyboard converges on the pointer activation path" {
    const t = std.testing;
    var p = Pressable{};
    try t.expect(p.keyEvent(.enter, true, false));
    try t.expect(p.keyEvent(.space, true, false));
    try t.expect(!p.keyEvent(.space, true, true)); // repeat: no double fire
    try t.expect(!p.keyEvent(.space, false, false)); // release: nothing
    try t.expect(!p.keyEvent(.a, true, false));
    try t.expectEqual(@as(u64, 2), p.activations);
}

test "cancel drops the latch without activating" {
    const t = std.testing;
    var p = Pressable{};
    p.pressBegin();
    try t.expectEqual(VisualState.pressed, p.visual());
    p.cancel();
    try t.expect(!p.pressEnd(true));
    try t.expectEqual(@as(u64, 0), p.activations);
}

test "press/release through a real Window honors inside/outside" {
    // Drives synthetic events through App/Window dispatch using only the
    // existing capture primitives: press arms capture (region carries an
    // up listener), release-outside still reaches the source, and the
    // widget-side inside probe decides activate vs cancel. Notably the
    // press-time `listener` (on_click) is never attached — nothing fires
    // on press.
    const t = std.testing;
    const App = @import("../app/app.zig").App;
    const elements = @import("../elements/root.zig");

    var app = try App.initHeadless(t.allocator);
    defer app.deinit();
    const win = try app.openWindow(.{}, struct {
        fn noop(_: *Window, _: *(@import("../gpu/root.zig").Scene)) void {}
    }.noop);

    var pressable = Pressable{};
    const S = struct {
        var state: *Pressable = undefined;
        fn down(_: *anyopaque, _: *const elements.element.ListenerPayload, raw_window: *anyopaque) void {
            const w: *Window = @ptrCast(@alignCast(raw_window));
            _ = w;
            state.pressBegin();
        }
        fn up(_: *anyopaque, _: *const elements.element.ListenerPayload, raw_window: *anyopaque) void {
            const w: *Window = @ptrCast(@alignCast(raw_window));
            _ = state.pressEnd(releaseInside(w));
        }
    };
    S.state = &pressable;
    var marker: u8 = 0;
    win.ui_frame.region_count = 1;
    win.ui_frame.regions[0] = .{
        .bounds = .{ .x = 0, .y = 0, .w = 50, .h = 50 },
        .mouse_down_listener = .{ .target = &marker, .call_fn = S.down },
        .mouse_up_listener = .{ .target = &marker, .call_fn = S.up },
    };

    const press = struct {
        fn at(w: *Window, x: f32, y: f32) void {
            w.handleEvent(.{ .mouse = .{ .pos = .{ .x = x, .y = y }, .button = .left, .pressed = true } });
        }
        fn release(w: *Window, x: f32, y: f32) void {
            w.handleEvent(.{ .mouse = .{ .pos = .{ .x = x, .y = y }, .button = .left, .pressed = false } });
        }
    };
    press.at(win, 10, 10);
    try t.expect(pressable.pressed);
    press.release(win, 10, 10);
    try t.expectEqual(@as(u64, 1), pressable.activations);

    press.at(win, 10, 10);
    press.release(win, 900, 900);
    try t.expectEqual(@as(u64, 1), pressable.activations);
    try t.expect(!pressable.pressed);
}
