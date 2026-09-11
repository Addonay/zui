//! M1 seam for vello_cpu src/filter/context.rs (Apache-2.0 OR MIT).
//!
//! M1 does not rasterize filter layers: `coarse.bucketer.bucketCommands`
//! rejects any recorded filter layer with `error.Unsupported` (there is no
//! filter pipeline until M2), so no filtered pixmap is ever produced.
//! `dispatch.single_threaded.rasterizeFilterLayers` therefore returns this
//! empty context, and `bucketCommands` never reads it.
//!
//! M2 replaces this file with the real port (`set_layer`/`filter_layer`/
//! `scratch`, owning one `?Pixmap` per recorded layer plus a reusable scratch
//! pixmap); the public shape stays `cpu.filter.FilterContext`.

const std = @import("std");
const pixmap_mod = @import("../common/pixmap.zig");

/// The rendered pixmaps of the filter layers of one scene (M2).
///
/// M1 owns no pixmaps and stores no layer state; only the constructor and the
/// queries that `rasterizeFilterLayers`/`bucketCommands` need exist.
pub const FilterContext = struct {
    /// Number of recorded layers the context was created for.
    num_layers: usize = 0,

    /// Create a context for `num_layers` recorded layers.
    pub fn init(num_layers: usize) FilterContext {
        return .{ .num_layers = num_layers };
    }

    /// Release every owned filter pixmap. M1 owns none.
    pub fn deinit(_: *FilterContext, _: std.mem.Allocator) void {}

    /// Resolve a rendered filter layer to its pixmap.
    ///
    /// M1 never renders a filter layer, so this always returns `null`; the M2
    /// port returns a borrowed handle to the pixmap stored by `setLayer`.
    pub fn filterLayer(_: *const FilterContext, _: usize) ?*const pixmap_mod.Pixmap {
        return null;
    }
};

test "filter_context_m1_is_empty" {
    var ctx = FilterContext.init(3);
    defer ctx.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 3), ctx.num_layers);
    try std.testing.expectEqual(@as(?*const pixmap_mod.Pixmap, null), ctx.filterLayer(0));
}
