//! UI-thread asset registry, owned by the App's decoded cache.
//! Request/complete/cancel are the future task-system boundary; requestPath
//! queues no worker yet. Use preloadPath/preloadBytes outside render for now.
//! Rendering only looks up metadata and validates ready pool references.
const std = @import("std");
const cache_mod = @import("cache.zig");
const raster = @import("raster.zig");
const svg = @import("svg.zig");
const limits = @import("../core/limits.zig");
const Color = @import("../core/color.zig").Color;
const log = std.log.scoped(.assets);

pub const Handle = struct { slot: u16, generation: u64 };
pub const Ticket = struct { handle: Handle, revision: u64 };
pub const State = enum { loading, ready, failed };
pub const Metadata = struct {
    state: State,
    w: f32 = 24,
    h: f32 = 24,
    failure: ?anyerror = null,
};
pub const Counters = struct {
    reads: u64 = 0,
    hashes: u64 = 0,
    decodes: u64 = 0,
    failures: u64 = 0,
    completions: u64 = 0,
    cancellations: u64 = 0,
};
pub const Budget = struct {
    source_bytes: usize = 16 * 1024 * 1024,
    retained_bytes: usize = 16 * 1024 * 1024,
    dimension: u32 = limits.MAX_IMAGE_DIMENSION,
    pixels: u64 = limits.MAX_IMAGE_PIXELS,
    count: usize = limits.MAX_CACHED_IMAGES,
};
const Entry = struct {
    generation: u64 = 0,
    revision: u64 = 1,
    path: ?[]u8 = null,
    bytes: ?[]u8 = null,
    metadata: Metadata = .{ .state = .loading },
    pixels: cache_mod.Handle = .invalid,
};

pub const Service = struct {
    allocator: std.mem.Allocator,
    cache: *cache_mod.Cache,
    budget: Budget = .{},
    entries: [limits.MAX_CACHED_IMAGES]Entry = @splat(.{}),
    next_generation: u64 = 1,
    retained_bytes: usize = 0,
    counters: Counters = .{},
    /// Changes on completion/cancellation/reload; owners should request layout
    /// and redraw when it changes. Future UI-thread completion will do this.
    version: u64 = 0,

    pub fn init(allocator: std.mem.Allocator, cache: *cache_mod.Cache) Service {
        return .{ .allocator = allocator, .cache = cache };
    }

    pub fn deinit(self: *Service) void {
        for (&self.entries) |*entry| self.freeEntry(entry);
    }

    fn freeEntry(self: *Service, entry: *Entry) void {
        if (entry.path) |p| self.allocator.free(p);
        if (entry.bytes) |b| {
            self.retained_bytes -= b.len;
            self.allocator.free(b);
        }
        entry.* = .{};
    }

    fn get(self: *Service, handle: Handle) ?*Entry {
        if (handle.slot >= self.entries.len or handle.generation == 0) return null;
        const e = &self.entries[handle.slot];
        return if (e.generation == handle.generation) e else null;
    }

    fn allocate(self: *Service) !Handle {
        for (self.entries[0..@min(self.budget.count, self.entries.len)], 0..) |*entry, i| {
            if (entry.generation != 0) continue;
            const generation = self.next_generation;
            self.next_generation += 1;
            entry.* = .{ .generation = generation };
            return .{ .slot = @intCast(i), .generation = generation };
        }
        return error.AssetTableFull;
    }

    /// Exact path identity, no filesystem access, content hashing or allocation.
    pub fn findPath(self: *Service, path: []const u8) ?Handle {
        for (&self.entries, 0..) |*entry, i| {
            if (entry.path) |p| if (std.mem.eql(u8, p, path))
                return .{ .slot = @intCast(i), .generation = entry.generation };
        }
        return null;
    }

    /// Embedded bytes are compared to bounded retained sources, never rehashed.
    /// Prefer a stable asset handle for large sources (constant-time lookup).
    pub fn findBytes(self: *Service, bytes: []const u8) ?Handle {
        for (&self.entries, 0..) |*entry, i| {
            if (entry.path != null) continue;
            if (entry.bytes) |b| if (std.mem.eql(u8, b, bytes))
                return .{ .slot = @intCast(i), .generation = entry.generation };
        }
        return null;
    }

    pub fn metadata(self: *Service, handle: Handle) ?Metadata {
        const entry = self.get(handle) orelse return null;
        var result = entry.metadata;
        if (result.state == .ready and self.cache.pixels(entry.pixels).len == 0) {
            result.state = .failed;
            result.failure = error.Evicted;
        }
        return result;
    }

    /// Ready pixels only. Never reloads, decodes, allocates or hashes.
    pub fn resolve(self: *Service, handle: Handle, frame: u64) ?cache_mod.Handle {
        const entry = self.get(handle) orelse return null;
        if (entry.metadata.state != .ready) return null;
        if (!self.cache.validate(entry.pixels, frame)) {
            self.fail(entry, error.Evicted);
            return null;
        }
        return entry.pixels;
    }

    /// A bounded pending request; does NOT spawn a worker in this release.
    pub fn requestPath(self: *Service, path: []const u8) !Ticket {
        if (path.len == 0 or path.len >= 4096 or std.mem.indexOfScalar(u8, path, 0) != null) return error.BadPath;
        if (self.findPath(path)) |handle| return .{ .handle = handle, .revision = self.get(handle).?.revision };
        const owned = try self.allocator.dupe(u8, path);
        errdefer self.allocator.free(owned);
        const handle = try self.allocate();
        self.get(handle).?.path = owned;
        return .{ .handle = handle, .revision = 1 };
    }

    fn pending(self: *Service, ticket: Ticket) ?*Entry {
        const e = self.get(ticket.handle) orelse return null;
        return if (e.revision == ticket.revision and e.metadata.state == .loading) e else null;
    }

    fn fail(self: *Service, entry: *Entry, err: anyerror) void {
        entry.metadata.state = .failed;
        entry.metadata.failure = err;
        self.counters.failures += 1;
        self.version += 1;
        log.warn("{s}: {s}; showing placeholder", .{ entry.path orelse "embedded image", @errorName(err) });
    }

    pub fn cancel(self: *Service, ticket: Ticket) bool {
        const entry = self.pending(ticket) orelse return false;
        entry.revision += 1;
        self.counters.cancellations += 1;
        self.fail(entry, error.Cancelled);
        return true;
    }

    /// Explicit invalidation policy: no automatic stat/watch or retry of failures.
    /// Stable handle survives reload; old completion tickets are rejected.
    pub fn reload(self: *Service, handle: Handle) !Ticket {
        const entry = self.get(handle) orelse return error.StaleAsset;
        entry.revision += 1;
        entry.metadata.state = .loading;
        entry.metadata.failure = null;
        self.version += 1;
        return .{ .handle = handle, .revision = entry.revision };
    }

    /// Explicit registry eviction, only between frames. Late tickets and retained
    /// handles cannot alias a reused slot. Decoded pool eviction is independent.
    pub fn release(self: *Service, handle: Handle) void {
        if (self.get(handle)) |entry| self.freeEntry(entry);
    }

    pub fn preloadPath(self: *Service, path: []const u8, frame: u64) !Handle {
        const ticket = try self.requestPath(path);
        const entry = self.get(ticket.handle).?;
        if (entry.metadata.state != .loading) return ticket.handle;
        self.counters.reads += 1;
        const bytes = readPath(self.allocator, path, self.budget.source_bytes) catch |err| {
            self.fail(entry, err);
            return ticket.handle;
        };
        defer self.allocator.free(bytes);
        _ = self.complete(ticket, bytes, frame);
        return ticket.handle;
    }

    pub fn preloadBytes(self: *Service, bytes: []const u8, frame: u64) !Handle {
        if (self.findBytes(bytes)) |handle| return handle;
        const handle = try self.allocate();
        _ = self.complete(.{ .handle = handle, .revision = 1 }, bytes, frame);
        return handle;
    }

    /// Report a worker-side read failure without retrying or accepting stale work.
    pub fn completeFailure(self: *Service, ticket: Ticket, err: anyerror) bool {
        const entry = self.pending(ticket) orelse return false;
        self.fail(entry, err);
        return true;
    }

    /// UI-thread completion boundary. Copies borrowed bytes; cancelled/stale
    /// tickets are ignored before allocation. Caller always owns its input.
    pub fn complete(self: *Service, ticket: Ticket, bytes: []const u8, frame: u64) bool {
        const entry = self.pending(ticket) orelse return false;
        self.load(entry, bytes, frame) catch |err| {
            self.fail(entry, err);
            return true;
        };
        self.counters.completions += 1;
        self.version += 1;
        return true;
    }

    fn load(self: *Service, entry: *Entry, bytes: []const u8, frame: u64) !void {
        if (bytes.len > self.budget.source_bytes) return error.SourceTooLarge;
        const old_len = if (entry.bytes) |b| b.len else 0;
        if (bytes.len > self.budget.retained_bytes -| (self.retained_bytes - old_len)) return error.SourceBudgetFull;
        const owned = try self.allocator.dupe(u8, bytes);
        if (entry.bytes) |b| self.allocator.free(b);
        entry.bytes = owned;
        self.retained_bytes = self.retained_bytes - old_len + owned.len;
        self.counters.hashes += 1;
        const hash = std.hash.Wyhash.hash(0, owned);
        if (self.cache.lookup(hash, frame)) |hit| {
            if (hit.w > self.budget.dimension or hit.h > self.budget.dimension or @as(u64, hit.w) * hit.h > self.budget.pixels) return error.TooLarge;
            entry.pixels = hit;
        } else {
            var w: u32 = 0;
            var h: u32 = 0;
            const is_svg = raster.sniff(owned) == .svg;
            if (is_svg) {
                const size = try svg.intrinsicSize(owned);
                if (!std.math.isFinite(size.w) or !std.math.isFinite(size.h) or size.w <= 0 or size.h <= 0 or
                    size.w > @as(f32, @floatFromInt(self.budget.dimension)) or size.h > @as(f32, @floatFromInt(self.budget.dimension))) return error.TooLarge;
                w = @intFromFloat(@ceil(size.w));
                h = @intFromFloat(@ceil(size.h));
            } else {
                const size = try raster.probe(owned);
                w = size.w;
                h = size.h;
            }
            if (w > self.budget.dimension or h > self.budget.dimension or @as(u64, w) * h > self.budget.pixels or
                @as(u64, w) * h * 4 > self.cache.pool.len) return error.TooLarge;
            self.counters.decodes += 1;
            const decoded = if (is_svg) try svg.render(self.allocator, owned, w, h, Color.white) else try raster.decode(self.allocator, owned);
            defer self.allocator.free(decoded.pixels);
            entry.pixels = try self.cache.place(hash, decoded.pixels, decoded.w, decoded.h, frame);
        }
        entry.metadata = .{ .state = .ready, .w = @floatFromInt(entry.pixels.w), .h = @floatFromInt(entry.pixels.h) };
    }
};

/// Portable std.Io file access, confined to synchronous preload. Exact-size
/// bounds are checked by readFileAlloc before unbounded source allocation.
fn readPath(allocator: std.mem.Allocator, path: []const u8, max: usize) ![]u8 {
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    return std.Io.Dir.cwd().readFileAlloc(threaded.io(), path, allocator, .limited(max));
}

test "request cancellation rejects late completion and release rejects stale handles" {
    const t = std.testing;
    const cache = try cache_mod.Cache.init(t.allocator);
    defer cache.deinit(t.allocator);
    const service = &cache.assets;
    const ticket = try service.requestPath("pending.png");
    try t.expectEqual(State.loading, service.metadata(ticket.handle).?.state);
    try t.expect(service.cancel(ticket));
    try t.expect(!service.complete(ticket, "bad", 1));
    try t.expectEqual(@as(u64, 0), service.counters.hashes);
    service.release(ticket.handle);
    const next = try service.requestPath("next.png");
    try t.expectEqual(ticket.handle.slot, next.handle.slot);
    try t.expect(service.metadata(ticket.handle) == null);
    try t.expect(!service.complete(ticket, "bad", 1));
}
