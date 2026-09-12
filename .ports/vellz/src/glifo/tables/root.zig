//! Raw OpenType table ports used by `glifo`.
//!
//! Each file is a hand-written subset of the `read-fonts` 0.41.0 generated
//! accessors; see the module docs in each file for the exact scope and the
//! degradation rules (`read_array(..).ok().unwrap_or_default()` semantics).

pub const sfnt = @import("sfnt.zig");
pub const head = @import("head.zig");
pub const maxp = @import("maxp.zig");
pub const hhea = @import("hhea.zig");
pub const hmtx = @import("hmtx.zig");
pub const loca = @import("loca.zig");
pub const glyf = @import("glyf.zig");
pub const cmap = @import("cmap.zig");
pub const colr = @import("colr.zig");
pub const cpal = @import("cpal.zig");
pub const bitmap = @import("bitmap.zig");
pub const cff = @import("cff.zig");
pub const variations = @import("variations.zig");
pub const gvar = @import("gvar.zig");

pub const Head = head.Head;
pub const Maxp = maxp.Maxp;
pub const Hhea = hhea.Hhea;
pub const Hmtx = hmtx.Hmtx;
pub const Loca = loca.Loca;
pub const Charmap = cmap.Charmap;
pub const Colr = colr.Colr;
pub const Cpal = cpal.Cpal;

test {
    _ = sfnt;
    _ = head;
    _ = maxp;
    _ = hhea;
    _ = hmtx;
    _ = loca;
    _ = glyf;
    _ = cmap;
    _ = colr;
    _ = cpal;
    _ = bitmap;
    _ = cff;
    _ = variations;
    _ = gvar;
}
