//! Native WebGPU resource payloads, from the `_sg_wgpu_*_t` structs of sokol_gfx.h:7719-7790.
//! Handles are optional because a resource that failed to create keeps them null.
const std = @import("std");
const t = @import("../../types.zig");
const sdk = @import("sdk.zig");

/// Shader entry point names are copied into fixed storage (`_SG_STRING_SIZE`).
pub const entry_name_size = 32;

pub const Buffer = struct {
    buf: ?sdk.Buffer = null,
    mapped_ptr: ?[*]u8 = null,
    /// CPU-side storage for staging buffers, which never reach the GPU.
    staging: ?[]u8 = null,
};

pub const Image = struct {
    tex: ?sdk.Texture = null,
};

pub const Sampler = struct {
    smp: ?sdk.Sampler = null,
};

pub const ShaderFunc = struct {
    module: ?sdk.ShaderModule = null,
    entry: [entry_name_size:0]u8 = @splat(0),

    pub fn entryView(self: *const ShaderFunc) sdk.StringView {
        const name = std.mem.sliceTo(&self.entry, 0);
        return .{ .data = name.ptr, .length = name.len };
    }
};

pub const Shader = struct {
    vertex_func: ShaderFunc = .{},
    fragment_func: ShaderFunc = .{},
    compute_func: ShaderFunc = .{},
    bgl_ub: ?sdk.BindGroupLayout = null,
    bg_ub: ?sdk.BindGroup = null,
    bgl_view_smp: ?sdk.BindGroupLayout = null,
    /// Number of dynamic offsets of the uniform bindgroup, in binding order.
    ub_num_dynoffsets: u8 = 0,
    /// Maps a sokol uniform block slot to its index in the dynamic offsets array.
    ub_dynoffsets: [8]u8 = @splat(0),
    /// Maps sokol uniform block slots to WGSL @group(0) bindings.
    ub_grp0_bnd_n: [8]u8 = @splat(0),
    /// Maps sokol view slots to WGSL @group(1) bindings.
    view_grp1_bnd_n: [32]u8 = @splat(0),
    /// Maps sokol sampler slots to WGSL @group(1) bindings.
    smp_grp1_bnd_n: [12]u8 = @splat(0),
};

pub const Pipeline = struct {
    rpip: ?sdk.RenderPipeline = null,
    cpip: ?sdk.ComputePipeline = null,
    blend_color: sdk.Color = .{},
};

pub const View = struct {
    view: ?sdk.TextureView = null,
};

pub fn Resource(comptime Desc: type) type {
    if (Desc == t.BufferDesc) return Buffer;
    if (Desc == t.ImageDesc) return Image;
    if (Desc == t.SamplerDesc) return Sampler;
    if (Desc == t.ShaderDesc) return Shader;
    if (Desc == t.PipelineDesc) return Pipeline;
    if (Desc == t.ViewDesc) return View;
    @compileError("unknown WebGPU resource descriptor");
}
