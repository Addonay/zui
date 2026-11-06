//! Port of GPUI `view.rs`: entities rendered as elements (`AnyView`).

const std = @import("std");
const app_mod = @import("app.zig");
const element_mod = @import("element.zig");
const window_mod = @import("window.zig");
const taffy = @import("taffy.zig");
const geometry = @import("geometry.zig");

const App = app_mod.App;
const Window = window_mod.Window;
const EntityId = app_mod.EntityId;
const AnyElement = element_mod.AnyElement;

/// A type-erased view: an entity whose type has `render`.
pub const AnyView = struct {
    entity_id: EntityId,
    tid: app_mod.TypeId,
    render_fn: *const fn (EntityId, *Window, *App) AnyElement,
    type_name: []const u8,

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

    /// GPUI `AnyView::cached`: currently renders every frame (cache key reserved).
    pub fn cached(self: AnyView, style: anytype) AnyView {
        _ = style;
        return self;
    }
};

const ViewElement = struct {
    view: AnyView,
    child: AnyElement = undefined,

    pub const RequestLayoutState = void;
    pub const PrepaintState = void;

    pub fn id(self: *ViewElement) ?element_mod.ElementId {
        return .{ .view = self.view.entity_id.as_u64() };
    }

    pub fn request_layout(self: *ViewElement, _: ?*const element_mod.GlobalElementId, window: *Window, cx: *App) struct { taffy.LayoutId, void } {
        window.push_view(self.view.entity_id);
        defer window.pop_view();
        self.child = self.view.render_fn(self.view.entity_id, window, cx);
        return .{ self.child.request_layout(window, cx), {} };
    }

    pub fn prepaint(self: *ViewElement, _: ?*const element_mod.GlobalElementId, _: geometry.Bounds(geometry.Pixels), _: *void, window: *Window, cx: *App) void {
        window.set_view_id(self.view.entity_id);
        window.push_view(self.view.entity_id);
        defer window.pop_view();
        self.child.prepaint(window, cx);
    }

    pub fn paint(self: *ViewElement, _: ?*const element_mod.GlobalElementId, _: geometry.Bounds(geometry.Pixels), _: *void, _: *void, window: *Window, cx: *App) void {
        window.push_view(self.view.entity_id);
        defer window.pop_view();
        self.child.paint(window, cx);
    }
};

/// GPUI `Entity::into_any_view` helper for root views.
pub fn into_any_view(entity: anytype) AnyView {
    return AnyView.from(entity);
}
