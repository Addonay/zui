const std = @import("std");
const builtin = @import("builtin");
const platform = @import("../platform/root.zig");
const elements = @import("../elements/root.zig");
const zlog = @import("../core/log.zig");
const Window = @import("window.zig").Window;

pub const FocusHandle = elements.FocusHandle;
pub const Listener = elements.Listener;

/// Ownership contract (gap §5A): one foreground (UI) thread owns every
/// entity. `Entity` is an owned handle valid until `destroy()`; `WeakEntity`
/// is a generation-checked handle for async completions and retained
/// callbacks — `upgrade()` returns null after destroy instead of aliasing
/// recycled memory. Listeners and focus handles minted from an entity carry
/// the same (store, id, generation) subscription and dispatch as a safe
/// no-op/false once the owner is destroyed (subscription cleanup is
/// inseparable from dispatch: liveness is resolved through the store before
/// the raw target is touched, so destroyed targets can never observe a
/// late completion or input event).
const EntityHeader = struct {
    store: *EntityStore,
    id: u32,
    /// Minted per entity from `next_generation`; never 0. A weak handle or
    /// subscription matches only when id AND generation still resolve to a
    /// live header, so destroyed targets fail predictably.
    generation: u32 = 0,
    /// Type tag (`typeTag(T)`) so a weak handle of the wrong value type
    /// fails to upgrade instead of mis-casting recycled memory.
    type_tag: u64 = 0,
    alive: bool = true,
    value_ptr: *anyopaque,
    next: ?*EntityHeader = null,
    /// Window scope (gap report §5.2): entities created with a window
    /// attached (mountView root and every `create(.., win)` child) are
    /// destroyed by `destroyWindowScope` when that window closes. Zero
    /// means app-lifetime (created with `window = null`).
    window_id: u32 = 0,
    destroy_fn: *const fn (*EntityHeader) void,
    /// The allocation this header lives in (the `Box`), carried explicitly:
    /// values with alignment above the header's (any stored `Listener`,
    /// whose payload is a 16-byte extern union) cannot be recovered with
    /// `@fieldParentPtr` from the header pointer alone.
    destroy_ctx: ?*anyopaque = null,
};

pub fn typeTag(comptime T: type) u64 {
    return std.hash.Wyhash.hash(0, @typeName(T));
}

pub const GlobalError = error{ GlobalAlreadySet, GlobalCapacityExceeded, GlobalNotSet, InvalidReservation };

const GlobalSlot = struct {
    type_tag: u64,
    value_ptr: ?*anyopaque = null,
    destroy_fn: ?*const fn (*anyopaque, std.mem.Allocator) void = null,
};

pub const SubscriptionError = error{SubscriptionCapacityExceeded};

const SubscriptionSlot = struct {
    id: u64,
    entity_id: u32,
    generation: u32,
    owner_id: u32 = 0,
    owner_generation: u32 = 0,
    active: bool = true,
    callback: *const fn (*const anyopaque, *anyopaque) void,
    ctx: *anyopaque,
};

pub const InvalidationScope = struct {
    store: *EntityStore,
    generation: u64,
    window: ?*Window,

    pub fn isValid(self: @This()) bool {
        return self.store.invalidation_generation == self.generation;
    }

    pub fn invalidate(self: @This()) void {
        self.store.invalidate();
    }

    pub fn windowTarget(self: @This()) ?*Window {
        return self.window;
    }
};

pub fn GlobalReservation(comptime T: type) type {
    return struct {
        store: *EntityStore,
        slot_index: usize,
        active: bool = true,

        pub fn set(self: *@This(), value: T) GlobalError!void {
            if (!self.active) return error.InvalidReservation;
            try self.store.installReservedGlobal(self.slot_index, T, value);
            self.active = false;
        }

        pub fn cancel(self: *@This()) void {
            if (!self.active) return;
            self.store.cancelGlobalReservation(self.slot_index);
            self.active = false;
        }
    };
}

pub const EntityReservationError = error{InvalidReservation};

/// A typed identity reservation matching GPUI's Reservation contract. The
/// id/generation are minted immediately, so weak references can be handed to
/// other state before the value is inserted; the slot remains non-live until
/// `insert` succeeds.
pub fn EntityReservation(comptime T: type) type {
    return struct {
        store: *EntityStore,
        id_value: u32,
        generation_value: u32,
        active: bool = true,

        pub fn id(self: @This()) u32 {
            return self.id_value;
        }

        pub fn generation(self: @This()) u32 {
            return self.generation_value;
        }

        pub fn insert(self: *@This(), options: T.Options, window: ?*Window) EntityReservationError!Entity(T) {
            if (!self.active) return error.InvalidReservation;
            self.active = false;
            return self.store.createWithIdentity(T, options, window, self.id_value, self.generation_value);
        }

        pub fn cancel(self: *@This()) void {
            self.active = false;
        }
    };
}

pub const Subscription = struct {
    store: *EntityStore,
    id: u64,
    active: bool = true,

    pub fn cancel(self: *@This()) void {
        if (!self.active) return;
        self.store.cancelSubscription(self.id);
        self.active = false;
    }

    pub fn isActive(self: @This()) bool {
        return self.active and self.store.subscriptionIsActive(self.id);
    }
};

pub const EntityStore = struct {
    allocator: std.mem.Allocator,
    head: ?*EntityHeader = null,
    next_id: u32 = 1,
    /// Monotonic entity generation; 0 is never minted (see EntityHeader).
    next_generation: u32 = 1,
    dirty: bool = false,
    /// UI-thread ownership (gap §5A): captured at init; every create /
    /// destroy / update asserts the calling thread in debug builds.
    owner_thread: std.Thread.Id,
    globals: std.ArrayList(GlobalSlot) = .empty,
    subscriptions: std.ArrayList(SubscriptionSlot) = .empty,
    next_subscription_id: u64 = 1,
    invalidation_generation: u64 = 1,

    pub fn init(allocator: std.mem.Allocator) EntityStore {
        // Wire the single subscription-liveness probe the element layer
        // consults (idempotent: every store wires the same function).
        elements.element.entity_is_alive_fn = entityAlive;
        return .{ .allocator = allocator, .owner_thread = std.Thread.getCurrentId() };
    }

    pub fn invalidate(self: *EntityStore) void {
        self.assertUiThread();
        self.invalidation_generation +%= 1;
        if (self.invalidation_generation == 0) self.invalidation_generation = 1;
        self.dirty = true;
    }

    pub fn scope(self: *EntityStore, window: ?*Window) InvalidationScope {
        self.assertUiThread();
        return .{ .store = self, .generation = self.invalidation_generation, .window = window };
    }

    fn destroyGlobalSlot(self: *EntityStore, slot: *GlobalSlot) void {
        if (slot.value_ptr) |value| if (slot.destroy_fn) |destroy| destroy(value, self.allocator);
        slot.* = .{ .type_tag = 0 };
    }

    fn installGlobalValue(self: *EntityStore, slot: *GlobalSlot, comptime T: type, value: T) GlobalError!void {
        const Box = struct { value: T };
        const box = self.allocator.create(Box) catch return error.GlobalCapacityExceeded;
        box.* = .{ .value = value };
        slot.value_ptr = @ptrCast(box);
        slot.destroy_fn = struct {
            fn destroy(raw: *anyopaque, allocator: std.mem.Allocator) void {
                const typed: *Box = @ptrCast(@alignCast(raw));
                if (@hasDecl(T, "deinit")) typed.value.deinit();
                allocator.destroy(typed);
            }
        }.destroy;
    }

    pub fn setGlobal(self: *EntityStore, comptime T: type, value: T) GlobalError!void {
        self.assertUiThread();
        const tag = typeTag(T);
        for (self.globals.items) |*slot| {
            if (slot.type_tag != tag) continue;
            if (slot.value_ptr) |old| if (slot.destroy_fn) |destroy| destroy(old, self.allocator);
            slot.value_ptr = null;
            slot.destroy_fn = null;
            return self.installGlobalValue(slot, T, value);
        }
        self.globals.append(self.allocator, .{ .type_tag = tag }) catch return error.GlobalCapacityExceeded;
        return self.installGlobalValue(&self.globals.items[self.globals.items.len - 1], T, value);
    }

    pub fn global(self: *const EntityStore, comptime T: type) ?*const T {
        const tag = typeTag(T);
        for (self.globals.items) |slot| {
            if (slot.type_tag == tag) {
                const raw = slot.value_ptr orelse return null;
                return @ptrCast(@alignCast(raw));
            }
        }
        return null;
    }

    pub fn globalMut(self: *EntityStore, comptime T: type) ?*T {
        return if (self.global(T)) |value| @constCast(value) else null;
    }

    /// Mutate a typed global through the same UI-thread/invalidation boundary
    /// as entity updates. Callers receive an explicit error instead of
    /// silently creating a value with an accidental default.
    pub fn updateGlobal(self: *EntityStore, comptime T: type, callback: *const fn (*T, *EntityStore) void) GlobalError!void {
        self.assertUiThread();
        const value = self.globalMut(T) orelse return error.GlobalNotSet;
        callback(value, self);
        self.invalidate();
    }

    pub fn removeGlobal(self: *EntityStore, comptime T: type) bool {
        self.assertUiThread();
        const tag = typeTag(T);
        for (self.globals.items) |*slot| {
            if (slot.type_tag == tag) {
                self.destroyGlobalSlot(slot);
                return true;
            }
        }
        return false;
    }

    pub fn reserveGlobal(self: *EntityStore, comptime T: type) GlobalError!GlobalReservation(T) {
        self.assertUiThread();
        const tag = typeTag(T);
        for (self.globals.items) |slot| if (slot.type_tag == tag) return error.GlobalAlreadySet;
        self.globals.append(self.allocator, .{ .type_tag = tag }) catch return error.GlobalCapacityExceeded;
        return .{ .store = self, .slot_index = self.globals.items.len - 1 };
    }

    fn installReservedGlobal(self: *EntityStore, index: usize, comptime T: type, value: T) GlobalError!void {
        self.assertUiThread();
        if (index >= self.globals.items.len) return error.InvalidReservation;
        const slot = &self.globals.items[index];
        if (slot.type_tag != typeTag(T) or slot.value_ptr != null) return error.InvalidReservation;
        try self.installGlobalValue(slot, T, value);
    }

    fn cancelGlobalReservation(self: *EntityStore, index: usize) void {
        self.assertUiThread();
        if (index < self.globals.items.len and self.globals.items[index].value_ptr == null) self.globals.items[index].type_tag = 0;
    }

    pub fn subscribe(self: *EntityStore, comptime T: type, entity: WeakEntity(T), ctx: *anyopaque, callback: *const fn (*const T, *anyopaque) void) SubscriptionError!Subscription {
        return self.subscribeOwned(T, entity, null, ctx, callback);
    }

    fn subscribeOwned(self: *EntityStore, comptime T: type, entity: WeakEntity(T), owner: ?*EntityHeader, ctx: *anyopaque, callback: *const fn (*const T, *anyopaque) void) SubscriptionError!Subscription {
        self.assertUiThread();
        const id = self.next_subscription_id;
        self.next_subscription_id +%= 1;
        if (self.next_subscription_id == 0) self.next_subscription_id = 1;
        self.subscriptions.append(self.allocator, .{
            .id = id,
            .entity_id = entity.id,
            .generation = entity.generation,
            .owner_id = if (owner) |value| value.id else 0,
            .owner_generation = if (owner) |value| value.generation else 0,
            .callback = @ptrCast(callback),
            .ctx = ctx,
        }) catch return error.SubscriptionCapacityExceeded;
        return .{ .store = self, .id = id };
    }

    fn cancelSubscription(self: *EntityStore, id: u64) void {
        self.assertUiThread();
        for (self.subscriptions.items) |*subscription| {
            if (subscription.id == id) subscription.active = false;
        }
    }

    /// Tear down subscriptions at the same lifetime boundary as their
    /// entity. This is deterministic even when no later notification occurs.
    pub fn cancelSubscriptionsFor(self: *EntityStore, id: u32, generation: u32) void {
        self.assertUiThread();
        for (self.subscriptions.items) |*subscription| {
            if ((subscription.entity_id == id and subscription.generation == generation) or
                (subscription.owner_id == id and subscription.owner_generation == generation))
            {
                subscription.active = false;
            }
        }
        var i: usize = 0;
        while (i < self.subscriptions.items.len) {
            if (!self.subscriptions.items[i].active) _ = self.subscriptions.swapRemove(i) else i += 1;
        }
    }

    fn subscriptionIsActive(self: *const EntityStore, id: u64) bool {
        for (self.subscriptions.items) |subscription| if (subscription.id == id) return subscription.active;
        return false;
    }

    fn emitEntity(self: *EntityStore, comptime T: type, entity: Entity(T)) void {
        self.assertUiThread();
        for (self.subscriptions.items) |*subscription| {
            if (!subscription.active or subscription.entity_id != entity.header.id or subscription.generation != entity.header.generation) continue;
            subscription.callback(@ptrCast(entity.value), subscription.ctx);
        }
        var i: usize = 0;
        while (i < self.subscriptions.items.len) {
            if (!self.subscriptions.items[i].active) {
                _ = self.subscriptions.swapRemove(i);
            } else {
                i += 1;
            }
        }
    }

    fn assertUiThread(self: *const EntityStore) void {
        if (comptime builtin.single_threaded) return;
        std.debug.assert(std.meta.eql(self.owner_thread, std.Thread.getCurrentId()));
    }

    /// Live entity count (observable budget for mount/unmount tests).
    pub fn count(self: *const EntityStore) usize {
        var n: usize = 0;
        var current = self.head;
        while (current) |header| {
            n += 1;
            current = header.next;
        }
        return n;
    }

    /// Generation-checked liveness: true only when (id, generation) still
    /// resolves to a live header. Backs weak handles and the subscription
    /// guards on `Listener`/`FocusHandle`; read-only, never touches values.
    pub fn isAlive(self: *const EntityStore, id: u32, generation: u32) bool {
        if (generation == 0) return false;
        var current = self.head;
        while (current) |header| {
            if (header.id == id and header.generation == generation and header.alive) return true;
            current = header.next;
        }
        return false;
    }

    fn lookupTyped(self: *EntityStore, comptime T: type, id: u32, generation: u32) ?Entity(T) {
        if (generation == 0) return null;
        var current = self.head;
        while (current) |header| {
            if (header.id == id and header.generation == generation and header.alive and header.type_tag == typeTag(T)) {
                return Entity(T){ .header = header, .value = @ptrCast(@alignCast(header.value_ptr)) };
            }
            current = header.next;
        }
        return null;
    }

    /// Individual release path (gap §5A): unlinks the entity, marks its
    /// generation dead so weak handles and subscriptions fail predictably,
    /// then frees the allocation. The integer primitive is idempotent:
    /// destroying an unknown or already-destroyed (id, generation) is a
    /// safe no-op (teardown paths may overlap, e.g. window close racing an
    /// explicit destroy). Prefer this over `destroyEntity` when holding
    /// only an id — it never touches a possibly-freed header pointer.
    pub fn destroyById(self: *EntityStore, id: u32, generation: u32) void {
        self.assertUiThread();
        if (generation == 0) return;
        var prev: ?*EntityHeader = null;
        var current = self.head;
        while (current) |h| {
            if (h.id == id and h.generation == generation and h.alive) {
                self.cancelSubscriptionsFor(id, generation);
                if (prev) |p| {
                    p.next = h.next;
                } else {
                    self.head = h.next;
                }
                h.alive = false;
                h.destroy_fn(h);
                self.dirty = true;
                return;
            }
            prev = h;
            current = h.next;
        }
        zlog.log("entity", "destroy of unknown entity ignored", .{});
    }

    /// Release via a live header. The header must still resolve live (i.e.
    /// the entity was not already destroyed); for retry-safe teardown use
    /// `destroyById` with a saved (id, generation) pair instead.
    pub fn destroyEntity(self: *EntityStore, header: *EntityHeader) void {
        self.destroyById(header.id, header.generation);
    }

    /// Destroy every entity scoped to a window (gap report §5.2): the
    /// mountView root plus every entity created with that window attached.
    /// Called by `App.reapClosed` before the Window itself is freed, so
    /// subscriptions/listeners targeting the scope fail predictably and
    /// entity counts/allocations return to baseline. Entities created with
    /// `window = null` are never touched.
    pub fn destroyWindowScope(self: *EntityStore, window_id: u32) void {
        self.assertUiThread();
        if (window_id == 0) return;
        var current = self.head;
        while (current) |h| {
            const next = h.next;
            if (h.window_id == window_id) {
                // destroyById handles unlink + destroy; find its pair.
                self.destroyById(h.id, h.generation);
            }
            current = next;
        }
    }

    pub fn deinit(self: *EntityStore) void {
        var current = self.head;
        while (current) |header| {
            const next = header.next;
            header.destroy_fn(header);
            current = next;
        }
        self.head = null;
        for (self.globals.items) |*slot| self.destroyGlobalSlot(slot);
        self.globals.deinit(self.allocator);
        self.subscriptions.deinit(self.allocator);
    }

    pub fn reserveEntity(self: *EntityStore, comptime T: type) EntityReservation(T) {
        self.assertUiThread();
        const id = self.next_id;
        self.next_id +%= 1;
        const generation = self.next_generation;
        self.next_generation +%= 1;
        if (self.next_generation == 0) self.next_generation = 1;
        return .{ .store = self, .id_value = id, .generation_value = generation };
    }

    pub fn insertEntity(self: *EntityStore, comptime T: type, reservation: *EntityReservation(T), options: T.Options, window: ?*Window) EntityReservationError!Entity(T) {
        if (reservation.store != self) return error.InvalidReservation;
        return reservation.insert(options, window);
    }

    pub fn create(self: *EntityStore, comptime T: type, options: T.Options, window: ?*Window) Entity(T) {
        self.assertUiThread();
        const id = self.next_id;
        self.next_id += 1;
        const generation = self.next_generation;
        self.next_generation +%= 1;
        if (self.next_generation == 0) self.next_generation = 1;
        return self.createWithIdentity(T, options, window, id, generation);
    }

    fn createWithIdentity(self: *EntityStore, comptime T: type, options: T.Options, window: ?*Window, id: u32, generation: u32) Entity(T) {
        self.assertUiThread();
        const Box = struct {
            header: EntityHeader,
            value: T,
        };
        const box = self.allocator.create(Box) catch @panic("out of memory creating ZUI entity");
        box.header = .{
            .store = self,
            .id = id,
            .generation = generation,
            .type_tag = typeTag(T),
            .alive = true,
            .value_ptr = &box.value,
            .next = self.head,
            .window_id = if (window) |w| w.id else 0,
            .destroy_fn = struct {
                fn destroy(raw: *EntityHeader) void {
                    const typed: *Box = @ptrCast(@alignCast(raw.destroy_ctx.?));
                    if (@hasDecl(T, "deinit")) typed.value.deinit();
                    raw.store.allocator.destroy(typed);
                }
            }.destroy,
            .destroy_ctx = @ptrCast(box),
        };
        self.head = &box.header;

        const entity = Entity(T){ .header = &box.header, .value = &box.value };
        var cx = Context(T){ .store = self, .current = entity, .window = window };
        if (@hasDecl(T, "init")) {
            box.value = T.init(&cx, options);
        } else if (@TypeOf(options) == T) {
            box.value = options;
        } else {
            @compileError(@typeName(T) ++ " needs init(cx, options)");
        }
        return entity;
    }
};

/// Generation-checked weak handle (gap §5A): the safe handle for async
/// completions and retained callbacks. `upgrade()` resolves through the
/// store and returns null once the target was destroyed (or when the type
/// mismatches), so a late completion can never mutate a destroyed target.
pub fn WeakEntity(comptime T: type) type {
    return struct {
        store: *EntityStore,
        id: u32,
        generation: u32,

        pub fn upgrade(self: @This()) ?Entity(T) {
            return self.store.lookupTyped(T, self.id, self.generation);
        }

        pub fn isAlive(self: @This()) bool {
            return self.store.isAlive(self.id, self.generation);
        }
    };
}

/// Store-level liveness probe behind the `Listener`/`FocusHandle`
/// subscription guards. Resolves through the header list only — never
/// touches the (possibly freed) target — so post-destroy dispatch is safe.
fn entityAlive(raw_store: *anyopaque, id: u32, generation: u32) bool {
    const store: *const EntityStore = @ptrCast(@alignCast(raw_store));
    return store.isAlive(id, generation);
}

pub fn Entity(comptime T: type) type {
    return struct {
        pub const Value = T;
        pub const is_entity = true;
        pub const Weak = WeakEntity(T);

        header: *EntityHeader,
        value: *T,

        pub fn read(self: @This()) *const T {
            return self.value;
        }

        /// Mutable access. Marks the store dirty (reliable invalidation:
        /// any mutable borrow may have changed rendering), so `readMut`
        /// can never silently bypass the update path.
        pub fn readMut(self: @This()) *T {
            self.header.store.assertUiThread();
            self.header.store.dirty = true;
            return self.value;
        }

        /// True while this handle's (id, generation) still resolves live.
        pub fn isAlive(self: @This()) bool {
            return self.header.store.isAlive(self.header.id, self.header.generation);
        }

        /// Weak handle for async completions: fails predictably after
        /// `destroy()` instead of aliasing recycled memory.
        pub fn weak(self: @This()) WeakEntity(T) {
            return .{ .store = self.header.store, .id = self.header.id, .generation = self.header.generation };
        }

        pub fn id(self: @This()) u32 {
            return self.header.id;
        }

        pub fn generation(self: @This()) u32 {
            return self.header.generation;
        }

        /// Individual release (gap §5A): unlinks and frees this entity,
        /// retires its generation, and invalidates weak handles plus all
        /// listeners/focus handles minted from it. The owned `Entity`
        /// handle must not be used afterwards; use `weak()` for anything
        /// that may outlive the entity.
        pub fn destroy(self: @This()) void {
            self.header.store.destroyEntity(self.header);
        }

        pub fn update(self: @This(), comptime callback: anytype) CallbackReturn(callback) {
            self.header.store.assertUiThread();
            var cx = Context(T){ .store = self.header.store, .current = self, .window = null };
            const info = @typeInfo(@TypeOf(callback)).@"fn";
            const result = if (info.param_types.len == 1)
                callback(self.value)
            else
                callback(self.value, &cx);
            self.header.store.dirty = true;
            self.header.store.emitEntity(T, self);
            return result;
        }

        pub fn updateWith(self: @This(), payload: anytype, comptime callback: anytype) CallbackReturn(callback) {
            self.header.store.assertUiThread();
            var cx = Context(T){ .store = self.header.store, .current = self, .window = null };
            const info = @typeInfo(@TypeOf(callback)).@"fn";
            const result = if (info.param_types.len == 2)
                callback(self.value, payload)
            else
                callback(self.value, payload, &cx);
            self.header.store.dirty = true;
            self.header.store.emitEntity(T, self);
            return result;
        }

        pub fn actionListener(self: @This(), comptime callback: anytype) Listener {
            return makeListener(T, self, callback);
        }

        pub fn focusHandle(self: @This(), cx: anytype) FocusHandle {
            _ = cx;
            return makeFocus(T, self);
        }

        pub fn toElement(self: @This()) elements.Element {
            const window: *Window = @ptrCast(@alignCast(elements.element.currentWindow()));
            var cx = Context(T){ .store = self.header.store, .current = self, .window = window };
            var rendered = self.value.render(window, &cx);
            if (@hasDecl(T, "handleEvent")) rendered = rendered.withFocus(makeFocus(T, self));
            return rendered;
        }
    };
}

fn CallbackReturn(comptime callback: anytype) type {
    return @typeInfo(@TypeOf(callback)).@"fn".return_type.?;
}

pub fn Context(comptime T: type) type {
    return struct {
        store: *EntityStore,
        current: ?Entity(T) = null,
        window: ?*Window = null,

        pub fn allocator(self: *@This()) std.mem.Allocator {
            return self.store.allocator;
        }

        pub fn entity(self: *@This()) Entity(T) {
            return self.current orelse @panic("context has no entity");
        }

        pub fn weakEntity(self: *@This()) WeakEntity(T) {
            return self.entity().weak();
        }

        pub fn entityId(self: *@This()) u32 {
            return self.entity().id();
        }

        pub fn new(self: *@This(), comptime U: type, options: U.Options) Entity(U) {
            return self.store.create(U, options, self.window);
        }

        pub fn reserve(self: *@This(), comptime U: type) EntityReservation(U) {
            return self.store.reserveEntity(U);
        }

        pub fn insert(self: *@This(), comptime U: type, reservation: *EntityReservation(U), options: U.Options) EntityReservationError!Entity(U) {
            return self.store.insertEntity(U, reservation, options, self.window);
        }

        pub fn focusHandle(self: *@This()) FocusHandle {
            return makeFocus(T, self.current.?);
        }

        pub fn notify(self: *@This()) void {
            self.store.dirty = true;
            self.store.invalidate();
            if (self.current) |current_entity| self.store.emitEntity(T, current_entity);
            if (self.window) |window| window.requestRender();
        }

        pub fn invalidate(self: *@This()) void {
            self.store.invalidate();
            if (self.window) |window| window.requestRender();
        }

        pub fn scope(self: *@This()) InvalidationScope {
            return self.store.scope(self.window);
        }

        pub fn global(self: *@This(), comptime U: type) ?*const U {
            return self.store.global(U);
        }

        pub fn globalMut(self: *@This(), comptime U: type) ?*U {
            return self.store.globalMut(U);
        }

        pub fn updateGlobal(self: *@This(), comptime U: type, callback: *const fn (*U, *@This()) void) GlobalError!void {
            const value = self.store.globalMut(U) orelse return error.GlobalNotSet;
            callback(value, self);
            self.notify();
        }

        pub fn setGlobal(self: *@This(), comptime U: type, value: U) GlobalError!void {
            return self.store.setGlobal(U, value);
        }

        pub fn reserveGlobal(self: *@This(), comptime U: type) GlobalError!GlobalReservation(U) {
            return self.store.reserveGlobal(U);
        }

        pub fn subscribe(self: *@This(), comptime U: type, target_entity: Entity(U), ctx: *anyopaque, callback: *const fn (*const U, *anyopaque) void) SubscriptionError!Subscription {
            return self.store.subscribeOwned(U, target_entity.weak(), if (self.current) |current| current.header else null, ctx, callback);
        }

        pub fn subscribeSelf(self: *@This(), ctx: *anyopaque, callback: *const fn (*const T, *anyopaque) void) SubscriptionError!Subscription {
            const current = self.current orelse return error.SubscriptionCapacityExceeded;
            return self.store.subscribeOwned(T, current.weak(), current.header, ctx, callback);
        }

        /// Spawn entity-scoped work on an app-owned TaskRuntime. The runtime
        /// type is generic here to keep runtime.zig independent of tasks.zig.
        pub fn spawn(self: *@This(), task_runtime: anytype, user: anytype, comptime run: anytype, comptime done: anytype) @TypeOf(task_runtime.spawnForEntity(T, self.weakEntity(), self.window, user, run, done)) {
            return task_runtime.spawnForEntity(T, self.weakEntity(), self.window, user, run, done);
        }

        pub fn listener(self: *@This(), comptime Owner: type, comptime callback: anytype) Listener {
            if (Owner != T) @compileError("listener owner must match Context owner");
            return makeListener(T, self.current.?, callback);
        }

        pub fn listenerWith(self: *@This(), comptime Payload: type, comptime Owner: type, comptime callback: anytype, payload: Payload) Listener {
            if (Owner != T) @compileError("listener owner must match Context owner");
            return makePayloadListener(T, Payload, self.current.?, callback, payload);
        }

        pub fn bindKeys(self: *@This(), comptime Owner: type, bindings: anytype) void {
            if (Owner != T) @compileError("key binding owner must match Context owner");
            const window = self.window orelse return;
            inline for (bindings.*) |binding| window.addKeyBinding(binding.key, binding.action);
        }
    };
}

fn makeListener(comptime T: type, entity: Entity(T), comptime callback: anytype) Listener {
    elements.element.trackEntityOwner(entity.header, entity.header.store, entity.header.id, entity.header.generation);
    return .{
        .target = entity.header,
        .call_fn = struct {
            fn call(raw: *anyopaque, _: *const elements.element.ListenerPayload, raw_window: *anyopaque) void {
                const header: *EntityHeader = @ptrCast(@alignCast(raw));
                const value: *T = @ptrCast(@alignCast(header.value_ptr));
                const typed_entity = Entity(T){ .header = header, .value = value };
                const window: *Window = @ptrCast(@alignCast(raw_window));
                var cx = Context(T){ .store = header.store, .current = typed_entity, .window = window };
                const info = @typeInfo(@TypeOf(callback)).@"fn";
                if (info.param_types.len == 2) {
                    _ = callback(value, &cx);
                } else if (info.param_types.len == 3) {
                    _ = callback(value, window, &cx);
                } else {
                    @compileError("unsupported listener callback signature");
                }
            }
        }.call,
    };
}

fn makePayloadListener(comptime T: type, comptime Payload: type, entity: Entity(T), comptime callback: anytype, payload: Payload) Listener {
    if (@sizeOf(Payload) > 16 or @alignOf(Payload) > @alignOf(u128)) @compileError("listener payload is too large");
    elements.element.trackEntityOwner(entity.header, entity.header.store, entity.header.id, entity.header.generation);
    var result = Listener{
        .target = entity.header,
        .call_fn = struct {
            fn call(raw: *anyopaque, raw_payload: *const elements.element.ListenerPayload, raw_window: *anyopaque) void {
                const header: *EntityHeader = @ptrCast(@alignCast(raw));
                const value: *T = @ptrCast(@alignCast(header.value_ptr));
                const typed_entity = Entity(T){ .header = header, .value = value };
                const window: *Window = @ptrCast(@alignCast(raw_window));
                const typed_payload: *const Payload = @ptrCast(@alignCast(&raw_payload.bytes));
                var cx = Context(T){ .store = header.store, .current = typed_entity, .window = window };
                const info = @typeInfo(@TypeOf(callback)).@"fn";
                if (info.param_types.len == 3) {
                    _ = callback(value, typed_payload.*, &cx);
                } else if (info.param_types.len == 4) {
                    _ = callback(value, typed_payload.*, window, &cx);
                } else {
                    @compileError("unsupported payload listener callback signature");
                }
            }
        }.call,
    };
    @memcpy(result.payload.bytes[0..@sizeOf(Payload)], std.mem.asBytes(&payload));
    return result;
}

fn makeFocus(comptime T: type, entity: Entity(T)) FocusHandle {
    elements.element.trackEntityOwner(entity.header, entity.header.store, entity.header.id, entity.header.generation);
    return .{
        .id = entity.header.id,
        .target = entity.header,
        .owner_store = entity.header.store,
        .owner_generation = entity.header.generation,
        .event_fn = if (@hasDecl(T, "handleEvent")) struct {
            fn dispatch(raw: *anyopaque, event: platform.Event, raw_window: *anyopaque) bool {
                const header: *EntityHeader = @ptrCast(@alignCast(raw));
                const value: *T = @ptrCast(@alignCast(header.value_ptr));
                const typed_entity = Entity(T){ .header = header, .value = value };
                const window: *Window = @ptrCast(@alignCast(raw_window));
                var cx = Context(T){ .store = header.store, .current = typed_entity, .window = window };
                return value.handleEvent(event, &cx);
            }
        }.dispatch else null,
    };
}

pub fn mountView(store: *EntityStore, window: *Window, build_fn: anytype) void {
    const info = @typeInfo(@TypeOf(build_fn)).@"fn";
    const Return = info.return_type.?;
    if (!@hasDecl(Return, "is_entity")) @compileError("view builder must return Entity(T)");
    const T = Return.Value;
    var cx = Context(T){ .store = store, .current = null, .window = window };
    const root = build_fn(window, &cx);
    mountEntity(store, window, root);
}

/// Mount an already-created typed view entity. This is the source-backed
/// counterpart of GPUI's `Window::open_view`: the entity remains the stable
/// identity while each frame calls its typed render method.
pub fn mountEntity(store: *EntityStore, window: *Window, root: anytype) void {
    _ = store;
    _ = store;
    const T = @TypeOf(root).Value;
    window.setRenderer(.{
        .ptr = root.header,
        .render_fn = struct {
            fn render(raw: ?*anyopaque, win: *Window, scene: *@import("../gpu/root.zig").Scene) void {
                const header: *EntityHeader = @ptrCast(@alignCast(raw.?));
                const value: *T = @ptrCast(@alignCast(header.value_ptr));
                const entity = Entity(T){ .header = header, .value = value };
                var render_cx = Context(T){ .store = header.store, .current = entity, .window = win };
                win.ui_frame.reset(win, win.pointer_position);
                win.ui_frame.images = win.images;
                // Text is always cozmic: install the App-owned engine (null
                // when the host has no fonts or init failed; text then draws
                // nothing). The provider is memoized, so a failed init is
                // not retried per frame.
                win.ui_frame.engine = null;
                if (win.cozmic_engine_fn) |provide| {
                    const ctx: *anyopaque = if (win.cozmic_engine_ctx) |c| c else win;
                    win.ui_frame.engine = provide(ctx);
                }
                win.ui_frame.frame_id = win.frame_id;
                win.ui_frame.allocator = win.allocator;
                elements.element.beginFrame(&win.ui_frame);
                defer elements.element.endFrame();
                const root_element = value.render(win, &render_cx);
                const diagnostics = @import("../debug/stats.zig");
                const layout_start = diagnostics.nowNs();
                elements.layout.layout(&win.ui_frame, root_element, .{ .x = 0, .y = 0, .w = win.bounds.size.w, .h = win.bounds.size.h });
                win.frame_durations.layout_ns = diagnostics.elapsed(layout_start);
                const paint_start = diagnostics.nowNs();
                elements.painter.paint(&win.ui_frame, root_element, scene);
                win.frame_durations.paint_ns = diagnostics.elapsed(paint_start);
                win.updateHitRegions();
                // NB: do NOT clear store.dirty here. App.step owns the
                // store->window fan-out and clears before rendering, so a
                // notify() during render survives for the next frame and
                // other windows are not starved by the first window's clear.
            }
        }.render,
    });
}

pub const TestHarness = struct {
    store: EntityStore,

    pub fn init(allocator: std.mem.Allocator) !TestHarness {
        return .{ .store = EntityStore.init(allocator) };
    }

    pub fn deinit(self: *TestHarness) void {
        self.store.deinit();
    }

    pub fn new(self: *TestHarness, comptime T: type, options: T.Options) Entity(T) {
        return self.store.create(T, options, null);
    }
};

test "entities can hold over-aligned values" {
    // Regression: a value whose alignment exceeds EntityHeader's (any stored
    // `Listener`, whose payload is a 16-byte extern union) used to fail the
    // box's @fieldParentPtr.
    const t = std.testing;
    const Over = struct {
        pub const Options = struct {};
        payload: elements.element.ListenerPayload = .{ .alignment = 0 },

        pub fn init(_: *Context(@This()), _: Options) @This() {
            return .{};
        }
    };

    var harness = try TestHarness.init(t.allocator);
    defer harness.deinit();
    const entity = harness.new(Over, .{});
    try t.expect(@intFromPtr(entity.value) % 16 == 0);
}

test "typed globals reservations and scoped subscriptions are deterministic" {
    const t = std.testing;
    var harness = try TestHarness.init(t.allocator);
    defer harness.deinit();

    const Global = struct { value: u32 };
    var reservation = try harness.store.reserveGlobal(Global);
    try t.expect(harness.store.global(Global) == null);
    try reservation.set(.{ .value = 7 });
    try t.expectEqual(@as(u32, 7), harness.store.global(Global).?.value);
    try harness.store.updateGlobal(Global, struct {
        fn bump(value: *Global, store: *EntityStore) void {
            value.value += 5;
            _ = store;
        }
    }.bump);
    try t.expectEqual(@as(u32, 12), harness.store.global(Global).?.value);
    try t.expectError(error.GlobalAlreadySet, harness.store.reserveGlobal(Global));

    const Counter = struct {
        pub const Options = struct {};
        value: u32 = 0,
        pub fn init(_: *Context(@This()), _: Options) @This() {
            return .{};
        }
    };
    var entity = harness.new(Counter, .{});
    var observed: u32 = 0;
    const Observer = struct {
        fn call(value: *const Counter, raw: *anyopaque) void {
            const count: *u32 = @ptrCast(@alignCast(raw));
            count.* += value.value;
        }
    };
    var subscription = try harness.store.subscribe(Counter, entity.weak(), &observed, Observer.call);
    var cx = Context(Counter){ .store = &harness.store, .current = entity, .window = null };
    var self_subscription = try cx.subscribeSelf(&observed, Observer.call);
    self_subscription.cancel();
    const scope = harness.store.scope(null);
    try t.expect(scope.isValid());
    _ = entity.update(struct {
        fn update(value: *Counter) void {
            value.value = 3;
        }
    }.update);
    try t.expectEqual(@as(u32, 3), observed);
    try t.expect(subscription.isActive());
    scope.invalidate();
    try t.expect(!scope.isValid());
    subscription.cancel();
    try t.expect(!subscription.isActive());
}

test "element frames install the provider's engine" {
    // Regression: measure and paint must share one engine (or neither), so
    // the frame's `engine` is exactly what the provider returned. There is
    // no font-stack gate any more.
    const t = std.testing;
    const App = @import("app.zig").App;
    const text_engine = @import("../fonts/text_engine.zig");

    const TestView = struct {
        pub const Options = struct {};
        pub fn init(_: *Context(@This()), _: Options) @This() {
            return .{};
        }
        pub fn render(_: *@This(), _: *Window, _: *Context(@This())) elements.Element {
            return elements.div().w(10).h(10);
        }
    };

    var app = try App.initHeadless(t.allocator);
    defer app.deinit();

    var provider_calls: u32 = 0;
    var provided_engine: ?*text_engine.Engine = null;
    const Provider = struct {
        var calls: *u32 = undefined;
        var result: *?*text_engine.Engine = undefined;
        fn provide(_: *anyopaque) ?*text_engine.Engine {
            calls.* += 1;
            return result.*;
        }
    };
    Provider.calls = &provider_calls;
    Provider.result = &provided_engine;

    const win = try app.openWindow(.{}, struct {
        fn build(_: *Window, cx: *Context(TestView)) Entity(TestView) {
            return cx.new(TestView, .{});
        }
    }.build);
    win.cozmic_engine_fn = Provider.provide;
    win.cozmic_engine_ctx = &provider_calls;

    // Provider returns null: the frame has no engine and text would draw
    // nothing; the provider is still consulted once per frame.
    win.render();
    try t.expectEqual(@as(u32, 1), provider_calls);
    try t.expect(win.ui_frame.engine == null);

    // Provider returns an engine: the frame installs exactly that pointer.
    // Use a real corpus engine (the view has no text, so it is only touched
    // by the frame-level `beginFrame`).
    const engine = text_engine.Engine.init(t.allocator) catch |err| switch (err) {
        error.ShaperUnavailable, error.LibraryUnavailable, error.NoFontsAvailable, error.FontCorpusIncomplete => return error.SkipZigTest,
        else => return err,
    };
    defer engine.deinit();
    provided_engine = engine;
    win.render();
    try t.expectEqual(@as(u32, 2), provider_calls);
    try t.expect(win.ui_frame.engine == engine);

    // reset() clears per-frame installs but not the provider wiring.
    win.ui_frame.reset(win, .{});
    try t.expect(win.ui_frame.engine == null);
    provided_engine = null;
}

test "entity destroy retires the generation; weak handles fail" {
    const t = std.testing;
    const Counter = struct {
        pub const Options = struct {};
        n: u32 = 0,
        pub fn init(_: *Context(@This()), _: Options) @This() {
            return .{};
        }
    };

    var harness = try TestHarness.init(t.allocator);
    defer harness.deinit();
    try t.expectEqual(@as(usize, 0), harness.store.count());

    const entity = harness.new(Counter, .{});
    try t.expectEqual(@as(usize, 1), harness.store.count());
    try t.expect(entity.isAlive());
    const weak = entity.weak();
    try t.expect(weak.isAlive());

    // Same-type upgrade resolves while live.
    {
        const upgraded = weak.upgrade() orelse return error.TestExpectedUpgrade;
        try t.expectEqual(@as(u32, 0), upgraded.read().n);
    }
    // Wrong-type upgrade never resolves, even while live.
    const Other = struct {
        pub const Options = struct {};
        pub fn init(_: *Context(@This()), _: Options) @This() {
            return .{};
        }
    };
    try t.expect(!harness.store.isAlive(99999, weak.generation));
    const wrong: WeakEntity(Other) = .{ .store = weak.store, .id = weak.id, .generation = weak.generation };
    try t.expect(wrong.upgrade() == null);

    entity.destroy();
    try t.expectEqual(@as(usize, 0), harness.store.count());
    try t.expect(!weak.isAlive());
    try t.expect(weak.upgrade() == null);
    // Double destroy via the integer primitive is a safe no-op, not a
    // double free (no header pointer is touched).
    harness.store.destroyById(weak.id, weak.generation);
    try t.expectEqual(@as(usize, 0), harness.store.count());
}

test "mount and unmount repeatedly has bounded memory" {
    const t = std.testing;
    const Doc = struct {
        pub const Options = struct { n: u32 = 0 };
        n: u32 = 0,
        pub fn init(_: *Context(@This()), opts: Options) @This() {
            return .{ .n = opts.n };
        }
    };

    var harness = try TestHarness.init(t.allocator);
    defer harness.deinit();
    // Open/close 200 documents: each destroy must unlink AND free (the
    // testing allocator fails the test on any leak), so the live count is
    // back at zero and no tombstones accumulate.
    var i: u32 = 0;
    while (i < 200) : (i += 1) {
        const doc = harness.new(Doc, .{ .n = i });
        try t.expectEqual(@as(usize, 1), harness.store.count());
        try t.expectEqual(i, doc.read().n);
        doc.destroy();
    }
    try t.expectEqual(@as(usize, 0), harness.store.count());
}

test "window scope teardown releases the mounted tree (gap report §5.2)" {
    const t = std.testing;
    const App = @import("app.zig").App;
    var app = try App.initHeadless(t.allocator);
    defer app.deinit();
    const win = try app.openWindow(.{}, struct {
        fn noop(_: *Window, _: *@import("../gpu/root.zig").Scene) void {}
    }.noop);

    const Scoped = struct {
        pub const Options = struct {};
        n: u32 = 0,
        pub fn init(_: *Context(@This()), _: Options) @This() {
            return .{};
        }
    };
    const AppLifetime = struct {
        pub const Options = struct {};
        pub fn init(_: *Context(@This()), _: Options) @This() {
            return .{};
        }
    };
    // Window-attached entities (like mountView roots and widget children).
    const scoped_a = app.entities.create(Scoped, .{}, win);
    const scoped_b = app.entities.create(Scoped, .{}, win);
    // App-lifetime entity (created with window = null) must survive.
    const persistent = app.entities.create(AppLifetime, .{}, null);
    const before = app.entities.count();
    try t.expectEqual(@as(usize, 2 + 1), before);
    try t.expect(scoped_a.isAlive() and scoped_b.isAlive());
    // Strong handles read the header; after scope teardown only weak
    // handles may be consulted (the documented contract).
    const weak_a = scoped_a.weak();
    const weak_b = scoped_b.weak();
    const weak_persistent = persistent.weak();

    win.close();
    app.reapClosed();
    try t.expectEqual(@as(usize, 1), app.entities.count());
    try t.expect(!weak_a.isAlive());
    try t.expect(!weak_b.isAlive());
    try t.expect(weak_persistent.isAlive());
    app.entities.destroyById(weak_persistent.id, weak_persistent.generation);
    try t.expectEqual(@as(usize, 0), app.entities.count());
}

test "late completion cannot mutate a destroyed target" {
    const t = std.testing;
    const Counter = struct {
        pub const Options = struct {};
        n: u32 = 0,
        pub fn init(_: *Context(@This()), _: Options) @This() {
            return .{};
        }
    };

    var harness = try TestHarness.init(t.allocator);
    defer harness.deinit();
    const entity = harness.new(Counter, .{});
    const weak = entity.weak();
    // A worker completion holding only the weak handle resolves, mutates,
    // and notifies while the target lives.
    if (weak.upgrade()) |live| {
        live.update(struct {
            fn bump(v: *Counter) void {
                v.n += 1;
            }
        }.bump);
    } else return error.TestExpectedUpgrade;
    try t.expectEqual(@as(u32, 1), entity.read().n);

    entity.destroy();
    // The same late completion after destroy resolves to null: no mutation,
    // no invalidation, no use-after-free.
    harness.store.dirty = false;
    var completions_applied: u32 = 0;
    if (weak.upgrade()) |late| {
        late.update(struct {
            fn bump(v: *Counter) void {
                v.n += 1;
            }
        }.bump);
        completions_applied += 1;
    }
    try t.expectEqual(@as(u32, 0), completions_applied);
    try t.expect(!harness.store.dirty);
}

test "subscriptions die with their entity" {
    const t = std.testing;
    const App = @import("app.zig").App;
    const gpu = @import("../gpu/root.zig");
    const Counter = struct {
        pub const Options = struct {};
        n: u32 = 0,
        pub fn init(_: *Context(@This()), _: Options) @This() {
            return .{};
        }
    };

    var app = try App.initHeadless(t.allocator);
    defer app.deinit();
    const entity = app.entities.create(Counter, .{}, null);
    const weak = entity.weak();

    var fired: u32 = 0;
    const Probe = struct {
        var count: *u32 = undefined;
        fn onEvent(v: *Counter, _: *Context(Counter)) void {
            v.n += 1;
            count.* += 1;
        }
    };
    Probe.count = &fired;
    const focus = entity.focusHandle(null);
    try t.expect(focus.isLive());

    // A painted region carrying the entity's listener resolves its owner
    // through the frame table (mint-time registration, no target touched).
    const win = try app.openWindow(.{}, struct {
        fn noop(_: *Window, _: *gpu.Scene) void {}
    }.noop);
    const frame = &win.ui_frame;
    frame.reset(win, .{});
    elements.element.beginFrame(frame);
    const listener = entity.actionListener(Probe.onEvent);
    const root = elements.div().w(100).h(100).on_click(listener);
    elements.layout.layout(frame, root, .{ .w = 100, .h = 100 });
    const scene = try t.allocator.create(gpu.Scene);
    defer t.allocator.destroy(scene);
    scene.* = .{};
    elements.painter.paint(frame, root, scene);
    elements.element.endFrame();
    try t.expectEqual(@as(usize, 1), frame.region_count);
    const region = frame.regions[0];
    try t.expect(region.ownerAlive());

    // Pre-destroy, the region dispatches: a press inside fires once.
    win.handleEvent(.{ .mouse = .{ .pos = .{ .x = 10, .y = 10 }, .button = .left, .pressed = true } });
    try t.expectEqual(@as(u32, 1), fired);

    entity.destroy();
    try t.expect(!weak.isAlive());
    // Post-destroy the same region value is dead: the gate fails without
    // touching freed memory, and a press through the real dispatch path
    // never reaches the freed target.
    try t.expect(!region.ownerAlive());
    win.handleEvent(.{ .mouse = .{ .pos = .{ .x = 10, .y = 10 }, .button = .left, .pressed = true } });
    try t.expectEqual(@as(u32, 1), fired);
    // Focus dispatch fails the same way (inline guard, no target touched).
    var token: usize = 0;
    try t.expect(!focus.dispatch(.{ .window = .close_requested }, @ptrCast(&token)));
    try t.expect(!focus.isLive());
}

test "owned subscriptions tear down with the observing view" {
    const t = std.testing;
    const Model = struct {
        pub const Options = struct {};
        value: u32 = 0,
        pub fn init(_: *Context(@This()), _: Options) @This() {
            return .{};
        }
    };
    const Observer = struct {
        pub const Options = struct {};
        pub fn init(_: *Context(@This()), _: Options) @This() {
            return .{};
        }
    };
    var harness = try TestHarness.init(t.allocator);
    defer harness.deinit();
    const model = harness.new(Model, .{});
    const observer = harness.new(Observer, .{});
    var cx = Context(Observer){ .store = &harness.store, .current = observer, .window = null };
    var fired: u32 = 0;
    const Callback = struct {
        fn call(_: *const Model, raw: *anyopaque) void {
            const count: *u32 = @ptrCast(@alignCast(raw));
            count.* += 1;
        }
    };
    var subscription = try cx.subscribe(Model, model, &fired, Callback.call);
    try t.expect(subscription.isActive());
    observer.destroy();
    try t.expect(!subscription.isActive());
    _ = model.update(struct {
        fn update(value: *Model) void {
            value.value += 1;
        }
    }.update);
    try t.expectEqual(@as(u32, 0), fired);
}

test "entity reservations expose identity before insertion" {
    const t = std.testing;
    const Model = struct {
        pub const Options = struct { value: u32 = 0 };
        value: u32 = 0,
        pub fn init(_: *Context(@This()), options: Options) @This() {
            return .{ .value = options.value };
        }
    };
    var harness = try TestHarness.init(t.allocator);
    defer harness.deinit();
    var reservation = harness.store.reserveEntity(Model);
    const reserved_id = reservation.id();
    const reserved_generation = reservation.generation();
    try t.expect(reserved_id != 0 and reserved_generation != 0);
    try t.expect(!harness.store.isAlive(reserved_id, reserved_generation));
    const entity = try harness.store.insertEntity(Model, &reservation, .{ .value = 7 }, null);
    try t.expectEqual(reserved_id, entity.id());
    try t.expectEqual(reserved_generation, entity.generation());
    try t.expectEqual(@as(u32, 7), entity.read().value);
    try t.expect(harness.store.isAlive(reserved_id, reserved_generation));
    try t.expectError(error.InvalidReservation, reservation.insert(.{ .value = 8 }, null));
    entity.destroy();
}
