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

- [ ] **First load of a URL is still slow (reported by the owner).** About 1 to 2 s. Measured: curl
      0.98 s / 1.42 s, `std.http` in Debug 1.83 s / 2.12 s, decoding 25 to 60 ms. Repeat loads are
      fast through the disk cache. Ideas, best first:
  - [ ] Build the HTTP and crypto code as a ReleaseFast static library even in Debug builds, which
        removes most of the 0.9 s Debug adds to TLS
  - [ ] Show something sized at once: a saved size or blurred thumbnail, so the layout does not jump
  - [ ] Reuse connections across images and across redirects to the same host
  - [ ] HTTP/2, or honoring `Cache-Control` and `ETag`, so a fresh entry needs no download at all
  - [ ] `prefetch(url)`, so an app can start loading before the image is on screen
- [ ] Load local files and embedded assets in the background, as GPUI does
- [ ] Size limit on a download; today a huge response is read whole into memory
- [ ] GIF animation (only the first frame draws)
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

- [ ] Pressure and back-gesture listeners
- [ ] Long-press tooltips
- [ ] External drag payloads (dragging out of the window)
- [ ] `cached` views
- [ ] Alias `with_animation` on `StyledElement`
- [ ] `container_query`, `percentage`
- [ ] `set_menus`, `init_colors`
- [ ] Scroll: ZUI stops propagation in the scroll listener and GPUI does not, so nested scrollers differ
- [ ] `Unbind`, `InputPreference`, pausing the pending-input timeout
- [ ] `keyboard_layout` and its change observer
- [ ] `delete_surrounding_text`; we never send surrounding text
- [ ] Linux: `xdg_activation`
- [ ] X11: drop lists sent with INCR are refused
- [ ] Entities in a replayed action can outlive a keymap that an action cleared

## Text

- [ ] `add_fonts` (every ported example skips `load_fonts`)
- [ ] Text-presentation selector: `❤\u{fe0e}` draws the color heart
- [ ] ShapedLine cursor and split APIs, typographic bounds
- [ ] Font enumeration
- [ ] Missing-glyph reporting
- [ ] cozmic `-Dsystem-libs` builds have no COLRv1, since hb-raster is a separate shared library

## Examples still to port

Each must run headless with a correct snapshot, and be driven for real: first frames hide most bugs.

- [ ] popover, anchor
- [ ] painting, data_table
- [ ] image_gallery, image_loading, gif_viewer
- [ ] mouse_pressure
- [ ] window, window_movable, window_positioning, window_shadow
- [ ] move_entity_between_windows, on_window_close_quit, toggle_headless
- [ ] set_menus, system_notifications, layer_shell, a11y
- [ ] paths_bench, testing

## Performance (after API parity)

- [ ] View caching with `AnyView::cached` and replayed scene ranges (`Scene.replay` exists)
- [ ] Avoid full layout when nothing changed
- [ ] X11 XShm presentation
- [ ] SIMD gradients in the CPU renderer
- [ ] Benchmarks against GPUI

## Project

- [ ] `dev` into `main`, source only (`AGENTS.md` §1.5)
- [ ] `AGENTS.md` §2 status table is older than the work since; refresh it
