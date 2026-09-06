//! GPU layer: scene collection today, per-API renderers next.
//!
//! Roadmap mirrors SDL's split: generic `scene` + `vulkan`/`metal`/`d3d12`
//! drivers behind one device vtable, with per-platform surface glue kept
//! in `platform/`. Vulkan function tables will be `dlopen`ed with
//! `VK_NO_PROTOTYPES` like SDL's `vkfuncs.h` X-macros.

pub const scene = @import("scene.zig");
pub const software = @import("software.zig");
pub const Scene = scene.Scene;
pub const Quad = scene.Quad;

test {
    _ = @import("scene.zig");
    _ = @import("software.zig");
}
