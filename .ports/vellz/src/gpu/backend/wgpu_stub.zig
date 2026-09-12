//! Inert stand-in for the sibling `wgpu` package in CPU-only builds.
//!
//! Zig 0.17 resolves every `@import` literal in every file it parses,
//! including files that are only reachable through untaken comptime branches
//! (`src/root.zig` -> `gpu/root.zig` -> `backend/root.zig` ->
//! `backend/device.zig`). The GPU backend sources therefore name the `wgpu`
//! module even when `-Dgpu=true` is not passed.
//!
//! `build.zig` provides this file under the module name `wgpu` for CPU-only
//! builds so those sources parse without resolving, downloading, building, or
//! linking the real package. Nothing here is semantically analyzed: with
//! `gpu=false`, `vellz.gpu.backend` is an empty namespace and no GPU
//! declaration is ever referenced. A `-Dgpu=true` build replaces this module
//! with the real `.ports/wgpu` package, and `src/gpu/root.zig` fails loudly if
//! that dependency cannot be resolved.
