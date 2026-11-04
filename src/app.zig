//! Port of GPUI `app.rs`, `app/entity_map.rs`, `app/context.rs`, `global.rs`
//! and `subscription.rs`: the application state, entities, contexts,
//! globals, observers and event subscriptions.

const std = @import("std");
const builtin = @import("builtin");
const geometry = @import("geometry.zig");
const window_mod = @import("window.zig");
const platform_mod = @import("platform.zig");
const element_mod = @import("element.zig");
const text_system_mod = @import("text_system.zig");
const executor_mod = @import("executor.zig");
const keymap_mod = @import("keymap.zig");
const action_mod = @import("action.zig");
const assets_mod = @import("assets.zig");
const uniform_list_mod = @import("elements/uniform_list.zig");
const list_mod = @import("elements/list.zig");

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

const SubscriberKind = enum { observe, event, release, global };

const Subscriber = struct {
    kind: SubscriberKind,
    emitter: u64,
    event_type: ?TypeId = null,
    ctx: usize,
    func: SubscriberFn,
    active: bool = true,
    id: u64,
};

/// A subscription handle (GPUI `Subscription`). Call `unsubscribe` to stop
/// it; `detach` (or just discarding it) keeps it alive for the app's life.
pub const Subscription = struct {
    app: ?*App,
    id: u64,

    pub fn detach(self: Subscription) void {
        _ = self;
    }
    pub fn unsubscribe(self: Subscription) void {
        const app = self.app orelse return;
        for (app.subscribers.items) |*s| if (s.id == self.id) {
            s.active = false;
        };
    }
    pub fn deinit(self: Subscription) void {
        self.unsubscribe();
    }
};

// ---------------------------------------------------------------------------
// Effects.

const Effect = union(enum) {
    notify: EntityId,
    emit: struct { emitter: EntityId, event_type: TypeId, payload: *const anyopaque },
    global_changed: TypeId,
    deferred: struct { ctx: usize, func: *const fn (*App, usize) void },
    refresh_windows,
};

// ---------------------------------------------------------------------------
// App.

const GlobalSlot = struct { ptr: *anyopaque, destroy: *const fn (std.mem.Allocator, *anyopaque) void };

/// The global application state (GPUI `App`).
pub const App = struct {
    allocator: std.mem.Allocator,
    platform: *platform_mod.Platform,
    entities: EntityMap = .{},
    windows: std.ArrayList(?*Window) = .empty,
    globals: std.AutoHashMapUnmanaged(TypeId, GlobalSlot) = .empty,
    subscribers: std.ArrayList(Subscriber) = .empty,
    next_subscription_id: u64 = 1,
    pending_effects: std.ArrayList(Effect) = .empty,
    flushing_effects: bool = false,
    pending_updates: u32 = 0,
    /// Arena for effect payloads; reset after each flush.
    effect_arena: std.heap.ArenaAllocator,
    text_system_: *text_system_mod.TextSystem,
    /// Named assets for `img()` and `svg()` (set with `Application.with_assets`).
    asset_source: assets_mod.AssetSource = assets_mod.AssetSource.empty,
    /// Decoded images, decoded once per source.
    asset_cache: assets_mod.AssetCache,
    background_executor_: executor_mod.BackgroundExecutor,
    foreground_executor_: executor_mod.ForegroundExecutor,
    keymap: keymap_mod.Keymap,
    actions: action_mod.ActionRegistry,
    global_action_listeners: std.ArrayList(action_mod.GlobalActionListener) = .empty,
    next_focus_id: u64 = 1,
    quitting: bool = false,
    reduce_motion: bool = false,
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
        app.foreground_executor_.app = app;
        return app;
    }

    pub fn deinit(self: *App) void {
        for (self.windows.items) |w| if (w) |win| win.destroy(self);
        self.windows.deinit(self.allocator);
        for (self.entities.slots.items) |*s| if (s.ptr) |p| {
            if (s.destroy) |d| d(self, p);
        };
        self.entities.slots.deinit(self.allocator);
        self.entities.free.deinit(self.allocator);
        var it = self.globals.valueIterator();
        while (it.next()) |g| g.destroy(self.allocator, g.ptr);
        self.globals.deinit(self.allocator);
        self.subscribers.deinit(self.allocator);
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

    pub fn release_entity(self: *App, id: EntityId) void {
        const i = id.index();
        if (i >= self.entities.slots.items.len) return;
        const s = &self.entities.slots.items[i];
        if (s.generation != id.generation() or s.ptr == null) return;
        const p = s.ptr.?;
        // Release listeners see the state before it's destroyed.
        for (self.subscribers.items) |*sub| {
            if (sub.active and sub.kind == .release and sub.emitter == id.as_u64()) {
                _ = sub.func(self, id, sub.ctx, p);
                sub.active = false;
            }
        }
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

    /// Schedules `f(cx)` to run after the current effect cycle.
    pub fn defer_(self: *App, comptime f: anytype) void {
        const S = struct {
            fn call(app: *App, _: usize) void {
                f(app);
            }
        };
        self.push_effect(.{ .deferred = .{ .ctx = 0, .func = S.call } });
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

    pub fn remove_global(self: *App, comptime G: type) void {
        if (self.globals.fetchRemove(type_id(G))) |kv| kv.value.destroy(self.allocator, kv.value.ptr);
    }

    /// Observes global `G` from outside an entity: `f(cx)`.
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
        for (self.windows.items, 0..) |w, i| if (w == win) {
            self.windows.items[i] = null;
        };
        win.destroy(self);
        var any_open = false;
        for (self.windows.items) |w| any_open = any_open or w != null;
        if (!any_open and self.platform.quit_when_last_window_closes()) self.quit();
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

    /// Spawns a foreground task `f(async_cx, args...)`.
    pub fn spawn(self: *App, comptime f: anytype, args: anytype) executor_mod.Task(ReturnOf(f)) {
        return self.foreground_executor_.spawn(f, .{self.to_async()} ++ args);
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

    pub fn displays(self: *App) []const platform_mod.Display {
        return self.platform.displays();
    }

    pub fn primary_display(self: *App) ?platform_mod.Display {
        return self.platform.primary_display();
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

    pub fn write_to_primary(self: *App, item: platform_mod.ClipboardItem) void {
        self.platform.write_to_primary(item);
    }

    pub fn read_from_primary(self: *App) ?platform_mod.ClipboardItem {
        return self.platform.read_from_primary();
    }

    pub fn open_url(self: *App, url: []const u8) void {
        self.platform.open_url(url);
    }

    pub fn set_reduce_motion(self: *App, v: bool) void {
        self.reduce_motion = v;
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

    pub fn is_action_available(self: *App, comptime A: type) bool {
        for (self.global_action_listeners.items) |l| if (l.action_type == type_id(A)) return true;
        if (self.active_window()) |w| return w.is_action_available(type_id(A));
        return false;
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
    pub fn with_assets(self: Application, source: anytype) Application {
        self.app.asset_source = if (@TypeOf(source) == assets_mod.AssetSource) source else assets_mod.AssetSource.from(source);
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
        self.app.deinit();
        self.platform.deinit();
    }

    /// Registers a callback for when the app is asked to open URLs.
    pub fn on_open_urls(self: Application, comptime f: fn ([]const []const u8, *App) void) Application {
        _ = f;
        return self;
    }
};

fn default_allocator() std.mem.Allocator {
    if (builtin.is_test) return std.testing.allocator;
    return std.heap.smp_allocator;
}
