//! xkbcommon bindings for layout-correct Wayland text (dlopen, never link).
//!
//! The evdev fallback in `input.zig` is US-QWERTY-only: on a German layout
//! evdev says `y` where the user pressed `z`. xkbcommon compiles the
//! compositor's keymap (sent over the `wl_keyboard.keymap` fd) and answers
//! per-key questions in the USER's layout: keysym for bindings, UTF-8 for
//! text. Pattern follows gpui_linux. `Compose` adds dead keys and the Compose key.
//!
//! Absent libxkbcommon, the backend falls back to the evdev tables, so
//! tests and minimal systems keep working.

const std = @import("std");
const dl = @import("dl.zig");

pub const xkb_lib_names: []const [*:0]const u8 = &.{ "libxkbcommon.so.0", "libxkbcommon.so" };

/// Minimal US keymap definitions for tests; includes resolve from the
/// system xkb database (absent database → compile fails → tests skip).
pub const us_test_keymap: [*:0]const u8 =
    \\xkb_keymap {
    \\  xkb_keycodes { include "evdev+aliases(qwerty)" };
    \\  xkb_types { include "complete" };
    \\  xkb_compat { include "complete" };
    \\  xkb_symbols { include "pc+us+inet(evdev)" };
    \\};
;

pub const Context = opaque {};
pub const Keymap = opaque {};
pub const State = opaque {};

pub const XKB_KEYMAP_FORMAT_TEXT_V1: c_uint = 1;
pub const XKB_KEYMAP_COMPILE_NO_FLAGS: c_uint = 0;
pub const XKB_KEY_DOWN: c_uint = 1;
pub const XKB_KEY_UP: c_uint = 0;

pub const XkbContextNewFn = *const fn (c_uint) callconv(.c) ?*Context;
pub const XkbContextUnrefFn = *const fn (*Context) callconv(.c) void;
pub const XkbKeymapNewFromStringFn = *const fn (*Context, [*:0]const u8, c_uint, c_uint) callconv(.c) ?*Keymap;
pub const XkbKeymapNewFromBufferFn = *const fn (*Context, [*]const u8, usize, c_uint, c_uint) callconv(.c) ?*Keymap;
pub const XkbKeymapUnrefFn = *const fn (*Keymap) callconv(.c) void;
pub const XkbStateNewFn = *const fn (*Keymap) callconv(.c) ?*State;
pub const XkbStateUnrefFn = *const fn (*State) callconv(.c) void;
pub const XkbStateUpdateKeyFn = *const fn (*State, u32, c_uint) callconv(.c) c_uint;
pub const XkbStateUpdateMaskFn = *const fn (*State, u32, u32, u32, u32, u32, u32) callconv(.c) c_uint;
pub const XkbStateKeyGetOneSymFn = *const fn (*State, u32) callconv(.c) u32;
pub const XkbStateKeyGetUtf8Fn = *const fn (*State, u32, [*]u8, usize) callconv(.c) c_int;

pub const XkbApi = struct {
    context_new: XkbContextNewFn,
    context_unref: XkbContextUnrefFn,
    keymap_new_from_string: XkbKeymapNewFromStringFn,
    keymap_new_from_buffer: XkbKeymapNewFromBufferFn,
    keymap_unref: XkbKeymapUnrefFn,
    state_new: XkbStateNewFn,
    state_unref: XkbStateUnrefFn,
    state_update_key: XkbStateUpdateKeyFn,
    state_update_mask: XkbStateUpdateMaskFn,
    state_key_get_one_sym: XkbStateKeyGetOneSymFn,
    state_key_get_utf8: XkbStateKeyGetUtf8Fn,

    pub fn load(lib: dl.Library) ?XkbApi {
        return .{
            .context_new = lib.lookup(XkbContextNewFn, "xkb_context_new") orelse return null,
            .context_unref = lib.lookup(XkbContextUnrefFn, "xkb_context_unref") orelse return null,
            .keymap_new_from_string = lib.lookup(XkbKeymapNewFromStringFn, "xkb_keymap_new_from_string") orelse return null,
            .keymap_new_from_buffer = lib.lookup(XkbKeymapNewFromBufferFn, "xkb_keymap_new_from_buffer") orelse return null,
            .keymap_unref = lib.lookup(XkbKeymapUnrefFn, "xkb_keymap_unref") orelse return null,
            .state_new = lib.lookup(XkbStateNewFn, "xkb_state_new") orelse return null,
            .state_unref = lib.lookup(XkbStateUnrefFn, "xkb_state_unref") orelse return null,
            .state_update_key = lib.lookup(XkbStateUpdateKeyFn, "xkb_state_update_key") orelse return null,
            .state_update_mask = lib.lookup(XkbStateUpdateMaskFn, "xkb_state_update_mask") orelse return null,
            .state_key_get_one_sym = lib.lookup(XkbStateKeyGetOneSymFn, "xkb_state_key_get_one_sym") orelse return null,
            .state_key_get_utf8 = lib.lookup(XkbStateKeyGetUtf8Fn, "xkb_state_key_get_utf8") orelse return null,
        };
    }

    pub fn isAvailable() bool {
        var lib = dl.Library.open(xkb_lib_names) orelse return false;
        defer lib.close();
        return load(lib) != null;
    }
};

// Keysyms (from xkbcommon-keysyms.h).
pub const XKB_KEY_NoSymbol: u32 = 0x000000;
pub const XKB_KEY_space: u32 = 0x0020;
pub const XKB_KEY_BackSpace: u32 = 0xff08;
pub const XKB_KEY_Tab: u32 = 0xff09;
pub const XKB_KEY_Return: u32 = 0xff0d;
pub const XKB_KEY_Escape: u32 = 0xff1b;
pub const XKB_KEY_Delete: u32 = 0xffff;
pub const XKB_KEY_Home: u32 = 0xff50;
pub const XKB_KEY_Left: u32 = 0xff51;
pub const XKB_KEY_Up: u32 = 0xff52;
pub const XKB_KEY_Right: u32 = 0xff53;
pub const XKB_KEY_Down: u32 = 0xff54;
pub const XKB_KEY_End: u32 = 0xff57;

/// Owned xkb lifecycle: library + context, with at most one keymap/state
/// pair replaced wholesale on every keymap event. All heap-free after init
/// (xkbcommon manages its own internals).
pub const Xkb = struct {
    lib: dl.Library,
    api: XkbApi,
    ctx: *Context,
    keymap: ?*Keymap = null,
    state: ?*State = null,

    pub fn init() !Xkb {
        var lib = dl.Library.open(xkb_lib_names) orelse return error.XkbUnavailable;
        errdefer lib.close();
        const api = XkbApi.load(lib) orelse return error.XkbSymbolsMissing;
        const ctx = api.context_new(0) orelse return error.XkbContextFailed;
        return .{ .lib = lib, .api = api, .ctx = ctx };
    }

    pub fn deinit(self: *Xkb) void {
        if (self.state) |s| self.api.state_unref(s);
        if (self.keymap) |k| self.api.keymap_unref(k);
        self.api.context_unref(self.ctx);
        self.lib.close();
    }

    pub fn hasLiveState(self: *const Xkb) bool {
        return self.state != null;
    }

    /// Compile a keymap from memory (the compositor fd is mmap'd by the
    /// caller) and swap it in, destroying the previous pair.
    pub fn setKeymapBuffer(self: *Xkb, bytes: [*]const u8, len: usize) !void {
        const keymap = self.api.keymap_new_from_buffer(self.ctx, bytes, len, XKB_KEYMAP_FORMAT_TEXT_V1, XKB_KEYMAP_COMPILE_NO_FLAGS) orelse return error.XkbKeymapFailed;
        errdefer self.api.keymap_unref(keymap);
        const state = self.api.state_new(keymap) orelse return error.XkbStateFailed;
        if (self.state) |s| self.api.state_unref(s);
        if (self.keymap) |k| self.api.keymap_unref(k);
        self.state = state;
        self.keymap = keymap;
    }

    /// Compile a NUL-terminated keymap (tests; same entry point as the fd
    /// path after mapping).
    pub fn setKeymapString(self: *Xkb, text: [*:0]const u8) !void {
        const keymap = self.api.keymap_new_from_string(self.ctx, text, XKB_KEYMAP_FORMAT_TEXT_V1, XKB_KEYMAP_COMPILE_NO_FLAGS) orelse return error.XkbKeymapFailed;
        errdefer self.api.keymap_unref(keymap);
        const state = self.api.state_new(keymap) orelse return error.XkbStateFailed;
        if (self.state) |s| self.api.state_unref(s);
        if (self.keymap) |k| self.api.keymap_unref(k);
        self.state = state;
        self.keymap = keymap;
    }

    pub fn updateKey(self: *Xkb, xkb_code: u32, down: bool) void {
        const st = self.state orelse return;
        _ = self.api.state_update_key(st, xkb_code, if (down) XKB_KEY_DOWN else XKB_KEY_UP);
    }

    pub fn syncModifiers(self: *Xkb, depressed: u32, latched: u32, locked: u32, group: u32) void {
        const st = self.state orelse return;
        _ = self.api.state_update_mask(st, depressed, latched, locked, group, 0, 0);
    }

    pub fn keysym(self: *Xkb, xkb_code: u32) u32 {
        const st = self.state orelse return XKB_KEY_NoSymbol;
        return self.api.state_key_get_one_sym(st, xkb_code);
    }

    /// UTF-8 text for a key in the current layout. Returns byte count (0 =
    /// no text, e.g. modifiers and dead keys). snprintf-like: pass NULL/0
    /// to query, but callers here always have a stack buffer.
    pub fn utf8(self: *Xkb, xkb_code: u32, out: []u8) usize {
        const st = self.state orelse return 0;
        const n = self.api.state_key_get_utf8(st, xkb_code, out.ptr, out.len);
        if (n <= 0) return 0;
        return @intCast(@min(n, out.len));
    }
};

pub const ComposeTable = opaque {};
pub const ComposeState = opaque {};

/// Result of feeding one pressed key to the compose state machine.
pub const ComposeResult = union(enum) {
    /// The key is not part of a sequence.
    nothing,
    /// A sequence is in progress; the key produces no text yet.
    composing,
    /// A sequence finished with this text, stored in the buffer passed to `feed`.
    composed: []const u8,
    /// The key broke a sequence. It has been fed again, so it may start a new one.
    cancelled,
};

/// Dead keys and the Compose key (libxkbcommon's compose API). It works on keysyms,
/// so both the Wayland and the X11 backends use it. Absent a table for the locale,
/// `init` returns null and keys simply produce their own text.
pub const Compose = struct {
    lib: dl.Library,
    ctx: *Context,
    table: *ComposeTable,
    state: *ComposeState,
    context_unref: XkbContextUnrefFn,
    table_unref: *const fn (*ComposeTable) callconv(.c) void,
    state_unref: *const fn (*ComposeState) callconv(.c) void,
    state_feed: *const fn (*ComposeState, u32) callconv(.c) c_uint,
    state_reset: *const fn (*ComposeState) callconv(.c) void,
    state_get_status: *const fn (*ComposeState) callconv(.c) c_uint,
    state_get_utf8: *const fn (*ComposeState, [*]u8, usize) callconv(.c) c_int,

    const status_composing = 1;
    const status_composed = 2;
    const status_cancelled = 3;

    /// Uses the POSIX locale precedence, like SDL3 (GPUI reads only LC_CTYPE, which most
    /// systems leave unset, and then gets the C table without dead-key sequences).
    pub fn init() ?Compose {
        const locale: [*:0]const u8 = std.c.getenv("LC_ALL") orelse std.c.getenv("LC_CTYPE") orelse std.c.getenv("LANG") orelse "C";
        return init_locale(locale);
    }

    pub fn init_locale(locale: [*:0]const u8) ?Compose {
        var lib = dl.Library.open(xkb_lib_names) orelse return null;
        const context_new = lib.lookup(XkbContextNewFn, "xkb_context_new");
        const context_unref = lib.lookup(XkbContextUnrefFn, "xkb_context_unref");
        const table_new = lib.lookup(*const fn (*Context, [*:0]const u8, c_uint) callconv(.c) ?*ComposeTable, "xkb_compose_table_new_from_locale");
        const table_unref = lib.lookup(*const fn (*ComposeTable) callconv(.c) void, "xkb_compose_table_unref");
        const state_new = lib.lookup(*const fn (*ComposeTable, c_uint) callconv(.c) ?*ComposeState, "xkb_compose_state_new");
        const state_unref = lib.lookup(*const fn (*ComposeState) callconv(.c) void, "xkb_compose_state_unref");
        const state_feed = lib.lookup(*const fn (*ComposeState, u32) callconv(.c) c_uint, "xkb_compose_state_feed");
        const state_reset = lib.lookup(*const fn (*ComposeState) callconv(.c) void, "xkb_compose_state_reset");
        const state_get_status = lib.lookup(*const fn (*ComposeState) callconv(.c) c_uint, "xkb_compose_state_get_status");
        const state_get_utf8 = lib.lookup(*const fn (*ComposeState, [*]u8, usize) callconv(.c) c_int, "xkb_compose_state_get_utf8");
        const fail = context_new == null or context_unref == null or table_new == null or table_unref == null or state_new == null or state_unref == null or state_feed == null or state_reset == null or state_get_status == null or state_get_utf8 == null;
        if (fail) {
            lib.close();
            return null;
        }
        const ctx = context_new.?(0) orelse {
            lib.close();
            return null;
        };
        const table = table_new.?(ctx, locale, 0) orelse {
            context_unref.?(ctx);
            lib.close();
            return null;
        };
        const state = state_new.?(table, 0) orelse {
            table_unref.?(table);
            context_unref.?(ctx);
            lib.close();
            return null;
        };
        return .{
            .lib = lib,
            .ctx = ctx,
            .table = table,
            .state = state,
            .context_unref = context_unref.?,
            .table_unref = table_unref.?,
            .state_unref = state_unref.?,
            .state_feed = state_feed.?,
            .state_reset = state_reset.?,
            .state_get_status = state_get_status.?,
            .state_get_utf8 = state_get_utf8.?,
        };
    }

    pub fn deinit(self: *Compose) void {
        self.state_unref(self.state);
        self.table_unref(self.table);
        self.context_unref(self.ctx);
        self.lib.close();
    }

    /// Abandons a sequence in progress (focus left the window).
    pub fn reset(self: *Compose) void {
        self.state_reset(self.state);
    }

    /// Feeds a pressed, non-modifier keysym. Composed text is written to `out`.
    pub fn feed(self: *Compose, keysym: u32, out: []u8) ComposeResult {
        _ = self.state_feed(self.state, keysym);
        switch (self.state_get_status(self.state)) {
            status_composing => return .composing,
            status_composed => {
                const n = self.state_get_utf8(self.state, out.ptr, out.len);
                if (n <= 0 or n >= out.len) return .nothing;
                return .{ .composed = out[0..@intCast(n)] };
            },
            status_cancelled => {
                // As in GPUI: the breaking key may itself begin a new sequence.
                _ = self.state_feed(self.state, keysym);
                return .cancelled;
            },
            else => return .nothing,
        }
    }
};

const test_dead_acute: u32 = 0xfe51;

test "compose turns a dead key and a letter into one character" {
    var compose = Compose.init_locale("en_US.UTF-8") orelse return error.SkipZigTest;
    defer compose.deinit();
    var buf: [32]u8 = undefined;
    try std.testing.expect(compose.feed(test_dead_acute, &buf) == .composing);
    const result = compose.feed('e', &buf);
    try std.testing.expect(result == .composed);
    try std.testing.expectEqualStrings("\u{e9}", result.composed);
    // Plain keys pass through afterwards.
    try std.testing.expect(compose.feed('e', &buf) == .nothing);
}

test "compose reports a broken sequence and restarts from the breaking key" {
    var compose = Compose.init_locale("en_US.UTF-8") orelse return error.SkipZigTest;
    defer compose.deinit();
    var buf: [32]u8 = undefined;
    try std.testing.expect(compose.feed(test_dead_acute, &buf) == .composing);
    // A digit cannot follow a dead acute.
    try std.testing.expect(compose.feed(0xff51, &buf) == .cancelled);
    try std.testing.expect(compose.feed('e', &buf) == .nothing);
    // Focus loss abandons a sequence.
    try std.testing.expect(compose.feed(test_dead_acute, &buf) == .composing);
    compose.reset();
    try std.testing.expect(compose.feed('e', &buf) == .nothing);
}

test "xkb maps evdev keys through the compiled us keymap" {
    var x = Xkb.init() catch return error.SkipZigTest;
    defer x.deinit();
    x.setKeymapString(us_test_keymap) catch return error.SkipZigTest;
    // evdev 30 ('a' position) is xkb keycode 38.
    x.updateKey(38, true);
    try std.testing.expectEqual(@as(u32, 'a'), x.keysym(38));
    var buf: [4]u8 = undefined;
    try std.testing.expectEqualStrings("a", buf[0..x.utf8(38, &buf)]);
    x.updateKey(38, false);
}
