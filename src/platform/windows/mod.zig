//! Windows platform: Win32 backend skeleton over user32 bindings.
//!
//! Inert on all operating systems until `Win32Backend.init` lands; see
//! `win32.zig` and `bindings.zig` for the mapped surface.

pub const bindings = @import("bindings.zig");
pub const win32 = @import("win32.zig");

pub const Win32Backend = win32.Win32Backend;

test {
    _ = @import("bindings.zig");
    _ = @import("win32.zig");
}
