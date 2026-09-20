//! Small blocking helper for synchronous work that must not borrow UI state.
//!
//! GPUI's `block_on` drives a Future. ZUI's task runtime is callback-based, so
//! this module exposes the compatible, explicit subset: run a `Send`-safe
//! function on a temporary thread and join it. Async task submission remains
//! owned by `TaskRuntime`.

const std = @import("std");

pub fn blockOn(comptime T: type, work: *const fn () T) T {
    var result: T = undefined;
    const ThreadState = struct { result: *T, work: *const fn () T };
    var state = ThreadState{ .result = &result, .work = work };
    const thread = std.Thread.spawn(.{}, struct {
        fn run(s: *ThreadState) void {
            s.result.* = s.work();
        }
    }.run, .{&state}) catch {
        result = work();
        return result;
    };
    thread.join();
    return result;
}

test "blocking helper returns worker result" {
    const answer = blockOn(u32, struct {
        fn compute() u32 {
            return 42;
        }
    }.compute);
    try std.testing.expectEqual(@as(u32, 42), answer);
}
