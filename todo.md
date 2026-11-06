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

The goal comes first, before performance. On 2026-11-06, by name, comparing GPUI's public functions with ZUI: **1254 of 1413
functions that should be ported (88.7%)**. Of GPUI's 1642, 229 are set aside below because they should not be ported now: 35 mean nothing in Zig,
135 are debug tooling and accessibility, 51 wait on macOS or Windows, and 8 wait on portal work over D-Bus. Types: 271 of 458, not sorted yet.
A name-only comparison: coincidences flatter it, and it says nothing about behaviour. Port a name or move it, and delete it either way.

<details><summary>Still to port, by GPUI file</summary>

#### window.rs (44)
default_prevented, defer, focus_lost_restore_target, frame_duration_snapshot, has_image_atlas_entry, input_latency_snapshot, invalidate_view, is_high_rate, is_minimizable, is_resizable, is_simple_fullscreen, native_window_state, not_drawing, paint_surface, painted_quads, painted_underlines, present_if_needed, record_input, refresh_interval, replace_views, restore_native_window_state, set_background_appearance, set_client_corner_radii, set_dirty, set_document_path, set_exclusive_edge, set_exclusive_zone, set_input_region, set_phase, set_platform_waker, set_scale_factor, set_touch_prediction_enabled, set_traffic_light_position, set_window_edited, simulate_next_frame, take_views, touch_prediction_enabled, underline_bounds, update_count, viewport_size, wake_platform, window_controls, with_optional_element_state, with_tab_group

#### app.rs (25)
action_deprecation_messages, action_documentation, action_schema_by_name, action_schemas, asset_source, defer, deprecated_actions_to_preferred_actions, foreground_journal, get_name, init_visible, is_test, new_inaccessible, read_from_clipboard_async, reduce_motion, register_inspector_element, request_windowing, run_embedded, set_inspector_renderer, set_text_rendering_mode, start_hang_monitor, test, text_rendering_mode, update_last_active, with_platform, with_windowing

#### platform.rs (18)
default_bounds, detect, gestures, linux_default, metadata, on_app_menu_action, on_displays_changed, on_power_mode_change, on_validate_app_menu_command, on_will_open_app_menu, read_from_clipboard_async, refresh_interval, refresh_interval_from_hz, request_windowing, set_initial_windowing, stream, uuid, visible_bounds

#### executor.rs (10)
advance_clock, allow_parking, block_test, forbid_parking, is_test, rng, set_block_on_ticks, set_num_cpus, simulate_random_delay, tick

#### action.rs (9)
action_json_schema, action_schema_by_name, action_schemas, deprecated_aliases, deprecation_message, deprecation_messages, documentation, generate_list_of_all_registered_actions, is_unbind

#### elements/div.rs (4)
external_drag_payload, interactivity, on_a11y_action, on_back_gesture

#### arena.rs (3)
alloc, begin_scope, end_scope

#### elements/animation.rs (3)
map_element, repeat_synced, with_max_fps

#### gestures.rs (3)
android, filter, ios

#### key_dispatch.rs (3)
contains_focus, refresh_node_id, reuse_subtree

#### style.rs (3)
blur_radius, combine_highlights, spread_radius

#### tab_stop.rs (3)
begin_group, end_group, paint_index

#### text_system/line_layout.rs (3)
layout_index, reuse_layouts, truncate_layouts

#### color.rs (2)
color_space, opaque_strategy

#### colors.rs (2)
for_appearance, get_global

#### elements/img.rs (2)
image_style, is_asset_cached

#### elements/text.rs (2)
__hash_text_macro_location_unstable_do_not_use, new_inaccessible

#### keymap/binding.rs (2)
action_input, meta

#### path_builder.rs (2)
dash_array, transform

#### subscription.rs (2)
insert_pending, retain

#### app/async_context.rs (1)
is_test

#### app/entity_map.rs (1)
restore_accessed

#### elements/anchored.rs (1)
attach

#### elements/deferred.rs (1)
with_priority

#### elements/image_cache.rs (1)
retain_all

#### elements/list.rs (1)
set_item_measurement_readiness

#### keymap/context.rs (1)
new_with_defaults

#### platform/app_menu.rs (1)
separator

#### platform/keyboard.rs (1)
get_key_equivalents

#### platform/scap_screen_capture.rs (1)
scap_screen_sources

#### seeds.rs (1)
calculate_seeds

#### svg_renderer.rs (1)
render_parsed

#### text_system/line_wrapper.rs (1)
len_utf8

#### util.rs (1)
with_timeout

</details>

<details><summary>Types not found in ZUI</summary>

ActivityGuard, Along, AnchoredState, AnyTooltip, AnyWeakView, AppCell, AppContext, AppRef, AppRefMut, ApplicationHandle, Arena, ArenaBox, ArenaClearNeeded, AsKeystroke, Asset, AssetLogger, BindingIndex, BorrowAppContext, DebugBelow, DebugFrameOverlayMode, DefaultColors, DivInspectorState, DummyKeyboardMapper, ElementClickedState, ElementHoverState, EmptyView, EntityInputHandler, EventEmitter, ExternalDragPayload, ExternalDragPayloadSource, FileDragPaths, Focusable, FontFamilyId, FutureExt, GestureEvent, GestureTuning, GlyphRasterData, GpuiBorrow, Half, ImageCache, ImageCacheElement, ImageId, ImageStyle, ImgLayoutState, ImgResourceLoader, InputEvent, InputPreference, InteractiveElement, Interpolate, IntoElement, InvalidKeystrokeError, IsZero, KeyEvent, KeyboardInteractivity, KeymapVersion, Layer, LayerShellNotSupportedError, LayerShellOptions, LeakDetectorSnapshot, MacroActionBuilder, MacroActionData, ManagedView, MissingGlyphSink, MouseEvent, OngoingScroll, OwnedOsMenu, PathVertex_ScaledPixels, PlatformDisplay, PlatformKeyboardLayout, PlatformKeyboardMapper, PlatformScheduler, PopupAnchor, PopupConstraintAdjustment, PopupGravity, PopupNotSupportedError, PopupOptions, PowerMode, Prompt, Radians, ReadGlobal, Render, RenderImageParams, RenderOnce, RenderSvgParams, RetainAllImageCacheProvider, ScreenCaptureFrame, ScreenCaptureSource, ScreenCaptureStream, ScrollPhysics, Sealed, SharedUri, SourceMetadata, SpringTarget, StatefulInteractiveElement, StyledImage, SurfaceSource, SystemWindowTab, SystemWindowTabController, TabStopCount, TabStopOperation, TabStopOrderNodeSummary, TaskExt, Text, ThermalState, ThreadedDispatcher, Timeout, TooltipId, Unbind, UniformListFrameState, UpdateGlobal, View, VisualContext, WindowButton, WindowButtonLayout, WindowControlArea, WindowControls, WindowingModes, WindowingRequest, WithTimeout

</details>

<details><summary>Set aside</summary>

**Rust-only:** apply_to, as_any, as_f32, as_non_zero_u64, borrow, borrow_mut, boxed_clone, bubble, capture, clear_accessed, detach_and_log_err_with_backtrace, dispatcher, downcast_mut, end_lease, extend_accessed, handle_created, handle_released, into_element, lease, new_invalid, partial_eq, pop_access_scope, push_access_scope, ref_counts_drop_handle, scheduler_executor, source_location, take_accessed, take_dropped, to_bytes, to_f64, to_i32, try_borrow_mut, union

**Waiting on macOS or Windows:** add_recent_document, add_tab, button_layout, get_next_tab_group_window, get_prev_tab_group_window, insert_window_control_hitbox, is_screen_capture_supported, merge_all_windows, move_tab_to_new_window, observe_button_layout_changed, on_app_lifecycle, on_memory_warning, on_system_sleep, on_system_wake, on_thermal_state_change, perform_dock_menu_action, power_mode, prevent_app_nap, prevent_idle_sleep, read_from_find_pasteboard, remove_tab, screen_capture_sources, select_next_tab, select_previous_tab, set_dock_menu, tab_groups, tabs, thermal_state, update_jump_list, update_tab_position, update_tab_title, window_control_area, write_to_find_pasteboard

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
- [ ] Refresh rate: `refresh_interval`, `is_high_rate`. `window_controls` needs xdg-shell v5. `set_background_appearance` needs
      alpha buffers. `set_client_corner_radii` is stored nowhere. `inner_window_bounds` ignores tiling
- [ ] `_NET_WM_STATE` and Wayland `set_app_id`, `request_decorations` have not run on a real window manager or compositor

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
- [ ] `cached` views
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

- [ ] toggle_headless: needs switching windowing modes at runtime (`request_windowing`)
- [ ] layer_shell, a11y

## Performance (after API parity)

- [ ] View caching with `AnyView::cached` and replayed scene ranges (`Scene.replay` exists)
- [ ] Avoid full layout when nothing changed
- [ ] X11 XShm presentation
- [ ] SIMD gradients in the CPU renderer
- [ ] Benchmarks against GPUI
- [ ] `paths_bench` has no numbers: a Debug build drew no first frame in 25 s on the CPU renderer. Measure
      it in release, on the GPU too, since 2000 path stars that slow may be a real problem

## Project

- [ ] `dev` into `main`, source only (`AGENTS.md` §1.5)
- [ ] `AGENTS.md` §2 status table is older than the work since; refresh it
