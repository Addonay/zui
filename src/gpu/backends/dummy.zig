//! Dummy backend capabilities, from sokol_gfx.h:9813-9836. Every resource and
//! command operation of this backend is a no-op that succeeds.
const e = @import("../enums.zig");
const core = @import("../core.zig");
const constants = @import("../constants.zig");

pub fn setup(s: *core.State) void {
    for (@backingInt(e.PixelFormat.r8)..@backingInt(e.PixelFormat.bc1_rgba)) |i| {
        s.formats[i] = .{ .sample = true, .filter = true, .render = true, .blend = true, .msaa = true };
    }
    s.formats[@backingInt(e.PixelFormat.depth)].depth = true;
    s.formats[@backingInt(e.PixelFormat.depth_stencil)].depth = true;
    s.limits.max_image_size_2d = 1024;
    s.limits.max_image_size_cube = 1024;
    s.limits.max_image_size_3d = 1024;
    s.limits.max_image_size_array = 1024;
    s.limits.max_image_array_layers = 1024;
    s.limits.max_vertex_attrs = 16;
    s.limits.max_color_attachments = constants.max_portable_color_attachments;
    s.limits.max_texture_bindings_per_stage = constants.max_portable_texture_bindings_per_stage;
    s.limits.max_storage_buffer_bindings_per_stage = constants.max_portable_storagebuffer_bindings_per_stage;
    s.limits.max_storage_image_bindings_per_stage = constants.max_portable_storageimage_bindings_per_stage;
}
