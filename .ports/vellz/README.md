# vellz

A standalone Zig port of the [Vello] 2D rendering family, tracking the pinned
upstream revision recorded in [`tools/pin.env`](tools/pin.env) and the `pins`
struct in [`build.zig`](build.zig):

| Component | Upstream | Revision |
| --- | --- | --- |
| shared core | `vello_common` 0.2.0 | `1e63b4a40ccb484f82e1d85b83df97ab95bcfbe7` |
| CPU renderer | `vello_cpu` 0.2.0 | `v0.10.0-51-g1e63b4a4`, 2026-09-11 |
| GPU renderer | `vello_gpu` 0.2.0 | |
| shaders | `vello_gpu_shaders` 0.2.0 | |
| glyph rendering | `glifo` 0.3.0 | |

Upstream `research/` (the older compute-centric renderer) is deliberately not
part of the target. The GPU backend will use the sibling [`.ports/wgpu`](../wgpu)
package (wgpu-native `v29.0.1.1`) rather than re-binding the C API locally.

## Status

**Milestones 1, 2, and 4 complete (G1, G2, and G4 met 2026-09-12); the M4 u8,
multithreaded, and SIMD CPU pipelines have landed.** The CPU renderer produces
premultiplied RGBA8 pixels through the full upstream pipeline (path encoding →
flatten → tiles → sparse strips → coarse bucketing → fine rasterization) and
every scene in the shared corpus — solid fills, strokes, gradients, images,
layers, masks, filter layers, and blurred rounded rectangles, each also in its
low-precision `*_speed` variant — is
**byte-exact against the pinned upstream oracle** (`tolerance=0`, all four
channels) in Debug, ReleaseSafe, and ReleaseFast:

```sh
zig build test     # 953/953 unit and integration tests (936 lib + 8 scene
                   #   + 4 adapter + 5 Cozmic bridge; the bridge skips when
                   #   the .ports/cozmic sibling checkout is absent)
zig build corpus   # 148/148 corpus scenes byte-exact vs the upstream oracle
zig build probe    # upstream probe fixture, byte-exact (tolerance-3 policy)
zig build glyphs   # outlines/cmap byte-identical to upstream skrifa/glifo (glyf, CFF, CFF2, gvar/cvar, autohint, embolden)
zig build bench    # per-stage CPU benchmarks (see docs/benchmarks.md)
```

GPU (`-Dgpu=true`): `gpu-corpus` gates 75 scenes against the pinned CPU oracle
under the documented tolerance registry (most byte-exact or max-abs 1, the rest
at max-abs 2 with recorded AA/rounding reasons; multi-pass filter graphs remain
typed `error.Unsupported`, and the mask adapt is documented in `tests/README.md`),
plus typed device-loss/unsupported-capability error tests.

Coverage: antialiased fills, translucent overlap, NonZero/EvenOdd, nested
clips and isolated clip layers, transforms, round-capped strokes, degenerate
and empty scenes, tile seams, wide curvature at 128×128, linear/radial/sweep
gradients with LUT/repeat extend, nearest/bilinear image sampling with
reflect, opacity and multiply-blend layers, alpha/luminance masks, filter
layers (flood, offset, gaussian blur, drop shadow and shadow-only, composed
with clip/opacity/blend), analytic blurred rounded rectangles (normal and
inverted), the ported upstream probe scene (solid, alpha blending, gradient,
nearest/bilinear images, opacity layer, difference blend, rotation), the u8
`optimize_speed` pipeline (16 `*_speed` scenes, u8-native LUT gradients and
bilinear images), and multithreaded f32 dispatch (1–255 threads, byte-identical
to single-threaded). The imported upstream `probe.rgba` fixture is byte-exact
(tolerance policy 3, measured difference 0).

Progress toward M3 and M5 (both staged): the glyph outline engine is ported and
bit-exact against upstream `skrifa`/`glifo` — sfnt/`head`/`maxp`/`hhea`/`hmtx`/
`loca`/`glyf`/`cmap` parsing with fixed-point 26.6 scaling, simple/composite
outlines, `gvar`/`cvar` variation deltas with IUP and phantom points, and the
TrueType hinting interpreter (`fpgm`/`prep`/`cvt`, phantom points,
`HintingInstance`/`HintCache`, `GETVARIATION`), plus the unhinted CFF/CFF2
scaler (`cff.zig`: Type2 charstrings, flex, `seac`, CFF2 `blend`/`vsindex`;
`tables/cff.zig` + `tables/variations.zig`: INDEX/DICT/charset/FDSelect and
item variation store scalars) behind a format-neutral `glyf`/CFF dispatch
(`outlines.zig`), and the `Engine::AutoFallback` autohinter (`autohint/`, the
ported generated style tables; instruction-less Noto Sans/Mono/Devanagari) —
compared across 60 glyph vectors (2,335,632 path elements / 6,812,052 f32
coordinates; Roboto size sweeps hinted and unhinted, Noto and colour Noto,
Source Serif CFF/CFF2, the Inconsolata variable font at both axes, and the
autohinted Noto Sans/Mono/Devanagari) and
5 cmap vectors (458,752 mappings) at tolerance 0 (`zig build glyphs`) — and
the atlas stack
(`guillotiere`, `multi_atlas`, `image_cache`) is ported with a Rust-golden
placement trace. T3 wires the stack end to end: positioned `glyph_run` scenes
(fill/stroke, transform absorption, skew, glyph transforms, gradient paint)
render through `vellz.glifo` + `vellz.cpu` byte-exact against the pinned
oracle with the glyph atlas cache on and off (15 new scenes; tolerance 0). T4
adds COLRv0/v1 + CPAL (paint-graph traversal, linear/radial/sweep gradients,
transforms, clip boxes, composite modes, palette and foreground colors) and
its 27-scene G3c corpus. G3b adds 7 hinted `glyph_run` scenes (fill, atlas
cache on/off, scaled, horizontally skewed, glyph transform, transform
composition, composite-heavy accented glyphs), all byte-exact against the
pinned oracle. T5 adds the skip-ink decoration path
(`renderDecoration`: underline/overline/strikethrough spans, buffer,
transforms; 6 new scenes mirroring `vello_tests`' decoration cases and an
oracle `--dump-decoration` span dump) and the opt-in Cozmic adapter
(`vellz.cozmic_adapter`, never a dependency of the rendering core): it maps
already-positioned glyphs 1:1 onto `glifo.GlyphRun` runs and is gated by a
bridge test that renders byte-identical pixels to a direct `glyph_run`, with
an explicit skip when `.ports/cozmic` is absent. T5 also ports embedded
bitmap glyphs (`CBDT`/`CBLC`, `sbix`, `EBDT`/`EBLC`) through the upstream
COLR > bitmap > outline cascade with the pending-upload atlas path and a
`png 0.18`-compatible decoder, plus a 5-scene G3e bitmap corpus (Noto CBTF
colour emoji: fill, stroke, cache on/off, transform-composition rows). `sbix`
and `EBDT`/`EBLC` are covered by synthetic-font unit tests (the pinned assets
gate `CBDT`/`CBLC` end to end); PNG 16-bit and Adam7 payloads are decoded
like `png 0.18` (`STRIP_16` high-byte strip, sparse deinterleaving) and
unit-tested against synthetic streams because the pinned fonts only carry
8-bit non-interlaced PNGs. T6 closes the variable-font deferral: `gvar` deltas (simple,
composite, empty glyphs, shared tuples, IUP and phantom points), `cvar` CVT
deltas during hint-instance setup, second-level variable maps in the outline
and glyph-atlas caches, and normalized coordinates through
`GlyphRunBuilder.normalizedCoords` and the scene/oracle tooling. The pinned
`Inconsolata.ttf` (OFL-1.1: `wght` + `wdth` axes, `gvar`/`HVAR`/`avar`, hinted
bytecode) gates 15 dump vectors and a 12-scene `glyph_run_var_*` corpus
(wght min/max, wdth, both axes, composites, stroke, hint and atlas-cache
variants). G3b-autohint ports `Engine::AutoFallback` (`hinting.zig` selects
the interpreter or `autohint/`): the deprecated-shaper-equivalent generated
style tables, blue zones, edge hinting, Latin/monospace/Indic script groups,
and the `HintCache` engine swap. The pinned instruction-less
`NotoSans-Regular`/`NotoSansMono`/`NotoSansDevanagari` (OFL-1.1, unhinted
build tree) gate 12 `glyph_run_autohint_*` scenes (fill, small, skew, scale
absorption, composites, transform-composition rows, cache on/off) and 14 dump
vectors, all byte-exact at tolerance 0. Synthetic embolden (`FontEmbolden` +
`kurbo.expandPath`, backed by the ported `kurbo` `arc`/`expand`) is applied
after hinting and before the bbox, flows through the atlas/outline cache keys
(amount/join/miter/tolerance bits, upstream's explicit `join_bits`) and
decoration skip-ink extents; the 6 `glyph_run_embolden*` scenes and 4 dump
vectors are byte-exact. All of
it renders byte-exact against the pinned oracle, atlas cache on and off
(148/148 corpus, tolerance 0). The GPU side has the wgpu-native device
bootstrap, the full host/shader layout
contract, the schedule/layer executor, encoded paints (gradients and images),
the image atlas + GPU glyph text (`gpu/resources.zig`, `gpu/text.zig`), the
documented mask adapt (`gpu/mask.zig` + `mask.wgsl`; upstream `vello_gpu`
panics on mask layers), GPU filters, and a 75-scene `gpu-corpus` gate (the
per-scene tolerance registry plus typed
device-loss/unsupported-capability/missing-binding/feedback-loop errors)
running on the llvmpipe software adapter.

Not yet implemented (explicit typed errors, never placeholder pixels): CFF
hinting (`skrifa/cff/hint.rs`), `HVAR` advance deltas on CFF2/variable
outlines, COLRv1 `Var*` paint deltas at non-default coordinates, and hinted
advances from `hdmx` without backward compatibility (all typed
`error.Unsupported`); GPU multi-pass filter graphs and the full G5 corpus (M5
remainder). G4 is met: `zig build corpus` is byte-exact at every
SIMD level (`fallback`, `sse2`, `sse4_2`, `avx2`, `avx512`), with per-stage
benchmarks in `docs/benchmarks.md` (u8-vs-f32 speedups 1.9–3.4× on the
representative scenes). MT filter layers and u8 + MT return
`error.Unsupported` (documented upstream limitations). See
[`plan.md`](plan.md) for the ledgers and milestones.


## Layout

```text
.ports/vellz/
  build.zig            package build (CPU always, GPU via -Dgpu=true)
  build.zig.zon        manifest; lazy path dependency on ../wgpu
  README.md
  plan.md              architecture, ledger, milestones
  docs/                port contracts, CPU pipeline interfaces, GPU/shader maps
  src/
    root.zig           public entry point
    kurbo/             port of kurbo 0.13.1 (geometry, paths, SVG, stroke)
    peniko/            port of peniko 0.6.1 + color 0.3.3
    simd/              portable fearless_simd equivalent
    common/            port of vello_common
    cpu/               port of vello_cpu
    gpu/               port of vello_gpu (only with -Dgpu=true)
  examples/cpu_basic.zig
  tests/               scenes, oracle fixtures, integration notes
  tools/               pin.env, oracle driver, comparison tools, CLI
  .reference/vello/    pinned upstream checkout (ignored, never distributed)
```

## Building

CPU-only, no GPU dependency:

```sh
zig build test                  # unit + integration tests
zig build check                 # compile without running
zig build corpus                # corpus gate: 148 scenes byte-exact vs pinned fixtures
zig build probe                 # upstream probe fixture (tolerance-3 policy)
zig build run-cpu-example       # writes cpu_example.ppm
zig build vellz-cli             # corpus renderer CLI -> zig-out/bin
zig build bench                 # per-stage CPU benchmark (docs/benchmarks.md)
```

GPU backend (resolves the sibling `../wgpu` package and links wgpu-native):

```sh
zig build -Dgpu=true check      # currently fails with a Milestone 5 notice
```

## Reconstructing the oracle

The upstream checkout is only needed to regenerate reference images and to
inspect the pinned sources while porting. It is excluded from the package
distribution.

```sh
tools/fetch-reference.sh
tools/render_corpus.sh --check           # verify committed fixtures
tools/oracle-rs/target/release/vellz-oracle --scene ... --out ...
tools/generate_shaders.sh                # refresh checked-in WGSL (GPU)
```

`tools/oracle-rs` is our own Rust driver around the pinned `vello_cpu`;
`tools/compare_corpus.sh` renders the shared corpus with `vellz-cli` and
compares raw premultiplied RGBA8 byte-for-byte. `tools/check_probe.sh` renders
the ported upstream probe scene and compares it against the imported
`tests/fixtures/upstream/probe.rgba`. See
[`tests/README.md`](tests/README.md) and
[`docs/gpu-compatibility.md`](docs/gpu-compatibility.md).

## Third-party notices

The ported algorithms and the fixture scenes derive from Vello
(`Apache-2.0 OR MIT`); upstream copyright and license notices are retained in
the source files and in `tests/fixtures/`. wgpu-native is `MIT OR Apache-2.0`.

[Vello]: https://github.com/linebender/vello
