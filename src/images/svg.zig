//! SVG parse + rasterize via vendored nanosvg (Zlib licensed).
//!
//! GPUI-parity notes: `svg()` elements tint icons through `currentColor`
//! (lucide/feather style: `stroke="currentColor"`). Nanosvg does not resolve
//! `currentColor`, so when a tint is given we substitute the literal with
//! the tint hex before parsing — same observable semantics as GPUI passing
//! the text color into its svg renderer.
//!
//! Cold path only: parse mutates a copy and both parse + rasterize malloc
//! internally. Frames reference cache-pool bytes, never this.

const std = @import("std");
const c = @import("c.zig");
const color_mod = @import("../core/color.zig");
const limits = @import("../core/limits.zig");
const zlog = @import("../core/log.zig");
const raster = @import("raster.zig");

pub const SvgError = error{
    NotSvg,
    TooLarge,
    ParseFailed,
    NoIntrinsicSize,
    RasterFailed,
    OutOfMemory,
};

/// Intrinsic pixel size from width/height attrs (or the viewBox fallback
/// nanosvg applies). Errors when the document has no usable size.
pub fn intrinsicSize(svg_bytes: []const u8) SvgError!struct { w: f32, h: f32 } {
    const doc = try parseCopy(svg_bytes);
    defer c.api.deleteSvg(doc);
    if (doc.width <= 0 or doc.height <= 0) return SvgError.NoIntrinsicSize;
    return .{ .w = doc.width, .h = doc.height };
}

/// Rasterize to allocator-owned RGBA8 of exactly `target_w` x `target_h`,
/// contain-fitting the artwork (letterboxed on transparent) like GPUI's
/// default object-fit. `tint` substitutes `currentColor` when present.
pub fn render(
    allocator: std.mem.Allocator,
    svg_bytes: []const u8,
    target_w: u32,
    target_h: u32,
    tint: ?color_mod.Color,
) SvgError!raster.Decoded {
    if (target_w == 0 or target_h == 0) return SvgError.RasterFailed;
    if (@as(u64, target_w) * @as(u64, target_h) > limits.MAX_IMAGE_PIXELS) return SvgError.TooLarge;
    const prepared = try maybeTint(allocator, svg_bytes, tint);
    defer if (prepared.owned) allocator.free(prepared.bytes);
    const doc = try parseCopy(prepared.bytes);
    defer c.api.deleteSvg(doc);

    const iw = if (doc.width > 0) doc.width else @as(f32, @floatFromInt(target_w));
    const ih = if (doc.height > 0) doc.height else @as(f32, @floatFromInt(target_h));
    const scale = @min(
        @as(f32, @floatFromInt(target_w)) / iw,
        @as(f32, @floatFromInt(target_h)) / ih,
    );
    // Center the fitted artwork in the target box.
    const tx = (@as(f32, @floatFromInt(target_w)) - iw * scale) / 2.0;
    const ty = (@as(f32, @floatFromInt(target_h)) - ih * scale) / 2.0;

    const n = @as(usize, target_w) * target_h * 4;
    const out = allocator.alloc(u8, n) catch return SvgError.OutOfMemory;
    errdefer allocator.free(out);
    @memset(out, 0); // rasterizer composites onto dst; zero = transparent.

    const rast = c.api.createRasterizer() orelse return SvgError.RasterFailed;
    defer c.api.deleteRasterizer(rast);
    c.api.rasterizeSvg(
        rast,
        doc,
        tx,
        ty,
        scale,
        out.ptr,
        @intCast(target_w),
        @intCast(target_h),
        @intCast(target_w * 4),
    );
    return .{ .pixels = out, .w = target_w, .h = target_h };
}

/// Parse a NUL-terminated mutable copy (nsvgParse writes into its input).
fn parseCopy(svg_bytes: []const u8) SvgError!*c.NsvgImage {
    if (raster.sniff(svg_bytes) != .svg) return SvgError.NotSvg;
    if (svg_bytes.len > limits.MAX_SVG_BYTES) return SvgError.TooLarge;
    const gpa = std.heap.c_allocator;
    const buf = gpa.alloc(u8, svg_bytes.len + 1) catch return SvgError.OutOfMemory;
    defer gpa.free(buf);
    @memcpy(buf[0..svg_bytes.len], svg_bytes);
    buf[svg_bytes.len] = 0;
    const doc = c.api.parseSvg(@ptrCast(buf.ptr), "px", 96.0) orelse {
        zlog.log("images", "nsvgParse failed ({d} bytes)", .{svg_bytes.len});
        return SvgError.ParseFailed;
    };
    return doc;
}

const Prepared = struct {
    bytes: []const u8,
    owned: bool,
};

/// Substitute `currentColor` with the tint hex. Returns borrowed input when
/// no tint is set or no occurrence exists.
fn maybeTint(allocator: std.mem.Allocator, svg_bytes: []const u8, tint: ?color_mod.Color) SvgError!Prepared {
    const t = tint orelse return .{ .bytes = svg_bytes, .owned = false };
    if (std.mem.indexOf(u8, svg_bytes, "currentColor") == null) return .{ .bytes = svg_bytes, .owned = false };
    var hex: [7]u8 = undefined;
    const r: u32 = @intFromFloat(std.math.clamp(t.r * 255.0, 0.0, 255.0));
    const g: u32 = @intFromFloat(std.math.clamp(t.g * 255.0, 0.0, 255.0));
    const b: u32 = @intFromFloat(std.math.clamp(t.b * 255.0, 0.0, 255.0));
    _ = std.fmt.bufPrint(&hex, "#{x:0>2}{x:0>2}{x:0>2}", .{ r, g, b }) catch return SvgError.OutOfMemory;
    // "currentColor" (12) -> "#rrggbb" (7): output shrinks, single pass.
    var out = allocator.alloc(u8, svg_bytes.len) catch return SvgError.OutOfMemory;
    errdefer allocator.free(out);
    var si: usize = 0;
    var di: usize = 0;
    while (si < svg_bytes.len) {
        if (si + 12 <= svg_bytes.len and std.mem.eql(u8, svg_bytes[si..][0..12], "currentColor")) {
            @memcpy(out[di..][0..7], &hex);
            di += 7;
            si += 12;
        } else {
            out[di] = svg_bytes[si];
            di += 1;
            si += 1;
        }
    }
    if (allocator.resize(out, di)) {
        return .{ .bytes = out[0..di], .owned = true };
    }
    // Allocator can't resize in place: copy to an exact buffer so the
    // caller can free with the right length.
    const exact = allocator.alloc(u8, di) catch {
        allocator.free(out);
        return SvgError.OutOfMemory;
    };
    @memcpy(exact, out[0..di]);
    allocator.free(out);
    return .{ .bytes = exact, .owned = true };
}

test "tint substitution replaces currentColor" {
    const t = std.testing.allocator;
    const src = "<svg><path stroke=\"currentColor\" fill=\"none\"/></svg>";
    const tint = color_mod.Color.rgb(1, 0, 0);
    const p = try maybeTint(t, src, tint);
    defer if (p.owned) t.free(p.bytes);
    try std.testing.expect(p.owned);
    try std.testing.expect(std.mem.indexOf(u8, p.bytes, "currentColor") == null);
    try std.testing.expect(std.mem.indexOf(u8, p.bytes, "#ff0000") != null);

    // No tint or no occurrence borrows.
    const q = try maybeTint(t, src, null);
    try std.testing.expect(!q.owned);
    const r = try maybeTint(t, "<svg/>", tint);
    try std.testing.expect(!r.owned);
}

test "intrinsic size reads width/height, rejects non-svg" {
    try std.testing.expectError(SvgError.NotSvg, intrinsicSize("\x89PNG...."));
    const s = try intrinsicSize("<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"24\" height=\"48\"></svg>");
    try std.testing.expectEqual(@as(f32, 24), s.w);
    try std.testing.expectEqual(@as(f32, 48), s.h);
}

test "viewBox-only icon reports usable size" {
    const icon = "<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 24 24\" fill=\"none\" stroke=\"currentColor\" stroke-width=\"2\"><path d=\"M20 6 9 17l-5-5\"/></svg>";
    const s = try intrinsicSize(icon);
    try std.testing.expectEqual(@as(f32, 24), s.w);
    try std.testing.expectEqual(@as(f32, 24), s.h);
}

test "stroke icon rasterizes non-empty pixels with tint" {
    const t = std.testing.allocator;
    const icon = "<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 24 24\" fill=\"none\" stroke=\"currentColor\" stroke-width=\"3\" stroke-linecap=\"round\" stroke-linejoin=\"round\"><path d=\"M20 6 9 17l-5-5\"/></svg>";
    const img = try render(t, icon, 24, 24, color_mod.Color.rgb(1, 1, 1));
    defer t.free(img.pixels);
    try std.testing.expectEqual(@as(u32, 24), img.w);
    var nonzero: usize = 0;
    var reddish: usize = 0;
    var i: usize = 0;
    while (i < img.pixels.len) : (i += 4) {
        if (img.pixels[i + 3] > 8) {
            nonzero += 1;
            // Tinted white stroke: r/g/b all high where opaque.
            if (img.pixels[i] > 200 and img.pixels[i + 1] > 200 and img.pixels[i + 2] > 200) reddish += 1;
        }
    }
    try std.testing.expect(nonzero > 20);
    try std.testing.expectEqual(nonzero, reddish);
}

test "gradient logo rasterizes colorful pixels" {
    const t = std.testing.allocator;
    const logo =
        \\<svg xmlns="http://www.w3.org/2000/svg" width="32" height="32" viewBox="0 0 32 32">
        \\<defs><linearGradient id="g" x1="0" y1="0" x2="1" y2="1">
        \\<stop offset="0" stop-color="#7c5cff"/><stop offset="1" stop-color="#46d5e8"/>
        \\</linearGradient></defs>
        \\<rect x="2" y="2" width="28" height="28" rx="7" fill="url(#g)"/>
        \\</svg>
    ;
    const img = try render(t, logo, 32, 32, null);
    defer t.free(img.pixels);
    var solid: usize = 0;
    var colorful: usize = 0;
    var i: usize = 0;
    while (i < img.pixels.len) : (i += 4) {
        if (img.pixels[i + 3] > 128) {
            solid += 1;
            const r = img.pixels[i];
            const b = img.pixels[i + 2];
            if ((r > 60 and b > 60) and (r < 250 or b < 250)) colorful += 1;
        }
    }
    // Rounded rect covers most of the box; gradient spans purple->teal.
    try std.testing.expect(solid > 500);
    try std.testing.expect(colorful > 200);
}
