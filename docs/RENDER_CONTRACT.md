# ZUI render contract

Scene-side contract for getting pixels on screen: what the scene means,
who resolves resources, where frames complete, and what fails loudly.
Companion to the gap report §3 (overflow policy) and §5E (scene semantics).

## 1. Scene submission

- One `gpu.Scene` per window per frame, owned by `Window` (`src/app/window.zig`).
- The producer is the window's `Renderer` callback: for entity views,
  `runtime.mountView` installs layout → `elements.painter.paint` → scene.
- `Window.render()` clears the scene, runs the producer, then enforces the
  overflow policy (§4). Emission order is paint order; the rasterizer
  (`gpu.vellz.Renderer`) and any future GPU driver must draw
  `commandSlice()` in order and may only fuse ADJACENT same-kind commands.
- The scene never allocates: all storage is fixed arrays sized by
  `src/core/limits.zig`. Producers check push return values; the scene
  counts every failure.

## 2. Resource resolution

- Glyph coverage bytes live in the engine atlas pool (`Engine.glyphs`);
  scene glyphs copy the atlas entry (offset + dims), never a reference.
  Mid-frame eviction is deferred past emitted glyphs (`fonts/atlas.zig`),
  so pool bytes stay valid through present.
- Image bytes live in the App image-cache pool; scene blits carry a
  `pool_offset`. Pool reset refuses while current-frame entries are pinned,
  and retained handles validate by generation, so a blit never reads
  recycled bytes (a stale handle paints nothing).
- Each window renders and presents adjacently inside `App.step`, because a
  later window's render could otherwise evict pool bytes a previous window
  still references.

## 3. Per-window surface

- Today: one native window per connection is enforced (`App.openWindow`
  returns `MultipleNativeWindowsNotSupported` for non-null backends);
  headless keeps N logical windows for tests. Per-window native
  surfaces/swapchains are future work (gap report §5G).
- The vellz `Renderer` is owned per presenting window; its context,
  resources, and pixmap persist across frames and are recreated on resize.

## 4. Scale

- Backends report a per-window `scale_factor` in `windowInfo` (X11: 1.0,
  Wayland: from compositor, Cocoa: display scale, Win32: DPI/96).
- The scene, layout, and rasterizer currently work in logical pixels end to
  end: **no logical/physical pipeline is implemented yet**. Moving a window
  across differently-scaled monitors does not re-rasterize text, and there
  is no fractional-scale atlas invalidation. This matches gap report §5G
  and must be fixed before any HiDPI claim. Contributors: do not add a
  second `scale` float threaded by hand; define the pipeline
  (logical layout units → framebuffer pixels → content scale) first.

## 5. Completion

- `App.step` renders each dirty window and presents adjacently.
- A presented frame is always COMPLETE: either every push succeeded, or
  the frame is the diagnostic placeholder (§4). There is no partial present.

## 6. Failure and the overflow policy

- `Scene.overflowed()` / `hasOverflow()` report pushes dropped since the
  last `clear()`. `Scene.dropped` is the cumulative total (never reset).
- An overflowed frame is REJECTED:
  1. `Window.render` substitutes `renderOverflowPlaceholder` (full-viewport
     magenta + dark inset — unmissable, never blank), counts
     `rejected_frames`, sets `last_frame_rejected`, and logs at `ZUI_LOG=1`.
     Drop counters are preserved as evidence.
  2. `App.step` counts `App.rejected_frames` and logs the rejection, then
     presents the placeholder.
  3. Headless producers check `overflowed()` directly; `bench-text` fails
     its gate (nonzero exit) on any standard-row overflow.
- Capacity coherence: `MAX_RENDER_COMMANDS >= MAX_SCENE_GLYPHS`, so a
  glyph-only frame is bound by payload arrays, never by the command stream
  first (the §3 failure mode). Mixed quad+glyph frames share one command
  budget and can still overflow — that is a deliberate fixed-capacity
  tradeoff, handled by rejection, not by silent partial frames.
- Larger caps are not the answer to unbounded content: shaping unshaped
  rows costs the frame budget whether or not they fit. Virtualize large
  lists/paragraphs (don't shape invisible content).

## 7. Known approximations (§5E hardening)

Documented limitations — stated here so nobody re-discovers them as bugs:

- **Nested clips** are one intersected RECTANGLE per draw, not a clip
  stack. Rectangular nesting is exact; there is no save/restore depth, no
  transforms, and no rounded-rect descendant clip: a rounded background
  does not round its children (report §5E). Menus/popovers must paint
  outside the clipping ancestor, not as its child.
- **Group opacity** multiplies alpha down the tree (0.5 × 0.5 = 0.25).
  True isolated group compositing needs an offscreen buffer; the product
  differs from isolation exactly when semi-transparent siblings overlap.
  Covered by the painter test at 0.25-over-black (≈64).
- **Blur** is 8 concentric expanding quads (soft falloff), not a blur
  kernel: it approximates glow, never blurs content behind the node.
- **Shadows** are two offset quads (halo + contact layer), not a blurred
  silhouette: no kernel, no light direction, no content-aware shape beyond
  the rounded rect.
- **Color glyphs** (emoji, color faces) are skipped and counted
  (`cozmic_skipped_glyphs`): the atlas is single-channel coverage, and a
  mask reinterpretation would be garbage, not a fallback.
- **Gradients** are single-quad horizontal lerps with exact rounded
  corners; no multi-stop, radial, or rotated gradients in the scene.
- **Paths/strokes/canvas**: no custom path emission in the public scene
  yet — charts/diagrams/editors need the custom-element + canvas protocol
  (gap report §5A2) before this contract can cover them.
- **Glyph scene-full** counts into per-node `skipped` alongside spaces and
  missing ink; the frame-level `overflowed()` signal is what distinguishes
  "no ink by nature" from "ink lost to overflow".
