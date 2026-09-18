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

fn typeTag(comptime T: type) u64 {
    return std.hash.Wyhash.hash(0, @typeName(T));
}

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

    pub fn init(allocator: std.mem.Allocator) EntityStore {
        // Wire the single subscription-liveness probe the element layer
        // consults (idempotent: every store wires the same function).
        elements.element.entity_is_alive_fn = entityAlive;
        return .{ .allocator = allocator, .owner_thread = std.Thread.getCurrentId() };
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
    }

    pub fn create(self: *EntityStore, comptime T: type, options: T.Options, window: ?*Window) Entity(T) {
        self.assertUiThread();
        const Box = struct {
            header: EntityHeader,
            value: T,
        };
        const box = self.allocator.create(Box) catch @panic("out of memory creating ZUI entity");
        box.header = .{
            .store = self,
            .id = self.next_id,
            .generation = self.next_generation,
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
        self.next_id += 1;
        self.next_generation +%= 1;
        if (self.next_generation == 0) self.next_generation = 1;
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

        pub fn new(self: *@This(), comptime U: type, options: U.Options) Entity(U) {
            return self.store.create(U, options, self.window);
        }

        pub fn focusHandle(self: *@This()) FocusHandle {
            return makeFocus(T, self.current.?);
        }

        pub fn notify(self: *@This()) void {
            self.store.dirty = true;
            if (self.window) |window| window.requestRender();
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
