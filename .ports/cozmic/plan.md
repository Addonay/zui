# cozmic — cosmic-text port plan

Pinned upstream: `.reference/cosmic-text` (cosmic-text 0.19.0, ~12.4k LOC, 25 *.rs).
Vendored refs: `.reference/ezi-code` (UAX #9/#14/#24/#29, NFC/NFD, bidi, scripts),
`.reference/harfbuzz-ref` + `.reference/freetype-ref` (C wrap pattern).
Zig: 0.17.0-dev.2085+5e36170b5. Canonical type ownership: `src/types.zig`.

## Status vocabulary (owner review 2026-09-11)

"Landed" previously overstated several modules. Use these terms:
- **ported** — Rust logic transcribed, compiles, has unit tests.
- **isolated** — additionally compiles/tests standalone with local stand-in types.
- **connected** — uses canonical types and is reachable from the public API end to end.
- **verified** — output matches upstream on shared fixtures (differential test/image).

Current integration audit (owner probes):
1. Buffer did not use the real shaper: `FontSystem` empty struct, synthetic
   `0.6*size` advance, ellipsize ignored. Integration pass started 2026-09-11
   (shape/layout + buffer_line + buffer + edit rewire in flight).
2. `buffer.Attrs != attrs.Attrs`; Editor owned its own EditBuffer — unification in flight.
3. Delete at start of `e`+U+0301 left the accent — grapheme fix in flight.
4. `unicode.zig` used approximated table subsets and was not imported by
   shaping/editor — direct imports + full tables planned (ezi-code build dep).
5. Benchmarks compared different work (synthetic Zig vs real Rust) — harness
   kept, performance conclusions postponed until identical fonts/inputs.

## Module map (Rust -> Zig)

Status legend: ported / isolated / connected / verified / partial / stub.

| Rust | LOC | Zig | Status |
|------|-----|-----|--------|
| attrs.rs | 594 | src/attrs.zig | ported, connected (canonical owner) |
| cursor.rs | 156 | src/cursor.zig | ported, connected (canonical owner) |
| line_ending.rs | 98 | src/line_ending.zig | ported, connected (canonical owner) |
| cached.rs | 86 | src/cached.zig | ported |
| math.rs | 20 | src/math.zig | ported |
| layout.rs | 218 | src/layout.zig | ported, canonical owner; physical() -> CacheKey wire in flight |
| render.rs | 156 | src/render.zig | ported |
| bidi_para.rs | 74 | src/bidi_para.zig | ported (full UAX#9 levels pending) |
| font/mod.rs | 264 | src/font.zig | ported (sfnt sniff; HB/FT wiring point) |
| font/system.rs | 557 | src/font_system.zig | ported, canonical owner |
| font/fallback/* | 746 | src/fallback.zig | ported |
| font/cache.rs | 424 | src/font_system.zig (scan) | partial (CTFC disk cache TODO) |
| shape.rs | 3084 | src/shape.zig | ported; connecting to buffer in flight |
| shape_run_cache.rs | 49 | src/shape_run_cache.zig | ported |
| glyph_cache.rs | 170 | src/glyph_cache.zig | ported, connected (canonical owner) |
| swash.rs | 304 | src/swash_cache.zig | ported (raster stand-in until FT) |
| buffer_line.rs | 338 | src/buffer_line.zig | ported; connecting to shaper in flight |
| buffer.rs | 1830 | src/buffer.zig | ported; connecting to FontSystem/shape in flight |
| edit/mod.rs + editor.rs | 1259 | src/edit.zig | ported; connecting to Buffer + grapheme fix in flight |
| edit/vi.rs | 1181 | src/vi.zig | ported, isolated (no Buffer connection) |
| edit/syntect.rs | 494 | src/syntect.zig | stub (real highlighter pending) |
| lib.rs | 148 | src/root.zig | ported (public re-exports in flight) |
| rangemap | — | src/attrs.zig AttrsList | ported |
| unicode-bidi | — | src/bidi_para.zig + src/unicode.zig | partial (UAX#9 levels) |
| unicode-linebreak | — | src/unicode.zig | ported shards (full ezi-code dep pending) |
| unicode-segmentation | — | src/unicode.zig | ported shards (full ezi-code dep pending) |
| unicode-script | — | src/unicode.zig | ported shards (full ezi-code dep pending) |
| harfrust (HarfBuzz) | — | shape.zig ShapeAdapter seam | stub (real hb_shape pending) |
| skrifa + swash | — | src/font.zig + src/swash_cache.zig | stub (FreeType pending) |
| fontdb | — | src/font_system.zig FontDb | partial (fontconfig pending) |

## Integration order (agreed with owner)

1. One canonical type set (`src/types.zig`). — in flight
2. Connect FontSystem -> ShapeLine -> BufferLine -> Buffer -> Editor. — in flight
3. Replace synthetic font/shaping/raster adapters with one real backend
   (FreeType raster + HarfBuzz shaping behind the existing seams).
4. Connect complete Unicode data/algorithms (ezi-code dependency) to the pipeline.
5. Pass one end-to-end fixture: mixed Latin/Arabic, wrapping, click-to-caret,
   selection, insertion, grapheme deletion.
6. Expand differential coverage before Vi/syntax/optimization work.

## Test parity (image plan 2026-09-11)

Assets vendored: tests/fonts (7 ttf + 3 LICENSE), tests/images (24 png baselines),
tests/sample/hello.txt.
Suites: direction 7, wrap_stability 2, wrap_word_fallback 1, ellipsize 14 img,
richtext 1, shaping 6 img + 2 logic, decorations 4 img, variable 1, editor 7 (vi-gated).
Harness TODO: tests/common/draw.zig (isolated fontdb from tests/fonts, locale En-US,
margins 5, Pixmap blendSrcOver + fillRect, PNG writer via flate+Crc32, PNG read via
stb_image.h or minimal decoder, decoded-RGBA compare not byte compare, bless via
-Dgenerate-images or COZMIC_GENERATE_IMAGES).
Blockers: Buffer.draw/render missing, FontDb.loadFontsDir/loadFontData missing,
real HB/FT raster (solid-mask stand-in cannot match baselines).

## Gates

- `zig build test` green, `zig fmt --check` clean.
- Each module has unit tests mirroring Rust edge cases.
- End-to-end fixture (step 5 above) passes.
- Benches run under `zig build bench`; `bench-compare` emits dual tables.

## Reviews

- Leaf / font+shape / buffer+edit reviews DONE + fixes DONE 2026-09-11
  (render saturating, bidi B-set, flag bits, UAF, wrap branch, grapheme gaps).
  Verified suites green: render 17, layout 7, bidi 12, cached 5, cursor 8,
  attrs 13, math 4, swash 14, font_system 11, fallback 7, buffer 18,
  buffer_line 15, edit 18, root 183.

## Integration pass 2026-09-11 (owner review follow-up)

- `src/types.zig` landed: canonical type ownership contract; standalone-file
  constraint retired.
- layout/shape/shape_run_cache DONE: duplicates deleted, canonical imports,
  `LayoutGlyph.physical` builds a real `glyph_cache.CacheKey`, shape uses
  `unicode.zig` breaks/scripts/bidi. Tests: layout 27, shape 61, run cache 19.
- Owner fixes on top: `render.zig` canonical `attrs.Color`/`CacheKeyFlags`
  (37 tests); `unicode.zig` LB23/24/25/28/30 rules so words no longer split
  between letters (6 tests); `shape.zig` charmap RTL visual order fixes an
  end<start underflow (61 tests).
- edit.zig DONE: stand-ins deleted; `Editor` edits a real `Buffer` via
  `BufferRef`; grapheme-aware Delete/Backspace/motions/hit; `shapeAsNeeded`
  calls real `shapeUntilCursor/Scroll`; `e`+U+0301 Delete regression passes.
  Tests: edit 170 incl. real-font fixture.
- buffer_line.zig DONE: 97 tests, all stand-ins deleted, calls the real
  `ShapeLine.build`/`layoutToBuffer` (charmap seam) with the real FontSystem.
- buffer.zig DONE: 140 tests, real shaper path, ellipsize wired, `hit`/
  motions grapheme-correct via `unicode.zig`.
- Parent wiring: root.zig aliases repointed to canonical owners; benches load
  the vendored test fonts and use the canonical API; `e2e_test.zig` fixture
  added (mixed Latin/Arabic wrap + RTL levels, click-to-caret, selection,
  insertion, grapheme delete, ellipsize U+2026) and wired into `zig build test`.
- `unicode.zig` W3 fix: Arabic `AL -> R` before N/I passes (was level 0).
- `glyph_cache.CacheKeyFlags` unified onto `attrs.CacheKeyFlags`; `edit.Color`
  unified onto `attrs.Color`. Remaining: `attrs.Weight` (struct) vs
  glyph_cache/font_system `u16`; `FontId` placeholder in layout/glyph_cache.
- Build: `zig build test` -> 225/225 green; `zig build bench` and
  `zig build bench-compare` run through the integrated pipeline.

## Bench parity pass 2026-09-11

- Audited the 16 `UPSTREAM-ONLY` rows from `bench-compare`: none are missing
  cozmic features. 15 are upstream `Shaping::Basic` layout rows (cozmic has
  `Shaping.basic` via `shapeSkip` + tests); 1 is `load FontSystem`
  (`FontSystem.init` + `loadSystemFonts` exist).
- `benches/layout.zig`: full Wrap x Shaping(Simple/Advanced) matrix plus a
  `loadFontSystem` row; `tools/bench_compare.py` matches the shaping dimension
  and the font row. Result: 38 connected, 0 upstream-only.
- Fixed latent compile error in `FontSystem.loadSystemFonts` (`db.addFace`
  return value was ignored; `addScannedFile` was unreachable until the new
  bench exercised it).
- Corrected the compare tool's stale note: upstream has `Wrap::WordOrGlyph`;
  it simply has no bench row, so Zig-only coverage is expected.
- `build.zig`: bench run steps are serialized so JSON rows cannot interleave
  and the two benches stop contending for CPU.
- `zig build test` green; `zig fmt --check` clean.

Remaining for full cosmic-text parity, in priority order:
1. Real backend (IN PROGRESS 2026-09-11):
   - Vendored binding libraries: `.reference/harfbuzz-ref` -> `src/harfbuzz/`
     and `.reference/freetype-ref` -> `src/freetype/` (copies of the
     allyourcodebase Zig bindings, adapted to Zig 0.17). Their `c.zig` now
     re-exports `c_bindings.zig` generated with `zig translate-c` from the
     system headers (`@cImport` was removed in 0.17).
   - Registered as build modules `harfbuzz` and `freetype` in `build.zig`;
     system linkage (`linkSystemLibrary`) is declared there. Code uses
     `@import("harfbuzz")` / `@import("freetype")`.
   - Glue refactor: `src/shape_hb.zig` and `src/raster_ft.zig` both use the
     vendored modules; tests wired into root (245/245 green).
   - Engine bridge DONE: `FontSystem.addFontData(id, bytes, ...)` owns the
     HarfBuzz backend, `FontSystem.shaper()` returns the real `ShapeAdapter`,
     and `buffer_line.buildShapeLine` uses it whenever font data is
     registered (charmap remains only as the no-fonts fallback).
     `e2e_test.zig` and both benches register the vendored fonts, so mixed
     Latin/Arabic, ellipsize, click-to-caret, selection and insertion now run
     through HarfBuzz; a per-font-advance test proves shaping is real.
   - Raster bridge DONE: `src/font_raster.zig` bridges FontSystem font bytes to
     FreeType; `SwashCache.setRaster` prefers real `Rendered` bitmaps; e2e
     fixture renders a shaped 'A' through the cache (252/252 green).
   - `swash_cache.CacheKey` unified onto `glyph_cache.CacheKey`.
   - Next parity gates: `Buffer.draw` + image-test harness (tests/common),
     per-attrs font selection for fallback, fvar/wght, fontconfig discovery.
2. Unicode: replace approximated shards with the real ezi-code tables
   (build.zig.zon dependency).
3. Image-test harness (tests/common/draw.zig, decoded-RGBA compare) and the
   24 upstream baselines; run after (1).
4. `attrs.Weight`/`FontId` final unification; `syntect` real highlighter and
   `vi` reconnection to `Buffer`.
5. Bench fairness: deterministic fonts on both engines, then compare.

## Buffer/edit/layout notes

- BufferLine: owned text + ending + AttrsList, 2-level cache with Used->Unused
  reuse, reset_shaping > reset_layout hierarchy.
- DirtyFlags: RELAYOUT|TAB_SHAPE|TEXT_SET|SCROLL|DIRECTION, deferred resolve,
  shape_until_scroll/cursor preconditions.
- layout_runs culls by height, centers via (line_height-ascent-descent)/2,
  RTL-aware cursor/hit/highlight.
- Wrapping in shape.rs layout_to_buffer (~800 LOC): congruent/incongruent span
  walk, trailing-blank allowance, WordOrGlyph fallback, visual reorder, justify
  expansion, mono/hint rounding. Stability invariant: layout(unbounded)->w then
  layout(w) same wrap.
- Ellipsize: ellipsis U+2026, Start=backward+prepend, Middle=half-split +
  ellipsis_level_between (UAX#9 N1/N2), End=forward+append. Lines(0)->max(1),
  Height uses 2*lh lookahead.
- Editor: byte-index Cursor+Affinity, grapheme/word motions, hit per-grapheme
  half-split RTL-mirrored, delete_range/insert_at ending preservation +
  ChangeItem undo, selection Normal/Line/Word bounds.
- vi/syntect feature-gated; vi is isolated until Buffer connection.
- Test parity must include: stable_wrap matrix, wrap_word_fallback, ellipsize
  images, richtext empty-line metrics, BiDi seps no-panic, decorations,
  variable weights, editor_modified_state line endings.
