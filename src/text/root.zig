//! Text layer: low-level font binding tables.
//!
//! `bindings` is the ported Gooey MIT-licensed FreeType/HarfBuzz/
//! Fontconfig `extern` table (no `@cImport`, compiles without system
//! headers). The working stack (discovery, raster, shaping, atlas) lives
//! in `fonts/`; text layout/editing semantics are plan M3/M4 work.

pub const bindings = @import("bindings.zig");

test {
    _ = @import("bindings.zig");
}
