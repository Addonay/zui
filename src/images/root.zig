//! Decoded-image pipeline: sniff, raster decode (stb_image), SVG
//! rasterize (nanosvg), and the App-owned RGBA pool cache.
//!
//! Backends: vendored C in `third_party/` (Zlib/MIT + public domain, see
//! `third_party/images.c`). Cold paths allocate; frames reference pool
//! offsets and never allocate.

pub const c = @import("c.zig");
pub const raster = @import("raster.zig");
pub const svg = @import("svg.zig");
pub const cache = @import("cache.zig");

pub const Cache = cache.Cache;
pub const Handle = cache.Handle;
pub const Format = raster.Format;
pub const sniff = raster.sniff;

test {
    _ = @import("c.zig");
    _ = @import("raster.zig");
    _ = @import("svg.zig");
    _ = @import("cache.zig");
}
