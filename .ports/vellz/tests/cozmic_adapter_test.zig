//! Opt-in Cozmic adapter tests.
//!
//! This is the only test root that can see the Cozmic sibling checkout. It is
//! added to `zig build test` with a `cozmic_available` build option; when
//! `.ports/cozmic` is missing (a standalone vellz checkout), the bridge tests
//! are replaced by one explicit skip, so the default test step never fails
//! because of a missing sibling.

const std = @import("std");
const options = @import("cozmic_options");

test "cozmic bridge tests (skip when the sibling checkout is absent)" {
    if (comptime options.cozmic_available) {
        // Referencing the bridge pulls in its test decls (1:1 mapping and
        // pixel-equivalence tests).
        _ = @import("cozmic_bridge.zig");
    } else {
        std.debug.print(
            "SKIP: .ports/cozmic is not available; Cozmic adapter bridge tests skipped\n",
            .{},
        );
        return error.SkipZigTest;
    }
}
