//! Port of gpui/src/scene.rs: the per-frame list of primitives, their draw order, and batching.
const std = @import("std");
const geometry = @import("geometry.zig");
const color = @import("color.zig");
const atlas = @import("atlas.zig");
const bounds_tree = @import("bounds_tree.zig");
const testing = std.testing;

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

pub const MonochromeSprite = struct {
    order: DrawOrder = 0,
    pad: u32 = 0,
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

/// A filled shape made of triangles, built by `PathBuilder` or by `move_to`/`line_to`/`curve_to`.
pub fn Path(comptime P: type) type {
    return struct {
        const Self = @This();

        allocator: std.mem.Allocator,
        id: PathId = .{},
        order: DrawOrder = 0,
        bounds: Bounds(P) = .{},
        content_mask: ContentMask(P) = .{},
        vertices: std.ArrayList(PathVertex(P)) = .empty,
        color: Background = Background.default,
        start: Point(P),
        current: Point(P),
        contour_count: usize = 0,

        /// Creates an empty path starting at `start`.
        pub fn new(allocator: std.mem.Allocator, start: Point(P)) Self {
            return .{
                .allocator = allocator,
                .start = start,
                .current = start,
                .bounds = .{ .origin = start, .size = .{} },
            };
        }

        pub fn deinit(self: *Self) void {
            self.vertices.deinit(self.allocator);
        }

        /// Returns a deep copy that owns its own vertices.
        pub fn clone(self: *const Self) !Self {
            var copy = self.*;
            copy.vertices = .empty;
            errdefer copy.deinit();
            try copy.vertices.appendSlice(self.allocator, self.vertices.items);
            return copy;
        }

        /// Scales this path by `factor`, returning a new path.
        pub fn scale(self: *const Self, factor: f32) !Path(ScaledPixels) {
            var scaled: Path(ScaledPixels) = .{
                .allocator = self.allocator,
                .id = self.id,
                .order = self.order,
                .bounds = self.bounds.scale(factor),
                .content_mask = self.content_mask.scale(factor),
                .color = self.color,
                .start = self.start.scale(factor),
                .current = self.current.scale(factor),
                .contour_count = self.contour_count,
            };
            errdefer scaled.deinit();
            try scaled.vertices.ensureTotalCapacityPrecise(self.allocator, self.vertices.items.len);
            for (self.vertices.items) |vertex| scaled.vertices.appendAssumeCapacity(vertex.scale(factor));
            return scaled;
        }

        /// Moves the start and current point to `to`.
        pub fn move_to(self: *Self, to: Point(P)) void {
            self.contour_count += 1;
            self.start = to;
            self.current = to;
        }

        /// Draws a straight line from the current point to `to`.
        pub fn line_to(self: *Self, to: Point(P)) !void {
            self.contour_count += 1;
            if (self.contour_count > 1) {
                try self.push_triangle(
                    .{ self.start, self.current, to },
                    .{ corner_st(0, 1), corner_st(0, 1), corner_st(0, 1) },
                );
            }
            self.current = to;
        }

        /// Draws a curve from the current point to `to` using quadratic control point `ctrl`.
        pub fn curve_to(self: *Self, to: Point(P), ctrl: Point(P)) !void {
            self.contour_count += 1;
            if (self.contour_count > 1) {
                try self.push_triangle(
                    .{ self.start, self.current, to },
                    .{ corner_st(0, 1), corner_st(0, 1), corner_st(0, 1) },
                );
            }
            try self.push_triangle(
                .{ self.current, ctrl, to },
                .{ corner_st(0, 0), corner_st(0.5, 0), corner_st(1, 1) },
            );
            self.current = to;
        }

        /// Appends a triangle, growing the path bounds to include its corners.
        pub fn push_triangle(self: *Self, xy: [3]Point(P), st: [3]Point(f32)) !void {
            for (xy) |corner| {
                self.bounds = self.bounds.@"union"(.{ .origin = corner, .size = .{} });
            }
            try self.vertices.ensureUnusedCapacity(self.allocator, 3);
            for (xy, st) |position, texture_position| {
                self.vertices.appendAssumeCapacity(.{
                    .xy_position = position,
                    .st_position = texture_position,
                    .content_mask = .{},
                });
            }
        }

        /// The path bounds intersected with its content mask.
        pub fn clipped_bounds(self: *const Self) Bounds(P) {
            return self.bounds.intersect(self.content_mask.bounds);
        }

        fn corner_st(x: f32, y: f32) Point(f32) {
            return .{ .x = x, .y = y };
        }
    };
}

/// Paint operation recorded in order, so layers and primitives can be replayed.
pub const PaintOperation = union(enum) {
    primitive: Primitive,
    start_layer: Bounds(ScaledPixels),
    end_layer,

    fn deinit(self: *PaintOperation) void {
        switch (self.*) {
            .primitive => |*primitive| primitive.deinit(),
            .start_layer, .end_layer => {},
        }
    }
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

/// The per-frame list of primitives with draw-order assignment and batching.
pub const Scene = struct {
    allocator: std.mem.Allocator,
    paint_operations: std.ArrayList(PaintOperation) = .empty,
    primitive_bounds: BoundsTree(ScaledPixels),
    layer_stack: std.ArrayList(DrawOrder) = .empty,
    shadows: std.ArrayList(Shadow) = .empty,
    quads: std.ArrayList(Quad) = .empty,
    paths: std.ArrayList(Path(ScaledPixels)) = .empty,
    underlines: std.ArrayList(Underline) = .empty,
    monochrome_sprites: std.ArrayList(MonochromeSprite) = .empty,
    subpixel_sprites: std.ArrayList(SubpixelSprite) = .empty,
    polychrome_sprites: std.ArrayList(PolychromeSprite) = .empty,
    surfaces: std.ArrayList(PaintSurface) = .empty,

    pub fn init(allocator: std.mem.Allocator) Scene {
        return .{
            .allocator = allocator,
            .primitive_bounds = BoundsTree(ScaledPixels).init(allocator),
        };
    }

    pub fn deinit(self: *Scene) void {
        self.release_paths();
        self.paint_operations.deinit(self.allocator);
        self.primitive_bounds.deinit();
        self.layer_stack.deinit(self.allocator);
        self.paths.deinit(self.allocator);
        self.shadows.deinit(self.allocator);
        self.quads.deinit(self.allocator);
        self.underlines.deinit(self.allocator);
        self.monochrome_sprites.deinit(self.allocator);
        self.subpixel_sprites.deinit(self.allocator);
        self.polychrome_sprites.deinit(self.allocator);
        self.surfaces.deinit(self.allocator);
    }

    /// Removes all primitives and layers, retaining allocated capacity.
    pub fn clear(self: *Scene) void {
        self.release_paths();
        self.paint_operations.clearRetainingCapacity();
        self.primitive_bounds.clear();
        self.layer_stack.clearRetainingCapacity();
        self.shadows.clearRetainingCapacity();
        self.quads.clearRetainingCapacity();
        self.paths.clearRetainingCapacity();
        self.underlines.clearRetainingCapacity();
        self.monochrome_sprites.clearRetainingCapacity();
        self.subpixel_sprites.clearRetainingCapacity();
        self.polychrome_sprites.clearRetainingCapacity();
        self.surfaces.clearRetainingCapacity();
    }

    /// Frees path vertices referenced from paint operations and the path list.
    fn release_paths(self: *Scene) void {
        for (self.paint_operations.items) |*operation| operation.deinit();
        for (self.paths.items) |*path| path.deinit();
    }

    /// The number of recorded paint operations.
    pub fn len(self: *const Scene) usize {
        return self.paint_operations.items.len;
    }

    /// Starts a layer whose primitives share one draw order.
    pub fn push_layer(self: *Scene, bounds: Bounds(ScaledPixels)) !void {
        try self.paint_operations.ensureUnusedCapacity(self.allocator, 1);
        try self.layer_stack.ensureUnusedCapacity(self.allocator, 1);
        const order = try self.primitive_bounds.insert(bounds);
        self.layer_stack.appendAssumeCapacity(order);
        self.paint_operations.appendAssumeCapacity(.{ .start_layer = bounds });
    }

    /// Ends the innermost layer.
    pub fn pop_layer(self: *Scene) !void {
        try self.paint_operations.ensureUnusedCapacity(self.allocator, 1);
        _ = self.layer_stack.pop();
        self.paint_operations.appendAssumeCapacity(.end_layer);
    }

    /// Adds a primitive, assigning its draw order. Takes ownership; invisible primitives are dropped.
    pub fn insert_primitive(self: *Scene, primitive: Primitive) !void {
        var owned = primitive;
        errdefer owned.deinit();

        const clipped_bounds = owned.bounds().intersect(owned.content_mask().bounds);
        if (clipped_bounds.is_empty()) {
            owned.deinit();
            return;
        }

        try self.paint_operations.ensureUnusedCapacity(self.allocator, 1);
        const order = if (self.layer_stack.getLastOrNull()) |layer_order|
            layer_order
        else
            try self.primitive_bounds.insert(clipped_bounds);

        switch (owned) {
            .shadow => |*shadow| {
                shadow.order = order;
                try self.shadows.append(self.allocator, shadow.*);
            },
            .quad => |*quad| {
                quad.order = order;
                try self.quads.append(self.allocator, quad.*);
            },
            .path => |*path| {
                path.order = order;
                path.id = .{ .value = self.paths.items.len };
                var copy = try path.clone();
                errdefer copy.deinit();
                try self.paths.append(self.allocator, copy);
            },
            .underline => |*underline| {
                underline.order = order;
                try self.underlines.append(self.allocator, underline.*);
            },
            .monochrome_sprite => |*sprite| {
                sprite.order = order;
                try self.monochrome_sprites.append(self.allocator, sprite.*);
            },
            .subpixel_sprite => |*sprite| {
                sprite.order = order;
                try self.subpixel_sprites.append(self.allocator, sprite.*);
            },
            .polychrome_sprite => |*sprite| {
                sprite.order = order;
                try self.polychrome_sprites.append(self.allocator, sprite.*);
            },
            .surface => |*surface| {
                surface.order = order;
                try self.surfaces.append(self.allocator, surface.*);
            },
        }

        self.paint_operations.appendAssumeCapacity(.{ .primitive = owned });
    }

    /// Re-inserts the paint operations in `range` of `prev_scene` into this scene.
    pub fn replay(self: *Scene, range: Range, prev_scene: *const Scene) !void {
        for (prev_scene.paint_operations.items[range.start..range.end]) |operation| {
            switch (operation) {
                .primitive => |primitive| try self.insert_primitive(try primitive.clone()),
                .start_layer => |bounds| try self.push_layer(bounds),
                .end_layer => try self.pop_layer(),
            }
        }
    }

    /// Sorts every primitive list by draw order (and texture for sprites). Call before `batches`.
    pub fn finish(self: *Scene) void {
        sort_by_order(Shadow, self.shadows.items);
        sort_by_order(Quad, self.quads.items);
        sort_by_order(Path(ScaledPixels), self.paths.items);
        sort_by_order(Underline, self.underlines.items);
        sort_by_order_and_texture(MonochromeSprite, self.monochrome_sprites.items);
        sort_by_order_and_texture(SubpixelSprite, self.subpixel_sprites.items);
        sort_by_order_and_texture(PolychromeSprite, self.polychrome_sprites.items);
        sort_by_order(PaintSurface, self.surfaces.items);
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

// Unstable sort: primitives sharing an order do not overlap, so their relative order does not matter.
fn sort_by_order(comptime T: type, items: []T) void {
    std.sort.pdq(T, items, {}, struct {
        fn less(_: void, lhs: T, rhs: T) bool {
            return lhs.order < rhs.order;
        }
    }.less);
}

fn sort_by_order_and_texture(comptime T: type, items: []T) void {
    std.sort.pdq(T, items, {}, struct {
        fn less(_: void, lhs: T, rhs: T) bool {
            if (lhs.order != rhs.order) return lhs.order < rhs.order;
            return lhs.tile.texture_id.index < rhs.tile.texture_id.index;
        }
    }.less);
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

test "overlapping primitives get increasing draw orders" {
    var scene = Scene.init(testing.allocator);
    defer scene.deinit();

    try scene.insert_primitive(.{ .quad = quad_at(0, 0, 10, 10) });
    try scene.insert_primitive(.{ .underline = underline_at(0, 0, 10, 2) });
    try scene.insert_primitive(.{ .quad = quad_at(0, 0, 10, 10) });

    try testing.expectEqual(@as(usize, 3), scene.len());
    try testing.expectEqual(@as(DrawOrder, 1), scene.quads.items[0].order);
    try testing.expectEqual(@as(DrawOrder, 2), scene.underlines.items[0].order);
    try testing.expectEqual(@as(DrawOrder, 3), scene.quads.items[1].order);
}

test "finish sorts primitives by draw order" {
    var scene = Scene.init(testing.allocator);
    defer scene.deinit();

    try scene.insert_primitive(.{ .quad = quad_at(0, 0, 10, 10) });
    try scene.insert_primitive(.{ .quad = quad_at(0, 0, 10, 10) });
    try scene.insert_primitive(.{ .quad = quad_at(50, 50, 10, 10) });
    scene.finish();

    const orders = [_]DrawOrder{ scene.quads.items[0].order, scene.quads.items[1].order, scene.quads.items[2].order };
    try testing.expectEqualSlices(DrawOrder, &.{ 1, 1, 2 }, &orders);
    try testing.expectEqual(@as(f32, 50), scene.quads.items[1].bounds.origin.x);
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

test "layers assign their order to contained primitives" {
    var scene = Scene.init(testing.allocator);
    defer scene.deinit();

    try scene.push_layer(rect(0, 0, 100, 100));
    try scene.insert_primitive(.{ .quad = quad_at(0, 0, 10, 10) });
    try scene.insert_primitive(.{ .quad = quad_at(20, 20, 10, 10) });
    try scene.pop_layer();

    try testing.expectEqual(@as(usize, 4), scene.len());
    try testing.expectEqual(@as(DrawOrder, 1), scene.quads.items[0].order);
    try testing.expectEqual(@as(DrawOrder, 1), scene.quads.items[1].order);
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

test "paths are stored with their own copy of the vertices" {
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
    try testing.expectEqual(@as(usize, 6), scene.paths.items[0].vertices.items.len);
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
