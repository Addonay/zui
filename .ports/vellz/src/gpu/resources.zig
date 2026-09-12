//! Port of `vello_gpu/src/resources.rs` (Apache-2.0 OR MIT).
//!
//! Persistent renderer resources shared across frames: the image atlas cache
//! (`common.image_cache.ImageCache`), the renderer-agnostic glyph preparation
//! caches, and the lazily created glyph atlas (the `glifo` glyph cache plus a
//! page-sized GPU `Scene` that replays recorded glyph commands into an atlas
//! texture).
//!
//! # Port adaptations (deliberate divergences)
//!
//! - Upstream's `Resources::before_render`/`after_render` take backend
//!   closures for `render_to_atlas`/`write_to_atlas`/`clear_atlas_region`.
//!   Zig has no closures, so this module stays CPU-safe and owns only the
//!   data; the wgpu-backed frame hooks live in `backend/renderer.zig`
//!   (`prepareResources`/`finishResources`), which call the same operations in
//!   the same order.
//! - Upstream normalizes the atlas configuration against the device limits in
//!   `Renderer::new_with`. The `ImageCache` here is constructed before the
//!   device exists, so `configureAtlas` applies the normalized size instead
//!   (and reports `error.UnsupportedCapability` when allocations already
//!   happened with a different size).
//! - `Text` support is always enabled (the `text` feature is this package).

const std = @import("std");
const common = @import("../common/root.zig");
const glifo = @import("../glifo/root.zig");
const scene_mod = @import("scene.zig");

const AtlasConfig = common.multi_atlas.AtlasConfig;
const ImageCache = common.image_cache.ImageCache;
const ImageId = common.paint.ImageId;
const Pixmap = common.pixmap.Pixmap;

/// Atlas configuration used when the caller does not provide one (upstream
/// `MemorySettings` defaults, normalized against the device limits later).
pub const DEFAULT_ATLAS_SIZE: u16 = 4096;

/// Type-erased image upload callback.
///
/// `glifo`'s uncached bitmap path hands the renderer a `Pixmap` image source,
/// which upstream `vello_gpu` panics on. The GPU port uploads it into the
/// image atlas instead; this erased callback keeps `resources.zig` CPU-safe
/// (it must not import `backend/renderer.zig`, which pulls in `wgpu`).
pub const GlyphUploader = struct {
    /// Backend renderer instance.
    context: *anyopaque,
    /// Upload `pixmap` and return its image-atlas id.
    upload_fn: *const fn (context: *anyopaque, pixmap: *const Pixmap) anyerror!ImageId,

    /// Upload `pixmap` into the atlas.
    pub fn upload(self: GlyphUploader, pixmap: *const Pixmap) anyerror!ImageId {
        return self.upload_fn(self.context, pixmap);
    }
};

/// Errors from resource setup.
pub const Error = std.mem.Allocator.Error || common.multi_atlas.AtlasError || error{
    /// The atlas configuration cannot be changed after allocations happened.
    UnsupportedCapability,
};

/// Glyph atlas state: the `glifo` glyph cache plus the page-sized `Scene`
/// that replays recorded outline/COLR commands (upstream
/// `text::GlyphAtlasResources`).
pub const GlyphAtlasResources = struct {
    /// The glyph cache (keys, slots, pending commands/clear rects).
    glyph_atlas: glifo.GlyphAtlas,
    /// Page-sized scene that draws rasterized outlines and COLR graphs into
    /// an atlas texture.
    glyph_renderer: scene_mod.Scene,
    /// Width of each atlas page in pixels.
    page_width: u16,
    /// Height of each atlas page in pixels.
    page_height: u16,

    /// Create glyph atlas state with the given page size and eviction
    /// configuration.
    pub fn init(
        allocator: std.mem.Allocator,
        page_width: u16,
        page_height: u16,
        eviction_config: glifo.GlyphCacheConfig,
    ) std.mem.Allocator.Error!GlyphAtlasResources {
        var glyph_renderer = try scene_mod.Scene.init(allocator, page_width, page_height);
        errdefer glyph_renderer.deinit();
        return .{
            .glyph_atlas = glifo.GlyphAtlas.initWithConfig(eviction_config),
            .glyph_renderer = glyph_renderer,
            .page_width = page_width,
            .page_height = page_height,
        };
    }

    /// Release the page scene and the glyph cache.
    pub fn deinit(self: *GlyphAtlasResources, allocator: std.mem.Allocator) void {
        self.glyph_renderer.deinit();
        self.glyph_atlas.deinit(allocator);
        self.* = undefined;
    }

    /// Advance the cache clock and evict unused entries.
    pub fn maintain(
        self: *GlyphAtlasResources,
        allocator: std.mem.Allocator,
        image_cache: *ImageCache,
    ) Error!void {
        try self.glyph_atlas.maintain(allocator, image_cache);
    }
};

/// Persistent resources required by the GPU renderer (upstream
/// `Resources::new`).
///
/// A set of resources must only be used with the renderer instance associated
/// with it.
pub const Resources = struct {
    /// Allocator used by every owned buffer and cache.
    allocator: std.mem.Allocator,
    /// Image atlas cache resolving `ImageSource.opaque_id` paints and backing
    /// the glyph atlas pages.
    image_cache: ImageCache,
    /// Renderer-agnostic glyph caches (outline paths and skip-ink spans).
    glyph_prep_cache: glifo.GlyphPrepCache = .{},
    /// Lazily initialized glyph atlas resources (upstream
    /// `glyph_resources`).
    glyph_resources: ?GlyphAtlasResources = null,
    /// Backend uploader for `Pixmap` image sources (uncached bitmap glyphs).
    /// Set by `Renderer::configureResources`; null keeps the pixmap source,
    /// which then fails loudly in the paint encoder.
    glyph_uploader: ?GlyphUploader = null,

    /// Create resources with the default atlas configuration.
    pub fn init(allocator: std.mem.Allocator) Error!Resources {
        return initWithConfig(allocator, .{});
    }

    /// Create resources with a custom image atlas configuration.
    pub fn initWithConfig(allocator: std.mem.Allocator, config: AtlasConfig) Error!Resources {
        return .{
            .allocator = allocator,
            .image_cache = try ImageCache.initWithConfig(allocator, config),
        };
    }

    /// Release every owned cache and buffer.
    pub fn deinit(self: *Resources) void {
        if (self.glyph_resources) |*glyph_resources| glyph_resources.deinit(self.allocator);
        self.glyph_resources = null;
        self.glyph_prep_cache.deinit(self.allocator);
        self.image_cache.deinit(self.allocator);
        self.* = undefined;
    }

    /// Clamp the atlas size to the renderer's resource texture dimension
    /// (upstream `MemorySettings::normalize`). Must be called before any image
    /// or glyph allocation; a mismatched size afterwards is a typed error.
    pub fn configureAtlas(self: *Resources, resource_dim: u16) Error!void {
        const config = &self.image_cache.atlas_manager.config;
        if (config.atlas_size[0] == 0 or config.atlas_size[1] == 0) {
            return error.UnsupportedCapability;
        }
        if (config.atlas_size[0] == resource_dim and config.atlas_size[1] == resource_dim) {
            return;
        }
        if (self.image_cache.atlasCount() != 0 or self.glyph_resources != null) {
            std.debug.print(
                "vellz-gpu: image atlas is {d}x{d}, renderer resource dimension is {d}\n",
                .{ config.atlas_size[0], config.atlas_size[1], resource_dim },
            );
            return error.UnsupportedCapability;
        }
        config.atlas_size = .{ resource_dim, resource_dim };
    }

    /// Lazily create the glyph atlas resources at the image atlas page size
    /// (upstream `Resources::ensure_glyph_resources`).
    pub fn ensureGlyphResources(self: *Resources) Error!void {
        if (self.glyph_resources != null) return;
        const size = self.image_cache.atlas_manager.config.atlas_size;
        self.glyph_resources = try GlyphAtlasResources.init(
            self.allocator,
            size[0],
            size[1],
            .{},
        );
    }

    /// The image atlas configuration.
    pub fn atlasConfig(self: *const Resources) AtlasConfig {
        return self.image_cache.atlas_manager.config;
    }

    /// The number of allocated atlas pages.
    pub fn atlasCount(self: *const Resources) u32 {
        return @intCast(self.image_cache.atlasCount());
    }

    /// Advance glyph caches; called once per rendered frame
    /// (upstream `Resources::after_render` prologue).
    pub fn maintain(self: *Resources) Error!void {
        self.glyph_prep_cache.maintain(self.allocator);
        if (self.glyph_resources) |*glyph_resources| {
            try glyph_resources.maintain(self.allocator, &self.image_cache);
        }
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "resources default config and lazy glyph resources" {
    const allocator = testing.allocator;
    var resources = try Resources.init(allocator);
    defer resources.deinit();

    try testing.expect(resources.glyph_resources == null);
    try testing.expectEqual(@as(u32, 0), resources.atlasCount());

    try resources.configureAtlas(1024);
    try testing.expectEqual([2]u16{ 1024, 1024 }, resources.atlasConfig().atlas_size);

    try resources.ensureGlyphResources();
    try testing.expect(resources.glyph_resources != null);
    const glyph_resources = &resources.glyph_resources.?;
    try testing.expectEqual(@as(u16, 1024), glyph_resources.page_width);
    try testing.expectEqual(@as(u16, 1024), glyph_resources.page_height);
    try testing.expectEqual(@as(u16, 1024), glyph_resources.glyph_renderer.width);

    // A second call reuses the existing resources.
    const renderer_ptr = &glyph_resources.glyph_renderer;
    try resources.ensureGlyphResources();
    try testing.expect(renderer_ptr == &resources.glyph_resources.?.glyph_renderer);
}

test "configure atlas is rejected after allocations" {
    const allocator = testing.allocator;
    var resources = try Resources.initWithConfig(allocator, .{ .atlas_size = .{ 64, 64 } });
    defer resources.deinit();

    const id = try resources.image_cache.allocate(allocator, 8, 8, 0);
    try testing.expectEqual(@as(u32, 0), id.asU32());

    try testing.expectError(error.UnsupportedCapability, resources.configureAtlas(128));
    // The unchanged size is accepted.
    try resources.configureAtlas(64);
    try testing.expectEqual([2]u16{ 64, 64 }, resources.atlasConfig().atlas_size);
}

test "empty atlas size is rejected at construction" {
    const allocator = testing.allocator;
    try testing.expectError(
        error.InvalidOptions,
        Resources.initWithConfig(allocator, .{ .atlas_size = .{ 0, 0 } }),
    );
}
