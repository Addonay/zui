//! Retained vertical scroll container. Create with cx.new(ScrollArea, options).
//! `build` runs each frame and returns arbitrary ordinary element children.
//! The host supplies viewport width/height (update options on host resize).
//! Content is naturally measured; use definite heights, not flex-grow, for
//! overflow. Wheel units follow ScrollEvent: positive dy is up, fractional
//! lines are preserved. No momentum is synthesized on top of native input.
const std = @import("std");
const e = @import("../elements/root.zig");
const runtime = @import("../app/runtime.zig");
const Window = @import("../app/window.zig").Window;
const platform = @import("../platform/root.zig");
const theme = @import("theme.zig");
const a11y = @import("../a11y/root.zig");
const ScrollModel = @import("scroll_model.zig").ScrollModel;

pub const ScrollArea = struct {
    pub const Options = struct {
        key: u64,
        label: []const u8 = "Scroll area",
        width: f32 = 300,
        height: f32 = 300,
        line_height: f64 = 32,
        /// Contain suppresses edge chaining; auto passes remaining delta out.
        chaining: enum { auto, contain } = .auto,
        tokens: ?theme.Theme = null,
        context: ?*anyopaque = null,
        build: ?*const fn (?*anyopaque, *Window) e.Element = null,
    };
    options: Options,
    model: ScrollModel = .{},
    dragging: bool = false,
    drag_grab: f64 = 0,

    pub fn init(_: *runtime.Context(ScrollArea), options: Options) ScrollArea {
        return fromOptions(options);
    }
    pub fn fromOptions(options: Options) ScrollArea {
        std.debug.assert(options.key != 0);
        std.debug.assert(std.math.isFinite(options.width) and options.width >= 0);
        std.debug.assert(std.math.isFinite(options.height) and options.height >= 0);
        std.debug.assert(std.math.isFinite(options.line_height) and options.line_height > 0);
        return .{ .options = options };
    }
    pub fn handleEvent(self: *ScrollArea, ev: platform.Event, cx: *runtime.Context(ScrollArea)) bool {
        return self.event(ev, cx.window orelse return false);
    }
    pub fn event(self: *ScrollArea, ev: platform.Event, win: *Window) bool {
        if (ev == .window) {
            if (ev.window == .unfocused or ev.window == .close_requested) self.dragging = false;
            return false;
        }
        if (ev != .key or !ev.key.pressed) return false;
        if (ev.key.modifiers.ctrl or ev.key.modifiers.alt or ev.key.modifiers.super) return false;
        if (ev.key.key == .space) {
            self.model.page(if (ev.key.modifiers.shift) .up else .down);
        } else if (!self.model.key(ev.key.key, self.options.line_height)) return false;
        win.requestRender();
        return true;
    }
    fn listener(self: *ScrollArea, comptime callback: anytype) e.Listener {
        return .{ .target = self, .call_fn = callback };
    }
    fn wheel(raw: *anyopaque, _: *const e.element.ListenerPayload, raw_win: *anyopaque) void {
        const self: *ScrollArea = @ptrCast(@alignCast(raw));
        const win: *Window = @ptrCast(@alignCast(raw_win));
        const scroll = win.scrollEvent();
        const remainder = self.model.scroll(-@as(f64, scroll.dy) * self.options.line_height);
        if (self.options.chaining == .auto) win.chainScroll(scroll.dx, @floatCast(-remainder / self.options.line_height));
        win.requestRender();
    }
    fn trackBounds(self: *ScrollArea, win: *Window) @import("../core/geometry.zig").Rect {
        for (win.ui_frame.nodes[0..win.ui_frame.node_count]) |node| {
            if (node.stable_key == self.trackKey()) return node.bounds;
        }
        return .{};
    }
    fn down(raw: *anyopaque, _: *const e.element.ListenerPayload, raw_win: *anyopaque) void {
        const self: *ScrollArea = @ptrCast(@alignCast(raw));
        const win: *Window = @ptrCast(@alignCast(raw_win));
        const bounds = self.trackBounds(win);
        const thumb = self.model.thumb(bounds.h, self.minimumThumb());
        const y: f64 = win.pointer_position.y - bounds.y;
        self.dragging = true;
        self.drag_grab = if (y >= thumb.start and y <= thumb.start + thumb.length) y - thumb.start else thumb.length / 2;
        self.drag(win);
    }
    fn move(raw: *anyopaque, _: *const e.element.ListenerPayload, raw_win: *anyopaque) void {
        const self: *ScrollArea = @ptrCast(@alignCast(raw));
        const win: *Window = @ptrCast(@alignCast(raw_win));
        if (self.dragging and win.left_button_down) self.drag(win);
    }
    fn up(raw: *anyopaque, _: *const e.element.ListenerPayload, _: *anyopaque) void {
        const self: *ScrollArea = @ptrCast(@alignCast(raw));
        self.dragging = false;
    }
    fn drag(self: *ScrollArea, win: *Window) void {
        const bounds = self.trackBounds(win);
        const thumb = self.model.thumb(bounds.h, self.minimumThumb());
        if (thumb.travel <= 0) return;
        const fraction = (@as(f64, win.pointer_position.y - bounds.y) - self.drag_grab) / thumb.travel;
        _ = self.model.jump(fraction * self.model.maxOffset());
        win.requestRender();
    }
    pub fn trackKey(self: *const ScrollArea) u64 {
        return platform.id.fromSrc(self.options.key, @src(), 0);
    }
    fn minimumThumb(self: *const ScrollArea) f64 {
        return (self.options.tokens orelse theme.current()).spacing.lg;
    }
    fn semanticAction(raw: *anyopaque, request: a11y.Request, raw_win: *anyopaque) void {
        const self: *ScrollArea = @ptrCast(@alignCast(raw));
        const win: *Window = @ptrCast(@alignCast(raw_win));
        switch (request.action) {
            .increment => _ = self.model.scroll(self.model.viewport),
            .decrement => _ = self.model.scroll(-self.model.viewport),
            .set_value => _ = self.model.jump(request.value),
            else => {},
        }
        win.requestRender();
    }
    pub fn render(self: *ScrollArea, win: *Window, cx: *runtime.Context(ScrollArea)) e.Element {
        const content = if (self.options.build) |build| build(self.options.context, win) else e.div();
        const size = e.layout.measure(e.element.currentFrame(), content.index);
        self.model.resize(self.options.height, size.h);
        const viewport = e.div().w_full().h(self.options.height).scroll_y(@floatCast(self.model.offset)).child(content);
        return self.renderViewport(win, cx.focusHandle(), viewport, .group);
    }
    /// Shared presentation/input for VirtualList. Content coordinates are
    /// already viewport-local; no giant logical offset enters f32 layout.
    pub fn renderViewport(self: *ScrollArea, win: *Window, focus: e.FocusHandle, viewport: e.Element, role: a11y.Role) e.Element {
        const t = self.options.tokens orelse theme.current();
        if (!win.left_button_down) self.dragging = false;
        const frame = e.element.currentFrame();
        if (focus.owner_store) |store| frame.trackOwner(self, store, focus.id, focus.owner_generation);
        var root = e.div().keyed(self.options.key).w(self.options.width).h(self.options.height)
            .bg(t.palette.surface).withFocus(focus).on_scroll(self.listener(wheel))
            .semantic(.{ .role = role, .name = self.options.label, .states = .{ .focused = win.focused.eql(focus), .scrollable = self.model.maxOffset() > 0 }, .value = .{ .current = self.model.offset, .max = self.model.maxOffset(), .step = self.options.line_height }, .actions = .{ .focus = true, .increment = true, .decrement = true, .set_value = true }, .handler = .{ .target = self, .call_fn = semanticAction } });
        if (win.focused.eql(focus)) {
            root = root.border_color(t.palette.focus_ring);
            frame.nodes[root.index].style.border_width = t.focus_ring_width;
        }
        root = root.child(viewport);
        if (self.model.maxOffset() > 0 and self.options.height > 0) {
            const thumb = self.model.thumb(self.options.height, self.minimumThumb());
            const width = t.spacing.md;
            root = root.child(e.div().keyed(self.trackKey()).absolute().right(0).top(0).w(width).h(self.options.height)
                .bg(t.palette.track).withFocus(focus).on_mouse_down(self.listener(down)).on_mouse_move(self.listener(move)).on_mouse_up(self.listener(up))
                .child(e.div().absolute().top(@floatCast(thumb.start)).w(width).h(@floatCast(thumb.length)).rounded(t.radii.full)
                .bg(if (self.dragging) t.palette.accent else t.palette.muted).hover_bg(t.palette.accent)));
        }
        return root;
    }
};
