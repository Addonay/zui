# Notices

ZUI is MIT licensed (see `LICENSE`).

ZUI is a port of GPUI (https://github.com/zed-industries/zed/tree/main/crates/gpui),
Copyright 2022 - 2025 Zed Industries, Inc., licensed under the Apache License,
Version 2.0. Its design, public API and portions of its logic (including shader
math) are derived from GPUI.

## Dependencies (fetched by `build.zig.zon`)

| Package | Source | Role |
| ------- | ------ | ---- |
| cozmic | https://github.com/Addonay/cozmic | text shaping, layout and rasterization (port of cosmic-text; bundles HarfBuzz and FreeType) |
| zafi | https://github.com/Addonay/zafi | flexbox / grid / block layout (port of Taffy) |

## Vendored C code (`third_party/`)

- nanosvg (`nanosvg.h`, `nanosvgrast.h`): zlib license, Copyright (c) 2013-2014 Mikko Mononen.
- stb_image (`stb_image.h`): public domain / MIT, Sean Barrett.
