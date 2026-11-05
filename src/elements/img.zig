//! Port of GPUI `elements/img.rs`: the `img()` element, a styled element that
//! paints a decoded image with object-fit, grayscale and fallback support.
//!
//! Loads are synchronous (see `assets.zig`), so the `loading` state is stored
//! for API parity but never shown. The fallback element is laid out and painted
//! from `paint_ext`, since `StyledElement` has no prepaint hook for extensions.

const std = @import("std");
const geometry = @import("../geometry.zig");
const style_mod = @import("../style.zig");
const element_mod = @import("../element.zig");
const taffy = @import("../taffy.zig");
const window_mod = @import("../window.zig");
const app_mod = @import("../app.zig");
const atlas = @import("../atlas.zig");
const assets = @import("../assets.zig");
const div = @import("div.zig");

const Window = window_mod.Window;
const App = app_mod.App;
const Style = style_mod.Style;
const Pixels = geometry.Pixels;
const DevicePixels = geometry.DevicePixels;
const Size = geometry.Size;
const Bounds = geometry.Bounds;
const AnyElement = element_mod.AnyElement;
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

    /// Element shown while loading (GPUI `with_loading`). Loads are synchronous, so it is not shown yet.
    pub fn with_loading(self: anytype, f: *const fn () AnyElement) @TypeOf(self) {
        self.ext.loading_ = f;
        return self;
    }

    pub fn request_layout_ext(self: anytype, s: *Style, window: *Window, cx: *App) ?LayoutId {
        const e = &self.ext;
        e.data = null;
        e.replacement = null;
        const source = e.source orelse return null;

        const data = source.use_data(&cx.asset_cache, cx.asset_source) catch |err| {
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

        // Intrinsic size in logical pixels; the measure callback fills whichever dimension is auto.
        const measure = window_mod.frame_arena().create(Measure) catch @panic("OOM");
        measure.* = .{ .intrinsic = data.render_size(0) };
        return window.request_measured_layout(s, .{ .ctx = measure, .func = Measure.measure });
    }

    pub fn paint_ext(self: anytype, bounds: Bounds(Pixels), s: *const Style, window: *Window, cx: *App) void {
        const e = &self.ext;
        if (e.data) |data| {
            if (data.frame_count() == 0) return;
            const frame: usize = 0;
            const new_bounds = e.object_fit_.get_bounds(bounds, data.size(frame));
            const visible = bounds.intersect(new_bounds);
            if (visible.size.width <= 0 or visible.size.height <= 0) return;
            if (new_bounds.size.width <= 0 or new_bounds.size.height <= 0) return;

            var builder = ImageTile{ .image = data, .frame = frame };
            const key = atlas.AtlasKey{ .image = image_key(data.id, frame) };
            const tile = (window.sprite_atlas.get_or_insert_with(key, .{ .context = &builder, .build_fn = ImageTile.build }) catch return) orelse return;

            const radii = s.corner_radii.to_pixels(window.rem_size()).clamp_radii_for_quad_size(visible.size);
            window.paint_polychrome_tile(visible, radii, sub_tile(tile, new_bounds, visible), e.grayscale_);
        } else if (e.replacement) |rep| {
            rep.prepaint(window, cx);
            rep.paint(window, cx);
        }
    }
};

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

/// Atlas builder for one frame of a decoded image. The pixels stay owned by the `RenderImage`.
const ImageTile = struct {
    image: *assets.RenderImage,
    frame: usize,

    fn build(raw: *anyopaque) anyerror!?atlas.TileData {
        const self: *const ImageTile = @ptrCast(@alignCast(raw));
        const bytes = self.image.as_bytes(self.frame) orelse return null;
        const s = self.image.size(self.frame);
        return .{ .size = s, .bytes = bytes };
    }
};

/// Atlas key for one frame of an image: a hash of the image id and frame index.
fn image_key(id: u64, frame: usize) u64 {
    const parts = [_]u64{ id, frame };
    return std.hash.Wyhash.hash(0x696d6720, std.mem.sliceAsBytes(&parts));
}

/// The part of `tile` that shows `visible`, where `image` is the full drawn rectangle (GPUI's sub-tile for clipped images).
fn sub_tile(tile: atlas.AtlasTile, image: Bounds(Pixels), visible: Bounds(Pixels)) atlas.AtlasTile {
    if (visible.eq(image)) return tile;
    const iw = image.size.width;
    const ih = image.size.height;
    const tw: f32 = @floatFromInt(tile.bounds.size.width);
    const th: f32 = @floatFromInt(tile.bounds.size.height);
    var out = tile;
    const x_off = (visible.origin.x - image.origin.x) / iw;
    const y_off = (visible.origin.y - image.origin.y) / ih;
    out.bounds.origin.x = tile.bounds.origin.x + @as(DevicePixels, @intFromFloat(@round(x_off * tw)));
    out.bounds.origin.y = tile.bounds.origin.y + @as(DevicePixels, @intFromFloat(@round(y_off * th)));
    out.bounds.size.width = @max(1, @as(DevicePixels, @intFromFloat(@round(visible.size.width / iw * tw))));
    out.bounds.size.height = @max(1, @as(DevicePixels, @intFromFloat(@round(visible.size.height / ih * th))));
    return out;
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

test "sub_tile crops the atlas tile to the visible part" {
    const tile: atlas.AtlasTile = .{
        .texture_id = .{ .index = 0, .kind = .polychrome },
        .tile_id = .{ .value = 1 },
        .padding = 0,
        .bounds = .{ .origin = .{ .x = 0, .y = 0 }, .size = .{ .width = 200, .height = 100 } },
    };
    // Image drawn at 100x100 but only the right half of a 200x100 cover is visible.
    const image: Bounds(Pixels) = .{ .origin = .{ .x = 0, .y = 0 }, .size = .{ .width = 200, .height = 100 } };
    const visible: Bounds(Pixels) = .{ .origin = .{ .x = 50, .y = 0 }, .size = .{ .width = 100, .height = 100 } };
    const sub = sub_tile(tile, image, visible);
    try std.testing.expectEqual(@as(DevicePixels, 50), sub.bounds.origin.x);
    try std.testing.expectEqual(@as(DevicePixels, 100), sub.bounds.size.width);
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
