# vellz port plan

Status vocabulary, used consistently in this file and in code comments:

| Term | Meaning |
| --- | --- |
| `port` | Rust logic transcribed into Zig, compiles, unit-tested. |
| `connected` | Reachable from the public API and exercised in the real pipeline. |
| `oracle-verified` | Output compared against the pinned upstream oracle on shared fixtures with recorded metrics. |
| `adapted` | Deliberate divergence from upstream (documented, measured separately). |
| `deferred` | Scoped but not yet implemented; explicit error, never placeholder pixels. |
| `unsupported` | Out of scope by decision; documented as such. |

A file existing is not progress. Only `connected` + `oracle-verified` counts as
parity.

## 1. Upstream baseline

- Repository: <https://github.com/linebender/vello>
- Revision: `1e63b4a40ccb484f82e1d85b83df97ab95bcfbe7` (`v0.10.0-51-g1e63b4a4`, 2026-09-11)
- Crates in scope:
  - `vello_common` 0.2.0 — shared geometry, path encoding, tiling, strips, paints.
  - `vello_cpu` 0.2.0 — sparse-strip CPU renderer (u8 and f32 pipelines, multithreading, filters, text).
  - `vello_gpu` 0.2.0 — hybrid GPU renderer (CPU strip preprocessing + GPU rasterization/compositing).
  - `vello_gpu_shaders` 0.2.0 — WGSL/WESL shader sources and host-shader contracts.
  - `glifo` 0.3.0 — glyph outline/bitmap/COLR handling used by `vello_cpu` (feature `text`).
- Explicitly out of scope: `research/` (`vello_research`, `vello_encoding`, `vello_shaders`,
  the winit examples) — the older compute-centric renderer. `vello_toy`/`vello_tests`
  are used as oracle tooling only, not ported.
- Key Rust dependency versions (workspace root `Cargo.toml`): wgpu 29.0.3,
  naga 29.0.3, peniko 0.6.1, kurbo 0.13.1, skrifa 0.44.0, fearless_simd 0.7.0,
  guillotiere 0.7.0, smallvec 1.15.1, rayon 1.12.0.
- Tested Zig: `0.17.0-dev.2085+5e36170b5` on Linux x86_64.
- Sibling GPU package: `.ports/wgpu`, wgpu-native `v29.0.1.1`
  (`6aed50955d934ac36049ba8d002034841633ae02`). Note the version skew against
  Rust wgpu 29.0.3; see §7.

### Reconstruction commands

```sh
# 1. Pinned upstream checkout (ignored by git, never distributed).
tools/fetch-reference.sh

# 2. Build the upstream oracle binaries (CPU, headless).
cd .reference/vello
cargo build --release -p vello_toy        # `debug` and `svg` stage/PNG tools

# 3. Build our own scene-corpus oracle driver (renders the shared corpus with
#    the pinned vello_cpu at fixed settings).
cd ../../../tools/oracle-rs && cargo build --release
```

The exact revision is enforced by `tools/fetch-reference.sh` and recorded in
`tools/pin.env` and `build.zig` (`pins`).

## 2. Scope

Deliverables:

1. **CPU renderer** producing premultiplied RGBA8 pixels in memory
   (`vellz.cpu`), with a scalar reference path and SIMD paths.
2. **Hybrid GPU renderer** (`vellz.gpu`): CPU path/geometry preprocessing
   (flattening, tiling, strip generation) followed by actual GPU execution of
   the upstream pipeline through `.ports/wgpu`. Uploading a fully CPU-rasterized
   frame is not the hybrid backend.
3. **Shared semantics and algorithms** (`vellz.common`) used by both backends:
   one canonical geometry, color, paint, path, tile, and strip representation.
4. **Glyph rendering** via a port of `glifo`, plus a narrow optional Cozmic
   adapter that consumes already-positioned glyphs and never reshapes/relayouts.
5. **Examples, oracle tooling, fixtures, and this plan** kept current.

Non-goals for the first pass:

- Window/event integration inside the library (examples may use platform glue).
- The `research/` compute renderer, its encoding pipeline, or its shading model.
- WebGL/WebGPU-targeted variants of `vello_gpu` (`render/webgl`, wasm builds).
- `pico_svg` and other debug-only upstream features unless the oracle corpus
  needs them (the upstream `probe` fixture is imported; see §12).

## 3. Architecture and dependency graph

```text
        .ports/wgpu (wgpu module, wgpu-native v29.0.1.1)
                        ^
                        |  optional, only with -Dgpu=true
  +---------------------+----------------------+
  |                                            |
vellz.gpu (vello_gpu port)              vellz.gpu_shaders (WGSL + host layouts)
  |          \                                 |
  |           \--> GPU execution of             |
  |                uploads, passes, readback    |
  v                                            v
vellz.common <----------------------- vellz.cpu (vello_cpu port)
  |   geometry, paths, paints, tiles, strips, pixmaps,
  |   render state, masks, filters, atlas/image cache
  |
  +--> vellz.kurbo   (geometry subset of kurbo 0.13.1)
  +--> vellz.peniko  (color/blend/gradient/image subset of peniko 0.6.1)
  +--> vellz.simd    (fearless_simd equivalent dispatch)
  +--> vellz.glifo   (glyph outlines, bitmaps, COLR, atlas)
```

Dependency direction is fixed:

- `vellz.gpu -> vellz.common` and `vellz.gpu -> wgpu` package.
- `vellz.cpu -> vellz.common` (+ `vellz.glifo` when text is enabled).
- `wgpu` never depends on vellz.
- Cozmic is never a dependency of the rendering core. The adapter in
  `src/cozmic_adapter.zig` (compiled only by examples/tests that opt in) maps
  Cozmic's positioned output onto the renderer's glyph contract.

No module re-imports wgpu headers or defines its own GPU handles/descriptors;
all GPU types come from the `wgpu` module. No module defines a second copy of a
shared type (see §4).

## 4. Canonical type ownership

Single owners; every other module imports them:

| Concept | Owner (Zig) | Upstream counterpart |
| --- | --- | --- |
| Point/Vec2/Affine/Rect/RoundedRect | `src/kurbo/` | kurbo 0.13.1 |
| BezPath/PathEl/PathSeg/Shape | `src/kurbo/` | kurbo 0.13.1 |
| Stroke/Cap/Join/Dash | `src/kurbo/` | kurbo 0.13.1 |
| Color/AlphaColor/PremulColor/palette | `src/peniko/color.zig` | peniko 0.6.1 |
| Gradient/ColorStops/Extend | `src/peniko/gradient.zig` | peniko 0.6.1 |
| Image/ImageFormat/ImageAlphaType | `src/peniko/image.zig` | peniko 0.6.1 |
| BlendMode/Mix/Compose/Fill | `src/peniko/blend.zig` | peniko 0.6.1 |
| Paint/PaintType/Tint/ImageSource | `src/common/paint.zig` | vello_common::paint |
| RenderState/Transforms | `src/common/render_state.zig`, `src/common/transforms.zig` | vello_common |
| Path encoding (`Path`, verbs) | `src/common/encode.zig` | vello_common::encode |
| Tiles/Strips/Segments/Cmds | `src/common/tile.zig`, `src/common/strip.zig` | vello_common |
| Pixmap/Pixels/PixelMetadata | `src/common/pixmap.zig` | vello_common::pixmap |
| Mask/Clip/render target | `src/common/mask.zig`, `src/common/target.zig` | vello_common |
| `RenderContext`/settings/resources | `src/cpu/render.zig` | vello_cpu::render |
| GPU renderer + resources | `src/gpu/` | vello_gpu |
| Glyph types/FontData contract | `src/glifo/` | glifo |

Allocator contract: every owner type is explicit about borrowed vs owned data;
`*_init(allocator, ...)`/`deinit()` pairs, no hidden global allocators, no
allocation in `deinit`. Owned slices are `[]T` allocated from the passed
allocator; borrowed data uses slices and documented lifetimes. See §9.

## 5. Source-to-Zig coverage ledger

Filled in as ports land. `not-started` modules are listed so coverage is
falsifiable rather than implied.

Status: `n/s` not started · `port` transcribed+tested · `conn` connected to the
public pipeline · `ver` oracle-verified · `adapt` deliberate divergence ·
`defer` explicit error · `unsup` out of scope.

### `vello_common` → `src/common/`

| Upstream module | Zig target | Status | Notes |
| --- | --- | --- | --- |
| `lib.rs` (`TextureId`, `reexports`) | `common/root.zig` | n/s | |
| `geometry.rs` (`SizeU16`, `PaddingU16`, `RectU16`) | `common/geometry.zig` | n/s | integer types only; no Point/Affine here |
| `math.rs` (`FloatExt`, `compute_erf7`, `snap_up`) | `common/math.zig` | n/s | `NEARLY_ZERO = 1/4096` must match shaders |
| `simd.rs` (`Splat4thExt`, `element_wise_splat`) | `common/simd.zig` | n/s | over `src/simd` |
| `util.rs` (`f32_to_u8`, pools, `strip_bbox`, `unpremultiply`) | `common/util.zig` | n/s | `Div255Ext`, `Pool`/`VecPool`/`RetainVec` |
| `flatten.rs` + `flatten_simd.rs` | `common/flatten.zig` | port | scalar transcription of the SIMD operation order; oracle-verified (13 targeted + 160 random paths, 13,508 lines, zero f32-bit diffs); `stroke` wired to the kurbo port |
| `tile.rs` (`Tile` 4×4, `Tiles`, analytic AA + MSAA) | `common/tile.zig` | port | 65 tests (all 60 upstream ported); oracle-verified (160 random line sets, zero diffs incl. winding bookkeeping) |
| `strip.rs` (`Strip`, segments, `render`) | `common/strip.zig` | port | byte-identical differential vs upstream over 15 scenes/15 rects; adds `stripBbox`; 1259 LOC |
| `strip_generator.rs` | `common/strip_generator.zig` | port | 16 tests (13 upstream); cycle split with `strip_storage.zig` |
| `rect.rs` (fast pixel-aligned rect) | `common/rect.zig` | port | upstream tests ported |
| `clip.rs` (`ClipState`, `PathDataRef`, `intersect`) | `common/clip.zig`, `common/intersect.zig` | port | 22 tests (13 upstream); cycle split documented in docs/cpu-pipeline.md |
| `viewport.rs` (`ViewportState`) | `common/viewport.zig` | port | 3 tests; not connected until cpu/render lands |
| `paint.rs` (`Paint`, `IndexedPaint`, `Tint`, ...) | `common/paint.zig` | port | connected; indexed (gradient/image) paints oracle-verified via the corpus; `PaintType = peniko Brush` |
| `encode.rs` (gradients/images/BRR encoding + LUTs) | `common/encode.zig` | port | connected; gradient/image encoding + LUTs oracle-verified (4 gradient + 2 image scenes byte-exact); BRR encoding deferred (M2-later) |
| `render_state.rs` | `common/render_state.zig` | port | 2 tests |
| `transforms.rs` | `common/transforms.zig` | port | connected; 5 tests |
| `pixmap.rs` (`Pixmap`, `PixmapMut`, premultiply) | `common/pixmap.zig` | port | connected (CPU targets, image assets); RGBA8 premultiplied sRGB |
| `mask.rs` | `common/mask.zig` | port | Shared(MaskRepr); 6 tests |
| `record.rs` (layers/commands) | `common/record.zig` | port | 18 tests (11 upstream), transactional OOM-safe pushes |
| `filter_effects.rs` + `filter/mod.rs` | `common/filter_effects.zig`, `common/filter.zig` | port | connected; `PreparedFilter` payloads (flood, gaussian blur, offset, drop shadow) oracle-verified; 22+ tests |
| `blurred_rounded_rect.rs` | `common/blurred_rounded_rect.zig` | port | 1 test; encode + painter connected and oracle-verified (normal/inverted scenes) |
| `image_cache.rs`, `multi_atlas.rs` (guillotiere) | `common/atlas.zig` | defer | M3 (glyph atlas), M2 (images) |
| `target.rs` (`TargetInit`) | `common/target.zig` | port | 1 test; connected via `RasterizerSettings` |
| `probe.rs` | `common/probe.zig`, `cpu/probe.zig` | port (oracle/dev only) | Scene, grid layout, and upstream tolerance-3 comparison policy ported; embedded pinned `tests/fixtures/upstream/probe.rgba`; connected via `vellz.cpu.probe`/`vellz-cli --probe`; oracle-verified byte-exact (51×51, four channels, max diff 0) |
| `pico_svg.rs` | — | defer | Dev-only SVG loader |

### `vello_cpu` → `src/cpu/`

| Upstream module | Zig target | Status | Notes |
| --- | --- | --- | --- |
| `lib.rs` (exports, `RenderMode`) | `cpu/root.zig` | port | connected; f32 pipeline (`optimize_quality`) |
| `render.rs` (`RenderContext`, settings, Resources) | `cpu/render.zig`, `cpu/settings.zig` | port | connected; solid/indexed paints + masks (`setMask`/`resetMask`/`pushMaskLayer`), layers (clip/opacity/blend), image registry; gradient/image encoding oracle-verified |
| `record.rs` (`RecordedFill`) | `cpu/record.zig` | port | connected; `bbox` waits on filter work |
| `region.rs` (`Region`, `Regions`) | `cpu/region.zig` | port | 4 tests |
| `coarse/cmd.rs` | `cpu/coarse/cmd.zig` | port | 4 tests |
| `coarse/depth.rs` | `cpu/coarse/depth.zig` | port | 10 tests, 128-px buckets |
| `coarse/bucketer.rs` | `cpu/coarse/bucketer.zig` | port | full `bucketCommands` (fills, layers, depth, alpha segments) |
| `fine/mod.rs` (`Fine`, `rasterize_region`, traits) | `cpu/fine/mod.zig` | port | connected; error-returning per port policy; painter selection dispatches on `K.Numeric` |
| `fine/highp/*` (f32 kernel) | `cpu/fine/highp/mod.zig`, `blend.zig`, `compose.zig` | port | connected; 16 mix + 14 compose modes |
| `fine/lowp/*` (u8 kernel) | `cpu/fine/lowp/mod.zig`, `blend.zig`, `compose.zig`, `gradient.zig`, `image.zig` | port + conn + ver | connected via `optimize_speed`; scalar u8 fast paths + f32 fallback for the remaining mix modes; oracle-verified (16 speed scenes byte-exact vs pinned oracle) |
| `fine/common/gradient/*` | `cpu/fine/gradient.zig` | port | connected; oracle-verified (linear/radial/sweep/repeat scenes byte-exact) |
| `fine/common/image.rs` | `cpu/fine/image.zig` | port | connected; oracle-verified (nearest/bilinear scenes byte-exact) |
| `dispatch/single_threaded.rs` | `cpu/dispatch/single_threaded.zig` | port | connected; comptime kernel selection (`optimize_speed` -> u8, `optimize_quality` -> f32), mirroring upstream with both pipelines enabled |
| `dispatch/mod.rs` (`Dispatcher`, selection) | `cpu/dispatch/mod.zig` | port | connected; vtable + `num_threads` selection |
| `dispatch/multi_threaded*.rs` | `cpu/dispatch/multi_threaded.zig` + `multi_threaded/{task,cost,worker,sync}.zig` | conn | f32 MT byte-identical to ST on the differential scene (`render.zig`); u8/filters `error.Unsupported`; corpus stays threads=0 |
| `filter/*` | `cpu/filter/*.zig` | port | connected; oracle-verified (8 filter scenes byte-exact); highp uses upstream's lowp blur/drop-shadow internals; multi-primitive graphs -> `error.Unsupported` |
| `fine/common/rounded_blurred_rect.rs` | `cpu/fine/blurred_rect.zig` | port | connected; oracle-verified (normal + inverted scenes byte-exact) |
| `text.rs`, `text_debug.rs` | `cpu/text.zig` | defer | M3 |
| `util.rs` (`Span`, `div255`, `Premultiply`) | `cpu/util.zig` | port | 6 tests |

### `vello_gpu` → `src/gpu/`

| Upstream area | Zig target | Status | Notes |
| --- | --- | --- | --- |
| `render/common.rs` (Config, GpuStrip, clear/encoded paint structs, packing) | `gpu/render/common.zig` | port | 8 layout/packing tests run in the default `zig build test`; comptime `@sizeOf`/`@offsetOf` asserts match `docs/shader-interface.md` §4 |
| `render/wgpu/mod.rs` (device bootstrap/readback/clear subset) | `gpu/backend/{device,wgpu,readback}.zig` | partial | T1: instance/adapter/device/queue, error scopes, uncaptured/device-lost capture, limits, adapter-info printing, checked-in clear WGSL pipeline, texture readback; `run-gpu-smoke` passes offscreen on lavapipe (all handles released, zero validation errors) |
| `render/wgpu/mod.rs` (Programs, passes, resources) | `gpu/render/wgpu.zig` | defer | M5 T3–T5 |
| `draw.rs`, `scene.rs` | `gpu/draw.zig`, `gpu/scene.zig` | defer | M5 |
| `schedule/*`, `target.rs` | `gpu/schedule.zig`, `gpu/target.zig` | defer | M5 |
| `util.rs` (packing subset) | `gpu/util.zig` | partial | `pack_u16_pair`/`pack_opacity` landed; `Ranges`/`RangedSlice` with the schedule |
| `copy.rs` | `gpu/copy.zig` | partial | `GpuCopyInstance` (16 B) + packing test |
| `blend.rs` | `gpu/blend.zig` | partial | `GpuBlendInstance` (32 B) + `blend_config` bit packing; `new`/`copy_from_scratch` need the schedule |
| `filter.rs` (layout subset) | `gpu/filter.zig` | partial | 48-byte blocks, `FilterInstanceData` (36 B), header/pass-kind constants; `PreparedFilter` conversions and the pass planner follow |
| `paint.rs`, `rect.rs` | `gpu/paint.zig`, `gpu/rect.zig` | defer | M5 |
| `gradient_cache.rs` | `gpu/gradient_cache.zig` | defer | M5 |
| `resources.rs`, `text.rs` | `gpu/resources.zig`, `gpu/text.zig` | defer | M5/M3 |
| `render/webgl/*` | — | unsup | WebGL out of scope |
| WGSL shaders | `gpu/shaders/generated.zig` | port | checked-in compiled WGSL; `clear.wgsl` drives the offscreen smoke |

### `glifo` → `src/glifo/`

| Upstream module | Zig target | Status | Notes |
| --- | --- | --- | --- |
| `lib.rs`, `interface.rs` (Glyph, DrawSink, GlyphRenderer) | `glifo/root.zig`, `glifo/interface.zig` | defer | M3 |
| `glyph.rs` (GlyphRun, hints, transforms) | `glifo/glyph.zig` | defer | M3 |
| `renderer.rs` (atlas-first drawing) | `glifo/renderer.zig` | defer | M3 |
| `colr.rs` (COLR/CPAL painting) | `glifo/colr.zig` | defer | M3 |
| `atlas/*` (cache, keys, regions, commands) | `glifo/atlas/*.zig` | defer | M3 |
| `util.rs` | `glifo/util.zig` | defer | M3 |

### Ported dependency sources (`kurbo`, `color`, `peniko`)

| Upstream | Zig | Status |
| --- | --- | --- |
| kurbo `point/vec2/affine/rect/size/insets/bezpath/line/circle/common/cubicbez/quadbez/svg` | `src/kurbo/*` | port (7,166 LOC, 84 tests; 68 probed values bit-identical to Rust kurbo 0.13.1) |
| kurbo `stroke.rs` (`Stroke`, `StrokeOpts`, `StrokeCtx`, `stroke_with`) | `src/kurbo/stroke.zig` | in flight (style types landed; expansion port running) |
| kurbo `arc/ellipse/rounded_rect/expand/offset/simplify/fit/...` | — | defer/unsup as needed |
| color `AlphaColor`/`PremulColor`/`Srgb`/`Rgba8`/`PremulRgba8`/palette | `src/peniko/{color,rgba8,palette}.zig` | port (45 tests; palette 142/142 cross-checked; premultiply/conversion bit-verified against Rust color 0.3.3) |
| peniko `blend/fill/gradient/image` | `src/peniko/*` | port (45 tests; gradient uses an interim local Point until kurbo lands) |
| `fearless_simd` | `src/simd/root.zig` | port (portable backend, tests green) |
| `alloc::Arc` | `src/common/shared.zig` | port (atomic refcount, 5 tests) |
| `vello_common` foundation (`geometry/math/target/render_state/transforms/paint/pixmap/util`) | `src/common/*` | port (3,034 LOC, 53 tests; `zig build test` now collects all submodule tests: 187/187) |

**Build hygiene note:** `std.testing.refAllDecls` does not force analysis of imported files in this Zig version, so every aggregating root (`src/common/root.zig`, and future `src/cpu/root.zig`, `src/gpu/root.zig`) must explicitly `_ = @import("<file>.zig");` each submodule in a `test` block. Without it, modules can reference missing symbols and their tests silently do not run.



## 6. Public operations and feature coverage

<!-- FEATURES:MATRIX -->

## 7. Shader-to-host interface mapping

The full contract (five shader roots, bind groups, vertex layouts, host struct
byte layouts, encoded-paint packing, pipeline state, constants) is maintained
in [`docs/shader-interface.md`](docs/shader-interface.md). Highlights:

- Five WGSL modules (`render`, `clear`, `copy`, `blend`, `filter`), no compute,
  no subgroups/f16/dual-source blending; compiled WGSL is checked in with
  provenance and a regeneration script rather than adding a WESL toolchain.
- `render` strip instances are 24 bytes / six `Uint32` vertex attributes;
  `Config` uniform is 32 bytes; filter blocks are exactly 48 bytes.
- Hard constants: tile height 4, `NEARLY_ZERO_TOLERANCE = 1/4096`,
  `FILTER_ATLAS_PADDING = 6`, `MAX_KERNEL_SIZE = 13`.

## 8. GPU compatibility gate

The full inventory and mapping lives in
[`docs/gpu-compatibility.md`](docs/gpu-compatibility.md): every wgpu operation,
feature, limit, format, and capability used by the pinned `vello_gpu` mapped to
the `.ports/wgpu` C API. Conclusion: **no blocking gaps and no binding
additions required.** The pinned wgpu-native checkout resolves wgpu-core/naga/
wgpu-types to 29.0.3 — identical to the Rust side.

Required substitutions (operational, not semantic):

1. `DeviceExt::create_buffer_init` → create + `wgpuQueueWriteBuffer`.
2. `Queue::write_buffer_with` staging belt → persistent mapped or queue writes.
3. `TextureView::texture()` feedback check → track `WGPUTexture` identity next
   to views in the Zig bindings type.
4. Always use `wgpu_zig_init_WGPU*` descriptor helpers; never zero-init.
5. Explicit `Release`/`Destroy`/pass `End`; buffer mapping driven by
   `wgpuDevicePoll(device, true, null)`.


## 9. Dependency functionality: port, adapt, bind, defer

| Dependency | Used for | Decision |
| --- | --- | --- |
| kurbo 0.13.1 | Affine/Point/Vec2/Rect/BezPath/PathEl/Shape, stroke expansion, flattening helpers | **port** (largest geometry dependency; `src/kurbo/`) |
| color 0.3.3 | `AlphaColor`/`PremulColor`/`Rgba8`/`PremulRgba8`/`Srgb`, CSS palette, color mixing | **port** (`src/peniko/color.zig`, `rgba8.zig`, `palette.zig`) |
| peniko 0.6.1 | Brush/Gradient/Image/BlendMode/Fill/Extend, `FontData` resource handle | **port** (`src/peniko/`) |
| fearless_simd 0.7.0 | `Level`, `dispatch!`, fixed-width vectors | **replace** with a Zig SIMD abstraction over `@Vector` exposing the same levels and a scalar fallback (`src/simd/`) |
| guillotiere 0.7.0 | atlas rect packing (`multi_atlas.rs`) | **port** (small; M3/M2 atlas work) |
| smallvec | inline small vectors | **replace** with fixed buffers/`ArrayList` per site (no ABI) |
| bytemuck | `Pod` casts, slice casts | **replace** with `@bitCast`/`@ptrCast`/`std.mem.bytesAsSlice` |
| thiserror | `AtlasError` | **replace** with a Zig error set |
| log | one NaN-path warning | **replace** with a Zig logging hook |
| png 0.18.1 | `Pixmap::from_png`/`into_png` | **defer/bind** (feature-gated; not needed for M1; std has inflate) |
| roxmltree 0.20 | `pico_svg` dev loader | **defer** (dev-only) |
| libm | no_std float funcs | **replace** with `std.math` |
| skrifa 0.44.0 | font parsing/outlines/hinting in `glifo` | **port/adapt** in M3; subset needed by the glyph contract |
| std threading (rayon/crossbeam/ordered-channel) | CPU multithreading | **adapt** to Zig threads with the same worker model (M4) |

No dependency is bound through Rust. The GPU path binds `.ports/wgpu` only.


## 10. Memory, lifetime, and numerical contracts

Documented once here, enforced per module:

- **Ownership.** `RenderContext` owns its encoded scene and resources;
  `Pixmap` owns its pixel buffer; `Resources` owns glyph/image caches. Public
  setters borrow; `render` may mutate targets but never takes ownership.
- **Scene/resource lifetime.** Resources passed to `render` must outlive the
  call; they may be reused across frames and keep caches warm. A `RenderContext`
  may be reused after `reset()` at the same or different size; no pointers into
  caller memory survive `render`.
- **Mutation/invalidation.** `set_*` affects subsequent draw commands only
  (upstream semantics). `reset()` drops transforms, clip stack, and recorded
  commands. Cache keys include font bytes identity, face index, variation
  coordinates, glyph id, size (subpixel-binned), transform, and hinting flags;
  mutating any invalidates the key.
- **Pixels.** Public CPU targets are premultiplied RGBA8 (`PremulRgba8`), sRGB
  encoded, row-major, no padding. The f32 pipeline computes with premultiplied
  linear float then converts. `ImageAlphaType` distinguishes alpha vs
  premultiplied input images.
- **Coordinates.** Scene coordinates are logical f32 in device pixels
  (no global DPI scaling); transforms compose `Transforms` (upstream separates
  scene transform and per-glyph transform). Tiles are integer pixel-aligned;
  bounding boxes are half-open `[x0,x1) x [y0,y1)`.
- **Clipping/bounds.** Clip stacks intersect; layers have explicit bounds or
  derive them from contents. Out-of-viewport geometry is culled, never drawn
  with placeholder coverage.
- **Failure.** Allocation failure returns `error.OutOfMemory`; the caller's
  context remains in a defined state (no partially recorded command visible).
  GPU device loss/unsupported capability returns a typed error and the backend
  stops; it never silently falls back to the CPU rasterizer.
- **Threads.** CPU multithreading is opt-in; shared state is synchronized by the
  dispatch layer, and `flush` publishes the scene to workers. GPU resources are
  used from one thread at a time; in-flight resources are retired after the
  submission that uses them completes.

## 11. Upstream limitations and intentional divergences

Recorded from the pinned READMEs/source; each entry states impact and handling.

| Upstream limitation | vellz handling |
| --- | --- |
| `vello_cpu`: complex filter graphs panic; filters unsupported in multithreaded mode | typed `error.Unsupported`; no silent skip |
| `vello_cpu`: glyph caching marked experimental | port the cache behind the explicit contract; keep uncached path correct first |
| `vello_gpu`: mask layers, complex filter graphs, some non-isolated blends panic | typed errors; document unsupported cases in the feature matrix |
| `vello_gpu`: some failures panic (no `Result`) | Zig API returns errors; panic only on programmer misuse |
| Rust wgpu badge says 29.0.1 while Cargo.lock uses 29.0.3 | record actual lock version 29.0.3; wgpu-native core matches 29.0.3 |
| `vello_toy debug` default `--stages` contains invalid `ti` | pass stages explicitly in oracle scripts |
| `ARCHITECTURE.md` describes the stale `research/` pipeline | do not treat it as documentation for the target crates |
| Upstream tests ignore alpha in pass/fail and use per-variant tolerances | vellz compares all four channels exactly on f32/scalar; tolerance only where documented |
| `vello_tests` snapshots are Git LFS objects | pin bytes + SHA-256 when importing; never rely on LFS availability at test time |
| `vello_toy` SVG rendering ignores images/text/gradients and uses autodetected SIMD + u8 | used only as a smoke tool, never as byte-gold |
| `Level::new()` output is machine-dependent | oracle and parity tests pin `Level.fallback` |
| fractional `powf` in kurbo-level flattening uses `std.math.pow` (Go algorithm), not platform libm `pow` | can flip subdivision counts at exact thresholds (`err/max_hypot2 == k^6`); the sparse-strip fill path uses the upstream `estimate` LUT and is unaffected; revisit with libm linkage in M2 and gate any parity test that hits `CubicBez.toQuads` |
| kurbo `Dashes` upstream spills past 4 entries | port returns `error.DashPatternTooLong` explicitly; no silent drop |
| `f32ToU8` out-of-range lanes differ between x86 `cvttps2dq` and scalar fallback upstream | port reproduces x86 behavior and documents that only 0..1 is portable |
| port defect (fixed): `kurbo/stroke.zig` had reordered `Join`/`Cap` enum tags vs upstream | fixed to upstream tag order; corpus gate now byte-exact; all future enum ports must preserve upstream tag order |
| `stroke_scaled` upstream allows 1 diff pixel; `glyphs_colr_test_glyphs` allows 55 | recorded per-fixture where those scenes are imported |

Intentional divergences are marked `adapt` in code with a comment naming the
upstream behavior and the reason (Zig allocator contracts, error returns instead
of panics, thread ownership).


## 12. Test, fixture, and performance methodology

- **Corpus.** `tests/scenes/*.json` — deterministic scenes with fixed
  dimensions, transforms, paints, resources, and settings. Rendered by both the
  Rust oracle driver (`tools/oracle-rs`) and vellz; outputs are premultiplied
  RGBA8 raw pixels (`*.rgba`) to avoid PNG-decoder variance.
- **Comparison.** `tools/compare.py` reports exact mismatches, per-channel
  metrics, and a diff image. Exact equality is required for the f32/scalar
  path and for oracle-verified fixtures unless a fixture documents a tolerance
  and the reason. A tolerance is never used to hide missing geometry.
- **Upstream probe.** `tests/fixtures/upstream/probe.rgba` is the pinned
  upstream probe reference (unpremultiplied RGBA8, 51×51). `common/probe.zig`
  ports the scene and the upstream comparison policy (all four channels,
  per-channel absolute tolerance 3, zero-alpha pixels equal); `zig build probe`
  re-renders it and re-checks the written bytes independently through
  `tools/compare_raw.py`. The f32/scalar path is byte-exact and both tools
  report the measured maximum channel difference.
- **Coverage areas.** winding rules and self-intersection; degenerate/extreme
  geometry; join/cap/dash strokes; tile seams; nested/intersecting clips;
  translucent overlap and layers; gradient stops/transforms; image sampling and
  edges; positioned glyphs and mixed scripts; empty scenes; repeated resize;
  allocation failure/teardown.
- **Performance.** Measured only after comparable output exists, separately for
  scene construction, CPU preprocessing, CPU rasterization, GPU upload, GPU
  execution, readback, presentation. Record hardware/adapter, build mode,
  feature flags, memory, workload. Hardware vs software adapters are reported
  explicitly. Readback cost is included or excluded symmetrically and noted.

## 13. Milestones and executable gates

### Milestone 0 — Reproducible oracle

- Pinned checkout, oracle driver, scene corpus, comparison tooling.
- **Gate:** `tools/oracle-rs` renders every corpus scene; `tools/compare.py`
  reports identical output for two oracle runs (`G0`). Recorded settings,
  hashes, and hardware are committed in `tests/fixtures/README.md`.

### Milestone 1 — Shared foundation and first CPU image

- Geometry/transform/paint/path/tile/strip/pixmap types; CPU encode → strip →
  coarse → fine path for solid fills; overlapping translucent fills; nested
  clipping.
- **Gate `G1`: MET 2026-09-11.** All 12 corpus scenes are byte-exact
  (`tolerance=0`, all four channels) against the pinned oracle in Debug,
  ReleaseSafe, and ReleaseFast: `zig build corpus`. Scenes cover AA fills,
  translucent overlap, NonZero/EvenOdd, nested clips and clip layers,
  transforms, round-capped strokes, degenerate/empty input, tile seams and
  wide curvature at 128×128. Unit/integration tests: 483/483.
  Verification commands: `zig build test`, `zig build corpus`,
  `zig build run-cpu-example`.

### Milestone 2 — CPU feature coverage

- Strokes, gradients, images, layers/blending, masks, supported filters,
  upstream fixtures imported with provenance.
- **Gate `G2`: MET 2026-09-12.** All 32 corpus scenes are byte-exact
  (`tolerance=0`, four channels) in Debug, ReleaseSafe, and ReleaseFast: the
  M1 set plus linear/radial/sweep/repeat gradients, nearest/bilinear images,
  opacity/multiply layers, alpha/luminance masks, filter layers (flood,
  offset, gaussian blur, drop shadow and drop-shadow-only, composed with
  clip/opacity/blend), and analytic blurred rounded rectangles (normal and
  inverted). `zig build test` = 589/589. Verification commands:
  `zig build test`, `zig build corpus`.
- Provenance: the ported upstream `vello_common::probe` scene
  (`common/probe.zig`, `cpu/probe.zig`, `vellz-cli --probe`,
  `zig build probe`) renders `probe.rgba` byte-exact (tolerance policy 3;
  measured max channel difference 0).

### Milestone 3 — Glyph rendering and Cozmic adapter

- `glifo` port; stable font identity/face index/variation/glyph/size/placement
  contract; monochrome + COLR behavior; cache invalidation.
- **Gate:** glyph corpus renders match upstream for the same font resources;
  Cozmic adapter test consumes Cozmic positioned glyphs without reshaping
  (`G3`).

### Milestone 4 — CPU optimization

- **Status (2026-09-12):** the u8 low-precision pipeline and multithreaded
  f32 dispatch are landed on `main` and oracle/differential-verified (G4 is
  not claimed yet: SIMD-level dispatch and methodology-complete timings are
  still open).
- u8 low-precision pipeline ported and connected behind
  `RenderMode.optimize_speed` (`cpu/fine/lowp/*`, dispatcher kernel selection).
- Multi-threaded f32 dispatch ported: `dispatch/mod.zig` `Dispatcher` vtable +
  `multi_threaded.zig` with persistent `std.Thread` workers and upstream
  batch/cost/row splitting; output is byte-identical to the single-threaded
  f32 path (`render.zig` differential test, threads 1–4). u8 + MT and MT
  filter layers return typed `error.Unsupported` (upstream limitation).
- **u8 oracle gate:** 16 `*_speed` corpus scenes byte-exact (`tolerance=0`,
  four channels) against the pinned oracle rendered with
  `RenderMode::OptimizeSpeed`; they cover the u8-native gradient LUT and
  bilinear painters, the f32 painter `paintU8` conversion (nearest/bicubic
  images, undefined radial gradients), and the integer blend/composite/mask
  paths. All 32 quality scenes (including filters and blurred rounded rects)
  stay byte-exact.
- **MT equivalence:** the single- vs multi-threaded f32 output is asserted
  byte-identical on a layered differential scene in `cpu/render.zig`; the
  corpus itself runs with the committed scenes' `threads` setting (0).
- **Rough timings** (ReleaseFast CLI, 200 runs each, includes ~2.4 ms process
  startup; not a methodology-complete G4 record): `fill_wave_seams_128`
  3.6 -> 2.0 ms, `fill_tile_grid_128` 4.4 -> 1.9 ms, `gradient_repeat_128`
  5.0 -> 3.5 ms; but `image_bilinear_64` 3.4 -> 4.8 ms slower in u8, because
  the ported u8 painters run scalar lane loops while the f32 painters
  vectorize through `@Vector`.
- **Remaining:** SIMD-level dispatch (the port currently pins fallback
  semantics in `src/simd`), MT filters, u8 + MT, per-stage measured speedups.
  Gate G4 is not claimed until scalar/portable/SIMD agreement and timings are
  recorded.

### Milestone 5 — Hybrid GPU implementation

- Actual upstream GPU pipeline through `.ports/wgpu`; upstream WGSL initially;
  host/shader layout verification; uploads, passes, compositing, readback,
  synchronization, resource reuse, device-loss handling.
- **Gate:** GPU corpus output matches the CPU oracle within documented
  tolerances; offscreen rendering works without a window; compatibility gate
  has no unrecorded missing operations (`G5`).

### Milestone 6 — Application integration

- CPU and GPU examples; narrow ZUI adapter after the standalone engine passes.
- **Gate:** real text, images, overlap, clipping, scrolling, resizing,
  high-DPI verified; ZUI's existing renderer is not replaced until then (`G6`).

## 14. Progress log

- 2026-09-11: scaffold; pinned checkout; oracle driver + 12-scene corpus
  rendered twice and hash-verified (`tools/render_corpus.sh --check`);
  `docs/gpu-compatibility.md` and `docs/shader-interface.md` written from
  full reconnaissance; compiled WGSL checked in with SHA-256 manifest
  (`tools/generate_shaders.sh`); kurbo (7,166 LOC/84 tests, bit-verified
  against upstream), peniko/color (2,637 LOC/45 tests, bit-verified), common
  foundation (3,034 LOC/53 tests), and the portable SIMD backend landed;
  `zig build test` collects and passes 187/187. Test-collection hazard found
  and fixed (explicit submodule imports in aggregating roots). In flight:
  flatten/tile, mask/filter data model, CPU rasterization core, full kurbo
  stroke expansion; audits running for peniko and common-foundation numerics.
- Tooling added: `tools/compare_corpus.sh` (G1 runner), `tools/vellz_cli.zig`
  (scene -> .rgba, wired once `vellz.cpu` lands), `tools/scene.zig` parser.
- 2026-09-11 M2 started: path-level masks wired end to end
  (`setMask`/`resetMask`/`pushMaskLayer`) with a lifetime fix — recordings now
  own their mask handles like upstream's `Arc<Mask>` clones (the command
  recorder releases draw resources through an optional `deinit` hook), so a
  scene remains renderable after the context mask is replaced. Image registry
  ported with explicit ownership and resolver view. 485/485 tests. In flight:
  `common/encode.zig` (gradient/image encoding + LUTs) and the cross-language
  scene-format extension for gradients/images/layers/masks.
- 2026-09-11 M1 complete: `zig build corpus` reports 12/12 byte-exact against
  the oracle in Debug/ReleaseSafe/ReleaseFast (`G1`). The final delta
  (`stroke_basic_64`, 19 pixels at round caps) was traced through
  stroke-expansion, flattening, tile, strip, and segment stages (all
  bit-identical to upstream) to a port defect: `kurbo/stroke.zig` had
  reordered the `Join` (`bevel,miter,round`) and `Cap` (`butt,square,round`)
  enums relative to upstream (`Miter,Round,Bevel` / `Butt,Round,Square`).
  Named uses were unaffected, but numeric mapping (the CLI/scene path) built
  `miter+square` instead of `round+round`, changing cap geometry. Fixed to
  upstream order; corpus then exact. Lesson recorded: enum declarations that
  mirror upstream must preserve upstream tag order.
- 2026-09-11 later: kurbo stroke expansion landed (2,357 LOC, 102 tests,
  240-case differential vs Rust); flatten/tile (65 tile tests) and CPU
  rasterization core (region, coarse cmd/depth/bucketer data model,
  `Fine(K)`, `F32Kernel`) landed; mask/filter data model landed (29 tests).
  `zig build test` = 363/363. Foundation numerics audit applied: `powi`
  multiply chain, `QuadBez` D^4 rounding, `Rect` aspect reciprocal,
  `tryTakeRgb8` no longer corrupts the pixmap on OOM, checked bounds in
  `sample`/`setPixel`, exact image-data length, `SizeU16.add` overflow panic.
  Strip wave (`strip`/`strip_storage`/`rect`) dispatched.
- Upstream oracle facts recorded: the byte-exact reference variant is
  `_cpu_f32_scalar` (`Level::fallback`, 0 threads, `OptimizeQuality`); upstream
  pass/fail compares RGB only and ignores alpha, with per-variant tolerances
  (0 for the f32 scalar gold). vellz compares all four channels exactly on the
  f32 scalar path. `vello_toy` is smoke-only (autodetected SIMD, u8 pipeline,
  primitive SVG support). `vello_tests/snapshots` are Git LFS; import fixtures
  by pinned SHA-256 only. `vello_common/assets/probe.rgba` is an independent
  deterministic fixture (unpremultiplied RGBA8, tolerance 3 upstream) for later
  import.
- 2026-09-11 later: M2 CPU features verified end to end. The in-flight
  gradient/image encoder (`common/encode.zig`) and fine-side painters
  (`cpu/fine/gradient.zig`, `cpu/fine/image.zig`) were already written; the
  missing link was upstream `generate_fill`'s indexed-paint path in
  `cpu/coarse/bucketer.zig`: the bucketer now threads `encoded_paints` through
  `bucketCommands`/`generateFill` and gates depth culling on
  `encode.paintMayHaveTransparency` instead of rejecting `Paint.indexed`.
  `zig build corpus` now reports 22/22 scenes byte-exact (`tolerance=0`, four
  channels) — adding linear/radial/sweep/repeat gradients,
  nearest/bilinear images, opacity/multiply layers, and alpha/luminance masks
  to the M1 set; `zig build test` 547/547. Remaining for G2: filter layers
  (gaussian blur, drop shadow, flood, offset), blurred rounded rectangles,
  upstream fixture import.
- 2026-09-12: **M2 complete (G2 met).** Filter layers landed end to end:
  `vello_common` filter payloads (`PreparedFilter` for flood, gaussian blur,
  offset, drop shadow/drop-shadow-only), `vello_cpu` algorithms and
  `FilterContext`/scratch, the bucketer's filter-layer branch and
  `generate_filter_layer_fill`, dispatcher-side filter-layer rasterization,
  paint-level `setFilterEffect` layering, and analytic blurred rounded
  rectangles (`common/pixmap`-level encode + `cpu/fine/blurred_rect.zig`).
  Ten new scenes (8 filter, 2 blurred rounded rect) were added with
  deterministically regenerated pinned-oracle fixtures; `zig build corpus` =
  32/32 byte-exact in Debug/ReleaseSafe/ReleaseFast, `zig build test` =
  589/589. The upstream `probe.rgba` fixture is byte-exact. Verified on
  integration branches pending merge into `main`: u8 `optimize_speed`
  rasterization (16 further scenes byte-exact) and multithreaded dispatch
  (byte-identical to single-threaded at 1–4 threads).
- 2026-09-11 later (merged 2026-09-12): the upstream fixture import is
  closed. The pinned `vello_common::probe` scene is ported
  (`common/probe.zig`: 8 active elements, `Filter` disabled as upstream,
  grid geometry and the tolerance-3 comparison policy transcribed) with the
  pinned `probe.rgba` embedded and compared per channel; `cpu/probe.zig`
  adds the exact reference render settings and the end-to-end oracle test;
  `vellz-cli --probe` and `zig build probe` (`tools/check_probe.sh`,
  re-checked with `tools/compare_raw.py`) run it outside `zig build test`.
  Measured: 51×51, different pixels 0, max channel difference `[0,0,0,0]`
  (byte-exact, fnv1a `52f1e5326a5c7fda`). One port defect found and fixed
  during the port: the gradient element set its paint but initially omitted
  the `fill_rect`, which is exactly what the probe is for.
- 2026-09-11 later (merged 2026-09-12): M4 u8 speed path landed. Ported
  upstream `fine/lowp/{mod,blend,compose,gradient,image}.rs` into
  `cpu/fine/lowp/{mod,blend,compose,gradient,image}.zig` (u8/u16 integer
  compositing and blend fast paths with the f32 fallback for the remaining
  mix modes; u8 LUT gradient painter; u8-native bilinear image painters;
  the f32 painters gained `paintU8` conversion for the paths upstream keeps
  on f32, and `cpu/fine/blurred_rect.zig` gained the matching `paintU8` so
  the u8 kernel can use the M2 blurred-rect painter too).
  `cpu/fine/mod.zig` `indexedFill`/`applyComplexPaint` select painters by
  `K.Numeric`, and `dispatch/single_threaded.zig` routes
  `RenderMode.optimize_speed` to `U8Kernel` with comptime dispatch (no
  runtime vtable), mirroring upstream when both pipeline features are on;
  filter layers rasterize their contents with the selected kernel, as
  upstream's `rasterize_filter_layers` does. Oracle evidence: 16 new
  `*_speed` scenes render byte-exact vs the pinned oracle at
  `OptimizeSpeed` (`tolerance=0`, four channels); quality scenes stay
  byte-exact. Remaining: SIMD-level dispatch, multithreading, more measured
  speedups, glyphs on the u8 path.
- 2026-09-12 (merged 2026-09-12): M4 multithreading landed. `cpu/dispatch/mod.zig`
  owns the upstream `Dispatcher` vtable and the `num_threads` selection
  (0 = single-threaded); `cpu/dispatch/multi_threaded.zig` + `multi_threaded/`
  port the worker/job structure with persistent `std.Thread` workers replacing
  rayon/crossbeam: batched `RenderTask`s with `cost.COST_THRESHOLD`, in-order
  completion slots for recording, per-worker strip/alpha storage, and
  strip-row `Region` splitting for fine rasterization. Zig 0.17 moved
  `Mutex`/`Condition` behind `std.Io`; `multi_threaded/sync.zig` centralizes
  the stateless futex-backed `global_single_threaded` instance (documented
  adapt). `RenderContext.flush` became fallible (`error.NotFlushed` when a MT
  render starts before flush; upstream panics). Differential test renders a
  layered gradient/image/mask/clip/stroke scene with 0..4 threads and compares
  all four channels byte-for-byte; upstream MT tests (`allocations`, reset /
  drop with pending tasks, empty frame after reset, clip before draw) are
  ported. Branch evidence: `zig build test` = 563/563 (557 unit + 6 scene),
  `zig build corpus` = 22/22 byte-exact (corpus stays `threads: 0`,
  single-threaded). Extra MT evidence: rewriting corpus scenes to
  `"threads": 4` and rendering them with the CLI matches the pinned oracle
  fixtures byte-for-byte in Debug, ReleaseSafe, and ReleaseFast. Remaining
  for G4: native SIMD levels, MT filters, u8 + MT, and measured speedups.

- 2026-09-12: **integration complete.** Merged `vellz-probe` (`2ce5579`),
  `vellz-lowp` (`344f5c5`), and `vellz-mt` (`04f2c62`) into `main` in that
  order. Composition: MT's `Dispatcher` vtable + persistent worker pool keep
  the architecture; lowp's comptime kernel selection lives inside the
  single-threaded dispatcher's `rasterizeWith(K)` (including upstream's
  generic `rasterize_filter_layers`), and main's M2 filter layers keep
  working on both kernels; the MT dispatcher still rejects `optimize_speed`
  and filter layers with typed `error.Unsupported`. `RenderContext.flush`
  stays `!void` (`error.NotFlushed` before an MT render), and the push-layer
  seam now carries `Option<FilterData>` by value (upstream's shape): the
  single-threaded dispatcher consumes it, MT releases it and errors. One
  composition fix beyond textual merges: `cpu/fine/blurred_rect.zig` gained
  the upstream `paintU8` path so the u8 kernel can use the M2 blurred-rect
  painter. Final gates on `main`: `zig build test` = 638/638 (631 lib + 7
  scene) and `zig build corpus` = 48/48 byte-exact at `tolerance=0` in Debug,
  ReleaseSafe, and ReleaseFast; `zig build probe` byte-exact; `zig build
  run-cpu-example` smoke test passes. MT spot checks: nine varied scenes
  rendered with `"threads": 4` (`fill_overlap_alpha_64`,
  `gradient_radial_64`, `stroke_basic_64`, `mask_alpha_64`, `clip_layer_64`,
  `layer_opacity_64`, `image_bilinear_64`, `gradient_sweep_64`,
  `fill_wave_seams_128`) match the committed fixtures byte-for-byte;
  filter+MT and u8+MT fail with typed `error.Unsupported`.
- 2026-09-12: **M5 T1/T2 landed** (branch `vellz-gpu`). T2 host/shader contract:
  `gpu/render/common.zig` (`Config` 32 B, `GpuStrip` 24 B, `GpuClearInstance`
  28 B, encoded paints 48/32/64/48/80 B, paint/rect/flag + image/gradient/tint
  packing), `gpu/copy.zig` (16 B), `gpu/blend.zig` (32 B, `blend_config` bits),
  `gpu/filter.zig` (48-byte blocks, `FilterInstanceData` 36 B, header/pass-kind
  constants), `gpu/util.zig`; all asserted at comptime and exercised by 8 tests
  that run in the default CPU build (`zig build test` = 646/646; corpus stays
  48/48 byte-exact). T1 bootstrap: `gpu/backend/device.zig`
  (instance -> adapter -> device/queue, error scopes, uncaptured + device-lost
  capture, typed `Error`, limits, adapter-info printing, `--force-adapter-failure`
  => `error.NoAdapter`), `readback.zig` (texture -> 256-B row-aligned buffer ->
  map/poll -> tightly packed RGBA8), `wgpu.zig` (checked-in `clear.wgsl` module
  + 28-B instanced rectangle pipeline + clear encoder), `tools/gpu_smoke.zig`
  wired in `build.zig` as `run-gpu-smoke` / `run-gpu-smoke-failure` and compiled
  by `-Dgpu=true check`. Evidence: `zig build -Dgpu=true run-gpu-smoke` on the
  llvmpipe adapter (`backend=vulkan type=cpu execution=software-adapter
  vendorID=0x10005`, Mesa 25.2.8, `maxTextureDimension2D=8192`) clears a 64×64
  `Rgba8Unorm` texture to `0xFFBF8040` and all 4096 readback pixels match; zero
  validation errors; every handle released. `zig build -Dgpu=true test` =
  653/653. Environment finding recorded: Zig 0.17 AstGen resolves every
  `@import` literal in every parsed file, even inside untaken comptime branches,
  so `build.zig` provides an inert `wgpu_stub.zig` module name for CPU-only
  builds; the real `.ports/wgpu` dependency is never resolved or linked there.
  Next: T3 (pipeline factory + clear through the strip/encoded infrastructure),
  T4 (root strip pass for solid fills), then the G5 harness.
