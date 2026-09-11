# Daybook — ZUI todo example

A native task workspace with a light blue-gray palette, a sidebar on wide
windows, compact filters on smaller windows, and a four-row paginated list.
The old `main.zig` has been replaced by `daybook.zig`.

```sh
zig build run-todo
# Optional sample tasks:
ZUI_TODO_DEMO=1 zig build run-todo
```

Click the composer or press Tab to start typing. Enter adds a task; Escape
releases focus. Clicking outside the composer also releases focus.
Select a row and press Space to toggle it or Delete to remove it.
All / Active / Done filter the list; Previous / Next navigate long lists.

Tasks are held in memory for the current run; this example does not save them.
The shared text field supports UTF-8 codepoint movement and editing, but not
selection, mouse caret positioning, or full IME composition.

## Validation

```sh
zig build test
zig build selftest-todo
ZUI_TODO_DEMO=1 ZUI_SNAPSHOT=/tmp/daybook.ppm zig build run-todo
ZUI_TODO_DEMO=1 ZUI_SNAPSHOT=/tmp/daybook-small.ppm ZUI_SNAPSHOT_WIDTH=540 ZUI_SNAPSHOT_HEIGHT=740 zig build run-todo
```

Snapshots use the actual ZUI layout and software painter, without a desktop
window. Integration checks drive the backend event queue, including focus,
typing, submission, completion, Escape, Tab, and pagination.
