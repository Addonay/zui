//! Port of GPUI's `examples/testing.rs`: a counter window, and the GPUI test patterns from the
//! Rust file as `test` blocks. Run the tests with `zig build test`.
//!
//! Differences from the Rust version:
//! - `example_support::load_fonts` is a no-op on native platforms, so it is not called.
//! - `cx.subscribe_self(f)` is `cx.subscribe(cx.entity(), f)`.
//! - ZUI has no async/await. `load` is a foreground spawn, and `counter.update(cx, load).await` is
//!   `task.wait()`, which runs queued main-thread work while it waits. Side effects still wait
//!   for `run_until_parked`, as in GPUI.
//! - `test_allow_parking` is NOT ported. It checks that GPUI's scheduler panics when a test awaits
//!   something outside its control, and ZUI's executor has no such check. Nothing to allow.
//! - `#[gpui::test(iterations = 10)]` with `StdRng` is a loop over 10 fixed seeds of
//!   `std.Random.DefaultPrng`. GPUI's randomized scheduler is not reproduced, so the interleaving
//!   tests only randomize the order in which the two apps' operations are issued.
//! - The two apps of the distributed tests share one thread, so the mock network needs no lock.
//!   GPUI sends from `background_spawn`; here the send is a foreground task that runs on
//!   `run_until_parked`, which keeps the same ordering as seen by the test.
//! - The trace printed by `test_random_interleaving` (`--nocapture`) is not printed.

const std = @import("std");
const gpui = @import("zui");
const App = gpui.App;
const AsyncApp = gpui.AsyncApp;
const Bounds = gpui.Bounds;
const ClickEvent = gpui.ClickEvent;
const Context = gpui.Context;
const Div = gpui.Div;
const Entity = gpui.Entity;
const FocusHandle = gpui.FocusHandle;
const KeyBinding = gpui.KeyBinding;
const Pixels = gpui.Pixels;
const Subscription = gpui.Subscription;
const Task = gpui.Task;
const TestAppContext = gpui.TestAppContext;
const VisualTestContext = gpui.VisualTestContext;
const Window = gpui.Window;
const WindowOptions = gpui.WindowOptions;
const WeakEntity = gpui.WeakEntity;
const div = gpui.div;
const px = gpui.px;
const rgb = gpui.rgb;
const size = gpui.size;

const Increment = gpui.Action("counter", "Increment");
const Decrement = gpui.Action("counter", "Decrement");

/// Event emitted by Counter
const CounterEvent = struct {};

const Counter = struct {
    pub const Event = CounterEvent;

    count: i32,
    focus_handle: FocusHandle,
    _subscription: Subscription,

    fn init(cx: *Context(Counter)) Counter {
        const subscription = cx.subscribe(cx.entity(), on_counter_event);

        return .{
            .count = 0,
            .focus_handle = cx.focus_handle(),
            ._subscription = subscription,
        };
    }

    fn on_counter_event(this: *Counter, _: anytype, _: *const CounterEvent, _: *Context(Counter)) void {
        this.count = 999;
    }

    fn increment(self: *Counter, _: *const Increment, _: *Window, cx: *Context(Counter)) void {
        self.count += 1;
        cx.notify();
    }

    fn decrement(self: *Counter, _: *const Decrement, _: *Window, cx: *Context(Counter)) void {
        self.count -= 1;
        cx.notify();
    }

    fn load(self: *Counter, cx: *Context(Counter)) Task(void) {
        _ = self;
        return cx.spawn(load_task, .{});
    }

    fn load_task(this: WeakEntity(Counter), cx: *AsyncApp) void {
        // Simulate loading data (e.g., from disk or network)
        this.update(cx, set_count, .{100}) catch {};
    }

    fn reload(self: *Counter, cx: *Context(Counter)) void {
        _ = self;
        // Simulate reloading data in the background
        var task = cx.spawn(reload_task, .{});
        task.detach();
    }

    fn reload_task(this: WeakEntity(Counter), cx: *AsyncApp) void {
        this.update(cx, add_count, .{50}) catch {};
    }

    fn set_count(self: *Counter, value: i32, _: *Context(Counter)) void {
        self.count = value;
    }

    fn add_count(self: *Counter, delta: i32, _: *Context(Counter)) void {
        self.count += delta;
    }

    fn emit_event(_: *Counter, cx: *Context(Counter)) void {
        cx.emit(.{});
    }

    fn on_decrement_click(self: *Counter, _: *const ClickEvent, window: *Window, cx: *Context(Counter)) void {
        self.decrement(&Decrement{}, window, cx);
    }

    fn on_increment_click(self: *Counter, _: *const ClickEvent, window: *Window, cx: *Context(Counter)) void {
        self.increment(&Increment{}, window, cx);
    }

    fn on_load_click(self: *Counter, _: *const ClickEvent, _: *Window, cx: *Context(Counter)) void {
        var task = self.load(cx);
        task.detach();
    }

    fn on_reload_click(self: *Counter, _: *const ClickEvent, _: *Window, cx: *Context(Counter)) void {
        self.reload(cx);
    }

    fn button(id: []const u8, label: []const u8) *Div {
        return div()
            .id(id)
            .px_4()
            .py_2()
            .bg(rgb(0x313244))
            .hover(gpui.style_refinement().bg(rgb(0x45475a)))
            .rounded_md()
            .cursor_pointer()
            .text_color(rgb(0xcdd6f4))
            .child(label);
    }

    pub fn render(self: *Counter, _: *Window, cx: *Context(Counter)) *Div {
        return div()
            .id("counter")
            .key_context("Counter")
            .on_action(Increment, cx.listener(Counter.increment))
            .on_action(Decrement, cx.listener(Counter.decrement))
            .track_focus(&self.focus_handle)
            .flex()
            .flex_col()
            .gap_4()
            .bg(rgb(0x1e1e2e))
            .size_full()
            .justify_center()
            .items_center()
            .child(
                div()
                    .text_3xl()
                    .text_color(rgb(0xcdd6f4))
                    .child(gpui.format("{d}", .{self.count})),
            )
            .child(
                div()
                    .flex()
                    .gap_2()
                    .child(button("decrement", "−").on_click(cx.listener(Counter.on_decrement_click)))
                    .child(button("increment", "+").on_click(cx.listener(Counter.on_increment_click))),
            )
            .child(
                div()
                    .flex()
                    .gap_2()
                    .child(button("load", "Load").on_click(cx.listener(Counter.on_load_click)))
                    .child(button("reload", "Reload").on_click(cx.listener(Counter.on_reload_click))),
            )
            .child(
                div()
                    .text_sm()
                    .text_color(rgb(0x6c7086))
                    .child("Press ↑/↓ or click buttons"),
            );
    }
};

fn build_root(window: *Window, app: *App) Entity(Counter) {
    const counter = app.new(Counter.init);
    counter.read(app).focus_handle.focus(window);
    return counter;
}

fn run_example(cx: *App) void {
    // example_support::load_fonts is not ported (no TextSystem::add_fonts yet).
    cx.bind_keys(&.{
        KeyBinding.new("up", Increment{}, "Counter"),
        KeyBinding.new("down", Decrement{}, "Counter"),
    });

    const bounds = Bounds(Pixels).centered(null, size(px(300.0), px(200.0)), cx);
    _ = cx.open_window(WindowOptions{
        .window_bounds = .{ .windowed = bounds },
    }, build_root) catch unreachable;
}

pub fn main() void {
    gpui.Application.new().run(run_example);
}

// -- Tests --------------------------------------------------------------------

// Here's a basic GPUI test. Just add the macro and take a TestAppContext as an argument!
//
// Note that synchronous side effects run immediately after your "update*" calls complete.
test "basic testing" {
    var cx = TestAppContext.init();
    defer cx.deinit();

    const counter = cx.new(Counter.init);

    counter.update(&cx, Counter.set_count, .{42});

    // Note that TestAppContext doesn't support `read(cx)` in GPUI, but it does here.
    try std.testing.expectEqual(@as(i32, 42), counter.read(&cx).count);

    // Emit an event - the subscriber will run immediately after the update finishes
    counter.update(&cx, Counter.emit_event, .{});

    try std.testing.expectEqual(@as(i32, 999), counter.read(&cx).count);
}

// Tests which involve the window require you to construct a VisualTestContext.
// Just like synchronous side effects, the window will be drawn after every "update*"
// call, so you can test render-dependent behavior.
test "counter in window" {
    var cx = TestAppContext.init();
    defer cx.deinit();

    const counter, const vcx = cx.add_window_view(build_root);
    const focus_handle = counter.read(&cx).focus_handle;

    // Action dispatch depends on the element tree to resolve which action handler
    // to call, and this works exactly as you'd expect in a test.
    focus_handle.dispatch_action(Increment{}, vcx.window, cx.app);

    try std.testing.expectEqual(@as(i32, 1), counter.read(&cx).count);
}

// GPUI tests can also be async. Here `wait` runs the foreground work the load needs.
// The test executor runs pending work only when you yield control, so the detached reload
// does not run until `run_until_parked`.
test "async operations" {
    var cx = TestAppContext.init();
    defer cx.deinit();

    const counter = cx.new(Counter.init);

    // Tasks can be awaited directly
    var load = counter.update(&cx, Counter.load, .{});
    _ = load.wait();

    try std.testing.expectEqual(@as(i32, 100), counter.read(&cx).count);

    // But side effects don't run until you yield control
    counter.update(&cx, Counter.reload, .{});

    try std.testing.expectEqual(@as(i32, 100), counter.read(&cx).count);

    // This runs all pending tasks
    cx.run_until_parked();

    try std.testing.expectEqual(@as(i32, 150), counter.read(&cx).count);
}

// Property testing: the GPUI `iterations = 10` attribute, as a loop over fixed seeds.
test "counter random operations" {
    var seed: u64 = 0;
    while (seed < 10) : (seed += 1) {
        var cx = TestAppContext.init();
        defer cx.deinit();
        var prng = std.Random.DefaultPrng.init(seed);
        const rng = prng.random();

        const window_counter, const vcx = cx.add_window_view(build_root);
        _ = window_counter;

        const counter = cx.new(Counter.init);

        // Perform random increments/decrements
        var expected: i32 = 0;
        for (0..100) |_| {
            if (rng.boolean()) {
                expected += 1;
                const inc = Increment{};
                counter.update_in(vcx.window, &cx, Counter.increment, .{&inc});
            } else {
                expected -= 1;
                const dec = Decrement{};
                counter.update_in(vcx.window, &cx, Counter.decrement, .{&dec});
            }
        }

        try std.testing.expectEqual(expected, counter.read(&cx).count);
    }
}

/// Distributed systems: a mock network between two app contexts.
const Queue = struct {
    items: [64]i32 = undefined,
    head: usize = 0,
    tail: usize = 0,

    fn push(self: *Queue, value: i32) void {
        self.items[self.tail] = value;
        self.tail += 1;
    }

    fn pop(self: *Queue) ?i32 {
        if (self.head == self.tail) return null;
        const value = self.items[self.head];
        self.head += 1;
        return value;
    }
};

/// A mock network that delivers messages between two peers.
const MockNetwork = struct {
    a_to_b: Queue = .{},
    b_to_a: Queue = .{},

    fn a_client(self: *MockNetwork) NetworkClient {
        return .{ .network = self, .is_a = true };
    }

    fn b_client(self: *MockNetwork) NetworkClient {
        return .{ .network = self, .is_a = false };
    }
};

/// A client handle for sending/receiving messages over the mock network.
const NetworkClient = struct {
    network: *MockNetwork,
    is_a: bool,

    // See, networking is easy!
    fn send(self: NetworkClient, value: i32) void {
        if (self.is_a) {
            self.network.b_to_a.push(value);
        } else {
            self.network.a_to_b.push(value);
        }
    }

    fn receive(self: NetworkClient) ?i32 {
        if (self.is_a) return self.network.a_to_b.pop();
        return self.network.b_to_a.pop();
    }
};

/// A networked counter that can send/receive over a mock network.
const NetworkedCounter = struct {
    count: i32,
    client: NetworkClient,

    fn new(client: NetworkClient) NetworkedCounter {
        return .{ .count = 0, .client = client };
    }

    /// Increment the counter and broadcast the change.
    fn increment(self: *NetworkedCounter, delta: i32, cx: *Context(NetworkedCounter)) void {
        self.count += delta;

        var send_task = cx.foreground_executor().spawn(send_delta, .{ self.client, delta });
        send_task.detach();
    }

    fn send_delta(client: NetworkClient, delta: i32) void {
        client.send(delta);
    }

    /// Process incoming increment requests.
    fn sync(self: *NetworkedCounter, _: *Context(NetworkedCounter)) void {
        while (self.client.receive()) |delta| self.count += delta;
    }
};

// You can simulate distributed systems with multiple app contexts, simply by adding
// additional parameters.
test "distributed: app sync" {
    var network: MockNetwork = .{};
    var cx_a = TestAppContext.init();
    defer cx_a.deinit();
    var cx_b = TestAppContext.init();
    defer cx_b.deinit();

    const a = cx_a.new(NetworkedCounter.new(network.a_client()));
    const b = cx_b.new(NetworkedCounter.new(network.b_client()));

    // B increments locally and broadcasts the delta
    b.update(&cx_b, NetworkedCounter.increment, .{42});
    try std.testing.expectEqual(@as(i32, 42), b.read(&cx_b).count); // B's count is set immediately
    try std.testing.expectEqual(@as(i32, 0), a.read(&cx_a).count); // A's count is in a side effect

    cx_b.run_until_parked(); // Send the delta from B
    a.update(&cx_a, NetworkedCounter.sync, .{}); // Receive the delta at A

    try std.testing.expectEqual(@as(i32, 42), b.read(&cx_b).count); // Both counts now match
    try std.testing.expectEqual(@as(i32, 42), a.read(&cx_a).count);
}

// Multiple apps run concurrently: each `run_until_parked` runs one app's tasks. Here the
// operations of the two apps are issued in a random order, and both sides must agree at the end.
test "distributed: random interleaving" {
    var seed: u64 = 0;
    while (seed < 10) : (seed += 1) {
        var network: MockNetwork = .{};
        var cx_a = TestAppContext.init();
        defer cx_a.deinit();
        var cx_b = TestAppContext.init();
        defer cx_b.deinit();
        var prng = std.Random.DefaultPrng.init(seed);
        const rng = prng.random();

        const a = cx_a.new(NetworkedCounter.new(network.a_client()));
        const b = cx_b.new(NetworkedCounter.new(network.b_client()));

        const num_operations = rng.intRangeLessThan(usize, 3, 8);
        for (0..num_operations) |i| {
            const value: i32 = @intCast(i);
            if (rng.boolean()) {
                b.update(&cx_b, NetworkedCounter.increment, .{value});
            } else {
                a.update(&cx_a, NetworkedCounter.increment, .{value});
            }
        }

        // This will send all of the pending increment messages, from both a and b
        cx_a.run_until_parked();
        cx_b.run_until_parked();

        a.update(&cx_a, NetworkedCounter.sync, .{});
        b.update(&cx_b, NetworkedCounter.sync, .{});

        try std.testing.expectEqual(a.read(&cx_a).count, b.read(&cx_b).count);
    }
}
