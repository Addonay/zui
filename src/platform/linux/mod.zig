//! Linux platform: Wayland + X11 backends over shared evdev input tables.
//!
//! Both backends `dlopen` their system libraries (libwayland-client,
//! libX11) and translate to normalized `event.Event`; see `evdev.zig` for
//! the shared keycode story.

pub const evdev = @import("evdev.zig");
pub const wayland = @import("wayland.zig");
pub const x11 = @import("x11.zig");
pub const xkb = @import("xkb.zig");

test {
    _ = @import("evdev.zig");
    _ = @import("wayland.zig");
    _ = @import("x11.zig");
    _ = @import("xkb.zig");
}
