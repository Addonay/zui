//! Retained popup panel. `build` borrows host state and builds ordinary children.
const e = @import("../elements/root.zig");
const runtime = @import("../app/runtime.zig");
const Window = @import("../app/window.zig").Window;
const platform = @import("../platform/root.zig");
const overlay = @import("overlay.zig");
const theme = @import("theme.zig");
const behavior = @import("behavior.zig");
pub const Popover = Panel(false);
pub const Modal = Panel(true);
pub const Dialog = Modal;
pub fn Panel(comptime modal: bool) type {
    return struct {
        const Self = @This();
        pub const Options = struct {
            key: u64,
            label: []const u8,
            width: f32 = 280,
            height: f32 = 180,
            trigger_width: f32 = 160,
            dismiss_outside: bool = !modal,
            context: ?*anyopaque = null,
            build: ?*const fn (?*anyopaque, *Window) e.Element = null,
            tokens: ?theme.Theme = null,
        };
        options: Options,
        overlay: overlay.State = .{},
        pressable: behavior.Pressable = .{},
        pub fn init(_: *runtime.Context(Self), options: Options) Self {
            return .{ .options = options, .overlay = .{ .modal = modal, .dismiss_outside = options.dismiss_outside } };
        }
        pub fn popupKey(self: *const Self) u64 { return platform.id.fromSrc(self.options.key, @src(), 0); }
        pub fn open(self: *Self, win: *Window) void { self.overlay.show(win); }
        pub fn close(self: *Self, win: *Window) void { self.overlay.close(win); }
        fn toggle(self: *Self, win: *Window) void { if (self.overlay.open) self.close(win) else self.open(win); }
        fn down(self: *Self, _: *Window, _: *runtime.Context(Self)) void { self.pressable.pressBegin(); }
        fn up(self: *Self, win: *Window, _: *runtime.Context(Self)) void {
            if (self.pressable.pressEnd(behavior.releaseInside(win))) self.toggle(win);
        }
        pub fn handleEvent(self: *Self, event: platform.Event, cx: *runtime.Context(Self)) bool {
            const win = cx.window orelse return false;
            if (event != .key) return false;
            if (event.key.pressed and event.key.key == .escape and self.overlay.open) { self.close(win); return true; }
            if (!self.overlay.open and self.pressable.keyEvent(event.key.key, event.key.pressed, event.key.repeat)) { self.open(win); return true; }
            return false;
        }
        fn semanticAction(raw: *anyopaque, _: @import("../a11y/root.zig").Request, raw_win: *anyopaque) void {
            const self: *Self = @ptrCast(@alignCast(raw));
            self.toggle(@ptrCast(@alignCast(raw_win)));
        }
        pub fn render(self: *Self, win: *Window, cx: *runtime.Context(Self)) e.Element {
            const t = self.options.tokens orelse theme.current();
            const handle = cx.focusHandle();
            if (handle.owner_store) |store| e.element.currentFrame().trackOwner(self, store, handle.id, handle.owner_generation);
            const trigger = e.div().keyed(self.options.key).w(self.options.trigger_width).h(t.button_h).bg(t.palette.surface).rounded(t.radii.md).withFocus(handle)
                .on_mouse_down(cx.listener(Self, down)).on_mouse_up(cx.listener(Self, up))
                .semantic(.{ .role = .button, .name = self.options.label, .controls = self.popupKey(), .states = .{ .expanded = self.overlay.open }, .actions = .{ .activate = true, .focus = true }, .handler = .{ .target = self, .call_fn = semanticAction } })
                .child(e.text(self.options.label, .{ .size = t.type_scale.body, .color = t.palette.fg }));
            if (self.overlay.open) {
                self.overlay.anchor_key = self.options.key;
                self.overlay.size = .{ .w = self.options.width, .h = self.options.height };
                self.overlay.placement = if (modal) .center else .bottom;
                var panel = e.div().keyed(self.popupKey()).bg(t.palette.surface_raised).rounded(t.radii.md).withFocus(handle)
                    .semantic(.{ .role = .dialog, .name = self.options.label, .states = .{ .modal = modal }, .labelled_by = self.options.key });
                if (self.options.build) |build| panel = panel.child(build(self.options.context, win));
                self.overlay.portal(win, handle, panel);
            }
            return trigger;
        }
    };
}
