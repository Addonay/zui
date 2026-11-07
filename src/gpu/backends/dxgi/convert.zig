//! Shared DXGI and Direct3D format/state conversion, from sokol_gfx.h:13982-14343.
const t = @import("../../types.zig");
const e = @import("../../enums.zig");
const c = @import("constants.zig");

pub fn baseFormat(value: e.PixelFormat) u32 {
    return switch (value) {
        .r8 => c.format_r8_unorm,
        .r8sn => c.format_r8_snorm,
        .r8ui => c.format_r8_uint,
        .r8si => c.format_r8_sint,
        .r16 => c.format_r16_unorm,
        .r16sn => c.format_r16_snorm,
        .r16ui => c.format_r16_uint,
        .r16si => c.format_r16_sint,
        .r16f => c.format_r16_float,
        .rg8 => c.format_r8g8_unorm,
        .rg8sn => c.format_r8g8_snorm,
        .rg8ui => c.format_r8g8_uint,
        .rg8si => c.format_r8g8_sint,
        .r32ui => c.format_r32_uint,
        .r32si => c.format_r32_sint,
        .r32f => c.format_r32_float,
        .rg16 => c.format_r16g16_unorm,
        .rg16sn => c.format_r16g16_snorm,
        .rg16ui => c.format_r16g16_uint,
        .rg16si => c.format_r16g16_sint,
        .rg16f => c.format_r16g16_float,
        .rgba8 => c.format_r8g8b8a8_unorm,
        .srgb8a8 => c.format_r8g8b8a8_unorm_srgb,
        .rgba8sn => c.format_r8g8b8a8_snorm,
        .rgba8ui => c.format_r8g8b8a8_uint,
        .rgba8si => c.format_r8g8b8a8_sint,
        .bgra8 => c.format_b8g8r8a8_unorm,
        .sbgr8a8 => c.format_b8g8r8a8_unorm_srgb,
        .rgb10a2 => c.format_r10g10b10a2_unorm,
        .rg11b10f => c.format_r11g11b10_float,
        .rgb9e5 => c.format_r9g9b9e5_sharedexp,
        .rg32ui => c.format_r32g32_uint,
        .rg32si => c.format_r32g32_sint,
        .rg32f => c.format_r32g32_float,
        .rgba16 => c.format_r16g16b16a16_unorm,
        .rgba16sn => c.format_r16g16b16a16_snorm,
        .rgba16ui => c.format_r16g16b16a16_uint,
        .rgba16si => c.format_r16g16b16a16_sint,
        .rgba16f => c.format_r16g16b16a16_float,
        .rgba32ui => c.format_r32g32b32a32_uint,
        .rgba32si => c.format_r32g32b32a32_sint,
        .rgba32f => c.format_r32g32b32a32_float,
        .depth => c.format_r32_typeless,
        .depth_stencil => c.format_r32g8x24_typeless,
        .bc1_rgba => c.format_bc1_unorm,
        .bc2_rgba => c.format_bc2_unorm,
        .bc3_rgba => c.format_bc3_unorm,
        .bc3_srgba => c.format_bc3_unorm_srgb,
        .bc4_r => c.format_bc4_unorm,
        .bc4_rsn => c.format_bc4_snorm,
        .bc5_rg => c.format_bc5_unorm,
        .bc5_rgsn => c.format_bc5_snorm,
        .bc6h_rgbf => c.format_bc6h_sf16,
        .bc6h_rgbuf => c.format_bc6h_uf16,
        .bc7_rgba => c.format_bc7_unorm,
        .bc7_srgba => c.format_bc7_unorm_srgb,
        else => c.format_unknown,
    };
}

pub fn topology(value: e.PrimitiveType) u32 {
    return switch (value) {
        .points => c.primitive_topology_pointlist,
        .lines => c.primitive_topology_linelist,
        .line_strip => c.primitive_topology_linestrip,
        .triangles => c.primitive_topology_trianglelist,
        .triangle_strip => c.primitive_topology_trianglestrip,
        else => unreachable,
    };
}

pub fn indexFormat(value: e.IndexType) u32 {
    return switch (value) {
        .none => c.format_unknown,
        .uint16 => c.format_r16_uint,
        .uint32 => c.format_r32_uint,
        else => unreachable,
    };
}

pub fn addressMode(value: e.Wrap) u32 {
    return switch (value) {
        .repeat => c.texture_address_wrap,
        .clamp_to_edge => c.texture_address_clamp,
        .clamp_to_border => c.texture_address_border,
        .mirrored_repeat => c.texture_address_mirror,
        else => unreachable,
    };
}

pub fn vertexFormat(value: e.VertexFormat) u32 {
    return switch (value) {
        .float => c.format_r32_float,
        .float2 => c.format_r32g32_float,
        .float3 => c.format_r32g32b32_float,
        .float4 => c.format_r32g32b32a32_float,
        .int => c.format_r32_sint,
        .int2 => c.format_r32g32_sint,
        .int3 => c.format_r32g32b32_sint,
        .int4 => c.format_r32g32b32a32_sint,
        .uint => c.format_r32_uint,
        .uint2 => c.format_r32g32_uint,
        .uint3 => c.format_r32g32b32_uint,
        .uint4 => c.format_r32g32b32a32_uint,
        .byte4 => c.format_r8g8b8a8_sint,
        .byte4n => c.format_r8g8b8a8_snorm,
        .ubyte4 => c.format_r8g8b8a8_uint,
        .ubyte4n => c.format_r8g8b8a8_unorm,
        .short2 => c.format_r16g16_sint,
        .short2n => c.format_r16g16_snorm,
        .ushort2 => c.format_r16g16_uint,
        .ushort2n => c.format_r16g16_unorm,
        .short4 => c.format_r16g16b16a16_sint,
        .short4n => c.format_r16g16b16a16_snorm,
        .ushort4 => c.format_r16g16b16a16_uint,
        .ushort4n => c.format_r16g16b16a16_unorm,
        .uint10_n2 => c.format_r10g10b10a2_unorm,
        .half2 => c.format_r16g16_float,
        .half4 => c.format_r16g16b16a16_float,
        else => unreachable,
    };
}

pub fn inputClass(value: e.VertexStep) u32 {
    return switch (value) {
        .per_vertex => c.input_per_vertex_data,
        .per_instance => c.input_per_instance_data,
        else => unreachable,
    };
}

pub fn cullMode(value: e.CullMode) u32 {
    return switch (value) {
        .none => c.cull_none,
        .front => c.cull_front,
        .back => c.cull_back,
        else => unreachable,
    };
}

pub fn compareFunc(value: e.CompareFunc) u32 {
    return switch (value) {
        .never => c.comparison_never,
        .less => c.comparison_less,
        .equal => c.comparison_equal,
        .less_equal => c.comparison_less_equal,
        .greater => c.comparison_greater,
        .not_equal => c.comparison_not_equal,
        .greater_equal => c.comparison_greater_equal,
        .always => c.comparison_always,
        else => unreachable,
    };
}

pub fn stencilOp(value: e.StencilOp) u32 {
    return switch (value) {
        .keep => c.stencil_op_keep,
        .zero => c.stencil_op_zero,
        .replace => c.stencil_op_replace,
        .incr_clamp => c.stencil_op_incr_sat,
        .decr_clamp => c.stencil_op_decr_sat,
        .invert => c.stencil_op_invert,
        .incr_wrap => c.stencil_op_incr,
        .decr_wrap => c.stencil_op_decr,
        else => unreachable,
    };
}

pub fn blendFactor(value: e.BlendFactor) u32 {
    return switch (value) {
        .zero => c.blend_zero,
        .one => c.blend_one,
        .src_color => c.blend_src_color,
        .one_minus_src_color => c.blend_inv_src_color,
        .src_alpha => c.blend_src_alpha,
        .one_minus_src_alpha => c.blend_inv_src_alpha,
        .dst_color => c.blend_dest_color,
        .one_minus_dst_color => c.blend_inv_dest_color,
        .dst_alpha => c.blend_dest_alpha,
        .one_minus_dst_alpha => c.blend_inv_dest_alpha,
        .src_alpha_saturated => c.blend_src_alpha_sat,
        .blend_color => c.blend_blend_factor,
        .one_minus_blend_color => c.blend_inv_blend_factor,
        .blend_alpha => c.blend_blend_factor,
        .one_minus_blend_alpha => c.blend_inv_blend_factor,
        .src1_color => c.blend_src1_color,
        .one_minus_src1_color => c.blend_inv_src1_color,
        .src1_alpha => c.blend_src1_alpha,
        .one_minus_src1_alpha => c.blend_inv_src1_alpha,
        else => unreachable,
    };
}

pub fn blendOp(value: e.BlendOp) u32 {
    return switch (value) {
        .add => c.blend_op_add,
        .subtract => c.blend_op_subtract,
        .reverse_subtract => c.blend_op_rev_subtract,
        .min => c.blend_op_min,
        .max => c.blend_op_max,
        else => unreachable,
    };
}

pub fn textureFormat(value: e.PixelFormat) u32 {
    return switch (value) {
        .srgb8a8 => c.format_r8g8b8a8_typeless,
        .sbgr8a8 => c.format_b8g8r8a8_typeless,
        else => baseFormat(value),
    };
}
pub fn srvFormat(value: e.PixelFormat) u32 {
    return switch (value) {
        .depth => c.format_r32_float,
        .depth_stencil => c.format_r32_float_x8x24_typeless,
        else => baseFormat(value),
    };
}
pub fn dsvFormat(value: e.PixelFormat) u32 {
    return switch (value) {
        .depth => c.format_d32_float,
        .depth_stencil => c.format_d32_float_s8x24_uint,
        else => baseFormat(value),
    };
}
pub const rtvUavFormat = srvFormat;
pub fn filter(min: e.Filter, mag: e.Filter, mip: e.Filter, comparison: bool, anisotropy: u32) u32 {
    var result: u32 = if (anisotropy > 1) 0x55 else (if (min == .linear) @as(u32, 0x10) else 0) |
        (if (mag == .linear) @as(u32, 4) else 0) |
        (if (mip == .linear) @as(u32, 1) else 0);
    if (comparison) result |= 0x80;
    return result;
}
pub fn colorMask(value: e.ColorMask) u8 {
    return @truncate(@backingInt(value) & 15);
}
pub fn bufferUsage(value: t.BufferUsage) u32 {
    return if (value.write_transient) c.usage_dynamic else c.usage_default;
}
pub fn bufferCpuAccess(value: t.BufferUsage) u32 {
    return if (value.write_transient) c.cpu_access_write else 0;
}
pub fn bufferBindFlags(value: t.BufferUsage) u32 {
    var flags: u32 = 0;
    if (value.vertex_buffer) flags |= c.bind_vertex_buffer;
    if (value.index_buffer) flags |= c.bind_index_buffer;
    if (value.storage_buffer) {
        flags |= c.bind_shader_resource;
        if (!value.write_transient) flags |= c.bind_unordered_access;
    }
    return flags;
}
pub fn bufferMiscFlags(value: t.BufferUsage) u32 {
    return if (value.storage_buffer) c.resource_misc_buffer_allow_raw_views else 0;
}
pub fn imageBindFlags(value: t.ImageUsage) u32 {
    var flags: u32 = c.bind_shader_resource;
    if (value.color_attachment) flags |= c.bind_render_target;
    if (value.depth_stencil_attachment) flags |= c.bind_depth_stencil;
    if (value.storage_image) flags |= c.bind_unordered_access;
    return flags;
}
pub fn subresource(mip: u32, slice: u32, mip_count: u32) u32 {
    return mip + slice * mip_count;
}
