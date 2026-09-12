//! Minimal `ItemVariationStore` port for CFF2 blend support.
//!
//! `read-fonts` 0.41.0 `tables/variations.rs` subset: the item variation store
//! header, item variation data region indexes and the variation region list
//! with `VariationRegion::compute_scalar`. CFF2 charstrings and private DICTs
//! only need region scalars (the deltas are already on the operand stack), so
//! delta-set decoding is deliberately absent. `compute_scalar` follows the
//! exact `Fixed`/`F2Dot14` operation order of the Rust original.

const std = @import("std");
const sfnt = @import("sfnt.zig");
const fixed = @import("../fixed.zig");

pub const Fixed = fixed.Fixed;

pub const Error = error{
    Truncated,
    OutOfBounds,
    InvalidVariationStoreIndex,
};

/// `ItemVariationStore` header plus the raw subtable slices.
pub const ItemVariationStore = struct {
    /// Store bytes; all internal offsets resolve relative to this slice.
    data: []const u8,
    format: u16,
    variation_region_list_offset: u32,
    item_variation_data_count: u16,

    pub fn parse(data: []const u8) Error!ItemVariationStore {
        if (data.len < 8) return error.Truncated;
        return .{
            .data = data,
            .format = sfnt.readU16(data, 0).?,
            .variation_region_list_offset = sfnt.readU32(data, 2).?,
            .item_variation_data_count = sfnt.readU16(data, 6).?,
        };
    }

    /// `variation_region_list()`; the offset resolves against the store start.
    pub fn variationRegionList(self: ItemVariationStore) Error!VariationRegionList {
        const start = self.variation_region_list_offset;
        if (start == 0 or start > self.data.len) return error.OutOfBounds;
        return VariationRegionList.parse(self.data[start..]);
    }

    /// `item_variation_data().get(index)`; a null/out-of-range offset is
    /// `error.InvalidVariationStoreIndex`, matching `BlendState`'s `ok_or`.
    pub fn itemVariationData(self: ItemVariationStore, index: usize) Error!ItemVariationData {
        if (index >= @as(usize, self.item_variation_data_count)) {
            return error.InvalidVariationStoreIndex;
        }
        const entry = 8 + 4 * index;
        const offset = sfnt.readU32(self.data, entry) orelse
            return error.InvalidVariationStoreIndex;
        if (offset == 0 or offset > self.data.len) return error.InvalidVariationStoreIndex;
        return ItemVariationData.parse(self.data[offset..]);
    }
};

/// `ItemVariationData`: only the fields blend evaluation reads.
pub const ItemVariationData = struct {
    data: []const u8,
    item_count: u16,
    word_delta_count: u16,
    region_index_count: u16,

    pub fn parse(data: []const u8) Error!ItemVariationData {
        if (data.len < 6) return error.Truncated;
        return .{
            .data = data,
            .item_count = sfnt.readU16(data, 0).?,
            .word_delta_count = sfnt.readU16(data, 2).?,
            .region_index_count = sfnt.readU16(data, 4).?,
        };
    }

    /// `region_indexes()`: a computed array of `region_index_count` u16s after
    /// the 6-byte header; a truncated array reads as empty, exactly like the
    /// generated `read_array(..).ok().unwrap_or_default()`.
    pub fn regionIndexes(self: ItemVariationData) []const u8 {
        const n = @as(usize, self.region_index_count) * 2;
        if (6 + n > self.data.len) return &.{};
        return self.data[6 .. 6 + n];
    }
};

/// `VariationRegionList`.
pub const VariationRegionList = struct {
    data: []const u8,
    axis_count: u16,
    region_count: u16,

    pub fn parse(data: []const u8) Error!VariationRegionList {
        if (data.len < 4) return error.Truncated;
        return .{
            .data = data,
            .axis_count = sfnt.readU16(data, 0).?,
            .region_count = sfnt.readU16(data, 2).?,
        };
    }

    /// One `VariationRegion`, or `error.OutOfBounds` when the region array is
    /// truncated (the generated `ComputedArray::get` path).
    pub fn region(self: VariationRegionList, index: usize) Error!VariationRegion {
        if (index >= self.region_count) return error.OutOfBounds;
        const region_len = @as(usize, self.axis_count) * 6;
        const start = 4 + region_len * index;
        if (start + region_len > self.data.len) return error.OutOfBounds;
        return .{ .data = self.data[start .. start + region_len], .axis_count = self.axis_count };
    }
};

/// One variation region: `axis_count` (start, peak, end) F2Dot14 triples.
pub const VariationRegion = struct {
    data: []const u8,
    axis_count: u16,

    /// `VariationRegion::compute_scalar`: the exact `Fixed` operation order.
    pub fn computeScalar(self: VariationRegion, coords: []const i16) Fixed {
        var scalar = Fixed.one;
        var i: usize = 0;
        while (i < self.axis_count) : (i += 1) {
            const off = i * 6;
            const start = fixed.F2Dot14.fromBits(sfnt.readI16(self.data, off).?).toFixed();
            const peak = fixed.F2Dot14.fromBits(sfnt.readI16(self.data, off + 2).?).toFixed();
            const end = fixed.F2Dot14.fromBits(sfnt.readI16(self.data, off + 4).?).toFixed();
            if (peak.bits == 0) continue;
            if (start.bits > peak.bits or peak.bits > end.bits or
                (start.bits < 0 and end.bits > 0))
            {
                continue;
            }
            const coord = if (i < coords.len)
                fixed.F2Dot14.fromBits(coords[i]).toFixed()
            else
                Fixed.zero;
            if (coord.bits < start.bits or coord.bits > end.bits) {
                return Fixed.zero;
            } else if (coord.bits == peak.bits) {
                continue;
            } else if (coord.bits < peak.bits) {
                scalar = scalar.mulDiv(Fixed.sub(coord, start), Fixed.sub(peak, start));
            } else {
                scalar = scalar.mulDiv(Fixed.sub(end, coord), Fixed.sub(end, peak));
            }
        }
        return scalar;
    }
};

// --------------------------------------------------------------------- tests

test "variation region scalar matches the example values" {
    // A single-axis region list with peak -0.5, matching `blend.rs`'s
    // example expectations at several coordinates.
    // start=-1.0 (0xC000), peak=-0.5 (0xE000), end=0.0 (0x0000)
    var buf: [10]u8 = undefined;
    std.mem.writeInt(u16, buf[0..2], 1, .big); // axis_count
    std.mem.writeInt(u16, buf[2..4], 1, .big); // region_count
    std.mem.writeInt(i16, buf[4..6], @bitCast(@as(u16, 0xC000)), .big);
    std.mem.writeInt(i16, buf[6..8], @bitCast(@as(u16, 0xE000)), .big);
    std.mem.writeInt(i16, buf[8..10], @bitCast(@as(u16, 0x0000)), .big);
    const list = try VariationRegionList.parse(&buf);
    const region = try list.region(0);
    // coord -1.0 -> scalar 0.0
    try std.testing.expectEqual(
        @as(i32, 0),
        region.computeScalar(&.{@bitCast(@as(u16, 0xC000))}).bits,
    );
    // coord -0.5 -> peak, scalar 1.0
    try std.testing.expectEqual(
        @as(i32, 1 << 16),
        region.computeScalar(&.{@bitCast(@as(u16, 0xE000))}).bits,
    );
    // coord -0.25 -> 0.5
    try std.testing.expectEqual(
        @as(i32, 0x8000),
        region.computeScalar(&.{@bitCast(@as(u16, 0xF000))}).bits,
    );
    // coord 0.0 -> 0.0
    try std.testing.expectEqual(@as(i32, 0), region.computeScalar(&.{0}).bits);
}

test "item variation store rejects missing subtables" {
    var buf: [8]u8 = undefined;
    std.mem.writeInt(u16, buf[0..2], 1, .big);
    std.mem.writeInt(u32, buf[2..6], 0, .big);
    std.mem.writeInt(u16, buf[6..8], 1, .big);
    const store = try ItemVariationStore.parse(&buf);
    try std.testing.expectError(
        error.InvalidVariationStoreIndex,
        store.itemVariationData(0),
    );
    try std.testing.expectError(error.OutOfBounds, store.variationRegionList());
}
