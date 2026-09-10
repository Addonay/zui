//! Env-gated stderr diagnostics for the frame loop and backends.
//!
//! Disabled by default (zero cost beyond one cached `getenv`): set
//! `ZUI_LOG=1` to get lifecycle lines (backend kind, configure sizes,
//! ping/pong, present sizes, slow steps). Uses `std.debug.print`, which
//! is fine on these cold paths — never call from the layout/scene hot
//! path itself, only around it.

const std = @import("std");
const builtin = @import("builtin");

var cached: ?bool = null;

/// True once `ZUI_LOG` is set to a non-empty value (besides "0").
pub fn enabled() bool {
    if (cached) |c| return c;
    var on = false;
    if (builtin.link_libc) {
        if (std.c.getenv("ZUI_LOG")) |raw| {
            const v = std.mem.span(raw);
            on = v.len > 0 and !std.mem.eql(u8, v, "0");
        }
    }
    cached = on;
    return on;
}

/// Scoped debug line, no-op (after one branch) unless `ZUI_LOG` is set.
pub fn log(comptime scope: []const u8, comptime fmt: []const u8, args: anytype) void {
    if (!enabled()) return;
    std.debug.print("[zui:{s}] " ++ fmt ++ "\n", .{scope} ++ args);
}

test "log disabled by default has no output contract" {
    // Only asserts the accessor is cheap and deterministic, not the env.
    const a = enabled();
    const b = enabled();
    try std.testing.expectEqual(a, b);
}
