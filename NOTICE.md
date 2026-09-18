# Dependency, reference, and license notices

ZUI itself is MIT licensed (see `LICENSE`).

## Packaged Zig dependencies (fetched by `build.zig.zon`)

| Package | Source | Pinned commit | Role |
| ------- | ------ | ------------- | ---- |
| cozmic  | https://github.com/Addonay/cozmic | `83e791d1752a1d86d7eadb19987a10fcd44307a8` | text shaping/layout engine |
| zlay    | https://github.com/Addonay/zlay | `dbce9266163ba5400385693aebd86c0726464a94` | standalone layout engine (Taffy-derived) |
| vellz   | https://github.com/Addonay/vellz | `d5aa45e7eda4d3924b64c2b9dfabf1c4f3412916` | CPU 2D renderer |

Each package carries its own license; consult the fetched sources for
their terms. Vellz's GPU/wgpu dependency is lazy and is never resolved
by ZUI's CPU build.

## Vendored C code (`third_party/`, compiled into the `zui` module)

- nanosvg (`nanosvg.h`, `nanosvgrast.h`): Zlib licensed,
  Copyright (c) 2013-2014 Mikko Mononen. SVG parse + rasterize.
- stb_image (`stb_image.h`): public domain (Unlicense/MIT),
  Sean Barrett. Image decode.

Upstream: https://github.com/memononen/nanosvg,
https://github.com/nothings/stb

## Vendored third-party sources (distributed with this tree)

- `third_party/accesskit/`: AccessKit C ABI (accesskit-c), upstream tag
  `0.23.0`, dual MIT/Apache-2.0 (Copyright The AccessKit contributors;
  includes a Chromium-derived notice in `LICENSE.chromium` — see
  `LICENSE-APACHE`). The `Cargo.lock` pins the exact dependency set; the
  library is built by cargo only when the `-Daccesskit=true` build option
  is set. Upstream: https://github.com/AccessKit/accesskit-c

## In-tree ports and API references (reimplemented, not verbatim copies)

- `src/core/limits.zig`: ported from Gooey
  (https://github.com/duanebester/gooey), MIT licensed,
  Copyright 2025 Duane Bester <bester.duane@gmail.com>.
- `src/gpu/device.zig` (+ `vulkan.zig`, `metal.zig`, `d3d12.zig`):
  API shape modeled on SDL3's `SDL_gpu.h` (Zlib license,
  Copyright 1997-2026 Sam Lantinga); reimplemented in Zig.
- `src/platform/linux/evdev.zig`: pattern ported from Gooey's
  `platform/linux/input.zig` (MIT, Duane Bester).
- `src/app/keymap.zig`: bindings modeled on GPUI/Zed's
  `key_dispatch.rs` (as attributed in-file).

## Local reference checkouts (NOT distributed)

`.references/`, `.ports/`, and `tools/references.env` record upstream
sources used during development (Gooey, GPUI/Zed, SDL3, DVUI, Taffy).
They are excluded from the package (`build.zig.zon` `.paths`) and are
never required to build, test, or consume ZUI.
