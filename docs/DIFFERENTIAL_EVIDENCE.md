# GPUI/ZUI differential evidence

This workstream adds a reproducible comparison protocol for six high-risk
parity families. It does not change ZUI runtime code and it does not turn a
matching synthetic record into a full parity claim.

Run from the repository root:

```sh
python3 -m unittest discover -s tools/differential -p 'test_*.py'
bash tools/run-differential.sh
```

The runner compiles `tools/differential/gpui_oracle.rs` against the pinned
source revision represented by `.references/gpui`, emits the ZUI side through
`zig build differential-zui`, and compares JSONL records with the tolerances
in `tools/differential/fixtures.json`. Record identity is `(fixture, case)`;
missing, duplicate, or extra records fail the run. Floating-point tolerance is
per fixture, while text ranges, traces, list indices, and scene digests are
exact.

## Evidence levels

| Domain | Current executable evidence | What it proves | What it does not prove |
| --- | --- | --- | --- |
| layout geometry | pinned Taffy/Zlay oracle plus three shared records | the selected flex/percentage/absolute fixtures agree | all GPUI style vocabulary, intrinsic text baselines, or visual output |
| animation values | GPUI `spring.rs` source-shaped Rust probe vs public ZUI `SpringConfig` | analytic spring states agree for three damping regimes and retargeting | animation scheduling, compositor timing, or every GPUI animation helper |
| input traces | shared deterministic capture/target/bubble contract records | the selected propagation traces are stable and schema-comparable | native touch/pen/drag delivery and hit testing |
| text ranges | shared UTF-8 fixture records | the selected range representation is reproducible | font shaping, glyph geometry, IME, or grapheme policy beyond these fixtures |
| scene digests | shared command-digest records plus `zig build gpu-offscreen-diff` | command ordering is exact and the retained alpha/gradient/rounded/path/image fixture has zero CPU/WGPU pixel mismatches (max delta 2) | full scene vocabulary, GPU batching, or live device-loss behavior |
| virtualized lists | shared one-million-row range records | the bounded-range contract is reproducible | row measurement, variable heights, scrolling physics, or allocation profiles |

Only the animation rows currently execute a direct implementation comparison in
this repository: the Rust probe follows the pinned GPUI spring implementation
and the ZUI probe calls `zui.animation.SpringConfig`. The other records are
contract fixtures pending dedicated GPUI adapters; they are deliberately
included so a future adapter cannot silently change the schema or tolerance.

## Reproducibility rules

- Keep `.references/gpui` pinned and record source paths in `fixtures.json`.
- Do not use wall-clock values, random seeds, locale-dependent formatting, or
  machine-specific paths in JSONL output.
- Keep geometry and animation values in decimal form with bounded precision;
  compare them using the declared tolerance rather than string formatting.
- Keep traces, UTF-8 ranges, list windows, and scene digests exact.
- A new fixture must add both a source path and a test case before its parity
  matrix row can be strengthened.
- A passing differential run is evidence for the named cases only. It is not a
  license to mark a GPUI source-family row `Complete` without the row's other
  API, platform, and native validation gates.

The existing `tools/run-zlay-parity.sh` remains the authoritative external
Taffy layout runner; this protocol is the common envelope for the additional
domains and intentionally does not replace that more detailed layout probe.
