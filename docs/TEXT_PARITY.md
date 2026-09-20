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

Verification boundary: the aggregate `zig build test` and AccessKit-enabled
build currently report 22/22 and 23/23 build steps respectively from cached
artifacts. A fresh `zig build test-text --summary all` run is currently
blocked by the declaration-order error at `src/gpu/scene.zig:66`; therefore
this document records the text APIs and prior focused evidence without
claiming a fresh text-gate pass in the current tree.

Native IME remains explicitly unverified here. Wayland text-input-v3, XIM,
Windows IME, and macOS IME adapters require live compositor/platform drivers;
this slice does not alter those backends.
