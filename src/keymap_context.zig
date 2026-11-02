//! Key contexts and the keymap predicate language (GPUI keymap/context.rs).
//!
//! `KeyContext` is a small set of identifiers and key=value pairs describing one node of the
//! element tree. `KeyBindingContextPredicate` decides whether a binding applies to a stack of
//! contexts, e.g. `editor && mode == full`, `Workspace > Pane`, `!vim_mode`, `a || (b && c)`.
//!
//! Storage is fixed-size and copyable: a KeyContext owns its identifiers, so context stacks can be
//! copied without allocation. Identifiers are limited to `max_ident_len` bytes and a context to
//! `max_entries` entries.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// Maximum number of entries in one `KeyContext`.
pub const max_entries = 8;
/// Maximum byte length of a context identifier or value.
pub const max_ident_len = 32;

pub const ContextError = error{
    /// The context already has `max_entries` entries.
    ContextFull,
    /// An identifier or value is longer than `max_ident_len`.
    IdentifierTooLong,
    /// The source is not a valid context string.
    InvalidContext,
};

/// An identifier stored inline.
pub const Ident = struct {
    buf: [max_ident_len]u8 = undefined,
    len: u8 = 0,

    pub fn init(s: []const u8) ContextError!Ident {
        if (s.len > max_ident_len) return error.IdentifierTooLong;
        var out: Ident = .{ .len = @intCast(s.len) };
        @memcpy(out.buf[0..s.len], s);
        return out;
    }

    pub fn slice(self: *const Ident) []const u8 {
        return self.buf[0..self.len];
    }
};

/// An entry in a KeyContext: an identifier (`value == null`) or a key=value pair.
pub const ContextEntry = struct {
    key: Ident = .{},
    value: ?Ident = null,
};

/// A set of identifiers and key-value pairs describing the current context for the keymap.
pub const KeyContext = struct {
    entries_buf: [max_entries]ContextEntry = undefined,
    len: u8 = 0,

    /// Parses `StatusBar mode=visible` style source: identifiers and `key = value` pairs,
    /// separated by whitespace.
    pub fn parse(source: []const u8) ContextError!KeyContext {
        var ctx: KeyContext = .{};
        var rest = skip_whitespace(source);
        while (rest.len > 0) {
            const key_len = ident_len(rest);
            if (key_len == 0) return error.InvalidContext;
            const key = rest[0..key_len];
            rest = skip_whitespace(rest[key_len..]);
            if (rest.len > 0 and rest[0] == '=') {
                rest = skip_whitespace(rest[1..]);
                const value_len = ident_len(rest);
                const value = rest[0..value_len];
                rest = skip_whitespace(rest[value_len..]);
                try ctx.set(key, value);
            } else {
                try ctx.add(key);
            }
        }
        return ctx;
    }

    pub fn entries(self: *const KeyContext) []const ContextEntry {
        return self.entries_buf[0..self.len];
    }

    pub fn is_empty(self: *const KeyContext) bool {
        return self.len == 0;
    }

    pub fn clear(self: *KeyContext) void {
        self.len = 0;
    }

    /// The first entry without a value (usually the component name), if any.
    pub fn primary(self: *const KeyContext) ?*const ContextEntry {
        for (self.entries()) |*e| if (e.value == null) return e;
        return null;
    }

    /// Adds an identifier unless the key is already present.
    pub fn add(self: *KeyContext, identifier: []const u8) ContextError!void {
        if (self.contains(identifier)) return;
        try self.push(.{ .key = try Ident.init(identifier), .value = null });
    }

    /// Sets a key-value pair unless the key is already present.
    pub fn set(self: *KeyContext, key: []const u8, value: []const u8) ContextError!void {
        if (self.contains(key)) return;
        try self.push(.{ .key = try Ident.init(key), .value = try Ident.init(value) });
    }

    /// Whether an identifier or key is present (with or without a value).
    pub fn contains(self: *const KeyContext, key: []const u8) bool {
        for (self.entries()) |e| if (std.mem.eql(u8, e.key.slice(), key)) return true;
        return false;
    }

    /// The value for `key`, or null if the key is missing or is a bare identifier.
    pub fn get(self: *const KeyContext, key: []const u8) ?[]const u8 {
        for (self.entries()) |*e| {
            if (std.mem.eql(u8, e.key.slice(), key)) {
                return if (e.value) |*v| v.slice() else null;
            }
        }
        return null;
    }

    /// Adds every entry of `other` whose key is not yet present.
    pub fn extend(self: *KeyContext, other: *const KeyContext) ContextError!void {
        for (other.entries()) |e| {
            if (self.contains(e.key.slice())) continue;
            try self.push(e);
        }
    }

    pub fn eql(a: *const KeyContext, b: *const KeyContext) bool {
        if (a.len != b.len) return false;
        for (a.entries(), b.entries()) |*x, *y| {
            if (!std.mem.eql(u8, x.key.slice(), y.key.slice())) return false;
            const xv = if (x.value) |*v| v.slice() else null;
            const yv = if (y.value) |*v| v.slice() else null;
            if (xv == null and yv == null) continue;
            if (xv == null or yv == null) return false;
            if (!std.mem.eql(u8, xv.?, yv.?)) return false;
        }
        return true;
    }

    fn push(self: *KeyContext, entry: ContextEntry) ContextError!void {
        if (self.len >= max_entries) return error.ContextFull;
        self.entries_buf[self.len] = entry;
        self.len += 1;
    }

    pub fn format(self: KeyContext, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        for (self.entries(), 0..) |e, i| {
            if (i > 0) try writer.writeByte(' ');
            try writer.writeAll(e.key.slice());
            if (e.value) |v| try writer.print("={s}", .{v.slice()});
        }
    }
};

/// A predicate over a stack of contexts, parsed from a keymap `context` string.
pub const KeyBindingContextPredicate = union(enum) {
    /// Matches a context containing this identifier.
    identifier: []const u8,
    /// Matches a context whose `key` equals `value`.
    equal: KeyValue,
    /// Matches a context whose `key` differs from `value` or is absent.
    not_equal: KeyValue,
    /// `parent > child`: `child` matches a context below one that matches `parent`.
    descendant: Pair,
    /// `!pred`
    not: *const Self,
    @"and": Pair,
    @"or": Pair,

    const Self = @This();

    pub const KeyValue = struct { key: []const u8, value: []const u8 };
    pub const Pair = struct { left: *const Self, right: *const Self };

    pub const ParseError = error{
        UnexpectedEnd,
        UnexpectedCharacter,
        ExpectedCloseParen,
        OperandsMustBeIdentifiers,
        OutOfMemory,
    };

    const PRECEDENCE_CHILD = 1;
    const PRECEDENCE_OR = 2;
    const PRECEDENCE_AND = 3;
    const PRECEDENCE_EQ = 4;
    const PRECEDENCE_NOT = 5;

    const OpKind = enum { child, @"and", @"or", eq, neq };
    const Operator = struct { text: []const u8, precedence: u32, kind: OpKind };
    const operators = [_]Operator{
        .{ .text = ">", .precedence = PRECEDENCE_CHILD, .kind = .child },
        .{ .text = "&&", .precedence = PRECEDENCE_AND, .kind = .@"and" },
        .{ .text = "||", .precedence = PRECEDENCE_OR, .kind = .@"or" },
        .{ .text = "==", .precedence = PRECEDENCE_EQ, .kind = .eq },
        .{ .text = "!=", .precedence = PRECEDENCE_EQ, .kind = .neq },
    };

    /// Parses a predicate. Identifiers are copied into `allocator`, so `source` may be freed
    /// afterwards. Child nodes are allocated with `allocator` too; use an arena.
    pub fn parse(allocator: Allocator, source: []const u8) ParseError!Self {
        const result = try parse_expr(allocator, skip_whitespace(source), 0);
        if (result.rest.len > 0) return error.UnexpectedCharacter;
        return result.predicate;
    }

    /// The deepest depth (number of leading contexts) at which the predicate matches.
    pub fn depth_of(self: *const Self, contexts: []const KeyContext) ?usize {
        var depth: usize = contexts.len + 1;
        while (depth > 0) {
            depth -= 1;
            if (self.eval_inner(contexts[0..depth], contexts)) return depth;
        }
        return null;
    }

    /// Evaluates the predicate against contexts ordered from lowest (root) to highest (leaf).
    pub fn eval(self: *const Self, contexts: []const KeyContext) bool {
        return self.eval_inner(contexts, contexts);
    }

    pub fn eval_inner(self: *const Self, contexts: []const KeyContext, all: []const KeyContext) bool {
        if (contexts.len == 0) return false;
        const ctx = &contexts[contexts.len - 1];
        switch (self.*) {
            .identifier => |name| return ctx.contains(name),
            .equal => |kv| return if (ctx.get(kv.key)) |v| std.mem.eql(u8, v, kv.value) else false,
            .not_equal => |kv| return if (ctx.get(kv.key)) |v| !std.mem.eql(u8, v, kv.value) else true,
            .not => |pred| {
                for (0..all.len) |i| {
                    if (pred.eval_inner(all[0 .. i + 1], all)) return false;
                }
                return true;
            },
            .descendant => |p| {
                var i: usize = 0;
                while (i + 1 < contexts.len) : (i += 1) {
                    if (p.left.eval_inner(contexts[0 .. i + 1], all)) {
                        return p.right.eval_inner(contexts[i + 1 ..], contexts[i + 1 ..]);
                    }
                }
                return false;
            },
            .@"and" => |p| return p.left.eval_inner(contexts, all) and p.right.eval_inner(contexts, all),
            .@"or" => |p| return p.left.eval_inner(contexts, all) or p.right.eval_inner(contexts, all),
        }
    }

    /// Whether every context matched by `other` is also matched by `self`.
    pub fn is_superset(self: *const Self, other: *const Self) bool {
        if (self.eql(other)) return true;
        switch (self.*) {
            .@"or" => |p| return p.left.is_superset(other) or p.right.is_superset(other),
            else => {},
        }
        switch (other.*) {
            .descendant => |p| return self.is_superset(p.right),
            .@"and" => |p| return self.is_superset(p.left) or self.is_superset(p.right),
            else => return false,
        }
    }

    /// Structural equality.
    pub fn eql(a: *const Self, b: *const Self) bool {
        if (std.meta.activeTag(a.*) != std.meta.activeTag(b.*)) return false;
        return switch (a.*) {
            .identifier => |n| std.mem.eql(u8, n, b.identifier),
            .equal => |kv| std.mem.eql(u8, kv.key, b.equal.key) and std.mem.eql(u8, kv.value, b.equal.value),
            .not_equal => |kv| std.mem.eql(u8, kv.key, b.not_equal.key) and std.mem.eql(u8, kv.value, b.not_equal.value),
            .descendant => |p| p.left.eql(b.descendant.left) and p.right.eql(b.descendant.right),
            .not => |p| p.eql(b.not),
            .@"and" => |p| p.left.eql(b.@"and".left) and p.right.eql(b.@"and".right),
            .@"or" => |p| p.left.eql(b.@"or".left) and p.right.eql(b.@"or".right),
        };
    }

    /// Writes the predicate in keymap syntax, adding parentheses only where needed.
    pub fn format(self: Self, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        switch (self) {
            .identifier => |name| try writer.writeAll(name),
            .equal => |kv| try writer.print("{s} == {s}", .{ kv.key, kv.value }),
            .not_equal => |kv| try writer.print("{s} != {s}", .{ kv.key, kv.value }),
            .descendant => |p| try writer.print("{f} > {f}", .{ p.left.*, p.right.* }),
            .not => |p| switch (p.*) {
                .identifier => |name| try writer.print("!{s}", .{name}),
                else => try writer.print("!({f})", .{p.*}),
            },
            .@"and" => {
                var first = true;
                try write_joined(&self, writer, true, &first);
            },
            .@"or" => {
                var first = true;
                try write_joined(&self, writer, false, &first);
            },
        }
    }

    fn write_joined(node: *const Self, writer: *std.Io.Writer, comptime is_and: bool, first: *bool) std.Io.Writer.Error!void {
        const pair: ?Pair = if (is_and) switch (node.*) {
            .@"and" => |p| p,
            else => null,
        } else switch (node.*) {
            .@"or" => |p| p,
            else => null,
        };
        if (pair) |p| {
            try write_joined(p.left, writer, is_and, first);
            try write_joined(p.right, writer, is_and, first);
            return;
        }
        if (!first.*) try writer.writeAll(if (is_and) " && " else " || ");
        first.* = false;
        const needs_parens = switch (node.*) {
            .@"or" => is_and,
            .@"and" => !is_and,
            else => false,
        };
        if (needs_parens) {
            try writer.print("({f})", .{node.*});
        } else {
            try writer.print("{f}", .{node.*});
        }
    }

    const Parsed = struct { predicate: Self, rest: []const u8 };

    fn parse_expr(allocator: Allocator, source: []const u8, min_precedence: u32) ParseError!Parsed {
        var parsed = try parse_primary(allocator, source);
        var rest = parsed.rest;
        var progressed = true;
        while (progressed) {
            progressed = false;
            for (operators) |op| {
                if (op.precedence < min_precedence) continue;
                if (!std.mem.startsWith(u8, rest, op.text)) continue;
                const after = skip_whitespace(rest[op.text.len..]);
                const right = try parse_expr(allocator, after, op.precedence + 1);
                parsed.predicate = try combine(allocator, op.kind, parsed.predicate, right.predicate);
                rest = right.rest;
                progressed = true;
                break;
            }
        }
        return .{ .predicate = parsed.predicate, .rest = rest };
    }

    fn parse_primary(allocator: Allocator, source: []const u8) ParseError!Parsed {
        if (source.len == 0) return error.UnexpectedEnd;
        const next = source[0];
        if (next == '(') {
            const inner = skip_whitespace(source[1..]);
            const parsed = try parse_expr(allocator, inner, 0);
            if (!std.mem.startsWith(u8, parsed.rest, ")")) return error.ExpectedCloseParen;
            return .{ .predicate = parsed.predicate, .rest = skip_whitespace(parsed.rest[1..]) };
        }
        if (next == '!') {
            const after = skip_whitespace(source[1..]);
            const parsed = try parse_expr(allocator, after, PRECEDENCE_NOT);
            const boxed = try box(allocator, parsed.predicate);
            return .{ .predicate = .{ .not = boxed }, .rest = parsed.rest };
        }
        if (is_identifier_char(next)) {
            var len: usize = 0;
            while (len < source.len and (is_identifier_char(source[len]) or is_vim_operator_char(source[len]))) len += 1;
            const ident = try allocator.dupe(u8, source[0..len]);
            return .{ .predicate = .{ .identifier = ident }, .rest = skip_whitespace(source[len..]) };
        }
        if (is_vim_operator_char(next)) {
            const ident = try allocator.dupe(u8, source[0..1]);
            return .{ .predicate = .{ .identifier = ident }, .rest = skip_whitespace(source[1..]) };
        }
        return error.UnexpectedCharacter;
    }

    fn combine(allocator: Allocator, kind: OpKind, left: Self, right: Self) ParseError!Self {
        switch (kind) {
            .eq, .neq => {
                const l = switch (left) {
                    .identifier => |n| n,
                    else => return error.OperandsMustBeIdentifiers,
                };
                const r = switch (right) {
                    .identifier => |n| n,
                    else => return error.OperandsMustBeIdentifiers,
                };
                const kv = KeyValue{ .key = l, .value = r };
                return if (kind == .eq) .{ .equal = kv } else .{ .not_equal = kv };
            },
            .child => return .{ .descendant = .{ .left = try box(allocator, left), .right = try box(allocator, right) } },
            .@"and" => return .{ .@"and" = .{ .left = try box(allocator, left), .right = try box(allocator, right) } },
            .@"or" => return .{ .@"or" = .{ .left = try box(allocator, left), .right = try box(allocator, right) } },
        }
    }

    fn box(allocator: Allocator, value: Self) Allocator.Error!*const Self {
        const ptr = try allocator.create(Self);
        ptr.* = value;
        return ptr;
    }
};

fn is_identifier_char(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_' or c == '-';
}

fn is_vim_operator_char(c: u8) bool {
    return c == '>' or c == '<' or c == '~' or c == '"' or c == '?';
}

fn ident_len(source: []const u8) usize {
    var len: usize = 0;
    while (len < source.len and is_identifier_char(source[len])) len += 1;
    return len;
}

fn skip_whitespace(source: []const u8) []const u8 {
    var i: usize = 0;
    while (i < source.len and std.ascii.isWhitespace(source[i])) i += 1;
    return source[i..];
}

// ---------------------------------------------------------------------------
// Tests (ported from GPUI keymap/context.rs)

const testing = std.testing;
const P = KeyBindingContextPredicate;

fn parse_test(arena: Allocator, source: []const u8) !P {
    return P.parse(arena, source);
}

fn kc(source: []const u8) KeyContext {
    return KeyContext.parse(source) catch unreachable;
}

test "parse context" {
    var expected: KeyContext = .{};
    try expected.add("baz");
    try expected.set("foo", "bar");
    try testing.expect(KeyContext.eql(&kc("baz foo=bar"), &expected));
    try testing.expect(KeyContext.eql(&kc("baz foo = bar"), &expected));
    try testing.expect(KeyContext.eql(&kc("  baz foo   =   bar baz"), &expected));
    try testing.expect(KeyContext.eql(&kc(" baz foo = bar"), &expected));
}

test "parse context rejects garbage instead of looping" {
    try testing.expectError(error.InvalidContext, KeyContext.parse("&&"));
}

test "parse identifiers" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try testing.expectEqualStrings("abc12", (try parse_test(arena, "abc12")).identifier);
    try testing.expectEqualStrings("_1a", (try parse_test(arena, "_1a")).identifier);
}

test "parse negations" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const p = try parse_test(arena, " ! ! abc");
    try testing.expectEqualStrings("abc", p.not.not.identifier);
}

test "parse equality operators" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const eq = try parse_test(arena, "a == b");
    try testing.expectEqualStrings("a", eq.equal.key);
    try testing.expectEqualStrings("b", eq.equal.value);
    const neq = try parse_test(arena, "c!=d");
    try testing.expectEqualStrings("c", neq.not_equal.key);
    try testing.expectEqualStrings("d", neq.not_equal.value);
    try testing.expectError(error.OperandsMustBeIdentifiers, parse_test(arena, "c == !d"));
}

test "parse boolean operators" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const a_or_not_b_and_c = try parse_test(arena, "a || !b && c");
    try testing.expectEqualStrings("a", a_or_not_b_and_c.@"or".left.identifier);
    try testing.expectEqualStrings("b", a_or_not_b_and_c.@"or".right.@"and".left.not.identifier);
    try testing.expectEqualStrings("c", a_or_not_b_and_c.@"or".right.@"and".right.identifier);

    const mixed = try parse_test(arena, "a && b || c&&d");
    try testing.expectEqualStrings("a", mixed.@"or".left.@"and".left.identifier);
    try testing.expectEqualStrings("b", mixed.@"or".left.@"and".right.identifier);
    try testing.expectEqualStrings("c", mixed.@"or".right.@"and".left.identifier);
    try testing.expectEqualStrings("d", mixed.@"or".right.@"and".right.identifier);

    const left_assoc = try parse_test(arena, "a && b && c && d");
    try testing.expectEqualStrings("d", left_assoc.@"and".right.identifier);
    try testing.expectEqualStrings("c", left_assoc.@"and".left.@"and".right.identifier);
}

test "parse parenthesized expressions" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const p = try parse_test(arena, "a && (b == c || d != e)");
    try testing.expectEqualStrings("a", p.@"and".left.identifier);
    try testing.expectEqualStrings("c", p.@"and".right.@"or".left.equal.value);
    try testing.expectEqualStrings("e", p.@"and".right.@"or".right.not_equal.value);
    const q = try parse_test(arena, " ( a || b ) ");
    try testing.expectEqualStrings("b", q.@"or".right.identifier);
}

test "parse errors" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try testing.expectError(error.ExpectedCloseParen, parse_test(arena, "(a || b"));
    try testing.expectError(error.UnexpectedEnd, parse_test(arena, ""));
    try testing.expectError(error.UnexpectedCharacter, parse_test(arena, "a &"));
}

test "is_superset" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const cases = [_]struct { a: []const u8, b: []const u8, expected: bool }{
        .{ .a = "editor", .b = "editor", .expected = true },
        .{ .a = "editor", .b = "workspace", .expected = false },
        .{ .a = "editor", .b = "editor && vim_mode", .expected = true },
        .{ .a = "editor", .b = "mode == full && editor", .expected = true },
        .{ .a = "editor && mode == full", .b = "editor", .expected = false },
        .{ .a = "editor", .b = "something > editor", .expected = true },
        .{ .a = "editor", .b = "editor > menu", .expected = false },
        .{ .a = "foo || bar || baz", .b = "bar", .expected = true },
        .{ .a = "foo || bar || baz", .b = "quux", .expected = false },
    };
    for (cases) |c| {
        const a = try parse_test(arena, c.a);
        const b = try parse_test(arena, c.b);
        try testing.expectEqual(c.expected, a.is_superset(&b));
    }
}

test "child operator" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const pred = try parse_test(arena, "parent > child");

    const parent = kc("parent");
    const child = kc("child");
    try testing.expect(pred.eval(&.{ parent, child }));
    try testing.expect(pred.eval(&.{ kc("grandparent"), parent, child }));
    try testing.expect(!pred.eval(&.{ kc("other"), child }));
    try testing.expect(pred.eval(&.{ parent, kc("other"), child }));
    try testing.expect(!pred.eval(&.{}));
    try testing.expect(!pred.eval(&.{child}));
    try testing.expect(!pred.eval(&.{parent}));

    const zany = try parse_test(arena, "child > child");
    try testing.expect(!zany.eval(&.{child}));
    try testing.expect(zany.eval(&.{ child, child }));
}

test "not operator" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const editor = kc("editor");
    const workspace = kc("workspace");
    const parent = kc("parent");
    const child = kc("child");

    const not_editor = try parse_test(arena, "!editor");
    try testing.expect(not_editor.eval(&.{workspace}));
    try testing.expect(!not_editor.eval(&.{editor}));
    try testing.expect(!not_editor.eval(&.{ editor, workspace }));
    try testing.expect(!not_editor.eval(&.{ workspace, editor }));

    const complex = try parse_test(arena, "!editor && workspace");
    try testing.expect(complex.eval(&.{workspace}));
    try testing.expect(!complex.eval(&.{ editor, workspace }));

    const not_mode = try parse_test(arena, "!(mode == full)");
    const full = kc("mode=full");
    const partial = kc("mode=partial");
    try testing.expect(!not_mode.eval(&.{full}));
    try testing.expect(not_mode.eval(&.{partial}));

    const not_descendant = try parse_test(arena, "!(parent > child)");
    try testing.expect(not_descendant.eval(&.{parent}));
    try testing.expect(not_descendant.eval(&.{child}));
    try testing.expect(!not_descendant.eval(&.{ parent, child }));

    const parent_not_child = try parse_test(arena, "parent > !child");
    try testing.expect(!parent_not_child.eval(&.{parent}));
    try testing.expect(!parent_not_child.eval(&.{child}));
    try testing.expect(!parent_not_child.eval(&.{ parent, child }));

    const double = try parse_test(arena, "!!editor");
    try testing.expect(double.eval(&.{editor}));
    try testing.expect(!double.eval(&.{workspace}));

    // Descendant cases from GPUI, with capitalized identifiers.
    const wpe = [_]KeyContext{ kc("Workspace"), kc("Pane"), kc("Editor") };
    const pane_pane_editor = try parse_test(arena, "Pane > (Pane > Editor)");
    try testing.expect(!pane_pane_editor.eval(&wpe));
    const wpe_pred = try parse_test(arena, "Workspace > Pane > Editor");
    try testing.expect(wpe_pred.eval(&wpe));
    const pane_pane_then_editor = try parse_test(arena, "(Pane > Pane) > Editor");
    try testing.expect(!pane_pane_then_editor.eval(&wpe));
    const pane_not_workspace = try parse_test(arena, "Pane > !Workspace");
    try testing.expect(pane_not_workspace.eval(&.{ kc("Pane"), kc("Editor") }));
    try testing.expect(!pane_not_workspace.eval(&.{ kc("Pane"), kc("Workspace") }));
    const not_workspace = try parse_test(arena, "!Workspace");
    try testing.expect(!not_workspace.eval(&.{kc("Workspace")}));
    try testing.expect(not_workspace.eval(&.{kc("Pane")}));
    try testing.expect(!not_workspace.eval(&wpe));
}

test "depth_of prefers the deepest matching context" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const pred = try parse_test(arena, "editor");
    try testing.expectEqual(@as(?usize, 2), pred.depth_of(&.{ kc("pane"), kc("editor") }));
    try testing.expectEqual(@as(?usize, null), pred.depth_of(&.{kc("pane")}));
    const global = try parse_test(arena, "!editor");
    try testing.expectEqual(@as(?usize, null), global.depth_of(&.{kc("editor")}));
    try testing.expectEqual(@as(?usize, 1), global.depth_of(&.{kc("workspace")}));
}

test "display round-trips" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const cases = [_]struct { source: []const u8, expected: []const u8 }{
        .{ .source = "a", .expected = "a" },
        .{ .source = "a == b", .expected = "a == b" },
        .{ .source = "a != b", .expected = "a != b" },
        .{ .source = "a > b", .expected = "a > b" },
        .{ .source = "!a", .expected = "!a" },
        .{ .source = "!(a && b)", .expected = "!(a && b)" },
        .{ .source = "!(a || b)", .expected = "!(a || b)" },
        .{ .source = "a && b && c", .expected = "a && b && c" },
        .{ .source = "a || b || c", .expected = "a || b || c" },
        .{ .source = "a || (b && c)", .expected = "a || (b && c)" },
        .{ .source = "a && (b || c) && d", .expected = "a && (b || c) && d" },
        .{ .source = "a || (b && c) || d", .expected = "a || (b && c) || d" },
        .{ .source = "a && b == c && !(d > e) && f == g", .expected = "a && b == c && !(d > e) && f == g" },
    };
    for (cases) |c| {
        const p = try parse_test(arena, c.source);
        const rendered = try std.fmt.allocPrint(arena, "{f}", .{p});
        try testing.expectEqualStrings(c.expected, rendered);
        const reparsed = try parse_test(arena, rendered);
        try testing.expect(p.eql(&reparsed));
    }
}

test "key context get / contains / extend" {
    var c = kc("Editor vim_mode=normal");
    try testing.expect(c.contains("Editor"));
    try testing.expectEqualStrings("normal", c.get("vim_mode").?);
    try testing.expectEqual(@as(?[]const u8, null), c.get("Editor"));
    try c.set("vim_mode", "insert"); // already present: ignored
    try testing.expectEqualStrings("normal", c.get("vim_mode").?);
    try c.extend(&kc("Editor mode=full"));
    try testing.expectEqualStrings("full", c.get("mode").?);
    try testing.expectEqualStrings("Editor", c.primary().?.key.slice());
}
