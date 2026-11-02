//! Port of GPUI `element.rs`: the `Element` protocol, `AnyElement`,
//! `IntoElement`, `ParentElement`, `Render`/`RenderOnce` and element ids.
//!
//! An element type `E` (usually used through a pointer `*E` allocated in the
//! frame arena) implements, by duck typing:
//!
//! ```zig
//! pub const RequestLayoutState = ...;
//! pub const PrepaintState = ...;
//! pub fn id(self: *E) ?ElementId
//! pub fn request_layout(self: *E, id: ?*const GlobalElementId, window: *Window, cx: *App) struct { LayoutId, RequestLayoutState }
//! pub fn prepaint(self: *E, id: ?*const GlobalElementId, bounds: Bounds(Pixels), rl: *RequestLayoutState, window: *Window, cx: *App) PrepaintState
//! pub fn paint(self: *E, id: ?*const GlobalElementId, bounds: Bounds(Pixels), rl: *RequestLayoutState, pp: *PrepaintState, window: *Window, cx: *App) void
//! ```
//!
//! A type is `IntoElement` if it is an element pointer, an `AnyElement`, a
//! string (rendered as text), an `Entity(V)` whose `V` has `render`, or has an
//! `into_element(self)` method.

const std = @import("std");
const geometry = @import("geometry.zig");
const taffy = @import("taffy.zig");
const window_mod = @import("window.zig");
const app_mod = @import("app.zig");

const Window = window_mod.Window;
const App = app_mod.App;
const Pixels = geometry.Pixels;
const Point = geometry.Point;
const Size = geometry.Size;
const Bounds = geometry.Bounds;
const LayoutId = taffy.LayoutId;
const AvailableSpace = taffy.AvailableSpace;

pub const SharedString = []const u8;

/// Identifies an element among its siblings, stable across frames.
pub const ElementId = union(enum) {
    view: u64,
    integer: u64,
    name: SharedString,
    named_integer: struct { name: SharedString, index: u64 },
    focus_handle: u64,
    path: SharedString,
    code_location: usize,

    /// Converts strings, integers, `.{ "name", index }` tuples and `ElementId`s.
    pub fn from(v: anytype) ElementId {
        const T = @TypeOf(v);
        if (T == ElementId) return v;
        switch (@typeInfo(T)) {
            .int, .comptime_int => return .{ .integer = @intCast(v) },
            .pointer => |p| {
                if (p.size == .slice and p.child == u8) return .{ .name = v };
                if (p.size == .one) switch (@typeInfo(p.child)) {
                    .array => |a| if (a.child == u8) return .{ .name = v },
                    else => {},
                };
            },
            .@"struct" => |s| if (s.is_tuple and s.field_names.len == 2) {
                return .{ .named_integer = .{ .name = v[0], .index = @intCast(v[1]) } };
            },
            else => {},
        }
        @compileError("cannot convert " ++ @typeName(T) ++ " into ElementId");
    }

    pub fn hash_into(self: ElementId, h: *std.hash.Wyhash) void {
        const tag: u8 = @intFromEnum(std.meta.activeTag(self));
        h.update(std.mem.asBytes(&tag));
        switch (self) {
            .view, .integer, .focus_handle => |x| h.update(std.mem.asBytes(&x)),
            .code_location => |x| h.update(std.mem.asBytes(&x)),
            .name, .path => |s| h.update(s),
            .named_integer => |ni| {
                h.update(ni.name);
                h.update(std.mem.asBytes(&ni.index));
            },
        }
    }

    pub fn eql(a: ElementId, b: ElementId) bool {
        if (std.meta.activeTag(a) != std.meta.activeTag(b)) return false;
        return switch (a) {
            .view => |x| x == b.view,
            .integer => |x| x == b.integer,
            .focus_handle => |x| x == b.focus_handle,
            .code_location => |x| x == b.code_location,
            .name => |s| std.mem.eql(u8, s, b.name),
            .path => |s| std.mem.eql(u8, s, b.path),
            .named_integer => |ni| ni.index == b.named_integer.index and std.mem.eql(u8, ni.name, b.named_integer.name),
        };
    }
};

/// The path of element ids from the window root, identified by its hash.
pub const GlobalElementId = struct {
    hash: u64,

    pub fn eql(a: GlobalElementId, b: GlobalElementId) bool {
        return a.hash == b.hash;
    }
};

pub fn extend_path_hash(prefix: u64, id: ElementId) u64 {
    var h = std.hash.Wyhash.init(prefix);
    id.hash_into(&h);
    return h.final();
}

// ---------------------------------------------------------------------------
// Type-erased elements.

const VTable = struct {
    request_layout: *const fn (*anyopaque, *Window, *App) LayoutId,
    prepaint: *const fn (*anyopaque, *Window, *App) void,
    paint: *const fn (*anyopaque, *Window, *App) void,
    inner: *const fn (*anyopaque) *anyopaque,
    type_name: []const u8,
};

const Phase = enum { start, request_layout, layout_computed, prepaint, painted };

/// The state machine wrapping an element through a frame (GPUI `Drawable`).
pub fn Drawable(comptime EPtr: type) type {
    const E = @typeInfo(EPtr).pointer.child;
    return struct {
        const Self = @This();
        element: EPtr,
        phase: Phase = .start,
        layout_id: LayoutId = undefined,
        global_id: ?GlobalElementId = null,
        bounds: Bounds(Pixels) = undefined,
        rl: E.RequestLayoutState = undefined,
        pp: E.PrepaintState = undefined,

        const vtable: VTable = .{
            .request_layout = requestLayoutErased,
            .prepaint = prepaintErased,
            .paint = paintErased,
            .inner = innerErased,
            .type_name = @typeName(E),
        };

        fn innerErased(p: *anyopaque) *anyopaque {
            const self: *Self = @ptrCast(@alignCast(p));
            return self.element;
        }

        fn elementId(self: *Self) ?ElementId {
            if (@hasDecl(E, "element_id")) return self.element.element_id();
            if (@hasDecl(E, "id") and @typeInfo(@TypeOf(E.id)) == .@"fn") {
                const F = @typeInfo(@TypeOf(E.id)).@"fn";
                if (F.param_types.len == 1) return self.element.id();
            }
            return null;
        }

        fn requestLayoutErased(p: *anyopaque, window: *Window, cx: *App) LayoutId {
            const self: *Self = @ptrCast(@alignCast(p));
            std.debug.assert(self.phase == .start);
            const eid = self.elementId();
            if (eid) |e| self.global_id = window.push_element_id(e);
            const gid_ptr: ?*const GlobalElementId = if (self.global_id) |*g| g else null;
            const res = self.element.request_layout(gid_ptr, window, cx);
            if (eid != null) window.pop_element_id();
            self.layout_id = res[0];
            self.rl = res[1];
            self.phase = .request_layout;
            return self.layout_id;
        }

        fn prepaintErased(p: *anyopaque, window: *Window, cx: *App) void {
            const self: *Self = @ptrCast(@alignCast(p));
            std.debug.assert(self.phase == .request_layout or self.phase == .layout_computed);
            const eid = self.elementId();
            if (eid) |e| _ = window.push_element_id(e);
            self.bounds = window.layout_bounds(self.layout_id);
            window.next_frame.dispatch_tree.push_node();
            const gid_ptr: ?*const GlobalElementId = if (self.global_id) |*g| g else null;
            self.pp = self.element.prepaint(gid_ptr, self.bounds, &self.rl, window, cx);
            window.next_frame.dispatch_tree.pop_node();
            if (eid != null) window.pop_element_id();
            self.phase = .prepaint;
        }

        fn paintErased(p: *anyopaque, window: *Window, cx: *App) void {
            const self: *Self = @ptrCast(@alignCast(p));
            std.debug.assert(self.phase == .prepaint);
            const eid = self.elementId();
            if (eid) |e| _ = window.push_element_id(e);
            const gid_ptr: ?*const GlobalElementId = if (self.global_id) |*g| g else null;
            self.element.paint(gid_ptr, self.bounds, &self.rl, &self.pp, window, cx);
            if (eid != null) window.pop_element_id();
            self.phase = .painted;
        }
    };
}

/// A type-erased element (GPUI `AnyElement`), allocated in the frame arena.
pub const AnyElement = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    /// Wraps an element pointer.
    pub fn new(element: anytype) AnyElement {
        const D = Drawable(@TypeOf(element));
        const d = window_mod.frame_arena().create(D) catch @panic("OOM");
        d.* = .{ .element = element };
        return .{ .ptr = d, .vtable = &D.vtable };
    }

    pub fn request_layout(self: AnyElement, window: *Window, cx: *App) LayoutId {
        return self.vtable.request_layout(self.ptr, window, cx);
    }

    pub fn prepaint(self: AnyElement, window: *Window, cx: *App) void {
        self.vtable.prepaint(self.ptr, window, cx);
    }

    pub fn paint(self: AnyElement, window: *Window, cx: *App) void {
        self.vtable.paint(self.ptr, window, cx);
    }

    /// The element's type name, for debugging.
    pub fn type_name(self: AnyElement) []const u8 {
        return self.vtable.type_name;
    }

    /// Downcasts to the concrete element pointer, if it is of type `EPtr`.
    pub fn downcast(self: AnyElement, comptime EPtr: type) ?EPtr {
        if (self.vtable != &Drawable(EPtr).vtable) return null;
        return @ptrCast(@alignCast(self.vtable.inner(self.ptr)));
    }

    /// Lays out this element as a root with the given available space.
    pub fn layout_as_root(self: AnyElement, available_space: Size(AvailableSpace), window: *Window, cx: *App) Size(Pixels) {
        const id = self.request_layout(window, cx);
        window.compute_layout(id, available_space, cx);
        return window.layout_bounds(id).size;
    }

    /// Lays out and prepaints this element at `origin` (GPUI `prepaint_as_root`).
    pub fn prepaint_as_root(self: AnyElement, origin: Point(Pixels), available_space: Size(AvailableSpace), window: *Window, cx: *App) void {
        _ = self.layout_as_root(available_space, window, cx);
        window.with_absolute_element_offset(origin, self, struct {
            fn f(el: AnyElement, w: *Window, c: *App) void {
                el.prepaint(w, c);
            }
        }.f, cx);
    }

    /// Prepaints at `origin` an element whose layout was already computed.
    pub fn prepaint_at(self: AnyElement, origin: Point(Pixels), window: *Window, cx: *App) void {
        window.with_absolute_element_offset(origin, self, struct {
            fn f(el: AnyElement, w: *Window, c: *App) void {
                el.prepaint(w, c);
            }
        }.f, cx);
    }

    /// Request layout, compute, prepaint and paint in one go.
    pub fn draw(self: AnyElement, origin: Point(Pixels), available_space: Size(AvailableSpace), window: *Window, cx: *App) void {
        self.prepaint_as_root(origin, available_space, window, cx);
        self.paint(window, cx);
    }

    pub fn into_any_element(self: AnyElement) AnyElement {
        return self;
    }
};

/// Converts any IntoElement value into an `AnyElement` (GPUI `into_any_element`).
pub fn into_any_element(value: anytype) AnyElement {
    const T = @TypeOf(value);
    if (T == AnyElement) return value;
    switch (@typeInfo(T)) {
        .pointer => |p| {
            if (p.size == .slice and p.child == u8) return @import("elements/text.zig").text_element(value);
            if (p.size == .one) {
                switch (@typeInfo(p.child)) {
                    .array => |a| if (a.child == u8) return @import("elements/text.zig").text_element(value),
                    .@"struct", .@"union", .@"enum", .@"opaque" => {
                        if (@hasDecl(p.child, "into_element") and !@hasDecl(p.child, "request_layout")) return into_any_element(value.into_element());
                        return AnyElement.new(value);
                    },
                    else => {},
                }
            }
        },
        .optional => {
            if (value) |v| return into_any_element(v);
            return @import("elements/empty.zig").empty();
        },
        .@"struct", .@"union" => {
            if (@hasDecl(T, "into_any_element")) return value.into_any_element();
            if (@hasDecl(T, "into_element")) return into_any_element(value.into_element());
            // A bare element value (GPUI `impl Element` is also `IntoElement`).
            if (@hasDecl(T, "request_layout")) return AnyElement.new(value);
        },
        else => {},
    }
    @compileError("type " ++ @typeName(T) ++ " is not IntoElement");
}

/// Shared children storage for `ParentElement` implementors.
pub const Children = std.ArrayList(AnyElement);

/// `ParentElement` mixin: `Self` must have `children: Children`-typed field via `children_mut()`.
pub fn ParentElement(comptime Self: type) type {
    return struct {
        /// Adds a child.
        pub fn child(self: Self, c: anytype) Self {
            self.children_mut().append(window_mod.frame_arena(), into_any_element(c)) catch @panic("OOM");
            return self;
        }
        /// Adds several children (a slice, array, or tuple of IntoElement values).
        pub fn children(self: Self, cs: anytype) Self {
            const T = @TypeOf(cs);
            switch (@typeInfo(T)) {
                .@"struct" => |s| if (s.is_tuple) {
                    inline for (0..s.field_names.len) |i| _ = child(self, cs[i]);
                    return self;
                },
                else => {},
            }
            for (cs) |c| _ = child(self, c);
            return self;
        }
        /// Appends already-erased elements.
        pub fn extend(self: Self, elements: []const AnyElement) void {
            self.children_mut().appendSlice(window_mod.frame_arena(), elements) catch @panic("OOM");
        }
    };
}

/// GPUI `FluentBuilder`: conditional builder helpers. `f` is `fn(Self) Self`.
pub fn FluentBuilder(comptime Self: type) type {
    return struct {
        /// Applies `f` to self (GPUI `map`).
        pub fn map(self: Self, f: anytype) Self {
            return f(self);
        }
        /// Applies `then` when `condition` holds.
        pub fn when(self: Self, condition: bool, then: anytype) Self {
            return if (condition) then(self) else self;
        }
        /// Applies `then` or `otherwise` depending on `condition`.
        pub fn when_else(self: Self, condition: bool, then: anytype, otherwise: anytype) Self {
            return if (condition) then(self) else otherwise(self);
        }
        /// Applies `then(self, value)` when `option` is non-null.
        pub fn when_some(self: Self, option: anytype, then: anytype) Self {
            return if (option) |v| then(self, v) else self;
        }
        /// Applies `then` when `option` is null.
        pub fn when_none(self: Self, option: anytype, then: anytype) Self {
            return if (option == null) then(self) else self;
        }
    };
}
