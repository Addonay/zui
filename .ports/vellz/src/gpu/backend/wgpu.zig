//! wgpu-backed render backend: shader modules, bind-group/pipeline factory,
//! resource creation, uploads, and the strip/clear render passes
//! (Apache-2.0 OR MIT).
//!
//! This is the T3/T4 port of the resource-creation subset of
//! `vello_gpu/src/render/wgpu/mod.rs`:
//!
//! - Shader modules are built from the checked-in WGSL in
//!   `src/gpu/shaders/generated.zig` (no runtime WESL/naga).
//! - `Layouts` mirrors the bind-group layout table in
//!   `docs/shader-interface.md` §2 exactly, including sample types.
//! - `Pipelines` creates the four 24-byte instanced strip variants
//!   (intermediate/alpha/depth-alpha/opaque), the three clear pipelines, and
//!   the copy/blend/filter pipelines.
//! - `writeRgba32Uint` uploads texel data with 256-byte-aligned rows.
//! - `stripPass`/`clearPass`/`clearFullTarget` encode the root passes.
//!
//! The earlier smoke-test API (`ClearPipeline`/`clearTexture`) is preserved for
//! `tools/gpu_smoke.zig`.

const std = @import("std");
const wgpu = @import("wgpu");
const c = wgpu.c;
const device = @import("device.zig");
const shaders = @import("../shaders/generated.zig");
const common = @import("../render/common.zig");
const filter_mod = @import("../filter.zig");
const common_util = @import("../../common/util.zig");

pub const Error = device.Error || error{
    ShaderCreationFailed,
    PipelineCreationFailed,
    TextureCreationFailed,
    TextureViewCreationFailed,
    RenderPassFailed,
    CommandEncodingFailed,
    BufferCreationFailed,
    BindGroupCreationFailed,
};

/// WebGPU requires row strides in buffer/texel copies to be a multiple of this
/// many bytes.
pub const COPY_BYTES_PER_ROW_ALIGNMENT: u32 = 256;

/// Create a WGSL shader module from a checked-in source string.
pub fn createShaderModule(
    dev: *device.Device,
    code: []const u8,
    label: []const u8,
) Error!c.WGPUShaderModule {
    var source = c.wgpu_zig_init_WGPUShaderSourceWGSL();
    source.chain.sType = c.WGPUSType_ShaderSourceWGSL;
    source.code = wgpu.stringView(code);

    var desc = c.wgpu_zig_init_WGPUShaderModuleDescriptor();
    desc.label = wgpu.stringView(label);
    desc.nextInChain = &source.chain;
    return c.wgpuDeviceCreateShaderModule(dev.handle, &desc) orelse error.ShaderCreationFailed;
}

/// Create a 2D texture with the given size, format, and usage.
pub fn createTexture2d(
    dev: *device.Device,
    width: u32,
    height: u32,
    format: c.WGPUTextureFormat,
    usage: c.WGPUTextureUsage,
    label: []const u8,
) Error!c.WGPUTexture {
    var desc = c.wgpu_zig_init_WGPUTextureDescriptor();
    desc.label = wgpu.stringView(label);
    desc.usage = usage;
    desc.dimension = c.WGPUTextureDimension_2D;
    desc.size = .{ .width = width, .height = height, .depthOrArrayLayers = 1 };
    desc.format = format;
    return c.wgpuDeviceCreateTexture(dev.handle, &desc) orelse error.TextureCreationFailed;
}

/// Create a full-size 2D texture view.
pub fn createFullView(
    texture: c.WGPUTexture,
    format: c.WGPUTextureFormat,
    label: []const u8,
) Error!c.WGPUTextureView {
    var desc = c.wgpu_zig_init_WGPUTextureViewDescriptor();
    desc.label = wgpu.stringView(label);
    desc.format = format;
    desc.dimension = c.WGPUTextureViewDimension_2D;
    return c.wgpuTextureCreateView(texture, &desc) orelse error.TextureViewCreationFailed;
}

// ---------------------------------------------------------------------------
// Descriptor builders (bind-group layouts and pipeline state)
// ---------------------------------------------------------------------------

fn textureLayoutEntry(
    binding: u32,
    visibility: c.WGPUShaderStage,
    sample_type: c.WGPUTextureSampleType,
) c.WGPUBindGroupLayoutEntry {
    var entry = c.wgpu_zig_init_WGPUBindGroupLayoutEntry();
    entry.binding = binding;
    entry.visibility = visibility;
    entry.texture.sampleType = sample_type;
    entry.texture.viewDimension = c.WGPUTextureViewDimension_2D;
    return entry;
}

fn uniformLayoutEntry(binding: u32, visibility: c.WGPUShaderStage) c.WGPUBindGroupLayoutEntry {
    var entry = c.wgpu_zig_init_WGPUBindGroupLayoutEntry();
    entry.binding = binding;
    entry.visibility = visibility;
    entry.buffer.type = c.WGPUBufferBindingType_Uniform;
    return entry;
}

fn samplerLayoutEntry(binding: u32, binding_type: c.WGPUSamplerBindingType) c.WGPUBindGroupLayoutEntry {
    var entry = c.wgpu_zig_init_WGPUBindGroupLayoutEntry();
    entry.binding = binding;
    entry.visibility = c.WGPUShaderStage_Fragment;
    entry.sampler.type = binding_type;
    return entry;
}

/// Create a bind-group layout from a static entry list.
pub fn createBindGroupLayout(
    dev: *device.Device,
    label: []const u8,
    entries: []const c.WGPUBindGroupLayoutEntry,
) Error!c.WGPUBindGroupLayout {
    var desc = c.wgpu_zig_init_WGPUBindGroupLayoutDescriptor();
    desc.label = wgpu.stringView(label);
    desc.entryCount = entries.len;
    desc.entries = if (entries.len == 0) null else entries.ptr;
    return c.wgpuDeviceCreateBindGroupLayout(dev.handle, &desc) orelse error.BindGroupCreationFailed;
}

/// The bind-group layouts from `docs/shader-interface.md` §2.
pub const Layouts = struct {
    /// Render group 0: alphas (`Uint`), `Config` uniform, child layer
    /// (`UnfilterableFloat`).
    strip: c.WGPUBindGroupLayout,
    /// Render group 1: four external textures (`UnfilterableFloat`).
    external_texture: c.WGPUBindGroupLayout,
    /// Render group 2: encoded paints (`Uint`).
    encoded_paints: c.WGPUBindGroupLayout,
    /// Render group 3: gradient LUT (filterable float).
    gradient: c.WGPUBindGroupLayout,
    /// Filter group 0: filter data (`Uint`).
    filter_data: c.WGPUBindGroupLayout,
    /// Filter group 1: source texture (filterable float) + filtering sampler.
    filter_input: c.WGPUBindGroupLayout,
    /// Filter group 2: original texture (filterable float).
    filter_original: c.WGPUBindGroupLayout,
    /// Blend group 0: two unfilterable layers + alphas.
    blend: c.WGPUBindGroupLayout,
    /// Copy group 0: unfilterable source.
    copy: c.WGPUBindGroupLayout,

    /// Create every layout, releasing on failure.
    pub fn create(dev: *device.Device) Error!Layouts {
        const strip_entries = [_]c.WGPUBindGroupLayoutEntry{
            textureLayoutEntry(0, c.WGPUShaderStage_Fragment, c.WGPUTextureSampleType_Uint),
            uniformLayoutEntry(1, c.WGPUShaderStage_Vertex | c.WGPUShaderStage_Fragment),
            textureLayoutEntry(2, c.WGPUShaderStage_Fragment, c.WGPUTextureSampleType_UnfilterableFloat),
        };
        const external_entries = [_]c.WGPUBindGroupLayoutEntry{
            textureLayoutEntry(0, c.WGPUShaderStage_Fragment, c.WGPUTextureSampleType_UnfilterableFloat),
            textureLayoutEntry(1, c.WGPUShaderStage_Fragment, c.WGPUTextureSampleType_UnfilterableFloat),
            textureLayoutEntry(2, c.WGPUShaderStage_Fragment, c.WGPUTextureSampleType_UnfilterableFloat),
            textureLayoutEntry(3, c.WGPUShaderStage_Fragment, c.WGPUTextureSampleType_UnfilterableFloat),
        };
        const encoded_entries = [_]c.WGPUBindGroupLayoutEntry{
            textureLayoutEntry(
                0,
                c.WGPUShaderStage_Vertex | c.WGPUShaderStage_Fragment,
                c.WGPUTextureSampleType_Uint,
            ),
        };
        const gradient_entries = [_]c.WGPUBindGroupLayoutEntry{
            textureLayoutEntry(0, c.WGPUShaderStage_Fragment, c.WGPUTextureSampleType_Float),
        };
        const filter_data_entries = [_]c.WGPUBindGroupLayoutEntry{
            textureLayoutEntry(0, c.WGPUShaderStage_Fragment, c.WGPUTextureSampleType_Uint),
        };
        const filter_input_entries = [_]c.WGPUBindGroupLayoutEntry{
            textureLayoutEntry(0, c.WGPUShaderStage_Fragment, c.WGPUTextureSampleType_Float),
            samplerLayoutEntry(1, c.WGPUSamplerBindingType_Filtering),
        };
        const filter_original_entries = [_]c.WGPUBindGroupLayoutEntry{
            textureLayoutEntry(0, c.WGPUShaderStage_Fragment, c.WGPUTextureSampleType_Float),
        };
        const blend_entries = [_]c.WGPUBindGroupLayoutEntry{
            textureLayoutEntry(0, c.WGPUShaderStage_Fragment, c.WGPUTextureSampleType_UnfilterableFloat),
            textureLayoutEntry(1, c.WGPUShaderStage_Fragment, c.WGPUTextureSampleType_UnfilterableFloat),
            textureLayoutEntry(2, c.WGPUShaderStage_Fragment, c.WGPUTextureSampleType_Uint),
        };
        const copy_entries = [_]c.WGPUBindGroupLayoutEntry{
            textureLayoutEntry(0, c.WGPUShaderStage_Fragment, c.WGPUTextureSampleType_UnfilterableFloat),
        };

        var layouts: Layouts = undefined;
        layouts.strip = try createBindGroupLayout(dev, "vellz-strip-layout", &strip_entries);
        errdefer c.wgpuBindGroupLayoutRelease(layouts.strip);
        layouts.external_texture = try createBindGroupLayout(dev, "vellz-external-layout", &external_entries);
        errdefer c.wgpuBindGroupLayoutRelease(layouts.external_texture);
        layouts.encoded_paints = try createBindGroupLayout(dev, "vellz-encoded-paints-layout", &encoded_entries);
        errdefer c.wgpuBindGroupLayoutRelease(layouts.encoded_paints);
        layouts.gradient = try createBindGroupLayout(dev, "vellz-gradient-layout", &gradient_entries);
        errdefer c.wgpuBindGroupLayoutRelease(layouts.gradient);
        layouts.filter_data = try createBindGroupLayout(dev, "vellz-filter-data-layout", &filter_data_entries);
        errdefer c.wgpuBindGroupLayoutRelease(layouts.filter_data);
        layouts.filter_input = try createBindGroupLayout(dev, "vellz-filter-input-layout", &filter_input_entries);
        errdefer c.wgpuBindGroupLayoutRelease(layouts.filter_input);
        layouts.filter_original = try createBindGroupLayout(dev, "vellz-filter-original-layout", &filter_original_entries);
        errdefer c.wgpuBindGroupLayoutRelease(layouts.filter_original);
        layouts.blend = try createBindGroupLayout(dev, "vellz-blend-layout", &blend_entries);
        errdefer c.wgpuBindGroupLayoutRelease(layouts.blend);
        layouts.copy = try createBindGroupLayout(dev, "vellz-copy-layout", &copy_entries);
        return layouts;
    }

    /// Release every layout.
    pub fn deinit(self: *Layouts) void {
        c.wgpuBindGroupLayoutRelease(self.copy);
        c.wgpuBindGroupLayoutRelease(self.blend);
        c.wgpuBindGroupLayoutRelease(self.filter_original);
        c.wgpuBindGroupLayoutRelease(self.filter_input);
        c.wgpuBindGroupLayoutRelease(self.filter_data);
        c.wgpuBindGroupLayoutRelease(self.gradient);
        c.wgpuBindGroupLayoutRelease(self.encoded_paints);
        c.wgpuBindGroupLayoutRelease(self.external_texture);
        c.wgpuBindGroupLayoutRelease(self.strip);
        self.* = undefined;
    }
};

/// The five checked-in WGSL modules.
pub const ShaderModules = struct {
    render: c.WGPUShaderModule,
    clear: c.WGPUShaderModule,
    copy: c.WGPUShaderModule,
    blend: c.WGPUShaderModule,
    filter: c.WGPUShaderModule,

    /// Create every module.
    pub fn create(dev: *device.Device) Error!ShaderModules {
        var modules: ShaderModules = undefined;
        modules.render = try createShaderModule(dev, shaders.RENDER, "vellz-render-shader");
        errdefer c.wgpuShaderModuleRelease(modules.render);
        modules.clear = try createShaderModule(dev, shaders.CLEAR, "vellz-clear-shader");
        errdefer c.wgpuShaderModuleRelease(modules.clear);
        modules.copy = try createShaderModule(dev, shaders.COPY, "vellz-copy-shader");
        errdefer c.wgpuShaderModuleRelease(modules.copy);
        modules.blend = try createShaderModule(dev, shaders.BLEND, "vellz-blend-shader");
        errdefer c.wgpuShaderModuleRelease(modules.blend);
        modules.filter = try createShaderModule(dev, shaders.FILTER, "vellz-filter-shader");
        return modules;
    }

    /// Release every module.
    pub fn deinit(self: *ShaderModules) void {
        c.wgpuShaderModuleRelease(self.filter);
        c.wgpuShaderModuleRelease(self.blend);
        c.wgpuShaderModuleRelease(self.copy);
        c.wgpuShaderModuleRelease(self.clear);
        c.wgpuShaderModuleRelease(self.render);
        self.* = undefined;
    }
};

fn premultipliedAlphaBlend() c.WGPUBlendState {
    var blend = c.wgpu_zig_init_WGPUBlendState();
    blend.color.srcFactor = c.WGPUBlendFactor_One;
    blend.color.dstFactor = c.WGPUBlendFactor_OneMinusSrcAlpha;
    blend.color.operation = c.WGPUBlendOperation_Add;
    blend.alpha.srcFactor = c.WGPUBlendFactor_One;
    blend.alpha.dstFactor = c.WGPUBlendFactor_OneMinusSrcAlpha;
    blend.alpha.operation = c.WGPUBlendOperation_Add;
    return blend;
}

fn depthStencilState(depth_write_enabled: bool) c.WGPUDepthStencilState {
    var state = c.wgpu_zig_init_WGPUDepthStencilState();
    state.format = c.WGPUTextureFormat_Depth24Plus;
    state.depthWriteEnabled = if (depth_write_enabled) c.WGPUOptionalBool_True else c.WGPUOptionalBool_False;
    state.depthCompare = c.WGPUCompareFunction_LessEqual;
    return state;
}

/// The render pipelines from `docs/shader-interface.md` §5.
pub const Pipelines = struct {
    /// Intermediate strip pipeline (`Rgba8Unorm`, premultiplied alpha).
    intermediate_strip: c.WGPURenderPipeline,
    /// Root alpha-strip pipeline (`format`, premultiplied alpha).
    alpha_strip: c.WGPURenderPipeline,
    /// Root alpha-strip pipeline with depth testing (`Depth24Plus`,
    /// LessEqual, no writes).
    depth_alpha_strip: c.WGPURenderPipeline,
    /// Root opaque-strip pipeline (`Depth24Plus`, LessEqual, writes).
    opaque_strip: c.WGPURenderPipeline,
    /// Layer-clear pipeline (`Rgba8Unorm`).
    clear: c.WGPURenderPipeline,
    /// User-target rectangle-clear pipeline (`format`).
    root_clear: c.WGPURenderPipeline,
    /// Atlas-region clear (`Rgba8Unorm`, fullscreen vertex + transparent
    /// fragment).
    atlas_clear: c.WGPURenderPipeline,
    /// Copy pipeline.
    copy: c.WGPURenderPipeline,
    /// Blend pipeline.
    blend: c.WGPURenderPipeline,
    /// Filter pipeline.
    filter: c.WGPURenderPipeline,

    /// Create every pipeline. `format` is the caller's target format; the
    /// intermediate/atlas pipelines are fixed to `Rgba8Unorm` per the shader
    /// contract.
    pub fn create(
        dev: *device.Device,
        layouts: *const Layouts,
        modules: *const ShaderModules,
        format: c.WGPUTextureFormat,
    ) Error!Pipelines {
        // Strip pipeline layout: four groups.
        var strip_groups = [_]c.WGPUBindGroupLayout{
            layouts.strip,
            layouts.external_texture,
            layouts.encoded_paints,
            layouts.gradient,
        };
        const strip_pipeline_layout = try createPipelineLayout(dev, "vellz-strip-pipeline-layout", &strip_groups);
        defer c.wgpuPipelineLayoutRelease(strip_pipeline_layout);

        var no_groups: [0]c.WGPUBindGroupLayout = .{};
        const clear_pipeline_layout = try createPipelineLayout(dev, "vellz-clear-pipeline-layout", &no_groups);
        defer c.wgpuPipelineLayoutRelease(clear_pipeline_layout);

        var filter_groups = [_]c.WGPUBindGroupLayout{
            layouts.filter_data,
            layouts.filter_input,
            layouts.filter_original,
        };
        const filter_pipeline_layout = try createPipelineLayout(dev, "vellz-filter-pipeline-layout", &filter_groups);
        defer c.wgpuPipelineLayoutRelease(filter_pipeline_layout);

        var blend_groups = [_]c.WGPUBindGroupLayout{layouts.blend};
        const blend_pipeline_layout = try createPipelineLayout(dev, "vellz-blend-pipeline-layout", &blend_groups);
        defer c.wgpuPipelineLayoutRelease(blend_pipeline_layout);

        var copy_groups = [_]c.WGPUBindGroupLayout{layouts.copy};
        const copy_pipeline_layout = try createPipelineLayout(dev, "vellz-copy-pipeline-layout", &copy_groups);
        defer c.wgpuPipelineLayoutRelease(copy_pipeline_layout);

        const blend_state = premultipliedAlphaBlend();

        var pipelines: Pipelines = undefined;
        pipelines.intermediate_strip = try createStripPipeline(
            dev,
            strip_pipeline_layout,
            modules.render,
            c.WGPUTextureFormat_RGBA8Unorm,
            &blend_state,
            null,
            "vellz-strip-intermediate",
        );
        errdefer c.wgpuRenderPipelineRelease(pipelines.intermediate_strip);
        pipelines.alpha_strip = try createStripPipeline(
            dev,
            strip_pipeline_layout,
            modules.render,
            format,
            &blend_state,
            null,
            "vellz-strip-alpha",
        );
        errdefer c.wgpuRenderPipelineRelease(pipelines.alpha_strip);
        var depth_alpha = depthStencilState(false);
        pipelines.depth_alpha_strip = try createStripPipeline(
            dev,
            strip_pipeline_layout,
            modules.render,
            format,
            &blend_state,
            &depth_alpha,
            "vellz-strip-depth-alpha",
        );
        errdefer c.wgpuRenderPipelineRelease(pipelines.depth_alpha_strip);
        var depth_opaque = depthStencilState(true);
        pipelines.opaque_strip = try createStripPipeline(
            dev,
            strip_pipeline_layout,
            modules.render,
            format,
            null,
            &depth_opaque,
            "vellz-strip-opaque",
        );
        errdefer c.wgpuRenderPipelineRelease(pipelines.opaque_strip);

        pipelines.clear = try createClearPipeline(
            dev,
            clear_pipeline_layout,
            modules.clear,
            c.WGPUTextureFormat_RGBA8Unorm,
            "vs_main",
            "fs_main",
            true,
            "vellz-clear",
        );
        errdefer c.wgpuRenderPipelineRelease(pipelines.clear);
        pipelines.root_clear = try createClearPipeline(
            dev,
            clear_pipeline_layout,
            modules.clear,
            format,
            "vs_main",
            "fs_main",
            true,
            "vellz-root-clear",
        );
        errdefer c.wgpuRenderPipelineRelease(pipelines.root_clear);
        pipelines.atlas_clear = try createClearPipeline(
            dev,
            clear_pipeline_layout,
            modules.clear,
            c.WGPUTextureFormat_RGBA8Unorm,
            "vs_main_fullscreen",
            "fs_transparent",
            false,
            "vellz-atlas-clear",
        );
        errdefer c.wgpuRenderPipelineRelease(pipelines.atlas_clear);

        const copy_attributes = copyAttributes();
        var copy_vertex = c.wgpu_zig_init_WGPUVertexBufferLayout();
        copy_vertex.arrayStride = @sizeOf(common.GpuCopyInstance);
        copy_vertex.stepMode = c.WGPUVertexStepMode_Instance;
        copy_vertex.attributeCount = copy_attributes.len;
        copy_vertex.attributes = &copy_attributes;
        pipelines.copy = try createTextureOpPipeline(
            dev,
            copy_pipeline_layout,
            modules.copy,
            &copy_vertex,
            "vellz-copy",
        );
        errdefer c.wgpuRenderPipelineRelease(pipelines.copy);

        const blend_attributes = blendAttributes();
        var blend_vertex = c.wgpu_zig_init_WGPUVertexBufferLayout();
        blend_vertex.arrayStride = @sizeOf(common.GpuBlendInstance);
        blend_vertex.stepMode = c.WGPUVertexStepMode_Instance;
        blend_vertex.attributeCount = blend_attributes.len;
        blend_vertex.attributes = &blend_attributes;
        pipelines.blend = try createTextureOpPipeline(
            dev,
            blend_pipeline_layout,
            modules.blend,
            &blend_vertex,
            "vellz-blend",
        );
        errdefer c.wgpuRenderPipelineRelease(pipelines.blend);

        const filter_attributes = filterInstanceAttributes();
        var filter_vertex = c.wgpu_zig_init_WGPUVertexBufferLayout();
        filter_vertex.arrayStride = @sizeOf(filter_mod.FilterInstanceData);
        filter_vertex.stepMode = c.WGPUVertexStepMode_Instance;
        filter_vertex.attributeCount = filter_attributes.len;
        filter_vertex.attributes = &filter_attributes;
        pipelines.filter = try createTextureOpPipeline(
            dev,
            filter_pipeline_layout,
            modules.filter,
            &filter_vertex,
            "vellz-filter",
        );

        return pipelines;
    }

    /// Release every pipeline.
    pub fn deinit(self: *Pipelines) void {
        c.wgpuRenderPipelineRelease(self.filter);
        c.wgpuRenderPipelineRelease(self.blend);
        c.wgpuRenderPipelineRelease(self.copy);
        c.wgpuRenderPipelineRelease(self.atlas_clear);
        c.wgpuRenderPipelineRelease(self.root_clear);
        c.wgpuRenderPipelineRelease(self.clear);
        c.wgpuRenderPipelineRelease(self.opaque_strip);
        c.wgpuRenderPipelineRelease(self.depth_alpha_strip);
        c.wgpuRenderPipelineRelease(self.alpha_strip);
        c.wgpuRenderPipelineRelease(self.intermediate_strip);
        self.* = undefined;
    }
};

fn createPipelineLayout(
    dev: *device.Device,
    label: []const u8,
    groups: []const c.WGPUBindGroupLayout,
) Error!c.WGPUPipelineLayout {
    var desc = c.wgpu_zig_init_WGPUPipelineLayoutDescriptor();
    desc.label = wgpu.stringView(label);
    desc.bindGroupLayoutCount = groups.len;
    desc.bindGroupLayouts = if (groups.len == 0) null else groups.ptr;
    return c.wgpuDeviceCreatePipelineLayout(dev.handle, &desc) orelse error.PipelineCreationFailed;
}

fn stripAttributes() [6]c.WGPUVertexAttribute {
    return .{
        .{ .format = c.WGPUVertexFormat_Uint32, .offset = 0, .shaderLocation = 0 },
        .{ .format = c.WGPUVertexFormat_Uint32, .offset = 4, .shaderLocation = 1 },
        .{ .format = c.WGPUVertexFormat_Uint32, .offset = 8, .shaderLocation = 2 },
        .{ .format = c.WGPUVertexFormat_Uint32, .offset = 12, .shaderLocation = 3 },
        .{ .format = c.WGPUVertexFormat_Uint32, .offset = 16, .shaderLocation = 4 },
        .{ .format = c.WGPUVertexFormat_Uint32, .offset = 20, .shaderLocation = 5 },
    };
}

fn filterInstanceAttributes() [9]c.WGPUVertexAttribute {
    return .{
        .{ .format = c.WGPUVertexFormat_Uint32, .offset = 0, .shaderLocation = 0 },
        .{ .format = c.WGPUVertexFormat_Uint32, .offset = 4, .shaderLocation = 1 },
        .{ .format = c.WGPUVertexFormat_Uint32, .offset = 8, .shaderLocation = 2 },
        .{ .format = c.WGPUVertexFormat_Uint32, .offset = 12, .shaderLocation = 3 },
        .{ .format = c.WGPUVertexFormat_Uint32, .offset = 16, .shaderLocation = 4 },
        .{ .format = c.WGPUVertexFormat_Uint32, .offset = 20, .shaderLocation = 5 },
        .{ .format = c.WGPUVertexFormat_Uint32, .offset = 24, .shaderLocation = 6 },
        .{ .format = c.WGPUVertexFormat_Uint32, .offset = 28, .shaderLocation = 7 },
        .{ .format = c.WGPUVertexFormat_Uint32, .offset = 32, .shaderLocation = 8 },
    };
}

fn clearAttributes() [4]c.WGPUVertexAttribute {
    return .{
        .{ .format = c.WGPUVertexFormat_Uint32x2, .offset = 0, .shaderLocation = 0 },
        .{ .format = c.WGPUVertexFormat_Uint32x2, .offset = 8, .shaderLocation = 1 },
        .{ .format = c.WGPUVertexFormat_Uint32x2, .offset = 16, .shaderLocation = 2 },
        .{ .format = c.WGPUVertexFormat_Uint32, .offset = 24, .shaderLocation = 3 },
    };
}

fn blendAttributes() [8]c.WGPUVertexAttribute {
    return .{
        .{ .format = c.WGPUVertexFormat_Uint32, .offset = 0, .shaderLocation = 0 },
        .{ .format = c.WGPUVertexFormat_Uint32, .offset = 4, .shaderLocation = 1 },
        .{ .format = c.WGPUVertexFormat_Uint32, .offset = 8, .shaderLocation = 2 },
        .{ .format = c.WGPUVertexFormat_Uint32, .offset = 12, .shaderLocation = 3 },
        .{ .format = c.WGPUVertexFormat_Uint32, .offset = 16, .shaderLocation = 4 },
        .{ .format = c.WGPUVertexFormat_Uint32, .offset = 20, .shaderLocation = 5 },
        .{ .format = c.WGPUVertexFormat_Uint32, .offset = 24, .shaderLocation = 6 },
        .{ .format = c.WGPUVertexFormat_Uint32, .offset = 28, .shaderLocation = 7 },
    };
}

fn copyAttributes() [4]c.WGPUVertexAttribute {
    return .{
        .{ .format = c.WGPUVertexFormat_Uint32, .offset = 0, .shaderLocation = 0 },
        .{ .format = c.WGPUVertexFormat_Uint32, .offset = 4, .shaderLocation = 1 },
        .{ .format = c.WGPUVertexFormat_Uint32, .offset = 8, .shaderLocation = 2 },
        .{ .format = c.WGPUVertexFormat_Uint32, .offset = 12, .shaderLocation = 3 },
    };
}

fn createStripPipeline(
    dev: *device.Device,
    layout: c.WGPUPipelineLayout,
    module: c.WGPUShaderModule,
    format: c.WGPUTextureFormat,
    blend: ?*const c.WGPUBlendState,
    depth: ?*const c.WGPUDepthStencilState,
    label: []const u8,
) Error!c.WGPURenderPipeline {
    const attributes = stripAttributes();
    var vertex_buffer = c.wgpu_zig_init_WGPUVertexBufferLayout();
    vertex_buffer.arrayStride = @sizeOf(common.GpuStrip);
    vertex_buffer.stepMode = c.WGPUVertexStepMode_Instance;
    vertex_buffer.attributeCount = attributes.len;
    vertex_buffer.attributes = &attributes;
    return createRenderPipeline(dev, layout, module, format, blend, depth, &.{vertex_buffer}, label);
}

fn createClearPipeline(
    dev: *device.Device,
    layout: c.WGPUPipelineLayout,
    module: c.WGPUShaderModule,
    format: c.WGPUTextureFormat,
    vs_entry: [:0]const u8,
    fs_entry: [:0]const u8,
    with_vertex_buffer: bool,
    label: []const u8,
) Error!c.WGPURenderPipeline {
    const attributes = clearAttributes();
    var vertex_buffer = c.wgpu_zig_init_WGPUVertexBufferLayout();
    vertex_buffer.arrayStride = @sizeOf(common.GpuClearInstance);
    vertex_buffer.stepMode = c.WGPUVertexStepMode_Instance;
    vertex_buffer.attributeCount = attributes.len;
    vertex_buffer.attributes = &attributes;
    const buffers: []const c.WGPUVertexBufferLayout = if (with_vertex_buffer) &.{vertex_buffer} else &.{};
    return createRenderPipelineEntry(
        dev,
        layout,
        module,
        format,
        null,
        null,
        buffers,
        vs_entry,
        fs_entry,
        label,
    );
}

fn createTextureOpPipeline(
    dev: *device.Device,
    layout: c.WGPUPipelineLayout,
    module: c.WGPUShaderModule,
    vertex_buffer: ?*const c.WGPUVertexBufferLayout,
    label: []const u8,
) Error!c.WGPURenderPipeline {
    const buffers: []const c.WGPUVertexBufferLayout = if (vertex_buffer) |buffer| &.{buffer.*} else &.{};
    return createRenderPipeline(
        dev,
        layout,
        module,
        c.WGPUTextureFormat_RGBA8Unorm,
        null,
        null,
        buffers,
        label,
    );
}

fn createRenderPipeline(
    dev: *device.Device,
    layout: c.WGPUPipelineLayout,
    module: c.WGPUShaderModule,
    format: c.WGPUTextureFormat,
    blend: ?*const c.WGPUBlendState,
    depth: ?*const c.WGPUDepthStencilState,
    buffers: []const c.WGPUVertexBufferLayout,
    label: []const u8,
) Error!c.WGPURenderPipeline {
    return createRenderPipelineEntry(dev, layout, module, format, blend, depth, buffers, "vs_main", "fs_main", label);
}

fn createRenderPipelineEntry(
    dev: *device.Device,
    layout: c.WGPUPipelineLayout,
    module: c.WGPUShaderModule,
    format: c.WGPUTextureFormat,
    blend: ?*const c.WGPUBlendState,
    depth: ?*const c.WGPUDepthStencilState,
    buffers: []const c.WGPUVertexBufferLayout,
    vs_entry: [:0]const u8,
    fs_entry: [:0]const u8,
    label: []const u8,
) Error!c.WGPURenderPipeline {
    var color_target = c.wgpu_zig_init_WGPUColorTargetState();
    color_target.format = format;
    color_target.blend = blend;
    color_target.writeMask = c.WGPUColorWriteMask_All;

    var fragment = c.wgpu_zig_init_WGPUFragmentState();
    fragment.module = module;
    fragment.entryPoint = wgpu.stringViewZ(fs_entry);
    fragment.targetCount = 1;
    fragment.targets = &color_target;

    var primitive = c.wgpu_zig_init_WGPUPrimitiveState();
    primitive.topology = c.WGPUPrimitiveTopology_TriangleStrip;

    var desc = c.wgpu_zig_init_WGPURenderPipelineDescriptor();
    desc.label = wgpu.stringView(label);
    desc.layout = layout;
    desc.vertex = .{
        .module = module,
        .entryPoint = wgpu.stringViewZ(vs_entry),
        .bufferCount = buffers.len,
        .buffers = if (buffers.len == 0) null else buffers.ptr,
    };
    desc.primitive = primitive;
    desc.multisample = c.wgpu_zig_init_WGPUMultisampleState();
    desc.fragment = &fragment;
    var depth_state: c.WGPUDepthStencilState = undefined;
    if (depth) |state| {
        depth_state = state.*;
        desc.depthStencil = &depth_state;
    } else {
        desc.depthStencil = null;
    }
    return c.wgpuDeviceCreateRenderPipeline(dev.handle, &desc) orelse error.PipelineCreationFailed;
}

/// A filtering sampler for filter input and gradient LUT sampling.
pub fn createFilterLinearSampler(dev: *device.Device) Error!c.WGPUSampler {
    var desc = c.wgpu_zig_init_WGPUSamplerDescriptor();
    desc.label = wgpu.stringView("vellz-filter-linear-sampler");
    desc.magFilter = c.WGPUFilterMode_Linear;
    desc.minFilter = c.WGPUFilterMode_Linear;
    return c.wgpuDeviceCreateSampler(dev.handle, &desc) orelse error.BindGroupCreationFailed;
}

// ---------------------------------------------------------------------------
// Buffers, textures, and uploads
// ---------------------------------------------------------------------------

/// Create a buffer with the given size and usage.
pub fn createBuffer(
    dev: *device.Device,
    size: u64,
    usage: c.WGPUBufferUsage,
    label: []const u8,
) Error!c.WGPUBuffer {
    var desc = c.wgpu_zig_init_WGPUBufferDescriptor();
    desc.label = wgpu.stringView(label);
    desc.size = size;
    desc.usage = usage;
    return c.wgpuDeviceCreateBuffer(dev.handle, &desc) orelse error.BufferCreationFailed;
}

/// Build the `Config` uniform value for a target size and resource texture
/// width. `resource_texture_dimension_2d` must be a power of two (the shaders
/// mask and shift alpha/paint texel indices by its log2).
pub fn configForSize(width: u32, height: u32, resource_texture_dimension_2d: u32) common.Config {
    std.debug.assert(std.math.isPowerOfTwo(resource_texture_dimension_2d));
    const bits = @ctz(resource_texture_dimension_2d);
    return .{
        .width = width,
        .height = height,
        .strip_height = common_util.TILE_HEIGHT,
        .alphas_tex_width_bits = bits,
        .encoded_paints_tex_width_bits = bits,
        .strip_offset_x = 0,
        .strip_offset_y = 0,
        .negate_ndc = 0,
    };
}

/// Create a `Config` uniform buffer initialized for the given target size.
pub fn createConfigBuffer(
    dev: *device.Device,
    width: u32,
    height: u32,
    resource_texture_dimension_2d: u32,
    label: []const u8,
) Error!c.WGPUBuffer {
    const buffer = try createBuffer(
        dev,
        @sizeOf(common.Config),
        c.WGPUBufferUsage_Uniform | c.WGPUBufferUsage_CopyDst,
        label,
    );
    errdefer c.wgpuBufferRelease(buffer);
    const config = configForSize(width, height, resource_texture_dimension_2d);
    c.wgpuQueueWriteBuffer(dev.queue, buffer, 0, &config, @sizeOf(common.Config));
    return buffer;
}

/// Create a `Rgba32Uint` texture used for alpha coverage or encoded paint
/// data.
pub fn createRgba32UintTexture(
    dev: *device.Device,
    width: u32,
    height: u32,
    label: []const u8,
) Error!c.WGPUTexture {
    return createTexture2d(
        dev,
        width,
        height,
        c.WGPUTextureFormat_RGBA32Uint,
        c.WGPUTextureUsage_TextureBinding | c.WGPUTextureUsage_CopyDst,
        label,
    );
}

/// Create a 1x1 `Rgba8Unorm` texture view used for unbound texture slots
/// (placeholder external/child-layer/gradient bindings).
pub fn createPlaceholderTextureView(dev: *device.Device, label: []const u8) Error!c.WGPUTextureView {
    const texture = try createTexture2d(
        dev,
        1,
        1,
        c.WGPUTextureFormat_RGBA8Unorm,
        c.WGPUTextureUsage_TextureBinding | c.WGPUTextureUsage_CopyDst,
        label,
    );
    defer c.wgpuTextureRelease(texture);
    return createFullView(texture, c.WGPUTextureFormat_RGBA8Unorm, label);
}

/// Upload tightly packed `Rgba32Uint` texel data to `texture`.
///
/// `bytes` is `width * height * 16` bytes (one texel per row is *not* implied:
/// rows are `width` texels wide). Rows are padded to
/// `COPY_BYTES_PER_ROW_ALIGNMENT` (256 bytes) because some backends require it;
/// the padded rows are copied through a temporary staging buffer that is
/// released before returning.
pub fn writeRgba32Uint(
    dev: *device.Device,
    texture: c.WGPUTexture,
    bytes: []const u8,
    width: u32,
    height: u32,
) Error!void {
    if (width == 0 or height == 0) return error.TextureTooLarge;
    const row_bytes: usize = @as(usize, width) * 16;
    const expected = row_bytes * height;
    if (bytes.len < expected) return error.Unsupported;

    const aligned_row: usize = std.mem.alignForward(usize, row_bytes, COPY_BYTES_PER_ROW_ALIGNMENT);

    var dest = c.wgpu_zig_init_WGPUTexelCopyTextureInfo();
    dest.texture = texture;
    dest.mipLevel = 0;
    dest.origin = .{ .x = 0, .y = 0, .z = 0 };
    dest.aspect = c.WGPUTextureAspect_All;

    var layout = c.wgpu_zig_init_WGPUTexelCopyBufferLayout();
    layout.offset = 0;
    layout.bytesPerRow = @intCast(aligned_row);
    layout.rowsPerImage = height;

    var size = c.WGPUExtent3D{ .width = width, .height = height, .depthOrArrayLayers = 1 };

    if (aligned_row == row_bytes) {
        c.wgpuQueueWriteTexture(dev.queue, &dest, bytes.ptr, expected, &layout, &size);
        return;
    }

    // Pad each row to the alignment. One extra row of padding is unnecessary:
    // the last row's tail is only read up to `bytesPerRow`.
    const staging = dev.allocator.alloc(u8, aligned_row * height) catch return error.OutOfMemory;
    defer dev.allocator.free(staging);
    @memset(staging, 0);
    for (0..height) |row| {
        @memcpy(
            staging[row * aligned_row ..][0..row_bytes],
            bytes[row * row_bytes ..][0..row_bytes],
        );
    }
    c.wgpuQueueWriteTexture(dev.queue, &dest, staging.ptr, staging.len, &layout, &size);
}

/// Upload tightly packed `Rgba8Unorm` pixel data with 256-byte-aligned rows.
pub fn writeRgba8(
    dev: *device.Device,
    texture: c.WGPUTexture,
    bytes: []const u8,
    width: u32,
    height: u32,
) Error!void {
    if (width == 0 or height == 0) return error.TextureTooLarge;
    const row_bytes: usize = @as(usize, width) * 4;
    const expected = row_bytes * height;
    if (bytes.len < expected) return error.Unsupported;
    const aligned_row: usize = std.mem.alignForward(usize, row_bytes, COPY_BYTES_PER_ROW_ALIGNMENT);

    var dest = c.wgpu_zig_init_WGPUTexelCopyTextureInfo();
    dest.texture = texture;
    dest.mipLevel = 0;
    dest.origin = .{ .x = 0, .y = 0, .z = 0 };
    dest.aspect = c.WGPUTextureAspect_All;

    var layout = c.wgpu_zig_init_WGPUTexelCopyBufferLayout();
    layout.offset = 0;
    layout.bytesPerRow = @intCast(aligned_row);
    layout.rowsPerImage = height;

    var size = c.WGPUExtent3D{ .width = width, .height = height, .depthOrArrayLayers = 1 };

    if (aligned_row == row_bytes) {
        c.wgpuQueueWriteTexture(dev.queue, &dest, bytes.ptr, expected, &layout, &size);
        return;
    }
    const staging = dev.allocator.alloc(u8, aligned_row * height) catch return error.OutOfMemory;
    defer dev.allocator.free(staging);
    @memset(staging, 0);
    for (0..height) |row| {
        @memcpy(
            staging[row * aligned_row ..][0..row_bytes],
            bytes[row * row_bytes ..][0..row_bytes],
        );
    }
    c.wgpuQueueWriteTexture(dev.queue, &dest, staging.ptr, staging.len, &layout, &size);
}

// ---------------------------------------------------------------------------
// Bind groups
// ---------------------------------------------------------------------------

fn createBindGroup(
    dev: *device.Device,
    layout: c.WGPUBindGroupLayout,
    label: []const u8,
    entries: []const c.WGPUBindGroupEntry,
) Error!c.WGPUBindGroup {
    var desc = c.wgpu_zig_init_WGPUBindGroupDescriptor();
    desc.label = wgpu.stringView(label);
    desc.layout = layout;
    desc.entryCount = entries.len;
    desc.entries = if (entries.len == 0) null else entries.ptr;
    return c.wgpuDeviceCreateBindGroup(dev.handle, &desc) orelse error.BindGroupCreationFailed;
}

fn textureBindEntry(binding: u32, view: c.WGPUTextureView) c.WGPUBindGroupEntry {
    var entry = c.wgpu_zig_init_WGPUBindGroupEntry();
    entry.binding = binding;
    entry.textureView = view;
    return entry;
}

/// Render group 0: alphas + `Config` uniform + child-layer texture.
pub fn createStripBindGroup(
    dev: *device.Device,
    layout: c.WGPUBindGroupLayout,
    alphas_view: c.WGPUTextureView,
    config_buffer: c.WGPUBuffer,
    child_layer_view: c.WGPUTextureView,
) Error!c.WGPUBindGroup {
    var config_entry = c.wgpu_zig_init_WGPUBindGroupEntry();
    config_entry.binding = 1;
    config_entry.buffer = config_buffer;
    config_entry.offset = 0;
    config_entry.size = @sizeOf(common.Config);
    const entries = [_]c.WGPUBindGroupEntry{
        textureBindEntry(0, alphas_view),
        config_entry,
        textureBindEntry(2, child_layer_view),
    };
    return createBindGroup(dev, layout, "vellz-strip-bind-group", &entries);
}

/// Render group 1: four external textures.
pub fn createExternalTextureBindGroup(
    dev: *device.Device,
    layout: c.WGPUBindGroupLayout,
    views: [4]c.WGPUTextureView,
) Error!c.WGPUBindGroup {
    const entries = [_]c.WGPUBindGroupEntry{
        textureBindEntry(0, views[0]),
        textureBindEntry(1, views[1]),
        textureBindEntry(2, views[2]),
        textureBindEntry(3, views[3]),
    };
    return createBindGroup(dev, layout, "vellz-external-bind-group", &entries);
}

/// Render group 2: encoded paints.
pub fn createEncodedPaintsBindGroup(
    dev: *device.Device,
    layout: c.WGPUBindGroupLayout,
    view: c.WGPUTextureView,
) Error!c.WGPUBindGroup {
    const entries = [_]c.WGPUBindGroupEntry{textureBindEntry(0, view)};
    return createBindGroup(dev, layout, "vellz-encoded-paints-bind-group", &entries);
}

/// Render group 3: gradient LUT.
pub fn createGradientBindGroup(
    dev: *device.Device,
    layout: c.WGPUBindGroupLayout,
    view: c.WGPUTextureView,
) Error!c.WGPUBindGroup {
    const entries = [_]c.WGPUBindGroupEntry{textureBindEntry(0, view)};
    return createBindGroup(dev, layout, "vellz-gradient-bind-group", &entries);
}

// ---------------------------------------------------------------------------
// Clear passes
// ---------------------------------------------------------------------------

/// The rect-clear render pipeline (upstream `clear_pipeline` /
/// `root_clear_pipeline`).
pub const ClearPipeline = struct {
    pipeline: c.WGPURenderPipeline,
    format: c.WGPUTextureFormat,

    pub fn create(dev: *device.Device, format: c.WGPUTextureFormat, label: []const u8) Error!ClearPipeline {
        const module = try createShaderModule(dev, shaders.CLEAR, label);
        defer c.wgpuShaderModuleRelease(module);

        var layout_desc = c.wgpu_zig_init_WGPUPipelineLayoutDescriptor();
        layout_desc.label = wgpu.stringView("vellz-gpu-clear-layout");
        const layout = c.wgpuDeviceCreatePipelineLayout(dev.handle, &layout_desc) orelse {
            return error.PipelineCreationFailed;
        };
        defer c.wgpuPipelineLayoutRelease(layout);

        const attributes = clearAttributes();
        var vertex_buffer = c.wgpu_zig_init_WGPUVertexBufferLayout();
        vertex_buffer.arrayStride = @sizeOf(common.GpuClearInstance);
        vertex_buffer.stepMode = c.WGPUVertexStepMode_Instance;
        vertex_buffer.attributeCount = attributes.len;
        vertex_buffer.attributes = &attributes;

        var color_target = c.wgpu_zig_init_WGPUColorTargetState();
        color_target.format = format;
        color_target.writeMask = c.WGPUColorWriteMask_All;

        var fragment = c.wgpu_zig_init_WGPUFragmentState();
        fragment.module = module;
        fragment.entryPoint = wgpu.stringView("fs_main");
        fragment.targetCount = 1;
        fragment.targets = &color_target;

        var primitive = c.wgpu_zig_init_WGPUPrimitiveState();
        primitive.topology = c.WGPUPrimitiveTopology_TriangleStrip;

        var desc = c.wgpu_zig_init_WGPURenderPipelineDescriptor();
        desc.label = wgpu.stringView(label);
        desc.layout = layout;
        desc.vertex = .{
            .module = module,
            .entryPoint = wgpu.stringView("vs_main"),
            .bufferCount = 1,
            .buffers = &vertex_buffer,
        };
        desc.primitive = primitive;
        desc.multisample = c.wgpu_zig_init_WGPUMultisampleState();
        desc.fragment = &fragment;

        const pipeline = c.wgpuDeviceCreateRenderPipeline(dev.handle, &desc) orelse {
            return error.PipelineCreationFailed;
        };
        return .{ .pipeline = pipeline, .format = format };
    }

    pub fn deinit(self: *ClearPipeline) void {
        c.wgpuRenderPipelineRelease(self.pipeline);
        self.* = undefined;
    }
};

/// Clear rectangles of a `format`-matching texture view with a list of
/// `GpuClearInstance` values, using the checked-in clear WGSL.
///
/// Mirrors upstream `clear_pass_inner`: the instances are uploaded to a
/// vertex buffer, the pass loads (preserves) the target, and each instance
/// draws a 4-vertex triangle strip.
pub fn clearTexture(
    dev: *device.Device,
    view: c.WGPUTextureView,
    texture_format: c.WGPUTextureFormat,
    pipeline: *const ClearPipeline,
    instances: []const common.GpuClearInstance,
) Error!void {
    if (instances.len == 0) return;
    if (pipeline.format != texture_format) return error.UnsupportedCapability;
    if (dev.isLost()) return error.DeviceLost;

    dev.pushErrorScope(c.WGPUErrorFilter_Validation);
    var scope_open = true;
    errdefer if (scope_open) {
        _ = dev.popErrorScope() catch {};
    };

    const instance_bytes: u64 = @as(u64, @sizeOf(common.GpuClearInstance)) * instances.len;
    const buffer = try createBuffer(
        dev,
        instance_bytes,
        c.WGPUBufferUsage_Vertex | c.WGPUBufferUsage_CopyDst,
        "vellz-gpu-clear-instances",
    );
    defer c.wgpuBufferRelease(buffer);
    c.wgpuQueueWriteBuffer(dev.queue, buffer, 0, instances.ptr, @intCast(instance_bytes));

    var encoder_desc = c.wgpu_zig_init_WGPUCommandEncoderDescriptor();
    encoder_desc.label = wgpu.stringView("vellz-gpu-clear-encoder");
    const encoder = c.wgpuDeviceCreateCommandEncoder(dev.handle, &encoder_desc) orelse {
        return error.CommandEncodingFailed;
    };
    defer c.wgpuCommandEncoderRelease(encoder);

    var color_attachment = c.wgpu_zig_init_WGPURenderPassColorAttachment();
    color_attachment.view = view;
    color_attachment.depthSlice = c.WGPU_DEPTH_SLICE_UNDEFINED;
    color_attachment.loadOp = c.WGPULoadOp_Load;
    color_attachment.storeOp = c.WGPUStoreOp_Store;
    color_attachment.clearValue = .{ .r = 0.0, .g = 0.0, .b = 0.0, .a = 0.0 };

    var pass_desc = c.wgpu_zig_init_WGPURenderPassDescriptor();
    pass_desc.label = wgpu.stringView("vellz-gpu-clear-pass");
    pass_desc.colorAttachmentCount = 1;
    pass_desc.colorAttachments = &color_attachment;
    const pass = c.wgpuCommandEncoderBeginRenderPass(encoder, &pass_desc) orelse {
        return error.RenderPassFailed;
    };
    c.wgpuRenderPassEncoderSetPipeline(pass, pipeline.pipeline);
    c.wgpuRenderPassEncoderSetVertexBuffer(pass, 0, buffer, 0, c.WGPU_WHOLE_SIZE);
    c.wgpuRenderPassEncoderDraw(pass, 4, @intCast(instances.len), 0, 0);
    c.wgpuRenderPassEncoderEnd(pass);
    c.wgpuRenderPassEncoderRelease(pass);

    var command_desc = c.wgpu_zig_init_WGPUCommandBufferDescriptor();
    command_desc.label = wgpu.stringView("vellz-gpu-clear-commands");
    const command_buffer = c.wgpuCommandEncoderFinish(encoder, &command_desc) orelse {
        return error.CommandEncodingFailed;
    };
    defer c.wgpuCommandBufferRelease(command_buffer);
    c.wgpuQueueSubmit(dev.queue, 1, &command_buffer);

    const scope_result = dev.popErrorScope();
    scope_open = false;
    try scope_result;
}

// ---------------------------------------------------------------------------
// Strip pass
// ---------------------------------------------------------------------------

/// Everything `stripPass` needs to encode one root draw pass.
pub const StripPass = struct {
    /// Color target.
    view: c.WGPUTextureView,
    /// Depth target (`Depth24Plus`, same extents as `view`), if enabled.
    depth_view: ?c.WGPUTextureView = null,
    /// Whether the depth buffer still has to be cleared to 1.0 this frame.
    clear_depth: bool = false,
    /// Color load op.
    load_op: c.WGPULoadOp = c.WGPULoadOp_Load,
    /// Clear value used when `load_op` is `Clear`.
    clear_value: c.WGPUColor = .{ .r = 0, .g = 0, .b = 0, .a = 0 },
    /// Opaque strips (drawn first with the opaque pipeline).
    opaque_strips: []const common.GpuStrip = &.{},
    /// Alpha strips selected by the sibling draw's ranges.
    alpha_strips: []const common.GpuStrip = &.{},
    /// Target is the user surface (enables the alpha/depth-alpha selection).
    is_root: bool = true,
    /// Bind groups for groups 0–3.
    strip_bind_group: c.WGPUBindGroup,
    external_bind_group: c.WGPUBindGroup,
    encoded_paints_bind_group: c.WGPUBindGroup,
    gradient_bind_group: c.WGPUBindGroup,
    /// Pipelines to select from.
    pipelines: *const Pipelines,
};

/// Encode one strip render pass (opaque then alpha strips), uploading the
/// instances into a fresh vertex buffer and releasing it before returning.
pub fn stripPass(
    dev: *device.Device,
    encoder: c.WGPUCommandEncoder,
    options: StripPass,
) Error!void {
    if (dev.isLost()) return error.DeviceLost;
    const opaque_count = options.opaque_strips.len;
    const alpha_count = options.alpha_strips.len;
    if (opaque_count == 0 and alpha_count == 0) return;

    const instance_count = opaque_count + alpha_count;
    const bytes = @as(u64, @sizeOf(common.GpuStrip)) * instance_count;
    const buffer = try createBuffer(
        dev,
        bytes,
        c.WGPUBufferUsage_Vertex | c.WGPUBufferUsage_CopyDst,
        "vellz-strip-instances",
    );
    defer c.wgpuBufferRelease(buffer);
    if (opaque_count > 0) {
        c.wgpuQueueWriteBuffer(
            dev.queue,
            buffer,
            0,
            options.opaque_strips.ptr,
            @intCast(@as(u64, @sizeOf(common.GpuStrip)) * opaque_count),
        );
    }
    if (alpha_count > 0) {
        c.wgpuQueueWriteBuffer(
            dev.queue,
            buffer,
            @intCast(@as(u64, @sizeOf(common.GpuStrip)) * opaque_count),
            options.alpha_strips.ptr,
            @intCast(@as(u64, @sizeOf(common.GpuStrip)) * alpha_count),
        );
    }

    var color_attachment = c.wgpu_zig_init_WGPURenderPassColorAttachment();
    color_attachment.view = options.view;
    color_attachment.depthSlice = c.WGPU_DEPTH_SLICE_UNDEFINED;
    color_attachment.loadOp = options.load_op;
    color_attachment.storeOp = c.WGPUStoreOp_Store;
    color_attachment.clearValue = options.clear_value;

    var depth_attachment = c.wgpu_zig_init_WGPURenderPassDepthStencilAttachment();
    var depth_storage: ?c.WGPURenderPassDepthStencilAttachment = null;
    if (options.depth_view) |depth_view| {
        depth_attachment.view = depth_view;
        depth_attachment.depthLoadOp = if (options.clear_depth) c.WGPULoadOp_Clear else c.WGPULoadOp_Load;
        depth_attachment.depthStoreOp = c.WGPUStoreOp_Store;
        depth_attachment.depthClearValue = 1.0;
        depth_attachment.depthReadOnly = 0;
        depth_storage = depth_attachment;
    }

    var pass_desc = c.wgpu_zig_init_WGPURenderPassDescriptor();
    pass_desc.label = wgpu.stringView("vellz-strip-pass");
    pass_desc.colorAttachmentCount = 1;
    pass_desc.colorAttachments = &color_attachment;
    pass_desc.depthStencilAttachment = if (depth_storage) |*attachment| attachment else null;

    const pass = c.wgpuCommandEncoderBeginRenderPass(encoder, &pass_desc) orelse {
        return error.RenderPassFailed;
    };
    defer c.wgpuRenderPassEncoderRelease(pass);

    c.wgpuRenderPassEncoderSetBindGroup(pass, 0, options.strip_bind_group, 0, null);
    c.wgpuRenderPassEncoderSetBindGroup(pass, 1, options.external_bind_group, 0, null);
    c.wgpuRenderPassEncoderSetBindGroup(pass, 2, options.encoded_paints_bind_group, 0, null);
    c.wgpuRenderPassEncoderSetBindGroup(pass, 3, options.gradient_bind_group, 0, null);
    c.wgpuRenderPassEncoderSetVertexBuffer(pass, 0, buffer, 0, c.WGPU_WHOLE_SIZE);

    if (opaque_count > 0) {
        c.wgpuRenderPassEncoderSetPipeline(pass, options.pipelines.opaque_strip);
        c.wgpuRenderPassEncoderDraw(pass, 4, @intCast(opaque_count), 0, 0);
    }
    if (alpha_count > 0) {
        const pipeline = if (options.is_root and options.depth_view != null)
            options.pipelines.depth_alpha_strip
        else if (options.is_root)
            options.pipelines.alpha_strip
        else
            options.pipelines.intermediate_strip;
        c.wgpuRenderPassEncoderSetPipeline(pass, pipeline);
        c.wgpuRenderPassEncoderDraw(pass, 4, @intCast(alpha_count), 0, @intCast(opaque_count));
    }
    c.wgpuRenderPassEncoderEnd(pass);
}

/// Encode a load-op clear of the full target (upstream `clear_full_target`).
pub fn clearFullTarget(
    dev: *device.Device,
    encoder: c.WGPUCommandEncoder,
    view: c.WGPUTextureView,
    color: c.WGPUColor,
) Error!void {
    if (dev.isLost()) return error.DeviceLost;
    var attachment = c.wgpu_zig_init_WGPURenderPassColorAttachment();
    attachment.view = view;
    attachment.depthSlice = c.WGPU_DEPTH_SLICE_UNDEFINED;
    attachment.loadOp = c.WGPULoadOp_Clear;
    attachment.storeOp = c.WGPUStoreOp_Store;
    attachment.clearValue = color;

    var desc = c.wgpu_zig_init_WGPURenderPassDescriptor();
    desc.label = wgpu.stringView("vellz-clear-target");
    desc.colorAttachmentCount = 1;
    desc.colorAttachments = &attachment;
    const pass = c.wgpuCommandEncoderBeginRenderPass(encoder, &desc) orelse {
        return error.RenderPassFailed;
    };
    c.wgpuRenderPassEncoderEnd(pass);
    c.wgpuRenderPassEncoderRelease(pass);
}

/// Encode the rect-list clear pass into an existing encoder (used by targets
/// that need a partial clear; the root path uses the load-op clear instead).
pub fn clearPass(
    dev: *device.Device,
    encoder: c.WGPUCommandEncoder,
    view: c.WGPUTextureView,
    pipeline: *const ClearPipeline,
    instances: []const common.GpuClearInstance,
) Error!void {
    if (instances.len == 0) return;
    if (dev.isLost()) return error.DeviceLost;

    const bytes = @as(u64, @sizeOf(common.GpuClearInstance)) * instances.len;
    const buffer = try createBuffer(
        dev,
        bytes,
        c.WGPUBufferUsage_Vertex | c.WGPUBufferUsage_CopyDst,
        "vellz-clear-instances",
    );
    defer c.wgpuBufferRelease(buffer);
    c.wgpuQueueWriteBuffer(dev.queue, buffer, 0, instances.ptr, @intCast(bytes));

    var attachment = c.wgpu_zig_init_WGPURenderPassColorAttachment();
    attachment.view = view;
    attachment.depthSlice = c.WGPU_DEPTH_SLICE_UNDEFINED;
    attachment.loadOp = c.WGPULoadOp_Load;
    attachment.storeOp = c.WGPUStoreOp_Store;

    var desc = c.wgpu_zig_init_WGPURenderPassDescriptor();
    desc.label = wgpu.stringView("vellz-clear-rects");
    desc.colorAttachmentCount = 1;
    desc.colorAttachments = &attachment;
    const pass = c.wgpuCommandEncoderBeginRenderPass(encoder, &desc) orelse {
        return error.RenderPassFailed;
    };
    defer c.wgpuRenderPassEncoderRelease(pass);
    c.wgpuRenderPassEncoderSetPipeline(pass, pipeline.pipeline);
    c.wgpuRenderPassEncoderSetVertexBuffer(pass, 0, buffer, 0, c.WGPU_WHOLE_SIZE);
    c.wgpuRenderPassEncoderDraw(pass, 4, @intCast(instances.len), 0, 0);
    c.wgpuRenderPassEncoderEnd(pass);
}

// ---------------------------------------------------------------------------
// Layout assertions (run under `-Dgpu=true test`)
// ---------------------------------------------------------------------------

test "vertex attribute layouts match the shader contract" {
    const strip = stripAttributes();
    try std.testing.expectEqual(@as(usize, 6), strip.len);
    for (strip, 0..) |attribute, i| {
        try std.testing.expectEqual(@as(u32, @intCast(i * 4)), attribute.offset);
        try std.testing.expectEqual(@as(u32, @intCast(c.WGPUVertexFormat_Uint32)), @as(u32, @intCast(attribute.format)));
    }

    const clear = clearAttributes();
    try std.testing.expectEqual(@as(u32, 0), clear[0].offset);
    try std.testing.expectEqual(@as(u32, 8), clear[1].offset);
    try std.testing.expectEqual(@as(u32, 16), clear[2].offset);
    try std.testing.expectEqual(@as(u32, 24), clear[3].offset);
    try std.testing.expectEqual(@sizeOf(common.GpuClearInstance), 28);

    const blend = blendAttributes();
    try std.testing.expectEqual(@as(usize, 8), blend.len);
    try std.testing.expectEqual(@sizeOf(common.GpuBlendInstance), 32);

    const copy = copyAttributes();
    try std.testing.expectEqual(@as(usize, 4), copy.len);
    try std.testing.expectEqual(@sizeOf(common.GpuCopyInstance), 16);

    const filter = filterInstanceAttributes();
    try std.testing.expectEqual(@as(usize, 9), filter.len);
    try std.testing.expectEqual(@sizeOf(filter_mod.FilterInstanceData), 36);
}

test "config buffer contents match the strip contract" {
    const config = configForSize(64, 64, 4096);
    try std.testing.expectEqual(@as(u32, 64), config.width);
    try std.testing.expectEqual(@as(u32, 64), config.height);
    try std.testing.expectEqual(@as(u32, common_util.TILE_HEIGHT), config.strip_height);
    try std.testing.expectEqual(@as(u32, 12), config.alphas_tex_width_bits);
    try std.testing.expectEqual(@as(u32, 12), config.encoded_paints_tex_width_bits);
    try std.testing.expectEqual(@as(u32, 0), config.negate_ndc);
    try std.testing.expectEqual(@as(usize, 32), @sizeOf(common.Config));
}

test "write texture row alignment helper" {
    try std.testing.expectEqual(@as(u32, 256), COPY_BYTES_PER_ROW_ALIGNMENT);
    // One 16-byte Rgba32Uint texel row is padded to a full alignment unit.
    try std.testing.expectEqual(
        @as(usize, 256),
        std.mem.alignForward(usize, 1 * 16, COPY_BYTES_PER_ROW_ALIGNMENT),
    );
    // A 4096-wide texel row is already aligned (4096 * 16 = 65536).
    try std.testing.expectEqual(
        @as(usize, 65536),
        std.mem.alignForward(usize, 4096 * 16, COPY_BYTES_PER_ROW_ALIGNMENT),
    );
}
