# ScrollArea and VirtualList

Both are retained widgets, created with `cx.new(Widget, options)` and inserted
with `entity.toElement()`. Options and callback contexts are borrowed; keep
callback state alive for the entity lifetime. Entity-owned input/semantic
callbacks use the existing generation guards.

- `ScrollArea.Options.build(context, window) -> Element` wraps an arbitrary
  subtree. Its natural measured height is the scroll extent. Use definite
  child heights rather than flex-grow for overflowing content.
- `VirtualList.Options.build_item(context, index, window) -> Element` builds
  only the visible rows and overscan (default two each side). With no
  `height_provider`, rows use the fixed `item_height`; the opt-in provider
  supplies bounded variable heights without constructing the full collection.
  Row subtrees must fit their reported height; no selection behavior is implied.
- `VirtualTable.Options.height_provider` uses the same bounded provider for
  variable-height rows. Fixed `row_height` remains the compatibility path;
  table selection, stable row keys, sorting, and activation work in both modes.
- `VirtualTable` provides bounded programmatic and pointer-handle column
  reordering, reports changes to the host, and keeps source column identities.
- `VirtualTable.scrollToRow(row, strategy)` mirrors list placement control;
  `ensureVisible` remains the non-disruptive `nearest` form.
- Hosts supply viewport width/height in options and update them on resize,
  then request a render. Every render re-clamps against viewport/content.
  These widgets do not infer final parent layout constraints after construction.
- Scroll state is `ScrollArea.model` / `VirtualList.scroll.model`. Use
  `jump(offset)` for programmatic positioning, then request a render.
- `VirtualList.scrollToItem(index, strategy)` provides GPUI-style item
  visibility control with `top`, `center`, `bottom`, and `nearest` placement.
  Fixed rows are exact; variable rows use the bounded provider estimate and
  are refined on the next render without walking the collection.
- Wheel input follows the existing `ScrollEvent` contract: positive dy is up,
  one line is `line_height` logical pixels (default 32), fractional lines are
  preserved. The current protocol has no separate pixel/line unit or phase.
- Thumb length is proportional with a theme-spacing minimum target size.
  Track presses jump; captured dragging maps directly to the logical range.
- Home/End and arrows work through focus. Space/Shift+Space page down/up.
  **Native PageUp/PageDown are blocked:** `platform.event.Key` currently has
  neither variant. `ScrollModel.page(.up/.down)` is available, and the key
  adapter recognizes `page_up`/`page_down` when the platform owner adds them.
  This task intentionally does not edit platform event/backend mappings.
- Default nested policy consumes locally and passes remainder outward at
  edges, including the remainder of a partially consumed delta. `contain`
  stops chaining. Existing legacy scroll listeners still consume everything.
- Accessibility snapshots expose list/listitem, one-based set position, total
  size, scrollability, current offset/range, focus and increment/decrement/
  set-value actions. Offscreen overscan rows are hidden, not eagerly expanded.
  This is the existing frame semantic model, not a native AT bridge.

## Bounds and precision

For viewport H, fixed row height h and overscan o, at most
`ceil(H/h) + 1 + 2*o` builders run (clamped at collection edges). There are
four chrome nodes while overflowing, plus one wrapper per row and whatever
nodes the application builder creates. The million-item test uses a one-node
builder: **18 nodes at either edge, 24 at a fractional middle offset**.
The builder remains responsible for the framework's per-frame node/text caps.

Offsets and extent use f64. Each built row subtracts the logical offset before
conversion to f32 layout coordinates; there is no enormous spacer to lose
fractional precision. Default keys derive from list key + index; supply
`item_key` to preserve data identity through reordering. Anchor preservation
through insertions/reorders is not implemented.

Variable-height lists use `virtual_list.HeightProvider`. The implementation
samples an estimated extent, probes only a bounded neighborhood around the
requested offset, invalidates on width/revision changes, and preserves a
stable anchor where the bounded estimate permits. Very large jumps can be
temporarily approximate until nearby rows are probed; a full prefix index is
still a possible future optimization.

Run `zig build test --summary all` for the aggregate headless layout, paint,
wheel, keyboard, capture, nested remainder, semantics, resize and million-item
suite. The current summary reports 22/22 build steps from cached artifacts;
the focused Zlay root is currently blocked by the declaration-order error at
`src/gpu/scene.zig:66`, so this is not a fresh renderer/layout certification.
