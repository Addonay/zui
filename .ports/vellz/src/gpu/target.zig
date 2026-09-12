//! Port of `vello_gpu/src/target.rs` (Apache-2.0 OR MIT).
//!
//! Render targets, texture bindings, and coordinate-space mappings used by the
//! draw encoder. Only the root-target subset participates in the first strip
//! pass; the layer/blend/filter binding types are ported alongside so the
//! schedule work can build on them without reshaping this file.
//!
//! CPU-safe: imports only `vellz.common.geometry`.

const std = @import("std");
const geometry = @import("../common/geometry.zig");

const RectU16 = geometry.RectU16;

/// The root target provided by the user.
pub const RootTarget = enum {
    /// The root target is the user-provided surface.
    user_surface,
    /// The root render target is an atlas layer.
    atlas_layer,

    /// Whether opaque strips may use this target's depth buffer.
    pub fn enableDepth(self: RootTarget) bool {
        return self == .user_surface;
    }

    /// A positional shift applied to all geometry for this target.
    pub fn geometryShift(_: RootTarget) [2]i32 {
        return .{ 0, 0 };
    }
};

/// The target for a draw pass.
pub const DrawPassTarget = union(enum) {
    /// Draw directly to the root.
    root: RootTarget,
    /// Draw to an intermediate layer texture.
    layer: LayerTextureId,

    /// Whether opaque strips may use this target's depth buffer (upstream
    /// `DrawPassTarget::enable_opaque`).
    pub fn enableOpaque(self: DrawPassTarget) bool {
        return switch (self) {
            .root => |target| target == .user_surface,
            .layer => false,
        };
    }
};

/// Even or odd intermediate texture group.
pub const TextureParity = enum(u8) {
    /// Texture group used by even layer depths.
    even = 0,
    /// Texture group used by odd layer depths.
    odd = 1,

    /// Parity of a layer nesting depth.
    pub fn fromParity(parity: usize) TextureParity {
        return if (parity & 1 == 0) .even else .odd;
    }

    /// The parity as a `usize` group index.
    pub fn getParity(self: TextureParity) usize {
        return @intFromEnum(self);
    }

    /// The other parity.
    pub fn opposite(self: TextureParity) TextureParity {
        return if (self == .even) .odd else .even;
    }
};

/// Identifies a page in an intermediate layer texture group.
pub const LayerTextureId = struct {
    /// The parity of the texture.
    texture_parity: TextureParity,
    /// The page index of the texture within the parity group.
    page_index: u16,

    /// Create a new layer texture id.
    pub fn new(texture_parity: TextureParity, page_index: u16) LayerTextureId {
        return .{ .texture_parity = texture_parity, .page_index = page_index };
    }
};

/// Output and optional child input used by a draw pass.
pub const DrawPassBindings = struct {
    /// Texture or root surface receiving the draw.
    target: DrawPassTarget,
    /// Child layer sampled by the draw, if any.
    child: ?LayerTextureId,

    /// Create a new binding pair.
    pub fn new(target: DrawPassTarget, child: ?LayerTextureId) DrawPassBindings {
        return .{ .target = target, .child = child };
    }
};

/// Target and temporary layer textures used by a filter pass.
pub const FilterPassBindings = struct {
    /// Texture containing the original input and receiving the final result.
    target: LayerTextureId,
    /// Opposite-parity texture used for filter ping-ponging.
    temporary: LayerTextureId,

    /// Create bindings, asserting the parities are opposite.
    pub fn new(target: LayerTextureId, temporary: LayerTextureId) FilterPassBindings {
        std.debug.assert(@intFromEnum(target.texture_parity) != @intFromEnum(temporary.texture_parity));
        return .{ .target = target, .temporary = temporary };
    }

    /// The final result texture.
    pub fn result(self: FilterPassBindings) LayerTextureId {
        return self.target;
    }

    /// The ping-pong texture.
    pub fn scratch(self: FilterPassBindings) LayerTextureId {
        return self.temporary;
    }

    /// The input texture for a step: the target on even steps, the temporary
    /// texture on odd steps.
    pub fn input(self: FilterPassBindings, step: usize) LayerTextureId {
        return if (step & 1 == 0) self.result() else self.scratch();
    }

    /// The output texture for a step: the temporary texture on even steps, the
    /// target on odd steps.
    pub fn output(self: FilterPassBindings, step: usize) LayerTextureId {
        return if (step & 1 == 0) self.scratch() else self.result();
    }
};

/// Target and child layer textures used by a blend pass.
pub const BlendPassBindings = struct {
    /// Layer serving as the blend backdrop and destination.
    target: LayerTextureId,
    /// Child layer serving as the blend source.
    child: LayerTextureId,

    /// Create bindings, asserting the parities are opposite.
    pub fn new(target: LayerTextureId, child: LayerTextureId) BlendPassBindings {
        std.debug.assert(@intFromEnum(target.texture_parity) != @intFromEnum(child.texture_parity));
        return .{ .target = target, .child = child };
    }

    /// The blend destination.
    pub fn blendTarget(self: BlendPassBindings) LayerTextureId {
        return self.target;
    }

    /// The texture for a parity: the child when its parity differs from the
    /// target's, otherwise the target.
    pub fn layerId(self: BlendPassBindings, parity: TextureParity) LayerTextureId {
        return if (@intFromEnum(self.target.texture_parity) == @intFromEnum(parity))
            self.target
        else
            self.child;
    }
};

/// The bound layer textures for a round.
pub const RoundBindings = struct {
    /// The bound page for each parity.
    pages: [2]?u16 = .{ null, null },

    /// Bindings for a single layer texture.
    pub fn new(id: LayerTextureId) RoundBindings {
        var pages = [_]?u16{ null, null };
        pages[id.texture_parity.getParity()] = id.page_index;
        return .{ .pages = pages };
    }

    /// Try to merge this binding with the other one, returning `null` when the
    /// two require different pages of the same parity.
    pub fn merge(self: RoundBindings, other: RoundBindings) ?RoundBindings {
        var result = self;
        for (&result.pages, other.pages) |*current, required| {
            if (required) |required_page| {
                if (current.*) |current_page| {
                    if (current_page != required_page) return null;
                } else {
                    current.* = required_page;
                }
            }
        }
        return result;
    }

    /// The bound texture for a parity, if present.
    pub fn layerId(self: RoundBindings, parity: TextureParity) ?LayerTextureId {
        const page_index = self.pages[parity.getParity()] orelse return null;
        return LayerTextureId.new(parity, page_index);
    }

    /// The required textures for this binding.
    pub fn requiredTextures(self: RoundBindings) [2]?LayerTextureId {
        return .{
            if (self.pages[0]) |page| LayerTextureId.new(.even, page) else null,
            if (self.pages[1]) |page| LayerTextureId.new(.odd, page) else null,
        };
    }
};

/// Rectangular region within a render target.
pub const TextureRegion = struct {
    /// Render target containing the region.
    target: LayerTextureId,
    /// Region in the layer texture.
    rect: RectU16,
};

/// Intermediate texture region paired with its scene-space layer bounds.
pub const LayerTextureRegion = struct {
    /// The texture region of the layer.
    texture: TextureRegion,
    /// Bounds of this layer in **viewport** coordinates.
    layer_bbox: RectU16,

    /// Restrict this region to the given scene-space bounds while preserving
    /// its texture mapping.
    pub fn cropTo(self: LayerTextureRegion, bounds: RectU16) LayerTextureRegion {
        const layer_bbox = self.layer_bbox.intersect(bounds);
        return .{
            .texture = .{
                .target = self.texture.target,
                .rect = self.textureRect(layer_bbox),
            },
            .layer_bbox = layer_bbox,
        };
    }

    /// Translate a scene-space rectangle within this layer to texture
    /// coordinates. The given bbox must be contained within the layer bbox.
    pub fn textureRect(self: LayerTextureRegion, bbox: RectU16) RectU16 {
        const x0 = self.texture.rect.x0 + (bbox.x0 - self.layer_bbox.x0);
        const y0 = self.texture.rect.y0 + (bbox.y0 - self.layer_bbox.y0);
        return RectU16.new(x0, y0, x0 + bbox.width(), y0 + bbox.height());
    }

    /// Layer textures never use the depth-buffer optimization (upstream
    /// `DrawTarget for LayerTextureRegion`).
    pub fn enableDepth(_: LayerTextureRegion) bool {
        return false;
    }

    /// We always render layers such that their bbox starts at (0, 0) in the
    /// allocated texture region, to minimize the consumed space.
    pub fn geometryShift(self: LayerTextureRegion) [2]i32 {
        return .{
            @as(i32, self.texture.rect.x0) - @as(i32, self.layer_bbox.x0),
            @as(i32, self.texture.rect.y0) - @as(i32, self.layer_bbox.y0),
        };
    }
};

// ---------------------------------------------------------------------------
// Tests (ported / adapted from `target.rs`)
// ---------------------------------------------------------------------------

const testing = std.testing;

test "root target depth and geometry shift" {
    try testing.expect(RootTarget.user_surface.enableDepth());
    try testing.expect(!RootTarget.atlas_layer.enableDepth());
    try testing.expectEqual([2]i32{ 0, 0 }, RootTarget.user_surface.geometryShift());
    try testing.expect((DrawPassTarget{ .root = .user_surface }).enableOpaque());
    try testing.expect(!(DrawPassTarget{ .root = .atlas_layer }).enableOpaque());
    try testing.expect(!(DrawPassTarget{
        .layer = LayerTextureId.new(.even, 0),
    }).enableOpaque());
}

test "texture parity" {
    try testing.expectEqual(TextureParity.even, TextureParity.fromParity(0));
    try testing.expectEqual(TextureParity.odd, TextureParity.fromParity(3));
    try testing.expectEqual(@as(usize, 1), TextureParity.odd.getParity());
    try testing.expectEqual(TextureParity.odd, TextureParity.even.opposite());
    try testing.expectEqual(TextureParity.even, TextureParity.odd.opposite());
}

test "texture pair constraints" {
    const even = RoundBindings.new(LayerTextureId.new(.even, 2));
    const odd = RoundBindings.new(LayerTextureId.new(.odd, 5));
    const empty = RoundBindings{};

    try testing.expectEqual(
        [2]?u16{ 2, null },
        even.merge(empty).?.pages,
    );
    try testing.expectEqual(
        [2]?u16{ 2, null },
        empty.merge(even).?.pages,
    );
    try testing.expectEqual(
        [2]?u16{ 2, 5 },
        even.merge(odd).?.pages,
    );
    try testing.expect(even.merge(RoundBindings.new(LayerTextureId.new(.even, 3))) == null);
    try testing.expect(odd.merge(RoundBindings.new(LayerTextureId.new(.odd, 6))) == null);

    try testing.expectEqual(
        LayerTextureId.new(.even, 2),
        even.layerId(.even).?,
    );
    try testing.expectEqual(@as(?LayerTextureId, null), even.layerId(.odd));
    try testing.expectEqual(
        [2]?LayerTextureId{ LayerTextureId.new(.even, 2), null },
        even.requiredTextures(),
    );
}

test "texture rect translation" {
    const layer = LayerTextureRegion{
        .texture = .{
            .target = LayerTextureId.new(.even, 0),
            .rect = RectU16.new(100, 200, 150, 250),
        },
        .layer_bbox = RectU16.new(10, 20, 60, 70),
    };

    try testing.expectEqual(
        RectU16.new(105, 210, 115, 222),
        layer.textureRect(RectU16.new(15, 30, 25, 42)),
    );
    try testing.expect(!layer.enableDepth());
    try testing.expectEqual([2]i32{ 90, 180 }, layer.geometryShift());
}

test "crop preserves texture mapping" {
    const layer = LayerTextureRegion{
        .texture = .{
            .target = LayerTextureId.new(.even, 0),
            .rect = RectU16.new(100, 200, 150, 250),
        },
        .layer_bbox = RectU16.new(10, 20, 60, 70),
    };

    const cropped = layer.cropTo(RectU16.new(15, 30, 25, 42));
    try testing.expectEqual(RectU16.new(105, 210, 115, 222), cropped.texture.rect);
    try testing.expectEqual(RectU16.new(15, 30, 25, 42), cropped.layer_bbox);
    try testing.expectEqual(layer.texture.target, cropped.texture.target);
}

test "filter pass ping-pong" {
    const bindings = FilterPassBindings.new(
        LayerTextureId.new(.even, 0),
        LayerTextureId.new(.odd, 0),
    );
    try testing.expectEqual(LayerTextureId.new(.even, 0), bindings.input(0));
    try testing.expectEqual(LayerTextureId.new(.odd, 0), bindings.output(0));
    try testing.expectEqual(LayerTextureId.new(.odd, 0), bindings.input(1));
    try testing.expectEqual(LayerTextureId.new(.even, 0), bindings.output(1));
}

test "blend pass bindings" {
    const bindings = BlendPassBindings.new(
        LayerTextureId.new(.even, 1),
        LayerTextureId.new(.odd, 2),
    );
    try testing.expectEqual(LayerTextureId.new(.even, 1), bindings.layerId(.even));
    try testing.expectEqual(LayerTextureId.new(.odd, 2), bindings.layerId(.odd));
}
