//! vellz — a Vello-derived 2D renderer in Zig.
//!
//! Ported from the pinned upstream revision recorded in `build.zig` and
//! `tools/pin.env`:
//!
//!     vello_common, vello_cpu, vello_gpu, vello_gpu_shaders
//!     linebender/vello @ 1e63b4a40ccb484f82e1d85b83df97ab95bcfbe7
//!     (v0.10.0-51-g1e63b4a4, 2026-09-11)
//!
//! The upstream `research/` tree (the older compute-centric GPU renderer) is
//! deliberately out of scope.
//!
//! The library is CPU-first: `@import("vellz")` compiles with no GPU
//! dependency at all. The GPU backend is available only when the package is
//! built with `-Dgpu=true`, which resolves the sibling `../wgpu` package.

const build_options = @import("build_options");

// Dependency ports (canonical owners). See plan.md §4.
pub const kurbo = @import("kurbo/root.zig");
pub const peniko = @import("peniko/root.zig");
pub const simd = @import("simd/root.zig");

/// Glyph outline loading for text rendering (M3 `glifo` port).
pub const glifo = @import("glifo/root.zig");

/// Shared core: geometry, paths, tiles, strips, paints, pixmaps.
pub const common = @import("common/root.zig");

// The CPU renderer (`cpu/`) is added as its modules land; see plan.md §5 for
// the coverage ledger.
pub const cpu = @import("cpu/root.zig");

/// The optional GPU backend. Only available when built with `-Dgpu=true`;
/// otherwise this is an empty namespace and the `wgpu` import does not exist.
pub const gpu = if (build_options.gpu) @import("gpu/root.zig") else struct {};

test {
    @import("std").testing.refAllDecls(@This());

    // The GPU host/shader layout contract is CPU-safe (its modules import only
    // `vellz.common`/`vellz.peniko`, never `wgpu`), so its tests run in the
    // default build even though the wgpu backend is gated behind `-Dgpu=true`.
    _ = @import("gpu/util.zig");
    _ = @import("gpu/copy.zig");
    _ = @import("gpu/blend.zig");
    _ = @import("gpu/filter.zig");
    _ = @import("gpu/render/common.zig");
}
