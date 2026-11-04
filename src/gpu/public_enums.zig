//! Public enumerations: the internal (sokol-shaped) enumerations without their
//! "default"/"invalid" placeholder members, which the public API expresses as
//! optional values or field defaults instead. Values are identical, so converting
//! to the internal enumeration is free. Generated from enums.zig.

pub const PixelFormat = enum(u32) {
    none = 1,
    r8 = 2,
    r8sn = 3,
    r8ui = 4,
    r8si = 5,
    r16 = 6,
    r16sn = 7,
    r16ui = 8,
    r16si = 9,
    r16f = 10,
    rg8 = 11,
    rg8sn = 12,
    rg8ui = 13,
    rg8si = 14,
    r32ui = 15,
    r32si = 16,
    r32f = 17,
    rg16 = 18,
    rg16sn = 19,
    rg16ui = 20,
    rg16si = 21,
    rg16f = 22,
    rgba8 = 23,
    srgb8a8 = 24,
    rgba8sn = 25,
    rgba8ui = 26,
    rgba8si = 27,
    bgra8 = 28,
    sbgr8a8 = 29,
    rgb10a2 = 30,
    rg11b10f = 31,
    rgb9e5 = 32,
    rg32ui = 33,
    rg32si = 34,
    rg32f = 35,
    rgba16 = 36,
    rgba16sn = 37,
    rgba16ui = 38,
    rgba16si = 39,
    rgba16f = 40,
    rgba32ui = 41,
    rgba32si = 42,
    rgba32f = 43,
    depth = 44,
    depth_stencil = 45,
    bc1_rgba = 46,
    bc2_rgba = 47,
    bc3_rgba = 48,
    bc3_srgba = 49,
    bc4_r = 50,
    bc4_rsn = 51,
    bc5_rg = 52,
    bc5_rgsn = 53,
    bc6h_rgbf = 54,
    bc6h_rgbuf = 55,
    bc7_rgba = 56,
    bc7_srgba = 57,
    etc2_rgb8 = 58,
    etc2_srgb8 = 59,
    etc2_rgb8a1 = 60,
    etc2_rgba8 = 61,
    etc2_srgb8a8 = 62,
    eac_r11 = 63,
    eac_r11sn = 64,
    eac_rg11 = 65,
    eac_rg11sn = 66,
    astc_4x4_rgba = 67,
    astc_4x4_srgba = 68,
};
pub const IndexType = enum(u32) {
    none = 1,
    uint16 = 2,
    uint32 = 3,
};
pub const ImageType = enum(u32) {
    @"2d" = 1,
    cube = 2,
    @"3d" = 3,
    array = 4,
};
pub const ImageSampleType = enum(u32) {
    float = 1,
    depth = 2,
    sint = 3,
    uint = 4,
    unfilterable_float = 5,
};
pub const SamplerType = enum(u32) {
    filtering = 1,
    nonfiltering = 2,
    comparison = 3,
};
pub const PrimitiveType = enum(u32) {
    points = 1,
    lines = 2,
    line_strip = 3,
    triangles = 4,
    triangle_strip = 5,
};
pub const Filter = enum(u32) {
    nearest = 1,
    linear = 2,
};
pub const Wrap = enum(u32) {
    repeat = 1,
    clamp_to_edge = 2,
    clamp_to_border = 3,
    mirrored_repeat = 4,
};
pub const BorderColor = enum(u32) {
    transparent_black = 1,
    opaque_black = 2,
    opaque_white = 3,
};
pub const VertexFormat = enum(u32) {
    float = 1,
    float2 = 2,
    float3 = 3,
    float4 = 4,
    int = 5,
    int2 = 6,
    int3 = 7,
    int4 = 8,
    uint = 9,
    uint2 = 10,
    uint3 = 11,
    uint4 = 12,
    byte4 = 13,
    byte4n = 14,
    ubyte4 = 15,
    ubyte4n = 16,
    short2 = 17,
    short2n = 18,
    ushort2 = 19,
    ushort2n = 20,
    short4 = 21,
    short4n = 22,
    ushort4 = 23,
    ushort4n = 24,
    int10_n2 = 25,
    uint10_n2 = 26,
    half2 = 27,
    half4 = 28,
};
pub const VertexStep = enum(u32) {
    per_vertex = 1,
    per_instance = 2,
};
pub const UniformType = enum(u32) {
    float = 1,
    float2 = 2,
    float3 = 3,
    float4 = 4,
    int = 5,
    int2 = 6,
    int3 = 7,
    int4 = 8,
    mat4 = 9,
};
pub const UniformLayout = enum(u32) {
    native = 1,
    std140 = 2,
};
pub const CullMode = enum(u32) {
    none = 1,
    front = 2,
    back = 3,
};
pub const FaceWinding = enum(u32) {
    ccw = 1,
    cw = 2,
};
pub const CompareFunc = enum(u32) {
    never = 1,
    less = 2,
    equal = 3,
    less_equal = 4,
    greater = 5,
    not_equal = 6,
    greater_equal = 7,
    always = 8,
};
pub const StencilOp = enum(u32) {
    keep = 1,
    zero = 2,
    replace = 3,
    incr_clamp = 4,
    decr_clamp = 5,
    invert = 6,
    incr_wrap = 7,
    decr_wrap = 8,
};
pub const BlendFactor = enum(u32) {
    zero = 1,
    one = 2,
    src_color = 3,
    one_minus_src_color = 4,
    src_alpha = 5,
    one_minus_src_alpha = 6,
    dst_color = 7,
    one_minus_dst_color = 8,
    dst_alpha = 9,
    one_minus_dst_alpha = 10,
    src_alpha_saturated = 11,
    blend_color = 12,
    one_minus_blend_color = 13,
    blend_alpha = 14,
    one_minus_blend_alpha = 15,
    src1_color = 16,
    one_minus_src1_color = 17,
    src1_alpha = 18,
    one_minus_src1_alpha = 19,
};
pub const BlendOp = enum(u32) {
    add = 1,
    subtract = 2,
    reverse_subtract = 3,
    min = 4,
    max = 5,
};
pub const ColorMask = enum(u32) {
    none = 16,
    r = 1,
    g = 2,
    rg = 3,
    b = 4,
    rb = 5,
    gb = 6,
    rgb = 7,
    a = 8,
    ra = 9,
    ga = 10,
    rga = 11,
    ba = 12,
    rba = 13,
    gba = 14,
    rgba = 15,
};
pub const ShaderStage = enum(u32) {
    vertex = 1,
    fragment = 2,
    compute = 3,
};
pub const ShaderAttrBaseType = enum(u32) {
    float = 1,
    sint = 2,
    uint = 3,
};
pub const ResourceState = enum(u32) {
    initial = 0,
    alloc = 1,
    unsealed = 2,
    valid = 3,
    failed = 4,
    invalid = 5,
};
pub const ViewType = enum(u32) {
    storagebuffer = 1,
    storageimage = 2,
    texture = 3,
    colorattachment = 4,
    resolveattachment = 5,
    depthstencilattachment = 6,
};
pub const PassState = enum(u32) {
    none = 0,
    render = 1,
    compute = 2,
};
