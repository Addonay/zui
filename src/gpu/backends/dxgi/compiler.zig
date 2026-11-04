//! On-demand native HLSL compilation, from sokol_gfx.h:14668-14725.
const std = @import("std");
const Library = @import("../../platform/windows_library.zig").Library;
const sdk = @import("com.zig");
const c = @import("constants.zig");
const t = @import("../../types.zig");
const e = @import("../../enums.zig");

pub const Compiler = struct {
    library: ?Library = null,
    function: ?sdk.CompileFn = null,
    load_failed: bool = false,

    pub fn ensureLoaded(self: *Compiler) bool {
        if (self.function != null) return true;
        if (self.load_failed) return false;
        self.load_failed = true;
        const library = Library.open("d3dcompiler_47.dll") catch return false;
        self.function = library.lookup(sdk.CompileFn, "D3DCompile");
        if (self.function == null) {
            library.close();
            return false;
        }
        self.library = library;
        self.load_failed = false;
        return true;
    }
    pub fn deinit(self: *Compiler) void {
        if (self.library) |library| library.close();
        self.* = .{};
    }
    fn log(logger: t.Logger, level: u32, item: e.LogItem, message: ?[*:0]const u8) void {
        if (logger.func) |callback| callback("sg", level, @backingInt(item), message, 0, null, logger.user_data);
    }
    pub fn compile(self: *Compiler, shader: t.ShaderFunction, debugging: bool, logger: t.Logger) ?*sdk.Object {
        const previously_failed = self.load_failed;
        if (!self.ensureLoaded()) {
            if (!previously_failed) log(logger, 1, .hlsl_load_compiler_failed, null);
            return null;
        }
        const source = shader.source orelse return null;
        const target = shader.d3d11_target orelse return null;
        const flags = c.compile_pack_matrix_column_major | (if (debugging) c.compile_debug | c.compile_skip_optimization else c.compile_optimization_level3);
        var output: ?*sdk.Object = null;
        var diagnostics: ?*sdk.Object = null;
        const status = self.function.?(source, std.mem.len(source), shader.d3d11_filepath, null, @ptrFromInt(1), shader.entry orelse "main", target, flags, 0, &output, &diagnostics);
        if (status < 0) log(logger, 1, .hlsl_compilation_failed, null);
        if (diagnostics) |blob| {
            log(logger, 2, .hlsl_compilation_output, null);
            if (sdk.getBufferPointer(blob)) |text| log(logger, 3, .hlsl_compilation_output, @ptrCast(text));
            sdk.release(blob);
        }
        if (status < 0) {
            sdk.release(output);
            return null;
        }
        return output;
    }
};
