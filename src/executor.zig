//! Port of GPUI `executor.rs`, `platform_scheduler.rs` and the main-thread
//! queue of `platform/threaded_dispatcher.rs`: a background worker pool, a
//! main-thread run queue drained by the platform loop, timers, and `Task`
//! handles.
//!
//! Zig has no async/await, so a foreground task is a deferred main-thread
//! callback whose result is stored in its `Task`, and a background task is a
//! plain function run on a worker thread.

const std = @import("std");
const Io = std.Io;

// ---------------------------------------------------------------------------
// Synchronization. Zig 0.17 implements mutexes, condition variables and futexes
// on top of `std.Io`. The single-threaded Io instance is enough here: it only
// uses the kernel futex and sleep calls, never its own thread pool.

var sync_threaded: Io.Threaded = Io.Threaded.init_single_threaded;

fn sync_io() Io {
    return sync_threaded.io();
}

fn oom() noreturn {
    @panic("out of memory");
}

fn ReturnType(comptime f: anytype) type {
    return @typeInfo(@TypeOf(f)).@"fn".return_type.?;
}

// ---------------------------------------------------------------------------
// Runnables and queues.

/// A type-erased unit of work on a worker, timer or main-thread queue.
const Runnable = struct {
    next: ?*Runnable = null,
    /// Timer deadline in awake-clock nanoseconds. Unused by other queues.
    deadline: i96 = 0,
    /// Runs the work when `execute` is true; otherwise only frees its resources.
    run_fn: *const fn (*Runnable, execute: bool) void,

    fn run(self: *Runnable, execute: bool) void {
        self.run_fn(self, execute);
    }
};

/// Intrusive FIFO of `Runnable`s. Not thread-safe; callers hold a mutex.
const RunQueue = struct {
    head: ?*Runnable = null,
    tail: ?*Runnable = null,

    fn push(q: *RunQueue, r: *Runnable) void {
        r.next = null;
        if (q.tail) |t| t.next = r else q.head = r;
        q.tail = r;
    }

    fn pop(q: *RunQueue) ?*Runnable {
        const r = q.head orelse return null;
        q.head = r.next;
        if (q.head == null) q.tail = null;
        r.next = null;
        return r;
    }

    /// Inserts `r` keeping the queue ordered by `deadline` (for timers).
    fn push_sorted(q: *RunQueue, r: *Runnable) void {
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
        pump: ?Pump = null,
        result: T = undefined,

        fn create(allocator: std.mem.Allocator) *S {
            const s = allocator.create(S) catch oom();
            s.* = .{ .allocator = allocator };
            return s;
        }

        /// Stores the result and wakes waiters. Called once, by the runnable.
        fn complete(self: *S, value: T) void {
            self.result = value;
            self.done.store(1, .release);
            sync_io().futexWake(u32, &self.done.raw, std.math.maxInt(u32));
        }

        fn release(self: *S) void {
            if (self.refs.fetchSub(1, .acq_rel) == 1) self.allocator.destroy(self);
        }
    };
}

fn wait_until_done(comptime S: type, s: *S) void {
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
) struct { *Runnable, *TaskState(ReturnType(f)) } {
    const R = ReturnType(f);
    const Node = SpawnNode(f, @TypeOf(args), R);
    const state = TaskState(R).create(allocator);
    const node = allocator.create(Node) catch oom();
    node.* = .{
        .runnable = .{ .run_fn = Node.run },
        .state = state,
        .args = args,
    };
    return .{ &node.runnable, state };
}

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
    queue: RunQueue = .{},
    timers: RunQueue = .{},
    shutdown: bool = false,
    started: bool = false,
    threads: []std.Thread = &.{},
    timer_thread: ?std.Thread = null,

    /// Queues work. Starts the workers on first use.
    fn submit(self: *Pool, r: *Runnable) void {
        const io = sync_io();
        self.mutex.lockUncancelable(io);
        if (!self.started) self.start_workers();
        if (self.threads.len == 0) {
            self.mutex.unlock(io);
            // No thread could be created: run inline so the task still completes.
            r.run(true);
            return;
        }
        self.queue.push(r);
        self.mutex.unlock(io);
        self.cond.signal(io);
    }

    /// Queues a timer. `r.deadline` is the awake-clock time it fires at.
    fn submit_timer(self: *Pool, r: *Runnable) void {
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
            while (self.queue.head == null and !self.shutdown) {
                self.cond.waitUncancelable(io, &self.mutex);
            }
            const r = self.queue.pop();
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

    /// Thread-safe. Queues `r` and wakes the platform loop.
    fn enqueue(self: *ForegroundCore, r: *Runnable) void {
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
        };
        return .{ .pool = pool };
    }

    /// Waits for queued work and timers, then stops the worker threads.
    pub fn deinit(self: *BackgroundExecutor) void {
        self.pool.destroy();
    }

    /// Runs `f(args...)` on a worker thread.
    pub fn spawn(self: *BackgroundExecutor, comptime f: anytype, args: anytype) Task(ReturnType(f)) {
        const r, const state = spawn_node(f, args, self.pool.allocator);
        self.pool.submit(r);
        return .{ .state = state };
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

        const state = TaskState(R).create(self.pool.allocator);
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
        self.pool.submit(&node.bg);
        return .{ .state = state };
    }

    /// Returns a task that completes after `duration_ns` nanoseconds. It may
    /// complete later if the machine is busy.
    pub fn timer(self: *BackgroundExecutor, duration_ns: u64) Task(void) {
        if (duration_ns == 0) return Task(void).ready({});
        const Fire = struct {
            fn fire() void {}
        };
        const r, const state = spawn_node(Fire.fire, .{}, self.pool.allocator);
        const now = Io.Clock.awake.now(sync_io()).nanoseconds;
        r.deadline = now + @as(i96, @intCast(duration_ns));
        self.pool.submit_timer(r);
        return .{ .state = state };
    }

    /// Waits for `task` on the calling thread and returns its result. Consumes `task`.
    pub fn block(self: *BackgroundExecutor, task: anytype) @TypeOf(task).Value {
        _ = self;
        var t = task;
        return t.wait();
    }

    /// Number of CPUs, used as the worker count.
    pub fn num_cpus(self: *const BackgroundExecutor) usize {
        return self.pool.thread_count;
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
        const r, const state = spawn_node(f, args, self.core.allocator);
        state.pump = .{ .ctx = self.core, .run = ForegroundCore.pump_thunk };
        self.core.enqueue(r);
        return .{ .state = state };
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

test "block waits for a task" {
    var bg = BackgroundExecutor.init(testing.allocator, {});
    defer bg.deinit();
    try testing.expectEqual(@as(i32, 9), bg.block(bg.spawn(add, .{ 4, 5 })));
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
