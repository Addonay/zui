//! Port of `vello_gpu/src/schedule/allocate.rs` (Apache-2.0 OR MIT).
//!
//! Atlas allocation for scheduled layer texture regions. One
//! `vellz.common.multi_atlas.Atlas` (the ported `guillotiere` allocator) backs
//! every intermediate texture page; pages are added on demand by the cursor.
//!
//! CPU-safe: imports only `vellz.common`.

const std = @import("std");
const common = @import("../../common/root.zig");
const filter_mod = @import("../filter.zig");
const target_mod = @import("../target.zig");

const RectangleAllocator = common.multi_atlas;
const AllocId = common.multi_atlas.AllocId;
const AtlasId = common.multi_atlas.AtlasId;
const RectU16 = common.geometry.RectU16;
const SizeU16 = common.geometry.SizeU16;
const LayerTextureId = target_mod.LayerTextureId;
const TextureParity = target_mod.TextureParity;
const TextureRegion = target_mod.TextureRegion;
const RecordedLayerKind = common.record.RecordedLayerKind;

/// Errors from atlas allocation. Upstream conflates these with the render
/// error; this port keeps them typed so the scheduler can refuse a scene
/// instead of panicking.
pub const Error = std.mem.Allocator.Error || error{
    /// A layer region (including padding) does not fit in a texture page.
    TooLarge,
};

/// An allocation and the round in which it was requested. Rounds are only
/// used for dependency ordering in this port; see `mod.zig`.
pub const Allocation = struct {
    /// The allocated texture region.
    allocation: AllocatedTextureRegion,
    /// Round starting from which this allocation is available.
    round_idx: usize,
};

/// Intermediate texture atlases used while constructing a schedule.
pub const Atlases = struct {
    /// The atlases for each texture parity.
    layer_atlases: [2]std.ArrayList(common.multi_atlas.Atlas),
    /// Whether the schedule requires the shared scratch texture.
    scratch_texture: bool,
    /// Dimensions of every atlas page and the scratch texture.
    texture_size: SizeU16,

    /// Create empty atlases for `texture_size` pages.
    pub fn init(texture_size: SizeU16) Atlases {
        return .{
            .layer_atlases = .{ .empty, .empty },
            .scratch_texture = false,
            .texture_size = texture_size,
        };
    }

    /// Release every page.
    pub fn deinit(self: *Atlases, allocator: std.mem.Allocator) void {
        for (&self.layer_atlases) |*atlases| {
            for (atlases.items) |*atlas| atlas.deinit(allocator);
            atlases.deinit(allocator);
        }
        self.* = undefined;
    }

    /// Whether the shared scratch texture was requested.
    pub fn scratchTexture(self: *const Atlases) bool {
        return self.scratch_texture;
    }

    /// The shared page size.
    pub fn textureSize(self: *const Atlases) SizeU16 {
        return self.texture_size;
    }

    /// Try to allocate `request` from the existing pages of its parity,
    /// preferring the lowest page index.
    pub fn allocateLayer(
        self: *Atlases,
        allocator: std.mem.Allocator,
        request: LayerAllocationRequest,
    ) Error!?AllocatedTextureRegion {
        const parity = request.texture_parity.getParity();
        for (0..self.layer_atlases[parity].items.len) |page_index| {
            const id = LayerTextureId.new(request.texture_parity, @intCast(page_index));
            const atlas = &self.layer_atlases[parity].items[page_index];
            if (try atlasAllocateRegion(allocator, atlas, id, request.region)) |allocation| {
                return allocation;
            }
        }
        return null;
    }

    /// Return an allocation to its page.
    pub fn deallocate(self: *Atlases, allocator: std.mem.Allocator, texture: AllocatedTextureRegion) Error!void {
        const id = texture.region.target;
        const atlas = &self.layer_atlases[id.texture_parity.getParity()].items[id.page_index];
        try atlasDeallocateRegion(allocator, atlas, texture);
    }

    /// Mark the shared scratch texture as required.
    pub fn requireScratchTexture(self: *Atlases) void {
        self.scratch_texture = true;
    }

    /// Append a new page to `texture_parity`.
    pub fn addLayerAtlas(
        self: *Atlases,
        allocator: std.mem.Allocator,
        texture_parity: TextureParity,
    ) std.mem.Allocator.Error!void {
        const parity = texture_parity.getParity();
        const page_index = self.layer_atlases[parity].items.len;
        const size = self.texture_size;
        const atlas = common.multi_atlas.Atlas.init(
            allocator,
            AtlasId.new(@intCast(page_index)),
            size.width(),
            size.height(),
        ) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            // The page size is validated to be non-zero when the renderer is
            // created, so the upstream asserts cannot fire here.
            else => unreachable,
        };
        errdefer {
            var copy = atlas;
            copy.deinit(allocator);
        }
        try self.layer_atlases[parity].append(allocator, atlas);
    }
};

/// A request for a layer allocation.
pub const LayerAllocationRequest = struct {
    /// Texture group from which the region must be allocated.
    texture_parity: TextureParity,
    /// Size and padding required within the selected page.
    region: RegionProps,

    /// Build a request for a recorded layer kind.
    pub fn new(bbox: RectU16, kind: RecordedLayerKind, texture_parity: TextureParity) LayerAllocationRequest {
        const padding: u16 = switch (kind) {
            .regular => 0,
            // Padding is needed because some filters use bilinear sampling;
            // the shaders assume transparent pixels around the region.
            .filter => filter_mod.FILTER_ATLAS_PADDING,
        };
        return .{
            .texture_parity = texture_parity,
            .region = .{
                .size = SizeU16.fromWh(bbox.width(), bbox.height()),
                .padding = padding,
            },
        };
    }

    /// Size of the page allocation needed to hold the region and its padding.
    pub fn allocationSize(self: LayerAllocationRequest) ?SizeU16 {
        return self.region.allocationSize();
    }
};

/// Size and padding of a region allocated from one atlas page.
pub const RegionProps = struct {
    /// Size of the usable region.
    size: SizeU16,
    /// Transparent padding reserved around the usable region.
    padding: u16,

    /// Size of the atlas allocation needed to hold the region and its padding.
    pub fn allocationSize(self: RegionProps) ?SizeU16 {
        const doubled = @mulWithOverflow(self.padding, 2);
        if (doubled[1] != 0) return null;
        return self.size.checkedAdd(doubled[0]);
    }
};

/// Texture region and allocator metadata needed to release it.
pub const AllocatedTextureRegion = struct {
    /// Usable portion of the allocation.
    region: TextureRegion,
    /// Padding surrounding the usable region.
    padding: u16,
    /// Identifier used to return the allocation to its atlas.
    alloc_id: AllocId,

    /// The region that must be cleared after use (padding is never drawn
    /// into, so it does not need clearing).
    pub fn clearRegion(self: AllocatedTextureRegion) TextureRegion {
        return self.region;
    }

    /// The full allocation rectangle including padding.
    pub fn allocationRegion(self: AllocatedTextureRegion) RectU16 {
        return RectU16.new(
            self.region.rect.x0 - self.padding,
            self.region.rect.y0 - self.padding,
            self.region.rect.x1 + self.padding,
            self.region.rect.y1 + self.padding,
        );
    }
};

fn atlasAllocateRegion(
    allocator: std.mem.Allocator,
    atlas: *common.multi_atlas.Atlas,
    target: LayerTextureId,
    props: RegionProps,
) Error!?AllocatedTextureRegion {
    const padding = props.padding;
    const width = props.size.width();
    const height = props.size.height();
    const allocation_size = props.allocationSize() orelse return error.TooLarge;
    const allocation = (try atlas.allocate(allocator, allocation_size.width(), allocation_size.height())) orelse return null;
    const x = allocation.x + padding;
    const y = allocation.y + padding;
    return .{
        .region = .{
            .target = target,
            .rect = RectU16.new(x, y, x + width, y + height),
        },
        .padding = padding,
        .alloc_id = allocation.id,
    };
}

fn atlasDeallocateRegion(
    allocator: std.mem.Allocator,
    atlas: *common.multi_atlas.Atlas,
    texture: AllocatedTextureRegion,
) Error!void {
    const allocation_region = texture.allocationRegion();
    atlas.deallocate(
        allocator,
        texture.alloc_id,
        allocation_region.width(),
        allocation_region.height(),
    ) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        // A failed deallocation of a live region is a scheduler bug; the
        // allocation id is always taken from this atlas.
        error.InvalidAllocationId => unreachable,
    };
}

// ---------------------------------------------------------------------------
// Tests (ported / adapted from `allocate.rs`)
// ---------------------------------------------------------------------------

const testing = std.testing;

fn makeRequest(texture_parity: TextureParity, size: SizeU16, padding: u16) LayerAllocationRequest {
    return .{
        .texture_parity = texture_parity,
        .region = .{ .size = size, .padding = padding },
    };
}

test "layer requests" {
    const bbox = RectU16.new(4, 8, 20, 32);
    const regular = LayerAllocationRequest.new(bbox, .regular, .odd);
    try testing.expectEqual(TextureParity.odd, regular.texture_parity);
    try testing.expectEqual(SizeU16.fromWh(16, 24), regular.region.size);
    try testing.expectEqual(@as(u16, 0), regular.region.padding);
    try testing.expectEqual(SizeU16.fromWh(16, 24), regular.allocationSize().?);

    const filter_kind: RecordedLayerKind = .{ .filter = .{
        // Only the union tag is read by `LayerAllocationRequest.new`.
        .filter_data = undefined,
        .placement = common.filter.FilterLayerPlacement.EMPTY,
    } };
    const filter = LayerAllocationRequest.new(bbox, filter_kind, .odd);
    try testing.expectEqual(@as(u16, filter_mod.FILTER_ATLAS_PADDING), filter.region.padding);
    try testing.expectEqual(
        SizeU16.fromWh(16 + filter_mod.FILTER_ATLAS_PADDING * 2, 24 + filter_mod.FILTER_ATLAS_PADDING * 2),
        filter.allocationSize().?,
    );
}

test "page selection" {
    const allocator = testing.allocator;
    const size = SizeU16.new(8);
    var atlases = Atlases.init(size);
    defer atlases.deinit(allocator);

    const even = makeRequest(.even, size, 0);
    const odd = makeRequest(.odd, size, 0);

    try atlases.addLayerAtlas(allocator, .even);
    const even_0 = (try atlases.allocateLayer(allocator, even)).?;
    try testing.expectEqual(LayerTextureId.new(.even, 0), even_0.region.target);
    // It's already full.
    try testing.expect((try atlases.allocateLayer(allocator, even)) == null);

    try atlases.addLayerAtlas(allocator, .even);
    const even_1 = (try atlases.allocateLayer(allocator, even)).?;
    try testing.expectEqual(LayerTextureId.new(.even, 1), even_1.region.target);

    try atlases.addLayerAtlas(allocator, .odd);
    const odd_0 = (try atlases.allocateLayer(allocator, odd)).?;
    try testing.expectEqual(LayerTextureId.new(.odd, 0), odd_0.region.target);

    try atlases.deallocate(allocator, even_0);
    const reused = (try atlases.allocateLayer(allocator, even)).?;
    try testing.expectEqual(LayerTextureId.new(.even, 0), reused.region.target);
}

test "page capacity" {
    const allocator = testing.allocator;
    var atlases = Atlases.init(SizeU16.fromWh(16, 8));
    defer atlases.deinit(allocator);

    const req = makeRequest(.even, SizeU16.new(8), 0);
    try atlases.addLayerAtlas(allocator, .even);

    const first = (try atlases.allocateLayer(allocator, req)).?;
    const second = (try atlases.allocateLayer(allocator, req)).?;
    try testing.expectEqual(LayerTextureId.new(.even, 0), first.region.target);
    try testing.expectEqual(LayerTextureId.new(.even, 0), second.region.target);
    try testing.expect((try atlases.allocateLayer(allocator, req)) == null);

    try atlases.addLayerAtlas(allocator, .even);
    const third = (try atlases.allocateLayer(allocator, req)).?;
    try testing.expectEqual(LayerTextureId.new(.even, 1), third.region.target);
}

test "padded reuse" {
    const allocator = testing.allocator;
    var atlas = try common.multi_atlas.Atlas.init(allocator, AtlasId.new(0), 8, 8);
    defer atlas.deinit(allocator);
    const target = LayerTextureId.new(.even, 0);
    const props = RegionProps{ .size = SizeU16.new(6), .padding = 1 };

    const allocation = (try atlasAllocateRegion(allocator, &atlas, target, props)).?;
    try testing.expectEqual(RectU16.new(1, 1, 7, 7), allocation.region.rect);
    try testing.expectEqual(RectU16.new(1, 1, 7, 7), allocation.clearRegion().rect);
    try testing.expectEqual(RectU16.new(0, 0, 8, 8), allocation.allocationRegion());
    try testing.expect((try atlasAllocateRegion(allocator, &atlas, target, props)) == null);

    try atlasDeallocateRegion(allocator, &atlas, allocation);
    const reused = (try atlasAllocateRegion(allocator, &atlas, target, props)).?;
    try testing.expectEqual(RectU16.new(1, 1, 7, 7), reused.region.rect);
}

test "oversized regions" {
    const allocator = testing.allocator;
    var atlas = try common.multi_atlas.Atlas.init(allocator, AtlasId.new(0), 8, 8);
    defer atlas.deinit(allocator);
    const target = LayerTextureId.new(.even, 0);

    try testing.expect((try atlasAllocateRegion(
        allocator,
        &atlas,
        target,
        .{ .size = SizeU16.fromWh(9, 8), .padding = 0 },
    )) == null);
    try testing.expect((try atlasAllocateRegion(
        allocator,
        &atlas,
        target,
        .{ .size = SizeU16.new(8), .padding = 1 },
    )) == null);
}
