//! Reproducible smoke probe for ZUI's portable test/visual infrastructure.
//! No window, GPU, clock, or platform backend is opened.
const std = @import("std");
const trace = @import("debug_trace");
const profiler = @import("debug_profiler");

pub fn main() !void {
    var events = trace.Trace{};
    _ = events.frameBegin(0, 1);
    _ = events.event(4_000, 1, 17, 800, 600);
    _ = events.append(8_000, 1, .layout, 0, 12, 0, "root");
    _ = events.append(12_000, 1, .paint, 0, 2, 0, "scene");
    _ = events.frameEnd(16_000, 1);

    var timings = profiler.Recorder{};
    var layout = timings.begin("layout", 100);
    _ = timings.end(&layout, 275);
    _ = timings.counter("frames", 1);

    std.debug.print(
        "trace={x} profiler={x} records={d} timings={d}\n",
        .{ events.digest(false), timings.digest(), events.len, timings.len },
    );
}

test "headless debug probe produces bounded artifacts" {
    var events = trace.Trace{};
    for (0..trace.max_records + 4) |frame| {
        _ = events.append(0, @intCast(frame), .marker, 0, 0, 0, "probe");
    }
    try std.testing.expectEqual(trace.max_records, events.len);
    try std.testing.expectEqual(@as(u64, 4), events.dropped);
}
