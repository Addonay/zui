//! D3D12 driver data and COM calls, derived from the Windows SDK d3d12.h and
//! d3d12sdklayers.h. Vtable indices are the C `ID3D12*Vtbl` member positions.
//! Object, GUID, invoke and blob access are shared with the D3D11 backend.
const std = @import("std");
const builtin = @import("builtin");
const com = @import("../dxgi/com.zig");

pub const call_conv = com.call_conv;
pub const Object = com.Object;
pub const Guid = com.Guid;
pub const invoke = com.invoke;
pub const addRef = com.addRef;
pub const release = com.release;
pub const getBufferPointer = com.getBufferPointer;
pub const getBufferSize = com.getBufferSize;

pub const Handle = ?*anyopaque;
pub const CpuHandle = usize;
pub const GpuHandle = u64;

pub const iid_device: Guid = .{ .data1 = 0x189819f1, .data2 = 0x1db6, .data3 = 0x4b57, .data4 = .{ 0xbe, 0x54, 0x18, 0x21, 0x33, 0x9b, 0x85, 0xf7 } };
pub const iid_command_queue: Guid = .{ .data1 = 0x0ec870a6, .data2 = 0x5d7e, .data3 = 0x4c22, .data4 = .{ 0x8c, 0xfc, 0x5b, 0xaa, 0xe0, 0x76, 0x16, 0xed } };
pub const iid_command_allocator: Guid = .{ .data1 = 0x6102dee4, .data2 = 0xaf59, .data3 = 0x4b09, .data4 = .{ 0xb9, 0x99, 0xb4, 0x4d, 0x73, 0xf0, 0x9b, 0x24 } };
pub const iid_command_list: Guid = .{ .data1 = 0x5b160d0f, .data2 = 0xac1b, .data3 = 0x4185, .data4 = .{ 0x8b, 0xa8, 0xb3, 0xae, 0x42, 0xa5, 0xa4, 0x55 } };
pub const iid_fence: Guid = .{ .data1 = 0x0a753dcf, .data2 = 0xc4d8, .data3 = 0x4b91, .data4 = .{ 0xad, 0xf6, 0xbe, 0x5a, 0x60, 0xd9, 0x5a, 0x76 } };
pub const iid_resource: Guid = .{ .data1 = 0x696442be, .data2 = 0xa72e, .data3 = 0x4059, .data4 = .{ 0xbc, 0x79, 0x5b, 0x5c, 0x98, 0x04, 0x0f, 0xad } };
pub const iid_descriptor_heap: Guid = .{ .data1 = 0x8efb471d, .data2 = 0x616c, .data3 = 0x4f49, .data4 = .{ 0x90, 0xf7, 0x12, 0x7b, 0xb7, 0x63, 0xfa, 0x51 } };
pub const iid_root_signature: Guid = .{ .data1 = 0xc54a6b66, .data2 = 0x72df, .data3 = 0x4ee8, .data4 = .{ 0x8b, 0xe5, 0xa9, 0x46, 0xa1, 0x42, 0x92, 0x14 } };
pub const iid_pipeline_state: Guid = .{ .data1 = 0x765a30f3, .data2 = 0xf624, .data3 = 0x4c6f, .data4 = .{ 0xa8, 0x28, 0xac, 0xe9, 0x48, 0x62, 0x24, 0x45 } };
pub const iid_debug: Guid = .{ .data1 = 0x344488b7, .data2 = 0x6846, .data3 = 0x474b, .data4 = .{ 0xb9, 0x89, 0xf0, 0x27, 0x44, 0x82, 0x45, 0xe0 } };
pub const iid_info_queue: Guid = .{ .data1 = 0x0742a90b, .data2 = 0xc387, .data3 = 0x483f, .data4 = .{ 0xb9, 0x46, 0x30, 0xa7, 0xe4, 0xe6, 0x14, 0x58 } };

// ---------------------------------------------------------------- structures

pub const CommandQueueDesc = extern struct { type: u32 = 0, priority: i32 = 0, flags: u32 = 0, node_mask: u32 = 0 };

pub const DescriptorHeapDesc = extern struct { type: u32 = 0, num_descriptors: u32 = 0, flags: u32 = 0, node_mask: u32 = 0 };

pub const HeapProperties = extern struct { type: u32 = 0, cpu_page_property: u32 = 0, memory_pool_preference: u32 = 0, creation_node_mask: u32 = 0, visible_node_mask: u32 = 0 };

pub const SampleDesc = extern struct { count: u32 = 1, quality: u32 = 0 };

pub const ResourceDesc = extern struct {
    dimension: u32 = 0,
    alignment: u64 = 0,
    width: u64 = 0,
    height: u32 = 1,
    depth_or_array_size: u16 = 1,
    mip_levels: u16 = 1,
    format: u32 = 0,
    sample_desc: SampleDesc = .{},
    layout: u32 = 0,
    flags: u32 = 0,
};

pub const Footprint = extern struct { format: u32 = 0, width: u32 = 0, height: u32 = 0, depth: u32 = 0, row_pitch: u32 = 0 };

pub const PlacedFootprint = extern struct { offset: u64 = 0, footprint: Footprint = .{} };

/// `D3D12_TEXTURE_COPY_LOCATION`, where `type` selects the union member.
pub const TextureCopyLocation = extern struct {
    resource: ?*Object = null,
    type: u32 = 0,
    payload: extern union { placed: PlacedFootprint, subresource_index: u32 } = .{ .placed = .{} },
};

pub const TransitionBarrier = extern struct { resource: ?*Object = null, subresource: u32 = 0, state_before: u32 = 0, state_after: u32 = 0 };

pub const ResourceBarrier = extern struct {
    type: u32 = 0,
    flags: u32 = 0,
    payload: extern union { transition: TransitionBarrier, uav: extern struct { resource: ?*Object = null } } = .{ .transition = .{} },
};

pub const Viewport = extern struct { top_left_x: f32 = 0, top_left_y: f32 = 0, width: f32 = 0, height: f32 = 0, min_depth: f32 = 0, max_depth: f32 = 1 };

pub const Rect = extern struct { left: i32 = 0, top: i32 = 0, right: i32 = 0, bottom: i32 = 0 };

pub const Box = extern struct { left: u32 = 0, top: u32 = 0, front: u32 = 0, right: u32 = 0, bottom: u32 = 0, back: u32 = 0 };

pub const VertexBufferView = extern struct { buffer_location: u64 = 0, size_in_bytes: u32 = 0, stride_in_bytes: u32 = 0 };

pub const IndexBufferView = extern struct { buffer_location: u64 = 0, size_in_bytes: u32 = 0, format: u32 = 0 };

pub const ShaderBytecode = extern struct { ptr: ?*const anyopaque = null, size: usize = 0 };

pub const InputElementDesc = extern struct {
    semantic_name: ?[*:0]const u8 = null,
    semantic_index: u32 = 0,
    format: u32 = 0,
    input_slot: u32 = 0,
    aligned_byte_offset: u32 = 0,
    input_slot_class: u32 = 0,
    instance_data_step_rate: u32 = 0,
};

pub const RenderTargetBlendDesc = extern struct {
    blend_enable: i32 = 0,
    logic_op_enable: i32 = 0,
    src_blend: u32 = 0,
    dest_blend: u32 = 0,
    blend_op: u32 = 0,
    src_blend_alpha: u32 = 0,
    dest_blend_alpha: u32 = 0,
    blend_op_alpha: u32 = 0,
    logic_op: u32 = 0,
    render_target_write_mask: u8 = 0,
};

pub const BlendDesc = extern struct {
    alpha_to_coverage_enable: i32 = 0,
    independent_blend_enable: i32 = 0,
    render_target: [8]RenderTargetBlendDesc = @splat(.{}),
};

pub const RasterizerDesc = extern struct {
    fill_mode: u32 = 0,
    cull_mode: u32 = 0,
    front_counter_clockwise: i32 = 0,
    depth_bias: i32 = 0,
    depth_bias_clamp: f32 = 0,
    slope_scaled_depth_bias: f32 = 0,
    depth_clip_enable: i32 = 0,
    multisample_enable: i32 = 0,
    antialiased_line_enable: i32 = 0,
    forced_sample_count: u32 = 0,
    conservative_raster: u32 = 0,
};

pub const StencilOpDesc = extern struct { stencil_fail_op: u32 = 0, stencil_depth_fail_op: u32 = 0, stencil_pass_op: u32 = 0, stencil_func: u32 = 0 };

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

pub const GraphicsPipelineStateDesc = extern struct {
    root_signature: ?*Object = null,
    vs: ShaderBytecode = .{},
    ps: ShaderBytecode = .{},
    ds: ShaderBytecode = .{},
    hs: ShaderBytecode = .{},
    gs: ShaderBytecode = .{},
    stream_output: extern struct { declaration: ?*const anyopaque = null, num_entries: u32 = 0, buffer_strides: ?*const anyopaque = null, num_strides: u32 = 0, rasterized_stream: u32 = 0 } = .{},
    blend: BlendDesc = .{},
    sample_mask: u32 = 0xffffffff,
    rasterizer: RasterizerDesc = .{},
    depth_stencil: DepthStencilDesc = .{},
    input_layout: extern struct { elements: ?[*]const InputElementDesc = null, num_elements: u32 = 0 } = .{},
    ib_strip_cut_value: u32 = 0,
    primitive_topology_type: u32 = 0,
    num_render_targets: u32 = 0,
    rtv_formats: [8]u32 = @splat(0),
    dsv_format: u32 = 0,
    sample_desc: SampleDesc = .{},
    node_mask: u32 = 0,
    cached_pso: extern struct { blob: ?*const anyopaque = null, size: usize = 0 } = .{},
    flags: u32 = 0,
};

pub const ComputePipelineStateDesc = extern struct {
    root_signature: ?*Object = null,
    cs: ShaderBytecode = .{},
    node_mask: u32 = 0,
    cached_pso: extern struct { blob: ?*const anyopaque = null, size: usize = 0 } = .{},
    flags: u32 = 0,
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
    shader4component_mapping: u32 = 0x1688,
    payload: extern union {
        buffer: extern struct { first_element: u64 = 0, num_elements: u32 = 0, structure_byte_stride: u32 = 0, flags: u32 = 0 },
        texture_2d: extern struct { most_detailed_mip: u32 = 0, mip_levels: u32 = 0, plane_slice: u32 = 0, resource_min_lod_clamp: f32 = 0 },
        texture_2d_array: extern struct { most_detailed_mip: u32 = 0, mip_levels: u32 = 0, first_array_slice: u32 = 0, array_size: u32 = 0, plane_slice: u32 = 0, resource_min_lod_clamp: f32 = 0 },
        texture_2d_ms_array: extern struct { first_array_slice: u32 = 0, array_size: u32 = 0 },
        texture_3d: extern struct { most_detailed_mip: u32 = 0, mip_levels: u32 = 0, resource_min_lod_clamp: f32 = 0 },
        texture_cube: extern struct { most_detailed_mip: u32 = 0, mip_levels: u32 = 0, resource_min_lod_clamp: f32 = 0 },
    } = .{ .buffer = .{} },
};

pub const UnorderedAccessViewDesc = extern struct {
    format: u32 = 0,
    view_dimension: u32 = 0,
    payload: extern union {
        buffer: extern struct { first_element: u64 = 0, num_elements: u32 = 0, structure_byte_stride: u32 = 0, counter_offset_in_bytes: u64 = 0, flags: u32 = 0 },
        texture_2d: extern struct { mip_slice: u32 = 0, plane_slice: u32 = 0 },
        texture_2d_array: extern struct { mip_slice: u32 = 0, first_array_slice: u32 = 0, array_size: u32 = 0, plane_slice: u32 = 0 },
        texture_3d: extern struct { mip_slice: u32 = 0, first_w_slice: u32 = 0, w_size: u32 = 0 },
    } = .{ .buffer = .{} },
};

pub const RenderTargetViewDesc = extern struct {
    format: u32 = 0,
    view_dimension: u32 = 0,
    payload: extern union {
        texture_2d: extern struct { mip_slice: u32 = 0, plane_slice: u32 = 0 },
        texture_2d_array: extern struct { mip_slice: u32 = 0, first_array_slice: u32 = 0, array_size: u32 = 0, plane_slice: u32 = 0 },
        texture_2d_ms_array: extern struct { first_array_slice: u32 = 0, array_size: u32 = 0 },
        texture_3d: extern struct { mip_slice: u32 = 0, first_w_slice: u32 = 0, w_size: u32 = 0 },
    } = .{ .texture_2d = .{} },
};

pub const DepthStencilViewDesc = extern struct {
    format: u32 = 0,
    view_dimension: u32 = 0,
    flags: u32 = 0,
    payload: extern union {
        texture_2d: extern struct { mip_slice: u32 = 0 },
        texture_2d_array: extern struct { mip_slice: u32 = 0, first_array_slice: u32 = 0, array_size: u32 = 0 },
        texture_2d_ms_array: extern struct { first_array_slice: u32 = 0, array_size: u32 = 0 },
    } = .{ .texture_2d = .{} },
};

pub const RootDescriptorRange = extern struct {
    range_type: u32 = 0,
    num_descriptors: u32 = 0,
    base_shader_register: u32 = 0,
    register_space: u32 = 0,
    offset_in_descriptors_from_table_start: u32 = 0,
};

pub const RootParameter = extern struct {
    parameter_type: u32 = 0,
    payload: extern union {
        table: extern struct { num_ranges: u32 = 0, ranges: ?[*]const RootDescriptorRange = null },
        descriptor: extern struct { shader_register: u32 = 0, register_space: u32 = 0 },
    } = .{ .descriptor = .{} },
    shader_visibility: u32 = 0,
};

pub const RootSignatureDesc = extern struct {
    num_parameters: u32 = 0,
    parameters: ?[*]const RootParameter = null,
    num_static_samplers: u32 = 0,
    static_samplers: ?*const anyopaque = null,
    flags: u32 = 0,
};

/// Root signature 1.1 structures, matching d3d12.h without a C dependency.
pub const RootDescriptorRange1 = extern struct {
    range_type: u32 = 0,
    num_descriptors: u32 = 0,
    base_shader_register: u32 = 0,
    register_space: u32 = 0,
    flags: u32 = 0,
    offset_in_descriptors_from_table_start: u32 = 0,
};
pub const RootParameter1 = extern struct {
    parameter_type: u32 = 0,
    payload: extern union {
        table: extern struct { num_ranges: u32 = 0, ranges: ?[*]const RootDescriptorRange1 = null },
        constants: extern struct { shader_register: u32, register_space: u32, num_values: u32 },
        descriptor: extern struct { shader_register: u32 = 0, register_space: u32 = 0, flags: u32 = 0 },
    } = .{ .descriptor = .{} },
    shader_visibility: u32 = 0,
};
pub const RootSignatureDesc1 = extern struct {
    num_parameters: u32 = 0,
    parameters: ?[*]const RootParameter1 = null,
    num_static_samplers: u32 = 0,
    static_samplers: ?*const anyopaque = null,
    flags: u32 = 0,
};
pub const VersionedRootSignatureDesc = extern struct {
    version: u32 = 2, // D3D_ROOT_SIGNATURE_VERSION_1_1
    payload: extern union { v1_0: RootSignatureDesc, v1_1: RootSignatureDesc1 },
};
pub const VersionedRootSignatureSerializeFn = *const fn (*const VersionedRootSignatureDesc, *?*Object, *?*Object) callconv(call_conv) i32;

pub const FormatSupport = extern struct { format: u32 = 0, support1: u32 = 0, support2: u32 = 0 };

pub const Message = extern struct {
    category: u32 = 0,
    severity: u32 = 0,
    id: u32 = 0,
    description: ?[*:0]const u8 = null,
    description_byte_length: usize = 0,
};

// ---------------------------------------------------------------- device

pub fn queryInterface(object: *Object, riid: *const Guid, out: *?*Object) i32 {
    return invoke(0, *const fn (*Object, *const Guid, *?*Object) callconv(call_conv) i32, object, .{ riid, out });
}

pub fn createCommandQueue(object: *Object, desc: *const CommandQueueDesc, out: *?*Object) i32 {
    return invoke(8, *const fn (*Object, *const CommandQueueDesc, *const Guid, *?*Object) callconv(call_conv) i32, object, .{ desc, &iid_command_queue, out });
}

pub fn createCommandAllocator(object: *Object, list_type: u32, out: *?*Object) i32 {
    return invoke(9, *const fn (*Object, u32, *const Guid, *?*Object) callconv(call_conv) i32, object, .{ list_type, &iid_command_allocator, out });
}

pub fn createGraphicsPipelineState(object: *Object, desc: *const GraphicsPipelineStateDesc, out: *?*Object) i32 {
    return invoke(10, *const fn (*Object, *const GraphicsPipelineStateDesc, *const Guid, *?*Object) callconv(call_conv) i32, object, .{ desc, &iid_pipeline_state, out });
}

pub fn createComputePipelineState(object: *Object, desc: *const ComputePipelineStateDesc, out: *?*Object) i32 {
    return invoke(11, *const fn (*Object, *const ComputePipelineStateDesc, *const Guid, *?*Object) callconv(call_conv) i32, object, .{ desc, &iid_pipeline_state, out });
}

pub fn createCommandList(object: *Object, list_type: u32, allocator: *Object, out: *?*Object) i32 {
    return invoke(12, *const fn (*Object, u32, u32, *Object, ?*Object, *const Guid, *?*Object) callconv(call_conv) i32, object, .{ @as(u32, 0), list_type, allocator, @as(?*Object, null), &iid_command_list, out });
}

pub fn checkFeatureSupport(object: *Object, feature: u32, data: *anyopaque, size: u32) i32 {
    return invoke(13, *const fn (*Object, u32, *anyopaque, u32) callconv(call_conv) i32, object, .{ feature, data, size });
}

pub fn createDescriptorHeap(object: *Object, desc: *const DescriptorHeapDesc, out: *?*Object) i32 {
    return invoke(14, *const fn (*Object, *const DescriptorHeapDesc, *const Guid, *?*Object) callconv(call_conv) i32, object, .{ desc, &iid_descriptor_heap, out });
}

pub fn getDescriptorHandleIncrementSize(object: *Object, heap_type: u32) u32 {
    return invoke(15, *const fn (*Object, u32) callconv(call_conv) u32, object, .{heap_type});
}

pub fn createRootSignature(object: *Object, blob: *Object, out: *?*Object) i32 {
    const data = getBufferPointer(blob);
    return invoke(16, *const fn (*Object, u32, ?*const anyopaque, usize, *const Guid, *?*Object) callconv(call_conv) i32, object, .{ @as(u32, 0), data, getBufferSize(blob), &iid_root_signature, out });
}

pub fn createShaderResourceView(object: *Object, resource: ?*Object, desc: ?*const ShaderResourceViewDesc, dest: CpuHandle) void {
    return invoke(18, *const fn (*Object, ?*Object, ?*const ShaderResourceViewDesc, CpuHandle) callconv(call_conv) void, object, .{ resource, desc, dest });
}

pub fn createUnorderedAccessView(object: *Object, resource: ?*Object, desc: ?*const UnorderedAccessViewDesc, dest: CpuHandle) void {
    return invoke(19, *const fn (*Object, ?*Object, ?*Object, ?*const UnorderedAccessViewDesc, CpuHandle) callconv(call_conv) void, object, .{ resource, @as(?*Object, null), desc, dest });
}

pub fn createRenderTargetView(object: *Object, resource: ?*Object, desc: ?*const RenderTargetViewDesc, dest: CpuHandle) void {
    return invoke(20, *const fn (*Object, ?*Object, ?*const RenderTargetViewDesc, CpuHandle) callconv(call_conv) void, object, .{ resource, desc, dest });
}

pub fn createDepthStencilView(object: *Object, resource: ?*Object, desc: ?*const DepthStencilViewDesc, dest: CpuHandle) void {
    return invoke(21, *const fn (*Object, ?*Object, ?*const DepthStencilViewDesc, CpuHandle) callconv(call_conv) void, object, .{ resource, desc, dest });
}

pub fn createSampler(object: *Object, desc: *const SamplerDesc, dest: CpuHandle) void {
    return invoke(22, *const fn (*Object, *const SamplerDesc, CpuHandle) callconv(call_conv) void, object, .{ desc, dest });
}

pub fn copyDescriptorsSimple(object: *Object, count: u32, dest: CpuHandle, src: CpuHandle, heap_type: u32) void {
    return invoke(24, *const fn (*Object, u32, CpuHandle, CpuHandle, u32) callconv(call_conv) void, object, .{ count, dest, src, heap_type });
}

pub fn createCommittedResource(object: *Object, heap: *const HeapProperties, heap_flags: u32, desc: *const ResourceDesc, state: u32, out: *?*Object) i32 {
    return invoke(27, *const fn (*Object, *const HeapProperties, u32, *const ResourceDesc, u32, ?*const anyopaque, *const Guid, *?*Object) callconv(call_conv) i32, object, .{ heap, heap_flags, desc, state, @as(?*const anyopaque, null), &iid_resource, out });
}

pub fn createFence(object: *Object, initial: u64, out: *?*Object) i32 {
    return invoke(36, *const fn (*Object, u64, u32, *const Guid, *?*Object) callconv(call_conv) i32, object, .{ initial, @as(u32, 0), &iid_fence, out });
}

pub fn getDeviceRemovedReason(object: *Object) i32 {
    return invoke(37, *const fn (*Object) callconv(call_conv) i32, object, .{});
}

pub fn getCopyableFootprints(object: *Object, desc: *const ResourceDesc, first: u32, count: u32, base_offset: u64, layouts: ?[*]PlacedFootprint, rows: ?[*]u32, row_sizes: ?[*]u64, total: ?*u64) void {
    return invoke(38, *const fn (*Object, *const ResourceDesc, u32, u32, u64, ?[*]PlacedFootprint, ?[*]u32, ?[*]u64, ?*u64) callconv(call_conv) void, object, .{ desc, first, count, base_offset, layouts, rows, row_sizes, total });
}

// ---------------------------------------------------------------- object, queue, fence, resource

pub fn setName(object: *Object, name: [*:0]const u16) i32 {
    return invoke(6, *const fn (*Object, [*:0]const u16) callconv(call_conv) i32, object, .{name});
}

pub fn queueExecuteCommandLists(object: *Object, count: u32, lists: [*]const ?*Object) void {
    return invoke(10, *const fn (*Object, u32, [*]const ?*Object) callconv(call_conv) void, object, .{ count, lists });
}

pub fn queueSignal(object: *Object, fence: *Object, value: u64) i32 {
    return invoke(14, *const fn (*Object, *Object, u64) callconv(call_conv) i32, object, .{ fence, value });
}

pub fn allocatorReset(object: *Object) i32 {
    return invoke(8, *const fn (*Object) callconv(call_conv) i32, object, .{});
}

pub fn fenceCompletedValue(object: *Object) u64 {
    return invoke(8, *const fn (*Object) callconv(call_conv) u64, object, .{});
}

pub fn fenceSetEventOnCompletion(object: *Object, value: u64, event: Handle) i32 {
    return invoke(9, *const fn (*Object, u64, Handle) callconv(call_conv) i32, object, .{ value, event });
}

pub fn resourceMap(object: *Object, subresource: u32, out: *?*anyopaque) i32 {
    return invoke(8, *const fn (*Object, u32, ?*const anyopaque, *?*anyopaque) callconv(call_conv) i32, object, .{ subresource, @as(?*const anyopaque, null), out });
}

pub fn resourceUnmap(object: *Object, subresource: u32) void {
    return invoke(9, *const fn (*Object, u32, ?*const anyopaque) callconv(call_conv) void, object, .{ subresource, @as(?*const anyopaque, null) });
}

pub fn resourceGpuAddress(object: *Object) u64 {
    return invoke(11, *const fn (*Object) callconv(call_conv) u64, object, .{});
}

// Struct returns use the explicit out-pointer ABI (WIDL_EXPLICIT_AGGREGATE_RETURNS),
// which is what the D3D12 runtime implements.
pub fn heapStartCpu(object: *Object) CpuHandle {
    var out: CpuHandle = 0;
    _ = invoke(9, *const fn (*Object, *CpuHandle) callconv(call_conv) *CpuHandle, object, .{&out});
    return out;
}

pub fn heapStartGpu(object: *Object) GpuHandle {
    var out: GpuHandle = 0;
    _ = invoke(10, *const fn (*Object, *GpuHandle) callconv(call_conv) *GpuHandle, object, .{&out});
    return out;
}

// ---------------------------------------------------------------- command list

pub fn listClose(object: *Object) i32 {
    return invoke(9, *const fn (*Object) callconv(call_conv) i32, object, .{});
}

pub fn listReset(object: *Object, allocator: *Object) i32 {
    return invoke(10, *const fn (*Object, *Object, ?*Object) callconv(call_conv) i32, object, .{ allocator, @as(?*Object, null) });
}

pub fn drawInstanced(object: *Object, vertex_count: u32, instance_count: u32, start_vertex: u32, start_instance: u32) void {
    return invoke(12, *const fn (*Object, u32, u32, u32, u32) callconv(call_conv) void, object, .{ vertex_count, instance_count, start_vertex, start_instance });
}

pub fn drawIndexedInstanced(object: *Object, index_count: u32, instance_count: u32, start_index: u32, base_vertex: i32, start_instance: u32) void {
    return invoke(13, *const fn (*Object, u32, u32, u32, i32, u32) callconv(call_conv) void, object, .{ index_count, instance_count, start_index, base_vertex, start_instance });
}

pub fn dispatch(object: *Object, x: u32, y: u32, z: u32) void {
    return invoke(14, *const fn (*Object, u32, u32, u32) callconv(call_conv) void, object, .{ x, y, z });
}

pub fn copyBufferRegion(object: *Object, dst: ?*Object, dst_offset: u64, src: ?*Object, src_offset: u64, size: u64) void {
    return invoke(15, *const fn (*Object, ?*Object, u64, ?*Object, u64, u64) callconv(call_conv) void, object, .{ dst, dst_offset, src, src_offset, size });
}

pub fn copyTextureRegion(object: *Object, dst: *const TextureCopyLocation, x: u32, y: u32, z: u32, src: *const TextureCopyLocation, box: ?*const Box) void {
    return invoke(16, *const fn (*Object, *const TextureCopyLocation, u32, u32, u32, *const TextureCopyLocation, ?*const Box) callconv(call_conv) void, object, .{ dst, x, y, z, src, box });
}

pub fn copyResource(object: *Object, dst: ?*Object, src: ?*Object) void {
    return invoke(17, *const fn (*Object, ?*Object, ?*Object) callconv(call_conv) void, object, .{ dst, src });
}

pub fn resolveSubresource(object: *Object, dst: ?*Object, dst_subresource: u32, src: ?*Object, src_subresource: u32, format: u32) void {
    return invoke(19, *const fn (*Object, ?*Object, u32, ?*Object, u32, u32) callconv(call_conv) void, object, .{ dst, dst_subresource, src, src_subresource, format });
}

pub fn iaSetPrimitiveTopology(object: *Object, topology: u32) void {
    return invoke(20, *const fn (*Object, u32) callconv(call_conv) void, object, .{topology});
}

pub fn rsSetViewports(object: *Object, count: u32, viewports: *const Viewport) void {
    return invoke(21, *const fn (*Object, u32, *const Viewport) callconv(call_conv) void, object, .{ count, viewports });
}

pub fn rsSetScissorRects(object: *Object, count: u32, rects: *const Rect) void {
    return invoke(22, *const fn (*Object, u32, *const Rect) callconv(call_conv) void, object, .{ count, rects });
}

pub fn omSetBlendFactor(object: *Object, factor: *const [4]f32) void {
    return invoke(23, *const fn (*Object, *const [4]f32) callconv(call_conv) void, object, .{factor});
}

pub fn omSetStencilRef(object: *Object, reference: u32) void {
    return invoke(24, *const fn (*Object, u32) callconv(call_conv) void, object, .{reference});
}

pub fn setPipelineState(object: *Object, pipeline: ?*Object) void {
    return invoke(25, *const fn (*Object, ?*Object) callconv(call_conv) void, object, .{pipeline});
}

pub fn resourceBarrier(object: *Object, count: u32, barriers: [*]const ResourceBarrier) void {
    return invoke(26, *const fn (*Object, u32, [*]const ResourceBarrier) callconv(call_conv) void, object, .{ count, barriers });
}

pub fn setDescriptorHeaps(object: *Object, count: u32, heaps: [*]const ?*Object) void {
    return invoke(28, *const fn (*Object, u32, [*]const ?*Object) callconv(call_conv) void, object, .{ count, heaps });
}

pub fn setComputeRootSignature(object: *Object, signature: ?*Object) void {
    return invoke(29, *const fn (*Object, ?*Object) callconv(call_conv) void, object, .{signature});
}

pub fn setGraphicsRootSignature(object: *Object, signature: ?*Object) void {
    return invoke(30, *const fn (*Object, ?*Object) callconv(call_conv) void, object, .{signature});
}

pub fn setComputeRootDescriptorTable(object: *Object, index: u32, base: GpuHandle) void {
    return invoke(31, *const fn (*Object, u32, GpuHandle) callconv(call_conv) void, object, .{ index, base });
}

pub fn setGraphicsRootDescriptorTable(object: *Object, index: u32, base: GpuHandle) void {
    return invoke(32, *const fn (*Object, u32, GpuHandle) callconv(call_conv) void, object, .{ index, base });
}

pub fn setComputeRootConstantBufferView(object: *Object, index: u32, address: u64) void {
    return invoke(37, *const fn (*Object, u32, u64) callconv(call_conv) void, object, .{ index, address });
}

pub fn setGraphicsRootConstantBufferView(object: *Object, index: u32, address: u64) void {
    return invoke(38, *const fn (*Object, u32, u64) callconv(call_conv) void, object, .{ index, address });
}

pub fn iaSetIndexBuffer(object: *Object, view: ?*const IndexBufferView) void {
    return invoke(43, *const fn (*Object, ?*const IndexBufferView) callconv(call_conv) void, object, .{view});
}

pub fn iaSetVertexBuffer(object: *Object, slot: u32, view: *const VertexBufferView) void {
    return invoke(44, *const fn (*Object, u32, u32, *const VertexBufferView) callconv(call_conv) void, object, .{ slot, @as(u32, 1), view });
}

pub fn omSetRenderTargets(object: *Object, count: u32, rtvs: ?[*]const CpuHandle, dsv: ?*const CpuHandle) void {
    return invoke(46, *const fn (*Object, u32, ?[*]const CpuHandle, i32, ?*const CpuHandle) callconv(call_conv) void, object, .{ count, rtvs, @as(i32, 0), dsv });
}

pub fn clearDepthStencilView(object: *Object, dsv: CpuHandle, flags: u32, depth: f32, stencil: u8) void {
    return invoke(47, *const fn (*Object, CpuHandle, u32, f32, u8, u32, ?*const Rect) callconv(call_conv) void, object, .{ dsv, flags, depth, stencil, @as(u32, 0), @as(?*const Rect, null) });
}

pub fn clearRenderTargetView(object: *Object, rtv: CpuHandle, color: *const [4]f32) void {
    return invoke(48, *const fn (*Object, CpuHandle, *const [4]f32, u32, ?*const Rect) callconv(call_conv) void, object, .{ rtv, color, @as(u32, 0), @as(?*const Rect, null) });
}

// ---------------------------------------------------------------- info queue

pub fn infoGetNumStoredMessages(object: *Object) u64 {
    return invoke(8, *const fn (*Object) callconv(call_conv) u64, object, .{});
}

pub fn infoGetMessage(object: *Object, index: u64, message: ?*Message, size: *usize) i32 {
    return invoke(5, *const fn (*Object, u64, ?*Message, *usize) callconv(call_conv) i32, object, .{ index, message, size });
}

pub fn infoClearStoredMessages(object: *Object) void {
    return invoke(4, *const fn (*Object) callconv(call_conv) void, object, .{});
}

pub fn listBeginEvent(object: *Object, metadata: u32, data: [*:0]const u8) void {
    return invoke(57, *const fn (*Object, u32, [*:0]const u8, u32) callconv(call_conv) void, object, .{ metadata, data, @as(u32, @intCast(std.mem.len(data) + 1)) });
}

pub fn listEndEvent(object: *Object) void {
    return invoke(58, *const fn (*Object) callconv(call_conv) void, object, .{});
}

pub fn debugEnableLayer(object: *Object) void {
    return invoke(3, *const fn (*Object) callconv(call_conv) void, object, .{});
}

// ---------------------------------------------------------------- kernel32 events

// The externs are only referenced on Windows, so other hosts can analyze this file.
extern "kernel32" fn CreateEventExW(attributes: ?*anyopaque, name: ?[*:0]const u16, flags: u32, access: u32) callconv(.winapi) Handle;
extern "kernel32" fn WaitForSingleObject(handle: Handle, milliseconds: u32) callconv(.winapi) u32;
extern "kernel32" fn CloseHandle(handle: Handle) callconv(.winapi) i32;

/// An auto-reset event for fence waits, or null where events are not available.
pub fn createEvent() Handle {
    if (comptime builtin.os.tag != .windows) return null;
    return CreateEventExW(null, null, 0, event_all_access);
}

pub fn waitEvent(event: Handle, milliseconds: u32) void {
    if (comptime builtin.os.tag != .windows) unreachable;
    _ = WaitForSingleObject(event, milliseconds);
}

pub fn closeEvent(event: Handle) void {
    if (comptime builtin.os.tag != .windows) unreachable;
    _ = CloseHandle(event);
}

pub const infinite: u32 = 0xffffffff;
const event_all_access: u32 = 0x1f0003;

pub fn fromOpaque(pointer: *const anyopaque) *Object {
    return @ptrCast(@constCast(pointer));
}

pub const RootSignatureSerializeFn = *const fn (*const RootSignatureDesc, u32, *?*Object, *?*Object) callconv(call_conv) i32;
pub const GetDebugInterfaceFn = *const fn (*const Guid, *?*Object) callconv(call_conv) i32;

// GUIDs and method slots from the pinned Windows SDK's d3d12sdklayers.h/d3d12.h.
pub const iid_debug1: Guid = .{ .data1 = 0xaffaa4ca, .data2 = 0x63fe, .data3 = 0x4d8e, .data4 = .{ 0xb8, 0xad, 0x15, 0x90, 0x00, 0xaf, 0x43, 0x04 } };
pub const iid_dred_settings: Guid = .{ .data1 = 0x82bc481c, .data2 = 0x6b9b, .data3 = 0x4030, .data4 = .{ 0xae, 0xdb, 0x7e, 0xe3, 0xd1, 0xdf, 0x1e, 0x63 } };
pub fn debugEnableGpuValidation(object: *Object) void {
    invoke(4, *const fn (*Object, i32) callconv(call_conv) void, object, .{1});
    invoke(5, *const fn (*Object, i32) callconv(call_conv) void, object, .{1});
}
pub fn enableDred(object: *Object) void {
    invoke(3, *const fn (*Object, u32) callconv(call_conv) void, object, .{2});
    invoke(4, *const fn (*Object, u32) callconv(call_conv) void, object, .{2});
}
