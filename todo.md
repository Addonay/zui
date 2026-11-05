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

The goal comes first, before performance. On 2026-11-06, by name: **1007 of 1642 functions (61%) and 245 of 458
types (53.5%)**. A name-only comparison: coincidences flatter it, and Rust-only names and macros distort it the
other way. Generated `Styled` methods are not counted. Sort the list below as it is worked through: port
it, or note why it stays out (Rust-only, or waiting on a platform), and delete it either way.

<details><summary>GPUI names not found in ZUI</summary>

#### action.rs (12 of 19 functions missing)
action_json_schema, action_schema_by_name, action_schemas, as_any, boxed_clone, deprecated_aliases, deprecation_message, deprecation_messages, documentation, generate_list_of_all_registered_actions, is_unbind, partial_eq
types: MacroActionBuilder, MacroActionData, Unbind

#### app.rs (112 of 181 functions missing)
action_deprecation_messages, action_documentation, action_schema_by_name, action_schemas, add_recent_document, add_tab, all_bindings_for_input, app_path, assert_no_new_leaks, asset_source, borrow, borrow_mut, button_layout, can_select_mixed_files_and_dirs, clear_globals, compositor_name, cursor_hide_mode, defer, delete_credentials, deprecated_actions_to_preferred_actions, find_display, foreground_journal, get_name, get_next_tab_group_window, get_prev_tab_group_window, global_mut, graphical_environment, hide_other_apps, init_visible, is_cursor_visible, is_screen_capture_supported, is_test, is_visible, key_bindings, keyboard_layout, keyboard_mapper, leak_detector_snapshot, merge_all_windows, move_tab_to_new_window, new_inaccessible, observe_displays, observe_new, observe_release, observe_release_in, on_app_lifecycle, on_app_quit, on_app_restart, on_keyboard_layout_change, on_memory_warning, on_missing_glyphs, on_reopen, on_system_sleep, on_system_wake, on_thermal_state_change, open_with_system, path_for_auxiliary_executable, perform_dock_menu_action, platform_info, power_mode, prevent_idle_sleep, prompt_for_new_path, prompt_for_paths, propagate, read_credentials, read_from_clipboard_async, read_from_find_pasteboard, reduce_motion, ref_counts_drop_handle, register_inspector_element, register_url_scheme, remove_tab, request_windowing, reveal_path, run_embedded, screen_capture_sources, select_next_tab, select_previous_tab, set_activation_policy, set_cursor_hide_mode, set_dock_menu, set_http_client, set_inspector_renderer, set_quit_mode, set_restart_path, set_text_rendering_mode, set_visible, set_window_appearance, should_auto_hide_scrollbars, shutdown, spawn_with_priority, start_hang_monitor, tab_groups, tabs, test, text_rendering_mode, thermal_state, try_borrow_mut, unhide_other_apps, update_jump_list, update_last_active, update_tab_position, update_tab_title, window_appearance, window_stack, with_platform, with_quit_mode, with_restart_arguments, with_window, with_windowing, write_credentials, write_credentials_if_not_exists, write_to_find_pasteboard
types: AnyTooltip, AppCell, AppRef, AppRefMut, ApplicationHandle, CursorHideMode, ExternalDragPayloadSource, GpuiBorrow, InputPreference, QuitMode, SystemWindowTab, SystemWindowTabController

#### app/async_context.rs (5 of 18 functions missing)
is_test, read_default_global, read_global, try_read_global, update_root
types: AsyncWindowContext

#### app/bench_context.rs (6 of 6 functions missing)
bench_platform, foreground_work, metrics, print, with_fps, with_frame_budget_nanos
types: BenchReport, ForegroundWorkSummary

#### app/context.rs (22 of 43 functions missing)
defer_in, focus_self, focus_view, observe_button_layout_changed, observe_global_in, observe_in, observe_release, observe_release_in, observe_self, observe_window_display, observe_window_visibility, on_app_quit, on_app_restart, on_blur, on_focus, on_focus_in, on_focus_lost, on_focus_out, on_release_in, spawn_in, spawn_in_with_priority, subscribe_self

#### app/entity_map.rs (19 of 35 functions missing)
as_non_zero_u64, assert_no_new_leaks, assert_released, clear_accessed, end_lease, entity_type, extend_accessed, handle_created, handle_released, is_upgradable, leak_detector_snapshot, lease, new_invalid, pop_access_scope, push_access_scope, ref_counts_drop_handle, restore_accessed, take_accessed, take_dropped
types: AnyWeakEntity, LeakDetectorSnapshot

#### app/headless_app_context.rs (7 of 14 functions missing)
advance_clock, allow_parking, capture_screenshot, forbid_parking, update_window, with_asset_source, with_platform
types: HeadlessAppContext

#### arena.rs (3 of 7 functions missing)
alloc, begin_scope, end_scope
types: Arena, ArenaBox

#### color.rs (2 of 29 functions missing)
color_space, opaque_strategy

#### colors.rs (2 of 5 functions missing)
for_appearance, get_global
types: DefaultColors

#### element.rs (6 of 19 functions missing)
a11y_role, a11y_synthetic_children, downcast_mut, into_element, source_location, write_a11y_info
types: IntoElement, Render, RenderOnce

#### elements/anchored.rs (1 of 8 functions missing)
attach
types: AnchoredState

#### elements/animation.rs (3 of 15 functions missing)
map_element, repeat_synced, with_max_fps

#### elements/deferred.rs (1 of 3 functions missing)
with_priority

#### elements/div.rs (48 of 122 functions missing)
a11y_synthetic_children, accessibility_id, anchor_scroll, aria_active_descendant, aria_column_count, aria_column_index, aria_description, aria_expanded, aria_keyshortcuts, aria_label, aria_level, aria_max_numeric_value, aria_min_numeric_value, aria_numeric_value, aria_numeric_value_step, aria_orientation, aria_placeholder, aria_position_in_set, aria_row_count, aria_row_index, aria_selected, aria_size_of_set, aria_toggled, aria_value, bottom_item, debug_selector, dragged_item, external_drag_payload, for_handle, hover_listener_mode, interactivity, logical_scroll_bottom, occlude_mouse, on_a11y_action, on_back_gesture, on_boxed_action, on_children_prepainted, on_drag_move, on_file_drop_exit, on_mouse_exit, on_scroll, restrict_scroll_to_axis, role, scroll_to_top_of_item, source_location, top_item, window_control_area, with_dynamic_prepaint_order
types: DivInspectorState, DragMoveEvent, ElementClickedState, ElementHoverState, HoverListenerMode, InteractiveElement, StatefulInteractiveElement

#### elements/image_cache.rs (1 of 11 functions missing)
retain_all
types: ImageCache, ImageCacheElement, RetainAllImageCacheProvider

#### elements/img.rs (2 of 10 functions missing)
image_style, is_asset_cached
types: ImageStyle, ImgLayoutState, ImgResourceLoader, StyledImage

#### elements/list.rs (6 of 33 functions missing)
is_scrollbar_dragging, scrollbar_drag_ended, scrollbar_drag_started, set_item_measurement_readiness, set_offset_from_scrollbar, splice_focusable

#### elements/text.rs (3 of 24 functions missing)
__hash_text_macro_location_unstable_do_not_use, line_layouts, new_inaccessible
types: Text

#### elements/uniform_list.rs (1 of 17 functions missing)
logical_scroll_top_index
types: UniformListFrameState

#### executor.rs (24 of 30 functions missing)
advance_clock, allow_parking, block_on, block_test, block_with_timeout, detach_and_log_err, detach_and_log_err_with_backtrace, dispatcher, forbid_parking, idle_time_remaining, is_main_thread, is_test, prevent_app_nap, rng, scheduler_executor, scoped, scoped_priority, set_block_on_ticks, set_num_cpus, simulate_random_delay, spawn_when_idle, spawn_with_priority, tick, to_send
types: Scope, SendForegroundExecutor, TaskExt

#### geometry.rs (9 of 78 functions missing)
as_f32, ceil, floor, pow, round, to_bytes, to_f64, to_i32, union
types: Along, Half, IsZero, Radians

#### gestures.rs (3 of 3 functions missing)
android, filter, ios
types: GestureTuning, OngoingScroll, ScrollPhysics

#### gpui.rs (9 of 20 functions missing)
background_spawn, new_window_entity, read_global, read_window, replace_root_view, update_default_global, update_window, update_window_entity, with_window
types: AppContext, BorrowAppContext, EventEmitter, GpuSpecs, Sealed, VisualContext

#### input.rs (6 of 16 functions missing)
paste, selection_bounds_for_range, set_selected_text_range, text_input_configuration, text_input_editable_range, text_length_utf16
types: EntityInputHandler

#### inspector.rs (5 of 6 functions missing)
active_element_id, invoke, is_picking, render_inspector_states, start_picking
types: FunctionReflection, Inspector, InspectorElementId, InspectorElementPath, InspectorRenderer

#### key_dispatch.rs (12 of 31 functions missing)
available_actions, contains_focus, focus_path, focusable_node_id, highest_precedence_binding_for_action, possible_next_bindings_for_input, refresh_node_id, reuse_subtree, root_node_id, set_active_node, set_view_id, view_path_reversed

#### keymap.rs (3 of 9 functions missing)
all_bindings_for_input, possible_next_bindings_for_input, version
types: BindingIndex, KeymapVersion

#### keymap/binding.rs (6 of 10 functions missing)
action_input, keystrokes, meta, predicate, set_meta, with_meta
types: KeyBindingMetaIndex

#### keymap/context.rs (1 of 15 functions missing)
new_with_defaults

#### path_builder.rs (2 of 18 functions missing)
dash_array, transform

#### platform.rs (67 of 97 functions missing)
add_recent_document, app_path, apply_to, button_layout, can_select_mixed_files_and_dirs, compositor_name, default_bounds, delete_credentials, detect, gestures, graphical_environment, guess_compositor, hide_cursor_until_mouse_moves, hide_other_apps, is_cursor_visible, is_screen_capture_supported, is_visible, keyboard_layout, keyboard_mapper, linux_default, metadata, on_app_lifecycle, on_app_menu_action, on_displays_changed, on_keyboard_layout_change, on_memory_warning, on_power_mode_change, on_quit, on_reopen, on_system_sleep, on_system_wake, on_thermal_state_change, on_validate_app_menu_command, on_will_open_app_menu, open_with_system, path_for_auxiliary_executable, perform_dock_menu_action, platform_info, power_mode, prevent_idle_sleep, prompt_for_new_path, prompt_for_paths, read_credentials, read_from_clipboard_async, read_from_find_pasteboard, refresh_interval, refresh_interval_from_hz, register_url_scheme, request_windowing, reveal_path, screen_capture_sources, set_activation_policy, set_dock_menu, set_initial_windowing, set_window_appearance, should_auto_hide_scrollbars, stream, thermal_state, unhide_other_apps, update_jump_list, uuid, visible_bounds, window_appearance, window_stack, write_credentials, write_credentials_if_not_exists, write_to_find_pasteboard
types: ActivationPolicy, ActivityGuard, DisplayChanges, DisplayEvent, GraphicalEnvironment, PlatformDisplay, PowerMode, ScreenCaptureFrame, ScreenCaptureSource, ScreenCaptureStream, SourceMetadata, ThermalState, WindowButton, WindowButtonLayout, WindowControls, WindowVisibility, WindowingModes, WindowingRequest

#### platform/app_menu.rs (1 of 12 functions missing)
separator
types: OwnedOsMenu

#### platform/keyboard.rs (2 of 4 functions missing)
get_key_equivalents, map_key_equivalent
types: DummyKeyboardMapper, PlatformKeyboardLayout, PlatformKeyboardMapper

#### platform/keystroke.rs (7 of 33 functions missing)
as_keystroke, from_keystroke, new_with_mapper, remove_key_char, set_key, set_modifiers, with_simulated_ime
types: AsKeystroke, InvalidKeystrokeError, KeybindingKeystroke

#### platform/platform_info.rs (1 of 1 functions missing)
is_mac
types: PlatformInfo, PlatformTarget

#### platform/scap_screen_capture.rs (1 of 1 functions missing)
scap_screen_sources

#### profiler.rs (39 of 45 functions missing)
as_str, begin_action_handler, begin_draw, begin_input, begin_view, budget, collect_and_reset, collect_unseen, convert, dirty_to_draw_duration, draw_duration, end_action_handler, end_draw, end_input, end_view, frame_duration_snapshot, get_all_timings, get_current_thread_task_timings, get_current_thread_timings, get_thread_task_timings, histogram_bucket_counts, input_latency_snapshot, is_late, missed_refreshes, poll_duration, present_duration, record_draw_phases, record_frame_event, record_frame_signal, record_present, save_task_timing, set_refresh_interval, set_trace_enabled, since, startup_time, take_all_stats, trace_enabled, update_running_task, work_start
types: ActiveTiming, DrawPhases, FrameDurationSnapshot, FrameEvent, FrameTiming, FrameTimingCollector, GlobalThreadTimings, GuardedTaskTimings, InputLatencySnapshot, PresentTiming, ProfilingCollector, RefreshIntervalFrames, SerializedLocation, SerializedTaskTiming, SerializedThreadTaskTimings, TaskStatistics, TaskTiming, ThreadTaskStatistics, ThreadTaskTimings, ThreadTimings, ThreadTimingsDelta, ViewPhase, ViewTiming, WindowProfiler, YieldTime

#### profiler/actions.rs (5 of 8 functions missing)
longest_runtimes, runtime, save_action_timing, take_action_stats, update_running_action
types: ActionStatistics, ActionTiming

#### profiler/hang.rs (6 of 8 functions missing)
as_str, convert, detect, first_present_at, poll, take_active_time
types: HangDetector, HangIncident, HangTrigger, SerializedHangContributor, SerializedHangIncident

#### profiler/journal.rs (9 of 10 functions missing)
busy_fraction, dirty_at, dirty_to_present_duration, end_time, interval_end, occupancy, occupancy_within, small_poll_summary, start_time
types: ForegroundEvent, ForegroundJournalEntry, FrameSkipReason, FrameSkipped, FrameSnapshot, FrameStateChange, InputTiming, IntervalBoundary, PlatformSignal, PollSummary, PresentedFrame, SmallPollFlush

#### queue.rs (5 of 9 functions missing)
iter, spin_send, spin_try_pop, try_iter, try_pop
types: Iter, PriorityQueueReceiver, PriorityQueueSender, RecvError, SendError, TryIter

#### randomized_element_tree.rs (13 of 15 functions missing)
element_count, entity_density, handler_density, is_tall, sample, topology, with_animation_density, with_cached_views, with_entity_density, with_handler_density, with_hover_styles, with_topologies, with_topology
types: RandomizedElementTreeAction, RandomizedElementTreeBounds, RandomizedElementTreeConfig, RandomizedElementTreeTopology, RandomizedElementTreeWorkCounters

#### seeds.rs (1 of 1 functions missing)
calculate_seeds

#### style.rs (3 of 16 functions missing)
blur_radius, combine_highlights, spread_radius
types: DebugBelow

#### subscription.rs (3 of 7 functions missing)
insert_pending, join, retain

#### svg_renderer.rs (1 of 4 functions missing)
render_parsed
types: RenderSvgParams

#### tab_stop.rs (3 of 8 functions missing)
begin_group, end_group, paint_index
types: TabStopCount, TabStopOperation, TabStopOrderNodeSummary

#### text_system.rs (3 of 7 functions missing)
font_class, grapheme, report
types: FallbackFontClass, FontFamilyId, MissingGlyph, MissingGlyphSink

#### text_system/line.rs (5 of 10 functions missing)
paint_with_underline_handler, split_at, take_until, with_len, x_offset
types: GlyphRasterData, ShapedLineCursor

#### text_system/line_layout.rs (5 of 23 functions missing)
layout_index, reuse_layouts, split_at, truncate_layouts, wrap_boundaries

#### text_system/line_wrapper.rs (1 of 7 functions missing)
len_utf8

#### util.rs (1 of 6 functions missing)
with_timeout
types: FutureExt, Timeout, WithTimeout

#### view.rs (1 of 8 functions missing)
entity_type
types: AnyWeakView, EmptyView, View

#### window.rs (108 of 215 functions missing)
bubble, capslock, capture, capture_long_press, captured_hitbox, client_inset, cycle_debug_frame_overlay_mode, debug_assert_paint, debug_assert_paint_or_prepaint, debug_assert_prepaint, debug_frame_overlay_mode, default_prevented, defer, dismiss_virtual_keyboard, focus_lost_restore_target, frame_duration_snapshot, fully_visible_bounds, has_image_atlas_entry, has_long_press_capture, inner_window_bounds, input_latency_snapshot, insert_window_control_hitbox, insets, invalidate_view, is_action_available_in, is_focus_in, is_focus_out, is_fullscreen, is_high_rate, is_hovered_at, is_maximized, is_minimizable, is_paused, is_resizable, is_simple_fullscreen, is_visible, keystroke_text_for, keystrokes, last_input_was_keyboard, last_input_was_touch, native_window_state, not_drawing, observe_button_layout_changed, observe_release, observe_window_display, observe_window_visibility, on_focus_in, on_focus_out, paint_drop_shadows, paint_image, paint_inset_shadows, paint_surface, paint_svg, paint_underline_with_exclusions, painted_quads, painted_underlines, pixel_snap, pixel_snap_bounds, pixel_snap_f64, pixel_snap_point, present_if_needed, record_input, refresh_interval, render_to_image, rendered_scene, replace_root, replace_views, request_autoscroll, request_decorations, reset_debug_frame_overlay_stats, restore_native_window_state, set_app_id, set_background_appearance, set_client_corner_radii, set_debug_frame_overlay_mode, set_dirty, set_document_path, set_exclusive_edge, set_exclusive_zone, set_input_region, set_phase, set_platform_waker, set_scale_factor, set_touch_prediction_enabled, set_traffic_light_position, set_view_id, set_window_edited, simulate_next_frame, spawn_with_priority, take_autoscroll, take_views, touch_prediction_enabled, transact, underline_bounds, update_count, use_state, viewport_size, visibility, visual_viewport_bounds, wake_platform, window_controls, with_content_mask, with_element_namespace, with_element_offset, with_global_id, with_optional_element_state, with_rem_size, with_tab_group
types: ArenaClearNeeded, DismissEvent, FocusOutEvent, Focusable, ManagedView, PendingInputStatus, PendingInputTimeoutStatus, TooltipId, WeakFocusHandle, WindowControlArea

#### window/a11y.rs (2 of 3 functions missing)
push_child, synthetic_node_id
types: A11ySubtreeBuilder

#### asset_cache.rs
types: Asset, AssetLogger

#### assets.rs
types: ImageId, RenderImageParams

#### debug_overlay.rs
types: DebugFrameOverlayMode

#### elements/surface.rs
types: SurfaceSource

#### global.rs
types: ReadGlobal, UpdateGlobal

#### interactive.rs
types: ExternalDragPayload, FileDragPaths, GestureEvent, InputEvent, KeyEvent, MouseEvent

#### platform/layer_shell.rs
types: KeyboardInteractivity, Layer, LayerShellNotSupportedError, LayerShellOptions

#### platform/popup.rs
types: PopupAnchor, PopupConstraintAdjustment, PopupGravity, PopupNotSupportedError, PopupOptions

#### platform/threaded_dispatcher.rs
types: ThreadedDispatcher

#### platform_scheduler.rs
types: PlatformScheduler

#### profiler/hang/monitor.rs
types: HangMonitorConfig, HangMonitorError, HangMonitorPoll, HangMonitorPollReason

#### scene.rs
types: PathVertex_ScaledPixels

#### shared_uri.rs
types: SharedUri

#### spring.rs
types: Interpolate, SpringTarget

#### window/prompts.rs
types: Prompt


</details>

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
- [ ] WebP, TIFF, ICO, PNM decoders; WebP animates in GPUI since `635026f`, with GPUI's test data for it in `platform.rs`
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
- [ ] Linux notifications: the API exists, but posting needs a D-Bus client, which ZUI lacks
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

- [ ] Text-presentation selector: `❤\u{fe0e}` draws the color heart
- [ ] `split_at` on ShapedLine and LineLayout, typographic bounds
- [ ] Missing-glyph reporting
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
