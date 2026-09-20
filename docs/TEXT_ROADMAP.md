# Text roadmap: gap §5B status and the color-glyph blocker

Updated 2026-09-20. Tracks gap-report §5B (text editing + internationalization).
Shading: **done** · _partial_ · deferred (with owner).

## What landed this round

- **Editing model** (`src/widgets/editing.zig`): bounded model with an
  opt-in multiline mode,
  offsets are UTF-8 bytes, UAX#29 grapheme segmentation via cozmic (`ezi-code`
  tables). Selection (anchor/active), shift-extension, word/line movement,
  vertical movement with a retained grapheme column, select-all,
  one-transaction paste (`insert`), grapheme delete, bounded
  undo/redo (16 entries, fixed-capacity stack copies, no allocator), horizontal
  and multiline `scroll_y`. `TextField` (`src/widgets/text_field.zig`) now
  delegates editing, including an opt-in multiline layout/viewport,
  to it; the field keeps the legacy `buffer`/`len`/`caret` views read-only.
- **IME protocol** (`src/platform/event.zig`): `CompositionEvent`
  (preedit/commit/cancel), owned 256-byte `CompositionText` with a `marked`
  range and optional surrounding-text `replacement` range, plus `CaretReporter`
  for window-local caret rectangles. Criticality, coalescing and queue policy
  unchanged; commit/cancel are critical, preedit is droppable. App/window
  dispatch the new variant to the focused element. The field holds preedit
  state, renders preedit inline with underline + selection highlight, and
  cancels on blur/Escape. Wayland `zwp_text_input_v3` and optional X11 XIM
  source integrations now feed this protocol and update the IME cursor path;
  live compositor/IBus/Fcitx/XIM validation and the Win32/Cocoa adapters remain.
- **Shaped geometry** (`src/fonts/text_engine.zig`, `src/elements/text_engine.zig`):
  `Layout.visualMove` (distinct visual grapheme caret, bidi-aware),
  `Layout.selectionRects` (wrapped + mixed-direction highlight rects),
  `Layout.hit`/`cursorPosition` exposed; element-level `editingGeometry`
  borrows the retained measure layout when valid. The field consumes these for
  pointer hit-testing (click + drag), selection rects, caret placement and
  scroll clamping. `caretX` remains for the old caret-only path.

Deferred inside the model, structured as extensions: split-caret affinity,
binding tables per layout direction, large/dynamic document storage, and
UTF-16 conversion at platform boundaries (protocol types already document the
offset convention). Native IME delivery remains a platform gap even though
the normalized composition protocol and multiline consumer now exist.

## Color glyphs: bounded RGBA path and remaining evidence

Two tests in `src/fonts/text_engine.zig` ("color spike") carry executable
evidence from this host:

- **CBDT/sbix bitmap emoji produces RGBA data** (`/usr/share/fonts/twemoji/Twemoji.ttf`):
  shaping resolves the flag sequence to one ligature glyph, per-script
  fallback picks the emoji face, `SwashCache.getImage` returns
  `content == .color` RGBA (76×72 at the 48px strike, non-zero-alpha ink, 4
  bytes/pixel). The ZUI atlas now stores that data in a separate bounded color
  pool, emits a content-tagged scene glyph, and Vellz renders it as an RGBA
  image; synthetic atlas/Vellz tests cover pool separation and non-gray output.
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

Remaining color work is live/native evidence: run the shipped text path with a
color emoji font on a compositor and validate high-DPI/color-font cache
eviction. COLRv1 remains host/FreeType dependent: the current host's spike
still returns an empty bitmap, while hosts whose FreeType traverses the paint
graph should use the same RGBA path without another ZUI-side representation
change. The mask API remains strict: `putBitmap(.color, ...)` still rejects;
color bytes enter only through the explicit color-pool API.

## Current verification note

The aggregate test step reports 22/22 build steps, and the AccessKit-enabled
aggregate reports 23/23, both from cached artifacts. The fresh focused
`zig build test-text --summary all` gate is currently blocked by the existing
declaration-order error at `src/gpu/scene.zig:66`; native IME and live color
font presentation remain unverified independently.
