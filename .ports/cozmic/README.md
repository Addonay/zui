# cozmic

Cozmic is a Zig text layout and editing library ported from
[COSMIC Text](https://github.com/pop-os/cosmic-text). It provides font selection
and fallback, shaping, bidirectional paragraph layout, wrapping, hit testing,
caret geometry, selection, editing, incremental layout, and optional glyph
rasterization.

The high-level engine is written in Zig with explicit allocators, ownership,
errors, cache lifetimes, and renderer-independent output. HarfBuzz and FreeType
are the intended production backends behind narrow adapters.

COSMIC Text is the primary source and compatibility reference. Pango
contributes behavioral ideas and a secondary oracle for capabilities such as
strong/weak carets, logical attributes, selection geometry, tabs, and advanced
typography.

Cozmic is independent of ZUI. It does not own native windows, OS keycode
mapping, clipboard services, GPU devices, or a widget tree.

## Status

The library is mid-integration. The module ports exist and have unit tests, but
the public `Buffer` pipeline is still being connected to the real shaper and
font system. See [plan.md](plan.md) for the ported/connected/verified matrix,
the pinned upstream baseline, and the completion gates.

Upstream checkout and vendored references live in `.reference/`:
`cosmic-text`, `ezi-code` (Unicode algorithms), and HarfBuzz/FreeType sources.

## Building

```sh
zig build test          # all tests
zig build bench         # cozmic benchmarks
zig build bench-compare # cozmic vs cosmic-text criterion side-by-side
```

Optional features: `-Dvi`, `-Dsyntect` (default off).
