//! Port of GPUI's `examples/ownership_post.rs`.
//!
//! Zig initializers cannot capture `counter`, so the subscriber is created first and
//! then subscribes and reads the counter inside `update` (the same state as the Rust closure).

const std = @import("std");
const gpui = @import("zui");
const App = gpui.App;
const Context = gpui.Context;
const Entity = gpui.Entity;

const Counter = struct {
    count: usize,

    pub const Event = Change;
};

const Change = struct {
    increment: usize,
};

fn run_example(cx: *App) void {
    const counter: Entity(Counter) = cx.new(struct {
        fn init(_: *Context(Counter)) Counter {
            return .{ .count = 0 };
        }
    }.init);
    const subscriber = cx.new(struct {
        fn init(_: *Context(Counter)) Counter {
            return .{ .count = 0 };
        }
    }.init);
    subscriber.update(cx, struct {
        fn update(s: *Counter, counter_: Entity(Counter), cx2: *Context(Counter)) void {
            _ = cx2.subscribe(counter_, struct {
                fn on_change(subscriber_: *Counter, _: Entity(Counter), event: *const Change, _: *Context(Counter)) void {
                    subscriber_.count += event.increment * 2;
                }
            }.on_change).detach();

            s.count = counter_.read(cx2).count * 2;
        }
    }.update, .{counter});

    counter.update(cx, struct {
        fn update(c: *Counter, cx2: *Context(Counter)) void {
            c.count += 2;
            cx2.notify();
            cx2.emit(Change{ .increment = 2 });
        }
    }.update, .{});

    std.debug.assert(subscriber.read(cx).count == 4);
}

pub fn main() void {
    gpui.Application.new().run(run_example);
}
