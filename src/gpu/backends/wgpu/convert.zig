//! Conversions from sokol-gfx enums to webgpu.h enums, ported from the `_sg_wgpu_*`
//! helpers of sokol_gfx.h:18428-18700. Sokol values are validated before they arrive
//! here, so unhandled values are unreachable.
const std = @import("std");
const t = @import("../../types.zig");
const e = @import("../../enums.zig");
const sdk = @import("sdk.zig");

pub fn stringView(label: ?[*:0]const u8) sdk.StringView {
    const text = label orelse return .{};
    return .{ .data = text, .length = std.mem.len(text) };
}

pub fn optionalBool(value: bool) sdk.OptionalBool {
    return if (value) .true else .false;
}

pub fn bufferUsage(usg: t.BufferUsage) u64 {
    var res: u64 = 0;
    if (usg.vertex_buffer) res |= sdk.BufferUsage.vertex;
    if (usg.index_buffer) res |= sdk.BufferUsage.index;
    if (usg.storage_buffer) res |= sdk.BufferUsage.storage;
    if (usg.copy_src) res |= sdk.BufferUsage.copy_src;
    if (usg.copy_dst or usg.write_transient) res |= sdk.BufferUsage.copy_dst;
    return res;
}

pub fn loadOp(view: ?sdk.TextureView, action: e.LoadAction) sdk.LoadOp {
    if (view == null) return .undefined;
    return switch (action) {
        .clear, .dontcare => .clear,
        .load => .load,
        else => unreachable,
    };
}

pub fn storeOp(view: ?sdk.TextureView, action: e.StoreAction) sdk.StoreOp {
    if (view == null) return .undefined;
    return switch (action) {
        .store => .store,
        .dontcare => .discard,
        else => unreachable,
    };
}

pub fn textureViewDimension(image_type: e.ImageType) sdk.TextureViewDimension {
    return switch (image_type) {
        .@"2d" => .@"2_d",
        .cube => .cube,
        .@"3d" => .@"3_d",
        .array => .@"2_d_array",
        else => unreachable,
    };
}

/// Cube and 3D images are attached as 2D array and 2D views (sokol_gfx.h "not a bug").
pub fn attachmentViewDimension(image_type: e.ImageType) sdk.TextureViewDimension {
    return switch (image_type) {
        .@"2d" => .@"2_d",
        .cube => .@"2_d_array",
        .@"3d" => .@"2_d",
        .array => .@"2_d_array",
        else => unreachable,
    };
}

pub fn textureDimension(image_type: e.ImageType) sdk.TextureDimension {
    return if (image_type == .@"3d") .@"3_d" else .@"2_d";
}

pub fn textureSampleType(sample_type: e.ImageSampleType, msaa: bool) sdk.TextureSampleType {
    return switch (sample_type) {
        .float => if (msaa) .unfilterable_float else .float,
        .depth => .depth,
        .sint => .sint,
        .uint => .uint,
        .unfilterable_float => .unfilterable_float,
        else => unreachable,
    };
}

pub fn samplerBindingType(sampler_type: e.SamplerType) sdk.SamplerBindingType {
    return switch (sampler_type) {
        .filtering => .filtering,
        .comparison => .comparison,
        .nonfiltering => .non_filtering,
        else => unreachable,
    };
}

pub fn addressMode(wrap: e.Wrap) sdk.AddressMode {
    return switch (wrap) {
        .repeat => .repeat,
        .clamp_to_edge, .clamp_to_border => .clamp_to_edge,
        .mirrored_repeat => .mirror_repeat,
        else => unreachable,
    };
}

pub fn minMagFilter(filter: e.Filter) sdk.FilterMode {
    return switch (filter) {
        .nearest => .nearest,
        .linear => .linear,
        else => unreachable,
    };
}

pub fn mipmapFilter(filter: e.Filter) sdk.MipmapFilterMode {
    return switch (filter) {
        .nearest => .nearest,
        .linear => .linear,
        else => unreachable,
    };
}

pub fn indexFormat(index_type: e.IndexType) sdk.IndexFormat {
    // there is no webgpu IndexFormat for "none"
    return if (index_type == .uint16) .uint16 else .uint32;
}

pub fn stripIndexFormat(primitive: e.PrimitiveType, index_type: e.IndexType) sdk.IndexFormat {
    if (index_type == .none) return .undefined;
    return switch (primitive) {
        .line_strip, .triangle_strip => indexFormat(index_type),
        else => .undefined,
    };
}

pub fn stepMode(step: e.VertexStep) sdk.VertexStepMode {
    return if (step == .per_vertex) .vertex else .instance;
}

pub fn vertexFormat(format: e.VertexFormat) sdk.VertexFormat {
    return switch (format) {
        .float => .float32,
        .float2 => .float32x2,
        .float3 => .float32x3,
        .float4 => .float32x4,
        .int => .sint32,
        .int2 => .sint32x2,
        .int3 => .sint32x3,
        .int4 => .sint32x4,
        .uint => .uint32,
        .uint2 => .uint32x2,
        .uint3 => .uint32x3,
        .uint4 => .uint32x4,
        .byte4 => .sint8x4,
        .byte4n => .snorm8x4,
        .ubyte4 => .uint8x4,
        .ubyte4n => .unorm8x4,
        .short2 => .sint16x2,
        .short2n => .snorm16x2,
        .ushort2 => .uint16x2,
        .ushort2n => .unorm16x2,
        .short4 => .sint16x4,
        .short4n => .snorm16x4,
        .ushort4 => .uint16x4,
        .ushort4n => .unorm16x4,
        .uint10_n2 => .unorm10_10_10_2,
        .half2 => .float16x2,
        .half4 => .float16x4,
        else => unreachable,
    };
}

pub fn topology(primitive: e.PrimitiveType) sdk.PrimitiveTopology {
    return switch (primitive) {
        .points => .point_list,
        .lines => .line_list,
        .line_strip => .line_strip,
        .triangles => .triangle_list,
        .triangle_strip => .triangle_strip,
        else => unreachable,
    };
}

pub fn frontFace(winding: e.FaceWinding) sdk.FrontFace {
    return if (winding == .ccw) .ccw else .cw;
}

pub fn cullMode(mode: e.CullMode) sdk.CullMode {
    return switch (mode) {
        .none => .none,
        .front => .front,
        .back => .back,
        else => unreachable,
    };
}

pub fn textureFormat(format: e.PixelFormat) sdk.TextureFormat {
    return switch (format) {
        .none => .undefined,
        .r8 => .r8_unorm,
        .r8sn => .r8_snorm,
        .r8ui => .r8_uint,
        .r8si => .r8_sint,
        .r16 => .r16_unorm,
        .r16sn => .r16_snorm,
        .r16ui => .r16_uint,
        .r16si => .r16_sint,
        .r16f => .r16_float,
        .rg8 => .rg8_unorm,
        .rg8sn => .rg8_snorm,
        .rg8ui => .rg8_uint,
        .rg8si => .rg8_sint,
        .r32ui => .r32_uint,
        .r32si => .r32_sint,
        .r32f => .r32_float,
        .rg16 => .rg16_unorm,
        .rg16sn => .rg16_snorm,
        .rg16ui => .rg16_uint,
        .rg16si => .rg16_sint,
        .rg16f => .rg16_float,
        .rgba8 => .rgba8_unorm,
        .srgb8a8 => .rgba8_unorm_srgb,
        .rgba8sn => .rgba8_snorm,
        .rgba8ui => .rgba8_uint,
        .rgba8si => .rgba8_sint,
        .bgra8 => .bgra8_unorm,
        .sbgr8a8 => .bgra8_unorm_srgb,
        .rgb10a2 => .rgb10_a2_unorm,
        .rg11b10f => .rg11_b10_ufloat,
        .rgb9e5 => .rgb9_e5_ufloat,
        .rg32ui => .rg32_uint,
        .rg32si => .rg32_sint,
        .rg32f => .rg32_float,
        .rgba16 => .rgba16_unorm,
        .rgba16sn => .rgba16_snorm,
        .rgba16ui => .rgba16_uint,
        .rgba16si => .rgba16_sint,
        .rgba16f => .rgba16_float,
        .rgba32ui => .rgba32_uint,
        .rgba32si => .rgba32_sint,
        .rgba32f => .rgba32_float,
        .depth => .depth32_float,
        .depth_stencil => .depth32_float_stencil8,
        .bc1_rgba => .bc1_rgba_unorm,
        .bc2_rgba => .bc2_rgba_unorm,
        .bc3_rgba => .bc3_rgba_unorm,
        .bc3_srgba => .bc3_rgba_unorm_srgb,
        .bc4_r => .bc4_r_unorm,
        .bc4_rsn => .bc4_r_snorm,
        .bc5_rg => .bc5_rg_unorm,
        .bc5_rgsn => .bc5_rg_snorm,
        .bc6h_rgbf => .bc6_hrgb_float,
        .bc6h_rgbuf => .bc6_hrgb_ufloat,
        .bc7_rgba => .bc7_rgba_unorm,
        .bc7_srgba => .bc7_rgba_unorm_srgb,
        .etc2_rgb8 => .etc2_rgb8_unorm,
        .etc2_srgb8 => .etc2_rgb8_unorm_srgb,
        .etc2_rgb8a1 => .etc2_rgb8_a1_unorm,
        .etc2_rgba8 => .etc2_rgba8_unorm,
        .etc2_srgb8a8 => .etc2_rgba8_unorm_srgb,
        .eac_r11 => .eacr11_unorm,
        .eac_r11sn => .eacr11_snorm,
        .eac_rg11 => .eacrg11_unorm,
        .eac_rg11sn => .eacrg11_snorm,
        .astc_4x4_rgba => .astc4x4_unorm,
        .astc_4x4_srgba => .astc4x4_unorm_srgb,
        .default => unreachable,
        else => unreachable,
    };
}

pub fn compareFunc(func: e.CompareFunc) sdk.CompareFunction {
    return switch (func) {
        .never => .never,
        .less => .less,
        .equal => .equal,
        .less_equal => .less_equal,
        .greater => .greater,
        .not_equal => .not_equal,
        .greater_equal => .greater_equal,
        .always => .always,
        else => unreachable,
    };
}

pub fn stencilOp(op: e.StencilOp) sdk.StencilOperation {
    return switch (op) {
        .keep => .keep,
        .zero => .zero,
        .replace => .replace,
        .incr_clamp => .increment_clamp,
        .decr_clamp => .decrement_clamp,
        .invert => .invert,
        .incr_wrap => .increment_wrap,
        .decr_wrap => .decrement_wrap,
        else => unreachable,
    };
}

pub fn blendOp(op: e.BlendOp) sdk.BlendOperation {
    return switch (op) {
        .add => .add,
        .subtract => .subtract,
        .reverse_subtract => .reverse_subtract,
        .min => .min,
        .max => .max,
        else => unreachable,
    };
}

pub fn blendFactor(factor: e.BlendFactor) sdk.BlendFactor {
    return switch (factor) {
        .zero => .zero,
        .one => .one,
        .src_color => .src,
        .one_minus_src_color => .one_minus_src,
        .src_alpha => .src_alpha,
        .one_minus_src_alpha => .one_minus_src_alpha,
        .dst_color => .dst,
        .one_minus_dst_color => .one_minus_dst,
        .dst_alpha => .dst_alpha,
        .one_minus_dst_alpha => .one_minus_dst_alpha,
        .src_alpha_saturated => .src_alpha_saturated,
        .blend_color, .blend_alpha => .constant,
        .one_minus_blend_color, .one_minus_blend_alpha => .one_minus_constant,
        .src1_color => .src1,
        .one_minus_src1_color => .one_minus_src1,
        .src1_alpha => .src1_alpha,
        .one_minus_src1_alpha => .one_minus_src1_alpha,
        else => unreachable,
    };
}

pub fn colorWriteMask(mask: e.ColorMask) u64 {
    // the sokol color mask bits (r=1, g=2, b=4, a=8) match the webgpu bit values
    return @as(u64, @intCast(@backingInt(mask) & 0xF));
}

pub fn shaderStage(stage: e.ShaderStage) u64 {
    return switch (stage) {
        .vertex => sdk.ShaderStage.vertex,
        .fragment => sdk.ShaderStage.fragment,
        .compute => sdk.ShaderStage.compute,
        else => unreachable,
    };
}
