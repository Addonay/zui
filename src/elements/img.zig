//! Port of GPUI `elements/img.rs`: the `img()` element, a styled element that
//! paints a decoded image with object-fit, grayscale and fallback support.
//!
//! URLs load in the background (see `assets.zig`); `with_loading` shows while they do. GPUI waits
//! `LOADING_DELAY` before showing it, which ZUI does not yet. Images load through the image cache
//! in scope (`image_cache`, see `image_cache.zig`), or else through the app's own cache. The fallback
//! element is laid out and painted from `paint_ext`, since `StyledElement` has no prepaint hook for
//! extensions.

const std = @import("std");
const geometry = @import("../geometry.zig");
const style_mod = @import("../style.zig");
const element_mod = @import("../element.zig");
const taffy = @import("../taffy.zig");
const window_mod = @import("../window.zig");
const app_mod = @import("../app.zig");
const atlas = @import("../atlas.zig");
const assets = @import("../assets.zig");
const executor = @import("../executor.zig");
const div = @import("div.zig");

const Window = window_mod.Window;
const App = app_mod.App;
const Style = style_mod.Style;
const Pixels = geometry.Pixels;
const DevicePixels = geometry.DevicePixels;
const Size = geometry.Size;
const Bounds = geometry.Bounds;
const AnyElement = element_mod.AnyElement;
const GlobalElementId = element_mod.GlobalElementId;
const LayoutId = taffy.LayoutId;

/// An image element (GPUI `Img`).
pub const Img = div.StyledElement(ImgExt);

/// Creates an image element from a string (URL or embedded asset name),
/// an `assets.Resource`, an `assets.ImageSource`, a `*assets.RenderImage`, or a `*assets.Image`.
pub fn img(source: anytype) *Img {
    const i = Img.new();
    i.ext.source = assets.ImageSource.from(source);
    return i;
}

/// Image formats the `img` element accepts (GPUI `Img::extensions`).
pub fn extensions() []const []const u8 {
    return assets.supported_extensions();
}

/// Element-specific state and style for `Img`. Per-frame fields are set by `request_layout_ext`.
pub const ImgExt = struct {
    source: ?assets.ImageSource = null,
    object_fit_: style_mod.ObjectFit = .contain,
    grayscale_: bool = false,
    loading_: ?*const fn () AnyElement = null,
    fallback_: ?*const fn () AnyElement = null,

    /// The decoded image for this frame, or null if it failed to load.
    data: ?*assets.RenderImage = null,
    /// The fallback element, when loading failed and a fallback was set.
    replacement: ?AnyElement = null,
    /// The frame of a multi-frame image to paint this frame (GPUI `ImgLayoutState::frame_index`).
    frame_index: usize = 0,

    /// How the image fits its bounds (GPUI `object_fit`).
    pub fn object_fit(self: anytype, v: style_mod.ObjectFit) @TypeOf(self) {
        self.ext.object_fit_ = v;
        return self;
    }

    /// Draws the image in grayscale (GPUI `grayscale`).
    pub fn grayscale(self: anytype, v: bool) @TypeOf(self) {
        self.ext.grayscale_ = v;
        return self;
    }

    /// Element shown when the image fails to load (GPUI `with_fallback`).
    pub fn with_fallback(self: anytype, f: *const fn () AnyElement) @TypeOf(self) {
        self.ext.fallback_ = f;
        return self;
    }

    /// Element shown while loading (GPUI `with_loading`).
    pub fn with_loading(self: anytype, f: *const fn () AnyElement) @TypeOf(self) {
        self.ext.loading_ = f;
        return self;
    }

    pub fn request_layout_ext(self: anytype, gid: ?*const GlobalElementId, s: *Style, window: *Window, cx: *App) ?LayoutId {
        const e = &self.ext;
        e.data = null;
        e.replacement = null;
        e.frame_index = 0;
        const source = e.source orelse return null;

        const data = load_image(source, window, cx) catch |err| {
            const placeholder = if (err == error.Loading) e.loading_ else e.fallback_;
            if (placeholder) |build| {
                const rep = build();
                const child = rep.request_layout(window, cx);
                e.replacement = rep;
                return window.request_layout(s, &.{child}, cx);
            }
            return window.request_layout(s, &.{}, cx);
        };
        e.data = data;
        e.frame_index = advance_frame(data, gid, window, cx);

        // Intrinsic size in logical pixels; the measure callback fills whichever dimension is auto.
        const measure = window_mod.frame_arena().create(Measure) catch @panic("OOM");
        measure.* = .{ .intrinsic = data.render_size(e.frame_index) };
        return window.request_measured_layout(s, .{ .ctx = measure, .func = Measure.measure });
    }

    pub fn paint_ext(self: anytype, bounds: Bounds(Pixels), s: *const Style, window: *Window, cx: *App) void {
        const e = &self.ext;
        if (e.data) |data| {
            if (data.frame_count() == 0) return;
            const frame = e.frame_index;
            const new_bounds = e.object_fit_.get_bounds(bounds, data.size(frame));
            window.paint_image(bounds, new_bounds, s.corner_radii.to_pixels(window.rem_size()), data, frame, e.grayscale_) catch |err| {
                std.log.err("img: paint_image failed: {s}", .{@errorName(err)});
            };
        } else if (e.replacement) |rep| {
            rep.prepaint(window, cx);
            rep.paint(window, cx);
        }
    }
};

/// Per-element animation state of a multi-frame image (GPUI `ImgState`).
const ImgState = struct {
    frame_index: usize = 0,
    /// Awake-clock time the current frame started; null while the image is not animating.
    last_frame_time: ?u64 = null,
};

/// Moves a GIF on to its next frame once the current frame's delay has passed, and asks the window
/// for another frame while it does. Without an element id there is no state, so nothing animates.
fn advance_frame(data: *assets.RenderImage, gid: ?*const GlobalElementId, window: *Window, cx: *App) usize {
    const frame_count = data.frame_count();
    const state = window.element_state(ImgState, (gid orelse return 0).*, .{});
    state.frame_index = @min(state.frame_index, frame_count -| 1);

    const animating = frame_count > 1 and window.is_window_active() and !cx.reduce_motion;
    if (!animating) {
        state.last_frame_time = null;
        return state.frame_index;
    }
    const now = executor.now_ns();
    if (state.last_frame_time) |last| {
        const frame_duration = @as(u64, data.delay(state.frame_index)) * std.time.ns_per_ms;
        if (now -| last >= frame_duration) {
            state.frame_index = (state.frame_index + 1) % frame_count;
            state.last_frame_time = last + frame_duration;
        }
    } else {
        state.last_frame_time = now;
    }
    window.request_animation_frame();
    return state.frame_index;
}

const Measure = struct {
    intrinsic: Size(Pixels),

    /// Resolves the image size given the known dimensions, keeping the aspect ratio (GPUI `Img` auto sizing).
    fn measure(ctx: *anyopaque, known: Size(?Pixels), available: Size(taffy.AvailableSpace), window: *Window, cx: *App) Size(Pixels) {
        _ = available;
        _ = window;
        _ = cx;
        const m: *const Measure = @ptrCast(@alignCast(ctx));
        const iw = m.intrinsic.width;
        const ih = m.intrinsic.height;
        if (known.width) |w| {
            if (known.height) |h| return .{ .width = w, .height = h };
            if (iw <= 0) return .{ .width = w, .height = 0 };
            return .{ .width = w, .height = w * ih / iw };
        }
        if (known.height) |h| {
            if (ih <= 0) return .{ .width = 0, .height = h };
            return .{ .width = h * iw / ih, .height = h };
        }
        return m.intrinsic;
    }
};

/// Loads `source` (GPUI `ImageSource::use_data`). A URL, file or asset name goes through the image
/// cache in scope, if an ancestor set one: that is where `null` means "still loading". Otherwise it
/// goes through the app's own cache. A custom source is always asked, with this window.
fn load_image(source: assets.ImageSource, window: *Window, cx: *App) assets.ImageCacheError!*assets.RenderImage {
    switch (source) {
        .resource => |resource| if (window.current_image_cache()) |cache| {
            return cache.load(resource, window, cx) orelse error.Loading;
        },
        .custom => |custom| return custom.load_fn(custom.ptr, window, cx) orelse error.Loading,
        else => {},
    }
    return source.use_data(&cx.asset_cache, cx.asset_source);
}

test "measure keeps the aspect ratio of the intrinsic size" {
    const m: Measure = .{ .intrinsic = .{ .width = 200, .height = 100 } };
    const ctx: *anyopaque = @constCast(&m);
    const no_space: Size(taffy.AvailableSpace) = undefined;
    var win: Window = undefined;
    var app: App = undefined;

    const both_auto = Measure.measure(ctx, .{ .width = null, .height = null }, no_space, &win, &app);
    try std.testing.expectEqual(@as(f32, 200), both_auto.width);
    try std.testing.expectEqual(@as(f32, 100), both_auto.height);

    const width_known = Measure.measure(ctx, .{ .width = 50, .height = null }, no_space, &win, &app);
    try std.testing.expectEqual(@as(f32, 25), width_known.height);
}

test "element protocol instantiates the image hooks" {
    // Referencing the protocol functions instantiates `StyledElement(ImgExt)` and type-checks the hooks.
    _ = &Img.request_layout;
    _ = &Img.prepaint;
    _ = &Img.paint;
    _ = &Img.object_fit;
    _ = &Img.grayscale;
    _ = &Img.with_fallback;
}

test {
    std.testing.refAllDecls(@This());
}
