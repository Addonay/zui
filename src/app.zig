//! Port of GPUI `app.rs`, `app/entity_map.rs`, `app/context.rs`, `global.rs`
//! and `subscription.rs`: the application state, entities, contexts,
//! globals, observers and event subscriptions.

const std = @import("std");
const builtin = @import("builtin");
const geometry = @import("geometry.zig");
const style_mod = @import("style.zig");
const view_mod = @import("view.zig");
const window_mod = @import("window.zig");
const platform_mod = @import("platform.zig");
const element_mod = @import("element.zig");
const text_system_mod = @import("text_system.zig");
const executor_mod = @import("executor.zig");
const keymap_mod = @import("keymap.zig");
const colors_mod = @import("colors.zig");
const action_mod = @import("action.zig");
const keystroke_mod = @import("keystroke.zig");
const http_client_mod = @import("http_client.zig");
const assets_mod = @import("assets.zig");
const asset_cache_mod = @import("asset_cache.zig");
const uniform_list_mod = @import("elements/uniform_list.zig");
const list_mod = @import("elements/list.zig");
const focus_events = @import("window/focus_events.zig");

/// Given to `Context.on_focus_out` listeners (GPUI `FocusOutEvent`).
pub const FocusOutEvent = focus_events.FocusOutEvent;

const Window = window_mod.Window;
const WindowOptions = window_mod.WindowOptions;
const Pixels = geometry.Pixels;
const AnyElement = element_mod.AnyElement;
pub const SharedString = []const u8;

// ---------------------------------------------------------------------------
// Type ids.

/// A unique id per Zig type (GPUI uses `TypeId`).
pub const TypeId = *const anyopaque;

pub fn type_id(comptime T: type) TypeId {
    const S = struct {
        const name: []const u8 = @typeName(T);
        var tag: u8 = 0;
    };
    _ = S.name;
    return @ptrCast(&S.tag);
}

// ---------------------------------------------------------------------------
// Entities.

/// Identifies an entity; packs a slot index and a generation.
pub const EntityId = enum(u64) {
    _,

    pub fn new(idx: u32, gen_: u32) EntityId {
        return @enumFromInt(@as(u64, gen_) << 32 | idx);
    }
    pub fn index(self: EntityId) u32 {
        return @truncate(@intFromEnum(self));
    }
    pub fn generation(self: EntityId) u32 {
        return @intCast(@intFromEnum(self) >> 32);
    }
    pub fn as_u64(self: EntityId) u64 {
        return @intFromEnum(self);
    }
    pub fn from_u64(v: u64) EntityId {
        return @enumFromInt(v);
    }
};

const EntitySlot = struct {
    ptr: ?*anyopaque = null,
    tid: ?TypeId = null,
    generation: u32 = 1,
    destroy: ?*const fn (*App, *anyopaque) void = null,
    /// Set while the entity is leased for an update (re-entrancy check).
    leased: bool = false,
};

/// Owns all entity state (GPUI `EntityMap`).
pub const EntityMap = struct {
    slots: std.ArrayList(EntitySlot) = .empty,
    free: std.ArrayList(u32) = .empty,

    fn reserve(self: *EntityMap, gpa: std.mem.Allocator) EntityId {
        if (self.free.pop()) |i| return .new(i, self.slots.items[i].generation);
        self.slots.append(gpa, .{}) catch oom();
        return .new(@intCast(self.slots.items.len - 1), 1);
    }

    pub fn get(self: *const EntityMap, id: EntityId) ?*anyopaque {
        const i = id.index();
        if (i >= self.slots.items.len) return null;
        const s = &self.slots.items[i];
        if (s.generation != id.generation()) return null;
        return s.ptr;
    }

    pub fn len(self: *const EntityMap) usize {
        return self.slots.items.len - self.free.items.len;
    }
};

fn oom() noreturn {
    @panic("out of memory");
}

/// A strong handle to an entity of type `T` (GPUI `Entity<T>`).
///
/// Handles are plain values; the entity lives until `release` is called (or
/// the app shuts down). Windows release their root views when closed.
pub fn Entity(comptime T: type) type {
    return struct {
        const Self = @This();
        pub const Type = T;
        pub const is_entity = true;
        entity_id_: EntityId,

        /// This entity's id.
        pub fn entity_id(self: Self) EntityId {
            return self.entity_id_;
        }

        /// A weak handle to the same entity.
        pub fn downgrade(self: Self) WeakEntity(T) {
            return .{ .entity_id_ = self.entity_id_ };
        }

        /// Erases the type.
        pub fn into_any(self: Self) AnyEntity {
            return .{ .entity_id_ = self.entity_id_, .tid = type_id(T) };
        }

        /// Read-only access to the entity's state.
        pub fn read(self: Self, cx: anytype) *const T {
            const app = app_of(cx);
            return @ptrCast(@alignCast(app.entities.get(self.entity_id_) orelse @panic("entity released")));
        }

        /// Mutable access without a context (GPUI `as_mut`); prefer `update`.
        pub fn as_mut(self: Self, cx: anytype) *T {
            const app = app_of(cx);
            return @ptrCast(@alignCast(app.entities.get(self.entity_id_) orelse @panic("entity released")));
        }

        /// Calls `f(state, args..., cx)` style updates. `f` is
        /// `fn(*T, *Context(T)) R` or `fn(*T, ..., *Context(T)) R` with `args` the middle params.
        pub fn update(self: Self, cx: anytype, comptime f: anytype, args: anytype) ReturnOf(f) {
            const app = app_of(cx);
            return app.update_entity(T, self, f, args);
        }

        /// Like `update`, but with access to a window (GPUI `update_in`).
        pub fn update_in(self: Self, window: *Window, cx: anytype, comptime f: anytype, args: anytype) ReturnOf(f) {
            const app = app_of(cx);
            const state = self.as_mut(app);
            var ctx: Context(T) = .{ .app = app, .entity_id_ = self.entity_id_ };
            return @call(.auto, f, .{state} ++ args ++ .{ window, &ctx });
        }

        /// Drops this entity's state.
        pub fn release(self: Self, cx: anytype) void {
            app_of(cx).release_entity(self.entity_id_);
        }

        pub fn eql(a: Self, b: Self) bool {
            return a.entity_id_ == b.entity_id_;
        }

        /// Erases into a view (`T` must have `render`).
        pub fn into_any_view(self: Self) @import("view.zig").AnyView {
            return @import("view.zig").AnyView.from(self);
        }

        /// This entity as a view that keeps its last output until it notifies, laid out at `style`
        /// without measuring its contents, so `style` must give it a definite size (GPUI `Entity::cached`).
        pub fn cached(self: Self, style: anytype) @import("view.zig").AnyView {
            return self.into_any_view().cached(style);
        }

        /// Entities are IntoElement when `T` is Render: they render as views.
        pub fn into_any_element(self: Self) AnyElement {
            return @import("view.zig").AnyView.from(self).into_any_element();
        }
    };
}

fn ReturnOf(comptime f: anytype) type {
    return @typeInfo(@TypeOf(f)).@"fn".return_type.?;
}

/// A weak handle (GPUI `WeakEntity<T>`): `upgrade` fails once released.
pub fn WeakEntity(comptime T: type) type {
    return struct {
        const Self = @This();
        entity_id_: EntityId,

        pub fn entity_id(self: Self) EntityId {
            return self.entity_id_;
        }

        pub fn upgrade(self: Self, cx: anytype) ?Entity(T) {
            const app = app_of(cx);
            if (app.entities.get(self.entity_id_) == null) return null;
            return .{ .entity_id_ = self.entity_id_ };
        }

        /// Updates the entity if it is still alive.
        pub fn update(self: Self, cx: anytype, comptime f: anytype, args: anytype) error{EntityReleased}!ReturnOf(f) {
            const e = self.upgrade(cx) orelse return error.EntityReleased;
            return e.update(cx, f, args);
        }

        pub fn read_with(self: Self, cx: anytype) ?*const T {
            const e = self.upgrade(cx) orelse return null;
            return e.read(cx);
        }

        /// The same entity without its type (GPUI `WeakEntity::into`).
        pub fn into_any(self: Self) AnyWeakEntity {
            return .{ .entity_id_ = self.entity_id_, .tid = type_id(T) };
        }
    };
}

/// A type-erased entity handle.
pub const AnyEntity = struct {
    entity_id_: EntityId,
    tid: TypeId,

    pub fn entity_id(self: AnyEntity) EntityId {
        return self.entity_id_;
    }
    pub fn downcast(self: AnyEntity, comptime T: type) ?Entity(T) {
        if (self.tid != type_id(T)) return null;
        return .{ .entity_id_ = self.entity_id_ };
    }
    /// The type of the entity (GPUI `AnyEntity::entity_type`).
    pub fn entity_type(self: AnyEntity) TypeId {
        return self.tid;
    }
    /// A weak handle to the same entity (GPUI `AnyEntity::downgrade`).
    pub fn downgrade(self: AnyEntity) AnyWeakEntity {
        return .{ .entity_id_ = self.entity_id_, .tid = self.tid };
    }
};

/// A type-erased weak handle (GPUI `AnyWeakEntity`): `upgrade` fails once the entity is released.
pub const AnyWeakEntity = struct {
    entity_id_: EntityId,
    tid: TypeId,

    pub fn entity_id(self: AnyWeakEntity) EntityId {
        return self.entity_id_;
    }
    pub fn entity_type(self: AnyWeakEntity) TypeId {
        return self.tid;
    }
    /// A strong handle, if the entity is still alive.
    pub fn upgrade(self: AnyWeakEntity, cx: anytype) ?AnyEntity {
        if (!self.is_upgradable(cx)) return null;
        return .{ .entity_id_ = self.entity_id_, .tid = self.tid };
    }
    /// Whether the entity is still alive (GPUI `AnyWeakEntity::is_upgradable`).
    pub fn is_upgradable(self: AnyWeakEntity, cx: anytype) bool {
        return app_of(cx).entities.get(self.entity_id_) != null;
    }
    /// The typed handle, if the entity is alive and really is a `T`.
    pub fn downcast(self: AnyWeakEntity, comptime T: type) ?WeakEntity(T) {
        if (self.tid != type_id(T)) return null;
        return .{ .entity_id_ = self.entity_id_ };
    }
};

/// Returns the `*App` behind `*App`, `*Context(T)`, `*AsyncApp` or `*Window`-bound contexts.
pub fn app_of(cx: anytype) *App {
    const T = @TypeOf(cx);
    if (T == *App or T == *const App) return @constCast(cx);
    const C = @typeInfo(T).pointer.child;
    if (@hasField(C, "app")) return cx.app;
    @compileError("not an app context: " ++ @typeName(T));
}

// ---------------------------------------------------------------------------
// Context(T).

/// The state a subscriber keeps when it needs a window as well as its entity. Owned by the
/// subscriber (see `App.add_owned_subscriber`).
const WindowBound = struct {
    entity: EntityId,
    window: window_mod.WindowId,
};

/// The state of a focus subscriber: its entity and the focus handle it watches.
const EntityFocus = struct {
    entity: EntityId,
    focus: u64,
};

/// Which focus change a `Context.on_focus*` listener waits for.
const FocusMode = enum { focus, focus_in, blur, focus_out, lost };

/// The context passed to entity updates and renders (GPUI `Context<T>`).
/// It forwards the most common `App` methods; use `cx.app` for the rest.
pub fn Context(comptime T: type) type {
    return struct {
        const Self = @This();
        app: *App,
        entity_id_: EntityId,

        /// A strong handle to the entity being updated.
        pub fn entity(self: *const Self) Entity(T) {
            return .{ .entity_id_ = self.entity_id_ };
        }

        /// A weak handle to the entity being updated.
        pub fn weak_entity(self: *const Self) WeakEntity(T) {
            return .{ .entity_id_ = self.entity_id_ };
        }

        pub fn entity_id(self: *const Self) EntityId {
            return self.entity_id_;
        }

        /// Marks this entity as changed: observers run and windows that render it redraw.
        pub fn notify(self: *Self) void {
            self.app.notify(self.entity_id_);
        }

        /// Emits an event to subscribers (`T` must declare `pub const Event = ...`).
        pub fn emit(self: *Self, event: T.Event) void {
            self.app.emit_event(T, self.entity_id_, event);
        }

        /// Wraps `f(this, event, window, cx)` into an element listener bound to this entity.
        pub fn listener(self: *const Self, comptime f: anytype) Listener(ListenerEvent(f)) {
            const E = ListenerEvent(f);
            const S = struct {
                fn call(ctx: *anyopaque, event: *const E, window: *Window, app: *App) void {
                    const id = EntityId.from_u64(@intFromPtr(ctx));
                    const state = app.entities.get(id) orelse return;
                    var c: Context(T) = .{ .app = app, .entity_id_ = id };
                    f(@as(*T, @ptrCast(@alignCast(state))), event, window, &c);
                }
            };
            return .{ .ctx = @ptrFromInt(@as(usize, @intCast(self.entity_id_.as_u64()))), .func = S.call };
        }

        /// Like `listener`, but captures `data` (copied into the frame arena):
        /// `f(this, data, event, window, cx)`.
        pub fn listener_with(self: *const Self, data: anytype, comptime f: anytype) Listener(ListenerEventWith(f)) {
            const D = @TypeOf(data);
            const E = ListenerEventWith(f);
            const Cap = struct { id: EntityId, data: D };
            const cap = window_mod.frame_arena().create(Cap) catch oom();
            cap.* = .{ .id = self.entity_id_, .data = data };
            const S = struct {
                fn call(ctx: *anyopaque, event: *const E, window: *Window, app: *App) void {
                    const c2: *Cap = @ptrCast(@alignCast(ctx));
                    const state = app.entities.get(c2.id) orelse return;
                    var c: Context(T) = .{ .app = app, .entity_id_ = c2.id };
                    f(@as(*T, @ptrCast(@alignCast(state))), c2.data, event, window, &c);
                }
            };
            return .{ .ctx = cap, .func = S.call };
        }

        /// Wraps `f(this, range, window, cx) []AnyElement` into a range renderer for `uniform_list` (GPUI `processor`).
        pub fn processor(self: *const Self, comptime f: anytype) uniform_list_mod.RangeRenderer {
            const S = struct {
                fn call(ctx: *anyopaque, range: uniform_list_mod.Range, window: *Window, app: *App) []element_mod.AnyElement {
                    const id = EntityId.from_u64(@intFromPtr(ctx));
                    const state = app.entities.get(id) orelse return &.{};
                    var c: Context(T) = .{ .app = app, .entity_id_ = id };
                    return f(@as(*T, @ptrCast(@alignCast(state))), range, window, &c);
                }
            };
            return .{ .ctx = @ptrFromInt(@as(usize, @intCast(self.entity_id_.as_u64()))), .func = S.call };
        }

        /// Wraps `f(this, ix, window, cx) AnyElement` into an item renderer for `list` (GPUI `processor`).
        pub fn item_processor(self: *const Self, comptime f: anytype) list_mod.ItemRenderer {
            const S = struct {
                fn call(ctx: *anyopaque, ix: usize, window: *Window, app: *App) element_mod.AnyElement {
                    const id = EntityId.from_u64(@intFromPtr(ctx));
                    const state = app.entities.get(id) orelse @panic("list item rendered for a released entity");
                    var c: Context(T) = .{ .app = app, .entity_id_ = id };
                    return f(@as(*T, @ptrCast(@alignCast(state))), ix, window, &c);
                }
            };
            return .{ .ctx = @ptrFromInt(@as(usize, @intCast(self.entity_id_.as_u64()))), .func = S.call };
        }

        /// Observes `observed`: `f(this, observed, cx)` runs whenever it notifies.
        pub fn observe(self: *Self, observed: anytype, comptime f: anytype) Subscription {
            const E = @TypeOf(observed);
            const me = self.entity_id_;
            const S = struct {
                fn call(app: *App, emitter: EntityId, ctx: usize, _: ?*const anyopaque) bool {
                    const id = EntityId.from_u64(ctx);
                    const state = app.entities.get(id) orelse return false;
                    var c: Context(T) = .{ .app = app, .entity_id_ = id };
                    f(@as(*T, @ptrCast(@alignCast(state))), E{ .entity_id_ = emitter }, &c);
                    return true;
                }
            };
            return self.app.add_observer(observed.entity_id(), me.as_u64(), S.call);
        }

        /// Runs `f(this, window, cx)` when the appearance of `window` changes (GPUI `observe_window_appearance`).
        pub fn observe_window_appearance(self: *Self, window: *Window, comptime f: anytype) Subscription {
            const me = self.entity_id_;
            const S = struct {
                fn call(app: *App, _: EntityId, ctx: usize, payload: ?*const anyopaque) bool {
                    const id = EntityId.from_u64(ctx);
                    const state = app.entities.get(id) orelse return false;
                    const win: *Window = @ptrCast(@alignCast(@constCast(payload.?)));
                    var c: Context(T) = .{ .app = app, .entity_id_ = id };
                    f(@as(*T, @ptrCast(@alignCast(state))), win, &c);
                    return true;
                }
            };
            return self.app.add_subscriber(.{ .kind = .window_appearance, .emitter = window.handle_id, .ctx = me.as_u64(), .func = S.call, .id = 0 });
        }

        /// Runs `f(this, window, cx)` when the bounds of `window` change: it moved or was resized
        /// (GPUI `observe_window_bounds`).
        pub fn observe_window_bounds(self: *Self, window: *Window, comptime f: anytype) Subscription {
            return self.window_subscriber(.window_bounds, window, f);
        }

        /// Runs `f(this, window, cx)` when `window` is activated or deactivated (GPUI `observe_window_activation`).
        pub fn observe_window_activation(self: *Self, window: *Window, comptime f: anytype) Subscription {
            return self.window_subscriber(.window_activation, window, f);
        }

        /// Runs `f(this, visibility, window, cx)` when the visibility of `window` changes (GPUI
        /// `observe_window_visibility`). Only changes are reported.
        pub fn observe_window_visibility(self: *Self, window: *Window, comptime f: anytype) Subscription {
            const me = self.entity_id_;
            const S = struct {
                fn call(app: *App, _: EntityId, ctx: usize, payload: ?*const anyopaque) bool {
                    const id = EntityId.from_u64(ctx);
                    const state = app.entities.get(id) orelse return false;
                    const win: *Window = @ptrCast(@alignCast(@constCast(payload.?)));
                    var c: Context(T) = .{ .app = app, .entity_id_ = id };
                    f(@as(*T, @ptrCast(@alignCast(state))), win.visibility_, win, &c);
                    return true;
                }
            };
            return self.app.add_window_subscriber(.window_visibility, window.handle_id, me.as_u64(), S.call);
        }

        /// Runs `f(this, window, cx)` when `window` moves to another display, or the display it is on
        /// changes (GPUI `observe_window_display`).
        pub fn observe_window_display(self: *Self, window: *Window, comptime f: anytype) Subscription {
            return self.window_subscriber(.window_display, window, f);
        }

        fn window_subscriber(self: *Self, comptime kind: SubscriberKind, window: *Window, comptime f: anytype) Subscription {
            const me = self.entity_id_;
            const S = struct {
                fn call(app: *App, _: EntityId, ctx: usize, payload: ?*const anyopaque) bool {
                    const id = EntityId.from_u64(ctx);
                    const state = app.entities.get(id) orelse return false;
                    const win: *Window = @ptrCast(@alignCast(@constCast(payload.?)));
                    var c: Context(T) = .{ .app = app, .entity_id_ = id };
                    f(@as(*T, @ptrCast(@alignCast(state))), win, &c);
                    return true;
                }
            };
            return self.app.add_window_subscriber(kind, window.handle_id, me.as_u64(), S.call);
        }

        /// Subscribes to events emitted by `emitter`, with the window the subscriber is rendered in:
        /// `f(this, emitter, event, window, cx)`. The window is looked up when the event fires, so
        /// the callback follows the entity to another window, as GPUI's does. Events that arrive
        /// while the entity is in no window are dropped; the subscription stays. The `window`
        /// argument of the call is not stored: GPUI's `subscribe_in` takes it only to start there.
        pub fn subscribe_in(self: *Self, emitter: anytype, window: *Window, comptime f: anytype) Subscription {
            _ = window;
            const EH = @TypeOf(emitter);
            const Ev = EH.Type.Event;
            const S = struct {
                fn call(app: *App, from: EntityId, ctx: usize, payload: ?*const anyopaque) bool {
                    const id = EntityId.from_u64(ctx);
                    const state = app.entities.get(id) orelse return false;
                    const current = app.window_for_entity(id) orelse return true;
                    var c: Context(T) = .{ .app = app, .entity_id_ = id };
                    const ev: *const Ev = @ptrCast(@alignCast(payload.?));
                    f(@as(*T, @ptrCast(@alignCast(state))), EH{ .entity_id_ = from }, ev, current, &c);
                    return true;
                }
            };
            return self.app.add_event_listener(emitter.entity_id(), type_id(Ev), self.entity_id_.as_u64(), S.call);
        }

        /// Subscribes to events emitted by `emitter`: `f(this, emitter, event, cx)`.
        pub fn subscribe(self: *Self, emitter: anytype, comptime f: anytype) Subscription {
            const EH = @TypeOf(emitter);
            const Ev = EH.Type.Event;
            const S = struct {
                fn call(app: *App, from: EntityId, ctx: usize, payload: ?*const anyopaque) bool {
                    const id = EntityId.from_u64(ctx);
                    const state = app.entities.get(id) orelse return false;
                    var c: Context(T) = .{ .app = app, .entity_id_ = id };
                    const ev: *const Ev = @ptrCast(@alignCast(payload.?));
                    f(@as(*T, @ptrCast(@alignCast(state))), EH{ .entity_id_ = from }, ev, &c);
                    return true;
                }
            };
            return self.app.add_event_listener(emitter.entity_id(), type_id(Ev), self.entity_id_.as_u64(), S.call);
        }

        /// Runs `f(this, cx)` when this entity is released.
        pub fn on_release(self: *Self, comptime f: anytype) Subscription {
            const S = struct {
                fn call(app: *App, from: EntityId, _: usize, payload: ?*const anyopaque) bool {
                    const state: *T = @ptrCast(@alignCast(@constCast(payload.?)));
                    var c: Context(T) = .{ .app = app, .entity_id_ = from };
                    f(state, &c);
                    return false;
                }
            };
            return self.app.add_release_listener(self.entity_id_, S.call);
        }

        /// Observes global `G`: `f(this, cx)` runs when it changes.
        /// Runs `f(this, event, window, cx)` after any keystroke has been handled.
        pub fn observe_keystrokes(self: *Self, comptime f: anytype) Subscription {
            return self.keystroke_subscriber(KeystrokeObserverKey, f);
        }

        /// Runs `f(this, event, window, cx)` before a keystroke is handled.
        pub fn intercept_keystrokes(self: *Self, comptime f: anytype) Subscription {
            return self.keystroke_subscriber(KeystrokeInterceptorKey, f);
        }

        fn keystroke_subscriber(self: *Self, comptime Key: type, comptime f: anytype) Subscription {
            const S = struct {
                fn call(app: *App, _: EntityId, ctx: usize, payload: ?*const anyopaque) bool {
                    const id = EntityId.from_u64(ctx);
                    const state = app.entities.get(id) orelse return false;
                    const p: *const KeystrokePayload = @ptrCast(@alignCast(payload.?));
                    var c: Context(T) = .{ .app = app, .entity_id_ = id };
                    f(@as(*T, @ptrCast(@alignCast(state))), p.event, p.window, &c);
                    return true;
                }
            };
            return self.app.add_global_observer(type_id(Key), self.entity_id_.as_u64(), S.call);
        }

        /// Runs `f(this, window, cx)` when `window`'s pending keystrokes change.
        pub fn observe_pending_input(self: *Self, window: *Window, comptime f: anytype) Subscription {
            const S = struct {
                fn call(app: *App, _: EntityId, ctx: usize, payload: ?*const anyopaque) bool {
                    const id = EntityId.from_u64(ctx);
                    const state = app.entities.get(id) orelse return false;
                    var c: Context(T) = .{ .app = app, .entity_id_ = id };
                    f(@as(*T, @ptrCast(@alignCast(state))), @constCast(@as(*const Window, @ptrCast(@alignCast(payload.?)))), &c);
                    return true;
                }
            };
            return self.app.add_subscriber(.{ .kind = .global, .emitter = @intFromPtr(window), .event_type = type_id(PendingInputObserverKey), .ctx = self.entity_id_.as_u64(), .func = S.call, .id = 0 });
        }

        pub fn observe_global(self: *Self, comptime G: type, comptime f: anytype) Subscription {
            const S = struct {
                fn call(app: *App, _: EntityId, ctx: usize, _: ?*const anyopaque) bool {
                    const id = EntityId.from_u64(ctx);
                    const state = app.entities.get(id) orelse return false;
                    var c: Context(T) = .{ .app = app, .entity_id_ = id };
                    f(@as(*T, @ptrCast(@alignCast(state))), &c);
                    return true;
                }
            };
            return self.app.add_global_observer(type_id(G), self.entity_id_.as_u64(), S.call);
        }

        /// Spawns a foreground task: `f(weak_this, async_cx, args...)`.
        pub fn spawn(self: *Self, comptime f: anytype, args: anytype) executor_mod.Task(ReturnOf(f)) {
            const weak: WeakEntity(T) = .{ .entity_id_ = self.entity_id_ };
            return self.app.foreground_executor().spawn(f, .{ weak, self.app.to_async() } ++ args);
        }

        /// Runs `f(this, cx)` whenever this entity notifies (GPUI `observe_self`).
        pub fn observe_self(self: *Self, comptime f: anytype) Subscription {
            const S = struct {
                fn call(app: *App, _: EntityId, ctx: usize, _: ?*const anyopaque) bool {
                    const id = EntityId.from_u64(ctx);
                    const state = app.entities.get(id) orelse return false;
                    var c: Context(T) = .{ .app = app, .entity_id_ = id };
                    f(@as(*T, @ptrCast(@alignCast(state))), &c);
                    return true;
                }
            };
            return self.app.add_observer(self.entity_id_, self.entity_id_.as_u64(), S.call);
        }

        /// Runs `f(this, event, cx)` for each event this entity emits (GPUI `subscribe_self`).
        pub fn subscribe_self(self: *Self, comptime f: anytype) Subscription {
            const Ev = T.Event;
            const S = struct {
                fn call(app: *App, _: EntityId, ctx: usize, payload: ?*const anyopaque) bool {
                    const id = EntityId.from_u64(ctx);
                    const state = app.entities.get(id) orelse return false;
                    var c: Context(T) = .{ .app = app, .entity_id_ = id };
                    const ev: *const Ev = @ptrCast(@alignCast(payload.?));
                    f(@as(*T, @ptrCast(@alignCast(state))), ev, &c);
                    return true;
                }
            };
            return self.app.add_event_listener(self.entity_id_, type_id(Ev), self.entity_id_.as_u64(), S.call);
        }

        /// Runs `f(this, released, cx)` when `observed` is released, once (GPUI `observe_release`).
        pub fn observe_release(self: *Self, observed: anytype, comptime f: anytype) Subscription {
            const T2 = @TypeOf(observed).Type;
            const S = struct {
                fn call(app: *App, _: EntityId, ctx: usize, payload: ?*const anyopaque) bool {
                    const id = EntityId.from_u64(ctx);
                    const state = app.entities.get(id) orelse return false;
                    const released: *T2 = @ptrCast(@alignCast(@constCast(payload.?)));
                    var c: Context(T) = .{ .app = app, .entity_id_ = id };
                    f(@as(*T, @ptrCast(@alignCast(state))), released, &c);
                    return false;
                }
            };
            return self.app.add_subscriber(.{ .kind = .release, .emitter = observed.entity_id().as_u64(), .ctx = self.entity_id_.as_u64(), .func = S.call, .id = 0 });
        }

        /// Runs `f(this, released, window, cx)` when `observed` is released, once (GPUI `observe_release_in`).
        /// If `window` has been closed by then, the callback does not run: ZUI has no window handle
        /// that stays valid after its window is gone.
        pub fn observe_release_in(self: *Self, observed: anytype, window: *Window, comptime f: anytype) Subscription {
            const T2 = @TypeOf(observed).Type;
            const S = struct {
                fn call(app: *App, _: EntityId, ctx: usize, payload: ?*const anyopaque) bool {
                    const bound: *const WindowBound = @ptrFromInt(ctx);
                    const state = app.entities.get(bound.entity) orelse return false;
                    const win = app.window_by_id(bound.window) orelse return false;
                    const released: *T2 = @ptrCast(@alignCast(@constCast(payload.?)));
                    var c: Context(T) = .{ .app = app, .entity_id_ = bound.entity };
                    f(@as(*T, @ptrCast(@alignCast(state))), released, win, &c);
                    return false;
                }
            };
            return self.app.add_owned_subscriber(.{ .kind = .release, .emitter = observed.entity_id().as_u64(), .ctx = 0, .func = S.call, .id = 0 }, WindowBound, .{ .entity = self.entity_id_, .window = window.handle_id });
        }

        /// Runs `f(this, window, app)` when this entity is released, once (GPUI `on_release_in`).
        /// As with `observe_release_in`, it does not run if the window is closed by then.
        pub fn on_release_in(self: *Self, window: *Window, comptime f: anytype) Subscription {
            const S = struct {
                fn call(app: *App, _: EntityId, ctx: usize, payload: ?*const anyopaque) bool {
                    const bound: *const WindowBound = @ptrFromInt(ctx);
                    const win = app.window_by_id(bound.window) orelse return false;
                    f(@as(*T, @ptrCast(@alignCast(@constCast(payload.?)))), win, app);
                    return false;
                }
            };
            return self.app.add_owned_subscriber(.{ .kind = .release, .emitter = self.entity_id_.as_u64(), .ctx = 0, .func = S.call, .id = 0 }, WindowBound, .{ .entity = self.entity_id_, .window = window.handle_id });
        }

        /// Runs `f(this, observed, window, cx)` whenever `observed` notifies (GPUI `observe_in`).
        /// `window` is the one given here; the callback does not run while it is closed.
        pub fn observe_in(self: *Self, observed: anytype, window: *Window, comptime f: anytype) Subscription {
            const E = @TypeOf(observed);
            const S = struct {
                fn call(app: *App, emitter: EntityId, ctx: usize, _: ?*const anyopaque) bool {
                    const bound: *const WindowBound = @ptrFromInt(ctx);
                    const state = app.entities.get(bound.entity) orelse return false;
                    const win = app.window_by_id(bound.window) orelse return true;
                    var c: Context(T) = .{ .app = app, .entity_id_ = bound.entity };
                    f(@as(*T, @ptrCast(@alignCast(state))), E{ .entity_id_ = emitter }, win, &c);
                    return true;
                }
            };
            return self.app.add_owned_subscriber(.{ .kind = .observe, .emitter = observed.entity_id().as_u64(), .ctx = 0, .func = S.call, .id = 0 }, WindowBound, .{ .entity = self.entity_id_, .window = window.handle_id });
        }

        /// Runs `f(this, window, cx)` whenever the global `G` changes (GPUI `observe_global_in`).
        pub fn observe_global_in(self: *Self, comptime G: type, window: *Window, comptime f: anytype) Subscription {
            const S = struct {
                fn call(app: *App, _: EntityId, ctx: usize, _: ?*const anyopaque) bool {
                    const bound: *const WindowBound = @ptrFromInt(ctx);
                    const state = app.entities.get(bound.entity) orelse return false;
                    // A window that is closed (or briefly unavailable) skips this change and stays observed.
                    const win = app.window_by_id(bound.window) orelse return true;
                    var c: Context(T) = .{ .app = app, .entity_id_ = bound.entity };
                    f(@as(*T, @ptrCast(@alignCast(state))), win, &c);
                    return true;
                }
            };
            return self.app.add_owned_subscriber(.{ .kind = .global, .emitter = 0, .event_type = type_id(G), .ctx = 0, .func = S.call, .id = 0 }, WindowBound, .{ .entity = self.entity_id_, .window = window.handle_id });
        }

        /// Runs `f(this, window, cx)` at the end of the current update, if the entity and the window
        /// still exist (GPUI `defer_in`).
        pub fn defer_in(self: *Self, window: *Window, comptime f: anytype) void {
            const bound = self.app.effect_arena.allocator().create(WindowBound) catch oom();
            bound.* = .{ .entity = self.entity_id_, .window = window.handle_id };
            const S = struct {
                fn run(app: *App, ctx: usize) void {
                    const b: *const WindowBound = @ptrFromInt(ctx);
                    const state = app.entities.get(b.entity) orelse return;
                    const win = app.window_by_id(b.window) orelse return;
                    var c: Context(T) = .{ .app = app, .entity_id_ = b.entity };
                    f(@as(*T, @ptrCast(@alignCast(state))), win, &c);
                }
            };
            self.app.push_effect(.{ .deferred = .{ .ctx = @intFromPtr(bound), .func = S.run } });
        }

        /// Moves focus to `view`, which must have a `focus_handle` (GPUI `focus_view`).
        pub fn focus_view(self: *Self, view: anytype, window: *Window) void {
            const handle = view.read(self.app).focus_handle(self.app);
            window.focus(handle);
        }

        /// Moves focus to this entity's focus handle at the end of the current update (GPUI
        /// `focus_self`). The entity must have a `focus_handle` method.
        pub fn focus_self(self: *Self, window: *Window) void {
            const S = struct {
                fn run(this: *T, win: *Window, cx: *Context(T)) void {
                    this.focus_handle(cx.app).focus(win);
                }
            };
            self.defer_in(window, S.run);
        }

        /// Runs `f(this, window, cx)` when `handle` gets focus, from outside its subtree (GPUI `on_focus`).
        pub fn on_focus(self: *Self, handle: window_mod.FocusHandle, window: *Window, comptime f: anytype) Subscription {
            return self.focus_listener(window, .focus, .focus, handle.id, f);
        }

        /// Runs `f(this, window, cx)` when `handle` or something beneath it gets focus (GPUI `on_focus_in`).
        pub fn on_focus_in(self: *Self, handle: window_mod.FocusHandle, window: *Window, comptime f: anytype) Subscription {
            return self.focus_listener(window, .focus, .focus_in, handle.id, f);
        }

        /// Runs `f(this, window, cx)` when `handle` loses focus (GPUI `on_blur`).
        pub fn on_blur(self: *Self, handle: window_mod.FocusHandle, window: *Window, comptime f: anytype) Subscription {
            return self.focus_listener(window, .focus, .blur, handle.id, f);
        }

        /// Runs `f(this, event, window, cx)` when `handle` or something beneath it loses focus (GPUI `on_focus_out`).
        pub fn on_focus_out(self: *Self, handle: window_mod.FocusHandle, window: *Window, comptime f: anytype) Subscription {
            return self.focus_listener(window, .focus, .focus_out, handle.id, f);
        }

        /// Runs `f(this, window, cx)` when nothing in the window has focus any more, which usually means
        /// the focused element was removed. Use it to pick a default to focus (GPUI `on_focus_lost`).
        pub fn on_focus_lost(self: *Self, window: *Window, comptime f: anytype) Subscription {
            return self.focus_listener(window, .focus_lost, .lost, 0, f);
        }

        fn focus_listener(self: *Self, window: *Window, comptime kind: SubscriberKind, comptime mode: FocusMode, focus: u64, comptime f: anytype) Subscription {
            const S = struct {
                fn call(app: *App, _: EntityId, ctx: usize, payload: ?*const anyopaque) bool {
                    const watch: *const EntityFocus = @ptrFromInt(ctx);
                    const state = app.entities.get(watch.entity) orelse return false;
                    const p: *const focus_events.Payload = @ptrCast(@alignCast(payload.?));
                    const ev = p.event;
                    const hit = switch (mode) {
                        .focus => focus_events.last(ev.previous_focus_path) != watch.focus and focus_events.last(ev.current_focus_path) == watch.focus,
                        .focus_in => ev.is_focus_in(watch.focus),
                        .blur => focus_events.last(ev.previous_focus_path) == watch.focus and focus_events.last(ev.current_focus_path) != watch.focus,
                        .focus_out => ev.is_focus_out(watch.focus),
                        .lost => true,
                    };
                    if (!hit) return true;
                    var c: Context(T) = .{ .app = app, .entity_id_ = watch.entity };
                    const this: *T = @ptrCast(@alignCast(state));
                    if (comptime mode == .focus_out) {
                        const blurred = focus_events.last(ev.previous_focus_path) orelse return true;
                        f(this, focus_events.FocusOutEvent{ .blurred = .{ .id = blurred } }, p.window, &c);
                    } else {
                        f(this, p.window, &c);
                    }
                    return true;
                }
            };
            return self.app.add_owned_subscriber(.{ .kind = kind, .emitter = window.handle_id, .ctx = 0, .func = S.call, .id = 0 }, EntityFocus, .{ .entity = self.entity_id_, .focus = focus });
        }

        /// Runs `f(this, cx)` when the app quits, before it is torn down (GPUI `on_app_quit`).
        pub fn on_app_quit(self: *Self, comptime f: anytype) Subscription {
            const S = struct {
                fn call(app: *App, _: EntityId, ctx: usize, _: ?*const anyopaque) bool {
                    const id = EntityId.from_u64(ctx);
                    const state = app.entities.get(id) orelse return false;
                    var c: Context(T) = .{ .app = app, .entity_id_ = id };
                    f(@as(*T, @ptrCast(@alignCast(state))), &c);
                    return true;
                }
            };
            return self.app.add_subscriber(.{ .kind = .app_quit, .emitter = 0, .ctx = self.entity_id_.as_u64(), .func = S.call, .id = 0 });
        }

        /// Spawns `f(weak_this, window_cx, args...)` on the main thread (GPUI `spawn_in`). `window_cx`
        /// is an `AsyncWindowContext` by value, not a pointer.
        pub fn spawn_in(self: *Self, window: *Window, comptime f: anytype, args: anytype) executor_mod.Task(ReturnOf(f)) {
            const weak: WeakEntity(T) = .{ .entity_id_ = self.entity_id_ };
            const wcx: AsyncWindowContext = .{ .app = self.app, .window_id = window.handle_id };
            return self.app.foreground_executor().spawn(f, .{ weak, wcx } ++ args);
        }

        /// Like `spawn_in`, with a priority. Foreground work runs in order, so it is ignored (as in GPUI).
        pub fn spawn_in_with_priority(self: *Self, priority: executor_mod.Priority, window: *Window, comptime f: anytype, args: anytype) executor_mod.Task(ReturnOf(f)) {
            _ = priority;
            return self.spawn_in(window, f, args);
        }

        // -- App forwarding (GPUI's Context derefs to App) ------------------

        pub fn new(self: *Self, init: anytype) Entity(EntityTypeOf(@TypeOf(init))) {
            return self.app.new(init);
        }
        pub fn global(self: *Self, comptime G: type) *G {
            return self.app.global(G);
        }
        pub fn try_global(self: *Self, comptime G: type) ?*G {
            return self.app.try_global(G);
        }
        pub fn set_global(self: *Self, value: anytype) void {
            self.app.set_global(value);
        }
        pub fn update_global(self: *Self, comptime G: type, comptime f: anytype) ReturnOf(f) {
            return self.app.update_global(G, f);
        }
        pub fn has_global(self: *Self, comptime G: type) bool {
            return self.app.has_global(G);
        }
        pub fn focus_handle(self: *Self) window_mod.FocusHandle {
            return self.app.focus_handle();
        }
        pub fn refresh_windows(self: *Self) void {
            self.app.refresh_windows();
        }
        pub fn quit(self: *Self) void {
            self.app.quit();
        }
        pub fn background_executor(self: *Self) *executor_mod.BackgroundExecutor {
            return self.app.background_executor();
        }
        pub fn foreground_executor(self: *Self) *executor_mod.ForegroundExecutor {
            return self.app.foreground_executor();
        }
        pub fn text_system(self: *Self) *text_system_mod.TextSystem {
            return self.app.text_system();
        }
        pub fn open_window(self: *Self, options: WindowOptions, comptime build_root_view: anytype) !window_mod.WindowHandle(window_mod.RootViewType(build_root_view)) {
            return self.app.open_window(options, build_root_view);
        }
        pub fn dispatch_action(self: *Self, action: anytype) void {
            self.app.dispatch_action(action);
        }
        pub fn write_to_clipboard(self: *Self, item: platform_mod.ClipboardItem) void {
            self.app.write_to_clipboard(item);
        }
        pub fn read_from_clipboard(self: *Self) ?platform_mod.ClipboardItem {
            return self.app.read_from_clipboard();
        }
        pub fn write_to_primary(self: *Self, item: platform_mod.ClipboardItem) void {
            self.app.write_to_primary(item);
        }
        pub fn read_from_primary(self: *Self) ?platform_mod.ClipboardItem {
            return self.app.read_from_primary();
        }
        pub fn defer_(self: *Self, comptime f: anytype) void {
            self.app.defer_(f);
        }
        pub fn allocator(self: *Self) std.mem.Allocator {
            return self.app.allocator;
        }
    };
}

/// Element event listener: a type-erased callback `(event, window, cx)`.
pub fn Listener(comptime E: type) type {
    return struct {
        const Self = @This();
        pub const Event = E;
        ctx: *anyopaque,
        func: *const fn (ctx: *anyopaque, event: *const E, window: *Window, cx: *App) void,

        pub fn call(self: Self, event: *const E, window: *Window, cx: *App) void {
            self.func(self.ctx, event, window, cx);
        }

        /// Builds a listener from a plain `fn(*const E, *Window, *App) void`.
        pub fn from_fn(comptime f: fn (*const E, *Window, *App) void) Self {
            const S = struct {
                fn call(_: *anyopaque, e: *const E, w: *Window, c: *App) void {
                    f(e, w, c);
                }
            };
            return .{ .ctx = @ptrFromInt(1), .func = S.call };
        }
    };
}

/// Coerces a `Listener(E)` or `fn(*const E, *Window, *App) void` into `Listener(E)`.
pub fn to_listener(comptime E: type, h: anytype) Listener(E) {
    const H = @TypeOf(h);
    if (H == Listener(E)) return h;
    if (@typeInfo(H) == .@"fn") return Listener(E).from_fn(h);
    if (@typeInfo(H) == .pointer and @typeInfo(@typeInfo(H).pointer.child) == .@"fn") return Listener(E).from_fn(h.*);
    @compileError("expected a listener for " ++ @typeName(E) ++ ", got " ++ @typeName(H));
}

fn ListenerEvent(comptime f: anytype) type {
    const params = @typeInfo(@TypeOf(f)).@"fn".param_types;
    return @typeInfo(params[1].?).pointer.child;
}

fn ListenerEventWith(comptime f: anytype) type {
    const params = @typeInfo(@TypeOf(f)).@"fn".param_types;
    return @typeInfo(params[2].?).pointer.child;
}

/// The context of a platform completion that runs an app callback: the app, and the caller's
/// context. Freed when it runs, so a completion runs once.
fn PromptCallback(comptime C: type, comptime R: type, comptime f: fn (C, R, *App) void) type {
    return struct {
        const Self = @This();
        app: *App,
        ctx: C,

        fn complete(raw: *anyopaque, result: R) void {
            const self: *Self = @ptrCast(@alignCast(raw));
            const app = self.app;
            const ctx = self.ctx;
            app.allocator.destroy(self);
            f(ctx, result, app);
        }
    };
}

fn dupe_strings(gpa: std.mem.Allocator, items: []const []const u8) std.mem.Allocator.Error![]const []const u8 {
    if (items.len == 0) return &.{};
    const out = try gpa.alloc([]const u8, items.len);
    var done: usize = 0;
    errdefer {
        for (out[0..done]) |s| gpa.free(s);
        gpa.free(out);
    }
    for (items, 0..) |item, i| {
        out[i] = try gpa.dupe(u8, item);
        done = i + 1;
    }
    return out;
}

fn free_strings(gpa: std.mem.Allocator, items: []const []const u8) void {
    if (items.len == 0) return;
    for (items) |s| gpa.free(s);
    gpa.free(items);
}

/// The entity type produced by an initializer passed to `cx.new`.
pub fn EntityTypeOf(comptime I: type) type {
    switch (@typeInfo(I)) {
        .@"fn" => |f| return f.return_type.?,
        .pointer => |p| if (@typeInfo(p.child) == .@"fn") return @typeInfo(p.child).@"fn".return_type.?,
        else => {},
    }
    return I;
}

// ---------------------------------------------------------------------------
// Subscriptions.

/// Callback shape for observers/subscribers; returns false to unsubscribe.
const SubscriberFn = *const fn (app: *App, emitter: EntityId, ctx: usize, payload: ?*const anyopaque) bool;

const SubscriberKind = enum {
    observe,
    event,
    release,
    global,
    window_closed,
    window_appearance,
    /// The titlebar button layout of a window changed (`Window.observe_button_layout_changed`).
    window_button_layout,
    window_bounds,
    window_activation,
    /// A window's focus changed (`Context.on_focus` and its siblings).
    focus,
    /// A window has nothing focused any more (`Context.on_focus_lost`).
    focus_lost,
    app_quit,
    /// An entity of type `event_type` was created (`App.observe_new`).
    new_entity,
    /// Graphemes that no font drew (`App.on_missing_glyphs`).
    missing_glyphs,
    /// A window's visibility changed (`Window.observe_window_visibility`).
    window_visibility,
    /// A window moved to another display, or its display changed (`Window.observe_window_display`).
    window_display,
    /// A display was added, removed or changed (`App.observe_displays`).
    displays,
    /// The keyboard layout changed (`App.on_keyboard_layout_change`).
    keyboard_layout,
    /// The app was reopened (`App.on_reopen`).
    reopen,
    /// The app is about to restart (`App.on_app_restart`).
    app_restart,
};

/// When the cursor is hidden in response to typing (GPUI `CursorHideMode`). The cursor comes back
/// when the mouse moves.
pub const CursorHideMode = enum {
    /// Never hide the cursor automatically.
    never,
    /// Hide on character-producing key presses (typing).
    on_typing,
    /// Hide on character-producing key presses, and when a key binding resolves to an action
    /// that consumes the keystroke.
    on_typing_and_action,
};

/// A display's bounds, as the app last saw them. Ids are the platform's.
const DisplayState = struct { id: platform_mod.DisplayId, bounds: geometry.Bounds(Pixels) };

/// A context allocated for one subscriber. `Subscriber.ctx` is its address, and `free` releases it
/// when the subscriber goes away.
const OwnedContext = struct {
    ptr: *anyopaque,
    free: *const fn (std.mem.Allocator, *anyopaque) void,
};

const Subscriber = struct {
    kind: SubscriberKind,
    emitter: u64,
    event_type: ?TypeId = null,
    ctx: usize,
    func: SubscriberFn,
    active: bool = true,
    id: u64,
    owned: ?OwnedContext = null,
};

/// A subscription handle (GPUI `Subscription`). Call `unsubscribe` to stop
/// it; `detach` (or just discarding it) keeps it alive for the app's life.
/// The value being dragged, with its type erased (GPUI's `&dyn Any` on a drag).
pub const AnyDragValue = struct {
    ptr: *anyopaque,
    type_id: TypeId,

    pub fn is(self: AnyDragValue, comptime T: type) bool {
        return self.type_id == type_id(T);
    }
    pub fn downcast(self: AnyDragValue, comptime T: type) ?*const T {
        if (!self.is(T)) return null;
        return @ptrCast(@alignCast(self.ptr));
    }
};

/// A drag in progress (GPUI `AnyDrag`). The value is copied when the drag starts, so
/// plain data needs no care. Slices inside it must outlive the drag.
pub const AnyDrag = struct {
    value: AnyDragValue,
    view: view_mod.AnyView,
    cursor_offset: geometry.Point(Pixels),
    cursor_style: ?style_mod.CursorStyle = null,
    free_value: ?*const fn (std.mem.Allocator, *anyopaque) void = null,
};

pub const Subscription = struct {
    app: ?*App,
    id: u64,
    /// Nonzero for a subscription made by `join`: `group - 1` indexes `App.subscription_groups`.
    group: u32 = 0,

    /// Joins two subscriptions into one that unsubscribes both (GPUI `Subscription::join`).
    /// Both belong to the same app. The joined ids are kept by the app until it is deinitialized.
    pub fn join(a: Subscription, b: Subscription) Subscription {
        const app = a.app orelse return b;
        var ids: std.ArrayList(u64) = .empty;
        a.append_ids(&ids, app);
        b.append_ids(&ids, app);
        app.subscription_groups.append(app.allocator, ids) catch oom();
        return .{ .app = app, .id = 0, .group = @intCast(app.subscription_groups.items.len) };
    }

    fn append_ids(self: Subscription, ids: *std.ArrayList(u64), app: *App) void {
        if (self.group == 0) {
            ids.append(app.allocator, self.id) catch oom();
            return;
        }
        for (app.subscription_groups.items[self.group - 1].items) |id| ids.append(app.allocator, id) catch oom();
    }

    pub fn detach(self: Subscription) void {
        _ = self;
    }
    pub fn unsubscribe(self: Subscription) void {
        const app = self.app orelse return;
        if (self.group == 0) return app.deactivate_subscriber(self.id);
        for (app.subscription_groups.items[self.group - 1].items) |id| app.deactivate_subscriber(id);
    }
    pub fn deinit(self: Subscription) void {
        self.unsubscribe();
    }
};

// ---------------------------------------------------------------------------
// Effects.

/// Whether a keystroke should prefer character input or key bindings (GPUI `InputPreference`).
pub const InputPreference = enum {
    /// Prefer typing text over triggering key bindings.
    character_input,
    /// Dispatch key bindings normally, if any match.
    key_bindings,
};

/// What a keystroke did (GPUI `KeystrokeEvent`). Valid during the call.
pub const KeystrokeEvent = struct {
    keystroke: keystroke_mod.Keystroke,
    /// Whether this keystroke should prefer character input or key bindings. It is `character_input`
    /// when the platform prefers text for the key (AltGr on Windows) and the focused input accepts
    /// text. Interceptors still receive these keystrokes and can consume them. A multi-stroke
    /// binding still waits as pending input even then.
    input_preference: InputPreference = .key_bindings,
    /// The action it resolved to. Always null for interceptors, which run first.
    action: ?action_mod.AnyAction = null,
    context_stack: []const keymap_mod.KeyContext = &.{},
};

const KeystrokeObserverKey = struct {};
const KeystrokeInterceptorKey = struct {};
const PendingInputObserverKey = struct {};
const KeystrokePayload = struct { event: *const KeystrokeEvent, window: *Window };

const Effect = union(enum) {
    notify: EntityId,
    emit: struct { emitter: EntityId, event_type: TypeId, payload: *const anyopaque },
    global_changed: TypeId,
    deferred: struct { ctx: usize, func: *const fn (*App, usize) void },
    refresh_windows,
    close_window: window_mod.WindowId,
};

// ---------------------------------------------------------------------------
// App.

const GlobalSlot = struct { ptr: *anyopaque, destroy: *const fn (std.mem.Allocator, *anyopaque) void };

/// When the app quits by itself, after its last window closes (GPUI `QuitMode`).
pub const QuitMode = enum {
    /// What the platform does: quit when the last window closes, except on macOS.
    default,
    /// Never quit by itself; `quit` must be called.
    explicit,
    /// Quit when the last window closes, on every platform.
    last_window_closed,
};

/// The global application state (GPUI `App`).
/// A type-erased `on_system_notification_response` handler: `func(ctx, response, app)`.
const SystemNotificationHandler = struct {
    ctx: *anyopaque,
    func: *const fn (*anyopaque, platform_mod.SystemNotificationResponse, *App) void,
    /// Frees `ctx`, which was allocated with the app's allocator.
    free: *const fn (std.mem.Allocator, *anyopaque) void,
};

pub const App = struct {
    allocator: std.mem.Allocator,
    /// The drag following the pointer, across all windows.
    active_drag: ?AnyDrag = null,
    platform: *platform_mod.Platform,
    /// The last power mode the platform reported (GPUI `App::power_mode`), kept current by the listener.
    power_mode_: platform_mod.PowerMode = .unknown,
    system_notification_response: ?SystemNotificationHandler = null,
    /// The binary `restart` starts instead of this one (GPUI `set_restart_path`). Owned.
    restart_path: ?[]u8 = null,
    /// The arguments `restart` passes (GPUI `with_restart_arguments`). Owned, each one too.
    restart_arguments: []const []const u8 = &.{},
    entities: EntityMap = .{},
    windows: std.ArrayList(?*Window) = .empty,
    globals: std.AutoHashMapUnmanaged(TypeId, GlobalSlot) = .empty,
    subscribers: std.ArrayList(Subscriber) = .empty,
    next_subscription_id: u64 = 1,
    /// The `on_missing_glyphs` subscriber, if one is registered (GPUI keeps one callback slot).
    missing_glyph_subscription: ?u64 = null,
    pending_effects: std.ArrayList(Effect) = .empty,
    flushing_effects: bool = false,
    pending_updates: u32 = 0,
    /// Arena for effect payloads; reset after each flush.
    effect_arena: std.heap.ArenaAllocator,
    text_system_: *text_system_mod.TextSystem,
    /// Replaces the in-window prompt (GPUI `prompt_builder`). Null means GPUI's fallback.
    prompt_builder: ?window_mod.PromptBuilder = null,
    /// Named assets for `img()` and `svg()` (set with `Application.with_assets`). Read it with `asset_source()`.
    asset_source_: assets_mod.AssetSource = assets_mod.AssetSource.empty,
    /// Decoded images, decoded once per source.
    asset_cache: assets_mod.AssetCache,
    /// Background loads of `use_asset` and of image caches (GPUI `loading_assets`).
    asset_loads: asset_cache_mod.AssetLoads = undefined,
    background_executor_: executor_mod.BackgroundExecutor,
    foreground_executor_: executor_mod.ForegroundExecutor,
    keymap: keymap_mod.Keymap,
    actions: action_mod.ActionRegistry,
    global_action_listeners: std.ArrayList(action_mod.GlobalActionListener) = .empty,
    next_focus_id: u64 = 1,
    quitting: bool = false,
    /// `shutdown` has run; it runs once.
    shut_down: bool = false,
    quit_mode: QuitMode = .default,
    /// Read it with `reduce_motion()`.
    reduce_motion_: bool = false,
    /// The name set with `TestAppContext.set_name`, read with `get_name()`. Null otherwise.
    name_: ?[]const u8 = null,
    /// When the app's shared animation clock started; `repeat_synced` phases count from here (GPUI `synced_animation_epoch`).
    synced_animation_epoch: u64 = 0,
    /// Set by `propagate`. A bubble-phase action listener stops propagation by default, and calls
    /// `propagate` to let the action reach the handlers above it.
    propagate_event: bool = true,
    /// The subscription ids each `Subscription.join` made. Freed by `deinit`.
    subscription_groups: std.ArrayList(std.ArrayList(u64)) = .empty,
    /// The displays as of the last display notification. Diffed to produce `DisplayEvent`s.
    display_snapshot: std.ArrayList(DisplayState) = .empty,
    /// Hides the cursor on keyboard input (GPUI `cursor_hide_mode`).
    cursor_hide_mode_: CursorHideMode = .on_typing_and_action,
    /// Storage for `window_stack`; its slice is valid until the next call.
    window_stack_storage: std.ArrayList(window_mod.AnyWindowHandle) = .empty,
    async_app: AsyncApp = undefined,

    pub fn init(allocator: std.mem.Allocator, platform: *platform_mod.Platform) !*App {
        const app = try allocator.create(App);
        app.* = .{
            .allocator = allocator,
            .platform = platform,
            .effect_arena = .init(allocator),
            .text_system_ = try text_system_mod.TextSystem.create(allocator),
            .asset_cache = assets_mod.AssetCache.init(allocator),
            .background_executor_ = executor_mod.BackgroundExecutor.init(allocator, platform),
            .foreground_executor_ = executor_mod.ForegroundExecutor.init(allocator, platform),
            .keymap = keymap_mod.Keymap.init(allocator),
            .actions = action_mod.ActionRegistry.init(allocator),
        };
        app.async_app = .{ .app = app };
        platform.on_power_mode_change(.{ .ctx = app, .func = App.on_power_mode_changed });
        app.synced_animation_epoch = executor_mod.now_ns();
        app.foreground_executor_.app = app;
        app.asset_loads = asset_cache_mod.AssetLoads.init(allocator, app, &app.foreground_executor_);
        app.asset_cache.fetch_config = .{
            .foreground = &app.foreground_executor_,
            .on_settled_ctx = app,
            .on_settled = struct {
                fn redraw(ctx: *anyopaque) void {
                    const self: *App = @ptrCast(@alignCast(ctx));
                    self.refresh_windows();
                }
            }.redraw,
        };
        platform.set_callbacks(.{
            .ctx = app,
            .keyboard_layout_changed = struct {
                fn f(ctx: *anyopaque) void {
                    const self: *App = @ptrCast(@alignCast(ctx));
                    self.dispatch_keyboard_layout_change();
                }
            }.f,
        });
        // GPUI's `App::new` registers displays and the app menu callbacks the same way.
        platform.on_displays_changed(.{ .ctx = app, .func = struct {
            fn f(ctx: *anyopaque) void {
                const self: *App = @ptrCast(@alignCast(ctx));
                self.displays_changed();
            }
        }.f });
        platform.on_will_open_app_menu(.{ .ctx = app, .func = struct {
            fn f(ctx: *anyopaque) void {
                const self: *App = @ptrCast(@alignCast(ctx));
                self.clear_pending_keystrokes();
            }
        }.f });
        platform.on_validate_app_menu_command(.{ .ctx = app, .func = struct {
            fn f(ctx: *anyopaque, action: action_mod.AnyAction) bool {
                const self: *App = @ptrCast(@alignCast(ctx));
                return self.is_action_type_available(action.type_id);
            }
        }.f });
        platform.on_app_menu_action(.{ .ctx = app, .func = struct {
            fn f(ctx: *anyopaque, action: action_mod.AnyAction) void {
                const self: *App = @ptrCast(@alignCast(ctx));
                self.dispatch_any_action(action);
            }
        }.f });
        app.read_display_snapshot() catch oom();
        return app;
    }

    pub fn deinit(self: *App) void {
        self.shutdown();
        // The platform must not call back into an app that is going away.
        self.platform.clear_app_listeners();
        self.display_snapshot.deinit(self.allocator);
        self.window_stack_storage.deinit(self.allocator);
        if (self.system_notification_response) |h| h.free(self.allocator, h.ctx);
        self.system_notification_response = null;
        if (self.restart_path) |path| self.allocator.free(path);
        self.restart_path = null;
        free_strings(self.allocator, self.restart_arguments);
        self.restart_arguments = &.{};
        // Each slot is cleared before its window is destroyed, as close_window does, so a window
        // being destroyed is never seen again by is_root_of_other_window.
        for (self.windows.items) |*slot| {
            const win = slot.* orelse continue;
            slot.* = null;
            win.destroy(self);
        }
        for (self.entities.slots.items) |*s| if (s.ptr) |p| {
            if (s.destroy) |d| d(self, p);
        };
        // After the entities: a released image cache releases its loads itself. The window list is
        // still needed then (drop_image walks it), so it is freed last.
        self.asset_loads.deinit();
        self.windows.deinit(self.allocator);
        self.entities.slots.deinit(self.allocator);
        self.entities.free.deinit(self.allocator);
        var it = self.globals.valueIterator();
        while (it.next()) |g| g.destroy(self.allocator, g.ptr);
        self.globals.deinit(self.allocator);
        // Subscribers that were never compacted still own their contexts.
        for (self.subscribers.items) |s| if (s.owned) |o| o.free(self.allocator, o.ptr);
        self.subscribers.deinit(self.allocator);
        for (self.subscription_groups.items) |*g| g.deinit(self.allocator);
        self.subscription_groups.deinit(self.allocator);
        self.pending_effects.deinit(self.allocator);
        self.effect_arena.deinit();
        self.text_system_.destroy();
        self.asset_cache.deinit();
        self.background_executor_.deinit();
        self.foreground_executor_.deinit();
        self.keymap.deinit();
        self.actions.deinit();
        self.global_action_listeners.deinit(self.allocator);
        const a = self.allocator;
        a.destroy(self);
    }

    // -- entities --------------------------------------------------------

    /// Creates a new entity (GPUI `cx.new(|cx| T)`).
    ///
    /// `init` is either a `T` value, or `fn(*Context(T)) T`.
    pub fn new(self: *App, initializer: anytype) Entity(EntityTypeOf(@TypeOf(initializer))) {
        const T = EntityTypeOf(@TypeOf(initializer));
        const id = self.entities.reserve(self.allocator);
        const ptr = self.allocator.create(T) catch oom();
        const slot = &self.entities.slots.items[id.index()];
        slot.* = .{
            .ptr = null,
            .tid = type_id(T),
            .generation = id.generation(),
            .destroy = struct {
                fn d(app: *App, p: *anyopaque) void {
                    const t: *T = @ptrCast(@alignCast(p));
                    if (@hasDecl(T, "deinit")) {
                        const F = @typeInfo(@TypeOf(T.deinit)).@"fn";
                        if (F.param_types.len == 1) t.deinit() else t.deinit(app);
                    }
                    app.allocator.destroy(t);
                }
            }.d,
        };
        if (@TypeOf(initializer) == T) {
            ptr.* = initializer;
        } else {
            var ctx: Context(T) = .{ .app = self, .entity_id_ = id };
            self.pending_updates += 1;
            ptr.* = initializer(&ctx);
            self.pending_updates -= 1;
        }
        self.entities.slots.items[id.index()].ptr = ptr;
        self.notify_new_entity(T, id, ptr);
        return .{ .entity_id_ = id };
    }

    /// Reserves an entity id to be filled later with `insert_entity`.
    pub fn reserve_entity(self: *App, comptime T: type) Reservation(T) {
        return .{ .entity_id_ = self.entities.reserve(self.allocator) };
    }

    pub fn insert_entity(self: *App, reservation: anytype, initializer: anytype) Entity(@TypeOf(reservation).Type) {
        const T = @TypeOf(reservation).Type;
        const id = reservation.entity_id_;
        const ptr = self.allocator.create(T) catch oom();
        var ctx: Context(T) = .{ .app = self, .entity_id_ = id };
        ptr.* = if (@TypeOf(initializer) == T) initializer else initializer(&ctx);
        self.entities.slots.items[id.index()] = .{ .ptr = ptr, .tid = type_id(T), .generation = id.generation(), .destroy = struct {
            fn d(app: *App, p: *anyopaque) void {
                app.allocator.destroy(@as(*T, @ptrCast(@alignCast(p))));
            }
        }.d };
        self.notify_new_entity(T, id, ptr);
        return .{ .entity_id_ = id };
    }

    pub fn update_entity(self: *App, comptime T: type, handle: Entity(T), comptime f: anytype, args: anytype) ReturnOf(f) {
        const raw = self.entities.get(handle.entity_id_) orelse @panic("entity released");
        const state: *T = @ptrCast(@alignCast(raw));
        var ctx: Context(T) = .{ .app = self, .entity_id_ = handle.entity_id_ };
        self.pending_updates += 1;
        defer {
            self.pending_updates -= 1;
            if (self.pending_updates == 0) self.flush_effects();
        }
        return @call(.auto, f, .{state} ++ args ++ .{&ctx});
    }

    pub fn has_active_drag(self: *const App) bool {
        return self.active_drag != null;
    }

    pub fn active_drag_cursor_style(self: *const App) ?style_mod.CursorStyle {
        return if (self.active_drag) |d| d.cursor_style else null;
    }

    pub fn set_active_drag_cursor_style(self: *App, cursor_style: style_mod.CursorStyle, window: *Window) void {
        if (self.active_drag) |*d| {
            d.cursor_style = cursor_style;
            window.refresh();
        }
    }

    /// Cancels the drag. Returns true if there was one.
    pub fn stop_active_drag(self: *App, window: *Window) bool {
        if (self.active_drag == null) return false;
        self.clear_active_drag();
        window.refresh();
        return true;
    }

    pub fn set_active_drag(self: *App, drag: AnyDrag) void {
        self.clear_active_drag();
        self.active_drag = drag;
    }

    /// Ends the drag and releases what it owns: its copy of the value and its view.
    pub fn clear_active_drag(self: *App) void {
        const drag = self.active_drag orelse return;
        self.active_drag = null;
        if (drag.free_value) |free| free(self.allocator, drag.value.ptr);
        self.release_entity(drag.view.entity_id);
    }

    pub fn release_entity(self: *App, id: EntityId) void {
        const i = id.index();
        if (i >= self.entities.slots.items.len) return;
        {
            const s = &self.entities.slots.items[i];
            if (s.generation != id.generation() or s.ptr == null) return;
        }
        const p = self.entities.slots.items[i].ptr.?;
        // Release listeners see the state before it's destroyed. By index: a listener may
        // subscribe, which can move the list.
        var k: usize = 0;
        while (k < self.subscribers.items.len) : (k += 1) {
            const sub = self.subscribers.items[k];
            if (sub.active and sub.kind == .release and sub.emitter == id.as_u64()) {
                self.subscribers.items[k].active = false;
                _ = sub.func(self, id, sub.ctx, p);
            }
        }
        // Re-fetched: a listener may have created entities, which can move the slots.
        const s = &self.entities.slots.items[i];
        if (s.destroy) |d| d(self, p);
        s.ptr = null;
        s.generation +%= 1;
        if (s.generation == 0) s.generation = 1;
        self.entities.free.append(self.allocator, @intCast(i)) catch oom();
    }

    // -- notifications & effects ----------------------------------------

    pub fn notify(self: *App, id: EntityId) void {
        self.push_effect(.{ .notify = id });
    }

    pub fn emit_event(self: *App, comptime T: type, emitter: EntityId, event: T.Event) void {
        const p = self.effect_arena.allocator().create(T.Event) catch oom();
        p.* = event;
        self.push_effect(.{ .emit = .{ .emitter = emitter, .event_type = type_id(T.Event), .payload = p } });
    }

    fn push_effect(self: *App, e: Effect) void {
        self.pending_effects.append(self.allocator, e) catch oom();
        if (self.pending_updates == 0) self.flush_effects();
    }

    /// Runs `f` with this app and flushes effects afterwards (GPUI `App::update`).
    pub fn update(self: *App, comptime f: anytype, args: anytype) ReturnOf(f) {
        self.pending_updates += 1;
        defer {
            self.pending_updates -= 1;
            if (self.pending_updates == 0) self.flush_effects();
        }
        return @call(.auto, f, args ++ .{self});
    }

    pub fn flush_effects(self: *App) void {
        if (self.flushing_effects) return;
        self.flushing_effects = true;
        defer self.flushing_effects = false;
        var i: usize = 0;
        while (i < self.pending_effects.items.len) : (i += 1) {
            const e = self.pending_effects.items[i];
            switch (e) {
                .notify => |id| self.apply_notify(id),
                .emit => |em| self.apply_emit(em.emitter, em.event_type, em.payload),
                .global_changed => |tid| self.apply_global_changed(tid),
                .deferred => |d| d.func(self, d.ctx),
                .refresh_windows => for (self.windows.items) |w| if (w) |win| win.refresh(),
                .close_window => |id| if (self.window_by_id(id)) |win| self.close_window(win),
            }
        }
        self.pending_effects.clearRetainingCapacity();
        _ = self.effect_arena.reset(.retain_capacity);
        self.compact_subscribers();
    }

    fn apply_notify(self: *App, id: EntityId) void {
        for (self.windows.items) |w| if (w) |win| win.on_entity_notified(id);
        const n = self.subscribers.items.len;
        for (0..n) |k| {
            const s = self.subscribers.items[k];
            if (s.active and s.kind == .observe and s.emitter == id.as_u64()) {
                if (!s.func(self, id, s.ctx, null)) self.subscribers.items[k].active = false;
            }
        }
    }

    fn apply_emit(self: *App, emitter: EntityId, tid: TypeId, payload: *const anyopaque) void {
        const n = self.subscribers.items.len;
        for (0..n) |k| {
            const s = self.subscribers.items[k];
            if (s.active and s.kind == .event and s.emitter == emitter.as_u64() and s.event_type == tid) {
                if (!s.func(self, emitter, s.ctx, payload)) self.subscribers.items[k].active = false;
            }
        }
    }

    fn apply_global_changed(self: *App, tid: TypeId) void {
        const n = self.subscribers.items.len;
        for (0..n) |k| {
            const s = self.subscribers.items[k];
            if (s.active and s.kind == .global and s.event_type == tid) {
                if (!s.func(self, EntityId.from_u64(0), s.ctx, null)) self.subscribers.items[k].active = false;
            }
        }
    }

    fn compact_subscribers(self: *App) void {
        var j: usize = 0;
        for (self.subscribers.items) |s| {
            if (s.active) {
                self.subscribers.items[j] = s;
                j += 1;
            } else if (s.owned) |o| {
                o.free(self.allocator, o.ptr);
            }
        }
        self.subscribers.shrinkRetainingCapacity(j);
    }

    fn add_subscriber(self: *App, s: Subscriber) Subscription {
        var sub = s;
        sub.id = self.next_subscription_id;
        self.next_subscription_id += 1;
        self.subscribers.append(self.allocator, sub) catch oom();
        return .{ .app = self, .id = sub.id };
    }

    /// Adds a subscriber whose context is a copy of `value`. The copy lives until the subscriber
    /// is removed (unsubscribed, or it returned false), so the callback can read it through `ctx`.
    fn add_owned_subscriber(self: *App, s: Subscriber, comptime Ctx: type, value: Ctx) Subscription {
        const Free = struct {
            fn free(a: std.mem.Allocator, raw: *anyopaque) void {
                a.destroy(@as(*Ctx, @ptrCast(@alignCast(raw))));
            }
        };
        const ptr = self.allocator.create(Ctx) catch oom();
        ptr.* = value;
        var sub = s;
        sub.ctx = @intFromPtr(ptr);
        sub.owned = .{ .ptr = ptr, .free = Free.free };
        return self.add_subscriber(sub);
    }

    /// Runs the `kind` subscribers of `win` with `payload`. Used for focus changes, which need both
    /// the event and the window.
    pub fn dispatch_window_payload(self: *App, kind: SubscriberKind, win: *Window, payload: *const anyopaque) void {
        self.pending_updates += 1;
        defer {
            self.pending_updates -= 1;
            if (self.pending_updates == 0) self.flush_effects();
        }
        var i: usize = 0;
        while (i < self.subscribers.items.len) : (i += 1) {
            const sub = self.subscribers.items[i];
            if (!sub.active or sub.kind != kind or sub.emitter != @as(u64, win.handle_id)) continue;
            if (!sub.func(self, EntityId.from_u64(0), sub.ctx, payload)) self.subscribers.items[i].active = false;
        }
    }

    /// Runs `f(this, window, cx)`-style observers of new entities: every `observe_new` callback for
    /// `T` gets the entity that was just created.
    fn notify_new_entity(self: *App, comptime T: type, id: EntityId, ptr: *T) void {
        self.pending_updates += 1;
        defer {
            self.pending_updates -= 1;
            if (self.pending_updates == 0) self.flush_effects();
        }
        var i: usize = 0;
        while (i < self.subscribers.items.len) : (i += 1) {
            const sub = self.subscribers.items[i];
            if (!sub.active or sub.kind != .new_entity or sub.event_type != type_id(T)) continue;
            if (!sub.func(self, id, sub.ctx, ptr)) self.subscribers.items[i].active = false;
        }
    }

    /// Calls `f(this, window, cx)` for every entity of type `T` created from now on (GPUI
    /// `observe_new`). `window` is always null: ZUI does not know which window an entity will be
    /// drawn in when it is created, so an app that needs one must find it in a later update.
    pub fn observe_new(self: *App, comptime T: type, comptime f: fn (*T, ?*Window, *Context(T)) void) Subscription {
        const S = struct {
            fn call(app: *App, id: EntityId, _: usize, payload: ?*const anyopaque) bool {
                const this: *T = @ptrCast(@alignCast(@constCast(payload.?)));
                var c: Context(T) = .{ .app = app, .entity_id_ = id };
                f(this, null, &c);
                return true;
            }
        };
        return self.add_subscriber(.{ .kind = .new_entity, .emitter = 0, .event_type = type_id(T), .ctx = 0, .func = S.call, .id = 0 });
    }

    /// Runs the `on_app_quit` handlers once (GPUI `shutdown`). `Application.run` calls it when the
    /// platform loop has ended, and `deinit` calls it too. Windows and entities still exist.
    pub fn shutdown(self: *App) void {
        if (self.shut_down) return;
        self.shut_down = true;
        self.pending_updates += 1;
        var i: usize = 0;
        while (i < self.subscribers.items.len) : (i += 1) {
            const sub = self.subscribers.items[i];
            if (!sub.active or sub.kind != .app_quit) continue;
            // Handlers are removed once they have run, as GPUI's are.
            self.subscribers.items[i].active = false;
            _ = sub.func(self, EntityId.from_u64(0), sub.ctx, null);
        }
        self.pending_updates -= 1;
        if (self.pending_updates == 0) self.flush_effects();
    }

    /// Runs `f(cx)` when the app quits (GPUI `App::on_app_quit`). Runs once, from `shutdown`.
    pub fn on_app_quit(self: *App, comptime f: fn (*App) void) Subscription {
        const S = struct {
            fn call(app: *App, _: EntityId, _: usize, _: ?*const anyopaque) bool {
                f(app);
                return true;
            }
        };
        return self.add_subscriber(.{ .kind = .app_quit, .emitter = 0, .ctx = 0, .func = S.call, .id = 0 });
    }

    /// Sets when the app quits by itself (GPUI `set_quit_mode`).
    pub fn set_quit_mode(self: *App, mode: QuitMode) void {
        self.quit_mode = mode;
    }

    pub fn add_observer(self: *App, observed: EntityId, ctx: usize, func: SubscriberFn) Subscription {
        return self.add_subscriber(.{ .kind = .observe, .emitter = observed.as_u64(), .ctx = ctx, .func = func, .id = 0 });
    }

    pub fn add_event_listener(self: *App, emitter: EntityId, event_type: TypeId, ctx: usize, func: SubscriberFn) Subscription {
        return self.add_subscriber(.{ .kind = .event, .emitter = emitter.as_u64(), .event_type = event_type, .ctx = ctx, .func = func, .id = 0 });
    }

    pub fn add_release_listener(self: *App, entity: EntityId, func: SubscriberFn) Subscription {
        return self.add_subscriber(.{ .kind = .release, .emitter = entity.as_u64(), .ctx = 0, .func = func, .id = 0 });
    }

    pub fn add_global_observer(self: *App, tid: TypeId, ctx: usize, func: SubscriberFn) Subscription {
        return self.add_subscriber(.{ .kind = .global, .emitter = 0, .event_type = tid, .ctx = ctx, .func = func, .id = 0 });
    }

    /// Observes an entity from outside any entity: `f(observed, cx)`.
    pub fn observe(self: *App, observed: anytype, comptime f: anytype) Subscription {
        const E = @TypeOf(observed);
        const S = struct {
            fn call(app: *App, emitter: EntityId, _: usize, _: ?*const anyopaque) bool {
                f(E{ .entity_id_ = emitter }, app);
                return true;
            }
        };
        return self.add_observer(observed.entity_id(), 0, S.call);
    }

    fn deactivate_subscriber(self: *App, id: u64) void {
        for (self.subscribers.items) |*s| if (s.id == id) {
            s.active = false;
        };
        // Dropping the `on_missing_glyphs` subscription stops the collection, as in GPUI.
        if (self.missing_glyph_subscription == id) {
            self.missing_glyph_subscription = null;
            self.text_system_.set_missing_glyph_reporting(false);
        }
    }

    /// Calls `f(missing, cx)` with the graphemes that no font could draw, after the frame that shaped
    /// them (GPUI `on_missing_glyphs`). Registering a callback replaces the previous one. Unsubscribing
    /// stops the reports. The slice is valid for the call only.
    pub fn on_missing_glyphs(self: *App, comptime f: fn ([]const text_system_mod.MissingGlyph, *App) void) Subscription {
        if (self.missing_glyph_subscription) |old| self.deactivate_subscriber(old);
        const S = struct {
            fn call(app: *App, _: EntityId, _: usize, payload: ?*const anyopaque) bool {
                const glyphs: *const []const text_system_mod.MissingGlyph = @ptrCast(@alignCast(payload.?));
                f(glyphs.*, app);
                return true;
            }
        };
        const sub = self.add_subscriber(.{ .kind = .missing_glyphs, .emitter = 0, .ctx = 0, .func = S.call, .id = 0 });
        self.missing_glyph_subscription = sub.id;
        self.text_system_.set_missing_glyph_reporting(true);
        return sub;
    }

    /// Delivers the missing glyphs reported since the last call to the `on_missing_glyphs` callback.
    /// Windows call it after each frame, since shaping happens in the frame.
    pub fn dispatch_missing_glyphs(self: *App) void {
        if (self.missing_glyph_subscription == null) return;
        const glyphs = self.text_system_.take_missing_glyphs() catch return;
        defer self.text_system_.free_missing_glyphs(glyphs);
        if (glyphs.len == 0) return;
        self.pending_updates += 1;
        const view: []const text_system_mod.MissingGlyph = glyphs;
        const payload: *const anyopaque = @ptrCast(&view);
        var i: usize = 0;
        while (i < self.subscribers.items.len) : (i += 1) {
            const sub = self.subscribers.items[i];
            if (!sub.active or sub.kind != .missing_glyphs) continue;
            if (!sub.func(self, EntityId.from_u64(0), sub.ctx, payload)) self.subscribers.items[i].active = false;
        }
        self.pending_updates -= 1;
        if (self.pending_updates == 0) self.flush_effects();
    }

    /// Runs `f(released, cx)` when `observed` is released, once (GPUI `App::observe_release`).
    /// `released` is the entity's state, valid for the call only.
    pub fn observe_release(self: *App, observed: anytype, comptime f: anytype) Subscription {
        const T2 = @TypeOf(observed).Type;
        const S = struct {
            fn call(app: *App, _: EntityId, _: usize, payload: ?*const anyopaque) bool {
                const released: *T2 = @ptrCast(@alignCast(@constCast(payload.?)));
                f(released, app);
                return false;
            }
        };
        return self.add_release_listener(observed.entity_id(), S.call);
    }

    /// Runs `f(released, window, cx)` when `observed` is released, once (GPUI
    /// `App::observe_release_in`). Does nothing if `window` has closed by then.
    pub fn observe_release_in(self: *App, observed: anytype, window: *Window, comptime f: anytype) Subscription {
        const T2 = @TypeOf(observed).Type;
        const S = struct {
            fn call(app: *App, _: EntityId, ctx: usize, payload: ?*const anyopaque) bool {
                const win = app.window_by_id(@intCast(ctx)) orelse return false;
                const released: *T2 = @ptrCast(@alignCast(@constCast(payload.?)));
                f(released, win, app);
                return false;
            }
        };
        return self.add_subscriber(.{ .kind = .release, .emitter = observed.entity_id().as_u64(), .ctx = window.handle_id, .func = S.call, .id = 0 });
    }

    /// Lets the action being dispatched continue to the handlers above the one that called this
    /// (GPUI `App::propagate`). Action handlers stop propagation by default during the bubble phase.
    pub fn propagate(self: *App) void {
        self.propagate_event = true;
    }

    /// Runs `f(view, window, cx, args...)` in the window, where `view` is its root view (GPUI
    /// `App::update_window`). Fails with `error.WindowClosed` when the window is gone.
    pub fn update_window(self: *App, handle: window_mod.AnyWindowHandle, comptime f: anytype, args: anytype) error{WindowClosed}!ReturnOf(f) {
        const win = self.window_by_id(handle.id) orelse return error.WindowClosed;
        const view = win.root orelse return error.WindowClosed;
        const result = @call(.auto, f, .{ view, win, self } ++ args);
        self.flush_effects();
        return result;
    }

    /// Runs `f(root_entity, cx, args...)` with the window's root view (GPUI `App::read_window`).
    /// `V` is the root view type of `handle`.
    pub fn read_window(self: *App, comptime V: type, handle: window_mod.WindowHandle(V), comptime f: anytype, args: anytype) error{WindowClosed}!ReturnOf(f) {
        _ = self.window_by_id(handle.window_id) orelse return error.WindowClosed;
        const entity: Entity(V) = .{ .entity_id_ = handle.entity_id_ };
        return @call(.auto, f, .{ entity, self } ++ args);
    }

    /// Subscribes to an entity's events from outside any entity: `f(emitter, event, cx)`.
    pub fn subscribe(self: *App, emitter: anytype, comptime f: anytype) Subscription {
        const EH = @TypeOf(emitter);
        const Ev = EH.Type.Event;
        const S = struct {
            fn call(app: *App, from: EntityId, _: usize, payload: ?*const anyopaque) bool {
                f(EH{ .entity_id_ = from }, @as(*const Ev, @ptrCast(@alignCast(payload.?))), app);
                return true;
            }
        };
        return self.add_event_listener(emitter.entity_id(), type_id(Ev), 0, S.call);
    }

    /// Schedules `f(cx)` to run at the end of the current effect cycle (GPUI `App::defer`). Zig has no
    /// closures, so `f` is a function and takes no captures.
    pub fn @"defer"(self: *App, comptime f: anytype) void {
        const S = struct {
            fn call(app: *App, _: usize) void {
                f(app);
            }
        };
        self.push_effect(.{ .deferred = .{ .ctx = 0, .func = S.call } });
    }
    /// The name `defer` had before it matched GPUI.
    pub const defer_ = @"defer";

    /// Schedules `f(window, cx)` at the end of the current effect cycle, if the window with `id` still
    /// exists (the work of GPUI `Window::defer`).
    pub fn defer_window(self: *App, id: window_mod.WindowId, comptime f: fn (*Window, *App) void) void {
        const S = struct {
            fn call(app: *App, ctx: usize) void {
                const win = app.window_by_id(@intCast(ctx)) orelse return;
                f(win, app);
            }
        };
        self.push_effect(.{ .deferred = .{ .ctx = @intCast(id), .func = S.call } });
    }

    // -- globals ---------------------------------------------------------

    pub fn set_global(self: *App, value: anytype) void {
        const G = @TypeOf(value);
        const tid = type_id(G);
        if (self.globals.get(tid)) |slot| {
            @as(*G, @ptrCast(@alignCast(slot.ptr))).* = value;
        } else {
            const p = self.allocator.create(G) catch oom();
            p.* = value;
            self.globals.put(self.allocator, tid, .{ .ptr = p, .destroy = struct {
                fn d(a: std.mem.Allocator, raw: *anyopaque) void {
                    a.destroy(@as(*G, @ptrCast(@alignCast(raw))));
                }
            }.d }) catch oom();
        }
        self.push_effect(.{ .global_changed = tid });
    }

    pub fn global(self: *App, comptime G: type) *G {
        return self.try_global(G) orelse @panic("no global of type " ++ @typeName(G));
    }

    pub fn try_global(self: *App, comptime G: type) ?*G {
        const slot = self.globals.get(type_id(G)) orelse return null;
        return @ptrCast(@alignCast(slot.ptr));
    }

    pub fn has_global(self: *App, comptime G: type) bool {
        return self.globals.contains(type_id(G));
    }

    /// Initializes GPUI's default colors (GPUI `init_colors`). Read them with `default_colors`.
    pub fn init_colors(self: *App) void {
        self.set_global(colors_mod.GlobalColors{ .value = colors_mod.Colors.default });
    }

    /// The colors set by `init_colors` (GPUI `default_colors`). Panics if `init_colors` was not called.
    pub fn default_colors(self: *App) *const colors_mod.Colors {
        return &self.global(colors_mod.GlobalColors).value;
    }

    /// Returns the global, inserting `G{}` if missing.
    pub fn default_global(self: *App, comptime G: type) *G {
        if (self.try_global(G) == null) self.set_global(G{});
        return self.global(G);
    }

    /// `f(*G, cx)`; observers are notified afterwards.
    pub fn update_global(self: *App, comptime G: type, comptime f: anytype) ReturnOf(f) {
        const g = self.global(G);
        defer self.push_effect(.{ .global_changed = type_id(G) });
        return f(g, self);
    }

    /// Mutable access to the global `G`, which must be set (GPUI `global_mut`). `global` already
    /// returns a mutable pointer; this is the name GPUI code uses. Does not notify observers.
    pub fn global_mut(self: *App, comptime G: type) *G {
        return self.global(G);
    }

    /// Like `update_global`, after setting `G{}` if it is not set yet (GPUI `update_default_global`).
    pub fn update_default_global(self: *App, comptime G: type, comptime f: anytype) ReturnOf(f) {
        _ = self.default_global(G);
        return self.update_global(G, f);
    }

    /// Runs `f(args...)` on a background thread (GPUI `background_spawn`, the `AppContext` method).
    /// Same as `background_executor().spawn`.
    pub fn background_spawn(self: *App, comptime f: anytype, args: anytype) executor_mod.Task(ReturnOf(f)) {
        return self.background_executor_.spawn(f, args);
    }

    pub fn remove_global(self: *App, comptime G: type) void {
        if (self.globals.fetchRemove(type_id(G))) |kv| kv.value.destroy(self.allocator, kv.value.ptr);
    }

    /// Removes every global. Does not notify global observers (GPUI `clear_globals`).
    pub fn clear_globals(self: *App) void {
        var it = self.globals.valueIterator();
        while (it.next()) |slot| slot.destroy(self.allocator, slot.ptr);
        self.globals.clearRetainingCapacity();
    }

    /// Observes global `G` from outside an entity: `f(cx)`.
    /// Runs `f(event, window, cx)` after any keystroke in any window has been handled.
    pub fn observe_keystrokes(self: *App, comptime f: anytype) Subscription {
        return self.add_keystroke_subscriber(KeystrokeObserverKey, f);
    }

    /// Runs `f(event, window, cx)` before a keystroke is handled. `window.stop_propagation()`
    /// keeps it from matching key bindings.
    pub fn intercept_keystrokes(self: *App, comptime f: anytype) Subscription {
        return self.add_keystroke_subscriber(KeystrokeInterceptorKey, f);
    }

    fn add_keystroke_subscriber(self: *App, comptime Key: type, comptime f: anytype) Subscription {
        const S = struct {
            fn call(app: *App, _: EntityId, _: usize, payload: ?*const anyopaque) bool {
                const p: *const KeystrokePayload = @ptrCast(@alignCast(payload.?));
                f(p.event, p.window, app);
                return true;
            }
        };
        return self.add_global_observer(type_id(Key), 0, S.call);
    }

    pub fn dispatch_keystroke_observers(self: *App, event: *const KeystrokeEvent, window: *Window) void {
        self.fire_keystroke_subscribers(KeystrokeObserverKey, event, window);
    }

    pub fn dispatch_keystroke_interceptors(self: *App, event: *const KeystrokeEvent, window: *Window) void {
        self.fire_keystroke_subscribers(KeystrokeInterceptorKey, event, window);
    }

    fn fire_keystroke_subscribers(self: *App, comptime Key: type, event: *const KeystrokeEvent, window: *Window) void {
        const payload: KeystrokePayload = .{ .event = event, .window = window };
        var i: usize = 0;
        // By index: a callback may subscribe.
        while (i < self.subscribers.items.len) : (i += 1) {
            const sub = self.subscribers.items[i];
            if (!sub.active or sub.kind != .global or sub.event_type != type_id(Key)) continue;
            if (!sub.func(self, EntityId.from_u64(0), sub.ctx, &payload)) self.subscribers.items[i].active = false;
        }
    }

    /// Runs `f(window, cx)` when `window`'s pending keystrokes change.
    pub fn observe_pending_input(self: *App, window: *Window, comptime f: anytype) Subscription {
        const S = struct {
            fn call(app: *App, _: EntityId, _: usize, payload: ?*const anyopaque) bool {
                f(@constCast(@as(*const Window, @ptrCast(@alignCast(payload.?)))), app);
                return true;
            }
        };
        return self.add_subscriber(.{ .kind = .global, .emitter = @intFromPtr(window), .event_type = type_id(PendingInputObserverKey), .ctx = 0, .func = S.call, .id = 0 });
    }

    pub fn dispatch_pending_input_observers(self: *App, window: *Window) void {
        var i: usize = 0;
        while (i < self.subscribers.items.len) : (i += 1) {
            const sub = self.subscribers.items[i];
            if (!sub.active or sub.kind != .global or sub.emitter != @intFromPtr(window) or sub.event_type != type_id(PendingInputObserverKey)) continue;
            if (!sub.func(self, EntityId.from_u64(0), sub.ctx, window)) self.subscribers.items[i].active = false;
        }
    }

    pub fn observe_global(self: *App, comptime G: type, comptime f: anytype) Subscription {
        const S = struct {
            fn call(app: *App, _: EntityId, _: usize, _: ?*const anyopaque) bool {
                f(app);
                return true;
            }
        };
        return self.add_global_observer(type_id(G), 0, S.call);
    }

    // -- windows ---------------------------------------------------------

    /// Opens a window whose root view is built by `build_root_view(window, cx)`.
    pub fn open_window(self: *App, options: WindowOptions, comptime build_root_view: anytype) !window_mod.WindowHandle(window_mod.RootViewType(build_root_view)) {
        const V = window_mod.RootViewType(build_root_view);
        const win = try Window.create(self, options);
        const handle_index = self.windows.items.len;
        self.windows.append(self.allocator, win) catch oom();
        win.handle_id = @intCast(handle_index);
        self.pending_updates += 1;
        const root = build_root_view(win, self);
        self.pending_updates -= 1;
        win.set_root_view(root.into_any_view());
        win.refresh();
        self.flush_effects();
        _ = V;
        return .{ .window_id = win.handle_id, .entity_id_ = root.entity_id() };
    }

    /// Whether an open window other than `closing` has `id` as its root view.
    /// The keymap, for reading or changing bindings (GPUI `key_bindings`).
    pub fn key_bindings(self: *App) *keymap_mod.Keymap {
        return &self.keymap;
    }

    /// Every binding that matches `input` in any context, highest precedence first (GPUI
    /// `all_bindings_for_input`). Caller frees the slice with the app's allocator.
    pub fn all_bindings_for_input(self: *App, input: []const keystroke_mod.Keystroke) ![]keymap_mod.KeyBinding {
        return self.keymap.all_bindings_for_input(self.allocator, input);
    }

    pub fn is_root_of_other_window(self: *App, id: EntityId, closing: *Window) bool {
        for (self.windows.items) |maybe_window| {
            const win = maybe_window orelse continue;
            if (win == closing) continue;
            const root = win.root orelse continue;
            if (root.entity_id == id) return true;
        }
        return false;
    }

    /// The open window that rendered `id` in its last frame, if any. An entity moved to another
    /// window is found there once that window has drawn it.
    pub fn window_for_entity(self: *App, id: EntityId) ?*Window {
        for (self.windows.items) |maybe_window| {
            const win = maybe_window orelse continue;
            if (win.rendered_entities.contains(id)) return win;
        }
        return null;
    }

    /// Runs `f(window, app, args...)` in the window that rendered `entity_id` (GPUI `with_window`).
    /// Null when no open window has rendered it. Effects it queues are flushed afterwards.
    pub fn with_window(self: *App, entity_id: EntityId, comptime f: anytype, args: anytype) ?ReturnOf(f) {
        const win = self.window_for_entity(entity_id) orelse return null;
        const result = @call(.auto, f, .{ win, self } ++ args);
        self.flush_effects();
        return result;
    }

    pub fn window_by_id(self: *App, id: window_mod.WindowId) ?*Window {
        if (id >= self.windows.items.len) return null;
        return self.windows.items[id];
    }

    /// Handles to all open windows.
    pub fn windows_list(self: *App) []const ?*Window {
        return self.windows.items;
    }

    pub fn active_window(self: *App) ?*Window {
        for (self.windows.items) |w| if (w) |win| if (win.is_window_active()) return win;
        for (self.windows.items) |w| if (w) |win| return win;
        return null;
    }

    pub fn close_window(self: *App, win: *Window) void {
        var index: ?usize = null;
        for (self.windows.items, 0..) |w, i| if (w == win) {
            index = i;
        };
        // Already closed: the window is gone and must not be destroyed twice.
        const i = index orelse return;
        self.windows.items[i] = null;
        const id = win.handle_id;
        win.destroy(self);
        self.dispatch_window_closed(id);
        var any_open = false;
        for (self.windows.items) |w| any_open = any_open or w != null;
        const quit_on_last = switch (self.quit_mode) {
            .default => self.platform.quit_when_last_window_closes(),
            .explicit => false,
            .last_window_closed => true,
        };
        if (!any_open and quit_on_last) self.quit();
    }

    /// Closes the window with this handle once the current update ends (GPUI `remove_window`).
    pub fn close_window_later(self: *App, win: *Window) void {
        self.push_effect(.{ .close_window = win.handle_id });
    }

    /// How many windows are open (GPUI `cx.windows().len()`).
    pub fn window_count(self: *App) usize {
        var n: usize = 0;
        for (self.windows.items) |w| if (w != null) {
            n += 1;
        };
        return n;
    }

    /// Runs `f(cx, window_id)` after a window closes (GPUI `cx.on_window_closed`).
    pub fn on_window_closed(self: *App, comptime f: anytype) Subscription {
        const S = struct {
            fn call(app: *App, _: EntityId, _: usize, payload: ?*const anyopaque) bool {
                const id: *const window_mod.WindowId = @ptrCast(@alignCast(payload.?));
                f(app, id.*);
                return true;
            }
        };
        return self.add_subscriber(.{ .kind = .window_closed, .emitter = 0, .ctx = 0, .func = S.call, .id = 0 });
    }

    fn dispatch_window_closed(self: *App, id: window_mod.WindowId) void {
        var i: usize = 0;
        while (i < self.subscribers.items.len) : (i += 1) {
            const sub = self.subscribers.items[i];
            if (!sub.active or sub.kind != .window_closed) continue;
            if (!sub.func(self, EntityId.from_u64(0), sub.ctx, &id)) self.subscribers.items[i].active = false;
        }
    }

    /// Runs the appearance observers of `win` (its appearance has changed).
    pub fn dispatch_window_appearance(self: *App, win: *Window) void {
        var i: usize = 0;
        while (i < self.subscribers.items.len) : (i += 1) {
            const sub = self.subscribers.items[i];
            if (!sub.active or sub.kind != .window_appearance or sub.emitter != @as(u64, win.handle_id)) continue;
            if (!sub.func(self, EntityId.from_u64(0), sub.ctx, win)) self.subscribers.items[i].active = false;
        }
    }

    pub fn dispatch_window_button_layout(self: *App, win: *Window) void {
        var i: usize = 0;
        while (i < self.subscribers.items.len) : (i += 1) {
            const sub = self.subscribers.items[i];
            if (!sub.active or sub.kind != .window_button_layout or sub.emitter != @as(u64, win.handle_id)) continue;
            if (!sub.func(self, EntityId.from_u64(0), sub.ctx, win)) self.subscribers.items[i].active = false;
        }
    }

    pub fn add_window_subscriber(self: *App, kind: SubscriberKind, window_id: window_mod.WindowId, ctx: usize, func: SubscriberFn) Subscription {
        return self.add_subscriber(.{ .kind = kind, .emitter = @as(u64, window_id), .ctx = ctx, .func = func, .id = 0 });
    }

    /// Runs the `kind` observers of `win` with `win` as the payload, then flushes what they queued.
    pub fn dispatch_window_observers(self: *App, kind: SubscriberKind, win: *Window) void {
        self.pending_updates += 1;
        defer {
            self.pending_updates -= 1;
            if (self.pending_updates == 0) self.flush_effects();
        }
        var i: usize = 0;
        while (i < self.subscribers.items.len) : (i += 1) {
            const sub = self.subscribers.items[i];
            if (!sub.active or sub.kind != kind or sub.emitter != @as(u64, win.handle_id)) continue;
            if (!sub.func(self, EntityId.from_u64(0), sub.ctx, win)) self.subscribers.items[i].active = false;
        }
    }

    /// Sets the function that builds in-window prompts (GPUI `set_prompt_builder`).
    pub fn set_prompt_builder(self: *App, builder: window_mod.PromptBuilder) void {
        self.prompt_builder = builder;
    }

    /// Goes back to GPUI's fallback prompt (GPUI `reset_prompt_builder`).
    pub fn reset_prompt_builder(self: *App) void {
        self.prompt_builder = null;
    }

    pub fn refresh_windows(self: *App) void {
        self.push_effect(.refresh_windows);
    }

    // -- misc ------------------------------------------------------------

    pub fn focus_handle(self: *App) window_mod.FocusHandle {
        const id = self.next_focus_id;
        self.next_focus_id += 1;
        return .{ .id = id };
    }

    pub fn text_system(self: *App) *text_system_mod.TextSystem {
        return self.text_system_;
    }

    pub fn background_executor(self: *App) *executor_mod.BackgroundExecutor {
        return &self.background_executor_;
    }

    pub fn foreground_executor(self: *App) *executor_mod.ForegroundExecutor {
        return &self.foreground_executor_;
    }

    /// The loaded `A` for `source`, or null while it loads; starts the load if needed. Does not redraw
    /// anything when it arrives (GPUI `fetch_asset`). Windows use `Window.use_asset` instead.
    pub fn fetch_asset(self: *App, comptime A: type, source: A.Source) ?A.Output {
        return self.asset_loads.entry(A, source).get();
    }

    /// Drops the cached `A` for `source`, abandoning a running load (GPUI `remove_asset`). The next
    /// `use_asset` for it loads again. Views are not redrawn; they redraw on their next frame.
    pub fn remove_asset(self: *App, comptime A: type, source: A.Source) void {
        self.asset_loads.remove(A, source);
    }

    /// Whether `source` is cached or loading (GPUI `has_asset`, which is test-only there).
    pub fn has_asset(self: *App, comptime A: type, source: A.Source) bool {
        return self.asset_loads.contains(A, source);
    }

    /// Sets the client that fetches remote images (GPUI `set_http_client`). `Application.with_http_client`
    /// does the same before the app runs.
    pub fn set_http_client(self: *App, client: http_client_mod.HttpClient) void {
        self.asset_cache.fetch_config.?.http_client = client;
    }

    /// Removes `image`'s tiles from every window's sprite atlas, before the image is freed (GPUI
    /// `drop_image`, which also takes the window being drawn; here all windows are cleaned).
    pub fn drop_image(self: *App, image: *const assets_mod.RenderImage) void {
        for (self.windows.items) |slot| if (slot) |w| w.forget_image(image);
    }

    /// Spawns a foreground task `f(async_cx, args...)`.
    pub fn spawn(self: *App, comptime f: anytype, args: anytype) executor_mod.Task(ReturnOf(f)) {
        return self.foreground_executor_.spawn(f, .{self.to_async()} ++ args);
    }

    /// Like `spawn`, with a priority. Foreground work runs in order, so the priority is ignored (as in GPUI).
    pub fn spawn_with_priority(self: *App, priority: executor_mod.Priority, comptime f: anytype, args: anytype) executor_mod.Task(ReturnOf(f)) {
        _ = priority;
        return self.spawn(f, args);
    }

    pub fn to_async(self: *App) *AsyncApp {
        return &self.async_app;
    }

    pub fn quit(self: *App) void {
        self.quitting = true;
        self.platform.quit();
    }

    /// Brings the application to the foreground.
    pub fn activate(self: *App, ignoring_other_apps: bool) void {
        self.platform.activate(ignoring_other_apps);
    }

    pub fn hide(self: *App) void {
        self.platform.hide();
    }

    /// Replaces the menu bar (GPUI `App::set_menus`). The menus are copied, so the slice may be
    /// discarded afterwards. Platforms without a menu bar keep them for `get_menus`.
    pub fn set_menus(self: *App, menus: []const platform_mod.app_menu.Menu) void {
        self.platform.set_menus(menus);
    }

    /// The menus last given to `set_menus`, or null if none were set (GPUI `App::get_menus`).
    pub fn get_menus(self: *App) ?[]const platform_mod.app_menu.OwnedMenu {
        return self.platform.get_menus();
    }

    /// Sets the process-wide identity and user-visible name (GPUI `App::set_app_identity`).
    /// Call it once, early, before posting notifications. No platform uses it yet.
    pub fn set_app_identity(self: *App, identifier: []const u8, name: []const u8) void {
        self.platform.set_app_identity(identifier, name);
    }

    /// Posts a system notification (GPUI `App::show_system_notification`). A tag that matches an
    /// earlier one replaces it where supported. Linux posts through the session bus; the other
    /// platforms do nothing yet. See `on_system_notification_response`.
    pub fn show_system_notification(self: *App, notification: platform_mod.SystemNotification) void {
        self.platform.show_system_notification(notification);
    }

    /// Removes the notification with this tag (GPUI `App::dismiss_system_notification`).
    pub fn dismiss_system_notification(self: *App, tag: []const u8) void {
        self.platform.dismiss_system_notification(tag);
    }

    /// Registers the handler for notification responses (GPUI `App::on_system_notification_response`).
    /// `f(ctx, response, app)` runs when a platform reports one through
    /// `dispatch_system_notification_response`. Registering again replaces the handler.
    pub fn on_system_notification_response(self: *App, ctx: anytype, comptime f: fn (@TypeOf(ctx), platform_mod.SystemNotificationResponse, *App) void) void {
        const C = @TypeOf(ctx);
        const boxed = self.allocator.create(C) catch @panic("out of memory");
        boxed.* = ctx;
        const Thunk = struct {
            fn call(raw: *anyopaque, response: platform_mod.SystemNotificationResponse, app: *App) void {
                const held: *const C = @ptrCast(@alignCast(raw));
                f(held.*, response, app);
            }
            fn free(a: std.mem.Allocator, raw: *anyopaque) void {
                a.destroy(@as(*C, @ptrCast(@alignCast(raw))));
            }
        };
        if (self.system_notification_response) |old| old.free(self.allocator, old.ctx);
        self.system_notification_response = .{ .ctx = boxed, .func = Thunk.call, .free = Thunk.free };
    }

    /// Delivers a response from the platform to the handler registered with
    /// `on_system_notification_response`.
    pub fn dispatch_system_notification_response(self: *App, response: platform_mod.SystemNotificationResponse) void {
        const handler = self.system_notification_response orelse return;
        handler.func(handler.ctx, response, self);
    }

    /// Runs `f(event, cx)` when a display is connected, disconnected, or its bounds change (GPUI
    /// `observe_displays`). The platform says when displays may have changed; the app diffs them.
    pub fn observe_displays(self: *App, comptime f: anytype) Subscription {
        const S = struct {
            fn call(app: *App, _: EntityId, _: usize, payload: ?*const anyopaque) bool {
                const event: *const platform_mod.DisplayEvent = @ptrCast(@alignCast(payload.?));
                f(event.*, app);
                return true;
            }
        };
        return self.add_subscriber(.{ .kind = .displays, .emitter = 0, .ctx = 0, .func = S.call, .id = 0 });
    }

    fn read_display_snapshot(self: *App) !void {
        self.display_snapshot.clearRetainingCapacity();
        for (self.platform.displays()) |d| try self.display_snapshot.append(self.allocator, .{ .id = d.id, .bounds = d.bounds });
    }

    /// Whether the app has seen a display with this id, as of its last display notification (GPUI `knows_display`).
    pub fn knows_display(self: *App, id: platform_mod.DisplayId) bool {
        return find_display_state(self.display_snapshot.items, id) != null;
    }

    fn find_display_state(list: []const DisplayState, id: platform_mod.DisplayId) ?DisplayState {
        for (list) |d| if (d.id == id) return d;
        return null;
    }

    /// The platform's displays changed. Diffs them against the last snapshot, tells the windows on
    /// each changed display, then runs the `observe_displays` observers (GPUI `displays_changed`).
    pub fn displays_changed(self: *App) void {
        var current: std.ArrayList(DisplayState) = .empty;
        defer current.deinit(self.allocator);
        for (self.platform.displays()) |d| current.append(self.allocator, .{ .id = d.id, .bounds = d.bounds }) catch oom();

        // Removed first, then added and changed, as GPUI orders them.
        var events: std.ArrayList(platform_mod.DisplayEvent) = .empty;
        defer events.deinit(self.allocator);
        for (self.display_snapshot.items) |old| {
            if (find_display_state(current.items, old.id) == null) events.append(self.allocator, .{ .removed = old.id }) catch oom();
        }
        for (current.items) |fresh| {
            if (find_display_state(self.display_snapshot.items, fresh.id)) |old| {
                if (!std.meta.eql(old.bounds, fresh.bounds)) events.append(self.allocator, .{ .changed = .{ .id = fresh.id, .changes = .{ .bounds = true } } }) catch oom();
            } else {
                events.append(self.allocator, .{ .added = fresh.id }) catch oom();
            }
        }
        std.mem.swap(std.ArrayList(DisplayState), &self.display_snapshot, &current);

        self.pending_updates += 1;
        defer {
            self.pending_updates -= 1;
            if (self.pending_updates == 0) self.flush_effects();
        }
        for (events.items) |event| switch (event) {
            .changed => |c| for (self.windows.items) |maybe_win| {
                const win = maybe_win orelse continue;
                if (win.display_id_ == c.id) win.notify_display_observers(self);
            },
            else => {},
        };
        for (events.items) |*event| {
            var i: usize = 0;
            while (i < self.subscribers.items.len) : (i += 1) {
                const sub = self.subscribers.items[i];
                if (!sub.active or sub.kind != .displays) continue;
                if (!sub.func(self, EntityId.from_u64(0), sub.ctx, event)) self.subscribers.items[i].active = false;
            }
        }
    }

    /// Runs the observers of a global kind with `payload`, then flushes what they queued.
    fn dispatch_global(self: *App, kind: SubscriberKind, payload: ?*const anyopaque) void {
        self.pending_updates += 1;
        defer {
            self.pending_updates -= 1;
            if (self.pending_updates == 0) self.flush_effects();
        }
        var i: usize = 0;
        while (i < self.subscribers.items.len) : (i += 1) {
            const sub = self.subscribers.items[i];
            if (!sub.active or sub.kind != kind) continue;
            if (!sub.func(self, EntityId.from_u64(0), sub.ctx, payload)) self.subscribers.items[i].active = false;
        }
    }

    /// The current keyboard layout (GPUI `keyboard_layout`).
    pub fn keyboard_layout(self: *App) platform_mod.KeyboardLayout {
        return self.platform.keyboard_layout();
    }

    /// The titlebar button layout, when the platform has one (GPUI `button_layout`).
    pub fn button_layout(self: *App) ?platform_mod.WindowButtonLayout {
        return self.platform.button_layout();
    }

    /// The keyboard mapper (GPUI `keyboard_mapper`). Linux maps nothing, as GPUI's does.
    pub fn keyboard_mapper(_: *App) platform_mod.KeyboardMapper {
        return .{};
    }

    /// Runs `f(cx)` when the keyboard layout changes (GPUI `on_keyboard_layout_change`).
    pub fn on_keyboard_layout_change(self: *App, comptime f: fn (*App) void) Subscription {
        const S = struct {
            fn call(app: *App, _: EntityId, _: usize, _: ?*const anyopaque) bool {
                f(app);
                return true;
            }
        };
        return self.add_subscriber(.{ .kind = .keyboard_layout, .emitter = 0, .ctx = 0, .func = S.call, .id = 0 });
    }

    /// The keyboard layout changed: runs the `on_keyboard_layout_change` observers.
    pub fn dispatch_keyboard_layout_change(self: *App) void {
        self.dispatch_global(.keyboard_layout, null);
    }

    /// Runs `f(cx)` when the app is reopened (GPUI `on_reopen`). Only macOS reports reopens, as
    /// GPUI's Linux platform never calls its reopen callback either.
    pub fn on_reopen(self: *App, comptime f: fn (*App) void) Subscription {
        const S = struct {
            fn call(app: *App, _: EntityId, _: usize, _: ?*const anyopaque) bool {
                f(app);
                return true;
            }
        };
        return self.add_subscriber(.{ .kind = .reopen, .emitter = 0, .ctx = 0, .func = S.call, .id = 0 });
    }

    /// Runs the `on_reopen` observers. A platform calls it when the user reopens a running app.
    pub fn dispatch_reopen(self: *App) void {
        self.dispatch_global(.reopen, null);
    }

    /// When the cursor is hidden on keyboard input (GPUI `cursor_hide_mode`).
    pub fn cursor_hide_mode(self: *App) CursorHideMode {
        return self.cursor_hide_mode_;
    }

    /// Sets when the cursor is hidden on keyboard input (GPUI `set_cursor_hide_mode`).
    pub fn set_cursor_hide_mode(self: *App, mode: CursorHideMode) void {
        self.cursor_hide_mode_ = mode;
    }

    /// Whether the cursor is visible, as the platform reports it (GPUI `is_cursor_visible`).
    pub fn is_cursor_visible(self: *App) bool {
        return self.platform.is_cursor_visible();
    }

    /// Hides the cursor until the mouse moves over one of the app's windows.
    pub fn hide_cursor_until_mouse_moves(self: *App) void {
        self.platform.hide_cursor_until_mouse_moves();
    }

    /// The display server's environment, or null while headless (GPUI `graphical_environment`).
    pub fn graphical_environment(self: *App) ?platform_mod.GraphicalEnvironment {
        return self.platform.graphical_environment();
    }

    /// The compositor in use on Linux, empty elsewhere (GPUI `compositor_name`).
    pub fn compositor_name(self: *App) []const u8 {
        return self.platform.compositor_name();
    }

    /// The host OS and application target (GPUI `platform_info`).
    /// The operating system's power mode, or `unknown` where the platform cannot tell (GPUI `App::power_mode`).
    pub fn power_mode(self: *App) platform_mod.PowerMode {
        return self.power_mode_;
    }

    fn on_power_mode_changed(raw: *anyopaque) void {
        const self: *App = @ptrCast(@alignCast(raw));
        self.power_mode_ = self.platform.power_mode();
    }

    pub fn platform_info(self: *App) platform_mod.PlatformInfo {
        return self.platform.platform_info();
    }

    /// Whether the user wants scrollbars to hide themselves (GPUI `should_auto_hide_scrollbars`).
    pub fn should_auto_hide_scrollbars(self: *App) bool {
        return self.platform.should_auto_hide_scrollbars();
    }

    /// Sets whether the app takes part in the system's foreground UI (GPUI `set_activation_policy`).
    /// Only macOS acts on it.
    pub fn set_activation_policy(self: *App, policy: platform_mod.ActivationPolicy) void {
        self.platform.set_activation_policy(policy);
    }

    /// Hides the other applications (GPUI `hide_other_apps`). Linux ignores it, as GPUI does.
    pub fn hide_other_apps(self: *App) void {
        self.platform.hide_other_apps();
    }

    /// Shows the applications hidden by `hide_other_apps` (GPUI `unhide_other_apps`).
    pub fn unhide_other_apps(self: *App) void {
        self.platform.unhide_other_apps();
    }

    /// The windows ordered front to back, the active one first; null when the platform cannot say
    /// (GPUI `window_stack`). Windows of other applications are left out. The slice is valid until
    /// the next call.
    pub fn window_stack(self: *App) ?[]const window_mod.AnyWindowHandle {
        const platform_windows = self.platform.window_stack() orelse return null;
        self.window_stack_storage.clearRetainingCapacity();
        for (platform_windows) |pw| {
            for (self.windows.items) |maybe_win| {
                const win = maybe_win orelse continue;
                if (win.platform_window == pw) {
                    self.window_stack_storage.append(self.allocator, .{ .id = win.handle_id }) catch oom();
                    break;
                }
            }
        }
        return self.window_stack_storage.items;
    }

    pub fn displays(self: *App) []const platform_mod.Display {
        return self.platform.displays();
    }

    pub fn primary_display(self: *App) ?platform_mod.Display {
        return self.platform.primary_display();
    }

    /// The display with this id, if it is connected (GPUI `find_display`).
    pub fn find_display(self: *App, id: platform_mod.DisplayId) ?platform_mod.Display {
        for (self.displays()) |d| if (d.id == id) return d;
        return null;
    }

    /// Size of the primary display, used by `Bounds.centered`.
    pub fn primary_display_size(self: *App) geometry.Size(Pixels) {
        if (self.primary_display()) |d| return d.bounds.size;
        return .{ .width = 1920, .height = 1080 };
    }

    pub fn write_to_clipboard(self: *App, item: platform_mod.ClipboardItem) void {
        self.platform.write_to_clipboard(item);
    }

    pub fn read_from_clipboard(self: *App) ?platform_mod.ClipboardItem {
        return self.platform.read_from_clipboard();
    }

    /// Reads the clipboard as a task (GPUI `read_from_clipboard_async`). Linux reads synchronously, so
    /// the task is ready when it is returned, as GPUI's platform default is. Prefer this in code that can
    /// wait: a platform whose clipboard is asynchronous would return nothing from `read_from_clipboard`.
    pub fn read_from_clipboard_async(self: *App) executor_mod.Task(?platform_mod.ClipboardItem) {
        return executor_mod.Task(?platform_mod.ClipboardItem).ready(self.read_from_clipboard());
    }

    /// The app's assets, for `img()` and `svg()` (GPUI `asset_source`). Set with `Application.with_assets`.
    pub fn asset_source(self: *const App) *const assets_mod.AssetSource {
        return &self.asset_source_;
    }

    /// Deprecated action names, each mapped to the name that replaces it (GPUI
    /// `deprecated_actions_to_preferred_actions`).
    pub fn deprecated_actions_to_preferred_actions(self: *const App) *const std.StringHashMapUnmanaged([]const u8) {
        return self.actions.deprecated_aliases();
    }

    /// Deprecation messages by action name (GPUI `action_deprecation_messages`).
    pub fn action_deprecation_messages(self: *const App) *const std.StringHashMapUnmanaged([]const u8) {
        return self.actions.deprecation_messages();
    }

    pub fn write_to_primary(self: *App, item: platform_mod.ClipboardItem) void {
        self.platform.write_to_primary(item);
    }

    pub fn read_from_primary(self: *App) ?platform_mod.ClipboardItem {
        return self.platform.read_from_primary();
    }

    pub fn open_url(self: *App, url: []const u8) void {
        self.platform.open_url(url);
    }

    /// The appearance of the application's windows (GPUI `App::window_appearance`).
    pub fn window_appearance(self: *App) platform_mod.WindowAppearance {
        return self.platform.window_appearance();
    }

    /// Whether one file dialog may choose files and directories together (GPUI `can_select_mixed_files_and_dirs`).
    pub fn can_select_mixed_files_and_dirs(self: *App) bool {
        return self.platform.can_select_mixed_files_and_dirs();
    }

    /// Shows a file chooser. `f(ctx, result, app)` runs once: `null` when the user cancelled, or the
    /// chosen paths, valid during the call only. GPUI returns a receiver; the callback takes its place.
    pub fn prompt_for_paths(self: *App, options: platform_mod.PathPromptOptions, ctx: anytype, comptime f: fn (@TypeOf(ctx), anyerror!?[]const []const u8, *App) void) void {
        const Box = PromptCallback(@TypeOf(ctx), anyerror!?[]const []const u8, f);
        const box = self.allocator.create(Box) catch oom();
        box.* = .{ .app = self, .ctx = ctx };
        self.platform.prompt_for_paths(options, .{ .ctx = box, .func = Box.complete });
    }

    /// Shows a save dialog starting in `directory`. `f(ctx, result, app)` runs once, as for `prompt_for_paths`.
    pub fn prompt_for_new_path(self: *App, directory: []const u8, suggested_name: ?[]const u8, ctx: anytype, comptime f: fn (@TypeOf(ctx), anyerror!?[]const u8, *App) void) void {
        const Box = PromptCallback(@TypeOf(ctx), anyerror!?[]const u8, f);
        const box = self.allocator.create(Box) catch oom();
        box.* = .{ .app = self, .ctx = ctx };
        self.platform.prompt_for_new_path(directory, suggested_name, .{ .ctx = box, .func = Box.complete });
    }

    /// Shows a path in the file manager (GPUI `App::reveal_path`).
    pub fn reveal_path(self: *App, path: []const u8) void {
        self.platform.reveal_path(path);
    }

    /// Opens a path with the system's default application (GPUI `App::open_with_system`).
    pub fn open_with_system(self: *App, path: []const u8) void {
        self.platform.open_with_system(path);
    }

    /// The path of this executable (GPUI `App::app_path`). Valid until the next call.
    pub fn app_path(self: *App) anyerror![]const u8 {
        return self.platform.app_path();
    }

    /// GPUI `App::path_for_auxiliary_executable`.
    pub fn path_for_auxiliary_executable(self: *App, name: []const u8) anyerror![]const u8 {
        return self.platform.path_for_auxiliary_executable(name);
    }

    /// Registers `scheme` for this app's URLs (GPUI `App::register_url_scheme`). Linux does not
    /// support it yet and answers with an error, as GPUI's Linux platform does.
    pub fn register_url_scheme(self: *App, scheme: []const u8) executor_mod.Task(anyerror!void) {
        const result = self.platform.register_url_scheme(scheme);
        return executor_mod.Task(anyerror!void).ready(result);
    }

    /// Runs `f(app)` before the app restarts (GPUI `App::on_app_restart`). Kept until dropped.
    pub fn on_app_restart(self: *App, comptime f: fn (*App) void) Subscription {
        const S = struct {
            fn call(app: *App, _: EntityId, _: usize, _: ?*const anyopaque) bool {
                f(app);
                return true;
            }
        };
        return self.add_subscriber(.{ .kind = .app_restart, .emitter = 0, .ctx = 0, .func = S.call, .id = 0 });
    }

    /// Sets the binary `restart` starts instead of this one (GPUI `App::set_restart_path`).
    pub fn set_restart_path(self: *App, path: []const u8) std.mem.Allocator.Error!void {
        const copy = try self.allocator.dupe(u8, path);
        if (self.restart_path) |old| self.allocator.free(old);
        self.restart_path = copy;
    }

    /// Sets the arguments `restart` passes (GPUI `with_restart_arguments`).
    pub fn set_restart_arguments(self: *App, arguments: []const []const u8) std.mem.Allocator.Error!void {
        const copy = try dupe_strings(self.allocator, arguments);
        free_strings(self.allocator, self.restart_arguments);
        self.restart_arguments = copy;
    }

    /// Restarts the app (GPUI `App::restart`). The `on_app_restart` observers run first. The
    /// platform starts the new process and quits this one, if it can.
    pub fn restart(self: *App) void {
        self.pending_updates += 1;
        var i: usize = 0;
        while (i < self.subscribers.items.len) : (i += 1) {
            const sub = self.subscribers.items[i];
            if (!sub.active or sub.kind != .app_restart) continue;
            _ = sub.func(self, EntityId.from_u64(0), sub.ctx, null);
        }
        self.pending_updates -= 1;
        if (self.pending_updates == 0) self.flush_effects();

        const path = self.restart_path;
        self.restart_path = null;
        const arguments = self.restart_arguments;
        self.restart_arguments = &.{};
        self.platform.restart(path, arguments);
        if (path) |p| self.allocator.free(p);
        free_strings(self.allocator, arguments);
    }

    /// Whether non-essential animations (spinners, for example) should be drawn in a static state
    /// instead (GPUI `reduce_motion`).
    pub fn reduce_motion(self: *const App) bool {
        return self.reduce_motion_;
    }

    /// Sets `reduce_motion` (GPUI `set_reduce_motion`).
    pub fn set_reduce_motion(self: *App, v: bool) void {
        self.reduce_motion_ = v;
    }

    /// The name of the app, set only by tests (GPUI `get_name`). Null when none was set.
    pub fn get_name(self: *const App) ?[]const u8 {
        return self.name_;
    }

    // -- actions & keymap ------------------------------------------------

    /// Binds keystrokes to actions (GPUI `bind_keys`).
    pub fn bind_keys(self: *App, bindings: []const keymap_mod.KeyBinding) void {
        self.keymap.add_bindings(bindings) catch oom();
        for (self.windows.items) |w| if (w) |win| win.refresh();
    }

    pub fn clear_key_bindings(self: *App) void {
        self.keymap.clear();
    }

    /// Registers a global action handler `f(*const A, cx)`.
    pub fn on_action(self: *App, comptime A: type, comptime f: fn (*const A, *App) void) void {
        const S = struct {
            fn call(raw: *const anyopaque, app: *App) void {
                f(@ptrCast(@alignCast(raw)), app);
            }
        };
        self.global_action_listeners.append(self.allocator, .{ .action_type = type_id(A), .func = S.call }) catch oom();
    }

    /// Dispatches an action to the focused element of the active window, then globally.
    pub fn dispatch_action(self: *App, action: anytype) void {
        const boxed = action_mod.box_action(self.effect_arena.allocator(), action);
        if (self.active_window()) |w| {
            w.dispatch_action(boxed, self);
        } else {
            self.dispatch_global_action(boxed);
        }
    }

    pub fn dispatch_global_action(self: *App, action: action_mod.AnyAction) void {
        for (self.global_action_listeners.items) |l| {
            if (l.action_type == action.type_id) l.func(action.ptr, self);
        }
    }

    /// Dispatches an action that is already boxed, to the active window's focus path, then globally.
    /// Platforms pass menu picks this way (GPUI `dispatch_action` on a `&dyn Action`).
    pub fn dispatch_any_action(self: *App, action: action_mod.AnyAction) void {
        if (self.active_window()) |w| {
            w.dispatch_action(action, self);
        } else {
            self.dispatch_global_action(action);
        }
    }

    /// Whether an action of this type is bound now, as GPUI's `is_action_available` decides it
    /// (global listeners, then the active window's focus path). Used for menu validation.
    pub fn is_action_type_available(self: *App, tid: TypeId) bool {
        for (self.global_action_listeners.items) |l| if (l.action_type == tid) return true;
        if (self.active_window()) |w| return w.is_action_available(tid);
        return false;
    }

    /// Clears the multi-stroke keystrokes pending in every window (GPUI `clear_pending_keystrokes`).
    /// Runs when an application menu opens, so a half-typed sequence does not outlive it.
    pub fn clear_pending_keystrokes(self: *App) void {
        for (self.windows.items) |maybe_win| {
            const win = maybe_win orelse continue;
            win.clear_pending_keystrokes();
        }
    }

    pub fn is_action_available(self: *App, comptime A: type) bool {
        return self.is_action_type_available(type_id(A));
    }
};

/// A reserved-but-unfilled entity slot.
pub fn Reservation(comptime T: type) type {
    return struct {
        pub const Type = T;
        entity_id_: EntityId,
    };
}

/// An app context usable across suspension points (GPUI `AsyncApp`).
pub const AsyncApp = struct {
    app: *App,

    pub fn update(self: *AsyncApp, comptime f: anytype, args: anytype) ReturnOf(f) {
        return self.app.update(f, args);
    }
    pub fn new(self: *AsyncApp, init: anytype) Entity(EntityTypeOf(@TypeOf(init))) {
        return self.app.new(init);
    }
    pub fn background_executor(self: *AsyncApp) *executor_mod.BackgroundExecutor {
        return self.app.background_executor();
    }
    pub fn foreground_executor(self: *AsyncApp) *executor_mod.ForegroundExecutor {
        return self.app.foreground_executor();
    }
    pub fn refresh(self: *AsyncApp) void {
        self.app.refresh_windows();
    }

    /// Runs `f(global, app, args...)` with the global `G` (GPUI `read_global`). Fails if `G` is not set.
    pub fn read_global(self: *AsyncApp, comptime G: type, comptime f: anytype, args: anytype) error{GlobalNotFound}!ReturnOf(f) {
        const g = self.app.try_global(G) orelse return error.GlobalNotFound;
        return @call(.auto, f, .{ g, self.app } ++ args);
    }

    /// Runs `f(global, app, args...)` with the global `G`, setting `G{}` first if it is not set
    /// (GPUI `read_default_global`).
    pub fn read_default_global(self: *AsyncApp, comptime G: type, comptime f: anytype, args: anytype) ReturnOf(f) {
        const g = self.app.default_global(G);
        const result = @call(.auto, f, .{ g, self.app } ++ args);
        self.app.flush_effects();
        return result;
    }

    /// Like `read_global`, but null when `G` is not set (GPUI `try_read_global`).
    pub fn try_read_global(self: *AsyncApp, comptime G: type, comptime f: anytype, args: anytype) ?ReturnOf(f) {
        const g = self.app.try_global(G) orelse return null;
        return @call(.auto, f, .{ g, self.app } ++ args);
    }
};

/// An app context for a window, usable across suspension points (GPUI `AsyncWindowContext`). It
/// holds the window's id, so it works after the window has closed: `update` then fails.
pub const AsyncWindowContext = struct {
    app: *App,
    window_id: window_mod.WindowId,

    /// Runs `f(window, app, args...)` in the window (GPUI `AsyncWindowContext::update`), or fails
    /// with `error.WindowClosed`. Effects it queues are flushed afterwards.
    pub fn update(self: AsyncWindowContext, comptime f: anytype, args: anytype) error{WindowClosed}!ReturnOf(f) {
        const win = self.app.window_by_id(self.window_id) orelse return error.WindowClosed;
        const r = @call(.auto, f, .{ win, self.app } ++ args);
        self.app.flush_effects();
        return r;
    }

    /// The window this context is for (GPUI `window_handle`).
    pub fn window_handle(self: AsyncWindowContext) window_mod.AnyWindowHandle {
        return .{ .id = self.window_id };
    }

    /// Runs `f(root_view, window, app, args...)` in the window (GPUI `update_root`).
    pub fn update_root(self: AsyncWindowContext, comptime f: anytype, args: anytype) error{WindowClosed}!ReturnOf(f) {
        return self.app.update_window(self.window_handle(), f, args);
    }

    /// Runs `f(entity_state, window, context, args...)` on `entity` with the window (GPUI
    /// `update_window_entity`). Fails when the window is gone.
    pub fn update_window_entity(self: AsyncWindowContext, entity: anytype, comptime f: anytype, args: anytype) error{WindowClosed}!ReturnOf(f) {
        const win = self.app.window_by_id(self.window_id) orelse return error.WindowClosed;
        const result = entity.update_in(win, self.app, f, args);
        self.app.flush_effects();
        return result;
    }

    pub fn background_executor(self: AsyncWindowContext) *executor_mod.BackgroundExecutor {
        return self.app.background_executor();
    }
    pub fn foreground_executor(self: AsyncWindowContext) *executor_mod.ForegroundExecutor {
        return self.app.foreground_executor();
    }
};

/// The application entry point (GPUI `Application`).
pub const Application = struct {
    allocator: std.mem.Allocator,
    platform: *platform_mod.Platform,
    app: *App,

    /// Creates the application on the current platform with the default allocator.
    pub fn new() Application {
        return with_allocator(default_allocator());
    }

    /// Creates a headless application (no windows are shown; for tests and servers).
    pub fn headless() Application {
        return init_with(default_allocator(), platform_mod.headless_platform(default_allocator()));
    }

    /// Creates the application using `allocator` for all framework state.
    pub fn with_allocator(allocator: std.mem.Allocator) Application {
        return init_with(allocator, platform_mod.current_platform(allocator));
    }

    fn init_with(allocator: std.mem.Allocator, platform: *platform_mod.Platform) Application {
        const app = App.init(allocator, platform) catch oom();
        return .{ .allocator = allocator, .platform = platform, .app = app };
    }

    /// Sets the source of named assets (GPUI `with_assets`). `source` is a pointer to a type with
    /// `load(path) ?[]const u8`, or an `assets.AssetSource`; it must outlive the app.
    /// Sets the client that fetches remote images (GPUI `with_http_client`). The default is
    /// built on `std.http`.
    pub fn with_http_client(self: Application, client: http_client_mod.HttpClient) Application {
        self.app.asset_cache.fetch_config.?.http_client = client;
        return self;
    }

    /// Sets where downloaded images are saved so they show at once next time. The default is the
    /// platform's per-user cache directory; `.off` saves nothing.
    pub fn with_image_cache(self: Application, cache: assets_mod.DiskCache) Application {
        self.app.asset_cache.fetch_config.?.disk_cache = cache;
        return self;
    }

    /// Sets when the app quits by itself, after its last window closes (GPUI `with_quit_mode`).
    pub fn with_quit_mode(self: Application, mode: QuitMode) Application {
        self.app.set_quit_mode(mode);
        return self;
    }

    /// Configures the arguments `restart` passes (GPUI `with_restart_arguments`).
    pub fn with_restart_arguments(self: Application, arguments: []const []const u8) Application {
        self.app.set_restart_arguments(arguments) catch oom();
        return self;
    }

    pub fn with_assets(self: Application, source: anytype) Application {
        self.app.asset_source_ = if (@TypeOf(source) == assets_mod.AssetSource) source else assets_mod.AssetSource.from(source);
        return self;
    }

    /// Starts the event loop. `on_finish_launching(cx)` runs once the platform is ready.
    pub fn run(self: Application, comptime on_finish_launching: fn (*App) void) void {
        const S = struct {
            fn launched(ctx: *anyopaque) void {
                const app: *App = @ptrCast(@alignCast(ctx));
                on_finish_launching(app);
                app.flush_effects();
            }
        };
        self.platform.run(self.app, S.launched);
        // The loop has ended: quit handlers run while windows and entities still exist.
        self.app.shutdown();
        self.app.deinit();
        self.platform.deinit();
    }

    /// Registers a callback for when the app is asked to open URLs.
    /// Runs `f(app)` when the app is reopened (GPUI `Application::on_reopen`).
    pub fn on_reopen(self: Application, comptime f: fn (*App) void) Application {
        _ = self.app.on_reopen(f);
        return self;
    }

    pub fn on_open_urls(self: Application, comptime f: fn ([]const []const u8, *App) void) Application {
        _ = f;
        return self;
    }
};

fn default_allocator() std.mem.Allocator {
    if (builtin.is_test) return std.testing.allocator;
    return std.heap.smp_allocator;
}

const TestAppContext = @import("app/test_context.zig").TestAppContext;

test "init_colors installs the default colors" {
    var cx = TestAppContext.init();
    defer cx.deinit();
    cx.app.init_colors();
    const expected = colors_mod.Colors.default;
    try std.testing.expectEqual(expected.background.to_u32(), cx.app.default_colors().background.to_u32());
    try std.testing.expectEqual(expected.text.to_u32(), cx.app.default_colors().text.to_u32());
    try std.testing.expectEqual(expected.text.to_u32(), colors_mod.Colors.get_global(cx.app).text.to_u32());
}

test "get_name, set_name and reduce_motion" {
    var cx = TestAppContext.init();
    defer cx.deinit();
    try std.testing.expect(cx.app.get_name() == null);
    cx.set_name("zui-test");
    try std.testing.expectEqualStrings("zui-test", cx.app.get_name().?);

    try std.testing.expect(!cx.app.reduce_motion());
    cx.app.set_reduce_motion(true);
    try std.testing.expect(cx.app.reduce_motion());
}

test "defer runs at the end of the current update, not during it" {
    var cx = TestAppContext.init();
    defer cx.deinit();
    const S = struct {
        var runs: u32 = 0;
        var seen_during_update: u32 = 0;
        fn run(_: *App) void {
            runs += 1;
        }
        fn go(app: *App) void {
            app.@"defer"(run);
            seen_during_update = runs;
        }
    };
    S.runs = 0;
    cx.app.update(S.go, .{});
    try std.testing.expectEqual(@as(u32, 0), S.seen_during_update);
    try std.testing.expectEqual(@as(u32, 1), S.runs);
}

test "deprecation maps are empty without deprecated actions" {
    var cx = TestAppContext.init();
    defer cx.deinit();
    try std.testing.expectEqual(@as(u32, 0), cx.app.deprecated_actions_to_preferred_actions().count());
    try std.testing.expectEqual(@as(u32, 0), cx.app.action_deprecation_messages().count());
}
