# GPUI input and focus parity

This document records the checked-in, source-backed slice implemented in ZUI.
The comparison sources are `.references/gpui/crates/gpui/src/interactive.rs`,
`gestures.rs`, `input.rs`, `key_dispatch.rs`, and `tab_stop.rs`.

## Implemented contract

- `src/platform/event.zig` defines retained touch phases and IDs, finger/pen
  identity, predicted positions, force/pressure stages, pen tilt/twist,
  pinch events, bounded file drag/drop payloads, and a two-contact,
  allocation-free tap/long-press/pan/pinch recognizer.
- `src/app/keymap.zig` exposes capture, target, bubble, and default-action
  phases. Bindings win before default actions; consumed events never invoke a
  default action. Tab, activation, dismissal, and directional defaults are
  represented explicitly and produce deterministic phase traces.
- `src/widgets/focus.zig` retains the existing paint-order focus behavior and
  adds explicit GPUI-style tab-stop ordering by index, stable insertion-order
  tie breaking, negative-index skipping, and bounded traversal traces.

The legacy `Event` queue remains unchanged in this slice. The rich
`event.InputEvent` envelope is additive so existing mouse, key, scroll, and
IME producers keep their behavior while platform adapters migrate.

## Tests

- `platform.event.test.rich pointer vocabulary preserves touch target and recognizes gestures`
- `platform.event.test.drag drop paths are owned and bounded`
- `app.keymap.test.default keyboard phases run only after unconsumed capture target bubble`
- `app.keymap.test.key binding wins before default action`
- `widgets.focus.test.tab stops sort by index and emit deterministic traversal trace`
- Existing focus wrap, dead-region, duplicate, and modal-scope tests remain in
  the same module.

Native touch/pen/gesture delivery and live compositor drag/drop remain backend
integration work; this slice provides the portable contract and deterministic
core behavior those adapters target.

## Current gate note (2026-09-22)

The source-ledger gate passes with 7 public modules, 45 public re-exports, and
47 source families. The aggregate headless build reports 25/25 steps (26/26
with AccessKit), 541/545 tests passed and 4 skipped on a fresh run. These
counts do not establish native touch, pen, gesture, or drag/drop delivery;
those remain unverified until an external compositor/client drives them.
