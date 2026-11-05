//! Port of GPUI `asset_cache.rs`: background asset loads, cached by asset type and source.
//!
//! An asset type `A` is a struct with:
//! - `pub const Source`: the key. Hashed by `hash` (slices by content). The entry keeps a copy.
//! - `pub const Output`: the cached result. Copied out by `use_asset` and `get_asset`.
//! - `pub fn load(source: A.Source, cx: *LoadContext) A.Output`: runs on a worker thread.
//!
//! and optionally:
//! - `clone_source(source, allocator)` and `free_source(source, allocator)`, for sources that own memory.
//!   Without `clone_source` the entry keeps the caller's bytes, so they must outlive the load.
//! - `dispose(output, app)`: runs on the main thread when a loaded result is dropped. Use it to free
//!   what `Output` owns.
//!
//! Differences from GPUI:
//! - GPUI's `load(source, cx: &mut App)` returns a future that the executor polls. Zig has neither,
//!   so `load` runs to completion on a worker thread with a `LoadContext`, and it cannot touch the App.
//!   The result goes back to the main thread, which notifies the views that asked for it.
//! - Sources and outputs are passed by value, not by reference. GPUI's `Output: Clone` is not needed:
//!   the cache hands out bit copies.
//! - Cancellation is cooperative. `remove_asset` abandons a running load at once: its result is
//!   disposed when it arrives. App shutdown waits for running loads, so a long load should check
//!   `LoadContext.is_cancelled` or sleep with `LoadContext.sleep`.
//! - `hash` is a deep hash built here, since `std.hash.autoHash` refuses slices inside structs.

const std = @import("std");
const Io = std.Io;
const executor_mod = @import("executor.zig");
const assets = @import("assets.zig");
const http_client_mod = @import("http_client.zig");
const app_mod = @import("app.zig");

const App = app_mod.App;
const EntityId = app_mod.EntityId;

/// What a load gets on its worker thread (GPUI passes `&mut App` and the executor instead).
pub const LoadContext = struct {
    allocator: std.mem.Allocator,
    io: Io,
    asset_source: assets.AssetSource,
    http_client: ?http_client_mod.HttpClient,
    cancel_flag: *const std.atomic.Value(bool),

    /// True once the app no longer wants the result (see the top of this file).
    pub fn is_cancelled(self: *const LoadContext) bool {
        return self.cancel_flag.load(.acquire);
    }

    /// Sleeps for `ns`, or stops early with `error.Canceled` once the load is abandoned.
    pub fn sleep(self: *const LoadContext, ns: u64) error{Canceled}!void {
        var left = ns;
        while (left > 0) {
            if (self.is_cancelled()) return error.Canceled;
            const step = @min(left, 10 * std.time.ns_per_ms);
            executor_mod.sleep_ns(step);
            left -= step;
        }
        if (self.is_cancelled()) return error.Canceled;
    }
};

/// Deep hash of a source: slices by content, structs and unions field by field (GPUI `hash`).
pub fn hash(data: anytype) u64 {
    var h = std.hash.Wyhash.init(0);
    hash_into(&h, data);
    return h.final();
}

fn hash_into(h: *std.hash.Wyhash, value: anytype) void {
    const T = @TypeOf(value);
    switch (@typeInfo(T)) {
        .pointer => |p| switch (p.size) {
            .slice => {
                const len: usize = value.len;
                h.update(std.mem.asBytes(&len));
                if (p.child == u8) {
                    h.update(value);
                } else for (value) |item| hash_into(h, item);
            },
            .one => hash_into(h, value.*),
            else => h.update(std.mem.asBytes(&value)),
        },
        .@"struct" => |s| inline for (s.field_names) |name| hash_into(h, @field(value, name)),
        .@"union" => {
            const tag: usize = @intFromEnum(std.meta.activeTag(value));
            h.update(std.mem.asBytes(&tag));
            switch (value) {
                inline else => |payload| hash_into(h, payload),
            }
        },
        .optional => {
            const present: u8 = @intFromBool(value != null);
            h.update(std.mem.asBytes(&present));
            if (value) |v| hash_into(h, v);
        },
        .array => for (value) |item| hash_into(h, item),
        else => h.update(std.mem.asBytes(&value)),
    }
}

/// The background loader and the table of entries an app owns (GPUI `loading_assets`).
/// Lives in `App`. Every entry is registered in `live` while it exists, so `deinit` can release them all.
pub const AssetLoads = struct {
    allocator: std.mem.Allocator,
    app: *App,
    foreground: *executor_mod.ForegroundExecutor,
    threaded: Io.Threaded,
    group: Io.Group = .init,
    /// Guards `finished`, and the fields of entries that workers and the main thread both touch.
    mutex: Io.Mutex = .init,
    /// Loads finished on a worker, waiting for the main thread. Each holds the worker's reference.
    finished: std.ArrayList(Finished) = .empty,
    /// Every entry that exists, by address.
    live: std.AutoHashMapUnmanaged(usize, Live) = .empty,
    /// The entries `use_asset` owns, by asset type and source hash.
    entries: std.AutoHashMapUnmanaged(Key, Live) = .empty,
    /// Set by `deinit`: settling then skips notifications.
    closed: bool = false,

    const Key = struct { asset: usize, hash: u64 };
    const Live = struct {
        ptr: *anyopaque,
        release: *const fn (ptr: *anyopaque, app: *App) void,
    };
    const Finished = struct {
        ptr: *anyopaque,
        settle: *const fn (ptr: *anyopaque, app: *App) void,
    };

    pub fn init(allocator: std.mem.Allocator, app: *App, foreground: *executor_mod.ForegroundExecutor) AssetLoads {
        return .{
            .allocator = allocator,
            .app = app,
            .foreground = foreground,
            .threaded = Io.Threaded.init(allocator, .{}),
        };
    }

    fn io(self: *AssetLoads) Io {
        return self.threaded.io();
    }

    /// Releases every entry and waits for running loads. Runs at app shutdown, after the windows are gone.
    pub fn deinit(self: *AssetLoads) void {
        const the_io = self.io();
        self.closed = true;
        // Release everything first: each running load sees its flag and the group wait ends sooner.
        var all: std.ArrayList(Live) = .empty;
        defer all.deinit(self.allocator);
        var live_it = self.live.valueIterator();
        while (live_it.next()) |l| all.append(self.allocator, l.*) catch @panic("out of memory");
        for (all.items) |l| l.release(l.ptr, self.app);
        self.group.cancel(the_io);
        var batch = self.take_finished();
        defer batch.deinit(self.allocator);
        for (batch.items) |f| f.settle(f.ptr, self.app);
        std.debug.assert(self.live.count() == 0);
        self.entries.deinit(self.allocator);
        self.live.deinit(self.allocator);
        self.finished.deinit(self.allocator);
        self.threaded.deinit();
    }

    fn take_finished(self: *AssetLoads) std.ArrayList(Finished) {
        const the_io = self.io();
        self.mutex.lockUncancelable(the_io);
        defer self.mutex.unlock(the_io);
        const batch = self.finished;
        self.finished = .empty;
        return batch;
    }

    /// Main thread, once per batch of finished loads.
    fn settle_all(self: *AssetLoads) void {
        if (self.closed) return;
        var batch = self.take_finished();
        defer batch.deinit(self.allocator);
        for (batch.items) |f| f.settle(f.ptr, self.app);
    }

    /// The entry for `source`, started if it is not cached yet (GPUI `asset_entry`).
    pub fn entry(self: *AssetLoads, comptime A: type, source: A.Source) *CachedLoad(A) {
        const Entry = CachedLoad(A);
        const key: Key = .{ .asset = @intFromPtr(app_mod.type_id(A)), .hash = hash(source) };
        if (self.entries.get(key)) |l| return @ptrCast(@alignCast(l.ptr));
        const e = Entry.start(self, source) catch @panic("out of memory");
        self.entries.put(self.allocator, key, .{ .ptr = e, .release = Entry.release_erased }) catch @panic("out of memory");
        return e;
    }

    /// Whether `source` is cached or loading.
    pub fn contains(self: *AssetLoads, comptime A: type, source: A.Source) bool {
        return self.entries.contains(.{ .asset = @intFromPtr(app_mod.type_id(A)), .hash = hash(source) });
    }

    /// Drops the cached entry for `source`; a running load is abandoned (GPUI `remove_asset`).
    pub fn remove(self: *AssetLoads, comptime A: type, source: A.Source) void {
        const key: Key = .{ .asset = @intFromPtr(app_mod.type_id(A)), .hash = hash(source) };
        if (self.entries.fetchRemove(key)) |kv| kv.value.release(kv.value.ptr, self.app);
    }
};

/// One background load and its result (GPUI `CachedLoad`).
///
/// The owner holds one reference, and a worker or the finished queue holds another while a load runs.
/// `release` drops the owner's reference. The entry is freed once no reference is left.
pub fn CachedLoad(comptime A: type) type {
    return struct {
        const Self = @This();

        loads: *AssetLoads,
        /// Guarded by `loads.mutex`. The owner's reference plus the worker's while it runs or is queued.
        refs: u32,
        /// Set by `release`. Read by the worker and by settling.
        cancel_flag: std.atomic.Value(bool) = .init(false),
        /// Guarded by `loads.mutex`. Set by the worker, taken by settling.
        pending: ?A.Output = null,
        /// Written once before the worker starts, read-only after.
        source: A.Source,
        asset_source: assets.AssetSource,
        http_client: ?http_client_mod.HttpClient,
        /// Main thread only from here on.
        loaded: bool = false,
        value: A.Output = undefined,
        /// Views that asked for the value while it loaded; they are notified when it arrives.
        viewers: std.ArrayList(EntityId) = .empty,

        /// Starts loading `source` (GPUI `CachedLoad::new`). The caller owns the returned reference.
        pub fn start(loads: *AssetLoads, source: A.Source) error{OutOfMemory}!*Self {
            const a = loads.allocator;
            const cloned = comptime @hasDecl(A, "clone_source");
            const owned: A.Source = if (cloned) try A.clone_source(source, a) else source;
            errdefer if (cloned) A.free_source(owned, a);
            const self = try a.create(Self);
            errdefer a.destroy(self);
            self.* = .{
                .loads = loads,
                .refs = 2,
                .source = owned,
                .asset_source = loads.app.asset_source,
                .http_client = if (loads.app.asset_cache.fetch_config) |c| c.http_client else null,
            };
            try loads.live.put(a, @intFromPtr(self), .{ .ptr = self, .release = release_erased });
            errdefer _ = loads.live.remove(@intFromPtr(self));
            loads.group.concurrent(loads.io(), work, .{self}) catch {
                // No thread to run on: load here, so the caller still gets a value.
                self.refs = 1;
                var lc = self.context(a);
                self.value = A.load(self.source, &lc);
                self.loaded = true;
            };
            return self;
        }

        fn context(self: *Self, allocator: std.mem.Allocator) LoadContext {
            return .{
                .allocator = allocator,
                .io = self.loads.io(),
                .asset_source = self.asset_source,
                .http_client = self.http_client,
                .cancel_flag = &self.cancel_flag,
            };
        }

        /// Worker thread. Always hands its result over, even when nobody wants it any more.
        fn work(self: *Self) Io.Cancelable!void {
            const loads = self.loads;
            var lc = self.context(loads.allocator);
            const out = A.load(self.source, &lc);
            const the_io = loads.io();
            loads.mutex.lockUncancelable(the_io);
            self.pending = out;
            loads.finished.append(loads.allocator, .{ .ptr = self, .settle = settle_erased }) catch @panic("out of memory");
            loads.mutex.unlock(the_io);
            // Thread-safe, like RemoteImages' delivery: the queue, not the call, carries the result.
            var task = loads.foreground.spawn(AssetLoads.settle_all, .{loads});
            task.detach();
        }

        fn settle_erased(ptr: *anyopaque, app: *App) void {
            const self: *Self = @ptrCast(@alignCast(ptr));
            self.settle(app);
        }

        /// Main thread. Takes the worker's reference and the result.
        fn settle(self: *Self, app: *App) void {
            const loads = self.loads;
            const the_io = loads.io();
            loads.mutex.lockUncancelable(the_io);
            const out = self.pending.?;
            self.pending = null;
            self.refs -= 1;
            const abandoned = self.cancel_flag.load(.acquire);
            const free_now = self.refs == 0;
            loads.mutex.unlock(the_io);
            if (abandoned) {
                if (comptime @hasDecl(A, "dispose")) A.dispose(out, app);
                if (free_now) self.destroy();
                return;
            }
            self.value = out;
            self.loaded = true;
            if (!loads.closed) for (self.viewers.items) |id| app.notify(id);
            self.viewers.clearRetainingCapacity();
        }

        fn release_erased(ptr: *anyopaque, app: *App) void {
            const self: *Self = @ptrCast(@alignCast(ptr));
            self.release(app);
        }

        /// Drops the owner's reference (GPUI dropping a `CachedLoad`). The loaded value is disposed
        /// now; a running load is disposed when it arrives. Calling it again does nothing.
        pub fn release(self: *Self, app: *App) void {
            const loads = self.loads;
            const the_io = loads.io();
            loads.mutex.lockUncancelable(the_io);
            if (self.cancel_flag.load(.acquire)) {
                loads.mutex.unlock(the_io);
                return;
            }
            self.cancel_flag.store(true, .release);
            self.refs -= 1;
            const free_now = self.refs == 0;
            loads.mutex.unlock(the_io);
            if (self.loaded) {
                self.loaded = false;
                if (comptime @hasDecl(A, "dispose")) A.dispose(self.value, app);
            }
            if (free_now) self.destroy();
        }

        fn destroy(self: *Self) void {
            const loads = self.loads;
            const a = loads.allocator;
            _ = loads.live.remove(@intFromPtr(self));
            self.viewers.deinit(a);
            if (comptime @hasDecl(A, "clone_source")) A.free_source(self.source, a);
            a.destroy(self);
        }

        /// The loaded value, if it has arrived (GPUI `get`). Does not subscribe the caller.
        pub fn get(self: *const Self) ?A.Output {
            return if (self.loaded) self.value else null;
        }

        /// The loaded value, or null while it loads. A view that asks is notified when it arrives
        /// (GPUI `use_by`). `view` is null outside rendering, and then nothing is notified.
        pub fn use_by(self: *Self, view: ?EntityId) ?A.Output {
            if (self.loaded) return self.value;
            if (view) |id| {
                for (self.viewers.items) |v| if (v == id) return null;
                self.viewers.append(self.loads.allocator, id) catch @panic("out of memory");
            }
            return null;
        }
    };
}

// -- tests -------------------------------------------------------------------

const testing = std.testing;

test "hash: slices hash by content, and different sources differ" {
    const a = "pixel.png";
    var buf: [9]u8 = undefined;
    @memcpy(&buf, a);
    try testing.expectEqual(hash(@as([]const u8, a)), hash(@as([]const u8, &buf)));
    try testing.expect(hash(@as([]const u8, a)) != hash(@as([]const u8, "other.png")));
    const r1: assets.Resource = .{ .uri = "https://example.test/a.png" };
    const r2: assets.Resource = .{ .embedded = "https://example.test/a.png" };
    try testing.expect(hash(r1) != hash(r2));
}

test {
    std.testing.refAllDecls(@This());
}
