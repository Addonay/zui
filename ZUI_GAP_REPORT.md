# ZUI has closed many foundation gaps; the remaining path beyond GPUI is integration and proof

**Assessment date:** 2026-09-20 (gate evidence in "Executed checks" refreshed 2026-09-22)

**Code baseline:** current working tree, including uncommitted changes
**Scope:** the current ZUI tree, its pinned local references, executable local checks, limited live Linux probes, and primary upstream documentation. This is an engineering assessment, not a production-readiness certificate.

## Executive summary

ZUI changed substantially after the first gap report. The current working tree
closes or materially advances many of the original recommendations:

- Entities now have generations, explicit destruction, weak handles, UI-thread assertions, and liveness-gated callbacks.
- Elements have frame generations and stable keys; the source-column ID collision is fixed.
- Overflowed scenes are rejected and replaced by a diagnostic frame rather than presented partially.
- The event queue distinguishes critical, coalescable, and droppable input.
- Zlay is now the canonical layout dispatcher and runs the real todo/dashboard selftests.
- Text editing now includes grapheme-aware selection, undo/redo, bidi visual movement, shaped hit geometry, and an IME protocol.
- ZUI now has semantic nodes, focus scopes, core controls, portals, menus, overlays, scrolling, bounded fixed/variable-height list virtualization, a virtual table, themes, inspector data, and an optional Linux AccessKit bridge.
- Linux X11 and Wayland have per-window native handles, targeted events, and multi-window support. A logical/physical DPI pipeline now exists across the platform sources.
- Cross-frame text-layout caching reduced warm text-frame cost by roughly an order of magnitude in the current benchmark.
- The 2026-09-20 performance pass removed character-geometry work from
  non-semantic text, skipped empty semantic-tree traversals, and replaced
  linear glyph-atlas lookup with a bounded open-addressed index. On the same
  host and benchmark settings, 256 sentence nodes measured 1.24ms -> 0.62ms
  and 64 wrapped paragraphs 1.61ms -> 0.47ms per warm frame.
- The warm-path element-only callgrind profile attributes about 65% of
  instructions to glyph paint/raster lookup and about 30% to canonical Zlay;
  the remaining cost is in the active text/raster/layout engines rather than
  an unprofiled framework loop. Massif peaks at about 15.0 MiB for the
  benchmark harness, dominated by its fixed Frame/Scene storage and one
  engine allocation, with no unbounded per-frame growth observed.
- A root license, notice, CI workflow, platform matrix, smoke consumer, and packaged documentation now exist.

That progress changes the verdict. ZUI is no longer merely a promising rendering nucleus with one widget. It is now an early application framework with meaningful vertical slices.

It is still not ready to claim parity with GPUI. The most important remaining problems are narrower and more concrete:

1. The AccessKit bridge now builds a ZUI-owned snapshot with fresh root/child nodes per update; a live Wayland PyAT-SPI probe observes the todo semantic tree and actionable nodes, but screen-reader speech and native Windows/macOS adapters remain unverified.
2. Mounted view entities are now scoped to window lifetime; lifecycle soak and cross-window teardown evidence remain incomplete.
3. The custom-element/canvas protocol now includes bounded ordered line and
   path primitives, rounded shadows, damage tracking, and a documented device
   recovery policy; arbitrary retained layers, richer transforms, and full
   differential rendering evidence remain incomplete.
4. Zlay is now canonical, but still supports only a documented subset.
5. Wayland text-input-v3 and optional X11 XIM source paths now exist, but live IME composition is still unverified; Win32/Cocoa adapters and richer native text-range publication remain incomplete. Character positions/widths are now exported from shaped layouts. Color glyphs now have an explicit RGBA atlas/Vellz path. Bounded multiline editing is implemented, but larger-document behavior is not.
6. The optional Vellz/WGPU path now compiles, acquires a real Vulkan
   adapter/device, and presents three diagnostic frames through a native
   Wayland surface on this host. An opt-in bridge now translates ordered
   solid/gradient/border/rounded ZUI quads, rectangular clips, pool-validated
   atlas images with crop/tint/transform/grayscale, mask/color glyphs, and
   bounded line strokes;
   bounded glyph/image-resource reuse, paths, shadows, and recovery policy
   source tests are now covered; CPU remains the default and pixel-differential
   equivalence plus live loss injection remain open.
7. A worker-pool task runtime and UI-thread completion boundary now exist; window-targeted completions now invalidate safely before close/reap, while broader task composition and asset/file-watch integration remain incomplete.
8. Windows/macOS compile by default but remain native-runtime unverified, single-window, and unable to compile with AccessKit enabled.
9. Linux/native event producers now route critical queue failures through escalation and owner-table overflow rejects unsafe frames; cross-target producer validation and CI/docs consistency remain incomplete.

The architecture should still be kept. The next phase should harden and integrate what now exists, not start another broad subsystem expansion.

### Continuation checkpoint: animation and native frame pacing (2026-09-18)

- The GPUI-style animation demo now emits clockwise SVG/image rotation through
  the ordered scene and Vellz renderer instead of substituting opacity.
- The same image/SVG transform path now carries centered scale and logical
  translation, with compact per-frame transform slots so ordinary Node/Frame
  storage stays within its hot-frame budget; arbitrary nested transforms and
  shear remain unimplemented.
- The demo uses the GPUI `300x300` window, lifetime-safe formatted text with
  wrapping, and a selftest that verifies a half-turn reaches the scene image
  payload.
- `Window.springValue` now owns bounded retained scalar springs, deduplicates
  reads within a render, preserves retarget velocity, and requests the next
  native/timer frame while unsettled; the window regression covers this
  contract.
- Reduced-motion policy is now app/window scoped (`ZUI_REDUCE_MOTION=1` or
  `App.setReduceMotion`): retained springs snap to target and decorative frame
  requests are suppressed, with a headless regression.
- Public `AlignContent` values now translate through the Zlay adapter, with
  Taffy’s stretch default and an external eleven-fixture oracle gate; the
  adapter test suite and consumer selftests remain green.
- Public cross-axis end alignment and main-axis end/around/evenly distribution
  now translate through the same Zlay path; legacy layout remains deliberately
  start/center/between-compatible until the adapter becomes canonical.
- Pointer down/up and motion now have an element-tree capture/bubble phase with
  explicit `Window.stopPropagation()`, retained in compact interaction
  extensions so the hot-frame budget remains green. Scroll target/bubble
  dispatch now follows retained ancestry when a child chains an unconsumed
  remainder; touch/gesture propagation remains separate.
- Button, radio, popover, and annotated todo controls now use native keyboard
  default-action timing: Enter activates on the initial non-repeat press, while
  Space arms on press and activates only on key-up; cancellation clears the
  pending Space latch. Focused-control regressions and the todo selftest cover
  the release path.
- Window lifecycle cancellation now dispatches a framework-internal
  `cancelled` event on focus changes, focused unmount, modal close and close;
  native focus loss also reaches the focused widget before clearing capture.
  Controls, text fields, scroll areas, menus, virtual tables and popovers clear
  their private latches; non-focusable custom captured owners still need an
  explicit cancellation hook.
- Text editing now has an opt-in bounded multiline TextField path: newline
  insertion, line-local Home/End, vertical grapheme-column movement, wrapped
  shaped selection/caret geometry, and vertical scroll state are covered by
  focused model/consumer tests; native IME remains separate.
- Public flex shrink and authored flex-basis controls now translate through
  Zlay, with translation coverage and the hot-frame budget still passing.
- Compact public min/max width and height constraints now translate through
  Zlay without inflating ordinary node storage; adapter coverage verifies the
  emitted Taffy dimensions.
- Public aspect-ratio sizing now uses the same compact style-extension path and
  translates to Zlay/Taffy without changing legacy layout behavior.
- The external Zlay/Taffy gate is now a required CI job, so the matched
  fixture evidence is checked on every change rather than only locally.
- Wayland animation requests use one-shot `wl_surface.frame` callbacks when
  available; timer cadence remains the fallback for backends without a native
  frame source. A three-second Wayland probe recorded compositor frames with
  zero timer frames and zero busy-buffer skips.
- X11 button, motion, key, and text events now route through the owning
  targeted-window helper, and null/Wayland producer paths apply the queue's
  critical-event policy.
- `zig build test --summary all` reports **25/25 steps succeeded**
  (541/545 tests passed, 4 skipped; refreshed 2026-09-22), with the
  animation integration checks passing. This proves the implemented slice and
  headless behavior; it does not prove full GPUI parity or native
  screen-reader, Windows/macOS, GPU, or visual-regression coverage.

---

## 1. Evidence, methods, and limits

### What was reviewed

- Git history and the complete source delta from report baseline `5dbbbb26` through `aa159aa1`.
- Runtime/entity ownership, window lifecycle, event routing, element identity, layout dispatch, Zlay adapter, focus/interaction, semantic tree, widgets, assets, debugging, scene/rendering, DPI, and platform backends.
- `README.md`, `docs/A11Y_PLAN.md`, `docs/DEBUGGING.md`, `docs/PLATFORM_MATRIX.md`, `docs/RENDER_CONTRACT.md`, `docs/TEXT_ROADMAP.md`, and `docs/ZLAY_ADAPTER.md`.
- The local pinned GPUI, DVUI, Gooey, and Taffy references used by the repository.
- Three independent Luna passes focused on runtime/layout, rendering/platform, and public API/widgets. Their conclusions were retained only when supported by current source or executable evidence.

### Executed checks

| Check | Result | What it establishes |
| --- | --- | --- |
| `zig version` | `0.17.0-dev.2163+89ff10d56` | Current local toolchain (refreshed 2026-09-22) |
| `zig build test --summary all` | **25/25 steps succeeded; 541/545 tests passed (4 skipped)** | Aggregate headless build is green; skipped cases are host/platform/font boundaries |
| `zig build test -Daccesskit=true --summary all` | **26/26 steps succeeded; 455/455 tests passed** | Vendored AccessKit C ABI path builds and links on native Linux; live AT-SPI semantic/action probing also passes, but this is not screen-reader speech validation |
| `zig build test-text --summary all` | **6/6 steps succeeded; 54/54 tests passed** | Focused text, fallback, range, geometry, and bounded-document tests pass; native IME remains separate |
| `zig build test-zlay --summary all` | **8/8 steps succeeded; 43/43 tests passed** | Focused Zlay adapter/oracle fixtures pass |
| `zig build smoke --summary all` | **2/2 steps succeeded** | External path-dependency consumer builds |
| `bash tools/run-zlay-parity.sh` | **PASS** | External pinned Taffy fixture matched |
| `zig build selftest-zlay --summary all` | **11/11 steps succeeded** | Real todo/dashboard behavior runs through canonical Zlay |
| `zig build check -Dtarget=x86_64-windows-gnu --summary all` | **16/16 succeeded** | Default configuration compiles for Windows; it was not executed |
| `zig build check -Dtarget=aarch64-macos-none --summary all` | **16/16 succeeded** | Default configuration compiles for macOS; it was not executed |
| Same Windows check with `-Daccesskit=true` | Failed in Translate-C with 44 AVX builtin errors | Optional accessibility configuration is not cross-target ready |
| Same macOS check with `-Daccesskit=true` | Failed at `src/a11y/accesskit.zig:103` | Bridge is hard-coded around the Unix adapter type |
| `zig build bench-text -Doptimize=fast -- --format json --iter 9 --warmup 3` | 11 standard rows, zero gate failures; 256 sentence nodes 0.62ms median and 64 wrapped paragraphs 0.47ms median | Warm cached text/layout/paint path and non-overflow standard workloads |
| `zig build bench-text -Doptimize=fast -- --element-only --quick --format json` plus callgrind/massif | Warm element-only profile; ~65% paint/glyph, ~30% Zlay; ~15.0 MiB peak massif footprint | Focused warm-path CPU and allocation evidence; uncached raw reference rows remain separately measured |
| Benchmark with `--allow-overflow --iter 3 --warmup 1` | 256-paragraph stress frame rejected after 23,040 dropped pushes | Stress capacity remains finite; incomplete content is now explicitly rejected |
| `zig build gpu-check -Dgpu=true -Dwgpu-native-prefix=.ports/wgpu/.reference/artifacts/prebuilt --summary all` | **5/5 steps succeeded**; Mesa RADV Vulkan adapter/device acquired, 8192 max texture dimension | Optional WGPU/Vellz device boundary is live on this host; it is still not the default UI presentation path |
| `zig build gpu-wayland-smoke -Dgpu=true -Dwgpu-native-prefix=.ports/wgpu/.reference/artifacts/prebuilt --summary all` | **9/9 steps succeeded**; three bridged scene frames presented, format 23 | Native Wayland surface configure/acquire/render/present/teardown works for the tested scene subset |
| `zig build gpu-wayland-test -Dgpu=true -Dwgpu-native-prefix=.ports/wgpu/.reference/artifacts/prebuilt --summary all` | **9/9 steps succeeded; 5/5 bridge tests passed** | Ordered solid/gradient/rounded/border quads, bounded line/path primitives, rectangular clips, rounded shadows, cached image/glyph uploads, crop/tint/transform/grayscale, mask/color glyph resources, damage planning, and recovery policy translate or validate explicitly |

Live Linux probes performed during the review successfully launched and presented the todo app on X11 and Wayland. The AccessKit-enabled X11 probe created its Unix adapter. That earlier probe predates the current annotated Daybook fixture; current semantic/action coverage is headless and source-backed, while a real screen-reader workflow remains unverified.

### Evidence limits

- Normal unit-test artifacts were cached. The example selftests and focused Zlay run executed, but this was not a from-empty-cache rebuild.
- Windows and macOS checks were compile-only. No Win32/Cocoa launch, input, DPI, IME, accessibility, multi-window, suspend/resume, or teardown was observed.
- No full ZUI scene renderer ran on Vulkan/Metal/D3D12. The optional WGPU/Vellz
  device probe and a native Wayland surface smoke ran against Mesa RADV; the
  root GPU path currently translates the tested quad/clip/border/image/glyph
  subset, not default App handoff, fence-based retirement, injected device
  loss, or the complete scene vocabulary.
- No Orca, NVDA, or VoiceOver workflow was successfully completed against semantically annotated ZUI controls.
- The text benchmark excludes Vellz rasterization, native presentation, application work, and input-to-frame latency.
- No controlled GPUI/DVUI comparison was executed.

### Current size

ZUI now contains approximately **29,799 Zig lines under `src/`** and **440 named test declarations** across `src/` and `examples/`. This declaration count is not a claim that all cases ran in every build configuration; the executable gates above are the authority for verification. Size is context, not evidence of quality.

| Module | Zig lines |
| --- | ---: |
| `platform/` | 8,644 |
| `gpu/` | 4,599 |
| `elements/` | 4,200 |
| `app/` | 3,971 |
| `widgets/` | 3,226 |
| `fonts/` | 1,998 |
| `images/` | 1,349 |
| `core/` | 779 |
| `a11y/` | 460 |
| `debug/` | 457 |

---

## 2. What the recent work genuinely closed

The report should not keep presenting these as wholly missing.

| Former gap | Current evidence | Honest status |
| --- | --- | --- |
| No explicit entity release or weak handles | `src/app/runtime.zig:46–219,222–304` | **Implemented at entity level**; mounted window-tree ownership remains open |
| Raw late callbacks can target freed entities | Generation-aware listener/focus owner checks in runtime and elements | **Substantially addressed**; owner-table overflow weakens the guarantee |
| Escaped elements are unchecked indices | `Element.generation`, `node()` validation, `isAlive()` in `src/elements/element.zig:606–627` | **Implemented** |
| Stable ID column collision | 16-byte encoding plus regression at `src/platform/id.zig:22–59` | **Fixed** |
| Partial scenes are silently presented | `Scene.overflowed`, placeholder frame, rejection counters in `scene.zig` and `window.zig` | **Fixed policy**; capacity still requires virtualization |
| Event overflow has no policy | Critical/coalescable/droppable policy in `src/platform/event.zig:229–409` | **Implemented in queue**; native producers do not consistently act on failure |
| Zlay is completely disconnected | Dispatcher plus adapter, focused tests and real-tree selftests | **Integrated and canonical; experimental style gaps remain** |
| Text field is codepoint-only | Grapheme model, selection, undo/redo, bidi geometry, pointer hit testing, composition model, opt-in multiline editing | **Substantially implemented**; native IME/a11y text and large-document behavior remain |
| No persistent text-layout reuse | Engine cross-frame cache and benchmark cache-hit reporting | **Implemented for current key/model** |
| Asset I/O occurs in paint | `src/images/service.zig` and asset-handle resolution | **Removed from paint**; loading is still synchronous without a task runtime |
| Only `TextField` exists | Controls, radio group, scrolling, lists/tables, menus, select/combo, tooltip/popover/modal/dialog | **First widget layer exists** |
| No focus or semantic foundation | `widgets/focus.zig`, `a11y/root.zig`, semantic actions and focus scopes | **Implemented foundation**; lifecycle/modal/native details remain |
| No native accessibility bridge | Vendored AccessKit C ABI and Linux Unix adapter | **Wired but not yet correct/validated enough to claim support** |
| No virtualization | Fixed/variable-height `VirtualList` and bounded variable-height `VirtualTable` | **Implemented subset**; richer table behavior remains |
| No inspector/profiler surface | `src/debug/inspector.zig`, `stats.zig`, overlay and documentation | **Implemented diagnostics foundation** |
| One native window only everywhere | X11, Wayland, and null backends now route per-window handles/events | **Implemented on Linux/headless**; Win32/Cocoa remain single-window |
| DPI is only a reported float | Logical/physical scaling, fractional Wayland path, Win32/Cocoa source handling, null pixel tests | **Substantially implemented**; native cross-monitor evidence incomplete |
| Windows/macOS fail basic compilation | Default compile-only checks now pass 16/16 (2026-09-22) | **Fixed for default build**; AccessKit configuration still fails |
| No license/CI/package smoke test | `LICENSE`, `NOTICE.md`, `.github/workflows/ci.yml`, smoke consumer, manifest paths | **Implemented baseline**, with stale CI policy/comments |

This work is real. It should be credited without confusing source integration and headless tests with native production validation.

---

## 3. Current architecture and capability matrix

| Area | Current ZUI state | Remaining distance from a production GPUI-class framework |
| --- | --- | --- |
| State/ownership | Typed entities, explicit destroy, `WeakEntity`, generations, UI-thread assertions, liveness-gated listeners, window scopes | Subscription/task teardown, stronger owned-handle misuse protection, lifecycle soak evidence |
| Element model | Transient keyed elements with frame-generation checks, custom measure/prepaint/paint, and bounded Canvas scene pushes | Broader paths/layers/transforms and retained keyed custom state |
| Layout | Zlay canonical default; real-tree selftests and external oracle | Expand style vocabulary; restore full upstream differential oracle |
| Text layout | Cozmic shaping/fallback/bidi/wrap, cross-frame layout cache, shaped selection/hit geometry, RGBA color-glyph path | Rich text runs, broader color-font/scale evidence, stronger cache budget/eviction evidence |
| Text editing | Grapheme-aware editing, selection, undo/redo, bidi movement, composition model, opt-in multiline TextField, Wayland text-input-v3 and optional X11 XIM source paths | Live IME validation, Win32/Cocoa adapters, UTF-16 OS conversion, accessible text ranges, larger/dynamic document model |
| Interaction | Pointer capture, element-tree capture/bubble for pointer/motion/scroll, release-based `Pressable`, focus traversal/scopes, portals, targeted scrolling | Touch/pen/gesture/drag-drop, explicit tab order, broader default-action coverage |
| Accessibility | Stable semantic tree, annotated Daybook fixture, roles/states/actions, ZUI-owned AccessKit snapshots with synthetic root publication, keyed TextField value/selection actions and character-length metadata | AT validation, Win/mac adapters, richer text-run geometry, incremental updates |
| Widgets | Meaningful first set of controls, overlays, variable-height virtual list/table, bounded column resize/order, themes | Editable combo, submenus, tree/tabs/split panes, textarea, command palette, docking, rich text, reorder animations, polish and native validation |
| Assets | Stable handles, loading/ready/failed states, tickets, budgets, cancellation/reload, worker-pool reads, UI completion, no paint-time I/O | Broader task composition, deduplicated async fetch/decode, file/watch policy |
| Windows | Linux X11/Wayland/null multi-window and targeted events | Win32/Cocoa multi-window and native runtime proof |
| DPI | Logical scene units and physical raster pipeline; fractional Wayland source path | Real per-monitor transitions on all OSes, X11 RandR per-monitor detection, native evidence |
| Rendering | Ordered CPU Vellz rendering with overflow rejection, scale-aware glyph handling, Canvas quad/ring/line pushes, image/SVG rotation, and opt-in WGPU device/surface plus solid/gradient/rounded/clip/image/glyph/border/line bridge paths with bounded resource caches | Public arbitrary paths/layers, nested transforms, true effects/group opacity; default App GPU handoff; device loss/fallback evidence |
| Scheduling | Monotonic deadlines, UI-thread one-shot executor timers with cancellation, task wakeups, and Wayland compositor frame callbacks with timer fallback | Cross-backend display pacing, lower idle-wakeup evidence, repeating/async timer composition and broader task cancellation |
| Tooling | Headless backend, selftests, smoke consumer, inspector/stats, platform ledger | Visual regression suite, interaction trace/replay, native runners, docs site/gallery, benchmark comparison harness |

---

## 4. Performance status after text caching and overflow repair

The old report’s 8,192-command table is obsolete. `MAX_RENDER_COMMANDS` and `MAX_SCENE_GLYPHS` are now both 16,384. Standard benchmark rows reject unexpected overflow, and the 256-paragraph capacity stress is skipped unless explicitly enabled.

**Machine:** AMD Ryzen 5 5625U, Linux x86_64

**Build:** ReleaseFast, deterministic packaged fonts
**Sampling:** nine measured iterations, three warmups

| Warm element workload | Median layout + paint | Scene glyphs | Drops | Cache behavior |
| --- | ---: | ---: | ---: | --- |
| 256 short labels | **0.150 ms** | 1,696 | 0 | `layout_shapes=0`, cross-frame hits |
| 256 sentences | **1.073 ms** | 8,320 | 0 | `layout_shapes=0`, cross-frame hits |
| 64 wrapped paragraphs | **1.542 ms** | 9,856 | 0 | `layout_shapes=0`, cross-frame hits |

The previous equivalents were approximately 2.12 ms, 9.65 ms, and 10.53 ms respectively. These runs are not a formal before/after experiment—the code, cache state, and compiler date differ—but they demonstrate that the new cache changes the warm-path order of magnitude.

The cold 16-label row remained about **16.0 ms**, including approximately **13.1 ms** of engine initialization. That is not application startup time.

With `--allow-overflow --iter 3 --warmup 1`, 256 wrapped paragraphs took about **6.24 ms** for cached element layout/paint, emitted 16,384 glyphs, and dropped 23,040 pushes. The benchmark labels this an intentional overflow stress and the application would reject the frame rather than present partial text.

### Interpretation

- The old correctness defect—presenting plausible but missing output—is fixed.
- The stress case still proves fixed scene capacity is finite. Virtualization remains mandatory for large content.
- Warm text shaping is now dramatically cheaper, but paint still scales with visible glyph count.
- The benchmark still omits CPU rasterization and native presentation, so it cannot support a 120 Hz framework claim.
- A real performance program still needs startup, full-frame raster/present, input latency, idle wakeups, allocations, RSS, tail latency, virtualized 100k-row behavior, and matched GPUI/DVUI output.

---

## 5. Immediate correctness and integration blockers

These deserve priority over adding more widget names.

### 5.1 AccessKit publication is wired but not screen-reader proven

The semantic model is valuable, and the Linux adapter is genuinely created with
`-Daccesskit=true`. The current bridge stores a ZUI-owned snapshot, constructs
fresh AccessKit nodes per update, transfers each node exactly once, and emits a
synthetic window root with top-level semantic children. The ownership/root
implementation is covered by the AccessKit-enabled build and snapshot design,
but no real screen-reader workflow has passed yet.

An earlier live todo AT-SPI probe saw an application frame with zero semantic
children, before the annotated Daybook path and its semantic selftests landed.
The current headless fixture publishes actionable roots and the AccessKit
snapshot test covers their parentage, but no live screen-reader workflow has
yet passed, so native accessibility is still unverified.

Additional gaps:

- Only the Unix adapter is instantiated (`accesskit.zig:111–120`).
- Windows/macOS AccessKit-enabled cross-target builds fail.
- Full snapshots are rebuilt instead of diffed.
- Text input exposes selection actions and AccessKit character-length metadata;
  full accessible text ranges and rich text-run geometry remain open.
- The 64-entry action queue rejects and logs overflow, but has no retry or
  coalescing policy.
- Semantic capacity is 512 (`MAX_A11Y_ELEMENTS`); larger trees are rejected
  rather than published partially.
- No Orca/NVDA/VoiceOver workflow has passed.

**Exit gate:** an annotated controls demo is navigable and actionable in Orca, NVDA, and VoiceOver; root/child/focus updates pass adapter-level tests; node ownership survives repeated update callbacks under an allocator checker.

### 5.2 Mounted entity scopes are implemented; soak evidence remains

`EntityHeader.window_id` and `EntityStore.destroyWindowScope()` now cover
`mountView()` roots and window-attached child entities. `App.reapClosed()` runs
the scope teardown before freeing the `Window`, and runtime tests verify scoped
entities die while app-lifetime entities survive. A longer lifecycle/allocation
soak across repeated native close/reopen cycles remains unverified.

### 5.3 Owner-table overflow is now fail-safe

The frame owner table is capped at 256. New targets first enter a tombstone
table whose regions dispatch as dead; if that table also fills,
`owner_overflow_fatal` rejects the frame before presentation. Regression tests
cover both tombstoning and fatal rejection. Larger-frame usability and capacity
budget tuning remain separate work.

### 5.4 Native event producers now escalate critical loss

The queue has explicit critical/coalescable/droppable policy. X11 input now
routes through the targeted helper; Wayland, Win32, Cocoa, and null paths use
critical escalation for releases, close, focus, text, and frame events. Ordinary
motion/scroll drops remain counted by the queue, and complete cross-target
runtime stress is still unverified.

### 5.5 CI and documentation are now mostly aligned

Default Windows/macOS compile checks are green and required in
`.github/workflows/ci.yml`. The platform matrix records compile-only evidence,
while native launch/behavior/validation remain explicitly open. Remaining
documentation work is maintenance: keep new renderer, accessibility, and
animation evidence synchronized as more platform gates land.

---

## 6. Remaining architectural gaps

### A. Extend the public custom-element and canvas protocol

The public custom-element lifecycle now exists: external code can provide
stable state, intrinsic measurement, prepaint, ordered Canvas/Scene emission,
semantic bindings, hit regions, and teardown. `tools/smoke_consumer` exercises
that contract out of tree without core edits.

The next extension is broader scene vocabulary:

1. Stable identity and optional retained element state.
2. Layout request and intrinsic measurement.
3. Prepaint after geometry is known.
4. Ordered paint through public canvas/scene primitives.
5. Semantic nodes and interaction regions using the same focus/owner model.
6. Teardown for retained resources.

Add arbitrary paths beyond the bounded line stroke, layers, rounded clip
stacks, richer transforms, and more canvas primitives. Keep ordinary `div()`
composition static and efficient;
custom elements should not force everything through heap-allocated dynamic
dispatch.

**Exit gate:** an external package implements a chart, terminal/editor surface, and variable-height virtual list without modifying ZUI.

### B. Make Zlay canonical while its supported contract continues to expand

Zlay is now the default dispatcher for real trees, and the todo/dashboard
selftests pass through it. `ZUI_LAYOUT=legacy` remains an explicit migration
escape hatch for consumers auditing unsupported style differences.

The adapter explicitly defers or differs on
advanced grid/intrinsic constraints, baselines, reverse flow, CSS overflow,
available-width text reflow, some percentage behavior, and legacy overflow
semantics (`src/elements/zlay_adapter.zig:43–53`). It rebuilds the Zlay tree
every dirty frame and has no stable-node cache.

The three historical grid disagreements now pass, and the repository has a
small external Taffy oracle gate covering flex growth/padding/gaps, wrapped
absolute positioning, center/space-between/padding, min/max constraints, basic
grid tracks/placement, column auto-flow, aspect-ratio sizing, and reverse flex
flow. The published dependency still
excludes the full fixture harness, so canonical status does not imply full CSS
or Taffy parity.

**Remaining exit gate:** broader public style coverage and full application
geometry/pixel fixtures pass at resize/fractional coordinates; unsupported
styles fail explicitly; the legacy escape hatch can then be removed.

### C. Complete input, focus, and text integration

The internal editing model is now strong for bounded single- and multiline
fields. Remaining work is at system boundaries:

- Validate the new Wayland text-input-v3 preedit/commit/cancel and caret path
  with a real compositor/IBus or Fcitx session; then add X11, Win32, and Cocoa
  native adapters.
- Convert native UTF-16/ranges explicitly at Windows/macOS boundaries.
- Add line/word selection refinements, native multiline IME integration, and
  large-document storage beyond the bounded model.
- Keyed `TextField` now publishes focus, bounded editable-value, and text
  selection actions in addition to selection/value state; character-length
  metadata is generated and tested, while full accessible ranges, richer
  text-run geometry, and native IME accessibility remain open.
- Cancel armed press/capture on focus loss, unmount, disable, modal replacement,
  and window close. The Window cancellation boundary and owner-tagged portal
  scope cleanup now cover the focused/widget paths; non-focusable custom owners
  still need an explicit cancellation hook.
- Move Space activation to conventional key-up behavior where appropriate.
- Keyboard events now follow the focused element ancestry through explicit
  capture and bubble listeners, matching GPUI's key dispatch order. Remaining
  propagation/default-action work includes modifiers-changed observers and
  extension beyond pointer/motion/scroll/keyboard to touch/pen/gesture,
  drag/drop, and touchpad phases.

Color bitmap glyphs now use a separate bounded RGBA atlas pool and Vellz image path. The color spike, atlas separation, and synthetic Vellz pixel test are covered; live emoji rendering and COLRv1 behavior remain host/font dependent.

### D. Extend the task/runtime and async asset layer

`images.Service` now has stable handles, states, tickets, stale completion
rejection, cancellation, reload, budgets, and worker-pool reads through the
App-owned `TaskRuntime`. Decode/place completions remain marshalled to the UI
thread, and ready assets do not perform paint-time I/O.

ZUI still needs:

- Foreground and background executors integrated with the event loop.
- Scoped tasks tied to entity/window lifetime.
- Cancellation and weak-target completion.
- UI-thread completion queue and invalidation.
- Deterministic clocks/executors for tests.
- Async HTTP/file asset sources without blocking typing or paint.

**Exit gate:** a resizable virtualized image browser loads thumbnails in workers, closes safely during work, and performs no ready-asset I/O or decode on the UI frame path.

### E. Finish the renderer boundary with one GPU backend

The CPU Vellz renderer is the working oracle. The root now exposes opt-in
Vellz/WGPU device, native Wayland surface, and solid/gradient/rounded/clip/image/
glyph/border scene-bridge gates; on this host they acquired the Mesa RADV Vulkan adapter with
`maxTextureDimension2D=8192`, presented three frames, and passed the bridge
test. The App now owns an explicit opt-in WGPU/Vellz bridge and passes the
Window scene plus glyph/image pools through its renderer controller; CPU
presentation remains the default compatibility mode. `gpu.render_backend.Controller` now owns the
explicit App/Window selection seam: CPU is selected by default, WGPU requires
compiled support plus a native surface and installed submit hooks, resize and
minimize invalidate or skip frames, and injected loss exercises one recreate
attempt before CPU fallback. `renderer-test` covers this policy headlessly;
the Wayland smoke wraps its real bridge frames with the same lifecycle state.
`gpu-offscreen-diff` now compares 4096 CPU/WGPU pixels for a retained
alpha/gradient/rounded/path/nearest-image scene fixture with zero mismatches
(maximum delta 2); the current host timing sample is CPU 5.29ms, bridge
3.52ms, render submission 5.69ms, and readback 0.47ms. Native device-loss
injection and backend hook installation in the default platform backends remain
unverified.
`vulkan.zig`, `metal.zig`, and `d3d12.zig` still return `error.Unsupported`.

Do not finish three low-level drivers in parallel. First connect one Vellz/WGPU path through a small UI renderer contract:

- Per-window surface, scale and resize/minimize handling.
- Scene/resource submission and explicit completion.
- Glyph/image upload and persistent caching.
- In-flight frame resource retirement.
- Device loss and deterministic CPU fallback.
- Same overlap, clip, opacity and image semantics as CPU.

The renderer still lacks arbitrary public custom paths, arbitrary nested
transforms, isolated group opacity, and real blur/shadow semantics. The
bounded line stroke and color-glyph paths are now scene-backed. These
remaining scene semantics should be defined before becoming GPU-specific
accidents.

### F. Broaden widgets after behavior contracts stabilize

Current exports are a legitimate first component library: `TextField`, Button, Checkbox, Switch, Slider, Progress, RadioGroup, ScrollArea, VirtualList, VirtualTable, Menu, ContextMenu, Select, ComboBox, Tooltip, Popover, Modal, and Dialog.

Remaining depth matters more than count:

- VirtualList now supports an opt-in bounded `HeightProvider`; very large jumps use an estimated extent until nearby rows are probed.
- VirtualTable now supports bounded variable row heights, retained column resize,
  and pointer/programmatic column reorder; richer reorder animations remain deferred.
- ComboBox is select-like rather than editable/filtering.
- Menu submenus are visual placeholders without full tree/keyboard behavior.
- ScrollArea still builds/measures arbitrary children; only virtual paths bound large content.
- Theme state is global mutable state, not per-window/system-aware.
- Callback and option slices often have borrowed lifetime contracts rather than scoped subscriptions.
- Reduced motion, high contrast, text scale, loading/error states, contrast audits, and native visual QA remain.
- The current component layer includes TextArea, TreeView, Tabs, SplitPane,
  command palette, docking, and editor primitives as bounded contracts. Missing
  depth still includes rich text/Markdown, date/time/color pickers, completion,
  diagnostics, minimap, persistent multi-level docking, and polished native
  behavior.

Do not add those as painted shells. Every component needs keyboard behavior, semantics, focus rules, disabled/loading/error states, and headless/native tests.

### G. Finish platform proof, not just platform source

The default project now compiles for Windows and macOS. Linux X11/Wayland multi-window and DPI source paths are substantially implemented. Evidence is still uneven:

| Target | Current evidence | Remaining proof |
| --- | --- | --- |
| Linux X11 | Native compile/launch, multi-window routing, env scale, optional XIM source path, partial live checks | XIM server/composition validation, RandR per-monitor scale, AT-SPI annotated controls, lifecycle soak |
| Linux Wayland | Native compile/launch, per-surface windows, fractional-scale protocol, optional text-input-v3 source path, live AT-SPI semantic/action probe | Real monitor migration, live IBus/Fcitx IME, clipboard/drag-drop soak, screen-reader speech validation |
| Windows | Default compile-only 16/16 (2026-09-22) | Native launch/input/DPI/clipboard/IME/a11y; multi-window; AccessKit-enabled build |
| macOS | Default compile-only 16/16 (2026-09-22) | Native launch/input/DPI/clipboard/IME/a11y; multi-window; AccessKit-enabled build |
| Headless | Unit/selftests, multi-window routing, snapshots | Visual golden suite and trace/replay |
| GPU | Opt-in WGPU/Wayland bridge with App/Window handoff; direct Vulkan/Metal/D3D12 drivers remain stubs | Pixel-differential proof, live device-loss injection, non-Wayland backend support |

Win32 and Cocoa still lack the per-window `createWindow` implementation used by Linux. Cocoa also retains global backend state. Default cross-target success must not be advertised as runtime support.

---

## 7. Comparison with GPUI and the Zig ecosystem

### GPUI remains the application-framework benchmark

Current GPUI provides typed/weak entities, subscriptions, custom element phases, Taffy integration, virtual lists, async executors, animations, capture/bubble input, tab stops, AccessKit, native services, multi-window platform backends, test contexts, profiler and inspector infrastructure. Its official README still describes it as pre-1.0 with frequent breaking changes and a source-led learning experience: https://github.com/zed-industries/zed/blob/main/crates/gpui/README.md

ZUI has now matched parts of that list: weak entities, stable semantic IDs, bounded variable-height virtualization, focus scopes, initial widgets, multi-window Linux, inspector stats, and a text cache. The remaining gap is no longer “everything around rendering”; it is extensibility, task/runtime integration, native validation, accessibility correctness, and product depth.

GPUI’s component ecosystem remains a second benchmark. GPUI Kit/GPUI Component supplies the polished controls, editing, tables, docking and themes developers actually consume. ZUI’s current widgets are foundation implementations, not yet an equivalent application system.

### DVUI remains the strongest immediate Zig usability baseline

DVUI documents a broad widget catalog, multiple backends, animations, themes, dialogs and AccessKit, but also acknowledges simple LTR/codepoint text and incomplete grapheme/bidi behavior: https://github.com/david-vanderson/dvui

ZUI’s most credible technical advantage is Cozmic-backed international text plus retained app state. DVUI remains ahead in breadth, embedding maturity, examples, and established widget behavior.

### Capy, zgui, Mach and zigui occupy adjacent positions

- Capy’s native controls offer inherited platform behavior but uneven control parity: https://github.com/capy-ui/capy
- zgui is excellent Dear ImGui tooling rather than a retained application framework: https://github.com/zig-gamedev/zgui
- Mach is a graphics/game ecosystem and possible interop target, not a complete accessible app toolkit: https://github.com/hexops/mach
- The young `ddalcu/zigui` validates demand for pure-Zig declarative UI with software/GPU fallback, so fluent Zig syntax alone is not a durable moat: https://github.com/ddalcu/zigui

### Specialization is the right architecture

Zlay, Cozmic, Vellz and AccessKit should remain independently testable subsystems behind narrow contracts. Xilem/Masonry follows a similar specialist-stack strategy, and AccessKit is explicitly designed for transient/immediate toolkits with stable IDs and incremental updates: https://github.com/linebender/xilem and https://github.com/AccessKit/accesskit

The risk is not using dependencies. The risk is claiming the feature of a dependency before ZUI’s adapter, lifecycle and native validation are complete.

---

## 8. A measurable definition of “better than GPUI”

Do not reduce this to raw FPS. ZUI wins only if ordinary developers can ship a complete application more predictably.

1. **Adoption:** an external user builds a substantial app from the documented package without private framework changes.
2. **Safety:** stale entities, callbacks, semantic actions, asset completions and tasks fail predictably; window close releases its mounted scope.
3. **Extensibility:** charts, editors, terminals and custom virtualization use a public element/canvas contract.
4. **International text:** graphemes, bidi, fallback, variable/color fonts, IME, selection and accessible text work together.
5. **Accessibility:** core flows pass Orca, NVDA and VoiceOver, not only semantic unit tests.
6. **Portability:** every advertised platform has compile, launch, behavior and manual-validation evidence.
7. **Rendering:** CPU and GPU produce equivalent complete scenes, with device-loss fallback and no silent overflow.
8. **Performance:** matched-output benchmarks report startup, p50/p95/p99 frame time, input latency, allocations, RSS, idle wakeups and dropped/rejected frames.
9. **Developer experience:** stable package recipe, searchable docs, gallery, inspector, actionable diagnostics and migration notes.
10. **Stability:** versioned public contracts, supported Zig revisions, changelog and compatibility policy.

Potential Zig advantages—comptime validation, explicit allocators, compact layouts and C interop—are opportunities, not automatic proof of speed or safety.

---

## 9. Revised delivery order

The old stages should be updated because much of Stage 0–3 now exists.

| Stage | Main work | Exit gate |
| --- | --- | --- |
| **0. Consolidate the new baseline** | Maintain AccessKit snapshot/root ownership; window-owned entity teardown; owner overflow; producer queue errors; capacity/docs/CI contradictions | Repeated windows/entities/a11y updates are leak/UAF-free; default cross checks are required CI jobs; capability docs agree |
| **1. Expand current integrations** | Broaden the supported Zlay style contract and oracle; move remaining demos to reusable widgets/semantics; validate Linux AccessKit with annotated controls | Supported styles have resize/fractional fixtures; demos are keyboard/screen-reader operable; legacy layout/press-time controls are no longer the primary examples |
| **2. Extensibility and task runtime** | Extend custom Canvas/scene vocabulary; scoped executor/tasks; async asset pipeline; trace/replay tests | External chart/editor/image-browser consumers need no core patch and close safely during work |
| **3. Native text and interaction** | Platform IME adapters, multiline text, accessible ranges, lifecycle capture cancellation, propagation, drag/drop/touch | Multilingual editing and modal/forms pass native keyboard, pointer, IME and a11y scenarios |
| **4. Renderer completion** | One Vellz GPU backend, persistent resources, retirement, device loss, CPU fallback, richer scene semantics | CPU/GPU differential fixtures pass; resize/minimize/device-loss soak is stable |
| **5. Platform and product depth** | Win/mac multi-window/native validation; variable virtualization; deep widgets/themes; docs/gallery | Published support matrix and component behavior specs match real native evidence |
| **6. Competitive proof** | External applications, fair GPUI/DVUI benchmark suite, release policy and migration guidance | Independent users ship without private patches; performance and support claims are reproducible |

### Sensible parallel ownership

Once shared identity/event/scene contracts are frozen, work can proceed in parallel:

- Runtime owner: mount scopes, tasks, cancellation, invalidation.
- Layout owner: Zlay contract, fixtures and migration.
- Text/input owner: native IME, multiline and accessibility ranges.
- Accessibility owner: bridge ownership/root/diffs and native AT validation.
- Renderer owner: public scene/canvas and one GPU backend.
- Platform owners: implementation behind agreed window/input/scale contracts.
- Widget/tooling owner: components, semantics, gallery, inspector and visual tests.

Do not allow each workstream to invent separate IDs, ownership rules, event propagation, task cancellation or resource handles.

---

## 10. Documentation and release hygiene

Recent work fixed many previous release blockers:

- Root license and notice exist.
- Package paths include README, plan, report, platform matrix, license and smoke consumer.
- A consumer smoke build exists.
- CI and a platform evidence matrix exist.
- README architecture and capability descriptions are substantially fresher.

Remaining cleanup:

- Make now-green default Windows/macOS checks required, not `continue-on-error`.
- Add separate optional-feature jobs, especially `-Daccesskit=true`, and keep them red until supported rather than hiding them behind the default-off configuration.
- Correct stale one-window, partial-overflow and accessibility statements across README/docs/source comments.
- Run a clean-cache release verification periodically; cached green tests are not sufficient release evidence.
- Add sanitizers/fuzzing for AccessKit ownership, images/SVG/fonts, Unicode edits, event saturation, layout mutation and stale handles.
- Add a semantically annotated component gallery and pixel/semantic golden tests.
- Record native validation with OS, compositor, scale, screen reader and backend versions.
- Keep public repository state and published Zlay/Cozmic/Vellz pins synchronized.

---

## Final recommendation

The recent work was well targeted. It addressed the earlier report’s highest-value foundations instead of merely expanding GPU stubs or visual demos. ZUI now has enough architecture to justify building real applications against it.

The next step is consolidation. Fix the AccessKit bridge and mount lifetime, deepen the now-canonical Zlay and semantic-widget paths, add a public custom-element/task model, then prove native text/accessibility/platform behavior. Those steps will produce more competitive value than another batch of surface-level controls.

The credible long-term position remains:

> A pure-Zig application UI framework with explicit ownership, excellent international text, accessibility and automation by default, deterministic CPU/GPU rendering, and unusually strong diagnostics.

That position is now more plausible than it was two days ago. It is not yet proven.

---

## Primary sources

Live upstream sources were consulted during the original 2026-09-16 assessment; current local conclusions were refreshed from the 2026-09-18 tree.

1. GPUI: https://github.com/zed-industries/zed/tree/main/crates/gpui
2. GPUI accessibility guide: https://raw.githubusercontent.com/zed-industries/zed/main/crates/gpui/src/_accessibility.rs
3. GPUI Kit: https://github.com/longbridge/gpui-kit
4. DVUI: https://github.com/david-vanderson/dvui
5. Capy: https://github.com/capy-ui/capy
6. AccessKit and C bindings: https://github.com/AccessKit/accesskit and https://github.com/AccessKit/accesskit-c
7. Xilem/Masonry: https://github.com/linebender/xilem
8. Vello: https://github.com/linebender/vello
9. Slint: https://github.com/slint-ui/slint
10. SDL3 high DPI and IME area contracts: https://wiki.libsdl.org/SDL3/README-highdpi and https://wiki.libsdl.org/SDL3/SDL_SetTextInputArea
11. Unicode grapheme segmentation: https://www.unicode.org/reports/tr29/
12. HarfBuzz shaping concepts: https://harfbuzz.github.io/shaping-concepts.html
13. Local evidence: `build.zig`, `build.zig.zon`, `.github/workflows/ci.yml`, `docs/`, `tools/bench_text.zig`, `tools/smoke_consumer/`, `tools/references.env`, and the source paths cited above.
