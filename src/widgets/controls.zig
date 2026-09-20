//! Retained controls composed from behavior, theme and ordinary elements.
//! Create with cx.new(Button, .{ .key = stable_key, .label = "Save" }).
const std = @import("std");
const e = @import("../elements/root.zig");
const runtime = @import("../app/runtime.zig");
const Window = @import("../app/window.zig").Window;
const platform = @import("../platform/root.zig");
const a11y = @import("../a11y/root.zig");
const behavior = @import("behavior.zig");
const theme = @import("theme.zig");

pub const Button = Control(.button);
pub const Checkbox = Control(.checkbox);
pub const Switch = Control(.switch_control);
pub const Slider = Control(.slider);
pub const Progress = Control(.progress);

pub fn Control(comptime role: a11y.Role) type {
    return struct {
        const Self = @This();
        pub const Options = struct {
            key: u64,
            label: []const u8,
            disabled: bool = false,
            checked: bool = false,
            value: f64 = 0,
            min: f64 = 0,
            max: f64 = 1,
            step: f64 = 0.1,
            width: f32 = 160,
            tokens: ?theme.Theme = null,
            /// Optional application callback. Borrowed, must outlive control.
            on_change: ?e.Listener = null,
        };
        options: Options,
        pressable: behavior.Pressable = .{},
        checked: bool = false,
        value: f64 = 0,
        bounds: @import("../core/geometry.zig").Rect = .{},

        pub fn init(_: *runtime.Context(Self), options: Options) Self {
            std.debug.assert(options.key != 0);
            std.debug.assert(std.math.isFinite(options.min) and std.math.isFinite(options.max) and options.max > options.min);
            std.debug.assert(std.math.isFinite(options.step) and options.step > 0);
            return .{ .options = options, .checked = options.checked, .value = if (std.math.isFinite(options.value)) std.math.clamp(options.value, options.min, options.max) else options.min, .pressable = .{ .enabled = !options.disabled } };
        }
        fn changed(self: *Self, win: *Window) void {
            win.requestRender();
            if (self.options.on_change) |callback| callback.call(win);
        }
        fn activate(self: *Self, win: *Window) void {
            if (role == .checkbox or role == .switch_control) self.checked = !self.checked;
            self.changed(win);
        }
        pub fn setValue(self: *Self, value: f64, win: *Window) void {
            if (self.options.disabled or !std.math.isFinite(value)) return;
            const opts = self.options;
            const snapped = opts.min + @round((value - opts.min) / opts.step) * opts.step;
            const next = std.math.clamp(snapped, opts.min, opts.max);
            if (next != self.value) {
                self.value = next;
                self.changed(win);
            }
        }
        fn updateBounds(self: *Self, win: *Window, cx: *runtime.Context(Self)) void {
            self.bounds = .{};
            for (win.ui_frame.regions[0..win.ui_frame.region_count]) |r| if (r.focus) |f| {
                if (f.eql(cx.focusHandle())) {
                    self.bounds = r.bounds;
                    return;
                }
            };
        }
        fn pointerValue(self: *Self, win: *Window) void {
            if (self.bounds.w <= 0) return;
            const fraction = std.math.clamp((win.pointer_position.x - self.bounds.x) / self.bounds.w, 0, 1);
            self.setValue(self.options.min + @as(f64, fraction) * (self.options.max - self.options.min), win);
        }
        fn down(self: *Self, win: *Window, cx: *runtime.Context(Self)) void {
            self.pressable.setEnabled(!self.options.disabled);
            if (role == .progress) return;
            self.updateBounds(win, cx);
            self.pressable.pressBegin();
            if (role == .slider and self.pressable.pressed) self.pointerValue(win);
            cx.notify();
        }
        fn move(self: *Self, win: *Window, cx: *runtime.Context(Self)) void {
            self.updateBounds(win, cx);
            self.pressable.setHovered(self.bounds.contains(win.pointer_position));
            if (role == .slider and self.pressable.pressed) self.pointerValue(win);
            cx.notify();
        }
        fn up(self: *Self, win: *Window, cx: *runtime.Context(Self)) void {
            self.pressable.setEnabled(!self.options.disabled);
            // Current painted geometry, not the old captured rectangle.
            self.updateBounds(win, cx);
            if (self.pressable.pressEnd(behavior.releaseInside(win) and self.bounds.contains(win.pointer_position))) {
                if (role != .slider and role != .progress) self.activate(win);
            }
            cx.notify();
        }
        fn semanticAction(raw: *anyopaque, request: a11y.Request, raw_win: *anyopaque) void {
            const self: *Self = @ptrCast(@alignCast(raw));
            const win: *Window = @ptrCast(@alignCast(raw_win));
            self.pressable.setEnabled(!self.options.disabled);
            switch (request.action) {
                .activate => if (role != .progress and role != .slider) {
                    if (self.pressable.activate()) self.activate(win);
                },
                .increment => if (role == .slider) self.setValue(self.value + self.options.step, win),
                .decrement => if (role == .slider) self.setValue(self.value - self.options.step, win),
                .set_value => if (role == .slider) self.setValue(request.value, win),
                .set_text_selection => {},
                .focus => {},
            }
        }
        pub fn handleEvent(self: *Self, event: platform.Event, cx: *runtime.Context(Self)) bool {
            self.pressable.setEnabled(!self.options.disabled);
            if (event == .window) {
                if (event.window == .unfocused or event.window == .close_requested or event.window == .cancelled) self.pressable.cancel();
                return false;
            }
            if (event != .key or self.options.disabled or role == .progress) return false;
            const key = event.key;
            if (key.modifiers.ctrl or key.modifiers.alt or key.modifiers.super) return false;
            const win = cx.window orelse return false;
            if (role == .slider) {
                if (!key.pressed) return false;
                switch (key.key) {
                    .left, .down => self.setValue(self.value - self.options.step, win),
                    .right, .up => self.setValue(self.value + self.options.step, win),
                    .home => self.setValue(self.options.min, win),
                    .end => self.setValue(self.options.max, win),
                    else => return false,
                }
                cx.notify();
                return true;
            }
            const key_result = self.pressable.keyEventResult(key.key, key.pressed, key.repeat);
            if (key_result == .activated) {
                self.activate(win);
                cx.notify();
            }
            return key_result != .ignored;
        }
        pub fn render(self: *Self, win: *Window, cx: *runtime.Context(Self)) e.Element {
            const t = self.options.tokens orelse theme.current();
            const focus = cx.focusHandle();
            self.updateBounds(win, cx);
            self.pressable.setEnabled(!self.options.disabled);
            self.pressable.setHovered(self.bounds.contains(win.pointer_position));
            const focused = win.focused.eql(focus);
            if (!win.left_button_down or !focused) self.pressable.cancel();
            var root = e.div().keyed(self.options.key).w(self.options.width).h(t.button_h).flex_row().gap(t.spacing.sm).items_center().px(t.spacing.sm).rounded(t.radii.md)
                .bg(theme.stateBg(t, t.palette.surface, self.pressable.visual())).border_color(if (focused) t.palette.focus_ring else t.palette.border);
            e.element.currentFrame().nodes[root.index].style.border_width = if (focused) t.focus_ring_width else 1;
            if (role == .checkbox or role == .switch_control) {
                var mark = e.div().w(if (role == .switch_control) 32 else 18).h(18).rounded(if (role == .switch_control) t.radii.full else t.radii.sm).bg(if (self.checked) t.palette.accent else t.palette.track);
                if (self.checked) mark = mark.child(e.div().size(8).bg(t.palette.accent_fg).rounded(t.radii.full));
                root = root.child(mark);
            }
            if (role == .slider or role == .progress) {
                const fraction: f32 = @floatCast((self.value - self.options.min) / (self.options.max - self.options.min));
                const width = @max(0, self.options.width - 2 * t.spacing.sm);
                root = root.child(e.div().w(width).h(6).rounded(t.radii.full).bg(t.palette.track).child(e.div().w(width * fraction).h(6).rounded(t.radii.full).bg(t.palette.accent)));
            } else root = root.child(e.text(self.options.label, .{ .size = t.type_scale.body, .color = if (self.options.disabled) t.palette.muted else t.palette.fg }));
            const frame = e.element.currentFrame();
            if (focus.owner_store) |store| frame.trackOwner(self, store, focus.id, focus.owner_generation);
            root = root.withFocus(focus).semantic(.{
                .role = role,
                .name = self.options.label,
                .states = .{ .disabled = self.options.disabled, .checked = if (role == .checkbox or role == .switch_control) self.checked else null, .focused = focused, .read_only = role == .progress },
                .value = if (role == .slider or role == .progress) .{ .current = self.value, .min = self.options.min, .max = self.options.max, .step = self.options.step } else null,
                .actions = .{ .activate = role == .button or role == .checkbox or role == .switch_control, .focus = true, .increment = role == .slider, .decrement = role == .slider, .set_value = role == .slider },
                .handler = .{ .target = self, .call_fn = semanticAction },
            });
            if (role != .progress) root = root.on_mouse_down(cx.listener(Self, down)).on_mouse_up(cx.listener(Self, up)).on_mouse_move(cx.listener(Self, move)).cursor_pointer();
            return root;
        }
    };
}
