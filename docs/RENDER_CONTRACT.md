# ZUI render contract

Scene-side contract for getting pixels on screen: what the scene means,
who resolves resources, where frames complete, and what fails loudly.
Companion to the gap report §3 (overflow policy) and §5E (scene semantics).

## 1. Scene submission

- One `gpu.Scene` per window per frame, owned by `Window` (`src/app/window.zig`).
- The producer is the window's `Renderer` callback: for entity views,
  `runtime.mountView` installs layout → `elements.painter.paint` → scene.
- Window-owned scenes attach a bounded out-of-line stroke storage so custom
  line primitives do not enlarge the hot `Frame + Scene` stack pair. A
  standalone `Scene{}` retains quad/glyph/blit compatibility; callers that
  emit strokes must attach `StrokeStorage` first.
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

The presentation seam is `Window.present()`. CPU remains the default. An
optional `gpu.render_backend.Controller` may be activated with explicit
WGPU/Vellz hooks; it rejects incomplete selection (missing build, surface, or
runtime), skips minimized frames, invalidates in-flight work on resize, and
keeps bounded retirement records for persistent backend resources. A device
loss gets one injected recreation attempt; a failed recreation or second loss
switches the same window to CPU presentation.

## 3. Per-window surface

- Today: Linux X11 and Wayland support MULTIPLE native windows — each
  logical `Window` owns a window-scoped native handle (X11: own X window +
  framebuffer; Wayland: own `wl_surface`/`xdg_toplevel` + buffers) and
  input/resize/close/scale events route to their destination via targeted
  envelopes. Win32 and Cocoa keep the explicit single-window guard
  (`createWindow == null`); headless keeps N logical windows for tests.
- The vellz `Renderer` is owned per presenting window; its context,
  resources, and pixmap persist across frames and are recreated on resize.
- An optional WGPU/Vellz backend is compiled and device-probed with
  `zig build gpu-check -Dgpu=true -Dwgpu-native-prefix=...`; it currently
  supports device/resource work. On Linux/Wayland,
  `gpu-wayland-smoke` additionally creates/configures a native surface and
  presents diagnostic/solid/gradient frames. The fixed ZUI scene/resource
  bridge is still partial; the opt-in bridge test covers ordered
  solid/gradient/border/rounded quads, bounded line strokes, rectangular clips,
  pool-validated atlas images, and mask/color glyph uploads. A bounded bridge
  glyph/image-resource cache now reuses and retires uploaded IDs; default App
  resource handoff and full font/COLR coverage remain separate evidence. The
  App/Window boundary now exposes explicit backend selection and fallback
  policy, while native WGPU object creation remains opt-in through hooks.

## 4. Scale (logical/physical pipeline)

The contract (gap report §5G stage 2):

- **Layout and scene coordinates are LOGICAL pixels** (f32, fractional OK).
  `elements/layout.zig` and the painter never see the scale factor.
- **The window framebuffer is PHYSICAL pixels.** Backends size their SHM /
  XImage buffers and `Renderer.render(width, height)` in physical pixels.
- **`Window.scale_factor: f32`** bridges them: `physical = logical * scale`.
  Acquired from the platform (X11 RandR per-monitor scale with Xft.dpi
  fallback; Wayland fractional-scale-v1 / wl_output scale; Cocoa backing
  scale; Win32 DPI/96; null backend: whatever the test sets).
- **Conversion points:**
  1. *Rasterization (paint at physical resolution):* `gpu.vellz.Renderer`
     carries `scale_factor` (set by each backend's `presentFn` from
     `windowInfo().scale_factor`) and multiplies logical quad/glyph/blit
     geometry, borders, radii and clips by it. The pixmap stays framebuffer-
     sized, so geometry is rendered at native density.
  2. *Text:* the painter emits 1x masks with logical origins;
     `text_engine.Engine.scaleScene(scene, scale)` re-rasterizes each atlas
     entry at `size_px * scale` into `Engine.scaled_glyphs` (a separate
     atlas so nothing referenced by the present is evicted) and rewrites
     the scene glyph to the physical mask. Fractional scales rasterize at
     the exact fractional font size (cozmic keys include full f32 size
     bits), never stretch the 1x mask; a failed re-raster keeps the 1x mask
     and the renderer stretches it via `glyph_scale`.
  3. *Input:* pointer positions arrive in physical pixels and are divided
     by `scale_factor` at the window boundary before hit-testing and
     region dispatch (`Window.handleEvent` normalizes; callbacks and
     regions see logical coordinates).
  4. *Fonts:* measurement stays logical (`TextAttrs.size` in logical px);
     only rasterization scales.
- **Rounding policy:** geometry stays f32 logical end to end; pixel rects
  are produced by the rasterizer at physical resolution (vellz rounds
  glyph origins to whole physical pixels). No integer snapping happens at
  the scene or layout layer.
- **`scale_changed`** (platform event) → `App.handleEvent` copies the new
  `windowInfo().scale_factor` into `Window`, marks dirty, and the next
  present re-rasterizes text at the new density and rebuilds the scaled
  atlas. A window moved between monitors therefore keeps text sharp and
  hit alignment, per the §5G acceptance criteria.

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

- **Nested clips and groups** are now bounded retained commands. CPU Vellz
  and the optional WGPU bridge support nested affine transforms, rectangular
  and rounded/path group clips, and opacity layers in emission order. The
  fixed group depth is 64; malformed underflow/overflow is rejected.
- **Group opacity** is isolated by the Vellz layer path, so overlapping
  semi-transparent siblings are composited as a group rather than merely
  multiplying each primitive's alpha.
- **Blur** is 8 concentric expanding quads (soft falloff), not a blur
  kernel: it approximates glow, never blurs content behind the node.
- **Shadows** are two offset quads (halo + contact layer), not a blurred
  silhouette: no kernel, no light direction, no content-aware shape beyond
  the rounded rect.
- **Color glyphs** (emoji, color faces) use the separate RGBA atlas pool and
  image path; hosts without usable color raster data still skip them and count
  the miss (`cozmic_skipped_glyphs`): unsupported raster content still skips
  safely; color glyphs use the separate RGBA pool and do not corrupt mask
  bytes.
- **Gradients** are single-quad horizontal lerps with exact rounded
  corners; no multi-stop, radial, or rotated gradients in the scene.
- **Paths/strokes/canvas**: custom Canvas emits bounded Bezier paths and
  groups, with CPU/WGPU stroke joins (`miter`, `round`, `bevel`) and caps
  (`butt`, `round`, `square`). Unsupported resource payloads still fail
  explicitly; the fixed path segment and group capacities remain enforced.
- **Glyph scene-full** counts into per-node `skipped` alongside spaces and
  missing ink; the frame-level `overflowed()` signal is what distinguishes
  "no ink by nature" from "ink lost to overflow".
