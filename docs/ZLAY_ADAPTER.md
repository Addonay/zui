# §5D: Zlay element layout contract

Verified 2026-09-20 against Zlay `dbce9266163ba5400385693aebd86c0726464a94`
(the unchanged `build.zig.zon` pin).

## Run

- Default: packaged Zlay layout is now canonical for mounted trees.
- Migration escape hatch: `ZUI_LAYOUT=legacy zig build run-todo` or
  `ZUI_LAYOUT=legacy zig build run-dash`.
- `zig build test-zlay`: focused adapter tests (filter also includes existing
  tests whose names contain “adapter”).
- `zig build selftest-zlay`: real todo and dashboard headless input/paint tests,
  with the environment explicitly set by the build step.
- `zig build test --summary all`: normal regression gate, including adapter
  unit tests and the canonical Zlay example integration path.

`elements/layout.zig` dispatches, so no runtime/entity or Window changes are
needed. Adapter errors log before falling back to legacy. Direct calls to
`zlay_adapter.layout` propagate errors. The adapter rebuilds allocator-owned
Zlay nodes per dirty frame and copies computed bounds back into real nodes.
It does not use legacy container measure/place; only text/image intrinsic
measurement is shared. Empty containers also pass through Zlay leaf sizing.

## Coverage and semantics

- Rows/columns, gaps, four-edge container padding.
- Grow (zero basis on non-wrapped items; auto basis on wrapped rows), explicit
  shrink and basis controls (the compatibility default remains no shrink).
- Explicit width/height, square, full axes as parent-content percentages,
  authored percentage axes, max-width-full; nested content-box resolution;
  auto containers stretch in columns.
- Start/center/end/stretch/baseline cross alignment; start/center/end/between/
  around/evenly main alignment; explicit align-content distribution.
- Visible/clip/hidden/scroll overflow values and scrollbar gutters are
  translated into Zlay. Each retained node exposes the computed scrollbar size
  and scrollable overflow region; scroll offsets remain caller-owned.
- Absolute left/right/top and four-edge inset. Right takes precedence over left.
- Row wrapping (including reverse line order) and normal-child scroll
  translations.
- Existing Cozmic text measurement and retained measure→paint handoff. Text
  with an authored percentage width is reflowed against the parent’s definite
  available width; unconstrained root text remains intrinsic. Intrinsic,
  min-content, max-content, percentage min/max, and aspect-ratio sizing are
  translated through Zlay. Images retain intrinsic size and one-explicit-axis
  aspect derivation.
- Public overflow/style vocabulary includes scrollbar gutters, text overflow
  policy, line clamping metadata, concurrent-scroll policy, and axis-lock
  policy. Zlay consumes the gutter and overflow geometry; the remaining input
  policies are retained for the platform gesture layer.
- Paint and interaction fields remain on the original nodes. Borders stay
  paint-only rather than accidentally shrinking the content box.

Header docs define border-box sizing and unrounded f32 logical units. Agreement
fixtures use **0.001 logical units**, including fractional viewport origins,
resize, nested grow/full axes, padding/gap, wrapping, absolute offsets/inset,
scroll, alignment, square, border overlays, text and image measurements.
The public `unsupported` ledger enumerates deferred/different semantics; this
is not an all-CSS adapter. The public grid API covers bounded length,
percentage, `fr`, auto, intrinsic, fit-content, and minmax tracks, explicit
line/span placement (including named lines where the pinned engine can resolve
them), and row/column dense auto-flow. Track counts remain bounded by
`max_grid_tracks`.

Baseline alignment is passed to Zlay with the first/last Cozmic run baselines
from the retained text layout. The overflow enum and scrollbar gutter are
translated, and Zlay's scrollable-overflow rectangle is retained on each node.
Scroll chaining and gesture policy remain outside this adapter.

### Pinned divergence fixtures

These assert both outputs rather than relaxing agreement tolerance:

| Fixture | Legacy | Zlay |
|---|---:|---:|
| Single grow=0.25 child in 100-wide row | width 100 | width 25 |
| Explicit width=20, grow=1 child in wrapped 100-wide row | width 20 (legacy explicit-size clamp) | width 100 |

Other explicit limitations in the adapter ledger include public grid/intrinsic
constraints, legacy overflow clamping, full axes in indefinite parents,
wrapped double-padding measurement, leaf padding, ignored column wrapping,
non-absolute offsets, and deferred CSS style vocabulary. Available-width
reflow is supported when an explicit percentage width is authored; intrinsic
min/max-content probes remain unwrapped. Full
todo/dashboard geometry equivalence and visual resize parity are **not** claimed
from their behavioral selftests.

## Historical grid re-run

Executable tests in `src/elements/zlay_adapter_test.zig` start from adapter
translation (including box sizing, gap and padding), then add test-only grid
styles to the pinned Zlay tree. They run actual grid compute; they are not
flex substitutes or empty tests. Expected values are the historical vendored
Taffy 0.14 results recorded in `plan.md`, not newly generated Rust results.

| Historical disagreement | Current pin | Historical Taffy expectation | Result |
|---|---:|---:|---|
| Second column, 40px + 20px tracks, 10px gap | x=50 | x=50 | now passes |
| Child, 100px border-box grid, 10px padding, 1fr | width=80 | width=80 | now passes |
| Child min-width=60 in fixed 40px track | width=60 | width=60 | now passes |

No Zlay source changes were made. A fresh full upstream fixture harness was
attempted with `zig build parity --summary all` in the fetched package, but the
published package excludes `tools/parity/run.py`. The pinned source checkout
itself is healthy (`cargo test --all-features`: 145 core, 107 handwritten,
6,085 XML, and 5 doctests passed), and the repository now carries a smaller
reproducible external fixture gate in `tools/run-zlay-parity.sh`. The three
historical probes and eleven external fixtures are not full Taffy parity.

## Executed evidence

Refreshed 2026-09-22 — `zig build test test-zlay selftest-zlay --summary all`:

```text
Build Summary: 31/31 steps succeeded; 3/4 tests passed (1 skipped)
test success
test-zlay success
selftest-zlay success
  todo: all checks passed
  dashboard: all checks passed
```

The single skip is `examples/todo/daybook_tests.zig`'s
"bridge snapshot carries annotated roots", which is gated on
`zui.a11y.accesskit.enabled` and only runs under `-Daccesskit=true`.
Focused gates, fresh 2026-09-22: `zig build test` **25/25 steps;
541/545 tests passed (4 skipped)**, `zig build test-zlay` **8/8 steps;
43/43 tests passed**, `zig build selftest-zlay` **11/11 steps** — all green.

The adapter tests cover agreement/measurement fixtures, explicit divergence,
unsupported-ledger behavior, alignment and overflow vocabulary, intrinsic and
percentage constraints, full bounded grid track/placement translation,
available-space text reflow, reverse flow/wrap, aspect-ratio resize, baseline
geometry, scrollbar/scroll-region reporting, named-line resolution, and
historical grid probes.
No native visual review or full application geometry snapshot parity is claimed.

Additional bounded artifact probes on 2026-09-18 rendered the seeded todo
example at `540x740` and the dashboard at `800x600` through both the legacy
and Zlay paths. Pixel comparison reported `0` differing pixels for both
pairs. This strengthens the two shipped consumers' evidence, but remains two
fixtures rather than a full Taffy/oracle parity claim; the default therefore
uses canonical Zlay while broader public-style coverage is added; legacy
remains an explicit migration escape hatch.

The pinned oracle is now restored locally and a reproducible eleven-fixture probe
is available:

```sh
bash tools/run-zlay-parity.sh
```

It runs the same row/padding/gap/grow, wrapped-line/absolute-position,
center/space-between/padding, min/max constraint, grid track/placement,
column auto-flow, aspect-ratio, reverse-flex, and reverse-wrap fixtures through
Taffy 0.14 and the real ZUI Zlay adapter and
requires byte-identical normalized
bounds. This is the first external oracle gate, not full fixture parity; the
canonical default still has documented unsupported style semantics.
