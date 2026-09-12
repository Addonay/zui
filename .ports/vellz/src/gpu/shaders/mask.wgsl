// Hand-written WGSL for the M5 mask-layer adapt (not part of the pinned
// upstream vello_gpu_shaders set; upstream has no mask sampling path).
//
// Multiplies a rendered layer region by an alpha/luminance mask into the
// shared scratch texture. The caller then copies the region back into the
// layer texture (copy.wgsl) before compositing the layer:
//
//   layer texture --(this shader, scratch)--> copy pass --> layer texture
//
// The mask sampler is nearest (textureLoad), matching the CPU
// `SampledMaskIter`: mask sample coordinates are scene pixel coordinates, and
// out-of-mask samples are transparent black.

struct VertexOut {
    @builtin(position) position: vec4<f32>,
    @location(0) local: vec2<f32>,
    @location(1) @interpolate(flat) source_origin: u32,
    @location(2) @interpolate(flat) scene_origin: u32,
    @location(3) @interpolate(flat) mask_size: u32,
};

struct Instance {
    @location(0) @interpolate(flat) geometry_origin: u32,
    @location(1) @interpolate(flat) geometry_size: u32,
    @location(2) @interpolate(flat) source_origin: u32,
    @location(3) @interpolate(flat) scene_origin: u32,
    @location(4) @interpolate(flat) mask_size: u32,
    @location(5) @interpolate(flat) texture_size: u32,
};

fn unpack_u16_pair(packed: u32) -> vec2<u32> {
    return vec2<u32>(packed & 0xFFFFu, packed >> 16u);
}

@group(0) @binding(0) var source_texture: texture_2d<f32>;
@group(0) @binding(1) var mask_texture: texture_2d<f32>;

@vertex
fn vs_main(@builtin(vertex_index) vertex_index: u32, instance: Instance) -> VertexOut {
    var out: VertexOut;
    let corner = vec2<f32>(f32(vertex_index & 1u), f32((vertex_index >> 1u) & 1u));
    let origin = unpack_u16_pair(instance.geometry_origin);
    let size = unpack_u16_pair(instance.geometry_size);
    let texture_size = unpack_u16_pair(instance.texture_size);
    let dst = vec2<f32>(f32(origin.x), f32(origin.y)) + corner * vec2<f32>(f32(size.x), f32(size.y));
    let ndc = vec2<f32>(
        (dst.x * 2.0) / f32(texture_size.x) - 1.0,
        1.0 - (dst.y * 2.0) / f32(texture_size.y),
    );
    out.position = vec4<f32>(ndc, 0.0, 1.0);
    out.local = corner * vec2<f32>(f32(size.x), f32(size.y));
    out.source_origin = instance.source_origin;
    out.scene_origin = instance.scene_origin;
    out.mask_size = instance.mask_size;
    return out;
}

@fragment
fn fs_main(in: VertexOut) -> @location(0) vec4<f32> {
    let local = vec2<i32>(in.local);
    let source_origin = unpack_u16_pair(in.source_origin);
    let scene_origin = unpack_u16_pair(in.scene_origin);
    let mask_size = unpack_u16_pair(in.mask_size);

    let sample = textureLoad(source_texture, vec2<i32>(source_origin) + local, 0);

    let mask_coord = vec2<i32>(scene_origin) + local;
    var mask_value = 0.0;
    if (mask_coord.x >= 0 && mask_coord.y >= 0 &&
        mask_coord.x < i32(mask_size.x) && mask_coord.y < i32(mask_size.y)) {
        mask_value = textureLoad(mask_texture, mask_coord, 0).r;
    }

    return sample * mask_value;
}
