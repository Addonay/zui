//! Native Vulkan resource payloads, the `_sg_vk_*_t` structs of sokol_gfx.h:7886-8128.
//! Handles are the raw 64-bit values of the Vulkan non-dispatchable handle types.
const std = @import("std");
const t = @import("../../types.zig");
const c = @import("../../constants.zig");
const sdk = @import("sdk.zig");
const barrier = @import("barrier.zig");

pub const Buffer = struct {
    buf: sdk.Buffer = 0,
    mem: sdk.DeviceMemory = 0,
    /// Only valid for storage buffers.
    dev_addr: u64 = 0,
    cur_access: barrier.Access = barrier.none,
};

pub const Image = struct {
    img: sdk.Image = 0,
    mem: sdk.DeviceMemory = 0,
    cur_access: barrier.Access = barrier.none,
};

/// Samplers and views record the descriptor bytes that are copied into the
/// descriptor buffer on every bindings update.
pub const max_descriptor_data_size = 256;

pub const Sampler = struct {
    smp: sdk.Sampler = 0,
    descriptor_size: usize = 0,
    descriptor_data: [max_descriptor_data_size]u8 = @splat(0),
};

pub const ShaderFunc = struct {
    module: sdk.ShaderModule = 0,
    /// Null-terminated entry point name (the header copies it into `_sg_str_t`).
    entry: [64:0]u8 = @splat(0),
};

pub const Shader = struct {
    vertex_func: ShaderFunc = .{},
    fragment_func: ShaderFunc = .{},
    compute_func: ShaderFunc = .{},
    ub_dsl: sdk.DescriptorSetLayout = 0,
    ub_count: u32 = 0,
    view_smp_count: u32 = 0,
    ub_dset_size: u64 = 0,
    view_smp_dsl: sdk.DescriptorSetLayout = 0,
    view_smp_dset_size: u64 = 0,
    pip_layout: sdk.PipelineLayout = 0,
    // indexed by sokol-gfx bind slot
    ub_set0_bnd_n: [c.max_uniformblock_bindslots]u8 = @splat(0),
    view_set1_bnd_n: [c.max_view_bindslots]u8 = @splat(0),
    smp_set1_bnd_n: [c.max_sampler_bindslots]u8 = @splat(0),
    // relative descriptor offsets to the start of the descriptor set in the descriptor buffer
    ub_dset_offsets: [c.max_uniformblock_bindslots]u16 = @splat(0),
    view_dset_offsets: [c.max_view_bindslots]u16 = @splat(0),
    smp_dset_offsets: [c.max_sampler_bindslots]u16 = @splat(0),
};

pub const Pipeline = struct {
    pip: sdk.Pipeline = 0,
};

pub const View = struct {
    img_view: sdk.ImageView = 0,
    descriptor_size: usize = 0,
    descriptor_data: [max_descriptor_data_size]u8 = @splat(0),
};

pub fn Resource(comptime Desc: type) type {
    if (Desc == t.BufferDesc) return Buffer;
    if (Desc == t.ImageDesc) return Image;
    if (Desc == t.SamplerDesc) return Sampler;
    if (Desc == t.ShaderDesc) return Shader;
    if (Desc == t.PipelineDesc) return Pipeline;
    if (Desc == t.ViewDesc) return View;
    @compileError("unknown resource descriptor");
}
