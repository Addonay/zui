//! Port of GPUI `executor.rs`, `platform_scheduler.rs` and the main-thread
//! queue of `platform/threaded_dispatcher.rs`: a background worker pool, a
//! main-thread run queue drained by the platform loop, timers, and `Task`
//! handles.
//!
//! Zig has no async/await, so a foreground task is a deferred main-thread
//! callback whose result is stored in its `Task`, and a background task is a
//! plain function run on a worker thread.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const test_scheduler = @import("test_scheduler.zig");
const TestScheduler = test_scheduler.TestScheduler;

/// The deterministic scheduler a test attaches to an app's executors (see `test_scheduler.zig`).
/// Only test builds have one, so every field and check that uses it is `void` and folds away
/// elsewhere.
const Attached = if (builtin.is_test) ?*TestScheduler else void;
const not_attached: Attached = if (builtin.is_test) null else {};

/// The fake clock, in test builds while a `TestScheduler` runs. `now_ns` and every timer read it
/// instead of the awake clock. A test that runs its own clock may set it directly.
pub var test_clock_ns: if (builtin.is_test) ?u64 else void = if (builtin.is_test) null else {};

// ---------------------------------------------------------------------------
// Synchronization. Zig 0.17 implements mutexes, condition variables and futexes
// on top of `std.Io`. The single-threaded Io instance is enough here: it only
// uses the kernel futex and sleep calls, never its own thread pool.

var sync_threaded: Io.Threaded = Io.Threaded.init_single_threaded;

pub fn sync_io() Io {
    return sync_threaded.io();
}

fn real_now_ns() i96 {
    return Io.Clock.awake.now(sync_io()).nanoseconds;
}

/// Monotonic time in nanoseconds; does not advance while the system sleeps. Under a test scheduler
/// this is its fake clock (GPUI `executor.now()`).
pub fn now_ns() u64 {
    if (builtin.is_test) if (test_clock_ns) |t| return t;
    return @intCast(real_now_ns());
}

/// Blocks the calling thread.
pub fn sleep_ns(duration_ns: u64) void {
    sync_io().sleep(.fromNanoseconds(@intCast(duration_ns)), .awake) catch {};
}

fn oom() noreturn {
    @panic("out of memory");
}

/// How soon a background task runs (GPUI `Priority`). When workers are free, higher
/// priorities are taken first. `RealtimeAudio` is not ported: it needs a dedicated OS
/// thread with realtime scheduling, which no ZUI platform sets up.
pub const Priority = enum { high, medium, low };

fn ReturnType(comptime f: anytype) type {
    return @typeInfo(@TypeOf(f)).@"fn".return_type.?;
}

// ---------------------------------------------------------------------------
// Runnables and queues.

/// A type-erased unit of work on a worker, timer or main-thread queue.
pub const Runnable = struct {
    next: ?*Runnable = null,
    /// Timer deadline in clock nanoseconds (see `timer_now`). Unused by other queues.
    deadline: i96 = 0,
    /// Runs the work when `execute` is true; otherwise only frees its resources.
    run_fn: *const fn (*Runnable, execute: bool) void,

    pub fn run(self: *Runnable, execute: bool) void {
        self.run_fn(self, execute);
    }
};

/// Intrusive FIFO of `Runnable`s. Not thread-safe; callers hold a mutex.
pub const RunQueue = struct {
    head: ?*Runnable = null,
    tail: ?*Runnable = null,

    pub fn push(q: *RunQueue, r: *Runnable) void {
        r.next = null;
        if (q.tail) |t| t.next = r else q.head = r;
        q.tail = r;
    }

    pub fn pop(q: *RunQueue) ?*Runnable {
        const r = q.head orelse return null;
        q.head = r.next;
        if (q.head == null) q.tail = null;
        r.next = null;
        return r;
    }

    /// Inserts `r` keeping the queue ordered by `deadline` (for timers). Equal deadlines keep their
    /// insertion order.
    pub fn push_sorted(q: *RunQueue, r: *Runnable) void {
        const first = q.head orelse return q.push(r);
        if (r.deadline < first.deadline) {
            r.next = first;
            q.head = r;
            return;
        }
        var prev = first;
        while (prev.next) |n| {
            if (n.deadline > r.deadline) break;
            prev = n;
        }
        r.next = prev.next;
        prev.next = r;
        if (r.next == null) q.tail = r;
    }
};

// ---------------------------------------------------------------------------
// Task state.

/// Runs on the thread that polls a foreground task while it waits.
const Pump = struct {
    ctx: *anyopaque,
    /// Runs queued main-thread work and returns how many items ran.
    run: *const fn (ctx: *anyopaque) usize,
};

/// Shared state between a `Task` handle and the runnable that fulfils it.
/// Freed when both have released it.
fn TaskState(comptime T: type) type {
    return struct {
        const S = @This();

        allocator: std.mem.Allocator,
        /// The handle plus the runnable.
        refs: std.atomic.Value(u32) = .init(2),
        /// 0 until the result is stored, then 1. Also the futex word.
        done: std.atomic.Value(u32) = .init(0),
        cancelled: std.atomic.Value(bool) = .init(false),
        /// Set by `detach_and_log_err`: an error result is logged when the task completes.
        log_on_completion: std.atomic.Value(bool) = .init(false),
        /// Whoever flips this first logs the error. Completion and detaching can race.
        logged: std.atomic.Value(bool) = .init(false),
        pump: ?Pump = null,
        /// The scheduler whose work completes this task, if it was spawned under one. Waits then
        /// run that scheduler instead of blocking.
        sched: Attached = not_attached,
        result: T = undefined,

        fn create(allocator: std.mem.Allocator, sched: Attached) *S {
            const s = allocator.create(S) catch oom();
            s.* = .{ .allocator = allocator, .sched = sched };
            return s;
        }

        /// Stores the result and wakes waiters. Called once, by the runnable.
        fn complete(self: *S, value: T) void {
            self.result = value;
            self.done.store(1, .seq_cst);
            sync_io().futexWake(u32, &self.done.raw, std.math.maxInt(u32));
            if (self.log_on_completion.load(.seq_cst)) self.log_error_once();
        }

        /// Logs the result if it is an error and nobody has logged it yet. Only called once the
        /// result is stored.
        fn log_error_once(self: *S) void {
            if (@typeInfo(T) != .error_union) return;
            if (self.logged.cmpxchgStrong(false, true, .seq_cst, .seq_cst) != null) return;
            if (self.result) |_| {} else |err| log_task_error(err);
        }

        fn release(self: *S) void {
            if (self.refs.fetchSub(1, .acq_rel) == 1) self.allocator.destroy(self);
        }
    };
}

fn wait_until_done(comptime S: type, s: *S) void {
    if (builtin.is_test) if (s.sched) |sched| return sched.block_until_done(&s.done);
    const io = sync_io();
    while (s.done.load(.acquire) == 0) {
        if (s.pump) |p| {
            if (p.run(p.ctx) > 0) continue;
            // Nothing to run yet. Background threads may queue more work
            // without waking us, so re-check periodically.
            io.futexWaitTimeout(u32, &s.done.raw, 0, .{ .duration = .{
                .raw = .fromNanoseconds(std.time.ns_per_ms),
                .clock = .awake,
            } }) catch {};
        } else {
            io.futexWaitUncancelable(u32, &s.done.raw, 0);
        }
    }
}

/// Like `wait_until_done`, but gives up after `timeout_ns`. Returns whether the task completed.
fn wait_until_done_for(s: anytype, timeout_ns: u64) bool {
    if (builtin.is_test) if (s.sched) |sched| return sched.block_until_done_for(&s.done, timeout_ns);
    const io = sync_io();
    const deadline = now_ns() +| timeout_ns;
    while (s.done.load(.acquire) == 0) {
        const now = now_ns();
        if (now >= deadline) return false;
        var slice = deadline - now;
        // Background threads may queue main-thread work without waking us, so a waiter that
        // pumps re-checks every millisecond.
        if (s.pump) |p| {
            if (p.run(p.ctx) > 0) continue;
            slice = @min(slice, std.time.ns_per_ms);
        }
        io.futexWaitTimeout(u32, &s.done.raw, 0, .{ .duration = .{
            .raw = .fromNanoseconds(@intCast(slice)),
            .clock = .awake,
        } }) catch {};
    }
    return true;
}

/// Where `detach_and_log_err` reports an error. It logs by default. The test runner fails any test
/// that logs an error, so tests replace this to count the errors instead.
pub var task_error_sink: *const fn (err: anyerror) void = log_error_sink;

fn log_error_sink(err: anyerror) void {
    std.log.err("task failed: {s}", .{@errorName(err)});
}

fn log_task_error(err: anyerror) void {
    task_error_sink(err);
}

/// Handle to a running computation (GPUI `Task<T>`).
///
/// A task is move-only. `get` and `wait` consume the result. Dropping a task
/// without calling `detach` cancels it: `deinit` is `cancel`.
pub fn Task(comptime T: type) type {
    return struct {
        const Self = @This();
        /// The result type (GPUI `Task<T>`'s `T`).
        pub const Value = T;
        const State = TaskState(T);

        state: ?*State = null,
        /// Result of a task that is already complete (`ready`).
        ready_value: ?T = null,

        /// An already-completed task (GPUI `Task::ready`).
        pub fn ready(value: T) Self {
            return .{ .ready_value = value };
        }

        /// Whether the result is available.
        pub fn is_ready(self: *const Self) bool {
            if (self.state) |s| return s.done.load(.acquire) != 0;
            return self.ready_value != null;
        }

        /// Takes the result if it is available, without blocking.
        pub fn get(self: *Self) ?T {
            if (self.state) |s| {
                if (s.done.load(.acquire) == 0) return null;
                const v = s.result;
                self.drop_handle();
                return v;
            }
            const v = self.ready_value orelse return null;
            self.ready_value = null;
            return v;
        }

        /// Blocks until the result is available and takes it. On a foreground
        /// task called from the main thread, this runs queued main-thread work
        /// while it waits.
        pub fn wait(self: *Self) T {
            if (self.state) |s| {
                wait_until_done(State, s);
                const v = s.result;
                self.drop_handle();
                return v;
            }
            const v = self.ready_value orelse @panic("Task result already taken");
            self.ready_value = null;
            return v;
        }

        /// Waits up to `timeout_ns` for the result without taking it. Returns whether it is ready.
        pub fn wait_for(self: *Self, timeout_ns: u64) bool {
            if (self.state) |s| return wait_until_done_for(s, timeout_ns);
            return self.ready_value != null;
        }

        /// Cancels the task. A task that has not started is skipped; a running one
        /// finishes but its result is discarded.
        pub fn cancel(self: *Self) void {
            if (self.state) |s| s.cancelled.store(true, .release);
            self.drop_handle();
        }

        /// Lets the task run to completion in the background, discarding its result.
        pub fn detach(self: *Self) void {
            self.drop_handle();
        }

        /// Same as `cancel`; dropping a task cancels it.
        pub const deinit = cancel;

        /// Runs the task to completion in the background and logs its error if it fails
        /// (GPUI `TaskExt::detach_and_log_err`). Only exists for tasks whose result is an error
        /// union. The error is logged once, when the task completes.
        pub const detach_and_log_err = if (@typeInfo(T) == .error_union) detach_and_log_err_impl else {};

        fn detach_and_log_err_impl(self: *Self) void {
            if (self.state) |s| {
                s.log_on_completion.store(true, .seq_cst);
                // The task may have completed before the flag was set. The claim makes sure
                // only one side logs.
                if (s.done.load(.seq_cst) != 0) s.log_error_once();
            } else if (self.ready_value) |v| {
                if (v) |_| {} else |err| log_task_error(err);
            }
            self.drop_handle();
        }

        fn drop_handle(self: *Self) void {
            if (self.state) |s| s.release();
            self.state = null;
            self.ready_value = null;
        }
    };
}

// ---------------------------------------------------------------------------
// Spawn nodes.

/// Runnable that calls `f(args...)` and completes a `TaskState`.
fn SpawnNode(comptime f: anytype, comptime Args: type, comptime R: type) type {
    return struct {
        const Node = @This();
        runnable: Runnable,
        state: *TaskState(R),
        args: Args,

        fn run(r: *Runnable, execute: bool) void {
            const node: *Node = @fieldParentPtr("runnable", r);
            const state = node.state;
            if (execute and !state.cancelled.load(.acquire)) {
                state.complete(@call(.auto, f, node.args));
            }
            state.allocator.destroy(node);
            state.release();
        }
    };
}

fn spawn_node(
    comptime f: anytype,
    args: anytype,
    allocator: std.mem.Allocator,
    sched: Attached,
) struct { *Runnable, *TaskState(ReturnType(f)) } {
    const R = ReturnType(f);
    const Node = SpawnNode(f, @TypeOf(args), R);
    const state = TaskState(R).create(allocator, sched);
    const node = allocator.create(Node) catch oom();
    node.* = .{
        .runnable = .{ .run_fn = Node.run },
        .state = state,
        .args = args,
    };
    return .{ &node.runnable, state };
}

/// The result of `BackgroundExecutor.block_with_timeout` (GPUI `Result<R, impl Future>`).
pub fn BlockWithTimeout(comptime T: type, comptime TaskT: type) type {
    return union(enum) {
        /// The task finished in time.
        ok: T,
        /// Still running. The task is handed back, and can be waited on again.
        pending: TaskT,
    };
}

/// A heap job that calls `f(args...)` and drops its result, for work spawned on a `Scope`. The
/// job frees itself when it has run.
fn Discard(comptime f: anytype, comptime Args: type) type {
    return struct {
        const Job = @This();
        allocator: std.mem.Allocator,
        args: Args,

        fn run(job: *Job) void {
            defer job.allocator.destroy(job);
            _ = @call(.auto, f, job.args);
        }
    };
}

/// Tasks spawned on a `Scope` are all waited for when `BackgroundExecutor.scoped` returns
/// (GPUI `Scope`). The arguments are copied, so they may point into the caller's stack.
pub const Scope = struct {
    executor: *BackgroundExecutor,
    priority: Priority,
    tasks: std.ArrayList(Task(void)) = .empty,

    /// How many CPUs are available to the dispatcher.
    pub fn num_cpus(self: *const Scope) usize {
        return self.executor.num_cpus();
    }

    /// Runs `f(args...)` on a worker thread. Its result is discarded. Unlike GPUI's closure, this
    /// takes a function and its arguments.
    pub fn spawn(self: *Scope, comptime f: anytype, args: anytype) void {
        const Job = Discard(f, @TypeOf(args));
        const allocator = self.executor.pool.allocator;
        const job = allocator.create(Job) catch oom();
        job.* = .{ .allocator = allocator, .args = args };
        const t = self.executor.spawn_with_priority(self.priority, Job.run, .{job});
        self.tasks.append(allocator, t) catch oom();
    }

    fn wait_all(self: *Scope) void {
        for (self.tasks.items) |*t| t.wait();
        self.tasks.deinit(self.executor.pool.allocator);
    }
};

// ---------------------------------------------------------------------------
// Background pool.

const Pool = struct {
    allocator: std.mem.Allocator,
    thread_count: usize,
    mutex: Io.Mutex = .init,
    /// Signalled when work is queued or on shutdown.
    cond: Io.Condition = .init,
    /// Signalled when a timer is added or on shutdown.
    timer_cond: Io.Condition = .init,
    /// One FIFO per `Priority`, indexed by `@intFromEnum`.
    queues: [3]RunQueue = .{ .{}, .{}, .{} },
    timers: RunQueue = .{},
    shutdown: bool = false,
    started: bool = false,
    threads: []std.Thread = &.{},
    timer_thread: ?std.Thread = null,
    /// The thread that created the app, which is the platform's main thread.
    main_thread: std.Thread.Id = undefined,
    /// Set in tests that run the app deterministically: work and timers go to the scheduler.
    test_sched: Attached = not_attached,

    /// The clock timers are measured against: the fake clock under a test scheduler, else the awake
    /// clock. The timer thread compares with the awake clock, so only attached pools may use the fake one.
    fn timer_now(self: *const Pool) i96 {
        if (builtin.is_test) if (self.test_sched) |s| return @intCast(s.now());
        return real_now_ns();
    }

    /// Queues work at `priority`. Starts the workers on first use.
    fn submit(self: *Pool, r: *Runnable, priority: Priority) void {
        if (builtin.is_test) if (self.test_sched) |s| return s.schedule_background(r, priority);
        const io = sync_io();
        self.mutex.lockUncancelable(io);
        if (!self.started) self.start_workers();
        if (self.threads.len == 0) {
            self.mutex.unlock(io);
            // No thread could be created: run inline so the task still completes.
            r.run(true);
            return;
        }
        self.queues[@backingInt(priority)].push(r);
        self.mutex.unlock(io);
        self.cond.signal(io);
    }

    /// Takes the runnable of the highest priority that has one. Caller holds the mutex.
    fn pop_next(self: *Pool) ?*Runnable {
        for (&self.queues) |*q| {
            if (q.pop()) |r| return r;
        }
        return null;
    }

    fn has_work(self: *const Pool) bool {
        for (self.queues) |q| {
            if (q.head != null) return true;
        }
        return false;
    }

    /// Queues a timer. `r.deadline` is the time it fires at, on the clock `timer_now` reads.
    fn submit_timer(self: *Pool, r: *Runnable) void {
        if (builtin.is_test) if (self.test_sched) |s| return s.add_timer(r);
        const io = sync_io();
        self.mutex.lockUncancelable(io);
        if (self.timer_thread == null) {
            self.timer_thread = std.Thread.spawn(.{}, timer_main, .{self}) catch
                @panic("failed to spawn timer thread");
        }
        self.timers.push_sorted(r);
        self.mutex.unlock(io);
        self.timer_cond.signal(io);
    }

    fn start_workers(self: *Pool) void {
        self.started = true;
        const threads = self.allocator.alloc(std.Thread, self.thread_count) catch oom();
        var n: usize = 0;
        while (n < threads.len) : (n += 1) {
            threads[n] = std.Thread.spawn(.{}, worker_main, .{self}) catch break;
        }
        self.threads = threads[0..n];
        if (n == 0) self.allocator.free(threads);
    }

    fn worker_main(self: *Pool) void {
        const io = sync_io();
        while (true) {
            self.mutex.lockUncancelable(io);
            while (!self.has_work() and !self.shutdown) {
                self.cond.waitUncancelable(io, &self.mutex);
            }
            const r = self.pop_next();
            self.mutex.unlock(io);
            // Queue empty and shutting down: exit.
            const job = r orelse return;
            job.run(true);
        }
    }

    fn timer_main(self: *Pool) void {
        const io = sync_io();
        self.mutex.lockUncancelable(io);
        while (true) {
            if (self.timers.head) |t| {
                const now = Io.Clock.awake.now(io).nanoseconds;
                if (t.deadline <= now or self.shutdown) {
                    _ = self.timers.pop();
                    self.mutex.unlock(io);
                    t.run(true);
                    self.mutex.lockUncancelable(io);
                    continue;
                }
                const remaining = t.deadline - now;
                self.timer_cond.waitTimeout(io, &self.mutex, .{ .duration = .{
                    .raw = .fromNanoseconds(remaining),
                    .clock = .awake,
                } }) catch {};
            } else {
                if (self.shutdown) break;
                self.timer_cond.waitUncancelable(io, &self.mutex);
            }
        }
        self.mutex.unlock(io);
    }

    /// Stops the threads after the queued work has run, then frees the pool.
    fn destroy(self: *Pool) void {
        if (builtin.is_test) if (self.test_sched) |s| {
            s.drain_background();
            self.allocator.destroy(self);
            return;
        };
        const io = sync_io();
        self.mutex.lockUncancelable(io);
        self.shutdown = true;
        self.mutex.unlock(io);
        self.cond.broadcast(io);
        self.timer_cond.broadcast(io);
        for (self.threads) |t| t.join();
        if (self.timer_thread) |t| t.join();
        if (self.threads.len > 0) self.allocator.free(self.threads);
        self.allocator.destroy(self);
    }
};

// ---------------------------------------------------------------------------
// Main thread queue.

const ForegroundCore = struct {
    allocator: std.mem.Allocator,
    mutex: Io.Mutex = .init,
    queue: RunQueue = .{},
    wake_ctx: ?*anyopaque = null,
    wake_fn: ?*const fn (*anyopaque) void = null,
    /// Set in tests that run the app deterministically: this queue is then a session of the scheduler.
    test_sched: Attached = not_attached,

    /// Thread-safe. Queues `r` and wakes the platform loop.
    fn enqueue(self: *ForegroundCore, r: *Runnable) void {
        if (builtin.is_test) if (self.test_sched) |s| {
            s.schedule_foreground(self, r);
            self.wake();
            return;
        };
        const io = sync_io();
        self.mutex.lockUncancelable(io);
        self.queue.push(r);
        self.mutex.unlock(io);
        self.wake();
    }

    fn wake(self: *ForegroundCore) void {
        if (self.wake_fn) |f| f(self.wake_ctx.?);
    }

    /// Runs the work queued before this call. Work queued while running waits
    /// for the next call.
    fn run_pending(self: *ForegroundCore) usize {
        // Under a test scheduler every ready task runs, background ones too, as GPUI's `run_until_parked`.
        if (builtin.is_test) if (self.test_sched) |s| return s.run_until_parked();
        const io = sync_io();
        self.mutex.lockUncancelable(io);
        var batch = self.queue;
        self.queue = .{};
        self.mutex.unlock(io);
        var n: usize = 0;
        while (batch.pop()) |r| : (n += 1) r.run(true);
        return n;
    }

    fn has_pending(self: *ForegroundCore) bool {
        if (builtin.is_test) if (self.test_sched) |s| return s.has_session_work(self);
        const io = sync_io();
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        return self.queue.head != null;
    }

    fn pump_thunk(ctx: *anyopaque) usize {
        const self: *ForegroundCore = @ptrCast(@alignCast(ctx));
        return self.run_pending();
    }

    /// Drops pending work without running it, releasing its resources.
    fn drop_pending(self: *ForegroundCore) void {
        if (builtin.is_test) if (self.test_sched) |s| return s.drop_session(self);
        const io = sync_io();
        self.mutex.lockUncancelable(io);
        var batch = self.queue;
        self.queue = .{};
        self.mutex.unlock(io);
        while (batch.pop()) |r| r.run(false);
    }
};

fn WakeThunk(comptime P: type) type {
    return struct {
        fn wake(ctx: *anyopaque) void {
            const p: P = @ptrCast(@alignCast(ctx));
            p.wake();
        }
    };
}

// ---------------------------------------------------------------------------
// Executors.

/// Runs work on background threads (GPUI `BackgroundExecutor`).
pub const BackgroundExecutor = struct {
    pool: *Pool,

    /// Creates the executor. Threads start on the first spawn.
    /// `platform` is accepted for GPUI parity and not used.
    pub fn init(allocator: std.mem.Allocator, platform: anytype) BackgroundExecutor {
        _ = platform;
        const pool = allocator.create(Pool) catch oom();
        pool.* = .{
            .allocator = allocator,
            .thread_count = std.Thread.getCpuCount() catch 1,
            .main_thread = std.Thread.getCurrentId(),
        };
        return .{ .pool = pool };
    }

    /// Waits for queued work and timers, then stops the worker threads.
    pub fn deinit(self: *BackgroundExecutor) void {
        self.pool.destroy();
    }

    /// Runs `f(args...)` on a worker thread.
    pub fn spawn(self: *BackgroundExecutor, comptime f: anytype, args: anytype) Task(ReturnType(f)) {
        return self.spawn_with_priority(.medium, f, args);
    }

    /// Runs `f(args...)` on a worker thread, taking it before lower-priority work that is queued.
    pub fn spawn_with_priority(self: *BackgroundExecutor, priority: Priority, comptime f: anytype, args: anytype) Task(ReturnType(f)) {
        const r, const state = spawn_node(f, args, self.pool.allocator, self.pool.test_sched);
        self.pool.submit(r, priority);
        return .{ .state = state };
    }

    /// Whether the calling thread is the one that created the app (GPUI `is_main_thread`).
    pub fn is_main_thread(self: *const BackgroundExecutor) bool {
        return std.Thread.getCurrentId() == self.pool.main_thread;
    }

    /// Calls `scheduler(ctx, scope)`, then waits for every task it spawned before returning, so the
    /// tasks may borrow from the caller's stack (GPUI `scoped`). Zig has no closures, so the state
    /// the scheduler needs goes in `ctx` (pass `{}` for none). Tasks get medium priority.
    pub fn scoped(self: *BackgroundExecutor, ctx: anytype, comptime scheduler: anytype) void {
        self.scoped_priority(.medium, ctx, scheduler);
    }

    /// Like `scoped`, with the priority given to every task spawned on the scope (GPUI `scoped_priority`).
    pub fn scoped_priority(self: *BackgroundExecutor, priority: Priority, ctx: anytype, comptime scheduler: anytype) void {
        var scope: Scope = .{ .executor = self, .priority = priority };
        defer scope.wait_all();
        scheduler(ctx, &scope);
    }

    /// Runs `work(args...)` on a worker, then `on_done(ctx, result)` on the main
    /// thread of `fg`. The returned task completes after `on_done` runs.
    pub fn spawn_then(
        self: *BackgroundExecutor,
        fg: *ForegroundExecutor,
        comptime work: anytype,
        args: anytype,
        comptime on_done: anytype,
        ctx: anytype,
    ) Task(ReturnType(on_done)) {
        const W = ReturnType(work);
        const R = ReturnType(on_done);
        const Ctx = @TypeOf(ctx);
        const Then = struct {
            const Node = @This();
            bg: Runnable,
            fg_run: Runnable,
            fg_core: *ForegroundCore,
            state: *TaskState(R),
            args: @TypeOf(args),
            ctx: Ctx,
            value: W = undefined,

            fn run_bg(r: *Runnable, execute: bool) void {
                const node: *Node = @fieldParentPtr("bg", r);
                if (!execute or node.state.cancelled.load(.acquire)) {
                    free(node);
                    return;
                }
                node.value = @call(.auto, work, node.args);
                // The node now belongs to the main-thread runnable.
                node.fg_core.enqueue(&node.fg_run);
            }

            fn run_fg(r: *Runnable, execute: bool) void {
                const node: *Node = @fieldParentPtr("fg_run", r);
                if (execute and !node.state.cancelled.load(.acquire)) {
                    node.state.complete(@call(.auto, on_done, .{ node.ctx, node.value }));
                }
                free(node);
            }

            fn free(node: *Node) void {
                const state = node.state;
                state.allocator.destroy(node);
                state.release();
            }
        };

        const state = TaskState(R).create(self.pool.allocator, self.pool.test_sched);
        state.pump = .{ .ctx = fg.core, .run = ForegroundCore.pump_thunk };
        const node = self.pool.allocator.create(Then) catch oom();
        node.* = .{
            .bg = .{ .run_fn = Then.run_bg },
            .fg_run = .{ .run_fn = Then.run_fg },
            .fg_core = fg.core,
            .state = state,
            .args = args,
            .ctx = ctx,
        };
        self.pool.submit(&node.bg, .medium);
        return .{ .state = state };
    }

    /// Returns a task that completes after `duration_ns` nanoseconds. It may
    /// complete later if the machine is busy.
    pub fn timer(self: *BackgroundExecutor, duration_ns: u64) Task(void) {
        if (duration_ns == 0) return Task(void).ready({});
        const Fire = struct {
            fn fire() void {}
        };
        const r, const state = spawn_node(Fire.fire, .{}, self.pool.allocator, self.pool.test_sched);
        const at = self.pool.timer_now();
        r.deadline = at + @as(i96, @intCast(duration_ns));
        self.pool.submit_timer(r);
        return .{ .state = state };
    }

    /// Runs `on_done(ctx)` on the main thread once `duration_ns` has passed. Timers cannot
    /// be cancelled, so `on_done` must check whether it still applies.
    pub fn after(self: *BackgroundExecutor, fg: *ForegroundExecutor, duration_ns: u64, comptime on_done: anytype, ctx: anytype) void {
        const Ctx = @TypeOf(ctx);
        const Node = struct {
            const NodeT = @This();
            timer: Runnable,
            fg_run: Runnable,
            fg_core: *ForegroundCore,
            ctx: Ctx,
            allocator: std.mem.Allocator,

            fn on_timer(r: *Runnable, execute: bool) void {
                const node: *NodeT = @fieldParentPtr("timer", r);
                if (!execute) return node.allocator.destroy(node);
                node.fg_core.enqueue(&node.fg_run);
            }
            fn on_main(r: *Runnable, execute: bool) void {
                const node: *NodeT = @fieldParentPtr("fg_run", r);
                if (execute) on_done(node.ctx);
                node.allocator.destroy(node);
            }
        };
        const allocator = self.pool.allocator;
        const node = allocator.create(Node) catch oom();
        node.* = .{
            .timer = .{ .run_fn = Node.on_timer },
            .fg_run = .{ .run_fn = Node.on_main },
            .fg_core = fg.core,
            .ctx = ctx,
            .allocator = allocator,
        };
        const at = self.pool.timer_now();
        node.timer.deadline = at + @as(i96, @intCast(duration_ns));
        self.pool.submit_timer(&node.timer);
    }

    /// Waits for `task` on the calling thread and returns its result. Consumes `task`. On the main
    /// thread, queued main-thread work runs while it waits (GPUI `block_on`, which takes a future).
    pub fn block_on(self: *BackgroundExecutor, task: anytype) @TypeOf(task).Value {
        _ = self;
        var t = task;
        return t.wait();
    }

    /// Waits up to `timeout_ns` for `task`. Returns its result, or hands the task back still
    /// running (GPUI `block_with_timeout`, which returns `Err(future)`).
    pub fn block_with_timeout(self: *BackgroundExecutor, timeout_ns: u64, task: anytype) BlockWithTimeout(@TypeOf(task).Value, @TypeOf(task)) {
        _ = self;
        var t = task;
        if (t.wait_for(timeout_ns)) return .{ .ok = t.wait() };
        return .{ .pending = t };
    }

    /// Number of CPUs, used as the worker count. A test scheduler reports its override (GPUI default 4).
    pub fn num_cpus(self: *const BackgroundExecutor) usize {
        if (builtin.is_test) if (self.pool.test_sched) |s| return s.num_cpus();
        return self.pool.thread_count;
    }

    /// The current time: the fake clock under a test scheduler (GPUI `now`).
    pub fn now(self: *const BackgroundExecutor) u64 {
        return @intCast(self.pool.timer_now());
    }

    /// Whether this executor runs on a test scheduler (GPUI `is_test`).
    pub fn is_test(self: *const BackgroundExecutor) bool {
        if (builtin.is_test) return self.pool.test_sched != null;
        return false;
    }

    fn attached_scheduler(self: *const BackgroundExecutor) *TestScheduler {
        if (!builtin.is_test) @compileError("test scheduler calls need a test build");
        return self.pool.test_sched orelse @panic("this executor is not a test executor; use TestAppContext.build");
    }

    /// Moves the fake clock forward by `duration_ns`, running what comes due on the way in time
    /// order (GPUI `advance_clock`).
    pub fn advance_clock(self: *BackgroundExecutor, duration_ns: u64) void {
        self.attached_scheduler().advance_clock(duration_ns);
    }

    /// Runs one ready task, or fires due timers first. Returns false when there was nothing to do
    /// (GPUI `tick`).
    pub fn tick(self: *BackgroundExecutor) bool {
        return self.attached_scheduler().tick();
    }

    /// Runs ready tasks until none is left. Timers stay where they are (GPUI `run_until_parked`).
    pub fn run_until_parked(self: *BackgroundExecutor) void {
        _ = self.attached_scheduler().run_until_parked();
    }

    /// Lets other work run for a random number of ticks, from the seed (GPUI `simulate_random_delay`,
    /// which is a future there and runs now here).
    pub fn simulate_random_delay(self: *BackgroundExecutor) void {
        self.attached_scheduler().simulate_random_delay();
    }

    /// Lets a blocked wait park: the test waits for another thread to queue work (GPUI `allow_parking`).
    pub fn allow_parking(self: *BackgroundExecutor) void {
        self.attached_scheduler().allow_parking();
    }

    /// A blocked wait that nothing can finish panics instead of parking (GPUI `forbid_parking`).
    pub fn forbid_parking(self: *BackgroundExecutor) void {
        self.attached_scheduler().forbid_parking();
    }

    /// How many ticks `block_with_timeout` may run, drawn from `min..=max` (GPUI `set_block_on_ticks`).
    pub fn set_block_on_ticks(self: *BackgroundExecutor, min: usize, max: usize) void {
        self.attached_scheduler().set_block_on_ticks(min, max);
    }

    /// The seeded generator that orders the work. Test data drawn from it repeats for a seed
    /// (GPUI `rng`).
    pub fn rng(self: *BackgroundExecutor) std.Random {
        return self.attached_scheduler().rng();
    }

    /// Overrides `num_cpus` for this test (GPUI `set_num_cpus`).
    pub fn set_num_cpus(self: *BackgroundExecutor, count: usize) void {
        self.attached_scheduler().set_num_cpus(count);
    }
};

/// Runs work on the main thread (GPUI `ForegroundExecutor`). Work is drained by
/// `run_pending`, which the platform run loop calls each turn.
pub const ForegroundExecutor = struct {
    /// The owning app. Type-erased to keep this file independent of app.zig.
    app: ?*anyopaque = null,
    core: *ForegroundCore,

    /// Creates the executor. `platform` may be a pointer whose type has a
    /// `wake()` method; it is called when work is queued from another thread.
    pub fn init(allocator: std.mem.Allocator, platform: anytype) ForegroundExecutor {
        const core = allocator.create(ForegroundCore) catch oom();
        core.* = .{ .allocator = allocator };
        const P = @TypeOf(platform);
        if (@typeInfo(P) == .pointer and @hasDecl(@typeInfo(P).pointer.child, "wake")) {
            core.wake_ctx = @ptrCast(platform);
            core.wake_fn = WakeThunk(P).wake;
        }
        return .{ .core = core };
    }

    /// Drops pending work without running it and frees the queue. Outstanding
    /// tasks from this executor must not be used afterwards.
    pub fn deinit(self: *ForegroundExecutor) void {
        self.core.drop_pending();
        self.core.allocator.destroy(self.core);
    }

    /// Queues `f(args...)` to run on the main thread at the next `run_pending`.
    pub fn spawn(self: *ForegroundExecutor, comptime f: anytype, args: anytype) Task(ReturnType(f)) {
        const r, const state = spawn_node(f, args, self.core.allocator, self.core.test_sched);
        state.pump = .{ .ctx = self.core, .run = ForegroundCore.pump_thunk };
        self.core.enqueue(r);
        return .{ .state = state };
    }

    /// Queues `f(args...)` on the main thread. The priority is ignored: foreground work runs in
    /// order, as in GPUI.
    pub fn spawn_with_priority(self: *ForegroundExecutor, priority: Priority, comptime f: anytype, args: anytype) Task(ReturnType(f)) {
        _ = priority;
        return self.spawn(f, args);
    }

    /// Queues `f(args...)` for the main thread's idle time (GPUI `spawn_when_idle`). ZUI cannot
    /// meter idle time on any platform yet, so this is ordinary main-thread work, and `timeout` is
    /// ignored. GPUI does the same on platforms without idle support.
    pub fn spawn_when_idle(self: *ForegroundExecutor, timeout_ns: ?u64, comptime f: anytype, args: anytype) Task(ReturnType(f)) {
        _ = timeout_ns;
        return self.spawn(f, args);
    }

    /// Time left in the current idle slice (GPUI `idle_time_remaining`). Null, because idle time
    /// is not metered, which GPUI reports the same way.
    pub fn idle_time_remaining(self: *const ForegroundExecutor) ?u64 {
        _ = self;
        return null;
    }

    /// Whether this executor runs on a test scheduler (GPUI `is_test`).
    pub fn is_test(self: *const ForegroundExecutor) bool {
        if (builtin.is_test) return self.core.test_sched != null;
        return false;
    }

    /// Waits for `task` on the test thread, running the scheduler meanwhile (GPUI `block_test`). Under
    /// a test scheduler this is the same wait as `BackgroundExecutor.block_on`; it panics otherwise.
    pub fn block_test(self: *ForegroundExecutor, task: anytype) @TypeOf(task).Value {
        if (!builtin.is_test) @compileError("block_test needs a test build");
        if (self.core.test_sched == null) @panic("block_test needs a test scheduler");
        var t = task;
        return t.wait();
    }

    /// A handle that can queue main-thread work from any thread (GPUI `SendForegroundExecutor`).
    pub fn to_send(self: *const ForegroundExecutor) SendForegroundExecutor {
        return .{ .core = self.core };
    }

    /// Runs the work queued so far on the main thread. Returns how many items ran.
    /// Call from the main thread (the platform run loop).
    pub fn run_pending(self: *ForegroundExecutor) usize {
        return self.core.run_pending();
    }

    /// Whether any main-thread work is queued.
    pub fn has_pending(self: *ForegroundExecutor) bool {
        return self.core.has_pending();
    }

    /// Thread-safe. Calls `func(ctx)` on the main thread at the next `run_pending`.
    pub fn dispatch_on_main(self: *ForegroundExecutor, ctx: *anyopaque, func: *const fn (*anyopaque) void) void {
        const Dispatch = struct {
            runnable: Runnable,
            allocator: std.mem.Allocator,
            ctx: *anyopaque,
            func: *const fn (*anyopaque) void,

            fn run(r: *Runnable, execute: bool) void {
                const node: *@This() = @fieldParentPtr("runnable", r);
                if (execute) node.func(node.ctx);
                node.allocator.destroy(node);
            }
        };
        const allocator = self.core.allocator;
        const node = allocator.create(Dispatch) catch oom();
        node.* = .{
            .runnable = .{ .run_fn = Dispatch.run },
            .allocator = allocator,
            .ctx = ctx,
            .func = func,
        };
        self.core.enqueue(&node.runnable);
    }
};

/// A foreground executor that can be used from any thread (GPUI `SendForegroundExecutor`). Work
/// still runs on the main thread, at its next `run_pending`. Its tasks are not pumped by `wait`:
/// a thread that waits on one blocks until the main thread runs it.
pub const SendForegroundExecutor = struct {
    core: *ForegroundCore,

    pub fn spawn(self: SendForegroundExecutor, comptime f: anytype, args: anytype) Task(ReturnType(f)) {
        const r, const state = spawn_node(f, args, self.core.allocator, self.core.test_sched);
        self.core.enqueue(r);
        return .{ .state = state };
    }
};

/// Makes `bg` and `fg` run on `sched` instead of threads, so the app runs deterministically (GPUI
/// `TestDispatcher`). Both executors must belong to the same app, and nothing may be queued yet.
/// Test builds only.
pub fn attach_test_scheduler(bg: *BackgroundExecutor, fg: *ForegroundExecutor, sched: *TestScheduler) void {
    if (!builtin.is_test) @compileError("attach_test_scheduler needs a test build");
    bg.pool.test_sched = sched;
    fg.core.test_sched = sched;
}

// ---------------------------------------------------------------------------
// Tests.

const testing = std.testing;

fn add(a: i32, b: i32) i32 {
    return a + b;
}

fn slow_square(x: u64) u64 {
    return x * x;
}

test "background spawn and wait" {
    var bg = BackgroundExecutor.init(testing.allocator, {});
    defer bg.deinit();
    var t = bg.spawn(add, .{ 2, 3 });
    try testing.expectEqual(@as(i32, 5), t.wait());
}

test "background spawn with error union result" {
    const Fail = struct {
        fn f(fail: bool) error{Boom}!u8 {
            if (fail) return error.Boom;
            return 7;
        }
    };
    var bg = BackgroundExecutor.init(testing.allocator, {});
    defer bg.deinit();
    var ok = bg.spawn(Fail.f, .{false});
    try testing.expectEqual(@as(u8, 7), try ok.wait());
    var bad = bg.spawn(Fail.f, .{true});
    try testing.expectError(error.Boom, bad.wait());
}

test "many background tasks" {
    var bg = BackgroundExecutor.init(testing.allocator, {});
    defer bg.deinit();
    const n = 1000;
    var tasks: [n]Task(u64) = undefined;
    for (&tasks, 0..) |*t, i| t.* = bg.spawn(slow_square, .{@as(u64, i)});
    var sum: u64 = 0;
    for (&tasks) |*t| sum += t.wait();
    var expected: u64 = 0;
    for (0..n) |i| expected += @as(u64, i) * i;
    try testing.expectEqual(expected, sum);
}

test "get is non-blocking and consumes the result" {
    var bg = BackgroundExecutor.init(testing.allocator, {});
    defer bg.deinit();
    const Gate = struct {
        fn wait_then_one(flag: *std.atomic.Value(bool)) i32 {
            while (!flag.load(.acquire)) std.Thread.yield() catch {};
            return 1;
        }
    };
    var flag = std.atomic.Value(bool).init(false);
    var t = bg.spawn(Gate.wait_then_one, .{&flag});
    try testing.expectEqual(@as(?i32, null), t.get());
    try testing.expect(!t.is_ready());
    flag.store(true, .release);
    try testing.expectEqual(@as(i32, 1), t.wait());
    try testing.expectEqual(@as(?i32, null), t.get());
}

test "ready task" {
    var t = Task(i32).ready(3);
    try testing.expect(t.is_ready());
    try testing.expectEqual(@as(i32, 3), t.wait());
}

test "block_on waits for a task" {
    var bg = BackgroundExecutor.init(testing.allocator, {});
    defer bg.deinit();
    try testing.expectEqual(@as(i32, 9), bg.block_on(bg.spawn(add, .{ 4, 5 })));
}

test "block_with_timeout returns the result when it is in time" {
    var bg = BackgroundExecutor.init(testing.allocator, {});
    defer bg.deinit();
    switch (bg.block_with_timeout(5 * std.time.ns_per_s, bg.spawn(add, .{ 1, 2 }))) {
        .ok => |v| try testing.expectEqual(@as(i32, 3), v),
        .pending => return error.TestUnexpectedResult,
    }
}

test "block_with_timeout hands back a task that is still running" {
    var bg = BackgroundExecutor.init(testing.allocator, {});
    defer bg.deinit();
    const Gate = struct {
        fn wait_for_flag(flag: *std.atomic.Value(bool)) i32 {
            while (!flag.load(.acquire)) sleep_ns(100 * std.time.ns_per_us);
            return 11;
        }
    };
    var flag = std.atomic.Value(bool).init(false);
    const t = bg.spawn(Gate.wait_for_flag, .{&flag});
    var pending = switch (bg.block_with_timeout(2 * std.time.ns_per_ms, t)) {
        .ok => return error.TestUnexpectedResult,
        .pending => |task| task,
    };
    // The handed-back task is still the same computation: it finishes once released.
    flag.store(true, .release);
    try testing.expectEqual(@as(i32, 11), pending.wait());
}

test "scoped waits for every task before it returns" {
    var bg = BackgroundExecutor.init(testing.allocator, {});
    defer bg.deinit();
    const Bump = struct {
        fn run(counter: *std.atomic.Value(u32), by: u32) void {
            sleep_ns(200 * std.time.ns_per_us);
            _ = counter.fetchAdd(by, .seq_cst);
        }
    };
    var counter = std.atomic.Value(u32).init(0);
    const Scheduler = struct {
        fn schedule(c: *std.atomic.Value(u32), scope: *Scope) void {
            var i: u32 = 1;
            while (i <= 8) : (i += 1) scope.spawn(Bump.run, .{ c, i });
        }
    };
    bg.scoped_priority(.high, &counter, Scheduler.schedule);
    // Every task borrowed `counter` from this stack frame, and all of them have run.
    try testing.expectEqual(@as(u32, 36), counter.load(.seq_cst));
}

test "is_main_thread is true here and false on a worker" {
    var bg = BackgroundExecutor.init(testing.allocator, {});
    defer bg.deinit();
    const Probe = struct {
        fn on_worker(e: *BackgroundExecutor) bool {
            return e.is_main_thread();
        }
    };
    try testing.expect(bg.is_main_thread());
    try testing.expect(!bg.block_on(bg.spawn(Probe.on_worker, .{&bg})));
}

test "priority: the queue hands out higher priorities first" {
    // A pool whose workers never start: its queues are inspected directly.
    var pool: Pool = .{ .allocator = testing.allocator, .thread_count = 0 };
    var low: Runnable = .{ .run_fn = undefined };
    var medium: Runnable = .{ .run_fn = undefined };
    var high: Runnable = .{ .run_fn = undefined };
    pool.queues[@backingInt(Priority.low)].push(&low);
    pool.queues[@backingInt(Priority.medium)].push(&medium);
    pool.queues[@backingInt(Priority.high)].push(&high);
    try testing.expectEqual(&high, pool.pop_next().?);
    try testing.expectEqual(&medium, pool.pop_next().?);
    try testing.expectEqual(&low, pool.pop_next().?);
    try testing.expectEqual(@as(?*Runnable, null), pool.pop_next());
}

test "spawn_with_priority runs the work" {
    var bg = BackgroundExecutor.init(testing.allocator, {});
    defer bg.deinit();
    try testing.expectEqual(@as(i32, 7), bg.block_on(bg.spawn_with_priority(.high, add, .{ 3, 4 })));
    try testing.expectEqual(@as(i32, 9), bg.block_on(bg.spawn_with_priority(.low, add, .{ 4, 5 })));
}

test "detach_and_log_err reports an error once, when the task fails" {
    var bg = BackgroundExecutor.init(testing.allocator, {});
    defer bg.deinit();
    const Fail = struct {
        fn f(fail: bool) error{Boom}!u8 {
            if (fail) return error.Boom;
            return 1;
        }
    };
    const Count = struct {
        var reported: std.atomic.Value(usize) = .init(0);
        fn sink(err: anyerror) void {
            std.testing.expectEqualStrings("Boom", @errorName(err)) catch unreachable;
            _ = reported.fetchAdd(1, .seq_cst);
        }
    };
    const saved = task_error_sink;
    task_error_sink = Count.sink;
    defer task_error_sink = saved;
    Count.reported.store(0, .seq_cst);
    const before = Count.reported.load(.seq_cst);
    // A task that succeeds logs nothing.
    var ok = bg.spawn(Fail.f, .{false});
    ok.detach_and_log_err();
    // A ready error is logged at once.
    var ready = Task(error{Boom}!u8).ready(error.Boom);
    ready.detach_and_log_err();
    try testing.expectEqual(before + 1, Count.reported.load(.seq_cst));
    // A failing background task is logged when it completes. Wait for that, with a bound.
    var failing = bg.spawn(Fail.f, .{true});
    failing.detach_and_log_err();
    var waited: u64 = 0;
    while (Count.reported.load(.seq_cst) < before + 2 and waited < 5 * std.time.ns_per_s) {
        sleep_ns(std.time.ns_per_ms);
        waited += std.time.ns_per_ms;
    }
    try testing.expectEqual(before + 2, Count.reported.load(.seq_cst));
}

test "foreground spawn_when_idle runs on run_pending and has no idle budget" {
    var fg = ForegroundExecutor.init(testing.allocator, {});
    defer fg.deinit();
    try testing.expectEqual(@as(?u64, null), fg.idle_time_remaining());
    var t = fg.spawn_when_idle(null, add, .{ 2, 2 });
    try testing.expect(!t.is_ready());
    _ = fg.run_pending();
    try testing.expectEqual(@as(?i32, 4), t.get());
}

test "SendForegroundExecutor queues work from another thread" {
    var fg = ForegroundExecutor.init(testing.allocator, {});
    defer fg.deinit();
    const send = fg.to_send();
    const Off = struct {
        fn spawn_from(s: SendForegroundExecutor, out: *?Task(i32)) void {
            out.* = s.spawn(add, .{ 20, 22 });
        }
    };
    var slot: ?Task(i32) = null;
    const thread = try std.Thread.spawn(.{}, Off.spawn_from, .{ send, &slot });
    thread.join();
    try testing.expect(fg.has_pending());
    _ = fg.run_pending();
    try testing.expectEqual(@as(i32, 42), slot.?.get().?);
}

test "foreground spawn and run_pending" {
    var fg = ForegroundExecutor.init(testing.allocator, {});
    defer fg.deinit();
    var t = fg.spawn(add, .{ 40, 2 });
    try testing.expect(!t.is_ready());
    try testing.expect(fg.has_pending());
    try testing.expectEqual(@as(usize, 1), fg.run_pending());
    try testing.expect(!fg.has_pending());
    try testing.expectEqual(@as(?i32, 42), t.get());
}

test "foreground wait pumps the main-thread queue" {
    var fg = ForegroundExecutor.init(testing.allocator, {});
    defer fg.deinit();
    var t = fg.spawn(slow_square, .{12});
    try testing.expectEqual(@as(u64, 144), t.wait());
}

test "foreground cancel skips the work" {
    var fg = ForegroundExecutor.init(testing.allocator, {});
    defer fg.deinit();
    const Count = struct {
        var runs: usize = 0;
        fn bump() void {
            runs += 1;
        }
    };
    Count.runs = 0;
    var t = fg.spawn(Count.bump, .{});
    t.cancel();
    _ = fg.run_pending();
    try testing.expectEqual(@as(usize, 0), Count.runs);
}

test "spawn_then delivers the result on the main thread" {
    var bg = BackgroundExecutor.init(testing.allocator, {});
    defer bg.deinit();
    var fg = ForegroundExecutor.init(testing.allocator, {});
    defer fg.deinit();

    const Work = struct {
        fn double(x: i32) i32 {
            return x * 2;
        }
        fn on_done(out: *i32, v: i32) void {
            out.* = v;
        }
    };
    var out: i32 = 0;
    var t = bg.spawn_then(&fg, Work.double, .{21}, Work.on_done, &out);
    // `wait` on the main thread runs `on_done` before returning.
    t.wait();
    try testing.expectEqual(@as(i32, 42), out);
}

test "spawn_then result is seen by run_pending on the main thread" {
    var bg = BackgroundExecutor.init(testing.allocator, {});
    defer bg.deinit();
    var fg = ForegroundExecutor.init(testing.allocator, {});
    defer fg.deinit();

    const Work = struct {
        fn make(x: u32) u32 {
            return x + 1;
        }
        fn on_done(out: *u32, v: u32) void {
            out.* = v;
        }
    };
    var out: u32 = 0;
    var t = bg.spawn_then(&fg, Work.make, .{9}, Work.on_done, &out);
    while (!t.is_ready()) {
        _ = fg.run_pending();
        std.Thread.yield() catch {};
    }
    try testing.expectEqual(@as(u32, 10), out);
    t.detach();
}

test "timer completes after its duration" {
    var bg = BackgroundExecutor.init(testing.allocator, {});
    defer bg.deinit();
    const start = Io.Clock.awake.now(sync_io()).nanoseconds;
    var t = bg.timer(5 * std.time.ns_per_ms);
    try testing.expect(!t.is_ready());
    t.wait();
    const elapsed = Io.Clock.awake.now(sync_io()).nanoseconds - start;
    try testing.expect(elapsed >= 5 * std.time.ns_per_ms);
}

test "zero timer is ready" {
    var bg = BackgroundExecutor.init(testing.allocator, {});
    defer bg.deinit();
    var t = bg.timer(0);
    try testing.expect(t.is_ready());
    t.wait();
}

test "detached task runs to completion" {
    var bg = BackgroundExecutor.init(testing.allocator, {});
    const Flag = struct {
        fn set(flag: *std.atomic.Value(u32)) void {
            flag.store(1, .release);
        }
    };
    var flag = std.atomic.Value(u32).init(0);
    var detached = bg.spawn(Flag.set, .{&flag});
    detached.detach();
    // Dropping the executor waits for queued work, so the detached task has run.
    bg.deinit();
    try testing.expectEqual(@as(u32, 1), flag.load(.acquire));
}

test "cancel before run releases resources" {
    var bg = BackgroundExecutor.init(testing.allocator, {});
    defer bg.deinit();
    var tasks: [64]Task(i32) = undefined;
    for (&tasks) |*t| t.* = bg.spawn(add, .{ 1, 1 });
    for (&tasks) |*t| t.cancel();
}

test "dispatch_on_main calls back on run_pending and wakes the platform" {
    const Fake = struct {
        woke: usize = 0,
        pub fn wake(self: *@This()) void {
            self.woke += 1;
        }
    };
    var platform: Fake = .{};
    var fg = ForegroundExecutor.init(testing.allocator, &platform);
    defer fg.deinit();

    const Cb = struct {
        fn run(ctx: *anyopaque) void {
            const n: *usize = @ptrCast(@alignCast(ctx));
            n.* += 1;
        }
    };
    var calls: usize = 0;
    fg.dispatch_on_main(&calls, Cb.run);
    fg.dispatch_on_main(&calls, Cb.run);
    try testing.expectEqual(@as(usize, 2), platform.woke);
    try testing.expectEqual(@as(usize, 2), fg.run_pending());
    try testing.expectEqual(@as(usize, 2), calls);
}

test "num_cpus is at least one" {
    var bg = BackgroundExecutor.init(testing.allocator, {});
    defer bg.deinit();
    try testing.expect(bg.num_cpus() >= 1);
}
