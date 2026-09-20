# GPUI parity matrix

This is the completion ledger for the full-parity goal. A row is complete only
when the ZUI API and behavior are implemented, source-backed tests exist, and
the advertised platform/backend validation has run. “Implemented” without
“verified” is not completion.

| GPUI source family | Current ZUI status | Completion evidence |
| --- | --- | --- |
| `app.rs`, `global.rs`, `subscription.rs`, context APIs | Implemented slice | typed globals/updateGlobal, entity reservations, subscriptions, scoped invalidation, typed/erased views, and deterministic TestAppContext; window-context and Future executor breadth remain open |
| `element.rs`, `elements/mod.rs` | Partial | public typed custom-element composition and lifecycle contract |
| `elements/anchored.rs`, `container_query.rs`, `deferred.rs`, `surface.rs` | Implemented slice | public ZUI counterparts are exported from `src/elements/root.zig`; focused geometry/order/clipping contracts exist, but typed GPUI composition and full lifecycle parity remain open |
| `elements/image_cache.rs`, `img.rs`, `list.rs`, `uniform_list.rs` | Implemented slice | borrowed image-cache scope now controls descendant intrinsic sizing and paint resources, with retained image/uniform-list and virtual list/table contracts; GPUI list differential adapter and insertion anchoring remain open |
| `style.rs`, `taffy.rs` | Partial | complete supported style vocabulary and resize/fractional geometry oracle; common record envelope covers selected fixtures |
| `interactive.rs`, `input.rs`, `gestures.rs`, `tab_stop.rs` | Partial | keyboard/touch/pen/gesture/drag phases and tab traversal trace tests; shared input trace adapter still open |
| `text_system/*`, `elements/text.rs` | Partial | font features/fallback, grapheme ranges, shaped character positions/widths, bounded line clamping, ellipsis, and large-document tests now publish through AccessKit; native IME and platform speech/range workflows remain open |
| `elements/animation.rs`, `spring.rs` | Verified slice | `AnimationTrack` now covers one-shot/repeat/synced phase, easing, and max-FPS policy; `bash tools/run-differential.sh` matched 18 records including the pinned spring comparison; element scheduling helpers remain separate |
| `scene.rs`, `path_builder.rs`, `elements/canvas.rs` | Implemented slice | bounded paths, transforms, strokes, shadows, clipping, damage/recovery, and scene-digest contracts exist; pixel/GPU equivalence remains open |
| `assets.rs`, `asset_cache.rs` | Implemented slice | generic asset source/cache contract, cancellation, deduplication, reload, retention, and bounded eviction tests exist; broader async composition remains open |
| `action.rs`, `queue.rs`, `refineable`, `shared_uri.rs`, `executor.rs` | Implemented slice | explicit typed action dispatch, bounded priority sender/receiver, refinement cascade, owned URI components, and thread-compatible blocking helper; macro/async-Future layers remain out of scope |
| `gpui_util::arc_cow`, `http_client` | Implemented slice | `src/core/arc_cow.zig` provides borrowed/owned sharing with detach-on-write; `src/http_client.zig` provides validated requests, responses, cancellation tokens, null transport, and a deterministic test provider; no network I/O is performed by tests |
| `platform.rs` and platform service modules | Implemented slice | `src/platform/services.zig` provides portable service contracts; `src/platform/native_window_services.zig` adds generation-checked per-window handles, multi-window registry, clipboard/IME/cursor/DPI/lifecycle state; Windows/Cocoa bindings expose the relevant activation, text-input, cursor, and scale-notification symbols. Native callback routing and live OS behavior remain open. |
| `scene.rs` GPU/headless boundary | Implemented slice | App/Window WGPU handoff, persistent resource retirement, injected device-loss fallback, and 4096-pixel CPU/WGPU offscreen differential covering alpha, gradient, rounded quad, path, and nearest-sampled image; full scene vocabulary and live loss injection remain open |
| `test.rs`, visual-test platform, profiler | Partial | reusable offscreen `TestContext`/`VisualTestContext`, golden scene digests, input replay, profiler and inspector snapshots; native screenshot/GPU claims remain out of scope |
| mobile lifecycle/insets | Implemented contract boundary | `src/platform/mobile.zig` has GPUI-shaped phase/inset/appearance types, null-backend callback tests, and explicit Android/iOS `error.Unsupported` adapter boundaries; native adapters and live lifecycle validation remain open |
| component ecosystem | Implemented slice | behavior and render contracts exist for editor, text area, tabs, tree, split pane, command palette, docking, and existing controls; richer editor/docking behavior and native proof remain open |

## Status vocabulary

- **Missing**: no public equivalent or no meaningful implementation.
- **Partial**: a bounded implementation exists, but at least one required API,
  behavior, platform, or oracle gate remains open.
- **Implemented slice**: the requested behavior exists and has focused tests,
  but the row still needs the stated differential or platform evidence.
- **Complete**: all row evidence is present and the row is rechecked after the
  final integration build.

The matrix deliberately records the checked-in GPUI source surface rather than
claiming that a passing ZUI unit suite proves framework parity.

## Current gate snapshot (2026-09-20)

These are the gates actually run during this reconciliation. The aggregate
`test` results are cached build artifacts; Zig's build summary reports build
steps, not a repository-wide test-case total, so no synthetic aggregate test
count is claimed here.

| Gate | Current result | Status interpretation |
| --- | --- | --- |
| `python3 tools/check-gpui-parity-matrix.py` | **PASS: 7 modules, 45 re-exports, 47 source families, 2 executable gates** | Source inventory is synchronized with the pinned GPUI file. |
| `zig build test --summary all` | **24/24 steps succeeded; 447/451 tests passed (4 skipped)** | Aggregate headless run is green; skipped cases are the existing host/platform/font boundaries. |
| `zig build test -Daccesskit=true --summary all` | **25/25 steps succeeded; 451/451 tests passed** | AccessKit-enabled aggregate path is green; no native screen-reader speech behavior is implied. |
| `zig build test-text --summary all` | **54/54 tests passed** | Focused text features, fallback, ranges, geometry, and bounded document tests pass. Native IME remains separate. |
| `zig build test-zlay --summary all` | **42/42 tests passed** | Focused layout adapter/oracle fixtures pass. |
| `bash tools/run-differential.sh` | **PASS: 18 matched records** | Contract/differential records only; not full family parity. |
| `bash tools/run-zlay-parity.sh` | **PASS** | External Taffy fixture matched; this is separate from the blocked focused ZUI test root. |
| `zig build check -Dtarget=x86_64-windows-gnu --summary all` | **15/15 succeeded** | Compile-only evidence. |
| `zig build check -Dtarget=aarch64-macos-none --summary all` | **15/15 succeeded** | Compile-only evidence. |
| `zig build debug-test --summary all` | **3/3 succeeded** | Headless trace/profiler/snapshot contract gate. |
| `zig build test-context --summary all` | **30/30 passed** | Reusable deterministic TestContext, visual golden, replay, profiler, and inspector contract gate. |
| `zig build gpu-wayland-test -Dgpu=true -Dwgpu-native-prefix=.ports/wgpu/.reference/artifacts/prebuilt --summary all` | **5/5 bridge tests passed** | Optional WGPU bridge evidence on this host. |
| `zig build gpu-offscreen-diff -Dgpu=true -Dwgpu-native-prefix=.ports/wgpu/.reference/artifacts/prebuilt --summary all` | **4096 pixels, max delta 2, zero mismatches**; current host sample CPU 5.29ms, bridge 3.52ms, render submission 5.69ms, readback 0.47ms | Real CPU/WGPU offscreen pixel differential and CPU-side GPU-path timing baseline covering alpha, gradient, rounded quad, path, and nearest-sampled image. |
| `zig build gpu-wayland-smoke -Dgpu=true -Dwgpu-native-prefix=.ports/wgpu/.reference/artifacts/prebuilt --summary all` | **3 diagnostic frames presented** | Native Wayland smoke only; not default App GPU parity. |
| `zig test tools/native_linux_fixture.zig` | **3/3 passed** | Native protocol ordering fixture only. |
| `python3 tools/atspi_tree_probe.py todo` | **PASS: 12 nodes; native click action returned success** | Live Wayland AT-SPI semantic publication/action evidence; not speech-reader certification. |
| `python3 -m unittest discover -s tools/differential -p 'test_*.py'` | **3/3 passed** | Differential protocol tests only. |

## Source-ledger inventory and exit gates

Source of truth for this inventory: `.references/gpui/crates/gpui/src/gpui.rs`
at the checked-in reference revision.

The following inventory is deliberately statement-level. Wildcard exports are
not treated as equivalent merely because ZUI has a similarly named module: the
corresponding ZUI export and its status are recorded in the table below. The
HTML markers are consumed by `tools/check-gpui-parity-matrix.py`; keep them in
sync with the pinned GPUI source.

### Public GPUI modules

<!-- gpui-module: colors -->
<!-- gpui-module: prelude -->
<!-- gpui-module: profiler -->
<!-- gpui-module: queue -->
<!-- gpui-module: test -->
<!-- gpui-module: _accessibility -->
<!-- gpui-module: _ownership_and_data_flow -->

### Public GPUI re-export statements

<!-- gpui-reexport: pub use proptest; -->
<!-- gpui-reexport: pub use accesskit; -->
<!-- gpui-reexport: pub use accesskit::Action as AccessibleAction; -->
<!-- gpui-reexport: pub use accesskit::{Orientation, Role, Toggled}; -->
<!-- gpui-reexport: pub use action::*; -->
<!-- gpui-reexport: pub use anyhow::Result; -->
<!-- gpui-reexport: pub use app::*; -->
<!-- gpui-reexport: pub use asset_cache::*; -->
<!-- gpui-reexport: pub use assets::*; -->
<!-- gpui-reexport: pub use color::*; -->
<!-- gpui-reexport: pub use ctor::ctor; -->
<!-- gpui-reexport: pub use debug_overlay::*; -->
<!-- gpui-reexport: pub use element::*; -->
<!-- gpui-reexport: pub use elements::*; -->
<!-- gpui-reexport: pub use executor::*; -->
<!-- gpui-reexport: pub use geometry::*; -->
<!-- gpui-reexport: pub use gestures::*; -->
<!-- gpui-reexport: pub use global::*; -->
<!-- gpui-reexport: pub use gpui_macros::{ AppContext, IntoElement, Render, VisualContext, bench, property_test, register_action, test, }; -->
<!-- gpui-reexport: pub use spring::*; -->
<!-- gpui-reexport: pub use gpui_shared_string::*; -->
<!-- gpui-reexport: pub use gpui_util::arc_cow::ArcCow; -->
<!-- gpui-reexport: pub use http_client; -->
<!-- gpui-reexport: pub use input::*; -->
<!-- gpui-reexport: pub use inspector::*; -->
<!-- gpui-reexport: pub use interactive::*; -->
<!-- gpui-reexport: pub use keymap::*; -->
<!-- gpui-reexport: pub use path_builder::*; -->
<!-- gpui-reexport: pub use platform::*; -->
<!-- gpui-reexport: pub use profiler::*; -->
<!-- gpui-reexport: pub use queue::{PriorityQueueReceiver, PriorityQueueSender}; -->
<!-- gpui-reexport: pub use refineable::*; -->
<!-- gpui-reexport: pub use scene::*; -->
<!-- gpui-reexport: pub use shared_uri::*; -->
<!-- gpui-reexport: pub use style::*; -->
<!-- gpui-reexport: pub use styled::*; -->
<!-- gpui-reexport: pub use subscription::*; -->
<!-- gpui-reexport: pub use svg_renderer::*; -->
<!-- gpui-reexport: pub use taffy::{AvailableSpace, LayoutId}; -->
<!-- gpui-reexport: pub use test::*; -->
<!-- gpui-reexport: pub use text_system::*; -->
<!-- gpui-reexport: pub use util::{FutureExt, Timeout}; -->
<!-- gpui-reexport: pub use view::*; -->
<!-- gpui-reexport: pub use window::*; -->
<!-- gpui-reexport: pub use pollster::block_on; -->

### Re-export comparison

| Exact GPUI source statement | Current ZUI public counterpart | Status / exit gate |
| --- | --- | --- |
| `accesskit`, `AccessibleAction`, `Orientation`, `Role`, `Toggled` | `zui.a11y` tree and action types; no root-level AccessKit aliases | Partial; live Wayland AT-SPI tree publication is observed, but screen-reader speech and UIA/NSAccessibility remain open |
| `action::*`, `app::*`, `global::*`, `subscription::*` | `zui.app` entities, globals, subscriptions, invalidation | Partial; `app-runtime` gate |
| `asset_cache::*`, `assets::*` | `zui.images.GenericAssetCache`, image service/cache | Partial; `asset-cache` gate |
| `color::*`, `geometry::*`, `colors`, `prelude`, `gpui_shared_string::*` | `zui.Color`, geometry types, `zui.colors`, `zui.prelude`, `zui.SharedString` | Implemented public vocabulary slice; appearance-aware global color state and macro-generated prelude behavior remain different |
| `element::*`, `elements::*`, `styled::*`, `view::*` | `zui.elements` and retained `Element`/widget constructors | Partial; typed composition/lifecycle gate |
| `executor::*`, `util::{FutureExt, Timeout}` | `zui.app.tasks.TaskRuntime` and timers | Partial; API names and scheduling semantics differ |
| `gpui_util::arc_cow::ArcCow`, `http_client` | `zui.core.ArcCow`, `zui.http_client` plus root aliases | Implemented slice; focused deterministic tests cover borrowed/owned COW, request validation, response status, provider recording, and cancellation; async runtime adapters and real transports remain outside this contract |
| `gestures::*`, `input::*`, `interactive::*`, `keymap::*` | `zui.platform.event`, keymap, capture/bubble input | Partial; touch/pen/gesture/drag gate |
| `global::*`, `inspector::*`, `profiler::*` | `zui.app` globals and `zui.debug` diagnostics | Partial; inspector/profiler contract gate |
| `path_builder::*`, `scene::*`, `svg_renderer::*` | `zui.gpu.Scene`, paths, strokes, SVG image pipeline | Partial; joins/caps/layers and differential rendering gate |
| `platform::*`, `http_client` | `zui.platform` and platform service contracts | Partial; native adapter gate |
| `queue::{PriorityQueueReceiver, PriorityQueueSender}` | `zui.PriorityQueueReceiver(T)`, `zui.PriorityQueueSender(T)` | Implemented slice; bounded queue tests pass |
| `refineable::*`, `style::*`, `taffy::{AvailableSpace, LayoutId}` | `zui.Refinement(T)`, `zui.Cascade(T)`, `zlay` layout module | Implemented slice for explicit refinement values; full style vocabulary gate remains |
| `spring::*` | `zui.animation.Spring` | Implemented slice; `animation` gate |
| `ctor::ctor`, `gpui_macros::{...}` | no equivalent procedural-macro surface | Missing; macro compatibility is out of the Zig ABI scope |
| `proptest`, `test::*`, `pollster::block_on` | headless tests and debug probes | Partial; visual/test-context gate |
| `shared_uri::*`, `svg_renderer::*`, `text_system::*` | `zui.SharedUri`, shared-string/image/text-engine modules | Implemented slice for owned URI parsing; font-feature, fallback, and IME gates remain |

The grouped comparison table is explanatory; the marker inventory above is the
authoritative completeness check. GPUI's nested `private` module is excluded
because it is explicitly documentation/implementation support rather than the
public re-export surface.

The following one-to-one maps make the comparison explicit for every source
statement, including exports for which ZUI intentionally has no counterpart:

<!-- gpui-export-map: pub use proptest; => zui test-only suite; partial -->
<!-- gpui-export-map: pub use accesskit; => zui.a11y.accesskit; partial -->
<!-- gpui-export-map: pub use accesskit::Action as AccessibleAction; => zui.a11y.Action; partial -->
<!-- gpui-export-map: pub use accesskit::{Orientation, Role, Toggled}; => zui.a11y.Role and state/action types; partial -->
<!-- gpui-export-map: pub use action::*; => zui.Action, zui.ActionDispatch, zui.makeAction; implemented slice; macro registration out of scope -->
<!-- gpui-export-map: pub use anyhow::Result; => Zig error unions; no alias; partial -->
<!-- gpui-export-map: pub use app::*; => zui.app.App, Context, Entity, Window; partial -->
<!-- gpui-export-map: pub use asset_cache::*; => zui.images.GenericAssetCache; partial -->
<!-- gpui-export-map: pub use assets::*; => zui.images service/cache; partial -->
<!-- gpui-export-map: pub use color::*; => zui.Color and core.color; partial -->
<!-- gpui-export-map: pub use ctor::ctor; => no Zig constructor macro; missing -->
<!-- gpui-export-map: pub use debug_overlay::*; => zui.debug.inspector; partial -->
<!-- gpui-export-map: pub use element::*; => zui.elements.Element and lifecycle types; partial -->
<!-- gpui-export-map: pub use elements::*; => zui.elements constructors and anchored/container/deferred/surface/image-cache/uniform-list families; implemented slice; typed composition remains partial -->
<!-- gpui-export-map: pub use executor::*; => zui.app.tasks.TaskRuntime and zui.blockOn; implemented slice; Future executor out of scope -->
<!-- gpui-export-map: pub use geometry::*; => zui.Point, Size, Rect, Bounds; partial -->
<!-- gpui-export-map: pub use gestures::*; => zui.platform.event gesture recognizers; implemented slice; native delivery remains unverified -->
<!-- gpui-export-map: pub use global::*; => zui.app globals and reservations; partial -->
<!-- gpui-export-map: pub use gpui_macros::{ AppContext, IntoElement, Render, VisualContext, bench, property_test, register_action, test, }; => no procedural-macro ABI; missing -->
<!-- gpui-export-map: pub use spring::*; => zui.animation.Spring and SpringConfig; implemented slice -->
<!-- gpui-export-map: pub use gpui_shared_string::*; => zui.SharedString; partial -->
<!-- gpui-export-map: pub use gpui_util::arc_cow::ArcCow; => zui.core.ArcCow; implemented detach-on-write slice -->
<!-- gpui-export-map: pub use http_client; => zui.http_client; implemented transport-neutral request/response/cancellation slice -->
<!-- gpui-export-map: pub use input::*; => zui.platform.event input types; partial -->
<!-- gpui-export-map: pub use inspector::*; => zui.debug.inspector; partial -->
<!-- gpui-export-map: pub use interactive::*; => zui.elements interaction listeners; partial -->
<!-- gpui-export-map: pub use keymap::*; => zui.app.Keymap and Keystroke; partial -->
<!-- gpui-export-map: pub use path_builder::*; => zui.gpu.Path and path commands; partial -->
<!-- gpui-export-map: pub use platform::*; => zui.platform backend/services; partial -->
<!-- gpui-export-map: pub use profiler::*; => zui.debug.profiler; partial -->
<!-- gpui-export-map: pub use queue::{PriorityQueueReceiver, PriorityQueueSender}; => zui.PriorityQueueReceiver(T), zui.PriorityQueueSender(T); implemented slice -->
<!-- gpui-export-map: pub use refineable::*; => zui.Refinement(T), zui.Cascade(T); implemented slice; derive macro out of scope -->
<!-- gpui-export-map: pub use scene::*; => zui.gpu.Scene and render commands; partial -->
<!-- gpui-export-map: pub use shared_uri::*; => zui.SharedUri; implemented slice -->
<!-- gpui-export-map: pub use style::*; => zui.elements style/layout fields; partial -->
<!-- gpui-export-map: pub use styled::*; => zui Element style methods; partial -->
<!-- gpui-export-map: pub use subscription::*; => zui.app.Subscription; partial -->
<!-- gpui-export-map: pub use svg_renderer::*; => zui.images.svg and svg elements; partial -->
<!-- gpui-export-map: pub use taffy::{AvailableSpace, LayoutId}; => zlay layout module; partial -->
<!-- gpui-export-map: pub use test::*; => zui TestHarness and headless probes; partial -->
<!-- gpui-export-map: pub use text_system::*; => zui.text_engine and text elements; partial -->
<!-- gpui-export-map: pub use util::{FutureExt, Timeout}; => zui.app.tasks timers; partial -->
<!-- gpui-export-map: pub use view::*; => zui.app.Entity/view mounting; partial -->
<!-- gpui-export-map: pub use window::*; => zui.app.Window and WindowOptions; partial -->
<!-- gpui-export-map: pub use pollster::block_on; => zui.blockOn; implemented compatible sync helper; async Future polling out of scope -->

### GPUI source families (machine-checked)

<!-- gpui-source-family: _accessibility -->
<!-- gpui-source-family: _ownership_and_data_flow -->
<!-- gpui-source-family: accesskit -->
<!-- gpui-source-family: action -->
<!-- gpui-source-family: anyhow -->
<!-- gpui-source-family: app -->
<!-- gpui-source-family: asset_cache -->
<!-- gpui-source-family: assets -->
<!-- gpui-source-family: color -->
<!-- gpui-source-family: colors -->
<!-- gpui-source-family: ctor -->
<!-- gpui-source-family: debug_overlay -->
<!-- gpui-source-family: element -->
<!-- gpui-source-family: elements -->
<!-- gpui-source-family: executor -->
<!-- gpui-source-family: geometry -->
<!-- gpui-source-family: gestures -->
<!-- gpui-source-family: global -->
<!-- gpui-source-family: gpui_macros -->
<!-- gpui-source-family: gpui_shared_string -->
<!-- gpui-source-family: gpui_util -->
<!-- gpui-source-family: http_client -->
<!-- gpui-source-family: input -->
<!-- gpui-source-family: inspector -->
<!-- gpui-source-family: interactive -->
<!-- gpui-source-family: keymap -->
<!-- gpui-source-family: path_builder -->
<!-- gpui-source-family: platform -->
<!-- gpui-source-family: pollster -->
<!-- gpui-source-family: prelude -->
<!-- gpui-source-family: profiler -->
<!-- gpui-source-family: proptest -->
<!-- gpui-source-family: queue -->
<!-- gpui-source-family: refineable -->
<!-- gpui-source-family: scene -->
<!-- gpui-source-family: shared_uri -->
<!-- gpui-source-family: spring -->
<!-- gpui-source-family: style -->
<!-- gpui-source-family: styled -->
<!-- gpui-source-family: subscription -->
<!-- gpui-source-family: svg_renderer -->
<!-- gpui-source-family: taffy -->
<!-- gpui-source-family: test -->
<!-- gpui-source-family: text_system -->
<!-- gpui-source-family: util -->
<!-- gpui-source-family: view -->
<!-- gpui-source-family: window -->

### Executable exit gates

<!-- gpui-gate: id=inventory command=python3 tools/check-gpui-parity-matrix.py -->
<!-- gpui-gate: id=differential command=bash tools/run-differential.sh -->

Run both evidence gates from the repository root:

```sh
python3 tools/check-gpui-parity-matrix.py
bash tools/run-differential.sh
```

It fails if the pinned GPUI file gains or loses a public module/re-export that
is not recorded here, if a source family is omitted, or if a future matrix row
claims `Complete` without a declared executable `gate:` and an `evidence:`
label. The differential gate compares only the named fixture cases and is not
sufficient to prove behavioral parity for an entire source family.
