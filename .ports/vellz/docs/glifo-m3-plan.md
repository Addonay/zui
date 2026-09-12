# Milestone 3 plan: glyph rendering (`glifo`) + Cozmic adapter

Pinned upstream: `1e63b4a40ccb484f82e1d85b83df97ab95bcfbe7` (`v0.10.0-51-g1e63b4a4`), `glifo 0.3.0`. Covers plan.md §2 item 4 and §13 M3. LOC below measured/grepped from the pinned checkout and the pinned cargo registry copies (`skrifa 0.44.0`, `read-fonts 0.41.0`, `guillotiere 0.7.0`); `~` = estimate.

## 1. Upstream module inventory → Zig targets (dependency order)

| # | Upstream | ≈LOC | Zig target | Depends on |
|---|---|---|---|---|
| 1 | `guillotiere-0.7.0/src/allocator.rs` + `lib.rs` | 1,808 + 200 | `src/common/guillotiere.zig` | — |
| 2 | `vello_common/src/multi_atlas.rs` | 1,019 | `src/common/multi_atlas.zig` | guillotiere, `common/geometry.zig` |
| 3 | `vello_common/src/image_cache.rs` | 357 | `src/common/image_cache.zig` | multi_atlas, `common/paint.zig` (`ImageId`) |
| 4 | `skrifa/src/{font,instance,charmap,metrics}.rs` + `read-fonts` tables (`head/maxp/hhea/hmtx/cmap/loca/glyf/OS2` + `COLR/CPAL`) | subset of >100k generated + ~1.2k hand-written | `src/glifo/font.zig`, `src/glifo/tables/*.zig` | — |
| 5 | `skrifa/src/outline/glyf/mod.rs` (1,470), `glyf/outline.rs` (179), `path.rs` (426), `pen.rs` | ~2.1k | `src/glifo/glyf.zig`, `src/glifo/pen.zig` | `font.zig`, `kurbo` |
| 6 | `glifo/src/util.rs` | 145 | `src/glifo/util.zig` | `kurbo.Affine` |
| 7 | `glifo/src/glyph.rs` (`OutlineCache`, `GlyphPrepCache`, `Glyph`, run prep) | 2,437 | `src/glifo/glyph.zig`, `src/glifo/outline_cache.zig` | 4–6 |
| 8 | `glifo/src/atlas/{key,region,commands,cache,mod}.rs` | 364/50/193/645/29 | `src/glifo/atlas/{key,region,commands,cache,root}.zig` | 2–3, 7 |
| 9 | `glifo/src/interface.rs` | 92 | `src/glifo/interface.zig` | 8 |
| 10 | `glifo/src/renderer.rs` | 778 | `src/glifo/renderer.zig` | 7–9 |
| 11 | `glifo/src/colr.rs` + `skrifa/src/color/{mod,traversal,instance,transform}.rs` | 616 + ~1.5k | `src/glifo/colr.zig` | 4, 7, 10 |
| 12 | `vello_cpu/src/text.rs` (509) + `render.rs` text hooks + `text_debug.rs` (107) | ~650 | `src/cpu/text.zig`, changes in `src/cpu/render.zig` | 8–11 |
| 13 | `vello_gpu/src/{text,resources}.rs` | — | `src/gpu/text.zig` | M5, not M3 |
| 14 | `glifo/src/lib.rs` re-exports | 66 | `src/glifo/root.zig`, `src/root.zig` | all |

Staged-only inventory (see §5 remainder): `cff/mod.rs` 1,011 + `cff/hint.rs`, `glyf/deltas.rs` (~400). The interpreter (`outline/glyf/hint/*` + `outline/hint.rs`), the autohinter (`outline/autohint/*`, incl. the BestEffort GSUB shaper subset) and `bitmap.rs`/PNG decode have since landed as M3 G3b/G3e.

## 2. Font loading decision (standalone, byte-exact)

`bind` is rejected everywhere: the package must have no Rust and the pinned oracle must stay the only authority. No C font library either (FreeType output differs from `skrifa` bit-for-bit). Decision per piece:

| skrifa functionality | Decision | Rationale / staging |
|---|---|---|
| sfnt/TTC header, table directory, `head`/`maxp`/`hhea`/`hmtx`, face index | **port** (small subset) | ~10 tables only; needed upem/numGlyphs/metrics; no generated-table machinery |
| `cmap` format 4 + 12 | **port** subset | oracle/test layout needs codepoint→gid; no production caller reshapes |
| `cmap` format 14 (variation sequences) | **defer** | no fixture; explicit error |
| `loca`/`glyf` outlines, simple + composite | **port** FreeType-style | default `PathStyle::FreeType`; `HarfBuzz` variant → `error.Unsupported`. Critical: unhinted FreeType scaling runs through `Fixed`/`F26Dot6` (`Scale26Dot6`) and converts to f32 at the end — an f32 reimplementation will not be bit-exact |
| `gvar`/`HVAR`/`avar`, `LocationRef`/`NormalizedCoord` | **contract only, outline deltas defer** | API and cache keys carry `i16` coords; non-default coords on a variable font → `error.Unsupported` until ported |
| TrueType interpreter (`fpgm`/`prep`/`cvt`, phantom points), `HintingInstance`/`HintingOptions(Engine::AutoFallback, Target::Smooth{Lcd, symmetric_rendering:false, preserve_linear_metrics:true})` | **port** (staged, after tasks 1–5) | upstream default `hint(true)`; Roboto prefers interpreter, so hinted fixtures need it |
| autohinter (`outline/autohint/*`) | **port** (G3b autohint) | selected by `Engine::AutoFallback` for instruction-less fonts; ported with the BestEffort GSUB shaper subset, `styles_data.zig` transcribed from skrifa's generated tables. Fixture: the Noto project's unhinted `NotoSans-Regular.ttf`; 3884 glyphs × 6 sizes (0.5–2048 ppem) and 8 hinted `--dump-glyphs` vectors are byte-exact |
| CFF/CFF2 | **defer** | Roboto/Noto/`test_glyphs-glyf_colr_1` are all `glyf` |
| COLRv0/v1 + CPAL, `ColorPainter` traversal, brushes, composite modes | **port** | required by the milestone; glifo never hints COLR |
| CBDT/CBLC/sbix + PNG bitmap glyphs | **port** (T5) | `sbix`/`CBDT`/`EBDT` strike selection + decode, `png 0.18`-compatible decoder; 16-bit/Adam7 -> `error.Unsupported` |
| `FontEmbolden`/`kurbo::expand_path`/`Diagonal2` | **defer** | kurbo `expand` not ported; non-zero amount → `error.Unsupported` |
| `metrics`/advances outside the oracle | **tooling-only adapt** | scene format carries explicit gid+x, so the core never needs shaping metrics |

Provenance: `tests/fixtures/upstream/Roboto-Regular.ttf` is imported byte-for-byte from `assets/roboto/Roboto-Regular.ttf` (Apache-2.0, license copied), but **no SHA-256 is recorded** in `tests/fixtures/upstream/README.md` and `tools/import_upstream_fixtures.sh` hashes only `probe.*`. Task T2 must add `sha256sum` for every import. Do not guess the value; capture it from the pinned file once and commit it. Same treatment for `NotoColorEmoji-Subset.ttf` (OFL-1.1) and `colr_test_glyphs/test_glyphs-glyf_colr_1.ttf` when imported.

## 3. Public contracts

### `vellz.glifo` (mirrors `glifo/src/lib.rs`)
`Glyph{id:u32,x:f32,y:f32}`, `NormalizedCoord=i16`, `FontData{blob:Shared(FontBlob), index:u32}` (`id()` = blob id, upstream pointer-derived), `FontEmbolden`, `GlyphRun`, `GlyphRunBuilder` (`fontSize`, `fontEmbolden`, `glyphTransform`, `hint`, `normalizedCoords`, `atlasCache`, `fillGlyphs`, `strokeGlyphs`, `renderDecoration`), `GlyphRunRenderer`, `GlyphPrepCache`/`GlyphPrepCacheMut`/`GlyphCaches`, `OutlineCache`, `HintCache` (staged), `AtlasCacher`, `GlyphCacheKey`, `AtlasSlot`, `RasterMetrics`, `GLYPH_PADDING=1`, `GlyphAtlas`, `ImageCache`, `AtlasConfig`/`GlyphCacheConfig`, `AtlasCommand`/`AtlasCommandRecorder`/`AtlasPaint`, `DrawSink`/`GlyphRenderer`.

Zig adaptations to document: trait objects become comptime duck typing; `DrawSink`/`GlyphRenderer` methods that can allocate (fill/stroke/push layers, save/restore state) return `!void`; upstream-infallible recorder methods stay infallible; `OutlinePen` callbacks take an allocator-holding sink.

Cache ownership/invalidation (upstream semantics, to preserve):
- `Resources` owns `glyph_prep_cache` (outline cache, hint cache, underline spans) and lazily `glyph_resources` (`GlyphAtlas` + `ImageCache` + a page-sized `RenderContext` + `[]Shared(Pixmap)` pages). `RenderContext` owns the scene/encoded paints only.
- Frame protocol: `before_render` → drain pending uploads (bitmap), `replay_pending_atlas_commands` into the page renderer per page, register atlas pages; rasterize; `after_render` → `maintain`, drain evicted rects, clear page regions, unregister pages. vellz `renderWith` must call the hooks in the same order (upstream calls `before_render` before target clear).
- Key = font id, font index, glyph id, size bits, hinted, subpixel bucket (4 buckets, sentinels 4/5), packed context color, embolden bits, var coords (coords held in a second-level map, excluded from Eq/Hash). Any mutation invalidates; `clear()` drops everything; `maintain()` uses max age 64, eviction frequency 64, threshold 256; `HintCache` is a 16-entry LRU. Deterministic map type required (upstream `foldhash` fixed seed 0); Zig `AutoHashMapUnmanaged` is deterministic but its iteration/eviction order differs — pixels are unaffected (slots are disjoint and sampled at integer offsets), record as a documented divergence.

### `vello_cpu` text surface to mirror
- `RenderContext::glyph_run(&mut self, resources, font) -> GlyphRunBuilder`; `Resources{image_registry, glyph_prep_cache, glyph_resources}`; `before_render(render_mode)`, `after_render()`, `prepare_glyph_cache`, `sync_glyph_cache`, `maintain_glyph_cache`, `clear_evicted_glyph_atlas_regions`; `DEFAULT_GLYPH_ATLAS_SIZE=4096`; `ATLAS_IMAGE_ID_BASE=u32::MAX/2` (vellz already matches); `CpuGlyphRunBackend{ctx, resources, atlas_cache_enabled}` with `GlyphRunBackend::{atlas_cache, fill_glyphs, stroke_glyphs, render_decoration}`.
- Drawing surface already present upstream: `impl DrawSink for RenderContext` (`set_transform/set_paint/set_paint_transform/fill_path/fill_rect/push_clip_layer/push_clip_path/push_blend_layer/pop_layer/pop_clip_path/width/height`) and `impl GlyphRenderer` (`save_state/restore_state/stroke_path/set_paint_image/set_tint/get_context_color/current_paint/atlas_image_source/atlas_paint_transform`).
- Missing in vellz, to add: `RenderContext.glyphRun`, `setTint`/`tint`, `saveState`/`restoreState` (clone/deinit `PaintType`), `ImageRegistry.registerAtlasPage`/`destroyAtlasPage` for ids ≥ base, and small `kurbo` helpers (`PathSeg.transform`, `BezPath` element-slice exposure, `Rect.toPath` reuse for COLR clip boxes).

### Narrow Cozmic adapter
`src/cozmic_adapter.zig` defines `PositionedGlyph{glyph_id:u32, font_id:u32, font_size:f32, x:f32, y:f32}`, a caller-supplied `FontResolver` (font_id → bytes/index/shared blob id), and `drawRun(...)` that builds a `glifo.GlyphRun` and calls `fillGlyphs`/`strokeGlyphs`. Rules:
1. consumes already-positioned glyphs only — never maps characters, shapes, kerns, wraps, or reorders;
2. the core never imports Cozmic; tests bridge `cozmic.layout.LayoutGlyph`/`PhysicalGlyph` → `PositionedGlyph` (`x = p.x + p.cache_key.x_bin.asFloat()`, same for y; glyph id/size/font id from the cache key) and this bridge is the only Cozmic-aware code;
3. Cozmic y is already y-down layout space; no `FLIP_Y` (glifo applies the font-space flip internally);
4. subpixel: Cozmic's `.875` carry vs glifo's clamp-to-bucket-3 differ by ≤0.125 px; pass reconstructed fractional positions so glifo quantizes once, and document the residual;
5. synthetic embolden is only forwarded if kurbo `expand` lands; otherwise explicit `error.Unsupported` (ZUI's current FreeType bold dilation is not silently dropped).

## 4. Tests, fixtures, staged gates

Byte-exact is achievable: fixed-point 26.6 glyf scaling, `PathStyle::FreeType`, f32-scalar upstream gold (`DEFAULT_CPU_F32_TOLERANCE=0`, `diff_pixels=0`), raw `.rgba` comparison. Not achievable without extra ports: hinted outlines (interpreter), embolden. Upstream allows 55 `diff_pixels` for `glyphs_colr_test_glyphs`; vellz should aim exact and record the allowance only if the COLR pipeline can't close it, per the tolerance policy.

Oracle/scene changes needed in `tools/oracle-rs/src/main.rs`, `tools/scene.zig`, `tools/vellz_cli.zig`, `tools/oracle-rs/README.md`:
- new command `glyph_run`: `font{asset,index}`, `font_size`, `hint`, `glyph_transform`, `embolden`, `normalized_coords`, `atlas_cache`, `style:"fill"|"stroke"`, `glyphs:[{id,x,y}]`; optional `decoration{x_range,baseline_y,offset,size,buffer}`; assets relative to the scene dir (use `../fixtures/upstream/Roboto-Regular.ttf`).
- a `--dump-glyphs` mode that renders one run into a recording `DrawSink` and prints per-glyph path elements as f32 bit patterns (ground truth for T2 without rasterization).
- metadata: add `font_sha256`; keep FNV hashes; corpus gate uses the existing `tools/compare_corpus.sh`/`tools/compare_raw.py` (plan.md's `tools/compare.py` is stale naming).
- import upstream fonts (with licenses) and pin SHA-256 in `tests/fixtures/upstream/README.md`; do not consume `vello_tests/snapshots/*.png` (Git LFS, PNG variance) — reproduce the upstream scene parameters from `vello_tests/tests/glyph.rs` as JSON and regenerate `.rgba` with the pinned oracle.

Staged gates: **G3a** unhinted outline corpus (Roboto `glyphs_{filled,small,skewed,scaled,glyph_transform}_unhinted`, transform-composition rows) byte-exact with atlas cache on and off in Debug/ReleaseSafe/ReleaseFast; **G3b** hinted outline scenes through the ported interpreter; **G3c** COLR (Noto COLR + `colr_test_glyphs`) byte-exact; **G3d** Cozmic adapter consumes Cozmic output with a no-reshape assertion and pixel equality vs the same direct glyph list; **G3e** embedded bitmap corpus (`glyph_run_bitmap_noto*` + `..._transform_composition_*`) byte-exact with the atlas cache on and off; error-path tests (CFF, unsupported PNG features, embolden, non-default coords, autohint-needed font).

## 5. First five implementation tasks

**T1 — atlas infrastructure.** Files: `src/common/guillotiere.zig`, `src/common/multi_atlas.zig`, `src/common/image_cache.zig`, `src/common/root.zig`, `build.zig`. Deps: none. Acceptance: upstream tests ported (multi_atlas ~12, image_cache ~10, guillotiere ~9) green; `zig build test`; a committed 10k-op allocate/deallocate trace from a `tools/oracle-rs` dump reproduces identical offsets/ids; atlas split documented in plan.md §5 (currently promises one `common/atlas.zig`).

**T2 — font + unhinted glyf outlines + prep cache.** Files: `src/glifo/{root,font,tables/*,glyf,pen,outline_cache,glyph,util}.zig`, `src/root.zig`, oracle `--dump-glyphs`, fixture SHA. Deps: T1 not required (parallel), `kurbo`. Acceptance: for pinned (font,size,gid) vectors, emitted path elements are bit-identical to `skrifa`/glifo via `--dump-glyphs`, simple and composite; `cmap` 4/12 matches skrifa for ASCII+emoji; `OutlineCache` reuse/prune tests; Roboto SHA-256 recorded.

**T3 — render core + `vello_cpu` integration (unhinted).** Files: `src/glifo/{interface,renderer,atlas/*}.zig`, `src/cpu/text.zig`, `src/cpu/render.zig`, `src/root.zig`, `docs/cpu-pipeline.md`, `tools/`. Deps: T1, T2. Acceptance: G3a scenes byte-exact with cache off/on; upstream glifo key/renderer/glyph tests ported; resources lifecycle (lazy init, maintain, page registration, teardown) covered; `zig build test`, `zig build corpus`.

**T4 — COLR/CPAL.** Files: `src/glifo/colr.zig`, `src/glifo/tables/{colr,cpal}.zig`, `src/glifo/glyph.zig`, `src/glifo/atlas/commands.zig`, scene/oracle support. Deps: T3. Acceptance: G3c Noto COLR + `colr_test_glyphs` byte-exact (or documented 55-pixel allowance with fixture-level provenance); gradient/sweep/radial brushes, transforms, clip boxes, non-default composite modes exercised; cache-on determinism; recorder ownership (cloned gradients freed on replay/deinit) leak-tested.

**T5 — Cozmic adapter + decoration.** Files: `src/cozmic_adapter.zig`, `src/glifo/glyph.rs→.zig` decoration, `src/kurbo/bezpath.zig` (`PathSeg.transform`), `tests/cozmic_adapter_test.zig`, `build.zig` (opt-in test). Deps: T3 (outline fill/stroke), optionally T4. Acceptance: positioned-glyph mapping is 1:1 (ids/positions, no shaping calls, asserted by a counter/probe); `renderDecoration` skip-ink spans match upstream on crafted glyphs; adapter test skips explicitly when `.ports/cozmic` is absent; `zig build test`.

M3 remainder after these five: `gvar`/variation, CFF, embolden — each explicit `error.Unsupported`. (TrueType hinting, the autohinter, bitmap/PNG, decoration and the Cozmic adapter landed in T5/G3b; see `plan.md`'s ledger.)

## Evidence inspected
`plan.md` §2/§5/§9/§10/§11/§13; `README.md`; `docs/port-contracts.md`; `docs/cpu-pipeline.md`; `tests/README.md`; `tests/fixtures/upstream/README.md`; `build.zig`, `build.zig.zon`, `src/root.zig`, `src/cpu/render.zig`, `src/common/render_state.zig`, `src/common/paint.zig`, relevant `src/kurbo` APIs; `tools/{scene.zig,vellz_cli.zig,oracle-rs/src/main.rs,import_upstream_fixtures.sh}`. Upstream: all `glifo/src/*`, `vello_cpu/src/{text,text_debug,render}.rs` text paths, `vello_common/src/{multi_atlas,image_cache}.rs`, `vello_tests/tests/{glyph,util,renderer}.rs`, `vello_dev_macros/src/{test,lib}.rs`, fixture READMEs, plus registry copies of `skrifa 0.44.0`, `read-fonts 0.41.0`, `guillotiere 0.7.0`. Cozmic: `src/layout.zig`, `glyph_cache.zig`, `shape_hb.zig`, `render.zig`; ZUI `README.md` font/atlas notes and `src/fonts/{atlas,shaper}.zig`.

## Recommended plan (compact)
Port the atlas stack first, then a fixed-point-exact `glyf` outline subset with a path-dump oracle, wire it into `cpu/text.zig` with the upstream frame protocol, then COLR, then the Cozmic adapter; stage hinting/CFF/bitmap/variation/embolden behind typed errors with explicit gates G3a–G3d. Recommended M3 gate scope: unhinted outlines + COLR + adapter, with hinted parity as G3b immediately after the interpreter port.

## Risks
- Hinting interpreter is the largest item (30+ files) and gates upstream-default `hint(true)` scenes; if G3 requires hinted parity, tasks 1–5 are not enough.
- Unhinted glyf must use 26.6 `Fixed` scaling; f32 shortcuts silently break byte-exactness.
- Hash-map iteration differences vs `foldhash` fixed-state change eviction/packing order (argued pixel-invisible; needs confirmation).
- COLR exactness across composition layers/gradients is the least certain; upstream itself allows 55 pixels.
- Deferrals (CFF, embolden, variation, autohint, PNG 16-bit/Adam7) shrink coverage vs upstream test names.

## Open questions
1. Is G3 (unhinted + COLR + adapter) acceptable, or is hinted-Roboto parity required before declaring M3?
2. Approve deferring synthetic embolden, CFF/CFF2, CBDT/PNG, and variable-font outlines with typed errors?
3. Confirm hash-map/Pixmap-page ownership divergences are acceptable as documented non-pixel divergences.
4. Who captures and commits the missing Roboto/Noto/colr SHA-256 values (needs write access to `tests/fixtures/upstream/` + the import script)?
