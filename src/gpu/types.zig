const std = @import("std");
const enums = @import("enums.zig");

pub const Buffer = struct {
    id: u32 = 0,
};
pub const Image = struct {
    id: u32 = 0,
};
pub const Sampler = struct {
    id: u32 = 0,
};
pub const Shader = struct {
    id: u32 = 0,
};
pub const Pipeline = struct {
    id: u32 = 0,
};
pub const View = struct {
    id: u32 = 0,
};
pub const Range = struct {
    ptr: ?*const anyopaque = null,
    size: usize = 0,

    /// Borrows the slice; its storage must outlive the call consuming this range.
    pub fn fromSlice(comptime T: type, values: []const T) Range {
        return .{ .ptr = values.ptr, .size = values.len * @sizeOf(T) };
    }

    /// Borrows a value without copying it or taking the address of a temporary.
    pub fn fromValue(comptime T: type, value: *const T) Range {
        return .{ .ptr = value, .size = @sizeOf(T) };
    }
};
pub const Color = struct {
    r: f32 = 0,
    g: f32 = 0,
    b: f32 = 0,
    a: f32 = 0,
};
pub const PixelformatInfo = struct {
    sample: bool = false,
    filter: bool = false,
    render: bool = false,
    blend: bool = false,
    msaa: bool = false,
    depth: bool = false,
    compressed: bool = false,
    read: bool = false,
    write: bool = false,
    bytes_per_pixel: i32 = 0,
};
pub const Features = struct {
    origin_top_left: bool = false,
    image_clamp_to_border: bool = false,
    mrt_independent_blend_state: bool = false,
    mrt_independent_write_mask: bool = false,
    compute: bool = false,
    msaa_texture_bindings: bool = false,
    separate_buffer_types: bool = false,
    draw_base_vertex: bool = false,
    draw_base_instance: bool = false,
    dual_source_blending: bool = false,
    vertexformat_int10_n2: bool = false,
    copy_buffer_to_image_relaxed_buffer_type: bool = false,
    copy_buffer_to_image_relaxed_bytes_per_row: bool = false,
    /// Independent native GL mip/layer view objects. Without these, mip-only
    /// views share backing texture range state and layer subsets are unsupported.
    gl_texture_views: bool = false,
};
pub const Limits = struct {
    max_image_size_2d: i32 = 0,
    max_image_size_cube: i32 = 0,
    max_image_size_3d: i32 = 0,
    max_image_size_array: i32 = 0,
    max_image_array_layers: i32 = 0,
    max_vertex_attrs: i32 = 0,
    max_color_attachments: i32 = 0,
    max_texture_bindings_per_stage: i32 = 0,
    max_storage_buffer_bindings_per_stage: i32 = 0,
    max_storage_image_bindings_per_stage: i32 = 0,
    gl_max_vertex_uniform_components: i32 = 0,
    gl_max_combined_texture_image_units: i32 = 0,
    d3d11_max_unordered_access_views: i32 = 0,
    vk_min_uniform_buffer_offset_alignment: i32 = 0,
};
pub const ColorAttachmentAction = struct {
    load_action: enums.LoadAction = .default,
    store_action: enums.StoreAction = .default,
    clear_value: Color = .{},
};
pub const DepthAttachmentAction = struct {
    load_action: enums.LoadAction = .default,
    store_action: enums.StoreAction = .default,
    clear_value: f32 = 0,
};
pub const StencilAttachmentAction = struct {
    load_action: enums.LoadAction = .default,
    store_action: enums.StoreAction = .default,
    clear_value: u8 = 0,
};
pub const PassAction = struct {
    colors: [8]ColorAttachmentAction = std.mem.zeroes([8]ColorAttachmentAction),
    depth: DepthAttachmentAction = .{},
    stencil: StencilAttachmentAction = .{},
};
pub const MetalSwapchain = struct {
    current_drawable: ?*const anyopaque = null,
    depth_stencil_texture: ?*const anyopaque = null,
    msaa_color_texture: ?*const anyopaque = null,
};
/// D3D12 swapchain targets (zicr extension): ID3D12Resource pointers; the
/// backend creates the render target and depth stencil views itself.
pub const D3d12Swapchain = struct {
    render_target: ?*const anyopaque = null,
    resolve_target: ?*const anyopaque = null,
    depth_stencil_target: ?*const anyopaque = null,
};
pub const D3d11Swapchain = struct {
    render_view: ?*const anyopaque = null,
    resolve_view: ?*const anyopaque = null,
    depth_stencil_view: ?*const anyopaque = null,
};
pub const WgpuSwapchain = struct {
    render_view: ?*const anyopaque = null,
    resolve_view: ?*const anyopaque = null,
    depth_stencil_view: ?*const anyopaque = null,
};
pub const VulkanSwapchain = struct {
    render_image: ?*const anyopaque = null,
    render_view: ?*const anyopaque = null,
    resolve_image: ?*const anyopaque = null,
    resolve_view: ?*const anyopaque = null,
    depth_stencil_image: ?*const anyopaque = null,
    depth_stencil_view: ?*const anyopaque = null,
    render_finished_semaphore: ?*const anyopaque = null,
    present_complete_semaphore: ?*const anyopaque = null,
};
pub const GlSwapchain = struct {
    framebuffer: u32 = 0,
};
pub const Swapchain = struct {
    invalid: bool = false,
    width: i32 = 0,
    height: i32 = 0,
    sample_count: i32 = 0,
    color_format: enums.PixelFormat = .default,
    depth_format: enums.PixelFormat = .default,
    metal: MetalSwapchain = .{},
    d3d11: D3d11Swapchain = .{},
    d3d12: D3d12Swapchain = .{},
    wgpu: WgpuSwapchain = .{},
    vulkan: VulkanSwapchain = .{},
    gl: GlSwapchain = .{},
};
pub const Attachments = struct {
    colors: [8]View = std.mem.zeroes([8]View),
    resolves: [8]View = std.mem.zeroes([8]View),
    depth_stencil: View = .{},
};
pub const Pass = struct {
    _start_canary: u32 = 0,
    compute: bool = false,
    action: PassAction = .{},
    attachments: Attachments = .{},
    swapchain: Swapchain = .{},
    label: ?[*:0]const u8 = null,
    _end_canary: u32 = 0,
};
pub const Bindings = struct {
    _start_canary: u32 = 0,
    vertex_buffers: [8]Buffer = std.mem.zeroes([8]Buffer),
    vertex_buffer_offsets: [8]i32 = std.mem.zeroes([8]i32),
    index_buffer: Buffer = .{},
    index_buffer_offset: i32 = 0,
    views: [32]View = std.mem.zeroes([32]View),
    samplers: [12]Sampler = std.mem.zeroes([12]Sampler),
    _end_canary: u32 = 0,
};
pub const BufferUsage = struct {
    vertex_buffer: bool = false,
    index_buffer: bool = false,
    storage_buffer: bool = false,
    staging_buffer: bool = false,
    staging_index_buffer: bool = false,
    write_unsealed: bool = false,
    write_transient: bool = false,
    copy_src: bool = false,
    copy_dst: bool = false,
};
pub const BufferDesc = struct {
    _start_canary: u32 = 0,
    size: usize = 0,
    usage: BufferUsage = .{},
    data: Range = .{},
    label: ?[*:0]const u8 = null,
    gl_buffer: u32 = 0,
    mtl_buffer: ?*const anyopaque = null,
    d3d11_buffer: ?*const anyopaque = null,
    wgpu_buffer: ?*const anyopaque = null,
    _end_canary: u32 = 0,
};
pub const ImageUsage = struct {
    storage_image: bool = false,
    color_attachment: bool = false,
    resolve_attachment: bool = false,
    depth_stencil_attachment: bool = false,
    write_unsealed: bool = false,
    write_transient: bool = false,
    copy_src: bool = false,
    copy_dst: bool = false,
    immutable: bool = false,
};
pub const ImageData = struct {
    mip_levels: [16]Range = std.mem.zeroes([16]Range),
};
pub const ImageExtent = struct {
    width: i32 = 0,
    height: i32 = 0,
    num_slices: i32 = 0,
};
pub const ImageLocation = struct {
    image: Image = .{},
    mip_level: i32 = 0,
    x: i32 = 0,
    y: i32 = 0,
    slice: i32 = 0,
};
pub const WriteImageSource = struct {
    data: Range = .{},
    offset: usize = 0,
    bytes_per_row: i32 = 0,
    bytes_per_slice: i32 = 0,
};
pub const WriteImageDesc = struct {
    src: WriteImageSource = .{},
    dst: ImageLocation = .{},
    size: ImageExtent = .{},
};
pub const BufferLocation = struct {
    buffer: Buffer = .{},
    offset: usize = 0,
};
pub const BufferImageLocation = struct {
    buffer: Buffer = .{},
    offset: usize = 0,
    bytes_per_row: i32 = 0,
    bytes_per_slice: i32 = 0,
};
pub const WriteBufferSource = struct {
    data: Range = .{},
    offset: usize = 0,
};
pub const WriteBufferDesc = struct {
    src: WriteBufferSource = .{},
    dst: BufferLocation = .{},
    size: usize = 0,
};
pub const CopyBufferToBufferDesc = struct {
    src: BufferLocation = .{},
    dst: BufferLocation = .{},
    size: usize = 0,
};
pub const CopyBufferToImageDesc = struct {
    src: BufferImageLocation = .{},
    dst: ImageLocation = .{},
    size: ImageExtent = .{},
};
pub const ImageDesc = struct {
    _start_canary: u32 = 0,
    type: enums.ImageType = .default,
    usage: ImageUsage = .{},
    width: i32 = 0,
    height: i32 = 0,
    num_slices: i32 = 0,
    num_mipmaps: i32 = 0,
    pixel_format: enums.PixelFormat = .default,
    sample_count: i32 = 0,
    data: ImageData = .{},
    label: ?[*:0]const u8 = null,
    gl_texture: u32 = 0,
    gl_texture_target: u32 = 0,
    mtl_texture: ?*const anyopaque = null,
    d3d11_texture: ?*const anyopaque = null,
    wgpu_texture: ?*const anyopaque = null,
    _end_canary: u32 = 0,
};
pub const SamplerDesc = struct {
    _start_canary: u32 = 0,
    min_filter: enums.Filter = .default,
    mag_filter: enums.Filter = .default,
    mipmap_filter: enums.Filter = .default,
    wrap_u: enums.Wrap = .default,
    wrap_v: enums.Wrap = .default,
    wrap_w: enums.Wrap = .default,
    min_lod: f32 = 0,
    max_lod: f32 = 0,
    border_color: enums.BorderColor = .default,
    compare: enums.CompareFunc = .default,
    max_anisotropy: u32 = 0,
    label: ?[*:0]const u8 = null,
    gl_sampler: u32 = 0,
    mtl_sampler: ?*const anyopaque = null,
    d3d11_sampler: ?*const anyopaque = null,
    wgpu_sampler: ?*const anyopaque = null,
    _end_canary: u32 = 0,
};
pub const ShaderFunction = struct {
    source: ?[*:0]const u8 = null,
    bytecode: Range = .{},
    entry: ?[*:0]const u8 = null,
    d3d11_target: ?[*:0]const u8 = null,
    d3d11_filepath: ?[*:0]const u8 = null,
};
pub const ShaderVertexAttr = struct {
    base_type: enums.ShaderAttrBaseType = .undefined,
    glsl_name: ?[*:0]const u8 = null,
    hlsl_sem_name: ?[*:0]const u8 = null,
    hlsl_sem_index: u8 = 0,
};
pub const GlslShaderUniform = struct {
    type: enums.UniformType = .invalid,
    array_count: u16 = 0,
    glsl_name: ?[*:0]const u8 = null,
};
pub const ShaderUniformBlock = struct {
    stage: enums.ShaderStage = .none,
    size: u32 = 0,
    hlsl_register_b_n: u8 = 0,
    msl_buffer_n: u8 = 0,
    wgsl_group0_binding_n: u8 = 0,
    spirv_set0_binding_n: u8 = 0,
    layout: enums.UniformLayout = .default,
    glsl_uniforms: [16]GlslShaderUniform = std.mem.zeroes([16]GlslShaderUniform),
};
pub const ShaderTextureView = struct {
    stage: enums.ShaderStage = .none,
    image_type: enums.ImageType = .default,
    sample_type: enums.ImageSampleType = .default,
    multisampled: bool = false,
    hlsl_register_t_n: u8 = 0,
    msl_texture_n: u8 = 0,
    wgsl_group1_binding_n: u8 = 0,
    spirv_set1_binding_n: u8 = 0,
};
pub const ShaderStorageBufferView = struct {
    stage: enums.ShaderStage = .none,
    readonly: bool = false,
    hlsl_register_t_n: u8 = 0,
    hlsl_register_u_n: u8 = 0,
    msl_buffer_n: u8 = 0,
    wgsl_group1_binding_n: u8 = 0,
    spirv_set1_binding_n: u8 = 0,
    glsl_binding_n: u8 = 0,
};
pub const ShaderStorageImageView = struct {
    stage: enums.ShaderStage = .none,
    image_type: enums.ImageType = .default,
    access_format: enums.PixelFormat = .default,
    writeonly: bool = false,
    hlsl_register_u_n: u8 = 0,
    msl_texture_n: u8 = 0,
    wgsl_group1_binding_n: u8 = 0,
    spirv_set1_binding_n: u8 = 0,
    glsl_binding_n: u8 = 0,
};
pub const ShaderView = struct {
    texture: ShaderTextureView = .{},
    storage_buffer: ShaderStorageBufferView = .{},
    storage_image: ShaderStorageImageView = .{},
};
pub const ShaderSampler = struct {
    stage: enums.ShaderStage = .none,
    sampler_type: enums.SamplerType = .default,
    hlsl_register_s_n: u8 = 0,
    msl_sampler_n: u8 = 0,
    wgsl_group1_binding_n: u8 = 0,
    spirv_set1_binding_n: u8 = 0,
};
pub const ShaderTextureSamplerPair = struct {
    stage: enums.ShaderStage = .none,
    view_slot: u8 = 0,
    sampler_slot: u8 = 0,
    glsl_name: ?[*:0]const u8 = null,
};
pub const MtlShaderThreadsPerThreadgroup = struct {
    x: i32 = 0,
    y: i32 = 0,
    z: i32 = 0,
};
pub const ShaderDesc = struct {
    _start_canary: u32 = 0,
    vertex_func: ShaderFunction = .{},
    fragment_func: ShaderFunction = .{},
    compute_func: ShaderFunction = .{},
    attrs: [16]ShaderVertexAttr = std.mem.zeroes([16]ShaderVertexAttr),
    uniform_blocks: [8]ShaderUniformBlock = std.mem.zeroes([8]ShaderUniformBlock),
    views: [32]ShaderView = std.mem.zeroes([32]ShaderView),
    samplers: [12]ShaderSampler = std.mem.zeroes([12]ShaderSampler),
    texture_sampler_pairs: [32]ShaderTextureSamplerPair = std.mem.zeroes([32]ShaderTextureSamplerPair),
    mtl_threads_per_threadgroup: MtlShaderThreadsPerThreadgroup = .{},
    label: ?[*:0]const u8 = null,
    _end_canary: u32 = 0,
};
pub const VertexBufferLayoutState = struct {
    stride: i32 = 0,
    step_func: enums.VertexStep = .default,
    step_rate: i32 = 0,
};
pub const VertexAttrState = struct {
    buffer_index: i32 = 0,
    offset: i32 = 0,
    format: enums.VertexFormat = .invalid,
};
pub const VertexLayoutState = struct {
    buffers: [8]VertexBufferLayoutState = std.mem.zeroes([8]VertexBufferLayoutState),
    attrs: [16]VertexAttrState = std.mem.zeroes([16]VertexAttrState),
};
pub const StencilFaceState = struct {
    compare: enums.CompareFunc = .default,
    fail_op: enums.StencilOp = .default,
    depth_fail_op: enums.StencilOp = .default,
    pass_op: enums.StencilOp = .default,
};
pub const StencilState = struct {
    enabled: bool = false,
    front: StencilFaceState = .{},
    back: StencilFaceState = .{},
    read_mask: u8 = 0,
    write_mask: u8 = 0,
    ref: u8 = 0,
};
pub const DepthState = struct {
    pixel_format: enums.PixelFormat = .default,
    compare: enums.CompareFunc = .default,
    write_enabled: bool = false,
    bias: f32 = 0,
    bias_slope_scale: f32 = 0,
    bias_clamp: f32 = 0,
};
pub const BlendState = struct {
    enabled: bool = false,
    src_factor_rgb: enums.BlendFactor = .default,
    dst_factor_rgb: enums.BlendFactor = .default,
    op_rgb: enums.BlendOp = .default,
    src_factor_alpha: enums.BlendFactor = .default,
    dst_factor_alpha: enums.BlendFactor = .default,
    op_alpha: enums.BlendOp = .default,
};
pub const ColorTargetState = struct {
    pixel_format: enums.PixelFormat = .default,
    write_mask: enums.ColorMask = .default,
    blend: BlendState = .{},
};
pub const PipelineDesc = struct {
    _start_canary: u32 = 0,
    compute: bool = false,
    shader: Shader = .{},
    layout: VertexLayoutState = .{},
    depth: DepthState = .{},
    stencil: StencilState = .{},
    color_count: i32 = 0,
    colors: [8]ColorTargetState = std.mem.zeroes([8]ColorTargetState),
    primitive_type: enums.PrimitiveType = .default,
    index_type: enums.IndexType = .default,
    cull_mode: enums.CullMode = .default,
    face_winding: enums.FaceWinding = .default,
    sample_count: i32 = 0,
    blend_color: Color = .{},
    alpha_to_coverage_enabled: bool = false,
    label: ?[*:0]const u8 = null,
    _end_canary: u32 = 0,
};
pub const BufferViewDesc = struct {
    buffer: Buffer = .{},
    offset: i32 = 0,
};
pub const ImageViewDesc = struct {
    image: Image = .{},
    mip_level: i32 = 0,
    slice: i32 = 0,
};
pub const TextureViewRange = struct {
    base: i32 = 0,
    count: i32 = 0,
};
pub const TextureViewDesc = struct {
    image: Image = .{},
    mip_levels: TextureViewRange = .{},
    slices: TextureViewRange = .{},
};
pub const ViewDesc = struct {
    _start_canary: u32 = 0,
    texture: TextureViewDesc = .{},
    storage_buffer: BufferViewDesc = .{},
    storage_image: ImageViewDesc = .{},
    color_attachment: ImageViewDesc = .{},
    resolve_attachment: ImageViewDesc = .{},
    depth_stencil_attachment: ImageViewDesc = .{},
    label: ?[*:0]const u8 = null,
    _end_canary: u32 = 0,
};
pub const TraceHooks = struct {
    user_data: ?*anyopaque = null,
    reset_state_cache: ?*const fn (user_data: ?*anyopaque) void = null,
    make_buffer: ?*const fn (desc: ?*const BufferDesc, result: Buffer, user_data: ?*anyopaque) void = null,
    make_image: ?*const fn (desc: ?*const ImageDesc, result: Image, user_data: ?*anyopaque) void = null,
    make_sampler: ?*const fn (desc: ?*const SamplerDesc, result: Sampler, user_data: ?*anyopaque) void = null,
    make_shader: ?*const fn (desc: ?*const ShaderDesc, result: Shader, user_data: ?*anyopaque) void = null,
    make_pipeline: ?*const fn (desc: ?*const PipelineDesc, result: Pipeline, user_data: ?*anyopaque) void = null,
    make_view: ?*const fn (desc: ?*const ViewDesc, result: View, user_data: ?*anyopaque) void = null,
    destroy_buffer: ?*const fn (buf: Buffer, user_data: ?*anyopaque) void = null,
    destroy_image: ?*const fn (img: Image, user_data: ?*anyopaque) void = null,
    destroy_sampler: ?*const fn (smp: Sampler, user_data: ?*anyopaque) void = null,
    destroy_shader: ?*const fn (shd: Shader, user_data: ?*anyopaque) void = null,
    destroy_pipeline: ?*const fn (pip: Pipeline, user_data: ?*anyopaque) void = null,
    destroy_view: ?*const fn (view: View, user_data: ?*anyopaque) void = null,
    write_buffer_transient: ?*const fn (desc: ?*const WriteBufferDesc, user_data: ?*anyopaque) void = null,
    write_image_transient: ?*const fn (desc: ?*const WriteImageDesc, user_data: ?*anyopaque) void = null,
    write_buffer_unsealed: ?*const fn (desc: ?*const WriteBufferDesc, user_data: ?*anyopaque) void = null,
    write_image_unsealed: ?*const fn (desc: ?*const WriteImageDesc, user_data: ?*anyopaque) void = null,
    seal_buffer: ?*const fn (buf: Buffer, user_data: ?*anyopaque) void = null,
    seal_image: ?*const fn (img: Image, user_data: ?*anyopaque) void = null,
    copy_buffer_to_buffer: ?*const fn (desc: ?*const CopyBufferToBufferDesc, user_data: ?*anyopaque) void = null,
    copy_buffer_to_image: ?*const fn (desc: ?*const CopyBufferToImageDesc, user_data: ?*anyopaque) void = null,
    begin_pass: ?*const fn (pass: ?*const Pass, user_data: ?*anyopaque) void = null,
    apply_viewport: ?*const fn (x: i32, y: i32, width: i32, height: i32, origin_top_left: bool, user_data: ?*anyopaque) void = null,
    apply_scissor_rect: ?*const fn (x: i32, y: i32, width: i32, height: i32, origin_top_left: bool, user_data: ?*anyopaque) void = null,
    apply_pipeline: ?*const fn (pip: Pipeline, user_data: ?*anyopaque) void = null,
    apply_bindings: ?*const fn (bindings: ?*const Bindings, user_data: ?*anyopaque) void = null,
    apply_uniforms: ?*const fn (ub_index: i32, data: ?*const Range, user_data: ?*anyopaque) void = null,
    draw: ?*const fn (base_element: i32, num_elements: i32, num_instances: i32, user_data: ?*anyopaque) void = null,
    draw_ex: ?*const fn (base_element: i32, num_elements: i32, num_instances: i32, base_vertex: i32, base_instance: i32, user_data: ?*anyopaque) void = null,
    dispatch: ?*const fn (num_groups_x: i32, num_groups_y: i32, num_groups_z: i32, user_data: ?*anyopaque) void = null,
    end_pass: ?*const fn (user_data: ?*anyopaque) void = null,
    commit: ?*const fn (user_data: ?*anyopaque) void = null,
    alloc_buffer: ?*const fn (result: Buffer, user_data: ?*anyopaque) void = null,
    alloc_image: ?*const fn (result: Image, user_data: ?*anyopaque) void = null,
    alloc_sampler: ?*const fn (result: Sampler, user_data: ?*anyopaque) void = null,
    alloc_shader: ?*const fn (result: Shader, user_data: ?*anyopaque) void = null,
    alloc_pipeline: ?*const fn (result: Pipeline, user_data: ?*anyopaque) void = null,
    alloc_view: ?*const fn (result: View, user_data: ?*anyopaque) void = null,
    dealloc_buffer: ?*const fn (buf_id: Buffer, user_data: ?*anyopaque) void = null,
    dealloc_image: ?*const fn (img_id: Image, user_data: ?*anyopaque) void = null,
    dealloc_sampler: ?*const fn (smp_id: Sampler, user_data: ?*anyopaque) void = null,
    dealloc_shader: ?*const fn (shd_id: Shader, user_data: ?*anyopaque) void = null,
    dealloc_pipeline: ?*const fn (pip_id: Pipeline, user_data: ?*anyopaque) void = null,
    dealloc_view: ?*const fn (view_id: View, user_data: ?*anyopaque) void = null,
    init_buffer: ?*const fn (buf_id: Buffer, desc: ?*const BufferDesc, user_data: ?*anyopaque) void = null,
    init_image: ?*const fn (img_id: Image, desc: ?*const ImageDesc, user_data: ?*anyopaque) void = null,
    init_sampler: ?*const fn (smp_id: Sampler, desc: ?*const SamplerDesc, user_data: ?*anyopaque) void = null,
    init_shader: ?*const fn (shd_id: Shader, desc: ?*const ShaderDesc, user_data: ?*anyopaque) void = null,
    init_pipeline: ?*const fn (pip_id: Pipeline, desc: ?*const PipelineDesc, user_data: ?*anyopaque) void = null,
    init_view: ?*const fn (view_id: View, desc: ?*const ViewDesc, user_data: ?*anyopaque) void = null,
    uninit_buffer: ?*const fn (buf_id: Buffer, user_data: ?*anyopaque) void = null,
    uninit_image: ?*const fn (img_id: Image, user_data: ?*anyopaque) void = null,
    uninit_sampler: ?*const fn (smp_id: Sampler, user_data: ?*anyopaque) void = null,
    uninit_shader: ?*const fn (shd_id: Shader, user_data: ?*anyopaque) void = null,
    uninit_pipeline: ?*const fn (pip_id: Pipeline, user_data: ?*anyopaque) void = null,
    uninit_view: ?*const fn (view_id: View, user_data: ?*anyopaque) void = null,
    fail_buffer: ?*const fn (buf_id: Buffer, user_data: ?*anyopaque) void = null,
    fail_image: ?*const fn (img_id: Image, user_data: ?*anyopaque) void = null,
    fail_sampler: ?*const fn (smp_id: Sampler, user_data: ?*anyopaque) void = null,
    fail_shader: ?*const fn (shd_id: Shader, user_data: ?*anyopaque) void = null,
    fail_pipeline: ?*const fn (pip_id: Pipeline, user_data: ?*anyopaque) void = null,
    fail_view: ?*const fn (view_id: View, user_data: ?*anyopaque) void = null,
    push_debug_group: ?*const fn (name: ?[*:0]const u8, user_data: ?*anyopaque) void = null,
    pop_debug_group: ?*const fn (user_data: ?*anyopaque) void = null,
};
pub const SlotInfo = struct {
    state: enums.ResourceState = .initial,
    res_id: u32 = 0,
    uninit_count: u32 = 0,
};
pub const BufferInfo = struct {
    slot: SlotInfo = .{},
    num_slots: i32 = 0,
    active_slot: i32 = 0,
};
pub const ImageInfo = struct {
    slot: SlotInfo = .{},
    num_slots: i32 = 0,
    active_slot: i32 = 0,
};
pub const SamplerInfo = struct {
    slot: SlotInfo = .{},
};
pub const ShaderInfo = struct {
    slot: SlotInfo = .{},
};
pub const PipelineInfo = struct {
    slot: SlotInfo = .{},
};
pub const ViewInfo = struct {
    slot: SlotInfo = .{},
};
pub const FrameStatsGl = struct {
    num_bind_buffer: u32 = 0,
    num_active_texture: u32 = 0,
    num_bind_texture: u32 = 0,
    num_bind_sampler: u32 = 0,
    num_bind_image_texture: u32 = 0,
    num_use_program: u32 = 0,
    num_render_state: u32 = 0,
    num_vertex_attrib_pointer: u32 = 0,
    num_vertex_attrib_divisor: u32 = 0,
    num_enable_vertex_attrib_array: u32 = 0,
    num_disable_vertex_attrib_array: u32 = 0,
    num_uniform: u32 = 0,
    num_memory_barriers: u32 = 0,
};
pub const FrameStatsD3d11Pass = struct {
    num_om_set_render_targets: u32 = 0,
    num_clear_render_target_view: u32 = 0,
    num_clear_depth_stencil_view: u32 = 0,
    num_resolve_subresource: u32 = 0,
};
pub const FrameStatsD3d11Pipeline = struct {
    num_rs_set_state: u32 = 0,
    num_om_set_depth_stencil_state: u32 = 0,
    num_om_set_blend_state: u32 = 0,
    num_ia_set_primitive_topology: u32 = 0,
    num_ia_set_input_layout: u32 = 0,
    num_vs_set_shader: u32 = 0,
    num_vs_set_constant_buffers: u32 = 0,
    num_ps_set_shader: u32 = 0,
    num_ps_set_constant_buffers: u32 = 0,
    num_cs_set_shader: u32 = 0,
    num_cs_set_constant_buffers: u32 = 0,
};
pub const FrameStatsD3d11Bindings = struct {
    num_ia_set_vertex_buffers: u32 = 0,
    num_ia_set_index_buffer: u32 = 0,
    num_vs_set_shader_resources: u32 = 0,
    num_vs_set_samplers: u32 = 0,
    num_ps_set_shader_resources: u32 = 0,
    num_ps_set_samplers: u32 = 0,
    num_cs_set_shader_resources: u32 = 0,
    num_cs_set_samplers: u32 = 0,
    num_cs_set_unordered_access_views: u32 = 0,
    num_om_set_rts_and_uavs: u32 = 0,
};
pub const FrameStatsD3d11Uniforms = struct {
    num_update_subresource: u32 = 0,
};
pub const FrameStatsD3d11Draw = struct {
    num_draw_indexed_instanced: u32 = 0,
    num_draw_indexed: u32 = 0,
    num_draw_instanced: u32 = 0,
    num_draw: u32 = 0,
};
pub const FrameStatsD3d11 = struct {
    pass: FrameStatsD3d11Pass = .{},
    pipeline: FrameStatsD3d11Pipeline = .{},
    bindings: FrameStatsD3d11Bindings = .{},
    uniforms: FrameStatsD3d11Uniforms = .{},
    draw: FrameStatsD3d11Draw = .{},
    num_map: u32 = 0,
    num_unmap: u32 = 0,
};
pub const FrameStatsMetalIdpool = struct {
    num_added: u32 = 0,
    num_released: u32 = 0,
    num_garbage_collected: u32 = 0,
};
pub const FrameStatsMetalPipeline = struct {
    num_set_blend_color: u32 = 0,
    num_set_cull_mode: u32 = 0,
    num_set_front_facing_winding: u32 = 0,
    num_set_stencil_reference_value: u32 = 0,
    num_set_depth_bias: u32 = 0,
    num_set_render_pipeline_state: u32 = 0,
    num_set_depth_stencil_state: u32 = 0,
};
pub const FrameStatsMetalBindings = struct {
    num_set_vertex_buffer: u32 = 0,
    num_set_vertex_buffer_offset: u32 = 0,
    num_skip_redundant_vertex_buffer: u32 = 0,
    num_set_vertex_texture: u32 = 0,
    num_skip_redundant_vertex_texture: u32 = 0,
    num_set_vertex_sampler_state: u32 = 0,
    num_skip_redundant_vertex_sampler_state: u32 = 0,
    num_set_fragment_buffer: u32 = 0,
    num_set_fragment_buffer_offset: u32 = 0,
    num_skip_redundant_fragment_buffer: u32 = 0,
    num_set_fragment_texture: u32 = 0,
    num_skip_redundant_fragment_texture: u32 = 0,
    num_set_fragment_sampler_state: u32 = 0,
    num_skip_redundant_fragment_sampler_state: u32 = 0,
    num_set_compute_buffer: u32 = 0,
    num_set_compute_buffer_offset: u32 = 0,
    num_skip_redundant_compute_buffer: u32 = 0,
    num_set_compute_texture: u32 = 0,
    num_skip_redundant_compute_texture: u32 = 0,
    num_set_compute_sampler_state: u32 = 0,
    num_skip_redundant_compute_sampler_state: u32 = 0,
};
pub const FrameStatsMetalUniforms = struct {
    num_set_vertex_buffer_offset: u32 = 0,
    num_set_fragment_buffer_offset: u32 = 0,
    num_set_compute_buffer_offset: u32 = 0,
};
pub const FrameStatsMetal = struct {
    idpool: FrameStatsMetalIdpool = .{},
    pipeline: FrameStatsMetalPipeline = .{},
    bindings: FrameStatsMetalBindings = .{},
    uniforms: FrameStatsMetalUniforms = .{},
};
pub const FrameStatsWgpuUniforms = struct {
    num_set_bindgroup: u32 = 0,
    size_write_buffer: u32 = 0,
};
pub const FrameStatsWgpuBindings = struct {
    num_set_vertex_buffer: u32 = 0,
    num_skip_redundant_vertex_buffer: u32 = 0,
    num_set_index_buffer: u32 = 0,
    num_skip_redundant_index_buffer: u32 = 0,
    num_create_bindgroup: u32 = 0,
    num_discard_bindgroup: u32 = 0,
    num_set_bindgroup: u32 = 0,
    num_skip_redundant_bindgroup: u32 = 0,
    num_bindgroup_cache_hits: u32 = 0,
    num_bindgroup_cache_misses: u32 = 0,
    num_bindgroup_cache_collisions: u32 = 0,
    num_bindgroup_cache_invalidates: u32 = 0,
    num_bindgroup_cache_hash_vs_key_mismatch: u32 = 0,
};
pub const FrameStatsWgpu = struct {
    uniforms: FrameStatsWgpuUniforms = .{},
    bindings: FrameStatsWgpuBindings = .{},
};
/// D3D12 submissions, including the blocking one-shot compatibility path.
pub const FrameStatsD3d12 = struct {
    num_queue_submits: u32 = 0,
    num_one_shot_submits: u32 = 0,
};
pub const FrameStatsVk = struct {
    num_pipeline_cache_header_repairs: u32 = 0,
    num_queue_submits: u32 = 0,
    num_queue_wait_idle: u32 = 0,
    num_cmd_pipeline_barrier: u32 = 0,
    num_allocate_memory: u32 = 0,
    num_free_memory: u32 = 0,
    size_allocate_memory: u32 = 0,
    num_delete_queue_added: u32 = 0,
    num_delete_queue_collected: u32 = 0,
    num_cmd_copy_buffer: u32 = 0,
    num_cmd_copy_buffer_to_image: u32 = 0,
    num_cmd_set_descriptor_buffer_offsets: u32 = 0,
    size_descriptor_buffer_writes: u32 = 0,
};
pub const FrameResourceStats = struct {
    allocated: u32 = 0,
    deallocated: u32 = 0,
    inited: u32 = 0,
    uninited: u32 = 0,
};
pub const TotalResourceStats = struct {
    alive: u32 = 0,
    free: u32 = 0,
    allocated: u32 = 0,
    deallocated: u32 = 0,
    inited: u32 = 0,
    uninited: u32 = 0,
};
pub const TotalStats = struct {
    buffers: TotalResourceStats = .{},
    images: TotalResourceStats = .{},
    samplers: TotalResourceStats = .{},
    views: TotalResourceStats = .{},
    shaders: TotalResourceStats = .{},
    pipelines: TotalResourceStats = .{},
};
pub const FrameStats = struct {
    frame_index: u32 = 0,
    num_passes: u32 = 0,
    num_apply_viewport: u32 = 0,
    num_apply_scissor_rect: u32 = 0,
    num_apply_pipeline: u32 = 0,
    num_apply_bindings: u32 = 0,
    num_apply_uniforms: u32 = 0,
    num_draw: u32 = 0,
    num_draw_ex: u32 = 0,
    num_dispatch: u32 = 0,
    num_write_buffer_transient: u32 = 0,
    num_write_image_transient: u32 = 0,
    num_write_buffer_unsealed: u32 = 0,
    num_write_image_unsealed: u32 = 0,
    num_seal_buffer: u32 = 0,
    num_seal_image: u32 = 0,
    num_copy_buffer_to_buffer: u32 = 0,
    num_copy_buffer_to_image: u32 = 0,
    size_apply_uniforms: u32 = 0,
    size_copy_buffer_to_buffer: u32 = 0,
    size_copy_buffer_to_image: u32 = 0,
    buffers: FrameResourceStats = .{},
    images: FrameResourceStats = .{},
    samplers: FrameResourceStats = .{},
    views: FrameResourceStats = .{},
    shaders: FrameResourceStats = .{},
    pipelines: FrameResourceStats = .{},
    gl: FrameStatsGl = .{},
    d3d11: FrameStatsD3d11 = .{},
    d3d12: FrameStatsD3d12 = .{},
    metal: FrameStatsMetal = .{},
    wgpu: FrameStatsWgpu = .{},
    vk: FrameStatsVk = .{},
};
pub const Stats = struct {
    prev_frame: FrameStats = .{},
    cur_frame: FrameStats = .{},
    total: TotalStats = .{},
};
pub const EnvironmentDefaults = struct {
    color_format: enums.PixelFormat = .default,
    depth_format: enums.PixelFormat = .default,
    sample_count: i32 = 0,
};
pub const MetalEnvironment = struct {
    device: ?*const anyopaque = null,
};
/// D3D12 device and direct command queue (zicr extension): ID3D12Device and ID3D12CommandQueue.
pub const D3d12Environment = struct {
    device: ?*const anyopaque = null,
    queue: ?*const anyopaque = null,
};
pub const D3d11Environment = struct {
    device: ?*const anyopaque = null,
    device_context: ?*const anyopaque = null,
};
pub const WgpuEnvironment = struct {
    instance: ?*const anyopaque = null,
    wait_timeout_ns: u64 = 0,
    device: ?*const anyopaque = null,
    /// Resolves webgpu.h functions by name, typically `wgpuGetProcAddress` of
    /// the WebGPU implementation (Dawn, wgpu-native or the browser shim).
    get_proc_address: ?*const fn (name: [:0]const u8, user_data: ?*anyopaque) ?*const anyopaque = null,
    user_data: ?*anyopaque = null,
};
pub const VulkanEnvironment = struct {
    instance: ?*const anyopaque = null,
    physical_device: ?*const anyopaque = null,
    device: ?*const anyopaque = null,
    queue: ?*const anyopaque = null,
    queue_family_index: u32 = 0,
    /// `vkGetInstanceProcAddr` of the Vulkan loader that created `instance`;
    /// every other Vulkan function is resolved through it.
    get_instance_proc_addr: ?*const anyopaque = null,
};
pub const GlEnvironment = struct {
    /// Resolve driver symbols from the application's current GL/GLES context.
    get_proc_address: ?*const fn (name: [:0]const u8, user_data: ?*anyopaque) ?*const anyopaque = null,
    user_data: ?*anyopaque = null,
};
pub const Environment = struct {
    gl: GlEnvironment = .{},
    defaults: EnvironmentDefaults = .{},
    metal: MetalEnvironment = .{},
    d3d11: D3d11Environment = .{},
    d3d12: D3d12Environment = .{},
    wgpu: WgpuEnvironment = .{},
    vulkan: VulkanEnvironment = .{},
};
pub const CommitListener = struct {
    func: ?*const fn (user_data: ?*anyopaque) void = null,
    user_data: ?*anyopaque = null,
};
pub const Allocator = struct {
    alloc_fn: ?*const fn (size: usize, user_data: ?*anyopaque) ?*anyopaque = null,
    free_fn: ?*const fn (ptr: ?*anyopaque, user_data: ?*anyopaque) void = null,
    user_data: ?*anyopaque = null,
};
pub const Logger = struct {
    func: ?*const fn (tag: ?[*:0]const u8, log_level: u32, log_item_id: u32, message_or_null: ?[*:0]const u8, line_nr: u32, filename_or_null: ?[*:0]const u8, user_data: ?*anyopaque) void = null,
    user_data: ?*anyopaque = null,
};
pub const D3d11Desc = struct {
    shader_debugging: bool = false,
};
pub const MetalDesc = struct {
    force_managed_storage_mode: bool = false,
    use_command_buffer_with_retained_references: bool = false,
};
pub const WgpuDesc = struct {
    disable_bindgroups_cache: bool = false,
    bindgroups_cache_size: i32 = 0,
};
pub const VulkanDesc = struct {
    pipeline_cache_data: Range = .{},
    use_descriptor_buffer: bool = false,
    descriptor_set_capacity: u32 = 4096,
    copy_staging_buffer_size: i32 = 0,
    transient_staging_buffer_size: i32 = 0,
    descriptor_buffer_size: i32 = 0,
};
pub const Desc = struct {
    _start_canary: u32 = 0,
    buffer_pool_size: i32 = 0,
    image_pool_size: i32 = 0,
    sampler_pool_size: i32 = 0,
    shader_pool_size: i32 = 0,
    pipeline_pool_size: i32 = 0,
    view_pool_size: i32 = 0,
    uniform_buffer_size: i32 = 0,
    max_commit_listeners: i32 = 0,
    disable_validation: bool = false,
    enforce_portable_limits: bool = false,
    d3d11: D3d11Desc = .{},
    metal: MetalDesc = .{},
    wgpu: WgpuDesc = .{},
    vulkan: VulkanDesc = .{},
    allocator: Allocator = .{},
    logger: Logger = .{},
    environment: Environment = .{},
    _end_canary: u32 = 0,
};
pub const D3d11BufferInfo = struct {
    buf: ?*const anyopaque = null,
};
pub const D3d11ImageInfo = struct {
    tex2d: ?*const anyopaque = null,
    tex3d: ?*const anyopaque = null,
    res: ?*const anyopaque = null,
};
pub const D3d11SamplerInfo = struct {
    smp: ?*const anyopaque = null,
};
pub const D3d11ShaderInfo = struct {
    cbufs: [8]?*const anyopaque = std.mem.zeroes([8]?*const anyopaque),
    vs: ?*const anyopaque = null,
    fs: ?*const anyopaque = null,
};
pub const D3d11PipelineInfo = struct {
    il: ?*const anyopaque = null,
    rs: ?*const anyopaque = null,
    dss: ?*const anyopaque = null,
    bs: ?*const anyopaque = null,
};
pub const D3d11ViewInfo = struct {
    srv: ?*const anyopaque = null,
    uav: ?*const anyopaque = null,
    rtv: ?*const anyopaque = null,
    dsv: ?*const anyopaque = null,
};
pub const MtlBufferInfo = struct {
    buf: [2]?*const anyopaque = std.mem.zeroes([2]?*const anyopaque),
    active_slot: i32 = 0,
};
pub const MtlImageInfo = struct {
    tex: [2]?*const anyopaque = std.mem.zeroes([2]?*const anyopaque),
    active_slot: i32 = 0,
};
pub const MtlSamplerInfo = struct {
    smp: ?*const anyopaque = null,
};
pub const MtlShaderInfo = struct {
    vertex_lib: ?*const anyopaque = null,
    fragment_lib: ?*const anyopaque = null,
    vertex_func: ?*const anyopaque = null,
    fragment_func: ?*const anyopaque = null,
};
pub const MtlPipelineInfo = struct {
    rps: ?*const anyopaque = null,
    dss: ?*const anyopaque = null,
};
pub const WgpuBufferInfo = struct {
    buf: ?*const anyopaque = null,
};
pub const WgpuImageInfo = struct {
    tex: ?*const anyopaque = null,
};
pub const WgpuSamplerInfo = struct {
    smp: ?*const anyopaque = null,
};
pub const WgpuShaderInfo = struct {
    vs_mod: ?*const anyopaque = null,
    fs_mod: ?*const anyopaque = null,
    bgl: ?*const anyopaque = null,
};
pub const WgpuPipelineInfo = struct {
    render_pipeline: ?*const anyopaque = null,
    compute_pipeline: ?*const anyopaque = null,
};
pub const WgpuViewInfo = struct {
    view: ?*const anyopaque = null,
};
pub const GlBufferInfo = struct {
    buf: [2]u32 = std.mem.zeroes([2]u32),
    active_slot: i32 = 0,
};
pub const GlImageInfo = struct {
    tex: [2]u32 = std.mem.zeroes([2]u32),
    tex_target: u32 = 0,
    active_slot: i32 = 0,
};
pub const GlSamplerInfo = struct {
    smp: u32 = 0,
};
pub const GlShaderInfo = struct {
    prog: u32 = 0,
};
pub const GlViewInfo = struct {
    tex_view: [2]u32 = std.mem.zeroes([2]u32),
    msaa_render_buffer: u32 = 0,
    msaa_resolve_frame_buffer: u32 = 0,
};
