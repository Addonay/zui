//! Typed native resource references resolved by the shared API.
const t = @import("types.zig");
pub fn References(comptime Resource: anytype) type {
    return struct {
        pub const BufferBinding = struct {
            resource: *Resource(t.BufferDesc),
            desc: *const t.BufferDesc,
            active_slot: i32,
        };
        pub const ImageBinding = struct {
            resource: *Resource(t.ImageDesc),
            desc: *const t.ImageDesc,
            active_slot: i32,
        };
        pub const ViewBinding = struct {
            resource: *Resource(t.ViewDesc),
            desc: *const t.ViewDesc,
            buffer: ?BufferBinding = null,
            image: ?ImageBinding = null,
        };
        pub const ShaderBinding = struct {
            resource: *Resource(t.ShaderDesc),
            desc: *const t.ShaderDesc,
        };
        pub const PipelineBinding = struct {
            resource: *Resource(t.PipelineDesc),
            desc: *const t.PipelineDesc,
            slot: t.SlotInfo,
        };
        pub const Bindings = struct {
            pipeline: PipelineBinding,
            shader: ShaderBinding,
            vertex_buffers: [8]?BufferBinding = @splat(null),
            vertex_offsets: [8]i32 = @splat(0),
            index_buffer: ?BufferBinding = null,
            index_offset: i32 = 0,
            views: [32]?ViewBinding = @splat(null),
            samplers: [12]?*Resource(t.SamplerDesc) = @splat(null),
        };
        pub const Attachments = struct {
            colors: [8]?ViewBinding = @splat(null),
            resolves: [8]?ViewBinding = @splat(null),
            depth_stencil: ?ViewBinding = null,
            num_colors: usize = 0,
            width: i32 = 0,
            height: i32 = 0,

            pub fn empty(self: Attachments) bool {
                return self.num_colors == 0 and self.depth_stencil == null;
            }
        };
    };
}
