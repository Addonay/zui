# ZUI platform support matrix

Assessment baseline: 2026-09-17, `zig version 0.17.0-dev.2151+2ec5523d5`
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
| Linux Wayland | yes | yes (native) | yes (prior runtime use) | partial (headless selftests only) | no |
| Linux X11 | yes | yes (native) | yes (prior runtime use) | partial (headless selftests only) | no |
| Windows (Win32) | yes | **no** (known failure, see below) | no | no | no |
| macOS (Cocoa) | yes | **no** (known failure, see below) | no | no | no |
| GPU presentation (Vulkan/Metal/D3D12) | stubs only | n/a | no | no | no |
| Headless (`ZUI_BACKEND=null`) | yes | yes (native) | yes | yes (`zig build test` runs todo + dashboard selftests) | n/a (no native surface) |

Notes:

- Linux "launch" is prior runtime use, not a live interaction session in
  this review; no fresh native GUI interaction was performed.
- CPU presentation on Linux goes through the Vellz CPU renderer
  (`src/gpu/vellz.zig`). `vulkan.zig`, `metal.zig`, and `d3d12.zig`
  initializers return `error.Unsupported`; there is no operational ZUI
  GPU presentation path.
- One native window per process is enforced
  (`error.MultipleNativeWindowsNotSupported`, `src/app/app.zig:208-213`).
  Multi-window support is future work.
- Per-window DPI scaling is not implemented: scale factors are reported
  by the platform but there is no complete logical/physical pipeline.

## Known foreign-target compile failures

Reproduce without executing anything:

```sh
zig build check -Dtarget=x86_64-windows-gnu   # compile-only
zig build check -Dtarget=aarch64-macos        # compile-only
```

Observed 2026-09-17:

- **Windows (`x86_64-windows-gnu`):** 2 errors.
  `src/platform/linux/x11.zig:203` performs a target-invalid `XEvent`
  size assertion; `src/platform/windows/win32.zig:221` mishandles the
  optional `GetDpiForWindow` lookup type.
- **macOS (`aarch64-macos`):** ~65 diagnostics. Dominant classes:
  alignment-increasing function-pointer casts in
  `src/platform/dl.zig:56`, Linux Wayland/X11 modules instantiated for
  the macOS target, Objective-C message-send alignment casts, and a
  nested-optional Objective-C ABI type.

These jobs run in CI (`.github/workflows/ci.yml`) as known-failing
(`continue-on-error`) so fixes and regressions are both visible.
Flip them to required when `zig build check` succeeds for the target,
then add native runners to prove launch and behavior before claiming
parity.

## Toolchain policy

- Tested revision: `0.17.0-dev.2151+2ec5523d5` (this machine).
- `build.zig.zon` `minimum_zig_version`: `0.17.0-dev.2085+5e36170b5`
  (floor, not the tested revision).
- CI installs the exact tested revision from the Zig download index.
- Bump the minimum deliberately and note the tested revision in
  `README.md` when upgrading.
