//! Hand-written `extern` bindings for the vendored C image backends.
//!
//! Backends live in `third_party/` (compiled into the zui module):
//! - nanosvg (`nanosvg.h`, `nanosvgrast.h`): Zlib licensed,
//!   Copyright (c) 2013-14 Mikko Mononen. SVG parse + rasterize.
//! - stb_image (`stb_image.h`): public domain, Sean Barrett.
//!   JPEG/PNG/GIF/BMP/PSD/TGA/HDR/PIC/PNM decode.
//!
//! Only the entry points we use are declared; signatures mirror the
//! upstream headers (verified against the vendored copies).

const builtin = @import("builtin");

pub const NsvgImage = extern struct {
    width: f32,
    height: f32,
    // Opaque tail (shapes list etc.); never touched from Zig.
};

pub const NsvgRasterizer = opaque {};

pub const STBI_default: c_int = 0;

extern fn nsvgParse(input: [*:0]u8, units: [*:0]const u8, dpi: f32) ?*NsvgImage;
extern fn nsvgParseFromFile(filename: [*:0]const u8, units: [*:0]const u8, dpi: f32) ?*NsvgImage;
extern fn nsvgDelete(image: *NsvgImage) void;
extern fn nsvgCreateRasterizer() ?*NsvgRasterizer;
extern fn nsvgRasterize(r: *NsvgRasterizer, image: *NsvgImage, tx: f32, ty: f32, scale: f32, dst: [*]u8, w: c_int, h: c_int, stride: c_int) void;
extern fn nsvgDeleteRasterizer(r: *NsvgRasterizer) void;

extern fn stbi_load_from_memory(buffer: [*]const u8, len: c_int, x: *c_int, y: *c_int, channels_in_file: *c_int, desired_channels: c_int) ?[*]u8;
extern fn stbi_image_free(retval_from_stbi_load: ?*anyopaque) void;
extern fn stbi_failure_reason() [*:0]const u8;
extern fn stbi_info_from_memory(buffer: [*]const u8, len: c_int, x: *c_int, y: *c_int, comp: *c_int) c_int;

pub const api = struct {
    pub const parseSvg = nsvgParse;
    pub const parseSvgFile = nsvgParseFromFile;
    pub const deleteSvg = nsvgDelete;
    pub const createRasterizer = nsvgCreateRasterizer;
    pub const rasterizeSvg = nsvgRasterize;
    pub const deleteRasterizer = nsvgDeleteRasterizer;
    pub const stbiLoad = stbi_load_from_memory;
    pub const stbiFree = stbi_image_free;
    pub const stbiFailure = stbi_failure_reason;
    pub const stbiInfo = stbi_info_from_memory;
};

comptime {
    // The C TU is linked via build.zig; fail fast if it is missing.
    if (!builtin.link_libc) @compileError("images need libc (vendored C backends)");
}
