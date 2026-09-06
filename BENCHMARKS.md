# ZUI layout benchmark report

Date: 2026-09-06  
Host: AMD Ryzen 5 5625U with Radeon Graphics, 12 logical CPUs, x86_64  
Zig: 0.17.0-dev.1980+e78ea8f2c  
Reference: vendored Taffy 0.14.0

## Method

ZUI was compiled with the `bench-layout` `ReleaseFast` build step. Each
iteration builds a fresh fixed-capacity tree outside the timed interval and
times one cold `computeRoot` call. The tree-creation rows time construction
only. Progress is printed to stderr before every case.

The direct commands used for the final run were equivalent to:

```text
zig build bench-layout -Doptimize=ReleaseFast
cargo build --release --manifest-path src/layout/bench/Cargo.toml
```

The host mounts the repository's `/home` cache read-only to Zig's cache
syscalls, so the final verification ran the exact `build.zig` steps from a
writable `/tmp` copy. The generated binaries and source graph are identical;
the fallback direct command, when needed, was:

```text
zig build-exe --dep layout -Mroot=src/layout/bench.zig \
  -Mlayout=src/layout_module.zig -OReleaseFast \
  --cache-dir /tmp/zui-cache --global-cache-dir /tmp/zui-global \
  -femit-bin=/tmp/zui-layout-bench
```

Taffy's release library and the local comparison runner were built with
`cargo build --release`. The vendored Criterion flex/grid benchmark binaries
were also built with `cargo build --release --benches` and smoke-run with
`--noplot --measurement-time 0.1 --warm-up-time 0.1 --sample-size 10`.

## ZUI results

`ns/layout` is the mean wall-clock nanoseconds per cold layout. `layouts/s` is
the reciprocal throughput. Checksums make accidental dead-code elimination or
empty-tree runs visible.

| suite | case | nodes | iterations | ns/layout | layouts/s | checksum |
|---|---|---:|---:|---:|---:|---:|
| tree_creation | fixed-capacity tree | 1000 | 50 | 8666.5 | 115387 | 100050.0 |
| tree_creation | fixed-capacity tree | 3000 | 20 | 25827.4 | 38719 | 120020.0 |
| flat_flex | fixed row | 1000 | 20 | 76856.3 | 13011 | 400000.0 |
| flat_flex | fixed row | 3000 | 10 | 389985.3 | 2564 | 200000.0 |
| huge_nested | huge nested | 1000 | 20 | 1030587.9 | 970 | 400000.0 |
| huge_nested | huge nested | 3000 | 10 | 2080566.0 | 481 | 200000.0 |
| wide | 2-level wide | 1000 | 20 | 73218.7 | 13658 | 400000.0 |
| wide | 2-level wide | 3000 | 10 | 242335.8 | 4127 | 200000.0 |
| deep_random | 12-level random | 1000 | 20 | 100296.3 | 9970 | 400000.0 |
| deep_random | 14-level random | 3000 | 10 | 302750.7 | 3303 | 200000.0 |
| deep_auto | 12-level auto | 1000 | 20 | 1559206.7 | 641 | 400000.0 |
| deep_auto | 14-level auto | 3000 | 10 | 4435610.8 | 225 | 400000.0 |
| super_deep | depth 50 | 50 | 50 | 183669.4 | 5445 | 1000000.0 |
| grid_wide | 4x4 | 17 | 50 | 2422.9 | 412735 | 1000000.0 |
| grid_wide | 16x16 | 257 | 20 | 29760.8 | 33601 | 400000.0 |
| grid_wide | 63x63 | 3970 | 5 | 723091.8 | 1383 | 100000.0 |
| grid_deep | 2x2, 5 levels | 1365 | 10 | 194628.4 | 5138 | 200000.0 |
| grid_deep_3 | 3x3, 4 levels (cap-limited) | 4095 | 5 | 494746.4 | 2021 | 100000.0 |
| grid_superdeep | 1x1, depth 50 | 51 | 50 | 13735.5 | 72804 | 1000000.0 |
| mixed | depth 2 width 4 | 21 | 50 | 4280.8 | 233603 | 1000000.0 |
| mixed | depth 4 width 6 (cap-safe substitute for width 8) | 1555 | 10 | 340441.4 | 2937 | 200000.0 |

## Taffy 0.14 reference results

This runner uses fixed 10×20 flex leaves and fixed 20×20 grid leaves, the same
overlap inputs used by ZUI's `flat_flex` and `grid_wide` rows. Taffy's setup is
outside `Instant::now()` for layout rows; tree-creation rows include tree
construction, matching the Taffy `tree_creation` family.

| suite | case | nodes | iterations | ns/layout | layouts/s | checksum |
|---|---|---:|---:|---:|---:|---:|
| tree_creation | new + children | 1000 | 50 | 146032.4 | 6848 | 50050.0 |
| tree_creation | new + children | 3000 | 20 | 468624.2 | 2134 | 60020.0 |
| tree_creation | new + children | 10000 | 5 | 3860346.6 | 259 | 50005.0 |
| tree_creation | new + children | 100000 | 1 | 80611889.0 | 12 | 100001.0 |
| flex_flat | row | 1000 | 20 | 266565.8 | 3751 | 200400.0 |
| flex_flat | row | 3000 | 10 | 784115.1 | 1275 | 300200.0 |
| flex_flat | row | 10000 | 5 | 3285219.8 | 304 | 500100.0 |
| flex_flat | row | 100000 | 1 | 91428313.0 | 11 | 1000020.0 |
| grid_wide | 4x4 | 17 | 20 | 16150.6 | 61917 | 3200.0 |
| grid_wide | 16x16 | 257 | 10 | 411363.3 | 2431 | 6400.0 |
| grid_wide | 31x31 | 962 | 5 | 1279167.0 | 782 | 6200.0 |
| grid_wide | 63x63 | 3970 | 3 | 6038434.3 | 166 | 7560.0 |
| grid_wide | 100x100 | 10001 | 1 | 23096078.0 | 43 | 4000.0 |
| grid_wide | 316x316 | 99857 | 1 | 409187336.0 | 2 | 12640.0 |
| grid_deep | 2x2, 5 levels | 1366 | 5 | 6751314.2 | 148 | 6400.0 |
| grid_deep | 3x3, 4 levels | 7382 | 10 | 39609260.6 | 25 | 32400.0 |
| grid_deep | 2x2, 7 levels | 21846 | 1 | 114844219.0 | 9 | 5120.0 |
| grid_superdeep | 1x1, depth 100 | 101 | 5 | 896102.2 | 1116 | 200.0 |
| grid_superdeep | 1x1, depth 1000 | 1001 | 1 | 12122489.0 | 82 | 40.0 |
| deep_chain | depth 50 | 50 | 20 | 167918.5 | 5955 | 39200.0 |
| deep_chain | depth 100 | 100 | 10 | 344706.4 | 2901 | 39600.0 |

## Direct overlap

The useful apples-to-apples points are fixed leaves with the same viewport and
the same node/track counts. These ratios are derived from the tables above;
they are one run on one host, not a universal language benchmark.

| case | ZUI ns | Taffy ns | ZUI throughput result |
|---|---:|---:|---:|
| tree creation, target 1000 | 8666.5 | 146032.4 | ZUI 16.9× faster |
| tree creation, target 3000 | 25827.4 | 468624.2 | ZUI 18.1× faster |
| flat flex, 1000 | 76856.3 | 266565.8 | ZUI 3.5× faster |
| flat flex, 3000 | 389985.3 | 784115.1 | ZUI 2.0× faster |
| grid, 4×4 | 2422.9 | 16150.6 | ZUI 6.7× faster |
| grid, 16×16 | 29760.8 | 411363.3 | ZUI 13.8× faster |
| grid, 63×63 | 723091.8 | 6038434.3 | ZUI 8.4× faster |
| deep chain, depth 50 | 183669.4 | 167918.5 | ZUI 1.1× slower |

The ZUI flex rows are faster at the comparable fixed inputs, but the engine is
not yet feature-equivalent to Taffy. The current performance result should not
be read as “ZUI is faster than Taffy” for arbitrary CSS layouts: ZUI has a
smaller fixed-capacity data model and deliberately omits several web-layout
features.

## Coverage and intentional limits

The ZUI harness covers every family in Taffy's `flexbox.rs`, `grid.rs`,
`mixed.rs`, and `tree_creation.rs`. Cases that exceed ZUI's 4096-node pool are
represented by the largest legal case and labelled `cap-limited` or
`cap-safe substitute`. Taffy's original 10k/100k flex and 100/316-track grid
rows are still run by the release comparison binary.

Implemented and tested in this checkout:

- flex row/column and reverse directions, RTL rows, greedy wrapping,
  grow/shrink, min/max freezing, gaps, `justify-content`, `align-content`,
  `align-items`/`align-self`, auto margins, and aspect-ratio transfer;
- block vertical flow with explicit widths, margins and gaps;
- grid fixed/percentage/intrinsic/fractional tracks, integer repeats,
  explicit placement, spans, implicit tracks, sparse/dense auto-flow and
  track gaps;
- recursive measure hooks, min-content hooks, absolute insets, hidden
  subtrees, cache keys, dirty propagation, and device-pixel edge rounding;
- fixed-capacity tree creation and cold-layout stress runs with progress.

Not claimed as exact Taffy parity yet: baseline metrics (baseline currently
falls back to flex-start), flex-wrap balancing, margin collapsing/floats/
fragmentation, CSS named grid lines, auto-fit/auto-fill, subgrid, masonry,
scrollbar sizing and Taffy's detailed layout/scroll metadata. Those are the
remaining work before a “passes all Taffy fixtures” claim would be honest.

## Research notes

The implementation choices are grounded in the upstream mechanisms rather than
inferred from the timings alone:

- Taffy's low-level example exposes `compute_cached_layout`, `CacheTree` and a
  cache key carrying layout inputs; ZUI follows that shape with fixed slots:
  [Taffy custom-tree cache example](https://github.com/DioxusLabs/taffy/blob/main/examples/custom_tree_owned_unsafe.rs).
- Taffy's current discussion of scoped invalidation identifies propagation to
  the root as a real cost for small interactive changes. ZUI's dirty ancestor
  walk plus deferred intrinsic reflow is the fixed-pool response:
  [Taffy issue #917](https://github.com/DioxusLabs/taffy/issues/917).
- CSS layout containment documents the general principle that an isolated
  subtree can stop internal layout effects from escaping. ZUI does not claim
  CSS containment semantics yet, but its relayout boundary is designed around
  the same future extension point:
  [MDN `contain`](https://developer.mozilla.org/en-US/docs/Web/CSS/Reference/Properties/contain).
