# ZUI

Hand-rolled retained UI framework in Zig. One foreground thread owns state
(`App`/`Entity`/`Context`), views render transient elements (`div()`/`text()`),
a layout pass sizes them, a painter records a `Scene`, and a native backend
presents it with the vellz CPU renderer by default. An opt-in WGPU/Vellz path
now covers device acquisition and a tested Wayland surface/scene bridge,
while CPU presentation remains the compatibility path.

## Toolchain

- Tested with `zig version 0.17.0-dev.2163+89ff10d56` on Linux (all gates in
  `docs/GPUI_PARITY_MATRIX.md` re-run on this revision, 2026-09-22).
- `build.zig.zon` declares `minimum_zig_version 0.17.0-dev.2085+5e36170b5`
  (a floor, not the tested revision). Bump it deliberately and note the
  tested revision here when upgrading. See `docs/PLATFORM_MATRIX.md`
  for the toolchain policy.
- System libraries (Wayland/X11, Vulkan loader) are reached through
  hand-written `extern` tables via runtime `dlopen` — never hard-linked.
  The cozmic text engine dlopens FreeType/HarfBuzz/Fontconfig itself; ZUI
  only consumes its Zig API. Vendored C is limited to image codecs
  (`third_party/`: stb_image, nanosvg).

## Commands

```sh
zig build test          # unit tests (zui + layout) + todo tests + headless selftest
zig build test-legacy   # the same unit suite through the legacy layout escape hatch
zig build run-todo      # run the todo example (needs a display or ZUI_BACKEND=null)
zig build selftest-todo # headless integration: synthetic input through the full stack
zig build run-images    # render the images demo to a PPM snapshot
zig build -Doptimize=ReleaseFast run-animation  # GPUI-style spring/rotation demo

# Optional WGPU/Vellz device gate (requires the pinned wgpu-native library).
# The repository's local prebuilt is under .ports/wgpu/.reference/artifacts.
zig build gpu-check -Dgpu=true \
  -Dwgpu-native-prefix=.ports/wgpu/.reference/artifacts/prebuilt

# Optional native Wayland surface smoke (Linux/Wayland only). This presents
# a small bridged ZUI scene; the CPU renderer remains the default path.
zig build gpu-wayland-smoke -Dgpu=true \
  -Dwgpu-native-prefix=.ports/wgpu/.reference/artifacts/prebuilt

# Bridge test for ordered ZUI quads, clips, images, borders, and glyph uploads.
zig build gpu-wayland-test -Dgpu=true \
  -Dwgpu-native-prefix=.ports/wgpu/.reference/artifacts/prebuilt

# Accessibility-friendly motion policy: animated values snap and no frame
# source is requested for decorative animation.
ZUI_REDUCE_MOTION=1 zig build -Doptimize=ReleaseFast run-animation

# Headless text cost per frame over the real element path (no window/backend).
# Times layout.measure+place and painter.paint separately for N = 1/16/64/256
# text nodes (14px labels, 16px sentences, 16px wrapped paragraphs); prints
# ns/node, ns/char, scene glyphs, the paint-phase uncached-shape share, and a
# cold first-frame row. Add `-- --format json` for JSONL. Use
# `-Doptimize=fast` for representative frame costs.
zig build bench-text -Doptimize=fast -- --format json --iter 9 --warmup 3
# Profile only the warm retained element path (useful with callgrind).
zig build bench-text -Doptimize=fast -- --element-only --quick --format json

ZUI_BACKEND=null ZUI_TODO_DEMO=1 zig build run-todo       # seeded, headless
ZUI_SNAPSHOT=/tmp/todo.ppm zig build run-todo             # one-frame PPM dump
bash tools/run-zlay-parity.sh                             # Zlay vs pinned Taffy fixture
python3 tools/check-gpui-parity-matrix.py                  # GPUI source-ledger gate
bash tools/run-differential.sh                             # 18-record differential gate
zig build debug-test                                      # trace/profiler/snapshot gate

# Remaining steps (`zig build --help` lists all of them).
zig build check                           # compile every test root + example, run nothing
zig build renderer-probe                  # headless explicit renderer-selection probe
zig build debug-probe                     # deterministic trace/profiler/scene snapshot dump
zig build selftest-animation selftest-dash  # headless integration selftests for those examples
zig build zlay-probe                      # print a matched Zlay/Taffy oracle fixture
zig build run-dash-kit                    # Rust gpui-kit dashboard (needs cargo on PATH)
zig build gpu-compile -Dgpu=true          # compile the Vellz/WGPU boundary (no device needed)
```

## Reconstructing source references

The upstream implementation references are deliberately not stored in this
repository. They are pinned by immutable commit ID and can be restored after a
fresh clone with:

```sh
bash tools/fetch-references.sh
```

The command restores root references plus the Cozmic, WGPU, and Vellz port
references. It will never replace an existing checkout at a different commit;
inspect or remove that checkout explicitly before rerunning it.

## Architecture

```text
App / scheduler            owns entities, platform connection, text engine, image cache
  Window (n)               per-window native handle, focus/scale, renderer surface;
                           multi-window on X11/Wayland/null (Win32/Cocoa guard explicitly)
    elements.Frame         transient nodes rebuilt each dirty render
      elements.layout      flexbox measure/place; packaged Zlay is the default
                           path, with ZUI_LAYOUT=legacy as a migration escape
      elements.painter     nodes -> ordered gpu.Scene commands
                           (quads + bounded line strokes + glyphs + image blits)
      gpu.vellz            Vello-derived CPU renderer; per-window physical buffer
      app/assets           asset service: loading/ready/failed, dedup, budgets
                            path reads run on the task worker pool, decode+place
                            completes on the UI thread (see app/tasks)
      app/tasks            worker pool (default 2, ≤32 in flight) + UI-thread
                            completion queue drained at step start; weak-target
                            completions no-op after destroy, over-limit fails loud
      debug/               frame inspector (ZUI_INSPECT=1), stats, debug overlay
fonts/                     text engine: cozmic shaping/layout, FreeType raster,
                           cross-frame layout cache, swash image cache + atlas
images/                    stb/nanosvg decoders + decoded-pixel cache
widgets/                   Button/Checkbox/Switch/Slider/Progress/RadioGroup,
                           TextField/TextArea/Editor, ScrollArea, VirtualList,
                           VirtualTable, Menu/Select/ComboBox, Tooltip,
                           Popover/Modal, Tabs, TreeView, SplitPane,
                           CommandPalette, bounded docking, focus/theme layers
a11y/                      per-frame semantic tree (roles/names/values/states/
                           bounds/actions) keyed by stable element IDs
zlay (package)             source-shaped Taffy port, standalone dependency;
                           adapter covers the canonical element style subset;
                           ZUI_LAYOUT=legacy is the migration escape hatch
gpu/device.zig             SDL-shaped device contract; software/null drivers
                           validate, Vulkan/Metal/D3D12 init is unsupported
```

Roadmap: `plan.md` (milestones M0–M7). Port ledger: `src/layout/port.md`.
The full GPUI capability ledger is `docs/GPUI_PARITY_MATRIX.md`; it records
implemented, verified, and still-open framework surface area explicitly.

## Supported / limitations

- Backends: Linux Wayland + X11 (runtime-verified, live multi-window on both);
  macOS Cocoa and Windows Win32 compile cross-target (`zig build check`) but
  are **not** runtime-validated here (see `docs/PLATFORM_MATRIX.md`).
  Headless `null` backend for tests. `ZUI_BACKEND=wayland|x11|null` pins the choice.
- Multi-window: X11 + Wayland support several native windows with targeted
  event routing; Win32/Cocoa keep an explicit single-window guard.
- DPI: complete logical/physical pipeline — layout and scene coordinates are
  logical px; framebuffers, raster and input are physical at
  `window.scale_factor`. Text re-rasterizes per density; Wayland wires
  fractional-scale-v1, Win32 wires WM_DPICHANGED, Cocoa re-queries
  backingScaleFactor; X11 acquires scale from `ZUI_SCALE`/`GDK_SCALE`
  (per-monitor RandR detection is a documented next stage).
- Text: cozmic is the only text engine. Measure→paint shares one shaped
  layout, and the cross-frame layout cache re-uses unchanged shapes across
  frames. The measured 2026-09-20 `-Doptimize=fast` warm benchmark is
  0.62ms for 256 sentence nodes and 0.47ms for 64 wrapped paragraphs; the
  fixed-capacity atlas uses allocation-free indexed glyph lookup.
  TextField supports bounded single- and multiline editing with grapheme-aware
  caret/deletion, selection, undo/redo, selection-aware clipboard, pointer
  caret placement, and an IME composition protocol (preedit/commit/cancel).
  Native compositor IME validation remains open (docs/TEXT_ROADMAP.md).
  Focused `test-text` and aggregate text paths are green on this host.
- Scene is an ordered command stream (`src/gpu/scene.zig`) consumed in
  paint order by the Vellz CPU path; cross-type overlap is preserved.
  Commands are bounded (16K); an overflowed frame is REJECTED with a
  diagnostic placeholder, never presented partial (`rejected_frames`).
- Widgets ship as bounded behavior + render + semantic + theme layers
  (`src/widgets/`). The component contracts are not a claim of complete GPUI
  ecosystem parity: richer editor services, persistent docking, native drag/
  drop, visual polish, and platform validation remain open.
  The a11y tree (`src/a11y/`) publishes to platform accessibility through
  the vendored AccessKit C ABI (`third_party/accesskit`, upstream 0.23.0)
  with `-Daccesskit=true` — Linux unix adapter created live; screen-reader
  (Orca/NVDA/VoiceOver) validation and Windows/macOS adapters are pending
  (see `docs/A11Y_PLAN.md` for the evidence ledger).
- `gpu/device` + Vulkan/Metal/D3D12 are skeletons returning
  `error.Unsupported`; presentation goes through `gpu/vellz` CPU rendering.
- Hot structs (`Scene` ~6.3MB, element `Frame` ~4.3MB, all inline storage)
  must be heap-allocated or embedded in a heap owner — never stacked
  together in one function. The engine is heap-allocated for the same
  reason (its atlas is ~1MB inline).

## License / platform status

- License: MIT (`LICENSE`); third-party notices: `NOTICE.md`.
- Platform support levels (source vs compile vs launch vs validated):
  `docs/PLATFORM_MATRIX.md`. CI runs native tests plus compile-only
  cross-target checks (`.github/workflows/ci.yml`).
