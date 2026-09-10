//! Runtime `dlopen` tables for the system font stack.
//!
//! Why tables, not linking: the repo hard constraint is system libs via
//! hand-written `extern` + runtime `dlopen`, never `@cImport` and never a
//! hard link. `src/text/bindings.zig` already declares the C ABI as Zig
//! types (no link needed for types); this file binds those signatures to
//! function pointers resolved with `dlsym` at runtime, mirroring the
//! `WaylandApi` / `X11Api` pattern in `src/platform/`.
//!
//! Each table has `load()` (all-or-nothing symbol resolution) and
//! `isAvailable()` (probe without keeping the library open). Owners
//! (`discovery`, `face`, `shaper`) keep their own `dl.Library` handle and
//! close it on `deinit`, so `zig build test` links only libc and still
//! passes on machines without the font stack (integration tests skip).

const dl = @import("../platform/dl.zig");
const tb = @import("../text/bindings.zig");

// ============================================================================
// FreeType
// ============================================================================

pub const freetype_lib_names: []const [*:0]const u8 = &.{ "libfreetype.so.6", "libfreetype.so" };

pub const FT_InitFn = *const fn (*tb.FT_Library) callconv(.c) tb.FT_Error;
pub const FT_DoneFn = *const fn (tb.FT_Library) callconv(.c) tb.FT_Error;
pub const FT_NewFaceFn = *const fn (tb.FT_Library, [*:0]const u8, tb.FT_Long, *tb.FT_Face) callconv(.c) tb.FT_Error;
pub const FT_DoneFaceFn = *const fn (tb.FT_Face) callconv(.c) tb.FT_Error;
pub const FT_SetPixelSizesFn = *const fn (tb.FT_Face, tb.FT_UInt, tb.FT_UInt) callconv(.c) tb.FT_Error;
pub const FT_GetCharIndexFn = *const fn (tb.FT_Face, tb.FT_ULong) callconv(.c) tb.FT_UInt;
pub const FT_LoadGlyphFn = *const fn (tb.FT_Face, tb.FT_UInt, tb.FT_Int32) callconv(.c) tb.FT_Error;
pub const FT_LoadCharFn = *const fn (tb.FT_Face, tb.FT_ULong, tb.FT_Int32) callconv(.c) tb.FT_Error;
pub const FT_RenderGlyphFn = *const fn (tb.FT_GlyphSlot, tb.FT_Render_Mode) callconv(.c) tb.FT_Error;
pub const FT_GetKerningFn = *const fn (tb.FT_Face, tb.FT_UInt, tb.FT_UInt, tb.FT_UInt, *tb.FT_Vector) callconv(.c) tb.FT_Error;

pub const FreeTypeApi = struct {
    init: FT_InitFn,
    done: FT_DoneFn,
    new_face: FT_NewFaceFn,
    done_face: FT_DoneFaceFn,
    set_pixel_sizes: FT_SetPixelSizesFn,
    get_char_index: FT_GetCharIndexFn,
    load_glyph: FT_LoadGlyphFn,
    load_char: FT_LoadCharFn,
    render_glyph: FT_RenderGlyphFn,
    get_kerning: FT_GetKerningFn,

    pub fn load(lib: dl.Library) ?FreeTypeApi {
        return .{
            .init = lib.lookup(FT_InitFn, "FT_Init_FreeType") orelse return null,
            .done = lib.lookup(FT_DoneFn, "FT_Done_FreeType") orelse return null,
            .new_face = lib.lookup(FT_NewFaceFn, "FT_New_Face") orelse return null,
            .done_face = lib.lookup(FT_DoneFaceFn, "FT_Done_Face") orelse return null,
            .set_pixel_sizes = lib.lookup(FT_SetPixelSizesFn, "FT_Set_Pixel_Sizes") orelse return null,
            .get_char_index = lib.lookup(FT_GetCharIndexFn, "FT_Get_Char_Index") orelse return null,
            .load_glyph = lib.lookup(FT_LoadGlyphFn, "FT_Load_Glyph") orelse return null,
            .load_char = lib.lookup(FT_LoadCharFn, "FT_Load_Char") orelse return null,
            .render_glyph = lib.lookup(FT_RenderGlyphFn, "FT_Render_Glyph") orelse return null,
            .get_kerning = lib.lookup(FT_GetKerningFn, "FT_Get_Kerning") orelse return null,
        };
    }

    pub fn isAvailable() bool {
        var lib = dl.Library.open(freetype_lib_names) orelse return false;
        defer lib.close();
        return load(lib) != null;
    }
};

// ============================================================================
// HarfBuzz
// ============================================================================

pub const harfbuzz_lib_names: []const [*:0]const u8 = &.{ "libharfbuzz.so.0", "libharfbuzz.so" };

pub const HbBufferCreateFn = *const fn () callconv(.c) ?*tb.hb_buffer_t;
pub const HbBufferDestroyFn = *const fn (*tb.hb_buffer_t) callconv(.c) void;
pub const HbBufferResetFn = *const fn (*tb.hb_buffer_t) callconv(.c) void;
pub const HbBufferSetDirectionFn = *const fn (*tb.hb_buffer_t, tb.hb_direction_t) callconv(.c) void;
pub const HbBufferAddUtf8Fn = *const fn (*tb.hb_buffer_t, [*]const u8, c_int, c_uint, c_int) callconv(.c) void;
pub const HbBufferGuessSegmentPropsFn = *const fn (*tb.hb_buffer_t) callconv(.c) void;
pub const HbBufferGetLengthFn = *const fn (*tb.hb_buffer_t) callconv(.c) c_uint;
pub const HbBufferGetGlyphInfosFn = *const fn (*tb.hb_buffer_t, *c_uint) callconv(.c) [*]tb.hb_glyph_info_t;
pub const HbBufferGetGlyphPositionsFn = *const fn (*tb.hb_buffer_t, *c_uint) callconv(.c) [*]tb.hb_glyph_position_t;
pub const HbShapeFn = *const fn (*tb.hb_font_t, *tb.hb_buffer_t, ?[*]const tb.hb_feature_t, c_uint) callconv(.c) void;
pub const HbFontDestroyFn = *const fn (*tb.hb_font_t) callconv(.c) void;
pub const HbFtFontCreateReferencedFn = *const fn (tb.FT_Face) callconv(.c) ?*tb.hb_font_t;
pub const HbFtFontChangedFn = *const fn (*tb.hb_font_t) callconv(.c) void;

pub const HarfBuzzApi = struct {
    buffer_create: HbBufferCreateFn,
    buffer_destroy: HbBufferDestroyFn,
    buffer_reset: HbBufferResetFn,
    buffer_set_direction: HbBufferSetDirectionFn,
    buffer_add_utf8: HbBufferAddUtf8Fn,
    buffer_guess_segment_properties: HbBufferGuessSegmentPropsFn,
    buffer_get_length: HbBufferGetLengthFn,
    buffer_get_glyph_infos: HbBufferGetGlyphInfosFn,
    buffer_get_glyph_positions: HbBufferGetGlyphPositionsFn,
    shape: HbShapeFn,
    font_destroy: HbFontDestroyFn,
    ft_font_create_referenced: HbFtFontCreateReferencedFn,
    ft_font_changed: HbFtFontChangedFn,

    pub fn load(lib: dl.Library) ?HarfBuzzApi {
        return .{
            .buffer_create = lib.lookup(HbBufferCreateFn, "hb_buffer_create") orelse return null,
            .buffer_destroy = lib.lookup(HbBufferDestroyFn, "hb_buffer_destroy") orelse return null,
            .buffer_reset = lib.lookup(HbBufferResetFn, "hb_buffer_reset") orelse return null,
            .buffer_set_direction = lib.lookup(HbBufferSetDirectionFn, "hb_buffer_set_direction") orelse return null,
            .buffer_add_utf8 = lib.lookup(HbBufferAddUtf8Fn, "hb_buffer_add_utf8") orelse return null,
            .buffer_guess_segment_properties = lib.lookup(HbBufferGuessSegmentPropsFn, "hb_buffer_guess_segment_properties") orelse return null,
            .buffer_get_length = lib.lookup(HbBufferGetLengthFn, "hb_buffer_get_length") orelse return null,
            .buffer_get_glyph_infos = lib.lookup(HbBufferGetGlyphInfosFn, "hb_buffer_get_glyph_infos") orelse return null,
            .buffer_get_glyph_positions = lib.lookup(HbBufferGetGlyphPositionsFn, "hb_buffer_get_glyph_positions") orelse return null,
            .shape = lib.lookup(HbShapeFn, "hb_shape") orelse return null,
            .font_destroy = lib.lookup(HbFontDestroyFn, "hb_font_destroy") orelse return null,
            .ft_font_create_referenced = lib.lookup(HbFtFontCreateReferencedFn, "hb_ft_font_create_referenced") orelse return null,
            .ft_font_changed = lib.lookup(HbFtFontChangedFn, "hb_ft_font_changed") orelse return null,
        };
    }

    pub fn isAvailable() bool {
        var lib = dl.Library.open(harfbuzz_lib_names) orelse return false;
        defer lib.close();
        return load(lib) != null;
    }
};

// ============================================================================
// Fontconfig
// ============================================================================

pub const fontconfig_lib_names: []const [*:0]const u8 = &.{ "libfontconfig.so.1", "libfontconfig.so" };

pub const FcInitFn = *const fn () callconv(.c) ?*tb.FcConfig;
pub const FcConfigDestroyFn = *const fn (*tb.FcConfig) callconv(.c) void;
pub const FcPatternCreateFn = *const fn () callconv(.c) ?*tb.FcPattern;
pub const FcPatternDestroyFn = *const fn (*tb.FcPattern) callconv(.c) void;
pub const FcPatternAddStringFn = *const fn (*tb.FcPattern, [*:0]const u8, [*:0]const u8) callconv(.c) tb.FcBool;
pub const FcPatternAddIntegerFn = *const fn (*tb.FcPattern, [*:0]const u8, c_int) callconv(.c) tb.FcBool;
pub const FcPatternAddBoolFn = *const fn (*tb.FcPattern, [*:0]const u8, tb.FcBool) callconv(.c) tb.FcBool;
pub const FcPatternGetStringFn = *const fn (*tb.FcPattern, [*:0]const u8, c_int, *?[*:0]const tb.FcChar8) callconv(.c) tb.FcResult;
pub const FcPatternGetIntegerFn = *const fn (*tb.FcPattern, [*:0]const u8, c_int, *c_int) callconv(.c) tb.FcResult;
pub const FcConfigSubstituteFn = *const fn (?*tb.FcConfig, *tb.FcPattern, tb.FcMatchKind) callconv(.c) tb.FcBool;
pub const FcDefaultSubstituteFn = *const fn (*tb.FcPattern) callconv(.c) void;
pub const FcFontMatchFn = *const fn (?*tb.FcConfig, *tb.FcPattern, *tb.FcResult) callconv(.c) ?*tb.FcPattern;

pub const FontconfigApi = struct {
    init_load_config_and_fonts: FcInitFn,
    config_destroy: FcConfigDestroyFn,
    pattern_create: FcPatternCreateFn,
    pattern_destroy: FcPatternDestroyFn,
    pattern_add_string: FcPatternAddStringFn,
    pattern_add_integer: FcPatternAddIntegerFn,
    pattern_add_bool: FcPatternAddBoolFn,
    pattern_get_string: FcPatternGetStringFn,
    pattern_get_integer: FcPatternGetIntegerFn,
    config_substitute: FcConfigSubstituteFn,
    default_substitute: FcDefaultSubstituteFn,
    font_match: FcFontMatchFn,

    pub fn load(lib: dl.Library) ?FontconfigApi {
        return .{
            .init_load_config_and_fonts = lib.lookup(FcInitFn, "FcInitLoadConfigAndFonts") orelse return null,
            .config_destroy = lib.lookup(FcConfigDestroyFn, "FcConfigDestroy") orelse return null,
            .pattern_create = lib.lookup(FcPatternCreateFn, "FcPatternCreate") orelse return null,
            .pattern_destroy = lib.lookup(FcPatternDestroyFn, "FcPatternDestroy") orelse return null,
            .pattern_add_string = lib.lookup(FcPatternAddStringFn, "FcPatternAddString") orelse return null,
            .pattern_add_integer = lib.lookup(FcPatternAddIntegerFn, "FcPatternAddInteger") orelse return null,
            .pattern_add_bool = lib.lookup(FcPatternAddBoolFn, "FcPatternAddBool") orelse return null,
            .pattern_get_string = lib.lookup(FcPatternGetStringFn, "FcPatternGetString") orelse return null,
            .pattern_get_integer = lib.lookup(FcPatternGetIntegerFn, "FcPatternGetInteger") orelse return null,
            .config_substitute = lib.lookup(FcConfigSubstituteFn, "FcConfigSubstitute") orelse return null,
            .default_substitute = lib.lookup(FcDefaultSubstituteFn, "FcDefaultSubstitute") orelse return null,
            .font_match = lib.lookup(FcFontMatchFn, "FcFontMatch") orelse return null,
        };
    }

    pub fn isAvailable() bool {
        var lib = dl.Library.open(fontconfig_lib_names) orelse return false;
        defer lib.close();
        return load(lib) != null;
    }
};

test "font tables probe without linking" {
    // Availability reflects the machine, but loading must be all-or-nothing
    // and must never require link-time libs (this test binary links libc).
    const std = @import("std");
    if (FreeTypeApi.isAvailable()) {
        var lib = dl.Library.open(freetype_lib_names).?;
        defer lib.close();
        try std.testing.expect(FreeTypeApi.load(lib) != null);
    }
    if (HarfBuzzApi.isAvailable()) {
        var lib = dl.Library.open(harfbuzz_lib_names).?;
        defer lib.close();
        try std.testing.expect(HarfBuzzApi.load(lib) != null);
    }
    if (FontconfigApi.isAvailable()) {
        var lib = dl.Library.open(fontconfig_lib_names).?;
        defer lib.close();
        try std.testing.expect(FontconfigApi.load(lib) != null);
    }
}
