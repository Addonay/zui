# ZUI platform support matrix

Assessment baseline: updated 2026-09-20, `zig version 0.17.0-dev.2151+2ec5523d5`
on Linux x86_64; cross-target compile rows refreshed 2026-09-22 on
`zig version 0.17.0-dev.2163+89ff10d56`. See `ZUI_GAP_REPORT.md` sections
5G/5H for the full analysis.

## Platform-service contract boundary

### Windows/macOS window-scoped contract

`src/platform/native_window_services.zig` is now the platform-neutral
source contract for the desktop pieces GPUI keeps per `PlatformWindow`:
generation-checked native handles, a bounded multi-window registry, clipboard
formats, IME composition/caret state, cursor visibility/shape, DPI conversion,
and lifecycle state. `src/platform/windows/services.zig` and
`src/platform/macos/services.zig` provide the native-handle adapters
(`HWND`/Objective-C `id`) without changing the application or window runtime.
The bindings also pin the Win32 activation/input-language/DPI/cursor symbols
and Cocoa backing-scale/lifecycle/text-input notification names.

The contract is deterministic and headless-tested. It is not evidence that
the current callback plumbing is multi-window-safe: `win32.zig` and
`cocoa.zig` still use a file-scope active backend for their native callback
classes/window procedure. Migrating those callbacks to the registry requires
native-host testing and is intentionally outside this workstream's allowed
files.

`src/platform/services.zig` is the portable, source-backed contract for the
GPUI platform-service families. The null backend deterministically stores text
clipboard data, URL/menu/appearance/cursor/notification requests, validates
all bounded payloads, and returns `error.Unsupported` for operations requiring
an OS or compositor: image/multi-format clipboard, file prompts, anchored
popups, layer-shell surfaces, screen capture, and external drag initiation.
This is an API and test milestone, not native support evidence.

Native gaps still requiring backend-specific work and live validation:

- Wayland/X11/Win32/Cocoa clipboard MIME formats, ownership, and selection
  lifetime;
- native file and save dialogs, URL launching and custom URL registration;
- app-menu installation and action/validation callbacks;
- notifications, credentials, system appearance, and window option mapping;
- compositor popups/layer-shell, screen capture providers, and external drag;
- native cursor taxonomy and platform-specific fallback behavior.
- Windows: HWND-per-window callback routing, native multi-format clipboard
  ownership, IMM32/TSF composition and candidate placement, per-monitor DPI
  transitions, activation/deactivation, and close/reopen behavior.
- macOS: NSWindow-per-window delegate routing, NSPasteboard ownership and
  non-text formats, NSTextInputClient/marked-text composition, cursor and
  backing-scale notifications, appearance/lifecycle transitions, and close/
  reopen behavior.

Linux cannot live-validate any of those Win32 or Cocoa operations. The
cross-target compiler can validate ABI shape and symbol typing only; a Windows
runner and macOS host are still required for behavior, clipboard ownership,
IME delivery, cursor display, monitor moves, and multi-window callback tests.

## Mobile lifecycle contract boundary

`src/platform/mobile.zig` now provides a platform-neutral GPUI-shaped
lifecycle vocabulary (`active`, `inactive`, `background`, `foreground`),
safe-area/IME insets with effective-edge calculation, shared window
appearance, callback registration, and deterministic null-backend tests.
`AdapterBoundary` exposes explicit Android and iOS slots, but every native
operation currently returns `error.Unsupported`.

Native work still required: Android `Activity`/`WindowInsets` and
`WindowInsetsAnimation`/`onTrimMemory` bridges; iOS `UIApplication` lifecycle,
`safeAreaInsets`, keyboard-frame notifications, appearance propagation, and
memory-warning observers; native surface recreation/resume ordering; and live
suspend/resume, rotation, cutout, keyboard, and memory-pressure validation on
both platforms. GPUI's richer screen/display contract is also not claimed:
native display identity, bounds, scale, refresh/orientation changes, and
rotation-driven surface metrics still need an adapter and tests. This contract
must not be read as mobile support.

## Evidence levels

No platform is called "supported" on weaker evidence than stated here.
Source presence alone is never support evidence.

| Level | Meaning |
| ----- | ------- |
| source | backend/driver source exists in the tree |
| compile | `zig build check -Dtarget=<triple>` succeeds (compile-only, never executed) |
| launch | the example app starts natively on that OS and presents a window |
| behavior | automated input/clipboard/IME/DPI/accessibility/multi-window checks pass natively |
| validated | manual native validation recorded (screen reader, multi-monitor DPI, suspend/resume, teardown) |

## Matrix

| Target | source | compile | launch | behavior | validated |
| ------ | :----: | :-----: | :----: | :------: | :-------: |
| Linux Wayland | yes | yes (native) | yes (2026-09-18: todo app live on kwin_wayland, clean close; live multi-window protocol smoke) | partial (headless selftests; synthetic multi-window routing; live fractional-scale preferred_scale observed; `tools/native_linux_probe.sh` sees text-input-v3 and data-device globals here, but preedit/commit/cancel/caret and clipboard/drag-drop remain UNVERIFIED without external protocol drivers) | no |
| Linux X11 | yes | yes (native) | yes (2026-09-18: todo app live, clean close exit; multi-window live tests; 2x DPI physical window observed) | partial (headless selftests; multiwindow ×5 synthetic; live targeted input; optional XIM source path with live fallback smoke; an IBus live attempt reached `XCreateIC` failure and fell back to `XLookupString`; XIM transaction and clipboard/Xdnd exchange remain UNVERIFIED) | no |
| Windows (Win32) | yes | **yes** (`zig build check -Dtarget=x86_64-windows-gnu`, 16/16 as of 2026-09-22; never executed) | no | no | no |
| macOS (Cocoa) | yes | **yes** (`zig build check -Dtarget=aarch64-macos-none`, 16/16 as of 2026-09-22; never executed) | no | no | no |
| Accessibility bridge | yes (vendored accesskit-c 0.23.0, `-Daccesskit=true`) | yes (native + foreign targets compile without it) | yes (adapter created live on X11) | partial (live Wayland PyAT-SPI probe observes 12 semantic nodes and a successful click action; Orca/NVDA/VoiceOver speech remains unverified) | no |
| GPU device boundary (Vellz/WGPU) | yes (opt-in) | yes (`gpu-check` with pinned wgpu-native) | yes (offscreen adapter/device probe on Mesa RADV) | partial (device limits/error path; not the default UI surface) | no |
| Native Wayland WGPU surface smoke | yes (opt-in Linux) | yes (`gpu-wayland-smoke`) | yes (3 diagnostic frames on Mesa RADV) | partial (surface configure/acquire/present; quads/clips/images/glyphs) | no |
| GPU presentation (Vulkan/Metal/D3D12) | partial WGPU/Wayland bridge; direct drivers remain stubs | n/a | partial (Wayland smoke only) | partial (tested scene subset) | no |
| Headless (`ZUI_BACKEND=null`) | yes | yes (native) | yes | yes (`zig build test` runs todo + dashboard selftests; multiwindow ×5) | n/a (no native surface) |

## Native Linux probe

Run `tools/native_linux_probe.sh` on the target workstation. It reports
source wiring, protocol/service presence, and external-consumer evidence as
separate rows. A protocol global, X server, AT-SPI bus, or registry is not an
event consumer and cannot prove behavior. `UNVERIFIED` is intentional:
Wayland text-input-v3 preedit/commit/cancel/caret requires an input-method
driver; Wayland data-device and X11 selection/Xdnd require a second native
client; and semantic publication requires a live ZUI tree observed by an
AT-SPI consumer. `ScreenReaderEnabled=true` is useful environment evidence,
but it still does not prove that ZUI published the expected nodes/actions.
Set `ZUI_NATIVE_REQUIRE=1` when those external actors are available; the
probe then fails instead of converting missing actors into a false pass.
The close/reopen line is likewise `UNVERIFIED` until an external runner
drives a real ZUI window; the checked-in X11 cycle test and fixture remain
executable source-backed coverage.

The probe also checks that the checked-in adapters contain their listener,
bind, callback, and selection-serving paths. Those are source-contract
checks, not runtime evidence. The AT-SPI rows distinguish the session bus,
registry, and screen-reader status from semantic publication.

## DPI / scale pipeline (2026-09-18)

Contract: layout and scene coordinates are LOGICAL f32 px; window
framebuffers, raster and input are PHYSICAL px at `window.scale_factor`.
Implemented end to end on: null (testable arbitrary scale, pixel-asserted
at 1x/2x/1.5x), X11 (env scale acquisition: `ZUI_SCALE`, `GDK_SCALE`), Win32
(WM_DPICHANGED, per-monitor DPI at creation), Cocoa (backingScaleFactor +
buffer-density re-query on resize). Wayland additionally wires
fractional-scale-v1 (`preferred_scale` authoritative, integer
`set_buffer_scale` fallback). What is NOT yet observed natively: a real
fractional-scale monitor move on X11 (RandR per-monitor detection is a
documented next stage; env scale is fixed per connection), Win32/Cocoa
runtime behavior (compile-only), and Wayland scale change re-rasterization
on a real fractional monitor.

Notes:

- CPU presentation goes through the Vellz CPU renderer
  (`src/gpu/vellz.zig`). `vulkan.zig`, `metal.zig`, and `d3d12.zig`
  initializers return `error.Unsupported`. The separate opt-in Vellz/WGPU
  boundary can acquire a native device, and the opt-in Wayland smoke can
  present diagnostic frames. The opt-in bridge covers ordered
  solid/gradient/border/rounded quads, rectangular clips, atlas images with
  crop/tint/transform/grayscale, mask/color glyphs, and bounded glyph/image
  reuse; default App resource handoff and the default ZUI scene path remain
  unimplemented.
- Multi-window: X11 (2026-09-18, live-tested), Wayland (2026-09-18,
  live protocol smoke on kwin_wayland), null (headless-tested). Win32 and
  Cocoa keep the explicit single-window guard (`createWindow == null`).

## Cross-target compile checks

Reproduce without executing anything:

```sh
zig build check -Dtarget=x86_64-windows-gnu   # compile-only
zig build check -Dtarget=aarch64-macos-none   # compile-only
```

The same two compile-only checks can be run with the reporting wrapper:

```sh
tools/cross_target_compile_probe.sh
ZUI_COMPILE_REQUIRE=1 tools/cross_target_compile_probe.sh
```

`PASS` means only that Zig compiled the target. It does not establish launch,
native callback routing, IME, clipboard ownership, DPI changes, accessibility,
or multi-window behavior. The wrapper reports missing Zig as `UNVERIFIED` and
never upgrades a compile result into a native behavior claim.

Observed 2026-09-17: both targets failed (X11 target leakage, Win32
optional-function handling; alignment casts, Linux module leakage on
macOS, nested-optional ABI type). **Fixed 2026-09-18**: both targets now
compile 15/15 (see the git history for the gating/ABI fixes), and the CI jobs
are required. Refreshed 2026-09-22 on `0.17.0-dev.2163+89ff10d56`: both
targets compile 16/16. Compile evidence exists; native runner launch/behavior
validation is still open work before any parity claim.

## Toolchain policy

- Tested revision: `0.17.0-dev.2163+89ff10d56` (this machine, refreshed
  2026-09-22; previously `0.17.0-dev.2151+2ec5523d5`).
- `build.zig.zon` `minimum_zig_version`: `0.17.0-dev.2085+5e36170b5`
  (floor, not the tested revision).
- CI installs the exact tested revision from the Zig download index.
- Bump the minimum deliberately and note the tested revision in
  `README.md` when upgrading.
