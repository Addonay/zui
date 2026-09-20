//! Bounded, source-keyed asset cache contract.
//!
//! This is the small generic boundary shared by image-like resources and
//! other retained assets. It deliberately owns no worker, decoder, GPU
//! resource, or UI element. A source adapter starts a load after `begin()`;
//! the UI-thread completion calls `complete()` or `fail()`. Generation and
//! revision checks make late worker results harmless.

const std = @import("std");
/// Keep this layer independent from the renderer/core module graph. The
/// image pool currently uses the same effective bound; callers can lower it
/// through `Budget.count` for tests or smaller caches.
const max_entries = 64;

pub const SourceKey = struct {
    hash: u64,
    kind: u32 = 0,

    pub fn fromBytes(bytes: []const u8, kind: u32) SourceKey {
        return .{ .hash = std.hash.Wyhash.hash(@as(u64, kind), bytes), .kind = kind };
    }
};

pub const State = enum { loading, ready, failed };
pub const Failure = enum { cancelled, closed, evicted, load_failed };
pub const Handle = struct { slot: u16, generation: u64 };
pub const Ticket = struct { handle: Handle, revision: u64 };
pub const Budget = struct { count: usize = max_entries };
pub const Stats = struct {
    loads: u64 = 0,
    completions: u64 = 0,
    failures: u64 = 0,
    cancellations: u64 = 0,
    evictions: u64 = 0,
    stale_completions: u64 = 0,
};

/// Narrow source-provider bridge. The provider owns the actual I/O/decoder;
/// it is called exactly once for a newly reserved source and feeds the
/// returned ticket back to the cache on completion.
pub fn AssetSource(comptime CacheType: type) type {
    return struct {
        const Self = @This();
        pub const StartFn = *const fn (*anyopaque, Ticket) void;

        context: *anyopaque,
        start_fn: StartFn,

        pub fn request(self: Self, cache: *CacheType, source: SourceKey) !CacheType.Acquire {
            const acquisition = try cache.begin(source);
            if (acquisition.started) self.start_fn(self.context, acquisition.ticket);
            return acquisition;
        }
    };
}

pub fn AssetCache(comptime Value: type) type {
    return struct {
        const Self = @This();
        pub const ValueRelease = *const fn (std.mem.Allocator, *Value) void;
        pub const Ops = struct { release: ValueRelease };
        pub const Acquire = struct {
            ticket: Ticket,
            state: State,
            /// True only when the caller must start a source load.
            started: bool,
        };
        pub const Metadata = struct {
            source: SourceKey,
            state: State,
            revision: u64,
            failure: ?Failure = null,
            references: u32 = 0,
        };

        const Entry = struct {
            generation: u64 = 0,
            revision: u64 = 1,
            source: SourceKey = .{ .hash = 0 },
            state: State = .loading,
            failure: ?Failure = null,
            value: ?Value = null,
            references: u32 = 0,
            last_used: u64 = 0,
        };

        allocator: std.mem.Allocator,
        ops: Ops,
        budget: Budget = .{},
        entries: [max_entries]Entry = @splat(.{}),
        next_generation: u64 = 1,
        clock: u64 = 0,
        closed: bool = false,
        stats: Stats = .{},

        pub fn init(allocator: std.mem.Allocator, ops: Ops) Self {
            return .{ .allocator = allocator, .ops = ops };
        }

        pub fn deinit(self: *Self) void {
            self.close();
            for (&self.entries) |*entry| self.discard(entry);
        }

        /// Stop accepting work. In-flight tickets become invalid immediately;
        /// a completion arriving after close is rejected without touching the
        /// value or source table.
        pub fn close(self: *Self) void {
            if (self.closed) return;
            self.closed = true;
            for (&self.entries) |*entry| {
                if (entry.generation != 0 and entry.state == .loading) {
                    entry.revision += 1;
                    entry.state = .failed;
                    entry.failure = .closed;
                    self.stats.cancellations += 1;
                }
            }
        }

        pub fn isClosed(self: *const Self) bool {
            return self.closed;
        }

        /// Find an existing source or reserve a bounded slot for a new load.
        /// Repeated calls while loading deduplicate and return the same ticket.
        pub fn begin(self: *Self, source: SourceKey) !Acquire {
            if (self.closed) return error.CacheClosed;
            if (self.find(source)) |handle| {
                const entry = self.get(handle).?;
                self.touch(entry);
                return .{
                    .ticket = .{ .handle = handle, .revision = entry.revision },
                    .state = entry.state,
                    .started = false,
                };
            }
            const handle = try self.reserve(source);
            const entry = self.get(handle).?;
            self.stats.loads += 1;
            return .{
                .ticket = .{ .handle = handle, .revision = entry.revision },
                .state = .loading,
                .started = true,
            };
        }

        pub fn find(self: *Self, source: SourceKey) ?Handle {
            for (&self.entries, 0..) |*entry, i| {
                if (entry.generation != 0 and std.meta.eql(entry.source, source))
                    return .{ .slot = @intCast(i), .generation = entry.generation };
            }
            return null;
        }

        pub fn metadata(self: *Self, handle: Handle) ?Metadata {
            const entry = self.get(handle) orelse return null;
            return .{ .source = entry.source, .state = entry.state, .revision = entry.revision, .failure = entry.failure, .references = entry.references };
        }

        pub fn value(self: *Self, handle: Handle) ?*const Value {
            const entry = self.get(handle) orelse return null;
            if (entry.state != .ready) return null;
            return if (entry.value) |*stored| stored else null;
        }

        pub fn retain(self: *Self, handle: Handle) bool {
            const entry = self.get(handle) orelse return false;
            entry.references +|= 1;
            self.touch(entry);
            return true;
        }

        pub fn release(self: *Self, handle: Handle) bool {
            const entry = self.get(handle) orelse return false;
            if (entry.references > 0) entry.references -= 1;
            self.touch(entry);
            return true;
        }

        /// Accept a result only for the currently loading revision.
        pub fn complete(self: *Self, ticket: Ticket, completed_value: Value) bool {
            if (self.closed) {
                self.stats.stale_completions += 1;
                self.disposeValue(completed_value);
                return false;
            }
            const entry = self.pending(ticket) orelse {
                self.stats.stale_completions += 1;
                self.disposeValue(completed_value);
                return false;
            };
            if (entry.value) |*old| self.disposeValue(old.*);
            entry.value = completed_value;
            entry.state = .ready;
            entry.failure = null;
            self.touch(entry);
            self.stats.completions += 1;
            return true;
        }

        pub fn fail(self: *Self, ticket: Ticket, reason: Failure) bool {
            const entry = self.pending(ticket) orelse {
                self.stats.stale_completions += 1;
                return false;
            };
            entry.state = .failed;
            entry.failure = reason;
            entry.revision += 1;
            self.stats.failures += 1;
            return true;
        }

        pub fn cancel(self: *Self, ticket: Ticket) bool {
            const entry = self.pending(ticket) orelse return false;
            entry.revision += 1;
            entry.state = .failed;
            entry.failure = .cancelled;
            self.stats.cancellations += 1;
            return true;
        }

        /// Start a new revision without changing the stable source handle.
        pub fn reload(self: *Self, handle: Handle) !Ticket {
            if (self.closed) return error.CacheClosed;
            const entry = self.get(handle) orelse return error.StaleHandle;
            if (entry.value) |*old| {
                self.disposeValue(old.*);
                entry.value = null;
            }
            entry.revision += 1;
            entry.state = .loading;
            entry.failure = null;
            self.stats.loads += 1;
            return .{ .handle = handle, .revision = entry.revision };
        }

        /// Explicit removal. All subsequent completions for the old handle
        /// are rejected even if the slot is reused.
        pub fn evict(self: *Self, handle: Handle) bool {
            const entry = self.get(handle) orelse return false;
            self.discard(entry);
            self.stats.evictions += 1;
            return true;
        }

        fn reserve(self: *Self, source: SourceKey) !Handle {
            const count = @min(self.budget.count, self.entries.len);
            var candidate: ?*Entry = null;
            var candidate_slot: usize = 0;
            for (self.entries[0..count], 0..) |*entry, i| {
                if (entry.generation == 0) {
                    candidate = entry;
                    candidate_slot = i;
                    break;
                }
                if (entry.references == 0 and entry.state != .loading and
                    (candidate == null or entry.last_used < candidate.?.last_used))
                {
                    candidate = entry;
                    candidate_slot = i;
                }
            }
            const entry = candidate orelse return error.CacheFull;
            if (entry.generation != 0) {
                self.discard(entry);
                self.stats.evictions += 1;
            }
            const generation = self.next_generation;
            self.next_generation +%= 1;
            if (self.next_generation == 0) self.next_generation = 1;
            entry.* = .{ .generation = generation, .source = source, .last_used = self.clock };
            return .{ .slot = @intCast(candidate_slot), .generation = generation };
        }

        fn get(self: *Self, handle: Handle) ?*Entry {
            if (handle.generation == 0 or handle.slot >= self.entries.len) return null;
            const entry = &self.entries[handle.slot];
            return if (entry.generation == handle.generation) entry else null;
        }

        fn pending(self: *Self, ticket: Ticket) ?*Entry {
            const entry = self.get(ticket.handle) orelse return null;
            return if (entry.state == .loading and entry.revision == ticket.revision) entry else null;
        }

        fn touch(self: *Self, entry: *Entry) void {
            self.clock +%= 1;
            entry.last_used = self.clock;
        }

        fn disposeValue(self: *Self, owned_value: Value) void {
            var owned = owned_value;
            self.ops.release(self.allocator, &owned);
        }

        fn discard(self: *Self, entry: *Entry) void {
            if (entry.value) |*stored| self.disposeValue(stored.*);
            entry.* = .{};
        }
    };
}

test {
    _ = @import("asset_cache_test.zig");
}
