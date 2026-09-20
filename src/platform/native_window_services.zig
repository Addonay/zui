//! Window-scoped platform services shared by the Win32 and Cocoa adapters.
//!
//! This is deliberately a contract layer: it has no user32/AppKit calls and
//! can therefore be tested on Linux. Native adapters may use these types to
//! keep per-window state instead of routing it through process-global state.

const std = @import("std");
const geometry = @import("../core/geometry.zig");

pub const MAX_WINDOWS = 32;
pub const MAX_CLIPBOARD_BYTES = 64 * 1024;
pub const MAX_COMPOSITION_BYTES = 16 * 1024;

pub const WindowHandle = struct {
    native: usize,
    generation: u32,

    pub fn eql(self: @This(), other: @This()) bool {
        return self.native == other.native and self.generation == other.generation;
    }
};

pub const WindowSlot = struct {
    handle: WindowHandle,
    active: bool = true,
    focused: bool = false,
};

/// A fixed-capacity registry makes multi-window identity explicit while
/// keeping callback lookup allocation-free and deterministic.
pub const WindowRegistry = struct {
    slots: [MAX_WINDOWS]?WindowSlot = @splat(null),
    next_generation: u32 = 1,
    active: ?WindowHandle = null,

    pub fn register(self: *@This(), native: usize) !WindowHandle {
        if (native == 0) return error.InvalidHandle;
        for (self.slots) |slot| {
            if (slot) |entry| {
                if (entry.handle.native == native and entry.active) return error.AlreadyRegistered;
            }
        }
        for (&self.slots) |*slot| {
            if (slot.* == null) {
                const handle = WindowHandle{ .native = native, .generation = self.next_generation };
                self.next_generation +%= 1;
                if (self.next_generation == 0) self.next_generation = 1;
                slot.* = .{ .handle = handle };
                if (self.active == null) self.active = handle;
                return handle;
            }
        }
        return error.WindowLimit;
    }

    pub fn unregister(self: *@This(), handle: WindowHandle) bool {
        for (&self.slots) |*slot| {
            if (slot.*) |entry| {
                if (entry.handle.eql(handle)) {
                    slot.* = null;
                    if (self.active) |active| {
                        if (active.eql(handle)) self.active = self.firstActive();
                    }
                    return true;
                }
            }
        }
        return false;
    }

    pub fn setFocused(self: *@This(), handle: WindowHandle, focused: bool) bool {
        for (&self.slots) |*slot| {
            if (slot.*) |*entry| {
                if (entry.handle.eql(handle)) {
                    entry.focused = focused;
                    if (focused) self.active = handle;
                    return true;
                }
            }
        }
        return false;
    }

    pub fn contains(self: *const @This(), handle: WindowHandle) bool {
        for (self.slots) |slot| {
            if (slot) |entry| {
                if (entry.handle.eql(handle) and entry.active) return true;
            }
        }
        return false;
    }

    fn firstActive(self: *const @This()) ?WindowHandle {
        for (self.slots) |slot| {
            if (slot) |entry| {
                if (entry.active) return entry.handle;
            }
        }
        return null;
    }
};

pub const ClipboardFormat = enum { text_utf8, text_utf16, html, png };

pub const ClipboardState = struct {
    format: ClipboardFormat = .text_utf8,
    bytes: [MAX_CLIPBOARD_BYTES]u8 = undefined,
    len: usize = 0,
    available: bool = false,

    pub fn set(self: *@This(), format: ClipboardFormat, value: []const u8) !void {
        if (value.len > self.bytes.len) return error.PayloadTooLarge;
        @memcpy(self.bytes[0..value.len], value);
        self.format = format;
        self.len = value.len;
        self.available = true;
    }

    pub fn read(self: *const @This(), requested: ClipboardFormat, out: []u8) !usize {
        if (!self.available) return error.Unavailable;
        if (requested != self.format) return error.UnsupportedFormat;
        const n = @min(out.len, self.len);
        @memcpy(out[0..n], self.bytes[0..n]);
        return n;
    }
};

pub const ImeState = struct {
    enabled: bool = false,
    composing: bool = false,
    composition: [MAX_COMPOSITION_BYTES]u8 = undefined,
    composition_len: usize = 0,
    caret: geometry.Rect = .{},

    pub fn setComposition(self: *@This(), text: []const u8) !void {
        if (text.len > self.composition.len) return error.PayloadTooLarge;
        @memcpy(self.composition[0..text.len], text);
        self.composition_len = text.len;
        self.composing = text.len != 0;
    }

    pub fn compositionText(self: *const @This()) []const u8 {
        return self.composition[0..self.composition_len];
    }
};

pub const Cursor = enum { arrow, text, pointing_hand, resize_horizontal, resize_vertical, hidden };

pub const CursorState = struct {
    shape: Cursor = .arrow,
    visible: bool = true,

    pub fn set(self: *@This(), shape: Cursor) void {
        self.shape = shape;
        self.visible = shape != .hidden;
    }
};

pub const DpiState = struct {
    scale_factor: f32 = 1,

    pub fn setScale(self: *@This(), scale: f32) !void {
        if (std.math.isNan(scale) or std.math.isInf(scale) or scale < 0.25 or scale > 8) return error.InvalidScale;
        self.scale_factor = scale;
    }

    pub fn toPhysical(self: *const @This(), logical: f32) f32 {
        return logical * self.scale_factor;
    }

    pub fn toLogical(self: *const @This(), physical: f32) f32 {
        return physical / self.scale_factor;
    }
};

pub const Lifecycle = enum { created, active, inactive, background, closing, closed };

pub const PlatformServices = struct {
    handle: WindowHandle,
    clipboard: ClipboardState = .{},
    ime: ImeState = .{},
    cursor: CursorState = .{},
    dpi: DpiState = .{},
    lifecycle: Lifecycle = .created,

    pub fn nativeClipboard(_: *const @This()) error{Unsupported}!void {
        return error.Unsupported;
    }
    pub fn nativeIme(_: *const @This()) error{Unsupported}!void {
        return error.Unsupported;
    }
    pub fn nativeCursor(_: *const @This()) error{Unsupported}!void {
        return error.Unsupported;
    }
    pub fn nativeDpi(_: *const @This()) error{Unsupported}!void {
        return error.Unsupported;
    }
};

test "window registry keeps native handles and focus independent" {
    var registry = WindowRegistry{};
    const first = try registry.register(0x10);
    const second = try registry.register(0x20);
    try std.testing.expect(!first.eql(second));
    try std.testing.expect(registry.setFocused(second, true));
    try std.testing.expect(registry.active.?.eql(second));
    try std.testing.expect(registry.unregister(first));
    try std.testing.expect(!registry.contains(first));
    try std.testing.expect(registry.contains(second));
}

test "clipboard and IME state are bounded and window-local" {
    var services = PlatformServices{ .handle = .{ .native = 1, .generation = 1 } };
    try services.clipboard.set(.html, "<b>zui</b>");
    var out: [32]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 10), try services.clipboard.read(.html, &out));
    try std.testing.expectError(error.UnsupportedFormat, services.clipboard.read(.png, &out));
    try services.ime.setComposition("日本");
    try std.testing.expectEqualStrings("日本", services.ime.compositionText());
}

test "DPI and lifecycle state are deterministic" {
    var services = PlatformServices{ .handle = .{ .native = 2, .generation = 1 } };
    try services.dpi.setScale(1.5);
    try std.testing.expectApproxEqAbs(@as(f32, 15), services.dpi.toPhysical(10), 0.001);
    services.lifecycle = .active;
    try std.testing.expectEqual(Lifecycle.active, services.lifecycle);
    try std.testing.expectError(error.InvalidScale, services.dpi.setScale(0.1));
}
