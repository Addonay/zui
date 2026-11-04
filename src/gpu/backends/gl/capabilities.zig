//! Native OpenGL/GLES format capability rules, ported from sokol_gfx.h:10758-10910.
const t = @import("../../types.zig");
const e = @import("../../enums.zig");

pub const Table = [69]t.PixelformatInfo;
fn mark(table: *Table, format: e.PixelFormat, comptime flags: []const u8) void {
    const info = &table[@backingInt(format)];
    inline for (flags) |flag| {
        switch (flag) {
            's' => info.sample = true,
            'f' => info.filter = true,
            'b' => info.blend = true,
            'r' => info.render = true,
            'm' => info.msaa = true,
            'd' => info.depth = true,
            else => unreachable,
        }
    }
}

fn base(table: *Table, has_bgra: bool, gles: bool) void {
    mark(table, .r8, "sfbrm");
    mark(table, .r8sn, "sf");
    mark(table, .r8ui, "srm");
    mark(table, .r8si, "srm");
    if (!gles) {
        mark(table, .r16, "sfbrm");
        mark(table, .r16sn, "sfbrm");
    }
    mark(table, .r16ui, "srm");
    mark(table, .r16si, "srm");
    mark(table, .rg8, "sfbrm");
    mark(table, .rg8sn, "sf");
    mark(table, .rg8ui, "srm");
    mark(table, .rg8si, "srm");
    mark(table, .r32ui, "sr");
    mark(table, .r32si, "sr");
    if (!gles) {
        mark(table, .rg16, "sfbrm");
        mark(table, .rg16sn, "sfbrm");
    }
    mark(table, .rg16ui, "srm");
    mark(table, .rg16si, "srm");
    mark(table, .rgba8, "sfbrm");
    mark(table, .srgb8a8, "sfbrm");
    mark(table, .rgba8sn, "sf");
    mark(table, .rgba8ui, "srm");
    mark(table, .rgba8si, "srm");
    if (has_bgra) {
        mark(table, .bgra8, "sfbrm");
        mark(table, .sbgr8a8, "sfbrm");
    }
    mark(table, .rgb10a2, "sfbrm");
    mark(table, .rgb9e5, "sf");
    mark(table, .rg32ui, "srm");
    mark(table, .rg32si, "srm");
    if (!gles) {
        mark(table, .rgba16, "sfbrm");
        mark(table, .rgba16sn, "sfbrm");
    }
    mark(table, .rgba16ui, "srm");
    mark(table, .rgba16si, "srm");
    mark(table, .rgba32ui, "srm");
    mark(table, .rgba32si, "srm");
    mark(table, .depth, "srmd");
    mark(table, .depth_stencil, "srmd");
}

fn halfFloat(table: *Table, has_colorbuffer_half_float: bool) void {
    if (has_colorbuffer_half_float) {
        mark(table, .r16f, "sfbrm");
        mark(table, .rg16f, "sfbrm");
        mark(table, .rgba16f, "sfbrm");
    } else {
        mark(table, .r16f, "sf");
        mark(table, .rg16f, "sf");
        mark(table, .rgba16f, "sf");
    }
}

fn fullFloat(table: *Table, has_colorbuffer_float: bool, has_texture_float_linear: bool, has_float_blend: bool) void {
    if (has_texture_float_linear) {
        if (has_colorbuffer_float) {
            if (has_float_blend) {
                mark(table, .r32f, "sfbrm");
                mark(table, .rg32f, "sfbrm");
                mark(table, .rgba32f, "sfbrm");
            } else {
                mark(table, .r32f, "sfrm");
                mark(table, .rg32f, "sfrm");
                mark(table, .rgba32f, "sfrm");
            }
            mark(table, .rg11b10f, "sfrm");
        } else {
            mark(table, .r32f, "sf");
            mark(table, .rg32f, "sf");
            mark(table, .rgba32f, "sf");
            mark(table, .rg11b10f, "sf");
        }
    } else {
        if (has_colorbuffer_float) {
            mark(table, .r32f, "sbrm");
            mark(table, .rg32f, "sbrm");
            mark(table, .rgba32f, "sbrm");
            mark(table, .rg11b10f, "srm");
        } else {
            mark(table, .r32f, "s");
            mark(table, .rg32f, "s");
            mark(table, .rgba32f, "s");
            mark(table, .rg11b10f, "s");
        }
    }
}

fn s3tc(table: *Table) void {
    mark(table, .bc1_rgba, "sf");
    mark(table, .bc2_rgba, "sf");
    mark(table, .bc3_rgba, "sf");
    mark(table, .bc3_srgba, "sf");
}

fn rgtc(table: *Table) void {
    mark(table, .bc4_r, "sf");
    mark(table, .bc4_rsn, "sf");
    mark(table, .bc5_rg, "sf");
    mark(table, .bc5_rgsn, "sf");
}

fn bptc(table: *Table) void {
    mark(table, .bc6h_rgbf, "sf");
    mark(table, .bc6h_rgbuf, "sf");
    mark(table, .bc7_rgba, "sf");
    mark(table, .bc7_srgba, "sf");
}

fn etc2(table: *Table) void {
    mark(table, .etc2_rgb8, "sf");
    mark(table, .etc2_srgb8, "sf");
    mark(table, .etc2_rgb8a1, "sf");
    mark(table, .etc2_rgba8, "sf");
    mark(table, .etc2_srgb8a8, "sf");
    mark(table, .eac_r11, "sf");
    mark(table, .eac_r11sn, "sf");
    mark(table, .eac_rg11, "sf");
    mark(table, .eac_rg11sn, "sf");
}

fn astc(table: *Table) void {
    mark(table, .astc_4x4_rgba, "sf");
    mark(table, .astc_4x4_srgba, "sf");
}

pub const Extensions = struct {
    s3tc: bool = false,
    rgtc: bool = false,
    bptc: bool = false,
    etc2: bool = false,
    astc: bool = false,
    bgra: bool = false,
    colorbuffer_float: bool = false,
    colorbuffer_half_float: bool = false,
    texture_float_linear: bool = false,
    float_blend: bool = false,
    anisotropic: bool = false,
};

pub fn formats(gles: bool, compute: bool, extensions: Extensions) Table {
    var table: Table = @splat(.{});
    base(&table, if (gles) extensions.bgra else false, gles);
    fullFloat(&table, !gles or extensions.colorbuffer_float, !gles or extensions.texture_float_linear, !gles or extensions.float_blend);
    halfFloat(&table, !gles or extensions.colorbuffer_half_float);
    if (extensions.s3tc) s3tc(&table);
    if (extensions.rgtc) rgtc(&table);
    if (extensions.bptc) bptc(&table);
    if (extensions.etc2) etc2(&table);
    if (extensions.astc) astc(&table);
    if (compute and !gles) {
        table[@backingInt(e.PixelFormat.rgba32f)].read = true;
        table[@backingInt(e.PixelFormat.rgba32f)].write = true;
        table[@backingInt(e.PixelFormat.rgba16f)].read = true;
        table[@backingInt(e.PixelFormat.rgba16f)].write = true;
        table[@backingInt(e.PixelFormat.rg32f)].read = true;
        table[@backingInt(e.PixelFormat.rg32f)].write = true;
        table[@backingInt(e.PixelFormat.rg16f)].read = true;
        table[@backingInt(e.PixelFormat.rg16f)].write = true;
        table[@backingInt(e.PixelFormat.rg11b10f)].read = true;
        table[@backingInt(e.PixelFormat.rg11b10f)].write = true;
        table[@backingInt(e.PixelFormat.rgba32ui)].read = true;
        table[@backingInt(e.PixelFormat.rgba32ui)].write = true;
        table[@backingInt(e.PixelFormat.rgba16ui)].read = true;
        table[@backingInt(e.PixelFormat.rgba16ui)].write = true;
        table[@backingInt(e.PixelFormat.r32f)].read = true;
        table[@backingInt(e.PixelFormat.r32f)].write = true;
        table[@backingInt(e.PixelFormat.r16f)].read = true;
        table[@backingInt(e.PixelFormat.r16f)].write = true;
        table[@backingInt(e.PixelFormat.rgba8ui)].read = true;
        table[@backingInt(e.PixelFormat.rgba8ui)].write = true;
        table[@backingInt(e.PixelFormat.rg32ui)].read = true;
        table[@backingInt(e.PixelFormat.rg32ui)].write = true;
        table[@backingInt(e.PixelFormat.rg16ui)].read = true;
        table[@backingInt(e.PixelFormat.rg16ui)].write = true;
        table[@backingInt(e.PixelFormat.rg8ui)].read = true;
        table[@backingInt(e.PixelFormat.rg8ui)].write = true;
        table[@backingInt(e.PixelFormat.r32ui)].read = true;
        table[@backingInt(e.PixelFormat.r32ui)].write = true;
        table[@backingInt(e.PixelFormat.r16ui)].read = true;
        table[@backingInt(e.PixelFormat.r16ui)].write = true;
        table[@backingInt(e.PixelFormat.r8ui)].read = true;
        table[@backingInt(e.PixelFormat.r8ui)].write = true;
        table[@backingInt(e.PixelFormat.rgba32si)].read = true;
        table[@backingInt(e.PixelFormat.rgba32si)].write = true;
        table[@backingInt(e.PixelFormat.rgba16si)].read = true;
        table[@backingInt(e.PixelFormat.rgba16si)].write = true;
        table[@backingInt(e.PixelFormat.rgba8si)].read = true;
        table[@backingInt(e.PixelFormat.rgba8si)].write = true;
        table[@backingInt(e.PixelFormat.rg32si)].read = true;
        table[@backingInt(e.PixelFormat.rg32si)].write = true;
        table[@backingInt(e.PixelFormat.rg16si)].read = true;
        table[@backingInt(e.PixelFormat.rg16si)].write = true;
        table[@backingInt(e.PixelFormat.rg8si)].read = true;
        table[@backingInt(e.PixelFormat.rg8si)].write = true;
        table[@backingInt(e.PixelFormat.r32si)].read = true;
        table[@backingInt(e.PixelFormat.r32si)].write = true;
        table[@backingInt(e.PixelFormat.r16si)].read = true;
        table[@backingInt(e.PixelFormat.r16si)].write = true;
        table[@backingInt(e.PixelFormat.r8si)].read = true;
        table[@backingInt(e.PixelFormat.r8si)].write = true;
        table[@backingInt(e.PixelFormat.rgba16)].read = true;
        table[@backingInt(e.PixelFormat.rgba16)].write = true;
        table[@backingInt(e.PixelFormat.rgb10a2)].read = true;
        table[@backingInt(e.PixelFormat.rgb10a2)].write = true;
        table[@backingInt(e.PixelFormat.rgba8)].read = true;
        table[@backingInt(e.PixelFormat.rgba8)].write = true;
        table[@backingInt(e.PixelFormat.rg16)].read = true;
        table[@backingInt(e.PixelFormat.rg16)].write = true;
        table[@backingInt(e.PixelFormat.rg8)].read = true;
        table[@backingInt(e.PixelFormat.rg8)].write = true;
        table[@backingInt(e.PixelFormat.r16)].read = true;
        table[@backingInt(e.PixelFormat.r16)].write = true;
        table[@backingInt(e.PixelFormat.r8)].read = true;
        table[@backingInt(e.PixelFormat.r8)].write = true;
        table[@backingInt(e.PixelFormat.rgba16sn)].read = true;
        table[@backingInt(e.PixelFormat.rgba16sn)].write = true;
        table[@backingInt(e.PixelFormat.rgba8sn)].read = true;
        table[@backingInt(e.PixelFormat.rgba8sn)].write = true;
        table[@backingInt(e.PixelFormat.rg16sn)].read = true;
        table[@backingInt(e.PixelFormat.rg16sn)].write = true;
        table[@backingInt(e.PixelFormat.rg8sn)].read = true;
        table[@backingInt(e.PixelFormat.rg8sn)].write = true;
        table[@backingInt(e.PixelFormat.r16sn)].read = true;
        table[@backingInt(e.PixelFormat.r16sn)].write = true;
        table[@backingInt(e.PixelFormat.r8sn)].read = true;
        table[@backingInt(e.PixelFormat.r8sn)].write = true;
    } else if (compute) {
        table[@backingInt(e.PixelFormat.rgba32f)].read = true;
        table[@backingInt(e.PixelFormat.rgba32f)].write = true;
        table[@backingInt(e.PixelFormat.rgba16f)].read = true;
        table[@backingInt(e.PixelFormat.rgba16f)].write = true;
        table[@backingInt(e.PixelFormat.r32f)].read = true;
        table[@backingInt(e.PixelFormat.r32f)].write = true;
        table[@backingInt(e.PixelFormat.rgba32ui)].read = true;
        table[@backingInt(e.PixelFormat.rgba32ui)].write = true;
        table[@backingInt(e.PixelFormat.rgba16ui)].read = true;
        table[@backingInt(e.PixelFormat.rgba16ui)].write = true;
        table[@backingInt(e.PixelFormat.rgba8ui)].read = true;
        table[@backingInt(e.PixelFormat.rgba8ui)].write = true;
        table[@backingInt(e.PixelFormat.r32ui)].read = true;
        table[@backingInt(e.PixelFormat.r32ui)].write = true;
        table[@backingInt(e.PixelFormat.rgba32si)].read = true;
        table[@backingInt(e.PixelFormat.rgba32si)].write = true;
        table[@backingInt(e.PixelFormat.rgba16si)].read = true;
        table[@backingInt(e.PixelFormat.rgba16si)].write = true;
        table[@backingInt(e.PixelFormat.rgba8si)].read = true;
        table[@backingInt(e.PixelFormat.rgba8si)].write = true;
        table[@backingInt(e.PixelFormat.r32si)].read = true;
        table[@backingInt(e.PixelFormat.r32si)].write = true;
        table[@backingInt(e.PixelFormat.rgba8)].read = true;
        table[@backingInt(e.PixelFormat.rgba8)].write = true;
        table[@backingInt(e.PixelFormat.rgba8sn)].read = true;
        table[@backingInt(e.PixelFormat.rgba8sn)].write = true;
    }
    return table;
}
