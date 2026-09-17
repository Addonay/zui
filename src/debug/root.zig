//! Application diagnostics and opt-in inspector. See docs/DEBUGGING.md.
pub const stats = @import("stats.zig");
pub const inspector = @import("inspector.zig");
test {
    _ = @import("inspector_test.zig");
}
