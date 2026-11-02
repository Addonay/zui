//! Port of the `refineable` crate: `Refinement(T)` is the derived
//! "every field optional" type that GPUI generates with `#[derive(Refineable)]`.
//!
//! A struct opts nested fields into deep refinement by declaring
//! `pub const refineable_fields = .{ "field_a", "field_b" };`. Those fields get
//! `Refinement(FieldType)`; every other field becomes `?FieldType` (fields that
//! are already optional stay as they are).

const std = @import("std");
const Type = std.lang.Type;

fn isRefineableField(comptime T: type, comptime name: []const u8) bool {
    if (!@hasDecl(T, "refineable_fields")) return false;
    inline for (T.refineable_fields) |f| {
        if (std.mem.eql(u8, f, name)) return true;
    }
    return false;
}

fn isOptional(comptime T: type) bool {
    return @typeInfo(T) == .optional;
}

/// The refinement type of `T`.
pub fn Refinement(comptime T: type) type {
    return struct {
        pub const Base = T;
        pub const Fields = RefinementFields(T);
    }.Fields;
}

fn RefinementFields(comptime T: type) type {
    const info = @typeInfo(T).@"struct";
    const n = info.field_names.len;
    var names: [n][]const u8 = undefined;
    var types: [n]type = undefined;
    var attrs: [n]Type.Struct.FieldAttributes = undefined;
    for (info.field_names, info.field_types, 0..) |name, FT, i| {
        names[i] = name;
        if (isRefineableField(T, name)) {
            const R = Refinement(FT);
            types[i] = R;
            attrs[i] = .{ .default_value_ptr = &@as(R, .{}) };
        } else if (isOptional(FT)) {
            types[i] = FT;
            attrs[i] = .{ .default_value_ptr = &@as(FT, null) };
        } else {
            types[i] = ?FT;
            attrs[i] = .{ .default_value_ptr = &@as(?FT, null) };
        }
    }
    return @Struct(.auto, null, &names, &types, &attrs);
}

/// Applies `refinement` onto `base` in place (GPUI `Refineable::refine`).
pub fn refine(comptime T: type, base: *T, refinement: *const Refinement(T)) void {
    const info = @typeInfo(T).@"struct";
    inline for (info.field_names, info.field_types) |fname, ftype| {
        const r = &@field(refinement, fname);
        if (comptime isRefineableField(T, fname)) {
            refine(ftype, &@field(base, fname), r);
        } else if (comptime isOptional(ftype)) {
            if (r.* != null) @field(base, fname) = r.*;
        } else {
            if (r.*) |v| @field(base, fname) = v;
        }
    }
}

/// Returns `base` refined by `refinement` (GPUI `Refineable::refined`).
pub fn refined(comptime T: type, base: T, refinement: *const Refinement(T)) T {
    var out = base;
    refine(T, &out, refinement);
    return out;
}

/// Merges `other` into the refinement `self` (GPUI `Refinement::refine` on refinements).
pub fn merge(comptime T: type, self: *Refinement(T), other: *const Refinement(T)) void {
    const info = @typeInfo(T).@"struct";
    inline for (info.field_names, info.field_types) |fname, ftype| {
        if (comptime isRefineableField(T, fname)) {
            merge(ftype, &@field(self, fname), &@field(other, fname));
        } else {
            if (@field(other, fname) != null) @field(self, fname) = @field(other, fname);
        }
    }
}

/// True if the refinement sets nothing.
pub fn is_empty(comptime T: type, r: *const Refinement(T)) bool {
    const info = @typeInfo(T).@"struct";
    inline for (info.field_names, info.field_types) |fname, ftype| {
        if (comptime isRefineableField(T, fname)) {
            if (!is_empty(ftype, &@field(r, fname))) return false;
        } else if (@field(r, fname) != null) return false;
    }
    return true;
}

test "refinement basics" {
    const Inner = struct { a: f32 = 1, b: f32 = 2 };
    const Outer = struct {
        pub const refineable_fields = .{"inner"};
        inner: Inner = .{},
        c: u8 = 3,
        d: ?u8 = null,
    };
    var r: Refinement(Outer) = .{};
    try std.testing.expect(is_empty(Outer, &r));
    r.inner.b = 10;
    r.d = 7;
    const out = refined(Outer, .{}, &r);
    try std.testing.expectEqual(@as(f32, 1), out.inner.a);
    try std.testing.expectEqual(@as(f32, 10), out.inner.b);
    try std.testing.expectEqual(@as(u8, 3), out.c);
    try std.testing.expectEqual(@as(?u8, 7), out.d);
    var r2: Refinement(Outer) = .{};
    r2.c = 9;
    merge(Outer, &r, &r2);
    try std.testing.expectEqual(@as(?u8, 9), r.c);
    try std.testing.expectEqual(@as(?f32, 10), r.inner.b);
}
