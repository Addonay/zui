//! GPU layer: scene collection, device abstraction, per-API drivers.
//!
//! Split mirrors SDL3: generic `scene` + `device` vtable with
//! `vulkan`/`metal`/`d3d12` drivers behind it, per-platform surface glue
//! kept in `platform/`. Vulkan function tables are `dlopen`ed with
//! `VK_NO_PROTOTYPES` like SDL's `vkfuncs.h` X-macros. `software` is the
//! CPU fallback; `null_device` discards frames for headless tests.

pub const scene = @import("scene.zig");
pub const vellz = @import("vellz.zig");
pub const device = @import("device.zig");
pub const null_device = @import("null_device.zig");
pub const software_device = @import("software_device.zig");
pub const vulkan = @import("vulkan.zig");
pub const metal = @import("metal.zig");
pub const d3d12 = @import("d3d12.zig");
pub const Scene = scene.Scene;
pub const Quad = scene.Quad;
pub const Glyph = scene.Glyph;
pub const Device = device.Device;
pub const DeviceKind = device.DeviceKind;
pub const SurfaceHandle = device.SurfaceHandle;
pub const CommandBuffer = device.CommandBuffer;
pub const RenderPass = device.RenderPass;
pub const ComputePass = device.ComputePass;
pub const CopyPass = device.CopyPass;
pub const TextureFormat = device.TextureFormat;

test {
    _ = @import("scene.zig");
    _ = @import("vellz.zig");
    _ = @import("device.zig");
    _ = @import("null_device.zig");
    _ = @import("software_device.zig");
    _ = @import("vulkan.zig");
    _ = @import("metal.zig");
    _ = @import("d3d12.zig");
}
