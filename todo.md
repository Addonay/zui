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

## Images

- [ ] First load of a URL takes about 1 to 2 s. It now matches curl (0.87 to 1.12 s and 1.27 to 1.92 s,
      against curl's 0.87 to 0.98 s and 1.36 to 1.42 s) in Debug too, so what is left is the network. Repeat
      loads are fast through the disk cache. To make it feel faster:
  - [ ] Show something sized at once: a saved size or blurred thumbnail, so the layout does not jump
  - [ ] Reuse connections across images and across redirects to the same host
  - [ ] HTTP/2, or honoring `Cache-Control` and `ETag`, so a fresh entry needs no download at all
  - [ ] `prefetch(url)`, so an app can start loading before the image is on screen
- [ ] Load local files and embedded assets in the background, as GPUI does
- [ ] Size limit on a download; today a huge response is read whole into memory
- [ ] `retain_all(id)`; URLs in an `ImageCacheItem` skip the disk copy and do not share entries with `AssetCache`
- [ ] Removing a path from the default `AssetCache`; `image_loading`'s image 4 has no click handler without it
- [ ] Quitting waits for a `use_asset` load that never checks `LoadContext.is_cancelled`
- [ ] Atlas and memory behaviour over many image changes, such as repeated "Next Photos", is unmeasured
- [ ] `testing`: `test_allow_parking` is not ported, since ZUI has no parking check
- [ ] `run_until_parked` never parks while a GIF is on screen, and spins to its 10,000-iteration guard
- [ ] WebP, TIFF, ICO, PNM decoders
- [ ] EXIF orientation in PNG (JPEG is done)
- [ ] GPUI's delay before `with_loading` appears, so fast loads do not flash a placeholder
- [ ] Atlas tiles of images replaced by a newer download are never freed
- [ ] Disk cache evicts oldest written, not least recently used
- [ ] `RemoteImages` and disk cache behaviour on Windows and macOS is compiled, never run

## Platforms

- [ ] macOS (Metal), reference `gpui_macos`
- [ ] Windows (D3D12, Vulkan fallback), reference `gpui_windows`
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
- [ ] Alias `with_animation` on `StyledElement`
- [ ] `container_query`, `percentage`
- [ ] `init_colors`; `set_menus` is stored but only macOS will draw it
- [ ] Linux notifications: the API exists, but posting needs a D-Bus client, which ZUI lacks
- [ ] Scroll: ZUI stops propagation in the scroll listener and GPUI does not, so nested scrollers differ
- [ ] `Unbind`, `InputPreference`, pausing the pending-input timeout
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
- [ ] ShapedLine cursor and split APIs, typographic bounds
- [ ] Font enumeration
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
