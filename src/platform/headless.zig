//! A platform with no OS windows, used for tests, snapshots and servers
//! (GPUI's `TestPlatform` / headless mode). Frames are rendered with the CPU
//! renderer into an in-memory framebuffer when one is requested.

const std = @import("std");
const geometry = @import("../geometry.zig");
const platform = @import("../platform.zig");
const scene_mod = @import("../scene.zig");
const atlas_mod = @import("../atlas.zig");
const app_mod = @import("../app.zig");
const window_mod = @import("../window.zig");

const Platform = platform.Platform;
const PlatformWindow = platform.PlatformWindow;
const Pixels = geometry.Pixels;

pub const HeadlessPlatform = struct {
    allocator: std.mem.Allocator,
    platform: Platform = .{ .vtable = &vtable },
    windows: std.ArrayList(*HeadlessWindow) = .empty,
    app: ?*app_mod.App = null,
    quit_requested: bool = false,
    clipboard: ?[]u8 = null,
    /// The connected displays. Tests change them with `set_displays`.
    displays_: [max_displays]platform.Display = @splat(default_display),
    display_count: usize = 1,
    cursor: platform.CursorStyle = .arrow,
    menus: platform.app_menu.MenuStore = .{},
    /// What the app last asked for, for tests.
    activation_policy: ?platform.ActivationPolicy = null,
    cursor_visible: bool = true,
    /// The keyboard layout the platform reports. Tests change it with `set_keyboard_layout`.
    layout_name: []const u8 = "unknown",
    hide_requests: u32 = 0,
    /// What the platform reports for scrollbars. Tests change it.
    auto_hide_scrollbars: bool = false,
    cursor_hide_requests: u32 = 0,
    hide_other_apps_requests: u32 = 0,
    unhide_other_apps_requests: u32 = 0,
    const max_displays = 4;
    const default_display: platform.Display = .{ .id = 0, .bounds = .{ .origin = .{ .x = 0, .y = 0 }, .size = .{ .width = 1920, .height = 1080 } } };

    const vtable: Platform.VTable = .{
        .run = run,
        .quit = quit,
        .deinit = deinit,
        .open_window = openWindow,
        .wake = wake,
        .displays = displays,
        .set_cursor_style = setCursor,
        .write_to_clipboard = writeClipboard,
        .read_from_clipboard = readClipboard,
        .quit_when_last_window_closes = noQuitOnClose,
        .set_menus = setMenus,
        .get_menus = getMenus,
        .set_activation_policy = setActivationPolicy,
        .hide_cursor_until_mouse_moves = hideCursorUntilMouseMoves,
        .is_cursor_visible = isCursorVisible,
        .hide_other_apps = hideOtherApps,
        .unhide_other_apps = unhideOtherApps,
        .keyboard_layout = keyboardLayout,
        .hide = hideApp,
        .should_auto_hide_scrollbars = autoHideScrollbars,
    };

    fn hideApp(p: *Platform) void {
        from(p).hide_requests += 1;
    }

    fn autoHideScrollbars(p: *Platform) bool {
        return from(p).auto_hide_scrollbars;
    }

    fn keyboardLayout(p: *Platform) platform.KeyboardLayout {
        const name = from(p).layout_name;
        return .{ .id = name, .name = name };
    }

    /// Changes the keyboard layout and tells the app, as a platform does when the user switches it.
    pub fn set_keyboard_layout(self: *HeadlessPlatform, name: []const u8) void {
        if (std.mem.eql(u8, self.layout_name, name)) return;
        self.layout_name = name;
        self.platform.emit_keyboard_layout_changed();
    }

    fn setActivationPolicy(p: *Platform, policy: platform.ActivationPolicy) void {
        from(p).activation_policy = policy;
    }

    fn hideCursorUntilMouseMoves(p: *Platform) void {
        const self = from(p);
        self.cursor_hide_requests += 1;
        self.cursor_visible = false;
    }

    fn isCursorVisible(p: *Platform) bool {
        return from(p).cursor_visible;
    }

    fn hideOtherApps(p: *Platform) void {
        from(p).hide_other_apps_requests += 1;
    }

    fn unhideOtherApps(p: *Platform) void {
        from(p).unhide_other_apps_requests += 1;
    }

    /// Replaces the connected displays and tells the app, as a platform does when its outputs change.
    pub fn set_displays(self: *HeadlessPlatform, list: []const platform.Display) void {
        std.debug.assert(list.len <= max_displays);
        @memcpy(self.displays_[0..list.len], list);
        self.display_count = list.len;
        self.platform.emit_displays_changed();
    }

    fn setMenus(p: *Platform, menus: []const platform.app_menu.Menu) void {
        const self = from(p);
        self.menus.set(self.allocator, menus);
    }

    fn getMenus(p: *Platform) ?[]const platform.app_menu.OwnedMenu {
        return from(p).menus.get();
    }

    pub fn create(allocator: std.mem.Allocator) *Platform {
        const self = allocator.create(HeadlessPlatform) catch @panic("OOM");
        self.* = .{ .allocator = allocator };
        return &self.platform;
    }

    pub fn from(p: *Platform) *HeadlessPlatform {
        return @fieldParentPtr("platform", p);
    }

    fn run(p: *Platform, app: *app_mod.App, on_launch: *const fn (*anyopaque) void) void {
        const self = from(p);
        self.app = app;
        on_launch(app);
        self.run_until_idle(app);
    }

    /// Pumps foreground tasks and pending frames until nothing is left to do.
    pub fn run_until_idle(self: *HeadlessPlatform, app: *app_mod.App) void {
        var guard: usize = 0;
        while (!self.quit_requested and guard < 10_000) : (guard += 1) {
            var did = app.foreground_executor().run_pending() > 0;
            for (self.windows.items) |w| {
                if (w.frame_requested) {
                    w.frame_requested = false;
                    w.base.emit_request_frame(.{});
                    did = true;
                }
            }
            if (!did) break;
        }
    }

    fn quit(p: *Platform) void {
        from(p).quit_requested = true;
    }

    fn deinit(p: *Platform) void {
        const self = from(p);
        for (self.windows.items) |w| w.destroy();
        self.windows.deinit(self.allocator);
        if (self.clipboard) |c| self.allocator.free(c);
        self.menus.deinit();
        self.allocator.destroy(self);
    }

    fn wake(_: *Platform) void {}

    fn openWindow(p: *Platform, options: window_mod.WindowOptions) anyerror!*PlatformWindow {
        const self = from(p);
        const w = try HeadlessWindow.create(self, options);
        try self.windows.append(self.allocator, w);
        return &w.base;
    }

    fn displays(p: *Platform) []const platform.Display {
        const self = from(p);
        return self.displays_[0..self.display_count];
    }

    fn setCursor(p: *Platform, s: platform.CursorStyle) void {
        from(p).cursor = s;
    }

    fn writeClipboard(p: *Platform, item: platform.ClipboardItem) void {
        const self = from(p);
        if (self.clipboard) |c| self.allocator.free(c);
        self.clipboard = self.allocator.dupe(u8, item.text_) catch null;
    }

    fn readClipboard(p: *Platform) ?platform.ClipboardItem {
        const c = from(p).clipboard orelse return null;
        return .new_string(c);
    }

    fn noQuitOnClose(_: *Platform) bool {
        return false;
    }
};

pub const HeadlessWindow = struct {
    base: PlatformWindow = .{ .vtable = &vtable },
    owner: *HeadlessPlatform,
    size: geometry.Size(Pixels),
    /// Where the window sits; tests move it with `move_to`.
    origin: geometry.Point(Pixels) = .{ .x = 0, .y = 0 },
    scale: f32 = 1,
    title: []const u8 = "",
    frame_requested: bool = true,
    closed: bool = false,
    atlas: atlas_mod.CpuAtlas,
    /// The last presented scene (borrowed from the window's rendered frame).
    last_scene: ?*const scene_mod.Scene = null,
    draw_count: u64 = 0,
    /// What the window last told the input method, for tests.
    ime_enabled: bool = false,
    ime_enabled_changes: u32 = 0,
    ime_position: ?geometry.Bounds(Pixels) = null,
    /// The app draws the frame (no server decorations are asked for). Nothing is moved or
    /// resized by a compositor here, so `start_window_resize` and `show_window_menu` do nothing.
    client_decorations: bool = false,
    client_inset: Pixels = 0,
    /// Whether the window is presented. Tests change it with `set_visibility`.
    visibility_: platform.WindowVisibility = .visible,
    /// The display the window is on. Tests move it with `move_to_display`.
    display: platform.DisplayId = 0,

    fn windowDecorations(p: *PlatformWindow) window_mod.Decorations {
        const self: *HeadlessWindow = @fieldParentPtr("base", p);
        if (self.client_decorations) return .{ .client = .{ .tiling = .{} } };
        return .server;
    }

    fn setClientInset(p: *PlatformWindow, inset: Pixels) void {
        const self: *HeadlessWindow = @fieldParentPtr("base", p);
        self.client_inset = inset;
    }

    fn updateImeEnabled(p: *PlatformWindow, enabled: bool) void {
        const self: *HeadlessWindow = @fieldParentPtr("base", p);
        self.ime_enabled = enabled;
        self.ime_enabled_changes += 1;
    }

    fn updateImePosition(p: *PlatformWindow, area: geometry.Bounds(Pixels)) void {
        const self: *HeadlessWindow = @fieldParentPtr("base", p);
        self.ime_position = area;
    }

    const vtable: PlatformWindow.VTable = .{
        .update_ime_enabled = updateImeEnabled,
        .update_ime_position = updateImePosition,
        .bounds = bounds,
        .content_size = contentSize,
        .scale_factor = scaleFactor,
        .request_frame = requestFrame,
        .draw = draw,
        .sprite_atlas = spriteAtlas,
        .set_title = setTitle,
        .resize = resize,
        .close = close,
        .window_decorations = windowDecorations,
        .set_client_inset = setClientInset,
        .visibility = visibility,
        .display_id = displayId,
    };

    fn visibility(p: *PlatformWindow) platform.WindowVisibility {
        return from(p).visibility_;
    }

    fn displayId(p: *PlatformWindow) ?platform.DisplayId {
        return from(p).display;
    }

    /// Changes what the window presents and reports it. Like a real platform, it reports even a
    /// repeat of the state it already had: the window must work out what changed.
    pub fn set_visibility(self: *HeadlessWindow, v: platform.WindowVisibility) void {
        self.visibility_ = v;
        self.base.emit_visibility_changed();
    }

    /// Moves the window to another display and reports it, even when it is the display it is on.
    pub fn move_to_display(self: *HeadlessWindow, id: platform.DisplayId) void {
        self.display = id;
        self.base.emit_display_changed();
    }

    fn create(owner: *HeadlessPlatform, options: window_mod.WindowOptions) !*HeadlessWindow {
        const a = owner.allocator;
        const self = try a.create(HeadlessWindow);
        const b = if (options.window_bounds) |wb| wb.get_bounds() else geometry.Bounds(Pixels){ .origin = .{ .x = 0, .y = 0 }, .size = .{ .width = 800, .height = 600 } };
        self.* = .{ .owner = owner, .size = b.size, .atlas = atlas_mod.CpuAtlas.init(a), .client_decorations = options.window_decorations == .client };
        if (std.c.getenv("ZUI_SCALE")) |s| self.scale = std.fmt.parseFloat(f32, std.mem.span(s)) catch 1;
        return self;
    }

    fn destroy(self: *HeadlessWindow) void {
        self.atlas.deinit();
        self.owner.allocator.destroy(self);
    }

    pub fn from(p: *PlatformWindow) *HeadlessWindow {
        return @fieldParentPtr("base", p);
    }

    fn bounds(p: *PlatformWindow) geometry.Bounds(Pixels) {
        return .{ .origin = from(p).origin, .size = from(p).size };
    }
    /// Moves the window and reports it as the platform does: only a real change is reported.
    pub fn move_to(self: *HeadlessWindow, origin: geometry.Point(Pixels)) void {
        if (self.origin.x == origin.x and self.origin.y == origin.y) return;
        self.origin = origin;
        self.base.emit_moved();
    }
    fn contentSize(p: *PlatformWindow) geometry.Size(Pixels) {
        return from(p).size;
    }
    fn scaleFactor(p: *PlatformWindow) f32 {
        return from(p).scale;
    }
    fn requestFrame(p: *PlatformWindow) void {
        from(p).frame_requested = true;
    }
    fn draw(p: *PlatformWindow, scene: *const scene_mod.Scene) void {
        const self = from(p);
        self.last_scene = scene;
        self.draw_count += 1;
        if (std.c.getenv("ZUI_SNAPSHOT")) |path| self.snapshot(scene, std.mem.span(path)) catch |err| {
            std.log.err("snapshot failed: {s}", .{@errorName(err)});
        };
    }

    /// Renders `scene` with the CPU renderer and writes a binary PPM to `path`.
    pub fn snapshot(self: *HeadlessWindow, scene: *const scene_mod.Scene, path: []const u8) !void {
        const cpu = @import("../renderer/cpu.zig");
        const a = self.owner.allocator;
        const w: u32 = @intFromFloat(@round(self.size.width * self.scale));
        const h: u32 = @intFromFloat(@round(self.size.height * self.scale));
        const pixels = try a.alloc(u8, @as(usize, w) * h * 4);
        defer a.free(pixels);
        var r = cpu.CpuRenderer.init(a);
        defer r.deinit();
        const fb: cpu.Framebuffer = .{ .pixels = pixels, .width = w, .height = h, .stride = w * 4, .format = .rgba8 };
        r.draw(scene, &self.atlas, fb, @import("../color.zig").white());
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(a);
        try out.print(a, "P6\n{d} {d}\n255\n", .{ w, h });
        try out.ensureUnusedCapacity(a, @as(usize, w) * h * 3);
        var i: usize = 0;
        while (i < pixels.len) : (i += 4) out.appendSliceAssumeCapacity(pixels[i .. i + 3]);
        const zpath = try a.dupeSentinel(u8, path, 0);
        defer a.free(zpath);
        const f = std.c.fopen(zpath, "wb") orelse return error.OpenFailed;
        defer _ = std.c.fclose(f);
        if (std.c.fwrite(out.items.ptr, 1, out.items.len, f) != out.items.len) return error.WriteFailed;
    }
    fn spriteAtlas(p: *PlatformWindow) atlas_mod.PlatformAtlas {
        return self_atlas(from(p));
    }
    fn self_atlas(self: *HeadlessWindow) atlas_mod.PlatformAtlas {
        return self.atlas.platform_atlas();
    }
    fn setTitle(p: *PlatformWindow, t: []const u8) void {
        from(p).title = t;
    }
    fn resize(p: *PlatformWindow, s: geometry.Size(Pixels)) void {
        const self = from(p);
        self.size = s;
        p.emit_resize(s, self.scale);
    }
    fn close(p: *PlatformWindow) void {
        const self = from(p);
        self.closed = true;
        const list = &self.owner.windows;
        for (list.items, 0..) |w, i| if (w == self) {
            _ = list.swapRemove(i);
            break;
        };
        self.destroy();
    }
};
