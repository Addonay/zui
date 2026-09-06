# ZUI Build Prompt

(Paste into a fresh session to continue the work.)

**Task: Build ZUI — a hand-rolled, high-performance GPU UI framework in Zig, from the current scaffold to a running todo app.**

**Context.** You are working in `/home/addo/dev/stupid/zui` (Zig `0.17.0-dev.1970+67f39b551`, Linux). This is a from-scratch UI framework. The owner is writing everything themselves — core, Metal/Vulkan/OpenGL/DX12 bindings, Wayland/X11/Win32/Cocoa backends, all in Zig — and will only depend on very low-level system libraries (FreeType, HarfBuzz, Fontconfig and similar). No SDL, no GLFW, no DVUI as dependencies.

**Reference material (vendored read-only in `.references/`, never import as dependencies):**
- `gpui/` — the API ideal: `App` / `Window` / `Context(T)` / `Entity(T)`, views with `render()`, `div().child()` value-type element builders, `listener` + `on_click`/`on_action` + `notify()`.
- `gooey/` — the Zig proof-of-concept: module layout, static allocation caps, hand-written C `extern` bindings, `@embedFile` shaders. Two files are already MIT-licensed ports with attribution headers (`src/core/limits.zig`, `src/text/bindings.zig` — Copyright 2025 Duane Bester).
- `sdl3/`, `glfw/`, `dvui/` — backend architecture references only: backend vtable + bootstrap probe order, `dlopen`ed WM/GL/VK function tables with graceful fallback, `PumpEvents` + `WaitEventTimeout` event-loop pair, `SDL_Send*`-style event normalization before queueing, GLFW `null_*` minimal reference backend, DVUI `@src()`-derived widget IDs and tiny `Backend` contract.

**Current repo state (do not regress):**
- `src/core/` — `geometry.zig` (Point/Size/Rect/Bounds + tests), `color.zig` (`hex()` for packed ints, `rgb()/rgba()` for 0–1 floats + tests), `limits.zig` (ported caps + `MAX_EVENTS_PER_FRAME` + comptime validation + tests), `mod.zig`.
- `src/platform/` — `id.zig` (FNV `@src()` IDs + test), `event.zig` (normalized `Event` union + fixed ring `EventQueue` + test), `backend.zig` (`BackendKind`/`VTable`/`Backend` fat pointer + `preferredOrder()` wayland → x11 → null + test), `null.zig` (headless `NullBackend` implementing the full vtable + test), `mod.zig`.
- `src/gpu/` — `scene.zig` (fixed quad collector, fail-fast push + test), `mod.zig`.
- `src/text/` — `bindings.zig` (ported FT/HarfBuzz/Fontconfig externs, compiles without system headers), `mod.zig`.
- `src/root.zig` — public surface re-exporting the above plus `hex/rgb/rgba/white/transparent` helpers.
- `build.zig` — `zui` module + `test` step. `zig build test` passes 16/16 (verify with `zig test src/root.zig`).
- `build.zig.zon` — `paths` deliberately excludes `.references/` (3GB+); `fingerprint` is content-derived, update it only if Zig tells you to.
- `examples/todo/` — `main.zig` + `README.md` are the **design target**: a fashionable dark todo app in the ideal retained API. It parses (`zig ast-check` passes) but cannot build — `App`/`Context`/`Window`/`Entity`/`div`/`text`/`TextField` do not exist yet. Do not dumb it down to fit the implementation; implement upward until it builds and runs.

**What to do, in strict order (one phase at a time, each ending green):**
1. **Frame loop on null backend** — `App.init/run`, `openWindow`, per-frame `poll → render → Scene → present` against `NullBackend`. Headless test drives 3 frames and asserts scene contents.
2. **Flexbox layout** — naive measure + position pass over a small element tree (`div`/`text`/`spacer`), no caching. Unit tests on fixed sizes, gaps, nesting.
3. **Software painter + real window** — first real backend (Wayland, X11 fallback second): window creation via `dlopen`ed system libs (never link directly), present the `Scene` (start with OpenGL or pure software shm, Vulkan later). A blank window in `theme.bg` is the milestone.
4. **Text** — Fontconfig discovery + FreeType raster + HarfBuzz shaping using `text/bindings.zig`, glyph atlas with eviction, `measureText` matching rendered output. Test with shaping fixtures, no window needed.
5. **Input** — hit-testing, focus chain, keymap → actions, `TextField` as the first retained widget entity.
6. **Retained layer** — `Entity(T)` arena, `Context(T)` with `listener`/`listenerWith` + `notify()`, element builders from the todo (`div/text/spacer/when/children`, declarative `hover_bg`, `zui.hex` colors).
7. **Run the todo** — wire `zig build run-todo`, make `examples/todo/main.zig` compile with minimal edits (prefer implementation changes over example changes), and its headless model test passes.

**Hard constraints:**
- Zig only for our code; system libs (`freetype`, `harfbuzz`, `fontconfig`, `vulkan`, `wayland-client`, etc.) via hand-written `extern` + runtime `dlopen` tables, never `@cImport` for our own headers.
- Zero allocation after init on the frame path; every buffer/queue gets a cap in `core/limits.zig`.
- No verbatim copies from SDL/GLFW/DVUI/GPUI (license + language mismatch) — port patterns only. Gooey MIT ports are allowed but must keep the attribution header.
- No closures in the public Zig API (Zig has none) — use function pointers + small captured args like the existing `listenerWith`.
- Every new module ships with unit tests; `zig fmt` clean; `zig build test` green at every step. Verify by running, never by inspection alone.

**Deliverable for the session:** state which phase you are implementing, implement it, and report files changed + test counts + remaining phases.
