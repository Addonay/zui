//! Actions: named, type-erased commands dispatched through the element tree and keymap
//! (GPUI action.rs).
//!
//! GPUI's `actions!(ns, [A, B])` becomes `pub const A = zui.Action("ns", "A");`. Each call returns a
//! unique zero-sized type with `action_name` ("ns::A"). Actions with data are plain structs; the
//! type name is used when no `action_name` declaration is present.

const std = @import("std");
const Allocator = std.mem.Allocator;
const app_mod = @import("app.zig");
const TypeId = app_mod.TypeId;
const App = app_mod.App;

/// A type-erased action: a boxed copy of the value plus its type and name.
pub const AnyAction = struct {
    type_id: TypeId,
    ptr: *const anyopaque,
    name: []const u8,

    /// Returns the action as `T`. Asserts that the action has type `T`.
    pub fn cast(self: AnyAction, comptime T: type) *const T {
        std.debug.assert(self.type_id == type_id_of(T));
        return @ptrCast(@alignCast(self.ptr));
    }

    /// Whether this action has type `T`.
    pub fn is(self: AnyAction, comptime T: type) bool {
        return self.type_id == type_id_of(T);
    }
};

fn type_id_of(comptime T: type) TypeId {
    return app_mod.type_id(T);
}

fn oom() noreturn {
    @panic("out of memory");
}

/// Copies `action` into `allocator` and returns it type-erased.
pub fn box_action(allocator: Allocator, action: anytype) AnyAction {
    const T = @TypeOf(action);
    const boxed = allocator.create(T) catch oom();
    boxed.* = action;
    return .{ .type_id = type_id_of(T), .ptr = boxed, .name = action_name(T) };
}

/// Calls `f` with the action pointer cast to `*const A` when the action type matches.
pub const GlobalActionListener = struct {
    action_type: TypeId,
    func: *const fn (*const anyopaque, *App) void,
};

/// Declares a unit action named `namespace::name`, like one entry of GPUI's `actions!` macro.
pub fn Action(comptime namespace: []const u8, comptime name: []const u8) type {
    return struct {
        pub const action_name: []const u8 = namespace ++ "::" ++ name;

        /// The action's name, for display.
        pub fn name(_: *const @This()) []const u8 {
            return action_name;
        }

        /// The action's name, without an instance.
        pub fn name_for_type() []const u8 {
            return action_name;
        }
    };
}

/// The name used for `T` in keymaps: `T.action_name` if declared, else the Zig type name.
pub fn action_name(comptime T: type) []const u8 {
    if (@hasDecl(T, "action_name")) return T.action_name;
    return @typeName(T);
}

/// Disables a binding in keymaps: `KeyBinding.new("ctrl-a", NoAction{}, ctx)` removes the
/// lower-precedence matches for that keystroke in the context.
pub const NoAction = Action("zed", "NoAction");

/// Whether `action` is `NoAction`.
pub fn is_no_action(action: AnyAction) bool {
    return action.is(NoAction);
}

pub const ActionBuildError = error{ActionNotFound};

/// Maps action names to constructors, so actions can be built from a name (GPUI's
/// ActionRegistry). Types must be default-constructible (`T{}`). Registration is explicit: Zig has
/// no link-time registry, so call `register` for each action at startup.
pub const ActionRegistry = struct {
    gpa: Allocator,
    by_name: std.StringHashMapUnmanaged(Entry) = .empty,
    names_by_type: std.AutoHashMapUnmanaged(TypeId, []const u8) = .empty,
    all_names: std.ArrayList([]const u8) = .empty,

    const Entry = struct {
        type_id: TypeId,
        build: *const fn (Allocator) AnyAction,
    };

    pub fn init(gpa: Allocator) ActionRegistry {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *ActionRegistry) void {
        self.by_name.deinit(self.gpa);
        self.names_by_type.deinit(self.gpa);
        self.all_names.deinit(self.gpa);
    }

    /// Registers `T` under its action name. Panics if the name is already registered.
    pub fn register(self: *ActionRegistry, comptime T: type) !void {
        const name = action_name(T);
        if (self.by_name.contains(name)) {
            std.debug.panic("Action with name `{s}` already registered", .{name});
        }
        const S = struct {
            fn build(allocator: Allocator) AnyAction {
                return box_action(allocator, T{});
            }
        };
        try self.by_name.put(self.gpa, name, .{ .type_id = type_id_of(T), .build = S.build });
        try self.names_by_type.put(self.gpa, type_id_of(T), name);
        try self.all_names.append(self.gpa, name);
    }

    /// Builds the action registered under `name`.
    pub fn build_action(self: *const ActionRegistry, name: []const u8, allocator: Allocator) ActionBuildError!AnyAction {
        const entry = self.by_name.get(name) orelse return error.ActionNotFound;
        return entry.build(allocator);
    }

    /// Builds the action registered for `tid`.
    pub fn build_action_type(self: *const ActionRegistry, tid: TypeId, allocator: Allocator) ActionBuildError!AnyAction {
        const name = self.names_by_type.get(tid) orelse return error.ActionNotFound;
        return self.build_action(name, allocator);
    }

    /// All registered action names, in registration order.
    pub fn all_action_names(self: *const ActionRegistry) []const []const u8 {
        return self.all_names.items;
    }
};

// ---------------------------------------------------------------------------
// Tests

const testing = std.testing;

const MoveUp = Action("editor", "MoveUp");
const MoveDown = Action("editor", "MoveDown");
const Plain = struct {};

test "Action names and type identity" {
    try testing.expectEqualStrings("editor::MoveUp", MoveUp.action_name);
    try testing.expectEqualStrings("editor::MoveUp", action_name(MoveUp));
    try testing.expectEqualStrings("editor::MoveUp", (MoveUp{}).name());
    try testing.expectEqualStrings("editor::MoveUp", MoveUp.name_for_type());
    // Same arguments give the same type; different names give different types.
    try testing.expect(MoveUp == Action("editor", "MoveUp"));
    try testing.expect(MoveUp != MoveDown);
    // Without a declaration the Zig type name is used.
    try testing.expectEqualStrings(@typeName(Plain), action_name(Plain));
}

test "box_action copies the value" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const Data = struct { amount: u32, tag: []const u8 };
    const original = Data{ .amount = 7, .tag = "x" };
    const any = box_action(arena.allocator(), original);
    try testing.expect(any.is(Data));
    try testing.expectEqual(@as(u32, 7), any.cast(Data).amount);
    try testing.expectEqualStrings(@typeName(Data), any.name);
    const unit = box_action(arena.allocator(), MoveUp{});
    try testing.expect(unit.is(MoveUp));
    try testing.expect(!unit.is(MoveDown));
    try testing.expectEqualStrings("editor::MoveUp", unit.name);
}

test "NoAction detection" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try testing.expect(is_no_action(box_action(arena.allocator(), NoAction{})));
    try testing.expect(!is_no_action(box_action(arena.allocator(), MoveUp{})));
}

test "ActionRegistry builds actions by name and type" {
    var registry = ActionRegistry.init(testing.allocator);
    defer registry.deinit();
    try registry.register(MoveUp);
    try registry.register(MoveDown);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const built = try registry.build_action("editor::MoveDown", arena.allocator());
    try testing.expect(built.is(MoveDown));
    const by_type = try registry.build_action_type(app_mod.type_id(MoveUp), arena.allocator());
    try testing.expectEqualStrings("editor::MoveUp", by_type.name);
    try testing.expectError(error.ActionNotFound, registry.build_action("editor::Missing", arena.allocator()));
    try testing.expectEqual(@as(usize, 2), registry.all_action_names().len);
    try testing.expectEqualStrings("editor::MoveDown", registry.all_action_names()[1]);
}
