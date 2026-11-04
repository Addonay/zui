//! Validation layer, from sokol_gfx.h:24749-26691.
//!
//! Each check that fails logs its validation log item. In debug builds a failed
//! validation then raises VALIDATION_FAILED as a panic-level log item unless the
//! `validate_non_fatal` build option is set. Outside debug builds (or with
//! `Desc.disable_validation`) the checks are skipped, except for the binding
//! and attachment limit checks, which are always active as in the original.
const std = @import("std");
const t = @import("types.zig");
const e = @import("enums.zig");
const config = @import("config.zig");
const formats = @import("formats.zig");
const core = @import("core.zig");

const State = core.State;

const Validator = struct {
    failed: bool = false,

    fn check(v: *Validator, cond: bool, item: e.LogItem) void {
        if (cond) return;
        v.failed = true;
        core.state().validate_error = item;
        core.logError(item);
    }

    fn end(v: *const Validator) bool {
        if (!v.failed) return true;
        if (!config.validate_non_fatal) core.logPanic(.validation_failed);
        return false;
    }
};

fn enabled() bool {
    return config.debug and !core.state().desc.disable_validation;
}

fn isGl(backend: e.Backend) bool {
    return backend == .glcore or backend == .gles3;
}
fn isD3d(backend: e.Backend) bool {
    return backend == .d3d11 or backend == .d3d12;
}
fn isMetal(backend: e.Backend) bool {
    return backend == .metal_ios or backend == .metal_macos or backend == .metal_simulator;
}

fn one(b0: bool, b1: bool, b2: bool) bool {
    return @as(u32, @intFromBool(b0)) + @intFromBool(b1) + @intFromBool(b2) == 1;
}

fn multipleU64(val: u64, of: u64) bool {
    std.debug.assert(of > 0);
    return val % of == 0;
}

fn multiple(val: i32, of: i32) bool {
    std.debug.assert(val >= 0 and of > 0);
    return @mod(val, of) == 0;
}

fn formatInfo(fmt: e.PixelFormat) t.PixelformatInfo {
    const index = @backingInt(fmt);
    std.debug.assert(index < core.num_pixel_formats);
    return core.state().formats[index];
}

// ---------------------------------------------------------------- resource descriptors

pub fn bufferDesc(desc: *const t.BufferDesc) bool {
    if (!enabled()) return true;
    const s = core.state();
    const usage = desc.usage;
    const injected = desc.gl_buffer != 0 or desc.mtl_buffer != null or desc.d3d11_buffer != null or desc.wgpu_buffer != null;
    var v: Validator = .{};
    v.check(desc._start_canary == 0, .validate_bufferdesc_canary);
    v.check(desc._end_canary == 0, .validate_bufferdesc_canary);
    v.check(desc.size > 0, .validate_bufferdesc_expect_nonzero_size);
    if (usage.staging_buffer or usage.staging_index_buffer) {
        // staging buffer type cannot be combined with vertex/index/storage types
        v.check(!usage.vertex_buffer, .validate_bufferdesc_staging_vs_vertexbuffer);
        v.check(!usage.index_buffer, .validate_bufferdesc_staging_vs_indexbuffer);
        v.check(!usage.storage_buffer, .validate_bufferdesc_staging_vs_storagebuffer);
        v.check(!injected, .validate_bufferdesc_staging_vs_injected);
        v.check(!usage.copy_dst, .validate_bufferdesc_staging_vs_copydst);
        v.check(usage.copy_src, .validate_bufferdesc_staging_copysrc);
        v.check(desc.data.ptr == null, .validate_bufferdesc_staging_vs_initialdata);
    }
    if (s.features.separate_buffer_types and !(usage.staging_buffer or usage.staging_index_buffer)) {
        v.check(one(usage.vertex_buffer, usage.index_buffer, usage.storage_buffer), .validate_bufferdesc_separate_buffer_types);
    }
    if (usage.write_unsealed) {
        v.check(!usage.write_transient, .validate_bufferdesc_writeunsealed_vs_writetransient);
        v.check(!usage.copy_dst, .validate_bufferdesc_writeunsealed_vs_copydst);
        v.check(!(usage.staging_buffer or usage.staging_index_buffer), .validate_bufferdesc_writeunsealed_vs_staging);
        v.check(desc.data.ptr == null, .validate_bufferdesc_writeunsealed_vs_initialdata);
    }
    if (usage.write_transient) {
        v.check(!usage.copy_dst, .validate_bufferdesc_writetransient_vs_copydst);
        v.check(desc.data.ptr == null, .validate_bufferdesc_writetransient_vs_initialdata);
        v.check(!injected, .validate_bufferdesc_writetransient_vs_injected);
    }
    if (usage.copy_dst) {
        v.check(desc.data.ptr == null, .validate_bufferdesc_copydst_vs_initialdata);
    }
    if (desc.data.ptr != null) {
        v.check(desc.size == desc.data.size, .validate_bufferdesc_expect_matching_data_size);
    } else {
        v.check(desc.data.size == 0, .validate_bufferdesc_expect_zero_data_size);
        // storage buffers can be initialized by compute shaders
        if (!injected and !usage.storage_buffer) {
            v.check(usage.write_unsealed or usage.write_transient or usage.copy_dst, .validate_bufferdesc_expect_data);
        }
    }
    if (usage.storage_buffer) {
        v.check(s.features.compute, .validate_bufferdesc_storagebuffer_supported);
        v.check(multipleU64(desc.size, 4), .validate_bufferdesc_storagebuffer_size_multiple_4);
    }
    return v.end();
}

fn imageData(v: *Validator, data: *const t.ImageData, fmt: e.PixelFormat, width: i32, height: i32, num_mips: i32, num_slices: i32) void {
    for (0..@intCast(@max(num_mips, 0))) |mip_index| {
        const level = data.mip_levels[mip_index];
        v.check(level.ptr != null and level.size > 0, .validate_imagedata_nodata);
        const mip: i32 = @intCast(mip_index);
        const bytes_per_slice = formats.surfacePitch(fmt, core.miplevelDim(width, mip), core.miplevelDim(height, mip), 1);
        v.check(@as(i64, bytes_per_slice) * num_slices == level.size, .validate_imagedata_data_size);
    }
}

pub fn imageDesc(desc: *const t.ImageDesc) bool {
    if (!enabled()) return true;
    const s = core.state();
    const usg = desc.usage;
    const any_attachment = usg.color_attachment or usg.resolve_attachment or usg.depth_stencil_attachment;
    var v: Validator = .{};
    v.check(desc._start_canary == 0, .validate_imagedesc_canary);
    v.check(desc._end_canary == 0, .validate_imagedesc_canary);
    v.check(one(usg.immutable, usg.write_transient, usg.copy_dst), .validate_imagedesc_immutable_vs_writable);
    v.check(!(usg.color_attachment and usg.depth_stencil_attachment), .validate_imagedesc_attachment_color_depth_stencil);
    switch (desc.type) {
        .@"2d" => v.check(desc.num_slices == 1, .validate_imagedesc_imagetype_2d_numslices),
        .cube => v.check(desc.num_slices == 6, .validate_imagedesc_imagetype_cube_numslices),
        .array => v.check(desc.num_slices >= 1 and desc.num_slices <= s.limits.max_image_array_layers, .validate_imagedesc_imagetype_array_numslices),
        .@"3d" => v.check(desc.num_slices >= 1 and desc.num_slices <= s.limits.max_image_size_3d, .validate_imagedesc_imagetype_3d_numslices),
        else => unreachable,
    }
    v.check(desc.width > 0, .validate_imagedesc_width);
    v.check(desc.height > 0, .validate_imagedesc_height);
    const fmt = desc.pixel_format;
    const injected = desc.gl_texture != 0 or desc.mtl_texture != null or desc.d3d11_texture != null or desc.wgpu_texture != null;
    if (core.isDepthOrDepthStencilFormat(fmt)) {
        v.check(desc.type != .@"3d", .validate_imagedesc_depth_3d_image);
    }
    if (any_attachment) {
        v.check(usg.immutable, .validate_imagedesc_attachment_expect_immutable);
        v.check(desc.data.mip_levels[0].ptr == null, .validate_imagedesc_attachment_expect_no_data);
        v.check(formatInfo(fmt).render, .validate_imagedesc_attachment_pixelformat);
        if (usg.resolve_attachment) {
            v.check(desc.sample_count == 1, .validate_imagedesc_attachment_resolve_expect_no_msaa);
        }
        if (desc.sample_count > 1) {
            v.check(formatInfo(fmt).msaa, .validate_imagedesc_attachment_no_msaa_support);
            v.check(desc.num_mipmaps == 1, .validate_imagedesc_attachment_msaa_num_mipmaps);
            v.check(desc.type != .array, .validate_imagedesc_attachment_msaa_array_image);
            v.check(desc.type != .@"3d", .validate_imagedesc_attachment_msaa_3d_image);
            v.check(desc.type != .cube, .validate_imagedesc_attachment_msaa_cube_image);
        }
    }
    if (usg.storage_image) {
        v.check(usg.immutable, .validate_imagedesc_storageimage_expect_immutable);
        v.check(desc.data.mip_levels[0].ptr == null, .validate_imagedesc_storageimage_expect_no_data);
        v.check(core.isValidStorageImageFormat(fmt), .validate_imagedesc_storageimage_pixelformat);
        // D3D11 doesn't allow multisampled UAVs
        v.check(desc.sample_count == 1, .validate_imagedesc_storageimage_expect_no_msaa);
    }
    if (usg.write_unsealed) {
        v.check(usg.immutable, .validate_imagedesc_writeunsealed_vs_immutable);
        v.check(!any_attachment, .validate_imagedesc_writeunsealed_vs_attachment);
    }
    if (usg.write_transient) {
        v.check(!any_attachment, .validate_imagedesc_writetransient_vs_attachment);
        v.check(!injected, .validate_imagedesc_writetransient_vs_injected);
    }
    if (usg.copy_dst) {
        v.check(!any_attachment, .validate_imagedesc_copydst_vs_attachment);
    }
    if (!any_attachment and !usg.storage_image) {
        v.check(desc.sample_count == 1, .validate_imagedesc_msaa_but_no_attachment);
        v.check(!core.isValidAttachmentDepthFormat(fmt), .validate_imagedesc_nonrt_pixelformat);
        if (!injected and !usg.write_unsealed and usg.immutable) {
            // an immutable image must have valid data
            imageData(&v, &desc.data, fmt, desc.width, desc.height, desc.num_mipmaps, desc.num_slices);
        } else {
            for (desc.data.mip_levels) |level| {
                const empty = level.ptr == null and level.size == 0;
                if (injected) v.check(empty, .validate_imagedesc_injected_no_data);
                if (!usg.immutable or usg.write_unsealed) v.check(empty, .validate_imagedesc_writable_no_data);
            }
        }
    }
    return v.end();
}

pub fn samplerDesc(desc: *const t.SamplerDesc) bool {
    if (!enabled()) return true;
    var v: Validator = .{};
    v.check(desc._start_canary == 0, .validate_samplerdesc_canary);
    v.check(desc._end_canary == 0, .validate_samplerdesc_canary);
    // restriction from WebGPU: when anisotropy > 1, all filters must be linear
    if (desc.max_anisotropy > 1) {
        v.check(desc.min_filter == .linear and desc.mag_filter == .linear and desc.mipmap_filter == .linear, .validate_samplerdesc_anistropic_requires_linear_filtering);
    }
    return v.end();
}

/// Bind slot collision masks: vertex and compute bits in the low half,
/// fragment bits in the high half, stage-less slots address all 128 bits.
fn slotBit(stage: e.ShaderStage, slot: u8) u128 {
    return switch (stage) {
        .none => blk: {
            std.debug.assert(slot < 128);
            break :blk @as(u128, 1) << @intCast(slot);
        },
        .vertex, .compute => blk: {
            std.debug.assert(slot < 64);
            break :blk @as(u128, 1) << @intCast(slot);
        },
        .fragment => blk: {
            std.debug.assert(slot < 64);
            break :blk @as(u128, 1) << @intCast(@as(u32, slot) + 64);
        },
        else => unreachable,
    };
}

const SlotBits = struct {
    bits: u128 = 0,

    /// Checks that a slot is free, then marks it as used.
    fn claim(self: *SlotBits, v: *Validator, stage: e.ShaderStage, slot: u8, item: e.LogItem) void {
        const bit = slotBit(stage, slot);
        v.check(self.bits & bit == 0, item);
        self.bits |= bit;
    }
};

fn strLen(str: [*:0]const u8) usize {
    return std.mem.len(str);
}

pub fn shaderDesc(desc: *const t.ShaderDesc) bool {
    if (!enabled()) return true;
    const backend = core.state().backend;
    const is_compute_shader = core.isComputeShaderDesc(desc);
    var v: Validator = .{};
    v.check(desc._start_canary == 0, .validate_shaderdesc_canary);
    v.check(desc._end_canary == 0, .validate_shaderdesc_canary);
    if (isGl(backend) or backend == .wgpu) {
        // on GL or WebGPU, must provide shader source code
        if (is_compute_shader) {
            v.check(desc.compute_func.source != null, .validate_shaderdesc_compute_source);
        } else {
            v.check(desc.vertex_func.source != null, .validate_shaderdesc_vertex_source);
            v.check(desc.fragment_func.source != null, .validate_shaderdesc_fragment_source);
        }
    } else if (isMetal(backend) or isD3d(backend)) {
        // on Metal or D3D11, must provide shader source code or byte code
        if (is_compute_shader) {
            v.check(desc.compute_func.source != null or desc.compute_func.bytecode.ptr != null, .validate_shaderdesc_compute_source_or_bytecode);
        } else {
            v.check(desc.vertex_func.source != null or desc.vertex_func.bytecode.ptr != null, .validate_shaderdesc_vertex_source_or_bytecode);
            v.check(desc.fragment_func.source != null or desc.fragment_func.bytecode.ptr != null, .validate_shaderdesc_fragment_source_or_bytecode);
        }
    }
    if (is_compute_shader) {
        v.check(desc.vertex_func.source == null and desc.vertex_func.bytecode.ptr == null, .validate_shaderdesc_invalid_shader_combo);
        v.check(desc.fragment_func.source == null and desc.fragment_func.bytecode.ptr == null, .validate_shaderdesc_invalid_shader_combo);
    } else {
        v.check(desc.compute_func.source == null and desc.compute_func.bytecode.ptr == null, .validate_shaderdesc_invalid_shader_combo);
    }
    if (isMetal(backend) and is_compute_shader) {
        const tg = desc.mtl_threads_per_threadgroup;
        v.check(tg.x > 0 and tg.y > 0 and tg.z > 0, .validate_shaderdesc_metal_threads_per_threadgroup_initialized);
        v.check(((tg.x *% tg.y *% tg.z) & 31) == 0, .validate_shaderdesc_metal_threads_per_threadgroup_multiple_32);
    }
    for (desc.attrs) |attr| {
        if (attr.glsl_name) |name| v.check(strLen(name) < 32, .validate_shaderdesc_attr_string_too_long);
        if (attr.hlsl_sem_name) |name| v.check(strLen(name) < 32, .validate_shaderdesc_attr_string_too_long);
    }
    // if shader byte code, the size must also be provided
    inline for (.{ "vertex_func", "fragment_func", "compute_func" }) |name| {
        const func = @field(desc, name);
        if (func.bytecode.ptr != null) v.check(func.bytecode.size > 0, .validate_shaderdesc_no_bytecode_size);
    }

    var msl_buf: SlotBits = .{};
    var msl_tex: SlotBits = .{};
    var msl_smp: SlotBits = .{};
    var hlsl_buf: SlotBits = .{};
    var hlsl_srv: SlotBits = .{};
    var hlsl_uav: SlotBits = .{};
    var hlsl_smp: SlotBits = .{};
    var glsl_sbuf: SlotBits = .{};
    var glsl_simg: SlotBits = .{};
    var wgsl_group0: SlotBits = .{};
    var wgsl_group1: SlotBits = .{};
    var spirv_set0: SlotBits = .{};
    var spirv_set1: SlotBits = .{};

    for (desc.uniform_blocks) |ub| {
        if (ub.stage == .none) continue;
        v.check(ub.size > 0, .validate_shaderdesc_uniformblock_size_is_zero);
        if (isMetal(backend)) {
            msl_buf.claim(&v, ub.stage, ub.msl_buffer_n, .validate_shaderdesc_uniformblock_metal_buffer_slot_collision);
        } else if (isD3d(backend)) {
            hlsl_buf.claim(&v, ub.stage, ub.hlsl_register_b_n, .validate_shaderdesc_uniformblock_hlsl_register_b_collision);
        } else if (backend == .wgpu) {
            wgsl_group0.claim(&v, .none, ub.wgsl_group0_binding_n, .validate_shaderdesc_uniformblock_wgsl_group0_binding_collision);
        } else if (backend == .vulkan) {
            spirv_set0.claim(&v, .none, ub.spirv_set0_binding_n, .validate_shaderdesc_uniformblock_spirv_set0_binding_collision);
        }
        if (isGl(backend)) {
            var uniforms_continuous = true;
            var uniform_offset: u32 = 0;
            var num_uniforms: u32 = 0;
            for (ub.glsl_uniforms) |u| {
                if (u.type == .invalid) {
                    uniforms_continuous = false;
                    continue;
                }
                v.check(uniforms_continuous, .validate_shaderdesc_uniformblock_no_cont_members);
                v.check(u.glsl_name != null, .validate_shaderdesc_uniformblock_uniform_glsl_name);
                v.check(u.array_count > 0, .validate_shaderdesc_uniformblock_array_count);
                uniform_offset = core.alignU32(uniform_offset, formats.uniformAlignment(u.type, u.array_count, ub.layout));
                uniform_offset += formats.uniformSize(u.type, u.array_count, ub.layout);
                num_uniforms += 1;
                // with std140, arrays are only allowed for FLOAT4, INT4, MAT4
                if (ub.layout == .std140 and u.array_count > 1) {
                    v.check(u.type == .float4 or u.type == .int4 or u.type == .mat4, .validate_shaderdesc_uniformblock_std140_array_type);
                }
            }
            if (ub.layout == .std140) uniform_offset = core.alignU32(uniform_offset, 16);
            v.check(uniform_offset == ub.size, .validate_shaderdesc_uniformblock_size_mismatch);
            v.check(num_uniforms > 0, .validate_shaderdesc_uniformblock_no_members);
        }
    }

    var texview_slot_mask: u32 = 0;
    for (desc.views, 0..) |view, view_idx| {
        if (view.texture.stage != .none) {
            const tex = view.texture;
            texview_slot_mask |= @as(u32, 1) << @intCast(view_idx);
            if (isMetal(backend)) {
                msl_tex.claim(&v, tex.stage, tex.msl_texture_n, .validate_shaderdesc_view_texture_metal_texture_slot_collision);
            } else if (isD3d(backend)) {
                hlsl_srv.claim(&v, tex.stage, tex.hlsl_register_t_n, .validate_shaderdesc_view_texture_hlsl_register_t_collision);
            } else if (backend == .wgpu) {
                wgsl_group1.claim(&v, .none, tex.wgsl_group1_binding_n, .validate_shaderdesc_view_texture_wgsl_group1_binding_collision);
            } else if (backend == .vulkan) {
                spirv_set1.claim(&v, .none, tex.spirv_set1_binding_n, .validate_shaderdesc_view_texture_spirv_set1_binding_collision);
            }
        } else if (view.storage_buffer.stage != .none) {
            const sbuf = view.storage_buffer;
            if (sbuf.stage == .vertex) {
                v.check(sbuf.readonly, .validate_shaderdesc_view_storagebuffer_vertexshader_readwrite);
            }
            if (isMetal(backend)) {
                msl_buf.claim(&v, sbuf.stage, sbuf.msl_buffer_n, .validate_shaderdesc_view_storagebuffer_metal_buffer_slot_collision);
            } else if (isD3d(backend)) {
                if (sbuf.readonly) {
                    hlsl_srv.claim(&v, sbuf.stage, sbuf.hlsl_register_t_n, .validate_shaderdesc_view_storagebuffer_hlsl_register_t_collision);
                } else {
                    hlsl_uav.claim(&v, sbuf.stage, sbuf.hlsl_register_u_n, .validate_shaderdesc_view_storagebuffer_hlsl_register_u_collision);
                }
            } else if (isGl(backend)) {
                glsl_sbuf.claim(&v, .none, sbuf.glsl_binding_n, .validate_shaderdesc_view_storagebuffer_glsl_binding_collision);
            } else if (backend == .wgpu) {
                wgsl_group1.claim(&v, .none, sbuf.wgsl_group1_binding_n, .validate_shaderdesc_view_storagebuffer_wgsl_group1_binding_collision);
            } else if (backend == .vulkan) {
                spirv_set1.claim(&v, .none, sbuf.spirv_set1_binding_n, .validate_shaderdesc_view_storagebuffer_spirv_set1_binding_collision);
            }
        } else if (view.storage_image.stage != .none) {
            const simg = view.storage_image;
            v.check(simg.stage == .compute, .validate_shaderdesc_view_storageimage_expect_compute_stage);
            if (isMetal(backend)) {
                msl_tex.claim(&v, simg.stage, simg.msl_texture_n, .validate_shaderdesc_view_storageimage_metal_texture_slot_collision);
            } else if (isD3d(backend)) {
                hlsl_uav.claim(&v, simg.stage, simg.hlsl_register_u_n, .validate_shaderdesc_view_storageimage_hlsl_register_u_collision);
            } else if (isGl(backend)) {
                glsl_simg.claim(&v, .none, simg.glsl_binding_n, .validate_shaderdesc_view_storageimage_glsl_binding_collision);
            } else if (backend == .wgpu) {
                wgsl_group1.claim(&v, .none, simg.wgsl_group1_binding_n, .validate_shaderdesc_view_storageimage_wgsl_group1_binding_collision);
            } else if (backend == .vulkan) {
                spirv_set1.claim(&v, .none, simg.spirv_set1_binding_n, .validate_shaderdesc_view_storageimage_spirv_set1_binding_collision);
            }
        }
    }

    var smp_slot_mask: u32 = 0;
    for (desc.samplers, 0..) |smp, smp_idx| {
        if (smp.stage == .none) continue;
        smp_slot_mask |= @as(u32, 1) << @intCast(smp_idx);
        if (isMetal(backend)) {
            msl_smp.claim(&v, smp.stage, smp.msl_sampler_n, .validate_shaderdesc_sampler_metal_sampler_slot_collision);
        } else if (isD3d(backend)) {
            hlsl_smp.claim(&v, smp.stage, smp.hlsl_register_s_n, .validate_shaderdesc_sampler_hlsl_register_s_collision);
        } else if (backend == .wgpu) {
            wgsl_group1.claim(&v, .none, smp.wgsl_group1_binding_n, .validate_shaderdesc_sampler_wgsl_group1_binding_collision);
        } else if (backend == .vulkan) {
            spirv_set1.claim(&v, .none, smp.spirv_set1_binding_n, .validate_shaderdesc_sampler_spirv_set1_binding_collision);
        }
    }

    var ref_texview_slot_mask: u32 = 0;
    var ref_smp_slot_mask: u32 = 0;
    for (desc.texture_sampler_pairs) |pair| {
        if (pair.stage == .none) continue;
        if (isGl(backend)) v.check(pair.glsl_name != null, .validate_shaderdesc_texture_sampler_pair_glsl_name);
        const view_slot_in_range = pair.view_slot < 32;
        const smp_slot_in_range = pair.sampler_slot < 12;
        v.check(view_slot_in_range, .validate_shaderdesc_texture_sampler_pair_view_slot_out_of_range);
        v.check(smp_slot_in_range, .validate_shaderdesc_texture_sampler_pair_sampler_slot_out_of_range);
        if (!(view_slot_in_range and smp_slot_in_range)) continue;
        ref_texview_slot_mask |= @as(u32, 1) << @intCast(pair.view_slot);
        ref_smp_slot_mask |= @as(u32, 1) << @intCast(pair.sampler_slot);
        const view = desc.views[pair.view_slot];
        const smp = desc.samplers[pair.sampler_slot];
        v.check(view.texture.stage != .none, .validate_shaderdesc_texture_sampler_pair_expect_texture_view);
        v.check(view.texture.stage == pair.stage, .validate_shaderdesc_texture_sampler_pair_texture_stage_mismatch);
        v.check(smp.stage == pair.stage, .validate_shaderdesc_texture_sampler_pair_sampler_stage_mismatch);
        const sample_type = view.texture.sample_type;
        if (sample_type == .uint or sample_type == .sint or sample_type == .unfilterable_float) {
            v.check(smp.sampler_type == .nonfiltering, .validate_shaderdesc_nonfiltering_sampler_required);
        }
        if (sample_type == .depth) {
            v.check(smp.sampler_type == .comparison, .validate_shaderdesc_comparison_sampler_required);
        }
    }
    // each texture view and sampler must be referenced by a texture-sampler pair
    v.check(texview_slot_mask == ref_texview_slot_mask, .validate_shaderdesc_texview_not_referenced_by_texture_sampler_pairs);
    v.check(smp_slot_mask == ref_smp_slot_mask, .validate_shaderdesc_sampler_not_referenced_by_texture_sampler_pairs);
    return v.end();
}

pub fn pipelineDesc(desc: *const t.PipelineDesc) bool {
    if (!enabled()) return true;
    const s = core.state();
    var v: Validator = .{};
    v.check(desc._start_canary == 0, .validate_pipelinedesc_canary);
    v.check(desc._end_canary == 0, .validate_pipelinedesc_canary);
    v.check(desc.shader.id != 0, .validate_pipelinedesc_shader);
    const maybe_shd = core.lookupShader(desc.shader.id);
    v.check(maybe_shd != null, .validate_pipelinedesc_shader);
    if (maybe_shd) |shd| {
        v.check(shd.slot.state == .valid, .validate_pipelinedesc_shader);
        if (desc.compute) {
            v.check(shd.cmn.is_compute, .validate_pipelinedesc_compute_shader_expected);
        } else {
            v.check(!shd.cmn.is_compute, .validate_pipelinedesc_no_compute_shader_expected);
            var attrs_cont = true;
            for (desc.layout.attrs, 0..) |attr, attr_index| {
                if (attr.format == .invalid) {
                    attrs_cont = false;
                    continue;
                }
                v.check(attrs_cont, .validate_pipelinedesc_no_cont_attrs);
                std.debug.assert(attr.buffer_index < 8);
                // vertex format must match the expected shader attribute base type (if provided)
                const base_type = shd.cmn.attrs[attr_index].base_type;
                if (base_type != .undefined and formats.vertexBaseType(attr.format) != base_type) {
                    v.check(false, .validate_pipelinedesc_attr_basetype_mismatch);
                    core.logMsg(.validate_pipelinedesc_attr_basetype_mismatch, "attr format:");
                    core.logMsg(.validate_pipelinedesc_attr_basetype_mismatch, formats.vertexName(attr.format).ptr);
                    core.logMsg(.validate_pipelinedesc_attr_basetype_mismatch, "shader attr base type:");
                    core.logMsg(.validate_pipelinedesc_attr_basetype_mismatch, formats.shaderAttrBaseTypeName(base_type).ptr);
                }
                if (attr.format == .int10_n2) {
                    v.check(s.features.vertexformat_int10_n2, .validate_pipelinedesc_attr_vertexformat_int10_n2_not_supported);
                }
                if (s.backend == .d3d11 and shd.native == .d3d11) {
                    // on D3D11, semantic names (and semantic indices) must be provided
                    v.check(shd.native.d3d11.semantic_names[attr_index][0] != 0, .validate_pipelinedesc_attr_semantics);
                }
            }
            for (shd.cmn.views, 0..) |view, i| {
                if (view.view_type != .storagebuffer or view.sbuf_readonly) continue;
                // read/write storage buffer bindings are not allowed in vertex shaders
                v.check(view.stage != .vertex, .validate_pipelinedesc_shader_readonly_storagebuffers);
                if (s.backend == .d3d11 and shd.native == .d3d11) {
                    // on D3D11, fragment shader UAV slots must not collide with color render target slots
                    const reg = shd.native.d3d11.uav_registers[i];
                    v.check(reg >= desc.color_count, .validate_pipelinedesc_shader_hlsl_register_u_vs_color_count);
                    v.check(reg < s.limits.d3d11_max_unordered_access_views, .validate_pipelinedesc_shader_hlsl_register_u_limit);
                }
            }
            for (desc.layout.buffers) |buf| {
                if (buf.stride == 0) continue;
                v.check(buf.stride > 0 and @mod(buf.stride, 4) == 0, .validate_pipelinedesc_layout_stride4);
            }
        }
    }
    if (desc.depth.pixel_format == .none) {
        v.check(!desc.depth.write_enabled, .validate_pipelinedesc_depth_format_none_but_depth_write_enabled);
        v.check(desc.depth.compare == .always or desc.depth.compare == .never, .validate_pipelinedesc_depth_format_none_compare_func_mismatch);
    }
    v.check(desc.color_count >= 0 and desc.color_count <= 8, .validate_pipelinedesc_color_count);
    for (desc.colors[0..@intCast(std.math.clamp(desc.color_count, 0, 8))]) |color| {
        const bs = color.blend;
        if (bs.op_rgb == .min or bs.op_rgb == .max) {
            v.check(bs.src_factor_rgb == .one and bs.dst_factor_rgb == .one, .validate_pipelinedesc_blendop_minmax_requires_blendfactor_one);
        }
        if (bs.op_alpha == .min or bs.op_alpha == .max) {
            v.check(bs.src_factor_alpha == .one and bs.dst_factor_alpha == .one, .validate_pipelinedesc_blendop_minmax_requires_blendfactor_one);
        }
        const needs_dualsource_blending = core.isDualSourceBlendFactor(bs.src_factor_rgb) or
            core.isDualSourceBlendFactor(bs.dst_factor_rgb) or
            core.isDualSourceBlendFactor(bs.src_factor_alpha) or
            core.isDualSourceBlendFactor(bs.dst_factor_alpha);
        if (needs_dualsource_blending) {
            v.check(s.features.dual_source_blending, .validate_pipelinedesc_dual_source_blending_not_supported);
        }
    }
    return v.end();
}

pub fn viewDesc(desc: *const t.ViewDesc) bool {
    if (!enabled()) return true;
    const s = core.state();
    var v: Validator = .{};
    v.check(desc._start_canary == 0, .validate_viewdesc_canary);
    v.check(desc._end_canary == 0, .validate_viewdesc_canary);

    // only one view type can be defined
    var view_type: e.ViewType = .invalid;
    var img_desc: ?*const t.ImageViewDesc = null;
    var tex_desc: ?*const t.TextureViewDesc = null;
    var buf_desc: ?*const t.BufferViewDesc = null;
    if (desc.texture.image.id != 0) {
        view_type = .texture;
        tex_desc = &desc.texture;
    }
    if (desc.storage_buffer.buffer.id != 0) {
        v.check(view_type == .invalid, .validate_viewdesc_unique_viewtype);
        view_type = .storagebuffer;
        buf_desc = &desc.storage_buffer;
    }
    inline for (.{
        .{ "storage_image", e.ViewType.storageimage },
        .{ "color_attachment", e.ViewType.colorattachment },
        .{ "resolve_attachment", e.ViewType.resolveattachment },
        .{ "depth_stencil_attachment", e.ViewType.depthstencilattachment },
    }) |entry| {
        if (@field(desc, entry[0]).image.id != 0) {
            v.check(view_type == .invalid, .validate_viewdesc_unique_viewtype);
            view_type = entry[1];
            img_desc = &@field(desc, entry[0]);
        }
    }
    v.check(view_type != .invalid, .validate_viewdesc_any_viewtype);

    var buf: ?*core.Buffer = null;
    var img: ?*core.Image = null;
    var res_valid = false;
    if (buf_desc) |bd| {
        buf = core.lookupBuffer(bd.buffer.id);
        v.check(buf != null, .validate_viewdesc_resource_alive);
        if (buf) |b| {
            v.check(b.slot.state == .valid, .validate_viewdesc_resource_valid);
            res_valid = b.slot.state == .valid;
        }
    } else if (img_desc) |id| {
        img = core.lookupImage(id.image.id);
        v.check(img != null, .validate_viewdesc_resource_alive);
        if (img) |i| {
            v.check(i.slot.state == .valid, .validate_viewdesc_resource_valid);
            res_valid = i.slot.state == .valid;
        }
    } else if (tex_desc) |td| {
        img = core.lookupImage(td.image.id);
        v.check(img != null, .validate_viewdesc_resource_alive);
        if (img) |i| {
            const valid_or_unsealed = core.stateValidUnsealed(i.slot.state);
            v.check(valid_or_unsealed, .validate_viewdesc_image_valid_unsealed);
            res_valid = valid_or_unsealed;
        }
    }
    if (res_valid) {
        // check usage flags
        switch (view_type) {
            .storagebuffer => v.check(buf.?.cmn.usage.storage_buffer, .validate_viewdesc_storagebuffer_usage),
            .storageimage => {
                v.check(img.?.cmn.usage.storage_image, .validate_viewdesc_storageimage_usage);
                v.check(core.isValidStorageImageFormat(img.?.cmn.pixel_format), .validate_viewdesc_storageimage_pixelformat);
            },
            .texture => if (!s.features.msaa_texture_bindings) {
                v.check(img.?.cmn.sample_count == 1, .validate_viewdesc_texture_expect_no_msaa);
            },
            .colorattachment => {
                v.check(img.?.cmn.usage.color_attachment, .validate_viewdesc_colorattachment_usage);
                v.check(core.isValidAttachmentColorFormat(img.?.cmn.pixel_format), .validate_viewdesc_colorattachment_pixelformat);
            },
            .resolveattachment => {
                v.check(img.?.cmn.usage.resolve_attachment, .validate_viewdesc_resolveattachment_usage);
                v.check(img.?.cmn.sample_count == 1, .validate_viewdesc_resolveattachment_samplecount);
            },
            .depthstencilattachment => {
                v.check(img.?.cmn.usage.depth_stencil_attachment, .validate_viewdesc_depthstencilattachment_usage);
                v.check(core.isValidAttachmentDepthFormat(img.?.cmn.pixel_format), .validate_viewdesc_depthstencilattachment_pixelformat);
            },
            else => unreachable,
        }
        if (buf_desc) |bd| {
            v.check(bd.offset >= 0 and @as(usize, @intCast(@max(bd.offset, 0))) < buf.?.cmn.size, .validate_viewdesc_storagebuffer_offset_vs_buffer_size);
            v.check(bd.offset >= 0 and @mod(bd.offset, 256) == 0, .validate_viewdesc_storagebuffer_offset_multiple_256);
        } else if (img_desc) |id| {
            const cmn = &img.?.cmn;
            v.check(id.mip_level >= 0 and id.mip_level < cmn.num_mipmaps, .validate_viewdesc_image_miplevel);
            switch (cmn.type) {
                .@"2d" => v.check(id.slice == 0, .validate_viewdesc_image_2d_slice),
                .cube => v.check(id.slice >= 0 and id.slice < 6, .validate_viewdesc_image_cubemap_slice),
                .array => v.check(id.slice >= 0 and id.slice < cmn.num_slices, .validate_viewdesc_image_array_slice),
                .@"3d" => v.check(id.slice == 0, .validate_viewdesc_image_3d_slice),
                else => {},
            }
        } else if (tex_desc) |td| {
            const cmn = &img.?.cmn;
            // NOTE: it doesn't matter here if the mip/slice count is default-zero
            const max_mip_level = @as(i64, td.mip_levels.base) + td.mip_levels.count;
            const max_slice = @as(i64, td.slices.base) + td.slices.count;
            v.check(td.mip_levels.base >= 0 and max_mip_level <= cmn.num_mipmaps, .validate_viewdesc_texture_miplevels);
            switch (cmn.type) {
                .@"2d" => v.check(td.slices.base == 0 and max_slice <= 1, .validate_viewdesc_texture_2d_slices),
                .cube => v.check(td.slices.base == 0 and max_slice <= 1, .validate_viewdesc_texture_cubemap_slices),
                .array => v.check(td.slices.base >= 0 and max_slice <= cmn.num_slices, .validate_viewdesc_texture_array_slices),
                .@"3d" => v.check(td.slices.base == 0 and max_slice <= 1, .validate_viewdesc_texture_3d_slices),
                else => {},
            }
        }
    }
    return v.end();
}

// ---------------------------------------------------------------- passes

/// Validates one offscreen attachment view and returns its image if it is
/// alive and valid, so the caller can compare dimensions.
fn attachmentImage(v: *Validator, view: ?*core.View, comptime kind: enum { color, resolve, depth_stencil }) ?*core.Image {
    const items = switch (kind) {
        .color => .{ .validate_beginpass_colorattachmentview_alive, .validate_beginpass_colorattachmentview_valid, .validate_beginpass_colorattachmentview_type, .validate_beginpass_colorattachmentview_image_alive, .validate_beginpass_colorattachmentview_image_valid, e.ViewType.colorattachment },
        .resolve => .{ .validate_beginpass_resolveattachmentview_alive, .validate_beginpass_resolveattachmentview_valid, .validate_beginpass_resolveattachmentview_type, .validate_beginpass_resolveattachmentview_image_alive, .validate_beginpass_resolveattachmentview_image_valid, e.ViewType.resolveattachment },
        .depth_stencil => .{ .validate_beginpass_depthstencilattachmentview_alive, .validate_beginpass_depthstencilattachmentview_valid, .validate_beginpass_depthstencilattachmentview_type, .validate_beginpass_depthstencilattachmentview_image_alive, .validate_beginpass_depthstencilattachmentview_image_valid, e.ViewType.depthstencilattachment },
    };
    // the view object must be alive and valid
    v.check(view != null, items[0]);
    const vw = view orelse return null;
    v.check(vw.slot.state == .valid, items[1]);
    if (vw.slot.state != .valid) return null;
    // the view must have the expected type, its image must be alive and valid
    v.check(vw.cmn.type == items[5], items[2]);
    const img = vw.cmn.img.ref.getOrNull();
    v.check(img != null, items[3]);
    const im = img orelse return null;
    v.check(im.slot.state == .valid, items[4]);
    return if (im.slot.state == .valid) im else null;
}

pub fn beginPass(pass: *const t.Pass) bool {
    if (!enabled()) return true;
    const s = core.state();
    s.validate.pass_index +%= 1;
    const backend = s.backend;
    const is_invalid_swapchain_pass = pass.swapchain.invalid;
    const is_compute_pass = pass.compute;
    const is_swapchain_pass = !is_compute_pass and core.attachmentsEmpty(&pass.attachments);
    const is_offscreen_pass = !(is_compute_pass or is_swapchain_pass);
    const sc = &pass.swapchain;
    var v: Validator = .{};
    v.check(pass._start_canary == 0, .validate_beginpass_canary);
    v.check(pass._end_canary == 0, .validate_beginpass_canary);
    if (is_compute_pass) {
        v.check(core.attachmentsEmpty(&pass.attachments), .validate_beginpass_computepass_expect_no_attachments);
    } else if (is_invalid_swapchain_pass) {
        // skips to the 'swapchain zeroed' validation at the end
    } else if (is_swapchain_pass) {
        v.check(sc.width > 0, .validate_beginpass_swapchain_expect_width);
        v.check(sc.height > 0, .validate_beginpass_swapchain_expect_height);
        v.check(sc.sample_count > 0, .validate_beginpass_swapchain_expect_samplecount);
        v.check(@backingInt(sc.color_format) > @backingInt(e.PixelFormat.none), .validate_beginpass_swapchain_expect_colorformat);
        // NOTE: the depth buffer is optional, and the GL framebuffer handle may be 0
        if (isMetal(backend)) {
            v.check(sc.metal.current_drawable != null, .validate_beginpass_swapchain_metal_expect_currentdrawable);
            if (sc.depth_format == .none) {
                v.check(sc.metal.depth_stencil_texture == null, .validate_beginpass_swapchain_metal_expect_depthstenciltexture_notset);
            } else {
                v.check(sc.metal.depth_stencil_texture != null, .validate_beginpass_swapchain_metal_expect_depthstenciltexture);
            }
            if (sc.sample_count > 1) {
                v.check(sc.metal.msaa_color_texture != null, .validate_beginpass_swapchain_metal_expect_msaacolortexture);
            } else {
                v.check(sc.metal.msaa_color_texture == null, .validate_beginpass_swapchain_metal_expect_msaacolortexture_notset);
            }
        } else if (backend == .d3d12) {
            const dx = &sc.d3d12;
            v.check(dx.render_target != null, .validate_beginpass_swapchain_d3d12_expect_rendertarget);
            if (sc.depth_format == .none) {
                v.check(dx.depth_stencil_target == null, .validate_beginpass_swapchain_d3d12_expect_depthstenciltarget_notset);
            } else {
                v.check(dx.depth_stencil_target != null, .validate_beginpass_swapchain_d3d12_expect_depthstenciltarget);
            }
            if (sc.sample_count > 1) {
                v.check(dx.resolve_target != null, .validate_beginpass_swapchain_d3d12_expect_resolvetarget);
            } else {
                v.check(dx.resolve_target == null, .validate_beginpass_swapchain_d3d12_expect_resolvetarget_notset);
            }
        } else if (backend == .d3d11) {
            v.check(sc.d3d11.render_view != null, .validate_beginpass_swapchain_d3d11_expect_renderview);
            if (sc.depth_format == .none) {
                v.check(sc.d3d11.depth_stencil_view == null, .validate_beginpass_swapchain_d3d11_expect_depthstencilview_notset);
            } else {
                v.check(sc.d3d11.depth_stencil_view != null, .validate_beginpass_swapchain_d3d11_expect_depthstencilview);
            }
            if (sc.sample_count > 1) {
                v.check(sc.d3d11.resolve_view != null, .validate_beginpass_swapchain_d3d11_expect_resolveview);
            } else {
                v.check(sc.d3d11.resolve_view == null, .validate_beginpass_swapchain_d3d11_expect_resolveview_notset);
            }
        } else if (backend == .wgpu) {
            v.check(sc.wgpu.render_view != null, .validate_beginpass_swapchain_wgpu_expect_renderview);
            if (sc.depth_format == .none) {
                v.check(sc.wgpu.depth_stencil_view == null, .validate_beginpass_swapchain_wgpu_expect_depthstencilview_notset);
            } else {
                v.check(sc.wgpu.depth_stencil_view != null, .validate_beginpass_swapchain_wgpu_expect_depthstencilview);
            }
            if (sc.sample_count > 1) {
                v.check(sc.wgpu.resolve_view != null, .validate_beginpass_swapchain_wgpu_expect_resolveview);
            } else {
                v.check(sc.wgpu.resolve_view == null, .validate_beginpass_swapchain_wgpu_expect_resolveview_notset);
            }
        } else if (backend == .vulkan) {
            const vk = &sc.vulkan;
            v.check(vk.render_image != null, .validate_beginpass_swapchain_vulkan_expect_renderimage);
            v.check(vk.render_view != null, .validate_beginpass_swapchain_vulkan_expect_renderview);
            if (sc.depth_format == .none) {
                v.check(vk.depth_stencil_image == null, .validate_beginpass_swapchain_vulkan_expect_depthstencilimage_notset);
                v.check(vk.depth_stencil_view == null, .validate_beginpass_swapchain_vulkan_expect_depthstencilview_notset);
            } else {
                v.check(vk.depth_stencil_image != null, .validate_beginpass_swapchain_vulkan_expect_depthstencilimage);
                v.check(vk.depth_stencil_view != null, .validate_beginpass_swapchain_vulkan_expect_depthstencilview);
            }
            if (sc.sample_count > 1) {
                v.check(vk.resolve_image != null, .validate_beginpass_swapchain_vulkan_expect_resolveimage);
                v.check(vk.resolve_view != null, .validate_beginpass_swapchain_vulkan_expect_resolveview);
            } else {
                v.check(vk.resolve_image == null, .validate_beginpass_swapchain_vulkan_expect_resolveimage_notset);
                v.check(vk.resolve_view == null, .validate_beginpass_swapchain_vulkan_expect_resolveview_notset);
            }
            v.check(vk.render_finished_semaphore != null, .validate_beginpass_swapchain_vulkan_expect_renderfinishedsemaphore);
            v.check(vk.present_complete_semaphore != null, .validate_beginpass_swapchain_vulkan_expect_presentcompletesemaphore);
        }
    } else {
        // an offscreen pass
        var has_color_atts = false;
        var atts_cont = true;
        var color_width: i32 = -1;
        var color_height: i32 = -1;
        var color_sample_count: i32 = -1;
        for (pass.attachments.colors) |color| {
            if (color.id == 0) {
                atts_cont = false;
                continue;
            }
            has_color_atts = true;
            v.check(atts_cont, .validate_beginpass_colorattachmentviews_continuous);
            const view = core.lookupView(color.id);
            const img = attachmentImage(&v, view, .color) orelse continue;
            const dim = core.imageViewDim(view.?);
            if (color_width == -1) {
                color_width = dim.width;
                color_height = dim.height;
                color_sample_count = img.cmn.sample_count;
            } else {
                v.check(color_width == dim.width, .validate_beginpass_colorattachmentview_sizes);
                v.check(color_height == dim.height, .validate_beginpass_colorattachmentview_sizes);
                v.check(color_sample_count == img.cmn.sample_count, .validate_beginpass_colorattachmentview_samplecounts_equal);
            }
        }
        for (pass.attachments.resolves, pass.attachments.colors) |resolve, color| {
            if (resolve.id == 0) continue;
            v.check(color.id != 0, .validate_beginpass_resolveattachmentview_no_colorattachmentview);
            const view = core.lookupView(resolve.id);
            _ = attachmentImage(&v, view, .resolve) orelse continue;
            if (color_width != -1) {
                const dim = core.imageViewDim(view.?);
                v.check(color_sample_count > 1, .validate_beginpass_colorattachmentview_samplecount);
                v.check(color_width == dim.width, .validate_beginpass_resolveattachmentview_sizes);
                v.check(color_height == dim.height, .validate_beginpass_resolveattachmentview_sizes);
            }
        }
        var has_depth_stencil_atts = false;
        if (pass.attachments.depth_stencil.id != 0) {
            has_depth_stencil_atts = true;
            const view = core.lookupView(pass.attachments.depth_stencil.id);
            if (attachmentImage(&v, view, .depth_stencil)) |img| {
                if (color_width != -1) {
                    const dim = core.imageViewDim(view.?);
                    v.check(color_width == dim.width, .validate_beginpass_depthstencilattachmentview_sizes);
                    v.check(color_height == dim.height, .validate_beginpass_depthstencilattachmentview_sizes);
                    v.check(color_sample_count == img.cmn.sample_count, .validate_beginpass_depthstencilattachmentview_samplecount);
                }
            }
        }
        // must have at least color- or depth-stencil-attachments
        v.check(has_color_atts or has_depth_stencil_atts, .validate_beginpass_attachments_expected);
    }
    if (is_compute_pass or is_offscreen_pass or is_invalid_swapchain_pass) {
        v.check(sc.width == 0, .validate_beginpass_swapchain_expect_width_notset);
        v.check(sc.height == 0, .validate_beginpass_swapchain_expect_height_notset);
        v.check(sc.sample_count == 0, .validate_beginpass_swapchain_expect_samplecount_notset);
        v.check(sc.color_format == .default, .validate_beginpass_swapchain_expect_colorformat_notset);
        v.check(sc.depth_format == .default, .validate_beginpass_swapchain_expect_depthformat_notset);
        if (isMetal(backend)) {
            v.check(sc.metal.current_drawable == null, .validate_beginpass_swapchain_metal_expect_currentdrawable_notset);
            v.check(sc.metal.depth_stencil_texture == null, .validate_beginpass_swapchain_metal_expect_depthstenciltexture_notset);
            v.check(sc.metal.msaa_color_texture == null, .validate_beginpass_swapchain_metal_expect_msaacolortexture_notset);
        } else if (backend == .d3d12) {
            v.check(sc.d3d12.render_target == null, .validate_beginpass_swapchain_d3d12_expect_rendertarget_notset);
            v.check(sc.d3d12.depth_stencil_target == null, .validate_beginpass_swapchain_d3d12_expect_depthstenciltarget_notset);
            v.check(sc.d3d12.resolve_target == null, .validate_beginpass_swapchain_d3d12_expect_resolvetarget_notset);
        } else if (backend == .d3d11) {
            v.check(sc.d3d11.render_view == null, .validate_beginpass_swapchain_d3d11_expect_renderview_notset);
            v.check(sc.d3d11.depth_stencil_view == null, .validate_beginpass_swapchain_d3d11_expect_depthstencilview_notset);
            v.check(sc.d3d11.resolve_view == null, .validate_beginpass_swapchain_d3d11_expect_resolveview_notset);
        } else if (backend == .wgpu) {
            v.check(sc.wgpu.render_view == null, .validate_beginpass_swapchain_wgpu_expect_renderview_notset);
            v.check(sc.wgpu.depth_stencil_view == null, .validate_beginpass_swapchain_wgpu_expect_depthstencilview_notset);
            v.check(sc.wgpu.resolve_view == null, .validate_beginpass_swapchain_wgpu_expect_resolveview_notset);
        } else if (isGl(backend)) {
            v.check(sc.gl.framebuffer == 0, .validate_beginpass_swapchain_gl_expect_framebuffer_notset);
        } else if (backend == .vulkan) {
            const vk = &sc.vulkan;
            v.check(vk.render_image == null, .validate_beginpass_swapchain_vulkan_expect_renderimage_notset);
            v.check(vk.render_view == null, .validate_beginpass_swapchain_vulkan_expect_renderview_notset);
            v.check(vk.depth_stencil_image == null, .validate_beginpass_swapchain_vulkan_expect_depthstencilimage_notset);
            v.check(vk.depth_stencil_view == null, .validate_beginpass_swapchain_vulkan_expect_depthstencilview_notset);
            v.check(vk.resolve_image == null, .validate_beginpass_swapchain_vulkan_expect_resolveimage_notset);
            v.check(vk.resolve_view == null, .validate_beginpass_swapchain_vulkan_expect_resolveview_notset);
            v.check(vk.render_finished_semaphore == null, .validate_beginpass_swapchain_vulkan_expect_renderfinishedsemaphore_notset);
            v.check(vk.present_complete_semaphore == null, .validate_beginpass_swapchain_vulkan_expect_presentcompletesemaphore_notset);
        }
    }
    return v.end();
}

pub fn applyViewport() bool {
    if (!enabled()) return true;
    const pass = &core.state().cur_pass;
    var v: Validator = .{};
    v.check(pass.in_pass and !pass.is_compute, .validate_avp_renderpass_expected);
    return v.end();
}

pub fn applyScissorRect() bool {
    if (!enabled()) return true;
    const pass = &core.state().cur_pass;
    var v: Validator = .{};
    v.check(pass.in_pass and !pass.is_compute, .validate_asr_renderpass_expected);
    return v.end();
}

pub fn applyPipeline(pip_id: t.Pipeline) bool {
    if (!enabled()) return true;
    const s = core.state();
    var v: Validator = .{};
    // the pipeline object must be alive and valid
    v.check(pip_id.id != 0, .validate_apip_pipeline_valid_id);
    const pip = core.lookupPipeline(pip_id.id);
    v.check(pip != null, .validate_apip_pipeline_exists);
    const p = pip orelse return v.end();
    v.check(p.slot.state == .valid, .validate_apip_pipeline_valid);

    // the pipeline's shader must be alive and valid
    v.check(s.cur_pass.in_pass, .validate_apip_pass_expected);
    const shd_alive = p.cmn.shader.alive();
    v.check(shd_alive, .validate_apip_pipeline_shader_alive);
    if (!shd_alive) return v.end();
    const shd = p.cmn.shader.get();
    v.check(shd.slot.state == .valid, .validate_apip_pipeline_shader_valid);

    // set the expected bindings and uniform block flags for deferred validation in draw/dispatch
    s.validate.required_bindings_and_uniforms = p.cmn.required_bindings_and_uniforms | shd.cmn.required_bindings_and_uniforms;
    s.validate.applied_bindings_and_uniforms = 0;
    // resetting the write-transient flags prevents misfires when applyBindings() isn't called
    s.validate.write_buffer_transient_missing = false;
    s.validate.write_image_transient_missing = false;

    if (p.cmn.is_compute) {
        v.check(s.cur_pass.is_compute, .validate_apip_computepass_expected);
    } else {
        v.check(!s.cur_pass.is_compute, .validate_apip_renderpass_expected);
        if (core.attachmentsEmpty(&s.cur_pass.atts)) {
            // a swapchain pass
            const sc = &s.cur_pass.swapchain;
            v.check(p.cmn.color_count == 1, .validate_apip_swapchain_color_count);
            v.check(p.cmn.colors[0].pixel_format == sc.color_fmt, .validate_apip_swapchain_color_format);
            v.check(p.cmn.depth.pixel_format == sc.depth_fmt, .validate_apip_swapchain_depth_format);
            v.check(p.cmn.sample_count == sc.sample_count, .validate_apip_swapchain_sample_count);
        } else {
            // an offscreen pass, pipeline attributes must match the pass attachments
            const atts = core.attachmentsPtrs(&s.cur_pass.atts);
            const alive = core.attachmentsAlive(&atts);
            v.check(alive, .validate_apip_attachments_alive);
            if (alive) {
                v.check(p.cmn.color_count == atts.num_color_views, .validate_apip_colorattachments_count);
                for (0..@intCast(@max(p.cmn.color_count, 0))) |i| {
                    const clr_view = atts.color_views[i] orelse continue;
                    v.check(clr_view.slot.state == .valid, .validate_apip_colorattachments_view_valid);
                    const clr_img = clr_view.cmn.img.ref.get();
                    v.check(clr_img.slot.state == .valid, .validate_apip_colorattachments_image_valid);
                    v.check(p.cmn.colors[i].pixel_format == clr_img.cmn.pixel_format, .validate_apip_colorattachments_format);
                    v.check(p.cmn.sample_count == clr_img.cmn.sample_count, .validate_apip_attachment_sample_count);
                }
                if (atts.ds_view) |ds_view| {
                    v.check(ds_view.slot.state == .valid, .validate_apip_depthstencilattachment_view_valid);
                    const ds_img = ds_view.cmn.img.ref.get();
                    v.check(ds_img.slot.state == .valid, .validate_apip_depthstencilattachment_image_valid);
                    v.check(p.cmn.depth.pixel_format == ds_img.cmn.pixel_format, .validate_apip_depthstencilattachment_format);
                    v.check(p.cmn.sample_count == ds_img.cmn.sample_count, .validate_apip_attachment_sample_count);
                } else {
                    v.check(p.cmn.depth.pixel_format == .none, .validate_apip_depthstencilattachment_format);
                }
            }
        }
    }
    return v.end();
}

/// Records a vertex or index buffer binding for read/write hazard tracking.
fn trackBoundBuffer(v: *Validator, s: *State, buf: *core.Buffer, usage_ok: bool, usage_item: e.LogItem, rw_item: e.LogItem) void {
    buf.cmn.validate.bind_frame_index = s.frame_index;
    buf.cmn.validate.read_render_pass_index = s.validate.pass_index;
    v.check(usage_ok, usage_item);
    v.check(buf.cmn.validate.write_render_pass_index != s.validate.pass_index, rw_item);
    if (buf.cmn.usage.write_transient) {
        s.validate.write_buffer_transient_missing = s.validate.write_buffer_transient_missing or buf.cmn.write_transient_frame_index != s.frame_index;
    }
}

pub fn applyBindings(bindings: *const t.Bindings) bool {
    if (!enabled()) return true;
    const s = core.state();
    var v: Validator = .{};
    s.validate.applied_bindings_and_uniforms |= core.bindings_flag;
    s.validate.write_buffer_transient_missing = false;
    s.validate.write_image_transient_missing = false;

    // must be called in a pass
    v.check(s.cur_pass.in_pass, .validate_abnd_pass_expected);

    // bindings must not be empty
    var has_any_bindings = bindings.index_buffer.id != 0;
    for (bindings.vertex_buffers) |b| has_any_bindings = has_any_bindings or b.id != 0;
    for (bindings.views) |b| has_any_bindings = has_any_bindings or b.id != 0;
    for (bindings.samplers) |b| has_any_bindings = has_any_bindings or b.id != 0;
    v.check(has_any_bindings, .validate_abnd_empty_bindings);

    // a pipeline object must have been applied
    v.check(!s.cur_pip.isNull(), .validate_abnd_no_pipeline);
    const pip_alive = s.cur_pip.alive();
    v.check(pip_alive, .validate_abnd_pipeline_alive);
    if (!pip_alive) return v.end();
    const pip = s.cur_pip.get();
    v.check(pip.slot.state == .valid, .validate_abnd_pipeline_valid);

    const shd_alive = pip.cmn.shader.alive();
    v.check(shd_alive, .validate_abnd_pipeline_shader_alive);
    if (!shd_alive) return v.end();
    const shd = pip.cmn.shader.get();
    v.check(shd.slot.state == .valid, .validate_abnd_pipeline_shader_valid);

    if (s.cur_pass.is_compute) {
        for (bindings.vertex_buffers) |b| v.check(b.id == 0, .validate_abnd_compute_expected_no_vbufs);
    } else {
        for (bindings.vertex_buffers, pip.cmn.vertex_buffer_layout_active) |b, active| {
            if (!active) continue;
            v.check(b.id != 0, .validate_abnd_expected_vbuf);
            if (b.id == 0) continue;
            const buf = core.lookupBuffer(b.id);
            v.check(buf != null, .validate_abnd_vbuf_alive);
            // NOTE: state != VALID is legal and skips rendering
            if (buf) |bf| if (bf.slot.state == .valid) {
                trackBoundBuffer(&v, s, bf, bf.cmn.usage.vertex_buffer, .validate_abnd_vbuf_usage, .validate_abnd_vbuf_vs_sbview_readwrite);
            };
        }
    }

    if (s.cur_pass.is_compute) {
        v.check(bindings.index_buffer.id == 0, .validate_abnd_compute_expected_no_ibuf);
    } else {
        if (pip.cmn.index_type == .none) {
            // pipeline defines non-indexed rendering, but index buffer provided
            v.check(bindings.index_buffer.id == 0, .validate_abnd_expected_no_ibuf);
        } else {
            // pipeline defines indexed rendering, but no index buffer provided
            v.check(bindings.index_buffer.id != 0, .validate_abnd_expected_ibuf);
        }
        if (bindings.index_buffer.id != 0) {
            const buf = core.lookupBuffer(bindings.index_buffer.id);
            v.check(buf != null, .validate_abnd_ibuf_alive);
            if (buf) |bf| if (bf.slot.state == .valid) {
                trackBoundBuffer(&v, s, bf, bf.cmn.usage.index_buffer, .validate_abnd_ibuf_usage, .validate_abnd_ibuf_vs_sbview_readwrite);
            };
        }
    }

    // has expected view bindings
    for (shd.cmn.views, bindings.views) |sv, b| {
        if (sv.view_type == .invalid) continue;
        v.check(b.id != 0, .validate_abnd_expected_view_binding);
        if (b.id == 0) continue;
        const view = core.lookupView(b.id);
        v.check(view != null, .validate_abnd_view_alive);
        const vw = view orelse continue;
        // NOTE: an invalid view state is allowed and skips rendering
        if (vw.slot.state != .valid) continue;
        switch (sv.view_type) {
            .texture => {
                v.check(vw.cmn.type == .texture, .validate_abnd_expect_texview);
                // NOTE: an invalid image ref is allowed and skips rendering
                if (!vw.cmn.img.ref.valid()) continue;
                const img = vw.cmn.img.ref.get();
                img.cmn.validate.bind_frame_index = s.frame_index;
                v.check(img.cmn.type == sv.image_type, .validate_abnd_texview_imagetype_mismatch);
                if (sv.multisampled) {
                    v.check(img.cmn.sample_count > 1, .validate_abnd_texview_expected_multisampled_image);
                } else {
                    v.check(img.cmn.sample_count == 1, .validate_abnd_texview_expected_non_multisampled_image);
                }
                const info = formatInfo(img.cmn.pixel_format);
                switch (sv.sample_type) {
                    .float => v.check(info.filter, .validate_abnd_texview_expected_filterable_image),
                    .depth => v.check(info.depth, .validate_abnd_texview_expected_depth_image),
                    else => {},
                }
                if (img.cmn.usage.write_transient) {
                    s.validate.write_image_transient_missing = s.validate.write_image_transient_missing or img.cmn.write_transient_frame_index != s.frame_index;
                }
            },
            .storagebuffer => {
                v.check(vw.cmn.type == .storagebuffer, .validate_abnd_expect_sbview);
                // NOTE: an invalid buffer ref is allowed and skips rendering
                if (!vw.cmn.buf.ref.valid()) continue;
                const buf = vw.cmn.buf.ref.get();
                buf.cmn.validate.bind_frame_index = s.frame_index;
                if (sv.sbuf_readonly) {
                    buf.cmn.validate.read_render_pass_index = s.validate.pass_index;
                    v.check(s.cur_pass.is_compute or buf.cmn.validate.write_render_pass_index != s.validate.pass_index, .validate_abnd_sbview_readonly_vs_readwrite);
                } else {
                    buf.cmn.validate.write_render_pass_index = s.validate.pass_index;
                    v.check(s.cur_pass.is_compute or buf.cmn.validate.read_render_pass_index != s.validate.pass_index, .validate_abnd_sbview_readwrite_vs_read);
                    v.check(!buf.cmn.usage.write_transient, .validate_abnd_sbview_readwrite_vs_writetransient);
                }
                if (buf.cmn.usage.write_transient) {
                    s.validate.write_buffer_transient_missing = s.validate.write_buffer_transient_missing or buf.cmn.write_transient_frame_index != s.frame_index;
                }
            },
            .storageimage => {
                v.check(vw.cmn.type == .storageimage, .validate_abnd_expect_simgview);
                // storage images are only allowed in compute passes
                v.check(s.cur_pass.is_compute, .validate_abnd_simgview_compute_pass_expected);
                if (!vw.cmn.img.ref.valid()) continue;
                const img = vw.cmn.img.ref.get();
                img.cmn.validate.bind_frame_index = s.frame_index;
                v.check(img.cmn.type == sv.image_type, .validate_abnd_simgview_imagetype_mismatch);
                v.check(img.cmn.pixel_format == sv.access_format, .validate_abnd_simgview_accessformat);
                if (img.cmn.usage.write_transient) {
                    s.validate.write_image_transient_missing = s.validate.write_image_transient_missing or img.cmn.write_transient_frame_index != s.frame_index;
                }
            },
            else => {},
        }
    }

    // has expected samplers
    for (shd.cmn.samplers, bindings.samplers) |ss, b| {
        if (ss.stage == .none) continue;
        v.check(b.id != 0, .validate_abnd_expected_sampler_binding);
        if (b.id == 0) continue;
        const smp = core.lookupSampler(b.id);
        v.check(smp != null, .validate_abnd_sampler_alive);
        const sm = smp orelse continue;
        // NOTE: invalid samplers don't skip rendering, but are an error
        v.check(sm.slot.state == .valid, .validate_abnd_sampler_valid);
        if (ss.sampler_type == .comparison) {
            v.check(sm.cmn.compare != .never, .validate_abnd_unexpected_sampler_compare_never);
        } else {
            v.check(sm.cmn.compare == .never, .validate_abnd_expected_sampler_compare_never);
        }
        if (ss.sampler_type == .nonfiltering) {
            const nonfiltering = sm.cmn.min_filter != .linear and sm.cmn.mag_filter != .linear and sm.cmn.mipmap_filter != .linear;
            v.check(nonfiltering, .validate_abnd_expected_nonfiltering_sampler);
        }
    }

    // the same image cannot be used as texture binding and pass attachment or storage image binding
    for (shd.cmn.views, bindings.views) |sv, b| {
        if (sv.view_type != .texture or b.id == 0) continue;
        const tex_view = core.lookupView(b.id) orelse continue;
        const img_id = tex_view.cmn.img.ref.sref.id;
        if (!core.attachmentsEmpty(&s.cur_pass.atts)) {
            if (core.lookupView(s.cur_pass.atts.depth_stencil.id)) |ds_view| {
                v.check(img_id != ds_view.cmn.img.ref.sref.id, .validate_abnd_texture_binding_vs_depthstencil_attachment);
            }
            for (s.cur_pass.atts.colors, s.cur_pass.atts.resolves) |color, resolve| {
                if (core.lookupView(color.id)) |color_view| {
                    v.check(img_id != color_view.cmn.img.ref.sref.id, .validate_abnd_texture_binding_vs_color_attachment);
                }
                if (core.lookupView(resolve.id)) |resolve_view| {
                    v.check(img_id != resolve_view.cmn.img.ref.sref.id, .validate_abnd_texture_binding_vs_resolve_attachment);
                }
            }
        }
        for (shd.cmn.views, bindings.views) |other_sv, other_b| {
            if (other_sv.view_type != .storageimage or other_b.id == 0) continue;
            if (core.lookupView(other_b.id)) |simg_view| {
                v.check(img_id != simg_view.cmn.img.ref.sref.id, .validate_abnd_texture_vs_storageimage_binding);
            }
        }
    }
    return v.end();
}

pub fn applyUniforms(ub_slot: usize, data: *const t.Range) bool {
    if (!enabled()) return true;
    std.debug.assert(ub_slot < core.max_uniformblock_bindslots);
    const s = core.state();
    var v: Validator = .{};
    s.validate.applied_bindings_and_uniforms |= @as(u32, 1) << @intCast(ub_slot);
    v.check(s.cur_pass.in_pass, .validate_au_pass_expected);
    v.check(!s.cur_pip.isNull(), .validate_au_no_pipeline);
    const pip_alive = s.cur_pip.alive();
    v.check(pip_alive, .validate_au_pipeline_alive);
    if (pip_alive) {
        const pip = s.cur_pip.get();
        v.check(pip.slot.state == .valid, .validate_au_pipeline_valid);
        const shd_alive = pip.cmn.shader.alive();
        v.check(shd_alive, .validate_au_pipeline_shader_alive);
        if (shd_alive) {
            const shd = pip.cmn.shader.get();
            v.check(shd.slot.state == .valid, .validate_au_pipeline_shader_valid);
            v.check(shd.cmn.uniform_blocks[ub_slot].stage != .none, .validate_au_no_uniformblock_at_slot);
            v.check(data.size == shd.cmn.uniform_blocks[ub_slot].size, .validate_au_size);
        }
    }
    return v.end();
}

fn checkDeferred(v: *Validator, s: *const State, buffer_item: e.LogItem, image_item: e.LogItem) void {
    v.check(s.validate.required_bindings_and_uniforms == s.validate.applied_bindings_and_uniforms, .validate_draw_required_bindings_or_uniforms_missing);
    v.check(!s.validate.write_buffer_transient_missing, buffer_item);
    v.check(!s.validate.write_image_transient_missing, image_item);
}

pub fn draw(base_element: i32, num_elements: i32, num_instances: i32) bool {
    if (!enabled()) return true;
    const s = core.state();
    var v: Validator = .{};
    v.check(s.cur_pass.in_pass and !s.cur_pass.is_compute, .validate_draw_renderpass_expected);
    v.check(base_element >= 0, .validate_draw_baseelement_ge_zero);
    v.check(num_elements >= 0, .validate_draw_numelements_ge_zero);
    v.check(num_instances >= 0, .validate_draw_numinstances_ge_zero);
    checkDeferred(&v, s, .validate_draw_write_buffer_transient_missing, .validate_draw_write_image_transient_missing);
    return v.end();
}

pub fn drawEx(base_element: i32, num_elements: i32, num_instances: i32, base_vertex: i32, base_instance: i32) bool {
    if (!enabled()) return true;
    const s = core.state();
    var v: Validator = .{};
    v.check(s.cur_pass.in_pass and !s.cur_pass.is_compute, .validate_draw_ex_renderpass_expected);
    // NOTE: base_vertex is allowed to be < 0
    v.check(base_element >= 0, .validate_draw_ex_baseelement_ge_zero);
    v.check(num_elements >= 0, .validate_draw_ex_numelements_ge_zero);
    v.check(num_instances >= 0, .validate_draw_ex_numinstances_ge_zero);
    v.check(base_instance >= 0, .validate_draw_ex_baseinstance_ge_zero);
    if (base_vertex != 0) v.check(s.features.draw_base_vertex, .validate_draw_ex_basevertex_not_supported);
    if (base_instance > 0) v.check(s.features.draw_base_instance, .validate_draw_ex_baseinstance_not_supported);
    if (!s.use_indexed_draw) v.check(base_vertex == 0, .validate_draw_ex_basevertex_vs_indexed);
    if (!(num_instances > 1 or s.use_instanced_draw)) v.check(base_instance == 0, .validate_draw_ex_baseinstance_vs_instanced);
    checkDeferred(&v, s, .validate_draw_write_buffer_transient_missing, .validate_draw_write_image_transient_missing);
    return v.end();
}

pub fn dispatch(num_groups_x: i32, num_groups_y: i32, num_groups_z: i32) bool {
    if (!enabled()) return true;
    const s = core.state();
    var v: Validator = .{};
    v.check(s.cur_pass.in_pass and s.cur_pass.is_compute, .validate_dispatch_computepass_expected);
    v.check(num_groups_x >= 0 and num_groups_x < (1 << 16), .validate_dispatch_numgroupsx);
    v.check(num_groups_y >= 0 and num_groups_y < (1 << 16), .validate_dispatch_numgroupsy);
    v.check(num_groups_z >= 0 and num_groups_z < (1 << 16), .validate_dispatch_numgroupsz);
    checkDeferred(&v, s, .validate_dispatch_write_buffer_transient_missing, .validate_dispatch_write_image_transient_missing);
    return v.end();
}

// ---------------------------------------------------------------- data transfers

fn writeBufferCommon(v: *Validator, buf: *const core.Buffer, desc: *const t.WriteBufferDesc) void {
    v.check(desc.src.data.ptr != null, .validate_writebuffer_src_data_pointer);
    v.check(desc.src.data.size > 0, .validate_writebuffer_src_data_size);
    v.check(desc.size > 0 and desc.size <= desc.src.data.size, .validate_writebuffer_size);
    v.check(@as(u128, desc.dst.offset) + desc.size <= buf.cmn.size, .validate_writebuffer_write_overflow);
    v.check(@as(u128, desc.src.offset) + desc.size <= desc.src.data.size, .validate_writebuffer_read_overflow);
}

pub fn writeBufferTransient(buf: *const core.Buffer, desc: *const t.WriteBufferDesc) bool {
    if (!enabled()) return true;
    std.debug.assert(buf.slot.state == .valid);
    const s = core.state();
    var v: Validator = .{};
    v.check(buf.cmn.usage.write_transient, .validate_writebuffertransient_usage);
    // write-transient is only allowed before the resource is used in the current frame
    v.check(buf.cmn.validate.bind_frame_index != s.frame_index, .validate_writebuffertransient_write_before_bind);
    v.check(buf.cmn.validate.copy_src_frame_index != s.frame_index, .validate_writebuffertransient_write_before_copy);
    // WebGPU restriction: offset must be a multiple of 4
    v.check(multipleU64(desc.dst.offset, 4), .validate_writebuffertransient_dst_offset_alignment);
    writeBufferCommon(&v, buf, desc);
    return v.end();
}

pub fn writeBufferUnsealed(buf: *const core.Buffer, desc: *const t.WriteBufferDesc) bool {
    if (!enabled()) return true;
    std.debug.assert(buf.slot.state == .unsealed);
    var v: Validator = .{};
    v.check(buf.cmn.usage.write_unsealed, .validate_writebufferunsealed_usage);
    writeBufferCommon(&v, buf, desc);
    return v.end();
}

fn mipDepthOrSlices(cmn: *const core.ImageCommon, mip_level: i32) i32 {
    return if (cmn.type == .@"3d") core.miplevelDim(cmn.num_slices, mip_level) else cmn.num_slices;
}

fn writeImageCommon(v: *Validator, img: *const core.Image, desc: *const t.WriteImageDesc) void {
    const cmn = &img.cmn;
    const mip_ok = desc.dst.mip_level >= 0 and desc.dst.mip_level < 32;
    const mip_level = if (mip_ok) desc.dst.mip_level else 0;
    const write_size = @as(u128, @intCast(@max(desc.src.bytes_per_slice, 0))) * @as(u128, @intCast(@max(desc.size.num_slices, 0)));
    const mip_width = core.miplevelDim(cmn.width, mip_level);
    const mip_height = core.miplevelDim(cmn.height, mip_level);
    const mip_depth_or_slices = mipDepthOrSlices(cmn, mip_level);
    const fmt = cmn.pixel_format;
    const bsize = formats.blockSize(fmt);
    const block_dim = formats.blockDimension(fmt);
    const row_bytes = formats.rowPitch(fmt, @max(desc.size.width, 0), 1);
    const num_rows = formats.numRows(fmt, @max(desc.size.height, 0));
    const bpr = desc.src.bytes_per_row;
    const bps = desc.src.bytes_per_slice;
    v.check(desc.src.data.ptr != null, .validate_writeimage_src_data_pointer);
    v.check(desc.src.data.size > 0, .validate_writeimage_src_data_size);
    v.check(bpr > 0 and multiple(bpr, bsize), .validate_writeimage_bytesperrow);
    v.check(bps > 0 and bpr > 0 and multiple(bps, bpr), .validate_writeimage_bytesperslice);
    // NOTE: the <= 0 checks prevent misleading validation messages
    v.check(bpr <= 0 or bpr >= row_bytes, .validate_writeimage_bytesperrow_too_small);
    v.check(bps <= 0 or @as(i64, bps) >= @as(i64, num_rows) * bpr, .validate_writeimage_bytesperslice_too_small);
    v.check(desc.dst.mip_level >= 0 and desc.dst.mip_level < cmn.num_mipmaps, .validate_writeimage_miplevel);
    v.check(desc.size.width > 0 and desc.size.width <= mip_width, .validate_writeimage_width);
    v.check(desc.size.height > 0 and desc.size.height <= mip_height, .validate_writeimage_height);
    v.check(desc.size.num_slices > 0 and desc.size.num_slices <= mip_depth_or_slices, .validate_writeimage_numslices);
    v.check(@as(u128, desc.src.offset) + write_size <= desc.src.data.size, .validate_writeimage_read_overflow);
    v.check(desc.dst.x >= 0 and desc.dst.x < mip_width, .validate_writeimage_dst_x_range);
    v.check(desc.dst.y >= 0 and desc.dst.y < mip_height, .validate_writeimage_dst_y_range);
    v.check(desc.dst.slice >= 0 and desc.dst.slice < mip_depth_or_slices, .validate_writeimage_dst_slice_range);
    v.check(@as(i64, desc.dst.x) + desc.size.width <= mip_width, .validate_writeimage_write_width_overflow);
    v.check(@as(i64, desc.dst.y) + desc.size.height <= mip_height, .validate_writeimage_write_height_overflow);
    v.check(@as(i64, desc.dst.slice) + desc.size.num_slices <= mip_depth_or_slices, .validate_writeimage_write_numslices_overflow);
    // a size that's not a multiple of the block size is allowed when the write
    // reaches the miplevel edge (needed for compressed miplevels smaller than one block)
    v.check(desc.dst.x < 0 or multiple(desc.dst.x, block_dim), .validate_writeimage_dst_x_alignment);
    v.check(desc.dst.y < 0 or multiple(desc.dst.y, block_dim), .validate_writeimage_dst_y_alignment);
    v.check(desc.size.width <= 0 or multiple(desc.size.width, block_dim) or desc.dst.x + desc.size.width == mip_width, .validate_writeimage_width_multiple);
    v.check(desc.size.height <= 0 or multiple(desc.size.height, block_dim) or desc.dst.y + desc.size.height == mip_height, .validate_writeimage_height_multiple);
}

pub fn writeImageTransient(img: *const core.Image, desc: *const t.WriteImageDesc) bool {
    if (!enabled()) return true;
    std.debug.assert(img.slot.state == .valid);
    const s = core.state();
    var v: Validator = .{};
    v.check(!img.cmn.usage.immutable and img.cmn.usage.write_transient, .validate_writeimagetransient_usage);
    // write-transient is only allowed before the resource is bound in the current frame
    v.check(img.cmn.validate.bind_frame_index != s.frame_index, .validate_writeimagetransient_write_before_bind);
    writeImageCommon(&v, img, desc);
    return v.end();
}

pub fn writeImageUnsealed(img: *const core.Image, desc: *const t.WriteImageDesc) bool {
    if (!enabled()) return true;
    std.debug.assert(img.slot.state == .unsealed);
    var v: Validator = .{};
    v.check(img.cmn.usage.immutable and img.cmn.usage.write_unsealed, .validate_writeimageunsealed_usage);
    writeImageCommon(&v, img, desc);
    return v.end();
}

pub fn sealBuffer(buf: *const core.Buffer) bool {
    if (!enabled()) return true;
    var v: Validator = .{};
    v.check(buf.slot.state == .unsealed, .validate_sealbuffer_resourcestate);
    return v.end();
}

pub fn sealImage(img: *const core.Image) bool {
    if (!enabled()) return true;
    var v: Validator = .{};
    v.check(img.slot.state == .unsealed, .validate_sealimage_resourcestate);
    return v.end();
}

pub fn copyBufferToBuffer(src_buf: *core.Buffer, dst_buf: *const core.Buffer, desc: *const t.CopyBufferToBufferDesc) bool {
    if (!enabled()) return true;
    std.debug.assert(src_buf.slot.state == .valid and dst_buf.slot.state == .valid);
    const s = core.state();
    src_buf.cmn.validate.copy_src_frame_index = s.frame_index;
    var v: Validator = .{};
    v.check(!s.cur_pass.in_pass, .validate_copybuffertobuffer_inside_pass);
    v.check(desc.src.buffer.id != desc.dst.buffer.id, .validate_copybuffertobuffer_src_vs_dst_buffer);
    v.check(src_buf.cmn.usage.copy_src, .validate_copybuffertobuffer_copy_src);
    v.check(dst_buf.cmn.usage.copy_dst, .validate_copybuffertobuffer_copy_dst);
    v.check(desc.size > 0, .validate_copybuffertobuffer_zero_size);
    v.check(multipleU64(desc.src.offset, 4), .validate_copybuffertobuffer_src_offset_alignment);
    v.check(multipleU64(desc.dst.offset, 4), .validate_copybuffertobuffer_dst_offset_alignment);
    v.check(@as(u128, desc.src.offset) + desc.size <= src_buf.cmn.size, .validate_copybuffertobuffer_src_overflow);
    v.check(@as(u128, desc.dst.offset) + desc.size <= dst_buf.cmn.size, .validate_copybuffertobuffer_dst_overflow);
    if (s.features.separate_buffer_types) {
        const src_is_index = src_buf.cmn.usage.index_buffer or src_buf.cmn.usage.staging_index_buffer;
        v.check(src_is_index == dst_buf.cmn.usage.index_buffer, .validate_copybuffertobuffer_webgl2_index_buffer);
    }
    return v.end();
}

pub fn copyBufferToImage(src_buf: *core.Buffer, dst_img: *const core.Image, desc: *const t.CopyBufferToImageDesc) bool {
    if (!enabled()) return true;
    std.debug.assert(src_buf.slot.state == .valid and dst_img.slot.state == .valid);
    const s = core.state();
    src_buf.cmn.validate.copy_src_frame_index = s.frame_index;
    var v: Validator = .{};
    const cmn = &dst_img.cmn;
    const mip_ok = desc.dst.mip_level >= 0 and desc.dst.mip_level < 32;
    const mip_level = if (mip_ok) desc.dst.mip_level else 0;
    const mip_width = core.miplevelDim(cmn.width, mip_level);
    const mip_height = core.miplevelDim(cmn.height, mip_level);
    const mip_depth_or_slices = mipDepthOrSlices(cmn, mip_level);
    const fmt = cmn.pixel_format;
    const block_dim = formats.blockDimension(fmt);
    const block_size = formats.blockSize(fmt);
    const row_bytes = formats.rowPitch(fmt, @max(desc.size.width, 0), 1);
    const num_rows = formats.numRows(fmt, @max(desc.size.height, 0));
    const bpr = desc.src.bytes_per_row;
    const bps = desc.src.bytes_per_slice;
    const is_staging_buffer = src_buf.cmn.usage.staging_buffer;
    // NOTE: the <= 0 checks prevent misleading validation messages
    v.check(bpr <= 0 or bpr >= row_bytes, .validate_copybuffertoimage_bytesperrow_too_small);
    v.check(bps <= 0 or @as(i64, bps) >= @as(i64, num_rows) * bpr, .validate_copybuffertoimage_bytesperslice_too_small);
    v.check(!src_buf.cmn.usage.staging_index_buffer, .validate_copybuffertoimage_src_staging_index_buffer);
    // D3D11 has no copy-buffer-to-texture, and must use a staging buffer as source
    if (!s.features.copy_buffer_to_image_relaxed_buffer_type) {
        v.check(is_staging_buffer, .validate_copybuffertoimage_src_staging_buffer);
    }
    // WebGL2 cannot copy from index buffers into other resource types
    if (s.features.separate_buffer_types) {
        v.check(!src_buf.cmn.usage.index_buffer, .validate_copybuffertoimage_webgl2_index_buffer);
    }
    // when copying from GPU buffers, WebGPU requires bytes-per-row to be a multiple of 256
    if (!s.features.copy_buffer_to_image_relaxed_bytes_per_row and !is_staging_buffer) {
        v.check(bpr > 0 and multiple(bpr, 256), .validate_copybuffertoimage_bytesperrow_multiple_256);
    }
    v.check(bpr > 0 and multiple(bpr, block_size), .validate_copybuffertoimage_bytesperrow_multiple_blocksize);
    v.check(!s.cur_pass.in_pass, .validate_copybuffertoimage_inside_pass);
    v.check(src_buf.cmn.usage.copy_src, .validate_copybuffertoimage_copy_src);
    v.check(cmn.usage.copy_dst, .validate_copybuffertoimage_copy_dst);
    v.check(multipleU64(desc.src.offset, @intCast(block_size)), .validate_copybuffertoimage_src_offset_alignment);
    v.check(bps > 0 and bpr > 0 and multiple(bps, bpr), .validate_copybuffertoimage_bytesperslice);
    v.check(desc.dst.mip_level >= 0 and desc.dst.mip_level < cmn.num_mipmaps, .validate_copybuffertoimage_dst_miplevel);
    v.check(desc.size.width > 0 and desc.size.width <= mip_width, .validate_copybuffertoimage_dst_width);
    v.check(desc.size.height > 0 and desc.size.height <= mip_height, .validate_copybuffertoimage_dst_height);
    // a size that's not a multiple of the block size is allowed when the copy reaches the miplevel edge
    v.check(desc.size.width <= 0 or multiple(desc.size.width, block_dim) or desc.dst.x + desc.size.width == mip_width, .validate_copybuffertoimage_dst_width_multiple);
    v.check(desc.size.height <= 0 or multiple(desc.size.height, block_dim) or desc.dst.y + desc.size.height == mip_height, .validate_copybuffertoimage_dst_height_multiple);
    if (desc.size.width > 0 and desc.size.height > 0 and desc.size.num_slices > 0) {
        const required_size = desc.src.offset +% formats.imageCopySize(fmt, bpr, bps, desc.size.width, desc.size.height, desc.size.num_slices);
        v.check(required_size <= src_buf.cmn.size, .validate_copybuffertoimage_src_overflow);
    }
    v.check(desc.size.num_slices > 0 and desc.size.num_slices <= mip_depth_or_slices, .validate_copybuffertoimage_dst_numslices);
    v.check(desc.dst.x >= 0 and desc.dst.x < mip_width, .validate_copybuffertoimage_dst_x_range);
    v.check(desc.dst.y >= 0 and desc.dst.y < mip_height, .validate_copybuffertoimage_dst_y_range);
    v.check(desc.dst.x < 0 or multiple(desc.dst.x, block_dim), .validate_copybuffertoimage_dst_x_alignment);
    v.check(desc.dst.y < 0 or multiple(desc.dst.y, block_dim), .validate_copybuffertoimage_dst_y_alignment);
    v.check(desc.dst.slice >= 0 and desc.dst.slice < mip_depth_or_slices, .validate_copybuffertoimage_dst_slice_range);
    v.check(@as(i64, desc.dst.x) + desc.size.width <= mip_width, .validate_copybuffertoimage_dst_width_overflow);
    v.check(@as(i64, desc.dst.y) + desc.size.height <= mip_height, .validate_copybuffertoimage_dst_height_overflow);
    v.check(@as(i64, desc.dst.slice) + desc.size.num_slices <= mip_depth_or_slices, .validate_copybuffertoimage_dst_numslices_overflow);
    return v.end();
}

// ---------------------------------------------------------------- always-active limit checks

/// Also active in release mode: shader creation fails when a shader uses more
/// bindings than the device limits allow.
pub fn shaderBindingLimits(desc: *const t.ShaderDesc) bool {
    const Counts = struct { vs: i32 = 0, fs: i32 = 0, cs: i32 = 0 };
    const count = struct {
        fn f(counts: *Counts, stage: e.ShaderStage) void {
            switch (stage) {
                .vertex => counts.vs += 1,
                .fragment => counts.fs += 1,
                .compute => counts.cs += 1,
                else => {},
            }
        }
    }.f;
    var tex: Counts = .{};
    var sbuf: Counts = .{};
    var simg: Counts = .{};
    var texsmp: Counts = .{};
    for (desc.views) |view| {
        count(&tex, view.texture.stage);
        count(&sbuf, view.storage_buffer.stage);
        count(&simg, view.storage_image.stage);
    }
    for (desc.texture_sampler_pairs) |pair| count(&texsmp, pair.stage);
    const limits = core.state().limits;
    const max_tex = limits.max_texture_bindings_per_stage;
    const max_sbuf = limits.max_storage_buffer_bindings_per_stage;
    const max_simg = limits.max_storage_image_bindings_per_stage;
    var ok = true;
    const checks = [_]struct { bool, e.LogItem }{
        .{ tex.vs > max_tex, .shaderdesc_too_many_vertexstage_textures },
        .{ tex.fs > max_tex, .shaderdesc_too_many_fragmentstage_textures },
        .{ tex.cs > max_tex, .shaderdesc_too_many_computestage_textures },
        .{ sbuf.vs > max_sbuf, .shaderdesc_too_many_vertexstage_storagebuffers },
        .{ sbuf.fs > max_sbuf, .shaderdesc_too_many_fragmentstage_storagebuffers },
        .{ sbuf.cs > max_sbuf, .shaderdesc_too_many_computestage_storagebuffers },
        .{ simg.vs > max_simg, .shaderdesc_too_many_vertexstage_storageimages },
        .{ simg.fs > max_simg, .shaderdesc_too_many_fragmentstage_storageimages },
        .{ simg.cs > max_simg, .shaderdesc_too_many_computestage_storageimages },
        .{ texsmp.vs > max_tex, .shaderdesc_too_many_vertexstage_texturesamplerpairs },
        .{ texsmp.fs > max_tex, .shaderdesc_too_many_fragmentstage_texturesamplerpairs },
        .{ texsmp.cs > max_tex, .shaderdesc_too_many_computestage_texturesamplerpairs },
    };
    for (checks) |c| {
        if (c[0]) {
            core.logError(c[1]);
            ok = false;
        }
    }
    return ok;
}

pub fn passAttachmentLimits(pass: *const t.Pass) bool {
    var num_color_atts: i32 = 0;
    var num_resolve_atts: i32 = 0;
    for (pass.attachments.colors, pass.attachments.resolves) |color, resolve| {
        if (color.id != 0) num_color_atts += 1;
        if (resolve.id != 0) num_resolve_atts += 1;
    }
    const max_color_atts = core.state().limits.max_color_attachments;
    var ok = true;
    if (num_color_atts > max_color_atts) {
        core.logError(.beginpass_too_many_color_attachments);
        ok = false;
    }
    // max_color_attachments is not a bug
    if (num_resolve_atts > max_color_atts) {
        core.logError(.beginpass_too_many_resolve_attachments);
        ok = false;
    }
    return ok;
}

// ---------------------------------------------------------------- readback (zicr extension)

pub fn readBuffer(buf: *const core.Buffer, offset: usize, len: usize) bool {
    if (!enabled()) return true;
    const s = core.state();
    var v: Validator = .{};
    v.check(!s.cur_pass.in_pass, .validate_readbuffer_inside_pass);
    v.check(buf.cmn.usage.copy_src, .validate_readbuffer_usage);
    v.check(len > 0, .validate_readbuffer_empty);
    v.check(@as(u128, offset) + len <= buf.cmn.size, .validate_readbuffer_range);
    return v.end();
}

/// `region` has defaults resolved; checks it against the image and `len`.
pub fn readImage(img: *const core.Image, region: *const core.ReadRegion, len: usize) bool {
    if (!enabled()) return true;
    const s = core.state();
    const cmn = &img.cmn;
    var v: Validator = .{};
    v.check(!s.cur_pass.in_pass, .validate_readimage_inside_pass);
    v.check(cmn.usage.copy_src, .validate_readimage_usage);
    v.check(!formats.isCompressed(cmn.pixel_format) and !core.isDepthOrDepthStencilFormat(cmn.pixel_format), .validate_readimage_pixelformat);
    v.check(cmn.sample_count == 1, .validate_readimage_msaa);
    const mip_ok = region.mip_level < cmn.num_mipmaps;
    v.check(mip_ok, .validate_readimage_miplevel);
    if (!mip_ok) return v.end();
    const mip: i32 = @intCast(region.mip_level);
    const mip_width: u64 = @intCast(core.miplevelDim(cmn.width, mip));
    const mip_height: u64 = @intCast(core.miplevelDim(cmn.height, mip));
    const mip_slices: u64 = @intCast(mipDepthOrSlices(cmn, mip));
    v.check(region.width > 0 and region.height > 0 and region.num_slices > 0 and
        @as(u64, region.x) + region.width <= mip_width and
        @as(u64, region.y) + region.height <= mip_height and
        @as(u64, region.slice) + region.num_slices <= mip_slices, .validate_readimage_region);
    if (!v.failed) {
        const row_bytes: usize = @intCast(formats.rowPitch(cmn.pixel_format, @intCast(region.width), 1));
        v.check(region.bytes_per_row >= row_bytes, .validate_readimage_bytesperrow);
        v.check(region.bytes_per_slice >= region.bytes_per_row * region.height, .validate_readimage_bytesperslice);
        const required = @as(u128, region.num_slices - 1) * region.bytes_per_slice + @as(u128, region.height - 1) * region.bytes_per_row + row_bytes;
        v.check(len >= required, .validate_readimage_dst_size);
    }
    return v.end();
}
