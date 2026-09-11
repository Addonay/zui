# GPU shaders

Compiled WGSL from the pinned `vello_gpu_shaders` v0.2.0 at the upstream
revision recorded in `tools/pin.env`.

- `manifest.json` — provenance, byte counts, SHA-256 of every file.
- `*.wgsl` — linked and minified WGSL, checked in (never generated at build
  time; a GPU build does not need Rust/naga/WESL).
- `generated.zig` — `@embedFile` accessors used by `vellz.gpu`.

Regenerate after changing the pin:

```sh
tools/fetch-reference.sh
tools/generate_shaders.sh
```

The files are minified by upstream, which means struct and variable names are
opaque (`A`, `B`, ...). The host-side contract (bind groups, vertex layouts,
struct byte offsets, constants) is documented in
[`docs/shader-interface.md`](../../../docs/shader-interface.md) and must be
validated with size/offset assertions in Zig before any shader is modified.
