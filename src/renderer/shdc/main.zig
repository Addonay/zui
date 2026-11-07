//! Shader compiler (from zicr): compiles annotated GLSL (sokol-shdc syntax) for every
//! backend with sokol-shdc and generates a Zig module with, per program, the
//! bind slot constants and a `desc(backend)` function returning the
//! `gpu.ShaderDesc` for that backend.
//!
//! usage: zui-shdc <sokol-shdc> <input.glsl> <output.zig> <scratch-dir> <slang:slang:...>
const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

// ---------------------------------------------------------------- YAML subset

/// The YAML subset written by sokol-shdc: block maps, block lists with `-`
/// on their own line, and plain scalars (sometimes with a trailing `;`).
const Node = union(enum) {
    scalar: []const u8,
    map: []const Entry,
    list: []const Node,

    const Entry = struct { key: []const u8, value: Node };

    fn get(self: Node, key: []const u8) ?Node {
        if (self != .map) return null;
        for (self.map) |entry| if (std.mem.eql(u8, entry.key, key)) return entry.value;
        return null;
    }
    fn str(self: Node, key: []const u8) ?[]const u8 {
        const value = self.get(key) orelse return null;
        return if (value == .scalar) value.scalar else null;
    }
    fn int(self: Node, key: []const u8) ?u32 {
        return std.fmt.parseInt(u32, self.str(key) orelse return null, 10) catch null;
    }
    fn items(self: Node, key: []const u8) []const Node {
        const value = self.get(key) orelse return &.{};
        return if (value == .list) value.list else &.{};
    }
};

const Line = struct { indent: usize, text: []const u8 };

const Parser = struct {
    arena: Allocator,
    lines: []const Line,
    pos: usize = 0,

    fn parse(arena: Allocator, source: []const u8) !Node {
        var lines: std.ArrayList(Line) = .empty;
        var it = std.mem.splitScalar(u8, source, '\n');
        while (it.next()) |raw| {
            const line = std.mem.trimEnd(u8, raw, " \r\t");
            const text = std.mem.trimStart(u8, line, " ");
            if (text.len == 0) continue;
            try lines.append(arena, .{ .indent = line.len - text.len, .text = text });
        }
        var parser: Parser = .{ .arena = arena, .lines = lines.items };
        if (parser.lines.len == 0) return .{ .map = &.{} };
        if (parser.lines[0].indent != 0) return error.InvalidYaml;
        const root = try parser.block(0);
        if (parser.pos != parser.lines.len) return error.InvalidYaml;
        return root;
    }

    fn block(self: *Parser, indent: usize) error{ OutOfMemory, InvalidYaml }!Node {
        const first = self.lines[self.pos];
        if (first.text[0] == '-') {
            var list: std.ArrayList(Node) = .empty;
            while (self.pos < self.lines.len and self.lines[self.pos].indent == indent and self.lines[self.pos].text[0] == '-') {
                const text = self.lines[self.pos].text;
                self.pos += 1;
                if (text.len > 1) {
                    try list.append(self.arena, .{ .scalar = scalar(text[1..]) });
                } else if (self.pos < self.lines.len and self.lines[self.pos].indent > indent) {
                    try list.append(self.arena, try self.block(self.lines[self.pos].indent));
                } else {
                    try list.append(self.arena, .{ .scalar = "" });
                }
            }
            return .{ .list = list.items };
        }
        var map: std.ArrayList(Node.Entry) = .empty;
        while (self.pos < self.lines.len and self.lines[self.pos].indent == indent and self.lines[self.pos].text[0] != '-') {
            const text = self.lines[self.pos].text;
            self.pos += 1;
            const colon = std.mem.indexOfScalar(u8, text, ':') orelse return error.InvalidYaml;
            const key = text[0..colon];
            const rest = text[colon + 1 ..];
            const value: Node = if (std.mem.trim(u8, rest, " ").len > 0)
                .{ .scalar = scalar(rest) }
            else if (self.pos < self.lines.len and self.lines[self.pos].indent > indent)
                try self.block(self.lines[self.pos].indent)
            else
                .{ .scalar = "" };
            try map.append(self.arena, .{ .key = key, .value = value });
        }
        return .{ .map = map.items };
    }

    fn scalar(text: []const u8) []const u8 {
        return std.mem.trimEnd(u8, std.mem.trim(u8, text, " "), ";");
    }
};

// WGSL 16.1/16.2, checked 2026-10-18: https://www.w3.org/TR/WGSL/#keyword-summary
// Check reflection names before generating any module: shdc can preserve a GLSL
// resource name which is reserved in WGSL and otherwise fail only at GPU submit.
const wgsl_reserved =
    "alias break case const const_assert continue continuing default diagnostic discard else enable false fn for if let loop override requires return struct switch true var while " ++
    "NULL Self abstract active alignas alignof as asm asm_fragment async attribute auto await become cast catch class co_await co_return co_yield coherent column_major common compile compile_fragment concept const_cast consteval constexpr constinit crate debugger decltype delete demote demote_to_helper do dynamic_cast enum explicit export extends extern external fallthrough filter final finally friend from fxgroup get goto groupshared highp impl implements import inline instanceof interface layout lowp macro macro_rules match mediump meta mod module move mut mutable namespace new nil noexcept noinline nointerpolation non_coherent noncoherent noperspective null nullptr of operator package packoffset partition pass patch pixelfragment precise precision premerge priv protected pub public readonly ref regardless register reinterpret_cast require resource restrict self set shared sizeof smooth snorm static static_assert static_cast std subroutine super target template this thread_local throw trait try type typedef typeid typename typeof union unless unorm unsafe unsized use using varying virtual volatile wgsl where with writeonly yield";

// Target-specific additions to WGSL's broad future-reserved set. HLSL object
// keywords: https://learn.microsoft.com/en-us/windows/win32/direct3dhlsl/dx-graphics-hlsl-appendix-keywords
// MSL/C++ additions: https://wgpu.rs/doc/src/naga/back/msl/keywords.rs.html
const target_reserved =
    "AppendStructuredBuffer BlendState Buffer ByteAddressBuffer cbuffer centroid CompileShader ComputeShader ConsumeStructuredBuffer DepthStencilState DepthStencilView DomainShader dword GeometryShader Hullshader InputPatch line lineadj linear LineStream matrix OutputPatch PixelShader point PointStream RasterizerState RenderTargetView row_major RWBuffer RWByteAddressBuffer RWStructuredBuffer RWTexture1D RWTexture1DArray RWTexture2D RWTexture2DArray RWTexture3D sample sampler SamplerState SamplerComparisonState stateblock stateblock_state string StructuredBuffer tbuffer technique technique10 technique11 texture Texture1D Texture1DArray Texture2D Texture2DArray Texture2DMS Texture2DMSArray Texture3D TextureCube TextureCubeArray triangle triangleadj TriangleStream uniform unsigned vector vertexfragment VertexShader void " ++
    "and bitor or xor compl bitand and_eq or_eq xor_eq not not_eq char char16_t char32_t short signed wchar_t private main device constant thread threadgroup threadgroup_imageblock ray_data object_data vertex fragment kernel metal atomic as_type size_t ptrdiff_t uchar ushort uint ulong half bfloat";

fn reservedIdentifier(name: []const u8) bool {
    if (std.mem.startsWith(u8, name, "__") or std.mem.eql(u8, name, "_")) return true;
    inline for (.{ wgsl_reserved, target_reserved }) |set| {
        var words = std.mem.tokenizeScalar(u8, set, ' ');
        while (words.next()) |word| if (std.mem.eql(u8, word, name)) return true;
    }
    // Numeric vector/matrix type keywords are a family, not just scalar names.
    inline for (.{ "bool", "int", "uint", "float", "double", "half", "min10float", "min16float", "min12int", "min16int", "min16uint", "char", "short", "long", "uchar", "ushort", "ulong", "bfloat" }) |scalar| {
        if (std.mem.eql(u8, name, scalar)) return true;
        if (std.mem.startsWith(u8, name, scalar)) {
            const suffix = name[scalar.len..];
            if (suffix.len == 1 and suffix[0] >= '1' and suffix[0] <= '4') return true;
            if (suffix.len == 3 and suffix[0] >= '1' and suffix[0] <= '4' and suffix[1] == 'x' and suffix[2] >= '1' and suffix[2] <= '4') return true;
        }
    }
    return false;
}

fn validateIdentifiers(node: Node) error{ReservedShaderIdentifier}!void {
    switch (node) {
        .scalar => {},
        .list => |items| for (items) |item| try validateIdentifiers(item),
        .map => |entries| for (entries) |entry| {
            const identifier = std.mem.eql(u8, entry.key, "name") or std.mem.eql(u8, entry.key, "struct_name") or std.mem.eql(u8, entry.key, "inst_name") or std.mem.eql(u8, entry.key, "glsl_name");
            if (identifier and entry.value == .scalar and reservedIdentifier(entry.value.scalar)) {
                if (!@import("builtin").is_test) std.debug.print("shader identifier '{s}' is reserved in a shader target language; rename it in the input shader\n", .{entry.value.scalar});
                return error.ReservedShaderIdentifier;
            }
            try validateIdentifiers(entry.value);
        },
    }
}

// ---------------------------------------------------------------- code generation

/// Convert shdc's GL 4.10 interface decorations to the GL 3.30 interface.
/// This deliberately does not translate newer language operations: the native
/// compiler still rejects unsupported shader syntax. Compute remains GL 4.30.
fn gl330Source(allocator: Allocator, source: []const u8, vertex: bool) ![]const u8 {
    if (!std.mem.startsWith(u8, source, "#version 410\n")) return error.UnexpectedGlslVersion;
    var result: std.ArrayList(u8) = .empty;
    errdefer result.deinit(allocator);
    var lines = std.mem.splitScalar(u8, source, '\n');
    while (lines.next()) |original| {
        var line = original;
        if (std.mem.eql(u8, line, "#version 410")) line = "#version 330";
        // Vertex inputs and fragment outputs retain GL 3.3 attribute locations.
        // Interstage varyings link by their original names instead of locations.
        if (std.mem.startsWith(u8, line, "layout(location = ")) {
            const end = std.mem.indexOfScalar(u8, line, ')') orelse return error.InvalidShaderInterface;
            const declaration = std.mem.trimStart(u8, line[end + 1 ..], " ");
            var qualifiers = std.mem.tokenizeAny(u8, declaration, " \t");
            while (qualifiers.next()) |qualifier| {
                if (std.mem.eql(u8, qualifier, if (vertex) "out" else "in")) {
                    // Do not silently discard extra component/index decorations.
                    const location = std.mem.trim(u8, line["layout(location = ".len..end], " ");
                    _ = std.fmt.parseInt(u32, location, 10) catch return error.UnsupportedShaderInterface;
                    line = declaration;
                    break;
                }
                if (!std.mem.eql(u8, qualifier, "flat") and !std.mem.eql(u8, qualifier, "smooth") and !std.mem.eql(u8, qualifier, "noperspective") and !std.mem.eql(u8, qualifier, "centroid") and !std.mem.eql(u8, qualifier, "sample") and !std.mem.eql(u8, qualifier, "invariant")) break;
            }
        }
        try result.appendSlice(allocator, line);
        try result.append(allocator, '\n');
    }
    return try result.toOwnedSlice(allocator);
}

const Generator = struct {
    arena: Allocator,
    io: Io,
    out: *Io.Writer,
    /// Directory containing the reflection file, for relative shader paths.
    base_dir: []const u8,
    legacy_gl: bool = false,
    blob_index: usize = 0,
    blobs: std.ArrayList(u8) = .empty,

    fn readShaderFile(self: *Generator, path: []const u8) ![]u8 {
        const cwd = Io.Dir.cwd();
        if (cwd.readFileAlloc(self.io, path, self.arena, .unlimited)) |data| return data else |_| {}
        const joined = try std.fs.path.join(self.arena, &.{ self.base_dir, std.fs.path.basename(path) });
        return cwd.readFileAlloc(self.io, joined, self.arena, .unlimited);
    }

    fn function(self: *Generator, func: Node, vertex: bool) !void {
        const w = self.out;
        const original = try self.readShaderFile(func.str("path") orelse return error.MissingShaderPath);
        const data = if (self.legacy_gl) try gl330Source(self.arena, original, vertex) else original;
        const binary = std.mem.eql(u8, func.str("is_binary") orelse "false", "true");
        try w.writeAll(".{ .code = .{ ");
        if (binary) {
            // shader byte code must be 4-byte aligned, so it lives in a separate constant
            const name = try std.fmt.allocPrint(self.arena, "bytecode_{d}", .{self.blob_index});
            self.blob_index += 1;
            var blob: Io.Writer.Allocating = .init(self.arena);
            try blob.writer.print("const {s} align(4) = [_]u8{{", .{name});
            for (data, 0..) |byte, i| {
                if (i % 24 == 0) try blob.writer.writeAll("\n    ");
                try blob.writer.print("0x{x:0>2},", .{byte});
            }
            try blob.writer.writeAll("\n};\n");
            try self.blobs.appendSlice(self.arena, blob.written());
            try w.print(".bytecode = &{s} }}", .{name});
        } else {
            try w.print(".source = \"{f}\" }}", .{std.zig.fmtString(data)});
        }
        if (func.str("entry_point")) |entry| try w.print(", .entry = \"{f}\"", .{std.zig.fmtString(entry)});
        if (func.str("d3d11_target")) |target| try w.print(", .d3d_target = \"{f}\"", .{std.zig.fmtString(target)});
        try w.writeAll(" }");
    }

    fn bindings(self: *Generator, node: Node, comptime fields: anytype) !void {
        const w = self.out;
        try w.writeAll(".bindings = .{");
        var any = false;
        inline for (fields) |field| {
            if (node.int(field[0])) |value| {
                try w.print(" .{s} = {d},", .{ field[1], value });
                any = true;
            }
        }
        try w.writeAll(if (any) " }" else "}");
    }

    fn desc(self: *Generator, program: Node) !void {
        const w = self.out;
        try w.writeAll(".{\n        .stages = ");
        if (program.get("compute_func")) |cs| {
            try w.writeAll(".{ .compute = .{ .function = ");
            try self.function(cs, false);
            if (program.get("mtl_threads_per_threadgroup")) |tg| {
                try w.print(", .threads_per_threadgroup = .{{ {d}, {d}, {d} }}", .{ tg.int("x") orelse 1, tg.int("y") orelse 1, tg.int("z") orelse 1 });
            }
            try w.writeAll(" } },\n");
        } else {
            try w.writeAll(".{ .render = .{ .vertex = ");
            try self.function(program.get("vertex_func") orelse return error.MissingVertexFunction, true);
            try w.writeAll(", .fragment = ");
            try self.function(program.get("fragment_func") orelse return error.MissingFragmentFunction, false);
            try w.writeAll(" } },\n");
        }

        const attrs = program.items("attrs");
        if (attrs.len > 0) {
            var max_slot: u32 = 0;
            for (attrs) |attr| max_slot = @max(max_slot, attr.int("slot") orelse 0);
            try w.writeAll("        .attrs = &.{");
            for (0..max_slot + 1) |slot| {
                const attr = for (attrs) |a| {
                    if (a.int("slot") == @as(u32, @intCast(slot))) break a;
                } else null;
                try w.writeAll("\n            .{");
                if (attr) |a| {
                    if (a.str("base_type")) |bt| try w.print(" .base_type = .{s},", .{baseType(bt)});
                    if (a.str("glsl_name")) |name| try w.print(" .glsl_name = \"{f}\",", .{std.zig.fmtString(name)});
                    if (a.str("hlsl_sem_name")) |name| try w.print(" .hlsl_semantic = \"{f}\", .hlsl_semantic_index = {d},", .{ std.zig.fmtString(name), a.int("hlsl_sem_index") orelse 0 });
                }
                try w.writeAll(" },");
            }
            try w.writeAll("\n        },\n");
        }

        const ubs = program.items("uniform_blocks");
        if (ubs.len > 0) {
            try w.writeAll("        .uniform_blocks = &.{");
            for (ubs) |ub| {
                try w.print("\n            .{{ .slot = {d}, .stage = .{s}, .size = {d}, .layout = .std140, ", .{ ub.int("slot") orelse 0, ub.str("stage") orelse "vertex", ub.int("size") orelse 0 });
                try self.bindings(ub, .{ .{ "hlsl_register_b_n", "hlsl" }, .{ "msl_buffer_n", "msl" }, .{ "wgsl_group0_binding_n", "wgsl" }, .{ "spirv_set0_binding_n", "spirv" } });
                const uniforms = ub.items("glsl_uniforms");
                if (uniforms.len > 0) {
                    try w.writeAll(", .glsl_uniforms = &.{");
                    for (uniforms) |u| {
                        const count = u.int("array_count") orelse 0;
                        try w.print(" .{{ .type = .{s}, .array_count = {d}, .name = \"{f}\" }},", .{ uniformType(u.str("type") orelse "vec4"), @max(count, 1), std.zig.fmtString(u.str("glsl_name") orelse "") });
                    }
                    try w.writeAll(" }");
                }
                try w.writeAll(" },");
            }
            try w.writeAll("\n        },\n");
        }

        const views = program.items("views");
        if (views.len > 0) {
            try w.writeAll("        .views = &.{");
            for (views) |view| {
                if (view.get("texture")) |tex| {
                    try w.print("\n            .{{ .slot = {d}, .stage = .{s}, .kind = .{{ .texture = .{{ .image_type = {s}, .sample_type = .{s}, .multisampled = {s} }} }}, ", .{ tex.int("slot") orelse 0, tex.str("stage") orelse "fragment", imageType(tex.str("type") orelse "2d"), tex.str("sample_type") orelse "float", tex.str("multisampled") orelse "false" });
                    try self.bindings(tex, .{ .{ "hlsl_register_t_n", "hlsl" }, .{ "msl_texture_n", "msl" }, .{ "wgsl_group1_binding_n", "wgsl" }, .{ "spirv_set1_binding_n", "spirv" } });
                } else if (view.get("storage_buffer")) |sbuf| {
                    try w.print("\n            .{{ .slot = {d}, .stage = .{s}, .kind = .{{ .storage_buffer = .{{ .readonly = {s} }} }}, ", .{ sbuf.int("slot") orelse 0, sbuf.str("stage") orelse "compute", sbuf.str("readonly") orelse "true" });
                    try self.bindings(sbuf, .{ .{ "hlsl_register_t_n", "hlsl" }, .{ "hlsl_register_u_n", "hlsl_uav" }, .{ "msl_buffer_n", "msl" }, .{ "wgsl_group1_binding_n", "wgsl" }, .{ "spirv_set1_binding_n", "spirv" }, .{ "glsl_binding_n", "glsl" } });
                } else if (view.get("storage_image")) |simg| {
                    const format = try std.ascii.allocLowerString(self.arena, simg.str("access_format") orelse "rgba8");
                    try w.print("\n            .{{ .slot = {d}, .stage = .{s}, .kind = .{{ .storage_image = .{{ .image_type = {s}, .access_format = .{s}, .writeonly = {s} }} }}, ", .{ simg.int("slot") orelse 0, simg.str("stage") orelse "compute", imageType(simg.str("type") orelse "2d"), format, simg.str("writeonly") orelse "false" });
                    try self.bindings(simg, .{ .{ "hlsl_register_u_n", "hlsl_uav" }, .{ "msl_texture_n", "msl" }, .{ "wgsl_group1_binding_n", "wgsl" }, .{ "spirv_set1_binding_n", "spirv" }, .{ "glsl_binding_n", "glsl" } });
                } else continue;
                try w.writeAll(" },");
            }
            try w.writeAll("\n        },\n");
        }

        const samplers = program.items("samplers");
        if (samplers.len > 0) {
            try w.writeAll("        .samplers = &.{");
            for (samplers) |smp| {
                try w.print("\n            .{{ .slot = {d}, .stage = .{s}, .type = .{s}, ", .{ smp.int("slot") orelse 0, smp.str("stage") orelse "fragment", smp.str("sampler_type") orelse "filtering" });
                try self.bindings(smp, .{ .{ "hlsl_register_s_n", "hlsl" }, .{ "msl_sampler_n", "msl" }, .{ "wgsl_group1_binding_n", "wgsl" }, .{ "spirv_set1_binding_n", "spirv" } });
                try w.writeAll(" },");
            }
            try w.writeAll("\n        },\n");
        }

        const pairs = program.items("texture_sampler_pairs");
        if (pairs.len > 0) {
            try w.writeAll("        .texture_sampler_pairs = &.{");
            for (pairs) |pair| {
                try w.print("\n            .{{ .stage = .{s}, .view = {d}, .sampler = {d}", .{ pair.str("stage") orelse "fragment", pair.int("view_slot") orelse 0, pair.int("sampler_slot") orelse 0 });
                if (pair.str("glsl_name")) |name| try w.print(", .glsl_name = \"{f}\"", .{std.zig.fmtString(name)});
                try w.writeAll(" },");
            }
            try w.writeAll("\n        },\n");
        }
        try w.writeAll("    }");
    }
};

fn baseType(name: []const u8) []const u8 {
    if (std.mem.eql(u8, name, "Int")) return "sint";
    if (std.mem.eql(u8, name, "UInt")) return "uint";
    return "float";
}

fn imageType(name: []const u8) []const u8 {
    if (std.mem.eql(u8, name, "cube")) return ".cube";
    if (std.mem.eql(u8, name, "3d")) return ".@\"3d\"";
    if (std.mem.eql(u8, name, "array")) return ".array";
    return ".@\"2d\"";
}

fn uniformType(name: []const u8) []const u8 {
    const map = .{
        .{ "float", "float" }, .{ "vec2", "float2" }, .{ "vec3", "float3" }, .{ "vec4", "float4" },
        .{ "int", "int" },     .{ "ivec2", "int2" },  .{ "ivec3", "int3" },  .{ "ivec4", "int4" },
        .{ "mat4", "mat4" },
    };
    inline for (map) |entry| if (std.mem.eql(u8, name, entry[0])) return entry[1];
    return "float4";
}

/// The slang used for each backend, in order of preference.
const backend_slangs = .{
    .{ "gl", .{ "glsl430", "glsl410" } },
    .{ "gles", .{ "glsl310es", "glsl300es" } },
    .{ "d3d11", .{ "hlsl5", "hlsl4" } },
    .{ "d3d12", .{ "hlsl5", "hlsl4" } },
    .{ "wgpu", .{"wgsl"} },
    .{ "vulkan", .{"spirv_vk"} },
};

fn findProgram(shaders: []const Node, slang: []const u8, name: []const u8) ?Node {
    for (shaders) |shader| {
        if (!std.mem.eql(u8, shader.str("slang") orelse "", slang)) continue;
        for (shader.items("programs")) |program| {
            if (std.mem.eql(u8, program.str("name") orelse "", name)) return program;
        }
    }
    return null;
}

fn constName(view: Node) ?[]const u8 {
    if (view.get("texture")) |v| return v.str("name");
    if (view.get("storage_buffer")) |v| return v.str("struct_name");
    if (view.get("storage_image")) |v| return v.str("name");
    return null;
}

fn generate(gen: *Generator, root: Node, input_name: []const u8) !void {
    const w = gen.out;
    const shaders = root.items("shaders");
    if (shaders.len == 0) return error.NoShaders;
    try w.print(
        \\//! Generated by zui-shdc from `{s}`; do not edit.
        \\const builtin = @import("builtin");
        \\const gpu = @import("../gpu/root.zig");
        \\
    , .{input_name});

    for (shaders[0].items("programs")) |first| {
        const name = first.str("name") orelse continue;
        try w.print("\npub const {f} = struct {{\n", .{std.zig.fmtId(name)});

        // bind slot constants, named after the GLSL declarations
        const named = for (shaders) |shader| {
            if (std.mem.startsWith(u8, shader.str("slang") orelse "", "glsl")) break findProgram(shaders, shader.str("slang").?, name) orelse first;
        } else first;
        try w.writeAll("    pub const attrs = struct {\n");
        for (named.items("attrs")) |attr| if (attr.str("glsl_name")) |n| try w.print("        pub const {f} = {d};\n", .{ std.zig.fmtId(n), attr.int("slot") orelse 0 });
        try w.writeAll("    };\n    pub const uniform_blocks = struct {\n");
        for (named.items("uniform_blocks")) |ub| if (ub.str("struct_name")) |n| try w.print("        pub const {f} = {d};\n", .{ std.zig.fmtId(n), ub.int("slot") orelse 0 });
        try w.writeAll("    };\n    pub const uniform_block_sizes = struct {\n");
        for (named.items("uniform_blocks")) |ub| if (ub.str("struct_name")) |n| try w.print("        pub const {f} = {d};\n", .{ std.zig.fmtId(n), ub.int("size") orelse 0 });
        try w.writeAll("    };\n    pub const views = struct {\n");
        for (named.items("views")) |view| {
            const n = constName(view) orelse continue;
            const inner = view.get("texture") orelse view.get("storage_buffer") orelse view.get("storage_image") orelse continue;
            const slot = inner.int("slot") orelse 0;
            try w.print("        pub const {f} = {d};\n", .{ std.zig.fmtId(n), slot });
        }
        try w.writeAll("    };\n    pub const samplers = struct {\n");
        for (named.items("samplers")) |smp| if (smp.str("name")) |n| try w.print("        pub const {f} = {d};\n", .{ std.zig.fmtId(n), smp.int("slot") orelse 0 });
        try w.writeAll("    };\n");

        // one descriptor per compiled shader language
        for (shaders) |shader| {
            const slang = shader.str("slang") orelse continue;
            const program = findProgram(shaders, slang, name) orelse continue;
            try w.print("    const {s}: gpu.ShaderDesc = ", .{slang});
            try gen.desc(program);
            try w.writeAll(";\n");
            if (std.mem.eql(u8, slang, "glsl410")) {
                gen.legacy_gl = true;
                try w.writeAll("    /// GLSL 3.30 variant; actual shader syntax must be supported by GL 3.3.\n    pub const glsl330: gpu.ShaderDesc = ");
                try gen.desc(program);
                try w.writeAll(";\n");
                gen.legacy_gl = false;
            }
        }

        // backend selection
        try w.writeAll("\n    /// The shader descriptor for `backend`, or null if no shader language for it was compiled.\n");
        try w.writeAll("    pub fn desc(backend: gpu.Backend) ?gpu.ShaderDesc {\n        return switch (backend) {\n");
        inline for (backend_slangs) |entry| {
            var chosen: ?[]const u8 = null;
            inline for (entry[1]) |slang| {
                if (chosen == null and findProgram(shaders, slang, name) != null) chosen = slang;
            }
            if (chosen) |slang| try w.print("            .{s} => {s},\n", .{ entry[0], slang }) else try w.print("            .{s} => null,\n", .{entry[0]});
        }
        const has_ios = findProgram(shaders, "metal_ios", name) != null;
        const has_sim = findProgram(shaders, "metal_sim", name) != null;
        const has_macos = findProgram(shaders, "metal_macos", name) != null;
        try w.print("            .metal => if (builtin.os.tag == .macos) {s} else if (builtin.abi == .simulator) {s} else {s},\n", .{
            if (has_macos) "metal_macos" else "null",
            if (has_sim) "metal_sim" else "null",
            if (has_ios) "metal_ios" else "null",
        });
        // the dummy backend accepts any descriptor
        try w.print("            .dummy => {s},\n        }};\n    }}\n}};\n", .{shaders[0].str("slang").?});
    }
    if (gen.blobs.items.len > 0) {
        try w.writeAll("\n");
        try w.writeAll(gen.blobs.items);
    }
}

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const io = init.io;
    const args = try init.minimal.args.toSlice(arena);
    if (args.len != 6) {
        std.debug.print("usage: zui-shdc <sokol-shdc> <input.glsl> <output.zig> <scratch-dir> <slangs>\n", .{});
        return error.InvalidArguments;
    }
    const shdc, const input, const output, const scratch, const slangs = .{ args[1], args[2], args[3], args[4], args[5] };
    const cwd = Io.Dir.cwd();
    try cwd.createDirPath(io, scratch);
    const prefix = try std.fmt.allocPrint(arena, "{s}{c}", .{ scratch, std.fs.path.sep });
    const result = try std.process.run(arena, io, .{ .argv = &.{ shdc, "-i", input, "-o", prefix, "-l", slangs, "-f", "bare_yaml", "--no-log-cmdline" } });
    if (!result.term.success()) {
        std.debug.print("{s}{s}", .{ result.stdout, result.stderr });
        return error.ShaderCompilationFailed;
    }
    const reflection_path = try std.fmt.allocPrint(arena, "{s}_reflection.yaml", .{prefix});
    const yaml = try cwd.readFileAlloc(io, reflection_path, arena, .unlimited);
    const root = try Parser.parse(arena, yaml);
    try validateIdentifiers(root);
    var out: Io.Writer.Allocating = .init(arena);
    var gen: Generator = .{ .arena = arena, .io = io, .out = &out.writer, .base_dir = scratch };
    try generate(&gen, root, std.fs.path.basename(input));
    try cwd.writeFile(io, .{ .sub_path = output, .data = out.written() });
}

test "pinned reflection subset preserves nested resources and trailing semicolons" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const root = try Parser.parse(arena.allocator(),
        \\shaders:
        \\  -
        \\    slang: wgsl
        \\    programs:
        \\      -
        \\        name: textured
        \\        views:
        \\          -
        \\            texture:
        \\              name: source_image
        \\              slot: 3;
    );
    const program = findProgram(root.items("shaders"), "wgsl", "textured").?;
    const texture = program.items("views")[0].get("texture").?;
    try std.testing.expectEqualStrings("source_image", texture.str("name").?);
    try std.testing.expectEqual(@as(u32, 3), texture.int("slot").?);
}

test "reflection parser rejects unconsumed or malformed indentation" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectError(error.InvalidYaml, Parser.parse(arena.allocator(), "  shaders: bad"));
    try std.testing.expectError(error.InvalidYaml, Parser.parse(arena.allocator(), "shaders: scalar\n  unexpected: nested"));
    try std.testing.expectError(error.InvalidYaml, Parser.parse(arena.allocator(), "missing colon"));
}

test "cross-target reserved reflection identifiers fail before GPU creation" {
    inline for (.{ "target", "Texture2D", "cbuffer", "threadgroup", "device", "float4x4", "half3", "and_eq" }) |name| try std.testing.expect(reservedIdentifier(name));
    try std.testing.expect(reservedIdentifier("__private"));
    try std.testing.expect(reservedIdentifier("thread_local"));
    try std.testing.expect(!reservedIdentifier("dst_image"));
    try std.testing.expect(!reservedIdentifier("target_color"));
    const invalid: Node = .{ .map = &.{.{ .key = "name", .value = .{ .scalar = "target" } }} };
    try std.testing.expectError(error.ReservedShaderIdentifier, validateIdentifiers(invalid));
    // Type descriptions and file paths are not user identifiers.
    try validateIdentifiers(.{ .map = &.{.{ .key = "type", .value = .{ .scalar = "struct" } }} });
}

test "GL330 interface conversion keeps attribute and output locations" {
    const input = "#version 410\nlayout(location = 0) in vec3 position;\nlayout(location = 1) out vec4 color;\n";
    const vertex = try gl330Source(std.testing.allocator, input, true);
    defer std.testing.allocator.free(vertex);
    try std.testing.expect(std.mem.startsWith(u8, vertex, "#version 330\nlayout(location = 0) in"));
    try std.testing.expect(std.mem.indexOf(u8, vertex, "\nout vec4 color;") != null);
    const fragment = try gl330Source(std.testing.allocator, input, false);
    defer std.testing.allocator.free(fragment);
    try std.testing.expect(std.mem.indexOf(u8, fragment, "\nin vec3 position;") != null);
    try std.testing.expect(std.mem.indexOf(u8, fragment, "layout(location = 1) out") != null);
    try std.testing.expectError(error.UnexpectedGlslVersion, gl330Source(std.testing.allocator, "#version 430\n", true));
    const flat = try gl330Source(std.testing.allocator, "#version 410\nlayout(location = 0) flat out ivec4 value;\n", true);
    defer std.testing.allocator.free(flat);
    try std.testing.expect(std.mem.indexOf(u8, flat, "\nflat out ivec4 value;") != null);
    try std.testing.expectError(error.UnsupportedShaderInterface, gl330Source(std.testing.allocator, "#version 410\nlayout(location = 0, component = 1) out vec2 value;\n", true));
}
