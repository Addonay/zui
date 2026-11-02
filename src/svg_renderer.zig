//! Port of GPUI `svg_renderer.rs`: parses SVG documents and rasterizes them
//! with the vendored nanosvg (`third_party/nanosvg`, Zlib licensed).
//!
//! `render_alpha_mask` produces A8 coverage for monochrome sprites, which the
//! element tints with the text color. Differences from GPUI's resvg backend:
//! no `<text>` layout (nanosvg has no font support) and no bundled fonts.

const std = @import("std");
const geometry = @import("geometry.zig");
const assets = @import("assets.zig");

const DevicePixels = geometry.DevicePixels;
const Size = geometry.Size;

/// Rasterize at this multiple of the target size; the element draws it at half size (GPUI `SMOOTH_SVG_SCALE_FACTOR`).
pub const SMOOTH_SVG_SCALE_FACTOR: f32 = 2.0;

/// Largest side length of a rasterized SVG, in pixels (GPUI `MAX_SIZE`).
const MAX_SIZE: f32 = 8192.0;

/// Mirrors nanosvg's `NSVGimage`; only the size is read from Zig.
const NsvgImage = extern struct {
    width: f32,
    height: f32,
    shapes: ?*anyopaque,
};

const NsvgRasterizer = opaque {};

extern fn nsvgParse(input: [*:0]u8, units: [*:0]const u8, dpi: f32) ?*NsvgImage;
extern fn nsvgDelete(image: *NsvgImage) void;
extern fn nsvgCreateRasterizer() ?*NsvgRasterizer;
extern fn nsvgDeleteRasterizer(r: *NsvgRasterizer) void;
extern fn nsvgRasterize(r: *NsvgRasterizer, image: *NsvgImage, tx: f32, ty: f32, scale: f32, dst: [*]u8, w: c_int, h: c_int, stride: c_int) void;

pub const RenderError = error{
    /// The document failed to parse or has no usable size.
    InvalidSvg,
    /// The requested size is zero, or the rasterized size is empty.
    EmptySize,
    OutOfMemory,
};

/// A parsed SVG document, rasterizable at any size. Release with `deinit`.
pub const ParsedSvg = struct {
    image: *NsvgImage,

    /// Intrinsic width in CSS pixels (96 dpi).
    pub fn width(self: ParsedSvg) f32 {
        return self.image.width;
    }

    /// Intrinsic height in CSS pixels (96 dpi).
    pub fn height(self: ParsedSvg) f32 {
        return self.image.height;
    }

    pub fn deinit(self: ParsedSvg) void {
        nsvgDelete(self.image);
    }
};

/// The size to rasterize an SVG at (GPUI `SvgSize`).
pub const SvgSize = union(enum) {
    /// Width in device pixels; the height follows the aspect ratio.
    size: Size(DevicePixels),
    /// Exact device size; the artwork is fitted inside and centered.
    exact_size: Size(DevicePixels),
    /// A multiple of the document's intrinsic size.
    scale_factor: f32,
};

/// Straight-alpha RGBA pixels, row-major.
pub const Pixmap = struct {
    width: u32,
    height: u32,
    pixels: []u8,
};

/// Monochrome A8 coverage, row-major, one byte per pixel.
pub const AlphaMask = struct {
    width: u32,
    height: u32,
    pixels: []u8,
};

/// Parses and rasterizes SVG documents (GPUI `SvgRenderer`). Owns a nanosvg rasterizer; release with `deinit`.
pub const SvgRenderer = struct {
    rasterizer: *NsvgRasterizer,

    pub fn init() error{OutOfMemory}!SvgRenderer {
        const r = nsvgCreateRasterizer() orelse return error.OutOfMemory;
        return .{ .rasterizer = r };
    }

    pub fn deinit(self: *SvgRenderer) void {
        nsvgDeleteRasterizer(self.rasterizer);
    }

    /// Parses an SVG document. `bytes` is copied, since nanosvg edits its input in place.
    pub fn parse_svg(self: *SvgRenderer, allocator: std.mem.Allocator, bytes: []const u8) RenderError!ParsedSvg {
        _ = self;
        const buf = allocator.allocSentinel(u8, bytes.len, 0) catch return error.OutOfMemory;
        defer allocator.free(buf);
        @memcpy(buf, bytes);
        const image = nsvgParse(buf.ptr, "px", 96.0) orelse return error.InvalidSvg;
        if (!(image.width > 0 and image.height > 0)) {
            nsvgDelete(image);
            return error.InvalidSvg;
        }
        return .{ .image = image };
    }

    /// Rasterizes a parsed document to straight-alpha RGBA (GPUI `render_parsed`, without the BGRA swap).
    pub fn render_pixmap(self: *SvgRenderer, allocator: std.mem.Allocator, svg: ParsedSvg, size: SvgSize) RenderError!Pixmap {
        const sw = svg.width();
        const sh = svg.height();
        var w: f32 = 0;
        var h: f32 = 0;
        var scale: f32 = 1;
        var tx: f32 = 0;
        var ty: f32 = 0;
        switch (size) {
            .size => |s| {
                if (s.width <= 0) return error.EmptySize;
                scale = @as(f32, @floatFromInt(s.width)) / sw;
                w = sw * scale;
                h = sh * scale;
            },
            .exact_size => |s| {
                if (s.width <= 0 or s.height <= 0) return error.EmptySize;
                const fw: f32 = @floatFromInt(s.width);
                const fh: f32 = @floatFromInt(s.height);
                scale = @min(fw / sw, fh / sh);
                w = fw;
                h = fh;
                tx = (fw - sw * scale) / 2.0;
                ty = (fh - sh * scale) / 2.0;
            },
            .scale_factor => |f| {
                if (!(f > 0)) return error.EmptySize;
                scale = f;
                w = sw * f;
                h = sh * f;
            },
        }

        // Keep the rasterized size within the GPU texture limit, scaling everything together.
        if (w > MAX_SIZE or h > MAX_SIZE) {
            const k = @min(MAX_SIZE / w, MAX_SIZE / h);
            w *= k;
            h *= k;
            scale *= k;
            tx *= k;
            ty *= k;
        }
        const wi: u32 = @max(1, @as(u32, @intFromFloat(@floor(w))));
        const hi: u32 = @max(1, @as(u32, @intFromFloat(@floor(h))));

        const pixels = allocator.alloc(u8, @as(usize, wi) * hi * 4) catch return error.OutOfMemory;
        errdefer allocator.free(pixels);
        // nanosvg composites onto the destination, so it must start transparent.
        @memset(pixels, 0);
        nsvgRasterize(self.rasterizer, svg.image, tx, ty, scale, pixels.ptr, @intCast(wi), @intCast(hi), @intCast(wi * 4));
        return .{ .width = wi, .height = hi, .pixels = pixels };
    }

    /// Rasterizes to A8 coverage for a monochrome sprite (GPUI `render_alpha_mask`).
    pub fn render_alpha_mask(self: *SvgRenderer, allocator: std.mem.Allocator, svg: ParsedSvg, size: SvgSize) RenderError!AlphaMask {
        const rgba = try self.render_pixmap(allocator, svg, size);
        defer allocator.free(rgba.pixels);
        const n = @as(usize, rgba.width) * rgba.height;
        const alpha = allocator.alloc(u8, n) catch return error.OutOfMemory;
        for (alpha, 0..) |*a, i| a.* = rgba.pixels[i * 4 + 3];
        return .{ .width = rgba.width, .height = rgba.height, .pixels = alpha };
    }

    /// Parses and rasterizes `bytes` into a `RenderImage` at `scale_factor`, for `img()` of an SVG file
    /// (GPUI `render_single_frame`). The result is rasterized at 2x and records that in `scale_factor`.
    pub fn render_single_frame(self: *SvgRenderer, allocator: std.mem.Allocator, bytes: []const u8, scale_factor: f32) RenderError!*assets.RenderImage {
        const svg = try self.parse_svg(allocator, bytes);
        defer svg.deinit();
        const rgba = try self.render_pixmap(allocator, svg, .{ .scale_factor = scale_factor * SMOOTH_SVG_SCALE_FACTOR });
        const frames = allocator.alloc(assets.Frame, 1) catch {
            allocator.free(rgba.pixels);
            return error.OutOfMemory;
        };
        frames[0] = assets.frame_from_rgba_owned(rgba.pixels, rgba.width, rgba.height, 0);
        const image = assets.RenderImage.new(allocator, frames) catch {
            allocator.free(rgba.pixels);
            allocator.free(frames);
            return error.OutOfMemory;
        };
        image.scale_factor = SMOOTH_SVG_SCALE_FACTOR;
        return image;
    }
};

// -- tests -------------------------------------------------------------------

const testing = std.testing;

test "rect svg rasterizes with full coverage" {
    var r = try SvgRenderer.init();
    defer r.deinit();
    const svg = try r.parse_svg(testing.allocator, "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"10\" height=\"10\"><rect width=\"10\" height=\"10\" fill=\"#000\"/></svg>");
    defer svg.deinit();

    const mask = try r.render_alpha_mask(testing.allocator, svg, .{ .size = .{ .width = 20, .height = 20 } });
    defer testing.allocator.free(mask.pixels);
    try testing.expectEqual(@as(u32, 20), mask.width);
    try testing.expectEqual(@as(u32, 20), mask.height);

    var covered: usize = 0;
    for (mask.pixels) |a| {
        if (a > 0) covered += 1;
    }
    try testing.expectEqual(@as(usize, 20 * 20), covered);
    try testing.expectEqual(@as(u8, 255), mask.pixels[10 * 20 + 10]);
}

test "exact size fits and centers the artwork" {
    var r = try SvgRenderer.init();
    defer r.deinit();
    // A 10x10 square drawn into a 20x10 box: coverage only in the middle 10 columns.
    const svg = try r.parse_svg(testing.allocator, "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"10\" height=\"10\"><rect width=\"10\" height=\"10\"/></svg>");
    defer svg.deinit();

    const mask = try r.render_alpha_mask(testing.allocator, svg, .{ .exact_size = .{ .width = 20, .height = 10 } });
    defer testing.allocator.free(mask.pixels);
    try testing.expectEqual(@as(u8, 0), mask.pixels[4]);
    try testing.expectEqual(@as(u8, 255), mask.pixels[5]);
    try testing.expectEqual(@as(u8, 255), mask.pixels[14]);
    try testing.expectEqual(@as(u8, 0), mask.pixels[15]);
}

test "stroke-only icon has nonzero coverage" {
    var r = try SvgRenderer.init();
    defer r.deinit();
    const svg = try r.parse_svg(testing.allocator, "<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 24 24\" fill=\"none\" stroke=\"currentColor\" stroke-width=\"3\"><path d=\"M4 12 L20 12\"/></svg>");
    defer svg.deinit();

    const mask = try r.render_alpha_mask(testing.allocator, svg, .{ .size = .{ .width = 48, .height = 48 } });
    defer testing.allocator.free(mask.pixels);
    var covered: usize = 0;
    for (mask.pixels) |a| {
        if (a > 0) covered += 1;
    }
    try testing.expect(covered > 50);
}

test "garbage input is rejected" {
    var r = try SvgRenderer.init();
    defer r.deinit();
    try testing.expectError(error.InvalidSvg, r.parse_svg(testing.allocator, "not an svg document"));
}

test "render_single_frame produces a 2x BGRA frame" {
    var r = try SvgRenderer.init();
    defer r.deinit();
    const img = try r.render_single_frame(testing.allocator, "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"10\" height=\"10\"><rect width=\"10\" height=\"10\" fill=\"#ff0000\"/></svg>", 1.0);
    defer img.deinit();
    try testing.expectEqual(@as(f32, 2.0), img.scale_factor);
    try testing.expectEqual(@as(f32, 10.0), img.render_size(0).width);
    // Opaque red in BGRA order: blue byte 0, red byte 255.
    const px = img.as_bytes(0).?;
    const w: usize = @intCast(img.size(0).width);
    const h: usize = @intCast(img.size(0).height);
    const mid = ((h / 2) * w + w / 2) * 4;
    try testing.expectEqualSlices(u8, &.{ 0, 0, 255, 255 }, px[mid .. mid + 4]);
}
