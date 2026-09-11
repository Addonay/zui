# Port contracts

Rules every module in this repository follows. They exist so separately
implemented modules compose into the real pipeline instead of a pile of
independently passing files.

## Naming and shape

- Types `PascalCase`; functions `camelCase`; fields and locals `snake_case`;
  constants `UPPER_SNAKE`. Upstream method names map to camelCase
  (`snap_up` → `snapUp`); upstream fields keep their names.
- Tagged unions replace Rust enums. Payload field names are lower-case
  (`Paint.solid`, `ImageSource.opaque_id`).
- No traits. Generic behavior is comptime duck typing: consumers take
  `anytype` and call the required methods; nothing is boxed or dynamically
  dispatched unless upstream had dynamic dispatch (e.g. `Dispatcher`).
- Rust `usize` → `usize` where used for indexing/lengths; `u32`/`u16`/`u8`
  sizes stay exactly as upstream, including fixed bit widths in caches,
  packed structs, and file formats.
- No `@cImport`. C interop goes through translated modules (`.ports/wgpu`
  exposes `wgpu.c`).

## Allocators and lifetimes

- Every type that owns heap memory has `init(allocator, ...)`, `deinit(self,
  allocator)`, and explicit `clone(allocator)` where upstream clones.
- Containers hold `std.ArrayList(T)` (unmanaged): `list.append(alloc, item)`,
  `list.deinit(alloc)`. An owned slice is `[]T` from the same allocator.
- Borrowed data is a slice or pointer with a doc comment stating who owns it
  and for how long. Public APIs never retain borrowed memory past the call
  unless the type documents it (e.g. `PixmapMut` is borrowed for `render`).
- Allocation failure propagates as `error.OutOfMemory`; the caller's object
  stays in a defined state (no half-appended public state).
- Shared ownership uses `common/shared.zig` (`Shared(T)`); raw `*T` means
  borrowed and must never be `release`d.

## Module dependency direction

Upstream Rust allows module import cycles; Zig does not. The required split:

```
kurbo, peniko, simd, common/math, common/geometry   (leaves)
  -> common/flatten
  -> common/tile
  -> common/strip
  -> common/strip_generator
  -> common/clip, common/viewport
  -> common/record, common/util (strip bbox parts live in strip.zig)
  -> common/paint, pixmap, render_state, transforms, target, shared
  -> cpu/coarse, cpu/region, cpu/fine, cpu/dispatch, cpu/render
  -> gpu/*  (only when -Dgpu=true)
  -> glifo/* -> cpu/text, gpu/text
```

`common/util.zig` is a leaf: numeric narrowing, pools, rectangle snapping.
Anything upstream in `util.rs` that needs `Strip`/`Tile` (`strip_bbox`) lives
in `strip.zig`. When a cycle appears, split by ownership, never by copying.

## Rendering semantics (must match upstream)

- Coordinates are y-down, f64 paths/transforms, f32 flattening/tiling/strips.
- Tiles are 4×4; `Strip.x`, `Strip.y`, and widths are tile-aligned; the alpha
  buffer is column-major, 4 bytes per pixel column.
- Coverage: `NonZero` → `min(|winding|*255 + 0.5, 255)`; `EvenOdd` →
  `min(|winding - 2*floor(0.5*winding + 0.5)|*255 + 0.5, 255)`; optional
  aliasing threshold binarizes per pixel.
- Pixels are premultiplied sRGB RGBA8. Conversion constants and rounding must
  match `color` 0.3.3 / `vello_common::util` exactly.
- Blend math on premultiplied values; `with_src_alpha` clamps RGB ≤ A after
  Mix. Lowp uses `div_255(v) = (v + 255) >> 8`; highp uses FMA expressions as
  written upstream.
- Default state: black solid paint, `Fill.NonZero`, `BlendMode.new(.normal,
  .src_over)`, stroke width 1, bevel join, butt caps, identity transforms.

## Testing

- Unit tests live in the ported file and derive from upstream `#[cfg(test)]`
  cases where they exist.
- Integration/oracle tests live under `tests/` and use `tests/scenes/*.json`
  with `tools/compare.py`.
- A module is only `connected` once the public pipeline exercises it; report
  that separately from `ported`.
- `zig fmt` is mandatory; `zig build test` must stay green once the module is
  wired into `src/root.zig`.
