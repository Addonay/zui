//! Scoped background executor (gap report §6D).
//!
//! A minimal pool of worker threads (default 2) with a bounded job queue.
//! Workers perform file I/O and never mutate entities, windows, the image
//! cache, or the asset registry. Results marshal back to the UI thread
//! through a completion queue drained at `App.step` start, mirroring the
//! event-queue boundary (`platform/event.zig` queue policy untouched).
//!
//! Each job carries a cancellation token checked at worker start AND before
//! completion delivery, plus an optional weak-target liveness probe so a
//! destroyed entity (or a cancelled/stale asset ticket) turns the delivery
//! into a counted no-op instead of aliasing freed memory (`WeakEntity`
//! semantics in `runtime.zig`). Submit and drain assert the UI thread like
//! `EntityStore`.
//!
//! Queue bound: at most `max_in_flight` jobs may be pending, running, or
//! awaiting delivery. Over-limit submissions fail with
//! `error.TaskQueueFull` — counted in `rejected_full`, never silent.
//!
//! Shutdown: `deinit` joins workers, delivers already-finished completions
//! while entities and the asset cache are still alive (callers must deinit
//! the runtime BEFORE `EntityStore` and image-cache teardown), then
//! destroys unstarted jobs without running them. Closing a window or
//! destroying an entity mid-flight is therefore safe: late deliveries
//! no-op through the liveness probe.
//!
//! When no worker thread could be spawned (thread creation failed, or a
//! single-threaded build), submissions still succeed: `drainCompletions`
//! runs queued jobs inline on the UI thread through the same
//! cancel-then-alive gates, so behavior stays identical, only less
//! parallel. If even the queue rings cannot be allocated, submissions fail
//! with `error.TaskQueueFull` (counted, explicit).

const std = @import("std");
const builtin = @import("builtin");
const runtime = @import("runtime.zig");
const window_mod = @import("window.zig");
const zlog = @import("../core/log.zig");

pub const DEFAULT_WORKERS: usize = 2;
pub const DEFAULT_MAX_IN_FLIGHT: usize = 32;

/// Shared cancellation token. Set from the UI thread (or any thread);
/// observed by the worker at job start and by the UI thread before
/// delivery. A cancelled job still occupies its queue slot until drained.
pub const Cancel = struct {
    flag: *std.atomic.Value(bool),

    pub fn cancel(self: Cancel) void {
        self.flag.store(true, .seq_cst);
    }

    pub fn isCancelled(self: Cancel) bool {
        return self.flag.load(.seq_cst);
    }
};

const Job = struct {
    ctx: *anyopaque,
    run_fn: *const fn (*anyopaque, Cancel) void,
    complete_fn: *const fn (*anyopaque) void,
    destroy_fn: *const fn (*anyopaque, std.mem.Allocator) void,
    /// UI-thread liveness probe (weak entity target, asset ticket). Null
    /// means unconditionally live. Checked before delivery; a dead target
    /// is a counted no-op (`dropped_stale`).
    alive_fn: ?*const fn (*anyopaque) bool,
    cancelled: *std.atomic.Value(bool),
};

pub const JobFns = struct {
    run: *const fn (*anyopaque, Cancel) void,
    complete: *const fn (*anyopaque) void,
    destroy: *const fn (*anyopaque, std.mem.Allocator) void,
    alive: ?*const fn (*anyopaque) bool = null,
};

pub const Options = struct {
    workers: usize = DEFAULT_WORKERS,
    max_in_flight: usize = DEFAULT_MAX_IN_FLIGHT,
};

pub const TaskRuntime = struct {
    allocator: std.mem.Allocator,
    ui_thread: std.Thread.Id,
    max_in_flight: usize,
    num_workers: usize,
    mutex: std.atomic.Mutex = .unlocked,
    pending_buf: []*Job = &.{},
    ready_buf: []*Job = &.{},
    pending_head: usize = 0,
    pending_len: usize = 0,
    ready_head: usize = 0,
    ready_len: usize = 0,
    /// Pending + running + ready-undelivered. Touched on the UI thread
    /// only (submit/deliver); workers never consult it.
    in_flight: usize = 0,
    workers: std.ArrayList(std.Thread) = .empty,
    started: bool = false,
    shutdown_flag: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    /// Optional wakeup signalled by workers after publishing a completion
    /// (lets a blocked event loop return promptly; delivery still happens
    /// on the UI thread in `drainCompletions`). Heap-owned backend copy so
    /// the runtime never borrows a moved `App`.
    wakeup_fn: ?*const fn (*anyopaque) void = null,
    wakeup_ctx: ?*anyopaque = null,
    submitted: u64 = 0,
    delivered: u64 = 0,
    dropped_cancelled: u64 = 0,
    dropped_stale: u64 = 0,
    rejected_full: u64 = 0,

    pub fn init(allocator: std.mem.Allocator, opts: Options) TaskRuntime {
        return .{
            .allocator = allocator,
            .ui_thread = std.Thread.getCurrentId(),
            .max_in_flight = @max(opts.max_in_flight, 1),
            .num_workers = opts.workers,
        };
    }

    fn assertUiThread(self: *const TaskRuntime) void {
        if (comptime builtin.single_threaded) return;
        std.debug.assert(std.meta.eql(self.ui_thread, std.Thread.getCurrentId()));
    }

    fn lock(self: *TaskRuntime) void {
        while (!self.mutex.tryLock()) std.Thread.yield() catch {};
    }

    fn unlock(self: *TaskRuntime) void {
        self.mutex.unlock();
    }

    /// Allocate rings and spawn workers. Infallible by design: when thread
    /// creation (or ring allocation) fails the runtime degrades to inline
    /// execution inside `drainCompletions` (same gates, UI thread), or to
    /// explicit `TaskQueueFull` rejection when no queue exists at all.
    pub fn start(self: *TaskRuntime) void {
        self.assertUiThread();
        if (self.started) return;
        self.started = true;
        if (comptime builtin.single_threaded) return;
        self.pending_buf = self.allocator.alloc(*Job, self.max_in_flight) catch {
            zlog.log("tasks", "queue alloc failed; submissions will report TaskQueueFull", .{});
            return;
        };
        self.ready_buf = self.allocator.alloc(*Job, self.max_in_flight) catch {
            self.allocator.free(self.pending_buf);
            self.pending_buf = &.{};
            zlog.log("tasks", "queue alloc failed; submissions will report TaskQueueFull", .{});
            return;
        };
        // Pre-size the join list so appends below cannot fail (a spawned
        // thread with no stored handle could neither join nor detach
        // safely: it touches the rings under mutex until shutdown).
        self.workers.ensureTotalCapacity(self.allocator, self.num_workers) catch {
            self.allocator.free(self.pending_buf);
            self.allocator.free(self.ready_buf);
            self.pending_buf = &.{};
            self.ready_buf = &.{};
            zlog.log("tasks", "worker list alloc failed; queued jobs run inline in drain", .{});
            return;
        };
        var spawned: usize = 0;
        while (spawned < self.num_workers) : (spawned += 1) {
            const th = std.Thread.spawn(.{}, workerMain, .{self}) catch {
                zlog.log("tasks", "worker spawn failed; continuing with {d} worker(s), drain runs the rest inline", .{spawned});
                break;
            };
            self.workers.appendAssumeCapacity(th);
        }
    }

    /// Install a completion wakeup (typically the platform backend wake).
    /// The callback must be thread-safe; it must not touch task state.
    /// `ctx` is borrowed: the caller must keep it alive until `deinit`
    /// returns (App heap-owns its backend copy for exactly this reason).
    pub fn setWakeup(self: *TaskRuntime, func: *const fn (*anyopaque) void, ctx: *anyopaque) void {
        self.assertUiThread();
        self.wakeup_fn = func;
        self.wakeup_ctx = ctx;
    }

    pub fn workerCount(self: *const TaskRuntime) usize {
        return self.workers.items.len;
    }

    pub fn pendingCount(self: *TaskRuntime) usize {
        self.lock();
        defer self.unlock();
        return self.pending_len;
    }

    pub fn readyCount(self: *TaskRuntime) usize {
        self.lock();
        defer self.unlock();
        return self.ready_len;
    }

    /// True while any job is submitted but undelivered (pending, running,
    /// or ready). `App.nextWaitNs` treats ready work as immediately due.
    pub fn hasReady(self: *const TaskRuntime) bool {
        // UI-thread-only read in practice (drain/submit are UI entry
        // points); the mutex field is const-cast because a worker may hold
        // it briefly while publishing a completion.
        const m: *std.atomic.Mutex = @constCast(&self.mutex);
        while (!m.tryLock()) std.Thread.yield() catch {};
        defer m.unlock();
        return self.ready_len > 0;
    }

    pub fn inFlight(self: *const TaskRuntime) usize {
        // UI-thread-only counter; no lock needed (submit/deliver/drain are
        // all UI-thread entry points).
        return self.in_flight;
    }

    /// Type-erased submit. Takes ownership of `ctx` (via `fns.destroy`)
    /// only on success; on `TaskQueueFull`/`OutOfMemory` the caller keeps
    /// `ctx` and must destroy it.
    pub fn spawnRaw(self: *TaskRuntime, ctx: *anyopaque, fns: JobFns) error{ TaskQueueFull, OutOfMemory }!Cancel {
        self.assertUiThread();
        if (!self.started) self.start();
        const job = try self.allocator.create(Job);
        errdefer self.allocator.destroy(job);
        const flag = try self.allocator.create(std.atomic.Value(bool));
        errdefer self.allocator.destroy(flag);
        flag.* = .init(false);
        job.* = .{
            .ctx = ctx,
            .run_fn = fns.run,
            .complete_fn = fns.complete,
            .destroy_fn = fns.destroy,
            .alive_fn = fns.alive,
            .cancelled = flag,
        };
        self.lock();
        defer self.unlock();
        if (self.pending_buf.len == 0 or self.in_flight >= self.max_in_flight) {
            self.rejected_full += 1;
            return error.TaskQueueFull;
        }
        self.pending_buf[(self.pending_head + self.pending_len) % self.max_in_flight] = job;
        self.pending_len += 1;
        self.in_flight += 1;
        self.submitted += 1;
        return .{ .flag = flag };
    }

    /// Entity-scoped submit. `run` executes on a worker (must touch only
    /// `user` state and the cancel token — never entities, windows, or
    /// caches). `done` runs on the UI thread as `Context(T)` against the
    /// upgraded target and may notify/invalidate; a destroyed target
    /// no-ops before `done` is reached. `user` is copied into the job box,
    /// so worker-produced results must flow through pointers or atomics
    /// reachable from the copy.
    pub fn spawnForEntity(
        self: *TaskRuntime,
        comptime T: type,
        weak: runtime.WeakEntity(T),
        window: ?*window_mod.Window,
        user: anytype,
        comptime run: anytype,
        comptime done: anytype,
    ) error{ TaskQueueFull, OutOfMemory }!Cancel {
        const Ctx = @TypeOf(user);
        const Box = struct {
            weak: runtime.WeakEntity(T),
            window: ?*window_mod.Window,
            state: Ctx,
        };
        const box = try self.allocator.create(Box);
        errdefer self.allocator.destroy(box);
        box.* = .{ .weak = weak, .window = window, .state = user };
        const fns = JobFns{
            .run = struct {
                fn runFn(raw: *anyopaque, cancel: Cancel) void {
                    const b: *Box = @ptrCast(@alignCast(raw));
                    run(&b.state, cancel);
                }
            }.runFn,
            .complete = struct {
                fn completeFn(raw: *anyopaque) void {
                    const b: *Box = @ptrCast(@alignCast(raw));
                    // Double-gated: drain already checked liveness on this
                    // same thread, so upgrade cannot fail here; the check
                    // keeps completeFn safe if ever invoked directly.
                    const ent = b.weak.upgrade() orelse return;
                    var cx = runtime.Context(T){ .store = ent.header.store, .current = ent, .window = b.window };
                    done(ent.value, &cx, &b.state);
                }
            }.completeFn,
            .destroy = struct {
                fn destroyFn(raw: *anyopaque, alloc: std.mem.Allocator) void {
                    const b: *Box = @ptrCast(@alignCast(raw));
                    alloc.destroy(b);
                }
            }.destroyFn,
            .alive = struct {
                fn aliveFn(raw: *anyopaque) bool {
                    const b: *Box = @ptrCast(@alignCast(raw));
                    return b.weak.isAlive();
                }
            }.aliveFn,
        };
        errdefer self.allocator.destroy(box);
        // On success spawnRaw owns `box` (freed at delivery); on error
        // the errdefer above frees it and the caller keeps nothing.
        return self.spawnRaw(box, fns);
    }

    /// Drain finished completions on the UI thread. With no workers, queued
    /// jobs first run inline through the same cancel gate, so
    /// submit-then-drain is a complete synchronous pipeline.
    pub fn drainCompletions(self: *TaskRuntime) void {
        self.assertUiThread();
        if (self.workers.items.len == 0 and self.pending_buf.len > 0) {
            while (true) {
                self.lock();
                if (self.pending_len == 0 or self.shutdown_flag.load(.seq_cst)) {
                    self.unlock();
                    break;
                }
                const job = self.pending_buf[self.pending_head];
                self.pending_head = (self.pending_head + 1) % self.max_in_flight;
                self.pending_len -= 1;
                self.unlock();
                if (!job.cancelled.load(.seq_cst)) {
                    job.run_fn(job.ctx, .{ .flag = job.cancelled });
                }
                self.lock();
                self.ready_buf[(self.ready_head + self.ready_len) % self.max_in_flight] = job;
                self.ready_len += 1;
                self.unlock();
            }
        }
        while (true) {
            self.lock();
            if (self.ready_len == 0) {
                self.unlock();
                break;
            }
            const job = self.ready_buf[self.ready_head];
            self.ready_head = (self.ready_head + 1) % self.max_in_flight;
            self.ready_len -= 1;
            self.unlock();
            self.deliver(job);
        }
    }

    fn deliver(self: *TaskRuntime, job: *Job) void {
        self.in_flight -= 1;
        if (job.cancelled.load(.seq_cst)) {
            self.dropped_cancelled += 1;
        } else if (job.alive_fn) |isAlive| {
            if (!isAlive(job.ctx)) {
                self.dropped_stale += 1;
                self.destroyJob(job);
                return;
            }
            job.complete_fn(job.ctx);
            self.delivered += 1;
        } else {
            job.complete_fn(job.ctx);
            self.delivered += 1;
        }
        self.destroyJob(job);
    }

    fn destroyJob(self: *TaskRuntime, job: *Job) void {
        job.destroy_fn(job.ctx, self.allocator);
        self.allocator.destroy(job.cancelled);
        self.allocator.destroy(job);
    }

    pub fn deinit(self: *TaskRuntime) void {
        self.assertUiThread();
        self.shutdown_flag.store(true, .seq_cst);
        for (self.workers.items) |w| w.join();
        self.workers.deinit(self.allocator);
        // Deliver what workers finished while targets are still alive;
        // the caller must deinit tasks BEFORE entities and the image cache.
        self.drainCompletions();
        // Unstarted jobs never ran: destroy without run/complete.
        while (self.pending_len > 0) {
            self.pending_len -= 1;
            const job = self.pending_buf[self.pending_head];
            self.pending_head = (self.pending_head + 1) % self.max_in_flight;
            self.in_flight -= 1;
            self.destroyJob(job);
        }
        if (self.pending_buf.len > 0) self.allocator.free(self.pending_buf);
        if (self.ready_buf.len > 0) self.allocator.free(self.ready_buf);
        self.pending_buf = &.{};
        self.ready_buf = &.{};
        // wakeup_ctx is borrowed (see setWakeup); the owner frees it.
        self.wakeup_fn = null;
        self.wakeup_ctx = null;
    }
};

fn workerMain(rt: *TaskRuntime) void {
    while (true) {
        rt.lock();
        if (rt.pending_len == 0) {
            const stop = rt.shutdown_flag.load(.seq_cst);
            rt.unlock();
            if (stop) return;
            std.Thread.yield() catch {};
            continue;
        }
        const job = rt.pending_buf[rt.pending_head];
        rt.pending_head = (rt.pending_head + 1) % rt.max_in_flight;
        rt.pending_len -= 1;
        rt.unlock();
        // Cancellation gate at worker start: a cancel() that landed after
        // submit skips the work; delivery re-checks before dispatch.
        if (!job.cancelled.load(.seq_cst)) {
            job.run_fn(job.ctx, .{ .flag = job.cancelled });
        }
        rt.lock();
        // Room is guaranteed: every ready job still counts in in_flight,
        // and pending + running + ready never exceeds max_in_flight.
        rt.ready_buf[(rt.ready_head + rt.ready_len) % rt.max_in_flight] = job;
        rt.ready_len += 1;
        const wake_fn = rt.wakeup_fn;
        const wake_ctx = rt.wakeup_ctx;
        rt.unlock();
        if (wake_fn) |w| w(wake_ctx.?);
    }
}

// ---------------------------------------------------------------------------
// Tests (headless, deterministic: atomic gates instead of sleeps)
// ---------------------------------------------------------------------------

fn spinUntil(cond: *const fn (*anyopaque) bool, ctx: *anyopaque) bool {
    // Generous liveness bound; correctness never depends on timing, only
    // on eventual worker progress.
    var i: usize = 0;
    while (i < 20_000_000) : (i += 1) {
        if (cond(ctx)) return true;
        std.Thread.yield() catch {};
    }
    return false;
}

test "task completion marshals to the UI thread" {
    const t = std.testing;
    var harness = try runtime.TestHarness.init(t.allocator);
    defer harness.deinit();
    var rt = TaskRuntime.init(t.allocator, .{ .workers = 2 });
    defer rt.deinit();
    rt.start();

    const Counter = struct {
        pub const Options = struct {};
        n: u32 = 0,
        pub fn init(_: *runtime.Context(@This()), _: @This().Options) @This() {
            return .{};
        }
    };
    const entity = harness.new(Counter, .{});
    const ui_id = std.Thread.getCurrentId();

    const State = struct {
        worker_id: ?std.Thread.Id = null,
        ui_seen: ?std.Thread.Id = null,
        notified: bool = false,
    };
    var state = State{};
    const run = struct {
        fn run(s: *State, _: Cancel) void {
            s.worker_id = std.Thread.getCurrentId();
        }
    }.run;
    const done = struct {
        fn done(v: *Counter, cx: *runtime.Context(Counter), s: *State) void {
            s.ui_seen = std.Thread.getCurrentId();
            v.n += 1;
            cx.notify();
        }
    }.done;
    // Direct spawnRaw with a minimal entity-targeted job, asserting the
    // worker/UI thread boundary explicitly. spawnForEntity wraps this same
    // path and is covered by the test below.
    const Box = struct {        weak: runtime.WeakEntity(Counter),
        st: *State,
    };
    const box = try t.allocator.create(Box);
    errdefer t.allocator.destroy(box);
    box.* = .{ .weak = entity.weak(), .st = &state };
    const fns = JobFns{
        .run = struct {
            fn r(raw: *anyopaque, c: Cancel) void {
                const b: *Box = @ptrCast(@alignCast(raw));
                run(b.st, c);
            }
        }.r,
        .complete = struct {
            fn c(raw: *anyopaque) void {
                const b: *Box = @ptrCast(@alignCast(raw));
                const ent = b.weak.upgrade() orelse return;
                var cx = runtime.Context(Counter){ .store = ent.header.store, .current = ent, .window = null };
                done(ent.value, &cx, b.st);
            }
        }.c,
        .destroy = struct {
            fn d(raw: *anyopaque, alloc: std.mem.Allocator) void {
                alloc.destroy(@as(*Box, @ptrCast(@alignCast(raw))));
            }
        }.d,
        .alive = struct {
            fn a(raw: *anyopaque) bool {
                const b: *Box = @ptrCast(@alignCast(raw));
                return b.weak.isAlive();
            }
        }.a,
    };
    _ = try rt.spawnRaw(box, fns);
    const Ctx = struct {
        rt: *TaskRuntime,
        fn ready(p: *anyopaque) bool {
            const r: *@This() = @ptrCast(@alignCast(p));
            return r.rt.readyCount() > 0;
        }
    };
    var c = Ctx{ .rt = &rt };
    try t.expect(spinUntil(Ctx.ready, &c));
    rt.drainCompletions();
    try t.expectEqual(@as(u32, 1), entity.read().n);
    try t.expect(state.ui_seen != null);
    try t.expect(std.meta.eql(state.ui_seen.?, ui_id));
    try t.expect(harness.store.dirty); // notify() invalidated on the UI thread
    try t.expectEqual(@as(u64, 1), rt.delivered);
    if (rt.workerCount() > 0) {
        // A real worker ran the job off the UI thread.
        try t.expect(state.worker_id != null);
        try t.expect(!std.meta.eql(state.worker_id.?, ui_id));
    }
}

test "spawnForEntity delivers as Context(T) on the UI thread" {
    const t = std.testing;
    var harness = try runtime.TestHarness.init(t.allocator);
    defer harness.deinit();
    var rt = TaskRuntime.init(t.allocator, .{ .workers = 2 });
    defer rt.deinit();
    rt.start();

    const Counter = struct {
        pub const Options = struct {};
        n: u32 = 0,
        pub fn init(_: *runtime.Context(@This()), _: @This().Options) @This() {
            return .{};
        }
    };
    const entity = harness.new(Counter, .{});

    // Worker-produced results flow through pointers inside the copied user
    // state; the done callback runs as Context(T) and may notify.
    const Probes = struct {
        ran_on_worker: *std.atomic.Value(bool),
        done_count: *u32,
    };
    var ran_on_worker = std.atomic.Value(bool).init(false);
    var done_count: u32 = 0;
    _ = try rt.spawnForEntity(
        Counter,
        entity.weak(),
        null,
        Probes{ .ran_on_worker = &ran_on_worker, .done_count = &done_count },
        struct {
            fn run(p: *Probes, _: Cancel) void {
                p.ran_on_worker.store(true, .seq_cst);
            }
        }.run,
        struct {
            fn done(v: *Counter, cx: *runtime.Context(Counter), p: *Probes) void {
                v.n += 1;
                p.done_count.* += 1;
                cx.notify();
            }
        }.done,
    );
    const Ready = struct {
        fn ready(p: *anyopaque) bool {
            const r: *TaskRuntime = @ptrCast(@alignCast(p));
            return r.readyCount() > 0;
        }
    };
    if (rt.workerCount() > 0) {
        try t.expect(spinUntil(Ready.ready, &rt));
    }
    rt.drainCompletions();
    try t.expectEqual(@as(u32, 1), entity.read().n);
    try t.expectEqual(@as(u32, 1), done_count);
    try t.expect(harness.store.dirty);
    try t.expectEqual(@as(u64, 1), rt.delivered);
    if (rt.workerCount() > 0) {
        try t.expect(ran_on_worker.load(.seq_cst));
    }
}

test "destroyed target completion no-ops" {
    const t = std.testing;
    var harness = try runtime.TestHarness.init(t.allocator);
    defer harness.deinit();
    var rt = TaskRuntime.init(t.allocator, .{ .workers = 1 });
    defer rt.deinit();
    rt.start();

    const Counter = struct {
        pub const Options = struct {};
        n: u32 = 0,
        pub fn init(_: *runtime.Context(@This()), _: @This().Options) @This() {
            return .{};
        }
    };
    const entity = harness.new(Counter, .{});
    const weak = entity.weak();

    const Gate = struct {
        started: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
        release: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
        applied: u32 = 0,
    };
    var gate = Gate{};
    const Box = struct {
        weak: runtime.WeakEntity(Counter),
        gate: *Gate,
    };
    const box = try t.allocator.create(Box);
    errdefer t.allocator.destroy(box);
    box.* = .{ .weak = weak, .gate = &gate };
    _ = try rt.spawnRaw(box, .{
        .run = struct {
            fn r(raw: *anyopaque, _: Cancel) void {
                const b: *Box = @ptrCast(@alignCast(raw));
                b.gate.started.store(true, .seq_cst);
                while (!b.gate.release.load(.seq_cst)) std.Thread.yield() catch {};
            }
        }.r,
        .complete = struct {
            fn c(raw: *anyopaque) void {
                const b: *Box = @ptrCast(@alignCast(raw));
                const ent = b.weak.upgrade() orelse return;
                ent.readMut().n += 1;
                b.gate.applied += 1;
            }
        }.c,
        .destroy = struct {
            fn d(raw: *anyopaque, alloc: std.mem.Allocator) void {
                alloc.destroy(@as(*Box, @ptrCast(@alignCast(raw))));
            }
        }.d,
        .alive = struct {
            fn a(raw: *anyopaque) bool {
                const b: *Box = @ptrCast(@alignCast(raw));
                return b.weak.isAlive();
            }
        }.a,
    });

    // Wait until the worker is provably inside the job, then destroy the
    // target mid-flight: the late delivery must no-op.
    const Started = struct {
        fn ready(p: *anyopaque) bool {
            const g: *Gate = @ptrCast(@alignCast(p));
            return g.started.load(.seq_cst);
        }
    };
    if (rt.workerCount() > 0) {
        try t.expect(spinUntil(Started.ready, &gate));
    }
    entity.destroy();
    harness.store.dirty = false;
    gate.release.store(true, .seq_cst);
    const Ready = struct {
        fn ready(p: *anyopaque) bool {
            const r: *TaskRuntime = @ptrCast(@alignCast(p));
            return r.readyCount() > 0;
        }
    };
    if (rt.workerCount() > 0) {
        try t.expect(spinUntil(Ready.ready, &rt));
    }
    rt.drainCompletions();
    try t.expectEqual(@as(u32, 0), gate.applied);
    try t.expect(!harness.store.dirty);
    try t.expectEqual(@as(u64, 1), rt.dropped_stale);
    try t.expectEqual(@as(u64, 0), rt.delivered);
}

test "cancelled jobs never deliver" {
    const t = std.testing;
    var rt = TaskRuntime.init(t.allocator, .{ .workers = 1 });
    defer rt.deinit();
    rt.start();

    const Gate = struct {
        release: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
        applied: u32 = 0,
    };
    var gate = Gate{};
    const Box = struct {
        gate: *Gate,
    };
    const box = try t.allocator.create(Box);
    errdefer t.allocator.destroy(box);
    box.* = .{ .gate = &gate };
    const token = try rt.spawnRaw(box, .{
        .run = struct {
            fn r(raw: *anyopaque, _: Cancel) void {
                const b: *Box = @ptrCast(@alignCast(raw));
                while (!b.gate.release.load(.seq_cst)) std.Thread.yield() catch {};
            }
        }.r,
        .complete = struct {
            fn c(raw: *anyopaque) void {
                const b: *Box = @ptrCast(@alignCast(raw));
                b.gate.applied += 1;
            }
        }.c,
        .destroy = struct {
            fn d(raw: *anyopaque, alloc: std.mem.Allocator) void {
                alloc.destroy(@as(*Box, @ptrCast(@alignCast(raw))));
            }
        }.d,
    });
    // Cancel while the worker is gated inside (or queued): either the
    // worker-start gate or the pre-delivery gate drops it.
    token.cancel();
    gate.release.store(true, .seq_cst);
    const Ready = struct {
        fn ready(p: *anyopaque) bool {
            const r: *TaskRuntime = @ptrCast(@alignCast(p));
            return r.readyCount() > 0;
        }
    };
    if (rt.workerCount() > 0) {
        try t.expect(spinUntil(Ready.ready, &rt));
    }
    rt.drainCompletions();
    try t.expectEqual(@as(u32, 0), gate.applied);
    try t.expectEqual(@as(u64, 1), rt.dropped_cancelled);
    try t.expectEqual(@as(u64, 0), rt.delivered);
}

test "over-limit submissions fail explicitly" {
    const t = std.testing;
    var rt = TaskRuntime.init(t.allocator, .{ .workers = 1, .max_in_flight = 1 });
    defer rt.deinit();
    rt.start();

    const Nop = struct {};
    const box = try t.allocator.create(Nop);
    errdefer t.allocator.destroy(box);
    box.* = .{};
    const fns = JobFns{
        .run = struct {
            fn r(_: *anyopaque, _: Cancel) void {}
        }.r,
        .complete = struct {
            fn c(_: *anyopaque) void {}
        }.c,
        .destroy = struct {
            fn d(raw: *anyopaque, alloc: std.mem.Allocator) void {
                alloc.destroy(@as(*Nop, @ptrCast(@alignCast(raw))));
            }
        }.d,
    };
    _ = try rt.spawnRaw(box, fns);
    // One slot, already occupied: the next submission is rejected with an
    // explicit error plus a counter — never silently dropped.
    const box2 = try t.allocator.create(Nop);
    defer t.allocator.destroy(box2);
    box2.* = .{};
    try t.expectError(error.TaskQueueFull, rt.spawnRaw(box2, fns));
    try t.expectEqual(@as(u64, 1), rt.rejected_full);
    rt.drainCompletions();
    try t.expectEqual(@as(usize, 0), rt.inFlight());
}
