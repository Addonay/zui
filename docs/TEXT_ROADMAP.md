# Text roadmap: gap §5B status and the color-glyph blocker

Updated 2026-09-17. Tracks gap-report §5B (text editing + internationalization).
Shading: **done** · _partial_ · deferred (with owner).

## What landed this round

- **Editing model** (`src/widgets/editing.zig`): bounded single-line model,
  offsets are UTF-8 bytes, UAX#29 grapheme segmentation via cozmic (`ezi-code`
  tables). Selection (anchor/active), shift-extension, word/line movement,
  select-all, one-transaction paste (`insert`), grapheme delete, bounded
  undo/redo (16 entries, fixed-capacity stack copies, no allocator), horizontal
  `scroll_x`. `TextField` (`src/widgets/text_field.zig`) now delegates editing
  to it; the field keeps the legacy `buffer`/`len`/`caret` views read-only.
- **IME protocol** (`src/platform/event.zig`): `CompositionEvent`
  (preedit/commit/cancel), owned 256-byte `CompositionText` with a `marked`
  range and optional surrounding-text `replacement` range, plus `CaretReporter`
  for window-local caret rectangles. Criticality, coalescing and queue policy
  unchanged; commit/cancel are critical, preedit is droppable. App/window
  dispatch the new variant to the focused element. The field holds preedit
  state, renders preedit inline with underline + selection highlight, and
  cancels on blur/Escape. Native IME wiring is the next round.
- **Shaped geometry** (`src/fonts/text_engine.zig`, `src/elements/text_engine.zig`):
  `Layout.visualMove` (distinct visual grapheme caret, bidi-aware),
  `Layout.selectionRects` (wrapped + mixed-direction highlight rects),
  `Layout.hit`/`cursorPosition` exposed; element-level `editingGeometry`
  borrows the retained measure layout when valid. The field consumes these for
  pointer hit-testing (click + drag), selection rects, caret placement and
  scroll clamping. `caretX` remains for the old caret-only path.

Deferred inside the model, structured as extensions: multiline (cursor `line`
fields already flow through the model), split-caret affinity, virtual cursor
column for Up/Down, binding tables per layout direction, and
UTF-16 conversion at platform boundaries (protocol types already document the
offset convention).

## Color glyphs: status and the blocker (spike-verified)

Two tests in `src/fonts/text_engine.zig` ("color spike") carry executable
evidence from this host:

- **CBDT/sbix bitmap emoji works end to end today** (`/usr/share/fonts/twemoji/Twemoji.ttf`):
  shaping resolves the flag sequence to one ligature glyph, per-script
  fallback picks the emoji face, `SwashCache.getImage` returns
  `content == .color` RGBA (76×72 at the 48px strike, non-zero-alpha ink, 4
  bytes/pixel), and the coverage-only atlas rejects it exactly per contract
  (`error.ColorUnsupported`, zero pool bytes, no readable mask key). The same
  result was cross-checked below the engine with an independent raw-FreeType C
  probe: `FT_PIXEL_MODE_BGRA`, 76×72, straight from `FT_Load_Glyph`.
- **COLRv1 is blocked in the host FreeType build, not in cozmic's flags**
  (`google-noto-color-emoji-fonts/Noto-COLRv1.ttf`, FreeType 2.14.3): the
  shaped flag ligature (gid 3773) and the lone regional indicator load as
  outlines with `FT_HAS_COLOR` true, but **every** render path —
  `FT_LOAD_COLOR`, `FT_LOAD_COLOR | FT_LOAD_RENDER`, explicit
  `FT_Render_Glyph(FT_RENDER_MODE_NORMAL)` — yields a 0×0 bitmap with a null
  buffer, both through cozmic's adapter and through raw FreeType with no
  cozmic in the loop. The in-repo test pins this observation but deliberately
  skips on hosts whose FreeType does traverse COLRv1 paint graphs (the
  assertions would be false there).

Two registration gotchas the spike pins for the next implementer: a late font
needs BOTH `FontSystem.addFontData` (HarfBuzz backend; `db.addFaceFromBytes`
is family-matching metadata only) and `Raster.addFromFontSystem` (the FreeType
registry snapshots at `Engine.init`).

**ZUI-side work (next round, does not require the COLRv1 fix):** give the
atlas a second RGBA pool with a color key bit so color and coverage entries
cannot alias (vellz's sentinel `subpixel_x` design in
`vellz/src/glifo/atlas/key.zig` is the proven pattern), extend the painter to
switch on `view.content`, and emit color quads. CBDT emoji paints then; COLRv1
starts painting on hosts/builds whose FreeType traverses the paint graph (or
once cozmic vendors a build that does), with no further ZUI change. The
coverage-only contract stays intact: `putBitmap(.color, ...)` keeps rejecting,
the new pool is a separate, explicit path.
