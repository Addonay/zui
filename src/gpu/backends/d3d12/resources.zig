//! Native D3D12 resource payloads. Descriptors are CPU descriptor handles
//! (0 for none) in the backend's persistent, non-shader-visible heaps.
const t = @import("../../types.zig");
const sdk = @import("sdk.zig");
const constants = @import("constants.zig");

pub const Object = sdk.Object;

pub const Buffer = struct {
    /// The ID3D12Resource, or null for staging buffers, which keep their data in `staging`.
    resource: ?*Object = null,
    gpu_address: u64 = 0,
    staging: ?[]u8 = null,
    /// The tracked resource state; every transition goes from here.
    state: u32 = constants.state_common,
};

pub const Image = struct {
    resource: ?*Object = null,
    /// The typeless texture format, see convert.textureFormat.
    format: u32 = 0,
    state: u32 = constants.state_common,
};

pub const Sampler = struct {
    handle: usize = 0,
};

/// Stage indices of a shader's descriptor tables: vertex, fragment, compute.
pub const stage_count = 3;
/// Table kinds: shader resource views, unordered access views, samplers.
pub const TableKind = enum(u8) { srv = 0, uav = 1, sampler = 2 };

/// A descriptor table of a root signature covering registers 0..count-1.
pub const Table = struct {
    param: u32 = 0,
    count: u32 = 0,
};

/// Where a shader view or sampler slot is bound, see the root signature layout in DESIGN.md.
pub const Binding = struct {
    active: bool = false,
    stage: u8 = 0,
    kind: TableKind = .srv,
    register: u8 = 0,
};

pub const Shader = struct {
    root_signature: ?*Object = null,
    /// Shader byte code, copied from the source or compiled HLSL.
    vertex: []u8 = &.{},
    fragment: []u8 = &.{},
    compute: []u8 = &.{},
    /// Semantic names and indices of the vertex attributes, copied from the descriptor.
    semantic_names: [16][32]u8 = @splat(@splat(0)),
    semantic_indices: [16]u8 = @splat(0),
    /// Root parameter index of each uniform block slot.
    ub_param: [8]u32 = @splat(0),
    tables: [stage_count][3]Table = @splat(@splat(.{})),
    views: [32]Binding = @splat(.{}),
    samplers: [12]Binding = @splat(.{}),
};

pub const Pipeline = struct {
    pso: ?*Object = null,
    topology: u32 = 0,
    index_format: u32 = 0,
    vertex_strides: [8]u32 = @splat(0),
    stencil_ref: u32 = 0,
    blend_color: [4]f32 = @splat(0),
};

/// Descriptors of a view, one per kind it supports. Storage buffers have both
/// an SRV (read-only use) and a UAV (writable use).
pub const View = struct {
    srv: usize = 0,
    uav: usize = 0,
    rtv: usize = 0,
    dsv: usize = 0,
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
