//! Vello CPU glyph rendering backend.
//!
//! Port of `vello_cpu/src/text.rs`. Provides `GlyphAtlasResources` (atlas
//! backed by per-page `Pixmap`s) and the `GlyphRunBackend` implementation for
//! `RenderContext` that rasterizes glyphs into CPU-accessible pixel buffers.
//!
//! The key difference from a GPU backend is that atlas pages are owned as
//! shared `Pixmap`s here, so the CPU renderer reads pixels directly without an
//! upload step. Page pixmaps are registered in the image registry before
//! rasterization (`beforeRender`) and unregistered afterwards
//! (`afterRender`), exactly like upstream's frame protocol.
//!
//! Port adaptations (see `.ports/vellz/docs/glifo-m3-plan.md` §3):
//! - Explicit allocators: the frame hooks and resource lifecycle take the
//!   allocator; upstream's `Vec::push`/`Arc::new` abort on failure.
//! - `Arc::get_mut(..).expect(..)` becomes a `refCount() == 1` assertion,
//!   because this port's `Shared(T)` has no fallible mutable accessor.
//! - Bitmap glyph upload queuing is omitted until bitmap glyphs land.

const std = @import("std");
const cpu_render = @import("render.zig");
const glifo = @import("../glifo/root.zig");
const common_pixmap = @import("../common/pixmap.zig");
const paint_mod = @import("../common/paint.zig");
const shared_mod = @import("../common/shared.zig");
const peniko = @import("../peniko/root.zig");
const kurbo = @import("../kurbo/root.zig");
const simd = @import("../simd/root.zig");

const RenderContext = cpu_render.RenderContext;
const Resources = cpu_render.Resources;
const RenderMode = cpu_render.RenderMode;
const RasterizerSettings = cpu_render.RasterizerSettings;
const Pixmap = common_pixmap.Pixmap;
const Shared = shared_mod.Shared;

/// Default atlas page size in pixels (upstream
/// `DEFAULT_GLYPH_ATLAS_SIZE`).
pub const DEFAULT_GLYPH_ATLAS_SIZE: u16 = 4096;

/// Glyph atlas state owned by `Resources`: the cache, the image allocator, a
/// page-sized render context used to replay recorded atlas commands, and one
/// pixmap per atlas page.
pub const GlyphAtlasResources = struct {
    /// The glyph cache (keys, slots, pending commands/clear rects).
    glyph_atlas: glifo.GlyphAtlas,
    /// The image allocator backing atlas pages.
    image_cache: glifo.ImageCache,
    /// Page-sized render context that draws outline commands into a page.
    ///
    /// Always single-threaded (`num_threads: 0`), matching upstream; the page
    /// renderer is reset between pages.
    glyph_renderer: RenderContext,
    /// One pixmap per atlas page, grown on demand.
    ///
    /// Shared because the image registry holds a clone while rasterizing;
    /// during sync the page is uniquely owned (asserted via `refCount`).
    pixmaps: std.ArrayListUnmanaged(Shared(Pixmap)) = .empty,
    /// Width of each atlas page in pixels.
    page_width: u16,
    /// Height of each atlas page in pixels.
    page_height: u16,

    /// Create glyph atlas state with the given page size, SIMD level and
    /// eviction configuration.
    pub fn init(
        allocator: std.mem.Allocator,
        page_width: u16,
        page_height: u16,
        level: simd.Level,
        eviction_config: glifo.GlyphCacheConfig,
    ) !GlyphAtlasResources {
        var image_cache = try glifo.ImageCache.initWithConfig(allocator, .{});
        errdefer image_cache.deinit(allocator);

        var glyph_renderer = try RenderContext.init(
            allocator,
            page_width,
            page_height,
            .{ .level = level, .num_threads = 0 },
        );
        errdefer glyph_renderer.deinit(allocator);

        return .{
            .glyph_atlas = glifo.GlyphAtlas.initWithConfig(eviction_config),
            .image_cache = image_cache,
            .glyph_renderer = glyph_renderer,
            .page_width = page_width,
            .page_height = page_height,
        };
    }

    /// Release pages, the page renderer, the image cache and the atlas cache.
    pub fn deinit(self: *GlyphAtlasResources, allocator: std.mem.Allocator) void {
        for (self.pixmaps.items) |pixmap| pixmap.release(allocator);
        self.pixmaps.deinit(allocator);
        self.glyph_renderer.deinit(allocator);
        self.image_cache.deinit(allocator);
        self.glyph_atlas.deinit(allocator);
        self.* = undefined;
    }

    /// Advance the cache clock and evict unused entries.
    pub fn maintain(self: *GlyphAtlasResources, allocator: std.mem.Allocator) !void {
        try self.glyph_atlas.maintain(allocator, &self.image_cache);
    }
};

/// Ensure a pixmap exists for the given page, creating it if needed.
fn ensurePage(
    allocator: std.mem.Allocator,
    glyph_resources: *GlyphAtlasResources,
    page_index: usize,
) std.mem.Allocator.Error!void {
    while (glyph_resources.pixmaps.items.len <= page_index) {
        var pixmap = try Pixmap.init(
            allocator,
            glyph_resources.page_width,
            glyph_resources.page_height,
        );
        errdefer pixmap.deinit(allocator);
        const handle = try Shared(Pixmap).create(allocator, pixmap);
        glyph_resources.pixmaps.append(allocator, handle) catch |err| {
            handle.release(allocator);
            return err;
        };
    }
}

/// Register (or replace) the atlas pages in the image registry.
fn registerAtlasPages(
    resources: *Resources,
    allocator: std.mem.Allocator,
    glyph_resources: *GlyphAtlasResources,
) std.mem.Allocator.Error!void {
    for (glyph_resources.pixmaps.items, 0..) |pixmap, page_index| {
        try resources.image_registry.registerAtlasPage(
            allocator,
            @intCast(page_index),
            pixmap.clone(),
        );
    }
}

/// Lazily create the glyph atlas resources (upstream
/// `Resources::ensure_glyph_resources`).
pub fn ensureGlyphResources(
    resources: *Resources,
    allocator: std.mem.Allocator,
    level: simd.Level,
) !void {
    return ensureGlyphResourcesWithSize(
        resources,
        allocator,
        DEFAULT_GLYPH_ATLAS_SIZE,
        DEFAULT_GLYPH_ATLAS_SIZE,
        level,
    );
}

/// Same as `ensureGlyphResources` with an explicit page size; tests use a
/// small page so the unit suite does not allocate 4096x4096 buffers.
pub fn ensureGlyphResourcesWithSize(
    resources: *Resources,
    allocator: std.mem.Allocator,
    page_width: u16,
    page_height: u16,
    level: simd.Level,
) !void {
    if (resources.glyph_resources == null) {
        resources.glyph_resources = try GlyphAtlasResources.init(
            allocator,
            page_width,
            page_height,
            level,
            .{},
        );
    }
}

/// Sync pending atlas work and register the pages: the upstream
/// `Resources::prepare_glyph_cache` + `sync_glyph_cache` pair.
pub fn prepareGlyphCache(
    resources: *Resources,
    allocator: std.mem.Allocator,
    render_mode: RenderMode,
) !void {
    if (resources.glyph_resources == null) return;
    try syncGlyphCache(resources, allocator, render_mode);
}

/// Frame-start hook: drain pending atlas commands into the page pixmaps and
/// register every page in the image registry.
///
/// Called before the target is cleared, exactly like upstream
/// `resources.before_render(render_mode)`.
pub fn beforeRender(
    resources: *Resources,
    allocator: std.mem.Allocator,
    render_mode: RenderMode,
) !void {
    try prepareGlyphCache(resources, allocator, render_mode);
}

/// Rasterize pending outline/COLR glyphs into their atlas pages, then register
/// the pages for image sampling. Bitmap upload draining is deferred with
/// bitmap support.
fn syncGlyphCache(
    resources: *Resources,
    allocator: std.mem.Allocator,
    render_mode: RenderMode,
) !void {
    const glyph_resources = &(resources.glyph_resources orelse return);

    const Replay = struct {
        glyph_resources: *GlyphAtlasResources,
        allocator: std.mem.Allocator,
        render_mode: RenderMode,

        pub fn replay(self: @This(), recorder: *glifo.AtlasCommandRecorder) anyerror!void {
            const page_index: usize = recorder.page_index;
            try ensurePage(self.allocator, self.glyph_resources, page_index);
            const page = &self.glyph_resources.pixmaps.items[page_index];
            // Upstream `Arc::get_mut`; the page is uniquely owned during sync.
            std.debug.assert(page.refCount() == 1);

            const glyph_renderer = &self.glyph_resources.glyph_renderer;
            glyph_renderer.reset();
            try glifo.renderer.replayAtlasCommands(self.allocator, recorder, glyph_renderer);
            try glyph_renderer.flush();

            // Fresh resources: the page renderer must not recursively touch the
            // outer glyph caches (upstream passes `&mut Self::default()`).
            var page_resources = Resources.init();
            defer page_resources.deinit(self.allocator);
            try glyph_renderer.renderWith(page.get(), &page_resources, .{
                .render_mode = self.render_mode,
                .target_init = .src_over,
                .pixel_format = .rgba8,
                .offset = .{ .x = 0, .y = 0 },
            });
        }
    };

    const replay = Replay{
        .glyph_resources = glyph_resources,
        .allocator = allocator,
        .render_mode = render_mode,
    };
    try glyph_resources.glyph_atlas.replayPendingAtlasCommands(allocator, replay);
    try registerAtlasPages(resources, allocator, glyph_resources);
}

/// Frame-end hook: maintain the prep caches, evict unused glyphs, unregister
/// the atlas pages and clear evicted regions.
///
/// Called after rasterization, exactly like upstream
/// `resources.after_render()`.
pub fn afterRender(resources: *Resources, allocator: std.mem.Allocator) !void {
    resources.glyph_prep_cache.maintain(allocator);

    const glyph_resources = &(resources.glyph_resources orelse return);
    try glyph_resources.maintain(allocator);

    const page_count: u32 = @intCast(glyph_resources.pixmaps.items.len);
    var page_index: u32 = 0;
    while (page_index < page_count) : (page_index += 1) {
        _ = resources.image_registry.destroyAtlasPage(allocator, page_index);
    }

    clearEvictedGlyphAtlasRegions(glyph_resources);
}

/// Zero out atlas regions queued by eviction.
fn clearEvictedGlyphAtlasRegions(glyph_resources: *GlyphAtlasResources) void {
    for (glyph_resources.glyph_atlas.pendingClearRects()) |clear| {
        const pixmap = glyph_resources.pixmaps.items[clear.page_index].get();
        clearPixmapRegion(pixmap, clear);
    }
    glyph_resources.glyph_atlas.clearPendingClearRects();
}

/// Zero out a rectangular region in the atlas pixmap.
///
/// Necessary because atlas rendering uses `SrcOver` blending, so stale pixels
/// from evicted glyphs would bleed through if not cleared.
fn clearPixmapRegion(pixmap: *Pixmap, rect: glifo.PendingClearRect) void {
    const stride: usize = pixmap.width;
    const clear_width: usize = rect.width;
    const clear_height: usize = rect.height;
    std.debug.assert(@as(usize, rect.x) + clear_width <= stride);
    std.debug.assert(@as(usize, rect.y) + clear_height <= pixmap.height);

    const data = pixmap.dataAsU8SliceMut();
    var y: usize = 0;
    while (y < clear_height) : (y += 1) {
        const row_start = ((@as(usize, rect.y) + y) * stride + @as(usize, rect.x)) * 4;
        @memset(data[row_start .. row_start + clear_width * 4], 0);
    }
}

/// A CPU glyph run backend: the `GlyphRunBackend` implementation for
/// `RenderContext` (upstream `CpuGlyphRunBackend`).
pub const CpuGlyphRunBackend = struct {
    /// The render context glyphs are drawn into.
    ctx: *RenderContext,
    /// Persistent resources owning the glyph caches.
    resources: *Resources,
    /// Whether atlas-backed glyph caching is enabled for this run.
    atlas_cache_enabled: bool,

    /// Enable or disable atlas-backed glyph caching for the glyph run.
    pub fn atlasCache(self: CpuGlyphRunBackend, enabled: bool) CpuGlyphRunBackend {
        var result = self;
        result.atlas_cache_enabled = enabled;
        return result;
    }

    /// Build a run renderer, lazily creating atlas resources when caching is
    /// enabled (upstream `CpuGlyphRunBackend::render_glyphs` prologue).
    fn buildRunRenderer(
        self: CpuGlyphRunBackend,
        allocator: std.mem.Allocator,
        run: glifo.GlyphRun,
        glyphs: anytype,
    ) !glifo.GlyphRunRenderer(@TypeOf(glyphs)) {
        var atlas_cacher: glifo.AtlasCacher = .disabled;
        if (self.atlas_cache_enabled) {
            try ensureGlyphResources(self.resources, allocator, self.ctx.renderSettings().level);
            const glyph_resources = &self.resources.glyph_resources.?;
            atlas_cacher = .{ .enabled = .{
                .glyph_atlas = &glyph_resources.glyph_atlas,
                .image_cache = &glyph_resources.image_cache,
            } };
        }

        return glifo.buildRenderer(
            run,
            glyphs,
            self.resources.glyph_prep_cache.asMut(),
            atlas_cacher,
        );
    }

    fn renderGlyphs(
        self: CpuGlyphRunBackend,
        allocator: std.mem.Allocator,
        run: glifo.GlyphRun,
        glyphs: anytype,
        style: glifo.glyph.Style,
    ) !void {
        var run_renderer = try self.buildRunRenderer(allocator, run, glyphs);

        switch (style) {
            .fill => try run_renderer.fillGlyphs(allocator, self.ctx),
            .stroke => {
                const adjustment = run_renderer.strokeAdjustment();
                const original_width = self.ctx.stroke().width;
                self.ctx.strokeMut().width *= adjustment;
                defer self.ctx.strokeMut().width = original_width;
                try run_renderer.strokeGlyphs(allocator, self.ctx);
            },
        }
    }

    /// Fill the glyph sequence using the backend's configured state.
    pub fn fillGlyphs(
        self: CpuGlyphRunBackend,
        allocator: std.mem.Allocator,
        run: glifo.GlyphRun,
        glyphs: anytype,
    ) !void {
        try self.renderGlyphs(allocator, run, glyphs, .fill);
    }

    /// Stroke the glyph sequence using the backend's configured state.
    pub fn strokeGlyphs(
        self: CpuGlyphRunBackend,
        allocator: std.mem.Allocator,
        run: glifo.GlyphRun,
        glyphs: anytype,
    ) !void {
        try self.renderGlyphs(allocator, run, glyphs, .stroke);
    }

    /// Render a decoration (underline/overline/strikethrough) with skip-ink
    /// behavior into the context, using the backend's run settings.
    pub fn renderDecoration(
        self: CpuGlyphRunBackend,
        allocator: std.mem.Allocator,
        run: glifo.GlyphRun,
        glyphs: anytype,
        x_range: [2]f32,
        baseline_y: f32,
        offset: f32,
        size: f32,
        buffer: f32,
    ) !void {
        var run_renderer = try self.buildRunRenderer(allocator, run, glyphs);
        try run_renderer.renderDecoration(
            allocator,
            x_range,
            baseline_y,
            offset,
            size,
            buffer,
            self.ctx,
        );
    }
};

/// A glyph run builder specialized to the CPU backend (upstream
/// `pub type GlyphRunBuilder<'a>`).
pub const GlyphRunBuilder = glifo.GlyphRunBuilder(CpuGlyphRunBackend);

// --------------------------------------------------------------------- tests

const testing = std.testing;

test "glyph atlas resources lazy init, page registration and teardown" {
    const allocator = testing.allocator;
    var resources = Resources.init();
    defer resources.deinit(allocator);
    try testing.expect(resources.glyph_resources == null);

    try ensureGlyphResourcesWithSize(&resources, allocator, 16, 16, .baseline);
    const glyph_resources = &resources.glyph_resources.?;
    try testing.expectEqual(@as(usize, 0), glyph_resources.pixmaps.items.len);

    try ensurePage(allocator, glyph_resources, 0);
    const page = glyph_resources.pixmaps.items[0];
    try testing.expectEqual(@as(usize, 1), page.refCount());
    try testing.expectEqual(@as(u16, 16), page.get().width);

    try registerAtlasPages(&resources, allocator, glyph_resources);
    const atlas_id = paint_mod.ImageId.new(cpu_render.ATLAS_IMAGE_ID_BASE);
    const resolved = resources.resolveImage(atlas_id);
    try testing.expect(resolved != null);
    // Page list + registry + the clone just resolved.
    try testing.expectEqual(@as(usize, 3), resolved.?.refCount());
    resolved.?.release(allocator);

    try testing.expect(resources.image_registry.destroyAtlasPage(allocator, 0));
    try testing.expect(resources.resolveImage(atlas_id) == null);
}

test "render context glyph run with the atlas cache end to end" {
    const allocator = testing.allocator;
    const fixture = @import("../glifo/test_fixture.zig");
    const font_data = glifo.FontData.init(try fixture.roboto(), 0);

    var ctx = try RenderContext.init(allocator, 32, 32, .{
        .level = .baseline,
        .num_threads = 0,
    });
    defer ctx.deinit(allocator);
    var resources = Resources.init();
    defer resources.deinit(allocator);
    // Small pages keep the unit test cheap; production uses 4096 (`ensureGlyphResources`).
    try ensureGlyphResourcesWithSize(&resources, allocator, 64, 64, .baseline);
    const glyph_resources = &resources.glyph_resources.?;

    ctx.setPaint(peniko.Color.BLACK);
    ctx.setTransform(kurbo.Affine.translate(kurbo.Vec2.new(0.0, 24.0)));
    const glyphs = [_]glifo.Glyph{.{ .id = 37, .x = 0.0, .y = 0.0 }};
    const builder = ctx.glyphRun(&resources, font_data)
        .fontSize(24.0)
        .hint(false)
        .atlasCache(true);
    try builder.fillGlyphs(allocator, glifo.iterate(&glyphs));

    // Encoding recorded one atlas entry and one page of deferred commands.
    try testing.expectEqual(@as(usize, 1), glyph_resources.glyph_atlas.len());
    try testing.expectEqual(
        @as(usize, 1),
        glyph_resources.glyph_atlas.pending_atlas_commands.items.len,
    );

    var pixmap = try Pixmap.init(allocator, 32, 32);
    defer pixmap.deinit(allocator);
    try ctx.renderWith(&pixmap, &resources, .{
        .render_mode = .optimize_quality,
        .target_init = .{ .clear = peniko.Color.TRANSPARENT },
        .pixel_format = .rgba8,
        .offset = .{ .x = 0, .y = 0 },
    });

    // The page was rasterized, registered for the frame, then unregistered by
    // `afterRender`.
    try testing.expectEqual(@as(usize, 1), glyph_resources.pixmaps.items.len);
    try testing.expectEqual(
        @as(usize, 0),
        glyph_resources.glyph_atlas.pending_atlas_commands.items[0].?.commands.items.len,
    );
    try testing.expect(
        resources.resolveImage(paint_mod.ImageId.new(cpu_render.ATLAS_IMAGE_ID_BASE)) == null,
    );

    // The run produced visible coverage.
    var nonzero: usize = 0;
    for (pixmap.dataAsU8Slice()) |byte| {
        if (byte != 0) nonzero += 1;
    }
    try testing.expect(nonzero > 0);
}

test "evicted region clearing zeroes atlas bytes" {
    const allocator = testing.allocator;
    var pixmap = try Pixmap.init(allocator, 4, 4);
    defer pixmap.deinit(allocator);
    for (pixmap.dataAsU8SliceMut()) |*byte| byte.* = 0xFF;

    clearPixmapRegion(&pixmap, .{
        .page_index = 0,
        .x = 1,
        .y = 1,
        .width = 2,
        .height = 2,
    });
    const data = pixmap.dataAsU8Slice();
    // Row 1, columns 1..3 are zero; the rest is untouched.
    try testing.expectEqual(@as(u8, 0), data[(1 * 4 + 1) * 4]);
    try testing.expectEqual(@as(u8, 0), data[(2 * 4 + 2) * 4 + 3]);
    try testing.expectEqual(@as(u8, 0xFF), data[0]);
    try testing.expectEqual(@as(u8, 0xFF), data[(3 * 4 + 3) * 4 + 3]);
}
