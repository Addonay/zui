//! FreeType 2 backend: font metrics + glyph rasterization (real C library).
//!
//! This is a thin adapter over the vendored `freetype` binding module
//! (`src/freetype/`, the allyourcodebase bindings with `zig translate-c`
//! `c_bindings.zig`). That module owns the C ABI surface — `FT_FaceRec`,
//! `FT_GlyphSlotRec`, `FT_Bitmap`, the `FT_*` call signatures — and the
//! `ft.Library` / `ft.Face` wrappers. This file only:
//!
//! - exposes the loader/raster/pixel flags consumers here use as `FT_*`
//!   aliases of the vendored constants,
//! - maps FreeType's ~90 error codes down to the small `Error` set callers of
//!   this module have always seen,
//! - snapshots a rendered glyph slot into `Rendered`.
//!
//! Struct layouts and offsets are asserted against the translated bindings by
//! the "ABI layout" test.
//!
//! ## Lifetime
//!
//! - `Library` owns the `FT_Library`. Every `Face` made from it borrows the
//!   library and must not outlive it (FreeType keeps no back-pointer we need,
//!   but the underlying allocator belongs to the library).
//! - `Face.initMemory` does **not** copy the font bytes: `bytes` must stay
//!   alive and at a stable address until `Face.deinit`. `Face.owns_blob` is
//!   `false` accordingly, documented rather than silently assumed.
//! - `Rendered.bitmap` borrows the face's glyph slot. It is invalidated by the
//!   next `loadRender` / `loadRenderFlags` call (and by `Face.deinit`); copy it
//!   if it must outlive the call. `Rendered` needs no `deinit`.
//! - `Face` and `Library` are single-threaded like the underlying objects: use
//!   one per thread, or serialize access externally.

const std = @import("std");
const ft = @import("freetype");

/// Vendored translate-c bindings (same names an `@cImport` would have made).
const c = ft.c;

// ---------------------------------------------------------------------------
// Public constants (`FT_LOAD_*`, `FT_RENDER_MODE_*`, `FT_PIXEL_MODE_*`)
// ---------------------------------------------------------------------------

/// `FT_LOAD_DEFAULT`: native hinting + no bitmap format forcing.
pub const FT_LOAD_DEFAULT: c_int = c.FT_LOAD_DEFAULT;
/// `FT_LOAD_NO_HINTING` (combine with `FT_LOAD_NO_AUTOHINT` for unhinted).
pub const FT_LOAD_NO_HINTING: c_int = @intCast(c.FT_LOAD_NO_HINTING);
/// `FT_LOAD_RENDER`: render the glyph into `slot.bitmap` while loading.
pub const FT_LOAD_RENDER: c_int = @intCast(c.FT_LOAD_RENDER);
/// `FT_LOAD_NO_BITMAP`: ignore embedded bitmap strikes, keep outlines.
pub const FT_LOAD_NO_BITMAP: c_int = @intCast(c.FT_LOAD_NO_BITMAP);
/// `FT_LOAD_TARGET_NORMAL` (the default rendering target).
pub const FT_LOAD_TARGET_NORMAL: c_int = @intCast(c.FT_LOAD_TARGET_NORMAL);
/// `FT_RENDER_MODE_NORMAL`: anti-aliased 8-bit coverage.
pub const FT_RENDER_MODE_NORMAL: c_int = c.FT_RENDER_MODE_NORMAL;
/// `FT_PIXEL_MODE_MONO`: 1 bit/pixel, MSB first.
pub const FT_PIXEL_MODE_MONO: u8 = @intCast(c.FT_PIXEL_MODE_MONO);
/// `FT_PIXEL_MODE_GRAY`: 8-bit coverage (or LCD bytes, see below).
pub const FT_PIXEL_MODE_GRAY: u8 = @intCast(c.FT_PIXEL_MODE_GRAY);
/// `FT_PIXEL_MODE_GRAY2`: 2-bit embedded AA bitmap.
pub const FT_PIXEL_MODE_GRAY2: u8 = @intCast(c.FT_PIXEL_MODE_GRAY2);
/// `FT_PIXEL_MODE_GRAY4`: 4-bit embedded AA bitmap.
pub const FT_PIXEL_MODE_GRAY4: u8 = @intCast(c.FT_PIXEL_MODE_GRAY4);
/// `FT_PIXEL_MODE_LCD`: 8-bit per subpixel, 3x wider than the glyph.
pub const FT_PIXEL_MODE_LCD: u8 = @intCast(c.FT_PIXEL_MODE_LCD);
/// `FT_PIXEL_MODE_LCD_V`: 8-bit per subpixel, 3x taller than the glyph.
pub const FT_PIXEL_MODE_LCD_V: u8 = @intCast(c.FT_PIXEL_MODE_LCD_V);
/// `FT_PIXEL_MODE_BGRA`: 4x8-bit premultiplied color, blue first.
pub const FT_PIXEL_MODE_BGRA: u8 = @intCast(c.FT_PIXEL_MODE_BGRA);
/// `FT_GLYPH_FORMAT_BITMAP` = `FT_MAKE_TAG('b','i','t','s')`.
pub const FT_GLYPH_FORMAT_BITMAP: u32 = @intCast(c.FT_GLYPH_FORMAT_BITMAP);
/// `FT_KERNING_DEFAULT`: full, grid-fitted kerning.
pub const FT_KERNING_DEFAULT: c_uint = @intCast(c.FT_KERNING_DEFAULT);

// ABI type aliases kept for callers that name these structs directly; the
// layouts and `extern fn` signatures live in the vendored bindings now.
pub const FT_Library = c.FT_Library;
pub const FT_Face = c.FT_Face;
pub const FT_GlyphSlot = c.FT_GlyphSlot;
pub const FT_Generic = c.FT_Generic;
pub const FT_Vector = c.FT_Vector;
pub const FT_BBox = c.FT_BBox;
pub const FT_Glyph_Metrics = c.FT_Glyph_Metrics;
pub const FT_Bitmap = c.FT_Bitmap;
pub const FT_GlyphSlotRec = c.FT_GlyphSlotRec;
pub const FT_FaceRec = c.FT_FaceRec;

// ---------------------------------------------------------------------------
// Error mapping.
// ---------------------------------------------------------------------------

/// Errors surfaced by this module.
pub const Error = error{
    /// The font data was recognized as a known format but is structurally
    /// broken (`FT_Err_Invalid_File_Format`).
    InvalidFileFormat,
    /// No FreeType driver recognized the data (`FT_Err_Unknown_File_Format`).
    UnknownFileFormat,
    /// Bad face index, out-of-range glyph, or other invalid argument
    /// (`FT_Err_Invalid_Argument`).
    InvalidArgument,
    /// `FT_Err_Invalid_Glyph_Index` (returned by some drivers instead of
    /// `InvalidArgument` for out-of-range glyph ids).
    InvalidGlyphIndex,
    /// A zero width/height reached `FT_Set_Pixel_Sizes`
    /// (`FT_Err_Invalid_Pixel_Size`); rejected before calling FreeType.
    InvalidPixelSize,
    /// A null/deinitialized handle, or an unmapped non-zero FreeType code.
    FreeTypeFailure,
};

/// Map a raw `FT_Error` code from a `ft.c` call.
fn ftError(code: c_int) Error {
    return switch (code) {
        c.FT_Err_Unknown_File_Format => error.UnknownFileFormat,
        c.FT_Err_Invalid_File_Format => error.InvalidFileFormat,
        c.FT_Err_Invalid_Argument => error.InvalidArgument,
        c.FT_Err_Invalid_Glyph_Index => error.InvalidGlyphIndex,
        c.FT_Err_Invalid_Pixel_Size => error.InvalidPixelSize,
        else => error.FreeTypeFailure,
    };
}

/// Map an error from the vendored `ft.Library` / `ft.Face` wrappers (which
/// surface the full FreeType error set) onto this module's small set.
fn wrapperError(err: ft.Error) Error {
    return switch (err) {
        error.UnknownFileFormat => error.UnknownFileFormat,
        error.InvalidFileFormat => error.InvalidFileFormat,
        error.InvalidArgument => error.InvalidArgument,
        error.InvalidGlyphIndex => error.InvalidGlyphIndex,
        error.InvalidPixelSize => error.InvalidPixelSize,
        else => error.FreeTypeFailure,
    };
}

// ---------------------------------------------------------------------------
// Library.
// ---------------------------------------------------------------------------

/// An initialized `FT_Library`.
pub const Library = struct {
    /// Vendored wrapper around the raw `FT_Library`; `null` before `init` and
    /// after `deinit`.
    handle: ?ft.Library,

    /// `FT_Init_FreeType`.
    pub fn init() Error!Library {
        const handle = ft.Library.init() catch |err| return wrapperError(err);
        return .{ .handle = handle };
    }

    /// `FT_Done_FreeType`. Safe to call twice; the second call is a no-op.
    ///
    /// The return code is intentionally dropped: FreeType only fails this for
    /// invalid/unbalanced handles, which is a caller bug with no recovery
    /// path. The wrapper is cleared *before* the call so a double `deinit`
    /// cannot double-free.
    pub fn deinit(self: *Library) void {
        if (self.handle) |handle| {
            self.handle = null;
            handle.deinit();
        }
    }

    pub const Version = struct {
        major: c_int,
        minor: c_int,
        patch: c_int,
    };

    /// `FT_Library_Version`; `null` when the library is not live.
    pub fn version(self: *const Library) ?Version {
        const handle = self.handle orelse return null;
        const v = handle.version();
        if (v.major == 0 and v.minor == 0 and v.patch == 0) return null;
        return .{ .major = v.major, .minor = v.minor, .patch = v.patch };
    }
};

// ---------------------------------------------------------------------------
// Face.
// ---------------------------------------------------------------------------

/// A loaded `FT_Face` (one face of a font file).
pub const Face = struct {
    /// Library that created this face. Borrowed: it must outlive the face.
    library: *const Library,
    /// Vendored wrapper around the raw `FT_Face`.
    handle: ft.Face,
    /// Always `false` today: `initMemory` borrows the caller's bytes instead
    /// of copying them. Present so callers can assert the ownership contract
    /// instead of assuming it (a future file-backed loader would set `true`).
    owns_blob: bool,

    /// Raw C `FT_Face`, borrowed. For callers that need to hand the handle to
    /// other C libraries (e.g. HarfBuzz); prefer the methods below.
    pub fn raw(self: *const Face) c.FT_Face {
        return self.handle.handle;
    }

    /// `FT_New_Memory_Face` over caller-owned bytes.
    ///
    /// The bytes are **not** copied (FreeType keeps a pointer into them), so
    /// they must stay alive and unmoved until `deinit`. `index` selects a
    /// face in a collection; out-of-range indices fail with
    /// `error.InvalidArgument`.
    pub fn initMemory(library: *const Library, bytes: []const u8, index: i32) Error!Face {
        const lib = library.handle orelse return error.FreeTypeFailure;
        if (bytes.len == 0) return error.InvalidFileFormat;
        if (bytes.len > std.math.maxInt(c_long)) return error.InvalidArgument;
        const handle = lib.initMemoryFace(bytes, index) catch |err| return wrapperError(err);
        return .{
            .library = library,
            .handle = handle,
            .owns_blob = false,
        };
    }

    /// `FT_Done_Face`. Not idempotent (FreeType does not allow it); call once.
    pub fn deinit(self: *Face) void {
        self.handle.deinit();
        self.* = undefined;
    }

    // -- Immutable metrics -------------------------------------------------

    /// `units_per_EM` (design units per em).
    pub fn upem(self: *const Face) u16 {
        return @intCast(self.handle.handle.*.units_per_EM);
    }

    /// Horizontal ascender in design units, positive for the usual case.
    pub fn ascent(self: *const Face) i16 {
        return @intCast(self.handle.handle.*.ascender);
    }

    /// Horizontal descender in design units: negative for the usual case
    /// (FreeType uses a y-down coordinate system).
    pub fn descent(self: *const Face) i16 {
        return @intCast(self.handle.handle.*.descender);
    }

    /// Recommended baseline-to-baseline distance in design units.
    pub fn height(self: *const Face) i16 {
        return @intCast(self.handle.handle.*.height);
    }

    /// Underline top from the baseline in design units (usually negative).
    pub fn underlinePosition(self: *const Face) i16 {
        return @intCast(self.handle.handle.*.underline_position);
    }

    /// Underline stroke thickness in design units.
    pub fn underlineThickness(self: *const Face) i16 {
        return @intCast(self.handle.handle.*.underline_thickness);
    }

    /// Number of glyphs in the face (0 for a malformed/negative count).
    pub fn glyphCount(self: *const Face) u32 {
        return @intCast(@max(self.handle.handle.*.num_glyphs, 0));
    }

    /// Family name as NUL-terminated C string, if the face has one.
    pub fn familyName(self: *const Face) ?[]const u8 {
        const name = self.handle.handle.*.family_name;
        if (name == null) return null;
        return std.mem.sliceTo(name, 0);
    }

    /// Style (subfamily) name, if the face has one.
    pub fn styleName(self: *const Face) ?[]const u8 {
        const name = self.handle.handle.*.style_name;
        if (name == null) return null;
        return std.mem.sliceTo(name, 0);
    }

    /// `FT_Get_Char_Index`: glyph id for a Unicode codepoint, 0 when absent.
    pub fn charIndex(self: *const Face, codepoint: u32) u32 {
        return @intCast(c.FT_Get_Char_Index(self.handle.handle, codepoint));
    }

    // -- Sizing / raster ---------------------------------------------------

    /// `FT_Set_Pixel_Sizes`. Rejects zero dimensions up front with
    /// `error.InvalidPixelSize`: FreeType accepts `(0, 0)` but then renders
    /// degenerate 1x1 bitmaps.
    pub fn setPixelSizes(self: *Face, pixel_width: u32, pixel_height: u32) Error!void {
        if (pixel_width == 0 or pixel_height == 0) return error.InvalidPixelSize;
        const code = c.FT_Set_Pixel_Sizes(self.handle.handle, pixel_width, pixel_height);
        if (code != c.FT_Err_Ok) return ftError(code);
    }

    /// Load + render a glyph at a square pixel size (26.6-free, pixels).
    ///
    /// Equivalent to `loadRenderFlags(glyph, pixel_size, FT_LOAD_DEFAULT)`.
    pub fn loadRender(self: *Face, glyph: u32, pixel_size: u16) Error!Rendered {
        return self.loadRenderFlags(glyph, pixel_size, FT_LOAD_DEFAULT);
    }

    /// Load a glyph with explicit `FT_LOAD_*` flags and render it when the
    /// load produced an outline (embedded bitmap strikes are already bitmaps).
    ///
    /// Rendering uses `FT_Render_Glyph(slot, FT_RENDER_MODE_NORMAL)`. Pass
    /// e.g. `FT_LOAD_DEFAULT | FT_LOAD_NO_HINTING` for unhinted coverage or
    /// `FT_LOAD_DEFAULT | FT_LOAD_NO_BITMAP` to force outline rendering.
    pub fn loadRenderFlags(
        self: *Face,
        glyph: u32,
        pixel_size: u16,
        load_flags: c_int,
    ) Error!Rendered {
        try self.setPixelSizes(pixel_size, pixel_size);
        const code = c.FT_Load_Glyph(self.handle.handle, glyph, load_flags);
        if (code != c.FT_Err_Ok) return ftError(code);
        const slot = self.handle.handle.*.glyph;
        if (slot == null) return error.FreeTypeFailure;
        if (slot.*.format != FT_GLYPH_FORMAT_BITMAP) {
            const render_code = c.FT_Render_Glyph(slot, @intCast(c.FT_RENDER_MODE_NORMAL));
            if (render_code != c.FT_Err_Ok) return ftError(render_code);
        }
        return snapshot(slot);
    }

    /// `FT_Get_Kerning` with `FT_KERNING_DEFAULT`.
    ///
    /// Returns the x kerning in 26.6 fixed point (64 = 1 pixel); FreeType
    /// reports 0 (not an error) for faces without kerning data.
    pub fn kerning(self: *const Face, left_glyph: u32, right_glyph: u32) Error!i64 {
        var v: c.FT_Vector = .{};
        const code = c.FT_Get_Kerning(
            self.handle.handle,
            left_glyph,
            right_glyph,
            @intCast(c.FT_KERNING_DEFAULT),
            &v,
        );
        if (code != c.FT_Err_Ok) return ftError(code);
        return @intCast(v.x);
    }
};

/// A rendered glyph bitmap. `bitmap` borrows the face's glyph slot (see the
/// module docs): it is valid until the next `Face.loadRender*` call or
/// `Face.deinit`.
pub const Rendered = struct {
    /// Physical bitmap width in pixels (3x the logical width for
    /// `FT_PIXEL_MODE_LCD`).
    width: u32,
    /// Physical bitmap height in rows (3x the logical height for
    /// `FT_PIXEL_MODE_LCD_V`).
    height: u32,
    /// `bitmap_left`: left bearing in whole pixels, i.e. pen-x to the left
    /// edge of the bitmap.
    left: i32,
    /// `bitmap_top`: top bearing in whole pixels, i.e. baseline y-up to the
    /// top edge of the bitmap.
    top: i32,
    /// Fitted horizontal advance in 26.6 fixed point (`/ 64` = pixels).
    advance_x: i64,
    /// One of `FT_PIXEL_MODE_*`.
    pixel_mode: u8,
    /// Borrowed coverage/color bytes: `height * stride()` bytes when the
    /// bitmap is non-empty, otherwise an empty slice. Rows may include
    /// padding; use `rowSlice` for exact row bytes.
    bitmap: []const u8,
    /// Signed stride: positive = top row first (down flow), negative =
    /// bottom-up (up flow, `buffer` points at the bottom row).
    pitch: i32,

    /// Absolute row stride in bytes.
    pub fn stride(self: Rendered) usize {
        if (self.pitch < 0) return @intCast(-@as(i64, self.pitch));
        return @intCast(self.pitch);
    }

    /// Exact bytes of visual row `row` (0 = top), padding excluded.
    /// Returns an empty slice when `row` is out of range or the bitmap is
    /// empty. Handles negative pitch (up-flow) by walking rows in reverse
    /// memory order.
    pub fn rowSlice(self: Rendered, row: u32) []const u8 {
        if (row >= self.height) return &.{};
        const stride_bytes = self.stride();
        if (stride_bytes == 0) return &.{};
        const physical_row: u32 = if (self.pitch < 0) self.height - 1 - row else row;
        const start = @as(usize, physical_row) * stride_bytes;
        if (start >= self.bitmap.len) return &.{};
        const packed_len = packedRowBytes(self.pixel_mode, self.width);
        return self.bitmap[start..][0..@min(packed_len, self.bitmap.len - start)];
    }
};

/// Packed (unpadded) bytes per row for a pixel mode, mirroring FreeType's own
/// `ft_glyphslot_preset_bitmap` sizes:
/// - MONO: `(width + 7) / 8`
/// - GRAY / LCD / LCD_V: `width` (LCD/LCD_V widths already count subpixels)
/// - BGRA: `width * 4`
/// - anything else: 0 (unknown layout)
pub fn packedRowBytes(pixel_mode: u8, width: u32) usize {
    return switch (pixel_mode) {
        FT_PIXEL_MODE_MONO => (@as(usize, width) + 7) / 8,
        FT_PIXEL_MODE_GRAY, FT_PIXEL_MODE_LCD, FT_PIXEL_MODE_LCD_V => @as(usize, width),
        FT_PIXEL_MODE_BGRA => @as(usize, width) * 4,
        else => 0,
    };
}

fn snapshot(slot: c.FT_GlyphSlot) Error!Rendered {
    const bmp = &slot.*.bitmap;
    const rows: usize = @intCast(bmp.rows);
    const stride_bytes: usize = if (bmp.pitch < 0)
        @intCast(-@as(i64, bmp.pitch))
    else
        @intCast(bmp.pitch);

    var bytes: []const u8 = &.{};
    if (bmp.buffer != null) {
        const buffer = bmp.buffer;
        if (bmp.width != 0 and rows != 0 and stride_bytes != 0) {
            const len = std.math.mul(usize, rows, stride_bytes) catch
                return error.FreeTypeFailure;
            bytes = buffer[0..len];
        }
    }

    return .{
        .width = @intCast(bmp.width),
        .height = @intCast(bmp.rows),
        .left = @intCast(slot.*.bitmap_left),
        .top = @intCast(slot.*.bitmap_top),
        .advance_x = @intCast(slot.*.advance.x),
        .pixel_mode = bmp.pixel_mode,
        .bitmap = bytes,
        .pitch = @intCast(bmp.pitch),
    };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;
const font = @import("font.zig");

/// Vendored font corpus, probed like the other real-font tests in this repo
/// (`tests/fonts` when run from the package root, one level up when run from
/// `src/`).
const font_path_prefixes = [_][]const u8{
    "tests/fonts/",
    "../tests/fonts/",
    "src/../tests/fonts/",
};

fn readTestFont(allocator: std.mem.Allocator, file: []const u8) ![]u8 {
    var last_err: anyerror = error.FileNotFound;
    for (font_path_prefixes) |prefix| {
        const path = try std.fs.path.join(allocator, &.{ prefix, file });
        defer allocator.free(path);
        if (std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, allocator, .limited(1 << 24))) |bytes| {
            return bytes;
        } else |e| {
            last_err = e;
        }
    }
    // Only a genuinely missing corpus skips; other I/O errors propagate so a
    // broken fixture cannot silently turn into a green skip.
    if (last_err == error.FileNotFound) return error.SkipZigTest;
    return last_err;
}

fn countNonZero(bytes: []const u8) usize {
    var n: usize = 0;
    for (bytes) |b| {
        if (b != 0) n += 1;
    }
    return n;
}

const FaceCase = struct {
    file: []const u8,
    family: []const u8,
};

const face_cases = [_]FaceCase{
    .{ .file = "Inter-Regular.ttf", .family = "Inter" },
    .{ .file = "FiraMono-Medium.ttf", .family = "Fira Mono" },
};

test "ABI layout matches installed FreeType (LP64)" {
    // Only x86_64/aarch64 LP64 is validated here; on other models FreeType's
    // `long`/`int` widths change the offsets and this test steps aside.
    if (@sizeOf(c_long) != 8 or @sizeOf(c_int) != 4 or @sizeOf(c_short) != 2) {
        return error.SkipZigTest;
    }

    // Self-contained structs, embedded by value in face/slot. These are the
    // vendored translate-c structs, so this pins the generated bindings to
    // the installed FreeType headers.
    try testing.expectEqual(@as(usize, 16), @sizeOf(c.FT_Generic));
    try testing.expectEqual(@as(usize, 16), @sizeOf(c.FT_Vector));
    try testing.expectEqual(@as(usize, 32), @sizeOf(c.FT_BBox));
    try testing.expectEqual(@as(usize, 64), @sizeOf(c.FT_Glyph_Metrics));
    try testing.expectEqual(@as(usize, 40), @sizeOf(c.FT_Bitmap));
    try testing.expectEqual(@as(usize, 16), @offsetOf(c.FT_Bitmap, "buffer"));
    try testing.expectEqual(@as(usize, 24), @offsetOf(c.FT_Bitmap, "num_grays"));

    // FT_GlyphSlotRec prefix offsets (C `offsetof` on the installed headers).
    try testing.expectEqual(@as(usize, 0), @offsetOf(c.FT_GlyphSlotRec, "library"));
    try testing.expectEqual(@as(usize, 16), @offsetOf(c.FT_GlyphSlotRec, "next"));
    try testing.expectEqual(@as(usize, 24), @offsetOf(c.FT_GlyphSlotRec, "glyph_index"));
    try testing.expectEqual(@as(usize, 32), @offsetOf(c.FT_GlyphSlotRec, "generic"));
    try testing.expectEqual(@as(usize, 48), @offsetOf(c.FT_GlyphSlotRec, "metrics"));
    try testing.expectEqual(@as(usize, 112), @offsetOf(c.FT_GlyphSlotRec, "linearHoriAdvance"));
    try testing.expectEqual(@as(usize, 128), @offsetOf(c.FT_GlyphSlotRec, "advance"));
    try testing.expectEqual(@as(usize, 144), @offsetOf(c.FT_GlyphSlotRec, "format"));
    try testing.expectEqual(@as(usize, 152), @offsetOf(c.FT_GlyphSlotRec, "bitmap"));
    try testing.expectEqual(@as(usize, 192), @offsetOf(c.FT_GlyphSlotRec, "bitmap_left"));
    try testing.expectEqual(@as(usize, 196), @offsetOf(c.FT_GlyphSlotRec, "bitmap_top"));
    // Unlike the old prefix-only mirror, the generated struct models the
    // private tail too, so it is larger than the public prefix.
    try testing.expect(@sizeOf(c.FT_GlyphSlotRec) > 200);

    // FT_FaceRec prefix offsets.
    try testing.expectEqual(@as(usize, 0), @offsetOf(c.FT_FaceRec, "num_faces"));
    try testing.expectEqual(@as(usize, 32), @offsetOf(c.FT_FaceRec, "num_glyphs"));
    try testing.expectEqual(@as(usize, 40), @offsetOf(c.FT_FaceRec, "family_name"));
    try testing.expectEqual(@as(usize, 48), @offsetOf(c.FT_FaceRec, "style_name"));
    try testing.expectEqual(@as(usize, 56), @offsetOf(c.FT_FaceRec, "num_fixed_sizes"));
    try testing.expectEqual(@as(usize, 64), @offsetOf(c.FT_FaceRec, "available_sizes"));
    try testing.expectEqual(@as(usize, 72), @offsetOf(c.FT_FaceRec, "num_charmaps"));
    try testing.expectEqual(@as(usize, 80), @offsetOf(c.FT_FaceRec, "charmaps"));
    try testing.expectEqual(@as(usize, 88), @offsetOf(c.FT_FaceRec, "generic"));
    try testing.expectEqual(@as(usize, 104), @offsetOf(c.FT_FaceRec, "bbox"));
    try testing.expectEqual(@as(usize, 136), @offsetOf(c.FT_FaceRec, "units_per_EM"));
    try testing.expectEqual(@as(usize, 138), @offsetOf(c.FT_FaceRec, "ascender"));
    try testing.expectEqual(@as(usize, 140), @offsetOf(c.FT_FaceRec, "descender"));
    try testing.expectEqual(@as(usize, 142), @offsetOf(c.FT_FaceRec, "height"));
    try testing.expectEqual(@as(usize, 148), @offsetOf(c.FT_FaceRec, "underline_position"));
    try testing.expectEqual(@as(usize, 150), @offsetOf(c.FT_FaceRec, "underline_thickness"));
    try testing.expectEqual(@as(usize, 152), @offsetOf(c.FT_FaceRec, "glyph"));
    try testing.expectEqual(@as(usize, 160), @offsetOf(c.FT_FaceRec, "size"));
    try testing.expectEqual(@as(usize, 168), @offsetOf(c.FT_FaceRec, "charmap"));

    // Pixel mode values must match the C enum exactly.
    try testing.expectEqual(@as(u8, 1), FT_PIXEL_MODE_MONO);
    try testing.expectEqual(@as(u8, 2), FT_PIXEL_MODE_GRAY);
    try testing.expectEqual(@as(u8, 5), FT_PIXEL_MODE_LCD);
    try testing.expectEqual(@as(u8, 7), FT_PIXEL_MODE_BGRA);
    try testing.expectEqual(c.FT_PIXEL_MODE_LCD, @as(c_int, FT_PIXEL_MODE_LCD));
}

test "Library init exposes version, deinit is idempotent" {
    var lib = try Library.init();
    defer lib.deinit();

    const version = lib.version() orelse return error.TestUnexpectedResult;
    try testing.expect(version.major >= 2);
    try testing.expect(version.minor >= 0);
    try testing.expect(version.patch >= 0);

    lib.deinit();
    try testing.expect(lib.version() == null);
}

test "face metrics agree with font.zig sfnt sniff" {
    const allocator = testing.allocator;
    for (face_cases) |case| {
        const bytes = try readTestFont(allocator, case.file);
        defer allocator.free(bytes);

        var lib = try Library.init();
        defer lib.deinit();
        var face = try Face.initMemory(&lib, bytes, 0);
        defer face.deinit();

        const sniffed = font.sniffMetrics(bytes);
        try testing.expectEqual(font.Font.MetricsSource.sniffed, sniffed.source);

        // Cross-check the FreeType values against the pure-Zig sfnt parse.
        try testing.expectEqual(sniffed.metrics.units_per_em, face.upem());
        try testing.expectEqual(
            sniffed.metrics.ascent,
            @as(f32, @floatFromInt(face.ascent())),
        );
        try testing.expectEqual(
            sniffed.metrics.descent,
            @as(f32, @floatFromInt(face.descent())),
        );

        // Sanity: scalable outlines with y-down metrics.
        try testing.expect(face.upem() > 0);
        try testing.expect(face.ascent() > 0);
        try testing.expect(face.descent() < 0);
        try testing.expect(face.glyphCount() > 100);
        // TrueType `height` is ascender - descender (fits i32).
        try testing.expectEqual(
            @as(i32, face.ascent()) - @as(i32, face.descent()),
            @as(i32, face.height()),
        );
        try testing.expect(face.underlineThickness() > 0);

        // Runtime check of the translated `family_name` field.
        try testing.expectEqualStrings(case.family, face.familyName() orelse "");
        try testing.expect(face.raw().*.num_faces == 1);
    }
}

test "charIndex resolves ASCII and Arabic codepoints" {
    const allocator = testing.allocator;

    const latin_bytes = try readTestFont(allocator, "Inter-Regular.ttf");
    defer allocator.free(latin_bytes);
    var lib = try Library.init();
    defer lib.deinit();
    var latin = try Face.initMemory(&lib, latin_bytes, 0);
    defer latin.deinit();

    const a = latin.charIndex('A');
    try testing.expect(a != 0);
    try testing.expect(latin.charIndex('V') != 0);
    try testing.expect(latin.charIndex('A') != latin.charIndex('V'));
    // U+10FFFF is a noncharacter: no glyph, but looking it up must not trap.
    try testing.expectEqual(@as(u32, 0), latin.charIndex(0x10FFFF));

    const arabic_bytes = try readTestFont(allocator, "NotoSansArabic.ttf");
    defer allocator.free(arabic_bytes);
    var arabic = try Face.initMemory(&lib, arabic_bytes, 0);
    defer arabic.deinit();
    try testing.expect(arabic.charIndex(0x645) != 0); // ARABIC LETTER MEEM

    // Kerning must answer without error (Inter has no pair kerning here).
    _ = try latin.kerning(a, latin.charIndex('V'));
}

test "loadRender returns a borrowed gray coverage bitmap" {
    const allocator = testing.allocator;
    const bytes = try readTestFont(allocator, "Inter-Regular.ttf");
    defer allocator.free(bytes);

    var lib = try Library.init();
    defer lib.deinit();
    var face = try Face.initMemory(&lib, bytes, 0);
    defer face.deinit();

    const glyph = face.charIndex('A');
    try testing.expect(glyph != 0);

    const rendered = try face.loadRender(glyph, 16);
    try testing.expect(rendered.width > 0);
    try testing.expect(rendered.height > 0);
    try testing.expectEqual(FT_PIXEL_MODE_GRAY, rendered.pixel_mode);
    try testing.expect(rendered.pitch > 0);
    try testing.expectEqual(
        @as(usize, rendered.height) * rendered.stride(),
        rendered.bitmap.len,
    );
    try testing.expectEqual(@as(usize, rendered.width), rendered.rowSlice(0).len);
    try testing.expect(countNonZero(rendered.bitmap) > 0);
    try testing.expect(rendered.advance_x > 0);
    // Inter's 'A' at 16px: 10px advance => 640 in 26.6.
    try testing.expectEqual(@as(i64, 640), rendered.advance_x);

    // The bitmap borrows slot memory; the same call again must be stable.
    const again = try face.loadRender(glyph, 16);
    try testing.expectEqual(rendered.width, again.width);
    try testing.expectEqual(rendered.height, again.height);
}

test "larger pixel sizes produce larger rasters" {
    const allocator = testing.allocator;
    const bytes = try readTestFont(allocator, "FiraMono-Medium.ttf");
    defer allocator.free(bytes);

    var lib = try Library.init();
    defer lib.deinit();
    var face = try Face.initMemory(&lib, bytes, 0);
    defer face.deinit();

    const glyph = face.charIndex('A');
    const small = try face.loadRender(glyph, 8);
    const small_width = small.width;
    const small_height = small.height;
    const small_len = small.bitmap.len;
    try testing.expect(small_width > 0);
    try testing.expect(small_height > 0);

    // `small.bitmap` is invalidated by the next load; only the copied scalars
    // above may be used after this point.
    const large = try face.loadRender(glyph, 32);
    try testing.expect(large.width > small_width);
    try testing.expect(large.height > small_height);
    try testing.expect(large.bitmap.len > small_len);
    try testing.expectEqual(
        @as(usize, large.height) * large.stride(),
        large.bitmap.len,
    );

    // Unhinted rendering goes through the same path and stays gray.
    const unhinted = try face.loadRenderFlags(
        glyph,
        32,
        FT_LOAD_DEFAULT | FT_LOAD_NO_HINTING,
    );
    try testing.expectEqual(FT_PIXEL_MODE_GRAY, unhinted.pixel_mode);
    try testing.expect(unhinted.width > 0 and unhinted.height > 0);
}

test "zero-size and out-of-range glyphs fail without trapping" {
    const allocator = testing.allocator;
    const bytes = try readTestFont(allocator, "Inter-Regular.ttf");
    defer allocator.free(bytes);

    var lib = try Library.init();
    defer lib.deinit();
    var face = try Face.initMemory(&lib, bytes, 0);
    defer face.deinit();

    try testing.expectError(error.InvalidPixelSize, face.setPixelSizes(0, 16));
    try testing.expectError(error.InvalidPixelSize, face.setPixelSizes(16, 0));
    const glyph = face.charIndex('A');
    try testing.expectError(error.InvalidPixelSize, face.loadRender(glyph, 0));

    // FreeType reports Invalid_Argument (or Invalid_Glyph_Index on some
    // drivers) for ids past `num_glyphs`; either is fine, a trap is not.
    const oob = face.loadRender(face.glyphCount() + 1000, 16);
    try testing.expect(oob == error.InvalidArgument or oob == error.InvalidGlyphIndex);

    // Glyph 0 (.notdef) is always loadable: empty or non-empty, never a trap.
    const notdef = try face.loadRender(0, 16);
    try testing.expect(notdef.bitmap.len == 0 or
        notdef.bitmap.len == @as(usize, notdef.height) * notdef.stride());
}

test "invalid font data and face indices are rejected" {
    var lib = try Library.init();
    defer lib.deinit();

    try testing.expectError(error.InvalidFileFormat, Face.initMemory(&lib, &.{}, 0));

    const garbage = Face.initMemory(&lib, "not a font at all!!", 0);
    try testing.expect(garbage == error.InvalidFileFormat or
        garbage == error.UnknownFileFormat);

    const allocator = testing.allocator;
    const bytes = try readTestFont(allocator, "Inter-Regular.ttf");
    defer allocator.free(bytes);
    try testing.expectError(error.InvalidArgument, Face.initMemory(&lib, bytes, 42));
}

test "Rendered.rowSlice handles up-flow (negative pitch) bitmaps" {
    // Synthetic 2x1 gray bitmap, pitch -2: memory starts at the *bottom* row
    // (FreeType "up flow"), so the visual top row is the second chunk.
    // Each row uses 1 of its 2 stride bytes; bytes 1 and 3 are padding.
    const up_flow = Rendered{
        .width = 1,
        .height = 2,
        .left = 0,
        .top = 2,
        .advance_x = 64,
        .pixel_mode = FT_PIXEL_MODE_GRAY,
        .bitmap = &.{ 0x11, 0x00, 0x22, 0x00 },
        .pitch = -2,
    };
    try testing.expectEqual(@as(usize, 2), up_flow.stride());
    try testing.expectEqualSlices(u8, &.{0x22}, up_flow.rowSlice(0));
    try testing.expectEqualSlices(u8, &.{0x11}, up_flow.rowSlice(1));
    try testing.expectEqualSlices(u8, &.{}, up_flow.rowSlice(2));

    // Packed-row helper mirrors FreeType's preset sizes.
    try testing.expectEqual(@as(usize, 1), packedRowBytes(FT_PIXEL_MODE_MONO, 8));
    try testing.expectEqual(@as(usize, 2), packedRowBytes(FT_PIXEL_MODE_MONO, 9));
    try testing.expectEqual(@as(usize, 9), packedRowBytes(FT_PIXEL_MODE_GRAY, 9));
    try testing.expectEqual(@as(usize, 15), packedRowBytes(FT_PIXEL_MODE_LCD, 15));
    try testing.expectEqual(@as(usize, 12), packedRowBytes(FT_PIXEL_MODE_BGRA, 3));
    try testing.expectEqual(@as(usize, 0), packedRowBytes(0, 9));
}
