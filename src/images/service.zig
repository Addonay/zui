//! UI-thread asset registry, owned by the App's decoded cache.
//! requestPath() spawns a real worker-pool file read when a TaskRuntime is
//! bound (App wires it in ensureTasksWired); decode+place still runs in the
//! UI-thread completion through the existing complete()/completeFailure()
//! boundary, so the cache is never touched off-thread. Use
//! preloadPath/preloadBytes outside render for synchronous loads.
//! Rendering only looks up metadata and validates ready pool references.
const std = @import("std");
const cache_mod = @import("cache.zig");
const raster = @import("raster.zig");
const svg = @import("svg.zig");
const limits = @import("../core/limits.zig");
const tasks = @import("../app/tasks.zig");
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
    /// True once a worker read was spawned for the current loading
    /// revision; dedups repeat requestPath calls into one flight.
    worker_spawned: bool = false,
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
    /// Worker pool for async path reads. Null keeps the original
    /// synchronous-pending behavior (standalone use, existing tests, or a
    /// degraded App whose runtime box failed to allocate). App binds its
    /// heap-owned TaskRuntime at init.
    task_runtime: ?*tasks.TaskRuntime = null,
    /// Frame id stamped onto async completions for cache pinning. App sets
    /// this to the current step before draining task completions.
    completion_frame: u64 = 0,

    pub fn init(allocator: std.mem.Allocator, cache: *cache_mod.Cache) Service {
        return .{ .allocator = allocator, .cache = cache };
    }

    /// Bind (or rebind) the worker pool used by requestPath/reload.
    /// App binds its heap-owned runtime once at init; the address stays
    /// stable across App moves (see App.tasks).
    pub fn bindRuntime(self: *Service, rt: *tasks.TaskRuntime) void {
        self.task_runtime = rt;
    }

    /// True while the ticket still owns its entry's loading revision:
    /// the liveness probe for worker starts and completion dispatch.
    pub fn isPending(self: *Service, ticket: Ticket) bool {
        return self.pending(ticket) != null;
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

    /// Registry entry point. Without a bound runtime the ticket stays
    /// pending until preload/complete, exactly as before. With a runtime
    /// bound, a real worker job is spawned for the file read; decode+place
    /// runs later in the UI-thread completion. A full task queue fails the
    /// entry explicitly AND returns error.TaskQueueFull — never silent.
    pub fn requestPath(self: *Service, path: []const u8) !Ticket {
        const ticket = try self.requestPending(path);
        const rt = self.task_runtime orelse return ticket;
        const entry = self.get(ticket.handle) orelse return ticket;
        if (entry.metadata.state != .loading or entry.worker_spawned) return ticket;
        self.spawnRead(rt, ticket) catch |err| {
            if (err == error.TaskQueueFull) {
                if (self.pending(ticket)) |e| self.fail(e, error.TaskQueueFull);
                return error.TaskQueueFull;
            }
            return err;
        };
        self.get(ticket.handle).?.worker_spawned = true;
        return ticket;
    }

    /// Synchronous registry insert shared by requestPath and preloadPath.
    /// Never spawns: preloadPath stays fully synchronous.
    fn requestPending(self: *Service, path: []const u8) !Ticket {
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
    /// With a runtime bound, reload spawns a fresh worker read (same
    /// over-limit policy as requestPath).
    pub fn reload(self: *Service, handle: Handle) !Ticket {
        const entry = self.get(handle) orelse return error.StaleAsset;
        entry.revision += 1;
        entry.metadata.state = .loading;
        entry.metadata.failure = null;
        entry.worker_spawned = false;
        self.version += 1;
        const ticket = Ticket{ .handle = handle, .revision = entry.revision };
        const rt = self.task_runtime orelse return ticket;
        self.spawnRead(rt, ticket) catch |err| {
            if (err == error.TaskQueueFull) {
                if (self.pending(ticket)) |e| self.fail(e, error.TaskQueueFull);
                return error.TaskQueueFull;
            }
            return err;
        };
        self.get(handle).?.worker_spawned = true;
        return ticket;
    }

    /// Explicit registry eviction, only between frames. Late tickets and retained
    /// handles cannot alias a reused slot. Decoded pool eviction is independent.
    pub fn release(self: *Service, handle: Handle) void {
        if (self.get(handle)) |entry| self.freeEntry(entry);
    }

    pub fn preloadPath(self: *Service, path: []const u8, frame: u64) !Handle {
        const ticket = try self.requestPending(path);
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

    /// Worker-pool file read for one ticket. The worker touches only its
    /// own job box (path dupe + libc-allocated file bytes); the registry
    /// and cache are UI-thread-only. Cancellation composes through the
    /// ticket: checked at worker start, re-checked before completion
    /// dispatch, and re-checked inside complete() before decode.
    const ImageJob = struct {
        service: *Service,
        ticket: Ticket,
        path: []u8,
        max_bytes: usize,
        bytes: []u8 = &.{},
        failure: ?anyerror = null,
    };

    fn spawnRead(self: *Service, rt: *tasks.TaskRuntime, ticket: Ticket) !void {
        const entry = self.get(ticket.handle) orelse return;
        const src = entry.path orelse return;
        const box = try self.allocator.create(ImageJob);
        errdefer self.allocator.destroy(box);
        const owned = try self.allocator.dupe(u8, src);
        errdefer self.allocator.free(owned);
        box.* = .{
            .service = self,
            .ticket = ticket,
            .path = owned,
            .max_bytes = self.budget.source_bytes,
        };
        // spawnRaw owns `box` (and `owned` through it) only on success;
        // the errdefers above free both on submission failure.
        _ = try rt.spawnRaw(box, .{
            .run = imageJobRun,
            .complete = imageJobComplete,
            .destroy = imageJobDestroy,
            .alive = imageJobAlive,
        });
    }

    fn imageJobRun(raw: *anyopaque, token: tasks.Cancel) void {
        const job: *ImageJob = @ptrCast(@alignCast(raw));
        if (token.isCancelled()) return;
        // Ticket check at worker start: a cancel()/reload()/release() that
        // landed after submit skips the read. Benign race with a
        // concurrent UI-thread registry mutation — worst case a wasted
        // read; delivery re-checks on the UI thread, which is authoritative.
        if (!job.service.isPending(job.ticket)) return;
        job.bytes = readPath(std.heap.c_allocator, job.path, job.max_bytes) catch |err| {
            job.failure = err;
            return;
        };
    }

    fn imageJobComplete(raw: *anyopaque) void {
        const job: *ImageJob = @ptrCast(@alignCast(raw));
        const svc = job.service;
        // Ticket check before completion dispatch: cancelled/stale tickets
        // no-op here even when the worker already read the file.
        if (!svc.isPending(job.ticket)) return;
        svc.counters.reads += 1;
        if (job.failure) |err| {
            _ = svc.completeFailure(job.ticket, err);
        } else {
            // complete() re-checks the ticket before decode/alloc.
            _ = svc.complete(job.ticket, job.bytes, svc.completion_frame);
        }
    }

    fn imageJobAlive(raw: *anyopaque) bool {
        const job: *ImageJob = @ptrCast(@alignCast(raw));
        return job.service.isPending(job.ticket);
    }

    fn imageJobDestroy(raw: *anyopaque, alloc: std.mem.Allocator) void {
        const job: *ImageJob = @ptrCast(@alignCast(raw));
        // Worker-side bytes are libc-owned (read off-thread); the path dupe
        // and box are service-allocator-owned (UI thread both ends).
        if (job.bytes.len > 0) std.heap.c_allocator.free(job.bytes);
        alloc.free(job.path);
        alloc.destroy(job);
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
