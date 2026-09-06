//! ZUI layout engine — Zig-native port of Taffy architecture.
//!
//! Reference: `.references/taffy/src/` (MIT, DioxusLabs/taffy 0.14.0).
//! GPUI pins taffy `=0.13.0` (see `.references/gpui/crates/gpui/Cargo.toml:96`)
//! and wraps it in `crates/gpui/src/taffy.rs`. We port the kernels to Zig
//! SoA with fixed caps instead of depending on Rust.
//!
//! Mapping to Taffy sources:
//! - `style.zig` <- `style/mod.rs` + `style/{dimension,alignment,flex,grid,block,float}.rs`
//! - `geometry.zig` <- `geometry.rs` + `style/available_space.rs`
//! - `tree.zig` <- `tree/taffy_tree.rs` + `tree/traits.rs`
//! - `cache.zig` <- `tree/cache.rs`
//! - `measure.zig` <- measure-fn concept from `tree/taffy_tree.rs` + `compute/leaf.rs`
//! - `flex.zig` <- `compute/flexbox.rs`
//! - `grid.zig` <- `compute/grid/` (placement + track sizing)
//! - `block.zig` <- `compute/block.rs`
//! - `compute.zig` <- `compute/mod.rs` (dispatcher + sizing modes)
//! - `round.zig` <- GPUI `taffy.rs:270-344` device-pixel snap (Taffy rounding off)
//!
//! Hard constraints (from TODO.md):
//! - Zig only, zero allocation after init, every pool capped in `core/limits.zig`.
//! - No closures: measure hooks are fn pointers + `*anyopaque` context.
//! - Fixed `u16` node ids (`MAX_LAYOUT_ELEMENTS=4096` fits).
//!
//! Migration: `elements/layout.zig` (naive measure+place) keeps working.
//! New trees build here; element bridge lands once flex reaches parity.

pub const style = @import("style.zig");
pub const geometry = @import("geometry.zig");
pub const tree = @import("tree.zig");
pub const cache = @import("cache.zig");
pub const measure = @import("measure.zig");
pub const flex = @import("flex.zig");
pub const grid = @import("grid.zig");
pub const block = @import("block.zig");
pub const compute = @import("compute.zig");
pub const round = @import("round.zig");

pub const Style = style.Style;
pub const Display = style.Display;
pub const Position = style.Position;
pub const Dimension = style.Dimension;
pub const LengthPercentage = style.LengthPercentage;
pub const AvailableSpace = geometry.AvailableSpace;
pub const SizingMode = geometry.SizingMode;
pub const Layout = geometry.Layout;
pub const LayoutTree = tree.LayoutTree;
pub const NodeId = tree.NodeId;
pub const MeasureFunc = measure.MeasureFunc;

test {
    _ = @import("style.zig");
    _ = @import("geometry.zig");
    _ = @import("tree.zig");
    _ = @import("cache.zig");
    _ = @import("measure.zig");
    _ = @import("flex.zig");
    _ = @import("grid.zig");
    _ = @import("block.zig");
    _ = @import("compute.zig");
    _ = @import("round.zig");
}
