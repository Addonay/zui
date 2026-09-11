//! Port of vello_common lib.rs (foundation subset) (Apache-2.0 OR MIT).
//!
//! Only the modules listed here are landed so far; the remaining
//! `vello_common` modules (`tile`, `strip`, `encode`, ...) are tracked in
//! `plan.md` §5 and are added without changing these ownership contracts.
//!
//! Module dependency direction (enforced by Zig's lack of import cycles):
//!
//! ```
//! geometry, math, shared            (leaves)
//!   -> util                         (leaf: no tile/strip imports)
//!   -> pixmap
//!   -> transforms, target
//!   -> paint -> render_state -> transforms
//! ```
//!
//! Allocator contract: types that own heap memory (`Pixmap`, `Pool`,
//! `RetainVec`, `RootTransforms`, `Shared(T)`) take an explicit
//! `std.mem.Allocator` on every growing operation and have
//! `init`/`deinit` pairs; borrowed views (`PixmapMut`) document their
//! lifetime and never outlive the owner.

pub const geometry = @import("geometry.zig");
pub const math = @import("math.zig");
pub const shared = @import("shared.zig");
pub const util = @import("util.zig");
pub const pixmap = @import("pixmap.zig");
pub const target = @import("target.zig");
pub const transforms = @import("transforms.zig");
pub const paint = @import("paint.zig");
pub const render_state = @import("render_state.zig");
pub const flatten = @import("flatten.zig");
pub const tile = @import("tile.zig");
pub const strip = @import("strip.zig");
pub const strip_storage = @import("strip_storage.zig");
pub const intersect = @import("intersect.zig");
pub const strip_generator = @import("strip_generator.zig");
pub const clip = @import("clip.zig");
pub const viewport = @import("viewport.zig");
pub const rect = @import("rect.zig");
pub const mask = @import("mask.zig");
pub const filter_effects = @import("filter_effects.zig");
pub const filter = @import("filter.zig");
pub const blurred_rounded_rect = @import("blurred_rounded_rect.zig");
pub const record = @import("record.zig");
pub const encode = @import("encode.zig");

test {
    // `refAllDecls` does not force analysis of imported files in this Zig
    // version, so tests in submodules must be pulled in explicitly here.
    _ = @import("geometry.zig");
    _ = @import("math.zig");
    _ = @import("shared.zig");
    _ = @import("util.zig");
    _ = @import("pixmap.zig");
    _ = @import("target.zig");
    _ = @import("transforms.zig");
    _ = @import("paint.zig");
    _ = @import("render_state.zig");
    _ = @import("flatten.zig");
    _ = @import("tile.zig");
    _ = @import("strip.zig");
    _ = @import("strip_storage.zig");
    _ = @import("intersect.zig");
    _ = @import("strip_generator.zig");
    _ = @import("clip.zig");
    _ = @import("viewport.zig");
    _ = @import("rect.zig");
    _ = @import("mask.zig");
    _ = @import("filter_effects.zig");
    _ = @import("filter.zig");
    _ = @import("blurred_rounded_rect.zig");
    _ = @import("record.zig");
    _ = @import("encode.zig");
}
