//! GPU device abstraction: the full SDL_gpu contract, re-expressed in Zig.
//!
//! API contract modeled on SDL3's `SDL_gpu.h` (zlib license, Copyright
//! 1997-2026 Sam Lantinga) and its `src/gpu/<api>` driver split —
//! reimplemented, never copied verbatim. Workflow per frame:
//!
//! ```text
//! device.claimWindow(surface)            // once per window
//! cmd = device.acquireCommandBuffer()
//! swp = device.waitAndAcquireSwapchainTexture(&cmd, surface)
//! pass = device.beginRenderPass(&cmd, .{ .color_targets = &.{.{...}} })
//! pass.bindPipeline(pipe); pass.bindVertexBuffers(0, &.{...}); ...
//! pass.drawPrimitives(.{ .num_vertices = N, ... }); pass.end()
//! copy = device.beginCopyPass(&cmd); copy.uploadToTexture(...); copy.end()
//! device.submit(&cmd)
//! ```
//!
//! Zig adaptations (deliberate, documented):
//! - Opaque C pointers become `enum(u32)` handles (`.null == 0`) issued
//!   from fixed pools capped in `core/limits.zig`. No hidden allocation.
//! - Every `ptr + count` pair becomes a slice. Invalid combinations
//!   (empty color targets, over-cap bindings) fail fast with errors or
//!   debug asserts instead of UB.
//! - SDL's `SDL_PropertiesID` extension bag is omitted: drivers take
//!   explicit fields. If an extension is ever needed it becomes a real
//!   struct field, not a typeless map.
//! - Passes (`RenderPass`, `ComputePass`, `CopyPass`) are small Zig structs
//!   holding the `Device` + command buffer. Operating on a closed pass is
//!   a no-op (release-safe), mismatched begin/end asserts in debug.
//! - The ZUI 2D fast path (`claim` / `acquire` / `drawScene` / `submit` /
//!   `render`) stays: `Scene` quads+glyphs without hand-rolling passes.
//!
//! Capability model: every driver reports `shaderFormats()` and answers
//! `supportsTextureFormat` / `supportsSampleCount`. The `software` and
//! `null` drivers implement the whole vtable as validation + counting
//! (documented per function); real GPU work lands per driver in
//! `vulkan.zig`, `metal.zig`, `d3d12.zig`.
//!
//! Open gaps (each also marked TODO(gpu) at the relevant site):
//! - Real driver init/swapchain/pipelines: `vulkan.zig` (Phase 8b),
//!   `metal.zig`, `d3d12.zig`.
//! - Offline shader pipeline (SPIR-V/MSL/DXBC blobs via `@embedFile`).
//! - `Backend.present` routing `Scene` through a claimed `Device`
//!   (lands with the windowing phase in `platform/`).
//! - Deliberately omitted SDL surface: `SDL_PropertiesID` extension bags,
//!   GDK suspend/resume, `SDL_PixelFormat` mapping (see TODOs below).

const std = @import("std");
const limits = @import("../core/limits.zig");
const color_mod = @import("../core/color.zig");
const scene_mod = @import("scene.zig");

pub const Scene = scene_mod.Scene;
pub const Color = color_mod.Color;

// ============================================================================
// Device identity
// ============================================================================

/// Which render API backs a `Device`. `software` is the CPU rasterizer
/// (`software.zig` / `software_device.zig`); `null` validates and counts
/// for headless tests.
pub const DeviceKind = enum {
    software,
    vulkan,
    metal,
    d3d12,
    null,

    pub fn name(self: @This()) []const u8 {
        return switch (self) {
            .software => "software",
            .vulkan => "vulkan",
            .metal => "metal",
            .d3d12 => "d3d12",
            .null => "null",
        };
    }
};

/// Driver names in probe priority order, mirroring `SDL_GetGPUDriver`.
pub const driver_names: []const []const u8 = &.{ "vulkan", "metal", "direct3d12", "software" };

pub fn defaultDriver() []const u8 {
    return driver_names[0];
}

/// Opaque window surface handed from `platform/` to `claimWindow`. The
/// device stores only the tag + pointer; per-OS interpretation lives in
/// the driver (e.g. Vulkan picks `vkCreateWaylandSurfaceKHR` vs
/// `vkCreateXlibSurfaceKHR` by tag).
pub const SurfaceHandle = struct {
    tag: Tag,
    ptr: ?*anyopaque = null,

    pub const Tag = enum {
        wayland,
        x11,
        cocoa,
        win32,
        headless,
    };
};

/// One frame's command buffer. Real drivers encode passes here; the null
/// and software drivers use it as a frame counter / drop flag.
pub const CommandBuffer = struct {
    id: u64 = 0,
    dropped: bool = false,
};

/// Probe order for automatic selection: native GPU first, CPU fallback,
/// null last. Mirrors `platform.backend.preferredOrder()`.
pub fn preferredOrder() [3]DeviceKind {
    return .{ .vulkan, .software, .null };
}

// ============================================================================
// Handles (fixed-pool ids, never pointers)
// ============================================================================

pub const Buffer = enum(u32) { null = 0, _ };
pub const TransferBuffer = enum(u32) { null = 0, _ };
pub const Texture = enum(u32) { null = 0, _ };
pub const Sampler = enum(u32) { null = 0, _ };
pub const Shader = enum(u32) { null = 0, _ };
pub const ComputePipeline = enum(u32) { null = 0, _ };
pub const GraphicsPipeline = enum(u32) { null = 0, _ };
pub const Fence = enum(u32) { null = 0, _ };

pub const CreateError = error{
    OutOfHandles,
    InvalidUsage,
    UnsupportedFormat,
    Unsupported,
    OutOfMemory,
};

pub const MapError = error{
    UnknownHandle,
    OutOfBounds,
    Unsupported,
};

pub const SubmitError = error{
    Cancelled,
    DeviceLost,
    Unsupported,
};

// ============================================================================
// Enums (ordinals match SDL_gpu.h order for cross-reading traces)
// ============================================================================

pub const PrimitiveType = enum(u32) {
    triangle_list = 0,
    triangle_strip = 1,
    line_list = 2,
    line_strip = 3,
    point_list = 4,
};

pub const LoadOp = enum(u32) { load = 0, clear = 1, dont_care = 2 };
pub const StoreOp = enum(u32) { store = 0, dont_care = 1, resolve = 2, resolve_and_store = 3 };
pub const IndexElementSize = enum(u32) { bits_16 = 0, bits_32 = 1 };

pub const TextureFormat = enum(u32) {
    invalid = 0,
    a8_unorm = 1,
    r8_unorm = 2,
    r8g8_unorm = 3,
    r8g8b8a8_unorm = 4,
    r16_unorm = 5,
    r16g16_unorm = 6,
    r16g16b16a16_unorm = 7,
    r10g10b10a2_unorm = 8,
    b5g6r5_unorm = 9,
    b5g5r5a1_unorm = 10,
    b4g4r4a4_unorm = 11,
    b8g8r8a8_unorm = 12,
    bc1_rgba_unorm = 13,
    bc2_rgba_unorm = 14,
    bc3_rgba_unorm = 15,
    bc4_r_unorm = 16,
    bc5_rg_unorm = 17,
    bc7_rgba_unorm = 18,
    bc6h_rgb_float = 19,
    bc6h_rgb_ufloat = 20,
    r8_snorm = 21,
    r8g8_snorm = 22,
    r8g8b8a8_snorm = 23,
    r16_snorm = 24,
    r16g16_snorm = 25,
    r16g16b16a16_snorm = 26,
    r16_float = 27,
    r16g16_float = 28,
    r16g16b16a16_float = 29,
    r32_float = 30,
    r32g32_float = 31,
    r32g32b32a32_float = 32,
    r11g11b10_ufloat = 33,
    r8_uint = 34,
    r8g8_uint = 35,
    r8g8b8a8_uint = 36,
    r16_uint = 37,
    r16g16_uint = 38,
    r16g16b16a16_uint = 39,
    r32_uint = 40,
    r32g32_uint = 41,
    r32g32b32a32_uint = 42,
    r8_int = 43,
    r8g8_int = 44,
    r8g8b8a8_int = 45,
    r16_int = 46,
    r16g16_int = 47,
    r16g16b16a16_int = 48,
    r32_int = 49,
    r32g32_int = 50,
    r32g32b32a32_int = 51,
    r8g8b8a8_unorm_srgb = 52,
    b8g8r8a8_unorm_srgb = 53,
    bc1_rgba_unorm_srgb = 54,
    bc2_rgba_unorm_srgb = 55,
    bc3_rgba_unorm_srgb = 56,
    bc7_rgba_unorm_srgb = 57,
    d16_unorm = 58,
    d24_unorm = 59,
    d32_float = 60,
    d24_unorm_s8_uint = 61,
    d32_float_s8_uint = 62,
    astc_4x4_unorm = 63,
    astc_5x4_unorm = 64,
    astc_5x5_unorm = 65,
    astc_6x5_unorm = 66,
    astc_6x6_unorm = 67,
    astc_8x5_unorm = 68,
    astc_8x6_unorm = 69,
    astc_8x8_unorm = 70,
    astc_10x5_unorm = 71,
    astc_10x6_unorm = 72,
    astc_10x8_unorm = 73,
    astc_10x10_unorm = 74,
    astc_12x10_unorm = 75,
    astc_12x12_unorm = 76,
    astc_4x4_unorm_srgb = 77,
    astc_5x4_unorm_srgb = 78,
    astc_5x5_unorm_srgb = 79,
    astc_6x5_unorm_srgb = 80,
    astc_6x6_unorm_srgb = 81,
    astc_8x5_unorm_srgb = 82,
    astc_8x6_unorm_srgb = 83,
    astc_8x8_unorm_srgb = 84,
    astc_10x5_unorm_srgb = 85,
    astc_10x6_unorm_srgb = 86,
    astc_10x8_unorm_srgb = 87,
    astc_10x10_unorm_srgb = 88,
    astc_12x10_unorm_srgb = 89,
    astc_12x12_unorm_srgb = 90,
    astc_4x4_float = 91,
    astc_5x4_float = 92,
    astc_5x5_float = 93,
    astc_6x5_float = 94,
    astc_6x6_float = 95,
    astc_8x5_float = 96,
    astc_8x6_float = 97,
    astc_8x8_float = 98,
    astc_10x5_float = 99,
    astc_10x6_float = 100,
    astc_10x8_float = 101,
    astc_10x10_float = 102,
    astc_12x10_float = 103,
    astc_12x12_float = 104,
};

pub const TextureType = enum(u32) {
    type_2d = 0,
    type_2d_array = 1,
    type_3d = 2,
    type_cube = 3,
    type_cube_array = 4,
};

pub const SampleCount = enum(u32) { count_1 = 0, count_2 = 1, count_4 = 2, count_8 = 3 };

pub const CubeMapFace = enum(u32) {
    positive_x = 0,
    negative_x = 1,
    positive_y = 2,
    negative_y = 3,
    positive_z = 4,
    negative_z = 5,
};

pub const TransferBufferUsage = enum(u32) { upload = 0, download = 1 };
pub const ShaderStage = enum(u32) { vertex = 0, fragment = 1 };

pub const VertexElementFormat = enum(u32) {
    invalid = 0,
    int = 1,
    int2 = 2,
    int3 = 3,
    int4 = 4,
    uint = 5,
    uint2 = 6,
    uint3 = 7,
    uint4 = 8,
    float = 9,
    float2 = 10,
    float3 = 11,
    float4 = 12,
    byte2 = 13,
    byte4 = 14,
    ubyte2 = 15,
    ubyte4 = 16,
    byte2_norm = 17,
    byte4_norm = 18,
    ubyte2_norm = 19,
    ubyte4_norm = 20,
    short2 = 21,
    short4 = 22,
    ushort2 = 23,
    ushort4 = 24,
    short2_norm = 25,
    short4_norm = 26,
    ushort2_norm = 27,
    ushort4_norm = 28,
    half2 = 29,
    half4 = 30,
};

pub const VertexInputRate = enum(u32) { vertex = 0, instance = 1 };
pub const FillMode = enum(u32) { fill = 0, line = 1 };
pub const CullMode = enum(u32) { none = 0, front = 1, back = 2 };
pub const FrontFace = enum(u32) { counter_clockwise = 0, clockwise = 1 };

pub const CompareOp = enum(u32) {
    invalid = 0,
    never = 1,
    less = 2,
    equal = 3,
    less_or_equal = 4,
    greater = 5,
    not_equal = 6,
    greater_or_equal = 7,
    always = 8,
};

pub const StencilOp = enum(u32) {
    invalid = 0,
    keep = 1,
    zero = 2,
    replace = 3,
    increment_and_clamp = 4,
    decrement_and_clamp = 5,
    invert = 6,
    increment_and_wrap = 7,
    decrement_and_wrap = 8,
};

pub const BlendOp = enum(u32) {
    invalid = 0,
    add = 1,
    subtract = 2,
    reverse_subtract = 3,
    min = 4,
    max = 5,
};

pub const BlendFactor = enum(u32) {
    invalid = 0,
    zero = 1,
    one = 2,
    src_color = 3,
    one_minus_src_color = 4,
    dst_color = 5,
    one_minus_dst_color = 6,
    src_alpha = 7,
    one_minus_src_alpha = 8,
    dst_alpha = 9,
    one_minus_dst_alpha = 10,
    constant_color = 11,
    one_minus_constant_color = 12,
    src_alpha_saturate = 13,
};

pub const Filter = enum(u32) { nearest = 0, linear = 1 };
pub const SamplerMipmapMode = enum(u32) { nearest = 0, linear = 1 };
pub const SamplerAddressMode = enum(u32) { repeat = 0, mirrored_repeat = 1, clamp_to_edge = 2 };
pub const PresentMode = enum(u32) { vsync = 0, immediate = 1, mailbox = 2 };
pub const SwapchainComposition = enum(u32) { sdr = 0, sdr_linear = 1, hdr_extended_linear = 2, hdr10_st2084 = 3 };
pub const FlipMode = enum(u32) { none = 0, horizontal = 1, vertical = 2, both = 3 };

// ============================================================================
// Flag groups (SDL_*UsageFlags / ShaderFormat / ColorComponent)
// ============================================================================

pub const TextureUsage = struct {
    pub const sampler: u32 = 1 << 0;
    pub const color_target: u32 = 1 << 1;
    pub const depth_stencil_target: u32 = 1 << 2;
    pub const graphics_storage_read: u32 = 1 << 3;
    pub const compute_storage_read: u32 = 1 << 4;
    pub const compute_storage_write: u32 = 1 << 5;
    /// NOT equivalent to READ|WRITE: reads+writes in the same shader.
    /// Caller is responsible for avoiding data races.
    pub const compute_storage_simultaneous_read_write: u32 = 1 << 6;
};

pub const BufferUsage = struct {
    pub const vertex: u32 = 1 << 0;
    pub const index: u32 = 1 << 1;
    pub const indirect: u32 = 1 << 2;
    pub const graphics_storage_read: u32 = 1 << 3;
    pub const compute_storage_read: u32 = 1 << 4;
    pub const compute_storage_write: u32 = 1 << 5;
};

pub const ShaderFormat = struct {
    pub const none: u32 = 0;
    pub const private: u32 = 1 << 0;
    pub const spirv: u32 = 1 << 1;
    pub const dxbc: u32 = 1 << 2;
    pub const dxil: u32 = 1 << 3;
    pub const msl: u32 = 1 << 4;
    pub const metallib: u32 = 1 << 5;
};

pub const ColorComponent = struct {
    pub const r: u8 = 1 << 0;
    pub const g: u8 = 1 << 1;
    pub const b: u8 = 1 << 2;
    pub const a: u8 = 1 << 3;
    pub const all: u8 = r | g | b | a;
};

/// Shader formats each backend consumes, mirroring SDL's per-driver
/// `GetGPUShaderFormats`. ZUI shaders ship offline-compiled per backend
/// (`@embedFile` pattern from gooey); the device rejects mismatches at
/// creation instead of failing obscurely at draw.
pub fn shaderFormatsFor(kind: DeviceKind) u32 {
    return switch (kind) {
        .vulkan => ShaderFormat.spirv,
        .metal => ShaderFormat.msl | ShaderFormat.metallib,
        .d3d12 => ShaderFormat.dxbc | ShaderFormat.dxil,
        .software, .null => ShaderFormat.none,
    };
}

// ============================================================================
// Format helpers (pure; mirror SDL_GPUTextureFormatTexelBlockSize et al.)
// ============================================================================

/// Bytes per texel block. Compressed formats report the whole block:
/// BC1/BC4 = 8, BC2/BC3/BC5/BC6H/BC7/ASTC = 16.
pub fn texelBlockSize(format: TextureFormat) u32 {
    return switch (format) {
        .invalid => 0,
        .a8_unorm, .r8_unorm, .r8_snorm, .r8_uint, .r8_int => 1,
        .r8g8_unorm, .r8g8_snorm, .r8g8_uint, .r8g8_int, .r16_unorm, .r16_snorm, .r16_float, .r16_uint, .r16_int, .b5g6r5_unorm, .b5g5r5a1_unorm, .b4g4r4a4_unorm, .d16_unorm => 2,
        .r8g8b8a8_unorm, .r8g8b8a8_snorm, .r8g8b8a8_uint, .r8g8b8a8_int, .r8g8b8a8_unorm_srgb, .b8g8r8a8_unorm, .b8g8r8a8_unorm_srgb, .r16g16_unorm, .r16g16_snorm, .r16g16_float, .r16g16_uint, .r16g16_int, .r32_float, .r32_uint, .r32_int, .r10g10b10a2_unorm, .r11g11b10_ufloat, .d24_unorm, .d32_float => 4,
        .r16g16b16a16_unorm, .r16g16b16a16_snorm, .r16g16b16a16_float, .r16g16b16a16_uint, .r16g16b16a16_int, .r32g32_float, .r32g32_uint, .r32g32_int, .d24_unorm_s8_uint, .d32_float_s8_uint => 8,
        .r32g32b32a32_float, .r32g32b32a32_uint, .r32g32b32a32_int => 16,
        .bc1_rgba_unorm, .bc1_rgba_unorm_srgb, .bc4_r_unorm => 8,
        .bc2_rgba_unorm, .bc3_rgba_unorm, .bc5_rg_unorm, .bc7_rgba_unorm, .bc6h_rgb_float, .bc6h_rgb_ufloat, .bc2_rgba_unorm_srgb, .bc3_rgba_unorm_srgb, .bc7_rgba_unorm_srgb => 16,
        .astc_4x4_unorm, .astc_5x4_unorm, .astc_5x5_unorm, .astc_6x5_unorm, .astc_6x6_unorm, .astc_8x5_unorm, .astc_8x6_unorm, .astc_8x8_unorm, .astc_10x5_unorm, .astc_10x6_unorm, .astc_10x8_unorm, .astc_10x10_unorm, .astc_12x10_unorm, .astc_12x12_unorm, .astc_4x4_unorm_srgb, .astc_5x4_unorm_srgb, .astc_5x5_unorm_srgb, .astc_6x5_unorm_srgb, .astc_6x6_unorm_srgb, .astc_8x5_unorm_srgb, .astc_8x6_unorm_srgb, .astc_8x8_unorm_srgb, .astc_10x5_unorm_srgb, .astc_10x6_unorm_srgb, .astc_10x8_unorm_srgb, .astc_10x10_unorm_srgb, .astc_12x10_unorm_srgb, .astc_12x12_unorm_srgb, .astc_4x4_float, .astc_5x4_float, .astc_5x5_float, .astc_6x5_float, .astc_6x6_float, .astc_8x5_float, .astc_8x6_float, .astc_8x8_float, .astc_10x5_float, .astc_10x6_float, .astc_10x8_float, .astc_10x10_float, .astc_12x10_float, .astc_12x12_float => 16,
    };
}

pub fn isCompressedFormat(format: TextureFormat) bool {
    const v = @backingInt(format);
    return (v >= @backingInt(TextureFormat.bc1_rgba_unorm) and v <= @backingInt(TextureFormat.bc6h_rgb_ufloat)) or
        (v >= @backingInt(TextureFormat.bc1_rgba_unorm_srgb) and v <= @backingInt(TextureFormat.bc7_rgba_unorm_srgb)) or
        (v >= @backingInt(TextureFormat.astc_4x4_unorm) and v <= @backingInt(TextureFormat.astc_12x12_float));
}

pub fn isDepthFormat(format: TextureFormat) bool {
    return switch (format) {
        .d16_unorm, .d24_unorm, .d32_float, .d24_unorm_s8_uint, .d32_float_s8_uint => true,
        else => false,
    };
}

/// Block extent for a format (compressed formats transfer in blocks).
pub fn blockExtent(format: TextureFormat) struct { w: u32, h: u32 } {
    const v = @backingInt(format);
    if (v >= @backingInt(TextureFormat.bc1_rgba_unorm) and v <= @backingInt(TextureFormat.bc7_rgba_unorm_srgb)) return .{ .w = 4, .h = 4 };
    if (v >= @backingInt(TextureFormat.astc_4x4_unorm) and v <= @backingInt(TextureFormat.astc_4x4_unorm_srgb) or
        v >= @backingInt(TextureFormat.astc_4x4_float) and v <= @backingInt(TextureFormat.astc_4x4_float)) return .{ .w = 4, .h = 4 };
    if (v >= @backingInt(TextureFormat.astc_5x4_unorm) and v <= @backingInt(TextureFormat.astc_5x4_unorm_srgb) or
        v >= @backingInt(TextureFormat.astc_5x4_float) and v <= @backingInt(TextureFormat.astc_5x4_float)) return .{ .w = 5, .h = 4 };
    if (v >= @backingInt(TextureFormat.astc_5x5_unorm) and v <= @backingInt(TextureFormat.astc_5x5_unorm_srgb) or
        v >= @backingInt(TextureFormat.astc_5x5_float) and v <= @backingInt(TextureFormat.astc_5x5_float)) return .{ .w = 5, .h = 5 };
    if (v >= @backingInt(TextureFormat.astc_6x5_unorm) and v <= @backingInt(TextureFormat.astc_6x5_unorm_srgb) or
        v >= @backingInt(TextureFormat.astc_6x5_float) and v <= @backingInt(TextureFormat.astc_6x5_float)) return .{ .w = 6, .h = 5 };
    if (v >= @backingInt(TextureFormat.astc_6x6_unorm) and v <= @backingInt(TextureFormat.astc_6x6_unorm_srgb) or
        v >= @backingInt(TextureFormat.astc_6x6_float) and v <= @backingInt(TextureFormat.astc_6x6_float)) return .{ .w = 6, .h = 6 };
    if (v >= @backingInt(TextureFormat.astc_8x5_unorm) and v <= @backingInt(TextureFormat.astc_8x5_unorm_srgb) or
        v >= @backingInt(TextureFormat.astc_8x5_float) and v <= @backingInt(TextureFormat.astc_8x5_float)) return .{ .w = 8, .h = 5 };
    if (v >= @backingInt(TextureFormat.astc_8x6_unorm) and v <= @backingInt(TextureFormat.astc_8x6_unorm_srgb) or
        v >= @backingInt(TextureFormat.astc_8x6_float) and v <= @backingInt(TextureFormat.astc_8x6_float)) return .{ .w = 8, .h = 6 };
    if (v >= @backingInt(TextureFormat.astc_8x8_unorm) and v <= @backingInt(TextureFormat.astc_8x8_unorm_srgb) or
        v >= @backingInt(TextureFormat.astc_8x8_float) and v <= @backingInt(TextureFormat.astc_8x8_float)) return .{ .w = 8, .h = 8 };
    if (v >= @backingInt(TextureFormat.astc_10x5_unorm) and v <= @backingInt(TextureFormat.astc_10x5_unorm_srgb) or
        v >= @backingInt(TextureFormat.astc_10x5_float) and v <= @backingInt(TextureFormat.astc_10x5_float)) return .{ .w = 10, .h = 5 };
    if (v >= @backingInt(TextureFormat.astc_10x6_unorm) and v <= @backingInt(TextureFormat.astc_10x6_unorm_srgb) or
        v >= @backingInt(TextureFormat.astc_10x6_float) and v <= @backingInt(TextureFormat.astc_10x6_float)) return .{ .w = 10, .h = 6 };
    if (v >= @backingInt(TextureFormat.astc_10x8_unorm) and v <= @backingInt(TextureFormat.astc_10x8_unorm_srgb) or
        v >= @backingInt(TextureFormat.astc_10x8_float) and v <= @backingInt(TextureFormat.astc_10x8_float)) return .{ .w = 10, .h = 8 };
    if (v >= @backingInt(TextureFormat.astc_10x10_unorm) and v <= @backingInt(TextureFormat.astc_10x10_unorm_srgb) or
        v >= @backingInt(TextureFormat.astc_10x10_float) and v <= @backingInt(TextureFormat.astc_10x10_float)) return .{ .w = 10, .h = 10 };
    if (v >= @backingInt(TextureFormat.astc_12x10_unorm) and v <= @backingInt(TextureFormat.astc_12x10_unorm_srgb) or
        v >= @backingInt(TextureFormat.astc_12x10_float) and v <= @backingInt(TextureFormat.astc_12x10_float)) return .{ .w = 12, .h = 10 };
    if (v >= @backingInt(TextureFormat.astc_12x12_unorm) and v <= @backingInt(TextureFormat.astc_12x12_unorm_srgb) or
        v >= @backingInt(TextureFormat.astc_12x12_float) and v <= @backingInt(TextureFormat.astc_12x12_float)) return .{ .w = 12, .h = 12 };
    return .{ .w = 1, .h = 1 };
}

/// Total bytes for one mip level of w×h in `format`, blocks rounded up.
/// Mirrors `SDL_CalculateGPUTextureFormatSize`.
// TODO(gpu): SDL_GetPixelFormatFromGPUTextureFormat mapping lives here
// when GPU readback meets the software path (download → software.Target
// needs a format bridge; ZUI otherwise speaks core.Color, not SDL pixels).
pub fn textureFormatSize(format: TextureFormat, width: u32, height: u32) u32 {
    if (format == .invalid or width == 0 or height == 0) return 0;
    const ext = blockExtent(format);
    const blocks_x = (width + ext.w - 1) / ext.w;
    const blocks_y = (height + ext.h - 1) / ext.h;
    return blocks_x * blocks_y * texelBlockSize(format);
}

pub fn sampleCountValue(count: SampleCount) u32 {
    return switch (count) {
        .count_1 => 1,
        .count_2 => 2,
        .count_4 => 4,
        .count_8 => 8,
    };
}

/// Size in bytes of one vertex attribute element.
pub fn vertexElementSize(format: VertexElementFormat) u32 {
    return switch (format) {
        .invalid => 0,
        .int, .uint, .float => 4,
        .int2, .uint2, .float2 => 8,
        .int3, .uint3, .float3 => 12,
        .int4, .uint4, .float4 => 16,
        .byte2, .ubyte2, .byte2_norm, .ubyte2_norm => 2,
        .byte4, .ubyte4, .byte4_norm, .ubyte4_norm => 4,
        .short2, .ushort2, .short2_norm, .ushort2_norm, .half2 => 4,
        .short4, .ushort4, .short4_norm, .ushort4_norm, .half4 => 8,
    };
}

// ============================================================================
// Create-info + state structs
// ============================================================================

pub const Viewport = struct {
    x: f32 = 0,
    y: f32 = 0,
    w: f32 = 0,
    h: f32 = 0,
    min_depth: f32 = 0,
    max_depth: f32 = 1,
};

pub const Scissor = struct {
    x: u32 = 0,
    y: u32 = 0,
    w: u32 = 0,
    h: u32 = 0,
};

pub const TextureTransferInfo = struct {
    transfer_buffer: TransferBuffer = .null,
    offset: u32 = 0,
    /// 0 = tightly packed (region width used).
    pixels_per_row: u32 = 0,
    /// 0 = tightly packed (region height used).
    rows_per_layer: u32 = 0,
};

pub const TransferBufferLocation = struct {
    transfer_buffer: TransferBuffer = .null,
    offset: u32 = 0,
};

pub const TextureLocation = struct {
    texture: Texture = .null,
    mip_level: u32 = 0,
    layer: u32 = 0,
    x: u32 = 0,
    y: u32 = 0,
    z: u32 = 0,
};

pub const TextureRegion = struct {
    texture: Texture = .null,
    mip_level: u32 = 0,
    layer: u32 = 0,
    x: u32 = 0,
    y: u32 = 0,
    z: u32 = 0,
    w: u32 = 0,
    h: u32 = 0,
    d: u32 = 1,
};

pub const BlitRegion = struct {
    texture: Texture = .null,
    mip_level: u32 = 0,
    layer_or_depth_plane: u32 = 0,
    x: u32 = 0,
    y: u32 = 0,
    w: u32 = 0,
    h: u32 = 0,
};

pub const BufferLocation = struct {
    buffer: Buffer = .null,
    offset: u32 = 0,
};

pub const BufferRegion = struct {
    buffer: Buffer = .null,
    offset: u32 = 0,
    size: u32 = 0,
};

pub const IndirectDrawCommand = struct {
    num_vertices: u32,
    num_instances: u32 = 1,
    first_vertex: u32 = 0,
    first_instance: u32 = 0,
};

pub const IndexedIndirectDrawCommand = struct {
    num_indices: u32,
    num_instances: u32 = 1,
    first_index: u32 = 0,
    vertex_offset: i32 = 0,
    first_instance: u32 = 0,
};

pub const IndirectDispatchCommand = struct {
    groupcount_x: u32,
    groupcount_y: u32,
    groupcount_z: u32,
};

pub const SamplerCreateInfo = struct {
    min_filter: Filter = .nearest,
    mag_filter: Filter = .nearest,
    mipmap_mode: SamplerMipmapMode = .nearest,
    address_mode_u: SamplerAddressMode = .clamp_to_edge,
    address_mode_v: SamplerAddressMode = .clamp_to_edge,
    address_mode_w: SamplerAddressMode = .clamp_to_edge,
    mip_lod_bias: f32 = 0,
    max_anisotropy: f32 = 1,
    compare_op: CompareOp = .never,
    min_lod: f32 = 0,
    max_lod: f32 = 1000,
    enable_anisotropy: bool = false,
    enable_compare: bool = false,
};

pub const VertexBufferDescription = struct {
    slot: u32,
    pitch: u32,
    input_rate: VertexInputRate = .vertex,
};

pub const VertexAttribute = struct {
    location: u32,
    buffer_slot: u32,
    format: VertexElementFormat,
    offset: u32,
};

pub const VertexInputState = struct {
    buffer_descriptions: []const VertexBufferDescription = &.{},
    attributes: []const VertexAttribute = &.{},
};

pub const StencilOpState = struct {
    fail_op: StencilOp = .keep,
    pass_op: StencilOp = .keep,
    depth_fail_op: StencilOp = .keep,
    compare_op: CompareOp = .always,
};

pub const ColorTargetBlendState = struct {
    src_color_blendfactor: BlendFactor = .one,
    dst_color_blendfactor: BlendFactor = .zero,
    color_blend_op: BlendOp = .add,
    src_alpha_blendfactor: BlendFactor = .one,
    dst_alpha_blendfactor: BlendFactor = .zero,
    alpha_blend_op: BlendOp = .add,
    color_write_mask: u8 = ColorComponent.all,
    enable_blend: bool = false,
    enable_color_write_mask: bool = false,

    /// Premultiplied-alpha blend used by ZUI's 2D quad pipeline.
    pub fn premultipliedAlpha() @This() {
        return .{
            .src_color_blendfactor = .one,
            .dst_color_blendfactor = .one_minus_src_alpha,
            .src_alpha_blendfactor = .one,
            .dst_alpha_blendfactor = .one_minus_src_alpha,
            .enable_blend = true,
        };
    }
};

pub const ShaderCreateInfo = struct {
    code: []const u8,
    entrypoint: []const u8 = "main",
    format: u32,
    stage: ShaderStage,
    num_samplers: u32 = 0,
    num_storage_textures: u32 = 0,
    num_storage_buffers: u32 = 0,
    num_uniform_buffers: u32 = 0,
};

pub const TextureCreateInfo = struct {
    type: TextureType = .type_2d,
    format: TextureFormat = .r8g8b8a8_unorm,
    usage: u32 = TextureUsage.sampler,
    width: u32 = 0,
    height: u32 = 0,
    layer_count_or_depth: u32 = 1,
    num_levels: u32 = 1,
    sample_count: SampleCount = .count_1,
};

pub const BufferCreateInfo = struct {
    usage: u32,
    size: u32,
};

pub const TransferBufferCreateInfo = struct {
    usage: TransferBufferUsage = .upload,
    size: u32,
};

pub const RasterizerState = struct {
    fill_mode: FillMode = .fill,
    cull_mode: CullMode = .none,
    front_face: FrontFace = .counter_clockwise,
    depth_bias_constant_factor: f32 = 0,
    depth_bias_clamp: f32 = 0,
    depth_bias_slope_factor: f32 = 0,
    enable_depth_bias: bool = false,
    enable_depth_clip: bool = true,
};

pub const MultisampleState = struct {
    sample_count: SampleCount = .count_1,
    enable_alpha_to_coverage: bool = false,
};

pub const DepthStencilState = struct {
    compare_op: CompareOp = .less,
    back_stencil_state: StencilOpState = .{},
    front_stencil_state: StencilOpState = .{},
    compare_mask: u8 = 0xFF,
    write_mask: u8 = 0xFF,
    enable_depth_test: bool = false,
    enable_depth_write: bool = false,
    enable_stencil_test: bool = false,
};

pub const ColorTargetDescription = struct {
    format: TextureFormat,
    blend_state: ColorTargetBlendState = .{},
};

pub const GraphicsPipelineTargetInfo = struct {
    color_targets: []const ColorTargetDescription = &.{},
    depth_stencil_format: TextureFormat = .invalid,
    has_depth_stencil_target: bool = false,
};

pub const GraphicsPipelineCreateInfo = struct {
    vertex_shader: Shader = .null,
    fragment_shader: Shader = .null,
    vertex_input_state: VertexInputState = .{},
    primitive_type: PrimitiveType = .triangle_list,
    rasterizer_state: RasterizerState = .{},
    multisample_state: MultisampleState = .{},
    depth_stencil_state: DepthStencilState = .{},
    target_info: GraphicsPipelineTargetInfo = .{},
};

pub const ComputePipelineCreateInfo = struct {
    code: []const u8,
    entrypoint: []const u8 = "main",
    format: u32,
    num_samplers: u32 = 0,
    num_readonly_storage_textures: u32 = 0,
    num_readonly_storage_buffers: u32 = 0,
    num_readwrite_storage_textures: u32 = 0,
    num_readwrite_storage_buffers: u32 = 0,
    num_uniform_buffers: u32 = 0,
    threadcount_x: u32 = 1,
    threadcount_y: u32 = 1,
    threadcount_z: u32 = 1,
};

pub const ColorTargetInfo = struct {
    texture: Texture = .null,
    mip_level: u32 = 0,
    layer: u32 = 0,
    load_op: LoadOp = .clear,
    store_op: StoreOp = .store,
    clear_color: Color = .transparent,
    resolve_texture: Texture = .null,
    resolve_mip_level: u32 = 0,
    resolve_layer: u32 = 0,
    cycle: bool = false,
};

pub const DepthStencilTargetInfo = struct {
    texture: Texture = .null,
    load_op: LoadOp = .clear,
    store_op: StoreOp = .store,
    stencil_load_op: LoadOp = .clear,
    stencil_store_op: StoreOp = .store,
    clear_depth: f32 = 1,
    clear_stencil: u8 = 0,
    cycle: bool = false,
};

pub const RenderPassInfo = struct {
    color_targets: []const ColorTargetInfo,
    depth_stencil: ?DepthStencilTargetInfo = null,
};

pub const StorageTextureBinding = struct {
    texture: Texture = .null,
    mip_level: u32 = 0,
    layer: u32 = 0,
    cycle: bool = false,
};

pub const ComputePassInfo = struct {
    storage_textures: []const StorageTextureBinding = &.{},
    storage_buffers: []const Buffer = &.{},
    samplers: []const SamplerBinding = &.{},
};

pub const BufferBinding = struct {
    buffer: Buffer = .null,
    offset: u32 = 0,
};

pub const SamplerBinding = struct {
    sampler: Sampler = .null,
    texture: Texture = .null,
};

pub const DrawParams = struct {
    num_vertices: u32,
    num_instances: u32 = 1,
    first_vertex: u32 = 0,
    first_instance: u32 = 0,
};

pub const DrawIndexedParams = struct {
    num_indices: u32,
    num_instances: u32 = 1,
    first_index: u32 = 0,
    vertex_offset: i32 = 0,
    first_instance: u32 = 0,
};

pub const DispatchParams = struct {
    x: u32,
    y: u32,
    z: u32,
};

pub const BlitInfo = struct {
    source: BlitRegion,
    destination: BlitRegion,
    load_op: LoadOp = .load,
    clear_color: Color = .transparent,
    flip_mode: FlipMode = .none,
    filter: Filter = .nearest,
    cycle: bool = false,
};

pub const SwapchainParameters = struct {
    composition: SwapchainComposition = .sdr,
    present_mode: PresentMode = .vsync,
};

/// Result of acquiring the swapchain image. `texture == .null` means no
/// frame is available yet (mirrors SDL returning NULL) — skip rendering
/// and try again next frame.
// TODO(gpu): STORE_OP_RESOLVE / RESOLVE_AND_STORE paths need a real-driver
// test once Vulkan lands (multisample render → resolve texture); the
// contract carries the ops already, only driver coverage is missing.
pub const SwapchainTexture = struct {
    texture: Texture = .null,
    w: u32 = 0,
    h: u32 = 0,
};

// ============================================================================
// Passes (shared open-state validation, zero driver burden)
// ============================================================================

pub const RenderPass = struct {
    dev: Device,
    cmd: *CommandBuffer,
    open: bool,

    fn check(self: *const @This(), what: []const u8) bool {
        if (!self.open or self.cmd.dropped) {
            std.debug.assert(!self.open); // draw-after-end is a bug; assert in debug, no-op in release
            _ = what;
            return false;
        }
        return true;
    }

    pub fn bindPipeline(self: *@This(), pipeline: GraphicsPipeline) void {
        if (!self.check("bindPipeline")) return;
        self.dev.vtable.renderBindPipeline(self.dev.ptr, self.cmd, pipeline);
    }
    pub fn setViewport(self: *@This(), viewport: Viewport) void {
        if (!self.check("setViewport")) return;
        self.dev.vtable.renderSetViewport(self.dev.ptr, self.cmd, viewport);
    }
    pub fn setScissor(self: *@This(), scissor: Scissor) void {
        if (!self.check("setScissor")) return;
        self.dev.vtable.renderSetScissor(self.dev.ptr, self.cmd, scissor);
    }
    pub fn setBlendConstants(self: *@This(), r: f32, g: f32, b: f32, a: f32) void {
        if (!self.check("setBlendConstants")) return;
        self.dev.vtable.renderSetBlendConstants(self.dev.ptr, self.cmd, r, g, b, a);
    }
    pub fn setStencilReference(self: *@This(), reference: u8) void {
        if (!self.check("setStencilReference")) return;
        self.dev.vtable.renderSetStencilReference(self.dev.ptr, self.cmd, reference);
    }
    pub fn bindVertexBuffers(self: *@This(), first_slot: u32, bindings: []const BufferBinding) void {
        if (!self.check("bindVertexBuffers")) return;
        self.dev.vtable.renderBindVertexBuffers(self.dev.ptr, self.cmd, first_slot, bindings);
    }
    pub fn bindIndexBuffer(self: *@This(), binding: BufferBinding, element_size: IndexElementSize) void {
        if (!self.check("bindIndexBuffer")) return;
        self.dev.vtable.renderBindIndexBuffer(self.dev.ptr, self.cmd, binding, element_size);
    }
    pub fn bindVertexSamplers(self: *@This(), first_slot: u32, bindings: []const SamplerBinding) void {
        if (!self.check("bindVertexSamplers")) return;
        self.dev.vtable.renderBindVertexSamplers(self.dev.ptr, self.cmd, first_slot, bindings);
    }
    pub fn bindVertexStorageTextures(self: *@This(), first_slot: u32, textures: []const Texture) void {
        if (!self.check("bindVertexStorageTextures")) return;
        self.dev.vtable.renderBindVertexStorageTextures(self.dev.ptr, self.cmd, first_slot, textures);
    }
    pub fn bindVertexStorageBuffers(self: *@This(), first_slot: u32, buffers: []const Buffer) void {
        if (!self.check("bindVertexStorageBuffers")) return;
        self.dev.vtable.renderBindVertexStorageBuffers(self.dev.ptr, self.cmd, first_slot, buffers);
    }
    pub fn bindFragmentSamplers(self: *@This(), first_slot: u32, bindings: []const SamplerBinding) void {
        if (!self.check("bindFragmentSamplers")) return;
        self.dev.vtable.renderBindFragmentSamplers(self.dev.ptr, self.cmd, first_slot, bindings);
    }
    pub fn bindFragmentStorageTextures(self: *@This(), first_slot: u32, textures: []const Texture) void {
        if (!self.check("bindFragmentStorageTextures")) return;
        self.dev.vtable.renderBindFragmentStorageTextures(self.dev.ptr, self.cmd, first_slot, textures);
    }
    pub fn bindFragmentStorageBuffers(self: *@This(), first_slot: u32, buffers: []const Buffer) void {
        if (!self.check("bindFragmentStorageBuffers")) return;
        self.dev.vtable.renderBindFragmentStorageBuffers(self.dev.ptr, self.cmd, first_slot, buffers);
    }
    pub fn drawPrimitives(self: *@This(), params: DrawParams) void {
        if (!self.check("drawPrimitives")) return;
        self.dev.vtable.renderDraw(self.dev.ptr, self.cmd, params);
    }
    pub fn drawIndexedPrimitives(self: *@This(), params: DrawIndexedParams) void {
        if (!self.check("drawIndexedPrimitives")) return;
        self.dev.vtable.renderDrawIndexed(self.dev.ptr, self.cmd, params);
    }
    pub fn drawPrimitivesIndirect(self: *@This(), buffer: Buffer, offset: u32, draw_count: u32) void {
        if (!self.check("drawPrimitivesIndirect")) return;
        self.dev.vtable.renderDrawIndirect(self.dev.ptr, self.cmd, buffer, offset, draw_count);
    }
    pub fn drawIndexedPrimitivesIndirect(self: *@This(), buffer: Buffer, offset: u32, draw_count: u32) void {
        if (!self.check("drawIndexedPrimitivesIndirect")) return;
        self.dev.vtable.renderDrawIndexedIndirect(self.dev.ptr, self.cmd, buffer, offset, draw_count);
    }
    pub fn end(self: *@This()) void {
        if (!self.open) return;
        self.open = false;
        if (self.cmd.dropped) return;
        self.dev.vtable.renderPassEnd(self.dev.ptr, self.cmd);
    }
};

pub const ComputePass = struct {
    dev: Device,
    cmd: *CommandBuffer,
    open: bool,

    fn check(self: *const @This()) bool {
        if (!self.open or self.cmd.dropped) {
            std.debug.assert(!self.open);
            return false;
        }
        return true;
    }

    pub fn bindPipeline(self: *@This(), pipeline: ComputePipeline) void {
        if (!self.check()) return;
        self.dev.vtable.computeBindPipeline(self.dev.ptr, self.cmd, pipeline);
    }
    pub fn bindSamplers(self: *@This(), first_slot: u32, bindings: []const SamplerBinding) void {
        if (!self.check()) return;
        self.dev.vtable.computeBindSamplers(self.dev.ptr, self.cmd, first_slot, bindings);
    }
    pub fn bindStorageTextures(self: *@This(), first_slot: u32, bindings: []const StorageTextureBinding) void {
        if (!self.check()) return;
        self.dev.vtable.computeBindStorageTextures(self.dev.ptr, self.cmd, first_slot, bindings);
    }
    pub fn bindStorageBuffers(self: *@This(), first_slot: u32, buffers: []const Buffer) void {
        if (!self.check()) return;
        self.dev.vtable.computeBindStorageBuffers(self.dev.ptr, self.cmd, first_slot, buffers);
    }
    pub fn dispatch(self: *@This(), params: DispatchParams) void {
        if (!self.check()) return;
        self.dev.vtable.computeDispatch(self.dev.ptr, self.cmd, params);
    }
    pub fn dispatchIndirect(self: *@This(), buffer: Buffer, offset: u32) void {
        if (!self.check()) return;
        self.dev.vtable.computeDispatchIndirect(self.dev.ptr, self.cmd, buffer, offset);
    }
    pub fn end(self: *@This()) void {
        if (!self.open) return;
        self.open = false;
        if (self.cmd.dropped) return;
        self.dev.vtable.computePassEnd(self.dev.ptr, self.cmd);
    }
};

pub const CopyPass = struct {
    dev: Device,
    cmd: *CommandBuffer,
    open: bool,

    fn check(self: *const @This()) bool {
        if (!self.open or self.cmd.dropped) {
            std.debug.assert(!self.open);
            return false;
        }
        return true;
    }

    pub fn uploadToTexture(self: *@This(), source: TextureTransferInfo, region: TextureRegion, cycle: bool) void {
        if (!self.check()) return;
        self.dev.vtable.copyUploadToTexture(self.dev.ptr, self.cmd, source, region, cycle);
    }
    pub fn uploadToBuffer(self: *@This(), source: TransferBufferLocation, dest: BufferRegion, cycle: bool) void {
        if (!self.check()) return;
        self.dev.vtable.copyUploadToBuffer(self.dev.ptr, self.cmd, source, dest, cycle);
    }
    pub fn copyTextureToTexture(self: *@This(), source: TextureLocation, dest: TextureLocation, w: u32, h: u32, d: u32, cycle: bool) void {
        if (!self.check()) return;
        self.dev.vtable.copyTextureToTexture(self.dev.ptr, self.cmd, source, dest, w, h, d, cycle);
    }
    pub fn copyBufferToBuffer(self: *@This(), source: BufferLocation, dest: BufferLocation, size: u32, cycle: bool) void {
        if (!self.check()) return;
        self.dev.vtable.copyBufferToBuffer(self.dev.ptr, self.cmd, source, dest, size, cycle);
    }
    pub fn downloadFromTexture(self: *@This(), region: TextureRegion, dest: TextureTransferInfo) void {
        if (!self.check()) return;
        self.dev.vtable.copyDownloadFromTexture(self.dev.ptr, self.cmd, region, dest);
    }
    pub fn downloadFromBuffer(self: *@This(), source: BufferRegion, dest: TransferBufferLocation) void {
        if (!self.check()) return;
        self.dev.vtable.copyDownloadFromBuffer(self.dev.ptr, self.cmd, source, dest);
    }
    pub fn end(self: *@This()) void {
        if (!self.open) return;
        self.open = false;
        if (self.cmd.dropped) return;
        self.dev.vtable.copyPassEnd(self.dev.ptr, self.cmd);
    }
};

// ============================================================================
// VTable — one function per SDL_gpu entry point, Zig-ified
// ============================================================================

pub const VTable = struct {
    kind: *const fn (*anyopaque) DeviceKind,
    driverName: *const fn (*anyopaque) []const u8,
    shaderFormats: *const fn (*anyopaque) u32,

    // Window / swapchain (SDL_ClaimWindowForGPUDevice et al.)
    claimWindow: *const fn (*anyopaque, SurfaceHandle) bool,
    releaseWindow: *const fn (*anyopaque, SurfaceHandle) void,
    setSwapchainParameters: *const fn (*anyopaque, SurfaceHandle, SwapchainParameters) bool,
    setAllowedFramesInFlight: *const fn (*anyopaque, u32) bool,
    swapchainTextureFormat: *const fn (*anyopaque, SurfaceHandle) TextureFormat,
    supportsPresentMode: *const fn (*anyopaque, SurfaceHandle, PresentMode) bool,
    supportsSwapchainComposition: *const fn (*anyopaque, SurfaceHandle, SwapchainComposition) bool,

    // Resources (SDL_Create*/SDL_Release*)
    createBuffer: *const fn (*anyopaque, BufferCreateInfo) CreateError!Buffer,
    createTransferBuffer: *const fn (*anyopaque, TransferBufferCreateInfo) CreateError!TransferBuffer,
    createTexture: *const fn (*anyopaque, TextureCreateInfo) CreateError!Texture,
    createSampler: *const fn (*anyopaque, SamplerCreateInfo) CreateError!Sampler,
    createShader: *const fn (*anyopaque, ShaderCreateInfo) CreateError!Shader,
    createComputePipeline: *const fn (*anyopaque, ComputePipelineCreateInfo) CreateError!ComputePipeline,
    createGraphicsPipeline: *const fn (*anyopaque, GraphicsPipelineCreateInfo) CreateError!GraphicsPipeline,
    setBufferName: *const fn (*anyopaque, Buffer, []const u8) void,
    setTextureName: *const fn (*anyopaque, Texture, []const u8) void,
    insertDebugLabel: *const fn (*anyopaque, *CommandBuffer, []const u8) void,
    pushDebugGroup: *const fn (*anyopaque, *CommandBuffer, []const u8) void,
    popDebugGroup: *const fn (*anyopaque, *CommandBuffer) void,
    releaseTexture: *const fn (*anyopaque, Texture) void,
    releaseSampler: *const fn (*anyopaque, Sampler) void,
    releaseBuffer: *const fn (*anyopaque, Buffer) void,
    releaseTransferBuffer: *const fn (*anyopaque, TransferBuffer) void,
    releaseShader: *const fn (*anyopaque, Shader) void,
    releaseComputePipeline: *const fn (*anyopaque, ComputePipeline) void,
    releaseGraphicsPipeline: *const fn (*anyopaque, GraphicsPipeline) void,

    // Command buffers + submission
    acquireCommandBuffer: *const fn (*anyopaque) CommandBuffer,
    pushVertexUniformData: *const fn (*anyopaque, *CommandBuffer, u32, []const u8) void,
    pushFragmentUniformData: *const fn (*anyopaque, *CommandBuffer, u32, []const u8) void,
    pushComputeUniformData: *const fn (*anyopaque, *CommandBuffer, u32, []const u8) void,
    acquireSwapchainTexture: *const fn (*anyopaque, *CommandBuffer, SurfaceHandle) SwapchainTexture,
    waitAndAcquireSwapchainTexture: *const fn (*anyopaque, *CommandBuffer, SurfaceHandle) SwapchainTexture,
    submit: *const fn (*anyopaque, *CommandBuffer) bool,
    submitAndAcquireFence: *const fn (*anyopaque, *CommandBuffer) SubmitError!Fence,
    cancel: *const fn (*anyopaque, *CommandBuffer) void,
    waitForIdle: *const fn (*anyopaque) void,
    waitForFences: *const fn (*anyopaque, []const Fence, bool) bool,
    queryFence: *const fn (*anyopaque, Fence) bool,
    releaseFence: *const fn (*anyopaque, Fence) void,

    // Render pass
    renderPassBegin: *const fn (*anyopaque, *CommandBuffer, RenderPassInfo) RenderPass,
    renderBindPipeline: *const fn (*anyopaque, *CommandBuffer, GraphicsPipeline) void,
    renderSetViewport: *const fn (*anyopaque, *CommandBuffer, Viewport) void,
    renderSetScissor: *const fn (*anyopaque, *CommandBuffer, Scissor) void,
    renderSetBlendConstants: *const fn (*anyopaque, *CommandBuffer, f32, f32, f32, f32) void,
    renderSetStencilReference: *const fn (*anyopaque, *CommandBuffer, u8) void,
    renderBindVertexBuffers: *const fn (*anyopaque, *CommandBuffer, u32, []const BufferBinding) void,
    renderBindIndexBuffer: *const fn (*anyopaque, *CommandBuffer, BufferBinding, IndexElementSize) void,
    renderBindVertexSamplers: *const fn (*anyopaque, *CommandBuffer, u32, []const SamplerBinding) void,
    renderBindVertexStorageTextures: *const fn (*anyopaque, *CommandBuffer, u32, []const Texture) void,
    renderBindVertexStorageBuffers: *const fn (*anyopaque, *CommandBuffer, u32, []const Buffer) void,
    renderBindFragmentSamplers: *const fn (*anyopaque, *CommandBuffer, u32, []const SamplerBinding) void,
    renderBindFragmentStorageTextures: *const fn (*anyopaque, *CommandBuffer, u32, []const Texture) void,
    renderBindFragmentStorageBuffers: *const fn (*anyopaque, *CommandBuffer, u32, []const Buffer) void,
    renderDraw: *const fn (*anyopaque, *CommandBuffer, DrawParams) void,
    renderDrawIndexed: *const fn (*anyopaque, *CommandBuffer, DrawIndexedParams) void,
    renderDrawIndirect: *const fn (*anyopaque, *CommandBuffer, Buffer, u32, u32) void,
    renderDrawIndexedIndirect: *const fn (*anyopaque, *CommandBuffer, Buffer, u32, u32) void,
    renderPassEnd: *const fn (*anyopaque, *CommandBuffer) void,

    // Compute pass
    computePassBegin: *const fn (*anyopaque, *CommandBuffer, ComputePassInfo) ComputePass,
    computeBindPipeline: *const fn (*anyopaque, *CommandBuffer, ComputePipeline) void,
    computeBindSamplers: *const fn (*anyopaque, *CommandBuffer, u32, []const SamplerBinding) void,
    computeBindStorageTextures: *const fn (*anyopaque, *CommandBuffer, u32, []const StorageTextureBinding) void,
    computeBindStorageBuffers: *const fn (*anyopaque, *CommandBuffer, u32, []const Buffer) void,
    computeDispatch: *const fn (*anyopaque, *CommandBuffer, DispatchParams) void,
    computeDispatchIndirect: *const fn (*anyopaque, *CommandBuffer, Buffer, u32) void,
    computePassEnd: *const fn (*anyopaque, *CommandBuffer) void,

    // Copy pass + transfer mapping
    copyPassBegin: *const fn (*anyopaque, *CommandBuffer) CopyPass,
    copyUploadToTexture: *const fn (*anyopaque, *CommandBuffer, TextureTransferInfo, TextureRegion, bool) void,
    copyUploadToBuffer: *const fn (*anyopaque, *CommandBuffer, TransferBufferLocation, BufferRegion, bool) void,
    copyTextureToTexture: *const fn (*anyopaque, *CommandBuffer, TextureLocation, TextureLocation, u32, u32, u32, bool) void,
    copyBufferToBuffer: *const fn (*anyopaque, *CommandBuffer, BufferLocation, BufferLocation, u32, bool) void,
    copyDownloadFromTexture: *const fn (*anyopaque, *CommandBuffer, TextureRegion, TextureTransferInfo) void,
    copyDownloadFromBuffer: *const fn (*anyopaque, *CommandBuffer, BufferRegion, TransferBufferLocation) void,
    copyPassEnd: *const fn (*anyopaque, *CommandBuffer) void,
    generateMipmaps: *const fn (*anyopaque, *CommandBuffer, Texture) void,
    blitTexture: *const fn (*anyopaque, *CommandBuffer, BlitInfo) void,
    mapTransferBuffer: *const fn (*anyopaque, TransferBuffer, bool) MapError![]u8,
    unmapTransferBuffer: *const fn (*anyopaque, TransferBuffer) void,

    // Format capabilities (per-driver; pure helpers above are driver-free)
    supportsTextureFormat: *const fn (*anyopaque, TextureFormat, TextureType, TextureUsageFlags) bool,
    supportsSampleCount: *const fn (*anyopaque, TextureFormat, SampleCount) bool,

    // ZUI 2D fast path (Scene without hand-rolled passes)
    claim: *const fn (*anyopaque, SurfaceHandle) void,
    acquire: *const fn (*anyopaque) CommandBuffer,
    drawScene: *const fn (*anyopaque, *CommandBuffer, *const Scene, []const u8) bool,
    submitScene: *const fn (*anyopaque, *CommandBuffer) void,
};

pub const TextureUsageFlags = u32;
pub const BufferUsageFlags = u32;
pub const ShaderFormatFlags = u32;

// TODO(gpu): SDL_PropertiesID extension bags are omitted on purpose — a
// typeless map hides requirements. If a driver ever needs an extension,
// add it as an explicit struct field here instead.

// ============================================================================
// Device wrapper
// ============================================================================

pub const Device = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub fn kind(self: @This()) DeviceKind {
        return self.vtable.kind(self.ptr);
    }
    pub fn driverName(self: @This()) []const u8 {
        return self.vtable.driverName(self.ptr);
    }
    pub fn shaderFormats(self: @This()) u32 {
        return self.vtable.shaderFormats(self.ptr);
    }

    pub fn claimWindow(self: @This(), surface: SurfaceHandle) bool {
        return self.vtable.claimWindow(self.ptr, surface);
    }
    pub fn releaseWindow(self: @This(), surface: SurfaceHandle) void {
        self.vtable.releaseWindow(self.ptr, surface);
    }
    pub fn setSwapchainParameters(self: @This(), surface: SurfaceHandle, params: SwapchainParameters) bool {
        return self.vtable.setSwapchainParameters(self.ptr, surface, params);
    }
    pub fn setAllowedFramesInFlight(self: @This(), n: u32) bool {
        return self.vtable.setAllowedFramesInFlight(self.ptr, n);
    }
    pub fn swapchainTextureFormat(self: @This(), surface: SurfaceHandle) TextureFormat {
        return self.vtable.swapchainTextureFormat(self.ptr, surface);
    }
    pub fn supportsPresentMode(self: @This(), surface: SurfaceHandle, mode: PresentMode) bool {
        return self.vtable.supportsPresentMode(self.ptr, surface, mode);
    }
    pub fn supportsSwapchainComposition(self: @This(), surface: SurfaceHandle, comp: SwapchainComposition) bool {
        return self.vtable.supportsSwapchainComposition(self.ptr, surface, comp);
    }

    pub fn createBuffer(self: @This(), info: BufferCreateInfo) CreateError!Buffer {
        return self.vtable.createBuffer(self.ptr, info);
    }
    pub fn createTransferBuffer(self: @This(), info: TransferBufferCreateInfo) CreateError!TransferBuffer {
        return self.vtable.createTransferBuffer(self.ptr, info);
    }
    pub fn createTexture(self: @This(), info: TextureCreateInfo) CreateError!Texture {
        return self.vtable.createTexture(self.ptr, info);
    }
    pub fn createSampler(self: @This(), info: SamplerCreateInfo) CreateError!Sampler {
        return self.vtable.createSampler(self.ptr, info);
    }
    pub fn createShader(self: @This(), info: ShaderCreateInfo) CreateError!Shader {
        return self.vtable.createShader(self.ptr, info);
    }
    pub fn createComputePipeline(self: @This(), info: ComputePipelineCreateInfo) CreateError!ComputePipeline {
        return self.vtable.createComputePipeline(self.ptr, info);
    }
    pub fn createGraphicsPipeline(self: @This(), info: GraphicsPipelineCreateInfo) CreateError!GraphicsPipeline {
        return self.vtable.createGraphicsPipeline(self.ptr, info);
    }
    pub fn releaseTexture(self: @This(), t: Texture) void {
        self.vtable.releaseTexture(self.ptr, t);
    }
    pub fn releaseSampler(self: @This(), s: Sampler) void {
        self.vtable.releaseSampler(self.ptr, s);
    }
    pub fn releaseBuffer(self: @This(), b: Buffer) void {
        self.vtable.releaseBuffer(self.ptr, b);
    }
    pub fn releaseTransferBuffer(self: @This(), t: TransferBuffer) void {
        self.vtable.releaseTransferBuffer(self.ptr, t);
    }
    pub fn releaseShader(self: @This(), s: Shader) void {
        self.vtable.releaseShader(self.ptr, s);
    }
    pub fn releaseComputePipeline(self: @This(), p: ComputePipeline) void {
        self.vtable.releaseComputePipeline(self.ptr, p);
    }
    pub fn releaseGraphicsPipeline(self: @This(), p: GraphicsPipeline) void {
        self.vtable.releaseGraphicsPipeline(self.ptr, p);
    }

    pub fn acquireCommandBuffer(self: @This()) CommandBuffer {
        return self.vtable.acquireCommandBuffer(self.ptr);
    }
    pub fn pushVertexUniformData(self: @This(), cmd: *CommandBuffer, slot: u32, data: []const u8) void {
        self.vtable.pushVertexUniformData(self.ptr, cmd, slot, data);
    }
    pub fn pushFragmentUniformData(self: @This(), cmd: *CommandBuffer, slot: u32, data: []const u8) void {
        self.vtable.pushFragmentUniformData(self.ptr, cmd, slot, data);
    }
    pub fn pushComputeUniformData(self: @This(), cmd: *CommandBuffer, slot: u32, data: []const u8) void {
        self.vtable.pushComputeUniformData(self.ptr, cmd, slot, data);
    }
    pub fn acquireSwapchainTexture(self: @This(), cmd: *CommandBuffer, surface: SurfaceHandle) SwapchainTexture {
        return self.vtable.acquireSwapchainTexture(self.ptr, cmd, surface);
    }
    pub fn waitAndAcquireSwapchainTexture(self: @This(), cmd: *CommandBuffer, surface: SurfaceHandle) SwapchainTexture {
        return self.vtable.waitAndAcquireSwapchainTexture(self.ptr, cmd, surface);
    }
    pub fn submitCommandBuffer(self: @This(), cmd: *CommandBuffer) bool {
        return self.vtable.submit(self.ptr, cmd);
    }
    pub fn submitAndAcquireFence(self: @This(), cmd: *CommandBuffer) SubmitError!Fence {
        return self.vtable.submitAndAcquireFence(self.ptr, cmd);
    }
    pub fn cancelCommandBuffer(self: @This(), cmd: *CommandBuffer) void {
        self.vtable.cancel(self.ptr, cmd);
    }
    pub fn waitForIdle(self: @This()) void {
        self.vtable.waitForIdle(self.ptr);
    }
    pub fn waitForFences(self: @This(), fences: []const Fence, wait_all: bool) bool {
        return self.vtable.waitForFences(self.ptr, fences, wait_all);
    }
    pub fn queryFence(self: @This(), fence: Fence) bool {
        return self.vtable.queryFence(self.ptr, fence);
    }
    pub fn releaseFence(self: @This(), fence: Fence) void {
        self.vtable.releaseFence(self.ptr, fence);
    }

    pub fn beginRenderPass(self: @This(), cmd: *CommandBuffer, info: RenderPassInfo) RenderPass {
        var pass = self.vtable.renderPassBegin(self.ptr, cmd, info);
        pass.dev = self;
        return pass;
    }
    pub fn beginComputePass(self: @This(), cmd: *CommandBuffer, info: ComputePassInfo) ComputePass {
        var pass = self.vtable.computePassBegin(self.ptr, cmd, info);
        pass.dev = self;
        return pass;
    }
    pub fn beginCopyPass(self: @This(), cmd: *CommandBuffer) CopyPass {
        var pass = self.vtable.copyPassBegin(self.ptr, cmd);
        pass.dev = self;
        return pass;
    }
    pub fn generateMipmaps(self: @This(), cmd: *CommandBuffer, texture: Texture) void {
        self.vtable.generateMipmaps(self.ptr, cmd, texture);
    }
    pub fn blitTexture(self: @This(), cmd: *CommandBuffer, info: BlitInfo) void {
        self.vtable.blitTexture(self.ptr, cmd, info);
    }
    pub fn mapTransferBuffer(self: @This(), buffer: TransferBuffer, cycle: bool) MapError![]u8 {
        return self.vtable.mapTransferBuffer(self.ptr, buffer, cycle);
    }
    pub fn unmapTransferBuffer(self: @This(), buffer: TransferBuffer) void {
        self.vtable.unmapTransferBuffer(self.ptr, buffer);
    }
    pub fn supportsTextureFormat(self: @This(), format: TextureFormat, @"type": TextureType, usage: u32) bool {
        return self.vtable.supportsTextureFormat(self.ptr, format, @"type", usage);
    }
    pub fn supportsSampleCount(self: @This(), format: TextureFormat, count: SampleCount) bool {
        return self.vtable.supportsSampleCount(self.ptr, format, count);
    }

    // ZUI 2D fast path
    pub fn claim(self: @This(), surface: SurfaceHandle) void {
        self.vtable.claim(self.ptr, surface);
    }
    pub fn acquire(self: @This()) CommandBuffer {
        return self.vtable.acquire(self.ptr);
    }
    pub fn drawScene(self: @This(), cmd: *CommandBuffer, scene: *const Scene, glyph_pixels: []const u8) bool {
        return self.vtable.drawScene(self.ptr, cmd, scene, glyph_pixels);
    }
    pub fn submit(self: @This(), cmd: *CommandBuffer) void {
        self.vtable.submitScene(self.ptr, cmd);
    }

    /// Convenience: acquire → draw → submit. Returns what `drawScene` did.
    pub fn render(self: @This(), scene: *const Scene, glyph_pixels: []const u8) bool {
        var cmd = self.acquire();
        const ok = self.drawScene(&cmd, scene, glyph_pixels);
        if (!cmd.dropped) self.submit(&cmd);
        return ok;
    }
};

// ============================================================================
// Tracker — shared handle-pool + frame counting for stub drivers
// ============================================================================

fn Pool(comptime cap: u32) type {
    return struct {
        const WORDS: usize = (cap + 31) / 32;
        used: [WORDS]u32 = std.mem.zeroes([WORDS]u32),
        live: u32 = 0,
        next: u32 = 1,

        pub fn alloc(self: *@This()) CreateError!u32 {
            if (self.live >= cap) return error.OutOfHandles;
            var i: u32 = 0;
            while (i < cap) : (i += 1) {
                const id = (self.next - 1 + i) % cap + 1;
                const w = (id - 1) / 32;
                const b: u5 = @intCast((id - 1) % 32);
                const mask = @as(u32, 1) << b;
                if (self.used[w] & mask == 0) {
                    self.used[w] |= mask;
                    self.live += 1;
                    self.next = id % cap + 1;
                    return id;
                }
            }
            return error.OutOfHandles;
        }

        /// False for null ids, out-of-range ids, and double frees.
        pub fn free(self: *@This(), id: u32) bool {
            if (id == 0 or id > cap) return false;
            const w = (id - 1) / 32;
            const b: u5 = @intCast((id - 1) % 32);
            const mask = @as(u32, 1) << b;
            if (self.used[w] & mask == 0) return false;
            self.used[w] &= ~mask;
            self.live -= 1;
            return true;
        }

        pub fn isLive(self: *const @This(), id: u32) bool {
            if (id == 0 or id > cap) return false;
            const w = (id - 1) / 32;
            const b: u5 = @intCast((id - 1) % 32);
            return self.used[w] & (@as(u32, 1) << b) != 0;
        }
    };
}

/// Per-driver resource + frame counters. Stub drivers (Vulkan/Metal/D3D12
/// until their real init lands) embed exactly this and share `stub_vtable`:
/// creation enforces `limits.zig` caps, everything else counts calls.
pub const Tracker = struct {
    kind: DeviceKind = .null,
    frames: u64 = 0,
    draws: u64 = 0,
    submits: u64 = 0,
    claims: u32 = 0,
    fences_signalled: u64 = 0,
    buffers: Pool(limits.MAX_GPU_BUFFERS) = .{},
    transfer_buffers: Pool(limits.MAX_GPU_TRANSFER_BUFFERS) = .{},
    textures: Pool(limits.MAX_GPU_TEXTURES) = .{},
    samplers: Pool(limits.MAX_GPU_SAMPLERS) = .{},
    shaders: Pool(limits.MAX_GPU_SHADERS) = .{},
    compute_pipelines: Pool(limits.MAX_GPU_COMPUTE_PIPELINES) = .{},
    graphics_pipelines: Pool(limits.MAX_GPU_GRAPHICS_PIPELINES) = .{},
    fences: Pool(limits.MAX_GPU_FENCES) = .{},
};

fn trackerOf(ptr: *anyopaque) *Tracker {
    return @ptrCast(@alignCast(ptr));
}

fn validateCreate(info_usage_nonzero: bool, size_nonzero: bool) CreateError!void {
    if (!info_usage_nonzero) return error.InvalidUsage;
    if (!size_nonzero) return error.InvalidUsage;
}

/// Shared stub vtable for drivers without real init yet. Every entry is
/// validation + counting; `drawScene` reports success so callers keep the
/// acquire → draw → submit shape.
pub const stub_vtable: VTable = .{
    .kind = struct {
        fn f(ptr: *anyopaque) DeviceKind {
            return trackerOf(ptr).kind;
        }
    }.f,
    .driverName = struct {
        fn f(ptr: *anyopaque) []const u8 {
            return trackerOf(ptr).kind.name();
        }
    }.f,
    .shaderFormats = struct {
        fn f(ptr: *anyopaque) u32 {
            return shaderFormatsFor(trackerOf(ptr).kind);
        }
    }.f,
    .claimWindow = struct {
        fn f(ptr: *anyopaque, s: SurfaceHandle) bool {
            _ = s;
            trackerOf(ptr).claims += 1;
            return true;
        }
    }.f,
    .releaseWindow = struct {
        fn f(ptr: *anyopaque, s: SurfaceHandle) void {
            _ = s;
            _ = ptr;
        }
    }.f,
    .setSwapchainParameters = struct {
        fn f(ptr: *anyopaque, s: SurfaceHandle, p: SwapchainParameters) bool {
            _ = s;
            _ = p;
            _ = ptr;
            return true;
        }
    }.f,
    .setAllowedFramesInFlight = struct {
        fn f(ptr: *anyopaque, n: u32) bool {
            _ = ptr;
            return n >= 1 and n <= limits.MAX_GPU_FRAMES_IN_FLIGHT;
        }
    }.f,
    .swapchainTextureFormat = struct {
        fn f(ptr: *anyopaque, s: SurfaceHandle) TextureFormat {
            _ = s;
            _ = ptr;
            return .b8g8r8a8_unorm;
        }
    }.f,
    .supportsPresentMode = struct {
        fn f(ptr: *anyopaque, s: SurfaceHandle, m: PresentMode) bool {
            _ = s;
            _ = ptr;
            return m == .vsync;
        }
    }.f,
    .supportsSwapchainComposition = struct {
        fn f(ptr: *anyopaque, s: SurfaceHandle, c: SwapchainComposition) bool {
            _ = s;
            _ = ptr;
            return c == .sdr;
        }
    }.f,
    .createBuffer = struct {
        fn f(ptr: *anyopaque, info: BufferCreateInfo) CreateError!Buffer {
            try validateCreate(info.usage != 0, info.size != 0);
            return @fromBackingInt(@intCast(try trackerOf(ptr).buffers.alloc()));
        }
    }.f,
    .createTransferBuffer = struct {
        fn f(ptr: *anyopaque, info: TransferBufferCreateInfo) CreateError!TransferBuffer {
            try validateCreate(true, info.size != 0);
            return @fromBackingInt(@intCast(try trackerOf(ptr).transfer_buffers.alloc()));
        }
    }.f,
    .createTexture = struct {
        fn f(ptr: *anyopaque, info: TextureCreateInfo) CreateError!Texture {
            try validateCreate(info.usage != 0, info.width != 0 and info.height != 0);
            if (info.format == .invalid) return error.UnsupportedFormat;
            return @fromBackingInt(@intCast(try trackerOf(ptr).textures.alloc()));
        }
    }.f,
    .createSampler = struct {
        fn f(ptr: *anyopaque, info: SamplerCreateInfo) CreateError!Sampler {
            _ = info;
            return @fromBackingInt(@intCast(try trackerOf(ptr).samplers.alloc()));
        }
    }.f,
    .createShader = struct {
        fn f(ptr: *anyopaque, info: ShaderCreateInfo) CreateError!Shader {
            const t = trackerOf(ptr);
            if (info.code.len == 0 or info.entrypoint.len == 0) return error.InvalidUsage;
            if (info.format & shaderFormatsFor(t.kind) == 0) return error.UnsupportedFormat;
            return @fromBackingInt(@intCast(try t.shaders.alloc()));
        }
    }.f,
    .createComputePipeline = struct {
        fn f(ptr: *anyopaque, info: ComputePipelineCreateInfo) CreateError!ComputePipeline {
            const t = trackerOf(ptr);
            if (info.code.len == 0) return error.InvalidUsage;
            if (info.format & shaderFormatsFor(t.kind) == 0) return error.UnsupportedFormat;
            return @fromBackingInt(@intCast(try t.compute_pipelines.alloc()));
        }
    }.f,
    .createGraphicsPipeline = struct {
        fn f(ptr: *anyopaque, info: GraphicsPipelineCreateInfo) CreateError!GraphicsPipeline {
            const t = trackerOf(ptr);
            if (info.vertex_shader == .null or info.fragment_shader == .null) return error.InvalidUsage;
            if (info.target_info.color_targets.len == 0) return error.InvalidUsage;
            if (info.target_info.color_targets.len > limits.MAX_GPU_COLOR_TARGETS) return error.InvalidUsage;
            if (!t.shaders.isLive(@backingInt(info.vertex_shader))) return error.InvalidUsage;
            if (!t.shaders.isLive(@backingInt(info.fragment_shader))) return error.InvalidUsage;
            return @fromBackingInt(@intCast(try t.graphics_pipelines.alloc()));
        }
    }.f,
    .setBufferName = struct {
        fn f(ptr: *anyopaque, b: Buffer, n: []const u8) void {
            _ = b;
            _ = n;
            _ = ptr;
        }
    }.f,
    .setTextureName = struct {
        fn f(ptr: *anyopaque, t: Texture, n: []const u8) void {
            _ = t;
            _ = n;
            _ = ptr;
        }
    }.f,
    .insertDebugLabel = struct {
        fn f(ptr: *anyopaque, c: *CommandBuffer, l: []const u8) void {
            _ = c;
            _ = l;
            _ = ptr;
        }
    }.f,
    .pushDebugGroup = struct {
        fn f(ptr: *anyopaque, c: *CommandBuffer, l: []const u8) void {
            _ = c;
            _ = l;
            _ = ptr;
        }
    }.f,
    .popDebugGroup = struct {
        fn f(ptr: *anyopaque, c: *CommandBuffer) void {
            _ = c;
            _ = ptr;
        }
    }.f,
    .releaseTexture = struct {
        fn f(ptr: *anyopaque, t: Texture) void {
            _ = trackerOf(ptr).textures.free(@backingInt(t));
        }
    }.f,
    .releaseSampler = struct {
        fn f(ptr: *anyopaque, s: Sampler) void {
            _ = trackerOf(ptr).samplers.free(@backingInt(s));
        }
    }.f,
    .releaseBuffer = struct {
        fn f(ptr: *anyopaque, b: Buffer) void {
            _ = trackerOf(ptr).buffers.free(@backingInt(b));
        }
    }.f,
    .releaseTransferBuffer = struct {
        fn f(ptr: *anyopaque, t: TransferBuffer) void {
            _ = trackerOf(ptr).transfer_buffers.free(@backingInt(t));
        }
    }.f,
    .releaseShader = struct {
        fn f(ptr: *anyopaque, s: Shader) void {
            _ = trackerOf(ptr).shaders.free(@backingInt(s));
        }
    }.f,
    .releaseComputePipeline = struct {
        fn f(ptr: *anyopaque, p: ComputePipeline) void {
            _ = trackerOf(ptr).compute_pipelines.free(@backingInt(p));
        }
    }.f,
    .releaseGraphicsPipeline = struct {
        fn f(ptr: *anyopaque, p: GraphicsPipeline) void {
            _ = trackerOf(ptr).graphics_pipelines.free(@backingInt(p));
        }
    }.f,
    .acquireCommandBuffer = struct {
        fn f(ptr: *anyopaque) CommandBuffer {
            const t = trackerOf(ptr);
            t.frames += 1;
            return .{ .id = t.frames };
        }
    }.f,
    .pushVertexUniformData = struct {
        fn f(ptr: *anyopaque, c: *CommandBuffer, s: u32, d: []const u8) void {
            _ = c;
            _ = s;
            _ = d;
            _ = ptr;
        }
    }.f,
    .pushFragmentUniformData = struct {
        fn f(ptr: *anyopaque, c: *CommandBuffer, s: u32, d: []const u8) void {
            _ = c;
            _ = s;
            _ = d;
            _ = ptr;
        }
    }.f,
    .pushComputeUniformData = struct {
        fn f(ptr: *anyopaque, c: *CommandBuffer, s: u32, d: []const u8) void {
            _ = c;
            _ = s;
            _ = d;
            _ = ptr;
        }
    }.f,
    .acquireSwapchainTexture = struct {
        fn f(ptr: *anyopaque, c: *CommandBuffer, s: SurfaceHandle) SwapchainTexture {
            _ = c;
            _ = s;
            _ = ptr;
            return .{};
        }
    }.f,
    .waitAndAcquireSwapchainTexture = struct {
        fn f(ptr: *anyopaque, c: *CommandBuffer, s: SurfaceHandle) SwapchainTexture {
            _ = c;
            _ = s;
            _ = ptr;
            return .{};
        }
    }.f,
    .submit = struct {
        fn f(ptr: *anyopaque, c: *CommandBuffer) bool {
            const t = trackerOf(ptr);
            if (c.dropped) return false;
            t.submits += 1;
            return true;
        }
    }.f,
    .submitAndAcquireFence = struct {
        fn f(ptr: *anyopaque, c: *CommandBuffer) SubmitError!Fence {
            const t = trackerOf(ptr);
            if (c.dropped) return error.Cancelled;
            t.submits += 1;
            const id = t.fences.alloc() catch return error.DeviceLost;
            t.fences_signalled += 1;
            return @fromBackingInt(@intCast(id));
        }
    }.f,
    .cancel = struct {
        fn f(ptr: *anyopaque, c: *CommandBuffer) void {
            _ = ptr;
            c.dropped = true;
        }
    }.f,
    .waitForIdle = struct {
        fn f(ptr: *anyopaque) void {
            _ = ptr;
        }
    }.f,
    .waitForFences = struct {
        fn f(ptr: *anyopaque, fences: []const Fence, wait_all: bool) bool {
            _ = wait_all;
            const t = trackerOf(ptr);
            for (fences) |fl| {
                if (!t.fences.isLive(@backingInt(fl))) return false;
            }
            return true;
        }
    }.f,
    .queryFence = struct {
        fn f(ptr: *anyopaque, fl: Fence) bool {
            return trackerOf(ptr).fences.isLive(@backingInt(fl));
        }
    }.f,
    .releaseFence = struct {
        fn f(ptr: *anyopaque, fl: Fence) void {
            _ = trackerOf(ptr).fences.free(@backingInt(fl));
        }
    }.f,
    .renderPassBegin = struct {
        fn f(ptr: *anyopaque, c: *CommandBuffer, info: RenderPassInfo) RenderPass {
            _ = info;
            _ = ptr;
            return .{ .dev = undefined, .cmd = c, .open = !c.dropped };
        }
    }.f,
    .renderBindPipeline = struct {
        fn f(ptr: *anyopaque, c: *CommandBuffer, p: GraphicsPipeline) void {
            _ = c;
            _ = p;
            _ = ptr;
        }
    }.f,
    .renderSetViewport = struct {
        fn f(ptr: *anyopaque, c: *CommandBuffer, v: Viewport) void {
            _ = c;
            _ = v;
            _ = ptr;
        }
    }.f,
    .renderSetScissor = struct {
        fn f(ptr: *anyopaque, c: *CommandBuffer, s: Scissor) void {
            _ = c;
            _ = s;
            _ = ptr;
        }
    }.f,
    .renderSetBlendConstants = struct {
        fn f(ptr: *anyopaque, c: *CommandBuffer, r: f32, g: f32, b: f32, a: f32) void {
            _ = c;
            _ = r;
            _ = g;
            _ = b;
            _ = a;
            _ = ptr;
        }
    }.f,
    .renderSetStencilReference = struct {
        fn f(ptr: *anyopaque, c: *CommandBuffer, r: u8) void {
            _ = c;
            _ = r;
            _ = ptr;
        }
    }.f,
    .renderBindVertexBuffers = struct {
        fn f(ptr: *anyopaque, c: *CommandBuffer, s: u32, b: []const BufferBinding) void {
            _ = c;
            _ = s;
            _ = b;
            _ = ptr;
        }
    }.f,
    .renderBindIndexBuffer = struct {
        fn f(ptr: *anyopaque, c: *CommandBuffer, b: BufferBinding, e: IndexElementSize) void {
            _ = c;
            _ = b;
            _ = e;
            _ = ptr;
        }
    }.f,
    .renderBindVertexSamplers = struct {
        fn f(ptr: *anyopaque, c: *CommandBuffer, s: u32, b: []const SamplerBinding) void {
            _ = c;
            _ = s;
            _ = b;
            _ = ptr;
        }
    }.f,
    .renderBindVertexStorageTextures = struct {
        fn f(ptr: *anyopaque, c: *CommandBuffer, s: u32, t: []const Texture) void {
            _ = c;
            _ = s;
            _ = t;
            _ = ptr;
        }
    }.f,
    .renderBindVertexStorageBuffers = struct {
        fn f(ptr: *anyopaque, c: *CommandBuffer, s: u32, b: []const Buffer) void {
            _ = c;
            _ = s;
            _ = b;
            _ = ptr;
        }
    }.f,
    .renderBindFragmentSamplers = struct {
        fn f(ptr: *anyopaque, c: *CommandBuffer, s: u32, b: []const SamplerBinding) void {
            _ = c;
            _ = s;
            _ = b;
            _ = ptr;
        }
    }.f,
    .renderBindFragmentStorageTextures = struct {
        fn f(ptr: *anyopaque, c: *CommandBuffer, s: u32, t: []const Texture) void {
            _ = c;
            _ = s;
            _ = t;
            _ = ptr;
        }
    }.f,
    .renderBindFragmentStorageBuffers = struct {
        fn f(ptr: *anyopaque, c: *CommandBuffer, s: u32, b: []const Buffer) void {
            _ = c;
            _ = s;
            _ = b;
            _ = ptr;
        }
    }.f,
    .renderDraw = struct {
        fn f(ptr: *anyopaque, c: *CommandBuffer, d: DrawParams) void {
            _ = d;
            _ = c;
            trackerOf(ptr).draws += 1;
        }
    }.f,
    .renderDrawIndexed = struct {
        fn f(ptr: *anyopaque, c: *CommandBuffer, d: DrawIndexedParams) void {
            _ = d;
            _ = c;
            trackerOf(ptr).draws += 1;
        }
    }.f,
    .renderDrawIndirect = struct {
        fn f(ptr: *anyopaque, c: *CommandBuffer, b: Buffer, o: u32, n: u32) void {
            _ = b;
            _ = o;
            _ = n;
            _ = c;
            trackerOf(ptr).draws += 1;
        }
    }.f,
    .renderDrawIndexedIndirect = struct {
        fn f(ptr: *anyopaque, c: *CommandBuffer, b: Buffer, o: u32, n: u32) void {
            _ = b;
            _ = o;
            _ = n;
            _ = c;
            trackerOf(ptr).draws += 1;
        }
    }.f,
    .renderPassEnd = struct {
        fn f(ptr: *anyopaque, c: *CommandBuffer) void {
            _ = c;
            _ = ptr;
        }
    }.f,
    .computePassBegin = struct {
        fn f(ptr: *anyopaque, c: *CommandBuffer, info: ComputePassInfo) ComputePass {
            _ = info;
            _ = ptr;
            return .{ .dev = undefined, .cmd = c, .open = !c.dropped };
        }
    }.f,
    .computeBindPipeline = struct {
        fn f(ptr: *anyopaque, c: *CommandBuffer, p: ComputePipeline) void {
            _ = c;
            _ = p;
            _ = ptr;
        }
    }.f,
    .computeBindSamplers = struct {
        fn f(ptr: *anyopaque, c: *CommandBuffer, s: u32, b: []const SamplerBinding) void {
            _ = c;
            _ = s;
            _ = b;
            _ = ptr;
        }
    }.f,
    .computeBindStorageTextures = struct {
        fn f(ptr: *anyopaque, c: *CommandBuffer, s: u32, b: []const StorageTextureBinding) void {
            _ = c;
            _ = s;
            _ = b;
            _ = ptr;
        }
    }.f,
    .computeBindStorageBuffers = struct {
        fn f(ptr: *anyopaque, c: *CommandBuffer, s: u32, b: []const Buffer) void {
            _ = c;
            _ = s;
            _ = b;
            _ = ptr;
        }
    }.f,
    .computeDispatch = struct {
        fn f(ptr: *anyopaque, c: *CommandBuffer, d: DispatchParams) void {
            _ = d;
            _ = c;
            trackerOf(ptr).draws += 1;
        }
    }.f,
    .computeDispatchIndirect = struct {
        fn f(ptr: *anyopaque, c: *CommandBuffer, b: Buffer, o: u32) void {
            _ = b;
            _ = o;
            _ = c;
            trackerOf(ptr).draws += 1;
        }
    }.f,
    .computePassEnd = struct {
        fn f(ptr: *anyopaque, c: *CommandBuffer) void {
            _ = c;
            _ = ptr;
        }
    }.f,
    .copyPassBegin = struct {
        fn f(ptr: *anyopaque, c: *CommandBuffer) CopyPass {
            _ = ptr;
            return .{ .dev = undefined, .cmd = c, .open = !c.dropped };
        }
    }.f,
    .copyUploadToTexture = struct {
        fn f(ptr: *anyopaque, c: *CommandBuffer, s: TextureTransferInfo, r: TextureRegion, cy: bool) void {
            _ = c;
            _ = s;
            _ = r;
            _ = cy;
            _ = ptr;
        }
    }.f,
    .copyUploadToBuffer = struct {
        fn f(ptr: *anyopaque, c: *CommandBuffer, s: TransferBufferLocation, d: BufferRegion, cy: bool) void {
            _ = c;
            _ = s;
            _ = d;
            _ = cy;
            _ = ptr;
        }
    }.f,
    .copyTextureToTexture = struct {
        fn f(ptr: *anyopaque, c: *CommandBuffer, s: TextureLocation, d: TextureLocation, w: u32, h: u32, dep: u32, cy: bool) void {
            _ = c;
            _ = s;
            _ = d;
            _ = w;
            _ = h;
            _ = dep;
            _ = cy;
            _ = ptr;
        }
    }.f,
    .copyBufferToBuffer = struct {
        fn f(ptr: *anyopaque, c: *CommandBuffer, s: BufferLocation, d: BufferLocation, n: u32, cy: bool) void {
            _ = c;
            _ = s;
            _ = d;
            _ = n;
            _ = cy;
            _ = ptr;
        }
    }.f,
    .copyDownloadFromTexture = struct {
        fn f(ptr: *anyopaque, c: *CommandBuffer, r: TextureRegion, d: TextureTransferInfo) void {
            _ = c;
            _ = r;
            _ = d;
            _ = ptr;
        }
    }.f,
    .copyDownloadFromBuffer = struct {
        fn f(ptr: *anyopaque, c: *CommandBuffer, s: BufferRegion, d: TransferBufferLocation) void {
            _ = c;
            _ = s;
            _ = d;
            _ = ptr;
        }
    }.f,
    .copyPassEnd = struct {
        fn f(ptr: *anyopaque, c: *CommandBuffer) void {
            _ = c;
            _ = ptr;
        }
    }.f,
    .generateMipmaps = struct {
        fn f(ptr: *anyopaque, c: *CommandBuffer, t: Texture) void {
            _ = c;
            _ = t;
            _ = ptr;
        }
    }.f,
    .blitTexture = struct {
        fn f(ptr: *anyopaque, c: *CommandBuffer, b: BlitInfo) void {
            _ = c;
            _ = b;
            _ = ptr;
        }
    }.f,
    .mapTransferBuffer = struct {
        fn f(ptr: *anyopaque, t: TransferBuffer, cy: bool) MapError![]u8 {
            _ = t;
            _ = cy;
            _ = ptr;
            return error.Unsupported;
        }
    }.f,
    .unmapTransferBuffer = struct {
        fn f(ptr: *anyopaque, t: TransferBuffer) void {
            _ = t;
            _ = ptr;
        }
    }.f,
    .supportsTextureFormat = struct {
        fn f(ptr: *anyopaque, format: TextureFormat, @"type": TextureType, usage: u32) bool {
            _ = @"type";
            _ = usage;
            _ = ptr;
            return format != .invalid and !isCompressedFormat(format);
        }
    }.f,
    .supportsSampleCount = struct {
        fn f(ptr: *anyopaque, format: TextureFormat, count: SampleCount) bool {
            _ = format;
            _ = ptr;
            return count == .count_1;
        }
    }.f,
    .claim = struct {
        fn f(ptr: *anyopaque, s: SurfaceHandle) void {
            _ = s;
            trackerOf(ptr).claims += 1;
        }
    }.f,
    .acquire = struct {
        fn f(ptr: *anyopaque) CommandBuffer {
            const t = trackerOf(ptr);
            t.frames += 1;
            return .{ .id = t.frames };
        }
    }.f,
    .drawScene = struct {
        fn f(ptr: *anyopaque, c: *CommandBuffer, scene: *const Scene, pixels: []const u8) bool {
            _ = scene;
            _ = pixels;
            _ = c;
            trackerOf(ptr).draws += 1;
            return true;
        }
    }.f,
    .submitScene = struct {
        fn f(ptr: *anyopaque, c: *CommandBuffer) void {
            _ = c;
            trackerOf(ptr).submits += 1;
        }
    }.f,
};

// NOTE: `renderPassBegin`/`computePassBegin`/`copyPassBegin` above return
// passes with `.dev = undefined` because a vtable fn cannot name its own
// `Device` fat pointer. The public `Device.begin*Pass` wrappers fill in
// `dev` right after the call — always use those, never the vtable fns.

test "device kinds have stable names" {
    try std.testing.expectEqualStrings("vulkan", DeviceKind.vulkan.name());
    try std.testing.expectEqualStrings("software", DeviceKind.software.name());
    try std.testing.expectEqualStrings("null", DeviceKind.null.name());
}

test "preferred order ends with null fallback" {
    const order = preferredOrder();
    try std.testing.expectEqual(DeviceKind.null, order[order.len - 1]);
}

test "texture format ordinals match SDL_gpu.h order" {
    try std.testing.expectEqual(@as(u32, 0), @backingInt(TextureFormat.invalid));
    try std.testing.expectEqual(@as(u32, 1), @backingInt(TextureFormat.a8_unorm));
    try std.testing.expectEqual(@as(u32, 4), @backingInt(TextureFormat.r8g8b8a8_unorm));
    try std.testing.expectEqual(@as(u32, 12), @backingInt(TextureFormat.b8g8r8a8_unorm));
    try std.testing.expectEqual(@as(u32, 13), @backingInt(TextureFormat.bc1_rgba_unorm));
    try std.testing.expectEqual(@as(u32, 52), @backingInt(TextureFormat.r8g8b8a8_unorm_srgb));
    try std.testing.expectEqual(@as(u32, 58), @backingInt(TextureFormat.d16_unorm));
    try std.testing.expectEqual(@as(u32, 63), @backingInt(TextureFormat.astc_4x4_unorm));
    try std.testing.expectEqual(@as(u32, 104), @backingInt(TextureFormat.astc_12x12_float));
}

test "texel block sizes match SDL_GPUTextureFormatTexelBlockSize" {
    try std.testing.expectEqual(@as(u32, 4), texelBlockSize(.r8g8b8a8_unorm));
    try std.testing.expectEqual(@as(u32, 4), texelBlockSize(.b8g8r8a8_unorm));
    try std.testing.expectEqual(@as(u32, 1), texelBlockSize(.r8_unorm));
    try std.testing.expectEqual(@as(u32, 8), texelBlockSize(.r16g16b16a16_float));
    try std.testing.expectEqual(@as(u32, 8), texelBlockSize(.bc1_rgba_unorm));
    try std.testing.expectEqual(@as(u32, 16), texelBlockSize(.bc3_rgba_unorm));
    try std.testing.expectEqual(@as(u32, 16), texelBlockSize(.astc_8x8_unorm));
    try std.testing.expectEqual(@as(u32, 4), texelBlockSize(.d32_float));
    try std.testing.expectEqual(@as(u32, 0), texelBlockSize(.invalid));
}

test "texture format sizes account for compression blocks" {
    try std.testing.expectEqual(@as(u32, 16384), textureFormatSize(.r8g8b8a8_unorm, 64, 64));
    // BC1 8x8 = 2x2 blocks of 8 bytes.
    try std.testing.expectEqual(@as(u32, 32), textureFormatSize(.bc1_rgba_unorm, 8, 8));
    // Non-multiple dimensions round blocks up: 5x5 BC1 = 2x2 blocks.
    try std.testing.expectEqual(@as(u32, 32), textureFormatSize(.bc1_rgba_unorm, 5, 5));
    try std.testing.expectEqual(@as(u32, 0), textureFormatSize(.invalid, 64, 64));
    try std.testing.expectEqual(@as(u32, 0), textureFormatSize(.r8_unorm, 0, 64));
}

test "vertex element sizes" {
    try std.testing.expectEqual(@as(u32, 16), vertexElementSize(.float4));
    try std.testing.expectEqual(@as(u32, 12), vertexElementSize(.float3));
    try std.testing.expectEqual(@as(u32, 4), vertexElementSize(.ubyte4_norm));
    try std.testing.expectEqual(@as(u32, 4), vertexElementSize(.half2));
    try std.testing.expectEqual(@as(u32, 8), vertexElementSize(.half4));
    try std.testing.expectEqual(@as(u32, 0), vertexElementSize(.invalid));
}

test "shader formats follow backend" {
    try std.testing.expectEqual(ShaderFormat.spirv, shaderFormatsFor(.vulkan));
    try std.testing.expect(shaderFormatsFor(.metal) & ShaderFormat.msl != 0);
    try std.testing.expect(shaderFormatsFor(.metal) & ShaderFormat.metallib != 0);
    try std.testing.expect(shaderFormatsFor(.d3d12) & ShaderFormat.dxil != 0);
    try std.testing.expectEqual(ShaderFormat.none, shaderFormatsFor(.software));
    try std.testing.expectEqual(ShaderFormat.none, shaderFormatsFor(.null));
}

test "driver names list the SDL backends" {
    try std.testing.expectEqual(@as(usize, 4), driver_names.len);
    try std.testing.expectEqualStrings("vulkan", driver_names[0]);
    try std.testing.expectEqualStrings("vulkan", defaultDriver());
}

test "premultiplied alpha blend matches the 2D pipeline" {
    const b = ColorTargetBlendState.premultipliedAlpha();
    try std.testing.expect(b.enable_blend);
    try std.testing.expectEqual(BlendFactor.one, b.src_color_blendfactor);
    try std.testing.expectEqual(BlendFactor.one_minus_src_alpha, b.dst_color_blendfactor);
    try std.testing.expectEqual(BlendOp.add, b.color_blend_op);
}

test "stub tracker enforces pool caps and detects double free" {
    var t = Tracker{ .kind = .null };
    var dev = Device{ .ptr = &t, .vtable = &stub_vtable };
    try std.testing.expectEqual(DeviceKind.null, dev.kind());
    try std.testing.expectEqualStrings("null", dev.driverName());

    const b = try dev.createBuffer(.{ .usage = BufferUsage.vertex, .size = 64 });
    try std.testing.expect(b != .null);
    try std.testing.expectError(error.InvalidUsage, dev.createBuffer(.{ .usage = 0, .size = 64 }));
    try std.testing.expectError(error.InvalidUsage, dev.createBuffer(.{ .usage = BufferUsage.vertex, .size = 0 }));
    try std.testing.expectError(error.UnsupportedFormat, dev.createTexture(.{
        .format = .invalid,
        .usage = TextureUsage.sampler,
        .width = 4,
        .height = 4,
    }));

    // Exhaust the buffer pool, then recover one slot.
    var i: u32 = 1;
    while (i < limits.MAX_GPU_BUFFERS) : (i += 1) {
        _ = try dev.createBuffer(.{ .usage = BufferUsage.vertex, .size = 16 });
    }
    try std.testing.expectError(error.OutOfHandles, dev.createBuffer(.{ .usage = BufferUsage.vertex, .size = 16 }));
    dev.releaseBuffer(b);
    const b2 = try dev.createBuffer(.{ .usage = BufferUsage.index, .size = 16 });
    try std.testing.expect(b2 != .null);
    // Double release + null release are safe no-ops.
    dev.releaseBuffer(b);
    dev.releaseBuffer(.null);

    var cmd = dev.acquireCommandBuffer();
    try std.testing.expect(dev.submitCommandBuffer(&cmd));
    dev.cancelCommandBuffer(&cmd);
    try std.testing.expect(!dev.submitCommandBuffer(&cmd));
    try std.testing.expectError(error.Cancelled, dev.submitAndAcquireFence(&cmd));
}
