//! D3D11 driver data and COM calls, derived from the installed Windows SDK.
//! Foreign driver layouts are confined here; rendering logic uses native Zig types.
//! No Sokol functions or external function symbols are declared.
const std = @import("std");
const builtin = @import("builtin");
pub const call_conv = @import("../dxgi/com.zig").call_conv;
pub const Object = @import("../dxgi/com.zig").Object;
pub const Guid = @import("../dxgi/com.zig").Guid;
pub const Rect = extern struct { left: i32 = 0, top: i32 = 0, right: i32 = 0, bottom: i32 = 0 };

pub const BlendDesc = extern struct {
    alpha_to_coverage_enable: i32 = 0,
    independent_blend_enable: i32 = 0,
    render_target: [8]RenderTargetBlendDesc = @splat(.{}),
};

pub const Box = extern struct {
    left: u32 = 0,
    top: u32 = 0,
    front: u32 = 0,
    right: u32 = 0,
    bottom: u32 = 0,
    back: u32 = 0,
};

pub const BufferDesc = extern struct {
    byte_width: u32 = 0,
    usage: u32 = 0,
    bind_flags: u32 = 0,
    cpu_access_flags: u32 = 0,
    misc_flags: u32 = 0,
    structure_byte_stride: u32 = 0,
};

pub const DepthStencilDesc = extern struct {
    depth_enable: i32 = 0,
    depth_write_mask: u32 = 0,
    depth_func: u32 = 0,
    stencil_enable: i32 = 0,
    stencil_read_mask: u8 = 0,
    stencil_write_mask: u8 = 0,
    front_face: StencilOpDesc = .{},
    back_face: StencilOpDesc = .{},
};

pub const StencilOpDesc = extern struct {
    stencil_fail_op: u32 = 0,
    stencil_depth_fail_op: u32 = 0,
    stencil_pass_op: u32 = 0,
    stencil_func: u32 = 0,
};

pub const DepthStencilViewDesc = extern struct {
    format: u32 = 0,
    view_dimension: u32 = 0,
    flags: u32 = 0,
    data: DepthStencilViewDescData = std.mem.zeroes(DepthStencilViewDescData),
};

pub const InputElementDesc = extern struct {
    semantic_name: ?[*:0]const u8 = null,
    semantic_index: u32 = 0,
    format: u32 = 0,
    input_slot: u32 = 0,
    aligned_byte_offset: u32 = 0,
    input_slot_class: u32 = 0,
    instance_data_step_rate: u32 = 0,
};

pub const MappedSubresource = extern struct {
    data: ?*anyopaque = null,
    row_pitch: u32 = 0,
    depth_pitch: u32 = 0,
};

pub const RasterizerDesc = extern struct {
    fill_mode: u32 = 0,
    cull_mode: u32 = 0,
    front_counter_clockwise: i32 = 0,
    depth_bias: i32 = 0,
    depth_bias_clamp: f32 = 0,
    slope_scaled_depth_bias: f32 = 0,
    depth_clip_enable: i32 = 0,
    scissor_enable: i32 = 0,
    multisample_enable: i32 = 0,
    antialiased_line_enable: i32 = 0,
};

pub const RenderTargetBlendDesc = extern struct {
    blend_enable: i32 = 0,
    src_blend: u32 = 0,
    dest_blend: u32 = 0,
    blend_op: u32 = 0,
    src_blend_alpha: u32 = 0,
    dest_blend_alpha: u32 = 0,
    blend_op_alpha: u32 = 0,
    render_target_write_mask: u8 = 0,
};

pub const RenderTargetViewDesc = extern struct {
    format: u32 = 0,
    view_dimension: u32 = 0,
    data: RenderTargetViewDescData = std.mem.zeroes(RenderTargetViewDescData),
};

pub const BufferRtv = extern struct {
    first_element: u32 = 0,
    num_elements: u32 = 0,
};

pub const SamplerDesc = extern struct {
    filter: u32 = 0,
    address_u: u32 = 0,
    address_v: u32 = 0,
    address_w: u32 = 0,
    mip_lod_bias: f32 = 0,
    max_anisotropy: u32 = 0,
    comparison_func: u32 = 0,
    border_color: [4]f32 = @splat(0),
    min_lod: f32 = 0,
    max_lod: f32 = 0,
};

pub const ShaderResourceViewDesc = extern struct {
    format: u32 = 0,
    view_dimension: u32 = 0,
    data: ShaderResourceViewDescData = std.mem.zeroes(ShaderResourceViewDescData),
};

pub const BufferexSrv = extern struct {
    first_element: u32 = 0,
    num_elements: u32 = 0,
    flags: u32 = 0,
};

pub const BufferSrv = extern struct {
    first_element: u32 = 0,
    num_elements: u32 = 0,
};

pub const SubresourceData = extern struct {
    data: ?*const anyopaque = null,
    sys_mem_pitch: u32 = 0,
    sys_mem_slice_pitch: u32 = 0,
};

pub const Tex1dArrayDsv = extern struct {
    mip_slice: u32 = 0,
    first_array_slice: u32 = 0,
    array_size: u32 = 0,
};

pub const Tex1dArrayRtv = extern struct {
    mip_slice: u32 = 0,
    first_array_slice: u32 = 0,
    array_size: u32 = 0,
};

pub const Tex1dArraySrv = extern struct {
    most_detailed_mip: u32 = 0,
    mip_levels: u32 = 0,
    first_array_slice: u32 = 0,
    array_size: u32 = 0,
};

pub const Tex1dDsv = extern struct {
    mip_slice: u32 = 0,
};

pub const Tex1dRtv = extern struct {
    mip_slice: u32 = 0,
};

pub const Tex1dSrv = extern struct {
    most_detailed_mip: u32 = 0,
    mip_levels: u32 = 0,
};

pub const Tex2dmsArrayDsv = extern struct {
    first_array_slice: u32 = 0,
    array_size: u32 = 0,
};

pub const Tex2dmsArrayRtv = extern struct {
    first_array_slice: u32 = 0,
    array_size: u32 = 0,
};

pub const Tex2dmsArraySrv = extern struct {
    first_array_slice: u32 = 0,
    array_size: u32 = 0,
};

pub const Tex2dmsDsv = extern struct {
    unused_field_nothing_to_define: u32 = 0,
};

pub const Tex2dmsRtv = extern struct {
    unused_field_nothing_to_define: u32 = 0,
};

pub const Tex2dmsSrv = extern struct {
    unused_field_nothing_to_define: u32 = 0,
};

pub const Tex2dArrayDsv = extern struct {
    mip_slice: u32 = 0,
    first_array_slice: u32 = 0,
    array_size: u32 = 0,
};

pub const Tex2dArrayRtv = extern struct {
    mip_slice: u32 = 0,
    first_array_slice: u32 = 0,
    array_size: u32 = 0,
};

pub const Tex2dArraySrv = extern struct {
    most_detailed_mip: u32 = 0,
    mip_levels: u32 = 0,
    first_array_slice: u32 = 0,
    array_size: u32 = 0,
};

pub const Tex2dDsv = extern struct {
    mip_slice: u32 = 0,
};

pub const Tex2dRtv = extern struct {
    mip_slice: u32 = 0,
};

pub const Tex2dSrv = extern struct {
    most_detailed_mip: u32 = 0,
    mip_levels: u32 = 0,
};

pub const Tex3dRtv = extern struct {
    mip_slice: u32 = 0,
    first_w_slice: u32 = 0,
    w_size: u32 = 0,
};

pub const Tex3dSrv = extern struct {
    most_detailed_mip: u32 = 0,
    mip_levels: u32 = 0,
};

pub const TexcubeArraySrv = extern struct {
    most_detailed_mip: u32 = 0,
    mip_levels: u32 = 0,
    first2_d_array_face: u32 = 0,
    num_cubes: u32 = 0,
};

pub const TexcubeSrv = extern struct {
    most_detailed_mip: u32 = 0,
    mip_levels: u32 = 0,
};

pub const Texture2DDesc = extern struct {
    width: u32 = 0,
    height: u32 = 0,
    mip_levels: u32 = 0,
    array_size: u32 = 0,
    format: u32 = 0,
    sample_desc: SampleDesc = .{},
    usage: u32 = 0,
    bind_flags: u32 = 0,
    cpu_access_flags: u32 = 0,
    misc_flags: u32 = 0,
};

pub const Texture3DDesc = extern struct {
    width: u32 = 0,
    height: u32 = 0,
    depth: u32 = 0,
    mip_levels: u32 = 0,
    format: u32 = 0,
    usage: u32 = 0,
    bind_flags: u32 = 0,
    cpu_access_flags: u32 = 0,
    misc_flags: u32 = 0,
};

pub const UnorderedAccessViewDesc = extern struct {
    format: u32 = 0,
    view_dimension: u32 = 0,
    data: UnorderedAccessViewDescData = std.mem.zeroes(UnorderedAccessViewDescData),
};

pub const BufferUav = extern struct {
    first_element: u32 = 0,
    num_elements: u32 = 0,
    flags: u32 = 0,
};

pub const Tex1dArrayUav = extern struct {
    mip_slice: u32 = 0,
    first_array_slice: u32 = 0,
    array_size: u32 = 0,
};

pub const Tex1dUav = extern struct {
    mip_slice: u32 = 0,
};

pub const Tex2dArrayUav = extern struct {
    mip_slice: u32 = 0,
    first_array_slice: u32 = 0,
    array_size: u32 = 0,
};

pub const Tex2dUav = extern struct {
    mip_slice: u32 = 0,
};

pub const Tex3dUav = extern struct {
    mip_slice: u32 = 0,
    first_w_slice: u32 = 0,
    w_size: u32 = 0,
};

pub const Viewport = extern struct {
    top_left_x: f32 = 0,
    top_left_y: f32 = 0,
    width: f32 = 0,
    height: f32 = 0,
    min_depth: f32 = 0,
    max_depth: f32 = 0,
};

pub fn checkFormatSupport(object: *Object, format: u32, p_format_support: ?[*]u32) i32 {
    return invoke(29, *const fn (*Object, u32, ?[*]u32) callconv(call_conv) i32, object, .{ format, p_format_support });
}

pub fn omSetRenderTargets(object: *Object, num_views: u32, pp_render_target_views: ?[*]const ?*Object, p_depth_stencil_view: ?*Object) void {
    return invoke(33, *const fn (*Object, u32, ?[*]const ?*Object, ?*Object) callconv(call_conv) void, object, .{ num_views, pp_render_target_views, p_depth_stencil_view });
}

pub fn omSetRenderTargetsAndUnorderedAccessViews(object: *Object, num_views: u32, pp_render_target_views: ?[*]const ?*Object, p_depth_stencil_view: ?*Object, uav_start_slot: u32, num_ua_vs: u32, pp_unordered_access_views: ?[*]const ?*Object, p_uav_initial_counts: ?[*]const u32) void {
    return invoke(34, *const fn (*Object, u32, ?[*]const ?*Object, ?*Object, u32, u32, ?[*]const ?*Object, ?[*]const u32) callconv(call_conv) void, object, .{ num_views, pp_render_target_views, p_depth_stencil_view, uav_start_slot, num_ua_vs, pp_unordered_access_views, p_uav_initial_counts });
}

pub fn rsSetState(object: *Object, p_rasterizer_state: ?*Object) void {
    return invoke(43, *const fn (*Object, ?*Object) callconv(call_conv) void, object, .{p_rasterizer_state});
}

pub fn omSetDepthStencilState(object: *Object, p_depth_stencil_state: ?*Object, stencil_ref: u32) void {
    return invoke(36, *const fn (*Object, ?*Object, u32) callconv(call_conv) void, object, .{ p_depth_stencil_state, stencil_ref });
}

pub fn omSetBlendState(object: *Object, p_blend_state: ?*Object, blend_factor: ?[*]const f32, sample_mask: u32) void {
    return invoke(35, *const fn (*Object, ?*Object, ?[*]const f32, u32) callconv(call_conv) void, object, .{ p_blend_state, blend_factor, sample_mask });
}

pub fn iaSetVertexBuffers(object: *Object, start_slot: u32, num_buffers: u32, pp_vertex_buffers: ?[*]const ?*Object, p_strides: ?[*]const u32, p_offsets: ?[*]const u32) void {
    return invoke(18, *const fn (*Object, u32, u32, ?[*]const ?*Object, ?[*]const u32, ?[*]const u32) callconv(call_conv) void, object, .{ start_slot, num_buffers, pp_vertex_buffers, p_strides, p_offsets });
}

pub fn iaSetIndexBuffer(object: *Object, p_index_buffer: ?*Object, format: u32, offset: u32) void {
    return invoke(19, *const fn (*Object, ?*Object, u32, u32) callconv(call_conv) void, object, .{ p_index_buffer, format, offset });
}

pub fn iaSetInputLayout(object: *Object, p_input_layout: ?*Object) void {
    return invoke(17, *const fn (*Object, ?*Object) callconv(call_conv) void, object, .{p_input_layout});
}

pub fn vsSetShader(object: *Object, p_vertex_shader: ?*Object, pp_class_instances: ?[*]const ?*Object, num_class_instances: u32) void {
    return invoke(11, *const fn (*Object, ?*Object, ?[*]const ?*Object, u32) callconv(call_conv) void, object, .{ p_vertex_shader, pp_class_instances, num_class_instances });
}

pub fn psSetShader(object: *Object, p_pixel_shader: ?*Object, pp_class_instances: ?[*]const ?*Object, num_class_instances: u32) void {
    return invoke(9, *const fn (*Object, ?*Object, ?[*]const ?*Object, u32) callconv(call_conv) void, object, .{ p_pixel_shader, pp_class_instances, num_class_instances });
}

pub fn csSetShader(object: *Object, p_compute_shader: ?*Object, pp_class_instances: ?[*]const ?*Object, num_class_instances: u32) void {
    return invoke(69, *const fn (*Object, ?*Object, ?[*]const ?*Object, u32) callconv(call_conv) void, object, .{ p_compute_shader, pp_class_instances, num_class_instances });
}

pub fn vsSetConstantBuffers(object: *Object, start_slot: u32, num_buffers: u32, pp_constant_buffers: ?[*]const ?*Object) void {
    return invoke(7, *const fn (*Object, u32, u32, ?[*]const ?*Object) callconv(call_conv) void, object, .{ start_slot, num_buffers, pp_constant_buffers });
}

pub fn psSetConstantBuffers(object: *Object, start_slot: u32, num_buffers: u32, pp_constant_buffers: ?[*]const ?*Object) void {
    return invoke(16, *const fn (*Object, u32, u32, ?[*]const ?*Object) callconv(call_conv) void, object, .{ start_slot, num_buffers, pp_constant_buffers });
}

pub fn csSetConstantBuffers(object: *Object, start_slot: u32, num_buffers: u32, pp_constant_buffers: ?[*]const ?*Object) void {
    return invoke(71, *const fn (*Object, u32, u32, ?[*]const ?*Object) callconv(call_conv) void, object, .{ start_slot, num_buffers, pp_constant_buffers });
}

pub fn vsSetShaderResources(object: *Object, start_slot: u32, num_views: u32, pp_shader_resource_views: ?[*]const ?*Object) void {
    return invoke(25, *const fn (*Object, u32, u32, ?[*]const ?*Object) callconv(call_conv) void, object, .{ start_slot, num_views, pp_shader_resource_views });
}

pub fn psSetShaderResources(object: *Object, start_slot: u32, num_views: u32, pp_shader_resource_views: ?[*]const ?*Object) void {
    return invoke(8, *const fn (*Object, u32, u32, ?[*]const ?*Object) callconv(call_conv) void, object, .{ start_slot, num_views, pp_shader_resource_views });
}

pub fn csSetShaderResources(object: *Object, start_slot: u32, num_views: u32, pp_shader_resource_views: ?[*]const ?*Object) void {
    return invoke(67, *const fn (*Object, u32, u32, ?[*]const ?*Object) callconv(call_conv) void, object, .{ start_slot, num_views, pp_shader_resource_views });
}

pub fn vsSetSamplers(object: *Object, start_slot: u32, num_samplers: u32, pp_samplers: ?[*]const ?*Object) void {
    return invoke(26, *const fn (*Object, u32, u32, ?[*]const ?*Object) callconv(call_conv) void, object, .{ start_slot, num_samplers, pp_samplers });
}

pub fn psSetSamplers(object: *Object, start_slot: u32, num_samplers: u32, pp_samplers: ?[*]const ?*Object) void {
    return invoke(10, *const fn (*Object, u32, u32, ?[*]const ?*Object) callconv(call_conv) void, object, .{ start_slot, num_samplers, pp_samplers });
}

pub fn csSetSamplers(object: *Object, start_slot: u32, num_samplers: u32, pp_samplers: ?[*]const ?*Object) void {
    return invoke(70, *const fn (*Object, u32, u32, ?[*]const ?*Object) callconv(call_conv) void, object, .{ start_slot, num_samplers, pp_samplers });
}

pub fn csSetUnorderedAccessViews(object: *Object, start_slot: u32, num_ua_vs: u32, pp_unordered_access_views: ?[*]const ?*Object, p_uav_initial_counts: ?[*]const u32) void {
    return invoke(68, *const fn (*Object, u32, u32, ?[*]const ?*Object, ?[*]const u32) callconv(call_conv) void, object, .{ start_slot, num_ua_vs, pp_unordered_access_views, p_uav_initial_counts });
}

pub fn createBuffer(object: *Object, p_desc: ?[*]const BufferDesc, p_initial_data: ?[*]const SubresourceData, pp_buffer: *?*Object) i32 {
    return invoke(3, *const fn (*Object, ?[*]const BufferDesc, ?[*]const SubresourceData, *?*Object) callconv(call_conv) i32, object, .{ p_desc, p_initial_data, pp_buffer });
}

pub fn createTexture2D(object: *Object, p_desc: ?[*]const Texture2DDesc, p_initial_data: ?[*]const SubresourceData, pp_texture2_d: *?*Object) i32 {
    return invoke(5, *const fn (*Object, ?[*]const Texture2DDesc, ?[*]const SubresourceData, *?*Object) callconv(call_conv) i32, object, .{ p_desc, p_initial_data, pp_texture2_d });
}

pub fn createShaderResourceView(object: *Object, p_resource: ?*Object, p_desc: ?[*]const ShaderResourceViewDesc, pp_sr_view: *?*Object) i32 {
    return invoke(7, *const fn (*Object, ?*Object, ?[*]const ShaderResourceViewDesc, *?*Object) callconv(call_conv) i32, object, .{ p_resource, p_desc, pp_sr_view });
}

pub fn createUnorderedAccessView(object: *Object, p_resource: ?*Object, p_desc: ?[*]const UnorderedAccessViewDesc, pp_uav_view: *?*Object) i32 {
    return invoke(8, *const fn (*Object, ?*Object, ?[*]const UnorderedAccessViewDesc, *?*Object) callconv(call_conv) i32, object, .{ p_resource, p_desc, pp_uav_view });
}

pub fn getResource(object: *Object, pp_resource: *?*Object) void {
    return invoke(7, *const fn (*Object, *?*Object) callconv(call_conv) void, object, .{pp_resource});
}

pub fn createTexture3D(object: *Object, p_desc: ?[*]const Texture3DDesc, p_initial_data: ?[*]const SubresourceData, pp_texture3_d: *?*Object) i32 {
    return invoke(6, *const fn (*Object, ?[*]const Texture3DDesc, ?[*]const SubresourceData, *?*Object) callconv(call_conv) i32, object, .{ p_desc, p_initial_data, pp_texture3_d });
}

pub fn createSamplerState(object: *Object, p_sampler_desc: ?[*]const SamplerDesc, pp_sampler_state: *?*Object) i32 {
    return invoke(23, *const fn (*Object, ?[*]const SamplerDesc, *?*Object) callconv(call_conv) i32, object, .{ p_sampler_desc, pp_sampler_state });
}

pub const getBufferPointer = @import("../dxgi/com.zig").getBufferPointer;

pub const getBufferSize = @import("../dxgi/com.zig").getBufferSize;

pub fn createVertexShader(object: *Object, p_shader_bytecode: ?*const anyopaque, bytecode_length: usize, p_class_linkage: ?*Object, pp_vertex_shader: *?*Object) i32 {
    return invoke(12, *const fn (*Object, ?*const anyopaque, usize, ?*Object, *?*Object) callconv(call_conv) i32, object, .{ p_shader_bytecode, bytecode_length, p_class_linkage, pp_vertex_shader });
}

pub fn createPixelShader(object: *Object, p_shader_bytecode: ?*const anyopaque, bytecode_length: usize, p_class_linkage: ?*Object, pp_pixel_shader: *?*Object) i32 {
    return invoke(15, *const fn (*Object, ?*const anyopaque, usize, ?*Object, *?*Object) callconv(call_conv) i32, object, .{ p_shader_bytecode, bytecode_length, p_class_linkage, pp_pixel_shader });
}

pub fn createComputeShader(object: *Object, p_shader_bytecode: ?*const anyopaque, bytecode_length: usize, p_class_linkage: ?*Object, pp_compute_shader: *?*Object) i32 {
    return invoke(18, *const fn (*Object, ?*const anyopaque, usize, ?*Object, *?*Object) callconv(call_conv) i32, object, .{ p_shader_bytecode, bytecode_length, p_class_linkage, pp_compute_shader });
}

pub fn createInputLayout(object: *Object, p_input_element_descs: ?[*]const InputElementDesc, num_elements: u32, p_shader_bytecode_with_input_signature: ?*const anyopaque, bytecode_length: usize, pp_input_layout: *?*Object) i32 {
    return invoke(11, *const fn (*Object, ?[*]const InputElementDesc, u32, ?*const anyopaque, usize, *?*Object) callconv(call_conv) i32, object, .{ p_input_element_descs, num_elements, p_shader_bytecode_with_input_signature, bytecode_length, pp_input_layout });
}

pub fn createRasterizerState(object: *Object, p_rasterizer_desc: ?[*]const RasterizerDesc, pp_rasterizer_state: *?*Object) i32 {
    return invoke(22, *const fn (*Object, ?[*]const RasterizerDesc, *?*Object) callconv(call_conv) i32, object, .{ p_rasterizer_desc, pp_rasterizer_state });
}

pub fn createDepthStencilState(object: *Object, p_depth_stencil_desc: ?[*]const DepthStencilDesc, pp_depth_stencil_state: *?*Object) i32 {
    return invoke(21, *const fn (*Object, ?[*]const DepthStencilDesc, *?*Object) callconv(call_conv) i32, object, .{ p_depth_stencil_desc, pp_depth_stencil_state });
}

pub fn createBlendState(object: *Object, p_blend_state_desc: ?[*]const BlendDesc, pp_blend_state: *?*Object) i32 {
    return invoke(20, *const fn (*Object, ?[*]const BlendDesc, *?*Object) callconv(call_conv) i32, object, .{ p_blend_state_desc, pp_blend_state });
}

pub fn createRenderTargetView(object: *Object, p_resource: ?*Object, p_desc: ?[*]const RenderTargetViewDesc, pp_rt_view: *?*Object) i32 {
    return invoke(9, *const fn (*Object, ?*Object, ?[*]const RenderTargetViewDesc, *?*Object) callconv(call_conv) i32, object, .{ p_resource, p_desc, pp_rt_view });
}

pub fn createDepthStencilView(object: *Object, p_resource: ?*Object, p_desc: ?[*]const DepthStencilViewDesc, pp_depth_stencil_view: *?*Object) i32 {
    return invoke(10, *const fn (*Object, ?*Object, ?[*]const DepthStencilViewDesc, *?*Object) callconv(call_conv) i32, object, .{ p_resource, p_desc, pp_depth_stencil_view });
}

pub fn rsSetViewports(object: *Object, num_viewports: u32, p_viewports: ?[*]const Viewport) void {
    return invoke(44, *const fn (*Object, u32, ?[*]const Viewport) callconv(call_conv) void, object, .{ num_viewports, p_viewports });
}

pub fn rsSetScissorRects(object: *Object, num_rects: u32, p_rects: ?[*]const u32) void {
    return invoke(45, *const fn (*Object, u32, ?[*]const u32) callconv(call_conv) void, object, .{ num_rects, p_rects });
}

pub fn clearRenderTargetView(object: *Object, p_render_target_view: ?*Object, color_rgba: ?[*]const f32) void {
    return invoke(50, *const fn (*Object, ?*Object, ?[*]const f32) callconv(call_conv) void, object, .{ p_render_target_view, color_rgba });
}

pub fn clearDepthStencilView(object: *Object, p_depth_stencil_view: ?*Object, clear_flags: u32, depth: f32, stencil: u8) void {
    return invoke(53, *const fn (*Object, ?*Object, u32, f32, u8) callconv(call_conv) void, object, .{ p_depth_stencil_view, clear_flags, depth, stencil });
}

pub fn resolveSubresource(object: *Object, p_dst_resource: ?*Object, dst_subresource: u32, p_src_resource: ?*Object, src_subresource: u32, format: u32) void {
    return invoke(57, *const fn (*Object, ?*Object, u32, ?*Object, u32, u32) callconv(call_conv) void, object, .{ p_dst_resource, dst_subresource, p_src_resource, src_subresource, format });
}

pub fn iaSetPrimitiveTopology(object: *Object, topology: u32) void {
    return invoke(24, *const fn (*Object, u32) callconv(call_conv) void, object, .{topology});
}

pub fn updateSubresource(object: *Object, p_dst_resource: ?*Object, dst_subresource: u32, p_dst_box: ?[*]const Box, p_src_data: ?*const anyopaque, src_row_pitch: u32, src_depth_pitch: u32) void {
    return invoke(48, *const fn (*Object, ?*Object, u32, ?[*]const Box, ?*const anyopaque, u32, u32) callconv(call_conv) void, object, .{ p_dst_resource, dst_subresource, p_dst_box, p_src_data, src_row_pitch, src_depth_pitch });
}

pub fn copySubresourceRegion(object: *Object, p_dst_resource: ?*Object, dst_subresource: u32, dst_x: u32, dst_y: u32, dst_z: u32, p_src_resource: ?*Object, src_subresource: u32, p_src_box: ?[*]const Box) void {
    return invoke(46, *const fn (*Object, ?*Object, u32, u32, u32, u32, ?*Object, u32, ?[*]const Box) callconv(call_conv) void, object, .{ p_dst_resource, dst_subresource, dst_x, dst_y, dst_z, p_src_resource, src_subresource, p_src_box });
}

pub fn drawIndexed(object: *Object, index_count: u32, start_index_location: u32, base_vertex_location: i32) void {
    return invoke(12, *const fn (*Object, u32, u32, i32) callconv(call_conv) void, object, .{ index_count, start_index_location, base_vertex_location });
}

pub fn drawIndexedInstanced(object: *Object, index_count_per_instance: u32, instance_count: u32, start_index_location: u32, base_vertex_location: i32, start_instance_location: u32) void {
    return invoke(20, *const fn (*Object, u32, u32, u32, i32, u32) callconv(call_conv) void, object, .{ index_count_per_instance, instance_count, start_index_location, base_vertex_location, start_instance_location });
}

pub fn draw(object: *Object, vertex_count: u32, start_vertex_location: u32) void {
    return invoke(13, *const fn (*Object, u32, u32) callconv(call_conv) void, object, .{ vertex_count, start_vertex_location });
}

pub fn drawInstanced(object: *Object, vertex_count_per_instance: u32, instance_count: u32, start_vertex_location: u32, start_instance_location: u32) void {
    return invoke(21, *const fn (*Object, u32, u32, u32, u32) callconv(call_conv) void, object, .{ vertex_count_per_instance, instance_count, start_vertex_location, start_instance_location });
}

pub fn dispatch(object: *Object, thread_group_count_x: u32, thread_group_count_y: u32, thread_group_count_z: u32) void {
    return invoke(41, *const fn (*Object, u32, u32, u32) callconv(call_conv) void, object, .{ thread_group_count_x, thread_group_count_y, thread_group_count_z });
}

pub fn map(object: *Object, p_resource: ?*Object, subresource: u32, map_type: u32, map_flags: u32, p_mapped_resource: ?[*]MappedSubresource) i32 {
    return invoke(14, *const fn (*Object, ?*Object, u32, u32, u32, ?[*]MappedSubresource) callconv(call_conv) i32, object, .{ p_resource, subresource, map_type, map_flags, p_mapped_resource });
}

pub fn unmap(object: *Object, p_resource: ?*Object, subresource: u32) void {
    return invoke(15, *const fn (*Object, ?*Object, u32) callconv(call_conv) void, object, .{ p_resource, subresource });
}

pub fn clearState(object: *Object) void {
    return invoke(110, *const fn (*Object) callconv(call_conv) void, object, .{});
}

pub fn getFeatureLevel(object: *Object) u32 {
    return invoke(37, *const fn (*Object) callconv(call_conv) u32, object, .{});
}

pub const invoke = @import("../dxgi/com.zig").invoke;
pub const addRef = @import("../dxgi/com.zig").addRef;
pub const release = @import("../dxgi/com.zig").release;
pub const setPrivateData = @import("../dxgi/com.zig").setPrivateData;

pub const indices = struct {
    pub const checkFormatSupport: usize = 29;
    pub const omSetRenderTargets: usize = 33;
    pub const omSetRenderTargetsAndUnorderedAccessViews: usize = 34;
    pub const rsSetState: usize = 43;
    pub const omSetDepthStencilState: usize = 36;
    pub const omSetBlendState: usize = 35;
    pub const iaSetVertexBuffers: usize = 18;
    pub const iaSetIndexBuffer: usize = 19;
    pub const iaSetInputLayout: usize = 17;
    pub const vsSetShader: usize = 11;
    pub const psSetShader: usize = 9;
    pub const csSetShader: usize = 69;
    pub const vsSetConstantBuffers: usize = 7;
    pub const psSetConstantBuffers: usize = 16;
    pub const csSetConstantBuffers: usize = 71;
    pub const vsSetShaderResources: usize = 25;
    pub const psSetShaderResources: usize = 8;
    pub const csSetShaderResources: usize = 67;
    pub const vsSetSamplers: usize = 26;
    pub const psSetSamplers: usize = 10;
    pub const csSetSamplers: usize = 70;
    pub const csSetUnorderedAccessViews: usize = 68;
    pub const createBuffer: usize = 3;
    pub const createTexture2D: usize = 5;
    pub const createShaderResourceView: usize = 7;
    pub const createUnorderedAccessView: usize = 8;
    pub const getResource: usize = 7;
    pub const createTexture3D: usize = 6;
    pub const createSamplerState: usize = 23;
    pub const getBufferPointer: usize = 3;
    pub const getBufferSize: usize = 4;
    pub const createVertexShader: usize = 12;
    pub const createPixelShader: usize = 15;
    pub const createComputeShader: usize = 18;
    pub const createInputLayout: usize = 11;
    pub const createRasterizerState: usize = 22;
    pub const createDepthStencilState: usize = 21;
    pub const createBlendState: usize = 20;
    pub const createRenderTargetView: usize = 9;
    pub const createDepthStencilView: usize = 10;
    pub const rsSetViewports: usize = 44;
    pub const rsSetScissorRects: usize = 45;
    pub const clearRenderTargetView: usize = 50;
    pub const clearDepthStencilView: usize = 53;
    pub const resolveSubresource: usize = 57;
    pub const iaSetPrimitiveTopology: usize = 24;
    pub const updateSubresource: usize = 48;
    pub const copySubresourceRegion: usize = 46;
    pub const drawIndexed: usize = 12;
    pub const drawIndexedInstanced: usize = 20;
    pub const draw: usize = 13;
    pub const drawInstanced: usize = 21;
    pub const dispatch: usize = 41;
    pub const map: usize = 14;
    pub const unmap: usize = 15;
    pub const clearState: usize = 110;
    pub const getFeatureLevel: usize = 37;
};

pub const DepthStencilViewDescData = extern union {
    texture_1d: Tex1dDsv,
    texture_1d_array: Tex1dArrayDsv,
    texture_2d: Tex2dDsv,
    texture_2d_array: Tex2dArrayDsv,
    texture_2d_ms: Tex2dmsDsv,
    texture_2d_ms_array: Tex2dmsArrayDsv,
};

pub const RenderTargetViewDescData = extern union {
    buffer: BufferRtv,
    texture_1d: Tex1dRtv,
    texture_1d_array: Tex1dArrayRtv,
    texture_2d: Tex2dRtv,
    texture_2d_array: Tex2dArrayRtv,
    texture_2d_ms: Tex2dmsRtv,
    texture_2d_ms_array: Tex2dmsArrayRtv,
    texture_3d: Tex3dRtv,
};

pub const ShaderResourceViewDescData = extern union {
    buffer: BufferSrv,
    texture_1d: Tex1dSrv,
    texture_1d_array: Tex1dArraySrv,
    texture_2d: Tex2dSrv,
    texture_2d_array: Tex2dArraySrv,
    texture_2d_ms: Tex2dmsSrv,
    texture_2d_ms_array: Tex2dmsArraySrv,
    texture_3d: Tex3dSrv,
    texture_cube: TexcubeSrv,
    texture_cube_array: TexcubeArraySrv,
    buffer_ex: BufferexSrv,
};

pub const UnorderedAccessViewDescData = extern union {
    buffer: BufferUav,
    texture_1d: Tex1dUav,
    texture_1d_array: Tex1dArrayUav,
    texture_2d: Tex2dUav,
    texture_2d_array: Tex2dArrayUav,
    texture_3d: Tex3dUav,
};

pub const CompileFn = @import("../dxgi/com.zig").CompileFn;

pub fn fromOpaque(pointer: *const anyopaque) *Object {
    return @ptrCast(@constCast(pointer));
}

pub const SampleDesc = extern struct { count: u32 = 0, quality: u32 = 0 };

pub const QueryDesc = extern struct { query: u32 = 0, misc_flags: u32 = 0 };
pub fn createQuery(object: *Object, desc: *const QueryDesc, out: *?*Object) i32 {
    return invoke(24, *const fn (*Object, *const QueryDesc, *?*Object) callconv(call_conv) i32, object, .{ desc, out });
}
pub fn endQuery(object: *Object, query: *Object) void {
    invoke(28, *const fn (*Object, *Object) callconv(call_conv) void, object, .{query});
}
pub fn queryData(object: *Object, query: *Object, data: *u32, flags: u32) i32 {
    return invoke(29, *const fn (*Object, *Object, *u32, u32, u32) callconv(call_conv) i32, object, .{ query, data, 4, flags });
}
pub fn flush(object: *Object) void {
    invoke(111, *const fn (*Object) callconv(call_conv) void, object, .{});
}
pub fn getDeviceRemovedReason(object: *Object) i32 {
    return invoke(39, *const fn (*Object) callconv(call_conv) i32, object, .{});
}
