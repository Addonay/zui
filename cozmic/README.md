# cozmic

Cozmic is a planned standalone Zig text layout and editing library inspired by
COSMIC Text. Its purpose is to give custom UI frameworks a coherent text engine:
font selection and fallback, shaping, bidirectional paragraph layout, wrapping,
hit testing, caret geometry, selection, editing, incremental layout, and optional
glyph rasterization.

The high-level engine will be written in Zig, with explicit allocators, ownership,
errors, cache lifetimes, and renderer-independent output. The initial design uses
HarfBuzz and FreeType behind narrow adapters rather than requiring a rewrite of
OpenType shaping and rasterization. Dependency-backed output equivalence must be
measured; a backend substitution is not automatically COSMIC Text parity.

COSMIC Text is the primary source and compatibility reference. Pango contributes
behavioral ideas and a secondary oracle for capabilities such as strong/weak
carets, logical attributes, selection geometry, tabs, and advanced typography.
Pango-inspired additions are tracked separately from upstream compatibility;
Pango and COSMIC Text are not assumed to give identical answers in every case.

Cozmic is independent of ZUI. It will not own native windows, OS keycode mapping,
clipboard services, GPU devices, or a widget tree. ZUI is intended to become one
consumer, alongside other renderers and UI frameworks.

**Status: specification only. No Cozmic engine has been implemented.**

Read [plan.md](plan.md) for the pinned upstream baseline, source and dependency
coverage, implementation contracts, test strategy, milestones, and completion
gates. The upstream checkout is at `../.references/cosmic-text`, excluded from the
parent repository by `.gitignore`. Reconstruction instructions and the exact
revision will be recorded in the plan.
