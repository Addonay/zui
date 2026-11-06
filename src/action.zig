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

/// A handler registered with `App.on_action`, run for every dispatched action of its type.
pub const GlobalActionListener = struct {
    action_type: TypeId,
    func: *const fn (*const anyopaque, *App) void,
};

/// Declares a unit action named `namespace::name`, like one entry of GPUI's `actions!` macro.
pub fn Action(comptime namespace: []const u8, comptime short_name: []const u8) type {
    const full = namespace ++ "::" ++ short_name;
    return struct {
        pub const action_name: []const u8 = full;

        /// The action's name, for display.
        pub fn name(_: *const @This()) []const u8 {
            return full;
        }

        /// The action's name, without an instance.
        pub fn name_for_type() []const u8 {
            return full;
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

/// GPUI `Unbind(name)`: a keymap entry that removes the binding of the action called `name` for the
/// same keystrokes, in the contexts this entry is enabled in. `name` is the action's full name, such
/// as "editor::MoveUp", and must outlive the keymap. Unlike `NoAction`, it removes one action only.
pub const Unbind = struct {
    pub const action_name: []const u8 = "zed::Unbind";

    /// The name of the action whose binding this entry removes.
    name: []const u8,
};

/// Whether `action` is `Unbind`.
pub fn is_unbind(action: AnyAction) bool {
    return action.is(Unbind);
}

pub const ActionBuildError = error{ActionNotFound};

/// GPUI `#[action(...)]` attributes for `ActionWith`.
pub const ActionOptions = struct {
    /// Shown for the action in docs and tooltips (GPUI `documentation`). Zig keeps no doc comments
    /// at comptime, so the text is given here.
    documentation: ?[]const u8 = null,
    /// Old names that still build this action (GPUI `deprecated_aliases`).
    deprecated_aliases: []const []const u8 = &.{},
    /// Warning shown for the action in the keymap schema (GPUI `deprecation_message`).
    deprecation_message: ?[]const u8 = null,
};

/// `Action`, with the documentation, deprecated aliases and deprecation message of GPUI's
/// `#[action(...)]` attributes: `pub const Save = ActionWith("editor", "Save", .{ .documentation = "..." })`.
/// Actions with data can declare the same as `pub const documentation`, `deprecated_aliases` and
/// `deprecation_message` on their struct instead.
pub fn ActionWith(comptime namespace: []const u8, comptime short_name: []const u8, comptime options: ActionOptions) type {
    const Base = Action(namespace, short_name);
    return struct {
        pub const action_name: []const u8 = Base.action_name;
        pub const documentation: ?[]const u8 = options.documentation;
        pub const deprecated_aliases: []const []const u8 = options.deprecated_aliases;
        pub const deprecation_message: ?[]const u8 = options.deprecation_message;

        pub fn name(_: *const @This()) []const u8 {
            return Base.name_for_type();
        }

        pub fn name_for_type() []const u8 {
            return Base.name_for_type();
        }
    };
}

/// GPUI `Action::documentation`: the `documentation` declaration of the action type, if any.
pub fn action_documentation(comptime T: type) ?[]const u8 {
    if (!@hasDecl(T, "documentation")) return null;
    const value: ?[]const u8 = T.documentation;
    return value;
}

/// GPUI `Action::deprecation_message`: the `deprecation_message` declaration of the action type.
pub fn action_deprecation_message(comptime T: type) ?[]const u8 {
    if (!@hasDecl(T, "deprecation_message")) return null;
    const value: ?[]const u8 = T.deprecation_message;
    return value;
}

/// GPUI `Action::deprecated_aliases`: the `deprecated_aliases` declaration of the action type.
pub fn action_deprecated_aliases(comptime T: type) []const []const u8 {
    if (!@hasDecl(T, "deprecated_aliases")) return &.{};
    return T.deprecated_aliases;
}

/// GPUI `Action::action_json_schema`: a JSON Schema for the input of `T`, built at compile time from
/// its fields. Null when `T` has no fields. Every field is listed under `properties`, and a field
/// with no default value is also `required`. Descriptions are not included, since Zig keeps no doc
/// comments at comptime; use `documentation` for the action itself. Supported field types: `bool`,
/// integers, floats, `[]const u8`, slices of those, enums (by field name), optionals (of the child
/// type, and not required), and nested structs. Anything else is a compile error.
pub fn action_json_schema(comptime T: type) ?[]const u8 {
    const info = @typeInfo(T);
    if (info != .@"struct" or info.@"struct".field_names.len == 0) return null;
    return comptime object_schema(T);
}

fn object_schema(comptime T: type) []const u8 {
    const info = @typeInfo(T).@"struct";
    var props: []const u8 = "";
    var required: []const u8 = "";
    inline for (info.field_names, info.field_types, info.field_attrs, 0..) |field_name, F, attrs, i| {
        if (i > 0) props = props ++ ",";
        props = props ++ "\"" ++ field_name ++ "\":" ++ value_schema(F);
        if (attrs.default_value_ptr == null) {
            if (required.len > 0) required = required ++ ",";
            required = required ++ "\"" ++ field_name ++ "\"";
        }
    }
    return "{\"type\":\"object\",\"properties\":{" ++ props ++ "},\"required\":[" ++ required ++ "]}";
}

fn value_schema(comptime F: type) []const u8 {
    return switch (@typeInfo(F)) {
        .bool => "{\"type\":\"boolean\"}",
        .int => "{\"type\":\"integer\"}",
        .float => "{\"type\":\"number\"}",
        .optional => |o| value_schema(o.child),
        .@"enum" => |e| enum_schema: {
            var values: []const u8 = "";
            inline for (e.field_names, 0..) |name, i| {
                if (i > 0) values = values ++ ",";
                values = values ++ "\"" ++ name ++ "\"";
            }
            break :enum_schema "{\"type\":\"string\",\"enum\":[" ++ values ++ "]}";
        },
        .pointer => |p| blk: {
            if (p.size != .slice) @compileError("no JSON schema for " ++ @typeName(F));
            if (p.child == u8) break :blk "{\"type\":\"string\"}";
            break :blk "{\"type\":\"array\",\"items\":" ++ value_schema(p.child) ++ "}";
        },
        .@"struct" => object_schema(F),
        else => @compileError("no JSON schema for " ++ @typeName(F)),
    };
}

/// One row of `ActionRegistry.action_schemas`: a registered name, aliases included, and its schema.
pub const SchemaEntry = struct {
    name: []const u8,
    /// The JSON Schema of the action's input, or null when it has no fields.
    json_schema: ?[]const u8,
};

/// Maps action names to constructors, so actions can be built from a name (GPUI's
/// ActionRegistry). Types must be default-constructible (`T{}`). Registration is explicit: Zig has
/// no link-time registry, so call `register` for each action at startup.
pub const ActionRegistry = struct {
    gpa: Allocator,
    by_name: std.StringHashMapUnmanaged(Entry) = .empty,
    names_by_type: std.AutoHashMapUnmanaged(TypeId, []const u8) = .empty,
    /// Every name in registration order, deprecated aliases included (GPUI `all_names`).
    all_names: std.ArrayList([]const u8) = .empty,
    /// Deprecated alias to the name it stands for (GPUI `deprecated_aliases`).
    aliases: std.StringHashMapUnmanaged([]const u8) = .empty,
    messages: std.StringHashMapUnmanaged([]const u8) = .empty,
    docs: std.StringHashMapUnmanaged([]const u8) = .empty,

    const Entry = struct {
        type_id: TypeId,
        build: *const fn (Allocator) AnyAction,
        json_schema: ?[]const u8,
    };

    pub fn init(gpa: Allocator) ActionRegistry {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *ActionRegistry) void {
        self.by_name.deinit(self.gpa);
        self.names_by_type.deinit(self.gpa);
        self.all_names.deinit(self.gpa);
        self.aliases.deinit(self.gpa);
        self.messages.deinit(self.gpa);
        self.docs.deinit(self.gpa);
    }

    /// Registers `T` under its action name, with its deprecated aliases, deprecation message and
    /// documentation. Panics if a name is already registered, as GPUI does.
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
        const entry: Entry = .{ .type_id = type_id_of(T), .build = S.build, .json_schema = action_json_schema(T) };
        try self.by_name.put(self.gpa, name, entry);
        // Aliases come before the name in `all_names`, as in GPUI.
        for (action_deprecated_aliases(T)) |alias| {
            if (self.by_name.contains(alias)) {
                std.debug.panic("Action with name `{s}` already registered. `{s}` is a deprecated alias of `{s}`.", .{ alias, alias, name });
            }
            try self.by_name.put(self.gpa, alias, entry);
            try self.aliases.put(self.gpa, alias, name);
            try self.all_names.append(self.gpa, alias);
        }
        try self.names_by_type.put(self.gpa, type_id_of(T), name);
        try self.all_names.append(self.gpa, name);
        if (action_deprecation_message(T)) |message| try self.messages.put(self.gpa, name, message);
        if (action_documentation(T)) |doc| try self.docs.put(self.gpa, name, doc);
    }

    /// Builds the action registered under `name`, or under a deprecated alias of it.
    pub fn build_action(self: *const ActionRegistry, name: []const u8, allocator: Allocator) ActionBuildError!AnyAction {
        const entry = self.by_name.get(name) orelse return error.ActionNotFound;
        return entry.build(allocator);
    }

    /// Builds the action registered for `tid`.
    pub fn build_action_type(self: *const ActionRegistry, tid: TypeId, allocator: Allocator) ActionBuildError!AnyAction {
        const name = self.names_by_type.get(tid) orelse return error.ActionNotFound;
        return self.build_action(name, allocator);
    }

    /// All registered action names, deprecated aliases included, in registration order.
    pub fn all_action_names(self: *const ActionRegistry) []const []const u8 {
        return self.all_names.items;
    }

    /// Every registered name with its input schema, in `all_action_names` order (GPUI
    /// `action_schemas`). The slice is owned by `allocator`.
    pub fn action_schemas(self: *const ActionRegistry, allocator: Allocator) ![]SchemaEntry {
        const out = try allocator.alloc(SchemaEntry, self.all_names.items.len);
        for (self.all_names.items, out) |name, *slot| {
            slot.* = .{ .name = name, .json_schema = self.by_name.get(name).?.json_schema };
        }
        return out;
    }

    /// The input schema of `name` (GPUI `action_schema_by_name`). Null when no action has the name;
    /// otherwise the schema, which is itself null for an action with no fields.
    pub fn action_schema_by_name(self: *const ActionRegistry, name: []const u8) ??[]const u8 {
        const entry = self.by_name.get(name) orelse return null;
        return entry.json_schema;
    }

    /// Deprecated alias to current name (GPUI `deprecated_aliases`).
    pub fn deprecated_aliases(self: *const ActionRegistry) *const std.StringHashMapUnmanaged([]const u8) {
        return &self.aliases;
    }

    /// Deprecation message by action name (GPUI `deprecation_messages`).
    pub fn deprecation_messages(self: *const ActionRegistry) *const std.StringHashMapUnmanaged([]const u8) {
        return &self.messages;
    }

    /// Documentation by action name (GPUI `documentation`).
    pub fn documentation(self: *const ActionRegistry) *const std.StringHashMapUnmanaged([]const u8) {
        return &self.docs;
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

const SizedInput = struct {
    amount: u32,
    tag: []const u8 = "x",
    flag: bool,
    mode: enum { fast, slow } = .fast,
    note: ?u8 = null,
    items: []const u32 = &.{},
};

test "action_json_schema: every field is a property, and a field without a default is required" {
    try testing.expectEqualStrings(
        "{\"type\":\"object\",\"properties\":{\"amount\":{\"type\":\"integer\"},\"tag\":{\"type\":\"string\"},\"flag\":{\"type\":\"boolean\"},\"mode\":{\"type\":\"string\",\"enum\":[\"fast\",\"slow\"]},\"note\":{\"type\":\"integer\"},\"items\":{\"type\":\"array\",\"items\":{\"type\":\"integer\"}}},\"required\":[\"amount\",\"flag\"]}",
        action_json_schema(SizedInput).?,
    );
}

test "action_json_schema: an action with no fields has no schema" {
    try testing.expect(action_json_schema(MoveUp) == null);
    try testing.expect(action_json_schema(Plain) == null);
}

test "ActionWith: documentation, deprecated aliases and the deprecation message reach the registry" {
    const Renamed = ActionWith("editor", "Save", .{
        .documentation = "Saves the file.",
        .deprecated_aliases = &.{"editor::Write"},
        .deprecation_message = "Use editor::Save.",
    });
    var registry = ActionRegistry.init(testing.allocator);
    defer registry.deinit();
    try registry.register(Renamed);

    // Aliases come before the name in the listing, as in GPUI.
    const names = registry.all_action_names();
    try testing.expectEqual(@as(usize, 2), names.len);
    try testing.expectEqualStrings("editor::Write", names[0]);
    try testing.expectEqualStrings("editor::Save", names[1]);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const built = try registry.build_action("editor::Write", arena.allocator());
    try testing.expect(built.is(Renamed));
    try testing.expectEqualStrings("editor::Save", built.name);

    try testing.expectEqualStrings("editor::Save", registry.deprecated_aliases().get("editor::Write").?);
    try testing.expectEqualStrings("Saves the file.", registry.documentation().get("editor::Save").?);
    try testing.expectEqualStrings("Use editor::Save.", registry.deprecation_messages().get("editor::Save").?);
    try testing.expect(registry.documentation().get("editor::Write") == null);
}

test "ActionRegistry: action_schemas and action_schema_by_name report every name with its schema" {
    const Resize = struct {
        pub const action_name: []const u8 = "editor::Resize";
        width: u32 = 0,
        height: u32 = 0,
    };
    var registry = ActionRegistry.init(testing.allocator);
    defer registry.deinit();
    try registry.register(MoveUp);
    try registry.register(Resize);

    const schemas = try registry.action_schemas(testing.allocator);
    defer testing.allocator.free(schemas);
    try testing.expectEqual(@as(usize, 2), schemas.len);
    try testing.expectEqualStrings("editor::MoveUp", schemas[0].name);
    try testing.expect(schemas[0].json_schema == null);
    try testing.expectEqualStrings("editor::Resize", schemas[1].name);
    try testing.expectEqualStrings(
        "{\"type\":\"object\",\"properties\":{\"width\":{\"type\":\"integer\"},\"height\":{\"type\":\"integer\"}},\"required\":[]}",
        schemas[1].json_schema.?,
    );

    // Null when no action has the name; otherwise the schema, itself null for a unit action.
    try testing.expect(registry.action_schema_by_name("editor::Missing") == null);
    const unit = registry.action_schema_by_name("editor::MoveUp");
    try testing.expect(unit != null);
    try testing.expect(unit.? == null);
    try testing.expect(registry.action_schema_by_name("editor::Resize").? != null);
}

test "action_documentation: a `documentation` declaration on a data action is read" {
    const Documented = struct {
        pub const documentation: []const u8 = "Opens the thing.";
        n: u8 = 0,
    };
    try testing.expectEqualStrings("Opens the thing.", action_documentation(Documented).?);
    try testing.expect(action_documentation(MoveUp) == null);
}
