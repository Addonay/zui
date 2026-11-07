//! Compile-time configuration, the equivalent of the SOKOL_* defines.
const builtin = @import("builtin");
const options = @import("build_options");

/// SOKOL_DEBUG: validation layer, log message strings and debug labels.
pub const debug = options.debug orelse (builtin.mode == .debug or builtin.mode == .safe);

/// SOKOL_VALIDATE_NON_FATAL: failed validation logs errors and skips the
/// operation instead of raising the VALIDATION_FAILED panic.
pub const validate_non_fatal = options.validate_non_fatal;
