//! Small explicit Zig prelude for the GPUI-style public surface.
//!
//! Zig has no implicit imports, so this module is opt-in and intentionally
//! names the common framework types and constructors rather than hiding them.
pub const App = @import("app/root.zig").App;
pub const Window = @import("app/root.zig").Window;
pub const Context = @import("app/root.zig").Context;
pub const Entity = @import("app/root.zig").Entity;
pub const WeakEntity = @import("app/root.zig").WeakEntity;
pub const Element = @import("elements/root.zig").Element;
pub const Color = @import("core/root.zig").Color;
pub const Point = @import("core/root.zig").Point;
pub const Size = @import("core/root.zig").Size;
pub const Rect = @import("core/root.zig").Rect;
pub const Scene = @import("gpu/root.zig").Scene;
pub const div = @import("elements/root.zig").div;
pub const text = @import("elements/root.zig").text;
pub const custom = @import("elements/root.zig").custom;
pub const img = @import("elements/root.zig").img;
pub const svg = @import("elements/root.zig").svg;
pub const Canvas = @import("elements/root.zig").Canvas;
pub const widgets = @import("widgets/root.zig");
pub const colors = @import("colors.zig");
