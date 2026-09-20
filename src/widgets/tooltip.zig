//! Passive hover/focus tooltip. Uses a one-shot render deadline, not animation.
const e = @import("../elements/root.zig");
const runtime = @import("../app/runtime.zig");
const Window = @import("../app/window.zig").Window;
const platform = @import("../platform/root.zig");
const ov = @import("overlay.zig");
const theme = @import("theme.zig");
pub const Tooltip = struct {
    pub const Options = struct { key: u64, label: []const u8, tip: []const u8, delay_ms: i64 = 500, width: f32 = 160, tip_width: f32 = 220 };
    options: Options,
    overlay: ov.State = .{ .capture_focus = false },
    hovered: bool = false,
    deadline: ?i64 = null,
    pub fn init(_: *runtime.Context(Tooltip), options: Options) Tooltip {
        return .{ .options = options };
    }
    pub fn tooltipKey(self: *const Tooltip) u64 {
        return platform.id.fromSrc(self.options.key, @src(), 0);
    }
    /// Deterministic clock seam, also used by render with the monotonic clock.
    pub fn updateAt(self: *Tooltip, win: *Window, active: bool, now: i64) void {
        if (!active) {
            self.deadline = null;
            self.overlay.close(win);
            return;
        }
        if (self.deadline == null) self.deadline = now + @max(0, self.options.delay_ms);
        if (now >= self.deadline.?) self.overlay.open = true else win.requestRenderAt(self.deadline.?);
    }
    pub fn handleEvent(self: *Tooltip, event: platform.Event, cx: *runtime.Context(Tooltip)) bool {
        const win = cx.window orelse return false;
        if (event == .mouse) {
            self.hovered = ov.bounds(win, self.options.key).contains(event.mouse.pos);
            if (!self.hovered) self.updateAt(win, false, win.timeMs());
        }
        if (event == .key and event.key.key == .escape) {
            self.overlay.close(win);
            self.deadline = null;
        }
        return false;
    }
    pub fn render(self: *Tooltip, win: *Window, cx: *runtime.Context(Tooltip)) e.Element {
        const t = theme.current();
        const handle = cx.focusHandle();
        const frame = e.element.currentFrame();
        if (frame.observer_count < frame.observers.len) {
            frame.observers[frame.observer_count] = handle;
            frame.observer_count += 1;
        }
        self.updateAt(win, self.hovered or win.focused.eql(handle), win.timeMs());
        const trigger = e.div().keyed(self.options.key).w(self.options.width).h(t.button_h).withFocus(handle)
            .semantic(.{ .role = .label, .name = self.options.label, .described_by = if (self.overlay.open) self.tooltipKey() else 0 })
            .child(e.text(self.options.label, .{ .size = t.type_scale.body, .color = t.palette.fg }));
        if (self.overlay.open) {
            self.overlay.anchor_key = self.options.key;
            self.overlay.size = .{ .w = self.options.tip_width, .h = t.button_h };
            const panel = e.div().keyed(self.tooltipKey()).bg(t.palette.surface_raised).rounded(t.radii.sm)
                .semantic(.{ .role = .tooltip, .name = self.options.tip })
                .child(e.text(self.options.tip, .{ .size = t.type_scale.label, .color = t.palette.fg }));
            self.overlay.portal(win, handle, panel);
        }
        return trigger;
    }
};
