//! Vulkan 1.3 ABI declarations used by the native sokol_gfx Vulkan backend.
//!
//! No C headers are imported. The constants, structs and function pointer types
//! below follow the Vulkan specification (vulkan_core.h). Every entry point is
//! resolved at runtime through `vkGetInstanceProcAddr` / `vkGetDeviceProcAddr`.
//! Non-dispatchable handles are 64-bit integers (the ABI on every platform),
//! dispatchable handles are opaque pointers.
const std = @import("std");

pub const Instance = ?*anyopaque;
pub const PhysicalDevice = ?*anyopaque;
pub const Device = ?*anyopaque;
pub const Queue = ?*anyopaque;
pub const CommandBuffer = ?*anyopaque;

pub const Buffer = u64;
pub const Image = u64;
pub const ImageView = u64;
pub const Sampler = u64;
pub const DeviceMemory = u64;
pub const ShaderModule = u64;
pub const Pipeline = u64;
pub const PipelineLayout = u64;
pub const DescriptorSetLayout = u64;
pub const CommandPool = u64;
pub const Fence = u64;
pub const Semaphore = u64;
pub const PipelineCache = u64;

pub const WHOLE_SIZE: u64 = ~@as(u64, 0);
pub const QUEUE_FAMILY_IGNORED: u32 = ~@as(u32, 0);
pub const REMAINING_MIP_LEVELS: u32 = ~@as(u32, 0);
pub const REMAINING_ARRAY_LAYERS: u32 = ~@as(u32, 0);
pub const TRUE: u32 = 1;
pub const FALSE: u32 = 0;
pub const MAX_PHYSICAL_DEVICE_NAME_SIZE = 256;
pub const UUID_SIZE = 16;

pub const AllocationCallbacks = anyopaque;
pub const ClearColorValue = extern union {
    float32: [4]f32,
    int32: [4]i32,
    uint32: [4]u32,
};
pub const ClearDepthStencilValue = extern struct {
    depth: f32 = 0,
    stencil: u32 = 0,
};
pub const ClearValue = extern union {
    color: ClearColorValue,
    depthStencil: ClearDepthStencilValue,
};
pub const DescriptorDataEXT = extern union {
    pSampler: ?*const Sampler,
    pCombinedImageSampler: ?*const anyopaque,
    pInputAttachmentImage: ?*const anyopaque,
    pSampledImage: ?*const anyopaque,
    pStorageImage: ?*const anyopaque,
    pUniformTexelBuffer: ?*const anyopaque,
    pStorageTexelBuffer: ?*const anyopaque,
    pUniformBuffer: ?*const DescriptorAddressInfoEXT,
    pStorageBuffer: ?*const DescriptorAddressInfoEXT,
    accelerationStructure: u64,
};
pub const DescriptorGetInfoEXT = extern struct {
    sType: i32 = 0,
    pNext: ?*const anyopaque = null,
    type: i32 = 0,
    data: DescriptorDataEXT = std.mem.zeroes(DescriptorDataEXT),
};
pub const RenderingAttachmentInfo = extern struct {
    sType: i32 = 0,
    pNext: ?*const anyopaque = null,
    imageView: ImageView = std.mem.zeroes(ImageView),
    imageLayout: i32 = 0,
    resolveMode: u32 = 0,
    resolveImageView: ImageView = std.mem.zeroes(ImageView),
    resolveImageLayout: i32 = 0,
    loadOp: i32 = 0,
    storeOp: i32 = 0,
    clearValue: ClearValue = std.mem.zeroes(ClearValue),
};
pub const PushConstantRange = extern struct {
    stageFlags: u32 = 0,
    offset: u32 = 0,
    size: u32 = 0,
};

// ---------------------------------------------------------------- constants

// ---------------------------------------------------------------- constants (VK_* values)

// ---- enums
// ---- image layouts / result / misc enums (i32)
pub const IMAGE_LAYOUT_UNDEFINED: i32 = 0;
pub const IMAGE_LAYOUT_GENERAL: i32 = 1;
pub const IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL: i32 = 2;
pub const IMAGE_LAYOUT_DEPTH_STENCIL_ATTACHMENT_OPTIMAL: i32 = 3;
pub const IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL: i32 = 6;
pub const IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL: i32 = 7;
pub const IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL: i32 = 5;
pub const IMAGE_LAYOUT_PRESENT_SRC_KHR: i32 = 1000001002;
pub const IMAGE_LAYOUT_ATTACHMENT_OPTIMAL: i32 = 1000314001;
pub const IMAGE_LAYOUT_DEPTH_STENCIL_READ_ONLY_OPTIMAL: i32 = 4;
pub const SUCCESS: i32 = 0;
pub const NOT_READY: i32 = 1;
pub const TIMEOUT: i32 = 2;
pub const SUBOPTIMAL_KHR: i32 = 1000001003;
pub const ERROR_OUT_OF_DATE_KHR: i32 = -1000001004;
pub const IMAGE_TYPE_1D: i32 = 0;
pub const IMAGE_TYPE_2D: i32 = 1;
pub const IMAGE_TYPE_3D: i32 = 2;
pub const IMAGE_VIEW_TYPE_1D: i32 = 0;
pub const IMAGE_VIEW_TYPE_2D: i32 = 1;
pub const IMAGE_VIEW_TYPE_3D: i32 = 2;
pub const IMAGE_VIEW_TYPE_CUBE: i32 = 3;
pub const IMAGE_VIEW_TYPE_1D_ARRAY: i32 = 4;
pub const IMAGE_VIEW_TYPE_2D_ARRAY: i32 = 5;
pub const IMAGE_TILING_OPTIMAL: i32 = 0;
pub const FILTER_NEAREST: i32 = 0;
pub const FILTER_LINEAR: i32 = 1;
pub const SAMPLER_MIPMAP_MODE_NEAREST: i32 = 0;
pub const SAMPLER_MIPMAP_MODE_LINEAR: i32 = 1;
pub const SAMPLER_ADDRESS_MODE_REPEAT: i32 = 0;
pub const SAMPLER_ADDRESS_MODE_MIRRORED_REPEAT: i32 = 1;
pub const SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE: i32 = 2;
pub const SAMPLER_ADDRESS_MODE_CLAMP_TO_BORDER: i32 = 3;
pub const BORDER_COLOR_FLOAT_TRANSPARENT_BLACK: i32 = 0;
pub const BORDER_COLOR_FLOAT_OPAQUE_BLACK: i32 = 2;
pub const BORDER_COLOR_FLOAT_OPAQUE_WHITE: i32 = 4;
pub const COMPARE_OP_NEVER: i32 = 0;
pub const COMPARE_OP_LESS: i32 = 1;
pub const COMPARE_OP_EQUAL: i32 = 2;
pub const COMPARE_OP_LESS_OR_EQUAL: i32 = 3;
pub const COMPARE_OP_GREATER: i32 = 4;
pub const COMPARE_OP_NOT_EQUAL: i32 = 5;
pub const COMPARE_OP_GREATER_OR_EQUAL: i32 = 6;
pub const COMPARE_OP_ALWAYS: i32 = 7;
pub const STENCIL_OP_KEEP: i32 = 0;
pub const STENCIL_OP_ZERO: i32 = 1;
pub const STENCIL_OP_REPLACE: i32 = 2;
pub const STENCIL_OP_INCREMENT_AND_CLAMP: i32 = 3;
pub const STENCIL_OP_DECREMENT_AND_CLAMP: i32 = 4;
pub const STENCIL_OP_INVERT: i32 = 5;
pub const STENCIL_OP_INCREMENT_AND_WRAP: i32 = 6;
pub const STENCIL_OP_DECREMENT_AND_WRAP: i32 = 7;
pub const BLEND_OP_ADD: i32 = 0;
pub const BLEND_OP_SUBTRACT: i32 = 1;
pub const BLEND_OP_REVERSE_SUBTRACT: i32 = 2;
pub const BLEND_OP_MIN: i32 = 3;
pub const BLEND_OP_MAX: i32 = 4;
pub const BLEND_FACTOR_ZERO: i32 = 0;
pub const BLEND_FACTOR_ONE: i32 = 1;
pub const BLEND_FACTOR_SRC_COLOR: i32 = 2;
pub const BLEND_FACTOR_ONE_MINUS_SRC_COLOR: i32 = 3;
pub const BLEND_FACTOR_DST_COLOR: i32 = 4;
pub const BLEND_FACTOR_ONE_MINUS_DST_COLOR: i32 = 5;
pub const BLEND_FACTOR_SRC_ALPHA: i32 = 6;
pub const BLEND_FACTOR_ONE_MINUS_SRC_ALPHA: i32 = 7;
pub const BLEND_FACTOR_DST_ALPHA: i32 = 8;
pub const BLEND_FACTOR_ONE_MINUS_DST_ALPHA: i32 = 9;
pub const BLEND_FACTOR_CONSTANT_COLOR: i32 = 10;
pub const BLEND_FACTOR_ONE_MINUS_CONSTANT_COLOR: i32 = 11;
pub const BLEND_FACTOR_CONSTANT_ALPHA: i32 = 12;
pub const BLEND_FACTOR_ONE_MINUS_CONSTANT_ALPHA: i32 = 13;
pub const BLEND_FACTOR_SRC_ALPHA_SATURATE: i32 = 14;
pub const BLEND_FACTOR_SRC1_COLOR: i32 = 15;
pub const BLEND_FACTOR_ONE_MINUS_SRC1_COLOR: i32 = 16;
pub const BLEND_FACTOR_SRC1_ALPHA: i32 = 17;
pub const BLEND_FACTOR_ONE_MINUS_SRC1_ALPHA: i32 = 18;
pub const ATTACHMENT_LOAD_OP_LOAD: i32 = 0;
pub const ATTACHMENT_LOAD_OP_CLEAR: i32 = 1;
pub const ATTACHMENT_LOAD_OP_DONT_CARE: i32 = 2;
pub const ATTACHMENT_STORE_OP_STORE: i32 = 0;
pub const ATTACHMENT_STORE_OP_DONT_CARE: i32 = 1;
pub const INDEX_TYPE_UINT16: i32 = 0;
pub const INDEX_TYPE_UINT32: i32 = 1;
pub const VERTEX_INPUT_RATE_VERTEX: i32 = 0;
pub const VERTEX_INPUT_RATE_INSTANCE: i32 = 1;
pub const PRIMITIVE_TOPOLOGY_POINT_LIST: i32 = 0;
pub const PRIMITIVE_TOPOLOGY_LINE_LIST: i32 = 1;
pub const PRIMITIVE_TOPOLOGY_LINE_STRIP: i32 = 2;
pub const PRIMITIVE_TOPOLOGY_TRIANGLE_LIST: i32 = 3;
pub const PRIMITIVE_TOPOLOGY_TRIANGLE_STRIP: i32 = 4;
pub const FRONT_FACE_COUNTER_CLOCKWISE: i32 = 0;
pub const FRONT_FACE_CLOCKWISE: i32 = 1;
pub const POLYGON_MODE_FILL: i32 = 0;
pub const PIPELINE_BIND_POINT_GRAPHICS: i32 = 0;
pub const PIPELINE_BIND_POINT_COMPUTE: i32 = 1;
pub const COMMAND_BUFFER_LEVEL_PRIMARY: i32 = 0;
pub const DYNAMIC_STATE_VIEWPORT: i32 = 0;
pub const DYNAMIC_STATE_SCISSOR: i32 = 1;
pub const SHARING_MODE_EXCLUSIVE: i32 = 0;
pub const DESCRIPTOR_TYPE_SAMPLER: i32 = 0;
pub const DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER: i32 = 1;
pub const DESCRIPTOR_TYPE_SAMPLED_IMAGE: i32 = 2;
pub const DESCRIPTOR_TYPE_STORAGE_IMAGE: i32 = 3;
pub const DESCRIPTOR_TYPE_UNIFORM_BUFFER: i32 = 6;
pub const DESCRIPTOR_TYPE_STORAGE_BUFFER: i32 = 7;
pub const OBJECT_TYPE_BUFFER: i32 = 9;
pub const OBJECT_TYPE_IMAGE: i32 = 10;
pub const OBJECT_TYPE_IMAGE_VIEW: i32 = 14;
pub const OBJECT_TYPE_SAMPLER: i32 = 21;
pub const OBJECT_TYPE_SHADER_MODULE: i32 = 15;
pub const OBJECT_TYPE_PIPELINE_LAYOUT: i32 = 17;
pub const OBJECT_TYPE_PIPELINE: i32 = 19;
pub const OBJECT_TYPE_COMMAND_POOL: i32 = 25;
pub const OBJECT_TYPE_COMMAND_BUFFER: i32 = 6;
pub const OBJECT_TYPE_DEVICE_MEMORY: i32 = 8;
pub const OBJECT_TYPE_FENCE: i32 = 7;
pub const OBJECT_TYPE_DESCRIPTOR_SET_LAYOUT: i32 = 20;
pub const OBJECT_TYPE_SEMAPHORE: i32 = 5;
pub const OBJECT_TYPE_QUEUE: i32 = 4;
pub const OBJECT_TYPE_DEVICE: i32 = 3;
pub const OBJECT_TYPE_PHYSICAL_DEVICE: i32 = 2;
pub const OBJECT_TYPE_INSTANCE: i32 = 1;
// ---- 32-bit flags
pub const IMAGE_ASPECT_COLOR_BIT: u32 = 0x00000001;
pub const IMAGE_ASPECT_DEPTH_BIT: u32 = 0x00000002;
pub const IMAGE_ASPECT_STENCIL_BIT: u32 = 0x00000004;
pub const BUFFER_USAGE_TRANSFER_SRC_BIT: u32 = 0x00000001;
pub const BUFFER_USAGE_TRANSFER_DST_BIT: u32 = 0x00000002;
pub const BUFFER_USAGE_UNIFORM_BUFFER_BIT: u32 = 0x00000010;
pub const BUFFER_USAGE_STORAGE_BUFFER_BIT: u32 = 0x00000020;
pub const BUFFER_USAGE_INDEX_BUFFER_BIT: u32 = 0x00000040;
pub const BUFFER_USAGE_VERTEX_BUFFER_BIT: u32 = 0x00000080;
pub const BUFFER_USAGE_SHADER_DEVICE_ADDRESS_BIT: u32 = 0x00020000;
pub const BUFFER_USAGE_RESOURCE_DESCRIPTOR_BUFFER_BIT_EXT: u32 = 0x00400000;
pub const BUFFER_USAGE_SAMPLER_DESCRIPTOR_BUFFER_BIT_EXT: u32 = 0x00200000;
pub const IMAGE_USAGE_TRANSFER_SRC_BIT: u32 = 0x00000001;
pub const IMAGE_USAGE_TRANSFER_DST_BIT: u32 = 0x00000002;
pub const IMAGE_USAGE_SAMPLED_BIT: u32 = 0x00000004;
pub const IMAGE_USAGE_STORAGE_BIT: u32 = 0x00000008;
pub const IMAGE_USAGE_COLOR_ATTACHMENT_BIT: u32 = 0x00000010;
pub const IMAGE_USAGE_DEPTH_STENCIL_ATTACHMENT_BIT: u32 = 0x00000020;
pub const IMAGE_CREATE_CUBE_COMPATIBLE_BIT: u32 = 0x00000010;
pub const MEMORY_PROPERTY_DEVICE_LOCAL_BIT: u32 = 0x00000001;
pub const MEMORY_PROPERTY_HOST_VISIBLE_BIT: u32 = 0x00000002;
pub const MEMORY_PROPERTY_HOST_COHERENT_BIT: u32 = 0x00000004;
pub const MEMORY_PROPERTY_HOST_CACHED_BIT: u32 = 0x00000008;
pub const MEMORY_ALLOCATE_DEVICE_ADDRESS_BIT: u32 = 0x00000002;
pub const COMMAND_POOL_CREATE_TRANSIENT_BIT: u32 = 0x00000001;
pub const COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT: u32 = 0x00000002;
pub const COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT: u32 = 0x00000001;
pub const FENCE_CREATE_SIGNALED_BIT: u32 = 0x00000001;
pub const FORMAT_FEATURE_SAMPLED_IMAGE_BIT: u32 = 0x00000001;
pub const FORMAT_FEATURE_SAMPLED_IMAGE_FILTER_LINEAR_BIT: u32 = 0x00001000;
pub const FORMAT_FEATURE_COLOR_ATTACHMENT_BIT: u32 = 0x00000080;
pub const FORMAT_FEATURE_COLOR_ATTACHMENT_BLEND_BIT: u32 = 0x00000100;
pub const FORMAT_FEATURE_DEPTH_STENCIL_ATTACHMENT_BIT: u32 = 0x00000200;
pub const FORMAT_FEATURE_STORAGE_IMAGE_BIT: u32 = 0x00000002;
pub const SAMPLE_COUNT_1_BIT: u32 = 0x00000001;
pub const SHADER_STAGE_VERTEX_BIT: u32 = 0x00000001;
pub const SHADER_STAGE_FRAGMENT_BIT: u32 = 0x00000010;
pub const SHADER_STAGE_COMPUTE_BIT: u32 = 0x00000020;
pub const COLOR_COMPONENT_R_BIT: u32 = 0x00000001;
pub const COLOR_COMPONENT_G_BIT: u32 = 0x00000002;
pub const COLOR_COMPONENT_B_BIT: u32 = 0x00000004;
pub const COLOR_COMPONENT_A_BIT: u32 = 0x00000008;
pub const CULL_MODE_NONE: u32 = 0;
pub const CULL_MODE_FRONT_BIT: u32 = 0x00000001;
pub const CULL_MODE_BACK_BIT: u32 = 0x00000002;
pub const DESCRIPTOR_SET_LAYOUT_CREATE_DESCRIPTOR_BUFFER_BIT_EXT: u32 = 0x00000010;
pub const DESCRIPTOR_SET_LAYOUT_CREATE_PUSH_DESCRIPTOR_BIT: u32 = 0x00000001;
pub const DEPENDENCY_BY_REGION_BIT: u32 = 0x00000001;
// ---- 64-bit flags (sync2)

// ---- 64-bit flags
pub const PIPELINE_STAGE_2_NONE: u64 = 0;
pub const PIPELINE_STAGE_2_COPY_BIT: u64 = 0x100000000;
pub const PIPELINE_STAGE_2_VERTEX_ATTRIBUTE_INPUT_BIT: u64 = 0x2000000000;
pub const PIPELINE_STAGE_2_INDEX_INPUT_BIT: u64 = 0x1000000000;
pub const PIPELINE_STAGE_2_VERTEX_SHADER_BIT: u64 = 0x00000008;
pub const PIPELINE_STAGE_2_FRAGMENT_SHADER_BIT: u64 = 0x00000080;
pub const PIPELINE_STAGE_2_COMPUTE_SHADER_BIT: u64 = 0x00000800;
pub const PIPELINE_STAGE_2_COLOR_ATTACHMENT_OUTPUT_BIT: u64 = 0x00000400;
pub const PIPELINE_STAGE_2_EARLY_FRAGMENT_TESTS_BIT: u64 = 0x00000100;
pub const PIPELINE_STAGE_2_LATE_FRAGMENT_TESTS_BIT: u64 = 0x00000200;
pub const PIPELINE_STAGE_2_ALL_COMMANDS_BIT: u64 = 0x00010000;
pub const PIPELINE_STAGE_2_ALL_TRANSFER_BIT: u64 = 0x00001000;
pub const PIPELINE_STAGE_2_TOP_OF_PIPE_BIT: u64 = 0x00000001;
pub const PIPELINE_STAGE_2_BOTTOM_OF_PIPE_BIT: u64 = 0x00002000;
pub const ACCESS_2_NONE: u64 = 0;
pub const ACCESS_2_VERTEX_ATTRIBUTE_READ_BIT: u64 = 0x00000004;
pub const ACCESS_2_INDEX_READ_BIT: u64 = 0x00000002;
pub const ACCESS_2_SHADER_STORAGE_READ_BIT: u64 = 0x200000000;
pub const ACCESS_2_SHADER_STORAGE_WRITE_BIT: u64 = 0x400000000;
pub const ACCESS_2_SHADER_SAMPLED_READ_BIT: u64 = 0x100000000;
pub const ACCESS_2_TRANSFER_WRITE_BIT: u64 = 0x00001000;
pub const ACCESS_2_TRANSFER_READ_BIT: u64 = 0x00000800;
pub const ACCESS_2_COLOR_ATTACHMENT_WRITE_BIT: u64 = 0x00000100;
pub const ACCESS_2_COLOR_ATTACHMENT_READ_BIT: u64 = 0x00000080;
pub const ACCESS_2_DEPTH_STENCIL_ATTACHMENT_WRITE_BIT: u64 = 0x00000400;
pub const ACCESS_2_DEPTH_STENCIL_ATTACHMENT_READ_BIT: u64 = 0x00000200;
pub const ACCESS_2_MEMORY_READ_BIT: u64 = 0x00008000;
pub const ACCESS_2_MEMORY_WRITE_BIT: u64 = 0x00010000;

// ---- formats
pub const FORMAT_UNDEFINED: i32 = 0;
pub const FORMAT_R8_UNORM: i32 = 9;
pub const FORMAT_R8_SNORM: i32 = 10;
pub const FORMAT_R8_UINT: i32 = 13;
pub const FORMAT_R8_SINT: i32 = 14;
pub const FORMAT_R16_UNORM: i32 = 70;
pub const FORMAT_R16_SNORM: i32 = 71;
pub const FORMAT_R16_UINT: i32 = 74;
pub const FORMAT_R16_SINT: i32 = 75;
pub const FORMAT_R16_SFLOAT: i32 = 76;
pub const FORMAT_R8G8_UNORM: i32 = 16;
pub const FORMAT_R8G8_SNORM: i32 = 17;
pub const FORMAT_R8G8_UINT: i32 = 20;
pub const FORMAT_R8G8_SINT: i32 = 21;
pub const FORMAT_R32_UINT: i32 = 98;
pub const FORMAT_R32_SINT: i32 = 99;
pub const FORMAT_R32_SFLOAT: i32 = 100;
pub const FORMAT_R16G16_UNORM: i32 = 77;
pub const FORMAT_R16G16_SNORM: i32 = 78;
pub const FORMAT_R16G16_UINT: i32 = 81;
pub const FORMAT_R16G16_SINT: i32 = 82;
pub const FORMAT_R16G16_SFLOAT: i32 = 83;
pub const FORMAT_R8G8B8A8_UNORM: i32 = 37;
pub const FORMAT_R8G8B8A8_SNORM: i32 = 38;
pub const FORMAT_R8G8B8A8_UINT: i32 = 41;
pub const FORMAT_R8G8B8A8_SINT: i32 = 42;
pub const FORMAT_R8G8B8A8_SRGB: i32 = 43;
pub const FORMAT_B8G8R8A8_UNORM: i32 = 44;
pub const FORMAT_B8G8R8A8_SRGB: i32 = 50;
pub const FORMAT_A2B10G10R10_UNORM_PACK32: i32 = 64;
pub const FORMAT_A2B10G10R10_UINT_PACK32: i32 = 68;

pub const FORMAT_E5B9G9R9_UFLOAT_PACK32: i32 = 123;
pub const FORMAT_R32G32_UINT: i32 = 101;
pub const FORMAT_R32G32_SINT: i32 = 102;
pub const FORMAT_R32G32_SFLOAT: i32 = 103;
pub const FORMAT_R16G16B16A16_UNORM: i32 = 91;
pub const FORMAT_R16G16B16A16_SNORM: i32 = 92;
pub const FORMAT_R16G16B16A16_UINT: i32 = 95;
pub const FORMAT_R16G16B16A16_SINT: i32 = 96;
pub const FORMAT_R16G16B16A16_SFLOAT: i32 = 97;
pub const FORMAT_R32G32B32A32_UINT: i32 = 107;
pub const FORMAT_R32G32B32A32_SINT: i32 = 108;
pub const FORMAT_R32G32B32A32_SFLOAT: i32 = 109;
pub const FORMAT_R32G32B32_UINT: i32 = 104;
pub const FORMAT_R32G32B32_SINT: i32 = 105;
pub const FORMAT_R32G32B32_SFLOAT: i32 = 106;
pub const FORMAT_D16_UNORM: i32 = 124;
pub const FORMAT_X8_D24_UNORM_PACK32: i32 = 125;
pub const FORMAT_D32_SFLOAT: i32 = 126;
pub const FORMAT_S8_UINT: i32 = 127;
pub const FORMAT_D24_UNORM_S8_UINT: i32 = 129;
pub const FORMAT_D32_SFLOAT_S8_UINT: i32 = 130;
pub const FORMAT_BC1_RGBA_UNORM_BLOCK: i32 = 133;
pub const FORMAT_BC1_RGBA_SRGB_BLOCK: i32 = 134;
pub const FORMAT_BC2_UNORM_BLOCK: i32 = 135;
pub const FORMAT_BC2_SRGB_BLOCK: i32 = 136;
pub const FORMAT_BC3_UNORM_BLOCK: i32 = 137;
pub const FORMAT_BC3_SRGB_BLOCK: i32 = 138;
pub const FORMAT_BC4_UNORM_BLOCK: i32 = 139;
pub const FORMAT_BC4_SNORM_BLOCK: i32 = 140;
pub const FORMAT_BC5_UNORM_BLOCK: i32 = 141;
pub const FORMAT_BC5_SNORM_BLOCK: i32 = 142;
pub const FORMAT_BC6H_UFLOAT_BLOCK: i32 = 143;
pub const FORMAT_BC6H_SFLOAT_BLOCK: i32 = 144;
pub const FORMAT_BC7_UNORM_BLOCK: i32 = 145;
pub const FORMAT_BC7_SRGB_BLOCK: i32 = 146;
pub const FORMAT_ETC2_R8G8B8_UNORM_BLOCK: i32 = 147;
pub const FORMAT_ETC2_R8G8B8_SRGB_BLOCK: i32 = 148;
pub const FORMAT_ETC2_R8G8B8A1_UNORM_BLOCK: i32 = 149;
pub const FORMAT_ETC2_R8G8B8A1_SRGB_BLOCK: i32 = 150;
pub const FORMAT_ETC2_R8G8B8A8_UNORM_BLOCK: i32 = 151;
pub const FORMAT_ETC2_R8G8B8A8_SRGB_BLOCK: i32 = 152;
pub const FORMAT_EAC_R11_UNORM_BLOCK: i32 = 153;
pub const FORMAT_EAC_R11_SNORM_BLOCK: i32 = 154;
pub const FORMAT_EAC_R11G11_UNORM_BLOCK: i32 = 155;
pub const FORMAT_EAC_R11G11_SNORM_BLOCK: i32 = 156;
pub const FORMAT_ASTC_4x4_UNORM_BLOCK: i32 = 157;
pub const FORMAT_ASTC_4x4_SRGB_BLOCK: i32 = 158;
pub const FORMAT_ASTC_5x4_UNORM_BLOCK: i32 = 159;
pub const FORMAT_ASTC_5x4_SRGB_BLOCK: i32 = 160;
pub const FORMAT_ASTC_5x5_UNORM_BLOCK: i32 = 161;
pub const FORMAT_ASTC_5x5_SRGB_BLOCK: i32 = 162;
pub const FORMAT_ASTC_6x5_UNORM_BLOCK: i32 = 163;
pub const FORMAT_ASTC_6x5_SRGB_BLOCK: i32 = 164;
pub const FORMAT_ASTC_6x6_UNORM_BLOCK: i32 = 165;
pub const FORMAT_ASTC_6x6_SRGB_BLOCK: i32 = 166;
pub const FORMAT_ASTC_8x5_UNORM_BLOCK: i32 = 167;
pub const FORMAT_ASTC_8x5_SRGB_BLOCK: i32 = 168;
pub const FORMAT_ASTC_8x6_UNORM_BLOCK: i32 = 169;
pub const FORMAT_ASTC_8x6_SRGB_BLOCK: i32 = 170;
pub const FORMAT_ASTC_8x8_UNORM_BLOCK: i32 = 171;
pub const FORMAT_ASTC_8x8_SRGB_BLOCK: i32 = 172;
pub const FORMAT_ASTC_10x5_UNORM_BLOCK: i32 = 173;
pub const FORMAT_ASTC_10x5_SRGB_BLOCK: i32 = 174;
pub const FORMAT_ASTC_10x6_UNORM_BLOCK: i32 = 175;
pub const FORMAT_ASTC_10x6_SRGB_BLOCK: i32 = 176;
pub const FORMAT_ASTC_10x8_UNORM_BLOCK: i32 = 177;
pub const FORMAT_ASTC_10x8_SRGB_BLOCK: i32 = 178;
pub const FORMAT_ASTC_10x10_UNORM_BLOCK: i32 = 179;
pub const FORMAT_ASTC_10x10_SRGB_BLOCK: i32 = 180;
pub const FORMAT_ASTC_12x10_UNORM_BLOCK: i32 = 181;
pub const FORMAT_ASTC_12x10_SRGB_BLOCK: i32 = 182;
pub const FORMAT_ASTC_12x12_UNORM_BLOCK: i32 = 183;
pub const FORMAT_ASTC_12x12_SRGB_BLOCK: i32 = 184;

pub const FORMAT_A2B10G10R10_SNORM_PACK32: i32 = 65;
pub const FORMAT_A2R10G10B10_UNORM_PACK32: i32 = 58;
pub const FORMAT_B10G11R11_UFLOAT_PACK32: i32 = 122;

// ---- additional
pub const IMAGE_LAYOUT_DEPTH_ATTACHMENT_OPTIMAL: i32 = 1000241000;
pub const IMAGE_LAYOUT_STENCIL_ATTACHMENT_OPTIMAL: i32 = 1000241002;
pub const RESOLVE_MODE_AVERAGE_BIT: u32 = 0x00000002;
pub const RESOLVE_MODE_NONE: u32 = 0;
pub const PIPELINE_CREATE_DESCRIPTOR_BUFFER_BIT_EXT: u32 = 0x20000000;
pub const PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT: u32 = 0x00000400;

// ---- sType values
pub const STRUCTURE_TYPE_SUBMIT_INFO: i32 = 4;
pub const STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO: i32 = 5;
pub const STRUCTURE_TYPE_FENCE_CREATE_INFO: i32 = 8;
pub const STRUCTURE_TYPE_BUFFER_CREATE_INFO: i32 = 12;
pub const STRUCTURE_TYPE_IMAGE_CREATE_INFO: i32 = 14;
pub const STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO: i32 = 15;
pub const STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO: i32 = 16;
pub const STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO: i32 = 18;
pub const STRUCTURE_TYPE_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO: i32 = 19;
pub const STRUCTURE_TYPE_PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO: i32 = 20;
pub const STRUCTURE_TYPE_PIPELINE_VIEWPORT_STATE_CREATE_INFO: i32 = 22;
pub const STRUCTURE_TYPE_PIPELINE_RASTERIZATION_STATE_CREATE_INFO: i32 = 23;
pub const STRUCTURE_TYPE_PIPELINE_MULTISAMPLE_STATE_CREATE_INFO: i32 = 24;
pub const STRUCTURE_TYPE_PIPELINE_DEPTH_STENCIL_STATE_CREATE_INFO: i32 = 25;
pub const STRUCTURE_TYPE_PIPELINE_COLOR_BLEND_STATE_CREATE_INFO: i32 = 26;
pub const STRUCTURE_TYPE_PIPELINE_DYNAMIC_STATE_CREATE_INFO: i32 = 27;
pub const STRUCTURE_TYPE_GRAPHICS_PIPELINE_CREATE_INFO: i32 = 28;
pub const STRUCTURE_TYPE_COMPUTE_PIPELINE_CREATE_INFO: i32 = 29;
pub const STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO: i32 = 30;
pub const STRUCTURE_TYPE_SAMPLER_CREATE_INFO: i32 = 31;
pub const STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO: i32 = 32;
pub const STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO: i32 = 39;
pub const STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO: i32 = 40;
pub const STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO: i32 = 42;
pub const STRUCTURE_TYPE_RENDERING_INFO: i32 = 1000044000;
pub const STRUCTURE_TYPE_RENDERING_ATTACHMENT_INFO: i32 = 1000044001;
pub const STRUCTURE_TYPE_PIPELINE_RENDERING_CREATE_INFO: i32 = 1000044002;
pub const STRUCTURE_TYPE_PHYSICAL_DEVICE_FEATURES_2: i32 = 1000059000;
pub const STRUCTURE_TYPE_PHYSICAL_DEVICE_PROPERTIES_2: i32 = 1000059001;
pub const STRUCTURE_TYPE_IMAGE_FORMAT_PROPERTIES_2: i32 = 1000059003;
pub const STRUCTURE_TYPE_PHYSICAL_DEVICE_IMAGE_FORMAT_INFO_2: i32 = 1000059004;
pub const STRUCTURE_TYPE_MEMORY_ALLOCATE_FLAGS_INFO: i32 = 1000060000;
pub const STRUCTURE_TYPE_DEBUG_UTILS_OBJECT_NAME_INFO_EXT: i32 = 1000128000;
pub const STRUCTURE_TYPE_DEBUG_UTILS_LABEL_EXT: i32 = 1000128002;
pub const STRUCTURE_TYPE_BUFFER_DEVICE_ADDRESS_INFO: i32 = 1000244001;
pub const STRUCTURE_TYPE_MEMORY_BARRIER_2: i32 = 1000314000;
pub const STRUCTURE_TYPE_BUFFER_MEMORY_BARRIER_2: i32 = 1000314001;
pub const STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER_2: i32 = 1000314002;
pub const STRUCTURE_TYPE_DEPENDENCY_INFO: i32 = 1000314003;
pub const STRUCTURE_TYPE_PHYSICAL_DEVICE_DESCRIPTOR_BUFFER_PROPERTIES_EXT: i32 = 1000316000;
pub const STRUCTURE_TYPE_DESCRIPTOR_ADDRESS_INFO_EXT: i32 = 1000316003;
pub const STRUCTURE_TYPE_DESCRIPTOR_GET_INFO_EXT: i32 = 1000316004;
pub const STRUCTURE_TYPE_DESCRIPTOR_BUFFER_BINDING_INFO_EXT: i32 = 1000316011;
pub const STRUCTURE_TYPE_COPY_BUFFER_TO_IMAGE_INFO_2: i32 = 1000337002;
pub const STRUCTURE_TYPE_BUFFER_IMAGE_COPY_2: i32 = 1000337009;

// ---------------------------------------------------------------- structs
pub const BufferCreateInfo = extern struct {
    sType: i32 = 0,
    pNext: ?*const anyopaque = null,
    flags: u32 = 0,
    size: u64 = 0,
    usage: u32 = 0,
    sharingMode: i32 = 0,
    queueFamilyIndexCount: u32 = 0,
    pQueueFamilyIndices: ?*const u32 = null,
};
pub const BufferDeviceAddressInfo = extern struct {
    sType: i32 = 0,
    pNext: ?*const anyopaque = null,
    buffer: u64 = 0,
};
pub const MemoryRequirements = extern struct {
    size: u64 = 0,
    alignment: u64 = 0,
    memoryTypeBits: u32 = 0,
};
pub const MemoryAllocateFlagsInfo = extern struct {
    sType: i32 = 0,
    pNext: ?*const anyopaque = null,
    flags: u32 = 0,
    deviceMask: u32 = 0,
};
pub const MemoryAllocateInfo = extern struct {
    sType: i32 = 0,
    pNext: ?*const anyopaque = null,
    allocationSize: u64 = 0,
    memoryTypeIndex: u32 = 0,
};
pub const PhysicalDeviceMemoryProperties = extern struct {
    memoryTypeCount: u32 = 0,
    memoryTypes: [32]MemoryType = std.mem.zeroes([32]MemoryType),
    memoryHeapCount: u32 = 0,
    memoryHeaps: [16]MemoryHeap = std.mem.zeroes([16]MemoryHeap),
};
pub const CommandPoolCreateInfo = extern struct {
    sType: i32 = 0,
    pNext: ?*const anyopaque = null,
    flags: u32 = 0,
    queueFamilyIndex: u32 = 0,
};
pub const CommandBufferAllocateInfo = extern struct {
    sType: i32 = 0,
    pNext: ?*const anyopaque = null,
    commandPool: u64 = 0,
    level: i32 = 0,
    commandBufferCount: u32 = 0,
};
pub const CommandBufferBeginInfo = extern struct {
    sType: i32 = 0,
    pNext: ?*const anyopaque = null,
    flags: u32 = 0,
    pInheritanceInfo: ?*const CommandBufferInheritanceInfo = null,
};
pub const SubmitInfo = extern struct {
    sType: i32 = 0,
    pNext: ?*const anyopaque = null,
    waitSemaphoreCount: u32 = 0,
    pWaitSemaphores: ?*const u64 = null,
    pWaitDstStageMask: ?*const u32 = null,
    commandBufferCount: u32 = 0,
    pCommandBuffers: ?*const ?*anyopaque = null,
    signalSemaphoreCount: u32 = 0,
    pSignalSemaphores: ?*const u64 = null,
};
pub const BufferCopy = extern struct {
    srcOffset: u64 = 0,
    dstOffset: u64 = 0,
    size: u64 = 0,
};
pub const BufferImageCopy2 = extern struct {
    sType: i32 = 0,
    pNext: ?*const anyopaque = null,
    bufferOffset: u64 = 0,
    bufferRowLength: u32 = 0,
    bufferImageHeight: u32 = 0,
    imageSubresource: ImageSubresourceLayers = std.mem.zeroes(ImageSubresourceLayers),
    imageOffset: Offset3D = std.mem.zeroes(Offset3D),
    imageExtent: Extent3D = std.mem.zeroes(Extent3D),
};
pub const CopyBufferToImageInfo2 = extern struct {
    sType: i32 = 0,
    pNext: ?*const anyopaque = null,
    srcBuffer: u64 = 0,
    dstImage: u64 = 0,
    dstImageLayout: i32 = 0,
    regionCount: u32 = 0,
    pRegions: ?*const BufferImageCopy2 = null,
};
pub const DescriptorBufferBindingInfoEXT = extern struct {
    sType: i32 = 0,
    pNext: ?*const anyopaque = null,
    address: u64 = 0,
    usage: u32 = 0,
};
pub const DescriptorAddressInfoEXT = extern struct {
    sType: i32 = 0,
    pNext: ?*anyopaque = null,
    address: u64 = 0,
    range: u64 = 0,
    format: i32 = 0,
};
pub const DescriptorSetLayoutBinding = extern struct {
    binding: u32 = 0,
    descriptorType: i32 = 0,
    descriptorCount: u32 = 0,
    stageFlags: u32 = 0,
    pImmutableSamplers: ?*const u64 = null,
};
pub const DescriptorSetLayoutCreateInfo = extern struct {
    sType: i32 = 0,
    pNext: ?*const anyopaque = null,
    flags: u32 = 0,
    bindingCount: u32 = 0,
    pBindings: ?*const DescriptorSetLayoutBinding = null,
};
pub const PipelineLayoutCreateInfo = extern struct {
    sType: i32 = 0,
    pNext: ?*const anyopaque = null,
    flags: u32 = 0,
    setLayoutCount: u32 = 0,
    pSetLayouts: ?*const u64 = null,
    pushConstantRangeCount: u32 = 0,
    pPushConstantRanges: ?*const PushConstantRange = null,
};
pub const ShaderModuleCreateInfo = extern struct {
    sType: i32 = 0,
    pNext: ?*const anyopaque = null,
    flags: u32 = 0,
    codeSize: usize = 0,
    pCode: ?*const u32 = null,
};
pub const SamplerCreateInfo = extern struct {
    sType: i32 = 0,
    pNext: ?*const anyopaque = null,
    flags: u32 = 0,
    magFilter: i32 = 0,
    minFilter: i32 = 0,
    mipmapMode: i32 = 0,
    addressModeU: i32 = 0,
    addressModeV: i32 = 0,
    addressModeW: i32 = 0,
    mipLodBias: f32 = 0,
    anisotropyEnable: u32 = 0,
    maxAnisotropy: f32 = 0,
    compareEnable: u32 = 0,
    compareOp: i32 = 0,
    minLod: f32 = 0,
    maxLod: f32 = 0,
    borderColor: i32 = 0,
    unnormalizedCoordinates: u32 = 0,
};
pub const ImageCreateInfo = extern struct {
    sType: i32 = 0,
    pNext: ?*const anyopaque = null,
    flags: u32 = 0,
    imageType: i32 = 0,
    format: i32 = 0,
    extent: Extent3D = std.mem.zeroes(Extent3D),
    mipLevels: u32 = 0,
    arrayLayers: u32 = 0,
    samples: i32 = 0,
    tiling: i32 = 0,
    usage: u32 = 0,
    sharingMode: i32 = 0,
    queueFamilyIndexCount: u32 = 0,
    pQueueFamilyIndices: ?*const u32 = null,
    initialLayout: i32 = 0,
};
pub const ImageViewCreateInfo = extern struct {
    sType: i32 = 0,
    pNext: ?*const anyopaque = null,
    flags: u32 = 0,
    image: u64 = 0,
    viewType: i32 = 0,
    format: i32 = 0,
    components: ComponentMapping = std.mem.zeroes(ComponentMapping),
    subresourceRange: ImageSubresourceRange = std.mem.zeroes(ImageSubresourceRange),
};
pub const FenceCreateInfo = extern struct {
    sType: i32 = 0,
    pNext: ?*const anyopaque = null,
    flags: u32 = 0,
};
pub const ImageMemoryBarrier2 = extern struct {
    sType: i32 = 0,
    pNext: ?*const anyopaque = null,
    srcStageMask: u64 = 0,
    srcAccessMask: u64 = 0,
    dstStageMask: u64 = 0,
    dstAccessMask: u64 = 0,
    oldLayout: i32 = 0,
    newLayout: i32 = 0,
    srcQueueFamilyIndex: u32 = 0,
    dstQueueFamilyIndex: u32 = 0,
    image: u64 = 0,
    subresourceRange: ImageSubresourceRange = std.mem.zeroes(ImageSubresourceRange),
};
pub const BufferMemoryBarrier2 = extern struct {
    sType: i32 = 0,
    pNext: ?*const anyopaque = null,
    srcStageMask: u64 = 0,
    srcAccessMask: u64 = 0,
    dstStageMask: u64 = 0,
    dstAccessMask: u64 = 0,
    srcQueueFamilyIndex: u32 = 0,
    dstQueueFamilyIndex: u32 = 0,
    buffer: u64 = 0,
    offset: u64 = 0,
    size: u64 = 0,
};
pub const MemoryBarrier2 = extern struct {
    sType: i32 = 0,
    pNext: ?*const anyopaque = null,
    srcStageMask: u64 = 0,
    srcAccessMask: u64 = 0,
    dstStageMask: u64 = 0,
    dstAccessMask: u64 = 0,
};
pub const DependencyInfo = extern struct {
    sType: i32 = 0,
    pNext: ?*const anyopaque = null,
    dependencyFlags: u32 = 0,
    memoryBarrierCount: u32 = 0,
    pMemoryBarriers: ?*const MemoryBarrier2 = null,
    bufferMemoryBarrierCount: u32 = 0,
    pBufferMemoryBarriers: ?*const BufferMemoryBarrier2 = null,
    imageMemoryBarrierCount: u32 = 0,
    pImageMemoryBarriers: ?*const ImageMemoryBarrier2 = null,
};
pub const RenderingInfo = extern struct {
    sType: i32 = 0,
    pNext: ?*const anyopaque = null,
    flags: u32 = 0,
    renderArea: Rect2D = std.mem.zeroes(Rect2D),
    layerCount: u32 = 0,
    viewMask: u32 = 0,
    colorAttachmentCount: u32 = 0,
    pColorAttachments: ?*const RenderingAttachmentInfo = null,
    pDepthAttachment: ?*const RenderingAttachmentInfo = null,
    pStencilAttachment: ?*const RenderingAttachmentInfo = null,
};
pub const PhysicalDeviceProperties2 = extern struct {
    sType: i32 = 0,
    pNext: ?*anyopaque = null,
    properties: PhysicalDeviceProperties = std.mem.zeroes(PhysicalDeviceProperties),
};
pub const PhysicalDeviceFeatures2 = extern struct {
    sType: i32 = 0,
    pNext: ?*anyopaque = null,
    features: PhysicalDeviceFeatures = std.mem.zeroes(PhysicalDeviceFeatures),
};
pub const PhysicalDeviceImageFormatInfo2 = extern struct {
    sType: i32 = 0,
    pNext: ?*const anyopaque = null,
    format: i32 = 0,
    type: i32 = 0,
    tiling: i32 = 0,
    usage: u32 = 0,
    flags: u32 = 0,
};
pub const FormatProperties = extern struct {
    linearTilingFeatures: u32 = 0,
    optimalTilingFeatures: u32 = 0,
    bufferFeatures: u32 = 0,
};
pub const PipelineShaderStageCreateInfo = extern struct {
    sType: i32 = 0,
    pNext: ?*const anyopaque = null,
    flags: u32 = 0,
    stage: i32 = 0,
    module: u64 = 0,
    pName: ?[*:0]const u8 = null,
    pSpecializationInfo: ?*const SpecializationInfo = null,
};
pub const GraphicsPipelineCreateInfo = extern struct {
    sType: i32 = 0,
    pNext: ?*const anyopaque = null,
    flags: u32 = 0,
    stageCount: u32 = 0,
    pStages: ?*const PipelineShaderStageCreateInfo = null,
    pVertexInputState: ?*const PipelineVertexInputStateCreateInfo = null,
    pInputAssemblyState: ?*const PipelineInputAssemblyStateCreateInfo = null,
    pTessellationState: ?*const PipelineTessellationStateCreateInfo = null,
    pViewportState: ?*const PipelineViewportStateCreateInfo = null,
    pRasterizationState: ?*const PipelineRasterizationStateCreateInfo = null,
    pMultisampleState: ?*const PipelineMultisampleStateCreateInfo = null,
    pDepthStencilState: ?*const PipelineDepthStencilStateCreateInfo = null,
    pColorBlendState: ?*const PipelineColorBlendStateCreateInfo = null,
    pDynamicState: ?*const PipelineDynamicStateCreateInfo = null,
    layout: u64 = 0,
    renderPass: u64 = 0,
    subpass: u32 = 0,
    basePipelineHandle: u64 = 0,
    basePipelineIndex: i32 = 0,
};
pub const ComputePipelineCreateInfo = extern struct {
    sType: i32 = 0,
    pNext: ?*const anyopaque = null,
    flags: u32 = 0,
    stage: PipelineShaderStageCreateInfo = std.mem.zeroes(PipelineShaderStageCreateInfo),
    layout: u64 = 0,
    basePipelineHandle: u64 = 0,
    basePipelineIndex: i32 = 0,
};
pub const PipelineVertexInputStateCreateInfo = extern struct {
    sType: i32 = 0,
    pNext: ?*const anyopaque = null,
    flags: u32 = 0,
    vertexBindingDescriptionCount: u32 = 0,
    pVertexBindingDescriptions: ?*const VertexInputBindingDescription = null,
    vertexAttributeDescriptionCount: u32 = 0,
    pVertexAttributeDescriptions: ?*const VertexInputAttributeDescription = null,
};
pub const VertexInputBindingDescription = extern struct {
    binding: u32 = 0,
    stride: u32 = 0,
    inputRate: i32 = 0,
};
pub const VertexInputAttributeDescription = extern struct {
    location: u32 = 0,
    binding: u32 = 0,
    format: i32 = 0,
    offset: u32 = 0,
};
pub const PipelineInputAssemblyStateCreateInfo = extern struct {
    sType: i32 = 0,
    pNext: ?*const anyopaque = null,
    flags: u32 = 0,
    topology: i32 = 0,
    primitiveRestartEnable: u32 = 0,
};
pub const PipelineViewportStateCreateInfo = extern struct {
    sType: i32 = 0,
    pNext: ?*const anyopaque = null,
    flags: u32 = 0,
    viewportCount: u32 = 0,
    pViewports: ?*const Viewport = null,
    scissorCount: u32 = 0,
    pScissors: ?*const Rect2D = null,
};
pub const PipelineRasterizationStateCreateInfo = extern struct {
    sType: i32 = 0,
    pNext: ?*const anyopaque = null,
    flags: u32 = 0,
    depthClampEnable: u32 = 0,
    rasterizerDiscardEnable: u32 = 0,
    polygonMode: i32 = 0,
    cullMode: u32 = 0,
    frontFace: i32 = 0,
    depthBiasEnable: u32 = 0,
    depthBiasConstantFactor: f32 = 0,
    depthBiasClamp: f32 = 0,
    depthBiasSlopeFactor: f32 = 0,
    lineWidth: f32 = 0,
};
pub const PipelineMultisampleStateCreateInfo = extern struct {
    sType: i32 = 0,
    pNext: ?*const anyopaque = null,
    flags: u32 = 0,
    rasterizationSamples: i32 = 0,
    sampleShadingEnable: u32 = 0,
    minSampleShading: f32 = 0,
    pSampleMask: ?*const u32 = null,
    alphaToCoverageEnable: u32 = 0,
    alphaToOneEnable: u32 = 0,
};
pub const PipelineDepthStencilStateCreateInfo = extern struct {
    sType: i32 = 0,
    pNext: ?*const anyopaque = null,
    flags: u32 = 0,
    depthTestEnable: u32 = 0,
    depthWriteEnable: u32 = 0,
    depthCompareOp: i32 = 0,
    depthBoundsTestEnable: u32 = 0,
    stencilTestEnable: u32 = 0,
    front: StencilOpState = std.mem.zeroes(StencilOpState),
    back: StencilOpState = std.mem.zeroes(StencilOpState),
    minDepthBounds: f32 = 0,
    maxDepthBounds: f32 = 0,
};
pub const StencilOpState = extern struct {
    failOp: i32 = 0,
    passOp: i32 = 0,
    depthFailOp: i32 = 0,
    compareOp: i32 = 0,
    compareMask: u32 = 0,
    writeMask: u32 = 0,
    reference: u32 = 0,
};
pub const PipelineColorBlendStateCreateInfo = extern struct {
    sType: i32 = 0,
    pNext: ?*const anyopaque = null,
    flags: u32 = 0,
    logicOpEnable: u32 = 0,
    logicOp: i32 = 0,
    attachmentCount: u32 = 0,
    pAttachments: ?*const PipelineColorBlendAttachmentState = null,
    blendConstants: [4]f32 = std.mem.zeroes([4]f32),
};
pub const PipelineColorBlendAttachmentState = extern struct {
    blendEnable: u32 = 0,
    srcColorBlendFactor: i32 = 0,
    dstColorBlendFactor: i32 = 0,
    colorBlendOp: i32 = 0,
    srcAlphaBlendFactor: i32 = 0,
    dstAlphaBlendFactor: i32 = 0,
    alphaBlendOp: i32 = 0,
    colorWriteMask: u32 = 0,
};
pub const PipelineDynamicStateCreateInfo = extern struct {
    sType: i32 = 0,
    pNext: ?*const anyopaque = null,
    flags: u32 = 0,
    dynamicStateCount: u32 = 0,
    pDynamicStates: ?*const i32 = null,
};
pub const PipelineRenderingCreateInfo = extern struct {
    sType: i32 = 0,
    pNext: ?*const anyopaque = null,
    viewMask: u32 = 0,
    colorAttachmentCount: u32 = 0,
    pColorAttachmentFormats: ?*const i32 = null,
    depthAttachmentFormat: i32 = 0,
    stencilAttachmentFormat: i32 = 0,
};
pub const Viewport = extern struct {
    x: f32 = 0,
    y: f32 = 0,
    width: f32 = 0,
    height: f32 = 0,
    minDepth: f32 = 0,
    maxDepth: f32 = 0,
};
pub const Rect2D = extern struct {
    offset: Offset2D = std.mem.zeroes(Offset2D),
    extent: Extent2D = std.mem.zeroes(Extent2D),
};
pub const PhysicalDeviceDescriptorBufferPropertiesEXT = extern struct {
    sType: i32 = 0,
    pNext: ?*anyopaque = null,
    combinedImageSamplerDescriptorSingleArray: u32 = 0,
    bufferlessPushDescriptors: u32 = 0,
    allowSamplerImageViewPostSubmitCreation: u32 = 0,
    descriptorBufferOffsetAlignment: u64 = 0,
    maxDescriptorBufferBindings: u32 = 0,
    maxResourceDescriptorBufferBindings: u32 = 0,
    maxSamplerDescriptorBufferBindings: u32 = 0,
    maxEmbeddedImmutableSamplerBindings: u32 = 0,
    maxEmbeddedImmutableSamplers: u32 = 0,
    bufferCaptureReplayDescriptorDataSize: usize = 0,
    imageCaptureReplayDescriptorDataSize: usize = 0,
    imageViewCaptureReplayDescriptorDataSize: usize = 0,
    samplerCaptureReplayDescriptorDataSize: usize = 0,
    accelerationStructureCaptureReplayDescriptorDataSize: usize = 0,
    samplerDescriptorSize: usize = 0,
    combinedImageSamplerDescriptorSize: usize = 0,
    sampledImageDescriptorSize: usize = 0,
    storageImageDescriptorSize: usize = 0,
    uniformTexelBufferDescriptorSize: usize = 0,
    robustUniformTexelBufferDescriptorSize: usize = 0,
    storageTexelBufferDescriptorSize: usize = 0,
    robustStorageTexelBufferDescriptorSize: usize = 0,
    uniformBufferDescriptorSize: usize = 0,
    robustUniformBufferDescriptorSize: usize = 0,
    storageBufferDescriptorSize: usize = 0,
    robustStorageBufferDescriptorSize: usize = 0,
    inputAttachmentDescriptorSize: usize = 0,
    accelerationStructureDescriptorSize: usize = 0,
    maxSamplerDescriptorBufferRange: u64 = 0,
    maxResourceDescriptorBufferRange: u64 = 0,
    samplerDescriptorBufferAddressSpaceSize: u64 = 0,
    resourceDescriptorBufferAddressSpaceSize: u64 = 0,
    descriptorBufferAddressSpaceSize: u64 = 0,
};
pub const PhysicalDeviceFeatures = extern struct {
    robustBufferAccess: u32 = 0,
    fullDrawIndexUint32: u32 = 0,
    imageCubeArray: u32 = 0,
    independentBlend: u32 = 0,
    geometryShader: u32 = 0,
    tessellationShader: u32 = 0,
    sampleRateShading: u32 = 0,
    dualSrcBlend: u32 = 0,
    logicOp: u32 = 0,
    multiDrawIndirect: u32 = 0,
    drawIndirectFirstInstance: u32 = 0,
    depthClamp: u32 = 0,
    depthBiasClamp: u32 = 0,
    fillModeNonSolid: u32 = 0,
    depthBounds: u32 = 0,
    wideLines: u32 = 0,
    largePoints: u32 = 0,
    alphaToOne: u32 = 0,
    multiViewport: u32 = 0,
    samplerAnisotropy: u32 = 0,
    textureCompressionETC2: u32 = 0,
    textureCompressionASTC_LDR: u32 = 0,
    textureCompressionBC: u32 = 0,
    occlusionQueryPrecise: u32 = 0,
    pipelineStatisticsQuery: u32 = 0,
    vertexPipelineStoresAndAtomics: u32 = 0,
    fragmentStoresAndAtomics: u32 = 0,
    shaderTessellationAndGeometryPointSize: u32 = 0,
    shaderImageGatherExtended: u32 = 0,
    shaderStorageImageExtendedFormats: u32 = 0,
    shaderStorageImageMultisample: u32 = 0,
    shaderStorageImageReadWithoutFormat: u32 = 0,
    shaderStorageImageWriteWithoutFormat: u32 = 0,
    shaderUniformBufferArrayDynamicIndexing: u32 = 0,
    shaderSampledImageArrayDynamicIndexing: u32 = 0,
    shaderStorageBufferArrayDynamicIndexing: u32 = 0,
    shaderStorageImageArrayDynamicIndexing: u32 = 0,
    shaderClipDistance: u32 = 0,
    shaderCullDistance: u32 = 0,
    shaderFloat64: u32 = 0,
    shaderInt64: u32 = 0,
    shaderInt16: u32 = 0,
    shaderResourceResidency: u32 = 0,
    shaderResourceMinLod: u32 = 0,
    sparseBinding: u32 = 0,
    sparseResidencyBuffer: u32 = 0,
    sparseResidencyImage2D: u32 = 0,
    sparseResidencyImage3D: u32 = 0,
    sparseResidency2Samples: u32 = 0,
    sparseResidency4Samples: u32 = 0,
    sparseResidency8Samples: u32 = 0,
    sparseResidency16Samples: u32 = 0,
    sparseResidencyAliased: u32 = 0,
    variableMultisampleRate: u32 = 0,
    inheritedQueries: u32 = 0,
};
pub const Offset2D = extern struct {
    x: i32 = 0,
    y: i32 = 0,
};
pub const Offset3D = extern struct {
    x: i32 = 0,
    y: i32 = 0,
    z: i32 = 0,
};
pub const Extent2D = extern struct {
    width: u32 = 0,
    height: u32 = 0,
};
pub const Extent3D = extern struct {
    width: u32 = 0,
    height: u32 = 0,
    depth: u32 = 0,
};
pub const ComponentMapping = extern struct {
    r: i32 = 0,
    g: i32 = 0,
    b: i32 = 0,
    a: i32 = 0,
};
pub const ImageSubresourceRange = extern struct {
    aspectMask: u32 = 0,
    baseMipLevel: u32 = 0,
    levelCount: u32 = 0,
    baseArrayLayer: u32 = 0,
    layerCount: u32 = 0,
};
pub const ImageSubresourceLayers = extern struct {
    aspectMask: u32 = 0,
    mipLevel: u32 = 0,
    baseArrayLayer: u32 = 0,
    layerCount: u32 = 0,
};
pub const BufferImageCopy = extern struct {
    bufferOffset: u64 = 0,
    bufferRowLength: u32 = 0,
    bufferImageHeight: u32 = 0,
    imageSubresource: ImageSubresourceLayers = std.mem.zeroes(ImageSubresourceLayers),
    imageOffset: Offset3D = std.mem.zeroes(Offset3D),
    imageExtent: Extent3D = std.mem.zeroes(Extent3D),
};
pub const ImageMemoryBarrier = extern struct {
    sType: i32 = 0,
    pNext: ?*const anyopaque = null,
    srcAccessMask: u32 = 0,
    dstAccessMask: u32 = 0,
    oldLayout: i32 = 0,
    newLayout: i32 = 0,
    srcQueueFamilyIndex: u32 = 0,
    dstQueueFamilyIndex: u32 = 0,
    image: u64 = 0,
    subresourceRange: ImageSubresourceRange = std.mem.zeroes(ImageSubresourceRange),
};
pub const MemoryBarrier = extern struct {
    sType: i32 = 0,
    pNext: ?*const anyopaque = null,
    srcAccessMask: u32 = 0,
    dstAccessMask: u32 = 0,
};
pub const BufferMemoryBarrier = extern struct {
    sType: i32 = 0,
    pNext: ?*const anyopaque = null,
    srcAccessMask: u32 = 0,
    dstAccessMask: u32 = 0,
    srcQueueFamilyIndex: u32 = 0,
    dstQueueFamilyIndex: u32 = 0,
    buffer: u64 = 0,
    offset: u64 = 0,
    size: u64 = 0,
};
pub const DescriptorBufferInfo = extern struct {
    buffer: u64 = 0,
    offset: u64 = 0,
    range: u64 = 0,
};
pub const ImageCopy = extern struct {
    srcSubresource: ImageSubresourceLayers = std.mem.zeroes(ImageSubresourceLayers),
    srcOffset: Offset3D = std.mem.zeroes(Offset3D),
    dstSubresource: ImageSubresourceLayers = std.mem.zeroes(ImageSubresourceLayers),
    dstOffset: Offset3D = std.mem.zeroes(Offset3D),
    extent: Extent3D = std.mem.zeroes(Extent3D),
};

pub const DebugUtilsLabelEXT = extern struct {
    sType: i32 = 0,
    pNext: ?*const anyopaque = null,
    pLabelName: ?[*:0]const u8 = null,
    color: [4]f32 = std.mem.zeroes([4]f32),
};
pub const DebugUtilsObjectNameInfoEXT = extern struct {
    sType: i32 = 0,
    pNext: ?*const anyopaque = null,
    objectType: i32 = 0,
    objectHandle: u64 = 0,
    pObjectName: ?[*:0]const u8 = null,
};
pub const ImageFormatProperties2 = extern struct {
    sType: i32 = 0,
    pNext: ?*anyopaque = null,
    imageFormatProperties: ImageFormatProperties = std.mem.zeroes(ImageFormatProperties),
};
pub const ImageFormatProperties = extern struct {
    maxExtent: Extent3D = std.mem.zeroes(Extent3D),
    maxMipLevels: u32 = 0,
    maxArrayLayers: u32 = 0,
    sampleCounts: u32 = 0,
    maxResourceSize: u64 = 0,
};
pub const PhysicalDeviceProperties = extern struct {
    apiVersion: u32 = 0,
    driverVersion: u32 = 0,
    vendorID: u32 = 0,
    deviceID: u32 = 0,
    deviceType: i32 = 0,
    deviceName: [256]u8 = std.mem.zeroes([256]u8),
    pipelineCacheUUID: [16]u8 = std.mem.zeroes([16]u8),
    limits: PhysicalDeviceLimits = std.mem.zeroes(PhysicalDeviceLimits),
    sparseProperties: PhysicalDeviceSparseProperties = std.mem.zeroes(PhysicalDeviceSparseProperties),
};
pub const PhysicalDeviceLimits = extern struct {
    maxImageDimension1D: u32 = 0,
    maxImageDimension2D: u32 = 0,
    maxImageDimension3D: u32 = 0,
    maxImageDimensionCube: u32 = 0,
    maxImageArrayLayers: u32 = 0,
    maxTexelBufferElements: u32 = 0,
    maxUniformBufferRange: u32 = 0,
    maxStorageBufferRange: u32 = 0,
    maxPushConstantsSize: u32 = 0,
    maxMemoryAllocationCount: u32 = 0,
    maxSamplerAllocationCount: u32 = 0,
    bufferImageGranularity: u64 = 0,
    sparseAddressSpaceSize: u64 = 0,
    maxBoundDescriptorSets: u32 = 0,
    maxPerStageDescriptorSamplers: u32 = 0,
    maxPerStageDescriptorUniformBuffers: u32 = 0,
    maxPerStageDescriptorStorageBuffers: u32 = 0,
    maxPerStageDescriptorSampledImages: u32 = 0,
    maxPerStageDescriptorStorageImages: u32 = 0,
    maxPerStageDescriptorInputAttachments: u32 = 0,
    maxPerStageResources: u32 = 0,
    maxDescriptorSetSamplers: u32 = 0,
    maxDescriptorSetUniformBuffers: u32 = 0,
    maxDescriptorSetUniformBuffersDynamic: u32 = 0,
    maxDescriptorSetStorageBuffers: u32 = 0,
    maxDescriptorSetStorageBuffersDynamic: u32 = 0,
    maxDescriptorSetSampledImages: u32 = 0,
    maxDescriptorSetStorageImages: u32 = 0,
    maxDescriptorSetInputAttachments: u32 = 0,
    maxVertexInputAttributes: u32 = 0,
    maxVertexInputBindings: u32 = 0,
    maxVertexInputAttributeOffset: u32 = 0,
    maxVertexInputBindingStride: u32 = 0,
    maxVertexOutputComponents: u32 = 0,
    maxTessellationGenerationLevel: u32 = 0,
    maxTessellationPatchSize: u32 = 0,
    maxTessellationControlPerVertexInputComponents: u32 = 0,
    maxTessellationControlPerVertexOutputComponents: u32 = 0,
    maxTessellationControlPerPatchOutputComponents: u32 = 0,
    maxTessellationControlTotalOutputComponents: u32 = 0,
    maxTessellationEvaluationInputComponents: u32 = 0,
    maxTessellationEvaluationOutputComponents: u32 = 0,
    maxGeometryShaderInvocations: u32 = 0,
    maxGeometryInputComponents: u32 = 0,
    maxGeometryOutputComponents: u32 = 0,
    maxGeometryOutputVertices: u32 = 0,
    maxGeometryTotalOutputComponents: u32 = 0,
    maxFragmentInputComponents: u32 = 0,
    maxFragmentOutputAttachments: u32 = 0,
    maxFragmentDualSrcAttachments: u32 = 0,
    maxFragmentCombinedOutputResources: u32 = 0,
    maxComputeSharedMemorySize: u32 = 0,
    maxComputeWorkGroupCount: [3]u32 = std.mem.zeroes([3]u32),
    maxComputeWorkGroupInvocations: u32 = 0,
    maxComputeWorkGroupSize: [3]u32 = std.mem.zeroes([3]u32),
    subPixelPrecisionBits: u32 = 0,
    subTexelPrecisionBits: u32 = 0,
    mipmapPrecisionBits: u32 = 0,
    maxDrawIndexedIndexValue: u32 = 0,
    maxDrawIndirectCount: u32 = 0,
    maxSamplerLodBias: f32 = 0,
    maxSamplerAnisotropy: f32 = 0,
    maxViewports: u32 = 0,
    maxViewportDimensions: [2]u32 = std.mem.zeroes([2]u32),
    viewportBoundsRange: [2]f32 = std.mem.zeroes([2]f32),
    viewportSubPixelBits: u32 = 0,
    minMemoryMapAlignment: usize = 0,
    minTexelBufferOffsetAlignment: u64 = 0,
    minUniformBufferOffsetAlignment: u64 = 0,
    minStorageBufferOffsetAlignment: u64 = 0,
    minTexelOffset: i32 = 0,
    maxTexelOffset: u32 = 0,
    minTexelGatherOffset: i32 = 0,
    maxTexelGatherOffset: u32 = 0,
    minInterpolationOffset: f32 = 0,
    maxInterpolationOffset: f32 = 0,
    subPixelInterpolationOffsetBits: u32 = 0,
    maxFramebufferWidth: u32 = 0,
    maxFramebufferHeight: u32 = 0,
    maxFramebufferLayers: u32 = 0,
    framebufferColorSampleCounts: u32 = 0,
    framebufferDepthSampleCounts: u32 = 0,
    framebufferStencilSampleCounts: u32 = 0,
    framebufferNoAttachmentsSampleCounts: u32 = 0,
    maxColorAttachments: u32 = 0,
    sampledImageColorSampleCounts: u32 = 0,
    sampledImageIntegerSampleCounts: u32 = 0,
    sampledImageDepthSampleCounts: u32 = 0,
    sampledImageStencilSampleCounts: u32 = 0,
    storageImageSampleCounts: u32 = 0,
    maxSampleMaskWords: u32 = 0,
    timestampComputeAndGraphics: u32 = 0,
    timestampPeriod: f32 = 0,
    maxClipDistances: u32 = 0,
    maxCullDistances: u32 = 0,
    maxCombinedClipAndCullDistances: u32 = 0,
    discreteQueuePriorities: u32 = 0,
    pointSizeRange: [2]f32 = std.mem.zeroes([2]f32),
    lineWidthRange: [2]f32 = std.mem.zeroes([2]f32),
    pointSizeGranularity: f32 = 0,
    lineWidthGranularity: f32 = 0,
    strictLines: u32 = 0,
    standardSampleLocations: u32 = 0,
    optimalBufferCopyOffsetAlignment: u64 = 0,
    optimalBufferCopyRowPitchAlignment: u64 = 0,
    nonCoherentAtomSize: u64 = 0,
};
pub const PhysicalDeviceSparseProperties = extern struct {
    residencyStandard2DBlockShape: u32 = 0,
    residencyStandard2DMultisampleBlockShape: u32 = 0,
    residencyStandard3DBlockShape: u32 = 0,
    residencyAlignedMipSize: u32 = 0,
    residencyNonResidentStrict: u32 = 0,
};
pub const MemoryType = extern struct {
    propertyFlags: u32 = 0,
    heapIndex: u32 = 0,
};
pub const MemoryHeap = extern struct {
    size: u64 = 0,
    flags: u32 = 0,
};

pub const DescriptorImageInfo = extern struct {
    sampler: u64 = 0,
    imageView: u64 = 0,
    imageLayout: i32 = 0,
};
pub const PipelineTessellationStateCreateInfo = extern struct {
    sType: i32 = 0,
    pNext: ?*const anyopaque = null,
    flags: u32 = 0,
    patchControlPoints: u32 = 0,
};

pub const CommandBufferInheritanceInfo = extern struct {
    sType: i32 = 0,
    pNext: ?*const anyopaque = null,
    renderPass: u64 = 0,
    subpass: u32 = 0,
    framebuffer: u64 = 0,
    occlusionQueryEnable: u32 = 0,
    queryFlags: u32 = 0,
    pipelineStatistics: u32 = 0,
};
pub const SpecializationInfo = extern struct {
    mapEntryCount: u32 = 0,
    pMapEntries: ?*const SpecializationMapEntry = null,
    dataSize: usize = 0,
    pData: ?*const anyopaque = null,
};
pub const SpecializationMapEntry = extern struct {
    constantID: u32 = 0,
    offset: u32 = 0,
    size: usize = 0,
};

// ---------------------------------------------------------------- entry points

pub const GetProcAddr = *const anyopaque;

/// Instance-level entry points, resolved with `vkGetInstanceProcAddr(instance, name)`.
pub const InstanceFns = struct {
    vkGetPhysicalDeviceMemoryProperties: *const fn (PhysicalDevice, *PhysicalDeviceMemoryProperties) callconv(.c) void = undefined,
    vkGetPhysicalDeviceProperties2: *const fn (PhysicalDevice, *PhysicalDeviceProperties2) callconv(.c) void = undefined,
    vkGetPhysicalDeviceFeatures2: *const fn (PhysicalDevice, *PhysicalDeviceFeatures2) callconv(.c) void = undefined,
    vkGetPhysicalDeviceFormatProperties: *const fn (PhysicalDevice, i32, *FormatProperties) callconv(.c) void = undefined,
    vkGetPhysicalDeviceImageFormatProperties2: *const fn (PhysicalDevice, *const PhysicalDeviceImageFormatInfo2, *ImageFormatProperties2) callconv(.c) i32 = undefined,
};

/// Device-level entry points, resolved with `vkGetDeviceProcAddr(device, name)`.
/// Optional fields belong to extensions and may be absent.
pub const DeviceFns = struct {
    vkGetFenceStatus: *const fn (Device, Fence) callconv(.c) i32 = undefined,
    vkCreatePipelineCache: *const fn (Device, *const PipelineCacheCreateInfo, ?*const AllocationCallbacks, *PipelineCache) callconv(.c) i32 = undefined,
    vkDestroyPipelineCache: *const fn (Device, PipelineCache, ?*const AllocationCallbacks) callconv(.c) void = undefined,
    vkGetPipelineCacheData: *const fn (Device, PipelineCache, *usize, ?*anyopaque) callconv(.c) i32 = undefined,
    vkCreateDescriptorPool: *const fn (Device, *const DescriptorPoolCreateInfo, ?*const AllocationCallbacks, *DescriptorPool) callconv(.c) i32 = undefined,
    vkDestroyDescriptorPool: *const fn (Device, DescriptorPool, ?*const AllocationCallbacks) callconv(.c) void = undefined,
    vkResetDescriptorPool: *const fn (Device, DescriptorPool, u32) callconv(.c) i32 = undefined,
    vkAllocateDescriptorSets: *const fn (Device, *const DescriptorSetAllocateInfo, [*]DescriptorSet) callconv(.c) i32 = undefined,
    vkUpdateDescriptorSets: *const fn (Device, u32, [*]const WriteDescriptorSet, u32, ?*const anyopaque) callconv(.c) void = undefined,
    vkCmdBindDescriptorSets: *const fn (CommandBuffer, i32, PipelineLayout, u32, u32, [*]const DescriptorSet, u32, ?[*]const u32) callconv(.c) void = undefined,
    vkDeviceWaitIdle: *const fn (Device) callconv(.c) i32 = undefined,
    vkCreateBuffer: *const fn (Device, *const BufferCreateInfo, ?*const AllocationCallbacks, *Buffer) callconv(.c) i32 = undefined,
    vkDestroyBuffer: *const fn (Device, Buffer, ?*const AllocationCallbacks) callconv(.c) void = undefined,
    vkGetBufferMemoryRequirements: *const fn (Device, Buffer, *MemoryRequirements) callconv(.c) void = undefined,
    vkBindBufferMemory: *const fn (Device, Buffer, DeviceMemory, u64) callconv(.c) i32 = undefined,
    vkGetBufferDeviceAddress: *const fn (Device, *const BufferDeviceAddressInfo) callconv(.c) u64 = undefined,
    vkCreateImage: *const fn (Device, *const ImageCreateInfo, ?*const AllocationCallbacks, *Image) callconv(.c) i32 = undefined,
    vkDestroyImage: *const fn (Device, Image, ?*const AllocationCallbacks) callconv(.c) void = undefined,
    vkGetImageMemoryRequirements: *const fn (Device, Image, *MemoryRequirements) callconv(.c) void = undefined,
    vkBindImageMemory: *const fn (Device, Image, DeviceMemory, u64) callconv(.c) i32 = undefined,
    vkCreateImageView: *const fn (Device, *const ImageViewCreateInfo, ?*const AllocationCallbacks, *ImageView) callconv(.c) i32 = undefined,
    vkDestroyImageView: *const fn (Device, ImageView, ?*const AllocationCallbacks) callconv(.c) void = undefined,
    vkAllocateMemory: *const fn (Device, *const MemoryAllocateInfo, ?*const AllocationCallbacks, *DeviceMemory) callconv(.c) i32 = undefined,
    vkFreeMemory: *const fn (Device, DeviceMemory, ?*const AllocationCallbacks) callconv(.c) void = undefined,
    vkMapMemory: *const fn (Device, DeviceMemory, u64, u64, u32, *?*anyopaque) callconv(.c) i32 = undefined,
    vkUnmapMemory: *const fn (Device, DeviceMemory) callconv(.c) void = undefined,
    vkCreateSampler: *const fn (Device, *const SamplerCreateInfo, ?*const AllocationCallbacks, *Sampler) callconv(.c) i32 = undefined,
    vkDestroySampler: *const fn (Device, Sampler, ?*const AllocationCallbacks) callconv(.c) void = undefined,
    vkCreateShaderModule: *const fn (Device, *const ShaderModuleCreateInfo, ?*const AllocationCallbacks, *ShaderModule) callconv(.c) i32 = undefined,
    vkDestroyShaderModule: *const fn (Device, ShaderModule, ?*const AllocationCallbacks) callconv(.c) void = undefined,
    vkCreateDescriptorSetLayout: *const fn (Device, *const DescriptorSetLayoutCreateInfo, ?*const AllocationCallbacks, *DescriptorSetLayout) callconv(.c) i32 = undefined,
    vkDestroyDescriptorSetLayout: *const fn (Device, DescriptorSetLayout, ?*const AllocationCallbacks) callconv(.c) void = undefined,
    vkCreatePipelineLayout: *const fn (Device, *const PipelineLayoutCreateInfo, ?*const AllocationCallbacks, *PipelineLayout) callconv(.c) i32 = undefined,
    vkDestroyPipelineLayout: *const fn (Device, PipelineLayout, ?*const AllocationCallbacks) callconv(.c) void = undefined,
    vkCreateGraphicsPipelines: *const fn (Device, PipelineCache, u32, [*]const GraphicsPipelineCreateInfo, ?*const AllocationCallbacks, [*]Pipeline) callconv(.c) i32 = undefined,
    vkCreateComputePipelines: *const fn (Device, PipelineCache, u32, [*]const ComputePipelineCreateInfo, ?*const AllocationCallbacks, [*]Pipeline) callconv(.c) i32 = undefined,
    vkDestroyPipeline: *const fn (Device, Pipeline, ?*const AllocationCallbacks) callconv(.c) void = undefined,
    vkCreateFence: *const fn (Device, *const FenceCreateInfo, ?*const AllocationCallbacks, *Fence) callconv(.c) i32 = undefined,
    vkDestroyFence: *const fn (Device, Fence, ?*const AllocationCallbacks) callconv(.c) void = undefined,
    vkWaitForFences: *const fn (Device, u32, [*]const Fence, u32, u64) callconv(.c) i32 = undefined,
    vkResetFences: *const fn (Device, u32, [*]const Fence) callconv(.c) i32 = undefined,
    vkCreateCommandPool: *const fn (Device, *const CommandPoolCreateInfo, ?*const AllocationCallbacks, *CommandPool) callconv(.c) i32 = undefined,
    vkDestroyCommandPool: *const fn (Device, CommandPool, ?*const AllocationCallbacks) callconv(.c) void = undefined,
    vkAllocateCommandBuffers: *const fn (Device, *const CommandBufferAllocateInfo, *CommandBuffer) callconv(.c) i32 = undefined,
    vkResetCommandBuffer: *const fn (CommandBuffer, u32) callconv(.c) i32 = undefined,
    vkBeginCommandBuffer: *const fn (CommandBuffer, *const CommandBufferBeginInfo) callconv(.c) i32 = undefined,
    vkEndCommandBuffer: *const fn (CommandBuffer) callconv(.c) i32 = undefined,
    vkQueueSubmit: *const fn (Queue, u32, [*]const SubmitInfo, Fence) callconv(.c) i32 = undefined,
    vkQueueWaitIdle: *const fn (Queue) callconv(.c) i32 = undefined,
    vkCmdPipelineBarrier2: *const fn (CommandBuffer, *const DependencyInfo) callconv(.c) void = undefined,
    vkCmdCopyBuffer: *const fn (CommandBuffer, Buffer, Buffer, u32, [*]const BufferCopy) callconv(.c) void = undefined,
    vkCmdCopyImageToBuffer: *const fn (CommandBuffer, Image, i32, Buffer, u32, [*]const BufferImageCopy) callconv(.c) void = undefined,
    vkCmdCopyBufferToImage2: *const fn (CommandBuffer, *const CopyBufferToImageInfo2) callconv(.c) void = undefined,
    vkCmdBeginRendering: *const fn (CommandBuffer, *const RenderingInfo) callconv(.c) void = undefined,
    vkCmdEndRendering: *const fn (CommandBuffer) callconv(.c) void = undefined,
    vkCmdBindPipeline: *const fn (CommandBuffer, i32, Pipeline) callconv(.c) void = undefined,
    vkCmdSetViewport: *const fn (CommandBuffer, u32, u32, [*]const Viewport) callconv(.c) void = undefined,
    vkCmdSetScissor: *const fn (CommandBuffer, u32, u32, [*]const Rect2D) callconv(.c) void = undefined,
    vkCmdBindVertexBuffers: *const fn (CommandBuffer, u32, u32, [*]const Buffer, [*]const u64) callconv(.c) void = undefined,
    vkCmdBindIndexBuffer: *const fn (CommandBuffer, Buffer, u64, i32) callconv(.c) void = undefined,
    vkCmdDraw: *const fn (CommandBuffer, u32, u32, u32, u32) callconv(.c) void = undefined,
    vkCmdDrawIndexed: *const fn (CommandBuffer, u32, u32, u32, i32, u32) callconv(.c) void = undefined,
    vkCmdDispatch: *const fn (CommandBuffer, u32, u32, u32) callconv(.c) void = undefined,
    vkGetDescriptorSetLayoutSizeEXT: ?*const fn (Device, DescriptorSetLayout, *u64) callconv(.c) void = null,
    vkGetDescriptorSetLayoutBindingOffsetEXT: ?*const fn (Device, DescriptorSetLayout, u32, *u64) callconv(.c) void = null,
    vkGetDescriptorEXT: ?*const fn (Device, *const DescriptorGetInfoEXT, usize, ?*anyopaque) callconv(.c) void = null,
    vkCmdBindDescriptorBuffersEXT: ?*const fn (CommandBuffer, u32, [*]const DescriptorBufferBindingInfoEXT) callconv(.c) void = null,
    vkCmdSetDescriptorBufferOffsetsEXT: ?*const fn (CommandBuffer, i32, PipelineLayout, u32, u32, [*]const u32, [*]const u64) callconv(.c) void = null,
    // extension entry points (VK_EXT_descriptor_buffer is required and checked at init)
    vkSetDebugUtilsObjectNameEXT: ?*const fn (Device, *const DebugUtilsObjectNameInfoEXT) callconv(.c) i32 = null,
    vkCmdBeginDebugUtilsLabelEXT: ?*const fn (CommandBuffer, *const DebugUtilsLabelEXT) callconv(.c) void = null,
    vkCmdEndDebugUtilsLabelEXT: ?*const fn (CommandBuffer) callconv(.c) void = null,
};

pub const GetInstanceProcAddr = *const fn (Instance, [*:0]const u8) callconv(.c) ?*const anyopaque;
pub const GetDeviceProcAddr = *const fn (Device, [*:0]const u8) callconv(.c) ?*const anyopaque;

/// Resolves every field of `out` by name. Optional fields may stay null, all others are required.
fn loadFns(comptime Table: type, out: *Table, getter: anytype, handle: anytype) error{MissingVulkanFunction}!void {
    const info = @typeInfo(Table).@"struct";
    inline for (info.field_names, info.field_types) |name, FieldType| {
        const proc = getter(handle, name.ptr);
        if (proc) |p| {
            @field(out, name) = @ptrCast(@alignCast(p));
        } else if (@typeInfo(FieldType) != .optional) {
            return error.MissingVulkanFunction;
        }
    }
}

/// All entry points used by the backend, loaded from the application's instance and device.
pub const Dispatch = struct {
    instance: InstanceFns = .{},
    device: DeviceFns = .{},

    pub fn load(self: *Dispatch, get_instance: GetInstanceProcAddr, instance: Instance, device: Device) error{MissingVulkanFunction}!void {
        try loadFns(InstanceFns, &self.instance, get_instance, instance);
        const get_device: GetDeviceProcAddr = @ptrCast(@alignCast(get_instance(instance, "vkGetDeviceProcAddr") orelse return error.MissingVulkanFunction));
        try loadFns(DeviceFns, &self.device, get_device, device);
    }
};

pub const DescriptorPool = u64;
pub const DescriptorSet = u64;
pub const DescriptorPoolSize = extern struct { type: i32, descriptorCount: u32 };
pub const DescriptorPoolCreateInfo = extern struct {
    sType: i32 = 33,
    pNext: ?*const anyopaque = null,
    flags: u32 = 0,
    maxSets: u32,
    poolSizeCount: u32,
    pPoolSizes: [*]const DescriptorPoolSize,
};
pub const DescriptorSetAllocateInfo = extern struct {
    sType: i32 = 34,
    pNext: ?*const anyopaque = null,
    descriptorPool: DescriptorPool,
    descriptorSetCount: u32,
    pSetLayouts: [*]const DescriptorSetLayout,
};
pub const WriteDescriptorSet = extern struct {
    sType: i32 = 35,
    pNext: ?*const anyopaque = null,
    dstSet: DescriptorSet = 0,
    dstBinding: u32 = 0,
    dstArrayElement: u32 = 0,
    descriptorCount: u32 = 1,
    descriptorType: i32 = 0,
    pImageInfo: ?[*]const DescriptorImageInfo = null,
    pBufferInfo: ?[*]const DescriptorBufferInfo = null,
    pTexelBufferView: ?[*]const u64 = null,
};

pub const PipelineCacheCreateInfo = extern struct {
    sType: i32 = 17,
    pNext: ?*const anyopaque = null,
    flags: u32 = 0,
    initialDataSize: usize = 0,
    pInitialData: ?*const anyopaque = null,
};
