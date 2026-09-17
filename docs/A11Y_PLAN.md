# Interaction and accessibility foundations

## Implemented seam (2026-09-17)

- `widgets.behavior.Pressable`: pointer down arms, captured release inside activates,
  release outside cancels. Enter/Space non-repeat key-down and semantic activation
  share `activate()`. Existing `on_click` remains press-time for compatibility.
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
  and `unkeyed` are observable. Native publication must reject incomplete snapshots
  rather than publishing them as complete. Snapshots and strings expire at reset;
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

## AccessKit C binding plan — not vendored

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

- Focus-loss/unmount/window-teardown capture cancellation is not fully wired:
  Pressable exposes `cancel`, and generic controls reject releases without current
  bounds, but Window/App do not yet deliver all lifecycle cancellation events.
  Keyboard activation currently happens on key-down, not Space key-up.
- Full capture/bubble/default-action propagation, nested scroll consumption,
  touchpad phases, overlay dismissal and a complete modal event barrier remain.
- Disabled pointer hits can still adopt focus under legacy Window dispatch;
  traversal and semantic actions exclude disabled controls. Scope lists do not
  automatically update as dialog content changes. General programmatic focus and
  semantic focus are not yet constrained by the modal scope.
- TextField semantics, text selection/range semantics, IME accessibility and
  native bridge publication are not connected here. TextField belongs to a
  concurrent editing workstream and was not changed.
- Hover/pressed presentation is basic; controls lack polished loading/error,
  reduced-motion/text-scale/high-contrast policies and full theme contrast audits.
  RadioGroup needs a clearer pressed/disabled presentation and roving option focus
  semantics for a production native bridge.
- Demos keep their visuals and existing press-time selftest contracts. Their
  local callback/state ownership is not a drop-in replacement for retained
  component entities; migration is deferred rather than restyling them wholesale.
