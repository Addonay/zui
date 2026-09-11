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

**Milestone 1 complete (G1 met 2026-09-11); Milestone 2 CPU features
oracle-verified.** The CPU renderer produces premultiplied RGBA8 pixels through
the full upstream pipeline (path encoding → flatten → tiles → sparse strips →
coarse bucketing → f32 fine rasterization) and every scene in the shared
corpus — solid fills, strokes, gradients, images, layers, and masks — is
**byte-exact against the pinned upstream oracle** (`tolerance=0`, all four
channels) in Debug, ReleaseSafe, and ReleaseFast:

```sh
zig build test     # 553/553 unit and integration tests
zig build corpus   # 22/22 corpus scenes byte-exact vs the upstream oracle
zig build probe    # upstream probe fixture, byte-exact (tolerance-3 policy)
```

Coverage: antialiased fills, translucent overlap, NonZero/EvenOdd, nested
clips and isolated clip layers, transforms, round-capped strokes, degenerate
and empty scenes, tile seams, wide curvature at 128×128, linear/radial/sweep
gradients with LUT/repeat extend, nearest/bilinear image sampling with
reflect, opacity and multiply-blend layers, alpha/luminance masks, and the
ported upstream probe scene (solid, alpha blending, gradient, nearest/bilinear
images, opacity layer, difference blend, rotation).

Not yet implemented (explicit errors, never placeholder pixels): filter
layers (gaussian blur, drop shadow, flood, offset), blurred rounded
rectangles, and u8-speed rasterization on the CPU; multithreading; glyph
rendering; the GPU backend. See [`plan.md`](plan.md) for the ledgers and
milestones.

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
zig build corpus                # G1 corpus gate against pinned oracle fixtures
zig build probe                 # upstream probe fixture (tolerance-3 policy)
zig build run-cpu-example       # writes cpu_example.ppm
zig build vellz-cli             # corpus renderer CLI -> zig-out/bin
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
