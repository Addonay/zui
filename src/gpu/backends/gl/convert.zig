//! Sokol to OpenGL enum conversion tables from sokol_gfx.h:10270-10742.
const std = @import("std");
const e = @import("../../enums.zig");
const t = @import("../../types.zig");
const c = @import("constants.zig");

pub fn shaderStage(value: e.ShaderStage) u32 {
    return switch (value) {
        .vertex => c.vertex_shader,
        .fragment => c.fragment_shader,
        .compute => c.compute_shader,
        else => unreachable,
    };
}

pub fn vertexComponents(value: e.VertexFormat) i32 {
    return switch (value) {
        .float => 1,
        .float2 => 2,
        .float3 => 3,
        .float4 => 4,
        .int => 1,
        .int2 => 2,
        .int3 => 3,
        .int4 => 4,
        .uint => 1,
        .uint2 => 2,
        .uint3 => 3,
        .uint4 => 4,
        .byte4 => 4,
        .byte4n => 4,
        .ubyte4 => 4,
        .ubyte4n => 4,
        .short2 => 2,
        .short2n => 2,
        .ushort2 => 2,
        .ushort2n => 2,
        .short4 => 4,
        .short4n => 4,
        .ushort4 => 4,
        .ushort4n => 4,
        .int10_n2 => 4,
        .uint10_n2 => 4,
        .half2 => 2,
        .half4 => 4,
        else => unreachable,
    };
}

pub fn vertexType(value: e.VertexFormat) u32 {
    return switch (value) {
        .float, .float2, .float3, .float4 => c.float,
        .int, .int2, .int3, .int4 => c.int,
        .uint, .uint2, .uint3, .uint4 => c.unsigned_int,
        .byte4, .byte4n => c.byte,
        .ubyte4, .ubyte4n => c.unsigned_byte,
        .short2, .short2n, .short4, .short4n => c.short,
        .ushort2, .ushort2n, .ushort4, .ushort4n => c.unsigned_short,
        .int10_n2 => c.int_2_10_10_10_rev,
        .uint10_n2 => c.unsigned_int_2_10_10_10_rev,
        .half2, .half4 => c.half_float,
        else => unreachable,
    };
}

pub fn vertexNormalized(value: e.VertexFormat) u8 {
    return switch (value) {
        .byte4n, .ubyte4n, .short2n, .ushort2n, .short4n, .ushort4n, .int10_n2, .uint10_n2 => c.true,
        else => c.false,
    };
}

pub fn primitiveType(value: e.PrimitiveType) u32 {
    return switch (value) {
        .points => c.points,
        .lines => c.lines,
        .line_strip => c.line_strip,
        .triangles => c.triangles,
        .triangle_strip => c.triangle_strip,
        else => unreachable,
    };
}

pub fn indexType(value: e.IndexType) u32 {
    return switch (value) {
        .none => 0,
        .uint16 => c.unsigned_short,
        .uint32 => c.unsigned_int,
        else => unreachable,
    };
}

pub fn compareFunc(value: e.CompareFunc) u32 {
    return switch (value) {
        .never => c.never,
        .less => c.less,
        .equal => c.equal,
        .less_equal => c.lequal,
        .greater => c.greater,
        .not_equal => c.notequal,
        .greater_equal => c.gequal,
        .always => c.always,
        else => unreachable,
    };
}

pub fn stencilOp(value: e.StencilOp) u32 {
    return switch (value) {
        .keep => c.keep,
        .zero => c.zero,
        .replace => c.replace,
        .incr_clamp => c.incr,
        .decr_clamp => c.decr,
        .invert => c.invert,
        .incr_wrap => c.incr_wrap,
        .decr_wrap => c.decr_wrap,
        else => unreachable,
    };
}

pub fn blendFactor(value: e.BlendFactor) u32 {
    return switch (value) {
        .zero => c.zero,
        .one => c.one,
        .src_color => c.src_color,
        .one_minus_src_color => c.one_minus_src_color,
        .src_alpha => c.src_alpha,
        .one_minus_src_alpha => c.one_minus_src_alpha,
        .dst_color => c.dst_color,
        .one_minus_dst_color => c.one_minus_dst_color,
        .dst_alpha => c.dst_alpha,
        .one_minus_dst_alpha => c.one_minus_dst_alpha,
        .src_alpha_saturated => c.src_alpha_saturate,
        .blend_color => c.constant_color,
        .one_minus_blend_color => c.one_minus_constant_color,
        .blend_alpha => c.constant_alpha,
        .one_minus_blend_alpha => c.one_minus_constant_alpha,
        .src1_color => c.src1_color,
        .one_minus_src1_color => c.one_minus_src1_color,
        .src1_alpha => c.src1_alpha,
        .one_minus_src1_alpha => c.one_minus_src1_alpha,
        else => unreachable,
    };
}

pub fn blendOp(value: e.BlendOp) u32 {
    return switch (value) {
        .add => c.func_add,
        .subtract => c.func_subtract,
        .reverse_subtract => c.func_reverse_subtract,
        .min => c.min,
        .max => c.max,
        else => unreachable,
    };
}

pub fn pixelType(value: e.PixelFormat) u32 {
    return switch (value) {
        .r8, .r8ui, .rg8, .rg8ui, .rgba8, .srgb8a8, .rgba8ui, .bgra8 => c.unsigned_byte,
        .r8sn, .r8si, .rg8sn, .rg8si, .rgba8sn, .rgba8si => c.byte,
        .r16, .r16ui, .rg16, .rg16ui, .rgba16, .rgba16ui => c.unsigned_short,
        .r16sn, .r16si, .rg16sn, .rg16si, .rgba16sn, .rgba16si => c.short,
        .r16f, .rg16f, .rgba16f => c.half_float,
        .r32ui, .rg32ui, .rgba32ui => c.unsigned_int,
        .r32si, .rg32si, .rgba32si => c.int,
        .r32f, .rg32f, .rgba32f => c.float,
        .rgb10a2 => c.unsigned_int_2_10_10_10_rev,
        .rg11b10f => c.unsigned_int_10f_11f_11f_rev,
        .rgb9e5 => c.unsigned_int_5_9_9_9_rev,
        .depth => c.float,
        .depth_stencil => c.float_32_unsigned_int_24_8_rev,
        else => unreachable,
    };
}

pub fn pixelFormat(value: e.PixelFormat) u32 {
    return switch (value) {
        .r8, .r8sn, .r16, .r16sn, .r16f, .r32f => c.red,
        .r8ui, .r8si, .r16ui, .r16si, .r32ui, .r32si => c.red_integer,
        .rg8, .rg8sn, .rg16, .rg16sn, .rg16f, .rg32f => c.rg,
        .rg8ui, .rg8si, .rg16ui, .rg16si, .rg32ui, .rg32si => c.rg_integer,
        .rgba8, .srgb8a8, .rgba8sn, .rgba16, .rgba16sn, .rgba16f, .rgba32f, .rgb10a2 => c.rgba,
        .rgba8ui, .rgba8si, .rgba16ui, .rgba16si, .rgba32ui, .rgba32si => c.rgba_integer,
        .rg11b10f, .rgb9e5 => c.rgb,
        .depth => c.depth_component,
        .depth_stencil => c.depth_stencil,
        .bc1_rgba => c.compressed_rgba_s3tc_dxt1_ext,
        .bc2_rgba => c.compressed_rgba_s3tc_dxt3_ext,
        .bc3_rgba => c.compressed_rgba_s3tc_dxt5_ext,
        .bc3_srgba => c.compressed_srgb_alpha_s3tc_dxt5_ext,
        .bc4_r => c.compressed_red_rgtc1,
        .bc4_rsn => c.compressed_signed_red_rgtc1,
        .bc5_rg => c.compressed_red_green_rgtc2,
        .bc5_rgsn => c.compressed_signed_red_green_rgtc2,
        .bc6h_rgbf => c.compressed_rgb_bptc_signed_float_arb,
        .bc6h_rgbuf => c.compressed_rgb_bptc_unsigned_float_arb,
        .bc7_rgba => c.compressed_rgba_bptc_unorm_arb,
        .bc7_srgba => c.compressed_srgb_alpha_bptc_unorm_arb,
        .etc2_rgb8 => c.compressed_rgb8_etc2,
        .etc2_srgb8 => c.compressed_srgb8_etc2,
        .etc2_rgb8a1 => c.compressed_rgb8_punchthrough_alpha1_etc2,
        .etc2_rgba8 => c.compressed_rgba8_etc2_eac,
        .etc2_srgb8a8 => c.compressed_srgb8_alpha8_etc2_eac,
        .eac_r11 => c.compressed_r11_eac,
        .eac_r11sn => c.compressed_signed_r11_eac,
        .eac_rg11 => c.compressed_rg11_eac,
        .eac_rg11sn => c.compressed_signed_rg11_eac,
        .astc_4x4_rgba => c.compressed_rgba_astc_4x4_khr,
        .astc_4x4_srgba => c.compressed_srgb8_alpha8_astc_4x4_khr,
        else => unreachable,
    };
}

pub fn pixelInternalFormat(value: e.PixelFormat) u32 {
    return switch (value) {
        .r8 => c.r8,
        .r8sn => c.r8_snorm,
        .r8ui => c.r8ui,
        .r8si => c.r8i,
        .r16 => c.r16,
        .r16sn => c.r16_snorm,
        .r16ui => c.r16ui,
        .r16si => c.r16i,
        .r16f => c.r16f,
        .rg8 => c.rg8,
        .rg8sn => c.rg8_snorm,
        .rg8ui => c.rg8ui,
        .rg8si => c.rg8i,
        .r32ui => c.r32ui,
        .r32si => c.r32i,
        .r32f => c.r32f,
        .rg16 => c.rg16,
        .rg16sn => c.rg16_snorm,
        .rg16ui => c.rg16ui,
        .rg16si => c.rg16i,
        .rg16f => c.rg16f,
        .rgba8 => c.rgba8,
        .srgb8a8 => c.srgb8_alpha8,
        .rgba8sn => c.rgba8_snorm,
        .rgba8ui => c.rgba8ui,
        .rgba8si => c.rgba8i,
        .rgb10a2 => c.rgb10_a2,
        .rg11b10f => c.r11f_g11f_b10f,
        .rgb9e5 => c.rgb9_e5,
        .rg32ui => c.rg32ui,
        .rg32si => c.rg32i,
        .rg32f => c.rg32f,
        .rgba16 => c.rgba16,
        .rgba16sn => c.rgba16_snorm,
        .rgba16ui => c.rgba16ui,
        .rgba16si => c.rgba16i,
        .rgba16f => c.rgba16f,
        .rgba32ui => c.rgba32ui,
        .rgba32si => c.rgba32i,
        .rgba32f => c.rgba32f,
        .depth => c.depth_component32f,
        .depth_stencil => c.depth32f_stencil8,
        .bc1_rgba => c.compressed_rgba_s3tc_dxt1_ext,
        .bc2_rgba => c.compressed_rgba_s3tc_dxt3_ext,
        .bc3_rgba => c.compressed_rgba_s3tc_dxt5_ext,
        .bc3_srgba => c.compressed_srgb_alpha_s3tc_dxt5_ext,
        .bc4_r => c.compressed_red_rgtc1,
        .bc4_rsn => c.compressed_signed_red_rgtc1,
        .bc5_rg => c.compressed_red_green_rgtc2,
        .bc5_rgsn => c.compressed_signed_red_green_rgtc2,
        .bc6h_rgbf => c.compressed_rgb_bptc_signed_float_arb,
        .bc6h_rgbuf => c.compressed_rgb_bptc_unsigned_float_arb,
        .bc7_rgba => c.compressed_rgba_bptc_unorm_arb,
        .bc7_srgba => c.compressed_srgb_alpha_bptc_unorm_arb,
        .etc2_rgb8 => c.compressed_rgb8_etc2,
        .etc2_srgb8 => c.compressed_srgb8_etc2,
        .etc2_rgb8a1 => c.compressed_rgb8_punchthrough_alpha1_etc2,
        .etc2_rgba8 => c.compressed_rgba8_etc2_eac,
        .etc2_srgb8a8 => c.compressed_srgb8_alpha8_etc2_eac,
        .eac_r11 => c.compressed_r11_eac,
        .eac_r11sn => c.compressed_signed_r11_eac,
        .eac_rg11 => c.compressed_rg11_eac,
        .eac_rg11sn => c.compressed_signed_rg11_eac,
        .astc_4x4_rgba => c.compressed_rgba_astc_4x4_khr,
        .astc_4x4_srgba => c.compressed_srgb8_alpha8_astc_4x4_khr,
        else => unreachable,
    };
}

pub fn bufferTarget(usage: t.BufferUsage) u32 {
    if (usage.vertex_buffer or usage.staging_buffer) return c.array_buffer;
    if (usage.index_buffer or usage.staging_index_buffer) return c.element_array_buffer;
    if (usage.storage_buffer) return c.shader_storage_buffer;
    unreachable;
}
pub fn bufferUsage(usage: t.BufferUsage) u32 {
    return if (usage.write_transient) c.stream_draw else if (usage.copy_dst) c.dynamic_copy else c.static_draw;
}
pub fn textureTarget(kind: e.ImageType, samples: i32, gles: bool) u32 {
    if (samples > 1) {
        std.debug.assert(!gles);
        return switch (kind) {
            .@"2d" => c.texture_2d_multisample,
            .array => c.texture_2d_multisample_array,
            else => unreachable,
        };
    }
    return switch (kind) {
        .@"2d" => c.texture_2d,
        .cube => c.texture_cube_map,
        .@"3d" => c.texture_3d,
        .array => c.texture_2d_array,
        else => unreachable,
    };
}
pub fn wrap(value: e.Wrap, gles: bool) u32 {
    return switch (value) {
        .clamp_to_edge => c.clamp_to_edge,
        .clamp_to_border => if (gles) c.clamp_to_edge else c.clamp_to_border,
        .repeat => c.repeat,
        .mirrored_repeat => c.mirrored_repeat,
        else => unreachable,
    };
}
pub fn minFilter(min: e.Filter, mip: e.Filter) u32 {
    return switch (min) {
        .nearest => switch (mip) {
            .nearest => c.nearest_mipmap_nearest,
            .linear => c.nearest_mipmap_linear,
            else => unreachable,
        },
        .linear => switch (mip) {
            .nearest => c.linear_mipmap_nearest,
            .linear => c.linear_mipmap_linear,
            else => unreachable,
        },
        else => unreachable,
    };
}
pub fn magFilter(value: e.Filter) u32 {
    return if (value == .nearest) c.nearest else c.linear;
}
pub fn cubeFace(index: i32) u32 {
    std.debug.assert(index >= 0 and index < 6);
    return c.texture_cube_map_positive_x + @as(u32, @intCast(index));
}
