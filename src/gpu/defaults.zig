//! Descriptor default resolution from sokol_gfx.h:26699-26936 and 27274-27353.
const std = @import("std");
const t = @import("types.zig");
const e = @import("enums.zig");
const formats = @import("formats.zig");

fn resolve(comptime T: type, value: T, fallback: T) T {
    const zero = switch (@typeInfo(T)) {
        .@"enum" => @backingInt(value) == 0,
        else => value == 0,
    };
    return if (zero) fallback else value;
}

pub fn desc(value: t.Desc, backend: e.Backend) t.Desc {
    var result = value;
    const env = &result.environment.defaults;
    if (backend == .wgpu) {
        std.debug.assert(@backingInt(env.color_format) > @backingInt(e.PixelFormat.none));
    } else {
        env.color_format = resolve(e.PixelFormat, env.color_format, switch (backend) {
            .metal_ios, .metal_macos, .metal_simulator, .d3d11, .d3d12 => .bgra8,
            else => .rgba8,
        });
    }
    env.depth_format = resolve(e.PixelFormat, env.depth_format, .depth_stencil);
    env.sample_count = resolve(i32, env.sample_count, 1);
    inline for (.{ .{ "buffer_pool_size", 128 }, .{ "image_pool_size", 128 }, .{ "sampler_pool_size", 64 }, .{ "shader_pool_size", 32 }, .{ "pipeline_pool_size", 64 }, .{ "view_pool_size", 256 }, .{ "uniform_buffer_size", 4 * 1024 * 1024 }, .{ "max_commit_listeners", 1024 } }) |field| {
        @field(result, field[0]) = resolve(i32, @field(result, field[0]), field[1]);
    }
    result.wgpu.bindgroups_cache_size = resolve(i32, result.wgpu.bindgroups_cache_size, 1024);
    result.vulkan.copy_staging_buffer_size = resolve(i32, result.vulkan.copy_staging_buffer_size, 4 * 1024 * 1024);
    result.vulkan.transient_staging_buffer_size = resolve(i32, result.vulkan.transient_staging_buffer_size, 16 * 1024 * 1024);
    result.vulkan.descriptor_buffer_size = resolve(i32, result.vulkan.descriptor_buffer_size, 16 * 1024 * 1024);
    return result;
}

pub fn buffer(value: t.BufferDesc) t.BufferDesc {
    var result = value;
    const usage = &result.usage;
    if (!(usage.vertex_buffer or usage.index_buffer or usage.storage_buffer or usage.staging_buffer or usage.staging_index_buffer)) usage.vertex_buffer = true;
    if (result.size == 0) result.size = result.data.size;
    return result;
}

pub fn image(value: t.ImageDesc, env: t.EnvironmentDefaults) t.ImageDesc {
    var result = value;
    result.type = resolve(e.ImageType, result.type, .@"2d");
    const usage = &result.usage;
    if (!(usage.immutable or usage.write_transient or usage.copy_dst)) usage.immutable = true;
    result.num_slices = resolve(i32, result.num_slices, if (result.type == .cube) 6 else 1);
    result.num_mipmaps = resolve(i32, result.num_mipmaps, 1);
    if (usage.color_attachment or usage.resolve_attachment) {
        result.pixel_format = resolve(e.PixelFormat, result.pixel_format, env.color_format);
        result.sample_count = resolve(i32, result.sample_count, env.sample_count);
    } else if (usage.depth_stencil_attachment) {
        result.pixel_format = resolve(e.PixelFormat, result.pixel_format, env.depth_format);
        result.sample_count = resolve(i32, result.sample_count, env.sample_count);
    } else {
        result.pixel_format = resolve(e.PixelFormat, result.pixel_format, .rgba8);
        result.sample_count = resolve(i32, result.sample_count, 1);
    }
    return result;
}

pub fn sampler(value: t.SamplerDesc) t.SamplerDesc {
    var result = value;
    inline for (.{ "min_filter", "mag_filter", "mipmap_filter" }) |name| @field(result, name) = resolve(e.Filter, @field(result, name), .nearest);
    inline for (.{ "wrap_u", "wrap_v", "wrap_w" }) |name| @field(result, name) = resolve(e.Wrap, @field(result, name), .repeat);
    result.max_lod = resolve(f32, result.max_lod, std.math.floatMax(f32));
    result.border_color = resolve(e.BorderColor, result.border_color, .opaque_black);
    result.compare = resolve(e.CompareFunc, result.compare, .never);
    result.max_anisotropy = resolve(u32, result.max_anisotropy, 1);
    return result;
}

pub fn shader(value: t.ShaderDesc, backend: e.Backend) t.ShaderDesc {
    var result = value;
    const entry: [*:0]const u8 = switch (backend) {
        .metal_ios, .metal_macos, .metal_simulator => "_main",
        else => "main",
    };
    inline for (.{ "vertex_func", "fragment_func", "compute_func" }) |name| {
        const function = &@field(result, name);
        if (function.entry == null) function.entry = entry;
    }
    if (backend == .d3d11) {
        if (result.vertex_func.source != null and result.vertex_func.d3d11_target == null) result.vertex_func.d3d11_target = "vs_4_0";
        if (result.fragment_func.source != null and result.fragment_func.d3d11_target == null) result.fragment_func.d3d11_target = "ps_4_0";
        if (result.compute_func.source != null) result.compute_func.d3d11_target = result.fragment_func.d3d11_target orelse "cs_5_0";
    }
    result.mtl_threads_per_threadgroup.y = resolve(i32, result.mtl_threads_per_threadgroup.y, 1);
    result.mtl_threads_per_threadgroup.z = resolve(i32, result.mtl_threads_per_threadgroup.z, 1);
    for (&result.uniform_blocks) |*block| {
        if (block.stage == .none) continue;
        block.layout = resolve(e.UniformLayout, block.layout, .native);
        for (&block.glsl_uniforms) |*uniform| {
            if (uniform.type == .invalid) break;
            uniform.array_count = resolve(u16, uniform.array_count, 1);
        }
    }
    for (&result.views) |*view| {
        if (view.texture.stage != .none) {
            view.texture.image_type = resolve(e.ImageType, view.texture.image_type, .@"2d");
            view.texture.sample_type = resolve(e.ImageSampleType, view.texture.sample_type, .float);
        } else if (view.storage_image.stage != .none) {
            view.storage_image.image_type = resolve(e.ImageType, view.storage_image.image_type, .@"2d");
        }
    }
    for (&result.samplers) |*smp| {
        if (smp.stage != .none) smp.sampler_type = resolve(e.SamplerType, smp.sampler_type, .filtering);
    }
    return result;
}

pub fn pipeline(value: t.PipelineDesc, env: t.EnvironmentDefaults) t.PipelineDesc {
    var result = value;
    result.primitive_type = resolve(e.PrimitiveType, result.primitive_type, .triangles);
    result.index_type = resolve(e.IndexType, result.index_type, .none);
    result.cull_mode = resolve(e.CullMode, result.cull_mode, .none);
    result.face_winding = resolve(e.FaceWinding, result.face_winding, .cw);
    result.sample_count = resolve(i32, result.sample_count, env.sample_count);
    inline for (.{ "front", "back" }) |name| {
        const face = &@field(result.stencil, name);
        face.compare = resolve(e.CompareFunc, face.compare, .always);
        inline for (.{ "fail_op", "depth_fail_op", "pass_op" }) |op| @field(face, op) = resolve(e.StencilOp, @field(face, op), .keep);
    }
    result.depth.compare = resolve(e.CompareFunc, result.depth.compare, .always);
    result.depth.pixel_format = resolve(e.PixelFormat, result.depth.pixel_format, env.depth_format);
    result.color_count = if (result.colors[0].pixel_format == .none) 0 else @min(resolve(i32, result.color_count, 1), 8);
    // a negative color count is passed through to validation, like the original
    for (result.colors[0..@intCast(@max(result.color_count, 0))]) |*color| {
        color.pixel_format = resolve(e.PixelFormat, color.pixel_format, env.color_format);
        color.write_mask = resolve(e.ColorMask, color.write_mask, .rgba);
        const blend = &color.blend;
        blend.op_rgb = resolve(e.BlendOp, blend.op_rgb, .add);
        blend.src_factor_rgb = resolve(e.BlendFactor, blend.src_factor_rgb, .one);
        blend.dst_factor_rgb = resolve(e.BlendFactor, blend.dst_factor_rgb, if (blend.op_rgb == .min or blend.op_rgb == .max) .one else .zero);
        blend.op_alpha = resolve(e.BlendOp, blend.op_alpha, .add);
        blend.src_factor_alpha = resolve(e.BlendFactor, blend.src_factor_alpha, .one);
        blend.dst_factor_alpha = resolve(e.BlendFactor, blend.dst_factor_alpha, if (blend.op_alpha == .min or blend.op_alpha == .max) .one else .zero);
    }
    var offsets: [8]i32 = @splat(0);
    var automatic: [8]bool = @splat(true);
    for (result.layout.attrs) |attr| {
        if (attr.format == .invalid) break;
        std.debug.assert(attr.buffer_index >= 0 and attr.buffer_index < 8);
        if (attr.offset != 0) automatic[@intCast(attr.buffer_index)] = false;
    }
    for (&result.layout.attrs) |*attr| {
        if (attr.format == .invalid) break;
        const index: usize = @intCast(attr.buffer_index);
        const layout = &result.layout.buffers[index];
        layout.step_func = resolve(e.VertexStep, layout.step_func, .per_vertex);
        layout.step_rate = resolve(i32, layout.step_rate, 1);
        if (automatic[index]) attr.offset = offsets[index];
        offsets[index] += formats.vertexSize(attr.format);
    }
    for (&result.layout.buffers, offsets) |*layout, offset| {
        if (layout.stride == 0) layout.stride = offset;
    }
    return result;
}

pub fn passAction(value: t.PassAction) t.PassAction {
    var result = value;
    for (&result.colors) |*color| {
        if (color.load_action == .default) {
            color.load_action = .clear;
            color.clear_value = .{ .r = 0.5, .g = 0.5, .b = 0.5, .a = 1 };
        }
        if (color.store_action == .default) color.store_action = .store;
    }
    if (result.depth.load_action == .default) {
        result.depth.load_action = .clear;
        result.depth.clear_value = 1;
    }
    if (result.stencil.load_action == .default) {
        result.stencil.load_action = .clear;
        result.stencil.clear_value = 0;
    }
    result.depth.store_action = resolve(e.StoreAction, result.depth.store_action, .dontcare);
    result.stencil.store_action = resolve(e.StoreAction, result.stencil.store_action, .dontcare);
    return result;
}

pub fn attachmentsEmpty(value: t.Attachments) bool {
    for (value.colors, value.resolves) |color, resolved| {
        if (color.id != 0 or resolved.id != 0) return false;
    }
    return value.depth_stencil.id == 0;
}

pub fn pass(value: t.Pass, env: t.EnvironmentDefaults) t.Pass {
    var result = value;
    if (!result.compute) {
        if (!result.swapchain.invalid and attachmentsEmpty(result.attachments)) {
            result.swapchain.sample_count = resolve(i32, result.swapchain.sample_count, env.sample_count);
            result.swapchain.color_format = resolve(e.PixelFormat, result.swapchain.color_format, env.color_format);
            result.swapchain.depth_format = resolve(e.PixelFormat, result.swapchain.depth_format, env.depth_format);
        }
        result.action = passAction(result.action);
    }
    return result;
}

pub fn writeBuffer(value: t.WriteBufferDesc) t.WriteBufferDesc {
    var result = value;
    if (result.src.offset < result.src.data.size and result.size == 0) result.size = result.src.data.size - result.src.offset;
    return result;
}

pub fn imageTransfer(comptime T: type, value: T, image_desc: t.ImageDesc) T {
    var result = value;
    const width = formats.mipDimension(image_desc.width, value.dst.mip_level);
    const height = formats.mipDimension(image_desc.height, value.dst.mip_level);
    const slices = if (image_desc.type == .@"3d") formats.mipDimension(image_desc.num_slices, value.dst.mip_level) else image_desc.num_slices;
    result.src.bytes_per_row = resolve(i32, result.src.bytes_per_row, formats.rowPitch(image_desc.pixel_format, width, 1));
    result.src.bytes_per_slice = resolve(i32, result.src.bytes_per_slice, formats.surfacePitch(image_desc.pixel_format, width, height, 1));
    result.size.width = resolve(i32, result.size.width, width - value.dst.x);
    result.size.height = resolve(i32, result.size.height, height - value.dst.y);
    result.size.num_slices = resolve(i32, result.size.num_slices, slices - value.dst.slice);
    return result;
}
