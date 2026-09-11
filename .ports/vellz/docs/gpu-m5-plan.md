# Milestone 5 — hybrid GPU backend (vellz)

Recon date: 2026-09-11. Status: plan only; no code changed. Pin:
`linebender/vello @ 1e63b4a40ccb484f82e1d85b83df97ab95bcfbe7` (`v0.10.0-51-g1e63b4a4`),
`.ports/wgpu` wgpu-native `v29.0.1.1` (`6aed50955d934ac36049ba8d002034841633ae02`).

## 1. Confirmed environment facts

| Fact | Evidence |
| --- | --- |
| **No prebuilt `libwgpu_native.*` exists here.** Glob found none in the workspace, `/usr`, `/usr/local`, `/opt`, or `/home/zeus`. `.ports/wgpu/.reference/` contains only `wgpu-native/` (source); there is no `artifacts/prebuilt` and no `target/`. | globs; directory listings |
| **Pinned wgpu-native source checkout exists** at `.ports/wgpu/.reference/wgpu-native`, detached HEAD `6aed5095…`, `ffi/webgpu-headers` submodule populated, full clone (no `.git/shallow`). | `.git/HEAD`, `.git/packed-refs`, dir listing |
| **Native source build is possible in principle but not done.** `cargo`/`rustc` are installed only under `$HOME/.rustup/toolchains/stable-…/bin`; `$HOME/.cargo/bin` contains only `rustup` (no `cargo` shim), so `cargo` is probably **not on PATH**. `rust-toolchain.toml` pins 1.93 (checkout `rust-version = "1.87"`); only `stable` is installed. `Cargo.lock` crates for wgpu/naga are **not** in the local registry cache (only oracle-rs deps), so a source build is a full network build (prior dev-machine time: 7m25s, `CARGO_BUILD_JOBS=4`). crates.io index is reachable from this session. | toolchain listings, `.rustup/settings.toml`, registry cache listing, `rust-toolchain.toml`, `Cargo.toml`, webfetch of `index.crates.io` |
| **Release route is available.** `tools/fetch-release.sh` downloads `wgpu-linux-x86_64-release.zip` from GitHub tag `v29.0.1.1`; `curl` and `unzip` exist; the GitHub release page is reachable. `build.zig` auto-detects `.reference/artifacts/prebuilt/lib`. | script, globs, webfetch |
| **Version match confirmed.** `.ports/wgpu/.reference/wgpu-native/Cargo.lock` resolves `naga`, `wgpu-core`, `wgpu-hal`, `wgpu-types` all to **29.0.3**, identical to the pinned vello `Cargo.lock` (`wgpu` 29.0.3). The “29.0.1.1” tag is the native release wrapper; there is no core-version skew. | Cargo.lock greps |
| **Zig**: `$HOME/.zvm/bin/zig` → `.zvm/master/zig`; recorded/tested as `0.17.0-dev.2085+5e36170b5`. Exact `zig version` could not be executed (shell denied); recent CPU corpus outputs (`out/candidate/*`) and `tools/oracle-rs/target/release/vellz-oracle` show the workflow runs here. | `.zvm` listing, plan/README, build outputs |
| **No hardware GPU node**: `/dev/dri` does not exist. Software Vulkan is present: loader `libvulkan.so.1.3.275`, ICD `/usr/share/vulkan/icd.d/lvp_icd.json` → `libvulkan_lvp.so`, LLVM 17/20, `libdrm`. Expect a CPU-type adapter (lavapipe); set `VK_ICD_FILENAMES` to the lvp JSON if enumeration is ambiguous. Offscreen rendering needs no display. | globs, ICD JSON |
| **`-Dgpu=true` currently fails by design**: `src/gpu/root.zig` `@compileError("… Milestone 5")`; `src/gpu/backend/` does not exist yet; `build.zig` forwards `-Dwgpu-native-*` options and resolves `../wgpu` lazily. | `src/gpu/root.zig`, `build.zig` |
| **Bindings suffice.** Vendored headers declare every needed function (`wgpuDeviceGetLimits`, `wgpuQueueWriteTexture`, `wgpuCommandEncoderCopyTextureToTexture`, `wgpuRenderPassEncoderSetScissorRect`, `wgpuBufferGetMappedRange`, error scopes, `WGPUPipelineLayoutDescriptor.immediateSize`); no binding additions identified. | header greps; `docs/gpu-compatibility.md` |
| **Prior proof, not this container**: `.ports/wgpu/verify/RESULTS.md` records real compute + offscreen runs on Fedora 44 (RADV and llvmpipe). | RESULTS.md |

**Blocking gap:** the native library must be fetched or built before any GPU work can link/run; then adapter acquisition on lavapipe is the go/no-go for G5 in this environment (Task 1).

## 2. Upstream inventory → planned Zig targets

LOC include Rust `#[cfg(test)]` code; production LOC is roughly 75–80% of each figure.

| Upstream (`vello_gpu/src/…`) | ~LOC | Zig target (plan.md §5, split proposed) | Depends on / gaps |
| --- | --- | --- | --- |
| `lib.rs` (errors, re-exports) | 167 | `src/gpu/root.zig` | — |
| `render/mod.rs`, `render/common.rs` | 27, 705 | `src/gpu/render/common.zig` | `common/geometry`, `common/tile`, `common/paint`, `peniko/color` |
| `render/wgpu/mod.rs` | 3397 | `src/gpu/render/wgpu.zig` + `src/gpu/backend/root.zig` (device/bootstrap) | `wgpu` module, all below |
| `scene.rs` | 1005 | `src/gpu/scene.zig` | `common/{encode,render_state,transforms,viewport,record,strip_generator,filter_effects}`, `kurbo`, `peniko`; text behind M3 |
| `draw.rs` | 1069 | `src/gpu/draw.zig` | `common/{strip,strip_generator,tile,paint,record}`, `rect`, `paint`, `target`, `util` |
| `target.rs` | 370 | `src/gpu/target.zig` | `common/geometry` only |
| `paint.rs` | 150 | `src/gpu/paint.zig` | `common/encode`, `common/paint`; atlas image source needs `common/atlas` |
| `rect.rs` | 331 | `src/gpu/rect.zig` | `kurbo`, `common/geometry` |
| `blend.rs` | 182 | `src/gpu/blend.zig` | `peniko/{BlendMode,Compose,Mix}`, `target`, `copy` |
| `copy.rs` | 20 | `src/gpu/copy.zig` | — |
| `filter.rs` | 915 | `src/gpu/filter.zig` | `common/filter` (**present**, incl. `PreparedFilter`, `DecimationSizer`), `common/filter_effects`, `copy`, `schedule.round` |
| `util.rs` | 284 | `src/gpu/util.zig` | `common/util` (`Clear`, `RetainVec`-equivalents) |
| `gradient_cache.rs` | 561 | `src/gpu/gradient_cache.zig` | `common/encode` (`EncodedGradient.u8Lut`, `GradientCacheKey` with `hash`/`bitEql`); needs a Zig HashMap adapter (no `peniko::color::cache_key` module in vellz) |
| `schedule/mod.rs`, `round.rs`, `execute.rs`, `allocate.rs`, `cursor.rs` | 1090, 860, 421, 413, 237 | `src/gpu/schedule/{root,round,execute,allocate,cursor}.zig` | `common/record`, `common/filter`, `draw`, `filter`, `paint`, `target`, `util`; `allocate` needs atlas/guillotiere (**missing**, §7) |
| `resources.rs` | 36 (+text) | `src/gpu/resources.zig` | `common/atlas` (`MultiAtlasManager`), `common/image_cache` (**both missing**), `glifo` behind text |
| `text.rs` | 350 | `src/gpu/text.zig` | `glifo` (M3) |
| `render/webgl/*` | — | — | **unsup** (out of scope) |
| `schedule/{schedule_tests,test_support}.rs` | — | — | test-only, not ported |

Checked-in shaders: `src/gpu/shaders/{render 15,696 B, blend 7,416 B, filter 7,151 B, clear 964 B, copy 908 B}.wgsl` = 32,135 B total, SHA-256 in `manifest.json`, embedded by `generated.zig` (`RENDER/CLEAR/COPY/BLEND/FILTER`, `all`).

**Dependency order (build bottom-up, gpu → common only, never gpu → cpu):**
1. `target.zig`, `copy.zig`, `util.zig`, `rect.zig`, `render/common.zig` — leaves.
2. `paint.zig`, `gradient_cache.zig` (via `common/encode`); `draw.zig` (via `common/strip`).
3. `scene.zig` (via `common/record`/`viewport`), `filter.zig` (via `common/filter`).
4. `schedule/*` (1–3 + `schedule/execute.zig` `Backend` trait → Zig vtable/anytype).
5. `render/wgpu.zig` backend (all + `wgpu`), `resources.zig` (needs atlas), `text.zig` (M3).

**Missing prerequisites:** `common/multi_atlas.rs` (1019 LOC) and `common/image_cache.rs` (357 LOC) are absent (`src/common/atlas.zig` is still `defer`; guillotiere 0.7.0 is cached in the Rust registry but not ported). They gate layer pages, images, atlases, and glyph atlases — **not** root solid/path fills, so they can follow the first render tasks. `common/filter.zig` already has everything `filter.rs` encodes, so GPU filters are not blocked.

## 3. Host/shader interface contract to implement first

Authoritative detail is `docs/shader-interface.md`; the checklist to land before any shader change:

- **Consumption**: compiled/minified WGSL is embedded via `@embedFile` in `src/gpu/shaders/generated.zig` and passed through `WGPUShaderSourceWGSL` chained onto `WGPUShaderModuleDescriptor.nextInChain` (pattern: `var source = c.wgpu_zig_init_WGPUShaderSourceWGSL(); source.chain.sType = c.WGPUSType_ShaderSourceWGSL; source.code = wgpu.stringView(src);`). No WESL/naga/cargo at Zig build time; regeneration only via `tools/generate_shaders.sh` after a pin change.
- **Bind groups**: render group 0 = `texture_2d<u32>` alphas + uniform `Config` + unfilterable layer texture; group 1 = four unfilterable external textures; group 2 = `texture_2d<u32>` encoded paints; group 3 = filterable gradient texture. Filter groups 0/1/2 = filter data, sampled source (linear sampler), original texture. Blend group 0 = two unfilterable layers + alphas. Copy group 0 = unfilterable source. Clear = none.
- **Vertex layouts** (all triangle-strip, instanced): strip stride 24 B = 6×Uint32 at shader locations 0–5; clear 28 B = Uint32x2×3 + Uint32; filter 36 B = 9×Uint32; blend 32 B = 8×Uint32; copy 16 B = 4×Uint32.
- **Host structs** (`@sizeOf`/`@offsetOf` assertions): `Config` 32 B (width, height, strip_height, alphas_tex_width_bits, encoded_paints_tex_width_bits, strip_offset_x, strip_offset_y, negate_ndc); `GpuStrip` 24 B (`x u16,y u16,width u16,dense_width_or_rect_height u16,col_idx_or_rect_frac u32,payload u32,paint_and_rect_flag u32,depth_index u32`); clear 28; copy 16 (packed u16 pairs); blend 32; `FilterInstanceData` 36; filter blocks exactly 48 B (`GpuOffset`, `GpuFlood`, `GpuGaussianBlur`, `GpuDropShadow`); encoded paints 48/32/64/48/80 B. Implement the packing helpers (`pack_image_*`, `pack_texture_width_and_extend_mode`, `pack_radial_kind_and_swapped`, `pack_tint`, `pack_u16_pair`, `pack_opacity`, paint bits: bit 31 rect, 29–30 color source, 26–28 paint type, 0–23 texture index, 24–25 external slot).
- **Pipeline state**: 4 strip pipelines (`intermediate` Rgba8Unorm premultiplied alpha; `alpha` target format; `depth alpha` Depth24Plus LessEqual no write; `opaque` no blend, depth write) plus filter/blend/copy (Rgba8Unorm, no blend), root clear (target format), atlas clear (`vs_main_fullscreen`/`fs_transparent`). Target formats `Rgba8Unorm`/caller format; samplers: filter linear; alphas/paints/filter-data use `textureLoad`. Depth value `z = 1 - depth_index/2^24`, depth cleared to 1 per frame.
- **Constants**: `Tile.HEIGHT = 4`, `NEARLY_ZERO_TOLERANCE = 1/4096`, `FILTER_SIZE_BYTES = 48`, `FILTER_ATLAS_PADDING = 6`, `MAX_KERNEL_SIZE = 13`.

## 4. Offscreen-first test strategy and the G5 gate

- **Device without a window**: `wgpuCreateInstance(null)` → `wgpuInstanceRequestAdapter` → `wgpuAdapterRequestDevice` (synchronous callbacks in this pin), uncaptured-error callback plus `PushErrorScope`/`PopErrorScope` around creation; `wgpuDeviceGetLimits` for `maxTextureDimension2D` (capped to 4096 for resource textures upstream). No `WGPUSurface` anywhere in the library or tests.
- **Readback loop**: render into a `Rgba8Unorm` texture with `RenderAttachment | CopySrc`; copy to a `MapRead | CopyDst` buffer (row stride padded to 256 B); `wgpuBufferMapAsync` + `wgpuDevicePoll(device, 1, null)`; `wgpuBufferGetMappedRange`; copy; `Unmap`. This is exactly the shape of `.ports/wgpu/examples/offscreen.zig`.
- **Oracle**: reuse committed `tests/fixtures/oracle/<name>.rgba` (premultiplied sRGB RGBA8, generated by pinned `vello_cpu`) and `tools/compare_raw.py` (`--max-abs-diff`, `--max-diff-pixels`, `--diff-out`). No new Rust images needed for G5.
- **Tolerance policy (grounded upstream)**: `vello_tests` compares hybrid GPU against CPU with `DEFAULT_HYBRID_TOLERANCE = 1` added to each test’s value, `diff_pixels = 0` default, and `is_pix_diff` ignores alpha (RGB-only; pixels where both alphas are 0 are ignored). vellz policy: compare **all four channels**; start at `--max-abs-diff 1 --max-diff-pixels 0`; a scene may relax either number only with a written reason (upstream itself uses 2–7 for glyphs/images/gradients). Missing geometry or an unimplemented feature fails loudly (`error.Unsupported`), never approximate.
- **First scenes (in order)**: `empty_64` (clear), `fill_rect_64` (AA solid rect), `fill_overlap_alpha_64` (premultiplied blending), `fill_path_nonzero_64` and `fill_path_evenodd_64` (sparse strips + winding), `transform_rotate_64`, `clip_nested_64` (clip paths), `fill_tile_grid_128`/`fill_wave_seams_128` (tile seams). Layers (`clip_layer_64`, `layer_*`), gradients, images, masks, and filters follow once those modules land.
- **G5 gate**: (1) `zig build -Dgpu=true check` and the smoke test pass with zero validation errors; (2) `zig build -Dgpu=true gpu-corpus` shows every implemented-feature scene within its recorded tolerance and unimplemented features error; (3) all of it runs offscreen; (4) layout/bind-group/vertex/pipeline assertions are unit tests; (5) a forced device-loss test and an unsupported-capability test (e.g. limit below a required size) return typed errors; (6) `docs/gpu-compatibility.md` has no unrecorded divergence.
- **Error policy**: Zig error set `error{NoInstance, NoAdapter, NoDevice, DeviceLost, ValidationFailed, OutOfMemory, UnsupportedCapability, TextureTooLarge, LimitReached, MissingTextureBinding, TextureFeedbackLoop, Unsupported}`. An uncaptured callback stores status + message on the device wrapper; once dead, every later call returns `DeviceLost`; unsupported formats/limits return `UnsupportedCapability` naming the limit. **No silent CPU fallback** (plan.md §10).

## 5. First five implementation tasks

**T1 — Bootstrap: link wgpu-native and acquire an offscreen device.**
Files: `src/gpu/backend/root.zig` (new), `src/gpu/backend/device.zig` (new: instance/adapter/device/queue, adapter info, error scopes, poll), `src/gpu/root.zig` (replace `@compileError` with a comptime-gated import of `backend/root.zig`; keep `shaders`), `build.zig` (add `-Dgpu=true`-gated smoke executable/step), `tools/gpu_smoke.zig` or `examples/gpu_smoke.zig`.
Depends: native library provided (`fetch-release.sh` or `zig build native` with cargo on PATH).
Acceptance: `zig build -Dgpu=true check` compiles/links; `zig build -Dgpu=true run-gpu-smoke` prints adapter/backend/type, creates a 64×64 `Rgba8Unorm` texture, clears and reads back, asserts 4 pixels, releases every handle; a `--force-adapter-failure` path returns `error.NoAdapter` and exits non-zero.

**T2 — Host/shader layout contract (no wgpu import).**
Files: `src/gpu/render/common.zig` (`Config`, `GpuStrip`, `GpuClearInstance`, `GpuEncodedImage`, `GpuLinearGradient`, `GpuRadialGradient`, `GpuSweepGradient`, `GpuBlurredRoundedRect`, size constants, packing helpers), `src/gpu/copy.zig`, `src/gpu/blend.zig`, `src/gpu/filter.zig` (Gpu* filter structs + header/pass-kind constants only), tests in each file.
Depends: `vellz.common`, `vellz.peniko` only.
Acceptance: `zig build test` passes with `@sizeOf`/`@offsetOf` asserts matching §3 (Config 32, GpuStrip 24, clear 28, copy 16, blend 32, filter instance 36, filter blocks 48, encoded paints 48/32/64/48/80) and bit-level packing tests against `docs/shader-interface.md`.

**T3 — Pipeline factory and offscreen clear through checked-in WGSL.**
Files: `src/gpu/backend/wgpu.zig` (shader modules from `generated.zig`, bind-group/pipeline layout helpers for clear, `GpuClearInstance` vertex layout, config/instance buffers), `src/gpu/backend/readback.zig` (texture→buffer→host helper).
Depends: T1, T2.
Acceptance: renders viewport clear and rect-list clears at 64×64 and 128×128 to `Rgba8Unorm`, readback matches expected premultiplied bytes exactly; zero validation errors; all handles released.

**T4 — Root strip pass for solid fills.**
Files: `src/gpu/scene.zig` (mini `Scene`: transforms, solid paint, `fillRect`, `fillPath`, `reset`; records `common/record.CommandRecorder`), `src/gpu/draw.zig` (`GpuStrip` from fill segments/rect parts + `rect.zig` split), `src/gpu/util.zig` (`Ranges`/`RangedSlice`), `src/gpu/target.zig`, `src/gpu/backend/wgpu.zig` (24-B instanced strip pipeline, 4 pipeline variants, `Config` uniform, `Rgba32Uint` alphas upload, strip buffer via `wgpuQueueWriteBuffer`, optional Depth24Plus).
Depends: T2, T3; `common/{strip,strip_generator,tile,record,render_state,viewport}`.
Acceptance: offscreen renders of `empty_64`, `fill_rect_64`, `fill_overlap_alpha_64`, `fill_path_nonzero_64`, `fill_path_evenodd_64`, `transform_rotate_64` compare against the oracle; per-scene metrics recorded; contract is max-abs-diff ≤ 1 with 0 pixels beyond (documented exceptions only); no layers/gradients/images assumed.

**T5 — G5 harness, error policy, and docs.**
Files: `tools/gpu_corpus.sh` (new; invokes the CLI with `--gpu` and `compare_raw.py`), `tools/vellz_cli.zig` (`--gpu` flag dispatched to the GPU backend; CPU remains default), `build.zig` (`gpu-corpus` step under `-Dgpu=true`), `tests/README.md` (tolerance registry), `src/gpu/backend/device.zig` (device-loss / unsupported mapping + tests).
Depends: T4.
Acceptance: `zig build -Dgpu=true gpu-corpus` exits 0 for the first scene set and non-zero on a deliberate tolerance breach; forced device loss and an impossible-limit request return `error.DeviceLost` / `error.UnsupportedCapability` (no CPU fallback); metrics and adapter identity (software fallback reported explicitly) are recorded.

## 6. Validation commands (for the implementation agent)

```sh
# 0. Native library, once (pick one)
(cd ../wgpu && tools/fetch-release.sh)                       # prebuilt route
# or: (cd ../wgpu && PATH="$HOME/.rustup/toolchains/stable-x86_64-unknown-linux-gnu/bin:$PATH" zig build native)

zig build test                                               # CPU baseline must stay green
zig build -Dgpu=true check                                   # compiles + layout tests
zig build -Dgpu=true run-gpu-smoke                           # adapter + readback (T1)
zig build -Dgpu=true gpu-corpus                              # G5 tolerance runner (T5)
tools/compare_raw.py tests/fixtures/oracle/fill_rect_64.rgba out/gpu/fill_rect_64.rgba \
    --size 64x64 --max-abs-diff 1 --max-diff-pixels 0
```

## 7. Risks, decisions, open questions

- **R1 (highest): adapter availability.** `/dev/dri` is absent; only lavapipe/llvmpipe software Vulkan is installed. Whether wgpu-native’s Vulkan backend enumerates it here is unproven (T1 is the go/no-go). Fallback: `VK_ICD_FILENAMES=/usr/share/vulkan/icd.d/lvp_icd.json`, then the GL/llvmpipe backend; if neither works, G5 must run on a display machine.
- **R2: native library provenance.** Prebuilt release (fast, needs network, SHA-256 should be pinned) vs cargo build of the pinned checkout (offline after fetch, ~7–15 min, `cargo` likely not on PATH, `rust-toolchain` 1.93 download). This is a reproducibility decision for the parent.
- **R3: missing `common/atlas.zig` (multi_atlas + image_cache + guillotiere).** Blocks layers, images, and `resources.zig`; not the first tasks.
- **R4: tolerance creep.** Upstream ignores alpha and uses 1–7 tolerance; vellz compares four channels. Every relaxed fixture must name the algorithmic reason (plan.md §12); max-diff-pixels must stay bounded.
- **R5: target-layout mismatch.** `plan.md` §5 says `gpu/render/wgpu.zig`; `src/gpu/root.zig`’s doc comment says `src/gpu/backend/`. Pick one (recommended: keep `src/gpu/backend/root.zig` as the wgpu-gated entry and `src/gpu/render/wgpu.zig` for the `render/wgpu/mod.rs` port, updating the plan ledger).
- **R6: M5 scope staging.** Recommend G5a = root fills/paths/clips offscreen; G5b = layers/blends; G5c = gradients/images/filters. The parent should confirm whether “Milestone 5 complete” requires all 22 corpus scenes or only the staged subset.
- **R7: Zig version drift.** Installed zvm “master” could postdate `0.17.0-dev.2085`; T1 must record `zig version` in the PR/log.

### Evidence inspected

`plan.md` §1–§14; `README.md`; `docs/gpu-compatibility.md`; `docs/shader-interface.md`; `docs/port-contracts.md`; `build.zig`; `build.zig.zon`; `src/root.zig`; `src/gpu/root.zig`; `src/gpu/shaders/{README.md,manifest.json,generated.zig}`; upstream `.reference/vello/vello_gpu/src/**` (`lib`, `scene`, `draw`, `target`, `paint`, `rect`, `blend`, `copy`, `filter`, `util`, `gradient_cache`, `resources`, `text`, `render/{mod,common,wgpu/mod}`, `schedule/{mod,round,execute,allocate,cursor}`); `.reference/vello/vello_common/src/{multi_atlas,image_cache}.rs`; `.reference/vello/vello_tests/{vello_dev_macros/src, tests/util.rs}`; `.reference/vello/Cargo.lock`; `.ports/wgpu/{build.zig, build.zig.zon, README.md, tools/*, include/webgpu/webgpu.h, src/root.zig, examples/{compute,offscreen}.zig, verify/RESULTS.md, .reference/wgpu-native/{.git/HEAD, Cargo.toml, Cargo.lock, rust-toolchain.toml}}`; `tools/{vellz_cli.zig, compare_corpus.sh, compare_raw.py}`; `tests/README.md`; environment probes for Vulkan/LLVM/rust/zig/crates.io.
