//! Keymap: keystroke sequences bound to actions, optionally restricted by a context predicate
//! (GPUI keymap.rs and keymap/binding.rs).
//!
//! Precedence follows GPUI: a binding whose context matches deeper in the context stack wins,
//! and among equal depths the binding added later wins. A `NoAction` binding disables all
//! lower-precedence matches for its keystrokes.

const std = @import("std");
const Allocator = std.mem.Allocator;
const ctx_mod = @import("keymap_context.zig");
const keystroke_mod = @import("keystroke.zig");
const action_mod = @import("action.zig");

/// GPUI `KeyBindingMetaIndex`: a key into a caller-owned store of binding metadata.
pub const KeyBindingMetaIndex = struct { value: u32 };

pub const KeyContext = ctx_mod.KeyContext;
pub const KeyBindingContextPredicate = ctx_mod.KeyBindingContextPredicate;
pub const Keystroke = keystroke_mod.Keystroke;
pub const AnyAction = action_mod.AnyAction;

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
    keystrokes: []const Keystroke,
    action: AnyAction,
    context_predicate: ?*const KeyBindingContextPredicate = null,
    /// GPUI `meta`: a caller-defined index into its own metadata store, such as the source of the
    /// binding. Null when unset.
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

    /// Loads a binding from dynamic input (e.g. a user keymap file).
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
            if (!input.should_match(target)) return null;
        }
        return self.keystrokes.len > typed.len;
    }
};

fn parse_keystrokes(allocator: Allocator, source: []const u8) LoadError![]const Keystroke {
    var list: std.ArrayList(Keystroke) = .empty;
    errdefer list.deinit(allocator);
    var it = std.mem.tokenizeAny(u8, source, " \t\r\n");
    while (it.next()) |token| {
        const keystroke = Keystroke.parse(token) catch return error.InvalidKeystrokes;
        if (keystroke.key.len == 0) return error.InvalidKeystrokes;
        try list.append(allocator, keystroke);
    }
    if (list.items.len == 0) return error.InvalidKeystrokes;
    return list.toOwnedSlice(allocator);
}

fn same_keystrokes(a: []const Keystroke, b: []const Keystroke) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| if (!x.eql(y)) return false;
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

/// Whether a disabling binding's context covers the context of the binding it disables.
fn disabled_matches_context(disabled: *const KeyBinding, binding: *const KeyBinding) bool {
    const d = disabled.context_predicate orelse return true;
    const p = binding.context_predicate orelse return false;
    return d.is_superset(p);
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

pub const Keymap = struct {
    gpa: Allocator,
    entries: std.ArrayList(KeyBinding) = .empty,

    pub fn init(gpa: Allocator) Keymap {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *Keymap) void {
        self.entries.deinit(self.gpa);
    }

    /// Removes all bindings.
    pub fn clear(self: *Keymap) void {
        self.entries.clearRetainingCapacity();
    }

    /// Adds bindings. Later bindings take precedence over earlier ones at the same depth.
    pub fn add_bindings(self: *Keymap, new_bindings: []const KeyBinding) !void {
        try self.entries.appendSlice(self.gpa, new_bindings);
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
    /// no predicate. Null when it does not match.
    fn binding_enabled(binding: *const KeyBinding, contexts: []const KeyContext) ?usize {
        if (binding.context_predicate) |predicate| return predicate.depth_of(contexts);
        return contexts.len;
    }

    /// The highest-precedence binding for a single keystroke in the context stack (root..leaf).
    /// Returns null if nothing matches or the best match is a `NoAction` that disables it.
    pub fn binding_for(self: *const Keymap, keystroke: Keystroke, contexts: []const KeyContext) ?*const KeyBinding {
        var best: ?usize = null;
        var best_depth: usize = 0;
        var ix = self.entries.items.len;
        while (ix > 0) {
            ix -= 1;
            const binding = &self.entries.items[ix];
            if (binding.keystrokes.len != 1) continue;
            if (!keystroke.should_match(&binding.keystrokes[0])) continue;
            const depth = binding_enabled(binding, contexts) orelse continue;
            // Iterating from the newest binding down, only a strictly deeper match replaces the best.
            if (best == null or depth > best_depth) {
                best = ix;
                best_depth = depth;
            }
        }
        const found = &self.entries.items[best orelse return null];
        if (action_mod.is_no_action(found.action)) return null;
        return found;
    }

    /// All bindings that match `input` in `contexts`, in precedence order, plus whether a longer
    /// sequence could still complete. Caller frees `bindings` with `allocator`.
    pub fn bindings_for_input(self: *const Keymap, allocator: Allocator, input: []const Keystroke, contexts: []const KeyContext) !BindingsForInput {
        var matched: std.ArrayList(Match) = .empty;
        defer matched.deinit(allocator);
        var pending_ix: std.ArrayList(usize) = .empty;
        defer pending_ix.deinit(allocator);

        var ix = self.entries.items.len;
        while (ix > 0) {
            ix -= 1;
            const binding = &self.entries.items[ix];
            const depth = binding_enabled(binding, contexts) orelse continue;
            const pending = binding.match_keystrokes(input) orelse continue;
            if (pending) {
                try pending_ix.append(allocator, ix);
            } else {
                try matched.append(allocator, .{ .depth = depth, .ix = ix });
            }
        }

        // Deeper first, then later-added first. Iteration above is already newest-first, so a
        // stable sort by depth alone gives the same order.
        std.mem.sort(Match, matched.items, {}, Match.less);

        var out: std.ArrayList(KeyBinding) = .empty;
        errdefer out.deinit(allocator);
        var first_ix: ?usize = null;
        for (matched.items) |m| {
            const binding = &self.entries.items[m.ix];
            // NoAction suppresses everything ranked below it.
            if (action_mod.is_no_action(binding.action)) break;
            try out.append(allocator, binding.*);
            if (first_ix == null) first_ix = m.ix;
        }

        // Pending sequences only count if no matched binding was added after them.
        var pending_seqs: std.ArrayList([]const Keystroke) = .empty;
        defer pending_seqs.deinit(allocator);
        var k = pending_ix.items.len;
        while (k > 0) {
            k -= 1; // ascending keymap order
            const pix = pending_ix.items[k];
            if (first_ix) |fi| if (fi > pix) continue;
            const binding = &self.entries.items[pix];
            if (action_mod.is_no_action(binding.action)) {
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

        return .{ .bindings = try out.toOwnedSlice(allocator), .pending = pending_seqs.items.len > 0 };
    }

    /// Bindings that could follow `input`: longer sequences that extend it and would dispatch for
    /// their full keystrokes in `contexts`, highest precedence first. Bindings disabled by a
    /// `NoAction` are left out. Caller frees the result with `allocator`.
    /// GPUI `Keymap::possible_next_bindings_for_input`.
    pub fn possible_next_bindings_for_input(self: *const Keymap, allocator: Allocator, input: []const Keystroke, contexts: []const KeyContext) ![]KeyBinding {
        var found: std.ArrayList(Match) = .empty;
        defer found.deinit(allocator);
        var ix = self.entries.items.len;
        while (ix > 0) {
            ix -= 1;
            const binding = &self.entries.items[ix];
            if (action_mod.is_no_action(binding.action)) continue;
            const pending = binding.match_keystrokes(input) orelse continue;
            if (!pending) continue;
            const depth = binding_enabled(binding, contexts) orelse continue;
            // The binding must win at its full keystrokes, not merely be a candidate.
            const winner = try self.bindings_for_input(allocator, binding.keystrokes, contexts);
            defer allocator.free(winner.bindings);
            if (winner.bindings.len == 0) continue;
            if (!same_binding(&winner.bindings[0], binding)) continue;
            try found.append(allocator, .{ .depth = depth, .ix = ix });
        }
        std.mem.sort(Match, found.items, {}, Match.less);
        const out = try allocator.alloc(KeyBinding, found.items.len);
        for (found.items, out) |m, *slot| slot.* = self.entries.items[m.ix];
        return out;
    }

    /// Bindings that dispatch `action` (by action type), newest first, skipping bindings disabled
    /// by a later `NoAction` on the same keystrokes. Caller frees the result.
    /// Note: matching is by action type only, not by payload.
    pub fn bindings_for_action(self: *const Keymap, allocator: Allocator, action: AnyAction) ![]KeyBinding {
        var out: std.ArrayList(KeyBinding) = .empty;
        errdefer out.deinit(allocator);
        for (self.entries.items, 0..) |*binding, ix| {
            if (binding.action.type_id != action.type_id) continue;
            if (action_mod.is_no_action(binding.action)) continue;
            var disabled = false;
            for (self.entries.items[ix + 1 ..]) |*later| {
                if (!action_mod.is_no_action(later.action)) continue;
                if (!same_keystrokes(later.keystrokes, binding.keystrokes)) continue;
                if (disabled_matches_context(later, binding)) {
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

    const single = keymap.binding_for(ks("ctrl-a"), &.{ kc("pane"), kc("editor") }).?;
    try testing.expect(is_action(single.*, ActionGamma));
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
    try testing.expect(keymap.binding_for(ks("ctrl-a"), &.{kc("barf")}) == null);
    try testing.expect(keymap.binding_for(ks("ctrl-a"), &.{kc("editor")}) != null);
    // Disabled in the more specific context.
    try testing.expect(keymap.binding_for(ks("ctrl-a"), &.{kc("editor mode=full")}) == null);
    // Globally disabled.
    try testing.expect(keymap.binding_for(ks("ctrl-b"), &.{kc("barf")}) == null);
    const r = try keymap.bindings_for_input(testing.allocator, &.{ks("ctrl-b")}, &.{kc("barf")});
    defer free_result(testing.allocator, r);
    try testing.expectEqual(@as(usize, 0), r.bindings.len);
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

test "keymap: NoAction in a deeper context does not disable a shallower binding" {
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
}

test "keymap: context precedence with same source" {
    const bindings = [_]KeyBinding{
        KeyBinding.new("cmd-r", ActionAlpha{}, "Workspace"),
        KeyBinding.new("cmd-r", ActionBeta{}, "Editor"),
    };
    var keymap = Keymap.init(testing.allocator);
    defer keymap.deinit();
    try keymap.add_bindings(&bindings);
    const r = try keymap.bindings_for_input(testing.allocator, &.{ks("cmd-r")}, &.{ kc("Workspace"), kc("Editor") });
    defer free_result(testing.allocator, r);
    try testing.expectEqual(@as(usize, 2), r.bindings.len);
    try testing.expect(is_action(r.bindings[0], ActionBeta));
    try testing.expect(is_action(r.bindings[1], ActionAlpha));
}

test "keymap: bindings_for_action respects later NoAction" {
    const bindings = [_]KeyBinding{
        KeyBinding.new("ctrl-a", ActionAlpha{}, "pane"),
        KeyBinding.new("ctrl-b", ActionBeta{}, "editor && mode == full"),
        KeyBinding.new("ctrl-c", ActionGamma{}, "workspace"),
        KeyBinding.new("ctrl-a", NoAction{}, "pane && active"),
        KeyBinding.new("ctrl-b", NoAction{}, "editor"),
    };
    var keymap = Keymap.init(testing.allocator);
    defer keymap.deinit();
    try keymap.add_bindings(&bindings);

    const alpha = try keymap.bindings_for_action(testing.allocator, box(ActionAlpha{}));
    defer testing.allocator.free(alpha);
    // The later NoAction is scoped to `pane && active`, which is narrower than `pane`, so it does
    // not cover the binding and the binding stays.
    try testing.expectEqual(@as(usize, 1), alpha.len);
    try testing.expectEqualStrings("a", alpha[0].keystrokes[0].key);

    const beta = try keymap.bindings_for_action(testing.allocator, box(ActionBeta{}));
    defer testing.allocator.free(beta);
    try testing.expectEqual(@as(usize, 0), beta.len);

    const gamma = try keymap.bindings_for_action(testing.allocator, box(ActionGamma{}));
    defer testing.allocator.free(gamma);
    try testing.expectEqual(@as(usize, 1), gamma.len);
    try testing.expectEqualStrings("c", gamma[0].keystrokes[0].key);
}

test "keymap: bindings_for_action ignores a targeted NoAction for a different keystroke" {
    const bindings = [_]KeyBinding{
        KeyBinding.new("tab", ActionAlpha{}, "Editor && edit_prediction"),
        KeyBinding.new("shift-tab", NoAction{}, "Editor"),
    };
    var keymap = Keymap.init(testing.allocator);
    defer keymap.deinit();
    try keymap.add_bindings(&bindings);
    const alpha = try keymap.bindings_for_action(testing.allocator, box(ActionAlpha{}));
    defer testing.allocator.free(alpha);
    try testing.expectEqual(@as(usize, 1), alpha.len);
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

test "keymap: possible_next_bindings excludes bindings that a NoAction disables" {
    const bindings = [_]KeyBinding{
        KeyBinding.new("ctrl-k a", ActionAlpha{}, "Editor"),
        KeyBinding.new("ctrl-k b", ActionBeta{}, "Editor"),
        KeyBinding.new("ctrl-k a", NoAction{}, "Editor"),
    };
    var keymap = Keymap.init(testing.allocator);
    defer keymap.deinit();
    try keymap.add_bindings(&bindings);
    const next = try keymap.possible_next_bindings_for_input(testing.allocator, &.{ks("ctrl-k")}, &.{kc("Editor")});
    defer testing.allocator.free(next);
    try testing.expectEqual(@as(usize, 1), next.len);
    try testing.expect(is_action(next[0], ActionBeta));
    try testing.expectEqualStrings("b", next[0].keystrokes[1].key);
}

test "keymap: possible_next_bindings drops a chord disabled in a deeper context" {
    const bindings = [_]KeyBinding{
        KeyBinding.new("space w w", ActionAlpha{}, "Workspace"),
        KeyBinding.new("space w x", ActionBeta{}, "Workspace"),
        KeyBinding.new("space w w", NoAction{}, "AgentPanel"),
    };
    var keymap = Keymap.init(testing.allocator);
    defer keymap.deinit();
    try keymap.add_bindings(&bindings);
    const contexts = [_]KeyContext{ kc("Workspace"), kc("AgentPanel") };
    for ([_][]const Keystroke{ &.{ks("space")}, &.{ ks("space"), ks("w") } }) |input| {
        const next = try keymap.possible_next_bindings_for_input(testing.allocator, input, &contexts);
        defer testing.allocator.free(next);
        try testing.expectEqual(@as(usize, 1), next.len);
        try testing.expect(is_action(next[0], ActionBeta));
    }
}

test "keymap: possible_next_bindings is empty when nothing extends the input" {
    const bindings = [_]KeyBinding{KeyBinding.new("ctrl-k a", ActionAlpha{}, "Editor")};
    var keymap = Keymap.init(testing.allocator);
    defer keymap.deinit();
    try keymap.add_bindings(&bindings);
    const next = try keymap.possible_next_bindings_for_input(testing.allocator, &.{ks("ctrl-k")}, &.{kc("Workspace")});
    defer testing.allocator.free(next);
    try testing.expectEqual(@as(usize, 0), next.len);
}

test "keymap: possible_next_bindings leaves out a binding that a deeper one with the same keys shadows" {
    const bindings = [_]KeyBinding{
        KeyBinding.new("ctrl-k a", ActionAlpha{}, "Workspace"),
        KeyBinding.new("ctrl-k a", ActionBeta{}, "Editor"),
        KeyBinding.new("ctrl-k b", ActionGamma{}, "Editor"),
    };
    var keymap = Keymap.init(testing.allocator);
    defer keymap.deinit();
    try keymap.add_bindings(&bindings);
    // Beta is deeper, so "ctrl-k a" dispatches Beta and Alpha can never be the next binding.
    // Beta itself is still a next binding: its own key completes it. Gamma comes first, being newer.
    const next = try keymap.possible_next_bindings_for_input(testing.allocator, &.{ks("ctrl-k")}, &.{ kc("Workspace"), kc("Editor") });
    defer testing.allocator.free(next);
    try testing.expectEqual(@as(usize, 2), next.len);
    try testing.expect(is_action(next[0], ActionGamma));
    try testing.expect(is_action(next[1], ActionBeta));
}

test "keymap: all_bindings_for_input ignores context and lists the newest first" {
    const bindings = [_]KeyBinding{
        KeyBinding.new("ctrl-a", ActionAlpha{}, "Workspace"),
        KeyBinding.new("ctrl-a", ActionBeta{}, "Editor"),
        KeyBinding.new("ctrl-b", ActionGamma{}, null),
        KeyBinding.new("ctrl-k a", ActionAlpha{}, null),
    };
    var keymap = Keymap.init(testing.allocator);
    defer keymap.deinit();
    try keymap.add_bindings(&bindings);

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

fn box(action: anytype) AnyAction {
    return action_mod.box_action(binding_allocator, action);
}
