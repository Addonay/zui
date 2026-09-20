//! Public typed element composition contracts.
//!
//! This is the ZUI equivalent of GPUI's `IntoElement`, `Render`, and
//! `RenderOnce` contracts.  It intentionally sits above the frame builder:
//! consumers provide ordinary Zig types with public `render` or `renderOnce`
//! methods and receive an ordinary `element.Element` handle.
//!
//! The retained store is keyed by `(type, key)`, which is the important part
//! of GPUI's global-element-id behavior: state follows a keyed element across
//! rebuilt frames and is destroyed when the key disappears from the scope.
//!
//! Source references:
//! - `.references/gpui/crates/gpui/src/element.rs` (`Element`, `IntoElement`,
//!   `Render`, `RenderOnce`)
//! - `.references/gpui/crates/gpui/src/elements/deferred.rs`
//! - `.references/gpui/crates/gpui/src/elements/container_query.rs`
//! - `.references/gpui/crates/gpui/src/elements/surface.rs`

const std = @import("std");
const element = @import("element.zig");
const deferred = @import("deferred.zig");
const container_query = @import("container_query.zig");
const surface = @import("surface.zig");
const core = @import("../core/root.zig");

pub const Element = element.Element;
pub const Frame = element.Frame;

pub const max_retained_slots = 128;
pub const max_teardowns = 64;

pub const Phase = enum { render, deferred, container_query, surface, teardown };

pub const Teardown = struct {
    target: *anyopaque,
    call: *const fn (*anyopaque) void,
};

/// Per-render public context passed to typed views/components.
pub const Context = struct {
    frame: *Frame,
    retained: *RetainedStore,
    deferred_queue: ?*deferred.Queue,
    teardowns: [max_teardowns]Teardown = undefined,
    teardown_count: usize = 0,
    epoch: u64,
    phase: Phase = .render,

    pub fn key(self: *const Context, value: u64) u64 {
        _ = self;
        if (value == 0) @panic("ZUI typed element keys must be nonzero");
        return value;
    }

    /// GPUI-style keyed state hook. The initializer is called exactly once
    /// for a `(T, key)` pair until that key leaves the scope.
    pub fn useKeyed(self: *Context, comptime T: type, key_value: u64, init: fn () T) *T {
        return self.retained.get(T, self.key(key_value), init, self.epoch);
    }

    /// Register an app-owned teardown callback for this composition scope.
    /// Registration is bounded and callbacks run once, in reverse order.
    pub fn onTeardown(self: *Context, target: *anyopaque, call: *const fn (*anyopaque) void) void {
        if (self.teardown_count >= self.teardowns.len) @panic("ZUI typed teardown limit exceeded");
        self.teardowns[self.teardown_count] = .{ .target = target, .call = call };
        self.teardown_count += 1;
    }

    pub fn deferElement(self: *Context, child: Element, priority: usize) bool {
        self.phase = .deferred;
        const queue = self.deferred_queue orelse return false;
        return queue.enqueue(child, priority);
    }

    pub fn query(self: *Context, size: core.Size, render: *const fn (core.Size) void) core.Size {
        self.phase = .container_query;
        return (container_query.Query{ .render = render }).materialize(size);
    }

    /// Register a surface for scope teardown. The surface remains app-owned;
    /// the scope only invokes its release hook.
    pub fn retainSurface(self: *Context, value: *surface.Surface) void {
        self.phase = .surface;
        self.onTeardown(value, releaseSurface);
    }

    fn releaseSurface(target: *anyopaque) void {
        const value: *surface.Surface = @ptrCast(@alignCast(target));
        value.release();
    }
};

const Slot = struct {
    type_tag: u64 = 0,
    key: u64 = 0,
    value: ?*anyopaque = null,
    destroy: ?*const fn (std.mem.Allocator, *anyopaque) void = null,
    last_epoch: u64 = 0,
};

/// Bounded retained state for typed elements. It is deliberately caller-owned
/// so it can be attached to an entity/view and survive frame rebuilds.
pub const RetainedStore = struct {
    allocator: std.mem.Allocator,
    slots: [max_retained_slots]Slot = undefined,
    len: usize = 0,
    destroyed: u64 = 0,

    pub fn init(allocator: std.mem.Allocator) RetainedStore {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *RetainedStore) void {
        while (self.len != 0) self.destroySlot(0);
    }

    pub fn get(self: *RetainedStore, comptime T: type, key: u64, initializer: fn () T, epoch: u64) *T {
        const tag = typeTag(T);
        for (self.slots[0..self.len]) |*slot| {
            if (slot.type_tag == tag and slot.key == key) {
                slot.last_epoch = epoch;
                return @ptrCast(@alignCast(slot.value.?));
            }
        }
        if (self.len == self.slots.len) @panic("ZUI retained state limit exceeded");
        const value = self.allocator.create(T) catch @panic("ZUI retained state allocation failed");
        value.* = initializer();
        self.slots[self.len] = .{
            .type_tag = tag,
            .key = key,
            .value = value,
            .destroy = destroyValue(T),
            .last_epoch = epoch,
        };
        self.len += 1;
        return value;
    }

    /// Drop states not touched by the completed render epoch.
    pub fn finish(self: *RetainedStore, epoch: u64) void {
        var i: usize = 0;
        while (i < self.len) {
            if (self.slots[i].last_epoch != epoch) self.destroySlot(i) else i += 1;
        }
    }

    fn destroySlot(self: *RetainedStore, index: usize) void {
        const slot = self.slots[index];
        if (slot.destroy) |destroy| destroy(self.allocator, slot.value.?);
        self.destroyed += 1;
        self.slots[index] = self.slots[self.len - 1];
        self.len -= 1;
    }

    fn typeTag(comptime T: type) u64 {
        return std.hash.Wyhash.hash(0, @typeName(T));
    }

    fn destroyValue(comptime T: type) *const fn (std.mem.Allocator, *anyopaque) void {
        return struct {
            fn destroy(allocator: std.mem.Allocator, value: *anyopaque) void {
                allocator.destroy(@as(*T, @ptrCast(@alignCast(value))));
            }
        }.destroy;
    }
};

pub const Scope = struct {
    context: Context,
    completed: bool = false,

    pub fn begin(frame: *Frame, retained: *RetainedStore, epoch: u64) Scope {
        element.beginFrame(frame);
        return .{
            .context = .{
                .frame = frame,
                .retained = retained,
                .deferred_queue = null,
                .epoch = epoch,
            },
        };
    }

    pub fn beginWithQueue(frame: *Frame, retained: *RetainedStore, queue: *deferred.Queue, epoch: u64) Scope {
        element.beginFrame(frame);
        return .{ .context = .{ .frame = frame, .retained = retained, .deferred_queue = queue, .epoch = epoch } };
    }

    pub fn render(self: *Scope, value: anytype) Element {
        return renderView(value, &self.context);
    }

    pub fn renderOnce(self: *Scope, value: anytype) Element {
        return renderOnceView(value, &self.context);
    }

    /// GPUI `View`-style entry point: dispatches borrowed stateful views and
    /// owned render-once components through one public composition method.
    pub fn view(self: *Scope, value: anytype) Element {
        return viewElement(value, &self.context);
    }

    pub fn end(self: *Scope) void {
        if (self.completed) return;
        var i = self.context.teardown_count;
        while (i > 0) {
            i -= 1;
            self.context.teardowns[i].call(self.context.teardowns[i].target);
        }
        self.context.retained.finish(self.context.epoch);
        element.endFrame();
        self.completed = true;
    }
};

/// Adapt a GPUI-shaped `Render` type: `fn render(*T, *Context) Element`.
pub fn renderView(view: anytype, context: *Context) Element {
    const T = @TypeOf(view.*);
    if (!@hasDecl(T, "render")) @compileError("typed view must provide render(self, *composition.Context) Element");
    return normalize(view.render(context));
}

/// Adapt a GPUI-shaped `RenderOnce` type: `fn renderOnce(T, *Context) Element`.
pub fn renderOnceView(view: anytype, context: *Context) Element {
    const T = @TypeOf(view);
    if (!@hasDecl(T, "renderOnce")) @compileError("render-once component must provide renderOnce(self, *composition.Context) Element");
    return normalize(view.renderOnce(context));
}

/// The View contract is the union GPUI exposes to callers: a borrowed value
/// with `render`, or an owned value with `renderOnce`.
pub fn viewElement(value: anytype, context: *Context) Element {
    const T = @TypeOf(value);
    if (@typeInfo(T) == .pointer and @hasDecl(@TypeOf(value.*), "render")) return renderView(value, context);
    if (@hasDecl(T, "renderOnce")) return renderOnceView(value, context);
    return intoElement(value, context);
}

/// Public IntoElement adapter. Existing elements pass through; typed values
/// may expose `intoElement`, `renderOnce`, or `render` in that order.
pub fn intoElement(value: anytype, context: *Context) Element {
    const T = @TypeOf(value);
    if (T == Element) return value;
    if (@hasDecl(T, "intoElement")) return normalize(value.intoElement(context));
    if (@hasDecl(T, "renderOnce")) return renderOnceView(value, context);
    if (@typeInfo(T) == .pointer and @hasDecl(@TypeOf(value.*), "render")) return renderView(value, context);
    @compileError("value does not implement the public IntoElement contract");
}

fn normalize(value: anytype) Element {
    const T = @TypeOf(value);
    if (T == Element) return value;
    @compileError("typed composition methods must return elements.Element");
}

test "typed render, render-once, keyed state, and teardown are public contracts" {
    const Test = struct {
        const State = struct { count: u32 = 0 };
        fn makeState() State {
            return .{};
        }
        var teardown_calls: u32 = 0;
        fn teardown(_: *anyopaque) void {
            teardown_calls += 1;
        }
        const View = struct {
            pub fn render(self: *@This(), ctx: *Context) Element {
                _ = self;
                const state = ctx.useKeyed(State, 7, makeState);
                state.count += 1;
                ctx.onTeardown(@ptrCast(&state.count), teardown);
                return element.div().keyed(ctx.key(7));
            }
        };
        const Once = struct {
            pub fn renderOnce(_: @This(), _: *Context) Element {
                return element.div().keyed(8);
            }
        };
    };
    Test.teardown_calls = 0;
    var frame = try std.testing.allocator.create(Frame);
    defer std.testing.allocator.destroy(frame);
    frame.* = .{};
    frame.reset(undefined, .{});
    var retained = RetainedStore.init(std.testing.allocator);
    defer retained.deinit();
    var scope = Scope.begin(frame, &retained, 1);
    var view = Test.View{};
    _ = scope.render(&view);
    _ = scope.renderOnce(Test.Once{});
    scope.end();
    try std.testing.expectEqual(@as(usize, 1), retained.len);
    try std.testing.expectEqual(@as(u32, 1), retained.slots[0].last_epoch);
    try std.testing.expectEqual(@as(u32, 1), Test.teardown_calls);
    frame.reset(undefined, .{});
    var next = Scope.begin(frame, &retained, 2);
    var second = Test.View{};
    _ = next.render(&second);
    next.end();
    try std.testing.expectEqual(@as(u32, 2), retained.get(Test.State, 7, Test.makeState, 2).count);
    frame.reset(undefined, .{});
    var dropped = Scope.begin(frame, &retained, 3);
    dropped.end();
    try std.testing.expectEqual(@as(usize, 0), retained.len);
    try std.testing.expectEqual(@as(u64, 1), retained.destroyed);
}

test "typed lifecycle covers deferred, query, and surface teardown" {
    var frame = try std.testing.allocator.create(Frame);
    defer std.testing.allocator.destroy(frame);
    frame.* = .{};
    frame.reset(undefined, .{});
    var retained = RetainedStore.init(std.testing.allocator);
    defer retained.deinit();
    var queue = deferred.Queue{};
    var scope = Scope.beginWithQueue(frame, &retained, &queue, 1);
    const child = element.div();
    try std.testing.expect(scope.context.deferElement(child, 4));
    const size = scope.context.query(core.size(80, 40), noopQuery);
    try std.testing.expectEqual(core.size(80, 40), size);
    var displayed = surface.surface(.{ .id = 1, .size = core.size(20, 20) });
    scope.context.retainSurface(&displayed);
    scope.end();
    try std.testing.expect(displayed.released);
}

fn noopQuery(_: core.Size) void {}
