# ZUI todo

Everything deferred, in one place. Add to it instead of leaving gaps in comments or PR notes, and
delete an entry when it lands. `AGENTS.md` explains how the code works; this says what is left.
Like the other non-source files, this stays off `main` (see `AGENTS.md` §1.5).

## Needs the owner

- [ ] **GitHub billing lock**: every Actions job fails with "your account is locked due to a billing
      issue", since 2026-11-05. CI runs nothing until it is fixed. #15 merged on local checks only.
- [ ] Try on a real desktop, which cannot be automated here:
  - [ ] Scroll flicker in `zig build run-text` (only the frames that caused it were tested)
  - [ ] Wayland file drops from Nautilus (needs an element with `on_drop(ExternalPaths)`)
  - [ ] Pinch gestures, which have never fired
  - [ ] Interactive resize under a real window manager
  - [ ] A multi-stroke binding through a real platform; no example binds one yet

## API parity

The goal comes first, before performance. On 2026-11-06, by name, comparing GPUI's public functions with ZUI: **1367 of 1412
functions that should be ported (96.8%)**. Of GPUI's 1642, 230 are set aside below because they should not be ported now: 40 mean nothing in Zig,
131 are debug tooling and accessibility, 51 wait on macOS or Windows, and 8 wait on portal work over D-Bus. Types: every one is sorted below.
A name-only comparison: coincidences flatter it, and it says nothing about behaviour. Port a name or move it, and delete it either way.

<details><summary>Still to port, by GPUI file</summary>

#### window.rs (15)
defer, frame_duration_snapshot, input_latency_snapshot, is_high_rate, native_window_state, paint_surface, record_input, restore_native_window_state, set_exclusive_edge, set_exclusive_zone, set_input_region, set_phase, set_touch_prediction_enabled, set_traffic_light_position, touch_prediction_enabled

#### app.rs (9)
defer, foreground_journal, init_visible, new_inaccessible, register_inspector_element, run_embedded, set_inspector_renderer, start_hang_monitor, test

#### elements/div.rs (4)
external_drag_payload, interactivity, on_a11y_action, on_back_gesture

#### platform.rs (4)
detect, gestures, metadata, stream

#### arena.rs (3)
alloc, begin_scope, end_scope

#### gestures.rs (3)
android, filter, ios

#### elements/text.rs (2)
__hash_text_macro_location_unstable_do_not_use, new_inaccessible

#### subscription.rs (2)
insert_pending, retain

#### app/entity_map.rs (1)
restore_accessed

#### elements/list.rs (1)
set_item_measurement_readiness

#### platform/scap_screen_capture.rs (1)
scap_screen_sources

</details>

<details><summary>Types, sorted</summary>

Still to do, each needing real work: `ExternalDragPayload`, `ExternalDragPayloadSource`, `FileDragPaths` (dragging out of the window); `InputPreference`; `Unbind`; `PowerMode` (UPower over D-Bus, as `gpui_linux/linux/power.rs`); `Popup*` (`xdg_popup`); `ScreenCaptureFrame`, `ScreenCaptureSource`, `ScreenCaptureStream`, `SourceMetadata` (portal screencast); `WindowButton`, `WindowButtonLayout`, `WindowControlArea`, `WindowControls` (xdg-shell v5); `WindowingModes`, `WindowingRequest`; `PlatformKeyboardLayout`, `DummyKeyboardMapper`.

Under another name: `ManagedView`, `DragMoveEvent`, `ExternalPaths`, `PlatformDisplay` (`platform.Display`), `Radians`, `DefaultColors`, `EntityInputHandler`, `ImageStyle`, `ImageCache`, `SharedUri`, `Prompt`, `InteractiveElement`, `StatefulInteractiveElement`, `Text`.

Rust-only, duck typed here: `AppContext`, `AppCell`, `AppRef`, `AppRefMut`, `ActivityGuard`, `ApplicationHandle`, `AsKeystroke`, `Asset`, `BorrowAppContext`, `EventEmitter`, `FutureExt`, `GpuiBorrow`, `Half`, `IsZero`, `Interpolate`, `IntoElement`, `Render`, `RenderOnce`, `ReadGlobal`, `UpdateGlobal`, `Sealed`, `SpringTarget`, `TaskExt`, `Timeout`, `WithTimeout`, `VisualContext`, `View`.

GPUI-private: `Along`, `AnchoredState`, `Arena`, `ArenaBox`, `ArenaClearNeeded`, `AssetLogger`, `BindingIndex`, `ElementClickedState`, `ElementHoverState`, `FontFamilyId`, `GlyphRasterData`, `ImageId`, `ImgLayoutState`, `ImgResourceLoader`, `KeymapVersion`, `MacroActionBuilder`, `MacroActionData`, `OngoingScroll`, `ScrollPhysics`, `RenderImageParams`, `RenderSvgParams`, `TabStopOperation`, `ThreadedDispatcher`, `TooltipId`, `UniformListFrameState`, `InvalidKeystrokeError`.

Debug tooling: `DebugBelow`, `DebugFrameOverlayMode`, `DivInspectorState`, `LeakDetectorSnapshot`, `PlatformScheduler`, the profiler and inspector types. macOS or Windows: `SurfaceSource`, `SystemWindowTab`, `SystemWindowTabController`, `ThermalState`. Not in `gpui_linux` either: the layer shell types.

</details>

<details><summary>Set aside</summary>

**Rust-only:** action_input, apply_to, as_any, as_f32, as_non_zero_u64, borrow, borrow_mut, boxed_clone, bubble, calculate_seeds, capture, clear_accessed, detach_and_log_err_with_backtrace, dispatcher, downcast_mut, end_lease, extend_accessed, generate_list_of_all_registered_actions, handle_created, handle_released, into_element, lease, new_invalid, opaque_strategy, partial_eq, pop_access_scope, push_access_scope, ref_counts_drop_handle, scheduler_executor, source_location, take_accessed, take_dropped, to_bytes, to_f64, to_i32, try_borrow_mut, union, with_timeout

**Waiting on macOS or Windows:** add_recent_document, add_tab, get_key_equivalents, get_next_tab_group_window, get_prev_tab_group_window, insert_window_control_hitbox, is_screen_capture_supported, merge_all_windows, move_tab_to_new_window, on_app_lifecycle, on_memory_warning, on_system_sleep, on_system_wake, on_thermal_state_change, perform_dock_menu_action, prevent_app_nap, prevent_idle_sleep, read_from_find_pasteboard, remove_tab, screen_capture_sources, select_next_tab, select_previous_tab, set_dock_menu, set_document_path, set_text_rendering_mode, set_window_edited, tab_groups, tabs, text_rendering_mode, thermal_state, update_jump_list, update_last_active, update_tab_position, update_tab_title, window_control_area, write_to_find_pasteboard

**Waiting on portal work over D-Bus:** delete_credentials, read_credentials, write_credentials, write_credentials_if_not_exists

**Debug tooling and accessibility** (each its own project): the profiler, inspector, bench and randomized tree harnesses, `aria_*` and `a11y_*`.

</details>

## API present in name only

These exist, so the comparison counts them, but they do nothing yet.

- [ ] `set_active_node` is not used by prepaint
- [ ] `insets()` is always zero, so `fully_visible_bounds` equals the viewport
- [ ] `KeyBinding.keystrokes` is still plain `Keystroke`, so `KeybindingKeystroke` does not affect bindings
- [ ] `ActivationPolicy` is stored only; `on_reopen` never fires on Linux, as in GPUI
- [ ] Long press: no platform emits it, so it has only run with simulated events
- [ ] `last_input_was_touch` works, but raw touch events are not dispatched to elements
- [ ] `transact` does not roll back dispatch-tree nodes or accessed element states, which GPUI's does

## Missing, needing real work

- [ ] `refresh_interval` is whole milliseconds on X11, and has not been checked against a real monitor's rate. `inner_window_bounds` ignores tiling
- [ ] A cancelled foreground task run through `run_pending` was seen leaking its `TaskState` (`executor.zig:154`) under the leak checker. Not chased, and not reproduced by a test yet
- [ ] Multi-monitor: X11 has one display per RandR CRTC, unlike GPUI's one per X screen. Run on two virtual monitors: both reported, windows opened on each. Never run on real monitors, or with monitors changing while running
- [ ] `has_image_atlas_entry` has only been tested with an empty image
- [ ] `visible_bounds` is the full bounds, as in every GPUI Linux backend: no work area is read
- [ ] Transparency on a real compositor: alpha was read from pixels and protocol, never seen blended. Blur has never run: mutter offers no `ext_background_effect_manager_v1`
- [ ] Test scheduler: `once`, `many`, `assert_correct_thread`, `blocked_sessions`, `spawn_dedicated`, `spawn_realtime`, `next_notification`. Asset and remote image tests stay on real workers
- [ ] Screen capture (portal), `focus_lost_restore_target` beyond the current path
- [ ] App menu callbacks are stored and registered, but nothing on Linux calls them, as in GPUI's Linux backend. They wait for macOS
- [ ] Popups: grabs and outside-click dismissal have not run with a real pointer; `xdg_popup.reposition` is not ported
- [ ] Power mode has only run against a fake bus; a daemon that never answers leaves it at its last value
- [ ] Action schemas have no field descriptions, since Zig keeps no doc comments

## Images

- [ ] First load of a URL takes about 1 to 2 s. It now matches curl (0.87 to 1.12 s and 1.27 to 1.92 s,
      against curl's 0.87 to 0.98 s and 1.36 to 1.42 s) in Debug too, so what is left is the network. Repeat
      loads are fast through the disk cache. To make it feel faster:
  - [ ] `prefetch(url)`, so an app can start loading before the image is on screen
  - [ ] HTTP/2, or honoring `Cache-Control` and `ETag`, so a fresh entry needs no download at all
  - Tried, and no better: 6 connections per host, as browsers do, made a 60-image `image_gallery` finish
    later (4.8 to 5.6 s against 2.9 to 5.0 s), since `picsum.photos` spends its time generating images. A shared
    client with no cap is within noise (median 3.6 s against 4.0 s, runs from 2.3 to 9.7 s). Not worth doing:
    reserving space (size is only known about 0.1 s before the image) and remembering redirects (it only
    speeds the background refresh)
- [ ] Load local files and embedded assets in the background, as GPUI does
- [ ] Size limit on a download; today a huge response is read whole into memory
- [ ] `retain_all(id)`; URLs in an `ImageCacheItem` skip the disk copy and do not share entries with `AssetCache`
- [ ] Removing a path from the default `AssetCache`; `image_loading`'s image 4 has no click handler without it
- [ ] Quitting waits for a `use_asset` load that never checks `LoadContext.is_cancelled`
- [ ] Atlas and memory behaviour over many image changes, such as repeated "Next Photos", is unmeasured
- [ ] `testing`: `test_allow_parking` is not ported, since ZUI has no parking check
- [ ] Flaky test? `remove_asset` failed once in a run that touched no asset code; not reproduced
- [ ] `run_until_parked` never parks while a GIF is on screen, and spins to its 10,000-iteration guard
- [ ] TIFF and ICO decoders. HDR, PSD and PIC went away with `stb_image`; AVIF and EXR were never here
- [ ] Wuffs is pinned to `0.4.0-alpha.12`, since the stable 0.3 has no WebP or JPEG. Move to 0.4 when it is released
- [ ] Coverage-guided fuzzing of `src/wuffs.zig`'s chunk walker and compositors; today it is 400 fixed-seed corruptions per fixture
- [ ] An animation over `Limits.max_total_bytes` (1 GiB of frames) fails outright, where it could play what fits
- [ ] EXIF orientation in PNG (JPEG is done)
- [ ] GPUI's delay before `with_loading` appears, so fast loads do not flash a placeholder
- [ ] Atlas tiles of images replaced by a newer download are never freed
- [ ] Disk cache evicts oldest written, not least recently used
- [ ] `RemoteImages` and disk cache behaviour on Windows and macOS is compiled, never run

## Platforms

- [ ] macOS (Metal), reference `gpui_macos`. Use `d01f125`'s key equivalents for backspace and delete
- [ ] Windows (D3D12, Vulkan fallback), reference `gpui_windows`. GPUI composites COLR on the CPU since `4a6121b`
- [ ] GL / GLES fallback
- [ ] Web (WebGPU), reference `gpui_web`
- [ ] Link libobjc on macOS: `zig build check` only analyzes the tests there, without linking

## GPU renderer

- [ ] Subpixel sprites (dual-source blending); nothing emits them yet
- [ ] Platform surfaces
- [ ] Device-lost recovery; a failed frame only logs and retries
- [ ] Run under the Khronos validation layer, which has never happened

## Elements and input

- [ ] Back-gesture listeners; no platform emits pressure yet (macOS will)
- [ ] Long-press tooltips
- [ ] External drag payloads (dragging out of the window)
- [ ] `ContainerQuery` is a styled element with an id and interactivity, which GPUI's is not; `Percentage`
      arithmetic and a `Radians` type are not ported
- [ ] `set_menus` is stored but only macOS will draw it
- [ ] Notifications on the real GNOME Shell: only a fake server has been tested. A server that never answers leaves
      that tag waiting forever (no timeout). The first post connects synchronously, blocking for up to 1 s
- [ ] Try file dialogs, dark mode following the desktop and `open_url` on a real desktop: tests use a fake portal
- [ ] File dialogs have no parent window: `wayland:<handle>` via xdg_foreign, or `x11:<xid>`
- [ ] Credentials: a Secret Service client on `dbus.zig` (OpenSession, SearchItems, CreateItem, GetSecret, Prompt), about 600 lines
- [ ] `reveal_path`'s OpenDirectory portal: file descriptors over D-Bus (`h`, UNIX_FDS, SCM_RIGHTS). The launcher fallback works
- [ ] Portal cursor size ignores the window scale; `file_uri_to_path` does not normalise `.` and `..`
- [ ] Wayland keyboard layout has not run with a real keyboard: a headless compositor has none
- [ ] Scroll: ZUI stops propagation in the scroll listener and GPUI does not, so nested scrollers differ
- [ ] `Unbind` (needs GPUI's binding precedence model), `InputPreference`, pausing the pending-input timeout
- [ ] `keyboard_layout` and its change observer
- [ ] `delete_surrounding_text`; we never send surrounding text
- [ ] Linux: `xdg_activation`
- [ ] `on_window_closed`; `painting` skips it (the app already quits on the last window)
- [ ] Hover `text_color` does not change text: `anchor` draws black on black when hovered. Runs are
      captured at layout with the non-hover style, and GPUI seems to do the same; check against a
      real GPUI build
- [ ] `data_table`: the visible-range text and scrollbar thumb lag a frame behind a wheel scroll;
      check against GPUI, and try dragging the thumb, which has never been exercised
- [ ] X11: drop lists sent with INCR are refused
- [ ] Entities in a replayed action can outlive a keymap that an action cleared

## Paths

- [ ] **Fill self-intersecting paths**: the ear-clipping in `path_builder.zig` drops them, so `painting`
      has no lightning bolt. Lyon fills them; a general tessellator is needed
- [ ] `painting`'s Rust logo needs lyon's path data, about 800 lines
- [ ] `painting` has only run on the CPU renderer

## Text

- [ ] Bug: Twemoji, a non-color font, rasterizes about 4.6x too big (76x72 for a heart at 16px). The cause is not
      isolated. `U+FE0E` handling skips faces named `*emoji*` to avoid it, which is a heuristic
- [ ] `InteractiveText::tooltip`: needs the tooltip state machine extracted from `elements/div.zig`
- [ ] GPUI's `LineWrapper` emergency-wrap and truncation tests, and `force width multiple combining marks`, not ported
- [ ] cozmic `-Dsystem-libs` builds have no COLRv1, since hb-raster is a separate shared library

## Examples still to port

Each must run headless with a correct snapshot, and be driven for real: first frames hide most bugs.

- [ ] layer_shell, a11y

## Performance (after API parity)

- On hold: the owner wants the API finished first, with naive implementations, and performance after.
- Benchmark: `zig build run-frame_bench -Doptimize=ReleaseFast -j1`, isolated. It times `Window.draw` on the headless
  platform, so no renderer or display counts. On a Ryzen 5 5625U, 2026-11-07, median per frame:
  20 views of 60 rows 10.6 ms uncached, 0.72 ms cached with none dirty, 1.5 ms cached with one dirty; 10k quads 36 ms; 2000 lines 5.8 ms.
- Profile: `perf` needs a kernel setting, so use callgrind. Build with `-Dcpu=x86_64`, because valgrind rejects native instructions, and pass
  `--toggle-collect='window.Window.draw'`, or font startup swamps it. Before the first fixes, of instructions in `draw`:
  `BoundsTree.insert` about 20%, `memcpy` 13% (`compute_style` 3%, element building 2%), layout in zafi most of the rest. Re-profile: the fixes below changed this.
  - Done: tree nodes are no longer copied while searching, and their indices are u32. An element refines its base style once, and paint recomputes style only if it has hover or drag styles.
- [ ] Find what still costs in `BoundsTree.insert`, and why `10k quads` costs about 3.6 us per element
- [ ] `Interactivity` and `Style` are large and copied per element: size them, and shrink what is usually empty
- [ ] Compare view caching with GPUI in a release build. GPUI itself has not been built here
- [ ] Run a cached view on a real Wayland and X11 window; no example uses `cached` yet
- [ ] Tooltip and throttled animation timers refresh the whole window, because no view is current in a timer. They could remember theirs
- [ ] Avoid full layout when nothing changed
- [ ] X11 XShm presentation
- [ ] SIMD gradients in the CPU renderer
- [ ] Benchmarks against GPUI
- [ ] `paths_bench` has no numbers: a Debug build drew no first frame in 25 s on the CPU renderer. Measure
      it in release, on the GPU too, since 2000 path stars that slow may be a real problem

### Left naive on purpose (the owner asked for the API first)

Each is also said in a comment where it is written.

- [ ] `Window.simulate_next_frame` copies the callback list; it could take the list
- [ ] X11 `displays()` rebuilds its array on every call; it could rebuild only when RandR reports a change
- [ ] X11 `display_id_at` scans the CRTCs linearly, which is fine for the monitors a desktop has
- [ ] X11 `refresh_crtcs` asks for every output's name on every RandR event; it could ask only when the outputs change
- [ ] `uuid_v5` runs SHA-1 per call; cache per output if it ever shows up in a profile
- [ ] `OwnedWindowingRequest.dupe` allocates per request; a platform-owned buffer would do
- [ ] A headless Linux platform paces frames with a fixed 16 ms timer, not a frame clock
- [ ] `replace_backend` tears down and reconnects on every mode switch; it could keep an unused connection alive
- [ ] `HeadlessPlatform.draw_requested_frames` and `frames_pending` walk every window on every pump; a list of windows asking for frames would do

## Project

- [ ] `dev` into `main`, source only (`AGENTS.md` §1.5)
- [ ] `AGENTS.md` §2 status table is older than the work since; refresh it
