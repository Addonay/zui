# AGENTS.md — ZUI: GPUI ported to Zig

This file records everything about how this codebase was built, so that any
agent (or human) can pick the work up. Read it fully before changing code.

## 1. Goal (from the project owner)

1. Make ZUI as close as possible to **GPUI** (the UI framework of the Zed
   editor, `zed-industries/zed/crates/gpui`), in design, architecture and
   **especially the public API**. A GPUI user should be able to transliterate
   GPUI code line by line. Where Zig forces a difference (no closures, traits,
   async sugar, explicit allocators), keep it close and idiomatic, not ugly.
2. Use the owner's libraries: **cozmic** (text; port of cosmic-text) and
   **zafi** (layout; port of Taffy). Use **zicr** ONLY for its **GPU backends**
   — the portable `zicr.gpu` device layer over **Vulkan, Direct3D 12, Metal,
   OpenGL/GLES and WebGPU (wgpu-native/Dawn/browser)**. zicr's `render2d` is
   NOT to be used: the renderer (batching, instance layouts, atlas, shaders,
   path rasterization) is ZUI's own, ported from GPUI's `gpui_wgpu` renderer,
   and it talks to the GPU exclusively through `zicr.gpu`. Copying zicr's
   backend code directly into ZUI is allowed (owner's repo) if that works
   better than the dependency.
3. Once API parity is ~99.99%, focus on **performance — beat GPUI**.
4. Dependencies only where they make sense (C/C++/Zig), minimal; otherwise
   write the code.
5. Workflow: all development on a **`dev`** branch via PRs (feature branch →
   PR → merge into `dev`); eventually `dev` → `main`, where `main` should hold
   **only source**: `src/`, `examples/`, build files, `third_party/`,
   `LICENSE`, `README.md` (no docs folders, ports, plans, reports). This file
   (`AGENTS.md`) is the explicit exception and must live on `main`.
6. Agent usage policy: use cheap subagents (Haiku) for most porting work and
   PRs; use a strong model (Opus) only occasionally for adversarial review.
   Don't review every turn — keep working.
7. Toolchain: **Zig 0.17.0 stable**, never a dev build.

## 2. Status at the time of writing (session stopped by the owner)

The old ZUI tree (a hand-rolled retained UI framework, its docs, tools, ports,
gap reports) was **deleted** and replaced with a fresh port of GPUI. The old
code is still in git history (`main` before this push, commit `d7a2017`) and
was used as a source for platform code.

Builds green: `zig build check` and `zig build test` (≈300 tests pass,
1 skip). `examples/hello_world.zig` renders pixel-identical in spirit to
GPUI's `hello_world.rs` (verified via headless snapshot).

| Area | Status |
| --- | --- |
| geometry, color, colors | done (ported tests) |
| style + `Refinement(T)` (derive Refineable) | done |
| styled (all 3214 GPUI `Styled` methods incl. macro-generated) | done |
| app: App, Application, Entity/WeakEntity/AnyEntity, Context(T), globals, observe/subscribe/emit/release, effects | done |
| window: frames, hitboxes, element state, focus, text style stack, content masks, opacity, paint_* primitives, mouse/key/action dispatch, deferred draws | done |
| element protocol, AnyElement, IntoElement, ParentElement, FluentBuilder, views (AnyView) | done |
| div + Interactivity (hover/active/focus/in_focus styles, click, mouse/key/action listeners, scroll, groups, track_focus, key_context) | done (drag/drop, tooltips, file drop, pressure/pinch NOT yet) |
| layout engine on zafi (`taffy.zig`, GPUI's TaffyLayoutEngine) | done |
| text system on cozmic (shaping+fallback, two-frame line layout cache, LineWrapper, ShapedLine/WrappedLine, StyledText/InteractiveText) | done (some GPUI extras missing, see §8) |
| keystroke, interactive events, keymap + context predicates, key_dispatch, actions | done (multi-keystroke pending replay, tab groups NOT yet) |
| executor (Background/Foreground executors, Task(T)) | done (thread pool; no async/await) |
| scene, bounds_tree, atlas (+CpuAtlas), path_builder | done |
| CPU renderer (port of GPUI WGSL math; SIMD + multithreaded bands) | done |
| headless platform (+ `ZUI_SNAPSHOT` PPM output) | done |
| Linux platform: Wayland + X11 (dlopen, no link deps) | done; verified on Xvfb and a mock Wayland compositor; no IME yet |
| TestAppContext / VisualTestContext + end-to-end tests | done |
| img / svg / assets (stb_image, nanosvg) | done (sync loading; GIF first frame only) |
| anchored, deferred, canvas, animation (+easings), spring | done |
| list (variable height), uniform_list | done (agent stopped right after tests passed; verify) |
| GPU renderer on zicr (`src/renderer/gpu.zig`, `shaders.glsl`, `-Dgpu=true`) | **WIP, not working yet** (see §7) |
| examples | 8 ported: hello_world, pattern, tree, text_layout, scrollable, ownership_post, active_state_bug, gradient |
| macOS / Windows / web platforms | NOT started |

## 3. Repository layout (mirrors `crates/gpui/src`)

```
src/zui.zig              root module: re-exports everything with GPUI names (+ prelude)
src/geometry.zig         Point/Size/Bounds/Edges/Corners, Pixels(=f32), Rems, Length...
src/color.zig colors.zig Hsla/Rgba/Background, rgb()/rgba()/hsla(), named colors
src/refineable.zig       Refinement(T) — comptime "#[derive(Refineable)]"
src/style.zig            Style, StyleRefinement, TextStyle, enums, BoxShadow, Fill...
src/styled.zig           Styled(Self) mixin: 3214 methods (generated once, see §6)
src/app.zig              App, Application, Entity, Context(T), Listener, Subscription...
src/app/test_context.zig TestAppContext, VisualTestContext + integration tests
src/window.zig           Window, WindowOptions/Handle, FocusHandle, Hitbox, Frame, paint_*
src/element.zig          Element protocol, Drawable, AnyElement, ElementId, ParentElement
src/view.zig             AnyView (entities rendered as elements)
src/elements/*.zig       div, text, img, svg, list, uniform_list, anchored, deferred,
                         canvas, animation, empty
src/taffy.zig            TaffyLayoutEngine on zafi (Style -> zafi.Style conversion)
src/text_system.zig + text_system/{font,line_layout,line,line_wrapper}.zig
src/keystroke.zig interactive.zig keymap.zig keymap_context.zig key_dispatch.zig action.zig
src/executor.zig         BackgroundExecutor, ForegroundExecutor, Task(T)
src/scene.zig bounds_tree.zig atlas.zig path_builder.zig
src/assets.zig svg_renderer.zig spring.zig
src/platform.zig         Platform / PlatformWindow vtable interfaces + shared types
src/platform/headless.zig  headless/test platform
src/platform/linux.zig + linux/{wayland,wayland_proto,x11,x11_proto,xkb,input,dl}.zig
src/renderer/cpu.zig     CPU renderer
src/renderer/gpu.zig gpu_test.zig shaders.glsl   GPU renderer (WIP)
examples/*.zig           line-by-line ports of crates/gpui/examples/*.rs
third_party/             stb_image, nanosvg, images.c shim
```

## 4. Toolchain, dependencies and the container setup

- Zig **0.17.0** stable: `https://ziglang.org/download/0.17.0/zig-x86_64-linux-0.17.0.tar.xz`
  (installed at `~/tools/zig-x86_64-linux-0.17.0`, symlinked to `/usr/local/bin/zig`).
  Note: Zig 0.17 changed a lot vs older versions — see §9.
- `build.zig.zon` dependencies:
  - `cozmic` — `git+https://github.com/Addonay/cozmic.git#bbc0f4f282acd024d1dc0b5e4d16fc4b08fcb6b0`
    (its own deps: ezi_code, harfbuzz 14.1.0, freetype 2.14.3, zlib 1.3.1, libpng 1.6.50)
  - `zafi` — `git+https://github.com/Addonay/zafi.git#04086f7a21f120a5ea52f921fb2034d75e10264f`
  - `zicr` (lazy) — `git+https://github.com/Addonay/zicr.git#87fe62228af2b69527ccd503da035c86b490ef42`
    (its lazy dep `sokol_tools_bin` provides the `sokol-shdc` shader compiler)
  - Removed from the old tree: `zlay`, `vellz`, `wgpu`.
- **Network quirk of the cloud container used**: Zig's own fetcher could not
  get through the HTTPS proxy ("unable to discover remote git server
  capabilities"), and GitHub archive tarballs returned 403. Workaround used:
  `git clone` each dep at the pinned commit into `~/deps/<name>`, copy without
  `.git`, and `zig fetch <dir>` to seed the global cache (hashes matched).
  Tarball deps (freetype/zlib/libpng) re-hashed differently when repacked in the
  cache, so they were unpacked directly into the project's `zig-pkg/<hash>/`
  directory by `~/deps/seed.sh <project dir>`. On a normal machine none of this
  is needed — `zig build` fetches everything.
- System libraries are never linked at build time: Wayland/X11/xkbcommon/libvulkan
  are `dlopen`ed. cozmic bundles HarfBuzz/FreeType statically.
- For GPU testing in a headless container: `apt-get install mesa-vulkan-drivers`
  gives lavapipe (`VK_ICD_FILENAMES=/usr/share/vulkan/icd.d/lvp_icd.json`).
  `Xvfb` is available for X11 tests.

## 5. Reference repositories that were cloned (not committed; `.references/` is gitignored)

| Path | Source | Why |
| --- | --- | --- |
| `.references/zed` | `https://github.com/zed-industries/zed` (sparse: `crates/gpui`, `gpui_macos`, `gpui_linux`, `gpui_windows`, `gpui_wgpu`, `gpui_web`, `gpui_platform`, `gpui_macros`) at `f816e1f` (2026-11-01) | THE reference. Every port follows these files. |
| `.references/zafi` | `https://github.com/Addonay/zafi` | layout API |
| `.references/cozmic` | `https://github.com/Addonay/cozmic` | text API |
| `.references/zicr` | `https://github.com/Addonay/zicr` | GPU layer, shader pipeline, Vulkan bootstrap example (`tools/vk_smoke.zig`) |
| `.references/zui-old` | `git worktree` of this repo at old `main` (`d7a2017`) | old Wayland/X11/xkb code, image code, text engine usage — copied/adapted |
| `.references/PORTING.md` | written by the orchestrator | the conventions given to every porting agent (summarized in §6) |

Recreate with: `git clone --depth 1 --filter=blob:none --sparse https://github.com/zed-industries/zed .references/zed && cd .references/zed && git sparse-checkout set crates/gpui crates/gpui_linux crates/gpui_wgpu crates/gpui_macros ...`

## 6. Porting conventions (the "API rules")

- **Names are GPUI's names**, snake_case for every function and method (even
  though Zig style is camelCase), PascalCase types, snake_case enum variants
  (`MouseButton::Left` → `.left`, `FontWeight::BOLD` stays `.BOLD` constant).
- `Option<T>` → `?T`; `Result` → error union; `impl Into<X>` → `anytype` +
  a converter (`geometry.to_length`, `color.to_hsla`, `color.to_background`,
  `style.to_fill`, `ElementId.from`, `app.to_listener`).
- Operators → methods: `.add/.sub/.mul/.div/.neg`. `union` → `@"union"`.
- **`Pixels = f32`** (alias, `px(v)` is identity), `ScaledPixels = f32`,
  `DevicePixels = i32`, `Rems = struct{value}`. Chosen for zero-cost math;
  type-safety traded for ergonomics.
- `SharedString` = `[]const u8` with the contract that it outlives the frame
  (static, or in the frame arena via `gpui.format(...)`).
- No `usingnamespace` in Zig ≥0.15: mixins are **alias declarations**
  (`pub const flex = StyledM.flex;`). To avoid repeating 3214 aliases per
  element, all styled elements share **one generic type**
  `StyledElement(Ext)` in `elements/div.zig`: `Div = StyledElement(DivExt)`,
  `Img = StyledElement(ImgExt)`, `Svg = StyledElement(SvgExt)`. Ext hooks:
  `request_layout_ext(self, *Style, window, cx) ?LayoutId` and
  `paint_ext(self, bounds, *const Style, window, cx)`. Ext-specific builder
  methods are forwarded with `pub const x = if (@hasDecl(Ext, "x")) Ext.x else {};`.
  The Styled alias block was generated by a throwaway Python script from
  `styled.zig`'s decl list (re-generate the same way if styled.zig changes;
  `styled.assert_has_all_styled_methods` checks drift).
- Element builders return pointers allocated in the **frame arena**:
  `div() *Div`, methods take/return `*Div`. `.id(x)` returns the same `*Div`
  (`Stateful(E) = E`), since there's no separate type state in Zig.
- Element protocol (duck typed): `RequestLayoutState`, `PrepaintState`,
  `element_id(self) ?ElementId` (named `element_id` because `id` is the
  builder method), `request_layout`, `prepaint`, `paint`. `Drawable(*E)`
  wraps it into the `AnyElement` state machine like GPUI.
- Closures → `fn` + context. `cx.listener(Self.on_click)` with
  `on_click(self: *Self, event: *const E, window: *Window, cx: *Context(Self))`;
  extra captures: `cx.listener_with(data, f)`. Plain handlers
  `fn(*const E, *Window, *App) void` are accepted everywhere a listener is.
- State styles: GPUI `.hover(|s| s.bg(red()))` → `.hover(gpui.style_refinement().bg(red()))`
  (a `*StyleBuilder` that has every Styled method).
- `entity.update(cx, |this, cx| ...)` → `entity.update(cx, T.method, .{args})`.
  `cx.new(|cx| T{..})` → `cx.new(T{..})` or `cx.new(T.init)` with
  `init(*Context(T)) T`.
- `actions!(ns, [A])` → `const A = gpui.Action("ns", "A");`.
- Entities are **not refcounted** (no destructors in Zig): they live until
  `entity.release(cx)`; windows release their root view on close.
  `Subscription.unsubscribe()` stops a subscription; dropping the value = detach.
- Allocators: hidden where GPUI hides them. `Application.new()` uses
  `std.heap.smp_allocator` (testing allocator under `zig test`);
  `Application.with_allocator(a)` to override.
- Scene primitives are plain Zig structs (not `extern`) because the geometry
  generics also hold tagged unions (Length) which can't be extern; GPU code
  packs them into its own extern instance structs.
- Ported code includes GPUI's `#[cfg(test)]` tests as Zig `test` blocks.

## 7. Architecture notes and decisions

- **Frame arena**: `window.frame_arena()` (threadlocal pointer to the window's
  `next_frame.arena`) — elements, listeners and formatted strings live there;
  the arena is the *frame's*, so data survives as `rendered_frame` until the
  frame after next (listeners dispatched against the rendered frame).
- **Draw**: `Window.draw` = clear next frame + layout engine → root
  `AnyView.into_any_element()` → `prepaint_as_root` → deferred draws →
  `paint` → `scene.finish()` → swap frames → `text_system().finish_frame()`
  (rotates the two-frame line-layout cache) → GC element states not touched
  for a frame → hit test → cursor → input handler. Platform calls `draw` from
  its `request_frame` callback when `dirty` or an animation frame was requested,
  then `present()`.
- **Invalidation**: `cx.notify()` → effect → windows that rendered that entity
  (`rendered_entities`) refresh. Effects are flushed when the outermost update
  ends (`pending_updates == 0`).
- **Element state** across frames: `window.element_state(S, global_id, init) *S`
  keyed by (global id hash, type id); also GPUI-shaped `with_element_state` and
  `use_keyed_state`.
- **Global element ids** are path hashes (u64) of the element id stack.
- **Hit testing**: hitboxes inserted in prepaint; `hit_test` walks back to front;
  `block_mouse` / `block_mouse_except_scroll` like GPUI.
- **Mouse dispatch**: capture phase front-to-back over registered listeners,
  then bubble back-to-front, `stop_propagation` stops. Key/action dispatch walks
  the dispatch-tree path to the focused node (capture then bubble), keybindings
  matched first via `Keymap.binding_for(keystroke, context_stack)`; unhandled
  key-downs with `key_char` go to the platform input handler.
- Key and action listeners are registered during **prepaint** (when the
  element's dispatch node is pushed), not paint as in GPUI — `element.zig`
  pushes/pops dispatch nodes around prepaint only.
- **Div paint order** matches GPUI: shadows → background → ext paint →
  children (in overflow mask, scroll-offset) → border on top.
- **Layout**: zafi tree cleared per frame (like GPUI), styles converted to
  device pixels (scale factor), rounding disabled, bounds snapped with
  round-half-toward-zero; measure functions via a threadlocal trampoline.
- **Text**: cozmic shapes each `layout_line` directly (one AttrsList span per
  run, no cozmic wrapping); GPUI's `LineWrapper` wraps. FontId = index into a
  resolved-face table (fallback faces get their own ids). Glyph rasterization
  through cozmic/swash into the sprite atlas (A8 mono, RGBA emoji).
  `SUBPIXEL_VARIANTS_X = 4, _Y = 1`.
- **Executor**: Zig 0.17 removed `std.Thread.Pool` and moved Mutex/Condition
  into `std.Io`; a small self-contained pool was written. Foreground tasks are
  main-thread callbacks (no suspension). `spawn_then` = background work then a
  main-thread continuation (replacement for `cx.spawn(async { bg.await; this.update })`).
- **Platform** interfaces are vtables embedded in backend structs and recovered
  with `@fieldParentPtr` (`Platform`, `PlatformWindow`); `PlatformAtlas` is a
  `{ptr, vtable}` value. `current_platform()` picks Linux (Wayland, then X11)
  or headless (`ZUI_HEADLESS=1`, tests, or no display).
- **CPU renderer** follows GPUI's WGSL literally: straight alpha, sRGB-space
  blending (as wgpu ALPHA_BLENDING), gradient color-space handling via LUT,
  erf-blur shadows, 4x MSAA paths with Loop-Blinn curves, gamma 1.8/contrast.
  Underline alpha is squared exactly like GPUI's shader (looks like a GPUI quirk).
  Benchmarks (4 vCPU Xeon, 1080p, ReleaseFast, 4 threads): 10k opaque rects
  5.2 ms, 10k rounded 21 ms, 10k gradients 231 ms (slowest path).
- **GPU renderer (WIP)** — design rule: ZUI renderer on top of `zicr.gpu`
  backends only (Vulkan on Linux/Windows/Android, D3D12 on Windows, Metal on
  macOS/iOS, GL/GLES as fallback, WebGPU for web/wgpu-native). Never import
  zicr's `render2d`; import the standalone module `zicr_dep.module("gpu")`.
  Native handle acquisition (Vulkan instance/surface/swapchain, Metal layer,
  DXGI swapchain, GL context, WebGPU surface) is per-platform code in ZUI.
  Files: `src/renderer/gpu.zig` + `shaders.glsl` (sokol-shdc
  annotated GLSL, port of `gpui_wgpu/src/shaders.wgsl`), gated by
  `-Dgpu=true` with a `gpu-test` step comparing GPU vs CPU pixels on lavapipe.
  The agent was stopped while fixing a compile error: importing the full
  `zicr` module pulls in zicr's `render2d`, which doesn't compile on 0.17 here;
  the fix in progress was to use `zicr_dep.module("gpu")` (the standalone GPU
  module) instead. Vulkan bootstrap (`vulkan_surface.zig`) and wiring into the
  Linux windows were NOT done. Plan: port `gpui_wgpu/src/wgpu_renderer.rs`
  batching onto zicr; instance data via instanced vertex attributes (portable
  to GL/WebGL); persistent growable instance buffer; GpuAtlas implementing
  PlatformAtlas with dirty-region uploads.
- **Headless snapshots**: `ZUI_HEADLESS=1 ZUI_SNAPSHOT=out.ppm zig build run-<example>`.
  `ZUI_SCALE=2` sets the headless scale factor.

## 8. Known gaps / next steps (in priority order)

1. Finish the GPU renderer on `zicr.gpu` backends only (see §7): switch the
   build to `zicr_dep.module("gpu")`, add Vulkan surface/swapchain bootstrap for
   Wayland/X11 and wire it into the Linux windows (CPU renderer stays the
   fallback), then macOS (Metal backend) and Windows (D3D12, Vulkan fallback)
   platforms, GL/GLES fallback, and web (WebGPU backend) — GPUI's
   `gpui_macos` / `gpui_windows` are the references; old ZUI had cocoa/win32
   skeletons in history.
2. Div: drag & drop (`on_drag`, `on_drop`, `drag_over`), tooltips,
   `on_file_drop`, pressure/pinch/back-gesture listeners, `on_aux_click`,
   `on_mouse_up_out`, `cached` views. `with_animation` is not yet aliased on
   StyledElement (add `pub const with_animation = animation.AnimationExt(*Self).with_animation;` etc.).
3. Input: `EntityInputHandler` / `ElementInputHandler` (GPUI text input
   example), IME (Wayland text-input-v3, X11 XIM), multi-keystroke binding
   replay, tab groups, `Unbind`.
4. Text: ShapedLine cursor/split APIs, typographic bounds, font enumeration,
   `add_fonts`, missing-glyph reporting.
5. Async: assets/images load synchronously; GIF animation; WebP.
6. Port the remaining GPUI examples (animation, image, image_gallery,
   input, list_example, uniform_list, popover, anchor, painting, data_table,
   drag_drop, focus_visible, tab_stop, window*, shadow, opacity, svg, text,
   text_wrapper, grid_layout, set_menus, ...). Each must run headless and
   produce a correct snapshot.
7. Performance (owner's phase 2 goal: beat GPUI): view caching (`AnyView::cached`
   with replayed scene ranges — `Scene.replay` exists), avoiding full layout
   when nothing changed, X11 XShm presentation, SIMD gradients in the CPU
   renderer, benchmarks vs GPUI.
8. Workflow: `dev` → `main` must eventually be source-only (see §1.5).
   `.references/` is gitignored.

## 9. Zig 0.17 gotchas met during the port

- `std.builtin` → `std.lang`; `@typeInfo(T).@"struct"` has `field_names`,
  `field_types`, `field_attrs`, `decl_names` (no `.fields`); `@Type` replaced by
  `@Struct(layout, backing, names, types, attrs)` etc.
- `std.ArrayList(T)` is unmanaged (`.empty`, `append(gpa, x)`).
- No `std.Thread.Pool`; Mutex/Condition live in `std.Io`.
- `Allocator.dupeZ` → `dupeSentinel(T, s, 0)`.
- Shadowing is an error: a local/param must not share a name with any decl in
  scope — with 3214 Styled aliases on `StyledElement`, names like `w`, `h`,
  `bg`, `m`, `p`, `active`, `text` cannot be used as locals inside it.
- Optimize mode tags are lowercase (`.debug`).
- `b.args` doesn't exist in `std.Build` (pass-through run args not wired).

## 10. How work was organized (for agents continuing it)

- Orchestrator wrote the architectural core (app, window, element, div,
  taffy, platform interfaces, refineable, view) and gave each Haiku agent one
  GPUI source family with an exact interface contract plus `PORTING.md`.
  Agents never commit; the orchestrator commits, keeps `zig build check` and
  `zig build test` green, and merges.
- PRs go from `claude/elegant-ritchie-jema73` (feature branch) into `dev`.
  PR #1 (core framework) was squash-merged into `dev`; later PRs should use
  **merge commits** (force-pushing after squash merges was blocked).
- Verify every change with `zig build check`, `zig build test`, and headless
  snapshots of examples.
