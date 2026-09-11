# Shader-to-host interface map — `vello_gpu_shaders` → `vellz.gpu`

Pinned upstream: `linebender/vello` @ `1e63b4a40ccb484f82e1d85b83df97ab95bcfbe7`
(`vello_gpu_shaders` 0.2.0, `vello_gpu` 0.2.0; naga 29.0.3). This document is
the contract the Zig GPU backend must honor byte-for-byte before any shader is
rewritten.

## 1. Shader compilation and distribution

Upstream authors WESL (`vello_gpu_shaders/shaders/*.wesl`), links imports at
build time (wesl 0.4.0), minifies through naga, and embeds five WGSL strings:

| Module | Entry points | Purpose |
| --- | --- | --- |
| `render` | `vs_main`, `fs_main` | sparse-strip fill/alpha/opaque/deep renders |
| `clear` | `vs_main`, `vs_main_fullscreen`, `fs_main`, `fs_transparent` | rect and atlas-region clears |
| `copy` | `vs_main`, `fs_main` | texture-region copy |
| `blend` | `vs_main`, `fs_main` | layer compositing (Porter-Duff + blend modes) |
| `filter` | `vs_main`, `fs_main` | offset/flood/gaussian blur/drop shadow executor |

No compute shaders, workgroups, subgroups, f16, or dual-source blending exist
anywhere in these sources. The WebGL branch compiles the same sources to GLSL
ES 3.00 via naga; it is out of scope for vellz.

Distribution decision: vellz checks the **compiled WGSL** into
`src/gpu/shaders/generated.zig` with provenance and a regeneration script that
runs `cargo run -p vello_gpu_shaders` against the pinned checkout. We do not
add a WESL toolchain to the Zig build.

## 2. Bind groups

| Shader | Group | Binding | Type | Visibility |
| --- | --- | --- | --- | --- |
| render | 0 | 0 | `texture_2d<u32>` (`alphas_texture`) | fragment |
| render | 0 | 1 | uniform `Config` | vertex + fragment |
| render | 0 | 2 | `texture_2d<f32>` unfilterable (`layer_input_texture`) | fragment |
| render | 1 | 0..3 | `texture_2d<f32>` unfilterable (`external_texture_0..3`) | fragment |
| render | 2 | 0 | `texture_2d<u32>` (`encoded_paints_texture`) | vertex + fragment |
| render | 3 | 0 | `texture_2d<f32>` filterable (`gradient_texture`) | fragment |
| filter | 0 | 0 | `texture_2d<u32>` (`filter_data`) | fragment |
| filter | 1 | 0 | `texture_2d<f32>` filterable (`source_texture`) | fragment |
| filter | 1 | 1 | filtering sampler (`linear_sampler`) | fragment |
| filter | 2 | 0 | `texture_2d<f32>` filterable (`original_texture`) | fragment |
| blend | 0 | 0,1 | `texture_2d<f32>` unfilterable (`layer_texture_0/1`) | fragment |
| blend | 0 | 2 | `texture_2d<u32>` (`alphas_texture`) | fragment |
| copy | 0 | 0 | `texture_2d<f32>` unfilterable (`source_texture`) | fragment |
| clear | — | none | | |

`UnfilterableFloat` is the C-side name for Rust
`TextureSampleType::Float { filterable: false }`.

## 3. Vertex buffer layouts (all triangle-strip, instanced)

Stride and attributes must match exactly; the C API uses `WGPUVertexFormat_*`:

| Pipeline | Stride | Attributes (shader location: format) |
| --- | --- | --- |
| render / strip | 24 | 0:Uint32, 1:Uint32, 2:Uint32, 3:Uint32, 4:Uint32, 5:Uint32 |
| clear | 28 | 0:Uint32x2, 1:Uint32x2, 2:Uint32x2, 3:Uint32 |
| filter | 36 | 0..8: Uint32 |
| blend | 32 | 0..7: Uint32 |
| copy | 16 | 0..3: Uint32 |

## 4. Host structs (byte layouts)

All are `#[repr(C)]`/`align(16)` upstream and must be asserted with
`@sizeOf`/`@offsetOf` in Zig.

### `Config` (uniform, 32 bytes)

| Offset | Field | Type |
| --- | --- | --- |
| 0 | width | u32 |
| 4 | height | u32 |
| 8 | strip_height | u32 |
| 12 | alphas_tex_width_bits | u32 |
| 16 | encoded_paints_tex_width_bits | u32 |
| 20 | strip_offset_x | i32 |
| 24 | strip_offset_y | i32 |
| 28 | negate_ndc | u32 |

Shader `Config` field names: `width`, `height`, `strip_height`,
`alphas_tex_width_bits`, `encoded_paints_tex_width_bits`, `strip_offset_x`,
`strip_offset_y`, `nc_y_negate`.

### `GpuStrip` (24 bytes)

| Offset | Field | Type |
| --- | --- | --- |
| 0 | x | u16 |
| 2 | y | u16 |
| 4 | width | u16 |
| 6 | dense_width_or_rect_height | u16 |
| 8 | col_idx_or_rect_frac | u32 |
| 12 | payload | u32 |
| 16 | paint_and_rect_flag | u32 |
| 20 | depth_index | u32 |

`paint_and_rect_flag` bits: 31 `RECT_STRIP_FLAG`; 29–30 color source
(0 payload, 1 layer); 26–28 paint type (0 solid, 1 image, 2 linear, 3 radial,
4 sweep, 5 blurred rounded rect); 0–23 paint texture index; 24–25 external
texture slot. Layer color source stores opacity in bits 0–7.

### `GpuClearInstance` (28 bytes)

`origin [u32;2]`, `size [u32;2]`, `target_size [u32;2]`, `color u32`.

### `GpuCopyInstance` (16 bytes)

`dest_texture_origin`, `source_texture_origin`, `copy_rect_size`,
`dest_texture_size`, each a packed u16 pair (`x | y << 16`).

### `GpuBlendInstance` (32 bytes)

`geometry_origin`, `geometry_size`, `geometry_alpha_col_idx`,
`parent_texture_size`, `child_texture_origin`, `child_parent_origin`,
`child_rect_size`, `blend_config`.

`blend_config` bits: 0–7 compose (Porter-Duff 0–13), 8–15 mix (0–15),
16–23 opacity, 24 parent parity, 25 child parity, 26 has-alpha.

### `FilterInstanceData` (36 bytes)

`source_origin`, `source_size`, `dest_origin`, `dest_size`,
`dest_texture_size`, `filter_data_offset`, `original_origin`, `original_size`,
`filter_pass_kind` — all u32.

Filter parameter blocks are exactly 48 bytes (3 RGBA32Uint texels):

- `GpuOffset`: `header, dx, dy, _padding[9]`
- `GpuFlood`: `header, color, _padding[10]`
- `GpuGaussianBlur`: `header, center_weight, linear_weights[3], linear_offsets[3], _padding[4]`
- `GpuDropShadow`: `header, center_weight, linear_weights[3], linear_offsets[3], dx, dy, color, _padding[1]`

Header bits: 0–3 filter type (0 offset, 1 flood, 2 gaussian, 3 drop shadow),
5–6 edge mode (0 duplicate, 1 wrap, 2 mirror, 3 none), 7–10 decimations,
11–12 linear taps, bit 13 composite-original. `FILTER_ATLAS_PADDING = 6`
(`MAX_KERNEL_SIZE = 13` / 2). Filter pass kinds: 0 copy, 1 flood, 2 offset,
3 downscale, 4 blur-H, 5 blur-V, 6 upscale, 7 composite drop shadow,
8 colorize.

### Encoded paint structs (all `align(16)`; stride = size/16 texels)

| Struct | Size | Fields in order |
| --- | --- | --- |
| `GpuEncodedImage` | 48 | `image_params u32, image_size u32, image_offset u32, transform [f32;6], tint u32, tint_mode u32, image_padding u32` |
| `GpuLinearGradient` | 32 | `texture_width_and_extend_mode u32, gradient_start u32, transform [f32;6]` |
| `GpuRadialGradient` | 64 | linear prefix + `kind_and_f_is_swapped u32, bias f32, scale f32, fp0 f32, fp1 f32, fr1 f32, f_focal_x f32, scaled_r0_squared f32` |
| `GpuSweepGradient` | 48 | linear prefix + `start_angle f32, inv_angle_delta f32, _padding [u32;2]` |
| `GpuBlurredRoundedRect` | 80 | `transform [f32;6], color u32, invert u32, params0 [f32;4], params1 [f32;4], size [f32;2], _padding1 [u32;2]` |

Packing helpers to replicate: `pack_image_size(w,h) = w << 16 | h`,
`pack_image_offset(x,y) = x << 16 | y`,
`pack_image_params(quality, extend_x, extend_y) = extend_y << 4 | extend_x << 2 | quality`,
`pack_texture_width_and_extend_mode(width, extend)` (extend in bits 30–31),
`pack_radial_kind_and_swapped`, `pack_tint` (premultiplied RGBA8 u32,
`u32::MAX` = no tint).

## 5. Pipeline state

All pipelines: `TriangleStrip`, multisample count 1, no blend except the strip
pipelines, depth only for the root opaque/depth-alpha variant.

| Pipeline | Target format | Blend | Depth |
| --- | --- | --- | --- |
| intermediate strip | Rgba8Unorm | premultiplied alpha | no |
| alpha strip | target format | premultiplied alpha | no |
| depth alpha strip | target format | premultiplied alpha | Depth24Plus, LessEqual, write off |
| opaque strip | target format | none | Depth24Plus, LessEqual, write on |
| filter / blend / copy / clear | Rgba8Unorm | none | no |
| root clear | target format | none | no |
| atlas clear | Rgba8Unorm | none | no |

Depth value: `z = 1.0 - f32(depth_index) / 2^24`; depth cleared to 1.0 once per
frame.

## 6. Resource formats

`Rgba8Unorm` (intermediates, atlases, gradient LUT, placeholder),
`Rgba32Uint` (alpha strips, encoded paints, filter data; sampled as `Uint`),
`Depth24Plus`, and a caller-chosen target format (examples use `Rgba8Unorm` or
`Bgra8Unorm`). All core WebGPU formats; no optional capabilities are requested
by the library (`Features::empty()`, only `max_texture_dimension_2d` is read).

## 7. Verification checklist for Milestone 5

1. `@sizeOf`/`@offsetOf` assertions for every struct in §4 against the WGSL
   declarations (shader structs are minified; use the pinned unminified sources
   for reading and the byte offsets recorded here).
2. Bind group layout fidelity per §2, including sample types.
3. Vertex attribute formats/strides per §3.
4. Pipeline target formats, blend factors, depth state per §5.
5. Constant equality: `NEARLY_ZERO_TOLERANCE = 1/4096`, `FILTER_SIZE_BYTES = 48`,
   `FILTER_ATLAS_PADDING = 6`, `MAX_KERNEL_SIZE = 13`, tile height 4.
6. `textureLoad` vs sampling semantics: alphas/paints/filter data use
   `textureLoad` (no filtering); only the filter input sampler and gradient
   texture filter.
