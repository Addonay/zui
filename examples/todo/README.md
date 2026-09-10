# Todo — ZUI ideal target

`main.zig` next to this file is the design target: a fashionable dark todo
app written as if `zui` already existed. It is intentionally not compiling
yet — `src/` has no implementation.

It mirrors GPUI's shape, translated to Zig:

- `App` / `Window` / `Context(T)` / `Entity(T)` — one foreground thread owns state.
- Views are structs with `render(self, window, cx) Element`.
- Elements are small value builders: `zui.div().flex_row().gap(12).child(...)`.
- Interaction is `cx.listener()` / `cx.listenerWith()` + `on_click` / `on_action`, then `cx.notify()`.
- Retained widgets (the composer input) are child entities: `Entity(zui.TextField)`.

## Naive build-out order

1. `App` + event loop + one window (native backend directly, single backend).
2. `Entity` arena + `Context.notify()` dirty bit + re-render every dirty frame (no diffing).
3. Elements `div / text / spacer / when / children` + naive flexbox measure/layout (no cache).
4. Software-first painter: one quad batch + one text run (use `stb_truetype` first, HarfBuzz later).
5. Input: mouse hit-test, focus chain, keymap → actions, `TextField` as first retained widget.
6. Then: scroll, window resize, clipboard, IME, GPU backend (Metal/Vulkan/WebGPU).

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
