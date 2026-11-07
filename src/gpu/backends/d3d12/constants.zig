//! Native D3D12 tokens used by the backend, from the Windows SDK d3d12.h.
//! Format, filter and state values shared with D3D11 come from ../dxgi/constants.zig.

// D3D12_FEATURE, D3D12_FORMAT_SUPPORT2
pub const feature_format_support: u32 = 3;
pub const feature_root_signature: u32 = 12;
pub const format_support2_uav_typed_load: u32 = 0x40;
pub const format_support2_uav_typed_store: u32 = 0x80;

// D3D12_HEAP_TYPE, D3D12_HEAP_FLAGS
pub const heap_default: u32 = 1;
pub const heap_upload: u32 = 2;
pub const heap_readback: u32 = 3;
pub const heap_flag_none: u32 = 0;

// D3D12_RESOURCE_STATES
pub const state_common: u32 = 0x0;
pub const state_vertex_and_constant_buffer: u32 = 0x1;
pub const state_index_buffer: u32 = 0x2;
pub const state_render_target: u32 = 0x4;
pub const state_unordered_access: u32 = 0x8;
pub const state_depth_write: u32 = 0x10;
pub const state_non_pixel_shader_resource: u32 = 0x40;
pub const state_pixel_shader_resource: u32 = 0x80;
pub const state_copy_dest: u32 = 0x400;
pub const state_copy_source: u32 = 0x800;
pub const state_resolve_dest: u32 = 0x1000;
pub const state_resolve_source: u32 = 0x2000;
pub const state_present: u32 = 0x0;
pub const state_generic_read: u32 = 0xac3;

// D3D12_RESOURCE_DIMENSION, D3D12_RESOURCE_FLAGS, D3D12_TEXTURE_LAYOUT
pub const dimension_buffer: u32 = 1;
pub const dimension_texture2d: u32 = 3;
pub const dimension_texture3d: u32 = 4;
pub const resource_flag_allow_render_target: u32 = 0x1;
pub const resource_flag_allow_depth_stencil: u32 = 0x2;
pub const resource_flag_allow_unordered_access: u32 = 0x4;
pub const texture_layout_unknown: u32 = 0;
pub const texture_layout_row_major: u32 = 1;

// D3D12_COMMAND_LIST_TYPE, D3D12_COMMAND_QUEUE_FLAGS
pub const command_list_type_direct: u32 = 0;
pub const queue_flag_none: u32 = 0;

// D3D12_DESCRIPTOR_HEAP_TYPE, D3D12_DESCRIPTOR_HEAP_FLAGS
pub const heap_type_cbv_srv_uav: u32 = 0;
pub const heap_type_sampler: u32 = 1;
pub const heap_type_rtv: u32 = 2;
pub const heap_type_dsv: u32 = 3;
pub const descriptor_heap_flag_none: u32 = 0;
pub const descriptor_heap_flag_shader_visible: u32 = 0x1;

// D3D12_RESOURCE_BARRIER_TYPE, D3D12_RESOURCE_BARRIER_FLAGS
pub const barrier_type_transition: u32 = 0;
pub const barrier_type_uav: u32 = 2;
pub const barrier_flag_none: u32 = 0;

// View dimensions and flags
pub const srv_dimension_buffer: u32 = 1;
pub const srv_dimension_texture2d: u32 = 4;
pub const srv_dimension_texture2darray: u32 = 5;
pub const srv_dimension_texture2dms: u32 = 6;
pub const srv_dimension_texture2dmsarray: u32 = 7;
pub const srv_dimension_texture3d: u32 = 8;
pub const srv_dimension_texturecube: u32 = 9;
pub const uav_dimension_buffer: u32 = 1;
pub const uav_dimension_texture2d: u32 = 4;
pub const uav_dimension_texture2darray: u32 = 5;
pub const uav_dimension_texture3d: u32 = 8;
pub const rtv_dimension_texture2d: u32 = 4;
pub const rtv_dimension_texture2darray: u32 = 5;
pub const rtv_dimension_texture2dms: u32 = 6;
pub const rtv_dimension_texture2dmsarray: u32 = 7;
pub const rtv_dimension_texture3d: u32 = 8;
pub const dsv_dimension_texture2d: u32 = 3;
pub const dsv_dimension_texture2darray: u32 = 4;
pub const dsv_dimension_texture2dms: u32 = 5;
pub const dsv_dimension_texture2dmsarray: u32 = 6;
pub const buffer_srv_flag_raw: u32 = 0x1;
pub const buffer_uav_flag_raw: u32 = 0x1;
pub const clear_depth: u32 = 0x1;
pub const clear_stencil: u32 = 0x2;

// Primitive topology types, shader visibility, root signature
pub const primitive_topology_type_point: u32 = 1;
pub const primitive_topology_type_line: u32 = 2;
pub const primitive_topology_type_triangle: u32 = 3;
pub const shader_visibility_all: u32 = 0;
pub const shader_visibility_vertex: u32 = 1;
pub const shader_visibility_pixel: u32 = 5;
pub const root_parameter_descriptor_table: u32 = 0;
pub const root_parameter_cbv: u32 = 2;
pub const range_type_srv: u32 = 0;
pub const range_type_uav: u32 = 1;
pub const range_type_sampler: u32 = 3;
pub const root_signature_flag_allow_input_assembler_input_layout: u32 = 0x1;
pub const root_signature_version_1_0: u32 = 0x1;
pub const root_signature_version_1_1: u32 = 0x2;
pub const descriptor_range_data_volatile: u32 = 0x2;
pub const descriptor_range_static_keeping_buffer_bounds_checks: u32 = 0x10000;
pub const root_descriptor_data_static_while_set_at_execute: u32 = 0x4;
pub const descriptor_range_offset_append: u32 = 0xffffffff;

// Copies and alignment
pub const texture_copy_subresource_index: u32 = 0;
pub const texture_copy_placed_footprint: u32 = 1;
pub const texture_data_pitch_alignment: u32 = 256;
pub const texture_data_placement_alignment: u32 = 512;

// Debug messages
pub const message_severity_corruption: u32 = 0;
pub const message_severity_error: u32 = 1;
