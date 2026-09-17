# §5D: experimental element layout migration

Verified 2026-09-17 against Zlay `dbce9266163ba5400385693aebd86c0726464a94`
(the unchanged `build.zig.zon` pin).

## Run

- Default: legacy recursive layout remains in use.
- Opt in for real mounted trees: `ZUI_LAYOUT=zlay zig build run-todo` or
  `ZUI_LAYOUT=zlay zig build run-dash`.
- `zig build test-zlay`: focused adapter tests (filter also includes existing
  tests whose names contain “adapter”).
- `zig build selftest-zlay`: real todo and dashboard headless input/paint tests,
  with the environment explicitly set by the build step.
- `zig build test --summary all`: normal regression gate, including adapter
  unit tests but retaining legacy example integration by default.

`elements/layout.zig` dispatches, so no runtime/entity or Window changes are
needed. Adapter errors log before falling back to legacy. Direct calls to
`zlay_adapter.layout` propagate errors. The adapter rebuilds allocator-owned
Zlay nodes per dirty frame and copies computed bounds back into real nodes.
It does not use legacy container measure/place; only text/image intrinsic
measurement is shared. Empty containers also pass through Zlay leaf sizing.

## Coverage and semantics

- Rows/columns, gaps, four-edge container padding.
- Grow (zero basis on non-wrapped items; auto basis on wrapped rows), no shrink.
- Explicit width/height, square, full axes as parent-content percentages,
  max-width-full; auto containers stretch in columns.
- Start/center cross alignment; start/center/between main alignment.
- Absolute left/right/top and four-edge inset. Right takes precedence over left.
- Row wrapping and normal-child scroll translations.
- Existing Cozmic text measurement and retained measure→paint handoff, with
  explicit-width-only wrapping; intrinsic images and one-explicit-axis aspect.
- Paint and interaction fields remain on the original nodes. Borders stay
  paint-only rather than accidentally shrinking the content box.

Header docs define border-box sizing and unrounded f32 logical units. Agreement
fixtures use **0.001 logical units**, including fractional viewport origins,
resize, nested grow/full axes, padding/gap, wrapping, absolute offsets/inset,
scroll, alignment, square, border overlays, text and image measurements.
The public `unsupported` ledger enumerates deferred/different semantics; this
is not an all-CSS adapter. No public grid API is introduced.

### Pinned divergence fixtures

These assert both outputs rather than relaxing agreement tolerance:

| Fixture | Legacy | Zlay |
|---|---:|---:|
| Single grow=0.25 child in 100-wide row | width 100 | width 25 |
| Explicit width=20, grow=1 child in wrapped 100-wide row | width 20 (legacy explicit-size clamp) | width 100 |

Other explicit limitations in the adapter ledger include legacy overflow
clamping, full axes in indefinite parents, wrapped double-padding measurement,
leaf padding, ignored column wrapping/non-absolute offsets, and deferred CSS
style vocabulary. Full todo/dashboard geometry equivalence and visual resize
parity are **not** claimed from their behavioral selftests.

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

No Zlay source changes were made. A fresh full oracle run was attempted with
`zig build parity --summary all` in the fetched package. It is **blocked**:
`python3: can't open file .../tools/parity/run.py: [Errno 2] No such file or directory`.
The published package excludes that harness/reference checkout. Restore the
source-pinned oracle outside the dependency cache before changing the default;
the three probes are not full Taffy parity.

## Executed evidence

`zig build test test-zlay selftest-zlay --summary all`:

```text
Build Summary: 22/22 steps succeeded; 235/235 tests passed
selftest-zlay success
  todo: all 15 checks passed
  dashboard: all 22 checks passed
test-zlay: 20 pass (includes existing adapter-named tests)
test: root 213 pass; todo model 2 pass; standalone Zlay artifact cached
```

The ten new adapter tests are four agreement/measurement tests, two divergence
fixtures, one unsupported-ledger test, and three historical grid probes.
No native visual review or full application geometry snapshot parity is claimed.
