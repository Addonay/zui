# GPUI widget ecosystem status

This directory now includes bounded, renderer-independent consumer contracts for
the main GPUI examples: `Editor`, `TextArea`, `Tabs`, `TreeView`, `SplitPane`,
and `CommandPalette`.

Complete in this pass:

- deterministic keyboard navigation and activation;
- disabled and loading gates on every component;
- error state retained by editable/container options;
- UTF-8-safe bounded editor editing, selection, deletion, and newline policy;
- collapsed-tree visibility, tab skipping, split clamping, and command filtering;
- semantic property contracts for text input, options/list items, split control,
  and command palette;
- headless regression tests for each contract;
- `render()` contracts that compose real ZUI elements, so measure, layout,
  paint, hit-region, focus, and semantic snapshots exercise the same pipeline
  as application code;
- bounded tree virtualization with overscan, scroll-to-row, and drop-target
  feedback;
- pointer-driven split resizing and a bounded retained docking model.

The focused widget contracts are included in the current aggregate build;
`zig build test --summary all` reports 22/22 build steps and the
AccessKit-enabled run reports 23/23. Zig's summary does not emit an aggregate
test-case count, so this document does not infer one from source declarations.
The current aggregate artifacts are cached, and a fresh focused text/layout
root is blocked by the unrelated declaration-order error at
`src/gpu/scene.zig:66`; the widget status must not be read as native or fresh
renderer verification.

Still deferred: native platform drag/drop adapters, rich editor undo/redo and
syntax highlighting, async command providers, animated split handles, and the
larger GPUI editor ecosystem (completion, diagnostics, minimap, and full
multi-level docking persistence). The widget-side contracts are deterministic
and bounded; native delivery and richer retained editor behavior remain
separate platform/runtime work.
