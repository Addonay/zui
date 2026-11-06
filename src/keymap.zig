//! Keymap: keystroke sequences bound to actions, optionally restricted by a context predicate
//! (GPUI keymap.rs and keymap/binding.rs).
//!
//! Precedence follows GPUI: a binding whose context matches deeper in the context stack wins,
//! and among equal depths the binding added later wins. A `NoAction` binding disables the
//! lower-precedence matches for its keystrokes, and an `Unbind` removes the binding of one named
//! action. Both only reach bindings from equal or weaker sources: a binding's meta is its source,
//! and a smaller meta is a stronger source (user over base keymap).

const std = @import("std");
const Allocator = std.mem.Allocator;
const ctx_mod = @import("keymap_context.zig");
const keystroke_mod = @import("keystroke.zig");
const action_mod = @import("action.zig");

/// GPUI `KeyBindingMetaIndex`: a key into a caller-owned store of binding metadata. A smaller
/// value is a stronger source (GPUI treats a missing meta as 0, a user binding).
pub const KeyBindingMetaIndex = struct { value: u32 };

/// GPUI `KeymapVersion`: changes whenever bindings are added or cleared.
pub const KeymapVersion = struct { value: usize = 0 };

pub const KeyContext = ctx_mod.KeyContext;
pub const KeyBindingContextPredicate = ctx_mod.KeyBindingContextPredicate;
pub const Keystroke = keystroke_mod.Keystroke;
pub const KeybindingKeystroke = keystroke_mod.KeybindingKeystroke;
pub const AnyAction = action_mod.AnyAction;
pub const Unbind = action_mod.Unbind;

/// Allocator for bindings created by `KeyBinding.new`. Bindings live for the app's lifetime.
const binding_allocator = std.heap.smp_allocator;

fn oom() noreturn {
    @panic("out of memory");
}

pub const LoadError = error{
    /// The keystroke string is empty or contains an invalid keystroke.
    InvalidKeystrokes,
    /// The context string does not parse.
    InvalidContext,
    OutOfMemory,
};

/// A keystroke sequence bound to an action, with an optional context predicate.
/// Fields named after GPUI's getters (`keystrokes`, `action`, `meta`, `action_input`) are the
/// getters: Zig cannot have a method and a field with one name.
pub const KeyBinding = struct {
    keystrokes: []const KeybindingKeystroke,
    action: AnyAction,
    context_predicate: ?*const KeyBindingContextPredicate = null,
    /// GPUI `meta`: a caller-defined index into its own metadata store, such as the source of the
    /// binding. Null when unset, which GPUI treats like 0 (a user binding).
    meta: ?KeyBindingMetaIndex = null,
    /// GPUI `action_input`: the data the keymap passed to the action. Null when there is none.
    action_input: ?[]const u8 = null,

    /// GPUI `KeyBinding::new("cmd-s", Save, Some("Editor"))`. Panics on invalid input, like GPUI.
    /// `keystrokes` is a space-separated sequence such as `"ctrl-k ctrl-s"`.
    pub fn new(keystrokes: []const u8, action: anytype, context: ?[]const u8) KeyBinding {
        const boxed = action_mod.box_action(binding_allocator, action);
        return load(binding_allocator, keystrokes, boxed, context) catch |err| {
            std.debug.panic("invalid keybinding \"{s}\": {s}", .{ keystrokes, @errorName(err) });
        };
    }

    /// Loads a binding from dynamic input (e.g. a user keymap file). GPUI's `use_key_equivalents`
    /// is not taken: the Linux and headless platforms map no key equivalents, so the keystrokes are
    /// kept as typed (`KeybindingKeystroke.from_keystroke`).
    pub fn load(allocator: Allocator, keystrokes: []const u8, action: AnyAction, context: ?[]const u8) LoadError!KeyBinding {
        const parsed_keystrokes = try parse_keystrokes(allocator, keystrokes);
        errdefer allocator.free(parsed_keystrokes);
        var context_predicate: ?*const KeyBindingContextPredicate = null;
        if (context) |source| {
            const value = KeyBindingContextPredicate.parse(allocator, source) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return error.InvalidContext,
            };
            const boxed = try allocator.create(KeyBindingContextPredicate);
            boxed.* = value;
            context_predicate = boxed;
        }
        return .{ .keystrokes = parsed_keystrokes, .action = action, .context_predicate = context_predicate };
    }

    /// GPUI `KeyBinding::with_meta`.
    pub fn with_meta(self: KeyBinding, meta: KeyBindingMetaIndex) KeyBinding {
        var out = self;
        out.meta = meta;
        return out;
    }

    /// GPUI `KeyBinding::set_meta`.
    pub fn set_meta(self: *KeyBinding, meta: KeyBindingMetaIndex) void {
        self.meta = meta;
    }

    /// GPUI `KeyBinding::predicate`: the context this binding requires, or null for any context.
    pub fn predicate(self: *const KeyBinding) ?*const KeyBindingContextPredicate {
        return self.context_predicate;
    }

    /// Whether the typed keystrokes are a prefix of (`true`) or exactly (`false`) this binding's
    /// sequence; `null` if they do not match.
    pub fn match_keystrokes(self: *const KeyBinding, typed: []const Keystroke) ?bool {
        if (self.keystrokes.len < typed.len) return null;
        for (self.keystrokes[0..typed.len], typed) |*target, *input| {
            if (!input.should_match(target.as_keystroke())) return null;
        }
        return self.keystrokes.len > typed.len;
    }
};

fn parse_keystrokes(allocator: Allocator, source: []const u8) LoadError![]const KeybindingKeystroke {
    var list: std.ArrayList(KeybindingKeystroke) = .empty;
    errdefer list.deinit(allocator);
    var it = std.mem.tokenizeAny(u8, source, " \t\r\n");
    while (it.next()) |token| {
        const keystroke = Keystroke.parse(token) catch return error.InvalidKeystrokes;
        if (keystroke.key.len == 0) return error.InvalidKeystrokes;
        try list.append(allocator, KeybindingKeystroke.from_keystroke(keystroke));
    }
    if (list.items.len == 0) return error.InvalidKeystrokes;
    return list.toOwnedSlice(allocator);
}

fn same_keystrokes(a: []const KeybindingKeystroke, b: []const KeybindingKeystroke) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| if (!x.inner.eql(y.inner)) return false;
    return true;
}

/// Whether two bindings are the same one, as copies made by dispatch compare. The action pointer
/// alone is not enough: zero-sized actions all share one address, so the action type is checked too.
pub fn same_binding(a: *const KeyBinding, b: *const KeyBinding) bool {
    return a.action.type_id == b.action.type_id and
        a.action.ptr == b.action.ptr and
        a.context_predicate == b.context_predicate and
        same_keystrokes(a.keystrokes, b.keystrokes);
}

/// GPUI `disabled_binding_matches_context`: whether a disabling binding's context covers the
/// context of the binding it disables.
fn disabled_matches_context(disabled: *const KeyBinding, binding: *const KeyBinding) bool {
    const d = disabled.context_predicate orelse return true;
    const p = binding.context_predicate orelse return false;
    return d.is_superset(p);
}

/// GPUI `binding_is_unbound`: whether `disabled` is an `Unbind` for the action of `binding` on the
/// same keystrokes. The context is checked by the caller.
fn binding_is_unbound(disabled: *const KeyBinding, binding: *const KeyBinding) bool {
    if (!action_mod.is_unbind(disabled.action)) return false;
    if (!same_keystrokes(disabled.keystrokes, binding.keystrokes)) return false;
    return std.mem.eql(u8, disabled.action.cast(Unbind).name, binding.action.name);
}

/// GPUI's `meta.map_or(0, |meta| meta.0)`: the source strength of a binding.
fn meta_value(binding: *const KeyBinding) u32 {
    return if (binding.meta) |meta| meta.value else 0;
}

/// Result of `Keymap.bindings_for_input`. `bindings` is owned by the caller's allocator.
pub const BindingsForInput = struct {
    bindings: []KeyBinding,
    /// Whether a longer keystroke sequence could still complete a binding.
    pending: bool,
};

/// A binding matched by the current input, with its depth and keymap index.
const Match = struct {
    depth: usize,
    ix: usize,

    fn less(_: void, a: Match, b: Match) bool {
        if (a.depth != b.depth) return a.depth > b.depth;
        return a.ix > b.ix;
    }
};

/// The keymap indices that dispatch for an input, in precedence order, and whether the input could
/// still be extended into a binding.
const Resolution = struct {
    indices: std.ArrayList(usize),
    pending: bool,
};

pub const Keymap = struct {
    gpa: Allocator,
    entries: std.ArrayList(KeyBinding) = .empty,
    keymap_version: KeymapVersion = .{},

    pub fn init(gpa: Allocator) Keymap {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *Keymap) void {
        self.entries.deinit(self.gpa);
    }

    /// GPUI `Keymap::version`.
    pub fn version(self: *const Keymap) KeymapVersion {
        return self.keymap_version;
    }

    /// Removes all bindings.
    pub fn clear(self: *Keymap) void {
        self.entries.clearRetainingCapacity();
        self.keymap_version.value += 1;
    }

    /// Adds bindings. Later bindings take precedence over earlier ones at the same depth.
    pub fn add_bindings(self: *Keymap, new_bindings: []const KeyBinding) !void {
        try self.entries.appendSlice(self.gpa, new_bindings);
        self.keymap_version.value += 1;
    }

    /// All bindings, in the order they were added.
    pub fn bindings(self: *const Keymap) []const KeyBinding {
        return self.entries.items;
    }

    /// Every binding that matches `input` whatever the context, highest precedence first (the
    /// ones added last). A binding that only starts `input` is left out. Caller frees the slice
    /// with `allocator`. GPUI `Keymap::all_bindings_for_input`.
    pub fn all_bindings_for_input(self: *const Keymap, allocator: Allocator, input: []const Keystroke) ![]KeyBinding {
        var out: std.ArrayList(KeyBinding) = .empty;
        errdefer out.deinit(allocator);
        var ix = self.entries.items.len;
        while (ix > 0) {
            ix -= 1;
            const binding = &self.entries.items[ix];
            const pending = binding.match_keystrokes(input) orelse continue;
            if (!pending) try out.append(allocator, binding.*);
        }
        return out.toOwnedSlice(allocator);
    }

    /// Depth at which the binding's predicate matches the contexts, or the full depth when it has
    /// no predicate. Null when it does not match. GPUI `binding_enabled`.
    fn binding_enabled(binding: *const KeyBinding, contexts: []const KeyContext) ?usize {
        if (binding.context_predicate) |predicate| return predicate.depth_of(contexts);
        return contexts.len;
    }

    /// All bindings that match `input` in `contexts`, in precedence order, plus whether a longer
    /// sequence could still complete. Bindings disabled by a `NoAction` or an `Unbind` are left out.
    /// Caller frees `bindings` with `allocator`. GPUI `Keymap::bindings_for_input`.
    pub fn bindings_for_input(self: *const Keymap, allocator: Allocator, input: []const Keystroke, contexts: []const KeyContext) !BindingsForInput {
        var resolution = try self.resolve(allocator, input, contexts, null);
        defer resolution.indices.deinit(allocator);
        const out = try allocator.alloc(KeyBinding, resolution.indices.items.len);
        for (resolution.indices.items, out) |ix, *slot| slot.* = self.entries.items[ix];
        return .{ .bindings = out, .pending = resolution.pending };
    }

    /// GPUI `resolve_bindings_for_input`. `candidates` are keymap indices, newest first; null means
    /// every binding. Candidates must include every binding that could match `input`, such as the
    /// `NoAction` and `Unbind` entries that disable them, or the disabling is missed.
    fn resolve(self: *const Keymap, allocator: Allocator, input: []const Keystroke, contexts: []const KeyContext, candidates: ?[]const usize) !Resolution {
        var matched: std.ArrayList(Match) = .empty;
        defer matched.deinit(allocator);
        var pending_ix: std.ArrayList(usize) = .empty;
        defer pending_ix.deinit(allocator);

        const count = if (candidates) |c| c.len else self.entries.items.len;
        for (0..count) |n| {
            const ix = if (candidates) |c| c[n] else self.entries.items.len - 1 - n;
            const binding = &self.entries.items[ix];
            const depth = binding_enabled(binding, contexts) orelse continue;
            const pending = binding.match_keystrokes(input) orelse continue;
            if (pending) {
                try pending_ix.append(allocator, ix);
            } else {
                try matched.append(allocator, .{ .depth = depth, .ix = ix });
            }
        }
        std.mem.sort(Match, matched.items, {}, Match.less);

        var indices: std.ArrayList(usize) = .empty;
        errdefer indices.deinit(allocator);
        var first_ix: ?usize = null;
        var unbound: std.ArrayList(*const KeyBinding) = .empty;
        defer unbound.deinit(allocator);
        // A `NoAction` suppresses the matches of its own source and weaker ones. Stronger sources
        // (a smaller meta, e.g. a user binding against a base keymap null) still apply.
        var no_action_meta: ?u32 = null;

        for (matched.items) |m| {
            const binding = &self.entries.items[m.ix];
            const meta = meta_value(binding);
            if (action_mod.is_no_action(binding.action)) {
                no_action_meta = if (no_action_meta) |existing| @min(existing, meta) else meta;
                continue;
            }
            if (no_action_meta) |limit| if (meta >= limit) continue;

            if (action_mod.is_unbind(binding.action)) {
                try unbound.append(allocator, binding);
                continue;
            }
            var disabled = false;
            for (unbound.items) |u| {
                if (binding_is_unbound(u, binding)) {
                    disabled = true;
                    break;
                }
            }
            if (disabled) continue;

            try indices.append(allocator, m.ix);
            if (first_ix == null) first_ix = m.ix;
        }

        // A pending sequence counts only if no matched binding of higher precedence came after it.
        // Walking oldest first, a `NoAction` or `Unbind` on the same keystrokes cancels it.
        var pending_seqs: std.ArrayList([]const KeybindingKeystroke) = .empty;
        defer pending_seqs.deinit(allocator);
        var k = pending_ix.items.len;
        while (k > 0) {
            k -= 1;
            const pix = pending_ix.items[k];
            if (first_ix) |fi| if (fi > pix) continue;
            const binding = &self.entries.items[pix];
            if (action_mod.is_no_action(binding.action) or action_mod.is_unbind(binding.action)) {
                var i: usize = 0;
                while (i < pending_seqs.items.len) {
                    if (same_keystrokes(pending_seqs.items[i], binding.keystrokes)) {
                        _ = pending_seqs.swapRemove(i);
                    } else {
                        i += 1;
                    }
                }
            } else {
                var present = false;
                for (pending_seqs.items) |seq| if (same_keystrokes(seq, binding.keystrokes)) {
                    present = true;
                    break;
                };
                if (!present) try pending_seqs.append(allocator, binding.keystrokes);
            }
        }

        return .{ .indices = indices, .pending = pending_seqs.items.len > 0 };
    }

    /// Bindings that could follow `input`: longer sequences that extend it and would dispatch for
    /// their full keystrokes in `contexts`, highest precedence first. Bindings disabled by a
    /// `NoAction` or an `Unbind` are left out. Caller frees the result with `allocator`.
    /// GPUI `Keymap::possible_next_bindings_for_input`.
    pub fn possible_next_bindings_for_input(self: *const Keymap, allocator: Allocator, input: []const Keystroke, contexts: []const KeyContext) ![]KeyBinding {
        // Keeps `NoAction` and `Unbind` entries, since they can disable candidates.
        var extending: std.ArrayList(usize) = .empty;
        defer extending.deinit(allocator);
        var ix = self.entries.items.len;
        while (ix > 0) {
            ix -= 1;
            const binding = &self.entries.items[ix];
            const pending = binding.match_keystrokes(input) orelse continue;
            if (pending) try extending.append(allocator, ix);
        }

        var found: std.ArrayList(Match) = .empty;
        defer found.deinit(allocator);
        for (extending.items) |candidate_ix| {
            const binding = &self.entries.items[candidate_ix];
            if (action_mod.is_no_action(binding.action) or action_mod.is_unbind(binding.action)) continue;
            const depth = binding_enabled(binding, contexts) orelse continue;
            // The typed input, then the binding's own remaining keystrokes. A typed keystroke can
            // match through its physical key or the character it produced, so the typed one is kept.
            const full = try allocator.alloc(Keystroke, binding.keystrokes.len);
            defer allocator.free(full);
            @memcpy(full[0..input.len], input);
            for (binding.keystrokes[input.len..], full[input.len..]) |keystroke, *slot| slot.* = keystroke.inner;

            var resolution = try self.resolve(allocator, full, contexts, extending.items);
            defer resolution.indices.deinit(allocator);
            if (std.mem.indexOfScalar(usize, resolution.indices.items, candidate_ix) != null) {
                try found.append(allocator, .{ .depth = depth, .ix = candidate_ix });
            }
        }
        std.mem.sort(Match, found.items, {}, Match.less);

        const out = try allocator.alloc(KeyBinding, found.items.len);
        for (found.items, out) |m, *slot| slot.* = self.entries.items[m.ix];
        return out;
    }

    /// Bindings that dispatch `action` (by action type), newest first. A binding is skipped when a
    /// later `NoAction` on the same keystrokes covers its context, or a later `Unbind` for its
    /// action does. Caller frees the result. Matching is by action type only, not by payload.
    /// GPUI `Keymap::bindings_for_action`.
    pub fn bindings_for_action(self: *const Keymap, allocator: Allocator, action: AnyAction) ![]KeyBinding {
        var out: std.ArrayList(KeyBinding) = .empty;
        errdefer out.deinit(allocator);
        for (self.entries.items, 0..) |*binding, ix| {
            if (binding.action.type_id != action.type_id) continue;
            if (action_mod.is_no_action(binding.action) or action_mod.is_unbind(binding.action)) continue;
            var disabled = false;
            for (self.entries.items[ix + 1 ..]) |*later| {
                if (!same_keystrokes(later.keystrokes, binding.keystrokes)) continue;
                if (action_mod.is_no_action(later.action)) {
                    if (disabled_matches_context(later, binding)) {
                        disabled = true;
                        break;
                    }
                } else if (action_mod.is_unbind(later.action) and disabled_matches_context(later, binding) and binding_is_unbound(later, binding)) {
                    disabled = true;
                    break;
                }
            }
            if (!disabled) try out.append(allocator, binding.*);
        }
        std.mem.reverse(KeyBinding, out.items);
        return out.toOwnedSlice(allocator);
    }
};

// ---------------------------------------------------------------------------
// Tests (ported from GPUI keymap.rs)

const testing = std.testing;
const Action = action_mod.Action;
const NoAction = action_mod.NoAction;

const ActionAlpha = Action("test_only", "ActionAlpha");
const ActionBeta = Action("test_only", "ActionBeta");
const ActionGamma = Action("test_only", "ActionGamma");

fn kc(source: []const u8) KeyContext {
    return KeyContext.parse(source) catch unreachable;
}

fn ks(source: []const u8) Keystroke {
    return Keystroke.parse(source) catch unreachable;
}

fn is_action(binding: KeyBinding, comptime T: type) bool {
    return binding.action.is(T);
}

fn free_result(allocator: Allocator, r: BindingsForInput) void {
    allocator.free(r.bindings);
}

/// `(keystrokes, action name)` pairs, like GPUI's `describe_bindings`. The keystrokes are unparsed
/// with the host's modifier spelling, so `ctrl-k b` reads the same as in the GPUI tests on Linux.
fn describe(allocator: Allocator, bindings: []const KeyBinding) ![]const [2][]const u8 {
    const out = try allocator.alloc([2][]const u8, bindings.len);
    for (bindings, out) |binding, *slot| {
        var text: std.ArrayList(u8) = .empty;
        for (binding.keystrokes, 0..) |keystroke, i| {
            if (i > 0) try text.append(allocator, ' ');
            const part = try keystroke.inner.unparse(allocator);
            defer allocator.free(part);
            try text.appendSlice(allocator, part);
        }
        slot.* = .{ try text.toOwnedSlice(allocator), binding.action.name };
    }
    return out;
}

fn free_describe(allocator: Allocator, described: []const [2][]const u8) void {
    for (described) |pair| allocator.free(pair[0]);
    allocator.free(described);
}

test "keymap: context-specific enabling" {
    const bindings = [_]KeyBinding{
        KeyBinding.new("ctrl-a", ActionAlpha{}, null),
        KeyBinding.new("ctrl-a", ActionBeta{}, "pane"),
        KeyBinding.new("ctrl-a", ActionGamma{}, "editor && mode==full"),
    };
    var keymap = Keymap.init(testing.allocator);
    defer keymap.deinit();
    try keymap.add_bindings(&bindings);

    // Global bindings are enabled in all contexts.
    try testing.expectEqual(@as(?usize, 0), Keymap.binding_enabled(&bindings[0], &.{}));
    try testing.expectEqual(@as(?usize, 1), Keymap.binding_enabled(&bindings[0], &.{kc("terminal")}));
    // Contextual bindings are enabled only where their predicate matches.
    try testing.expectEqual(@as(?usize, null), Keymap.binding_enabled(&bindings[1], &.{kc("barf x=y")}));
    try testing.expectEqual(@as(?usize, 1), Keymap.binding_enabled(&bindings[1], &.{kc("pane x=y")}));
    try testing.expectEqual(@as(?usize, null), Keymap.binding_enabled(&bindings[2], &.{kc("editor")}));
    try testing.expectEqual(@as(?usize, 1), Keymap.binding_enabled(&bindings[2], &.{kc("editor mode=full")}));
}

test "keymap: deeper context wins" {
    const bindings = [_]KeyBinding{
        KeyBinding.new("ctrl-a", ActionBeta{}, "pane"),
        KeyBinding.new("ctrl-a", ActionGamma{}, "editor"),
    };
    var keymap = Keymap.init(testing.allocator);
    defer keymap.deinit();
    try keymap.add_bindings(&bindings);

    const r = try keymap.bindings_for_input(testing.allocator, &.{ks("ctrl-a")}, &.{ kc("pane"), kc("editor") });
    defer free_result(testing.allocator, r);
    try testing.expect(!r.pending);
    try testing.expectEqual(@as(usize, 2), r.bindings.len);
    try testing.expect(is_action(r.bindings[0], ActionGamma));
    try testing.expect(is_action(r.bindings[1], ActionBeta));
}

test "keymap: NoAction disables matches" {
    const bindings = [_]KeyBinding{
        KeyBinding.new("ctrl-a", ActionAlpha{}, "editor"),
        KeyBinding.new("ctrl-b", ActionAlpha{}, "editor"),
        KeyBinding.new("ctrl-a", NoAction{}, "editor && mode==full"),
        KeyBinding.new("ctrl-b", NoAction{}, null),
    };
    var keymap = Keymap.init(testing.allocator);
    defer keymap.deinit();
    try keymap.add_bindings(&bindings);

    // Only enabled in the editor context.
    const barf = try keymap.bindings_for_input(testing.allocator, &.{ks("ctrl-a")}, &.{kc("barf")});
    defer free_result(testing.allocator, barf);
    try testing.expectEqual(@as(usize, 0), barf.bindings.len);
    const editor = try keymap.bindings_for_input(testing.allocator, &.{ks("ctrl-a")}, &.{kc("editor")});
    defer free_result(testing.allocator, editor);
    try testing.expectEqual(@as(usize, 1), editor.bindings.len);
    // Disabled in the more specific context.
    const full = try keymap.bindings_for_input(testing.allocator, &.{ks("ctrl-a")}, &.{kc("editor mode=full")});
    defer free_result(testing.allocator, full);
    try testing.expectEqual(@as(usize, 0), full.bindings.len);
    // Globally disabled.
    const global = try keymap.bindings_for_input(testing.allocator, &.{ks("ctrl-b")}, &.{kc("barf")});
    defer free_result(testing.allocator, global);
    try testing.expectEqual(@as(usize, 0), global.bindings.len);
}

test "keymap: multi-keystroke sequences and pending" {
    const bindings = [_]KeyBinding{
        KeyBinding.new("space w w", ActionAlpha{}, "Workspace"),
        KeyBinding.new("space w w", NoAction{}, "Editor"),
    };
    var keymap = Keymap.init(testing.allocator);
    defer keymap.deinit();
    try keymap.add_bindings(&bindings);

    const space = ks("space");
    const w = ks("w");
    const workspace = [_]KeyContext{kc("Workspace")};
    const editor_workspace = [_]KeyContext{ kc("Workspace"), kc("Editor") };

    // `space` is pending in the workspace, but not in the editor (where it is disabled).
    const sw = try keymap.bindings_for_input(testing.allocator, &.{space}, &workspace);
    defer free_result(testing.allocator, sw);
    try testing.expectEqual(@as(usize, 0), sw.bindings.len);
    try testing.expect(sw.pending);

    const se = try keymap.bindings_for_input(testing.allocator, &.{space}, &editor_workspace);
    defer free_result(testing.allocator, se);
    try testing.expect(!se.pending);

    // `space w w` dispatches in the workspace, but not in the editor.
    const www_ws = try keymap.bindings_for_input(testing.allocator, &.{ space, w, w }, &workspace);
    defer free_result(testing.allocator, www_ws);
    try testing.expectEqual(@as(usize, 1), www_ws.bindings.len);
    try testing.expect(!www_ws.pending);

    const www_ed = try keymap.bindings_for_input(testing.allocator, &.{ space, w, w }, &editor_workspace);
    defer free_result(testing.allocator, www_ed);
    try testing.expectEqual(@as(usize, 0), www_ed.bindings.len);
    try testing.expect(!www_ed.pending);
}

test "keymap: a binding added after a match keeps the prefix pending" {
    const bindings = [_]KeyBinding{
        KeyBinding.new("ctrl-w left", ActionAlpha{}, "editor"),
        KeyBinding.new("ctrl-w", NoAction{}, "editor"),
    };
    var keymap = Keymap.init(testing.allocator);
    defer keymap.deinit();
    try keymap.add_bindings(&bindings);
    const r = try keymap.bindings_for_input(testing.allocator, &.{ks("ctrl-w")}, &.{kc("editor")});
    defer free_result(testing.allocator, r);
    try testing.expectEqual(@as(usize, 0), r.bindings.len);
    try testing.expect(r.pending);

    const overridden = [_]KeyBinding{
        KeyBinding.new("ctrl-w left", ActionAlpha{}, "editor"),
        KeyBinding.new("ctrl-w", ActionBeta{}, "editor"),
    };
    var keymap2 = Keymap.init(testing.allocator);
    defer keymap2.deinit();
    try keymap2.add_bindings(&overridden);
    const r2 = try keymap2.bindings_for_input(testing.allocator, &.{ks("ctrl-w")}, &.{kc("editor")});
    defer free_result(testing.allocator, r2);
    try testing.expectEqual(@as(usize, 1), r2.bindings.len);
    try testing.expect(!r2.pending);
}

test "keymap: simple disable" {
    const bindings = [_]KeyBinding{
        KeyBinding.new("ctrl-x", ActionAlpha{}, "editor"),
        KeyBinding.new("ctrl-x", NoAction{}, "editor"),
    };
    var keymap = Keymap.init(testing.allocator);
    defer keymap.deinit();
    try keymap.add_bindings(&bindings);
    const r = try keymap.bindings_for_input(testing.allocator, &.{ks("ctrl-x")}, &.{kc("editor")});
    defer free_result(testing.allocator, r);
    try testing.expectEqual(@as(usize, 0), r.bindings.len);
    try testing.expect(!r.pending);
}

test "keymap: test_disable_deeper: a NoAction in a deeper context disables a shallower binding" {
    const bindings = [_]KeyBinding{
        KeyBinding.new("ctrl-x", ActionAlpha{}, "workspace"),
        KeyBinding.new("ctrl-x", NoAction{}, "editor"),
    };
    var keymap = Keymap.init(testing.allocator);
    defer keymap.deinit();
    try keymap.add_bindings(&bindings);
    const r = try keymap.bindings_for_input(testing.allocator, &.{ks("ctrl-x")}, &.{ kc("workspace"), kc("editor") });
    defer free_result(testing.allocator, r);
    try testing.expectEqual(@as(usize, 0), r.bindings.len);
    try testing.expect(!r.pending);
}

test "keymap: test_fail_to_disable: a NoAction in a shallower context does not disable a deeper binding" {
    const bindings = [_]KeyBinding{
        KeyBinding.new("ctrl-x", ActionAlpha{}, "editor"),
        KeyBinding.new("ctrl-x", NoAction{}, "workspace"),
    };
    var keymap = Keymap.init(testing.allocator);
    defer keymap.deinit();
    try keymap.add_bindings(&bindings);
    const r = try keymap.bindings_for_input(testing.allocator, &.{ks("ctrl-x")}, &.{ kc("workspace"), kc("editor") });
    defer free_result(testing.allocator, r);
    try testing.expectEqual(@as(usize, 1), r.bindings.len);
    try testing.expect(!r.pending);
}

test "keymap: test_disable_weaker_sources_only" {
    const USER = KeyBindingMetaIndex{ .value = 0 };
    const VIM = KeyBindingMetaIndex{ .value = 1 };
    const BASE = KeyBindingMetaIndex{ .value = 2 };
    const DEFAULT = KeyBindingMetaIndex{ .value = 3 };

    const editor_context = [_]KeyContext{kc("editor")};
    const ctrl_x = [_]Keystroke{ks("ctrl-x")};

    // A base keymap null disables a default binding in the same context.
    {
        var keymap = Keymap.init(testing.allocator);
        defer keymap.deinit();
        try keymap.add_bindings(&.{
            KeyBinding.new("ctrl-x", ActionAlpha{}, "editor").with_meta(DEFAULT),
            KeyBinding.new("ctrl-x", NoAction{}, "editor").with_meta(BASE),
        });
        const r = try keymap.bindings_for_input(testing.allocator, &ctrl_x, &editor_context);
        defer free_result(testing.allocator, r);
        try testing.expectEqual(@as(usize, 0), r.bindings.len);
    }
    // A user binding is not affected by base keymap or default nulls.
    {
        var keymap = Keymap.init(testing.allocator);
        defer keymap.deinit();
        try keymap.add_bindings(&.{
            KeyBinding.new("ctrl-x", NoAction{}, "editor").with_meta(DEFAULT),
            KeyBinding.new("ctrl-x", NoAction{}, "editor").with_meta(BASE),
            KeyBinding.new("ctrl-x", ActionBeta{}, null).with_meta(USER),
        });
        const r = try keymap.bindings_for_input(testing.allocator, &ctrl_x, &editor_context);
        defer free_result(testing.allocator, r);
        try testing.expectEqual(@as(usize, 1), r.bindings.len);
        try testing.expect(is_action(r.bindings[0], ActionBeta));
    }
    // A user binding at a shallower context is not disabled by a deeper base keymap null.
    {
        var keymap = Keymap.init(testing.allocator);
        defer keymap.deinit();
        try keymap.add_bindings(&.{
            KeyBinding.new("ctrl-x", NoAction{}, "editor").with_meta(BASE),
            KeyBinding.new("ctrl-x", ActionBeta{}, "workspace").with_meta(USER),
        });
        const r = try keymap.bindings_for_input(testing.allocator, &ctrl_x, &.{ kc("workspace"), kc("editor") });
        defer free_result(testing.allocator, r);
        try testing.expectEqual(@as(usize, 1), r.bindings.len);
        try testing.expect(is_action(r.bindings[0], ActionBeta));
    }
    // A vim binding survives a base keymap null.
    {
        var keymap = Keymap.init(testing.allocator);
        defer keymap.deinit();
        try keymap.add_bindings(&.{
            KeyBinding.new("ctrl-x", ActionAlpha{}, "editor").with_meta(DEFAULT),
            KeyBinding.new("ctrl-x", NoAction{}, "editor").with_meta(BASE),
            KeyBinding.new("ctrl-x", ActionGamma{}, "editor").with_meta(VIM),
        });
        const r = try keymap.bindings_for_input(testing.allocator, &ctrl_x, &editor_context);
        defer free_result(testing.allocator, r);
        try testing.expectEqual(@as(usize, 1), r.bindings.len);
        try testing.expect(is_action(r.bindings[0], ActionGamma));
    }
    // A user null disables everything in its context.
    {
        var keymap = Keymap.init(testing.allocator);
        defer keymap.deinit();
        try keymap.add_bindings(&.{
            KeyBinding.new("ctrl-x", ActionAlpha{}, "editor").with_meta(DEFAULT),
            KeyBinding.new("ctrl-x", ActionGamma{}, "editor").with_meta(VIM),
            KeyBinding.new("ctrl-x", NoAction{}, "editor").with_meta(USER),
        });
        const r = try keymap.bindings_for_input(testing.allocator, &ctrl_x, &editor_context);
        defer free_result(testing.allocator, r);
        try testing.expectEqual(@as(usize, 0), r.bindings.len);
    }
}

test "keymap: test_override_multikey" {
    {
        var keymap = Keymap.init(testing.allocator);
        defer keymap.deinit();
        try keymap.add_bindings(&.{
            KeyBinding.new("ctrl-w left", ActionAlpha{}, "editor"),
            KeyBinding.new("ctrl-w", NoAction{}, "editor"),
        });
        const r = try keymap.bindings_for_input(testing.allocator, &.{ks("ctrl-w")}, &.{kc("editor")});
        defer free_result(testing.allocator, r);
        try testing.expectEqual(@as(usize, 0), r.bindings.len);
        try testing.expect(r.pending);
    }
    {
        var keymap = Keymap.init(testing.allocator);
        defer keymap.deinit();
        try keymap.add_bindings(&.{
            KeyBinding.new("ctrl-w left", ActionAlpha{}, "editor"),
            KeyBinding.new("ctrl-w", ActionBeta{}, "editor"),
        });
        const r = try keymap.bindings_for_input(testing.allocator, &.{ks("ctrl-w")}, &.{kc("editor")});
        defer free_result(testing.allocator, r);
        try testing.expectEqual(@as(usize, 1), r.bindings.len);
        try testing.expect(!r.pending);
    }
}

test "keymap: test_multiple_keystroke_binding_disabled (zed issue 30259)" {
    const space = ks("space");
    const w = ks("w");
    const space_w = [_]Keystroke{ space, w };
    const space_w_w = [_]Keystroke{ space, w, w };
    const workspace = [_]KeyContext{kc("workspace")};
    const editor_workspace = [_]KeyContext{ kc("workspace"), kc("editor") };
    const one_space = [_]Keystroke{space};

    {
        var keymap = Keymap.init(testing.allocator);
        defer keymap.deinit();
        try keymap.add_bindings(&.{
            KeyBinding.new("space w w", ActionAlpha{}, "workspace"),
            KeyBinding.new("space w w", NoAction{}, "editor"),
        });
        // `space` is pending in the workspace, but not in the editor.
        const sw = try keymap.bindings_for_input(testing.allocator, &one_space, &workspace);
        defer free_result(testing.allocator, sw);
        try testing.expectEqual(@as(usize, 0), sw.bindings.len);
        try testing.expect(sw.pending);
        const se = try keymap.bindings_for_input(testing.allocator, &one_space, &editor_workspace);
        defer free_result(testing.allocator, se);
        try testing.expectEqual(@as(usize, 0), se.bindings.len);
        try testing.expect(!se.pending);

        // `space w` is pending in the workspace, but not in the editor.
        const sww = try keymap.bindings_for_input(testing.allocator, &space_w, &workspace);
        defer free_result(testing.allocator, sww);
        try testing.expect(sww.pending);
        const swe = try keymap.bindings_for_input(testing.allocator, &space_w, &editor_workspace);
        defer free_result(testing.allocator, swe);
        try testing.expect(!swe.pending);

        // `space w w` dispatches in the workspace, but not in the editor.
        const www = try keymap.bindings_for_input(testing.allocator, &space_w_w, &workspace);
        defer free_result(testing.allocator, www);
        try testing.expectEqual(@as(usize, 1), www.bindings.len);
        try testing.expect(!www.pending);
        const wwe = try keymap.bindings_for_input(testing.allocator, &space_w_w, &editor_workspace);
        defer free_result(testing.allocator, wwe);
        try testing.expectEqual(@as(usize, 0), wwe.bindings.len);
        try testing.expect(!wwe.pending);
    }
    // A binding defined after the NoAction keeps `space` pending in the editor.
    {
        var keymap = Keymap.init(testing.allocator);
        defer keymap.deinit();
        try keymap.add_bindings(&.{
            KeyBinding.new("space w w", ActionAlpha{}, "workspace"),
            KeyBinding.new("space w w", NoAction{}, "editor"),
            KeyBinding.new("space w x", ActionAlpha{}, "editor"),
        });
        const se = try keymap.bindings_for_input(testing.allocator, &one_space, &editor_workspace);
        defer free_result(testing.allocator, se);
        try testing.expect(se.pending);
    }
    // A binding defined before the NoAction keeps `space` pending in the editor.
    {
        var keymap = Keymap.init(testing.allocator);
        defer keymap.deinit();
        try keymap.add_bindings(&.{
            KeyBinding.new("space w w", ActionAlpha{}, "workspace"),
            KeyBinding.new("space w x", ActionAlpha{}, "editor"),
            KeyBinding.new("space w w", NoAction{}, "editor"),
        });
        const se = try keymap.bindings_for_input(testing.allocator, &one_space, &editor_workspace);
        defer free_result(testing.allocator, se);
        try testing.expect(se.pending);
    }
    // A binding at a higher context keeps `space` pending in the editor.
    {
        var keymap = Keymap.init(testing.allocator);
        defer keymap.deinit();
        try keymap.add_bindings(&.{
            KeyBinding.new("space w w", ActionAlpha{}, "workspace"),
            KeyBinding.new("space w x", ActionAlpha{}, "workspace"),
            KeyBinding.new("space w w", NoAction{}, "editor"),
        });
        const se = try keymap.bindings_for_input(testing.allocator, &one_space, &editor_workspace);
        defer free_result(testing.allocator, se);
        try testing.expect(se.pending);
    }
}

test "keymap: test_pending_match_enabled" {
    var keymap = Keymap.init(testing.allocator);
    defer keymap.deinit();
    try keymap.add_bindings(&.{
        KeyBinding.new("ctrl-x", ActionBeta{}, "vim_mode == normal"),
        KeyBinding.new("ctrl-x 0", ActionAlpha{}, "Workspace"),
    });
    const contexts = [_]KeyContext{ kc("Workspace"), kc("Pane"), kc("Editor vim_mode=normal") };
    const matched = try keymap.bindings_for_input(testing.allocator, &.{ks("ctrl-x")}, &contexts);
    defer free_result(testing.allocator, matched);
    try testing.expectEqual(@as(usize, 1), matched.bindings.len);
    try testing.expect(is_action(matched.bindings[0], ActionBeta));
    try testing.expect(matched.pending);
}

test "keymap: test_pending_match_enabled_extended" {
    const contexts = [_]KeyContext{ kc("Workspace"), kc("Pane"), kc("Editor vim_mode=normal") };
    {
        var keymap = Keymap.init(testing.allocator);
        defer keymap.deinit();
        try keymap.add_bindings(&.{
            KeyBinding.new("ctrl-x", ActionBeta{}, "vim_mode == normal"),
            KeyBinding.new("ctrl-x 0", NoAction{}, "Workspace"),
        });
        const matched = try keymap.bindings_for_input(testing.allocator, &.{ks("ctrl-x")}, &contexts);
        defer free_result(testing.allocator, matched);
        try testing.expectEqual(@as(usize, 1), matched.bindings.len);
        try testing.expect(is_action(matched.bindings[0], ActionBeta));
        try testing.expect(!matched.pending);
    }
    {
        var keymap = Keymap.init(testing.allocator);
        defer keymap.deinit();
        try keymap.add_bindings(&.{
            KeyBinding.new("ctrl-x", ActionBeta{}, "Workspace"),
            KeyBinding.new("ctrl-x 0", NoAction{}, "vim_mode == normal"),
        });
        const matched = try keymap.bindings_for_input(testing.allocator, &.{ks("ctrl-x")}, &contexts);
        defer free_result(testing.allocator, matched);
        try testing.expectEqual(@as(usize, 1), matched.bindings.len);
        try testing.expect(is_action(matched.bindings[0], ActionBeta));
        try testing.expect(!matched.pending);
    }
}

test "keymap: test_overriding_prefix" {
    var keymap = Keymap.init(testing.allocator);
    defer keymap.deinit();
    try keymap.add_bindings(&.{
        KeyBinding.new("ctrl-x 0", ActionAlpha{}, "Workspace"),
        KeyBinding.new("ctrl-x", ActionBeta{}, "vim_mode == normal"),
    });
    const contexts = [_]KeyContext{ kc("Workspace"), kc("Pane"), kc("Editor vim_mode=normal") };
    const matched = try keymap.bindings_for_input(testing.allocator, &.{ks("ctrl-x")}, &contexts);
    defer free_result(testing.allocator, matched);
    try testing.expectEqual(@as(usize, 1), matched.bindings.len);
    try testing.expect(is_action(matched.bindings[0], ActionBeta));
    try testing.expect(!matched.pending);
}

test "keymap: test_context_precedence_with_same_source" {
    var keymap = Keymap.init(testing.allocator);
    defer keymap.deinit();
    try keymap.add_bindings(&.{
        KeyBinding.new("cmd-r", ActionAlpha{}, "Workspace"),
        KeyBinding.new("cmd-r", ActionBeta{}, "Editor"),
    });
    const r = try keymap.bindings_for_input(testing.allocator, &.{ks("cmd-r")}, &.{ kc("Workspace"), kc("Editor") });
    defer free_result(testing.allocator, r);
    // Both bindings are returned, the Editor one first (highest precedence).
    try testing.expectEqual(@as(usize, 2), r.bindings.len);
    try testing.expect(is_action(r.bindings[0], ActionBeta));
    try testing.expect(is_action(r.bindings[1], ActionAlpha));
}

test "keymap: test_bindings_for_action" {
    var keymap = Keymap.init(testing.allocator);
    defer keymap.deinit();
    try keymap.add_bindings(&.{
        KeyBinding.new("ctrl-a", ActionAlpha{}, "pane"),
        KeyBinding.new("ctrl-b", ActionBeta{}, "editor && mode == full"),
        KeyBinding.new("ctrl-c", ActionGamma{}, "workspace"),
        KeyBinding.new("ctrl-a", NoAction{}, "pane && active"),
        KeyBinding.new("ctrl-b", NoAction{}, "editor"),
    });

    try expect_action_keys(&keymap, box(ActionAlpha{}), &.{"a"});
    try expect_action_keys(&keymap, box(ActionBeta{}), &.{});
    try expect_action_keys(&keymap, box(ActionGamma{}), &.{"c"});
}

/// GPUI's `assert_bindings`: the key of the first keystroke of each binding dispatching `action`.
fn expect_action_keys(keymap: *const Keymap, action: AnyAction, expected: []const []const u8) !void {
    const found = try keymap.bindings_for_action(testing.allocator, action);
    defer testing.allocator.free(found);
    try testing.expectEqual(expected.len, found.len);
    for (expected, found) |want, got| try testing.expectEqualStrings(want, got.keystrokes[0].inner.key);
}

test "keymap: test_targeted_unbind_ignores_target_context" {
    var keymap = Keymap.init(testing.allocator);
    defer keymap.deinit();
    try keymap.add_bindings(&.{
        KeyBinding.new("tab", ActionAlpha{}, "Editor"),
        KeyBinding.new("tab", ActionBeta{}, "Editor && showing_completions"),
        KeyBinding.new("tab", Unbind{ .name = "test_only::ActionAlpha" }, "Editor && edit_prediction"),
    });
    const contexts = [_]KeyContext{kc("Editor showing_completions edit_prediction")};
    const r = try keymap.bindings_for_input(testing.allocator, &.{ks("tab")}, &contexts);
    defer free_result(testing.allocator, r);
    try testing.expect(!r.pending);
    try testing.expectEqual(@as(usize, 1), r.bindings.len);
    try testing.expect(is_action(r.bindings[0], ActionBeta));
}

test "keymap: test_bindings_for_action_keeps_binding_for_narrower_targeted_unbind" {
    var keymap = Keymap.init(testing.allocator);
    defer keymap.deinit();
    try keymap.add_bindings(&.{
        KeyBinding.new("tab", ActionAlpha{}, "Editor"),
        KeyBinding.new("tab", Unbind{ .name = "test_only::ActionAlpha" }, "Editor && edit_prediction"),
        KeyBinding.new("tab", ActionBeta{}, "Editor && showing_completions"),
    });
    const alpha = try keymap.bindings_for_action(testing.allocator, box(ActionAlpha{}));
    defer testing.allocator.free(alpha);
    try testing.expectEqual(@as(usize, 1), alpha.len);
    try testing.expectEqualStrings("tab", alpha[0].keystrokes[0].inner.key);
    const beta = try keymap.bindings_for_action(testing.allocator, box(ActionBeta{}));
    defer testing.allocator.free(beta);
    try testing.expectEqual(@as(usize, 1), beta.len);
}

test "keymap: test_bindings_for_action_removes_binding_for_broader_targeted_unbind" {
    var keymap = Keymap.init(testing.allocator);
    defer keymap.deinit();
    try keymap.add_bindings(&.{
        KeyBinding.new("tab", ActionAlpha{}, "Editor && edit_prediction"),
        KeyBinding.new("tab", Unbind{ .name = "test_only::ActionAlpha" }, "Editor"),
    });
    const alpha = try keymap.bindings_for_action(testing.allocator, box(ActionAlpha{}));
    defer testing.allocator.free(alpha);
    try testing.expectEqual(@as(usize, 0), alpha.len);
}

test "keymap: test_source_precedence_sorting" {
    var keymap = Keymap.init(testing.allocator);
    defer keymap.deinit();
    // The default binding is added first, then the user binding; the user one wins at the same depth.
    try keymap.add_bindings(&.{KeyBinding.new("cmd-r", ActionAlpha{}, "Editor").with_meta(.{ .value = 3 })});
    try keymap.add_bindings(&.{KeyBinding.new("cmd-r", ActionBeta{}, "Editor").with_meta(.{ .value = 0 })});
    const r = try keymap.bindings_for_input(testing.allocator, &.{ks("cmd-r")}, &.{kc("Editor")});
    defer free_result(testing.allocator, r);
    try testing.expectEqual(@as(usize, 2), r.bindings.len);
    try testing.expect(is_action(r.bindings[0], ActionBeta));
    try testing.expect(is_action(r.bindings[1], ActionAlpha));
}

test "keymap: possible_next_bindings exclude null bindings" {
    var keymap = Keymap.init(testing.allocator);
    defer keymap.deinit();
    try keymap.add_bindings(&.{
        KeyBinding.new("ctrl-k a", ActionAlpha{}, "Editor"),
        KeyBinding.new("ctrl-k b", ActionBeta{}, "Editor"),
        KeyBinding.new("ctrl-k a", NoAction{}, "Editor"),
    });
    const next = try keymap.possible_next_bindings_for_input(testing.allocator, &.{ks("ctrl-k")}, &.{kc("Editor")});
    defer testing.allocator.free(next);
    const described = try describe(testing.allocator, next);
    defer free_describe(testing.allocator, described);
    try testing.expectEqual(@as(usize, 1), described.len);
    try testing.expectEqualStrings("ctrl-k b", described[0][0]);
    try testing.expectEqualStrings("test_only::ActionBeta", described[0][1]);
}

test "keymap: possible_next_bindings exclude unbound bindings" {
    var keymap = Keymap.init(testing.allocator);
    defer keymap.deinit();
    try keymap.add_bindings(&.{
        KeyBinding.new("ctrl-k a", ActionAlpha{}, "Editor"),
        KeyBinding.new("ctrl-k b", ActionBeta{}, "Editor"),
        KeyBinding.new("ctrl-k a", Unbind{ .name = "test_only::ActionAlpha" }, "Editor"),
    });
    const next = try keymap.possible_next_bindings_for_input(testing.allocator, &.{ks("ctrl-k")}, &.{kc("Editor")});
    defer testing.allocator.free(next);
    try testing.expectEqual(@as(usize, 1), next.len);
    try testing.expect(is_action(next[0], ActionBeta));
}

test "keymap: possible_next_bindings keep a user binding over a base keymap null" {
    const USER = KeyBindingMetaIndex{ .value = 0 };
    const BASE = KeyBindingMetaIndex{ .value = 2 };
    const DEFAULT = KeyBindingMetaIndex{ .value = 3 };
    var keymap = Keymap.init(testing.allocator);
    defer keymap.deinit();
    try keymap.add_bindings(&.{
        KeyBinding.new("ctrl-k a", ActionAlpha{}, "Editor").with_meta(DEFAULT),
        KeyBinding.new("ctrl-k a", NoAction{}, "Editor").with_meta(BASE),
        KeyBinding.new("ctrl-k a", ActionBeta{}, "Editor").with_meta(USER),
    });
    const next = try keymap.possible_next_bindings_for_input(testing.allocator, &.{ks("ctrl-k")}, &.{kc("Editor")});
    defer testing.allocator.free(next);
    try testing.expectEqual(@as(usize, 1), next.len);
    try testing.expect(is_action(next[0], ActionBeta));
}

test "keymap: possible_next_bindings apply disabling by context" {
    var keymap = Keymap.init(testing.allocator);
    defer keymap.deinit();
    try keymap.add_bindings(&.{
        KeyBinding.new("ctrl-k a", ActionAlpha{}, "Workspace"),
        KeyBinding.new("ctrl-k a", ActionBeta{}, "Editor"),
        KeyBinding.new("ctrl-k b", ActionGamma{}, "Editor"),
        // Only removes the editor binding, so the workspace binding still dispatches.
        KeyBinding.new("ctrl-k a", Unbind{ .name = "test_only::ActionBeta" }, "Editor"),
        // Doesn't apply because `Terminal` isn't in the context stack.
        KeyBinding.new("ctrl-k b", NoAction{}, "Terminal"),
    });
    const contexts = [_]KeyContext{ kc("Workspace"), kc("Editor") };
    const next = try keymap.possible_next_bindings_for_input(testing.allocator, &.{ks("ctrl-k")}, &contexts);
    defer testing.allocator.free(next);
    const described = try describe(testing.allocator, next);
    defer free_describe(testing.allocator, described);
    try testing.expectEqual(@as(usize, 2), described.len);
    try testing.expectEqualStrings("test_only::ActionGamma", described[0][1]);
    try testing.expectEqualStrings("test_only::ActionAlpha", described[1][1]);
}

test "keymap: possible_next_bindings exclude a longer chord disabled in a deeper context" {
    var keymap = Keymap.init(testing.allocator);
    defer keymap.deinit();
    try keymap.add_bindings(&.{
        KeyBinding.new("space w w", ActionAlpha{}, "Workspace"),
        KeyBinding.new("space w x", ActionBeta{}, "Workspace"),
        KeyBinding.new("space w w", NoAction{}, "AgentPanel"),
    });
    const contexts = [_]KeyContext{ kc("Workspace"), kc("AgentPanel") };
    const inputs = [_][]const Keystroke{ &.{ks("space")}, &.{ ks("space"), ks("w") } };
    for (inputs) |input| {
        const next = try keymap.possible_next_bindings_for_input(testing.allocator, input, &contexts);
        defer testing.allocator.free(next);
        try testing.expectEqual(@as(usize, 1), next.len);
        try testing.expect(is_action(next[0], ActionBeta));
    }
}

test "keymap: possible_next_bindings exclude disabled bindings with typed input" {
    // Option-S reports both its physical key and the character it produced, so typed input
    // matches bindings written with either.
    const typed = [_]Keystroke{ks("alt-s->ß")};
    var keymap = Keymap.init(testing.allocator);
    defer keymap.deinit();
    try keymap.add_bindings(&.{
        KeyBinding.new("ß a", ActionAlpha{}, null),
        KeyBinding.new("alt-s a", NoAction{}, null),
    });
    const next = try keymap.possible_next_bindings_for_input(testing.allocator, &typed, &.{});
    defer testing.allocator.free(next);
    try testing.expectEqual(@as(usize, 0), next.len);

    // Cross-check against dispatch of the same typed input.
    const typed_then_a = [_]Keystroke{ ks("alt-s->ß"), ks("a") };
    const r = try keymap.bindings_for_input(testing.allocator, &typed_then_a, &.{});
    defer free_result(testing.allocator, r);
    try testing.expectEqual(@as(usize, 0), r.bindings.len);
}

test "keymap: possible_next_bindings is empty when nothing extends the input" {
    var keymap = Keymap.init(testing.allocator);
    defer keymap.deinit();
    try keymap.add_bindings(&.{KeyBinding.new("ctrl-k a", ActionAlpha{}, "Editor")});
    const next = try keymap.possible_next_bindings_for_input(testing.allocator, &.{ks("ctrl-k")}, &.{kc("Workspace")});
    defer testing.allocator.free(next);
    try testing.expectEqual(@as(usize, 0), next.len);
}

test "keymap: possible_next_bindings keeps a shallower binding that the deeper one does not stop" {
    var keymap = Keymap.init(testing.allocator);
    defer keymap.deinit();
    try keymap.add_bindings(&.{
        KeyBinding.new("ctrl-k a", ActionAlpha{}, "Workspace"),
        KeyBinding.new("ctrl-k a", ActionBeta{}, "Editor"),
        KeyBinding.new("ctrl-k b", ActionGamma{}, "Editor"),
    });
    // Beta is deeper, so `ctrl-k a` dispatches Beta first. Alpha still dispatches after it unless
    // Beta stops propagation, so it is a possible next binding too. Gamma comes first, being newer.
    const next = try keymap.possible_next_bindings_for_input(testing.allocator, &.{ks("ctrl-k")}, &.{ kc("Workspace"), kc("Editor") });
    defer testing.allocator.free(next);
    try testing.expectEqual(@as(usize, 3), next.len);
    try testing.expect(is_action(next[0], ActionGamma));
    try testing.expect(is_action(next[1], ActionBeta));
    try testing.expect(is_action(next[2], ActionAlpha));
}

test "keymap: all_bindings_for_input ignores context and lists the newest first" {
    var keymap = Keymap.init(testing.allocator);
    defer keymap.deinit();
    try keymap.add_bindings(&.{
        KeyBinding.new("ctrl-a", ActionAlpha{}, "Workspace"),
        KeyBinding.new("ctrl-a", ActionBeta{}, "Editor"),
        KeyBinding.new("ctrl-b", ActionGamma{}, null),
        KeyBinding.new("ctrl-k a", ActionAlpha{}, null),
    });

    // Both ctrl-a bindings match, though neither context is on the stack; the later one first.
    const found = try keymap.all_bindings_for_input(testing.allocator, &.{ks("ctrl-a")});
    defer testing.allocator.free(found);
    try testing.expectEqual(@as(usize, 2), found.len);
    try testing.expect(is_action(found[0], ActionBeta));
    try testing.expect(is_action(found[1], ActionAlpha));

    // A prefix of a longer binding is not a match.
    const prefix = try keymap.all_bindings_for_input(testing.allocator, &.{ks("ctrl-k")});
    defer testing.allocator.free(prefix);
    try testing.expectEqual(@as(usize, 0), prefix.len);

    const none = try keymap.all_bindings_for_input(testing.allocator, &.{ks("ctrl-z")});
    defer testing.allocator.free(none);
    try testing.expectEqual(@as(usize, 0), none.len);
}

test "keymap: version changes when bindings are added or cleared" {
    var keymap = Keymap.init(testing.allocator);
    defer keymap.deinit();
    const v0 = keymap.version();
    try keymap.add_bindings(&.{KeyBinding.new("ctrl-a", ActionAlpha{}, null)});
    const v1 = keymap.version();
    try testing.expect(v0.value != v1.value);
    keymap.clear();
    try testing.expect(v1.value != keymap.version().value);
}

test "keymap: binding meta, predicate and action_input" {
    var binding = KeyBinding.new("ctrl-a", ActionAlpha{}, "Editor");
    try testing.expect(binding.meta == null);
    try testing.expect(binding.predicate() != null);
    try testing.expect(KeyBinding.new("ctrl-a", ActionAlpha{}, null).predicate() == null);

    const tagged = binding.with_meta(.{ .value = 7 });
    try testing.expectEqual(@as(u32, 7), tagged.meta.?.value);
    try testing.expect(binding.meta == null);

    binding.set_meta(.{ .value = 3 });
    try testing.expectEqual(@as(u32, 3), binding.meta.?.value);

    // Metadata and input survive the copies that dispatch makes.
    binding.action_input = "{\"n\":1}";
    var keymap = Keymap.init(testing.allocator);
    defer keymap.deinit();
    try keymap.add_bindings(&.{binding});
    const found = try keymap.bindings_for_input(testing.allocator, &.{ks("ctrl-a")}, &.{kc("Editor")});
    defer testing.allocator.free(found.bindings);
    try testing.expectEqual(@as(u32, 3), found.bindings[0].meta.?.value);
    try testing.expectEqualStrings("{\"n\":1}", found.bindings[0].action_input.?);
}

test "keymap: load reports invalid input" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const any = action_mod.box_action(arena.allocator(), ActionAlpha{});
    try testing.expectError(error.InvalidKeystrokes, KeyBinding.load(arena.allocator(), "", any, null));
    try testing.expectError(error.InvalidKeystrokes, KeyBinding.load(arena.allocator(), "ctrl-", any, null));
    try testing.expectError(error.InvalidContext, KeyBinding.load(arena.allocator(), "ctrl-a", any, "a &&"));
    const ok = try KeyBinding.load(arena.allocator(), "ctrl-k ctrl-s", any, "editor");
    try testing.expectEqual(@as(usize, 2), ok.keystrokes.len);
    try testing.expect(ok.context_predicate != null);
}

fn box(action: anytype) AnyAction {
    return action_mod.box_action(binding_allocator, action);
}
