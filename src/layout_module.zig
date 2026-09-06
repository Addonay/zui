//! Package root for the standalone `layout` Zig module.
//!
//! Keeping this one level below `src/` is important: layout kernels use the
//! shared `core` package via `../core`, and Zig's module sandbox only permits
//! imports below a module root. Consumers still get the intended API:
//! `@import("layout")`.

const impl = @import("layout/root.zig");

pub const style = impl.style;
pub const geometry = impl.geometry;
pub const tree = impl.tree;
pub const cache = impl.cache;
pub const measure = impl.measure;
pub const flex = impl.flex;
pub const grid = impl.grid;
pub const block = impl.block;
pub const compute = impl.compute;
pub const round = impl.round;

pub const Style = impl.Style;
pub const Display = impl.Display;
pub const Position = impl.Position;
pub const BoxSizing = impl.BoxSizing;
pub const Direction = impl.Direction;
pub const Dimension = impl.Dimension;
pub const LengthPercentage = impl.LengthPercentage;
pub const Edges = impl.Edges;
pub const FlexDirection = impl.FlexDirection;
pub const FlexWrap = impl.FlexWrap;
pub const AlignItems = impl.AlignItems;
pub const AlignContent = impl.AlignContent;
pub const AlignSelf = impl.AlignSelf;
pub const JustifyContent = impl.JustifyContent;
pub const GridTrack = impl.GridTrack;
pub const GridAutoFlow = impl.GridAutoFlow;
pub const AvailableSpace = impl.AvailableSpace;
pub const SizingMode = impl.SizingMode;
pub const Layout = impl.Layout;
pub const LayoutTree = impl.LayoutTree;
pub const NodeId = impl.NodeId;
pub const MeasureFunc = impl.MeasureFunc;
pub const ComputeTree = impl.ComputeTree;

test {
    _ = @import("layout/root.zig");
}
