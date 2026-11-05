//! Port of GPUI `elements/svg.rs`: the `svg()` element. It rasterizes an SVG
//! to an alpha mask (cached in the sprite atlas) and paints it tinted with the
//! text color, like GPUI's `svg().path(...).text_color(...)`.

const std = @import("std");
const geometry = @import("../geometry.zig");
const style_mod = @import("../style.zig");
const scene = @import("../scene.zig");
const window_mod = @import("../window.zig");
const app_mod = @import("../app.zig");
const atlas = @import("../atlas.zig");
const assets = @import("../assets.zig");
const svg_renderer = @import("../svg_renderer.zig");
const div = @import("div.zig");

const Window = window_mod.Window;
const App = app_mod.App;
const Style = style_mod.Style;
const Pixels = geometry.Pixels;
const DevicePixels = geometry.DevicePixels;
const Size = geometry.Size;
const Point = geometry.Point;
const Bounds = geometry.Bounds;

/// An SVG element (GPUI `Svg`).
pub const Svg = div.StyledElement(SvgExt);

/// Creates an SVG element. Set its source with `path`, `external_path` or `data`.
pub fn svg() *Svg {
    return Svg.new();
}

/// A transformation applied when painting an SVG; it does not change layout or hitboxes (GPUI `Transformation`).
pub const Transformation = struct {
    scaling: Size(f32) = .{ .width = 1, .height = 1 },
    translation: Point(Pixels) = .{ .x = 0, .y = 0 },
    /// Clockwise rotation in radians.
    rotation: f32 = 0,

    /// Scales along each axis.
    pub fn scale(s: Size(f32)) Transformation {
        return .{ .scaling = s };
    }

    /// Translates by `t`, in logical pixels.
    pub fn translate(t: Point(Pixels)) Transformation {
        return .{ .translation = t };
    }

    /// Rotates around the element center by radians, or by a `Percentage` of a full turn.
    pub fn rotate(angle: anytype) Transformation {
        return .{ .rotation = geometry.to_radians(angle) };
    }

    pub fn with_scaling(self: Transformation, s: Size(f32)) Transformation {
        var t = self;
        t.scaling = s;
        return t;
    }

    pub fn with_translation(self: Transformation, tr: Point(Pixels)) Transformation {
        var t = self;
        t.translation = tr;
        return t;
    }

    pub fn with_rotation(self: Transformation, angle: anytype) Transformation {
        var t = self;
        t.rotation = geometry.to_radians(angle);
        return t;
    }

    /// The matrix in device pixels, applied around `center` (GPUI `into_matrix`).
    pub fn into_matrix(self: Transformation, center: Point(Pixels), scale_factor: f32) scene.TransformationMatrix {
        const cx = center.x * scale_factor;
        const cy = center.y * scale_factor;
        // Read right to left: move the center to the origin, scale, rotate, then move back and apply the translation.
        return scene.TransformationMatrix.unit()
            .translate(.{ .x = cx + self.translation.x * scale_factor, .y = cy + self.translation.y * scale_factor })
            .rotate(self.rotation)
            .scale(self.scaling)
            .translate(.{ .x = -cx, .y = -cy });
    }
};

/// Element-specific state and style for `Svg`.
pub const SvgExt = struct {
    path_: ?[]const u8 = null,
    external_path_: ?[]const u8 = null,
    data_: ?[]const u8 = null,
    /// Hash of `data_`, the atlas key component for inline data.
    data_key: u64 = 0,
    transformation_: ?Transformation = null,

    /// Sets the embedded asset path, read through the app's `AssetSource` (GPUI `path`).
    pub fn path(self: anytype, p: []const u8) @TypeOf(self) {
        self.ext.path_ = p;
        return self;
    }

    /// Sets a file path read from disk (GPUI `external_path`).
    pub fn external_path(self: anytype, p: []const u8) @TypeOf(self) {
        self.ext.external_path_ = p;
        return self;
    }

    /// Sets inline SVG bytes, which must outlive the frame (GPUI `data`).
    pub fn data(self: anytype, bytes: []const u8) @TypeOf(self) {
        self.ext.data_ = bytes;
        self.ext.data_key = std.hash.Wyhash.hash(0x73766764, bytes);
        return self;
    }

    /// Transforms the painted artwork (GPUI `with_transformation`).
    pub fn with_transformation(self: anytype, t: Transformation) @TypeOf(self) {
        self.ext.transformation_ = t;
        return self;
    }

    /// Paints the mask tinted with `style.text.color`. Nothing is painted without a text color, as in GPUI.
    pub fn paint_ext(self: anytype, bounds: Bounds(Pixels), s: *const Style, window: *Window, cx: *App) void {
        const color = s.text.color orelse return;
        const e = &self.ext;
        const sf = window.scale_factor();
        const transformation = if (e.transformation_) |t| t.into_matrix(bounds.center(), sf) else scene.TransformationMatrix.unit();

        const source: SvgSource = if (e.data_) |bytes|
            .{ .data = .{ .bytes = bytes, .key = e.data_key } }
        else if (e.external_path_) |p|
            .{ .external = p }
        else if (e.path_) |p|
            .{ .asset = p }
        else
            return;

        // Rasterize at twice the device size, then draw at half size: smoother edges (GPUI SMOOTH_SVG_SCALE_FACTOR).
        const smooth = svg_renderer.SMOOTH_SVG_SCALE_FACTOR;
        const device_size: Size(DevicePixels) = .{
            .width = @intFromFloat(@ceil(bounds.size.width * sf * smooth)),
            .height = @intFromFloat(@ceil(bounds.size.height * sf * smooth)),
        };
        if (device_size.width <= 0 or device_size.height <= 0) return;

        var ctx: SvgTile = .{ .cache = &cx.asset_cache, .source = cx.asset_source, .src = source, .size = device_size };
        const key = atlas.AtlasKey{ .svg = svg_key(source, device_size) };
        const tile = (window.sprite_atlas.get_or_insert_with(key, .{ .context = &ctx, .build_fn = SvgTile.build }) catch return) orelse return;

        // Draw at half the tile size, centered on the bounds. The origin is rounded in device pixels (GPUI).
        const draw_w = @as(f32, @floatFromInt(tile.bounds.size.width)) / smooth;
        const draw_h = @as(f32, @floatFromInt(tile.bounds.size.height)) / smooth;
        const center = bounds.center();
        const ox = @round(center.x * sf - draw_w / 2.0);
        const oy = @round(center.y * sf - draw_h / 2.0);
        const svg_bounds: Bounds(Pixels) = .{
            .origin = .{ .x = ox / sf, .y = oy / sf },
            .size = .{ .width = draw_w / sf, .height = draw_h / sf },
        };
        window.paint_monochrome_tile(svg_bounds, tile, color, transformation);
    }
};

/// Where an SVG's bytes come from.
const SvgSource = union(enum) {
    data: struct { bytes: []const u8, key: u64 },
    external: []const u8,
    asset: []const u8,
};

/// Key for the rasterized mask: source identity plus the device size.
fn svg_key(source: SvgSource, size: Size(DevicePixels)) u64 {
    const id: u64 = switch (source) {
        .data => |d| d.key,
        .external => |p| std.hash.Wyhash.hash(0x65787400, p),
        .asset => |p| std.hash.Wyhash.hash(0x61737400, p),
    };
    const dims = [_]u64{ @intCast(size.width), @intCast(size.height) };
    return std.hash.Wyhash.hash(id, std.mem.sliceAsBytes(&dims));
}

/// Atlas builder: loads the SVG source and rasterizes it to an alpha mask.
const SvgTile = struct {
    cache: *assets.AssetCache,
    source: assets.AssetSource,
    src: SvgSource,
    size: Size(DevicePixels),

    fn build(raw: *anyopaque) anyerror!?atlas.TileData {
        const self: *SvgTile = @ptrCast(@alignCast(raw));
        // The mask is copied into the atlas right away, so frame-arena memory is enough.
        const arena = window_mod.frame_arena();
        const bytes: []const u8 = switch (self.src) {
            .data => |d| d.bytes,
            .external => |p| assets.read_file(arena, p) catch return null,
            .asset => |p| self.source.load(p) orelse return null,
        };
        const renderer = try self.cache.svg_renderer();
        const parsed = renderer.parse_svg(arena, bytes) catch return null;
        defer parsed.deinit();
        const mask = renderer.render_alpha_mask(arena, parsed, .{ .size = self.size }) catch return null;
        return .{
            .size = .{ .width = @intCast(mask.width), .height = @intCast(mask.height) },
            .bytes = mask.pixels,
        };
    }
};

test "transformation without rotation or scale only moves the origin" {
    const m = (Transformation{ .translation = .{ .x = 4, .y = 0 } }).into_matrix(.{ .x = 10, .y = 10 }, 1.0);
    const p = m.apply(.{ .x = 10, .y = 10 });
    try std.testing.expectApproxEqAbs(@as(f32, 14), p.x, 1e-4);
    try std.testing.expectApproxEqAbs(@as(f32, 10), p.y, 1e-4);
}

test "svg key depends on source and size" {
    const a = svg_key(.{ .asset = "a.svg" }, .{ .width = 16, .height = 16 });
    const b = svg_key(.{ .asset = "a.svg" }, .{ .width = 32, .height = 16 });
    const c = svg_key(.{ .asset = "b.svg" }, .{ .width = 16, .height = 16 });
    try std.testing.expect(a != b);
    try std.testing.expect(a != c);
}

test "element protocol instantiates the svg hooks" {
    _ = &Svg.request_layout;
    _ = &Svg.prepaint;
    _ = &Svg.paint;
    _ = &Svg.path;
    _ = &Svg.external_path;
    _ = &Svg.data;
    _ = &Svg.with_transformation;
}

test {
    std.testing.refAllDecls(@This());
}
