# vellz CPU benchmarks (M4)

Stage-level measurements for the CPU renderer, following the methodology in
`plan.md` §12. Generated and reproducible with `tools/bench.sh`; raw output
is committed under `out/bench-*.md` when regenerated.

## Methodology

- **Harness.** `tools/bench.zig` (`zig build bench`, wrapper `tools/bench.sh`)
  renders each scene repeatedly in-process into the same
  `RenderContext`/`Pixmap` with `RenderContext.reset` between iterations,
  exactly like a frame loop. The one-time asset decode / parse / renderer
  allocation is excluded from the per-iteration numbers and reported as
  `setup` (microseconds; usually 0-1).
- **Stages.** Per iteration the harness times:
  1. `construct` — `reset` plus replay of paints, transforms, and SVG path
     parsing (gradient stops and image handles are rebuilt every frame, as a
     frame re-submits its paints);
  2. `preprocess` — `fill_rect`/`fill_path` calls and `flush` (flatten, tile,
     strip generation);
  3. `bucket` — coarse bucketing inside `renderWith`, measured through
     `RasterizerSettings.timings` (`StageTimings.bucket_ns`);
  4. `fine` — fine rasterization inside `renderWith`
     (`StageTimings.fine_ns`); for the multi-threaded dispatcher this is the
     wall-clock wait for the parallel job;
  5. `render` — the whole `renderWith` call; 6. `total` — whole iteration.
- **Statistic.** `min` of N individually timed iterations (default; `--stat
  median` switches). The benchmark box is a shared 4-vCPU container with a
  load average around 12-16 during measurement, so the median of a whole run
  window can be biased by other tenants; the minimum is the robust estimator.
  Level speedups are computed from the selected statistic.
- **Exactness.** Every table row prints the FNV-1a hash of the rendered
  pixmap. All levels of a (scene, mode) group must print the same hash; the
  corpus is separately byte-compared against the pinned oracle at each level
  (below).
- **Modes.** `quality` = f32 kernel (`optimize_quality`), `speed` = u8 kernel
  (`optimize_speed`). Each scene is run in both modes regardless of the scene
  file's own setting.
- **Levels.** `fallback` = scalar backend, `native` = the level detected for
  the build target. `--levels fallback,sse2,sse4_2,avx2,avx512` accepts all
  names.

## Environment

| | |
| --- | --- |
| CPU | Intel(R) Xeon(R) CPU @ 2.60GHz (`icelake_server`), 4 vCPU visible |
| SIMD | AVX-512F/BW available; `Level.detect()` = `avx512` |
| OS / Zig | Linux x86_64; Zig `0.17.0-dev.2122+3e15e99e6` |
| Build | `ReleaseFast`, single-threaded dispatch (`threads=0`) |
| Warmup / runs | 10 / 100, statistic `min` |
| Load average | ~12-16 (shared container; see methodology) |

## Representative scenes (ReleaseFast, single-threaded, min of 100)

Raw output: `out/bench-ReleaseFast.md`.

| scene | mode | level | setup | construct | preprocess | bucket | fine | render | total | fnv1a |
| --- | --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| fill_wave_seams_128 | quality | fallback | 1 | 0 | 16 | 3 | 71 | 75 | 93 | 770f1deac2efa91d |
| fill_wave_seams_128 | quality | native | 1 | 0 | 16 | 3 | 71 | 75 | 92 | 770f1deac2efa91d |
| fill_wave_seams_128 | speed | fallback | 1 | 0 | 16 | 3 | 15 | 19 | 36 | 519cf39ae15b8065 |
| fill_wave_seams_128 | speed | native | 1 | 0 | 16 | 3 | 15 | 18 | 36 | 519cf39ae15b8065 |
| fill_tile_grid_128 | quality | fallback | 1 | 0 | 4 | 3 | 71 | 76 | 81 | e20328841bdd41e6 |
| fill_tile_grid_128 | quality | native | 1 | 0 | 4 | 3 | 71 | 76 | 81 | e20328841bdd41e6 |
| fill_tile_grid_128 | speed | fallback | 1 | 0 | 4 | 3 | 15 | 19 | 24 | c9e7db1fcc2b8f5d |
| fill_tile_grid_128 | speed | native | 1 | 0 | 4 | 3 | 15 | 19 | 24 | c9e7db1fcc2b8f5d |
| image_bilinear_64 | quality | fallback | 0 | 0 | 0 | 0 | 79 | 80 | 81 | 1c93dac9f6dc2006 |
| image_bilinear_64 | quality | native | 0 | 0 | 0 | 0 | 79 | 80 | 81 | 1c93dac9f6dc2006 |
| image_bilinear_64 | speed | fallback | 0 | 0 | 0 | 0 | 41 | 42 | 42 | 9a6979f278566404 |
| image_bilinear_64 | speed | native | 0 | 0 | 0 | 0 | 41 | 42 | 42 | 9a6979f278566404 |
| gradient_repeat_128 | quality | fallback | 1 | 0 | 6 | 1 | 94 | 96 | 104 | 08203a883b9c7cb1 |
| gradient_repeat_128 | quality | native | 1 | 0 | 6 | 1 | 94 | 96 | 104 | 08203a883b9c7cb1 |
| gradient_repeat_128 | speed | fallback | 1 | 0 | 6 | 1 | 34 | 36 | 44 | c49d1e4c3a0812a2 |
| gradient_repeat_128 | speed | native | 1 | 0 | 6 | 1 | 33 | 36 | 43 | c49d1e4c3a0812a2 |

Microseconds. `render` includes `bucket + fine` plus command/region setup;
`total` adds `construct + preprocess`.

## u8 (speed) vs f32 (quality)

Ratios from the table above (quality total / speed total, speed fine vs
quality fine):

| scene | total (f32/u8) | fine (f32/u8) |
| --- | ---: | ---: |
| fill_wave_seams_128 | 2.58x | 4.73x |
| fill_tile_grid_128 | 3.38x | 4.73x |
| image_bilinear_64 | 1.93x | 1.93x |
| gradient_repeat_128 | 2.42x | 2.85x |

`image_bilinear_64` is the scene plan.md §13 M4 called out as *slower* in u8
than f32 because of scalar lane loops in the u8 painters. That is fixed; see
the A/B below.

## SIMD level dispatch (fallback vs native)

Across all four scenes and both modes, `native`/`fallback` ratios are 0.98-1.01
for every stage; the fine stage is within 1% and every pixmap hash is equal.
This is expected on this build: `zig build` targets the native CPU, so LLVM
auto-vectorizes the scalar `fallback` transcriptions with the same AVX-512
instructions the explicit `@Vector` paths request. The explicit vector paths
(flatten cubic subdivision, analytic-AA fractional coverage/partial winding,
`@shuffle` helpers) are therefore a *guarantee* plus the exactness surface, not
an end-to-end speedup at these scene sizes; the corpus gates all levels
byte-exact. The measurable M4 speedup came from replacing the remaining scalar
lane loops in the u8 conversion/sampling helpers, which also applies to the
portable backend (they are element-wise and bit-identical, verified by tests).

## A/B: u8 lane-loop vectorization (`image_bilinear_64`)

Same harness, ReleaseFast, min of 100 runs, before/after commit `777d924`
(`f32ToU8`/`f32ToU32Vec` vectorized, texel words assembled with one bitcast,
lowp gradient indices converted as `f32x16`):

| path / stage | before (µs) | after (µs) | speedup |
| --- | ---: | ---: | ---: |
| speed `fine` | 102 | 41 | 2.49x |
| speed `total` | 104 | 42 | 2.48x |
| quality `fine` | 89 | 79 | 1.13x |
| quality `total` | 91 | 81 | 1.12x |

Before, the u8 path was 1.15x *slower* than f32 on this scene; after, it is
1.93x faster. The f32 path also benefits because the shared `f32_to_u32` index
and `extend` conversions are no longer scalar lane loops.

## Multi-threaded dispatch (quality, `threads=4`)

`out/bench-mt4-ReleaseFast.md`, min of 50 runs. At these scene sizes
(64x64-128x128, tenths of a millisecond) the persistent-worker synchronization
dominates, so MT is not faster than the single-threaded dispatcher; it is
recorded here for the plan's thread-count requirement. Corpus/MT pixel
equivalence (threads 1-4) is asserted in `src/cpu/render.zig`.
`optimize_speed` + MT returns `error.Unsupported` upstream, unchanged.

## Remaining scalar paths and why

- **`fallback` level** keeps the scalar transcriptions of flatten, tile, and
  the strip/coverage math. They are the byte-exact oracle reference and are
  bit-identical to the vector paths (differential tests:
  `common.flatten` "vector cubic flattening is bit-identical...",
  `common.tile` "analytic aa tiling is bit-identical..."), so the vector path
  can be selected per frame without changing output.
- **f32 bilinear/bicubic texel gather** is scalar in both upstream and this
  port (four independent pixel indices; no portable Zig gather). The index and
  weight math around it is vectorized.
- **u8 gradient LUT gather** remains a 16-entry scalar loop (as upstream); the
  index conversion and interpolation weights are `f32x16`.
- **`common/util.f32ToU8` and `cpu/fine/image.f32ToU32Vec`** have scalar
  reference implementations retained in tests only; the shipped path is
  vectorized and lane-for-lane exact (including NaN and range boundaries).

## Reproduction

```sh
# single-threaded, ReleaseFast, 100 runs per sample
tools/bench.sh --optimize ReleaseFast -- --runs 100 --warmup 10

# multi-threaded quality
tools/bench.sh --optimize ReleaseFast -- --threads 4 --modes quality

# per-level corpus exactness (byte-exact, tolerance 0)
./tools/compare_corpus.sh --level fallback
./tools/compare_corpus.sh --level avx512
```
