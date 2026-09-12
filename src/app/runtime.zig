const std = @import("std");
const platform = @import("../platform/root.zig");
const elements = @import("../elements/root.zig");
const Window = @import("window.zig").Window;

pub const FocusHandle = elements.FocusHandle;
pub const Listener = elements.Listener;

const EntityHeader = struct {
    store: *EntityStore,
    id: u32,
    value_ptr: *anyopaque,
    next: ?*EntityHeader = null,
    destroy_fn: *const fn (*EntityHeader) void,
};

pub const EntityStore = struct {
    allocator: std.mem.Allocator,
    head: ?*EntityHeader = null,
    next_id: u32 = 1,
    dirty: bool = false,

    pub fn init(allocator: std.mem.Allocator) EntityStore {
        return .{ .allocator = allocator };
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
        const Box = struct {
            header: EntityHeader,
            value: T,
        };
        const box = self.allocator.create(Box) catch @panic("out of memory creating ZUI entity");
        box.header = .{
            .store = self,
            .id = self.next_id,
            .value_ptr = &box.value,
            .next = self.head,
            .destroy_fn = struct {
                fn destroy(raw: *EntityHeader) void {
                    const typed: *Box = @fieldParentPtr("header", raw);
                    if (@hasDecl(T, "deinit")) typed.value.deinit();
                    typed.header.store.allocator.destroy(typed);
                }
            }.destroy,
        };
        self.next_id += 1;
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

pub fn Entity(comptime T: type) type {
    return struct {
        pub const Value = T;
        pub const is_entity = true;

        header: *EntityHeader,
        value: *T,

        pub fn read(self: @This()) *const T {
            return self.value;
        }

        pub fn readMut(self: @This()) *T {
            return self.value;
        }

        pub fn update(self: @This(), comptime callback: anytype) CallbackReturn(callback) {
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
    return .{
        .id = entity.header.id,
        .target = entity.header,
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
                elements.layout.layout(&win.ui_frame, root_element, .{ .x = 0, .y = 0, .w = win.bounds.size.w, .h = win.bounds.size.h });
                elements.painter.paint(&win.ui_frame, root_element, scene);
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
