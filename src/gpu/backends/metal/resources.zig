//! Native Metal resource payloads, from sokol_gfx.h:7519-7718 (`_sg_mtl_*_t`).
//! Object references are slot indices into the id pool (see idpool.zig), 0 meaning none.
const t = @import("../../types.zig");
const constants = @import("../../constants.zig");
const sdk = @import("sdk.zig");

pub const num_inflight = constants.num_inflight_frames;

/// Limits of the Metal argument tables, see sokol_gfx.h:7535-7545. Stage buffer slots are
/// 0..7 uniform blocks, 8..22 storage buffers and 23..30 vertex buffers.
pub const max_stage_buffer_bindings = 31;
pub const max_stage_ub_bindings = 8;
pub const max_stage_ub_sbuf_bindings = max_stage_buffer_bindings - 8;
pub const max_stage_texture_bindings = 32;
pub const max_stage_sampler_bindings = 12;

pub const Buffer = struct {
    /// Pool slots of the buffer objects, one per slot of the buffer.
    buf: [num_inflight]i32 = @splat(0),
    /// Range of bytes written since the last commit, for didModifyRange on macOS.
    write_range_start: usize = 0,
    write_range_end: usize = 0,
};

pub const Image = struct {
    tex: [num_inflight]i32 = @splat(0),
};

pub const Sampler = struct {
    sampler_state: i32 = 0,
};

pub const ShaderFunc = struct {
    mtl_lib: i32 = 0,
    mtl_func: i32 = 0,
};

pub const Shader = struct {
    vertex_func: ShaderFunc = .{},
    fragment_func: ShaderFunc = .{},
    compute_func: ShaderFunc = .{},
    threads_per_threadgroup: sdk.Size = .{},
    ub_buffer_n: [constants.max_uniformblock_bindslots]u8 = @splat(0),
    view_buffer_texture_n: [constants.max_view_bindslots]u8 = @splat(0),
    smp_sampler_n: [constants.max_sampler_bindslots]u8 = @splat(0),
};

pub const Pipeline = struct {
    prim_type: sdk.PrimitiveType = .point,
    index_size: i32 = 0,
    index_type: sdk.IndexType = .uint16,
    cull_mode: sdk.CullMode = .none,
    winding: sdk.Winding = .clockwise,
    stencil_ref: u32 = 0,
    threads_per_threadgroup: sdk.Size = .{},
    /// MTLComputePipelineState slot.
    cps: i32 = 0,
    /// MTLRenderPipelineState slot.
    rps: i32 = 0,
    /// MTLDepthStencilState slot.
    dss: i32 = 0,
};

pub const View = struct {
    tex_view: [num_inflight]i32 = @splat(0),
};

pub fn Resource(comptime Desc: type) type {
    if (Desc == t.BufferDesc) return Buffer;
    if (Desc == t.ImageDesc) return Image;
    if (Desc == t.SamplerDesc) return Sampler;
    if (Desc == t.ShaderDesc) return Shader;
    if (Desc == t.PipelineDesc) return Pipeline;
    if (Desc == t.ViewDesc) return View;
    @compileError("unknown Metal resource descriptor");
}
