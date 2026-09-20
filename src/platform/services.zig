//! GPUI-shaped platform services and the deterministic headless contract.
//!
//! This module deliberately stops at the platform boundary.  The null
//! implementation records portable state where that is meaningful and returns
//! `error.Unsupported` for operations that require an operating-system
//! service.  It must not pretend that a headless test exercised a native
//! dialog, compositor popup, screen capture provider, or drag-and-drop target.
//!
//! The public shapes are source-backed by the checked-in GPUI sources:
//! `platform.rs`, `platform/app_menu.rs`, `platform/popup.rs`, and
//! `platform/layer_shell.rs`.

const std = @import("std");
const geometry = @import("../core/geometry.zig");

pub const MAX_CLIPBOARD_ENTRIES: usize = 8;
pub const MAX_CLIPBOARD_BYTES: usize = 256 * 1024;
pub const MAX_MENU_ITEMS: usize = 64;
pub const MAX_PATHS: usize = 32;
pub const MAX_URL_BYTES: usize = 2048;
pub const MAX_NOTIFICATION_BYTES: usize = 512;

pub const ServiceError = error{
    Unsupported,
    InvalidOptions,
    CapacityExceeded,
    NotFound,
};

/// Clipboard MIME formats represented by GPUI's clipboard entries.
pub const ClipboardFormat = union(enum) {
    text,
    html,
    uri_list,
    image: ImageFormat,
    custom: []const u8,
};

pub const ImageFormat = enum { png, jpeg, webp, gif, svg, bmp, tiff, ico, pnm };

pub const ClipboardEntry = struct {
    format: ClipboardFormat,
    bytes: []const u8,
};

pub const ClipboardItem = struct {
    entries: []const ClipboardEntry,

    pub fn text(self: ClipboardItem) ?[]const u8 {
        for (self.entries) |entry| switch (entry.format) {
            .text => return entry.bytes,
            else => {},
        };
        return null;
    }

    pub fn isValid(self: ClipboardItem) bool {
        if (self.entries.len == 0 or self.entries.len > MAX_CLIPBOARD_ENTRIES) return false;
        var total: usize = 0;
        for (self.entries) |entry| {
            total = std.math.add(usize, total, entry.bytes.len) catch return false;
            if (total > MAX_CLIPBOARD_BYTES) return false;
            switch (entry.format) {
                .custom => |mime| if (mime.len == 0) return false,
                else => {},
            }
        }
        return true;
    }
};

pub const ClipboardReadError = error{ Unavailable, Denied, UnsupportedContent };

pub const PathPromptOptions = struct {
    files: bool = true,
    directories: bool = false,
    multiple: bool = false,
    prompt: ?[]const u8 = null,

    pub fn isValid(self: PathPromptOptions) bool {
        return (self.files or self.directories) and
            (!(self.multiple) or self.files or self.directories);
    }
};

pub const PathPromptResult = struct {
    paths: []const []const u8,
};

pub const Notification = struct {
    tag: []const u8,
    title: []const u8,
    body: []const u8,
};

pub const MenuItemKind = enum { separator, action, submenu, system_menu };

pub const MenuItem = struct {
    kind: MenuItemKind,
    label: []const u8 = "",
    action_id: u32 = 0,
    checked: bool = false,
    disabled: bool = false,
};

pub const Menu = struct {
    name: []const u8,
    items: []const MenuItem,
    disabled: bool = false,
};

pub const PopupAnchor = enum { center, top, bottom, left, right, top_left, bottom_left, top_right, bottom_right };
pub const PopupGravity = enum { center, top, bottom, left, right, top_left, bottom_left, top_right, bottom_right };
pub const PopupAdjustment = packed struct(u8) {
    slide_x: bool = false,
    slide_y: bool = false,
    flip_x: bool = false,
    flip_y: bool = false,
    resize_x: bool = false,
    resize_y: bool = false,
    _padding: u2 = 0,
};

pub const PopupOptions = struct {
    parent_window_id: u32,
    anchor_rect: geometry.Rect,
    anchor: PopupAnchor = .center,
    gravity: PopupGravity = .center,
    adjustment: PopupAdjustment = .{},
    offset: geometry.Point = .{ .x = 0, .y = 0 },
    grab: bool = false,
};

pub const Layer = enum { background, bottom, top, overlay };
pub const LayerAnchor = packed struct(u8) {
    top: bool = false,
    bottom: bool = false,
    left: bool = false,
    right: bool = false,
    _padding: u4 = 0,
};
pub const KeyboardInteractivity = enum { none, exclusive, on_demand };

pub const LayerShellOptions = struct {
    layer: Layer = .overlay,
    anchors: LayerAnchor = .{},
    exclusive_zone: i32 = 0,
    keyboard_interactivity: KeyboardInteractivity = .none,
    namespace: []const u8 = "zui",
};

pub const WindowAppearance = enum { light, vibrant_light, dark, vibrant_dark };
pub const WindowBackground = enum { opaque_background, plain_transparent, blurred, mica, mica_alt };
pub const WindowKind = enum { normal, popup, anchored_popup, floating, dialog, layer_shell };
pub const WindowOptions = struct {
    kind: WindowKind = .normal,
    appearance: WindowAppearance = .light,
    background: WindowBackground = .opaque_background,
    movable: bool = true,
    resizable: bool = true,
    minimizable: bool = true,
    focus: bool = true,
    show: bool = true,
    min_size: ?geometry.Size = null,
    app_id: ?[]const u8 = null,
};

pub const Cursor = enum {
    arrow,
    ibeam,
    crosshair,
    closed_hand,
    open_hand,
    pointing_hand,
    resize_left,
    resize_right,
    resize_left_right,
    resize_up,
    resize_down,
    resize_up_down,
    resize_diagonal,
    operation_not_allowed,
    drag_link,
    drag_copy,
    contextual_menu,
};

pub const ExternalDragPayload = struct {
    paths: []const []const u8 = &.{},
    text: ?[]const u8 = null,
    uri_list: ?[]const u8 = null,

    pub fn isValid(self: ExternalDragPayload) bool {
        return self.paths.len > 0 or self.text != null or self.uri_list != null;
    }
};

pub const ScreenCaptureSource = struct {
    id: u64,
    name: []const u8,
    is_display: bool,
};

pub const ScreenCaptureFrame = struct {
    source_id: u64,
    width: u32,
    height: u32,
    rgba: []const u8,
};

/// A deterministic, bounded platform service implementation for tests.
pub const NullPlatformServices = struct {
    appearance: WindowAppearance = .light,
    cursor: Cursor = .arrow,
    clipboard_storage: [MAX_CLIPBOARD_BYTES]u8 = undefined,
    clipboard_len: usize = 0,
    clipboard_is_set: bool = false,
    last_url_storage: [MAX_URL_BYTES]u8 = undefined,
    last_url_len: usize = 0,
    menu_count: usize = 0,
    notification_count: usize = 0,
    last_notification: ?Notification = null,

    pub fn setClipboard(self: *@This(), item: ClipboardItem) ServiceError!void {
        if (!item.isValid()) return error.InvalidOptions;
        // The null backend intentionally preserves only a text representation.
        // It still rejects non-text-only items instead of silently losing bytes.
        if (item.entries.len != 1 or item.entries[0].format != .text) return error.Unsupported;
        const bytes = item.entries[0].bytes;
        @memcpy(self.clipboard_storage[0..bytes.len], bytes);
        self.clipboard_len = bytes.len;
        self.clipboard_is_set = true;
    }

    pub fn readClipboard(self: *const @This(), out: []u8) ClipboardReadError!usize {
        if (!self.clipboard_is_set) return error.Unavailable;
        const n = @min(out.len, self.clipboard_len);
        @memcpy(out[0..n], self.clipboard_storage[0..n]);
        return n;
    }

    pub fn openUrl(self: *@This(), url: []const u8) ServiceError!void {
        if (url.len == 0 or url.len > MAX_URL_BYTES) return error.InvalidOptions;
        @memcpy(self.last_url_storage[0..url.len], url);
        self.last_url_len = url.len;
        // Recording is the deterministic contract; launching a browser is native.
    }

    pub fn lastUrl(self: *const @This()) []const u8 {
        return self.last_url_storage[0..self.last_url_len];
    }

    pub fn setMenus(self: *@This(), menus: []const Menu) ServiceError!void {
        if (menus.len > MAX_MENU_ITEMS) return error.CapacityExceeded;
        self.menu_count = menus.len;
    }

    pub fn setAppearance(self: *@This(), appearance: WindowAppearance) void {
        self.appearance = appearance;
    }

    pub fn setCursor(self: *@This(), cursor: Cursor) void {
        self.cursor = cursor;
    }

    pub fn showNotification(self: *@This(), notification: Notification) ServiceError!void {
        if (notification.tag.len > MAX_NOTIFICATION_BYTES or
            notification.title.len > MAX_NOTIFICATION_BYTES or
            notification.body.len > MAX_NOTIFICATION_BYTES) return error.InvalidOptions;
        self.notification_count += 1;
        self.last_notification = notification;
    }

    pub fn promptForPaths(_: *const @This(), options: PathPromptOptions) ServiceError!PathPromptResult {
        if (!options.isValid()) return error.InvalidOptions;
        return error.Unsupported;
    }

    pub fn promptForNewPath(_: *const @This(), directory: []const u8, suggested_name: ?[]const u8) ServiceError![]const u8 {
        if (directory.len == 0 or (suggested_name != null and suggested_name.?.len == 0)) return error.InvalidOptions;
        return error.Unsupported;
    }

    pub fn openPopup(_: *const @This(), options: PopupOptions) ServiceError!void {
        if (options.parent_window_id == 0) return error.InvalidOptions;
        return error.Unsupported;
    }

    pub fn openLayerShell(_: *const @This(), options: LayerShellOptions) ServiceError!void {
        if (options.namespace.len == 0) return error.InvalidOptions;
        return error.Unsupported;
    }

    pub fn screenCaptureSources(_: *const @This()) ServiceError![]const ScreenCaptureSource {
        return error.Unsupported;
    }

    pub fn startExternalDrag(_: *const @This(), payload: ExternalDragPayload) ServiceError!void {
        if (!payload.isValid()) return error.InvalidOptions;
        return error.Unsupported;
    }
};

test "null platform preserves text clipboard and rejects lossy formats" {
    var services = NullPlatformServices{};
    const text_entry = [_]ClipboardEntry{.{ .format = .text, .bytes = "hello" }};
    try services.setClipboard(.{ .entries = &text_entry });
    var out: [8]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 5), try services.readClipboard(&out));
    try std.testing.expectEqualStrings("hello", out[0..5]);
    const image_entry = [_]ClipboardEntry{.{ .format = .{ .image = .png }, .bytes = "PNG" }};
    try std.testing.expectError(error.Unsupported, services.setClipboard(.{ .entries = &image_entry }));
}

test "null platform records URL menus appearance cursor and notifications" {
    var services = NullPlatformServices{};
    try services.openUrl("https://example.test");
    try std.testing.expectEqualStrings("https://example.test", services.lastUrl());
    const items = [_]MenuItem{.{ .kind = .action, .label = "Open", .action_id = 7 }};
    const menus = [_]Menu{.{ .name = "File", .items = &items }};
    try services.setMenus(&menus);
    try std.testing.expectEqual(@as(usize, 1), services.menu_count);
    services.setAppearance(.dark);
    services.setCursor(.pointing_hand);
    try services.showNotification(.{ .tag = "build", .title = "Done", .body = "ok" });
    try std.testing.expectEqual(WindowAppearance.dark, services.appearance);
    try std.testing.expectEqual(Cursor.pointing_hand, services.cursor);
    try std.testing.expectEqual(@as(usize, 1), services.notification_count);
}

test "null platform rejects invalid options and makes native gaps explicit" {
    var services = NullPlatformServices{};
    try std.testing.expectError(error.InvalidOptions, services.openUrl(""));
    try std.testing.expectError(error.InvalidOptions, services.promptForPaths(.{ .files = false, .directories = false }));
    try std.testing.expectError(error.Unsupported, services.promptForPaths(.{ .files = true }));
    try std.testing.expectError(error.InvalidOptions, services.openPopup(.{ .parent_window_id = 0, .anchor_rect = .{} }));
    try std.testing.expectError(error.Unsupported, services.openLayerShell(.{}));
    try std.testing.expectError(error.Unsupported, services.screenCaptureSources());
    try std.testing.expectError(error.InvalidOptions, services.startExternalDrag(.{}));
    try std.testing.expectError(error.Unsupported, services.startExternalDrag(.{ .text = "copy me" }));
}

test "clipboard and external drag contracts validate bounded payloads" {
    var services = NullPlatformServices{};
    var too_many: [MAX_CLIPBOARD_ENTRIES + 1]ClipboardEntry = undefined;
    for (&too_many) |*entry| entry.* = .{ .format = .text, .bytes = "x" };
    try std.testing.expectError(error.InvalidOptions, services.setClipboard(.{ .entries = &too_many }));
    try std.testing.expect(!(ExternalDragPayload{}).isValid());
    try std.testing.expect((ExternalDragPayload{ .paths = &.{"/tmp/a"} }).isValid());
}
