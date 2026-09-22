# ZUI architecture and forward plan

Status: written 2026-09-10 as an architecture review of the then-current tree, and retained as historical intent. Most milestones below have since been implemented; the authoritative current status, evidence, and remaining gaps live in `ZUI_GAP_REPORT.md` (assessment 2026-09-20) and the gate snapshot in `docs/GPUI_PARITY_MATRIX.md`. Treat this document as the original plan, not a live statement of what is or is not done. Existing uncommitted implementation changes are the baseline, not changes proposed by this review.

## Direction

Build a usable retained UI framework with explicit ownership, reliable text/input, and independently verifiable layout and rendering. Prefer correcting boundaries and delivering a complete vertical slice over expanding platform and graphics API surface prematurely.

The previous TODO was a continuation prompt, not an architectural specification. Its completion claims and constraints need evidence. In particular, a large GPU vtable is not a working renderer, a layout port is not proven upstream parity, and native backend source is not cross-platform validation.

## Architecture at a glance

- `app/` retains entity state, schedules windows and dispatches events; `elements/` rebuilds a transient node tree each dirty render.
- `elements/layout.zig` currently lays out that tree independently of the much larger standalone `layout/` port.
- `elements/painter.zig` turns nodes into `gpu/scene.zig` payloads; native `platform/` backends rasterize them with `gpu/software.zig` directly.
- `fonts/` owns discovery, shaping and the glyph atlas; `images/` owns decoder wrappers and a shared decoded-pixel cache.
- `gpu/device.zig` is a broad parallel abstraction not yet driving native presentation. Hardware driver initialization remains unsupported.
- The build already vendors C image decoders; the old all-Zig/system-libraries-only narrative no longer describes the tree.

The core problem is integration and lifetime correctness across these layers. The recommendations below identify the boundary to change and an observable completion condition.

## Corrections established from the runtime paths

### 1. Connect the UI to one layout implementation (high priority)

**Evidence:** `runtime.mountView` calls `elements.layout.layout`; `src/elements/layout.zig` implements its own recursive measure/place algorithm and never calls the standalone engine. Its style is a smaller, independent vocabulary. `src/layout/port.md` explicitly says file coverage is not behavioral completeness. `src/root.zig` exports layout through a relative import while the build also registers a named `layout` module.

**Decision:** keep the source-shaped Taffy port isolated. Replace the element algorithm with an adapter, not a third implementation or a wholesale rewrite of the port. Give the named module one canonical import identity. Keep public builder conveniences, translating their semantics explicitly into layout styles; document where current convenience behavior differs from CSS/Taffy.

**Migration:** first map the current flex/absolute/padding/sizing subset and provide text/image measurement callbacks. Start with a bounded rebuild per dirty window if that is easiest to verify; add persistent node mapping and cache reuse only after stable element identity exists and profiling justifies it. Record unsupported styles explicitly. Preserve reference phase order until the source and fixture parity gates close.

**Done when:** real application trees exercise the standalone module; nested flex shrink/grow, intrinsic sizes, absolute children, and viewport resize have adapter regressions; supported grid behavior is exercised through public elements before advertised. Remove the old measure/place implementation after these checks. Restore a source-pinned differential harness with fixture counts, tolerances, rounding mode, failures and exclusions; do not equate local unit tests with full Taffy parity.

### 2. Make window identity and lifecycle real (high priority)

**Evidence:** `App` owns one `Backend`, initialized with a native window. `openWindow` allocates logical `Window` objects but changes that same backend's title/size/decorations. `handleEvent` broadcasts input and resize to all logical windows; `Event` has no destination window ID. `Window.close` immediately destroys the window through `App.removeWindow`, including when invoked inside an input callback whose caller continues using `self`.

**Decision:** separate application event-pump/connection ownership from native window ownership. Each UI window needs a native window handle, renderer surface, focus state, scale, and destination ID. Until this is implemented, reject a second native window explicitly rather than presenting misleading multi-window support.

**Migration:** defer close/destruction to a safe point after dispatch/render, with closed windows excluded from subsequent work. Introduce window IDs in event envelopes and targeted native operations. Move native create/destroy out of global backend initialization into explicit window lifecycle methods. Share the platform connection and GPU device where appropriate, never the individual surface.

**Done when:** closing from a listener or action cannot leave dispatch using freed memory; two native windows can receive independent titles, sizes, input, focus and presentations; closing one leaves the other alive. Add failure-path cleanup for `App.init`, `initHeadless`, and `initFonts`: currently later allocation failures have no complete unwind of already-created backend/font resources.

### 3. Unify scheduling, mutation, and entity lifetime (high priority)

**Evidence:** `Entity.update/updateWith` set `EntityStore.dirty`, but `App.step` consults window dirty flags instead; updates outside a window context need not schedule a render. `Window.render` clears dirty after callbacks, potentially swallowing a render request made during rendering. Entities are raw pointers in an app-lifetime linked list, with no individual release; listeners/focus handles borrow their headers. Element builders resolve a bare node index through a thread-local active frame.

**Decision:** keep a single UI thread and retained application state with transient element descriptions. This hybrid does not require a virtual DOM. Establish safe ownership and scheduling before attempting granular reactive subscriptions.

**Migration:** initially make entity mutation wake and invalidate all dependent windows conservatively (all windows is acceptable at first); later track mounted dependencies. Clear the current render request before calling user code, retaining new invalidations for the next frame. Define ownership for root/child entities and explicit release; use generation-checked IDs or equivalent checked handles for callbacks that may outlive their targets. Remove unrestricted mutation or require an explicit invalidation guard. Scope thread-local builder convenience to a documented render session, with debug frame/generation checks to reject escaped `Element` values. Keep real frame context explicit in layout and painter APIs.

**Done when:** updating an entity outside an input event visibly redraws, invalidating during render schedules another frame, destroyed entities cannot receive callbacks, repeated mount/unmount does not retain every entity, and stale element/focus handles fail predictably. Use monotonic deadlines for key sequences and animation, replacing step-count timing in `App.step`/`keymap.tick`; idle windows should sleep until input or a deadline.

### 4. Preserve drawing order and clip semantics (high priority)

**Evidence:** `Scene` has separate quad, glyph and image arrays; `software.Target.renderScene` draws all quads, then all glyphs, then all images. This destroys the painter's ordering between primitive types: a later panel cannot reliably cover earlier text or images. The painter clips children to every content box, stores hit regions using unclipped bounds, and removes corner radius when a rectangle is partially clipped.

**Decision:** add an ordered command stream that references typed payload arrays, with explicit clip state. Batch only adjacent compatible draws, or reorder only where non-overlap makes it demonstrably safe. Keep original geometry separate from clip geometry. Define overflow-visible/clip/scroll and stacking semantics instead of making clipping an implicit property of every container. Define group opacity separately from per-primitive alpha and specify approximations such as the current glow-based `blur`.

**Done when:** software pixel regressions cover alternating text/image/quad siblings, an opaque overlay over all primitive types, partial rounded clips, and nested opacity. Hit testing obeys the same effective clips and reverse paint order. The same scene semantics become the GPU acceptance oracle.

### 5. Own resource lifetime through frame completion (high priority)

**Evidence:** `fonts.Atlas.put` clears the entire atlas on exhaustion, while already-emitted glyphs retain offsets into its pixel pool. Render-then-present adjacency cannot protect against eviction within that same render. `images.Handle` is a raw offset/size; the painter's `.handle` path bypasses lookup/pinning, and later cache reset can reuse the offset. The image entry table has no ordinary slot eviction; exhausting slots can fail even when old entries are unused. GPU submission will eventually outlive the synchronous CPU present call.

**Decision:** distinguish persistent asset identity from frame-local resolved storage. Use generation-checked asset handles, explicit resolution/pinning, and a frame resource set. Never overwrite data referenced by an unfinished frame. Start with frame-safe pages or no-eviction-until-frame-end and a visible capacity error; add GPU retirement fences when asynchronous submission lands.

**Done when:** a single frame exceeding atlas capacity cannot corrupt earlier glyphs; retained image handles survive eviction through re-resolution or report stale status; full caches reclaim eligible slots; multiple in-flight frames retain their resources until completion. Exercise exhaustion with small test budgets instead of relying on huge defaults.

### 6. Move asset loading out of element building and painting (medium/high priority)

**Evidence:** `element.probeSource` reads path sources to obtain dimensions, while `painter.readPathBytes` reads them again to resolve pixels. Content hashing/cache lookup happens after the read; frame construction therefore still performs file I/O, and cache misses decode/allocate inside painting. `readPath` contains POSIX calls in the element layer.

**Decision:** introduce an app-owned asset service with loading/ready/failed states, intrinsic dimensions, decoded resources, and stable handles. Paths and embedded bytes are input to that service; layout and paint consume ready metadata/resources. Keep a convenient synchronous preload path for examples, then add background loading with UI-thread completion and invalidation. Route file access through a portable service outside elements.

**Done when:** repeated rendering of a ready path image does not reread, rehash, or decode it; missing files and decode failures have explicit placeholders/errors; completion requests layout when intrinsic size changes. Bound source bytes, decoded dimensions, and cache budgets before allocation. Handle file changes through an explicit reload policy.

### 7. Shrink the renderer contract to demonstrated needs (medium priority; after scene/lifetime fixes)

**Evidence:** native backends call the CPU rasterizer directly. `gpu/device.zig` exposes a broad SDL-shaped resource/pass API, while Vulkan/Metal/D3D12 initialization still returns `error.Unsupported`. `Device.drawScene` takes glyph pixels but no image pool; `software_device` documents that gap. Null validation and loader probes are not functional driver support.

**Decision:** preserve `platform/` for native windowing and `gpu/` for rendering; a folder reshuffle is not the correction. Put renderer selection and per-window surface attachment in app orchestration. Platform provides native surface descriptors and, for software, pixel-buffer presentation; it should not interpret `Scene`. Renderer consumes ordered scenes plus a complete resource set. Isolate the broad low-level GPU API as experimental/internal until a real implementation needs it; do not grow three driver skeletons in parallel.

**Migration:** route software through the same small frame/surface contract first, including images. Then implement one Vulkan vertical slice: device/surface creation, resize and zero-sized surfaces, acquire, upload, ordered quads/glyphs/images, submit/present, synchronization and teardown. Report capability and initialization failures explicitly; keep null an intentional headless mode rather than silent evidence of successful native startup. Add Metal/D3D12 after the contract survives an actual GPU backend.

**Done when:** software and GPU consume the same scenes with matching overlap, alpha and clip behavior; resize/minimize/reopen and resource retirement work; loader presence is distinguished from successful device/surface support. Only measured bottlenecks justify wider pass/compute APIs or sophisticated batching.

### 8. Build text layout and input around shaped runs (medium/high priority)

**Evidence:** measurement shapes text independently from paint; measurement accepts tracking, while `paintShaped` advances by glyph advances without applying tracking. Symbol fallback substitutes glyphs/advances only in paint, so measured and painted widths can diverge. `TextField` appends/removes at the end only, clips pasted bytes to available capacity without UTF-8 boundary validation, and has no selection/composition model. `TextEvent` is a fixed 32-byte commit payload with no IME composition event. `text/` remains largely a bindings export while `fonts/` owns the actual stack.

**Decision:** define a reusable text-layout result with font fallback runs, clusters, advances, line breaks, baselines and caret mapping. Measurement, paint, selection and hit testing consume it. Keep low-level font discovery/rasterization in fonts; use text for layout/editing semantics and consolidate duplicated binding ownership without losing attribution. Establish native font discovery adapters or an explicit supported dependency story for Windows/macOS.

**Migration:** first fix tracking/fallback agreement and safe UTF-8 insertion. Then add caret movement, selection, grapheme-aware deletion, clipboard selection semantics, undo/redo, wrapping, and horizontal scrolling. Extend normalized events with composition/preedit, commit and cancellation, with native adapters and caret-rectangle reporting.

**Done when:** nonzero tracking, fallback symbols, ligatures, combining marks, RTL text and long input have matching layout/paint/caret behavior; capacity clipping never stores malformed UTF-8; IME text is committed once. Use deterministic bundled test fonts with licenses, and make unavailable native prerequisites explicit skips.

### 9. Define interaction and accessibility as framework services (medium priority)

**Evidence:** `Window.handleEvent` fires click listeners on press, with no release-target/capture model; scroll dispatch goes to focus rather than a scroll target under the pointer. `updateHitRegions` leaves the focused handle unchanged if its region disappears. Double-click timestamp initialization is conditional on a previous nonzero timestamp, preventing an initially zero click history from being seeded through this path.

**Decision:** centralize hover, cursor, focus traversal, pointer capture and event propagation. Separate down/up/click, cancel capture on destruction or focus loss, and route scrolling through hit-tested scroll containers. Clear or deliberately restore focus when an element disappears. Add a semantic accessibility tree keyed by stable element IDs, independent of draw commands, before expanding the widget catalog.

**Done when:** press-inside/release-outside cancels a button, drag remains captured, clipped items cannot be clicked, tab/shift-tab works, double-click history initializes, and removed focused controls stop receiving text. Introduce roles, names, states and actions with headless semantic tests, then validate native accessibility bridges on each OS. Build buttons, checkbox, scroll view and virtual list on these services rather than embedding behavior into demos.

### 10. Replace blanket fixed-cap rules with observable budgets (cross-cutting)

**Evidence:** frame nodes/text panic on exhaustion; hit regions/actions can silently drop; scene pushes return failure that painter callers ignore. `core/limits.zig` includes inherited limits and comments for systems absent from this tree. Images allocate on misses; the Taffy tree owns allocator-backed storage. Neither large arrays nor reusable HarfBuzz buffers alone prove an allocation-free frame.

**Decision:** retain bounded, reusable hot storage where it helps, but specify budgets per owning subsystem and expose high-water/overflow counters. Choose an explicit policy per failure: reject the frame, render a diagnostic/placeholder, or grow at a safe preparation point. Input overflow must not silently lose button releases or close events; coalesce motion/resize and preserve critical transitions. Reserve/reuse scratch storage based on measured working sets. Keep large buffers off small stacks.

**Done when:** tests force every important capacity path and no invisible interactive controls result from silently missing hit regions. Publish baseline resident/per-window memory, allocation counts, layout/paint/present duration and p50/p95/p99 frame times for representative scenes. Include foreign-library work when claiming no allocations. Optimize only after comparable release measurements, with cold loads separated from warm rendering.

## Portability, build, and maintenance work

- **DPI contract:** separate logical layout coordinates from physical framebuffer pixels; apply per-window scale at rasterization, surface sizing and input normalization, with explicit rounding. Native backends expose scale factors, but a reported factor alone does not establish a complete conversion path. Test 1x, fractional and 2x scaling, including moving between monitors, font rerasterization and pointer alignment.
- **Platform capabilities:** publish a matrix for build/launch, window lifecycle, clipboard, IME, DPI, accessibility and renderer availability. Source presence, header checks, native compile, and native runtime tests are separate evidence levels. Add Linux Wayland/X11 runtime scenarios first; use actual Windows/macOS runners for their respective backends before claiming support. Native ABI/protocol correctness was not exhaustively audited here.
- **Build coverage:** `zig build test` covers root and standalone-layout test artifacts, not a native cross-platform matrix or the todo example's embedded Zig tests. Add explicit example compile/test and headless integration steps. Separate deterministic tests from environment-dependent font/backend tests; a missing dependency should report a skip rather than a successful early return.
- **Package health:** remove or restore the missing `BENCHMARKS.md` entry in `build.zig.zon`; test a packaged dependency from outside this checkout. Keep `.references` and build caches out of distributions. Pin the development Zig version deliberately and document upgrades; the installed compiler and manifest minimum currently differ.
- **Documentation:** create a short root README with working build/run/test commands, actual architecture, supported features and current limitations. Replace stale claims in `examples/todo/README.md` (it says the app does not compile and `src/` is empty), `src/root.zig`, `src/text/root.zig`, and inherited limit comments. Keep this plan as the roadmap and `src/layout/port.md` as the detailed port ledger; avoid another paste-to-agent instruction document.
- **Dependency policy:** record the actual accepted boundary: primarily Zig, native system APIs, and currently vendored C image codecs. Decide dependency additions on portability, maintenance and measured benefit; do not rewrite working codecs simply to satisfy an obsolete purity rule. Preserve upstream attribution and add a dependency/license inventory with pinned revisions. Review `-fno-sanitize=all` on the C image build and provide an instrumented decoder test/fuzz configuration where supported.
- **Application/library separation:** move todo-specific progress styling, palette choices and date helpers out of foundational elements as the widget layer matures. Keep examples as consumers of supported APIs; use theme/style tokens for reusable widgets rather than embedding one demo's appearance into their behavior.

## Target ownership and data flow

```text
App / UI scheduler
  owns entity store, asset service, platform connection, renderer device
  owns windows
    each owns native window + renderer surface + frame scratch
    each owns focus/capture/scroll state + mounted view dependencies

Native events + async asset completions
  -> targeted UI updates -> invalidation/deadlines
  -> view builds transient elements
  -> layout adapter -> standalone layout + shared text layout
  -> ordered scene + effective clips + hit/semantic trees
  -> renderer with pinned frame resources -> surface presentation
  -> completion retires resources and deferred destruction
```

This is a boundary overhaul with incremental migration, not a recommendation to discard the repository. Preserve the useful pieces: native backend implementations, pure geometry/color, the standalone layout port, software rasterizer, font shaping/rasterization, image decoders, value builders and headless event-driven example. Introduce adapters while migrating callers, then remove superseded paths; do not leave two permanent layout or presentation implementations.

## Delivery order

Each milestone should leave the existing app runnable. The acceptance conditions in the correction sections are part of the milestone, not optional cleanup. The order below allows tests and safety fixes before larger migrations; it replaces the old strict feature checklist.

| Milestone | Work | Exit gate |
|---|---|---|
| M0: reproducible baseline | Record toolchain/dependencies; wire example tests, headless integration and package smoke checks; correct stale docs; add small regressions for the identified failures. | One documented command set distinguishes unit, integration, fixture and native checks; package builds outside the checkout. |
| M1: safe runtime | Deferred close, initialization unwind, mutation-to-window invalidation, render-time invalidation preservation, stale focus/callback protection; temporarily enforce one native window if needed. | Close from callbacks and update outside callbacks are safe and observable; repeated lifecycles release owned state. |
| M2: correct scene/resources | Ordered commands, shared clip/hit rules, frame-safe atlas storage, resolvable image handles, overflow reporting. | Overlap/clip pixel tests and forced cache exhaustion pass without corruption or invisible interactive elements. |
| M3: integrated layout/text/assets | Replace element measure/place with the standalone adapter; share measured/painted runs; preload assets outside frame work; restore layout differential testing. | Existing todo layout passes through the adapter, text metrics agree with paint, ready images incur no frame I/O, and fixture coverage is explicit. Full port parity remains a separate tracked gate. |
| M4: useful interaction | Caret/selection/UTF-8, pointer capture/click semantics, focus traversal, scroll containers, semantic tree; begin IME bridge. | Keyboard-only and pointer-driven editing/scroll scenarios pass; text composition has an explicit event model. |
| M5: native window/render boundary | Per-window native handles/events/surfaces, complete software renderer contract, DPI normalization, actionable fallback errors. | Two windows stay independent and software still draws all primitives through the common renderer route. |
| M6: first actual GPU path | Vulkan vertical slice with resource retirement and resize handling; compare against software. | Correct quad/text/image composition, stable native lifecycle and measured release results. No generic GPU API expansion required to declare success. |
| M7: broader usability/support | Finish IME/accessibility bridges, native Windows/macOS validation, themes/basic widgets, virtual lists, then additional GPU drivers. | Each advertised feature has a real consumer and a platform-specific validation record. |

The first implementation batch should be M0 plus deferred destruction and invalidation from M1. It is small enough to review and addresses runtime hazards without waiting for GPU work. The first rendering batch should be the ordered scene and atlas safety in M2, because carrying those bugs into a new driver would make comparison misleading.

## Further work after the foundations

- Build a second small consumer (for example a resizable image browser with editable search and a virtualized list) to expose API assumptions hidden by the todo. Keep it a test vehicle, not a large showcase project.
- Add a layout/hit/clip inspector and frame counters so applications can diagnose geometry, resource pressure and scheduling without reading backend code.
- Add deterministic pixel fixtures with known fonts/assets and a controllable clock; cover resize, overlap, text fallback, scroll, asset failure and focus changes.
- Benchmark cold startup, idle CPU, input-to-frame latency, warm text-heavy scenes, large lists, mixed flex/grid, image loading and multi-window rendering. Record workload, build mode, hardware, allocation/memory budget and timings; separate layout computation from construction and presentation.
- Introduce layout/paint caching, dirty-subtree rendering, atlas indexing, GPU batching and damage tracking only where measurements show value. Virtualization should bound large-list work before globally raising capacities.
- Add fuzz/property checks at true boundaries: malformed image data, Unicode editing, layout mutation sequences, event queue saturation and stale resource handles. Avoid tests that merely reproduce declarations or validate stubs against themselves.

## Explicitly deferred or rejected inherited directions

- Do not copy a full general-purpose GPU API merely because SDL has it. Keep reference work only where it supports a tested implementation.
- Do not pursue Vulkan, Metal and D3D12 completion simultaneously before proving the small renderer boundary.
- Do not mark flex/grid “done” because files exist or local tests pass while the application bypasses that engine.
- Do not require zero allocations everywhere, force every capacity into one global file, or silently drop work to maintain that claim. Define and measure warm-path budgets and preserve correctness on exhaustion.
- Do not treat every new file as needing its own mirrored unit test; test behavior at the layer that owns it, with integration coverage for crossings.
- Do not introduce a reactive graph, virtual DOM, ECS, plugin system, render thread or total directory rewrite without a demonstrated requirement. Stable identity and ownership are required; those specific architectures are not.

## Review evidence and limits (2026-09-10)

This was a targeted architecture exploration of the current, substantially modified working tree. Findings above are derived from traced call paths; the proposed defect regressions have not been implemented or individually executed in this documentation task. No implementation files were changed.

- Read the old `TODO.md` as historical intent and compared its claims with build configuration, app/runtime/window, element layout/painter/builders, scene/software/device drivers, text/fonts/atlas, image cache, platform contracts/backend presentation paths, widget input, examples, and the layout port ledger/tree.
- `zig version`: `0.17.0-dev.2085+5e36170b5`; manifest minimum: `0.17.0-dev.1970+67f39b551`.
- `zig build test --summary all`: successful, **5/5 build steps**, both test executions reported **cached**. This is a successful cached build result, not a fresh test-count report.
- `ZUI_BACKEND=null ZUI_TODO_DEMO=1 ZUI_SELFTEST=1 zig build run-todo --summary all`: actual headless execution passed **9/9 checks**, **3/3 build steps**; executable compilation was cached.
- Not performed: GUI screenshots/live native interaction, cross-OS compilation/runtime tests, fresh Taffy fixture conformance, GPU execution, package smoke test, performance/allocation profiling, or exhaustive ABI/security review. Those remain explicit work above, not implied successes.
- The root `TODO.md` is removed in favor of this plan. The todo example and its README remain; its stale README is maintenance work, not a reason to remove the example.

## Second-pass review (completed)

The second pass reviewed runtime/core, native platform backends,
rendering/assets/text, and standalone layout/build coverage. Its findings were
folded into `ZUI_GAP_REPORT.md`; the layout-defect regressions it called for
(tree mutation/reparent staleness and the three Taffy grid disagreements)
have since been reproduced and fixed, and Zlay is now the default layout path
with `ZUI_LAYOUT=legacy` as the escape hatch. The section that follows is the
original second-pass checkpoint, kept for provenance.

### Second-pass checkpoint: layout integration now has a prerequisite

A fresh test run passed 308/308 executions (228 in the ZUI artifact plus 80 in the standalone layout artifact; layout tests are also imported by ZUI). Small out-of-tree probes nevertheless reproduced stale layout after reparenting and partial tree mutation on a rejected child ID.

A freshly built offline oracle against vendored Taffy 0.14 also disagrees with the Zig port on three small grids:

| Case | Zig port | Vendored Rust Taffy |
|---|---:|---:|
| Second column position, tracks 40px + 20px with a 10px gap | x=40 | x=50 |
| Child width in a 100px border-box grid with 10px horizontal padding and one 1fr track | 100 | 80 |
| Child with min-width 60px in a fixed 40px track | 40 | 60 |

Therefore M3 must start with tree mutation/cache invariants and these layout correctness regressions before making the port the application default. Keeping the existing application path temporarily is justified during that migration; exposing all port styles immediately is not.
