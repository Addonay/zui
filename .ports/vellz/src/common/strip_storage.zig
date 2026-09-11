//! Port of vello_common strip_generator.rs (strip storage types only) (Apache-2.0 OR MIT).
//!
//! This file owns `StripStorage`, `GenerationMode`, and `PathDataRef`. The
//! `StripGenerator` state machine is not ported here: upstream
//! `strip_generator.rs` and `clip.rs` form an import cycle that Zig cannot
//! express, so the split fixed in `docs/port-contracts.md` puts the storage
//! and clip-path view in `common/strip_storage.zig`, and `clip.rs`
//! (`common/clip.zig`) consumes them; `StripGenerator` lands separately.
//!
//! Ownership/allocator note: `StripStorage` owns both `std.ArrayList`s and
//! takes an allocator on every growing operation (`extend`) and on `deinit`;
//! `init`/`initDefault` do not allocate. `PathDataRef` borrows the strip and
//! alpha buffers for the duration of the call it is passed to (upstream
//! `PathDataRef<'_>`), so it never outlives its owner and is never freed.

const std = @import("std");
const geometry = @import("geometry.zig");
const strip = @import("strip.zig");

const RectU16 = geometry.RectU16;
const Strip = strip.Strip;

/// The generation mode of the strip storage.
pub const GenerationMode = union(enum) {
    /// Clear strips before generating the new ones.
    replace,
    /// Don't clear strips, append to the existing buffer.
    append,
    /// Truncate strips to the given index before generating new ones,
    /// preserving strips in `[0..n]`.
    replace_after: usize,

    /// The upstream `#[default]`: `GenerationMode::Replace`.
    pub const default: GenerationMode = .replace;
};

/// A storage for strip-related data.
///
/// The buffers are append-only from the storage's perspective: `clear` keeps
/// capacity, `extend` appends another storage's strips and alphas, and the
/// `StripGenerator` truncates `strips` according to `generation_mode` before
/// generating (see upstream `render_with_clip`).
pub const StripStorage = struct {
    /// The strips in the storage.
    strips: std.ArrayList(Strip) = .empty,
    /// The alphas in the storage.
    alphas: std.ArrayList(u8) = .empty,
    /// How the next generation pass treats the existing strips.
    generation_mode: GenerationMode = .replace,

    /// Create a new strip storage with the given generation mode.
    pub fn init(generation_mode: GenerationMode) StripStorage {
        return .{ .generation_mode = generation_mode };
    }

    /// Create a new strip storage with the default (`replace`) mode.
    pub fn initDefault() StripStorage {
        return .{};
    }

    /// Release both buffers.
    pub fn deinit(self: *StripStorage, allocator: std.mem.Allocator) void {
        self.strips.deinit(allocator);
        self.alphas.deinit(allocator);
        self.* = .{};
    }

    /// Reset the storage, keeping allocated capacity (upstream `Vec::clear`).
    pub fn clear(self: *StripStorage) void {
        self.strips.clearRetainingCapacity();
        self.alphas.clearRetainingCapacity();
    }

    /// Get the current generation mode.
    pub fn generationMode(self: *const StripStorage) GenerationMode {
        return self.generation_mode;
    }

    /// Set the generation mode of the storage.
    pub fn setGenerationMode(self: *StripStorage, mode: GenerationMode) void {
        self.generation_mode = mode;
    }

    /// Whether the strip storage is empty.
    pub fn isEmpty(self: *const StripStorage) bool {
        return self.strips.items.len == 0 and self.alphas.items.len == 0;
    }

    /// Extend the current strip storage with the data from another storage.
    ///
    /// Both buffers are reserved before either is written, so on allocation
    /// failure the storage is left unchanged and the strips/alphas pair never
    /// becomes inconsistent (upstream cannot fail).
    pub fn extend(self: *StripStorage, allocator: std.mem.Allocator, other: *const StripStorage) !void {
        try self.strips.ensureUnusedCapacity(allocator, other.strips.items.len);
        try self.alphas.ensureUnusedCapacity(allocator, other.alphas.items.len);
        self.strips.appendSliceAssumeCapacity(other.strips.items);
        self.alphas.appendSliceAssumeCapacity(other.alphas.items);
    }
};

/// A borrowed view of strip data for clipping (upstream `clip::PathDataRef`).
pub const PathDataRef = struct {
    /// The strips. Borrowed; owned by the storage passed to the clip
    /// intersection call.
    strips: []const Strip,
    /// The alpha buffer. Borrowed; owned by the same storage as `strips`.
    alphas: []const u8,
    /// The bounding box of this path data, in pixel units.
    bbox: RectU16,
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;
const ONES16: [16]u8 = @splat(1);
const TWOS16: [16]u8 = @splat(2);
const THREES16: [16]u8 = @splat(3);

test "generation mode default and accessors" {
    try testing.expectEqual(GenerationMode.replace, GenerationMode.default);

    var storage = StripStorage.initDefault();
    defer storage.deinit(testing.allocator);
    try testing.expectEqual(GenerationMode.replace, storage.generationMode());
    try testing.expect(storage.isEmpty());

    storage.setGenerationMode(.append);
    try testing.expectEqual(GenerationMode.append, storage.generationMode());
    storage.setGenerationMode(.{ .replace_after = 3 });
    try testing.expectEqual(@as(usize, 3), storage.generationMode().replace_after);
}

test "strip storage clear extend and path data ref" {
    const allocator = testing.allocator;

    var storage = StripStorage.init(.replace);
    defer storage.deinit(allocator);

    try storage.strips.append(allocator, Strip.new(0, 0, 0, false));
    try storage.strips.append(allocator, Strip.sentinel(0, 16));
    try storage.alphas.appendSlice(allocator, &ONES16);
    try testing.expect(!storage.isEmpty());

    var other = StripStorage.init(.append);
    defer other.deinit(allocator);
    try other.strips.append(allocator, Strip.new(4, 0, 32, true));
    try other.alphas.appendSlice(allocator, &TWOS16);

    try storage.extend(allocator, &other);
    try testing.expectEqual(@as(usize, 3), storage.strips.items.len);
    try testing.expectEqual(@as(usize, 32), storage.alphas.items.len);
    try testing.expectEqual(@as(u32, 32), storage.strips.items[2].alphaIdx());
    try testing.expect(storage.strips.items[2].fillGap());

    const path_data = PathDataRef{
        .strips = storage.strips.items,
        .alphas = storage.alphas.items,
        .bbox = RectU16.new(0, 0, 4, 4),
    };
    try testing.expectEqual(@as(usize, 3), path_data.strips.len);
    try testing.expectEqual(@as(usize, 32), path_data.alphas.len);

    storage.clear();
    try testing.expect(storage.isEmpty());
    try testing.expect(storage.strips.items.len == 0);
    try testing.expect(storage.alphas.items.len == 0);
}

test "strip storage replace_after truncation model" {
    const allocator = testing.allocator;

    var storage = StripStorage.init(.{ .replace_after = 1 });
    defer storage.deinit(allocator);

    try storage.strips.append(allocator, Strip.new(0, 0, 0, false));
    try storage.strips.append(allocator, Strip.new(4, 0, 16, false));
    try storage.alphas.appendSlice(allocator, &THREES16);

    // The generator truncates strips to the preserved prefix before appending
    // (upstream `render_with_clip`); the alpha buffer is untouched by modes.
    storage.strips.shrinkRetainingCapacity(1);
    try testing.expectEqual(@as(usize, 1), storage.strips.items.len);
    try testing.expectEqual(@as(u32, 0), storage.strips.items[0].alphaIdx());
}
