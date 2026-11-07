//! Native GL resource payloads corresponding to sokol_gfx.h:7263-7369.
const t = @import("../../types.zig");
const e = @import("../../enums.zig");

pub const Buffer = struct {
    ids: [2]u32 = @splat(0),
    injected: bool = false,
    gpu_dirty: u8 = 0,
    staging: ?[]u8 = null,
};
pub const Image = struct {
    target: u32 = 0,
    ids: [2]u32 = @splat(0),
    injected: bool = false,
    gpu_dirty: u8 = 0,
};
pub const Sampler = struct {
    id: u32 = 0,
    injected: bool = false,
};
pub const Uniform = struct {
    location: i32 = -1,
    type: e.UniformType = .invalid,
    count: u16 = 0,
    offset: u16 = 0,
};
pub const UniformBlock = struct {
    count: usize = 0,
    uniforms: [16]Uniform = @splat(.{}),
};
pub const Shader = struct {
    program: u32 = 0,
    attribute_names: [16][31:0]u8 = @splat(@splat(0)),
    uniform_blocks: [8]UniformBlock = @splat(.{}),
    storage_buffer_bindings: [32]u8 = @splat(0),
    storage_image_bindings: [32]u8 = @splat(0),
    texture_slots: [32]i8 = @splat(0),
};
pub const Attribute = struct {
    buffer_index: i8 = -1,
    divisor: i8 = -1,
    stride: u8 = 0,
    size: u8 = 0,
    normalized: u8 = 0,
    offset: i32 = 0,
    type: u32 = 0,
    base_type: e.ShaderAttrBaseType = .undefined,
};
pub const Pipeline = struct {
    attrs: [16]Attribute = @splat(.{}),
    active_vertex_buffers: [8]bool = @splat(false),
};
pub const View = struct {
    texture_views: [2]u32 = @splat(0),
    msaa_renderbuffer: u32 = 0,
    resolve_framebuffer: u32 = 0,
};

pub fn Resource(comptime Descriptor: type) type {
    if (Descriptor == t.BufferDesc) return Buffer;
    if (Descriptor == t.ImageDesc) return Image;
    if (Descriptor == t.SamplerDesc) return Sampler;
    if (Descriptor == t.ShaderDesc) return Shader;
    if (Descriptor == t.PipelineDesc) return Pipeline;
    if (Descriptor == t.ViewDesc) return View;
    @compileError("unknown GL resource descriptor");
}

const Ref = @import("../../backend_bindings.zig").References(Resource);
pub const BufferBinding = Ref.BufferBinding;
pub const ImageBinding = Ref.ImageBinding;
pub const ViewBinding = Ref.ViewBinding;
pub const ShaderBinding = Ref.ShaderBinding;
pub const PipelineBinding = Ref.PipelineBinding;
pub const Bindings = Ref.Bindings;
pub const Attachments = Ref.Attachments;

pub const Dirty = struct {
    pub const vertex: u8 = 1;
    pub const index: u8 = 2;
    pub const storage_buffer: u8 = 4;
    pub const texture: u8 = 8;
    pub const storage_image: u8 = 16;
    pub const attachment: u8 = 32;
    pub const buffer_all: u8 = vertex | index | storage_buffer;
    pub const image_all: u8 = texture | storage_image | attachment;
};
