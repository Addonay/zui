# Typed element composition

`zui.elements.Composition` is the public, source-backed equivalent of the
GPUI contracts in `.references/gpui/crates/gpui/src/element.rs`:

| GPUI contract | ZUI contract |
| --- | --- |
| `IntoElement` | `elements.compose(value, context)` |
| `Render` | `elements.renderView(&view, context)` or `Scope.render(&view)` |
| `RenderOnce` | `elements.renderOnce(value, context)` or `Scope.renderOnce(value)` |
| `View` | `elements.view(value, context)` or `Scope.view(value)` |
| global element id / keyed state | `Context.useKeyed(T, key, init)` |
| dropped element tree | `Scope.end()` teardown boundary |
| `deferred` | `Context.deferElement(child, priority)` |
| `container_query` | `Context.query(size, callback)` |
| `surface` | `Context.retainSurface(&surface)` |

The API is deliberately public-only: an external consumer needs only
`@import("zui")`, a frame, and an allocator-owned `RetainedElementState`.
State is retained by `(type, key)` across rebuilt frames, and untouched keys
are destroyed at the end of the completed scope. Teardown callbacks run once
in reverse registration order.

This is a typed composition and lifecycle contract, not a claim that all GPUI
platform behavior or every GPUI element family is implemented. Layout and
paint remain the existing ZUI element pipeline.

`zig build test-element-composition` compiles and runs an external consumer
root that imports only `zui` and exercises the typed `Render` plus keyed-state
contract.
