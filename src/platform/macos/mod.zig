//! macOS platform: Cocoa backend skeleton over objc bindings.
//!
//! Inert on all operating systems until `CocoaBackend.init` lands; see
//! `cocoa.zig` and `bindings.zig` for the mapped surface.

pub const bindings = @import("bindings.zig");
pub const services = @import("services.zig");
pub const cocoa = @import("cocoa.zig");

pub const CocoaBackend = cocoa.CocoaBackend;

test {
    _ = @import("bindings.zig");
    _ = @import("services.zig");
    _ = @import("cocoa.zig");
}
