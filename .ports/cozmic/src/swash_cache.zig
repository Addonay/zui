//! Port of cosmic-text `swash.rs` (304 lines).
//!
//! `CacheKey` / `SubpixelBin` / `CacheKeyFlags` are unified with
//! `glyph_cache.zig` (same `CacheKey` Rust uses in `swash.rs:13` via
//! `crate::{CacheKey, CacheKeyFlags}`). `Color` / image types stay local
//! until the font modules unify (see TODO below).
//! TODO(swash): unify `Color` with the real attrs/cache modules.
//!
//! Verbatim behaviour preserved:
//! - Source order `ColorOutline(0) / ColorBitmap(BestFit) / Outline`
//!   (swash.rs:57-65) is recorded as `SOURCE_ORDER` and honoured by the
//!   `RasterAdapter` contract.
//! - `FAKE_ITALIC` skews by 14 degrees about X (swash.rs:70-77, 117-122).
//! - `PIXEL_FONT` rounds the fractional offset (swash.rs:48-55).
//! - `wght` is clamped to the variation range before use (swash.rs:38-43).
//! - `with_pixels` blends `Mask` as `(alpha << 24) | (base & 0xFF_FF_FF)` and
//!   expands `Color` as RGBA; `SubpixelMask` is explicitly skipped and
//!   reported (swash.rs:203-246).
//! - Both caches use negative caching: misses (`null`) are stored so the
//!   rasterizer is not re-invoked (via `HashMap.entry` / `or_insert_with` in
//!   swash.rs:169-183).
//!
//! WIRING POINT (`hb`/`swash` backend): `RasterAdapter` is the narrow adapter
//! interface standing in for `swash::scale::ScaleContext` + `FontRef`. The
//! bundled `FallbackRaster` is a pure-Zig stand-in that synthesizes a solid
//! mask. The real scaler is `font_raster.Raster` (FreeType): attach one with
//! `SwashCache.setRaster` and `getImage`/`getImageUncached` serve real
//! coverage masks; `adapter` remains the stand-in for callers/tests without a
//! raster. When a raster is set it is authoritative: an unknown font id or a
//! pixel layout this seam cannot represent is a (negatively cached) miss, not
//! a fallback to synthetic pixels.

const std = @import("std");
const glyph_cache = @import("glyph_cache.zig");
const font_raster = @import("font_raster.zig");
const raster_ft = @import("raster_ft.zig");

/// Unified cache-key flags (re-export of `glyph_cache.CacheKeyFlags`).
/// Verbatim bits from `glyph_cache.rs:7-13`: FAKE_ITALIC=1,
/// DISABLE_HINTING=2, PIXEL_FONT=4.
pub const CacheKeyFlags = glyph_cache.CacheKeyFlags;
/// Unified subpixel bin (re-export of `glyph_cache.SubpixelBin`).
pub const SubpixelBin = glyph_cache.SubpixelBin;
pub const FLAG_FAKE_ITALIC: CacheKeyFlags = CacheKeyFlags.FAKE_ITALIC;
pub const FLAG_DISABLE_HINTING: CacheKeyFlags = CacheKeyFlags.DISABLE_HINTING;
pub const FLAG_PIXEL_FONT: CacheKeyFlags = CacheKeyFlags.PIXEL_FONT;

/// RGBA color packed as `u32` (matches cosmic-text `Color` layout `0xRRGGBBAA`).
/// Local alias only; unify with `attrs.zig` later.
pub const Color = u32;

/// Pack RGBA bytes, matching `Color::rgba` in cosmic-text.
pub fn rgba(r: u8, g: u8, b: u8, a: u8) Color {
    return (@as(u32, r) << 24) | (@as(u32, g) << 16) | (@as(u32, b) << 8) | @as(u32, a);
}

/// Raster cache key (canonical owner: `glyph_cache.CacheKey`).
pub const CacheKey = glyph_cache.CacheKey;

const KeyContext = struct {
    pub fn hash(_: KeyContext, k: CacheKey) u64 {
        var h = std.hash.Wyhash.init(0);
        h.update(std.mem.asBytes(&k.font_id));
        h.update(std.mem.asBytes(&k.glyph_id));
        h.update(std.mem.asBytes(&k.font_size_bits));
        const xb: u8 = @backingInt(k.x_bin);
        const yb: u8 = @backingInt(k.y_bin);
        h.update(std.mem.asBytes(&xb));
        h.update(std.mem.asBytes(&yb));
        h.update(std.mem.asBytes(&k.font_weight));
        h.update(std.mem.asBytes(&k.flags.bits));
        return h.final();
    }
    pub fn eql(_: KeyContext, a: CacheKey, b: CacheKey) bool {
        return CacheKey.eql(a, b);
    }
};

/// Raster source preference, mirroring the `Render::new` source order in
/// swash.rs:57-65 (color outline with palette 0, color bitmap best-fit,
/// standard scalable outline).
pub const RasterSource = enum {
    color_outline,
    color_bitmap,
    outline,
};

/// Verbatim source order from `swash_image` (swash.rs:57-65).
pub const SOURCE_ORDER = [_]RasterSource{ .color_outline, .color_bitmap, .outline };

/// Skew applied for `FAKE_ITALIC`: `Transform::skew(14deg, 0deg)`
/// (swash.rs:70-77). Horizontal shift per unit of vertical distance.
pub const FAKE_ITALIC_DEGREES: f32 = 14.0;
pub const FAKE_ITALIC_SKEW: f32 = 0.2493280028; // tan(14deg)

/// Horizontal skew offset for a point at height `y` under fake italic.
pub fn fakeItalicSkewDx(y: f32) f32 {
    return y * FAKE_ITALIC_SKEW;
}

/// Clamp a `wght` value into the font's variation range, mirroring
/// `f32::from(weight).clamp(min, max)` in swash.rs:38-43.
pub fn clampWght(value: f32, min: f32, max: f32) f32 {
    return std.math.clamp(value, min, max);
}

/// Fractional raster offset for a cache key. With `PIXEL_FONT` the binned
/// offset is rounded (swash.rs:48-55: `x_bin.as_float().round()`); otherwise
/// the binned subpixel offset is kept.
pub fn rasterOffset(key: CacheKey) struct { x: f32, y: f32 } {
    if (key.flags.contains(FLAG_PIXEL_FONT)) {
        return .{ .x = @round(key.x_bin.asFloat()), .y = @round(key.y_bin.asFloat()) };
    }
    return .{ .x = key.x_bin.asFloat(), .y = key.y_bin.asFloat() };
}

/// Image content kind, mirroring `swash::scale::image::Content`.
pub const ImageContent = enum {
    mask,
    color,
    subpixel_mask,
};

pub const Placement = struct {
    left: i32,
    top: i32,
    width: u32,
    height: u32,
};

/// Owned raster image. `data` holds `w*h` bytes for `mask` and `w*h*4` RGBA
/// bytes for `color`.
pub const SwashImageOwned = struct {
    placement: Placement,
    content: ImageContent,
    data: []u8,

    pub fn free(self: *SwashImageOwned, allocator: std.mem.Allocator) void {
        allocator.free(self.data);
        self.data = &.{};
    }
};

/// Borrowed view of a cached image (valid until the cache is mutated).
pub const SwashImageView = struct {
    placement: Placement,
    content: ImageContent,
    data: []const u8,
};

pub const Point = struct {
    x: f32,
    y: f32,
};

/// Outline path commands, mirroring `swash::zeno::Command`.
pub const OutlineCommand = union(enum) {
    move_to: Point,
    line_to: Point,
    quad_to: struct {
        control: Point,
        to: Point,
    },
    curve_to: struct {
        c1: Point,
        c2: Point,
        to: Point,
    },
    close: void,
};

/// Narrow adapter interface standing in for `ScaleContext + FontRef`
/// (see module docs WIRING POINT). Implementations must honour `SOURCE_ORDER`
/// and apply `FAKE_ITALIC` / `PIXEL_FONT` / `wght` clamping as documented
/// above. Returning `null` records a negative-cache entry.
pub const RasterAdapter = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        render_image: *const fn (
            ptr: *anyopaque,
            allocator: std.mem.Allocator,
            key: CacheKey,
        ) anyerror!?SwashImageOwned,
        render_outline: *const fn (
            ptr: *anyopaque,
            allocator: std.mem.Allocator,
            key: CacheKey,
        ) anyerror!?[]OutlineCommand,
    };

    pub fn renderImage(
        self: RasterAdapter,
        allocator: std.mem.Allocator,
        key: CacheKey,
    ) anyerror!?SwashImageOwned {
        return self.vtable.render_image(self.ptr, allocator, key);
    }

    pub fn renderOutline(
        self: RasterAdapter,
        allocator: std.mem.Allocator,
        key: CacheKey,
    ) anyerror!?[]OutlineCommand {
        return self.vtable.render_outline(self.ptr, allocator, key);
    }
};

/// Pure-Zig stand-in rasterizer: synthesizes a solid `Mask` covering
/// `ceil(size)` square pixels. Used when no backend is wired up and as a test
/// double. NOT a font renderer — replace via `RasterAdapter`.
pub const FallbackRaster = struct {
    images_rendered: usize = 0,
    outlines_rendered: usize = 0,
    /// When true, `render_image` returns `null` (missing glyph path).
    miss_image: bool = false,

    pub fn adapter(self: *FallbackRaster) RasterAdapter {
        return .{ .ptr = self, .vtable = &.{
            .render_image = renderImage,
            .render_outline = renderOutline,
        } };
    }

    fn renderImage(ptr: *anyopaque, allocator: std.mem.Allocator, key: CacheKey) !?SwashImageOwned {
        const self: *FallbackRaster = @ptrCast(@alignCast(ptr));
        self.images_rendered += 1;
        if (self.miss_image) return null;
        const size: u32 = @intFromFloat(@max(1.0, key.fontSize()));
        const data = try allocator.alloc(u8, size * size);
        @memset(data, 0xFF);
        return .{
            .placement = .{ .left = 0, .top = @intCast(size), .width = size, .height = size },
            .content = .mask,
            .data = data,
        };
    }

    fn renderOutline(ptr: *anyopaque, allocator: std.mem.Allocator, key: CacheKey) !?[]OutlineCommand {
        const self: *FallbackRaster = @ptrCast(@alignCast(ptr));
        self.outlines_rendered += 1;
        _ = key;
        const cmds = try allocator.alloc(OutlineCommand, 1);
        cmds[0] = .close;
        return cmds;
    }
};

/// Cache for rasterizing glyphs. Ports `SwashCache` (swash.rs:131-247) with
/// negative caching on both maps.
pub const SwashCache = struct {
    allocator: std.mem.Allocator,
    adapter: ?RasterAdapter,
    /// Optional real FreeType raster (`font_raster.Raster`). When set it takes
    /// precedence over `adapter`; see the module docs. Borrowed: the raster
    /// must outlive the cache.
    raster: ?*font_raster.Raster = null,
    image_cache: std.HashMap(CacheKey, ?SwashImageOwned, KeyContext, 80),
    outline_cache: std.HashMap(CacheKey, ?[]OutlineCommand, KeyContext, 80),

    pub fn init(allocator: std.mem.Allocator, adapter: ?RasterAdapter) SwashCache {
        return .{
            .allocator = allocator,
            .adapter = adapter,
            .image_cache = .init(allocator),
            .outline_cache = .init(allocator),
        };
    }

    pub fn deinit(self: *SwashCache) void {
        self.clearImages();
        self.image_cache.deinit();
        var oit = self.outline_cache.iterator();
        while (oit.next()) |entry| {
            if (entry.value_ptr.*) |cmds| self.allocator.free(cmds);
        }
        self.outline_cache.deinit();
    }

    /// Attach (or detach with `null`) the real FreeType raster.
    ///
    /// Cached images are dropped: `CacheKey` does not record the raster source,
    /// so keeping them would serve stand-in pixels after a real backend is
    /// attached (or vice versa). Outline caching is unaffected.
    pub fn setRaster(self: *SwashCache, raster: ?*font_raster.Raster) void {
        if (self.raster == raster) return;
        self.raster = raster;
        self.clearImages();
    }

    fn clearImages(self: *SwashCache) void {
        var it = self.image_cache.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.*) |*img| img.free(self.allocator);
        }
        self.image_cache.clearRetainingCapacity();
    }

    /// Render one image from whichever source is attached: FreeType raster
    /// first, then the stand-in adapter. `null` is a missing glyph / layout
    /// this seam cannot represent and is cached negatively by `getImage`.
    fn renderImage(self: *SwashCache, key: CacheKey) !?SwashImageOwned {
        if (self.raster) |raster| {
            const rendered = try raster.rasterize(
                key.font_id,
                key.glyph_id,
                key.fontSize(),
                key.flags,
            );
            const r = rendered orelse return null;
            return imageFromRendered(self.allocator, r);
        }
        const adapter = self.adapter orelse return null;
        return adapter.renderImage(self.allocator, key);
    }

    /// Create an image without caching results (swash.rs:155-161).
    /// Returns an owned image; call `free` on it. `null` means missing glyph.
    pub fn getImageUncached(self: *SwashCache, key: CacheKey) !?SwashImageOwned {
        return self.renderImage(key);
    }

    /// Create an image, caching results including misses (swash.rs:164-172).
    pub fn getImage(self: *SwashCache, key: CacheKey) !?SwashImageView {
        const entry = try self.image_cache.getOrPut(key);
        if (!entry.found_existing) {
            var owned = try self.renderImage(key);
            errdefer if (owned) |*img| img.free(self.allocator);
            entry.value_ptr.* = owned;
        }
        const stored = entry.value_ptr.*;
        if (stored) |*img| {
            return SwashImageView{
                .placement = img.placement,
                .content = img.content,
                .data = img.data,
            };
        }
        return null;
    }

    /// Create outline commands, caching results including misses
    /// (swash.rs:175-184).
    pub fn getOutline(self: *SwashCache, key: CacheKey) !?[]const OutlineCommand {
        const entry = try self.outline_cache.getOrPut(key);
        if (!entry.found_existing) {
            var owned: ?[]OutlineCommand = null;
            if (self.adapter) |adapter| owned = try adapter.renderOutline(self.allocator, key);
            errdefer if (owned) |cmds| self.allocator.free(cmds);
            entry.value_ptr.* = owned;
        }
        if (entry.value_ptr.*) |cmds| return cmds;
        return null;
    }

    /// Create outline commands without caching (swash.rs:187-193).
    /// Returns an owned slice; the caller frees it.
    pub fn getOutlineUncached(self: *SwashCache, key: CacheKey) !?[]OutlineCommand {
        const adapter = self.adapter orelse return null;
        return adapter.renderOutline(self.allocator, key);
    }

    /// Pixel visitor callback.
    pub const PixelFn = *const fn (ctx: *anyopaque, x: i32, y: i32, color: Color) void;

    /// Enumerate pixels in an image (swash.rs:196-246). Returns the number of
    /// pixels emitted. `subpixel_mask` content is explicitly skipped and
    /// reported as 0 (swash.rs:241-243 logs `TODO: SubpixelMask`).
    pub fn withPixels(
        self: *SwashCache,
        key: CacheKey,
        base: Color,
        ctx: *anyopaque,
        visit: PixelFn,
    ) !usize {
        const view = try self.getImage(key) orelse return 0;
        // Origin: (left, -top), matching swash.rs:204-205.
        const ox = view.placement.left;
        const oy = -view.placement.top;
        const w: i32 = @intCast(view.placement.width);
        const h: i32 = @intCast(view.placement.height);
        switch (view.content) {
            .mask => {
                // swash.rs:208-221: `Color((alpha << 24) | base & 0xFF_FF_FF)`.
                var i: usize = 0;
                var count: usize = 0;
                var off_y: i32 = 0;
                while (off_y < h) : (off_y += 1) {
                    var off_x: i32 = 0;
                    while (off_x < w) : (off_x += 1) {
                        if (i >= view.data.len) return count;
                        const alpha = view.data[i];
                        visit(ctx, ox + off_x, oy + off_y, (@as(u32, alpha) << 24) | (base & 0x00FF_FFFF));
                        i += 1;
                        count += 1;
                    }
                }
                return count;
            },
            .color => {
                // swash.rs:222-240: RGBA bytes straight through.
                var i: usize = 0;
                var count: usize = 0;
                var off_y: i32 = 0;
                while (off_y < h) : (off_y += 1) {
                    var off_x: i32 = 0;
                    while (off_x < w) : (off_x += 1) {
                        if (i + 4 > view.data.len) return count;
                        visit(ctx, ox + off_x, oy + off_y, rgba(
                            view.data[i],
                            view.data[i + 1],
                            view.data[i + 2],
                            view.data[i + 3],
                        ));
                        i += 4;
                        count += 1;
                    }
                }
                return count;
            },
            .subpixel_mask => return 0,
        }
    }
};

/// Convert a FreeType glyph bitmap into the cache's owned image shape.
///
/// `Gray` (8-bit coverage) and `Mono` (1 bit MSB-first) become per-pixel
/// alpha masks, copied row by row so `Rendered.rowSlice` can undo FreeType's
/// row padding and negative pitch. Other pixel modes (LCD/LCD_V/BGRA) cannot
/// be represented by the `mask`/`color` shapes this port keeps and are never
/// produced by `rasterize`'s normal (non-color, non-subpixel) render mode;
/// they return `null` and are cached as misses rather than emitting garbage.
fn imageFromRendered(
    allocator: std.mem.Allocator,
    rendered: raster_ft.Rendered,
) !?SwashImageOwned {
    switch (rendered.pixel_mode) {
        raster_ft.FT_PIXEL_MODE_GRAY, raster_ft.FT_PIXEL_MODE_MONO => {},
        else => return null,
    }
    const data = try maskFromRendered(allocator, rendered);
    return .{
        .placement = .{
            .left = rendered.left,
            .top = rendered.top,
            .width = rendered.width,
            .height = rendered.height,
        },
        .content = .mask,
        .data = data,
    };
}

/// Expand a Gray/Mono `Rendered` into a top-down `width * height` alpha mask.
fn maskFromRendered(allocator: std.mem.Allocator, rendered: raster_ft.Rendered) ![]u8 {
    if (rendered.pixel_mode != raster_ft.FT_PIXEL_MODE_GRAY and
        rendered.pixel_mode != raster_ft.FT_PIXEL_MODE_MONO)
    {
        return error.UnsupportedPixelMode;
    }
    const width: usize = rendered.width;
    const height: usize = rendered.height;
    const len = std.math.mul(usize, width, height) catch return error.OutOfMemory;
    const data = try allocator.alloc(u8, len);
    errdefer allocator.free(data);

    var y: usize = 0;
    while (y < height) : (y += 1) {
        const row = rendered.rowSlice(@intCast(y));
        const dst = data[y * width ..][0..width];
        switch (rendered.pixel_mode) {
            raster_ft.FT_PIXEL_MODE_GRAY => {
                // Gray rows are `width` bytes; a short row (empty bitmap)
                // leaves the remaining pixels transparent.
                const n = @min(dst.len, row.len);
                @memcpy(dst[0..n], row[0..n]);
                @memset(dst[n..], 0);
            },
            raster_ft.FT_PIXEL_MODE_MONO => {
                for (dst, 0..) |*px, x| {
                    const byte_index = x >> 3;
                    if (byte_index >= row.len) {
                        px.* = 0;
                        continue;
                    }
                    const bit = (row[byte_index] >> @intCast(7 - (x & 7))) & 1;
                    px.* = if (bit != 0) 0xFF else 0;
                }
            },
            else => unreachable, // rejected above and by imageFromRendered
        }
    }
    return data;
}

const PixelCollector = struct {
    xs: std.ArrayList(i32) = .empty,
    ys: std.ArrayList(i32) = .empty,
    colors: std.ArrayList(Color) = .empty,
    alloc: std.mem.Allocator,

    fn visit(ctx: *anyopaque, x: i32, y: i32, color: Color) void {
        const self: *PixelCollector = @ptrCast(@alignCast(ctx));
        // Test-only path: allocator is the test allocator; ignore OOM here
        // would hide failures, so fall back to storing nothing on error.
        self.xs.append(self.alloc, x) catch return;
        self.ys.append(self.alloc, y) catch return;
        self.colors.append(self.alloc, color) catch return;
    }
};

fn testKey() CacheKey {
    return .{
        .font_id = 1,
        .glyph_id = 65,
        .font_size_bits = @bitCast(@as(f32, 16.0)),
        .x_bin = .one, // asFloat 0.25 (was x_offset 0.25 pre-binning)
        .y_bin = .two, // asFloat 0.5 (was y_offset 0.5 pre-binning)
        .font_weight = 400,
        .flags = .{},
    };
}

test "mask pixels blend alpha over base verbatim" {
    var raster = FallbackRaster{};
    var cache = SwashCache.init(std.testing.allocator, raster.adapter());
    defer cache.deinit();
    // Override the cached image with known mask data.
    const key = testKey();
    const data = try std.testing.allocator.dupe(u8, &[_]u8{ 0xFF, 0x80 });
    try cache.image_cache.put(key, .{
        .placement = .{ .left = 10, .top = 4, .width = 2, .height = 1 },
        .content = .mask,
        .data = data,
    });
    var col = PixelCollector{ .alloc = std.testing.allocator };
    defer col.xs.deinit(col.alloc);
    defer col.ys.deinit(col.alloc);
    defer col.colors.deinit(col.alloc);
    const base: Color = 0x11223344;
    const n = try cache.withPixels(key, base, &col, PixelCollector.visit);
    try std.testing.expectEqual(@as(usize, 2), n);
    // Origin is (left, -top) = (10, -4).
    try std.testing.expectEqual(@as(i32, 10), col.xs.items[0]);
    try std.testing.expectEqual(@as(i32, -4), col.ys.items[0]);
    try std.testing.expectEqual((@as(u32, 0xFF) << 24) | (base & 0x00FF_FFFF), col.colors.items[0]);
    try std.testing.expectEqual((@as(u32, 0x80) << 24) | (base & 0x00FF_FFFF), col.colors.items[1]);
}

test "color pixels expand RGBA bytes" {
    var raster = FallbackRaster{};
    var cache = SwashCache.init(std.testing.allocator, raster.adapter());
    defer cache.deinit();
    const key = testKey();
    const data = try std.testing.allocator.dupe(u8, &[_]u8{ 1, 2, 3, 4 });
    try cache.image_cache.put(key, .{
        .placement = .{ .left = 0, .top = 0, .width = 1, .height = 1 },
        .content = .color,
        .data = data,
    });
    var col = PixelCollector{ .alloc = std.testing.allocator };
    defer col.xs.deinit(col.alloc);
    defer col.ys.deinit(col.alloc);
    defer col.colors.deinit(col.alloc);
    const n = try cache.withPixels(key, 0, &col, PixelCollector.visit);
    try std.testing.expectEqual(@as(usize, 1), n);
    try std.testing.expectEqual(rgba(1, 2, 3, 4), col.colors.items[0]);
}

test "image cache negatively caches misses" {
    var raster = FallbackRaster{ .miss_image = true };
    var cache = SwashCache.init(std.testing.allocator, raster.adapter());
    defer cache.deinit();
    const key = testKey();
    try std.testing.expect(try cache.getImage(key) == null);
    try std.testing.expect(try cache.getImage(key) == null);
    // Rasterizer ran once; the miss was cached.
    try std.testing.expectEqual(@as(usize, 1), raster.images_rendered);
}

test "no adapter means cached miss" {
    var cache = SwashCache.init(std.testing.allocator, null);
    defer cache.deinit();
    try std.testing.expect(try cache.getImage(testKey()) == null);
    try std.testing.expect(try cache.getOutline(testKey()) == null);
}

test "pixel font rounds offsets, fake italic skews 14deg" {
    const plain = testKey();
    const off = rasterOffset(plain);
    try std.testing.expectEqual(@as(f32, 0.25), off.x);
    var pix = testKey();
    pix.flags = FLAG_PIXEL_FONT;
    const rounded = rasterOffset(pix);
    try std.testing.expectEqual(@as(f32, 0.0), rounded.x);
    try std.testing.expectEqual(@as(f32, 1.0), rounded.y);
    try std.testing.expectApproxEqAbs(@as(f32, 0.2493280028), fakeItalicSkewDx(1.0), 1e-6);
    try std.testing.expectEqual(FAKE_ITALIC_DEGREES, 14.0);
}

test "wght clamp follows variation range" {
    try std.testing.expectEqual(@as(f32, 400.0), clampWght(400.0, 100.0, 900.0));
    try std.testing.expectEqual(@as(f32, 100.0), clampWght(50.0, 100.0, 900.0));
    try std.testing.expectEqual(@as(f32, 900.0), clampWght(950.0, 100.0, 900.0));
}

test "flags match glyph_cache verbatim (C1)" {
    // Cross-check: swash re-exports glyph_cache flags, so bits must equal
    // glyph_cache.rs:7-13 (FAKE_ITALIC=1, DISABLE_HINTING=2, PIXEL_FONT=4).
    // Imported in test only to avoid hiding a drift; non-test code uses the
    // re-export above.
    const gc = @import("glyph_cache.zig");
    try std.testing.expectEqual(gc.CacheKeyFlags.FAKE_ITALIC.bits, FLAG_FAKE_ITALIC.bits);
    try std.testing.expectEqual(gc.CacheKeyFlags.DISABLE_HINTING.bits, FLAG_DISABLE_HINTING.bits);
    try std.testing.expectEqual(gc.CacheKeyFlags.PIXEL_FONT.bits, FLAG_PIXEL_FONT.bits);
    try std.testing.expectEqual(@as(u32, 1), FLAG_FAKE_ITALIC.bits);
    try std.testing.expectEqual(@as(u32, 2), FLAG_DISABLE_HINTING.bits);
    try std.testing.expectEqual(@as(u32, 4), FLAG_PIXEL_FONT.bits);
    // hasFlag uses struct contains, not raw bit-and.
    var k = testKey();
    k.flags = FLAG_PIXEL_FONT;
    try std.testing.expect(k.flags.contains(FLAG_PIXEL_FONT));
    try std.testing.expect(!k.flags.contains(FLAG_DISABLE_HINTING));
}

test "cache key bins subpixel positions (C2)" {
    // new() boundary bins raw floats; hash/eql operate on bins, not floats.
    const r = CacheKey.new(7, 42, 16.0, .{ .x = 10.7, .y = 20.9 }, 400, .{});
    // 10.7 -> fract .7 in [0.625,0.875) => bin three, int 10.
    // 20.9 -> fract .9 >= .875 => carry to 21, bin zero.
    try std.testing.expectEqual(@as(i32, 10), r.x);
    try std.testing.expectEqual(@as(i32, 21), r.y);
    try std.testing.expectEqual(SubpixelBin.three, r.key.x_bin);
    try std.testing.expectEqual(SubpixelBin.zero, r.key.y_bin);
    // Same-bin positions hash/eql equal even though raw floats differ.
    const a = CacheKey.new(1, 1, 16.0, .{ .x = 0.26, .y = 0.51 }, 400, .{});
    const b = CacheKey.new(1, 1, 16.0, .{ .x = 0.30, .y = 0.60 }, 400, .{});
    try std.testing.expect(CacheKey.eql(a.key, b.key));
    try std.testing.expectEqual(KeyContext.hash(.{}, a.key), KeyContext.hash(.{}, b.key));
    // Different bins differ.
    const c = CacheKey.new(1, 1, 16.0, .{ .x = 0.0, .y = 0.0 }, 400, .{});
    try std.testing.expect(!CacheKey.eql(a.key, c.key));
    // rasterOffset operates on bin floats verbatim (swash.rs:48-55).
    const off = rasterOffset(a.key);
    try std.testing.expectEqual(@as(f32, 0.25), off.x);
    try std.testing.expectEqual(@as(f32, 0.5), off.y);
    var pix = a.key;
    pix.flags = FLAG_PIXEL_FONT;
    const rounded = rasterOffset(pix);
    try std.testing.expectEqual(@as(f32, 0.0), rounded.x);
    try std.testing.expectEqual(@as(f32, 1.0), rounded.y);
}

test "source order is color outline, color bitmap, outline" {
    try std.testing.expectEqual(RasterSource.color_outline, SOURCE_ORDER[0]);
    try std.testing.expectEqual(RasterSource.color_bitmap, SOURCE_ORDER[1]);
    try std.testing.expectEqual(RasterSource.outline, SOURCE_ORDER[2]);
}

fn readInterRegular(allocator: std.mem.Allocator) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        "tests/fonts/Inter-Regular.ttf",
        allocator,
        .limited(1 << 24),
    );
}

/// Glyph id for `codepoint` from a throwaway FreeType face (the harness has no
/// charmap of its own; production keys get ids from HarfBuzz).
fn interGlyphId(bytes: []const u8, codepoint: u32) !u16 {
    var lib = try raster_ft.Library.init();
    defer lib.deinit();
    var face = try raster_ft.Face.initMemory(&lib, bytes, 0);
    defer face.deinit();
    const id = face.charIndex(codepoint);
    if (id == 0) return error.TestUnexpectedResult;
    return @intCast(id);
}

test "raster-backed withPixels emits real FreeType coverage" {
    const allocator = std.testing.allocator;
    const bytes = try readInterRegular(allocator);
    defer allocator.free(bytes);

    var raster = try font_raster.Raster.init(allocator);
    defer raster.deinit();
    try raster.addFont(5, bytes, 0);

    var cache = SwashCache.init(allocator, null);
    defer cache.deinit();
    cache.setRaster(&raster);

    const key = CacheKey{
        .font_id = 5,
        .glyph_id = try interGlyphId(bytes, 'A'),
        .font_size_bits = @bitCast(@as(f32, 24.0)),
        .x_bin = .zero,
        .y_bin = .zero,
        .font_weight = 400,
        .flags = .{},
    };

    // The cached image is an owned mask with width*height alpha bytes and the
    // FreeType bearings as placement.
    const view = (try cache.getImage(key)) orelse return error.TestUnexpectedResult;
    try std.testing.expect(view.content == .mask);
    try std.testing.expect(view.placement.width > 0 and view.placement.height > 0);
    try std.testing.expectEqual(
        @as(usize, view.placement.width) * view.placement.height,
        view.data.len,
    );

    var col = PixelCollector{ .alloc = allocator };
    defer col.xs.deinit(allocator);
    defer col.ys.deinit(allocator);
    defer col.colors.deinit(allocator);
    const n = try cache.withPixels(key, 0, &col, PixelCollector.visit);
    try std.testing.expectEqual(view.data.len, n);
    var opaque_count: usize = 0;
    for (col.colors.items) |color| {
        if ((color >> 24) != 0) opaque_count += 1;
    }
    try std.testing.expect(opaque_count > 0);

    // Unknown font id through the raster is an explicit (cached) miss; the
    // raster is authoritative and does not fall back to synthetic pixels.
    var miss_key = key;
    miss_key.font_id = 99;
    try std.testing.expect(try cache.getImage(miss_key) == null);
    try std.testing.expect(try cache.getImage(miss_key) == null);

    // Detaching drops raster-derived entries: with no adapter left, the same
    // key becomes a miss again.
    cache.setRaster(null);
    try std.testing.expect(try cache.getImage(key) == null);
}

test "imageFromRendered unwraps row padding, pitch, and mono bits" {
    // Gray, pitch -2: FreeType up-flow memory starts at the *bottom* row, so
    // the visual top row is the second chunk; bytes 1 and 3 are padding.
    const up_flow = raster_ft.Rendered{
        .width = 1,
        .height = 2,
        .left = 3,
        .top = 4,
        .advance_x = 64,
        .pixel_mode = raster_ft.FT_PIXEL_MODE_GRAY,
        .bitmap = &.{ 0x11, 0x00, 0x22, 0x00 },
        .pitch = -2,
    };
    const image = (try imageFromRendered(std.testing.allocator, up_flow)).?;
    defer std.testing.allocator.free(image.data);
    try std.testing.expectEqual(ImageContent.mask, image.content);
    try std.testing.expectEqual(@as(i32, 3), image.placement.left);
    try std.testing.expectEqual(@as(i32, 4), image.placement.top);
    try std.testing.expectEqualSlices(u8, &.{ 0x22, 0x11 }, image.data);

    // Mono, one packed row: the MSB is the leftmost pixel.
    const mono = raster_ft.Rendered{
        .width = 4,
        .height = 1,
        .left = 0,
        .top = 1,
        .advance_x = 256,
        .pixel_mode = raster_ft.FT_PIXEL_MODE_MONO,
        .bitmap = &.{0b1010_0000},
        .pitch = 1,
    };
    const mono_image = (try imageFromRendered(std.testing.allocator, mono)).?;
    defer std.testing.allocator.free(mono_image.data);
    try std.testing.expectEqualSlices(u8, &.{ 0xFF, 0x00, 0xFF, 0x00 }, mono_image.data);

    // Subpixel/color layouts are not representable and are an explicit miss.
    var lcd = up_flow;
    lcd.pixel_mode = raster_ft.FT_PIXEL_MODE_LCD;
    try std.testing.expect(try imageFromRendered(std.testing.allocator, lcd) == null);
}

test {
    // Include the FreeType registry's own tests in this module's test build.
    _ = @import("font_raster.zig");
}
