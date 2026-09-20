# Interaction and accessibility foundations

## Implemented seam (2026-09-17)

- `widgets.behavior.Pressable`: pointer down arms, captured release inside activates,
  release outside cancels. Enter activates on its initial non-repeat press; Space
  arms on press and activates on key-up. Semantic activation shares `activate()`.
  Existing `on_click` remains press-time for compatibility.
- `widgets.focus`: paint-order, deduplicated Tab/Shift-Tab traversal; excludes dead,
  disabled and hidden semantic handles. Bounded scanning handles zero candidates.
  `pushScope(window, ids, modal)` returns a token for nested `popScope` restoration.
  Scope ids are borrowed and must outlive the scope. Modal pointer presses outside
  scoped focus ids are rejected; hosts must assign handles to modal interactive
  children. These are focus primitives, not a complete dialog/overlay manager.
- `Element.keyed(key).semantic(properties)` copies names and text values into the
  frame's text storage. `painter.paint` builds `Frame.semantic_tree` after layout.
  Semantic parents are the nearest semantic ancestor; unannotated containers do
  not become fake accessibility nodes. Bounds use the same rectangular content
  clipping convention as paint. Stable keys, never element indices, identify nodes.
- Tree roles, names, string/numeric values, disabled/checked/selected/focused/
  hidden/read-only states, bounds, labelled-by/described-by relationships, and
  activate/focus/increment/decrement/set-value actions are renderer independent.
- `Tree.perform(key, request, window)` resolves the current snapshot and checks
  owner generations before invoking a handler. Framework controls register their
  targets in the existing owner table. Custom targets must be registered too, or
  outlive the frame. Native workers must never retain these raw target pointers.
- Snapshot capacity is 512; `semantic_dropped`, tree `dropped`, `duplicate_keys`
  and `unkeyed` are observable. Native publication rejects incomplete snapshots,
  retains the last known-good snapshot, and increments a rejection counter rather
  than publishing them as complete. Snapshots and strings expire at reset;
  clone follows the existing borrowed-string contract and requires its source
  frame to stay alive. No asynchronous snapshot ownership is implied.

## Components and usage

Public namespace: `zui.widgets.{Button,Checkbox,RadioGroup,Switch,Slider,Progress}`;
semantics: `zui.widgets.a11y`; tokens: `zui.widgets.theme`.

```zig
const save = cx.new(zui.widgets.Button, .{
    .key = 100, // application-owned, globally unique stable key
    .label = "Save",
});
// Within render:
return zui.div().child(save);
```

Each control is a retained entity. Options/name/item slices and optional on-change
listener are borrowed and must outlive the control (use static strings or retained
application storage). `on_change` receives the Window; observe `checked`, `value`,
`selected`, or the pressable activation count to read state. Stored application
listeners are not weak subscriptions: the callback owner must outlive the control.

Button/Checkbox/Switch support release activation and Enter/Space. RadioGroup has
one Tab stop, arrow-key wrapping selection, Home/End, Enter/Space, pointer options,
and individual radio semantic actions. Maximum 32 options, with caller-supplied
stable keys. Slider supports pointer position/drag, arrows, Home/End and semantic
range actions with clamping/step rounding. Progress is read-only but focusable for
inspection as requested; it does not activate. Theme options can override the
shared light/dark default per control. Changing shared theme requires a redraw.

`controls_test.zig` exercises the real App/Window + layout/paint seam: release
cancellation, pointer/keyboard/semantic convergence, destroyed-owner action
rejection, all six control types, keyboard form traversal, modal restore, disabled
and zero-candidate traversal, semantic parentage, numeric values, sibling reorder,
unmount removal, and focus-ring styling. This is headless evidence, not a native
screen-reader or visual-contrast certification.

## AccessKit C binding — vendored and wired (2026-09-18)

Status update to the original plan below: the library is now **vendored and
live**, following DVUI's `accesskit-c` architecture (not Gooey's — Gooey
hand-implements AT-SPI over D-Bus; we follow the gap report's advice and use
AccessKit's maintained platform adapters instead of reimplementing them).

- **Vendored**: `third_party/accesskit/` — accesskit-c sources at upstream
  tag `0.23.0` (Rust C-ABI crate + `include/accesskit.h` + licenses). Built
  by `cargo build --release` as a `zig build` step; `-Daccesskit=true`
  links it and exposes the `accesskit_c` translateC import. Default OFF:
  plain `zig build` never needs Rust.
- **`src/a11y/accesskit.zig`** implements the bridge: pure role/action
  mapping tables (comptime-asserted against the vendored header), one
  `Bridge` per window holding a mutex-protected node snapshot, per-frame
  `publish()` after paint (UI thread), `update_if_active` factory (AT
  thread, reads only the snapshot), and queued action requests drained on
  the UI thread into `Tree.perform` — click/increment/decrement/set_value/
  focus, owner-liveness and modal gating included.
- **Identity**: ZUI stable keys are the AccessKit node ids. ZUI already
  diagnoses duplicate and unkeyed nodes, preventing the duplicate-ID
  dropped-nodes pitfall AccessKit's own README documents.
- **Verified so far** (evidence levels per `docs/PLATFORM_MATRIX.md`):
  compiles + links with the vendored library on Linux native and both
  foreign targets compile without AccessKit; live X11 window creates the
  unix adapter (logged) with clean exit and no protocol errors; the current
  cached AccessKit aggregate gate reports 23/23 build steps succeeded; keyed
  TextField selection now maps to AccessKit text-selection positions. The
  build summary does not emit a repository-wide test-case total, so no
  aggregate case count is claimed here.
- **Not yet validated**: an actual screen reader speech workflow (Orca on
  this session has no AT running; VoiceOver/NVDA need native runners),
  Windows (UIA) and macOS (NSAccessibility) adapters, adapter-owned
  snapshot diffing (currently a full per-frame tree push like DVUI's
  default), richer text-run offsets/geometry, and IME-driven accessibility
  updates.

## Native validation

`tools/native_linux_probe.sh` performs a reproducible host check for the
AT-SPI session bus. While the todo app was running on Wayland, PyAT-SPI also
observed its frame, entry, and actionable button nodes; the `Active` button's
AT-SPI `click` action returned success. Re-run that semantic
publication probe with:

```sh
python3 tools/atspi_tree_probe.py todo
```

The probe is native semantic-tree evidence; it does not claim screen-reader
speech, which still requires Orca/NVDA/VoiceOver driving the application.

`tools/native_linux_fixture.zig` covers the event ordering and UTF-8 caret
boundaries used by the checked-in Wayland text-input-v3 and X11 XIM paths.
The current run passes 3/3 fixtures. These are contract fixtures, not native
success claims. Run them with
`zig test tools/native_linux_fixture.zig`; use the host probe for native
capability status.

## AccessKit C binding plan (original steps, for the remaining work)

1. Pin an AccessKit-C release and its matching AccessKit schema. Package bindings
   behind an opt-in build flag; keep native adapter dependencies out of headless
   builds. Verify supported platforms and licensing before adding the dependency.
2. Allocate one native adapter per native window. Use stable `u64` element keys as
   NodeIds, reserving a separate window-root id. Wrap multiple semantic roots in
   that window node. Map `switch_control` to AccessKit switch, progress to progress
   indicator, text_input to text input, and otherwise use matching schema roles.
3. Translate name/value/range, checked/disabled/read-only/hidden, relationships,
   focus, bounds and supported actions. Publish children in snapshot paint order.
   Convert window-local logical rectangles using platform window origin and DPI;
   do not bake physical screen coordinates into the toolkit semantic model.
4. Keep an adapter-owned copy of the last accepted snapshot (including strings).
   Diff by stable key; emit changed nodes, child-list changes and focus updates.
   Remove disappeared ids. On overflow/duplicate/unkeyed errors reject publication
   with a diagnostic. Reset the adapter on window teardown, never reuse stale ids
   without an explicit generation/lifecycle policy.
5. Marshal AccessKit action requests to the UI thread as `(window id, stable key,
   action, value)`. Resolve only the latest live frame via `Tree.perform`; never
   store a widget pointer in an AT worker. Reject unknown, stale, unsupported,
   disabled, hidden, or out-of-modal-scope requests. Extend modal action gating
   before native publication (currently only pointer/Tab trapping is integrated).
6. Wire adapter activation/deactivation and native focus/window notifications at
   the platform boundary. Use AccessKit's AT-SPI/UIA/NSAccessibility adapters;
   do not independently implement those protocols.
7. Validate Orca, NVDA and VoiceOver: discover controls by name, read checked and
   numeric values, activate/toggle/set value, traverse and close a modal, remove a
   focused control, reopen windows, change scale, and handle late action requests.
   Require native tests before advertising screen-reader support.

## Explicit remaining gaps

- Bridge teardown race (residual, documented 2026-09-18): the vendored C ABI
  has no join/quiesce, so an assistive-technology thread inside a bridge
  callback at window-teardown instant can touch the freed Bridge. Observed
  once as a post-selftest segfault in a continuously-animating demo on a
  machine with a live AT-SPI bus. Mitigations in place: the adapter only
  starts on real native backends (headless runs never spawn AT threads, so
  CI is deterministic), and callbacks hold no state past the call. Full
  fix needs an upstream join API or immortal callback state. Text selection/
  range semantics, IME accessibility and native bridge publication remain
  incomplete.
- Window now has a lifecycle cancellation boundary: focus changes, native focus
  loss, close, live focused-element unmount, and modal close dispatch a
  cancellation event before dropping capture. Controls, text fields, scroll
  areas, menus, tables and popovers clear their private latches there. A
  captured non-focusable custom owner still needs an explicit cancellation
  callback if it remains alive while unmounted.
- Pointer down/up and motion capture/bubble propagation now follow retained
  element ancestry and can stop explicitly. Scroll target/bubble dispatch
  follows the same ancestry when a child chains an unconsumed remainder;
  touchpad phases, overlay dismissal and a complete modal event barrier remain.
- Disabled pointer hits, traversal, and semantic actions exclude disabled
  controls. Modal scope checks
  now gate Window and semantic/programmatic focus, and owner-tagged portal
  scopes are cleared when their host disappears; dynamic scope content and
  legacy hand-built regions still need broader coverage.
- Keyed TextField nodes now publish a `text_input` semantic role with label,
  committed value, focus/set-value/text-selection actions, and basic AccessKit
  text selection (Unicode scalar indices derived from UTF-8 offsets). Synthetic
  richer text-run geometry, IME accessibility, and native screen
  reader validation remain; unkeyed fields preserve their historical
  unannotated mode.
- Hover/pressed presentation is basic; controls lack polished loading/error,
  reduced-motion/text-scale/high-contrast policies and full theme contrast audits.
  RadioGroup needs a clearer pressed/disabled presentation and roving option focus
  semantics for a production native bridge.
- Demos keep their visuals and existing press-time selftest contracts. Their
  local callback/state ownership is not a drop-in replacement for retained
  component entities; migration is deferred rather than restyling them wholesale.
