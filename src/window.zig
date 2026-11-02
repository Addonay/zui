//! Port of GPUI `window.rs`: the `Window`, its frames, hitboxes, focus,
//! element state, painting primitives and event dispatch.

const std = @import("std");
const geometry = @import("geometry.zig");
const color_mod = @import("color.zig");
const style_mod = @import("style.zig");
const scene_mod = @import("scene.zig");
const taffy = @import("taffy.zig");
const element_mod = @import("element.zig");
const app_mod = @import("app.zig");
const platform_mod = @import("platform.zig");
const interactive = @import("interactive.zig");
const keystroke_mod = @import("keystroke.zig");
const key_dispatch = @import("key_dispatch.zig");
const action_mod = @import("action.zig");
const text_system_mod = @import("text_system.zig");
const atlas_mod = @import("atlas.zig");
const view_mod = @import("view.zig");
const refineable = @import("refineable.zig");

const App = app_mod.App;
const EntityId = app_mod.EntityId;
const Pixels = geometry.Pixels;
const ScaledPixels = geometry.ScaledPixels;
const Point = geometry.Point;
const Size = geometry.Size;
const Bounds = geometry.Bounds;
const Edges = geometry.Edges;
const Corners = geometry.Corners;
const Hsla = color_mod.Hsla;
const Background = color_mod.Background;
const AnyElement = element_mod.AnyElement;
const ElementId = element_mod.ElementId;
const GlobalElementId = element_mod.GlobalElementId;
const LayoutId = taffy.LayoutId;
const AvailableSpace = taffy.AvailableSpace;
const Style = style_mod.Style;
const TextStyle = style_mod.TextStyle;
const TextStyleRefinement = style_mod.TextStyleRefinement;
const CursorStyle = style_mod.CursorStyle;
const BorderStyle = style_mod.BorderStyle;
pub const ContentMask = scene_mod.ContentMask;
pub const DispatchPhase = key_dispatch.DispatchPhase;
pub const KeyContext = key_dispatch.KeyContext;
pub const AnyView = view_mod.AnyView;

pub const WindowId = u32;

// ---------------------------------------------------------------------------
// Frame arena (GPUI's ELEMENT_ARENA).

threadlocal var current_frame_arena: ?*std.heap.ArenaAllocator = null;
var fallback_arena_storage: ?std.heap.ArenaAllocator = null;

/// The allocator for transient per-frame data (elements, listeners, strings).
pub fn frame_arena() std.mem.Allocator {
    if (current_frame_arena) |a| return a.allocator();
    if (fallback_arena_storage == null) fallback_arena_storage = .init(std.heap.page_allocator);
    return fallback_arena_storage.?.allocator();
}

/// Formats into the frame arena (the `format!` analogue for element text).
pub fn format(comptime fmt: []const u8, args: anytype) []const u8 {
    return std.fmt.allocPrint(frame_arena(), fmt, args) catch @panic("OOM");
}

// ---------------------------------------------------------------------------
// Options & handles.

pub const WindowBounds = union(enum) {
    windowed: Bounds(Pixels),
    maximized: Bounds(Pixels),
    fullscreen: Bounds(Pixels),

    pub fn get_bounds(self: WindowBounds) Bounds(Pixels) {
        return switch (self) {
            inline else => |b| b,
        };
    }
};

pub const WindowKind = enum { normal, popup, floating, dialog };
pub const WindowBackgroundAppearance = enum { @"opaque", transparent, blurred };
pub const WindowDecorations = enum { server, client };

pub const TitlebarOptions = struct {
    title: ?[]const u8 = null,
    appears_transparent: bool = false,
    traffic_light_position: ?Point(Pixels) = null,
};

pub const WindowOptions = struct {
    window_bounds: ?WindowBounds = null,
    titlebar: ?TitlebarOptions = .{},
    focus: bool = true,
    show: bool = true,
    kind: WindowKind = .normal,
    is_movable: bool = true,
    is_resizable: bool = true,
    is_minimizable: bool = true,
    display_id: ?u32 = null,
    window_background: WindowBackgroundAppearance = .@"opaque",
    app_id: ?[]const u8 = null,
    window_min_size: ?Size(Pixels) = null,
    window_decorations: ?WindowDecorations = null,
};

/// The root view type returned by an `open_window` builder.
pub fn RootViewType(comptime build: anytype) type {
    const R = @typeInfo(@TypeOf(build)).@"fn".return_type.?;
    return R.Type;
}

/// A typed handle to a window whose root view is `V` (GPUI `WindowHandle<V>`).
pub fn WindowHandle(comptime V: type) type {
    return struct {
        const Self = @This();
        window_id: WindowId,
        entity_id_: EntityId,

        /// The root view entity.
        pub fn root(self: Self, cx: anytype) !app_mod.Entity(V) {
            _ = cx;
            return .{ .entity_id_ = self.entity_id_ };
        }

        /// Updates the root view with `f(view, args..., window, cx)`.
        pub fn update(self: Self, cx: anytype, comptime f: anytype, args: anytype) !@typeInfo(@TypeOf(f)).@"fn".return_type.? {
            const app = app_mod.app_of(cx);
            const win = app.window_by_id(self.window_id) orelse return error.WindowClosed;
            const e: app_mod.Entity(V) = .{ .entity_id_ = self.entity_id_ };
            const r = e.update_in(win, app, f, args);
            app.flush_effects();
            return r;
        }

        pub fn window(self: Self, cx: anytype) ?*Window {
            return app_mod.app_of(cx).window_by_id(self.window_id);
        }
    };
}

// ---------------------------------------------------------------------------
// Focus.

pub const FocusId = u64;

/// A handle to a focusable element (GPUI `FocusHandle`).
pub const FocusHandle = struct {
    id: FocusId,
    tab_index_: isize = 0,
    tab_stop_: bool = false,

    pub fn focus(self: FocusHandle, window: *Window) void {
        window.focus(self);
    }
    pub fn is_focused(self: FocusHandle, window: *const Window) bool {
        return window.focus_id == self.id;
    }
    /// True if this handle or a descendant is focused.
    pub fn contains_focused(self: FocusHandle, window: *const Window, cx: *const App) bool {
        _ = cx;
        const f = window.focus_id orelse return false;
        return window.rendered_frame.dispatch_tree.focus_contains(self.id, f);
    }
    /// True if this handle or an ancestor is focused.
    pub fn within_focused(self: FocusHandle, window: *const Window, cx: *const App) bool {
        _ = cx;
        const f = window.focus_id orelse return false;
        return window.rendered_frame.dispatch_tree.focus_contains(f, self.id);
    }
    pub fn tab_index(self: FocusHandle, index: isize) FocusHandle {
        var h = self;
        h.tab_index_ = index;
        return h;
    }
    pub fn tab_stop(self: FocusHandle, v: bool) FocusHandle {
        var h = self;
        h.tab_stop_ = v;
        return h;
    }
    /// Dispatches an action as if it originated from this handle.
    pub fn dispatch_action(self: FocusHandle, action: anytype, window: *Window, cx: *App) void {
        const prev = window.focus_id;
        window.focus_id = self.id;
        defer window.focus_id = prev;
        window.dispatch_action(action_mod.box_action(app_mod.app_of(cx).effect_arena.allocator(), action), cx);
    }
    pub fn eql(a: FocusHandle, b: FocusHandle) bool {
        return a.id == b.id;
    }
};

/// Types that can be focused (GPUI `Focusable`): `fn focus_handle(self, cx) FocusHandle`.
pub fn is_focusable(comptime T: type) bool {
    return @hasDecl(T, "focus_handle");
}

// ---------------------------------------------------------------------------
// Hitboxes.

pub const HitboxId = u64;

pub const HitboxBehavior = enum { normal, block_mouse, block_mouse_except_scroll };

/// A rectangular region that potentially blocks hitboxes inserted prior.
pub const Hitbox = struct {
    id: HitboxId,
    bounds: Bounds(Pixels),
    content_mask: ContentMask(Pixels),
    behavior: HitboxBehavior = .normal,

    /// True if the mouse is over this hitbox and nothing above blocks it.
    pub fn is_hovered(self: *const Hitbox, window: *const Window) bool {
        return window.hitbox_is_hovered(self.id);
    }
    /// True if a scroll event at the mouse position should go to this hitbox.
    pub fn should_handle_scroll(self: *const Hitbox, window: *const Window) bool {
        return window.hitbox_should_handle_scroll(self.id);
    }
};

const HitTest = struct {
    ids: std.ArrayList(HitboxId) = .empty,
    hover_hitbox_count: usize = 0,
};

// ---------------------------------------------------------------------------
// Frames.

const MouseListener = struct {
    event_type: app_mod.TypeId,
    ctx: *anyopaque,
    func: *const fn (ctx: *anyopaque, event: *const anyopaque, phase: DispatchPhase, window: *Window, cx: *App) void,
};

const CursorStyleRequest = struct { hitbox_id: ?HitboxId, style: CursorStyle };

const DeferredDraw = struct {
    priority: usize,
    element: AnyElement,
    absolute_offset: Point(Pixels),
    text_style_stack: []const TextStyleRefinement,
    parent_node: key_dispatch.DispatchNodeId,
    element_id_hash: u64,
};

pub const Frame = struct {
    scene: scene_mod.Scene,
    hitboxes: std.ArrayList(Hitbox) = .empty,
    mouse_listeners: std.ArrayList(MouseListener) = .empty,
    dispatch_tree: key_dispatch.DispatchTree,
    cursor_styles: std.ArrayList(CursorStyleRequest) = .empty,
    deferred_draws: std.ArrayList(DeferredDraw) = .empty,
    focus: ?FocusId = null,
    window_active: bool = false,
    arena: std.heap.ArenaAllocator,
    input_handlers: std.ArrayList(PendingInputHandler) = .empty,

    fn init(gpa: std.mem.Allocator) Frame {
        return .{
            .scene = scene_mod.Scene.init(gpa),
            .dispatch_tree = key_dispatch.DispatchTree.init(gpa),
            .arena = .init(gpa),
        };
    }

    fn deinit(self: *Frame, gpa: std.mem.Allocator) void {
        self.scene.deinit();
        self.hitboxes.deinit(gpa);
        self.mouse_listeners.deinit(gpa);
        self.dispatch_tree.deinit();
        self.cursor_styles.deinit(gpa);
        self.deferred_draws.deinit(gpa);
        self.input_handlers.deinit(gpa);
        self.arena.deinit();
    }

    fn clear(self: *Frame) void {
        self.scene.clear();
        self.hitboxes.clearRetainingCapacity();
        self.mouse_listeners.clearRetainingCapacity();
        self.dispatch_tree.clear();
        self.cursor_styles.clearRetainingCapacity();
        self.deferred_draws.clearRetainingCapacity();
        self.input_handlers.clearRetainingCapacity();
        self.focus = null;
        _ = self.arena.reset(.retain_capacity);
    }
};

const PendingInputHandler = struct {
    handler: platform_mod.PlatformInputHandler,
    focus_id: FocusId,
};

const ElementStateKey = struct { gid: u64, tid: app_mod.TypeId };
const ElementStateBox = struct {
    ptr: *anyopaque,
    destroy: *const fn (std.mem.Allocator, *anyopaque) void,
    frame: u64,
};

/// A paint request for a quad (GPUI `PaintQuad`).
pub const PaintQuad = struct {
    bounds: Bounds(Pixels),
    corner_radii: Corners(Pixels) = Corners(Pixels).all(0),
    background: Background,
    border_widths: Edges(Pixels) = Edges(Pixels).all(0),
    border_color: Hsla = color_mod.transparent_black(),
    border_style: BorderStyle = .solid,

    pub fn with_corner_radii(self: PaintQuad, r: anytype) PaintQuad {
        var q = self;
        q.corner_radii = toCorners(r);
        return q;
    }
    pub fn with_border_widths(self: PaintQuad, w: anytype) PaintQuad {
        var q = self;
        q.border_widths = toEdges(w);
        return q;
    }
    pub fn with_border_color(self: PaintQuad, c: anytype) PaintQuad {
        var q = self;
        q.border_color = color_mod.to_hsla(c);
        return q;
    }
    pub fn with_background(self: PaintQuad, bg: anytype) PaintQuad {
        var q = self;
        q.background = color_mod.to_background(bg);
        return q;
    }
};

fn toCorners(v: anytype) Corners(Pixels) {
    if (@TypeOf(v) == Corners(Pixels)) return v;
    return Corners(Pixels).all(@as(f32, v));
}

fn toEdges(v: anytype) Edges(Pixels) {
    if (@TypeOf(v) == Edges(Pixels)) return v;
    return Edges(Pixels).all(@as(f32, v));
}

/// Creates a `PaintQuad` (GPUI `quad`).
pub fn quad(b: Bounds(Pixels), corner_radii: anytype, background: anytype, border_widths: anytype, border_color: anytype, border_style: BorderStyle) PaintQuad {
    return .{
        .bounds = b,
        .corner_radii = toCorners(corner_radii),
        .background = color_mod.to_background(background),
        .border_widths = toEdges(border_widths),
        .border_color = color_mod.to_hsla(border_color),
        .border_style = border_style,
    };
}

/// A filled rectangle (GPUI `fill`).
pub fn fill(b: Bounds(Pixels), background: anytype) PaintQuad {
    return .{ .bounds = b, .background = color_mod.to_background(background) };
}

/// A 1px rectangle outline (GPUI `outline`).
pub fn outline(b: Bounds(Pixels), border_color: anytype, border_style: BorderStyle) PaintQuad {
    return .{
        .bounds = b,
        .background = color_mod.to_background(color_mod.transparent_black()),
        .border_widths = Edges(Pixels).all(1),
        .border_color = color_mod.to_hsla(border_color),
        .border_style = border_style,
    };
}

// ---------------------------------------------------------------------------
// Window.

/// A platform window and its UI state (GPUI `Window`).
pub const Window = struct {
    allocator: std.mem.Allocator,
    app: *App,
    handle_id: WindowId = 0,
    platform_window: *platform_mod.PlatformWindow,
    sprite_atlas: atlas_mod.PlatformAtlas,
    root: ?AnyView = null,
    layout_engine: taffy.TaffyLayoutEngine,
    rendered_frame: Frame,
    next_frame: Frame,
    /// Per-frame scratch for elements; reset at the start of every draw.
    element_arena: std.heap.ArenaAllocator,
    element_id_stack: std.ArrayList(ElementId) = .empty,
    element_id_hashes: std.ArrayList(u64) = .empty,
    text_style_stack: std.ArrayList(TextStyleRefinement) = .empty,
    element_offset_stack: std.ArrayList(Point(Pixels)) = .empty,
    content_mask_stack: std.ArrayList(ContentMask(Pixels)) = .empty,
    element_opacity_stack: std.ArrayList(f32) = .empty,
    element_states: std.AutoHashMapUnmanaged(ElementStateKey, ElementStateBox) = .empty,
    rendered_entities: std.AutoHashMapUnmanaged(EntityId, void) = .empty,
    next_rendered_entities: std.AutoHashMapUnmanaged(EntityId, void) = .empty,
    view_stack: std.ArrayList(EntityId) = .empty,
    next_hitbox_id: HitboxId = 1,
    mouse_hit_test: HitTest = .{},
    mouse_position_: Point(Pixels) = .{ .x = 0, .y = 0 },
    modifiers_: keystroke_mod.Modifiers = .{},
    capslock: keystroke_mod.Capslock = .{},
    scale_factor_: f32 = 1,
    rem_size_: Pixels = 16,
    rem_size_override_stack: std.ArrayList(Pixels) = .empty,
    viewport_size: Size(Pixels) = .{ .width = 0, .height = 0 },
    focus_id: ?FocusId = null,
    focus_enabled: bool = true,
    pending_focus_events: bool = false,
    active: bool = true,
    hovered: bool = false,
    dirty: bool = true,
    drawing: bool = false,
    needs_present: bool = false,
    /// Set by `request_animation_frame`; another frame is drawn after this one.
    animation_requested: bool = false,
    next_frame_callbacks: std.ArrayList(FrameCallback) = .empty,
    frame_count: u64 = 0,
    default_prevented: bool = false,
    propagate_event: bool = true,
    captured_hitbox: ?HitboxId = null,
    pending_keystrokes: std.ArrayList(keystroke_mod.Keystroke) = .empty,
    last_input_was_keyboard: bool = false,
    title: []const u8 = "",
    should_close_handler: ?FrameCallback = null,
    appearance_: platform_mod.WindowAppearance = .light,

    pub const FrameCallback = struct { ctx: *anyopaque, func: *const fn (*anyopaque, *Window, *App) void };

    pub fn create(app: *App, options: WindowOptions) !*Window {
        const gpa = app.allocator;
        const self = try gpa.create(Window);
        const pw = try app.platform.open_window(options);
        self.* = .{
            .allocator = gpa,
            .app = app,
            .platform_window = pw,
            .sprite_atlas = pw.sprite_atlas(),
            .layout_engine = taffy.TaffyLayoutEngine.new(gpa),
            .rendered_frame = Frame.init(gpa),
            .next_frame = Frame.init(gpa),
            .element_arena = .init(gpa),
        };
        self.scale_factor_ = pw.scale_factor();
        self.viewport_size = pw.content_size();
        self.appearance_ = pw.appearance();
        if (options.titlebar) |t| if (t.title) |title| {
            self.title = title;
        };
        pw.set_callbacks(.{
            .ctx = self,
            .request_frame = onRequestFrame,
            .input = onInput,
            .active_status_change = onActiveStatusChange,
            .hover_status_change = onHoverStatusChange,
            .resize = onResize,
            .should_close = onShouldClose,
            .close = onClose,
            .appearance_changed = onAppearanceChanged,
        });
        return self;
    }

    pub fn destroy(self: *Window, app: *App) void {
        if (self.root) |r| app.release_entity(r.entity_id);
        self.platform_window.close();
        const gpa = self.allocator;
        self.layout_engine.deinit();
        self.rendered_frame.deinit(gpa);
        self.next_frame.deinit(gpa);
        self.element_arena.deinit();
        self.element_id_stack.deinit(gpa);
        self.element_id_hashes.deinit(gpa);
        self.text_style_stack.deinit(gpa);
        self.element_offset_stack.deinit(gpa);
        self.content_mask_stack.deinit(gpa);
        self.element_opacity_stack.deinit(gpa);
        var it = self.element_states.valueIterator();
        while (it.next()) |b| b.destroy(gpa, b.ptr);
        self.element_states.deinit(gpa);
        self.rendered_entities.deinit(gpa);
        self.next_rendered_entities.deinit(gpa);
        self.view_stack.deinit(gpa);
        self.mouse_hit_test.ids.deinit(gpa);
        self.next_frame_callbacks.deinit(gpa);
        self.pending_keystrokes.deinit(gpa);
        self.rem_size_override_stack.deinit(gpa);
        gpa.destroy(self);
    }

    pub fn set_root_view(self: *Window, view: AnyView) void {
        self.root = view;
    }

    /// The root view, downcast to `V`.
    pub fn root_view(self: *Window, comptime V: type) ?app_mod.Entity(V) {
        const r = self.root orelse return null;
        return r.downcast(V);
    }

    // -- invalidation -------------------------------------------------

    /// Schedules a redraw of this window (GPUI `refresh`).
    pub fn refresh(self: *Window) void {
        if (!self.drawing) {
            self.dirty = true;
            self.platform_window.request_frame();
        }
    }

    pub fn is_dirty(self: *const Window) bool {
        return self.dirty;
    }

    pub fn on_entity_notified(self: *Window, id: EntityId) void {
        if (self.rendered_entities.contains(id)) self.refresh();
    }

    /// Requests that another frame be drawn after the current one (for animations).
    pub fn request_animation_frame(self: *Window) void {
        self.animation_requested = true;
        self.platform_window.request_frame();
    }

    /// Runs `f(window, cx)` before the next frame is drawn.
    pub fn on_next_frame(self: *Window, comptime f: fn (*Window, *App) void) void {
        const S = struct {
            fn call(_: *anyopaque, w: *Window, c: *App) void {
                f(w, c);
            }
        };
        self.next_frame_callbacks.append(self.allocator, .{ .ctx = @ptrFromInt(1), .func = S.call }) catch oom();
        self.platform_window.request_frame();
    }

    // -- properties ---------------------------------------------------

    pub fn scale_factor(self: *const Window) f32 {
        return self.scale_factor_;
    }
    pub fn rem_size(self: *const Window) Pixels {
        if (self.rem_size_override_stack.items.len > 0) return self.rem_size_override_stack.items[self.rem_size_override_stack.items.len - 1];
        return self.rem_size_;
    }
    pub fn set_rem_size(self: *Window, size: Pixels) void {
        self.rem_size_ = size;
    }
    pub fn line_height(self: *const Window) Pixels {
        return self.text_style().line_height_in_pixels(self.rem_size());
    }
    pub fn mouse_position(self: *const Window) Point(Pixels) {
        return self.mouse_position_;
    }
    pub fn modifiers(self: *const Window) keystroke_mod.Modifiers {
        return self.modifiers_;
    }
    pub fn viewport_size_(self: *const Window) Size(Pixels) {
        return self.viewport_size;
    }
    pub fn bounds(self: *const Window) Bounds(Pixels) {
        return self.platform_window.bounds();
    }
    pub fn is_window_active(self: *const Window) bool {
        return self.active;
    }
    pub fn is_window_hovered(self: *const Window) bool {
        return self.hovered;
    }
    pub fn appearance(self: *const Window) platform_mod.WindowAppearance {
        return self.appearance_;
    }
    pub fn text_system(self: *Window) *text_system_mod.TextSystem {
        return self.app.text_system();
    }
    pub fn set_window_title(self: *Window, title: []const u8) void {
        self.title = title;
        self.platform_window.set_title(title);
    }
    pub fn activate_window(self: *Window) void {
        self.platform_window.activate();
    }
    pub fn minimize_window(self: *Window) void {
        self.platform_window.minimize();
    }
    pub fn zoom_window(self: *Window) void {
        self.platform_window.zoom();
    }
    pub fn toggle_fullscreen(self: *Window) void {
        self.platform_window.toggle_fullscreen();
    }
    pub fn start_window_move(self: *Window) void {
        self.platform_window.start_window_move();
    }
    pub fn remove_window(self: *Window) void {
        self.app.close_window(self);
    }
    pub fn resize(self: *Window, size: Size(Pixels)) void {
        self.platform_window.resize(size);
    }
    pub fn window_handle_id(self: *const Window) WindowId {
        return self.handle_id;
    }
    pub fn prevent_default(self: *Window) void {
        self.default_prevented = true;
    }
    pub fn is_default_prevented(self: *const Window) bool {
        return self.default_prevented;
    }
    /// Stops the current event from propagating (GPUI `cx.stop_propagation`).
    pub fn stop_propagation(self: *Window) void {
        self.propagate_event = false;
    }
    pub fn capture_pointer(self: *Window, hitbox_id: HitboxId) void {
        self.captured_hitbox = hitbox_id;
    }
    pub fn release_pointer(self: *Window) void {
        self.captured_hitbox = null;
    }

    // -- focus -------------------------------------------------------

    pub fn focus(self: *Window, handle: FocusHandle) void {
        if (!self.focus_enabled or self.focus_id == handle.id) return;
        self.focus_id = handle.id;
        self.pending_focus_events = true;
        self.refresh();
    }

    pub fn blur(self: *Window) void {
        if (!self.focus_enabled) return;
        self.focus_id = null;
        self.refresh();
    }

    pub fn disable_focus(self: *Window) void {
        self.blur();
        self.focus_enabled = false;
    }

    pub fn focused(self: *const Window, cx: *const App) ?FocusHandle {
        _ = cx;
        const id = self.focus_id orelse return null;
        return .{ .id = id };
    }

    pub fn focus_next(self: *Window, cx: *App) void {
        _ = cx;
        if (self.rendered_frame.dispatch_tree.next_tab_stop(self.focus_id, true)) |id| self.focus(.{ .id = id });
    }

    pub fn focus_prev(self: *Window, cx: *App) void {
        _ = cx;
        if (self.rendered_frame.dispatch_tree.next_tab_stop(self.focus_id, false)) |id| self.focus(.{ .id = id });
    }

    // -- element ids & state -----------------------------------------

    pub fn push_element_id(self: *Window, id: ElementId) GlobalElementId {
        const prev: u64 = if (self.element_id_hashes.items.len > 0) self.element_id_hashes.items[self.element_id_hashes.items.len - 1] else 0;
        const h = element_mod.extend_path_hash(prev, id);
        self.element_id_stack.append(self.allocator, id) catch oom();
        self.element_id_hashes.append(self.allocator, h) catch oom();
        return .{ .hash = h };
    }

    pub fn pop_element_id(self: *Window) void {
        _ = self.element_id_stack.pop();
        _ = self.element_id_hashes.pop();
    }

    /// Runs `f(args..., window)` with `id` pushed onto the element id stack.
    pub fn with_id(self: *Window, id: anytype, comptime f: anytype, args: anytype) @typeInfo(@TypeOf(f)).@"fn".return_type.? {
        _ = self.push_element_id(ElementId.from(id));
        defer self.pop_element_id();
        return @call(.auto, f, args ++ .{self});
    }

    /// The global id of the current element id stack.
    pub fn current_global_id(self: *const Window) GlobalElementId {
        return .{ .hash = if (self.element_id_hashes.items.len > 0) self.element_id_hashes.items[self.element_id_hashes.items.len - 1] else 0 };
    }

    /// Persistent state of type `S` associated with an element's global id
    /// (GPUI `with_element_state`), initialized with `init` on first use.
    /// States not accessed during a frame are dropped.
    pub fn element_state(self: *Window, comptime S: type, gid: GlobalElementId, init: S) *S {
        const key: ElementStateKey = .{ .gid = gid.hash, .tid = app_mod.type_id(S) };
        const gop = self.element_states.getOrPut(self.allocator, key) catch oom();
        if (!gop.found_existing) {
            const p = self.allocator.create(S) catch oom();
            p.* = init;
            gop.value_ptr.* = .{ .ptr = p, .destroy = struct {
                fn d(a: std.mem.Allocator, raw: *anyopaque) void {
                    const s: *S = @ptrCast(@alignCast(raw));
                    if (@hasDecl(S, "deinit")) s.deinit(a);
                    a.destroy(s);
                }
            }.d, .frame = self.frame_count };
        }
        gop.value_ptr.frame = self.frame_count;
        return @ptrCast(@alignCast(gop.value_ptr.ptr));
    }

    /// GPUI `with_element_state`: `f(?*S, window) struct{R, S}`-style callers
    /// should prefer `element_state`; this form mirrors GPUI's signature.
    pub fn with_element_state(self: *Window, comptime S: type, gid: GlobalElementId, comptime f: anytype) @typeInfo(@TypeOf(f)).@"fn".return_type.? {
        const key: ElementStateKey = .{ .gid = gid.hash, .tid = app_mod.type_id(S) };
        const existing: ?*S = if (self.element_states.get(key)) |b| @ptrCast(@alignCast(b.ptr)) else null;
        return f(existing, self);
    }

    /// Keyed entity state (GPUI `use_keyed_state`): creates the entity on first use.
    pub fn use_keyed_state(self: *Window, key: anytype, cx: *App, comptime init: anytype) app_mod.Entity(app_mod.EntityTypeOf(@TypeOf(init))) {
        const T = app_mod.EntityTypeOf(@TypeOf(init));
        const gid = self.push_element_id(ElementId.from(key));
        defer self.pop_element_id();
        const Holder = struct { id: ?EntityId = null };
        const h = self.element_state(Holder, gid, .{});
        if (h.id) |id| {
            if (cx.entities.get(id) != null) return .{ .entity_id_ = id };
        }
        const e = cx.new(init);
        h.id = e.entity_id();
        _ = T;
        return e;
    }

    fn gc_element_states(self: *Window) void {
        var it = self.element_states.iterator();
        var dead: std.ArrayList(ElementStateKey) = .empty;
        defer dead.deinit(self.allocator);
        while (it.next()) |kv| {
            if (kv.value_ptr.frame + 1 < self.frame_count) dead.append(self.allocator, kv.key_ptr.*) catch oom();
        }
        for (dead.items) |k| {
            if (self.element_states.fetchRemove(k)) |kv| kv.value.destroy(self.allocator, kv.value.ptr);
        }
    }

    // -- views -------------------------------------------------------

    pub fn push_view(self: *Window, id: EntityId) void {
        self.view_stack.append(self.allocator, id) catch oom();
        self.next_rendered_entities.put(self.allocator, id, {}) catch oom();
    }
    pub fn pop_view(self: *Window) void {
        _ = self.view_stack.pop();
    }
    pub fn current_view(self: *const Window) ?EntityId {
        if (self.view_stack.items.len == 0) return null;
        return self.view_stack.items[self.view_stack.items.len - 1];
    }
    /// Records that the current frame depends on `id` (redraws when it notifies).
    pub fn observe_entity_for_redraw(self: *Window, id: EntityId) void {
        self.next_rendered_entities.put(self.allocator, id, {}) catch oom();
    }

    // -- text style ---------------------------------------------------

    /// The text style resolved from the window's text style stack.
    pub fn text_style(self: *const Window) TextStyle {
        var s: TextStyle = .{};
        for (self.text_style_stack.items) |*r| refineable.refine(TextStyle, &s, r);
        return s;
    }

    /// Runs `f(args..., window)` with `style` pushed (GPUI `with_text_style`).
    pub fn with_text_style(self: *Window, style: ?TextStyleRefinement, comptime f: anytype, args: anytype) @typeInfo(@TypeOf(f)).@"fn".return_type.? {
        if (style) |s| self.text_style_stack.append(self.allocator, s) catch oom();
        defer if (style != null) {
            _ = self.text_style_stack.pop();
        };
        return @call(.auto, f, args ++ .{self});
    }

    pub fn push_text_style(self: *Window, style: TextStyleRefinement) void {
        self.text_style_stack.append(self.allocator, style) catch oom();
    }
    pub fn pop_text_style(self: *Window) void {
        _ = self.text_style_stack.pop();
    }

    // -- offsets & masks ------------------------------------------------

    pub fn element_offset(self: *const Window) Point(Pixels) {
        if (self.element_offset_stack.items.len == 0) return .{ .x = 0, .y = 0 };
        return self.element_offset_stack.items[self.element_offset_stack.items.len - 1];
    }

    pub fn push_element_offset(self: *Window, offset: Point(Pixels)) void {
        const abs = self.element_offset().add(offset);
        self.element_offset_stack.append(self.allocator, abs) catch oom();
    }
    pub fn push_absolute_element_offset(self: *Window, offset: Point(Pixels)) void {
        self.element_offset_stack.append(self.allocator, offset) catch oom();
    }
    pub fn pop_element_offset(self: *Window) void {
        _ = self.element_offset_stack.pop();
    }

    /// Runs `f(arg, window, cx)` with an absolute element offset.
    pub fn with_absolute_element_offset(self: *Window, offset: Point(Pixels), arg: anytype, comptime f: anytype, cx: *App) void {
        self.push_absolute_element_offset(offset);
        defer self.pop_element_offset();
        f(arg, self, cx);
    }

    pub fn content_mask(self: *const Window) ContentMask(Pixels) {
        if (self.content_mask_stack.items.len == 0) {
            return .{ .bounds = .{ .origin = .{ .x = 0, .y = 0 }, .size = self.viewport_size } };
        }
        return self.content_mask_stack.items[self.content_mask_stack.items.len - 1];
    }

    /// Pushes a mask intersected with the current one; pair with `pop_content_mask`.
    pub fn push_content_mask(self: *Window, mask: ContentMask(Pixels)) void {
        const m = mask.intersect(self.content_mask());
        self.content_mask_stack.append(self.allocator, m) catch oom();
    }
    pub fn pop_content_mask(self: *Window) void {
        _ = self.content_mask_stack.pop();
    }

    pub fn element_opacity(self: *const Window) f32 {
        if (self.element_opacity_stack.items.len == 0) return 1;
        return self.element_opacity_stack.items[self.element_opacity_stack.items.len - 1];
    }
    pub fn push_element_opacity(self: *Window, opacity: ?f32) void {
        const o = (opacity orelse 1.0) * self.element_opacity();
        self.element_opacity_stack.append(self.allocator, o) catch oom();
    }
    pub fn pop_element_opacity(self: *Window) void {
        _ = self.element_opacity_stack.pop();
    }

    // -- layout --------------------------------------------------------

    pub fn request_layout(self: *Window, style: *const Style, children: []const LayoutId, cx: *App) LayoutId {
        _ = cx;
        return self.layout_engine.request_layout(style, self.rem_size(), self.scale_factor_, children);
    }

    pub fn request_measured_layout(self: *Window, style: *const Style, measure: taffy.MeasureFn) LayoutId {
        return self.layout_engine.request_measured_layout(style, self.rem_size(), self.scale_factor_, measure);
    }

    pub fn compute_layout(self: *Window, id: LayoutId, available_space: Size(AvailableSpace), cx: *App) void {
        self.layout_engine.compute_layout(id, available_space, self, cx);
    }

    /// Bounds of a laid-out node, offset by the current element offset.
    pub fn layout_bounds(self: *Window, id: LayoutId) Bounds(Pixels) {
        var b = self.layout_engine.layout_bounds(id, self.scale_factor_);
        const off = self.element_offset();
        b.origin = b.origin.add(off);
        return b;
    }

    // -- hitboxes ------------------------------------------------------

    /// Inserts a hitbox for the current frame (GPUI `insert_hitbox`).
    pub fn insert_hitbox(self: *Window, b: Bounds(Pixels), behavior: HitboxBehavior) Hitbox {
        const id = self.next_hitbox_id;
        self.next_hitbox_id += 1;
        const h: Hitbox = .{ .id = id, .bounds = b, .content_mask = self.content_mask(), .behavior = behavior };
        self.next_frame.hitboxes.append(self.allocator, h) catch oom();
        return h;
    }

    fn hitbox_is_hovered(self: *const Window, id: HitboxId) bool {
        if (self.captured_hitbox) |c| return c == id;
        const ht = &self.mouse_hit_test;
        for (ht.ids.items[0..ht.hover_hitbox_count]) |h| if (h == id) return true;
        return false;
    }

    fn hitbox_should_handle_scroll(self: *const Window, id: HitboxId) bool {
        for (self.mouse_hit_test.ids.items) |h| if (h == id) return true;
        return false;
    }

    fn hit_test(self: *Window, position: Point(Pixels)) void {
        const ht = &self.mouse_hit_test;
        ht.ids.clearRetainingCapacity();
        ht.hover_hitbox_count = 0;
        var set_hover_count = false;
        const boxes = self.rendered_frame.hitboxes.items;
        var i = boxes.len;
        while (i > 0) {
            i -= 1;
            const h = boxes[i];
            if (h.bounds.contains(position) and h.content_mask.bounds.contains(position)) {
                ht.ids.append(self.allocator, h.id) catch oom();
                if (!set_hover_count and h.behavior == .block_mouse_except_scroll) {
                    ht.hover_hitbox_count = ht.ids.items.len;
                    set_hover_count = true;
                }
                if (h.behavior == .block_mouse) break;
            }
        }
        if (!set_hover_count) ht.hover_hitbox_count = ht.ids.items.len;
    }

    /// Sets the cursor style while `hitbox` is hovered.
    pub fn set_cursor_style(self: *Window, style: CursorStyle, hitbox: *const Hitbox) void {
        self.next_frame.cursor_styles.append(self.allocator, .{ .hitbox_id = hitbox.id, .style = style }) catch oom();
    }

    /// Sets the cursor style for the whole window.
    pub fn set_window_cursor_style(self: *Window, style: CursorStyle) void {
        self.next_frame.cursor_styles.append(self.allocator, .{ .hitbox_id = null, .style = style }) catch oom();
    }

    // -- listeners -----------------------------------------------------

    /// Registers a mouse event listener for the current frame:
    /// `handler(ctx, *const E, phase, window, cx)`.
    pub fn on_mouse_event(self: *Window, comptime E: type, ctx: *anyopaque, comptime handler: fn (*anyopaque, *const E, DispatchPhase, *Window, *App) void) void {
        const S = struct {
            fn call(c: *anyopaque, ev: *const anyopaque, phase: DispatchPhase, w: *Window, a: *App) void {
                handler(c, @ptrCast(@alignCast(ev)), phase, w, a);
            }
        };
        self.next_frame.mouse_listeners.append(self.allocator, .{ .event_type = app_mod.type_id(E), .ctx = ctx, .func = S.call }) catch oom();
    }

    /// Registers a key event listener on the current dispatch node.
    pub fn on_key_event(self: *Window, comptime E: type, ctx: *anyopaque, comptime handler: fn (*anyopaque, *const E, DispatchPhase, *Window, *App) void) void {
        const S = struct {
            fn call(c: *anyopaque, ev: *const anyopaque, phase: DispatchPhase, w: *Window, a: *App) void {
                handler(c, @ptrCast(@alignCast(ev)), phase, w, a);
            }
        };
        self.next_frame.dispatch_tree.on_key_event(.{ .event_type = app_mod.type_id(E), .ctx = ctx, .func = S.call });
    }

    /// Registers an action listener on the current dispatch node.
    pub fn on_action(self: *Window, action_type: app_mod.TypeId, ctx: *anyopaque, func: key_dispatch.ActionFn) void {
        self.next_frame.dispatch_tree.on_action(.{ .action_type = action_type, .ctx = ctx, .func = func });
    }

    pub fn set_key_context(self: *Window, context: KeyContext) void {
        self.next_frame.dispatch_tree.set_key_context(context);
    }

    pub fn set_focus_handle(self: *Window, handle: *const FocusHandle, cx: *App) void {
        _ = cx;
        self.next_frame.dispatch_tree.set_focus_id(handle.id, handle.tab_index_, handle.tab_stop_);
        if (self.focus_id == handle.id) self.next_frame.focus = handle.id;
    }

    /// Registers the input handler for the focused element (text input).
    pub fn handle_input(self: *Window, focus_handle: *const FocusHandle, handler: platform_mod.PlatformInputHandler, cx: *App) void {
        _ = cx;
        if (self.focus_id == focus_handle.id) {
            self.next_frame.input_handlers.append(self.allocator, .{ .handler = handler, .focus_id = focus_handle.id }) catch oom();
        }
    }

    /// Draws `element` after the current tree, on top (GPUI `defer_draw`).
    pub fn defer_draw(self: *Window, element: AnyElement, absolute_offset: Point(Pixels), priority: usize) void {
        const stack = self.next_frame.arena.allocator().dupe(TextStyleRefinement, self.text_style_stack.items) catch oom();
        self.next_frame.deferred_draws.append(self.allocator, .{
            .priority = priority,
            .element = element,
            .absolute_offset = absolute_offset,
            .text_style_stack = stack,
            .parent_node = self.next_frame.dispatch_tree.active_node_id(),
            .element_id_hash = self.current_global_id().hash,
        }) catch oom();
    }

    // -- painting ------------------------------------------------------

    fn scaled_content_mask(self: *const Window) ContentMask(ScaledPixels) {
        return self.content_mask().scale(self.scale_factor_);
    }

    /// Paints layers of `paint` with a clipping layer (GPUI `paint_layer`).
    pub fn paint_layer(self: *Window, b: Bounds(Pixels), arg: anytype, comptime f: anytype, cx: *App) void {
        const clipped = b.intersect(self.content_mask().bounds);
        const scaled = clipped.scale(self.scale_factor_);
        const empty = clipped.size.width <= 0 or clipped.size.height <= 0;
        if (!empty) self.next_frame.scene.push_layer(scaled) catch oom();
        f(arg, self, cx);
        if (!empty) self.next_frame.scene.pop_layer() catch oom();
    }

    /// Paints box shadows outside `bounds`.
    pub fn paint_shadows(self: *Window, b: Bounds(Pixels), corner_radii: Corners(Pixels), shadows: []const style_mod.BoxShadow) void {
        const sf = self.scale_factor_;
        const opacity = self.element_opacity();
        for (shadows) |s| {
            if (s.inset) continue;
            const shadow_bounds = (Bounds(Pixels){ .origin = b.origin.add(s.offset), .size = b.size }).dilate(s.spread_radius);
            insertPrim(&self.next_frame.scene, .{ .shadow = .{
                .order = 0,
                .blur_radius = s.blur_radius * sf,
                .bounds = shadow_bounds.scale(sf),
                .content_mask = self.scaled_content_mask(),
                .corner_radii = corner_radii.scale(sf),
                .color = s.color.opacity(opacity),
            } });
        }
    }

    /// Paints a quad (GPUI `paint_quad`).
    pub fn paint_quad(self: *Window, q: PaintQuad) void {
        const sf = self.scale_factor_;
        const opacity = self.element_opacity();
        insertPrim(&self.next_frame.scene, .{ .quad = .{
            .order = 0,
            .border_style = q.border_style,
            .bounds = q.bounds.scale(sf),
            .content_mask = self.scaled_content_mask(),
            .background = q.background.opacity(opacity),
            .border_color = q.border_color.opacity(opacity),
            .corner_radii = q.corner_radii.scale(sf),
            .border_widths = q.border_widths.scale(sf),
        } });
    }

    /// Paints a path (GPUI `paint_path`). The scene takes ownership of `path`.
    pub fn paint_path(self: *Window, path: scene_mod.Path(Pixels), color: anytype) void {
        var p = path;
        defer p.deinit();
        var scaled = p.scale(self.scale_factor_) catch oom();
        scaled.content_mask = self.scaled_content_mask();
        scaled.color = color_mod.to_background(color).opacity(self.element_opacity());
        insertPrim(&self.next_frame.scene, .{ .path = scaled });
    }

    /// Paints an underline.
    pub fn paint_underline(self: *Window, origin: Point(Pixels), width: Pixels, style: *const style_mod.UnderlineStyle) void {
        const sf = self.scale_factor_;
        const height: Pixels = if (style.wavy) style.thickness * 3 else style.thickness;
        const b: Bounds(Pixels) = .{ .origin = origin, .size = .{ .width = width, .height = height } };
        insertPrim(&self.next_frame.scene, .{ .underline = .{
            .order = 0,
            .pad = 0,
            .bounds = b.scale(sf),
            .content_mask = self.scaled_content_mask(),
            .color = (style.color orelse color_mod.black()).opacity(self.element_opacity()),
            .thickness = style.thickness * sf,
            .wavy = .from(style.wavy),
        } });
    }

    /// Paints a strikethrough.
    pub fn paint_strikethrough(self: *Window, origin: Point(Pixels), width: Pixels, style: *const style_mod.StrikethroughStyle) void {
        const sf = self.scale_factor_;
        const b: Bounds(Pixels) = .{ .origin = origin, .size = .{ .width = width, .height = style.thickness } };
        insertPrim(&self.next_frame.scene, .{ .underline = .{
            .order = 0,
            .pad = 0,
            .bounds = b.scale(sf),
            .content_mask = self.scaled_content_mask(),
            .color = (style.color orelse color_mod.black()).opacity(self.element_opacity()),
            .thickness = style.thickness * sf,
            .wavy = .from(false),
        } });
    }

    /// Paints a monochrome glyph (GPUI `paint_glyph`).
    pub fn paint_glyph(self: *Window, origin: Point(Pixels), font_id: text_system_mod.FontId, glyph_id: text_system_mod.GlyphId, font_size: Pixels, color: Hsla) !void {
        const sf = self.scale_factor_;
        const go = origin.scale(sf);
        const SUBX = text_system_mod.SUBPIXEL_VARIANTS_X;
        const SUBY = text_system_mod.SUBPIXEL_VARIANTS_Y;
        const qx = @round(go.x * SUBX) / SUBX;
        const qy = @round(go.y * SUBY) / SUBY;
        const params: text_system_mod.RenderGlyphParams = .{
            .font_id = font_id,
            .glyph_id = glyph_id,
            .font_size = font_size,
            .subpixel_variant = .{ .x = @intFromFloat((qx - @floor(qx)) * SUBX), .y = @intFromFloat((qy - @floor(qy)) * SUBY) },
            .scale_factor = sf,
            .is_emoji = false,
        };
        const ts = self.text_system();
        const rb = try ts.raster_bounds(&params);
        if (rb.size.width == 0 or rb.size.height == 0) return;
        const tile = (try self.sprite_atlas.get_or_insert_with(params.atlas_key(), ts.tile_builder(&params))) orelse return;
        const b: Bounds(ScaledPixels) = .{
            .origin = .{ .x = @floor(qx) + @as(f32, @floatFromInt(rb.origin.x)), .y = @floor(qy) + @as(f32, @floatFromInt(rb.origin.y)) },
            .size = .{ .width = @floatFromInt(tile.bounds.size.width), .height = @floatFromInt(tile.bounds.size.height) },
        };
        insertPrim(&self.next_frame.scene, .{ .monochrome_sprite = .{
            .order = 0,
            .pad = 0,
            .bounds = b,
            .content_mask = self.scaled_content_mask(),
            .color = color.opacity(self.element_opacity()),
            .tile = tile,
            .transformation = scene_mod.TransformationMatrix.unit(),
        } });
    }

    /// Paints a color (emoji) glyph (GPUI `paint_emoji`).
    pub fn paint_emoji(self: *Window, origin: Point(Pixels), font_id: text_system_mod.FontId, glyph_id: text_system_mod.GlyphId, font_size: Pixels) !void {
        const sf = self.scale_factor_;
        const go = origin.scale(sf);
        const params: text_system_mod.RenderGlyphParams = .{
            .font_id = font_id,
            .glyph_id = glyph_id,
            .font_size = font_size,
            .subpixel_variant = .{ .x = 0, .y = 0 },
            .scale_factor = sf,
            .is_emoji = true,
        };
        const ts = self.text_system();
        const rb = try ts.raster_bounds(&params);
        if (rb.size.width == 0 or rb.size.height == 0) return;
        const tile = (try self.sprite_atlas.get_or_insert_with(params.atlas_key(), ts.tile_builder(&params))) orelse return;
        const b: Bounds(ScaledPixels) = .{
            .origin = .{ .x = @floor(go.x) + @as(f32, @floatFromInt(rb.origin.x)), .y = @floor(go.y) + @as(f32, @floatFromInt(rb.origin.y)) },
            .size = .{ .width = @floatFromInt(tile.bounds.size.width), .height = @floatFromInt(tile.bounds.size.height) },
        };
        insertPrim(&self.next_frame.scene, .{ .polychrome_sprite = .{
            .order = 0,
            .pad = 0,
            .grayscale = .from(false),
            .opacity = self.element_opacity(),
            .bounds = b,
            .content_mask = self.scaled_content_mask(),
            .corner_radii = Corners(ScaledPixels).all(0),
            .tile = tile,
        } });
    }

    /// Paints an already-rasterized polychrome image tile.
    pub fn paint_polychrome_tile(self: *Window, b: Bounds(Pixels), corner_radii: Corners(Pixels), tile: atlas_mod.AtlasTile, grayscale: bool) void {
        const sf = self.scale_factor_;
        insertPrim(&self.next_frame.scene, .{ .polychrome_sprite = .{
            .order = 0,
            .pad = 0,
            .grayscale = .from(grayscale),
            .opacity = self.element_opacity(),
            .bounds = b.scale(sf),
            .content_mask = self.scaled_content_mask(),
            .corner_radii = corner_radii.scale(sf),
            .tile = tile,
        } });
    }

    /// Paints a monochrome tile (e.g. a rasterized SVG) tinted with `color`.
    pub fn paint_monochrome_tile(self: *Window, b: Bounds(Pixels), tile: atlas_mod.AtlasTile, color: Hsla, transformation: scene_mod.TransformationMatrix) void {
        const sf = self.scale_factor_;
        insertPrim(&self.next_frame.scene, .{ .monochrome_sprite = .{
            .order = 0,
            .pad = 0,
            .bounds = b.scale(sf),
            .content_mask = self.scaled_content_mask(),
            .color = color.opacity(self.element_opacity()),
            .tile = tile,
            .transformation = transformation,
        } });
    }

    // -- drawing -------------------------------------------------------

    /// Produces a new frame: layout, prepaint and paint of the root view.
    pub fn draw(self: *Window, cx: *App) void {
        self.drawing = true;
        defer self.drawing = false;
        self.dirty = false;
        self.animation_requested = false;
        self.frame_count += 1;

        // Callbacks registered with on_next_frame.
        if (self.next_frame_callbacks.items.len > 0) {
            const cbs = self.allocator.dupe(FrameCallback, self.next_frame_callbacks.items) catch oom();
            defer self.allocator.free(cbs);
            self.next_frame_callbacks.clearRetainingCapacity();
            for (cbs) |cb| cb.func(cb.ctx, self, cx);
        }

        self.next_frame.clear();
        self.layout_engine.clear();
        self.next_rendered_entities.clearRetainingCapacity();
        self.next_hitbox_id = 1;
        self.text_style_stack.clearRetainingCapacity();
        self.element_offset_stack.clearRetainingCapacity();
        self.content_mask_stack.clearRetainingCapacity();
        self.element_opacity_stack.clearRetainingCapacity();
        self.element_id_stack.clearRetainingCapacity();
        self.element_id_hashes.clearRetainingCapacity();
        _ = self.element_arena.reset(.retain_capacity);
        const prev_arena = current_frame_arena;
        current_frame_arena = &self.next_frame.arena;
        defer current_frame_arena = prev_arena;

        cx.pending_updates += 1;
        if (self.root) |root| {
            const el = root.into_any_element();
            el.prepaint_as_root(.{ .x = 0, .y = 0 }, .{
                .width = .{ .definite = self.viewport_size.width },
                .height = .{ .definite = self.viewport_size.height },
            }, self, cx);
            self.prepaint_deferred_draws(cx);
            el.paint(self, cx);
            self.paint_deferred_draws(cx);
        }
        cx.pending_updates -= 1;

        self.next_frame.scene.finish();
        self.next_frame.focus = self.focus_id;
        self.next_frame.window_active = self.active;

        std.mem.swap(Frame, &self.rendered_frame, &self.next_frame);
        self.text_system().finish_frame();
        std.mem.swap(std.AutoHashMapUnmanaged(EntityId, void), &self.rendered_entities, &self.next_rendered_entities);
        self.gc_element_states();
        self.hit_test(self.mouse_position_);
        self.update_cursor();
        self.update_input_handler();
        self.needs_present = true;
        // Effects queued during render (e.g. notify) are processed now.
        cx.flush_effects();
    }

    fn prepaint_deferred_draws(self: *Window, cx: *App) void {
        const draws = self.next_frame.deferred_draws.items;
        std.sort.pdq(DeferredDraw, draws, {}, struct {
            fn lt(_: void, a: DeferredDraw, b: DeferredDraw) bool {
                return a.priority < b.priority;
            }
        }.lt);
        var i: usize = 0;
        while (i < self.next_frame.deferred_draws.items.len) : (i += 1) {
            const d = self.next_frame.deferred_draws.items[i];
            const saved = self.text_style_stack.items.len;
            self.text_style_stack.appendSlice(self.allocator, d.text_style_stack) catch oom();
            // The deferred child was laid out by `Deferred.request_layout`; GPUI only prepaints it here.
            d.element.prepaint_at(d.absolute_offset, self, cx);
            self.text_style_stack.shrinkRetainingCapacity(saved);
        }
    }

    fn paint_deferred_draws(self: *Window, cx: *App) void {
        for (self.next_frame.deferred_draws.items) |d| {
            const saved = self.text_style_stack.items.len;
            self.text_style_stack.appendSlice(self.allocator, d.text_style_stack) catch oom();
            d.element.paint(self, cx);
            self.text_style_stack.shrinkRetainingCapacity(saved);
        }
    }

    fn update_cursor(self: *Window) void {
        var style: CursorStyle = .arrow;
        var i = self.rendered_frame.cursor_styles.items.len;
        while (i > 0) {
            i -= 1;
            const r = self.rendered_frame.cursor_styles.items[i];
            if (r.hitbox_id) |hid| {
                if (self.hitbox_is_hovered(hid)) {
                    style = r.style;
                    break;
                }
            } else {
                style = r.style;
                break;
            }
        }
        self.app.platform.set_cursor_style(style);
    }

    fn update_input_handler(self: *Window) void {
        const handlers = self.rendered_frame.input_handlers.items;
        if (handlers.len > 0) {
            self.platform_window.set_input_handler(handlers[handlers.len - 1].handler);
        } else {
            self.platform_window.take_input_handler();
        }
    }

    /// Presents the last drawn frame to the platform window.
    pub fn present(self: *Window) void {
        if (!self.needs_present) return;
        self.needs_present = false;
        self.platform_window.draw(&self.rendered_frame.scene);
    }

    // -- event dispatch ------------------------------------------------

    /// Dispatches platform input; returns whether it was handled.
    pub fn dispatch_event(self: *Window, event: interactive.PlatformInput, cx: *App) bool {
        self.default_prevented = false;
        self.propagate_event = true;
        cx.pending_updates += 1;
        defer {
            cx.pending_updates -= 1;
            if (cx.pending_updates == 0) cx.flush_effects();
        }
        const prev_arena = current_frame_arena;
        current_frame_arena = &self.rendered_frame.arena;
        defer current_frame_arena = prev_arena;
        switch (event) {
            .mouse_move => |e| {
                self.mouse_position_ = e.position;
                self.modifiers_ = e.modifiers;
                self.last_input_was_keyboard = false;
                self.dispatch_mouse(interactive.MouseMoveEvent, &e, cx);
            },
            .mouse_down => |e| {
                self.mouse_position_ = e.position;
                self.modifiers_ = e.modifiers;
                self.last_input_was_keyboard = false;
                self.dispatch_mouse(interactive.MouseDownEvent, &e, cx);
            },
            .mouse_up => |e| {
                self.mouse_position_ = e.position;
                self.modifiers_ = e.modifiers;
                self.dispatch_mouse(interactive.MouseUpEvent, &e, cx);
            },
            .mouse_exited => |e| {
                self.mouse_position_ = e.position;
                self.modifiers_ = e.modifiers;
                self.dispatch_mouse(interactive.MouseExitEvent, &e, cx);
            },
            .scroll_wheel => |e| {
                self.mouse_position_ = e.position;
                self.modifiers_ = e.modifiers;
                self.dispatch_mouse(interactive.ScrollWheelEvent, &e, cx);
            },
            .modifiers_changed => |e| {
                self.modifiers_ = e.modifiers;
                self.capslock = e.capslock;
                self.dispatch_mouse(interactive.ModifiersChangedEvent, &e, cx);
            },
            .key_down => |e| {
                self.modifiers_ = e.keystroke.modifiers;
                self.last_input_was_keyboard = true;
                self.dispatch_key_event(interactive.KeyDownEvent, &e, cx);
            },
            .key_up => |e| {
                self.modifiers_ = e.keystroke.modifiers;
                self.dispatch_key_event(interactive.KeyUpEvent, &e, cx);
            },
            .file_drop => |e| {
                self.dispatch_mouse(interactive.FileDropEvent, &e, cx);
            },
            else => {},
        }
        return !self.propagate_event or self.default_prevented;
    }

    fn dispatch_mouse(self: *Window, comptime E: type, event: *const E, cx: *App) void {
        self.hit_test(self.mouse_position_);
        const tid = app_mod.type_id(E);
        const listeners = self.rendered_frame.mouse_listeners.items;
        // Capture phase: back to front.
        for (listeners) |l| {
            if (l.event_type != tid) continue;
            l.func(l.ctx, event, .capture, self, cx);
            if (!self.propagate_event) break;
        }
        if (self.propagate_event) {
            var i = listeners.len;
            while (i > 0) {
                i -= 1;
                const l = listeners[i];
                if (l.event_type != tid) continue;
                l.func(l.ctx, event, .bubble, self, cx);
                if (!self.propagate_event) break;
            }
        }
        if (E == interactive.MouseMoveEvent) self.update_cursor();
    }

    fn dispatch_key_event(self: *Window, comptime E: type, event: *const E, cx: *App) void {
        const tree = &self.rendered_frame.dispatch_tree;
        const path = tree.dispatch_path(self.focus_id, self.allocator);
        defer self.allocator.free(path);
        const tid = app_mod.type_id(E);

        // Keybindings first (key down only).
        if (E == interactive.KeyDownEvent) {
            const contexts = tree.context_stack(path, self.allocator);
            defer self.allocator.free(contexts);
            if (cx.keymap.binding_for(event.keystroke, contexts)) |binding| {
                const action = binding.action;
                self.dispatch_action_on_path(path, action, cx);
                if (!self.propagate_event) return;
            }
        }
        // Capture.
        for (path) |nid| {
            for (tree.node(nid).key_listeners.items) |l| {
                if (l.event_type != tid) continue;
                l.func(l.ctx, event, .capture, self, cx);
                if (!self.propagate_event) return;
            }
        }
        // Bubble.
        var i = path.len;
        while (i > 0) {
            i -= 1;
            for (tree.node(path[i]).key_listeners.items) |l| {
                if (l.event_type != tid) continue;
                l.func(l.ctx, event, .bubble, self, cx);
                if (!self.propagate_event) return;
            }
        }
        // Unhandled key-down: deliver text to the input handler.
        if (E == interactive.KeyDownEvent) {
            if (event.keystroke.key_char) |text| {
                if (!event.keystroke.modifiers.control and !event.keystroke.modifiers.platform) {
                    if (self.platform_window.input_handler()) |h| {
                        var handler = h;
                        handler.replace_text_in_range(null, text, self, cx);
                    }
                }
            }
        }
    }

    /// Dispatches a boxed action along the focus path, then globally.
    pub fn dispatch_action(self: *Window, action: action_mod.AnyAction, cx: *App) void {
        self.propagate_event = true;
        const path = self.rendered_frame.dispatch_tree.dispatch_path(self.focus_id, self.allocator);
        defer self.allocator.free(path);
        self.dispatch_action_on_path(path, action, cx);
        cx.flush_effects();
    }

    fn dispatch_action_on_path(self: *Window, path: []const key_dispatch.DispatchNodeId, action: action_mod.AnyAction, cx: *App) void {
        const tree = &self.rendered_frame.dispatch_tree;
        for (path) |nid| {
            for (tree.node(nid).action_listeners.items) |l| {
                if (l.action_type != action.type_id) continue;
                l.func(l.ctx, action.ptr, .capture, self, cx);
                if (!self.propagate_event) return;
            }
        }
        var i = path.len;
        while (i > 0) {
            i -= 1;
            for (tree.node(path[i]).action_listeners.items) |l| {
                if (l.action_type != action.type_id) continue;
                self.propagate_event = false;
                l.func(l.ctx, action.ptr, .bubble, self, cx);
                if (!self.propagate_event) return;
            }
        }
        cx.dispatch_global_action(action);
    }

    pub fn is_action_available(self: *Window, action_type: app_mod.TypeId) bool {
        const tree = &self.rendered_frame.dispatch_tree;
        const path = tree.dispatch_path(self.focus_id, self.allocator);
        defer self.allocator.free(path);
        for (path) |nid| for (tree.node(nid).action_listeners.items) |l| if (l.action_type == action_type) return true;
        return false;
    }

    // -- platform callbacks ---------------------------------------------

    fn onRequestFrame(ctx: *anyopaque, opts: platform_mod.RequestFrameOptions) void {
        const self: *Window = @ptrCast(@alignCast(ctx));
        if (self.dirty or self.animation_requested or opts.force_render) {
            self.draw(self.app);
        }
        self.present();
    }

    fn onInput(ctx: *anyopaque, event: interactive.PlatformInput) platform_mod.DispatchEventResult {
        const self: *Window = @ptrCast(@alignCast(ctx));
        const handled = self.dispatch_event(event, self.app);
        return .{ .propagate = !handled, .default_prevented = self.default_prevented };
    }

    fn onActiveStatusChange(ctx: *anyopaque, active: bool) void {
        const self: *Window = @ptrCast(@alignCast(ctx));
        self.active = active;
        self.refresh();
    }

    fn onHoverStatusChange(ctx: *anyopaque, hovered: bool) void {
        const self: *Window = @ptrCast(@alignCast(ctx));
        self.hovered = hovered;
    }

    fn onResize(ctx: *anyopaque, size: Size(Pixels), scale: f32) void {
        const self: *Window = @ptrCast(@alignCast(ctx));
        self.viewport_size = size;
        self.scale_factor_ = scale;
        self.refresh();
    }

    fn onShouldClose(ctx: *anyopaque) bool {
        const self: *Window = @ptrCast(@alignCast(ctx));
        _ = self;
        return true;
    }

    fn onClose(ctx: *anyopaque) void {
        const self: *Window = @ptrCast(@alignCast(ctx));
        self.app.close_window(self);
    }

    fn onAppearanceChanged(ctx: *anyopaque) void {
        const self: *Window = @ptrCast(@alignCast(ctx));
        self.appearance_ = self.platform_window.appearance();
        self.refresh();
    }
};

fn oom() noreturn {
    @panic("out of memory");
}

fn insertPrim(scene: *scene_mod.Scene, p: scene_mod.Primitive) void {
    scene.insert_primitive(p) catch oom();
}
