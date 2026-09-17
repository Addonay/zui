# ZUI: gap analysis and a route beyond GPUI

**Assessment date:** 2026-09-16
**Scope:** the current ZUI working tree, the local GPUI reference, selected Gooey source/docs, and current upstream documentation. This is a research report, not a feature-parity certification.

## Executive verdict

**ZUI has a credible architecture and working vertical slices, but is not yet a production-general-purpose UI toolkit. Its biggest deficit is not the choice of programming language or renderer: it is the integration and completeness of application-facing behavior.**

The retained `App`/`Entity` state plus transient element tree is a reasonable foundation. Keep it. The independently packaged Cozmic, Zlay, and Vellz stack is also an asset. However:

- Zlay is imported and tested but does not lay out ordinary ZUI elements.
- Vellz CPU rendering is integrated; its GPU functionality is not connected to ZUI's native presentation path.
- Cozmic shapes text, but ZUI still has a limited text field and cannot display color glyph bitmaps through its coverage-only atlas.
- Dashboard checkboxes, tables, dragging, and scrolling demonstrate useful behavior, but do not constitute a reusable, keyboard-accessible widget system.
- The framework lacks the stable identity, semantic tree, task lifecycle, and native-window boundaries needed by larger applications.

**The strongest positioning is: a dependable, internationalized, accessible desktop application toolkit for Zig, with explicit ownership, excellent diagnostics, and measured performance.** Merely reproducing GPUI's fluent builder syntax or making a dashboard look similar will not achieve that.

There are two different competitors:

1. **GPUI core:** rendering, element lifecycle, layout, entities, actions, input, tasks, window/platform services.
2. **GPUI's application ecosystem:** notably GPUI Kit / GPUI Component, which supplies the polished controls and data-oriented behavior developers actually ship.

Compete with both deliberately. Do not count the ecosystem's widgets as GPUI-core features, but do not ignore them when asking why a developer would choose ZUI.

---

## 1. Evidence and limitations

### What was inspected

- ZUI build configuration, package manifest, public exports, runtime, window dispatch, layout, painter, scene, text engine, atlas, text field, limits, and selected platform paths.
- GPUI's local README, element lifecycle, Taffy adapter, accessibility guide, input interfaces, context API references, platform manifests, and module inventory.
- Gooey's local README and selected animation/table implementation references.
- Current upstream primary documentation for DVUI, GPUI Kit, AccessKit, Vello, Xilem/Masonry, egui, Slint, and SDL3.

`tools/references.env` records GPUI revision `33375c34b9301dd850b0e6d9781fd00acace6953`, DVUI `a11cd712d48f08a7f8bb934e6f0f210f8b91603c`, Gooey `32ed73441c7c85940955da64532bdde3c9ee6c2a`, and Taffy `1b918bafcab101dd234ebeb27da0443e24fd9de2`. These are the repository's recorded reference pins; this assessment did not independently validate every checkout against its pin. Live web documentation can describe a newer baseline.

The local conclusions were established by direct inspection and executable checks. Three bounded Luna reviews then independently covered GPUI architecture, platform/rendering quality, and the current competitive landscape. Their findings were treated as leads and retained here only where the source tree or a primary upstream source supported them.

### Executed checks

| Check                                                                              | Observed result                                                                        |
| ---------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------- |
| `zig version`                                                                      | `0.17.0-dev.2131+d08989840`                                                            |
| `zig build test --summary all`                                                     | **16/16 build steps succeeded**                                                        |
| Todo integration run within that command                                           | **15 checks passed**, including focus, typing, add/toggle, and final-page reachability |
| Dashboard integration run within that command                                      | **22 checks passed**, including navigation, row dragging, scrolling, and search typing |
| Unit-test run artifacts                                                            | **Cached**; no fresh unit-test count claimed                                           |
| `zig build bench-text -Doptimize=ReleaseFast -- --format json`                   | Executed successfully with nine measured iterations and three warmups; exposed draw-capacity overflow |
| `zig build run-todo -Dtarget=x86_64-windows-gnu --summary all`                    | Compilation failed with two errors: X11 target leakage and Win32 optional-function handling |
| `zig build run-todo -Dtarget=aarch64-macos-none --summary all`                    | Compilation failed with 65 errors: dynamic-loader alignment, Linux target leakage, and Cocoa ABI/type issues |

No fresh live native GUI interaction, cross-OS runtime validation, GPU execution, external-consumer package smoke test, allocation profiling, or GPUI benchmark was performed. A 1600 x 1000 headless dashboard snapshot was rendered and visually inspected, but one snapshot does not establish native presentation, interaction quality, or visual parity.

Existing modifications in `README.md`, `src/app/runtime.zig`, and `src/elements/element.zig` were treated as user work and left untouched. The README review marker was pre-existing; no repository instruction requiring it was found. No implementation change is part of this report.

### Size is context, not a score

ZUI currently has approximately **20,768 lines of Zig under `src/`**, including tests/comments, excluding its major packaged dependencies:

| Module      | Lines |
| ----------- | ----: |
| `platform/` | 6,959 |
| `gpu/`      | 4,366 |
| `elements/` | 3,372 |
| `app/`      | 2,582 |
| `fonts/`    | 1,460 |
| `images/`   |   854 |
| `core/`     |   718 |
| `widgets/`  |   345 |

The locally available GPUI reference contains roughly 129,293 Rust lines across 206 files. It is a selected checkout, not a complete dependency accounting. These counts do **not** establish relative complexity, binary size, memory use, or speed.

---

## 2. What is already better than the old roadmap suggests

Do not restart work already present in the current tree.

| Historical gap                                       | Current  evidence                                                                                                                                                          |
| ---------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Cross-type drawing order lost                        | `src/gpu/scene.zig:42–55` defines an ordered command stream; `src/gpu/vellz.zig:139–169` consumes it in order.                                                            |
| Close during a callback immediately frees the window | `src/app/window.zig:209–215` marks closed; `src/app/app.zig:322–337` reaps at safe points.                                                                                |
| Entity updates outside a window fail to redraw       | `src/app/app.zig:399–409` fans entity dirtiness out to live windows.                                                                                                      |
| Render-time invalidation gets erased                 | `src/app/window.zig:179–185` clears dirty **before** invoking rendering.                                                                                                  |
| Text shaping repeated by ordinary measure and paint  | Measured Cozmic layouts are handed to paint; the benchmark reports `paint_shapes: 0` on element rows. This is per-frame reuse, not persistent cross-frame layout caching. |
| Text field is append-only and can split UTF-8        | `src/widgets/text_field.zig:119–184` implements caret movement, insertion at the caret, deletion, validation, and codepoint-safe capacity clipping.                       |
| No pointer capture or pointer-targeted scrolling     | `src/app/window.zig` contains capture/motion/release handling and scroll-listener hit testing.                                                                            |
| Disappearing focus target retains keyboard focus     | `src/app/window.zig:357–369` clears missing focused handles.                                                                                                              |
| Mid-frame atlas overwrite                            | `src/fonts/atlas.zig:11–18` defers eviction and reports overflow rather than overwriting referenced glyph storage.                                                        |
| Image handles have no stale check                    | `src/elements/painter.zig:203–209` validates retained handles before drawing.                                                                                             |
| No example integration coverage                      | `build.zig:114–123,161–168` runs todo and dashboard selftests from the normal test target.                                                                                |

These are valuable improvements, but several are deliberately interim policies. Deferred atlas eviction still permits missing glyphs on overflow; a safe single-window restriction is not multi-window support.

The README and `plan.md` need a status refresh. In particular, the README still describes unordered painting and append-only input, and references an old local layout directory. Its minimum compiler statement also differs from `build.zig.zon`.

---

## 3. The most actionable finding: the text benchmark already drops content

**Machine:** AMD Ryzen 5 5625U, Linux x86_64.
**Build:** ReleaseFast, deterministic packaged font corpus.
**Sampling:** nine measured iterations, three warmups. Treat this as diagnostic evidence, not a statistically robust performance publication.

The benchmark measures layout plus scene emission. It does **not** include Vellz frame rasterization, native presentation, or end-to-end input latency.

| Workload               | Reported median layout + paint | Emitted scene glyphs | Dropped scene pushes |
| ---------------------- | -----------------------------: | -------------------: | -------------------: |
| 64 short labels        |                       0.544 ms |                  424 |                    0 |
| 256 short labels       |                       2.122 ms |                1,696 |                    0 |
| 64 sentences           |                       2.379 ms |                2,080 |                    0 |
| 256 sentences          |                       9.648 ms |                8,192 |              **128** |
| 16 wrapped paragraphs  |                       2.531 ms |                2,464 |                    0 |
| 64 wrapped paragraphs  |                      10.527 ms |                8,192 |            **1,664** |
| 256 wrapped paragraphs |                      43.487 ms |                8,192 |           **31,232** |

The cold 16-label row was approximately 14.98 ms, including 11.82 ms of engine initialization. That is **not application startup time**. The glyph payload ceiling remains 16,384, while the ordered command ceiling is reached first at 8,192.

### Why this matters

`src/core/limits.zig` allows 65,536 quad payloads and 16,384 scene-glyph payloads, but only **8,192 ordered commands total**. Every emitted glyph uses a command. The command stream becomes the effective ceiling before those payload arrays fill.

The comment in `src/gpu/scene.zig:36–39` assumes this cap is comfortably large. The existing benchmark disproves that assumption. `Scene.dropped` makes loss observable to instrumentation, but does not make a partially rendered application acceptable.

**Recommended response:**

1. Establish a frame overflow policy: reserve/grow at safe boundaries, reject incomplete frames explicitly, or use a documented constrained profile. Do not silently present missing content.
2. Make command and payload capacities coherent; consider glyph-run commands referencing contiguous payload ranges.
3. Add correctness gates for emitted counts and overflow to benchmark runs. Keep an intentional overflow suite separate from performance-success results.
4. Cache unchanged text layouts across frames, with keys that include text, font instance/fallback configuration, size, width, tracking, and other shaping inputs.
5. Virtualize large lists and paragraphs; avoid shaping invisible content just to discard its pixels.
6. Measure allocations and dependency-level shaping before changing Cozmic algorithms.

### Additional concrete defects found during this review

These are smaller than the architectural gaps, but they affect foundations the future design will depend on:

- `src/platform/id.zig:22–30` writes the source column to bytes 4–7 and then overwrites those bytes with the low half of `extra`. Two call sites on the same file and line can therefore collide even when their columns differ. Stable IDs underpin focus, retained state, accessibility, automation, and inspector data; repair the representation and add collision regressions before using it broadly.
- `src/images/cache.zig:73–77` exposes `Cache.pixels(handle)` without validating the handle generation. Internal painter paths validate first, but the public operation is unsafe to call directly with a stale handle. Make stale validation inseparable from resolution.
- `EventQueue` is a fixed 256-entry ring and `push()` reports failure, but backend producers commonly ignore that result. Motion and resize may be coalesced; key/button releases, close, composition commits, and focus loss must not disappear. Define priority and overflow behavior before broadening input support.
- Element-node and text-storage exhaustion still panic, while scene and hit-region overflow can produce incomplete output. A single documented capacity policy should distinguish recoverable growth, rejected frames, diagnostic placeholders, and preserved critical events.

A larger command cap would remove this particular sentence-workload failure, but is not the architectural solution: it increases memory, leaves payload ceilings, and does not reduce shaping time. GPU acceleration also does not eliminate CPU-side layout cost.

---

## 4. Gap matrix against GPUI

GPUI paths below are relative to `.references/gpui/crates/`.

| Area                       | ZUI today                                                                   | GPUI/reference capability                                                                   | Missing work                                                                |
| -------------------------- | --------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------- |
| State and ownership        | Typed entity wrappers around app-lifetime allocations                       | Entity/weak-handle model, subscriptions, observations, release handling                     | Explicit entity release, stale-safe handles, teardown, mutation policy      |
| Element lifecycle          | Fixed node kinds; recursive measure/place/paint; TLS frame                  | `gpui/src/element.rs`: request-layout, prepaint, paint, global IDs, custom elements         | Stable keyed identity and a supported custom-element lifecycle              |
| Layout                     | Custom row/column/grow/wrap/absolute subset                                 | `gpui/src/taffy.rs`: real Taffy adapter with measurement and scale-aware rounding           | Connect Zlay, define style semantics, integrate grid/intrinsic sizing       |
| Text rendering             | Cozmic layout, FreeType-backed masks, measure→paint handoff                 | Platform text systems, shaped-line APIs, separate glyph/emoji painting                      | Color glyphs, fractional sizing/DPI quality, richer text runs and reuse     |
| Text editing               | Single-line, 512-byte buffer, codepoint caret/delete, whole-field clipboard | `gpui/src/input.rs`: marked/selected ranges, replacement, IME-facing protocol               | Selection, grapheme and bidi navigation, undo, composition, multiline       |
| Interaction                | Hover, focus handle, keymap, basic capture, hit-tested scrolling            | Dispatch tree, tab stops, interaction primitives, gestures                                  | Correct activation/release, focus scopes, propagation, capture cancellation |
| Accessibility              | No connected semantic-tree/bridge implementation found                      | AccessKit documented in `gpui/src/_accessibility.rs`; native adapters in platform manifests | Stable semantics plus AT-SPI/UIA/NSAccessibility integration                |
| Graphics                   | Ordered quads, mask glyphs, images, limited gradients and effects           | Paths, shadows, sprites, text decorations, GPU platform renderers                           | Native GPU path and richer scene operations with identical CPU semantics    |
| Native windows             | One native window explicitly enforced                                       | Per-window platform abstractions and window services                                        | Native ownership/event targeting, per-window surfaces, scaling              |
| Async/application services | No general task/subscription layer in inspected runtime                     | Executors, cancellable tasks, subscriptions, asset services                                 | UI-thread completion queue, cancellation, lifetime-safe async updates       |
| Virtualization             | Example-specific paging/scrolling; no reusable virtual list export          | `elements/list.rs`, `uniform_list.rs`                                                       | Fixed/variable-height lists, anchor preservation, virtual table             |
| Motion                     | `requestAnimationFrame()` and monotonic clock helper                        | `elements/animation.rs`, `spring.rs`                                                        | Timeline/springs, interruption policy, reduced motion, deadline scheduling  |
| Debugging                  | Logging, counters, headless tests, text benchmark                           | Inspector, debug overlay, profiler, test contexts                                           | Integrated geometry/identity/focus/semantic/resource inspector              |
| Components/themes          | One widget export (`TextField`); demo-local visuals                         | Core primitives plus external GPUI Kit component system                                     | Behavior primitives, tokenized themes, accessible reusable controls         |

### GPUI details worth copying, not blindly porting

- **Separate layout, prepaint, and paint.** Prepaint is a useful place to establish hit regions, deferred overlays, and viewport-dependent work after geometry is known. A custom chart/editor should not require modifying ZUI's central `NodeKind` switch.
- **Stable global identity.** GPUI composes element IDs through ancestors. ZUI's `Element` currently holds only a `u16` index resolved through the active TLS frame (`element.zig:325–353`). That index is not a persistent identity.
- **One logical interaction dispatch model.** Keyboard, pointer, and accessibility activation should converge on the same control behavior.
- **Task ownership is explicit.** Adopt cancellation and weak-target semantics, not necessarily Rust futures or the exact GPUI executor design.
- **Keep platform and renderer responsibilities distinct.** The inspected Linux manifest uses `gpui_wgpu`; macOS documentation specifies Metal; Windows has DirectX/DirectWrite modules. Do not design against outdated claims that GPUI universally uses Blade.

There are also opportunities to improve on GPUI. Its local README explicitly warns of pre-1.0 breaking changes and recommends reading Zed source for learning. Its accessibility guide documents duplicate source-derived IDs causing dropped nodes in release builds (`_accessibility.rs:109–164`). ZUI can offer better diagnostics and more predictable public APIs here. This is not evidence that GPUI lacks documentation entirely or that ZUI is already easier to use.

---

## 5. Highest-priority missing systems

### A. Stable identity, ownership, and application lifetime

**Evidence:** `src/app/runtime.zig:22–75` stores allocations in an app-lifetime linked list; `Entity` exposes raw value pointers, including `readMut()`. Listeners borrow entity headers. There is no ordinary individual release path in this API.

Before adding general background tasks, implement:

- Explicit owned and weak/generation-checked entity handles, or an equally well-specified scoped ownership model.
- Root/child entity lifetime and subscription cleanup.
- Checked callback resolution after unmount and window close.
- A mutation API with reliable invalidation; unrestricted `readMut()` should not silently bypass it.
- Stable keyed element IDs, duplicate detection, and frame-generation checks for transient handles.
- UI-thread ownership assertions and a safe completion queue for worker results.

**Acceptance:** repeatedly open/close documents without growing retained entities; late completions cannot mutate destroyed targets; keyed row state follows data when reordered; escaped element handles fail predictably.

### A2. A supported custom-element lifecycle

ZUI's public `Element` is a concrete index into the active frame, and `NodeKind` is closed over container, text, spacer, and image. Consumers can compose those primitives, but cannot implement an element that owns custom layout state, performs viewport-aware prepaint, establishes its own hit/semantic nodes, or emits custom scene content without changing framework switches.

Add an extensible element protocol with explicit phases:

1. Stable identity and optional retained element state.
2. Layout request plus intrinsic measurement callback.
3. Prepaint after geometry is known, including hit regions, clipping, focus and semantic nodes.
4. Ordered paint into a public canvas/scene interface.
5. Teardown for retained resources and subscriptions.

Keep `div()`, `text()`, and images as optimized built-ins. The protocol is an escape hatch for editors, charts, terminals, canvases, virtual lists, and third-party widgets; it should not force every ordinary control into dynamic dispatch.

**Acceptance:** an external package implements a virtualized custom element and a canvas/chart without modifying ZUI, reaches the same input/accessibility systems as built-ins, and is covered by headless layout/paint tests.

### B. Text editing and internationalization

Codepoint-safe editing is progress, not complete Unicode editing. An accented grapheme or emoji family can contain multiple codepoints. Byte-order left/right movement is not visual bidi navigation.

Build a shared editing model with:

- Selection anchor/active end, pointer hit testing, shift-selection, word/line movement, select-all.
- Grapheme-aware deletion and visual caret movement using shaped clusters.
- Selection-aware clipboard, undo/redo, and configurable input limits.
- Horizontal scrolling, caret visibility/blinking, multiline editing.
- IME preedit/marked range, commit, cancellation, surrounding-text queries, replacement ranges, and caret rectangle reporting.
- Explicit UTF-8 ↔ native UTF-16/range conversion at platform boundaries.
- Locale-aware key behavior and an eventual localization/direction API.

`platform/event.zig:123–146` only has a fixed 32-byte text commit event and no composition protocol. Correct IME cannot be added solely inside `TextField`.

The coverage-only atlas explicitly rejects color glyphs (`fonts/atlas.zig:20–24`). Cozmic or Vellz supporting a font feature does not automatically expose that feature through ZUI.

**Acceptance:** edit Latin combining marks, Arabic/Hebrew mixed with Latin, CJK composition, emoji sequences, pasted long text, and wrapped selections; validate candidate placement and cancellation on real OS input methods.

### C. Interaction and accessibility as foundations

`window.zig:409` invokes the click listener on **press**. Existing capture handles drag motion/release but does not establish conventional button activation semantics.

Required:

- Press/release/click distinction; press-inside/release-outside cancellation.
- Capture cancellation on focus loss, unmount, and window teardown.
- Capture/bubble propagation and default-action rules.
- Tab/shift-tab traversal, focus scopes, modal focus trapping/restoration, visible focus indicators.
- Nested scrolling with defined delta units, consumption/chaining, and touchpad phases where available.
- Accessible roles, names, values, states, bounds, relationships, and actions.
- Reduced-motion, text-scale, contrast, and theme integration.

The todo's Tab shortcut is not a general focus traversal system. Constants named `MAX_A11Y_ELEMENTS` are not an accessibility implementation.

**Recommendation:** use AccessKit's C API initially rather than independently reproducing three desktop accessibility bridges. Keep ZUI's semantic model independent of that binding. AccessKit still needs correct widget semantics and native screen-reader tests.

### D. One real layout engine

`runtime.mountView()` calls `elements.layout.layout()`, which uses its own recursive algorithm; the file does not import Zlay. Exporting `zui.layout` and testing the dependency separately does not integrate it.

Add a narrow adapter for the current styles, then extend to flex shrink/basis, min/max/intrinsic sizes, percentages, alignment/baselines, grid, aspect ratio, and explicit overflow semantics. Define box sizing and fractional rounding rather than copying CSS names without their behavior.

The old plan's three grid disagreements are historical findings, not freshly reproduced defects in the current dependency. Re-run those regressions and the current Zlay oracle before migration; do not assume the old failures remain.

**Acceptance:** real todo/dashboard trees go through Zlay, resize correctly, and agree with pinned fixtures. Advertise grid only after public element tests exercise it.

### E. Rendering, GPU integration, and resource completeness

ZUI currently translates its small scene into `vellz.cpu.RenderContext`. Native presentation remains CPU-backed; `vulkan.zig`, `metal.zig`, and `d3d12.zig` initializers still return `error.Unsupported`.

Do not implement an entire SDL-like GPU API merely to draw UI. First evaluate the already packaged Vellz GPU interface against ZUI's real resource/surface needs and verify its current behavior independently.

Create a small contract around scene submission, resource resolution, per-window surface, scale, completion, and failure. Prove one GPU/native vertical slice before expanding backends.

The scene also needs stronger semantics:

- Paths/strokes and custom canvas rendering for charts, diagrams, and editors.
- Nested clips, transforms, stacking/overlays, and explicit overflow.
- True isolated group opacity: multiplying alpha per child gives different overlap results.
- Real blur/shadows where advertised. `painter.zig:98–125` currently uses layered approximations.
- Color glyphs and richer gradients through the public scene.
- Persistent image resources and safe retirement for in-flight GPU frames.

`painter.zig:155–162` clips every child to the parent's rectangular content box. A rounded background is not automatically a rounded descendant clip. Menus/popovers need deliberate escape/overlay behavior.

**Acceptance:** CPU/GPU comparisons cover text-image-quad overlap, nested clips/layers, resize/minimize, missing resources, and device loss; surface creation errors are not disguised as successful support.

### F. Scheduling, frame pacing, and assets

`App.run()` waits up to 16 ms after each native step (`app.zig:451–459`); key sequences expire by ticks (`app.zig:424–426`). This is not a display-aware timing policy. Backend wake behavior can affect actual timing, so the source alone does not establish a measured frame-rate cap.

Replace this with input/completion/deadline-driven wakeups and native frame pacing. Idle windows should not wake periodically merely to discover there is no work. Animated windows should follow display timing; timers must use monotonic deadlines.

Path images are read for intrinsic size during element construction (`element.zig:651–666`) and read again on the painting path (`painter.zig:203–209`). Move loading/probing/decoding out of frame construction into an asset service with loading/ready/failed states, placeholders, deduplication, cancellation, and UI-thread completion.

**Acceptance:** ready assets incur no repeated file I/O; background loading does not block typing; idle wakeups and animation pacing are measured; closing a view cancels its owned work.

### G. Real native windows and DPI

`App` owns one backend and explicitly rejects a second live native window (`app.zig:208–213`). Events have no destination window ID. The platform reports scale factors, but `Window` and the element/render contract do not implement a complete per-window logical/physical pipeline.

Required:

- Shared application connection, independent native windows and renderer surfaces.
- Window-targeted input, focus, resize, close, and scale events.
- Distinct logical layout units, native window coordinates, framebuffer pixels, and content scale.
- Fractional-scale font/atlas invalidation and input normalization.
- Native dialogs, drag/drop interop, richer clipboard formats, URL/file opening, and platform menu integration as support grows.

**Acceptance:** two windows on differently scaled monitors stay independent; moving either window preserves text sharpness and hit alignment. Run actual Windows/macOS tests before advertising parity. Source presence and Linux tests of `UnsupportedPlatform` are not platform support evidence.

### H. Portability and platform correctness are current build blockers

The Windows and macOS sources are not merely unverified; with the current compiler, representative foreign-target builds do not compile:

- `x86_64-windows-gnu` fails because `src/platform/linux/x11.zig:203` performs a target-invalid `XEvent` size assertion and `src/platform/windows/win32.zig:221` mishandles the optional `GetDpiForWindow` lookup type.
- `aarch64-macos-none` fails with 65 diagnostics. The dominant classes are alignment-increasing function-pointer casts in `src/platform/dl.zig:56`, Linux Wayland/X11 modules being instantiated for the macOS target, similar Objective-C message-send alignment casts, and a nested-optional Objective-C ABI type.

This means the accurate support vocabulary is currently:

- Linux Wayland/X11: source plus local tests and prior runtime use, but this review did not perform live interaction.
- Windows/macOS: source present, foreign-target compilation failing, native runtime unverified.
- GPU: API and stub sources present, no operational ZUI GPU presentation path.
- Headless: exercised by integration tests and snapshot output.

Create compile-only build steps that do not attempt to execute foreign binaries, and run them in CI for every supported target. Native runners must separately prove launch, input, clipboard, IME, DPI, accessibility, multi-window, suspend/resume, renderer fallback, and teardown.

**Acceptance:** the published platform matrix distinguishes source presence, compile, launch, automated behavior, and manual native validation; no platform is called supported solely because its file exists.

---

## 6. A widget library, not a collection of attractive demos

`src/widgets/root.zig` exports only `TextField`. Primitive composition is useful, but consumers should not rebuild button semantics, dropdown dismissal, tab navigation, and table selection themselves.

Use three logical layers; they need not be separate repositories initially:

1. **Foundation:** runtime, identity, layout, scene, input, semantics, platform, tasks/assets.
2. **Behavior primitives:** pressable, selectable, focus scope, scroll model, overlay manager, editing model, virtualization.
3. **Styled components:** controls using semantic tokens and replaceable presentation.

### First component set

- Button/IconButton, Checkbox, RadioGroup, Switch.
- TextInput/TextArea, Label, form validation/helper/error text.
- ScrollArea, fixed-height virtual list, then variable-height virtual list.
- Menu/ContextMenu, Tooltip, Popover, Modal/Dialog, Select/ComboBox.
- Tabs, Slider, Progress, SplitPane, TreeView.

### Application-grade set after the foundations

- Virtual table with sorting, selection, resizing, sticky headers, keyboard movement, and async data.
- Command palette and searchable lists.
- Docking/split layouts with persisted state.
- Rich text/Markdown and chart primitives where supported by real consumers.

Theme tokens should cover colors, typography, spacing, radii, focus rings, elevation, density, disabled/hover/pressed/loading/error states, and motion. Light/dark mode must not just swap a background color.

Move demo-specific progress/date helpers out of foundational elements over time (`element.zig:773–798`). Keep a supported custom-element/canvas escape hatch so extending the library does not require a core fork.

---

## 7. Ecosystem research: what matters now

These are upstream documentation claims unless explicitly tied to inspected source or executed checks.

### DVUI: a strong Zig usability benchmark

DVUI documents a substantial widget catalog, multiple backends, touch selection, animations, themes, native file dialogs, AccessKit, and input-aware wait scheduling. It also explicitly documents simple left-to-right, one-glyph-per-codepoint text, no grapheme support, and no bidi text in its current README.

**Lesson:** ZUI can differentiate with high-quality international text and retained application state, but DVUI already sets a higher baseline for widgets, accessibility plumbing, examples, and embedding. Do not call those empty territory.

### Capy: native controls expose a different parity problem

Capy advertises declarative Zig UI, native operating-system controls, accessibility, cross-compilation, small executables, and desktop/web coverage. Its own component matrix is also candid: controls vary substantially by backend, with macOS and mobile missing many canvas, scrolling, selection, and editing features, and the project remains pre-production with breaking changes.

**Lesson:** native widgets can inherit platform accessibility and appearance, but a library then owns a persistent cross-platform behavior-parity problem. ZUI's custom-rendered approach can offer one semantic and visual model everywhere, provided it builds real accessibility adapters and platform integration rather than assuming custom drawing is portable by itself.

### zgui and Mach: adjacent tooling and rendering ecosystems

`zgui` provides strong Dear ImGui bindings plus plotting, gizmos, node editing, and test-engine support. It is a compelling game/editor tooling solution, not a complete retained desktop-application framework. Mach is a prominent Zig graphics/game toolkit and a possible interop or renderer target, but its official documentation still characterizes the project as experimental and evolving.

**Lesson:** ZUI should interoperate with game/rendering ecosystems where useful, but its differentiation is application semantics: durable state, Unicode editing, accessibility, native services, structured layout, automation, and production widgets.

### zigui: a young direct competitor worth tracking

The newer `ddalcu/zigui` project is explicitly pre-alpha, but its direction validates demand for a pure-Zig declarative/value-tree API, software rendering with SDL3 GPU fallback, multiple theme families, and editor primitives. Its published deferred work includes accessibility, HiDPI, navigation, tabs, modals, grids, materials, and animation.

**Lesson:** “pure Zig plus a fluent tree” will not remain a unique pitch. ZUI should win through verified semantics, international text, accessibility, diagnostics, package stability, and real applications rather than syntax resemblance.

### Gooey: a direct architectural competitor

The local README advertises GPU rendering, dynamic entity cleanup, animations, IME, accessibility, virtual lists, and tables. Selected source includes an animation store and virtualized table implementation. These claims were not native-runtime validated here.

**Lesson:** the differentiator cannot simply be “GPUI-like, but Zig.” Demonstrate correctness, portability, diagnostics, and application completeness. Borrow API lessons without assuming another framework's feature list proves parity.

### GPUI Kit: the real application-level bar

Current GPUI Kit documentation describes an unstyled behavior foundation plus a styled component system, 60+ controls, virtual lists/tables, docking, editing, charts, and theming. Its 120 FPS and large-document claims are vendor claims, not a comparable benchmark measured in this session.

**Lesson:** behavior/presentation separation and a searchable component gallery are central product features. Your `examples/dash-gpui` uses `gpui-kit = "0.6.1"`, not just raw GPUI. It is a useful paired consumer, **not yet a controlled benchmark harness**.

### Xilem/Masonry and AccessKit: specialization pays

Xilem/Masonry documents separate framework/widget layers and specialized windowing, renderer, text, and accessibility dependencies. AccessKit provides schema, incremental tree updates, platform adapters, and C bindings; stable IDs are fundamental. Its own README notes remaining limitations, including rich/hypertext support.

**Lesson:** maintain narrow interfaces between Zlay, Cozmic, Vellz, and semantics. Dependency integration is not a compromise to hide; it is the architecture to verify.

AccessKit's released adapters cover Windows UI Automation, macOS NSAccessibility, Unix AT-SPI, Android, and iOS, and its C bindings make a Zig integration feasible. Its schema is built around stable node IDs, roles, properties, actions, and incremental tree updates, which fits ZUI's transient-tree architecture. It still does not remove the need for correct widget semantics, text-range mapping, focus synchronization, and real assistive-technology testing.

### Vello: distinguish the renderer families

Current Vello docs distinguish CPU Sparse Strips, CPU-preprocessed GPU rasterization/compositing, and an experimental compute-centric renderer. CPU is described as more mature overall; the GPU family targets broad compatibility without requiring compute shaders.

**Lesson:** Vellz's CPU-first direction is reasonable. Do not assume the name “Vello” implies one compute-only architecture or universal production maturity. Verify exactly which Vellz implementation is pinned and consumed.

### egui and Slint: ergonomics and tooling are competitive features

Egui emphasizes easy integration, small APIs, custom painting, accessible controls, and on-demand repaint. Its text about typical frame cost is not a controlled comparison to ZUI. Slint emphasizes stable 1.x APIs, live preview, LSP integration, and separate UI design workflows.

**Lesson:** build a tiny external-consumer starter, excellent errors, an inspector, a gallery, and migration guidance. Consider preview/hot reload later; do not begin by inventing a new UI language.

### SDL3: copy the platform contracts, not all of SDL

SDL's high-DPI documentation explicitly separates window size, pixel size/density, and content/display scale. `SDL_SetTextInputArea` documents caret-adjacent native candidate placement.

**Lesson:** DPI and IME are multi-layer protocols, not a float named `scale_factor` and a text-event callback. SDL's contracts are useful even if ZUI keeps native backends.

---

## 8. A credible definition of “better than GPUI”

Choose measurable wins instead of an unqualified superiority claim:

1. **Adoption:** an external user creates a working application from a small documented package recipe, without reading backend source.
2. **Predictability:** explicit allocator/lifetime contracts; no silent missing content; stale handles and duplicate IDs are diagnosed.
3. **International usability:** real CJK IME, grapheme/bidi editing, font fallback, and color emoji work together.
4. **Accessibility:** core workflows pass VoiceOver, NVDA, and Orca testing, not just semantic-tree unit tests.
5. **Performance:** equal-output workloads show lower overhead, good tail latency, and low idle power on specified machines.
6. **Extensibility:** custom widgets and rendering do not require core changes.
7. **Stability:** versioned public API, migration notes, pinned supported Zig versions, and a documented feature/platform matrix.

Potential Zig advantages—comptime validation, explicit allocators, compact representation, straightforward C interop—are opportunities, not automatic speed or safety proofs. Zig has no borrow checker to make the entity and callback lifetime problem disappear.

Start with desktop productivity apps, editors, and data-heavy tools. Web/mobile/embedded can be deliberate later profiles. Trying to win every deployment target immediately would dilute the necessary work.

### Performance acceptance framework

At 60 Hz a frame interval is 16.67 ms; at 120 Hz it is 8.33 ms; at 144 Hz it is 6.94 ms. These are deadlines, not guaranteed framework budgets. Application work and presentation also need time.

For a declared 120 Hz target, a reasonable _initial engineering target_ is ordinary UI CPU work below roughly 4 ms at p95 on a named midrange machine, then validate end-to-end pacing. This is a proposed target, not a GPUI measurement or universal industry standard.

Benchmark paired workloads with the same fonts, data, viewport, scale, visible items, effects, and interaction trace. Record:

- Build revision, optimization, compiler, machine, OS, backend, renderer, adapter and power state.
- Build time: clean and incremental, separately from runtime.
- Startup to first useful frame; cold/warm resource loading.
- View construction, layout/shaping, scene emission, raster/GPU work, upload, present.
- Input-to-frame latency, dropped frames, p50/p95/p99 distributions.
- Idle CPU/wakeups, RSS, per-window memory, allocations, atlas/resource high-water marks.
- Emitted/missing content and output differences.

Do not compare an overflowing or simplified ZUI scene against a complete GPUI scene. Do not include readback in one renderer's timing but exclude its counterpart. The existing dashboard pair is a good starting point after equivalence is established.

---

## 9. Recommended delivery order and exit gates

No speculative dates: the scope and verification gates matter more than an unsupported estimate.

| Stage                                    | Main work                                                                                                                                                                    | Exit gate                                                                                                                                  |
| ---------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------ |
| **0. Truthful baseline**                 | Refresh docs; establish current platform/feature ledger; add native and compile-only cross-target CI; classify scene overflow as failure; external package smoke test; resolve licensing | Clean consumer build and reproducible checks distinguish cached, skipped, compile-only, headless, pixel, and native evidence               |
| **1. Runtime/identity contract**         | Collision-free stable IDs, entity ownership/release, weak callbacks, safe worker completion, custom-element protocol, explicit capacity policies                                | Repeated mount/unmount has bounded memory; stale handles/capture/tasks cannot target removed UI; external custom element works; benchmark emits complete content |
| **2. Layout + text foundation**          | Integrate Zlay; retain text layouts safely; expose shaped hit/caret/selection geometry; color-glyph path                                                                     | Real examples use Zlay; resize/intrinsic/grid fixtures pass; selected scripts render and edit consistently                                 |
| **3. Interaction + semantic foundation** | Correct press/release, focus traversal/scopes, selection/undo, semantic tree and initial AccessKit bridge; begin native IME                                                  | Keyboard-only forms and modal flow pass; screen reader can identify/activate controls; composition protocol is testable                    |
| **4. Window/render/scale boundary**      | Per-window native IDs/surfaces, logical/physical coordinates, scheduler/deadlines, CPU contract                                                                              | Two independently scaled windows work; idle/animation behavior measured; software output remains correct                                   |
| **5. First integrated GPU path**         | Vellz GPU integration where verified, resource retirement, resize/device-loss/fallback                                                                                       | Native GPU renders the same complete scenes as CPU with documented differences and measured benefits                                       |
| **6. Productive widget layer**           | Theme tokens, accessible core controls, overlays, virtual lists/table, async assets                                                                                          | Todo/dashboard use reusable controls; a second realistic consumer needs no private framework patches                                       |
| **7. Competitive release**               | Finish per-OS IME/accessibility validation; inspector/gallery/tutorials; stable release policy; fair GPUI comparison                                                         | Published support matrix, reproducible performance results, and independent external users                                                 |

Accessibility schema design begins with stable identity, not at the end. Similarly, DPI contracts must inform text and renderer design before all platform implementations are complete. Stages describe dependency order, not a requirement to work serially on unrelated tasks.

### Sensible parallel work boundaries

Once canonical identity/event/scene contracts are agreed:

- Runtime owner: entities, task cancellation, invalidation.
- Layout owner: Zlay adapter and fixtures.
- Input/text owner: editing model and composition protocol.
- Renderer owner: scene semantics, CPU/GPU integration and resource retirement.
- Platform owners: implementations behind agreed window/input/scale interfaces.
- Widget/tooling owner: controls, themes, semantic tests, inspector.

Do not assign six agents to invent their own IDs, caches, event types, or render contracts. Require integration tests at every boundary.

---

## 10. Release blockers beyond code features

- **License:** no root license file was present in the inspected root listing. Choose and publish the project's license and preserve dependency/reference notices. Attribution comments alone do not communicate a complete distribution policy.
- **CI:** no root `.github` directory was present. Add an actual supported-toolchain/native-platform matrix and artifact checks; absence here does not rule out private external CI.
- **Toolchain policy:** the working compiler is newer than the documented tested revision. Pin exact tested versions, distinguish minimum from supported, and maintain upgrade notes.
- **Package consumption:** `build.zig.zon` includes source, examples, C code, and build files, but excludes the README, roadmap, and any root license. Test from outside the checkout, including font fixtures, C sources, and optional GPU dependencies. Avoid reliance on ignored references/caches.
- **Public synchronization:** the public GitHub README observed during this review still described the older software renderer and stale limitations, while the local tree uses Vellz and contains fixes not reflected in that page. Keep the repository default branch, published Zlay/Cozmic/Vellz pins, documentation, examples, and claimed test revision synchronized before soliciting users.
- **Security/failure testing:** fuzz malformed images/SVG/fonts where applicable, Unicode edit sequences, layout mutations, stale handles, and event saturation. Review the `-fno-sanitize=all` C codec build flag and provide instrumented testing separately.
- **Native prerequisites:** a text-engine failure currently produces no text (`app.zig:88–99`). Ship actionable diagnostics and a supported font/dependency story rather than an unreadable app.
- **Documentation:** beginner guide, ownership guide, custom-widget tutorial, style/layout semantics, component gallery, platform capabilities, and upgrade instructions.

## Final recommendation

**Do not replace the architecture. Make its contracts complete.**

The immediate leverage is in stable identity/lifetimes, coherent capacity handling, Zlay integration, persistent text reuse, and a real input/semantic model. Then connect the GPU path and build reusable components on those foundations.

ZUI can become substantially more compelling than “GPUI translated to Zig.” To get there, its flagship claim should eventually be backed by this sentence: **ordinary developers can ship a fast, accessible, internationalized application with predictable ownership and no private patches to the UI framework.**

---

## Primary sources consulted

Live sources were consulted on 2026-09-16; upstream documentation claims are not independent runtime verification.

1. GPUI local reference: `.references/gpui/crates/gpui/README.md`, `src/element.rs`, `src/taffy.rs`, `src/_accessibility.rs`, `src/input.rs`, `src/app/context.rs`, and platform manifests. Upstream: https://github.com/zed-industries/zed/tree/main/crates/gpui
2. GPUI Kit architecture, features, usage, and components: https://github.com/longbridge/gpui-kit and https://gpui-kit.com/
3. DVUI features, scheduling, widgets, and stated text/accessibility limitations: https://github.com/david-vanderson/dvui
4. Gooey local reference: `.references/gooey/readme.md`, `src/animation/store.zig`, `src/widgets/data_table.zig`. Upstream: https://github.com/duanebester/gooey
5. AccessKit architecture, platform coverage/limitations, and bindings: https://github.com/AccessKit/accesskit and https://github.com/AccessKit/accesskit-c
6. Vello renderer families and maturity: https://github.com/linebender/vello
7. Xilem/Masonry architecture and stack: https://github.com/linebender/xilem
8. egui integration, usability, repaint policy, and feature goals: https://github.com/emilk/egui
9. Slint stability, live preview, editor integration, and layering: https://github.com/slint-ui/slint
10. SDL3 DPI contract: https://wiki.libsdl.org/SDL3/README-highdpi
11. SDL3 native input area: https://wiki.libsdl.org/SDL3/SDL_SetTextInputArea
12. Capy feature and component matrix: https://github.com/capy-ui/capy
13. zgui Dear ImGui bindings and extensions: https://github.com/zig-gamedev/zgui
14. Mach project status and architecture: https://machengine.org/docs/ and https://github.com/hexops/mach
15. zigui project direction and deferred work: https://github.com/ddalcu/zigui
16. Unicode grapheme segmentation: https://www.unicode.org/reports/tr29/
17. HarfBuzz shaping concepts: https://harfbuzz.github.io/shaping-concepts.html
18. Local reproducibility: `build.zig`, `build.zig.zon`, `tools/references.env`, `tools/bench_text.zig`, `examples/dash-gpui/Cargo.toml`.
