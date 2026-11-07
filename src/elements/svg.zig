//! Port of GPUI `elements/svg.rs`: the `svg()` element. It rasterizes an SVG
//! to an alpha mask (cached in the sprite atlas) and paints it tinted with the
//! text color, like GPUI's `svg().path(...).text_color(...)`.

const std = @import("std");
const geometry = @import("../geometry.zig");
const style_mod = @import("../style.zig");
const scene = @import("../scene.zig");
const window_mod = @import("../window.zig");
const app_mod = @import("../app.zig");
const assets = @import("../assets.zig");
const asset_cache = @import("../asset_cache.zig");
const div = @import("div.zig");

const Window = window_mod.Window;
const App = app_mod.App;
const Style = style_mod.Style;
const Pixels = geometry.Pixels;
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

        if (e.data_) |bytes| {
            window.paint_svg(bounds, e.path_ orelse "", bytes, transformation, color, cx) catch |err| {
                std.log.err("svg: paint_svg failed: {s}", .{@errorName(err)});
            };
        } else if (e.external_path_) |p| {
            // Nothing is painted until the file has loaded (GPUI loads it with `use_asset`).
            const bytes = window.use_asset(SvgFile, p, cx) orelse return;
            if (bytes.len == 0) return;
            window.paint_svg(bounds, p, bytes, transformation, color, cx) catch |err| {
                std.log.err("svg: paint_svg failed: {s}", .{@errorName(err)});
            };
        } else if (e.path_) |p| {
            window.paint_svg(bounds, p, null, transformation, color, cx) catch |err| {
                std.log.err("svg: paint_svg failed: {s}", .{@errorName(err)});
            };
        }
    }
};

/// The bytes of an SVG file on disk, loaded once per path (GPUI `SvgAsset`). An empty result means
/// the file could not be read.
pub const SvgFile = struct {
    pub const Source = []const u8;
    pub const Output = []const u8;

    pub fn clone_source(source: Source, allocator: std.mem.Allocator) error{OutOfMemory}!Source {
        return allocator.dupe(u8, source);
    }

    pub fn free_source(source: Source, allocator: std.mem.Allocator) void {
        allocator.free(source);
    }

    pub fn load(source: Source, cx: *asset_cache.LoadContext) Output {
        return assets.read_file(cx.allocator, source) catch @as(Output, &.{});
    }

    pub fn dispose(out: Output, app: *App) void {
        if (out.len > 0) app.allocator.free(out);
    }
};

test "transformation without rotation or scale only moves the origin" {
    const m = (Transformation{ .translation = .{ .x = 4, .y = 0 } }).into_matrix(.{ .x = 10, .y = 10 }, 1.0);
    const p = m.apply(.{ .x = 10, .y = 10 });
    try std.testing.expectApproxEqAbs(@as(f32, 14), p.x, 1e-4);
    try std.testing.expectApproxEqAbs(@as(f32, 10), p.y, 1e-4);
}

test "rotate takes radians or a percentage of a turn" {
    const geometry_mod = @import("../geometry.zig");
    try std.testing.expectApproxEqAbs(std.math.pi / 2.0, Transformation.rotate(geometry_mod.percentage(0.25)).rotation, 1e-6);
    try std.testing.expectEqual(@as(f32, 0.5), Transformation.rotate(@as(f32, 0.5)).rotation);
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
