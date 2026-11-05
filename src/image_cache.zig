//! Port of GPUI `elements/image_cache.rs`: the image caches an `img` loads through, and
//! `image_cache()`, which sets the cache for the images under an element.
//!
//! An `img` with a URL, file or asset name loads through the cache in scope. Without one it uses
//! the app's own `AssetCache`, which keeps decoded images for the life of the app and saves URLs to
//! disk. A cache in scope is what releases images: clearing it, removing an item, or releasing it
//! drops the image from every window's sprite atlas and frees it.
//!
//! Differences from GPUI:
//! - `ImageCacheProvider` is a duck-typed value, not a trait. `image_cache(x)` accepts an `Entity(T)`
//!   whose `T` has `load(self, Resource, *Window, *App) ?ImageCacheError!*RenderImage`, or a value or
//!   pointer whose type has `provide(self, *Window, *App) AnyImageCache`. `provide` runs each time
//!   the element is laid out, as in GPUI.
//! - `image_cache()` returns a `div`, so it can also be styled and given an id. GPUI's
//!   `ImageCacheElement` takes neither.
//! - `ImageCache::load` and `RetainAllImageCache::clear` take no `Window`. The atlas removal is done
//!   for all windows, so nothing needs the one being drawn.
//! - URLs in an `ImageCacheItem` are fetched on the worker and decoded there. They are not saved to
//!   disk, unlike the default cache, and they do not share its entries.
//! - `retain_all(id)` is not ported. Use `window.use_keyed_state` in a provider instead.

const std = @import("std");
const assets = @import("assets.zig");
const asset_cache = @import("asset_cache.zig");
const app_mod = @import("app.zig");
const window_mod = @import("window.zig");
const div_mod = @import("elements/div.zig");

const App = app_mod.App;
const Entity = app_mod.Entity;
const Window = window_mod.Window;
const Resource = assets.Resource;
const RenderImage = assets.RenderImage;
const ImageCacheError = assets.ImageCacheError;

/// The result of loading an image (GPUI `Option<Result<Arc<RenderImage>, ImageCacheError>>`, the
/// `Option` being the loading state).
pub const ImageResult = ImageCacheError!*RenderImage;

/// Loads one image (GPUI `ImageAssetLoader`). Decodes on the worker thread.
pub const ImageAssetLoader = struct {
    pub const Source = Resource;
    pub const Output = ImageResult;

    pub fn clone_source(source: Resource, allocator: std.mem.Allocator) error{OutOfMemory}!Resource {
        return switch (source) {
            .path => |p| .{ .path = try allocator.dupe(u8, p) },
            .uri => |u| .{ .uri = try allocator.dupe(u8, u) },
            .embedded => |e| .{ .embedded = try allocator.dupe(u8, e) },
        };
    }

    pub fn free_source(source: Resource, allocator: std.mem.Allocator) void {
        switch (source) {
            .path => |p| allocator.free(p),
            .uri => |u| allocator.free(u),
            .embedded => |e| allocator.free(e),
        }
    }

    pub fn load(source: Resource, cx: *asset_cache.LoadContext) ImageResult {
        return assets.load_detached(cx.allocator, cx.io, cx.asset_source, cx.http_client, source);
    }

    /// Main thread. The image leaves every window's atlas before it is freed.
    pub fn dispose(out: ImageResult, app: *App) void {
        const image = out catch return;
        app.drop_image(image);
        image.deinit();
    }
};

/// One image load a cache owns (GPUI `ImageCacheItem`). Release it to cancel the load and drop the image.
pub const ImageCacheItem = struct {
    entry: *asset_cache.CachedLoad(ImageAssetLoader),

    /// Starts loading `source` into a new item (GPUI `ImageCacheItem::new`).
    pub fn new(source: Resource, cx: *App) error{OutOfMemory}!ImageCacheItem {
        return .{ .entry = try asset_cache.CachedLoad(ImageAssetLoader).start(&cx.asset_loads, source) };
    }

    /// The result, if it has arrived (GPUI `get`).
    pub fn get(self: ImageCacheItem) ?ImageResult {
        return self.entry.get();
    }

    /// The result, or null while it loads; the window's current view is redrawn when it arrives (GPUI `use_image`).
    pub fn use_image(self: ImageCacheItem, window: *const Window) ?ImageResult {
        return self.entry.use_by(window.current_view());
    }

    /// Cancels the load if it is running, and drops the image if it arrived (GPUI dropping the item).
    pub fn release(self: ImageCacheItem, cx: *App) void {
        self.entry.release(cx);
    }
};

/// A type-erased image cache (GPUI `AnyImageCache`). Valid while the cache's entity lives.
pub const AnyImageCache = struct {
    ptr: *anyopaque,
    load_fn: *const fn (ptr: *anyopaque, resource: Resource, window: *Window, cx: *App) ?ImageResult,

    /// Wraps a cache entity: `T` needs `load(self, Resource, *Window, *App) ?ImageResult` (GPUI `From<Entity<I>>`).
    pub fn from(entity: anytype, cx: *App) AnyImageCache {
        const T = @typeInfo(@TypeOf(entity.as_mut(cx))).pointer.child;
        const S = struct {
            fn load(ptr: *anyopaque, resource: Resource, window: *Window, app: *App) ?ImageResult {
                const self: *T = @ptrCast(@alignCast(ptr));
                return self.load(resource, window, app);
            }
        };
        return .{ .ptr = entity.as_mut(cx), .load_fn = S.load };
    }

    /// The image for `resource`, or null while it loads (GPUI `load`).
    pub fn load(self: AnyImageCache, resource: Resource, window: *Window, cx: *App) ?ImageResult {
        return self.load_fn(self.ptr, resource, window, cx);
    }
};

/// Gives the cache for the images under an element (GPUI `ImageCacheProvider`), type-erased.
pub const ImageCacheProvider = struct {
    ptr: *anyopaque,
    provide_fn: *const fn (ptr: *anyopaque, window: *Window, cx: *App) AnyImageCache,

    /// See the top of this file for what `provider` may be. Values are copied into the frame arena.
    pub fn from(provider: anytype) ImageCacheProvider {
        const T = @TypeOf(provider);
        if (comptime is_entity(T)) {
            const stored = window_mod.frame_arena().create(T) catch @panic("out of memory");
            stored.* = provider;
            return .{ .ptr = stored, .provide_fn = struct {
                fn provide(p: *anyopaque, _: *Window, cx: *App) AnyImageCache {
                    const e: *const T = @ptrCast(@alignCast(p));
                    return AnyImageCache.from(e.*, cx);
                }
            }.provide };
        }
        if (comptime @typeInfo(T) == .pointer) return erase(@typeInfo(T).pointer.child, provider);
        const stored = window_mod.frame_arena().create(T) catch @panic("out of memory");
        stored.* = provider;
        return erase(T, stored);
    }

    fn erase(comptime P: type, pointer: *P) ImageCacheProvider {
        return .{ .ptr = pointer, .provide_fn = struct {
            fn provide(p: *anyopaque, w: *Window, cx: *App) AnyImageCache {
                const self: *P = @ptrCast(@alignCast(p));
                return self.provide(w, cx);
            }
        }.provide };
    }

    /// The cache to use now, for an element laid out in `window` (GPUI `provide`).
    pub fn provide(self: ImageCacheProvider, window: *Window, cx: *App) AnyImageCache {
        return self.provide_fn(self.ptr, window, cx);
    }

    fn is_entity(comptime T: type) bool {
        return @typeInfo(T) == .@"struct" and @hasDecl(T, "as_mut") and @hasDecl(T, "entity_id");
    }
};

/// Sets the image cache for the images under this element (GPUI `image_cache`). Returns a div, so it
/// takes children and styles like any element.
pub fn image_cache(provider: anytype) *div_mod.Div {
    return div_mod.div().image_cache(provider);
}

/// Decoded images, each source loaded once and kept until cleared, removed or the cache is released
/// (GPUI `RetainAllImageCache`). Create it as an entity with `RetainAllImageCache.new`.
pub const RetainAllImageCache = struct {
    allocator: std.mem.Allocator,
    items: std.AutoHashMapUnmanaged(u64, ImageCacheItem) = .empty,

    /// Creates the cache as an entity (GPUI `RetainAllImageCache::new`). Its images are released with it.
    pub fn new(cx: *App) Entity(RetainAllImageCache) {
        return cx.new(RetainAllImageCache{ .allocator = cx.allocator });
    }

    /// Called when the entity is released: releases every item (GPUI `observe_release`).
    pub fn deinit(self: *RetainAllImageCache, app: *App) void {
        self.clear(app);
        self.items.deinit(self.allocator);
    }

    /// The image for `resource`, or null while it loads (GPUI `load`). The window's current view is
    /// redrawn when it arrives.
    pub fn load(self: *RetainAllImageCache, resource: Resource, window: *Window, cx: *App) ?ImageResult {
        const key = asset_cache.hash(resource);
        if (self.items.get(key) == null) {
            const item = ImageCacheItem.new(resource, cx) catch return error.OutOfMemory;
            self.items.put(self.allocator, key, item) catch {
                item.release(cx);
                return error.OutOfMemory;
            };
        }
        return self.items.get(key).?.use_image(window);
    }

    /// Releases every image (GPUI `clear`).
    pub fn clear(self: *RetainAllImageCache, cx: *App) void {
        var it = self.items.valueIterator();
        while (it.next()) |item| item.release(cx);
        self.items.clearRetainingCapacity();
    }

    /// Releases the image for `resource` (GPUI `remove`).
    pub fn remove(self: *RetainAllImageCache, resource: Resource, cx: *App) void {
        if (self.items.fetchRemove(asset_cache.hash(resource))) |kv| kv.value.release(cx);
    }

    pub fn len(self: *const RetainAllImageCache) usize {
        return self.items.count();
    }

    pub fn is_empty(self: *const RetainAllImageCache) bool {
        return self.items.count() == 0;
    }
};

test {
    std.testing.refAllDecls(@This());
}
