# ZUI

Hand-rolled retained UI framework in Zig. One foreground thread owns state
(`App`/`Entity`/`Context`), views render transient elements (`div()`/`text()`),
a layout pass sizes them, a painter records a `Scene`, and a native backend
presents it with the CPU rasterizer. GPU drivers are future work.

## Toolchain

- Tested with `zig version 0.17.0-dev.2085+5e36170b5` on Linux.
- `build.zig.zon` declares `minimum_zig_version 0.17.0-dev.1970+67f39b551`
  (a floor, not the tested revision). Bump it deliberately and note the
  tested revision here when upgrading.
- System libraries (Wayland/X11, Vulkan loader) are reached through
  hand-written `extern` tables via runtime `dlopen` — never hard-linked.
  The cozmic text engine dlopens FreeType/HarfBuzz/Fontconfig itself; ZUI
  only consumes its Zig API. Vendored C is limited to image codecs
  (`third_party/`: stb_image, nanosvg).

## Commands

```sh
zig build test          # unit tests (zui + layout) + todo tests + headless selftest
zig build run-todo      # run the todo example (needs a display or ZUI_BACKEND=null)
zig build selftest-todo # headless integration: synthetic input through the full stack
zig build run-images    # render the images demo to a PPM snapshot

# Headless text cost per frame over the real element path (no window/backend).
# Times layout.measure+place and painter.paint separately for N = 1/16/64/256
# text nodes (14px labels, 16px sentences, 16px wrapped paragraphs); prints
# ns/node, ns/char, scene glyphs, the paint-phase uncached-shape share, and a
# cold first-frame row. Add `-- --format json` for JSONL. Use
# `-Doptimize=ReleaseFast` for representative frame costs.
zig build bench-text

ZUI_BACKEND=null ZUI_TODO_DEMO=1 zig build run-todo       # seeded, headless
ZUI_SNAPSHOT=/tmp/todo.ppm zig build run-todo             # one-frame PPM dump
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
  Window                   one logical window (native window ownership: see Limits)
    elements.Frame         transient nodes rebuilt each dirty render
      elements.layout      flexbox measure/place (standalone layout/ port NOT yet wired)
      elements.painter     nodes -> gpu.Scene (quads + glyphs + image blits)
      gpu.software         CPU rasterizer; platform backends present the pixels
fonts/                     text engine: cozmic shaping/layout, FreeType raster,
                           swash image cache + the ZUI glyph atlas
images/                    stb/nanosvg decoders + decoded-pixel cache
layout/                    source-shaped Taffy port, standalone; adapter is plan M3
gpu/device.zig             experimental SDL-shaped vtable; no working driver yet
```

Roadmap: `plan.md` (milestones M0–M7). Port ledger: `src/layout/port.md`.

## Supported / limitations

- Backends: Linux Wayland + X11 (runtime-verified); macOS Cocoa and Windows
  Win32 exist as source but are **not** runtime-validated here. Headless
  `null` backend for tests. `ZUI_BACKEND=wayland|x11|null` pins the choice.
- One native window per process for now (`error.MultipleNativeWindowsNotSupported`
  otherwise); headless supports up to `MAX_WINDOWS` logical windows.
- Text: cozmic is the only text engine. Element measure and paint both run
  one cozmic layout per text node (one shape, shared advances/fallback; a
  node keeps its measured box if a glyph cannot be painted). `src/fonts/`
  holds only the glyph atlas (`atlas.zig`) and the engine
  (`text_engine.zig`); there is no legacy `-Dtext-engine` switch. When no
  engine is installed in a frame, text draws nothing. TextField is
  append-only with no selection/IME yet (plan M3/M4).
- Scene draws quads, then glyphs, then images — cross-type paint order is
  **not** preserved (plan M2). No per-window DPI scaling yet.
- `gpu/device` + Vulkan/Metal/D3D12 are skeletons returning
  `error.Unsupported`; presentation goes through `gpu/software`.
- Hot structs (`Scene` ~5.9MB, element `Frame` ~2.5MB, all inline storage)
  must be heap-allocated or embedded in a heap owner — never stacked
  together in one function. The engine is heap-allocated for the same
  reason (its atlas is ~1MB inline).
