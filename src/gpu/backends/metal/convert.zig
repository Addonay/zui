//! Sokol-to-Metal enum conversion, from sokol_gfx.h:16010-16140 (enum translation
//! functions). Platform-dependent formats take a `macos` flag, the equivalent of
//! `_SG_TARGET_MACOS`.
const e = @import("../../enums.zig");
const sdk = @import("sdk.zig");

pub fn loadAction(a: e.LoadAction) sdk.LoadAction {
    return switch (a) {
        .clear => .clear,
        .load => .load,
        .dontcare => .dont_care,
        else => unreachable,
    };
}

pub fn storeAction(a: e.StoreAction, resolve: bool) sdk.StoreAction {
    return switch (a) {
        .store => if (resolve) .store_and_multisample_resolve else .store,
        .dontcare => if (resolve) .multisample_resolve else .dont_care,
        else => unreachable,
    };
}

pub fn vertexStep(step: e.VertexStep) sdk.VertexStepFunction {
    return switch (step) {
        .per_vertex => .per_vertex,
        .per_instance => .per_instance,
        else => unreachable,
    };
}

pub fn vertexFormat(fmt: e.VertexFormat) sdk.VertexFormat {
    return switch (fmt) {
        .float => .float,
        .float2 => .float2,
        .float3 => .float3,
        .float4 => .float4,
        .int => .int,
        .int2 => .int2,
        .int3 => .int3,
        .int4 => .int4,
        .uint => .uint,
        .uint2 => .uint2,
        .uint3 => .uint3,
        .uint4 => .uint4,
        .byte4 => .char4,
        .byte4n => .char4normalized,
        .ubyte4 => .uchar4,
        .ubyte4n => .uchar4normalized,
        .short2 => .short2,
        .short2n => .short2normalized,
        .ushort2 => .ushort2,
        .ushort2n => .ushort2normalized,
        .short4 => .short4,
        .short4n => .short4normalized,
        .ushort4 => .ushort4,
        .ushort4n => .ushort4normalized,
        .int10_n2 => .int1010102normalized,
        .uint10_n2 => .uint1010102normalized,
        .half2 => .half2,
        .half4 => .half4,
        else => unreachable,
    };
}

pub fn primitiveType(p: e.PrimitiveType) sdk.PrimitiveType {
    return switch (p) {
        .points => .point,
        .lines => .line,
        .line_strip => .line_strip,
        .triangles => .triangle,
        .triangle_strip => .triangle_strip,
        else => unreachable,
    };
}

/// _sg_mtl_pixel_format(). Block-compressed formats are macOS only, the other
/// compressed formats are iOS only.
pub fn pixelFormat(fmt: e.PixelFormat, macos: bool) sdk.PixelFormat {
    return switch (fmt) {
        .r8 => .r8unorm,
        .r8sn => .r8snorm,
        .r8ui => .r8uint,
        .r8si => .r8sint,
        .r16 => .r16unorm,
        .r16sn => .r16snorm,
        .r16ui => .r16uint,
        .r16si => .r16sint,
        .r16f => .r16float,
        .rg8 => .rg8unorm,
        .rg8sn => .rg8snorm,
        .rg8ui => .rg8uint,
        .rg8si => .rg8sint,
        .r32ui => .r32uint,
        .r32si => .r32sint,
        .r32f => .r32float,
        .rg16 => .rg16unorm,
        .rg16sn => .rg16snorm,
        .rg16ui => .rg16uint,
        .rg16si => .rg16sint,
        .rg16f => .rg16float,
        .rgba8 => .rgba8unorm,
        .srgb8a8 => .rgba8unorm_srgb,
        .rgba8sn => .rgba8snorm,
        .rgba8ui => .rgba8uint,
        .rgba8si => .rgba8sint,
        .bgra8 => .bgra8unorm,
        .sbgr8a8 => .bgra8unorm_srgb,
        .rgb10a2 => .rgb10a2unorm,
        .rg11b10f => .rg11b10float,
        .rgb9e5 => .rgb9e5float,
        .rg32ui => .rg32uint,
        .rg32si => .rg32sint,
        .rg32f => .rg32float,
        .rgba16 => .rgba16unorm,
        .rgba16sn => .rgba16snorm,
        .rgba16ui => .rgba16uint,
        .rgba16si => .rgba16sint,
        .rgba16f => .rgba16float,
        .rgba32ui => .rgba32uint,
        .rgba32si => .rgba32sint,
        .rgba32f => .rgba32float,
        .depth => .depth32float,
        .depth_stencil => .depth32float_stencil8,
        .bc1_rgba => if (macos) .bc1_rgba else .invalid,
        .bc2_rgba => if (macos) .bc2_rgba else .invalid,
        .bc3_rgba => if (macos) .bc3_rgba else .invalid,
        .bc3_srgba => if (macos) .bc3_rgba_srgb else .invalid,
        .bc4_r => if (macos) .bc4_runorm else .invalid,
        .bc4_rsn => if (macos) .bc4_rsnorm else .invalid,
        .bc5_rg => if (macos) .bc5_rgunorm else .invalid,
        .bc5_rgsn => if (macos) .bc5_rgsnorm else .invalid,
        .bc6h_rgbf => if (macos) .bc6h_rgbfloat else .invalid,
        .bc6h_rgbuf => if (macos) .bc6h_rgbufloat else .invalid,
        .bc7_rgba => if (macos) .bc7_rgbaunorm else .invalid,
        .bc7_srgba => if (macos) .bc7_rgbaunorm_srgb else .invalid,
        .etc2_rgb8 => if (macos) .invalid else .etc2_rgb8,
        .etc2_srgb8 => if (macos) .invalid else .etc2_rgb8_srgb,
        .etc2_rgb8a1 => if (macos) .invalid else .etc2_rgb8a1,
        .etc2_rgba8 => if (macos) .invalid else .eac_rgba8,
        .etc2_srgb8a8 => if (macos) .invalid else .eac_rgba8_srgb,
        .eac_r11 => if (macos) .invalid else .eac_r11unorm,
        .eac_r11sn => if (macos) .invalid else .eac_r11snorm,
        .eac_rg11 => if (macos) .invalid else .eac_rg11unorm,
        .eac_rg11sn => if (macos) .invalid else .eac_rg11snorm,
        .astc_4x4_rgba => if (macos) .invalid else .astc_4x4_ldr,
        .astc_4x4_srgba => if (macos) .invalid else .astc_4x4_srgb,
        else => .invalid,
    };
}

/// _sg_mtl_color_write_mask(). The sokol mask bits are R=1, G=2, B=4, A=8.
pub fn colorWriteMask(m: e.ColorMask) sdk.Uint {
    const bits = @backingInt(m);
    var res: sdk.Uint = sdk.color_write_mask_none;
    if (bits & 1 != 0) res |= sdk.color_write_mask_red;
    if (bits & 2 != 0) res |= sdk.color_write_mask_green;
    if (bits & 4 != 0) res |= sdk.color_write_mask_blue;
    if (bits & 8 != 0) res |= sdk.color_write_mask_alpha;
    return res;
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

pub fn blendFactor(f: e.BlendFactor) sdk.BlendFactor {
    return switch (f) {
        .zero => .zero,
        .one => .one,
        .src_color => .source_color,
        .one_minus_src_color => .one_minus_source_color,
        .src_alpha => .source_alpha,
        .one_minus_src_alpha => .one_minus_source_alpha,
        .dst_color => .destination_color,
        .one_minus_dst_color => .one_minus_destination_color,
        .dst_alpha => .destination_alpha,
        .one_minus_dst_alpha => .one_minus_destination_alpha,
        .src_alpha_saturated => .source_alpha_saturated,
        .blend_color => .blend_color,
        .one_minus_blend_color => .one_minus_blend_color,
        .blend_alpha => .blend_alpha,
        .one_minus_blend_alpha => .one_minus_blend_alpha,
        .src1_color => .source1_color,
        .one_minus_src1_color => .one_minus_source1_color,
        .src1_alpha => .source1_alpha,
        .one_minus_src1_alpha => .one_minus_source1_alpha,
        else => unreachable,
    };
}

pub fn compareFunc(f: e.CompareFunc) sdk.CompareFunction {
    return switch (f) {
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

pub fn cullMode(m: e.CullMode) sdk.CullMode {
    return switch (m) {
        .none => .none,
        .front => .front,
        .back => .back,
        else => unreachable,
    };
}

pub fn winding(w: e.FaceWinding) sdk.Winding {
    return switch (w) {
        .cw => .clockwise,
        .ccw => .counter_clockwise,
        else => unreachable,
    };
}

pub fn indexType(t: e.IndexType) sdk.IndexType {
    return switch (t) {
        .uint16 => .uint16,
        .uint32 => .uint32,
        else => unreachable,
    };
}

/// _sg_mtl_index_size(): bytes per index, 0 without an index buffer.
pub fn indexSize(t: e.IndexType) i32 {
    return switch (t) {
        .none => 0,
        .uint16 => 2,
        .uint32 => 4,
        else => unreachable,
    };
}

pub fn textureType(t: e.ImageType, msaa: bool) sdk.TextureType {
    return switch (t) {
        .@"2d" => if (msaa) .type_2d_multisample else .type_2d,
        .cube => .type_cube,
        .@"3d" => .type_3d,
        .array => .type_2d_array,
        else => unreachable,
    };
}

/// _sg_mtl_address_mode(). Clamp-to-border needs the image_clamp_to_border feature,
/// without it the wrap mode falls back to clamp-to-edge.
pub fn addressMode(w: e.Wrap, clamp_to_border: bool) sdk.SamplerAddressMode {
    return switch (w) {
        .repeat => .repeat,
        .clamp_to_edge => .clamp_to_edge,
        .clamp_to_border => if (clamp_to_border) .clamp_to_border_color else .clamp_to_edge,
        .mirrored_repeat => .mirror_repeat,
        else => unreachable,
    };
}

pub fn borderColor(c: e.BorderColor) sdk.SamplerBorderColor {
    return switch (c) {
        .transparent_black => .transparent_black,
        .opaque_black => .opaque_black,
        .opaque_white => .opaque_white,
        else => unreachable,
    };
}

pub fn minMagFilter(f: e.Filter) sdk.SamplerMinMagFilter {
    return switch (f) {
        .nearest => .nearest,
        .linear => .linear,
        else => unreachable,
    };
}

pub fn mipFilter(f: e.Filter) sdk.SamplerMipFilter {
    return switch (f) {
        .nearest => .nearest,
        .linear => .linear,
        else => unreachable,
    };
}
