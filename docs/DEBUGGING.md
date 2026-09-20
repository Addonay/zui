# Debugging frames and resources

ZUI exposes UI-thread diagnostics through `zui.debug`, `Window.diagnostics()`
and `App.diagnostics()`. These are observational APIs: they do not load fonts,
resolve assets, reset counters, or create animation deadlines.

## Quick start

```sh
ZUI_INSPECT=1 zig build run-todo 2>frames.jsonl
ZUI_LOG=1 zig build run-todo
```

`ZUI_INSPECT` must equal `1`. It is read when each window opens. Every render
emits one JSON line to stderr. Compiler/application messages may also be on
stderr; select lines with `type == "zui.frame"` when processing a mixed log.
Inspection is **off by default**, including release builds. It copies UI text
into logs: do not enable it for secrets or distribute captures without review.

Equivalent per-window configuration:

```zig
window.setInspector(.{ .enabled = true });
window.setDebugOverlay(.{ .bounds = true, .hit_regions = true, .focus = true });

const frame_stats = window.diagnostics();
const resource_stats = app.diagnostics();
_ = frame_stats;
_ = resource_stats;
```

The setters request one redraw. They do not change animation cadence or idle
wait behavior. Disable with `setInspector(.{})` / `setDebugOverlay(.{})`.

## Capture in a test or a file

```zig
const line = try zui.debug.inspector.jsonLine(allocator, window);
defer allocator.free(line);
// Pass `line` to your file writer or parse it with std.json.parseFromSlice.
```

For automatic file output, supply `inspector.Options.sink`: a borrowed context
pointer and `fn (*anyopaque, []const u8) anyerror!void`. The callback receives a
complete JSON line, including its final newline, synchronously after rendering.
Write it using the application's normal file/I/O context. Keep the sink alive
until disabled/window destruction; do not retain the borrowed bytes or mutate
or render the window inside the callback. File ownership remains with the app.
Allocation/write failures increment `inspector_failures` instead of disrupting
presentation. Capturing is an opt-in allocating/debug operation, not a profiler
for allocation-free performance measurements.

## JSONL version 1

Each `zui.frame` record includes:

- `window`, monotonic per-window render number `frame`, element `generation`,
  and `focused_id` (focus handles and stable keys are separate namespaces).
- `elements`: a flat tree with `index`, `stable_key`, `first_child`, and
  `next_sibling`. Child links, not construction order, define ancestry. A zero
  key means unkeyed, not a stable identity. Duplicate-key counts are in `stats`.
- Each element's logical `bounds`, kind, selected sizing/flex/padding/opacity/
  border style fields, escaped UTF-8 `text_preview` (up to 120 bytes without
  splitting a codepoint), truncation flag, semantic role/name, and focus state.
  Invalid UTF-8 receives a diagnostic string instead of invalid JSON.
- `hit_regions`: actual painter-generated, clipped rectangles in dispatch order
  (last wins), focus IDs, owner liveness and supported pointer-listener flags.
  Regions do not currently carry stable node keys: do not infer identity from
  equal rectangles. Semantic bindings remain visible even when their missing or
  duplicate key prevents inclusion in the accessibility snapshot.
- `stats.scene`: command/quad/glyph/blit counts, lifetime `dropped` and current
  `dropped_frame`. Rejected frames report the replacement placeholder's counts
  and preserve the original drop evidence, not a misleading partial scene.

`jsonLine()` reads the current frame and returns owned bytes. Automatic captures
are taken before debug overlay ink; an explicit capture after rendering includes
that ink in scene counts. Tree geometry always describes application elements.

## Counter scopes and timing

`App.diagnostics()` contains shared image-pool used/capacity bytes, live entries,
slot evictions, stale-handle drops; App event queue drops/coalescing/critical
overflow; atlas hits/misses/evictions/drops/bytes; and text-engine init failures.
Backend-private event queues are **not** folded into App queue counts. Image
pool usage includes orphan bytes until a pool reset; slot evictions are not a
count of pool resets. Atlas absence reports zero without forcing initialization.

`totals` aggregates render count, scene/hit-region drops, rejected frames,
layout/paint nanoseconds, skipped overlays, and inspector failures across live
**and retired** windows. `App.rejected_frames` separately retains its existing
scope: rejections seen by `App.step`, excluding direct `Window.render()` calls.
Window counters describe that window only. Resource counters retain the
underlying cache/queue's lifetime scope; no averaging or counter reset occurs.

Layout and paint durations use a monotonic clock around the mounted element
lifecycle. Layout includes text measurement/shaping. Paint includes scene,
hit-region, and semantic-tree construction. Both exclude view construction,
inspection, debug overlays, rasterization and native presentation. Raw scene
renderers report `null` durations rather than fictitious zero-cost layout.
Timers return zero on clock failure. These are CPU phase diagnostics, **not**
end-to-end latency, GPU timing, p95 claims, or evidence of GPUI performance parity.

`ZUI_LOG=1` emits a `[zui:stats] exit {...}` summary at `App.deinit()` before
resources are freed, including windows closed earlier. Continue to call deinit
on all normal exit paths. Abnormal process termination cannot print a summary.

## Geometry overlays and headless tests

Bounds are cyan, hit rectangles orange, focused hit rectangles magenta with a
2px outline. Debug rectangles append to the ordinary scene and therefore work
with headless rasterization too. They never register hit regions, change layout,
or participate in focus. Already-rejected frames keep their overflow placeholder.
When scene capacity is exhausted, debug rectangles are skipped and counted in
`overlay_skipped`; enabling diagnostics must not reject otherwise valid content.

`src/debug/inspector_test.zig` builds a real mounted keyed/semantic tree, runs a
headless App frame, parses JSON and checks geometry/roles/escaped text/focus,
checks overlay ink and hit-list invariance, forces a scene push failure and an
actual image slot eviction, and verifies counters survive window destruction.
Run the integrated suite with:

```sh
zig build test --summary all
```

This is a snapshot inspector and debug overlay, not an interactive tree editor,
native accessibility bridge, GPU profiler, or complete beginner/custom-widget
curriculum. Those broader documentation and tooling gaps remain separate work.

## Reusable visual test context

For renderer-independent GPUI-style visual tests, use
`zui.debug.test_context.TestContext` (also exported as
`VisualTestContext`). The caller supplies a `Scene`; the context supplies a
deterministic viewport, injected timestamps, frame/event traces, input replay,
scene golden capture/comparison, profiler records, and a compact inspector
snapshot. It never creates a native window or claims pixel/GPU equivalence.

Focused and external-consumer gates:

```sh
zig build test-context --summary all
zig build visual-test --summary all
zig build visual-test-probe
```

`test-context` is the focused 30-test contract gate. `visual-test-probe` is an
external `zui` consumer smoke command; it remains subject to the repository's
normal public-module compilation prerequisites. The inspector snapshot JSON is
stable apart from intentionally injected time fields, while golden digests and
replayed event digests omit timestamps.
