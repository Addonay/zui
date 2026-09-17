# ScrollArea and VirtualList

Both are retained widgets, created with `cx.new(Widget, options)` and inserted
with `entity.toElement()`. Options and callback contexts are borrowed; keep
callback state alive for the entity lifetime. Entity-owned input/semantic
callbacks use the existing generation guards.

- `ScrollArea.Options.build(context, window) -> Element` wraps an arbitrary
  subtree. Its natural measured height is the scroll extent. Use definite
  child heights rather than flex-grow for overflowing content.
- `VirtualList.Options.build_item(context, index, window) -> Element` builds
  only the visible fixed-height rows and overscan (default two each side).
  Row subtrees must fit `item_height`; no selection behavior is implied.
- Hosts supply viewport width/height in options and update them on resize,
  then request a render. Every render re-clamps against viewport/content.
  These widgets do not infer final parent layout constraints after construction.
- Scroll state is `ScrollArea.model` / `VirtualList.scroll.model`. Use
  `jump(offset)` for programmatic positioning, then request a render.
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

Variable-height lists are deferred. `virtual_list.HeightProvider` documents
the callback/context/revision seam; a future implementation needs a prefix
index, width/revision invalidation and stable-item anchor preservation. The
fixed-height path never invokes such a provider or measures all items.

Run `zig build test --summary all` for real headless layout, paint, wheel,
keyboard, capture, nested remainder, semantics, resize and million-item tests.
