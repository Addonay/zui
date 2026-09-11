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

SHA-256:

```text
88ff34af8db521e5e2520719706bc24388e7e976ac02dd818b867e0f6a8e0d13  probe.png
01c87c436d7b3cfaa357dfaad9259f57b4fdcb27a62da9658afb10056ee54bea  probe.rgba
```

The `probe.rgba` scene is defined in `vello_common/src/probe.rs` (upstream) and
becomes usable when the corresponding features (solid fill, alpha blending,
gradient, nearest/bilinear image, opacity layer, difference blend, rotation)
are ported. Until then it is a pinned reference, not a passing test.

Upstream `vello_tests/snapshots/*.png` (523 files, Git LFS) are the broader
gold corpus. They are imported one at a time together with the ported scene
code that produced them, together with their SHA-256, rather than wholesale.
