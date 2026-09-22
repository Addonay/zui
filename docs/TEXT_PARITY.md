# GPUI text-system parity slice

ZUI now exposes the source-backed text contracts used by this workstream:

- bounded OpenType feature settings (`TextAttrs.withFeature`) are passed into
  the real Cozmic/HarfBuzz `Attrs.font_features` list;
- ordered script fallback candidates are available through
  `fallbackCandidates`, while Cozmic remains responsible for actual installed
  face matching and per-script fallback;
- shaped layouts expose logical line ranges, UAX#29 word ranges, and
  glyph-derived grapheme character geometry (`characterPositions` and
  `characterWidths`), including proportional spans for ligature clusters;
- `text_document.Document` enforces byte/line limits and reflows only a
  requested visible line window, with revision tracking for retained editors.

The deterministic tests cover feature/cache invalidation, shaping geometry,
fallback policy, grapheme-safe ranges, and bounded large-document reflow.

Verification boundary: refreshed 2026-09-22. The aggregate
`zig build test --summary all` reports 25/25 build steps succeeded
(541/545 tests passed, 4 skipped) and `zig build test-text --summary all`
reports 6/6 steps succeeded (54/54 tests passed). The declaration-order
error previously recorded at `src/gpu/scene.zig:66` no longer exists in the
tree, so the focused text gate is no longer blocked.

Native IME remains explicitly unverified here. Wayland text-input-v3, XIM,
Windows IME, and macOS IME adapters require live compositor/platform drivers;
this slice does not alter those backends.
