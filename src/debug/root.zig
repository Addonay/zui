//! Application diagnostics and opt-in inspector. See docs/DEBUGGING.md.
pub const stats = @import("stats.zig");
pub const inspector = @import("inspector.zig");
pub const trace = @import("trace.zig");
pub const profiler = @import("profiler.zig");
pub const snapshot = @import("snapshot.zig");
pub const test_context = @import("test_context.zig");
test {
    _ = @import("inspector_test.zig");
}
