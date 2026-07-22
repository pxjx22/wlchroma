const std = @import("std");
const wayland = @import("wayland_test");

fn expectSplitApi(comptime T: type) !void {
    try std.testing.expect(@hasDecl(T, "useProgram"));
    try std.testing.expect(@hasDecl(T, "bindGeometry"));
    try std.testing.expect(@hasDecl(T, "uploadPalette"));
    try std.testing.expect(@hasDecl(T, "uploadStatic"));
    try std.testing.expect(!@hasDecl(T, "bind"));
    try std.testing.expect(!@hasDecl(T, "setStaticUniforms"));
}

test "effect and leaf shaders expose only split state operations" {
    try expectSplitApi(wayland.effect_shader.EffectShader);
    try expectSplitApi(wayland.colormix_shader.ColormixShader);
    try expectSplitApi(wayland.glass_drift_shader.GlassDriftShader);
    try expectSplitApi(wayland.standard_shader.StandardShader);
}
