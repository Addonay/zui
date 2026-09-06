//! Text layer: bindings today, shaping/rasterization next.
//!
//! `bindings` is the ported Gooey MIT-licensed FreeType/HarfBuzz/
//! Fontconfig `extern` table (no `@cImport`, compiles without system
//! headers). `face` (raster) and `shaper` (HarfBuzz buffer reuse) land
//! here as the Linux text backend takes shape.

pub const bindings = @import("bindings.zig");

test {
    _ = @import("bindings.zig");
}
