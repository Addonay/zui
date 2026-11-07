//! Sokol to Vulkan enum and flag conversions, sokol_gfx.h:22241-22611.
const std = @import("std");
const t = @import("../../types.zig");
const e = @import("../../enums.zig");
const sdk = @import("sdk.zig");

pub fn pixelFormat(fmt: e.PixelFormat) i32 {
    return switch (fmt) {
        .none => sdk.FORMAT_UNDEFINED,
        .r8 => sdk.FORMAT_R8_UNORM,
        .r8sn => sdk.FORMAT_R8_SNORM,
        .r8ui => sdk.FORMAT_R8_UINT,
        .r8si => sdk.FORMAT_R8_SINT,
        .r16 => sdk.FORMAT_R16_UNORM,
        .r16sn => sdk.FORMAT_R16_SNORM,
        .r16ui => sdk.FORMAT_R16_UINT,
        .r16si => sdk.FORMAT_R16_SINT,
        .r16f => sdk.FORMAT_R16_SFLOAT,
        .rg8 => sdk.FORMAT_R8G8_UNORM,
        .rg8sn => sdk.FORMAT_R8G8_SNORM,
        .rg8ui => sdk.FORMAT_R8G8_UINT,
        .rg8si => sdk.FORMAT_R8G8_SINT,
        .r32ui => sdk.FORMAT_R32_UINT,
        .r32si => sdk.FORMAT_R32_SINT,
        .r32f => sdk.FORMAT_R32_SFLOAT,
        .rg16 => sdk.FORMAT_R16G16_UNORM,
        .rg16sn => sdk.FORMAT_R16G16_SNORM,
        .rg16ui => sdk.FORMAT_R16G16_UINT,
        .rg16si => sdk.FORMAT_R16G16_SINT,
        .rg16f => sdk.FORMAT_R16G16_SFLOAT,
        .rgba8 => sdk.FORMAT_R8G8B8A8_UNORM,
        .srgb8a8 => sdk.FORMAT_R8G8B8A8_SRGB,
        .rgba8sn => sdk.FORMAT_R8G8B8A8_SNORM,
        .rgba8ui => sdk.FORMAT_R8G8B8A8_UINT,
        .rgba8si => sdk.FORMAT_R8G8B8A8_SINT,
        .bgra8 => sdk.FORMAT_B8G8R8A8_UNORM,
        .sbgr8a8 => sdk.FORMAT_B8G8R8A8_SRGB,
        .rgb10a2 => sdk.FORMAT_A2R10G10B10_UNORM_PACK32,
        .rg11b10f => sdk.FORMAT_B10G11R11_UFLOAT_PACK32,
        .rgb9e5 => sdk.FORMAT_E5B9G9R9_UFLOAT_PACK32,
        .rg32ui => sdk.FORMAT_R32G32_UINT,
        .rg32si => sdk.FORMAT_R32G32_SINT,
        .rg32f => sdk.FORMAT_R32G32_SFLOAT,
        .rgba16 => sdk.FORMAT_R16G16B16A16_UNORM,
        .rgba16sn => sdk.FORMAT_R16G16B16A16_SNORM,
        .rgba16ui => sdk.FORMAT_R16G16B16A16_UINT,
        .rgba16si => sdk.FORMAT_R16G16B16A16_SINT,
        .rgba16f => sdk.FORMAT_R16G16B16A16_SFLOAT,
        .rgba32ui => sdk.FORMAT_R32G32B32A32_UINT,
        .rgba32si => sdk.FORMAT_R32G32B32A32_SINT,
        .rgba32f => sdk.FORMAT_R32G32B32A32_SFLOAT,
        .depth => sdk.FORMAT_D32_SFLOAT,
        .depth_stencil => sdk.FORMAT_D32_SFLOAT_S8_UINT,
        .bc1_rgba => sdk.FORMAT_BC1_RGBA_UNORM_BLOCK,
        .bc2_rgba => sdk.FORMAT_BC2_UNORM_BLOCK,
        .bc3_rgba => sdk.FORMAT_BC3_UNORM_BLOCK,
        .bc3_srgba => sdk.FORMAT_BC3_SRGB_BLOCK,
        .bc4_r => sdk.FORMAT_BC4_UNORM_BLOCK,
        .bc4_rsn => sdk.FORMAT_BC4_SNORM_BLOCK,
        .bc5_rg => sdk.FORMAT_BC5_UNORM_BLOCK,
        .bc5_rgsn => sdk.FORMAT_BC5_SNORM_BLOCK,
        .bc6h_rgbf => sdk.FORMAT_BC6H_SFLOAT_BLOCK,
        .bc6h_rgbuf => sdk.FORMAT_BC6H_UFLOAT_BLOCK,
        .bc7_rgba => sdk.FORMAT_BC7_UNORM_BLOCK,
        .bc7_srgba => sdk.FORMAT_BC7_SRGB_BLOCK,
        .etc2_rgb8 => sdk.FORMAT_ETC2_R8G8B8_UNORM_BLOCK,
        .etc2_srgb8 => sdk.FORMAT_ETC2_R8G8B8_SRGB_BLOCK,
        .etc2_rgb8a1 => sdk.FORMAT_ETC2_R8G8B8A1_UNORM_BLOCK,
        .etc2_rgba8 => sdk.FORMAT_ETC2_R8G8B8A8_UNORM_BLOCK,
        .etc2_srgb8a8 => sdk.FORMAT_ETC2_R8G8B8A8_SRGB_BLOCK,
        .eac_r11 => sdk.FORMAT_EAC_R11_UNORM_BLOCK,
        .eac_r11sn => sdk.FORMAT_EAC_R11_SNORM_BLOCK,
        .eac_rg11 => sdk.FORMAT_EAC_R11G11_UNORM_BLOCK,
        .eac_rg11sn => sdk.FORMAT_EAC_R11G11_SNORM_BLOCK,
        .astc_4x4_rgba => sdk.FORMAT_ASTC_4x4_UNORM_BLOCK,
        .astc_4x4_srgba => sdk.FORMAT_ASTC_4x4_SRGB_BLOCK,
        else => sdk.FORMAT_UNDEFINED,
    };
}

pub fn vertexFormat(f: e.VertexFormat) i32 {
    return switch (f) {
        .float => sdk.FORMAT_R32_SFLOAT,
        .float2 => sdk.FORMAT_R32G32_SFLOAT,
        .float3 => sdk.FORMAT_R32G32B32_SFLOAT,
        .float4 => sdk.FORMAT_R32G32B32A32_SFLOAT,
        .int => sdk.FORMAT_R32_SINT,
        .int2 => sdk.FORMAT_R32G32_SINT,
        .int3 => sdk.FORMAT_R32G32B32_SINT,
        .int4 => sdk.FORMAT_R32G32B32A32_SINT,
        .uint => sdk.FORMAT_R32_UINT,
        .uint2 => sdk.FORMAT_R32G32_UINT,
        .uint3 => sdk.FORMAT_R32G32B32_UINT,
        .uint4 => sdk.FORMAT_R32G32B32A32_UINT,
        .byte4 => sdk.FORMAT_R8G8B8A8_SINT,
        .byte4n => sdk.FORMAT_R8G8B8A8_SNORM,
        .ubyte4 => sdk.FORMAT_R8G8B8A8_UINT,
        .ubyte4n => sdk.FORMAT_R8G8B8A8_UNORM,
        .short2 => sdk.FORMAT_R16G16_SINT,
        .short2n => sdk.FORMAT_R16G16_SNORM,
        .ushort2 => sdk.FORMAT_R16G16_UINT,
        .ushort2n => sdk.FORMAT_R16G16_UNORM,
        .short4 => sdk.FORMAT_R16G16B16A16_SINT,
        .short4n => sdk.FORMAT_R16G16B16A16_SNORM,
        .ushort4 => sdk.FORMAT_R16G16B16A16_UINT,
        .ushort4n => sdk.FORMAT_R16G16B16A16_UNORM,
        .int10_n2 => sdk.FORMAT_A2B10G10R10_SNORM_PACK32,
        .uint10_n2 => sdk.FORMAT_A2B10G10R10_UNORM_PACK32,
        .half2 => sdk.FORMAT_R16G16_SFLOAT,
        .half4 => sdk.FORMAT_R16G16B16A16_SFLOAT,
        else => unreachable,
    };
}

pub fn vertexInputRate(s: e.VertexStep) i32 {
    return if (s == .per_vertex) sdk.VERTEX_INPUT_RATE_VERTEX else sdk.VERTEX_INPUT_RATE_INSTANCE;
}

pub fn imageCreateFlags(kind: e.ImageType) u32 {
    return switch (kind) {
        .cube => sdk.IMAGE_CREATE_CUBE_COMPATIBLE_BIT,
        else => 0,
    };
}

pub fn imageType(kind: e.ImageType) i32 {
    return if (kind == .@"3d") sdk.IMAGE_TYPE_3D else sdk.IMAGE_TYPE_2D;
}

pub fn imageUsage(usg: t.ImageUsage) u32 {
    var res: u32 = sdk.IMAGE_USAGE_TRANSFER_DST_BIT | sdk.IMAGE_USAGE_SAMPLED_BIT;
    if (usg.storage_image) res |= sdk.IMAGE_USAGE_STORAGE_BIT;
    // readImage copies from the image
    if (usg.copy_src) res |= sdk.IMAGE_USAGE_TRANSFER_SRC_BIT;
    if (usg.color_attachment or usg.resolve_attachment) res |= sdk.IMAGE_USAGE_COLOR_ATTACHMENT_BIT;
    if (usg.depth_stencil_attachment) res |= sdk.IMAGE_USAGE_DEPTH_STENCIL_ATTACHMENT_BIT;
    return res;
}

pub fn bufferUsage(usg: t.BufferUsage) u32 {
    var res: u32 = sdk.BUFFER_USAGE_TRANSFER_DST_BIT;
    if (usg.vertex_buffer) res |= sdk.BUFFER_USAGE_VERTEX_BUFFER_BIT;
    if (usg.index_buffer) res |= sdk.BUFFER_USAGE_INDEX_BUFFER_BIT;
    if (usg.storage_buffer) res |= sdk.BUFFER_USAGE_STORAGE_BUFFER_BIT | sdk.BUFFER_USAGE_SHADER_DEVICE_ADDRESS_BIT;
    if (usg.copy_src) res |= sdk.BUFFER_USAGE_TRANSFER_SRC_BIT;
    if (usg.copy_dst) res |= sdk.BUFFER_USAGE_TRANSFER_DST_BIT;
    return res;
}

pub fn primitiveTopology(kind: e.PrimitiveType) i32 {
    return switch (kind) {
        .points => sdk.PRIMITIVE_TOPOLOGY_POINT_LIST,
        .lines => sdk.PRIMITIVE_TOPOLOGY_LINE_LIST,
        .line_strip => sdk.PRIMITIVE_TOPOLOGY_LINE_STRIP,
        .triangles => sdk.PRIMITIVE_TOPOLOGY_TRIANGLE_LIST,
        .triangle_strip => sdk.PRIMITIVE_TOPOLOGY_TRIANGLE_STRIP,
        else => unreachable,
    };
}

pub fn cullMode(cm: e.CullMode) u32 {
    return switch (cm) {
        .none => sdk.CULL_MODE_NONE,
        .front => sdk.CULL_MODE_FRONT_BIT,
        .back => sdk.CULL_MODE_BACK_BIT,
        else => unreachable,
    };
}

pub fn frontFace(fw: e.FaceWinding) i32 {
    return if (fw == .ccw) sdk.FRONT_FACE_COUNTER_CLOCKWISE else sdk.FRONT_FACE_CLOCKWISE;
}

pub fn compareOp(f: e.CompareFunc) i32 {
    return switch (f) {
        .never => sdk.COMPARE_OP_NEVER,
        .less => sdk.COMPARE_OP_LESS,
        .equal => sdk.COMPARE_OP_EQUAL,
        .less_equal => sdk.COMPARE_OP_LESS_OR_EQUAL,
        .greater => sdk.COMPARE_OP_GREATER,
        .not_equal => sdk.COMPARE_OP_NOT_EQUAL,
        .greater_equal => sdk.COMPARE_OP_GREATER_OR_EQUAL,
        .always => sdk.COMPARE_OP_ALWAYS,
        else => unreachable,
    };
}

pub fn stencilOp(op: e.StencilOp) i32 {
    return switch (op) {
        .keep => sdk.STENCIL_OP_KEEP,
        .zero => sdk.STENCIL_OP_ZERO,
        .replace => sdk.STENCIL_OP_REPLACE,
        .incr_clamp => sdk.STENCIL_OP_INCREMENT_AND_CLAMP,
        .decr_clamp => sdk.STENCIL_OP_DECREMENT_AND_CLAMP,
        .invert => sdk.STENCIL_OP_INVERT,
        .incr_wrap => sdk.STENCIL_OP_INCREMENT_AND_WRAP,
        .decr_wrap => sdk.STENCIL_OP_DECREMENT_AND_WRAP,
        else => unreachable,
    };
}

pub fn blendOp(op: e.BlendOp) i32 {
    return switch (op) {
        .add => sdk.BLEND_OP_ADD,
        .subtract => sdk.BLEND_OP_SUBTRACT,
        .reverse_subtract => sdk.BLEND_OP_REVERSE_SUBTRACT,
        .min => sdk.BLEND_OP_MIN,
        .max => sdk.BLEND_OP_MAX,
        else => unreachable,
    };
}

pub fn blendFactor(f: e.BlendFactor) i32 {
    return switch (f) {
        .zero => sdk.BLEND_FACTOR_ZERO,
        .one => sdk.BLEND_FACTOR_ONE,
        .src_color => sdk.BLEND_FACTOR_SRC_COLOR,
        .one_minus_src_color => sdk.BLEND_FACTOR_ONE_MINUS_SRC_COLOR,
        .src_alpha => sdk.BLEND_FACTOR_SRC_ALPHA,
        .one_minus_src_alpha => sdk.BLEND_FACTOR_ONE_MINUS_SRC_ALPHA,
        .dst_color => sdk.BLEND_FACTOR_DST_COLOR,
        .one_minus_dst_color => sdk.BLEND_FACTOR_ONE_MINUS_DST_COLOR,
        .dst_alpha => sdk.BLEND_FACTOR_DST_ALPHA,
        .one_minus_dst_alpha => sdk.BLEND_FACTOR_ONE_MINUS_DST_ALPHA,
        .src_alpha_saturated => sdk.BLEND_FACTOR_SRC_ALPHA_SATURATE,
        .blend_color => sdk.BLEND_FACTOR_CONSTANT_COLOR,
        .one_minus_blend_color => sdk.BLEND_FACTOR_ONE_MINUS_CONSTANT_COLOR,
        .blend_alpha => sdk.BLEND_FACTOR_CONSTANT_ALPHA,
        .one_minus_blend_alpha => sdk.BLEND_FACTOR_ONE_MINUS_CONSTANT_ALPHA,
        .src1_color => sdk.BLEND_FACTOR_SRC1_COLOR,
        .one_minus_src1_color => sdk.BLEND_FACTOR_ONE_MINUS_SRC1_COLOR,
        .src1_alpha => sdk.BLEND_FACTOR_SRC1_ALPHA,
        .one_minus_src1_alpha => sdk.BLEND_FACTOR_ONE_MINUS_SRC1_ALPHA,
        else => unreachable,
    };
}

/// sg_color_mask bits R=1, G=2, B=4, A=8 map directly onto the Vulkan bits.
pub fn colorWriteMask(m: e.ColorMask) u32 {
    const bits = @backingInt(m);
    var res: u32 = 0;
    if (bits & 0x1 != 0) res |= sdk.COLOR_COMPONENT_R_BIT;
    if (bits & 0x2 != 0) res |= sdk.COLOR_COMPONENT_G_BIT;
    if (bits & 0x4 != 0) res |= sdk.COLOR_COMPONENT_B_BIT;
    if (bits & 0x8 != 0) res |= sdk.COLOR_COMPONENT_A_BIT;
    return res;
}

pub fn shaderStage(s: e.ShaderStage) u32 {
    return switch (s) {
        .vertex => sdk.SHADER_STAGE_VERTEX_BIT,
        .fragment => sdk.SHADER_STAGE_FRAGMENT_BIT,
        .compute => sdk.SHADER_STAGE_COMPUTE_BIT,
        else => unreachable,
    };
}

pub fn loadOp(a: e.LoadAction) i32 {
    return switch (a) {
        .clear => sdk.ATTACHMENT_LOAD_OP_CLEAR,
        .dontcare => sdk.ATTACHMENT_LOAD_OP_DONT_CARE,
        else => sdk.ATTACHMENT_LOAD_OP_LOAD,
    };
}

pub fn storeOp(a: e.StoreAction) i32 {
    return switch (a) {
        .store => sdk.ATTACHMENT_STORE_OP_STORE,
        else => sdk.ATTACHMENT_STORE_OP_DONT_CARE,
    };
}

pub fn indexType(kind: e.IndexType) i32 {
    return if (kind == .uint16) sdk.INDEX_TYPE_UINT16 else sdk.INDEX_TYPE_UINT32;
}

pub fn textureImageViewType(kind: e.ImageType) i32 {
    return switch (kind) {
        .@"2d" => sdk.IMAGE_VIEW_TYPE_2D,
        .cube => sdk.IMAGE_VIEW_TYPE_CUBE,
        .@"3d" => sdk.IMAGE_VIEW_TYPE_3D,
        .array => sdk.IMAGE_VIEW_TYPE_2D_ARRAY,
        else => unreachable,
    };
}

pub fn attachmentImageViewType(kind: e.ImageType) i32 {
    return switch (kind) {
        .@"2d" => sdk.IMAGE_VIEW_TYPE_2D,
        .cube => sdk.IMAGE_VIEW_TYPE_2D_ARRAY, // not a bug
        .@"3d" => sdk.IMAGE_VIEW_TYPE_2D, // not a bug
        .array => sdk.IMAGE_VIEW_TYPE_2D_ARRAY,
        else => unreachable,
    };
}

pub fn samplerMinMagFilter(f: e.Filter) i32 {
    return if (f == .linear) sdk.FILTER_LINEAR else sdk.FILTER_NEAREST;
}

pub fn samplerMipmapMode(f: e.Filter) i32 {
    return if (f == .linear) sdk.SAMPLER_MIPMAP_MODE_LINEAR else sdk.SAMPLER_MIPMAP_MODE_NEAREST;
}

pub fn samplerAddressMode(w: e.Wrap) i32 {
    return switch (w) {
        .repeat => sdk.SAMPLER_ADDRESS_MODE_REPEAT,
        .clamp_to_edge => sdk.SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE,
        .clamp_to_border => sdk.SAMPLER_ADDRESS_MODE_CLAMP_TO_BORDER,
        .mirrored_repeat => sdk.SAMPLER_ADDRESS_MODE_MIRRORED_REPEAT,
        else => unreachable,
    };
}

pub fn samplerBorderColor(c: e.BorderColor) i32 {
    return switch (c) {
        .transparent_black => sdk.BORDER_COLOR_FLOAT_TRANSPARENT_BLACK,
        .opaque_black => sdk.BORDER_COLOR_FLOAT_OPAQUE_BLACK,
        .opaque_white => sdk.BORDER_COLOR_FLOAT_OPAQUE_WHITE,
        else => unreachable,
    };
}
