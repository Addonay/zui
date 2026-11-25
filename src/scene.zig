//! Port of gpui/src/scene.rs: the per-frame list of primitives, their draw order, and batching.
const std = @import("std");
const geometry = @import("geometry.zig");
const color = @import("color.zig");
const atlas = @import("atlas.zig");
const bounds_tree = @import("bounds_tree.zig");
const path_winding = @import("path_winding.zig");
const svg_mod = @import("elements/svg.zig");
const testing = std.testing;

pub const PathCurve = path_winding.PathCurve;
pub const PathTile = path_winding.PathTile;
pub const PathTiles = path_winding.PathTiles;

const Bounds = geometry.Bounds;
const Corners = geometry.Corners;
const Edges = geometry.Edges;
const Point = geometry.Point;
const Size = geometry.Size;
const Pixels = geometry.Pixels;
const ScaledPixels = geometry.ScaledPixels;
const Hsla = color.Hsla;
const Background = color.Background;
const AtlasTextureId = atlas.AtlasTextureId;
const AtlasTile = atlas.AtlasTile;
const BoundsTree = bounds_tree.BoundsTree;

/// Order in which primitives are painted; equal orders may be batched together.
pub const DrawOrder = u32;

/// A boolean stored as a `u32`, matching the shader-side representation.
pub const PaddedBool32 = struct {
    value: u32 = 0,

    pub fn from(value: bool) PaddedBool32 {
        return .{ .value = @intFromBool(value) };
    }
};

/// Indicates which region of the window is visible. Content outside the mask is not rendered.
pub fn ContentMask(comptime T: type) type {
    return struct {
        const Self = @This();

        bounds: Bounds(T) = .{},

        /// Scales the mask's pixel units by `factor`.
        pub fn scale(self: Self, factor: f32) ContentMask(ScaledPixels) {
            return .{ .bounds = self.bounds.scale(factor) };
        }

        /// Intersects this mask with `other`.
        pub fn intersect(self: Self, other: Self) Self {
            return .{ .bounds = self.bounds.intersect(other.bounds) };
        }
    };
}

/// The style of a border.
pub const BorderStyle = enum {
    solid,
    dashed,
};

/// A 2D affine transformation applied to a sprite: a row-major 2x2 matrix plus translation.
pub const TransformationMatrix = struct {
    rotation_scale: [2][2]f32 = .{ .{ 1, 0 }, .{ 0, 1 } },
    translation: [2]f32 = .{ 0, 0 },

    /// The unit matrix, which has no effect.
    pub fn unit() TransformationMatrix {
        return .{};
    }

    pub inline fn is_unit(self: *const TransformationMatrix) bool {
        return self.rotation_scale[0][0] == 1 and self.rotation_scale[0][1] == 0 and
            self.rotation_scale[1][0] == 0 and self.rotation_scale[1][1] == 1 and
            self.translation[0] == 0 and self.translation[1] == 0;
    }

    /// Moves the origin by `point`.
    pub fn translate(self: TransformationMatrix, point: Point(ScaledPixels)) TransformationMatrix {
        return self.compose(.{ .translation = .{ point.x, point.y } });
    }

    /// Clockwise rotation around the origin, in radians.
    pub fn rotate(self: TransformationMatrix, angle_radians: f32) TransformationMatrix {
        const cos = @cos(angle_radians);
        const sin = @sin(angle_radians);
        return self.compose(.{ .rotation_scale = .{ .{ cos, -sin }, .{ sin, cos } } });
    }

    /// Scales around the origin.
    pub fn scale(self: TransformationMatrix, sz: Size(f32)) TransformationMatrix {
        return self.compose(.{ .rotation_scale = .{ .{ sz.width, 0 }, .{ 0, sz.height } } });
    }

    /// Returns the transformation that applies `other` first, then `self`.
    pub fn compose(self: TransformationMatrix, other: TransformationMatrix) TransformationMatrix {
        if (std.meta.eql(other, TransformationMatrix{})) return self;
        const a = self.rotation_scale;
        const b = other.rotation_scale;
        return .{
            .rotation_scale = .{
                .{ a[0][0] * b[0][0] + a[0][1] * b[1][0], a[0][0] * b[0][1] + a[0][1] * b[1][1] },
                .{ a[1][0] * b[0][0] + a[1][1] * b[1][0], a[1][0] * b[0][1] + a[1][1] * b[1][1] },
            },
            .translation = .{
                self.translation[0] + a[0][0] * other.translation[0] + a[0][1] * other.translation[1],
                self.translation[1] + a[1][0] * other.translation[0] + a[1][1] * other.translation[1],
            },
        };
    }

    /// Applies the transformation to a point.
    pub fn apply(self: TransformationMatrix, point: Point(Pixels)) Point(Pixels) {
        const input = [2]f32{ point.x, point.y };
        var output = self.translation;
        for (&output, 0..) |*cell, i| {
            for (input, 0..) |value, k| cell.* += self.rotation_scale[i][k] * value;
        }
        return .{ .x = output[0], .y = output[1] };
    }

    /// The smallest axis-aligned bounds containing `b` once transformed.
    pub fn transform_bounds(self: TransformationMatrix, b: Bounds(ScaledPixels)) Bounds(ScaledPixels) {
        if (std.meta.eql(self, TransformationMatrix{})) return b;
        const xx = self.rotation_scale[0][0];
        const xy = self.rotation_scale[0][1];
        const yx = self.rotation_scale[1][0];
        const yy = self.rotation_scale[1][1];
        const tx = self.translation[0];
        const ty = self.translation[1];
        const corners = [4]Point(ScaledPixels){
            b.origin,
            b.top_right(),
            b.bottom_left(),
            b.bottom_right(),
        };
        var top_left: Point(ScaledPixels) = .{
            .x = xx * corners[0].x + xy * corners[0].y + tx,
            .y = yx * corners[0].x + yy * corners[0].y + ty,
        };
        var bottom_right = top_left;
        for (corners[1..]) |c| {
            const p: Point(ScaledPixels) = .{
                .x = xx * c.x + xy * c.y + tx,
                .y = yx * c.x + yy * c.y + ty,
            };
            top_left = top_left.min(p);
            bottom_right = bottom_right.max(p);
        }
        return Bounds(ScaledPixels).from_corners(top_left, bottom_right);
    }
};

pub const Quad = struct {
    order: DrawOrder = 0,
    border_style: BorderStyle = .solid,
    bounds: Bounds(ScaledPixels) = .{},
    content_mask: ContentMask(ScaledPixels) = .{},
    background: Background = Background.default,
    border_color: Hsla = Hsla.default,
    corner_radii: Corners(ScaledPixels) = .{},
    border_widths: Edges(ScaledPixels) = .{},
};

pub const Underline = struct {
    order: DrawOrder = 0,
    pad: u32 = 0,
    bounds: Bounds(ScaledPixels) = .{},
    content_mask: ContentMask(ScaledPixels) = .{},
    color: Hsla = Hsla.default,
    thickness: ScaledPixels = 0,
    wavy: PaddedBool32 = .{},
};

pub const Shadow = struct {
    order: DrawOrder = 0,
    blur_radius: ScaledPixels = 0,
    bounds: Bounds(ScaledPixels) = .{},
    corner_radii: Corners(ScaledPixels) = .{},
    content_mask: ContentMask(ScaledPixels) = .{},
    color: Hsla = Hsla.default,
    element_bounds: Bounds(ScaledPixels) = .{},
    element_corner_radii: Corners(ScaledPixels) = .{},
    /// 0 = drop shadow (rendered outside the element), 1 = inset shadow (rendered inside).
    inset: u32 = 0,
    pad: u32 = 0,
};

/// Refers to an animation of the scene a sprite is inserted into (GPUI `SpriteAnimationId`).
/// Fits in `MonochromeSprite`'s existing padding so the GPU instance layout is unchanged.
pub const SpriteAnimationId = enum(u32) {
    none = std.math.maxInt(u32),
    _,

    pub const NONE: SpriteAnimationId = .none;
};

/// A `TimedTransformation` the window applies to a sprite right before every present,
/// so the scene can be presented again without re-rendering views (GPUI `SpriteAnimation`).
pub const SpriteAnimation = struct {
    transformation: svg_mod.TimedTransformation,
    center: Point(Pixels),
    scale_factor: f32,
    base_color: Hsla = Hsla.default,
    sprite_index: usize = std.math.maxInt(usize),

    pub fn init(
        transformation: svg_mod.TimedTransformation,
        center: Point(Pixels),
        scale_factor: f32,
    ) SpriteAnimation {
        return .{
            .transformation = transformation,
            .center = center,
            .scale_factor = scale_factor,
        };
    }
};

pub const MonochromeSprite = struct {
    order: DrawOrder = 0,
    animation: SpriteAnimationId = .none,
    tile: AtlasTile,
    bounds: Bounds(ScaledPixels) = .{},
    content_mask: ContentMask(ScaledPixels) = .{},
    color: Hsla = Hsla.default,
    transformation: TransformationMatrix = .{},
};

pub const SubpixelSprite = struct {
    order: DrawOrder = 0,
    pad: u32 = 0,
    tile: AtlasTile,
    bounds: Bounds(ScaledPixels) = .{},
    content_mask: ContentMask(ScaledPixels) = .{},
    color: Hsla = Hsla.default,
    transformation: TransformationMatrix = .{},
};

pub const PolychromeSprite = struct {
    order: DrawOrder = 0,
    pad: u32 = 0,
    tile: AtlasTile,
    grayscale: PaddedBool32 = .{},
    opacity: f32 = 1,
    bounds: Bounds(ScaledPixels) = .{},
    content_mask: ContentMask(ScaledPixels) = .{},
    corner_radii: Corners(ScaledPixels) = .{},
};

/// A surface painted by the platform (e.g. a video frame). The handle is opaque to the scene.
pub const PaintSurface = struct {
    order: DrawOrder = 0,
    bounds: Bounds(ScaledPixels) = .{},
    content_mask: ContentMask(ScaledPixels) = .{},
    surface: ?*anyopaque = null,
};

/// Identifies a path within a scene's path list.
pub const PathId = struct {
    value: usize = 0,
};

/// A vertex of a path triangle with its position and texture coordinates.
pub fn PathVertex(comptime P: type) type {
    return struct {
        const Self = @This();

        xy_position: Point(P) = .{},
        st_position: Point(f32) = .{},
        content_mask: ContentMask(P) = .{},

        pub fn scale(self: Self, factor: f32) PathVertex(ScaledPixels) {
            return .{
                .xy_position = self.xy_position.scale(factor),
                .st_position = self.st_position,
                .content_mask = self.content_mask.scale(factor),
            };
        }
    };
}

/// A filled or stroked path represented as closed chains of xy-monotone quadratic
/// `PathCurve`s, binned into `PathTiles` when inserted into a `Scene`.
pub fn Path(comptime P: type) type {
    return struct {
        const Self = @This();

        allocator: std.mem.Allocator,
        id: PathId = .{},
        order: DrawOrder = 0,
        bounds: Bounds(P) = .{},
        paint_bounds_: Bounds(P) = .{},
        content_mask: ContentMask(P) = .{},
        color: Background = Background.default,
        even_odd: bool = true,
        curves: std.ArrayList(PathCurve) = .empty,
        tiles: ?PathTiles = null,
        start: Point(P) = .{},
        current: Point(P) = .{},
        has_contour: bool = false,
        closed_: bool = true,

        /// Creates an empty path starting at `start`.
        pub fn new(allocator: std.mem.Allocator, start: Point(P)) Self {
            return .{
                .allocator = allocator,
                .start = start,
                .current = start,
                .bounds = .{ .origin = start, .size = .{} },
                .paint_bounds_ = .{ .origin = start, .size = .{} },
            };
        }

        /// Wraps an owned slice of monotone curves produced by `PathBuilder`.
        pub fn from_curves(allocator: std.mem.Allocator, owned_curves: []PathCurve, even_odd: bool) Self {
            var p: Self = .{
                .allocator = allocator,
                .even_odd = even_odd,
                .curves = std.ArrayList(PathCurve).fromOwnedSlice(owned_curves),
            };
            p.recompute_bounds();
            return p;
        }

        pub fn deinit(self: *Self) void {
            self.curves.deinit(self.allocator);
            if (self.tiles) |*t| t.deinit();
        }

        /// Returns a deep copy that owns its own curves and tiles.
        pub fn clone(self: *const Self) !Self {
            var copy = self.*;
            copy.curves = .empty;
            copy.tiles = null;
            errdefer copy.deinit();
            try copy.curves.appendSlice(self.allocator, self.curves.items);
            if (self.tiles) |*t| copy.tiles = try t.clone();
            return copy;
        }

        /// Scales this path by `factor`, returning a new path.
        pub fn scale(self: *const Self, factor: f32) !Path(ScaledPixels) {
            var scaled: Path(ScaledPixels) = .{
                .allocator = self.allocator,
                .id = self.id,
                .order = self.order,
                .bounds = self.bounds.scale(factor),
                .paint_bounds_ = self.paint_bounds_.scale(factor),
                .content_mask = self.content_mask.scale(factor),
                .color = self.color,
                .even_odd = self.even_odd,
                .start = self.start.scale(factor),
                .current = self.current.scale(factor),
                .has_contour = self.has_contour,
                .closed_ = self.closed_,
            };
            errdefer scaled.deinit();
            try scaled.curves.ensureTotalCapacityPrecise(self.allocator, self.curves.items.len);
            for (self.curves.items) |curve| scaled.curves.appendAssumeCapacity(curve.scaled(factor));
            return scaled;
        }

        /// Starts a new contour at `to`, closing any previous open contour.
        pub fn move_to(self: *Self, to: Point(P)) void {
            if (self.has_contour and !self.closed_) {
                self.close() catch @panic("out of memory");
            }
            self.start = to;
            self.current = to;
            self.has_contour = true;
            self.closed_ = false;
        }

        /// Draws a straight line from the current point to `to`.
        pub fn line_to(self: *Self, to: Point(P)) !void {
            if (!self.has_contour) {
                self.start = to;
                self.current = to;
                self.has_contour = true;
                self.closed_ = false;
                return;
            }
            if (to.x != self.current.x or to.y != self.current.y) {
                const c = PathCurve.line(self.current, to);
                try self.curves.append(self.allocator, c);
                self.include_curve(c);
                self.current = to;
                self.closed_ = false;
            }
        }

        /// Draws a curve from the current point to `to` using quadratic control point `ctrl`.
        pub fn curve_to(self: *Self, to: Point(P), ctrl: Point(P)) !void {
            if (!self.has_contour) {
                self.start = to;
                self.current = to;
                self.has_contour = true;
                self.closed_ = false;
                return;
            }
            if (to.x == self.current.x and to.y == self.current.y and ctrl.x == self.current.x and ctrl.y == self.current.y) {
                return;
            }
            const before = self.curves.items.len;
            try PathCurve.push_monotone(&self.curves, self.allocator, self.current, ctrl, to);
            for (self.curves.items[before..]) |c| self.include_curve(c);
            self.current = to;
            self.closed_ = false;
        }

        /// Closes the current contour back to `start`.
        pub fn close(self: *Self) !void {
            if (!self.has_contour or self.closed_) return;
            try self.line_to(self.start);
            self.closed_ = true;
        }

        fn include_curve(self: *Self, c: PathCurve) void {
            const cb = Bounds(P).from_corners(
                .{ .x = c.min_x(), .y = c.p0.y },
                .{ .x = c.max_x(), .y = c.p1.y },
            );
            if (self.curves.items.len == 1) {
                self.bounds = cb;
                self.paint_bounds_ = cb;
            } else {
                self.bounds = self.bounds.@"union"(cb);
                self.paint_bounds_ = self.paint_bounds_.@"union"(cb);
            }
        }

        fn recompute_bounds(self: *Self) void {
            if (self.curves.items.len == 0) {
                self.bounds = .{};
                self.paint_bounds_ = .{};
                return;
            }
            const inf = std.math.inf(f32);
            var min_pt: Point(P) = .{ .x = inf, .y = inf };
            var max_pt: Point(P) = .{ .x = -inf, .y = -inf };
            for (self.curves.items) |c| {
                min_pt.x = @min(min_pt.x, c.min_x());
                max_pt.x = @max(max_pt.x, c.max_x());
                min_pt.y = @min(min_pt.y, c.p0.y);
                max_pt.y = @max(max_pt.y, c.p1.y);
            }
            self.bounds = Bounds(P).from_corners(min_pt, max_pt);
            self.paint_bounds_ = self.bounds;
        }

        /// The tight path bounds (without tile margin), used for gradient/pattern evaluation.
        pub fn paint_bounds(self: *const Self) Bounds(P) {
            if (self.tiles) |*t| return t.bounds();
            return self.paint_bounds_;
        }

        pub fn tile_count(self: *const Self) usize {
            if (self.tiles) |*t| return t.tiles().len;
            return 0;
        }

        /// The path bounds intersected with its content mask.
        pub fn clipped_bounds(self: *const Self) Bounds(P) {
            return self.bounds.intersect(self.content_mask.bounds);
        }
    };
}

/// Paint operation recorded in order, so layers and primitives can be replayed.
pub const PaintOperation = union(enum) {
    primitive: struct { kind: PrimitiveKind, index: u32 },
    start_layer: Bounds(ScaledPixels),
    end_layer,
};

/// A drawable item stored in a scene. Paths own their vertices.
pub const Primitive = union(enum) {
    shadow: Shadow,
    quad: Quad,
    path: Path(ScaledPixels),
    underline: Underline,
    monochrome_sprite: MonochromeSprite,
    subpixel_sprite: SubpixelSprite,
    polychrome_sprite: PolychromeSprite,
    surface: PaintSurface,

    pub fn kind(self: *const Primitive) PrimitiveKind {
        return switch (self.*) {
            .shadow => .shadow,
            .quad => .quad,
            .path => .path,
            .underline => .underline,
            .monochrome_sprite => .monochrome_sprite,
            .subpixel_sprite => .subpixel_sprite,
            .polychrome_sprite => .polychrome_sprite,
            .surface => .surface,
        };
    }

    pub fn bounds(self: *const Primitive) Bounds(ScaledPixels) {
        return switch (self.*) {
            .shadow => |shadow| shadow.bounds,
            .quad => |quad| quad.bounds,
            .path => |path| path.bounds,
            .underline => |underline| underline.bounds,
            .monochrome_sprite => |sprite| sprite.bounds,
            .subpixel_sprite => |sprite| sprite.bounds,
            .polychrome_sprite => |sprite| sprite.bounds,
            .surface => |surface| surface.bounds,
        };
    }

    pub fn transformation(self: *const Primitive) TransformationMatrix {
        return switch (self.*) {
            .monochrome_sprite => |sprite| sprite.transformation,
            .subpixel_sprite => |sprite| sprite.transformation,
            else => TransformationMatrix.unit(),
        };
    }

    pub fn content_mask(self: *const Primitive) ContentMask(ScaledPixels) {
        return switch (self.*) {
            .shadow => |shadow| shadow.content_mask,
            .quad => |quad| quad.content_mask,
            .path => |path| path.content_mask,
            .underline => |underline| underline.content_mask,
            .monochrome_sprite => |sprite| sprite.content_mask,
            .subpixel_sprite => |sprite| sprite.content_mask,
            .polychrome_sprite => |sprite| sprite.content_mask,
            .surface => |surface| surface.content_mask,
        };
    }

    pub fn clipped_bounds(self: *const Primitive) Bounds(ScaledPixels) {
        const b = switch (self.*) {
            .shadow => |shadow| if (shadow.inset != 0 and !shadow.element_bounds.is_empty())
                shadow.element_bounds
            else if (shadow.inset == 0 and shadow.blur_radius > 0)
                shadow.bounds.dilate(3.0 * shadow.blur_radius)
            else
                shadow.bounds,
            else => self.transformation().transform_bounds(self.bounds()),
        };
        return b.intersect(self.content_mask().bounds);
    }

    /// Returns a deep copy; only paths allocate.
    pub fn clone(self: *const Primitive) !Primitive {
        return switch (self.*) {
            .path => |*path| .{ .path = try path.clone() },
            else => self.*,
        };
    }

    /// Releases resources owned by this primitive.
    pub fn deinit(self: *Primitive) void {
        switch (self.*) {
            .path => |*path| path.deinit(),
            else => {},
        }
    }
};

/// Kinds of primitive, ordered as they are drawn when orders tie.
pub const PrimitiveKind = enum {
    shadow,
    quad,
    path,
    underline,
    monochrome_sprite,
    subpixel_sprite,
    polychrome_sprite,
    surface,

    /// A primitive can share the draw order of the topmost primitive it overlaps
    /// if that primitive's kind is at most `max_shared_kind()`.
    pub fn max_shared_kind(self: PrimitiveKind) PrimitiveKind {
        return switch (self) {
            .monochrome_sprite => .underline,
            .subpixel_sprite => .monochrome_sprite,
            .polychrome_sprite => .subpixel_sprite,
            else => self,
        };
    }
};

/// Half-open index range into a scene's paint operations.
pub const Range = struct {
    start: usize,
    end: usize,
};

/// A run of same-kind primitives that can be drawn in one draw call.
pub fn SpriteBatch(comptime Sprite: type) type {
    return struct {
        texture_id: AtlasTextureId,
        sprites: []const Sprite,
    };
}

/// A contiguous run of primitives of one kind, borrowed from the scene.
pub const PrimitiveBatch = union(enum) {
    shadows: []const Shadow,
    quads: []const Quad,
    paths: []const Path(ScaledPixels),
    underlines: []const Underline,
    monochrome_sprites: SpriteBatch(MonochromeSprite),
    subpixel_sprites: SpriteBatch(SubpixelSprite),
    polychrome_sprites: SpriteBatch(PolychromeSprite),
    surfaces: []const PaintSurface,
};

/// Iterates the scene's primitives in draw order, emitting batches of same-kind runs.
pub const BatchIterator = struct {
    shadows: []const Shadow,
    quads: []const Quad,
    paths: []const Path(ScaledPixels),
    underlines: []const Underline,
    monochrome_sprites: []const MonochromeSprite,
    subpixel_sprites: []const SubpixelSprite,
    polychrome_sprites: []const PolychromeSprite,
    surfaces: []const PaintSurface,

    shadows_index: usize = 0,
    quads_index: usize = 0,
    paths_index: usize = 0,
    underlines_index: usize = 0,
    monochrome_sprites_index: usize = 0,
    subpixel_sprites_index: usize = 0,
    polychrome_sprites_index: usize = 0,
    surfaces_index: usize = 0,

    /// The next pending primitive of one kind, or an absent head sorted last.
    const Head = struct {
        order: DrawOrder,
        kind: PrimitiveKind,
        present: bool,
    };

    pub fn next(self: *BatchIterator) ?PrimitiveBatch {
        const heads = [_]Head{
            self.head(.shadow),
            self.head(.quad),
            self.head(.path),
            self.head(.underline),
            self.head(.monochrome_sprite),
            self.head(.subpixel_sprite),
            self.head(.polychrome_sprite),
            self.head(.surface),
        };

        var first_index: usize = 0;
        for (heads[1..], 1..) |candidate, index| {
            if (head_before(candidate, heads[first_index])) first_index = index;
        }
        const first = heads[first_index];
        if (!first.present) return null;

        // The batch extends while primitives sort before the next kind's head.
        var limit: Head = undefined;
        var have_limit = false;
        for (heads, 0..) |candidate, index| {
            if (index == first_index) continue;
            if (!have_limit or head_before(candidate, limit)) {
                limit = candidate;
                have_limit = true;
            }
        }

        return switch (first.kind) {
            .shadow => .{ .shadows = take(Shadow, self.shadows, &self.shadows_index, .shadow, limit) },
            .quad => .{ .quads = take(Quad, self.quads, &self.quads_index, .quad, limit) },
            .path => .{ .paths = take(Path(ScaledPixels), self.paths, &self.paths_index, .path, limit) },
            .underline => .{ .underlines = take(Underline, self.underlines, &self.underlines_index, .underline, limit) },
            .monochrome_sprite => blk: {
                const sprites = take(MonochromeSprite, self.monochrome_sprites, &self.monochrome_sprites_index, .monochrome_sprite, limit);
                break :blk .{ .monochrome_sprites = .{ .texture_id = sprites[0].tile.texture_id, .sprites = sprites } };
            },
            .subpixel_sprite => blk: {
                const sprites = take(SubpixelSprite, self.subpixel_sprites, &self.subpixel_sprites_index, .subpixel_sprite, limit);
                break :blk .{ .subpixel_sprites = .{ .texture_id = sprites[0].tile.texture_id, .sprites = sprites } };
            },
            .polychrome_sprite => blk: {
                const sprites = take(PolychromeSprite, self.polychrome_sprites, &self.polychrome_sprites_index, .polychrome_sprite, limit);
                break :blk .{ .polychrome_sprites = .{ .texture_id = sprites[0].tile.texture_id, .sprites = sprites } };
            },
            .surface => .{ .surfaces = take(PaintSurface, self.surfaces, &self.surfaces_index, .surface, limit) },
        };
    }

    fn head(self: *const BatchIterator, kind: PrimitiveKind) Head {
        return switch (kind) {
            .shadow => head_of(self.shadows, self.shadows_index, kind),
            .quad => head_of(self.quads, self.quads_index, kind),
            .path => head_of(self.paths, self.paths_index, kind),
            .underline => head_of(self.underlines, self.underlines_index, kind),
            .monochrome_sprite => head_of(self.monochrome_sprites, self.monochrome_sprites_index, kind),
            .subpixel_sprite => head_of(self.subpixel_sprites, self.subpixel_sprites_index, kind),
            .polychrome_sprite => head_of(self.polychrome_sprites, self.polychrome_sprites_index, kind),
            .surface => head_of(self.surfaces, self.surfaces_index, kind),
        };
    }

    fn head_of(items: anytype, index: usize, kind: PrimitiveKind) Head {
        if (index < items.len) return .{ .order = items[index].order, .kind = kind, .present = true };
        return .{ .order = std.math.maxInt(DrawOrder), .kind = kind, .present = false };
    }

    /// Orders heads by (order, kind); absent heads sort after all present ones.
    fn head_before(a: Head, b: Head) bool {
        if (a.present != b.present) return a.present;
        if (a.order != b.order) return a.order < b.order;
        return @intFromEnum(a.kind) < @intFromEnum(b.kind);
    }

    /// Consumes the run of `kind` starting at `index` that sorts before `limit`.
    /// Sprites additionally stop at a texture change.
    fn take(comptime T: type, items: []const T, index: *usize, kind: PrimitiveKind, limit: Head) []const T {
        const start = index.*;
        const same_texture = comptime @hasField(T, "tile");
        var end = start + 1;
        while (end < items.len) : (end += 1) {
            const item = items[end];
            const item_head: Head = .{ .order = item.order, .kind = kind, .present = true };
            if (!head_before(item_head, limit)) break;
            if (same_texture and !std.meta.eql(item.tile.texture_id, items[start].tile.texture_id)) break;
        }
        index.* = end;
        return items[start..end];
    }
};

const Layer = struct {
    primitives: std.ArrayList(Range) = .empty,
    bounds: Bounds(ScaledPixels) = .{},
    max_kind: PrimitiveKind = .shadow,
    max_shared_kind: PrimitiveKind = .surface,

    fn deinit(self: *Layer, allocator: std.mem.Allocator) void {
        self.primitives.deinit(allocator);
    }
};

const SortEntry = struct {
    key: u64,
    index: u32,
};

fn join_bounds(a: Bounds(ScaledPixels), b: Bounds(ScaledPixels)) Bounds(ScaledPixels) {
    if (a.is_empty()) return b;
    if (b.is_empty()) return a;
    return a.@"union"(b);
}

/// The per-frame list of primitives with draw-order assignment and batching.
pub const Scene = struct {
    allocator: std.mem.Allocator,
    paint_operations: std.ArrayList(PaintOperation) = .empty,
    primitive_bounds: BoundsTree(ScaledPixels),
    path_binner: path_winding.Binner,
    layer_stack: std.ArrayList(usize) = .empty,
    layers: std.ArrayList(Layer) = .empty,
    sort_keys: std.ArrayList(SortEntry) = .empty,
    remap_scratch: std.ArrayList(u32) = .empty,
    shadows: std.ArrayList(Shadow) = .empty,
    quads: std.ArrayList(Quad) = .empty,
    paths: std.ArrayList(Path(ScaledPixels)) = .empty,
    underlines: std.ArrayList(Underline) = .empty,
    monochrome_sprites: std.ArrayList(MonochromeSprite) = .empty,
    subpixel_sprites: std.ArrayList(SubpixelSprite) = .empty,
    polychrome_sprites: std.ArrayList(PolychromeSprite) = .empty,
    surfaces: std.ArrayList(PaintSurface) = .empty,
    animations: std.ArrayList(SpriteAnimation) = .empty,

    pub fn init(allocator: std.mem.Allocator) Scene {
        return .{
            .allocator = allocator,
            .primitive_bounds = BoundsTree(ScaledPixels).init(allocator),
            .path_binner = path_winding.Binner.init(allocator),
        };
    }

    pub fn deinit(self: *Scene) void {
        self.release_paths();
        self.release_layers();
        self.paint_operations.deinit(self.allocator);
        self.primitive_bounds.deinit();
        self.path_binner.deinit();
        self.layer_stack.deinit(self.allocator);
        self.layers.deinit(self.allocator);
        self.sort_keys.deinit(self.allocator);
        self.remap_scratch.deinit(self.allocator);
        self.paths.deinit(self.allocator);
        self.shadows.deinit(self.allocator);
        self.quads.deinit(self.allocator);
        self.underlines.deinit(self.allocator);
        self.monochrome_sprites.deinit(self.allocator);
        self.subpixel_sprites.deinit(self.allocator);
        self.polychrome_sprites.deinit(self.allocator);
        self.surfaces.deinit(self.allocator);
        self.animations.deinit(self.allocator);
    }

    /// Removes all primitives and layers, retaining allocated capacity.
    pub fn clear(self: *Scene) void {
        self.release_paths();
        self.release_layers();
        self.paint_operations.clearRetainingCapacity();
        self.primitive_bounds.clear();
        self.layer_stack.clearRetainingCapacity();
        self.layers.clearRetainingCapacity();
        self.shadows.clearRetainingCapacity();
        self.quads.clearRetainingCapacity();
        self.paths.clearRetainingCapacity();
        self.underlines.clearRetainingCapacity();
        self.monochrome_sprites.clearRetainingCapacity();
        self.subpixel_sprites.clearRetainingCapacity();
        self.polychrome_sprites.clearRetainingCapacity();
        self.surfaces.clearRetainingCapacity();
        self.animations.clearRetainingCapacity();
    }

    /// Inserts a sprite that `advance_animations` keeps moving (GPUI `insert_animated_sprite`).
    pub fn insert_animated_sprite(
        self: *Scene,
        sprite_in: MonochromeSprite,
        anim_in: SpriteAnimation,
    ) !void {
        var sprite = sprite_in;
        var animation = anim_in;
        sprite.animation = @enumFromInt(@as(u32, @intCast(self.animations.items.len)));
        animation.base_color = sprite.color;
        if (try self.tryInsertSimple(.monochrome_sprite, sprite)) {
            try self.animations.append(self.allocator, animation);
        }
    }

    /// How long the window may wait between presents while only scene animations need a frame.
    pub fn animation_frame_interval(self: *const Scene) ?u64 {
        if (self.animations.items.len == 0) return null;
        var min_interval: u64 = std.math.maxInt(u64);
        for (self.animations.items) |animation| {
            const interval = animation.transformation.min_frame_interval() orelse 0;
            if (interval < min_interval) min_interval = interval;
        }
        return min_interval;
    }

    /// Moves every animated sprite to its pose at `elapsed_ns` without rebuilding the scene.
    pub fn advance_animations(self: *Scene, elapsed_ns: u64) void {
        for (self.animations.items) |animation| {
            if (animation.sprite_index >= self.monochrome_sprites.items.len) continue;
            const sprite = &self.monochrome_sprites.items[animation.sprite_index];
            const pose = animation.transformation.at(elapsed_ns);
            sprite.transformation = pose.into_matrix(animation.center, animation.scale_factor);
            sprite.color = animation.base_color.opacity(pose.alpha_factor());
        }
    }

    /// Frees path vertices and tiles referenced from the path list.
    fn release_paths(self: *Scene) void {
        for (self.paths.items) |*path| path.deinit();
    }

    fn release_layers(self: *Scene) void {
        for (self.layers.items) |*layer| layer.deinit(self.allocator);
    }

    /// The number of recorded paint operations.
    pub fn len(self: *const Scene) usize {
        return self.paint_operations.items.len;
    }

    /// Starts a layer whose primitives share one draw order.
    pub fn push_layer(self: *Scene, bounds: Bounds(ScaledPixels)) !void {
        try self.paint_operations.ensureUnusedCapacity(self.allocator, 1);
        try self.layer_stack.ensureUnusedCapacity(self.allocator, 1);
        try self.layers.append(self.allocator, .{});
        self.layer_stack.appendAssumeCapacity(self.layers.items.len - 1);
        self.paint_operations.appendAssumeCapacity(.{ .start_layer = bounds });
    }

    /// Ends the innermost layer.
    pub fn pop_layer(self: *Scene) !void {
        try self.paint_operations.ensureUnusedCapacity(self.allocator, 1);
        _ = self.layer_stack.pop();
        if (self.layer_stack.items.len == 0) {
            for (self.layers.items) |*layer| {
                defer {
                    layer.deinit(self.allocator);
                    layer.* = .{};
                }
                try self.insert_layer(layer);
            }
            self.layers.clearRetainingCapacity();
        }
        self.paint_operations.appendAssumeCapacity(.end_layer);
    }

    fn insert_layer(self: *Scene, layer: *const Layer) !void {
        if (layer.primitives.items.len == 0) return;
        const order = try self.primitive_bounds.insert(layer.bounds, layer.max_kind, layer.max_shared_kind);
        for (layer.primitives.items) |range| {
            for (self.paint_operations.items[range.start..range.end]) |operation| {
                switch (operation) {
                    .primitive => |ref| switch (ref.kind) {
                        .shadow => self.shadows.items[ref.index].order = order,
                        .quad => self.quads.items[ref.index].order = order,
                        .path => self.paths.items[ref.index].order = order,
                        .underline => self.underlines.items[ref.index].order = order,
                        .monochrome_sprite => self.monochrome_sprites.items[ref.index].order = order,
                        .subpixel_sprite => self.subpixel_sprites.items[ref.index].order = order,
                        .polychrome_sprite => self.polychrome_sprites.items[ref.index].order = order,
                        .surface => self.surfaces.items[ref.index].order = order,
                    },
                    .start_layer, .end_layer => {},
                }
            }
        }
    }

    /// Adds a primitive, assigning its draw order. Takes ownership; invisible primitives are dropped.
    pub fn insert_primitive(self: *Scene, primitive: Primitive) !void {
        _ = try self.try_insert_primitive(primitive);
    }

    pub fn insert_shadow(self: *Scene, item: Shadow) !void {
        _ = try self.tryInsertSimple(.shadow, item);
    }

    pub fn insert_quad(self: *Scene, item: Quad) !void {
        _ = try self.tryInsertSimple(.quad, item);
    }

    pub fn insert_underline(self: *Scene, item: Underline) !void {
        _ = try self.tryInsertSimple(.underline, item);
    }

    pub fn insert_monochrome_sprite(self: *Scene, item: MonochromeSprite) !void {
        _ = try self.tryInsertSimple(.monochrome_sprite, item);
    }

    pub fn insert_subpixel_sprite(self: *Scene, item: SubpixelSprite) !void {
        _ = try self.tryInsertSimple(.subpixel_sprite, item);
    }

    pub fn insert_polychrome_sprite(self: *Scene, item: PolychromeSprite) !void {
        _ = try self.tryInsertSimple(.polychrome_sprite, item);
    }

    pub fn insert_surface(self: *Scene, item: PaintSurface) !void {
        _ = try self.tryInsertSimple(.surface, item);
    }

    pub fn insert_path(self: *Scene, item: Path(ScaledPixels)) !void {
        _ = try self.try_insert_primitive(.{ .path = item });
    }

    fn assignOrder(self: *Scene, clipped_bounds: Bounds(ScaledPixels), prim_kind: PrimitiveKind) !DrawOrder {
        if (self.layer_stack.getLastOrNull()) |layer_idx| {
            const layer = &self.layers.items[layer_idx];
            layer.bounds = join_bounds(layer.bounds, clipped_bounds);
            layer.max_kind = @enumFromInt(@max(@intFromEnum(layer.max_kind), @intFromEnum(prim_kind)));
            layer.max_shared_kind = @enumFromInt(@min(@intFromEnum(layer.max_shared_kind), @intFromEnum(prim_kind.max_shared_kind())));
            const op_index = self.paint_operations.items.len;
            if (layer.primitives.items.len > 0 and layer.primitives.items[layer.primitives.items.len - 1].end == op_index) {
                layer.primitives.items[layer.primitives.items.len - 1].end += 1;
            } else {
                try layer.primitives.append(self.allocator, .{ .start = op_index, .end = op_index + 1 });
            }
            return 0;
        }
        return self.primitive_bounds.insert(clipped_bounds, prim_kind, prim_kind.max_shared_kind());
    }

    fn tryInsertSimple(self: *Scene, comptime prim_kind: PrimitiveKind, item_in: anytype) !bool {
        const clipped_bounds = switch (prim_kind) {
            .shadow => blk: {
                const b = if (item_in.inset != 0 and !item_in.element_bounds.is_empty())
                    item_in.element_bounds
                else if (item_in.inset == 0 and item_in.blur_radius > 0)
                    item_in.bounds.dilate(3.0 * item_in.blur_radius)
                else
                    item_in.bounds;
                break :blk b.intersect(item_in.content_mask.bounds);
            },
            .monochrome_sprite, .subpixel_sprite => blk: {
                const b = if (item_in.transformation.is_unit())
                    item_in.bounds
                else
                    item_in.transformation.transform_bounds(item_in.bounds);
                break :blk b.intersect(item_in.content_mask.bounds);
            },
            .quad, .underline, .polychrome_sprite, .surface => item_in.bounds.intersect(item_in.content_mask.bounds),
            .path => comptime unreachable,
        };
        if (clipped_bounds.is_empty()) return false;

        try self.paint_operations.ensureUnusedCapacity(self.allocator, 1);
        const order = try self.assignOrder(clipped_bounds, prim_kind);
        const list = switch (prim_kind) {
            .shadow => &self.shadows,
            .quad => &self.quads,
            .underline => &self.underlines,
            .monochrome_sprite => &self.monochrome_sprites,
            .subpixel_sprite => &self.subpixel_sprites,
            .polychrome_sprite => &self.polychrome_sprites,
            .surface => &self.surfaces,
            .path => comptime unreachable,
        };
        const prim_index: u32 = @intCast(list.items.len);
        const slot = try list.addOne(self.allocator);
        slot.* = item_in;
        slot.order = order;
        self.paint_operations.appendAssumeCapacity(.{ .primitive = .{ .kind = prim_kind, .index = prim_index } });
        return true;
    }

    /// Returns whether the primitive was kept rather than clipped away.
    fn try_insert_primitive(self: *Scene, primitive: Primitive) !bool {
        switch (primitive) {
            .shadow => |v| return self.tryInsertSimple(.shadow, v),
            .quad => |v| return self.tryInsertSimple(.quad, v),
            .underline => |v| return self.tryInsertSimple(.underline, v),
            .monochrome_sprite => |v| return self.tryInsertSimple(.monochrome_sprite, v),
            .subpixel_sprite => |v| return self.tryInsertSimple(.subpixel_sprite, v),
            .polychrome_sprite => |v| return self.tryInsertSimple(.polychrome_sprite, v),
            .surface => |v| return self.tryInsertSimple(.surface, v),
            .path => {},
        }

        var owned = primitive.path;
        var moved = false;
        errdefer if (!moved) owned.deinit();

        if (owned.tiles == null) {
            try owned.close();
            var tiles = try self.path_binner.bin(owned.allocator, owned.curves.items, owned.even_odd, 1.0);
            tiles.retain_visible(owned.content_mask.bounds);
            owned.paint_bounds_ = tiles.bounds();
            owned.bounds = tiles.painted_bounds();
            owned.tiles = tiles;
        }
        if (owned.tiles.?.tiles().len == 0) {
            owned.deinit();
            moved = true;
            return false;
        }

        const clipped_bounds = owned.clipped_bounds();
        if (clipped_bounds.is_empty()) {
            owned.deinit();
            moved = true;
            return false;
        }

        try self.paint_operations.ensureUnusedCapacity(self.allocator, 1);
        const order = try self.assignOrder(clipped_bounds, .path);
        const prim_index: u32 = @intCast(self.paths.items.len);
        owned.order = order;
        owned.id = .{ .value = prim_index };
        try self.paths.append(self.allocator, owned);
        moved = true;
        self.paint_operations.appendAssumeCapacity(.{ .primitive = .{ .kind = .path, .index = prim_index } });
        return true;
    }

    /// Re-inserts the paint operations in `range` of `prev_scene` into this scene.
    pub fn replay(self: *Scene, range: Range, prev_scene: *const Scene) !void {
        const ops = prev_scene.paint_operations.items[range.start..range.end];
        try self.paint_operations.ensureUnusedCapacity(self.allocator, ops.len);
        for (ops) |operation| {
            switch (operation) {
                .primitive => |ref| switch (ref.kind) {
                    .shadow => _ = try self.tryInsertSimple(.shadow, prev_scene.shadows.items[ref.index]),
                    .quad => _ = try self.tryInsertSimple(.quad, prev_scene.quads.items[ref.index]),
                    .path => try self.insert_path(try prev_scene.paths.items[ref.index].clone()),
                    .underline => _ = try self.tryInsertSimple(.underline, prev_scene.underlines.items[ref.index]),
                    .monochrome_sprite => {
                        const sprite = prev_scene.monochrome_sprites.items[ref.index];
                        const anim_idx = @intFromEnum(sprite.animation);
                        if (sprite.animation != .none and anim_idx < prev_scene.animations.items.len) {
                            try self.insert_animated_sprite(sprite, prev_scene.animations.items[anim_idx]);
                        } else {
                            _ = try self.tryInsertSimple(.monochrome_sprite, sprite);
                        }
                    },
                    .subpixel_sprite => _ = try self.tryInsertSimple(.subpixel_sprite, prev_scene.subpixel_sprites.items[ref.index]),
                    .polychrome_sprite => _ = try self.tryInsertSimple(.polychrome_sprite, prev_scene.polychrome_sprites.items[ref.index]),
                    .surface => _ = try self.tryInsertSimple(.surface, prev_scene.surfaces.items[ref.index]),
                },
                .start_layer => |bounds| try self.push_layer(bounds),
                .end_layer => try self.pop_layer(),
            }
        }
    }

    fn remapKind(self: *Scene, kind: PrimitiveKind) void {
        const map = self.remap_scratch.items;
        for (self.paint_operations.items) |*op| {
            if (op.* == .primitive and op.primitive.kind == kind) {
                op.primitive.index = map[op.primitive.index];
            }
        }
    }

    /// Sorts every primitive list by draw order (and texture for sprites). Call before `batches`.
    pub fn finish(self: *Scene) void {
        std.debug.assert(self.layer_stack.items.len == 0);
        if (sort_in_place(Shadow, self.shadows.items, &self.sort_keys, &self.remap_scratch, self.allocator, order_key(Shadow))) {
            self.remapKind(.shadow);
        }
        if (sort_in_place(Quad, self.quads.items, &self.sort_keys, &self.remap_scratch, self.allocator, order_key(Quad))) {
            self.remapKind(.quad);
        }
        if (sort_in_place(Path(ScaledPixels), self.paths.items, &self.sort_keys, &self.remap_scratch, self.allocator, order_key(Path(ScaledPixels)))) {
            for (self.paths.items, 0..) |*p, i| p.id = .{ .value = i };
            self.remapKind(.path);
        }
        if (sort_in_place(Underline, self.underlines.items, &self.sort_keys, &self.remap_scratch, self.allocator, order_key(Underline))) {
            self.remapKind(.underline);
        }
        if (sort_in_place(MonochromeSprite, self.monochrome_sprites.items, &self.sort_keys, &self.remap_scratch, self.allocator, order_texture_key(MonochromeSprite))) {
            self.remapKind(.monochrome_sprite);
        }
        if (sort_in_place(SubpixelSprite, self.subpixel_sprites.items, &self.sort_keys, &self.remap_scratch, self.allocator, order_texture_key(SubpixelSprite))) {
            self.remapKind(.subpixel_sprite);
        }
        if (sort_in_place(PolychromeSprite, self.polychrome_sprites.items, &self.sort_keys, &self.remap_scratch, self.allocator, order_texture_key(PolychromeSprite))) {
            self.remapKind(.polychrome_sprite);
        }
        if (sort_in_place(PaintSurface, self.surfaces.items, &self.sort_keys, &self.remap_scratch, self.allocator, order_key(PaintSurface))) {
            self.remapKind(.surface);
        }

        // Sorting moved the sprites, so animations learn where theirs ended up.
        if (self.animations.items.len > 0) {
            for (self.monochrome_sprites.items, 0..) |sprite, index| {
                if (sprite.animation == .none) continue;
                const anim_idx = @intFromEnum(sprite.animation);
                if (anim_idx < self.animations.items.len) {
                    self.animations.items[anim_idx].sprite_index = index;
                }
            }
        }
    }

    /// Iterates the sorted primitives as batches. Call `finish` first.
    pub fn batches(self: *const Scene) BatchIterator {
        return .{
            .shadows = self.shadows.items,
            .quads = self.quads.items,
            .paths = self.paths.items,
            .underlines = self.underlines.items,
            .monochrome_sprites = self.monochrome_sprites.items,
            .subpixel_sprites = self.subpixel_sprites.items,
            .polychrome_sprites = self.polychrome_sprites.items,
            .surfaces = self.surfaces.items,
        };
    }
};

/// The depth step between consecutive quads in a frame with `quad_count` quads.
pub fn quad_depth_scale(quad_count: usize) f32 {
    const clamped = @min(quad_count, (1 << 24) - 1) + 1;
    const denominator = std.math.ceilPowerOfTwo(usize, clamped) catch (1 << 24);
    return 1.0 / @as(f32, @floatFromInt(denominator));
}

/// Maps a quad's index in `Scene.quads` to depth, with greater values closer.
pub fn quad_depth(quad_id: u32, scale: f32) f32 {
    return @min(@as(f32, @floatFromInt(quad_id + 1)) * scale, 1.0);
}

fn order_key(comptime T: type) fn (*const T) u64 {
    return struct {
        fn get(item: *const T) u64 {
            return @as(u64, item.order) << 32;
        }
    }.get;
}

fn order_texture_key(comptime T: type) fn (*const T) u64 {
    return struct {
        fn get(item: *const T) u64 {
            return (@as(u64, item.order) << 32) | @as(u64, item.tile.texture_id.index);
        }
    }.get;
}

fn sort_entry_less(_: void, lhs: SortEntry, rhs: SortEntry) bool {
    if (lhs.key != rhs.key) return lhs.key < rhs.key;
    return lhs.index < rhs.index;
}

fn oom() noreturn {
    @panic("out of memory");
}

/// Sorts small `(key, index)` pairs instead of the large primitives themselves, then permutes
/// primitives into place in a single pass of cycles. Ties preserve insertion order via `index`.
/// Uses O(N) counting sort when order/texture spans are small; falls back to pdq otherwise.
/// Returns `true` if `primitives` was reordered (and populates `remap` with `old_idx -> new_idx`).
fn sort_in_place(
    comptime T: type,
    primitives: []T,
    keys: *std.ArrayList(SortEntry),
    remap: *std.ArrayList(u32),
    allocator: std.mem.Allocator,
    comptime key_fn: fn (*const T) u64,
) bool {
    if (primitives.len <= 1) return false;

    const has_tex = comptime @hasField(T, "tile");
    var sorted = true;
    var prev_key = key_fn(&primitives[0]);
    var min_order: u32 = primitives[0].order;
    var max_order: u32 = primitives[0].order;
    var min_tex: u32 = if (has_tex) primitives[0].tile.texture_id.index else 0;
    var max_tex: u32 = min_tex;

    for (primitives[1..]) |*item| {
        const k = key_fn(item);
        if (k < prev_key) sorted = false;
        prev_key = k;
        if (item.order < min_order) min_order = item.order;
        if (item.order > max_order) max_order = item.order;
        if (has_tex) {
            const tx = item.tile.texture_id.index;
            if (tx < min_tex) min_tex = tx;
            if (tx > max_tex) max_tex = tx;
        }
    }
    if (sorted) return false;

    const n = primitives.len;
    keys.resize(allocator, n) catch oom();
    remap.resize(allocator, n) catch oom();

    const order_span: u64 = @as(u64, max_order - min_order) + 1;
    const tex_span: u64 = if (has_tex) @as(u64, max_tex - min_tex) + 1 else 1;

    if (order_span <= 512 and tex_span <= 256) {
        if (tex_span == 1) {
            // Single-pass O(N) counting sort by `order`; forward iteration preserves insertion order.
            var counts: [512]u32 = @splat(0);
            for (primitives) |*item| {
                counts[item.order - min_order] += 1;
            }
            var acc: u32 = 0;
            for (counts[0..@intCast(order_span)]) |*c| {
                const count = c.*;
                c.* = acc;
                acc += count;
            }
            for (primitives, 0..) |*item, old_idx| {
                const b = item.order - min_order;
                const new_idx = counts[b];
                counts[b] = new_idx + 1;
                remap.items[old_idx] = new_idx;
                keys.items[new_idx].index = @intCast(old_idx);
            }
        } else {
            // Two-pass O(N) LSD counting sort: first by texture_id.index, then by order.
            var tex_counts: [256]u32 = @splat(0);
            for (primitives) |*item| {
                tex_counts[item.tile.texture_id.index - min_tex] += 1;
            }
            var tex_acc: u32 = 0;
            for (tex_counts[0..@intCast(tex_span)]) |*c| {
                const count = c.*;
                c.* = tex_acc;
                tex_acc += count;
            }
            // Use `remap` temporarily to hold indices sorted by texture.
            for (primitives, 0..) |*item, old_idx| {
                const tb = item.tile.texture_id.index - min_tex;
                const pos = tex_counts[tb];
                tex_counts[tb] = pos + 1;
                remap.items[pos] = @intCast(old_idx);
            }

            var ord_counts: [512]u32 = @splat(0);
            for (primitives) |*item| {
                ord_counts[item.order - min_order] += 1;
            }
            var ord_acc: u32 = 0;
            for (ord_counts[0..@intCast(order_span)]) |*c| {
                const count = c.*;
                c.* = ord_acc;
                ord_acc += count;
            }
            // Iterate in texture-sorted order so ties on (order, tex) preserve original order;
            // store `old_idx` into `keys[new_idx].index`, then fill `remap[old_idx] = new_idx`.
            for (remap.items[0..n]) |old_idx| {
                const b = primitives[old_idx].order - min_order;
                const new_idx = ord_counts[b];
                ord_counts[b] = new_idx + 1;
                keys.items[new_idx].index = old_idx;
            }
            for (keys.items[0..n], 0..) |entry, new_idx| {
                remap.items[entry.index] = @intCast(new_idx);
            }
        }
    } else {
        for (primitives, 0..) |*item, index| {
            keys.items[index] = .{ .key = key_fn(item), .index = @intCast(index) };
        }
        std.sort.pdq(SortEntry, keys.items, {}, sort_entry_less);

        for (keys.items, 0..) |entry, new_idx| {
            remap.items[entry.index] = @intCast(new_idx);
        }
    }

    for (0..n) |start| {
        if (keys.items[start].index == start) continue;
        const displaced = primitives[start];
        var target = start;
        while (true) {
            const source = keys.items[target].index;
            keys.items[target].index = @intCast(target);
            if (source == start) {
                primitives[target] = displaced;
                break;
            }
            primitives[target] = primitives[source];
            target = source;
        }
    }
    return true;
}

fn rect(x: f32, y: f32, width: f32, height: f32) Bounds(ScaledPixels) {
    return .{ .origin = .{ .x = x, .y = y }, .size = .{ .width = width, .height = height } };
}

fn visible_mask() ContentMask(ScaledPixels) {
    return .{ .bounds = rect(0, 0, 10000, 10000) };
}

fn quad_at(x: f32, y: f32, width: f32, height: f32) Quad {
    return .{ .bounds = rect(x, y, width, height), .content_mask = visible_mask() };
}

fn underline_at(x: f32, y: f32, width: f32, height: f32) Underline {
    return .{ .bounds = rect(x, y, width, height), .content_mask = visible_mask(), .thickness = 1 };
}

fn sprite_at(x: f32, y: f32, texture_index: u32) MonochromeSprite {
    return .{
        .bounds = rect(x, y, 10, 10),
        .content_mask = visible_mask(),
        .tile = .{
            .texture_id = .{ .index = texture_index, .kind = .monochrome },
            .tile_id = .{ .value = 0 },
            .padding = 0,
            .bounds = .{ .origin = .{ .x = 0, .y = 0 }, .size = .{ .width = 10, .height = 10 } },
        },
    };
}

test "primitives outside their content mask are dropped" {
    var scene = Scene.init(testing.allocator);
    defer scene.deinit();

    var clipped = quad_at(0, 0, 10, 10);
    clipped.content_mask = .{ .bounds = rect(100, 100, 10, 10) };
    try scene.insert_primitive(.{ .quad = clipped });
    try testing.expectEqual(@as(usize, 0), scene.len());
    try testing.expectEqual(@as(usize, 0), scene.quads.items.len);
}

test "kind-aware batching shares order for quad + text and bumps when quad overlaps text" {
    var scene = Scene.init(testing.allocator);
    defer scene.deinit();

    // Background quad + text sprites on top share order 1; an overlapping quad bumps to order 2.
    try scene.insert_primitive(.{ .quad = quad_at(0, 0, 100, 20) });
    try scene.insert_primitive(.{ .monochrome_sprite = sprite_at(5, 5, 1) });
    try scene.insert_primitive(.{ .monochrome_sprite = sprite_at(20, 5, 1) });
    try scene.insert_primitive(.{ .quad = quad_at(10, 0, 30, 20) });
    scene.finish();

    try testing.expectEqual(@as(DrawOrder, 1), scene.quads.items[0].order);
    try testing.expectEqual(@as(DrawOrder, 1), scene.monochrome_sprites.items[0].order);
    try testing.expectEqual(@as(DrawOrder, 1), scene.monochrome_sprites.items[1].order);
    try testing.expectEqual(@as(DrawOrder, 2), scene.quads.items[1].order);

    var batches = scene.batches();
    try testing.expectEqual(@as(usize, 1), batches.next().?.quads.len);
    try testing.expectEqual(@as(usize, 2), batches.next().?.monochrome_sprites.sprites.len);
    try testing.expectEqual(@as(usize, 1), batches.next().?.quads.len);
    try testing.expectEqual(@as(?PrimitiveBatch, null), batches.next());
}

test "overlapping primitives respect kind-aware draw orders" {
    var scene = Scene.init(testing.allocator);
    defer scene.deinit();

    try scene.insert_primitive(.{ .quad = quad_at(0, 0, 10, 10) });
    try scene.insert_primitive(.{ .underline = underline_at(0, 0, 10, 2) });
    try scene.insert_primitive(.{ .quad = quad_at(0, 0, 10, 10) });

    try testing.expectEqual(@as(usize, 3), scene.len());
    try testing.expectEqual(@as(DrawOrder, 1), scene.quads.items[0].order);
    try testing.expectEqual(@as(DrawOrder, 1), scene.underlines.items[0].order);
    try testing.expectEqual(@as(DrawOrder, 2), scene.quads.items[1].order);
}

test "finish sorts primitives by draw order and preserves stability on ties" {
    var scene = Scene.init(testing.allocator);
    defer scene.deinit();

    // Order 1 (first quad), Order 1 (overlaps first quad), Order 2 (overlaps underline at order 1), Order 1 (non-overlapping).
    try scene.insert_primitive(.{ .quad = quad_at(0, 0, 10, 10) });
    try scene.insert_primitive(.{ .underline = underline_at(0, 0, 10, 2) });
    try scene.insert_primitive(.{ .quad = quad_at(0, 0, 10, 10) });
    try scene.insert_primitive(.{ .quad = quad_at(50, 50, 10, 10) });
    scene.finish();

    const orders = [_]DrawOrder{ scene.quads.items[0].order, scene.quads.items[1].order, scene.quads.items[2].order };
    try testing.expectEqualSlices(DrawOrder, &.{ 1, 1, 2 }, &orders);
    try testing.expectEqual(@as(f32, 0), scene.quads.items[0].bounds.origin.x);
    try testing.expectEqual(@as(f32, 50), scene.quads.items[1].bounds.origin.x);
    try testing.expectEqual(@as(f32, 0), scene.quads.items[2].bounds.origin.x);
}

test "fast sort_in_place handles already-sorted, reversed, and interleaved inputs stably" {
    var keys: std.ArrayList(SortEntry) = .empty;
    defer keys.deinit(testing.allocator);
    var remap: std.ArrayList(u32) = .empty;
    defer remap.deinit(testing.allocator);

    // Already sorted
    var sorted_quads = [_]Quad{
        .{ .order = 1, .bounds = rect(1, 0, 1, 1) },
        .{ .order = 1, .bounds = rect(2, 0, 1, 1) },
        .{ .order = 2, .bounds = rect(3, 0, 1, 1) },
    };
    try testing.expect(!sort_in_place(Quad, &sorted_quads, &keys, &remap, testing.allocator, order_key(Quad)));
    try testing.expectEqual(@as(f32, 1), sorted_quads[0].bounds.origin.x);
    try testing.expectEqual(@as(f32, 2), sorted_quads[1].bounds.origin.x);
    try testing.expectEqual(@as(f32, 3), sorted_quads[2].bounds.origin.x);

    // Reversed with ties
    var reversed_quads = [_]Quad{
        .{ .order = 3, .bounds = rect(10, 0, 1, 1) },
        .{ .order = 2, .bounds = rect(20, 0, 1, 1) },
        .{ .order = 2, .bounds = rect(21, 0, 1, 1) },
        .{ .order = 1, .bounds = rect(30, 0, 1, 1) },
        .{ .order = 1, .bounds = rect(31, 0, 1, 1) },
    };
    try testing.expect(sort_in_place(Quad, &reversed_quads, &keys, &remap, testing.allocator, order_key(Quad)));
    try testing.expectEqual(@as(f32, 30), reversed_quads[0].bounds.origin.x);
    try testing.expectEqual(@as(f32, 31), reversed_quads[1].bounds.origin.x);
    try testing.expectEqual(@as(f32, 20), reversed_quads[2].bounds.origin.x);
    try testing.expectEqual(@as(f32, 21), reversed_quads[3].bounds.origin.x);
    try testing.expectEqual(@as(f32, 10), reversed_quads[4].bounds.origin.x);
    try testing.expectEqualSlices(u32, &.{ 4, 2, 3, 0, 1 }, remap.items);

    // Interleaved sprites by (order, texture_id)
    var sprites = [_]MonochromeSprite{
        sprite_at(1, 0, 3),
        sprite_at(2, 0, 1),
        sprite_at(3, 0, 2),
        sprite_at(4, 0, 1),
    };
    sprites[0].order = 2;
    sprites[1].order = 2;
    sprites[2].order = 1;
    sprites[3].order = 2;
    try testing.expect(sort_in_place(MonochromeSprite, &sprites, &keys, &remap, testing.allocator, order_texture_key(MonochromeSprite)));
    try testing.expectEqual(@as(f32, 3), sprites[0].bounds.origin.x); // order 1, tex 2
    try testing.expectEqual(@as(f32, 2), sprites[1].bounds.origin.x); // order 2, tex 1 (first)
    try testing.expectEqual(@as(f32, 4), sprites[2].bounds.origin.x); // order 2, tex 1 (second)
    try testing.expectEqual(@as(f32, 1), sprites[3].bounds.origin.x); // order 2, tex 3
}

test "batches alternate between kinds in draw order" {
    var scene = Scene.init(testing.allocator);
    defer scene.deinit();

    try scene.insert_primitive(.{ .quad = quad_at(0, 0, 10, 10) });
    try scene.insert_primitive(.{ .underline = underline_at(0, 0, 10, 2) });
    try scene.insert_primitive(.{ .quad = quad_at(0, 0, 10, 10) });
    scene.finish();

    var batches = scene.batches();
    const first = batches.next().?;
    try testing.expectEqual(@as(usize, 1), first.quads.len);
    const second = batches.next().?;
    try testing.expectEqual(@as(usize, 1), second.underlines.len);
    const third = batches.next().?;
    try testing.expectEqual(@as(usize, 1), third.quads.len);
    try testing.expectEqual(@as(?PrimitiveBatch, null), batches.next());
}

test "sprite batches break on texture change" {
    var scene = Scene.init(testing.allocator);
    defer scene.deinit();

    try scene.insert_primitive(.{ .monochrome_sprite = sprite_at(0, 0, 1) });
    try scene.insert_primitive(.{ .monochrome_sprite = sprite_at(20, 0, 2) });
    try scene.insert_primitive(.{ .monochrome_sprite = sprite_at(40, 0, 2) });
    scene.finish();

    var batches = scene.batches();
    const first = batches.next().?.monochrome_sprites;
    try testing.expectEqual(@as(u32, 1), first.texture_id.index);
    try testing.expectEqual(@as(usize, 1), first.sprites.len);
    const second = batches.next().?.monochrome_sprites;
    try testing.expectEqual(@as(u32, 2), second.texture_id.index);
    try testing.expectEqual(@as(usize, 2), second.sprites.len);
    try testing.expectEqual(@as(?PrimitiveBatch, null), batches.next());
}

test "layers assign their order to contained primitives and preserve paint order" {
    var scene = Scene.init(testing.allocator);
    defer scene.deinit();

    try scene.push_layer(rect(0, 0, 100, 100));
    try scene.insert_primitive(.{ .quad = quad_at(0, 0, 10, 10) });
    try scene.insert_primitive(.{ .quad = quad_at(20, 20, 10, 10) });
    try scene.pop_layer();

    try testing.expectEqual(@as(usize, 4), scene.len());
    try testing.expectEqual(@as(DrawOrder, 1), scene.quads.items[0].order);
    try testing.expectEqual(@as(DrawOrder, 1), scene.quads.items[1].order);

    // Nested layers are drawn above their parents.
    var nested = Scene.init(testing.allocator);
    defer nested.deinit();
    try nested.push_layer(rect(0, 0, 100, 100));
    try nested.insert_primitive(.{ .underline = underline_at(0, 0, 10, 10) });
    try nested.push_layer(rect(0, 0, 100, 100));
    try nested.insert_primitive(.{ .quad = quad_at(5, 0, 10, 10) });
    try nested.pop_layer();
    try nested.insert_primitive(.{ .underline = underline_at(5, 0, 10, 10) });
    try nested.pop_layer();
    nested.finish();

    var batches = nested.batches();
    try testing.expectEqual(@as(usize, 2), batches.next().?.underlines.len);
    try testing.expectEqual(@as(usize, 1), batches.next().?.quads.len);
    try testing.expectEqual(@as(?PrimitiveBatch, null), batches.next());
}

test "quad_depth_scale and quad_depth are monotonic in (0, 1]" {
    const scale0 = quad_depth_scale(0);
    try testing.expectEqual(@as(f32, 1.0), scale0);
    try testing.expectEqual(@as(f32, 1.0), quad_depth(0, scale0));

    const count: usize = 5;
    const scale = quad_depth_scale(count);
    var prev: f32 = 0.0;
    for (0..count + 1) |i| {
        const d = quad_depth(@intCast(i), scale);
        try testing.expect(d > prev);
        try testing.expect(d <= 1.0);
        prev = d;
    }
}

test "replay copies paint operations from another scene" {
    var source = Scene.init(testing.allocator);
    defer source.deinit();
    try source.insert_primitive(.{ .quad = quad_at(0, 0, 10, 10) });
    try source.push_layer(rect(0, 0, 50, 50));
    try source.insert_primitive(.{ .underline = underline_at(0, 0, 5, 5) });
    try source.pop_layer();

    var target = Scene.init(testing.allocator);
    defer target.deinit();
    try target.replay(.{ .start = 1, .end = source.len() }, &source);

    try testing.expectEqual(@as(usize, 3), target.len());
    try testing.expectEqual(@as(usize, 1), target.underlines.items.len);
    try testing.expectEqual(@as(usize, 0), target.quads.items.len);
}

test "paths are stored with their own binned curves and tiles" {
    var scene = Scene.init(testing.allocator);
    defer scene.deinit();

    var path = Path(ScaledPixels).new(testing.allocator, .{ .x = 0, .y = 0 });
    path.content_mask = visible_mask();
    path.move_to(.{ .x = 0, .y = 0 });
    try path.line_to(.{ .x = 10, .y = 0 });
    try path.line_to(.{ .x = 10, .y = 10 });
    try scene.insert_primitive(.{ .path = path });

    try testing.expectEqual(@as(usize, 1), scene.paths.items.len);
    try testing.expectEqual(@as(usize, 1), scene.len());
    try testing.expectEqual(@as(usize, 3), scene.paths.items[0].curves.items.len);
    try testing.expect(scene.paths.items[0].tile_count() > 0);
}

test "transformation matrix translate and scale" {
    const moved = TransformationMatrix.unit().translate(.{ .x = 10, .y = 20 });
    const moved_point = moved.apply(.{ .x = 1, .y = 2 });
    try testing.expectEqual(@as(f32, 11), moved_point.x);
    try testing.expectEqual(@as(f32, 22), moved_point.y);

    const scaled = TransformationMatrix.unit().scale(.{ .width = 2, .height = 3 });
    const scaled_point = scaled.apply(.{ .x = 1, .y = 1 });
    try testing.expectEqual(@as(f32, 2), scaled_point.x);
    try testing.expectEqual(@as(f32, 3), scaled_point.y);
}

test "animated sprites survive finish sorting and scene replay" {
    var source = Scene.init(testing.allocator);
    defer source.deinit();

    // Insert an animated sprite at order 2 and a static sprite at order 1 (via overlapping quad)
    // so sorting moves the animated sprite's index in `monochrome_sprites`.
    var animated = sprite_at(10, 10, 2);
    animated.color = color.red();
    const timed = svg_mod.TimedTransformation.rotation(std.time.ns_per_s, .{});
    const anim = SpriteAnimation.init(timed, .{ .x = 15, .y = 15 }, 1.0);
    try source.insert_animated_sprite(animated, anim);
    try source.insert_primitive(.{ .quad = quad_at(10, 10, 20, 20) });
    // Static sprite at order 1 in a separate region:
    try source.insert_primitive(.{ .monochrome_sprite = sprite_at(100, 100, 1) });
    source.finish();

    try testing.expectEqual(@as(?u64, 0), source.animation_frame_interval());
    source.advance_animations(250 * std.time.ns_per_ms);

    var found_anim = false;
    for (source.monochrome_sprites.items) |sp| {
        if (sp.animation != .none) {
            found_anim = true;
            try testing.expectApproxEqAbs(@as(f32, 0.0), sp.transformation.rotation_scale[0][0], 1e-4);
            try testing.expectApproxEqAbs(@as(f32, -1.0), sp.transformation.rotation_scale[0][1], 1e-4);
        }
    }
    try testing.expect(found_anim);

    var replayed = Scene.init(testing.allocator);
    defer replayed.deinit();
    try replayed.replay(.{ .start = 0, .end = source.len() }, &source);
    replayed.finish();
    try testing.expectEqual(@as(usize, 1), replayed.animations.items.len);
    replayed.advance_animations(500 * std.time.ns_per_ms);
    for (replayed.monochrome_sprites.items) |sp| {
        if (sp.animation != .none) {
            try testing.expectApproxEqAbs(@as(f32, -1.0), sp.transformation.rotation_scale[0][0], 1e-4);
        }
    }
}

test "replay after out-of-order finish sort replays exact sub-range primitives" {
    var source = Scene.init(testing.allocator);
    defer source.deinit();

    // Op 0..2: prefix quads at (0,0) -> order 1, (0,0) -> order 2.
    try source.insert_primitive(.{ .quad = quad_at(0, 0, 10, 10) });
    try source.insert_primitive(.{ .quad = quad_at(0, 0, 10, 10) });
    const range_start = source.len();
    // Op 2..5 (cached sub-range): distinct quads & sprite that get reordered by finish().
    // Quad at (50,50) gets order 1 (moves before order 2 quad in source.quads!).
    var q_sub1 = quad_at(50, 50, 12, 12);
    q_sub1.border_widths = Edges(ScaledPixels).all(3);
    try source.insert_primitive(.{ .quad = q_sub1 });
    // Quad overlapping (50,50) gets order 2.
    var q_sub2 = quad_at(50, 50, 14, 14);
    q_sub2.border_widths = Edges(ScaledPixels).all(5);
    try source.insert_primitive(.{ .quad = q_sub2 });
    // Interleaved sprites of different textures that get reordered by finish().
    try source.insert_primitive(.{ .monochrome_sprite = sprite_at(100, 100, 7) });
    try source.insert_primitive(.{ .monochrome_sprite = sprite_at(200, 200, 1) });
    const range_end = source.len();

    // Op 6: trailing quad at (500,500) -> order 1 (sorts before order 2 quads!).
    try source.insert_primitive(.{ .quad = quad_at(500, 500, 8, 8) });

    // finish() permutes both quads and monochrome_sprites out of insertion order.
    source.finish();

    var replayed = Scene.init(testing.allocator);
    defer replayed.deinit();
    try replayed.replay(.{ .start = range_start, .end = range_end }, &source);
    replayed.finish();

    // Only the 2 quads and 2 sprites from range_start..range_end should be in replayed.
    try testing.expectEqual(@as(usize, 2), replayed.quads.items.len);
    try testing.expectEqual(@as(f32, 3), replayed.quads.items[0].border_widths.top);
    try testing.expectEqual(@as(f32, 5), replayed.quads.items[1].border_widths.top);
    try testing.expectEqual(@as(usize, 2), replayed.monochrome_sprites.items.len);
    // Sprite tex 1 and tex 7 were both replayed (sorted to tex 1 then tex 7 by finish()).
    try testing.expectEqual(@as(u32, 1), replayed.monochrome_sprites.items[0].tile.texture_id.index);
    try testing.expectEqual(@as(f32, 200), replayed.monochrome_sprites.items[0].bounds.origin.x);
    try testing.expectEqual(@as(u32, 7), replayed.monochrome_sprites.items[1].tile.texture_id.index);
    try testing.expectEqual(@as(f32, 100), replayed.monochrome_sprites.items[1].bounds.origin.x);
}
