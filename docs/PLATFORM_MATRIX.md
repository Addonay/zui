# ZUI platform support matrix

Assessment baseline: updated 2026-09-18, `zig version 0.17.0-dev.2151+2ec5523d5`
on Linux x86_64. See `ZUI_GAP_REPORT.md` sections 5G/5H for the full analysis.

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
| Linux Wayland | yes | yes (native) | yes (2026-09-18: todo app live on kwin_wayland, clean close; live multi-window protocol smoke) | partial (headless selftests; synthetic multi-window routing; live fractional-scale preferred_scale observed) | no |
| Linux X11 | yes | yes (native) | yes (2026-09-18: todo app live, clean close exit; multi-window live tests; 2x DPI physical window observed) | partial (headless selftests; multiwindow ×5 synthetic; live targeted input) | no |
| Windows (Win32) | yes | **yes** (`zig build check -Dtarget=x86_64-windows-gnu`, 13/13; never executed) | no | no | no |
| macOS (Cocoa) | yes | **yes** (`zig build check -Dtarget=aarch64-macos-none`, 13/13; never executed) | no | no | no |
| GPU presentation (Vulkan/Metal/D3D12) | stubs only | n/a | no | no | no |
| Headless (`ZUI_BACKEND=null`) | yes | yes (native) | yes | yes (`zig build test` runs todo + dashboard selftests; multiwindow ×5) | n/a (no native surface) |

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
  initializers return `error.Unsupported`; there is no operational ZUI
  GPU presentation path.
- Multi-window: X11 (2026-09-18, live-tested), Wayland (2026-09-18,
  live protocol smoke on kwin_wayland), null (headless-tested). Win32 and
  Cocoa keep the explicit single-window guard (`createWindow == null`).

## Cross-target compile checks

Reproduce without executing anything:

```sh
zig build check -Dtarget=x86_64-windows-gnu   # compile-only
zig build check -Dtarget=aarch64-macos-none   # compile-only
```

Observed 2026-09-17: both targets failed (X11 target leakage, Win32
optional-function handling; alignment casts, Linux module leakage on
macOS, nested-optional ABI type). **Fixed 2026-09-18**: both targets now
compile 13/13 (see the git history for the gating/ABI fixes). The CI jobs
in `.github/workflows/ci.yml` should be flipped from `continue-on-error`
to required — compile evidence exists; native runner launch/behavior
validation is still open work before any parity claim.

## Toolchain policy

- Tested revision: `0.17.0-dev.2151+2ec5523d5` (this machine).
- `build.zig.zon` `minimum_zig_version`: `0.17.0-dev.2085+5e36170b5`
  (floor, not the tested revision).
- CI installs the exact tested revision from the Zig download index.
- Bump the minimum deliberately and note the tested revision in
  `README.md` when upgrading.
