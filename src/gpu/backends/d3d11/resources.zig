//! Native D3D11 resource ownership, from sokol_gfx.h:7425-7518.
const t = @import("../../types.zig");
const sdk = @import("sdk.zig");
pub const Buffer = struct { object: ?*sdk.Object = null, staging: ?[]u8 = null };
pub const Image = struct { format: u32 = 0, texture_2d: ?*sdk.Object = null, texture_3d: ?*sdk.Object = null, resource: ?*sdk.Object = null };
pub const Sampler = struct { object: ?*sdk.Object = null };
pub const Shader = struct {
    semantic_names: [16][31:0]u8 = @splat(@splat(0)),
    semantic_indices: [16]u32 = @splat(0),
    vertex: ?*sdk.Object = null,
    fragment: ?*sdk.Object = null,
    compute: ?*sdk.Object = null,
    vertex_bytecode: ?[]u8 = null,
    uniform_registers: [8]u8 = @splat(0),
    srv_registers: [32]u8 = @splat(0),
    uav_registers: [32]u8 = @splat(0),
    sampler_registers: [12]u8 = @splat(0),
    uniform_buffers: [8]?*sdk.Object = @splat(null),
    uniform_uploads: [8]?[]u8 = @splat(null),
    vertex_uniforms: [8]?*sdk.Object = @splat(null),
    fragment_uniforms: [8]?*sdk.Object = @splat(null),
    compute_uniforms: [8]?*sdk.Object = @splat(null),
};
pub const Pipeline = struct {
    stencil_ref: u32 = 0,
    vertex_strides: [8]u32 = @splat(0),
    topology: u32 = 0,
    index_format: u32 = 0,
    input_layout: ?*sdk.Object = null,
    rasterizer: ?*sdk.Object = null,
    depth_stencil: ?*sdk.Object = null,
    blend: ?*sdk.Object = null,
};
pub const View = struct { srv: ?*sdk.Object = null, uav: ?*sdk.Object = null, rtv: ?*sdk.Object = null, dsv: ?*sdk.Object = null };
pub fn Resource(comptime Descriptor: type) type {
    if (Descriptor == t.BufferDesc) return Buffer;
    if (Descriptor == t.ImageDesc) return Image;
    if (Descriptor == t.SamplerDesc) return Sampler;
    if (Descriptor == t.ShaderDesc) return Shader;
    if (Descriptor == t.PipelineDesc) return Pipeline;
    if (Descriptor == t.ViewDesc) return View;
    @compileError("unknown D3D11 resource descriptor");
}

const Ref = @import("../../backend_bindings.zig").References(Resource);
pub const BufferBinding = Ref.BufferBinding;
pub const ImageBinding = Ref.ImageBinding;
pub const ViewBinding = Ref.ViewBinding;
pub const ShaderBinding = Ref.ShaderBinding;
pub const PipelineBinding = Ref.PipelineBinding;
pub const Bindings = Ref.Bindings;
pub const Attachments = Ref.Attachments;
