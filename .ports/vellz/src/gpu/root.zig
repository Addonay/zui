//! GPU backend root.
//!
//! This module is analyzed only when the package is built with `-Dgpu=true`.
//! It deliberately does not import the sibling `wgpu` package: the shader
//! assets and shared GPU layouts are usable (and testable) without it.
//!
//! The wgpu-backed renderer lands in Milestone 5 as `src/gpu/backend/` and is
//! referenced from `src/root.zig` only when `-Dgpu=true`; Zig resolves import
//! paths even in untaken comptime branches, so the backend root directory must
//! exist before it can be referenced there.

const build_options = @import("build_options");

/// Compiled WGSL sources from the pinned `vello_gpu_shaders` revision.
pub const shaders = @import("shaders/generated.zig");

comptime {
    // Keep the option observable so a build with `-Dgpu=true` and no backend
    // fails loudly instead of silently shipping a CPU-only root.
    if (build_options.gpu) {
        @compileError("vellz GPU backend is not implemented yet (Milestone 5)");
    }
}

test {
    @import("std").testing.refAllDecls(@This());
}
