//! Named grid-line and grid-area resolution.
//!
//! Taffy stores line positions in maps keyed by borrowed custom identifiers.
//! This Zig layer keeps the same source-order line lists while using slices as
//! the borrowed identifier representation. Resolution handles positive and
//! negative occurrences, implicit `<area>-start`/`<area>-end` names, and the
//! CSS fallback for names which do not exist.

const std = @import("std");
const geometry = @import("../../../geometry.zig");
const grid_style = @import("../../../style/grid.zig");

pub const NamedLine = struct {
    name: []const u8,
    index: i16,
};

pub const NamedArea = struct {
    name: []const u8,
    row: i16 = 0,
    column: i16 = 0,
    row_end: i16 = 0,
    column_end: i16 = 0,
};

pub const StrHasher = struct {
    value: []const u8,

    pub fn eql(self: StrHasher, other: []const u8) bool {
        return std.mem.eql(u8, self.value, other);
    }
    pub fn cmp(self: StrHasher, other: StrHasher) std.math.Order {
        return std.math.order(self.value, other.value);
    }
};

pub const GridLineNames = struct {
    names: []const []const u8 = &.{},
    offsets: []const u32 = &.{},

    pub fn is_empty(self: GridLineNames) bool {
        return self.names.len == 0;
    }
    pub fn line_count(self: GridLineNames) usize {
        return if (self.offsets.len > 0) self.offsets.len - 1 else 0;
    }
    pub fn line(self: GridLineNames, line_index: usize) []const []const u8 {
        if (line_index + 1 >= self.offsets.len) return &.{};
        return self.names[self.offsets[line_index]..self.offsets[line_index + 1]];
    }
    pub fn iter(self: GridLineNames) GridLineNamesIter {
        return .{ .source = self, .index = 0 };
    }
};

pub const GridLineNamesIter = struct {
    source: GridLineNames,
    index: usize = 0,

    pub fn next(self: *GridLineNamesIter) ?[]const []const u8 {
        if (self.index >= self.source.line_count()) return null;
        const result = self.source.line(self.index);
        self.index += 1;
        return result;
    }
    pub fn size_hint(self: GridLineNamesIter) usize {
        return self.source.line_count() -| self.index;
    }
};

pub const NamedLineResolver = struct {
    row_lines: []const NamedLine = &.{},
    column_lines: []const NamedLine = &.{},
    areas: []const NamedArea = &.{},
    explicit_column_count: u16 = 0,
    explicit_row_count: u16 = 0,
    area_column_count_value: u16 = 0,
    area_row_count_value: u16 = 0,

    pub fn new(row_lines: []const NamedLine, column_lines: []const NamedLine, areas: []const NamedArea, explicit_rows: u16, explicit_columns: u16) NamedLineResolver {
        var result = NamedLineResolver{ .row_lines = row_lines, .column_lines = column_lines, .areas = areas, .explicit_row_count = explicit_rows, .explicit_column_count = explicit_columns };
        for (areas) |area| {
            result.area_row_count_value = @max(result.area_row_count_value, @as(u16, @intCast(@max(area.row_end, 0))));
            result.area_column_count_value = @max(result.area_column_count_value, @as(u16, @intCast(@max(area.column_end, 0))));
        }
        return result;
    }

    /// Build the resolver's line lists from the nested style representation.
    /// The line-name slices remain borrowed, just like a Taffy style's cheap
    /// clone identifiers; only the ordered `NamedLine` records are copied.
    pub fn from_style(style: @import("../../../style/mod.zig").Style, row_auto_repetitions: u16, column_auto_repetitions: u16) NamedLineResolver {
        _ = row_auto_repetitions;
        _ = column_auto_repetitions;
        var result = NamedLineResolver{
            .explicit_row_count = @intCast(style.grid_template_rows.len),
            .explicit_column_count = @intCast(style.grid_template_columns.len),
        };
        for (style.grid_template_column_names, 0..) |names, line_index| for (names) |name| {
            result.column_lines = upsert_line_name_map(result.column_lines, name, @intCast(line_index + 1));
        };
        for (style.grid_template_row_names, 0..) |names, line_index| for (names) |name| {
            result.row_lines = upsert_line_name_map(result.row_lines, name, @intCast(line_index + 1));
        };
        if (style.grid_template_areas) |areas| {
            result.area_row_count_value = areas.row_count;
            result.area_column_count_value = areas.column_count;
        }
        return result;
    }

    pub fn set_explicit_column_count(self: *NamedLineResolver, count: u16) void {
        self.explicit_column_count = count;
    }
    pub fn set_explicit_row_count(self: *NamedLineResolver, count: u16) void {
        self.explicit_row_count = count;
    }
    pub fn set_area_counts(self: *NamedLineResolver, rows: u16, columns: u16) void {
        self.area_row_count_value = rows;
        self.area_column_count_value = columns;
    }
    pub fn area_column_count(self: NamedLineResolver) u16 {
        return self.area_column_count_value;
    }
    pub fn area_row_count(self: NamedLineResolver) u16 {
        return self.area_row_count_value;
    }

    fn lines_for(self: NamedLineResolver, axis: geometry.AbsoluteAxis) []const NamedLine {
        return if (axis == .horizontal) self.column_lines else self.row_lines;
    }

    fn find_line_index(self: NamedLineResolver, name: []const u8, index: i32, axis: geometry.AbsoluteAxis, end_is_end: bool) i16 {
        const wanted = if (index == 0) @as(i32, 1) else index;
        var matches: [256]i16 = undefined;
        var count: usize = 0;
        for (self.lines_for(axis)) |line| {
            if (std.mem.eql(u8, line.name, name) and count < matches.len) {
                matches[count] = line.index;
                count += 1;
            }
        }
        if (count == 0) {
            for (self.areas) |area| {
                const suffix = if (end_is_end) "-end" else "-start";
                var buffer: [256]u8 = undefined;
                const generated_name = std.fmt.bufPrint(&buffer, "{s}{s}", .{ area.name, suffix }) catch continue;
                if (std.mem.eql(u8, generated_name, name) and count < matches.len) {
                    matches[count] = if (axis == .horizontal) if (end_is_end) area.column_end else area.column else if (end_is_end) area.row_end else area.row;
                    count += 1;
                }
            }
        }
        if (count > 0) {
            const position = if (wanted > 0) @as(usize, @intCast(wanted - 1)) else count -| @as(usize, @intCast(-wanted));
            if (position < count) return matches[position];
        }
        const explicit = if (axis == .horizontal) self.explicit_column_count else self.explicit_row_count;
        return if (wanted > 0) @intCast(@as(i32, explicit) + 1 + wanted) else @intCast(-(@as(i32, explicit) + 1 + wanted));
    }

    pub fn resolve_line_names(self: NamedLineResolver, value: geometry.Line(grid_style.GridPlacement), axis: geometry.AbsoluteAxis) geometry.Line(grid_style.GridPlacement) {
        var start = value.start;
        var end = value.end;
        if (start == .named_line) start = resolve_placement(self, start, axis, false);
        if (end == .named_line) end = resolve_placement(self, end, axis, true);

        // A named span is resolved relative to the opposite definite line.
        // When neither edge is definite its name still determines the first
        // matching line in the requested direction; the placement stage may
        // then treat it as an ordinary span if no such line exists.
        if (start == .named_span) {
            const named = start.named_span;
            if (end == .line) {
                const end_line = end.line;
                if (self.find_line_before(named.name, named.count, axis, end_line)) |line| start = .{ .line = line };
            } else if (self.find_line_index(named.name, named.count, axis, false) != 0) {
                start = .{ .line = self.find_line_index(named.name, named.count, axis, false) };
            }
        }
        if (end == .named_span) {
            const named = end.named_span;
            if (start == .line) {
                const start_line = start.line;
                if (self.find_line_after(named.name, named.count, axis, start_line)) |line| end = .{ .line = line };
            } else if (self.find_line_index(named.name, named.count, axis, true) != 0) {
                end = .{ .line = self.find_line_index(named.name, named.count, axis, true) };
            }
        }
        return .{ .start = start, .end = end };
    }

    pub fn resolve_row_names(self: NamedLineResolver, value: geometry.Line(grid_style.GridPlacement)) geometry.Line(grid_style.GridPlacement) {
        return self.resolve_line_names(value, .vertical);
    }
    pub fn resolve_column_names(self: NamedLineResolver, value: geometry.Line(grid_style.GridPlacement)) geometry.Line(grid_style.GridPlacement) {
        return self.resolve_line_names(value, .horizontal);
    }

    fn find_line_before(self: NamedLineResolver, name: []const u8, occurrence: u16, axis: geometry.AbsoluteAxis, end_line: i16) ?i16 {
        var matches: [256]i16 = undefined;
        var count: usize = 0;
        for (self.lines_for(axis)) |line| if (std.mem.eql(u8, line.name, name) and line.index < end_line) {
            if (count < matches.len) matches[count] = line.index;
            count += 1;
        };
        const wanted = if (occurrence == 0) 1 else occurrence;
        return if (wanted > 0 and wanted <= count) matches[wanted - 1] else null;
    }

    fn find_line_after(self: NamedLineResolver, name: []const u8, occurrence: u16, axis: geometry.AbsoluteAxis, start_line: i16) ?i16 {
        var matches: [256]i16 = undefined;
        var count: usize = 0;
        for (self.lines_for(axis)) |line| if (std.mem.eql(u8, line.name, name) and line.index > start_line) {
            if (count < matches.len) matches[count] = line.index;
            count += 1;
        };
        const wanted = if (occurrence == 0) 1 else occurrence;
        return if (wanted > 0 and wanted <= count) matches[wanted - 1] else null;
    }
};

fn resolve_placement(resolver: NamedLineResolver, value: grid_style.GridPlacement, axis: geometry.AbsoluteAxis, end_is_end: bool) grid_style.GridPlacement {
    return switch (value) {
        .named_line => |named| .{ .line = resolver.find_line_index(named.name, named.index, axis, end_is_end) },
        .named_span => |named| .{ .span = named.count },
        else => value,
    };
}

pub fn upsert_line_name_map(lines: []NamedLine, name: []const u8, index: i16) []NamedLine {
    // The caller owns the backing storage; this helper returns the unchanged
    // slice when the name already exists and appends through a page-backed
    // copy otherwise, matching the map's source-order insertion semantics.
    for (lines) |line| if (std.mem.eql(u8, line.name, name) and line.index == index) return lines;
    const result = std.heap.page_allocator.alloc(NamedLine, lines.len + 1) catch @panic("Taffy named-line allocation failed");
    @memcpy(result[0..lines.len], lines);
    result[lines.len] = .{ .name = name, .index = index };
    return result;
}

test "named grid lines resolve positive and negative occurrences" {
    const testing = std.testing;
    const columns = [_]NamedLine{
        .{ .name = "content", .index = 1 },
        .{ .name = "content", .index = 3 },
        .{ .name = "content", .index = 5 },
    };
    const resolver = NamedLineResolver.new(&[_]NamedLine{}, &columns, &[_]NamedArea{}, 2, 4);
    const start = resolver.resolve_column_names(.{ .start = .{ .named_line = .{ .name = "content", .index = 2 } }, .end = .auto }).start;
    const end = resolver.resolve_column_names(.{ .start = .{ .named_line = .{ .name = "content", .index = -1 } }, .end = .auto }).start;
    switch (start) {
        .line => |value| try testing.expectEqual(@as(i16, 3), value),
        else => try testing.expect(false),
    }
    switch (end) {
        .line => |value| try testing.expectEqual(@as(i16, 5), value),
        else => try testing.expect(false),
    }
}

test "named grid spans resolve from the opposite definite edge" {
    const testing = std.testing;
    const columns = [_]NamedLine{
        .{ .name = "content", .index = 1 },
        .{ .name = "content", .index = 3 },
        .{ .name = "content", .index = 5 },
    };
    const resolver = NamedLineResolver.new(&[_]NamedLine{}, &columns, &[_]NamedArea{}, 1, 4);
    const start_relative = resolver.resolve_column_names(.{
        .start = .{ .named_span = .{ .name = "content", .count = 1 } },
        .end = .{ .line = 5 },
    });
    switch (start_relative.start) {
        .line => |value| try testing.expectEqual(@as(i16, 1), value),
        else => try testing.expect(false),
    }
    const end_relative = resolver.resolve_column_names(.{
        .start = .{ .line = 1 },
        .end = .{ .named_span = .{ .name = "content", .count = 1 } },
    });
    switch (end_relative.end) {
        .line => |value| try testing.expectEqual(@as(i16, 3), value),
        else => try testing.expect(false),
    }
}
