//! Port of GPUI `platform.rs`: the `Platform` and `PlatformWindow`
//! interfaces implemented by each OS backend, plus shared platform types.
//!
//! Backends embed a `Platform` / `PlatformWindow` value and recover their
//! own state with `@fieldParentPtr`.

const std = @import("std");
const builtin = @import("builtin");
const geometry = @import("geometry.zig");
const style_mod = @import("style.zig");
const scene_mod = @import("scene.zig");
const atlas_mod = @import("atlas.zig");
const interactive = @import("interactive.zig");
const window_mod = @import("window.zig");
const app_mod = @import("app.zig");
const keystroke_mod = @import("keystroke.zig");
const action_mod = @import("action.zig");
pub const app_menu = @import("platform/app_menu.zig");
pub const popup = @import("platform/popup.zig");
const window_controls_mod = @import("platform/window_controls.zig");

pub const PopupOptions = popup.PopupOptions;
pub const PopupAnchor = popup.PopupAnchor;
pub const PopupGravity = popup.PopupGravity;
pub const PopupConstraintAdjustment = popup.PopupConstraintAdjustment;
pub const PopupNotSupportedError = popup.PopupNotSupportedError;
pub const WindowControls = window_controls_mod.WindowControls;
pub const WindowButton = window_controls_mod.WindowButton;
pub const WindowButtonLayout = window_controls_mod.WindowButtonLayout;

/// The operating system's preference for energy use versus performance (GPUI `PowerMode`).
pub const PowerMode = enum {
    /// The platform cannot determine the mode, or cannot distinguish the active mode from other
    /// non-low-power modes.
    unknown,
    /// The system prioritizes reducing energy use.
    low_power,
    /// The system balances energy use and performance.
    balanced,
    /// The system prioritizes performance over energy use.
    high_power,
};

/// Called when the power mode changes. The platform keeps it for as long as it runs.
pub const PowerListener = struct {
    ctx: *anyopaque,
    func: *const fn (*anyopaque) void,
};
/// Called on the main thread when the displays may have changed (GPUI `on_displays_changed`).
pub const Listener = struct {
    ctx: *anyopaque,
    func: *const fn (*anyopaque) void,
};

/// Called with the action picked from the application menu (GPUI `on_app_menu_action`).
pub const ActionListener = struct {
    ctx: *anyopaque,
    func: *const fn (*anyopaque, action_mod.AnyAction) void,
};

/// Says whether a menu command can run now (GPUI `on_validate_app_menu_command`).
pub const ActionValidator = struct {
    ctx: *anyopaque,
    func: *const fn (*anyopaque, action_mod.AnyAction) bool,
};

pub const WindowControlArea = window_controls_mod.WindowControlArea;

const Pixels = geometry.Pixels;
const Point = geometry.Point;
const Size = geometry.Size;
const Bounds = geometry.Bounds;
const Window = window_mod.Window;
const App = app_mod.App;
pub const CursorStyle = style_mod.CursorStyle;

pub const DisplayId = u32;

/// A 16-byte UUID (GPUI's `uuid::Uuid`, as `PlatformDisplay::uuid` returns).
pub const Uuid = [16]u8;

/// The DNS namespace of RFC 4122 appendix C (`Uuid::NAMESPACE_DNS`).
pub const uuid_namespace_dns: Uuid = .{ 0x6b, 0xa7, 0xb8, 0x10, 0x9d, 0xad, 0x11, 0xd1, 0x80, 0xb4, 0x00, 0xc0, 0x4f, 0xd4, 0x30, 0xc8 };

/// A name-based UUID, version 5 (RFC 4122 section 4.3), as GPUI's `Uuid::new_v5` makes it.
/// Deliberately naive: it hashes with the std SHA-1 on every call. Displays call it once, when
/// the outputs are read, so nothing needs it faster yet.
pub fn uuid_v5(namespace: Uuid, name: []const u8) Uuid {
    var hasher = std.crypto.hash.Sha1.init(.{});
    hasher.update(&namespace);
    hasher.update(name);
    var digest: [20]u8 = undefined;
    hasher.final(&digest);
    var out: Uuid = digest[0..16].*;
    out[6] = (out[6] & 0x0f) | 0x50;
    out[8] = (out[8] & 0x3f) | 0x80;
    return out;
}

test "uuid_v5 matches the RFC 4122 example for python.org" {
    const got = uuid_v5(uuid_namespace_dns, "python.org");
    const want: Uuid = .{ 0x88, 0x63, 0x13, 0xe1, 0x3b, 0x8a, 0x53, 0x72, 0x9b, 0x90, 0x0c, 0x9a, 0xee, 0x19, 0x9e, 0x5d };
    try std.testing.expectEqualSlices(u8, &want, &got);
}

/// Window size GPUI opens a window at when the display is big enough (GPUI `DEFAULT_WINDOW_SIZE`).
pub const DEFAULT_WINDOW_SIZE: geometry.Size(Pixels) = .{ .width = 1536, .height = 1095 };

/// The time between a display's refreshes in nanoseconds, from its rate in hertz. Rejects the zero,
/// negative and non-finite rates platforms use to mean "unknown" (GPUI `refresh_interval_from_hz`).
pub fn refresh_interval_from_hz(hertz: f64) ?u64 {
    if (!std.math.isFinite(hertz) or hertz <= 0) return null;
    return @intFromFloat(1.0 / hertz * std.time.ns_per_s);
}

/// A physical display (GPUI `PlatformDisplay`).
pub const Display = struct {
    id: DisplayId,
    bounds: Bounds(Pixels),
    scale_factor: f32 = 1,
    name: []const u8 = "",
    /// The time between the display's refreshes in nanoseconds: the maximum rate for a variable
    /// refresh display. Null when the platform does not report it (GPUI `refresh_interval`).
    refresh_interval: ?u64 = null,
    /// The stable identifier `uuid` returns. Null when the platform gives the display no name.
    uuid_bytes: ?Uuid = null,

    /// A stable identifier that survives restarts (GPUI `PlatformDisplay::uuid`). Fails with
    /// `NoUuid` when the platform could not name the display.
    pub fn uuid(self: Display) error{NoUuid}!Uuid {
        return self.uuid_bytes orelse error.NoUuid;
    }

    /// The part of the display where windows may go, without taskbars and docks (GPUI
    /// `PlatformDisplay::visible_bounds`). No Linux backend reports a work area, so this is the
    /// full bounds there, which is what GPUI's default implementation gives.
    pub fn visible_bounds(self: Display) Bounds(Pixels) {
        return self.bounds;
    }

    /// The bounds a window gets when the app does not place it: `DEFAULT_WINDOW_SIZE`, clipped to
    /// the display and centered on it (GPUI `PlatformDisplay::default_bounds`).
    pub fn default_bounds(self: Display) Bounds(Pixels) {
        const clipped: geometry.Size(Pixels) = .{
            .width = @min(DEFAULT_WINDOW_SIZE.width, self.bounds.size.width),
            .height = @min(DEFAULT_WINDOW_SIZE.height, self.bounds.size.height),
        };
        return Bounds(Pixels).centered_at(self.bounds.center(), clipped);
    }
};

test "refresh_interval_from_hz converts rates and rejects unknown ones (GPUI test_refresh_interval_from_hz)" {
    try std.testing.expectEqual(@as(?u64, 20_000_000), refresh_interval_from_hz(50.0));
    try std.testing.expectEqual(@as(?u64, 8_333_333), refresh_interval_from_hz(120.0));
    for ([_]f64{ 0.0, -60.0, std.math.nan(f64), std.math.inf(f64) }) |unknown| {
        try std.testing.expectEqual(@as(?u64, null), refresh_interval_from_hz(unknown));
    }
}

test "uuid fails without a name and visible_bounds is the full bounds" {
    const named: Display = .{ .id = 0, .bounds = .{ .origin = .{ .x = 0, .y = 0 }, .size = .{ .width = 10, .height = 20 } }, .uuid_bytes = uuid_v5(uuid_namespace_dns, "x") };
    try std.testing.expectEqualSlices(u8, &uuid_v5(uuid_namespace_dns, "x"), &(try named.uuid()));
    const unnamed: Display = .{ .id = 1, .bounds = named.bounds };
    try std.testing.expectError(error.NoUuid, unnamed.uuid());
    try std.testing.expectEqual(named.bounds, named.visible_bounds());
}

test "default_bounds: 1536x1095 clipped to the display and centered on it" {
    const big: Display = .{ .id = 0, .bounds = .{ .origin = .{ .x = 0, .y = 0 }, .size = .{ .width = 1920, .height = 1080 } } };
    // Height is clipped to 1080, and the window is centered on (960, 540).
    const bounds = big.default_bounds();
    try std.testing.expectEqual(@as(f32, 192), bounds.origin.x);
    try std.testing.expectEqual(@as(f32, 0), bounds.origin.y);
    try std.testing.expectEqual(@as(f32, 1536), bounds.size.width);
    try std.testing.expectEqual(@as(f32, 1080), bounds.size.height);

    // A small display is filled exactly, from its top left corner.
    const small: Display = .{ .id = 1, .bounds = .{ .origin = .{ .x = 10, .y = 20 }, .size = .{ .width = 800, .height = 600 } } };
    const fill = small.default_bounds();
    try std.testing.expectEqual(@as(f32, 10), fill.origin.x);
    try std.testing.expectEqual(@as(f32, 20), fill.origin.y);
    try std.testing.expectEqual(@as(f32, 800), fill.size.width);
    try std.testing.expectEqual(@as(f32, 600), fill.size.height);
}

/// Whether the platform is presenting a window's frames (GPUI `WindowVisibility`). Hidden
/// while the window is minimized, fully covered (where the platform can tell), or suspended.
pub const WindowVisibility = enum {
    visible,
    hidden,

    /// Whether frames drawn for the window will be shown.
    pub fn is_visible(self: WindowVisibility) bool {
        return self == .visible;
    }
};

/// Which properties of a display changed (GPUI `DisplayChanges`).
pub const DisplayChanges = struct {
    /// The display's bounds changed.
    bounds: bool = false,

    pub fn is_empty(self: DisplayChanges) bool {
        return !self.bounds;
    }
};

/// A change to the connected displays (GPUI `DisplayEvent`).
pub const DisplayEvent = union(enum) {
    /// A display was connected.
    added: DisplayId,
    /// A display was disconnected. Windows on it are moved to another display by the platform.
    removed: DisplayId,
    /// A connected display's properties changed.
    changed: struct { id: DisplayId, changes: DisplayChanges },
};

/// Whether the application takes part in the system's foreground UI (GPUI `ActivationPolicy`).
/// Only macOS acts on it; other platforms accept and ignore it.
pub const ActivationPolicy = enum {
    /// Participate in foreground application UI, such as the Dock and menu bar on macOS.
    regular,
    /// Run without foreground application UI while retaining the ability to open windows.
    accessory,
};

/// The host operating system (GPUI `OperatingSystem`).
/// The same type as `keystroke.OperatingSystem`, so keystrokes can be displayed for the platform.
pub const OperatingSystem = keystroke_mod.OperatingSystem;

/// How the application is delivered (GPUI `PlatformTarget`).
pub const PlatformTarget = enum {
    /// A native application, including headless execution.
    native,
    /// An application running in a browser.
    web,
};

/// The host OS and application target (GPUI `PlatformInfo`).
pub const PlatformInfo = struct {
    os: OperatingSystem,
    target: PlatformTarget,

    pub fn is_mac(self: PlatformInfo) bool {
        return self.os == .mac;
    }

    /// The identity of the OS this binary was built for, as a native application.
    pub fn host() PlatformInfo {
        return .{ .os = switch (builtin.os.tag) {
            .macos => .mac,
            .windows => .windows,
            .freebsd => .free_bsd,
            .ios => .ios,
            .linux => if (builtin.abi == .android) .android else .linux,
            else => .unknown,
        }, .target = .native };
    }
};

/// The graphical session a platform is connected to (GPUI `GraphicalEnvironment`): the variables
/// that locate its display server, as some process sees them. Slices are borrowed.
pub const GraphicalEnvironment = struct {
    /// `WAYLAND_DISPLAY`: a socket name relative to `xdg_runtime_dir`, or an absolute path.
    wayland_display: ?[]const u8 = null,
    /// `DISPLAY`: the X11 display name.
    x11_display: ?[]const u8 = null,
    /// `XDG_RUNTIME_DIR`: the directory containing Wayland sockets.
    xdg_runtime_dir: ?[]const u8 = null,
    /// `XDG_ACTIVATION_TOKEN`: lets the first window take focus on Wayland.
    activation_token: ?[]const u8 = null,

    /// The compositor this environment selects: Wayland, then X11, then headless. Does not
    /// attempt to connect to it (GPUI `GraphicalEnvironment::guess_compositor`).
    pub fn guess_compositor(self: GraphicalEnvironment) []const u8 {
        if (is_set(self.wayland_display)) return "Wayland";
        if (is_set(self.x11_display)) return "X11";
        return "Headless";
    }

    fn is_set(value: ?[]const u8) bool {
        const v = value orelse return false;
        return v.len > 0;
    }
};

/// Reads the variable `name` from this process's environment, or null when it is unset (no GPUI
/// counterpart: GPUI reads the environment with `std::env::var_os`).
fn env_value(name: [*:0]const u8) ?[]const u8 {
    const v = std.c.getenv(name) orelse return null;
    return std.mem.span(v);
}

/// Reads the display variables from this process's environment (GPUI `GraphicalEnvironment::detect`).
/// Leaves `activation_token` unset: a token is used once, by the first window of the process that set it.
pub fn detect_graphical_environment() GraphicalEnvironment {
    return .{
        .wayland_display = env_value("WAYLAND_DISPLAY"),
        .x11_display = env_value("DISPLAY"),
        .xdg_runtime_dir = env_value("XDG_RUNTIME_DIR"),
    };
}

/// The windowing modes a platform may start in or switch to (GPUI `WindowingModes`, a bitflags set).
pub const WindowingModes = packed struct(u8) {
    /// Connected to a Wayland compositor.
    wayland: bool = false,
    /// Connected to an X server.
    x11: bool = false,
    /// No display server. Windows lay out and handle input but draw nothing.
    headless: bool = false,
    _padding: u5 = 0,

    pub const WAYLAND: WindowingModes = .{ .wayland = true };
    pub const X11: WindowingModes = .{ .x11 = true };
    pub const HEADLESS: WindowingModes = .{ .headless = true };

    /// Every mode (GPUI `WindowingModes::all`).
    pub fn all() WindowingModes {
        return .{ .wayland = true, .x11 = true, .headless = true };
    }

    /// The union of two sets (GPUI `WindowingModes::union`, the `|` operator).
    pub fn @"union"(self: WindowingModes, other: WindowingModes) WindowingModes {
        return @bitCast(@as(u8, @bitCast(self)) | @as(u8, @bitCast(other)));
    }

    /// Whether every mode in `other` is in `self` (GPUI `WindowingModes::contains`).
    pub fn contains(self: WindowingModes, other: WindowingModes) bool {
        const mine: u8 = @bitCast(self);
        const theirs: u8 = @bitCast(other);
        return mine & theirs == theirs;
    }
};

/// A display mode for `App.request_windowing` to switch to, or the mode a platform starts in (GPUI
/// `WindowingRequest`).
pub const WindowingRequest = union(enum) {
    /// No display server. Windows lay out and handle input but draw nothing.
    headless,
    /// Connected to the display server that the environment names.
    windowed: GraphicalEnvironment,
};

/// A `WindowingRequest` that owns its strings, for a request applied after the caller returned
/// (GPUI keeps the request's `GraphicalEnvironment` by value; ZUI's slices are borrowed, so they are
/// copied here). Free it with `deinit`.
///
/// Deliberately naive: every request copies its strings into one fresh allocation. A faster version
/// would keep the strings in a fixed buffer owned by the platform, which no request ever outgrows
/// in practice.
pub const OwnedWindowingRequest = struct {
    gpa: std.mem.Allocator,
    request: WindowingRequest,
    /// The copied strings of a windowed request, in one allocation (empty for headless).
    storage: []u8,

    /// Copies `request` (GPUI has no counterpart: it moves the request).
    pub fn dupe(gpa: std.mem.Allocator, request: WindowingRequest) std.mem.Allocator.Error!OwnedWindowingRequest {
        switch (request) {
            .headless => return .{ .gpa = gpa, .request = .headless, .storage = try gpa.alloc(u8, 0) },
            .windowed => |env| {
                const fields = [_]?[]const u8{ env.wayland_display, env.x11_display, env.xdg_runtime_dir, env.activation_token };
                var total: usize = 0;
                for (fields) |field| total += if (field) |s| s.len else 0;
                const storage = try gpa.alloc(u8, total);
                var offset: usize = 0;
                const copied: GraphicalEnvironment = .{
                    .wayland_display = copy_into(storage, &offset, env.wayland_display),
                    .x11_display = copy_into(storage, &offset, env.x11_display),
                    .xdg_runtime_dir = copy_into(storage, &offset, env.xdg_runtime_dir),
                    .activation_token = copy_into(storage, &offset, env.activation_token),
                };
                return .{ .gpa = gpa, .request = .{ .windowed = copied }, .storage = storage };
            },
        }
    }

    fn copy_into(storage: []u8, offset: *usize, field: ?[]const u8) ?[]const u8 {
        const s = field orelse return null;
        const start = offset.*;
        @memcpy(storage[start .. start + s.len], s);
        offset.* += s.len;
        return storage[start..offset.*];
    }

    /// Frees the copied strings (no GPUI counterpart: Rust drops them).
    pub fn deinit(self: OwnedWindowingRequest) void {
        self.gpa.free(self.storage);
    }
};

test "WindowingModes: all, union and contains (GPUI WindowingModes)" {
    const all = WindowingModes.all();
    try std.testing.expect(all.contains(WindowingModes.HEADLESS));
    try std.testing.expect(all.contains(WindowingModes.WAYLAND.@"union"(WindowingModes.X11)));
    try std.testing.expect(!WindowingModes.HEADLESS.contains(WindowingModes.X11));
    try std.testing.expect(!WindowingModes.WAYLAND.contains(WindowingModes.WAYLAND.@"union"(WindowingModes.X11)));
}

test "OwnedWindowingRequest keeps its strings when the caller's buffer changes" {
    var buffer = "wayland-0".*;
    const environment: GraphicalEnvironment = .{ .wayland_display = &buffer };
    const owned = try OwnedWindowingRequest.dupe(std.testing.allocator, .{ .windowed = environment });
    defer owned.deinit();
    buffer[0] = 'x';
    try std.testing.expectEqualStrings("wayland-0", owned.request.windowed.wayland_display.?);
    try std.testing.expect(owned.request.windowed.x11_display == null);
}

/// A keyboard layout (GPUI `PlatformKeyboardLayout`).
pub const KeyboardLayout = struct {
    /// Unique to the layout.
    id: []const u8,
    /// For display, such as "English (US)".
    name: []const u8,
};

/// Maps key equivalents to the platform's representation (GPUI `PlatformKeyboardMapper`).
/// Linux and the headless platform use GPUI's `DummyKeyboardMapper`, which maps nothing.
pub const KeyboardMapper = struct {
    pub fn map_key_equivalent(self: KeyboardMapper, keystroke: keystroke_mod.Keystroke, use_key_equivalents: bool) keystroke_mod.Keystroke {
        _ = self;
        _ = use_key_equivalents;
        return keystroke;
    }
};

/// What the GPU renders with (GPUI `GpuSpecs`). Slices are owned by the platform.
pub const GpuSpecs = struct {
    /// Whether the GPU is really a fake (like `llvmpipe`) running on the CPU.
    is_software_emulated: bool = false,
    /// The name of the device, as reported by Vulkan.
    device_name: []const u8 = "",
    /// The name of the driver, as reported by Vulkan.
    driver_name: []const u8 = "",
    /// Further information about the driver, as reported by Vulkan.
    driver_info: []const u8 = "",
};

pub const WindowAppearance = enum {
    light,
    vibrant_light,
    dark,
    vibrant_dark,

    pub fn is_dark(self: WindowAppearance) bool {
        return self == .dark or self == .vibrant_dark;
    }
};

/// The edge or corner a window resize starts from (GPUI `ResizeEdge`).
pub const ResizeEdge = enum { top_left, top, top_right, right, bottom_right, bottom, bottom_left, left };

/// Which edges of a client-decorated window the compositor has tiled against (GPUI `Tiling`).
pub const Tiling = struct {
    top: bool = false,
    left: bool = false,
    right: bool = false,
    bottom: bool = false,

    pub fn tiled() Tiling {
        return .{ .top = true, .left = true, .right = true, .bottom = true };
    }

    pub fn is_tiled(self: Tiling) bool {
        return self.top or self.left or self.right or self.bottom;
    }
};

/// Who draws the window frame (GPUI `Decorations`). With `client`, the app draws its own
/// titlebar, borders and shadow, and calls `set_client_inset` for the shadow area.
pub const Decorations = union(enum) {
    server,
    client: struct { tiling: Tiling },
};

/// Clipboard contents (GPUI `ClipboardItem`), text only for now.
pub const ClipboardItem = struct {
    text_: []const u8,
    metadata: ?[]const u8 = null,

    pub fn new_string(s: []const u8) ClipboardItem {
        return .{ .text_ = s };
    }
    pub fn text(self: ClipboardItem) ?[]const u8 {
        return self.text_;
    }
};

pub const RequestFrameOptions = struct {
    require_presentation: bool = true,
    force_render: bool = false,
};

pub const DispatchEventResult = struct {
    propagate: bool = true,
    default_prevented: bool = false,
};

/// A UTF-8 byte range (`Range<usize>`).
pub const Range = struct {
    start: usize,
    end: usize,

    pub fn len(self: Range) usize {
        return self.end - self.start;
    }
    pub fn is_empty(self: Range) bool {
        return self.end <= self.start;
    }
};

pub const UTF16Selection = struct {
    range: Range,
    reversed: bool = false,
};

/// Automatic capitalization applied by software keyboards (GPUI `Autocapitalize`).
pub const Autocapitalize = enum { none, words, sentences, characters };

/// The action a software keyboard advertises on its confirm key (GPUI `TextInputAction`).
pub const TextInputAction = enum { unspecified, enter, done, go, next, previous, search, send };

/// Hints a text field gives the platform's input method (GPUI `TextInputConfiguration`).
pub const TextInputConfiguration = struct {
    /// Whether the platform may correct entered text automatically.
    autocorrect: bool = false,
    autocapitalize: Autocapitalize = .none,
    /// Whether software keyboards may offer word suggestions and spellcheck.
    suggestions: bool = false,
    input_action: TextInputAction = .unspecified,
};

/// Text input target (GPUI `PlatformInputHandler`), backed by an element's
/// `EntityInputHandler` implementation. Ranges are in UTF-16 code units, as in GPUI.
pub const PlatformInputHandler = struct {
    ctx: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        selected_text_range: *const fn (*anyopaque, ignore_disabled_input: bool, *Window, *App) ?UTF16Selection,
        marked_text_range: *const fn (*anyopaque, *Window, *App) ?Range,
        text_for_range: *const fn (*anyopaque, Range, adjusted: *?Range, *Window, *App) ?[]const u8,
        replace_text_in_range: *const fn (*anyopaque, ?Range, []const u8, *Window, *App) void,
        replace_and_mark_text_in_range: *const fn (*anyopaque, ?Range, []const u8, new_selected: ?Range, *Window, *App) void,
        unmark_text: *const fn (*anyopaque, *Window, *App) void,
        bounds_for_range: *const fn (*anyopaque, Range, *Window, *App) ?Bounds(Pixels),
        character_index_for_point: *const fn (*anyopaque, Point(Pixels), *Window, *App) ?usize,
        accepts_text_input: *const fn (*anyopaque, *Window, *App) bool,
        // Optional, as GPUI's trait defaults: a null entry behaves as the default does.
        paste: ?*const fn (*anyopaque, ClipboardItem, *Window, *App) void = null,
        selection_bounds_for_range: ?*const fn (*anyopaque, Range, Bounds(Pixels), *Window, *App) []const Bounds(Pixels) = null,
        set_selected_text_range: ?*const fn (*anyopaque, Range, *Window, *App) void = null,
        text_length_utf16: ?*const fn (*anyopaque, *Window, *App) ?usize = null,
        text_input_configuration: ?*const fn (*anyopaque, *Window, *App) TextInputConfiguration = null,
        text_input_editable_range: ?*const fn (*anyopaque, *Window, *App) ?Range = null,
    };

    /// Inserts clipboard contents at the caret (GPUI `paste`). Does nothing without a handler entry.
    pub fn paste(self: *PlatformInputHandler, item: ClipboardItem, window: *Window, cx: *App) void {
        const f = self.vtable.paste orelse return;
        f(self.ctx, item, window, cx);
    }
    /// Rectangles covering the selection, one per line or run (GPUI `selection_bounds_for_range`).
    /// Empty by default. The slice must live until the caller is done with it.
    pub fn selection_bounds_for_range(self: *PlatformInputHandler, range: Range, element_bounds: Bounds(Pixels), window: *Window, cx: *App) []const Bounds(Pixels) {
        const f = self.vtable.selection_bounds_for_range orelse return &.{};
        return f(self.ctx, range, element_bounds, window, cx);
    }
    /// Moves the selection (GPUI `set_selected_text_range`). Does nothing by default.
    pub fn set_selected_text_range(self: *PlatformInputHandler, range: Range, window: *Window, cx: *App) void {
        const f = self.vtable.set_selected_text_range orelse return;
        f(self.ctx, range, window, cx);
    }
    /// The length of the text in UTF-16 code units, or null if the handler does not say (GPUI `text_length_utf16`).
    pub fn text_length_utf16(self: *PlatformInputHandler, window: *Window, cx: *App) ?usize {
        const f = self.vtable.text_length_utf16 orelse return null;
        return f(self.ctx, window, cx);
    }
    /// Software keyboard hints (GPUI `text_input_configuration`). The defaults apply without a handler entry.
    pub fn text_input_configuration(self: *PlatformInputHandler, window: *Window, cx: *App) TextInputConfiguration {
        const f = self.vtable.text_input_configuration orelse return .{};
        return f(self.ctx, window, cx);
    }
    /// The range the user may edit, or null for no limit (GPUI `text_input_editable_range`).
    pub fn text_input_editable_range(self: *PlatformInputHandler, window: *Window, cx: *App) ?Range {
        const f = self.vtable.text_input_editable_range orelse return null;
        return f(self.ctx, window, cx);
    }

    pub fn selected_text_range(self: *PlatformInputHandler, ignore_disabled_input: bool, window: *Window, cx: *App) ?UTF16Selection {
        return self.vtable.selected_text_range(self.ctx, ignore_disabled_input, window, cx);
    }
    pub fn marked_text_range(self: *PlatformInputHandler, window: *Window, cx: *App) ?Range {
        return self.vtable.marked_text_range(self.ctx, window, cx);
    }
    pub fn text_for_range(self: *PlatformInputHandler, range: Range, adjusted: *?Range, window: *Window, cx: *App) ?[]const u8 {
        return self.vtable.text_for_range(self.ctx, range, adjusted, window, cx);
    }
    pub fn replace_text_in_range(self: *PlatformInputHandler, range: ?Range, text: []const u8, window: *Window, cx: *App) void {
        self.vtable.replace_text_in_range(self.ctx, range, text, window, cx);
    }
    pub fn replace_and_mark_text_in_range(self: *PlatformInputHandler, range: ?Range, text: []const u8, new_selected: ?Range, window: *Window, cx: *App) void {
        self.vtable.replace_and_mark_text_in_range(self.ctx, range, text, new_selected, window, cx);
    }
    pub fn unmark_text(self: *PlatformInputHandler, window: *Window, cx: *App) void {
        self.vtable.unmark_text(self.ctx, window, cx);
    }
    pub fn bounds_for_range(self: *PlatformInputHandler, range: Range, window: *Window, cx: *App) ?Bounds(Pixels) {
        return self.vtable.bounds_for_range(self.ctx, range, window, cx);
    }
    pub fn character_index_for_point(self: *PlatformInputHandler, point: Point(Pixels), window: *Window, cx: *App) ?usize {
        return self.vtable.character_index_for_point(self.ctx, point, window, cx);
    }
    pub fn accepts_text_input(self: *PlatformInputHandler, window: *Window, cx: *App) bool {
        return self.vtable.accepts_text_input(self.ctx, window, cx);
    }
    pub fn dispatch_input(self: *PlatformInputHandler, input: []const u8, window: *Window, cx: *App) void {
        self.replace_text_in_range(null, input, window, cx);
    }

    /// Where IME candidates should appear: the start of the composition on the caret's
    /// visual line, or else the selection's end. Port of `compute_ime_candidate_bounds`.
    pub fn selected_bounds(self: *PlatformInputHandler, window: *Window, cx: *App) ?Bounds(Pixels) {
        const marked = self.marked_text_range(window, cx);
        const selection = self.selected_text_range(true, window, cx) orelse return null;
        if (marked) |m| {
            var line_start = m.start;
            const caret = selection.range.end;
            if (self.bounds_for_range(.{ .start = caret, .end = caret }, window, cx)) |caret_bounds| {
                var i = caret;
                while (i > m.start) {
                    i -= 1;
                    const b = self.bounds_for_range(.{ .start = i, .end = i }, window, cx) orelse continue;
                    if (@abs(b.origin.y - caret_bounds.origin.y) > 0.1) {
                        line_start = i + 1;
                        break;
                    }
                }
            }
            return self.bounds_for_range(.{ .start = line_start, .end = line_start }, window, cx);
        }
        const offset = if (selection.reversed) selection.range.start else selection.range.end;
        return self.bounds_for_range(.{ .start = offset, .end = offset }, window, cx);
    }
};

/// What a platform's input method asks the focused text field to do (GPUI `ImeInput`).
pub const ImeInput = union(enum) {
    /// Replaces the composition, if any, or else the selection.
    insert_text: []const u8,
    /// Replaces the composition with new uncommitted text. `selected` is the caret or
    /// selection inside it, in UTF-16 code units; null leaves the caret at its end.
    set_marked_text: struct { text: []const u8, selected: ?Range = null },
    /// Accepts the composition as ordinary text.
    unmark_text,
    /// Removes the composition.
    delete_text,
};

/// How urgent a prompt is (GPUI `PromptLevel`).
pub const PromptLevel = enum {
    /// Something the user should know.
    info,
    /// A possible problem the user should be warned about.
    warning,
    /// A critical problem.
    critical,
};

/// A button of a prompt (GPUI `PromptButton`). Build one with a tagged literal,
/// `.{ .ok = "OK" }`, `.{ .cancel = "Cancel" }` or `.{ .other = "Later" }`, or let
/// `PromptButton.from` read a label the way GPUI reads `&str` answers.
pub const PromptButton = union(enum) {
    ok: []const u8,
    cancel: []const u8,
    other: []const u8,

    /// GPUI `From<&str>`: "ok" and "cancel" (any case) make the matching kind, labelled
    /// "OK" or "Cancel"; anything else is an ordinary button with that label.
    pub fn from(text: []const u8) PromptButton {
        if (std.ascii.eqlIgnoreCase(text, "ok")) return .{ .ok = "OK" };
        if (std.ascii.eqlIgnoreCase(text, "cancel")) return .{ .cancel = "Cancel" };
        return .{ .other = text };
    }

    pub fn label(self: PromptButton) []const u8 {
        return switch (self) {
            inline else => |l| l,
        };
    }

    pub fn is_cancel(self: PromptButton) bool {
        return std.meta.activeTag(self) == .cancel;
    }
};

/// Callbacks a window registers with its platform window.
pub const WindowCallbacks = struct {
    ctx: *anyopaque,
    request_frame: *const fn (*anyopaque, RequestFrameOptions) void,
    input: *const fn (*anyopaque, interactive.PlatformInput) DispatchEventResult,
    active_status_change: *const fn (*anyopaque, bool) void,
    hover_status_change: *const fn (*anyopaque, bool) void,
    resize: *const fn (*anyopaque, Size(Pixels), f32) void,
    /// The window's origin changed (GPUI `on_moved`). Wayland never reports this.
    moved: *const fn (*anyopaque) void,
    should_close: *const fn (*anyopaque) bool,
    close: *const fn (*anyopaque) void,
    appearance_changed: *const fn (*anyopaque) void,
    /// The titlebar button layout changed (GPUI `on_button_layout_changed`). Null where a window has none.
    button_layout_changed: ?*const fn (*anyopaque) void = null,
    ime: *const fn (*anyopaque, ImeInput) void,
    ime_area: *const fn (*anyopaque) ?Bounds(Pixels),
    /// The window's visibility may have changed (GPUI `on_visibility_change`). The window reads
    /// `PlatformWindow.visibility` again, so only changes are reported.
    visibility_changed: ?*const fn (*anyopaque) void = null,
    /// The window may be on another display, or that display changed (GPUI `on_display_changed`).
    display_changed: ?*const fn (*anyopaque) void = null,
};

/// What the platform reports to the app as a whole (GPUI's `on_keyboard_layout_change` callback).
/// Set once with `Platform.set_callbacks`. Displays use `Platform.on_displays_changed`.
pub const PlatformCallbacks = struct {
    ctx: *anyopaque,
    /// The current keyboard layout changed.
    keyboard_layout_changed: *const fn (*anyopaque) void,
};

/// The OS window interface (GPUI `PlatformWindow`).
pub const PlatformWindow = struct {
    vtable: *const VTable,
    callbacks: ?WindowCallbacks = null,
    input_handler_: ?PlatformInputHandler = null,

    pub const VTable = struct {
        bounds: *const fn (*PlatformWindow) Bounds(Pixels),
        content_size: *const fn (*PlatformWindow) Size(Pixels),
        scale_factor: *const fn (*PlatformWindow) f32,
        appearance: *const fn (*PlatformWindow) WindowAppearance = defaultAppearance,
        mouse_position: *const fn (*PlatformWindow) Point(Pixels) = defaultMousePosition,
        request_frame: *const fn (*PlatformWindow) void,
        draw: *const fn (*PlatformWindow, *const scene_mod.Scene) void,
        sprite_atlas: *const fn (*PlatformWindow) atlas_mod.PlatformAtlas,
        set_title: *const fn (*PlatformWindow, []const u8) void = noopStr,
        activate: *const fn (*PlatformWindow) void = noop,
        minimize: *const fn (*PlatformWindow) void = noop,
        zoom: *const fn (*PlatformWindow) void = noop,
        toggle_fullscreen: *const fn (*PlatformWindow) void = noop,
        /// Window state the compositor reports (GPUI `is_maximized`, `is_fullscreen`). Platforms
        /// that cannot tell answer false, as GPUI's test window does.
        is_maximized: *const fn (*PlatformWindow) bool = noFlag,
        is_fullscreen: *const fn (*PlatformWindow) bool = noFlag,
        /// GPUI `set_app_id`: the Wayland app id, or the X11 WM_CLASS.
        set_app_id: *const fn (*PlatformWindow, []const u8) void = noopStr,
        /// GPUI `request_decorations`: switches between server and client decorations where the
        /// platform can (Wayland's xdg-decoration). Other platforms keep what they have.
        request_decorations: *const fn (*PlatformWindow, window_mod.WindowDecorations) void = noopDecorations,
        start_window_move: *const fn (*PlatformWindow) void = noop,
        resize: *const fn (*PlatformWindow, Size(Pixels)) void = noopResize,
        close: *const fn (*PlatformWindow) void,
        update_ime_position: *const fn (*PlatformWindow, Bounds(Pixels)) void = noopIme,
        /// Whether a focused field wants text. Called on every change of focused field,
        /// with false first, because some protocols must be told about each field.
        update_ime_enabled: *const fn (*PlatformWindow, bool) void = noopImeEnabled,
        play_system_bell: *const fn (*PlatformWindow) void = noop,
        /// Who draws the frame, as decided for this window (GPUI `window_decorations`).
        window_decorations: *const fn (*PlatformWindow) Decorations = serverDecorations,
        /// Shadow area of a client-decorated window, in logical pixels (GPUI `set_client_inset`).
        set_client_inset: *const fn (*PlatformWindow, Pixels) void = noopInset,
        /// Whether the window surface is opaque, transparent or blurred behind (GPUI
        /// `set_background_appearance`). Each platform sets it from `WindowOptions.window_background`
        /// at creation. Required: a platform that cannot do it must say so by storing the value.
        set_background_appearance: *const fn (*PlatformWindow, window_mod.WindowBackgroundAppearance) void,
        background_appearance: *const fn (*PlatformWindow) window_mod.WindowBackgroundAppearance,
        /// Corner radii of the client-drawn window, so a blur matches its shape (GPUI
        /// `set_client_corner_radii`). Only the blur region uses them.
        set_client_corner_radii: *const fn (*PlatformWindow, geometry.Corners(Pixels)) void,
        start_window_resize: *const fn (*PlatformWindow, ResizeEdge) void = noopEdge,
        /// Asks the compositor for its window menu at a position (GPUI `show_window_menu`).
        show_window_menu: *const fn (*PlatformWindow, Point(Pixels)) void = noopPoint,
        /// Whether frames drawn for the window will be shown (GPUI `PlatformWindow::visibility`).
        visibility: *const fn (*PlatformWindow) WindowVisibility = defaultVisibility,
        /// The display the window is on, if the platform can tell (GPUI `PlatformWindow::display`).
        display_id: *const fn (*PlatformWindow) ?DisplayId = noDisplayId,
        /// The GPU the window renders with, if any (GPUI `gpu_specs`).
        gpu_specs: *const fn (*PlatformWindow) ?GpuSpecs = noGpuSpecs,
        /// What the window manager lets the window do (GPUI `PlatformWindow::window_controls`).
        window_controls: *const fn (*PlatformWindow) WindowControls = defaultWindowControls,
    };

    fn defaultWindowControls(_: *PlatformWindow) WindowControls {
        return .{};
    }
    pub fn window_controls(self: *PlatformWindow) WindowControls {
        return self.vtable.window_controls(self);
    }

    fn defaultVisibility(_: *PlatformWindow) WindowVisibility {
        return .visible;
    }
    fn noDisplayId(_: *PlatformWindow) ?DisplayId {
        return null;
    }
    fn noGpuSpecs(_: *PlatformWindow) ?GpuSpecs {
        return null;
    }
    pub fn visibility(self: *PlatformWindow) WindowVisibility {
        return self.vtable.visibility(self);
    }
    pub fn display_id(self: *PlatformWindow) ?DisplayId {
        return self.vtable.display_id(self);
    }
    pub fn gpu_specs(self: *PlatformWindow) ?GpuSpecs {
        return self.vtable.gpu_specs(self);
    }
    pub fn emit_visibility_changed(self: *PlatformWindow) void {
        if (self.callbacks) |c| if (c.visibility_changed) |f| f(c.ctx);
    }
    pub fn emit_display_changed(self: *PlatformWindow) void {
        if (self.callbacks) |c| if (c.display_changed) |f| f(c.ctx);
    }

    fn serverDecorations(_: *PlatformWindow) Decorations {
        return .server;
    }
    fn noopInset(_: *PlatformWindow, _: Pixels) void {}
    fn noopEdge(_: *PlatformWindow, _: ResizeEdge) void {}
    fn noFlag(_: *PlatformWindow) bool {
        return false;
    }
    fn noopDecorations(_: *PlatformWindow, _: window_mod.WindowDecorations) void {}

    pub fn is_maximized(self: *PlatformWindow) bool {
        return self.vtable.is_maximized(self);
    }
    pub fn is_fullscreen(self: *PlatformWindow) bool {
        return self.vtable.is_fullscreen(self);
    }
    pub fn set_app_id(self: *PlatformWindow, app_id: []const u8) void {
        self.vtable.set_app_id(self, app_id);
    }
    pub fn request_decorations(self: *PlatformWindow, decorations: window_mod.WindowDecorations) void {
        self.vtable.request_decorations(self, decorations);
    }
    fn noopPoint(_: *PlatformWindow, _: Point(Pixels)) void {}

    pub fn window_decorations(self: *PlatformWindow) Decorations {
        return self.vtable.window_decorations(self);
    }
    pub fn set_client_inset(self: *PlatformWindow, inset: Pixels) void {
        self.vtable.set_client_inset(self, inset);
    }
    pub fn set_background_appearance(self: *PlatformWindow, background: window_mod.WindowBackgroundAppearance) void {
        self.vtable.set_background_appearance(self, background);
    }
    pub fn background_appearance(self: *PlatformWindow) window_mod.WindowBackgroundAppearance {
        return self.vtable.background_appearance(self);
    }
    pub fn set_client_corner_radii(self: *PlatformWindow, radii: geometry.Corners(Pixels)) void {
        self.vtable.set_client_corner_radii(self, radii);
    }
    pub fn start_window_resize(self: *PlatformWindow, edge: ResizeEdge) void {
        self.vtable.start_window_resize(self, edge);
    }
    pub fn show_window_menu(self: *PlatformWindow, position: Point(Pixels)) void {
        self.vtable.show_window_menu(self, position);
    }

    fn defaultAppearance(_: *PlatformWindow) WindowAppearance {
        return .light;
    }
    fn defaultMousePosition(_: *PlatformWindow) Point(Pixels) {
        return .{ .x = 0, .y = 0 };
    }
    fn noop(_: *PlatformWindow) void {}
    fn noopStr(_: *PlatformWindow, _: []const u8) void {}
    fn noopResize(_: *PlatformWindow, _: Size(Pixels)) void {}
    fn noopImeEnabled(_: *PlatformWindow, _: bool) void {}
fn noopIme(_: *PlatformWindow, _: Bounds(Pixels)) void {}

    pub fn bounds(self: *PlatformWindow) Bounds(Pixels) {
        return self.vtable.bounds(self);
    }
    pub fn content_size(self: *PlatformWindow) Size(Pixels) {
        return self.vtable.content_size(self);
    }
    pub fn scale_factor(self: *PlatformWindow) f32 {
        return self.vtable.scale_factor(self);
    }
    pub fn appearance(self: *PlatformWindow) WindowAppearance {
        return self.vtable.appearance(self);
    }
    pub fn mouse_position(self: *PlatformWindow) Point(Pixels) {
        return self.vtable.mouse_position(self);
    }
    pub fn set_callbacks(self: *PlatformWindow, cbs: WindowCallbacks) void {
        self.callbacks = cbs;
    }
    pub fn request_frame(self: *PlatformWindow) void {
        self.vtable.request_frame(self);
    }
    pub fn draw(self: *PlatformWindow, scene: *const scene_mod.Scene) void {
        self.vtable.draw(self, scene);
    }
    pub fn sprite_atlas(self: *PlatformWindow) atlas_mod.PlatformAtlas {
        return self.vtable.sprite_atlas(self);
    }
    pub fn set_title(self: *PlatformWindow, title: []const u8) void {
        self.vtable.set_title(self, title);
    }
    pub fn activate(self: *PlatformWindow) void {
        self.vtable.activate(self);
    }
    pub fn minimize(self: *PlatformWindow) void {
        self.vtable.minimize(self);
    }
    pub fn zoom(self: *PlatformWindow) void {
        self.vtable.zoom(self);
    }
    pub fn toggle_fullscreen(self: *PlatformWindow) void {
        self.vtable.toggle_fullscreen(self);
    }
    pub fn start_window_move(self: *PlatformWindow) void {
        self.vtable.start_window_move(self);
    }
    pub fn resize(self: *PlatformWindow, size: Size(Pixels)) void {
        self.vtable.resize(self, size);
    }
    pub fn close(self: *PlatformWindow) void {
        self.vtable.close(self);
    }
    pub fn set_input_handler(self: *PlatformWindow, h: PlatformInputHandler) void {
        self.input_handler_ = h;
    }
    pub fn take_input_handler(self: *PlatformWindow) void {
        self.input_handler_ = null;
    }
    pub fn input_handler(self: *PlatformWindow) ?PlatformInputHandler {
        return self.input_handler_;
    }
    pub fn update_ime_position(self: *PlatformWindow, b: Bounds(Pixels)) void {
        self.vtable.update_ime_position(self, b);
    }

    // -- helpers for backends: forward OS events to the window ----------

    pub fn emit_request_frame(self: *PlatformWindow, opts: RequestFrameOptions) void {
        if (self.callbacks) |c| c.request_frame(c.ctx, opts);
    }
    pub fn emit_input(self: *PlatformWindow, event: interactive.PlatformInput) DispatchEventResult {
        if (self.callbacks) |c| return c.input(c.ctx, event);
        return .{};
    }
    pub fn emit_ime(self: *PlatformWindow, ime: ImeInput) void {
        if (self.callbacks) |c| c.ime(c.ctx, ime);
    }
    pub fn ime_area(self: *PlatformWindow) ?Bounds(Pixels) {
        if (self.callbacks) |c| return c.ime_area(c.ctx);
        return null;
    }
    pub fn play_system_bell(self: *PlatformWindow) void {
        self.vtable.play_system_bell(self);
    }
    pub fn update_ime_enabled(self: *PlatformWindow, enabled: bool) void {
        self.vtable.update_ime_enabled(self, enabled);
    }
    pub fn emit_active(self: *PlatformWindow, active: bool) void {
        if (self.callbacks) |c| c.active_status_change(c.ctx, active);
    }
    pub fn emit_hover(self: *PlatformWindow, hovered: bool) void {
        if (self.callbacks) |c| c.hover_status_change(c.ctx, hovered);
    }
    pub fn emit_resize(self: *PlatformWindow, size: Size(Pixels), scale: f32) void {
        if (self.callbacks) |c| c.resize(c.ctx, size, scale);
    }
    pub fn emit_moved(self: *PlatformWindow) void {
        if (self.callbacks) |c| c.moved(c.ctx);
    }
    pub fn emit_should_close(self: *PlatformWindow) bool {
        if (self.callbacks) |c| return c.should_close(c.ctx);
        return true;
    }
    pub fn emit_close(self: *PlatformWindow) void {
        if (self.callbacks) |c| c.close(c.ctx);
    }
    pub fn emit_appearance_changed(self: *PlatformWindow) void {
        if (self.callbacks) |c| c.appearance_changed(c.ctx);
    }
    pub fn emit_button_layout_changed(self: *PlatformWindow) void {
        if (self.callbacks) |c| {
            if (c.button_layout_changed) |changed| changed(c.ctx);
        }
    }
};

/// The OS application interface (GPUI `Platform`).
pub const Platform = struct {
    vtable: *const VTable,
    callbacks: ?PlatformCallbacks = null,
    /// Set by `on_displays_changed`; the platform keeps it for as long as it runs.
    displays_changed_: ?Listener = null,
    /// Set by `on_app_menu_action`.
    app_menu_action_: ?ActionListener = null,
    /// Set by `on_will_open_app_menu`.
    will_open_app_menu_: ?Listener = null,
    /// Set by `on_validate_app_menu_command`.
    validate_app_menu_command_: ?ActionValidator = null,

    pub const VTable = struct {
        /// Runs the event loop until quit, calling `on_launch(app)` once ready.
        run: *const fn (*Platform, *App, *const fn (*anyopaque) void) void,
        quit: *const fn (*Platform) void,
        deinit: *const fn (*Platform) void,
        /// `parent` is the window a popup is anchored to (GPUI `WindowParams` resolves it from
        /// `WindowKind::AnchoredPopup`); null for every other kind.
        open_window: *const fn (*Platform, window_mod.WindowOptions, ?*PlatformWindow) anyerror!*PlatformWindow,
        /// The titlebar button layout (GPUI `Platform::button_layout`). Null where the platform has none.
        button_layout: *const fn (*Platform) ?WindowButtonLayout = noButtonLayout,
        /// Wakes the event loop from another thread (foreground executor).
        wake: *const fn (*Platform) void,
        activate: *const fn (*Platform, bool) void = noopBool,
        hide: *const fn (*Platform) void = noop,
        displays: *const fn (*Platform) []const Display = noDisplays,
        set_cursor_style: *const fn (*Platform, CursorStyle) void = noopCursor,
        write_to_clipboard: *const fn (*Platform, ClipboardItem) void = noopClip,
        read_from_clipboard: *const fn (*Platform) ?ClipboardItem = noClip,
        write_to_primary: *const fn (*Platform, ClipboardItem) void = noopClip,
        read_from_primary: *const fn (*Platform) ?ClipboardItem = noClip,
        open_url: *const fn (*Platform, []const u8) void = noopStr,
        quit_when_last_window_closes: *const fn (*Platform) bool = yes,
        /// Replaces the menu bar (GPUI `set_menus`). Platforms with no menu bar only store them.
        set_menus: *const fn (*Platform, []const app_menu.Menu) void = noopMenus,
        get_menus: *const fn (*Platform) ?[]const app_menu.OwnedMenu = noGetMenus,
        set_app_identity: *const fn (*Platform, []const u8, []const u8) void = noopIdentity,
        show_system_notification: *const fn (*Platform, SystemNotification) void = noopNotification,
        dismiss_system_notification: *const fn (*Platform, []const u8) void = noopStr,
        /// The host OS and target (GPUI `Platform::platform_info`). Defaults to the build's OS.
        platform_info: *const fn (*Platform) PlatformInfo = hostPlatformInfo,
        /// The current keyboard layout (GPUI `Platform::keyboard_layout`).
        keyboard_layout: *const fn (*Platform) KeyboardLayout = unknownKeyboardLayout,
        /// The compositor in use, for Linux (GPUI `Platform::compositor_name`). Empty elsewhere.
        compositor_name: *const fn (*Platform) []const u8 = noCompositorName,
        /// The display server's environment, or null while headless (GPUI `Platform::graphical_environment`).
        graphical_environment: *const fn (*Platform) ?GraphicalEnvironment = noGraphicalEnvironment,
        /// Front to back (GPUI `Platform::window_stack`). Null when the platform cannot say. The
        /// slice is valid until the next call.
        window_stack: *const fn (*Platform) ?[]const *PlatformWindow = noWindowStack,
        /// Hides the cursor until the mouse moves over one of the app's windows (GPUI `hide_cursor_until_mouse_moves`).
        hide_cursor_until_mouse_moves: *const fn (*Platform) void = noop,
        /// Whether the cursor is visible (GPUI `is_cursor_visible`).
        is_cursor_visible: *const fn (*Platform) bool = alwaysTrue,
        /// Whether the user wants scrollbars to hide themselves (GPUI `should_auto_hide_scrollbars`).
        should_auto_hide_scrollbars: *const fn (*Platform) bool = alwaysFalse,
        /// Sets the activation policy (GPUI `Platform::set_activation_policy`). Only macOS acts on it.
        set_activation_policy: *const fn (*Platform, ActivationPolicy) void = noopPolicy,
        hide_other_apps: *const fn (*Platform) void = noop,
        unhide_other_apps: *const fn (*Platform) void = noop,
        /// The window appearance the platform reports (GPUI `Platform::window_appearance`).
        window_appearance: *const fn (*Platform) WindowAppearance = lightAppearance,
        /// The current power mode (GPUI `Platform::power_mode`).
        power_mode: *const fn (*Platform) PowerMode = unknownPowerMode,
        /// Registers the listener for power mode changes (GPUI `Platform::on_power_mode_change`).
        on_power_mode_change: *const fn (*Platform, PowerListener) void = noPowerListener,
        /// Shows a file chooser for paths (GPUI `Platform::prompt_for_paths`). Answers once, through
        /// `completion`, possibly before this returns when the dialog cannot be shown.
        prompt_for_paths: *const fn (*Platform, PathPromptOptions, PathsCompletion) void = noPromptForPaths,
        /// Shows a save dialog (GPUI `Platform::prompt_for_new_path`).
        prompt_for_new_path: *const fn (*Platform, []const u8, ?[]const u8, PathCompletion) void = noPromptForNewPath,
        /// Whether one dialog may choose files and directories together (GPUI `can_select_mixed_files_and_dirs`).
        can_select_mixed_files_and_dirs: *const fn (*Platform) bool = alwaysFalse,
        /// Shows a path in the file manager (GPUI `Platform::reveal_path`).
        reveal_path: *const fn (*Platform, []const u8) void = noopStr,
        /// Opens a path with the system's default application (GPUI `Platform::open_with_system`).
        open_with_system: *const fn (*Platform, []const u8) void = noopStr,
        /// Starts the app again: the binary (null for this one) with the arguments (GPUI `Platform::restart`).
        restart: *const fn (*Platform, ?[]const u8, []const []const u8) void = noRestart,
        /// The path of this executable (GPUI `Platform::app_path`). Valid until the next call.
        app_path: *const fn (*Platform) anyerror![]const u8 = noAppPath,
        /// GPUI `Platform::path_for_auxiliary_executable`.
        path_for_auxiliary_executable: *const fn (*Platform, []const u8) anyerror![]const u8 = noAuxiliaryExecutable,
        /// GPUI `Platform::register_url_scheme`.
        register_url_scheme: *const fn (*Platform, []const u8) anyerror!void = noRegisterUrlScheme,
        /// Sets the mode the platform starts in, before `run` (GPUI `Platform::set_initial_windowing`).
        /// Platforms that cannot switch modes answer `error.WindowingNotSupported`.
        set_initial_windowing: *const fn (*Platform, WindowingRequest) anyerror!void = noSetInitialWindowing,
        /// Switches between headless and windowed modes (GPUI `Platform::request_windowing`). Called
        /// from the main thread between event-loop iterations, never from inside event dispatch.
        request_windowing: *const fn (*Platform, WindowingRequest) anyerror!void = noRequestWindowing,
    };

    fn noSetInitialWindowing(_: *Platform, _: WindowingRequest) anyerror!void {
        return error.WindowingNotSupported;
    }
    fn noRequestWindowing(_: *Platform, _: WindowingRequest) anyerror!void {
        return error.WindowingNotSupported;
    }

    fn lightAppearance(_: *Platform) WindowAppearance {
        return .light;
    }
    fn unknownPowerMode(_: *Platform) PowerMode {
        return .unknown;
    }
    fn noPowerListener(_: *Platform, _: PowerListener) void {}
    fn noPromptForPaths(_: *Platform, _: PathPromptOptions, completion: PathsCompletion) void {
        completion.call(error.PromptsNotSupported);
    }
    fn noPromptForNewPath(_: *Platform, _: []const u8, _: ?[]const u8, completion: PathCompletion) void {
        completion.call(error.PromptsNotSupported);
    }
    fn noRestart(_: *Platform, _: ?[]const u8, _: []const []const u8) void {}
    fn noAppPath(_: *Platform) anyerror![]const u8 {
        return error.NotSupported;
    }
    fn noAuxiliaryExecutable(_: *Platform, _: []const u8) anyerror![]const u8 {
        return error.NotSupported;
    }
    fn noRegisterUrlScheme(_: *Platform, _: []const u8) anyerror!void {
        return error.NotSupported;
    }

    fn hostPlatformInfo(_: *Platform) PlatformInfo {
        return PlatformInfo.host();
    }
    fn unknownKeyboardLayout(_: *Platform) KeyboardLayout {
        return .{ .id = "unknown", .name = "unknown" };
    }
    fn noCompositorName(_: *Platform) []const u8 {
        return "";
    }
    fn noGraphicalEnvironment(_: *Platform) ?GraphicalEnvironment {
        return null;
    }
    fn noWindowStack(_: *Platform) ?[]const *PlatformWindow {
        return null;
    }
    fn alwaysTrue(_: *Platform) bool {
        return true;
    }
    fn alwaysFalse(_: *Platform) bool {
        return false;
    }
    fn noopPolicy(_: *Platform, _: ActivationPolicy) void {}

    fn noopMenus(_: *Platform, _: []const app_menu.Menu) void {}
    fn noGetMenus(_: *Platform) ?[]const app_menu.OwnedMenu {
        return null;
    }
    fn noopIdentity(_: *Platform, _: []const u8, _: []const u8) void {}
    fn noopNotification(_: *Platform, _: SystemNotification) void {}

    fn noop(_: *Platform) void {}
    fn noopBool(_: *Platform, _: bool) void {}
    fn noopStr(_: *Platform, _: []const u8) void {}
    fn noopCursor(_: *Platform, _: CursorStyle) void {}
    fn noButtonLayout(_: *Platform) ?WindowButtonLayout {
        return null;
    }
    fn noopClip(_: *Platform, _: ClipboardItem) void {}
    fn noClip(_: *Platform) ?ClipboardItem {
        return null;
    }
    fn noDisplays(_: *Platform) []const Display {
        return &.{};
    }
    fn yes(_: *Platform) bool {
        return true;
    }

    pub fn run(self: *Platform, app: *App, on_launch: *const fn (*anyopaque) void) void {
        self.vtable.run(self, app, on_launch);
    }
    pub fn quit(self: *Platform) void {
        self.vtable.quit(self);
    }
    pub fn deinit(self: *Platform) void {
        self.vtable.deinit(self);
    }
    pub fn open_window(self: *Platform, options: window_mod.WindowOptions, parent: ?*PlatformWindow) !*PlatformWindow {
        return self.vtable.open_window(self, options, parent);
    }
    pub fn button_layout(self: *Platform) ?WindowButtonLayout {
        return self.vtable.button_layout(self);
    }
    pub fn power_mode(self: *Platform) PowerMode {
        return self.vtable.power_mode(self);
    }
    pub fn on_power_mode_change(self: *Platform, listener: PowerListener) void {
        self.vtable.on_power_mode_change(self, listener);
    }
    pub fn wake(self: *Platform) void {
        self.vtable.wake(self);
    }
    pub fn activate(self: *Platform, ignoring_other_apps: bool) void {
        self.vtable.activate(self, ignoring_other_apps);
    }
    pub fn hide(self: *Platform) void {
        self.vtable.hide(self);
    }
    pub fn displays(self: *Platform) []const Display {
        return self.vtable.displays(self);
    }
    pub fn primary_display(self: *Platform) ?Display {
        const ds = self.displays();
        return if (ds.len > 0) ds[0] else null;
    }
    pub fn set_cursor_style(self: *Platform, style: CursorStyle) void {
        self.vtable.set_cursor_style(self, style);
    }
    pub fn write_to_clipboard(self: *Platform, item: ClipboardItem) void {
        self.vtable.write_to_clipboard(self, item);
    }
    pub fn read_from_clipboard(self: *Platform) ?ClipboardItem {
        return self.vtable.read_from_clipboard(self);
    }
    /// The middle-click selection. Only Linux has one; elsewhere writes do nothing and reads give null.
    pub fn write_to_primary(self: *Platform, item: ClipboardItem) void {
        self.vtable.write_to_primary(self, item);
    }
    pub fn read_from_primary(self: *Platform) ?ClipboardItem {
        return self.vtable.read_from_primary(self);
    }
    pub fn open_url(self: *Platform, url: []const u8) void {
        self.vtable.open_url(self, url);
    }
    pub fn quit_when_last_window_closes(self: *Platform) bool {
        return self.vtable.quit_when_last_window_closes(self);
    }
    pub fn set_menus(self: *Platform, menus: []const app_menu.Menu) void {
        self.vtable.set_menus(self, menus);
    }
    pub fn get_menus(self: *Platform) ?[]const app_menu.OwnedMenu {
        return self.vtable.get_menus(self);
    }
    pub fn set_app_identity(self: *Platform, identifier: []const u8, name: []const u8) void {
        self.vtable.set_app_identity(self, identifier, name);
    }
    pub fn show_system_notification(self: *Platform, notification: SystemNotification) void {
        self.vtable.show_system_notification(self, notification);
    }
    pub fn dismiss_system_notification(self: *Platform, tag: []const u8) void {
        self.vtable.dismiss_system_notification(self, tag);
    }
    pub fn set_callbacks(self: *Platform, cbs: PlatformCallbacks) void {
        self.callbacks = cbs;
    }
    /// Registers the callback run when displays may have been added, removed or changed. Calls may
    /// be spurious: the app rereads `displays` (GPUI `Platform::on_displays_changed`). Replaces the
    /// earlier callback.
    pub fn on_displays_changed(self: *Platform, listener: Listener) void {
        self.displays_changed_ = listener;
    }

    /// Registers the callback run with the action picked from the application menu (GPUI
    /// `Platform::on_app_menu_action`). Replaces the earlier callback.
    pub fn on_app_menu_action(self: *Platform, listener: ActionListener) void {
        self.app_menu_action_ = listener;
    }

    /// Registers the callback run just before the application menu opens (GPUI
    /// `Platform::on_will_open_app_menu`). Replaces the earlier callback.
    pub fn on_will_open_app_menu(self: *Platform, listener: Listener) void {
        self.will_open_app_menu_ = listener;
    }

    /// Registers the callback that says whether a menu command can run now (GPUI
    /// `Platform::on_validate_app_menu_command`). Replaces the earlier callback.
    pub fn on_validate_app_menu_command(self: *Platform, validator: ActionValidator) void {
        self.validate_app_menu_command_ = validator;
    }

    /// Backends call this when the displays changed. Stands in for GPUI's displays callback.
    pub fn emit_displays_changed(self: *Platform) void {
        if (self.displays_changed_) |l| l.func(l.ctx);
    }

    /// Backends call this with the action a menu item picked. No Linux code calls it: GPUI's Linux
    /// backend stores its menu callbacks and never invokes them either.
    pub fn emit_app_menu_action(self: *Platform, action: action_mod.AnyAction) void {
        if (self.app_menu_action_) |l| l.func(l.ctx, action);
    }

    /// Backends call this before an application menu opens. No Linux code calls it yet.
    pub fn emit_will_open_app_menu(self: *Platform) void {
        if (self.will_open_app_menu_) |l| l.func(l.ctx);
    }

    /// Backends ask whether a menu command can run. False when no validator is registered, so a
    /// command is never offered without the app's say-so.
    pub fn emit_validate_app_menu_command(self: *Platform, action: action_mod.AnyAction) bool {
        const v = self.validate_app_menu_command_ orelse return false;
        return v.func(v.ctx, action);
    }

    /// Drops every listener the app registered, so the platform never calls into an app that is
    /// going away. No GPUI counterpart: GPUI's platforms are dropped with the app instead.
    pub fn clear_app_listeners(self: *Platform) void {
        self.callbacks = null;
        self.displays_changed_ = null;
        self.app_menu_action_ = null;
        self.will_open_app_menu_ = null;
        self.validate_app_menu_command_ = null;
    }
    pub fn emit_keyboard_layout_changed(self: *Platform) void {
        if (self.callbacks) |c| c.keyboard_layout_changed(c.ctx);
    }
    pub fn platform_info(self: *Platform) PlatformInfo {
        return self.vtable.platform_info(self);
    }
    pub fn keyboard_layout(self: *Platform) KeyboardLayout {
        return self.vtable.keyboard_layout(self);
    }
    pub fn compositor_name(self: *Platform) []const u8 {
        return self.vtable.compositor_name(self);
    }
    pub fn graphical_environment(self: *Platform) ?GraphicalEnvironment {
        return self.vtable.graphical_environment(self);
    }
    pub fn window_stack(self: *Platform) ?[]const *PlatformWindow {
        return self.vtable.window_stack(self);
    }
    pub fn hide_cursor_until_mouse_moves(self: *Platform) void {
        self.vtable.hide_cursor_until_mouse_moves(self);
    }
    pub fn is_cursor_visible(self: *Platform) bool {
        return self.vtable.is_cursor_visible(self);
    }
    pub fn should_auto_hide_scrollbars(self: *Platform) bool {
        return self.vtable.should_auto_hide_scrollbars(self);
    }
    pub fn set_activation_policy(self: *Platform, policy: ActivationPolicy) void {
        self.vtable.set_activation_policy(self, policy);
    }
    pub fn hide_other_apps(self: *Platform) void {
        self.vtable.hide_other_apps(self);
    }
    pub fn window_appearance(self: *Platform) WindowAppearance {
        return self.vtable.window_appearance(self);
    }
    pub fn prompt_for_paths(self: *Platform, options: PathPromptOptions, completion: PathsCompletion) void {
        self.vtable.prompt_for_paths(self, options, completion);
    }
    pub fn prompt_for_new_path(self: *Platform, directory: []const u8, suggested_name: ?[]const u8, completion: PathCompletion) void {
        self.vtable.prompt_for_new_path(self, directory, suggested_name, completion);
    }
    pub fn can_select_mixed_files_and_dirs(self: *Platform) bool {
        return self.vtable.can_select_mixed_files_and_dirs(self);
    }
    pub fn reveal_path(self: *Platform, path: []const u8) void {
        self.vtable.reveal_path(self, path);
    }
    pub fn open_with_system(self: *Platform, path: []const u8) void {
        self.vtable.open_with_system(self, path);
    }
    pub fn restart(self: *Platform, binary_path: ?[]const u8, arguments: []const []const u8) void {
        self.vtable.restart(self, binary_path, arguments);
    }
    pub fn app_path(self: *Platform) anyerror![]const u8 {
        return self.vtable.app_path(self);
    }
    pub fn path_for_auxiliary_executable(self: *Platform, name: []const u8) anyerror![]const u8 {
        return self.vtable.path_for_auxiliary_executable(self, name);
    }
    pub fn register_url_scheme(self: *Platform, scheme: []const u8) anyerror!void {
        return self.vtable.register_url_scheme(self, scheme);
    }
    pub fn unhide_other_apps(self: *Platform) void {
        self.vtable.unhide_other_apps(self);
    }
    /// Sets the mode the platform starts in (GPUI `Platform::set_initial_windowing`).
    pub fn set_initial_windowing(self: *Platform, request: WindowingRequest) anyerror!void {
        return self.vtable.set_initial_windowing(self, request);
    }
    /// Switches the platform's mode now (GPUI `Platform::request_windowing`; the App defers the call).
    pub fn request_windowing(self: *Platform, request: WindowingRequest) anyerror!void {
        return self.vtable.request_windowing(self, request);
    }
};

/// A system notification to post (GPUI `SystemNotification`).
pub const SystemNotification = struct {
    /// Posting a notification with the tag of an earlier one replaces it where supported.
    tag: []const u8,
    title: []const u8,
    body: []const u8,
    actions: []const SystemNotificationAction = &.{},
};

/// A button of a `SystemNotification` (GPUI `SystemNotificationAction`).
pub const SystemNotificationAction = struct {
    id: []const u8,
    label: []const u8,
};

/// What the user did with a notification (GPUI `SystemNotificationResponse`). `action_id` is
/// null when the notification body was clicked.
pub const SystemNotificationResponse = struct {
    tag: []const u8,
    action_id: ?[]const u8 = null,
};

/// The options of a file chooser (GPUI `PathPromptOptions`). `files` is accepted for parity; the
/// Linux portal chooses files or directories, as the options say.
pub const PathPromptOptions = struct {
    files: bool = true,
    directories: bool = false,
    multiple: bool = false,
    /// The label of the accept button.
    prompt: ?[]const u8 = null,
};

/// Receives the answer to `prompt_for_paths`: `null` when the user cancelled, an error when the
/// dialog could not be shown. The paths are valid during the call only.
pub const PathsCompletion = struct {
    ctx: *anyopaque,
    func: *const fn (*anyopaque, anyerror!?[]const []const u8) void,

    pub fn call(self: PathsCompletion, result: anyerror!?[]const []const u8) void {
        self.func(self.ctx, result);
    }
};

/// Receives the answer to `prompt_for_new_path`: the chosen path, `null` when cancelled.
pub const PathCompletion = struct {
    ctx: *anyopaque,
    func: *const fn (*anyopaque, anyerror!?[]const u8) void,

    pub fn call(self: PathCompletion, result: anyerror!?[]const u8) void {
        self.func(self.ctx, result);
    }
};

pub const headless = @import("platform/headless.zig");

/// The platform for the current OS (GPUI `gpui_platform::current_platform`). On Linux this is the
/// Linux platform allowing every windowing mode, which starts headless when the environment names no
/// display server and can switch to one later. Tests and `ZUI_HEADLESS` get the headless platform.
pub fn current_platform(allocator: std.mem.Allocator) *Platform {
    if (builtin.is_test) return headless_platform(allocator);
    if (std.c.getenv("ZUI_HEADLESS") != null) return headless_platform(allocator);
    if (builtin.os.tag == .linux) {
        if (linux_platform(allocator, WindowingModes.all())) |p| return p else |err| {
            std.log.warn("linux platform unavailable ({s}); running headless", .{@errorName(err)});
        }
    }
    return headless_platform(allocator);
}

/// The Linux platform, allowed to start or switch to the modes in `allowed_modes` (GPUI
/// `gpui_platform::linux`). Only Linux has one: other systems get `error.LinuxOnly`.
pub fn linux_platform(allocator: std.mem.Allocator, allowed_modes: WindowingModes) !*Platform {
    if (builtin.os.tag != .linux) return error.LinuxOnly;
    return @import("platform/linux.zig").create(allocator, allowed_modes);
}

/// A platform with no OS windows (tests, servers, snapshots).
pub fn headless_platform(allocator: std.mem.Allocator) *Platform {
    return headless.HeadlessPlatform.create(allocator);
}
