# Todo — ZUI example app

`main.zig` next to this file is a working retained todo app: it builds,
runs natively (`zig build run-todo`), renders headless snapshots, and
self-tests through synthetic input. It mirrors GPUI's shape, translated
to Zig:

- `App` / `Window` / `Context(T)` / `Entity(T)` — one foreground thread owns state.
- Views are structs with `render(self, window, cx) Element`.
- Elements are small value builders: `zui.div().flex_row().gap(12).child(...)`.
- Interaction is `cx.listener()` / `cx.listenerWith()` + `on_click` / `on_action`, then `cx.notify()`.
- Retained widgets (the composer input) are child entities: `Entity(zui.TextField)`.

## Build-out status

Shipped (see root `README.md` + `plan.md` for limits and roadmap):

1. `App` + event loop + one native window (`ZUI_BACKEND` override, headless `null`).
2. `Entity` store + `Context.notify()` dirty bit + re-render every dirty frame (no diffing).
3. Elements `div / text / spacer / when / children` + flexbox measure/layout.
4. Software-first painter: quads, glyph runs, image blits (`gpu/software`).
5. Input: mouse hit-test, focus handles, keymap → actions, `TextField` widget.
6. Next: correct scene ordering/clipping, layout-port adapter, GPU vertical slice.

## What to look at in `main.zig`

- `TodoApp.render` — root `div`, backdrop blobs, 560px centered column.
- `renderComposer` — `Entity(TextField)` + gradient Add button, Enter to submit.
- `renderRow` / `checkBox` / `filterPill` — per-row `listenerWith(id, ...)` handlers.
- `counts / progress / isVisible` — pure derived helpers, tested headless at the bottom.
- `onOpen` — `openWindow` + initial `window.focus` + key bindings, same as `gpui/examples/input.rs`.

## Fashion notes

Dark `#0e0e13` bg, blurred accent blobs, `#1e1f2a` cards, 16px radius,
violet→cyan gradient CTA, pill filters with counts, progress track,
hover-reveal delete, empty states per filter. No emoji, system font stack.
