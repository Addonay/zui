//! Port of GPUI's deterministic test scheduler (`crates/scheduler/src/test_scheduler.rs`, with the
//! test dispatcher of `gpui/src/platform/test/dispatcher.rs`).
//!
//! A test attaches a `TestScheduler` to its app's executors (`TestAppContext.build`). From then on
//! every background and foreground task runs on the test thread, in an order drawn from a seeded
//! generator, and every timer waits on a fake clock that moves only when the test moves it. The same
//! seed gives the same order. Nothing here is reachable outside test builds: `executor.zig` holds no
//! scheduler otherwise.
//!
//! Zig has no futures, so GPUI's calls on a future are calls on the task itself: a `Task.wait` on a
//! test scheduler runs the scheduler until the task is done (GPUI `block`).

const std = @import("std");
const Io = std.Io;
const executor = @import("executor.zig");
const Runnable = executor.Runnable;
const RunQueue = executor.RunQueue;
const Priority = executor.Priority;

/// Where the fake clock starts: a second in, so a deadline of zero is never already due.
pub const start_ns: u64 = std.time.ns_per_s;
/// How long a parked wait may last before it counts as a deadlock (GPUI's 15 second hard limit).
const park_limit_ns: u64 = 15 * std.time.ns_per_s;
/// How long one parked step sleeps. The fake clock moves on by the same amount.
const park_step_ns: u64 = std.time.ns_per_ms;

const Entry = struct {
    runnable: *Runnable,
    /// The foreground session (its `ForegroundCore`) the work belongs to, or null for background work.
    session: ?*anyopaque,
    priority: Priority,
};

pub const TestScheduler = struct {
    allocator: std.mem.Allocator,
    /// Guards the fields below. Other threads may queue work while the test thread runs the scheduler.
    mutex: Io.Mutex = .init,
    random_state: std.Random.DefaultPrng,
    /// Work that is ready to run, in the order it was queued. `step` chooses from it by seed.
    ready: std.ArrayList(Entry) = .empty,
    /// Timers, ordered by deadline. Equal deadlines keep the order they were set in.
    timers: RunQueue = .{},
    /// Whether a blocked wait may park (sleep, and let other threads queue work) instead of failing.
    may_park: bool = false,
    block_ticks_min: usize = 0,
    block_ticks_max: usize = 1000,
    /// Set by `set_num_cpus`. Zero means no override.
    num_cpus_override: usize = 0,

    /// Creates a scheduler and starts the fake clock. Only one may run at a time, since the clock is
    /// process-wide (`executor.test_clock_ns`).
    pub fn init(allocator: std.mem.Allocator, seed: u64) *TestScheduler {
        if (executor.test_clock_ns != null) @panic("a test scheduler is already running");
        const self = allocator.create(TestScheduler) catch @panic("out of memory");
        self.* = .{ .allocator = allocator, .random_state = std.Random.DefaultPrng.init(seed) };
        executor.test_clock_ns = start_ns;
        return self;
    }

    /// Frees the scheduler and stops the fake clock. Work still queued is dropped unrun, as a task
    /// dropped before it ran is.
    pub fn deinit(self: *TestScheduler) void {
        self.lock();
        var ready = self.ready;
        self.ready = .empty;
        var timers = self.timers;
        self.timers = .{};
        self.unlock();
        for (ready.items) |e| e.runnable.run(false);
        ready.deinit(self.allocator);
        while (timers.pop()) |t| t.run(false);
        executor.test_clock_ns = null;
        self.allocator.destroy(self);
    }

    fn lock(self: *TestScheduler) void {
        self.mutex.lockUncancelable(executor.sync_io());
    }

    fn unlock(self: *TestScheduler) void {
        self.mutex.unlock(executor.sync_io());
    }

    /// The fake clock, in nanoseconds (GPUI `clock().now()`).
    pub fn now(self: *const TestScheduler) u64 {
        _ = self;
        return executor.test_clock_ns.?;
    }

    fn set_clock(ns: u64) void {
        executor.test_clock_ns = ns;
    }

    // -----------------------------------------------------------------------
    // Queueing. These are the entry points the executors call (GPUI `Scheduler`).

    /// Queues background work. Thread-safe.
    pub fn schedule_background(self: *TestScheduler, r: *Runnable, priority: Priority) void {
        self.lock();
        defer self.unlock();
        self.ready.append(self.allocator, .{ .runnable = r, .session = null, .priority = priority }) catch @panic("out of memory");
    }

    /// Queues main-thread work for `session` (GPUI `schedule_local`). Thread-safe.
    pub fn schedule_foreground(self: *TestScheduler, session: *anyopaque, r: *Runnable) void {
        self.lock();
        defer self.unlock();
        self.ready.append(self.allocator, .{ .runnable = r, .session = session, .priority = .medium }) catch @panic("out of memory");
    }

    /// Queues a timer. `r.deadline` is the fake time it is due at. Thread-safe.
    pub fn add_timer(self: *TestScheduler, r: *Runnable) void {
        self.lock();
        defer self.unlock();
        self.timers.push_sorted(r);
    }

    // -----------------------------------------------------------------------
    // Running.

    /// Runs one unit of work: due timers first move to the ready work, then one ready task runs,
    /// chosen by the seed (GPUI `tick`). Returns false when there was nothing to do.
    pub fn tick(self: *TestScheduler) bool {
        return self.step(false);
    }

    /// Like `tick`, but runs background work only (GPUI `tick_background_only`). Used when a
    /// background executor shuts down: the foreground work belongs to an app that is going away.
    pub fn tick_background_only(self: *TestScheduler) bool {
        return self.step(true);
    }

    fn step(self: *TestScheduler, background_only: bool) bool {
        self.lock();
        const at = self.now();
        var expired = false;
        while (self.timers.head) |t| {
            if (t.deadline > @as(i96, @intCast(at))) break;
            _ = self.timers.pop();
            self.ready.append(self.allocator, .{ .runnable = t, .session = null, .priority = .medium }) catch @panic("out of memory");
            expired = true;
        }
        const index = self.pick(background_only) orelse {
            self.unlock();
            return expired;
        };
        const entry = self.ready.orderedRemove(index);
        self.unlock();
        entry.runnable.run(true);
        return true;
    }

    /// Chooses the next ready entry. Any background entry is a candidate, but of each foreground
    /// session only its first entry, so a session runs in order. Candidates are weighted by priority
    /// (GPUI `step_filtered`). The caller holds the lock.
    fn pick(self: *TestScheduler, background_only: bool) ?usize {
        var total: u32 = 0;
        for (self.ready.items, 0..) |e, i| {
            if (self.is_candidate(i, background_only)) total += weight(e.priority);
        }
        if (total == 0) return null;
        var target = self.random_state.random().uintLessThan(u32, total);
        for (self.ready.items, 0..) |e, i| {
            if (!self.is_candidate(i, background_only)) continue;
            const w = weight(e.priority);
            if (target < w) return i;
            target -= w;
        }
        unreachable;
    }

    fn is_candidate(self: *const TestScheduler, index: usize, background_only: bool) bool {
        const e = self.ready.items[index];
        const session = e.session orelse return true;
        if (background_only) return false;
        for (self.ready.items[0..index]) |earlier| {
            if (earlier.session == session) return false;
        }
        return true;
    }

    /// GPUI's `Priority::weight`: how often a priority wins a pick.
    fn weight(p: Priority) u32 {
        return switch (p) {
            .high => 60,
            .medium => 30,
            .low => 10,
        };
    }

    /// Runs ready work until none is left (GPUI `run`). Timers that are not due stay where they are.
    /// Returns how many steps ran.
    pub fn run_until_parked(self: *TestScheduler) usize {
        var ran: usize = 0;
        while (self.tick()) ran += 1;
        return ran;
    }

    /// Moves the fake clock forward by `duration_ns`. Work that comes due on the way runs in time
    /// order: the clock stops at each timer that is due before the target, and what it released runs
    /// there (GPUI `advance_clock`).
    pub fn advance_clock(self: *TestScheduler, duration_ns: u64) void {
        const target = self.now() +| duration_ns;
        while (true) {
            _ = self.run_until_parked();
            const next = self.next_deadline() orelse break;
            if (next > target) break;
            set_clock(next);
        }
        set_clock(target);
        _ = self.run_until_parked();
    }

    /// Jumps the clock to the next timer, if there is one. Returns whether there was one (GPUI
    /// `advance_clock_to_next_timer`).
    pub fn advance_clock_to_next_timer(self: *TestScheduler) bool {
        const next = self.next_deadline() orelse return false;
        if (next > self.now()) set_clock(next);
        return true;
    }

    fn next_deadline(self: *TestScheduler) ?u64 {
        self.lock();
        defer self.unlock();
        const t = self.timers.head orelse return null;
        return @intCast(t.deadline);
    }

    /// Lets other work run for a random number of ticks, drawn from the seed (GPUI
    /// `simulate_random_delay`). The GPUI future yields 0 to 2 times, or 10 to 19 times with
    /// probability 1/10; here each yield is one tick.
    pub fn simulate_random_delay(self: *TestScheduler) void {
        const count = blk: {
            self.lock();
            defer self.unlock();
            const r = self.random_state.random();
            if (r.uintLessThan(u32, 10) == 0) break :blk 10 + r.uintLessThan(usize, 10);
            break :blk r.uintLessThan(usize, 2);
        };
        for (0..count) |_| {
            if (!self.tick()) break;
        }
    }

    /// Background teardown, as `BackgroundExecutor` drop does: background work runs and every timer
    /// fires, moving the clock to each. Foreground work stays queued, for its executor to drop, since
    /// its app may already be gone.
    pub fn drain_background(self: *TestScheduler) void {
        while (true) {
            while (self.tick_background_only()) {}
            if (!self.advance_clock_to_next_timer()) break;
        }
    }

    /// Drops the work queued for `session` without running it (`ForegroundExecutor` drop).
    pub fn drop_session(self: *TestScheduler, session: *anyopaque) void {
        self.lock();
        var kept: std.ArrayList(Entry) = .empty;
        var dropped: std.ArrayList(*Runnable) = .empty;
        for (self.ready.items) |e| {
            if (e.session == session) {
                dropped.append(self.allocator, e.runnable) catch @panic("out of memory");
            } else {
                kept.append(self.allocator, e) catch @panic("out of memory");
            }
        }
        self.ready.deinit(self.allocator);
        self.ready = kept;
        self.unlock();
        for (dropped.items) |r| r.run(false);
        dropped.deinit(self.allocator);
    }

    /// Whether any work is queued for `session`.
    pub fn has_session_work(self: *TestScheduler, session: *anyopaque) bool {
        self.lock();
        defer self.unlock();
        for (self.ready.items) |e| {
            if (e.session == session) return true;
        }
        return false;
    }

    // -----------------------------------------------------------------------
    // Blocking waits. `Task.wait` and friends call these on a test scheduler.

    /// Runs the scheduler until `done` is set (GPUI `block`). Nothing ready and no timer to jump to
    /// means nothing can finish the task: that panics unless parking is allowed, in which case the
    /// wait sleeps a step and lets other threads queue work.
    pub fn block_until_done(self: *TestScheduler, done: *const std.atomic.Value(u32)) void {
        var parked_ns: u64 = 0;
        while (done.load(.acquire) == 0) {
            if (self.tick()) continue;
            // With parking forbidden, nothing else can happen but a timer, so jump to it. With parking
            // allowed, real time passes instead, as in GPUI.
            if (!self.may_park and self.advance_clock_to_next_timer()) continue;
            self.park(&parked_ns);
        }
    }

    /// Like `block_until_done`, but gives up after `timeout_ns` of fake time, or after the number of
    /// ticks `set_block_on_ticks` draws (GPUI `block_with_timeout`). Returns whether `done` got set.
    pub fn block_until_done_for(self: *TestScheduler, done: *const std.atomic.Value(u32), timeout_ns: u64) bool {
        const deadline = self.now() +| timeout_ns;
        var budget = self.random_ticks();
        while (done.load(.acquire) == 0) {
            if (budget == 0) return false;
            budget -= 1;
            if (self.tick()) continue;
            if (self.next_deadline()) |next| {
                if (next <= deadline) {
                    set_clock(next);
                    continue;
                }
            }
            set_clock(deadline);
            return done.load(.acquire) != 0;
        }
        return true;
    }

    fn random_ticks(self: *TestScheduler) usize {
        self.lock();
        defer self.unlock();
        return self.random_state.random().intRangeAtMost(usize, self.block_ticks_min, self.block_ticks_max);
    }

    /// Sleeps a step while nothing can run, moving the fake clock on with it. Panics unless parking is
    /// allowed, and after GPUI's 15 second limit.
    fn park(self: *TestScheduler, parked_ns: *u64) void {
        if (!self.may_park) @panic("Parking forbidden. The test waits for work that no task in the test scheduler can finish. Call allow_parking if another thread is meant to finish it.");
        if (parked_ns.* >= park_limit_ns) @panic("Test timed out after 15 seconds while parking. This may indicate a deadlock or missing waker.");
        executor.sleep_ns(park_step_ns);
        parked_ns.* += park_step_ns;
        set_clock(self.now() + park_step_ns);
    }

    // -----------------------------------------------------------------------
    // Test controls.

    /// Lets a blocked wait park: a wait may sleep for another thread to queue its work (GPUI
    /// `allow_parking`).
    pub fn allow_parking(self: *TestScheduler) void {
        self.may_park = true;
    }

    /// A blocked wait that nothing can finish panics instead of parking (GPUI `forbid_parking`).
    pub fn forbid_parking(self: *TestScheduler) void {
        self.may_park = false;
    }

    pub fn parking_allowed(self: *const TestScheduler) bool {
        return self.may_park;
    }

    /// The number of ticks `block_until_done_for` may run, drawn from `min..=max` (GPUI
    /// `set_block_on_ticks`, which takes a range).
    pub fn set_block_on_ticks(self: *TestScheduler, min: usize, max: usize) void {
        std.debug.assert(min <= max);
        self.block_ticks_min = min;
        self.block_ticks_max = max;
    }

    /// The seeded generator (GPUI `rng`). Draws repeat for a seed as long as the test makes them in
    /// the same order. Use it on the test thread.
    pub fn rng(self: *TestScheduler) std.Random {
        return self.random_state.random();
    }

    /// Overrides the CPU count the executors report. Zero clears the override (GPUI `set_num_cpus`).
    pub fn set_num_cpus(self: *TestScheduler, count: usize) void {
        self.num_cpus_override = count;
    }

    /// The CPU count the executors report: the override, else 4 as GPUI's test dispatcher does.
    pub fn num_cpus(self: *const TestScheduler) usize {
        return if (self.num_cpus_override == 0) 4 else self.num_cpus_override;
    }
};

// ---------------------------------------------------------------------------
// Tests. Ported from GPUI's scheduler tests and executor tests, plus checks of the fake clock.

const testing = std.testing;
const ms = std.time.ns_per_ms;

fn add(a: i32, b: i32) i32 {
    return a + b;
}

/// Executors on a test scheduler, torn down as `App.deinit` does it: background, then foreground,
/// then the scheduler.
const Rig = struct {
    sched: *TestScheduler,
    bg: executor.BackgroundExecutor,
    fg: executor.ForegroundExecutor,

    fn init(seed: u64) Rig {
        var rig: Rig = .{
            .sched = TestScheduler.init(testing.allocator, seed),
            .bg = executor.BackgroundExecutor.init(testing.allocator, {}),
            .fg = executor.ForegroundExecutor.init(testing.allocator, {}),
        };
        executor.attach_test_scheduler(&rig.bg, &rig.fg, rig.sched);
        return rig;
    }

    fn deinit(self: *Rig) void {
        self.bg.deinit();
        self.fg.deinit();
        self.sched.deinit();
    }
};

/// What ran, in order, written by the tasks under test. Fixed size, so it lives on the test's stack.
const Trace = struct {
    items: [16]u8 = undefined,
    len: usize = 0,

    fn push(self: *Trace, id: u8) void {
        self.items[self.len] = id;
        self.len += 1;
    }

    fn slice(self: *const Trace) []const u8 {
        return self.items[0..self.len];
    }
};

/// A timer's continuation: records its id on the main thread when the timer has fired.
const Mark = struct {
    trace: *Trace,
    id: u8,

    fn fire(self: *Mark) void {
        self.trace.push(self.id);
    }
};

/// Ran tasks in `Trace` order, for the randomized-order tests.
const Record = struct {
    fn background(trace: *Trace, id: u8) void {
        trace.push(id);
    }
    fn foreground(trace: *Trace, id: u8) void {
        trace.push(id);
    }
};

test "timer: not ready before its time, and ready at it" {
    var rig = Rig.init(0);
    defer rig.deinit();
    const start = rig.bg.now();
    var t = rig.bg.timer(100 * ms);
    _ = rig.sched.run_until_parked();
    try testing.expect(!t.is_ready());
    // Work runs without moving the clock, so the timer waits.
    try testing.expectEqual(start, rig.bg.now());
    rig.bg.advance_clock(99 * ms);
    try testing.expect(!t.is_ready());
    try testing.expectEqual(start + 99 * ms, rig.bg.now());
    rig.bg.advance_clock(ms);
    try testing.expect(t.is_ready());
    try testing.expectEqual(start + 100 * ms, rig.bg.now());
    t.wait();
}

test "timers: fire in time order, and equal times in the order they were set" {
    var rig = Rig.init(3);
    defer rig.deinit();
    var trace: Trace = .{};
    var marks = [_]Mark{
        .{ .trace = &trace, .id = 'a' }, // 30 ms
        .{ .trace = &trace, .id = 'b' }, // 10 ms
        .{ .trace = &trace, .id = 'c' }, // 20 ms
        .{ .trace = &trace, .id = 'd' }, // 10 ms
    };
    const delays = [_]u64{ 30 * ms, 10 * ms, 20 * ms, 10 * ms };
    for (&marks, delays) |*m, d| rig.bg.after(&rig.fg, d, Mark.fire, m);
    _ = rig.sched.run_until_parked();
    try testing.expectEqual(@as(usize, 0), trace.len);

    rig.bg.advance_clock(15 * ms);
    // b and d are due together. The seed orders them, but both come before c.
    try testing.expectEqual(@as(usize, 2), trace.len);
    try testing.expect(std.mem.indexOfScalar(u8, trace.slice(), 'b') != null);
    try testing.expect(std.mem.indexOfScalar(u8, trace.slice(), 'd') != null);

    rig.bg.advance_clock(15 * ms);
    try testing.expectEqualStrings("ca", trace.slice()[2..]);
}

test "tick: runs one task at a time, and reports when there is none" {
    var rig = Rig.init(1);
    defer rig.deinit();
    var trace: Trace = .{};
    var first = rig.bg.spawn(Record.background, .{ &trace, 'x' });
    first.detach();
    var second = rig.fg.spawn(Record.foreground, .{ &trace, 'y' });
    second.detach();
    try testing.expect(rig.bg.tick());
    try testing.expectEqual(@as(usize, 1), trace.len);
    try testing.expect(rig.bg.tick());
    try testing.expectEqual(@as(usize, 2), trace.len);
    try testing.expect(!rig.bg.tick());
}

/// Runs three background and three foreground tasks, and returns the order they ran in.
fn run_order(seed: u64) [6]u8 {
    var rig = Rig.init(seed);
    defer rig.deinit();
    var trace: Trace = .{};
    for ([_]u8{ '1', '2', '3' }) |id| {
        var t = rig.bg.spawn(Record.background, .{ &trace, id });
        t.detach();
    }
    for ([_]u8{ 'a', 'b', 'c' }) |id| {
        var t = rig.fg.spawn(Record.foreground, .{ &trace, id });
        t.detach();
    }
    _ = rig.sched.run_until_parked();
    std.debug.assert(trace.len == 6);
    return trace.items[0..6].*;
}

test "order: the same seed gives the same order, and other seeds can give another" {
    const first = run_order(0);
    try testing.expectEqualSlices(u8, &first, &run_order(0));
    var another = false;
    for (1..20) |seed| {
        if (!std.mem.eql(u8, &first, &run_order(seed))) another = true;
    }
    try testing.expect(another);
}

test "foreground: one session runs its tasks in the order they were spawned, for any seed" {
    for (0..10) |seed| {
        var rig = Rig.init(seed);
        defer rig.deinit();
        var trace: Trace = .{};
        for ("0123456789") |id| {
            var t = rig.fg.spawn(Record.foreground, .{ &trace, id });
            t.detach();
        }
        _ = rig.sched.run_until_parked();
        try testing.expectEqualStrings("0123456789", trace.slice());
    }
}

test "wait: runs the scheduler until the task is done" {
    var rig = Rig.init(1);
    defer rig.deinit();
    try testing.expectEqual(@as(i32, 9), rig.bg.block_on(rig.bg.spawn(add, .{ 4, 5 })));
    try testing.expectEqual(@as(i32, 7), rig.fg.block_test(rig.fg.spawn(add, .{ 3, 4 })));
}

test "block_with_timeout: hands back a task that a timer has not finished, and it finishes once the clock reaches it" {
    var rig = Rig.init(2);
    defer rig.deinit();
    const timer = rig.bg.timer(1000 * ms);
    var pending = switch (rig.bg.block_with_timeout(100 * ms, timer)) {
        .ok => return error.TestUnexpectedResult,
        .pending => |t| t,
    };
    try testing.expect(!pending.is_ready());
    rig.bg.advance_clock(1000 * ms);
    try testing.expect(pending.is_ready());
    pending.wait();
}

test "parking: a wait with parking allowed sleeps and moves the clock until the timer is due" {
    var rig = Rig.init(4);
    defer rig.deinit();
    rig.bg.allow_parking();
    try testing.expect(rig.sched.parking_allowed());
    const start = rig.bg.now();
    var t = rig.bg.timer(3 * ms);
    t.wait();
    try testing.expect(rig.bg.now() - start >= 3 * ms);
    rig.bg.forbid_parking();
    try testing.expect(!rig.sched.parking_allowed());
}

test "SendForegroundExecutor: work queued from another thread runs in the scheduler" {
    var rig = Rig.init(5);
    defer rig.deinit();
    const send = rig.fg.to_send();
    const Off = struct {
        fn spawn_from(s: executor.SendForegroundExecutor, out: *?executor.Task(i32)) void {
            out.* = s.spawn(add, .{ 20, 22 });
        }
    };
    var slot: ?executor.Task(i32) = null;
    const thread = try std.Thread.spawn(.{}, Off.spawn_from, .{ send, &slot });
    thread.join();
    try testing.expect(rig.fg.has_pending());
    _ = rig.fg.run_pending();
    try testing.expectEqual(@as(i32, 42), slot.?.get().?);
}

test "teardown: background work and timers run, foreground work is dropped unrun" {
    var rig = Rig.init(6);
    var trace: Trace = .{};
    var mark: Mark = .{ .trace = &trace, .id = 't' };
    rig.bg.after(&rig.fg, 5 * ms, Mark.fire, &mark);
    var fg_task = rig.fg.spawn(Record.foreground, .{ &trace, 'f' });
    fg_task.detach();
    var bg_task = rig.bg.spawn(Record.background, .{ &trace, 'b' });
    bg_task.detach();

    rig.bg.deinit();
    // The background teardown ran the background work, and fired the timer, whose continuation waits
    // on the foreground executor.
    try testing.expectEqualStrings("b", trace.slice());
    try testing.expect(rig.fg.has_pending());
    rig.fg.deinit();
    rig.sched.deinit();
}

test "num_cpus: reports 4 unless overridden" {
    var rig = Rig.init(7);
    defer rig.deinit();
    try testing.expectEqual(@as(usize, 4), rig.bg.num_cpus());
    rig.bg.set_num_cpus(12);
    try testing.expectEqual(@as(usize, 12), rig.bg.num_cpus());
    rig.bg.set_num_cpus(0);
    try testing.expectEqual(@as(usize, 4), rig.bg.num_cpus());
}

test "rng: draws repeat for a seed" {
    // One scheduler at a time: the fake clock is process-wide.
    var first = Rig.init(8);
    const drawn = first.bg.rng().int(u64);
    try testing.expect(first.bg.is_test());
    try testing.expect(first.fg.is_test());
    first.deinit();
    var second = Rig.init(8);
    defer second.deinit();
    try testing.expectEqual(drawn, second.bg.rng().int(u64));
}
