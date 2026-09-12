# Upstream fixtures

Files imported byte-for-byte from the pinned Vello checkout
(`1e63b4a40ccb484f82e1d85b83df97ab95bcfbe7`) or, for the CFF faces, from the
pinned Adobe Fonts Source Serif 4 release commit below. Imported rather than
regenerated so tests never need a Rust toolchain or Git LFS.

| File | Source | License / provenance |
| --- | --- | --- |
| `probe.rgba` | `vello_common/assets/probe.rgba` | Original to the Vello repository, Apache-2.0 OR MIT. Unpremultiplied RGBA8, 51×51, produced by `regenerate_probe_reference` with `Level::fallback`, 0 threads, `OptimizeQuality`. Upstream compares all four channels with tolerance 3 and feature-bitmask statistics. |
| `probe.png` | `vello_common/assets/probe.png` | Same as above; preview only. |
| `Roboto-Regular.ttf` | `assets/roboto/Roboto-Regular.ttf` | Apache-2.0; see `Roboto-LICENSE.txt`. Used for positioned-glyph tests in Milestone 3. |
| `Roboto-LICENSE.txt` | `assets/roboto/LICENSE.txt` | Apache-2.0 notice. |
| `NotoColorEmoji-Subset.ttf` | `assets/noto_color_emoji/NotoColorEmoji-Subset.ttf` | OFL-1.1; see `NotoColorEmoji-LICENSE.txt`. 44 glyphs, `glyf` + `COLR`/`CPAL`, cmap formats 4/12/14: the format 12 and variation-sequence fixture. |
| `NotoColorEmoji-CBTF-Subset.ttf` | `assets/noto_color_emoji/NotoColorEmoji-CBTF-Subset.ttf` | OFL-1.1. Bitmap-only (`CBDT`/`CBLC`): one 109 ppem colour strike whose four glyphs carry 32-bit indexed PNGs (`PLTE`+`tRNS`). The bitmap glyph fixture (M3 T5) and the earlier `error.Unsupported` fixture for non-`glyf` outlines. |
| `NotoColorEmoji-LICENSE.txt` | `assets/noto_color_emoji/LICENSE.txt` | OFL-1.1 notice (covers both Noto files). |
| `test_glyphs-glyf_colr_1.ttf` | `assets/colr_test_glyphs/test_glyphs-glyf_colr_1.ttf` | Apache-2.0; see `colr_test_glyphs-LICENSE.txt`. The upstream COLRv1 test font ("Font is taken from https://github.com/googlefonts/color-fonts"): COLRv0 glyphs 168..175 plus a COLRv1 paint graph exercising layers, solids, linear/radial/sweep gradients, glyph clips, all transform formats and all composite modes; also carries the CPAL fixture used by the COLR tests. Not a Git LFS object (`file` header, not a pointer). |
| `colr_test_glyphs-LICENSE.txt` | `assets/colr_test_glyphs/LICENSE.txt` | Apache-2.0 notice. |
| `SourceSerif4-Regular.otf` | `adobe-fonts/source-serif` `OTF/SourceSerif4-Regular.otf` at commit `5f220b17d27ed64873f22cde0dd593685387bd19` (`release` branch) | OFL-1.1; see `SourceSerif4-LICENSE.md`. Static CFF (version 1) face: 1464 glyphs, upem 1000, global + local subrs, `hmtx` advances, no `HVAR`. The M3 CFF outline fixture. Downloaded via `tools/import_upstream_fixtures.sh`; not a Git LFS object. |
| `SourceSerif4Variable-Roman.otf` | `adobe-fonts/source-serif` `VAR/SourceSerif4Variable-Roman.otf` at commit `5f220b17d27ed64873f22cde0dd593685387bd19` | OFL-1.1. CFF2 variable face with 6 FDArray subfonts (FDSelect format 3), an item variation store and 34,012 `blend` operators at the default location. The M3 CFF2 fixture; the port supports its outlines bit-exactly but gates non-empty coordinates on `HVAR` (not ported) and CFF hinting. |
| `SourceSerif4-LICENSE.md` | `adobe-fonts/source-serif` `LICENSE.md` at the same commit | OFL-1.1 notice. |
| `Inconsolata.ttf` | `assets/inconsolata/Inconsolata.ttf` | OFL-1.1; see `Inconsolata-LICENSE.txt`. The variable-font fixture (M3 T6): `fvar` axes `wght` 200..900 (default 400) and `wdth` 50..200 (default 100), `gvar` with 962 glyphs and 8 shared tuples, `HVAR`, `avar`, and `fpgm`/`prep` bytecode so both the unhinted `gvar` path and the hinted path (interpreter + `GETVARIATION`) are gated. Not a Git LFS object. |
| `Inconsolata-LICENSE.txt` | `assets/inconsolata/LICENSE.txt` | OFL-1.1 notice. |
| `NotoSans-Regular.ttf` | `notofonts/notofonts.github.io` at `28b15b4b43b7bed62b5cf6e6b0b5ff5846270535`, `fonts/NotoSans/unhinted/ttf/NotoSans-Regular.ttf` | SIL OFL-1.1 (`NotoSans-OFL.txt`); from the Noto project's explicitly *unhinted* build tree. Static Regular, 3884 glyphs, `fpgm`/`prep` absent and `maxp.maxSizeOfInstructions == 0`, so skrifa's `Engine::AutoFallback` selects the autohinter. The M3 autohint fixture (`glyph_run` hinted scenes and `--dump-glyphs --hint` vectors). Downloaded by `tools/import_upstream_fixtures.sh` and checksum-verified. |
| `NotoSansMono-Regular.ttf` | `notofonts/notofonts.github.io` at `28b15b4b43b7bed62b5cf6e6b0b5ff5846270535`, `fonts/NotoSansMono/unhinted/ttf/NotoSansMono-Regular.ttf` | SIL OFL-1.1 (`NotoSans-OFL.txt`). Same unhinted build tree; monospace advances and same-width digits exercise the autohint advance paths. |
| `NotoSansDevanagari-Regular.ttf` | `notofonts/notofonts.github.io` at `28b15b4b43b7bed62b5cf6e6b0b5ff5846270535`, `fonts/NotoSansDevanagari/unhinted/ttf/NotoSansDevanagari-Regular.ttf` | SIL OFL-1.1 (`NotoSans-OFL.txt`). Same unhinted build tree; exercises the autohinter's Indic script group. |
| `NotoSans-OFL.txt` | `notofonts/latin-greek-cyrillic` at `4bc63d7ebca1faed49c6c685f380ba0abc2c1941`, `OFL.txt` | SIL OFL-1.1 notice for the Noto Sans fixtures. |

SHA-256:

```text
b505bbd72ed997810e346931fa31f3bc59d1e131080182de959c4978ea20eb45  NotoColorEmoji-CBTF-Subset.ttf
573154bdf29cd5963f2be063be3dda0055904f2ad8228c0fd57948580d927ea2  NotoColorEmoji-LICENSE.txt
467e3e7074b6cdf8bbb7795124eb88f87a08934f1446d5716795554cfb6e00cb  NotoColorEmoji-Subset.ttf
cfc7749b96f63bd31c3c42b5c471bf756814053e847c10f3eb003417bc523d30  Roboto-LICENSE.txt
319cff6e7a31f0f2a41c475dca42890aa5d19fe16017e2290f8c1d4e14f76481  Roboto-Regular.ttf
c21d7293d87b6d7ab1d0229a2f55b77f33a7613a6a4e66f6693d68d7d8d09464  SourceSerif4-LICENSE.md
edf160d0d584deee8a3bb2c3371b2a7624ca63580fbe02c57c1f4c91e84d8787  SourceSerif4-Regular.otf
867b73c6a954a4a64616906d179f94572a748790a1d022ebeeff07f56ea0221a  SourceSerif4Variable-Roman.otf
0cec06e0e55fbc3dc5cee4fca9b607f66cb8f4e4dbcf3b3c013594dd156732e9  colr_test_glyphs-LICENSE.txt
88ff34af8db521e5e2520719706bc24388e7e976ac02dd818b867e0f6a8e0d13  probe.png
01c87c436d7b3cfaa357dfaad9259f57b4fdcb27a62da9658afb10056ee54bea  probe.rgba
8aa611b1ca97044ac6f13dc982fde29256612f0a5acc6ef47ca541a7a5b99b28  test_glyphs-glyf_colr_1.ttf
228b071e67b1bafa952149559505aaed0a20269f457e0a18a8d7739d031561dc  Inconsolata.ttf
e564f06d018e7b95bc3594c96a17f1d41865af4038c375e7aa974dd69df38602  Inconsolata-LICENSE.txt
f3961a9cde016d41a4879aecda1474d3a36d6bf54fa0e4643de029cc2248b0e8  NotoSans-Regular.ttf
87f8ce0522a6c99b743ee5fc75b4073cfdd575639119672828b7b9944b65b4f4  NotoSansMono-Regular.ttf
216921eded5a97435fa0638deca66496bf51f52fa3467f566deb9938c25a71de  NotoSansDevanagari-Regular.ttf
cee9892f9f0cc8fe882c9e9537ee6a89621d86ee7ceaf70b02e2b2b1c25c061a  NotoSans-OFL.txt
```

The SHA-256 values were computed from the pinned checkout with `sha256sum`
(2026-09-12) and are re-printed by `tools/import_upstream_fixtures.sh`. The
Source Serif 4 values were captured from the pinned Adobe release download on
the same date. `zig build test` reads the fonts directly; the M3 oracle gate
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
