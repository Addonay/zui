# Scene assets

Small raw RGBA8 resources referenced by the Milestone 2 corpus scenes. They are
not fixtures: the fixtures live under `tests/fixtures/oracle/`.

| File | Size | Contents |
| --- | --- | --- |
| `checker16.rgba` | 16x16 | 4x4-pixel magenta/cyan checkerboard; top-right 8x8 quadrant fully transparent; bottom-left 8x8 quadrant is a per-pixel straight-alpha ramp (`a = 15 + 16 * (x + (y - 8))`). |
| `mask16.rgba` | 16x16 | Constant `(255, 64, 0)` color with a radial straight-alpha ramp around the center (`a = round(255 * (1 - d / d_max))`). |

Both files are straight (unpremultiplied) RGBA8, row-major, no padding:
`4 * width * height` bytes each.

## Regenerating

```sh
python3 tests/scenes/assets/generate.py
```

The generator is deterministic (no randomness, no timestamps); regenerated
bytes must be identical to the committed files. Committed SHA-256:

```text
b85378817f6d3f0a385b0f1db5f86a53c3ec02e1a40270b1f1712cb60902e045  checker16.rgba
cab22f27bc4bc58c63520a2da3579009257c79e0f46ab9248f061727741e0581  mask16.rgba
```

## Semantics used by the corpus

- `asset` paths in a scene are resolved relative to the scene file's
  directory, so `"assets/checker16.rgba"` from `tests/scenes/*.json`.
- Image paints scale the asset with a scene `set_paint_transform`; the raw
  asset stays 16x16.
- Mask layers must eventually cover the render target. `vello_cpu` ignores a
  mask whose dimensions do not match the render context, so the oracle
  resamples a mask asset to the context size with nearest-neighbor sampling
  (integer `src = dst * src_size / dst_size`). A future vellz mask
  implementation must use the same rule so the fixtures stay comparable.
