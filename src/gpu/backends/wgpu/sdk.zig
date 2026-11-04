//! WebGPU ABI declarations generated from the pinned webgpu.h (wgpu-native v29.0.1.1,
//! webgpu-headers 673658bc). Enum values, flags and struct layouts are copied from the header.
//! Every function is resolved at runtime through the environment's get_proc_address.

pub const ChainedStruct = extern struct {
    next: ?*const ChainedStruct = null,
    s_type: SType = @fromBackingInt(@intCast(0)),
};

pub const BindGroup = *opaque {};
pub const BindGroupLayout = *opaque {};
pub const Buffer = *opaque {};
pub const CommandBuffer = *opaque {};
pub const CommandEncoder = *opaque {};
pub const ComputePassEncoder = *opaque {};
pub const ComputePipeline = *opaque {};
pub const Device = *opaque {};
pub const PipelineLayout = *opaque {};
pub const QuerySet = *opaque {};
pub const Queue = *opaque {};
pub const RenderPassEncoder = *opaque {};
pub const RenderPipeline = *opaque {};
pub const Sampler = *opaque {};
pub const ShaderModule = *opaque {};
pub const Texture = *opaque {};
pub const TextureView = *opaque {};
pub const BufferUsage = struct {
    pub const none: u64 = 0x0;
    pub const map_read: u64 = 0x1;
    pub const map_write: u64 = 0x2;
    pub const copy_src: u64 = 0x4;
    pub const copy_dst: u64 = 0x8;
    pub const index: u64 = 0x10;
    pub const vertex: u64 = 0x20;
    pub const uniform: u64 = 0x40;
    pub const storage: u64 = 0x80;
    pub const indirect: u64 = 0x100;
    pub const query_resolve: u64 = 0x200;
};

pub const ColorWriteMask = struct {
    pub const none: u64 = 0x0;
    pub const red: u64 = 0x1;
    pub const green: u64 = 0x2;
    pub const blue: u64 = 0x4;
    pub const alpha: u64 = 0x8;
    pub const all: u64 = 0xf;
};

pub const MapMode = struct {
    pub const none: u64 = 0x0;
    pub const read: u64 = 0x1;
    pub const write: u64 = 0x2;
};

pub const ShaderStage = struct {
    pub const none: u64 = 0x0;
    pub const vertex: u64 = 0x1;
    pub const fragment: u64 = 0x2;
    pub const compute: u64 = 0x4;
};

pub const TextureUsage = struct {
    pub const none: u64 = 0x0;
    pub const copy_src: u64 = 0x1;
    pub const copy_dst: u64 = 0x2;
    pub const texture_binding: u64 = 0x4;
    pub const storage_binding: u64 = 0x8;
    pub const render_attachment: u64 = 0x10;
    pub const transient_attachment: u64 = 0x20;
};

pub const AddressMode = enum(u32) {
    undefined = 0,
    clamp_to_edge = 1,
    repeat = 2,
    mirror_repeat = 3,
    _,
};

pub const BlendFactor = enum(u32) {
    undefined = 0,
    zero = 1,
    one = 2,
    src = 3,
    one_minus_src = 4,
    src_alpha = 5,
    one_minus_src_alpha = 6,
    dst = 7,
    one_minus_dst = 8,
    dst_alpha = 9,
    one_minus_dst_alpha = 10,
    src_alpha_saturated = 11,
    constant = 12,
    one_minus_constant = 13,
    src1 = 14,
    one_minus_src1 = 15,
    src1_alpha = 16,
    one_minus_src1_alpha = 17,
    _,
};

pub const BlendOperation = enum(u32) {
    undefined = 0,
    add = 1,
    subtract = 2,
    reverse_subtract = 3,
    min = 4,
    max = 5,
    _,
};

pub const BufferBindingType = enum(u32) {
    binding_not_used = 0,
    undefined = 1,
    uniform = 2,
    storage = 3,
    read_only_storage = 4,
    _,
};

pub const CompareFunction = enum(u32) {
    undefined = 0,
    never = 1,
    less = 2,
    equal = 3,
    less_equal = 4,
    greater = 5,
    not_equal = 6,
    greater_equal = 7,
    always = 8,
    _,
};

pub const CullMode = enum(u32) {
    undefined = 0,
    none = 1,
    front = 2,
    back = 3,
    _,
};

pub const FeatureName = enum(u32) {
    core_features_and_limits = 1,
    depth_clip_control = 2,
    depth32_float_stencil8 = 3,
    texture_compression_bc = 4,
    texture_compression_bc_sliced3_d = 5,
    texture_compression_etc2 = 6,
    texture_compression_astc = 7,
    texture_compression_astc_sliced3_d = 8,
    timestamp_query = 9,
    indirect_first_instance = 10,
    shader_f16 = 11,
    rg11_b10_ufloat_renderable = 12,
    bgra8_unorm_storage = 13,
    float32_filterable = 14,
    float32_blendable = 15,
    clip_distances = 16,
    dual_source_blending = 17,
    subgroups = 18,
    texture_formats_tier1 = 19,
    texture_formats_tier2 = 20,
    primitive_index = 21,
    texture_component_swizzle = 22,
    _,
};

pub const FilterMode = enum(u32) {
    undefined = 0,
    nearest = 1,
    linear = 2,
    _,
};

pub const FrontFace = enum(u32) {
    undefined = 0,
    ccw = 1,
    cw = 2,
    _,
};

pub const IndexFormat = enum(u32) {
    undefined = 0,
    uint16 = 1,
    uint32 = 2,
    _,
};

pub const LoadOp = enum(u32) {
    undefined = 0,
    load = 1,
    clear = 2,
    _,
};

pub const MipmapFilterMode = enum(u32) {
    undefined = 0,
    nearest = 1,
    linear = 2,
    _,
};

pub const OptionalBool = enum(u32) {
    false = 0,
    true = 1,
    undefined = 2,
    _,
};

pub const PrimitiveTopology = enum(u32) {
    undefined = 0,
    point_list = 1,
    line_list = 2,
    line_strip = 3,
    triangle_list = 4,
    triangle_strip = 5,
    _,
};

pub const SType = enum(u32) {
    shader_source_spirv = 1,
    shader_source_wgsl = 2,
    render_pass_max_draw_count = 3,
    surface_source_metal_layer = 4,
    surface_source_windows_hwnd = 5,
    surface_source_xlib_window = 6,
    surface_source_wayland_surface = 7,
    surface_source_android_native_window = 8,
    surface_source_xcb_window = 9,
    surface_color_management = 10,
    request_adapter_web_xr_options = 11,
    texture_component_swizzle_descriptor = 12,
    external_texture_binding_layout = 13,
    external_texture_binding_entry = 14,
    compatibility_mode_limits = 15,
    texture_binding_view_dimension = 16,
    _,
};

pub const SamplerBindingType = enum(u32) {
    binding_not_used = 0,
    undefined = 1,
    filtering = 2,
    non_filtering = 3,
    comparison = 4,
    _,
};

pub const Status = enum(u32) {
    success = 1,
    @"error" = 2,
    _,
};

pub const StencilOperation = enum(u32) {
    undefined = 0,
    keep = 1,
    zero = 2,
    replace = 3,
    invert = 4,
    increment_clamp = 5,
    decrement_clamp = 6,
    increment_wrap = 7,
    decrement_wrap = 8,
    _,
};

pub const StorageTextureAccess = enum(u32) {
    binding_not_used = 0,
    undefined = 1,
    write_only = 2,
    read_only = 3,
    read_write = 4,
    _,
};

pub const StoreOp = enum(u32) {
    undefined = 0,
    store = 1,
    discard = 2,
    _,
};

pub const TextureAspect = enum(u32) {
    undefined = 0,
    all = 1,
    stencil_only = 2,
    depth_only = 3,
    _,
};

pub const TextureDimension = enum(u32) {
    undefined = 0,
    @"1_d" = 1,
    @"2_d" = 2,
    @"3_d" = 3,
    _,
};

pub const TextureFormat = enum(u32) {
    undefined = 0,
    r8_unorm = 1,
    r8_snorm = 2,
    r8_uint = 3,
    r8_sint = 4,
    r16_unorm = 5,
    r16_snorm = 6,
    r16_uint = 7,
    r16_sint = 8,
    r16_float = 9,
    rg8_unorm = 10,
    rg8_snorm = 11,
    rg8_uint = 12,
    rg8_sint = 13,
    r32_float = 14,
    r32_uint = 15,
    r32_sint = 16,
    rg16_unorm = 17,
    rg16_snorm = 18,
    rg16_uint = 19,
    rg16_sint = 20,
    rg16_float = 21,
    rgba8_unorm = 22,
    rgba8_unorm_srgb = 23,
    rgba8_snorm = 24,
    rgba8_uint = 25,
    rgba8_sint = 26,
    bgra8_unorm = 27,
    bgra8_unorm_srgb = 28,
    rgb10_a2_uint = 29,
    rgb10_a2_unorm = 30,
    rg11_b10_ufloat = 31,
    rgb9_e5_ufloat = 32,
    rg32_float = 33,
    rg32_uint = 34,
    rg32_sint = 35,
    rgba16_unorm = 36,
    rgba16_snorm = 37,
    rgba16_uint = 38,
    rgba16_sint = 39,
    rgba16_float = 40,
    rgba32_float = 41,
    rgba32_uint = 42,
    rgba32_sint = 43,
    stencil8 = 44,
    depth16_unorm = 45,
    depth24_plus = 46,
    depth24_plus_stencil8 = 47,
    depth32_float = 48,
    depth32_float_stencil8 = 49,
    bc1_rgba_unorm = 50,
    bc1_rgba_unorm_srgb = 51,
    bc2_rgba_unorm = 52,
    bc2_rgba_unorm_srgb = 53,
    bc3_rgba_unorm = 54,
    bc3_rgba_unorm_srgb = 55,
    bc4_r_unorm = 56,
    bc4_r_snorm = 57,
    bc5_rg_unorm = 58,
    bc5_rg_snorm = 59,
    bc6_hrgb_ufloat = 60,
    bc6_hrgb_float = 61,
    bc7_rgba_unorm = 62,
    bc7_rgba_unorm_srgb = 63,
    etc2_rgb8_unorm = 64,
    etc2_rgb8_unorm_srgb = 65,
    etc2_rgb8_a1_unorm = 66,
    etc2_rgb8_a1_unorm_srgb = 67,
    etc2_rgba8_unorm = 68,
    etc2_rgba8_unorm_srgb = 69,
    eacr11_unorm = 70,
    eacr11_snorm = 71,
    eacrg11_unorm = 72,
    eacrg11_snorm = 73,
    astc4x4_unorm = 74,
    astc4x4_unorm_srgb = 75,
    astc5x4_unorm = 76,
    astc5x4_unorm_srgb = 77,
    astc5x5_unorm = 78,
    astc5x5_unorm_srgb = 79,
    astc6x5_unorm = 80,
    astc6x5_unorm_srgb = 81,
    astc6x6_unorm = 82,
    astc6x6_unorm_srgb = 83,
    astc8x5_unorm = 84,
    astc8x5_unorm_srgb = 85,
    astc8x6_unorm = 86,
    astc8x6_unorm_srgb = 87,
    astc8x8_unorm = 88,
    astc8x8_unorm_srgb = 89,
    astc10x5_unorm = 90,
    astc10x5_unorm_srgb = 91,
    astc10x6_unorm = 92,
    astc10x6_unorm_srgb = 93,
    astc10x8_unorm = 94,
    astc10x8_unorm_srgb = 95,
    astc10x10_unorm = 96,
    astc10x10_unorm_srgb = 97,
    astc12x10_unorm = 98,
    astc12x10_unorm_srgb = 99,
    astc12x12_unorm = 100,
    astc12x12_unorm_srgb = 101,
    _,
};

pub const TextureSampleType = enum(u32) {
    binding_not_used = 0,
    undefined = 1,
    float = 2,
    unfilterable_float = 3,
    depth = 4,
    sint = 5,
    uint = 6,
    _,
};

pub const TextureViewDimension = enum(u32) {
    undefined = 0,
    @"1_d" = 1,
    @"2_d" = 2,
    @"2_d_array" = 3,
    cube = 4,
    cube_array = 5,
    @"3_d" = 6,
    _,
};

pub const VertexFormat = enum(u32) {
    uint8 = 1,
    uint8x2 = 2,
    uint8x4 = 3,
    sint8 = 4,
    sint8x2 = 5,
    sint8x4 = 6,
    unorm8 = 7,
    unorm8x2 = 8,
    unorm8x4 = 9,
    snorm8 = 10,
    snorm8x2 = 11,
    snorm8x4 = 12,
    uint16 = 13,
    uint16x2 = 14,
    uint16x4 = 15,
    sint16 = 16,
    sint16x2 = 17,
    sint16x4 = 18,
    unorm16 = 19,
    unorm16x2 = 20,
    unorm16x4 = 21,
    snorm16 = 22,
    snorm16x2 = 23,
    snorm16x4 = 24,
    float16 = 25,
    float16x2 = 26,
    float16x4 = 27,
    float32 = 28,
    float32x2 = 29,
    float32x3 = 30,
    float32x4 = 31,
    uint32 = 32,
    uint32x2 = 33,
    uint32x3 = 34,
    uint32x4 = 35,
    sint32 = 36,
    sint32x2 = 37,
    sint32x3 = 38,
    sint32x4 = 39,
    unorm10_10_10_2 = 40,
    unorm8x4_bgra = 41,
    _,
};

pub const VertexStepMode = enum(u32) {
    undefined = 0,
    vertex = 1,
    instance = 2,
    _,
};

pub const BindGroupDescriptor = extern struct {
    next_in_chain: ?*ChainedStruct = null,
    label: StringView = .{},
    layout: ?BindGroupLayout = null,
    entry_count: usize = 0,
    entries: ?*const BindGroupEntry = null,
};

pub const BindGroupEntry = extern struct {
    next_in_chain: ?*ChainedStruct = null,
    binding: u32 = 0,
    buffer: ?Buffer = null,
    offset: u64 = 0,
    size: u64 = 0,
    sampler: ?Sampler = null,
    texture_view: ?TextureView = null,
};

pub const BindGroupLayoutDescriptor = extern struct {
    next_in_chain: ?*ChainedStruct = null,
    label: StringView = .{},
    entry_count: usize = 0,
    entries: ?*const BindGroupLayoutEntry = null,
};

pub const BindGroupLayoutEntry = extern struct {
    next_in_chain: ?*ChainedStruct = null,
    binding: u32 = 0,
    visibility: u64 = 0,
    binding_array_size: u32 = 0,
    buffer: BufferBindingLayout = .{},
    sampler: SamplerBindingLayout = .{},
    texture: TextureBindingLayout = .{},
    storage_texture: StorageTextureBindingLayout = .{},
};

pub const BlendComponent = extern struct {
    operation: BlendOperation = @fromBackingInt(@intCast(0)),
    src_factor: BlendFactor = @fromBackingInt(@intCast(0)),
    dst_factor: BlendFactor = @fromBackingInt(@intCast(0)),
};

pub const BlendState = extern struct {
    color: BlendComponent = .{},
    alpha: BlendComponent = .{},
};

pub const BufferBindingLayout = extern struct {
    next_in_chain: ?*ChainedStruct = null,
    type: BufferBindingType = @fromBackingInt(@intCast(0)),
    has_dynamic_offset: u32 = 0,
    min_binding_size: u64 = 0,
};

pub const BufferDescriptor = extern struct {
    next_in_chain: ?*ChainedStruct = null,
    label: StringView = .{},
    usage: u64 = 0,
    size: u64 = 0,
    mapped_at_creation: u32 = 0,
};

pub const Color = extern struct {
    r: f64 = 0,
    g: f64 = 0,
    b: f64 = 0,
    a: f64 = 0,
};

pub const ColorTargetState = extern struct {
    next_in_chain: ?*ChainedStruct = null,
    format: TextureFormat = @fromBackingInt(@intCast(0)),
    blend: ?*const BlendState = null,
    write_mask: u64 = 0,
};

pub const CommandBufferDescriptor = extern struct {
    next_in_chain: ?*ChainedStruct = null,
    label: StringView = .{},
};

pub const CommandEncoderDescriptor = extern struct {
    next_in_chain: ?*ChainedStruct = null,
    label: StringView = .{},
};

pub const ComputePassDescriptor = extern struct {
    next_in_chain: ?*ChainedStruct = null,
    label: StringView = .{},
    timestamp_writes: ?*const PassTimestampWrites = null,
};

pub const ComputePipelineDescriptor = extern struct {
    next_in_chain: ?*ChainedStruct = null,
    label: StringView = .{},
    layout: ?PipelineLayout = null,
    compute: ComputeState = .{},
};

pub const ComputeState = extern struct {
    next_in_chain: ?*ChainedStruct = null,
    module: ?ShaderModule = null,
    entry_point: StringView = .{},
    constant_count: usize = 0,
    constants: ?*const ConstantEntry = null,
};

pub const ConstantEntry = extern struct {
    next_in_chain: ?*ChainedStruct = null,
    key: StringView = .{},
    value: f64 = 0,
};

pub const DepthStencilState = extern struct {
    next_in_chain: ?*ChainedStruct = null,
    format: TextureFormat = @fromBackingInt(@intCast(0)),
    depth_write_enabled: OptionalBool = @fromBackingInt(@intCast(0)),
    depth_compare: CompareFunction = @fromBackingInt(@intCast(0)),
    stencil_front: StencilFaceState = .{},
    stencil_back: StencilFaceState = .{},
    stencil_read_mask: u32 = 0,
    stencil_write_mask: u32 = 0,
    depth_bias: i32 = 0,
    depth_bias_slope_scale: f32 = 0,
    depth_bias_clamp: f32 = 0,
};

pub const Extent3D = extern struct {
    width: u32 = 0,
    height: u32 = 0,
    depth_or_array_layers: u32 = 0,
};

pub const FragmentState = extern struct {
    next_in_chain: ?*ChainedStruct = null,
    module: ?ShaderModule = null,
    entry_point: StringView = .{},
    constant_count: usize = 0,
    constants: ?*const ConstantEntry = null,
    target_count: usize = 0,
    targets: ?*const ColorTargetState = null,
};

pub const Future = extern struct {
    id: u64 = 0,
};

pub const Limits = extern struct {
    next_in_chain: ?*ChainedStruct = null,
    max_texture_dimension1_d: u32 = 0,
    max_texture_dimension2_d: u32 = 0,
    max_texture_dimension3_d: u32 = 0,
    max_texture_array_layers: u32 = 0,
    max_bind_groups: u32 = 0,
    max_bind_groups_plus_vertex_buffers: u32 = 0,
    max_bindings_per_bind_group: u32 = 0,
    max_dynamic_uniform_buffers_per_pipeline_layout: u32 = 0,
    max_dynamic_storage_buffers_per_pipeline_layout: u32 = 0,
    max_sampled_textures_per_shader_stage: u32 = 0,
    max_samplers_per_shader_stage: u32 = 0,
    max_storage_buffers_per_shader_stage: u32 = 0,
    max_storage_textures_per_shader_stage: u32 = 0,
    max_uniform_buffers_per_shader_stage: u32 = 0,
    max_uniform_buffer_binding_size: u64 = 0,
    max_storage_buffer_binding_size: u64 = 0,
    min_uniform_buffer_offset_alignment: u32 = 0,
    min_storage_buffer_offset_alignment: u32 = 0,
    max_vertex_buffers: u32 = 0,
    max_buffer_size: u64 = 0,
    max_vertex_attributes: u32 = 0,
    max_vertex_buffer_array_stride: u32 = 0,
    max_inter_stage_shader_variables: u32 = 0,
    max_color_attachments: u32 = 0,
    max_color_attachment_bytes_per_sample: u32 = 0,
    max_compute_workgroup_storage_size: u32 = 0,
    max_compute_invocations_per_workgroup: u32 = 0,
    max_compute_workgroup_size_x: u32 = 0,
    max_compute_workgroup_size_y: u32 = 0,
    max_compute_workgroup_size_z: u32 = 0,
    max_compute_workgroups_per_dimension: u32 = 0,
    max_immediate_size: u32 = 0,
};

pub const MultisampleState = extern struct {
    next_in_chain: ?*ChainedStruct = null,
    count: u32 = 0,
    mask: u32 = 0,
    alpha_to_coverage_enabled: u32 = 0,
};

pub const Origin3D = extern struct {
    x: u32 = 0,
    y: u32 = 0,
    z: u32 = 0,
};

pub const PassTimestampWrites = extern struct {
    next_in_chain: ?*ChainedStruct = null,
    query_set: ?QuerySet = null,
    beginning_of_pass_write_index: u32 = 0,
    end_of_pass_write_index: u32 = 0,
};

pub const PipelineLayoutDescriptor = extern struct {
    next_in_chain: ?*ChainedStruct = null,
    label: StringView = .{},
    bind_group_layout_count: usize = 0,
    bind_group_layouts: ?*const ?BindGroupLayout = null,
    immediate_size: u32 = 0,
};

pub const PrimitiveState = extern struct {
    next_in_chain: ?*ChainedStruct = null,
    topology: PrimitiveTopology = @fromBackingInt(@intCast(0)),
    strip_index_format: IndexFormat = @fromBackingInt(@intCast(0)),
    front_face: FrontFace = @fromBackingInt(@intCast(0)),
    cull_mode: CullMode = @fromBackingInt(@intCast(0)),
    unclipped_depth: u32 = 0,
};

pub const RenderPassColorAttachment = extern struct {
    next_in_chain: ?*ChainedStruct = null,
    view: ?TextureView = null,
    depth_slice: u32 = 0,
    resolve_target: ?TextureView = null,
    load_op: LoadOp = @fromBackingInt(@intCast(0)),
    store_op: StoreOp = @fromBackingInt(@intCast(0)),
    clear_value: Color = .{},
};

pub const RenderPassDepthStencilAttachment = extern struct {
    next_in_chain: ?*ChainedStruct = null,
    view: ?TextureView = null,
    depth_load_op: LoadOp = @fromBackingInt(@intCast(0)),
    depth_store_op: StoreOp = @fromBackingInt(@intCast(0)),
    depth_clear_value: f32 = 0,
    depth_read_only: u32 = 0,
    stencil_load_op: LoadOp = @fromBackingInt(@intCast(0)),
    stencil_store_op: StoreOp = @fromBackingInt(@intCast(0)),
    stencil_clear_value: u32 = 0,
    stencil_read_only: u32 = 0,
};

pub const RenderPassDescriptor = extern struct {
    next_in_chain: ?*ChainedStruct = null,
    label: StringView = .{},
    color_attachment_count: usize = 0,
    color_attachments: ?*const RenderPassColorAttachment = null,
    depth_stencil_attachment: ?*const RenderPassDepthStencilAttachment = null,
    occlusion_query_set: ?QuerySet = null,
    timestamp_writes: ?*const PassTimestampWrites = null,
};

pub const RenderPipelineDescriptor = extern struct {
    next_in_chain: ?*ChainedStruct = null,
    label: StringView = .{},
    layout: ?PipelineLayout = null,
    vertex: VertexState = .{},
    primitive: PrimitiveState = .{},
    depth_stencil: ?*const DepthStencilState = null,
    multisample: MultisampleState = .{},
    fragment: ?*const FragmentState = null,
};

pub const SamplerBindingLayout = extern struct {
    next_in_chain: ?*ChainedStruct = null,
    type: SamplerBindingType = @fromBackingInt(@intCast(0)),
};

pub const SamplerDescriptor = extern struct {
    next_in_chain: ?*ChainedStruct = null,
    label: StringView = .{},
    address_mode_u: AddressMode = @fromBackingInt(@intCast(0)),
    address_mode_v: AddressMode = @fromBackingInt(@intCast(0)),
    address_mode_w: AddressMode = @fromBackingInt(@intCast(0)),
    mag_filter: FilterMode = @fromBackingInt(@intCast(0)),
    min_filter: FilterMode = @fromBackingInt(@intCast(0)),
    mipmap_filter: MipmapFilterMode = @fromBackingInt(@intCast(0)),
    lod_min_clamp: f32 = 0,
    lod_max_clamp: f32 = 0,
    compare: CompareFunction = @fromBackingInt(@intCast(0)),
    max_anisotropy: u16 = 0,
};

pub const ShaderModuleDescriptor = extern struct {
    next_in_chain: ?*ChainedStruct = null,
    label: StringView = .{},
};

pub const ShaderSourceWGSL = extern struct {
    chain: ChainedStruct = .{},
    code: StringView = .{},
};

pub const StencilFaceState = extern struct {
    compare: CompareFunction = @fromBackingInt(@intCast(0)),
    fail_op: StencilOperation = @fromBackingInt(@intCast(0)),
    depth_fail_op: StencilOperation = @fromBackingInt(@intCast(0)),
    pass_op: StencilOperation = @fromBackingInt(@intCast(0)),
};

pub const StorageTextureBindingLayout = extern struct {
    next_in_chain: ?*ChainedStruct = null,
    access: StorageTextureAccess = @fromBackingInt(@intCast(0)),
    format: TextureFormat = @fromBackingInt(@intCast(0)),
    view_dimension: TextureViewDimension = @fromBackingInt(@intCast(0)),
};

pub const StringView = extern struct {
    data: ?[*]const u8 = null,
    length: usize = 0,
};

pub const TexelCopyBufferInfo = extern struct {
    layout: TexelCopyBufferLayout = .{},
    buffer: ?Buffer = null,
};

pub const TexelCopyBufferLayout = extern struct {
    offset: u64 = 0,
    bytes_per_row: u32 = 0,
    rows_per_image: u32 = 0,
};

pub const TexelCopyTextureInfo = extern struct {
    texture: ?Texture = null,
    mip_level: u32 = 0,
    origin: Origin3D = .{},
    aspect: TextureAspect = @fromBackingInt(@intCast(0)),
};

pub const TextureBindingLayout = extern struct {
    next_in_chain: ?*ChainedStruct = null,
    sample_type: TextureSampleType = @fromBackingInt(@intCast(0)),
    view_dimension: TextureViewDimension = @fromBackingInt(@intCast(0)),
    multisampled: u32 = 0,
};

pub const TextureDescriptor = extern struct {
    next_in_chain: ?*ChainedStruct = null,
    label: StringView = .{},
    usage: u64 = 0,
    dimension: TextureDimension = @fromBackingInt(@intCast(0)),
    size: Extent3D = .{},
    format: TextureFormat = @fromBackingInt(@intCast(0)),
    mip_level_count: u32 = 0,
    sample_count: u32 = 0,
    view_format_count: usize = 0,
    view_formats: ?*const TextureFormat = null,
};

pub const TextureViewDescriptor = extern struct {
    next_in_chain: ?*ChainedStruct = null,
    label: StringView = .{},
    format: TextureFormat = @fromBackingInt(@intCast(0)),
    dimension: TextureViewDimension = @fromBackingInt(@intCast(0)),
    base_mip_level: u32 = 0,
    mip_level_count: u32 = 0,
    base_array_layer: u32 = 0,
    array_layer_count: u32 = 0,
    aspect: TextureAspect = @fromBackingInt(@intCast(0)),
    usage: u64 = 0,
};

pub const VertexAttribute = extern struct {
    next_in_chain: ?*ChainedStruct = null,
    format: VertexFormat = @fromBackingInt(@intCast(0)),
    offset: u64 = 0,
    shader_location: u32 = 0,
};

pub const VertexBufferLayout = extern struct {
    next_in_chain: ?*ChainedStruct = null,
    step_mode: VertexStepMode = @fromBackingInt(@intCast(0)),
    array_stride: u64 = 0,
    attribute_count: usize = 0,
    attributes: ?*const VertexAttribute = null,
};

pub const VertexState = extern struct {
    next_in_chain: ?*ChainedStruct = null,
    module: ?ShaderModule = null,
    entry_point: StringView = .{},
    constant_count: usize = 0,
    constants: ?*const ConstantEntry = null,
    buffer_count: usize = 0,
    buffers: ?*const VertexBufferLayout = null,
};

// BufferMapCallbackInfo has a callback field, so it is written by hand.
pub const BufferMapCallback = *const fn (status: u32, message: StringView, userdata1: ?*anyopaque, userdata2: ?*anyopaque) callconv(.c) void;
pub const BufferMapCallbackInfo = extern struct {
    next_in_chain: ?*const ChainedStruct = null,
    mode: u32 = 0,
    callback: ?BufferMapCallback = null,
    userdata1: ?*anyopaque = null,
    userdata2: ?*anyopaque = null,
};

/// wgpu-native extension (wgpu.h), resolved separately: it may be absent.
pub const DevicePollFn = *const fn (device: ?Device, wait: u32, submission: ?*const anyopaque) callconv(.c) u32;

pub const Procs = struct {
    wgpuBindGroupLayoutRelease: *const fn (?BindGroupLayout) callconv(.c) void,
    wgpuBindGroupRelease: *const fn (?BindGroup) callconv(.c) void,
    wgpuBufferAddRef: *const fn (?Buffer) callconv(.c) void,
    wgpuBufferGetConstMappedRange: *const fn (?Buffer, usize, usize) callconv(.c) ?*anyopaque,
    wgpuBufferGetMappedRange: *const fn (?Buffer, usize, usize) callconv(.c) ?*anyopaque,
    wgpuBufferMapAsync: *const fn (?Buffer, u64, usize, usize, BufferMapCallbackInfo) callconv(.c) Future,
    wgpuBufferRelease: *const fn (?Buffer) callconv(.c) void,
    wgpuBufferUnmap: *const fn (?Buffer) callconv(.c) void,
    wgpuCommandBufferRelease: *const fn (?CommandBuffer) callconv(.c) void,
    wgpuCommandEncoderBeginComputePass: *const fn (?CommandEncoder, ?*const ComputePassDescriptor) callconv(.c) ?ComputePassEncoder,
    wgpuCommandEncoderBeginRenderPass: *const fn (?CommandEncoder, ?*const RenderPassDescriptor) callconv(.c) ?RenderPassEncoder,
    wgpuCommandEncoderCopyBufferToBuffer: *const fn (?CommandEncoder, ?Buffer, u64, ?Buffer, u64, u64) callconv(.c) void,
    wgpuCommandEncoderCopyBufferToTexture: *const fn (?CommandEncoder, ?*const TexelCopyBufferInfo, ?*const TexelCopyTextureInfo, ?*const Extent3D) callconv(.c) void,
    wgpuCommandEncoderCopyTextureToBuffer: *const fn (?CommandEncoder, ?*const TexelCopyTextureInfo, ?*const TexelCopyBufferInfo, ?*const Extent3D) callconv(.c) void,
    wgpuCommandEncoderFinish: *const fn (?CommandEncoder, ?*const CommandBufferDescriptor) callconv(.c) ?CommandBuffer,
    wgpuCommandEncoderRelease: *const fn (?CommandEncoder) callconv(.c) void,
    wgpuComputePassEncoderDispatchWorkgroups: *const fn (?ComputePassEncoder, u32, u32, u32) callconv(.c) void,
    wgpuComputePassEncoderEnd: *const fn (?ComputePassEncoder) callconv(.c) void,
    wgpuComputePassEncoderRelease: *const fn (?ComputePassEncoder) callconv(.c) void,
    wgpuComputePassEncoderSetBindGroup: *const fn (?ComputePassEncoder, u32, ?BindGroup, usize, ?*const u32) callconv(.c) void,
    wgpuComputePassEncoderSetPipeline: *const fn (?ComputePassEncoder, ?ComputePipeline) callconv(.c) void,
    wgpuComputePipelineRelease: *const fn (?ComputePipeline) callconv(.c) void,
    wgpuDeviceCreateBindGroup: *const fn (?Device, ?*const BindGroupDescriptor) callconv(.c) ?BindGroup,
    wgpuDeviceCreateBindGroupLayout: *const fn (?Device, ?*const BindGroupLayoutDescriptor) callconv(.c) ?BindGroupLayout,
    wgpuDeviceCreateBuffer: *const fn (?Device, ?*const BufferDescriptor) callconv(.c) ?Buffer,
    wgpuDeviceCreateCommandEncoder: *const fn (?Device, ?*const CommandEncoderDescriptor) callconv(.c) ?CommandEncoder,
    wgpuDeviceCreateComputePipeline: *const fn (?Device, ?*const ComputePipelineDescriptor) callconv(.c) ?ComputePipeline,
    wgpuDeviceCreatePipelineLayout: *const fn (?Device, ?*const PipelineLayoutDescriptor) callconv(.c) ?PipelineLayout,
    wgpuDeviceCreateRenderPipeline: *const fn (?Device, ?*const RenderPipelineDescriptor) callconv(.c) ?RenderPipeline,
    wgpuDeviceCreateSampler: *const fn (?Device, ?*const SamplerDescriptor) callconv(.c) ?Sampler,
    wgpuDeviceCreateShaderModule: *const fn (?Device, ?*const ShaderModuleDescriptor) callconv(.c) ?ShaderModule,
    wgpuDeviceCreateTexture: *const fn (?Device, ?*const TextureDescriptor) callconv(.c) ?Texture,
    wgpuDeviceGetLimits: *const fn (?Device, ?*Limits) callconv(.c) Status,
    wgpuDeviceGetQueue: *const fn (?Device) callconv(.c) ?Queue,
    wgpuDeviceHasFeature: *const fn (?Device, FeatureName) callconv(.c) u32,
    wgpuDeviceRelease: *const fn (?Device) callconv(.c) void,
    wgpuPipelineLayoutRelease: *const fn (?PipelineLayout) callconv(.c) void,
    wgpuQueueRelease: *const fn (?Queue) callconv(.c) void,
    wgpuQueueSubmit: *const fn (?Queue, usize, ?*const ?CommandBuffer) callconv(.c) void,
    wgpuQueueWriteBuffer: *const fn (?Queue, ?Buffer, u64, ?*const anyopaque, usize) callconv(.c) void,
    wgpuQueueWriteTexture: *const fn (?Queue, ?*const TexelCopyTextureInfo, ?*const anyopaque, usize, ?*const TexelCopyBufferLayout, ?*const Extent3D) callconv(.c) void,
    wgpuRenderPassEncoderDraw: *const fn (?RenderPassEncoder, u32, u32, u32, u32) callconv(.c) void,
    wgpuRenderPassEncoderDrawIndexed: *const fn (?RenderPassEncoder, u32, u32, u32, i32, u32) callconv(.c) void,
    wgpuRenderPassEncoderEnd: *const fn (?RenderPassEncoder) callconv(.c) void,
    wgpuRenderPassEncoderRelease: *const fn (?RenderPassEncoder) callconv(.c) void,
    wgpuRenderPassEncoderSetBindGroup: *const fn (?RenderPassEncoder, u32, ?BindGroup, usize, ?*const u32) callconv(.c) void,
    wgpuRenderPassEncoderSetBlendConstant: *const fn (?RenderPassEncoder, ?*const Color) callconv(.c) void,
    wgpuRenderPassEncoderSetIndexBuffer: *const fn (?RenderPassEncoder, ?Buffer, IndexFormat, u64, u64) callconv(.c) void,
    wgpuRenderPassEncoderSetPipeline: *const fn (?RenderPassEncoder, ?RenderPipeline) callconv(.c) void,
    wgpuRenderPassEncoderSetScissorRect: *const fn (?RenderPassEncoder, u32, u32, u32, u32) callconv(.c) void,
    wgpuRenderPassEncoderSetStencilReference: *const fn (?RenderPassEncoder, u32) callconv(.c) void,
    wgpuRenderPassEncoderSetVertexBuffer: *const fn (?RenderPassEncoder, u32, ?Buffer, u64, u64) callconv(.c) void,
    wgpuRenderPassEncoderSetViewport: *const fn (?RenderPassEncoder, f32, f32, f32, f32, f32, f32) callconv(.c) void,
    wgpuRenderPipelineRelease: *const fn (?RenderPipeline) callconv(.c) void,
    wgpuSamplerAddRef: *const fn (?Sampler) callconv(.c) void,
    wgpuSamplerRelease: *const fn (?Sampler) callconv(.c) void,
    wgpuShaderModuleRelease: *const fn (?ShaderModule) callconv(.c) void,
    wgpuTextureAddRef: *const fn (?Texture) callconv(.c) void,
    wgpuTextureCreateView: *const fn (?Texture, ?*const TextureViewDescriptor) callconv(.c) ?TextureView,
    wgpuTextureRelease: *const fn (?Texture) callconv(.c) void,
    wgpuTextureViewRelease: *const fn (?TextureView) callconv(.c) void,
};

/// Resolves every function of `Procs` by its webgpu.h name.
pub fn loadProcs(get_proc_address: *const fn (name: [:0]const u8, user_data: ?*anyopaque) ?*const anyopaque, user_data: ?*anyopaque) error{WgpuInitFailed}!Procs {
    var procs: Procs = undefined;
    inline for (@typeInfo(Procs).@"struct".field_names) |name| {
        const address = get_proc_address(name, user_data) orelse return error.WgpuInitFailed;
        @field(procs, name) = @ptrCast(@alignCast(address));
    }
    return procs;
}

pub const Instance = *opaque {};
pub const FutureWaitInfo = extern struct { future: Future = .{}, completed: u32 = 0 };
pub const InstanceWaitAnyFn = *const fn (?Instance, usize, ?[*]FutureWaitInfo, u64) callconv(.c) u32;
pub const ErrorScopeCallback = *const fn (u32, u32, StringView, ?*anyopaque, ?*anyopaque) callconv(.c) void;
pub const ErrorScopeCallbackInfo = extern struct {
    next_in_chain: ?*ChainedStruct = null,
    mode: u32 = 3,
    callback: ?ErrorScopeCallback = null,
    userdata1: ?*anyopaque = null,
    userdata2: ?*anyopaque = null,
};
pub const PushErrorScopeFn = *const fn (?Device, u32) callconv(.c) void;
pub const PopErrorScopeFn = *const fn (?Device, ErrorScopeCallbackInfo) callconv(.c) Future;
