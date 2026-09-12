# Upstream fixtures

Files imported byte-for-byte from the pinned Vello checkout
(`1e63b4a40ccb484f82e1d85b83df97ab95bcfbe7`). Imported rather than
regenerated so tests never need a Rust toolchain or Git LFS.

| File | Source | License / provenance |
| --- | --- | --- |
| `probe.rgba` | `vello_common/assets/probe.rgba` | Original to the Vello repository, Apache-2.0 OR MIT. Unpremultiplied RGBA8, 51×51, produced by `regenerate_probe_reference` with `Level::fallback`, 0 threads, `OptimizeQuality`. Upstream compares all four channels with tolerance 3 and feature-bitmask statistics. |
| `probe.png` | `vello_common/assets/probe.png` | Same as above; preview only. |
| `Roboto-Regular.ttf` | `assets/roboto/Roboto-Regular.ttf` | Apache-2.0; see `Roboto-LICENSE.txt`. Used for positioned-glyph tests in Milestone 3. |
| `Roboto-LICENSE.txt` | `assets/roboto/LICENSE.txt` | Apache-2.0 notice. |
| `NotoColorEmoji-Subset.ttf` | `assets/noto_color_emoji/NotoColorEmoji-Subset.ttf` | OFL-1.1; see `NotoColorEmoji-LICENSE.txt`. 44 glyphs, `glyf` + `COLR`/`CPAL`, cmap formats 4/12/14: the format 12 and variation-sequence fixture. |
| `NotoColorEmoji-CBTF-Subset.ttf` | `assets/noto_color_emoji/NotoColorEmoji-CBTF-Subset.ttf` | OFL-1.1. Bitmap-only (`CBDT`/`CBLC`): the `error.Unsupported` fixture for non-`glyf` outlines. |
| `NotoColorEmoji-LICENSE.txt` | `assets/noto_color_emoji/LICENSE.txt` | OFL-1.1 notice (covers both Noto files). |
| `test_glyphs-glyf_colr_1.ttf` | `assets/colr_test_glyphs/test_glyphs-glyf_colr_1.ttf` | Apache-2.0; see `colr_test_glyphs-LICENSE.txt`. The upstream COLRv1 test font ("Font is taken from https://github.com/googlefonts/color-fonts"): COLRv0 glyphs 168..175 plus a COLRv1 paint graph exercising layers, solids, linear/radial/sweep gradients, glyph clips, all transform formats and all composite modes; also carries the CPAL fixture used by the COLR tests. Not a Git LFS object (`file` header, not a pointer). |
| `colr_test_glyphs-LICENSE.txt` | `assets/colr_test_glyphs/LICENSE.txt` | Apache-2.0 notice. |

SHA-256:

```text
88ff34af8db521e5e2520719706bc24388e7e976ac02dd818b867e0f6a8e0d13  probe.png
01c87c436d7b3cfaa357dfaad9259f57b4fdcb27a62da9658afb10056ee54bea  probe.rgba
319cff6e7a31f0f2a41c475dca42890aa5d19fe16017e2290f8c1d4e14f76481  Roboto-Regular.ttf
467e3e7074b6cdf8bbb7795124eb88f87a08934f1446d5716795554cfb6e00cb  NotoColorEmoji-Subset.ttf
b505bbd72ed997810e346931fa31f3bc59d1e131080182de959c4978ea20eb45  NotoColorEmoji-CBTF-Subset.ttf
8aa611b1ca97044ac6f13dc982fde29256612f0a5acc6ef47ca541a7a5b99b28  test_glyphs-glyf_colr_1.ttf
0cec06e0e55fbc3dc5cee4fca9b607f66cb8f4e4dbcf3b3c013594dd156732e9  colr_test_glyphs-LICENSE.txt
```

The SHA-256 values were computed from the pinned checkout with `sha256sum`
(2026-09-12) and are re-printed by `tools/import_upstream_fixtures.sh`.
`zig build test` reads the fonts directly; the M3 T2 oracle gate
(`tools/compare_glyphs.sh`, `zig build glyphs`) hashes the canonical glyph
dumps instead of the fonts, because the comparison is on f32 path data.

The `probe.rgba` scene is defined in `vello_common/src/probe.rs` (upstream) and
is ported in `src/common/probe.zig`; `vellz.cpu.probe.renderProbePixmap`
renders it with the exact reference settings. As of 2026-09-11 the f32/scalar
port is byte-exact against this fixture, checked by the embedded-fixture test
in `zig build test` and by `zig build probe`
(`vellz-cli --probe` + `tools/compare_raw.py`). The upstream tolerance-3
policy is what `vellz.common.probe` implements, so both checks always report
the measured maximum channel difference instead of silently relying on the
tolerance.

Upstream `vello_tests/snapshots/*.png` (523 files, Git LFS) are the broader
gold corpus. They are imported one at a time together with the ported scene
code that produced them, together with their SHA-256, rather than wholesale.
