# GPU compatibility gate — Vello GPU (Rust wgpu 29.0.3) → `.ports/wgpu` (wgpu-native v29.0.1.1)

Status of this document: **complete for the pinned revision's library surface**
(`vello_gpu` minus its `webgl` feature and examples). Every wgpu operation,
feature, limit, resource format, and shader capability used by the pinned
`vello_gpu` has been inventoried and mapped to the C API exposed by the sibling
Zig package. No unrecorded gaps remain; the substitutions that are required are
listed below and are implementable through the existing package.

Pinned inputs:

| Component | Revision |
| --- | --- |
| vello | `1e63b4a40ccb484f82e1d85b83df97ab95bcfbe7` |
| vello_gpu / vello_common | 0.2.0 |
| Rust wgpu / naga | 29.0.3 |
| wgpu-native | `v29.0.1.1`, commit `6aed50955d934ac36049ba8d002034841633ae02` |
| wgpu-native internal wgpu-core/naga/wgpu-types | **29.0.3** |

**The key de-risking fact:** the pinned wgpu-native checkout's own `Cargo.lock`
resolves `wgpu-core`, `wgpu-types`, and `naga` to 29.0.3 — the same versions
Rust wgpu 29.0.3 uses. The C layer is a translation over the same core, so
differences are API *shape*, not rendering semantics.

## 1. Operations used by vello_gpu and their C mapping

Legend: **direct** = same concept and semantics; **reshaped** = same capability,
different descriptor/name shape; **substitute** = no C equivalent, documented
replacement required; **unused** = Rust-side sugar the port does not need.

### Device and resources

| Vello use | Rust wgpu | C API (pinned) | Status |
| --- | --- | --- | --- |
| read max texture dimension | `device.limits().max_texture_dimension_2d` | `wgpuDeviceGetLimits` → `WGPULimits.maxTextureDimension2D` | direct |
| depth texture (24-bit) | `create_texture(Depth24Plus, RENDER_ATTACHMENT)` | `wgpuDeviceCreateTexture` (`WGPUTextureFormat_Depth24Plus`) | direct |
| intermediate layer/scratch textures | `Rgba8Unorm`, `TEXTURE_BINDING\|RENDER_ATTACHMENT` | same | direct |
| alpha strip texture | `Rgba32Uint`, `TEXTURE_BINDING\|COPY_DST` | same, sampled as `Uint` | direct |
| image atlas pages | `Rgba8Unorm`, `TEXTURE_BINDING\|COPY_DST\|COPY_SRC\|RENDER_ATTACHMENT` | same | direct |
| filter-data texture | `Rgba32Uint`, `TEXTURE_BINDING\|COPY_DST` | same | direct |
| encoded-paints texture | `Rgba32Uint`, `TEXTURE_BINDING\|COPY_DST` | same | direct |
| gradient LUT texture | `Rgba8Unorm`, `TEXTURE_BINDING\|COPY_DST` | same | direct |
| placeholder external texture | `Rgba8Unorm` 1×1, `TEXTURE_BINDING` | same | direct |
| strip/config/instance buffers | `VERTEX`/`UNIFORM` + `COPY_DST` | `WGPUBufferUsage_*` | direct |
| create buffer with initial data | `DeviceExt::create_buffer_init` | — | **substitute:** `wgpuDeviceCreateBuffer` + `wgpuQueueWriteBuffer` (or `mappedAtCreation`) |
| update config/strips per pass | `Queue::write_buffer_with` (mapped staging) | — | **substitute:** reusable `MAP_WRITE` buffer + `wgpuBufferGetMappedRange`/`wgpuBufferWriteMappedRange`, or `wgpuQueueWriteBuffer`; measure before optimizing |

### Pipelines, layouts, bind groups

| Vello use | Rust wgpu | C API | Status |
| --- | --- | --- | --- |
| 10 render pipelines, triangle-strip, 4-vertex instanced draws | `create_render_pipeline` | `wgpuDeviceCreateRenderPipeline` | reshaped (split vertex/fragment/primitive/depth/multisample states) |
| premultiplied alpha blending | `BlendState::PREMULTIPLIED_ALPHA_BLENDING` | explicit `WGPUBlendState` (src=one, dst=one-minus-src-alpha, add) | reshaped |
| depth test for opaque strips | `DepthStencilState{ Depth24Plus, write, LessEqual }` | `WGPUDepthStencilState` (`depthWriteEnabled` is `WGPUOptionalBool`) | reshaped |
| 10 bind group layouts | `create_bind_group_layout` | `wgpuDeviceCreateBindGroupLayout` | reshaped: `BindingType` splits into buffer/sampler/texture/storageTexture sub-structs; `Float{filterable:false}` → `UnfilterableFloat` |
| bind groups | `create_bind_group` | `wgpuDeviceCreateBindGroup` / `WGPUBindGroupEntry` | reshaped (`WGPU_WHOLE_SIZE` for whole buffers) |
| pipeline layout, no push constants | `immediate_size: 0` | `WGPUPipelineLayoutDescriptor.immediateSize = 0` | direct |
| WGSL shader modules | `ShaderSource::Wgsl` | `WGPUShaderSourceWGSL` chained via `WGPUChainedStruct` | reshaped |
| filtering sampler | `create_sampler(Linear, Linear)` | `wgpuDeviceCreateSampler`; defaults via init shim | direct |
| compilation options / pipeline cache / multiview mask | `PipelineCompilationOptions`, `cache`, `multiview_mask` | absent | **unused by Vello**; no substitute needed |

### Passes and commands

| Vello use | Rust wgpu | C API | Status |
| --- | --- | --- | --- |
| command encoder | `create_command_encoder` | `wgpuDeviceCreateCommandEncoder` | direct |
| 8 render-pass sites, 1 color attachment each, optional depth | `begin_render_pass` | `wgpuCommandEncoderBeginRenderPass` / `WGPURenderPassEncoder` | reshaped (explicit `End` + `Release`; loads/stores split from values) |
| `Load`/`Clear`, `Store` | `LoadOp`/`StoreOp` | `WGPULoadOp_*`/`WGPUStoreOp_*` + `clearValue` | reshaped |
| set pipeline/bind groups/vertex buffer, scissor | pass encoder methods | same | direct |
| instanced draw of the fullscreen quad | `draw(0..4, instances)` | `wgpuRenderPassEncoderDraw(4, n, 0, first)` | direct |
| texture-to-texture copy | `copy_texture_to_texture` | `wgpuCommandEncoderCopyTextureToTexture` | direct |
| texture uploads (6 sites) | `Queue::write_texture` | `wgpuQueueWriteTexture` | direct (`WGPU_COPY_STRIDE_UNDEFINED` for absent strides) |
| submit | `queue.submit` | `wgpuQueueSubmit` | direct |
| finish encoder | `finish` | `wgpuCommandEncoderFinish` | direct |

### Capabilities deliberately unused by vello_gpu (verified)

No storage buffers, no compute passes in the renderer, no push constants, no
indirect draws, no timestamp/occlusion queries, no MSAA (sample count 1), no
mipmaps, no array/cube views, no `DownlevelFlags`/format-feature queries, no
device feature requests (`Features::empty()` in the examples).

## 2. Required substitutions (all implementable through `.ports/wgpu`)

1. **`DeviceExt::create_buffer_init`** — create + `wgpuQueueWriteBuffer`, or
   `mappedAtCreation`. No API addition needed.
2. **`Queue::write_buffer_with`** — Vello writes strip instances through a
   mapped staging belt for throughput. The C API has no staging belt; use a
   persistent `MAP_WRITE|COPY_SRC` buffer or `wgpuQueueWriteBuffer`. This is an
   operational difference to measure, not a rendering difference.
3. **`TextureView::texture()` feedback-loop check** — the C API has no view→
   texture getter. Vellz must track `WGPUTexture` identity alongside views in
   its `TextureBindings` equivalent and reject binding a view whose texture is
   the current render target.
4. **Descriptor defaults** — always use the generated `wgpu_zig_init_WGPU*`
   helpers from the sibling package instead of zeroing; several defaults
   (`mipLevelCount=1`, `sampleCount=1`, `WGPU_WHOLE_SIZE`, sampler LOD clamp)
   are not zero-equivalent.
5. **Ownership** — explicit `wgpu*Release`/`wgpu*Destroy`, pass `End`, and
   command-buffer release; the async request callbacks are synchronous in this
   pin, buffer mapping is driven by `wgpuDevicePoll(device, true, null)`.
6. **WGSL source distribution** — upstream compiles WESL at build time via
   `vello_gpu_shaders` (naga 29.0.3). The C side accepts the resulting WGSL
   directly; vellz will check in the compiled WGSL (with provenance and a
   regeneration script) rather than adding a WESL compiler.

## 3. Binding additions to `.ports/wgpu`

None required for the operation inventory above. The package already exposes
every needed function, type, enum, and init shim. If a binding addition becomes
necessary during Milestone 5, it must be (a) minimal, (b) justified in a note
in `.ports/wgpu/README.md`, and (c) not duplicated locally in vellz.

## 4. Verification obligations for Milestone 5

- Host/shader struct layouts must be asserted in Zig (`@sizeOf`, `@offsetOf`)
  against the WGSL `struct` declarations and upstream `Gpu*` `repr(C, align(16))`
  sizes.
- Texture formats/usages and pipeline formats must be checked against the table
  above at creation time; a mismatch fails loudly.
- Offscreen rendering must not require native window creation (`Renderer`
  already takes caller-owned `WGPUDevice`/`WGPUQueue`/`WGPUCommandEncoder`).
- Device loss and unsupported capabilities surface as typed errors; no silent
  CPU fallback.
