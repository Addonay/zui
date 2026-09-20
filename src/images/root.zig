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

pub const service = @import("service.zig");
pub const asset_cache = @import("asset_cache.zig");
pub const GenericAssetCache = asset_cache.AssetCache;
pub const SourceKey = asset_cache.SourceKey;
pub const AssetState = asset_cache.State;
pub const AssetFailure = asset_cache.Failure;
pub const Service = service.Service;
pub const AssetHandle = service.Handle;
pub const Cache = cache.Cache;
pub const Handle = cache.Handle;
pub const Format = raster.Format;
pub const sniff = raster.sniff;

test {
    _ = @import("c.zig");
    _ = @import("raster.zig");
    _ = @import("svg.zig");
    _ = @import("cache.zig");
    _ = @import("service_test.zig");
    _ = @import("asset_cache_image_test.zig");
}
