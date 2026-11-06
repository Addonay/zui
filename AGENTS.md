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
   better than the dependency. Actually that should be the case. copy the
   backends to zui and leave zicr alone. discard it when done.
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

## 2. Status

The old ZUI tree (a hand-rolled retained UI framework) was deleted and replaced with a fresh port of GPUI. The old
code is still in git history (`main` before this push, commit `d7a2017`).

**`todo.md` is the tracker**: what is missing, what exists in name only, and the API comparison by GPUI file. Keep
it current, and do not repeat it here.

On Linux, X11 and Wayland, with Vulkan and a CPU fallback, about 91% of the GPUI functions worth porting exist by name,
and every GPUI example is ported except `toggle_headless`, `layer_shell` and `a11y`. macOS, Windows and web are not
started, though CI's checks keep the shared code compiling for Windows and macOS. CI itself is off for now: the
owner's GitHub account has a billing lock, which the owner will sort out, so PRs are checked locally.

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
src/input.zig            ElementInputHandler: a view's EntityInputHandler methods as a PlatformInputHandler
src/executor.zig         BackgroundExecutor, ForegroundExecutor, Task(T)
src/scene.zig bounds_tree.zig atlas.zig path_builder.zig
src/assets.zig svg_renderer.zig spring.zig
src/http_client.zig http_native.zig image_disk_cache.zig   remote images: HTTP client and on-disk copies
src/platform.zig         Platform / PlatformWindow vtable interfaces + shared types
src/platform/headless.zig  headless/test platform
src/platform/linux.zig + linux/{wayland,wayland_proto,x11,x11_proto,xkb,input,dl}.zig
src/platform/linux/text_input_state.zig  text-input-v3 double-buffered state, no Wayland in it
src/platform/linux/xim_preedit.zig       XIM composition edits, no X11 in it
src/platform/linux/x11_scroll.zig        XInput2 scroll valuators, no X11 in it
src/platform/linux/dbus.zig system_notifications.zig   D-Bus client, and notifications on it
src/platform/linux/xdnd.zig              text/uri-list parsing for file drags
src/platform/linux/wayland_scroll.zig    wl_pointer axis frames, no Wayland in it
src/renderer/cpu.zig     CPU renderer
src/gpu/                 portable GPU layer (Vulkan/D3D12/D3D11/Metal/GL/WebGPU), vendored from zicr
src/renderer/gpu.zig     GPU renderer + GpuAtlas; shaders.glsl -> shaders_gen.zig (committed)
src/renderer/vulkan.zig  libvulkan loading, instance/device, per-window swapchains
src/renderer/window_renderer.zig  GpuContext (shared per connection) + GpuWindow
src/renderer/gpu_test.zig  GPU vs CPU pixel comparison (skips without Vulkan 1.3)
src/renderer/shdc/       generator that turns sokol-shdc output into shaders_gen.zig
examples/*.zig           line-by-line ports of crates/gpui/examples/*.rs
third_party/             Wuffs, nanosvg, images.c shim
```

## 4. Toolchain, dependencies and the container setup

- Zig **0.17.0** stable: `https://ziglang.org/download/0.17.0/zig-x86_64-linux-0.17.0.tar.xz`
  (installed at `~/tools/zig-x86_64-linux-0.17.0`, symlinked to `/usr/local/bin/zig`).
  Note: Zig 0.17 changed a lot vs older versions — see §9.
- `build.zig.zon` dependencies:
  - `cozmic` — `git+https://github.com/Addonay/cozmic.git#bd7e29cf11b9db0c046647dd58d8c8622c9b8683`
    (its own deps: ezi_code, harfbuzz 14.1.0, freetype 2.14.3, zlib 1.3.1, libpng 1.6.50)
  - `zafi` — `git+https://github.com/Addonay/zafi.git#04086f7a21f120a5ea52f921fb2034d75e10264f`
  - `sokol_tools_bin` (lazy) — the `sokol-shdc` binaries, fetched only by
    `zig build shaders -Dregen-shaders=true`. Run that after editing `shaders.glsl`;
    normal builds use the committed `src/renderer/shaders_gen.zig`.
  - Removed: `zicr` (backends copied to `src/gpu/`, see §1.2), `zlay`, `vellz`, `wgpu`.
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
| `.references/gpui` (local name; `.references/zed` in the cloud container) | `https://github.com/zed-industries/zed` (sparse: `crates/gpui`, `gpui_macos`, `gpui_linux`, `gpui_windows`, `gpui_wgpu`, `gpui_web`, `gpui_platform`, `gpui_macros`) kept up to date with `git pull`; last checked at `4a6121b` (2026-11-06) | THE reference. Every port follows these files. |
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
  `request_layout_ext(self, ?*const GlobalElementId, *Style, window, cx) ?LayoutId`, `prepaint_ext` and
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
- **View caching**: `entity.cached(style)` and `AnyView.cached(style)` follow GPUI's `ViewElement`: a clean view
  replays ranges of the rendered frame (`reuse_prepaint`, `reuse_paint`, `reuse_subtree`, `reuse_layouts`, `Scene.replay`).
  ZUI's elements and listeners live in the frame arena, which a reused view must outlive, so it renders into two
  arenas of its own (`ViewElementState`), alternating, because the rendered frame still uses the last render's
  while the next one is made. Deferred draws remember their arena. The text style in the key is a hash, since its
  strings may not outlive the frame. A second prepaint in one frame, after a failed `transact`, never reuses.
  Consequences for element code: hitbox ids do not repeat across frames, so hover is known only in paint (the hit
  test runs again between prepaint and paint), and a listener that changes how its element looks calls
  `window.notify_current_view()`, not `window.refresh()`, which renders every cached view again. Mouse listeners
  run with their view current. Line layouts are per window, while the text system stays per app: `Window.draw`
  points `TextSystem.active_cache` at the window's.
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
  matched first via `key_dispatch.dispatch_key` (see multi-stroke bindings below); unhandled
  key-downs with `key_char` go to the platform input handler.
- Key and action listeners are registered during **prepaint** (when the
  element's dispatch node is pushed), not paint as in GPUI — `element.zig`
  pushes/pops dispatch nodes around prepaint only.
- **Div paint order** matches GPUI: shadows → background → ext paint →
  children (in overflow mask, scroll-offset) → border on top.
- **Layout**: zafi tree cleared per frame (like GPUI), styles converted to
  device pixels (scale factor), rounding disabled, bounds snapped with
  round-half-toward-zero; measure functions via a threadlocal trampoline.
- **Color glyphs**: cozmic renders COLRv1 through the bundled HarfBuzz's `hb-raster` and the rest
  through FreeType. `-Dsystem-libs` builds of cozmic have no COLRv1.
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
- **GPU renderer**: port of `gpui_wgpu`'s batching on the vendored `src/gpu/` layer
  (never zicr's `render2d`). Instances are per-instance vertex attributes, so it stays
  portable to GL/WebGL. One `GpuContext` (device, atlas, pipelines) per connection, one
  `GpuWindow` (swapchain) per window; a window that cannot get one uses the CPU renderer.
  Selection: `ZUI_RENDERER=cpu` forces CPU, `=gpu` also accepts software Vulkan, the default
  takes hardware devices only (the CPU renderer beats llvmpipe). Debug builds log the choice.
  Requires Vulkan 1.3 with dynamic rendering, synchronization2 and buffer device address.
  Wayland uses mailbox and the existing frame-callback pacing, so an occluded window never
  blocks the main thread; X11 uses FIFO. Frame upload cap: 32 MB (`error.FrameTooLarge`,
  about 200k quads). Pattern stripes take their remainder from the instance because the
  packed height exceeds float precision and in-shader `fmod` drifts.
  Not drawn yet: subpixel sprites (need dual-source blending; nothing in ZUI emits them today)
  and platform surfaces. No device-lost recovery: a failed frame logs and retries.
  `ZUI_VULKAN_VALIDATION=1` enables the Khronos layer when installed (it was not on the
  machine used, so the renderer has not been run under native validation).
  Test on software Vulkan: `VK_ICD_FILENAMES=/usr/share/vulkan/icd.d/lvp_icd.x86_64.json`;
  `ZUI_GPU_TEST_DUMP=dir` writes each GPU/CPU pair as PPM.
- **Text input**: ranges are UTF-16, as in GPUI. Platforms call `PlatformWindow.emit_ime`
  (`ImeInput`), which `Window.handle_ime` applies to the focused handler. After each frame the
  window tells the platform when the focused text field changed (off, then on, on every change,
  because text-input-v3 requires it) and where the caret went. Wayland rules, from the protocol
  XML: a `done` with a stale serial still applies text but must not send state (foot gets this
  wrong); the rectangle is not moved while composing; `enter` can arrive before `wl_keyboard.enter`
  and with a null surface; one-byte commits go through as key presses, because IBus takes plain
  keys too. X11: XIM is opened only when XMODIFIERS names a real method, otherwise xkb compose
  shows dead keys inline. Xlib's instantiate callback fires once per registration, so after a
  server dies reconnecting is retried once a second for a minute. Every event must go through
  `XFilterEvent`, also while no server is connected. Not done: `delete_surrounding_text` (we never
  send surrounding text), `keyboard_layout`. GPUI has no content types either: it always sends none/normal.
- **Image decoding**: `src/wuffs.zig` over Google's Wuffs (`third_party/wuffs`, `0.4.0-alpha.12`), a separate
  library built optimized even in Debug. Not `stb_image`, which is not meant for untrusted files, and images
  now come from arbitrary URLs. Wuffs decodes one frame of an animated WebP, so the Zig side walks the RIFF
  chunks and composites, and that Zig is the part where a memory bug could live.
- **D-Bus**: `platform/linux/dbus.zig` is a client in Zig with no libdbus, non-blocking and polled from the
  platform loop. Test it only against a fake server on a private bus (see the isolation recipe below): a test
  must never reach the real session bus. Notifications are on top of it, in `linux/system_notifications.zig`.
- **Remote images**: `AssetCache` starts a fetch on first use and returns `error.Loading`, which `img`
  shows as `with_loading`, and the windows refresh when it settles. Each fetch runs on a `std.Io.Threaded`
  of its own in an `Io.Group`, not on the background executor, so quitting can cancel a download stuck on
  a slow server. Raster decoding happens on that thread, SVG on the main thread since its renderer is
  not thread-safe. A copy is kept in the per-user cache directory (`with_image_cache`, off in tests)
  and shown first, then the fetch still runs and replaces it if the bytes changed. Measured on 2026-11-05:
  curl takes 1.0 to 1.4 s for these URLs, `std.http` the same in release and about 0.9 s more in Debug,
  decoding 25 to 60 ms. So the HTTP client is a static library, `http_native.zig`, built optimized even in
  Debug, because `std` is compiled per artifact. It has its own `Io` and a C ABI, and callers poll a job
  from their own `Io` so that cancelling them cancels the fetch.
- **Window prompts**: `window/prompts.zig` follows GPUI's fallback prompt, with one addition: GPUI handles
  no keys there, and ZUI takes arrows, Tab, Enter, Space and Escape (which picks the Cancel button).
  Answers go to a listener. A replaced prompt, or one whose window closed, is never answered.
- **Multi-stroke bindings**: `Window.dispatch_keystroke` follows GPUI's `dispatch_key_event`. A prefix
  is held in `pending_keystrokes` (strings owned, since platform buffers are not stable) and its keys
  reach nobody. A key that breaks the sequence replays what was held. It waits one second only if
  the prefix is a binding of its own, a text field has focus, or it is a lone modifier; otherwise it
  waits for the next key forever, as in GPUI. Moving focus drops it. Key events now redraw first
  when the window is dirty, so they never match against a stale dispatch tree.
- **X11 pointer and timing**: pointer events come from XInput2 when libXi and XI 2.1 are there,
  and from core events otherwise (selecting XI2 suppresses the core ones for that window). Wheels
  report both through valuators and as emulated buttons 4 to 7: the emulated ones are skipped, or
  every notch would scroll twice. Keys stay on core events, because XIM needs them. Each monitor's
  refresh rate comes from RandR (interlace and double scan included), so frames follow the display
  under the window. No frames while unmapped or fully covered. `_NET_WM_SYNC_REQUEST` is answered
  after the frame is drawn, not on configure as in GPUI. XDND takes `text/uri-list` of any length up
  to 16 MB, unlike GPUI's 4 KB; lists sent with INCR are refused. Events are emitted as
  `FileDropEvent`, but nothing turns them into element drops until `on_drop` exists.
  Extension struct layouts in `x11_proto.zig` are checked at compile time against values measured
  with `offsetof`.
- **Drag and drop**: `App.active_drag` holds an `AnyDrag`: an erased copy of the value (shallow, so
  slices inside must outlive the drag) and the view drawn under the pointer, released when it ends.
  Platform file drags become the same thing with an `ExternalPaths` value, whose paths belong to the
  platform: a drop handler that keeps them must copy them. Any mouse up that no element took
  cancels the drag.
- **Tooltips**: a small state machine in `InteractiveElementState`. Timers cannot be cancelled, so
  each carries a generation, and checks with `Window.owns_element_state` that its element still exists.
- **Wayland pointer and drags**: fingers scroll in pixels, wheels in lines. `wl_data_device` is
  bound at version 3, so a drag offers copy only (a move would make the source delete the user's
  files). The file list is read through a non-blocking pipe polled by the main loop, with a timeout,
  because a slow source must not freeze the window. `finish` is sent only with an accepted type and
  a chosen action, since it is a protocol error otherwise. Drags cannot be tested with the harness
  below: even GTK to GTK gets cancelled under injected pointers, so test those by hand.
- **Testing without touching the desktop**: isolate *before* starting the bus, so the bus and
  everything it activates inherit it: `env -u WAYLAND_DISPLAY -u DBUS_SESSION_BUS_ADDRESS
  -u IBUS_ADDRESS HOME=<s>/home XDG_CONFIG_HOME=<s>/cfg XDG_DATA_HOME=<s>/data XDG_CACHE_HOME=<s>/cache
  XDG_STATE_HOME=<s>/state XDG_RUNTIME_DIR=<s>/rt dbus-run-session -- script`. **Never run
  `gsettings` or `dconf` outside that**, and setting these variables inside the script is too late:
  `dconf-service` is activated with the bus daemon's environment and writes the real user database.
  Compare `stat ~/.config/dconf/user` and the real `ibus-daemon` PID before and after.
  - Native Wayland: `mutter --headless --wayland --no-x11 --virtual-monitor 1024x768
    --wayland-display zui-test`. Unset `DISPLAY` for the client, or a Wayland failure silently falls
    back to X11. `WAYLAND_DEBUG=client` shows the protocol.
  - A real Wayland IME: `gnome-shell --headless --wayland --no-x11 --unsafe-mode` instead, with
    `GSETTINGS_BACKEND=keyfile` and `sources=[('ibus','libpinyin')]` in
    `<s>/cfg/glib-2.0/settings/keyfile`. It starts its own ibus. Press Escape to leave the overview,
    then click the field: a new window does not get keyboard focus by itself.
  - Keys and clicks: `org.gnome.Mutter.RemoteDesktop` over one D-Bus connection (the session dies
    with it; its keyboard hot-plugs on the first key, so that press is lost).
  - A real X11 IME: `ibus-daemon --xim --panel=disable`, `ibus engine libpinyin`,
    `XMODIFIERS=@im=ibus`, on Xvfb. Unset `WAYLAND_DISPLAY`, or the app opens on the real desktop.
  - Smooth scrolling and a real window manager: leave out `--no-x11` so mutter starts XWayland.
    The display name is in its log ("public X11 display"), and the client needs
    `XAUTHORITY=$XDG_RUNTIME_DIR/.mutter-Xwaylandauth.*`. `NotifyPointerAxis` gives real valuators.
    `--virtual-monitor 1024x768@120` tests refresh rates.
  - Dead keys on X11: `xmodmap -e "keycode 48 = dead_acute"`, then `xdotool key 48`. Plain mutter
    ignores layout settings.
  - A process still running at its timeout proves nothing: check for frames and protocol errors.
    Send output to a file, since pipes can lose it when `timeout` kills the job. `xdotool
    windowclose` destroys the window under the app, which logs harmless X11 protocol errors.
- **Headless snapshots**: `ZUI_HEADLESS=1 ZUI_SNAPSHOT=out.ppm zig build run-<example>`.
  `ZUI_SCALE=2` sets the headless scale factor.

## 8. Known gaps / next steps

See `todo.md`. In order: finish the API, then performance against GPUI (view caching and benchmarks first), and the
other platforms when the owner asks.

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
- `x = .{ .a = x.b, .b = x.a }` writes through the result location: `.b` reads the new `.a`, so a swap
  collapses both fields with no error. Copy to a local first or use `std.mem.swap`.
- Optimize mode tags are lowercase (`.debug`).
- `b.args` doesn't exist in `std.Build` (pass-through run args not wired).

## 10. How work is organized

- Haiku subagents read the source and draft a port, on a branch, into a PR against `dev`. The orchestrator reviews it,
  corrects and optimizes it, and merges it with a merge commit. The review finds real bugs most of the time, so it
  is not optional. Read the riskiest code, and run backends live: agents' tests rarely catch backend bugs.
- Agents and the orchestrator check with `zig build check -j2`, `zig build test -j2`, snapshots, and private displays
  (see section 7). Keep builds to two at a time, without ReleaseFast: the machine has limited memory, and builds
  have filled the disk (`.zig-cache` reached 60 GB). Agents delete their own build output, and scratch goes under
  `.zig-cache/scratch`, because `/tmp` is small.
- Nothing may reach the real desktop: no `zig build run-*` without isolation, no window, notification, program or file
  dialog on the real session, and no `gsettings` or `dconf`.
- Check what a library does from its source or the web, not from memory: Wuffs' WebP support was misremembered.
- When GPUI moves, read its new commits in `crates/gpui*` and port what applies. Last checked at `4a6121b`.
