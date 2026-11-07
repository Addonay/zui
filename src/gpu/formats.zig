//! Format tables and texture/uniform layout calculations from sokol_gfx.h:9269-9693.
const std = @import("std");
const enums = @import("enums.zig");

pub fn vertexSize(format: enums.VertexFormat) i32 {
    return switch (format) {
        .float => 4,
        .float2 => 8,
        .float3 => 12,
        .float4 => 16,
        .int => 4,
        .int2 => 8,
        .int3 => 12,
        .int4 => 16,
        .uint => 4,
        .uint2 => 8,
        .uint3 => 12,
        .uint4 => 16,
        .byte4 => 4,
        .byte4n => 4,
        .ubyte4 => 4,
        .ubyte4n => 4,
        .short2 => 4,
        .short2n => 4,
        .ushort2 => 4,
        .ushort2n => 4,
        .short4 => 8,
        .short4n => 8,
        .ushort4 => 8,
        .ushort4n => 8,
        .int10_n2 => 4,
        .uint10_n2 => 4,
        .half2 => 4,
        .half4 => 8,
        .invalid => 0,
        else => unreachable,
    };
}

pub fn vertexName(format: enums.VertexFormat) [:0]const u8 {
    return switch (format) {
        .float => "FLOAT",
        .float2 => "FLOAT2",
        .float3 => "FLOAT3",
        .float4 => "FLOAT4",
        .int => "INT",
        .int2 => "INT2",
        .int3 => "INT3",
        .int4 => "INT4",
        .uint => "UINT",
        .uint2 => "UINT2",
        .uint3 => "UINT3",
        .uint4 => "UINT4",
        .byte4 => "BYTE4",
        .byte4n => "BYTE4N",
        .ubyte4 => "UBYTE4",
        .ubyte4n => "UBYTE4N",
        .short2 => "SHORT2",
        .short2n => "SHORT2N",
        .ushort2 => "USHORT2",
        .ushort2n => "USHORT2N",
        .short4 => "SHORT4",
        .short4n => "SHORT4N",
        .ushort4 => "USHORT4",
        .ushort4n => "USHORT4N",
        .int10_n2 => "INT10_N2",
        .uint10_n2 => "UINT10_N2",
        .half2 => "HALF2",
        .half4 => "HALF4",
        else => unreachable,
    };
}

pub fn shaderAttrBaseTypeName(format: enums.ShaderAttrBaseType) [:0]const u8 {
    return switch (format) {
        .undefined => "UNDEFINED",
        .float => "FLOAT",
        .sint => "SINT",
        .uint => "UINT",
        else => unreachable,
    };
}

pub fn vertexBaseType(format: enums.VertexFormat) enums.ShaderAttrBaseType {
    return switch (format) {
        .float, .float2, .float3, .float4, .half2, .half4, .byte4n, .ubyte4n, .short2n, .ushort2n, .short4n, .ushort4n, .int10_n2, .uint10_n2 => .float,
        .int, .int2, .int3, .int4, .byte4, .short2, .short4 => .sint,
        .uint, .uint2, .uint3, .uint4, .ubyte4, .ushort2, .ushort4 => .uint,
        else => unreachable,
    };
}

pub fn isCompressed(format: enums.PixelFormat) bool {
    return switch (format) {
        .bc1_rgba, .bc2_rgba, .bc3_rgba, .bc3_srgba, .bc4_r, .bc4_rsn, .bc5_rg, .bc5_rgsn, .bc6h_rgbf, .bc6h_rgbuf, .bc7_rgba, .bc7_srgba, .etc2_rgb8, .etc2_srgb8, .etc2_rgb8a1, .etc2_rgba8, .etc2_srgb8a8, .eac_r11, .eac_r11sn, .eac_rg11, .eac_rg11sn, .astc_4x4_rgba, .astc_4x4_srgba => true,
        else => false,
    };
}

pub fn isSrgb(format: enums.PixelFormat) bool {
    return switch (format) {
        .srgb8a8, .sbgr8a8 => true,
        else => false,
    };
}

pub fn pixelSize(format: enums.PixelFormat) i32 {
    return switch (format) {
        .r8, .r8sn, .r8ui, .r8si => 1,
        .r16, .r16sn, .r16ui, .r16si, .r16f, .rg8, .rg8sn, .rg8ui, .rg8si => 2,
        .r32ui, .r32si, .r32f, .rg16, .rg16sn, .rg16ui, .rg16si, .rg16f, .rgba8, .srgb8a8, .rgba8sn, .rgba8ui, .rgba8si, .bgra8, .sbgr8a8, .rgb10a2, .rg11b10f, .rgb9e5 => 4,
        .rg32ui, .rg32si, .rg32f, .rgba16, .rgba16sn, .rgba16ui, .rgba16si, .rgba16f => 8,
        .rgba32ui, .rgba32si, .rgba32f => 16,
        .depth, .depth_stencil => 4,
        else => unreachable,
    };
}

pub fn blockSize(format: enums.PixelFormat) i32 {
    return switch (format) {
        .bc1_rgba, .bc4_r, .bc4_rsn, .etc2_rgb8, .etc2_srgb8, .etc2_rgb8a1, .eac_r11, .eac_r11sn => 8,
        .bc2_rgba, .bc3_rgba, .bc3_srgba, .bc5_rg, .bc5_rgsn, .bc6h_rgbf, .bc6h_rgbuf, .bc7_rgba, .bc7_srgba, .etc2_rgba8, .etc2_srgb8a8, .eac_rg11, .eac_rg11sn, .astc_4x4_rgba, .astc_4x4_srgba => 16,
        else => pixelSize(format),
    };
}

pub fn blockDimension(format: enums.PixelFormat) i32 {
    return if (isCompressed(format)) 4 else 1;
}

pub fn rowPitch(format: enums.PixelFormat, width: i32, alignment: i32) i32 {
    std.debug.assert(width >= 0 and alignment > 0 and std.math.isPowerOfTwo(alignment));
    const dimension = blockDimension(format);
    const bytes = blockSize(format);
    const blocks = @divTrunc(width + dimension - 1, dimension);
    const pitch = @max(blocks * bytes, bytes);
    return (pitch + alignment - 1) & ~(alignment - 1);
}

pub fn numRows(format: enums.PixelFormat, height: i32) i32 {
    std.debug.assert(height >= 0);
    const dimension = blockDimension(format);
    return @max(@divTrunc(height + dimension - 1, dimension), 1);
}

pub fn surfacePitch(format: enums.PixelFormat, width: i32, height: i32, alignment: i32) i32 {
    return numRows(format, height) * rowPitch(format, width, alignment);
}

pub fn imageCopySize(format: enums.PixelFormat, bytes_per_row: i32, bytes_per_slice: i32, width: i32, height: i32, num_slices: i32) usize {
    std.debug.assert(width > 0 and height > 0 and num_slices > 0);
    // like the original's size_t arithmetic, negative pitches wrap around, which
    // makes the overflow validation of a copy with a negative pitch fail
    const wrap = struct {
        fn f(value: i32) usize {
            return @bitCast(@as(isize, value));
        }
    }.f;
    return wrap(num_slices - 1) *% wrap(bytes_per_slice) +%
        wrap(numRows(format, height) - 1) *% wrap(bytes_per_row) +%
        wrap(rowPitch(format, width, 1));
}

pub fn mipDimension(base: i32, level: i32) i32 {
    std.debug.assert(base > 0 and level >= 0 and level < 32);
    return @max(base >> @as(u5, @intCast(level)), 1);
}

pub fn uniformAlignment(kind: enums.UniformType, count: u32, layout: enums.UniformLayout) u32 {
    if (layout == .native) return 1;
    std.debug.assert(count > 0);
    if (count > 1) return 16;
    return switch (kind) {
        .float, .int => 4,
        .float2, .int2 => 8,
        .float3, .float4, .int3, .int4, .mat4 => 16,
        else => unreachable,
    };
}

pub fn uniformSize(kind: enums.UniformType, count: u32, layout: enums.UniformLayout) u32 {
    std.debug.assert(count > 0);
    const size: u32 = switch (kind) {
        .float, .int => 4,
        .float2, .int2 => 8,
        .float3, .int3 => 12,
        .float4, .int4 => 16,
        .mat4 => 64,
        else => unreachable,
    };
    return (if (count > 1 and layout != .native) @max(size, 16) else size) * count;
}
