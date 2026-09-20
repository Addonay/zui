//! Typed view handles and the small type-erased view boundary.
//!
//! The shape follows GPUI's `view.rs`: an entity is the identity, rendering
//! is a typed function, and weak views can be retained without keeping the
//! entity alive. ZUI keeps the representation explicit so stale upgrades are
//! cheap and deterministic.

const runtime = @import("runtime.zig");
const Window = @import("window.zig").Window;
const elements = @import("../elements/root.zig");

pub fn ViewHandle(comptime T: type) type {
    return struct {
        entity: runtime.Entity(T),

        pub fn init(entity: runtime.Entity(T)) @This() {
            return .{ .entity = entity };
        }

        pub fn id(self: @This()) u32 {
            return self.entity.id();
        }

        pub fn weak(self: @This()) WeakView(T) {
            return .{ .weak = self.entity.weak() };
        }

        pub fn any(self: @This()) AnyView {
            return AnyView.from(self.entity);
        }

        pub fn mount(self: @This(), window: *Window) void {
            runtime.mountEntity(self.entity.header.store, window, self.entity);
        }
    };
}

pub fn WeakView(comptime T: type) type {
    return struct {
        weak: runtime.WeakEntity(T),

        pub fn upgrade(self: @This()) ?ViewHandle(T) {
            const entity = self.weak.upgrade() orelse return null;
            return ViewHandle(T).init(entity);
        }

        pub fn isAlive(self: @This()) bool {
            return self.weak.isAlive();
        }
    };
}

pub const AnyView = struct {
    store: *runtime.EntityStore,
    id_value: u32,
    generation_value: u32,
    type_tag: u64,
    render_fn: *const fn (*const AnyView, *Window) elements.Element,

    pub fn from(entity: anytype) AnyView {
        const T = @TypeOf(entity).Value;
        return .{
            .store = entity.header.store,
            .id_value = entity.id(),
            .generation_value = entity.generation(),
            .type_tag = runtime.typeTag(T),
            .render_fn = struct {
                fn render(view: *const AnyView, window: *Window) elements.Element {
                    const target = runtime.WeakEntity(T){
                        .store = view.store,
                        .id = view.id_value,
                        .generation = view.generation_value,
                    };
                    var entity_value = target.upgrade() orelse return elements.div();
                    var cx = runtime.Context(T){ .store = view.store, .current = entity_value, .window = window };
                    return entity_value.value.render(window, &cx);
                }
            }.render,
        };
    }

    pub fn id(self: @This()) u32 {
        return self.id_value;
    }

    pub fn isAlive(self: @This()) bool {
        return self.store.isAlive(self.id_value, self.generation_value);
    }

    pub fn render(self: *const @This(), window: *Window) elements.Element {
        return self.render_fn(self, window);
    }

    pub fn downcast(self: @This(), comptime T: type) ?runtime.Entity(T) {
        if (self.type_tag != runtime.typeTag(T)) return null;
        const target = runtime.WeakEntity(T){ .store = self.store, .id = self.id_value, .generation = self.generation_value };
        return target.upgrade();
    }

    pub fn weak(self: @This()) AnyWeakView {
        return .{ .store = self.store, .id_value = self.id_value, .generation_value = self.generation_value, .type_tag = self.type_tag, .render_fn = self.render_fn };
    }
};

pub const AnyWeakView = struct {
    store: *runtime.EntityStore,
    id_value: u32,
    generation_value: u32,
    type_tag: u64,
    render_fn: *const fn (*const AnyView, *Window) elements.Element,

    pub fn upgrade(self: @This()) ?AnyView {
        if (!self.store.isAlive(self.id_value, self.generation_value)) return null;
        return .{ .store = self.store, .id_value = self.id_value, .generation_value = self.generation_value, .type_tag = self.type_tag, .render_fn = self.render_fn };
    }
};

test "typed and erased views share generation-safe identity" {
    const t = @import("std").testing;
    const TestView = struct {
        pub const Options = struct {};
        pub fn init(_: *runtime.Context(@This()), _: Options) @This() {
            return .{};
        }
        pub fn render(_: *@This(), _: *Window, _: *runtime.Context(@This())) elements.Element {
            return elements.div();
        }
    };
    var harness = try runtime.TestHarness.init(t.allocator);
    defer harness.deinit();
    const entity = harness.new(TestView, .{});
    const typed = ViewHandle(TestView).init(entity);
    const erased = typed.any();
    try t.expectEqual(entity.id(), erased.id());
    try t.expect(erased.downcast(TestView) != null);
    const weak = erased.weak();
    entity.destroy();
    try t.expect(weak.upgrade() == null);
    try t.expect(!erased.isAlive());
}
