# oracle-rs

Renders the shared vellz scene corpus with the pinned upstream `vello_cpu`.
This is development tooling: it is not part of the distributed package and it
depends on a checkout under `../../.reference/vello`.

## Build

```sh
tools/fetch-reference.sh
cd tools/oracle-rs
cargo build --release
```

`Cargo.lock` is committed. It is seeded from the pinned checkout's lock file so
dependency resolution matches the upstream oracle as closely as possible; the
`vellz-oracle` entry is added by Cargo on first build.

## Usage

```sh
tools/oracle-rs/target/release/vellz-oracle \
    --scene tests/scenes/fill_rect_64.json \
    --out tests/fixtures/oracle/fill_rect_64.rgba \
    --png
```

Outputs:

- `<out>`: raw premultiplied sRGB RGBA8, row-major, no padding, `4*w*h` bytes.
- `<out without extension>.json`: metadata: dimensions, pipeline settings,
  pinned revision, FNV-1a hashes of the scene text and the output pixels.
- with `--png`: a PNG sibling for human inspection (never used for exact
  comparisons; decoders may differ).

Rendering is deterministic by construction: `level` defaults to `fallback`
(no runtime SIMD feature detection), `threads` to `0`, `mode` to `quality`
(f32 pipeline), and `target_init` to a transparent clear.

## Glyph and cmap dumps (M3 T2)

`--dump-glyphs` and `--dump-cmap` are the ground truth for the Zig `glifo`
port. They print canonical text to stdout; coordinates are f32 bit patterns in
lowercase hex so the Zig side can be byte-compared without float formatting.
`tools/compare_glyphs.sh` (or `zig build glyphs`) drives both implementations
and diffs every vector.

```sh
# Unhinted FreeType path elements for glyphs 0..100 at 16 px.
tools/oracle-rs/target/release/vellz-oracle \
    --dump-glyphs --font tests/fixtures/upstream/Roboto-Regular.ttf \
    --size 16.0 --gids 0-100

# Selected cmap subtable (format 4 or 12) for ASCII plus an emoji.
tools/oracle-rs/target/release/vellz-oracle \
    --dump-cmap --font tests/fixtures/upstream/NotoColorEmoji-Subset.ttf \
    --codepoints 65,0x1F389

# Scaled advances/lsb for fonts without outlines (bitmap-only faces).
tools/oracle-rs/target/release/vellz-oracle \
    --dump-advances --font tests/fixtures/upstream/NotoColorEmoji-CBTF-Subset.ttf \
    --size 50.0 --gids 1-4
```

`--dump-advances` prints `glyph_metrics(Size::new(ppem)).advance_width` /
`left_side_bearing` as f32 bit patterns (`gid N lsb <hex> advance <hex>`) and
exists because `--dump-glyphs` needs outlines, which bitmap-only faces do not
have. `tools/gen_glyph_scenes.py` uses it to position the bitmap `glyph_run`
scenes with exact f32 advance accumulation.

`--gids`/`--codepoints` accept comma-separated decimal or `0x` hex values and
inclusive `start-end` ranges, and may be repeated. `--font`, `--index`,
`--size` and the id list are shared by all three modes. The glyph dump draws
with `skrifa`'s `DrawSettings::unhinted(Size::new(size), LocationRef::default())`
and the default `PathStyle::FreeType`; that is exactly the call
`glifo 0.3.0`'s `OutlineCache` makes for an unhinted run, and the dump also
carries the resulting adjusted `lsb`/`advance`.

Fixture hashes for the vectors gated by `zig build test` live in
`tests/fixtures/glyphs/manifest.zig`; regenerate them with
`tools/compare_glyphs.sh --update-manifest`.

## Scene format

Version 1. All coordinates are f64 logical pixels; affine values are
`[a, b, c, d, e, f]` with kurbo's convention
`x' = a*x + c*y + e`, `y' = b*x + d*y + f`. Colors are 8-bit non-premultiplied
sRGB; alpha is linear in the alpha channel.

```json
{
  "version": 1,
  "width": 64,
  "height": 64,
  "settings": { "mode": "quality", "level": "fallback", "threads": 0 },
  "target_init": "clear",
  "commands": [
    { "op": "set_paint", "rgba8": [255, 0, 0, 128] },
    { "op": "fill_rect", "rect": [8, 8, 40, 40] }
  ]
}
```

Commands:

| `op` | fields | notes |
| --- | --- | --- |
| `set_transform` | `affine` | replaces the scene transform |
| `reset_transform` | | |
| `set_paint_transform` | `affine` | |
| `reset_paint_transform` | | |
| `set_paint` | `rgba8` or `gradient` or `image` | exactly one variant; see below |
| `set_fill_rule` | `rule`: `nonzero` \| `evenodd` | |
| `set_stroke` | `width`, `join`, `start_cap`, `end_cap`, `miter_limit`, `dash`, `dash_offset` | omitted fields keep upstream `Stroke` defaults |
| `set_aliasing_threshold` | `value`: u8 or null | |
| `fill_rect` / `stroke_rect` | `rect`: `[x0, y0, x1, y1]` | |
| `fill_path` / `stroke_path` | `path`: SVG path data | kurbo `BezPath::from_svg` |
| `push_clip_path` / `pop_clip_path` | `path` | non-isolated clipping |
| `push_clip_layer` / `pop_layer` | `path` | isolated clipping layer (alias for `push_layer` `kind:clip`) |
| `push_layer` / `pop_layer` | `kind`: `clip` \| `blend` \| `opacity` \| `mask` \| `filter` | isolated layer; see below |
| `set_filter_effect` | `filter` | wraps each subsequent draw in a filter layer |
| `reset_filter_effect` | | clears the paint-level filter |
| `glyph_run` | `font`, `font_size`, `glyphs`, ... | positioned glyph run through `glifo`; see below |
| `reset` | | upstream `RenderContext::reset` |

### Paints

Solid (existing):

```json
{ "op": "set_paint", "rgba8": [255, 0, 0, 128] }
```

Gradient (`extend` is `pad`, `repeat` or `reflect`; a kind is exactly one of
`linear`, `radial`, `sweep`):

```json
{ "op": "set_paint", "gradient": {
  "kind": { "linear": { "start": [10, 10], "end": [54, 54] } },
  "stops": [
    { "offset": 0.0, "rgba8": [0, 200, 64, 255] },
    { "offset": 1.0, "rgba8": [0, 64, 255, 255] }
  ],
  "extend": "pad"
} }
```

Radial uses `{"radial": {"start_center":[x,y],"start_radius":r,"end_center":[x,y],"end_radius":r}}`;
sweep uses `{"sweep": {"center":[x,y],"start_angle":a,"end_angle":a}}` (radians).

Image paint (`asset` is resolved relative to the scene file's directory;
`format` is `rgba8` or `bgra8`, `alpha_type` is `alpha` or `premultiplied`):

```json
{ "op": "set_paint", "image": {
  "asset": "assets/checker16.rgba",
  "width": 16,
  "height": 16,
  "format": "rgba8",
  "alpha_type": "alpha",
  "sampler": { "x_extend": "pad", "y_extend": "pad", "quality": "low", "alpha": 1.0 }
} }
```

`quality` is `low` (nearest), `medium` (bilinear) or `high`; extend modes are
`pad`, `repeat` or `reflect`. Raw assets are loaded with `Pixmap::from_parts`
(which premultiplies `alpha_type: "alpha"` input); `bgra8` assets have red and
blue swapped first.

### Layers

```json
{ "op": "push_layer", "kind": "clip", "path": "M32 4 L60 32 L32 60 L4 32 Z" }
{ "op": "push_layer", "kind": "blend", "blend": { "mix": "multiply", "compose": "src_over" } }
{ "op": "push_layer", "kind": "opacity", "opacity": 0.5 }
{ "op": "push_layer", "kind": "mask", "mask": {
    "asset": "assets/mask16.rgba",
    "width": 16, "height": 16,
    "format": "rgba8", "alpha_type": "alpha",
    "kind": "alpha"
} }
```

`mix` accepts the peniko `Mix` names (`normal`, `multiply`, `screen`,
`overlay`, `darken`, `lighten`, `color_dodge`, `color_burn`, `hard_light`,
`soft_light`, `difference`, `exclusion`, `hue`, `saturation`, `color`,
`luminosity`) and `compose` the peniko `Compose` names (`clear`, `copy`,
`dest`, `src_over`, `dest_over`, `src_in`, `dest_in`, `src_out`, `dest_out`,
`src_atop`, `dest_atop`, `xor`, `plus`, `plus_lighter`). `push_clip_layer` is
kept as an alias for `kind:clip`. Mask layers use the asset's alpha
(`kind: "alpha"`) or luminance (`kind: "luminance"`); mask assets are
nearest-neighbor resampled to the render target size because `vello_cpu`
ignores masks of a different size (see `tests/scenes/assets/README.md`).

### Filters

Upstream (`vello_cpu`) supports single-primitive filter graphs only; a
multi-primitive graph panics, so the scene format expresses only one primitive
per filter. `edge_mode` is `duplicate`, `wrap`, `mirror` or `none` (default).

```json
{ "op": "set_filter_effect", "filter": { "kind": "flood", "rgba8": [30, 140, 220, 180] } }
{ "op": "reset_filter_effect" }
{ "op": "set_filter_effect", "filter": { "kind": "offset", "dx": 8.5, "dy": -4.0 } }
{ "op": "set_filter_effect", "filter": { "kind": "gaussian_blur", "std_deviation": 3.0, "edge_mode": "duplicate" } }
{ "op": "set_filter_effect", "filter": { "kind": "drop_shadow", "dx": 6, "dy": 6, "std_deviation": 2, "rgba8": [20, 30, 90, 200], "edge_mode": "duplicate" } }
{ "op": "set_filter_effect", "filter": { "kind": "drop_shadow_only", "dx": 6, "dy": 6, "std_deviation": 2, "rgba8": [20, 30, 90, 200], "edge_mode": "duplicate" } }
```

`set_filter_effect` applies the filter to the next drawn elements (each draw
becomes its own filter layer); use `push_layer kind:filter` to apply one filter
to multiple draws. A filter layer accepts an optional `clip` (SVG path data),
`opacity` (f32), `blend` (`{mix, compose}`) and `mask` next to its required
`filter`:

```json
{ "op": "push_layer", "kind": "filter",
  "filter": { "kind": "gaussian_blur", "std_deviation": 2.0, "edge_mode": "duplicate" },
  "clip": "M32 6 L58 32 L32 58 L6 32 Z",
  "opacity": 0.5,
  "blend": { "mix": "multiply", "compose": "src_over" } }
{ "op": "pop_layer" }
```

Blurred rounded rectangles and glyph runs are consumed by both
implementations. Glyph runs never shape: the scene carries an explicit
positioned glyph list, so the oracle and vellz receive identical inputs.

### Glyph runs (M3 T3)

```json
{ "op": "glyph_run",
  "font": { "asset": "../fixtures/upstream/Roboto-Regular.ttf", "index": 0 },
  "font_size": 50.0,
  "hint": false,
  "atlas_cache": true,
  "style": "fill",
  "glyph_transform": [1, 0, -0.36, 1, 0, 0],
  "glyphs": [ { "id": 43, "x": 0.0, "y": 0.0 }, { "id": 72, "x": 32.5, "y": 0.0 } ] }
```

| field | notes |
| --- | --- |
| `font` | `asset` is relative to the scene file; `index` selects a TTC face |
| `font_size` | pixels per em |
| `hint` | default `true` (upstream); the M3 corpus uses `false` because the interpreter is not ported yet |
| `glyph_transform` | optional affine applied per glyph (after positioning) |
| `atlas_cache` | optional; toggles the glyph atlas path |
| `style` | `fill` (default) or `stroke` (uses the current `set_stroke`) |
| `glyphs` | `{id, x, y}` list; `id` is the font glyph id from `--dump-cmap` |
| `embolden` / `normalized_coords` | parsed and rejected with an explicit error until ported (`error.Unsupported`) |
| `decoration` | parsed and rejected with an explicit error until T5 |

The current scene transform and `set_paint_transform` are captured by
`RenderContext::glyph_run` exactly as in `vello_cpu`, so the usual commands
apply. `tools/gen_glyph_scenes.py` generates the committed corpus cases from
the font's cmap/hmtx; see `tests/README.md` for the gate and tolerance policy.
