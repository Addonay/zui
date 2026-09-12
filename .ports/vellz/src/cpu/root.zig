//! Port of vello_cpu src/lib.rs (CPU renderer subset) (Apache-2.0 OR MIT).
//!
//! Module map follows upstream (`vello_cpu/src`):
//!
//! - `util.zig`        <- `util.rs` (`Span`, `div255`, `Premultiply`, ...)
//! - `record.zig`      <- `record.rs` (`RecordedFill`)
//! - `region.zig`      <- `region.rs` (`Region`, `Regions`)
//! - `settings.zig`    <- `render.rs` settings (`RenderMode`, `PixelFormat`,
//!   `RenderSettings`, `RasterizerSettings`, `TargetInit`); a leaf module so
//!   the dispatcher can name them without an import cycle
//! - `coarse/`         <- `coarse/` (`cmd`, `depth`, `bucketer`)
//! - `filter.zig`      <- `filter/` (`context.rs`, `flood.rs`,
//!   `gaussian_blur.rs`, `drop_shadow.rs`, `offset.rs`, `shift.rs`, and the
//!   `FilterEffect` dispatch)
//! - `dispatch/mod.zig` <- `dispatch/mod.rs` (`Dispatcher` vtable +
//!   dispatch selection)
//! - `dispatch/single_threaded.zig` <- `dispatch/single_threaded.rs`
//! - `dispatch/multi_threaded.zig` + `dispatch/multi_threaded/*.zig`
//!   <- `dispatch/multi_threaded.rs` + `dispatch/multi_threaded/{worker,cost}.rs`
//! - `fine/`           <- `fine/` (`Fine(K)`, `rasterizeRegion`,
//!   `highp.F32Kernel`, `lowp.U8Kernel`, `common/rounded_blurred_rect.rs`)
//! - `render.zig`      <- `render.rs` (`RenderContext`, `Resources`, and the
//!   re-exported settings types)

const std = @import("std");

pub const util = @import("util.zig");
pub const record = @import("record.zig");
pub const region = @import("region.zig");
pub const settings = @import("settings.zig");
pub const filter = @import("filter.zig");
pub const coarse = @import("coarse/mod.zig");
pub const dispatch = @import("dispatch/mod.zig");
pub const single_threaded = @import("dispatch/single_threaded.zig");
pub const multi_threaded = @import("dispatch/multi_threaded.zig");
pub const fine = @import("fine/mod.zig");
pub const render = @import("render.zig");
pub const probe = @import("probe.zig");

pub const Span = util.Span;
pub const F32Kernel = fine.F32Kernel;
pub const U8Kernel = fine.U8Kernel;
pub const FilterContext = filter.FilterContext;

pub const RenderContext = render.RenderContext;
pub const Resources = render.Resources;
pub const RenderMode = render.RenderMode;
pub const PixelFormat = render.PixelFormat;
pub const RenderSettings = render.RenderSettings;
pub const RasterizerSettings = render.RasterizerSettings;
pub const TargetInit = render.TargetInit;
pub const Offset = render.Offset;

test {
    std.testing.refAllDecls(@This());

    // Explicit imports keep every module (and its `test` decls) in the test
    // build even if a decl becomes unreferenced.
    _ = @import("record.zig");
    _ = @import("region.zig");
    _ = @import("settings.zig");
    _ = @import("filter.zig");
    _ = @import("coarse/bucketer.zig");
    _ = @import("coarse/cmd.zig");
    _ = @import("coarse/depth.zig");
    _ = @import("dispatch/mod.zig");
    _ = @import("dispatch/single_threaded.zig");
    _ = @import("dispatch/multi_threaded.zig");
    _ = @import("dispatch/multi_threaded/task.zig");
    _ = @import("dispatch/multi_threaded/cost.zig");
    _ = @import("dispatch/multi_threaded/worker.zig");
    _ = @import("dispatch/multi_threaded/sync.zig");
    _ = @import("fine/mod.zig");
    _ = @import("fine/blurred_rect.zig");
    _ = @import("fine/highp/mod.zig");
    _ = @import("fine/lowp/mod.zig");
    _ = @import("fine/lowp/blend.zig");
    _ = @import("fine/lowp/compose.zig");
    _ = @import("fine/lowp/gradient.zig");
    _ = @import("fine/lowp/image.zig");
    _ = @import("render.zig");
    _ = @import("probe.zig");
}
