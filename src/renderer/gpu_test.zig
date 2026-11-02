const std = @import("std");
const zui_shaders = @import("zui_shaders");
test "shaders" {
    _ = zui_shaders.quads.desc(.vulkan);
}
