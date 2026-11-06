//! Port of GPUI `view.rs`: entities rendered as elements (`AnyView`).

const std = @import("std");
const app_mod = @import("app.zig");
const element_mod = @import("element.zig");
const window_mod = @import("window.zig");
const taffy = @import("taffy.zig");
const geometry = @import("geometry.zig");
const scene = @import("scene.zig");
const style_mod = @import("style.zig");
const div_mod = @import("elements/div.zig");

const App = app_mod.App;
const Window = window_mod.Window;
const EntityId = app_mod.EntityId;
const AnyElement = element_mod.AnyElement;
const Style = style_mod.Style;
const StyleRefinement = style_mod.StyleRefinement;

/// A type-erased view: an entity whose type has `render`.
pub const AnyView = struct {
    entity_id: EntityId,
    tid: app_mod.TypeId,
    render_fn: *const fn (EntityId, *Window, *App) AnyElement,
    type_name: []const u8,
    /// Set by `cached`: laid out at this style, and rendered only when something changed.
    cached_style: ?*const StyleRefinement = null,

    /// Erases an `Entity(V)` where `V.render(self, window, cx)` exists.
    pub fn from(entity: anytype) AnyView {
        const V = @TypeOf(entity).Type;
        if (!@hasDecl(V, "render")) @compileError(@typeName(V) ++ " has no render method and cannot be used as a view");
        const S = struct {
            fn render(id: EntityId, window: *Window, cx: *App) AnyElement {
                const raw = cx.entities.get(id) orelse return @import("elements/empty.zig").empty();
                const state: *V = @ptrCast(@alignCast(raw));
                var ctx: app_mod.Context(V) = .{ .app = cx, .entity_id_ = id };
                return element_mod.into_any_element(state.render(window, &ctx));
            }
        };
        return .{ .entity_id = entity.entity_id(), .tid = app_mod.type_id(V), .render_fn = S.render, .type_name = @typeName(V) };
    }

    pub fn downcast(self: AnyView, comptime V: type) ?app_mod.Entity(V) {
        if (self.tid != app_mod.type_id(V)) return null;
        return .{ .entity_id_ = self.entity_id };
    }

    pub fn into_any_element(self: AnyView) AnyElement {
        const el = window_mod.frame_arena().create(ViewElement) catch @panic("OOM");
        el.* = .{ .view = self };
        return AnyElement.new(el);
    }

    /// A weak handle to this view (GPUI `AnyView::downgrade`).
    pub fn downgrade(self: AnyView) AnyWeakView {
        return .{ .weak = .{ .entity_id_ = self.entity_id, .tid = self.tid }, .render_fn = self.render_fn, .type_name = self.type_name };
    }

    /// This view, keeping its last output until its entity notifies or `Window.refresh` runs. It is
    /// laid out at `style` without measuring its contents, so `style` must give it a definite
    /// size (GPUI `AnyView::cached`). Takes what `hover` takes, such as `gpui.style_refinement().size_full()`.
    pub fn cached(self: AnyView, style: anytype) AnyView {
        var copy = self;
        copy.cached_style = div_mod.to_style_refinement(style);
        return copy;
    }
};

/// What the output of a cached view depends on, other than the view (GPUI `ViewElementCacheKey`).
const ViewElementCacheKey = struct {
    bounds: geometry.Bounds(geometry.Pixels),
    content_mask: scene.ContentMask(geometry.Pixels),
    text_style: u64,
    /// By bits, so that a NaN opacity still matches itself.
    opacity: u32,
};

/// GPUI `ViewElementState`, plus memory: a cached view's elements and listeners are used for as many
/// frames as it stays cached, longer than the frame arena lasts, so they live in arenas here.
const ViewElementState = struct {
    prepaint_start: window_mod.PrepaintStateIndex = .{},
    prepaint_end: window_mod.PrepaintStateIndex = .{},
    paint_start: window_mod.PaintIndex = .{},
    paint_end: window_mod.PaintIndex = .{},
    cache_key: ?ViewElementCacheKey = null,
    /// Two, because the rendered frame still uses the last render's while the next one is made.
    arenas: [2]std.heap.ArenaAllocator,
    active_arena: u1 = 0,
    /// The frame that last prepainted this view. A second prepaint in that frame, after a failed
    /// `Window.transact`, cannot reuse: the ranges now describe the frame being drawn.
    prepaint_frame: u64 = 0,

    pub fn deinit(self: *ViewElementState, _: std.mem.Allocator) void {
        for (&self.arenas) |*arena| arena.deinit();
    }
};

const ViewElement = struct {
    view: AnyView,
    /// Null only for a cached view that is reusing its last output.
    child: ?AnyElement = null,

    pub const RequestLayoutState = void;
    pub const PrepaintState = void;

    pub fn id(self: *ViewElement) ?element_mod.ElementId {
        return .{ .view = self.view.entity_id.as_u64() };
    }

    pub fn request_layout(self: *ViewElement, _: ?*const element_mod.GlobalElementId, window: *Window, cx: *App) struct { taffy.LayoutId, void } {
        window.push_view(self.view.entity_id);
        defer window.pop_view();
        if (self.view.cached_style) |refinement| {
            var root_style: Style = .{};
            root_style.refine(refinement);
            return .{ window.request_layout(&root_style, &.{}, cx), {} };
        }
        const child = self.view.render_fn(self.view.entity_id, window, cx);
        self.child = child;
        return .{ child.request_layout(window, cx), {} };
    }

    pub fn prepaint(self: *ViewElement, global_id: ?*const element_mod.GlobalElementId, bounds: geometry.Bounds(geometry.Pixels), _: *void, window: *Window, cx: *App) void {
        const entity_id = self.view.entity_id;
        window.set_view_id(entity_id);
        window.push_view(entity_id);
        defer window.pop_view();
        if (self.child) |child| return child.prepaint(window, cx);

        const state = window.element_state(ViewElementState, global_id.?.*, .{ .arenas = .{ .init(window.allocator), .init(window.allocator) } });
        const key: ViewElementCacheKey = .{
            .bounds = bounds,
            .content_mask = window.content_mask(),
            .text_style = window.text_style().content_hash(),
            .opacity = @bitCast(window.element_opacity()),
        };
        const prepainted_already = state.prepaint_frame == window.frame_count;
        state.prepaint_frame = window.frame_count;
        const reusable = if (state.cache_key) |old| std.meta.eql(old, key) else false;
        if (reusable and !prepainted_already and !window.refreshing and
            !window.dirty_views.contains(entity_id) and cx.entities.get(entity_id) != null)
        {
            const start = window.prepaint_index();
            window.reuse_prepaint(state.prepaint_start, state.prepaint_end);
            state.prepaint_start = start;
            state.prepaint_end = window.prepaint_index();
            return;
        }

        // Everything inside renders again too, since its bounds may have changed with this view's.
        const refreshing = window.refreshing;
        window.refreshing = true;
        defer window.refreshing = refreshing;
        if (!prepainted_already) {
            state.active_arena +%= 1;
            _ = state.arenas[state.active_arena].reset(.retain_capacity);
        }
        const outer_arena = window_mod.swap_frame_arena(&state.arenas[state.active_arena]);
        defer _ = window_mod.swap_frame_arena(outer_arena);

        state.prepaint_start = window.prepaint_index();
        const child = self.view.render_fn(entity_id, window, cx);
        self.child = child;
        _ = child.layout_as_root(.{ .width = .{ .definite = bounds.size.width }, .height = .{ .definite = bounds.size.height } }, window, cx);
        child.prepaint_at(bounds.origin, window, cx);
        state.prepaint_end = window.prepaint_index();
        state.cache_key = key;
    }

    pub fn paint(self: *ViewElement, global_id: ?*const element_mod.GlobalElementId, _: geometry.Bounds(geometry.Pixels), _: *void, _: *void, window: *Window, cx: *App) void {
        window.push_view(self.view.entity_id);
        defer window.pop_view();
        if (self.view.cached_style == null) return self.child.?.paint(window, cx);

        const state = window.element_state(ViewElementState, global_id.?.*, .{ .arenas = .{ .init(window.allocator), .init(window.allocator) } });
        const start = window.paint_index();
        // Prepaint can only predict the opacity: an ancestor's hover style depends on this frame's
        // hit test. The key records what was painted, and output replayed under another
        // opacity is drawn again in the next frame.
        const opacity: u32 = @bitCast(window.element_opacity());
        if (self.child) |child| {
            const refreshing = window.refreshing;
            window.refreshing = true;
            defer window.refreshing = refreshing;
            const outer_arena = window_mod.swap_frame_arena(&state.arenas[state.active_arena]);
            defer _ = window_mod.swap_frame_arena(outer_arena);
            child.paint(window, cx);
            state.cache_key.?.opacity = opacity;
        } else {
            window.reuse_paint(state.paint_start, state.paint_end);
            if (state.cache_key.?.opacity != opacity) window.request_animation_frame();
        }
        state.paint_start = start;
        state.paint_end = window.paint_index();
    }
};

/// GPUI `Entity::into_any_view` helper for root views.
pub fn into_any_view(entity: anytype) AnyView {
    return AnyView.from(entity);
}

/// A view that renders nothing (GPUI `EmptyView`).
pub const EmptyView = struct {
    pub fn render(_: *EmptyView, _: *Window, _: *app_mod.Context(EmptyView)) AnyElement {
        return @import("elements/empty.zig").empty();
    }
};

/// A weak, type-erased view handle (GPUI `AnyWeakView`). `upgrade` fails once the view's entity is
/// released. Like the other weak handles in ZUI, it takes the `cx` that can check that.
pub const AnyWeakView = struct {
    weak: app_mod.AnyWeakEntity,
    render_fn: *const fn (EntityId, *Window, *App) AnyElement,
    type_name: []const u8,

    /// The strong view, if its entity is still alive.
    pub fn upgrade(self: AnyWeakView, cx: anytype) ?AnyView {
        if (!self.weak.is_upgradable(cx)) return null;
        return .{ .entity_id = self.weak.entity_id(), .tid = self.weak.tid, .render_fn = self.render_fn, .type_name = self.type_name };
    }
};
