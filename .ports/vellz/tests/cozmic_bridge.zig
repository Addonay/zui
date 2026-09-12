//! Cozmic -> `vellz.cozmic_adapter` bridge.
//!
//! This file is the **only** vellz code allowed to import the Cozmic sibling
//! checkout (`.ports/cozmic`). It lives in the opt-in test tree, never in
//! `src/`, so the rendering core stays Cozmic-free. It also carries the T5
//! acceptance tests: 1:1 mapping, no shaping, and pixel equivalence between
//! the adapter and a direct `glyph_run`.
//!
//! Cozmic's `PhysicalGlyph` is already in y-down layout space, so the bridge
//! only recombines the integer offset with the subpixel bin
//! (`p.x + p.cache_key.x_bin.asFloat()`); no `FLIP_Y` is applied. The
//! reconstructed position is passed to glifo, which performs its own
//! subpixel quantization once.

const std = @import("std");
const cozmic = @import("cozmic");
const adapter = @import("cozmic_adapter");
const vellz = @import("vellz");

const testing = std.testing;
const roboto = @embedFile("fixtures/upstream/Roboto-Regular.ttf");
const font_size: f32 = 24.0;
const width: u16 = 240;
const height: u16 = 40;

pub const LayoutGlyph = cozmic.LayoutGlyph;
pub const PhysicalGlyph = cozmic.PhysicalGlyph;

/// Convert one Cozmic physical glyph to an adapter `PositionedGlyph`.
pub fn fromPhysical(physical: PhysicalGlyph) adapter.PositionedGlyph {
    return .{
        .glyph_id = physical.cache_key.glyph_id,
        .font_id = physical.cache_key.font_id,
        .font_size = physical.cache_key.fontSize(),
        .x = @as(f32, @floatFromInt(physical.x)) + physical.cache_key.x_bin.asFloat(),
        .y = @as(f32, @floatFromInt(physical.y)) + physical.cache_key.y_bin.asFloat(),
    };
}

/// Convert a slice of Cozmic physical glyphs; caller owns the result.
pub fn fromPhysicalSlice(
    allocator: std.mem.Allocator,
    physicals: []const PhysicalGlyph,
) ![]adapter.PositionedGlyph {
    const result = try allocator.alloc(adapter.PositionedGlyph, physicals.len);
    for (physicals, 0..) |physical, i| {
        result[i] = fromPhysical(physical);
    }
    return result;
}

/// "HELLO" as Cozmic layout glyphs, advanced by hmtx (no shaping). Uses the
/// real `LayoutGlyph.physical` binning path so the bridge sees production
/// `PhysicalGlyph` values.
fn layoutHello() ![5]PhysicalGlyph {
    const font = try vellz.glifo.Font.init(roboto, 0);
    const upem: f32 = @floatFromInt(font.unitsPerEm());
    const glyph_ids = [_]u32{ 44, 41, 48, 48, 51 }; // H E L L O, Roboto

    var physicals: [glyph_ids.len]PhysicalGlyph = undefined;
    var x_em: f32 = 0.0;
    for (glyph_ids, 0..) |glyph_id, i| {
        const layout_glyph: LayoutGlyph = .{
            .start = i,
            .end = i + 1,
            .font_size = font_size,
            .font_weight = .normal,
            .line_height_opt = null,
            .font_id = 0,
            .glyph_id = @intCast(glyph_id),
            .x = 0.0,
            .y = 0.0,
            .w = 0.0,
            .level = 0,
            .x_offset = x_em,
            .y_offset = 0.0,
            .color_opt = null,
            .metadata = 0,
            .cache_key_flags = .{},
        };
        physicals[i] = layout_glyph.physical(0.0, 4.0, 1.0);
        x_em += @as(f32, @floatFromInt(font.advanceWidth(glyph_id))) / upem;
    }
    return physicals;
}

/// Counting font resolver: one lookup per adapter run, nothing per glyph.
const FontMap = struct {
    calls: usize = 0,

    fn resolveFn(context: ?*anyopaque, font_id: u32) adapter.ResolveError!adapter.ResolvedFont {
        const self: *FontMap = @ptrCast(@alignCast(context.?));
        if (font_id != 0) return error.UnknownFont;
        self.calls += 1;
        return .{ .bytes = roboto, .index = 0 };
    }

    fn resolver(self: *FontMap) adapter.FontResolver {
        return .{ .context = self, .resolveFn = resolveFn };
    }
};

/// Render `positioned` into a fresh pixmap, either through the adapter or
/// through a direct `glyph_run`. The caller owns the returned bytes.
fn render(
    allocator: std.mem.Allocator,
    positioned: []const adapter.PositionedGlyph,
    resolver: adapter.FontResolver,
    via_adapter: bool,
    hint: bool,
) ![]u8 {
    var ctx = try vellz.cpu.RenderContext.init(allocator, width, height, .{
        .level = .baseline,
        .num_threads = 0,
    });
    defer ctx.deinit(allocator);
    var resources = vellz.cpu.Resources.init();
    defer resources.deinit(allocator);

    ctx.setPaint(vellz.peniko.Color.BLACK);
    ctx.setTransform(vellz.kurbo.Affine.translate(vellz.kurbo.Vec2.new(2.0, 28.0)));

    if (via_adapter) {
        try adapter.drawRun(allocator, &ctx, &resources, resolver, positioned, .{
            .hint = hint,
            .atlas_cache = false,
        });
    } else if (positioned.len > 0) {
        // The direct path must mirror the adapter's split criteria (one run
        // per font/size change) to be comparable; the bridge list is
        // homogeneous, so assert that and issue a single run.
        const first = positioned[0];
        for (positioned) |positioned_glyph| {
            if (positioned_glyph.font_id != first.font_id or
                positioned_glyph.font_size != first.font_size)
            {
                return error.UnexpectedRunSplit;
            }
        }
        const font = vellz.glifo.FontData.init((try resolver.resolve(first.font_id)).bytes, 0);
        const glyphs = try allocator.alloc(vellz.glifo.Glyph, positioned.len);
        defer allocator.free(glyphs);
        for (positioned, 0..) |positioned_glyph, i| {
            glyphs[i] = .{
                .id = positioned_glyph.glyph_id,
                .x = positioned_glyph.x,
                .y = positioned_glyph.y,
            };
        }
        try ctx.glyphRun(&resources, font)
            .fontSize(first.font_size)
            .hint(hint)
            .atlasCache(false)
            .fillGlyphs(allocator, vellz.glifo.iterate(glyphs));
    }

    try ctx.flush();
    var pixmap = try vellz.common.pixmap.Pixmap.init(allocator, width, height);
    defer pixmap.deinit(allocator);
    try ctx.renderWith(&pixmap, &resources, .{
        .render_mode = .optimize_quality,
        .target_init = .{ .clear = vellz.peniko.Color.TRANSPARENT },
        .pixel_format = .rgba8,
        .offset = .{ .x = 0, .y = 0 },
    });
    return allocator.dupe(u8, pixmap.dataAsU8Slice());
}

test "cozmic physical glyphs map 1:1 to positioned glyphs" {
    const physicals = try layoutHello();
    const positioned = try fromPhysicalSlice(testing.allocator, &physicals);
    defer testing.allocator.free(positioned);

    try testing.expectEqual(physicals.len, positioned.len);
    var previous_x: f32 = -1.0;
    for (physicals, positioned) |physical, mapped| {
        // 1:1 ids and sizes from the physical cache key.
        try testing.expectEqual(@as(u32, physical.cache_key.glyph_id), mapped.glyph_id);
        try testing.expectEqual(@as(u32, physical.cache_key.font_id), mapped.font_id);
        try testing.expectEqual(physical.cache_key.fontSize(), mapped.font_size);
        // Subpixel reconstruction: integer offset plus the bin fraction.
        try testing.expectEqual(
            @as(f32, @floatFromInt(physical.x)) + physical.cache_key.x_bin.asFloat(),
            mapped.x,
        );
        try testing.expectEqual(
            @as(f32, @floatFromInt(physical.y)) + physical.cache_key.y_bin.asFloat(),
            mapped.y,
        );
        // Layout advanced left to right; nothing was reordered or inserted.
        try testing.expect(mapped.x > previous_x);
        previous_x = mapped.x;
    }
    // Cozmic y is y-down and echoed unchanged (no FLIP_Y).
    try testing.expectEqual(@as(f32, 4.0), positioned[0].y);
}

test "adapter pixels are byte-identical to a direct glyph_run" {
    const physicals = try layoutHello();
    const positioned = try fromPhysicalSlice(testing.allocator, &physicals);
    defer testing.allocator.free(positioned);

    var font_map = FontMap{};
    const from_adapter = try render(testing.allocator, positioned, font_map.resolver(), true, false);
    defer testing.allocator.free(from_adapter);
    // No shaping: the resolver is consulted once for the whole run, not once
    // per glyph or per character.
    try testing.expectEqual(@as(usize, 1), font_map.calls);

    const direct = try render(testing.allocator, positioned, font_map.resolver(), false, false);
    defer testing.allocator.free(direct);
    try testing.expectEqual(@as(usize, 2), font_map.calls);

    try testing.expectEqualSlices(u8, direct, from_adapter);
}

test "adapter forwards embolden to the core, which rejects it" {
    const physicals = try layoutHello();
    const positioned = try fromPhysicalSlice(testing.allocator, &physicals);
    defer testing.allocator.free(positioned);

    var ctx = try vellz.cpu.RenderContext.init(testing.allocator, width, height, .{
        .level = .baseline,
        .num_threads = 0,
    });
    defer ctx.deinit(testing.allocator);
    var resources = vellz.cpu.Resources.init();
    defer resources.deinit(testing.allocator);

    var font_map = FontMap{};
    try testing.expectError(error.Unsupported, adapter.drawRun(
        testing.allocator,
        &ctx,
        &resources,
        font_map.resolver(),
        positioned,
        .{
            .hint = false,
            .atlas_cache = false,
            .embolden = vellz.glifo.FontEmbolden.new(.{ 1.0, 0.0 }),
        },
    ));
}

test "adapter forwards hinting through the core" {
    const physicals = try layoutHello();
    const positioned = try fromPhysicalSlice(testing.allocator, &physicals);
    defer testing.allocator.free(positioned);

    var font_map = FontMap{};
    const from_adapter = try render(testing.allocator, positioned, font_map.resolver(), true, true);
    defer testing.allocator.free(from_adapter);
    const direct = try render(testing.allocator, positioned, font_map.resolver(), false, true);
    defer testing.allocator.free(direct);

    // Hinted runs absorb the (identity) scale and draw through the
    // interpreter on both paths; the adapter must be byte-identical.
    try testing.expectEqualSlices(u8, direct, from_adapter);
}
